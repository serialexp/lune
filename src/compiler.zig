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
//! `if`/`while`/numeric-`for`/generic-`for`/`do`/`break`/`return`, globals,
//! function literals/declarations/`local function`, calls and method calls, and
//! upvalue closures, and varargs (`...`: spread/forward/destructure in
//! expanding positions, first-value in single position; `...` outside a vararg
//! function is diagnosed). Not yet: named varargs (`...rest`, `#rest`,
//! `rest[i]`) and `{...}`/`{f()}` table-spread.

const std = @import("std");
const ast = @import("ast.zig");
const bytecode = @import("bytecode.zig");
const value = @import("value.zig");
const gc = @import("gc.zig");
const diag = @import("diag.zig");
const bc_liveness = @import("bc_liveness.zig");

const Instr = bytecode.Instr;
const OpCode = bytecode.OpCode;
const Proto = bytecode.Proto;
const Span = bytecode.Span;
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
    /// Number of protos in this chunk's tree (root + nested), i.e. how many ids
    /// `assignProtoIds` consumed starting at `Options.id_base`. The runtime
    /// `load` path uses this to advance the VM's global proto-id counter so each
    /// dynamically-compiled chunk occupies a disjoint id range (serialization
    /// resolves a `proto_id` to exactly one proto across static + loaded chunks).
    proto_count: u32 = 0,

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
    /// First proto id to assign (pre-order, root = `id_base`). Default 0 for the
    /// static main chunk. The runtime `load` path passes the VM's running proto-id
    /// counter so loaded chunks get a disjoint id range — required so a serialized
    /// closure's `proto_id` resolves to exactly one proto across all chunks.
    id_base: u32 = 0,
    /// Compile the top-level chunk as a **vararg function**, so `...` inside it is
    /// legal and a call passes extra arguments through as varargs. Default false
    /// (the CLI main chunk takes its arguments via the `arg` table, not `...`).
    /// The runtime `load` path sets this true to match Lua, where a loaded chunk
    /// is vararg and `load("return ...")(1, 2)` yields its arguments.
    vararg_root: bool = false,
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
        .is_vararg = opts.vararg_root,
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
        .spans = c.spans.items,
        .constants = c.constants.items,
        .num_registers = c.max_reg,
        .protos = c.protos.items,
        .name = "main",
        .is_vararg = c.is_vararg,
        // Doc 56 §4.2: per-pc register liveness, from the finished code.
        .reg_live = try bc_liveness.compute(c.arena, c.scratch, c.code.items, c.max_reg, c.protos.items),
    };
    // Assign every proto a stable, unique id (pre-order over the proto tree,
    // root = `id_base`). This is the proto's serialization identity — a trace's
    // anchor and a serialized closure name their proto by this id, not by the
    // in-memory pointer. Order is irrelevant; only uniqueness and stability-
    // within-a-compile matter. The same pass records `source` on every proto so
    // the runtime-error path can resolve span offsets to lines against the chunk
    // this proto actually came from (load support).
    var next_id: u32 = opts.id_base;
    assignProtoIds(proto, &next_id, source);

    // Moving `arena` is safe: code/constants/proto live in arena *heap* buffers,
    // not in the struct, so the pointers stay valid; only the `c.arena` handle
    // goes stale and we no longer use it.
    return .{ .arena = arena, .proto = proto, .proto_count = next_id - opts.id_base };
}

/// Pre-order walk assigning each proto a unique id. `@constCast` is sound: the
/// children were created as mutable `*Proto` in the compile arena (see
/// `compileFunction`); the `[]const *const Proto` field type is only a
/// downstream immutability contract, not the original allocation's constness.
/// 1-based source line containing byte `offset` (counts newlines before it).
/// Shared by the compiler's diagnostics and the runtime-error path in `interp`.
pub fn lineFromOffset(source: []const u8, offset: u32) u32 {
    var line: u32 = 1;
    var i: usize = 0;
    const end = @min(offset, source.len);
    while (i < end) : (i += 1) {
        if (source[i] == '\n') line += 1;
    }
    return line;
}

fn assignProtoIds(proto: *Proto, next: *u32, source: []const u8) void {
    proto.id = next.*;
    proto.source = source;
    next.* += 1;
    for (proto.protos) |child| assignProtoIds(@constCast(child), next, source);
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
    /// Source span per emitted instruction, parallel to `code` (→ `Proto.spans`).
    /// `emit` stamps each instruction with `cur_span`, so the runtime-error path
    /// can map a faulting `pc` back to source. Kept in lockstep: every `emit`
    /// appends to both.
    spans: std.ArrayList(Span) = .empty,
    /// The source span currently being compiled, set at statement/expression
    /// boundaries (`compileStmt`/`compileExprTo`). Whatever `emit` runs under
    /// gets stamped with this. Defaults to the start of source.
    cur_span: ast.Span = .{ .start = 0, .end = 0 },
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
        // Doc 44 D12b identity CONTRACT: every executable pc must stay below
        // `trace_code.CONT_PC_BIT` (1 << 31) so a continuation anchor's
        // tagged pc (`CONT_PC_BIT | resume_pc`) can never collide with an
        // executable pc — and so no resume pc can reach `0x7fffffff`, whose
        // encoding would alias `FUNC_HEAD_PC`. Hard-fail, not clamp: a
        // 2-billion-instruction proto is corrupt input, not a program.
        if (self.code.items.len >= 1 << 31)
            return self.fail(self.cur_span, "function too large (2^31 instruction limit)");
        try self.code.append(self.arena, instr);
        try self.spans.append(self.arena, .{ .start = self.cur_span.start, .end = self.cur_span.end });
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
    /// anywhere in the chunk and isn't a host builtin. In mahina (Lua/Luau
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
        self.cur_span = s.span;
        switch (s.data) {
            .local => |l| try self.compileLocal(l),
            .assign => |a| try self.compileAssign(a),
            .compound_assign => |ca| try self.compileCompoundAssign(ca),
            .do => |body| {
                self.beginScope();
                try self.compileBlock(body);
                try self.endScope();
            },
            .while_ => |w| try self.compileWhile(w),
            .repeat => |r| try self.compileRepeat(r),
            .if_ => |f| try self.compileIf(f),
            .numeric_for => |nf| try self.compileNumericFor(nf),
            .return_ => |exprs| try self.compileReturn(exprs),
            .break_ => try self.compileBreak(s.span),
            .call => |call_expr| try self.compileCallStmt(call_expr),
            .function_decl => |fd| try self.compileFunctionDecl(fd),
            .local_function => |lf| try self.compileLocalFunction(lf),

            .generic_for => |gf| try self.compileGenericFor(gf),
        }
    }

    fn compileLocal(self: *Compiler, l: anytype) Error!void {
        const start = self.next_reg;
        const n_names: u16 = @intCast(l.names.len);
        try self.compileValuesInto(l.values, start, n_names);
        // Declare names only after the RHS is evaluated (Lua scoping: `local x = x`
        // reads the outer `x`).
        for (l.names, 0..) |nm, j| {
            try self.declareLocal(nm.name, @intCast(start + j));
        }
    }

    fn compileAssign(self: *Compiler, a: anytype) Error!void {
        const mark = self.next_reg;
        const val_base = self.next_reg;
        const n_targets: u16 = @intCast(a.targets.len);
        try self.compileValuesInto(a.values, val_base, n_targets);
        for (a.targets, 0..) |tgt, j| {
            try self.compileStore(tgt, @intCast(val_base + j));
        }
        self.freeTo(mark);
    }

    /// `target OP= value`. Desugars to `target = target OP value` while evaluating
    /// `target`'s prefix/index expressions **exactly once** (the single-evaluation
    /// contract: `t[f()] += 1` calls `f` once). `op` is always a real binary op
    /// (the parser never produces a short-circuit op here), so `binOpCode` is safe.
    fn compileCompoundAssign(self: *Compiler, ca: anytype) Error!void {
        const tgt = ca.target;
        const op_span = ast.Span{ .start = tgt.span.start, .end = ca.value.span.end };
        switch (tgt.data) {
            .name => |nm| {
                // No side-effecting prefix: load current, combine, store back.
                const m = self.next_reg;
                const acc = try self.alloc1();
                try self.loadName(nm, acc, tgt.span);
                const rhs = try self.alloc1();
                try self.compileExprTo(ca.value, rhs);
                self.cur_span = op_span;
                _ = try self.emit(Instr.opABC(binOpCode(ca.op), acc, acc, rhs));
                try self.storeName(nm, acc, tgt.span);
                self.freeTo(m);
            },
            .field => |f| {
                // Evaluate `obj` once; the key is a constant string (no eval order
                // concern), held in a register so the load and store share it.
                const m = self.next_reg;
                const obj = try self.alloc1();
                try self.compileExprTo(f.obj, obj);
                const key = try self.alloc1();
                const k = try self.stringConstant(f.name);
                _ = try self.emit(Instr.opAB(.load_const, key, k));
                try self.compoundIndexStore(obj, key, ca.op, ca.value, op_span);
                self.freeTo(m);
            },
            .index => |ix| {
                // Evaluate BOTH `obj` and `key` once, then load→combine→store
                // through the held registers.
                const m = self.next_reg;
                const obj = try self.alloc1();
                try self.compileExprTo(ix.obj, obj);
                const key = try self.alloc1();
                try self.compileExprTo(ix.key, key);
                try self.compoundIndexStore(obj, key, ca.op, ca.value, op_span);
                self.freeTo(m);
            },
            else => unreachable, // parser guarantees the target is assignable
        }
    }

    /// Shared tail of an indexed compound assignment: `obj[key] = obj[key] OP value`
    /// reusing the already-evaluated `obj`/`key` registers (single-eval). Allocates
    /// only scratch above them and frees it before returning.
    fn compoundIndexStore(self: *Compiler, obj: u16, key: u16, op: ast.BinaryOp, rhs_expr: *const ast.Expr, op_span: ast.Span) Error!void {
        const m = self.next_reg;
        const cur = try self.alloc1();
        _ = try self.emit(Instr.opABC(.get_index, cur, obj, key));
        const rhs = try self.alloc1();
        try self.compileExprTo(rhs_expr, rhs);
        self.cur_span = op_span;
        _ = try self.emit(Instr.opABC(binOpCode(op), cur, cur, rhs));
        _ = try self.emit(Instr.opABC(.set_index, obj, key, cur));
        self.freeTo(m);
    }

    /// Fill registers `[base, base + want)` with the values of `exprs`, applying
    /// Lua's adjustment rules used by multi-assignment and `local`:
    ///   - too few values → nil-pad the remaining slots;
    ///   - a **call** in the *last* position expands to fill the remaining slots
    ///     (multi-return), so `local a, b = f()` binds both of `f`'s results;
    ///   - surplus values are evaluated (side effects) and discarded.
    /// Precondition: `next_reg == base`. Postcondition: `next_reg == base + want`
    /// and the window holds the adjusted values.
    fn compileValuesInto(self: *Compiler, exprs: []const *ast.Expr, base: u16, want: u16) Error!void {
        std.debug.assert(self.next_reg == base); // window is allocated by this helper
        const n = exprs.len;
        if (n == 0) {
            var p: u16 = 0;
            while (p < want) : (p += 1) {
                const r = try self.alloc1();
                _ = try self.emit(Instr.opA(.load_nil, r));
            }
            return;
        }
        if (n >= want) {
            // Enough (or surplus) values: each slot gets its own expr (the last is
            // truncated to one result like any other), then surplus is discarded.
            var p: usize = 0;
            while (p < want) : (p += 1) {
                const r = try self.alloc1();
                try self.compileExprTo(exprs[p], r);
            }
            while (p < n) : (p += 1) {
                const m = self.next_reg;
                const r = try self.alloc1();
                try self.compileExprTo(exprs[p], r);
                self.freeTo(m);
            }
            return;
        }
        // n < want: leading exprs are one-per-slot; the last expr either expands
        // (call → multi-return filling the remaining slots) or nil-pads.
        var p: usize = 0;
        while (p < n - 1) : (p += 1) {
            const r = try self.alloc1();
            try self.compileExprTo(exprs[p], r);
        }
        const last = exprs[n - 1];
        const remaining: u16 = want - @as(u16, @intCast(n - 1)); // >= 2 here
        if (last.isCall()) {
            // next_reg == base + (n-1): the call's results land in place, filling
            // [base + (n-1), base + want).
            try self.compileCallInPlace(last, remaining);
        } else if (last.data == .vararg) {
            // `local a, b, c = x, ...` — fill the remaining slots with the first
            // `remaining` varargs (`...[1..remaining]`), nil-padded. A constant
            // index per slot keeps this in fixed registers (no dynamic reg_top).
            try self.requireVararg(last.span);
            var j: u16 = 0;
            while (j < remaining) : (j += 1) {
                const slot = try self.alloc1();
                _ = try self.emit(Instr.opAx(.load_int, slot, j + 1));
                _ = try self.emit(Instr.opAB(.vararg_get, slot, slot));
            }
        } else {
            const r = try self.alloc1();
            try self.compileExprTo(last, r);
            var q: u16 = @intCast(n);
            while (q < want) : (q += 1) {
                const rr = try self.alloc1();
                _ = try self.emit(Instr.opA(.load_nil, rr));
            }
        }
    }

    /// Emit a call (`.call` or `.method_call`) whose function slot sits at the
    /// current `next_reg`, requesting `nwanted` results and leaving them live in
    /// `[base, base + nwanted)` with no result `move`. Used for multi-return in
    /// the last value position. Postcondition: `next_reg == base + nwanted`
    /// (argument temporaries above the result window are freed).
    fn compileCallInPlace(self: *Compiler, expr: *const ast.Expr, nwanted: u16) Error!void {
        const base = self.next_reg;
        switch (expr.data) {
            .call => |c| {
                _ = try self.alloc1(); // function slot at base; results land here
                try self.compileExprTo(c.callee, base);
                // Reuse the spread-aware arg layout: a trailing call/`...` expands.
                try self.compileArgList(c.args, base, expr.span, nwanted);
            },
            .method_call => |mc| {
                _ = try self.alloc1(); // function slot at base
                const self_reg = try self.alloc1(); // base+1 = self (first argument)
                try self.compileExprTo(mc.obj, self_reg);
                const km = self.next_reg;
                const key = try self.alloc1();
                const k = try self.stringConstant(mc.name);
                _ = try self.emit(Instr.opAB(.load_const, key, k));
                _ = try self.emit(Instr.opABC(.get_index, base, self_reg, key));
                self.freeTo(km); // free the key temp; fn + self stay
                try self.compileMethodArgs(base, mc.args, expr.span, nwanted);
            },
            else => unreachable, // guarded by isCall()
        }
        // Leave the result window live; free any argument temporaries above it.
        // A dynamic (`all_results`) call has an unknown result count, so collapse
        // back to the result base — the caller emits the consuming `call`/`ret`
        // immediately after, before allocating anything else. (`max_reg` already
        // covers the function + argument temporaries from the alloc1s above.)
        self.next_reg = if (nwanted == bytecode.all_results) base else base + nwanted;
        if (self.next_reg > self.max_reg) self.max_reg = self.next_reg;
    }

    /// Fail unless the function being compiled is variadic. Gate for every use
    /// of `...` (bare or named).
    fn requireVararg(self: *Compiler, span: ast.Span) Error!void {
        if (!self.is_vararg) return self.fail(span, "cannot use '...' outside a vararg function");
    }

    /// Emit a `vararg_spread` whose values land at the current `next_reg`, the
    /// dynamic (`all_results`) sibling of `compileCallInPlace` for a trailing
    /// `...`. The spread sets `reg_top`/`reg_top_pending`; the consuming
    /// `call`/`ret` must be emitted immediately after, before any further
    /// allocation. Postcondition: `next_reg == base` (dynamic count collapses
    /// like the `all_results` call path). Caller verifies `is_vararg`.
    fn compileSpreadInPlace(self: *Compiler) Error!void {
        const base = self.next_reg;
        _ = try self.emit(Instr.opA(.vararg_spread, base));
        self.next_reg = base;
        if (self.next_reg > self.max_reg) self.max_reg = self.next_reg;
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
                // Fuse `obj[i][j] = src` into one `set_index2` (mirror of the
                // `get_index2` fusion above): the intermediate row `obj[i]` is
                // consumed in a single op and never leaks as a bare `row_view`.
                // The grid inflation trigger (doc 14, Phase 4b) will live in the
                // `set_index2` handler.
                if (ix.obj.data == .index) {
                    const inner = ix.obj.data.index;
                    const m = self.next_reg;
                    const base = try self.alloc1();
                    try self.compileExprTo(inner.obj, base);
                    const key1 = try self.alloc1();
                    try self.compileExprTo(inner.key, key1);
                    const key2 = try self.alloc1();
                    try self.compileExprTo(ix.key, key2);
                    _ = try self.emit(.{ .op = .set_index2, .a = base, .b = key1, .c = key2, .aux = @intCast(src) });
                    self.freeTo(m);
                } else {
                    const m = self.next_reg;
                    const obj = try self.alloc1();
                    try self.compileExprTo(ix.obj, obj);
                    const key = try self.alloc1();
                    try self.compileExprTo(ix.key, key);
                    _ = try self.emit(Instr.opABC(.set_index, obj, key, src));
                    self.freeTo(m);
                }
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
        const n = exprs.len;
        // If the last value is a call, expand it: `return f()` / `return a, f()`
        // forwards *all* of `f`'s results. Earlier values (and any non-call last
        // value) are one register each.
        if (exprs[n - 1].isCall()) {
            for (exprs[0 .. n - 1]) |e| {
                const r = try self.alloc1();
                try self.compileExprTo(e, r);
            }
            try self.compileCallInPlace(exprs[n - 1], bytecode.all_results);
            _ = try self.emit(Instr.opAB(.ret, base, bytecode.all_results));
        } else if (exprs[n - 1].data == .vararg) {
            // `return a, ...` — forward every leading value then spread the rest.
            try self.requireVararg(exprs[n - 1].span);
            for (exprs[0 .. n - 1]) |e| {
                const r = try self.alloc1();
                try self.compileExprTo(e, r);
            }
            try self.compileSpreadInPlace();
            _ = try self.emit(Instr.opAB(.ret, base, bytecode.all_results));
        } else {
            for (exprs) |e| {
                const r = try self.alloc1();
                try self.compileExprTo(e, r);
            }
            _ = try self.emit(Instr.opAB(.ret, base, @intCast(n)));
        }
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

    /// `repeat body until cond`. Runs the body, then loops back while `cond` is
    /// false (exits when true) — the post-test mirror of `while`. The twist Lua
    /// requires: `cond` is evaluated in the *body's* scope, so locals declared in
    /// the body are visible to `until`. We reserve the condition register at `base`
    /// (below the body scope) and keep it live across the whole iteration, so the
    /// body's locals sit above it and `endScope` closes their upvalues normally
    /// before the back-edge — each iteration gets fresh captured cells.
    fn compileRepeat(self: *Compiler, r: anytype) Error!void {
        const base = self.next_reg;
        const loop_top = self.code.items.len;

        const cr = try self.alloc1(); // condition slot, reserved across the body

        // Body locals begin at base+1; `break` closes upvalues from there.
        try self.loops.append(self.scratch, .{ .scope_base = base + 1 });
        const loop_idx = self.loops.items.len - 1;

        self.beginScope();
        try self.compileBlock(r.body);
        // `cond` sees the body's locals (still in scope); write it into `cr`,
        // which lives below them and so survives `endScope`'s register pop.
        try self.compileExprTo(r.cond, cr);
        try self.endScope(); // pops body locals + closes their upvalues if captured

        // Loop back while the condition is false; fall through (exit) when true.
        try self.emitJumpTo(.jmp_if_false, cr, loop_top);

        self.freeTo(base); // release the condition slot
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

    /// `for v1..vn in explist do body end`. Layout mirrors `compileNumericFor`:
    /// control registers [f(iterator), s(state), ctrl(control)] at `base..base+2`,
    /// the loop variables `v1..vn` at `base+3..`. Each iteration calls
    /// `f(s, ctrl)` (a real `.call`, so the iterator may be a native like `next`
    /// *or* a user closure) wanting `n` results into the variable slots; the new
    /// `tfor_loop` continues iff the first result is non-nil, publishing it as the
    /// next `ctrl`. The iterator call window is `base+3,4,5`, so even for `n < 3`
    /// we reserve `3 + max(n,3)` registers.
    fn compileGenericFor(self: *Compiler, gf: anytype) Error!void {
        const base = self.next_reg;
        const n: u16 = @intCast(gf.names.len);

        // [f, s, ctrl] from the explist, multret-adjusted to exactly 3.
        try self.compileValuesInto(gf.exprs, base, 3);
        // Reserve the loop-variable / iterator-call window (>= 3 slots).
        const window: u16 = @max(n, 3);
        var w: u16 = 0;
        while (w < window) : (w += 1) _ = try self.alloc1();

        // Jump forward to the test block (mirrors for_prep's forward jump).
        const prep = try self.emitJump(.jmp, 0);
        const body_start = self.code.items.len;

        // Loop vars at base+3 are the lowest capturable registers in the loop
        // scope, so `break` must close upvalues from there.
        try self.loops.append(self.scratch, .{ .scope_base = @intCast(base + 3) });
        const loop_idx = self.loops.items.len - 1;

        self.beginScope();
        for (gf.names, 0..) |name, i| {
            try self.declareLocal(name, @intCast(base + 3 + i));
        }
        try self.compileBlock(gf.body);
        try self.endScope();

        // Test block (the forward-jmp target and the `tfor_loop` back-edge anchor;
        // the body falls through into it). Copy f,s,ctrl up into the call window —
        // f(base+0)/s(base+1) are never clobbered by the call, so they persist
        // across iterations — then call f(s, ctrl) for n results, then test.
        self.patchToHere(prep);
        _ = try self.emit(Instr.opAB(.move, base + 3, base + 0));
        _ = try self.emit(Instr.opAB(.move, base + 4, base + 1));
        _ = try self.emit(Instr.opAB(.move, base + 5, base + 2));
        _ = try self.emit(Instr.opABC(.call, base + 3, 2, n));
        try self.emitJumpTo(.tfor_loop, base, body_start);

        self.patchBreaks(loop_idx);
        self.freeTo(base); // release control + variable/window registers
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
        self.cur_span = e.span;
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
                const bytes = try self.decodeString(raw, e.span);
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
                // Fuse a chained `obj[i][j]` into one `get_index2` so the
                // intermediate row `obj[i]` is consumed in a single op and never
                // materialises as a bare `row_view` value — the gate that lets a
                // grid (doc 14) be read without leaking a view to a register.
                // Only the two innermost levels fuse; deeper chains compose
                // (the outer becomes a plain `get_index` on the fused result).
                if (ix.obj.data == .index) {
                    const inner = ix.obj.data.index;
                    const m = self.next_reg;
                    const base = try self.alloc1();
                    try self.compileExprTo(inner.obj, base);
                    const key1 = try self.alloc1();
                    try self.compileExprTo(inner.key, key1);
                    const key2 = try self.alloc1();
                    try self.compileExprTo(ix.key, key2);
                    _ = try self.emit(.{ .op = .get_index2, .a = dest, .b = base, .c = key1, .aux = @intCast(key2) });
                    self.freeTo(m);
                } else {
                    const m = self.next_reg;
                    const obj = try self.alloc1();
                    try self.compileExprTo(ix.obj, obj);
                    const key = try self.alloc1();
                    try self.compileExprTo(ix.key, key);
                    _ = try self.emit(Instr.opABC(.get_index, dest, obj, key));
                    self.freeTo(m);
                }
            },
            .table => |fields| try self.compileTable(fields, dest),
            .call => |c| try self.compileCall(c.callee, c.args, dest, 1),
            .method_call => |mc| try self.compileMethodCall(mc.obj, mc.name, mc.args, dest, 1),
            .function => |body| try self.compileFunction(body, "anonymous", dest),

            // `...` in single-value position yields its *first* value (or nil).
            // Tail/expanding positions are handled by the spread sites below.
            .vararg => {
                try self.requireVararg(e.span);
                _ = try self.emit(Instr.opA(.vararg_first, dest));
            },
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
            .coalesce => {
                // `a ?? b`: keep lhs unless it is *nil* (pure-nil, not falsiness —
                // `false ?? b` is `false`). RHS is skipped when lhs is non-nil.
                try self.compileExprTo(lhs, dest);
                const skip = try self.emitJump(.jmp_if_not_nil, dest); // non-nil → keep lhs
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
        // Compiling the operands reset `cur_span`; re-stamp the binop with the
        // whole `lhs op rhs` span so a runtime fault here underlines the
        // operation (which always contains the offending operand).
        self.cur_span = .{ .start = lhs.span.start, .end = rhs.span.end };
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
            .spans = child.spans.items,
            .constants = child.constants.items,
            .num_registers = child.max_reg,
            .num_params = child.num_params,
            .is_vararg = child.is_vararg,
            .protos = child.protos.items,
            .upvalues = child.upvalues.items,
            .name = name,
            // Doc 56 §4.2: per-pc register liveness, from the finished code.
            .reg_live = try bc_liveness.compute(self.arena, self.scratch, child.code.items, child.max_reg, child.protos.items),
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
        try self.compileArgList(args, base, callee.span, nwanted);
        if (nwanted >= 1 and dest != base) _ = try self.emit(Instr.opAB(.move, dest, base));
        self.freeTo(mark);
    }

    /// Lay out a call's arguments above its function slot at `base` and emit the
    /// `call`. If the last argument is itself a call, it expands (`all_results`):
    /// `print(f())` forwards every result of `f`. Each earlier argument (and a
    /// non-call last argument) is one register, truncated to a single value — so
    /// only the tail position is variadic, which keeps at most one dynamic-`reg_top`
    /// producer pending at a time. `base + 1` is the first argument slot.
    fn compileArgList(self: *Compiler, args: []const *ast.Expr, base: u16, span: ast.Span, nwanted: u16) Error!void {
        const n = args.len;
        if (n >= 1 and args[n - 1].isCall()) {
            for (args[0 .. n - 1]) |arg| {
                const r = try self.alloc1();
                try self.compileExprTo(arg, r);
            }
            try self.compileCallInPlace(args[n - 1], bytecode.all_results);
            _ = try self.emit(Instr.opABC(.call, base, bytecode.all_results, nwanted));
        } else if (n >= 1 and args[n - 1].data == .vararg) {
            // `f(a, ...)` — forward all of `...` as trailing arguments.
            try self.requireVararg(args[n - 1].span);
            for (args[0 .. n - 1]) |arg| {
                const r = try self.alloc1();
                try self.compileExprTo(arg, r);
            }
            try self.compileSpreadInPlace();
            _ = try self.emit(Instr.opABC(.call, base, bytecode.all_results, nwanted));
        } else {
            for (args) |arg| {
                const r = try self.alloc1();
                try self.compileExprTo(arg, r);
            }
            if (n > std.math.maxInt(u16)) return self.fail(span, "too many arguments");
            _ = try self.emit(Instr.opABC(.call, base, @intCast(n), nwanted));
        }
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

        // `self` is already at base+1; lay out the explicit arguments after it.
        try self.compileMethodArgs(base, args, obj.span, nwanted);
        if (nwanted >= 1 and dest != base) _ = try self.emit(Instr.opAB(.move, dest, base));
        self.freeTo(mark);
    }

    /// Lay out a method call's explicit arguments after the already-placed
    /// `self` (at `base + 1`) and emit the `.call`. Like `compileArgList`, a
    /// trailing call or `...` expands to `all_results`; otherwise `nargs` is the
    /// explicit count plus the implicit `self`. The function sits at `base`.
    fn compileMethodArgs(self: *Compiler, base: u16, args: []const *ast.Expr, span: ast.Span, nwanted: u16) Error!void {
        const n = args.len;
        if (n >= 1 and args[n - 1].isCall()) {
            for (args[0 .. n - 1]) |arg| {
                const r = try self.alloc1();
                try self.compileExprTo(arg, r);
            }
            try self.compileCallInPlace(args[n - 1], bytecode.all_results);
            _ = try self.emit(Instr.opABC(.call, base, bytecode.all_results, nwanted));
        } else if (n >= 1 and args[n - 1].data == .vararg) {
            // `obj:m(a, ...)` — `...` spreads as trailing arguments after `self`.
            try self.requireVararg(args[n - 1].span);
            for (args[0 .. n - 1]) |arg| {
                const r = try self.alloc1();
                try self.compileExprTo(arg, r);
            }
            try self.compileSpreadInPlace();
            _ = try self.emit(Instr.opABC(.call, base, bytecode.all_results, nwanted));
        } else {
            for (args) |arg| {
                const r = try self.alloc1();
                try self.compileExprTo(arg, r);
            }
            const total = n + 1; // implicit self
            if (total > std.math.maxInt(u16)) return self.fail(span, "too many arguments");
            _ = try self.emit(Instr.opABC(.call, base, @intCast(total), nwanted));
        }
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
    ///
    /// S-B (design doc 06): a string literal is **text** and always valid UTF-8 by
    /// construction. `\u{XXXX}` encodes a Unicode code point to UTF-8; `\xNN` /
    /// `\ddd` are restricted to **ASCII** (`≤ 0x7F`) — a byte `≥ 0x80` is a compile
    /// error pointing at `\u{…}` (a code point) or an integer array (a raw byte) —
    /// and the finished literal is validated as UTF-8. `span` locates diagnostics.
    fn decodeString(self: *Compiler, raw: []const u8, span: ast.Span) Error![]const u8 {
        std.debug.assert(raw.len >= 2);
        // Long-bracket string: `[` `=`{n} `[` ... `]` `=`{n} `]`. A normal string
        // always opens with `"`/`'`, so a leading `[` is an unambiguous marker.
        // No escapes; one leading newline is dropped (Lua 5.4 §3.1).
        if (raw[0] == '[') return self.decodeLongString(raw, span);
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
                    var val: u16 = 0;
                    var digits: usize = 0;
                    while (digits < 2 and i < inner.len and isHex(inner[i])) : (digits += 1) {
                        val = val * 16 + hexValue(inner[i]);
                        i += 1;
                    }
                    if (digits != 2) return self.fail(span, "\\x escape needs exactly two hex digits");
                    if (val > 0x7F) return self.fail(span, "\\x escape must be ASCII (<= 0x7F); use \\u{...} for a code point or a byte array for a raw byte");
                    try buf.append(self.arena, @intCast(val));
                },
                '0'...'9' => {
                    var val: u16 = esc - '0';
                    var digits: usize = 1;
                    while (digits < 3 and i < inner.len and inner[i] >= '0' and inner[i] <= '9') : (digits += 1) {
                        val = val * 10 + (inner[i] - '0');
                        i += 1;
                    }
                    if (val > 0x7F) return self.fail(span, "\\ddd escape must be ASCII (<= 127); use \\u{...} for a code point or a byte array for a raw byte");
                    try buf.append(self.arena, @intCast(val));
                },
                'u' => {
                    // `\u{XXXX}` — a Unicode code point encoded to UTF-8.
                    if (i >= inner.len or inner[i] != '{') return self.fail(span, "\\u must be followed by '{'");
                    i += 1;
                    var cp: u32 = 0;
                    var digits: usize = 0;
                    while (i < inner.len and isHex(inner[i])) : (digits += 1) {
                        cp = cp * 16 + hexValue(inner[i]);
                        i += 1;
                        if (cp > 0x10FFFF) return self.fail(span, "\\u{...} code point out of range (> 0x10FFFF)");
                    }
                    if (digits == 0) return self.fail(span, "\\u{...} needs at least one hex digit");
                    if (i >= inner.len or inner[i] != '}') return self.fail(span, "\\u{...} missing closing '}'");
                    i += 1;
                    var tmp: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(@intCast(cp), &tmp) catch
                        return self.fail(span, "\\u{...} is not a valid code point (surrogate or out of range)");
                    try buf.appendSlice(self.arena, tmp[0..n]);
                },
                else => try buf.append(self.arena, esc), // unknown escape → literal
            }
        }
        if (!std.unicode.utf8ValidateSlice(buf.items)) return self.fail(span, "string literal is not valid UTF-8");
        return buf.items;
    }

    /// Decode a long-bracket string literal `raw` = `[` `=`{n} `[` body `]` `=`{n} `]`.
    /// The content is verbatim (no escape interpretation); if the body begins with
    /// a newline it is dropped (Lua 5.4 §3.1: a `\r\n`/`\n\r`/`\r`/`\n` immediately
    /// after the opening bracket is not part of the string). The returned slice
    /// borrows `self.source`, which is fine — `stringConstant` interns (copies) it
    /// immediately. UTF-8 validated like every mahina string literal.
    fn decodeLongString(self: *Compiler, raw: []const u8, span: ast.Span) Error![]const u8 {
        std.debug.assert(raw[0] == '[');
        var level: usize = 0;
        while (raw[1 + level] == '=') level += 1;
        const delim = level + 2; // length of `[` `=`{level} `[` and of the close
        std.debug.assert(raw.len >= 2 * delim);
        var inner = raw[delim .. raw.len - delim];
        // Drop a single leading end-of-line (any of \n, \r, \r\n, \n\r).
        if (inner.len > 0 and (inner[0] == '\n' or inner[0] == '\r')) {
            const first = inner[0];
            inner = inner[1..];
            if (inner.len > 0 and (inner[0] == '\n' or inner[0] == '\r') and inner[0] != first) {
                inner = inner[1..];
            }
        }
        if (!std.unicode.utf8ValidateSlice(inner)) return self.fail(span, "string literal is not valid UTF-8");
        return inner;
    }

    fn lineOf(self: *const Compiler, offset: u32) u32 {
        return lineFromOffset(self.source, offset);
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
        // A grid row handle is a runtime transient, never a compiled constant.
        .row_view => unreachable,
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
        .sar => .sar,
        .and_, .or_, .coalesce => unreachable, // handled by short-circuit lowering
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
    var chunk = try compile(testing.allocator, vm.heap, src, tree.root, &diags);
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

test "repeat/until runs the body before testing and loops while false" {
    // Sums 1..5: body runs first, exits once i reaches 5.
    try testing.expectEqual(@as(i64, 15), (try runScalar(
        \\local i = 0
        \\local sum = 0
        \\repeat
        \\  i = i + 1
        \\  sum = sum + i
        \\until i >= 5
        \\return sum
    )).asInt());
}

test "repeat/until body runs at least once even when the condition is already true" {
    try testing.expectEqual(@as(i64, 1), (try runScalar(
        \\local n = 0
        \\repeat
        \\  n = n + 1
        \\until true
        \\return n
    )).asInt());
}

test "repeat/until condition sees locals declared in the body" {
    // `limit` is declared inside the body; Lua scopes it through `until`.
    try testing.expectEqual(@as(i64, 4), (try runScalar(
        \\local i = 0
        \\repeat
        \\  i = i + 1
        \\  local limit = 4
        \\until i >= limit
        \\return i
    )).asInt());
}

test "repeat/until closes a fresh upvalue cell each iteration" {
    // If the loop reused one cell, all three closures would read 3.
    try testing.expectEqual(@as(i64, 1), (try runScalar(
        \\local fns = {}
        \\local i = 0
        \\repeat
        \\  i = i + 1
        \\  local x = i
        \\  fns[i] = function() return x end
        \\until i >= 3
        \\return fns[1]()
    )).asInt());
}

test "break exits a repeat/until loop" {
    try testing.expectEqual(@as(i64, 3), (try runScalar(
        \\local k = 0
        \\repeat
        \\  k = k + 1
        \\  if k == 3 then break end
        \\until k >= 100
        \\return k
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

/// Assert that compiling `src` fails with a located diagnostic (S-B escape
/// rules). Mirrors the "unsupported construct" setup: parse, then expect
/// `compile` to return `CompileError` and record an error in the diagnostics.
fn expectCompileError(src: [:0]const u8) !void {
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    var tree = try parser.parse(testing.allocator, src, &diags);
    defer tree.deinit();
    var vm = try interp.Vm.init(testing.allocator);
    defer vm.deinit();
    try testing.expectError(Error.CompileError, compile(testing.allocator, vm.heap, src, tree.root, &diags));
    try testing.expect(diags.hasErrors());
}

test "S-B: \\u{} escape decodes to UTF-8 code point" {
    // \u{E9} → 'é' (U+00E9, 2 UTF-8 bytes); \u{1F600} → '😀' (U+1F600, 4 bytes).
    var r = try run(
        \\return "\u{E9}" .. "\u{1F600}"
    );
    defer r.deinit();
    try testing.expectEqualStrings("é😀", string.String.fromHeader(r.value.asHeap()).bytes());
}

test "S-B: \\xNN and \\ddd are ASCII-only; non-ASCII is a compile error" {
    // ASCII \x and \ddd still work.
    var r = try run(
        \\return "\x41\066"
    );
    defer r.deinit();
    try testing.expectEqualStrings("AB", string.String.fromHeader(r.value.asHeap()).bytes());

    // A byte >= 0x80 via \x or \ddd is rejected (use \u{...} or a byte array).
    try expectCompileError("return \"\\xFF\"");
    try expectCompileError("return \"\\200\"");

    // \x needs exactly two hex digits.
    try expectCompileError("return \"\\x\"");
    try expectCompileError("return \"\\xA\"");
    try expectCompileError("return \"\\xG0\"");
}

test "S-B: \\u{} rejects surrogates and over-range code points" {
    try expectCompileError("return \"\\u{D800}\""); // lone surrogate
    try expectCompileError("return \"\\u{110000}\""); // > U+10FFFF
    try expectCompileError("return \"\\u{}\""); // empty
    try expectCompileError("return \"\\u{1G}\""); // bad hex
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
    // `...` outside a vararg function is a clean compile error, not a crash:
    // `f` has no `...` in its parameter list.
    const src = "local function f() return ... end";
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    var tree = try parser.parse(testing.allocator, src, &diags);
    defer tree.deinit();

    var vm = try interp.Vm.init(testing.allocator);
    defer vm.deinit();
    try testing.expectError(Error.CompileError, compile(testing.allocator, vm.heap, src, tree.root, &diags));
    try testing.expect(diags.hasErrors());
}

test "per-instruction spans: parallel to code and map to source lines" {
    const src =
        \\local a = 1
        \\local b = 2
        \\return a + b
    ;
    var diags = Diagnostics.init(testing.allocator);
    defer diags.deinit();
    var tree = try parser.parse(testing.allocator, src, &diags);
    defer tree.deinit();
    var vm = try interp.Vm.init(testing.allocator);
    defer vm.deinit();
    var chunk = try compile(testing.allocator, vm.heap, src, tree.root, &diags);
    defer chunk.deinit();

    const proto = chunk.proto;
    // Every instruction carries a span (the two arrays stay in lockstep).
    try testing.expectEqual(proto.code.len, proto.spans.len);
    // The `add` emitted for `a + b` is stamped with line 3.
    var saw_add = false;
    for (proto.code, proto.spans) |instr, span| {
        if (instr.op == .add) {
            saw_add = true;
            try testing.expectEqual(@as(u32, 3), lineFromOffset(src, span.start));
        }
    }
    try testing.expect(saw_add);
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
    var chunk = try compileWithOptions(testing.allocator, vm.heap, src, tree.root, &diags, .{
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
