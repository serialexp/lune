//! The trace recorder: per-instruction IR recording (`recordInstr` and the
//! whole `rec*` family), IR emission (`emit`/`konst`/`guard*`/`refOf`/
//! `stampProv`), slot bookkeeping, and the `Recorder` struct with its support
//! types — carved out of `trace.zig` (file-split pass).
//!
//! Every method here is a `TraceState` method body moved verbatim: free
//! functions taking `self: *TraceState`, re-exported inside `TraceState` as
//! forwarding decls (`pub const recordInstr = trace_recorder.recordInstr;`)
//! so every `self.recordInstr(...)` spelling keeps working; module-level
//! decls (`Recorder`, `TraceKind`, `MAX_TRACE_INPUTS`, ...) are re-exported
//! at trace.zig module level the same way. Pure code motion — behaviour
//! identical by construction.

const std = @import("std");
const trace_mod = @import("trace.zig");
const bytecode = @import("bytecode.zig");
const value = @import("value.zig");
const regwindow = @import("regwindow.zig");
const RegWindow = regwindow.RegWindow;
const io = @import("io.zig");
const arr = @import("array.zig");
const function = @import("function.zig");
const string_mod = @import("string.zig");
const pattern_mod = @import("stdlib/pattern.zig");
const string_stdlib = @import("stdlib/string.zig");
const table_mod = @import("table.zig");
const arith = @import("arith.zig");
const gc = @import("gc.zig");
const Value = value.Value;
const Proto = bytecode.Proto;
const Instr = bytecode.Instr;
const OpCode = bytecode.OpCode;

const TraceState = trace_mod.TraceState;
const Trace = trace_mod.Trace;
const AnchorKey = trace_mod.AnchorKey;
const ChargeKind = trace_mod.ChargeKind;
const IrOp = trace_mod.IrOp;
const IrInstr = trace_mod.IrInstr;
const Ref = trace_mod.Ref;
const ObsType = trace_mod.ObsType;
const PHI_INTERNAL = trace_mod.PHI_INTERNAL;
const guardExitPc = trace_mod.guardExitPc;
const guardSourcePc = trace_mod.guardSourcePc;
const isSideExitGuardOp = trace_mod.isSideExitGuardOp;
const GuardRole = trace_mod.GuardRole;
const OperandDesig = trace_mod.OperandDesig;
const Polarity = trace_mod.Polarity;
const InputKind = trace_mod.InputKind;
const MAX_INLINE_DEPTH = trace_mod.MAX_INLINE_DEPTH;
const CallEdge = trace_mod.CallEdge;
const SlotStore = trace_mod.SlotStore;
const AbortReason = trace_mod.AbortReason;
const ExitProvenance = trace_mod.ExitProvenance;
const ProgramPoint = trace_mod.ProgramPoint;
const ExitKey = trace_mod.ExitKey;
const InputSeed = trace_mod.InputSeed;
const GuardProvenance = trace_mod.GuardProvenance;

// --- per-instruction recording ----------------------------------------

/// Mirror one executed tier-0 instruction into the trace IR, reading
/// *pre-execution* operand values from `regs` to choose type guards. Tier-0
/// still executes the instruction itself (next, in the dispatch loop) — this
/// only records. Unsupported opcodes / types abort the recording.
/// `pc` is the *post-increment* program counter (already advanced past
/// `instr`), matching what `applyJump(pc, aux)` expects — `recForLoop` uses it
/// to resolve the `for_loop` back-edge target against the trace anchor.
/// `resolved` carries the live value of an upvalue/global read for the two
/// arms that need it (`get_upval`/`get_global`) — the executor cannot resolve
/// those (no `*Vm`, no closure), so the dispatch loop pre-resolves and passes
/// it here. `Value.nil()` (and ignored) for every other opcode.
pub fn recordInstr(self: *TraceState, instr: Instr, regs: RegWindow, proto: *const Proto, pc: u32, resolved: Value) void {
    if (self.rec.instrs.items.len >= self.config.maxrecord) return self.abort(.too_long);
    self.rec.cur_pc = pc;
    self.rec.cur_op = instr.op;
    self.rec.cur_proto_id = proto.id; // leaf proto for GuardProvenance (A-i.3)
    // A-ii.3: capture the recorded program-point for region membership. Fail-soft
    // — an OOM here marks membership unavailable and continues; it must NEVER
    // abort the trace (that would change trace selection → non-byte-identical).
    if (self.rec.rec_path_ok) {
        self.rec.rec_path.append(self.gpa, .{ .proto_id = proto.id, .source_pc = pc -| 1 }) catch {
            self.rec.rec_path_ok = false;
        };
    }
    self.recordOne(instr, regs, proto, pc, resolved) catch self.abort(.alloc);
}

pub fn recordOne(self: *TraceState, instr: Instr, regs: RegWindow, proto: *const Proto, pc: u32, resolved: Value) error{OutOfMemory}!void {
    // Doc 27: the multret shadow is visible to exactly one instruction — the
    // designated consumer immediately after its producer, mirroring tier-0's
    // `reg_top_pending` scope. Stash and clear before dispatch; only the
    // consumer arms (`recCall`/`recBuiltin`/`recReturn`) receive the stash,
    // and only producer arms re-set the field (on success).
    const multret = self.rec.multret_top;
    self.rec.multret_top = null;
    switch (instr.op) {
        // loads & moves — define the destination, no guards.
        .load_nil => self.setReg(instr.a, try self.konst(Value.nil())),
        .load_bool => self.setReg(instr.a, try self.konst(Value.boolean(instr.b != 0))),
        .load_int => self.setReg(instr.a, try self.konst(Value.int(instr.aux))),
        .load_const => self.setReg(instr.a, try self.konst(proto.constants[instr.b])),
        .move => self.setReg(instr.a, try self.refOf(instr.b)),

        // arithmetic / bitwise / unary.
        .add => try self.recArith(.add, instr, regs),
        .sub => try self.recArith(.sub, instr, regs),
        .mul => try self.recArith(.mul, instr, regs),
        .div => try self.recArith(.div, instr, regs),
        .idiv => try self.recArith(.idiv, instr, regs),
        .mod => try self.recArith(.mod, instr, regs),
        .pow => try self.recArith(.pow, instr, regs),
        .band => try self.recBitwise(.band, instr, regs),
        .bor => try self.recBitwise(.bor, instr, regs),
        .bxor => try self.recBitwise(.bxor, instr, regs),
        .shl => try self.recBitwise(.shl, instr, regs),
        .shr => try self.recBitwise(.shr, instr, regs),
        .sar => try self.recBitwise(.sar, instr, regs),
        .neg => try self.recNeg(instr, regs),
        .not => try self.recNot(instr),
        .bnot => try self.recBnot(instr, regs),

        // comparisons (gt/ge normalise to lt/le with swapped operands).
        .eq => try self.recEq(.eq, instr, regs),
        .ne => try self.recEq(.ne, instr, regs),
        .lt => try self.recCompare(.lt, false, instr, regs),
        .le => try self.recCompare(.le, false, instr, regs),
        .gt => try self.recCompare(.lt, true, instr, regs),
        .ge => try self.recCompare(.le, true, instr, regs),

        // control flow.
        // Doc 38: while-inner nested-loop linking. A backward `jmp` whose
        // target already has a `.loop` root trace links to it (continuation/
        // side) or aborts LINNER (root), instead of unrolling the while body.
        // Forward jumps and jumps to unknown targets stay no-ops.
        .jmp => try self.recWhileLink(instr, regs, proto, pc),
        .jmp_if_false, .jmp_if_true => try self.recBranch(instr, regs, proto, pc),
        .for_loop => try self.recForLoop(instr, regs, pc),
        // Doc 30 c4: the generic-for back-edge — mirrors the CONTINUE
        // direction (first loop var non-nil → publish it as ctrl).
        .tfor_loop => try self.recTForLoop(instr, regs),
        // Nested-loop trace linking (doc 15, Phase 2). A continuation recording
        // re-reaching an inner numeric-`for`'s `for_prep` whose loop header
        // already has a root trace records `for_prep`'s pre-decrement and closes
        // with a `.link` to that root, instead of unrolling the inner loop.
        // When no inner root exists yet (or the shape isn't linkable), this falls
        // back to the historical LINNER abort (`.nyi_opcode`) — byte-identical to
        // before — so the inner loop spawns its own root first.
        .for_prep => try self.recForPrepLink(instr, regs, proto, pc),

        // Cross-frame tracing: inline a Lua callee's body straight into the
        // trace (LuaJIT-style `lj_record_call`/`lj_record_ret`). A host
        // (`native`) call stays a trace barrier unless it carries a
        // `RecordedBuiltin` tag; anything we can't inline (vararg, `__call`,
        // too deep) aborts cleanly and tier-0 owns the loop. Dynamic multret
        // windows resolve against the one-instruction `multret` shadow
        // (doc 27) instead of aborting.
        .call => try self.recCall(instr, regs, proto, multret),
        .ret => if (self.rec.inline_depth == 0)
            // A `.ret` in the anchor frame closes the traced function itself —
            // the loop's back-edge always closes the trace first, so this is
            // only reached on an odd shape; abort rather than map results into a
            // caller we never inlined.
            self.abort(.cross_frame)
        else
            try self.recReturn(instr, multret),
        // `.halt` ends the top-level chunk; never a return from an inlined
        // callee. Always a barrier.
        .halt => self.abort(.cross_frame),

        // Table read `t[k]`: an INTEGER key takes the lane-aware packed-array
        // path (Phase B; in-bounds dense narrow-lane slot only); a constant
        // STRING key takes the hash-field path (doc 11, `obj.field`); anything
        // else aborts cleanly. The key type is observed at record time.
        // `#R[b]` (doc 23 D3 / doc 24 D4): a table records through the
        // guarded `alen` producer; a konst string folds to its `cp_len`
        // (code points — the `#s` semantic, deliberately distinct from
        // `rawlen`'s bytes). A NON-konst string records through the pure
        // `slen` producer: when its producing op already proves stringness
        // (`tostr_*` — proven by construction), `slen` rides bare; an
        // *observed* string (a loaded slot / hash load) pins first with
        // `guard_string`.
        .len => {
            const v = regs.get(instr.b);
            if (v.isHeap() and v.heapType() == .table) {
                try self.recAlenShape(instr.a, instr.b, .b, regs);
            } else if (v.isHeap() and v.heapType() == .string) {
                const rstr = try self.refOf(instr.b);
                if (self.konstValueOf(rstr)) |kv| {
                    if (!kv.isHeap() or kv.heapType() != .string) return self.abort(.nyi_opcode);
                    const s = string_mod.String.fromHeader(kv.asHeap());
                    self.setReg(instr.a, try self.konst(Value.int(@intCast(s.cp_len))));
                } else {
                    const proven = self.isProvenStringRef(rstr);
                    // Emitted raw; tropt's guard dedup (GuardKey) drops an
                    // exact duplicate — same discipline as `guard_table`.
                    if (!proven)
                        self.stampProv(try self.emit(.{ .op = .guard_string, .a = rstr }), .operand_type, .b, .neutral);
                    const r = try self.emit(.{ .op = .slen, .a = rstr, .ty = .int });
                    self.setReg(instr.a, r);
                }
            } else return self.abort(.nyi_opcode);
        },

        // NUMBER covers the integral-float key (`v[j]` with `j` from float
        // division) — `recArrayGet` narrows it via `keyRefNarrowed` or aborts
        // `.bad_type` for a fractional float, same net abort as before.
        .get_index => if (regs.get(instr.c).isNumber())
            try self.recArrayGet(instr, regs)
        else if (isStringKey(regs.get(instr.c)))
            try self.recHashGet(instr, regs)
        else
            self.abort(.bad_type),

        // Table write `t[k]=v`: INTEGER key → packed-array write (Phase B,
        // in-bounds in-lane, C1 deopt-replay rule); constant STRING key →
        // hash-field write (doc 11, present-key overwrite only); else abort.
        .set_index => if (regs.get(instr.b).isNumber())
            try self.recArraySet(instr, regs)
        else if (isStringKey(regs.get(instr.b)))
            try self.recHashSet(instr, regs)
        else
            self.abort(.bad_type),

        // Fused two-level access `a[i][j]` / `a[i][j]=v` (doc 14, Phase 8). We
        // record ONLY when the container is already a flattened grid with an
        // int element lane and the access is a present, in-bounds, in-lane cell
        // — exactly the shape the grid native/oracle path models. Everything
        // else (nested tables not yet inflated, a grow/widen store, an f64 grid)
        // aborts to tier-0, which inflates / reshapes / runs the slow path.
        .get_index2 => try self.recGridGet(instr, regs),
        .set_index2 => try self.recGridSet(instr, regs),

        // Cluster sub-lever 1: a callee (or any loop-invariant value) reached
        // through an UPVALUE or GLOBAL. The executor cannot read these (no
        // `*Vm`, no closure), so we snapshot the loop-invariant value into a
        // dead slab slot above the anchor window (`slot_load` from a synthetic
        // input slot the dispatch loop re-seeds each entry) and — when it is a
        // function — pin its identity with `guard_func`. `set_upval`/`set_global`
        // stay aborts (not in this switch): a write in the traced region would
        // make the snapshot stale, so such loops keep running on tier-0.
        .get_upval => try self.recInputGet(.upvalue, instr.a, instr.b, resolved),
        .get_global => try self.recInputGet(.global, instr.a, instr.b, resolved),

        // tables, closures, concat, for_prep, len, …: each pulls in heap-effect
        // / cross-frame / invalidation machinery that is later work. Abort
        // cleanly.
        else => self.abort(.nyi_opcode),
    }
}

// --- recording helpers -------------------------------------------------

/// Append an IR instruction, returning its SSA ref (its index).
/// For simple type-guard ops (`guard_int`, `guard_float`, `guard_number`,
/// `guard_true`, `guard_false`), the current **post-increment resume/exit PC**
/// (`rec.cur_pc`, = source-opcode PC + 1) is stored in `aux` so the executor
/// can report which guard failed and chain to the exit PC. `guardExitPc` reads
/// it back; `guardSourcePc` recovers the owning source opcode. Other ops keep
/// their caller-set `aux`.
pub fn emit(self: *TraceState, ins: IrInstr) !Ref {
    var ins_mut = ins;
    switch (ins_mut.op) {
        // `int_of_float` and `alen` are value-producing but also side-exit, so
        // they stamp their PC for exit-PC chaining like the type guards (their
        // `aux` is unused for anything else — the result kind is `.int`, the
        // operand is `a`).
        .guard_int, .guard_float, .guard_number, .guard_true, .guard_false, .int_of_float, .alen => {
            ins_mut.aux = @intCast(self.rec.cur_pc);
        },
        else => {},
    }
    const ref: Ref = @intCast(self.rec.instrs.items.len);
    try self.rec.instrs.append(self.gpa, ins_mut);
    // Grow the exit-provenance table in lockstep (A-i.1): one `null` per append,
    // so `exit_prov.items[ref]` is always addressable. Guard / fused-producer
    // sites overwrite their slot via `stampProv` (A-i.3); everything else stays
    // `null`. If this append OOMs, `emit` returns the error → the recording
    // aborts → `reset` clears both lists back to equal length, so a transient
    // length skew never outlives the failed recording.
    try self.rec.exit_prov.append(self.gpa, null);
    return ref;
}

/// Emit an `.alloc`-kind op (doc 24 D4): ensures the body's single
/// `guard_gc` entry guard exists — emitted lazily immediately before the
/// FIRST `.alloc` op, which places it before *every* `.alloc` op. That is
/// the only ordering the D3 soundness argument needs: any effects that
/// precede it in the body (inline `astore`s) are already required to be
/// header-replay-idempotent by the C1 discipline (every later guard can
/// fail below them today), and a failing `guard_gc` means ZERO allocations
/// were performed this iteration, so the D2 corollary's clean-replay
/// premise holds at its exit. The guard's `aux` (the bound `A`) is a
/// placeholder until `commit()` stamps the final `alloc_count`.
pub fn emitAlloc(self: *TraceState, ins: IrInstr) !Ref {
    if (self.rec.guard_gc_ref == null) {
        self.rec.guard_gc_ref = try self.emit(.{ .op = .guard_gc });
    }
    self.rec.alloc_count += 1;
    return self.emit(ins);
}

/// Intern a constant into the trace's pool and emit a `konst` for it. A
/// value seen before reuses its existing `konst` ref (and pool slot) — a
/// `konst` is pure and operand-free, so sharing its ref is sound. This is
/// what lets identical subexpressions (e.g. the two `i + 7` in
/// `(i + 7) * (i + 7)`) end up with identical operand refs, so the
/// optimizer's CSE can collapse them (see docs / TODO.md).
pub fn konst(self: *TraceState, v: Value) !Ref {
    const key = konstKey(v);
    if (self.rec.konst_map.get(key)) |existing| return existing;
    const idx: i32 = @intCast(self.rec.consts.items.len);
    try self.rec.consts.append(self.gpa, v);
    const ref = try self.emit(.{ .op = .konst, .aux = idx, .ty = obsTypeOf(v) });
    try self.rec.konst_map.put(self.gpa, key, ref);
    return ref;
}

/// The SSA ref currently held by tier-0 register `slot`. The first read of a
/// register emits a `slot_load` (a trace input) and records it in the entry
/// snapshot.
pub fn refOf(self: *TraceState, slot: u16) !Ref {
    // Translate the frame-relative `slot` into a `reg_map` index by the current
    // frame's absolute offset (0 for the anchor frame; cross-frame tracing
    // raises it inside an inlined callee). A `slot_load` is only ever emitted
    // for an anchor-frame slot: S1 pre-seeds every callee slot `.def` at the
    // inlining `.call`, so a callee index is never `.undef` here — the
    // executor's `slot_load aux` therefore always lands in `[0,
    // anchor_num_registers)`.
    const abs: usize = self.rec.base_off + slot;
    const s = &self.rec.reg_map[abs];
    if (s.state != .undef) {
        // Doc 39: inside a peel's body pass, the first read of an
        // anchor-window slot iteration 1 DEFINED lazily creates the
        // internal φ carrying its steady state — `a` = the iteration-1
        // ref (a run-once value), `b` patched at close — and rebinds the
        // slot so every later consumer naturally uses the φ (φ-before-use
        // falls out of laziness; no operand rewrite pass exists). Slots
        // still `.input` at the marker (invariant reads) and slots the
        // body already wrote (`rebound`, incl. write-before-read — no
        // cross-iteration dataflow of their own) are referenced directly.
        if (self.rec.peel) |*p| {
            if (abs < self.rec.anchor_num_registers) {
                const ps = &p.slots[abs];
                if (!ps.rebound and ps.state == .def) {
                    const phi_ref = try self.emit(.{
                        .op = .phi,
                        .a = ps.ref,
                        .b = 0, // patched by finishPeel
                        .aux = PHI_INTERNAL,
                        .ty = self.rec.instrs.items[@intCast(ps.ref)].ty,
                    });
                    ps.rebound = true;
                    ps.phi_ref = phi_ref;
                    s.* = .{ .ref = phi_ref, .state = .def, .entry_kind = s.entry_kind };
                    return phi_ref;
                }
            }
        }
        return s.ref;
    }
    const aux: i32 = @intCast(abs);
    const ref = try self.emit(.{ .op = .slot_load, .aux = aux, .ty = .unknown });
    try self.rec.entry_slots.append(self.gpa, @intCast(abs));
    // A fresh `slot_load` resets `entry_kind` to `.none` by construction:
    // the slot was `.undef`, so no proof can have covered it yet.
    s.* = .{ .ref = ref, .state = .input };
    return ref;
}

/// Doc 39 Phase 0 (central capture, codex round-2 finding 11): a numeric
/// type proof just covered `ref`. If `ref` is an anchor-window `slot_load`,
/// stamp the slot's `entry_kind` — keyed off the *instruction* (a
/// `slot_load` carries its absolute slot in `aux`), so the stamp works
/// regardless of which proof route got here first, after the slot has been
/// redefined, and even when `guarded_refs` dedup suppresses the guard's
/// emission (the proof exists either way). First proof wins: the entry
/// value has exactly one runtime kind per recording, so later proofs agree.
pub fn noteEntryKind(self: *TraceState, ref: Ref, kind: EntryKind) void {
    const ins = self.rec.instrs.items[@intCast(ref)];
    if (ins.op != .slot_load) return;
    const abs: usize = @intCast(ins.aux);
    // Synthetic input slots (upvalue/global/hash-cell snapshots) reuse the
    // `slot_load` op with `aux >= anchor_num_registers`; that aux is an
    // executor window index, NEVER a `reg_map` index — don't alias the
    // inlined-callee scratch the `reg_map` tail reserves.
    if (abs >= self.rec.anchor_num_registers) return;
    const s = &self.rec.reg_map[abs];
    if (s.entry_kind == .none) s.entry_kind = kind;
}

/// Doc 39: the lane-implied variant of `noteEntryKind` for the `guard_fits`
/// proof route (emitted directly, not via `guard`). Fit implies type for the
/// narrow lanes: the int store-shape lanes (`Lane.isInt`) prove the value
/// int, `.f64` proves float; `.boolean`/`.value`/`.grid` prove no numeric
/// kind and stamp nothing.
pub fn noteEntryKindFromLane(self: *TraceState, ref: Ref, lane: arr.Lane) void {
    if (lane.isInt()) {
        self.noteEntryKind(ref, .int);
    } else if (lane == .f64) {
        self.noteEntryKind(ref, .float);
    }
}

/// Record that tier-0 register `slot` (in the current frame) now holds the
/// value produced by `ref` (a loop-carried write — surfaces in the exit
/// snapshot). Offset by `base_off` like `refOf`.
pub fn setReg(self: *TraceState, slot: u16, ref: Ref) void {
    self.defineSlotAbs(self.rec.base_off + slot, ref);
}

/// The single whole-`RegSlot` define: every write that replaces a slot's
/// binding (`setReg`, inlined-callee seeding, return mapping) funnels here
/// so that (a) `entry_kind` SURVIVES the write (doc 39 — `k = k/2` must not
/// erase the evidence that `k` entered int; codex round-2 finding 2), and
/// (b) an in-flight peel marks the slot `rebound` (a body write before any
/// read means "no internal φ" — the write-before-read class).
pub fn defineSlotAbs(self: *TraceState, abs: usize, ref: Ref) void {
    if (self.rec.peel) |*p| {
        if (abs < self.rec.anchor_num_registers) p.slots[abs].rebound = true;
    }
    const s = &self.rec.reg_map[abs];
    s.* = .{ .ref = ref, .state = .def, .entry_kind = s.entry_kind };
}

/// Whether tier-0 register `slot` was *read* during this recording (i.e. it is
/// in the entry snapshot). Used by `commit()` as a safety net so the dead-
/// temporary filter never drops a slot the trace actually consumed.
pub fn readSlot(self: *const TraceState, slot: u16) bool {
    return std.mem.indexOfScalar(u16, self.rec.entry_slots.items, slot) != null;
}

/// Stamp the exit provenance (doc 17, A-i.3) of the guard / fused-producer just
/// emitted at emission index `ref` — the lockstep `exit_prov` slot already exists
/// (appended by `emit`). The leaf is the currently-recording opcode:
/// `source_proto_id = cur_proto_id`, `source_pc = cur_pc − 1` (`cur_pc` is the
/// post-increment resume PC), with the live inline-path prefix. Behaviour-neutral:
/// nothing reads `exit_prov` until Part A (A-ii).
pub fn stampProv(self: *TraceState, ref: Ref, role: GuardRole, operand: OperandDesig, polarity: Polarity) void {
    self.rec.exit_prov.items[ref] = .{
        .guard = .{
            .path = pathFromFrames(&self.rec.frames, self.rec.inline_depth),
            .inline_depth = self.rec.inline_depth,
            .source_proto_id = self.rec.cur_proto_id,
            // `cur_pc` is the post-increment resume PC (= source-opcode PC + 1), so the
            // owning guest opcode is `cur_pc − 1` (same convention as `guardSourcePc`).
            // In production `cur_pc ≥ 1` always; saturating subtraction is identical for
            // every real input and only maps the synthetic `pc = 0` test sentinel to 0
            // (which `guardSourcePc` likewise treats as "no loop-body guard PC").
            .source_pc = self.rec.cur_pc -| 1,
            .role = role,
            .operand = operand,
            .polarity = polarity,
        },
    };
}

/// Emit a type guard for `ref` (deduplicated — an SSA value has one type). Stamps
/// its provenance `(role, operand)` (A-i.3) only when it actually emits: a deduped
/// guard (already covered) emits nothing, and the existing guard keeps its own
/// stamp (the many-to-one static-slot → guard map, H-1c).
pub fn guard(self: *TraceState, ref: Ref, op: IrOp, role: GuardRole, operand: OperandDesig) !void {
    // Doc 39: stamp the slot's proven entry kind BEFORE the dedup return —
    // the proof exists even when the guard emission is suppressed.
    switch (op) {
        .guard_int => self.noteEntryKind(ref, .int),
        .guard_float => self.noteEntryKind(ref, .float),
        else => {},
    }
    if (self.rec.guarded_refs.contains(ref)) return;
    try self.rec.guarded_refs.put(self.gpa, ref, {});
    const gref = try self.emit(.{ .op = op, .a = ref });
    self.stampProv(gref, role, operand, .neutral);
}

pub fn guardInt(self: *TraceState, ref: Ref, role: GuardRole, operand: OperandDesig) !void {
    try self.guard(ref, .guard_int, role, operand);
}

pub fn guardNum(self: *TraceState, ref: Ref, v: Value, role: GuardRole, operand: OperandDesig) !void {
    try self.guard(ref, if (v.isInt()) IrOp.guard_int else IrOp.guard_float, role, operand);
}

/// Record-time view of an array get/set KEY: the integer index tier-0's
/// `table.normalizeKey` resolves the key to, or null when the access is hash
/// territory (fractional float / non-number) and the caller must abort
/// `.bad_type`. The SAME `value.floatAsExactInt` predicate underpins
/// `normalizeKey`, tier-1a's `int_of_float`, and the native `cvttsd2si`
/// round-trip, so all four agree bit-for-bit.
pub fn keyIndexOf(vkey: Value) ?i64 {
    if (vkey.isInt()) return vkey.asInt();
    if (vkey.isFloat()) return value.floatAsExactInt(vkey.asFloat());
    return null;
}

/// Emit the int-typed key ref for an array get/set whose record-time key
/// `keyIndexOf` already accepted. An int key type-guards as before
/// (`guard_int`, dedup'd). An integral-FLOAT key — e.g. fft_bitreverse's
/// `j`, made float by `k = k/2` float division — NARROWS: `guard_float` on
/// the operand, then `int_of_float`, the same guarded float→int op the
/// float-loop-limit specialization uses (all three tiers lower it; native
/// requires exactly this dominating `guard_float`, nativegen.zig ~1522).
/// This is the recorder mirror of tier-0's `normalizeKey` (LuaJIT:
/// `lj_opt_narrow` index narrowing): a later NON-integral float at the same
/// site side-exits `int_of_float` → tier-0 resumes with its exact hash-part
/// semantics, so the fractional case is never on-trace, just not fast.
pub fn keyRefNarrowed(self: *TraceState, key_reg: u16, operand: OperandDesig, vkey: Value) !Ref {
    const rkey = try self.refOf(key_reg);
    if (vkey.isInt()) {
        try self.guardInt(rkey, .key_type, operand);
        return rkey;
    }
    std.debug.assert(vkey.isFloat()); // caller gated on keyIndexOf != null
    try self.guard(rkey, .guard_float, .key_type, operand);
    const iof = try self.emit(.{ .op = .int_of_float, .a = rkey, .ty = .int });
    self.stampProv(iof, .key_int, operand, .neutral);
    return iof;
}

pub fn recArith(self: *TraceState, op: IrOp, instr: Instr, regs: RegWindow) !void {
    const vb = regs.get(instr.b);
    const vc = regs.get(instr.c);
    if (!vb.isNumber() or !vc.isNumber()) return self.abort(.bad_type);
    const rb = try self.refOf(instr.b);
    const rc = try self.refOf(instr.c);
    try self.guardNum(rb, vb, .operand_type, .b);
    try self.guardNum(rc, vc, .operand_type, .c);
    const r = try self.emit(.{ .op = op, .a = rb, .b = rc, .ty = arithResultType(op, vb, vc) });
    self.setReg(instr.a, r);
}

pub fn recBitwise(self: *TraceState, op: IrOp, instr: Instr, regs: RegWindow) !void {
    const vb = regs.get(instr.b);
    const vc = regs.get(instr.c);
    if (!vb.isInt() or !vc.isInt()) return self.abort(.bad_type);
    const rb = try self.refOf(instr.b);
    const rc = try self.refOf(instr.c);
    try self.guardInt(rb, .operand_type, .b);
    try self.guardInt(rc, .operand_type, .c);
    const r = try self.emit(.{ .op = op, .a = rb, .b = rc, .ty = .int });
    self.setReg(instr.a, r);
}

pub fn recNeg(self: *TraceState, instr: Instr, regs: RegWindow) !void {
    const vb = regs.get(instr.b);
    if (!vb.isNumber()) return self.abort(.bad_type);
    const rb = try self.refOf(instr.b);
    try self.guardNum(rb, vb, .operand_type, .b);
    const r = try self.emit(.{ .op = .neg, .a = rb, .ty = if (vb.isInt()) .int else .float });
    self.setReg(instr.a, r);
}

/// `not` works on any value via Lua truthiness, so it needs no type guard —
/// the IR `not` is defined over truthiness, like tier-0.
pub fn recNot(self: *TraceState, instr: Instr) !void {
    const rb = try self.refOf(instr.b);
    const r = try self.emit(.{ .op = .not, .a = rb, .ty = .boolean });
    self.setReg(instr.a, r);
}

pub fn recBnot(self: *TraceState, instr: Instr, regs: RegWindow) !void {
    const vb = regs.get(instr.b);
    if (!vb.isInt()) return self.abort(.bad_type);
    const rb = try self.refOf(instr.b);
    try self.guardInt(rb, .operand_type, .b);
    const r = try self.emit(.{ .op = .bnot, .a = rb, .ty = .int });
    self.setReg(instr.a, r);
}

pub fn recCompare(self: *TraceState, op: IrOp, swap: bool, instr: Instr, regs: RegWindow) !void {
    const vb = regs.get(instr.b);
    const vc = regs.get(instr.c);
    if (!vb.isNumber() or !vc.isNumber()) return self.abort(.bad_type);
    var rb = try self.refOf(instr.b);
    var rc = try self.refOf(instr.c);
    try self.guardNum(rb, vb, .operand_type, .b);
    try self.guardNum(rc, vc, .operand_type, .c);
    // Native exact mixed int/float comparison cannot round the int through f64
    // (`compareIntFloat` deliberately does not). When the observed float is
    // integral, narrow only that operand and compare two ints. A later
    // fractional float exits at `int_of_float` before any sunk store executes,
    // and tier-0 replays with the full exact mixed-number semantics.
    if (vb.isInt() and vc.isFloat() and value.floatAsExactInt(vc.asFloat()) != null) {
        rc = try self.emit(.{ .op = .int_of_float, .a = rc, .ty = .int });
        self.stampProv(rc, .operand_int, .c, .neutral);
    } else if (vb.isFloat() and vc.isInt() and value.floatAsExactInt(vb.asFloat()) != null) {
        rb = try self.emit(.{ .op = .int_of_float, .a = rb, .ty = .int });
        self.stampProv(rb, .operand_int, .b, .neutral);
    }
    if (swap) {
        const t = rb;
        rb = rc;
        rc = t;
    }
    const r = try self.emit(.{ .op = op, .a = rb, .b = rc, .ty = .boolean });
    self.setReg(instr.a, r);
}

// --- index-recording shapes (doc 23 D3) --------------------------------
//
// The `get_index`/`set_index` opcode arms and the call-shaped `rawget`/
// `rawset` builtins record the SAME guarded access — on a metatable-free
// table (which every shape re-proves with `guard_table` after aborting
// `.has_metatable` at record time) raw and non-raw access are one
// operation. So the cores are shape functions over an explicit slot frame:
// which guest register plays table/key/value/dest, plus how each guard's
// operand is designated in exit provenance (`.b`/`.c` for the opcodes,
// `.a1`/`.a2`/`.a3` — call args — for the builtins).

/// Slot frame for the read shapes: `dst` receives the loaded value.
pub const GetFrame = struct {
    dst: u16,
    tab: u16,
    key: u16,
    tab_od: OperandDesig,
    key_od: OperandDesig,
};

/// Slot frame for the write shapes: `val` is the stored value's register.
pub const SetFrame = struct {
    tab: u16,
    key: u16,
    val: u16,
    tab_od: OperandDesig,
    key_od: OperandDesig,
    val_od: OperandDesig,
};

/// Record `t[k]` (`get_index`, `dst=a b=table c=key`) as an array read.
///
/// **Narrow lanes** (i8–i64/f64/u8/boolean): emits `guard_table` + `guard_lane`
/// on the table ref, `guard_int` on the key, then `aref` + `guard_bounds` +
/// `guard_present` + `aload`. The result is a scalar value.
///
/// **`.value` lane** (the type-erased lane holding full 16-byte Values): emits the
/// same prefix but omits `guard_present` (`.value` lane has no presence bitmap —
/// nil is in-band) and appends a type guard on the *loaded value*. Two element
/// shapes are recordable:
///   * a **table** with no metatable — the array-of-structs pattern
///     (`bodies[i].x`), pinned by `guard_table` on the load. The result is a heap
///     table ref subsequent `recHashGet`/`recHashSet` calls chain from.
///   * an **int or float** — the mixed/erased numeric array (doc 32), pinned by
///     `guard_int`/`guard_float`. Arises whenever an int-lane array takes a float
///     store (or vice versa): `widenFor` has no cross-family rung, so the array
///     erases to `.value` permanently.
///
/// Aborts (leaving tier-0 untouched) when:
///   * non-table container or non-int key → `.bad_type`;
///   * out-of-bounds or hole at record time → `.bad_type`;
///   * `.value`-lane with a bool, string, or function element → `.nyi_opcode`
///     (no strict type guard pins those — doc 32 §3);
///   * element table has a metatable → `.has_metatable`.
pub fn recArrayGet(self: *TraceState, instr: Instr, regs: RegWindow) !void {
    return self.arrayGetShape(regs, .{ .dst = instr.a, .tab = instr.b, .key = instr.c, .tab_od = .b, .key_od = .c });
}

pub fn arrayGetShape(self: *TraceState, regs: RegWindow, f: GetFrame) !void {
    const vtab = regs.get(f.tab);
    const vkey = regs.get(f.key);
    if (!vtab.isHeap() or vtab.heapType() != .table) return self.abort(.bad_type);
    const idx = keyIndexOf(vkey) orelse return self.abort(.bad_type);
    const tbl = table_mod.Table.fromHeader(vtab.asHeap());
    // A metatable means an absent slot could fire `__index` (chunk 2a). Even a
    // present slot today could become a hole on a later iteration, so the only
    // sound conservative choice is to bail the whole trace to tier-0.
    if (tbl.metatable != null) return self.abort(.has_metatable);
    const lane = tbl.array.lane;
    if (!arr.ArrayPart.inArray(idx, tbl.array.asize)) return self.abort(.bad_type);
    const loaded = tbl.getInt(idx);
    if (loaded.isNil()) return self.abort(.bad_type); // hole — not a profitable trace

    if (lane == .value) {
        // The `.value` lane stores full 16-byte Values (tag+payload, nil in-band).
        // Two element shapes are recordable, distinguished only by the *trailing*
        // type guard on the loaded ref — the address/bounds prefix is identical:
        //
        //   * a **table** with no metatable — the array-of-structs pattern
        //     (`bodies[i].x`), guarded by `guard_table` on the load;
        //   * an **int or float** — the mixed/erased numeric array (doc 32),
        //     guarded by `guard_int`/`guard_float` on the load.
        //
        // Everything else (bool, string, function) stays nyi: neither has a
        // *strict* type guard that pins the element so a later iteration changing
        // it side-exits — `guard_true` would wave a truthy heap value through, and
        // a string element would additionally need `guard_string` plumbing. This
        // is the same int/float restriction `hashGetShape` applies to hash fields,
        // for the same reason.
        const elem_is_table = loaded.isHeap() and loaded.heapType() == .table;
        const elem_is_num = loaded.isInt() or loaded.isFloat();
        if (!elem_is_table and !elem_is_num) return self.abort(.nyi_opcode);
        if (elem_is_table) {
            const elem_tbl = table_mod.Table.fromHeader(loaded.asHeap());
            if (elem_tbl.metatable != null) return self.abort(.has_metatable);
        }

        const lane_ord: i32 = @intFromEnum(lane); // 0 for .value
        const rtab = try self.refOf(f.tab);
        self.stampProv(try self.emit(.{ .op = .guard_table, .a = rtab }), .container_type, f.tab_od, .neutral);
        self.stampProv(try self.emit(.{ .op = .guard_lane, .a = rtab, .aux = lane_ord }), .container_lane, f.tab_od, .neutral);
        const rkey = try self.keyRefNarrowed(f.key, f.key_od, vkey);
        if (try self.forwardPendingArrayLoad(f.dst, rtab, rkey, idx)) return;
        const ref = try self.emit(.{ .op = .aref, .a = rtab, .b = rkey, .aux = lane_ord });
        self.stampProv(try self.emit(.{ .op = .guard_bounds, .a = ref }), .bounds, .none, .neutral);
        // No guard_present: the `.value` lane has no presence bitmap — nil is
        // encoded in-band (tag == .nil). A nil element fails the trailing type
        // guard below (nil is neither a heap_ref nor a number) and side-exits to
        // tier-0. Correct for both element shapes.
        const rload = try self.emit(.{ .op = .aload, .a = ref, .aux = lane_ord, .ty = obsTypeOf(loaded) });
        // Fused native producer-exit (A-i.3): the native `.value` `aload` tag-checks
        // the loaded element against the tag its recorded `ty` implies and side-exits
        // there, with no `guard_*` node — so the exit identity rides the `aload`
        // itself. The recorder still emits the guard below for the tier-1a oracle;
        // native discharges it statically (proven kind) and emits nothing.
        self.stampProv(rload, .element_type, .loaded, .neutral);
        // Pin the element's type so a later iteration changing it side-exits.
        if (elem_is_table) {
            self.stampProv(try self.emit(.{ .op = .guard_table, .a = rload }), .element_type, .loaded, .neutral);
        } else {
            try self.guardNum(rload, loaded, .element_type, .loaded);
        }
        self.setReg(f.dst, rload);
        return;
    }

    const lane_ord: i32 = @intFromEnum(lane);
    const rtab = try self.refOf(f.tab);
    self.stampProv(try self.emit(.{ .op = .guard_table, .a = rtab }), .container_type, f.tab_od, .neutral);
    self.stampProv(try self.emit(.{ .op = .guard_lane, .a = rtab, .aux = lane_ord }), .container_lane, f.tab_od, .neutral);
    const rkey = try self.keyRefNarrowed(f.key, f.key_od, vkey);
    if (try self.forwardPendingArrayLoad(f.dst, rtab, rkey, idx)) return;
    const ref = try self.emit(.{ .op = .aref, .a = rtab, .b = rkey, .aux = lane_ord });
    self.stampProv(try self.emit(.{ .op = .guard_bounds, .a = ref }), .bounds, .none, .neutral);
    self.stampProv(try self.emit(.{ .op = .guard_present, .a = ref }), .present, .none, .neutral);
    const rload = try self.emit(.{ .op = .aload, .a = ref, .aux = lane_ord, .ty = obsTypeOf(loaded) });
    self.setReg(f.dst, rload);
}

/// Resolve an array load against the recorder's deferred-store buffer using
/// LuaJIT's `aa_ahref` rule: forward only on a statically must-alias key, skip
/// only on a statically no-alias key, and abort on ambiguity. In particular we
/// never guard the record-time equality of two loop-varying keys — that pins an
/// incidental per-iteration relation and makes a valid trace a turnstile.
/// Walking newest-to-oldest preserves last-writer-wins.
pub fn forwardPendingArrayLoad(self: *TraceState, dst: u16, rtab: Ref, rkey: Ref, idx: i64) !bool {
    _ = idx; // observed values never decide aliasing
    var n = self.rec.pending_stores.items.len;
    while (n > 0) {
        n -= 1;
        const ps = self.rec.pending_stores.items[n];
        switch (ps.op) {
            .astore => {},
            // A present hash overwrite cannot change an array slot.
            .hstore => continue,
            // Doc 30: a pending `sgm_setpos` DOES write an array cell
            // (the gmatch state's slot 3) — fail closed on any store op
            // this classifier wasn't written for.
            else => {
                self.abort(.bad_type);
                return true;
            },
        }
        const addr = self.rec.instrs.items[ps.aref];
        std.debug.assert(addr.op == .aref);
        if (addr.a != rtab) {
            self.abort(.bad_type);
            return true;
        }
        switch (self.classifyArrayKeyAlias(rkey, addr.b)) {
            .must => {
                self.setReg(dst, ps.value);
                return true;
            },
            .no => continue,
            .may => {
                self.abort(.bad_type);
                return true;
            },
        }
    }
    return false;
}

/// Resolve a hash load against the deferred-store buffer (doc 08 §2026-08-20,
/// LuaJIT's `aa_href`). Every key that reaches the hash recorders is an
/// interned-string `.konst` (dispatch routes numeric keys to the array path),
/// so key identity is exactly konst-ref equality — interning + `konst()`'s
/// `(tag, bits)` dedup make equal content ⇔ the same ref. Walks newest→oldest
/// (last-writer-wins; `commit()` flushes oldest→newest — the pair keeps
/// repeated same-cell stores exact). Returns `true` when the load was resolved
/// (value forwarded or recording aborted); `false` → caller emits the heap read.
pub fn forwardPendingHashLoad(self: *TraceState, dst: u16, rtab: Ref, rkey: Ref) bool {
    var n = self.rec.pending_stores.items.len;
    while (n > 0) {
        n -= 1;
        const ps = self.rec.pending_stores.items[n];
        switch (ps.op) {
            // An in-bounds array store (the only array op ever buffered —
            // `astore_append` is emitted inline) can neither grow the array nor
            // migrate a hash cell, and every recordable hash key is a string:
            // NO alias, keep scanning.
            .astore => continue,
            .hstore => {},
            // Fail closed on any store op this classifier wasn't written for.
            else => {
                self.abort(.bad_type);
                return true;
            },
        }
        const addr = self.rec.instrs.items[ps.aref];
        std.debug.assert(addr.op == .href);
        // Distinct interned-string keys are distinct cells regardless of which
        // table each ref holds → NO.
        if (addr.b != rkey) continue;
        // Same key + same table SSA ref → MUST: forward the newest pending
        // value. Its type is already pinned by the store-side `guardNum`, and
        // at record time tier-0 has executed the store, so the observed loaded
        // value IS the stored value.
        if (addr.a == rtab) {
            self.setReg(dst, ps.value);
            return true;
        }
        // Same key, unproven table identity (two SSA refs may hold the same
        // table at runtime) → MAY: abort fail-closed. Never guard a runtime
        // identity relation between loop-varying refs.
        self.abort(.bad_type);
        return true;
    }
    return false;
}

pub fn classifyArrayKeyAlias(self: *const TraceState, lhs: Ref, rhs: Ref) AliasClass {
    if (lhs == rhs) return .must;
    const lc = self.intKonstRef(lhs);
    const rc = self.intKonstRef(rhs);
    if (lc != null and rc != null) return if (lc.? == rc.?) .must else .no;
    const la = self.affineIntKey(lhs, 0) orelse return .may;
    const ra = self.affineIntKey(rhs, 0) orelse return .may;
    if (la.base != ra.base) return .may;
    return if (la.offset == ra.offset) .must else .no;
}

pub fn intKonstRef(self: *const TraceState, ref: Ref) ?i64 {
    if (ref >= self.rec.instrs.items.len) return null;
    const ins = self.rec.instrs.items[ref];
    if (ins.op != .konst or ins.aux < 0) return null;
    const ci: usize = @intCast(ins.aux);
    if (ci >= self.rec.consts.items.len) return null;
    const v = self.rec.consts.items[ci];
    return if (v.isInt()) v.asInt() else null;
}

/// Canonicalise integer `base + constant` chains. Distinct offsets from the
/// same SSA base cannot alias; unrelated bases remain MAY. The recursion is
/// bounded defensively even though SSA operands point backward.
pub fn affineIntKey(self: *const TraceState, ref: Ref, depth: u8) ?AffineIntKey {
    if (depth == 16 or ref >= self.rec.instrs.items.len) return null;
    const ins = self.rec.instrs.items[ref];
    if (ins.op != .add or ins.ty != .int) return .{ .base = ref, .offset = 0 };
    if (self.intKonstRef(ins.a)) |c| {
        var key = self.affineIntKey(ins.b, depth + 1) orelse return null;
        key.offset +%= c;
        return key;
    }
    if (self.intKonstRef(ins.b)) |c| {
        var key = self.affineIntKey(ins.a, depth + 1) orelse return null;
        key.offset +%= c;
        return key;
    }
    return .{ .base = ref, .offset = 0 };
}

/// Record `t[k]=v` (`set_index`, `a=table b=key c=value`) as a lane-aware
/// packed-array write. Emits, in order: `guard_table` + `guard_lane` on the
/// table ref, `guard_int` on the key, then `aref` + `guard_bounds` + `astore`
/// — the FIRST mid-iteration heap mutation in the system. Aborts (leaving
/// tier-0 untouched) unless the store is a *present, in-bounds, in-lane*
/// slot whose value is deopt-replay-safe:
///   * non-table container or non-integral key → `.bad_type` (hash-part /
///     metatable territory, out of scope; an integral-FLOAT key narrows via
///     `keyRefNarrowed`, mirroring tier-0's `normalizeKey`);
///   * `.value`-lane array with a non-numeric value → `.nyi_opcode`. An int or
///     float IS recordable there (doc 32): every value fits the type-erased lane,
///     so no widen can be forced, and `guardNum` on the stored value replaces the
///     vacuous `guard_fits` as the type pin. A heap value stays out — it would be
///     the one shape needing a real write barrier under a future
///     generational/incremental collector. A `.value`-lane *append* is also still
///     out of scope: the append branch admits only bool/int lanes, so a `.value`
///     append falls through to the bounds check and aborts `.bad_type`;
///   * out-of-bounds (`k>len` would *grow*, `k<1` is the hash part) → `.bad_type`;
///   * `nil` value → `.bad_type` (a hole-punch / delete, not a normal store; B3
///     models presence-creating writes only — keeps `astore creates presence`);
///   * out-of-lane value (a value the current narrow lane can't hold would
///     *widen* — a shape change / allocation the native store can't do) →
///     `.bad_type`;
///   * **C1 (deopt-replay idempotence):** *any* packed-array read (`aload`)
///     recorded earlier in this trace → `.bad_type`. On a side-exit, tier-0
///     re-runs the aborted iteration against the *already-mutated* heap, so a
///     write whose value — OR whose very occurrence (control flow) — was decided
///     by a read could double-apply. A *data*-only check is unsound: a guard on a
///     read picks the branch, so `if t[i] then t[i]=false else t[i]=true end`
///     stores a constant yet replays differently. In a straight-line trace every
///     prior guard dominates this store, and every read-derived decision flows
///     through a guard, so "no earlier `aload` at all" covers both the data and
///     control channels with one obviously-sound rule. nsieve's sieve-clearing
///     loop is a pure write of `false` (no `aload`), so the rule costs it nothing.
pub fn recArraySet(self: *TraceState, instr: Instr, regs: RegWindow) !void {
    return self.arraySetShape(regs, .{ .tab = instr.a, .key = instr.b, .val = instr.c, .tab_od = .a, .key_od = .b, .val_od = .c });
}

pub fn arraySetShape(self: *TraceState, regs: RegWindow, f: SetFrame) !void {
    // NB (Gap C): unlike the single-store original, a store arriving while other
    // stores are already deferred is NOT blanket-aborted here. An in-bounds RMW
    // store appends to `pending_stores` (the in-bounds path below); an *append*
    // store (which changes `len`) must still abort — handled in the append branch.
    // The pending-store checks live at those two sites, not at the top,
    // because we cannot tell append-vs-in-bounds until we know `idx`/`len` below.
    // See `docs/design/08-multi-store-sinking.md`.
    const vtab = regs.get(f.tab);
    const vkey = regs.get(f.key);
    const vval = regs.get(f.val);
    if (!vtab.isHeap() or vtab.heapType() != .table) return self.abort(.bad_type);
    const idx = keyIndexOf(vkey) orelse return self.abort(.bad_type);
    if (vval.isNil()) return self.abort(.bad_type); // hole-punch — out of scope
    const tbl = table_mod.Table.fromHeader(vtab.asHeap());
    // A metatable means an absent-key store could fire `__newindex` (chunk 2a);
    // the append path below stores to exactly such an absent key (`len+1`).
    // Abort the whole trace to tier-0, which does full `__newindex` dispatch.
    if (tbl.metatable != null) return self.abort(.has_metatable);
    const lane = tbl.array.lane;
    // `.value`-lane store (doc 32): the type-erased lane holds full 16-byte
    // Values, so *any* value fits and no widen can ever be forced. Admitted for
    // **int/float** values only — the same restriction `hashSetShape` applies,
    // and for the same reason: those are the values with a strict type guard
    // (`guard_int`/`guard_float`) that keeps the cell scalar on-trace. A heap
    // value would additionally be the one shape needing a real write barrier
    // under any future generational/incremental collector.
    if (lane == .value and !(vval.isInt() or vval.isFloat())) return self.abort(.nyi_opcode);

    // Grow (append) store: `t[asize] = v` extends the dense run by one (doc 18
    // D2.3: under identity mapping the contiguous successor key IS `asize`).
    // This is
    // the bulk of an array-fill loop (nsieve's `for i=2,m do p[i]=true end` after
    // its first rehash narrows to the boolean lane and drains the hash). Rather
    // than abort the whole trace (the historic behaviour — the fill then ran fully
    // tier-0), record an `astore_append` guarded so the realloc/migrate cases fall
    // back to tier-0 while the in-capacity common case runs native. Phase A: the
    // boolean lane (one in-band byte/slot) and the fixed-width int lanes
    // (i8…i64: width store + presence bit) — exactly the lanes the native
    // in-bounds `astore` lowers (`nativegen.laneKind`). `.f64` needs XMM stores
    // the array path does not yet emit, so it (and `.value`) still abort below.
    // The emitted IR sequence is lane-generic; `guard_fits` (below) supplies the
    // int lane's runtime range check, and the value's static `.int` kind comes
    // from its producing ref (the loop slot) — same as the in-bounds int store.
    if ((lane == .boolean or lane.isInt()) and
        idx == @as(i64, @intCast(tbl.array.asize)) and
        tbl.hash.count() == 0 and
        tbl.array.fits(vval))
    {
        // Same C1 deopt-replay rule as `astore`: a prior packed-array read could
        // have steered this store's value or occurrence, and re-running the
        // iteration on a side-exit (against the now-longer array) would diverge.
        // (A non-empty `pending_stores` implies a prior `aload`, so this also
        // covers "append after a sunk store" — an append changes `len` and is
        // never deferred; `docs/design/08-multi-store-sinking.md` §soundness.)
        if (self.traceHasHeapLoad()) return self.abort(.bad_type);
        const rval = try self.refOf(f.val);
        const lane_ord: i32 = @intFromEnum(lane);
        const rtab = try self.refOf(f.tab);
        self.stampProv(try self.emit(.{ .op = .guard_table, .a = rtab }), .container_type, f.tab_od, .neutral);
        self.stampProv(try self.emit(.{ .op = .guard_lane, .a = rtab, .aux = lane_ord }), .container_lane, f.tab_od, .neutral);
        const rkey = try self.keyRefNarrowed(f.key, f.key_od, vkey);
        const ref = try self.emit(.{ .op = .aref, .a = rtab, .b = rkey, .aux = lane_ord });
        // guard_append: hash-empty + `idx==asize` + `asize<cap`. The grow analogue
        // of guard_bounds — side-exits to tier-0 (which reallocs/migrates) when
        // any precondition fails, so the on-trace append never allocates.
        self.stampProv(try self.emit(.{ .op = .guard_append, .a = ref }), .append_precond, .none, .neutral);
        // guard_fits: the value still fits the narrow lane (the oracle re-checks a
        // free-variable store; native bool already proves `.bool`). Same as astore.
        self.noteEntryKindFromLane(rval, lane); // doc 39: fit implies type
        self.stampProv(try self.emit(.{ .op = .guard_fits, .a = rval, .aux = lane_ord }), .value_fits, f.val_od, .neutral);
        _ = try self.emit(.{ .op = .astore_append, .a = ref, .b = rval, .aux = lane_ord });
        return;
    }

    if (!arr.ArrayPart.inArray(idx, tbl.array.asize)) return self.abort(.bad_type);
    // The value must fit the current lane unchanged — an out-of-lane store
    // would widen the array (shape change / allocation) which the native ABI
    // cannot perform; the prologue `guard_lane` then stays sufficient.
    if (!tbl.array.fits(vval)) return self.abort(.bad_type);

    // C1 / store-sinking: if this trace has already read the packed array, an
    // inline store would be deopt-unsound — on a side-exit *after* the store,
    // tier-0 re-runs the whole iteration against the mutated heap and a
    // read-modify-write double-applies (the read steered this store's value or
    // its control flow). Instead of aborting, DEFER the store: emit its address
    // + guards inline here, but stash the `astore` node and flush it at trace
    // close (`commit`) below every guard — incl. the `for_loop` continuation
    // guard — so every side-exit leaves the store un-executed and replay stores
    // exactly once. The virtual store buffer grows only within `maxrecord`, and
    // flushes in recorded order. A later array load either forwards from it or
    // proves non-aliasing with fail-closed guards; append remains unsupported
    // because it changes shape. A pure-write store (no prior `aload`) is
    // deopt-idempotent and emits inline as before.
    const defer_store = self.traceHasHeapLoad();
    const rval = try self.refOf(f.val);

    const lane_ord: i32 = @intFromEnum(lane);
    const rtab = try self.refOf(f.tab);
    self.stampProv(try self.emit(.{ .op = .guard_table, .a = rtab }), .container_type, f.tab_od, .neutral);
    self.stampProv(try self.emit(.{ .op = .guard_lane, .a = rtab, .aux = lane_ord }), .container_lane, f.tab_od, .neutral);
    const rkey = try self.keyRefNarrowed(f.key, f.key_od, vkey);
    const ref = try self.emit(.{ .op = .aref, .a = rtab, .b = rkey, .aux = lane_ord });
    self.stampProv(try self.emit(.{ .op = .guard_bounds, .a = ref }), .bounds, .none, .neutral);
    // Pin the stored value's type. Which guard does that depends on the lane, and
    // exactly one of the two is emitted:
    //
    // **Narrow lane → `guard_fits`.** The value must still fit the recorded lane:
    // a later iteration storing an out-of-lane value (an out-of-range/non-int int
    // into an int lane, a non-bool into the bool lane, a non-float into f64) would
    // force tier-0 to WIDEN the lane (alloc + relayout), which the native store
    // can't do mid-run and which would trip the tier-1a oracle's in-place
    // `setInLane` encode (`assert(fits(val))`) — so `guard_fits` side-exits
    // instead and lets tier-0 re-run + widen. The `astore` value can be a free
    // variable (a loop-carried slot), not just a constant, so the recorder cannot
    // assume it stays in-lane. For the bool lane native lowers this to nothing —
    // the value is already proven `.bool` at analysis time — but the oracle, which
    // runs the raw trace, still needs the runtime check. Fit implies type here
    // (`laneFits(.i32, v)` requires `v.isInt()`), so this doubles as the type pin.
    //
    // **`.value` lane → `guardNum` (doc 32).** `laneFits(.value, _)` is
    // unconditionally true, so `guard_fits` would degenerate to a no-op that pins
    // NOTHING — tropt would fold it as always-pass, and the oracle's `fits` assert
    // passes for any value. Recording observed an int/float once; that does not
    // make the producing ref numeric on a later iteration. Without an explicit
    // pin, tier-1a would store a drifted bool/heap into the cell while native had
    // assumed a numeric kind — an oracle divergence. This is the same guard, for
    // the same reason, that `hashSetShape` emits on a hash-cell store: neither
    // site has a lane to constrain the value. It also carries the *forwarded*
    // read: `forwardPendingArrayLoad` returns before any load guard is emitted, so
    // a forwarded `.value` load inherits its type pin entirely from here.
    if (lane == .value) {
        try self.guardNum(rval, vval, .value_type, f.val_od);
    } else {
        self.noteEntryKindFromLane(rval, lane); // doc 39: fit implies type
        self.stampProv(try self.emit(.{ .op = .guard_fits, .a = rval, .aux = lane_ord }), .value_fits, f.val_od, .neutral);
    }
    // No `guard_present`: on a narrow lane `astore` *creates* presence (the slot
    // is in-bounds by `guard_bounds`; storing a non-nil value sets the presence
    // bit), and the `.value` lane has no presence bitmap at all — nil is in-band,
    // and the store writes a non-nil value by the `isNil` abort above. The store
    // is effectful and not register-defining, so nothing is `setReg`'d.
    if (defer_store) {
        // Read-modify-write: stash the store; `commit()` flushes it (and any
        // siblings) below every guard, just before `.loop`, in this recorded
        // order. The guards above (table/lane/int/bounds/fits) stay inline and
        // continue to dominate the sunk store.
        try self.rec.pending_stores.append(self.gpa, .{
            .aref = ref,
            .value = rval,
            .lane_ord = lane_ord,
        });
    } else {
        _ = try self.emit(.{ .op = .astore, .a = ref, .b = rval, .aux = lane_ord });
    }
}

/// Record `a[i][j]` (`get_index2`, `dst=a tab=b row=c col=aux`) as a flattened-
/// grid cell read (doc 14, Phase 8). Emits, in order: `guard_grid` + `guard_stride`
/// on the table, `guard_int` on row + col, the `garow`/`gcell` address chain with
/// `guard_bounds` (row) + `guard_gcol` (col), then `guard_gpresent` + `gload`.
/// Aborts (leaving tier-0 untouched) unless the container is already a grid with an
/// **int or f64** element lane and the access is a *present, in-bounds* cell — every
/// other shape (a not-yet-inflated nested table, an out-of-bounds/hole cell) runs on
/// tier-0.
pub fn recGridGet(self: *TraceState, instr: Instr, regs: RegWindow) !void {
    // Like recArrayGet: a grid load after a sunk store would read stale on-trace.
    if (self.rec.pending_stores.items.len > 0) return self.abort(.bad_type);
    const col_reg: u16 = @intCast(instr.aux);
    const vtab = regs.get(instr.b);
    const vrow = regs.get(instr.c);
    const vcol = regs.get(col_reg);
    if (!vtab.isHeap() or vtab.heapType() != .table) return self.abort(.bad_type);
    if (!vrow.isInt() or !vcol.isInt()) return self.abort(.bad_type);
    const tbl = table_mod.Table.fromHeader(vtab.asHeap());
    if (tbl.metatable != null) return self.abort(.has_metatable);
    const ap = &tbl.array;
    if (ap.lane != .grid) return self.abort(.nyi_opcode); // not inflated → nested-table path (deferred)
    if (!ap.grid_elem.isInt() and ap.grid_elem != .f64) return self.abort(.nyi_opcode); // only int + f64 cells lower
    if (ap.stride > std.math.maxInt(i32)) return self.abort(.bad_type); // guard_stride aux is i32
    const row = vrow.asInt();
    const col = vcol.asInt();
    if (row < 1 or row > @as(i64, @intCast(ap.gridRows()))) return self.abort(.bad_type);
    if (col < 1 or col > @as(i64, @intCast(ap.stride))) return self.abort(.bad_type);
    const loaded = ap.gridGet(@intCast(row - 1), @intCast(col - 1));
    if (loaded.isNil()) return self.abort(.bad_type); // hole — not a profitable trace

    const ge: i32 = @intFromEnum(ap.grid_elem);
    const stride_aux: i32 = @intCast(ap.stride);
    const rtab = try self.refOf(instr.b);
    self.stampProv(try self.emit(.{ .op = .guard_grid, .a = rtab, .aux = ge }), .grid_shape, .b, .neutral);
    self.stampProv(try self.emit(.{ .op = .guard_stride, .a = rtab, .aux = stride_aux }), .grid_stride, .b, .neutral);
    const rrow = try self.refOf(instr.c);
    try self.guardInt(rrow, .row_type, .c);
    const rcol = try self.refOf(col_reg);
    try self.guardInt(rcol, .col_type, .aux);
    const garow = try self.emit(.{ .op = .garow, .a = rtab, .b = rrow, .aux = ge });
    self.stampProv(try self.emit(.{ .op = .guard_bounds, .a = garow }), .row_bounds, .none, .neutral); // row in [1,rows]
    const gcell = try self.emit(.{ .op = .gcell, .a = garow, .b = rcol, .aux = ge });
    // guard_gcol carries the column ref in `.b` (col in [1,stride]); native keeps
    // it live for the range-compare, the oracle re-reads gcell.b instead.
    self.stampProv(try self.emit(.{ .op = .guard_gcol, .a = gcell, .b = rcol }), .col_bounds, .none, .neutral);
    self.stampProv(try self.emit(.{ .op = .guard_gpresent, .a = gcell }), .present, .none, .neutral);
    const rload = try self.emit(.{ .op = .gload, .a = gcell, .aux = ge, .ty = obsTypeOf(loaded) });
    self.setReg(instr.a, rload);
}

/// Record `a[i][j]=v` (`set_index2`, `tab=a row=b col=c val=aux`) as a flattened-
/// grid cell write (doc 14, Phase 8). Mirrors `recGridGet`'s addressing, then
/// `guard_fits` + `gstore`. Aborts unless the store is an in-grid, in-bounds,
/// in-lane cell write: a new row (`row>rows`) or column past `stride` would GROW
/// the grid, and an out-of-lane value would WIDEN it — both reshape/realloc the
/// flat buffer, which the on-trace store cannot do, so they run on tier-0 (the
/// guards then side-exit on a later iteration that would reshape). Phase 8a keeps
/// the C1 deopt-replay rule simple: a store after *any* heap read aborts (no
/// store-sinking yet) — matmul's hot inner loop is read-only, so this is free.
pub fn recGridSet(self: *TraceState, instr: Instr, regs: RegWindow) !void {
    const val_reg: u16 = @intCast(instr.aux);
    const vtab = regs.get(instr.a);
    const vrow = regs.get(instr.b);
    const vcol = regs.get(instr.c);
    const vval = regs.get(val_reg);
    if (!vtab.isHeap() or vtab.heapType() != .table) return self.abort(.bad_type);
    if (!vrow.isInt() or !vcol.isInt()) return self.abort(.bad_type);
    if (vval.isNil()) return self.abort(.bad_type); // hole-punch — out of scope
    const tbl = table_mod.Table.fromHeader(vtab.asHeap());
    if (tbl.metatable != null) return self.abort(.has_metatable);
    const ap = &tbl.array;
    if (ap.lane != .grid) return self.abort(.nyi_opcode);
    if (!ap.grid_elem.isInt() and ap.grid_elem != .f64) return self.abort(.nyi_opcode); // only int + f64 cells lower
    if (ap.stride > std.math.maxInt(i32)) return self.abort(.bad_type);
    const row = vrow.asInt();
    const col = vcol.asInt();
    if (row < 1 or row > @as(i64, @intCast(ap.gridRows()))) return self.abort(.bad_type); // grow row → tier-0
    if (col < 1 or col > @as(i64, @intCast(ap.stride))) return self.abort(.bad_type); // grow stride → tier-0
    if (!arr.ArrayPart.laneFits(ap.grid_elem, vval)) return self.abort(.bad_type); // widen elem → tier-0
    // C1 (deopt-replay idempotence): a store after any prior heap read could
    // double-apply when a side-exit re-runs the iteration against the already-
    // mutated grid. Phase 8a aborts rather than sinking (see recArraySet for the
    // sinking machinery a later phase can extend to grids).
    if (self.traceHasHeapLoad()) return self.abort(.bad_type);

    const ge: i32 = @intFromEnum(ap.grid_elem);
    const stride_aux: i32 = @intCast(ap.stride);
    const rval = try self.refOf(val_reg);
    const rtab = try self.refOf(instr.a);
    self.stampProv(try self.emit(.{ .op = .guard_grid, .a = rtab, .aux = ge }), .grid_shape, .a, .neutral);
    self.stampProv(try self.emit(.{ .op = .guard_stride, .a = rtab, .aux = stride_aux }), .grid_stride, .a, .neutral);
    const rrow = try self.refOf(instr.b);
    try self.guardInt(rrow, .row_type, .b);
    const rcol = try self.refOf(instr.c);
    try self.guardInt(rcol, .col_type, .c);
    const garow = try self.emit(.{ .op = .garow, .a = rtab, .b = rrow, .aux = ge });
    self.stampProv(try self.emit(.{ .op = .guard_bounds, .a = garow }), .row_bounds, .none, .neutral);
    const gcell = try self.emit(.{ .op = .gcell, .a = garow, .b = rcol, .aux = ge });
    self.stampProv(try self.emit(.{ .op = .guard_gcol, .a = gcell, .b = rcol }), .col_bounds, .none, .neutral);
    self.stampProv(try self.emit(.{ .op = .guard_fits, .a = rval, .aux = ge }), .value_fits, .aux, .neutral);
    // No guard_gpresent: gstore *creates* presence (mirrors astore).
    _ = try self.emit(.{ .op = .gstore, .a = gcell, .b = rval, .aux = ge });
}

/// C1 support: has *any* heap read — a packed-array `aload`, a hash-field
/// `hload` (doc 11), OR a grid-cell `gload` (doc 14) — been recorded so far in
/// this trace? Used by `recArraySet`/`recHashSet`/`recGridSet` to decide whether a
/// write is a read-modify-write that must be deopt-sunk (or, for grids in Phase 8a,
/// aborted). This is the conservative-sound C1 rule: in a straight-line trace any
/// earlier read can influence a later write through its value (data) or through a
/// guard that selected the path (control), and a side-exit replays the iteration
/// against the already-mutated heap. Rejecting on the mere presence of an earlier
/// read covers both channels without per-value taint reasoning. A pure-write loop
/// (no `aload`/`hload`/`gload`, e.g. nsieve's sieve clear) is unaffected. The three
/// load kinds are pooled because an `aload`-then-`hstore` (or any cross pair) is
/// just as deopt-unsound as same-kind RMW.
pub fn traceHasHeapLoad(self: *const TraceState) bool {
    for (self.rec.instrs.items) |ins| {
        if (ins.op == .aload or ins.op == .hload or ins.op == .gload) return true;
    }
    return false;
}

/// Is `v` a heap **string** — i.e. an `obj.field`-shaped (hash-part) table key?
/// The compiler lowers every `obj.field` to `get_index`/`set_index` with an
/// interned-string key, so this is the gate that routes such accesses to the
/// hash-field path (doc 11) instead of the integer-array path.
pub fn isStringKey(v: Value) bool {
    return v.isHeap() and v.heapType() == .string;
}

/// H1 native seeding (Approach B, doc 11 §5). Register the loop-invariant
/// **value-cell pointer** of a constant-key field access as a `hash_cell` entry
/// input so the *native* path can read the cell from the slab prologue
/// (`[rsi + slot*8]`), exactly as U0 hoists an upvalue/global. Returns the
/// synthetic slab slot to stamp into `href.aux`, or `null` when the cell can't be
/// seeded — in which case the trace is still valid at **tier-1a** (the oracle
/// re-derives the cell from `href`'s `(table,key)` operands each iteration and
/// ignores `aux`); only *native* execution declines for this entry.
///
/// `rtab` must resolve to a `slot_load` so the dispatch loop can re-read the
/// table value from an anchor slot every entry; a table produced on-trace (e.g. a
/// call result) isn't seedable. `rkey` is the `konst` ref whose `aux` is the
/// key's const-pool index — recorded as `source` so `seedTraceInputs` can recover
/// the key `Value` and call `Table.fieldPtr`. `count` is the recorded
/// `hash.count()` (the `guard_hash` aux) the seed re-validates at entry, the
/// native analogue of the oracle's per-iteration `guard_hash` population check.
///
/// Unlike `recInputGet`, exhausting the input budget is **not** an abort: the
/// tier-1a trace stands, native just declines (returns `null`). An RMW's read and
/// write `href`s dedup onto one slot via `hash_cell_dedup`.
pub fn seedHashCell(self: *TraceState, rtab: Ref, rkey: Ref, count: u32) !?u16 {
    const tab_instr = self.rec.instrs.items[@intCast(rtab)];
    // The table must live in a re-readable anchor slot (a `slot_load`, which both
    // an ordinary register read and a U0-seeded upvalue/global resolve to). A
    // table computed on-trace has no entry slab slot to re-resolve from.
    if (tab_instr.op != .slot_load) return null;
    const table_reg: u16 = @intCast(tab_instr.aux);
    const key_const: u32 = @intCast(self.rec.instrs.items[@intCast(rkey)].aux);

    const dkey = (@as(u64, table_reg) << 32) | key_const;
    if (self.rec.hash_cell_dedup.get(dkey)) |slot| return slot;

    // Budget/index guards mirror `recInputGet`, but a miss declines native rather
    // than aborting the (still-valid-at-tier-1a) trace.
    if (self.rec.input_seeds.items.len >= MAX_TRACE_INPUTS) return null;
    if (self.rec.next_input_slot == std.math.maxInt(u16)) return null;

    const slot = self.rec.next_input_slot;
    self.rec.next_input_slot += 1;
    try self.rec.input_seeds.append(self.gpa, .{
        .kind = .hash_cell,
        .source = key_const,
        .slot = slot,
        .table_reg = table_reg,
        .expected_count = count,
    });
    try self.rec.hash_cell_dedup.put(self.gpa, dkey, slot);
    return slot;
}

/// Record `t.field` (`get_index`, `dst=a b=table c=key`, key an interned
/// string) as a hash-part field read. The string analogue of `recArrayGet`.
/// Emits, in order: `guard_table`(table) → `href`(table, keyconst) →
/// `guard_hash`(href, aux=recorded population) → `hload`(href) → the existing
/// type-guard on the `hload` ref (`guard_int`/`guard_float`/…). The cell address
/// is loop-invariant for a constant key (hoistable to the native prologue in
/// H1), so the read mirrors the array `aref`/`aload` path. Aborts (leaving
/// tier-0 untouched) unless the access is a *present, non-metatable, constant-
/// key* hash field — the only shape the oracle/native path models:
///   * non-table container → `.bad_type`;
///   * `tbl.metatable != null` → `.has_metatable` (an absent slot could fire
///     `__index`; even a present slot could become absent on a later iteration);
///   * key absent from the hash part at record time → `.bad_type` (an absent-key
///     access is the migrate/`__index`/grow territory v1 excludes; the present-
///     key rule is what keeps the hoisted cell from dangling);
///   * computed (non-`konst`) key → `.bad_type` (a runtime-varying key cannot be
///     pinned to one cell — v1 scope; `t[expr]` stays tier-0);
///   * a pending (sunk) store that MAY-aliases this load → `.bad_type` (doc 08
///     §2026-08-20): the deferred-store buffer is consulted first via
///     `forwardPendingHashLoad` — a MUST-alias forwards the pending value, a
///     proven NO falls through to the heap read, and only the ambiguous
///     same-key/different-table-ref case aborts fail-closed.
pub fn recHashGet(self: *TraceState, instr: Instr, regs: RegWindow) !void {
    return self.hashGetShape(regs, .{ .dst = instr.a, .tab = instr.b, .key = instr.c, .tab_od = .b, .key_od = .c });
}

pub fn hashGetShape(self: *TraceState, regs: RegWindow, f: GetFrame) !void {
    const vtab = regs.get(f.tab);
    const vkey = regs.get(f.key);
    if (!vtab.isHeap() or vtab.heapType() != .table) return self.abort(.bad_type);
    const tbl = table_mod.Table.fromHeader(vtab.asHeap());
    if (tbl.metatable != null) return self.abort(.has_metatable);
    const cell = tbl.fieldPtr(vkey) orelse return self.abort(.bad_type); // absent
    // Scalar-field restriction (the hash analogue of the narrow-array-lane rule).
    // A present cell holds a non-`nil` tagged `Value` of any type. We trace only
    // **int/float** fields, for two joined reasons: (1) the scalar exec-log
    // encoder (the cross-mode determinism oracle) cannot encode a heap value, so
    // `hload`'s logged value must be scalar; (2) only int/float have a *strict*
    // type guard (`guard_int`/`guard_float`) that pins the field's type so a later
    // iteration changing it side-exits — a `bool` field could silently become a
    // truthy heap value that `guard_true` would wave through. A bool/heap/string
    // field therefore aborts to tier-0, exactly as a `.value` array lane does.
    const fv = cell.*;
    if (!(fv.isInt() or fv.isFloat())) return self.abort(.nyi_opcode);
    // The key must be a recorded `konst` (the bytecode literal interned via
    // `load_const`), so its ref is provably the constant — no runtime key-
    // identity guard is needed and the cell is pinnable. A computed key reaches
    // here as a `slot_load`/arith ref and aborts (v1 scope).
    const rkey = try self.refOf(f.key);
    if (self.rec.instrs.items[@intCast(rkey)].op != .konst) return self.abort(.bad_type);

    const rtab = try self.refOf(f.tab);
    // Resolve against the deferred-store buffer BEFORE emitting the load chain
    // (doc 08 §2026-08-20): a MUST-alias forwards the pending value (the store
    // side already emitted `guard_table`/`href`/`guard_hash`/`guardNum` on this
    // same table ref + key konst, so no chain is re-emitted here), NO keeps
    // scanning / falls through to the heap read, MAY aborts fail-closed.
    if (self.forwardPendingHashLoad(f.dst, rtab, rkey)) return;
    self.stampProv(try self.emit(.{ .op = .guard_table, .a = rtab }), .container_type, f.tab_od, .neutral);
    // Seed the loop-invariant cell pointer for native (H1); `href.aux` carries
    // the synthetic slab slot, or `-1` to mark "not seeded → native declines".
    // The tier-1a oracle ignores `aux`, so a `null` seed leaves H0 untouched.
    const count: u32 = @intCast(tbl.hash.count());
    const seed_slot = try self.seedHashCell(rtab, rkey, count);
    const ref = try self.emit(.{ .op = .href, .a = rtab, .b = rkey, .aux = if (seed_slot) |s| @as(i32, s) else -1 });
    // Fused native producer-exit (A-i.3): native `href` side-exits at the address
    // node on cell-resolution failure (`nativegen.zig`), no `guard_*` — same guest
    // hash access as `guard_hash`, so it shares `(hash_struct, b)`.
    self.stampProv(ref, .hash_struct, f.tab_od, .neutral);
    self.stampProv(try self.emit(.{ .op = .guard_hash, .a = ref, .aux = @intCast(count) }), .hash_struct, f.tab_od, .neutral);
    const rload = try self.emit(.{ .op = .hload, .a = ref, .ty = obsTypeOf(fv) });
    // Fused native producer-exit (A-i.3): native `hload` side-exits at the load on
    // a field-type change, no `guard_*` node — same site as the consumer guardNum.
    self.stampProv(rload, .field_type, .loaded, .neutral);
    self.setReg(f.dst, rload);
    // Decompose the tagged-cell load into a typed load + the existing consumer
    // type-guard (mirrors `slot_load` + `guardNum`): native lowers `hload` to a
    // tag-check + payload load of the guarded kind. The oracle returns the whole
    // `Value`, so this guard is what makes the two agree on the side-exit
    // iteration (and pins the field type — int→float etc. side-exits).
    try self.guardNum(rload, fv, .field_type, .loaded);
}

/// Record `t.field = v` (`set_index`, `a=table b=key c=value`, key an interned
/// string) as a hash-part field write. The string analogue of `recArraySet`'s
/// in-bounds store. Present-key overwrite ONLY: the recorder rejects an absent
/// key (an insert could grow/rehash and dangle every hoisted cell) and a `nil`
/// value (a delete). Follows the same C1 store-sink discipline as `recArraySet`
/// — a store following any heap load is deferred below every guard (`commit`).
/// Aborts unless:
///   * non-table container → `.bad_type`;
///   * `nil` value (delete) → `.bad_type`;
///   * `tbl.metatable != null` → `.has_metatable` (`__newindex` territory);
///   * key absent at record time → `.bad_type` (insert — out of v1 scope);
///   * computed (non-`konst`) key → `.bad_type`;
///   * recorder allocation failure → `.alloc` (ordinary recording abort).
pub fn recHashSet(self: *TraceState, instr: Instr, regs: RegWindow) !void {
    return self.hashSetShape(regs, .{ .tab = instr.a, .key = instr.b, .val = instr.c, .tab_od = .a, .key_od = .b, .val_od = .c });
}

pub fn hashSetShape(self: *TraceState, regs: RegWindow, f: SetFrame) !void {
    const vtab = regs.get(f.tab);
    const vkey = regs.get(f.key);
    const vval = regs.get(f.val);
    if (!vtab.isHeap() or vtab.heapType() != .table) return self.abort(.bad_type);
    if (vval.isNil()) return self.abort(.bad_type); // delete — out of scope
    // Scalar-value restriction, the store mirror of `recHashGet`'s read rule: the
    // exec-log encoder is scalar-only, so the stored value (logged by its
    // producing `slot_load`/arith ref) must be int/float; a heap/bool field store
    // aborts to tier-0. Covers the int/float field arithmetic OOP code does
    // (`obj.x = obj.x + dt*vx`); reference fields (`obj.next = node`) stay tier-0.
    if (!(vval.isInt() or vval.isFloat())) return self.abort(.nyi_opcode);
    const tbl = table_mod.Table.fromHeader(vtab.asHeap());
    if (tbl.metatable != null) return self.abort(.has_metatable);
    _ = tbl.fieldPtr(vkey) orelse return self.abort(.bad_type); // absent = insert
    const rkey = try self.refOf(f.key);
    if (self.rec.instrs.items[@intCast(rkey)].op != .konst) return self.abort(.bad_type);

    // C1 / store-sinking, identical to `recArraySet`: a write following any heap
    // read is a read-modify-write that must be deferred below every guard so a
    // side-exit leaves it un-executed and deopt-replay applies it exactly once.
    const defer_store = self.traceHasHeapLoad();
    const rval = try self.refOf(f.val);
    // Pin the **store value's** type (int/float). A hash cell holds a full tagged
    // `Value` with no lane to constrain it, so this guard is the analogue of the
    // array path's `guard_fits`: it is the sole guarantee the field stays scalar
    // on-trace. Without it, a value whose runtime type drifts (int→heap) would be
    // written into the cell, and a later `hload` would read a non-scalar into the
    // scalar-only exec log. Emitting it inline (it stays in the body even when the
    // store sinks) makes a drifted store value side-exit *before* the write lands.
    // Sound via the standard deduped `guardNum`: `guarded_refs` holds only numeric
    // guards (truthiness `guard_true`/`guard_false` are emitted raw, never
    // registered), so a prior guard on this ref is necessarily a matching
    // `guard_int`/`guard_float`.
    try self.guardNum(rval, vval, .value_type, f.val_od);
    const rtab = try self.refOf(f.tab);
    self.stampProv(try self.emit(.{ .op = .guard_table, .a = rtab }), .container_type, f.tab_od, .neutral);
    // Seed the cell pointer for native (H1) — see `recHashGet`. An RMW's read and
    // write `href`s dedup onto the same slot via `seedHashCell`.
    const count: u32 = @intCast(tbl.hash.count());
    const seed_slot = try self.seedHashCell(rtab, rkey, count);
    const ref = try self.emit(.{ .op = .href, .a = rtab, .b = rkey, .aux = if (seed_slot) |s| @as(i32, s) else -1 });
    // Fused native producer-exit (A-i.3): native `href` cell-resolution failure.
    self.stampProv(ref, .hash_struct, f.tab_od, .neutral);
    self.stampProv(try self.emit(.{ .op = .guard_hash, .a = ref, .aux = @intCast(count) }), .hash_struct, f.tab_od, .neutral);
    // `hstore` is effectful (overwrites the present cell in place) and defines no
    // register. A present-key overwrite never grows the map, so `guard_hash`
    // (population) stays sufficient. The store value's type is pinned by the
    // `guardNum` above (native declines a heap value at H1).
    if (defer_store) {
        try self.rec.pending_stores.append(self.gpa, .{
            .aref = ref,
            .value = rval,
            .lane_ord = 0,
            .op = .hstore,
        });
    } else {
        _ = try self.emit(.{ .op = .hstore, .a = ref, .b = rval });
    }
}

/// `eq`/`ne`. First cut: numeric operands only (the common loop-condition
/// case); other types abort.
pub fn recEq(self: *TraceState, op: IrOp, instr: Instr, regs: RegWindow) !void {
    const rb = try self.refOf(instr.b);
    const rc = try self.refOf(instr.c);
    // Konst×konst folds to a bool konst with zero runtime work — `Value.eql`
    // at record time is exact for every type (interned strings compare by
    // identity). This is what makes the `type(x) == "number"` idiom (doc 23)
    // collapse entirely: both sides are konsts (the `type` fold and the proto
    // constant), so the comparison — and via the branch guard on a constant,
    // the whole test — vanishes from the trace body.
    if (self.konstValueOf(rb)) |kb| if (self.konstValueOf(rc)) |kc| {
        const equal = kb.eql(kc);
        self.setReg(instr.a, try self.konst(Value.boolean(if (op == .eq) equal else !equal)));
        return;
    };
    const vb = regs.get(instr.b);
    const vc = regs.get(instr.c);
    if (!vb.isNumber() or !vc.isNumber()) return self.abort(.bad_type);
    try self.guardNum(rb, vb, .operand_type, .b);
    try self.guardNum(rc, vc, .operand_type, .c);
    const r = try self.emit(.{ .op = op, .a = rb, .b = rc, .ty = .boolean });
    self.setReg(instr.a, r);
}

/// `jmp_if_false`/`jmp_if_true`: pin the *observed* truthiness of the tested
/// register. Which path the trace records is whatever tier-0 took; the guard
/// is what keeps the straight-line trace valid.
pub fn recBranch(self: *TraceState, instr: Instr, regs: RegWindow, proto: *const Proto, pc: u32) !void {
    const truthy_early = regs.get(instr.a).isTruthy();
    // Doc 38 LLEAVE (LuaJIT `rec_loop_interp`): a ROOT trace anchored at a
    // loop header "must loop back to form a root trace". If this branch is
    // the anchor loop's OWN exit edge and tier-0 took the exit direction,
    // abort instead of recording the enclosing code — the retry (after the
    // record-gate cooldown) lands on a pass that stays in the loop and
    // records the loop-BODY root the continuation machinery links against.
    // Anchor-tied structurally, so exits of OTHER loops (sequential
    // whiles, an inlined callee's loops — excluded by depth 0) never
    // match; side/continuation recordings legitimately cross loop exits.
    if (self.rec.kind == .root and self.rec.inline_depth == 0 and
        self.rec.anchor.proto == proto)
    {
        const jumped = (instr.op == .jmp_if_true) == truthy_early;
        const target_i: i64 = @as(i64, pc) + instr.aux; // `pc` = post-increment cursor, as in applyJump
        if (target_i >= 0 and target_i < @as(i64, @intCast(proto.code.len))) {
            const target: u32 = @intCast(target_i);
            if (target > pc) {
                // `while` shape: forward branch over the body whose last
                // instruction is the backward `jmp` to our anchor (the
                // condition start). Taking the branch leaves the loop.
                //
                // ROOT recordings abort unconditionally (LuaJIT LLEAVE):
                // the retry lands on a cond-true pass and records the
                // body root first. The cond-false GLUE sibling
                // (`guard_false → outer body → loop`, the figure-eight —
                // measured 78.5 cyc/it vs 137 for root+link on a
                // bounded-variance nest) is deliberately reachable only
                // through the SIDE-trace route: `.side` recordings skip
                // this check by kind, and the side want at a while-done
                // exit only accrues once the anchor's OBSERVED trips/entry
                // prove low (`whileDoneHotnessEligible`) — evidence a root
                // recording cannot have yet (no committed trace → no
                // receipts). That ordering keeps high-trip whiles
                // (nsieve-bit-fp) on the pure body-root + link family the
                // glue formation measurably degrades.
                if (jumped and target >= 1 and proto.code[target - 1].op == .jmp and
                    @as(i64, target) + proto.code[target - 1].aux == @as(i64, self.rec.anchor.pc))
                {
                    return self.abort(.loop_leave);
                }
            } else if (instr.op == .jmp_if_false and target == self.rec.anchor.pc and !jumped) {
                // `repeat`/`until` shape: backward `jmp_if_false` to our
                // anchor (the body start). Falling through leaves the loop.
                return self.abort(.loop_leave);
            }
        }
    }
    const ra = try self.refOf(instr.a);
    const truthy = truthy_early;
    // Fold statically-decided branches (doc 30 c5): a konst's truthiness is
    // fixed forever, and a proven-string producer result (`scap_str`,
    // `tostr_*`, the snew class) is ALWAYS truthy — only nil/false are
    // falsy in Lua, and a reachable string ref is never either. The guard
    // would be a tautology on the recorded direction, so emit nothing:
    // every tier wins (tier-1a skips a per-iteration re-check; native's
    // proveKinds rightly refuses to model heap truthiness, so an emitted
    // guard would bail the whole trace — the `if match(s, "^key")`
    // anchored-test shape). No region/polarity identity is lost either: a
    // branch that cannot diverge has no other CFG edge for a side trace.
    if (self.konstValueOf(ra)) |kv| {
        if (kv.isTruthy() == truthy) return;
        // A konst contradicting the observation is impossible (the konst IS
        // the observed value); fall through and emit the guard fail-closed.
    } else if (truthy and self.isProvenStringRef(ra)) {
        return;
    }
    const op: IrOp = if (truthy) .guard_true else .guard_false;
    const gref = try self.emit(.{ .op = op, .a = ra });
    // Branch polarity IS part of the identity (A-i.3, round-1 BLOCKER 1): the
    // true-exit and false-exit of one `if` are opposite CFG edges of the region.
    // Polarity names which guest CFG edge the RECORDED path took, keyed on the
    // branch's *jump-taken* edge (opcode-relative), NOT raw truthiness: a
    // `jmp_if_false` jumps when the value is falsy, a `jmp_if_true` when truthy.
    // So the recorded path took the branch iff `(op == jmp_if_true) == truthy`.
    const jumped = (instr.op == .jmp_if_true) == truthy;
    self.stampProv(gref, .branch_cond, .a, if (jumped) .taken else .fallthrough);
}

/// `for_loop` (numeric-for back-edge): record the increment and the
/// loop-continuation guard, mirroring the opcode. The actual back-edge / close
/// is handled by `onBackEdge`.
/// Generic-for back-edge (doc 30 c4): `tfor_loop base, target` — tier-0
/// continues iff the first loop variable (`base+3`) is non-nil, publishing
/// it as the next control (`base+2`). The recorder mirrors the CONTINUE
/// direction only: the observed v1 is pinned non-nil by its type guard
/// (number → `guardNum`, string → `guard_string`, table → `guard_table`;
/// a konst or proven string producer — e.g. the composite gmatch step's
/// `scap_str` — is nil-free statically and needs no pin), and the ctrl
/// slot inherits v1's ref (a pure ref move, like `.move`). An observed
/// nil (the loop's end) aborts: leaving the loop is not loop-body code —
/// the numeric `for_loop`'s exit-direction rule. At run time a
/// nil-producing iteration side-exits at the pin (or earlier, at the
/// composite step's negative status) and tier-0 replays the call,
/// produces the nil, and ends the loop itself. A BOOLEAN v1 aborts
/// fail-closed: `false` is non-nil (the loop continues) but no guard op
/// expresses "non-nil" without also pinning truthiness. No
/// `locals_watermark` here: generic-for keeps the maxInt sentinel (the
/// loop variables live below the call window and stay in the snapshot).
pub fn recTForLoop(self: *TraceState, instr: Instr, regs: RegWindow) !void {
    // Same cross-proto pc hazard as `recForLoop`: never process a
    // back-edge inside an inlined callee.
    if (self.rec.inline_depth > 0) return self.abort(.cross_frame);
    const a = instr.a;
    const v1 = regs.get(a + 3);
    if (v1.isNil()) return self.abort(.bad_type); // end direction
    // Pin the OLD ctrl (`a+2`) by observed type. The test block's
    // `move base+5 ← base+2` already materialized an UNGUARDED slot_load
    // of it (the arg-window copy the iterator may ignore), and an
    // unguarded slot_load has no provable kind — proveKinds would refuse
    // the whole trace for native. Unlike the v1 pin below this guard has
    // no loop semantics (any ctrl continues the loop); it exists purely so
    // the shuttle has a kind, so the policy differs at the edges:
    //   * nil → abort. Only reachable when recording starts at a loop
    //     instance's FIRST iteration (ctrl still the initial nil); the
    //     back-edge hotcount discipline starts recordings via the back
    //     edge (iteration ≥ 2), so this is a rare race, and a retry lands
    //     on a pinnable iteration — better than committing a trace that
    //     can never leave tier-1a.
    //   * bool / exotic heap → record UNPINNED. No guard op can pin them
    //     (no non-nil guard exists), the trace stays sound (native
    //     declines it; tier-1a executes it), and aborting forever would
    //     be strictly worse than tier-1a.
    const vc = regs.get(a + 2);
    if (vc.isNil()) return self.abort(.bad_type);
    const rc = try self.refOf(a + 2);
    if (self.konstValueOf(rc) == null and !self.isProvenStringRef(rc)) {
        if (vc.isNumber()) {
            try self.guardNum(rc, vc, .operand_type, .a);
        } else if (vc.isHeap()) {
            switch (vc.heapType()) {
                .string => self.stampProv(try self.emit(.{ .op = .guard_string, .a = rc }), .operand_type, .a, .neutral),
                .table => {
                    const ctbl = table_mod.Table.fromHeader(vc.asHeap());
                    if (ctbl.metatable == null)
                        self.stampProv(try self.emit(.{ .op = .guard_table, .a = rc }), .operand_type, .a, .neutral);
                    // metatable-bearing ctrl: leave unpinned (tier-1a).
                },
                else => {}, // exotic heap ctrl: leave unpinned (tier-1a).
            }
        }
        // bool ctrl: leave unpinned (tier-1a).
    }
    const r1 = try self.refOf(a + 3);
    if (self.konstValueOf(r1) == null and !self.isProvenStringRef(r1)) {
        if (v1.isNumber()) {
            try self.guardNum(r1, v1, .operand_type, .a);
        } else if (v1.isHeap()) switch (v1.heapType()) {
            .string => self.stampProv(try self.emit(.{ .op = .guard_string, .a = r1 }), .operand_type, .a, .neutral),
            .table => {
                const tbl = table_mod.Table.fromHeader(v1.asHeap());
                if (tbl.metatable != null) return self.abort(.has_metatable);
                self.stampProv(try self.emit(.{ .op = .guard_table, .a = r1 }), .operand_type, .a, .neutral);
            },
            else => return self.abort(.bad_type),
        } else return self.abort(.bad_type);
    }
    self.setReg(a + 2, r1); // publish ctrl = v1
}

pub fn recForLoop(self: *TraceState, instr: Instr, regs: RegWindow, pc: u32) !void {
    const a = instr.a;

    // If *this* `for_loop` is the one whose back-edge defines the trace
    // anchor (its target == anchor.pc, computed exactly as the interpreter's
    // `applyJump`), then the trace re-enters / resumes at this numeric-`for`'s
    // body start. Its four control regs occupy `a..a+3` (idx, limit, step,
    // var), so every slot `>= a+4` is a compiler temporary — dead at the body
    // start on every resume path and after the loop. Record the watermark so
    // `commit()` can drop those slots from the exit snapshot. A `for_loop` the
    // trace merely passes through (different target) is ignored.
    //
    // Guard with `inline_depth == 0`: at depth > 0 the `target` pc is in the
    // callee's proto, so `target == anchor.pc` is a cross-proto coincidence —
    // the watermark would corrupt the anchor frame's phi writeback. The callee's
    // locals are already excluded by `slot >= anchor_num_registers` in commit.
    const target: u32 = @intCast(@as(i64, pc) + instr.aux);
    if (self.rec.inline_depth == 0 and target == self.rec.anchor.pc)
        self.rec.locals_watermark = @as(u32, a) + 4;
    const vidx = regs.get(a);
    const vlimit = regs.get(a + 1);
    const vstep = regs.get(a + 2);
    if (!vidx.isNumber() or !vlimit.isNumber() or !vstep.isNumber()) return self.abort(.bad_type);
    const ridx = try self.refOf(a);
    const rlimit = try self.refOf(a + 1);
    const rstep = try self.refOf(a + 2);
    try self.guardNum(ridx, vidx, .operand_type, .a);
    try self.guardNum(rlimit, vlimit, .operand_type, .a1);
    try self.guardNum(rstep, vstep, .operand_type, .a2);

    // idx_next = idx + step
    const all_int = vidx.isInt() and vstep.isInt();
    const rnext = try self.emit(.{ .op = .add, .a = ridx, .b = rstep, .ty = if (all_int) .int else .float });

    // Float loop-limit specialization: when the index+step are int but the limit
    // is a **float** whose observed value is an exact integer, convert the
    // (loop-invariant) limit to an int once via `int_of_float`, so the body
    // compare is int-vs-int. tier-0 compares int-vs-float EXACTLY, and for an
    // integral limit `L` in i64 range `idx <= L ⟺ idx <= (i64)L` — so the trip
    // count and registers are byte-identical, while the native backend (which
    // bails on a mixed compare) can now lower it. A later non-integral limit
    // side-exits the op → tier-0 resumes the exact mixed compare. The `guard_float`
    // already emitted by `guardNum(rlimit, vlimit)` pins this trace to float-limit
    // entries. The limit is never written by the loop, so the exit snapshot is
    // unchanged. Only fires for an integral, in-range limit (else stays mixed,
    // bails to tier-1a as before).
    const rlimit_cmp = if (all_int and vlimit.isFloat() and value.floatAsExactInt(vlimit.asFloat()) != null) blk: {
        const iof = try self.emit(.{ .op = .int_of_float, .a = rlimit, .ty = .int });
        self.stampProv(iof, .limit_int, .a1, .neutral); // float-limit → int side-exit
        break :blk iof;
    } else rlimit;

    // loop continues while (ascending) idx_next <= limit, else limit <= idx_next.
    const ascending = vstep.toFloat() >= 0;
    const cmp = if (ascending)
        try self.emit(.{ .op = .le, .a = rnext, .b = rlimit_cmp, .ty = .boolean })
    else
        try self.emit(.{ .op = .le, .a = rlimit_cmp, .b = rnext, .ty = .boolean });

    // Polarity-aware continuation test (the zero-trip / loop-exit direction was
    // previously unrecordable — the recorder unconditionally asserted `guard_true`,
    // which contradicts the observed execution whenever tier-0 falls OUT of the
    // loop here, e.g. a `.side` recording of a skip-shaped iteration whose inner
    // loop zero-trips). Compute the observed decision with the SAME value-level
    // ops tier-0 uses (`arith.add`/`lt`/`le` on the runtime values), so the
    // recorded direction is byte-identical to the path tier-0 actually took —
    // a pure function of deterministic register values, identical in every
    // record/exec mode.
    const vnext = arith.add(vidx, vstep) catch return self.abort(.bad_type);
    const o_ascending = !(arith.lt(vstep, Value.int(0)) catch return self.abort(.bad_type));
    const within = if (o_ascending)
        arith.le(vnext, vlimit) catch return self.abort(.bad_type)
    else
        arith.le(vlimit, vnext) catch return self.abort(.bad_type);

    if (within) {
        // Loop-taken direction (the historical shape): assert the continue test,
        // publish the stepped index and the loop variable (R[a+3]). The
        // `guard_true` sourced at a `for_loop` is the loop-done guard — its
        // failure is the committed post-loop exit (isNumericForLoopDoneGuard).
        const done_g = try self.emit(.{ .op = .guard_true, .a = cmp });
        self.stampProv(done_g, .loop_done, .none, .neutral); // loop-continuation test
        self.setReg(a, rnext);
        self.setReg(a + 3, rnext);
    } else {
        // Loop-exit direction (zero-trip skip / final fall-out): assert the
        // continue test FAILED and keep recording straight-line past the loop.
        // tier-0 writes the stepped index back to R[a] but does NOT publish the
        // visible var R[a+3] on this path — mirror that exactly. A `guard_false`
        // here is an ORDINARY guard everywhere (loop-done machinery keys on
        // `guard_true`: isLoopDoneGuardIndex / isNumericForLoopDoneGuard /
        // irinterp all short-circuit on the op), so its failure deopts under the
        // H-1b re-execute convention — resume at the anchor with entry values,
        // tier-0 re-runs the iteration and takes the loop normally.
        const skip_g = try self.emit(.{ .op = .guard_false, .a = cmp });
        self.stampProv(skip_g, .loop_done, .none, .neutral); // loop-exit test
        self.setReg(a, rnext);
    }
}

/// `for_prep` (numeric-for entry): the nested-loop **trace-link** site (doc 15,
/// Phase 2 — the mahina analogue of LuaJIT's `rec_loop_jit` / `LJ_TRLINK_ROOT`).
///
/// A `for_prep` pre-decrements its index (`R[a] = init − step`) and jumps forward
/// to the matching `for_loop`, whose back-edge target is the loop body start —
/// which is exactly `for_prep`'s *post-increment* pc (`pc` here), so the inner
/// loop's **root-trace anchor pc == `pc`**. If a root trace is already cached
/// there, this recording (a continuation that fell out of the inner loop and
/// recorded the outer body forward) records the pre-decrement and **links** to
/// the inner root instead of recording the inner `for_loop`/unrolling. Otherwise
/// it aborts `.nyi_opcode` (LINNER): let the inner loop spawn its own root first.
/// The decision is a pure function of the cache + bytecode (no clock/RNG/address),
/// so it is identical across every record/exec mode — P1 carries to P2.
///
/// **P2 (the load-bearing hand-off invariant, doc 15).** The link hand-off must
/// reproduce the inner root's *entry state* — the tier-0 registers it reads at its
/// anchor (`entry_slots`). The inner root anchors at the loop **body start** (the
/// `for_loop` back-edge target), which tier-0 first reaches only AFTER `for_prep`
/// (`R[a] = init − step`) **and** the first `for_loop` (`R[a] += step → init`,
/// publishing the visible loop var `R[a+3] = init`). So the byte-identical hand-off
/// is `R[a] = init` **and** `R[a+3] = init` — the body reads the visible var
/// `R[a+3]` at the trace top, and the `for_loop` at the trace bottom reads `R[a]`
/// to step it, so BOTH are live entry inputs. (An earlier draft recorded only
/// `R[a] = init − step` and left `R[a+3]` stale — verified wrong by dumping the
/// inner root's `entry_slots`, which include the visible-var slot; the inner root
/// would then re-run the first iteration and read a stale loop var.) `R[a+1]`
/// (limit) / `R[a+2]` (step) are untouched by the loop and flow straight through.
/// A first-iteration bounds guard (`init` within `limit`) gates the link: a
/// zero-trip inner loop fails it and falls back to tier-0 rather than entering the
/// inner root, which assumes ≥1 iteration. Phase 3 consumes this snapshot to follow
/// the link through `driveChain`.
pub fn recForPrepLink(self: *TraceState, instr: Instr, regs: RegWindow, proto: *const Proto, pc: u32) !void {
    const a = instr.a;

    // Read + type-check the numeric-for control values up front (both directions
    // need them; tier-0 `for_prep` type-checks all three and raises TypeError on
    // a non-number, so a non-number is not a numeric `for` we model — abort).
    const vinit = regs.get(a);
    const vlimit = regs.get(a + 1);
    const vstep = regs.get(a + 2);
    if (!vinit.isNumber() or !vlimit.isNumber() or !vstep.isNumber()) return self.abort(.bad_type);

    // ZERO-TRIP RECORD-THROUGH. Decide which direction tier-0 is about to take,
    // with the SAME value-level ops it uses: `for_prep` computes `R[a] = init −
    // step`, jumps to the `for_loop`, which computes `(init − step) + step` and
    // compares against the limit (direction by step sign). Note `(init−step)+step`
    // is NOT always `init` for floats — compute it exactly, never shortcut.
    // The decision is a pure function of deterministic register values, so it is
    // identical in every record/exec mode.
    //
    // If the loop runs AND we are at depth 0, fall through to the `.link`
    // hand-off below. If it ZERO-TRIPS, the link is meaningless (the inner root
    // assumes ≥1 iteration) and force-closing with `.link` recorded the WRONG
    // shape — the duplicate-continuation bug that made the skip direction
    // unrecordable. Instead, record the `for_prep` as the plain arithmetic it is
    // (`R[a] = init − step`, operands type-guarded) and keep recording: tier-0
    // jumps to the `for_loop`, whose recorder mirror (`recForLoop`) now records
    // the observed loop-EXIT direction (`guard_false` on the continue test) and
    // continues straight-line past the loop. This is sound for every recording
    // kind — no link is taken, it is just straight-line code — so a `.root` may
    // record through a zero-tripping inner `for_prep` too.
    //
    // At `inline_depth > 0` the same record-through path handles BOTH zero-trip
    // AND running loops: the link path cannot work at depth > 0 (`driveChain`
    // resolves `link_target` in the anchor proto, not the callee's), so we record
    // the `for_prep` arithmetic and let `recForLoop` unroll the inner loop. The
    // trace specializes to the iteration count observed during recording; a
    // mismatch on replay deopts via `guard_true`/`guard_false` failure.
    {
        const pre = arith.sub(vinit, vstep) catch return self.abort(.bad_type);
        const vnext = arith.add(pre, vstep) catch return self.abort(.bad_type);
        const o_ascending = !(arith.lt(vstep, Value.int(0)) catch return self.abort(.bad_type));
        const within = if (o_ascending)
            arith.le(vnext, vlimit) catch return self.abort(.bad_type)
        else
            arith.le(vlimit, vnext) catch return self.abort(.bad_type);
        if (!within or self.rec.inline_depth > 0) {
            const rinit0 = try self.refOf(a);
            const rlimit0 = try self.refOf(a + 1);
            const rstep0 = try self.refOf(a + 2);
            try self.guardNum(rinit0, vinit, .operand_type, .a);
            try self.guardNum(rlimit0, vlimit, .operand_type, .a1);
            try self.guardNum(rstep0, vstep, .operand_type, .a2);
            const rsub = try self.emit(.{ .op = .sub, .a = rinit0, .b = rstep0, .ty = arithResultType(.sub, vinit, vstep) });
            self.setReg(a, rsub);
            return;
        }
    }

    // Only a *side* or *continuation* links (LuaJIT's model). A `.root` recording
    // that reaches an inner `for_prep` aborts LINNER — byte-identical to the
    // pre-Phase-2 behaviour — so it never anchors a link trace at a real
    // back-edge target.
    if (self.rec.kind == .root) return self.abort(.nyi_opcode);

    // Locate the matching `for_loop` (the forward jump target) and verify the
    // shape. `pc` is the post-increment pc, so `pc + instr.aux` is the `for_loop`
    // bytecode index (mirrors the interpreter's `applyJump(pc, aux)`), and that
    // `for_loop`'s back-edge target — the inner loop header / root anchor — is
    // `pc` itself (the instruction immediately after `for_prep`).
    const fl_i: i64 = @as(i64, pc) + instr.aux;
    if (fl_i < 0 or fl_i >= @as(i64, @intCast(proto.code.len))) return self.abort(.nyi_opcode);
    const fl_pc: u32 = @intCast(fl_i);
    if (proto.code[fl_pc].op != .for_loop) return self.abort(.nyi_opcode);
    const inner_anchor: u32 = pc; // body start == for_loop back-edge target
    // Cross-check the layout assumption: the `for_loop`'s own back-edge resolves
    // to `inner_anchor`. Treat a mismatch as an ordinary LINNER abort in release
    // builds too; otherwise a malformed bytecode shape could link to the wrong pc.
    if (@as(i64, @intCast(fl_pc)) + 1 + proto.code[fl_pc].aux != @as(i64, @intCast(inner_anchor)))
        return self.abort(.nyi_opcode);

    // LINNER (LuaJIT `rec_loop_jit`): only link if the inner loop header already
    // has a `.loop` root trace. Otherwise abort — the inner loop must trace as a
    // root first; once it does, a later continuation links here.
    const inner_key = AnchorKey{ .proto = proto, .pc = inner_anchor };
    if (self.findLoopTrace(inner_key.proto, inner_key.pc) == null) return self.abort(.nyi_opcode);

    // Reconstruct the inner root's entry state (discharges P2 — see the doc
    // comment). Guard init/limit/step are numbers (all three — tier-0 `for_prep`
    // type-checks `limit` too, so a non-number limit must side-exit here rather
    // than commit a bogus link); already checked at the top of this fn.
    const rinit = try self.refOf(a);
    const rlimit = try self.refOf(a + 1);
    const rstep = try self.refOf(a + 2);
    try self.guardNum(rinit, vinit, .operand_type, .a);
    try self.guardNum(rlimit, vlimit, .operand_type, .a1);
    try self.guardNum(rstep, vstep, .operand_type, .a2);

    // First-iteration bounds test, mirroring `recForLoop`'s compare (incl. the
    // float-limit → int specialization so a mixed int/float compare stays lowerable
    // and byte-identical to tier-0's `idx <= limit`). tier-0 computes `(init−step)
    // +step` and compares THAT — which is NOT always `init` for floats (e.g.
    // `init=1.0, step=1e16` → tier-0's first index is `0.0`, not `1.0`), so the
    // recorded IR must do the same `sub` then `add` and both compare and publish
    // the result. (An earlier revision compared/published `init` directly on the
    // "(init−step)+step = init" shortcut — codex-flagged BLOCKER: a float link
    // handed the inner root a first index tier-0 never produced. Ints wrap back
    // exactly, so this only ever differed for floats.) On failure the inner loop
    // runs zero times → side-exit to tier-0 instead of entering the inner root.
    const all_int = vinit.isInt() and vstep.isInt();
    const vpre = arith.sub(vinit, vstep) catch return self.abort(.bad_type);
    const rpre = try self.emit(.{ .op = .sub, .a = rinit, .b = rstep, .ty = arithResultType(.sub, vinit, vstep) });
    const rfirst = try self.emit(.{ .op = .add, .a = rpre, .b = rstep, .ty = arithResultType(.add, vpre, vstep) });
    const rlimit_cmp = if (all_int and vlimit.isFloat() and value.floatAsExactInt(vlimit.asFloat()) != null) blk: {
        const iof = try self.emit(.{ .op = .int_of_float, .a = rlimit, .ty = .int });
        self.stampProv(iof, .limit_int, .a1, .neutral);
        break :blk iof;
    } else rlimit;
    const ascending = vstep.toFloat() >= 0;
    const cmp = if (ascending)
        try self.emit(.{ .op = .le, .a = rfirst, .b = rlimit_cmp, .ty = .boolean })
    else
        try self.emit(.{ .op = .le, .a = rlimit_cmp, .b = rfirst, .ty = .boolean });
    self.stampProv(try self.emit(.{ .op = .guard_true, .a = cmp }), .loop_done, .none, .neutral);

    // Publish the inner root's entry state: the control index `R[a]` and the
    // visible loop var `R[a+3]` both hold tier-0's first index `(init−step)+step`.
    // (limit `R[a+1]` / step `R[a+2]` are untouched by the loop and flow through
    // the exit snapshot.)
    self.setReg(a, rfirst);
    self.setReg(a + 3, rfirst);

    // Close with the `.link` terminator (commit reads `link_target`). closeTrace
    // commits + clears `active`; a build failure gates the anchor, like any abort.
    // A-i.4: stamp the `.link` terminal's provenance (edge 2). `for_prep` is the
    // owning guest opcode, so `source_pc = pc − 1` (= `cur_pc − 1`, this recorded
    // op), and `inline_depth == 0` here (the guard at the top of this fn aborts any
    // inlined `for_prep`), so the path prefix is empty. Set together with
    // `link_target` so the commit-time ⇔ invariant holds by construction.
    self.rec.link_target = inner_anchor;
    self.rec.pending_link_provenance = .{ .link_terminal = .{
        .path = pathFromFrames(&self.rec.frames, self.rec.inline_depth),
        .inline_depth = self.rec.inline_depth,
        .source_proto_id = self.rec.cur_proto_id,
        .source_pc = self.rec.cur_pc -| 1,
    } };
    self.closeTrace(regs);
}

/// Doc 38 — while-inner nested-loop linking. Extends the doc 15 linking
/// machinery to `while` loops, whose bytecode structure is
/// `<cmp>; jmp_if_false <past_end>; <body>; jmp <back_to_cmp>`.
///
/// When a continuation/side recording encounters a backward `jmp` whose
/// target already has a `.loop` root trace (the inner while-loop root),
/// this function closes the recording with a `.link` terminal to that root
/// — exactly the numeric-for pattern from `recForPrepLink`, but simpler:
/// no pre-decrement arithmetic and no explicit bounds guard (the inner
/// root's own condition-prefix guard handles zero-trip).
///
/// Root recordings abort LINNER (matching `recForPrepLink` and LuaJIT's
/// `rec_loop_jit` root gate): the inner loop must spawn its own root
/// first.
///
/// Forward jumps, self-anchor jumps, OOB jumps, and jumps at inline
/// depth > 0 are silently ignored (the `.jmp` stays a no-op and the
/// recording unrolls the while body as before).
pub fn recWhileLink(self: *TraceState, instr: Instr, regs: RegWindow, proto: *const Proto, pc: u32) !void {
    // Compute the jump target in signed arithmetic, matching `applyJump`.
    // `pc` is the post-increment cursor (the instruction AFTER this `jmp`),
    // so `pc + aux` gives the jump destination.
    const target_i: i64 = @as(i64, pc) + instr.aux;
    if (target_i < 0 or target_i >= @as(i64, @intCast(proto.code.len))) return; // OOB → no-op
    const target: u32 = @intCast(target_i);

    // Only backward jumps are while-loop re-entries. Forward jumps (break,
    // goto, if-skip) are straight-line in the trace.
    if (target >= pc) return;

    // If this jump targets our own anchor, `maybeCloseAtAnchor` (called
    // before the mirror) or `onBackEdge` already closed the trace. This is
    // a safety net — in practice we shouldn't reach here for our own anchor.
    // Compare the full (proto, pc) pair, not just pc, to be future-proof.
    if (self.rec.anchor.proto == proto and target == self.rec.anchor.pc) return;

    // Links at inline depth > 0 can't work: `driveChain` resolves
    // `link_target` in the anchor proto, not the callee's. Same constraint
    // as `recForPrepLink`.
    if (self.rec.inline_depth > 0) return;

    // Root recordings abort LINNER — REGARDLESS of whether the inner while
    // has a root yet (LuaJIT `rec_loop_interp`: entering an inner loop in a
    // root aborts so the inner loop traces FIRST; making it conditional on
    // an existing inner root made the outcome a recording race). The
    // continuation machinery then owns the nest: the inner root's loop-done
    // exits arm a continuation at the post-loop pc (`maybeArmContinuation`,
    // doc 38), which records the outer body and links back here. Unrolling
    // instead would commit a trip-count-pinned trace that thrashes on trip
    // variance AND clogs the anchor's trace population.
    //
    // Escape hatch (LuaJIT `innerloopleft`): an inner anchor that
    // repeatedly failed to loop back (`loop_leave` aborts exhausting the
    // fast-retry budget — reason-specific, exactly like LuaJIT keys its
    // check on LLEAVE/LINNER penalties) has a low/zero remaining-trip
    // pattern; a root may then unroll it, which is strictly better than
    // both sides backing off forever. Deterministic — a pure abort count.
    if (self.rec.kind == .root) {
        // innerloopleft: an inner that PROVED it cannot root (LLEAVE budget
        // exhausted) can only ever be unrolled — no evidence overrides this.
        if (self.lleave_count.get(.{ .proto = proto, .pc = target })) |n| {
            if (n >= self.config.lleave_fast_retries) {
                self.rec.unrolled_while = true;
                return; // unroll
            }
        }
        // Unroll-first (doc 38 revision — LuaJIT's innerloopleft mirrored):
        // mahina's decomposed inner-root+link pays a runtime re-entry per
        // inner completion (exits are not patched branches), so unrolling
        // into the outer root wins whenever sibling coverage can absorb the
        // trip variance (measured: ~17 vs ~95 native cyc/it on a bounded-
        // variance nest). Only an outer anchor with PROVEN unroll failure
        // (`unroll_fail` >= flip: unrolling recordings aborted, or
        // committed unrolled roots thrash-gated) decomposes via LINNER.
        const fails = self.unroll_fail.get(self.rec.anchor) orelse 0;
        if (fails < self.config.unroll_fail_flip) {
            self.rec.unrolled_while = true;
            return; // unroll
        }
        return self.abort(.nyi_opcode); // LINNER → inner root + link
    }

    // Side/continuation recordings: no inner root yet → no-op (the historical
    // straight-line unroll). The inner while warms up via `onBackEdge` and
    // spawns its own root; a later continuation then links here.
    if (self.findLoopTrace(proto, target) == null) return;

    // Close with a `.link` terminal to the inner while root. The φ writeback
    // in `commit()` ensures all modified slots are flushed; unmodified slots
    // remain coherent in the physical register file.
    self.rec.link_target = target;
    self.rec.pending_link_provenance = .{ .link_terminal = .{
        .path = pathFromFrames(&self.rec.frames, self.rec.inline_depth),
        .inline_depth = self.rec.inline_depth,
        .source_proto_id = self.rec.cur_proto_id,
        .source_pc = self.rec.cur_pc -| 1,
    } };
    self.closeTrace(regs);
}

/// Cross-frame tracing — inline a Lua callee's body straight into the trace
/// (LuaJIT's `lj_record_call`). The dispatch loop keeps driving the recorder
/// through the callee's bytecode after tier-0 pushes the frame, so all this
/// does is: (1) emit a `guard_func` pinning the runtime callee to the recorded
/// `Proto.id` (fails closed → deopt to tier-0, which really calls it); (2)
/// **S1**-seed every callee slot `.def` so no callee index is ever read
/// `.undef` (which would emit an OOB `slot_load`); (3) push a recorder frame and
/// shift `base_off` into the callee window. The call's frame-push / param-copy /
/// pop never executes on the trace — callee slots are pure internal SSA
/// temporaries on the single anchor `RegWindow` (see the safety rails, doc 10).
///
/// Aborts cleanly (tier-0 owns the loop) on every shape we don't inline:
/// a host (`native`) callee is a trace barrier; a non-callable / `__call`
/// metamethod, a vararg callee, and exceeding `MAX_INLINE_DEPTH` or the
/// `reg_map` reservation all abort. Dynamic multret windows (doc 27) no
/// longer abort per se: an `all_results` ARGUMENT window resolves its fixed
/// count against the recorder's multret shadow (`multret`, set by the
/// immediately-preceding recorded producer — fails closed on `null`), and an
/// `all_results` RESULT window stores the sentinel in `ret_count` verbatim,
/// resolved by `recReturn` once the callee's `ret` fixes `produced`.
pub fn recCall(self: *TraceState, instr: Instr, regs: RegWindow, proto: *const Proto, multret: ?u32) !void {
    const callee = regs.get(instr.a);
    if (!callee.isHeap()) return self.abort(.cross_frame);
    switch (callee.heapType()) {
        // A host call crosses the embedding boundary — heap effects we can't
        // model on the trace — UNLESS the native carries a `RecordedBuiltin`
        // tag, i.e. the recorder knows how to record its calls (doc 23:
        // fold-to-konst, reuse of the index shapes, or a leaf op/callout).
        // Anything untagged stays the host barrier.
        .native => {
            const nat = function.Native.fromHeader(callee.asHeap());
            if (nat.recorded) |rb| return self.recBuiltin(rb, instr, regs, multret);
            return self.abort(.host_barrier);
        },
        .function => {},
        // `__call` on a table/userdata, or anything else callable only via a
        // metamethod, is not a plain Lua-closure call. Not inlined.
        else => return self.abort(.cross_frame),
    }
    // Doc 27 D3: a dynamic argument window resolves against the multret
    // shadow — `top - (a + 1)`, the same arithmetic tier-0 runs against
    // `reg_top` (`interp.zig` `.call`), in recorder frame-space (producer and
    // consumer always share a frame, so `base` never enters). All arithmetic
    // in u32 and fail-closed below the `all_results` sentinel (§3a). A
    // dynamic RESULT window needs nothing here: `ret_count = instr.c` stores
    // the sentinel verbatim and `recReturn` resolves it (D4).
    const nargs: u32 = if (instr.b == bytecode.all_results) blk: {
        const top = multret orelse return self.abort(.cross_frame);
        const first_arg = @as(u32, instr.a) + 1;
        if (top < first_arg) return self.abort(.cross_frame);
        const n = top - first_arg;
        if (n >= bytecode.all_results) return self.abort(.cross_frame);
        break :blk n;
    } else instr.b;

    const cl = function.Closure.fromHeader(callee.asHeap());
    const cp = cl.proto;
    // Loaded (`load`/`require`) callees inline like static ones (doc 19): their
    // proto constants are rooted VM-lifetime via `loaded_chunks` in both root
    // walks, so a trace konst over them is always redundant — the H-2
    // sole-root hazard that used to force an abort here is unreachable.
    // A vararg callee's extra-args frame cursor isn't modelled on the trace.
    if (cp.is_vararg) return self.abort(.cross_frame);
    if (self.rec.inline_depth >= MAX_INLINE_DEPTH) return self.abort(.too_deep);

    // Callee window starts `caller_proto.num_registers` above the current
    // frame's base — exactly tier-0's `callee_base = base + caller.num_registers`,
    // in the recorder's anchor-relative `base_off` space. `proto` here is the
    // *caller* proto (the frame the `.call` executes in).
    const callee_base_off: u32 = self.rec.base_off + proto.num_registers;
    if (@as(usize, callee_base_off) + cp.num_registers > self.rec.reg_map.len)
        return self.abort(.frame_bounds);

    // (1) guard_func: pin the runtime callee to this proto's stable id. `aux`
    // carries `Proto.id` (a `u32`, NOT a pointer — pointers change across a
    // keyframe restore and would break replay). Fails closed in the executor.
    const callee_ref = try self.refOf(instr.a);
    self.stampProv(try self.emit(.{ .op = .guard_func, .a = callee_ref, .aux = @bitCast(cp.id) }), .callee_identity, .a, .neutral);

    // (2) S1: seed every callee slot `.def`. Param slots (`i < num_params` and
    // an arg was actually passed) take the caller arg's SSA ref; everything else
    // is `nil`, matching tier-0's nil-fill of an unset register. After this no
    // callee slot is `.undef`, so `refOf` never emits a `slot_load` on a callee
    // index (which would be an out-of-window trace input). `nargs` was resolved
    // above (fixed, or doc 27's shadow resolution of `all_results`).
    var i: u16 = 0;
    while (i < cp.num_registers) : (i += 1) {
        const seed: Ref = if (i < cp.num_params and i < nargs)
            try self.refOf(@intCast(@as(usize, instr.a) + 1 + i))
        else
            try self.konst(Value.nil());
        // Whole-RegSlot write → `defineSlotAbs` (doc 39: preserves
        // `entry_kind`; a callee index is >= anchor_num_registers so the
        // peel-rebound branch never fires here, but the funnel keeps every
        // define on one audited path).
        self.defineSlotAbs(callee_base_off + i, seed);
    }

    // (3) push the recorder frame and descend into the callee window. Record the
    // inline call edge (A-i.2): `proto` is the caller here, and `cur_pc` is the
    // `.call`'s post-increment PC, so the source `.call` opcode is at `cur_pc − 1`.
    self.rec.frames[self.rec.inline_depth] = .{
        .base_off = self.rec.base_off,
        .ret_dest = instr.a,
        .ret_count = instr.c,
        .caller_proto_id = proto.id,
        .call_pc = self.rec.cur_pc - 1,
    };
    self.rec.inline_depth += 1;
    self.rec.base_off = callee_base_off;
}

/// Dispatch a `.call` whose callee is a `RecordedBuiltin`-tagged native to
/// its per-builtin recorder arm (doc 23 D1 — mahina's `recff_idmap`). The
/// common preamble here rejects dynamic windows once; each arm owns its own
/// arity (`instr.b`), result-count (`instr.c`), and observed-shape abort
/// matrix. Arms whose recorder has not landed yet abort `.host_barrier`,
/// byte-identical to the untagged path — a registry row only gains its
/// `.recorded` tag together with its arm, so those prongs are unreachable
/// until then and exist to keep the switch exhaustive as the enum grows.
pub fn recBuiltin(self: *TraceState, rb: function.RecordedBuiltin, instr: Instr, regs: RegWindow, multret: ?u32) !void {
    // Doc 27: dynamic multret windows resolve here instead of aborting.
    //
    // Consumer half (D2, `b == all_results`): the actual argument count is
    // `top - (a + 1)` against the multret shadow — the identical arithmetic
    // tier-0 runs against `reg_top`, in recorder frame-space. Fails closed on
    // a `null` shadow (vararg spreads, recordings starting at a consumer) and
    // on any count not representable below the sentinel (§3a, u32 math).
    //
    // Producer half (D1, `c == all_results`): only structurally single-result
    // builtins qualify — tier-0's `all` path calls `nat.func` and
    // `stampSingleResult` (exactly one value) for every recorded builtin
    // WITHOUT a `.multi` projection. `codepoint`/`select` have one (can
    // produce ≠1 values) and stay barriers. The arm itself records under an
    // effective `c = 1` (the exact mirror of `stampSingleResult`'s one-value
    // write); the shadow publishes after the arm succeeds.
    //
    // Both flags are captured BEFORE the effective-instr rewrite (§3b): the
    // middle call of `f(g(h()))` is consumer AND producer at once, and the
    // rewrite destroys both sentinels.
    const was_dynamic_c = instr.c == bytecode.all_results;
    var eff = instr;
    if (instr.b == bytecode.all_results) {
        const top = multret orelse return self.abort(.cross_frame);
        const first_arg = @as(u32, instr.a) + 1;
        if (top < first_arg) return self.abort(.cross_frame);
        const nargs = top - first_arg;
        if (nargs >= bytecode.all_results) return self.abort(.cross_frame);
        eff.b = @intCast(nargs);
    }
    if (was_dynamic_c) {
        switch (rb) {
            // Doc 30 §5: find/match/gmatch_iter join the D1 EXCLUDED list
            // in v1 — the producer shadow would need the census count.
            .codepoint, .select, .find, .match, .gmatch_iter => return self.abort(.cross_frame),
            else => {},
        }
        eff.c = 1;
    }
    switch (rb) {
        .sqrt => try self.recPureSqrt(eff, regs),
        .type => try self.recBType(eff, regs),
        .tostring => try self.recBTostring(eff, regs),
        .tonumber => try self.recBTonumber(eff, regs),
        .select => try self.recBSelect(eff),
        .rawequal => try self.recBRawequal(eff, regs),
        .rawlen => try self.recBRawlen(eff, regs),
        .rawget => try self.recBRawget(eff, regs),
        .rawset => try self.recBRawset(eff, regs),
        .sin => try self.recFloatUnary(eff, regs, .sin, .fsin),
        .cos => try self.recFloatUnary(eff, regs, .cos, .fcos),
        .mtype => try self.recBMType(eff, regs),
        .len => try self.recBSLen(eff, regs),
        .sub => try self.recBSSub(eff, regs),
        .reverse => try self.recBSRev(eff, regs),
        .char => try self.recBSChar1(eff, regs),
        .rep => try self.recBSRep2(eff, regs),
        .upper => try self.recBSCase(eff, regs, .upper, .supper),
        .lower => try self.recBSCase(eff, regs, .lower, .slower),
        .codepoint => try self.recBSCodepoint(eff, regs),
        .find => try self.recBSFind(eff, regs),
        .match => try self.recBSMatch(eff, regs),
        .gmatch_iter => try self.recBSGmatchIter(eff, regs),
        .floor => try self.recFloorCeil(eff, regs, .floor, .ffloor),
        .ceil => try self.recFloorCeil(eff, regs, .ceil, .fceil),
    }
    // D1 publish — only a LIVE recording may leave a shadow (an aborting arm
    // set `rec.active = false`; §3a truthfulness: set only by a successfully
    // recorded producer).
    if (was_dynamic_c and self.rec.active)
        self.rec.multret_top = @as(u32, eff.a) + 1;
}

/// `math.type(v)` — konst fold under the same pins as `type()` (doc 24
/// ride-along): a numeric argument's `guardNum` pin decides
/// "integer"/"float" (the pin is exactly the query!), a pinned
/// table/native/closure folds `nil` (Value.nil needs no interning), and
/// the pin-less observations (string/nil/bool non-konst) abort as in
/// `recBType`. Never allocates: string results via `foldInternedStr`.
pub fn recBMType(self: *TraceState, instr: Instr, regs: RegWindow) !void {
    if (instr.b != 1) return self.abort(.cross_frame);
    if (instr.c != 1) return self.abort(.cross_frame);
    try self.guardBuiltinCallee(instr.a, .mtype);
    const arg_slot: u16 = @intCast(@as(usize, instr.a) + 1);
    const argv = regs.get(arg_slot);
    const arg_ref = try self.refOf(arg_slot);
    if (self.konstValueOf(arg_ref) == null) {
        if (argv.isNumber()) {
            try self.guardNum(arg_ref, argv, .operand_type, .a1);
        } else if (argv.isHeap()) switch (argv.heapType()) {
            .table => {
                const tbl = table_mod.Table.fromHeader(argv.asHeap());
                if (tbl.metatable != null) return self.abort(.has_metatable);
                self.stampProv(try self.emit(.{ .op = .guard_table, .a = arg_ref }), .operand_type, .a1, .neutral);
            },
            .native => {
                const nat = function.Native.fromHeader(argv.asHeap());
                const tag = nat.recorded orelse return self.abort(.bad_type);
                try self.guardBuiltinCallee(arg_slot, tag);
            },
            .function => {
                const cl = function.Closure.fromHeader(argv.asHeap());
                if (!self.rec.guarded_refs.contains(arg_ref)) {
                    try self.rec.guarded_refs.put(self.gpa, arg_ref, {});
                    self.stampProv(try self.emit(.{ .op = .guard_func, .a = arg_ref, .aux = @bitCast(cl.proto.id) }), .callee_identity, .a1, .neutral);
                }
            },
            else => return self.abort(.bad_type),
        } else return self.abort(.bad_type);
    }
    if (!self.isRecording()) return;
    if (argv.isInt()) {
        const r = (try self.foldInternedStr("integer")) orelse return self.abort(.bad_type);
        self.setReg(instr.a, r);
    } else if (argv.isFloat()) {
        const r = (try self.foldInternedStr("float")) orelse return self.abort(.bad_type);
        self.setReg(instr.a, r);
    } else {
        self.setReg(instr.a, try self.konst(Value.nil()));
    }
}

// --- doc 23 D2: fold-to-konst builtin arms -----------------------------
//
// Shared discipline: the recorder runs BEFORE tier-0 executes the call, so a
// fold may never allocate a guest heap object — interned-string results go
// through `foldInternedStr` (read-only lookup, abort on miss; in steady state
// the hot-count threshold guarantees prior tier-0 iterations interned them).
// Guards follow the house rules: numeric pins via the *registered* `guardNum`
// (`guarded_refs` holds only numeric guards), heap-shape pins (`guard_table`,
// `guard_func`) emitted raw and deduped by CSE, builtin identity via
// `guardBuiltinCallee` (disjoint use of the registered set — a native-valued
// ref never carries a numeric guard).

/// The `Value` behind `ref` iff `ref` is a trace konst (else null). The
/// fold arms use this to recognize compile-time-constant arguments, whose
/// identity needs no runtime guard (konst refs are literals by construction).
pub fn konstValueOf(self: *const TraceState, ref: Ref) ?Value {
    const ins = self.rec.instrs.items[@intCast(ref)];
    if (ins.op != .konst) return null;
    return self.rec.consts.items[@intCast(ins.aux)];
}

/// Fold an interned-string result: konst ref for `bytes`'s already-interned
/// string, or null when it is not interned yet or no heap channel exists
/// (bare test harness) — callers abort `.bad_type` and recording retries
/// later, by which time tier-0 has interned the value. NEVER interns.
pub fn foldInternedStr(self: *TraceState, bytes: []const u8) !?Ref {
    const heap = self.rec_heap orelse return null;
    const s = heap.internedLookup(bytes) orelse return null;
    return try self.konst(Value.heap(&s.header));
}

/// `type(v)` — the result is a constant type-name string once the argument's
/// runtime type is pinned (doc 23 D2 table). Number/table/recorded-native/
/// closure observations pin with existing guards; string/nil/bool have no
/// guard vocabulary and abort (tier-0 owns them until a consumer justifies
/// new guards). The pins are deliberately *stronger* than `type()` needs
/// (`guardNum` pins int-vs-float; `guard_table` also demands no metatable;
/// `guard_func` pins the exact proto) — a drifting argument deopts and
/// re-records, which is conservative, never wrong.
pub fn recBType(self: *TraceState, instr: Instr, regs: RegWindow) !void {
    if (instr.b != 1) return self.abort(.cross_frame);
    if (instr.c != 1) return self.abort(.cross_frame);
    try self.guardBuiltinCallee(instr.a, .type);
    const arg_slot: u16 = @intCast(@as(usize, instr.a) + 1);
    const argv = regs.get(arg_slot);
    const arg_ref = try self.refOf(arg_slot);
    if (self.konstValueOf(arg_ref) == null) {
        if (argv.isNumber()) {
            try self.guardNum(arg_ref, argv, .operand_type, .a1);
        } else if (argv.isHeap()) switch (argv.heapType()) {
            .table => {
                const tbl = table_mod.Table.fromHeader(argv.asHeap());
                if (tbl.metatable != null) return self.abort(.has_metatable);
                self.stampProv(try self.emit(.{ .op = .guard_table, .a = arg_ref }), .operand_type, .a1, .neutral);
            },
            .native => {
                const nat = function.Native.fromHeader(argv.asHeap());
                const tag = nat.recorded orelse return self.abort(.bad_type);
                try self.guardBuiltinCallee(arg_slot, tag);
            },
            .function => {
                const cl = function.Closure.fromHeader(argv.asHeap());
                if (!self.rec.guarded_refs.contains(arg_ref)) {
                    try self.rec.guarded_refs.put(self.gpa, arg_ref, {});
                    self.stampProv(try self.emit(.{ .op = .guard_func, .a = arg_ref, .aux = @bitCast(cl.proto.id) }), .callee_identity, .a1, .neutral);
                }
            },
            else => return self.abort(.bad_type),
        } else return self.abort(.bad_type);
    }
    const kref = (try self.foldInternedStr(argv.typeName())) orelse return self.abort(.bad_type);
    self.setReg(instr.a, kref);
}

/// `tostring(v)` — two recorded shapes:
///
/// **Konst fold (arc A / doc 23).** Only non-heap konsts fold:
/// numbers/bools/nil can never carry a metatable (`Vm.metatableOf` returns
/// null for every non-heap value), so the `__tostring` metacall tier-0's
/// `bToString` probes first is statically impossible and the scalar
/// rendering is the whole story. A konst *string* does NOT fold: strings
/// share the mutable built-in string metatable, so a runtime `__tostring`
/// could appear with no guard to catch it. The rendering goes through
/// `io.writeValue` — the exact renderer `bToString` uses — into a bounded
/// stack buffer, then a read-only lookup.
///
/// **Allocating producer (arc B / doc 24).** A non-konst observed
/// int/float pins with `guardNum` (int-vs-float — the pin selects the op)
/// and records `tostr_int`/`tostr_num` through `emitAlloc` (which arms the
/// body's `guard_gc` budget guard). The `__tostring` impossibility argument
/// is the same (the guard proves non-heap). Everything else (observed
/// strings/bools/nil/heap) stays a tier-0 barrier.
pub fn recBTostring(self: *TraceState, instr: Instr, regs: RegWindow) !void {
    if (instr.b != 1) return self.abort(.cross_frame);
    if (instr.c != 1) return self.abort(.cross_frame);
    const arg_slot: u16 = @intCast(@as(usize, instr.a) + 1);
    const arg_ref = try self.refOf(arg_slot);
    if (self.konstValueOf(arg_ref)) |kv| {
        if (kv.isHeap()) return self.abort(.bad_type);
        try self.guardBuiltinCallee(instr.a, .tostring);
        var buf: [128]u8 = undefined;
        var w = io.Writer.fixed(&buf);
        io.writeValue(&w, kv) catch unreachable; // scalars render in <32 bytes
        const kref = (try self.foldInternedStr(w.buffered())) orelse return self.abort(.bad_type);
        self.setReg(instr.a, kref);
        return;
    }
    const argv = regs.get(arg_slot);
    if (!argv.isNumber()) return self.abort(.bad_type);
    try self.guardBuiltinCallee(instr.a, .tostring);
    try self.guardNum(arg_ref, argv, .operand_type, .a1);
    const op: IrOp = if (argv.isInt()) .tostr_int else .tostr_num;
    const r = try self.emitAlloc(.{ .op = op, .a = arg_ref, .ty = .heap });
    self.setReg(instr.a, r);
}

/// Is `r`'s producer an op whose result is a PROVEN string (needs no
/// `guard_string`)? The tostr/snew producers stamp `ty = .heap` with
/// string-typed results by construction.
pub fn isProvenStringRef(self: *const TraceState, r: Ref) bool {
    return switch (self.rec.instrs.items[@intCast(r)].op) {
        .tostr_int, .tostr_num, .ssub, .srev, .schar1, .srep2, .supper, .slower => true,
        // Doc 30: an interned capture span is a string by construction.
        .scap_str => true,
        else => false,
    };
}

/// Resolve a builtin STRING argument (doc 24 c3): a konst interned string
/// or a proven producer passes ref-through; an observed string gets a
/// `guard_string` pin; anything else aborts (tier-0 owns coercions and
/// error raising). Returns the operand ref.
/// Null = the recording was aborted (`abort` flags it; the caller must
/// return without emitting) — the house `!?Ref` convention: `abort()`
/// itself is not an error, allocator failures still propagate as errors.
pub fn stringArgRef(self: *TraceState, arg_slot: u16, regs: RegWindow, operand: OperandDesig) !?Ref {
    const r = try self.refOf(arg_slot);
    if (self.konstValueOf(r)) |kv| {
        if (!kv.isHeap() or kv.heapType() != .string) {
            self.abort(.bad_type);
            return null;
        }
        return r;
    }
    if (self.isProvenStringRef(r)) return r;
    const v = regs.get(arg_slot);
    if (!v.isHeap() or v.heapType() != .string) {
        self.abort(.bad_type);
        return null;
    }
    // tropt's GuardKey dedup drops an exact duplicate pin.
    self.stampProv(try self.emit(.{ .op = .guard_string, .a = r }), .operand_type, operand, .neutral);
    return r;
}

/// Resolve a builtin INT argument: konst int passes through; an observed
/// int gets a `guard_int` pin; float/other aborts (tier-0 owns the
/// integral-float coercion these builtins perform — recording it would
/// need an `int_of_float` shape no string bench exercises).
/// Null = aborted (see `stringArgRef`).
pub fn intArgRef(self: *TraceState, arg_slot: u16, regs: RegWindow, operand: OperandDesig) !?Ref {
    const r = try self.refOf(arg_slot);
    if (self.konstValueOf(r)) |kv| {
        if (!kv.isInt()) {
            self.abort(.bad_type);
            return null;
        }
        return r;
    }
    if (!regs.get(arg_slot).isInt()) {
        self.abort(.bad_type);
        return null;
    }
    try self.guard(r, .guard_int, .operand_type, operand);
    return r;
}

/// `string.len(s)` — non-allocating: the `#s` shape under `guard_builtin`.
/// Konst string folds to a `cp_len` konst (code points — NOT `rawlen`'s
/// byte length); otherwise `slen` on the proven/guarded ref.
pub fn recBSLen(self: *TraceState, instr: Instr, regs: RegWindow) !void {
    if (instr.b != 1) return self.abort(.cross_frame);
    if (instr.c != 1) return self.abort(.cross_frame);
    try self.guardBuiltinCallee(instr.a, .len);
    const arg_slot: u16 = @intCast(@as(usize, instr.a) + 1);
    const r = try self.refOf(arg_slot);
    if (self.konstValueOf(r)) |kv| {
        if (!kv.isHeap() or kv.heapType() != .string) return self.abort(.bad_type);
        const str = string_mod.String.fromHeader(kv.asHeap());
        self.setReg(instr.a, try self.konst(Value.int(@intCast(str.cp_len))));
        return;
    }
    const sref = (try self.stringArgRef(arg_slot, regs, .a1)) orelse return;
    self.setReg(instr.a, try self.emit(.{ .op = .slen, .a = sref, .ty = .int }));
}

/// `string.sub(s, i[, j])` → `ssub` (snew class). The 2-arg shape records
/// its default `j = -1` as a konst — same value tier-0 defaults to — so
/// both shapes share one op. The third operand rides `aux` as a ref
/// (codex #4); clamping semantics mean the op itself never errors.
pub fn recBSSub(self: *TraceState, instr: Instr, regs: RegWindow) !void {
    if (instr.b != 2 and instr.b != 3) return self.abort(.cross_frame);
    if (instr.c != 1) return self.abort(.cross_frame);
    try self.guardBuiltinCallee(instr.a, .sub);
    const base: usize = instr.a;
    const sref = (try self.stringArgRef(@intCast(base + 1), regs, .a1)) orelse return;
    const iref = (try self.intArgRef(@intCast(base + 2), regs, .a2)) orelse return;
    const jref: Ref = if (instr.b == 3)
        (try self.intArgRef(@intCast(base + 3), regs, .a3)) orelse return
    else
        try self.konst(Value.int(-1));
    const r = try self.emitAlloc(.{ .op = .ssub, .a = sref, .b = iref, .aux = @intCast(jref), .ty = .heap });
    self.setReg(instr.a, r);
}

/// `string.reverse(s)` → `srev` (snew class).
pub fn recBSRev(self: *TraceState, instr: Instr, regs: RegWindow) !void {
    if (instr.b != 1) return self.abort(.cross_frame);
    if (instr.c != 1) return self.abort(.cross_frame);
    try self.guardBuiltinCallee(instr.a, .reverse);
    const sref = (try self.stringArgRef(@intCast(@as(usize, instr.a) + 1), regs, .a1)) orelse return;
    self.setReg(instr.a, try self.emitAlloc(.{ .op = .srev, .a = sref, .ty = .heap }));
}

/// 1-argument `string.char(c)` → `schar1`. The variadic shape aborts
/// (`IrInstr` carries no operand vector — codex #4). Range failure is a
/// side-exit at run time, not a record-time concern.
pub fn recBSChar1(self: *TraceState, instr: Instr, regs: RegWindow) !void {
    if (instr.b != 1) return self.abort(.cross_frame);
    if (instr.c != 1) return self.abort(.cross_frame);
    try self.guardBuiltinCallee(instr.a, .char);
    const cref = (try self.intArgRef(@intCast(@as(usize, instr.a) + 1), regs, .a1)) orelse return;
    self.setReg(instr.a, try self.emitAlloc(.{ .op = .schar1, .a = cref, .ty = .heap }));
}

/// 2-argument `string.rep(s, n)` → `srep2`. A separator argument aborts
/// (pinned arity, codex #4) — tier-0 owns the 3-arg shape.
pub fn recBSRep2(self: *TraceState, instr: Instr, regs: RegWindow) !void {
    if (instr.b != 2) return self.abort(.cross_frame);
    if (instr.c != 1) return self.abort(.cross_frame);
    try self.guardBuiltinCallee(instr.a, .rep);
    const base: usize = instr.a;
    const sref = (try self.stringArgRef(@intCast(base + 1), regs, .a1)) orelse return;
    const nref = (try self.intArgRef(@intCast(base + 2), regs, .a2)) orelse return;
    self.setReg(instr.a, try self.emitAlloc(.{ .op = .srep2, .a = sref, .b = nref, .ty = .heap }));
}

/// `string.upper(s)` / `string.lower(s)` → `supper`/`slower` (doc 26 D2,
/// snew class — one arm, two ops). The recording is only reachable because
/// tier-0 is executing the very call being mirrored, which commits the
/// session's Unicode-version pin (or raises — D1a then kills this
/// recording), so the on-trace op is heap-only. No konst fold: a fold
/// would intern a derived string into the konst pool at record time; the
/// konst ref passes through and the op's repeat is an intern hit.
pub fn recBSCase(self: *TraceState, instr: Instr, regs: RegWindow, rb: function.RecordedBuiltin, op: IrOp) !void {
    if (instr.b != 1) return self.abort(.cross_frame);
    if (instr.c != 1) return self.abort(.cross_frame);
    try self.guardBuiltinCallee(instr.a, rb);
    const sref = (try self.stringArgRef(@intCast(@as(usize, instr.a) + 1), regs, .a1)) orelse return;
    self.setReg(instr.a, try self.emitAlloc(.{ .op = op, .a = sref, .ty = .heap }));
}

/// Single-result `string.codepoint(s [, i [, j]])` → `scp` (doc 26 D3).
/// Pure, non-allocating (plain `emit`, NOT `emitAlloc` — bound A must not
/// inflate). Arity pins: 1–3 arguments, exactly one wanted result (the
/// `nwanted >= 2` multi path stays a barrier — `recBuiltin`'s preamble
/// already rejected `all_results`, this rejects fixed multi shapes).
/// Defaults record the SAME refs tier-0 derives: 1-arg → both konst 1;
/// 2-arg → `aux` IS the i ref (j defaults to the runtime i). Indices are
/// int-only (tier-0's integral-float coercion stays tier-0-owned — the
/// ssub precedent). An empty range side-exits at run time.
pub fn recBSCodepoint(self: *TraceState, instr: Instr, regs: RegWindow) !void {
    if (instr.b < 1 or instr.b > 3) return self.abort(.cross_frame);
    if (instr.c != 1) return self.abort(.cross_frame);
    try self.guardBuiltinCallee(instr.a, .codepoint);
    const base: usize = instr.a;
    const sref = (try self.stringArgRef(@intCast(base + 1), regs, .a1)) orelse return;
    const iref: Ref = if (instr.b >= 2)
        (try self.intArgRef(@intCast(base + 2), regs, .a2)) orelse return
    else
        try self.konst(Value.int(1));
    const jref: Ref = if (instr.b == 3)
        (try self.intArgRef(@intCast(base + 3), regs, .a3)) orelse return
    else
        iref; // j defaults to the RUNTIME i — the same ref, not a konst
    self.setReg(instr.a, try self.emit(.{ .op = .scp, .a = sref, .b = iref, .aux = @intCast(jref), .ty = .int }));
}

// --- doc 30: the pattern-engine arms -----------------------------------

pub const PatternPin = struct { ref: Ref, str: *const string_mod.String };

/// P1: pin the pattern argument. A konst interned string passes ref-
/// through (bytes from the pool value); an observed runtime string gets
/// the interned-identity pin — `guard_string` for the dominating type
/// proof (unless the producer already proves it) plus `guard_sid` against
/// the pattern's konst-pool entry (§2a: equal bytes ⇔ same object within
/// a heap, so identity pins content — a cached-in-a-local pattern records
/// as well as a literal). Anything else aborts; tier-0 owns coercions.
/// Null = aborted (the `stringArgRef` convention).
pub fn patternArgPin(self: *TraceState, arg_slot: u16, regs: RegWindow, operand: OperandDesig) !?PatternPin {
    const r = try self.refOf(arg_slot);
    if (self.konstValueOf(r)) |kv| {
        if (!kv.isHeap() or kv.heapType() != .string) {
            self.abort(.bad_type);
            return null;
        }
        return .{ .ref = r, .str = string_mod.String.fromHeader(kv.asHeap()) };
    }
    const v = regs.get(arg_slot);
    if (!v.isHeap() or v.heapType() != .string) {
        self.abort(.bad_type);
        return null;
    }
    if (!self.isProvenStringRef(r))
        self.stampProv(try self.emit(.{ .op = .guard_string, .a = r }), .operand_type, operand, .neutral);
    // Rooting: `konst` interns the pattern Value into the trace pool
    // (an explicit GC root); the guard carries the POOL ID, never a
    // pointer — tier-1a resolves via `t.consts`, native bakes at compile
    // time (§2a).
    const pk = try self.konst(v);
    const pool_id = self.rec.instrs.items[@intCast(pk)].aux;
    self.stampProv(try self.emit(.{ .op = .guard_sid, .a = r, .aux = pool_id }), .operand_type, operand, .neutral);
    return .{ .ref = r, .str = string_mod.String.fromHeader(v.asHeap()) };
}

/// Project a completed match's result window out of the scratch (doc 30
/// §3): `first_slot` is the caller's first result register offset within
/// the window this helper owns (find offsets captures by 2). Emits one
/// `scap_str` per STRING capture in capture order REGARDLESS of the
/// wanted count (B02 — tier-0 materializes every capture before the
/// result window truncates, so the id stream must too); position
/// captures are non-allocating and emitted only when register-wanted.
/// Nil-pads wanted results beyond the produced span (M04).
pub fn projectCaptures(self: *TraceState, m: Ref, base: usize, first: usize, census: pattern_mod.Census, nwanted: usize) !void {
    var k: usize = 0;
    while (k < census.ncap) : (k += 1) {
        const slot = gc.MatchScratch.slot_cap0 + k;
        const wanted = (first + k) < nwanted;
        if (census.kinds[k] == .span) {
            const r = try self.emitAlloc(.{ .op = .scap_str, .a = m, .b = @intCast(slot), .ty = .heap });
            if (wanted) self.setReg(@intCast(base + first + k), r);
        } else if (wanted) {
            self.setReg(@intCast(base + first + k), try self.emit(.{ .op = .scap_int, .a = m, .b = @intCast(slot), .ty = .int }));
        }
    }
    var w: usize = first + census.ncap;
    while (w < nwanted) : (w += 1)
        self.setReg(@intCast(base + w), try self.konst(Value.nil()));
}

/// `string.find(s, pat [, init [, plain]])` (doc 30 §5). Plain flag must
/// be konst (its truthiness picks the shape at record time). Plain or
/// no-specials → `sfindp` with the end index as recorder arithmetic
/// (`start + cpLen(pat) − 1`, konst-folded from the pinned pattern — the
/// empty pattern's `(st, st−1)` falls out with `cpLen == 0`); else
/// `smatch` + scratch projections. v1 records the MATCHED direction only
/// (P2): the arm runs the same core tier-0 is about to and aborts on
/// no-match/raise.
pub fn recBSFind(self: *TraceState, instr: Instr, regs: RegWindow) !void {
    if (instr.b < 2 or instr.b > 4) return self.abort(.cross_frame);
    if (instr.c < 1) return self.abort(.cross_frame);
    try self.guardBuiltinCallee(instr.a, .find);
    const base: usize = instr.a;
    const sref = (try self.stringArgRef(@intCast(base + 1), regs, .a1)) orelse return;
    const sobj: *const string_mod.String = string_mod.String.fromHeader(regs.get(@intCast(base + 1)).asHeap());
    var plain = false;
    if (instr.b == 4) {
        const pref = try self.refOf(@intCast(base + 4));
        const pkv = self.konstValueOf(pref) orelse return self.abort(.bad_type);
        plain = pkv.isTruthy();
    }
    const init_ref: Ref = if (instr.b >= 3)
        (try self.intArgRef(@intCast(base + 3), regs, .a3)) orelse return
    else
        try self.konst(Value.int(1));
    const init_v: i64 = if (instr.b >= 3) regs.get(@intCast(base + 3)).asInt() else 1;
    const pat = (try self.patternArgPin(@intCast(base + 2), regs, .a2)) orelse return;
    const pat_bytes = pat.str.bytes();

    if (plain or !pattern_mod.hasSpecials(pat_bytes)) {
        // P2 via the same heap-free core the shim runs.
        if (string_stdlib.sfindPlainCore(sobj, init_v, pat_bytes) < 1) return self.abort(.bad_type);
        const r_start = try self.emit(.{ .op = .sfindp, .a = sref, .b = init_ref, .aux = @intCast(pat.ref), .ty = .int });
        self.setReg(instr.a, r_start);
        if (instr.c >= 2) {
            const cp_minus1: i64 = @as(i64, @intCast(pat.str.cpLen())) - 1;
            const kref = try self.konst(Value.int(cp_minus1));
            self.setReg(@intCast(base + 1), try self.emit(.{ .op = .add, .a = r_start, .b = kref, .ty = .int }));
        }
        var w: usize = 2;
        while (w < instr.c) : (w += 1) // M04: plain find has no captures
            self.setReg(@intCast(base + w), try self.konst(Value.nil()));
        return;
    }
    const census = pattern_mod.census(pat_bytes) orelse return self.abort(.bad_type);
    const st = string_stdlib.resolveInit(init_v, sobj) orelse return self.abort(.bad_type);
    var ms = pattern_mod.MatchState.init(sobj.bytes(), pat_bytes);
    _ = (pattern_mod.locateMatch(&ms, st, true) catch null) orelse return self.abort(.bad_type);
    const m = try self.emit(.{ .op = .smatch, .a = sref, .b = init_ref, .aux = @intCast(pat.ref), .ty = .int });
    self.setReg(instr.a, try self.emit(.{ .op = .scap_int, .a = m, .b = @intCast(gc.MatchScratch.slot_start), .ty = .int }));
    if (instr.c >= 2)
        self.setReg(@intCast(base + 1), try self.emit(.{ .op = .scap_int, .a = m, .b = @intCast(gc.MatchScratch.slot_end), .ty = .int }));
    try self.projectCaptures(m, base, 2, census, instr.c);
}

/// `string.match(s, pat [, init])` (doc 30 §5): always the `smatch` shape.
/// `ncap == 0` → the whole match interned from `slot_whole`; else the
/// capture window per B02/M04. Matched direction only (P2).
pub fn recBSMatch(self: *TraceState, instr: Instr, regs: RegWindow) !void {
    if (instr.b < 2 or instr.b > 3) return self.abort(.cross_frame);
    if (instr.c < 1) return self.abort(.cross_frame);
    try self.guardBuiltinCallee(instr.a, .match);
    const base: usize = instr.a;
    const sref = (try self.stringArgRef(@intCast(base + 1), regs, .a1)) orelse return;
    const sobj: *const string_mod.String = string_mod.String.fromHeader(regs.get(@intCast(base + 1)).asHeap());
    const init_ref: Ref = if (instr.b >= 3)
        (try self.intArgRef(@intCast(base + 3), regs, .a3)) orelse return
    else
        try self.konst(Value.int(1));
    const init_v: i64 = if (instr.b >= 3) regs.get(@intCast(base + 3)).asInt() else 1;
    const pat = (try self.patternArgPin(@intCast(base + 2), regs, .a2)) orelse return;
    const pat_bytes = pat.str.bytes();
    const census = pattern_mod.census(pat_bytes) orelse return self.abort(.bad_type);
    const st = string_stdlib.resolveInit(init_v, sobj) orelse return self.abort(.bad_type);
    var ms = pattern_mod.MatchState.init(sobj.bytes(), pat_bytes);
    _ = (pattern_mod.locateMatch(&ms, st, true) catch null) orelse return self.abort(.bad_type);
    const m = try self.emit(.{ .op = .smatch, .a = sref, .b = init_ref, .aux = @intCast(pat.ref), .ty = .int });
    if (census.ncap == 0) {
        self.setReg(instr.a, try self.emitAlloc(.{ .op = .scap_str, .a = m, .b = @intCast(gc.MatchScratch.slot_whole), .ty = .heap }));
        var w: usize = 1;
        while (w < instr.c) : (w += 1)
            self.setReg(@intCast(base + w), try self.konst(Value.nil()));
    } else {
        try self.projectCaptures(m, base, 0, census, instr.c);
    }
}

/// `@gmatch_iter(state)` → the composite `sgmatch` step (doc 30 §6). The
/// state is guarded a table; the pattern lives in `state[2]` where no SSA
/// ref exists, so the pin is NOT `guard_sid` — the expected pattern's
/// konst-pool id rides `sgmatch.aux` and the SHIM compares identity per
/// execution. The census only fixes the projection list, a syntactic
/// property of the pattern alone; subject/pos are read by the shim at run
/// time (a non-string subject / broken B03 layout → negative status →
/// side-exit). The cursor advance is a DEFERRED `sgm_setpos` through the
/// docs-07/08 pending-store discipline: any exit in the iteration replays
/// tier-0 against the UN-advanced pos and reproduces the same token.
/// v1 records the matched direction only; exhaustion aborts (the for-in
/// end is one side-exit per gmatch() call at run time).
pub fn recBSGmatchIter(self: *TraceState, instr: Instr, regs: RegWindow) !void {
    if (instr.b < 1 or instr.b > 2) return self.abort(.cross_frame);
    if (instr.c < 1) return self.abort(.cross_frame);
    try self.guardBuiltinCallee(instr.a, .gmatch_iter);
    const base: usize = instr.a;
    const state_slot: u16 = @intCast(base + 1);
    const stv = regs.get(state_slot);
    if (!stv.isHeap() or stv.heapType() != .table) return self.abort(.bad_type);
    const st_tbl = table_mod.Table.fromHeader(stv.asHeap());
    if (st_tbl.metatable != null) return self.abort(.has_metatable);
    const state_ref = try self.refOf(state_slot);
    // Fail-closed corner (§6): a SECOND composite step against the same
    // state ref in one iteration would read a stale pos under the
    // deferred store. The for-in shape (one aux call per iteration) never
    // trips this.
    for (self.rec.pending_stores.items) |ps| {
        if (ps.op == .sgm_setpos and ps.aref == state_ref) return self.abort(.bad_type);
    }
    // Record-time state reads: census inputs only — every runtime
    // assumption is shim-verified per execution or guarded.
    const subj_v = st_tbl.getInt(1);
    if (!subj_v.isHeap() or subj_v.heapType() != .string) return self.abort(.bad_type);
    const sobj = string_mod.String.fromHeader(subj_v.asHeap());
    const pat_v = st_tbl.getInt(2);
    if (!pat_v.isHeap() or pat_v.heapType() != .string) return self.abort(.bad_type);
    const pat_bytes = string_mod.String.fromHeader(pat_v.asHeap()).bytes();
    const pos = st_tbl.inLaneValueIntCell(3) orelse return self.abort(.bad_type); // B03
    if (pos < 0) return self.abort(.bad_type);
    const census = pattern_mod.census(pat_bytes) orelse return self.abort(.bad_type);
    // P2, gmatch flavor: continue from the stored pos, no anchor
    // consumption — exactly `gmatchAuxCore`'s locate.
    var ms = pattern_mod.MatchState.init(sobj.bytes(), pat_bytes);
    _ = (pattern_mod.locateMatch(&ms, @intCast(pos), false) catch null) orelse return self.abort(.bad_type);
    self.stampProv(try self.emit(.{ .op = .guard_table, .a = state_ref }), .operand_type, .a1, .neutral);
    const pk = try self.konst(pat_v);
    const pool_id = self.rec.instrs.items[@intCast(pk)].aux;
    const m = try self.emit(.{ .op = .sgmatch, .a = state_ref, .aux = pool_id, .ty = .int });
    if (census.ncap == 0) {
        self.setReg(instr.a, try self.emitAlloc(.{ .op = .scap_str, .a = m, .b = @intCast(gc.MatchScratch.slot_whole), .ty = .heap }));
        var w: usize = 1;
        while (w < instr.c) : (w += 1)
            self.setReg(@intCast(base + w), try self.konst(Value.nil()));
    } else {
        try self.projectCaptures(m, base, 0, census, instr.c);
    }
    const np = try self.emit(.{ .op = .scap_int, .a = m, .b = @intCast(gc.MatchScratch.slot_next_pos), .ty = .int });
    try self.rec.pending_stores.append(self.gpa, .{ .op = .sgm_setpos, .aref = state_ref, .value = np, .lane_ord = 0 });
}

/// `tonumber(v[, base])` — konst arguments fold at record time through
/// `arith.toNumber`, the ONE conversion core shared with tier-0's
/// `bToNumber` (so the fold and the builtin can never disagree); the result
/// is an int/float/nil konst, never an interned string. A non-konst
/// observed-*number* 1-arg call is the identity: pin with `guardNum` and
/// pass the ref through. Everything else (non-konst strings — a guarded
/// runtime parse — and dynamic bases) aborts; tier-0 owns it.
pub fn recBTonumber(self: *TraceState, instr: Instr, regs: RegWindow) !void {
    if (instr.c != 1) return self.abort(.cross_frame);
    if (instr.b < 1 or instr.b > 2) return self.abort(.cross_frame);
    const arg_ref = try self.refOf(@intCast(@as(usize, instr.a) + 1));
    const kv = self.konstValueOf(arg_ref);
    if (instr.b == 2) {
        const base_ref = try self.refOf(@intCast(@as(usize, instr.a) + 2));
        const kb = self.konstValueOf(base_ref) orelse return self.abort(.bad_type);
        const ka = kv orelse return self.abort(.bad_type);
        try self.guardBuiltinCallee(instr.a, .tonumber);
        self.setReg(instr.a, try self.konst(arith.toNumber(ka, kb)));
        return;
    }
    if (kv) |ka| {
        try self.guardBuiltinCallee(instr.a, .tonumber);
        self.setReg(instr.a, try self.konst(arith.toNumber(ka, null)));
        return;
    }
    const argv = regs.get(@intCast(@as(usize, instr.a) + 1));
    if (argv.isNumber()) {
        try self.guardBuiltinCallee(instr.a, .tonumber);
        try self.guardNum(arg_ref, argv, .operand_type, .a1);
        self.setReg(instr.a, arg_ref);
        return;
    }
    // Doc 30: the observed-STRING 1-arg call — a guarded runtime parse
    // through the ONE `arith.toNumber` core (`str2numRuntime` calls the
    // same function, so the recorder's observation, tier-0, and the
    // trace can never disagree). The observed outcome bakes the op's
    // kind (P2); a later kind flip or non-number side-exits at run time.
    // The nil direction stays tier-0 in v1.
    if (argv.isHeap() and argv.heapType() == .string) {
        try self.guardBuiltinCallee(instr.a, .tonumber);
        const sref = (try self.stringArgRef(@intCast(@as(usize, instr.a) + 1), regs, .a1)) orelse return;
        const outcome = arith.toNumber(argv, null);
        if (outcome.isInt()) {
            self.setReg(instr.a, try self.emit(.{ .op = .str2num_i, .a = sref, .ty = .int }));
        } else if (outcome.isFloat()) {
            self.setReg(instr.a, try self.emit(.{ .op = .str2num_f, .a = sref, .ty = .float }));
        } else {
            return self.abort(.bad_type);
        }
        return;
    }
    return self.abort(.bad_type);
}

/// `select('#', a…)` — only the konst-`'#'` selector records: the arg count
/// is compile-time fixed (`instr.b − 1`; `instr.b` excludes the callee), so
/// the result is a constant with no runtime guard beyond the callee
/// identity — konst args need no re-proving. The numeric form (a slot
/// shuffle, multi-result) is a non-goal; vararg callers can't trace anyway
/// (`is_vararg` aborts in `recCall`).
pub fn recBSelect(self: *TraceState, instr: Instr) !void {
    if (instr.c != 1) return self.abort(.cross_frame);
    if (instr.b < 1) return self.abort(.cross_frame);
    const sel_ref = try self.refOf(@intCast(@as(usize, instr.a) + 1));
    const sel = self.konstValueOf(sel_ref) orelse return self.abort(.bad_type);
    if (!sel.isHeap() or sel.heapType() != .string) return self.abort(.bad_type);
    const bytes = string_mod.String.fromHeader(sel.asHeap()).bytes();
    if (bytes.len != 1 or bytes[0] != '#') return self.abort(.bad_type);
    try self.guardBuiltinCallee(instr.a, .select);
    self.setReg(instr.a, try self.konst(Value.int(@as(i64, instr.b) - 1)));
}

/// `rawequal(a, b)` — the NaN-safe fold subset (doc 23 D2, codex catch #6:
/// `Value.eql` is false for NaN==NaN, so same-ref must NOT blindly fold
/// true). Konst×konst folds exactly; a same-ref pair folds true only once
/// the ref is *pinned non-float* — observed table → raw `guard_table`,
/// observed int → registered `guardNum` (pins int) — because a float (or
/// unguarded) same-ref could be NaN on a later entry. Everything else
/// aborts; a general value-compare op has no consumer yet.
pub fn recBRawequal(self: *TraceState, instr: Instr, regs: RegWindow) !void {
    if (instr.b != 2) return self.abort(.cross_frame);
    if (instr.c != 1) return self.abort(.cross_frame);
    const ra = try self.refOf(@intCast(@as(usize, instr.a) + 1));
    const rb2 = try self.refOf(@intCast(@as(usize, instr.a) + 2));
    const ka = self.konstValueOf(ra);
    const kb = self.konstValueOf(rb2);
    if (ka != null and kb != null) {
        try self.guardBuiltinCallee(instr.a, .rawequal);
        self.setReg(instr.a, try self.konst(Value.boolean(ka.?.eql(kb.?))));
        return;
    }
    if (ra != rb2) return self.abort(.bad_type);
    const argv = regs.get(@intCast(@as(usize, instr.a) + 1));
    if (argv.isInt()) {
        try self.guardBuiltinCallee(instr.a, .rawequal);
        try self.guardNum(ra, argv, .operand_type, .a1);
    } else if (argv.isHeap() and argv.heapType() == .table) {
        const tbl = table_mod.Table.fromHeader(argv.asHeap());
        if (tbl.metatable != null) return self.abort(.has_metatable);
        try self.guardBuiltinCallee(instr.a, .rawequal);
        self.stampProv(try self.emit(.{ .op = .guard_table, .a = ra }), .operand_type, .a1, .neutral);
    } else {
        return self.abort(.bad_type); // float same-ref: NaN ~= NaN
    }
    self.setReg(instr.a, try self.konst(Value.boolean(true)));
}

/// `rawlen(v)` — arc A folds the konst-string case to its **byte** length
/// (`bRawLen` returns `String.len`; `#s` is `cp_len`, a different quantity
/// — codex catch #7, the two must never share an emission), and records an
/// observed table through the same guarded `alen` shape as `#t` (`bRawLen`
/// on a table is `Table.length()`, the identical border — and `rawget`-
/// style raw-vs-plain is moot since the shape aborts on any metatable).
pub fn recBRawlen(self: *TraceState, instr: Instr, regs: RegWindow) !void {
    if (instr.b != 1) return self.abort(.cross_frame);
    if (instr.c != 1) return self.abort(.cross_frame);
    const arg_slot: u16 = @intCast(@as(usize, instr.a) + 1);
    const argv = regs.get(arg_slot);
    if (argv.isHeap() and argv.heapType() == .table) {
        try self.guardBuiltinCallee(instr.a, .rawlen);
        return self.recAlenShape(instr.a, arg_slot, .a1, regs);
    }
    const arg_ref = try self.refOf(arg_slot);
    const kv = self.konstValueOf(arg_ref) orelse return self.abort(.bad_type);
    if (!kv.isHeap() or kv.heapType() != .string) return self.abort(.bad_type);
    try self.guardBuiltinCallee(instr.a, .rawlen);
    const len = string_mod.String.fromHeader(kv.asHeap()).len;
    self.setReg(instr.a, try self.konst(Value.int(@intCast(len))));
}

/// `rawget(t, k)` — records through the extracted index shapes (doc 23 D3).
/// On a metatable-free table raw and non-raw access are the same operation,
/// and the shapes abort `.has_metatable` at record time with `guard_table`
/// re-proving absence at runtime — so the reuse is sound rather than
/// assumed. Numeric key → array-get shape; string key → hash-get shape
/// (konst-key-only, enforced inside). Grid-lane tables abort `.bad_type`:
/// tier-0's raw access deflates grids, and a trace must not bake a
/// deflation (`guard_lane` deopts if a table becomes a grid between
/// entries). Provenance designates the call args (`.a1` table, `.a2` key).
pub fn recBRawget(self: *TraceState, instr: Instr, regs: RegWindow) !void {
    if (instr.b != 2) return self.abort(.cross_frame);
    if (instr.c != 1) return self.abort(.cross_frame);
    const tab_slot: u16 = @intCast(@as(usize, instr.a) + 1);
    const key_slot: u16 = @intCast(@as(usize, instr.a) + 2);
    const vtab = regs.get(tab_slot);
    if (!vtab.isHeap() or vtab.heapType() != .table) return self.abort(.bad_type);
    if (table_mod.Table.fromHeader(vtab.asHeap()).array.lane == .grid) return self.abort(.bad_type);
    try self.guardBuiltinCallee(instr.a, .rawget);
    const vkey = regs.get(key_slot);
    if (vkey.isNumber())
        try self.arrayGetShape(regs, .{ .dst = instr.a, .tab = tab_slot, .key = key_slot, .tab_od = .a1, .key_od = .a2 })
    else if (isStringKey(vkey))
        try self.hashGetShape(regs, .{ .dst = instr.a, .tab = tab_slot, .key = key_slot, .tab_od = .a1, .key_od = .a2 })
    else
        return self.abort(.bad_type);
}

/// `rawset(t, k, v)` — the write mirror of `recBRawget`, through the same
/// extracted shapes with the store-sinking discipline unchanged (a sunk
/// store commits below every guard exactly as for `set_index`). A nil/NaN
/// key falls out naturally: nil is neither number nor string key (abort),
/// NaN fails `keyIndexOf` inside the array shape — tier-0 owns the error.
/// The statement-tolerant arm (doc 23 D1): `c ∈ {0,1}` — a statement call
/// (`rawset(t, k, v)` discarding the result, the common form, compiled
/// with `c == 0`) records the store alone; a value call (`c == 1`) also
/// defines the dest register with the table ref (tier-0 `bRawSet` returns
/// `args[0]`).
pub fn recBRawset(self: *TraceState, instr: Instr, regs: RegWindow) !void {
    if (instr.b != 3) return self.abort(.cross_frame);
    if (instr.c > 1) return self.abort(.cross_frame);
    const tab_slot: u16 = @intCast(@as(usize, instr.a) + 1);
    const key_slot: u16 = @intCast(@as(usize, instr.a) + 2);
    const val_slot: u16 = @intCast(@as(usize, instr.a) + 3);
    const vtab = regs.get(tab_slot);
    if (!vtab.isHeap() or vtab.heapType() != .table) return self.abort(.bad_type);
    if (table_mod.Table.fromHeader(vtab.asHeap()).array.lane == .grid) return self.abort(.bad_type);
    try self.guardBuiltinCallee(instr.a, .rawset);
    const vkey = regs.get(key_slot);
    if (vkey.isNumber())
        try self.arraySetShape(regs, .{ .tab = tab_slot, .key = key_slot, .val = val_slot, .tab_od = .a1, .key_od = .a2, .val_od = .a3 })
    else if (isStringKey(vkey))
        try self.hashSetShape(regs, .{ .tab = tab_slot, .key = key_slot, .val = val_slot, .tab_od = .a1, .key_od = .a2, .val_od = .a3 })
    else
        return self.abort(.bad_type);
    if (!self.isRecording()) return; // the shape aborted
    if (instr.c == 1) self.setReg(instr.a, try self.refOf(tab_slot));
}

/// Record `#t` / `rawlen(t)` as the guarded `alen` producer (doc 23 D3):
/// `guard_table(t)` then `alen(t)`, whose own runtime check side-exits
/// unless the exact fast case holds (hash empty ∧ bitmap lane ∧ (asize ≤ 1 ∨
/// present(asize−1))). The record-time observation must already satisfy the
/// fast case — an already-failing shape would be an instant turnstile — and
/// `.value`/`.boolean`/grid lanes abort (their presence is in-band, so the
/// fast case can't certify the border without reading elements).
///
/// Sunk-store interaction (arc-A codex #4, REFINED in doc 24 D7): pending
/// RMW stores flush at commit, below every guard, so on-trace `alen` reads
/// the pre-store table state mid-iteration. That is sound WITHOUT an abort
/// because sunk stores cannot change the guarded fast-case answer:
///   - only in-bounds stores sink (appends are never deferred — they change
///     `len` and abort/`astore_append` inline), so `asize` is invariant;
///   - stores never clear presence (nil hole-punch aborts), so
///     `present(asize-1)` can only go false→true; the trace's alen check
///     reading the stale FALSE side-exits — and since `alen` is a
///     side-exiting op, the sunk stores are un-executed at that exit and
///     tier-0's replay applies them exactly once (the doc-08 argument);
///   - when the check passes on the pre-store state, the result depends
///     only on `asize` — identical pre- and post-store;
///   - a sunk `hstore` implies a non-empty hash on ITS table; if that is
///     this table, the record-time `hash.count()` check below aborts, and
///     a different table cannot alias this one's header fields.
/// So: no pending-store abort. Gate: the rawset-then-`#t` differential in
/// trace_record_test.zig plus scalar's end-to-end run (doc 24 D7).
pub fn recAlenShape(self: *TraceState, dst: u16, tab_slot: u16, tab_od: OperandDesig, regs: RegWindow) !void {
    const vtab = regs.get(tab_slot);
    if (!vtab.isHeap() or vtab.heapType() != .table) return self.abort(.bad_type);
    const tbl = table_mod.Table.fromHeader(vtab.asHeap());
    if (tbl.metatable != null) return self.abort(.has_metatable);
    if (tbl.hash.count() != 0) return self.abort(.bad_type);
    if (!tbl.array.lane.scalarPresenceLane()) return self.abort(.bad_type);
    const asize = tbl.array.asize;
    if (asize > 1 and !tbl.array.isPresent(asize - 1)) return self.abort(.bad_type);
    const rtab = try self.refOf(tab_slot);
    self.stampProv(try self.emit(.{ .op = .guard_table, .a = rtab }), .container_type, tab_od, .neutral);
    const r = try self.emit(.{ .op = .alen, .a = rtab, .ty = .int });
    self.stampProv(r, .border, tab_od, .neutral);
    self.setReg(dst, r);
}

/// Emit `guard_builtin(callee, rb)` unless this callee ref already carries
/// one — re-proving, in both tiers, that the seeded callee is still this
/// exact builtin. The callee ref is the seeded loop-invariant input (so the
/// guard checks the same value `seedTraceInputs` re-resolves). Deduped
/// against `guarded_refs` — one SSA value, one identity check (a native
/// callee never carries a numeric type guard, so reusing the set is sound).
/// `aux` carries the `RecordedBuiltin` ordinal, not a PC.
pub fn guardBuiltinCallee(self: *TraceState, callee_slot: u16, rb: function.RecordedBuiltin) !void {
    const callee_ref = try self.refOf(callee_slot);
    if (!self.rec.guarded_refs.contains(callee_ref)) {
        try self.rec.guarded_refs.put(self.gpa, callee_ref, {});
        self.stampProv(try self.emit(.{ .op = .guard_builtin, .a = callee_ref, .aux = @intFromEnum(rb) }), .callee_pure, .a, .neutral);
    }
}

/// Inline a `math.sqrt(x)` call (callee flagged `RecordedBuiltin.sqrt`, doc 12) as a
/// leaf `fsqrt` producer instead of aborting `.host_barrier`. Emits, in order:
/// `guard_builtin(callee)` (re-prove the seeded callee is still this exact builtin —
/// deduped like a type guard, LICM-hoistable since the callee is a once-seeded
/// loop invariant), a type guard pinning the numeric operand, then
/// `fsqrt(arg)` whose result lands directly in the call's destination register.
/// NO frame push / NO `recReturn`: `fsqrt` is a leaf producer — the single value
/// the call site wants is `instr.a` itself, with no callee window to model.
pub fn recPureSqrt(self: *TraceState, instr: Instr, regs: RegWindow) !void {
    return self.recFloatUnary(instr, regs, .sqrt, .fsqrt);
}

/// The shared float-leaf shape (doc 23 D4): `f(x)` with one fixed numeric
/// arg and one result inlines as `guard_builtin(callee)` + a type guard on
/// the arg + a leaf float-producer op (`fsqrt`/`fsin`/`fcos`) whose result
/// lands in the call's destination. One fixed arg, one fixed result — any
/// other arity has no leaf shape, abort, tier-0 owns the call.
///
/// Numeric args only: the observed type (int or float) is pinned by
/// `guard_int`/`guard_float`, and an int operand is promoted by the SAME
/// operand-level discipline the float binary ops already use — tier-1a
/// `@floatFromInt`, native `cvtsi2sd` in `floatOperandToXmm`, both
/// round-to-nearest and bit-identical (partialsums' `sin(k)`/`sqrt(k)`
/// with an integer loop var is exactly this shape; doc 23 D4 note).
/// Anything non-numeric aborts `.bad_type`.
pub fn recFloatUnary(self: *TraceState, instr: Instr, regs: RegWindow, rb: function.RecordedBuiltin, op: IrOp) !void {
    if (instr.b != 1) return self.abort(.cross_frame);
    if (instr.c != 1) return self.abort(.cross_frame);
    const arg = regs.get(@intCast(@as(usize, instr.a) + 1));
    if (!arg.isFloat() and !arg.isInt()) return self.abort(.bad_type);

    try self.guardBuiltinCallee(instr.a, rb);
    const arg_ref = try self.refOf(@intCast(@as(usize, instr.a) + 1));
    const g: IrOp = if (arg.isFloat()) .guard_float else .guard_int;
    try self.guard(arg_ref, g, .operand_type, .a1);
    const r = try self.emit(.{ .op = op, .a = arg_ref, .ty = .float });
    self.setReg(instr.a, r);
}

/// Record `math.floor(x)` / `math.ceil(x)`. Unlike `recFloatUnary`
/// (sin/cos/sqrt → float result), these produce an INTEGER result (Lua 5.4
/// semantics: `math.floor(2.7) == 2`, an int, not `2.0`).
///
/// Integer path: `floor(int) == int` (identity). Emit `guard_int(arg)` and
/// reuse the same ref — no `ffloor`/`fceil` emitted.
/// Float path: emit `guard_float(arg)` + `ffloor`/`fceil` with `.ty = .int`.
/// The IR op side-exits on NaN / inf / out-of-`[-2^63, 2^63)`.
pub fn recFloorCeil(self: *TraceState, instr: Instr, regs: RegWindow, rb: function.RecordedBuiltin, op: IrOp) !void {
    if (instr.b != 1) return self.abort(.cross_frame); // single-arg only
    if (instr.c != 1) return self.abort(.cross_frame); // single-result only
    const arg = regs.get(@intCast(@as(usize, instr.a) + 1));
    if (!arg.isFloat() and !arg.isInt()) return self.abort(.bad_type);

    try self.guardBuiltinCallee(instr.a, rb);
    const arg_ref = try self.refOf(@intCast(@as(usize, instr.a) + 1));

    if (arg.isInt()) {
        // Integer → identity: floor/ceil of an int is itself.
        try self.guard(arg_ref, .guard_int, .operand_type, .a1);
        self.setReg(instr.a, arg_ref);
    } else {
        // Float → ffloor/fceil producing an integer.
        try self.guard(arg_ref, .guard_float, .operand_type, .a1);
        const r = try self.emit(.{ .op = op, .a = arg_ref, .ty = .int });
        self.setReg(instr.a, r);
    }
}

/// Cross-frame tracing — close an inlined callee (LuaJIT's `lj_record_ret`).
/// Only reached at `inline_depth > 0` (the anchor-frame `.ret` aborts). Maps the
/// callee's result slots back into the caller's `ret_dest..` window, nil-padding
/// to the call site's fixed `ret_count`, then pops the recorder frame and
/// restores `base_off`. The result writes use *absolute* `reg_map` indices (the
/// caller region is disjoint from and below the callee source region, so a
/// single forward pass can read source then write dest without a buffer).
pub fn recReturn(self: *TraceState, instr: Instr, multret: ?u32) !void {
    const d = self.rec.inline_depth - 1;
    const fr = self.rec.frames[d];
    // Doc 27 D5: `ret a, all_results` (`return prefix..., g(...)`) resolves
    // its produced count from the multret shadow in CALLEE frame-space —
    // `top - a` counts the fixed prefix slots plus everything the trailing
    // producer left, exactly tier-0's `reg_top`-based resolution. Fails
    // closed on a `null` shadow and on the sentinel bound (§3a, u32 math).
    const produced: u32 = if (instr.b == bytecode.all_results) blk: {
        const top = multret orelse return self.abort(.cross_frame);
        if (top < instr.a) return self.abort(.cross_frame);
        const n = top - instr.a;
        if (n >= bytecode.all_results) return self.abort(.cross_frame);
        break :blk n;
    } else instr.b;
    // Doc 27 D4: a caller that wanted a dynamic window (`call … c =
    // all_results`) takes exactly `produced` values — no nil-fill, tier-0's
    // `wants_all` arm — and re-exports the shadow for ITS caller's next
    // instruction, in caller frame-space (after `base_off` is restored).
    const wants_all = fr.ret_count == bytecode.all_results;
    const want: u32 = if (wants_all) produced else fr.ret_count;
    // The dynamic shapes can write above the caller's fixed window (tier-0
    // does the same into slab scratch); bound them against the reg_map
    // reservation like `recCall` bounds callee windows.
    if (@as(usize, fr.base_off) + fr.ret_dest + want > self.rec.reg_map.len)
        return self.abort(.frame_bounds);
    var k: u32 = 0;
    while (k < want) : (k += 1) {
        // `base_off` is still the callee window here, so `refOf` reads the
        // callee's result slots `instr.a + k`.
        const ref: Ref = if (k < produced)
            try self.refOf(@intCast(@as(usize, instr.a) + k))
        else
            try self.konst(Value.nil());
        // Whole-RegSlot write → `defineSlotAbs` (doc 39): return values can
        // land back in the ANCHOR window (`fr.base_off == 0`), where the
        // write must both preserve `entry_kind` and mark a peel rebound.
        self.defineSlotAbs(@as(usize, fr.base_off) + fr.ret_dest + k, ref);
    }
    self.rec.base_off = fr.base_off;
    self.rec.inline_depth = d;
    if (wants_all) self.rec.multret_top = @as(u32, fr.ret_dest) + produced;
}

/// Cluster sub-lever 1 — record a `get_upval`/`get_global` as a synthetic entry
/// input. The read's loop-invariant value (`resolved`, pre-resolved by the
/// dispatch loop since the executor has no `*Vm`/closure) is snapshotted into a
/// dead slab slot above the anchor window: emit a `slot_load` from that slot,
/// register the (`kind`, `source`→`slot`) seeding recipe on the trace, and — for
/// a function callee — pin its identity with `guard_func`. The dispatch loop
/// re-seeds the slot every entry (so a cross-entry change deopts via the guard
/// or a downstream type guard); a `set_upval`/`set_global` *inside* the traced
/// region is not in the record switch, so it aborts — the snapshot can never go
/// stale mid-run.
///
/// Inlined-callee upvalues: reads inside inlined callees (inline_depth > 0) create a
/// `callee_upvalue` seed that resolves through the callee's closure at entry.
/// The callee's closure is in a slab slot that was itself seeded earlier (as an
/// anchor-frame `upvalue`/`global` or regular `slot_load` input), so seed
/// ordering is correct by construction. Global reads at inline_depth > 0 still
/// abort — globals use proto-specific constant pool indices.
pub fn recInputGet(self: *TraceState, comptime kind: InputKind, dest: u16, source: u16, resolved: Value) !void {
    // Inlined-callee upvalues resolve through the callee's
    // closure. Global reads at depth > 0 still abort: the seed uses the
    // anchor's proto.constants, but the global's constant-pool index refers to
    // the callee's proto — a different key set.
    if (self.rec.inline_depth != 0) {
        if (kind == .global) return self.abort(.cross_frame);
        // kind == .upvalue at inline_depth > 0 → callee_upvalue seed.
        return self.recCalleeUpval(dest, source, resolved);
    }

    const key = (@as(u64, @intFromEnum(kind)) << 32) | source;
    if (self.rec.input_dedup.get(key)) |ref| {
        // A repeat read of the same upvalue/global reuses the one snapshot.
        self.setReg(dest, ref);
        return;
    }
    // Cap the number of synthetic inputs a single trace may carry. The hard
    // limit is the executor window the dispatch loop must widen (checked against
    // `regCapacity` at entry); this cap bounds it cheaply and keeps a
    // pathological loop from growing the entry snapshot without bound.
    if (self.rec.input_seeds.items.len >= MAX_TRACE_INPUTS) return self.abort(.input_cap);

    // Defensive: the synthetic slot counter is a `u16` seeded at
    // `anchor_num_registers`. A function with a near-`u16`-max register window
    // could push it to the wrap boundary; an `@intCast`-wrapped slot would fold
    // back *into* the live anchor window as a plausible in-window `slot_load`
    // that `assertWellFormed` (bound `anchor_num_registers + n_inputs`) cannot
    // catch — and `seedTraceInputs` would then clobber a live caller register.
    // Abort rather than wrap. (MAX_TRACE_INPUTS already bounds the count; this
    // bounds the *index*.)
    if (self.rec.next_input_slot == std.math.maxInt(u16)) return self.abort(.input_cap);

    const slot = self.rec.next_input_slot;
    self.rec.next_input_slot += 1;
    const ref = try self.emit(.{ .op = .slot_load, .aux = @intCast(slot), .ty = .unknown });
    try self.rec.entry_slots.append(self.gpa, slot);
    try self.rec.input_seeds.append(self.gpa, .{ .kind = kind, .source = source, .slot = slot });
    try self.rec.input_dedup.put(self.gpa, key, ref);
    // Pin a *function* callee's identity so a different proto — or a value that
    // is no longer a function — side-exits. A non-function loop-invariant (e.g.
    // an upvalue table) needs no identity guard: its *type* is pinned by the
    // ordinary operand guard wherever the trace consumes it.
    if (resolved.isHeap() and resolved.heapType() == .function) {
        const cl = function.Closure.fromHeader(resolved.asHeap());
        // Operand is the destination register `dest` (H-1c: `(callee_identity, dest)`),
        // which `recInputGet` receives as `instr.a` of the get_upval/get_global.
        self.stampProv(try self.emit(.{ .op = .guard_func, .a = ref, .aux = @bitCast(cl.proto.id) }), .callee_identity, .a, .neutral);
    }
    self.setReg(dest, ref);
}

/// Record a `get_upval` inside an inlined callee. The callee's closure
/// must be reachable as a `slot_load` in the anchor slab (i.e. the callee was
/// loaded from an upvalue/global/local of the anchor frame). If the callee was
/// computed on-trace (not a `slot_load`), we abort — on-trace closure creation
/// is future work (doc 24).
///
/// The seed resolves at entry by reading the callee closure from its slab slot
/// and then resolving `closure.upvalues[source]` through `upvalGet`. The
/// callee's own seed was appended earlier (when the anchor-frame `get_upval`
/// that loaded the callee ran), so seed ordering is correct by construction.
pub fn recCalleeUpval(self: *TraceState, dest: u16, source: u16, resolved: Value) !void {
    // Find the callee's closure ref. The callee was at register `ret_dest` in
    // frame `inline_depth - 1` (ret_dest = instr.a of the .call that opened
    // this inline frame — Lua convention: reg A holds the callee).
    const d = self.rec.inline_depth - 1;
    const callee_anchor_reg: usize = @as(usize, self.rec.frames[d].base_off) + self.rec.frames[d].ret_dest;
    if (callee_anchor_reg >= self.rec.reg_map.len) return self.abort(.cross_frame);
    const callee_entry = self.rec.reg_map[callee_anchor_reg];
    if (callee_entry.state == .undef) return self.abort(.cross_frame);
    const callee_ref = callee_entry.ref;

    // The callee ref must be a `slot_load` — that means the callee's closure
    // is in a known slab slot at entry time. A computed callee (aload, hload,
    // etc.) can't be re-resolved at entry, so we abort.
    const callee_ir = self.rec.instrs.items[callee_ref];
    if (callee_ir.op != .slot_load) return self.abort(.cross_frame);
    const callee_slot: u16 = @intCast(callee_ir.aux);

    // Dedup: (callee_upvalue << 32) | (callee_slot << 16) | source.
    // Two different inlined callees might both read upvalue index 0, so the
    // key must incorporate which callee.
    const key = (@as(u64, @intFromEnum(InputKind.callee_upvalue)) << 32) |
        (@as(u64, callee_slot) << 16) | source;
    if (self.rec.input_dedup.get(key)) |ref| {
        self.setReg(dest, ref);
        return;
    }

    if (self.rec.input_seeds.items.len >= MAX_TRACE_INPUTS) return self.abort(.input_cap);
    if (self.rec.next_input_slot == std.math.maxInt(u16)) return self.abort(.input_cap);

    const slot = self.rec.next_input_slot;
    self.rec.next_input_slot += 1;
    const ref = try self.emit(.{ .op = .slot_load, .aux = @intCast(slot), .ty = .unknown });
    try self.rec.entry_slots.append(self.gpa, slot);
    try self.rec.input_seeds.append(self.gpa, .{
        .kind = .callee_upvalue,
        .source = source,
        .slot = slot,
        .callee_slot = callee_slot,
    });
    try self.rec.input_dedup.put(self.gpa, key, ref);

    // Pin a function callee's identity (same as the anchor-frame path).
    if (resolved.isHeap() and resolved.heapType() == .function) {
        const cl = function.Closure.fromHeader(resolved.asHeap());
        self.stampProv(try self.emit(.{ .op = .guard_func, .a = ref, .aux = @bitCast(cl.proto.id) }), .callee_identity, .a, .neutral);
    }
    self.setReg(dest, ref);
}

/// Doc 39: `pc` anchors a *plain while* loop — at least one plain backward
/// `jmp` targets it, and no conditional backward jump (a repeat-until
/// back-edge) or loop-op back-edge (`for_loop`/`tfor_loop`/`jfor_loop`)
/// does. Pure bytecode geometry as a standalone predicate. Unmemoized: it
/// runs at most once per anchor-return of an otherwise-eligible root
/// recording, never on the dispatch hot path.
pub fn isPlainWhileAnchor(proto: *const Proto, pc: u32) bool {
    var has_plain = false;
    for (proto.code, 0..) |ins, j| {
        const is_jump = switch (ins.op) {
            .jmp, .jmp_if_false, .jmp_if_true, .for_loop, .tfor_loop, .jfor_loop => true,
            else => false,
        };
        if (!is_jump) continue;
        const t = @as(i64, @intCast(j)) + 1 + ins.aux;
        if (t != pc or j <= pc) continue;
        if (ins.op == .jmp) {
            has_plain = true;
        } else {
            return false;
        }
    }
    return has_plain;
}

/// Result type of a recorded arithmetic op given its observed operands. Mirrors
/// `arith.zig`: `/` and `^` are always float; otherwise int iff both operands are
/// int (matching tier-0's int/float promotion).
pub fn arithResultType(op: IrOp, vb: Value, vc: Value) ObsType {
    if (op == .div or op == .pow) return .float;
    return if (vb.isInt() and vc.isInt()) .int else .float;
}

pub fn obsTypeOf(v: Value) ObsType {
    return switch (v.tag) {
        .nil => .nil,
        .boolean => .boolean,
        .int => .int,
        .float => .float,
        .heap_ref => .heap,
        // TODO(Phase 8, doc 14): the fused grid-index path observes grid rows
        // directly; until it lands the recorder never sees a `row_view` operand
        // (grids are disabled), so this is unreachable.
        .row_view => unreachable,
    };
}

/// State of a tier-0 register within the recording: `undef` (never touched →
/// next read emits a `slot_load`), `input` (holds a `slot_load` ref — read but
/// not written, loop-invariant), or `def` (holds a computed ref — a loop-carried
/// write that surfaces in the exit snapshot).
pub const SlotState = enum { undef, input, def };

/// Doc 39 Phase 0: the numeric kind a type proof established for a slot's
/// ENTRY value (the `slot_load`), or `.none` when no int/float proof covered
/// it. Stamped centrally by `noteEntryKind` on every proof route (`guardNum`,
/// `guardInt`/`keyRefNarrowed`, bitop guards, lane-implied `guard_fits`) and
/// preserved across every whole-`RegSlot` write (`defineSlotAbs`), so the
/// peel-eligibility sweep can compare "entered int" against "carries float".
pub const EntryKind = enum { none, int, float };

/// The SSA ref currently held by a tier-0 register, with how it got there.
/// `entry_kind` records the proven numeric kind of the slot's entry value
/// (doc 39) — a property of the recording's entry snapshot, so it survives
/// redefinition (`.def`) of the slot.
pub const RegSlot = struct { ref: Ref = 0, state: SlotState = .undef, entry_kind: EntryKind = .none };

/// Doc 39: one anchor-window slot's snapshot at the peel marker (the first
/// anchor-return of a type-unstable plain-while root).
pub const PeelSlot = struct {
    /// The slot's iteration-1 final ref at the marker.
    ref: Ref = 0,
    /// The slot's state at the marker: `.def` = iteration 1 defined it (a body
    /// read lazily creates an internal φ); `.input`/`.undef` = invariant or
    /// untouched (referenced directly, no φ).
    state: SlotState = .undef,
    /// The body pass wrote this slot, or its internal φ was already created —
    /// either way, later body reads use `reg_map` directly (no new φ). A body
    /// WRITE before any read deliberately leaves `phi_ref` null: the slot has
    /// no cross-iteration dataflow of its own (redefined from other φ'd inputs
    /// every iteration) and falls to the existing write-only slot class.
    rebound: bool = false,
    /// The internal φ (aux == PHI_INTERNAL) carrying this slot's steady state,
    /// created lazily at the first body read. Its `b` is patched at close.
    phi_ref: ?Ref = null,
};

/// Doc 39: in-flight type-stabilizing peel. Entered at the first anchor-return
/// of an eligible unstable recording (`maybeEnterPeel`); cleared by `reset`.
pub const PeelState = struct {
    /// `instrs.len` immediately after the `preheader` marker was emitted. A
    /// close-path call arriving with the stream still at this length is the
    /// SAME logical anchor-return that entered the peel (`onBackEdge` and
    /// `maybeCloseAtAnchor` both fire on one arrival — the shared-generation
    /// rule, codex round-2 finding 1) and must not close; the next arrival
    /// (stream grown by the body pass) is the real second return.
    mark_len: usize,
    /// Per-slot marker snapshot, length `anchor_num_registers` (gpa-owned;
    /// freed by `Recorder.reset`/`deinit`).
    slots: []PeelSlot,
};

/// Key for interning constants in the recorder's const pool. Built from the tag
/// plus the meaningful payload bits — NOT the raw 16-byte `Value`, which has
/// uninitialised padding between `tag` and `payload`. Immediates compare by
/// value; a `heap_ref` const (always a string literal) compares by object
/// identity, which is conservative and sufficient: the same pooled literal is the
/// same heap object, and consts are GC roots for the recording's lifetime, so no
/// address is reused mid-recording.
pub const KonstKey = struct { tag: u8, bits: u64 };

pub fn konstKey(v: Value) KonstKey {
    return .{
        .tag = @intFromEnum(v.tag),
        .bits = switch (v.tag) {
            .nil => 0,
            .boolean => @as(u64, @intFromBool(v.asBool())),
            .int => @bitCast(v.asInt()),
            .float => @bitCast(v.asFloat()),
            .heap_ref => @intFromPtr(v.asHeap()),
            // Never a trace constant (runtime transient).
            .row_view => unreachable,
        },
    };
}

/// The in-progress recording buffer. `TraceState` owns it and drives every
/// mutation through its own methods (`emit`/`refOf`/`recordInstr`/…); this struct
/// is just storage + cleanup. While `active` is false the interpreter never calls
/// into it.
/// A deferred read-modify-write store (`op` = `.astore` for an in-bounds array
/// slot, `.hstore` for a present hash cell), sunk below every guard at trace
/// close. `aref`/`value` are IR refs already emitted inline (the address node —
/// `aref`/`href` — and the value to store); `lane_ord` is the packed-array
/// `Lane` ordinal (the `astore`'s `aux`; 0 and unused for `.hstore`). See
/// `Recorder.pending_stores`.
pub const PendingStore = struct {
    aref: Ref,
    value: Ref,
    lane_ord: i32,
    op: IrOp = .astore,
};

pub const AliasClass = enum { must, no, may };
pub const AffineIntKey = struct { base: Ref, offset: i64 };

/// Per-inlined-frame register reservation in the recorder's grown `reg_map`. The
/// map is sized `anchor.num_registers + MAX_INLINE_DEPTH × MAX_CALLEE_REGS`; a
/// callee whose `num_registers` exceeds this reservation (or that would overflow
/// the map at depth) aborts cleanly rather than reading the slab out of bounds.
/// 256 covers every realistic leaf body the compiler emits.
pub const MAX_CALLEE_REGS = 256;

/// Maximum number of synthetic entry inputs (upvalue/global/hash-cell
/// snapshots) a single trace may carry. Each is one slab slot the dispatch loop
/// re-seeds + widens the executor window by; a trace wanting more aborts
/// cleanly (`.input_cap`), and the widened window is still capacity-checked
/// dynamically at every entry (`seedTraceInputs` declines on overflow), so this
/// constant is pure policy — a backstop against a pathological loop growing the
/// entry snapshot without bound — not a layout invariant.
///
/// Measured 2026-08-28 (input-cap sweep, CURRENT_TASK LATEST-94): the machinery
/// is free at every width tried. Synthetic N-upvalue-callee loops at N =
/// 2..64, steady-state AND entry-heavy shapes, show a flat jit cost curve
/// (~45× over tier-0 throughout), and the direct control — the same N callees
/// as anchor-frame locals (zero inputs) vs upvalues (N inputs) — is identical
/// within noise at N = 8/16/32/64. The old value (8) was set on the guess "a
/// handful of callees covers every realistic loop"; str_manip's main path
/// already needs 7, and one more cached builtin in any user loop would have
/// silently killed its trace. 64 keeps the backstop role (maxrecord bounds the
/// IR anyway — each input costs ≥2 ops) without realistically binding.
///
/// `pub` for the diagnostic dumps only (`writeTrace`, `dumpNative` in main.zig
/// render `inputs=N/{this}`); nothing outside this file may make policy off it.
pub const MAX_TRACE_INPUTS = 64;

/// One saved caller context for an inlined `.call`, popped at the matching
/// `.ret`. `base_off` is the caller frame's absolute slot offset (relative to the
/// anchor frame's base); `ret_dest`/`ret_count` mirror the call's `instr.a`/
/// `instr.c` (where results land in the caller, and how many it wants).
pub const InlineFrame = struct {
    base_off: u32,
    ret_dest: u16,
    ret_count: u16,
    /// The inline call *edge* that opened this frame (doc 17, A-i.2 / H-1a): the
    /// caller proto's globally-unique id and the `.call` opcode's PC. Together with
    /// the sibling frames on `Recorder.frames[0..inline_depth]` these form a guard's
    /// ordered inline-path prefix (`currentPath`), so the two guards from `f(a);
    /// f(b)` inlined at distinct call sites get distinct `GuardProvenance`. Set in
    /// `recCall`'s push; read by `currentPath`. Behaviour-neutral (recorder-only).
    caller_proto_id: u32,
    call_pc: u32,
};

/// Build a guard's ordered inline-path prefix (doc 17, A-i.2) from the recorder's
/// live inline-frame stack: `path[i]` is the call edge that opened frame `i`.
/// `depth` (= `Recorder.inline_depth`, ≤ `MAX_INLINE_DEPTH`) is the meaningful
/// length; entries `[depth, MAX_INLINE_DEPTH)` are left undefined (a
/// `GuardProvenance` carries its own `inline_depth`, so consumers only read the
/// prefix). Pure — the identity substrate `stampProv` (A-i.3) reads.
pub fn pathFromFrames(frames: []const InlineFrame, depth: u8) [MAX_INLINE_DEPTH]CallEdge {
    var path: [MAX_INLINE_DEPTH]CallEdge = undefined;
    for (0..depth) |i| path[i] = .{
        .caller_proto_id = frames[i].caller_proto_id,
        .call_pc = frames[i].call_pc,
    };
    return path;
}

/// Disposition of an in-flight recording, deciding whether it may close with a
/// `.link` terminator (doc 16). Only the *anchor* — where the recording started
/// and what already lives there — differs between the three; the link-permission
/// rule is "a `root` never links; a `side` or `continuation` may".
///
/// - `.root`      — the ordinary case. Armed by `arm` (hot-count or
///                  `wants_side_trace`) at an anchor that has no trace yet (or is
///                  a fresh root). A root that reaches an inner `for_prep` aborts
///                  LINNER (LuaJIT's model) so it never anchors a link trace on a
///                  real back-edge target.
/// - `.side`      — an outer-header prime side-trace (doc 16, Phase 2), armed by
///                  `maybeStartReplaySide` at the failed trace's own coherent
///                  anchor to record the *current* (e.g. prime) iteration's path.
///                  May close with a `.link` into an existing inner root.
/// - `.continuation` — a nested-loop continuation (doc 15), armed by
///                  `maybeStartContinuation` at a non-header exit pc after an
///                  inner loop's loop-done exit. May close with a `.link`.
pub const TraceKind = enum { root, side, continuation };

pub const Recorder = struct {
    active: bool = false,
    anchor: AnchorKey = .{ .proto = undefined, .pc = 0 },
    abort_reason: ?AbortReason = null,
    /// Doc 39: in-flight type-stabilizing peel, or null (the common case — no
    /// peel entered). Set by `maybeEnterPeel` at the first anchor-return of an
    /// int-entry/float-body plain-while root; consulted by the close paths
    /// (same-arrival suppression + second-return close), `refOf` (lazy internal
    /// φ) and `defineSlotAbs` (rebound tracking); consumed by `finishPeel` +
    /// `commit`. Cleared (slice freed) by `reset`/`deinit`.
    peel: ?PeelState = null,
    /// Doc 38 unroll-first policy: this ROOT recording followed at least one
    /// inner-while back-edge inline (unrolled it) instead of aborting LINNER.
    /// Read at abort (an unrolling root that dies bumps the outer anchor's
    /// `unroll_fail` evidence) and carried onto the committed `Trace` so
    /// runtime thrash of an unrolled root counts as the same evidence.
    unrolled_while: bool = false,
    instrs: std.ArrayListUnmanaged(IrInstr) = .empty,
    consts: std.ArrayListUnmanaged(Value) = .empty,
    entry_slots: std.ArrayListUnmanaged(u16) = .empty,
    /// Exit provenance (doc 17, A-i / 9-B), grown in **lockstep with every `emit`**:
    /// `emit` appends one `null` per IR append, and guard / fused-producer sites
    /// overwrite their slot via `stampProv` (A-i.3). So `exit_prov.items[ref]` is the
    /// provenance (if any) of the instruction at emission index `ref`, for every
    /// `emit`-appended instr. The φ writeback block and the `.link`/`.loop` terminal
    /// are appended to `instrs` *directly at commit* (after recording), NOT via
    /// `emit`, so they have no lockstep slot — the array covers exactly the
    /// `emit`-appended prefix, which is where all guards and fused producers live.
    /// The `.link` terminal's provenance rides `pending_link_provenance` instead
    /// (A-i.4). At commit the whole table is remapped through `tropt`'s compaction
    /// map into the committed, compact `Trace.exit_prov`. Recorder scratch —
    /// cleared/retained like `instrs`.
    exit_prov: std.ArrayListUnmanaged(?ExitProvenance) = .empty,
    /// Ordered recorded guest program-points (doc 17 §A8-ii, A-ii.3): one
    /// `{proto_id, source_pc}` per `recordInstr`, the membership-set basis A-ii.4
    /// unions per region. Recorder scratch — dup'd into `Trace.rec_path` at commit,
    /// cleared/retained like `instrs`. **Fail-soft:** if an append OOMs, `rec_path_ok`
    /// flips false and the recording continues (membership becomes *unavailable* for
    /// this trace, `Trace.rec_path` commits empty) — it must NEVER abort the trace.
    rec_path: std.ArrayListUnmanaged(ProgramPoint) = .empty,
    rec_path_ok: bool = true,
    /// Refs already covered by a type guard, so we emit each at most once.
    guarded_refs: std.AutoHashMapUnmanaged(Ref, void) = .empty,
    /// Interns constants: a recurring literal reuses its `konst` instruction's
    /// ref (and pool slot) instead of emitting a fresh one, so identical
    /// subexpressions get identical operand refs and the optimizer's CSE can
    /// merge them. See `TraceState.konst`.
    konst_map: std.AutoHashMapUnmanaged(KonstKey, Ref) = .empty,
    /// Current SSA ref + state for each tier-0 register, sized to the recording
    /// frame's `num_registers`.
    reg_map: []RegSlot = &.{},
    /// Lowest register slot that is a *compiler temporary* at this trace's loop
    /// header — the live-locals watermark. Set only by the `for_loop` whose
    /// back-edge targets this trace's anchor (so it describes the loop the trace
    /// actually re-enters): for a numeric-`for` the control regs occupy
    /// `base..base+3`, so every slot `>= base+4` is an expression temporary, dead
    /// at every statement boundary (`compiler.zig:8-9`) and after the loop
    /// (`freeTo(base)`). `commit()` drops such slots from the exit snapshot — they
    /// are recomputed by tier-0 on deopt and never read post-loop. The `maxInt`
    /// sentinel means "unknown" (while / generic-`for` / a passed-through `for`),
    /// so nothing is filtered and behavior is unchanged.
    locals_watermark: u32 = std.math.maxInt(u32),
    /// Nested-loop trace linking (doc 15, Phase 2): when set, this recording is a
    /// *continuation* that re-reached an inner numeric-`for`'s `for_prep` whose loop
    /// header already has a root trace. The value is the inner root's anchor pc (a
    /// bytecode pc in this same proto). `commit()` then closes the trace with a
    /// `.link{aux=link_target}` terminator *instead of* `.loop`, and caches it
    /// unoptimized (link traces skip `tropt`). `null` for every ordinary
    /// root/continuation trace (closes with `.loop`). Reset to `null` by `reset`.
    link_target: ?u32 = null,
    /// Transport for the `.link` terminal's exit provenance (doc 17, A-i.4 / edge 2):
    /// the `.link` op is synthesized at COMMIT (not at `recForPrepLink`, and link
    /// traces bypass `tropt.optimize`), so `recForPrepLink` stashes the terminal's
    /// `.link_terminal` provenance here and `commit` consumes it when it appends the
    /// `.link`. Release invariant: `link_target != null ⇔ pending_link_provenance !=
    /// null`. Reset to `null` by `reset` (every abort/re-arm) alongside `link_target`.
    pending_link_provenance: ?ExitProvenance = null,
    /// Nested-loop trace linking (doc 15, Phase 2): true iff this recording is a
    /// *continuation* — armed at a non-header exit pc by `maybeStartContinuation`,
    /// recording the outer body after an inner loop's loop-done exit. Only a
    /// continuation may close with a `.link` when it re-reaches an inner `for_prep`
    /// (LuaJIT's model: a *root* recording that hits an inner loop aborts LINNER and
    /// lets the inner spawn the side trace, so the root never links). Crucially this
    /// keeps link anchors off real back-edge targets — a root at the outer header
    /// would anchor a link trace at the outer body start (a genuine loop header the
    /// dispatch loop *enters*), which Phase 2 cannot execute. Set by
    /// `maybeStartContinuation` (`.continuation`) or `maybeStartReplaySide`
    /// (`.side`); reset to `.root` by `reset` (every `arm`). `recForPrepLink`
    /// permits a `.link` close for `.side`/`.continuation` but never `.root`.
    kind: TraceKind = .root,
    /// Hotexit provenance: the parent `(trace id, exit index)` whose hot exit
    /// triggered this recording (`noteTakenExit` → want → arm). Non-null only
    /// for hotexit-sourced recordings; on successful commit the parent's exit
    /// counter is latched `EXIT_COUNT_DONE` (Pall's `SNAPCOUNT_DONE` at
    /// lj_trace.c:535). Cleared by `reset` and consumed by `commit`; an abort
    /// simply drops it (Pall retries the exit — `snap->count` stays hot — and
    /// the abort's own `gateAnchor` backoff is our `penalty_pc` analog).
    side_src: ?ExitKey = null,
    /// **Post-increment resume/exit PC** of the instruction currently being
    /// recorded (= its source-opcode PC + 1; the tier-0 fetch advances one
    /// fixed-width `Instr` before the recording mirror). Set by `recordInstr`
    /// before `recordOne`; `emit` stores it in the `aux` field of guard
    /// instructions so the executor can report *which* guard failed and chain to
    /// the exit PC. NOT the source-opcode index — `guardSourcePc` recovers that.
    cur_pc: u32 = 0,
    /// Tier-0 opcode of the instruction currently being recorded. Set alongside
    /// `cur_pc` in `recordInstr`; read by `logAbort` (when `config.record_aborts`)
    /// to name the opcode that triggered an abort. `.halt` is a harmless initial
    /// placeholder — overwritten before any abort can reference it.
    cur_op: OpCode = .halt,
    /// Globally-unique id of the proto whose opcode is currently being recorded —
    /// the *leaf* proto (the anchor proto, or an inlined callee's proto once
    /// `recCall` descends). Set alongside `cur_pc`/`cur_op` in `recordInstr`. Read by
    /// `stampProv` (A-i.3) as a guard's `source_proto_id`, so a guard from an inlined
    /// callee is attributed to the callee, not the anchor. Default 0 (harmless before
    /// the first `recordInstr`).
    cur_proto_id: u32 = 0,
    /// Deferred (sunk) stores: in-bounds `astore`s that follow an `aload` and
    /// present-cell `hstore`s that follow an `hload` (read-modify-writes). Rather
    /// than abort the trace (the old C1 rule), `recArraySet`/`recHashSet` record
    /// each store's address + guards inline but stash the store node itself here;
    /// `commit()` flushes them — *front-to-back, in the
    /// recorded (tier-0 bytecode) order* — *after* every guard (incl. the `for_loop`
    /// continuation guard), just before the `.loop` terminator. Sinking them below
    /// all side-exits makes deopt-replay idempotent: any guard failure leaves *all*
    /// of them un-executed, so tier-0 re-runs the iteration along the original source
    /// path and applies exactly that path's stores once each. Flushing in recorded
    /// order keeps last-writer-wins identical between the trace and tier-0 even if two
    /// stores alias. See `docs/design/08-multi-store-sinking.md` (Gap C); doc 07 is
    /// the single-store original (Gap B).
    ///
    /// A later array or hash read consults this virtual store buffer
    /// newest-to-oldest (`forwardPendingArrayLoad`/`forwardPendingHashLoad`):
    /// must-alias loads forward the pending value, proven-non-alias loads read the
    /// heap behind guards, and ambiguous table identity aborts fail-closed. Appends
    /// still abort because they mutate array shape. The list is naturally bounded
    /// by `maxrecord`; native register pressure spills or rejects the completed trace.
    pending_stores: std.ArrayListUnmanaged(PendingStore) = .empty,

    // --- deterministic on-trace allocation (doc 24 D3/D4) -------------------
    /// Count of `.alloc`-kind ops emitted so far — the allocation bound `A`.
    /// `commit()` stamps it into the entry `guard_gc`'s `aux` and the committed
    /// `Trace.alloc_bound`. Each `.alloc` op's helper performs at most one
    /// `Heap.link` (the D5 audit rule), so `A` bounds the burst's worst-case
    /// id consumption per iteration.
    alloc_count: u32 = 0,
    /// Emission ref of the single entry `guard_gc`, emitted by `emitAlloc`
    /// immediately before the FIRST `.alloc` op (which places it before every
    /// `.alloc` op — the only ordering the D3 argument needs: effects that
    /// precede it are already header-replay-idempotent under the C1 discipline,
    /// and a failing `guard_gc` means zero allocations were performed this
    /// iteration, so the D2 clean-replay premise holds). Null for a
    /// non-allocating recording (no `guard_gc` at all — arc-A traces unchanged).
    guard_gc_ref: ?Ref = null,

    // --- cross-frame tracing (inlined Lua calls) ---------------------------
    /// The anchor (outermost) frame's register count. The grown `reg_map` may be
    /// wider (it reserves space for inlined callee frames), so the executor's real
    /// register window is `[0, anchor_num_registers)`. `assertWellFormed` pins
    /// every `slot_load`/`phi` slot below this bound (S3), and `commit()` caps φ
    /// writeback to it (S2): callee slots are pure internal SSA temporaries, dead
    /// at the loop boundary, never loop-carried.
    anchor_num_registers: u16 = 0,
    /// Absolute slot offset of the frame currently being recorded, relative to the
    /// anchor frame's base. 0 for the anchor frame; `caller_base_off +
    /// caller_proto.num_registers` for an inlined callee. `refOf`/`setReg` add it
    /// to translate a frame-relative slot into a `reg_map` index, exactly as the
    /// interpreter's `callee_base = base + caller.num_registers` lays out windows.
    base_off: u32 = 0,
    /// Saved caller contexts for the currently-open inlined calls, indexed by
    /// `inline_depth - 1`. Pushed at an inlined `.call`, popped at the `.ret`.
    frames: [MAX_INLINE_DEPTH]InlineFrame = undefined,
    /// Number of inlined calls currently open (frame-stack depth). 0 at the anchor
    /// frame; a `.call` beyond `MAX_INLINE_DEPTH` aborts `.too_deep`.
    inline_depth: u8 = 0,
    /// Doc 27: frame-relative one-past-the-end of the values the immediately-
    /// preceding recorded instruction produced under `c == all_results` — the
    /// recorder's shadow of tier-0's `reg_top`/`reg_top_pending` handshake.
    /// Set only by a successfully recorded producer; valid for exactly one
    /// instruction (`recordOne` stashes and clears it before dispatch, mirroring
    /// tier-0's `reg_top_pending` scope); expressed in the frame-space of the
    /// instruction that will consume it. `null` = no pending producer — every
    /// `all_results` consumer fails closed on it. `u32`, not `u16`: a valid
    /// one-past top can be 65,536 (the slab size), and a resolved count must be
    /// checked below the `all_results` sentinel before it becomes a fixed arity
    /// (doc 27 §3a). Cleared on `reset` (the soundness boundary — a `maxrecord`
    /// abort fires before the `recordOne` stash, so a stale shadow could
    /// otherwise leak into the NEXT recording) and on `abort` (defense-in-depth).
    multret_top: ?u32 = null,

    // --- cluster sub-lever 1: upvalue/global-reached callee snapshots ---------
    /// Synthetic entry inputs accumulated this recording: each loop-invariant
    /// upvalue/global the dispatch loop must re-seed before entry (see `InputSeed`).
    /// Becomes the committed trace's `inputs`.
    input_seeds: std.ArrayListUnmanaged(InputSeed) = .empty,
    /// Dedup: maps `(kind, source)` (packed `u64`) → the synthetic `slot_load`'s
    /// SSA ref, so a repeated `get_upval`/`get_global` of the same source reuses one
    /// input slot + one `guard_func` instead of emitting another.
    input_dedup: std.AutoHashMapUnmanaged(u64, Ref) = .empty,
    /// Dedup for H1 `hash_cell` seeds: maps `(table_reg, key_const)` (packed `u64`)
    /// → the synthetic slab slot, so an RMW's read+write `href`s (and repeated reads
    /// of the same field) share one seeded cell pointer instead of consuming two of
    /// the `MAX_TRACE_INPUTS` budget. Separate from `input_dedup` because the value
    /// is a raw slot (no `slot_load` ref — `href` is the consumer via its `aux`).
    hash_cell_dedup: std.AutoHashMapUnmanaged(u64, u16) = .empty,
    /// Next synthetic input slab slot to hand out. Initialised to
    /// `anchor_num_registers` in `reset` (inputs live *above* the anchor window);
    /// bumped once per unique input. The slot is only ever a `slot_load` `aux` and
    /// an executor `RegWindow` index — never a `reg_map` index — so it does not
    /// collide with the inlined-callee scratch the `reg_map` tail reserves.
    next_input_slot: u16 = 0,

    pub fn deinit(self: *Recorder, gpa: std.mem.Allocator) void {
        if (self.peel) |p| gpa.free(p.slots);
        self.pending_stores.deinit(gpa);
        self.input_seeds.deinit(gpa);
        self.input_dedup.deinit(gpa);
        self.hash_cell_dedup.deinit(gpa);
        self.instrs.deinit(gpa);
        self.consts.deinit(gpa);
        self.entry_slots.deinit(gpa);
        self.exit_prov.deinit(gpa);
        self.rec_path.deinit(gpa);
        self.guarded_refs.deinit(gpa);
        self.konst_map.deinit(gpa);
        if (self.reg_map.len != 0) gpa.free(self.reg_map);
    }

    /// Clear the buffer and arm a fresh recording for `anchor` over a frame with
    /// `num_registers` registers. Reuses retained capacity; only (re)allocates
    /// `reg_map` when the register count changes.
    pub fn reset(self: *Recorder, gpa: std.mem.Allocator, anchor: AnchorKey, num_registers: u16) !void {
        self.instrs.clearRetainingCapacity();
        self.consts.clearRetainingCapacity();
        self.entry_slots.clearRetainingCapacity();
        self.exit_prov.clearRetainingCapacity();
        self.rec_path.clearRetainingCapacity();
        self.rec_path_ok = true;
        self.guarded_refs.clearRetainingCapacity();
        self.konst_map.clearRetainingCapacity();
        self.input_seeds.clearRetainingCapacity();
        self.input_dedup.clearRetainingCapacity();
        self.hash_cell_dedup.clearRetainingCapacity();
        self.pending_stores.clearRetainingCapacity();
        self.alloc_count = 0;
        self.guard_gc_ref = null;
        // Size the register map for the anchor frame **plus** reserved windows for
        // inlined callee frames (cross-frame tracing). The executor only ever
        // touches `[0, anchor_num_registers)`; the tail is scratch the recorder
        // uses to hold callee SSA temporaries while inlining.
        const wanted: usize = @as(usize, num_registers) + MAX_INLINE_DEPTH * MAX_CALLEE_REGS;
        if (self.reg_map.len != wanted) {
            if (self.reg_map.len != 0) gpa.free(self.reg_map);
            self.reg_map = try gpa.alloc(RegSlot, wanted);
        }
        @memset(self.reg_map, .{});
        self.anchor = anchor;
        self.abort_reason = null;
        self.locals_watermark = std.math.maxInt(u32);
        self.link_target = null;
        self.pending_link_provenance = null;
        self.kind = .root;
        self.side_src = null;
        self.anchor_num_registers = num_registers;
        self.base_off = 0;
        self.inline_depth = 0;
        self.multret_top = null; // doc 27 §3a: never inherit a stale shadow
        if (self.peel) |p| gpa.free(p.slots);
        self.peel = null;
        self.unrolled_while = false;
        self.next_input_slot = num_registers;
        self.active = true;
    }
};
