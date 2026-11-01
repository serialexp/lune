//! Name resolution: which declaration each name in a chunk refers to.
//!
//! One pass over the AST, before code generation, that owns mahina's scoping
//! rules (doc 74 §6.3): a `local`'s value is evaluated before its names are
//! visible, a `local function` sees itself, `repeat … until` sees the body's
//! locals, a name not found in any enclosing function is a global, and so is
//! `_G.x` (or `_G["x"]`, `_G:x(…)`, `function _G.x()`) while `_G` is the
//! global: the runtime's `_G` is the globals table. The
//! compiler asks this table which binding a name is instead of resolving it
//! by string, and the language server reads the same table for navigation, so
//! there is exactly one scoping model.
//!
//! It also owns Lua 5.5's global declarations and the attributes (doc 76
//! §3.2, §3.4, §4): a `global x` is in scope like a local and resolves `x` to
//! the global; inside the scope of any `global` declaration a free name no
//! declaration covers is an error, unless a `global *` is in scope too; and
//! an assignment to a `<const>` or `<close>` variable, a `for` control
//! variable, or a global declared `<const>` is an error. Both kinds are
//! `problems`, which the compiler reports.
//!
//! The result is two flat arrays. `bindings` is one entry per declaration
//! (plus one per distinct global name); `occurrences` is one entry per name
//! token (a declaration's own name included), sorted by source position, so
//! "which binding is the name at this offset" is a binary search and nothing
//! is allocated per occurrence.
//!
//! The pass is total: an AST holding error nodes (parser recovery) resolves
//! like any other, and the error nodes contribute no names.

const std = @import("std");
const ast = @import("ast.zig");
const token = @import("token.zig");

const Span = ast.Span;

pub const BindingId = u32;

pub const Kind = enum {
    /// `local x`.
    local,
    /// A declared function parameter.
    param,
    /// The implicit first parameter of `function a:m()`.
    self,
    /// A `for` loop variable, numeric or generic.
    for_var,
    /// `local function f`.
    local_function,
    /// A name no enclosing scope declares. One binding per distinct name.
    global,
};

pub const Access = enum {
    /// The declaring occurrence of a name.
    declare,
    read,
    write,
    /// `x += 1`.
    read_write,
};

pub const Binding = struct {
    kind: Kind,
    name: []const u8,
    /// A local's attribute; `.@"const"` for a `for` control variable. Always
    /// `.none` for a global, whose read-only-ness belongs to a declaration in
    /// scope, not to the name.
    attrib: ast.Attrib = .none,
    /// Where the name is declared. The implicit `self` has a zero-width span
    /// at the method name. A global has no declaration: this is its first
    /// write, or its first use when it is never written.
    decl_span: Span,
    /// The offset from which the name means this binding. The scope runs
    /// `[visible_from, scope_end)`. A global is visible everywhere.
    visible_from: u32,
    /// Where the scope ends: the start of the keyword that closes it (`end`,
    /// `elseif`, `else`), so a cursor just before it still sees the block's
    /// names and one just after the construct does not. A `repeat` scope also
    /// holds its `until` condition and ends with it.
    scope_end: u32,
    /// The function that declares it: 0 is the chunk, then pre-order. A
    /// global belongs to no function.
    func: u32,
    /// Some function other than the declaring one refers to it.
    captured: bool = false,
    /// Doc 76 D8: a `<const>` local whose value is a constant (`nil`, a
    /// boolean, a number, a string, or another such local) stands for that
    /// literal, which every use compiles to; the local gets no register.
    value: ?*const ast.Expr = null,
};

pub const Occurrence = struct {
    span: Span,
    binding: BindingId,
    access: Access,
    /// A global named through the globals table (`_G.x`, `_G["x"]`), not by
    /// itself: no local can capture it, whatever is in scope.
    qualified: bool = false,
    /// A global named by a `global x` declaration in scope (or its own
    /// declaration): the program says it exists, so the unknown-global lint
    /// keeps quiet about it. `Resolution.declarationOf` finds which.
    declared: bool = false,
    /// The name cannot be assigned here (doc 76 §3.4, §4): a `<const>` or
    /// `<close>` local, a `for` control variable, a global declared
    /// `<const>`, or a free name under a `global <const> *`.
    readonly: bool = false,

    // A file has one per name token, and the symbol index keeps them for
    // every file of a workspace: the flags ride in padding.
    comptime {
        std.debug.assert(@sizeOf(Occurrence) == 16);
    }
};

/// A `global x` declaration (doc 76 §3.2) and the text it covers.
pub const GlobalDeclaration = struct {
    binding: BindingId,
    /// The declared name.
    span: Span,
    attrib: ast.Attrib,
    /// Where its scope ends, as `Binding.scope_end`.
    scope_end: u32 = std.math.maxInt(u32),
};

/// A `global *` or `global <const> *` (doc 76 §3.2) and the text it covers.
pub const GlobalAll = struct {
    /// Where the statement starts.
    start: u32,
    attrib: ast.Attrib,
    scope_end: u32 = std.math.maxInt(u32),
};

/// A scoping rule the program breaks (doc 76 §3.2, §4.1); a compile error.
pub const Problem = struct {
    code: Code,
    /// The name as written.
    span: Span,
    name: []const u8,

    pub const Code = enum {
        /// A free name in the scope of a `global` declaration that declares
        /// neither it nor `*`.
        undeclared,
        /// An assignment to a variable that cannot be assigned.
        assign_to_const,
    };
};

pub const Resolution = struct {
    gpa: std.mem.Allocator,
    bindings: std.ArrayList(Binding) = .empty,
    /// Sorted by `span.start`; a name token yields at most one.
    occurrences: std.ArrayList(Occurrence) = .empty,
    /// The source the parser's recovery dropped (error nodes), in tree order.
    /// Names written there are unknown to this pass: a global that looks
    /// undefined may be defined in that text, so lints that rely on "never
    /// assigned" must stay quiet about any name it mentions.
    damaged: std.ArrayList(Span) = .empty,
    /// The scoping rules broken, in tree order.
    problems: std.ArrayList(Problem) = .empty,
    /// Every `global x` declaration, in tree order.
    declarations: std.ArrayList(GlobalDeclaration) = .empty,
    /// Every `global *`, in tree order.
    global_alls: std.ArrayList(GlobalAll) = .empty,

    pub fn deinit(self: *Resolution) void {
        self.bindings.deinit(self.gpa);
        self.occurrences.deinit(self.gpa);
        self.damaged.deinit(self.gpa);
        self.problems.deinit(self.gpa);
        self.declarations.deinit(self.gpa);
        self.global_alls.deinit(self.gpa);
    }

    /// Whether a free name at `offset` has to be declared (doc 76 §3.2): a
    /// `global x` is in scope there and no `global *` is. A cursor at a
    /// scope's end, just before its closing keyword, is still in it.
    pub fn strictAt(self: *const Resolution, offset: u32) bool {
        for (self.global_alls.items) |g| if (g.start <= offset and offset <= g.scope_end) return false;
        for (self.declarations.items) |d| if (d.span.start <= offset and offset <= d.scope_end) return true;
        return false;
    }


    /// The `global` declaration that makes the name at `occ` the global:
    /// the innermost one in scope there, its own for a declaring name. Null
    /// for an undeclared global and for anything else. A file has few, so
    /// a scan.
    pub fn declarationOf(self: *const Resolution, occ: *const Occurrence) ?*const GlobalDeclaration {
        if (!occ.declared) return null;
        var best: ?*const GlobalDeclaration = null;
        for (self.declarations.items) |*d| {
            if (d.binding != occ.binding or d.span.start > occ.span.start or occ.span.start >= d.scope_end) continue;
            if (best == null or d.span.start > best.?.span.start) best = d;
        }
        return best;
    }

    pub fn binding(self: *const Resolution, id: BindingId) *const Binding {
        return &self.bindings.items[id];
    }

    /// The occurrence whose name token starts at `start`, if any.
    pub fn occurrenceAt(self: *const Resolution, start: u32) ?*const Occurrence {
        const items = self.occurrences.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid].span.start < start) lo = mid + 1 else hi = mid;
        }
        if (lo < items.len and items[lo].span.start == start) return &items[lo];
        return null;
    }

    /// The binding of the name token starting at `start`, if the pass saw one.
    pub fn bindingAt(self: *const Resolution, start: u32) ?BindingId {
        return (self.occurrenceAt(start) orelse return null).binding;
    }

    /// The occurrence covering byte `offset` (a cursor anywhere in the name),
    /// if any.
    pub fn occurrenceCovering(self: *const Resolution, offset: u32) ?*const Occurrence {
        const items = self.occurrences.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid].span.start <= offset) lo = mid + 1 else hi = mid;
        }
        // `lo` is the first occurrence starting after `offset`. A zero-width
        // `self` shares its start with nothing that can cover, so the
        // candidate is the one before.
        var i = lo;
        while (i > 0) {
            i -= 1;
            const o = &items[i];
            if (o.span.start <= offset and offset <= o.span.end and o.span.end > o.span.start) return o;
            if (o.span.end < offset) break;
        }
        return null;
    }
};

/// A local that an earlier chunk of a REPL session declared at its top level
/// and this one can still see (doc 75 §6).
pub const Outer = struct {
    name: []const u8,
    attrib: ast.Attrib = .none,
};

/// Resolve every name of a chunk. `source_len` bounds the chunk's own scope.
pub fn resolve(gpa: std.mem.Allocator, root: ast.Block, source_len: u32) std.mem.Allocator.Error!Resolution {
    return resolveWith(gpa, root, source_len, &.{});
}

/// `resolve` with `outer` already in scope around the chunk: binding `i` of
/// the result is `outer[i]`, a local of the chunk's function (func 0) that
/// has no declaring token, so no occurrence. A later name in `outer` shadows
/// an earlier one, as a redeclaration does.
pub fn resolveWith(gpa: std.mem.Allocator, root: ast.Block, source_len: u32, outer: []const Outer) std.mem.Allocator.Error!Resolution {
    var res = Resolution{ .gpa = gpa };
    errdefer res.deinit();
    var w = Walker{ .gpa = gpa, .res = &res };
    defer w.deinit();

    for (outer) |o| {
        const id: BindingId = @intCast(res.bindings.items.len);
        try res.bindings.append(gpa, .{
            .kind = .local,
            .name = o.name,
            .attrib = o.attrib,
            .decl_span = .{ .start = 0, .end = 0 },
            .visible_from = 0,
            .scope_end = source_len,
            .func = 0,
        });
        try w.push(o.name, .{ .binding = id, .prev = undefined });
    }
    try w.block(root, source_len);
    try w.finish();
    return res;
}

const no_entry: u32 = std.math.maxInt(u32);

/// Where the closing `end` of a closed construct starts. The parser only builds
/// such a node after consuming that keyword, and it is the construct's last
/// token (an unclosed one is an error node and never reaches the resolver).
fn closeStart(span: Span) u32 {
    return span.end - @as(u32, "end".len);
}

/// A name that is currently in scope, or a `global *`.
const Entry = struct {
    /// For a `global *`, `no_entry`: it names nothing.
    binding: BindingId,
    /// The entry this one shadows, `no_entry` if none.
    prev: u32,
    what: What = .local,
    /// For `global x`, its index in `Resolution.declarations`; for
    /// `global *`, in `Resolution.global_alls`.
    decl: u32 = 0,

    const What = enum {
        /// A local, parameter or loop variable.
        local,
        /// `global x`: the name is the global `x`.
        global,
        global_const,
        /// `global *`: every name not declared otherwise is a global.
        all,
        all_const,
    };
};

const Walker = struct {
    gpa: std.mem.Allocator,
    res: *Resolution,
    /// The names in scope, innermost last. A name's chain of shadowed
    /// declarations is threaded through `Entry.prev`, with `heads` pointing at
    /// the innermost, so a lookup is one hash probe whatever the depth.
    entries: std.ArrayList(Entry) = .empty,
    heads: std.StringHashMapUnmanaged(u32) = .empty,
    globals: std.StringHashMapUnmanaged(BindingId) = .empty,
    func: u32 = 0,
    next_func: u32 = 1,
    /// `global x` declarations in scope: while there is one, a free name must
    /// be declared (doc 76 §3.2), unless a `global *` is in scope too.
    named_globals: u32 = 0,
    /// The `global *` declarations in scope, innermost last: whether each is
    /// `<const>`. The innermost decides whether a free name is read-only.
    collectives: std.ArrayList(bool) = .empty,

    fn deinit(self: *Walker) void {
        self.entries.deinit(self.gpa);
        self.heads.deinit(self.gpa);
        self.globals.deinit(self.gpa);
        self.collectives.deinit(self.gpa);
    }

    // ---- scopes ----

    fn mark(self: *const Walker) usize {
        return self.entries.items.len;
    }

    /// Leave a scope: drop its names and record where it ended.
    fn pop(self: *Walker, to: usize, scope_end: u32) void {
        while (self.entries.items.len > to) {
            const e = self.entries.pop().?;
            switch (e.what) {
                .local => {},
                .global, .global_const => self.named_globals -= 1,
                .all, .all_const => {
                    _ = self.collectives.pop();
                    self.res.global_alls.items[e.decl].scope_end = scope_end;
                    continue;
                },
            }
            const b = &self.res.bindings.items[e.binding];
            if (e.what == .local) b.scope_end = scope_end else self.res.declarations.items[e.decl].scope_end = scope_end;
            if (e.prev == no_entry) {
                _ = self.heads.remove(b.name);
            } else {
                self.heads.getPtr(b.name).?.* = e.prev;
            }
        }
    }

    /// Declare `name` in the innermost scope; it shadows any earlier one.
    fn declare(self: *Walker, kind: Kind, name: []const u8, decl: Span, visible_from: u32, attrib: ast.Attrib) std.mem.Allocator.Error!void {
        const id: BindingId = @intCast(self.res.bindings.items.len);
        try self.res.bindings.append(self.gpa, .{
            .kind = kind,
            .name = name,
            .attrib = attrib,
            .decl_span = decl,
            .visible_from = visible_from,
            .scope_end = visible_from,
            .func = self.func,
        });
        try self.push(name, .{ .binding = id, .prev = undefined });
        try self.res.occurrences.append(self.gpa, .{ .span = decl, .binding = id, .access = .declare, .readonly = attrib != .none });
    }

    /// Put `entry` in scope as the innermost meaning of `name`.
    fn push(self: *Walker, name: []const u8, entry: Entry) std.mem.Allocator.Error!void {
        const slot = try self.heads.getOrPut(self.gpa, name);
        var e = entry;
        e.prev = if (slot.found_existing) slot.value_ptr.* else no_entry;
        try self.entries.append(self.gpa, e);
        slot.value_ptr.* = @intCast(self.entries.items.len - 1);
    }

    /// `global x` (doc 76 §3.2): from here to the end of the block `x` is the
    /// global `x`, read-only when `<const>`.
    fn declareGlobal(self: *Walker, name: []const u8, span: Span, attrib: ast.Attrib) std.mem.Allocator.Error!void {
        const id = try self.global(name);
        const decl: u32 = @intCast(self.res.declarations.items.len);
        try self.res.declarations.append(self.gpa, .{ .binding = id, .span = span, .attrib = attrib });
        try self.push(name, .{ .binding = id, .prev = undefined, .what = if (attrib == .@"const") .global_const else .global, .decl = decl });
        self.named_globals += 1;
        try self.res.occurrences.append(self.gpa, .{ .span = span, .binding = id, .access = .declare, .declared = true, .readonly = attrib == .@"const" });
    }

    /// `global *` or `global <const> *`, the statement starting at `start`.
    fn declareAll(self: *Walker, attrib: ast.Attrib, start: u32) std.mem.Allocator.Error!void {
        const decl: u32 = @intCast(self.res.global_alls.items.len);
        try self.res.global_alls.append(self.gpa, .{ .start = start, .attrib = attrib });
        try self.entries.append(self.gpa, .{ .binding = no_entry, .prev = no_entry, .what = if (attrib == .@"const") .all_const else .all, .decl = decl });
        try self.collectives.append(self.gpa, attrib == .@"const");
    }

    fn problem(self: *Walker, code: Problem.Code, name: []const u8, span: Span) std.mem.Allocator.Error!void {
        try self.res.problems.append(self.gpa, .{ .code = code, .span = span, .name = name });
    }

    // ---- uses ----

    fn global(self: *Walker, name: []const u8) std.mem.Allocator.Error!BindingId {
        const slot = try self.globals.getOrPut(self.gpa, name);
        if (!slot.found_existing) {
            slot.value_ptr.* = @intCast(self.res.bindings.items.len);
            try self.res.bindings.append(self.gpa, .{
                .kind = .global,
                .name = name,
                .decl_span = .{ .start = 0, .end = 0 },
                .visible_from = 0,
                .scope_end = std.math.maxInt(u32),
                .func = std.math.maxInt(u32),
            });
        }
        return slot.value_ptr.*;
    }

    /// Record a use of `name` at `span`, and check it against the rules of
    /// doc 76: a write must not hit something read-only, and in the scope of
    /// a `global` declaration a free name must be declared.
    fn use(self: *Walker, name: []const u8, span: Span, access: Access) std.mem.Allocator.Error!void {
        const writes = access == .write or access == .read_write;
        var declared = false;
        var readonly = false;
        const id = if (self.heads.get(name)) |top| blk: {
            const e = self.entries.items[top];
            switch (e.what) {
                .local => {
                    const b = &self.res.bindings.items[e.binding];
                    if (b.func != self.func) b.captured = true;
                    readonly = b.attrib != .none;
                },
                .global, .global_const => {
                    declared = true;
                    readonly = e.what == .global_const;
                },
                .all, .all_const => unreachable, // never a head
            }
            break :blk e.binding;
        } else blk: {
            // 5.5's rule: any `global *` in scope admits the name, the
            // innermost deciding whether it is read-only; else any named
            // declaration in scope makes it an error.
            if (self.collectives.items.len > 0) {
                readonly = self.collectives.items[self.collectives.items.len - 1];
            } else if (self.named_globals > 0) {
                try self.problem(.undeclared, name, span);
            }
            break :blk try self.global(name);
        };
        if (writes and readonly) try self.problem(.assign_to_const, name, span);
        try self.res.occurrences.append(self.gpa, .{ .span = span, .binding = id, .access = access, .declared = declared, .readonly = readonly });
    }

    /// Doc 76 D8: the literal `e` is, through parentheses, as a constant
    /// `<const>` local's value: `nil`, a boolean, a number (a minus included),
    /// a string, or a name meaning a local that folds itself. Null for
    /// anything else. A name is looked up past the bindings from `hidden`
    /// on, the statement's own names, which its values cannot see.
    fn constantValueBelow(self: *const Walker, e: *const ast.Expr, hidden: usize) ?*const ast.Expr {
        var cur = e;
        while (cur.data == .paren) cur = cur.data.paren;
        return switch (cur.data) {
            .nil, .bool, .int, .float, .string_raw => cur,
            .unary => |u| blk: {
                var operand = u.operand;
                while (operand.data == .paren) operand = operand.data.paren;
                break :blk if (u.op == .neg and (operand.data == .int or operand.data == .float)) cur else null;
            },
            .name => |name| blk: {
                var at = self.heads.get(name) orelse break :blk null;
                while (self.entries.items[at].what == .local and self.entries.items[at].binding >= hidden) {
                    at = self.entries.items[at].prev;
                    if (at == no_entry) break :blk null;
                }
                const entry = self.entries.items[at];
                if (entry.what != .local) break :blk null;
                break :blk self.res.bindings.items[entry.binding].value;
            },
            else => null,
        };
    }

    /// Whether `name` means the global of that name here: no local of that
    /// name is in scope (a `global` declaration of it may be).
    fn namesGlobal(self: *const Walker, name: []const u8) bool {
        const top = self.heads.get(name) orelse return true;
        return self.entries.items[top].what != .local;
    }

    /// Whether `e` is the name `_G` meaning the global: the globals table,
    /// unless a local of that name is in scope.
    fn isGlobalTable(self: *const Walker, e: *const ast.Expr) bool {
        return e.data == .name and std.mem.eql(u8, e.data.name, "_G") and self.namesGlobal("_G");
    }

    /// Record `name` at `span`, read through the globals table, as a use of the
    /// global `name`.
    fn useQualified(self: *Walker, name: []const u8, span: Span, access: Access) std.mem.Allocator.Error!void {
        const id = try self.global(name);
        try self.res.occurrences.append(self.gpa, .{ .span = span, .binding = id, .access = access, .qualified = true });
    }

    /// The global a key of the globals table names: a quoted literal spelled
    /// like a name, with no escapes, so its text is the name (and a rename can
    /// rewrite it in place). Its span is the text between the quotes.
    fn keyName(key: *const ast.Expr) ?struct { name: []const u8, span: Span } {
        if (key.data != .string_raw) return null;
        const raw = key.data.string_raw;
        if (raw.len < 2 or (raw[0] != '"' and raw[0] != '\'')) return null;
        const name = raw[1 .. raw.len - 1];
        if (name.len == 0 or token.keywords.has(name)) return null;
        for (name, 0..) |c, i| {
            const alpha = std.ascii.isAlphabetic(c) or c == '_';
            if (!(alpha or (std.ascii.isDigit(c) and i > 0))) return null;
        }
        return .{ .name = name, .span = .{ .start = key.span.start + 1, .end = key.span.end - 1 } };
    }

    /// `obj.name` or `obj[key]`, read or (as a target) written: the table and
    /// key are evaluated, and through the globals table the field is a global.
    fn tableAccess(self: *Walker, e: *const ast.Expr, access: Access) std.mem.Allocator.Error!void {
        switch (e.data) {
            .field => |f| {
                try self.expr(f.obj);
                if (self.isGlobalTable(f.obj)) try self.useQualified(f.name, f.name_span, access);
            },
            .index => |ix| {
                try self.expr(ix.obj);
                try self.expr(ix.key);
                if (self.isGlobalTable(ix.obj)) if (keyName(ix.key)) |k| try self.useQualified(k.name, k.span, access);
            },
            else => unreachable,
        }
    }

    // ---- the walk ----

    fn block(self: *Walker, list: ast.Block, scope_end: u32) std.mem.Allocator.Error!void {
        const m = self.mark();
        try self.stmtList(list);
        self.pop(m, scope_end);
    }

    fn stmtList(self: *Walker, list: ast.Block) std.mem.Allocator.Error!void {
        for (list) |*s| try self.stmt(s);
    }

    fn exprList(self: *Walker, list: []const *ast.Expr) std.mem.Allocator.Error!void {
        for (list) |e| try self.expr(e);
    }

    fn stmt(self: *Walker, s: *const ast.Stmt) std.mem.Allocator.Error!void {
        switch (s.data) {
            .local => |l| {
                // The values are evaluated before the names exist.
                try self.exprList(l.values);
                const first: usize = self.res.bindings.items.len;
                for (l.names) |n| try self.declare(.local, n.name, n.name_span, s.span.end, n.attrib);
                // Doc 76 D8, as 5.4: only a name with a value of its own
                // folds; with more names than values, or fewer, none does.
                if (l.names.len == l.values.len) {
                    for (l.names, l.values, first..) |n, v, id| {
                        if (n.attrib == .@"const") self.res.bindings.items[id].value = self.constantValueBelow(v, first);
                    }
                }
            },
            .local_function => |lf| {
                // Declared first: the body can call itself.
                try self.declare(.local_function, lf.name, lf.name_span, lf.name_span.end, .none);
                try self.function(lf.body, false);
            },
            .global => |g| {
                // As a local's: the values come before the names are in
                // scope (5.5 `globalnames`).
                try self.exprList(g.values);
                for (g.names) |n| try self.declareGlobal(n.name, n.name_span, n.attrib);
            },
            .global_all => |ga| try self.declareAll(ga.attrib, s.span.start),
            .global_function => |gf| {
                // Declared first: the body can call itself.
                try self.declareGlobal(gf.name, gf.name_span, .none);
                try self.function(gf.body, false);
            },
            .assign => |a| {
                for (a.targets) |t| try self.target(t, .write);
                try self.exprList(a.values);
            },
            .compound_assign => |ca| {
                try self.target(ca.target, .read_write);
                try self.expr(ca.value);
            },
            .call => |e| try self.expr(e),
            .do => |body| try self.block(body, closeStart(s.span)),
            .while_ => |w| {
                try self.expr(w.cond);
                try self.block(w.body, closeStart(s.span));
            },
            .repeat => |r| {
                // `until` sees the body's locals: one scope around both.
                const m = self.mark();
                try self.stmtList(r.body);
                try self.expr(r.cond);
                self.pop(m, s.span.end);
            },
            .if_ => |f| {
                for (f.branches, 0..) |br, i| {
                    try self.expr(br.cond);
                    const end = if (i + 1 < f.branches.len)
                        f.branches[i + 1].kw_start
                    else if (f.else_body != null)
                        f.else_start
                    else
                        closeStart(s.span);
                    try self.block(br.body, end);
                }
                if (f.else_body) |eb| try self.block(eb, closeStart(s.span));
            },
            .numeric_for => |nf| {
                try self.expr(nf.start);
                try self.expr(nf.stop);
                if (nf.step) |st| try self.expr(st);
                const header_end = if (nf.step) |st| st.span.end else nf.stop.span.end;
                const m = self.mark();
                // The control variable is read-only (5.5 §3.3.5, doc 76 D6).
                try self.declare(.for_var, nf.name, nf.name_span, header_end, .@"const");
                try self.stmtList(nf.body);
                self.pop(m, closeStart(s.span));
            },
            .generic_for => |gf| {
                try self.exprList(gf.exprs);
                const header_end = if (gf.exprs.len > 0) gf.exprs[gf.exprs.len - 1].span.end else s.span.start;
                const m = self.mark();
                // The first variable, the control variable, is read-only;
                // the others are ordinary locals (5.5 §3.3.5, doc 76 D6).
                for (gf.names, 0..) |n, i| try self.declare(.for_var, n.text, n.span, header_end, if (i == 0) .@"const" else .none);
                try self.stmtList(gf.body);
                self.pop(m, closeStart(s.span));
            },
            .function_decl => |fd| {
                // `function f()` assigns `f`; `function a.b()` and `a:m()`
                // read `a` to reach the table. Through the globals table the
                // next name is the global: `function _G.f()` and `_G:f()`
                // assign it, `function _G.a.b()` reads it.
                const path = fd.name.path;
                const plain = path.len == 1 and fd.name.method == null;
                try self.use(path[0].text, path[0].span, if (plain) .write else .read);
                if (std.mem.eql(u8, path[0].text, "_G") and self.namesGlobal("_G")) {
                    if (path.len > 1) {
                        const last = path.len == 2 and fd.name.method == null;
                        try self.useQualified(path[1].text, path[1].span, if (last) .write else .read);
                    } else if (fd.name.method) |m| {
                        try self.useQualified(m.text, m.span, .write);
                    }
                }
                try self.function(fd.body, fd.name.method != null);
            },
            .return_ => |values| try self.exprList(values),
            .break_ => {},
            .err => try self.res.damaged.append(self.gpa, s.span),
        }
    }

    /// An assignment target: a name is written, anything else is evaluated
    /// (`a.b = 1` reads `a`), and a field of the globals table is written.
    fn target(self: *Walker, e: *const ast.Expr, access: Access) std.mem.Allocator.Error!void {
        switch (e.data) {
            .name => |n| try self.use(n, e.span, access),
            .field, .index => try self.tableAccess(e, access),
            else => try self.expr(e),
        }
    }

    fn expr(self: *Walker, e: *const ast.Expr) std.mem.Allocator.Error!void {
        switch (e.data) {
            .nil, .bool, .int, .float, .string_raw, .vararg, .intrinsic => {},
            .err => try self.res.damaged.append(self.gpa, e.span),
            .name => |n| try self.use(n, e.span, .read),
            .paren => |inner| try self.expr(inner),
            .unary => |u| try self.expr(u.operand),
            .binary => |b| {
                try self.expr(b.lhs);
                try self.expr(b.rhs);
            },
            .field, .index => try self.tableAccess(e, .read),
            .call => |c| {
                try self.expr(c.callee);
                try self.exprList(c.args);
            },
            .method_call => |mc| {
                try self.expr(mc.obj);
                if (self.isGlobalTable(mc.obj)) try self.useQualified(mc.name, mc.name_span, .read);
                try self.exprList(mc.args);
            },
            .function => |body| try self.function(body, false),
            .table => |fields| for (fields) |f| switch (f) {
                .positional => |v| try self.expr(v),
                .named => |nv| try self.expr(nv.value),
                .keyed => |kv| {
                    try self.expr(kv.key);
                    try self.expr(kv.value);
                },
            },
        }
    }

    /// A function body: its parameters and its statements share one scope.
    /// `method` marks `function a:m()`, whose first parameter is the implicit
    /// `self`.
    fn function(self: *Walker, body: *const ast.FunctionBody, method: bool) std.mem.Allocator.Error!void {
        const outer = self.func;
        self.func = self.next_func;
        self.next_func += 1;
        const m = self.mark();
        for (body.params, 0..) |p, i| {
            const kind: Kind = if (method and i == 0) .self else .param;
            try self.declare(kind, p.name, p.name_span, p.name_span.end, .none);
        }
        try self.stmtList(body.body);
        self.pop(m, closeStart(body.span));
        self.func = outer;
    }

    /// Sort the occurrences and settle each global's declaration.
    fn finish(self: *Walker) std.mem.Allocator.Error!void {
        const occ = self.res.occurrences.items;
        std.mem.sort(Occurrence, occ, {}, struct {
            fn lessThan(_: void, a: Occurrence, b: Occurrence) bool {
                if (a.span.start != b.span.start) return a.span.start < b.span.start;
                return a.span.end < b.span.end;
            }
        }.lessThan);

        // A global is declared at its first `global` declaration, else where
        // it is first written, else where it is first used; `occ` is in
        // source order now, so the first hit of the best rank wins.
        const bindings = self.res.bindings.items;
        const seen = try self.gpa.alloc(u8, bindings.len); // 0 unseen, 1 used, 2 written, 3 declared
        defer self.gpa.free(seen);
        @memset(seen, 0);
        for (occ) |o| {
            const b = &bindings[o.binding];
            if (b.kind != .global) continue;
            const rank: u8 = switch (o.access) {
                .declare => 3,
                .write, .read_write => 2,
                .read => 1,
            };
            if (rank > seen[o.binding]) {
                b.decl_span = o.span;
                seen[o.binding] = rank;
            }
        }
    }
};

// ---- tests ----

const testing = std.testing;
const parser = @import("parser.zig");
const Diagnostics = @import("diag.zig").Diagnostics;

const Fixture = struct {
    tree: ast.Ast,
    res: Resolution,

    fn init(src: [:0]const u8) !Fixture {
        var diags = Diagnostics.init(testing.allocator);
        defer diags.deinit();
        var tree = try parser.parse(testing.allocator, src, &diags);
        errdefer tree.deinit();
        try testing.expect(!diags.hasErrors());
        const res = try resolve(testing.allocator, tree.root, @intCast(src.len));
        return .{ .tree = tree, .res = res };
    }

    fn deinit(self: *Fixture) void {
        self.res.deinit();
        self.tree.deinit();
    }

    /// The binding of the `n`-th (0-based) whole-word occurrence of `needle`
    /// in the source.
    fn at(self: *const Fixture, needle: []const u8, n: usize) !BindingId {
        const src = self.tree.source;
        var from: usize = 0;
        var left = n;
        while (std.mem.find(u8, src[from..], needle)) |i| {
            const pos = from + i;
            from = pos + 1;
            const end = pos + needle.len;
            const before = pos > 0 and isWordByte(src[pos - 1]);
            const after = end < src.len and isWordByte(src[end]);
            if (before or after) continue;
            if (left == 0) return self.res.bindingAt(@intCast(pos)) orelse error.NoOccurrence;
            left -= 1;
        }
        return error.NoSuchText;
    }

    fn isWordByte(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }
};

test "resolve: a local's value is evaluated before its name is visible" {
    var f = try Fixture.init("local x = 1\nlocal x = x\nprint(x)");
    defer f.deinit();
    const first = try f.at("x", 0);
    const second = try f.at("x", 1);
    try testing.expect(first != second);
    try testing.expectEqual(first, try f.at("x", 2)); // `= x` reads the first
    try testing.expectEqual(second, try f.at("x", 3)); // `print(x)` reads the second
}

test "resolve: a local function sees itself, a local does not" {
    var f = try Fixture.init("local function f() return f end\nlocal g = function() return g end");
    defer f.deinit();
    try testing.expectEqual(try f.at("f", 0), try f.at("f", 1));
    const g_decl = try f.at("g", 0);
    const g_use = try f.at("g", 1);
    try testing.expect(g_decl != g_use);
    try testing.expectEqual(Kind.global, f.res.binding(g_use).kind);
}

test "resolve: repeat-until sees the body's locals" {
    var f = try Fixture.init("repeat local done = true until done");
    defer f.deinit();
    try testing.expectEqual(try f.at("done", 0), try f.at("done", 1));
}

test "resolve: scopes end with their block" {
    var f = try Fixture.init("do local a = 1 end\nprint(a)");
    defer f.deinit();
    const decl = try f.at("a", 0);
    try testing.expectEqual(Kind.local, f.res.binding(decl).kind);
    try testing.expectEqual(Kind.global, f.res.binding(try f.at("a", 1)).kind);
    try testing.expect(decl != try f.at("a", 1));
}

test "resolve: for variables, header expressions and the body" {
    var f = try Fixture.init("for i = i, 3 do print(i) end\nfor k, v in pairs(t) do print(k, v) end");
    defer f.deinit();
    const loop_var = try f.at("i", 0);
    try testing.expectEqual(Kind.for_var, f.res.binding(loop_var).kind);
    // `= i` in the header is the global `i`, the body's `i` is the loop variable.
    try testing.expectEqual(Kind.global, f.res.binding(try f.at("i", 1)).kind);
    try testing.expectEqual(loop_var, try f.at("i", 2));
    try testing.expectEqual(try f.at("k", 0), try f.at("k", 1));
    try testing.expectEqual(try f.at("v", 0), try f.at("v", 1));
}

test "resolve: captured is set when another function refers to a binding" {
    var f = try Fixture.init("local a, b = 1, 2\nlocal function g() return a end\nprint(b)");
    defer f.deinit();
    try testing.expect(f.res.binding(try f.at("a", 0)).captured);
    try testing.expect(!f.res.binding(try f.at("b", 0)).captured);
}

test "resolve: a capture through a middle function marks the original" {
    var f = try Fixture.init("local x = 1\nreturn function() return function() return x end end");
    defer f.deinit();
    const x = try f.at("x", 0);
    try testing.expectEqual(x, try f.at("x", 1));
    try testing.expect(f.res.binding(x).captured);
}

test "resolve: parameters, the implicit self, and varargs-free bodies" {
    const src = "function obj:greet(name) return self, name end";
    var f = try Fixture.init(src);
    defer f.deinit();
    const self_decl = try f.at("greet", 0); // the zero-width `self` sits at the method name
    try testing.expectEqual(Kind.self, f.res.binding(self_decl).kind);
    try testing.expectEqual(self_decl, try f.at("self", 0));
    try testing.expectEqual(Kind.param, f.res.binding(try f.at("name", 0)).kind);
    try testing.expectEqual(try f.at("name", 0), try f.at("name", 1));
    // `obj` is read to reach the table, and is a global here.
    const obj = try f.at("obj", 0);
    try testing.expectEqual(Kind.global, f.res.binding(obj).kind);
    try testing.expectEqual(Access.read, f.res.occurrenceAt(@intCast(std.mem.find(u8, src, "obj").?)).?.access);
}

test "resolve: globals are one binding per name, declared at the first write" {
    const src = "print(x)\nfunction f() x = 1 end\nx = 2\nprint(f)";
    var f = try Fixture.init(src);
    defer f.deinit();
    const x = try f.at("x", 0);
    try testing.expectEqual(x, try f.at("x", 1));
    try testing.expectEqual(x, try f.at("x", 2));
    const b = f.res.binding(x);
    try testing.expectEqual(Kind.global, b.kind);
    // The first write is inside `f`, not the earlier read.
    try testing.expectEqual(@as(u32, @intCast(std.mem.find(u8, src, "x = 1").?)), b.decl_span.start);
    // `function f()` writes the global `f`.
    try testing.expectEqual(Access.write, f.res.occurrenceAt(@intCast(std.mem.find(u8, src, "f()").?)).?.access);
}

test "resolve: accesses of assignments and compound assignments" {
    const src = "local n = 0\nn = n + 1\nn += 2\nlocal t = {}\nt.x = n";
    var f = try Fixture.init(src);
    defer f.deinit();
    const base: u32 = @intCast(std.mem.find(u8, src, "n = n").?);
    try testing.expectEqual(Access.write, f.res.occurrenceAt(base).?.access);
    try testing.expectEqual(Access.read, f.res.occurrenceAt(base + 4).?.access);
    try testing.expectEqual(Access.read_write, f.res.occurrenceAt(@intCast(std.mem.find(u8, src, "n += 2").?)).?.access);
    // `t.x = …` reads `t`.
    try testing.expectEqual(Access.read, f.res.occurrenceAt(@intCast(std.mem.find(u8, src, "t.x").?)).?.access);
    try testing.expectEqual(Access.declare, f.res.occurrenceAt(@intCast(std.mem.find(u8, src, "t =").?)).?.access);
}

test "resolve: a name read or written through _G is the global" {
    const src =
        \\local x = 0
        \\_G.x = 1
        \\_G["x"] += 2
        \\print(_G:x(), _G['\120'], _G[ [[x]] ], _G["end"])
        \\function _G.f() end
        \\function _G:m() end
        \\function _G.t.n() end
    ;
    var f = try Fixture.init(src);
    defer f.deinit();
    const local = try f.at("x", 0);
    const x = try f.at("x", 1);
    try testing.expect(local != x); // a local `x` does not capture `_G.x`
    try testing.expectEqual(Kind.global, f.res.binding(x).kind);
    const write = f.res.occurrenceAt(@intCast(std.mem.find(u8, src, "x = 1").?)).?;
    try testing.expectEqual(Access.write, write.access);
    try testing.expect(write.qualified);
    // The key's text, inside the quotes.
    const key = f.res.occurrenceAt(@intCast(std.mem.find(u8, src, "x\"] +=").?)).?;
    try testing.expectEqual(x, key.binding);
    try testing.expectEqual(Access.read_write, key.access);
    try testing.expectEqual(@as(u32, 1), key.span.end - key.span.start);
    try testing.expectEqual(x, try f.at("x", 3)); // `_G:x()` reads it
    // An escape, a long string or a keyword is not a name in the text.
    try testing.expect(f.res.occurrenceAt(@intCast(std.mem.find(u8, src, "\\120").?)) == null);
    try testing.expect(f.res.occurrenceAt(@intCast(std.mem.find(u8, src, "[[x]]").? + 2)) == null);
    try testing.expect(f.res.occurrenceAt(@intCast(std.mem.find(u8, src, "end\"").?)) == null);
    // The global is declared at its first write, `_G.x = 1`.
    try testing.expectEqual(write.span.start, f.res.binding(x).decl_span.start);
    // `function _G.f()` and `_G:m()` assign; `function _G.t.n()` reads `t`.
    try testing.expectEqual(Access.write, f.res.occurrenceAt(@intCast(std.mem.find(u8, src, "f()").?)).?.access);
    // (The implicit `self` sits at `m` too, so ask the binding.)
    var found = false;
    for (f.res.bindings.items) |b| {
        if (b.kind != .global or !std.mem.eql(u8, b.name, "m")) continue;
        try testing.expectEqual(@as(u32, @intCast(std.mem.find(u8, src, "m()").?)), b.decl_span.start);
        found = true;
    }
    try testing.expect(found);
    const t = f.res.occurrenceAt(@intCast(std.mem.find(u8, src, "t.n").?)).?;
    try testing.expectEqual(Access.read, t.access);
    try testing.expectEqual(Kind.global, f.res.binding(t.binding).kind);
    try testing.expect(f.res.occurrenceAt(@intCast(std.mem.find(u8, src, "n()").?)) == null);
}

test "resolve: through a local named _G a field is only a field" {
    const src = "local _G = {}\n_G.x = 1\nfunction _G.f() end\nprint(_G.y)";
    var f = try Fixture.init(src);
    defer f.deinit();
    try testing.expect(f.res.occurrenceAt(@intCast(std.mem.find(u8, src, "x =").?)) == null);
    try testing.expect(f.res.occurrenceAt(@intCast(std.mem.find(u8, src, "f()").?)) == null);
    try testing.expect(f.res.occurrenceAt(@intCast(std.mem.find(u8, src, "y)").?)) == null);
}

test "resolve: scope extents" {
    const src = "local a = 1\nif a then local b = 2 elseif a then local c = 3 end";
    var f = try Fixture.init(src);
    defer f.deinit();
    const a = f.res.binding(try f.at("a", 0));
    try testing.expectEqual(@as(u32, @intCast(std.mem.find(u8, src, "\nif").?)), a.visible_from);
    try testing.expectEqual(@as(u32, @intCast(src.len)), a.scope_end);
    const b = f.res.binding(try f.at("b", 0));
    // `b` ends at the `elseif` keyword, so `c`'s branch cannot see it.
    try testing.expectEqual(@as(u32, @intCast(std.mem.find(u8, src, "elseif").?)), b.scope_end);
    // `c` ends at the closing `end`.
    const c = f.res.binding(try f.at("c", 0));
    try testing.expectEqual(@as(u32, @intCast(std.mem.findLast(u8, src, "end").?)), c.scope_end);
}

test "resolve: a branch before `else` does not reach into it" {
    const src = "if true then local b = 1 else local c = 2 end";
    var f = try Fixture.init(src);
    defer f.deinit();
    try testing.expectEqual(@as(u32, @intCast(std.mem.find(u8, src, "else").?)), f.res.binding(try f.at("b", 0)).scope_end);
    try testing.expectEqual(@as(u32, @intCast(std.mem.findLast(u8, src, "end").?)), f.res.binding(try f.at("c", 0)).scope_end);
}

test "resolve: loop and function scopes end at their `end`" {
    const src = "for i = 1, 2 do local a = i end\nfunction f(p) return p end";
    var f = try Fixture.init(src);
    defer f.deinit();
    try testing.expectEqual(@as(u32, @intCast(std.mem.find(u8, src, "end").?)), f.res.binding(try f.at("i", 0)).scope_end);
    try testing.expectEqual(@as(u32, @intCast(std.mem.findLast(u8, src, "end").?)), f.res.binding(try f.at("p", 0)).scope_end);
}

test "resolve: occurrences are sorted and a lookup misses between names" {
    var f = try Fixture.init("local alpha = 1\nprint(alpha + beta)");
    defer f.deinit();
    const occ = f.res.occurrences.items;
    for (occ[1..], 0..) |o, i| try testing.expect(occ[i].span.start < o.span.start);
    try testing.expect(f.res.occurrenceAt(1) == null); // inside `alpha`, not at its start
    try testing.expect(f.res.occurrenceCovering(8) != null); // inside `alpha`
    try testing.expect(f.res.occurrenceCovering(12) == null); // the `=`
}

test "resolve: an AST with error nodes resolves what is left" {
    const src = "local x =\nlocal y = 1\nprint(x, y)";
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    var tree = try parser.parse(testing.allocator, src, &diags);
    defer tree.deinit();
    try testing.expect(diags.hasErrors());
    var res = try resolve(testing.allocator, tree.root, src.len);
    defer res.deinit();
    const x_use = res.bindingAt(@intCast(std.mem.find(u8, src, "x, y").?)).?;
    try testing.expectEqual(Kind.local, res.binding(x_use).kind);
}

test "resolve: dropped source is recorded as damaged" {
    const src = "local x =\nlocal y = 1\nz = = 2\nprint(x, y)";
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    var tree = try parser.parse(testing.allocator, src, &diags);
    defer tree.deinit();
    var res = try resolve(testing.allocator, tree.root, src.len);
    defer res.deinit();
    try testing.expectEqual(@as(usize, 2), res.damaged.items.len);
    try testing.expectEqualStrings("z = = 2", src[res.damaged.items[1].start..res.damaged.items[1].end]);
}
