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
const Token = token.Token;
const Tag = Token.Tag;
const Diagnostics = @import("diag.zig").Diagnostics;
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

    fn fail(self: *Parser, message: []const u8) Error {
        const t = self.current();
        self.diags.err(message, t.start, t.end, t.line);
        return Error.ParseError;
    }

    fn expect(self: *Parser, tag: Tag, message: []const u8) Error!Token {
        if (self.check(tag)) return self.advance();
        return self.fail(message);
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

    // =====================================================================
    // Blocks & statements
    // =====================================================================

    fn parseChunk(self: *Parser) Error!ast.Block {
        const block = try self.parseBlock();
        if (!self.check(.eof)) {
            // Trailing junk after a complete chunk.
            _ = self.fail("expected end of input") catch {};
        }
        return block;
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
            if (self.check(.keyword_return)) {
                const ret = self.parseReturn() catch |e| switch (e) {
                    Error.ParseError => {
                        self.synchronize();
                        continue;
                    },
                    else => return e,
                };
                try stmts.append(self.arena, ret);
                break; // `return` ends the block
            }
            const stmt = self.parseStatement() catch |e| switch (e) {
                Error.ParseError => {
                    self.synchronize();
                    continue;
                },
                else => return e,
            };
            try stmts.append(self.arena, stmt);
        }
        return try stmts.toOwnedSlice(self.arena);
    }

    /// Skip tokens until a plausible statement boundary so parsing can resume
    /// after an error. Always makes progress.
    fn synchronize(self: *Parser) void {
        // Ensure forward progress even if the current token is itself a sync
        // point we got stuck on.
        if (!self.check(.eof)) _ = self.advance();
        while (!self.check(.eof)) {
            // Stop *before* a token that can begin (or end) a statement.
            switch (self.currentTag()) {
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
            .keyword_function => self.parseFunctionDecl(),
            .keyword_break => blk: {
                const t = self.advance();
                break :blk Stmt{ .span = .{ .start = t.start, .end = t.end }, .data = .break_ };
            },
            else => self.parseExprStatement(),
        };
    }

    fn parseLocal(self: *Parser) Error!Stmt {
        const start = self.advance().start; // 'local'

        if (self.match(.keyword_function)) {
            const name_tok = try self.expect(.identifier, "expected function name");
            const body = try self.parseFunctionBody();
            return .{
                .span = self.spanFrom(start),
                .data = .{ .local_function = .{ .name = name_tok.lexeme(self.source), .body = body } },
            };
        }

        var names: std.ArrayList(ast.TypedName) = .empty;
        while (true) {
            const name_tok = try self.expect(.identifier, "expected variable name");
            const ty = try self.parseOptionalType();
            try names.append(self.arena, .{
                .name = name_tok.lexeme(self.source),
                .name_span = .{ .start = name_tok.start, .end = name_tok.end },
                .type = ty,
            });
            if (!self.match(.comma)) break;
        }

        var values: []const *Expr = &.{};
        if (self.match(.assign)) values = try self.parseExprList();

        return .{
            .span = self.spanFrom(start),
            .data = .{ .local = .{ .names = try names.toOwnedSlice(self.arena), .values = values } },
        };
    }

    fn parseExprStatement(self: *Parser) Error!Stmt {
        const start = self.current().start;
        const first = try self.parseSuffixed();

        if (self.check(.assign) or self.check(.comma)) {
            var targets: std.ArrayList(*Expr) = .empty;
            try targets.append(self.arena, first);
            while (self.match(.comma)) {
                try targets.append(self.arena, try self.parseSuffixed());
            }
            _ = try self.expect(.assign, "expected '=' in assignment");
            const values = try self.parseExprList();
            for (targets.items) |t| {
                if (!t.isAssignable()) {
                    self.diags.err("cannot assign to this expression", t.span.start, t.span.end, 0);
                    return Error.ParseError;
                }
            }
            return .{
                .span = self.spanFrom(start),
                .data = .{ .assign = .{ .targets = try targets.toOwnedSlice(self.arena), .values = values } },
            };
        }

        if (!first.isCall()) return self.fail("expected a statement (assignment or call)");
        return .{ .span = self.spanFrom(start), .data = .{ .call = first } };
    }

    fn parseIf(self: *Parser) Error!Stmt {
        const start = self.advance().start; // 'if'
        var branches: std.ArrayList(Stmt.Branch) = .empty;

        const cond = try self.parseExpr(0);
        _ = try self.expect(.keyword_then, "expected 'then'");
        try branches.append(self.arena, .{ .cond = cond, .body = try self.parseBlock() });

        while (self.match(.keyword_elseif)) {
            const c = try self.parseExpr(0);
            _ = try self.expect(.keyword_then, "expected 'then'");
            try branches.append(self.arena, .{ .cond = c, .body = try self.parseBlock() });
        }

        var else_body: ?ast.Block = null;
        if (self.match(.keyword_else)) else_body = try self.parseBlock();

        _ = try self.expect(.keyword_end, "expected 'end' to close 'if'");
        return .{
            .span = self.spanFrom(start),
            .data = .{ .if_ = .{ .branches = try branches.toOwnedSlice(self.arena), .else_body = else_body } },
        };
    }

    fn parseWhile(self: *Parser) Error!Stmt {
        const start = self.advance().start; // 'while'
        const cond = try self.parseExpr(0);
        _ = try self.expect(.keyword_do, "expected 'do'");
        const body = try self.parseBlock();
        _ = try self.expect(.keyword_end, "expected 'end' to close 'while'");
        return .{ .span = self.spanFrom(start), .data = .{ .while_ = .{ .cond = cond, .body = body } } };
    }

    fn parseRepeat(self: *Parser) Error!Stmt {
        const start = self.advance().start; // 'repeat'
        const body = try self.parseBlock();
        _ = try self.expect(.keyword_until, "expected 'until' to close 'repeat'");
        // The condition is parsed (and later compiled) in the body's scope: Lua
        // permits `until` to reference locals declared inside the loop body.
        const cond = try self.parseExpr(0);
        return .{ .span = self.spanFrom(start), .data = .{ .repeat = .{ .body = body, .cond = cond } } };
    }

    fn parseFor(self: *Parser) Error!Stmt {
        const start = self.advance().start; // 'for'
        const first_name = try self.expect(.identifier, "expected loop variable");

        if (self.match(.assign)) {
            // numeric for: for i = start, stop [, step] do ... end
            const start_expr = try self.parseExpr(0);
            _ = try self.expect(.comma, "expected ',' after numeric-for start");
            const stop_expr = try self.parseExpr(0);
            var step: ?*Expr = null;
            if (self.match(.comma)) step = try self.parseExpr(0);
            _ = try self.expect(.keyword_do, "expected 'do'");
            const body = try self.parseBlock();
            _ = try self.expect(.keyword_end, "expected 'end' to close 'for'");
            return .{ .span = self.spanFrom(start), .data = .{ .numeric_for = .{
                .name = first_name.lexeme(self.source),
                .start = start_expr,
                .stop = stop_expr,
                .step = step,
                .body = body,
            } } };
        }

        // generic for: for a, b in explist do ... end
        var names: std.ArrayList([]const u8) = .empty;
        try names.append(self.arena, first_name.lexeme(self.source));
        while (self.match(.comma)) {
            const n = try self.expect(.identifier, "expected loop variable");
            try names.append(self.arena, n.lexeme(self.source));
        }
        _ = try self.expect(.keyword_in, "expected '=' or 'in' in for-loop");
        const exprs = try self.parseExprList();
        _ = try self.expect(.keyword_do, "expected 'do'");
        const body = try self.parseBlock();
        _ = try self.expect(.keyword_end, "expected 'end' to close 'for'");
        return .{ .span = self.spanFrom(start), .data = .{ .generic_for = .{
            .names = try names.toOwnedSlice(self.arena),
            .exprs = exprs,
            .body = body,
        } } };
    }

    fn parseDo(self: *Parser) Error!Stmt {
        const start = self.advance().start; // 'do'
        const body = try self.parseBlock();
        _ = try self.expect(.keyword_end, "expected 'end' to close 'do'");
        return .{ .span = self.spanFrom(start), .data = .{ .do = body } };
    }

    fn parseFunctionDecl(self: *Parser) Error!Stmt {
        const start = self.advance().start; // 'function'
        var path: std.ArrayList([]const u8) = .empty;
        const first = try self.expect(.identifier, "expected function name");
        try path.append(self.arena, first.lexeme(self.source));
        while (self.match(.dot)) {
            const n = try self.expect(.identifier, "expected name after '.'");
            try path.append(self.arena, n.lexeme(self.source));
        }
        var method: ?[]const u8 = null;
        if (self.match(.colon)) {
            const m = try self.expect(.identifier, "expected method name after ':'");
            method = m.lexeme(self.source);
        }

        const body = try self.parseFunctionBody();
        // A method `a:m` gets an implicit leading `self` parameter.
        const final_body = if (method != null) try self.prependSelf(body) else body;

        return .{ .span = self.spanFrom(start), .data = .{ .function_decl = .{
            .name = .{ .path = try path.toOwnedSlice(self.arena), .method = method },
            .body = final_body,
        } } };
    }

    fn prependSelf(self: *Parser, body: *ast.FunctionBody) Error!*ast.FunctionBody {
        var params: std.ArrayList(ast.Param) = .empty;
        try params.append(self.arena, .{ .name = "self", .name_span = body.span, .type = null });
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
    fn parseFunctionBody(self: *Parser) Error!*ast.FunctionBody {
        const start = self.current().start;
        _ = try self.expect(.lparen, "expected '(' for parameter list");

        var params: std.ArrayList(ast.Param) = .empty;
        var is_vararg = false;
        if (!self.check(.rparen)) {
            while (true) {
                if (self.match(.ellipsis)) {
                    is_vararg = true;
                    break;
                }
                const name_tok = try self.expect(.identifier, "expected parameter name");
                const ty = try self.parseOptionalType();
                try params.append(self.arena, .{
                    .name = name_tok.lexeme(self.source),
                    .name_span = .{ .start = name_tok.start, .end = name_tok.end },
                    .type = ty,
                });
                if (!self.match(.comma)) break;
            }
        }
        _ = try self.expect(.rparen, "expected ')' after parameters");

        const ret_type = try self.parseOptionalType();
        const body = try self.parseBlock();
        _ = try self.expect(.keyword_end, "expected 'end' to close function");

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
        const first = try self.expect(.identifier, "expected type name");
        try path.append(self.arena, first.lexeme(self.source));
        while (self.match(.dot)) {
            const n = try self.expect(.identifier, "expected type name after '.'");
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
        return self.parseSuffixed();
    }

    fn parseSuffixed(self: *Parser) Error!*Expr {
        var e = try self.parsePrimary();
        while (true) {
            switch (self.currentTag()) {
                .dot => {
                    _ = self.advance();
                    const name_tok = try self.expect(.identifier, "expected field name after '.'");
                    e = try self.newExpr(
                        .{ .start = e.span.start, .end = name_tok.end },
                        .{ .field = .{ .obj = e, .name = name_tok.lexeme(self.source) } },
                    );
                },
                .lbracket => {
                    _ = self.advance();
                    const key = try self.parseExpr(0);
                    const close = try self.expect(.rbracket, "expected ']'");
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
                    const name_tok = try self.expect(.identifier, "expected method name after ':'");
                    const args = try self.parseCallArgs();
                    e = try self.newExpr(
                        .{ .start = e.span.start, .end = self.lastEnd() },
                        .{ .method_call = .{ .obj = e, .name = name_tok.lexeme(self.source), .args = args } },
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
        _ = try self.expect(.lparen, "expected '(' to start call arguments");
        if (self.match(.rparen)) return &.{};
        const args = try self.parseExprList();
        _ = try self.expect(.rparen, "expected ')' to close call arguments");
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
            .int_literal => {
                _ = self.advance();
                return self.newExpr(.{ .start = t.start, .end = t.end }, try self.parseNumber(t));
            },
            .float_literal => {
                _ = self.advance();
                const f = std.fmt.parseFloat(f64, t.lexeme(self.source)) catch {
                    return self.failAtToken(t, "invalid float literal");
                };
                return self.newExpr(.{ .start = t.start, .end = t.end }, .{ .float = f });
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
                const close = try self.expect(.rparen, "expected ')'");
                return self.newExpr(.{ .start = t.start, .end = close.end }, .{ .paren = inner });
            },
            .lbrace => return self.parseTable(),
            .keyword_function => {
                _ = self.advance();
                const body = try self.parseFunctionBody();
                return self.newExpr(body.span, .{ .function = body });
            },
            else => return self.fail("expected an expression"),
        }
    }

    fn failAtToken(self: *Parser, t: Token, message: []const u8) Error {
        self.diags.err(message, t.start, t.end, t.line);
        return Error.ParseError;
    }

    /// Parse an integer literal's value. Hex that overflows `i64` wraps (Phase 1
    /// semantics); a decimal that overflows `i64` promotes to a float.
    fn parseNumber(self: *Parser, t: Token) Error!Expr.Data {
        const text = t.lexeme(self.source);
        if (std.fmt.parseInt(i64, text, 0)) |v| {
            return .{ .int = v };
        } else |e| switch (e) {
            error.Overflow => {
                const is_hex = text.len >= 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X');
                if (is_hex) {
                    const u = std.fmt.parseInt(u64, text, 0) catch {
                        return self.failAtToken(t, "invalid integer literal");
                    };
                    return .{ .int = @bitCast(u) };
                }
                const f = std.fmt.parseFloat(f64, text) catch {
                    return self.failAtToken(t, "invalid integer literal");
                };
                return .{ .float = f };
            },
            error.InvalidCharacter => return self.failAtToken(t, "invalid integer literal"),
        }
    }

    fn parseTable(self: *Parser) Error!*Expr {
        const start = self.advance().start; // '{'
        var fields: std.ArrayList(ast.TableField) = .empty;
        while (!self.check(.rbrace)) {
            if (self.check(.lbracket)) {
                _ = self.advance();
                const key = try self.parseExpr(0);
                _ = try self.expect(.rbracket, "expected ']' in table key");
                _ = try self.expect(.assign, "expected '=' after table key");
                const value = try self.parseExpr(0);
                try fields.append(self.arena, .{ .keyed = .{ .key = key, .value = value } });
            } else if (self.check(.identifier) and self.peekAt(1).tag == .assign) {
                const name_tok = self.advance();
                _ = self.advance(); // '='
                const value = try self.parseExpr(0);
                try fields.append(self.arena, .{ .named = .{ .name = name_tok.lexeme(self.source), .value = value } });
            } else {
                const value = try self.parseExpr(0);
                try fields.append(self.arena, .{ .positional = value });
            }
            if (!self.match(.comma) and !self.match(.semicolon)) break;
        }
        const close = try self.expect(.rbrace, "expected '}' to close table");
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
    try testing.expectEqualStrings("v", gf.names[1]);
}

test "method declaration gets implicit self" {
    var tree = try parseOk("function obj:greet(name) return name end");
    defer tree.deinit();
    const fd = tree.root[0].data.function_decl;
    try testing.expectEqual(@as(usize, 1), fd.name.path.len);
    try testing.expectEqualStrings("obj", fd.name.path[0]);
    try testing.expectEqualStrings("greet", fd.name.method.?);
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

