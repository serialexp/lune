//! Hand-written scanner for the Lua-shaped surface syntax.
//!
//! Operates on a sentinel-terminated source (`[:0]const u8`) so the inner loop
//! never needs a length check — it stops at the `0` terminator. Produces one
//! `Token` per `next()` call; lexing errors are recorded in a shared
//! `Diagnostics` sink and surfaced as an `.invalid` token so scanning can
//! continue (better error recovery than bailing on the first bad byte).
//!
//! Long-bracket string literals (`[[ ... ]]` / `[==[ ... ]==]`) and long-bracket
//! comments (`--[[ ... ]]` / `--[==[ ... ]==]`, with matching `=` levels) are
//! supported. A long string is scanned to a `.string_literal` token spanning the
//! whole `[==[ ... ]==]`; the compiler decodes it (no escapes, one leading
//! newline skipped) by discriminating on the leading `[`.
//!
//! Deferred for v1 (tracked, not silently dropped): hex float literals (hex
//! integers are supported).

const std = @import("std");
const token = @import("token.zig");
const numeral = @import("numeral.zig");
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
        if (c == '[') {
            if (self.longBracketLevel()) |level| return self.longString(start, start_line, level);
        }

        return self.operator(start, start_line);
    }

    fn make(self: *Lexer, tag: Token.Tag, start: u32, line: u32) Token {
        return .{ .tag = tag, .start = start, .end = self.index, .line = line };
    }

    // -- trivia: whitespace, newlines, comments --

    fn skipTrivia(self: *Lexer) void {
        while (true) {
            switch (self.peek()) {
                ' ', '\t' => self.index += 1,
                '\n', '\r' => self.newline(),
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
        // Long-bracket block comment: --[[ ... ]] / --[==[ ... ]==] (any level).
        if (self.peek() == '[') {
            if (self.longBracketLevel()) |level| {
                const open_line = self.line;
                const open_start = self.index - 2;
                self.index += level + 2; // consume `[` `=`{level} `[`
                while (true) {
                    const c = self.peek();
                    if (c == 0) {
                        self.diags.report(.unterminated_block_comment, open_start, self.index, open_line);
                        return;
                    }
                    if (c == ']') {
                        if (self.longBracketClose(level)) |after| {
                            self.index = after;
                            return;
                        }
                    }
                    if (c == '\n' or c == '\r') self.newline() else self.index += 1;
                }
            }
        }
        // Line comment: to end of line (the newline is left for skipTrivia).
        while (self.peek() != '\n' and self.peek() != '\r' and self.peek() != 0) self.index += 1;
    }

    /// At a `[`, detect a long-bracket opener `[` `=`* `[` and return its level
    /// (the count of `=`), or null if this `[` is just an index bracket. Does not
    /// consume. Safe on the sentinel-terminated source: the `=` scan stops at `0`.
    fn longBracketLevel(self: *const Lexer) ?u32 {
        std.debug.assert(self.peek() == '[');
        var j = self.index + 1;
        while (self.source[j] == '=') j += 1;
        if (self.source[j] == '[') return j - (self.index + 1);
        return null;
    }

    /// At a `]`, does a closing long bracket of `level` (`]` `=`{level} `]`) start
    /// here? Returns the index just past the close, or null. Does not consume.
    fn longBracketClose(self: *const Lexer, level: u32) ?u32 {
        std.debug.assert(self.peek() == ']');
        var j = self.index + 1;
        var eq: u32 = 0;
        while (self.source[j] == '=') : (eq += 1) j += 1;
        if (eq == level and self.source[j] == ']') return j + 1;
        return null;
    }

    /// Scan a long-bracket string `[` `=`{level} `[` ... `]` `=`{level} `]` into a
    /// single `.string_literal` token spanning the whole literal (brackets
    /// included). Content (escape-free, leading-newline rules) is decoded later by
    /// the compiler, which discriminates a long string by its leading `[`.
    fn longString(self: *Lexer, start: u32, line: u32, level: u32) Token {
        self.index += level + 2; // consume the opening `[` `=`{level} `[`
        while (true) {
            const c = self.peek();
            if (c == 0) {
                self.diags.report(.unterminated_long_string, start, self.index, line);
                return self.make(.invalid, start, line);
            }
            if (c == ']') {
                if (self.longBracketClose(level)) |after| {
                    self.index = after;
                    return self.make(.string_literal, start, line);
                }
            }
            if (c == '\n' or c == '\r') self.newline() else self.index += 1;
        }
    }

    // -- token scanners --

    fn identifier(self: *Lexer, start: u32, line: u32) Token {
        while (isAlnum(self.peek())) self.index += 1;
        const text = self.source[start..self.index];
        return self.make(token.identifierTag(text), start, line);
    }

    /// Lua's `read_numeral`: from a digit (or `.digit`), take hex digits, `.`
    /// and an exponent mark (`e`/`E`, or `p`/`P` after `0x`) with an optional
    /// sign, then one touching letter, so `3x` is one bad numeral rather than
    /// `3` and `x`. The span must read as a numeral (`numeral.parse`), which
    /// also decides int against float. One difference from Lua: a `..` ends
    /// the numeral, so `1..2` is `1 .. 2` (Lua: "malformed number").
    fn number(self: *Lexer, start: u32, line: u32) Token {
        const hex = self.peek() == '0' and (self.peekNext() == 'x' or self.peekNext() == 'X');
        if (hex) self.index += 2;
        const exp_mark: u8 = if (hex) 'p' else 'e';
        while (true) {
            const c = self.peek();
            if (c == exp_mark or c == std.ascii.toUpper(exp_mark)) {
                self.index += 1;
                if (self.peek() == '+' or self.peek() == '-') self.index += 1;
            } else if (isHexDigit(c) or (c == '.' and self.peekNext() != '.')) {
                self.index += 1;
            } else break;
        }
        if (isAlpha(self.peek())) self.index += 1;
        const n = numeral.parse(self.source[start..self.index]) orelse {
            self.diags.report(.malformed_number, start, self.index, line);
            return self.make(.invalid, start, line);
        };
        return self.make(if (n == .int) .int_literal else .float_literal, start, line);
    }

    /// Step over one newline, as Lua's `inclinenumber`: `\n`, `\r`, or either
    /// pair (`\r\n`, `\n\r`) is one line break, the same ones
    /// `compiler.LineTable` counts, so the two never disagree on a line.
    fn newline(self: *Lexer) void {
        const first = self.peek();
        self.index += 1;
        const second = self.peek();
        if ((second == '\n' or second == '\r') and second != first) self.index += 1;
        self.line += 1;
    }

    fn string(self: *Lexer, start: u32, line: u32) Token {
        const quote = self.peek();
        self.index += 1; // opening quote
        while (true) {
            const c = self.peek();
            switch (c) {
                0, '\n', '\r' => {
                    self.diags.report(.unterminated_string, start, self.index, line);
                    return self.make(.invalid, start, line);
                },
                '\\' => {
                    // Consume the backslash and the escaped character verbatim;
                    // escape *interpretation* happens when the compiler builds
                    // the string value. Two escapes span more: a backslash before
                    // a newline (LF, CR, CRLF or LFCR) takes the whole newline,
                    // and `\z` the whitespace after it; both count lines.
                    self.index += 1;
                    switch (self.peek()) {
                        0 => {}, // reported as unterminated next round
                        '\n', '\r' => self.newline(),
                        'z' => {
                            self.index += 1;
                            while (true) switch (self.peek()) {
                                ' ', '\t', 0x0B, 0x0C => self.index += 1,
                                '\n', '\r' => self.newline(),
                                else => break,
                            };
                        },
                        else => self.index += 1,
                    }
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
            '+' => self.pick('=', .plus_assign, .plus),
            '-' => self.pick('=', .minus_assign, .minus),
            '*' => self.pick('=', .star_assign, .star),
            '/' => self.slashOp(),
            '%' => self.pick('=', .percent_assign, .percent),
            '^' => .caret, // no `^=` (exponent; compound form deliberately excluded)
            '#' => .hash,
            // Customary operator aliases (LuaJIT 3.0 parity): `&&`/`||`/`!`/`!=`
            // are pure lexical synonyms — they emit the very same tokens as
            // `and`/`or`/`not`/`~=`, so the parser and evaluator never know the
            // difference. A lone `&`/`|` stays bitwise; the compound `&=`/`|=`
            // assignment forms take priority over neither (doubled wins longest).
            '&' => self.ampOp(),
            '|' => self.pipeOp(),
            '!' => self.pick('=', .ne, .keyword_not),
            '?' => self.pick('?', .question_question, .question),
            '~' => self.tildeOp(),
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
            '<' => self.ltOp(),
            '>' => self.gtOp(),
            '.' => self.dots(),
            else => {
                self.diags.report(.unexpected_character, start, self.index, line);
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

    /// After consuming one `~`: resolve `~=` (inequality / xor-assign) / `~>>=`
    /// (arithmetic-shift assign) / `~>>` (arithmetic right shift) / `~` (bitwise
    /// xor / unary not). `~>` with a single `>` is left as a bare `~` then `>`;
    /// only the full `~>>` munches. Longest-match order: `~>>=` before `~>>`.
    fn tildeOp(self: *Lexer) Token.Tag {
        if (self.peek() == '=') {
            self.index += 1;
            return .ne;
        }
        if (self.peek() == '>' and self.peekNext() == '>') {
            self.index += 2; // consumed `~>>`
            if (self.peek() == '=') {
                self.index += 1;
                return .rshift_arith_assign;
            }
            return .rshift_arith;
        }
        return .tilde;
    }

    /// After consuming one `/`: `//=` / `//` / `/=` / `/`.
    fn slashOp(self: *Lexer) Token.Tag {
        if (self.peek() == '/') {
            self.index += 1; // consumed `//`
            return self.pick('=', .slash_slash_assign, .slash_slash);
        }
        return self.pick('=', .slash_assign, .slash);
    }

    /// After consuming one `&`: `&&` (logical-and alias) / `&=` / `&`.
    fn ampOp(self: *Lexer) Token.Tag {
        if (self.peek() == '&') {
            self.index += 1;
            return .keyword_and;
        }
        return self.pick('=', .amp_assign, .ampersand);
    }

    /// After consuming one `|`: `||` (logical-or alias) / `|=` / `|`.
    fn pipeOp(self: *Lexer) Token.Tag {
        if (self.peek() == '|') {
            self.index += 1;
            return .keyword_or;
        }
        return self.pick('=', .pipe_assign, .pipe);
    }

    /// After consuming one `<`: `<<=` / `<<` / `<=` / `<`.
    fn ltOp(self: *Lexer) Token.Tag {
        if (self.peek() == '<') {
            self.index += 1; // consumed `<<`
            return self.pick('=', .lshift_assign, .lshift);
        }
        return self.pick('=', .le, .lt);
    }

    /// After consuming one `>`: `>>=` / `>>` / `>=` / `>`.
    fn gtOp(self: *Lexer) Token.Tag {
        if (self.peek() == '>') {
            self.index += 1; // consumed `>>`
            return self.pick('=', .rshift_assign, .rshift);
        }
        return self.pick('=', .ge, .gt);
    }

    /// After consuming one `.`: resolve `.` / `..` / `..=` / `...`.
    fn dots(self: *Lexer) Token.Tag {
        if (self.peek() != '.') return .dot;
        self.index += 1; // second dot
        if (self.peek() == '.') {
            self.index += 1; // third dot
            return .ellipsis;
        }
        if (self.peek() == '=') {
            self.index += 1;
            return .concat_assign;
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

test "repeat/until lex as keywords, not identifiers" {
    try expectTags("repeat until repeated untilx", &.{
        .keyword_repeat, .keyword_until, .identifier, .identifier,
    });
}

test "int vs float literals" {
    try expectTags("1 2.0 3e2 0x1F 4.5e-3 .5", &.{
        .int_literal, .float_literal, .float_literal, .int_literal, .float_literal, .float_literal,
    });
}

test "hex floats and Lua's numeral span" {
    try expectTags("0x1.8p+1 0x.8 0xA 0x1P-3 1e+5", &.{
        .float_literal, .float_literal, .int_literal, .float_literal, .float_literal,
    });
}

test "a letter touching a numeral makes one malformed number, as in Lua" {
    for ([_][:0]const u8{ "3x", "0xfg", "1e", "0x", "1e+" }) |src| {
        var diags = Diagnostics.init(testing.allocator);
        defer diags.deinit();
        const toks = try tokenize(testing.allocator, src, &diags);
        defer testing.allocator.free(toks);
        try testing.expect(diags.hasErrors());
        try testing.expectEqual(@as(usize, 2), toks.len); // one invalid token + eof
        try testing.expectEqual(Token.Tag.invalid, toks[0].tag);
    }
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

test "nil-coalescing: ?? and lone ?" {
    try expectTags("a ?? b ? c", &.{
        .identifier, .question_question, .identifier, .question, .identifier,
    });
}

test "customary operator aliases: ! && || !=" {
    // The aliases emit the SAME tags as their classic spellings; a lone `&`/`|`
    // stays bitwise.
    try expectTags("&& || ! != & | a & b", &.{
        .keyword_and, .keyword_or, .keyword_not, .ne,
        .ampersand,   .pipe,       .identifier,  .ampersand,
        .identifier,
    });
}

test "tilde disambiguation: ~ ~= ~>>" {
    // `~>>` munches as one arithmetic-shift token; `~>` is `~` then `>`;
    // `~=` is inequality; bare `~` stands alone.
    try expectTags("~ ~= ~>> a ~> b ~~", &.{
        .tilde,      .ne,    .rshift_arith, .identifier,
        .tilde,      .gt,    .identifier,   .tilde,
        .tilde,
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

test "a backslash takes a whole CRLF, and \\z the whitespace after it" {
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    const toks = try tokenize(testing.allocator, "\"a\\\r\nb\" \"c\\z \r\n\t d\" x", &diags);
    defer testing.allocator.free(toks);
    try testing.expect(!diags.hasErrors());
    try testing.expectEqual(Token.Tag.string_literal, toks[0].tag);
    try testing.expectEqual(Token.Tag.string_literal, toks[1].tag);
    try testing.expectEqual(@as(u32, 3), toks[2].line); // `x`, after two newlines
}

test "a raw carriage return ends a string as unterminated" {
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    const toks = try tokenize(testing.allocator, "\"a\rb\"", &diags);
    defer testing.allocator.free(toks);
    try testing.expect(diags.hasErrors());
    try testing.expectEqual(Token.Tag.invalid, toks[0].tag);
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

test "long-bracket strings: levels, nesting, and [ as index still works" {
    // `[[..]]`, `[=[..]=]`, `[==[..]==]` are one string token each; a bare `[`
    // after a name is still an index bracket.
    try expectTags("[[a]] [=[b]=] [==[c]==]", &.{ .string_literal, .string_literal, .string_literal });
    try expectTags("t[1]", &.{ .identifier, .lbracket, .int_literal, .rbracket });
    // A level-1 long string swallows `]]` that is not its `]=]` close.
    try expectTags("[=[ has ]] inside ]=]", &.{.string_literal});
}

test "long-bracket string lexeme spans the whole literal" {
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    const src: [:0]const u8 = "x = [==[ y ]] z ]==]";
    const toks = try tokenize(testing.allocator, src, &diags);
    defer testing.allocator.free(toks);
    try testing.expect(!diags.hasErrors());
    try testing.expectEqualStrings("[==[ y ]] z ]==]", toks[2].lexeme(src));
}

test "leveled long comment is skipped, lines tracked" {
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    const src =
        \\local a --[==[ a
        \\  ]] not the close
        \\  block comment ]==]
        \\local b
    ;
    const toks = try tokenize(testing.allocator, src, &diags);
    defer testing.allocator.free(toks);
    try testing.expect(!diags.hasErrors());
    try testing.expectEqual(@as(usize, 5), toks.len); // local a local b eof
    try testing.expectEqual(Token.Tag.identifier, toks[3].tag);
    try testing.expectEqual(@as(u32, 4), toks[3].line); // `b` on line 4
}

test "unterminated long string records a diagnostic" {
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    const toks = try tokenize(testing.allocator, "x = [[oops\nmore", &diags);
    defer testing.allocator.free(toks);
    try testing.expect(diags.hasErrors());
    try testing.expectEqual(Token.Tag.invalid, toks[2].tag);
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

test "CR, CRLF and LFCR each end one line, in code, comments and long strings" {
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    const src: [:0]const u8 = "a\rb\r\nc\n\rd -- x\re --[[\r\n]] f [[\r]] g";
    const toks = try tokenize(testing.allocator, src, &diags);
    defer testing.allocator.free(toks);
    try testing.expect(!diags.hasErrors());
    const want = [_]u32{ 1, 2, 3, 4, 5, 6, 6, 7 };
    for (want, toks[0..want.len]) |line, t| try testing.expectEqual(line, t.line);
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
