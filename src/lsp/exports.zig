//! Module exports (doc 74 §7.4, P6d): what a module file hands to `require`,
//! and the `m.` of a local a consumer bound to `require "x"`. Pure, in byte
//! spans like `navigation.zig`; the server reads the module's text and keeps
//! what `of` finds (`module_cache.zig`).
//!
//! One bounded piece of shape tracking and nothing more (anything further is
//! tier 5, §7.5). A module's exports are the named fields of the table its
//! chunk's top-level `return` returns:
//! - `return { a = 1, f = function() end }`: the constructor's named fields;
//! - `return M`, where `M` is a local or a global: the named fields of the
//!   constructor `M` is declared or assigned with, `function M.f`,
//!   `function M:m` and `M.x = ...`, written in the chunk's own code (its
//!   blocks, loops and branches) but not inside a function, which runs only
//!   when something calls it.
//!
//! On the consumer's side, a local declared alone as `local m = require("x")`
//! and never assigned again holds the module.

const std = @import("std");
const ast = @import("../ast.zig");
const lexer = @import("../lexer.zig");
const resolve = @import("../resolve.zig");
const analysis_mod = @import("analysis.zig");
const library = @import("library.zig");
const modules = @import("modules.zig");

const Analysis = analysis_mod.Analysis;
const Allocator = std.mem.Allocator;
const Span = ast.Span;

pub const Kind = enum {
    function,
    /// `function M:m()`: called as `m:m()`, with an implicit `self`.
    method,
    value,
};

pub const Export = struct {
    name: []const u8,
    /// Where the module writes the name.
    span: Span,
    kind: Kind,
    /// `f(a, b)` for a function or a method; null for a value.
    signature: ?[]const u8,
};

/// The exports of a module's chunk, in source order; the first writing of a
/// name is the one kept. Everything is allocated in `a`.
pub fn of(a: Allocator, root: ast.Block, res: *const resolve.Resolution) Allocator.Error![]const Export {
    var c: Collector = .{ .a = a, .res = res };
    const returned = returnedValue(root) orelse return &.{};
    switch (returned.data) {
        .table => |fields| try c.fields(fields),
        .name => {
            const id = res.bindingAt(returned.span.start) orelse return &.{};
            switch (res.binding(id).kind) {
                .local, .global => {},
                .param, .self, .for_var, .local_function => return &.{},
            }
            c.module = id;
            try c.block(root);
        },
        else => {},
    }
    return c.out.toOwnedSlice(a);
}

/// The one value the chunk's last statement returns, parentheses removed.
/// Text the parser dropped after it does not hide it.
fn returnedValue(root: ast.Block) ?*const ast.Expr {
    var i = root.len;
    while (i > 0) {
        i -= 1;
        switch (root[i].data) {
            .err => continue,
            .return_ => |values| {
                if (values.len != 1) return null;
                var e = values[0];
                while (e.data == .paren) e = e.data.paren;
                return e;
            },
            else => return null,
        }
    }
    return null;
}

/// Exports, gathered for the table a binding holds (`module`), or for a
/// returned constructor.
const Collector = struct {
    a: Allocator,
    res: *const resolve.Resolution,
    module: resolve.BindingId = undefined,
    out: std.ArrayList(Export) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,

    fn add(self: *Collector, name: []const u8, span: Span, kind: Kind, body: ?*const ast.FunctionBody) Allocator.Error!void {
        if ((try self.seen.getOrPut(self.a, name)).found_existing) return;
        const owned = try self.a.dupe(u8, name);
        try self.out.append(self.a, .{
            .name = owned,
            .span = span,
            .kind = kind,
            .signature = if (body) |b| try signature(self.a, owned, b, kind == .method) else null,
        });
    }

    /// `name = value`: a function value is a function, anything else a value.
    fn addValue(self: *Collector, name: []const u8, span: Span, value: ?*const ast.Expr) Allocator.Error!void {
        if (value) |v| if (v.data == .function) return self.add(name, span, .function, v.data.function);
        try self.add(name, span, .value, null);
    }

    fn fields(self: *Collector, list: []const ast.TableField) Allocator.Error!void {
        for (list) |f| switch (f) {
            .named => |n| try self.addValue(n.name, n.name_span, n.value),
            .positional, .keyed => {},
        };
    }

    /// The name token at `start` is the module's table.
    fn isModuleAt(self: *const Collector, start: u32) bool {
        return self.res.bindingAt(start) == self.module;
    }

    fn block(self: *Collector, b: ast.Block) Allocator.Error!void {
        for (b) |*s| try self.stmt(s);
    }

    fn stmt(self: *Collector, s: *const ast.Stmt) Allocator.Error!void {
        switch (s.data) {
            .local => |l| for (l.names, 0..) |n, i| {
                if (i >= l.values.len or !self.isModuleAt(n.name_span.start)) continue;
                if (l.values[i].data == .table) try self.fields(l.values[i].data.table);
            },
            .assign => |asg| for (asg.targets, 0..) |t, i| {
                const value: ?*const ast.Expr = if (i < asg.values.len) asg.values[i] else null;
                switch (t.data) {
                    // `M = { ... }`, for a global module.
                    .name => if (self.isModuleAt(t.span.start)) {
                        if (value) |v| if (v.data == .table) try self.fields(v.data.table);
                    },
                    .field => |f| if (f.obj.data == .name and self.isModuleAt(f.obj.span.start)) {
                        try self.addValue(f.name, f.name_span, value);
                    },
                    else => {},
                }
            },
            .function_decl => |fd| {
                const path = fd.name.path;
                if (!self.isModuleAt(path[0].span.start)) return;
                if (fd.name.method) |m| {
                    if (path.len == 1) try self.add(m.text, m.span, .method, fd.body);
                } else if (path.len == 2) {
                    try self.add(path[1].text, path[1].span, .function, fd.body);
                }
            },
            .do => |body| try self.block(body),
            .while_ => |w| try self.block(w.body),
            .repeat => |r| try self.block(r.body),
            .if_ => |f| {
                for (f.branches) |br| try self.block(br.body);
                if (f.else_body) |eb| try self.block(eb);
            },
            .numeric_for => |nf| try self.block(nf.body),
            .generic_for => |gf| try self.block(gf.body),
            .local_function, .compound_assign, .call, .return_, .break_, .err => {},
        }
    }
};

/// `name(a, b, ...)`. A method's `self` is implicit, so it is left out, as
/// the call `m:name(a, b)` leaves it out.
fn signature(a: Allocator, name: []const u8, body: *const ast.FunctionBody, method: bool) Allocator.Error![]const u8 {
    const params = if (method and body.params.len > 0) body.params[1..] else body.params;
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{s}(", .{name});
    for (params, 0..) |p, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, p.name);
    }
    if (body.is_vararg) try out.appendSlice(a, if (params.len > 0) ", ..." else "...");
    try out.append(a, ')');
    return out.toOwnedSlice(a);
}

/// The export named `name`, if the module has one.
pub fn find(list: []const Export, name: []const u8) ?Export {
    for (list) |e| if (std.mem.eql(u8, e.name, name)) return e;
    return null;
}

// ---- the consumer's side -----------------------------------------------------

/// A member access on a module local, at the cursor.
pub const Access = struct {
    /// The module name the local was initialised from.
    module: []const u8,
    /// `m:f` rather than `m.f`.
    method: bool,
    /// The member's identifier around the cursor; empty when none is typed yet.
    member: Span,
};

/// The member access of a module local the cursor is in or right after:
/// `m.fo|`, `m:|`, `m.f|oo`. Null anywhere else, and in a string or comment.
pub fn accessAt(a: Allocator, an: *const Analysis, offset: u32) Allocator.Error!?Access {
    const src = an.source;
    const at: usize = @min(offset, src.len);
    var s = at;
    while (s > 0 and library.isIdentByte(src[s - 1])) s -= 1;
    var e = at;
    while (e < src.len and library.isIdentByte(src[e])) e += 1;
    if (s == 0) return null;
    const method = switch (src[s - 1]) {
        ':' => true,
        // `..` is concatenation.
        '.' => if (s >= 2 and src[s - 2] == '.') return null else false,
        else => return null,
    };
    const head = library.headEndingAt(src, s - 1) orelse return null;
    // Most heads are not module locals; that is the cheaper question, so it
    // goes before the lex from the start of the text.
    const module = moduleOf(an, head) orelse return null;
    if (try lexer.contextAt(a, src, offset) != .code) return null;
    return .{ .module = module, .method = method, .member = .{ .start = @intCast(s), .end = @intCast(e) } };
}

/// The module the local named at `head` holds, if it is one.
fn moduleOf(an: *const Analysis, head: Span) ?[]const u8 {
    const src = an.source;
    const id = library.localAt(an, src[head.start..head.end], head.start) orelse return null;
    const b = an.res.binding(id);
    if (b.kind != .local) return null;
    // Assigned again, it may hold anything.
    for (an.res.occurrences.items) |o| {
        if (o.binding == id and (o.access == .write or o.access == .read_write)) return null;
    }
    return initialiser(an, b.decl_span.end);
}

fn skipSpace(src: []const u8, from: usize) usize {
    var i = from;
    while (i < src.len and std.ascii.isWhitespace(src[i])) i += 1;
    return i;
}

/// The module name when the text after a local's name is ` = require("x")`
/// and nothing more: a single name, initialised by the call to the global
/// `require` with a plain literal. Read from the text right there, so it
/// costs the length of the line, whatever the file's size.
fn initialiser(an: *const Analysis, name_end: usize) ?[]const u8 {
    const src = an.source;
    var i = skipSpace(src, name_end);
    if (i >= src.len or src[i] != '=') return null;
    i = skipSpace(src, i + 1);
    const word = "require";
    if (!std.mem.startsWith(u8, src[i..], word)) return null;
    const call = i;
    i += word.len;
    if (i < src.len and library.isIdentByte(src[i])) return null;
    if (!modules.isGlobal(an, word, @intCast(call))) return null;
    i = skipSpace(src, i);
    if (i >= src.len or src[i] != '(') return null;
    // The literal ends at its quote; an escaped quote, a newline or a long
    // bracket leaves no plain name.
    const open = skipSpace(src, i + 1);
    if (open >= src.len or (src[open] != '"' and src[open] != '\'')) return null;
    const close = std.mem.findScalarPos(u8, src, open + 1, src[open]) orelse return null;
    if (std.mem.findScalar(u8, src[open..close], '\n') != null) return null;
    const name = modules.plainName(src[open .. close + 1]) orelse return null;
    if (!endsAt(src, close + 1)) return null;
    return name;
}

/// The call ends with the literal and its `)`: `require("x").sub` or
/// `require("x")()` would hold something else.
fn endsAt(src: []const u8, literal_end: usize) bool {
    var i = skipSpace(src, literal_end);
    if (i >= src.len or src[i] != ')') return false;
    i = skipSpace(src, i + 1);
    if (i >= src.len) return true;
    return std.mem.findScalar(u8, ".:[({\"'", src[i]) == null;
}

// ---- tests -------------------------------------------------------------------

const testing = std.testing;
const known = [_][]const u8{ "print", "require" };

fn exportsOf(arena: Allocator, src: []const u8) ![]const Export {
    var an = try analysis_mod.analyse(testing.allocator, src, &known, .{});
    defer an.deinit();
    return of(arena, an.tree.root, &an.res);
}

fn names(arena: Allocator, list: []const Export) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (list, 0..) |e, i| {
        if (i > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, e.name);
    }
    return out.items;
}

test "exports: the returned local's constructor, functions, methods and assigned fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\local M = { version = 1, make = function(x, ...) end }
        \\function M.add(a, b) end
        \\function M:size() end
        \\M.name = "m"
        \\if debug then M.trace = print end
        \\local function helper() M.later = 1 end
        \\function M.add() end
        \\local other = {}
        \\other.no = 1
        \\return M
    ;
    const list = try exportsOf(a, src);
    try testing.expectEqualStrings("version make add size name trace", try names(a, list));
    try testing.expectEqual(Kind.value, list[0].kind);
    try testing.expectEqualStrings("make(x, ...)", list[1].signature.?);
    // The first `add` is the one kept.
    try testing.expectEqualStrings("add(a, b)", list[2].signature.?);
    try testing.expectEqual(@as(u32, @intCast(std.mem.find(u8, src, "add(a").?)), list[2].span.start);
    try testing.expectEqual(Kind.method, list[3].kind);
    try testing.expectEqualStrings("size()", list[3].signature.?);
    try testing.expectEqual(Kind.value, list[5].kind);
}

test "exports: a returned constructor, a global module, and what is not a module" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("a f", try names(a, try exportsOf(a, "return ({ a = 1, [2] = 3, 4, f = function() end })")));
    try testing.expectEqualStrings("x g", try names(a, try exportsOf(a, "G = { x = 1 }\nfunction G.g() end\nreturn G")));
    try testing.expectEqual(@as(usize, 0), (try exportsOf(a, "local M = {}\nM.a = 1")).len);
    try testing.expectEqual(@as(usize, 0), (try exportsOf(a, "local M = {}\nM.a = 1\nreturn M, 2")).len);
    try testing.expectEqual(@as(usize, 0), (try exportsOf(a, "return make()")).len);
    try testing.expectEqual(@as(usize, 0), (try exportsOf(a, "local function f() end\nreturn f")).len);
    // Text the parser dropped after the return does not hide it.
    try testing.expectEqualStrings("a", try names(a, try exportsOf(a, "return { a = 1 }\n)")));
}

/// `accessAt` at the `|` in `marked`.
fn accessIn(arena: Allocator, marked: []const u8) !?Access {
    const bar = std.mem.find(u8, marked, "|").?;
    const src = try std.mem.concat(arena, u8, &.{ marked[0..bar], marked[bar + 1 ..] });
    var an = try analysis_mod.analyse(testing.allocator, src, &known, .{});
    defer an.deinit();
    var got = (try accessAt(arena, &an, @intCast(bar))) orelse return null;
    got.module = try arena.dupe(u8, got.module);
    return got;
}

test "access: a module local's dot or colon, typed or not, in damaged text too" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dot = (try accessIn(a, "local m = require(\"a.b\")\nm.|")).?;
    try testing.expectEqualStrings("a.b", dot.module);
    try testing.expect(!dot.method);
    try testing.expectEqual(dot.member.start, dot.member.end);
    const colon = (try accessIn(a, "local m = require(\"a\")\nm:fo|o()")).?;
    try testing.expect(colon.method);
    try testing.expectEqual(@as(u32, 3), colon.member.end - colon.member.start);
    try testing.expect(try accessIn(a, "local m = require ( 'a' )\nlocal function f() return m.x| end") != null);
}

test "access: nothing for another value, a reassigned or shadowed local, or a call's result" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(try accessIn(a, "local m = {}\nm.|") == null);
    try testing.expect(try accessIn(a, "local m = require(\"a\")\nm = {}\nprint(m.x|)") == null);
    try testing.expect(try accessIn(a, "local m = require(\"a\")\nm = {}\nm.|") == null);
    try testing.expect(try accessIn(a, "local m = require(\"a\")\ndo local m = {}\nm.| end") == null);
    try testing.expect(try accessIn(a, "local m = require(\"a\").sub\nm.|") == null);
    try testing.expect(try accessIn(a, "local m = require(name)\nm.|") == null);
    try testing.expect(try accessIn(a, "local x, m = 1, require(\"a\")\nm.|") == null);
    try testing.expect(try accessIn(a, "m = require(\"a\")\nm.|") == null);
    try testing.expect(try accessIn(a, "local m = require(\"a\")\nx = m ..|") == null);
    try testing.expect(try accessIn(a, "local m = require(\"a\")\nx = \"m.|\"") == null);
    // The local still holds the module where a later shadow is not yet seen.
    try testing.expect(try accessIn(a, "local m = require(\"a\")\nm.|\nlocal m = 1") != null);
}
