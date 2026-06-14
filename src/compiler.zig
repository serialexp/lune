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
//! Nested functions compile through a child `Compiler` linked to its parent;
//! free names resolve local → upvalue → global, and captured locals are closed
//! at scope exit (so each loop iteration yields a distinct binding). `closure`
//! instructions carry the capture plan in `Proto.upvalues`.
//!
//! Supported: expressions, locals, assignment, tables, indexing,
//! `if`/`while`/numeric-`for`/`do`/`break`/`return`, globals, function
//! literals/declarations/`local function`, calls and method calls, and upvalue
//! closures. Not yet: multi-value spread from a call, varargs, and generic
//! `for ... in` (diagnosed as unsupported).

const std = @import("std");
const ast = @import("ast.zig");
const bytecode = @import("bytecode.zig");
const value = @import("value.zig");
const gc = @import("gc.zig");
const diag = @import("diag.zig");

const Instr = bytecode.Instr;
const OpCode = bytecode.OpCode;
const Proto = bytecode.Proto;
const UpvalDesc = bytecode.UpvalDesc;
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

/// Compile-time configuration. Currently just the set of globals the host
/// installs before the chunk runs (e.g. `print`, `clock`), which the
/// unknown-global lint treats as defined. Default empty: callers that don't care
/// about the lint (most tests) use `compile`, which passes `.{}`.
pub const Options = struct {
    known_globals: []const []const u8 = &.{},
};

/// Compile a parsed chunk. String literals/names are interned into `heap`.
pub fn compile(
    gpa: std.mem.Allocator,
    heap: *gc.Heap,
    source: [:0]const u8,
    root: ast.Block,
    diags: *Diagnostics,
) Error!Chunk {
    return compileWithOptions(gpa, heap, source, root, diags, .{});
}

/// Compile a parsed chunk with explicit `Options` (see `compile`). The real entry
/// points (CLI, wasm) pass the host's builtin global names so the unknown-global
/// lint doesn't flag `print`/`clock`.
pub fn compileWithOptions(
    gpa: std.mem.Allocator,
    heap: *gc.Heap,
    source: [:0]const u8,
    root: ast.Block,
    diags: *Diagnostics,
    opts: Options,
) Error!Chunk {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    var usage = GlobalUsage{ .writes = std.StringHashMap(void).init(gpa), .known = opts.known_globals };
    defer usage.deinit(gpa);

    var c = Compiler{
        .arena = arena.allocator(),
        .scratch = gpa,
        .heap = heap,
        .source = source,
        .diags = diags,
        .globals_usage = &usage,
    };
    defer c.deinitScratch();

    try c.compileBlock(root);
    // Implicit `return` (no values) at the end of the chunk.
    _ = try c.emit(Instr.opAB(.ret, 0, 0));

    // Post-pass: warn about reads of a global that is never assigned anywhere in
    // the chunk and isn't a builtin. Skipped when the compile already has errors
    // (the usage tables would be incomplete → noisy false positives). Deferred to
    // here so forward references (read above a later `function f()`/assignment)
    // don't warn.
    if (!diags.hasErrors()) try c.warnUnknownGlobals();

    const proto = try c.arena.create(Proto);
    proto.* = .{
        .code = c.code.items,
        .constants = c.constants.items,
        .num_registers = c.max_reg,
        .protos = c.protos.items,
        .name = "main",
    };
    // Assign every proto a stable, unique id (pre-order over the proto tree,
    // root = 0). This is the proto's serialization identity — a trace's anchor
    // is stored on disk as `proto.id`, not as the in-memory pointer. Order is
    // irrelevant; only uniqueness and stability-within-a-compile matter.
    var next_id: u32 = 0;
    assignProtoIds(proto, &next_id);

    // Moving `arena` is safe: code/constants/proto live in arena *heap* buffers,
    // not in the struct, so the pointers stay valid; only the `c.arena` handle
    // goes stale and we no longer use it.
    return .{ .arena = arena, .proto = proto };
}

/// Pre-order walk assigning each proto a unique id. `@constCast` is sound: the
/// children were created as mutable `*Proto` in the compile arena (see
/// `compileFunction`); the `[]const *const Proto` field type is only a
/// downstream immutability contract, not the original allocation's constness.
fn assignProtoIds(proto: *Proto, next: *u32) void {
    proto.id = next.*;
    next.* += 1;
    for (proto.protos) |child| assignProtoIds(@constCast(child), next);
}

/// One `get_global` site recorded during compilation, for the unknown-global
/// post-pass. `name`/spans borrow the source buffer (which outlives compilation).
const GlobalRead = struct {
    name: []const u8,
    start: u32,
    end: u32,
};

/// Chunk-wide global-name bookkeeping, shared by the root compiler and every
/// nested function compiler — so a read inside an inner function still sees a
/// top-level write, and vice-versa. Reads and writes are collected during the
/// walk; the unknown-global lint consults all three sets at the end.
const GlobalUsage = struct {
    /// Every `get_global` site, in source order.
    reads: std.ArrayList(GlobalRead) = .empty,
    /// Names `set_global`'d somewhere in the chunk (assignment or `function f()`
    /// declaration). Membership ⇒ "this global is defined here." Keys borrow the
    /// source buffer. Managed (owns its allocator).
    writes: std.StringHashMap(void),
    /// Builtin globals the host installs before the chunk runs (e.g. `print`,
    /// `clock`); treated as defined. Empty unless the caller supplies them.
    known: []const []const u8 = &.{},

    fn deinit(self: *GlobalUsage, gpa: std.mem.Allocator) void {
        self.reads.deinit(gpa);
        self.writes.deinit();
    }

    fn isKnown(self: *const GlobalUsage, name: []const u8) bool {
        for (self.known) |k| {
            if (std.mem.eql(u8, k, name)) return true;
        }
        return false;
    }
};

const Local = struct {
    name: []const u8,
    reg: u16,
    depth: u32,
    /// Set when an inner function captures this local as an upvalue: its cell
    /// must be *closed* when the scope exits (so the captured value outlives the
    /// register).
    captured: bool = false,
};

const Loop = struct {
    /// Code indices of `break` jumps to patch to the loop's exit.
    breaks: std.ArrayList(usize) = .empty,
    /// First register of the loop's body scope. `break` closes any upvalues at
    /// or above this before jumping out (the natural scope-exit close on the
    /// fall-through path does not run on a `break`).
    scope_base: u16 = 0,
};

const Compiler = struct {
    /// Owns emitted code, the constant pool, and the `Proto`.
    arena: std.mem.Allocator,
    /// Owns transient bookkeeping (locals, loop/break stacks).
    scratch: std.mem.Allocator,
    heap: *gc.Heap,
    source: [:0]const u8,
    diags: *Diagnostics,
    /// Chunk-wide global bookkeeping for the unknown-global lint. Shared: the
    /// root owns it (in `compileWithOptions`); nested functions inherit the same
    /// pointer (see `compileFunction`).
    globals_usage: *GlobalUsage,

    /// The lexically-enclosing function being compiled, if this is a nested
    /// function body. Used to detect references to an outer function's locals
    /// (upvalue captures, which Phase 3d1 diagnoses rather than supports).
    parent: ?*Compiler = null,

    code: std.ArrayList(Instr) = .empty,
    constants: std.ArrayList(Value) = .empty,
    locals: std.ArrayList(Local) = .empty,
    loops: std.ArrayList(Loop) = .empty,
    /// Nested function prototypes compiled within this function (arena-owned),
    /// referenced by the `closure` instructions this function emits.
    protos: std.ArrayList(*Proto) = .empty,
    /// This function's upvalue capture plan (arena-owned) → `Proto.upvalues`.
    upvalues: std.ArrayList(UpvalDesc) = .empty,

    /// Fixed parameter count of the function being compiled.
    num_params: u8 = 0,
    is_vararg: bool = false,

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

    fn endScope(self: *Compiler) Error!void {
        self.scope_depth -= 1;
        var n = self.locals.items.len;
        var any_captured = false;
        while (n > 0 and self.locals.items[n - 1].depth > self.scope_depth) {
            n -= 1;
            if (self.locals.items[n].captured) any_captured = true;
            self.next_reg -= 1; // local registers are contiguous at the top
        }
        self.locals.items.len = n;
        // If a closing local was captured, snapshot its cell before the register
        // is reused (so each loop iteration / block gets a distinct binding).
        if (any_captured) _ = try self.emit(Instr.opA(.close_upvalues, self.next_reg));
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

    /// Index of the innermost local named `name`, if any (the slot, not the
    /// register — so the caller can mark it captured).
    fn resolveLocalSlot(self: *Compiler, name: []const u8) ?usize {
        var i = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.locals.items[i].name, name)) return i;
        }
        return null;
    }

    /// Resolve `name` to an upvalue index of *this* function, threading the
    /// capture down the enclosing-function chain (Lua's `singlevaraux`): a local
    /// of the immediate parent becomes a direct (`in_stack`) capture and marks
    /// that local for closing; a parent upvalue is inherited. Returns null if the
    /// name is not visible in any enclosing function (→ a global).
    fn resolveUpvalue(self: *Compiler, name: []const u8) Error!?u16 {
        const parent = self.parent orelse return null;
        if (parent.resolveLocalSlot(name)) |slot| {
            parent.locals.items[slot].captured = true;
            return try self.addUpvalue(.{ .in_stack = true, .index = parent.locals.items[slot].reg });
        }
        if (try parent.resolveUpvalue(name)) |up| {
            return try self.addUpvalue(.{ .in_stack = false, .index = up });
        }
        return null;
    }

    /// Append a capture descriptor (deduplicated) and return its upvalue index.
    fn addUpvalue(self: *Compiler, desc: UpvalDesc) Error!u16 {
        for (self.upvalues.items, 0..) |u, i| {
            if (u.in_stack == desc.in_stack and u.index == desc.index) return @intCast(i);
        }
        const idx = self.upvalues.items.len;
        if (idx > std.math.maxInt(u16)) {
            self.diags.err("function needs too many upvalues", 0, 0, 0);
            return Error.CompileError;
        }
        try self.upvalues.append(self.arena, desc);
        return @intCast(idx);
    }

    /// Load the value of `name` into `dest`: a local move, an upvalue read, or a
    /// global read (resolution order is local → upvalue → global).
    fn loadName(self: *Compiler, name: []const u8, dest: u16, span: ast.Span) Error!void {
        if (self.resolveLocal(name)) |r| {
            if (r != dest) _ = try self.emit(Instr.opAB(.move, dest, r));
        } else if (try self.resolveUpvalue(name)) |up| {
            _ = try self.emit(Instr.opAB(.get_upval, dest, up));
        } else {
            const k = try self.stringConstant(name);
            _ = try self.emit(Instr.opAB(.get_global, dest, k));
            // Record the read site for the unknown-global post-pass.
            try self.globals_usage.reads.append(self.scratch, .{ .name = name, .start = span.start, .end = span.end });
        }
    }

    /// Store register `src` into `name`: a local move, an upvalue write, or a
    /// global write.
    fn storeName(self: *Compiler, name: []const u8, src: u16, span: ast.Span) Error!void {
        _ = span;
        if (self.resolveLocal(name)) |r| {
            if (r != src) _ = try self.emit(Instr.opAB(.move, r, src));
        } else if (try self.resolveUpvalue(name)) |up| {
            _ = try self.emit(Instr.opAB(.set_upval, src, up));
        } else {
            const k = try self.stringConstant(name);
            _ = try self.emit(Instr.opAB(.set_global, src, k));
            // Mark this global as defined-in-chunk so reads of it don't warn.
            try self.globals_usage.writes.put(name, {});
        }
    }

    /// Emit a warning for every global *read* of a name that is never assigned
    /// anywhere in the chunk and isn't a host builtin. In lune (Lua/Luau
    /// semantics) such a name is a `nil`-valued global, so it compiles fine and
    /// only errors at runtime when used — most often it's a typo for a local.
    /// This is a warning, not an error: a global may legitimately be defined by
    /// another chunk or the host. Messages are allocated in the compile arena, so
    /// they live as long as the returned `Chunk` (callers consume `diags` before
    /// the chunk is freed).
    fn warnUnknownGlobals(self: *Compiler) Error!void {
        const u = self.globals_usage;
        for (u.reads.items) |r| {
            if (u.writes.contains(r.name)) continue;
            if (u.isKnown(r.name)) continue;
            const msg = try std.fmt.allocPrint(self.arena, "undefined global '{s}' (never assigned; reads as nil)", .{r.name});
            self.diags.add(.{
                .severity = .warning,
                .message = msg,
                .start = r.start,
                .end = r.end,
                .line = self.lineOf(r.start),
            });
        }
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
                try self.endScope();
            },
            .while_ => |w| try self.compileWhile(w),
            .if_ => |f| try self.compileIf(f),
            .numeric_for => |nf| try self.compileNumericFor(nf),
            .return_ => |exprs| try self.compileReturn(exprs),
            .break_ => try self.compileBreak(s.span),
            .call => |call_expr| try self.compileCallStmt(call_expr),
            .function_decl => |fd| try self.compileFunctionDecl(fd),
            .local_function => |lf| try self.compileLocalFunction(lf),

            // Later phases.
            .generic_for => return self.fail(s.span, "generic for is not supported yet"),
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
            .name => |nm| try self.storeName(nm, src, tgt.span),
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
            try self.endScope();

            try end_jumps.append(self.scratch, try self.emitJump(.jmp, 0));
            self.patchToHere(skip); // false → fall to the next branch / else
        }

        if (f.else_body) |eb| {
            self.beginScope();
            try self.compileBlock(eb);
            try self.endScope();
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

        try self.loops.append(self.scratch, .{ .scope_base = self.next_reg });
        const loop_idx = self.loops.items.len - 1;

        self.beginScope();
        try self.compileBlock(w.body);
        try self.endScope();

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

        // The loop variable (base+3) is the lowest capturable register in the
        // loop scope, so `break` must close from there.
        try self.loops.append(self.scratch, .{ .scope_base = @intCast(base + 3) });
        const loop_idx = self.loops.items.len - 1;

        self.beginScope();
        try self.declareLocal(nf.name, @intCast(base + 3));
        try self.compileBlock(nf.body);
        try self.endScope();

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
        const loop_idx = self.loops.items.len - 1;
        // The fall-through scope-exit close does not run on the break path, so
        // close the loop scope's upvalues here before jumping out. (A no-op at
        // runtime if nothing in the loop was captured.)
        _ = try self.emit(Instr.opA(.close_upvalues, self.loops.items[loop_idx].scope_base));
        const j = try self.emitJump(.jmp, 0);
        try self.loops.items[loop_idx].breaks.append(self.scratch, j);
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
            .name => |nm| try self.loadName(nm, dest, e.span),
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
            .call => |c| try self.compileCall(c.callee, c.args, dest, 1),
            .method_call => |mc| try self.compileMethodCall(mc.obj, mc.name, mc.args, dest, 1),
            .function => |body| try self.compileFunction(body, "anonymous", dest),

            // Phase 3d2.
            .vararg => return self.fail(e.span, "vararg is not supported yet (Phase 3d2)"),
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

    // ---- functions & calls ----

    /// Compile a function body into a nested `Proto`, register it among this
    /// function's `protos`, and emit a `closure` into `dest`. `name` is for
    /// disassembly only.
    fn compileFunction(self: *Compiler, body: *const ast.FunctionBody, name: []const u8, dest: u16) Error!void {
        if (body.params.len > std.math.maxInt(u8)) return self.fail(body.span, "too many parameters");

        var child = Compiler{
            .arena = self.arena,
            .scratch = self.scratch,
            .heap = self.heap,
            .source = self.source,
            .diags = self.diags,
            .globals_usage = self.globals_usage,
            .parent = self,
        };
        defer child.deinitScratch();

        // Parameters occupy the first registers, in order.
        for (body.params, 0..) |p, i| {
            _ = try child.alloc1();
            try child.declareLocal(p.name, @intCast(i));
        }
        child.num_params = @intCast(body.params.len);
        child.is_vararg = body.is_vararg;

        try child.compileBlock(body.body);
        // Implicit `return` (no values) if control reaches the end.
        _ = try child.emit(Instr.opAB(.ret, 0, 0));

        const proto = try self.arena.create(Proto);
        proto.* = .{
            .code = child.code.items,
            .constants = child.constants.items,
            .num_registers = child.max_reg,
            .num_params = child.num_params,
            .is_vararg = child.is_vararg,
            .protos = child.protos.items,
            .upvalues = child.upvalues.items,
            .name = name,
        };

        if (self.protos.items.len > std.math.maxInt(u16)) return self.fail(body.span, "too many nested functions");
        const idx: u16 = @intCast(self.protos.items.len);
        try self.protos.append(self.arena, proto);
        _ = try self.emit(Instr.opAB(.closure, dest, idx));
    }

    /// `local function f() … end` — sugar for `local f; f = function … end`,
    /// except `f` is declared *before* the body is compiled so the body can
    /// refer to `f` (recursion), capturing it as an upvalue.
    fn compileLocalFunction(self: *Compiler, lf: anytype) Error!void {
        const r = try self.alloc1();
        try self.declareLocal(lf.name, r); // visible inside its own body
        try self.compileFunction(lf.body, lf.name, r);
    }

    /// A call used as a statement: evaluate for effects, discard results.
    fn compileCallStmt(self: *Compiler, e: *const ast.Expr) Error!void {
        switch (e.data) {
            .call => |c| try self.compileCall(c.callee, c.args, 0, 0),
            .method_call => |mc| try self.compileMethodCall(mc.obj, mc.name, mc.args, 0, 0),
            else => unreachable, // parser guarantees a call statement is a call
        }
    }

    /// `callee(args)` wanting `nwanted` results, delivered into `dest` (the
    /// first result) when `nwanted >= 1`. The callee and its arguments are laid
    /// out in a fresh contiguous temp window: `[fn, arg0, arg1, …]`.
    fn compileCall(self: *Compiler, callee: *const ast.Expr, args: []const *ast.Expr, dest: u16, nwanted: u16) Error!void {
        const mark = self.next_reg;
        const base = try self.alloc1(); // function slot; results land here
        try self.compileExprTo(callee, base);
        for (args) |arg| {
            const r = try self.alloc1();
            try self.compileExprTo(arg, r);
        }
        if (args.len > std.math.maxInt(u16)) return self.fail(callee.span, "too many arguments");
        _ = try self.emit(Instr.opABC(.call, base, @intCast(args.len), nwanted));
        if (nwanted >= 1 and dest != base) _ = try self.emit(Instr.opAB(.move, dest, base));
        self.freeTo(mark);
    }

    /// `obj:name(args)` — method-call sugar for `obj.name(obj, args)`: `obj` is
    /// evaluated once and passed as the implicit first argument (`self`).
    fn compileMethodCall(self: *Compiler, obj: *const ast.Expr, name: []const u8, args: []const *ast.Expr, dest: u16, nwanted: u16) Error!void {
        const mark = self.next_reg;
        const base = try self.alloc1(); // function slot
        const self_reg = try self.alloc1(); // base+1 = self (first argument)
        try self.compileExprTo(obj, self_reg);

        // fn = self[name]
        const km = self.next_reg;
        const key = try self.alloc1();
        const k = try self.stringConstant(name);
        _ = try self.emit(Instr.opAB(.load_const, key, k));
        _ = try self.emit(Instr.opABC(.get_index, base, self_reg, key));
        self.freeTo(km); // free the key temp; fn + self stay

        for (args) |arg| {
            const r = try self.alloc1();
            try self.compileExprTo(arg, r);
        }
        const total = args.len + 1; // implicit self
        if (total > std.math.maxInt(u16)) return self.fail(obj.span, "too many arguments");
        _ = try self.emit(Instr.opABC(.call, base, @intCast(total), nwanted));
        if (nwanted >= 1 and dest != base) _ = try self.emit(Instr.opAB(.move, dest, base));
        self.freeTo(mark);
    }

    /// `function a.b:m(...) ... end` — sugar for assigning a function literal to
    /// the named target. A bare `function f` assigns the name `f` (local or
    /// global); a dotted/method target navigates to the container and sets the
    /// final field. (`self` for a method is already prepended by the parser.)
    fn compileFunctionDecl(self: *Compiler, fd: anytype) Error!void {
        const path = fd.name.path;
        const method = fd.name.method;

        // Simple `function f()` — assign to the (local-or-global) name `f`.
        if (path.len == 1 and method == null) {
            const mark = self.next_reg;
            const fnr = try self.alloc1();
            try self.compileFunction(fd.body, path[0], fnr);
            try self.storeName(path[0], fnr, fd.body.span);
            self.freeTo(mark);
            return;
        }

        // Dotted / method target: load the base, walk to the container, then
        // `set_index` the final key.
        const mark = self.next_reg;
        const objr = try self.alloc1();
        try self.loadName(path[0], objr, fd.body.span);

        const final_count = if (method != null) path.len else path.len - 1;
        var i: usize = 1;
        while (i < final_count) : (i += 1) {
            const m2 = self.next_reg;
            const key = try self.alloc1();
            const k = try self.stringConstant(path[i]);
            _ = try self.emit(Instr.opAB(.load_const, key, k));
            _ = try self.emit(Instr.opABC(.get_index, objr, objr, key));
            self.freeTo(m2);
        }

        const final_key = method orelse path[path.len - 1];
        const keyr = try self.alloc1();
        const kk = try self.stringConstant(final_key);
        _ = try self.emit(Instr.opAB(.load_const, keyr, kk));
        const fnr = try self.alloc1();
        try self.compileFunction(fd.body, final_key, fnr);
        _ = try self.emit(Instr.opABC(.set_index, objr, keyr, fnr));
        self.freeTo(mark);
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

test "function literal: call an anonymous function" {
    try testing.expectEqual(@as(i64, 42), (try runScalar(
        \\local double = function(x) return x * 2 end
        \\return double(21)
    )).asInt());
}

test "global function declaration and call" {
    try testing.expectEqual(@as(i64, 7), (try runScalar(
        \\function add(a, b) return a + b end
        \\return add(3, 4)
    )).asInt());
}

test "recursion through a global name: fib(10) == 55" {
    try testing.expectEqual(@as(i64, 55), (try runScalar(
        \\function fib(n)
        \\  if n < 2 then return n end
        \\  return fib(n - 1) + fib(n - 2)
        \\end
        \\return fib(10)
    )).asInt());
}

test "higher-order: pass a function as an argument" {
    try testing.expectEqual(@as(i64, 42), (try runScalar(
        \\function apply(f, x) return f(x) end
        \\function inc(n) return n + 1 end
        \\return apply(inc, 41)
    )).asInt());
}

test "missing arguments bind to nil; extra arguments are dropped" {
    // one declared param, called with none → n is nil → `n or 0` yields 0
    try testing.expectEqual(@as(i64, 0), (try runScalar(
        \\function f(n) return n or 0 end
        \\return f()
    )).asInt());
    // two declared params, called with three → third is dropped
    try testing.expectEqual(@as(i64, 5), (try runScalar(
        \\function g(a, b) return a + b end
        \\return g(2, 3, 99)
    )).asInt());
}

test "a function with no explicit return yields nil" {
    try testing.expect((try runScalar(
        \\function noop() end
        \\return noop()
    )).isNil());
}

test "function stored on a table field, called via the field" {
    try testing.expectEqual(@as(i64, 30), (try runScalar(
        \\local t = {}
        \\function t.add(a, b) return a + b end
        \\return t.add(10, 20)
    )).asInt());
}

test "method declaration and method call pass self implicitly" {
    try testing.expectEqual(@as(i64, 7), (try runScalar(
        \\local obj = { value = 7 }
        \\function obj:get() return self.value end
        \\return obj:get()
    )).asInt());
}

test "call statement runs for its side effect" {
    // A call used as a statement (result discarded): `fill()` mutates a global,
    // observed afterwards. Exercises the statement-call path end to end.
    try testing.expectEqual(@as(i64, 42), (try runScalar(
        \\g = {}
        \\function fill() g[1] = 42 end
        \\fill()
        \\return g[1]
    )).asInt());
}

test "closure reads an enclosing local (upvalue capture)" {
    try testing.expectEqual(@as(i64, 5), (try runScalar(
        \\local x = 5
        \\local f = function() return x end
        \\return f()
    )).asInt());
}

test "closure mutates a shared upvalue: a counter" {
    // Each call advances the captured `n`; the cell persists across calls.
    try testing.expectEqual(@as(i64, 3), (try runScalar(
        \\local function counter()
        \\  local n = 0
        \\  return function() n = n + 1; return n end
        \\end
        \\local c = counter()
        \\c(); c()
        \\return c()
    )).asInt());
}

test "two closures share one upvalue cell" {
    // `get` and `add` both capture `n`; at runtime they share one cell, so a
    // write through `add` is visible through `get`.
    try testing.expectEqual(@as(i64, 30), (try runScalar(
        \\local function make()
        \\  local n = 10
        \\  local t = {}
        \\  t.get = function() return n end
        \\  t.add = function(d) n = n + d end
        \\  return t
        \\end
        \\local t = make()
        \\t.add(20)
        \\return t.get()
    )).asInt());
}

test "local function recurses through its own upvalue" {
    try testing.expectEqual(@as(i64, 120), (try runScalar(
        \\local function fact(n)
        \\  if n <= 1 then return 1 end
        \\  return n * fact(n - 1)
        \\end
        \\return fact(5)
    )).asInt());
}

test "each loop iteration captures a distinct binding" {
    // Classic closure-in-loop test: without per-iteration closing, every
    // closure would see the final value. With it, fns[k] returns k.
    try testing.expectEqual(@as(i64, 2), (try runScalar(
        \\local fns = {}
        \\for i = 1, 3 do
        \\  local x = i
        \\  fns[i] = function() return x end
        \\end
        \\return fns[2]()
    )).asInt());

    try testing.expectEqual(@as(i64, 1), (try runScalar(
        \\local fns = {}
        \\for i = 1, 3 do
        \\  local x = i
        \\  fns[i] = function() return x end
        \\end
        \\return fns[1]()
    )).asInt());
}

test "nested closures capture across two levels" {
    try testing.expectEqual(@as(i64, 6), (try runScalar(
        \\local function outer(a)
        \\  return function(b)
        \\    return function(c) return a + b + c end
        \\  end
        \\end
        \\return outer(1)(2)(3)
    )).asInt());
}

test "unsupported construct produces a diagnostic, not a crash" {
    // Generic `for ... in` is not supported yet.
    const src = "for x in y do end";
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    var tree = try parser.parse(testing.allocator, src, &diags);
    defer tree.deinit();

    var vm = try interp.Vm.init(testing.allocator);
    defer vm.deinit();
    try testing.expectError(Error.CompileError, compile(testing.allocator, &vm.heap, src, tree.root, &diags));
    try testing.expect(diags.hasErrors());
}

/// Compile `src` with an explicit known-globals set and run `check` against the
/// resulting diagnostics while the chunk (and its arena-allocated warning
/// messages) is still alive.
fn checkGlobals(
    src: [:0]const u8,
    known: []const []const u8,
    check: *const fn (diags: *const Diagnostics) anyerror!void,
) !void {
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    var tree = try parser.parse(testing.allocator, src, &diags);
    defer tree.deinit();
    try testing.expect(!diags.hasErrors());

    var vm = try interp.Vm.init(testing.allocator);
    defer vm.deinit();
    var chunk = try compileWithOptions(testing.allocator, &vm.heap, src, tree.root, &diags, .{
        .known_globals = known,
    });
    defer chunk.deinit();

    try check(&diags);
}

test "unknown global: a read that is never assigned warns" {
    const Probe = struct {
        fn check(diags: *const Diagnostics) anyerror!void {
            // `d` is read but never written and is not a builtin → one warning.
            try testing.expectEqual(@as(usize, 1), diags.count());
            try testing.expect(!diags.hasErrors());
            const d = diags.list.items[0];
            try testing.expectEqual(diag.Severity.warning, d.severity);
            // Span covers exactly the single-character `d` read.
            try testing.expectEqual(@as(u32, 1), d.end - d.start);
            try testing.expect(std.mem.indexOf(u8, d.message, "undefined global") != null);
            try testing.expect(std.mem.indexOf(u8, d.message, "'d'") != null);
        }
    };
    try checkGlobals(
        \\local sum = 0
        \\sum = sum + d
        \\
    , &.{}, Probe.check);
}

test "unknown global: a builtin read does NOT warn" {
    const Probe = struct {
        fn check(diags: *const Diagnostics) anyerror!void {
            try testing.expectEqual(@as(usize, 0), diags.count());
        }
    };
    try checkGlobals("print(1)\n", &.{"print"}, Probe.check);
}

test "unknown global: a global assigned elsewhere does NOT warn" {
    const Probe = struct {
        fn check(diags: *const Diagnostics) anyerror!void {
            try testing.expectEqual(@as(usize, 0), diags.count());
        }
    };
    try checkGlobals(
        \\g = 1
        \\print_unused = g
        \\
    , &.{}, Probe.check);
}

test "unknown global: a forward reference to a later global function does NOT warn" {
    const Probe = struct {
        fn check(diags: *const Diagnostics) anyerror!void {
            // `helper` is read before its `function helper()` declaration; the
            // deferred two-phase check sees the write and stays quiet.
            try testing.expectEqual(@as(usize, 0), diags.count());
        }
    };
    try checkGlobals(
        \\local function main()
        \\  return helper()
        \\end
        \\function helper()
        \\  return 1
        \\end
        \\
    , &.{}, Probe.check);
}
