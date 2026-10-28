//! Semantic tokens (doc 74 §7.1): what each token is, for clients that colour
//! by the server's word. Names are classified from the resolver's index
//! (locals, parameters, functions, globals, built-ins), and a name with no
//! binding is a property: a table field, a method, the part after `.`.
//!
//! Tokens come out in source order, one per token, comments included; a
//! token spanning lines is left whole here and split per line by the server,
//! which is the only place that has the line index.

const std = @import("std");
const ast = @import("../ast.zig");
const diag = @import("../diag.zig");
const lexer = @import("../lexer.zig");
const token = @import("../token.zig");
const resolve = @import("../resolve.zig");
const analysis_mod = @import("analysis.zig");

const Span = ast.Span;
const Analysis = analysis_mod.Analysis;

/// The legend the server advertises. `Type` indexes `token_types`.
pub const token_types = [_][]const u8{
    "keyword", "operator", "number", "string", "comment", "function", "parameter", "variable", "property",
};
/// Modifier bits, in order: `declaration` is bit 0, `defaultLibrary` bit 1.
pub const token_modifiers = [_][]const u8{ "declaration", "defaultLibrary" };

pub const Type = enum(u8) {
    keyword,
    operator,
    number,
    string,
    comment,
    function,
    parameter,
    variable,
    property,
};

pub const modifier_declaration: u32 = 1 << 0;
pub const modifier_default_library: u32 = 1 << 1;

pub const Token = struct {
    span: Span,
    kind: Type,
    modifiers: u32 = 0,
};

/// Every token of `an.source`, in source order, comments included.
pub fn collect(a: std.mem.Allocator, an: *const Analysis, known_globals: []const []const u8) std.mem.Allocator.Error![]const Token {
    var diags = diag.Diagnostics.init(a);
    defer diags.deinit();
    var trivia = lexer.Trivia.init(a);
    defer trivia.deinit();
    const toks = try lexer.tokenizeTrivia(a, an.source, &diags, &trivia);

    var out: std.ArrayList(Token) = .empty;
    const comments = trivia.comments.items;
    var ci: usize = 0;
    // Tokens and occurrences are both in source order, so one pass finds each
    // name's occurrence without a search.
    var occ_i: usize = 0;
    for (toks) |t| {
        // A comment before this token comes first. The eof token starts at the
        // end of the text, so every comment is emitted before it.
        while (ci < comments.len and comments[ci].start < t.start) : (ci += 1) {
            try out.append(a, .{ .span = .{ .start = comments[ci].start, .end = comments[ci].end }, .kind = .comment });
        }
        if (classify(t, an, known_globals, &occ_i)) |tok| try out.append(a, tok);
    }
    for (comments[ci..]) |c| try out.append(a, .{ .span = .{ .start = c.start, .end = c.end }, .kind = .comment });
    return out.toOwnedSlice(a);
}

fn classify(t: token.Token, an: *const Analysis, known_globals: []const []const u8, occ_i: *usize) ?Token {
    const span: Span = .{ .start = t.start, .end = t.end };
    switch (t.tag) {
        .int_literal, .float_literal => return .{ .span = span, .kind = .number },
        .string_literal => return .{ .span = span, .kind = .string },
        .identifier => return identifier(an, known_globals, span, occ_i),
        // Brackets, separators and what the lexer could not read are left to
        // the editor's own bracket matching and its error marks.
        .invalid, .eof, .lparen, .rparen, .lbrace, .rbrace, .lbracket, .rbracket, .comma, .semicolon => return null,
        else => {},
    }
    const keyword = std.mem.startsWith(u8, @tagName(t.tag), "keyword_");
    return .{ .span = span, .kind = if (keyword) .keyword else .operator };
}

/// A name the resolver sees is its occurrence, of the same extent. A zero-width
/// occurrence (the implicit `self`) sits at its method's name, which is not one.
fn identifier(an: *const Analysis, known_globals: []const []const u8, span: Span, occ_i: *usize) Token {
    const occs = an.res.occurrences.items;
    while (occ_i.* < occs.len and occs[occ_i.*].span.start < span.start) occ_i.* += 1;
    if (occ_i.* >= occs.len) return .{ .span = span, .kind = .property };
    const occ = &occs[occ_i.*];
    if (occ.span.start != span.start or occ.span.end != span.end) return .{ .span = span, .kind = .property };
    const b = an.res.binding(occ.binding);
    var mods: u32 = 0;
    if (occ.access == .declare) mods |= modifier_declaration;
    const kind: Type = switch (b.kind) {
        .local_function => .function,
        .param, .self => .parameter,
        .local, .for_var, .global => .variable,
    };
    if (b.kind == .global and isKnown(known_globals, b.name)) mods |= modifier_default_library;
    return .{ .span = span, .kind = kind, .modifiers = mods };
}

fn isKnown(known_globals: []const []const u8, name: []const u8) bool {
    for (known_globals) |g| if (std.mem.eql(u8, g, name)) return true;
    return false;
}

// ---- tests -------------------------------------------------------------------

const testing = std.testing;

test "tokens: keywords, numbers, names by binding, built-ins, properties and comments" {
    var an = try analysis_mod.analyse(testing.allocator, "local x = 1 -- c\nprint(x.y)", &.{"print"}, .{});
    defer an.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try collect(arena.allocator(), &an, &.{"print"});
    const want = [_]struct { start: u32, kind: Type, modifiers: u32 }{
        .{ .start = 0, .kind = .keyword, .modifiers = 0 },
        .{ .start = 6, .kind = .variable, .modifiers = modifier_declaration },
        .{ .start = 8, .kind = .operator, .modifiers = 0 },
        .{ .start = 10, .kind = .number, .modifiers = 0 },
        .{ .start = 12, .kind = .comment, .modifiers = 0 },
        .{ .start = 17, .kind = .variable, .modifiers = modifier_default_library },
        .{ .start = 23, .kind = .variable, .modifiers = 0 },
        .{ .start = 24, .kind = .operator, .modifiers = 0 },
        .{ .start = 25, .kind = .property, .modifiers = 0 },
    };
    try testing.expectEqual(want.len, toks.len);
    for (want, toks) |w, t| {
        try testing.expectEqual(w.start, t.span.start);
        try testing.expectEqual(w.kind, t.kind);
        try testing.expectEqual(w.modifiers, t.modifiers);
    }
}

test "tokens: a method's name is a property, and its implicit self a parameter" {
    var an = try analysis_mod.analyse(testing.allocator, "local t = {}\nfunction t:m() return self end", &.{}, .{});
    defer an.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try collect(arena.allocator(), &an, &.{});
    // `m` is the name after `:`, and `self` is the parameter it introduces.
    const m = std.mem.find(u8, an.source, ":m").? + 1;
    const self_at = std.mem.find(u8, an.source, "self").?;
    for (toks) |t| {
        if (t.span.start == m) try testing.expectEqual(Type.property, t.kind);
        if (t.span.start == self_at) try testing.expectEqual(Type.parameter, t.kind);
    }
}

test "tokens: a parameter, a local function and an unterminated string do not break the list" {
    var an = try analysis_mod.analyse(testing.allocator, "local function f(p) return p end\nlocal s = \"open", &.{}, .{});
    defer an.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const toks = try collect(arena.allocator(), &an, &.{});
    // Parentheses are left out, and the unterminated string is not a token.
    try testing.expectEqual(Type.function, toks[2].kind); // `f` in `local function f`
    try testing.expectEqual(Type.parameter, toks[3].kind); // `p` in the parameter list
    try testing.expectEqual(Type.parameter, toks[5].kind); // `p` in `return p`
}
