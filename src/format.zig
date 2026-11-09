//! Doc 83: the source formatter. `format` takes a program's bytes and returns
//! its one standard form (4-space indent, width 100, doc 83 §3), or refuses:
//! a file with syntax errors is never touched (D6), and neither is one with a
//! comment in a position the formatter does not place (it would have to guess
//! which code the comment belongs to).
//!
//! The tree is a semantic one, so the syntax it does not keep is read from
//! the token stream (`parser.parseFormat`): semicolons, `then`/`do`/`end`,
//! where an attribute was written. Comments come from `format_comments`,
//! consumed in source order as the builder walks the tree, which is why every
//! construct builds its parts in the order they were written.
//!
//! The result is a `format_doc` document, printed at width 100.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const diag = @import("diag.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const token = @import("token.zig");
const fd = @import("format_doc.zig");
const fc = @import("format_comments.zig");

const Doc = fd.Doc;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Token = token.Token;
const Tag = Token.Tag;

/// Columns a line may use.
pub const width: u32 = 100;

pub const Error = error{
    OutOfMemory,
    /// The file has syntax errors (they are in the `Diagnostics` passed in).
    SyntaxError,
    /// A comment lies where the formatter does not place comments.
    UnplacedComment,
};

/// Where `format`'s memory goes, by phase (`zig build bench-fmt`).
pub const Breakdown = struct {
    /// The parser's arena: the token array and the syntax tree.
    parse_arena: usize = 0,
    /// The token array alone (inside `parse_arena`).
    tokens: usize = 0,
    /// The comment list and the line table that places comments.
    trivia: usize = 0,
    /// The document at its largest (one top-level statement's), and the
    /// formatter's own scratch.
    doc: usize = 0,
    /// The printer's working memory.
    printer: fd.Stats = .{},
    output: usize = 0,
};

/// The formatted form of `source`. The result is owned by `gpa`.
pub fn format(gpa: Allocator, source: []const u8, diags: *diag.Diagnostics) Error![]u8 {
    return formatMeasured(gpa, source, diags, null);
}

/// `format`, reporting where its memory went in `breakdown`.
///
/// The file is printed one top-level statement at a time: each is built,
/// printed, and its document released before the next is built (doc 83 §10),
/// so the document never holds more than the largest top-level statement.
pub fn formatMeasured(gpa: Allocator, source: []const u8, diags: *diag.Diagnostics, breakdown: ?*Breakdown) Error![]u8 {
    const src = try gpa.dupeSentinel(u8, source, 0);
    defer gpa.free(src);
    var trivia = lexer.Trivia.init(gpa);
    defer trivia.deinit();
    var parsed = parser.parseFormat(gpa, src, diags, &trivia) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SyntaxError,
    };
    defer parsed.ast.deinit();
    // A lossy sink could have dropped a comment or hidden an error (§7.1).
    if (diags.hasErrors() or diags.incomplete or trivia.incomplete) return error.SyntaxError;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var f: F = .{
        .gpa = gpa,
        .arena = &arena,
        .a = arena.allocator(),
        .b = try .init(gpa, src),
        .src = src,
        .toks = parsed.tokens,
        .cm = undefined,
    };
    defer f.deinit();
    f.cm = try fc.Comments.init(gpa, src, trivia.comments.items);
    f.base = f.b.mark();
    var printer: fd.Printer = .init(gpa, &f.b, .{ .width = width });
    defer printer.deinit();
    f.sink = &printer;
    _ = try f.blockBody(parsed.ast.root, 0, @intCast(src.len), true);
    if (!f.cm.exhausted()) return error.UnplacedComment;
    const text = try printer.finish();
    errdefer gpa.free(text);
    if (breakdown) |bd| bd.* = .{
        .parse_arena = parsed.ast.arena.queryCapacity(),
        .tokens = parsed.tokens.len * @sizeOf(Token),
        .trivia = trivia.comments.capacity * @sizeOf(lexer.Comment) + f.cm.line_starts.len * @sizeOf(u32),
        .doc = f.b.capacityBytes() + arena.queryCapacity() + f.scratchBytes(),
        .printer = printer.stats,
        .output = text.len,
    };
    if (text.len == 0) return text;
    // One final newline.
    const out = try gpa.realloc(text, text.len + 1);
    out[text.len] = '\n';
    return out;
}

/// `s` with every line break (`\r`, `\n`, `\r\n`, `\n\r`) as one `\n`, the
/// breaks the lexer counts (`Lexer.newline`), in `buf`.
fn lfOnly(gpa: Allocator, buf: *std.ArrayList(u8), s: []const u8) Allocator.Error![]const u8 {
    buf.clearRetainingCapacity();
    try buf.ensureTotalCapacity(gpa, s.len);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c != '\r' and c != '\n') {
            buf.appendAssumeCapacity(c);
            continue;
        }
        buf.appendAssumeCapacity('\n');
        if (i + 1 < s.len and (s[i + 1] == '\r' or s[i + 1] == '\n') and s[i + 1] != c) i += 1;
    }
    return buf.items;
}

// -- the builder ---------------------------------------------------------

const F = struct {
    gpa: Allocator,
    /// Comment runs; reset after each top-level statement is printed.
    arena: *std.heap.ArenaAllocator,
    a: Allocator,
    b: fd.Builder,
    src: []const u8,
    toks: []const Token,
    cm: fc.Comments,
    /// The top-level statements are printed here as they are built.
    sink: ?*fd.Printer = null,
    /// What the builder holds before the first statement (its fixed nodes).
    base: fd.Builder.Mark = undefined,
    /// A top-level piece has been printed (the next one is preceded by a newline).
    printed_any: bool = false,

    // The stacks the formatter's lists are built on, in `gpa`. Lists nest,
    // innermost on top; a list is read by index while nested lists are
    // built, because a push may move the stack.
    pieces: std.ArrayList(Piece) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    exprs: std.ArrayList(*const Expr) = .empty,
    ops: std.ArrayList(ast.BinaryOp) = .empty,
    flags: std.ArrayList(bool) = .empty,
    /// Text being assembled (a name list, a normalized string), copied into
    /// the builder as soon as it is done.
    sbuf: std.ArrayList(u8) = .empty,
    lfbuf: std.ArrayList(u8) = .empty,

    fn deinit(f: *F) void {
        f.cm.deinit(f.gpa);
        f.b.deinit();
        f.pieces.deinit(f.gpa);
        f.entries.deinit(f.gpa);
        f.exprs.deinit(f.gpa);
        f.ops.deinit(f.gpa);
        f.flags.deinit(f.gpa);
        f.sbuf.deinit(f.gpa);
        f.lfbuf.deinit(f.gpa);
    }

    fn scratchBytes(f: *const F) usize {
        return f.pieces.capacity * @sizeOf(Piece) + f.entries.capacity * @sizeOf(Entry) +
            f.exprs.capacity * @sizeOf(*const Expr) + f.ops.capacity * @sizeOf(ast.BinaryOp) +
            f.flags.capacity + f.sbuf.capacity + f.lfbuf.capacity;
    }

    // ---- tokens and text ----

    /// Index of the first token that starts at or after `offset`.
    fn tokIdx(f: *const F, offset: u32) usize {
        var lo: usize = 0;
        var hi: usize = f.toks.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (f.toks[mid].start < offset) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    fn lexeme(f: *const F, tk: Token) []const u8 {
        return f.src[tk.start..tk.end];
    }

    /// The first token of tag `tag` at or after `offset`.
    fn findTok(f: *const F, tag: Tag, offset: u32) ?Token {
        var i = f.tokIdx(offset);
        while (i < f.toks.len) : (i += 1) {
            if (f.toks[i].tag == tag) return f.toks[i];
            if (f.toks[i].tag == .eof) return null;
        }
        return null;
    }

    /// The token that ends at `end`.
    fn tokEndingAt(f: *const F, end: u32) Token {
        var i = f.tokIdx(end);
        if (i > 0) i -= 1;
        return f.toks[i];
    }

    /// Verbatim source text. Line breaks inside it (a long string, a template,
    /// a block comment, a backslash-newline) are written as `\n`: the lexer
    /// reads every `\r`, `\n`, `\r\n` and `\n\r` there as one `\n` already
    /// (doc 83 Q3), so the output is LF throughout and means the same.
    fn lit(f: *F, s: []const u8) Error!Doc {
        const text = if (std.mem.indexOfScalar(u8, s, '\r') != null) try lfOnly(f.gpa, &f.lfbuf, s) else s;
        if (std.mem.indexOfScalar(u8, text, '\n') != null) return f.b.raw(text);
        return f.b.text(text);
    }

    fn t(f: *F, s: []const u8) Error!Doc {
        return f.b.text(s);
    }

    fn cat(f: *F, parts: []const Doc) Error!Doc {
        return f.b.cat(parts);
    }

    /// Refuse if a comment before `pos` was never placed: it would otherwise
    /// be taken by the next construct, which is not where it was written.
    fn checkClean(f: *const F, pos: u32) Error!void {
        if (f.cm.pendingBefore(pos)) return error.UnplacedComment;
    }

    fn commentDoc(f: *F, c: fc.Comment) Error!Doc {
        return f.lit(f.cm.text(c));
    }

    /// Lines of comments (each followed by a hardline), or inline ones (each
    /// followed by a space), and a blank line after the run if the source
    /// had one.
    fn runDoc(f: *F, run: fc.LeadingRun) Error!?Doc {
        if (run.items.len == 0) return null;
        const top = f.b.top();
        for (run.items, 0..) |it, i| {
            if (i > 0 and it.blank_before) try f.b.push(fd.hardline);
            try f.b.push(try f.commentDoc(it.comment));
            try f.b.push(if (it.inline_) try f.t(" ") else fd.hardline);
        }
        if (run.blank_after) try f.b.push(fd.hardline);
        return try f.b.catFrom(top);
    }

    // ---- statement blocks ----

    const Piece = struct { doc: Doc, blank_before: bool };

    /// Statements one per line with their comments, from `start` (where the
    /// block's header ended) to `limit` (where its closing token starts).
    /// No leading or trailing newline; `empty` if there is nothing to print.
    /// The top level (`top`) is printed to `sink` as it goes, and returns
    /// `empty`.
    fn blockBody(f: *F, stmts: ast.Block, start: u32, limit: u32, top: bool) Error!Doc {
        const ptop = f.pieces.items.len;
        var prev_end = start;
        var after_fn = false;
        for (stmts, 0..) |s, i| {
            const run = try f.cm.takeLeading(f.a, prev_end, s.span.start);
            const is_fn = top and isFunctionDecl(s);
            // Where the attached part of the comments starts (all of them
            // unless a blank line separates the last ones from the item).
            var attached_from: usize = run.items.len;
            if (run.items.len > 0 and !run.blank_after) {
                var j = run.items.len;
                while (j > 0) {
                    j -= 1;
                    attached_from = j;
                    if (run.items[j].blank_before) break;
                }
            }
            var force_blank_at: ?usize = null;
            if (is_fn and attached_from == run.items.len) force_blank_at = f.pieces.items.len;
            var carry: ?Doc = null;
            var first_piece = true;
            for (run.items, 0..) |it, j| {
                if (j == attached_from and is_fn) force_blank_at = f.pieces.items.len;
                var d = try f.commentDoc(it.comment);
                if (carry) |c| d = try f.cat(&.{ c, d });
                if (it.inline_) {
                    carry = try f.cat(&.{ d, try f.t(" ") });
                    continue;
                }
                carry = null;
                var blank = it.blank_before;
                if (first_piece and after_fn) blank = true;
                first_piece = false;
                try f.pieces.append(f.gpa, .{ .doc = d, .blank_before = blank });
            }
            var sd = try f.stmt(s);
            try f.checkClean(s.span.end);
            if (carry) |c| sd = try f.cat(&.{ c, sd });
            // `;` where the next statement starts with `(` would otherwise
            // continue this one as a call (§6.1).
            if (i + 1 < stmts.len and f.startsWithParen(stmts[i + 1]) and endsInExpression(s)) {
                sd = try f.cat(&.{ sd, try f.t(";") });
            }
            const after = f.semiEnd(s.span.end);
            var end_pos = after;
            if (try f.cm.takeTrailing(f.a, after)) |tr| {
                sd = try f.cat(&.{ sd, try f.b.lineSuffix(tr.text) });
                end_pos = tr.end;
            }
            var blank = if (run.items.len > 0) run.blank_after else f.cm.gapHasBlank(prev_end, s.span.start);
            if (first_piece and after_fn) blank = true;
            if (force_blank_at) |at| {
                if (at == f.pieces.items.len) blank = true else f.pieces.items[at].blank_before = true;
            }
            try f.pieces.append(f.gpa, .{ .doc = sd, .blank_before = blank });
            prev_end = end_pos;
            after_fn = is_fn;
            if (top) try f.flush(ptop);
        }
        // Comments after the last statement, before the closing token.
        const tail = try f.cm.takeLeading(f.a, prev_end, limit);
        for (tail.items, 0..) |it, j| {
            const d = try f.commentDoc(it.comment);
            const blank = it.blank_before or (j == 0 and after_fn);
            try f.pieces.append(f.gpa, .{ .doc = d, .blank_before = blank });
        }
        if (top) {
            try f.flush(ptop);
            return fd.empty;
        }
        const d = try f.assemble(f.pieces.items[ptop..]);
        f.pieces.shrinkRetainingCapacity(ptop);
        return d;
    }

    /// Prints the top-level pieces from `ptop` on, then releases everything
    /// built for them.
    fn flush(f: *F, ptop: usize) Error!void {
        const sink = f.sink.?;
        for (f.pieces.items[ptop..]) |p| {
            if (f.printed_any) {
                try sink.feed(fd.hardline);
                if (p.blank_before) try sink.feed(fd.hardline);
            }
            try sink.feed(p.doc);
            f.printed_any = true;
        }
        f.pieces.shrinkRetainingCapacity(ptop);
        f.b.release(f.base);
        _ = f.arena.reset(.retain_capacity);
    }

    fn assemble(f: *F, pieces: []const Piece) Error!Doc {
        if (pieces.len == 0) return fd.empty;
        const top = f.b.top();
        for (pieces, 0..) |p, i| {
            if (i > 0) {
                try f.b.push(fd.hardline);
                if (p.blank_before) try f.b.push(fd.hardline);
            }
            try f.b.push(p.doc);
        }
        return f.b.catFrom(top);
    }

    /// The end of a statement and the `;` that may follow it.
    fn semiEnd(f: *const F, end: u32) u32 {
        const i = f.tokIdx(end);
        if (i < f.toks.len and f.toks[i].tag == .semicolon) return f.toks[i].end;
        return end;
    }

    fn startsWithParen(f: *const F, s: Stmt) bool {
        const i = f.tokIdx(s.span.start);
        return i < f.toks.len and f.toks[i].tag == .lparen;
    }

    /// A block's body, indented, after its header (which ended at
    /// `header_end`); a comment on the header's line stays there.
    fn indentedBody(f: *F, stmts: ast.Block, header_end: u32, limit: u32) Error!Doc {
        const trailing = try f.cm.takeTrailing(f.a, header_end);
        const start = if (trailing) |tr| tr.end else header_end;
        const body = try f.blockBody(stmts, start, limit, false);
        const suffix: Doc = if (trailing) |tr| try f.b.lineSuffix(tr.text) else fd.empty;
        if (body == fd.empty) return suffix;
        return f.cat(&.{ suffix, try f.b.indent(try f.cat(&.{ fd.hardline, body })) });
    }

    // ---- statements ----

    fn stmt(f: *F, s: Stmt) Error!Doc {
        switch (s.data) {
            .local => |l| {
                const head = try f.declHead(s.span);
                if (l.values.len == 0) return head;
                return f.cat(&.{ head, try f.t(" = "), try f.exprList(l.values) });
            },
            .global => |g| {
                const head = try f.declHead(s.span);
                if (g.values.len == 0) return head;
                return f.cat(&.{ head, try f.t(" = "), try f.exprList(g.values) });
            },
            .global_all => return f.declHead(s.span),
            .local_function => |lf| return f.functionStmt(s, "local ", lf.name, lf.body),
            .global_function => |gf| return f.functionStmt(s, "global ", gf.name, gf.body),
            .function_decl => |fdc| {
                f.sbuf.clearRetainingCapacity();
                for (fdc.name.path, 0..) |p, i| {
                    if (i > 0) try f.sbuf.append(f.gpa, '.');
                    try f.sbuf.appendSlice(f.gpa, p.text);
                }
                if (fdc.name.method) |m| {
                    try f.sbuf.append(f.gpa, ':');
                    try f.sbuf.appendSlice(f.gpa, m.text);
                }
                const head = try f.cat(&.{ try f.t(if (fdc.body.is_async) "async function " else "function "), try f.t(f.sbuf.items) });
                return f.cat(&.{ head, try f.funcBody(fdc.body, fdc.name.method != null) });
            },
            .assign => |a| {
                const top = f.b.top();
                for (a.targets, 0..) |e, i| {
                    const d = try f.expr(e);
                    if (i > 0) try f.b.push(try f.t(", "));
                    try f.b.push(d);
                }
                const targets = try f.b.catFrom(top);
                return f.cat(&.{ targets, try f.t(" = "), try f.exprList(a.values) });
            },
            .compound_assign => |c| {
                const target = try f.expr(c.target);
                const op = f.toks[f.tokIdx(c.target.span.end)];
                return f.cat(&.{ target, try f.t(" "), try f.t(f.lexeme(op)), try f.t(" "), try f.whole(c.value) });
            },
            .call => |e| return f.expr(e),
            .do => |body| {
                const end_tok = f.tokEndingAt(s.span.end);
                const inner = try f.indentedBody(body, s.span.start + 2, end_tok.start);
                return f.cat(&.{ try f.t("do"), inner, fd.hardline, try f.t("end") });
            },
            .while_ => |w| {
                const cond = try f.whole(w.cond);
                const do_tok = f.findTok(.keyword_do, w.cond.span.end) orelse return error.SyntaxError;
                try f.checkClean(do_tok.start);
                const inner = try f.indentedBody(w.body, do_tok.end, f.tokEndingAt(s.span.end).start);
                return f.cat(&.{ try f.t("while "), cond, try f.t(" do"), inner, fd.hardline, try f.t("end") });
            },
            .repeat => |r| {
                const until_tok = f.toks[f.tokIdx(r.cond.span.start) - 1];
                const inner = try f.indentedBody(r.body, s.span.start + 6, until_tok.start);
                const cond = try f.whole(r.cond);
                return f.cat(&.{ try f.t("repeat"), inner, fd.hardline, try f.t("until "), cond });
            },
            .if_ => |i| return f.ifStmt(s, i),
            .numeric_for => |n| {
                const top = f.b.top();
                try f.b.push(try f.t("for "));
                try f.b.push(try f.t(n.name));
                try f.b.push(try f.t(" = "));
                try f.b.push(try f.whole(n.start));
                try f.b.push(try f.t(", "));
                try f.b.push(try f.whole(n.stop));
                var last_end = n.stop.span.end;
                if (n.step) |st| {
                    try f.b.push(try f.t(", "));
                    try f.b.push(try f.whole(st));
                    last_end = st.span.end;
                }
                const do_tok = f.findTok(.keyword_do, last_end) orelse return error.SyntaxError;
                try f.checkClean(do_tok.start);
                try f.b.push(try f.t(" do"));
                try f.b.push(try f.indentedBody(n.body, do_tok.end, f.tokEndingAt(s.span.end).start));
                try f.b.push(fd.hardline);
                try f.b.push(try f.t("end"));
                return f.b.catFrom(top);
            },
            .generic_for => |g| {
                f.sbuf.clearRetainingCapacity();
                for (g.names, 0..) |n, k| {
                    if (k > 0) try f.sbuf.appendSlice(f.gpa, ", ");
                    try f.sbuf.appendSlice(f.gpa, n.text);
                }
                const names = try f.t(f.sbuf.items);
                const exprs = try f.exprList(g.exprs);
                const do_tok = f.findTok(.keyword_do, g.exprs[g.exprs.len - 1].span.end) orelse return error.SyntaxError;
                try f.checkClean(do_tok.start);
                const inner = try f.indentedBody(g.body, do_tok.end, f.tokEndingAt(s.span.end).start);
                return f.cat(&.{ try f.t("for "), names, try f.t(" in "), exprs, try f.t(" do"), inner, fd.hardline, try f.t("end") });
            },
            .return_ => |values| {
                if (values.len == 0) return f.t("return");
                return f.cat(&.{ try f.t("return "), try f.exprList(values) });
            },
            .break_ => return f.t("break"),
            .err => return error.SyntaxError,
        }
    }

    fn ifStmt(f: *F, s: Stmt, i: anytype) Error!Doc {
        const top = f.b.top();
        const end_tok = f.tokEndingAt(s.span.end);
        for (i.branches, 0..) |br, k| {
            if (k > 0) try f.b.push(fd.hardline);
            const cond = try f.whole(br.cond);
            const then_tok = f.findTok(.keyword_then, br.cond.span.end) orelse return error.SyntaxError;
            try f.checkClean(then_tok.start);
            const limit: u32 = if (k + 1 < i.branches.len) i.branches[k + 1].kw_start else if (i.else_body != null) i.else_start else end_tok.start;
            try f.b.push(try f.t(if (k == 0) "if " else "elseif "));
            try f.b.push(cond);
            try f.b.push(try f.t(" then"));
            try f.b.push(try f.indentedBody(br.body, then_tok.end, limit));
        }
        if (i.else_body) |eb| {
            try f.b.push(fd.hardline);
            try f.b.push(try f.t("else"));
            try f.b.push(try f.indentedBody(eb, i.else_start + 4, end_tok.start));
        }
        try f.b.push(fd.hardline);
        try f.b.push(try f.t("end"));
        return f.b.catFrom(top);
    }

    fn functionStmt(f: *F, s: Stmt, prefix: []const u8, name: []const u8, body: *ast.FunctionBody) Error!Doc {
        _ = s;
        const head = try f.cat(&.{
            try f.t(prefix),
            try f.t(if (body.is_async) "async function " else "function "),
            try f.t(name),
        });
        return f.cat(&.{ head, try f.funcBody(body, false) });
    }

    /// `local`/`global` and the names (with attributes and types), up to the
    /// `=`: read from the tokens, so an attribute stays where it was written.
    /// A list too long for the line is filled: as many names per line as
    /// fit, the continuation lines indented once.
    fn declHead(f: *F, span: ast.Span) Error!Doc {
        const top = f.b.top();
        f.sbuf.clearRetainingCapacity();
        var prev: ?Tag = null;
        var i = f.tokIdx(span.start);
        while (i < f.toks.len and f.toks[i].start < span.end and f.toks[i].tag != .assign) : (i += 1) {
            const tk = f.toks[i];
            if (prev) |p| if (spaceBetween(p, tk.tag)) try f.sbuf.append(f.gpa, ' ');
            try f.sbuf.appendSlice(f.gpa, f.lexeme(tk));
            prev = tk.tag;
            if (tk.tag == .comma) {
                try f.b.push(try f.t(f.sbuf.items));
                f.sbuf.clearRetainingCapacity();
                prev = null;
            }
        }
        try f.b.push(try f.t(f.sbuf.items));
        if (f.b.parts(top).len == 1) {
            const only = f.b.parts(top)[0];
            f.b.popTo(top);
            return only;
        }
        return f.b.indent(try f.b.fillFrom(top));
    }

    // ---- expressions ----

    /// An expression in a position that holds a whole value: parentheses
    /// that only wrap it (not a call or `...`, whose pair truncates to one
    /// value) are redundant, and removed to their fixpoint (§6.9).
    fn whole(f: *F, e: *const Expr) Error!Doc {
        var x = e;
        while (x.data == .paren) {
            const inner = x.data.paren;
            switch (inner.data) {
                .call, .method_call, .vararg => break,
                else => x = inner,
            }
        }
        return f.expr(x);
    }

    /// `a`, or `a,` then the rest on continuation lines if it doesn't fit.
    fn exprList(f: *F, values: []const *Expr) Error!Doc {
        if (values.len == 0) return fd.empty;
        const first = try f.whole(values[0]);
        if (values.len == 1) return first;
        const top = f.b.top();
        for (values[1..]) |v| {
            try f.b.push(try f.t(","));
            try f.b.push(fd.line);
            const d = try f.whole(v);
            try f.b.push(d);
        }
        const rest = try f.b.catFrom(top);
        return f.b.group(try f.cat(&.{ first, try f.b.indent(rest) }));
    }

    fn expr(f: *F, e: *const Expr) Error!Doc {
        switch (e.data) {
            .nil, .bool, .int, .float, .name, .vararg => return f.t(f.src[e.span.start..e.span.end]),
            .string_raw => return f.lit(try f.normalizeString(f.src[e.span.start..e.span.end])),
            .string_interp => {
                // Printed verbatim, so comments inside a hole stay with it.
                try f.checkClean(e.span.start);
                f.cm.skipTo(e.span.end);
                return f.lit(f.src[e.span.start..e.span.end]);
            },
            .paren => |inner| return f.cat(&.{ try f.t("("), try f.expr(inner), try f.t(")") }),
            .unary => |u| {
                const operand = try f.expr(u.operand);
                const op = switch (u.op) {
                    .neg => "-",
                    .not => "not ",
                    .len => "#",
                    .bnot => "~",
                };
                // `- -x` must not become `--x`, a comment; `~ ~x` likewise.
                const same = (u.op == .neg or u.op == .bnot) and u.operand.data == .unary and u.operand.data.unary.op == u.op;
                return f.cat(&.{ try f.t(op), if (same) try f.t(" ") else fd.empty, operand });
            },
            .binary => return f.binary(e),
            .field, .index, .method_call => return f.chain(e),
            .call => |c| {
                if (c.callee.data == .intrinsic) {
                    // `await e`.
                    return f.cat(&.{ try f.t("await "), try f.expr(c.args[0]) });
                }
                return f.chain(e);
            },
            .function => |fb| {
                const head = try f.t(if (fb.is_async) "async function" else "function");
                return f.cat(&.{ head, try f.funcBody(fb, false) });
            },
            .intrinsic => return error.SyntaxError,
            .table => |fields| return f.table(fields, e.span),
            .err => return error.SyntaxError,
        }
    }

    /// A postfix chain (`a.b[c](d):e(f)`): its root and every link after it,
    /// built in one pass so a long chain is not re-walked per link. A chain of
    /// more than two calls that does not fit breaks before every `.` or `:`
    /// that follows the first call (§6.4), each link indented once.
    fn chain(f: *F, e: *const Expr) Error!Doc {
        // The links, outermost first, on the expression stack.
        const xtop = f.exprs.items.len;
        var root = e;
        walk: while (true) {
            switch (root.data) {
                .field => |fl| {
                    try f.exprs.append(f.gpa, root);
                    root = fl.obj;
                },
                .index => |ix| {
                    try f.exprs.append(f.gpa, root);
                    root = ix.obj;
                },
                .method_call => |m| {
                    try f.exprs.append(f.gpa, root);
                    root = m.obj;
                },
                .call => |c| {
                    if (c.callee.data == .intrinsic) break :walk;
                    try f.exprs.append(f.gpa, root);
                    root = c.callee;
                },
                else => break :walk,
            }
        }
        std.mem.reverse(*const Expr, f.exprs.items[xtop..]);
        const n = f.exprs.items.len - xtop;
        // Each link's doc on the builder's stack; where each link begins a
        // line when the chain breaks (the `.`/`:` links after the first
        // call) on the flag stack.
        const ltop = f.b.top();
        const btop = f.flags.items.len;
        var calls: usize = 0;
        var seen_call = false;
        for (0..n) |k| {
            const node = f.exprs.items[xtop + k];
            switch (node.data) {
                .field => |fl| {
                    try f.flags.append(f.gpa, seen_call);
                    try f.b.push(try f.cat(&.{ try f.t("."), try f.t(fl.name) }));
                },
                .index => |ix| {
                    try f.flags.append(f.gpa, false);
                    const link = try f.cat(&.{ try f.t("["), try f.whole(ix.key), try f.t("]") });
                    try f.b.push(link);
                },
                .call => |c| {
                    try f.flags.append(f.gpa, false);
                    const link = try f.argList(c.args, c.callee.span.end, node.span.end);
                    try f.b.push(link);
                    calls += 1;
                    seen_call = true;
                },
                .method_call => |m| {
                    try f.flags.append(f.gpa, seen_call);
                    const arglist = try f.argList(m.args, m.name_span.end, node.span.end);
                    try f.b.push(try f.cat(&.{ try f.t(":"), try f.t(m.name), arglist }));
                    calls += 1;
                    seen_call = true;
                },
                else => unreachable,
            }
        }
        f.exprs.shrinkRetainingCapacity(xtop);
        const root_doc = try f.expr(root);
        var any_break = false;
        if (calls > 2) for (f.flags.items[btop..]) |b| {
            if (b) any_break = true;
        };
        if (!any_break) {
            f.flags.shrinkRetainingCapacity(btop);
            // The root, then the links.
            const links = try f.b.catFrom(ltop);
            return f.cat(&.{ root_doc, links });
        }
        // The head runs to the first link that starts a line; the rest hang
        // from it, one `.`/`:` link (with what follows it) per line.
        var first_break: usize = 0;
        while (!f.flags.items[btop + first_break]) first_break += 1;
        const rtop = f.b.top();
        for (first_break..n) |k| {
            if (f.flags.items[btop + k]) try f.b.push(fd.softline);
            try f.b.push(f.b.parts(ltop)[k]);
        }
        const rest = try f.b.catFrom(rtop);
        const htop = f.b.top();
        try f.b.push(root_doc);
        for (0..first_break) |k| try f.b.push(f.b.parts(ltop)[k]);
        try f.b.push(try f.b.indent(rest));
        const whole_chain = try f.b.group(try f.b.catFrom(htop));
        f.b.popTo(ltop);
        f.flags.shrinkRetainingCapacity(btop);
        return whole_chain;
    }

    fn binary(f: *F, e: *const Expr) Error!Doc {
        const op = e.data.binary.op;
        const level = opLevel(op);
        // The chain of this precedence level, flattened along its
        // associativity, so `a + b - c` is one group.
        // Operands in source order on the expression stack, the operators
        // between them on the operator stack.
        const xtop = f.exprs.items.len;
        const otop = f.ops.items.len;
        if (rightAssoc(op)) {
            var cur = e;
            while (true) {
                const bn = cur.data.binary;
                try f.exprs.append(f.gpa, bn.lhs);
                try f.ops.append(f.gpa, bn.op);
                if (bn.rhs.data == .binary and opLevel(bn.rhs.data.binary.op) == level) {
                    cur = bn.rhs;
                } else {
                    try f.exprs.append(f.gpa, bn.rhs);
                    break;
                }
            }
        } else {
            // Walked from the right: right operands outermost first, then
            // the leftmost operand; reversed into source order.
            var cur = e;
            while (true) {
                const bn = cur.data.binary;
                try f.exprs.append(f.gpa, bn.rhs);
                try f.ops.append(f.gpa, bn.op);
                if (bn.lhs.data == .binary and opLevel(bn.lhs.data.binary.op) == level) {
                    cur = bn.lhs;
                } else {
                    try f.exprs.append(f.gpa, bn.lhs);
                    break;
                }
            }
            std.mem.reverse(*const Expr, f.exprs.items[xtop..]);
            std.mem.reverse(ast.BinaryOp, f.ops.items[otop..]);
        }
        const n_ops = f.ops.items.len - otop;
        const first = try f.expr(f.exprs.items[xtop]);
        const top = f.b.top();
        for (0..n_ops) |k| {
            try f.b.push(fd.line);
            try f.b.push(try f.t(opText(f.ops.items[otop + k])));
            try f.b.push(try f.t(" "));
            const d = try f.expr(f.exprs.items[xtop + 1 + k]);
            try f.b.push(d);
        }
        f.exprs.shrinkRetainingCapacity(xtop);
        f.ops.shrinkRetainingCapacity(otop);
        const rest = try f.b.catFrom(top);
        return f.b.group(try f.cat(&.{ first, try f.b.indent(rest) }));
    }

    // ---- lists: arguments, parameters, table entries ----

    /// One item of a bracketed list: its doc, whether a blank line was
    /// before it, and the comment after it on its line (`empty` if none).
    const Entry = struct { doc: Doc, blank: bool, suffix: Doc };

    /// Builds the parts of a bracketed list while the caller builds each
    /// item, in order, so comments between items are consumed in order. The
    /// items are on `F.entries` from `top` on; `release` pops them.
    const ListBuilder = struct {
        f: *F,
        prev: u32,
        top: usize,
        /// A comment on the opening bracket's line.
        open_suffix: ?Doc = null,
        any_comment: bool = false,
        pending_lead: ?Doc = null,
        pending_blank: bool = false,

        fn release(lb: *const ListBuilder) void {
            lb.f.entries.shrinkRetainingCapacity(lb.top);
        }

        fn count(lb: *const ListBuilder) usize {
            return lb.f.entries.items.len - lb.top;
        }

        fn entry(lb: *const ListBuilder, i: usize) Entry {
            return lb.f.entries.items[lb.top + i];
        }

        fn init(f: *F, open_end: u32) Error!ListBuilder {
            var lb: ListBuilder = .{ .f = f, .prev = open_end, .top = f.entries.items.len };
            if (try f.cm.takeTrailing(f.a, open_end)) |tr| {
                lb.open_suffix = try f.b.lineSuffix(tr.text);
                lb.prev = tr.end;
                lb.any_comment = true;
            }
            return lb;
        }

        /// Comments before the item that starts at `start`; returns the docs
        /// to print before it.
        fn begin(lb: *ListBuilder, start: u32) Error!void {
            const f = lb.f;
            const run = try f.cm.takeLeading(f.a, lb.prev, start);
            lb.pending_blank = if (run.items.len > 0) run.items[0].blank_before else f.cm.gapHasBlank(lb.prev, start);
            if (try f.runDoc(run)) |d| {
                lb.any_comment = true;
                lb.pending_lead = d;
            } else lb.pending_lead = null;
        }

        fn end(lb: *ListBuilder, item_end: u32, doc: Doc) Error!void {
            const f = lb.f;
            try f.checkClean(item_end);
            var sep_end = item_end;
            const i = f.tokIdx(item_end);
            if (i < f.toks.len and (f.toks[i].tag == .comma or f.toks[i].tag == .semicolon)) sep_end = f.toks[i].end;
            var d = doc;
            if (lb.pending_lead) |lead| d = try f.cat(&.{ lead, d });
            lb.pending_lead = null;
            var suffix: Doc = fd.empty;
            lb.prev = sep_end;
            if (try f.cm.takeTrailing(f.a, sep_end)) |tr| {
                suffix = try f.b.lineSuffix(tr.text);
                lb.prev = tr.end;
                lb.any_comment = true;
            }
            try f.entries.append(f.gpa, .{ .doc = d, .blank = lb.pending_blank, .suffix = suffix });
        }

        /// Own-line comments before the closing bracket.
        fn finish(lb: *ListBuilder, close_start: u32) Error!?Doc {
            const f = lb.f;
            const run = try f.cm.takeLeading(f.a, lb.prev, close_start);
            if (run.items.len == 0) return null;
            lb.any_comment = true;
            const top = f.b.top();
            for (run.items, 0..) |it, i| {
                if (i > 0) {
                    try f.b.push(fd.hardline);
                    if (it.blank_before) try f.b.push(fd.hardline);
                }
                try f.b.push(try f.commentDoc(it.comment));
            }
            return try f.b.catFrom(top);
        }

        /// The items separated by commas; `sep` follows each comma (a `line`
        /// or a `hardline`). A trailing comment forces the group to break.
        fn joined(lb: *ListBuilder, sep: Doc, trailing_comma: Doc, keep_blank: bool) Error!Doc {
            const f = lb.f;
            const top = f.b.top();
            const n = lb.count();
            for (0..n) |i| {
                const it = lb.entry(i);
                if (i > 0) {
                    try f.b.push(sep);
                    if (keep_blank and it.blank) try f.b.push(fd.hardline);
                }
                try f.b.push(it.doc);
                try f.b.push(if (i + 1 < n) try f.t(",") else trailing_comma);
                if (it.suffix != fd.empty) {
                    try f.b.push(it.suffix);
                    try f.b.push(fd.break_parent);
                }
            }
            return f.b.catFrom(top);
        }
    };

    /// `(a, b)` of a call, from just after the callee to the call's end.
    fn argList(f: *F, list: []const *Expr, callee_end: u32, call_end: u32) Error!Doc {
        const open = f.toks[f.tokIdx(callee_end)];
        const close = f.tokEndingAt(call_end);
        var lb = try ListBuilder.init(f, open.end);
        defer lb.release();
        for (list) |e| {
            try lb.begin(e.span.start);
            const d = try f.whole(e);
            try lb.end(e.span.end, d);
        }
        const dangling = try lb.finish(close.start);
        if (list.len == 0 and !lb.any_comment) return f.t("()");
        const open_doc: Doc = try f.cat(&.{ try f.t("("), lb.open_suffix orelse fd.empty });
        const close_doc = try f.t(")");
        const body = try lb.joined(fd.line, fd.empty, false);
        const dang: Doc = if (dangling) |d| try f.cat(&.{ fd.hardline, d }) else fd.empty;
        const expanded = try f.b.group(try f.cat(&.{
            open_doc,
            try f.b.indent(try f.cat(&.{ fd.softline, body, dang })),
            fd.softline,
            close_doc,
        }));
        // A last argument that is a function or a table hugs the call (§6.2).
        if (!lb.any_comment and list.len > 0 and hugs(list[list.len - 1]) and !anyHuggable(list[0 .. list.len - 1])) {
            const top = f.b.top();
            try f.b.push(open_doc);
            for (0..list.len - 1) |i| {
                try f.b.push(lb.entry(i).doc);
                try f.b.push(try f.t(", "));
            }
            try f.b.push(try f.b.hug(lb.entry(list.len - 1).doc));
            try f.b.push(close_doc);
            return f.b.alt(try f.b.catFrom(top), expanded);
        }
        return expanded;
    }

    fn hugs(e: *const Expr) bool {
        return switch (e.data) {
            .function => true,
            .table => |fields| fields.len > 0,
            else => false,
        };
    }

    fn anyHuggable(list: []const *Expr) bool {
        for (list) |e| if (hugs(e)) return true;
        return false;
    }

    /// `(params) : ret` then the body and `end`, for a function whose
    /// `function`/name text the caller printed. `skip_self`: a method
    /// declaration's synthesised first parameter.
    fn funcBody(f: *F, fb: *const ast.FunctionBody, skip_self: bool) Error!Doc {
        const params = if (skip_self and fb.params.len > 0) fb.params[1..] else fb.params;
        const open = f.toks[f.tokIdx(fb.span.start)];
        const close_idx = blk: {
            var i = f.tokIdx(fb.span.start);
            while (i < f.toks.len and f.toks[i].tag != .rparen) i += 1;
            break :blk i;
        };
        const close = f.toks[close_idx];
        var lb = try ListBuilder.init(f, open.end);
        defer lb.release();
        for (params) |p| {
            const end = if (p.type) |ty| ty.span.end else p.name_span.end;
            try lb.begin(p.name_span.start);
            var d = try f.t(p.name);
            if (p.type) |ty| d = try f.cat(&.{ d, try f.t(": "), try f.t(try f.typeText(ty)) });
            try lb.end(end, d);
        }
        if (fb.is_vararg) {
            const dots = f.findTok(.ellipsis, open.end) orelse return error.SyntaxError;
            try lb.begin(dots.start);
            try lb.end(dots.end, try f.t("..."));
        }
        const dangling = try lb.finish(close.start);
        var header_end = close.end;
        var params_doc: Doc = undefined;
        if (params.len == 0 and !fb.is_vararg and !lb.any_comment) {
            params_doc = try f.t("()");
        } else {
            const body = try lb.joined(fd.line, fd.empty, false);
            const dang: Doc = if (dangling) |d| try f.cat(&.{ fd.hardline, d }) else fd.empty;
            params_doc = try f.b.group(try f.cat(&.{
                try f.t("("),
                lb.open_suffix orelse fd.empty,
                try f.b.indent(try f.cat(&.{ fd.softline, body, dang })),
                fd.softline,
                try f.t(")"),
            }));
        }
        var ret: Doc = fd.empty;
        if (fb.ret_type) |rt| {
            ret = try f.cat(&.{ try f.t(": "), try f.t(try f.typeText(rt)) });
            header_end = rt.span.end;
        }
        const end_tok = f.tokEndingAt(fb.span.end);
        try f.checkClean(close.start);
        const inner = try f.indentedBody(fb.body, header_end, end_tok.start);
        return f.cat(&.{ params_doc, ret, inner, fd.hardline, try f.t("end") });
    }

    fn typeText(f: *F, ty: *const ast.TypeExpr) Error![]const u8 {
        f.sbuf.clearRetainingCapacity();
        for (ty.path, 0..) |seg, i| {
            if (i > 0) try f.sbuf.append(f.gpa, '.');
            try f.sbuf.appendSlice(f.gpa, seg);
        }
        if (ty.optional) try f.sbuf.append(f.gpa, '?');
        return f.sbuf.items;
    }

    // ---- tables ----

    fn table(f: *F, fields: []const ast.TableField, span: ast.Span) Error!Doc {
        var lb = try ListBuilder.init(f, span.start + 1);
        defer lb.release();
        for (fields) |fl| {
            const sp = f.fieldSpan(fl);
            try lb.begin(sp.start);
            const d = try f.fieldDoc(fl);
            try lb.end(sp.end, d);
        }
        const dangling = try lb.finish(span.end - 1);
        if (fields.len == 0 and !lb.any_comment) return f.t("{}");

        var forced = lb.any_comment;
        var fill_ok = fields.len > 0;
        for (fields) |fl| {
            switch (fl) {
                .positional => |e| {
                    if (!f.isShortLiteral(e)) fill_ok = false;
                    if (e.data == .table or e.data == .function) forced = true;
                },
                .named => |n| {
                    fill_ok = false;
                    if (n.value.data == .table or n.value.data == .function) forced = true;
                },
                .keyed => |k| {
                    fill_ok = false;
                    if (k.value.data == .table or k.value.data == .function) forced = true;
                },
            }
        }
        if (fields.len > 4 and !fill_ok) forced = true;
        const open_doc: Doc = try f.cat(&.{ try f.t("{"), lb.open_suffix orelse fd.empty });
        const close_doc = try f.t("}");
        const comma = try f.t(",");
        if (forced) {
            const body = try lb.joined(fd.hardline, comma, true);
            const dang: Doc = if (dangling) |d| try f.cat(&.{ fd.hardline, d }) else fd.empty;
            return f.cat(&.{
                open_doc,
                try f.b.indent(try f.cat(&.{ fd.hardline, body, dang })),
                fd.hardline,
                close_doc,
            });
        }
        const trailing = try f.b.ifBreak(comma, fd.empty);
        if (fill_ok and fields.len > 1) {
            const top = f.b.top();
            const n = lb.count();
            for (0..n) |i| {
                const d = lb.entry(i).doc;
                try f.b.push(if (i + 1 < n) try f.cat(&.{ d, comma }) else d);
            }
            const items = try f.b.fillFrom(top);
            return f.b.group(try f.cat(&.{
                open_doc,
                try f.b.indent(try f.cat(&.{ fd.line, items })),
                trailing,
                fd.line,
                close_doc,
            }));
        }
        const body = try lb.joined(fd.line, trailing, false);
        return f.b.group(try f.cat(&.{
            open_doc,
            try f.b.indent(try f.cat(&.{ fd.line, body })),
            fd.line,
            close_doc,
        }));
    }

    fn fieldSpan(f: *const F, fl: ast.TableField) ast.Span {
        switch (fl) {
            .positional => |e| return e.span,
            .named => |n| return .{ .start = n.name_span.start, .end = n.value.span.end },
            .keyed => |k| {
                const open = f.toks[f.tokIdx(k.key.span.start) - 1];
                return .{ .start = open.start, .end = k.value.span.end };
            },
        }
    }

    fn fieldDoc(f: *F, fl: ast.TableField) Error!Doc {
        switch (fl) {
            .positional => |e| return f.whole(e),
            .named => |n| return f.cat(&.{ try f.t(n.name), try f.t(" = "), try f.whole(n.value) }),
            .keyed => |k| return f.cat(&.{ try f.t("["), try f.whole(k.key), try f.t("] = "), try f.whole(k.value) }),
        }
    }

    /// A number, `true`/`false`/`nil`, or a string of at most 12 source bytes
    /// between its quotes (§6.5): what a literal array's fill packs.
    fn isShortLiteral(f: *const F, e: *const Expr) bool {
        return switch (e.data) {
            .nil, .bool, .int, .float => true,
            .unary => |u| u.op == .neg and (u.operand.data == .int or u.operand.data == .float),
            .string_raw => e.span.end - e.span.start <= 14 and f.src[e.span.start] != '[',
            else => false,
        };
    }

    // ---- strings ----

    /// §6.10: double quotes unless the content has more `"` than `'`; only
    /// the quote escapes change with the delimiter.
    fn normalizeString(f: *F, lexeme_: []const u8) Error![]const u8 {
        if (lexeme_.len < 2 or (lexeme_[0] != '"' and lexeme_[0] != '\'')) return lexeme_;
        const old = lexeme_[0];
        const content = lexeme_[1 .. lexeme_.len - 1];
        var dq: usize = 0;
        var sq: usize = 0;
        var i: usize = 0;
        while (i < content.len) : (i += 1) {
            switch (content[i]) {
                '\\' => {
                    i += 1;
                    if (i < content.len) switch (content[i]) {
                        '"' => dq += 1,
                        '\'' => sq += 1,
                        else => {},
                    };
                },
                '"' => dq += 1,
                '\'' => sq += 1,
                else => {},
            }
        }
        const new: u8 = if (dq > sq) '\'' else '"';
        if (new == old) return lexeme_;
        const out = &f.sbuf;
        out.clearRetainingCapacity();
        try out.append(f.gpa, new);
        i = 0;
        while (i < content.len) : (i += 1) {
            const c = content[i];
            if (c == '\\' and i + 1 < content.len) {
                const n = content[i + 1];
                i += 1;
                if (n == '"' or n == '\'') {
                    // The old delimiter's escape is no longer needed; the new
                    // delimiter's is never present (it was the other quote).
                    if (n == new) try out.append(f.gpa, '\\');
                    try out.append(f.gpa, n);
                } else {
                    try out.append(f.gpa, '\\');
                    try out.append(f.gpa, n);
                }
            } else if (c == new) {
                try out.append(f.gpa, '\\');
                try out.append(f.gpa, c);
            } else try out.append(f.gpa, c);
        }
        try out.append(f.gpa, new);
        return out.items;
    }
};

// -- small tables --------------------------------------------------------

fn isFunctionDecl(s: Stmt) bool {
    return switch (s.data) {
        .function_decl, .local_function, .global_function => true,
        else => false,
    };
}

/// Does the statement end in an expression (so a following `(` would
/// continue it) rather than in the `end` of a block?
fn endsInExpression(s: Stmt) bool {
    return switch (s.data) {
        .local => |l| l.values.len > 0,
        .global => |g| g.values.len > 0,
        .assign, .compound_assign, .call, .return_, .repeat => true,
        else => false,
    };
}

fn spaceBetween(p: Tag, c: Tag) bool {
    if (c == .comma or c == .colon or c == .dot or c == .gt) return false;
    if (p == .lt or p == .dot) return false;
    return true;
}

fn opText(op: ast.BinaryOp) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .idiv => "//",
        .mod => "%",
        .pow => "^",
        .concat => "..",
        .eq => "==",
        .ne => "~=",
        .lt => "<",
        .le => "<=",
        .gt => ">",
        .ge => ">=",
        .and_ => "and",
        .or_ => "or",
        .coalesce => "??",
        .band => "&",
        .bor => "|",
        .bxor => "~",
        .shl => "<<",
        .shr => ">>",
        .sar => "~>>",
    };
}

/// The parser's binding level (left side), so operators of one level form one chain.
fn opLevel(op: ast.BinaryOp) u8 {
    return switch (op) {
        .or_, .coalesce => 2,
        .and_ => 4,
        .lt, .gt, .le, .ge, .ne, .eq => 6,
        .bor => 8,
        .bxor => 10,
        .band => 12,
        .shl, .shr, .sar => 14,
        .concat => 16,
        .add, .sub => 18,
        .mul, .div, .idiv, .mod => 20,
        .pow => 24,
    };
}

fn rightAssoc(op: ast.BinaryOp) bool {
    return op == .concat or op == .pow;
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;

fn expectFmt(src: []const u8, expected: []const u8) !void {
    var diags = diag.Diagnostics.init(testing.allocator);
    defer diags.deinit();
    const got = try format(testing.allocator, src, &diags);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
    // And the standard form is its own fixed point (§7.2).
    var diags2 = diag.Diagnostics.init(testing.allocator);
    defer diags2.deinit();
    const again = try format(testing.allocator, got, &diags2);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(got, again);
}

test "format: locals, assignments, calls and returns" {
    try expectFmt("local   x=1\nlocal a,b = 1,2;y = x+1\nprint( x , y )\n", "local x = 1\nlocal a, b = 1, 2\ny = x + 1\nprint(x, y)\n");
    try expectFmt("return", "return\n");
    try expectFmt("", "");
}

test "format: blocks are expanded and indented" {
    try expectFmt("if x then return end", "if x then\n    return\nend\n");
    try expectFmt("while a do b() end", "while a do\n    b()\nend\n");
    try expectFmt("for i=1,10 do print(i) end", "for i = 1, 10 do\n    print(i)\nend\n");
    try expectFmt("for k,v in pairs(t) do end", "for k, v in pairs(t) do\nend\n");
    try expectFmt("if a then x() elseif b then y() else z() end", "if a then\n    x()\nelseif b then\n    y()\nelse\n    z()\nend\n");
    try expectFmt("repeat x() until done", "repeat\n    x()\nuntil done\n");
    try expectFmt("do local a = 1 end", "do\n    local a = 1\nend\n");
}

test "format: functions" {
    try expectFmt("local function f(a,b) return a+b end", "local function f(a, b)\n    return a + b\nend\n");
    try expectFmt("function t.a.b:m(x) return self end", "function t.a.b:m(x)\n    return self\nend\n");
    try expectFmt("local f = function() end", "local f = function()\nend\n");
    try expectFmt("async function f(...) end", "async function f(...)\nend\n");
}

test "format: strings prefer double quotes" {
    try expectFmt("x = 'a'", "x = \"a\"\n");
    try expectFmt("x = 'it\\'s'", "x = \"it's\"\n");
    try expectFmt("x = 'say \"hi\"'", "x = 'say \"hi\"'\n");
    try expectFmt("x = \"say \\\"hi\\\"\"", "x = 'say \"hi\"'\n");
    try expectFmt("x = [[long]]", "x = [[long]]\n");
    try expectFmt("x = 'a\\\\'", "x = \"a\\\\\"\n");
}

test "format: parentheses are removed only where redundant" {
    try expectFmt("if (a) then return ((b)) end", "if a then\n    return b\nend\n");
    try expectFmt("local x = (f())", "local x = (f())\n");
    try expectFmt("return (a and b) or c", "return (a and b) or c\n");
    try expectFmt("local s = (\"x\"):rep(3)", "local s = (\"x\"):rep(3)\n");
    try expectFmt("print((...))", "print((...))\n");
}

test "format: a semicolon is kept only before a statement starting with a paren" {
    try expectFmt("f()\n;(g or h)()", "f();\n(g or h)()\n");
    try expectFmt("local a = 1;\nlocal b = 2", "local a = 1\nlocal b = 2\n");
    try expectFmt("do end\n(f)()", "do\nend\n(f)()\n");
}

test "format: unary operators never join into a comment" {
    try expectFmt("x = - -y", "x = - -y\n");
    try expectFmt("x = not a", "x = not a\n");
    try expectFmt("x = -a + #b", "x = -a + #b\n");
}

test "format: declarations keep their attributes and types where written" {
    try expectFmt("local<const>a,b=1,2", "local <const> a, b = 1, 2\n");
    try expectFmt("local a<const>,b<close> =1,2", "local a <const>, b <close> = 1, 2\n");
    try expectFmt("local x:number=1", "local x: number = 1\n");
    try expectFmt("global x", "global x\n");
    try expectFmt("global *", "global *\n");
}

test "format: tables follow the count and simplicity rule" {
    try expectFmt("t = {}", "t = {}\n");
    try expectFmt("t = {a=1,b=2}", "t = { a = 1, b = 2 }\n");
    try expectFmt("t = {a=1,b=2,c=3,d=4,e=5}", "t = {\n    a = 1,\n    b = 2,\n    c = 3,\n    d = 4,\n    e = 5,\n}\n");
    try expectFmt("t = {{1,2},{3,4}}", "t = {\n    { 1, 2 },\n    { 3, 4 },\n}\n");
    try expectFmt("t = {1,2,3,4,5,6,7,8}", "t = { 1, 2, 3, 4, 5, 6, 7, 8 }\n");
    try expectFmt("t = {[1]=2, [k]=v;x=1}", "t = { [1] = 2, [k] = v, x = 1 }\n");
}

test "format: binary chains break before the operator" {
    try expectFmt("x = a+b*c", "x = a + b * c\n");
    try expectFmt("x = a..b..c", "x = a .. b .. c\n");
    try expectFmt("x = a^b^c", "x = a ^ b ^ c\n");
    try expectFmt("x = a-b-c", "x = a - b - c\n");
    try expectFmt(
        "local result = alpha_alpha_alpha + beta_beta_beta_beta + gamma_gamma_gamma_gamma + delta_delta_delta_delta + epsilon",
        "local result = alpha_alpha_alpha\n    + beta_beta_beta_beta\n    + gamma_gamma_gamma_gamma\n    + delta_delta_delta_delta\n    + epsilon\n",
    );
}

test "format: a last function argument hugs the call" {
    try expectFmt("f(a, function() return 1 end)", "f(a, function()\n    return 1\nend)\n");
    try expectFmt("pcall(function() x() end)", "pcall(function()\n    x()\nend)\n");
    try expectFmt("f({a=1,b=2})", "f({ a = 1, b = 2 })\n");
    try expectFmt("x:method(1, 2)", "x:method(1, 2)\n");
    try expectFmt("await task", "await task\n");
    // An empty table before the hugged one does not block the hug.
    try expectFmt(
        "setmetatable({}, {__tostring = function() return 'T' end})",
        "setmetatable({}, {\n    __tostring = function()\n        return \"T\"\n    end,\n})\n",
    );
}

test "format: line breaks inside long strings, templates and block comments come out as LF" {
    try expectFmt("local x = [[a\r\nb]]\r\n", "local x = [[a\nb]]\n");
    try expectFmt("local y = `t\r\nu`\r\n", "local y = `t\nu`\n");
    try expectFmt("--[[ a\r\n b ]]\r\nlocal z = 1\r\n", "--[[ a\n b ]]\nlocal z = 1\n");
    try expectFmt("local x = [[a\rb\n\rc]]\n", "local x = [[a\nb\nc]]\n");
}

test "format: a long method chain breaks before each link after the first call" {
    try expectFmt("a:b():c():d()", "a:b():c():d()\n");
    try expectFmt(
        "local result = builder:set_name(\"some long name here\"):set_age(1234567):set_email(\"x@example.com\"):build()",
        "local result = builder:set_name(\"some long name here\")\n    :set_age(1234567)\n    :set_email(\"x@example.com\")\n    :build()\n",
    );
    // Two calls stay on one line however long.
    try expectFmt(
        "local result = builder:set_name(\"some long name here that is long\", \"and another string here to fill the width\", 1)",
        "local result = builder:set_name(\n    \"some long name here that is long\",\n    \"and another string here to fill the width\",\n    1\n)\n",
    );
}

test "format: a name list too long for the line wraps after a comma" {
    try expectFmt("local a, b <const>, c = 1, 2, 3", "local a, b <const>, c = 1, 2, 3\n");
    try expectFmt(
        "local alpha_alpha_alpha, beta_beta_beta, gamma_gamma_gamma, delta_delta_delta, epsilon_epsilon, zeta_zeta_zeta = f()",
        "local alpha_alpha_alpha, beta_beta_beta, gamma_gamma_gamma, delta_delta_delta, epsilon_epsilon,\n    zeta_zeta_zeta = f()\n",
    );
}

test "format: comments stay with their code" {
    try expectFmt("-- header\nlocal x = 1 -- trailing\n-- above y\nlocal y = 2\n", "-- header\nlocal x = 1 -- trailing\n-- above y\nlocal y = 2\n");
    try expectFmt("a()\n\n\n-- floating\n\nb()", "a()\n\n-- floating\n\nb()\n");
    try expectFmt("if x then -- why\n  y()\n  -- last\nend", "if x then -- why\n    y()\n    -- last\nend\n");
    try expectFmt("f(\n  a, -- first\n  b\n  -- after b\n)", "f(\n    a, -- first\n    b\n    -- after b\n)\n");
    try expectFmt("t = {\n  -- lead\n  a = 1, -- one\n  b = 2,\n}", "t = {\n    -- lead\n    a = 1, -- one\n    b = 2,\n}\n");
    try expectFmt("--[[ block\n   comment ]]\nlocal x = 1", "--[[ block\n   comment ]]\nlocal x = 1\n");
    try expectFmt("f(a, --[[ inline ]] b)", "f(a, --[[ inline ]] b)\n");
    try expectFmt("-- only a comment\n", "-- only a comment\n");
}

test "format: top-level functions get a blank line around them, with their comments attached" {
    try expectFmt(
        "local a = 1\n-- doc\nfunction f() end\nlocal b = 2\n",
        "local a = 1\n\n-- doc\nfunction f()\nend\n\nlocal b = 2\n",
    );
    try expectFmt("function a() end\nfunction b() end\n", "function a()\nend\n\nfunction b()\nend\n");
}

test "format: syntax errors and unplaced comments are refused" {
    var diags = diag.Diagnostics.init(testing.allocator);
    defer diags.deinit();
    try testing.expectError(error.SyntaxError, format(testing.allocator, "local = =", &diags));
    var d2 = diag.Diagnostics.init(testing.allocator);
    defer d2.deinit();
    try testing.expectError(error.UnplacedComment, format(testing.allocator, "local x = 1 + -- no\n 2\n", &d2));
}
