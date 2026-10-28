//! `require` resolution (doc 74 §7.4). Pure: a resolver takes a probe that says
//! whether a file exists, and the server supplies the real one. The search
//! mirrors `package.searchpath` with the default searchers: a built-in module
//! short-circuits, then each `package.path` template is tried in order with
//! `?` replaced by the module name (dots become `/`), relative to the runtime
//! working directory.
//!
//! Only a plain string-literal argument to an unshadowed `require` names a
//! module. Anything else is a dynamic site, which is reported as such, never as
//! an error.

const std = @import("std");
const ast = @import("../ast.zig");
const diag = @import("../diag.zig");
const lexer = @import("../lexer.zig");
const token = @import("../token.zig");
const analysis_mod = @import("analysis.zig");
const library = @import("library.zig");

const Analysis = analysis_mod.Analysis;
pub const Span = ast.Span;

/// Modules the runtime already has loaded, so `require` never searches for them
/// (`stdlib/package.zig`, plus `_G`).
pub const builtin_modules = [_][]const u8{ "_G", "package", "coroutine", "string", "table", "math", "os", "io" };

/// Whether `path` names an existing file. The server answers from disk or from
/// an open document.
pub const Probe = struct {
    context: *anyopaque,
    exists: *const fn (context: *anyopaque, path: []const u8) bool,
};

pub const Resolution = union(enum) {
    /// A built-in module; no file.
    builtin,
    /// The first candidate that exists, joined with the working directory.
    file: []const u8,
    /// Every candidate tried, in order, for "no file 'x'" messages.
    missing: []const []const u8,
};

/// `a.b` as the path it searches: `a/b`.
pub fn mappedName(a: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.mem.replaceOwned(u8, a, name, ".", "/");
}

/// The candidate paths for `name`, one per template, with `cwd` joined in. A
/// `.` cwd is left out, so the paths read as the templates do (`./a/b.mah`).
pub fn candidates(
    a: std.mem.Allocator,
    cwd: []const u8,
    templates: []const []const u8,
    name: []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    const mapped = try mappedName(a, name);
    const out = try a.alloc([]const u8, templates.len);
    for (templates, out) |t, *slot| {
        const sub = try std.mem.replaceOwned(u8, a, t, "?", mapped);
        slot.* = if (std.mem.eql(u8, cwd, ".")) sub else try std.fs.path.join(a, &.{ cwd, sub });
    }
    return out;
}

/// Resolve `name`. A built-in wins without a probe; otherwise the first existing
/// candidate wins, in template order.
pub fn resolve(
    a: std.mem.Allocator,
    name: []const u8,
    cwd: []const u8,
    templates: []const []const u8,
    probe: Probe,
) std.mem.Allocator.Error!Resolution {
    for (builtin_modules) |b| {
        if (std.mem.eql(u8, b, name)) return .builtin;
    }
    const cands = try candidates(a, cwd, templates, name);
    for (cands) |path| {
        if (probe.exists(probe.context, path)) return .{ .file = path };
    }
    return .{ .missing = cands };
}

/// One `require` in a file. `name` is null for a dynamic site: a non-literal
/// argument, or a literal with escapes. `span` is the string literal, or the
/// `require` name itself when the argument is dynamic.
pub const Site = struct {
    span: Span,
    name: ?[]const u8,
};

/// Every `require` call in the analysed source, in source order. A `require`
/// that is a local or a parameter, or is a field (`t.require`, `t:require`), is
/// not the global and is skipped.
pub fn sites(a: std.mem.Allocator, an: *const Analysis) std.mem.Allocator.Error![]const Site {
    var diags = diag.Diagnostics.init(a);
    defer diags.deinit();
    const toks = try lexer.tokenize(a, an.source, &diags);

    var out: std.ArrayList(Site) = .empty;
    for (toks, 0..) |t, i| {
        if (t.tag != .identifier) continue;
        const word = an.source[t.start..t.end];
        if (!std.mem.eql(u8, word, "require")) continue;
        if (i > 0 and (toks[i - 1].tag == .dot or toks[i - 1].tag == .colon)) continue;
        if (library.isLocal(an, word, t.start)) continue;

        // `require "a"` or `require("a")`.
        const arg_i = if (i + 1 < toks.len and toks[i + 1].tag == .lparen) i + 2 else i + 1;
        if (arg_i >= toks.len) continue;
        const arg = toks[arg_i];
        if (arg.tag == .string_literal and literalFollowedByClose(toks, i, arg_i)) {
            try out.append(a, .{ .span = .{ .start = arg.start, .end = arg.end }, .name = plainName(an.source[arg.start..arg.end]) });
        } else if (i + 1 < toks.len and toks[i + 1].tag == .lparen) {
            try out.append(a, .{ .span = .{ .start = t.start, .end = t.end }, .name = null });
        }
    }
    return out.toOwnedSlice(a);
}

/// The argument is followed by `)` when the call was parenthesised, and by
/// nothing when it was `require "a"`. A `require("a" .. b)` is not a literal.
fn literalFollowedByClose(toks: []const token.Token, require_i: usize, arg_i: usize) bool {
    if (arg_i == require_i + 1) return true;
    const after = arg_i + 1;
    return after < toks.len and toks[after].tag == .rparen;
}

/// The module name inside a plain `"..."` or `'...'` literal. Escapes and long
/// brackets are not decoded, so they are dynamic (null).
fn plainName(lexeme: []const u8) ?[]const u8 {
    if (lexeme.len < 2) return null;
    const q = lexeme[0];
    if ((q != '"' and q != '\'') or lexeme[lexeme.len - 1] != q) return null;
    const inner = lexeme[1 .. lexeme.len - 1];
    if (std.mem.findScalar(u8, inner, '\\') != null) return null;
    return inner;
}

// ---- tests -------------------------------------------------------------------

const testing = std.testing;

/// A probe over a fixed set of paths.
const FakeFs = struct {
    files: []const []const u8,

    fn probe(self: *FakeFs) Probe {
        return .{ .context = self, .exists = exists };
    }

    fn exists(context: *anyopaque, path: []const u8) bool {
        const self: *FakeFs = @ptrCast(@alignCast(context));
        for (self.files) |f| {
            if (std.mem.eql(u8, f, path)) return true;
        }
        return false;
    }
};

const default_templates = [_][]const u8{ "./?.mah", "./?/init.mah" };

test "modules: a dotted name maps to a path, and templates are tried in order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("a/b/c", try mappedName(a, "a.b.c"));

    const cands = try candidates(a, "src", &default_templates, "a.b");
    try testing.expectEqualStrings("src/./a/b.mah", cands[0]);
    try testing.expectEqualStrings("src/./a/b/init.mah", cands[1]);

    // The init file exists and the plain one does not: the second template wins.
    var fs: FakeFs = .{ .files = &.{"src/./a/b/init.mah"} };
    const r = try resolve(a, "a.b", "src", &default_templates, fs.probe());
    try testing.expectEqualStrings("src/./a/b/init.mah", r.file);
}

test "modules: a built-in short-circuits, and a miss lists every candidate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fs: FakeFs = .{ .files = &.{"./string.mah"} };
    // `string` is built in, so the file next to it is never looked at.
    try testing.expectEqual(Resolution.builtin, try resolve(a, "string", ".", &default_templates, fs.probe()));

    const miss = try resolve(a, "nope.x", ".", &default_templates, fs.probe());
    try testing.expectEqual(@as(usize, 2), miss.missing.len);
    try testing.expectEqualStrings("./nope/x.mah", miss.missing[0]);
}

fn sitesOf(arena: std.mem.Allocator, src: [:0]const u8) ![]const Site {
    var an = try analysis_mod.analyse(testing.allocator, src, &.{}, .{});
    defer an.deinit();
    const s = try sites(arena, &an);
    // The names borrow from `an.source`; copy them out before it is freed.
    const out = try arena.alloc(Site, s.len);
    for (s, out) |it, *slot| {
        slot.* = it;
        if (it.name) |n| slot.name = try arena.dupe(u8, n);
    }
    return out;
}

test "modules: a literal require names its module, with or without parentheses" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try sitesOf(arena.allocator(),
        \\local a = require("a.b")
        \\local c = require 'c'
    );
    try testing.expectEqual(@as(usize, 2), s.len);
    try testing.expectEqualStrings("a.b", s[0].name.?);
    try testing.expectEqualStrings("c", s[1].name.?);
}

test "modules: dynamic arguments are sites with no name, not errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try sitesOf(arena.allocator(),
        \\local x = require(path)
        \\local y = require("a" .. b)
        \\local z = require("e\"x")
    );
    try testing.expectEqual(@as(usize, 3), s.len);
    for (s) |site| try testing.expect(site.name == null);
}

test "modules: a shadowed or field require is not the global one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try sitesOf(arena.allocator(),
        \\local function f(require)
        \\  return require("inner")
        \\end
        \\local t = {}
        \\t.require("field")
        \\t:require("method")
        \\require("global")
    );
    try testing.expectEqual(@as(usize, 1), s.len);
    try testing.expectEqualStrings("global", s[0].name.?);
}
