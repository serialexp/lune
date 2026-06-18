//! Tokens for the Lua-shaped surface syntax.
//!
//! A `Token` is a tag plus a byte span into the source (and a line, for
//! diagnostics). Literal *values* are not stored here — they are derived from
//! the source slice when the parser needs them. The one lexical decision baked
//! into the tag is **int vs float** (`int_literal` / `float_literal`), because
//! lune has first-class `i64` and `f64` (see Phase 1) and the distinction is
//! purely syntactic (presence of `.` or an exponent).

const std = @import("std");

pub const Token = struct {
    tag: Tag,
    /// Byte offset of the first character (inclusive).
    start: u32,
    /// Byte offset just past the last character (exclusive). Lexeme is
    /// `source[start..end]`.
    end: u32,
    /// 1-based line of `start`, for diagnostics.
    line: u32,

    pub fn lexeme(self: Token, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }

    pub const Tag = enum {
        // literals
        int_literal,
        float_literal,
        string_literal,
        identifier,

        // keywords
        keyword_and,
        keyword_break,
        keyword_do,
        keyword_else,
        keyword_elseif,
        keyword_end,
        keyword_false,
        keyword_for,
        keyword_function,
        keyword_if,
        keyword_in,
        keyword_local,
        keyword_nil,
        keyword_not,
        keyword_or,
        keyword_repeat,
        keyword_return,
        keyword_then,
        keyword_true,
        keyword_until,
        keyword_while,

        // punctuation & operators
        plus, // +
        minus, // -
        star, // *
        slash, // /
        slash_slash, // //  (floor division)
        percent, // %
        caret, // ^   (exponentiation)
        hash, // #   (length)
        ampersand, // &   (bitwise and)
        pipe, // |   (bitwise or)
        tilde, // ~   (bitwise xor / unary not)
        lshift, // <<
        rshift, // >>
        eq, // ==
        ne, // ~=
        lt, // <
        gt, // >
        le, // <=
        ge, // >=
        assign, // =
        lparen, // (
        rparen, // )
        lbrace, // {
        rbrace, // }
        lbracket, // [
        rbracket, // ]
        semicolon, // ;
        colon, // :   (method call; also reserved for type annotations)
        double_colon, // ::  (reserved: labels / annotations)
        comma, // ,
        dot, // .
        dot_dot, // ..  (concatenation)
        ellipsis, // ... (varargs)

        // sentinels
        eof,
        /// A lexing error occurred at this span; a diagnostic was recorded.
        invalid,

        /// Human-readable name for diagnostics / debugging.
        pub fn lexerName(tag: Tag) []const u8 {
            return switch (tag) {
                .int_literal => "integer",
                .float_literal => "float",
                .string_literal => "string",
                .identifier => "identifier",
                .eof => "end of file",
                .invalid => "invalid token",
                else => tag.symbol() orelse @tagName(tag),
            };
        }

        /// The canonical spelling for fixed tokens (keywords/operators), or null
        /// for tokens whose text varies (literals, identifiers).
        pub fn symbol(tag: Tag) ?[]const u8 {
            return switch (tag) {
                .keyword_and => "and",
                .keyword_break => "break",
                .keyword_do => "do",
                .keyword_else => "else",
                .keyword_elseif => "elseif",
                .keyword_end => "end",
                .keyword_false => "false",
                .keyword_for => "for",
                .keyword_function => "function",
                .keyword_if => "if",
                .keyword_in => "in",
                .keyword_local => "local",
                .keyword_nil => "nil",
                .keyword_not => "not",
                .keyword_or => "or",
                .keyword_repeat => "repeat",
                .keyword_return => "return",
                .keyword_then => "then",
                .keyword_true => "true",
                .keyword_until => "until",
                .keyword_while => "while",
                .plus => "+",
                .minus => "-",
                .star => "*",
                .slash => "/",
                .slash_slash => "//",
                .percent => "%",
                .caret => "^",
                .hash => "#",
                .ampersand => "&",
                .pipe => "|",
                .tilde => "~",
                .lshift => "<<",
                .rshift => ">>",
                .eq => "==",
                .ne => "~=",
                .lt => "<",
                .gt => ">",
                .le => "<=",
                .ge => ">=",
                .assign => "=",
                .lparen => "(",
                .rparen => ")",
                .lbrace => "{",
                .rbrace => "}",
                .lbracket => "[",
                .rbracket => "]",
                .semicolon => ";",
                .colon => ":",
                .double_colon => "::",
                .comma => ",",
                .dot => ".",
                .dot_dot => "..",
                .ellipsis => "...",
                else => null,
            };
        }
    };
};

/// Keyword lookup: identifier text → keyword tag, or null if it is a plain
/// identifier. Built at comptime.
pub const keywords = std.StaticStringMap(Token.Tag).initComptime(.{
    .{ "and", .keyword_and },
    .{ "break", .keyword_break },
    .{ "do", .keyword_do },
    .{ "else", .keyword_else },
    .{ "elseif", .keyword_elseif },
    .{ "end", .keyword_end },
    .{ "false", .keyword_false },
    .{ "for", .keyword_for },
    .{ "function", .keyword_function },
    .{ "if", .keyword_if },
    .{ "in", .keyword_in },
    .{ "local", .keyword_local },
    .{ "nil", .keyword_nil },
    .{ "not", .keyword_not },
    .{ "or", .keyword_or },
    .{ "repeat", .keyword_repeat },
    .{ "return", .keyword_return },
    .{ "then", .keyword_then },
    .{ "true", .keyword_true },
    .{ "until", .keyword_until },
    .{ "while", .keyword_while },
});

/// Resolve an identifier lexeme to a keyword tag, or `.identifier`.
pub fn identifierTag(text: []const u8) Token.Tag {
    return keywords.get(text) orelse .identifier;
}

test "keyword lookup distinguishes keywords from identifiers" {
    try std.testing.expectEqual(Token.Tag.keyword_function, identifierTag("function"));
    try std.testing.expectEqual(Token.Tag.keyword_end, identifierTag("end"));
    try std.testing.expectEqual(Token.Tag.identifier, identifierTag("foo"));
    try std.testing.expectEqual(Token.Tag.identifier, identifierTag("endx"));
    try std.testing.expectEqual(Token.Tag.identifier, identifierTag("End"));
}

test "symbol/lexerName round-trips for fixed tokens" {
    try std.testing.expectEqualStrings("//", Token.Tag.slash_slash.symbol().?);
    try std.testing.expectEqualStrings("...", Token.Tag.ellipsis.symbol().?);
    try std.testing.expect(Token.Tag.identifier.symbol() == null);
    try std.testing.expectEqualStrings("integer", Token.Tag.int_literal.lexerName());
}
