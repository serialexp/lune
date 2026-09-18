//! Register/slot allocation for tier-1b native codegen (split from
//! `nativegen.zig`, file-split pass): `analyze` — the forward linear
//! scan that classifies tier-0 slots, computes per-ref liveness and
//! assigns every value a `Loc` (GP/XMM register or frame spill slot) —
//! plus the pure `Place` mapping the emitter addresses homes through.

const std = @import("std");
const x64 = @import("x64.zig");
const trace_ir = @import("trace_ir.zig");
const trace = trace_ir;
const trace_code = @import("trace_code.zig");
const layout = @import("nativegen_layout.zig");
const prove = @import("nativegen_prove.zig");
const mcode = @import("nativegen_mcode.zig");
const Reg = x64.Reg;
const Trace = trace_code.TraceCode;
const Kind = @import("nativegen_artifact.zig").Kind;
const SeedPlan = @import("nativegen_artifact.zig").SeedPlan;
const NativeSeedCtx = trace_code.NativeSeedCtx;
const isNumKind = prove.isNumKind;
const operandReads = prove.operandReads;
const laneKind = layout.laneKind;
const konstFitsLane = layout.konstFitsLane;
const VALUE_LANE = layout.VALUE_LANE;
const GRID_LANE = layout.GRID_LANE;
const BOOL_LANE = layout.BOOL_LANE;
const SPILL_MAX = mcode.SPILL_MAX;

// ---------------------------------------------------------------------------
// cut-2: register allocation + single-snapshot deopt — the analysis half
//
// `analyze` is a forward linear-scan over the linear SSA that (a) classifies each
// tier-0 slot the trace touches, (b) computes per-ref liveness, and (c) assigns
// every value a `Loc` (a CPU register or a frame spill slot). It is *pure analysis*:
// `lower` consumes its output in later commits. Landed first as a measured no-op so
// the risky logic rides under the existing differential oracle.
// ---------------------------------------------------------------------------

/// Where a value lives during the loop body.
pub const Loc = union(enum) {
    reg: Reg, // a general-purpose register (int/bool/ptr/aref)
    xmm: Reg, // an XMM register (float) — same 0..15 index space, disjoint pool
    spill: u32, // frame slot index; byte displacement = index * 8 (kind-agnostic 8-B cell)
};

/// How a slot participates in the loop, deciding its prologue/back-edge/EXIT handling.
pub const SlotClass = enum {
    /// slot_loaded AND in exit_stores: read+write loop-carried. Gets a home; flushed
    /// to regs[] on a side-exit; reassigned at the back-edge shuffle.
    carried,
    /// slot_loaded, NOT in exit_stores: read-only, loop-invariant. Loaded once into a
    /// home; never written back (untouched ⇒ coherent).
    invariant,
    /// in exit_stores, NOT slot_loaded (e.g. `flag = i<limit`). No home; committed to
    /// regs[] at the back-edge (cut-1 style); never touched at EXIT.
    write_only,
};

/// Compile-time facts about one tier-0 slot.
pub const SlotInfo = struct {
    slot: u16,
    class: SlotClass,
    kind: Kind, // box tag at commit/flush (int/ptr for carried/invariant; store_ref's for write_only)
    home: Loc, // valid for carried/invariant
    load_ref: i32, // the slot_load ref, or -1
    store_ref: i32, // the exit_store ref feeding it, or -1
    /// For a `.ptr` (table) invariant slot: the bool-lane ordinal its `guard_lane`
    /// pins, checked once in the prologue. `-1` for non-`.ptr` slots.
    lane: i32,
    /// For a `.func` (cross-frame callee snapshot) invariant slot: the recorded
    /// `Proto.id` its covering `guard_func` pins, checked once in the prologue
    /// (closure type + this id). Unused (0) for non-`.func` slots.
    func_id: u32 = 0,
    /// For a `.native` (pure-builtin callee snapshot) invariant slot: the recorded
    /// `RecordedBuiltin` ordinal its covering `guard_builtin` pins, checked once in the
    /// prologue (native type + this tag's payload byte + the non-null flag). `-1` for
    /// non-`.native` slots.
    recorded_tag: i32 = -1,
    /// For a `.ptr` table accessed as a GRID (doc 14): the `grid_elem` lane ordinal
    /// (an int lane) its covering `guard_grid` pins and the `stride` its
    /// `guard_stride` pins, both checked once in the prologue (`array.grid_elem ==
    /// grid_elem ∧ array.stride == grid_stride`; `s.lane` is set to `GRID_LANE` so
    /// the shared lane check verifies `array.lane == .grid`). `-1` when the slot is
    /// not a grid table. `grid_stride` is also the folded immediate `gcell` uses for
    /// its `row*stride` multiply — sound because the prologue proved it equals the
    /// runtime stride and no traced store grows it (the recorder aborts a grow).
    grid_elem: i32 = -1,
    grid_stride: i32 = -1,
    /// doc 24 c3: an invariant `.heap` slot pinned by a covering `guard_string`
    /// (an observed-string input to the snew ops / `slen`). The prologue verifies
    /// `header.type == string` once — the slot is read-only in the trace (a
    /// carried string bails in classification), so the pin holds for the whole
    /// native run. `false` for every other slot.
    is_string: bool = false,
    /// win 2: the store_ref transient was allocated *into* home, so the op updates the
    /// home in place and the back-edge shuffle move for this slot self-elides. Only set
    /// for `carried` slots passing the safety predicate (see `analyzeInner`).
    coalesced: bool,
    /// Doc 39 (peeled trace): the ref of this slot's INTERNAL (steady-state) φ —
    /// the slot-bound φ's `a` association stamped by the recorder — or -1. When
    /// >= 0 the slot's post-run-once value lives in that φ's computed home, not in
    /// `home`: `home` holds the ENTRY value (iteration 1's class, used only by the
    /// run-once region), the back-edge shuffle skips the slot home entirely (the
    /// internal-φ move carries the value; the home's register class may not even
    /// match the steady kind), and every deopt flush re-boxes from the steady
    /// home with `steady_kind`. Only ever set for `t.peeled` traces.
    steady_phi: i32 = -1,
    /// Kind of the steady-state value (`kinds[steady_phi]`); equals `kind` for a
    /// type-stable carried slot, differs (int entry → float steady) for a widened
    /// one. `.none` when `steady_phi < 0`.
    steady_kind: Kind = .none,
    /// Phase 2 (invariant array-base hoisting): for a `.ptr` slot used as an
    /// `aref.a`, the loop-invariant array base pointers / length, materialized ONCE
    /// in the prologue into a dedicated register and reused across every iteration
    /// (instead of re-loading `[tbreg+field]` each time). `null` ⇒ not hoisted (no
    /// free register, or the field is unused) and the body keeps the per-iteration
    /// load — correctness never depends on seating. Valid for the whole native run
    /// by the B5 invariant: the read/write path never reallocates or lane-widens the
    /// array (`guard_fits` side-exits first). Pure invariant scratch — never written
    /// back to `regs[]` on exit.
    data_home: ?Reg = null, // [array_base + data]  (element pointer)
    present_home: ?Reg = null, // [array_base + present] (int-lane presence bitmap ptr)
    len_home: ?Reg = null, // [array_base + asize]   (slot count / bounds limit, for guard_bounds)
};

/// The allocator's output — the sole input `lower` needs (later commits).
pub const Alloc = struct {
    loc: []Loc, // [n] location of each ref's value (slot_load refs resolve to their home)
    last_use: []u32, // [n] index of the last instruction reading each ref
    slot_id_of_ref: []i32, // [n] slots[] index for a slot_load ref, else -1
    slots: []SlotInfo,
    spill_count: u32, // frame slots used (homes + transients); frame = spill_count*8
    used_callee_saved: u16, // bitmask of callee-saved GPRs used (must be push/pop'd)

    // --- callout save area (Phase 2, .value-lane href) ---
    // When a trace contains a .heap-rooted href (per-iteration hash-cell
    // resolution via `resolveHashCell`), the callout clobbers all SysV
    // caller-saved registers. Live homes in those registers must be saved
    // to the frame before the call and restored after. These fields describe
    // the save area appended to the spill region (slots callout_save_base ..
    // callout_save_base + callout_save_count - 1).
    callout_save_base: u32 = 0, // first spill-slot index of save area
    callout_save_count: u32 = 0, // number of 8-byte slots reserved

    // --- rdx park slot for the inline int mod/idiv lowering (doc 25 D1) ---
    // `idiv` clobbers rdx:rax unconditionally and rdx carries the live
    // `*NativeResult` all body long, so `emitIntDivMod` parks rdx here for
    // the duration of the instruction. An allocator-OWNED unique spill slot
    // (codex medium): consumed from `spill_count` wholly outside the callout
    // save region — never its alignment-padding slot — so it can't alias a
    // spilled operand or the callout's own saved rdx. Addressed `div_save*8`.
    div_save: ?u32 = null,

    // --- tnew out-param word (doc 45 D6) ---
    // The `table_runtime.tnew` callout writes its `**Table` result through a
    // pointer. A DEDICATED allocator-owned frame word (codex: never the
    // callout region's alignment-padding slot — that would alias the
    // callout's own `sub rsp, 8` bracket). One word serves every tnew in the
    // body: the out-param is strictly instruction-local. Addressed
    // `tnew_out*8`; null when the trace allocates no tables.
    tnew_out: ?u32 = null,

    pub fn deinit(self: *Alloc, gpa: std.mem.Allocator) void {
        gpa.free(self.loc);
        gpa.free(self.last_use);
        gpa.free(self.slot_id_of_ref);
        gpa.free(self.slots);
        self.* = undefined;
    }
};

/// 1<<reg as a 16-bit register-set bit.
pub fn regBit(r: Reg) u16 {
    return @as(u16, 1) << @intFromEnum(r);
}

/// Allocatable GPRs, in preference order: caller-saved first (no prologue save), then
/// callee-saved (push/pop'd). Excludes rax/rcx (scratch), rbx (completed), rsp, rdi
/// (tags base), rsi (payloads base), and rdx (native result out-param).
pub const ALLOC_ORDER = [_]Reg{ .r8, .r9, .r10, .r11, .rbp, .r12, .r13, .r14, .r15 };
pub const CALLEE_SAVED_MASK: u16 = regBit(.rbp) | regBit(.r12) | regBit(.r13) | regBit(.r14) | regBit(.r15);

/// Preference order for Phase-2 invariant array-base homes: `ALLOC_ORDER` reversed,
/// so base pointers claim the callee-saved tail (r15…r12, rbp) the body's linear
/// scan only reaches under register pressure. A low-pressure trace (e.g. nsieve)
/// therefore hoists its array bases without displacing any hot transient into a
/// spill; a high-pressure one simply leaves a base un-hoisted (per-iter load).
pub const BASE_HOME_ORDER = [_]Reg{ .r15, .r14, .r13, .r12, .rbp, .r11, .r10, .r9, .r8 };

/// Allocatable XMM registers (Phase D float homes/transients). xmm0/xmm1 are the
/// float scratch pair (the SSE analogue of rax/rcx) — never allocated; xmm2..xmm15
/// are the pool. On the SysV/Linux ABI every XMM is *caller-saved*, so a float home
/// needs no prologue save (the `fn([*]Value) callconv(.c)` target owns them all) —
/// hence no XMM analogue of `CALLEE_SAVED_MASK`. The `Reg` indices are reused for
/// XMM (same 0..15 ModRM/REX bits); a `Loc.xmm`/`Place.xmm` tag keeps them disjoint
/// from the identically-indexed GP registers.
pub const XMM_ALLOC_ORDER = [_]Reg{
    x64.xmm2,  x64.xmm3,  x64.xmm4,  x64.xmm5,  x64.xmm6,  x64.xmm7,
    x64.xmm8,  x64.xmm9,  x64.xmm10, x64.xmm11, x64.xmm12, x64.xmm13,
    x64.xmm14, x64.xmm15,
};
/// The float scratch pair (analogue of rax/rcx), reserved out of the pool above.
pub const XMM_SCRATCH0: Reg = x64.xmm0;
pub const XMM_SCRATCH1: Reg = x64.xmm1;

pub const AnalyzeError = std.mem.Allocator.Error || error{
    /// cut-2 cannot represent this trace (type-instability, etc.). The caller bails;
    /// the cut-1 stack-slot path (or tier-1a) handles it correctly.
    Bail,
};

/// True iff `op` produces a register-resident value that gets its own location (i.e. a
/// transient: konst / arithmetic / compare). slot_loads resolve to a slot home; guards
/// and the loop marker produce no value.
pub fn isTransient(op: trace_ir.IrOp) bool {
    return switch (op) {
        .konst, .add, .sub, .mul, .div, .band, .bor, .bxor, .shl, .shr, .sar, .neg, .bnot, .eq, .ne, .lt, .le => true,
        // aref materializes idx0 in a register; aload materializes the decoded bool.
        .aref, .aload => true,
        // int_of_float materializes the converted int limit in a register; alen
        // the border int.
        .int_of_float, .ffloor, .fceil, .alen => true,
        // fsqrt materializes the `@sqrt` result in a float home (XMM/spill);
        // fsin/fcos/pow materialize their `fmath` kernel callout's result
        // likewise.
        .fsqrt, .fsin, .fcos, .pow => true,
        // doc 25: int mod/idiv materialize the floor-adjusted idiv result in
        // a GP home; the float lane its fmath kernel callout result in a
        // float home.
        .mod, .idiv => true,
        // doc 24: tostr_* materialize the interned `*GcHeader` in a GP home;
        // slen the cp_len int. The snew class (c3) likewise materializes its
        // fresh-or-interned `*GcHeader` result in a GP home.
        .tostr_int, .tostr_num, .slen, .ssub, .srev, .schar1, .srep2 => true,
        // doc 26: the case producers materialize their `*GcHeader` in a GP
        // home like the snew class; scp its scalar codepoint int.
        .supper, .slower, .scp => true,
        // doc 30: the match/parse class materialize their status / index /
        // scratch word / `*GcHeader` / parsed number in a home. sgm_setpos
        // and guard_sid are value-less effects/guards — NOT here.
        .sfindp, .smatch, .sgmatch, .scap_int, .scap_str, .str2num_i, .str2num_f => true,
        // href materializes the seeded cell pointer in a register (like aref); hload
        // materializes the decoded scalar field value. hstore/guard_hash are effects.
        // Doc 43 P5: uref/uload are their closed-upvalue-cell twins (uref the
        // seeded cell pointer, uload the decoded scalar); ustore is an effect.
        .href, .hload, .uref, .uload => true,
        // grid (doc 14): garow materializes the row base (row0, like aref), gcell the
        // flat cell index, gload the decoded int cell. gstore/the grid guards are
        // effects/value-less.
        .garow, .gcell, .gload => true,
        // doc 45 D6: tnew materializes the fresh `*Table`'s `*GcHeader` in a
        // GP home (kind `.heap`), like the snew producer class.
        .tnew => true,
        else => false,
    };
}

/// True iff the op's two operands may be swapped without changing the result. Used
/// both for operand coalescing (either operand's dying register may be reused) and to
/// let the ALU emitter avoid a staging move when the in-register operand is `b`.
pub fn isCommutative(op: trace_ir.IrOp) bool {
    return switch (op) {
        .add, .mul, .band, .bor, .bxor, .eq, .ne => true,
        else => false, // sub, lt, le are order-sensitive
    };
}

// operandReads lives in nativegen_prove.zig (file-split pass); aliased below.

/// Whether two `Loc`s name the same physical home (register or spill slot).
pub fn locEql(x: Loc, y: Loc) bool {
    return Place.eql(locToPlace(x), locToPlace(y));
}

/// Ops whose result can be computed *into* a destination home in place (win 2). A
/// compare result is Bool, never carried (type-stability bails), and konst has no
/// operand to anchor the home — so only arithmetic/bitwise + unary qualify.
/// [doc 30 c4b] Ops whose result is BY CONSTRUCTION an interned `*String` —
/// the `is_string[i] = true` PRODUCER arms of proveKinds Pass B (tostr/snew/
/// case/scap_str classes; NOT the guard-derived sources: a string-guarded
/// slot_load or string konst proves only its own value, not a writeback).
/// Used by the carried-string classification arm: a slot may carry a `.heap`
/// value across iterations only when the φ writeback is one of these. Keep
/// this list a SUBSET of proveKinds' producer set — a missing op merely bails
/// a compilable trace (fail closed); an op here that proveKinds does not
/// treat as a string would be type confusion in the body's static string
/// facts (`slen`, snew operands).
pub fn isStringProducerOp(op: trace_ir.IrOp) bool {
    return switch (op) {
        .tostr_int, .tostr_num, .ssub, .srev, .schar1, .srep2, .supper, .slower, .scap_str => true,
        else => false,
    };
}

pub fn isCoalescibleOp(op: trace_ir.IrOp) bool {
    return switch (op) {
        .add, .sub, .mul, .band, .bor, .bxor, .neg, .bnot => true,
        else => false,
    };
}

/// Find a slot in the list or append a fresh (unclassified) entry; returns its index.
pub fn findOrAddSlot(slots: *std.ArrayListUnmanaged(SlotInfo), gpa: std.mem.Allocator, slot: u16) !usize {
    for (slots.items, 0..) |s, id| {
        if (s.slot == slot) return id;
    }
    try slots.append(gpa, .{
        .slot = slot,
        .class = undefined,
        .kind = .none,
        .home = undefined,
        .load_ref = -1,
        .store_ref = -1,
        .lane = -1,
        .coalesced = false,
    });
    return slots.items.len - 1;
}

/// See module header. Returns `null` to bail (cut-2 cannot compile this trace); the
/// caller falls back. Runs only on a `proveKinds`-accepted trace, so every op is in the
/// supported subset and `kinds`/`slot_of` are filled.
pub fn analyze(gpa: std.mem.Allocator, t: *const Trace, kinds: []const Kind, slot_of: []const i32) ?Alloc {
    return analyzeInner(gpa, t, kinds, slot_of) catch |e| switch (e) {
        error.Bail, error.OutOfMemory => null,
    };
}

pub fn analyzeInner(gpa: std.mem.Allocator, t: *const Trace, kinds: []const Kind, slot_of: []const i32) AnalyzeError!Alloc {
    const n = t.instrs.len;

    // Phase E1/E2: the preheader marker (if any) splits the trace into a run-once
    // region (index < marker) and the per-iteration body. Run-once value refs and
    // every internal φ get a *computed home* — a register/spill held across the whole
    // loop, written once in the prologue (an internal φ also updates at the back-edge),
    // and NEVER flushed at deopt (they back no tier-0 slot; tier-0 recomputes on replay).
    var marker_idx: ?usize = null;
    for (t.instrs, 0..) |ins, i| {
        if (ins.op == .preheader) {
            marker_idx = i;
            break;
        }
    }

    var slots: std.ArrayListUnmanaged(SlotInfo) = .empty;
    errdefer slots.deinit(gpa);

    const slot_id_of_ref = try gpa.alloc(i32, n);
    errdefer gpa.free(slot_id_of_ref);
    @memset(slot_id_of_ref, -1);

    // --- classification: gather slot_loads, then slot-bound φ writebacks ---
    for (t.instrs, 0..) |ins, i| {
        if (ins.op != .slot_load) continue;
        const slot: u16 = @intCast(slot_of[i]); // validated >= 0 in proveKinds
        const id = try findOrAddSlot(&slots, gpa, slot);
        slots.items[id].load_ref = @intCast(i);
        slot_id_of_ref[i] = @intCast(id);
    }
    // A slot-bound φ (aux >= 0) is the loop-carried writeback the old exit_store was:
    // `aux` is the tier-0 slot, `b` is the body value carried to the next iteration.
    // Internal φs (aux == PHI_INTERNAL) back no slot — they get a computed home in a
    // later phase, not a slot class here.
    for (t.instrs) |ins| {
        if (ins.op != .phi or ins.aux < 0) continue;
        const id = try findOrAddSlot(&slots, gpa, @intCast(ins.aux));
        slots.items[id].store_ref = ins.b;
    }
    for (slots.items) |*s| {
        const loaded = s.load_ref >= 0;
        const stored = s.store_ref >= 0;
        if (loaded and stored and t.instrs[n - 1].op == .terminal) {
            // A one-shot root never feeds its snapshot back into its own
            // prologue. Keep the entry home immutable, independently of the
            // outgoing value's kind. Terminal lowering reads store_ref and
            // boxes that value separately; failed guards leave entry regs intact.
            s.class = .invariant;
            s.kind = kinds[@intCast(s.load_ref)];
        } else if (loaded and stored) {
            s.class = .carried;
            // A carried slot is treated as ONE boxable scalar kind end-to-end: the
            // prologue tag-checks it, the body keeps it in a same-class home, and the
            // deopt flush re-boxes it with that tag. Phase D widens the admissible set
            // from int to {int, float}; bool/ptr/aref carried still bail.
            const lk = kinds[@intCast(s.load_ref)];
            const sk = kinds[@intCast(s.store_ref)];
            if (lk == .ptr and (sk == .ptr or sk == .heap)) {
                // [doc 22 §A.1] Carried-heap: a guard_table-covered table slot whose φ
                // writeback is itself a table (`bi = b[i]` — a VALUE_LANE aload result,
                // or another table slot_load). The slot's kind becomes `.heap`, NOT
                // `.ptr`: every `.ptr`-keyed analysis and prologue hoist (lane/grid
                // pinning, C2 type+metatable checks, array-base homes) then skips it by
                // kind mismatch, because those entry-time facts describe only the first
                // iteration's table. The home is a GP register/spill holding the current
                // `*GcHeader`, refreshed by the back-edge φ shuffle; in-body table facts
                // come from the DYNAMIC forms (per-iteration guard_table/guard_hash, the
                // resolveHashCell href callout) via `isCarriedHeapRoot`, and both the
                // entry tag-check and every flush use TAG_HEAP. Structural bails below
                // refuse anything this cut cannot check per-iteration (array/grid roots).
                s.kind = .heap;
            } else if (lk == .heap and sk == .heap) {
                // [doc 30 c4b] Carried STRING: a `guard_string`-covered slot whose φ
                // writeback is a STATIC string producer — the gmatch for-in's loop
                // variable, where each iteration's `w` is the fresh `scap_str`
                // result. Soundness is split across the iterations exactly like
                // carried-heap tables, but with a STRONGER entry pin and a STRONGER
                // writeback proof, because the body's string facts (`slen`, snew
                // operands) are static — there are no per-iteration dynamic guards
                // to fall back on:
                //   * iteration 1 (the entry value): `is_string` makes the prologue
                //     keep the FULL guard_string pin — the [RV-1] TAG_HEAP tag-lane
                //     check plus `header.type == string`;
                //   * iterations 2+ (the carried value): the writeback must be a
                //     producer whose result is a `*String` by construction
                //     (`isStringProducerOp`), so string-ness holds with no check.
                // The home is a GP register/spill holding the current `*GcHeader`,
                // refreshed by the back-edge φ shuffle; every flush uses TAG_HEAP
                // (heap boxing is type-agnostic — the type lives in the header).
                // The [doc 22 §A.2] GC-admission sweep below already covers this
                // slot (keyed on kind `.heap`, any class), and the structural bails
                // refuse any table-shaped op rooted at it. An unpinned `.heap` load
                // or a non-producer writeback (e.g. a `.ptr` table masquerading
                // through kind `.heap`) fails closed.
                const lref: u16 = @intCast(s.load_ref);
                var pinned = false;
                for (t.instrs) |g| {
                    if (g.op == .guard_string and g.a == lref) {
                        pinned = true;
                        break;
                    }
                }
                if (!pinned) return error.Bail;
                if (!isStringProducerOp(t.instrs[@intCast(s.store_ref)].op)) return error.Bail;
                s.kind = .heap;
                s.is_string = true;
            } else if (lk == .boxed and sk == .boxed) {
                // One-shot boxed pass-through: the payload home is raw bits and
                // terminal writeback copies the tag lane separately. It is never
                // inspected or loop-carried (proveKinds gates both properties).
                s.kind = .boxed;
            } else if (lk == .none) {
                // Doc 45 D6: WRITE-DOMINATED carried slot — the entry load is
                // snapshot-only (`.none`: the body never reads it; it exists
                // because a precise recording force-loads the whole window)
                // while the φ writeback re-defines the slot every iteration
                // (`local t = {}`). The home carries the STORE class, and the
                // prologue tag-check pins the ENTRY value to that same class,
                // which is what makes the pre-first-write snapshot flush
                // byte-exact: re-boxing payload bits under the checked tag
                // reproduces the entry Value verbatim (TAG_HEAP boxing is
                // type-agnostic, so any heap object — table, string —
                // round-trips; int/float likewise under their checked tag).
                // An entry value of a different class refuses in the prologue
                // → tier-1a, fail closed. `.bool` stays refused: the [RV-1]
                // tag switch has no TAG_BOOL row for slot pins.
                if (sk == .int or sk == .float or sk == .heap) {
                    s.kind = sk;
                } else if (sk == .ptr) {
                    s.kind = .heap; // raw *GcHeader → TAG_HEAP boxing
                } else {
                    return error.Bail;
                }
            } else {
                // [RV-4 / review P0] The *load* class fixes the prologue tag-check and the
                // home's register class. Outside the carried-heap and carried-string
                // cases above, a `.ptr` load carried would skip the table/lane checks
                // and reinterpret an int/float payload as a `*GcHeader` → type
                // confusion; only a boxable scalar may be carried.
                if (lk != .int and lk != .float) return error.Bail;
                // [RV-3] type-stability: the store class must match the load class in a
                // `.loop` trace. A slot loaded int but stored float (or vice versa)
                // would pass the once-hoisted prologue guard forever while the oracle
                // re-checks every iteration and deopts — and the home's register class
                // (GP vs XMM) would be wrong.
                //
                // doc 34: `.link` traces are exempt. Their phis write to `regs[]` and
                // then control transfers to a DIFFERENT trace (the link target) with
                // its own prologue and guards. The type of the phi writeback is
                // re-checked by the receiving trace's prologue, so type instability
                // between load and store is safe — the link trace never loops back
                // into its own body. The deopt flush re-boxes the value with whatever
                // tag it actually has, which is correct. The slot's home class follows
                // the LOAD type (the prologue pin). The `.link` terminal flush
                // (below) tags the store value with its own kind, not the slot's.
                if (sk != lk) {
                    if ((t.instrs[n - 1].op == .link or t.instrs[n - 1].op == .terminal) and isNumKind(lk) and isNumKind(sk)) {
                        // Accept: the slot homes as the load class; the φ writeback
                        // converts at the one-shot flush. Doc 44: a `.terminal`
                        // head close shares `.link`'s exemption verbatim — it
                        // never loops back into its own body either, and tier-0
                        // re-checks types at the resume pc.
                    } else if (t.peeled and isNumKind(lk) and isNumKind(sk)) {
                        // Doc 39: a peeled trace's widened carried slot (int entry,
                        // float steady state). Accepted iff the peeled post-pass
                        // below finds the slot-bound φ's steady-φ association —
                        // the entry home keeps the load class (the prologue keeps
                        // demanding TAG_INT, which is what fresh instances
                        // present); the steady value lives in the internal φ's
                        // computed home and every flush re-boxes from there.
                    } else {
                        return error.Bail;
                    }
                }
                s.kind = lk;
            }
        } else if (loaded) {
            s.class = .invariant;
            // int OR ptr (a guard_table-covered table slot, read-only loop-invariant).
            s.kind = kinds[@intCast(s.load_ref)];
        } else {
            s.class = .write_only;
            s.kind = kinds[@intCast(s.store_ref)];
        }
    }
    // Doc 39: peeled-trace steady-φ association. For every carried slot of a
    // peeled trace, connect the slot to its internal (steady-state) φ via the
    // slot-bound φ's `a` field (stamped by the recorder at commit;
    // assertWellFormed pins that a nonzero `a` points at a PHI_INTERNAL φ).
    // Post-run-once, the slot's live value rides that φ's computed home — the
    // entry home is DEAD after iteration 1 (all slot_load uses are in the
    // run-once region), so the back-edge shuffle skips it and the deopt flush
    // reads the steady home instead. Fail-closed rules:
    //   * widened slot (store kind ≠ load kind) with NO steady φ → Bail: the
    //     back-edge move into the load-class home would be class-mismatched and
    //     the flush tag wrong. (`a == 0` means the body pass never read the
    //     slot before writing it — a shape v1 does not home.)
    //   * steady φ present but its kind ≠ the store kind → Bail (malformed).
    //   * scalar carried only: the carried-heap/carried-string classes keep
    //     their own machinery (their per-iteration facts are body-anchored) —
    //     v1 refuses them in a peeled trace rather than reasoning about their
    //     run-once/steady split.
    if (t.peeled) {
        for (slots.items) |*s| {
            if (s.class != .carried) continue;
            if (s.kind == .heap or s.kind == .ptr) return error.Bail;
            const sk = kinds[@intCast(s.store_ref)];
            // Find this slot's slot-bound φ and read its steady association.
            var steady: i32 = -1;
            for (t.instrs) |p| {
                if (p.op == .phi and p.aux >= 0 and @as(u16, @intCast(p.aux)) == s.slot) {
                    if (p.a != 0) steady = @intCast(p.a);
                    break;
                }
            }
            if (steady >= 0) {
                if (kinds[@intCast(steady)] != sk) return error.Bail;
                s.steady_phi = steady;
                s.steady_kind = sk;
            } else if (sk != s.kind) {
                return error.Bail; // widened but write-only-in-body: no steady home
            }
        }
    }

    // [doc 22 §A.1, fail closed] Structural bails for carried-heap slots. The
    // `.ptr`-keyed lane/grid analyses below skip a carried-heap slot by kind
    // mismatch — which means an aref/garow rooted at one would otherwise compile
    // SILENTLY with no lane pin and a first-iteration-only base. Refuse instead:
    // this cut supports exactly the hash-path ops (href/guard_table/guard_hash),
    // whose dynamic in-body forms re-check the CURRENT table each iteration. And
    // those dynamic forms are only per-iteration if they sit in the body — a
    // placement before the preheader marker would run once, checking iteration
    // 1's table only, so that too is refused.
    for (slots.items) |s| {
        if (s.class != .carried or s.kind != .heap) continue;
        const lr: u16 = @intCast(s.load_ref);
        const ms: usize = marker_idx orelse 0;
        for (t.instrs, 0..) |g, gi| {
            switch (g.op) {
                // No entry-hoisted per-table fact may root at a per-iteration table.
                .aref, .garow, .guard_lane, .guard_grid, .guard_stride => {
                    if (g.a == lr) return error.Bail;
                },
                .guard_table, .href => if (g.a == lr and gi < ms) return error.Bail,
                .guard_hash => if (t.instrs[g.a].a == lr and gi < ms) return error.Bail,
                else => {},
            }
        }
    }
    // [doc 22 §A.2] Heap-φ GC admission: a `.heap`-kind slot (carried OR
    // write-only) keeps a raw `*GcHeader` unrooted in a register/spill across the
    // body, sound only while no body callout can trigger a collection. Check every
    // callout against the HelperCaps table; refuse the trace if any may GC.
    {
        var has_heap_phi = false;
        for (slots.items) |s| {
            if (s.kind == .heap) {
                has_heap_phi = true;
                break;
            }
        }
        if (has_heap_phi) {
            for (0..n) |ci| {
                if (bodyCalloutOf(t, kinds, slots.items, slot_id_of_ref, ci)) |c| {
                    if (calloutMayCollect(c)) return error.Bail;
                }
            }
        }
    }
    // A `.ptr` (table) invariant slot accessed as an ARRAY needs the lane its
    // `guard_lane` pins, so the prologue can check it once. Locate the guard_lane
    // covering the slot_load. A table accessed only via the HASH part (H1: `href`,
    // no `aref`) carries no array lane — the recorder emits `guard_table` but no
    // `guard_lane` — so `s.lane` stays -1 and the prologue skips the lane check (the
    // data/present/len array-base hoist is likewise keyed on aref usage, so a
    // hash-only slot gets none). A table used BOTH ways has the guard_lane and is
    // pinned normally. The table-type + metatable prologue checks cover the hash
    // path's validity regardless of lane.
    for (slots.items) |*s| {
        if (s.kind != .ptr) continue;
        if (s.class == .write_only) continue;
        const lr: u16 = @intCast(s.load_ref);
        // An aref on this slot REQUIRES a guard_lane (the recorder always emits both);
        // a malformed trace with array access but no lane would miscompile, so track it.
        var has_aref = false;
        for (t.instrs) |g| {
            if (g.op == .aref and g.a == lr) has_aref = true;
            if (g.op == .guard_lane and g.a == lr) s.lane = g.aux;
        }
        if (has_aref and s.lane < 0) return error.Bail; // array access without a pinned lane
    }
    // A `.ptr` table accessed as a GRID (doc 14) carries no `guard_lane`; instead a
    // `guard_grid` pins `lane == .grid ∧ grid_elem` and a `guard_stride` pins the row
    // width. Tag the slot with the meta-lane GRID_LANE plus the recorded grid_elem and
    // stride so the prologue can verify all three once per entry. A table is a grid OR
    // a scalar array at any instant — never both — so a slot already carrying a scalar
    // lane (set above) here is malformed; bail rather than miscompile.
    for (slots.items) |*s| {
        if (s.kind != .ptr) continue;
        if (s.class == .write_only) continue;
        const lr: u16 = @intCast(s.load_ref);
        var has_garow = false;
        var ge: i32 = -1;
        var gs: i32 = -1;
        for (t.instrs) |g| {
            if (g.op == .garow and g.a == lr) has_garow = true;
            if (g.op == .guard_grid and g.a == lr) ge = g.aux;
            if (g.op == .guard_stride and g.a == lr) gs = g.aux;
        }
        if (!has_garow) continue;
        if (s.lane >= 0 or ge < 0 or gs < 0) return error.Bail;
        s.lane = GRID_LANE;
        s.grid_elem = ge;
        s.grid_stride = gs;
    }
    // A `.func` (cross-frame callee snapshot) invariant slot carries the recorded
    // `Proto.id` from its covering `guard_func`, checked once in the prologue (the
    // upvalue/global cell is re-resolved + re-seeded each entry, so it cannot change
    // within a native run). Locate the guard_func and stash its id on the slot.
    for (slots.items) |*s| {
        if (s.kind != .func) continue;
        // Doc 44: a WRITE-ONLY `.func` slot (a head trace's φ writeback of the
        // callee closure into the child frame) is never prologue-checked — the
        // guard_func covers the LOADED snapshot slot, and the flush re-boxes
        // the already-verified pointer. No id to stash.
        if (s.load_ref < 0) continue;
        const lr: u16 = @intCast(s.load_ref);
        var found = false;
        for (t.instrs) |g| {
            if (g.op == .guard_func and g.a == lr) {
                if (found and @as(u32, @bitCast(g.aux)) != s.func_id) {
                    // Two guard_funcs on one snapshot with *different* recorded ids:
                    // the prologue checks one id, but the oracle re-checks each and
                    // would side-exit on the second — a divergence. The recorder never
                    // emits this (dedup → one synthetic slot → one resolved closure →
                    // one id), so it can only arise malformed. Bail, don't miscompile.
                    return error.Bail;
                }
                s.func_id = @bitCast(g.aux);
                found = true;
            }
        }
        // proveKinds only set .func via a guard_func, so one always exists.
        // Defensive: bail rather than miscompile.
        if (!found) return error.Bail;
    }
    // A `.native` (pure-builtin callee snapshot) invariant slot carries the recorded
    // `RecordedBuiltin` ordinal from its covering `guard_builtin`, checked once in the
    // prologue (the upvalue/global cell is re-resolved + re-seeded each entry, so it
    // cannot change within a native run). Locate the guard_builtin and stash its tag.
    for (slots.items) |*s| {
        if (s.kind != .native) continue;
        // Same write-only guard as the `.func` loop above: no load → no
        // prologue identity check → nothing to stash.
        if (s.load_ref < 0) continue;
        const lr: u16 = @intCast(s.load_ref);
        var found = false;
        for (t.instrs) |g| {
            if (g.op == .guard_builtin and g.a == lr) {
                if (found and g.aux != s.recorded_tag) {
                    // Two guard_builtins on one snapshot with *different* recorded tags:
                    // the prologue checks one, but the oracle re-checks each and would
                    // side-exit on the second — a divergence. The recorder never emits
                    // this (one seeded callee → one tag), so it can only arise malformed.
                    return error.Bail;
                }
                s.recorded_tag = g.aux;
                found = true;
            }
        }
        // proveKinds only set .native via a guard_builtin, so one always exists.
        if (!found) return error.Bail;
    }
    // A `.heap` INVARIANT slot (doc 24 c3) can only arise via a covering
    // `guard_string` (proveKinds' sole path to an invariant `.heap` slot_load);
    // tag it so the prologue emits the once-per-entry `header.type == string`
    // check. Defensive: bail rather than miscompile if no guard is found — an
    // unpinned invariant heap slot would let a table payload flow into the snew
    // callouts as a `*String`. (A CARRIED `.heap` string slot got the same
    // `is_string` tag — plus the writeback-producer proof — in the doc 30 c4b
    // classification arm above; this block is the invariant half only.)
    for (slots.items) |*s| {
        if (s.class != .invariant or s.kind != .heap) continue;
        const lr: u16 = @intCast(s.load_ref);
        var found = false;
        for (t.instrs) |g| {
            if (g.op == .guard_string and g.a == lr) {
                found = true;
                break;
            }
        }
        if (!found) return error.Bail;
        s.is_string = true;
    }

    // --- liveness: last_use, single backward pass; carried/write store_refs live to the marker ---
    const last_use = try gpa.alloc(u32, n);
    errdefer gpa.free(last_use);
    for (last_use, 0..) |*lu, i| lu.* = @intCast(i); // live at least at its own def
    {
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            const ins = t.instrs[i];
            const rd = operandReads(ins);
            if (rd.a and last_use[ins.a] < i) last_use[ins.a] = @intCast(i);
            if (rd.b and last_use[ins.b] < i) last_use[ins.b] = @intCast(i);
        }
    }
    // The value feeding ANY φ's back-edge update (slot-bound OR internal) must survive
    // to the shuffle/commit at the terminal `loop` (operandReads does not count φ.b, so
    // this explicit extension is its only liveness — exactly as the old exit_store had).
    for (t.instrs) |ins| {
        if (ins.op != .phi) continue;
        if (last_use[ins.b] < n - 1) last_use[ins.b] = @intCast(n - 1);
    }
    // A dynamically-rooted href reads ins.a (the per-iteration *GcHeader — a
    // VALUE_LANE aload result, or a carried-heap slot_load) but
    // `operandReads(.href)` returns {false, false} (the loop-invariant path reads
    // from the seeded slab slot, not from operand refs). Extend the root's
    // liveness here so it survives to the href and the guard_hash that follows it.
    // guard_hash also reads href_ins.a (the same root) to check hash population.
    // (For a carried-heap slot_load the extension is a no-op — its loc IS the
    // pinned slot home — but routing both roots through the one predicate keeps
    // analysis and lowering deciding identically.)
    for (t.instrs, 0..) |ins, i| {
        if (ins.op == .href and isDynTableRoot(kinds, slots.items, slot_id_of_ref, ins.a)) {
            if (last_use[ins.a] < i) last_use[ins.a] = @intCast(i);
        }
        if (ins.op == .guard_hash) {
            const href_ins = t.instrs[ins.a];
            if (isDynTableRoot(kinds, slots.items, slot_id_of_ref, href_ins.a)) {
                if (last_use[href_ins.a] < i) last_use[href_ins.a] = @intCast(i);
            }
        }
        // doc 43 P3: aref consumers reach the TABLE lazily through `aref.a`
        // (arrayFieldReg / the guard_bounds asize fallback), but operandReads
        // counts only the aref token — sound for a `.ptr` root (the table
        // lives in a pinned slot home for the whole trace), unsound for a
        // dynamic root (an hload'd table field / VALUE_LANE element), whose
        // SSA range would otherwise end at its last DIRECT use and hand the
        // consumers a recycled register as the "table". Extend the root's
        // liveness to every reach-through consumer, the dyn-href precedent.
        switch (ins.op) {
            .guard_bounds, .guard_present, .guard_append, .aload, .astore, .astore_append => {
                const aref_ins = t.instrs[ins.a];
                if (aref_ins.op == .aref and isDynTableRoot(kinds, slots.items, slot_id_of_ref, aref_ins.a)) {
                    if (last_use[aref_ins.a] < i) last_use[aref_ins.a] = @intCast(i);
                }
            },
            else => {},
        }
        // ssub (doc 24 c3) and scp (doc 26) read a THIRD operand — the
        // end-index ref in `aux` — which `operandReads`' two-field shape
        // cannot express. Extend its liveness here, exactly as the dyn-href
        // root above, so the end index survives to the callout's staging
        // (ssub → rcx, scp → rdx).
        if (ins.op == .ssub or ins.op == .scp or ins.op == .sfindp or ins.op == .smatch) {
            // Doc 30: sfindp/smatch join the ternary club — their PATTERN
            // ref rides `aux` and must survive to the callout staging.
            const ar: usize = @intCast(ins.aux);
            if (last_use[ar] < i) last_use[ar] = @intCast(i);
        }
    }
    // Doc 45 D6 (codex point 1): PRECISE snapshot refs are read by the
    // per-snapshot exit materializers, which `operandReads` cannot see.
    // Extend every captured ref's liveness to each exit that can materialize
    // it — BEFORE any allocation decision — or the flush would read a
    // recycled register/spill. Only ops that can actually take a precise exit
    // (`requiresPreciseSnapshot`: side-exit guards + tnew) extend; the snap a
    // pure arithmetic op carries can never be materialized, so extending for
    // it would only waste registers. Runs only on precise traces (no snap
    // anywhere otherwise); refs were range-validated by compileImpl.
    if (t.deopt_mode == .precise) {
        for (t.instrs, 0..) |ins, i| {
            if (ins.snap == 0 or !trace_ir.requiresPreciseSnapshot(ins.op)) continue;
            const rec = t.snapshots[ins.snap - 1];
            for (t.snapshot_slots[rec.slots_begin..][0..rec.slots_len]) |ss| {
                if (last_use[ss.ref] < i) last_use[ss.ref] = @intCast(i);
            }
        }
    }

    // --- allocation: pin slot homes, then linear-scan the transients ---
    const loc = try gpa.alloc(Loc, n);
    errdefer gpa.free(loc);
    for (loc) |*l| l.* = .{ .spill = 0 }; // placeholder for value-less refs (guards/loop)

    var free: u16 = comptime blk: {
        var m: u16 = 0;
        for (ALLOC_ORDER) |r| m |= regBit(r);
        break :blk m;
    };
    // The disjoint XMM pool (Phase D). Bits are the same 0..15 index space; a float
    // home/transient draws from here, an int/bool/ptr from `free`.
    var free_xmm: u16 = comptime blk: {
        var m: u16 = 0;
        for (XMM_ALLOC_ORDER) |r| m |= regBit(r);
        break :blk m;
    };
    var spill_count: u32 = 0;
    var used_callee: u16 = 0;
    var home_reg_mask: u16 = 0;
    var home_xmm_mask: u16 = 0;

    for (slots.items) |*s| {
        if (s.class == .write_only) continue;
        // Doc 45 D6: a snapshot-only load (kind `.none` — a dead anchor-window
        // slot the precise recorder force-loaded so full-window snapshots have
        // a ref) gets NO home: the body never reads it, the exit materializers
        // SKIP it (its slab slot is untouched, so the slab is already
        // current), and pinning a home would burn a register per dead slot.
        if (s.kind == .none) continue;
        if (s.kind == .float) {
            // Float home: draw from the XMM pool, else a shared 8-byte spill cell.
            if (pickRegFrom(&free_xmm, &XMM_ALLOC_ORDER)) |r| {
                s.home = .{ .xmm = r };
                home_xmm_mask |= regBit(r);
            } else {
                s.home = .{ .spill = spill_count };
                spill_count += 1;
            }
        } else if (pickReg(&free)) |r| {
            s.home = .{ .reg = r };
            home_reg_mask |= regBit(r);
            used_callee |= regBit(r) & CALLEE_SAVED_MASK;
        } else {
            s.home = .{ .spill = spill_count };
            spill_count += 1;
        }
    }
    // Resolve slot_load refs to their slot home. A `.none` (snapshot-only)
    // slot has no home — its loc stays the value-less placeholder, and every
    // consumer (there are none in the body; exit materializers skip it) must
    // never read it.
    for (t.instrs, 0..) |ins, i| {
        if (ins.op != .slot_load) continue;
        const s = slots.items[@intCast(slot_id_of_ref[i])];
        if (s.kind == .none) continue;
        loc[i] = s.home;
    }

    // --- computed homes (Phase E1/E2) ---
    // Pin a persistent home for every run-once value (preheader transient) and every
    // internal φ, drawing from the same pools as slot homes (so their registers are
    // reserved out of the body linear scan). The scan then skips these refs. A φ's home
    // is updated at the back-edge; a preheader value's is written once in the prologue.
    const is_computed = try gpa.alloc(bool, n);
    defer gpa.free(is_computed);
    @memset(is_computed, false);
    {
        const ms = marker_idx orelse 0;
        for (t.instrs, 0..) |ins, i| {
            const is_pre_val = marker_idx != null and i < ms and isTransient(ins.op);
            const is_int_phi = ins.op == .phi and ins.aux == trace.PHI_INTERNAL;
            if (!is_pre_val and !is_int_phi) continue;
            if (is_int_phi) {
                // The init must be a run-once value (a < marker), so the prologue
                // init-move reads a home already materialized before `loop_top`.
                if (marker_idx == null or ins.a >= ms) return error.Bail;
                // ... and one with a PERSISTENT location the seed move can read:
                // a run-once transient (computed home, this same block) or a
                // slot_load (slot home). LICM inits are always transients; a
                // peeled trace's init is an arbitrary iteration-1 ref, so
                // anything else (a scan-allocated non-transient producer whose
                // register may be reused) fails closed.
                const init_op = t.instrs[ins.a].op;
                if (!isTransient(init_op) and init_op != .slot_load) return error.Bail;
            }
            switch (kinds[i]) {
                .float => {
                    if (pickRegFrom(&free_xmm, &XMM_ALLOC_ORDER)) |r| {
                        loc[i] = .{ .xmm = r };
                        home_xmm_mask |= regBit(r);
                    } else {
                        loc[i] = .{ .spill = spill_count };
                        spill_count += 1;
                    }
                },
                .int, .bool => {
                    if (pickReg(&free)) |r| {
                        loc[i] = .{ .reg = r };
                        home_reg_mask |= regBit(r);
                        used_callee |= regBit(r) & CALLEE_SAVED_MASK;
                    } else {
                        loc[i] = .{ .spill = spill_count };
                        spill_count += 1;
                    }
                },
                // A computed home must carry a boxable scalar; anything else (a `.ptr`/
                // `.aref` hoisted into the preheader, or a mis-typed φ) cannot be homed.
                else => return error.Bail,
            }
            is_computed[i] = true;
        }
    }

    // --- Phase 2: reserve invariant array-base homes ---------------------------------
    // For each `.ptr` slot used as an `aref.a`, the array `data`/`present` pointers and
    // `len` are loop-invariant across a native run (B5: the path never reallocates or
    // lane-widens — `guard_fits` side-exits first). Materialize each *once* in the
    // prologue into a dedicated register instead of re-loading `[tbreg+field]` every
    // iteration. Only the fields the body actually reads are reserved, drawn from the
    // callee-saved tail (`BASE_HOME_ORDER`) so a low-pressure trace hoists for free
    // while a high-pressure one falls back to the per-iteration load (a `null` home).
    // Reserved here — after computed homes, before coalescing + the body linear scan —
    // so neither reuses these registers; folded into `home_reg_mask`/`used_callee` so
    // the disjointness assertions and prologue push/pop already cover them.
    {
        const ns = slots.items.len;
        const need_data = try gpa.alloc(bool, ns);
        defer gpa.free(need_data);
        const need_present = try gpa.alloc(bool, ns);
        defer gpa.free(need_present);
        const need_len = try gpa.alloc(bool, ns);
        defer gpa.free(need_len);
        @memset(need_data, false);
        @memset(need_present, false);
        @memset(need_len, false);

        // Which array base each consuming op needs, attributed to the `.ptr` slot its
        // address operand roots at. (guard_bounds → len; bool guard_present/aload/astore
        // → data; int guard_present → present; int astore/astore_append → data + present.)
        // astore_append also bumps len in memory, but via a re-fetched table pointer in
        // rax (no len_home for an append trace), so it needs no len reservation here.
        //
        // A scalar array op roots ONE hop (aref.a == table slot_load); a grid op
        // (doc 14) roots TWO hops (gcell.a == garow, garow.a == table slot_load). Its
        // grid guard_bounds is on the GAROW, whose `.a` is already the table slot_load,
        // so it falls into the one-hop arm below unchanged. The cell ops (gload/gstore/
        // guard_gpresent) carry the gcell and need the extra hop.
        for (t.instrs) |ins| {
            var sid_signed: i32 = -1;
            var is_bool = false;
            var is_value = false;
            switch (ins.op) {
                .guard_bounds, .guard_present, .aload, .astore, .astore_append => {
                    const aref_ins = t.instrs[@intCast(ins.a)];
                    sid_signed = slot_id_of_ref[aref_ins.a];
                    is_bool = aref_ins.aux == BOOL_LANE;
                    is_value = aref_ins.aux == VALUE_LANE;
                },
                .gload, .gstore, .guard_gpresent => {
                    const gcell_ins = t.instrs[@intCast(ins.a)];
                    const garow_ins = t.instrs[@intCast(gcell_ins.a)];
                    sid_signed = slot_id_of_ref[garow_ins.a]; // two hops to the table slot
                },
                else => continue,
            }
            if (sid_signed < 0) continue; // table operand isn't a slot home — leave per-iter
            const sid: usize = @intCast(sid_signed);
            switch (ins.op) {
                .guard_bounds => need_len[sid] = true,
                .guard_present => if (is_bool) {
                    need_data[sid] = true;
                } else {
                    need_present[sid] = true;
                },
                .aload => need_data[sid] = true,
                .astore, .astore_append => {
                    need_data[sid] = true;
                    // The bool lane carries presence in-band (one byte per slot) and the
                    // `.value` lane has no presence bitmap at all (`present` is null, nil
                    // is an in-band tag) — reserving a base register for either would be a
                    // wasted home, and for `.value` a load through a null pointer.
                    if (!is_bool and !is_value) need_present[sid] = true;
                },
                // Grid cells (doc 14) are int-lane only in this cut: a load needs the
                // data base; a store needs data + the presence bitmap; a presence guard
                // needs only the bitmap.
                .gload => need_data[sid] = true,
                .guard_gpresent => need_present[sid] = true,
                .gstore => {
                    need_data[sid] = true;
                    need_present[sid] = true;
                },
                else => unreachable,
            }
        }

        // An astore_append bumps `len` in memory only (no len_home writeback — see the
        // lowering), so a `len` register hoisted by a sibling guard_bounds on the same
        // table would go stale the moment the append commits. Don't hoist `len` for any
        // trace that contains an astore_append; guard_bounds then reloads `len` from the
        // table each iteration (always the committed value). A pure append fill has no
        // guard_bounds, so this costs it nothing.
        var has_append = false;
        for (t.instrs) |ins| {
            if (ins.op == .astore_append) {
                has_append = true;
                break;
            }
        }
        for (slots.items, 0..) |*s, sid| {
            if (s.class == .write_only) continue;
            if (need_data[sid]) {
                if (pickRegFrom(&free, &BASE_HOME_ORDER)) |r| {
                    s.data_home = r;
                    home_reg_mask |= regBit(r);
                    used_callee |= regBit(r) & CALLEE_SAVED_MASK;
                }
            }
            if (need_present[sid]) {
                if (pickRegFrom(&free, &BASE_HOME_ORDER)) |r| {
                    s.present_home = r;
                    home_reg_mask |= regBit(r);
                    used_callee |= regBit(r) & CALLEE_SAVED_MASK;
                }
            }
            if (need_len[sid] and !has_append) {
                if (pickRegFrom(&free, &BASE_HOME_ORDER)) |r| {
                    s.len_home = r;
                    home_reg_mask |= regBit(r);
                    used_callee |= regBit(r) & CALLEE_SAVED_MASK;
                }
            }
        }
    }

    // --- home coalescing (win 2): allocate a carried slot's store_ref transient INTO
    // the slot's home, so the op updates the home in place AND the back-edge shuffle
    // self-elides. Gated by a safety predicate (cuts-2's single-snapshot model assumes
    // homes are written only at the back-edge; an in-place update breaks that unless no
    // side-exit follows it). Must run BEFORE the linear scan so it sees loc[j] fixed.
    const is_coalesced_home = try gpa.alloc(bool, n);
    defer gpa.free(is_coalesced_home);
    @memset(is_coalesced_home, false);
    {
        // The last side-exiting instruction. An in-place home update that PRECEDES
        // any mid-body side-exit would be committed by the deopt flush even though
        // the iteration aborted — so home coalescing must be blocked past the last
        // of them. `opMayExitInBody` is the closed inventory of every exit the body
        // emitter can produce (the hoisted guards — guard_int/guard_lane and the
        // `.ptr` forms of guard_table/guard_hash — never exit mid-body; their
        // dynamic per-iteration forms and the href callout DO). Trace order is
        // straight-line, so index order == dominance: "after" == strictly greater
        // index.
        var last_body_guard: i64 = -1;
        for (0..n) |idx| {
            if (opMayExitInBody(t, kinds, slots.items, slot_id_of_ref, idx)) last_body_guard = @intCast(idx);
        }
        for (slots.items, 0..) |*s, sid| {
            if (s.class != .carried) continue;
            // Doc 39: never coalesce in a peeled trace. A steady-φ slot's entry
            // home is DEAD after the run-once region — pinning a body transient
            // into it would resurrect it with (potentially) the wrong register
            // class, and the back-edge shuffle deliberately skips these homes.
            if (s.steady_phi >= 0) continue;
            // [Phase D] Float coalescing is disabled in the first cut: SSE has no
            // `op [mem],xmm` store form and a float op always materializes into a
            // scratch XMM before writing its home, so there is no in-place win to
            // capture. Skip — the back-edge shuffle handles the float carry.
            if (s.kind == .float) continue;
            // doc 34: a type-unstable carried slot (`.link` exemption) homes as the
            // load kind, but its phi store_ref may be a different numeric kind.
            // Coalescing a float-kind store_ref into an int-kind GP home → unreachable
            // in the float lowering. Skip coalescing entirely for type-unstable slots.
            if (kinds[@intCast(s.store_ref)] != s.kind) continue;
            const j: usize = @intCast(s.store_ref);
            const def = t.instrs[j];
            if (!isCoalescibleOp(def.op)) continue;
            // (1) no side-exit follows the in-place update.
            if (@as(i64, @intCast(j)) <= last_body_guard) continue;
            // [RV] imul has no [mem],reg store form → a spilled-home mul can't go in place.
            if (def.op == .mul and s.home != .reg) continue;
            // (2) S's OLD value is fully dead by j: no slot_load(S) ref is read after j.
            // (The operand read at j itself has last_use == j ≤ j, which is fine.)
            var old_live = false;
            for (0..n) |r2| {
                if (slot_id_of_ref[r2] == @as(i32, @intCast(sid)) and last_use[r2] > j) {
                    old_live = true;
                    break;
                }
            }
            if (old_live) continue;
            // (3) home(S) holds an operand at the op: left operand is home (any op), or a
            // commutative op's right operand is home. Unary requires its sole operand.
            const a_home = operandReads(def).a and locEql(loc[def.a], s.home);
            const b_home = operandReads(def).b and locEql(loc[def.b], s.home);
            const op_ok = a_home or (b_home and isCommutative(def.op));
            if (!op_ok) continue;
            // Coalesce: pin the transient into the home, mark the slot, and extend the
            // transient's live range to the loop marker so the scan never frees the home
            // [RV: the coalesced value IS snapshot state from j onward].
            loc[j] = s.home;
            s.coalesced = true;
            is_coalesced_home[j] = true;
            if (last_use[j] < n - 1) last_use[j] = @intCast(n - 1);
        }
    }

    // Linear scan over transient defs in index order; active set ≤ pool size. A
    // second, parallel active set tracks the XMM pool (float transients) — the two
    // register files expire independently into `free` / `free_xmm`.
    var active: [ALLOC_ORDER.len]struct { reg: Reg, last: u32 } = undefined;
    var active_len: usize = 0;
    var active_xmm: [XMM_ALLOC_ORDER.len]struct { reg: Reg, last: u32 } = undefined;
    var active_xmm_len: usize = 0;
    for (t.instrs, 0..) |ins, i| {
        if (!isTransient(ins.op)) continue;
        // expire GP transients whose last use precedes i
        var w: usize = 0;
        for (active[0..active_len]) |e| {
            if (e.last < i) {
                free |= regBit(e.reg);
            } else {
                active[w] = e;
                w += 1;
            }
        }
        active_len = w;
        // expire XMM transients likewise
        var wx: usize = 0;
        for (active_xmm[0..active_xmm_len]) |e| {
            if (e.last < i) {
                free_xmm |= regBit(e.reg);
            } else {
                active_xmm[wx] = e;
                wx += 1;
            }
        }
        active_xmm_len = wx;

        // A win-2 transient is already pinned to its slot home — never reallocate it.
        if (is_coalesced_home[i]) continue;
        // A run-once preheader value already has a computed home (pinned above, its
        // register reserved out of the pool) — never reallocate or expire it.
        if (is_computed[i]) continue;

        // [Phase D] A float transient draws from the XMM pool. Operand coalescing
        // (win 1) is disabled for floats (the value always lands in a scratch XMM
        // first — see the win-2 skip above), so allocate a fresh XMM or a spill cell.
        if (kinds[i] == .float) {
            if (pickRegFrom(&free_xmm, &XMM_ALLOC_ORDER)) |r| {
                loc[i] = .{ .xmm = r };
                active_xmm[active_xmm_len] = .{ .reg = r, .last = last_use[i] };
                active_xmm_len += 1;
            } else {
                loc[i] = .{ .spill = spill_count };
                spill_count += 1;
            }
            continue;
        }

        // --- operand coalescing (win 1): reuse a *dying* operand's register for the
        // result, emitting an in-place `op dst, b` instead of staging through rax.
        // The operand must (a) live in a register, (b) NOT be a slot home — reusing a
        // home would clobber a loop-carried value mid-iteration [RV: location-based,
        // not slot_id<0, so it stays correct once win-2 puts transients in homes] —
        // and (c) die exactly here (last_use == i). For commutative ops either operand
        // qualifies; otherwise only `a` (the destructive-write target).
        const rd = operandReads(ins);
        var coalesced: ?Reg = null;
        const cands = [2]struct { ref: usize, ok: bool }{
            .{ .ref = ins.a, .ok = rd.a },
            .{ .ref = ins.b, .ok = rd.b and isCommutative(ins.op) },
        };
        for (cands) |c| {
            if (!c.ok) continue;
            if (loc[c.ref] != .reg) continue;
            const r = loc[c.ref].reg;
            if (home_reg_mask & regBit(r) != 0) continue;
            if (last_use[c.ref] != i) continue;
            // Repurpose the operand's active entry for the result's live range.
            for (active[0..active_len]) |*e| {
                if (e.reg == r) {
                    e.last = last_use[i];
                    coalesced = r;
                    break;
                }
            }
            if (coalesced != null) break;
        }
        if (coalesced) |r| {
            loc[i] = .{ .reg = r };
        } else if (pickReg(&free)) |r| {
            loc[i] = .{ .reg = r };
            used_callee |= regBit(r) & CALLEE_SAVED_MASK;
            active[active_len] = .{ .reg = r, .last = last_use[i] };
            active_len += 1;
        } else {
            loc[i] = .{ .spill = spill_count };
            spill_count += 1;
        }
    }

    // --- invariant assertions (compiled out in release; the structural guardrail) ---
    if (std.debug.runtime_safety) {
        // homes are register-disjoint, tracked per register file (a GP reg and the
        // XMM of the same 0..15 index are physically distinct → never alias).
        var seen: u16 = 0;
        var seen_xmm: u16 = 0;
        for (slots.items) |s| {
            if (s.class == .write_only) continue;
            switch (s.home) {
                .reg => |r| {
                    const b = regBit(r);
                    std.debug.assert(seen & b == 0);
                    seen |= b;
                },
                .xmm => |r| {
                    const b = regBit(r);
                    std.debug.assert(seen_xmm & b == 0);
                    seen_xmm |= b;
                },
                .spill => {},
            }
        }
        // Computed homes (preheader values + internal φs) are also register-disjoint
        // from slot homes and from each other (drawn from the same pools after slots).
        for (0..n) |i| {
            if (!is_computed[i]) continue;
            switch (loc[i]) {
                .reg => |r| {
                    const b = regBit(r);
                    std.debug.assert(seen & b == 0);
                    seen |= b;
                },
                .xmm => |r| {
                    const b = regBit(r);
                    std.debug.assert(seen_xmm & b == 0);
                    seen_xmm |= b;
                },
                .spill => {},
            }
        }
        // [Phase 2] Invariant array-base homes are register-disjoint from slot homes,
        // computed homes, and each other (drawn from `free` after both, each pick
        // clearing its bit). They are GP-only and folded into `home_reg_mask`.
        for (slots.items) |s| {
            for ([_]?Reg{ s.data_home, s.present_home, s.len_home }) |maybe| {
                if (maybe) |r| {
                    const b = regBit(r);
                    std.debug.assert(seen & b == 0);
                    seen |= b;
                    std.debug.assert(home_reg_mask & b != 0); // must be reserved out of the body
                }
            }
        }
        // no transient register aliases a home register (per file) — except a win-2
        // transient (pinned INTO its slot's home) or a computed home (pinned above).
        for (t.instrs, 0..) |ins, i| {
            if (!isTransient(ins.op)) continue;
            if (is_coalesced_home[i] or is_computed[i]) continue;
            switch (loc[i]) {
                .reg => |r| std.debug.assert(home_reg_mask & regBit(r) == 0),
                .xmm => |r| std.debug.assert(home_xmm_mask & regBit(r) == 0),
                .spill => {},
            }
        }
        // every slot-bound φ's back-edge update ref has a concrete location (always does)
        for (t.instrs) |ins| {
            if (ins.op != .phi or ins.aux < 0) continue;
            const l = loc[ins.b];
            std.debug.assert(l == .reg or l == .xmm or l == .spill);
        }
    }

    // --- callout save area (any BodyCallout in the body) ---
    // If any instruction in this trace lowers to a mid-body callout (a
    // dynamically-rooted href's `resolveHashCell`, an fsin/fcos `fmath` kernel
    // call, …), the callout clobbers all SysV caller-saved registers. Reserve
    // frame slots to save/restore live homes. The predicate is `bodyCalloutOf`
    // itself — the SAME mapping the lowering and the heap-φ GC audit dispatch
    // on — so a new callout can never silently miss its save area.
    var callout_save_base: u32 = 0;
    var callout_save_count: u32 = 0;
    {
        var needs_callout = false;
        for (t.instrs, 0..) |_, ci| {
            if (bodyCalloutOf(t, kinds, slots.items, slot_id_of_ref, ci) != null) {
                needs_callout = true;
                break;
            }
        }
        if (needs_callout) {
            callout_save_base = spill_count;
            // The callout clobbers ALL SysV caller-saved registers. We must save
            // not just slot homes but also transient registers that may be live
            // across the callout (e.g. a float hload result from a prior field
            // access in the same iteration, still alive at the second href).
            // Simplest correct approach: save ALL caller-saved GP and XMM
            // allocatable registers unconditionally, plus rdi/rsi (SoA bases)
            // and rdx (*NativeResult out-param, used at side-exits).
            var count: u32 = 3; // rdi + rsi + rdx
            // All allocatable caller-saved GPRs: r8, r9, r10, r11.
            count += 4;
            // All allocatable XMMs: xmm2–xmm15 (XMM_ALLOC_ORDER, 14 regs).
            count += XMM_ALLOC_ORDER.len;
            callout_save_count = count;
            // +1 for the alignment padding slot: the JIT body runs with
            // rsp % 16 == 8 (correct for the JIT's own return convention but
            // wrong for an outgoing SysV call). `emitHrefCallout` does
            // `sub rsp, 8` before the call and `add rsp, 8` after — the
            // extra slot ensures this doesn't underflow the frame.
            spill_count += count + 1;
        }
    }

    // --- rdx park slot for inline int mod/idiv (doc 25 D1) ---
    // Reserved AFTER the callout region so it can never alias it (codex
    // medium). One slot serves every int mod/idiv in the body — the park is
    // strictly instruction-local, never live across two of them.
    var div_save: ?u32 = null;
    for (t.instrs) |ins| {
        if ((ins.op == .mod or ins.op == .idiv) and ins.ty == .int) {
            div_save = spill_count;
            spill_count += 1;
            break;
        }
    }

    // --- tnew out-param word (doc 45 D6) ---
    // Same discipline as div_save: reserved after the callout region, one
    // dedicated word, never the padding slot (see the field doc on `Alloc`).
    var tnew_out: ?u32 = null;
    for (t.instrs) |ins| {
        if (ins.op == .tnew) {
            tnew_out = spill_count;
            spill_count += 1;
            break;
        }
    }

    return .{
        .loc = loc,
        .last_use = last_use,
        .slot_id_of_ref = slot_id_of_ref,
        .slots = try slots.toOwnedSlice(gpa),
        .spill_count = spill_count,
        .used_callee_saved = used_callee,
        .callout_save_base = callout_save_base,
        .callout_save_count = callout_save_count,
        .div_save = div_save,
        .tnew_out = tnew_out,
    };
}

/// Pop the first free register in `ALLOC_ORDER` preference, clearing its bit. Null if none.
pub fn pickReg(free: *u16) ?Reg {
    return pickRegFrom(free, &ALLOC_ORDER);
}

/// Pop the first free register in the given preference order, clearing its bit. Null
/// if none. Shared by the GP pool (`ALLOC_ORDER`) and the XMM pool (`XMM_ALLOC_ORDER`).
pub fn pickRegFrom(free: *u16, order: []const Reg) ?Reg {
    for (order) |r| {
        const b = regBit(r);
        if (free.* & b != 0) {
            free.* &= ~b;
            return r;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// cut-2: lowering helpers — a `Place` is where a value sits (a register or a frame
// slot at an rsp displacement). The body keeps slot homes in registers and transients
// in frame slots (commit B); commit C moves transients to registers too.
// ---------------------------------------------------------------------------

pub const Place = union(enum) {
    reg: Reg, // a general-purpose register
    xmm: Reg, // an XMM register (float). Distinct tag → a GP reg and the XMM of the
    // same 0..15 index never compare equal (they are physically distinct registers).
    mem: i32, // rsp-relative byte displacement (kind-agnostic 8-B cell)

    // pub for nativegen.zig's emitters (file-split pass).
    pub fn eql(x: Place, y: Place) bool {
        if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
        return switch (x) {
            .reg => x.reg == y.reg,
            .xmm => x.xmm == y.xmm,
            .mem => x.mem == y.mem,
        };
    }
};

/// Map an allocation `Loc` to a `Place`: a register stays a register; a spill slot
/// becomes a frame displacement `[rsp + idx*8]`.
pub fn locToPlace(l: Loc) Place {
    return switch (l) {
        .reg => |r| .{ .reg = r },
        .xmm => |r| .{ .xmm = r },
        .spill => |idx| .{ .mem = @as(i32, @intCast(idx)) * 8 },
    };
}

/// The home of a carried/invariant slot: its assigned register or spill slot.
pub fn slotHomePlace(s: SlotInfo) Place {
    return locToPlace(s.home);
}

/// Where ref `r`'s value lives — its linear-scan-assigned register or frame slot.
/// A `slot_load` ref resolves to its slot home (its `loc` was set to that home).
pub fn placeOfRef(alloc: *const Alloc, r: usize) Place {
    return locToPlace(alloc.loc[r]);
}

// ---------------------------------------------------------------------------
// doc 22 §A.1b: carried-heap roots and per-iteration table facts
//
// A *carried-heap* slot (class == .carried, kind == .heap) holds a table whose
// identity changes at every back-edge (`bi = b[i]`-shaped φ writeback). Any
// entry-time fact about that table — the seeded hash cell, the prologue's
// type/metatable/lane checks, a hoisted array base — describes only the FIRST
// iteration's table, so every table-rooted op on such a slot must use its
// dynamic in-body form (exactly the forms the `.heap`-kind aload roots already
// use). These predicates are the single decision point, shared by analysis
// (liveness, coalescing safety, save-area sizing) and lowering.

/// True iff `ref` is the slot_load of a carried-heap slot.
pub fn isCarriedHeapRoot(slots: []const SlotInfo, slot_id_of_ref: []const i32, ref: u16) bool {
    const sid = slot_id_of_ref[ref];
    if (sid < 0) return false;
    const s = slots[@intCast(sid)];
    return s.class == .carried and s.kind == .heap;
}

/// True iff a table-rooted op at `ref` cannot rely on entry-time facts: the root
/// is a per-iteration `.heap` value (VALUE_LANE aload result) or a carried-heap
/// slot. An href on such a root needs the `resolveHashCell` callout; its
/// guard_table/guard_hash need their dynamic in-body forms.
pub fn isDynTableRoot(kinds: []const Kind, slots: []const SlotInfo, slot_id_of_ref: []const i32, ref: u16) bool {
    return kinds[ref] == .heap or isCarriedHeapRoot(slots, slot_id_of_ref, ref);
}

/// Doc 49 P5: the aux an href at `idx` actually lowers with. A SEEDED href
/// (`aux >= 0`) whose root turns out dynamic at emission (carried-heap — the
/// recorder saw a `slot_load`, the body's φ rewrites the slot each iteration)
/// cannot read its slab slot: `computeSeedPlan` deactivates the seed. If the
/// recorder stamped a valid hrefk `(slot, mask)` hint into that seed
/// (`InputSeed.hrefk_aux`), lower to hrefk inline guards instead of the
/// `resolveHashCell` callout; `-1` (no hint) keeps today's callout. Every aux
/// consumer that dispatches a dyn-rooted href's lowering — the save-frame
/// reservation (`bodyCalloutOf`) and the emit dispatch — MUST route through
/// this one helper so they decide identically (a mismatch is either a missing
/// save frame under a callout, or a dead reserved frame).
pub fn effectiveHrefAux(
    t: *const Trace,
    kinds: []const Kind,
    slots: []const SlotInfo,
    slot_id_of_ref: []const i32,
    idx: usize,
) i32 {
    const ins = t.instrs[idx];
    std.debug.assert(ins.op == .href);
    if (ins.aux < 0) return ins.aux; // hrefk or callout: already emission-final
    if (!isDynTableRoot(kinds, slots, slot_id_of_ref, ins.a)) return ins.aux; // live seed
    for (t.inputs) |seed| {
        if (seed.kind == .hash_cell and @as(i32, seed.slot) == ins.aux)
            return seed.hrefk_aux;
    }
    // A seed slot with no matching seed is malformed; fail closed to the
    // callout, whose runtime resolution needs no recorded facts.
    return -1;
}

/// Does lowering emit a mid-body side-exit for instruction `idx`? Home
/// coalescing must not order an in-place carried-home update before ANY of
/// these — the single-snapshot deopt flush would commit a partial iteration
/// (see the coalescing block in `analyzeInner`). This is the closed inventory
/// of every `jccNativeExit`/`jmpNativeExit` the body emitter can produce; when
/// adding a new side-exiting lowering, extend this switch in the same change.
///
/// [Rule #0.5] This replaces a hand-kept op list that had gone stale: it was
/// blind to the href-callout miss exit, the dynamic guard_table/guard_hash
/// forms, the VALUE_LANE aload heap-tag check, and the grid guards
/// guard_gcol/guard_gpresent — any of which, ordered after the last inventoried
/// guard, would have let a coalesced in-place update commit early.
pub fn opMayExitInBody(
    t: *const Trace,
    kinds: []const Kind,
    slots: []const SlotInfo,
    slot_id_of_ref: []const i32,
    idx: usize,
) bool {
    const ins = t.instrs[idx];
    return switch (ins.op) {
        .guard_true,
        .guard_false,
        .guard_bounds,
        .guard_present,
        .guard_absent,
        .guard_fits,
        .guard_append,
        .int_of_float,
        .ffloor,
        .fceil,
        .hload,
        // Doc 43 P5: uload tag-checks the cell per iteration and side-exits on
        // a type drift between entries — a body exit, exactly like hload.
        // (`uref` and `ustore` are exit-free: the cell is entry-proven and a
        // scalar overwrite cannot fail.)
        .uload,
        .guard_gcol,
        .guard_gpresent,
        .alen,
        // Doc 24: the budget guard exits when headroom is gone; the tostr and
        // snew callouts exit on a null return (OOM, or — snew — the collapsed
        // tier-0 raise: invalid codepoint / negative count).
        .guard_gc,
        .tostr_int,
        .tostr_num,
        .ssub,
        .srev,
        .schar1,
        .srep2,
        // Doc 26: the case producers exit on a null return (OOM); scp exits
        // on the −1 sentinel (empty range — tier-0 replays to nil).
        .supper,
        .slower,
        .scp,
        // Doc 30: the match callouts exit on a negative status (sfindp also
        // on 0 — matched index is ≥ 1); scap_str on null (OOM); str2num_* on
        // a kind mismatch / non-number; sgm_setpos on bad_layout; guard_sid
        // is a body identity guard. scap_int is the one exit-FREE member
        // (a baked scratch load) and is deliberately absent.
        .sfindp,
        .smatch,
        .sgmatch,
        .scap_str,
        .str2num_i,
        .str2num_f,
        .sgm_setpos,
        .guard_sid,
        // Doc 45 D6: tnew exits on a non-.ok Status (OOM → `.precise_error`).
        .tnew,
        => true,
        // Doc 25: only the INT lane exits (a zero divisor side-exits so
        // tier-0 raises DivisionByZero; the (minInt, -1) pair is computed
        // inline, NO exit). The float lane's fmath kernel is total.
        .mod, .idiv => ins.ty == .int,
        // A VALUE_LANE aload tag-checks TAG_HEAP and side-exits on mismatch;
        // scalar-lane aloads are exit-free (guard_present/guard_bounds dominate).
        .aload => ins.aux == VALUE_LANE,
        // The dynamic (per-iteration) table checks side-exit; the `.ptr` forms
        // are prologue-hoisted / seed-validated and emit nothing in the body.
        .guard_table => isDynTableRoot(kinds, slots, slot_id_of_ref, ins.a),
        // doc 43 P3: a guard_lane on a `.heap`-kinded root (hload'd table
        // field) compares the lane byte per-iteration and side-exits on
        // mismatch; the `.ptr` form is prologue-hoisted and exit-free.
        .guard_lane => isDynTableRoot(kinds, slots, slot_id_of_ref, ins.a),
        // doc 43 P2: a guard_func on a `.heap`-kinded hload (function field)
        // side-exits in the body; the `.func` callee-snapshot form is
        // prologue-hoisted and exit-free. Without this row, carried-home
        // coalescing could commit a resumable home before the identity check
        // and a failed method guard would deopt a partial iteration.
        .guard_func => kinds[ins.a] == .heap,
        // A dynamically-resolved href side-exits on callout miss (cell == 0).
        .href => isDynTableRoot(kinds, slots, slot_id_of_ref, ins.a),
        .guard_hash => isDynTableRoot(kinds, slots, slot_id_of_ref, t.instrs[ins.a].a),
        else => false,
    };
}

// doc 22 §A.2 (HelperCaps), doc 24 D5 (the may_allocate/may_collect split): a
// heap φ keeps a raw `*GcHeader` in a register or spill cell across the whole
// body with no GC root. That is sound only while nothing in the body can
// trigger a COLLECTION — so every runtime helper the body may call out to is
// enumerated here with an explicit may-collect capability, and heap-φ
// admission refuses the trace if any callout could collect. Mere ALLOCATION
// (`tostr_*`) does not invalidate a φ-carried pointer: the GC is non-moving
// and allocation never collects in place (the single collect site is tier-0's
// dispatch prologue); its determinism cost is accounted by the `guard_gc`
// budget instead. A new callout MUST add a row (the exhaustive switch enforces
// it at compile time); claiming may_collect=false for a helper that can reach
// `Vm.collect` would be a soundness bug.

/// Every runtime helper a native body can call MID-ITERATION. The enum exists
/// solely to feed `calloutMayCollect`, i.e. to answer "can a heap φ be
/// invalidated across this call site", so membership is exactly "reachable from
/// `bodyCalloutOf`" — a variant no mapping ever returns is dead weight that
/// makes the GC audit look broader than it is.
///
/// Deliberately EXCLUDED, and why it needs no row: `NativeSeedCtx.seed_fn`
/// (doc 22 §B.2), the entry-prologue seeding callout that resolves
/// upvalue/global/hash-cell inputs into the trace's slab slots. It runs ONCE at
/// entry, before any heap φ is live, so it is outside this enum's question by
/// construction — not merely a `can_gc = false` answer to it. (For the record
/// it also allocates nothing: resolution and validation only — upvalue reads,
/// global-table lookups, hash-chain walks.)
pub const BodyCallout = enum {
    /// `resolveHashCell`: pure hash-chain walk over an existing table — reads
    /// the key, hashes, follows cells; allocates nothing.
    resolve_hash_cell,
    /// Full raw lookup, no mutation/allocation/collection.
    table_absent,
    /// `fmath.sinRuntime`: the shared noinline `math.sin` kernel (doc 23 D4) —
    /// a pure f64 → f64 function; allocates nothing.
    fsin,
    /// `fmath.cosRuntime`: likewise for `math.cos`.
    fcos,
    /// `fmath.floorRuntime` (doc 35): `@floor` + convert to i64; returns
    /// `FLOOR_CEIL_SENTINEL` on out-of-range/NaN/inf. Pure f64 → i64.
    ffloor,
    /// `fmath.ceilRuntime` (doc 35): likewise for `math.ceil`.
    fceil,
    /// `fmath.powRuntime`: the shared `^` kernel — pure (f64, f64) → f64;
    /// allocates nothing.
    fpow,
    /// `fmath.fmodRuntime` (doc 25): the shared float-`%` kernel
    /// (`x - floor(x/y)*y`) — pure (f64, f64) → f64, total (y == 0 → NaN);
    /// allocates nothing.
    fmod,
    /// `fmath.floordivRuntime` (doc 25): the shared float-`//` kernel
    /// (`floor(x/y)`) — pure (f64, f64) → f64, total; allocates nothing.
    ffloordiv,
    /// `stralloc.tostrIntRuntime` (doc 24): renders + interns an int's decimal
    /// string. **may_allocate = true** (at most ONE `Heap.link` per call — the
    /// D5 audit rule; an intern hit links zero), **may_collect = false**
    /// (allocation never collects in place — the ONLY collect site is the
    /// tier-0 dispatch prologue).
    tostr_int,
    /// `stralloc.tostrNumRuntime`: likewise for a float. Same
    /// may_allocate/may_collect split as `tostr_int`.
    tostr_num,
    /// `stralloc.ssubRuntime` (doc 24 c3): codepoint-range substring via the
    /// shared `subCore`. **may_allocate = true** (host scratch first, then at
    /// most ONE `Heap.link` at the final intern — the D5 audit rule; an intern
    /// hit links zero), **may_collect = false** (single collect site: tier-0's
    /// dispatch prologue).
    ssub,
    /// `stralloc.srevRuntime`: codepoint reversal via `reverseCore`. Same
    /// may_allocate/may_collect split as `ssub`.
    srev,
    /// `stralloc.schar1Runtime`: one-codepoint `string.char` via `char1Core`.
    /// Same split; an invalid codepoint returns null BEFORE any link.
    schar1,
    /// `stralloc.srep2Runtime`: separator-less `string.rep` via `rep2Core`.
    /// Same split; a negative/zero count resolves inside the core.
    srep2,
    /// `stralloc.supperRuntime` (doc 26): full-Unicode `string.upper` via the
    /// shared `caseCore`. **may_allocate = true** (host scratch first, then at
    /// most ONE `Heap.link` at the final intern — the D5 audit rule; an intern
    /// hit links zero), **may_collect = false** (single collect site: tier-0's
    /// dispatch prologue).
    supper,
    /// `stralloc.slowerRuntime`: likewise for `string.lower`. Same split.
    slower,
    /// `stralloc.scpRuntime` (doc 26): `string.codepoint` single-result read
    /// via the shared `codepointCore` — a pure (s, i, j) → i64 reader.
    /// Allocates NOTHING (the one non-allocating stralloc shim); −1 sentinel
    /// for the empty range (never a real codepoint — scalars are 0…0x10FFFF).
    scp,
    /// `stralloc.sfindpRuntime` (doc 30): plain-substring find — a pure
    /// (s, init, pat) → i64 reader. Allocates nothing, heap-free.
    sfindp,
    /// `stralloc.smatchRuntime` (doc 30): locate + scratch fill for
    /// find/match. Writes only the heap's `match_scratch` (host scratch,
    /// never GC state) — **may_allocate = false, may_collect = false**.
    smatch,
    /// `stralloc.sgmatchRuntime` (doc 30 §6): one composite gmatch-iterator
    /// step — READ-ONLY on the state table plus a `match_scratch` fill.
    /// Same non-allocating profile as `smatch`.
    sgmatch,
    /// `stralloc.scapStrRuntime` (doc 30): interns the span in a scratch
    /// slot. **may_allocate = true** (at most ONE `Heap.link` — the D5 audit
    /// rule; an intern hit links zero), **may_collect = false** (single
    /// collect site: tier-0's dispatch prologue).
    scap_str,
    /// `stralloc.str2numRuntime` (doc 30): `tonumber` on a string via the
    /// ONE `arith.toNumber` core — pure `*String` → {status, bits};
    /// allocates nothing.
    str2num,
    /// `stralloc.sgmSetposRuntime` (doc 30 §6): the deferred gmatch-cursor
    /// commit — one in-lane int-over-int cell write (no GC barrier needed);
    /// allocates nothing.
    sgm_setpos,
    /// `table_runtime.tnew` (doc 45 D6): the precise-only table allocation.
    /// **may_allocate = true** (exactly ONE `Heap.newTable` link per call —
    /// budgeted by the eager `guard_gc`), **may_collect = false** (allocation
    /// never collects in place; the single collect site stays tier-0's
    /// dispatch prologue, and the heap is non-moving). Failure is NOT a
    /// side-exit deopt: the emitter routes a non-`.ok` Status through the
    /// precise-error stub (`.precise_error`, execute-once — never retried).
    tnew,
};

/// The doc-22 capability, renamed for the doc-24 may_allocate/may_collect
/// split: can this callout trigger a COLLECTION mid-body? That is the only
/// capability heap-φ admission cares about — the GC is non-moving and
/// allocation never collects in place (single collect site: tier-0's dispatch
/// prologue), so a callout that merely ALLOCATES (`tostr_*`) leaves every
/// φ-carried raw `*GcHeader` valid. Allocation capability is documented
/// per-row above and accounted by the `guard_gc` budget instead.
pub fn calloutMayCollect(c: BodyCallout) bool {
    return switch (c) {
        .resolve_hash_cell, .table_absent => false,
        .fsin, .fcos, .ffloor, .fceil, .fpow, .fmod, .ffloordiv => false,
        .tostr_int, .tostr_num => false,
        .ssub, .srev, .schar1, .srep2 => false,
        .supper, .slower, .scp => false,
        // Doc 30: the matchers/projection/parse/commit shims never reach
        // `Vm.collect` — scapStr's intern merely ALLOCATES (≤1 link, budgeted
        // by guard_gc); the rest touch only host scratch / one table cell.
        .sfindp, .smatch, .sgmatch, .scap_str, .str2num, .sgm_setpos => false,
        // Doc 45 D6: tnew allocates (≤1 link, guard_gc-budgeted) but never
        // collects — see the enum row.
        .tnew => false,
    };
}

/// Which helper (if any) does instruction `idx` call out to in the body?
pub fn bodyCalloutOf(
    t: *const Trace,
    kinds: []const Kind,
    slots: []const SlotInfo,
    slot_id_of_ref: []const i32,
    idx: usize,
) ?BodyCallout {
    const ins = t.instrs[idx];
    return switch (ins.op) {
        // A dynamic-root href calls resolveHashCell — UNLESS it carries an
        // hrefk aux (doc 49): that lowers to inline guards + a `lea`, no call,
        // so it must NOT reserve the (large) callout save frame. Doc 49 P5:
        // the EFFECTIVE aux — a deactivated seed's stamped hrefk hint counts
        // as hrefk here, exactly as the emit dispatch will lower it.
        .href => if (isDynTableRoot(kinds, slots, slot_id_of_ref, ins.a) and
            trace_ir.HrefAux.decode(effectiveHrefAux(t, kinds, slots, slot_id_of_ref, idx)) == null) .resolve_hash_cell else null,
        .guard_absent => .table_absent,
        .fsin => .fsin,
        .fcos => .fcos,
        .ffloor => .ffloor,
        .fceil => .fceil,
        .pow => .fpow,
        // doc 25: ONLY the float lane is a callout; the int lane lowers to
        // inline cqo/idiv (`emitIntDivMod`) with no callout save area.
        .mod => if (ins.ty == .float) .fmod else null,
        .idiv => if (ins.ty == .float) .ffloordiv else null,
        .tostr_int => .tostr_int,
        .tostr_num => .tostr_num,
        .ssub => .ssub,
        .srev => .srev,
        .schar1 => .schar1,
        .supper => .supper,
        .slower => .slower,
        .scp => .scp,
        .srep2 => .srep2,
        // Doc 30. scap_int is NOT here: it lowers to a baked absolute load,
        // no call, so it needs no save area and invalidates nothing.
        .sfindp => .sfindp,
        .smatch => .smatch,
        .sgmatch => .sgmatch,
        .scap_str => .scap_str,
        .str2num_i, .str2num_f => .str2num,
        .sgm_setpos => .sgm_setpos,
        // Doc 45 D6: precise-only table allocation callout.
        .tnew => .tnew,
        else => null,
    };
}

/// Doc 22 §A.1b: compute the page's `SeedPlan` — which of `t.inputs` the
/// emitted body actually consumes at entry.
///
/// - `.upvalue` / `.global` seeds are always active: their slab slots are read
///   by ordinary `slot_load`s in the body.
/// - A `.hash_cell` seed is active iff some `href` names its slot (`aux ==
///   seed.slot`) AND that href's table root is *not* dynamic (`isDynTableRoot`
///   false). A dynamic-rooted href lowers to the per-iteration
///   `resolveHashCell` callout (aux forced to -1) and never reads the seeded
///   slab slot — seeding it would be dead work whose entry validation could
///   spuriously hash-decline the whole entry.
/// - `null` ⇒ compile bail (fail closed): more inputs than the 64-bit plan can
///   name. Real traces carry a handful; this is a structural bound, not a
///   tuning knob.
pub fn computeSeedPlan(
    t: *const Trace,
    kinds: []const Kind,
    slots: []const SlotInfo,
    slot_id_of_ref: []const i32,
) ?SeedPlan {
    if (t.inputs.len > 64) return null;
    var plan = SeedPlan{};
    for (t.inputs, 0..) |seed, i| {
        switch (seed.kind) {
            // Doc 43 P5: every `upvalue_cell` seed stays active — WRITER paths
            // feed `uref`'s slab load, and VERIFIER paths re-prove the alias
            // class at entry (deactivating one would skip that proof). A class
            // whose uref was DCE'd still validates (conservative: a failed
            // resolve declines an entry nothing would have read — matching
            // tier-1a's full-set resolution, and fail-closed).
            // Doc 53: `upvalue_slot_alias` likewise always active — it IS the
            // cross-entry soundness proof for a canonicalized slot read
            // (deactivating it would let a same-proto alien-activation closure
            // run the trace against the wrong frame), and keeping the whole
            // non-hash_cell family active preserves seed-order dependencies
            // (this seed reads `slots[callee_slot]`, which an earlier
            // upvalue/global seed may populate).
            .upvalue, .global, .callee_upvalue, .callee_global, .upvalue_cell, .upvalue_slot_alias => plan.activate(i),
            .hash_cell => {
                for (t.instrs) |ins| {
                    if (ins.op != .href) continue;
                    if (ins.aux < 0) continue;
                    if (@as(u32, @intCast(ins.aux)) != seed.slot) continue;
                    if (!isDynTableRoot(kinds, slots, slot_id_of_ref, ins.a)) {
                        plan.activate(i);
                        break;
                    }
                }
            },
        }
    }
    return plan;
}
