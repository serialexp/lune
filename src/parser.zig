//! Recursive-descent parser with a Pratt (precedence-climbing) expression
//! parser, producing the arena-owned AST in `ast.zig`.
//!
//! Error handling: a syntax error records a diagnostic and unwinds to the
//! enclosing block via `error.ParseError`; the block loop then *synchronises*
//! (skips to the next statement boundary) and keeps going, so one bad statement
//! does not abort the whole parse. `error.OutOfMemory` propagates.
//!
//! Type annotations (`: T`) are parsed and retained but not interpreted (v1).
//! Deferred (noted, not silent): call sugar `f"s"` / `f{...}`, `goto`/labels.

const std = @import("std");
const ast = @import("ast.zig");
const token = @import("token.zig");
const lexer = @import("lexer.zig");
const numeral = @import("numeral.zig");
const Token = token.Token;
const Tag = Token.Tag;
const diag = @import("diag.zig");
const Diagnostics = diag.Diagnostics;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Span = ast.Span;

const Error = error{ ParseError, OutOfMemory };

/// Parse a whole chunk. The returned `Ast` owns an arena holding every node;
/// call `ast.Ast.deinit` to free it. Syntax errors are reported through
/// `diags`; check `diags.hasErrors()` — on error the returned tree is partial
/// but still well-formed.
pub fn parse(gpa: std.mem.Allocator, source: [:0]const u8, diags: *Diagnostics) Error!ast.Ast {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const tokens = try lexer.tokenize(a, source, diags);

    var p = Parser{
        .tokens = tokens,
        .source = source,
        .arena = a,
        .diags = diags,
    };
    const root = try p.parseChunk();

    return .{ .arena = arena, .source = source, .root = root };
}

const Parser = struct {
    tokens: []const Token,
    pos: u32 = 0,
    source: [:0]const u8,
    arena: std.mem.Allocator,
    diags: *Diagnostics,
    /// A syntax error has been reported: stray tokens after it are probably
    /// its aftermath, not new mistakes.
    had_error: bool = false,

    // -- token cursor --

    fn current(self: *const Parser) Token {
        return self.tokens[self.pos];
    }
    fn currentTag(self: *const Parser) Tag {
        return self.tokens[self.pos].tag;
    }
    fn peekAt(self: *const Parser, offset: u32) Token {
        const i = self.pos + offset;
        if (i >= self.tokens.len) return self.tokens[self.tokens.len - 1]; // eof
        return self.tokens[i];
    }
    fn advance(self: *Parser) Token {
        const t = self.tokens[self.pos];
        if (t.tag != .eof) self.pos += 1;
        return t;
    }
    fn check(self: *const Parser, tag: Tag) bool {
        return self.currentTag() == tag;
    }
    fn match(self: *Parser, tag: Tag) bool {
        if (self.check(tag)) {
            _ = self.advance();
            return true;
        }
        return false;
    }
    fn lastEnd(self: *const Parser) u32 {
        return self.tokens[self.pos - 1].end;
    }

    // -- diagnostics --

    fn fail(self: *Parser, code: diag.Code) Error {
        return self.failRelated(code, null);
    }

    /// `fail`, also pointing at `related` (the construct that is unclosed).
    fn failRelated(self: *Parser, code: diag.Code, related: ?diag.Related) Error {
        const t = self.current();
        self.diags.reportRelated(code, t.start, t.end, t.line, related);
        self.had_error = true;
        return Error.ParseError;
    }

    fn expect(self: *Parser, tag: Tag, code: diag.Code) Error!Token {
        if (self.check(tag)) return self.advance();
        return self.fail(code);
    }

    /// `expect` for the token that closes something `open` opened: a failure
    /// also points back at the opener, labelled `label` (static text).
    fn expectClosing(self: *Parser, tag: Tag, code: diag.Code, open: Token, label: []const u8) Error!Token {
        if (self.check(tag)) return self.advance();
        return self.failRelated(code, .{ .start = open.start, .end = open.end, .label = label });
    }

    // -- allocation helpers --

    fn newExpr(self: *Parser, span: Span, data: Expr.Data) Error!*Expr {
        const e = try self.arena.create(Expr);
        e.* = .{ .span = span, .data = data };
        return e;
    }
    fn spanFrom(self: *const Parser, start: u32) Span {
        return .{ .start = start, .end = self.lastEnd() };
    }
    fn tokSpan(t: Token) Span {
        return .{ .start = t.start, .end = t.end };
    }
    fn ident(self: *const Parser, t: Token) ast.Ident {
        return .{ .text = t.lexeme(self.source), .span = tokSpan(t) };
    }

    // =====================================================================
    // Blocks & statements
    // =====================================================================

    fn parseChunk(self: *Parser) Error!ast.Block {
        var stmts: std.ArrayList(Stmt) = .empty;
        while (true) {
            try stmts.appendSlice(self.arena, try self.parseBlock());
            if (self.check(.eof)) break;
            // A block-closing token with nothing to close. After an earlier
            // error it is usually that error's aftermath (a statement whose
            // header was dropped but whose `end` was not), so it is skipped
            // without a second diagnostic; the rest of the file still parses.
            const t = self.current();
            if (!self.had_error) _ = self.fail(.expected_end_of_input) catch {};
            _ = self.advance();
            try stmts.append(self.arena, .{ .span = tokSpan(t), .data = .err });
        }
        return try stmts.toOwnedSlice(self.arena);
    }

    fn atBlockEnd(self: *const Parser) bool {
        return switch (self.currentTag()) {
            .eof, .keyword_end, .keyword_else, .keyword_elseif, .keyword_until => true,
            else => false,
        };
    }

    fn parseBlock(self: *Parser) Error!ast.Block {
        var stmts: std.ArrayList(Stmt) = .empty;
        while (!self.atBlockEnd()) {
            if (self.check(.semicolon)) {
                _ = self.advance();
                continue;
            }
            const start_pos = self.pos;
            const start = self.current().start;
            if (self.check(.keyword_return)) {
                const ret = self.parseReturn() catch |e| switch (e) {
                    Error.ParseError => {
                        try stmts.append(self.arena, try self.dropped(start_pos, start));
                        continue;
                    },
                    else => return e,
                };
                try stmts.append(self.arena, ret);
                break; // `return` ends the block
            }
            const stmt = self.parseStatement() catch |e| switch (e) {
                Error.ParseError => {
                    try stmts.append(self.arena, try self.dropped(start_pos, start));
                    continue;
                },
                else => return e,
            };
            try stmts.append(self.arena, stmt);
        }
        return try stmts.toOwnedSlice(self.arena);
    }

    /// The statement that began at token `start_pos` (source offset `start`)
    /// failed: skip to a boundary and stand an error node over what was lost.
    fn dropped(self: *Parser, start_pos: u32, start: u32) Error!Stmt {
        return .{ .span = self.synchronize(start_pos, start), .data = .err };
    }

    /// Skip tokens until a plausible statement boundary so parsing can resume
    /// after an error, and return the span skipped, from `start`. Always makes
    /// progress: if nothing was consumed since `floor_pos` (the token the
    /// failed construct began at) the current token is skipped even if it
    /// would be a boundary; otherwise a boundary token is left for the next
    /// statement, so `local x =` followed by `local y = 1` keeps the second.
    fn synchronize(self: *Parser, floor_pos: u32, start: u32) Span {
        const error_line = self.current().line;
        if (self.pos == floor_pos and !self.check(.eof)) _ = self.advance();
        self.skipToBoundary(error_line);
        return .{ .start = start, .end = @max(start, self.lastEnd()) };
    }

    /// `error_line` is the line the error was found on: an identifier on a
    /// later line is taken to begin the next statement (`print(2)` after a
    /// broken line), which no keyword announces. A statement continued over
    /// several lines can make this stop early; the extra node is an error
    /// node, not a changed meaning.
    fn skipToBoundary(self: *Parser, error_line: u32) void {
        while (!self.check(.eof)) {
            // Stop *before* a token that can begin (or end) a statement.
            switch (self.currentTag()) {
                .identifier => {
                    if (self.current().line > error_line) return;
                    _ = self.advance();
                },
                .semicolon => {
                    _ = self.advance();
                    return;
                },
                .keyword_local,
                .keyword_if,
                .keyword_while,
                .keyword_repeat,
                .keyword_for,
                .keyword_function,
                .keyword_async,
                .keyword_await,
                .keyword_do,
                .keyword_return,
                .keyword_break,
                .keyword_end,
                .keyword_else,
                .keyword_elseif,
                => return,
                else => _ = self.advance(),
            }
        }
    }

    fn parseStatement(self: *Parser) Error!Stmt {
        return switch (self.currentTag()) {
            .keyword_local => self.parseLocal(),
            .keyword_if => self.parseIf(),
            .keyword_while => self.parseWhile(),
            .keyword_repeat => self.parseRepeat(),
            .keyword_for => self.parseFor(),
            .keyword_do => self.parseDo(),
            .keyword_function => self.parseFunctionDecl(false),
            .keyword_async => blk: {
                // Doc 73 §7: `async function a.b:c(...) ... end`.
                const start = self.advance().start;
                if (!self.check(.keyword_function)) break :blk self.fail(.expected_function_after_async);
                var s = try self.parseFunctionDecl(true);
                s.span.start = start;
                break :blk s;
            },
            // Doc 73 §7: `await e` is a call, so it is a statement too.
            .keyword_await => blk: {
                const start = self.current().start;
                const e = try self.parseExpr(0);
                if (!e.isCall()) break :blk self.fail(.expected_statement);
                break :blk Stmt{ .span = self.spanFrom(start), .data = .{ .call = e } };
            },
            .keyword_break => blk: {
                const t = self.advance();
                break :blk Stmt{ .span = .{ .start = t.start, .end = t.end }, .data = .break_ };
            },
            else => self.parseExprStatement(),
        };
    }

    fn parseLocal(self: *Parser) Error!Stmt {
        const local_pos = self.pos;
        const start = self.advance().start; // 'local'

        const is_async = self.match(.keyword_async);
        if (is_async and !self.check(.keyword_function)) return self.fail(.expected_function_after_async);
        const fn_tok = self.current();
        if (self.match(.keyword_function)) {
            const name_tok = try self.expect(.identifier, .expected_function_name);
            const body = try self.parseFunctionBody(fn_tok);
            body.is_async = is_async;
            return .{
                .span = self.spanFrom(start),
                .data = .{ .local_function = .{ .name = name_tok.lexeme(self.source), .name_span = tokSpan(name_tok), .body = body } },
            };
        }

        var names: std.ArrayList(ast.TypedName) = .empty;
        while (true) {
            const name_tok = try self.expect(.identifier, .expected_variable_name);
            const ty = try self.parseOptionalType();
            try names.append(self.arena, .{
                .name = name_tok.lexeme(self.source),
                .name_span = .{ .start = name_tok.start, .end = name_tok.end },
                .type = ty,
            });
            if (!self.match(.comma)) break;
        }

        var values: []const *Expr = &.{};
        if (self.match(.assign)) {
            const value_start = self.current().start;
            values = self.parseExprList() catch |e| switch (e) {
                Error.ParseError => blk: {
                    // The names parsed, so keep the declaration: dropping it
                    // would turn every later use of them into a global.
                    const skipped = self.synchronize(local_pos, value_start);
                    const lost = try self.newExpr(skipped, .err);
                    const one = try self.arena.alloc(*Expr, 1);
                    one[0] = lost;
                    break :blk one;
                },
                else => return e,
            };
        }

        return .{
            .span = self.spanFrom(start),
            .data = .{ .local = .{ .names = try names.toOwnedSlice(self.arena), .values = values } },
        };
    }

    /// Map a compound-assignment operator token to its underlying binary op, or
    /// null if the token is not a compound-assign operator. `~=` (`.ne`) is the
    /// special case: in statement context — right after an lvalue — it is
    /// xor-assign (`bxor`), NOT the inequality comparison (which only ever occurs
    /// in expression context). The deliberately-absent `^=` has no token at all.
    fn compoundAssignOp(tag: Tag) ?ast.BinaryOp {
        return switch (tag) {
            .plus_assign => .add,
            .minus_assign => .sub,
            .star_assign => .mul,
            .slash_assign => .div,
            .slash_slash_assign => .idiv,
            .percent_assign => .mod,
            .amp_assign => .band,
            .pipe_assign => .bor,
            .ne => .bxor, // `~=` in statement context = xor-assign
            .lshift_assign => .shl,
            .rshift_assign => .shr,
            .rshift_arith_assign => .sar,
            .concat_assign => .concat,
            else => null,
        };
    }

    fn parseExprStatement(self: *Parser) Error!Stmt {
        const start = self.current().start;
        const first = try self.parseSuffixed();

        // Compound assignment `target OP= value` (single target). Detected before
        // the plain `=`/`,` assignment because `~=` (xor-assign) shares the `ne`
        // token with inequality — here, right after an lvalue, it is xor-assign.
        if (compoundAssignOp(self.current().tag)) |op| {
            if (!first.isAssignable()) {
                self.diags.report(.cannot_assign, first.span.start, first.span.end, 0);
                return Error.ParseError;
            }
            _ = self.advance(); // the compound-assign operator
            const value = try self.parseExpr(0);
            return .{
                .span = self.spanFrom(start),
                .data = .{ .compound_assign = .{ .target = first, .op = op, .value = value } },
            };
        }

        if (self.check(.assign) or self.check(.comma)) {
            var targets: std.ArrayList(*Expr) = .empty;
            try targets.append(self.arena, first);
            while (self.match(.comma)) {
                try targets.append(self.arena, try self.parseSuffixed());
            }
            _ = try self.expect(.assign, .expected_assign);
            const values = try self.parseExprList();
            for (targets.items) |t| {
                if (!t.isAssignable()) {
                    self.diags.report(.cannot_assign, t.span.start, t.span.end, 0);
                    return Error.ParseError;
                }
            }
            return .{
                .span = self.spanFrom(start),
                .data = .{ .assign = .{ .targets = try targets.toOwnedSlice(self.arena), .values = values } },
            };
        }

        if (!first.isCall()) return self.fail(.expected_statement);
        return .{ .span = self.spanFrom(start), .data = .{ .call = first } };
    }

    fn parseIf(self: *Parser) Error!Stmt {
        const open = self.advance(); // 'if'
        const start = open.start;
        var branches: std.ArrayList(Stmt.Branch) = .empty;

        const cond = try self.parseExpr(0);
        _ = try self.expect(.keyword_then, .expected_then);
        try branches.append(self.arena, .{ .kw_start = open.start, .cond = cond, .body = try self.parseBlock() });

        while (self.check(.keyword_elseif)) {
            const kw = self.advance();
            const c = try self.parseExpr(0);
            _ = try self.expect(.keyword_then, .expected_then);
            try branches.append(self.arena, .{ .kw_start = kw.start, .cond = c, .body = try self.parseBlock() });
        }

        var else_body: ?ast.Block = null;
        var else_start: u32 = 0;
        if (self.check(.keyword_else)) {
            else_start = self.advance().start;
            else_body = try self.parseBlock();
        }

        _ = try self.expectClosing(.keyword_end, .expected_end_if, open, "'if' opened here");
        return .{
            .span = self.spanFrom(start),
            .data = .{ .if_ = .{ .branches = try branches.toOwnedSlice(self.arena), .else_body = else_body, .else_start = else_start } },
        };
    }

    fn parseWhile(self: *Parser) Error!Stmt {
        const open = self.advance(); // 'while'
        const start = open.start;
        const cond = try self.parseExpr(0);
        _ = try self.expect(.keyword_do, .expected_do);
        const body = try self.parseBlock();
        _ = try self.expectClosing(.keyword_end, .expected_end_while, open, "'while' opened here");
        return .{ .span = self.spanFrom(start), .data = .{ .while_ = .{ .cond = cond, .body = body } } };
    }

    fn parseRepeat(self: *Parser) Error!Stmt {
        const open = self.advance(); // 'repeat'
        const start = open.start;
        const body = try self.parseBlock();
        _ = try self.expectClosing(.keyword_until, .expected_until, open, "'repeat' opened here");
        // The condition is parsed (and later compiled) in the body's scope: Lua
        // permits `until` to reference locals declared inside the loop body.
        const cond = try self.parseExpr(0);
        return .{ .span = self.spanFrom(start), .data = .{ .repeat = .{ .body = body, .cond = cond } } };
    }

    fn parseFor(self: *Parser) Error!Stmt {
        const open = self.advance(); // 'for'
        const start = open.start;
        const first_name = try self.expect(.identifier, .expected_loop_variable);

        if (self.match(.assign)) {
            // numeric for: for i = start, stop [, step] do ... end
            const start_expr = try self.parseExpr(0);
            _ = try self.expect(.comma, .expected_comma_after_for_start);
            const stop_expr = try self.parseExpr(0);
            var step: ?*Expr = null;
            if (self.match(.comma)) step = try self.parseExpr(0);
            _ = try self.expect(.keyword_do, .expected_do);
            const body = try self.parseBlock();
            _ = try self.expectClosing(.keyword_end, .expected_end_for, open, "'for' opened here");
            return .{ .span = self.spanFrom(start), .data = .{ .numeric_for = .{
                .name = first_name.lexeme(self.source),
                .name_span = tokSpan(first_name),
                .start = start_expr,
                .stop = stop_expr,
                .step = step,
                .body = body,
            } } };
        }

        // generic for: for a, b in explist do ... end
        var names: std.ArrayList(ast.Ident) = .empty;
        try names.append(self.arena, self.ident(first_name));
        while (self.match(.comma)) {
            const n = try self.expect(.identifier, .expected_loop_variable);
            try names.append(self.arena, self.ident(n));
        }
        _ = try self.expect(.keyword_in, .expected_in);
        const exprs = try self.parseExprList();
        _ = try self.expect(.keyword_do, .expected_do);
        const body = try self.parseBlock();
        _ = try self.expectClosing(.keyword_end, .expected_end_for, open, "'for' opened here");
        return .{ .span = self.spanFrom(start), .data = .{ .generic_for = .{
            .names = try names.toOwnedSlice(self.arena),
            .exprs = exprs,
            .body = body,
        } } };
    }

    fn parseDo(self: *Parser) Error!Stmt {
        const open = self.advance(); // 'do'
        const start = open.start;
        const body = try self.parseBlock();
        _ = try self.expectClosing(.keyword_end, .expected_end_do, open, "'do' opened here");
        return .{ .span = self.spanFrom(start), .data = .{ .do = body } };
    }

    fn parseFunctionDecl(self: *Parser, is_async: bool) Error!Stmt {
        const fn_tok = self.advance(); // 'function'
        const start = fn_tok.start;
        var path: std.ArrayList(ast.Ident) = .empty;
        const first = try self.expect(.identifier, .expected_function_name);
        try path.append(self.arena, self.ident(first));
        while (self.match(.dot)) {
            const n = try self.expect(.identifier, .expected_name_after_dot);
            try path.append(self.arena, self.ident(n));
        }
        var method: ?ast.Ident = null;
        if (self.match(.colon)) {
            const m = try self.expect(.identifier, .expected_method_name);
            method = self.ident(m);
        }

        const body = try self.parseFunctionBody(fn_tok);
        body.is_async = is_async;
        // A method `a:m` gets an implicit leading `self` parameter.
        const final_body = if (method) |m| try self.prependSelf(body, m.span.start) else body;

        return .{ .span = self.spanFrom(start), .data = .{ .function_decl = .{
            .name = .{ .path = try path.toOwnedSlice(self.arena), .method = method },
            .body = final_body,
        } } };
    }

    /// `at` is where `self` would be written if it were: the method name's start,
    /// as a zero-width span, so no navigation lands on the whole function.
    fn prependSelf(self: *Parser, body: *ast.FunctionBody, at: u32) Error!*ast.FunctionBody {
        var params: std.ArrayList(ast.Param) = .empty;
        try params.append(self.arena, .{ .name = "self", .name_span = .{ .start = at, .end = at }, .type = null });
        try params.appendSlice(self.arena, body.params);
        body.params = try params.toOwnedSlice(self.arena);
        return body;
    }

    fn parseReturn(self: *Parser) Error!Stmt {
        const start = self.advance().start; // 'return'
        var values: []const *Expr = &.{};
        if (!self.atBlockEnd() and !self.check(.semicolon)) {
            values = try self.parseExprList();
        }
        _ = self.match(.semicolon);
        return .{ .span = self.spanFrom(start), .data = .{ .return_ = values } };
    }

    // =====================================================================
    // Function bodies, params, types
    // =====================================================================

    /// Parse `( params ) [: rettype] block end`. Assumes the name/keyword before
    /// the `(` was already consumed.
    fn parseFunctionBody(self: *Parser, open: Token) Error!*ast.FunctionBody {
        const start = self.current().start;
        _ = try self.expect(.lparen, .expected_lparen_params);

        var params: std.ArrayList(ast.Param) = .empty;
        var is_vararg = false;
        if (!self.check(.rparen)) {
            while (true) {
                if (self.match(.ellipsis)) {
                    is_vararg = true;
                    break;
                }
                const name_tok = try self.expect(.identifier, .expected_param_name);
                const ty = try self.parseOptionalType();
                try params.append(self.arena, .{
                    .name = name_tok.lexeme(self.source),
                    .name_span = .{ .start = name_tok.start, .end = name_tok.end },
                    .type = ty,
                });
                if (!self.match(.comma)) break;
            }
        }
        _ = try self.expect(.rparen, .expected_rparen_params);

        const ret_type = try self.parseOptionalType();
        const body = try self.parseBlock();
        _ = try self.expectClosing(.keyword_end, .expected_end_function, open, "'function' opened here");

        const fb = try self.arena.create(ast.FunctionBody);
        fb.* = .{
            .span = self.spanFrom(start),
            .params = try params.toOwnedSlice(self.arena),
            .is_vararg = is_vararg,
            .ret_type = ret_type,
            .body = body,
        };
        return fb;
    }

    /// `: TypeName(.TypeName)* '?'?` — reserved, unchecked. Returns null if there
    /// is no `:` annotation.
    fn parseOptionalType(self: *Parser) Error!?*ast.TypeExpr {
        if (!self.match(.colon)) return null;
        const start = self.current().start;
        var path: std.ArrayList([]const u8) = .empty;
        const first = try self.expect(.identifier, .expected_type_name);
        try path.append(self.arena, first.lexeme(self.source));
        while (self.match(.dot)) {
            const n = try self.expect(.identifier, .expected_type_name_after_dot);
            try path.append(self.arena, n.lexeme(self.source));
        }
        const is_opt = self.matchOptionalMarker();
        const te = try self.arena.create(ast.TypeExpr);
        te.* = .{
            .span = self.spanFrom(start),
            .path = try path.toOwnedSlice(self.arena),
            .optional = is_opt,
        };
        return te;
    }

    /// Optional-type marker `?`. We don't have a dedicated `?` token, so it is
    /// not yet expressible; reserved for when the type syntax grows. Always
    /// false for now (kept as a seam).
    fn matchOptionalMarker(self: *Parser) bool {
        _ = self;
        return false;
    }

    // =====================================================================
    // Expressions (Pratt)
    // =====================================================================

    const BindInfo = struct { op: ast.BinaryOp, l: u8, r: u8 };

    fn infixBp(tag: Tag) ?BindInfo {
        return switch (tag) {
            .keyword_or => .{ .op = .or_, .l = 2, .r = 3 },
            // `??` sits at the `or` level, left-associative (same binding powers).
            .question_question => .{ .op = .coalesce, .l = 2, .r = 3 },
            .keyword_and => .{ .op = .and_, .l = 4, .r = 5 },
            .lt => .{ .op = .lt, .l = 6, .r = 7 },
            .gt => .{ .op = .gt, .l = 6, .r = 7 },
            .le => .{ .op = .le, .l = 6, .r = 7 },
            .ge => .{ .op = .ge, .l = 6, .r = 7 },
            .ne => .{ .op = .ne, .l = 6, .r = 7 },
            .eq => .{ .op = .eq, .l = 6, .r = 7 },
            .pipe => .{ .op = .bor, .l = 8, .r = 9 },
            .tilde => .{ .op = .bxor, .l = 10, .r = 11 },
            .ampersand => .{ .op = .band, .l = 12, .r = 13 },
            .lshift => .{ .op = .shl, .l = 14, .r = 15 },
            .rshift => .{ .op = .shr, .l = 14, .r = 15 },
            .rshift_arith => .{ .op = .sar, .l = 14, .r = 15 },
            // concat is right-associative: l > r.
            .dot_dot => .{ .op = .concat, .l = 17, .r = 16 },
            .plus => .{ .op = .add, .l = 18, .r = 19 },
            .minus => .{ .op = .sub, .l = 18, .r = 19 },
            .star => .{ .op = .mul, .l = 20, .r = 21 },
            .slash => .{ .op = .div, .l = 20, .r = 21 },
            .slash_slash => .{ .op = .idiv, .l = 20, .r = 21 },
            .percent => .{ .op = .mod, .l = 20, .r = 21 },
            // pow is right-associative and binds tighter than unary (rbp 22).
            .caret => .{ .op = .pow, .l = 25, .r = 24 },
            else => null,
        };
    }

    /// Binding power that a unary prefix operator imposes on its operand.
    const unary_bp: u8 = 22;

    fn parseExpr(self: *Parser, min_bp: u8) Error!*Expr {
        var lhs = try self.parseUnary();
        while (infixBp(self.currentTag())) |info| {
            if (info.l < min_bp) break;
            _ = self.advance();
            const rhs = try self.parseExpr(info.r);
            lhs = try self.newExpr(
                .{ .start = lhs.span.start, .end = rhs.span.end },
                .{ .binary = .{ .op = info.op, .lhs = lhs, .rhs = rhs } },
            );
        }
        return lhs;
    }

    fn parseUnary(self: *Parser) Error!*Expr {
        const t = self.current();
        const uop: ?ast.UnaryOp = switch (t.tag) {
            .minus => .neg,
            .keyword_not => .not,
            .hash => .len,
            .tilde => .bnot,
            else => null,
        };
        if (uop) |op| {
            _ = self.advance();
            const operand = try self.parseExpr(unary_bp);
            return self.newExpr(
                .{ .start = t.start, .end = operand.span.end },
                .{ .unary = .{ .op = op, .operand = operand } },
            );
        }
        if (t.tag == .keyword_await) {
            // Doc 73 §7: `await e` binds as a unary operator and is the call
            // `task_await(e)`, so it is a statement and yields what the
            // task returned, as many values as a call.
            _ = self.advance();
            const operand = try self.parseExpr(unary_bp);
            const span: ast.Span = .{ .start = t.start, .end = operand.span.end };
            const callee = try self.newExpr(.{ .start = t.start, .end = t.end }, .{ .intrinsic = .task_await });
            const args = try self.arena.alloc(*Expr, 1);
            args[0] = operand;
            return self.newExpr(span, .{ .call = .{ .callee = callee, .args = args } });
        }
        return self.parseSuffixed();
    }

    fn parseSuffixed(self: *Parser) Error!*Expr {
        var e = try self.parsePrimary();
        while (true) {
            switch (self.currentTag()) {
                .dot => {
                    _ = self.advance();
                    const name_tok = try self.expect(.identifier, .expected_field_name);
                    e = try self.newExpr(
                        .{ .start = e.span.start, .end = name_tok.end },
                        .{ .field = .{ .obj = e, .name = name_tok.lexeme(self.source), .name_span = tokSpan(name_tok) } },
                    );
                },
                .lbracket => {
                    _ = self.advance();
                    const key = try self.parseExpr(0);
                    const close = try self.expect(.rbracket, .expected_rbracket);
                    e = try self.newExpr(
                        .{ .start = e.span.start, .end = close.end },
                        .{ .index = .{ .obj = e, .key = key } },
                    );
                },
                .lparen => {
                    const args = try self.parseCallArgs();
                    e = try self.newExpr(
                        .{ .start = e.span.start, .end = self.lastEnd() },
                        .{ .call = .{ .callee = e, .args = args } },
                    );
                },
                .colon => {
                    _ = self.advance();
                    const name_tok = try self.expect(.identifier, .expected_method_name);
                    const args = try self.parseCallArgs();
                    e = try self.newExpr(
                        .{ .start = e.span.start, .end = self.lastEnd() },
                        .{ .method_call = .{ .obj = e, .name = name_tok.lexeme(self.source), .name_span = tokSpan(name_tok), .args = args } },
                    );
                },
                else => break,
            }
        }
        return e;
    }

    /// `( args )` — consumes the parentheses. Call sugar (`f"s"`, `f{...}`) is
    /// deferred.
    fn parseCallArgs(self: *Parser) Error![]const *Expr {
        const open = try self.expect(.lparen, .expected_lparen_args);
        if (self.match(.rparen)) return &.{};
        const args = try self.parseExprList();
        _ = try self.expectClosing(.rparen, .expected_rparen_args, open, "'(' opened here");
        return args;
    }

    fn parseExprList(self: *Parser) Error![]const *Expr {
        var list: std.ArrayList(*Expr) = .empty;
        try list.append(self.arena, try self.parseExpr(0));
        while (self.match(.comma)) {
            try list.append(self.arena, try self.parseExpr(0));
        }
        return try list.toOwnedSlice(self.arena);
    }

    fn parsePrimary(self: *Parser) Error!*Expr {
        const t = self.current();
        switch (t.tag) {
            .keyword_nil => {
                _ = self.advance();
                return self.newExpr(.{ .start = t.start, .end = t.end }, .nil);
            },
            .keyword_true => {
                _ = self.advance();
                return self.newExpr(.{ .start = t.start, .end = t.end }, .{ .bool = true });
            },
            .keyword_false => {
                _ = self.advance();
                return self.newExpr(.{ .start = t.start, .end = t.end }, .{ .bool = false });
            },
            .int_literal, .float_literal => {
                _ = self.advance();
                return self.newExpr(.{ .start = t.start, .end = t.end }, try self.parseNumber(t));
            },
            .string_literal => {
                _ = self.advance();
                return self.newExpr(.{ .start = t.start, .end = t.end }, .{ .string_raw = t.lexeme(self.source) });
            },
            .ellipsis => {
                _ = self.advance();
                return self.newExpr(.{ .start = t.start, .end = t.end }, .vararg);
            },
            .identifier => {
                _ = self.advance();
                return self.newExpr(.{ .start = t.start, .end = t.end }, .{ .name = t.lexeme(self.source) });
            },
            .lparen => {
                _ = self.advance();
                const inner = try self.parseExpr(0);
                const close = try self.expectClosing(.rparen, .expected_rparen, t, "'(' opened here");
                return self.newExpr(.{ .start = t.start, .end = close.end }, .{ .paren = inner });
            },
            .lbrace => return self.parseTable(),
            .keyword_function => {
                const fn_tok = self.advance();
                const body = try self.parseFunctionBody(fn_tok);
                return self.newExpr(body.span, .{ .function = body });
            },
            .keyword_async => {
                _ = self.advance();
                if (!self.check(.keyword_function)) return self.fail(.expected_function_after_async);
                const fn_tok = self.advance();
                const body = try self.parseFunctionBody(fn_tok);
                body.is_async = true;
                return self.newExpr(.{ .start = t.start, .end = body.span.end }, .{ .function = body });
            },
            else => return self.fail(.expected_expression),
        }
    }

    fn failAtToken(self: *Parser, t: Token, code: diag.Code) Error {
        self.diags.report(code, t.start, t.end, t.line);
        return Error.ParseError;
    }

    /// A numeric literal's value, read as Lua reads it (`numeral.parse`, the
    /// lexer's classifier): hex integers wrap, a decimal integer too big for
    /// `i64` is a float, and floats may be hex (`0x1.8p+1`).
    fn parseNumber(self: *Parser, t: Token) Error!Expr.Data {
        return switch (numeral.parse(t.lexeme(self.source)) orelse return self.failAtToken(t, .malformed_number)) {
            .int => |i| .{ .int = i },
            .float => |f| .{ .float = f },
        };
    }

    fn parseTable(self: *Parser) Error!*Expr {
        const open = self.advance(); // '{'
        const start = open.start;
        var fields: std.ArrayList(ast.TableField) = .empty;
        while (!self.check(.rbrace)) {
            if (self.check(.lbracket)) {
                _ = self.advance();
                const key = try self.parseExpr(0);
                _ = try self.expect(.rbracket, .expected_rbracket_key);
                _ = try self.expect(.assign, .expected_assign_after_key);
                const value = try self.parseExpr(0);
                try fields.append(self.arena, .{ .keyed = .{ .key = key, .value = value } });
            } else if (self.check(.identifier) and self.peekAt(1).tag == .assign) {
                const name_tok = self.advance();
                _ = self.advance(); // '='
                const value = try self.parseExpr(0);
                try fields.append(self.arena, .{ .named = .{ .name = name_tok.lexeme(self.source), .name_span = tokSpan(name_tok), .value = value } });
            } else {
                const value = try self.parseExpr(0);
                try fields.append(self.arena, .{ .positional = value });
            }
            if (!self.match(.comma) and !self.match(.semicolon)) break;
        }
        const close = try self.expectClosing(.rbrace, .expected_rbrace, open, "'{' opened here");
        return self.newExpr(.{ .start = start, .end = close.end }, .{ .table = try fields.toOwnedSlice(self.arena) });
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Parse `src`, assert no diagnostics, and return the owned AST.
fn parseOk(src: [:0]const u8) !ast.Ast {
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    const tree = try parse(testing.allocator, src, &diags);
    errdefer {
        var t = tree;
        t.deinit();
    }
    try testing.expect(!diags.hasErrors());
    return tree;
}

test "local declaration with int value" {
    var tree = try parseOk("local x = 42");
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 1), tree.root.len);
    const local = tree.root[0].data.local;
    try testing.expectEqual(@as(usize, 1), local.names.len);
    try testing.expectEqualStrings("x", local.names[0].name);
    try testing.expectEqual(@as(i64, 42), local.values[0].data.int);
}

test "arithmetic precedence: 1 + 2 * 3 = add(1, mul(2,3))" {
    var tree = try parseOk("local r = 1 + 2 * 3");
    defer tree.deinit();
    const top = tree.root[0].data.local.values[0];
    try testing.expectEqual(ast.BinaryOp.add, top.data.binary.op);
    try testing.expectEqual(@as(i64, 1), top.data.binary.lhs.data.int);
    const rhs = top.data.binary.rhs;
    try testing.expectEqual(ast.BinaryOp.mul, rhs.data.binary.op);
}

test "concat is right-associative" {
    var tree = try parseOk("local r = a .. b .. c");
    defer tree.deinit();
    const top = tree.root[0].data.local.values[0];
    try testing.expectEqual(ast.BinaryOp.concat, top.data.binary.op);
    // a .. (b .. c): the rhs is itself a concat.
    try testing.expectEqualStrings("a", top.data.binary.lhs.data.name);
    try testing.expectEqual(ast.BinaryOp.concat, top.data.binary.rhs.data.binary.op);
}

test "unary minus vs pow: -2^2 = neg(pow(2,2))" {
    var tree = try parseOk("local r = -2^2");
    defer tree.deinit();
    const top = tree.root[0].data.local.values[0];
    try testing.expectEqual(ast.UnaryOp.neg, top.data.unary.op);
    try testing.expectEqual(ast.BinaryOp.pow, top.data.unary.operand.data.binary.op);
}

test "multiple assignment" {
    var tree = try parseOk("x, y = 1, 2");
    defer tree.deinit();
    const a = tree.root[0].data.assign;
    try testing.expectEqual(@as(usize, 2), a.targets.len);
    try testing.expectEqual(@as(usize, 2), a.values.len);
    try testing.expectEqualStrings("x", a.targets[0].data.name);
}

test "compound assignment desugars to a compound_assign node with the right op" {
    var tree = try parseOk(
        \\a += 1
        \\t[k] ~>>= 2
        \\o.n ~= 3
    );
    defer tree.deinit();
    const a = tree.root[0].data.compound_assign;
    try testing.expectEqual(ast.BinaryOp.add, a.op);
    try testing.expectEqualStrings("a", a.target.data.name);

    const b = tree.root[1].data.compound_assign;
    try testing.expectEqual(ast.BinaryOp.sar, b.op);
    try testing.expect(b.target.data == .index);

    // `~=` as a statement operator is xor-assign, not inequality.
    const c = tree.root[2].data.compound_assign;
    try testing.expectEqual(ast.BinaryOp.bxor, c.op);
    try testing.expect(c.target.data == .field);
}

test "if / elseif / else" {
    var tree = try parseOk(
        \\if a then
        \\  b()
        \\elseif c then
        \\  d()
        \\else
        \\  e()
        \\end
    );
    defer tree.deinit();
    const s = tree.root[0].data.if_;
    try testing.expectEqual(@as(usize, 2), s.branches.len);
    try testing.expect(s.else_body != null);
}

test "numeric and generic for" {
    var tree = try parseOk(
        \\for i = 1, 10, 2 do x() end
        \\for k, v in pairs(t) do y() end
    );
    defer tree.deinit();
    const nf = tree.root[0].data.numeric_for;
    try testing.expectEqualStrings("i", nf.name);
    try testing.expect(nf.step != null);
    const gf = tree.root[1].data.generic_for;
    try testing.expectEqual(@as(usize, 2), gf.names.len);
    try testing.expectEqualStrings("v", gf.names[1].text);
}

test "method declaration gets implicit self" {
    var tree = try parseOk("function obj:greet(name) return name end");
    defer tree.deinit();
    const fd = tree.root[0].data.function_decl;
    try testing.expectEqual(@as(usize, 1), fd.name.path.len);
    try testing.expectEqualStrings("obj", fd.name.path[0].text);
    try testing.expectEqualStrings("greet", fd.name.method.?.text);
    // self prepended before the declared param.
    try testing.expectEqual(@as(usize, 2), fd.body.params.len);
    try testing.expectEqualStrings("self", fd.body.params[0].name);
    try testing.expectEqualStrings("name", fd.body.params[1].name);
}

test "call, method call, field and index chaining" {
    var tree = try parseOk("a.b[c](d):m(e)");
    defer tree.deinit();
    const call = tree.root[0].data.call; // outermost is the method call
    const mc = call.data.method_call;
    try testing.expectEqualStrings("m", mc.name);
    try testing.expectEqual(@as(usize, 1), mc.args.len);
    // receiver is a call: a.b[c](d)
    try testing.expect(mc.obj.data == .call);
}

test "type annotations are parsed and retained (unchecked)" {
    var tree = try parseOk("local x: Foo.Bar = 1");
    defer tree.deinit();
    const local = tree.root[0].data.local;
    const ty = local.names[0].type.?;
    try testing.expectEqual(@as(usize, 2), ty.path.len);
    try testing.expectEqualStrings("Foo", ty.path[0]);
    try testing.expectEqualStrings("Bar", ty.path[1]);
}

test "function literal with vararg and table constructor" {
    var tree = try parseOk("local f = function(a, ...) return {1, x = 2, [k] = 3} end");
    defer tree.deinit();
    const fb = tree.root[0].data.local.values[0].data.function;
    try testing.expect(fb.is_vararg);
    try testing.expectEqual(@as(usize, 1), fb.params.len);
    const ret = fb.body[0].data.return_;
    const tbl = ret[0].data.table;
    try testing.expectEqual(@as(usize, 3), tbl.len);
    try testing.expect(tbl[0] == .positional);
    try testing.expect(tbl[1] == .named);
    try testing.expect(tbl[2] == .keyed);
}

test "hex int wraps, big decimal promotes to float" {
    var tree = try parseOk("local a, b = 0xFFFFFFFFFFFFFFFF, 99999999999999999999999");
    defer tree.deinit();
    const vals = tree.root[0].data.local.values;
    try testing.expectEqual(@as(i64, -1), vals[0].data.int); // wrapped
    try testing.expect(vals[1].data == .float); // promoted
}

test "doc 73 §7: async marks function bodies, and await is a call of the await intrinsic" {
    var tree = try parseOk(
        \\async function a.b:c(x) end
        \\local async function f(...) end
        \\local g = async function() end
        \\await f(1)
        \\local v = await g() + 1
    );
    defer tree.deinit();
    const decl = tree.root[0].data.function_decl;
    try testing.expect(decl.body.is_async);
    try testing.expectEqualStrings("self", decl.body.params[0].name);
    try testing.expect(tree.root[1].data.local_function.body.is_async);
    try testing.expect(tree.root[2].data.local.values[0].data.function.is_async);
    const stmt = tree.root[3].data.call.data.call;
    try testing.expectEqual(ast.Intrinsic.task_await, stmt.callee.data.intrinsic);
    try testing.expect(stmt.args[0].data == .call);
    // `await` binds as a unary operator: `(await g()) + 1`.
    const sum = tree.root[4].data.local.values[0].data.binary;
    try testing.expectEqual(ast.BinaryOp.add, sum.op);
    try testing.expectEqual(ast.Intrinsic.task_await, sum.lhs.data.call.callee.data.intrinsic);
}

test "doc 73 §7: async and await are reserved, and async takes a function" {
    for ([_][:0]const u8{ "local async = 1", "local t = { await = 1 }.await", "await = 2", "async local x = 1", "local async x = 1", "local f = async 1", "await x + 1" }) |src| {
        var diags = Diagnostics.init(testing.allocator);
        defer diags.deinit();
        var tree = try parse(testing.allocator, src, &diags);
        defer tree.deinit();
        try testing.expect(diags.hasErrors());
    }
}

test "error recovery: bad statement, then a good one" {
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    var tree = try parse(testing.allocator, "local = 5\nlocal y = 7", &diags);
    defer tree.deinit();
    try testing.expect(diags.hasErrors());
    // Recovered and parsed the second statement.
    var found_y = false;
    for (tree.root) |s| {
        if (s.data == .local and s.data.local.names.len == 1 and
            std.mem.eql(u8, s.data.local.names[0].name, "y")) found_y = true;
    }
    try testing.expect(found_y);
}


/// The source text a span covers.
fn spanText(src: []const u8, sp: ast.Span) []const u8 {
    return src[sp.start..sp.end];
}

test "doc 74 P1a: every declared or accessed name carries its own span" {
    const src =
        \\local function f() end
        \\for i = 1, 2 do end
        \\for k, v in pairs(t) do end
        \\function a.b:m() end
        \\local t = { key = 1 }
        \\t.fld = o:meth()
    ;
    var tree = try parseOk(src);
    defer tree.deinit();

    try testing.expectEqualStrings("f", spanText(src, tree.root[0].data.local_function.name_span));
    try testing.expectEqualStrings("i", spanText(src, tree.root[1].data.numeric_for.name_span));

    const gf = tree.root[2].data.generic_for;
    try testing.expectEqualStrings("k", spanText(src, gf.names[0].span));
    try testing.expectEqualStrings("v", spanText(src, gf.names[1].span));

    const fd = tree.root[3].data.function_decl;
    try testing.expectEqualStrings("a", spanText(src, fd.name.path[0].span));
    try testing.expectEqualStrings("b", spanText(src, fd.name.path[1].span));
    try testing.expectEqualStrings("m", spanText(src, fd.name.method.?.span));

    const fields = tree.root[4].data.local.values[0].data.table;
    try testing.expectEqualStrings("key", spanText(src, fields[0].named.name_span));

    const assign = tree.root[5].data.assign;
    try testing.expectEqualStrings("fld", spanText(src, assign.targets[0].data.field.name_span));
    const call = assign.values[0].data.method_call;
    try testing.expectEqualStrings("meth", spanText(src, call.name_span));
}

test "doc 74 P1a: the implicit self of a method is a zero-width span at the method name" {
    const src = "function obj:greet(name) end";
    var tree = try parseOk(src);
    defer tree.deinit();
    const params = tree.root[0].data.function_decl.body.params;
    try testing.expectEqualStrings("self", params[0].name);
    const at = std.mem.find(u8, src, "greet").?;
    try testing.expectEqual(ast.Span{ .start = @intCast(at), .end = @intCast(at) }, params[0].name_span);
    // The declared parameter keeps its own span.
    try testing.expectEqualStrings("name", spanText(src, params[1].name_span));
}

/// Parse source that has errors; the caller checks `diags` and frees the tree.
fn parseBroken(src: [:0]const u8, diags: *Diagnostics) !ast.Ast {
    return parse(testing.allocator, src, diags);
}

test "doc 74 P1b: a dropped statement becomes an error node over the skipped text" {
    const src = "x = = 1\nprint(2)";
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    var tree = try parseBroken(src, &diags);
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 1), diags.count());
    try testing.expectEqual(@as(usize, 2), tree.root.len);
    try testing.expect(tree.root[0].data == .err);
    try testing.expectEqualStrings("x = = 1", spanText(src, tree.root[0].span));
    try testing.expect(tree.root[1].data == .call);
}

test "doc 74 P1b: a local with a broken value keeps its declaration" {
    const src = "local x =\nlocal y = 1\nprint(x, y)";
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    var tree = try parseBroken(src, &diags);
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 1), diags.count());
    try testing.expectEqual(@as(usize, 3), tree.root.len);
    const x = tree.root[0].data.local;
    try testing.expectEqualStrings("x", x.names[0].name);
    try testing.expectEqual(@as(usize, 1), x.values.len);
    try testing.expect(x.values[0].data == .err);
    // The next statement's `local` was not swallowed by the recovery.
    try testing.expectEqualStrings("y", tree.root[1].data.local.names[0].name);
    try testing.expect(tree.root[2].data == .call);
}

test "doc 74 P1b: the `end` left over by a dropped header costs no second diagnostic" {
    const src = "if ( then local a = 1 end\nprint(a)";
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    var tree = try parseBroken(src, &diags);
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 1), diags.count());
    // if-header (dropped), local a, stray end, print(a): parsing went on to the end.
    try testing.expectEqual(@as(usize, 4), tree.root.len);
    try testing.expect(tree.root[0].data == .err);
    try testing.expect(tree.root[1].data == .local);
    try testing.expect(tree.root[2].data == .err);
    try testing.expect(tree.root[3].data == .call);
}

test "doc 74 P1b: a stray `end` with no earlier error is reported once and parsing goes on" {
    const src = "end\nprint(1)";
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    var tree = try parseBroken(src, &diags);
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 1), diags.count());
    try testing.expect(tree.root[0].data == .err);
    try testing.expect(tree.root[1].data == .call);
}

test "doc 74 P1b: every error node's span is well formed and inside the source" {
    const sources = [_][:0]const u8{
        "local", "local x =", "x =", "if", "if x then", "for", "function", "a.b.", "f(", "{", "return return",
        "local function", "while true do local = end", "end end end", "(((", "x = = = =",
    };
    for (sources) |src| {
        var diags = Diagnostics.init(testing.allocator);
        defer diags.deinit();
        var tree = try parseBroken(src, &diags);
        defer tree.deinit();
        try testing.expect(diags.hasErrors());
        for (tree.root) |s| {
            try testing.expect(s.span.start <= s.span.end);
            try testing.expect(s.span.end <= src.len);
        }
    }
}

test "doc 74 P1d: an unclosed construct points back at its opener" {
    const cases = [_]struct { src: [:0]const u8, code: diag.Code, open: []const u8, label: []const u8 }{
        .{ .src = "if x then", .code = .expected_end_if, .open = "if", .label = "'if' opened here" },
        .{ .src = "while x do", .code = .expected_end_while, .open = "while", .label = "'while' opened here" },
        .{ .src = "for i = 1, 2 do", .code = .expected_end_for, .open = "for", .label = "'for' opened here" },
        .{ .src = "do", .code = .expected_end_do, .open = "do", .label = "'do' opened here" },
        .{ .src = "repeat", .code = .expected_until, .open = "repeat", .label = "'repeat' opened here" },
        .{ .src = "local function f()", .code = .expected_end_function, .open = "function", .label = "'function' opened here" },
        .{ .src = "f(1", .code = .expected_rparen_args, .open = "(", .label = "'(' opened here" },
        .{ .src = "local t = {1", .code = .expected_rbrace, .open = "{", .label = "'{' opened here" },
        .{ .src = "local a = (1", .code = .expected_rparen, .open = "(", .label = "'(' opened here" },
    };
    for (cases) |c| {
        var diags = Diagnostics.init(testing.allocator);
        defer diags.deinit();
        var tree = try parseBroken(c.src, &diags);
        defer tree.deinit();
        const d = diags.list.items[0];
        try testing.expectEqual(c.code, d.code);
        try testing.expectEqualStrings(c.code.message(), d.message);
        const r = d.related.?;
        try testing.expectEqualStrings(c.label, r.label);
        try testing.expectEqualStrings(c.open, c.src[r.start..r.end]);
    }
}

test "doc 74 P1d: a plain syntax error carries its code and no related span" {
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    var tree = try parseBroken("local x = )", &diags);
    defer tree.deinit();
    try testing.expectEqual(diag.Code.expected_expression, diags.list.items[0].code);
    try testing.expect(diags.list.items[0].related == null);
}
