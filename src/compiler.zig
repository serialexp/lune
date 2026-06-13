//! Bytecode compiler — lowers the AST (`ast.zig`) to tier-0 register bytecode
//! (`bytecode.zig`).
//!
//! A single straightforward pass with classic stack-discipline register
//! allocation: locals occupy a contiguous block of low registers for the life of
//! their scope, and temporaries are allocated above them and freed (by resetting
//! the high-water mark) as soon as each expression or statement finishes. The
//! invariant that makes scope exit trivial: **at every statement boundary,
//! `next_reg` equals the number of live locals** — all temporaries are released.
//!
//! Control flow uses forward jumps with back-patching and the dedicated
//! `for_prep`/`for_loop` pair for numeric `for`. Short-circuit `and`/`or` lower
//! to a value-carrying conditional jump.
//!
//! Scope of this increment (Phase 3c): expressions, locals, assignment, tables,
//! indexing, `if`/`while`/numeric-`for`/`do`/`break`/`return`, and global
//! read/write for free names. Functions, calls, methods, varargs, and generic
//! `for` are diagnosed as unsupported and land in Phase 3d.

const std = @import("std");
const ast = @import("ast.zig");
const bytecode = @import("bytecode.zig");
const value = @import("value.zig");
const gc = @import("gc.zig");
const diag = @import("diag.zig");

const Instr = bytecode.Instr;
const OpCode = bytecode.OpCode;
const Proto = bytecode.Proto;
const Value = value.Value;
const Diagnostics = diag.Diagnostics;

pub const Error = error{ CompileError, OutOfMemory };

/// A compiled chunk plus the arena that owns its bytecode, constant pool, and
/// `Proto`. String constants are interned into the caller's heap (they outlive
/// the chunk); everything else here is freed by `deinit`.
pub const Chunk = struct {
    arena: std.heap.ArenaAllocator,
    proto: *Proto,

    pub fn deinit(self: *Chunk) void {
        self.arena.deinit();
    }
};

/// Compile a parsed chunk. String literals/names are interned into `heap`.
pub fn compile(
    gpa: std.mem.Allocator,
    heap: *gc.Heap,
    source: [:0]const u8,
    root: ast.Block,
    diags: *Diagnostics,
) Error!Chunk {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    var c = Compiler{
        .arena = arena.allocator(),
        .scratch = gpa,
        .heap = heap,
        .source = source,
        .diags = diags,
    };
    defer c.deinitScratch();

    try c.compileBlock(root);
    // Implicit `return` (no values) at the end of the chunk.
    _ = try c.emit(Instr.opAB(.ret, 0, 0));

    const proto = try c.arena.create(Proto);
    proto.* = .{
        .code = c.code.items,
        .constants = c.constants.items,
        .num_registers = c.max_reg,
        .name = "main",
    };
    // Moving `arena` is safe: code/constants/proto live in arena *heap* buffers,
    // not in the struct, so the pointers stay valid; only the `c.arena` handle
    // goes stale and we no longer use it.
    return .{ .arena = arena, .proto = proto };
}

const Local = struct {
    name: []const u8,
    reg: u16,
    depth: u32,
};

const Loop = struct {
    /// Code indices of `break` jumps to patch to the loop's exit.
    breaks: std.ArrayList(usize) = .empty,
};

const Compiler = struct {
    /// Owns emitted code, the constant pool, and the `Proto`.
    arena: std.mem.Allocator,
    /// Owns transient bookkeeping (locals, loop/break stacks).
    scratch: std.mem.Allocator,
    heap: *gc.Heap,
    source: [:0]const u8,
    diags: *Diagnostics,

    code: std.ArrayList(Instr) = .empty,
    constants: std.ArrayList(Value) = .empty,
    locals: std.ArrayList(Local) = .empty,
    loops: std.ArrayList(Loop) = .empty,

    scope_depth: u32 = 0,
    /// Next free register (also == live-local count at statement boundaries).
    next_reg: u16 = 0,
    /// High-water mark → `Proto.num_registers`.
    max_reg: u16 = 0,

    fn deinitScratch(self: *Compiler) void {
        self.locals.deinit(self.scratch);
        for (self.loops.items) |*lp| lp.breaks.deinit(self.scratch);
        self.loops.deinit(self.scratch);
    }

    // ---- emission ----

    fn emit(self: *Compiler, instr: Instr) Error!usize {
        try self.code.append(self.arena, instr);
        return self.code.items.len - 1;
    }

    /// Emit a jump (with a placeholder offset) and return its code index so the
    /// caller can back-patch it once the target is known.
    fn emitJump(self: *Compiler, op: OpCode, reg: u16) Error!usize {
        return self.emit(.{ .op = op, .a = reg, .aux = 0 });
    }

    /// Patch a previously-emitted forward jump to land at the current end of code.
    fn patchToHere(self: *Compiler, jump_index: usize) void {
        const target: i64 = @intCast(self.code.items.len);
        const after_jump: i64 = @intCast(jump_index + 1);
        self.code.items[jump_index].aux = @intCast(target - after_jump);
    }

    /// Emit a jump whose target is an already-emitted instruction (back-edge).
    fn emitJumpTo(self: *Compiler, op: OpCode, reg: u16, target_index: usize) Error!void {
        const this_index: i64 = @intCast(self.code.items.len);
        const target: i64 = @intCast(target_index);
        _ = try self.emit(.{ .op = op, .a = reg, .aux = @intCast(target - (this_index + 1)) });
    }

    // ---- registers ----

    fn reserve(self: *Compiler, n: u16) Error!u16 {
        if (self.next_reg > std.math.maxInt(u16) - n) {
            self.diags.err("function needs too many registers", 0, 0, 0);
            return Error.CompileError;
        }
        const base = self.next_reg;
        self.next_reg += n;
        if (self.next_reg > self.max_reg) self.max_reg = self.next_reg;
        return base;
    }

    fn alloc1(self: *Compiler) Error!u16 {
        return self.reserve(1);
    }

    fn freeTo(self: *Compiler, mark: u16) void {
        self.next_reg = mark;
    }

    // ---- constants ----

    /// Append a constant (deduplicated by *exact* identity — not `Value.eql`,
    /// which would conflate `1` and `1.0` into one pool slot).
    fn addConstant(self: *Compiler, v: Value) Error!u16 {
        for (self.constants.items, 0..) |existing, i| {
            if (sameConstant(existing, v)) return @intCast(i);
        }
        const idx = self.constants.items.len;
        if (idx > std.math.maxInt(u16)) {
            self.diags.err("too many constants", 0, 0, 0);
            return Error.CompileError;
        }
        try self.constants.append(self.arena, v);
        return @intCast(idx);
    }

    fn stringConstant(self: *Compiler, bytes: []const u8) Error!u16 {
        const v = try self.heap.internValue(bytes);
        return self.addConstant(v);
    }

    // ---- scopes & locals ----

    fn beginScope(self: *Compiler) void {
        self.scope_depth += 1;
    }

    fn endScope(self: *Compiler) void {
        self.scope_depth -= 1;
        var n = self.locals.items.len;
        while (n > 0 and self.locals.items[n - 1].depth > self.scope_depth) {
            n -= 1;
            self.next_reg -= 1; // local registers are contiguous at the top
        }
        self.locals.items.len = n;
    }

    fn declareLocal(self: *Compiler, name: []const u8, reg: u16) Error!void {
        try self.locals.append(self.scratch, .{ .name = name, .reg = reg, .depth = self.scope_depth });
    }

    fn resolveLocal(self: *Compiler, name: []const u8) ?u16 {
        var i = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.locals.items[i].name, name)) return self.locals.items[i].reg;
        }
        return null;
    }

    // ---- statements ----

    fn compileBlock(self: *Compiler, block: ast.Block) Error!void {
        for (block) |*stmt| try self.compileStmt(stmt);
    }

    fn compileStmt(self: *Compiler, s: *const ast.Stmt) Error!void {
        switch (s.data) {
            .local => |l| try self.compileLocal(l),
            .assign => |a| try self.compileAssign(a),
            .do => |body| {
                self.beginScope();
                try self.compileBlock(body);
                self.endScope();
            },
            .while_ => |w| try self.compileWhile(w),
            .if_ => |f| try self.compileIf(f),
            .numeric_for => |nf| try self.compileNumericFor(nf),
            .return_ => |exprs| try self.compileReturn(exprs),
            .break_ => try self.compileBreak(s.span),

            // Phase 3d.
            .call => return self.fail(s.span, "call statements are not supported yet"),
            .generic_for => return self.fail(s.span, "generic for is not supported yet"),
            .function_decl => return self.fail(s.span, "function declarations are not supported yet"),
            .local_function => return self.fail(s.span, "local functions are not supported yet"),
        }
    }

    fn compileLocal(self: *Compiler, l: anytype) Error!void {
        const start = self.next_reg;
        const n_names = l.names.len;

        var i: usize = 0;
        while (i < n_names) : (i += 1) {
            const r = try self.alloc1();
            if (i < l.values.len) {
                try self.compileExprTo(l.values[i], r);
            } else {
                _ = try self.emit(Instr.opA(.load_nil, r));
            }
        }
        // Evaluate any surplus RHS expressions for their side effects, then drop.
        while (i < l.values.len) : (i += 1) {
            const mark = self.next_reg;
            const r = try self.alloc1();
            try self.compileExprTo(l.values[i], r);
            self.freeTo(mark);
        }
        // Declare names only after the RHS is evaluated (Lua scoping: `local x = x`
        // reads the outer `x`).
        for (l.names, 0..) |nm, j| {
            try self.declareLocal(nm.name, @intCast(start + j));
        }
    }

    fn compileAssign(self: *Compiler, a: anytype) Error!void {
        const mark = self.next_reg;
        const val_base = self.next_reg;
        const n_targets = a.targets.len;

        var i: usize = 0;
        while (i < n_targets) : (i += 1) {
            const r = try self.alloc1();
            if (i < a.values.len) {
                try self.compileExprTo(a.values[i], r);
            } else {
                _ = try self.emit(Instr.opA(.load_nil, r));
            }
        }
        while (i < a.values.len) : (i += 1) {
            const m = self.next_reg;
            const r = try self.alloc1();
            try self.compileExprTo(a.values[i], r);
            self.freeTo(m);
        }
        for (a.targets, 0..) |tgt, j| {
            try self.compileStore(tgt, @intCast(val_base + j));
        }
        self.freeTo(mark);
    }

    /// Emit a store of register `src` into the assignable target `tgt`.
    fn compileStore(self: *Compiler, tgt: *const ast.Expr, src: u16) Error!void {
        switch (tgt.data) {
            .name => |nm| {
                if (self.resolveLocal(nm)) |r| {
                    if (r != src) _ = try self.emit(Instr.opAB(.move, r, src));
                } else {
                    const k = try self.stringConstant(nm);
                    _ = try self.emit(Instr.opAB(.set_global, src, k));
                }
            },
            .field => |f| {
                const m = self.next_reg;
                const obj = try self.alloc1();
                try self.compileExprTo(f.obj, obj);
                const key = try self.alloc1();
                const k = try self.stringConstant(f.name);
                _ = try self.emit(Instr.opAB(.load_const, key, k));
                _ = try self.emit(Instr.opABC(.set_index, obj, key, src));
                self.freeTo(m);
            },
            .index => |ix| {
                const m = self.next_reg;
                const obj = try self.alloc1();
                try self.compileExprTo(ix.obj, obj);
                const key = try self.alloc1();
                try self.compileExprTo(ix.key, key);
                _ = try self.emit(Instr.opABC(.set_index, obj, key, src));
                self.freeTo(m);
            },
            else => unreachable, // parser guarantees targets are assignable
        }
    }

    fn compileReturn(self: *Compiler, exprs: []const *ast.Expr) Error!void {
        if (exprs.len == 0) {
            _ = try self.emit(Instr.opAB(.ret, 0, 0));
            return;
        }
        const mark = self.next_reg;
        const base = self.next_reg;
        for (exprs) |e| {
            const r = try self.alloc1();
            try self.compileExprTo(e, r);
        }
        _ = try self.emit(Instr.opAB(.ret, base, @intCast(exprs.len)));
        self.freeTo(mark);
    }

    fn compileIf(self: *Compiler, f: anytype) Error!void {
        var end_jumps: std.ArrayList(usize) = .empty;
        defer end_jumps.deinit(self.scratch);

        for (f.branches) |br| {
            const mark = self.next_reg;
            const cr = try self.alloc1();
            try self.compileExprTo(br.cond, cr);
            const skip = try self.emitJump(.jmp_if_false, cr);
            self.freeTo(mark); // condition temp is dead after the test

            self.beginScope();
            try self.compileBlock(br.body);
            self.endScope();

            try end_jumps.append(self.scratch, try self.emitJump(.jmp, 0));
            self.patchToHere(skip); // false → fall to the next branch / else
        }

        if (f.else_body) |eb| {
            self.beginScope();
            try self.compileBlock(eb);
            self.endScope();
        }

        for (end_jumps.items) |j| self.patchToHere(j);
    }

    fn compileWhile(self: *Compiler, w: anytype) Error!void {
        const loop_top = self.code.items.len;

        const mark = self.next_reg;
        const cr = try self.alloc1();
        try self.compileExprTo(w.cond, cr);
        const exit = try self.emitJump(.jmp_if_false, cr);
        self.freeTo(mark);

        try self.loops.append(self.scratch, .{});
        const loop_idx = self.loops.items.len - 1;

        self.beginScope();
        try self.compileBlock(w.body);
        self.endScope();

        try self.emitJumpTo(.jmp, 0, loop_top);

        self.patchToHere(exit);
        self.patchBreaks(loop_idx);
    }

    fn compileNumericFor(self: *Compiler, nf: anytype) Error!void {
        // Control registers: [idx, limit, step, var] — must be contiguous.
        const base = self.next_reg;
        const r_idx = try self.alloc1();
        try self.compileExprTo(nf.start, r_idx);
        const r_limit = try self.alloc1();
        try self.compileExprTo(nf.stop, r_limit);
        const r_step = try self.alloc1();
        if (nf.step) |st| {
            try self.compileExprTo(st, r_step);
        } else {
            _ = try self.emit(Instr.opAx(.load_int, r_step, 1));
        }
        _ = try self.alloc1(); // r_var = base + 3, published each iteration

        const prep = try self.emit(.{ .op = .for_prep, .a = base, .aux = 0 });
        const body_start = self.code.items.len;

        try self.loops.append(self.scratch, .{});
        const loop_idx = self.loops.items.len - 1;

        self.beginScope();
        try self.declareLocal(nf.name, @intCast(base + 3));
        try self.compileBlock(nf.body);
        self.endScope();

        // for_loop tests + back-edges to the body; for_prep jumps here.
        try self.emitJumpTo(.for_loop, base, body_start);
        self.code.items[prep].aux = blk: {
            const target: i64 = @intCast(self.code.items.len - 1); // the for_loop index
            const after: i64 = @intCast(prep + 1);
            break :blk @intCast(target - after);
        };

        self.patchBreaks(loop_idx);
        self.freeTo(base); // release the 4 control registers
    }

    fn compileBreak(self: *Compiler, span: ast.Span) Error!void {
        if (self.loops.items.len == 0) return self.fail(span, "break outside a loop");
        const j = try self.emitJump(.jmp, 0);
        try self.loops.items[self.loops.items.len - 1].breaks.append(self.scratch, j);
    }

    /// Patch all of a loop's `break`s to the current point and pop it.
    fn patchBreaks(self: *Compiler, loop_idx: usize) void {
        const lp = &self.loops.items[loop_idx];
        for (lp.breaks.items) |b| self.patchToHere(b);
        lp.breaks.deinit(self.scratch);
        self.loops.items.len = loop_idx;
    }

    // ---- expressions ----

    /// Emit code so that `R[dest]` holds the value of `e`.
    fn compileExprTo(self: *Compiler, e: *const ast.Expr, dest: u16) Error!void {
        switch (e.data) {
            .nil => _ = try self.emit(Instr.opA(.load_nil, dest)),
            .bool => |b| _ = try self.emit(Instr.opAB(.load_bool, dest, @intFromBool(b))),
            .int => |i| {
                if (i >= std.math.minInt(i32) and i <= std.math.maxInt(i32)) {
                    _ = try self.emit(Instr.opAx(.load_int, dest, @intCast(i)));
                } else {
                    const k = try self.addConstant(Value.int(i));
                    _ = try self.emit(Instr.opAB(.load_const, dest, k));
                }
            },
            .float => |f| {
                const k = try self.addConstant(Value.float(f));
                _ = try self.emit(Instr.opAB(.load_const, dest, k));
            },
            .string_raw => |raw| {
                const bytes = try self.decodeString(raw);
                const k = try self.stringConstant(bytes);
                _ = try self.emit(Instr.opAB(.load_const, dest, k));
            },
            .name => |nm| {
                if (self.resolveLocal(nm)) |r| {
                    if (r != dest) _ = try self.emit(Instr.opAB(.move, dest, r));
                } else {
                    const k = try self.stringConstant(nm);
                    _ = try self.emit(Instr.opAB(.get_global, dest, k));
                }
            },
            .paren => |inner| try self.compileExprTo(inner, dest),
            .unary => |u| try self.compileUnary(u.op, u.operand, dest),
            .binary => |b| try self.compileBinary(b.op, b.lhs, b.rhs, dest),
            .field => |f| {
                const m = self.next_reg;
                const obj = try self.alloc1();
                try self.compileExprTo(f.obj, obj);
                const key = try self.alloc1();
                const k = try self.stringConstant(f.name);
                _ = try self.emit(Instr.opAB(.load_const, key, k));
                _ = try self.emit(Instr.opABC(.get_index, dest, obj, key));
                self.freeTo(m);
            },
            .index => |ix| {
                const m = self.next_reg;
                const obj = try self.alloc1();
                try self.compileExprTo(ix.obj, obj);
                const key = try self.alloc1();
                try self.compileExprTo(ix.key, key);
                _ = try self.emit(Instr.opABC(.get_index, dest, obj, key));
                self.freeTo(m);
            },
            .table => |fields| try self.compileTable(fields, dest),

            // Phase 3d.
            .vararg => return self.fail(e.span, "vararg is not supported yet"),
            .call, .method_call => return self.fail(e.span, "calls are not supported yet"),
            .function => return self.fail(e.span, "function expressions are not supported yet"),
        }
    }

    fn compileUnary(self: *Compiler, op: ast.UnaryOp, operand: *const ast.Expr, dest: u16) Error!void {
        const m = self.next_reg;
        const t = try self.alloc1();
        try self.compileExprTo(operand, t);
        const oc: OpCode = switch (op) {
            .neg => .neg,
            .not => .not,
            .len => .len,
            .bnot => .bnot,
        };
        _ = try self.emit(Instr.opAB(oc, dest, t));
        self.freeTo(m);
    }

    fn compileBinary(self: *Compiler, op: ast.BinaryOp, lhs: *const ast.Expr, rhs: *const ast.Expr, dest: u16) Error!void {
        // Short-circuit operators carry a value and skip the RHS.
        switch (op) {
            .and_ => {
                try self.compileExprTo(lhs, dest);
                const skip = try self.emitJump(.jmp_if_false, dest); // false → keep lhs
                try self.compileExprTo(rhs, dest);
                self.patchToHere(skip);
                return;
            },
            .or_ => {
                try self.compileExprTo(lhs, dest);
                const skip = try self.emitJump(.jmp_if_true, dest); // true → keep lhs
                try self.compileExprTo(rhs, dest);
                self.patchToHere(skip);
                return;
            },
            else => {},
        }

        const m = self.next_reg;
        const t1 = try self.alloc1();
        try self.compileExprTo(lhs, t1);
        const t2 = try self.alloc1();
        try self.compileExprTo(rhs, t2);
        _ = try self.emit(Instr.opABC(binOpCode(op), dest, t1, t2));
        self.freeTo(m);
    }

    fn compileTable(self: *Compiler, fields: []const ast.TableField, dest: u16) Error!void {
        _ = try self.emit(Instr.opA(.new_table, dest));
        var array_index: i32 = 1;
        for (fields) |field| {
            const m = self.next_reg;
            const key = try self.alloc1();
            const val = try self.alloc1();
            switch (field) {
                .positional => |val_expr| {
                    _ = try self.emit(Instr.opAx(.load_int, key, array_index));
                    try self.compileExprTo(val_expr, val);
                    array_index += 1;
                },
                .named => |nv| {
                    const k = try self.stringConstant(nv.name);
                    _ = try self.emit(Instr.opAB(.load_const, key, k));
                    try self.compileExprTo(nv.value, val);
                },
                .keyed => |kv| {
                    try self.compileExprTo(kv.key, key);
                    try self.compileExprTo(kv.value, val);
                },
            }
            _ = try self.emit(Instr.opABC(.set_index, dest, key, val));
            self.freeTo(m);
        }
    }

    // ---- helpers ----

    /// Decode a raw string lexeme (including its surrounding quotes) into bytes,
    /// resolving escape sequences. Allocated in the arena (transient — interning
    /// copies it).
    fn decodeString(self: *Compiler, raw: []const u8) Error![]const u8 {
        std.debug.assert(raw.len >= 2); // at least the two quotes
        const inner = raw[1 .. raw.len - 1];
        var buf: std.ArrayList(u8) = .empty;
        try buf.ensureTotalCapacity(self.arena, inner.len);

        var i: usize = 0;
        while (i < inner.len) {
            const ch = inner[i];
            if (ch != '\\') {
                try buf.append(self.arena, ch);
                i += 1;
                continue;
            }
            i += 1;
            if (i >= inner.len) break; // trailing backslash (lexer should prevent)
            const esc = inner[i];
            i += 1;
            switch (esc) {
                'n' => try buf.append(self.arena, '\n'),
                't' => try buf.append(self.arena, '\t'),
                'r' => try buf.append(self.arena, '\r'),
                'a' => try buf.append(self.arena, 7),
                'b' => try buf.append(self.arena, 8),
                'f' => try buf.append(self.arena, 12),
                'v' => try buf.append(self.arena, 11),
                '\\' => try buf.append(self.arena, '\\'),
                '"' => try buf.append(self.arena, '"'),
                '\'' => try buf.append(self.arena, '\''),
                '\n' => try buf.append(self.arena, '\n'),
                'x' => {
                    var val: u8 = 0;
                    var digits: usize = 0;
                    while (digits < 2 and i < inner.len and isHex(inner[i])) : (digits += 1) {
                        val = val * 16 + hexValue(inner[i]);
                        i += 1;
                    }
                    try buf.append(self.arena, val);
                },
                '0'...'9' => {
                    var val: u16 = esc - '0';
                    var digits: usize = 1;
                    while (digits < 3 and i < inner.len and inner[i] >= '0' and inner[i] <= '9') : (digits += 1) {
                        val = val * 10 + (inner[i] - '0');
                        i += 1;
                    }
                    try buf.append(self.arena, @intCast(val & 0xff));
                },
                else => try buf.append(self.arena, esc), // unknown escape → literal
            }
        }
        return buf.items;
    }

    fn lineOf(self: *const Compiler, offset: u32) u32 {
        var line: u32 = 1;
        var i: usize = 0;
        const end = @min(offset, self.source.len);
        while (i < end) : (i += 1) {
            if (self.source[i] == '\n') line += 1;
        }
        return line;
    }

    fn fail(self: *Compiler, span: ast.Span, comptime message: []const u8) Error {
        self.diags.err(message, span.start, span.end, self.lineOf(span.start));
        return Error.CompileError;
    }
};

/// Exact constant identity (tag + bit pattern), so `1` and `1.0` stay distinct
/// pool entries and a `load_const` always reads the literal it was compiled for.
fn sameConstant(a: Value, b: Value) bool {
    if (a.tag != b.tag) return false;
    return switch (a.tag) {
        .nil => true,
        .boolean, .int, .float => a.payload.bits == b.payload.bits,
        .heap_ref => a.payload.ptr == b.payload.ptr,
    };
}

fn binOpCode(op: ast.BinaryOp) OpCode {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .idiv => .idiv,
        .mod => .mod,
        .pow => .pow,
        .concat => .concat,
        .eq => .eq,
        .ne => .ne,
        .lt => .lt,
        .le => .le,
        .gt => .gt,
        .ge => .ge,
        .band => .band,
        .bor => .bor,
        .bxor => .bxor,
        .shl => .shl,
        .shr => .shr,
        .and_, .or_ => unreachable, // handled by short-circuit lowering
    };
}

fn isHex(ch: u8) bool {
    return (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
}

fn hexValue(ch: u8) u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => 0,
    };
}

// ---------------------------------------------------------------------------
// Tests — parse → compile → run, asserting the observable result. This is the
// front-to-back differential check: the bytecode is correct iff running it
// reproduces the source program's meaning.
// ---------------------------------------------------------------------------

const testing = std.testing;
const parser = @import("parser.zig");
const interp = @import("interp.zig");
const string = @import("string.zig");

/// Compile and run `src`, returning (vm, chunk, result). Caller deinits both
/// (after inspecting any heap result).
const RunResult = struct {
    vm: interp.Vm,
    chunk: Chunk,
    value: Value,

    fn deinit(self: *RunResult) void {
        self.chunk.deinit();
        self.vm.deinit();
    }
};

fn run(src: [:0]const u8) !RunResult {
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();

    var tree = try parser.parse(testing.allocator, src, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try interp.Vm.init(testing.allocator);
    errdefer vm.deinit();
    var chunk = try compile(testing.allocator, &vm.heap, src, tree.root, &diags);
    errdefer chunk.deinit();
    try testing.expect(!diags.hasErrors());

    const result = try vm.run(chunk.proto);
    return .{ .vm = vm, .chunk = chunk, .value = result };
}

/// Convenience for scalar-returning programs (safe to deinit before reading).
fn runScalar(src: [:0]const u8) !Value {
    var r = try run(src);
    defer r.deinit();
    return r.value;
}

test "arithmetic and operator precedence" {
    try testing.expectEqual(@as(i64, 14), (try runScalar("return 2 + 3 * 4")).asInt());
    try testing.expectEqual(@as(i64, 20), (try runScalar("return (2 + 3) * 4")).asInt());
    try testing.expectEqual(@as(f64, 3.5), (try runScalar("return 7 / 2")).asFloat());
    try testing.expectEqual(@as(i64, 3), (try runScalar("return 7 // 2")).asInt());
    try testing.expectEqual(@as(i64, 1), (try runScalar("return 7 % 3")).asInt());
    try testing.expectEqual(@as(f64, 8.0), (try runScalar("return 2 ^ 3")).asFloat());
}

test "locals and assignment" {
    try testing.expectEqual(@as(i64, 30), (try runScalar(
        \\local a = 10
        \\local b = 20
        \\return a + b
    )).asInt());

    try testing.expectEqual(@as(i64, 7), (try runScalar(
        \\local x = 3
        \\x = x + 4
        \\return x
    )).asInt());
}

test "local scoping: local x = x reads the outer binding" {
    try testing.expectEqual(@as(i64, 11), (try runScalar(
        \\local x = 10
        \\do
        \\  local x = x + 1
        \\  return x
        \\end
    )).asInt());
}

test "if / elseif / else" {
    const program =
        \\local n = 5
        \\if n < 0 then
        \\  return -1
        \\elseif n == 0 then
        \\  return 0
        \\else
        \\  return 1
        \\end
    ;
    try testing.expectEqual(@as(i64, 1), (try runScalar(program)).asInt());
}

test "while loop accumulates" {
    try testing.expectEqual(@as(i64, 15), (try runScalar(
        \\local i = 1
        \\local sum = 0
        \\while i <= 5 do
        \\  sum = sum + i
        \\  i = i + 1
        \\end
        \\return sum
    )).asInt());
}

test "numeric for, with and without an explicit step" {
    try testing.expectEqual(@as(i64, 15), (try runScalar(
        \\local sum = 0
        \\for i = 1, 5 do
        \\  sum = sum + i
        \\end
        \\return sum
    )).asInt());

    // countdown by -2: 10 + 8 + 6 + 4 + 2 = 30
    try testing.expectEqual(@as(i64, 30), (try runScalar(
        \\local sum = 0
        \\for i = 10, 1, -2 do
        \\  sum = sum + i
        \\end
        \\return sum
    )).asInt());
}

test "break exits the loop" {
    try testing.expectEqual(@as(i64, 10), (try runScalar(
        \\local sum = 0
        \\for i = 1, 100 do
        \\  if i > 4 then break end
        \\  sum = sum + i
        \\end
        \\return sum
    )).asInt());
}

test "and / or short-circuit and carry values" {
    try testing.expectEqual(@as(i64, 2), (try runScalar("return 1 and 2")).asInt());
    try testing.expectEqual(@as(i64, 1), (try runScalar("return 1 or 2")).asInt());
    try testing.expect((try runScalar("return nil and 2")).isNil());
    try testing.expectEqual(@as(i64, 2), (try runScalar("return nil or 2")).asInt());
    try testing.expectEqual(@as(i64, 5), (try runScalar("return false or 5")).asInt());
}

test "globals round-trip through the global table" {
    try testing.expectEqual(@as(i64, 42), (try runScalar(
        \\g = 42
        \\return g
    )).asInt());
}

test "tables: constructor, index, length" {
    try testing.expectEqual(@as(i64, 20), (try runScalar(
        \\local t = {10, 20, 30}
        \\return t[2]
    )).asInt());

    try testing.expectEqual(@as(i64, 3), (try runScalar(
        \\local t = {10, 20, 30}
        \\return #t
    )).asInt());

    try testing.expectEqual(@as(i64, 99), (try runScalar(
        \\local t = {}
        \\t["key"] = 99
        \\return t.key
    )).asInt());

    try testing.expectEqual(@as(i64, 7), (try runScalar(
        \\local t = {x = 7}
        \\return t.x
    )).asInt());
}

test "string literals, escapes, and concatenation" {
    var r = try run(
        \\local greeting = "hello"
        \\return greeting .. ", " .. "world\n"
    );
    defer r.deinit();
    try testing.expect(r.value.isHeap());
    try testing.expectEqualStrings("hello, world\n", string.String.fromHeader(r.value.asHeap()).bytes());
}

test "string length via #" {
    try testing.expectEqual(@as(i64, 5), (try runScalar(
        \\return #"hello"
    )).asInt());
}

test "unsupported construct produces a diagnostic, not a crash" {
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    var tree = try parser.parse(testing.allocator, "return foo()", &diags);
    defer tree.deinit();

    var vm = try interp.Vm.init(testing.allocator);
    defer vm.deinit();
    try testing.expectError(Error.CompileError, compile(testing.allocator, &vm.heap, "return foo()", tree.root, &diags));
    try testing.expect(diags.hasErrors());
}
