//! A tiny hand-rolled x86-64 (System V AMD64) machine-code encoder.
//!
//! This is the assembler half of tier-1b native codegen (`nativegen.zig` is the
//! IR-lowering half). It emits *exactly* the instruction forms the integer-trace
//! compiler needs — no more — into a growable byte buffer, with a forward-reference
//! label/fixup table for the loop back-edge and the side-exit jumps.
//!
//! ## Why our own, and why so small
//!
//! A tracing JIT pays compile latency at *runtime*, so an LLVM/Cranelift backend is
//! the wrong tool (slow, opaque). We own the whole pipeline already (lexer →
//! bytecode → tracer → optimizer → IR-interpreter), so the last tier is ours too.
//! The supported form set is deliberately minimal — every byte sequence here is
//! pinned by a golden-byte test (`test "enc: …"`), because a single wrong ModRM bit
//! is an invisible miscompile, not a crash.
//!
//! ## Conventions
//!
//! * All integer ALU/`mov` forms are 64-bit (REX.W = 1), so a REX prefix is always
//!   present on them; the 8-bit guard/`setcc` forms emit REX only when a high
//!   register (r8–r15) forces it.
//! * Memory operands are `[base + disp32]` only (the trace's spill frame and the
//!   `regs` array — no index/scale needed). `rsp`/`r12` bases get the mandatory SIB
//!   byte; `rbp`/`r13` bases get a forced disp8 (their mod=00 slot is RIP-relative).
//! * `reg` in the ModRM is the *register* operand, `rm` is the register-or-memory
//!   operand, exactly as the Intel `/r` notation reads.
//!
//! Reference: Intel SDM Vol. 2 (opcode maps) — every encoding below is cross-checked
//! against it in the tests.

const std = @import("std");

/// The 16 general-purpose 64-bit registers, numbered by their architectural index
/// (the value that feeds ModRM.rm / .reg and the REX extension bit). `r8`–`r15`
/// have index ≥ 8, which sets the relevant REX bit.
pub const Reg = enum(u4) {
    rax = 0,
    rcx = 1,
    rdx = 2,
    rbx = 3,
    rsp = 4,
    rbp = 5,
    rsi = 6,
    rdi = 7,
    r8 = 8,
    r9 = 9,
    r10 = 10,
    r11 = 11,
    r12 = 12,
    r13 = 13,
    r14 = 14,
    r15 = 15,

    /// Low 3 bits — the ModRM.rm / .reg / opcode-embedded field.
    fn lo(self: Reg) u3 {
        return @truncate(@intFromEnum(self));
    }
    /// High bit — the REX.R / .B / .X extension for r8–r15.
    fn hi(self: Reg) bool {
        return @intFromEnum(self) >= 8;
    }
};

/// Condition codes — the low nibble shared by `setcc` (0x90|cc) and the near
/// `jcc` (0x0F 0x80|cc). Only the codes the trace compiler emits are listed.
pub const Cond = enum(u8) {
    e = 0x4, // ZF=1            — equal / zero
    ne = 0x5, // ZF=0           — not-equal / not-zero
    l = 0xC, // SF≠OF          — signed <
    ge = 0xD, // SF=OF          — signed ≥
    le = 0xE, // ZF=1 or SF≠OF  — signed ≤
    g = 0xF, // ZF=0 and SF=OF — signed >
};

/// A forward- or backward-reference target. Created unbound (`label`), positioned
/// later (`bind`); every `jmp`/`jcc` to it records a fixup that `resolve` patches.
pub const Label = struct { id: u32 };

const Fixup = struct {
    /// Byte offset of the rel32 immediate (the 4 bytes to overwrite).
    at: usize,
    label: u32,
};

/// The growable code buffer + label machinery. Drive it with the typed `emit*`
/// methods, `bind` labels, then `resolve` once before reading `code.items`.
pub const Assembler = struct {
    gpa: std.mem.Allocator,
    code: std.ArrayListUnmanaged(u8) = .empty,
    /// Bound target offsets, indexed by `Label.id`; `null` until `bind`.
    labels: std.ArrayListUnmanaged(?usize) = .empty,
    fixups: std.ArrayListUnmanaged(Fixup) = .empty,

    pub fn init(gpa: std.mem.Allocator) Assembler {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Assembler) void {
        self.code.deinit(self.gpa);
        self.labels.deinit(self.gpa);
        self.fixups.deinit(self.gpa);
        self.* = undefined;
    }

    // ---- low-level byte emission ------------------------------------------------

    fn b(self: *Assembler, byte: u8) !void {
        try self.code.append(self.gpa, byte);
    }

    fn imm32(self: *Assembler, v: i32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(i32, &buf, v, .little);
        try self.code.appendSlice(self.gpa, &buf);
    }

    fn imm64(self: *Assembler, v: i64) !void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(i64, &buf, v, .little);
        try self.code.appendSlice(self.gpa, &buf);
    }

    /// Emit a REX prefix. `w` = 64-bit operand; `r`/`x`/`bb` extend ModRM.reg /
    /// SIB.index / ModRM.rm respectively. Always emitted when any bit is set; pass
    /// `force` for 8-bit forms that must have REX to reach spl/bpl/sil/dil (we don't,
    /// but the parameter keeps the intent explicit).
    fn rex(self: *Assembler, w: bool, r: bool, x: bool, bb: bool) !void {
        const byte: u8 = 0x40 |
            (@as(u8, @intFromBool(w)) << 3) |
            (@as(u8, @intFromBool(r)) << 2) |
            (@as(u8, @intFromBool(x)) << 1) |
            @as(u8, @intFromBool(bb));
        if (byte != 0x40) try self.b(byte);
    }

    /// ModRM for a register-direct operand (mod = 11).
    fn modrmReg(self: *Assembler, reg: u3, rm: u3) !void {
        try self.b(0xC0 | (@as(u8, reg) << 3) | @as(u8, rm));
    }

    /// ModRM (+ SIB + displacement) for a `[base + disp]` memory operand. `reg` is
    /// the opcode's register field (a real register's low 3 bits, or a `/n`
    /// extension digit).
    fn modrmMem(self: *Assembler, reg: u3, base: Reg, disp: i32) !void {
        const base_lo = base.lo();
        // mod: 00 = no disp (illegal for base rbp/r13 → forced to disp8 0);
        //      01 = disp8; 10 = disp32.
        const mod: u2 = if (disp == 0 and base_lo != 5)
            0b00
        else if (disp >= -128 and disp <= 127)
            0b01
        else
            0b10;
        // rm = 100 means "SIB byte follows"; rsp(4)/r12(12) always need it.
        const need_sib = base_lo == 4;
        const rm: u3 = if (need_sib) 0b100 else base_lo;
        try self.b((@as(u8, mod) << 6) | (@as(u8, reg) << 3) | @as(u8, rm));
        if (need_sib) {
            // scale=00, index=100 (none), base=base_lo. REX.B already extends base.
            try self.b((0b00 << 6) | (0b100 << 3) | @as(u8, base_lo));
        }
        switch (mod) {
            0b00 => {},
            0b01 => try self.b(@bitCast(@as(i8, @intCast(disp)))),
            0b10 => try self.imm32(disp),
            else => unreachable,
        }
    }

    // ---- mov --------------------------------------------------------------------

    /// `mov reg, imm64` — REX.W + B8+rd + imm64 (always the full 10-byte form, so a
    /// negative i64 constant is exact).
    pub fn movRegImm64(self: *Assembler, reg: Reg, v: i64) !void {
        try self.rex(true, false, false, reg.hi());
        try self.b(0xB8 + @as(u8, reg.lo()));
        try self.imm64(v);
    }

    /// `mov dst, src` — 89 /r (MOV r/m64, r64): reg = src, rm = dst.
    pub fn movRegReg(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.rex(true, src.hi(), false, dst.hi());
        try self.b(0x89);
        try self.modrmReg(src.lo(), dst.lo());
    }

    /// `mov dst, [base + disp]` — 8B /r (MOV r64, r/m64): reg = dst, rm = mem.
    pub fn movRegMem(self: *Assembler, dst: Reg, base: Reg, disp: i32) !void {
        try self.rex(true, dst.hi(), false, base.hi());
        try self.b(0x8B);
        try self.modrmMem(dst.lo(), base, disp);
    }

    /// `mov [base + disp], src` — 89 /r (MOV r/m64, r64): reg = src, rm = mem.
    pub fn movMemReg(self: *Assembler, base: Reg, disp: i32, src: Reg) !void {
        try self.rex(true, src.hi(), false, base.hi());
        try self.b(0x89);
        try self.modrmMem(src.lo(), base, disp);
    }

    /// `mov qword [base + disp], imm32` — C7 /0 id (sign-extended). Used to write a
    /// small boxed tag (1/2) into a `Value`'s tag word, zeroing the padding too.
    pub fn movMemImm32(self: *Assembler, base: Reg, disp: i32, v: i32) !void {
        try self.rex(true, false, false, base.hi());
        try self.b(0xC7);
        try self.modrmMem(0, base, disp);
        try self.imm32(v);
    }

    /// `movzx dst, src8` — REX.W 0F B6 /r: zero-extend the low byte of `src` into
    /// the full 64-bit `dst` (the mandatory follow-up to `setcc`).
    pub fn movzxRegReg8(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.rex(true, dst.hi(), false, src.hi());
        try self.b(0x0F);
        try self.b(0xB6);
        try self.modrmReg(dst.lo(), src.lo());
    }

    // ---- integer ALU (reg, reg) -------------------------------------------------

    fn aluRegReg(self: *Assembler, opcode: u8, dst: Reg, src: Reg) !void {
        // `op r/m64, r64`: reg = src, rm = dst → dst = dst op src.
        try self.rex(true, src.hi(), false, dst.hi());
        try self.b(opcode);
        try self.modrmReg(src.lo(), dst.lo());
    }

    pub fn addRegReg(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.aluRegReg(0x01, dst, src);
    }
    pub fn subRegReg(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.aluRegReg(0x29, dst, src);
    }
    pub fn andRegReg(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.aluRegReg(0x21, dst, src);
    }
    pub fn orRegReg(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.aluRegReg(0x09, dst, src);
    }
    pub fn xorRegReg(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.aluRegReg(0x31, dst, src);
    }
    /// `cmp dst, src` — 39 /r: sets flags from `dst - src` (operands unchanged).
    pub fn cmpRegReg(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.aluRegReg(0x39, dst, src);
    }

    /// `imul dst, src` — REX.W 0F AF /r: reg = dst, rm = src → dst *= src. The low
    /// 64 bits are exact two's-complement wrap (matches arith.zig `*%`).
    pub fn imulRegReg(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.rex(true, dst.hi(), false, src.hi());
        try self.b(0x0F);
        try self.b(0xAF);
        try self.modrmReg(dst.lo(), src.lo());
    }

    // ---- integer ALU (reg, mem) / (mem, reg) ------------------------------------

    /// `op dst, [base + disp]` — the **load form** `op r64, r/m64`: reg = dst,
    /// rm = mem → dst = dst op [mem]. `opcode` is the load-direction opcode (add 03,
    /// sub 2B, and 23, or 0B, xor 33, cmp 3B — the reg-reg opcode | 0x02).
    fn aluRegMem(self: *Assembler, opcode: u8, dst: Reg, base: Reg, disp: i32) !void {
        try self.rex(true, dst.hi(), false, base.hi());
        try self.b(opcode);
        try self.modrmMem(dst.lo(), base, disp);
    }

    pub fn addRegMem(self: *Assembler, dst: Reg, base: Reg, disp: i32) !void {
        try self.aluRegMem(0x03, dst, base, disp);
    }
    pub fn subRegMem(self: *Assembler, dst: Reg, base: Reg, disp: i32) !void {
        try self.aluRegMem(0x2B, dst, base, disp);
    }
    pub fn andRegMem(self: *Assembler, dst: Reg, base: Reg, disp: i32) !void {
        try self.aluRegMem(0x23, dst, base, disp);
    }
    pub fn orRegMem(self: *Assembler, dst: Reg, base: Reg, disp: i32) !void {
        try self.aluRegMem(0x0B, dst, base, disp);
    }
    pub fn xorRegMem(self: *Assembler, dst: Reg, base: Reg, disp: i32) !void {
        try self.aluRegMem(0x33, dst, base, disp);
    }
    /// `cmp dst, [base + disp]` — 3B /r: flags from `dst - [mem]` (operands kept).
    pub fn cmpRegMem(self: *Assembler, dst: Reg, base: Reg, disp: i32) !void {
        try self.aluRegMem(0x3B, dst, base, disp);
    }

    /// `imul dst, [base + disp]` — REX.W 0F AF /r with rm = mem → dst *= [mem]. imul
    /// has only this load form (no `imul [mem], reg`).
    pub fn imulRegMem(self: *Assembler, dst: Reg, base: Reg, disp: i32) !void {
        try self.rex(true, dst.hi(), false, base.hi());
        try self.b(0x0F);
        try self.b(0xAF);
        try self.modrmMem(dst.lo(), base, disp);
    }

    /// `op [base + disp], src` — the **store form** `op r/m64, r64`: reg = src,
    /// rm = mem → [mem] = [mem] op src. `opcode` is the same reg-reg opcode
    /// `aluRegReg` uses (add 01, sub 29, and 21, or 09, xor 31). Used for an
    /// in-place update of a *spilled* home. (No imul store form exists.)
    fn aluMemReg(self: *Assembler, opcode: u8, base: Reg, disp: i32, src: Reg) !void {
        try self.rex(true, src.hi(), false, base.hi());
        try self.b(opcode);
        try self.modrmMem(src.lo(), base, disp);
    }

    pub fn addMemReg(self: *Assembler, base: Reg, disp: i32, src: Reg) !void {
        try self.aluMemReg(0x01, base, disp, src);
    }
    pub fn subMemReg(self: *Assembler, base: Reg, disp: i32, src: Reg) !void {
        try self.aluMemReg(0x29, base, disp, src);
    }
    pub fn andMemReg(self: *Assembler, base: Reg, disp: i32, src: Reg) !void {
        try self.aluMemReg(0x21, base, disp, src);
    }
    pub fn orMemReg(self: *Assembler, base: Reg, disp: i32, src: Reg) !void {
        try self.aluMemReg(0x09, base, disp, src);
    }
    pub fn xorMemReg(self: *Assembler, base: Reg, disp: i32, src: Reg) !void {
        try self.aluMemReg(0x31, base, disp, src);
    }

    /// `neg reg` — REX.W F7 /3 (0 -% reg, wrapping; matches arith.neg).
    pub fn negReg(self: *Assembler, reg: Reg) !void {
        try self.rex(true, false, false, reg.hi());
        try self.b(0xF7);
        try self.modrmReg(3, reg.lo());
    }
    /// `not reg` — REX.W F7 /2 (bitwise complement; matches arith.bnot).
    pub fn notReg(self: *Assembler, reg: Reg) !void {
        try self.rex(true, false, false, reg.hi());
        try self.b(0xF7);
        try self.modrmReg(2, reg.lo());
    }
    /// `inc reg` — REX.W FF /0.
    pub fn incReg(self: *Assembler, reg: Reg) !void {
        try self.rex(true, false, false, reg.hi());
        try self.b(0xFF);
        try self.modrmReg(0, reg.lo());
    }

    // ---- ALU (reg / mem, imm) ---------------------------------------------------

    /// `add reg, imm32` — REX.W 81 /0 id.
    pub fn addRegImm32(self: *Assembler, reg: Reg, v: i32) !void {
        try self.rex(true, false, false, reg.hi());
        try self.b(0x81);
        try self.modrmReg(0, reg.lo());
        try self.imm32(v);
    }
    /// `sub reg, imm32` — REX.W 81 /5 id.
    pub fn subRegImm32(self: *Assembler, reg: Reg, v: i32) !void {
        try self.rex(true, false, false, reg.hi());
        try self.b(0x81);
        try self.modrmReg(5, reg.lo());
        try self.imm32(v);
    }

    /// `cmp reg, imm32` — REX.W 81 /7 id (imm sign-extended to 64).
    pub fn cmpRegImm32(self: *Assembler, reg: Reg, v: i32) !void {
        try self.rex(true, false, false, reg.hi());
        try self.b(0x81);
        try self.modrmReg(7, reg.lo());
        try self.imm32(v);
    }

    /// `cmp byte [base + disp], imm8` — 80 /7 ib (8-bit; REX only if base ≥ r8).
    /// The guard_int tag check: `cmp byte [rdi + slot*16], Tag.int`.
    pub fn cmpByteMemImm(self: *Assembler, base: Reg, disp: i32, v: u8) !void {
        try self.rex(false, false, false, base.hi());
        try self.b(0x80);
        try self.modrmMem(7, base, disp);
        try self.b(v);
    }

    /// `cmp qword [base + disp], imm8` — REX.W 83 /7 ib (imm sign-extended). The
    /// bool-guard test: `cmp qword [spill], 0`.
    pub fn cmpQwordMemImm8(self: *Assembler, base: Reg, disp: i32, v: i8) !void {
        try self.rex(true, false, false, base.hi());
        try self.b(0x83);
        try self.modrmMem(7, base, disp);
        try self.b(@bitCast(v));
    }

    /// `setcc reg8` — 0F 90|cc /0 (writes only the low byte; caller must `movzx`).
    pub fn setcc(self: *Assembler, cc: Cond, reg: Reg) !void {
        try self.rex(false, false, false, reg.hi());
        try self.b(0x0F);
        try self.b(0x90 | @intFromEnum(cc));
        try self.modrmReg(0, reg.lo());
    }

    // ---- stack / control flow ---------------------------------------------------

    /// `push reg` — 50+rd (REX.B if reg ≥ r8; no REX.W).
    pub fn push(self: *Assembler, reg: Reg) !void {
        try self.rex(false, false, false, reg.hi());
        try self.b(0x50 + @as(u8, reg.lo()));
    }
    /// `pop reg` — 58+rd.
    pub fn pop(self: *Assembler, reg: Reg) !void {
        try self.rex(false, false, false, reg.hi());
        try self.b(0x58 + @as(u8, reg.lo()));
    }
    /// `ret` — C3.
    pub fn ret(self: *Assembler) !void {
        try self.b(0xC3);
    }

    // ---- labels & jumps ---------------------------------------------------------

    /// Allocate an unbound label.
    pub fn label(self: *Assembler) !Label {
        const id: u32 = @intCast(self.labels.items.len);
        try self.labels.append(self.gpa, null);
        return .{ .id = id };
    }

    /// Fix a label's target to the current code position.
    pub fn bind(self: *Assembler, l: Label) void {
        self.labels.items[l.id] = self.code.items.len;
    }

    fn recordFixup(self: *Assembler, l: Label) !void {
        try self.fixups.append(self.gpa, .{ .at = self.code.items.len, .label = l.id });
        try self.imm32(0); // rel32 placeholder, patched in resolve()
    }

    /// `jmp rel32` — E9 cd (to a label).
    pub fn jmp(self: *Assembler, l: Label) !void {
        try self.b(0xE9);
        try self.recordFixup(l);
    }

    /// `jcc rel32` — 0F 80|cc cd (near; rel32 so any in-trace distance is reachable).
    pub fn jcc(self: *Assembler, cc: Cond, l: Label) !void {
        try self.b(0x0F);
        try self.b(0x80 | @intFromEnum(cc));
        try self.recordFixup(l);
    }

    /// Patch every recorded jump with its bound label's relative offset. Call once,
    /// after all code is emitted and all labels bound, before reading `code.items`.
    pub fn resolve(self: *Assembler) void {
        for (self.fixups.items) |f| {
            const target = self.labels.items[f.label].?; // bound or it's a bug
            const rel: i64 = @as(i64, @intCast(target)) - @as(i64, @intCast(f.at + 4));
            std.debug.assert(rel >= std.math.minInt(i32) and rel <= std.math.maxInt(i32));
            std.mem.writeInt(i32, self.code.items[f.at..][0..4], @intCast(rel), .little);
        }
    }
};

// ---------------------------------------------------------------------------
// Golden-byte tests — every supported form pinned against the Intel SDM.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectEnc(expected: []const u8, build_fn: anytype) !void {
    var a = Assembler.init(testing.allocator);
    defer a.deinit();
    try build_fn(&a);
    a.resolve();
    try testing.expectEqualSlices(u8, expected, a.code.items);
}

test "enc: mov reg, imm64" {
    try expectEnc(&.{ 0x48, 0xB8, 0x01, 0, 0, 0, 0, 0, 0, 0 }, struct {
        fn f(a: *Assembler) !void {
            try a.movRegImm64(.rax, 1);
        }
    }.f);
    // r8 sets REX.B; negative imm is exact two's-complement.
    try expectEnc(&.{ 0x49, 0xB8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }, struct {
        fn f(a: *Assembler) !void {
            try a.movRegImm64(.r8, -1);
        }
    }.f);
}

test "enc: mov reg, reg" {
    try expectEnc(&.{ 0x48, 0x89, 0xC8 }, struct { // mov rax, rcx
        fn f(a: *Assembler) !void {
            try a.movRegReg(.rax, .rcx);
        }
    }.f);
    try expectEnc(&.{ 0x48, 0x89, 0xF8 }, struct { // mov rax, rdi
        fn f(a: *Assembler) !void {
            try a.movRegReg(.rax, .rdi);
        }
    }.f);
    try expectEnc(&.{ 0x4D, 0x89, 0xC1 }, struct { // mov r9, r8
        fn f(a: *Assembler) !void {
            try a.movRegReg(.r9, .r8);
        }
    }.f);
}

test "enc: mov reg, [base+disp] / [base+disp], reg" {
    try expectEnc(&.{ 0x48, 0x8B, 0x47, 0x08 }, struct { // mov rax, [rdi+8]
        fn f(a: *Assembler) !void {
            try a.movRegMem(.rax, .rdi, 8);
        }
    }.f);
    try expectEnc(&.{ 0x48, 0x8B, 0x07 }, struct { // mov rax, [rdi]  (disp 0)
        fn f(a: *Assembler) !void {
            try a.movRegMem(.rax, .rdi, 0);
        }
    }.f);
    try expectEnc(&.{ 0x48, 0x89, 0x44, 0x24, 0x10 }, struct { // mov [rsp+16], rax (SIB)
        fn f(a: *Assembler) !void {
            try a.movMemReg(.rsp, 16, .rax);
        }
    }.f);
    try expectEnc(&.{ 0x48, 0x89, 0x04, 0x24 }, struct { // mov [rsp], rax (SIB, disp0)
        fn f(a: *Assembler) !void {
            try a.movMemReg(.rsp, 0, .rax);
        }
    }.f);
}

test "enc: mov qword [base+disp], imm32" {
    try expectEnc(&.{ 0x48, 0xC7, 0x07, 0x02, 0, 0, 0 }, struct { // mov qword [rdi], 2
        fn f(a: *Assembler) !void {
            try a.movMemImm32(.rdi, 0, 2);
        }
    }.f);
}

test "enc: movzx reg, reg8" {
    try expectEnc(&.{ 0x48, 0x0F, 0xB6, 0xC0 }, struct { // movzx rax, al
        fn f(a: *Assembler) !void {
            try a.movzxRegReg8(.rax, .rax);
        }
    }.f);
}

test "enc: alu reg, reg" {
    try expectEnc(&.{ 0x48, 0x01, 0xF8 }, struct { // add rax, rdi
        fn f(a: *Assembler) !void {
            try a.addRegReg(.rax, .rdi);
        }
    }.f);
    try expectEnc(&.{ 0x48, 0x29, 0xC8 }, struct { // sub rax, rcx
        fn f(a: *Assembler) !void {
            try a.subRegReg(.rax, .rcx);
        }
    }.f);
    try expectEnc(&.{ 0x48, 0x21, 0xC8 }, struct { // and rax, rcx
        fn f(a: *Assembler) !void {
            try a.andRegReg(.rax, .rcx);
        }
    }.f);
    try expectEnc(&.{ 0x48, 0x09, 0xC8 }, struct { // or rax, rcx
        fn f(a: *Assembler) !void {
            try a.orRegReg(.rax, .rcx);
        }
    }.f);
    try expectEnc(&.{ 0x48, 0x31, 0xC8 }, struct { // xor rax, rcx
        fn f(a: *Assembler) !void {
            try a.xorRegReg(.rax, .rcx);
        }
    }.f);
    try expectEnc(&.{ 0x48, 0x39, 0xC8 }, struct { // cmp rax, rcx
        fn f(a: *Assembler) !void {
            try a.cmpRegReg(.rax, .rcx);
        }
    }.f);
}

test "enc: imul / neg / not / inc" {
    try expectEnc(&.{ 0x48, 0x0F, 0xAF, 0xC1 }, struct { // imul rax, rcx
        fn f(a: *Assembler) !void {
            try a.imulRegReg(.rax, .rcx);
        }
    }.f);
    try expectEnc(&.{ 0x48, 0xF7, 0xD8 }, struct { // neg rax
        fn f(a: *Assembler) !void {
            try a.negReg(.rax);
        }
    }.f);
    try expectEnc(&.{ 0x48, 0xF7, 0xD0 }, struct { // not rax
        fn f(a: *Assembler) !void {
            try a.notReg(.rax);
        }
    }.f);
    try expectEnc(&.{ 0x48, 0xFF, 0xC3 }, struct { // inc rbx
        fn f(a: *Assembler) !void {
            try a.incReg(.rbx);
        }
    }.f);
}

test "enc: ALU reg, [mem] (load form)" {
    try expectEnc(&.{ 0x48, 0x03, 0x47, 0x08 }, struct { // add rax, [rdi+8]
        fn f(a: *Assembler) !void {
            try a.addRegMem(.rax, .rdi, 8);
        }
    }.f);
    try expectEnc(&.{ 0x48, 0x2B, 0x0A }, struct { // sub rcx, [rdx]
        fn f(a: *Assembler) !void {
            try a.subRegMem(.rcx, .rdx, 0);
        }
    }.f);
    try expectEnc(&.{ 0x48, 0x23, 0x47, 0x08 }, struct { // and rax, [rdi+8]
        fn f(a: *Assembler) !void {
            try a.andRegMem(.rax, .rdi, 8);
        }
    }.f);
    try expectEnc(&.{ 0x48, 0x0B, 0x47, 0x08 }, struct { // or rax, [rdi+8]
        fn f(a: *Assembler) !void {
            try a.orRegMem(.rax, .rdi, 8);
        }
    }.f);
    try expectEnc(&.{ 0x48, 0x33, 0x47, 0x08 }, struct { // xor rax, [rdi+8]
        fn f(a: *Assembler) !void {
            try a.xorRegMem(.rax, .rdi, 8);
        }
    }.f);
    try expectEnc(&.{ 0x48, 0x3B, 0x47, 0x08 }, struct { // cmp rax, [rdi+8]
        fn f(a: *Assembler) !void {
            try a.cmpRegMem(.rax, .rdi, 8);
        }
    }.f);
    try expectEnc(&.{ 0x48, 0x0F, 0xAF, 0x07 }, struct { // imul rax, [rdi]
        fn f(a: *Assembler) !void {
            try a.imulRegMem(.rax, .rdi, 0);
        }
    }.f);
    // r8–r15: REX.R (dst r8) + REX.B (base r9).
    try expectEnc(&.{ 0x4D, 0x03, 0x41, 0x10 }, struct { // add r8, [r9+16]
        fn f(a: *Assembler) !void {
            try a.addRegMem(.r8, .r9, 16);
        }
    }.f);
    // rsp base → SIB byte.
    try expectEnc(&.{ 0x48, 0x03, 0x44, 0x24, 0x10 }, struct { // add rax, [rsp+16]
        fn f(a: *Assembler) !void {
            try a.addRegMem(.rax, .rsp, 16);
        }
    }.f);
    // rbp base, disp 0 → forced disp8.
    try expectEnc(&.{ 0x48, 0x03, 0x45, 0x00 }, struct { // add rax, [rbp]
        fn f(a: *Assembler) !void {
            try a.addRegMem(.rax, .rbp, 0);
        }
    }.f);
}

test "enc: ALU [mem], reg (store form)" {
    try expectEnc(&.{ 0x48, 0x01, 0x4F, 0x08 }, struct { // add [rdi+8], rcx
        fn f(a: *Assembler) !void {
            try a.addMemReg(.rdi, 8, .rcx);
        }
    }.f);
    try expectEnc(&.{ 0x48, 0x29, 0x44, 0x24, 0x10 }, struct { // sub [rsp+16], rax
        fn f(a: *Assembler) !void {
            try a.subMemReg(.rsp, 16, .rax);
        }
    }.f);
    try expectEnc(&.{ 0x48, 0x21, 0x4F, 0x08 }, struct { // and [rdi+8], rcx
        fn f(a: *Assembler) !void {
            try a.andMemReg(.rdi, 8, .rcx);
        }
    }.f);
    try expectEnc(&.{ 0x48, 0x09, 0x4F, 0x08 }, struct { // or [rdi+8], rcx
        fn f(a: *Assembler) !void {
            try a.orMemReg(.rdi, 8, .rcx);
        }
    }.f);
    try expectEnc(&.{ 0x48, 0x31, 0x4F, 0x08 }, struct { // xor [rdi+8], rcx
        fn f(a: *Assembler) !void {
            try a.xorMemReg(.rdi, 8, .rcx);
        }
    }.f);
    // r8–r15 store: REX.R (src r10) + REX.B (base r11).
    try expectEnc(&.{ 0x4D, 0x01, 0x53, 0x18 }, struct { // add [r11+24], r10
        fn f(a: *Assembler) !void {
            try a.addMemReg(.r11, 24, .r10);
        }
    }.f);
}

test "enc: add/sub reg, imm32" {
    try expectEnc(&.{ 0x48, 0x81, 0xEC, 0x80, 0, 0, 0 }, struct { // sub rsp, 128
        fn f(a: *Assembler) !void {
            try a.subRegImm32(.rsp, 128);
        }
    }.f);
    try expectEnc(&.{ 0x48, 0x81, 0xC4, 0x80, 0, 0, 0 }, struct { // add rsp, 128
        fn f(a: *Assembler) !void {
            try a.addRegImm32(.rsp, 128);
        }
    }.f);
    try expectEnc(&.{ 0x48, 0x81, 0xFF, 0, 0, 0, 0 }, struct { // cmp rdi, 0
        fn f(a: *Assembler) !void {
            try a.cmpRegImm32(.rdi, 0);
        }
    }.f);
}

test "enc: cmp byte / qword mem, imm" {
    try expectEnc(&.{ 0x80, 0x7F, 0x08, 0x02 }, struct { // cmp byte [rdi+8], 2
        fn f(a: *Assembler) !void {
            try a.cmpByteMemImm(.rdi, 8, 2);
        }
    }.f);
    try expectEnc(&.{ 0x80, 0x3F, 0x02 }, struct { // cmp byte [rdi], 2
        fn f(a: *Assembler) !void {
            try a.cmpByteMemImm(.rdi, 0, 2);
        }
    }.f);
    try expectEnc(&.{ 0x48, 0x83, 0x7C, 0x24, 0x10, 0x00 }, struct { // cmp qword [rsp+16], 0
        fn f(a: *Assembler) !void {
            try a.cmpQwordMemImm8(.rsp, 16, 0);
        }
    }.f);
}

test "enc: setcc" {
    try expectEnc(&.{ 0x0F, 0x94, 0xC0 }, struct { // sete al
        fn f(a: *Assembler) !void {
            try a.setcc(.e, .rax);
        }
    }.f);
    try expectEnc(&.{ 0x0F, 0x9C, 0xC0 }, struct { // setl al
        fn f(a: *Assembler) !void {
            try a.setcc(.l, .rax);
        }
    }.f);
    try expectEnc(&.{ 0x0F, 0x9E, 0xC0 }, struct { // setle al
        fn f(a: *Assembler) !void {
            try a.setcc(.le, .rax);
        }
    }.f);
}

test "enc: push / pop / ret" {
    try expectEnc(&.{0x53}, struct { // push rbx
        fn f(a: *Assembler) !void {
            try a.push(.rbx);
        }
    }.f);
    try expectEnc(&.{0x5B}, struct { // pop rbx
        fn f(a: *Assembler) !void {
            try a.pop(.rbx);
        }
    }.f);
    try expectEnc(&.{ 0x41, 0x54 }, struct { // push r12
        fn f(a: *Assembler) !void {
            try a.push(.r12);
        }
    }.f);
    try expectEnc(&.{0xC3}, struct {
        fn f(a: *Assembler) !void {
            try a.ret();
        }
    }.f);
}

test "enc: jmp backward (loop back-edge)" {
    // L: inc rbx ; jmp L  → jmp rel32 = -(3+5) = -8 = 0xF8FFFFFF
    try expectEnc(
        &.{ 0x48, 0xFF, 0xC3, 0xE9, 0xF8, 0xFF, 0xFF, 0xFF },
        struct {
            fn f(a: *Assembler) !void {
                const l = try a.label();
                a.bind(l);
                try a.incReg(.rbx);
                try a.jmp(l);
            }
        }.f,
    );
}

test "enc: jcc forward (side-exit)" {
    // jne EXIT ; inc rbx ; EXIT: ret
    //   jne rel32 over `inc rbx` (3 bytes) → rel32 = 3 = 0x03000000(LE)
    try expectEnc(
        &.{ 0x0F, 0x85, 0x03, 0x00, 0x00, 0x00, 0x48, 0xFF, 0xC3, 0xC3 },
        struct {
            fn f(a: *Assembler) !void {
                const exit = try a.label();
                try a.jcc(.ne, exit);
                try a.incReg(.rbx);
                a.bind(exit);
                try a.ret();
            }
        }.f,
    );
}
