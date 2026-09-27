//! Tier-0 register bytecode — the instruction set the compiler emits and the
//! tier-0 interpreter executes.
//!
//! **Register-based**, like Lua 5 / LuaJIT: each function activation owns a
//! window of `Value` registers (a frame), and most instructions read and write
//! registers by index rather than pushing/popping a stack. This keeps the
//! instruction count low and maps cleanly onto the trace IR later.
//!
//! Tier-0 is the *correctness oracle*, not a hot tier (the hot tiers are the
//! IR-interpreter and native codegen — see docs/design/00-architecture.md
//! §Testing strategy). So this encoding favours clarity over density: a fixed
//! 12-byte instruction with named operand fields, not a bit-packed word. The
//! trace IR — which *is* cache-sensitive — has its own representation (Phase 6).
//!
//! Operand conventions (documented per-opcode below):
//!   * `a`        — usually the destination register.
//!   * `b`, `c`   — source registers or pool indices, per opcode.
//!   * `aux`      — a signed 32-bit immediate: small int literals and relative
//!                  jump offsets.
//! `K[i]` is `constants[i]`; `R[i]` is register `i` of the current frame.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;

/// The opcode. The full tier-0 instruction set is declared up front so the ISA
/// is stable and the disassembler is total; the interpreter implements them
/// across the Phase 3 increments (unimplemented ones return `error.Unimplemented`
/// until their runtime support lands). Operand meaning is given per variant.
pub const OpCode = enum(u8) {
    // ---- loads & moves ----
    /// `a`         R[a] = nil
    load_nil,
    /// `a, b`      R[a] = (b != 0)   — load a boolean immediate
    load_bool,
    /// `a, aux`    R[a] = int(aux)   — small integer immediate (fits i32)
    load_int,
    /// `a, b`      R[a] = K[b]       — load from the constant pool
    load_const,
    /// `a, b`      R[a] = R[b]       — copy a register
    move,

    // ---- arithmetic:   R[a] = R[b] op R[c]  (semantics in arith.zig) ----
    add,
    sub,
    mul,
    div,
    idiv,
    mod,
    pow,

    // ---- bitwise:      R[a] = R[b] op R[c] ----
    band,
    bor,
    bxor,
    shl,
    shr,
    sar,

    // ---- unary:        R[a] = op R[b] ----
    neg,
    not,
    bnot,
    /// `#R[b]` — length (string/table aware; Increment B/E).
    len,

    // ---- concat:       R[a] = R[b] .. R[c]   (Increment B/E) ----
    concat,

    // ---- comparisons:  R[a] = bool ----
    eq,
    ne,
    lt,
    le,
    gt,
    ge,

    // ---- control flow ----
    /// `aux`       pc += aux   (relative, measured from the next instruction)
    jmp,
    /// `a, aux`    if !truthy(R[a]) pc += aux
    jmp_if_false,
    /// `a, aux`    if  truthy(R[a]) pc += aux
    jmp_if_true,
    /// `a, aux`    if R[a] is NOT nil, pc += aux. The nil-specific test backing
    ///             `??` (nil-coalescing): unlike `jmp_if_true`, a non-nil-but-
    ///             falsy value (`false`, `0`) keeps the lhs rather than falling
    ///             through to the rhs.
    jmp_if_not_nil,
    /// `a, aux`    numeric-for setup. R[a..a+3) = (idx, limit, step); validates
    ///             they are numbers, pre-subtracts step from idx, then `pc += aux`
    ///             to the matching `for_loop`.
    for_prep,
    /// `a, aux`    numeric-for step+test. idx (R[a]) += step (R[a+2]); if still
    ///             within limit (R[a+1], direction from step's sign), copy idx to
    ///             the loop variable R[a+3] and `pc += aux` (back-edge to the
    ///             body). Otherwise fall through (loop done).
    for_loop,
    /// `a, aux, b` patched trace entry (doc 20, the LuaJIT `BC_JFORL`
    ///             analogue). Written ONLY into a per-VM copy-on-patch code
    ///             image over a qualified anchor's `.for_loop` — canonical
    ///             `Proto.code` NEVER contains it. `.a`/`.aux` preserved
    ///             verbatim from the patched `.for_loop`; `.b` carries the
    ///             entry-patch slot index into the VM's registry. Executes
    ///             the exact `.for_loop` step semantics, then (Phase 1)
    ///             dispatches the bound trace via `enterSelectedTrace`,
    ///             skipping the per-back-edge discovery/selection cascade.
    jfor_loop,
    /// `a, aux, b` patched trace entry for while/repeat/generic-for loop
    ///             closers (doc 20 Phase 3, the `.jloop` analogue). Written
    ///             ONLY into a per-VM copy-on-patch image over a backward
    ///             `.jmp` (while), `.jmp_if_false` (repeat), or `.tfor_loop`
    ///             (generic-for — recordable since doc 30 c4); canonical
    ///             `Proto.code` NEVER contains it. `.a`/`.aux` retain the
    ///             original instruction's operands and `.b` carries the
    ///             entry-patch slot index. The dispatch arm executes the
    ///             original semantics first (from `patch.orig`); only a taken
    ///             back-edge enters the bound trace.
    jloop,
    /// `a, aux`    generic-for test+continue. The preceding `call` has already
    ///             written the loop variables into R[a+3..]. If the first loop
    ///             variable R[a+3] is **not nil** (Lua stops only on nil; `false`
    ///             continues), copy it to the control slot R[a+2] and `pc += aux`
    ///             (back-edge to the body). Otherwise fall through (loop done).
    ///             Unlike `for_loop` it computes nothing — the iterator call did.
    tfor_loop,

    // ---- tables   (Increment B/E) ----
    /// `a`         R[a] = {}   (new empty table)
    new_table,
    /// `a, b, c`   R[a] = R[b][R[c]]
    get_index,
    /// `a, b, c`   R[a][R[b]] = R[c]
    set_index,
    /// `a, b, c, aux`  R[a] = R[b][R[c]][R[aux]]   (fused two-level read)
    ///             The compiler emits this for a chained `obj[i][j]` so the
    ///             intermediate row `obj[i]` is consumed in one op and never
    ///             materialises as a bare `row_view` value — the gate that lets a
    ///             grid (doc 14) be touched without leaking a view to a register.
    ///             Semantically identical to two `get_index`es on a nested table.
    get_index2,
    /// `a, b, c, aux`  R[a][R[b]][R[c]] = R[aux]   (fused two-level store)
    ///             Emitted for `obj[i][j] = v`. The grid inflation trigger
    ///             (doc 14) lives here; on a nested table it is two-step identical.
    set_index2,

    // ---- globals  (Increment D) ----
    /// `a, b`      R[a] = G[K[b]]   (K[b] is the global name string)
    get_global,
    /// `a, b`      G[K[b]] = R[a]
    set_global,

    // ---- functions (Increment D) ----
    /// `a, b`      R[a] = closure(protos[b])  capturing upvalues
    closure,
    /// `a, b`      R[a] = upvalue[b]
    get_upval,
    /// `a, b`      upvalue[b] = R[a]
    set_upval,
    /// `a`         close every open upvalue whose register is `>= a` (the
    ///             leaving scope's first register): snapshot the captured value
    ///             into the cell so it outlives the registers about to be freed.
    ///             Emitted at block/loop-scope exit and `break`.
    close_upvalues,
    /// `a, b, c`   call R[a] with `b` args in R[a+1..a+1+b], want `c` results
    ///             written back starting at R[a]. `c == max_results` means "all".
    call,
    /// `a, b`      return `b` values from R[a..a+b]. `b == 0` is "no values".
    ret,

    // ---- varargs (Phase 3d2) — read the current frame's `...` cursor ----
    /// `a`         R[a] = the first vararg, or nil if there are none. Emitted
    ///             when `...` / a named vararg appears in single-value position.
    vararg_first,
    /// `a`         R[a] = int(vararg count). Emitted for `#name` on a named vararg.
    vararg_len,
    /// `a, b`      R[a] = (1 <= R[b] <= count) ? vararg[R[b]] : nil. 1-based,
    ///             bounds-checked. Emitted for `name[i]` on a named vararg.
    vararg_get,
    /// `a`         spread all varargs into R[a..a+count) and set `reg_top` to their
    ///             end (the dynamic-multret producer half — same protocol as a
    ///             trailing `call`/native). Emitted in expanding positions: the last
    ///             call arg, the return list, the last of a multi-assign.
    vararg_spread,

    // ---- misc ----
    /// Stop top-level execution (implicit final instruction of the main chunk).
    halt,

    /// `b` (+ orig operands preserved) patched FUNCTION-HEAD trace entry
    ///             (doc 44 P0, the LuaJIT `BC_JFUNCF` analogue). Written ONLY
    ///             into a per-VM copy-on-patch image over a head-qualified
    ///             proto's pc 0 — canonical `Proto.code` NEVER contains it.
    ///             Unlike `.jfor_loop`/`.jloop` the patched-over instruction
    ///             is ARBITRARY (whatever the function body starts with), so
    ///             the handler owns no canonical step semantics of its own:
    ///             it tries the bound head trace and, on decline/bypass,
    ///             tail-dispatches `patch.orig` through the ordinary handler
    ///             table. `.b` carries the entry-patch slot index; appended
    ///             LAST to keep the enum dense (doc 42 §4.6).
    jfunc_head,

    /// `b` (+ orig operands preserved) patched CONTINUATION trace entry
    ///             (doc 44 D12b — the return-side `jfunc_head` twin). Written
    ///             ONLY into a per-VM copy-on-patch image over a hot post-call
    ///             resume pc — canonical `Proto.code` NEVER contains it. The
    ///             patched-over instruction is ARBITRARY (whatever follows the
    ///             call), so the handler owns no canonical step semantics: it
    ///             tries the bound cont trace and, on decline/bypass,
    ///             tail-dispatches the canonical instruction through the
    ///             ordinary handler table. `.b` carries the entry-patch slot
    ///             index; appended LAST to keep the enum dense (doc 42 §4.6).
    jcont,

    /// `b, aux`    loop marker (doc 58, LuaJIT's `BC_LOOP`). Emitted right
    ///             after a `while` loop's condition branch and at the top of a
    ///             `repeat` loop. `.b` is the loop kind (`LoopKind`); `.aux` is
    ///             the offset from `pc + 1` to the loop's exit pc (the first
    ///             instruction after the loop) — NOT a jump: execution always
    ///             falls through to `pc + 1`. Doc 58 B1: a no-op in every tier;
    ///             B2 makes it the loop's back-edge, whose header is `pc + 1`.
    ///             Appended LAST to keep the enum dense (doc 42 §4.6).
    loop,
};

/// Doc 58: the kind of loop a `loop` marker belongs to, in its `.b` operand.
pub const LoopKind = enum(u16) {
    while_loop = 0,
    repeat_loop = 1,
};

/// Doc 58: the header of the loop whose back-edge instruction is `ins` at
/// `pc` — the pc a trace for that loop is anchored at — or null when `ins` is
/// not a loop back-edge. The one definition of "which instructions are
/// back-edges"; every walker that needs a loop header asks here instead of
/// decoding `aux` itself (a `loop` marker's `aux` is its exit offset, so the
/// generic `pc + 1 + aux` would be wrong for it).
///
/// B1 (today's shape): a backward jump of any kind, `for_loop` and
/// `tfor_loop` are back-edges; the `loop` marker is not one yet.
pub fn loopHeaderOf(ins: Instr, pc: usize) ?u32 {
    switch (ins.op) {
        .jmp, .jmp_if_true, .jmp_if_false, .jmp_if_not_nil, .for_loop, .tfor_loop => {},
        else => return null,
    }
    const t: i64 = @as(i64, @intCast(pc)) + 1 + ins.aux;
    if (t < 0 or t > @as(i64, @intCast(pc))) return null;
    return @intCast(t);
}

/// Doc 58: the static extent of one loop — every instruction from `start` to
/// `end` inclusive runs inside it — plus its back-edge instruction.
pub const LoopExtent = struct {
    start: u32,
    end: u32,
    back_edge_pc: u32,
    back_edge_op: OpCode,
};

/// Doc 58: the extent of the loop whose header is `header`, found through its
/// unique back-edge (`loopHeaderOf`). Null when no back-edge has this header,
/// or more than one does (ambiguous: callers fail closed). Replaces the two
/// numeric-only `forLoopEndFor` copies.
///
/// B1 (today's shape): every loop runs from its header to its back-edge.
pub fn loopExtentFor(proto: *const Proto, header: u32) ?LoopExtent {
    var found: ?LoopExtent = null;
    for (proto.code, 0..) |ins, i| {
        if (loopHeaderOf(ins, i) != header) continue;
        if (found != null) return null; // ambiguous
        found = .{ .start = header, .end = @intCast(i), .back_edge_pc = @intCast(i), .back_edge_op = ins.op };
    }
    return found;
}

/// Doc 58: the exit pc (first instruction after the loop) of a `loop` marker
/// at `pc`.
pub fn loopMarkerExit(ins: Instr, pc: usize) usize {
    std.debug.assert(ins.op == .loop);
    const e: i64 = @as(i64, @intCast(pc)) + 1 + ins.aux;
    std.debug.assert(e > @as(i64, @intCast(pc)));
    return @intCast(e);
}

// Doc 42 §4.6: the tail-call dispatch tables index `[@intFromEnum(op)]`
// directly, which is only sound while the enum stays dense from 0. Explicit
// or sparse discriminants must fail HERE, loudly, not as silent
// wrong-handler dispatch.
comptime {
    const info = @typeInfo(OpCode).@"enum";
    for (info.field_names, info.field_values, 0..) |name, val, i| {
        if (val != i) @compileError("OpCode must stay dense from 0: '" ++
            name ++ "' has value " ++ std.fmt.comptimePrint("{d}", .{val}) ++
            " at index " ++ std.fmt.comptimePrint("{d}", .{i}));
    }
}

/// Sentinel for `call`'s `c` operand meaning "want every result the callee
/// produces" (multi-value tail position). A real result count is `< this`.
pub const all_results: u16 = std.math.maxInt(u16);

/// One decoded instruction. 12 bytes: op (1) + three u16 operands (6) + a signed
/// 32-bit immediate (4), with one byte of natural padding. Roomy on purpose —
/// 16-bit registers/pool indices and a 32-bit jump/immediate range remove tier-0
/// scaling limits without the foot-guns of an 8-bit packing.
pub const Instr = struct {
    op: OpCode,
    a: u16 = 0,
    b: u16 = 0,
    c: u16 = 0,
    aux: i32 = 0,

    // Ergonomic constructors so hand-assembled programs (tests) and the compiler
    // read clearly. They name the operand pattern, not the opcode.

    /// Opcode with no operands (e.g. `halt`).
    pub fn op0(o: OpCode) Instr {
        return .{ .op = o };
    }

    /// `op a`
    pub fn opA(o: OpCode, a: u16) Instr {
        return .{ .op = o, .a = a };
    }

    /// `op a, b`
    pub fn opAB(o: OpCode, a: u16, b: u16) Instr {
        return .{ .op = o, .a = a, .b = b };
    }

    /// `op a, b, c`
    pub fn opABC(o: OpCode, a: u16, b: u16, c: u16) Instr {
        return .{ .op = o, .a = a, .b = b, .c = c };
    }

    /// `op a, aux` (immediate / jump-from-register forms)
    pub fn opAx(o: OpCode, a: u16, aux: i32) Instr {
        return .{ .op = o, .a = a, .aux = aux };
    }

    /// `op aux` (bare jump)
    pub fn opJ(o: OpCode, aux: i32) Instr {
        return .{ .op = o, .aux = aux };
    }
};

/// How a closure obtains one of its upvalues when it is created. Either it
/// captures a local register of the *enclosing* frame (`in_stack`), or it
/// inherits one of the enclosing closure's own upvalues. Mirrors Lua's
/// `Upvaldesc`.
pub const UpvalDesc = struct {
    /// `true`: capture the enclosing frame's local register `index`.
    /// `false`: reuse the enclosing closure's upvalue `index`.
    in_stack: bool,
    index: u16,
};

/// Doc 56 §4.2: per-pc register liveness of one proto, computed once at
/// compile time by `bc_liveness.compute`. `liveIn(pc, r)` is true when the
/// value in register `r` just BEFORE `pc` executes may be read on some path
/// from `pc` before it is overwritten (the LuaJIT `snap_usedef` question,
/// answered by a whole-proto dataflow instead of a per-snapshot scan). An
/// exit snapshot resuming at `pc` needs only these slots; a trace that
/// computed a dead local may let `tropt` delete it. `words == 0` means "no
/// table" (a hand-built proto, or one over the memory budget): callers must
/// then treat liveness as unknown, never as "dead".
pub const RegLiveness = struct {
    /// `u64` words per pc; the table is `code.len * words` long.
    words: u32 = 0,
    bits: []const u64 = &.{},

    pub fn available(self: RegLiveness) bool {
        return self.words != 0;
    }

    /// Requires `available()`, `pc < code.len` and `reg < num_registers`.
    pub fn liveIn(self: RegLiveness, pc: u32, reg: u16) bool {
        std.debug.assert(self.words != 0);
        const w = self.bits[@as(usize, pc) * self.words + reg / 64];
        return (w >> @intCast(reg % 64)) & 1 != 0;
    }

    /// The whole live-in row at `pc` (`words` words; bit `r % 64` of word
    /// `r / 64` is register `r`). Requires `available()`, `pc < code.len`.
    pub fn row(self: RegLiveness, pc: u32) []const u64 {
        std.debug.assert(self.words != 0);
        return self.bits[@as(usize, pc) * self.words ..][0..self.words];
    }
};

/// A function prototype: the immutable compiled form of one function body (the
/// main chunk is just the top-level prototype). A runtime *closure* (Increment D)
/// pairs a `Proto` with captured upvalues; the `Proto` itself is shared and
/// constant.
/// A half-open `[start, end)` byte range into the original source. Mirrors
/// `ast.Span`'s shape, redeclared here so bytecode does not depend on `ast`.
pub const Span = struct { start: u32 = 0, end: u32 = 0 };

pub const Proto = struct {
    /// Instruction stream.
    code: []const Instr,
    /// Source span per instruction, parallel to `code` (same index = same
    /// instruction). Used only on the cold paths — runtime-error location and
    /// disassembly — never in the hot dispatch loop. Defaults empty so
    /// hand-built protos (tests, IR paths) need not supply it; consumers must
    /// bounds-check `pc < spans.len` before indexing.
    spans: []const Span = &.{},
    /// Constant pool: literals too large for an immediate (big ints, all floats
    /// and strings, global names). Indexed by `load_const`/`get_global` etc.
    constants: []const Value = &.{},
    /// Number of register slots the frame needs (the compiler computes the high
    /// water mark). The interpreter reserves exactly this many.
    num_registers: u16 = 0,
    /// Declared fixed parameters (the first `num_params` registers on entry).
    num_params: u8 = 0,
    /// Whether the function accepts `...` beyond its fixed params.
    is_vararg: bool = false,
    /// Nested function prototypes, referenced by `closure` (Increment D).
    protos: []const *const Proto = &.{},
    /// Upvalue capture plan: how a `closure` of this proto fills its cells from
    /// the enclosing frame. Empty for functions that capture nothing.
    upvalues: []const UpvalDesc = &.{},
    /// Doc 56 §4.2: per-pc register liveness (see `RegLiveness`). Filled by
    /// the compiler; empty (unavailable) on hand-built protos.
    reg_live: RegLiveness = .{},
    /// Debug name for disassembly / diagnostics (not semantically meaningful).
    name: []const u8 = "?",
    /// Stable, unique id assigned at compile time (pre-order over the proto
    /// tree, root = 0). This — not the in-memory `*const Proto` address — is how
    /// a serialized trace names its anchor (`src/traceser.zig`): a pointer is
    /// meaningless on disk, so the wire form stores this id and the visualiser
    /// uses it to correlate a trace with its proto's disassembly. Defaults to 0
    /// so hand-built test protos compile; the compiler overwrites it.
    id: u32 = 0,
    /// Source text this proto was compiled from, used by the runtime-error path
    /// (`callSiteAt`/`describeFault`/`backtraceFrames`) to turn a span offset into
    /// a line number. The whole proto tree of one chunk shares one source slice.
    /// Defaults empty (hand-built protos / IR paths); the error path falls back to
    /// `vm.source` when empty. For a runtime-`load`ed chunk this points at the
    /// VM-owned source copy, so loaded code reports its *own* line numbers rather
    /// than the main chunk's. Borrows the buffer (which outlives the proto).
    source: []const u8 = "",
};

// ---------------------------------------------------------------------------
// Disassembly — invaluable for debugging the compiler and reading test output.
// Rendered to an `io.Writer` (the one churny-surface wrapper).
// ---------------------------------------------------------------------------

const io = @import("io.zig");

/// Write a single instruction in a fixed, greppable columnar form.
pub fn writeInstr(w: *io.Writer, instr: Instr) io.Writer.Error!void {
    try w.print("{s:<14}", .{@tagName(instr.op)});
    switch (instr.op) {
        .halt => {},
        .jmp => try w.print(" {d:>4}", .{instr.aux}),
        .load_nil, .new_table, .close_upvalues, .vararg_first, .vararg_len, .vararg_spread => try w.print(" r{d}", .{instr.a}),
        .load_int => try w.print(" r{d}  {d}", .{ instr.a, instr.aux }),
        .jmp_if_false, .jmp_if_true, .jmp_if_not_nil, .for_prep, .for_loop => try w.print(" r{d}  {d:>4}", .{ instr.a, instr.aux }),
        // Doc 58: the loop kind and the exit offset (a fall-through op).
        .loop => try w.print(" {s}  exit {d:>4}", .{
            if (instr.b == @intFromEnum(LoopKind.repeat_loop)) "repeat" else "while",
            instr.aux,
        }),
        .load_bool,
        .load_const,
        .move,
        .neg,
        .not,
        .bnot,
        .len,
        .get_global,
        .set_global,
        .closure,
        .get_upval,
        .set_upval,
        .ret,
        .vararg_get,
        => try w.print(" r{d}  {d}", .{ instr.a, instr.b }),
        else => try w.print(" r{d}  {d}  {d}", .{ instr.a, instr.b, instr.c }),
    }
}

/// Disassemble a whole prototype (header + numbered instructions). Returns the
/// text for inspection; useful in tests via `disassembleAlloc`.
pub fn writeProto(w: *io.Writer, proto: *const Proto) io.Writer.Error!void {
    try w.print("proto {s}  regs={d} params={d}{s}\n", .{
        proto.name,
        proto.num_registers,
        proto.num_params,
        if (proto.is_vararg) " vararg" else "",
    });
    for (proto.code, 0..) |instr, i| {
        try w.print("  {d:>4}  ", .{i});
        try writeInstr(w, instr);
        try w.writeAll("\n");
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Instr is a compact 12 bytes" {
    // Auto-layout struct (Zig may reorder fields to minimise padding); we only
    // care that it stays small. It is never serialised — tier-0 is in-memory.
    try testing.expectEqual(@as(usize, 12), @sizeOf(Instr));
}

test "instruction constructors set the right operands" {
    const a = Instr.opABC(.add, 0, 1, 2);
    try testing.expectEqual(OpCode.add, a.op);
    try testing.expectEqual(@as(u16, 0), a.a);
    try testing.expectEqual(@as(u16, 1), a.b);
    try testing.expectEqual(@as(u16, 2), a.c);

    const j = Instr.opJ(.jmp, -3);
    try testing.expectEqual(@as(i32, -3), j.aux);

    const li = Instr.opAx(.load_int, 5, 1000);
    try testing.expectEqual(@as(u16, 5), li.a);
    try testing.expectEqual(@as(i32, 1000), li.aux);
}

test "disassembly renders a small program" {
    const code = [_]Instr{
        Instr.opAx(.load_int, 0, 2),
        Instr.opAx(.load_int, 1, 3),
        Instr.opABC(.add, 0, 0, 1),
        Instr.opAB(.ret, 0, 1),
    };
    const proto = Proto{ .code = &code, .num_registers = 2, .name = "main" };

    var buf: [256]u8 = undefined;
    var w = io.Writer.fixed(&buf);
    try writeProto(&w, &proto);
    const text = w.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "proto main") != null);
    try testing.expect(std.mem.indexOf(u8, text, "load_int") != null);
    try testing.expect(std.mem.indexOf(u8, text, "add") != null);
}
