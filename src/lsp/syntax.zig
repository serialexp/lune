//! Syntactic features read off the tree (doc 74 §7.1): the spans folding and
//! selection ranges use, and the document symbol outline. Byte spans in and
//! out, like `navigation.zig`; the server converts them to positions.
//!
//! Each walk is one pass over the AST and allocates the result into the
//! caller's allocator. Nothing here reads the source text.

const std = @import("std");
const ast = @import("../ast.zig");

const Span = ast.Span;

/// A tree node's span. `foldable` marks the ones a client may collapse: a
/// multi-line statement, a function, or a table constructor.
pub const Node = struct {
    span: Span,
    foldable: bool,
};

/// Every statement and expression, outer ones before the ones they contain.
pub fn nodes(a: std.mem.Allocator, root: ast.Block) std.mem.Allocator.Error![]const Node {
    var c = NodeCollector{ .a = a };
    try c.block(root);
    return c.list.toOwnedSlice(a);
}

const NodeCollector = struct {
    a: std.mem.Allocator,
    list: std.ArrayList(Node) = .empty,

    fn add(self: *NodeCollector, span: Span, foldable: bool) std.mem.Allocator.Error!void {
        try self.list.append(self.a, .{ .span = span, .foldable = foldable });
    }

    fn block(self: *NodeCollector, b: ast.Block) std.mem.Allocator.Error!void {
        for (b) |*s| try self.stmt(s);
    }

    fn exprs(self: *NodeCollector, list: []const *ast.Expr) std.mem.Allocator.Error!void {
        for (list) |e| try self.expr(e);
    }

    fn stmt(self: *NodeCollector, s: *const ast.Stmt) std.mem.Allocator.Error!void {
        try self.add(s.span, switch (s.data) {
            .do, .while_, .repeat, .if_, .numeric_for, .generic_for, .function_decl, .local_function, .global_function => true,
            else => false,
        });
        switch (s.data) {
            .local => |l| try self.exprs(l.values),
            .local_function => |lf| try self.block(lf.body.body),
            .global => |g| try self.exprs(g.values),
            .global_all => {},
            .global_function => |gf| try self.block(gf.body.body),
            .assign => |asg| {
                try self.exprs(asg.targets);
                try self.exprs(asg.values);
            },
            .compound_assign => |ca| {
                try self.expr(ca.target);
                try self.expr(ca.value);
            },
            .call => |e| try self.expr(e),
            .do => |body| try self.block(body),
            .while_ => |w| {
                try self.expr(w.cond);
                try self.block(w.body);
            },
            .repeat => |r| {
                try self.block(r.body);
                try self.expr(r.cond);
            },
            .if_ => |f| {
                for (f.branches) |br| {
                    try self.expr(br.cond);
                    try self.block(br.body);
                }
                if (f.else_body) |eb| try self.block(eb);
            },
            .numeric_for => |nf| {
                try self.expr(nf.start);
                try self.expr(nf.stop);
                if (nf.step) |st| try self.expr(st);
                try self.block(nf.body);
            },
            .generic_for => |gf| {
                try self.exprs(gf.exprs);
                try self.block(gf.body);
            },
            .function_decl => |fd| try self.block(fd.body.body),
            .return_ => |values| try self.exprs(values),
            .break_, .err => {},
        }
    }

    fn expr(self: *NodeCollector, e: *const ast.Expr) std.mem.Allocator.Error!void {
        try self.add(e.span, switch (e.data) {
            .function, .table => true,
            else => false,
        });
        switch (e.data) {
            .nil, .bool, .int, .float, .string_raw, .name, .vararg, .intrinsic, .err => {},
            .paren => |inner| try self.expr(inner),
            .string_interp => |si| try self.exprs(si.holes),
            .unary => |u| try self.expr(u.operand),
            .binary => |b| {
                try self.expr(b.lhs);
                try self.expr(b.rhs);
            },
            .field => |f| try self.expr(f.obj),
            .index => |ix| {
                try self.expr(ix.obj);
                try self.expr(ix.key);
            },
            .call => |c| {
                try self.expr(c.callee);
                try self.exprs(c.args);
            },
            .method_call => |mc| {
                try self.expr(mc.obj);
                try self.exprs(mc.args);
            },
            .function => |body| try self.block(body.body),
            .table => |fields| {
                for (fields) |f| {
                    switch (f) {
                        .positional => |v| try self.expr(v),
                        .named => |nv| try self.expr(nv.value),
                        .keyed => |kv| {
                            try self.expr(kv.key);
                            try self.expr(kv.value);
                        },
                    }
                }
            },
        }
    }
};

// ---- document symbols --------------------------------------------------------

pub const Kind = enum { function, method, variable, field, object };

/// One entry of the outline. `selection` is the name, and lies inside `range`,
/// the whole declaration.
pub const Symbol = struct {
    name: []const u8,
    kind: Kind,
    range: Span,
    selection: Span,
    children: []const Symbol,
};

/// The outline of a chunk: the declarations at its top level, with the
/// functions and table constructors they name nested under them. A plain
/// block's declarations (`do`, loop and branch bodies) join the enclosing list.
pub fn symbols(a: std.mem.Allocator, root: ast.Block) std.mem.Allocator.Error![]const Symbol {
    var c = SymbolCollector{ .a = a };
    return c.bodyOf(root);
}

const SymbolCollector = struct {
    a: std.mem.Allocator,

    fn bodyOf(self: *SymbolCollector, b: ast.Block) std.mem.Allocator.Error![]const Symbol {
        var out: std.ArrayList(Symbol) = .empty;
        try self.block(b, &out);
        return out.toOwnedSlice(self.a);
    }

    fn block(self: *SymbolCollector, b: ast.Block, out: *std.ArrayList(Symbol)) std.mem.Allocator.Error!void {
        for (b) |*s| try self.stmt(s, out);
    }

    fn stmt(self: *SymbolCollector, s: *const ast.Stmt, out: *std.ArrayList(Symbol)) std.mem.Allocator.Error!void {
        switch (s.data) {
            .local => |l| {
                for (l.names, 0..) |n, i| {
                    const value: ?*const ast.Expr = if (i < l.values.len) l.values[i] else null;
                    try out.append(self.a, try self.declared(n.name, n.name_span, s.span, value, .variable));
                }
            },
            .local_function => |lf| try out.append(self.a, .{
                .name = lf.name,
                .kind = .function,
                .range = s.span,
                .selection = lf.name_span,
                .children = try self.bodyOf(lf.body.body),
            }),
            .global => |g| {
                for (g.names, 0..) |n, i| {
                    const value: ?*const ast.Expr = if (i < g.values.len) g.values[i] else null;
                    try out.append(self.a, try self.declared(n.name, n.name_span, s.span, value, .variable));
                }
            },
            .global_function => |gf| try out.append(self.a, .{
                .name = gf.name,
                .kind = .function,
                .range = s.span,
                .selection = gf.name_span,
                .children = try self.bodyOf(gf.body.body),
            }),
            .function_decl => |fd| {
                const last = if (fd.name.method) |m| m.span else fd.name.path[fd.name.path.len - 1].span;
                try out.append(self.a, .{
                    .name = try self.funcName(fd.name),
                    .kind = if (fd.name.method != null) .method else .function,
                    .range = s.span,
                    .selection = last,
                    .children = try self.bodyOf(fd.body.body),
                });
            },
            .do => |body| try self.block(body, out),
            .while_ => |w| try self.block(w.body, out),
            .repeat => |r| try self.block(r.body, out),
            .if_ => |f| {
                for (f.branches) |br| try self.block(br.body, out);
                if (f.else_body) |eb| try self.block(eb, out);
            },
            .numeric_for => |nf| try self.block(nf.body, out),
            .generic_for => |gf| try self.block(gf.body, out),
            .assign, .compound_assign, .call, .return_, .break_, .global_all, .err => {},
        }
    }

    /// A named value: a function is a function, a table constructor an object
    /// with its fields as children, anything else `plain`.
    fn declared(
        self: *SymbolCollector,
        name: []const u8,
        name_span: Span,
        range: Span,
        value: ?*const ast.Expr,
        plain: Kind,
    ) std.mem.Allocator.Error!Symbol {
        const base: Symbol = .{ .name = name, .kind = plain, .range = range, .selection = name_span, .children = &.{} };
        const v = value orelse return base;
        return switch (v.data) {
            .function => |fb| .{ .name = name, .kind = .function, .range = range, .selection = name_span, .children = try self.bodyOf(fb.body) },
            .table => |fields| .{ .name = name, .kind = .object, .range = range, .selection = name_span, .children = try self.fieldsOf(fields) },
            else => base,
        };
    }

    fn fieldsOf(self: *SymbolCollector, list: []const ast.TableField) std.mem.Allocator.Error![]const Symbol {
        var out: std.ArrayList(Symbol) = .empty;
        for (list) |f| {
            switch (f) {
                .named => |nv| try out.append(self.a, try self.declared(
                    nv.name,
                    nv.name_span,
                    .{ .start = nv.name_span.start, .end = nv.value.span.end },
                    nv.value,
                    .field,
                )),
                .positional, .keyed => {},
            }
        }
        return out.toOwnedSlice(self.a);
    }

    /// `a.b.c` or `a.b:m`, as written.
    fn funcName(self: *SymbolCollector, n: ast.FuncName) std.mem.Allocator.Error![]const u8 {
        const names = try self.a.alloc([]const u8, n.path.len);
        for (n.path, names) |id, *slot| slot.* = id.text;
        const dotted = try std.mem.join(self.a, ".", names);
        const m = n.method orelse return dotted;
        return std.fmt.allocPrint(self.a, "{s}:{s}", .{ dotted, m.text });
    }
};

// ---- tests -------------------------------------------------------------------

const testing = std.testing;
const parser = @import("../parser.zig");
const diag = @import("../diag.zig");

test "nodes: statements and expressions, with the foldable ones marked" {
    var diags = diag.Diagnostics.init(testing.allocator);
    defer diags.deinit();
    var tree = try parser.parse(testing.allocator, "if a then f(1) end", &diags);
    defer tree.deinit();
    const ns = try nodes(testing.allocator, tree.root);
    defer testing.allocator.free(ns);
    try testing.expect(ns[0].foldable); // the `if`
    try testing.expect(!ns[1].foldable); // its condition, the name `a`
}

test "symbols: a table's functions and fields, a method's name, and a plain block's locals" {
    var diags = diag.Diagnostics.init(testing.allocator);
    defer diags.deinit();
    var tree = try parser.parse(testing.allocator,
        \\local M = {
        \\  add = function(a) return a end,
        \\  n = 1,
        \\}
        \\function M.run:go(x) do local y = 2 end end
    , &diags);
    defer tree.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const syms = try symbols(arena.allocator(), tree.root);
    try testing.expectEqual(@as(usize, 2), syms.len);
    try testing.expectEqualStrings("M", syms[0].name);
    try testing.expectEqual(Kind.object, syms[0].kind);
    try testing.expectEqual(@as(usize, 2), syms[0].children.len);
    try testing.expectEqualStrings("add", syms[0].children[0].name);
    try testing.expectEqual(Kind.function, syms[0].children[0].kind);
    try testing.expectEqual(Kind.field, syms[0].children[1].kind);
    try testing.expectEqualStrings("M.run:go", syms[1].name);
    try testing.expectEqual(Kind.method, syms[1].kind);
    try testing.expectEqualStrings("y", syms[1].children[0].name);
    try testing.expectEqual(Kind.variable, syms[1].children[0].kind);
}
