//! Abstract syntax tree for the Lua-shaped surface syntax.
//!
//! This is the contract the bytecode compiler (Phase 3) consumes, so it aims to
//! be clear and faithful to source structure rather than maximally compact. v1
//! uses a classic pointer-based tagged-union tree, arena-allocated and freed in
//! one shot (the AST is built once; the hot path is the interpreter/JIT, not the
//! parser). A flat index-based AST (à la the Zig compiler) is a possible later
//! optimisation; nothing here precludes it.
//!
//! Every node carries a source `Span` — diagnostics need it, and the time-travel
//! visualiser will map runtime events back to source with it.
//!
//! Type annotations are **parsed and retained but not checked** in v1 (the doc
//! says reserve the syntax now). `TypeExpr` is intentionally minimal.

const std = @import("std");

/// Byte span `[start, end)` into the source.
pub const Span = struct {
    start: u32,
    end: u32,
};

pub const BinaryOp = enum {
    add, // +
    sub, // -
    mul, // *
    div, // /     (always float, Phase 1)
    idiv, // //    (floor division)
    mod, // %
    pow, // ^
    concat, // ..
    eq, // ==
    ne, // ~=
    lt, // <
    le, // <=
    gt, // >
    ge, // >=
    and_, // and
    or_, // or
    band, // &
    bor, // |
    bxor, // ~
    shl, // <<
    shr, // >>
};

pub const UnaryOp = enum {
    neg, // -
    not, // not
    len, // #
    bnot, // ~
};

/// A reserved, unchecked type annotation: a dotted name with an optional `?`.
/// Example: `Foo.Bar?`. Kept so the syntax exists and the visualiser/type
/// checker can use it later.
pub const TypeExpr = struct {
    span: Span,
    /// Dotted path components, e.g. `["Foo", "Bar"]`.
    path: []const []const u8,
    optional: bool = false,
};

/// A name optionally annotated with a type (function params, `local` names).
pub const TypedName = struct {
    name: []const u8,
    name_span: Span,
    type: ?*TypeExpr = null,
};

pub const Param = TypedName;

/// A `{ ... }` table constructor entry.
pub const TableField = union(enum) {
    /// `expr` — positional/array entry.
    positional: *Expr,
    /// `name = expr`.
    named: struct { name: []const u8, value: *Expr },
    /// `[key] = expr`.
    keyed: struct { key: *Expr, value: *Expr },
};

pub const FunctionBody = struct {
    span: Span,
    params: []const Param,
    is_vararg: bool,
    /// Reserved return-type annotation (unchecked in v1).
    ret_type: ?*TypeExpr = null,
    body: Block,
};

pub const Expr = struct {
    span: Span,
    data: Data,

    pub const Data = union(enum) {
        nil,
        bool: bool,
        int: i64,
        float: f64,
        /// Raw string lexeme *including* quotes; escape decoding is deferred to
        /// Phase 3 (when string objects are built). Stored as a source slice.
        string_raw: []const u8,
        /// Identifier reference.
        name: []const u8,
        /// `...`
        vararg,
        /// `( expr )` — preserved because Lua parentheses truncate a multi-value
        /// expression to a single value.
        paren: *Expr,
        unary: struct { op: UnaryOp, operand: *Expr },
        binary: struct { op: BinaryOp, lhs: *Expr, rhs: *Expr },
        /// `obj.name`
        field: struct { obj: *Expr, name: []const u8 },
        /// `obj[key]`
        index: struct { obj: *Expr, key: *Expr },
        /// `callee(args)`
        call: struct { callee: *Expr, args: []const *Expr },
        /// `obj:name(args)`
        method_call: struct { obj: *Expr, name: []const u8, args: []const *Expr },
        /// `function (...) ... end` literal.
        function: *FunctionBody,
        /// `{ ... }`
        table: []const TableField,
    };

    /// Is this expression a valid assignment target (lvalue)?
    pub fn isAssignable(self: *const Expr) bool {
        return switch (self.data) {
            .name, .field, .index => true,
            else => false,
        };
    }

    /// Is this expression a call (the only expression allowed as a statement)?
    pub fn isCall(self: *const Expr) bool {
        return switch (self.data) {
            .call, .method_call => true,
            else => false,
        };
    }
};

/// A `function a.b.c:m` declaration target.
pub const FuncName = struct {
    /// Dotted path, e.g. `a.b.c` → `["a","b","c"]`. At least one element.
    path: []const []const u8,
    /// Method component after `:`, if any (`:m`). Implies an implicit `self`.
    method: ?[]const u8 = null,
};

pub const Stmt = struct {
    span: Span,
    data: Data,

    pub const Data = union(enum) {
        /// `local a, b: T = e1, e2`
        local: struct { names: []const TypedName, values: []const *Expr },
        /// `local function f() ... end`
        local_function: struct { name: []const u8, body: *FunctionBody },
        /// `t1, t2 = e1, e2` (targets are assignable exprs).
        assign: struct { targets: []const *Expr, values: []const *Expr },
        /// A call used as a statement.
        call: *Expr,
        /// `do ... end`
        do: Block,
        /// `while c do ... end`
        while_: struct { cond: *Expr, body: Block },
        /// `if c then ... elseif ... else ... end`
        if_: struct { branches: []const Branch, else_body: ?Block },
        /// `for i = a, b, c do ... end`
        numeric_for: struct {
            name: []const u8,
            start: *Expr,
            stop: *Expr,
            step: ?*Expr,
            body: Block,
        },
        /// `for k, v in e1, e2 do ... end`
        generic_for: struct {
            names: []const []const u8,
            exprs: []const *Expr,
            body: Block,
        },
        /// `function a.b:m(...) ... end`
        function_decl: struct { name: FuncName, body: *FunctionBody },
        /// `return e1, e2`
        return_: []const *Expr,
        /// `break`
        break_,
    };

    pub const Branch = struct { cond: *Expr, body: Block };
};

/// A block is a sequence of statements (slice provides the indirection that
/// breaks the Stmt ↔ Block type cycle).
pub const Block = []const Stmt;

/// The parsed program plus the arena that owns every node. `deinit` frees it
/// all at once.
pub const Ast = struct {
    arena: std.heap.ArenaAllocator,
    source: [:0]const u8,
    root: Block,

    pub fn deinit(self: *Ast) void {
        self.arena.deinit();
    }
};

test "ast node predicates" {
    var name_expr = Expr{ .span = .{ .start = 0, .end = 1 }, .data = .{ .name = "x" } };
    try std.testing.expect(name_expr.isAssignable());
    try std.testing.expect(!name_expr.isCall());

    var call_expr = Expr{
        .span = .{ .start = 0, .end = 3 },
        .data = .{ .call = .{ .callee = &name_expr, .args = &.{} } },
    };
    try std.testing.expect(call_expr.isCall());
    try std.testing.expect(!call_expr.isAssignable());

    const lit = Expr{ .span = .{ .start = 0, .end = 1 }, .data = .{ .int = 7 } };
    try std.testing.expect(!lit.isAssignable());
    try std.testing.expect(!lit.isCall());
}
