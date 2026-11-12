//! The debugger's pure-read evaluator (doc 86 §7.3, D6): `watch`, `hover`,
//! `repl` and breakpoint conditions.
//!
//! It parses the expression with the real parser and walks the AST
//! against one frame's state. It reads; it never writes, calls, or
//! allocates on the VM heap. So evaluating changes neither the heap, the
//! step counter, the logs, nor the GC schedule. What it accepts:
//!
//! - literals (string literals through the compiler's own decoder,
//!   `strlit.zig`), and backtick templates whose holes are numbers,
//!   strings, booleans or nil;
//! - names, resolved as the frame's locals (§4), then its upvalues, then
//!   globals;
//! - `.field` and `[index]` on tables, as raw gets;
//! - arithmetic, bitwise, comparison, `not`, `and`, `or` and `??` on
//!   primitive values, through the VM's own `arith` routines;
//! - `#` on strings, and on tables without `__len`;
//! - `..` on strings and numbers.
//!
//! It refuses, with a message: calls and method calls, function and
//! table constructors, `...`, and any operation where the VM would apply
//! a metamethod (an absent key in a table with `__index`, `__eq` between
//! two tables, arithmetic on a value whose metatable has the operator's
//! handler, indexing a string). An operation the VM would fault on (`nil
//! + 1`) is an error with the VM's wording, not a refusal.
//!
//! A `..` result is a scratch byte string in the caller's arena (`Val.text`):
//! nothing is interned. A string key is looked up through
//! `Heap.internedLookup`, which only reads the intern table: a byte string
//! that is not interned cannot be any table's key.

const std = @import("std");
const interp = @import("../interp.zig");
const bytecode = @import("../bytecode.zig");
const value = @import("../value.zig");
const arith = @import("../arith.zig");
const ast = @import("../ast.zig");
const parser = @import("../parser.zig");
const strlit = @import("../strlit.zig");
const table = @import("../table.zig");
const function = @import("../function.zig");
const string = @import("../string.zig");
const io = @import("../io.zig");
const Diagnostics = @import("../diag.zig").Diagnostics;

const Vm = interp.Vm;
const Value = value.Value;
const Proto = bytecode.Proto;
const Closure = function.Closure;
const Allocator = std.mem.Allocator;

/// An evaluated value: a VM value, or a byte string the evaluator built
/// (a concatenation, a template, a literal that is not interned).
pub const Val = union(enum) {
    value: Value,
    text: []const u8,

    pub fn truthy(self: Val) bool {
        return switch (self) {
            .value => |v| v.isTruthy(),
            .text => true,
        };
    }
};

pub const Outcome = union(enum) {
    ok: Val,
    /// The expression would have to run code or change state (a call, a
    /// metamethod), or does not parse.
    refused: []const u8,
    /// The expression faults as the program would (`nil + 1`).
    failed: []const u8,
};

/// The state an expression reads: one frame's registers, function and pc.
pub const Scope = struct {
    proto: *const Proto,
    closure: ?*const Closure,
    pc: u32,
    /// The frame's registers: `tags[base + r]`, `payloads[base + r]`.
    tags: []const u8,
    payloads: []const u64,
    base: usize,
    /// The source text of the frame's chunk, when the session holds it: a
    /// folded `<const>` is the literal at a span of it (§4).
    source: ?[]const u8 = null,

    /// The running frame of the running coroutine, at its published pc.
    pub fn top(vm: *const Vm) Scope {
        std.debug.assert(vm.depth > 0);
        return ofFrame(vm, vm.depth - 1);
    }

    /// Frame `i` of the running coroutine, at its pc: the instruction
    /// about to run or that raised, for the top frame, and the call it is
    /// in for one below.
    pub fn ofFrame(vm: *const Vm, i: u32) Scope {
        std.debug.assert(i < vm.depth);
        return ofStack(vm.frames[0..vm.depth], vm.tags, vm.payloads, i, true);
    }

    /// Frame `i` of one coroutine's `frames` and registers. `live` says the
    /// stack is the running one, whose top frame is at the instruction about
    /// to run (or that raised). Every other frame is inside a call, at the
    /// call instruction (`Vm.contextFrames` places a frame the same way).
    pub fn ofStack(frames: []const interp.CallFrame, tags: []const u8, payloads: []const u64, i: usize, live: bool) Scope {
        const f = &frames[i];
        const at: usize = if ((live and i == frames.len - 1) or f.in_flight) f.pc else f.pc -| 1;
        return .{
            .proto = f.closure.proto,
            .closure = f.closure,
            .pc = @intCast(at),
            .tags = tags,
            .payloads = payloads,
            .base = f.base,
        };
    }

    pub fn reg(self: Scope, r: u16) Value {
        const slot = self.base + r;
        return .{ .tag = @enumFromInt(self.tags[slot]), .payload = .{ .bits = self.payloads[slot] } };
    }
};

/// Evaluate `source`, one expression, in `scope`. Every allocation is
/// in `arena`, which the caller resets; the outcome's text lives there.
pub fn evaluate(arena: Allocator, vm: *Vm, scope: Scope, source: []const u8) Allocator.Error!Outcome {
    const expr = switch (try parseExpression(arena, source)) {
        .expr => |x| x,
        .refused => |why| return .{ .refused = why },
    };
    return evaluateExpr(arena, vm, scope, expr);
}

/// A breakpoint's condition, parsed once: it is evaluated at every hit, and
/// parsing is the part of an evaluation that costs allocations.
pub const Condition = struct {
    arena: std.heap.ArenaAllocator,
    parsed: Parsed,

    pub fn init(gpa: Allocator, source: []const u8) Allocator.Error!*Condition {
        const self = try gpa.create(Condition);
        errdefer gpa.destroy(self);
        self.arena = .init(gpa);
        errdefer self.arena.deinit();
        self.parsed = try parseExpression(self.arena.allocator(), source);
        return self;
    }

    pub fn deinit(self: *Condition, gpa: Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};

/// `evaluate` of a condition parsed already.
pub fn evaluateCondition(arena: Allocator, vm: *Vm, scope: Scope, cond: *const Condition) Allocator.Error!Outcome {
    const expr = switch (cond.parsed) {
        .expr => |x| x,
        .refused => |why| return .{ .refused = why },
    };
    return evaluateExpr(arena, vm, scope, expr);
}

fn evaluateExpr(arena: Allocator, vm: *Vm, scope: Scope, expr: *const ast.Expr) Allocator.Error!Outcome {
    var e: Evaluator = .{ .arena = arena, .vm = vm, .scope = scope };
    const v = e.eval(expr) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Refused => return .{ .refused = e.message },
        error.Failed => return .{ .failed = e.message },
    };
    return .{ .ok = v };
}

/// The value of the folded `<const>` `name` (§4), the literal at `span` of
/// the scope's source: refused when the source is not held.
pub fn foldedValue(arena: Allocator, vm: *Vm, scope: Scope, name: []const u8, span: bytecode.Span) Allocator.Error!Outcome {
    var e: Evaluator = .{ .arena = arena, .vm = vm, .scope = scope };
    const v = e.folded(name, span) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Refused => return .{ .refused = e.message },
        error.Failed => return .{ .failed = e.message },
    };
    return .{ .ok = v };
}

/// `source` as one expression, or why it is not one.
const Parsed = union(enum) { expr: *const ast.Expr, refused: []const u8 };

fn parseExpression(arena: Allocator, source: []const u8) Allocator.Error!Parsed {
    const prefix = "return ";
    const text = try arena.allocSentinel(u8, prefix.len + source.len, 0);
    @memcpy(text[0..prefix.len], prefix);
    @memcpy(text[prefix.len..], source);
    var diags = Diagnostics.init(arena);
    const tree = parser.parse(arena, text, &diags) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .refused = "the expression does not parse" },
    };
    if (diags.list.items.len != 0) {
        return .{ .refused = try std.fmt.allocPrint(arena, "the expression does not parse: {s}", .{diags.list.items[0].message}) };
    }
    if (tree.root.len != 1 or tree.root[0].data != .return_ or tree.root[0].data.return_.len != 1) {
        return .{ .refused = "evaluate takes one expression" };
    }
    return .{ .expr = tree.root[0].data.return_[0] };
}

const Fail = error{ OutOfMemory, Refused, Failed };

const Evaluator = struct {
    arena: Allocator,
    vm: *Vm,
    scope: Scope,
    message: []const u8 = "",

    fn refuse(self: *Evaluator, comptime fmt: []const u8, args: anytype) Fail {
        self.message = try std.fmt.allocPrint(self.arena, fmt, args);
        return error.Refused;
    }

    fn fail(self: *Evaluator, comptime fmt: []const u8, args: anytype) Fail {
        self.message = try std.fmt.allocPrint(self.arena, fmt, args);
        return error.Failed;
    }

    fn eval(self: *Evaluator, x: *const ast.Expr) Fail!Val {
        return switch (x.data) {
            .nil => val(Value.nil()),
            .bool => |b| val(Value.boolean(b)),
            .int => |i| val(Value.int(i)),
            .float => |f| val(Value.float(f)),
            .string_raw => |raw| .{ .text = try self.decoded(try strlit.decodeString(self.arena, raw)) },
            .string_interp => |t| self.template(t.chunks, t.holes),
            .name => |n| self.name(n),
            .paren => |inner| self.eval(inner),
            .unary => |u| self.unary(u.op, u.operand),
            .binary => |b| self.binary(b.op, b.lhs, b.rhs),
            .field => |f| val(try self.index(try self.eval(f.obj), .{ .text = f.name })),
            .index => |ix| blk: {
                const obj = try self.eval(ix.obj);
                break :blk val(try self.index(obj, try self.eval(ix.key)));
            },
            .call, .method_call => self.refuse("evaluate does not call functions", .{}),
            .function => self.refuse("evaluate does not make functions", .{}),
            .table => self.refuse("evaluate does not make tables", .{}),
            .intrinsic => self.refuse("evaluate does not run intrinsics", .{}),
            .vararg => self.refuse("evaluate does not read '...'", .{}),
            .err => self.refuse("the expression does not parse", .{}),
        };
    }

    fn val(v: Value) Val {
        return .{ .value = v };
    }

    fn decoded(self: *Evaluator, d: strlit.Decoded) Fail![]const u8 {
        return switch (d) {
            .ok => |bytes| bytes,
            .bad => |code| self.refuse("bad string literal: {s}", .{code.message()}),
        };
    }

    // ---- names -------------------------------------------------------

    fn name(self: *Evaluator, n: []const u8) Fail!Val {
        const sc = self.scope;
        // The innermost visible local of that name (`locals` is sorted by
        // start pc, so the last visible row is the innermost).
        var i = sc.proto.locals.len;
        while (i > 0) {
            i -= 1;
            const lv = sc.proto.locals[i];
            if (!lv.visibleAt(sc.pc) or !std.mem.eql(u8, lv.name, n)) continue;
            switch (lv.loc) {
                .reg => |r| {
                    const live = sc.proto.reg_live;
                    if (live.available() and sc.pc < sc.proto.code.len and !live.liveIn(sc.pc, r))
                        return self.refuse("'{s}' is not available here (its register is dead)", .{n});
                    return val(sc.reg(r));
                },
                .literal => |span| return self.folded(n, span),
            }
        }
        if (sc.closure) |cl| {
            for (sc.proto.upval_names, 0..) |un, idx| {
                if (!std.mem.eql(u8, un, n) or idx >= cl.upvalues.len) continue;
                const cell = cl.upvalues[idx];
                return val(.{ .tag = @enumFromInt(cell.tag.*), .payload = .{ .bits = cell.payload.* } });
            }
        }
        return val(try self.rawGet(Value.heap(&self.vm.globals.header), .{ .text = n }, "global"));
    }

    /// A folded `<const>` (§4): the literal at `span` of the chunk's source,
    /// read by this evaluator, so a string decodes as the compiler decodes it.
    fn folded(self: *Evaluator, n: []const u8, span: bytecode.Span) Fail!Val {
        const src = self.scope.source orelse
            return self.refuse("'{s}' is a folded <const>, and the source of its chunk is not available", .{n});
        if (span.start >= span.end or span.end > src.len)
            return self.refuse("'{s}' is a folded <const>, and its source span is outside the chunk's source", .{n});
        return switch (try parseExpression(self.arena, src[span.start..span.end])) {
            .expr => |x| self.eval(x),
            .refused => |why| self.refuse("'{s}' is a folded <const>: {s}", .{ n, why }),
        };
    }

    // ---- indexing ----------------------------------------------------

    fn index(self: *Evaluator, obj: Val, key: Val) Fail!Value {
        const o = switch (obj) {
            .value => |v| v,
            .text => return self.refuse("indexing a string goes through its metatable", .{}),
        };
        return self.rawGet(o, key, "field");
    }

    /// `obj[key]` without metamethods: a refusal where the VM would apply
    /// `__index`, the VM's fault where it would fault.
    fn rawGet(self: *Evaluator, obj: Value, key: Val, comptime what: []const u8) Fail!Value {
        if (obj.isRowView() or !obj.isHeap()) return self.fail("attempt to index a {s} value", .{obj.typeName()});
        switch (obj.heapType()) {
            .table => {},
            .string => return self.refuse("indexing a string goes through its metatable", .{}),
            .typed_array => return self.refuse("evaluate does not read typed arrays yet", .{}),
            else => if (self.metatable(obj) != null)
                return self.refuse("indexing a {s} goes through its metatable", .{obj.typeName()})
            else
                return self.fail("attempt to index a {s} value", .{obj.typeName()}),
        }
        const t = table.Table.fromHeader(obj.asHeap());
        const k: ?Value = switch (key) {
            .value => |v| v,
            // Bytes no string has can be no table's key.
            .text => |bytes| if (self.vm.heap.internedLookup(bytes)) |s| Value.heap(&s.header) else null,
        };
        if (k) |kv| if (kv.isFloat() and std.math.isNan(kv.asFloat())) return Value.nil();
        const got = if (k) |kv| t.get(kv) else Value.nil();
        if (got.isNil() and self.hasMeta(obj, self.vm.mm.index)) {
            return self.refuse("the " ++ what ++ " is absent and the table has an __index metamethod", .{});
        }
        return got;
    }

    fn metatable(self: *Evaluator, v: Value) ?*table.Table {
        return self.vm.metatableOf(v);
    }

    fn hasMeta(self: *Evaluator, v: Value, mm_name: Value) bool {
        const mt = self.metatable(v) orelse return false;
        return !mt.get(mm_name).isNil();
    }

    // ---- operators ---------------------------------------------------

    fn unary(self: *Evaluator, op: ast.UnaryOp, operand: *const ast.Expr) Fail!Val {
        const x = try self.eval(operand);
        switch (op) {
            .not => return val(Value.boolean(!x.truthy())),
            .len => return switch (x) {
                .text => |bytes| val(Value.int(@intCast(std.unicode.utf8CountCodepoints(bytes) catch bytes.len))),
                .value => |v| blk: {
                    if (v.isHeap() and v.heapType() == .table and self.hasMeta(v, self.vm.mm.len))
                        return self.refuse("the table has a __len metamethod", .{});
                    break :blk val(interp.lenOf(v) catch return self.fail("attempt to get length of a {s} value", .{v.typeName()}));
                },
            },
            .neg => return val(try self.arithmetic(x, null, .neg)),
            .bnot => return val(try self.arithmetic(x, null, .bnot)),
        }
    }

    fn binary(self: *Evaluator, op: ast.BinaryOp, lhs: *const ast.Expr, rhs: *const ast.Expr) Fail!Val {
        switch (op) {
            .and_ => {
                const a = try self.eval(lhs);
                return if (a.truthy()) self.eval(rhs) else a;
            },
            .or_ => {
                const a = try self.eval(lhs);
                return if (a.truthy()) a else self.eval(rhs);
            },
            .coalesce => {
                const a = try self.eval(lhs);
                return if (a == .value and a.value.isNil()) self.eval(rhs) else a;
            },
            else => {},
        }
        const a = try self.eval(lhs);
        const b = try self.eval(rhs);
        return switch (op) {
            .eq => val(Value.boolean(try self.equal(a, b))),
            .ne => val(Value.boolean(!try self.equal(a, b))),
            .lt => val(Value.boolean(try self.less(a, b, false))),
            .le => val(Value.boolean(try self.less(a, b, true))),
            .gt => val(Value.boolean(try self.less(b, a, false))),
            .ge => val(Value.boolean(try self.less(b, a, true))),
            .concat => .{ .text = try self.concat(a, b) },
            .add => val(try self.arithmetic(a, b, .add)),
            .sub => val(try self.arithmetic(a, b, .sub)),
            .mul => val(try self.arithmetic(a, b, .mul)),
            .div => val(try self.arithmetic(a, b, .div)),
            .idiv => val(try self.arithmetic(a, b, .idiv)),
            .mod => val(try self.arithmetic(a, b, .mod)),
            .pow => val(try self.arithmetic(a, b, .pow)),
            .band => val(try self.arithmetic(a, b, .band)),
            .bor => val(try self.arithmetic(a, b, .bor)),
            .bxor => val(try self.arithmetic(a, b, .bxor)),
            .shl => val(try self.arithmetic(a, b, .shl)),
            .shr => val(try self.arithmetic(a, b, .shr)),
            .sar => val(try self.arithmetic(a, b, .sar)),
            .and_, .or_, .coalesce => unreachable,
        };
    }

    const ArithOp = enum { add, sub, mul, div, idiv, mod, pow, band, bor, bxor, shl, shr, sar, neg, bnot };

    /// The VM's own arithmetic. An operand that is not a number takes the
    /// metamethod path in the VM, so here it is a refusal when a handler
    /// exists and the VM's fault when none does.
    fn arithmetic(self: *Evaluator, a: Val, b: ?Val, comptime op: ArithOp) Fail!Value {
        const mm_name = switch (op) {
            .neg => "unm",
            else => @tagName(op),
        };
        const handler = @field(self.vm.mm, mm_name);
        // A string is never a number to the VM's routines: the string
        // metatable decides, as it does in the VM.
        if (a == .text or (b != null and b.? == .text)) {
            const smt = self.vm.string_metatable;
            if (smt != null and !smt.?.get(handler).isNil())
                return self.refuse("the operand has a __{s} metamethod", .{mm_name});
            return self.fail("attempt to {s} a string value", .{opVerb(op)});
        }
        const x = a.value;
        const y = if (b) |bv| bv.value else x;
        const r: arith.Error!Value = switch (op) {
            .add => arith.add(x, y),
            .sub => arith.sub(x, y),
            .mul => arith.mul(x, y),
            .div => arith.div(x, y),
            .idiv => arith.floorDiv(x, y),
            .mod => arith.mod(x, y),
            .pow => arith.pow(x, y),
            .band => arith.band(x, y),
            .bor => arith.bor(x, y),
            .bxor => arith.bxor(x, y),
            .shl => arith.shl(x, y),
            .shr => arith.shr(x, y),
            .sar => arith.sar(x, y),
            .neg => arith.neg(x),
            .bnot => arith.bnot(x),
        };
        return r catch |err| switch (err) {
            error.DivisionByZero => self.fail("attempt to perform 'n{s}0'", .{if (op == .mod) "%%" else "//"}),
            error.TypeError => {
                if (self.hasMeta(x, handler) or (b != null and self.hasMeta(y, handler)))
                    return self.refuse("the operand has a __{s} metamethod", .{mm_name});
                const bad = if (!x.isNumber()) x else y;
                return self.fail("attempt to {s} a {s} value", .{ opVerb(op), bad.typeName() });
            },
        };
    }

    fn opVerb(op: ArithOp) []const u8 {
        return switch (op) {
            .band, .bor, .bxor, .shl, .shr, .sar, .bnot => "perform bitwise operation on",
            else => "perform arithmetic on",
        };
    }

    fn bytesOf(v: Val) ?[]const u8 {
        return switch (v) {
            .text => |t| t,
            .value => |x| interp.strBytes(x),
        };
    }

    fn equal(self: *Evaluator, a: Val, b: Val) Fail!bool {
        if (bytesOf(a)) |sa| {
            const sb = bytesOf(b) orelse return false;
            return std.mem.eql(u8, sa, sb);
        }
        if (b == .text) return false;
        const x = a.value;
        const y = b.value;
        if (arith.eq(x, y)) return true;
        const tables = x.isHeap() and x.heapType() == .table and y.isHeap() and y.heapType() == .table;
        if (tables and (self.hasMeta(x, self.vm.mm.eq) or self.hasMeta(y, self.vm.mm.eq)))
            return self.refuse("comparing two tables with an __eq metamethod", .{});
        return false;
    }

    fn less(self: *Evaluator, a: Val, b: Val, or_equal: bool) Fail!bool {
        if (bytesOf(a)) |sa| if (bytesOf(b)) |sb| {
            const o = std.mem.order(u8, sa, sb);
            return if (or_equal) o != .gt else o == .lt;
        };
        if (a == .value and b == .value and a.value.isNumber() and b.value.isNumber()) {
            return (if (or_equal) arith.le(a.value, b.value) else arith.lt(a.value, b.value)) catch unreachable;
        }
        const handler = if (or_equal) self.vm.mm.le else self.vm.mm.lt;
        if ((a == .value and self.hasMeta(a.value, handler)) or (b == .value and self.hasMeta(b.value, handler)))
            return self.refuse("the operand has a __{s} metamethod", .{if (or_equal) "le" else "lt"});
        return self.fail("attempt to compare {s} with {s}", .{ typeOf(a), typeOf(b) });
    }

    fn typeOf(v: Val) []const u8 {
        return switch (v) {
            .text => "string",
            .value => |x| x.typeName(),
        };
    }

    fn concat(self: *Evaluator, a: Val, b: Val) Fail![]const u8 {
        var buf_a: [64]u8 = undefined;
        var buf_b: [64]u8 = undefined;
        const pa = try self.concatPart(a, &buf_a, b);
        const pb = try self.concatPart(b, &buf_b, a);
        return std.mem.concat(self.arena, u8, &.{ pa, pb });
    }

    fn concatPart(self: *Evaluator, v: Val, buf: []u8, other: Val) Fail![]const u8 {
        switch (v) {
            .text => |t| return t,
            .value => |x| return interp.coerceConcat(x, buf) catch {
                const o = switch (other) {
                    .value => |ov| ov,
                    .text => Value.nil(),
                };
                if (self.hasMeta(x, self.vm.mm.concat) or self.hasMeta(o, self.vm.mm.concat))
                    return self.refuse("the operand has a __concat metamethod", .{});
                return self.fail("attempt to concatenate a {s} value", .{x.typeName()});
            },
        }
    }

    /// A backtick template (doc 82): the chunks with the holes' text between
    /// them. A hole renders as `tostring` would, so a value whose metatable
    /// has `__tostring` is refused.
    fn template(self: *Evaluator, chunks: []const []const u8, holes: []const *ast.Expr) Fail!Val {
        var out: std.ArrayList(u8) = .empty;
        for (chunks, 0..) |chunk, i| {
            try out.appendSlice(self.arena, try self.decoded(try strlit.decodeTemplateChunk(self.arena, chunk)));
            if (i >= holes.len) break;
            const h = try self.eval(holes[i]);
            if (bytesOf(h)) |t| {
                try out.appendSlice(self.arena, t);
                continue;
            }
            switch (h) {
                .text => unreachable,
                .value => |x| {
                    if (self.hasMeta(x, self.vm.mm.tostring))
                        return self.refuse("a hole's value has a __tostring metamethod", .{});
                    var buf: [128]u8 = undefined;
                    var w = io.Writer.fixed(&buf);
                    io.writeValue(&w, x) catch unreachable; // a scalar or "kind: 0x<id>" always fits
                    try out.appendSlice(self.arena, w.buffered());
                },
            }
        }
        return .{ .text = out.items };
    }
};
