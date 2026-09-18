//! Emission helpers for tier-1b native codegen (split from
//! `nativegen.zig`, file-split pass): everything `lower` calls to put
//! bytes in the assembler — Place movers, ALU/shift/compare/float
//! emitters, slot flushes, the parallel move, exit/teardown/ledger/
//! silent-epilogue paths, and the runtime-callout family.

const std = @import("std");
const x64 = @import("x64.zig");
const trace_ir = @import("trace_ir.zig");
const trace_code = @import("trace_code.zig");
const trace = trace_ir;
const trace_exec = @import("trace_exec.zig");
const value = @import("value.zig");
const table = @import("table.zig");
const arr = @import("array.zig");
const fmath = @import("fmath.zig");
const gc = @import("gc.zig");
const stralloc = @import("stralloc.zig");
const string_mod = @import("string.zig");
const Value = value.Value;
const Reg = x64.Reg;
const Trace = trace_code.TraceCode;

const artifact = @import("nativegen_artifact.zig");
const Kind = artifact.Kind;
const NativeResult = artifact.NativeResult;
const NativeResultLedgerLayout = artifact.NativeResultLedgerLayout;
const SilentSummaryCell = artifact.SilentSummaryCell;
const ExitPatchKind = artifact.ExitPatchKind;
const RET_CONT_SLOTS = artifact.RET_CONT_SLOTS;
const EXIT_NOP5 = artifact.EXIT_NOP5;

const layout = @import("nativegen_layout.zig");
const ArrLayout = layout.ArrLayout;
const TAG_NIL = layout.TAG_NIL;
const TAG_INT = layout.TAG_INT;
const TAG_BOOL = layout.TAG_BOOL;
const TAG_FLOAT = layout.TAG_FLOAT;
const TAG_HEAP = layout.TAG_HEAP;
const VALUE_TAG_OFF = layout.VALUE_TAG_OFF;
const VALUE_PAYLOAD_OFF = layout.VALUE_PAYLOAD_OFF;
const TABLE_TYPE = layout.TABLE_TYPE;
const HEADER_TYPE_OFF = layout.HEADER_TYPE_OFF;
const METATABLE_OFF = layout.METATABLE_OFF;
const STRING_TYPE = layout.STRING_TYPE;
const BOOL_LANE = layout.BOOL_LANE;
const GRID_LANE = layout.GRID_LANE;
const F64_LANE = layout.F64_LANE;
const U8_LANE = layout.U8_LANE;
const VALUE_LANE = layout.VALUE_LANE;
const HASH_SIZE_FROM_HEADER = layout.HASH_SIZE_FROM_HEADER;
const resolveHashCell = layout.resolveHashCell;
const intLaneWidth = layout.intLaneWidth;

const prove = @import("nativegen_prove.zig");
const isNumKind = prove.isNumKind;
const operandReads = prove.operandReads;

const ngalloc = @import("nativegen_alloc.zig");
const Alloc = ngalloc.Alloc;
const SlotInfo = ngalloc.SlotInfo;
const Place = ngalloc.Place;
const Loc = ngalloc.Loc;
const locToPlace = ngalloc.locToPlace;
const slotHomePlace = ngalloc.slotHomePlace;
const placeOfRef = ngalloc.placeOfRef;
const locEql = ngalloc.locEql;
const regBit = ngalloc.regBit;
const CALLEE_SAVED_MASK = ngalloc.CALLEE_SAVED_MASK;
const XMM_SCRATCH0 = ngalloc.XMM_SCRATCH0;
const XMM_SCRATCH1 = ngalloc.XMM_SCRATCH1;
const BodyCallout = ngalloc.BodyCallout;
const calloutMayCollect = ngalloc.calloutMayCollect;
const isCommutative = ngalloc.isCommutative;
const XMM_ALLOC_ORDER = ngalloc.XMM_ALLOC_ORDER;
const SilentExitMetadata = artifact.SilentExitMetadata;

pub fn placeToReg(a: *x64.Assembler, dst: Reg, src: Place) !void {
    switch (src) {
        .reg => |r| if (r != dst) try a.movRegReg(dst, r),
        .mem => |d| try a.movRegMem(dst, .rsp, d),
        .xmm => unreachable, // a GP destination never receives a float source
    }
}

pub fn regToPlace(a: *x64.Assembler, dst: Place, src: Reg) !void {
    switch (dst) {
        .reg => |r| if (r != src) try a.movRegReg(r, src),
        .mem => |d| try a.movMemReg(.rsp, d, src),
        .xmm => unreachable, // a GP source never targets a float home
    }
}

/// Ensure a ref's value is in a CPU register usable as a memory *base*, returning
/// that register. A register home is used directly; a spilled home is loaded into
/// `scratch` (rax). Used for the invariant table pointer at each array op.
pub fn refBaseReg(a: *x64.Assembler, alloc: *const Alloc, ref: usize, scratch: Reg) !Reg {
    switch (placeOfRef(alloc, ref)) {
        .reg => |r| return r,
        .mem => |d| {
            try a.movRegMem(scratch, .rsp, d);
            return scratch;
        },
        .xmm => unreachable, // array-path operands are int/ptr, never float
    }
}

/// [Phase 2] The register holding an invariant array base pointer (`data` or
/// `present`) for the table referenced by `aref_a` (an aref token's table operand).
/// If `analyze` hoisted that field into a dedicated register home, return it directly
/// — no memory traffic. Otherwise fall back to the per-iteration load: fetch the table
/// pointer (its home, or `scratch`) and load `[tbreg + array_base + field]` into
/// `scratch`, returning `scratch`. Either way the returned register is a valid memory
/// base for the subsequent SIB element access. (`len` is a compare operand, handled
/// inline at `guard_bounds`.)
pub const ArrayBaseField = enum { data, present };
pub fn arrayFieldReg(a: *x64.Assembler, alloc: *const Alloc, aref_a: usize, field: ArrayBaseField, scratch: Reg) !Reg {
    const sid = alloc.slot_id_of_ref[aref_a];
    if (sid >= 0) {
        const s = alloc.slots[@intCast(sid)];
        const home: ?Reg = switch (field) {
            .data => s.data_home,
            .present => s.present_home,
        };
        if (home) |r| return r; // hoisted — already in a register, no load
    }
    const tb = try refBaseReg(a, alloc, aref_a, scratch);
    const fieldoff: i32 = switch (field) {
        .data => ArrLayout.data,
        .present => ArrLayout.present,
    };
    try a.movRegMem(scratch, tb, ArrLayout.array_base + fieldoff);
    return scratch;
}

/// Like `refBaseReg`, but for a slot's home `Place` (used for the prologue table
/// checks, where the slot is referenced by its home, not an SSA ref).
pub fn refHomeBaseReg(a: *x64.Assembler, s: SlotInfo, scratch: Reg) !Reg {
    switch (slotHomePlace(s)) {
        .reg => |r| return r,
        .mem => |d| {
            try a.movRegMem(scratch, .rsp, d);
            return scratch;
        },
        .xmm => unreachable, // only `.ptr`/`.func`/`.native` heap-pointer slots reach here, never float
    }
}

/// Emit `dst <op> src` where `dst` is a register and `src` is a Place — reg→reg ALU
/// or the load-form `op r64, [mem]` when the operand is spilled (avoids staging it
/// through scratch). Only binary arithmetic/bitwise ops reach here.
pub fn emitAluRegPlace(a: *x64.Assembler, op: trace.IrOp, dst: Reg, src: Place) !void {
    switch (src) {
        .reg => |r| switch (op) {
            .add => try a.addRegReg(dst, r),
            .sub => try a.subRegReg(dst, r),
            .mul => try a.imulRegReg(dst, r),
            .band => try a.andRegReg(dst, r),
            .bor => try a.orRegReg(dst, r),
            .bxor => try a.xorRegReg(dst, r),
            else => unreachable,
        },
        .mem => |d| switch (op) {
            .add => try a.addRegMem(dst, .rsp, d),
            .sub => try a.subRegMem(dst, .rsp, d),
            .mul => try a.imulRegMem(dst, .rsp, d),
            .band => try a.andRegMem(dst, .rsp, d),
            .bor => try a.orRegMem(dst, .rsp, d),
            .bxor => try a.xorRegMem(dst, .rsp, d),
            else => unreachable,
        },
        .xmm => unreachable, // integer ALU never reads a float operand
    }
}

/// Lower a binary ALU op `dst = pa <op> pb` reading operands in place.
///   - register dst: keep `pa` in dst (elided when operand/home-coalesced so `pa==dst`)
///     then `op dst, pb`; a commutative op may instead keep the in-register `pb`.
///   - spilled dst: in-place store form `op [dst], pb_reg` when `pa==dst` (the win-2
///     coalesced home), else stage `a` in rax and write back. imul has no store form,
///     so a spilled in-place `mul` is never produced (analyze keeps such homes in regs).
pub fn emitBinAlu(a: *x64.Assembler, op: trace.IrOp, dst: Place, pa: Place, pb: Place) !void {
    switch (dst) {
        .reg => |R| {
            if (pa == .reg and pa.reg == R) {
                try emitAluRegPlace(a, op, R, pb);
            } else if (isCommutative(op) and pb == .reg and pb.reg == R) {
                try emitAluRegPlace(a, op, R, pa);
            } else {
                // R holds neither operand: materialize `a`, then `op R, b`. For
                // non-commutative ops `pb.reg == R` is impossible (a still-live operand
                // keeps its register), so the staging move never clobbers `b`.
                try placeToReg(a, R, pa);
                try emitAluRegPlace(a, op, R, pb);
            }
        },
        .mem => |D| {
            if (Place.eql(pa, dst)) {
                // In-place spilled home (win 2): `op [dst], b`. Load b to rcx if spilled.
                std.debug.assert(op != .mul); // no imul store form
                const src_reg: Reg = switch (pb) {
                    .reg => |r| r,
                    .mem => |bd| blk: {
                        try a.movRegMem(.rcx, .rsp, bd);
                        break :blk .rcx;
                    },
                    .xmm => unreachable,
                };
                switch (op) {
                    .add => try a.addMemReg(.rsp, D, src_reg),
                    .sub => try a.subMemReg(.rsp, D, src_reg),
                    .band => try a.andMemReg(.rsp, D, src_reg),
                    .bor => try a.orMemReg(.rsp, D, src_reg),
                    .bxor => try a.xorMemReg(.rsp, D, src_reg),
                    else => unreachable,
                }
            } else {
                // General spilled dst: compute in rax, write back.
                try placeToReg(a, .rax, pa);
                try emitAluRegPlace(a, op, .rax, pb);
                try a.movMemReg(.rsp, D, .rax);
            }
        },
        .xmm => unreachable, // integer ALU never writes a float home (see emitFloatBinOp)
    }
}

/// Lower a Lua/mahina shift `dst = pa <shift> pb` (`pb` = the count). Reproduces the
/// FULL operator semantics the oracle (`arith.shiftLeft`/`shiftRight`/`shiftRightArith`)
/// computes, making no assumption that the count is masked: a negative count shifts the
/// other direction, and an out-of-range positive count saturates — to `0` for the
/// logical shifts (`shl`/`shr`), or to the **sign fill** (`-1`/`0`) for the arithmetic
/// right shift (`sar`, the `~>>` operator). x86 `shl/shr/sar reg, cl` honour only the
/// low 6 bits of the count, so the out-of-`[0,63]` cases are handled with an explicit
/// branch bracket rather than a bare hardware shift (which would alias 64→0, 65→1, … and
/// mishandle a negative count). The value works in `W` (the dst register, or rax for a
/// spilled dst); the count lives in cl (rcx, a scratch reg) for the duration. Registers
/// used: `W` + rcx only — no extra temporary — so it fits the cut-2 allocator's two
/// scratch registers no matter how many homes are live.
pub fn emitShift(a: *x64.Assembler, op: trace.IrOp, dst: Place, pa: Place, pb: Place) !void {
    // Working register: the dst register itself, or rax when dst is spilled.
    const W: Reg = switch (dst) {
        .reg => |R| R,
        .mem => .rax,
        .xmm => unreachable, // a shift result is int, never a float home
    };
    // Load the count into rcx FIRST: pb's home may coincide with the dst register (the
    // linear scan can reuse a dying operand's reg as the result home), so reading the
    // count before W is overwritten with the value avoids clobbering it. (rcx is a
    // reserved scratch, never an operand home, so this never clobbers pa.)
    try placeToReg(a, .rcx, pb);
    // Then the value into W (the mov elides when pa is already in W).
    if (!(pa == .reg and pa.reg == W)) try placeToReg(a, W, pa);

    const neg_lbl = try a.label();
    const zero_lbl = try a.label();
    const done_lbl = try a.label();
    // sar's positive-overflow leg broadcasts the sign bit instead of zeroing; only
    // referenced/bound on the `.sar` path.
    const sign_lbl = if (op == .sar) try a.label() else undefined;

    // count < 0 → reverse-direction branch.
    try a.cmpRegImm32(.rcx, 0);
    try a.jcc(.s, neg_lbl);
    // count >= 64 → out of range. Logical shifts yield 0; arithmetic right shift
    // saturates to the sign fill (`sar W, 63`).
    try a.cmpRegImm32(.rcx, 64);
    if (op == .sar) try a.jcc(.ae, sign_lbl) else try a.jcc(.ae, zero_lbl);
    // 0 <= count < 64 → the op's primary direction.
    switch (op) {
        .shl => try a.shlRegCl(W),
        .shr => try a.shrRegCl(W),
        .sar => try a.sarRegCl(W),
        else => unreachable,
    }
    try a.jmp(done_lbl);

    a.bind(neg_lbl);
    // magnitude = -count; an out-of-range magnitude (incl. INT64_MIN, whose negation
    // stays INT64_MIN — huge as unsigned) → result 0 (the reverse is always logical).
    try a.negReg(.rcx);
    try a.cmpRegImm32(.rcx, 64);
    try a.jcc(.ae, zero_lbl);
    // Reverse direction by the magnitude (`x << -n` == `x >> n`; for sar the reverse is
    // a logical left, exactly as for shr).
    if (op == .shl) try a.shrRegCl(W) else try a.shlRegCl(W);
    try a.jmp(done_lbl);

    a.bind(zero_lbl);
    try a.xorRegReg(W, W);
    if (op == .sar) {
        // zero_lbl falls through to done unless sar's sign leg follows; jump past it.
        try a.jmp(done_lbl);
        a.bind(sign_lbl);
        try a.sarRegImm8(W, 63); // broadcast bit 63 → all-ones (-1) or all-zeros (0)
    }

    a.bind(done_lbl);
    // Spilled dst: write the computed value back to its stack home.
    if (dst == .mem) try a.movMemReg(.rsp, dst.mem, W);
}

/// Lower a comparison `dst = pa <cc> pb` reading operands in place. Needs a register
/// on the left of `cmp`; stages `a` through rax only when it is spilled. The Bool
/// result lands in `dst` via setcc+movzx.
pub fn emitCompare(a: *x64.Assembler, op: trace.IrOp, dst: Place, pa: Place, pb: Place) !void {
    const lhs: Reg = switch (pa) {
        .reg => |r| r,
        .mem => |d| blk: {
            try a.movRegMem(.rax, .rsp, d);
            break :blk .rax;
        },
        .xmm => unreachable, // F1 admits only int compare operands (float compare is F2)
    };
    switch (pb) {
        .reg => |r| try a.cmpRegReg(lhs, r),
        .mem => |d| try a.cmpRegMem(lhs, .rsp, d),
        .xmm => unreachable, // F1 admits only int compare operands (float compare is F2)
    }
    const cc: x64.Cond = switch (op) {
        .eq => .e,
        .ne => .ne,
        .lt => .l,
        .le => .le,
        else => unreachable,
    };
    switch (dst) {
        .reg => |R| {
            try a.setcc(cc, R);
            try a.movzxRegReg8(R, R); // zero-extend the 0/1 byte to the full register
        },
        .mem => |D| {
            try a.setcc(cc, .rax);
            try a.movzxRegReg8(.rax, .rax);
            try a.movMemReg(.rsp, D, .rax);
        },
        .xmm => unreachable, // a comparison result is a bool, never homed in an XMM
    }
}

/// Lower heap-reference equality by stable `GcHeader.id`. Process-address
/// equality is not mahina identity: keyframe restore deliberately rebuilds the
/// graph at new addresses while preserving IDs. Both operand kinds (`.ptr` and
/// `.heap`) hold a non-null raw `*GcHeader` in a GP home.
pub fn emitHeapCompare(a: *x64.Assembler, op: trace.IrOp, dst: Place, pa: Place, pb: Place) !void {
    std.debug.assert(op == .eq or op == .ne);
    try placeToReg(a, .rax, pa);
    try a.movRegMem32(.rax, .rax, layout.GCHEADER_ID_OFF);
    try placeToReg(a, .rcx, pb);
    try a.movRegMem32(.rcx, .rcx, layout.GCHEADER_ID_OFF);
    try a.cmpRegReg(.rax, .rcx);
    const cc: x64.Cond = if (op == .eq) .e else .ne;
    switch (dst) {
        .reg => |R| {
            try a.setcc(cc, R);
            try a.movzxRegReg8(R, R);
        },
        .mem => |D| {
            try a.setcc(cc, .rax);
            try a.movzxRegReg8(.rax, .rax);
            try a.movMemReg(.rsp, D, .rax);
        },
        .xmm => unreachable,
    }
}

/// Lower a float comparison `dst = pa <cc> pb` (both operands proven `.float`; mixed
/// int/float compares bail in proveKinds). Stages operands into xmm0/xmm1, runs
/// `ucomisd`, and combines the NaN-aware flags into a clean 0/1 bool in rax, then to
/// `dst`. `ucomisd` sets only ZF/PF/CF (PF=1 ⇔ unordered/NaN); SF/OF are untouched, so
/// the unsigned-style conds (a/ae) + p/np are the correct readouts. Semantics mirror
/// `value.compareNumeric` for two f64s: a NaN operand makes lt/le/eq false and ne true.
///
/// [review] `ucomisd` (not `comisd`) is deliberate: it raises the invalid-operand flag
/// only for a *signaling* NaN, never a quiet one. The oracle short-circuits
/// `isNan(x) or isNan(y)`, so a qNaN lhs + sNaN rhs makes native touch the sNaN (setting
/// MXCSR.IE) where the oracle would not. This never diverges the boolean *result* — and
/// it is unobservable in mahina anyway: FP exceptions are masked (SysV default), there is
/// no MXCSR/feenableexcept seam, and a signaling NaN is unreachable from Lua source
/// (0.0/0.0 yields a quiet NaN; there is no sNaN literal).
pub fn emitFloatCompare(a: *x64.Assembler, op: trace.IrOp, dst: Place, pa: Place, pb: Place) !void {
    try floatOperandToXmm(a, XMM_SCRATCH0, pa, .float); // lhs
    try floatOperandToXmm(a, XMM_SCRATCH1, pb, .float); // rhs
    switch (op) {
        // a < b: compare (rhs ? lhs); `seta` = CF==0 && ZF==0 = rhs>lhs = a<b. A NaN
        // sets CF=1 → seta=0 (false), as required.
        .lt => {
            try a.ucomisdRegReg(XMM_SCRATCH1, XMM_SCRATCH0);
            try a.setcc(.a, .rax);
            try a.movzxRegReg8(.rax, .rax);
        },
        // a <= b: `setae` = CF==0 = rhs>=lhs = a<=b. NaN sets CF=1 → 0 (false).
        .le => {
            try a.ucomisdRegReg(XMM_SCRATCH1, XMM_SCRATCH0);
            try a.setcc(.ae, .rax);
            try a.movzxRegReg8(.rax, .rax);
        },
        // a == b, NaN→false: ordered (np) AND equal (ZF). On NaN, ZF=1 but PF=1 → np=0.
        .eq => {
            try a.ucomisdRegReg(XMM_SCRATCH0, XMM_SCRATCH1);
            try a.setcc(.e, .rax); // ZF: equal OR unordered
            try a.setcc(.np, .rcx); // ordered (not-parity)
            try a.movzxRegReg8(.rax, .rax);
            try a.movzxRegReg8(.rcx, .rcx);
            try a.andRegReg(.rax, .rcx);
        },
        // a != b, NaN→true: unordered (p) OR not-equal (!ZF). On NaN, ZF=1 → setne=0 but PF=1 → p=1.
        .ne => {
            try a.ucomisdRegReg(XMM_SCRATCH0, XMM_SCRATCH1);
            try a.setcc(.ne, .rax); // !ZF
            try a.setcc(.p, .rcx); // unordered (parity)
            try a.movzxRegReg8(.rax, .rax);
            try a.movzxRegReg8(.rcx, .rcx);
            try a.orRegReg(.rax, .rcx);
        },
        else => unreachable,
    }
    try regToPlace(a, dst, .rax);
}

/// Materialize a numeric operand into a scratch XMM (`dst_xmm`). A `.float` operand is
/// moved with `movsd`; an `.int` operand is promoted with `cvtsi2sd` (round-to-nearest,
/// bit-matching `@floatFromInt` in the strict-FP oracle). Operand homes are XMM/spill
/// (float) or GP/spill (int) — never the cross combination.
pub fn floatOperandToXmm(a: *x64.Assembler, dst_xmm: Reg, place: Place, kind: Kind) !void {
    switch (kind) {
        .float => switch (place) {
            .xmm => |x| try a.movsdRegReg(dst_xmm, x),
            .mem => |d| try a.movsdRegMem(dst_xmm, .rsp, d),
            .reg => unreachable, // a float never lives in a GP register
        },
        .int => switch (place) {
            .reg => |r| try a.cvtsi2sdRegReg(dst_xmm, r),
            .mem => |d| try a.cvtsi2sdRegMem(dst_xmm, .rsp, d),
            .xmm => unreachable, // an int never lives in an XMM register
        },
        else => unreachable, // proveKinds admits only int/float operands to a float op
    }
}

/// Lower a float binary op `dst = pa <op> pb`. Both operands are staged into the reserved
/// scratch XMMs (xmm0 = lhs, xmm1 = rhs; an int operand is `cvtsi2sd`-promoted), the SSE
/// op runs in xmm0 preserving operand order (matters for sub/div), then the result moves
/// to the home. Float coalescing is disabled in the first cut, so `dst` is xmm2..15 or a
/// spill cell — never a scratch XMM — and staging through xmm0/xmm1 cannot clobber it
/// before both operands are read (so `x*x` and reused-register dsts are safe).
pub fn emitFloatBinOp(a: *x64.Assembler, op: trace.IrOp, dst: Place, pa: Place, ka: Kind, pb: Place, kb: Kind) !void {
    try floatOperandToXmm(a, XMM_SCRATCH0, pa, ka);
    try floatOperandToXmm(a, XMM_SCRATCH1, pb, kb);
    switch (op) {
        .add => try a.addsdRegReg(XMM_SCRATCH0, XMM_SCRATCH1),
        .sub => try a.subsdRegReg(XMM_SCRATCH0, XMM_SCRATCH1),
        .mul => try a.mulsdRegReg(XMM_SCRATCH0, XMM_SCRATCH1),
        .div => try a.divsdRegReg(XMM_SCRATCH0, XMM_SCRATCH1),
        else => unreachable,
    }
    switch (dst) {
        .xmm => |x| if (x != XMM_SCRATCH0) try a.movsdRegReg(x, XMM_SCRATCH0),
        .mem => |d| try a.movsdMemReg(.rsp, d, XMM_SCRATCH0),
        .reg => unreachable, // a float result never homes in a GP register
    }
}

/// Flush one slot's `Value` into the SoA register file: the 1-byte tag into
/// `tags[slot]` (rdi, scale-1) and the 8 payload bytes into `payloads[slot]` (rsi,
/// scale-8). The tag is written with a single-byte store (NOT the old 4-byte
/// `movMemImm32`, which under SoA would clobber the next three slots' tag bytes).
/// The payload source is a `Place`: a GP reg / spill cell raw-copies the 8 bytes
/// (int/bool); an XMM home stores the double with `movsd` (float). rax is the
/// scratch for a spilled payload.
pub fn boxedTagSpill(t: *const Trace, kinds: []const Kind, alloc: *const Alloc, ref: usize) !u32 {
    if (ref >= t.instrs.len or kinds[ref] != .boxed or t.instrs[ref].op != .slot_load) return error.Unsupported;
    var ordinal: u32 = 0;
    for (kinds[0..ref]) |kind| if (kind == .boxed) {
        ordinal += 1;
    };
    return alloc.spill_count + ordinal;
}

pub fn snapshotBoxedTags(a: *x64.Assembler, t: *const Trace, kinds: []const Kind, alloc: *const Alloc) !void {
    // Snapshot every admitted boxed source before *any* destination tag store:
    // phi writes are parallel, and reading tags during a swap/cycle would pair a
    // preserved payload with an already-overwritten tag.
    for (kinds, 0..) |kind, ref| {
        if (kind != .boxed) continue;
        const spill = try boxedTagSpill(t, kinds, alloc, ref);
        try a.movzxRegMem8(.rax, .rdi, t.instrs[ref].aux);
        try a.movMemReg(.rsp, @as(i32, @intCast(spill)) * 8, .rax);
    }
}

pub fn flushBoxedSlot(a: *x64.Assembler, dst_slot: i32, tag_spill: u32, payload: Place) !void {
    // Payload was loaded into its ordinary GP/spill home. The independent tag
    // came from the actual phi source and was snapshotted before destination
    // mutation, so write-only destinations and arbitrary parallel copies work.
    try a.movzxRegMem8(.rax, .rsp, @as(i32, @intCast(tag_spill)) * 8);
    try a.movByteMemReg(.rdi, dst_slot, .rax);
    const poff: i32 = dst_slot * 8;
    switch (payload) {
        .reg => |r| try a.movMemReg(.rsi, poff, r),
        .mem => |d| {
            try a.movRegMem(.rax, .rsp, d);
            try a.movMemReg(.rsi, poff, .rax);
        },
        .xmm => unreachable,
    }
}

pub fn flushSlot(a: *x64.Assembler, slot: i32, kind: Kind, payload: Place) !void {
    std.debug.assert(kind != .boxed);
    const tag: u8 = switch (kind) {
        .nil => @intFromEnum(value.Tag.nil),
        .bool => TAG_BOOL,
        .float => TAG_FLOAT,
        // `.ptr` (invariant table), `.heap` (per-iteration table — a carried-heap
        // slot's current value or a write-only VALUE_LANE aload result), and
        // `.func` (a guard_func-covered closure, flushed by a head trace's φ
        // writeback — doc 44) all hold a raw *GcHeader payload and re-box as a
        // heap ref.
        .ptr, .heap, .func => TAG_HEAP,
        else => TAG_INT,
    };
    const poff: i32 = slot * 8;
    try a.movByteMemImm(.rdi, slot, tag);
    switch (payload) {
        .reg => |r| try a.movMemReg(.rsi, poff, r),
        .xmm => |x| try a.movsdMemReg(.rsi, poff, x),
        .mem => |d| {
            try a.movRegMem(.rax, .rsp, d);
            try a.movMemReg(.rsi, poff, .rax);
        },
    }
}

/// `dst <- src` between two Places. A mem→mem move routes through rax (raw 8 bytes —
/// kind-agnostic, so it serves int and float spill cells alike). A parallel-move cycle is
/// always single-class (a move connects xmm↔xmm/mem or reg↔reg/mem, never xmm↔reg — see
/// `analyze`), so the float/int endpoint combinations below are the only ones that occur.
pub fn movePlace(a: *x64.Assembler, dst: Place, src: Place) !void {
    if (Place.eql(dst, src)) return;
    switch (dst) {
        .reg => |r| try placeToReg(a, r, src),
        .xmm => |dx| switch (src) {
            .xmm => |sx| try a.movsdRegReg(dx, sx),
            .mem => |sd| try a.movsdRegMem(dx, .rsp, sd),
            .reg => unreachable, // a float src never lives in a GP register
        },
        .mem => |d| switch (src) {
            .reg => |sr| try a.movMemReg(.rsp, d, sr),
            .xmm => |sx| try a.movsdMemReg(.rsp, d, sx),
            .mem => |sd| {
                try a.movRegMem(.rax, .rsp, sd);
                try a.movMemReg(.rsp, d, .rax);
            },
        },
    }
}

/// One PHI back-edge move. `is_float` records the carried slot's class so the cycle
/// breaker picks the matching scratch (xmm1 for float, rcx for int) — needed because a
/// `.mem` (spill) endpoint alone does not reveal the value's class.
pub const Move = struct { dst: Place, src: Place, is_float: bool = false };

/// Emit a parallel move (the back-edge PHI shuffle): all `dst <- src` happen as if
/// simultaneously. Acyclic moves go first (Kahn); each remaining disjoint cycle is
/// broken with rcx (saving the cycle's start value), fully, before the next. rax is
/// the mem↔mem scratch inside `movePlace`; the two never collide.
pub fn emitParallelMove(a: *x64.Assembler, moves: []Move, done: []bool) !void {
    @memset(done, false);
    var left = moves.len;

    var progress = true;
    while (progress and left > 0) {
        progress = false;
        for (moves, 0..) |m, i| {
            if (done[i]) continue;
            var blocked = false;
            for (moves, 0..) |o, j| {
                if (done[j] or j == i) continue;
                if (Place.eql(o.src, m.dst)) {
                    blocked = true;
                    break;
                }
            }
            if (blocked) continue;
            try movePlace(a, m.dst, m.src);
            done[i] = true;
            left -= 1;
            progress = true;
        }
    }

    for (moves, 0..) |_, start| {
        if (done[start]) continue;
        // Save the cycle's start value in a scratch matching the cycle's class (a cycle
        // is wholly int or wholly float). float → xmm1 (movsd), int → rcx (raw bytes,
        // works for both reg and spill endpoints).
        const fcycle = moves[start].is_float;
        if (fcycle) {
            switch (moves[start].dst) {
                .xmm => |x| try a.movsdRegReg(XMM_SCRATCH1, x),
                .mem => |d| try a.movsdRegMem(XMM_SCRATCH1, .rsp, d),
                .reg => unreachable,
            }
        } else {
            try placeToReg(a, .rcx, moves[start].dst);
        }
        var cur = start;
        while (true) {
            const m = moves[cur];
            done[cur] = true;
            left -= 1;
            var nxt: ?usize = null;
            for (moves, 0..) |o, j| {
                if (done[j]) continue;
                if (Place.eql(o.dst, m.src)) {
                    nxt = j;
                    break;
                }
            }
            if (nxt) |j| {
                try movePlace(a, m.dst, m.src);
                cur = j;
            } else {
                // m.src is the (clobbered) cycle start; restore from the saved scratch.
                if (fcycle) {
                    switch (m.dst) {
                        .xmm => |x| try a.movsdRegReg(x, XMM_SCRATCH1),
                        .mem => |d| try a.movsdMemReg(.rsp, d, XMM_SCRATCH1),
                        .reg => unreachable,
                    }
                } else {
                    try regToPlace(a, m.dst, .rcx);
                }
                break;
            }
        }
    }
    std.debug.assert(left == 0);
}

/// Restore the stack/callee-saved state and return. Self-framed epilogue.
pub fn emitTeardown(a: *x64.Assembler, frame: i32, callee: []const Reg) !void {
    if (frame > 0) try a.addRegImm32(.rsp, frame);
    var k = callee.len;
    while (k > 0) {
        k -= 1;
        try a.pop(callee[k]);
    }
    try a.pop(.rbx);
    try a.ret();
}

/// Emit a trace's return path. Self-framed (`shared_exit == null`, test path): tear
/// down the per-trace frame + callee-saved and `ret`. Frameless (`shared_exit` set,
/// production path): the shared trampoline owns the frame, so just leave to its
/// teardown. rax is dead scratch at every exit site (the slot flush + result writes
/// are already done), so it is free to hold the target address.
///
/// `slot_addr` (doc 17 Increment 2.3) is the absolute address of this exit's link
/// slot when the exit is *chainable* (the `.link` terminal / a linked-loop-done
/// stub). When set (frameless only), the exit becomes an indirect
/// `movabs rax, slot_addr; jmp qword [rax]` — the slot holds `shared_exit` by default
/// (byte-identical to the direct jump) and a child body entry once `driveChain` arms
/// it. When null, the exit jumps directly to `shared_exit` as in 2.1 (used by the
/// non-chainable `deopt_exit` fallback and `prologue_fail`).
pub fn emitReturn(a: *x64.Assembler, frame: i32, callee: []const Reg, shared_exit: ?usize, trace_id: u32, slot_addr: ?usize) !void {
    // P-B (doc 17): stamp the final trace's stable id into the result. rdx still holds
    // the *NativeResult at every exit site (it is reserved for the whole body). Baked
    // as an imm32 (the trace's own id here; a linked child overwrites it in 2.3).
    try a.movMemImm32(.rdx, @offsetOf(NativeResult, "final_trace_id"), @bitCast(trace_id));
    if (shared_exit) |se| {
        if (slot_addr) |sa| {
            // Indirect through the link slot: load the slot's current target VALUE
            // (default `shared_exit`, or an armed child body entry) into rax, apply the
            // 2.3c-2c forced-yield cap (redirects an armed dispatch to `shared_exit` when
            // the ledger is full), then jump. Loading the value (vs. the old `jmp [slot]`
            // through memory) is what lets the cap inspect and, if needed, override it.
            try a.movRegImm64(.rax, @bitCast(@as(u64, sa)));
            try a.movRegMem(.rax, .rax, 0);
            try emitForcedYieldCheck(a, se);
            try a.jmpReg(.rax);
        } else {
            try a.movRegImm64(.rax, @bitCast(@as(u64, se)));
            try a.jmpReg(.rax);
        }
    } else {
        try emitTeardown(a, frame, callee);
    }
}

/// Absolute address of the link slot for IR instruction `idx`, or null when there is
/// no slot table (self-framed test page). Baked into the exit as an imm64 so the
/// `jmp qword [rax]` reaches the slot regardless of where the heap array lives.
pub fn slotAddr(slots: []usize, idx: usize) ?usize {
    if (slots.len == 0) return null;
    return @intFromPtr(&slots[idx]);
}

/// 2.3c-2a (doc 17): append one per-transition entry to `NativeResult`'s ledger at
/// index `ledger_len`, then bump the length — the mechanism that lets a fused native
/// span (`C→I→C→…` chained under the shared frame) recover the HIDDEN intermediate
/// exits its single returned `NativeResult` would otherwise drop. Records the cumulative
/// `rbx` counter (`ledger_cum`, scale-8) plus `trace_id` (imm) and the already-in-memory
/// `exit_instr` / `exit_reason` (scale-4 parallel arrays). EVERY exit site calls this
/// AFTER it has written `NativeResult.exit_instr` and `NativeResult.exit_reason` (so the
/// reads below see THIS exit's values — `exit_reason` stays the wrapper-init `.normal`
/// at every site except `prologue_fail`, which writes it first, and `prologue_fail` is
/// terminal so it never rides mid-span) and BEFORE it dispatches (so a chain-source exit
/// records itself before jumping into the child). Clobbers rax (index) and rcx (staging)
/// — both dead scratch at every exit; rbx is the live cumulative counter, rdx the
/// `*NativeResult`.
///
/// Bounds-guarded: when the ledger is at `LEDGER_CAP` the entry is DROPPED (span
/// continues). That is inert while nothing forms a native cycle — 2.3c-2a/b spans are a
/// handful of hops, far below the cap — and 2.3c-2c replaces the drop at chain-SOURCE
/// sites with a forced yield to `shared_exit` so a closed cycle can never silently lose
/// a hop.
pub fn emitLedgerAppend(a: *x64.Assembler, trace_id: u32, kind: trace_exec.LedgerKind) !void {
    const full = try a.label();
    // rax = ledger_len; drop the entry if already at capacity (unreachable pre-cycle).
    try a.movRegMem(.rax, .rdx, @offsetOf(NativeResult, "ledger_len"));
    try a.cmpRegImm32(.rax, @intCast(trace_exec.LEDGER_CAP));
    try a.jcc(.ae, full);
    // ledger_cum[rax] = rbx  (usize lane, SIB scale 8)
    try a.storeMemSibReg(.rdx, .rax, 8, @offsetOf(NativeResult, "ledger_cum"), .rbx);
    // ledger_id[rax] = trace_id  (u32 lane; imm staged in rcx, scale 4)
    try a.movRegImm64(.rcx, @intCast(trace_id));
    try a.storeMemSibReg(.rdx, .rax, 4, @offsetOf(NativeResult, "ledger_id"), .rcx);
    // ledger_exit[rax] = NativeResult.exit_instr  (8-byte load, low 32 stored)
    try a.movRegMem(.rcx, .rdx, @offsetOf(NativeResult, "exit_instr"));
    try a.storeMemSibReg(.rdx, .rax, 4, @offsetOf(NativeResult, "ledger_exit"), .rcx);
    // ledger_reason[rax] = NativeResult.exit_reason
    try a.movRegMem(.rcx, .rdx, @offsetOf(NativeResult, "exit_reason"));
    try a.storeMemSibReg(.rdx, .rax, 4, @offsetOf(NativeResult, "ledger_reason"), .rcx);
    // 2.3c-2c: ledger_kind[rax] = kind  (u32 lane; per-site compile-time constant).
    try a.movRegImm64(.rcx, @intCast(@intFromEnum(kind)));
    try a.storeMemSibReg(.rdx, .rax, 4, @offsetOf(NativeResult, "ledger_kind"), .rcx);
    // 2.3c-2c: ledger_outcome[rax] = .normal (0). A chain-source forced yield
    // (`emitForcedYieldCheck`) overwrites this entry to `.yielded` when the ledger is
    // full; otherwise it stays `.normal` (dispatched-or-terminal, positionally resolved).
    try a.movRegImm64(.rcx, @intCast(@intFromEnum(trace_exec.LedgerOutcome.normal)));
    try a.storeMemSibReg(.rdx, .rax, 4, @offsetOf(NativeResult, "ledger_outcome"), .rcx);
    // ledger_len = rax + 1
    try a.incReg(.rax);
    try a.movMemReg(.rdx, @offsetOf(NativeResult, "ledger_len"), .rax);
    a.bind(full);
}

/// 2.3c-2c (doc 17): the forced-yield cap. Emitted at every frameless chain-source
/// dispatch, AFTER `emitLedgerAppend` and BEFORE the `jmp`. On entry `rax` holds the
/// resolved dispatch target — an armed child body entry, or `shared_exit` when the
/// slot is unarmed. Contract:
///   * unarmed (`rax == shared_exit`)         → leave `rax`, fall through (natural terminal / plain deopt);
///   * armed + ledger has room (`len < CAP`)  → leave `rax`, fall through (dispatch into the child);
///   * armed + ledger FULL (`len == CAP`)     → mark the just-appended terminal entry
///       `.yielded` and rewrite `rax = shared_exit`, so a closed native cycle returns to
///       the driver instead of running an unrecordable hop.
/// Leaves `rax` = the (possibly rewritten) jmp target; the caller does `jmp rax`.
/// Clobbers `rcx` (dead scratch — `emitLedgerAppend` just clobbered it). `rbx` (live
/// cumulative counter) and `rdx` (`*NativeResult`) are untouched.
///
/// DEAD until 2.3c-2e closes the `I→C` cycle: pre-cycle every span is ≤2 entries « CAP
/// (32), so the ledger never fills and the yield branch never executes — byte-identical.
pub fn emitForcedYieldCheck(a: *x64.Assembler, shared_exit: usize) !void {
    const do_jmp = try a.label();
    // rcx = shared_exit. Unarmed target (rax == shared_exit) → nothing to cap.
    try a.movRegImm64(.rcx, @bitCast(@as(u64, shared_exit)));
    try a.cmpRegReg(.rax, .rcx);
    try a.jcc(.e, do_jmp);
    // Armed. Room left in the ledger (ledger_len < CAP) → dispatch into the child.
    try a.cmpQwordMemImm8(.rdx, @offsetOf(NativeResult, "ledger_len"), @intCast(trace_exec.LEDGER_CAP));
    try a.jcc(.b, do_jmp);
    // Armed AND full → forced yield. Mark the just-appended terminal entry (index
    // ledger_len − 1) `.yielded`, then redirect the dispatch to `shared_exit`.
    try a.movRegMem(.rcx, .rdx, @offsetOf(NativeResult, "ledger_len"));
    try a.subRegImm32(.rcx, 1);
    // Stage the `.yielded` code in rax (free — reloaded with shared_exit right after),
    // store it into ledger_outcome[rcx] (u32 lane, scale 4).
    try a.movRegImm64(.rax, @intCast(@intFromEnum(trace_exec.LedgerOutcome.yielded)));
    try a.storeMemSibReg(.rdx, .rcx, 4, @offsetOf(NativeResult, "ledger_outcome"), .rax);
    try a.movRegImm64(.rax, @bitCast(@as(u64, shared_exit)));
    a.bind(do_jmp);
}

/// Doc 54 P0: everything the inline self-call push needs that is knowable at
/// commit time. `callee_slot`/`nargs`/`ret_count` are the `.call`
/// instruction's a/b/c fields (statically eligible: `.call`, `b !=
/// all_results`, non-vararg proto, `term_aux` in bounds — checked by the
/// caller, so they are plain immediates here); `proto_addr` is the baked
/// `t.anchor.proto` the callee guard pins against (pointer identity, exactly
/// the helper's `cl.proto != proto` — proto-not-closure-identity, so a
/// same-proto different-upvalue closure descends with ITS OWN closure
/// pointer in the frame).
pub const InlineSelfPush = struct {
    callee_slot: u16,
    nargs: u16,
    ret_count: u16,
    term_aux: i32,
    num_params: u8,
    nreg: i32,
    proto_addr: u64,
};

/// Doc 54 P0: the inline same-page self-call frame push — the emitted twin of
/// `interp.nativeSelfCallPush` for HEAD pages, replacing the C-ABI callout.
/// Emitted between the terminal's slot flush and the plain terminal exit;
/// every check the helper re-derived per push is now either an emit-time
/// constant (static eligibility, the caller's job), the per-episode
/// `descent_ok` byte (receipts inert ∧ no pending reg-top ∧ no final cut),
/// or one of the inline walls below. "Decline" = `jne/ja` to `decline`
/// (the plain terminal exit) with NOTHING mutated — every store sits after
/// the last wall, the helper's own ordering.
///
/// Register bracket: rdi/rsi (lanes), rdx (`*NativeResult`), rbx (cumulative
/// counter) are the only live registers at a terminal epilogue (homes just
/// flushed); rax/rcx/r8-r11 are dead scratch. Allocation here: r9 = `&ctx`,
/// r8 = `*Vm` (loaded per push — `Vm` is movable, never baked), r11 = the
/// guarded callee closure (header == closure address, asserted in
/// `nativegen_layout`), rcx = caller base then callee base, rax = frame
/// pointer then depth, r10 = scratch / the new frame's `call_seq`.
///
/// On the taken path this replicates `opCall`'s Lua-closure arm byte-for-
/// byte in VM-state effect: caller one-past-call cursor freeze, callee
/// window init (params copied, rest nil with zero payloads — `fillNil`
/// parity), the `pushFrameVararg` frame write (including the doc-20
/// code-cache invalidation via the `CODE_CACHE_GEN_INVALID` qword and the
/// `call_seq` mint), depth/stack_top, `setRegionContext`'s three stores,
/// the call-entry tick, the episode-ctx refresh, and the
/// `self_call_pushes` witness — then bumps `pushed_frames`, resets
/// `linked_loop_done` (ordinary-entry replica), shifts the lanes onto the
/// pushed window and re-enters `body_entry`.
pub fn emitInlineSelfPush(
    a: *x64.Assembler,
    ctx: *const trace_code.NativeSeedCtx,
    abi: trace_code.FrameMotionAbi,
    p: InlineSelfPush,
    body_entry: x64.Label,
    decline: x64.Label,
) !void {
    const Ctx = trace_code.NativeSeedCtx;
    // -- step 1: episode descent gate ------------------------------------
    try a.movRegImm64(.r9, @bitCast(@as(u64, @intFromPtr(ctx))));
    try a.cmpByteMemImm(.r9, @offsetOf(Ctx, "descent_ok"), 1);
    try a.jcc(.ne, decline);
    try a.movRegMem(.r8, .r9, @offsetOf(Ctx, "vm"));
    // -- step 2: callee guard (tag, object type, proto pin) --------------
    const cs: i32 = p.callee_slot;
    try a.cmpByteMemImm(.rdi, cs, TAG_HEAP);
    try a.jcc(.ne, decline);
    try a.movRegMem(.r11, .rsi, cs * 8);
    try a.cmpByteMemImm(.r11, HEADER_TYPE_OFF, layout.FUNCTION_TYPE);
    try a.jcc(.ne, decline);
    try a.movRegMem(.r10, .r11, layout.CLOSURE_PROTO_OFF);
    try a.movRegImm64(.rax, @bitCast(p.proto_addr));
    try a.cmpRegReg(.r10, .rax);
    try a.jcc(.ne, decline);
    // -- step 3: walls (depth, register capacity, call_seq space) --------
    try a.cmpDwordMemImm(.r8, abi.vm_depth_off, abi.max_call_depth);
    try a.jcc(.ae, decline);
    // callee_base + nreg = ctx.base + 2*nreg must fit the slab.
    try a.movRegMem(.rcx, .r9, @offsetOf(Ctx, "base"));
    try a.movRegReg(.r10, .rcx);
    try a.addRegImm32(.r10, p.nreg * 2);
    try a.cmpRegMem(.r10, .r9, @offsetOf(Ctx, "reg_capacity"));
    try a.jcc(.a, decline);
    // next_call_seq == maxInt(u64) → decline (tier-0 re-runs and panics).
    try a.cmpQwordMemImm8(.r8, abi.vm_next_call_seq_off, -1);
    try a.jcc(.e, decline);
    // -- step 4: caller one-past-call resume-cursor freeze ---------------
    // rax = &frames[depth-1] (byte address; frame_size is not a power of
    // two, so multiply through a scratch immediate).
    try a.movRegMem32(.rax, .r8, abi.vm_depth_off);
    try a.subRegImm32(.rax, 1);
    try a.movRegImm64(.r10, abi.frame_size);
    try a.imulRegReg(.rax, .r10);
    try a.addRegReg(.rax, .r8);
    try a.addRegImm32(.rax, abi.vm_frames_off);
    try a.movMemImm32(.rax, abi.frame_pc_off, p.term_aux + 1);
    // -- step 5: callee window init (fully unrolled) ---------------------
    // Destination slot j lives at lane offset nreg+j of the CURRENT window
    // (window adjacency: callee_base = base + nreg). Copy bound params from
    // caller slots callee_slot+1+j; nil-fill the rest with zero payloads
    // (`fillNil`/`Value.nil()` parity — byte-identical slab bytes).
    var j: i32 = 0;
    while (j < p.nreg) : (j += 1) {
        const dst = p.nreg + j;
        if (j < p.num_params and j < p.nargs) {
            const src = cs + 1 + j;
            try a.movzxRegMem8(.r10, .rdi, src);
            try a.movByteMemReg(.rdi, dst, .r10);
            try a.movRegMem(.r10, .rsi, src * 8);
            try a.movMemReg(.rsi, dst * 8, .r10);
        } else {
            try a.movByteMemImm(.rdi, dst, TAG_NIL);
            try a.movMemImm32(.rsi, dst * 8, 0);
        }
    }
    // -- step 6: the frame write at frames[depth] ------------------------
    try a.addRegImm32(.rax, abi.frame_size); // rax = &frames[depth]
    try a.movMemReg(.rax, abi.frame_closure_off, .r11);
    // ret wiring first: r10 doubles as the u16 immediate stage before it
    // takes the minted call_seq.
    try a.movRegImm64(.r10, p.ret_count);
    try a.storeMemReg(.rax, 2, abi.frame_ret_count_off, .r10);
    try a.movRegImm64(.r10, p.callee_slot);
    try a.storeMemReg(.rax, 2, abi.frame_ret_dest_off, .r10);
    // call_seq mint: frame.call_seq = next_call_seq; next_call_seq += 1.
    try a.movRegMem(.r10, .r8, abi.vm_next_call_seq_off);
    try a.movMemReg(.rax, abi.frame_call_seq_off, .r10);
    try a.addRegImm32(.r10, 1);
    try a.movMemReg(.r8, abi.vm_next_call_seq_off, .r10);
    try a.subRegImm32(.r10, 1); // r10 = the minted call_seq, kept for step 7/8
    try a.addRegImm32(.rcx, p.nreg); // rcx = callee_base
    try a.movMemReg(.rax, abi.frame_base_off, .rcx);
    try a.movMemImm32(.rax, abi.frame_pc_off, 0);
    try a.movMemImm32(.rax, abi.frame_varargs_base_off, 0);
    try a.movMemImm32(.rax, abi.frame_varargs_count_off, 0);
    // Doc-20 fetch-image cache invalidation (the struct-literal default):
    // qword -1 == CODE_CACHE_GEN_INVALID.
    try a.movMemImm32(.rax, abi.frame_code_cache_gen_off, -1);
    // ctx.base refresh now, while rcx still holds callee_base (step 8's
    // base half, hoisted — nothing observes ctx mid-sequence).
    try a.movMemReg(.r9, @offsetOf(Ctx, "base"), .rcx);
    // -- step 7: depth, stack_top, region context, tick ------------------
    try a.movRegMem32(.rax, .r8, abi.vm_depth_off);
    try a.addRegImm32(.rax, 1);
    try a.movMemReg32(.r8, abi.vm_depth_off, .rax); // rax = new depth
    try a.addRegImm32(.rcx, p.nreg); // rcx = callee_base + nreg = new stack_top
    try a.movMemReg(.r8, abi.vm_stack_top_off, .rcx);
    // setRegionContext(new_depth, call_seq): payload dword + qword, then
    // the validity byte (doc 54 P0 field split).
    try a.movMemReg32(.r8, abi.vm_region_depth_off, .rax);
    try a.movMemReg(.r8, abi.vm_region_call_seq_off, .r10);
    try a.movByteMemImm(.r8, abi.vm_region_valid_off, 1);
    // tickCallEntry: tick +%= 1 (success only, after the push — tier-0 order).
    try a.incMemQword(.r8, abi.vm_tick_off);
    // -- step 8: episode-ctx refresh (closure + call_seq; base done above,
    // proto/reg_capacity/vm/descent_ok episode-invariant) ----------------
    try a.movMemReg(.r9, @offsetOf(Ctx, "closure"), .r11);
    try a.movMemReg(.r9, @offsetOf(Ctx, "call_seq"), .r10);
    // -- step 9: witnesses, lane shift, re-entry -------------------------
    try a.incMemQword(.r8, abi.vm_self_call_pushes_off);
    try a.movRegMem(.rax, .rdx, @offsetOf(NativeResult, "pushed_frames"));
    try a.addRegImm32(.rax, 1);
    try a.movMemReg(.rdx, @offsetOf(NativeResult, "pushed_frames"), .rax);
    try a.movMemImm32(.rdx, @offsetOf(NativeResult, "linked_loop_done"), 0);
    try a.addRegImm32(.rdi, p.nreg);
    try a.addRegImm32(.rsi, p.nreg * 8);
    try a.jmp(body_entry);
}

pub const InlineSelfRetPop = struct {
    /// `instr.a` of the static `.ret` — the result window's first slot.
    a_reg: i32,
    /// `instr.b` — the produced result count (never `all_results`; static).
    count: i32,
    nreg: i32,
};

/// Doc 54 P1: the inline return-side frame pop — the emitted twin of the
/// (deleted) `interp.nativeSelfRetPop` C-ABI helper, mirroring `opRet`'s
/// non-boundary arm for an episode-pushed same-proto frame. Emitted at a
/// `.terminal(return_interp)` between the slot flush and the `.ret_pop`
/// ledger/compare-chain continuation; a decline (`jne/ja/je` to `no_pop`)
/// mutates NOTHING and the page runs its plain terminal exit (tier-0
/// re-executes the `ret` generically) — byte-identical to the helper's
/// decline.
///
/// The helper's per-pop preflight maps to:
/// - emit-time statics (caller's job): aux in bounds, `.ret`,
///   `b != all_results`, `!is_vararg`, `a + b <= nreg`;
/// - the per-episode `descent_ok` byte (receipts inert ∧ no pending
///   reg-top ∧ no final cut);
/// - inline runtime checks: the net-pushed floor, the open-upvalue
///   CEILING compare (`open_upvalue_ceiling <= frame.base` ⇒ no open cell
///   at or above the popped window — the watermark replaces the helper's
///   full-list scan), and the dynamic return wiring
///   (`ret_count != all_results`, `ret_dest + want <= nreg`);
/// - episode-structural invariants, each asserted by the jit-debug-only
///   `frame_motion_assert_fn` callout: depth ≥ 2, `frame.base == ctx.base`,
///   `frame.call_seq == ctx.call_seq`, frame/parent proto pins, window
///   adjacency, and `activeRegionFor(call_seq) == null` (why the region-
///   activation drop reduces to the context-clear replica below).
///
/// Register bracket (same terminal-epilogue facts as the push): rdi/rsi
/// (lanes, still on the CALLEE window — the armed ret-cont chain shifts
/// them, not this sequence), rdx (`*NativeResult`), rbx (cumulative
/// counter) stay untouched; rax/rcx/r8-r11 are dead scratch. During the
/// copy loop r8/r9 serve as dst-index/payload staging and are recomputed
/// after (r9 is baked, r8 reloads from ctx); rax holds the frame pointer,
/// recomputed after the loop.
///
/// On the taken (fall-through) path this replicates `opRet`'s non-boundary
/// arm in VM-state effect: result copy into the parent window WHILE the
/// callee window is still under `stack_top` (rooting order), the
/// `dropRegionActivation` residue under the descent gate (just the
/// region-context validity clear when the popped `call_seq` matches — zero
/// activations exist, assert-verified), `depth -= 1`, `stack_top =
/// parent.base + nreg`, the episode-ctx refresh onto the caller activation
/// (closure/base/call_seq; proto and capacity episode-invariant), the
/// `ret_resume_pc` publication from the parent's frozen cursor, and the
/// `self_ret_pops` witness. No tick — `opRet` does not tick; the tick
/// stream stays a pure function of the call stream.
pub fn emitInlineSelfRetPop(
    a: *x64.Assembler,
    ctx: *const trace_code.NativeSeedCtx,
    abi: trace_code.FrameMotionAbi,
    p: InlineSelfRetPop,
    no_pop: x64.Label,
) !void {
    const Ctx = trace_code.NativeSeedCtx;
    const all_results: i32 = @import("bytecode.zig").all_results;
    // -- step 1: episode descent gate ------------------------------------
    try a.movRegImm64(.r9, @bitCast(@as(u64, @intFromPtr(ctx))));
    try a.cmpByteMemImm(.r9, @offsetOf(Ctx, "descent_ok"), 1);
    try a.jcc(.ne, no_pop);
    // -- step 2: the net-pushed floor (an episode only pops frames IT
    // pushed; the entry frame's own return stays tier-0) -----------------
    try a.movRegMem(.rax, .rdx, @offsetOf(NativeResult, "pushed_frames"));
    try a.subRegMem(.rax, .rdx, @offsetOf(NativeResult, "popped_frames"));
    try a.jcc(.e, no_pop);
    // -- step 2b (jit-debug builds only): the structural-invariant assert
    // callout. Premised on net > 0 (episode-pushed top frame), so it sits
    // here; the invariants hold whether or not a later wall declines.
    // Same three-push bracket as the old helpers: rsp ≡8 → ≡0, aligned.
    if (ctx.frame_motion_assert_fn) |assert_fn| {
        try a.push(.rdi);
        try a.push(.rsi);
        try a.push(.rdx);
        try a.movRegImm64(.rdi, @bitCast(@as(u64, @intFromPtr(ctx))));
        try a.movRegImm64(.rsi, p.nreg);
        try a.movRegImm64(.rax, @bitCast(@as(u64, @intFromPtr(assert_fn))));
        try a.callReg(.rax);
        try a.pop(.rdx);
        try a.pop(.rsi);
        try a.pop(.rdi);
        try a.movRegImm64(.r9, @bitCast(@as(u64, @intFromPtr(ctx))));
    }
    try a.movRegMem(.r8, .r9, @offsetOf(Ctx, "vm"));
    // -- step 3: rax = &frames[depth-1] (the popped frame) ---------------
    try a.movRegMem32(.rax, .r8, abi.vm_depth_off);
    try a.subRegImm32(.rax, 1);
    try a.movRegImm64(.r10, abi.frame_size);
    try a.imulRegReg(.rax, .r10);
    try a.addRegReg(.rax, .r8);
    try a.addRegImm32(.rax, abi.vm_frames_off);
    // -- step 4: open-upvalue ceiling wall (the watermark replaces the
    // helper's full open-list scan; stale-HIGH only declines) ------------
    try a.movRegMem(.rcx, .r8, abi.vm_open_upvalue_ceiling_off);
    try a.cmpRegMem(.rcx, .rax, abi.frame_base_off);
    try a.jcc(.a, no_pop);
    // -- step 5: dynamic return wiring (the frame may have been pushed by
    // a DIFFERENT call site than this ret's — fib's two sites) -----------
    try a.movzxRegMem16(.r11, .rax, abi.frame_ret_count_off); // r11 = want
    try a.cmpRegImm32(.r11, all_results);
    try a.jcc(.e, no_pop);
    try a.movzxRegMem16(.r10, .rax, abi.frame_ret_dest_off); // r10 = dst reg
    try a.movRegReg(.rcx, .r10);
    try a.addRegReg(.rcx, .r11);
    try a.cmpRegImm32(.rcx, p.nreg);
    try a.jcc(.a, no_pop);
    // -- step 6: result copy (opRet order: while the callee window is
    // still under stack_top; nil-fill the tail past `count`). Src slot
    // a_reg+k of the CALLEE window (lanes); dst slot ret_dest+k of the
    // PARENT window = lane index ret_dest-nreg+k (window adjacency).
    try a.subRegImm32(.r10, p.nreg); // r10 = ret_dest - nreg (signed dst base)
    try a.xorRegReg(.rcx, .rcx); // rcx = k
    const loop_top = try a.label();
    const loop_done = try a.label();
    const nil_case = try a.label();
    const next = try a.label();
    a.bind(loop_top);
    try a.cmpRegReg(.rcx, .r11);
    try a.jcc(.ae, loop_done);
    try a.movRegReg(.r8, .rcx); // r8 = dst lane index (vm reloaded after)
    try a.addRegReg(.r8, .r10);
    try a.cmpRegImm32(.rcx, p.count);
    try a.jcc(.ae, nil_case);
    try a.loadRegMemSib(.rax, .rdi, .rcx, 1, false, p.a_reg);
    try a.storeMemSibReg(.rdi, .r8, 1, 0, .rax);
    try a.loadRegMemSib(.r9, .rsi, .rcx, 8, false, p.a_reg * 8);
    try a.storeMemSibReg(.rsi, .r8, 8, 0, .r9);
    try a.jmp(next);
    a.bind(nil_case);
    try a.movRegImm64(.rax, TAG_NIL);
    try a.storeMemSibReg(.rdi, .r8, 1, 0, .rax);
    try a.xorRegReg(.r9, .r9);
    try a.storeMemSibReg(.rsi, .r8, 8, 0, .r9);
    a.bind(next);
    try a.incReg(.rcx);
    try a.jmp(loop_top);
    a.bind(loop_done);
    // -- step 7: recompute the loop-clobbered pointers (r9 is baked; the
    // frame pointer re-derives from the still-unmutated depth) -----------
    try a.movRegImm64(.r9, @bitCast(@as(u64, @intFromPtr(ctx))));
    try a.movRegMem(.r8, .r9, @offsetOf(Ctx, "vm"));
    try a.movRegMem32(.rax, .r8, abi.vm_depth_off);
    try a.subRegImm32(.rax, 1);
    try a.movRegImm64(.r10, abi.frame_size);
    try a.imulRegReg(.rax, .r10);
    try a.addRegReg(.rax, .r8);
    try a.addRegImm32(.rax, abi.vm_frames_off);
    // -- step 8: dropRegionActivation residue. Under the descent gate the
    // profit map is empty, so `nextActivation(call_seq)` closes nothing —
    // but it DOES clear the region-context validity byte when the context
    // seq matches the popped frame's (which the push set it to). Replicate
    // exactly; the assert callout pins the zero-activations premise.
    try a.movRegMem(.rcx, .rax, abi.frame_call_seq_off);
    try a.cmpRegMem(.rcx, .r8, abi.vm_region_call_seq_off);
    const no_ctx_clear = try a.label();
    try a.jcc(.ne, no_ctx_clear);
    try a.movByteMemImm(.r8, abi.vm_region_valid_off, 0);
    a.bind(no_ctx_clear);
    // -- step 9: the pop — depth, stack_top ------------------------------
    try a.subRegImm32(.rax, abi.frame_size); // rax = parent frame
    try a.movRegMem32(.rcx, .r8, abi.vm_depth_off);
    try a.subRegImm32(.rcx, 1);
    try a.movMemReg32(.r8, abi.vm_depth_off, .rcx);
    try a.movRegMem(.r10, .rax, abi.frame_base_off); // r10 = parent.base
    try a.movRegReg(.rcx, .r10);
    try a.addRegImm32(.rcx, p.nreg);
    try a.movMemReg(.r8, abi.vm_stack_top_off, .rcx);
    // -- step 10: episode-ctx refresh onto the caller activation ---------
    try a.movRegMem(.r11, .rax, abi.frame_closure_off);
    try a.movMemReg(.r9, @offsetOf(Ctx, "closure"), .r11);
    try a.movMemReg(.r9, @offsetOf(Ctx, "base"), .r10);
    try a.movRegMem(.rcx, .rax, abi.frame_call_seq_off);
    try a.movMemReg(.r9, @offsetOf(Ctx, "call_seq"), .rcx);
    // ret_resume_pc (u32) from the parent's frozen one-past-call cursor.
    try a.movRegMem(.rcx, .rax, abi.frame_pc_off);
    try a.movMemReg32(.r9, @offsetOf(Ctx, "ret_resume_pc"), .rcx);
    // -- step 11: the formation witness (no tick — opRet does not tick) --
    try a.incMemQword(.r8, abi.vm_self_ret_pops_off);
    // Fall through = POP-OK: the caller emits popped_frames++, the
    // `.ret_pop` ledger row, and the ret-cont compare chain.
}

/// B-3a's unreachable silent tail. `metadata_cell` is a stable compile-time-owned
/// pointer cell; B-3b publishes a `*SilentExitMetadata` into it before patching.
pub fn emitSilentEpilogue(a: *x64.Assembler, kind: ExitPatchKind, metadata_cell: *usize, shared_exit: usize, trace_id: u32) !void {
    const can_silence = try a.label();
    const owned = try a.label();
    const qualified_done = try a.label();
    const zero_done = try a.label();
    const reset_zero = try a.label();
    const exhausted = try a.label();

    // A reporting prefix cannot be represented by the silent ABI. Continue at the
    // exact original reporting target whenever this span has emitted any row. This
    // also prevents re-entering silence after an off-cycle reporting suffix begins.
    try a.movRegImm64(.rax, @bitCast(@as(u64, @intFromPtr(metadata_cell))));
    try a.movRegMem(.rax, .rax, 0);
    try a.cmpQwordMemImm8(.rdx, @offsetOf(NativeResult, "ledger_len"), 0);
    try a.jcc(.e, can_silence);
    try a.movRegMem(.rax, .rax, @offsetOf(SilentExitMetadata, "reporting_target"));
    try a.jmpReg(.rax);
    a.bind(can_silence);

    // Final round-5 ordering: kind-specific materialization is complete before this
    // store, and every promoted epilogue publishes the exact cumulative rbx baseline.
    try a.movMemReg(.rdx, @offsetOf(NativeResult, "silent_cum"), .rbx);
    try a.movMemImm32(.rdx, @offsetOf(NativeResult, "silent_active"), 1);

    // rax = *SilentExitMetadata (loaded above).
    // First-cell ownership: preserve the first promoted edge observed in this call.
    try a.cmpQwordMemImm8(.rdx, @offsetOf(NativeResult, "silent_cell"), 0);
    try a.jcc(.ne, owned);
    try a.movMemReg(.rdx, @offsetOf(NativeResult, "silent_cell"), .rax);
    a.bind(owned);

    // r8 = dynamic local = current rbx - this body's entry rbx; rcx = edge cell.
    try a.movRegReg(.r8, .rbx);
    try a.subRegMem(.r8, .rdx, @offsetOf(NativeResult, "entry_rbx"));
    try a.movRegMem(.rcx, .rax, @offsetOf(SilentExitMetadata, "summary"));
    try a.movMemReg(.rcx, @offsetOf(SilentSummaryCell, "last_local"), .r8);

    // Round-6 exactness: every firing records ITSELF — its count, its ordinal, and
    // that it was the most recent edge to fire. Zig then indexes the summary by
    // measurement rather than by `(first_phase + t) % len` arithmetic, which is only
    // sound for a single live ring in which every trace owns exactly one phase.
    // r9 = this firing's one-based silent-transition ordinal (the counter at
    // `silent_transitions` is bumped at the tail, after the kind switch).
    try a.incMemQword(.rcx, @offsetOf(SilentSummaryCell, "firings"));
    try a.movRegMem(.r9, .rdx, @offsetOf(NativeResult, "silent_transitions"));
    try a.incReg(.r9);
    try a.movMemReg(.rcx, @offsetOf(SilentSummaryCell, "last_ordinal"), .r9);
    try a.movMemReg(.rdx, @offsetOf(NativeResult, "silent_last_cell"), .rax);

    // Preserve dynamic progress evidence independently from aggregated work.
    // Provenance verdict merging needs occurrence count, not merely a sum that
    // could have come from a different number of firings.
    const not_productive = try a.label();
    try a.cmpRegImm32(.r8, 0);
    try a.jcc(.e, not_productive);
    try a.incMemQword(.rcx, @offsetOf(SilentSummaryCell, "productive_firings"));
    try a.movMemReg(.rcx, @offsetOf(SilentSummaryCell, "last_productive_ordinal"), .r9);
    a.bind(not_productive);

    // Doc 52 P1: resident edges are barren-exempt — their firings neither
    // advance nor reset the activation's zero-run. Each arm tests the per-edge
    // flag (rax = metadata, still live) immediately before its zero-run
    // mutation and jumps straight to `zero_done`; all summary-cell work above
    // is keyed to the edge's own cells and unaffected. Activation edges pay
    // the test + fall through — the cost-honesty note in doc 52.
    switch (kind) {
        .deopt => {
            try a.addMemReg(.rcx, @offsetOf(SilentSummaryCell, "region_work"), .r8);
            try a.addMemReg(.rcx, @offsetOf(SilentSummaryCell, "selection_work"), .r8);
            try a.cmpRegMem(.r8, .rax, @offsetOf(SilentExitMetadata, "min_useful"));
            try a.jcc(.b, qualified_done);
            try a.incMemQword(.rcx, @offsetOf(SilentSummaryCell, "qualifying_rows"));
            a.bind(qualified_done);
            try a.cmpQwordMemImm8(.rax, @offsetOf(SilentExitMetadata, "barren_exempt"), 0);
            try a.jcc(.ne, zero_done);
            try a.cmpRegImm32(.r8, 0);
            try a.jcc(.ne, reset_zero);
            try a.incMemQword(.rdx, @offsetOf(NativeResult, "cur_zero_run"));
            try a.jmp(zero_done);
        },
        .loop_done_linked => {
            // region_work += 1; selection_work += max(local, 1).
            try a.movRegImm64(.r9, 1);
            try a.addMemReg(.rcx, @offsetOf(SilentSummaryCell, "region_work"), .r9);
            try a.cmpRegImm32(.r8, 0);
            const local_nonzero = try a.label();
            try a.jcc(.ne, local_nonzero);
            try a.movRegImm64(.r8, 1);
            a.bind(local_nonzero);
            try a.addMemReg(.rcx, @offsetOf(SilentSummaryCell, "selection_work"), .r8);
            try a.cmpRegMem(.r8, .rax, @offsetOf(SilentExitMetadata, "min_useful"));
            try a.jcc(.b, qualified_done);
            try a.incMemQword(.rcx, @offsetOf(SilentSummaryCell, "qualifying_rows"));
            a.bind(qualified_done);
            try a.cmpQwordMemImm8(.rax, @offsetOf(SilentExitMetadata, "barren_exempt"), 0);
            try a.jcc(.ne, zero_done);
            try a.jmp(reset_zero);
        },
        .link_terminal => {
            // Structural only: no work cells; a zero-work link advances the barren run.
            try a.cmpQwordMemImm8(.rax, @offsetOf(SilentExitMetadata, "barren_exempt"), 0);
            try a.jcc(.ne, zero_done);
            try a.incMemQword(.rdx, @offsetOf(NativeResult, "cur_zero_run"));
            try a.jmp(zero_done);
        },
        .region_bridge => {
            // Structural region work is zero, but selection charges max(local, 1).
            // Zero region work advances the barren run even when local is nonzero.
            try a.cmpRegImm32(.r8, 0);
            const local_nonzero = try a.label();
            try a.jcc(.ne, local_nonzero);
            try a.movRegImm64(.r8, 1);
            a.bind(local_nonzero);
            try a.addMemReg(.rcx, @offsetOf(SilentSummaryCell, "selection_work"), .r8);
            try a.cmpRegMem(.r8, .rax, @offsetOf(SilentExitMetadata, "min_useful"));
            try a.jcc(.b, qualified_done);
            try a.incMemQword(.rcx, @offsetOf(SilentSummaryCell, "qualifying_rows"));
            a.bind(qualified_done);
            try a.cmpQwordMemImm8(.rax, @offsetOf(SilentExitMetadata, "barren_exempt"), 0);
            try a.jcc(.ne, zero_done);
            try a.incMemQword(.rdx, @offsetOf(NativeResult, "cur_zero_run"));
            try a.jmp(zero_done);
        },
    }
    a.bind(reset_zero);
    try a.movMemImm32(.rdx, @offsetOf(NativeResult, "cur_zero_run"), 0);
    a.bind(zero_done);

    try a.incMemQword(.rdx, @offsetOf(NativeResult, "silent_transitions"));
    try a.movRegMem(.r8, .rdx, @offsetOf(NativeResult, "silent_transitions"));
    try a.cmpRegMem(.r8, .rdx, @offsetOf(NativeResult, "silent_budget"));
    try a.jcc(.ae, exhausted);
    try a.movRegMem(.r8, .rdx, @offsetOf(NativeResult, "cur_zero_run"));
    // Final round-5 barren comparison is absolute: cur_zero_run >= max_barren_run,
    // with max_barren_run staged directly in barren_budget.
    try a.cmpRegMem(.r8, .rdx, @offsetOf(NativeResult, "barren_budget"));
    try a.jcc(.ae, exhausted);

    // Continue through the same per-exit slot as the reporting path.
    try a.movRegMem(.rax, .rax, @offsetOf(SilentExitMetadata, "slot"));
    try a.movRegMem(.rax, .rax, 0);
    try a.jmpReg(.rax);

    a.bind(exhausted);
    try a.movMemReg(.rdx, @offsetOf(NativeResult, "completed"), .rbx);
    try a.movMemImm32(.rdx, @offsetOf(NativeResult, "final_trace_id"), @bitCast(trace_id));
    try a.movRegImm64(.rax, @bitCast(@as(u64, shared_exit)));
    try a.jmpReg(.rax);
}

pub fn nativeExitLabel(a: *x64.Assembler, exit_labels: []?x64.Label, instr_idx: usize) !x64.Label {
    if (exit_labels[instr_idx]) |l| return l;
    const l = try a.label();
    exit_labels[instr_idx] = l;
    return l;
}

pub fn jccNativeExit(a: *x64.Assembler, exit_labels: []?x64.Label, instr_idx: usize, cc: x64.Cond) !void {
    try a.jcc(cc, try nativeExitLabel(a, exit_labels, instr_idx));
}

pub fn jmpNativeExit(a: *x64.Assembler, exit_labels: []?x64.Label, instr_idx: usize) !void {
    try a.jmp(try nativeExitLabel(a, exit_labels, instr_idx));
}

pub fn nativeLinkedLoopDoneLabel(a: *x64.Assembler, linked_loop_done_labels: []?x64.Label, instr_idx: usize) !x64.Label {
    if (linked_loop_done_labels[instr_idx]) |l| return l;
    const l = try a.label();
    linked_loop_done_labels[instr_idx] = l;
    return l;
}

pub fn isNumericForLoopDoneGuard(t: *const Trace, instr_idx: usize) bool {
    return t.isNumericForLoopDoneGuard(instr_idx);
}

/// Part A-v (doc 17 §A2.1/§A2.3): true for a trace-local composite outer-loop
/// re-test whose bridge has at least one dominance-safe slot update to commit.
///
/// "Same-proto outer re-test" is represented without region metadata: committed
/// guard provenance must identify a source-level branch condition owned by the
/// anchor proto, and its post-fetch PC must precede this continuation's anchor.
/// This excludes inlined-callee guards, forward branches, and numeric-for
/// loop-done guards. The dominance-scoped set E is the slot-bound phi set whose
/// update ref was defined before the guard; a slot-bound phi is precisely a value
/// live at the trace successor/back-edge. Internal phis do not name VM slots and
/// are excluded.
pub fn isCompositeBridgeCandidate(t: *const Trace, instr_idx: usize) bool {
    return t.classifyBridgeCandidate(instr_idx);
}

/// The caller-saved GPRs every body callout must preserve (rax/rcx are the
/// JIT's scratch pair and deliberately excluded — a callout result rides
/// through the restore in one of them).
pub const CALLOUT_SAVED_GP = [_]Reg{ .r8, .r9, .r10, .r11 };

/// Save every SysV caller-saved home the JIT body may keep live across a
/// mid-body callout — rdi/rsi (SoA bases), rdx (*NativeResult), r8–r11, and
/// all allocatable XMMs (xmm2–xmm15) — into the pre-reserved
/// `callout_save_base` frame area. Shared by every `BodyCallout` lowering
/// (doc 23 D4 generalized this out of the href callout); paired with
/// `emitCalloutRestore`.
pub fn emitCalloutSave(a: *x64.Assembler, alloc: *const Alloc) !void {
    std.debug.assert(alloc.callout_save_count != 0); // save area must be reserved
    var off: u32 = alloc.callout_save_base;
    // rdi (tags base), rsi (payloads base), rdx (*NativeResult).
    try a.movMemReg(.rsp, @intCast(off * 8), .rdi);
    off += 1;
    try a.movMemReg(.rsp, @intCast(off * 8), .rsi);
    off += 1;
    try a.movMemReg(.rsp, @intCast(off * 8), .rdx);
    off += 1;
    // ALL caller-saved GP registers (r8–r11), not just homes — transients in
    // these registers may be live across the callout.
    for (CALLOUT_SAVED_GP) |r| {
        try a.movMemReg(.rsp, @intCast(off * 8), r);
        off += 1;
    }
    // ALL allocatable XMMs (xmm2–xmm15): same reasoning — a transient float
    // live across the callout would be clobbered.
    for (XMM_ALLOC_ORDER) |r| {
        try a.movsdMemReg(.rsp, @intCast(off * 8), r);
        off += 1;
    }
    // Sanity: we used exactly the reserved number of slots.
    std.debug.assert(off == alloc.callout_save_base + alloc.callout_save_count);
}

/// Restore everything `emitCalloutSave` saved, in reverse order. Deliberately
/// never touches rax/rcx (GP scratch) or xmm0/xmm1 (float scratch): a callout
/// stashes its result there so it survives the restore. Restore must happen
/// BEFORE any result check that can side-exit — the deopt flush at
/// `jccNativeExit` relies on slot homes being correct.
pub fn emitCalloutRestore(a: *x64.Assembler, alloc: *const Alloc) !void {
    var off: u32 = alloc.callout_save_base + alloc.callout_save_count;
    {
        var ri: usize = XMM_ALLOC_ORDER.len;
        while (ri > 0) {
            ri -= 1;
            off -= 1;
            try a.movsdRegMem(XMM_ALLOC_ORDER[ri], .rsp, @intCast(off * 8));
        }
    }
    {
        var ri: usize = CALLOUT_SAVED_GP.len;
        while (ri > 0) {
            ri -= 1;
            off -= 1;
            try a.movRegMem(CALLOUT_SAVED_GP[ri], .rsp, @intCast(off * 8));
        }
    }
    off -= 1;
    try a.movRegMem(.rdx, .rsp, @intCast(off * 8));
    off -= 1;
    try a.movRegMem(.rsi, .rsp, @intCast(off * 8));
    off -= 1;
    try a.movRegMem(.rdi, .rsp, @intCast(off * 8));
    std.debug.assert(off == alloc.callout_save_base);
}

/// Emit the mid-body callout for a float-kernel producer (`fsin`/`fcos`
/// unary; `pow` and doc 25's float `mod`/`idiv` binary — doc 23 D4). The native body calls THE SAME noinline
/// `fmath` kernel tier-0 and tier-1a execute — never an inline SSE
/// re-derivation — so cross-tier bit-identity holds by construction (there is
/// exactly one compiled body of each kernel in the process). SysV float call:
/// operands in xmm0(/xmm1), result in xmm0; the restore only touches xmm2–xmm15 /
/// r8–r11 / rdi/rsi/rdx, so the result rides through it in xmm0. No side-exit:
/// the operand is a proven numeric (dominating `guard_float`/`guard_int`) and
/// the kernel is total (NaN in → NaN out).
pub fn emitFloatCallout(
    a: *x64.Assembler,
    alloc: *const Alloc,
    kinds: []const Kind,
    ins: trace.IrInstr,
    i: usize,
) !void {
    try emitCalloutSave(a, alloc);

    // arg0: the proven-numeric operand into xmm0 (== XMM_SCRATCH0); a proven
    // int promotes via the shared cvtsi2sd discipline. The two-arg kernels
    // (`pow`, and doc 25's float mod/idiv) additionally stage their second
    // operand into xmm1 — staging order is safe because operand homes are
    // never the scratch XMMs.
    const is_binary = ins.op == .pow or ins.op == .mod or ins.op == .idiv;
    try floatOperandToXmm(a, XMM_SCRATCH0, placeOfRef(alloc, ins.a), kinds[ins.a]);
    if (is_binary)
        try floatOperandToXmm(a, XMM_SCRATCH1, placeOfRef(alloc, ins.b), kinds[ins.b]);

    // Call the fmath kernel via an absolute address in rax. Same alignment
    // dance as emitHrefCallout: the body runs with rsp % 16 == 8, SysV wants
    // rsp % 16 == 0 at the call.
    const kernel: usize = switch (ins.op) {
        .fsin => @intFromPtr(&fmath.sinRuntime),
        .fcos => @intFromPtr(&fmath.cosRuntime),
        .pow => @intFromPtr(&fmath.powRuntime),
        .mod => @intFromPtr(&fmath.fmodRuntime),
        .idiv => @intFromPtr(&fmath.floordivRuntime),
        else => unreachable,
    };
    try a.subRegImm32(.rsp, 8);
    try a.movRegImm64(.rax, @bitCast(kernel));
    try a.callReg(.rax);
    try a.addRegImm32(.rsp, 8);

    // Result is in xmm0; restore (which leaves xmm0 alone), then home it.
    try emitCalloutRestore(a, alloc);
    switch (placeOfRef(alloc, i)) {
        .xmm => |x| if (x != XMM_SCRATCH0) try a.movsdRegReg(x, XMM_SCRATCH0),
        .mem => |d| try a.movsdMemReg(.rsp, d, XMM_SCRATCH0),
        .reg => unreachable, // a float result never homes in a GP register
    }
}

/// Doc 35: emit the mid-body callout for `ffloor`/`fceil`. Unlike
/// `emitFloatCallout` (which produces a float in xmm0), these kernels
/// return an i64 in rax (SysV integer return convention). The caller
/// then checks for the out-of-range sentinel (`FLOOR_CEIL_SENTINEL =
/// minInt(i64)`) and side-exits if hit. Result lands in a GP register
/// home, not an XMM.
pub fn emitFloorCeilCallout(
    a: *x64.Assembler,
    alloc: *const Alloc,
    kinds: []const Kind,
    ins: trace.IrInstr,
    i: usize,
    exit_labels: []?x64.Label,
) !void {
    try emitCalloutSave(a, alloc);

    // arg0: the proven-numeric operand into xmm0.
    try floatOperandToXmm(a, XMM_SCRATCH0, placeOfRef(alloc, ins.a), kinds[ins.a]);

    // Call the fmath kernel (f64→i64, result in rax).
    const kernel: usize = switch (ins.op) {
        .ffloor => @intFromPtr(&fmath.floorRuntime),
        .fceil => @intFromPtr(&fmath.ceilRuntime),
        else => unreachable,
    };
    try a.subRegImm32(.rsp, 8);
    try a.movRegImm64(.rax, @bitCast(kernel));
    try a.callReg(.rax);
    try a.addRegImm32(.rsp, 8);

    // Restore callee-saved regs (rax is the return value, not clobbered
    // by the restore — the restore touches only r8–r11/rdi/rsi/rdx/xmm2+).
    try emitCalloutRestore(a, alloc);

    // Sentinel check: rax == minInt(i64) → side-exit. Use `movabs rcx, sentinel`
    // + `cmp rax, rcx` → je exit. rcx is a scratch register.
    const sentinel: i64 = fmath.FLOOR_CEIL_SENTINEL;
    try a.movRegImm64(.rcx, @bitCast(sentinel));
    try a.cmpRegReg(.rax, .rcx);
    try jccNativeExit(a, exit_labels, i, .e); // equal → out-of-range → side-exit

    // Home the result (an integer) in the allocated GP register or spill.
    try regToPlace(a, placeOfRef(alloc, i), .rax);
}

/// doc 25 D1: inline int `%` / `//`. `cqo`/`idiv` + the floor adjustment
/// reproduce `@mod`/`@divFloor` exactly for every non-special pair; the two
/// specials are handled without ever reaching the (trapping) hardware
/// instruction: a ZERO divisor side-exits at this instruction (tier-0
/// re-raises `DivisionByZero` from the same exit snapshot tier-1a errors
/// at), and `(minInt, -1)` materializes the oracle's DEFINED value inline
/// (`mod` → 0, `idiv` → minInt) and CONTINUES — tier-1a doesn't exit there,
/// so native must not either (codex blocker, doc 25). `idiv` clobbers
/// rdx:rax, and rdx carries the live `*NativeResult`, so rdx is parked in
/// the allocator-owned `div_save` frame slot for the duration; rax/rcx are
/// body scratch. The result canonically ends in rax on every path.
pub fn emitIntDivMod(
    a: *x64.Assembler,
    alloc: *const Alloc,
    ins: trace.IrInstr,
    i: usize,
    exit_labels: []?x64.Label,
) !void {
    const save_disp: i32 = @as(i32, @intCast(alloc.div_save.?)) * 8;
    // Park rdx. The mov leaves rdx itself intact, so the zero-divisor exit
    // below still runs with a valid *NativeResult in rdx.
    try a.movMemReg(.rsp, save_disp, .rdx);
    try placeToReg(a, .rax, placeOfRef(alloc, ins.a)); // dividend
    try placeToReg(a, .rcx, placeOfRef(alloc, ins.b)); // divisor
    try a.cmpRegImm32(.rcx, 0);
    try jccNativeExit(a, exit_labels, i, .e); // y == 0 → tier-0 raises
    // (minInt, -1) probe. rdx is clobbered from here on — no exit until it
    // is restored at the end.
    const go = try a.label();
    const done = try a.label();
    try a.movRegImm64(.rdx, @bitCast(@as(u64, 0x8000_0000_0000_0000)));
    try a.xorRegReg(.rdx, .rax); // 0 iff dividend == minInt
    try a.jcc(.ne, go);
    try a.cmpRegImm32(.rcx, -1);
    try a.jcc(.ne, go);
    // The pair: mod → 0; idiv → minInt (rax already holds the dividend).
    if (ins.op == .mod) try a.xorRegReg(.rax, .rax);
    try a.jmp(done);
    a.bind(go);
    try a.cqo();
    try a.idivReg(.rcx); // rax = trunc quotient, rdx = trunc remainder
    // Floor adjust: rem != 0 and sign(rem) != sign(divisor).
    if (ins.op == .mod) {
        // Result = remainder (+ divisor when adjusting), canonicalized into
        // rax; the truncated quotient is dead → xor scratch.
        const move = try a.label();
        try a.cmpRegImm32(.rdx, 0);
        try a.jcc(.e, move);
        try a.movRegReg(.rax, .rdx);
        try a.xorRegReg(.rax, .rcx);
        try a.jcc(.ns, move); // same signs → no adjust
        try a.addRegReg(.rdx, .rcx); // rem += divisor
        a.bind(move);
        try a.movRegReg(.rax, .rdx);
    } else {
        // Result = quotient (already rax); the remainder is dead after the
        // sign test → clobber it.
        try a.cmpRegImm32(.rdx, 0);
        try a.jcc(.e, done);
        try a.xorRegReg(.rdx, .rcx);
        try a.jcc(.ns, done); // same signs → no adjust
        try a.subRegImm32(.rax, 1); // quot -= 1
    }
    a.bind(done);
    try regToPlace(a, placeOfRef(alloc, i), .rax); // home is never rax/rcx/rdx
    try a.movRegMem(.rdx, .rsp, save_disp); // unpark
}

/// Emit the mid-body callout for an allocating interned-string producer
/// (`tostr_int`/`tostr_num` — doc 24 D5). Same shape as `emitHrefCallout`:
/// save, SysV args (rdi = the baked `*Heap`; the guarded scalar in rsi for the
/// int body, xmm0 for the float body), call the shared noinline `stralloc`
/// body through an absolute pointer, stash the result across the restore, then
/// test-and-exit. A null return is OOM with a CLEAN id stream (no `Heap.link`
/// preceded the fallible step — stralloc.zig's audit): the ordinary deopt exit
/// resumes tier-0 at the header and the replay re-raises the same OOM at the
/// same logical point. On success the `*GcHeader` (kind `.heap`) lands in the
/// op's home; the restore leaves rcx/rax/xmm0 untouched so it rides through.
pub fn emitTostrCallout(
    a: *x64.Assembler,
    alloc: *const Alloc,
    kinds: []const Kind,
    heap: *gc.Heap,
    ins: trace.IrInstr,
    i: usize,
    exit_labels: []?x64.Label,
) !void {
    try emitCalloutSave(a, alloc);

    // Stage the operand BEFORE overwriting rdi (a `.mem` home reads via rsp,
    // untouched by the save; a `.reg` home is r8–r11, also untouched).
    if (ins.op == .tostr_int) {
        try placeToReg(a, .rsi, placeOfRef(alloc, ins.a));
    } else {
        try floatOperandToXmm(a, XMM_SCRATCH0, placeOfRef(alloc, ins.a), kinds[ins.a]);
    }
    // arg0: the Heap, baked absolute (stable for the VM's lifetime).
    try a.movRegImm64(.rdi, @bitCast(@as(u64, @intFromPtr(heap))));

    // Call the stralloc body via an absolute address in rax. Same alignment
    // dance as emitHrefCallout (body runs with rsp % 16 == 8).
    const body: usize = switch (ins.op) {
        .tostr_int => @intFromPtr(&stralloc.tostrIntRuntime),
        .tostr_num => @intFromPtr(&stralloc.tostrNumRuntime),
        else => unreachable,
    };
    try a.subRegImm32(.rsp, 8);
    try a.movRegImm64(.rax, @bitCast(body));
    try a.callReg(.rax);
    try a.addRegImm32(.rsp, 8);

    // rax = the interned *GcHeader, or 0 on OOM. The result check must come
    // AFTER the restore (the deopt flush relies on slot homes being correct),
    // so stash it in rcx — scratch, never a home, untouched by the restore.
    try a.movRegReg(.rcx, .rax);
    try emitCalloutRestore(a, alloc);
    try a.cmpRegImm32(.rcx, 0);
    try jccNativeExit(a, exit_labels, i, .e); // 0 → OOM → side-exit
    try regToPlace(a, placeOfRef(alloc, i), .rcx);
}

/// Emit the mid-body callout for a snew-class producer (`ssub`/`srev`/
/// `schar1`/`srep2` — doc 24 D4/c3 — and, doc 26, the case producers
/// `supper`/`slower`, which ride srev's exact arg shape). Same shape as
/// `emitTostrCallout`: save,
/// SysV args (rdi = the baked `*Heap`, then the op's operands), call the
/// shared noinline `stralloc` shim — which calls THE SAME core tier-0 runs —
/// through an absolute pointer, stash the result across the restore, then
/// test-and-exit. A null return collapses BOTH D5 failure arms (OOM, or the
/// tier-0 raise: invalid codepoint / negative count) with a CLEAN id stream
/// (no `Heap.link` preceded the fallible step — stralloc.zig's audit): the
/// ordinary deopt exit resumes tier-0 at the header and the replay re-raises
/// the identical error (or re-hits the OOM) at the same logical point. On
/// success the fresh-or-interned `*GcHeader` (kind `.heap`) lands in the op's
/// home.
///
/// Operand staging is hazard-free in any order: homes are r8–r11 / rbp /
/// r12–r15 / rsp-relative spills — never rsi/rdx/rcx (reserved) — and the
/// save wrote rdi/rsi/rdx to the frame already. rcx doubles as ssub's fourth
/// arg AND the post-call result stash; the call consumes the arg before the
/// stash is written, so there is no conflict.
pub fn emitSnewCallout(
    a: *x64.Assembler,
    alloc: *const Alloc,
    heap: *gc.Heap,
    ins: trace.IrInstr,
    i: usize,
    exit_labels: []?x64.Label,
) !void {
    try emitCalloutSave(a, alloc);

    // arg1 (rsi): the string `*GcHeader` (ssub/srev/srep2) or the codepoint
    // int (schar1) — `ins.a` in every shape.
    try placeToReg(a, .rsi, placeOfRef(alloc, ins.a));
    switch (ins.op) {
        // ssub(heap, s, i, j): start in rdx, end in rcx (the aux ref — the one
        // three-operand op; analyzeInner extended its liveness to here).
        .ssub => {
            try placeToReg(a, .rdx, placeOfRef(alloc, ins.b));
            try placeToReg(a, .rcx, placeOfRef(alloc, @intCast(ins.aux)));
        },
        // srep2(heap, s, n): count in rdx.
        .srep2 => try placeToReg(a, .rdx, placeOfRef(alloc, ins.b)),
        .srev, .schar1, .supper, .slower => {},
        else => unreachable,
    }
    // arg0: the Heap, baked absolute (stable for the VM's lifetime).
    try a.movRegImm64(.rdi, @bitCast(@as(u64, @intFromPtr(heap))));

    // Call the stralloc shim via an absolute address in rax. Same alignment
    // dance as emitHrefCallout (body runs with rsp % 16 == 8).
    const body: usize = switch (ins.op) {
        .ssub => @intFromPtr(&stralloc.ssubRuntime),
        .srev => @intFromPtr(&stralloc.srevRuntime),
        .schar1 => @intFromPtr(&stralloc.schar1Runtime),
        .srep2 => @intFromPtr(&stralloc.srep2Runtime),
        .supper => @intFromPtr(&stralloc.supperRuntime),
        .slower => @intFromPtr(&stralloc.slowerRuntime),
        else => unreachable,
    };
    try a.subRegImm32(.rsp, 8);
    try a.movRegImm64(.rax, @bitCast(body));
    try a.callReg(.rax);
    try a.addRegImm32(.rsp, 8);

    // rax = the result *GcHeader, or 0 (OOM / tier-0-raise, collapsed). The
    // result check must come AFTER the restore (the deopt flush relies on
    // slot homes being correct), so stash it in rcx — scratch, never a home,
    // untouched by the restore.
    try a.movRegReg(.rcx, .rax);
    try emitCalloutRestore(a, alloc);
    try a.cmpRegImm32(.rcx, 0);
    try jccNativeExit(a, exit_labels, i, .e); // 0 → side-exit, tier-0 replays
    try regToPlace(a, placeOfRef(alloc, i), .rcx);
}

/// Emit the mid-body callout for `scp` (`string.codepoint`, single result —
/// doc 26 D4). A SEPARATE emitter, not a mode flag on `emitSnewCallout`,
/// because the shape differs on every axis that matters: no heap argument
/// (`scpRuntime` is the one non-allocating stralloc shim — args (s, i, j) in
/// rdi/rsi/rdx), an int result rather than a `*GcHeader`, and the failure
/// sentinel is −1 rather than null — compared FULL-WIDTH signed (`cmp r64,
/// imm32` sign-extends, so this is a 64-bit compare; a real codepoint is
/// 0…0x10FFFF and can never alias it). −1 (empty range) side-exits and tier-0
/// replays the call to its nil result — through whatever continuation follows
/// (nil-consuming or raising), which native never needs to know.
///
/// Operand staging is hazard-free: homes are r8–r11 / rbp / r12–r15 /
/// rsp-relative spills — never rdi/rsi/rdx — and `emitCalloutSave` wrote
/// rdi/rsi (the SoA bases) to the frame already, so loading the three arg
/// registers in any order clobbers no unread source.
pub fn emitScpCallout(
    a: *x64.Assembler,
    alloc: *const Alloc,
    ins: trace.IrInstr,
    i: usize,
    exit_labels: []?x64.Label,
) !void {
    try emitCalloutSave(a, alloc);

    // scpRuntime(s, i, j): the string `*GcHeader` in rdi, start index in rsi,
    // end index in rdx (the aux ref — analyzeInner extended its liveness).
    try placeToReg(a, .rdi, placeOfRef(alloc, ins.a));
    try placeToReg(a, .rsi, placeOfRef(alloc, ins.b));
    try placeToReg(a, .rdx, placeOfRef(alloc, @intCast(ins.aux)));

    // Call the shim via an absolute address in rax. Same alignment dance as
    // emitHrefCallout (body runs with rsp % 16 == 8).
    try a.subRegImm32(.rsp, 8);
    try a.movRegImm64(.rax, @bitCast(@as(u64, @intFromPtr(&stralloc.scpRuntime))));
    try a.callReg(.rax);
    try a.addRegImm32(.rsp, 8);

    // rax = the codepoint, or −1 (empty range). The result check must come
    // AFTER the restore (the deopt flush relies on slot homes being correct),
    // so stash it in rcx — scratch, never a home, untouched by the restore.
    try a.movRegReg(.rcx, .rax);
    try emitCalloutRestore(a, alloc);
    try a.cmpRegImm32(.rcx, -1);
    try jccNativeExit(a, exit_labels, i, .e); // −1 → side-exit, tier-0 replays to nil
    try regToPlace(a, placeOfRef(alloc, i), .rcx);
}

/// Emit the mid-body callout for a doc 30 match op (`sfindp`/`smatch`/
/// `sgmatch`) — the status-result class. One emitter for the three because
/// they share the whole protocol and differ only in arg staging and the
/// success predicate: save, SysV args, call the shared noinline `stralloc`
/// shim (the SAME core every tier runs — P3), stash the i64 result across the
/// restore in rcx (scratch, never a home), then test-and-exit:
///
/// - `sfindp(s, init, pat)` — heap-FREE. Success is a 1-based char index
///   ≥ 1; every failure status is negative and 0 is never returned, so
///   `result ≤ 0 → exit` (full-width signed — `cmp r64, imm32`).
/// - `smatch(heap, s, init, pat)` — fills `heap.match_scratch`. Success is
///   exactly 0 (`≠ 0 → exit`; positives are never returned).
/// - `sgmatch(heap, state, expected_pat)` — one composite gmatch-iterator
///   step, read-only on the state. `expected_pat` is the record-time pattern
///   konst (`t.consts[aux]`), resolved HERE at emission to a baked
///   `*GcHeader` (stable: non-moving GC, consts rooted by the trace) — the
///   shim's identity check replaces `guard_sid` on this path (round-2 B02).
///   Success is exactly 0; a no-match end-of-iteration is a negative status
///   → side-exit, and tier-0's replay produces the loop-ending nil itself.
///
/// Every negative status (doc 30 M03: no_match, malformed, …, bad_init)
/// side-exits with a CLEAN id stream — none of the three shims links — and
/// tier-0 replays the iteration, re-raising any matcher error itself at the
/// same logical point.
///
/// Operand staging is hazard-free in any order: homes are r8–r11 / rbp /
/// r12–r15 / rsp-relative spills — never the arg registers — and the save
/// wrote rdi/rsi/rdx to the frame already. rcx doubles as smatch's fourth
/// arg AND the result stash (the ssub precedent): the call consumes the arg
/// before the stash is written.
pub fn emitMatchCallout(
    a: *x64.Assembler,
    alloc: *const Alloc,
    t: *const Trace,
    heap: ?*gc.Heap,
    ins: trace.IrInstr,
    i: usize,
    exit_labels: []?x64.Label,
) !void {
    try emitCalloutSave(a, alloc);

    switch (ins.op) {
        // sfindpRuntime(s, init, pat): heap-free three-arg shape.
        .sfindp => {
            try placeToReg(a, .rdi, placeOfRef(alloc, ins.a));
            try placeToReg(a, .rsi, placeOfRef(alloc, ins.b));
            try placeToReg(a, .rdx, placeOfRef(alloc, @intCast(ins.aux)));
        },
        // smatchRuntime(heap, s, init, pat): heap first, pattern in rcx.
        .smatch => {
            try placeToReg(a, .rsi, placeOfRef(alloc, ins.a));
            try placeToReg(a, .rdx, placeOfRef(alloc, ins.b));
            try placeToReg(a, .rcx, placeOfRef(alloc, @intCast(ins.aux)));
            try a.movRegImm64(.rdi, @bitCast(@as(u64, @intFromPtr(heap.?))));
        },
        // sgmatchRuntime(heap, state, expected_pat): the pattern is baked.
        .sgmatch => {
            try placeToReg(a, .rsi, placeOfRef(alloc, ins.a));
            const pat = t.consts[@intCast(ins.aux)].asHeap();
            try a.movRegImm64(.rdx, @bitCast(@as(u64, @intFromPtr(pat))));
            try a.movRegImm64(.rdi, @bitCast(@as(u64, @intFromPtr(heap.?))));
        },
        else => unreachable,
    }

    const body: usize = switch (ins.op) {
        .sfindp => @intFromPtr(&stralloc.sfindpRuntime),
        .smatch => @intFromPtr(&stralloc.smatchRuntime),
        .sgmatch => @intFromPtr(&stralloc.sgmatchRuntime),
        else => unreachable,
    };
    try a.subRegImm32(.rsp, 8);
    try a.movRegImm64(.rax, @bitCast(body));
    try a.callReg(.rax);
    try a.addRegImm32(.rsp, 8);

    // The result check must come AFTER the restore (the deopt flush relies on
    // slot homes being correct), so stash the status in rcx.
    try a.movRegReg(.rcx, .rax);
    try emitCalloutRestore(a, alloc);
    try a.cmpRegImm32(.rcx, 0);
    if (ins.op == .sfindp)
        try jccNativeExit(a, exit_labels, i, .le) // ≤ 0 → side-exit
    else
        try jccNativeExit(a, exit_labels, i, .ne); // ≠ 0 → side-exit
    try regToPlace(a, placeOfRef(alloc, i), .rcx);
}

/// Emit the mid-body callout for `scap_str` (doc 30): intern the span in
/// scratch slot `ins.b`. The snew protocol verbatim — save, args (rdi = the
/// baked `*Heap`, rsi = the slot IMMEDIATE), call `scapStrRuntime`, stash the
/// `*GcHeader` across the restore, null → side-exit (OOM; no `Heap.link`
/// preceded the failure, so the id stream is clean and tier-0 re-hits the
/// same OOM on replay). Emitted even when the capture is dead (B02: `.alloc`
/// ops execute for id-stream fidelity — tropt never DCEs it).
pub fn emitScapStrCallout(
    a: *x64.Assembler,
    alloc: *const Alloc,
    heap: *gc.Heap,
    ins: trace.IrInstr,
    i: usize,
    exit_labels: []?x64.Label,
) !void {
    try emitCalloutSave(a, alloc);

    try a.movRegImm64(.rsi, @as(i64, ins.b));
    try a.movRegImm64(.rdi, @bitCast(@as(u64, @intFromPtr(heap))));

    try a.subRegImm32(.rsp, 8);
    try a.movRegImm64(.rax, @bitCast(@as(u64, @intFromPtr(&stralloc.scapStrRuntime))));
    try a.callReg(.rax);
    try a.addRegImm32(.rsp, 8);

    try a.movRegReg(.rcx, .rax);
    try emitCalloutRestore(a, alloc);
    try a.cmpRegImm32(.rcx, 0);
    try jccNativeExit(a, exit_labels, i, .e); // null → side-exit (OOM)
    try regToPlace(a, placeOfRef(alloc, i), .rcx);
}

/// Emit the mid-body callout for `str2num_i`/`str2num_f` (doc 30): the ONE
/// `arith.toNumber` core on a proven-string operand. `str2numRuntime` returns
/// the two-eightbyte `Str2NumResult` in rax (status) : rdx (raw value bits) —
/// SysV small-struct return. Both must survive the restore, and the restore
/// overwrites rdx (the parked `*NativeResult`), so the stash is: status →
/// rcx, value bits → rax (neither is touched by the restore). The recorder
/// baked the OBSERVED kind into the op — status ≠ expected (wrong kind, or
/// −1 = not a number) side-exits, and tier-0's replay produces the other
/// kind / the nil / the raise itself. Heap-free, pure, no id-stream impact.
pub fn emitStr2NumCallout(
    a: *x64.Assembler,
    alloc: *const Alloc,
    ins: trace.IrInstr,
    i: usize,
    exit_labels: []?x64.Label,
) !void {
    try emitCalloutSave(a, alloc);

    try placeToReg(a, .rdi, placeOfRef(alloc, ins.a));

    try a.subRegImm32(.rsp, 8);
    try a.movRegImm64(.rax, @bitCast(@as(u64, @intFromPtr(&stralloc.str2numRuntime))));
    try a.callReg(.rax);
    try a.addRegImm32(.rsp, 8);

    try a.movRegReg(.rcx, .rax); // status
    try a.movRegReg(.rax, .rdx); // raw value bits
    try emitCalloutRestore(a, alloc);
    const expected: i32 = if (ins.op == .str2num_i) 0 else 1;
    try a.cmpRegImm32(.rcx, expected);
    try jccNativeExit(a, exit_labels, i, .ne); // kind mismatch / non-number → exit
    // Home the value: int → GP/spill via the shared path; float → the raw
    // f64 bits movq into the XMM home (or a raw 8-byte spill store — bits
    // are bits). A float result never homes in a GP register.
    if (ins.op == .str2num_i) {
        try regToPlace(a, placeOfRef(alloc, i), .rax);
    } else switch (placeOfRef(alloc, i)) {
        .xmm => |x| try a.movqXmmReg(x, .rax),
        .mem => |d| try a.movMemReg(.rsp, d, .rax),
        .reg => unreachable,
    }
}

/// Emit the mid-body callout for `sgm_setpos` (doc 30 §6): commit the gmatch
/// cursor into the state's slot 3 — the deferred store, sunk below every
/// guard, so reaching it means the iteration is committed. `sgmSetposRuntime`
/// re-verifies the B03 cell shape (in-lane `.value` int cell) and writes an
/// int over an int — no GC barrier, no allocation. 0 = written; a negative
/// status (bad_layout — the shape raced away) side-exits with NOTHING
/// written, and tier-0 replays the whole iteration. Value-less: no home.
pub fn emitSgmSetposCallout(
    a: *x64.Assembler,
    alloc: *const Alloc,
    ins: trace.IrInstr,
    i: usize,
    exit_labels: []?x64.Label,
) !void {
    try emitCalloutSave(a, alloc);

    try placeToReg(a, .rdi, placeOfRef(alloc, ins.a));
    try placeToReg(a, .rsi, placeOfRef(alloc, ins.b));

    try a.subRegImm32(.rsp, 8);
    try a.movRegImm64(.rax, @bitCast(@as(u64, @intFromPtr(&stralloc.sgmSetposRuntime))));
    try a.callReg(.rax);
    try a.addRegImm32(.rsp, 8);

    try a.movRegReg(.rcx, .rax);
    try emitCalloutRestore(a, alloc);
    try a.cmpRegImm32(.rcx, 0);
    try jccNativeExit(a, exit_labels, i, .ne); // bad_layout → side-exit
}

/// Emit the per-iteration hash-cell resolution call-out for a `.heap`-rooted href.
/// The sequence saves all live caller-saved homes (rdi/rsi SoA bases + GP + XMM)
/// into the pre-reserved frame area, sets up SysV ABI arguments, calls
/// `resolveHashCell`, restores, checks the result, and stores the cell pointer in
/// the href's home. On a 0 return (cell not found) the trace side-exits.
pub fn emitHrefCallout(
    a: *x64.Assembler,
    t: *const Trace,
    alloc: *const Alloc,
    kinds: []const Kind,
    ins: trace.IrInstr,
    i: usize,
    exit_labels: []?x64.Label,
) !void {
    _ = kinds;

    // 1. Save all caller-saved homes into the reserved frame area.
    try emitCalloutSave(a, alloc);

    // 2. Set up SysV ABI arguments:
    //    rdi = *GcHeader (from the aload's home — the .heap table pointer)
    //    rsi = key tag bits (compile-time constant from the trace's const pool)
    //    rdx = key payload bits (compile-time constant)
    //
    // The href's ins.b is a konst instruction; the konst's aux indexes t.consts.
    const konst_ins = t.instrs[ins.b];
    const key = t.consts[@intCast(konst_ins.aux)];
    const key_tag: u64 = @intFromEnum(key.tag);
    const key_payload: u64 = key.payload.bits;

    // Load the table *GcHeader into rdi (arg0). The aload result (ins.a) might be
    // in a register home, a spill, or might have been clobbered if its home was rdi
    // — but we already saved rdi, and refBaseReg uses .rax as scratch, which is fine
    // since we haven't loaded args into it yet.
    try placeToReg(a, .rdi, placeOfRef(alloc, ins.a));

    // Key tag and payload are compile-time constants.
    try a.movRegImm64(.rsi, @bitCast(key_tag));
    try a.movRegImm64(.rdx, @bitCast(key_payload));

    // 3. Call resolveHashCell via an absolute address in rax.
    // The JIT body runs with rsp % 16 == 8 (return-address push from the
    // C-ABI entry call). SysV requires rsp % 16 == 0 at a `call` site, so
    // bump the stack by 8 to fix alignment, then undo after the call.
    try a.subRegImm32(.rsp, 8);
    try a.movRegImm64(.rax, @bitCast(@intFromPtr(&resolveHashCell)));
    try a.callReg(.rax);
    try a.addRegImm32(.rsp, 8);

    // rax now holds the cell pointer (or 0 on miss). The result check must
    // come AFTER the restore (the deopt flush at jccNativeExit relies on slot
    // homes being correct), so stash rax in rcx — scratch, not a home, and
    // emitCalloutRestore never touches it — then restore, then test rcx.
    try a.movRegReg(.rcx, .rax);

    // 5. Restore everything saved in step 1 (rcx/xmm0 untouched).
    try emitCalloutRestore(a, alloc);

    // 6. Check the result (stashed in rcx). 0 = cell not found → side-exit.
    try a.cmpRegImm32(.rcx, 0);
    try jccNativeExit(a, exit_labels, i, .e); // ZF=1 → rcx==0 → miss

    // 7. Store the cell pointer (in rcx) into the href's home.
    try regToPlace(a, placeOfRef(alloc, i), .rcx);
}

/// doc 49 — the hrefk inline hash-cell resolution for a dynamic-root href
/// carrying an `HrefAux`-encoded `(slot, mask)`. Replaces the
/// `resolveHashCell` callout for that shape: ~7 instructions, 4 loads, NO
/// call, NO caller-saved save/restore (and `bodyCalloutOf` reserves no save
/// frame for it).
///
/// Guard order is contractual (doc 49 codex rounds 1–3):
///   1. `hash.mask == K` — establishes capacity, bounds `S <= K` (encode
///      guarantees it), and non-null `nodes` (empty map has mask 0, K >= 3).
///      Reloading `nodes` from the LIVE table each iteration makes same-mask
///      reallocation safe.
///   2. LIVE-CELL guard: `node[S].value.tag != nil`. Without it a store-only
///      chain could write through a DEAD node (delete + unrelated insert
///      restores the aggregate count) without bumping `live` — diverging from
///      the tier-1a `fieldPtr` oracle, which rejects dead nodes. Ordered
///      BEFORE any key deref: a dead heap key holds id bits, not a pointer.
///   3. Key tag == the konst's tag (heap_ref for the v1 string keys).
///   4. Key IDENTITY by stable `GcHeader.id` — NEVER payload bits: keyframe
///      restore gives interned strings new addresses; ids survive (the same
///      reason `guard_func` pins `proto.id`).
/// Any failure side-exits at this instruction — the same exit the callout's
/// miss path uses, so provenance/ledger semantics are unchanged.
pub fn emitHrefK(
    a: *x64.Assembler,
    t: *const Trace,
    alloc: *const Alloc,
    ins: trace.IrInstr,
    i: usize,
    exit_labels: []?x64.Label,
) !void {
    const dec = trace.HrefAux.decode(ins.aux).?; // caller dispatched on decode
    const konst_ins = t.instrs[ins.b];
    const key = t.consts[@intCast(konst_ins.aux)];
    // v1 records hrefk for heap (interned string) keys only (`hrefAuxFor`).
    std.debug.assert(key.isHeap());
    const key_id: u32 = key.asHeap().id;
    const node_off: i32 = @as(i32, @intCast(dec.slot)) * layout.NODE_SIZE;

    // rax/rcx are the body scratch pair (never homes) — same discipline as
    // the dynamic guard_table/guard_func emitters.
    // 1. rax = *GcHeader (== *Table; header is the first field).
    try placeToReg(a, .rax, placeOfRef(alloc, ins.a));
    //    mask guard: capacity changed (rehash/grow/fresh table shape) → exit.
    try a.cmpDwordMemImm(.rax, layout.HASH_MASK_FROM_HEADER, dec.mask);
    try jccNativeExit(a, exit_labels, i, .ne);
    //    rax = nodes base (non-null: mask == K >= 3 proves a live array).
    try a.movRegMem(.rax, .rax, layout.HASH_NODES_FROM_HEADER);
    // 2. live-cell guard: value tag at the slot must not be nil (dead/absent).
    try a.cmpByteMemImm(.rax, node_off + layout.NODE_VALUE_OFF + layout.VALUE_TAG_OFF, layout.TAG_NIL);
    try jccNativeExit(a, exit_labels, i, .e);
    // 3. key tag guard.
    try a.cmpByteMemImm(.rax, node_off + layout.NODE_KEY_TAG_OFF, @intFromEnum(key.tag));
    try jccNativeExit(a, exit_labels, i, .ne);
    // 4. key identity guard by stable id: rcx = node key's *GcHeader (a LIVE
    //    node's key holds a valid pointer — guard 2 established liveness).
    try a.movRegMem(.rcx, .rax, node_off + layout.NODE_KEY_PAYLOAD_OFF);
    try a.cmpDwordMemImm(.rcx, layout.GCHEADER_ID_OFF, key_id);
    try jccNativeExit(a, exit_labels, i, .ne);
    // Cell pointer: &node.value.
    try a.addRegImm32(.rax, node_off + layout.NODE_VALUE_OFF);
    try regToPlace(a, placeOfRef(alloc, i), .rax);
}

/// `guard_absent` (doc 45 D7): prove the runtime raw lookup `t[k]` is still nil,
/// side-exiting when a value (or a metatable, or a non-table) has appeared.
///
/// The common numeric shape is INLINED — every check reads the table's LIVE
/// layout through the header pointer (lane, asize, data/present, hash size);
/// nothing is pinned to the recording's addresses, so lane widening, growth and
/// rehash between iterations are all observed truthfully:
///
///   1. `header.type == .table` and `metatable == null` — else the guard fails
///      (a metatable would dispatch `__index`; absence may not suppress it).
///   2. grid lane → full-lookup callout (virtual rows are never nil).
///   3. `key <u asize` (LuaJIT-style unsigned compare — rejects negative keys
///      via wrap, same as `ArrayPart.inArray`): in-array absence is the lane's
///      own nil encoding — bool lane in-band byte 0, `.value` lane nil tag,
///      numeric lanes a CLEAR presence-bitmap bit. All reads are behind the
///      bounds check; the bitmap is only dereferenced for bitmap lanes.
///   4. out of array: an EMPTY hash (live-entry count 0) proves absence with
///      no lookup at all — the binary-trees leaf shape `t[2]` on `{item}`.
///      A non-empty hash falls back to the callout (the key may be resident).
///
/// String keys always take the full-lookup callout (interning gives them no
/// cheap inline test). The callout is `table_runtime.isAbsent` — the SAME
/// predicate tier-1a runs, so every tier agrees by construction. The callout
/// preserves live homes via the shared save/restore ABI (`bodyCalloutOf` maps
/// this op, so the save area is reserved whenever the trace contains one —
/// even though the inline path usually skips the call).
pub fn emitGuardAbsent(
    a: *x64.Assembler,
    alloc: *const Alloc,
    kinds: []const Kind,
    ins: trace.IrInstr,
    i: usize,
    exit_labels: []?x64.Label,
) !void {
    const is_int_key = kinds[ins.b] == .int;
    const pass = try a.label();
    const callout = try a.label();

    if (is_int_key) {
        const lane_off: i32 = ArrLayout.array_base + ArrLayout.lane;
        // rax = table header. rax/rcx are the body scratch pair (never homes).
        try placeToReg(a, .rax, placeOfRef(alloc, ins.a));
        // 1. type + metatable (no qword cmp-mem-imm encoder → load and test).
        try a.cmpByteMemImm(.rax, HEADER_TYPE_OFF, TABLE_TYPE);
        try jccNativeExit(a, exit_labels, i, .ne); // not a table → guard fails
        try a.movRegMem(.rcx, .rax, METATABLE_OFF);
        try a.cmpRegImm32(.rcx, 0);
        try jccNativeExit(a, exit_labels, i, .ne); // metatable appeared → guard fails
        // 2. grid meta-lane → full lookup.
        try a.cmpByteMemImm(.rax, lane_off, @intCast(GRID_LANE));
        try a.jcc(.e, callout);
        // 3. bounds: key <u asize?
        try placeToReg(a, .rcx, placeOfRef(alloc, ins.b));
        try a.cmpRegMem(.rcx, .rax, ArrLayout.array_base + ArrLayout.asize);
        const in_array = try a.label();
        try a.jcc(.b, in_array);
        // 4. out of array: empty hash proves absence; else the callout decides.
        try a.cmpDwordMemImm(.rax, HASH_SIZE_FROM_HEADER, 0);
        try a.jcc(.ne, callout);
        try a.jmp(pass);

        a.bind(in_array);
        const bool_lane = try a.label();
        const value_lane = try a.label();
        try a.cmpByteMemImm(.rax, lane_off, @intCast(BOOL_LANE));
        try a.jcc(.e, bool_lane);
        try a.cmpByteMemImm(.rax, lane_off, @intCast(VALUE_LANE));
        try a.jcc(.e, value_lane);
        // Numeric lanes (i8…i64/u8/f64): presence bitmap — a SET bit means the
        // slot holds a value, so the absence guard fails.
        try a.movRegMem(.rax, .rax, ArrLayout.array_base + ArrLayout.present);
        try a.btMemReg(.rax, 0, .rcx);
        try jccNativeExit(a, exit_labels, i, .b); // CF=1 → present → guard fails
        try a.jmp(pass);

        a.bind(bool_lane); // in-band encoding: 0 = absent, 1 = false, 2 = true
        try a.movRegMem(.rax, .rax, ArrLayout.array_base + ArrLayout.data);
        try a.loadRegMemSib(.rax, .rax, .rcx, 1, false, 0); // movzx byte
        try a.cmpRegImm32(.rax, 0);
        try jccNativeExit(a, exit_labels, i, .ne); // non-zero byte → present
        try a.jmp(pass);

        a.bind(value_lane); // 16-byte tagged Values, nil in-band → tag probe
        try a.movRegMem(.rax, .rax, ArrLayout.array_base + ArrLayout.data);
        try a.shlRegImm8(.rcx, 4); // idx*16 (SIB can't scale by 16)
        try a.addRegReg(.rcx, .rax); // rcx = &data[idx]
        try a.cmpByteMemImm(.rcx, VALUE_TAG_OFF, TAG_NIL);
        try jccNativeExit(a, exit_labels, i, .ne); // non-nil tag → present
        try a.jmp(pass);
    }

    // Slow path (string keys unconditionally; int keys on grid / non-empty-hash
    // fallback): the shared full semantic lookup, THE predicate tier-1a runs.
    a.bind(callout);
    try emitCalloutSave(a, alloc);
    try placeToReg(a, .rdi, placeOfRef(alloc, ins.a));
    try placeToReg(a, .rsi, placeOfRef(alloc, ins.b));
    const runtime = @import("table_runtime.zig");
    const helper = if (is_int_key) @intFromPtr(&runtime.absentInt) else @intFromPtr(&runtime.absentString);
    try a.subRegImm32(.rsp, 8);
    try a.movRegImm64(.rax, @bitCast(@as(u64, helper)));
    try a.callReg(.rax);
    try a.addRegImm32(.rsp, 8);
    try a.movRegReg(.rcx, .rax);
    try emitCalloutRestore(a, alloc);
    try a.cmpRegImm32(.rcx, 0);
    try jccNativeExit(a, exit_labels, i, .e); // helper says "not absent" → guard fails
    a.bind(pass);
}

pub fn emitHStore(a: *x64.Assembler, kinds: []const Kind, alloc: *const Alloc, ins: trace.IrInstr) !void {
    if (kinds[ins.b] == .float) {
        // Stage the value into XMM_SCRATCH0 first (independent of rax/rcx), then
        // write tag + payload through the cell pointer.
        try floatOperandToXmm(a, XMM_SCRATCH0, placeOfRef(alloc, ins.b), .float);
        const creg = try refBaseReg(a, alloc, ins.a, .rcx);
        try a.movByteMemImm(creg, VALUE_TAG_OFF, TAG_FLOAT);
        try a.movsdMemReg(creg, VALUE_PAYLOAD_OFF, XMM_SCRATCH0);
    } else {
        // int OR bool (doc 43 P1). Load the value before resolving the cell
        // pointer: a spilled href resolves through rcx (never rax), and value
        // homes are outside rax/rcx. A `.bool` value is a clean 0/1 GP by
        // convention, so the raw 8-byte payload store reproduces
        // `Value.boolean`'s full-width layout bit-for-bit (as the int arm does
        // `Value.int`'s).
        try placeToReg(a, .rax, placeOfRef(alloc, ins.b));
        const creg = try refBaseReg(a, alloc, ins.a, .rcx);
        try a.movByteMemImm(creg, VALUE_TAG_OFF, if (kinds[ins.b] == .bool) TAG_BOOL else TAG_INT);
        try a.storeMemReg(creg, 8, VALUE_PAYLOAD_OFF, .rax);
    }
}

pub fn emitAStore(a: *x64.Assembler, t: *const Trace, kinds: []const Kind, alloc: *const Alloc, ins: trace.IrInstr) !void {
    const aref_ins = t.instrs[ins.a];
    if (ins.aux == VALUE_LANE) {
        // doc 32: `.value`-lane store — write a full tagged Value (tag byte + 8-byte
        // payload) and **no presence bit**; the lane has no bitmap (nil is in-band,
        // and the recorder aborts a nil store). Every value fits a type-erased lane,
        // so unlike the narrow lanes there is no width/range concern: the tag is what
        // preserves integer-vs-float identity, exactly as `emitHStore` does for a hash
        // cell. The seven padding bytes are left untouched — nothing observes them
        // (equality compares semantic fields; keyframe capture goes through
        // `array.get`), and tier-0's `encode` does not define them either.
        //
        // Address in rcx, computed index-first for the same reason as the VALUE_LANE
        // aload: `arrayFieldReg(…, .rax)` may return `.rax`, so the data base must be
        // fetched only after the index is already parked in scratch rcx.
        if (kinds[ins.b] == .float) {
            // Stage the value into XMM_SCRATCH0 before touching rax/rcx.
            try floatOperandToXmm(a, XMM_SCRATCH0, placeOfRef(alloc, ins.b), .float);
            const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
            try a.movRegReg(.rcx, ireg);
            try a.shlRegImm8(.rcx, 4);
            const datareg = try arrayFieldReg(a, alloc, aref_ins.a, .data, .rax);
            try a.addRegReg(.rcx, datareg); // rcx = &data[idx0] (Value*)
            try a.movByteMemImm(.rcx, VALUE_TAG_OFF, TAG_FLOAT);
            try a.movsdMemReg(.rcx, VALUE_PAYLOAD_OFF, XMM_SCRATCH0);
        } else {
            const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
            try a.movRegReg(.rcx, ireg);
            try a.shlRegImm8(.rcx, 4);
            const datareg = try arrayFieldReg(a, alloc, aref_ins.a, .data, .rax);
            try a.addRegReg(.rcx, datareg); // rcx = &data[idx0] (Value*)
            // Load the value into rax only now — the data base is already consumed,
            // and rcx (the address) is scratch so no value home can alias it.
            try placeToReg(a, .rax, placeOfRef(alloc, ins.b));
            try a.movByteMemImm(.rcx, VALUE_TAG_OFF, TAG_INT);
            try a.storeMemReg(.rcx, 8, VALUE_PAYLOAD_OFF, .rax);
        }
        return;
    }
    if (ins.aux == F64_LANE) {
        try floatOperandToXmm(a, XMM_SCRATCH0, placeOfRef(alloc, ins.b), .float);
        const datareg = try arrayFieldReg(a, alloc, aref_ins.a, .data, .rax);
        const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
        try a.leaRegMemSib(.rax, datareg, ireg, 8, 0);
        try a.movsdMemReg(.rax, 0, XMM_SCRATCH0);
        const preg = try arrayFieldReg(a, alloc, aref_ins.a, .present, .rax);
        const pireg = try refBaseReg(a, alloc, ins.a, .rcx);
        try a.btsMemReg(preg, 0, pireg);
    } else if (ins.aux == BOOL_LANE) {
        const datareg = try arrayFieldReg(a, alloc, aref_ins.a, .data, .rax);
        const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
        try a.leaRegMemSib(.rax, datareg, ireg, 1, 0);
        try placeToReg(a, .rcx, placeOfRef(alloc, ins.b));
        try a.incReg(.rcx);
        try a.storeMemReg(.rax, 1, 0, .rcx);
    } else {
        const w = intLaneWidth(ins.aux);
        const datareg = try arrayFieldReg(a, alloc, aref_ins.a, .data, .rax);
        const ireg = try refBaseReg(a, alloc, ins.a, .rcx);
        try a.leaRegMemSib(.rax, datareg, ireg, w, 0);
        try placeToReg(a, .rcx, placeOfRef(alloc, ins.b));
        try a.storeMemReg(.rax, w, 0, .rcx);

        const preg = try arrayFieldReg(a, alloc, aref_ins.a, .present, .rax);
        const pireg = try refBaseReg(a, alloc, ins.a, .rcx);
        try a.btsMemReg(preg, 0, pireg);
    }
}

pub fn emitGStore(a: *x64.Assembler, t: *const Trace, alloc: *const Alloc, ins: trace.IrInstr) !void {
    const gcell_ins = t.instrs[ins.a];
    const garow_ins = t.instrs[gcell_ins.a];
    if (ins.aux == F64_LANE) {
        try floatOperandToXmm(a, XMM_SCRATCH0, placeOfRef(alloc, ins.b), .float);
        const datareg = try arrayFieldReg(a, alloc, garow_ins.a, .data, .rax);
        const flatreg = try refBaseReg(a, alloc, ins.a, .rcx);
        try a.leaRegMemSib(.rax, datareg, flatreg, 8, 0);
        try a.movsdMemReg(.rax, 0, XMM_SCRATCH0);
    } else {
        const w = intLaneWidth(ins.aux);
        const datareg = try arrayFieldReg(a, alloc, garow_ins.a, .data, .rax);
        const flatreg = try refBaseReg(a, alloc, ins.a, .rcx);
        try a.leaRegMemSib(.rax, datareg, flatreg, w, 0);
        try placeToReg(a, .rcx, placeOfRef(alloc, ins.b));
        try a.storeMemReg(.rax, w, 0, .rcx);
    }
    const preg = try arrayFieldReg(a, alloc, garow_ins.a, .present, .rax);
    const pflat = try refBaseReg(a, alloc, ins.a, .rcx);
    try a.btsMemReg(preg, 0, pflat);
}

pub fn emitPhiValueFlush(a: *x64.Assembler, t: *const Trace, kinds: []const Kind, alloc: *const Alloc, p: trace.IrInstr) !void {
    const ref: usize = @intCast(p.b);
    const kind = kinds[ref];
    if (kind == .boxed) {
        try flushBoxedSlot(a, @as(i32, @intCast(p.aux)), try boxedTagSpill(t, kinds, alloc, ref), placeOfRef(alloc, ref));
    } else {
        try flushSlot(a, @as(i32, @intCast(p.aux)), kind, placeOfRef(alloc, ref));
    }
}

pub fn emitLinkedLoopDoneSnapshot(
    a: *x64.Assembler,
    t: *const Trace,
    kinds: []const Kind,
    alloc: *const Alloc,
    exit_instr: usize,
) !void {
    // Doc 39: unreachable for a peeled trace — the linked branch that creates
    // this stub's label is gated on `!t.peeled` in `lower`.
    std.debug.assert(!t.peeled);
    var si = exit_instr + 1;
    while (si < t.instrs.len) : (si += 1) {
        const p = t.instrs[si];
        switch (p.op) {
            .astore => try emitAStore(a, t, kinds, alloc, p),
            .hstore => try emitHStore(a, kinds, alloc, p),
            // Doc 43 P5: a loop-done-sunk closed-cell store — same Value-cell
            // shape as hstore, same emitter.
            .ustore => try emitHStore(a, kinds, alloc, p),
            .gstore => try emitGStore(a, t, alloc, p),
            .phi, .loop, .link => break,
            // Defensive belt: the linked branch is only emitted when
            // `loopDoneSnapshotSupported` accepted the range — now a closed
            // whitelist of exactly the store arms above — so ANY other op here
            // means the gate and this walk drifted apart. Fail the compile
            // rather than emit a snapshot that silently skips a store (the
            // sgm_setpos un-advanced-cursor bug class, generalized).
            else => return error.UnsupportedLoopDoneStore,
        }
    }

    const guard = t.instrs[exit_instr];
    const for_ins = t.anchor.proto.code[trace.guardSourcePc(guard).?];
    const visible_var_slot: i32 = @as(i32, @intCast(for_ins.a)) + 3;
    for (t.instrs) |p| {
        if (p.op != .phi or p.aux == trace.PHI_INTERNAL) continue;
        if (p.aux == visible_var_slot) continue;
        try emitPhiValueFlush(a, t, kinds, alloc, p);
    }
}

/// Part A-v (doc 17 §A2.1): materialize the bridge's compile-time set E.
/// Slot-bound phis are the trace successor's live VM-slot writebacks; only an
/// update defined before `exit_instr` dominates that guard. Post-guard phis and
/// internal optimizer phis are deliberately excluded.
pub fn emitCompositeBridgeSnapshot(
    a: *x64.Assembler,
    t: *const Trace,
    kinds: []const Kind,
    alloc: *const Alloc,
    exit_instr: usize,
) !void {
    var emitted = t.bridgeEmissions(exit_instr);
    while (emitted.next()) |p| {
        try emitPhiValueFlush(a, t, kinds, alloc, p);
    }
}
