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
    coalesce, // ??  (nil-coalescing; short-circuit, pure-nil)
    band, // &
    bor, // |
    bxor, // ~
    shl, // <<
    shr, // >>  (logical / zero-fill)
    sar, // ~>> (arithmetic / sign-extending)
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

/// A name and where it is written: the unit for name lists (`for` variables,
/// `function a.b:m` components) so every name keeps its own span.
pub const Ident = struct {
    text: []const u8,
    span: Span,
};

/// A variable attribute, `<const>` or `<close>` (doc 76 §3.1, §4, §6).
pub const Attrib = enum {
    none,
    /// `<const>`: the variable cannot be assigned again.
    @"const",
    /// `<close>`: the value's `__close` runs when the variable goes out of
    /// scope. Read-only too, as in Lua.
    close,
};

/// A name optionally annotated with a type (function params, `local` and
/// `global` names), and for a declared variable its attribute.
pub const TypedName = struct {
    name: []const u8,
    name_span: Span,
    type: ?*TypeExpr = null,
    /// The attribute in effect for this name: its own postfixed one, else the
    /// list's prefixed one (`local <const> a, b <close>`).
    attrib: Attrib = .none,
};

pub const Param = TypedName;

/// A `{ ... }` table constructor entry.
pub const TableField = union(enum) {
    /// `expr` — positional/array entry.
    positional: *Expr,
    /// `name = expr`.
    named: struct { name: []const u8, name_span: Span, value: *Expr },
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
    /// `async function` (doc 73 §7): a call starts a task running the body.
    is_async: bool = false,
    /// The proto's name when the compiler can't take it from where the
    /// function is written: an async function's body, named as the function.
    name: ?[]const u8 = null,
};

/// A library function the compiler calls by itself, not by any name a
/// program can rebind (bytecode `intrinsic`): the task library's, which
/// `async function` and `await` compile to (doc 73 §7).
pub const Intrinsic = enum(u8) {
    /// `spawn(f, ...)`: start a task running `f(...)`; returns the task.
    task_spawn,
    /// `await(x)`: `x`'s results once it settles (a task), else `x`.
    task_await,
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
        /// A backtick template (doc 82): `chunks.len == holes.len + 1`. Each
        /// chunk is the raw, still-escaped source text between holes (without
        /// delimiters); each hole is a single-valued expression.
        string_interp: struct { chunks: []const []const u8, holes: []const *Expr },
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
        field: struct { obj: *Expr, name: []const u8, name_span: Span },
        /// `obj[key]`
        index: struct { obj: *Expr, key: *Expr },
        /// `callee(args)`
        call: struct { callee: *Expr, args: []const *Expr },
        /// `obj:name(args)`
        method_call: struct { obj: *Expr, name: []const u8, name_span: Span, args: []const *Expr },
        /// `function (...) ... end` literal.
        function: *FunctionBody,
        /// An intrinsic as a value; only the parser makes one, as the
        /// callee of the call `await e` is.
        intrinsic: Intrinsic,
        /// `{ ... }`
        table: []const TableField,
        /// Source the parser could not read (error recovery, doc 74 §6.2).
        /// The span covers the text it dropped; a diagnostic already
        /// reported it. Never compiled into anything that runs.
        err,
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
    path: []const Ident,
    /// Method component after `:`, if any (`:m`). Implies an implicit `self`.
    method: ?Ident = null,
};

pub const Stmt = struct {
    span: Span,
    data: Data,

    pub const Data = union(enum) {
        /// `local a, b: T = e1, e2`
        local: struct { names: []const TypedName, values: []const *Expr },
        /// `local function f() ... end`
        local_function: struct { name: []const u8, name_span: Span, body: *FunctionBody },
        /// `global a <const>, b = e1, e2` (doc 76 §3). No `values` means no
        /// initializer: `global x` declares and leaves `x` as it is.
        global: struct { names: []const TypedName, values: []const *Expr },
        /// `global *` or `global <const> *`: every name not declared so far.
        global_all: struct { attrib: Attrib },
        /// `global function f() ... end`
        global_function: struct { name: []const u8, name_span: Span, body: *FunctionBody },
        /// `t1, t2 = e1, e2` (targets are assignable exprs).
        assign: struct { targets: []const *Expr, values: []const *Expr },
        /// `target OP= value` (single target). The compiler evaluates `target`'s
        /// prefix/index **once**, then stores `target = target OP value`. `op` is
        /// the underlying binary op (`+=` → `add`, `~=` → `bxor`, …); never a
        /// short-circuit op (`and_`/`or_`/`coalesce` have no compound form).
        compound_assign: struct { target: *Expr, op: BinaryOp, value: *Expr },
        /// A call used as a statement.
        call: *Expr,
        /// `do ... end`
        do: Block,
        /// `while c do ... end`
        while_: struct { cond: *Expr, body: Block },
        /// `repeat ... until c`. The `cond` is evaluated in the scope of `body`'s
        /// locals (Lua lets `until` reference variables declared in the body), so
        /// the compiler keeps the body scope open across the condition.
        repeat: struct { body: Block, cond: *Expr },
        /// `if c then ... elseif ... else ... end`
        if_: struct {
            branches: []const Branch,
            else_body: ?Block,
            /// Start of the `else` keyword; meaningless without an `else_body`.
            else_start: u32 = 0,
        },
        /// `for i = a, b, c do ... end`
        numeric_for: struct {
            name: []const u8,
            name_span: Span,
            start: *Expr,
            stop: *Expr,
            step: ?*Expr,
            body: Block,
        },
        /// `for k, v in e1, e2 do ... end`
        generic_for: struct {
            names: []const Ident,
            exprs: []const *Expr,
            body: Block,
        },
        /// `function a.b:m(...) ... end`
        function_decl: struct { name: FuncName, body: *FunctionBody },
        /// `return e1, e2`
        return_: []const *Expr,
        /// `break`
        break_,
        /// A statement the parser dropped (error recovery, doc 74 §6.2); the
        /// span covers the skipped text and a diagnostic already reported it.
        err,
    };

    /// `kw_start` is where the `if` / `elseif` keyword starts.
    pub const Branch = struct { kw_start: u32, cond: *Expr, body: Block };
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
