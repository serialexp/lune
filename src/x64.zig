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
    b = 0x2, // CF=1            — unsigned <  (below)
    ae = 0x3, // CF=0           — unsigned ≥  (above-or-equal / not-carry)
    e = 0x4, // ZF=1            — equal / zero
    ne = 0x5, // ZF=0           — not-equal / not-zero
    be = 0x6, // CF=1 or ZF=1   — unsigned ≤  (below-or-equal)
    a = 0x7, // CF=0 and ZF=0  — unsigned >  (above)
    p = 0xA, // PF=1            — parity (unordered, after ucomisd compare)
    np = 0xB, // PF=0           — no-parity (ordered)
    l = 0xC, // SF≠OF          — signed <
    ge = 0xD, // SF=OF          — signed ≥
    le = 0xE, // ZF=1 or SF≠OF  — signed ≤
    g = 0xF, // ZF=0 and SF=OF — signed >
};

/// XMM register aliases. SSE encodes an XMM operand by the same 0..15 index
/// (ModRM.reg/.rm + the REX.R/.B extension bit) as a GP register, so the JIT
/// reuses `Reg` directly for XMM operands; these names exist only so call sites
/// read `xmm0` rather than the GP spelling of the same index.
pub const xmm0: Reg = @enumFromInt(0);
pub const xmm1: Reg = @enumFromInt(1);
pub const xmm2: Reg = @enumFromInt(2);
pub const xmm3: Reg = @enumFromInt(3);
pub const xmm4: Reg = @enumFromInt(4);
pub const xmm5: Reg = @enumFromInt(5);
pub const xmm6: Reg = @enumFromInt(6);
pub const xmm7: Reg = @enumFromInt(7);
pub const xmm8: Reg = @enumFromInt(8);
pub const xmm9: Reg = @enumFromInt(9);
pub const xmm10: Reg = @enumFromInt(10);
pub const xmm11: Reg = @enumFromInt(11);
pub const xmm12: Reg = @enumFromInt(12);
pub const xmm13: Reg = @enumFromInt(13);
pub const xmm14: Reg = @enumFromInt(14);
pub const xmm15: Reg = @enumFromInt(15);

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
        try self.rexF(w, r, x, bb, false);
    }

    /// `rex` with an explicit `force`: emit the prefix even when it would be the
    /// bare 0x40. Needed by 8-bit stores (`88 /r`) whose source is `rsi/rdi/rbp/
    /// rsp` — without a REX prefix those `reg` encodings mean `ah/ch/dh/bh`, so
    /// REX must be present to select `sil/dil/bpl/spl`.
    fn rexF(self: *Assembler, w: bool, r: bool, x: bool, bb: bool, force: bool) !void {
        const byte: u8 = 0x40 |
            (@as(u8, @intFromBool(w)) << 3) |
            (@as(u8, @intFromBool(r)) << 2) |
            (@as(u8, @intFromBool(x)) << 1) |
            @as(u8, @intFromBool(bb));
        if (force or byte != 0x40) try self.b(byte);
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

    /// SIB scale bits (00/01/10/11) for an element width of 1/2/4/8 bytes.
    fn sibScale(width: u8) u2 {
        return switch (width) {
            1 => 0b00,
            2 => 0b01,
            4 => 0b10,
            8 => 0b11,
            else => unreachable,
        };
    }

    /// ModRM + SIB + displacement for a `[base + index*scale + disp]` operand
    /// (the lane-aware packed-array element address). `reg` is the opcode's
    /// register field. `scale` is the encoded SIB scale (use `sibScale`). The
    /// index register must not be `rsp` — index field `0b100` is the SIB
    /// "no-index" escape, so `rsp` cannot be an index (REX.X disambiguates r12).
    fn modrmMemSib(self: *Assembler, reg: u3, base: Reg, index: Reg, scale: u2, disp: i32) !void {
        std.debug.assert(index != .rsp);
        const base_lo = base.lo();
        // Same mod rule as `modrmMem`: base rbp/r13 (lo=5) at disp 0 collides with
        // the SIB "no base, disp32" form, so force disp8.
        const mod: u2 = if (disp == 0 and base_lo != 5)
            0b00
        else if (disp >= -128 and disp <= 127)
            0b01
        else
            0b10;
        try self.b((@as(u8, mod) << 6) | (@as(u8, reg) << 3) | 0b100); // rm=100 → SIB
        try self.b((@as(u8, scale) << 6) | (@as(u8, index.lo()) << 3) | @as(u8, base_lo));
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

    // ---- lane-aware packed-array load / store (Phase B) -------------------------
    //
    // These reach a packed element at `[base + index*lane_width + disp]` (the SIB
    // form) and decode/encode the narrow lane's width to/from a full 64-bit GP
    // register. `lane_width` is the element byte width (1/2/4/8) and doubles as
    // the SIB scale. Sub-byte (boolean) lanes use the `bt`/`bts`/`btr` bit ops
    // below instead.

    /// `mov/movsx/movzx/movsxd dst, <width> [base + index*width + disp]` —
    /// load one packed element, extending `width` bytes to the full 64-bit `dst`.
    /// `signed` selects sign- vs zero-extension (narrow int lanes are signed;
    /// the f64/i64 8-byte path ignores it). Forms:
    ///   1: REX.W 0F BE (movsx) / 0F B6 (movzx)
    ///   2: REX.W 0F BF (movsx) / 0F B7 (movzx)
    ///   4: REX.W 63 (movsxd, signed) / 8B with REX.W=0 (mov r32, zero-extends)
    ///   8: REX.W 8B (mov r64)
    pub fn loadRegMemSib(self: *Assembler, dst: Reg, base: Reg, index: Reg, lane_width: u8, signed: bool, disp: i32) !void {
        switch (lane_width) {
            1 => {
                try self.rex(true, dst.hi(), index.hi(), base.hi());
                try self.b(0x0F);
                try self.b(if (signed) 0xBE else 0xB6);
            },
            2 => {
                try self.rex(true, dst.hi(), index.hi(), base.hi());
                try self.b(0x0F);
                try self.b(if (signed) 0xBF else 0xB7);
            },
            4 => {
                if (signed) {
                    try self.rex(true, dst.hi(), index.hi(), base.hi());
                    try self.b(0x63); // movsxd r64, r/m32
                } else {
                    try self.rex(false, dst.hi(), index.hi(), base.hi());
                    try self.b(0x8B); // mov r32, r/m32 (zero-extends to r64)
                }
            },
            8 => {
                try self.rex(true, dst.hi(), index.hi(), base.hi());
                try self.b(0x8B);
            },
            else => unreachable,
        }
        try self.modrmMemSib(dst.lo(), base, index, sibScale(lane_width), disp);
    }

    /// `mov <width> [base + index*width + disp], src` — store the low `width`
    /// bytes of `src` into a packed element. Forms:
    ///   1: 88 /r (REX forced when src ∈ rsi/rdi/rbp/rsp so it isn't ah/ch/dh/bh)
    ///   2: 66 + 89 /r (16-bit operand-size prefix)
    ///   4: 89 /r (REX.W=0)
    ///   8: REX.W 89 /r
    pub fn storeMemSibReg(self: *Assembler, base: Reg, index: Reg, lane_width: u8, disp: i32, src: Reg) !void {
        switch (lane_width) {
            1 => {
                try self.rexF(false, src.hi(), index.hi(), base.hi(), src.lo() >= 4);
                try self.b(0x88);
            },
            2 => {
                try self.b(0x66);
                try self.rex(false, src.hi(), index.hi(), base.hi());
                try self.b(0x89);
            },
            4 => {
                try self.rex(false, src.hi(), index.hi(), base.hi());
                try self.b(0x89);
            },
            8 => {
                try self.rex(true, src.hi(), index.hi(), base.hi());
                try self.b(0x89);
            },
            else => unreachable,
        }
        try self.modrmMemSib(src.lo(), base, index, sibScale(lane_width), disp);
    }

    /// `lea dst, [base + index*width + disp]` — REX.W 8D /r. Computes a packed
    /// element address (`data + idx0*width`) into `dst` WITHOUT touching memory or
    /// flags, so the int-lane store can fold the index into one base register and
    /// free the index register for the value (only rax/rcx are scratch).
    pub fn leaRegMemSib(self: *Assembler, dst: Reg, base: Reg, index: Reg, lane_width: u8, disp: i32) !void {
        try self.rex(true, dst.hi(), index.hi(), base.hi());
        try self.b(0x8D);
        try self.modrmMemSib(dst.lo(), base, index, sibScale(lane_width), disp);
    }

    /// `mov <width> [base + disp], src` — store the low `width` bytes of `src` to a
    /// plain `[base+disp]` address (NO index). The SIB store `storeMemSibReg` needs
    /// base+index+src live at once; for the int-lane store the address is folded
    /// into `base` via `leaRegMemSib` first, leaving this non-indexed form. Same
    /// width encodings as `storeMemSibReg` (88 / 66+89 / 89 / REX.W 89).
    pub fn storeMemReg(self: *Assembler, base: Reg, lane_width: u8, disp: i32, src: Reg) !void {
        switch (lane_width) {
            1 => {
                try self.rexF(false, src.hi(), false, base.hi(), src.lo() >= 4);
                try self.b(0x88);
            },
            2 => {
                try self.b(0x66);
                try self.rex(false, src.hi(), false, base.hi());
                try self.b(0x89);
            },
            4 => {
                try self.rex(false, src.hi(), false, base.hi());
                try self.b(0x89);
            },
            8 => {
                try self.rex(true, src.hi(), false, base.hi());
                try self.b(0x89);
            },
            else => unreachable,
        }
        try self.modrmMem(src.lo(), base, disp);
    }

    /// Bit-string op against memory with the bit index in a register:
    /// `bt/bts/btr [base + disp], idx` — 0F A3 / 0F AB / 0F B3 /r, REX.W. The
    /// `idx` register is a full 64-bit bit offset into the byte string at
    /// `[base+disp]` (the CPU resolves byte = base + idx/8, bit = idx%8), so the
    /// boolean lane's value/presence bitmaps index directly by slot with no
    /// per-element address math. `bt` sets CF from the bit (read); `bts` sets it
    /// to 1; `btr` clears it to 0.
    fn btGroup(self: *Assembler, op2: u8, base: Reg, disp: i32, idx: Reg) !void {
        try self.rex(true, idx.hi(), false, base.hi());
        try self.b(0x0F);
        try self.b(op2);
        try self.modrmMem(idx.lo(), base, disp);
    }
    pub fn btMemReg(self: *Assembler, base: Reg, disp: i32, idx: Reg) !void {
        try self.btGroup(0xA3, base, disp, idx);
    }
    pub fn btsMemReg(self: *Assembler, base: Reg, disp: i32, idx: Reg) !void {
        try self.btGroup(0xAB, base, disp, idx);
    }
    pub fn btrMemReg(self: *Assembler, base: Reg, disp: i32, idx: Reg) !void {
        try self.btGroup(0xB3, base, disp, idx);
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
        // Force a REX prefix for low-encoding 4..7 (rsp/rbp/rsi/rdi): in an 8-bit
        // `reg` field those mean `ah/ch/dh/bh` *without* REX, but `spl/bpl/sil/dil`
        // *with* it. (r8..r15 already force REX via `bb`; al/cl/dl/bl need none.)
        try self.rexF(false, false, false, reg.hi(), reg.lo() >= 4);
        try self.b(0x0F);
        try self.b(0x90 | @intFromEnum(cc));
        try self.modrmReg(0, reg.lo());
    }

    // ---- scalar SSE2 (double-precision float) — Phase D -------------------------
    //
    // Float traces live in XMM registers. Every form here is a scalar-double op:
    // a mandatory legacy prefix (0xF2 for scalar-double, 0x66 for the integer /
    // move / compare forms), then the *optional* REX (W for the 64-bit GP↔XMM
    // moves and cvtsi2sd, R/B for xmm8–15), then the two-byte 0F opcode and ModRM.
    // The one ordering subtlety vs the integer forms: the mandatory prefix is
    // emitted *before* REX (legacy prefixes always precede REX), which is why
    // these don't go through the plain `rex` entry points directly.

    /// Reg-reg scalar-SSE form: `<prefix> [REX] 0F <opcode> /r`, ModRM mod=11.
    /// `reg` is the ModRM.reg operand (REX.R), `rm` the ModRM.rm operand (REX.B).
    fn sseRR(self: *Assembler, prefix: u8, w: bool, opcode: u8, reg: Reg, rm: Reg) !void {
        try self.b(prefix);
        try self.rex(w, reg.hi(), false, rm.hi());
        try self.b(0x0F);
        try self.b(opcode);
        try self.modrmReg(reg.lo(), rm.lo());
    }

    /// Reg-mem scalar-SSE form: `<prefix> [REX] 0F <opcode> /r`, `[base+disp]`.
    /// `reg` is the ModRM.reg operand (the XMM register); the memory operand is rm.
    fn sseRM(self: *Assembler, prefix: u8, w: bool, opcode: u8, reg: Reg, base: Reg, disp: i32) !void {
        try self.b(prefix);
        try self.rex(w, reg.hi(), false, base.hi());
        try self.b(0x0F);
        try self.b(opcode);
        try self.modrmMem(reg.lo(), base, disp);
    }

    /// `movsd dst, src` — F2 0F 10 /r: copy a scalar double between XMM regs.
    pub fn movsdRegReg(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.sseRR(0xF2, false, 0x10, dst, src);
    }
    /// `movsd dst, [base+disp]` — F2 0F 10 /r: load a double into an XMM reg.
    pub fn movsdRegMem(self: *Assembler, dst: Reg, base: Reg, disp: i32) !void {
        try self.sseRM(0xF2, false, 0x10, dst, base, disp);
    }
    /// `movsd [base+disp], src` — F2 0F 11 /r: store an XMM double to memory
    /// (reg field = the source XMM).
    pub fn movsdMemReg(self: *Assembler, base: Reg, disp: i32, src: Reg) !void {
        try self.sseRM(0xF2, false, 0x11, src, base, disp);
    }

    /// `addsd dst, src` — F2 0F 58 /r.
    pub fn addsdRegReg(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.sseRR(0xF2, false, 0x58, dst, src);
    }
    /// `addsd dst, [base+disp]` — F2 0F 58 /r.
    pub fn addsdRegMem(self: *Assembler, dst: Reg, base: Reg, disp: i32) !void {
        try self.sseRM(0xF2, false, 0x58, dst, base, disp);
    }
    /// `subsd dst, src` — F2 0F 5C /r (dst = dst - src; operand order matters).
    pub fn subsdRegReg(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.sseRR(0xF2, false, 0x5C, dst, src);
    }
    /// `subsd dst, [base+disp]` — F2 0F 5C /r.
    pub fn subsdRegMem(self: *Assembler, dst: Reg, base: Reg, disp: i32) !void {
        try self.sseRM(0xF2, false, 0x5C, dst, base, disp);
    }
    /// `mulsd dst, src` — F2 0F 59 /r.
    pub fn mulsdRegReg(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.sseRR(0xF2, false, 0x59, dst, src);
    }
    /// `mulsd dst, [base+disp]` — F2 0F 59 /r.
    pub fn mulsdRegMem(self: *Assembler, dst: Reg, base: Reg, disp: i32) !void {
        try self.sseRM(0xF2, false, 0x59, dst, base, disp);
    }
    /// `divsd dst, src` — F2 0F 5E /r (dst = dst / src; operand order matters).
    pub fn divsdRegReg(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.sseRR(0xF2, false, 0x5E, dst, src);
    }
    /// `divsd dst, [base+disp]` — F2 0F 5E /r.
    pub fn divsdRegMem(self: *Assembler, dst: Reg, base: Reg, disp: i32) !void {
        try self.sseRM(0xF2, false, 0x5E, dst, base, disp);
    }

    /// `ucomisd a, b` — 66 0F 2E /r: unordered compare two doubles, set ZF/PF/CF.
    /// (Unordered ⇒ ZF=PF=CF=1; the NaN-aware setcc combine reads PF.)
    pub fn ucomisdRegReg(self: *Assembler, lhs: Reg, rhs: Reg) !void {
        try self.sseRR(0x66, false, 0x2E, lhs, rhs);
    }
    /// `ucomisd lhs, [base+disp]` — 66 0F 2E /r.
    pub fn ucomisdRegMem(self: *Assembler, lhs: Reg, base: Reg, disp: i32) !void {
        try self.sseRM(0x66, false, 0x2E, lhs, base, disp);
    }

    /// `cvtsi2sd dst_xmm, src_gp` — F2 REX.W 0F 2A /r: convert a signed 64-bit
    /// integer to a double (round-to-nearest, matching `@floatFromInt`).
    pub fn cvtsi2sdRegReg(self: *Assembler, dst_xmm: Reg, src_gp: Reg) !void {
        try self.sseRR(0xF2, true, 0x2A, dst_xmm, src_gp);
    }
    /// `cvtsi2sd dst_xmm, qword [base+disp]` — F2 REX.W 0F 2A /r.
    pub fn cvtsi2sdRegMem(self: *Assembler, dst_xmm: Reg, base: Reg, disp: i32) !void {
        try self.sseRM(0xF2, true, 0x2A, dst_xmm, base, disp);
    }

    /// `cvttsd2si dst_gp, src_xmm` — F2 REX.W 0F 2C /r: convert a double to a signed
    /// 64-bit integer with **truncation toward zero** (matching `@intFromFloat`). A
    /// NaN / ±inf / out-of-`[-2^63, 2^63)` source yields the "integer indefinite"
    /// 0x8000000000000000, which the recorder's round-trip test (`cvtsi2sd` +
    /// `ucomisd`) detects and side-exits on. reg field = dst GP, rm = src XMM.
    pub fn cvttsd2siRegReg(self: *Assembler, dst_gp: Reg, src_xmm: Reg) !void {
        try self.sseRR(0xF2, true, 0x2C, dst_gp, src_xmm);
    }

    /// `movq dst_xmm, src_gp` — 66 REX.W 0F 6E /r: move 64 raw bits GP→XMM
    /// (materialize a float constant whose bits are in a GP register).
    pub fn movqXmmReg(self: *Assembler, dst_xmm: Reg, src_gp: Reg) !void {
        try self.sseRR(0x66, true, 0x6E, dst_xmm, src_gp);
    }
    /// `movq dst_gp, src_xmm` — 66 REX.W 0F 7E /r: move 64 raw bits XMM→GP
    /// (reg field = the source XMM, rm = the destination GP).
    pub fn movqRegXmm(self: *Assembler, dst_gp: Reg, src_xmm: Reg) !void {
        try self.sseRR(0x66, true, 0x7E, src_xmm, dst_gp);
    }

    /// `xorpd dst, src` — 66 0F 57 /r: bitwise-xor two doubles (the sign-flip
    /// mask for the deferred float-`neg`).
    pub fn xorpdRegReg(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.sseRR(0x66, false, 0x57, dst, src);
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

test "enc: SIB load (movsx/movsxd/mov, scale 1/2/4/8)" {
    // movsx rax, byte [rdi + rcx*1]   — REX.W 0F BE, SIB scale0 idx=rcx base=rdi
    try expectEnc(&.{ 0x48, 0x0F, 0xBE, 0x04, 0x0F }, struct {
        fn f(a: *Assembler) !void {
            try a.loadRegMemSib(.rax, .rdi, .rcx, 1, true, 0);
        }
    }.f);
    // movzx rax, byte [rdi + rcx*1]   — REX.W 0F B6
    try expectEnc(&.{ 0x48, 0x0F, 0xB6, 0x04, 0x0F }, struct {
        fn f(a: *Assembler) !void {
            try a.loadRegMemSib(.rax, .rdi, .rcx, 1, false, 0);
        }
    }.f);
    // movsx rax, word [rdi + rcx*2]   — REX.W 0F BF, scale1
    try expectEnc(&.{ 0x48, 0x0F, 0xBF, 0x04, 0x4F }, struct {
        fn f(a: *Assembler) !void {
            try a.loadRegMemSib(.rax, .rdi, .rcx, 2, true, 0);
        }
    }.f);
    // movsxd rax, dword [rdi + rcx*4] — REX.W 63, scale2
    try expectEnc(&.{ 0x48, 0x63, 0x04, 0x8F }, struct {
        fn f(a: *Assembler) !void {
            try a.loadRegMemSib(.rax, .rdi, .rcx, 4, true, 0);
        }
    }.f);
    // mov eax, dword [rdi + rcx*4]    — 8B with REX.W=0 (zero-extends); no REX byte
    try expectEnc(&.{ 0x8B, 0x04, 0x8F }, struct {
        fn f(a: *Assembler) !void {
            try a.loadRegMemSib(.rax, .rdi, .rcx, 4, false, 0);
        }
    }.f);
    // mov rax, qword [rdi + rcx*8]    — REX.W 8B, scale3
    try expectEnc(&.{ 0x48, 0x8B, 0x04, 0xCF }, struct {
        fn f(a: *Assembler) !void {
            try a.loadRegMemSib(.rax, .rdi, .rcx, 8, false, 0);
        }
    }.f);
    // mov rax, qword [rdi + rcx*8 + 16] — disp8 form
    try expectEnc(&.{ 0x48, 0x8B, 0x44, 0xCF, 0x10 }, struct {
        fn f(a: *Assembler) !void {
            try a.loadRegMemSib(.rax, .rdi, .rcx, 8, false, 16);
        }
    }.f);
    // rbp base, disp 0 → forced disp8: mov rax, qword [rbp + rcx*8]
    try expectEnc(&.{ 0x48, 0x8B, 0x44, 0xCD, 0x00 }, struct {
        fn f(a: *Assembler) !void {
            try a.loadRegMemSib(.rax, .rbp, .rcx, 8, false, 0);
        }
    }.f);
}

test "enc: SIB store (byte/word/dword/qword)" {
    // mov byte [rdi + rcx*1], al — 88 /r, src rax (lo0 <4) → no REX byte
    try expectEnc(&.{ 0x88, 0x04, 0x0F }, struct {
        fn f(a: *Assembler) !void {
            try a.storeMemSibReg(.rdi, .rcx, 1, 0, .rax);
        }
    }.f);
    // mov byte [rdi + rcx*1], sil — src rsi (lo6 ≥4) forces REX 0x40 → sil not dh
    try expectEnc(&.{ 0x40, 0x88, 0x34, 0x0F }, struct {
        fn f(a: *Assembler) !void {
            try a.storeMemSibReg(.rdi, .rcx, 1, 0, .rsi);
        }
    }.f);
    // mov word [rdi + rcx*2], ax — 66 prefix + 89
    try expectEnc(&.{ 0x66, 0x89, 0x04, 0x4F }, struct {
        fn f(a: *Assembler) !void {
            try a.storeMemSibReg(.rdi, .rcx, 2, 0, .rax);
        }
    }.f);
    // mov dword [rdi + rcx*4], eax — 89 with REX.W=0; no REX byte
    try expectEnc(&.{ 0x89, 0x04, 0x8F }, struct {
        fn f(a: *Assembler) !void {
            try a.storeMemSibReg(.rdi, .rcx, 4, 0, .rax);
        }
    }.f);
    // mov qword [rdi + rcx*8], rax — REX.W 89
    try expectEnc(&.{ 0x48, 0x89, 0x04, 0xCF }, struct {
        fn f(a: *Assembler) !void {
            try a.storeMemSibReg(.rdi, .rcx, 8, 0, .rax);
        }
    }.f);
    // r8–r15 index/base: mov qword [r9 + r10*8], rax — REX.WXB
    try expectEnc(&.{ 0x4B, 0x89, 0x04, 0xD1 }, struct {
        fn f(a: *Assembler) !void {
            try a.storeMemSibReg(.r9, .r10, 8, 0, .rax);
        }
    }.f);
}

test "enc: lea reg, [base + index*scale (+disp)]" {
    // lea rax, [rdi + rcx*8] — REX.W 8D, same SIB as the qword load (opcode 8D)
    try expectEnc(&.{ 0x48, 0x8D, 0x04, 0xCF }, struct {
        fn f(a: *Assembler) !void {
            try a.leaRegMemSib(.rax, .rdi, .rcx, 8, 0);
        }
    }.f);
    // lea rax, [rdi + rcx*4 + 16] — scale2 (0b10), disp8
    try expectEnc(&.{ 0x48, 0x8D, 0x44, 0x8F, 0x10 }, struct {
        fn f(a: *Assembler) !void {
            try a.leaRegMemSib(.rax, .rdi, .rcx, 4, 16);
        }
    }.f);
    // lea r8, [r9 + r10*1] — REX.WRXB exercised
    try expectEnc(&.{ 0x4F, 0x8D, 0x04, 0x11 }, struct {
        fn f(a: *Assembler) !void {
            try a.leaRegMemSib(.r8, .r9, .r10, 1, 0);
        }
    }.f);
}

test "enc: non-SIB width store mov [base+disp], reg" {
    // mov byte [rax], cl — 88 /r, src rcx (lo1 <4) → no REX byte
    try expectEnc(&.{ 0x88, 0x08 }, struct {
        fn f(a: *Assembler) !void {
            try a.storeMemReg(.rax, 1, 0, .rcx);
        }
    }.f);
    // mov byte [rax], sil — src rsi (lo6 ≥4) forces REX 0x40 → sil not dh
    try expectEnc(&.{ 0x40, 0x88, 0x30 }, struct {
        fn f(a: *Assembler) !void {
            try a.storeMemReg(.rax, 1, 0, .rsi);
        }
    }.f);
    // mov word [rax], cx — 66 prefix + 89, no REX
    try expectEnc(&.{ 0x66, 0x89, 0x08 }, struct {
        fn f(a: *Assembler) !void {
            try a.storeMemReg(.rax, 2, 0, .rcx);
        }
    }.f);
    // mov dword [rax], ecx — 89, REX.W=0, no REX byte
    try expectEnc(&.{ 0x89, 0x08 }, struct {
        fn f(a: *Assembler) !void {
            try a.storeMemReg(.rax, 4, 0, .rcx);
        }
    }.f);
    // mov qword [rax], rcx — REX.W 89
    try expectEnc(&.{ 0x48, 0x89, 0x08 }, struct {
        fn f(a: *Assembler) !void {
            try a.storeMemReg(.rax, 8, 0, .rcx);
        }
    }.f);
    // mov qword [r8], rcx — REX.W + REX.B (base r8)
    try expectEnc(&.{ 0x49, 0x89, 0x08 }, struct {
        fn f(a: *Assembler) !void {
            try a.storeMemReg(.r8, 8, 0, .rcx);
        }
    }.f);
    // mov dword [rbp + 8], ecx — base rbp (lo5) forces disp8 even at... here disp8=8
    try expectEnc(&.{ 0x89, 0x4D, 0x08 }, struct {
        fn f(a: *Assembler) !void {
            try a.storeMemReg(.rbp, 4, 8, .rcx);
        }
    }.f);
}

test "enc: bt / bts / btr [mem], reg" {
    // bt [rdi], rcx — REX.W 0F A3, reg=rcx rm=rdi
    try expectEnc(&.{ 0x48, 0x0F, 0xA3, 0x0F }, struct {
        fn f(a: *Assembler) !void {
            try a.btMemReg(.rdi, 0, .rcx);
        }
    }.f);
    // bts [rdi], rcx — 0F AB
    try expectEnc(&.{ 0x48, 0x0F, 0xAB, 0x0F }, struct {
        fn f(a: *Assembler) !void {
            try a.btsMemReg(.rdi, 0, .rcx);
        }
    }.f);
    // btr [rdi], rcx — 0F B3
    try expectEnc(&.{ 0x48, 0x0F, 0xB3, 0x0F }, struct {
        fn f(a: *Assembler) !void {
            try a.btrMemReg(.rdi, 0, .rcx);
        }
    }.f);
    // bt [r8], r9 — REX.W + REX.R (r9 reg) + REX.B (r8 base)
    try expectEnc(&.{ 0x4D, 0x0F, 0xA3, 0x08 }, struct {
        fn f(a: *Assembler) !void {
            try a.btMemReg(.r8, 0, .r9);
        }
    }.f);
}

test "enc: SSE2 scalar-double arith (reg, reg)" {
    // movsd xmm0, xmm1 — F2 0F 10 /r
    try expectEnc(&.{ 0xF2, 0x0F, 0x10, 0xC1 }, struct {
        fn f(a: *Assembler) !void {
            try a.movsdRegReg(xmm0, xmm1);
        }
    }.f);
    // movsd xmm1, xmm0
    try expectEnc(&.{ 0xF2, 0x0F, 0x10, 0xC8 }, struct {
        fn f(a: *Assembler) !void {
            try a.movsdRegReg(xmm1, xmm0);
        }
    }.f);
    // addsd xmm0, xmm1 — F2 0F 58
    try expectEnc(&.{ 0xF2, 0x0F, 0x58, 0xC1 }, struct {
        fn f(a: *Assembler) !void {
            try a.addsdRegReg(xmm0, xmm1);
        }
    }.f);
    // subsd xmm0, xmm1 — F2 0F 5C
    try expectEnc(&.{ 0xF2, 0x0F, 0x5C, 0xC1 }, struct {
        fn f(a: *Assembler) !void {
            try a.subsdRegReg(xmm0, xmm1);
        }
    }.f);
    // mulsd xmm0, xmm1 — F2 0F 59
    try expectEnc(&.{ 0xF2, 0x0F, 0x59, 0xC1 }, struct {
        fn f(a: *Assembler) !void {
            try a.mulsdRegReg(xmm0, xmm1);
        }
    }.f);
    // divsd xmm0, xmm1 — F2 0F 5E
    try expectEnc(&.{ 0xF2, 0x0F, 0x5E, 0xC1 }, struct {
        fn f(a: *Assembler) !void {
            try a.divsdRegReg(xmm0, xmm1);
        }
    }.f);
    // ucomisd xmm0, xmm1 — 66 0F 2E
    try expectEnc(&.{ 0x66, 0x0F, 0x2E, 0xC1 }, struct {
        fn f(a: *Assembler) !void {
            try a.ucomisdRegReg(xmm0, xmm1);
        }
    }.f);
    // xorpd xmm0, xmm0 — 66 0F 57
    try expectEnc(&.{ 0x66, 0x0F, 0x57, 0xC0 }, struct {
        fn f(a: *Assembler) !void {
            try a.xorpdRegReg(xmm0, xmm0);
        }
    }.f);
}

test "enc: SSE2 scalar-double mem forms" {
    // movsd xmm0, [rdi+8] — F2 0F 10 /r, [rdi+disp8]
    try expectEnc(&.{ 0xF2, 0x0F, 0x10, 0x47, 0x08 }, struct {
        fn f(a: *Assembler) !void {
            try a.movsdRegMem(xmm0, .rdi, 8);
        }
    }.f);
    // movsd [rdi+8], xmm0 — F2 0F 11 /r (reg field = source xmm)
    try expectEnc(&.{ 0xF2, 0x0F, 0x11, 0x47, 0x08 }, struct {
        fn f(a: *Assembler) !void {
            try a.movsdMemReg(.rdi, 8, xmm0);
        }
    }.f);
    // movsd [rdi], xmm0 — disp0, no SIB (rdi base)
    try expectEnc(&.{ 0xF2, 0x0F, 0x11, 0x07 }, struct {
        fn f(a: *Assembler) !void {
            try a.movsdMemReg(.rdi, 0, xmm0);
        }
    }.f);
    // addsd xmm0, [rsp+16] — F2 0F 58, [rsp] base needs SIB
    try expectEnc(&.{ 0xF2, 0x0F, 0x58, 0x44, 0x24, 0x10 }, struct {
        fn f(a: *Assembler) !void {
            try a.addsdRegMem(xmm0, .rsp, 16);
        }
    }.f);
    // ucomisd xmm0, [rdi] — 66 0F 2E
    try expectEnc(&.{ 0x66, 0x0F, 0x2E, 0x07 }, struct {
        fn f(a: *Assembler) !void {
            try a.ucomisdRegMem(xmm0, .rdi, 0);
        }
    }.f);
}

test "enc: SSE2 GP<->XMM moves + cvtsi2sd" {
    // cvtsi2sd xmm0, rax — F2 REX.W 0F 2A /r
    try expectEnc(&.{ 0xF2, 0x48, 0x0F, 0x2A, 0xC0 }, struct {
        fn f(a: *Assembler) !void {
            try a.cvtsi2sdRegReg(xmm0, .rax);
        }
    }.f);
    // cvtsi2sd xmm0, rcx
    try expectEnc(&.{ 0xF2, 0x48, 0x0F, 0x2A, 0xC1 }, struct {
        fn f(a: *Assembler) !void {
            try a.cvtsi2sdRegReg(xmm0, .rcx);
        }
    }.f);
    // cvtsi2sd xmm0, qword [rdi+8]
    try expectEnc(&.{ 0xF2, 0x48, 0x0F, 0x2A, 0x47, 0x08 }, struct {
        fn f(a: *Assembler) !void {
            try a.cvtsi2sdRegMem(xmm0, .rdi, 8);
        }
    }.f);
    // cvttsd2si rax, xmm0 — F2 REX.W 0F 2C /r (reg=rax, rm=xmm0)
    try expectEnc(&.{ 0xF2, 0x48, 0x0F, 0x2C, 0xC0 }, struct {
        fn f(a: *Assembler) !void {
            try a.cvttsd2siRegReg(.rax, xmm0);
        }
    }.f);
    // cvttsd2si rax, xmm1 (reg=rax, rm=xmm1)
    try expectEnc(&.{ 0xF2, 0x48, 0x0F, 0x2C, 0xC1 }, struct {
        fn f(a: *Assembler) !void {
            try a.cvttsd2siRegReg(.rax, xmm1);
        }
    }.f);
    // movq xmm0, rax — 66 REX.W 0F 6E /r
    try expectEnc(&.{ 0x66, 0x48, 0x0F, 0x6E, 0xC0 }, struct {
        fn f(a: *Assembler) !void {
            try a.movqXmmReg(xmm0, .rax);
        }
    }.f);
    // movq rax, xmm0 — 66 REX.W 0F 7E /r (reg field = source xmm)
    try expectEnc(&.{ 0x66, 0x48, 0x0F, 0x7E, 0xC0 }, struct {
        fn f(a: *Assembler) !void {
            try a.movqRegXmm(.rax, xmm0);
        }
    }.f);
    // movq rcx, xmm0 — rm = rcx (dst gp)
    try expectEnc(&.{ 0x66, 0x48, 0x0F, 0x7E, 0xC1 }, struct {
        fn f(a: *Assembler) !void {
            try a.movqRegXmm(.rcx, xmm0);
        }
    }.f);
}

test "enc: SSE2 high registers (xmm8-15 + r8-15)" {
    // movsd xmm8, xmm15 — REX.R (reg=xmm8) + REX.B (rm=xmm15) = 0x45
    try expectEnc(&.{ 0xF2, 0x45, 0x0F, 0x10, 0xC7 }, struct {
        fn f(a: *Assembler) !void {
            try a.movsdRegReg(xmm8, xmm15);
        }
    }.f);
    // addsd xmm15, xmm8 — REX.R (xmm15) + REX.B (xmm8) = 0x45, modrm reg=7 rm=0
    try expectEnc(&.{ 0xF2, 0x45, 0x0F, 0x58, 0xF8 }, struct {
        fn f(a: *Assembler) !void {
            try a.addsdRegReg(xmm15, xmm8);
        }
    }.f);
    // cvtsi2sd xmm8, r15 — F2 REX.W.R.B 0F 2A, reg=0 rm=7
    try expectEnc(&.{ 0xF2, 0x4D, 0x0F, 0x2A, 0xC7 }, struct {
        fn f(a: *Assembler) !void {
            try a.cvtsi2sdRegReg(xmm8, .r15);
        }
    }.f);
    // movq xmm8, r15 — 66 REX.W.R.B 0F 6E
    try expectEnc(&.{ 0x66, 0x4D, 0x0F, 0x6E, 0xC7 }, struct {
        fn f(a: *Assembler) !void {
            try a.movqXmmReg(xmm8, .r15);
        }
    }.f);
    // movsd xmm8, [r9+8] — REX.R (xmm8) + REX.B (r9) = 0x45
    try expectEnc(&.{ 0xF2, 0x45, 0x0F, 0x10, 0x41, 0x08 }, struct {
        fn f(a: *Assembler) !void {
            try a.movsdRegMem(xmm8, .r9, 8);
        }
    }.f);
}

test "enc: setcc unsigned (b / ae)" {
    try expectEnc(&.{ 0x0F, 0x92, 0xC0 }, struct { // setb al
        fn f(a: *Assembler) !void {
            try a.setcc(.b, .rax);
        }
    }.f);
    try expectEnc(&.{ 0x0F, 0x93, 0xC0 }, struct { // setae al
        fn f(a: *Assembler) !void {
            try a.setcc(.ae, .rax);
        }
    }.f);
    // sil/dil/bpl/spl require a REX prefix (else the reg field means ah/ch/dh/bh).
    try expectEnc(&.{ 0x40, 0x0F, 0x92, 0xC6 }, struct { // setb sil (REX-forced)
        fn f(a: *Assembler) !void {
            try a.setcc(.b, .rsi);
        }
    }.f);
    try expectEnc(&.{ 0x41, 0x0F, 0x92, 0xC0 }, struct { // setb r8b
        fn f(a: *Assembler) !void {
            try a.setcc(.b, .r8);
        }
    }.f);
}

test "enc: setcc parity / above / below-or-equal (NaN-aware float compares)" {
    try expectEnc(&.{ 0x0F, 0x96, 0xC0 }, struct { // setbe al
        fn f(a: *Assembler) !void {
            try a.setcc(.be, .rax);
        }
    }.f);
    try expectEnc(&.{ 0x0F, 0x97, 0xC0 }, struct { // seta al
        fn f(a: *Assembler) !void {
            try a.setcc(.a, .rax);
        }
    }.f);
    try expectEnc(&.{ 0x0F, 0x9A, 0xC0 }, struct { // setp al
        fn f(a: *Assembler) !void {
            try a.setcc(.p, .rax);
        }
    }.f);
    try expectEnc(&.{ 0x0F, 0x9B, 0xC0 }, struct { // setnp al
        fn f(a: *Assembler) !void {
            try a.setcc(.np, .rax);
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
