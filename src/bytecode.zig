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
/// The back-edges are exactly the three loop ops, as in LuaJIT (`FORL`,
/// `ITERL`, `LOOP`): a taken `for_loop`/`tfor_loop` (header = its backward
/// target, the body start) and a `loop` marker (header = `pc + 1`, the body
/// start). A backward `jmp`/`jmp_if_false` is only a loop's physical closer
/// (`while`'s jump back to its condition, `repeat`'s jump back to its
/// marker), never a back-edge.
pub fn loopHeaderOf(ins: Instr, pc: usize) ?u32 {
    switch (ins.op) {
        .loop => return @intCast(pc + 1),
        .for_loop, .tfor_loop => {},
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

/// Doc 58: the extent of the loop whose header is `header`, or null when
/// `header` is not a loop header. Replaces the two numeric-only
/// `forLoopEndFor` copies.
///
/// O(1), from the header side (doc 58 §4.8 — it is asked per region member on
/// every topology rebuild, so a whole-proto scan made the rebuild
/// O(members × code)). Every loop shape the compiler emits pins its own
/// back-edge from the instruction right above its header:
///  - numeric `for`: `for_prep` at `header − 1` jumps to its `for_loop`, whose
///    taken edge returns to `header` (`compileNumericFor`);
///  - generic `for`: a forward `jmp` at `header − 1` enters the test block
///    (`move`s and the iterator `call`) that ends in the `tfor_loop` returning
///    to `header` (`compileGenericFor`);
///  - `while`/`repeat`: the `loop` marker at `header − 1` (below).
/// Each link is checked, so anything else is null. That one back-edge per
/// header is unique is a property of compiler output (each loop owns its
/// header), not re-proved here by scanning for rivals.
///
/// The extent is every instruction that runs inside the loop, which for the
/// two marker kinds is NOT `[header, back_edge]` — the marker sits at the top
/// and the code that closes the loop sits below the body:
///  - numeric `for`: `[header, the for_loop]`;
///  - generic `for`: `[header, the tfor_loop]` (the forward `jmp` to the test
///    block at `header − 1` runs only on entry, like `for_prep`);
///  - `while`: `[C, E − 1]`, where `E` is the marker's exit pc and `C` is the
///    first condition instruction — the target of the backward `jmp` that
///    closes the loop at `E − 1`. The condition sits BELOW the header, so a
///    member in it has `pc < header` and is still inside the loop;
///  - `repeat`: `[the marker, E − 1]` (`E − 1` is the backward `jmp_if_false`
///    that closes it).
///
/// A structural query, not a compiler assertion: every shape is checked
/// against exactly what `compileWhile`/`compileRepeat` emit, and anything else
/// — a marker whose exit is out of range or not past it, an unknown loop
/// kind, a `while` whose condition branch does not sit right above the marker
/// and target `E`, a `repeat` whose closer does not target its marker —
/// returns null instead of trapping (doc 58 B2 review should-fix).
pub fn loopExtentFor(proto: *const Proto, header: u32) ?LoopExtent {
    const code = proto.code;
    if (header == 0 or header >= code.len) return null;
    const i: u32 = header - 1;
    const entry = code[i];
    switch (entry.op) {
        .for_prep => {
            const fl = jumpTargetOf(entry, i);
            if (fl <= i or fl >= @as(i64, @intCast(code.len))) return null;
            const back: u32 = @intCast(fl);
            if (code[back].op != .for_loop or loopHeaderOf(code[back], back) != header) return null;
            return .{ .start = header, .end = back, .back_edge_pc = back, .back_edge_op = .for_loop };
        },
        .jmp => {
            const t = jumpTargetOf(entry, i);
            if (t <= i or t >= @as(i64, @intCast(code.len))) return null;
            var back: usize = @intCast(t);
            while (back < code.len) : (back += 1) switch (code[back].op) {
                .move, .call => {},
                else => break,
            };
            if (back >= code.len or code[back].op != .tfor_loop or loopHeaderOf(code[back], back) != header) return null;
            return .{ .start = header, .end = @intCast(back), .back_edge_pc = @intCast(back), .back_edge_op = .tfor_loop };
        },
        .loop => {
            const exit = loopMarkerExitChecked(entry, i, code.len) orelse return null;
            const end = exit - 1;
            if (end <= i) return null; // the closer must sit past the marker
            const closer = code[end];
            const kind = std.enums.fromInt(LoopKind, entry.b) orelse return null;
            const start: u32 = switch (kind) {
                // `C … jmp_if_false → E; loop; body; jmp → C`: the condition
                // branch sits right above the marker and leaves to `E`, and the
                // closer at `E − 1` jumps back to `C`.
                .while_loop => blk: {
                    if (i == 0) return null;
                    const branch = code[i - 1];
                    if (branch.op != .jmp_if_false) return null;
                    if (jumpTargetOf(branch, i - 1) != @as(i64, exit)) return null;
                    if (closer.op != .jmp) return null;
                    const c = jumpTargetOf(closer, end);
                    if (c < 0 or c > @as(i64, i - 1)) return null;
                    break :blk @intCast(c);
                },
                // `loop; body; cond; jmp_if_false → loop`: the closer at `E − 1`
                // jumps back to the marker, which opens the loop.
                .repeat_loop => blk: {
                    if (closer.op != .jmp_if_false) return null;
                    if (jumpTargetOf(closer, end) != @as(i64, i)) return null;
                    break :blk i;
                },
            };
            return .{ .start = start, .end = end, .back_edge_pc = i, .back_edge_op = .loop };
        },
        else => return null,
    }
}

/// Doc 58 §4.8: the GATE of the loop whose header is `header` — the one
/// instruction every entry into its body passes through, first entry and
/// repetition alike — or null when the loop's shape is not recognised (fail
/// closed). For a `while`/`repeat` loop it is the `loop` marker at
/// `header − 1`. For a numeric or generic `for` it is the back-edge op
/// (`for_loop`/`tfor_loop`): `for_prep` never falls through into the body but
/// jumps to the `for_loop`, which performs the first test, and a generic
/// `for` enters through the iterator call block that ends at its
/// `tfor_loop`. The header itself is NOT a gate: a zero-trip loop reaches the
/// code after it without passing the header.
pub fn loopGateOf(proto: *const Proto, header: u32) ?u32 {
    const ext = loopExtentFor(proto, header) orelse return null;
    return switch (ext.back_edge_op) {
        .loop, .for_loop, .tfor_loop => ext.back_edge_pc,
        else => null,
    };
}

/// `pc + 1 + aux` for a jump-shaped instruction, unchecked (may be out of
/// range — callers compare it against a known pc).
fn jumpTargetOf(ins: Instr, pc: usize) i64 {
    return @as(i64, @intCast(pc)) + 1 + ins.aux;
}

/// Doc 58 §4.2: the compiler's own check that the only backward jumps it emits
/// are the two loop closers, each in its pinned shape. Every other backward
/// jump would be an untracked back-edge now that `loopHeaderOf` recognises
/// only the three loop ops. Debug/safe builds only; called once per finished
/// proto.
pub fn assertLoopClosersWellFormed(code: []const Instr) void {
    if (!std.debug.runtime_safety) return;
    for (code, 0..) |ins, pc| {
        const t: i64 = switch (ins.op) {
            .jmp, .jmp_if_true, .jmp_if_false, .jmp_if_not_nil => @as(i64, @intCast(pc)) + 1 + ins.aux,
            else => continue,
        };
        if (t > @as(i64, @intCast(pc))) continue; // forward: not a closer
        const target: usize = @intCast(t);
        switch (ins.op) {
            // `while`: a backward `jmp` at `E − 1` targets the condition `C`,
            // and the loop's marker `m` sits between them with `code[m − 1]`
            // the condition's branch: `C ≤ m − 1 < m < E`. The marker is
            // identified by its extent ENDING at this closer (`E == pc + 1`),
            // not by being the nearest one — an inner loop's marker also lies
            // in `(C, pc)`.
            .jmp => {
                var m: usize = target + 1;
                const found = while (m <= pc) : (m += 1) {
                    if (code[m].op == .loop and loopMarkerExit(code[m], m) == pc + 1) break true;
                } else false;
                std.debug.assert(found);
                std.debug.assert(@as(LoopKind, @enumFromInt(code[m].b)) == .while_loop);
                std.debug.assert(m > target); // `C ≤ m − 1`
                std.debug.assert(code[m - 1].op == .jmp_if_false);
            },
            // `repeat`: a backward `jmp_if_false` targets its `loop` marker.
            .jmp_if_false => {
                std.debug.assert(code[target].op == .loop);
                std.debug.assert(@as(LoopKind, @enumFromInt(code[target].b)) == .repeat_loop);
                std.debug.assert(loopMarkerExit(code[target], target) == pc + 1);
            },
            else => unreachable, // no other backward jump shape exists
        }
    }
}

/// Doc 58: is `header` the header of a `while` loop — i.e. does a `loop` marker
/// of kind `while` sit right above it? (`repeat` markers and `for` back-edges
/// answer false.) The peel's shape gate and tests share this one definition.
pub fn isWhileHeader(proto: *const Proto, header: u32) bool {
    // The header is a real instruction (the body start), so `code.len` is
    // out of range like anything past it.
    if (header == 0 or header >= proto.code.len) return false;
    const above = proto.code[header - 1];
    if (above.op != .loop) return false;
    return std.enums.fromInt(LoopKind, above.b) == .while_loop;
}

/// Doc 58: the exit pc (first instruction after the loop) of a `loop` marker
/// at `pc`, checked: null unless the exit lies past the marker and within
/// `code_len` (the exit may equal `code_len` — a loop ending the code). The
/// structural queries use this; trusted compiler-output callers may use the
/// asserting `loopMarkerExit`.
pub fn loopMarkerExitChecked(ins: Instr, pc: usize, code_len: usize) ?u32 {
    if (ins.op != .loop) return null;
    const e = jumpTargetOf(ins, pc);
    if (e <= @as(i64, @intCast(pc)) or e > @as(i64, @intCast(code_len))) return null;
    return @intCast(e);
}

/// Doc 58: the exit pc (first instruction after the loop) of a `loop` marker
/// at `pc`, for compiler output (asserts the shape).
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

/// Doc 58 §4.8: the dominator tree of one proto's CFG, rooted at pc 0,
/// computed once at compile time by `bc_dom.compute` and stored as each pc's
/// DFS interval in the tree, so `dominates(a, b)` is O(1) interval
/// containment. A pc unreachable from pc 0 is `none` in both arrays and
/// dominates nothing / is dominated by nothing. Empty (`!available()`) on a
/// hand-built proto or one over the size limit: callers then have no
/// dominance facts and must fail closed.
pub const DomTree = struct {
    pre: []const u32 = &.{},
    post: []const u32 = &.{},

    pub const none = std.math.maxInt(u32);

    pub fn available(self: DomTree) bool {
        return self.pre.len != 0;
    }

    /// Is `pc` reachable from pc 0? False when no tree is available.
    pub fn reachable(self: DomTree, pc: u32) bool {
        return pc < self.pre.len and self.pre[pc] != none;
    }

    /// Does every path from pc 0 to `b` pass through `a`? Reflexive. False
    /// when no tree is available, or either pc is out of range or unreachable.
    pub fn dominates(self: DomTree, a: u32, b: u32) bool {
        if (!self.reachable(a) or !self.reachable(b)) return false;
        return self.pre[a] <= self.pre[b] and self.post[b] <= self.post[a];
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
    /// Global-access cache: one hash-slot hint per constant, used by
    /// `get_global`/`set_global` for the global named by `constants[i]`
    /// (`Table.getHinted`). A hint only: every use re-checks it, so it never
    /// changes a result, and it is never serialized. Mutable through a
    /// `*const Proto` (the slice's elements are). Allocated zeroed by the
    /// compiler; empty on hand-built protos, whose global accesses then take
    /// the plain lookup. Every VM running this proto reads and writes these
    /// words, so running one proto on two threads at once is a data race even
    /// when each VM is used by one thread only. The embedding API shares
    /// nothing between VMs (doc 59), so that can't happen today (doc 62 §4.4).
    global_slot_hints: []u32 = &.{},
    /// Doc 56 §4.2: per-pc register liveness (see `RegLiveness`). Filled by
    /// the compiler; empty (unavailable) on hand-built protos.
    reg_live: RegLiveness = .{},
    /// Doc 61 §5: `reg_live` is available AND the code passes the call-layout
    /// check (`bc_liveness.maskable`). The one predicate the GC root walk and
    /// every JIT store-elision site read: a frame of a non-maskable proto is
    /// scanned whole, and its traces keep every store. Filled by the compiler;
    /// false on hand-built protos.
    maskable: bool = false,
    /// Doc 58 §4.8: the CFG's dominator tree (see `DomTree`). Filled by the
    /// compiler; empty (unavailable) on hand-built protos.
    dom: DomTree = .{},
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

fn marker(kind: u16, aux: i32) Instr {
    return .{ .op = .loop, .b = kind, .aux = aux };
}

test "doc 58 §4.8: loopExtentFor and loopGateOf on every compiler loop shape" {
    const w: u16 = @intFromEnum(LoopKind.while_loop);
    const r: u16 = @intFromEnum(LoopKind.repeat_loop);
    // `while`: C=0; jmp_if_false → E=5; loop; body (header 3); jmp → C.
    const while_code = [_]Instr{
        Instr.opA(.load_bool, 0),     Instr.opAx(.jmp_if_false, 0, 3), marker(w, 2),
        Instr.opAx(.load_int, 1, 0), Instr.opAx(.jmp, 0, -5),          Instr.op0(.ret),
    };
    const wp = Proto{ .code = &while_code };
    try testing.expectEqual(LoopExtent{ .start = 0, .end = 4, .back_edge_pc = 2, .back_edge_op = .loop }, loopExtentFor(&wp, 3).?);
    try testing.expectEqual(@as(?u32, 2), loopGateOf(&wp, 3));
    try testing.expect(isWhileHeader(&wp, 3));
    // `repeat`: loop (exit 4); body (header 1); cond; jmp_if_false → marker.
    const repeat_code = [_]Instr{
        marker(r, 3),                Instr.opAx(.load_int, 1, 0),
        Instr.opA(.load_bool, 0),    Instr.opAx(.jmp_if_false, 0, -4),
        Instr.op0(.ret),
    };
    const rp = Proto{ .code = &repeat_code };
    try testing.expectEqual(LoopExtent{ .start = 0, .end = 3, .back_edge_pc = 0, .back_edge_op = .loop }, loopExtentFor(&rp, 1).?);
    try testing.expectEqual(@as(?u32, 0), loopGateOf(&rp, 1));
    // Numeric `for`: for_prep → for_loop; body (header 1); for_loop → header.
    const for_code = [_]Instr{ Instr.opAx(.for_prep, 0, 1), Instr.opAx(.load_int, 4, 0), Instr.opAx(.for_loop, 0, -2), Instr.op0(.ret) };
    const fp = Proto{ .code = &for_code };
    try testing.expectEqual(LoopExtent{ .start = 1, .end = 2, .back_edge_pc = 2, .back_edge_op = .for_loop }, loopExtentFor(&fp, 1).?);
    try testing.expectEqual(@as(?u32, 2), loopGateOf(&fp, 1));
    // Generic `for`: jmp → test block; body (header 1); move×3; call; tfor_loop → header.
    const gen_code = [_]Instr{
        Instr.opAx(.jmp, 0, 1),      Instr.opAx(.load_int, 6, 0),
        Instr.opAB(.move, 3, 0),     Instr.opAB(.move, 4, 1),
        Instr.opAB(.move, 5, 2),     Instr.opABC(.call, 3, 2, 1),
        Instr.opAx(.tfor_loop, 0, -6), Instr.op0(.ret),
    };
    const gp = Proto{ .code = &gen_code };
    try testing.expectEqual(LoopExtent{ .start = 1, .end = 6, .back_edge_pc = 6, .back_edge_op = .tfor_loop }, loopExtentFor(&gp, 1).?);
    try testing.expectEqual(@as(?u32, 6), loopGateOf(&gp, 1));
    // A pc that is not a header (inside a body, past the end) has no loop.
    try testing.expectEqual(@as(?LoopExtent, null), loopExtentFor(&wp, 4));
    try testing.expectEqual(@as(?LoopExtent, null), loopExtentFor(&fp, 3));
    try testing.expectEqual(@as(?LoopExtent, null), loopExtentFor(&fp, 0));
    try testing.expectEqual(@as(?LoopExtent, null), loopExtentFor(&gp, 3));
}

test "doc 58 B2 review: loopExtentFor fails closed on malformed loop shapes instead of trapping" {
    const w: u16 = @intFromEnum(LoopKind.while_loop);
    const r: u16 = @intFromEnum(LoopKind.repeat_loop);
    const Case = struct { code: []const Instr, header: u32 };
    const cases = [_]Case{
        // A marker whose exit lies behind it.
        .{ .code = &.{ marker(r, -3), Instr.op0(.ret) }, .header = 1 },
        // A marker whose exit lies past the code.
        .{ .code = &.{ marker(r, 40), Instr.op0(.ret) }, .header = 1 },
        // A `repeat` marker whose exit is the next pc: no closer past it.
        .{ .code = &.{ marker(r, 0), Instr.op0(.ret) }, .header = 1 },
        // An unknown loop kind.
        .{ .code = &.{ marker(9, 1), Instr.opA(.load_bool, 0), Instr.op0(.ret) }, .header = 1 },
        // A `while` whose condition branch leaves to the wrong pc.
        .{ .code = &.{ Instr.opA(.load_bool, 0), Instr.opAx(.jmp_if_false, 0, 2), marker(w, 2), Instr.opAx(.load_int, 1, 0), Instr.opAx(.jmp, 0, -5), Instr.op0(.ret) }, .header = 3 },
        // A `while` marker with no condition branch above it.
        .{ .code = &.{ Instr.opA(.load_bool, 0), Instr.opA(.load_bool, 0), marker(w, 2), Instr.opAx(.load_int, 1, 0), Instr.opAx(.jmp, 0, -5), Instr.op0(.ret) }, .header = 3 },
        // A `while` marker at pc 0 (nothing above it).
        .{ .code = &.{ marker(w, 2), Instr.opAx(.load_int, 1, 0), Instr.opAx(.jmp, 0, -3), Instr.op0(.ret) }, .header = 1 },
        // A `repeat` whose closer does not jump back to its marker.
        .{ .code = &.{ marker(r, 3), Instr.opAx(.load_int, 1, 0), Instr.opA(.load_bool, 0), Instr.opAx(.jmp_if_false, 0, -3), Instr.op0(.ret) }, .header = 1 },
        // A `for_prep` that jumps to something other than a `for_loop`.
        .{ .code = &.{ Instr.opAx(.for_prep, 0, 1), Instr.opAx(.load_int, 4, 0), Instr.opAx(.load_int, 4, 0), Instr.op0(.ret) }, .header = 1 },
        // A `for_prep` jumping out of the code.
        .{ .code = &.{ Instr.opAx(.for_prep, 0, 99), Instr.op0(.ret) }, .header = 1 },
        // A forward `jmp` that does not enter a generic-`for` test block.
        .{ .code = &.{ Instr.opAx(.jmp, 0, 1), Instr.opAx(.load_int, 6, 0), Instr.opAx(.load_int, 6, 0), Instr.op0(.ret) }, .header = 1 },
    };
    for (cases) |cs| {
        const p = Proto{ .code = cs.code };
        try testing.expectEqual(@as(?LoopExtent, null), loopExtentFor(&p, cs.header));
        try testing.expectEqual(@as(?u32, null), loopGateOf(&p, cs.header));
    }
    // An unknown kind is not a `while` either (checked decode, not a trap).
    const unknown = [_]Instr{ marker(9, 1), Instr.opA(.load_bool, 0), Instr.op0(.ret) };
    try testing.expect(!isWhileHeader(&Proto{ .code = &unknown }, 1));
    // A marker as the last instruction: its "header" is `code.len`, not a pc.
    const tail = [_]Instr{ Instr.opA(.load_bool, 0), Instr.opAx(.jmp_if_false, 0, 1), marker(w, 0) };
    const tp = Proto{ .code = &tail };
    try testing.expect(!isWhileHeader(&tp, 3));
    try testing.expectEqual(@as(?LoopExtent, null), loopExtentFor(&tp, 3));
}
