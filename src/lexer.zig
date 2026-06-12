//! Hand-written scanner for the Lua-shaped surface syntax.
//!
//! Operates on a sentinel-terminated source (`[:0]const u8`) so the inner loop
//! never needs a length check — it stops at the `0` terminator. Produces one
//! `Token` per `next()` call; lexing errors are recorded in a shared
//! `Diagnostics` sink and surfaced as an `.invalid` token so scanning can
//! continue (better error recovery than bailing on the first bad byte).
//!
//! Deferred for v1 (tracked, not silently dropped): long-bracket string
//! literals (`[[ ... ]]` / `[==[ ... ]==]`). Long-bracket *comments*
//! (`--[[ ... ]]`, no level markers) are supported. Hex float literals are
//! deferred (hex integers are supported).

const std = @import("std");
const token = @import("token.zig");
const Token = token.Token;
const Diagnostics = @import("diag.zig").Diagnostics;

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}
fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}
fn isAlnum(c: u8) bool {
    return isAlpha(c) or isDigit(c);
}

pub const Lexer = struct {
    source: [:0]const u8,
    index: u32 = 0,
    line: u32 = 1,
    diags: *Diagnostics,

    pub fn init(source: [:0]const u8, diags: *Diagnostics) Lexer {
        return .{ .source = source, .diags = diags };
    }

    inline fn peek(self: *const Lexer) u8 {
        return self.source[self.index];
    }
    inline fn peekNext(self: *const Lexer) u8 {
        // Safe: only called when peek() != 0, so index < len and index+1 <= len
        // (the sentinel position, which is a valid index for [:0]).
        return self.source[self.index + 1];
    }

    /// Produce the next token. Returns `.eof` repeatedly once input is consumed.
    pub fn next(self: *Lexer) Token {
        self.skipTrivia();

        const start = self.index;
        const start_line = self.line;
        const c = self.peek();

        if (c == 0) return self.make(.eof, start, start_line);

        if (isAlpha(c)) return self.identifier(start, start_line);
        if (isDigit(c)) return self.number(start, start_line);
        if (c == '.' and isDigit(self.peekNext())) return self.number(start, start_line);
        if (c == '"' or c == '\'') return self.string(start, start_line);

        return self.operator(start, start_line);
    }

    fn make(self: *Lexer, tag: Token.Tag, start: u32, line: u32) Token {
        return .{ .tag = tag, .start = start, .end = self.index, .line = line };
    }

    // -- trivia: whitespace, newlines, comments --

    fn skipTrivia(self: *Lexer) void {
        while (true) {
            switch (self.peek()) {
                ' ', '\t', '\r' => self.index += 1,
                '\n' => {
                    self.index += 1;
                    self.line += 1;
                },
                '-' => {
                    if (self.peekNext() != '-') return;
                    self.index += 2; // consume "--"
                    self.skipComment();
                },
                else => return,
            }
        }
    }

    fn skipComment(self: *Lexer) void {
        // Long-bracket block comment: --[[ ... ]]  (no level markers in v1).
        if (self.peek() == '[' and self.peekNext() == '[') {
            const open_line = self.line;
            const open_start = self.index - 2;
            self.index += 2;
            while (true) {
                const c = self.peek();
                if (c == 0) {
                    self.diags.err("unterminated block comment", open_start, self.index, open_line);
                    return;
                }
                if (c == ']' and self.peekNext() == ']') {
                    self.index += 2;
                    return;
                }
                if (c == '\n') self.line += 1;
                self.index += 1;
            }
        }
        // Line comment: to end of line (the '\n' is left for skipTrivia).
        while (self.peek() != '\n' and self.peek() != 0) self.index += 1;
    }

    // -- token scanners --

    fn identifier(self: *Lexer, start: u32, line: u32) Token {
        while (isAlnum(self.peek())) self.index += 1;
        const text = self.source[start..self.index];
        return self.make(token.identifierTag(text), start, line);
    }

    fn number(self: *Lexer, start: u32, line: u32) Token {
        // Hex integer: 0x / 0X followed by hex digits.
        if (self.peek() == '0' and (self.peekNext() == 'x' or self.peekNext() == 'X')) {
            self.index += 2;
            const digits_start = self.index;
            while (isHexDigit(self.peek())) self.index += 1;
            if (self.index == digits_start) {
                self.diags.err("invalid hexadecimal number", start, self.index, line);
                return self.make(.invalid, start, line);
            }
            return self.make(.int_literal, start, line);
        }

        var is_float = false;
        while (isDigit(self.peek())) self.index += 1;

        // Fractional part — but not if the dot is actually a `..` operator.
        if (self.peek() == '.' and self.peekNext() != '.') {
            is_float = true;
            self.index += 1;
            while (isDigit(self.peek())) self.index += 1;
        }

        // Exponent.
        if (self.peek() == 'e' or self.peek() == 'E') {
            is_float = true;
            self.index += 1;
            if (self.peek() == '+' or self.peek() == '-') self.index += 1;
            const exp_start = self.index;
            while (isDigit(self.peek())) self.index += 1;
            if (self.index == exp_start) {
                self.diags.err("malformed number exponent", start, self.index, line);
                return self.make(.invalid, start, line);
            }
        }

        return self.make(if (is_float) .float_literal else .int_literal, start, line);
    }

    fn string(self: *Lexer, start: u32, line: u32) Token {
        const quote = self.peek();
        self.index += 1; // opening quote
        while (true) {
            const c = self.peek();
            switch (c) {
                0, '\n' => {
                    self.diags.err("unterminated string", start, self.index, line);
                    return self.make(.invalid, start, line);
                },
                '\\' => {
                    // Consume the backslash and the escaped character verbatim;
                    // escape *interpretation* happens when the parser builds the
                    // string value. A backslash-newline counts a line.
                    self.index += 1;
                    if (self.peek() == '\n') self.line += 1;
                    if (self.peek() != 0) self.index += 1;
                },
                else => {
                    if (c == quote) {
                        self.index += 1; // closing quote
                        return self.make(.string_literal, start, line);
                    }
                    self.index += 1;
                },
            }
        }
    }

    fn operator(self: *Lexer, start: u32, line: u32) Token {
        const c = self.peek();
        self.index += 1;
        const tag: Token.Tag = switch (c) {
            '+' => .plus,
            '-' => .minus,
            '*' => .star,
            '/' => self.pick('/', .slash_slash, .slash),
            '%' => .percent,
            '^' => .caret,
            '#' => .hash,
            '&' => .ampersand,
            '|' => .pipe,
            '~' => self.pick('=', .ne, .tilde),
            '(' => .lparen,
            ')' => .rparen,
            '{' => .lbrace,
            '}' => .rbrace,
            '[' => .lbracket,
            ']' => .rbracket,
            ';' => .semicolon,
            ',' => .comma,
            '=' => self.pick('=', .eq, .assign),
            ':' => self.pick(':', .double_colon, .colon),
            '<' => self.pickTwo('=', .le, '<', .lshift, .lt),
            '>' => self.pickTwo('=', .ge, '>', .rshift, .gt),
            '.' => self.dots(),
            else => {
                self.diags.err("unexpected character", start, self.index, line);
                return self.make(.invalid, start, line);
            },
        };
        return self.make(tag, start, line);
    }

    /// If the current char is `expect`, consume it and return `yes`, else `no`.
    fn pick(self: *Lexer, expect: u8, yes: Token.Tag, no: Token.Tag) Token.Tag {
        if (self.peek() == expect) {
            self.index += 1;
            return yes;
        }
        return no;
    }

    /// Two-way second-char dispatch (e.g. `<` → `<=` or `<<` or `<`).
    fn pickTwo(self: *Lexer, e1: u8, t1: Token.Tag, e2: u8, t2: Token.Tag, no: Token.Tag) Token.Tag {
        const c = self.peek();
        if (c == e1) {
            self.index += 1;
            return t1;
        }
        if (c == e2) {
            self.index += 1;
            return t2;
        }
        return no;
    }

    /// After consuming one `.`: resolve `.` / `..` / `...`.
    fn dots(self: *Lexer) Token.Tag {
        if (self.peek() != '.') return .dot;
        self.index += 1; // second dot
        if (self.peek() == '.') {
            self.index += 1; // third dot
            return .ellipsis;
        }
        return .dot_dot;
    }
};

/// Convenience: tokenize an entire source into a slice (including the trailing
/// `.eof`). Caller owns the returned slice.
pub fn tokenize(gpa: std.mem.Allocator, source: [:0]const u8, diags: *Diagnostics) ![]Token {
    var list: std.ArrayList(Token) = .empty;
    errdefer list.deinit(gpa);
    var lexer = Lexer.init(source, diags);
    while (true) {
        const t = lexer.next();
        try list.append(gpa, t);
        if (t.tag == .eof) break;
    }
    return list.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Lex `source` and assert the produced tags (excluding the trailing eof).
fn expectTags(source: [:0]const u8, expected: []const Token.Tag) !void {
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    const toks = try tokenize(testing.allocator, source, &diags);
    defer testing.allocator.free(toks);
    try testing.expect(!diags.hasErrors());
    try testing.expectEqual(expected.len + 1, toks.len); // +eof
    for (expected, 0..) |tag, i| {
        try testing.expectEqual(tag, toks[i].tag);
    }
    try testing.expectEqual(Token.Tag.eof, toks[toks.len - 1].tag);
}

test "keywords vs identifiers" {
    try expectTags("local x function foo end", &.{
        .keyword_local, .identifier, .keyword_function, .identifier, .keyword_end,
    });
}

test "int vs float literals" {
    try expectTags("1 2.0 3e2 0x1F 4.5e-3 .5", &.{
        .int_literal, .float_literal, .float_literal, .int_literal, .float_literal, .float_literal,
    });
}

test "number followed by concat is not a float" {
    // `1..2` is int, `..`, int — the dot pair must win over a fractional part.
    try expectTags("1..2", &.{ .int_literal, .dot_dot, .int_literal });
}

test "maximal-munch operators" {
    try expectTags("+ - * / // % ^ == ~= <= >= < > << >> .. ... :: = : .", &.{
        .plus,  .minus, .star,    .slash, .slash_slash, .percent, .caret,
        .eq,    .ne,    .le,      .ge,    .lt,          .gt,      .lshift,
        .rshift, .dot_dot, .ellipsis, .double_colon, .assign, .colon, .dot,
    });
}

test "index and call punctuation" {
    try expectTags("a.b[c](d):m()", &.{
        .identifier, .dot,     .identifier, .lbracket, .identifier, .rbracket,
        .lparen,     .identifier, .rparen,  .colon,    .identifier, .lparen,
        .rparen,
    });
}

test "strings with escapes and both quote styles" {
    try expectTags(
        \\"hello" 'it\'s' "tab\there"
    , &.{ .string_literal, .string_literal, .string_literal });
}

test "line and block comments are skipped, lines tracked" {
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    const src =
        \\local a -- a line comment
        \\--[[ a
        \\   block comment ]]
        \\local b
    ;
    const toks = try tokenize(testing.allocator, src, &diags);
    defer testing.allocator.free(toks);
    try testing.expect(!diags.hasErrors());
    // local a local b eof
    try testing.expectEqual(@as(usize, 5), toks.len);
    try testing.expectEqual(Token.Tag.keyword_local, toks[0].tag);
    try testing.expectEqual(Token.Tag.identifier, toks[3].tag);
    // `b` is on line 4.
    try testing.expectEqual(@as(u32, 4), toks[3].line);
}

test "unterminated string records a diagnostic and recovers" {
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    const toks = try tokenize(testing.allocator, "\"oops\nlocal", &diags);
    defer testing.allocator.free(toks);
    try testing.expect(diags.hasErrors());
    try testing.expectEqual(Token.Tag.invalid, toks[0].tag);
    // Recovery: scanning continues on the next line.
    try testing.expectEqual(Token.Tag.keyword_local, toks[1].tag);
}

test "unexpected character is diagnosed" {
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    const toks = try tokenize(testing.allocator, "a `", &diags);
    defer testing.allocator.free(toks);
    try testing.expect(diags.hasErrors());
    try testing.expectEqual(Token.Tag.identifier, toks[0].tag);
    try testing.expectEqual(Token.Tag.invalid, toks[1].tag);
}

test "lexeme slices map back to source" {
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    const src: [:0]const u8 = "foo = 123";
    const toks = try tokenize(testing.allocator, src, &diags);
    defer testing.allocator.free(toks);
    try testing.expectEqualStrings("foo", toks[0].lexeme(src));
    try testing.expectEqualStrings("123", toks[2].lexeme(src));
}
