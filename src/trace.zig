//! Trace recorder, trace IR, and the trace lifecycle — the heart of the JIT.
//!
//! A tracing JIT works by watching tier-0 execute, noticing when a loop runs
//! *hot*, and **recording** one iteration of that loop into a linear,
//! single-assignment IR specialised to the types it actually observed. The
//! execution tiers (`irinterp.zig`: tier-1a IR interpreter; `nativegen.zig`:
//! tier-1b native codegen) *execute* that IR. Recording is deliberately
//! *transparent* — tier-0 still performs every operation, so a program's
//! observable behaviour is identical whether the recorder is on or off. That
//! invariant is the recorder's decisive correctness test (`interp.zig`, the
//! `expectProgram` matrix).
//!
//! What lives here:
//!   * the **trace IR** — `IrOp`/`IrInstr`/`Trace`, plus a disassembler. This is
//!     the cache-sensitive representation the architecture reserves for the JIT
//!     (docs/design/00-architecture.md §Value representation), kept separate from
//!     the tier-0 bytecode (`bytecode.zig`).
//!   * the **recorder** — `TraceState` (hotness counters, the trace cache, and
//!     the in-progress `Recorder`) and its state machine (`onBackEdge`).
//!   * the **lifecycle machinery** that grew around them: side traces and hot-exit
//!     wants, the peel (doc 39/40), chain/burst dispatch (`driveChain`,
//!     `replayLedger`), native link arming and exit-branch patching (doc 17),
//!     regions and provenance, gates/backoff, and cache invalidation.
//!
//! Policy is set by docs/design/01-trace-lifecycle.md and refined by docs 15-40.

const std = @import("std");
const bytecode = @import("bytecode.zig");
const arith = @import("arith.zig");
const value = @import("value.zig");
const function = @import("function.zig");
const regwindow = @import("regwindow.zig");
const RegWindow = regwindow.RegWindow;
const io = @import("io.zig");
const tropt = @import("tropt.zig");
const execlog = @import("execlog.zig");
const nativegen = @import("nativegen.zig");
const irinterp = @import("irinterp.zig");
const jitdbg = @import("jitdbg.zig");
const Value = value.Value;
const Proto = bytecode.Proto;
const Instr = bytecode.Instr;
const OpCode = bytecode.OpCode;
const table_mod = @import("table.zig");
const arr = @import("array.zig");
const string_mod = @import("string.zig");
const gc = @import("gc.zig");
// Doc 30 c4: the recorder's P2/P3 surface — the SAME pure cores tier-0 and
// the shims run (census, locate, init resolution), never a re-derivation.
const string_stdlib = @import("stdlib/string.zig");
const pattern_mod = @import("stdlib/pattern.zig");

// ---------------------------------------------------------------------------
// Trace IR
// ---------------------------------------------------------------------------
// The IR core lives in the leaf module `trace_ir.zig` (file-split pass).
// Re-exported here so every existing `trace.X` spelling keeps resolving and
// the move stays behaviour-free.

pub const trace_ir = @import("trace_ir.zig");
pub const trace_link_mod = @import("trace_link.zig");
pub const trace_regionops_mod = @import("trace_regionops.zig");
pub const trace_chain_mod = @import("trace_chain.zig");
pub const trace_recorder_mod = @import("trace_recorder.zig");

pub const Ref = trace_ir.Ref;
pub const SnapIdx = trace_ir.SnapIdx;
pub const ObsType = trace_ir.ObsType;
pub const IrOp = trace_ir.IrOp;
pub const PHI_INTERNAL = trace_ir.PHI_INTERNAL;
pub const IrInstr = trace_ir.IrInstr;
pub const guardExitPc = trace_ir.guardExitPc;
pub const isSideExitGuardOp = trace_ir.isSideExitGuardOp;
pub const ChargeKind = trace_ir.ChargeKind;
pub const guardSourcePc = trace_ir.guardSourcePc;

// -------------------------------------------------------------------------
// Trace-graph identities and the region data model live in leaf modules now
// (`trace_types.zig`, `trace_region.zig`). Re-exported here so every existing
// `trace.X` spelling keeps resolving and the move stays behaviour-free.
// -------------------------------------------------------------------------

pub const trace_types = @import("trace_types.zig");
pub const trace_region = @import("trace_region.zig");

pub const CallEdge = trace_types.CallEdge;
pub const Polarity = trace_types.Polarity;
pub const GuardRole = trace_types.GuardRole;
pub const OperandDesig = trace_types.OperandDesig;
pub const GuardProvenance = trace_types.GuardProvenance;
pub const LinkTerminalProvenance = trace_types.LinkTerminalProvenance;
pub const ExitProvenance = trace_types.ExitProvenance;
pub const ExitProvEntry = trace_types.ExitProvEntry;
pub const ExitKey = trace_types.ExitKey;
pub const ProgramPoint = trace_types.ProgramPoint;
pub const StructuralEdgeId = trace_types.StructuralEdgeId;
pub const AnchorKey = trace_types.AnchorKey;
pub const MAX_INLINE_DEPTH = trace_types.MAX_INLINE_DEPTH;
pub const exitOrder = trace_types.exitOrder;
pub const exitProvEntryLess = trace_types.exitProvEntryLess;

pub const RegionId = trace_region.RegionId;
pub const RegionKey = trace_region.RegionKey;
pub const RegionAccum = trace_region.RegionAccum;
pub const RegionDestination = trace_region.RegionDestination;
pub const RegionContext = trace_region.RegionContext;
pub const RegionClassifier = trace_region.RegionClassifier;
pub const RegionBridgeDef = trace_region.RegionBridgeDef;
pub const RegionDef = trace_region.RegionDef;
pub const RegionInternMap = trace_region.RegionInternMap;
pub const ObserverSpan = trace_region.ObserverSpan;
pub const ObserverFast = trace_region.ObserverFast;
pub const ObserverHot = trace_region.ObserverHot;
pub const freeRegionBridges = trace_region.freeRegionBridges;
pub const cloneRegionBridges = trace_region.cloneRegionBridges;
pub const freeRegionSetMap = trace_region.freeRegionSetMap;
pub const RegionSetBuilder = trace_region.RegionSetBuilder;
pub const programPointsEqual = trace_region.programPointsEqual;
pub const appendUniqueSlot = trace_region.appendUniqueSlot;
pub const programPointLess = trace_region.programPointLess;

/// Remap the recorder's dense, emission-indexed exit-provenance table (A-i.1) into
/// the committed trace's compact, sorted `[]ExitProvEntry`, keyed by committed
/// instruction index. `old_to_new` is `tropt`'s compaction map (emission index →
/// committed index, `null` for a dropped instr); pass `null` for the identity map
/// (the `dupe` path — link + unoptimized traces preserve indices 1:1). Only
/// non-`null` provenance whose instruction survived compaction is carried over
/// (the many-to-one dedup already happened at stamp time).
///
/// `link_terminal` (A-i.4) carries the `.link` terminal's provenance and its
/// committed index. The `.link`/`.loop` terminal is appended directly to `instrs`
/// at commit — it never went through `emit`, so it has NO lockstep `rec_exit_prov`
/// slot; it is injected here as one extra entry. `null` for every non-link trace
/// (a `.loop` terminal is a back-edge, not an exit).
///
/// Returns a static empty slice when there is nothing to carry (no alloc). Caller
/// owns the result.
/// Populate `t.bridge_cand` / `t.bridge_cand_built` by evaluating the pure
/// `nativegen.isCompositeBridgeCandidate` oracle once per instruction index
/// (doc 17 §T.9). Call once, at commit, after `t` is fully populated.
///
/// FAIL-SOFT by design: on OOM the memo is simply left unbuilt and
/// `Trace.isBridgeCandidate` falls back to the oracle. There is deliberately no
/// error return — a commit must never fail because an accelerator could not be
/// allocated.
pub fn buildBridgeCandMemo(gpa: std.mem.Allocator, t: *Trace) void {
    if (t.instrs.len == 0) {
        // Nothing to memoize, but mark it built: the oracle returns false for every
        // index on an empty trace, which an empty bitset reproduces exactly.
        t.bridge_cand_built = true;
        return;
    }
    const bytes = gpa.alloc(u8, (t.instrs.len + 7) / 8) catch return;
    @memset(bytes, 0);
    for (0..t.instrs.len) |i| {
        if (nativegen.isCompositeBridgeCandidate(t, i))
            bytes[i >> 3] |= @as(u8, 1) << @intCast(i & 7);
    }
    t.bridge_cand = bytes;
    t.bridge_cand_built = true;
}

pub fn buildExitProv(
    gpa: std.mem.Allocator,
    rec_exit_prov: []const ?ExitProvenance,
    old_to_new: ?[]const ?Ref,
    link_terminal: ?ExitProvEntry,
) ![]ExitProvEntry {
    if (old_to_new) |m| std.debug.assert(m.len >= rec_exit_prov.len);
    var count: usize = if (link_terminal != null) 1 else 0;
    for (rec_exit_prov, 0..) |p, i| {
        if (p == null) continue;
        const survived = if (old_to_new) |m| m[i] != null else true;
        if (survived) count += 1;
    }
    if (count == 0) return &.{};
    const out = try gpa.alloc(ExitProvEntry, count);
    errdefer gpa.free(out);
    var k: usize = 0;
    for (rec_exit_prov, 0..) |p, i| {
        const prov = p orelse continue;
        const committed: u32 = if (old_to_new) |m| (m[i] orelse continue) else @intCast(i);
        out[k] = .{ .index = committed, .prov = prov };
        k += 1;
    }
    if (link_terminal) |lt| {
        out[k] = lt;
        k += 1;
    }
    std.debug.assert(k == count);
    // Committed indices are already ascending for guards/fused producers (neither is
    // hoisted into the preheader, so compaction preserves their relative order), but
    // sort defensively so `Trace.provAt`'s binary search is correct regardless of any
    // future LICM change.
    std.mem.sort(ExitProvEntry, out, {}, exitProvEntryLess);
    return out;
}

/// Whether IR instruction `idx` of `t` is a numeric-for loop-done guard: a
/// `guard_true` whose deopt PC lands immediately after a `for_loop` bytecode op.
/// Mirrors nativegen's `isNumericForLoopDoneGuard`, kept here so the arming side can
/// enforce the P-C option (b) invariant (2.3c-0a) without reaching into codegen.
/// Returns before touching `t.anchor` when `idx` is out of range, so it is safe on
/// synthetic traces with an undefined anchor and empty `instrs`.
pub fn isLoopDoneGuardIndex(t: *const Trace, idx: usize) bool {
    if (idx >= t.instrs.len) return false;
    const g = t.instrs[idx];
    if (g.op != .guard_true) return false;
    const exit_pc = guardExitPc(g) orelse return false;
    if (exit_pc == 0 or exit_pc > t.anchor.proto.code.len) return false;
    if (t.anchor.proto.code[guardSourcePc(g).?].op != .for_loop) return false;
    // Inlined-callee corner: a callee-internal `for_loop` guard at `inline_depth > 0` has its
    // `guardSourcePc` in the callee's proto, not the anchor's. If the callee's pc
    // coincidentally maps to a `for_loop` in the anchor proto, this would falsely
    // match. Reject inlined-callee guards via the exit provenance table.
    if (t.provAt(@intCast(idx))) |prov| switch (prov) {
        .guard => |gp| if (gp.inline_depth > 0) return false,
        .link_terminal => return false, // a link terminal is never a loop-done guard
    };
    return true;
}

/// Doc 38 — the WHILE twin of `isLoopDoneGuardIndex`, returning the post-loop
/// resume PC on a match (null otherwise). A while loop compiles to
/// `<cond>; jmp_if_false <past_end>; <body>; jmp <back_to_cond>`, so its
/// loop-done exit is the CONDITION guard: a `guard_true` (recBranch pinned the
/// observed continue direction) whose source opcode is the `jmp_if_false`.
/// Classified structurally, tied to the trace's own anchor: the branch's jump
/// target must be exactly one past a backward `jmp` that returns to
/// `t.anchor.pc` — that shape IS the while loop this trace is the root of, and
/// it cannot match an inner while unrolled inside the trace (its back-edge
/// targets the inner header, not our anchor).
///
/// Two structural differences from the numeric-for loop-done:
///  * the guard sits at the trace TOP (before the body), so the failing pass
///    ran only the condition prefix — completed iterations already committed
///    at their `.loop` terminals and NO final-iteration flush is owed;
///  * the post-loop PC is the branch's JUMP TARGET, not `guardExitPc` (which
///    is the fall-through = the loop body start).
/// Same doc-37 provenance rule as the numeric classifier: an inlined-callee
/// guard's `guardSourcePc` is in the callee's proto — reject depth > 0.
pub fn whileLoopDonePostPc(t: *const Trace, idx: usize) ?u32 {
    if (idx >= t.instrs.len) return null;
    const g = t.instrs[idx];
    if (g.op != .guard_true) return null;
    const src_pc = guardSourcePc(g) orelse return null;
    const proto = t.anchor.proto;
    if (src_pc >= proto.code.len) return null;
    const br = proto.code[src_pc];
    if (br.op != .jmp_if_false) return null;
    // Post-loop pc = the branch's jump target (post-increment base, like
    // `applyJump`): `(src_pc + 1) + aux`. Must be a forward, in-bounds exit.
    const post_i: i64 = @as(i64, src_pc) + 1 + br.aux;
    if (post_i <= @as(i64, src_pc) or post_i >= @as(i64, @intCast(proto.code.len))) return null;
    const post: u32 = @intCast(post_i);
    if (post == 0) return null;
    // The instruction immediately before the post-loop pc must be this loop's
    // backward `jmp`, returning exactly to the trace's anchor (the condition).
    const back = proto.code[post - 1];
    if (back.op != .jmp) return null;
    if (@as(i64, post) + back.aux != @as(i64, t.anchor.pc)) return null;
    if (t.provAt(@intCast(idx))) |prov| switch (prov) {
        .guard => |gp| if (gp.inline_depth > 0) return null,
        .link_terminal => return null,
    };
    return post;
}

/// Doc 38: boolean twin of `whileLoopDonePostPc` for classification-only sites.
pub fn isWhileLoopDoneGuardIndex(t: *const Trace, idx: usize) bool {
    return whileLoopDonePostPc(t, idx) != null;
}

/// Doc 40 Phase 0 (codex finding 3): is a while-loop-done exit's "zero
/// completions ⇒ regs coherent at the post-loop pc" claim actually true for
/// this trace? For an ordinary trace, always — the condition guard sits at the
/// trace top, before any of the final pass's body ran (the doc 38 zero-trip
/// argument). For a PEELED trace (doc 39) the claim breaks in the STEADY
/// region: the run-once region is a real tier-0 iteration, and a
/// zero-completion deopt deliberately leaves the carried-slot boxes untouched
/// — so a steady-region loop-done firing at zero local completions has
/// *executed* (but never flushed) iteration 1, and the post-loop pc is NOT
/// coherent. Such an exit must take the ordinary deopt-replay path (tier-0
/// re-runs from the entry state), never the `.while_done` chain. A
/// run-once-region loop-done (idx before the marker) stays chain-safe: zero
/// completions there really is zero iterations.
pub fn whileDoneCoherentAtZero(t: *const Trace, idx: usize) bool {
    if (!t.peeled) return true;
    for (t.instrs[0..@min(idx, t.instrs.len)]) |ins| {
        if (ins.op == .preheader) return false; // marker precedes the exit → steady region
    }
    return true;
}

/// Doc 38: either loop-done kind — numeric-for OR while. Use at accounting
/// sites where "the loop ran to completion" matters regardless of loop shape
/// (hot-exit exclusion, receipt region-work). Kind-specific machinery (the
/// native linked materialization, `flushNumericForLoopDone`) keeps using the
/// specific classifiers.
pub fn isAnyLoopDoneGuardIndex(t: *const Trace, idx: usize) bool {
    return isLoopDoneGuardIndex(t, idx) or isWhileLoopDoneGuardIndex(t, idx);
}

/// Caller-declared intent for `armNativeLink`, enforcing the P-C option (b) invariant
/// (doc 17, 2.3c-0a): a numeric-for loop-done guard's `slot[ei]` is EXCLUSIVELY its
/// linked-materialized exit. So only a `.loop_done_linked` arm may target a loop-done
/// guard slot, and conversely `.link_terminal` / `.ordinary_guard` arms must never
/// land on one (a loop-done ordinary deopt reaches `shared_exit` through the memory-
/// staged `NativeResult.exit_target`, never through `slot[ei]`).
pub const ArmKind = enum {
    /// `.link`-terminal handoff (2.3b-1). The terminal is a `.link` op, never a guard.
    link_terminal,
    /// Ordinary source-branch guard slot (2.3c-1). Must not be a loop-done guard.
    ordinary_guard,
    /// The loop-done linked-materialized exit (2.3c-2). Must be a loop-done guard.
    loop_done_linked,
    /// Part A edge-4 bridge: a composite ordinary guard whose stub commits the
    /// dominance-scoped phi snapshot before entering the child's ordinary entry.
    region_bridge,
    /// Part S (doc 17): native SIBLING HANDOFF. An anchor-coherent ordinary deopt
    /// exit whose child is a trace at the SAME anchor as the parent — the native
    /// compilation of doc 16's coherent-anchor chain. The parent's carried-home
    /// flush leaves regs coherent at the shared anchor, so the child's ordinary
    /// entry (its own compiled prologue guards re-validating types) is exactly the
    /// state an ordinary dispatcher re-entry would have produced. Reuses the
    /// ordinary-guard slot and stub verbatim; only the arm kind and the replay
    /// production are new.
    sibling_handoff,
};

// Region-bridge arming (A-vii-d): always on since the full chain landed — the
// replay grammar (A-vii-a), the arm-time S⊆E validator (A-vii-b), the
// consumption-keyed profit gate (A-vii-c/c.1/c.2), reachable armability
// (A-vii-d.0), and the `tryArmRegionBridge` arm site in `driveChain`. The
// staged flip-switch (`region_bridge_arming_enabled`) was folded once the
// increments were history.
//
// Part S (§S) — the native sibling handoff. Always on.
//
// The mechanism: patching a hot ordinary-guard exit to jump straight into a
// same-anchor sibling's ordinary entry, fusing skip⇄continuation ping-pong into
// one native call (on nsieve it fuses the majority of dispatcher bursts).
//
// History of the soundness scare (2026-08-12/13), kept because the diagnosis
// path is instructive: an earlier revision of this comment declared the §S
// premise ("a zero-progress pre-effect deopt is coherent at the anchor")
// FALSIFIED, because the A-viii outer-cycle repro printed 108 where the unfused
// run prints 109 even after both premise halves (`exitIsPreEffect`, the
// `term_local == 0` charge filter) were in place. That verdict was wrong. The
// dropped iteration was never a register-coherence failure at the handoff at
// all — it was `replayLedger`'s TERMINAL arm resuming at the stale linked
// `link_pc` when a burst mixed `.link_terminal` rows with a later handoff row,
// so tier-0 resumed inside the previous prime's finished inner loop and the
// middle `for_loop` advanced past the in-flight iteration (the missing prime is
// 307, the first zero-trip). The fix is entry-PROVENANCE, not snapshots: a row
// whose owner was entered at its anchor (handoff successor, like a bridged
// successor) terminal-resumes at the anchor, never `link_pc` — see
// `next_entry = .via_handoff` in `replayLedger`. With that fix A-viii prints 109 with
// arming ON, the full suite is green, and all six output-identity controls
// hash byte-identical.
//
// The premise therefore stands as designed, with eligibility enforced at
// `siblingHandoffEligible`: compiled native, in-bounds, not a loop-done or
// bridge slot, not already armed, no preceding heap effect on the trace
// (`exitIsPreEffect`), and the guard must be sourced at a real conditional
// branch opcode (`jmp_if_*`) — a non-branch guard (e.g. a zero-trip loop-entry
// check sourced at `for_prep`) would ping-pong parent⇄sibling to LEDGER_CAP
// instead of committing an iteration per transition (measured: +128% on
// nsieve before the branch-source rule).
//
// Part B-2b (doc 17 §B.5): hotexit-provenance relation and disposable arm —
// always on (the `provenance_arming_enabled` flip-switch was folded).

pub const SlotStore = trace_ir.SlotStore;

/// Result of an exit-PC chain attempt. Ordinary same-loop side traces resume at
/// the caller's current loop header (`resume_pc == null`). Nested-loop link
/// chains consume a post-inner-loop continuation and therefore resume tier-0 at
/// that continuation anchor when the bounded chain yields back.
pub const ChainResult = struct {
    completed: usize,
    resume_pc: ?u32 = null,
};

/// The execution tier a chain drive uses for the candidate traces it enters.
/// Chosen at each dispatcher call site (comptime), NOT per-candidate:
///   * `.ir`          — run candidates on the tier-1a IR interpreter. Used by the
///                      ordinary zero-exit chain and the tier-1a loop-done chain.
///   * `.native_only` — run candidates as native compiled code; a candidate with
///                      no native compilation ends the drive (never silently
///                      tier-1a). Used by the native loop-done chain.
/// See `docs/design/16-coherent-state-chaining.md`.
pub const ChainTier = enum { ir, native_only };

/// How the *failed* trace left the register file when it side-exited — this fixes
/// where tier-0 must resume if the drive yields, and whether a loop-done commit is
/// still owed before a continuation can run. (Design doc 16, "exit kinds".)
///   * `.ordinary_header`       — an ordinary guard exit; `regs` are coherent at
///                                `failed.anchor.pc` and nothing is owed.
///   * `.ir_numeric_for_done`   — a tier-1a numeric-`for` loop-done exit; the final
///                                iteration's sunk stores + φ hand-off are still in
///                                the carried executor scratch (`[]Value`) and must
///                                be flushed via `flushNumericForLoopDone` before a
///                                continuation runs.
///   * `.native_numeric_for_done` — a native numeric-`for` loop-done exit; the root
///                                was entered with `runLinkedLoopDone`, so the final
///                                iteration is already materialized — no flush owed.
pub const ExitMaterialization = union(enum) {
    ordinary_header,
    ir_numeric_for_done: []Value,
    native_numeric_for_done,
    /// Doc 38: a while-loop-done exit (either tier — the tier is `driveChain`'s
    /// comptime param). The condition guard sits at the trace TOP, so the
    /// failing pass ran only the condition prefix: completed iterations already
    /// committed at their `.loop` terminals and NO flush is owed on any tier.
    /// The chain walks at the post-loop pc (`whileLoopDonePostPc`), which is
    /// the condition branch's jump target — NOT `guardExitPc`.
    while_done,
};

/// Doc 20 (patched trace entry): one registry slot binding a `.jfor_loop` or
/// `.jloop`
/// patched into a per-VM code image to its qualified root trace. Slots are
/// **stable-address** (§R2-6): each is its own heap allocation, the index in
/// `TraceState.entry_patches` is baked into the image instruction's `.b`, and
/// tombstoned slots are reused via `entry_patch_free` — never compacted.
/// Doc 20 §R4-2: per-trace entry-patch lifecycle. Suppression is split by
/// reason because the arms have different wake behaviour (§R5-2, §R6-2):
/// `.suppressed_incumbent` is woken only by its recorded incumbent's
/// tombstone; `.suppressed_capacity` by ANY tombstone; `.suppressed_permanent`
/// (not-`.compiled`, ambiguous patch pc — properties that never change) is
/// never woken, the trace simply keeps entering via the walk.
pub const EntryPatchState = enum {
    eligible,
    pending,
    bound,
    suppressed_incumbent,
    suppressed_capacity,
    suppressed_permanent,
};

pub const EntryPatch = struct {
    /// The bound root. Valid to dereference ONLY while `live` (§R7-2):
    /// `removeTrace` clears `live` through `Trace.entry_slot` BEFORE
    /// `t.destroy` frees the allocation; the drain resolves `trace_id`
    /// through `traceById` and never follows this pointer.
    trace: *Trace,
    /// Non-reused id for drain-time identity; `traceById` returning null
    /// means the trace is already destroyed (§R7-2).
    trace_id: u32,
    proto: *const Proto,
    /// Instruction index of the patched loop-closing instruction in the image.
    patch_pc: u32,
    /// Canonical content, restored on unpatch (debug-asserted identical to
    /// `proto.code[patch_pc]`, which is the ground truth anyway).
    orig: Instr,
    /// Cleared by any unpatch mark; the arm inspects it BEFORE the
    /// post-return drain, never after (§R2-4, §R7-1).
    live: bool = true,
    /// Set with `live = false` by `markEntryPatchPending`; consumed by the
    /// safe-point drain (§R5-1 same-turn).
    pending_unpatch: bool = false,
    /// Slot is dead and on (or headed for) the free-list.
    tombstone: bool = false,
    /// Non-productive patched entries since the last productive one; at
    /// `patch_strikes` the arm marks pending unpatch (§R6-1).
    strikes: u8 = 0,
    /// EntryPlan (§R1-4/6), the structural half of seeding memoized at patch
    /// time. The input-slot → seed-source map already lives on the trace
    /// (`Trace.inputs`); the only piece `seedTraceInputs` re-derives per entry
    /// is the scratch-size high-water mark (`max(num_registers, max input
    /// slot + 1)`) — memoized here. Seed VALUES are still re-resolved every
    /// entry and every fail-closed check stays in `enterSelectedTrace`; the
    /// plan is never claimed total.
    seed_count: u32,
};

/// Per-anchor cooldown record for the gate (`TraceState.gate`). An anchor that
/// thrashed (low-yield penalty maxed) or could not be traced (abort / commit
/// failure) is held off until its back-edge counter reaches `retry_at`. On the
/// retry it is given one more chance; a re-failure calls `gateAnchor` again,
/// which doubles `window` (capped at `config.backoff_max`) and bumps `strikes`.
/// At `config.max_strikes` the anchor is abandoned permanently. The schedule is
/// counted in the deterministic global back-edge `tick` (which advances on *every*
/// back-edge, including ones the hot-count pre-filter skips), so the cooldown keeps
/// elapsing while a gated anchor is being cheaply skipped, and is reproducible.
pub const Gate = struct {
    /// Global `tick` value at/after which the anchor becomes eligible again.
    retry_at: u64,
    /// Length of the *next* cooldown window (back-edges); doubles per escalation.
    window: u32,
    /// How many times this anchor has been gated; `>= max_strikes` ⇒ permanent.
    strikes: u32,
    /// Why the LAST escalation fired (doc 38 yield gate). A `.low_trip_while`
    /// dispatch gate is exempt from the clear-on-productive paths: the very
    /// receipts that would clear it (1–2-trip completions) are the evidence it
    /// gates on. It expires only via the standard cooldown, after which a
    /// probe window that clears the yield bar simply never re-gates
    /// (`noteWhileYield`). All other reasons keep doc 31 D2 semantics.
    reason: GateReason,
};

/// Doc 31 D3: why an anchor was gated — carried in the jit-debug receipt line
/// (`gate[dispatch:legacy_thrash]` vs `gate[record:record_abort]`) so a
/// receipts log self-explains which machine gated. The first three are
/// dispatch-gate sources, the last two record-gate sources (doc 31 §3).
pub const GateReason = enum {
    legacy_thrash,
    region_decay,
    native_unsupported,
    /// Doc 38 yield gate: a while anchor whose entries average below
    /// `config.while_yield_min_avg` trips over a `while_yield_window`-entry
    /// probe. Each entry is productive (a completion, often 1–2 trips, half
    /// zero-trip on fft_bitreverse) but the per-entry runtime turnstile
    /// (entry + seam re-entry; our exits are not patched branches) costs more
    /// than tier-0 running the same 0–2 iterations. Dispatch-gate source;
    /// exempt from clear-on-productive (see `Gate.reason`).
    low_trip_while,
    record_abort,
    commit_failure,
};

/// Doc 38 yield-gate accumulator (`TraceState.while_yield`): entries and total
/// completed iterations observed for one while anchor over the current probe
/// window. Both saturate; the verdict compares `iters` against
/// `entries * while_yield_min_avg` at `entries == while_yield_window`.
pub const WhileYield = struct {
    entries: u32,
    iters: u32,
};

/// Identifies a guard-failure site: the trace anchor and the bytecode PC of the
/// failing guard instruction (stored in the guard's `aux` field by the per-guard
/// PC recording, step 2).  Used to count how often a specific guard fails, so
/// side-trace recording (step 4) can be triggered at the right threshold.
pub const GuardKey = struct { anchor: AnchorKey, exit_pc: u32 };

/// Key of one burst-TERMINAL exit site (jitdbg telemetry, doc 17 Part B): the
/// (trace, exit instruction, materialization kind, outcome) whose ledger row was
/// the last of a burst — i.e. the exact site that returned control to the runtime.
pub const DbgTerminalKey = struct {
    trace_id: u32,
    exit_instr: u32,
    kind: irinterp.LedgerKind,
    outcome: irinterp.LedgerOutcome,
};

/// The kind of type a trace's entry guard enforces on a register.
pub const EntryGuardType = enum(u8) {
    int,
    float,
    number, // accepts both int and float (guard_number)
    table,
};

/// A register and the type it must have for this trace to be entered.
/// Pairs are computed from the trace's IR at commit time and stored as a
/// runtime-only fingerprint — not serialized.
pub const EntryGuard = struct { slot: u16, ty: EntryGuardType };

/// Where a synthetic trace input is resolved from at entry (cross-frame tracing,
/// cluster sub-lever 1). A callee reached through an UPVALUE or GLOBAL is a
/// loop-invariant register value the executor cannot read (it has no `*Vm`, no
/// closure). The recorder snapshots it into a dead slab slot *above* the anchor
/// frame window and reads it as an ordinary `slot_load`; the dispatch loop seeds
/// the slot once per entry (`upvalGet`/`globals.get`) before running the trace.
/// `hash_cell` (doc 11, H1): the loop-invariant **value-cell pointer** of a
/// constant-key field access (`obj.field`). Unlike `upvalue`/`global` it seeds no
/// `slot_load` — the existing `href` op consumes it (via `href.aux == slot`) — and
/// it writes a raw `@intFromPtr(cell)` into the slab payload for the **native** path
/// only; the tier-1a oracle ignores the slot and re-derives the cell from `href`'s
/// `(table,key)` operands each iteration (so H0's IR and exec-log behaviour are
/// frozen). Re-resolved every entry via `Table.fieldPtr`, so — like every seed — no
/// pointer is ever serialized.
pub const InputKind = enum(u8) { upvalue, global, hash_cell, callee_upvalue };

/// One synthetic entry input the dispatch loop resolves and writes into the slab
/// before trace entry. For `upvalue`/`global`: `source` is the upvalue index
/// (`closure.upvalues[source]`) or the global key's constant-pool index
/// (`proto.constants[source]`); `slot` is the synthetic frame-relative slab slot
/// (== the seeding `slot_load`'s `aux`), always `>= anchor_num_registers`. For
/// `callee_upvalue` (inlined-callee upvalues): `source` is the upvalue index in the *inlined
/// callee's* closure, and `callee_slot` is the anchor-slab slot where that
/// callee's closure lives at entry time — the seed resolves through
/// `Closure.fromHeader(regGet(base + callee_slot)).upvalues[source]`. The
/// callee's own seed (kind=`upvalue` or a regular `slot_load`) is always
/// earlier in the seed array, so `callee_slot` is populated before this seed
/// runs. For `hash_cell` (H1): `source` is the **key**'s constant-pool index,
/// `table_reg` is the anchor slot holding the table value, and `expected_count`
/// is the recorded `hash.count()` (the `guard_hash` aux) the seed re-checks for
/// native eligibility. Runtime-only — not serialized (precedent: `entry_guards`).
pub const InputSeed = struct {
    kind: InputKind,
    source: u32,
    slot: u16,
    /// `hash_cell` only: anchor slot the table value lives in at entry.
    table_reg: u16 = 0,
    /// `hash_cell` only: recorded `hash.count()` — the entry must match it (the
    /// native analogue of the oracle's per-iteration `guard_hash` count check), else
    /// the entry declines native and runs tier-1a (which side-exits at `guard_hash`).
    expected_count: u32 = 0,
    /// `callee_upvalue` only (inlined-callee upvalues): anchor-slab slot where the inlined callee's
    /// closure lives at entry time. The callee was already seeded (as an `upvalue`
    /// or regular `slot_load` input) before this seed, so `regGet(base +
    /// callee_slot)` is valid by the time this seed runs.
    callee_slot: u16 = 0,
};

/// Doc 22 §B.1: the per-VM native seeding context. A seeded trace's entry
/// prologue (B-ii) and `driveChain`'s tier-1a seeding twin (B-iii) resolve
/// entry inputs *from native/chain code*, where no `*Vm` argument exists — so
/// the VM publishes everything the seeding helper needs into this struct once
/// per episode (`Vm.prepareNativeEpisode`), and compiled pages bake `&ctx` as
/// an imm64. Hence it MUST be heap-allocated with a stable address: `Vm` is a
/// by-value struct that may move; this ctx may not. Owned by `TraceState`
/// (created by `Vm.initBare`, freed in `TraceState.deinit`).
///
/// Freshness: a baked `&ctx` outlives episodes, so consumers must check that
/// the ctx describes the CURRENT activation before trusting it — `proto` and
/// `call_seq` are the stamp (`stubEnterable`, B-iv). `proto == null` means "no
/// episode prepared yet" and can never read as fresh.
///
/// All pointers are `anyopaque` because trace.zig cannot name `Vm`/`Closure`/
/// `Proto` (interp.zig imports trace.zig, not vice versa); `seed_fn` (installed
/// once by `Vm.initBare`, pointing at interp.zig's C-ABI seeding twin) casts
/// them back.
pub const NativeSeedCtx = struct {
    /// `seed_fn` result grammar (u64 for C-ABI simplicity; doc 22 §B.2).
    pub const SEED_OK: u64 = 1;
    /// A hash_cell seed failed validation (metatable appeared, key vanished,
    /// `hash.count()` drifted): the entry must not run natively this episode.
    pub const SEED_HASH_DECLINE: u64 = 2;
    /// The seed slots don't fit the register slab (`base + count > capacity`):
    /// nothing was written; the candidate itself is unusable at this depth.
    pub const SEED_CAPACITY_DECLINE: u64 = 3;

    /// `*Vm`, valid for the prepared episode only.
    vm: *anyopaque = undefined,
    /// `*const function.Closure` of the anchor frame (upvalue seeds).
    closure: *const anyopaque = undefined,
    /// Anchor frame base into the register slab.
    base: usize = 0,
    /// `Vm.regCapacity()` at episode start (capacity-decline check).
    reg_capacity: usize = 0,
    /// `*const Proto` of the anchor frame — half the freshness stamp, and the
    /// constant pool for global/hash_cell key resolution. `null` ⇒ never fresh.
    proto: ?*const anyopaque = null,
    /// The anchor frame's activation token — the other half of the stamp.
    call_seq: u64 = 0,
    /// The C-ABI seeding twin (interp.zig `nativeSeedFn`): resolves the plan's
    /// ACTIVE seeds into the slab, returns SEED_OK / SEED_HASH_DECLINE /
    /// SEED_CAPACITY_DECLINE. Installed once at VM init; never reassigned.
    ///
    /// The plan travels BY VALUE (`plan_bits`, the `SeedPlan.bits` bitmap): the
    /// caller is JIT-emitted prologue code that bakes its arguments as imm64s at
    /// compile time, and `&CompiledTrace.seed_plan` has no stable address to bake
    /// (`compileImpl` returns the struct by value). `&t` and `&ctx` bake fine —
    /// committed traces are heap-allocated and immutable, the ctx is heap-allocated
    /// by design. (Recorded deviation from doc 22 §B.1's `*const SeedPlan` sketch.)
    seed_fn: *const fn (ctx: *const NativeSeedCtx, t: *const Trace, plan_bits: u64) callconv(.c) u64,
    /// The tier-1a seeding twin (interp.zig `nativeSeedTier1aFn`; doc 22 §B.3),
    /// called from `driveChain`'s chain seams (`seedForTier1a`) before each
    /// `irinterp.execute` of a seeded successor. Unlike the C-ABI plan twin it
    /// resolves the FULL input set — tier-1a's `slot_load`s read every synthetic
    /// slot; seed plans are a native-page concept (carried-heap rewrites) that
    /// never deactivates tier-1a's needs — and it is a plain Zig fn pointer (the
    /// callers are chain seams, not JIT-emitted code, so nothing is baked).
    /// Same tri-state result grammar. Optional so hand-built test ctxs that only
    /// exercise the C-ABI prologue keep compiling; consumers fail closed.
    seed_tier1a_fn: ?*const fn (ctx: *const NativeSeedCtx, t: *const Trace) u64 = null,
};

/// A completed, cached trace: the recorded IR plus the entry/exit snapshots that
/// connect it back to tier-0 register slots. The IR is immutable once
/// committed; a trace leaves the cache only wholesale (`removeTrace` /
/// `clearCache` — see the lifecycle doc).
pub const Trace = struct {
    /// Stable, monotonically-assigned identity (P-B, doc 17). Unlike the cache
    /// index (`traceIndex`, which `swapRemove` shuffles), this is assigned once at
    /// finalize from `TraceState.next_trace_id` and NEVER reused — so it can be
    /// baked into native exit code as `final_trace_id` and resolved back via
    /// `traceById` even after unrelated traces retire. Default 0 for hand-built test
    /// traces that never go through finalize (they don't chain, so id collisions are
    /// harmless — the dispatcher's id path only runs for real recorded traces).
    id: u32 = 0,
    /// Doc 20 §R7-2: back-reference to this trace's entry-patch registry slot
    /// while entry-patch-bound, else null. Lets `removeTrace` mark the slot
    /// (clear `live`, set pending) in O(1) BEFORE destruction, and lets
    /// qualification assert a trace never binds two slots.
    entry_slot: ?u16 = null,
    /// Doc 20 §R4-2: the per-trace entry-patch state machine. The receipt
    /// funnel (`accountTraceRun`) may make exactly ONE transition —
    /// `.eligible → .pending` — behind a single state compare, so a `.bound`
    /// trace's productive receipts cost one never-taken branch. Every other
    /// transition happens at the safe-point drain (`drainEntryPatchWork`) or
    /// an unpatch (`unpatchSlot`), all deterministic events.
    entry_patch: EntryPatchState = .eligible,
    /// Valid ONLY while `entry_patch == .suppressed_incumbent`: the registry
    /// slot index of the live incumbent that blocked this trace's install.
    /// Its tombstone (and only its) wakes this trace back to `.eligible`.
    entry_patch_incumbent: u16 = 0,
    anchor: AnchorKey,
    /// Doc 38 unroll-first policy: this trace's recording unrolled at least one
    /// inner-while back-edge inline. When such a trace's anchor is gated for
    /// legacy thrash, that gate is evidence unrolling does not cover this
    /// outer loop's trip variance (`unroll_fail`).
    unrolled_while: bool = false,
    /// Doc 39: this trace was committed from a type-stabilizing PEEL — its
    /// `preheader` run-once region is a real tier-0 iteration (iteration 1,
    /// original int semantics), not an LICM-hoisted invariant block. SEMANTIC
    /// state, serialized (schema v bump): the first back-edge completes TWO
    /// tier-0 iterations, and a deopt at zero local completions must leave the
    /// carried-slot boxes untouched (tier-0 replays iteration 1 from the entry
    /// state). Cannot be inferred from the marker — an LICM'd trace carries the
    /// same marker but its preheader completes ZERO iterations.
    peeled: bool = false,
    /// The straight-line IR, terminated by a `loop` instruction.
    instrs: []IrInstr,
    /// Constants referenced by `konst` instructions (may include heap values, so
    /// the collector roots these — see `Vm.collect`).
    consts: []Value,
    /// Tier-0 registers read as inputs, in `slot_load` order (the entry snapshot).
    entry_slots: []u16,
    /// Synthetic entry inputs (cross-frame tracing cluster sub-lever 1): each
    /// loop-invariant upvalue/global callee the dispatch loop must resolve and seed
    /// into a dead slab slot above the anchor window before entry. Empty for the
    /// common case (no upvalue/global-reached callee). Runtime-only — not
    /// serialized; freed in `destroy`.
    inputs: []InputSeed = &.{},
    /// Entry type guards extracted from the IR at commit time: for each register
    /// this trace guards on entry, the type it must have.  Used by
    /// `matchesFingerprint` to skip non-matching traces without a trial entry.
    /// Runtime-only — not serialized.
    entry_guards: []EntryGuard,
    /// Tier-1b native-codegen cache (Phase 8): lazily compiled machine code for
    /// this trace, or a terminal `unsupported` verdict. `unattempted` until the
    /// first native dispatch (`TraceState.nativeFor`). Runtime-only — not part of
    /// the serialized trace; the page is freed in `destroy`.
    native: nativegen.NativeState = .unattempted,
    /// Runtime counter: how many times this trace has committed a useful
    /// number of iterations (>= `min_useful`).  Used by `findTrace` to
    /// return the most-successful trace first — a stable frequency-based
    /// priority that does not thrash on alternating types.
    hit_count: u64 = 0,
    /// Consecutive native-prologue refusals for this candidate. Any body entry
    /// resets the streak; a maxed streak suppresses only this trace.
    consec_refusals: u32 = 0,
    /// Doc 24 D3: the trace's static allocation bound `A` — the number of
    /// `.alloc`-kind ops the recorded body contains (0 = non-allocating, the
    /// arc-A status quo). Mirrors the entry `guard_gc`'s `aux` (stamped from the
    /// same counter at commit, so it stays an upper bound even if the optimizer
    /// CSEs an `.alloc` away). Read by the observation blackout: while
    /// suspension/keyframe observation is armed, the dispatcher and the chain
    /// walk decline to enter any trace with `alloc_bound > 0` (doc 24 D3,
    /// codex #2). Runtime-only — not serialized (recomputable from the IR).
    alloc_bound: u32 = 0,

    /// Doc 26 D1: the IR contains `supper`/`slower`, whose heap-only kernels
    /// are sound ONLY because the session's Unicode-version pin
    /// (`Vm.unicode_version_pinned`) was committed before this trace could
    /// commit and is monotone for the VM's lifetime. Debug asserts check the
    /// pin at commit, at trace entry, and at link ARMING (a patched
    /// native→native transfer has no vm in reach; by monotonicity a pin that
    /// held at arm time holds forever after). Runtime-only, recomputable.
    requires_unicode_pin: bool = false,

    /// B-iv.3 backoff: the exit whose composite-bridge arm pipeline last ran in
    /// full and declined because the child's page was not stub-enterable.
    /// `maybeArmCompositeExit` short-circuits on a hit, so a durably
    /// non-enterable child costs ONE full pipeline run per
    /// (activation x `region_defs_gen`) instead of one per terminal composite
    /// deopt. Purely an accelerator: it can only skip work that would have
    /// declined identically, never change an arm decision that would otherwise
    /// have been made. `maxInt` = no memo. Runtime-only — not serialized.
    bridge_decline_exit: u32 = std.math.maxInt(u32),
    /// `region_defs_gen` the memo was stamped under; 0 = never stamped.
    bridge_decline_gen: u32 = 0,
    /// `region_context.call_seq` the memo was stamped under.
    bridge_decline_seq: u64 = 0,

    /// Exit provenance (doc 17, A-i / 9-B): the guest-logical identity of each
    /// side-exit / `.link` terminal, keyed by *committed* instruction index, sorted
    /// by index (alloc-once at commit — guards are a minority of instrs). Empty for
    /// hand-built test traces and until A-i.3 stamps sites. Runtime-only — transient
    /// JIT-tiering metadata, never serialized, never a `.snapshot` root. Read by the
    /// Part-A region classifier via `provAt`; freed in `destroy`.
    exit_prov: []ExitProvEntry = &.{},
    /// Whether `exit_prov` is the COMPLETE exit table (doc 17 §A8-ii, A-ii.4 fail-soft).
    /// `false` iff the commit-time `buildExitProv` OOM'd and this trace was committed with
    /// an EMPTY exit table rather than aborting the commit (same fail-soft rationale as
    /// `rec_path_complete` — a `commit` error gates the anchor and perturbs tiering, and
    /// `exit_prov` is region metadata off the tier-selection path, though the Part-A
    /// classifier and successor resolution do consume it). A
    /// truncated table means this trace contributes NO structural edges, so the whole edge
    /// graph is missing edges; region discovery then arms/mints NOTHING that pass (a
    /// dropped *boundary* edge could otherwise shrink an owner's competing-entry count and
    /// spuriously flip a region armable). Default `true`. Runtime-only — not serialized.
    exit_prov_complete: bool = true,
    /// Ordered recorded guest program-points (doc 17 §A8-ii, A-ii.3), dup'd from the
    /// recorder at commit; the membership-set basis A-ii.4 unions per region. Empty
    /// when membership was *unavailable* (a recorder-path OOM flipped `rec_path_ok`)
    /// or for hand-built test traces. Owned; freed in `destroy`. Not serialized.
    rec_path: []ProgramPoint = &.{},
    /// Whether `rec_path` is the COMPLETE recorded membership (doc 17 §A8-ii, A-ii.4
    /// fail-soft — round-14 review finding 3). `false` iff a recorder-path OOM
    /// (`rec_path_ok` flipped) OR the commit-time `rec_path` dup OOM'd truncated it, so
    /// the two "empty" cases (unavailable vs legitimately empty) are distinguishable.
    /// Region discovery fails any region containing an incomplete member CLOSED
    /// (`armable = false`) rather than minting it on truncated membership. Default
    /// `true` (a legitimately-empty path — incl. hand-built test traces — is complete).
    /// Runtime-only — not serialized.
    rec_path_complete: bool = true,

    /// Memoized `nativegen.isCompositeBridgeCandidate` (doc 17 §T.9), one bit per
    /// committed instruction index, LSB-first. That oracle is a PURE function of
    /// immutable recorded data (`instrs`, `anchor.proto.code`, `provAt`) that ends in
    /// an O(`instrs`) scan, and the seam calls it once per receipt from eight sites —
    /// 4.68% of nsieve N=9 wall-clock spent recomputing a constant. Alloc-once at
    /// commit; owned; freed in `destroy`; never serialized.
    ///
    /// `bridge_cand_built` distinguishes "not built" from "built and all-zero" — the
    /// build is FAIL-SOFT (an OOM must not abort the commit, same rationale as
    /// `exit_prov`), and hand-built test traces never go through commit at all. When
    /// false, `isBridgeCandidate` falls back to calling the oracle, so the memo is a
    /// pure accelerator: results are identical either way, by construction.
    bridge_cand: []const u8 = &.{},
    bridge_cand_built: bool = false,

    /// Memo for `TraceState.anchorPopulation`: the `countTracesAt(anchor)` result as
    /// of `TraceState.cache_gen == anchor_pop_gen`. Gen 0 = never computed (state
    /// gens start at 1). Pure accelerator — recomputed on any cache mutation.
    anchor_pop_gen: u32 = 0,
    anchor_pop: u32 = 0,

    /// Memo for `TraceState.hasNativeLoopDoneLink` — a pure function of this
    /// trace's instrs (fixed after commit), its dispatch proto (fixed: the
    /// anchor proto), and the trace cache contents (covered by
    /// `TraceState.cache_gen`). Ran per NATIVE DISPATCH before; now one gen
    /// compare in steady state. Gen 0 = never computed.
    ldl_memo_gen: u32 = 0,
    ldl_memo: bool = false,

    /// Pall's per-snapshot exit hotcount (`snap->count`, lj_trace.c
    /// `trace_hotside`): one taken-exit counter per committed instruction index,
    /// bumped by `noteTakenExit` on EVERY taken exit through that instruction.
    /// `EXIT_COUNT_DONE` (255, LuaJIT's `SNAPCOUNT_DONE`) latches once a side
    /// trace triggered by this exit commits — the exit is never counted again.
    /// Alloc-once at commit (FAIL-SOFT: an OOM leaves it empty and
    /// `noteTakenExit` bounds-checks, costing hotness, never correctness — same
    /// rationale as `bridge_cand`); empty for hand-built test traces; owned;
    /// freed in `destroy`; never serialized. Per-receipt cost is one direct
    /// byte RMW — no hashing (the Part S lesson below: a per-receipt hashmap
    /// probe was a measured 15% regression).
    exit_counts: []u8 = &.{},

    /// Part S — the sibling-handoff watch, deliberately a THREE-SCALAR, one-slot,
    /// allocation-free counter rather than a `(trace, exit) -> u32` side map.
    ///
    /// The first cut of Part S kept a `sibling_counts` hashmap keyed by `ExitKey` and
    /// resolved its owner with a `traceById` linear scan, both executed on EVERY
    /// dispatcher burst terminal (472k times on nsieve N=9). Measured: the bookkeeping
    /// cost more than the handoff saved — a 26% burst reduction that came out 15%
    /// SLOWER on the clock. The counter therefore has to be free, not merely cheap:
    ///
    ///   * one watched exit at a time (`sibling_watch_exit`), so a receipt is a `u32`
    ///     compare and an increment — no hashing, no probe, no allocation;
    ///   * eligibility is only consulted when the watch MOVES, not per receipt;
    ///   * `sibling_arms` is a COUNT, and its only per-receipt job is the `== 0` fast
    ///     reject in `hasArmedSiblingHandoff`.
    ///
    /// A count rather than a bool because a trace can have several hot exits and each
    /// deserves its own handoff. The first cut latched a bool on the first arm, which
    /// silently capped nsieve at ONE arm: exit 9 fused, and exit 16 — still terminating
    /// 304k bursts, half the remaining seam — could never be watched again. After the
    /// arm the watch resets so the next exit can qualify; an exit that is already armed
    /// is rejected by `siblingHandoffEligible`, so it cannot re-arm.
    ///
    /// Determinism is unchanged: all three are pure functions of the receipt stream,
    /// in receipt order. The one-slot watch is *less* eager than a full per-exit map
    /// (two co-hot exits qualify one after the other, not simultaneously), which can
    /// only ever DELAY an arm — never arm something a map wouldn't have.
    sibling_watch_exit: u32 = std.math.maxInt(u32),
    sibling_watch_count: u32 = 0,
    sibling_arms: u32 = 0,
    /// Single-slot INELIGIBLE-exit memo for `noteSiblingTerminal`: the last exit
    /// whose `siblingHandoffEligible` came back false. Repeat receipts at that
    /// exit are one `u32` compare instead of a full eligibility re-scan (measured:
    /// nsieve terminated 84k bursts/run at one statically-ineligible exit, each
    /// re-running the armed-links scan + bridge memo + branch-source test — ~5%
    /// wall-clock). Sound because eligibility for a fixed `(trace, exit)` is
    /// static EXCEPT for the armed-slot exclusion, so the memo is cleared wherever
    /// the arm set touching this trace changes (`clearSiblingLatch`, a successful
    /// sibling arm).
    sibling_reject_exit: u32 = std.math.maxInt(u32),

    /// Freeze-after-qualify membership memo (task #70, the runtime-seam kill): the
    /// last `regionMemberPoint(rid, anchor)` answer for this trace, keyed by
    /// `(region_defs_gen, rid)`. `replayLedger`'s frozen fast path asks "is this
    /// row's owner anchored inside the live region's footprint" once per ROW; the
    /// answer is a pure function of the trace anchor (immutable) and the region
    /// def's `member_points`/`armable` (invalidated by bumping
    /// `TraceState.region_defs_gen` at every `region_defs` mutation), so two
    /// scalars + a bool replace a per-row footprint scan. Gen 0 never matches
    /// (`region_defs_gen` starts at 1), so a fresh trace always recomputes.
    region_memo_rid: u64 = std.math.maxInt(u64),
    region_memo_gen: u32 = 0,
    region_memo_member: bool = false,

    /// Memoized `nativegen.isCompositeBridgeCandidate(self, idx)` — see `bridge_cand`.
    /// Falls back to the oracle when the memo was not built.
    pub fn isBridgeCandidate(self: *const Trace, idx: usize) bool {
        if (!self.bridge_cand_built)
            return nativegen.isCompositeBridgeCandidate(self, idx);
        if (idx >= self.instrs.len) return false; // oracle's own bound
        return (self.bridge_cand[idx >> 3] >> @intCast(idx & 7)) & 1 != 0;
    }

    /// The exit provenance at committed instruction index `idx`, or `null` if that
    /// instruction is not a tracked exit. Binary search over the sorted table.
    pub fn provAt(self: *const Trace, idx: u32) ?ExitProvenance {
        var lo: usize = 0;
        var hi: usize = self.exit_prov.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const e = self.exit_prov[mid];
            if (e.index == idx) return e.prov;
            if (e.index < idx) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    /// Free a heap-allocated trace and its arrays.
    /// LuaJIT's `SNAPCOUNT_DONE` (lj_jit.h): a side trace for this exit has been
    /// committed — stop counting it. Saturation caps at `DONE - 1` so an exit can
    /// never drift into DONE by counting alone.
    pub const EXIT_COUNT_DONE: u8 = 255;

    pub fn destroy(self: *Trace, gpa: std.mem.Allocator) void {
        self.native.deinit();
        gpa.free(self.instrs);
        gpa.free(self.consts);
        gpa.free(self.entry_slots);
        gpa.free(self.entry_guards);
        if (self.inputs.len != 0) gpa.free(self.inputs);
        if (self.exit_prov.len != 0) gpa.free(self.exit_prov);
        if (self.rec_path.len != 0) gpa.free(self.rec_path); // A-ii.3
        if (self.bridge_cand.len != 0) gpa.free(self.bridge_cand); // §T.9 memo
        if (self.exit_counts.len != 0) gpa.free(self.exit_counts); // hotexit counters
        gpa.destroy(self);
    }

    /// Check whether the current register types match this trace's entry
    /// type guards (the fingerprint).  Returns true if all guarded slots
    /// have the expected type, or if the trace has no entry guards at all
    /// (hand-built test traces, traces without type guards).
    pub fn matchesFingerprint(self: *const Trace, regs: RegWindow) bool {
        for (self.entry_guards) |g| {
            const v = regs.get(g.slot);
            switch (g.ty) {
                .int => if (!v.isInt()) return false,
                .float => if (!v.isFloat()) return false,
                .number => if (!v.isNumber()) return false,
                .table => if (!v.isHeap() or v.heapType() != .table) return false,
            }
        }
        return true;
    }
};

// ---------------------------------------------------------------------------
// Recorder + trace state
// ---------------------------------------------------------------------------

/// Why a recording was abandoned. Aborting discards the partial trace and leaves
/// tier-0 entirely untouched; the anchor may be retried later (penalty/blacklist
/// backoff is a later increment — see the lifecycle doc). `recordInstr` and the
/// state machine fill these in (Increment B).
pub const AbortReason = enum {
    /// An opcode the recorder does not yet model (tables, globals, concat, …).
    nyi_opcode,
    /// A `call`/`ret`/`halt` — cross-frame tracing is deferred.
    cross_frame,
    /// A host (`native`) call — always a trace barrier (`02-determinism.md`).
    host_barrier,
    /// The trace exceeded `maxrecord` instructions.
    too_long,
    /// An operand had a type the recorder cannot guard/model here.
    bad_type,
    /// An indexed/appended table carries a metatable, so the access may dispatch
    /// a `__index`/`__newindex` metamethod (chunk 2a). Recording aborts: the
    /// metamethod call would be a trace barrier anyway, and a present-slot raw
    /// read/store could silently skip a metamethod on a *later* iteration if the
    /// table's shape changes. Conservative and exact — these tables run tier-0,
    /// which does full metamethod dispatch. Lifting this needs a
    /// `guard_no_metatable` IR op (deferred perf follow-up).
    has_metatable,
    /// Allocation failed while building the trace.
    alloc,
    /// Cross-frame inlining exceeded `MAX_INLINE_DEPTH`. (Deep/unbounded
    /// recursion is Phase 3.) Exactly the call-nesting meaning the name says —
    /// the reservation-overflow and input-budget conditions that used to share
    /// this tag have their own reasons below (`frame_bounds`, `input_cap`), so
    /// an abort table names WHICH limit fired (the LATEST-94 misdiagnosis came
    /// from having to guess).
    too_deep,
    /// An inlined callee window (`recCall`) or a dynamic return write
    /// (`recReturn`, multret shapes) would overflow the recorder's grown
    /// `reg_map` reservation. Abort rather than panic on an OOB slab access;
    /// tier-0 owns the loop.
    frame_bounds,
    /// The synthetic entry-input machinery refused: the trace already carries
    /// `MAX_TRACE_INPUTS` upvalue/global/hash-cell snapshots (a pure-policy
    /// backstop — see the constant's comment), or the synthetic slot index
    /// would wrap its `u16`. The trace's actual usage is visible as
    /// `inputs=N/cap` in `--dump-traces`/`--dump-native`.
    input_cap,
    /// Doc 38 / LuaJIT `LJ_TRERR_LLEAVE` ("leaving loop in root trace"): a ROOT
    /// recording anchored at a `while`/`repeat` header observed its own loop's
    /// exit direction on the condition branch. A root must loop back to form a
    /// root trace — recording onward would wander into the enclosing loop and
    /// commit a rotated outer trace at the inner anchor (frequently
    /// type-unstable across the enclosing back-edge, e.g. `local k = 64` int
    /// vs the loop body's float — the analyze RV-3 bail), clogging the anchor
    /// the nested-loop continuation machinery needs for the loop-BODY root.
    /// Repeated `loop_leave` strikes at an anchor mark a low-trip-count loop;
    /// `recWhileLink` then lets an outer root unroll it (LuaJIT's
    /// `innerloopleft` fallback).
    loop_leave,
    /// Doc 39: a type-stabilizing peel (int-entry/float-body carried slots)
    /// recorded its second pass and the carried kinds STILL mismatched — a
    /// genuine per-iteration flip-flop, or a forbidden effect surfaced on the
    /// body pass (a path iteration 1 didn't take). Ordinary strike semantics:
    /// such a shape was uncompilable before the peel existed and stays so.
    type_instability,
    /// An error unwound through the dispatch loop while this recording was
    /// active (doc 26 D1a). The raise itself is not part of the recorded IR, so
    /// letting the recording survive the unwind would stitch post-catch
    /// instructions (an enclosing `pcall`'s continuation) onto the partial
    /// iteration — a Franken-path that could commit if control re-reached the
    /// anchor. Reachable today via `schar1` (records under `guard_int`, then
    /// tier-0's `string.char` raises on an out-of-range value under an
    /// enclosing pcall); `Vm.execWith`'s errdefer kills the recording at the
    /// innermost unwind instead.
    raised,
};

/// One aggregated abort, accumulated in `TraceState.abort_log` when
/// `config.record_aborts`. Rows are deduped by `(anchor.pc, reason, op)` so a
/// loop that aborts a million times collapses to a single row with a `count` —
/// the diagnostic-friendly shape ("this loop dies on `new_table`, `nyi_opcode`,
/// after 6 IR instrs, N times"). Purely informational; nothing in the tiering
/// path reads it. The `proto` pointer is borrowed (valid while the chunk is
/// alive, which it is when `--dump-aborts` prints, exactly like `--dump-traces`).
pub const AbortRecord = struct {
    /// Loop-header anchor the recording was attempting.
    proto: *const Proto,
    anchor_pc: u32,
    /// Bytecode PC of the instruction that triggered the abort (`rec.cur_pc`).
    abort_pc: u32,
    /// The tier-0 opcode being recorded when the abort fired (`rec.cur_op`).
    op: OpCode,
    /// Why the recording was abandoned.
    reason: AbortReason,
    /// How many IR instructions the partial trace had reached before aborting —
    /// "how far it got" (0 = died on the very first recorded instruction).
    ir_len: u32,
    /// How many times this exact `(anchor, reason, op)` abort recurred.
    count: u64 = 1,
};

/// Tunables for the recorder. Defaults track LuaJIT's where sensible; all are
/// overridable (tests use tiny thresholds, the CLI flips `enabled`).
pub const TraceConfig = struct {
    /// Master switch. Off by default: with this false the VM behaves exactly as
    /// it did before Phase 5 (no counting, no recording, no trace execution). The
    /// CLI `--trace` / `--dump-traces` flags and tests flip it on.
    enabled: bool = false,
    /// Whether cached traces are *executed* by the tier-1a IR-interpreter
    /// (`irinterp.zig`). On by default once `enabled`; tests set it false to get
    /// Phase-5a behaviour (record only, tier-0 executes everything) and isolate
    /// recorder bugs from executor bugs.
    execute: bool = true,
    /// Whether the trace optimizer (`tropt.zig`) rewrites a trace at commit time
    /// (constant folding, CSE, dead-code elimination). On by default; independent
    /// of `execute` (an unexecuted trace can still be optimized for inspection).
    /// Tests set it false to compare optimized vs raw IR and prove transparency.
    optimize: bool = true,
    /// Doc 39: type-stabilizing peel for int-entry/float-body plain-while
    /// roots (numeric φ widening). Off = every close is a first-return close
    /// (pre-doc-39 behaviour); tests and A/B isolation flip it.
    peel: bool = true,
    /// Back-edge count at which a loop header becomes a trace anchor.
    hotloop: u32 = 56,
    /// Maximum IR instructions in one trace before aborting (`too_long`).
    maxrecord: u32 = 2000,
    /// A trace entry that commits at least this many iterations is "doing real
    /// work" and clears the anchor's re-entry penalty. Loops shorter than this per
    /// entry are exactly where a tracing JIT wins nothing, so retiring them to
    /// tier-0 (below) costs ~nothing.
    min_useful: u32 = 8,
    /// Minimum remaining numeric-`for` trip count for a trace *entry* to be worth
    /// it. At a `for_loop` back-edge whose computed remaining iteration count is
    /// below this, the dispatch loop declines to enter the trace and lets tier-0
    /// run the short loop. This keeps a loop that is profitable for some strides
    /// (the inner nsieve loop runs `m/i` times — huge for small `i`) but trivial
    /// for others (1–7 times for large `i`) from gating its shared anchor on the
    /// trivial runs: declining entry means no `onSideExit` penalty, so the
    /// profitable long runs stay traced. Only applies to `for_loop` (a clean,
    /// computable trip count); while/repeat loops are entered as before. Set to 0
    /// to disable. Heuristic — never affects output, only tiering.
    ///
    /// DEMOTED to dead config by doc 20 Phase 1 (default 0 = disabled): the
    /// trip gate was a symptom of the per-back-edge discovery/selection
    /// cascade the patched entry removes, and the #69/#73 low-yield gate
    /// machine is the real thrash brake (full-board experiment: fft −34%,
    /// everything else in noise). Kept one release for A/B, then deleted.
    min_trip_entry: u32 = 0,
    /// Doc 20 §R6-1: consecutive non-productive patched entries (seed
    /// decline, prologue fail-closed, zero-progress exit) tolerated before
    /// the `.jfor_loop` arm marks its own slot pending unpatch — the anchor
    /// then re-decides through the virgin warming cascade (Open Q2's rebind
    /// policy is a measured follow-up). Productive entries reset the count.
    patch_strikes: u8 = 4,
    /// After this many *low-yield* trace entries (each committing fewer than
    /// `min_useful` iterations) an anchor is gated off so tier-0 owns the loop —
    /// the brake against re-entry thrash on type-unstable / branchy loops.
    max_penalty: u32 = 8,
    /// Consecutive entry refusals tolerated before suppressing this candidate.
    max_entry_refusals: u32 = 32,
    /// Part B-2b: complete-ledger zero-progress alternations tolerated before
    /// retiring the logical provenance edge and its disposable physical arm.
    max_edge_strikes: u8 = 3,
    /// Gate-fix arc (2026-08-12, codex BLOCKER 2): a QUALIFIED activation's
    /// consumed zero-work receipts are intra-complex transitions, but a streak
    /// of this many with NO intervening credited work is decay — it flushes one
    /// synthetic low-yield strike through the window gate machine and restarts.
    /// Sized so healthy branchy fusion (nsieve: a handful of barren transitions
    /// per credited scan segment) never trips it, while a barren-only spin is
    /// gated within `max_barren_run * max_penalty` receipts. Deterministic —
    /// a pure function of receipt counts.
    max_barren_run: u32 = 64,
    /// Freeze-after-qualify (task #70): consecutive useful windows after which a
    /// live activation FREEZES and `replayLedger` prices its member→member ledger
    /// rows through the allocation-free direct-credit fast path instead of the
    /// full classify/choose/destination hash pipeline. 2 = one window to qualify
    /// (`useful_window_seen`), one more to prove it wasn't a fluke. Any strike
    /// unfreezes. Heuristic — never affects output, only tiering cost.
    freeze_windows: u32 = 2,
    /// Enables production discovery/publication of silent exit cycles. Kept as
    /// an explicit gate while B-3 coverage is measured and hardened.
    silent_promotion_enabled: bool = true,
    /// Maximum promoted transitions executed by one native call before the
    /// universal silent drain regains control. This replaces the ordinary
    /// eight-hop steering bound only while a promoted set is active.
    silent_budget: usize = 4096,
    /// Number of identical, consecutive full-ledger cycle detections required
    /// before publishing a promotion.
    promote_after: u32 = 4,
    /// Gate backoff (replaces the old permanent blacklist). When an anchor is
    /// gated (low-yield penalty maxed, a recording abort, or a commit failure) it
    /// is held off tier-1 for a *cooldown window* measured in back-edges, after
    /// which it is retried once. Each re-failure doubles the window — a
    /// temporarily-unstable loop recovers cheaply, a hopeless one is retried
    /// exponentially less often. The window is keyed on the deterministic
    /// per-anchor back-edge counter, never wall-clock or RNG, so the retry
    /// schedule is reproducible (mahina determinism). `backoff_base` is the first
    /// window; it doubles up to `backoff_max`.
    backoff_base: u32 = 128,
    /// Cap on the doubling cooldown window (back-edges).
    backoff_max: u32 = 1 << 16,
    /// After this many gate escalations on one anchor, give up permanently (the
    /// loop has proven hopeless — e.g. a host call in the body that aborts every
    /// recording, or strict alternation no straight-line trace can amortize).
    max_strikes: u32 = 6,
    /// Doc 38 LLEAVE retry budget (LuaJIT `innerloopleft` analog, but reason-
    /// specific where LuaJIT's penalty slot conflates less). A `loop_leave`
    /// abort below this per-anchor count does NOT strike the record gate — the
    /// anchor silently retries at its next hot event, because which pass a
    /// recording lands on (cond-true → the loop-body root we want, cond-false
    /// → LLEAVE) is a race against the loop's trip pattern, not evidence the
    /// loop is untraceable. At/past the budget the loop has PROVEN a low/zero
    /// remaining-trip pattern: `loop_leave` starts striking the gate normally
    /// AND `recWhileLink` lets an enclosing root unroll the loop instead of
    /// aborting LINNER. Deterministic — a pure per-anchor abort count.
    lleave_fast_retries: u32 = 8,
    /// Doc 38 unroll-first policy: proven unroll failures at one OUTER anchor
    /// (recording aborts while unrolled + thrash gates on committed unrolled
    /// roots) before `recWhileLink` stops unrolling there and decomposes into
    /// inner-root + link (LINNER). 2 = LuaJIT `innerloopleft` penalty parity.
    unroll_fail_flip: u32 = 2,
    /// Doc 38 glue-sibling eligibility: maximum observed average trips/entry
    /// (from the `while_yield` accumulator) at which a while anchor's
    /// loop-done exit still accrues side-trace hotness — i.e. may grow the
    /// cond-false GLUE sibling (`guard_false → outer body → loop`, the
    /// figure-eight). Cost model: the glue fusion's benefit is amortizing the
    /// per-instance entry+seam turnstile, which dominates only for low-trip
    /// whiles (nest avg 5: glue = 78 cyc/it vs 137 decomposed; fft avg 1.5).
    /// For high-trip whiles the body loop already amortizes the seam and the
    /// glue family is measured pure downside (nsieve-bit-fp avg ~30+: glue
    /// formation was a 2.7× bench regression vs the root+link chain). Below
    /// the minimum sample (8 entries) hotness does not accrue (conservative:
    /// glue formation defers until the trip pattern is observed).
    while_glue_max_avg: u32 = 8,
    /// Doc 38 yield gate probe window: how many while-loop-done ENTRY receipts
    /// are accumulated per anchor before the average-trip verdict. Small enough
    /// that a hopeless turnstile (fft_bitreverse: 25.5M entries/run at ~1.5
    /// trips avg) gates within noise; large enough that a bursty-but-healthy
    /// while (mixed zero-trip and long instances) shows its true average.
    while_yield_window: u32 = 64,
    /// Minimum average trips per entry (integer, compared as
    /// `iters < entries * min_avg`) a while anchor must sustain over a probe
    /// window to stay dispatched. Below it, entering the trace costs more in
    /// runtime turnstile (entry + seam) than tier-0 running the same 0–2
    /// iterations, so the anchor is dispatch-gated (`.low_trip_while`).
    /// Recovery is probe-based: post-cooldown windows that clear the bar
    /// never re-gate. Pure deterministic counters — no clocks, no RNG.
    while_yield_min_avg: u32 = 3,
    /// Guard-failure count at which a side trace is recorded for this
    /// `(anchor, exit_pc)` pair.  When a guard at PC X in a trace anchored
    /// at A fails this many times, the next back-edge to A arms a new
    /// recording that captures the alternate path through the loop body.
    hotguard: u32 = 50,
    /// LuaJIT-faithful hot-exit threshold (lj_jit.h `JIT_P_hotexit` = 10, consumed
    /// by `trace_hotside`, lj_trace.c:798): the number of TAKEN exits through one
    /// `(trace, exit_instr)` — productive or not — before a side trace is wanted
    /// there. This is Pall's model verbatim: every taken exit increments the
    /// exit's own counter (`snap->count`); segment productivity is never
    /// consulted; a successful side-trace commit latches the counter to DONE
    /// (`SNAPCOUNT_DONE`) so the exit is never counted again. See
    /// `noteTakenExit`.
    hotexit: u8 = 10,
    /// Maximum distinct traces cached per anchor before `countGuardFailure` /
    /// `countFingerprintMiss` stop counting (i.e. before side-trace recording at
    /// that anchor is refused). Four remains the economic bound until native exit
    /// branches can jump directly into side traces without a runtime sibling walk.
    max_traces_per_anchor: usize = 4,
    /// Record a per-trace **execution log** (`execlog.zig`) for the visualizer's
    /// iteration animation. Off by default (zero cost on the JIT path — the executor
    /// is comptime-specialized); the wasm playground flips it on. Independent of
    /// `execute` (it observes the same executor run).
    record_exec_log: bool = false,
    /// Exec-log detail cap: per trace entry, stop recording per-iteration events once
    /// this many iterations have committed (the side-exit is still recorded; the
    /// entry's `iterations` stays accurate). Bounds the spinning detail.
    exec_log_max_iters: u32 = 16,
    /// Exec-log entry cap: stop recording new entries (exit ramps) for a trace beyond
    /// this many. Bounds total volume for an oft-entered trace.
    exec_log_max_entries: u32 = 64,
    /// Tier-1b: compile a hot trace to native x86-64 machine code (`nativegen.zig`)
    /// and run that instead of the tier-1a IR-interpreter. Off by default; the CLI
    /// `--jit-native` flips it on. x86-64/Linux only — elsewhere (incl. wasm) the
    /// compiler bails and the trace silently stays on tier-1a. Mutually exclusive
    /// with `record_exec_log` (the viz instrumentation observes the interpreter).
    native_codegen: bool = false,
    /// Record an **abort log** (`TraceState.abort_log`): every recording that is
    /// abandoned appends/bumps a row keyed by `(anchor, reason, triggering
    /// opcode)`, with the partial IR length reached. Off by default (the abort
    /// path stays a single field write); the CLI `--dump-aborts` flips it on so a
    /// loop that never tiers up can be diagnosed (which opcode/reason kills it, and
    /// how far the trace got). Diagnostic only — never affects tiering or output.
    record_aborts: bool = false,
    /// Runtime gate for the compile-gated live JIT debug log (`src/jitdbg.zig`).
    /// Only meaningful in a `-Djit-debug=true` build (otherwise every jitdbg call
    /// site is compiled out and this bool is inert). The CLI `--jit-debug` flag
    /// sets it; tests set it on exactly the VM under investigation. Diagnostic
    /// only — stderr, never program output.
    debug_log: bool = false,
    /// Runtime gate for JIT execution-coverage accounting (native-vs-tier-0 loop
    /// iterations + TSC time, per anchor). Off by default; when off the added cost is
    /// a handful of predictable, well-predicted branches (at the back-edge, trace-exec
    /// entry/exit, and each `onSideExit`) that skip all the counting — no map op,
    /// counter, or `rdtsc` runs. Set by the CLI `--jit-coverage`/`--jit-stats` flags
    /// (NOT `--time`, which stays uninstrumented so its timing is clean) and forced on
    /// by the WASM entry (the viz always instruments). When on, each interpreted
    /// back-edge is classified covered/uncovered via the per-anchor `has_trace` flag
    /// (O(1), no `findTrace` scan) and charged its cycles, and trace runs add their
    /// committed iteration count + bracketed cycles. Diagnostic only — never affects
    /// tiering, hot-counts, gating, snapshots, replay, or output; the report and the
    /// nondeterministic TSC values go only to stderr.
    coverage: bool = false,
};

/// Direct-mapped hot-count table size (a power of two). A back-edge hashes its
/// `(proto, pc)` into this many `u16` slots; the table is a cheap pre-filter that
/// lets a *gated* anchor skip the per-back-edge hashmap bookkeeping in
/// `onBackEdge` entirely (it just decrements a slot and bails). Sized generously
/// — any real program has a handful of hot loops, so collisions (two anchors
/// sharing a slot) are rare and, when they happen, only cost extra slow-path
/// visits, never correctness. 2^11 = 2048 slots = 4 KiB inline in `TraceState`.
const HOTCOUNT_BITS = 11;
const HOTCOUNT_SIZE = 1 << HOTCOUNT_BITS;
/// Skip window installed on a *gated* anchor: the number of back-edges its
/// hot-count slot suppresses before the slow path re-checks the gate. Kept modest
/// so a transiently-gated loop whose cooldown elapses still re-enters its trace
/// within a small, bounded number of iterations (recovery responsiveness) while
/// still cutting the per-back-edge cost of a permanently-dead loop by ~this factor.
const GATE_SKIP: u16 = 64;

/// Hash `(proto, pc)` into a hot-count slot. Pointer-based, like the existing
/// `AutoHashMap(AnchorKey, …)` keys — trace timing already varies across runs by
/// address, which is sound because the trace cache is runtime-only state (never
/// serialized) and traces are output-transparent (== tier-0). A collision only
/// changes *which* back-edges take the slow path, never the result.
inline fn hotIndex(proto: *const Proto, pc: u32) usize {
    // Mix in u64 explicitly: the golden-ratio constant is 64-bit, so a `usize`
    // accumulator overflows on a 32-bit target (wasm32). On a 64-bit target this is
    // byte-identical to the old `usize` math (usize == u64); the final mask keeps
    // the result within `HOTCOUNT_SIZE`, so the `@intCast` back to usize is safe.
    var h: u64 = @intFromPtr(proto);
    h ^= @as(u64, pc) *% 0x9E3779B97F4A7C15;
    h ^= h >> 29;
    return @intCast(h & (HOTCOUNT_SIZE - 1));
}

/// One armed native link (P-E, doc 17 Increment 2.3): `parent`'s frameless exit slot
/// at `slot_index` currently jumps straight into `child`'s body. Keyed by trace
/// identity (not a raw slot address) so lifetime resets stay valid no matter which
/// end retires first — the slot address is re-derived from the live `parent` at reset.
pub const NativeLink = struct {
    parent: *Trace,
    slot_index: u32,
    child: *Trace,
    /// A-vii-d.1: the arm kind is part of the record so replay can validate a
    /// `.region_bridge` row against the exact provenance that armed it (review
    /// blocker 3: never a global historical `region_defs` scan).
    kind: ArmKind,
    /// Set only for `.region_bridge` arms: the exact live region the arm was
    /// proven against. Every discovery rebuild disarms region-bridge links whose
    /// region is no longer live-armable (fail-closed on topology transitions).
    region_id: ?RegionId = null,
    /// `region_defs_gen` at the moment the `.region_bridge` arm pipeline last
    /// fully validated this link (`tryArmRegionBridge` stamps it with
    /// `region_id`). The already-armed early-out in `maybeArmCompositeExit`
    /// honors the arm only while this gen is current: a discovery rebuild
    /// replaces `def.bridges`/membership under the same region id without
    /// touching the link (the stale-link sweep checks region LIVENESS, not the
    /// exact bridge proof — codex review of f613c98), so a gen mismatch forces
    /// one full re-validation instead of trusting obsolete provenance forever.
    armed_gen: u32 = 0,
    /// Replay-walk memo for `.region_bridge` rows: the unique registered edge the
    /// slow resolution (provAt → def lookup → members scan, all release-panicking)
    /// produced, stamped with `region_defs_gen`. On a gen match the row grammar
    /// validates the successor against this edge directly — the defs have not
    /// changed since the full proof ran, so every slow-path verdict is unchanged
    /// by construction. Gen 0 = never resolved (state gens start at 1).
    bridge_edge: ?StructuralEdgeId = null,
    bridge_edge_gen: u32 = 0,
};

pub const PromotedEdge = struct {
    parent: *Trace,
    exit: u32,
    kind: nativegen.ExitPatchKind,
    child: *Trace,
    arm_kind: ArmKind,
    resume_pc: u32,
};

/// B-3d (doc 17 §B3.16 D2): the promoted unit is the frozen region's armed-edge
/// SET in canonical (parent id, exit) order — no ring order exists and none is
/// stored. A ring is just a set whose automaton happens to be periodic; every
/// per-edge fact reporting needs is MEASURED into `summary` by the epilogues
/// (`firings`/`last_ordinal`/`last_productive_ordinal`), never reconstructed
/// from position.
// pub for trace_chain.zig (file-split pass)
pub const PromotedSet = struct {
    edges: []PromotedEdge,
    summary: []nativegen.SilentSummaryCell,
    metadata: []nativegen.SilentExitMetadata,
    region_key: RegionKey,
    id: u32,
};

const PromotionRejects = struct {
    bridge_member: u64 = 0,
    region_mismatch: u64 = 0,
    open_chain: u64 = 0,
    no_patch_point: u64 = 0,
    child_mismatch: u64 = 0,
    cap: u64 = 0,
    /// B-3d (§B3.17 R1): `promoteSet` refused because the region already owns a
    /// live set — one set per region key is an ENFORCED invariant, and candidacy
    /// must restart from fully-reporting windows after the owning set demotes.
    region_owned: u64 = 0,
};

const PromotionDemotions = struct {
    activation: u64 = 0,
    region_close: u64 = 0,
    slot_mutation: u64 = 0,
    trace_invalidation: u64 = 0,
    teardown: u64 = 0,
    /// B-3d.1 (doc 17 §B3.17 R2): a low-yield window verdict unfroze the region's
    /// accumulator, so its live promotion was demoted in the same act — patches
    /// never outlive the frozen state that justified them, and the drain's
    /// frozen-accumulator check stays a true invariant instead of a latent crash.
    unfreeze: u64 = 0,
    /// B-3d (§B3.17 R1): a NEW armable member edge armed into a region that owns
    /// a live set — the set no longer covers the region's armed-edge population,
    /// so it demotes and candidacy regrows with the region-total candidate.
    membership_growth: u64 = 0,
};

/// Part B-2a (doc 17 §B.5): the persistent logical relation between the
/// side exit that caused a side trace to be recorded and that committed child.
/// The physical sibling-handoff arm is disposable; this relation survives it.
/// B-2b creates these at registered side-trace commit and republishes their
/// disposable physical arms at dispatcher safe points.
pub const ProvenanceEdge = struct {
    parent_id: u32,
    exit_instr: u32,
    child_id: u32,
    strikes: u8 = 0,
};

pub const ProvenanceAction = enum { strike, reset };

pub const ProvenanceVerdict = struct {
    parent_id: u32,
    exit_instr: u32,
    child_id: u32,
    action: ProvenanceAction,
};

const SilentProvenanceEvidence = struct {
    parent_id: u32,
    exit_instr: u32,
    child_id: u32,
    saw_productive: bool = false,
    saw_return_without_progress: bool = false,
};

/// Per-anchor JIT execution-coverage tally (`TraceState.coverage` value). `traced`
/// = loop iterations committed by trace runs (tier-1b native, or tier-1a IR-interp)
/// anchored here; `interp` = interpreted (tier-0) back-edges taken at this anchor.
/// `has_trace` flips true once a trace is committed at this anchor (at commit, and
/// defensively on any trace run), so `noteInterpIter` can classify each interpreted
/// back-edge covered-vs-uncovered in O(1) — a single map probe it already does —
/// with no `findTrace` cache scan on the hot path. Accumulated only when
/// `config.coverage`.
///
/// `*_cycles` are the TSC (`readCycles`) time attribution, so the report can weigh
/// iterations by cost — a traced iteration is ~10-20× cheaper than a tier-0 one, so
/// iteration% badly overstates JIT effectiveness. `traced_cycles` = cycles spent
/// running trace code committed *at this anchor*, attributed per hop: every trace
/// run (direct dispatch or a `driveChain` hop) charges the span since the previous
/// hop boundary (`last_hop_tsc`) to *its own* anchor in `onSideExit`, so a chain hop
/// into an inner/continuation trace bills the inner anchor — cycles now mirror
/// iterations per anchor, not lumped onto the entry anchor. The one residual: a
/// *fused* native run that executes several hops in one mcode burst replays them
/// through `onSideExit` back-to-back after the burst, so the whole burst's cycles
/// land on the first replayed hop's anchor (genuinely unsplittable without per-hop
/// TSC reads inside mcode). `interp_cycles` = cycles of the tier-0 body iterations charged at this
/// anchor's back-edge — *self time* for an innermost loop, but it leaks the
/// outer-body-head into the innermost loop at a nesting boundary (one small span per
/// outer iteration). Both are approximate per anchor; only the aggregate split
/// (`TraceState.cycles_*` vs `run_cycles`) is exact. Zero on non-x86_64 (no TSC).
pub const AnchorCoverage = struct {
    traced: u64 = 0,
    interp: u64 = 0,
    traced_cycles: u64 = 0,
    interp_cycles: u64 = 0,
    has_trace: bool = false,
};

/// Read the CPU cycle counter (x86_64 `rdtsc`) for coverage time attribution.
/// Non-serializing — fine for coarse ratios over millions of samples, and we avoid
/// `rdtscp`/`cpuid` fences (too slow for a per-back-edge hook). Returns 0 on
/// non-x86_64 (e.g. the wasm VM), which makes every cycle delta 0 → the report shows
/// n/a time rather than garbage. Diagnostic only: the value is gated on
/// `config.coverage`, lives solely in the stderr/report path, and never feeds
/// tiering, hot-counts, snapshots, replay, or program output — so its inherent
/// nondeterminism can't leak into anything observable (docs/design/02).
pub inline fn readCycles() u64 {
    if (@import("builtin").target.cpu.arch != .x86_64) return 0;
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | @as(u64, lo);
}

/// Cycle delta `now - prev`, clamped to 0 when `now < prev`. `rdtsc` is not
/// serializing and, across a core/vCPU migration on a non-invariant-TSC box, a
/// later read can come back *smaller* than an earlier one. A raw wrapping subtract
/// would then yield a delta near `maxInt(u64)` and, through the saturating adds,
/// permanently pin the cycle totals near the maximum — corrupting the whole report.
/// Dropping the odd backward span to 0 keeps the diagnostic robust (at worst a
/// single mis-measured span is lost, not the entire run).
pub inline fn cycleDelta(now: u64, prev: u64) u64 {
    return if (now > prev) now - prev else 0;
}

/// All recorder state owned by a `Vm`: the hotness counters, the cache of
/// committed traces, and the single in-progress `Recorder`.
pub const TraceState = struct {
    gpa: std.mem.Allocator,
    config: TraceConfig = .{},
    /// Read-only heap channel for the builtin fold arms (doc 23 D2): the
    /// dispatch loop refreshes this right before every `recordInstr` call
    /// (interp.zig), the same supply-what-the-recorder-can't-reach pattern as
    /// the `resolved` parameter — never a stored self-pointer trusted across
    /// calls. Folds use it for `internedLookup` ONLY (the arc-A invariant:
    /// recording never creates a guest heap object). Null in bare test
    /// harnesses that build a `TraceState` without a VM; fold arms then abort
    /// `.bad_type` and every other recorder path is unaffected.
    rec_heap: ?*const gc.Heap = null,
    /// MUTABLE execution-heap channel (doc 24 D5): the heap the tier-1a
    /// executor's `.alloc` arms and tier-1b's baked callouts/`guard_gc`
    /// allocate against. Unlike `rec_heap` (refreshed defensively per
    /// `recordInstr`), this may be stored once: `Vm.heap` is itself
    /// heap-allocated with a stable address for exactly this purpose (see the
    /// `Vm.heap` field doc). Set by `Vm.initBare`; null in bare test harnesses,
    /// where allocating traces fail closed (tier-1a side-exits the `.alloc`
    /// arm, `compileInto` declines the page).
    exec_heap: ?*gc.Heap = null,
    /// Shared machine-code arena — all tier-1b native traces are co-located slices of
    /// this (P-D of the exit-branch-patching port, doc 17). Replaces the old one-
    /// `mmap`-per-trace model so a future increment can link trace→trace with a bare
    /// `rel32` jump. Lifetime ≥ every trace (deinited *after* the cache is freed).
    mcode_arena: nativegen.McodeArena,
    /// Doc 22 §B.1: the per-VM native seeding context (see `NativeSeedCtx`).
    /// Created by `Vm.initBare` (NOT `TraceState.init`, which stays infallible —
    /// its ~120 call sites are hand-built test states that never run native
    /// seeded entries and leave this null); freed here in `deinit`. Compiled
    /// pages bake the pointer as an imm64, so it is assigned once and never
    /// reallocated for the VM's lifetime.
    native_seed_ctx: ?*NativeSeedCtx = null,
    /// Back-edge counters keyed by loop-header anchor. Only touched on the *slow*
    /// path (when the hot-count pre-filter trips), so for a non-gated anchor it
    /// still counts every back-edge (the pre-filter leaves un-gated slots at 0),
    /// preserving the arm-at-`hotloop` timing exactly. A gated anchor's count is
    /// coarse (the pre-filter skips most of its back-edges), which is fine — the
    /// gate's own cooldown is driven by `tick`, not this.
    counters: std.AutoHashMapUnmanaged(AnchorKey, u32) = .empty,
    /// Doc 20: per-VM copy-on-patch code images (§R1 fix). Canonical
    /// `Proto.code` is NEVER mutated; the first patch into a proto clones its
    /// code here and patches mutate only the clone. ONLY the dispatch fetch
    /// reads images (`codeFor`); recorder/predicates/visualiser/keyframes
    /// read canonical by construction. Lifetime is epoch-stable (§R2-2):
    /// freed only in `dropEntryPatchState` (epoch clear / deinit), never on
    /// last-unpatch. Empty forever on an unpatched run (§T7).
    code_images: std.AutoHashMapUnmanaged(*const Proto, []Instr) = .empty,
    /// Doc 20 §R2-1/§R3-4: monotone generation bumped on every image
    /// create/publish; `execImpl` re-resolves its cached `code` local in the
    /// back-edge epilogue when this differs from the generation it cached.
    /// `u64` so wrap-aliasing is structurally unreachable.
    image_gen: u64 = 0,
    /// Doc 20 §R2-6: the entry-patch registry. Indexed by the `.b` operand of
    /// patched `.jfor_loop` / `.jloop` instructions; each slot is its own allocation
    /// (stable addresses), tombstoned + reused via `entry_patch_free`.
    entry_patches: std.ArrayListUnmanaged(*EntryPatch) = .empty,
    entry_patch_free: std.ArrayListUnmanaged(u16) = .empty,
    /// Count of pending-unpatch marks awaiting the safe-point drain. A bare
    /// counter (not a list) so `markEntryPatchPending` cannot OOM mid-grammar
    /// (§R2-4); the drain early-outs at 0 and scans slots only when dirty.
    entry_patch_dirty: u32 = 0,
    /// Monotonic global back-edge tick. Incremented on *every* back-edge in the
    /// dispatch loop — including ones the hot-count pre-filter skips — so it is the
    /// one clock that never freezes. The gate's `retry_at` cooldown is measured in
    /// these ticks, which is why a transiently-gated loop's cooldown keeps elapsing
    /// while the pre-filter is cheaply skipping its back-edges. Deterministic.
    tick: u64 = 0,
    /// Direct-mapped hot-count pre-filter (see `hotIndex`/`HOTCOUNT_SIZE`). A slot
    /// holds the number of back-edges to skip cheaply before re-consulting the slow
    /// path for the anchor(s) that hash there. Zero ⇒ take the slow path now. Set
    /// to `GATE_SKIP` when an anchor is found gated, so a dead loop's millions of
    /// back-edges cost an array decrement instead of three hashmap probes apiece.
    hotcount: [HOTCOUNT_SIZE]u16 = @splat(0),
    /// Committed traces. A linear scan is fine — the cache stays small (dozens,
    /// not thousands) and dispatch goes through per-anchor lookups.
    cache: std.ArrayListUnmanaged(*Trace) = .empty,
    /// Next stable `Trace.id` to hand out (P-B, doc 17). Monotonic; never decremented,
    /// so a retired trace's id is never reassigned and a baked `final_trace_id` can
    /// never alias a different live trace.
    next_trace_id: u32 = 0,
    /// Armed native links (P-E, doc 17 Increment 2.3). Each record is a `parent`
    /// trace whose frameless exit slot `parent.native.compiled.slots[slot_index]` has
    /// been written to jump directly into `child`'s body. Kept so a retiring trace can
    /// be made lifetime-safe: when `child` is destroyed its arena slot returns to the
    /// reuse free-list and could be overwritten by unrelated code, so every parent
    /// slot pointing at it must first be reset to `shared_exit`; and when `parent` is
    /// destroyed its slot array is freed, so its records must be dropped before any
    /// child-retire tries to write through them. `resetLinksTouching` handles both
    /// directions by trace *identity* (never a raw slot pointer), so it is correct
    /// regardless of retire order. Populated by `armNativeLink` (2.3b+).
    armed_links: std.ArrayListUnmanaged(NativeLink) = .empty,
    /// B-3b.2 silent-cycle registry. `promoted_exit_owners` is the exclusive
    /// physical-exit ownership index required by §B3.9(4); ids, rather than list
    /// indices, remain stable across swap-removal.
    promoted_sets: std.ArrayListUnmanaged(PromotedSet) = .empty,
    promoted_exit_owners: std.AutoHashMapUnmanaged(ExitKey, u32) = .empty,
    next_promoted_set_id: u32 = 1,
    promotion_candidate: []PromotedEdge = &.{},
    promotion_candidate_run: u32 = 0,
    promotion_candidate_region: ?RegionKey = null,
    /// Cycle ids queued while replay is validating the armed-link registry.
    /// Capacity is reserved before promotion publication, so queuing is infallible.
    pending_demote: std.ArrayListUnmanaged(PendingDemotion) = .empty,
    /// Part B-2b: persistent hotexit-provenance relations. Edges are expected to
    /// be few, so lifecycle operations deliberately use linear scans.
    provenance_edges: std.ArrayListUnmanaged(ProvenanceEdge) = .empty,
    /// Part B-2b drain gate: the physical sibling arms are a disposable cache,
    /// but RE-publishing is only needed after an event that could have changed
    /// what's publishable — a new edge, a disarm, or a trace retirement. The
    /// drain runs at every dispatcher safe point (per walk), so without this
    /// flag its edge×armed_links scan becomes a permanent per-walk tax
    /// (measured 5.7% of nsieve-bit wall). Set at every invalidating event;
    /// cleared by a drain pass that ends with nothing transiently deferred.
    provenance_arms_pending: bool = false,
    /// B-2b episode gate. `provenance_edges` is GLOBAL across protos, but the
    /// drain always runs inside ONE frame's episode, and a seeded child anchored
    /// in a different proto is not enterable under it. Such an edge is neither
    /// armable now nor permanently declined, so folding it into
    /// `provenance_arms_pending` (retried at every safe point) latched that flag
    /// permanently and defeated the gate it exists to keep shut. Tracked
    /// separately and re-opened ONLY when the live episode identity changes.
    provenance_arms_episode_pending: bool = false,
    /// The `liveEpisodeProto()` the last drain pass ran under. `null` (no fresh
    /// episode) is a distinct value from every proto pointer, so the pass-level
    /// staleness seam re-opens correctly too.
    provenance_drain_episode: ?*const anyopaque = null,
    /// Trace-cache mutation generation: bumped on every `cache` append/remove/clear.
    /// Keys the per-trace `anchor_pop_*` memo so hot-path anchor-population queries
    /// (`anchorPopulation`) are one compare in steady state instead of an O(cache)
    /// `countTracesAt` scan per receipt. Starts at 1 so a fresh trace's memo (gen 0)
    /// always recomputes; wrap-around collision would need 2^32 mutations inside one
    /// trace's lifetime — not reachable.
    cache_gen: u32 = 1,
    /// O(1) `traceById` index: slot `id` holds the live committed trace with that
    /// id, or null (retired / gap / never registered). Ids are monotonic and never
    /// reused (P-B), so the array only grows with commits. Maintained fail-soft: a
    /// grow-OOM at commit simply leaves the id unindexed and `traceById` falls back
    /// to the linear cache scan (hand-built test traces appended straight to
    /// `cache` take that fallback too), so results are identical by construction.
    trace_by_id: std.ArrayListUnmanaged(?*Trace) = .empty,
    /// A-vii-d.1: at most one bridge-arm request recorded by `replayLedger` when
    /// it walks a terminal composite `.deopt` row, drained by the ledger DRIVERS
    /// via `drainPendingBridgeArm` after the replay returns (never mid-walk —
    /// review blocker 5: a mid-ledger `invalidateRegion → disarmAllLinks` could
    /// erase the armed provenance later `.region_bridge` rows validate against).
    /// Cleared at every `replayLedger` entry so a stale request can never leak
    /// across ledgers.
    pending_bridge_arm: ?ExitKey = null,
    /// Part S: one-shot arm request. Set when a `Trace.sibling_watch_count` crosses
    /// `hotguard`; consumed by `tryArmSiblingHandoff` at the dispatcher's NEXT
    /// successful same-anchor trace entry — so the armed child is the trace the
    /// deterministic dispatch actually ran, never a hit-count guess made here.
    pending_sibling_arm: ?ExitKey = null,
    /// A-vii-d.1: nonzero while a `replayLedger` walk is in progress. While set,
    /// `disarmAllLinks` DEFERS (records `pending_disarm_all`) instead of
    /// mutating the armed-link registry: later rows of the very ledger being
    /// walked validate their transitions against that registry (armed-edge
    /// provenance — fused M1 / loop-done / bridge rows all prove "this jump was
    /// armed" by finding the record), and a mid-walk disarm erases the proof of
    /// transitions that already physically happened. Measured on nsieve: the
    /// region gate's `flushRegionWindow` striking to `max_penalty` on row 0 of
    /// a fused `[skip.deopt(M1), ramp.link]` ledger disarmed everything and
    /// panicked row 0's own "armed source-branch ramp" validation. The ledger
    /// DRIVERS apply the deferred disarm via `applyPendingDisarms` immediately
    /// after the walk returns, BEFORE acting on the directive — so no native
    /// code ever runs between the deferral and its application.
    replay_walk_depth: u32 = 0,
    /// The deferred `disarmAllLinks` request (see `replay_walk_depth`).
    pending_disarm_all: bool = false,
    /// Anchors currently held off tier-1 with a doubling cooldown (`Gate`). Set
    /// when a recording aborts, a commit fails, or the low-yield re-entry penalty
    /// maxes out. Unlike the old permanent blacklist, an anchor here is *retried*
    /// once its cooldown window of back-edges elapses; a re-failure doubles the
    /// window, and after `config.max_strikes` escalations it is abandoned for
    /// good. A loop that was only *temporarily* unstable (type-unstable early,
    /// then settled) recovers; see `isGated` / `gateAnchor`.
    gate: std.AutoHashMapUnmanaged(AnchorKey, Gate) = .empty,
    /// Doc 31 D1: anchors currently held off *recording* (never dispatch) with
    /// the same doubling cooldown. Set on recording aborts and commit
    /// failures — LuaJIT's `penalty_pc` analog: a failed recording backs off
    /// RE-RECORDING at its start anchor; a committed trace at the same anchor
    /// keeps dispatching. Recording eligibility consults BOTH maps
    /// (`recordingBarred`); dispatch consults only `gate`. At `max_strikes`
    /// the anchor is permanently record-blacklisted (survives trace
    /// retirement — accepted `penalty_pc` blacklist semantics, doc 31 §3).
    record_gate: std.AutoHashMapUnmanaged(AnchorKey, Gate) = .empty,
    /// Doc 38: per-anchor count of `loop_leave` aborts (a while/repeat root
    /// recording that observed its own loop's exit direction). Below
    /// `config.lleave_fast_retries` the abort is a silent retry (no record-gate
    /// strike); at/past it, the anchor is treated as a proven low-trip loop —
    /// gate strikes resume AND `recWhileLink`'s innerloopleft check lets an
    /// enclosing root unroll it. Reset wholesale with the gates (epoch
    /// boundary) so a freed proto's key never lingers.
    lleave_count: std.AutoHashMapUnmanaged(AnchorKey, u32) = .empty,
    /// Doc 38 unroll-first policy: per-OUTER-anchor count of proven unroll
    /// failures — a root recording that unrolled an inner while and then
    /// aborted, or a committed unrolled root whose anchor got gated for
    /// legacy thrash. At `config.unroll_fail_flip` the outer anchor stops
    /// unrolling and `recWhileLink` decomposes (LINNER) instead. Mirrors
    /// LuaJIT's `innerloopleft` evidence counter with the roles REVERSED:
    /// LuaJIT tries the inner root first because its side exits are patched
    /// branches; mahina's exits re-enter the runtime per inner completion, so
    /// unrolling is the profitable default (measured: unroll 17 cyc/it vs
    /// decomposed ~95 cyc/it on a bounded-variance nest) and decomposition is
    /// the escape for trip variance unrolling cannot cover (nsieve-bit-fp:
    /// decomposition 4x faster than failed unrolling). Reset wholesale with
    /// the gates (epoch boundary).
    unroll_fail: std.AutoHashMapUnmanaged(AnchorKey, u32) = .empty,
    /// Doc 38 yield gate accumulator: per-anchor (entries, iters) over the
    /// current probe window, fed by every ENTERED receipt whose exit is a
    /// while-loop-done guard (`noteWhileYield`). Reset per verdict and on the
    /// epoch boundary with the gates.
    while_yield: std.AutoHashMapUnmanaged(AnchorKey, WhileYield) = .empty,
    /// Re-entry penalty per anchor: a low-yield trace entry bumps it, a
    /// productive one clears it (doc 31 D2); at `config.max_penalty` the anchor
    /// is gated off with a doubling cooldown (`onSideExit` → `gateAnchor`).
    penalty: std.AutoHashMapUnmanaged(AnchorKey, u32) = .empty,
    /// Pure ephemeral structural-edge cache (doc 17 §A3.3 / §A8-ii, A-ii.2):
    /// `{Trace.id, exit_instr} → StructuralEdgeId`. Rebuilt WHOLESALE from the current
    /// cache at every commit AND every retirement (never surgically mutated), dropped
    /// in `clearCache`, freed in `deinit`. NOT a source of truth — consumed by the
    /// region classifier and region-bridge validation (`validateRegionBridge`).
    /// A rebuild reserves capacity BEFORE clearing the prior snapshot, so a
    /// commit-path OOM RETAINS it and a retirement-path OOM fail-closes to EMPTY
    /// (both region-neutral: an empty cache arms nothing).
    edge_cache: std.AutoHashMapUnmanaged(ExitKey, StructuralEdgeId) = .empty,
    /// Discovered region definitions keyed by interned `RegionId` (doc 17 §A3.1 /
    /// §A8-ii, A-ii.4). **Proto/VM-lifetime**: accumulated as traces commit, NEVER
    /// cleaned by `removeTrace` (a GC-physical retire must not diverge
    /// `gc_stress on/off`), cleared ONLY wholesale in `clearCache` (the epoch boundary
    /// where protos may be freed). Owns each `RegionDef`'s `members`/`member_points`.
    /// Consumed by the arming path (`armable` flips, `edgeMemberOfRegion`).
    region_defs: std.AutoHashMapUnmanaged(RegionId, RegionDef) = .empty,
    /// Invalidation generation for `Trace.region_memo_*` (freeze-after-qualify,
    /// task #70). Bumped at EVERY `region_defs` mutation — new/updated defs and
    /// every `armable` flip — so per-trace footprint-membership memos never
    /// outlive the def state they were computed against. Starts at 1 so a fresh
    /// trace's memo gen 0 can never spuriously match.
    region_defs_gen: u32 = 1,
    /// Single-slot cache of the qualified-live-activation resolution inside
    /// `qualifiedActiveMember` (task #70 seam work): the `activeRegionFor` map
    /// iteration + `region_profit.getPtr` + qualification check for one
    /// `call_seq`. `act_cache_gen == 0` means invalid; it is zeroed by
    /// `refreshObserverFast` (the single hook every `region_profit` mutation
    /// already runs through, so the cached `accum` pointer can never dangle) and
    /// by the `useful_window_seen` flip (which changes the cached verdict without
    /// mutating the map). The `region_defs_gen` half of the key covers footprint
    /// changes.
    act_cache_seq: u64 = 0,
    act_cache_gen: u32 = 0,
    act_cache: ?MemberAccum = null,
    /// Interns a region's canonical sorted INTERNAL edge SET → its `RegionId` (same
    /// Proto/VM lifetime as `region_defs`). Hash-bucketed; a hit confirmed by
    /// element-wise set equality (collision mints a distinct id).
    region_intern: RegionInternMap = .empty,
    /// Next `RegionId` to mint (monotonic; mirrors `next_trace_id`). A discovery pass
    /// that OOMs before publishing does NOT bump it — the tentative ids it staged are
    /// simply never used (ids need only be unique, not contiguous).
    next_region_id: u64 = 0,
    /// Physical classification index (doc 17 §A3.1 / §A3.3): a concrete trace exit
    /// `{Trace.id, exit_instr}` → the regions it belongs to (internal edges + boundary
    /// exits that LEAVE the region from a member anchor). **Physical + transient**:
    /// WHOLESALE-rebuilt per discovery pass AND per `removeTrace` from the surviving
    /// cache; excludes `armable == false` regions. Owns each `[]RegionId`. Queried by
    /// `classifyExit`, whose result feeds `tryArmRegionBridge`. A retirement-rebuild
    /// OOM publishes EMPTY (fail-closed — the prior set references a dead trace).
    source_exit_regions: std.AutoHashMapUnmanaged(ExitKey, []RegionId) = .empty,
    /// Physical classification index (doc 17 §A3.1): a concrete `Trace.id` → the
    /// regions entered by landing in it (destination of an internal edge; physical
    /// members only). Same lifetime/rebuild/ownership rules as `source_exit_regions`.
    dest_entry_regions: std.AutoHashMapUnmanaged(u32, []RegionId) = .empty,
    /// A-iv: persistent across physical trace retirement/re-arm, bounded by live
    /// activation lifetime and cleared on activation death / restore / epoch end.
    /// Opening a logical region is the only operation that may grow this map;
    /// the per-op observer only probes/removes existing entries.
    region_profit: std.AutoHashMapUnmanaged(RegionKey, RegionAccum) = .empty,
    region_context: ?RegionContext = null,
    /// A-vii-e.1: single-accumulator observer fast path (see `ObserverFast`).
    observer_fast: ?ObserverFast = null,
    /// A-vii-e.2: inline hot-span cache over `observer_fast` (see `ObserverHot`).
    observer_hot: ObserverHot = .{},
    /// Inert diagnostics used by the A-iv guards to prove full-window and
    /// remainder flushes occurred. No tiering path consumes either counter.
    region_profit_flushes: u64 = 0,
    region_profit_flushed_work: u64 = 0,
    /// Total trace entries executed (incremented in the dispatch loop before each
    /// `irinterp.execute`/native run). Diagnostic only — used to confirm the gate
    /// entry-check actually halts re-entry on a thrashing anchor, and a cheap
    /// signal for benchmark analysis (entries ≫ committed-iterations means a
    /// low-yield loop the JIT can't amortize).
    entries: u64 = 0,
    /// The subset of `entries` where the dispatcher actually committed to running
    /// **native** code (`nativeFor(ct)` resolved and `ran_native` was set), as
    /// opposed to falling back to the tier-1a IR interpreter or the exec-log
    /// recorder. Diagnostic only — no tiering path reads it.
    ///
    /// `entries` alone cannot carry R2-4's claim ("an open observation window
    /// removes the native→native handoffs, not the traces"): it is bumped before
    /// the native-vs-IR choice is made, so a run that silently fell back to
    /// tier-1a for every entry would still advance it. This counter is the one
    /// that says native trace bodies are still being entered *through the
    /// dispatcher*, which is exactly the post-blackout state R2-4 describes.
    native_entries: u64 = 0,
    /// Diagnostic/test counters for nested-loop link execution. `link_ir_exits`
    /// counts continuations that actually reached the irinterp `.link` arm;
    /// `link_follow_count` counts those links being followed into the inner root.
    /// They are intentionally harmless in release builds and give tests a direct
    /// proof that Phase 3 is not inert.
    ///
    /// Since coherent-state chaining (doc 16, Phase 2–3) these aggregate *both*
    /// classes of `.link` burst that flow through the same driveChain code: the
    /// loop-done continuation (anchored at the inner-exit PC) and the prime-side
    /// entry ramp (anchored at the outer header). They cannot be told apart at the
    /// `.link` arm, so use `prime_side_chain_follows` (below) when you need the
    /// prime-path-specific count.
    link_ir_exits: u64 = 0,
    link_follow_count: u64 = 0,
    /// Phase 4 native-chain diagnostics. These mirror the tier-1a counters above,
    /// but only increment when both linked traces execute through native pages.
    native_link_exits: u64 = 0,
    native_link_follow_count: u64 = 0,
    /// Doc 22 §B.2/§B.6 diagnostics: seed-prologue declines observed at any
    /// drain seam — the dispatcher's direct-entry handlers (interp.zig, scalar
    /// `ledger_len <= 1`), `replayLedger`'s fused/silent decline rows, and
    /// `driveChain`'s tier-1a chain seams. Output equality alone cannot prove
    /// a decline path actually fired (the §B.6 decline-determinism tests need
    /// the witness), and no tiering path reads them.
    seed_hash_declines: u64 = 0,
    seed_capacity_declines: u64 = 0,
    /// 2.3b-1 (doc 17): count of `.link`-terminal slots actually armed in
    /// `driveChain` — a continuation `C`'s `.link` slot pointed straight at its inner
    /// root `I`'s `linked_entry`, so the next `C.run` fuses into `I` under the shared
    /// frame with no Zig re-entry. `> 0` is the "the arm actually fires" signal the
    /// 2.3b-1 differential test asserts (stdout equality alone cannot prove the slot
    /// path, only that the fused and unfused runs agree).
    native_link_arms: u64 = 0,
    /// 2.3c-1 (M1 half-fusion, doc 17): count of ordinary source-branch guard slots
    /// armed in `driveChain` — a skip trace's productive branch guard (e.g. nsieve's
    /// `guard_false(p[i])`) pointed straight at the prime-side ramp's `ordinary_entry`,
    /// so the next time that guard fires it jumps into the ramp under the shared frame
    /// (skip→ramp fuses into one native call, its `.link` terminal drained by the
    /// dispatcher's fused-`.link` consumer). Distinct from `native_link_arms` (the
    /// 2.3b-1 continuation→inner `.link`-terminal arms) so the 2.3c-1 differential test
    /// can prove THIS arm fires; `> 0` is the "skip→ramp arm actually happened" signal.
    native_source_link_arms: u64 = 0,
    /// Part S: how many sibling-handoff slots were armed / actually fired natively.
    sibling_handoff_arms: u64 = 0,
    sibling_handoff_fused: u64 = 0,
    /// 2.3c-1 (M1 half-fusion, doc 17): count of fused skip→prime-side receipts DRAINED
    /// by the dispatcher's M1 fused-`.link` consumer (interp.zig) — i.e. the arm above
    /// actually took effect and a native `ct.run` fused straight into the prime-side ramp
    /// (`final != ct`, provenance via `hasArmedSourceBranchLinkAt`). Distinct from the arm
    /// counter: an arm can happen without ever firing (skip retired first); this counts
    /// the consumer path being taken. `> 0` proves the M1 consumer is exercised, not just
    /// wired, in the 2.3c-1 differential test.
    native_source_link_fused: u64 = 0,
    /// 2.3c-2e (2c-E, doc 17): count of loop-done slots actually armed — an inner
    /// root `I`'s numeric-`for` loop-done guard slot pointed at its continuation
    /// `C`'s `ordinary_entry`, closing the native `C↔I` cycle. Bumped only by
    /// `armLoopDoneLink` (the single shared fail-closed arm helper). `> 0` is the
    /// "the I→C arm actually happened" signal for the E2 differential tests.
    native_loopdone_link_arms: u64 = 0,
    /// 2.3c-2e (2c-E, doc 17): count of fused `I.loop_done_linked → C` edges DRAINED
    /// by `replayLedger`'s NON-last `.loop_done_linked` arm — i.e. the arm above
    /// actually took effect and a native run fused straight from an inner loop-done
    /// into its continuation without Zig re-entry. Distinct from the arm counter (an
    /// arm can happen without ever firing); `> 0` proves the fused edge is exercised.
    native_loopdone_link_fused: u64 = 0,
    /// 2c-F (2c-E, doc 17): count of armed slots RESET by `disarmAllLinks` when the
    /// dispatcher opens an observation/suspend/replay window over a VM that already
    /// holds a live armed native cycle (`!safe_to_arm`). Bumped by the number of
    /// slots each `disarmAllLinks` returns to `shared_exit`; `> 0` is the "the
    /// blackout actually tore down a live cycle" signal for the disarm integration
    /// test (a byte-identical run under an open window cannot, by itself, prove a
    /// non-empty registry was torn down — the counter can).
    native_link_disarms: u64 = 0,
    silent_promotions: u64 = 0,
    silent_demotions: u64 = 0,
    silent_promotion_candidates: u64 = 0,
    silent_rejects: PromotionRejects = .{},
    silent_demotion_reasons: PromotionDemotions = .{},
    silent_bursts_drained: u64 = 0,
    silent_transitions_total: u64 = 0,
    silent_budget_exhaustions: u64 = 0,
    silent_barren_exhaustions: u64 = 0,
    silent_suffix_drains: u64 = 0,
    silent_hops_total: u64 = 0,
    /// One-call staging for sibling provenance. Silent prefix evidence is
    /// merged with the reporting suffix before one final verdict is applied.
    silent_provenance: [PROVENANCE_VERDICT_CAP]SilentProvenanceEvidence = undefined,
    silent_provenance_len: usize = 0,
    /// A-viii (doc 17 §A8 step 8): the high-water mark of `armed_links.len` — the
    /// most handoff edges ever armed SIMULTANEOUSLY. The per-kind arm counters are
    /// lifetime totals, so they cannot distinguish "the three edges of the outer
    /// cycle were live at once" (a closed armed cycle, which is what the disarm
    /// path must be able to tear down) from "three edges each armed and torn down
    /// in turn". This peak can: `>= 3` with a `.region_bridge` among the kinds is
    /// the outer cycle `skip→…→cont→skip` standing complete. Diagnostic only — no
    /// selection path reads it, so it cannot perturb the 10-mode equivalence.
    native_link_peak: usize = 0,
    /// A-vii-d (doc 17 §A-vii.2): count of composite bridge slots actually armed by
    /// `tryArmRegionBridge` — a region member's composite ordinary guard slot pointed
    /// at the registered successor's `ordinary_entry`, so the next time that guard
    /// fires natively the stub commits the dominance-scoped phi snapshot and jumps
    /// STRAIGHT into the cross-anchor child (edge 4, no Zig re-entry). `> 0` is the
    /// "the region-profit gate qualified a region and the arm actually happened"
    /// signal for the A-vii-d differential tests.
    native_region_bridge_arms: u64 = 0,
    /// How many times `tryArmRegionBridge` ran its pipeline — i.e. got PAST
    /// `maybeArmCompositeExit`'s memo gates and paid for `classifyExit` + the
    /// def/profit probes + `validateRegionBridge` (which alone measured 2.4% of
    /// nsieve N=5). The ratio against `native_region_bridge_arms` is the memo's
    /// hit rate: a durably non-enterable child should show ONE attempt per
    /// activation, not one per composite deopt. Diagnostics only — never read by
    /// a decision, so it cannot perturb the byte-identical stream.
    native_region_bridge_arm_attempts: u64 = 0,
    /// A-vii-d: count of `.region_bridge` ledger rows DRAINED by `replayLedger` —
    /// i.e. the arm above actually took effect and a native run fused through the
    /// composite bridge stub into the cross-anchor successor. Distinct from the arm
    /// counter (an arm can happen without ever firing: the parent may retire, or the
    /// guard may never fail again); `> 0` proves the fused edge-4 hop is exercised.
    native_region_bridge_fused: u64 = 0,
    /// **Coherent-state chaining (doc 16, Phase 2) diagnostics.** `prime_side_arms`
    /// counts outer-header prime side-traces armed (a productive branch-guard went
    /// hot and we switched to `.full` to record the current prime iteration).
    /// `tier0_outer_body_entries` counts tier-0 executions of a traced anchor's body
    /// top — the design's required NEW signal for "how often the prime path drops to
    /// tier-0" (the back-edge counter returns early once any trace exists at the
    /// anchor, so it cannot measure this). Both are mode-invariant and give tests a
    /// direct proof Phase 2 is not inert.
    prime_side_arms: u64 = 0,
    tier0_outer_body_entries: u64 = 0,
    /// Counts prime side-trace link-bursts actually *entered* via the
    /// `.ordinary_header` chain (as opposed to a loop-done `.link` continuation,
    /// which bumps `native_link_exits`/`link_ir_exits` and is indistinguishable
    /// there). This is the Phase-2-specific "the prime chain fired, not merely
    /// recorded" signal the design demands — output equality alone can't prove it.
    prime_side_chain_follows: u64 = 0,
    /// **JIT execution-coverage accounting** (gated on `config.coverage`). Measures
    /// the gap between what the JIT *traces* and what actually runs *as a trace*, in
    /// the natural unit of a trace JIT — loop iterations (back-edges). `iters_traced`
    /// = iterations committed by a trace run (tier-1b native, or tier-1a IR-interp
    /// when native is off/unavailable — either way NOT the tier-0 bytecode
    /// interpreter), summed in `onSideExit`; `iters_tier0_covered` = interpreted
    /// back-edges at an anchor that HAS a compiled trace (the smell: covered code
    /// that keeps falling back to tier-0); `iters_tier0_uncovered` = interpreted
    /// back-edges at an anchor with no trace. Total loop iterations = the sum of the
    /// three; "covered by a trace" = traced + tier0_covered; "ran as a trace" =
    /// traced / total.
    iters_traced: u64 = 0,
    iters_tier0_covered: u64 = 0,
    iters_tier0_uncovered: u64 = 0,
    /// **Cycle (time) attribution** for the same three classes, via `readCycles`
    /// (x86_64 TSC; 0 elsewhere). Iteration counts flatter the JIT — a traced
    /// iteration is ~10-20× cheaper than a tier-0 one — so these weigh each class by
    /// actual cost. `cycles_traced` = cycles inside the dispatcher's trace-exec
    /// bracket (native/tier-1a run + chaining); `cycles_tier0_covered` /
    /// `cycles_tier0_uncovered` = cycles of tier-0 body iterations charged at their
    /// back-edge, split by whether a trace exists at the anchor. The report's
    /// `cycles_other` is the residual `run_cycles - (the three)`: it is genuinely
    /// non-loop straight-line code PLUS the small per-trace-entry work that falls
    /// between a back-edge stamp and the trace bracket (trace lookup, fingerprint,
    /// input seeding) — a slop term, not pure non-loop time. The three classes are
    /// disjoint and, being sub-intervals of the run bracket, sum to ≤ `run_cycles`,
    /// so the partition with `cycles_other` holds; only the class *labels* carry the
    /// documented slop, and the per-anchor split additionally has a nesting-boundary
    /// leak (see `AnchorCoverage`). Backward-TSC spans are dropped to 0 (`cycleDelta`).
    cycles_traced: u64 = 0,
    cycles_tier0_covered: u64 = 0,
    cycles_tier0_uncovered: u64 = 0,
    /// Steering-seam time: TSC cycles spent inside the OUTERMOST `replayLedger`
    /// walk (per-receipt ledger validation + steering), and how many such walks
    /// ran. The walk executes inside the dispatcher's trace-exec bracket, so this
    /// is a sub-interval of `cycles_traced` — the report subtracts it to split
    /// "traced" into native execution proper vs runtime seam (the split perf
    /// attributes to `replayLedger` self-time vs `[JIT]`). Gated on
    /// `config.coverage` exactly like every other TSC read; nested walks
    /// (`replay_walk_depth > 0` at entry) are not re-bracketed, so no
    /// double-counting. x86_64 only (0 elsewhere).
    cycles_seam: u64 = 0,
    seam_walks: u64 = 0,
    /// Total run cycles (TSC), stamped around the whole `Vm.run` (0 if never set:
    /// coverage off, non-x86_64, or a run driven via the `start()`/`exec()` resume
    /// path, which is NOT instrumented — coverage timing assumes the one-shot `run()`
    /// entry the CLI uses). The denominator for the time-based percentages;
    /// `cycles_other = run_cycles - traced - tier0_*`. When 0 the report shows time
    /// as n/a rather than dividing by zero.
    run_cycles: u64 = 0,
    /// Monotonic wall-clock nanoseconds over the same `Vm.run` bracket as
    /// `run_cycles` (stamped by the CLI from its host clock — the VM core holds no
    /// platform clock). Pairs with `run_cycles` so a consumer can recover the TSC
    /// frequency (`run_cycles / run_nanos`) and convert the per-class cycle counts to
    /// real time. 0 whenever `run_cycles` is (coverage off, non-x86_64, wasm, or the
    /// resume path) — the visualizer then shows time as n/a. Diagnostic only.
    run_nanos: u64 = 0,
    /// TSC of the last tier-0 coverage "event" (back-edge hook, or trace-region exit)
    /// — the start of the current tier-0 span. `noteInterpIter` charges
    /// `now - last_event_tsc` to the anchor. Seeded to the run-start TSC so the first
    /// span isn't a huge bogus delta. Scratch, not reported.
    last_event_tsc: u64 = 0,
    /// TSC of the last trace-hop boundary — the start of the current hop's execution
    /// span. Stamped at trace-region entry (dispatcher `|buf|` block) and re-stamped
    /// by every `onSideExit`, which charges `now - last_hop_tsc` of *this hop's*
    /// execution to *this hop's own anchor* (`t.anchor`). This is what makes per-anchor
    /// traced time mirror the per-anchor iteration count: a chain hop into an inner
    /// trace bills its cycles to the inner anchor, not the outer entry anchor. Scratch,
    /// not reported. (A fused native span that replays several hops in one mcode run is
    /// the one residual: the whole span lands on the first replayed hop — genuinely
    /// unsplittable, since they ran as one instruction stream.)
    last_hop_tsc: u64 = 0,
    /// Per-anchor breakdown of the same accounting, keyed by loop-header anchor, so
    /// the report (and the viz) can attribute traced/interpreted iterations + cycles
    /// to a specific source region. Populated only when `config.coverage`; freed in
    /// `deinit`. `AnchorCoverage` fields mirror the aggregates above, partitioned by
    /// anchor.
    coverage: std.AutoHashMapUnmanaged(AnchorKey, AnchorCoverage) = .empty,
    /// The in-progress recording (at most one at a time).
    rec: Recorder = .{},
    /// Reusable SSA-value scratch for the tier-1a executor (`irinterp.execute`),
    /// indexed by `Ref`. Reused across every entry — never allocated
    /// per-iteration or per-entry. Not a GC root (the executor runs no
    /// safepoint; see `irinterp.zig`).
    ///
    /// **Segmented, because trace execution NESTS and the frames must not move.**
    /// The dispatcher takes a frame for the trace it enters and keeps it live
    /// across `driveChain` (it is the `.ir_numeric_for_done` payload); the
    /// candidate walk takes a frame per candidate; `runLinkedBurst` takes one
    /// per hop. A single flat growable buffer cannot serve that shape: growing
    /// it to fit an inner frame reallocates, and every outer frame's slice
    /// becomes a dangling pointer into freed memory. That was a real
    /// use-after-free — `--trace bench/luajit/nsieve-bit.lua 6` (38-instr entry,
    /// 59-instr candidate) and `--trace bench/luajit/scimark-sparse.lua 3000`
    /// (44 → 57) both moved the buffer, in ReleaseFast as well as Debug, and
    /// `flushNumericForLoopDone` then read the freed block. Release only printed
    /// the right answer because the process allocator neither scrubs a freed
    /// block nor had reused it yet.
    ///
    /// So the backing is a list of independently-allocated chunks: appending a
    /// chunk moves the list of *slices*, never the `Value`s a live frame points
    /// at. Frames are carved bump-style within a chunk and released in LIFO
    /// order via `valuesMark`/`valuesRelease` — which is what makes a chunk at
    /// or above `values_cur` provably dead and therefore safe to reallocate when
    /// an oversized frame needs it. Each chunk holds at least
    /// `values_chunk_slots`, and a frame larger than that simply gets a chunk of
    /// its own, so no frame ever straddles a chunk boundary and no invariant
    /// depends on `config.maxrecord`.
    values_chunks: std.ArrayListUnmanaged([]Value) = .empty,
    /// Index into `values_chunks` of the chunk currently being carved from.
    values_cur: u32 = 0,
    /// The un-carved tail of `values_chunks[values_cur]` — everything in that
    /// chunk after the deepest live frame. Kept as a slice rather than an offset
    /// so the push fast path is one length compare and a subslice: this runs on
    /// every trace entry, and chasing `values_cur → chunks.items.ptr → chunk →
    /// len` instead measured +1.3–2.2% on nsieve and scimark-fft. Empty before
    /// the first chunk exists, which the fast path's length check rejects.
    values_free: []Value = &.{},
    /// 2.3c-2b (doc 17): scratch for ONE native continuation call's decoded
    /// per-transition ledger. `runLinkedBurst` fills it via
    /// `CompiledTrace.runCapturingLedger` and immediately replays it in
    /// `replayContinuationLedger`; the borrow lives only for that capture→replay
    /// window (no native call / resize / nested replay in between). Sized to
    /// `irinterp.LEDGER_CAP`, the native append's own bound, so a full span always
    /// fits. Not a GC root (holds decoded scalars, no `Value`s).
    ledger_scratch: [irinterp.LEDGER_CAP]irinterp.LedgerEntry = undefined,
    /// Last guard-failure instruction index, written by the dispatch loop when a
    /// trace side-exits with zero iterations. Used for per-guard PC recording
    /// (exit-PC-aware chaining). `maxInt(u32)` means no guard failed (clean exit
    /// or arith error).
    last_exit_instr: u32 = std.math.maxInt(u32),
    /// Per-guard failure counters for side-trace recording (step 4).  Keyed by
    /// `(anchor, exit_pc)` — each entry tracks how many times a specific guard
    /// in traces at `anchor` has failed.  When a counter crosses `hotguard`,
    /// `wants_side_trace` is set and the next back-edge records a side trace.
    guard_failures: std.AutoHashMapUnmanaged(GuardKey, u32) = .empty,
    /// Burst-terminal telemetry (jitdbg builds only — never touched otherwise).
    /// One record per `driveDispatcherLedger` entry: burst ledger length histogram
    /// plus a per-(trace,exit,kind) count of the TERMINAL row — i.e. exactly the
    /// exits that hand control back to the runtime. This is the target list for
    /// exit-branch patching (doc 17 Part B): every entry here is a runtime
    /// round-trip that a patched transition or freeze could eliminate.
    dbg_burst_len_hist: [irinterp.LEDGER_CAP + 1]u64 = @splat(0),
    dbg_burst_terminals: std.AutoHashMapUnmanaged(DbgTerminalKey, u64) = .empty,
    /// B-3c telemetry: composition of silent-burst SUFFIX ledgers — every
    /// materialized row a burst still produced despite live promotion, keyed
    /// like the terminals. These rows are what end bursts (ledger-full) and
    /// what the suffix replay walks, so they are the remaining seam feedstock:
    /// any hot key here is a candidate for a further promoted set.
    dbg_silent_suffix_rows: std.AutoHashMapUnmanaged(DbgTerminalKey, u64) = .empty,
    /// B-3a seam gate input: every replay row is partitioned by whether its physical
    /// armed edge belongs to any bridge-free closed directed subcycle.
    dbg_patchable_cycle_rows: u64 = 0,
    dbg_other_replay_rows: u64 = 0,
    /// When non-null, the next back-edge to this anchor will arm a side-trace
    /// recording (even if a trace already exists there).  Set by
    /// `countGuardFailure` when a guard-failure crosses `hotguard`; cleared
    /// by `onBackEdge` when the side trace is armed.
    wants_side_trace: ?AnchorKey = null,
    /// Provenance of the pending `wants_side_trace` when it came from a hot exit
    /// (`noteTakenExit`): the parent `(trace id, exit index)` to DONE-latch once
    /// the side trace commits — Pall's `snap->count = SNAPCOUNT_DONE` at side-
    /// trace link (lj_trace.c:535). Null for fingerprint-miss wants (those have
    /// no single parent exit). Follows the want through consume →
    /// `pending_replay_src` → `Recorder.side_src`; cleared wherever the want is
    /// dropped, so `side_want_src != null ⇒ wants_side_trace != null`.
    side_want_src: ?ExitKey = null,
    /// `side_want_src` after `consumeSideTraceWantAtResume` moved the want into
    /// `pending_replay_anchor`; transferred to `Recorder.side_src` by
    /// `maybeStartReplaySide`, cleared with `pending_replay_anchor`.
    pending_replay_src: ?ExitKey = null,
    /// **Nested-loop trace linking (Phase 1).** When non-null, a *continuation*
    /// recording is pending at this (non-header) anchor — the bytecode PC tier-0
    /// resumes at after an inner numeric-`for` loop runs to completion (the inner
    /// loop-done `guard_true`'s recorded `exit_pc`). Unlike a root or side trace,
    /// this is **not** a back-edge target, so it cannot arm in `onBackEdge`;
    /// `maybeArmContinuation` sets it on a hot inner loop-done exit and
    /// `maybeStartContinuation` consumes it in the dispatch prologue the moment
    /// `cur_pc` reaches the anchor — *after* tier-0 has deopt-replayed the final
    /// inner iteration, so the continuation records the **outer** body forward, not
    /// a stray inner iteration. Recording the inner `for_prep` it then re-reaches
    /// still aborts (LINNER) until Phase 2 turns it into a `.link`. See
    /// `docs/design/15-nested-loop-linking.md`.
    pending_exit_anchor: ?AnchorKey = null,
    /// **Coherent-state chaining (doc 16, Phase 2).** When non-null, a
    /// branch-guard at this outer-header anchor has gone hot: the next such exit
    /// should arm an *immediate* replay of the current (prime) iteration — recording
    /// the taken branch forward through the inner `for_prep` and closing with a
    /// `.link` to the inner root — rather than the *next* iteration (which the
    /// `wants_side_trace`/`onBackEdge` path would record, and which is ~93% a
    /// composite in nsieve, the wrong path). Set by `noteTakenExit` (the unified
    /// hotexit counter routes source-branch guard exits here at the `hotexit`
    /// threshold — the separate hotguard-50 per-anchor map is gone);
    /// consumed at the productive-exit site by handing off to `pending_replay_anchor`.
    wants_prime_side: ?AnchorKey = null,
    /// Hotexit provenance for `wants_prime_side` (mirrors `side_want_src`): the
    /// parent `(trace, exit)` to DONE-latch when the prime side trace commits.
    /// Handed to `pending_replay_src` at the consumption site; cleared wherever
    /// `wants_prime_side` is dropped.
    prime_want_src: ?ExitKey = null,
    /// **Coherent-state chaining (doc 16, Phase 2).** When non-null, an outer-header
    /// prime side-trace recording is pending at this anchor. Unlike
    /// `pending_exit_anchor` (a *post-inner* continuation pc), this anchor is the
    /// failed trace's OWN coherent anchor — the registers are already coherent there
    /// on the productive exit, so tier-0 re-enters at the anchor and
    /// `maybeStartReplaySide` starts the `.side` recording the instant `cur_pc`
    /// reaches it, capturing the prime branch of that same iteration. Cleared by
    /// `maybeStartReplaySide` (consumed) or `clearPendingExitAnchor` (frame unwind).
    pending_replay_anchor: ?AnchorKey = null,
    /// Per-trace execution logs for the visualizer (`execlog.zig`), populated only
    /// when `config.record_exec_log`. Keyed by `trace_id` (cache index). Empty and
    /// untouched on the normal JIT path.
    exec_logs: std.ArrayListUnmanaged(execlog.TraceExecLog) = .empty,
    /// The recorder driving `exec_logs`, lazily created on first use so the off path
    /// allocates nothing. Reused (per-entry scratch retained) across every entry.
    exec_recorder: ?execlog.ExecLogRecorder = null,
    /// Aborted-recording diagnostic log, populated only when `config.record_aborts`
    /// (the `--dump-aborts` CLI flag). Deduped by `(anchor, reason, op)`; see
    /// `AbortRecord` and `logAbort`. Empty and untouched on the normal path.
    abort_log: std.ArrayListUnmanaged(AbortRecord) = .empty,

    pub fn init(gpa: std.mem.Allocator) TraceState {
        return .{ .gpa = gpa, .mcode_arena = nativegen.McodeArena.init(gpa) };
    }

    // --- live debug logging (jitdbg) ------------------------------------------
    //
    // The permanent replacement for hand-added `std.debug.print` scaffolding.
    // Compiled out entirely unless the build sets `-Djit-debug=true`; silent at
    // run time unless `config.debug_log` (CLI `--jit-debug`, or set per-VM in a
    // test). See src/jitdbg.zig for the gate contract.

    /// One live debug line, double-gated (comptime `-Djit-debug` + runtime
    /// `config.debug_log`). Stderr only — never program output.
    pub inline fn dbg(self: *const TraceState, comptime fmt: []const u8, args: anytype) void {
        if (comptime jitdbg.enabled) {
            if (self.config.debug_log) jitdbg.log(fmt, args);
        }
    }

    /// Dump the `guard_failures` map (one line per `(anchor, exit_pc)` key with
    /// its count). The on-demand version of the ad-hoc iterator loops we used to
    /// paste into tests. Same double gate as `dbg`.
    /// Part S: does an armed `.sibling_handoff` link exist for exactly this
    /// (parent, exit) → child triple? The replay-side proof of the arm.
    pub fn hasArmedSiblingHandoff(self: *const TraceState, parent: *const Trace, exit_instr: u32, child: *const Trace) bool {
        // Fast reject: `sibling_arms` counts this parent's armed handoffs and is
        // maintained by every arm/disarm path, so `== 0` is an exact necessary
        // condition for the scan below to find anything. This runs once per non-final
        // `.deopt` row in the hot replay walk; the registry scan must not.
        if (parent.sibling_arms == 0) return false;
        for (self.armed_links.items) |l| {
            if (l.kind == .sibling_handoff and l.parent == parent and
                l.slot_index == exit_instr and l.child == child) return true;
        }
        return false;
    }

    /// Part S / §S-a: the ANCHOR-COHERENCE proof for a handoff exit — does no
    /// heap-mutating op precede `exit_instr` in the trace body?
    ///
    /// This is the eligibility check the first cut of Part S omitted, and omitting it
    /// is not a subtlety: a native deopt flushes CARRIED HOMES only (invariants stay at
    /// their entry values, internal phis are never flushed), so the flushed register
    /// image is the anchor state OF THE CURRENT ITERATION. Handing that to a
    /// same-anchor sibling therefore re-runs the current iteration from its top — sound
    /// exactly when the iteration has not yet mutated the heap, and silently wrong
    /// otherwise. Measured: without this check the A-viii outer-cycle test prints 108
    /// where the unfused run prints 109, one iteration dropped.
    ///
    /// A linear scan rather than a `bridge_cand`-style per-trace bitset on purpose:
    /// this is consulted only when the watch MOVES and again at arm time, both cold.
    /// A memo here would buy nothing and cost a build/free/serialize lifecycle.
    ///
    /// The store ops here are `tropt.kindOf`'s `.astore` class. `sgm_setpos`
    /// (kind `.setpos`, doc 30) is a store too, but it is NEVER emitted inline —
    /// it only enters the IR through the pending-store sink, below every guard —
    /// so no exit can precede one and the scan need not name it. That safety
    /// lives in `commit`'s sinking discipline, not here: if `sgm_setpos` ever
    /// gains an inline emission path it must join this list. Guards (which
    /// side-exit but mutate nothing) and `int_of_float` are deliberately fine.
    /// The doc-24 allocating producers (`tostr_*`, snew, `scap_str`) also fall
    /// through: they only intern (grow the heap), never mutate guest-visible
    /// state, so re-running the iteration re-interns identically (D2 id-stream).
    // pub for trace_link.zig (file-split pass)
    pub fn exitIsPreEffect(t: *const Trace, exit_instr: u32) bool {
        const n = @min(@as(usize, exit_instr), t.instrs.len);
        for (t.instrs[0..n]) |ins| switch (ins.op) {
            .astore, .astore_append, .hstore, .gstore => return false,
            else => {},
        };
        return true;
    }

    /// Part S: is `exit_instr` of `t` an anchor-coherent ordinary deopt exit that
    /// the sibling-handoff stub can drive? The stub is the existing ordinary-guard
    /// path (resolve through `slot[ei]` → flush carried homes → append → forced-yield
    /// → `jmp`), so eligibility is exactly the set of exits that path owns.
    fn siblingHandoffEligible(self: *const TraceState, t: *Trace, exit_instr: u32) bool {
        const c = switch (t.native) {
            .compiled => |*cc| cc,
            else => return false,
        };
        if (exit_instr >= c.slots.len or exit_instr >= t.instrs.len) return false;
        // Already armed here: the slot is taken, so counting it again could only
        // produce a redundant arm. Consulted on the watch-MOVE path only, never
        // per receipt, so the registry scan stays off the hot path.
        if (t.sibling_arms != 0) {
            for (self.armed_links.items) |l| {
                if (l.kind == .sibling_handoff and l.parent == t and l.slot_index == exit_instr)
                    return false;
            }
        }
        // Loop-done slots belong to `.loop_done_linked` (P-C option (b)), and the
        // ordinary loop-done deopt bypasses `slot[ei]` entirely in emission.
        if (isLoopDoneGuardIndex(t, exit_instr)) return false;
        // Bridge candidates run the A-v bridge stub body, not the plain path.
        if (t.isBridgeCandidate(exit_instr)) return false;
        // The anchor-coherence proof. Without it the handoff is not
        // semantics-preserving — see `exitIsPreEffect`.
        if (!exitIsPreEffect(t, exit_instr)) return false;
        // PROGRESS, not just soundness: only a SOURCE-BRANCH guard may arm. A branch
        // guard failing means the program took the OTHER branch at the shared anchor
        // decision — exactly the case the same-anchor sibling was recorded for, so the
        // handoff completes the iteration natively. Any other guard kind (zero-trip
        // loop-entry checks, bounds, type) says nothing about which branch holds:
        // the sibling re-runs the iteration, its OWN branch guard fails, and the
        // armed pair PING-PONGS until the ledger cap forces a yield. Measured on
        // nsieve N=9: arming the zero-trip exit ei=16 turned 304k two-row bursts
        // into 304k THIRTY-TWO-row yield bursts — +128% wall-clock from a mechanism
        // that is a −7% win when it arms branch guards only.
        //
        // `isSourceBranchGuardExit` alone is NOT that test: it excludes only
        // `for_loop`-sourced guards, so a `for_prep`-sourced zero-trip check (nsieve's
        // ei=16, guard_true over `le i+i, m`) passes it while telling us nothing about
        // the anchor branch. Require the POSITIVE property instead: the guard's source
        // opcode is a conditional branch — the one bytecode shape where "this guard
        // failed" and "the sibling's branch was taken" are the same statement.
        if (!self.isSourceBranchGuardExit(t, exit_instr, t.anchor.proto)) return false;
        const src_pc = guardSourcePc(t.instrs[exit_instr]) orelse return false;
        if (src_pc >= t.anchor.proto.code.len) return false;
        switch (t.anchor.proto.code[src_pc].op) {
            .jmp_if_false, .jmp_if_true, .jmp_if_not_nil => {},
            else => return false,
        }
        return true;
    }

    /// Part S: charge one burst-terminal receipt to `(trace, exit)` and, on crossing
    /// `hotguard`, request an arm. Pure function of the receipt stream.
    // pub for trace_chain.zig (file-split pass)
    pub fn noteSiblingTerminal(self: *TraceState, t: *Trace, exit_instr: u32) void {
        // Steady state (a request already in flight): one optional load and out. See
        // `Trace.sibling_watch_exit` for why this path has to be free, not just cheap.
        if (self.pending_sibling_arm != null) return;
        // Single-slot ineligible memo: a terminal at the last known-ineligible exit
        // is one compare and out — never a re-scan. Cleared on any arm/disarm event
        // touching this trace (the only non-static eligibility input).
        if (t.sibling_reject_exit == exit_instr) return;
        if (t.sibling_watch_exit != exit_instr) {
            self.dbg("sibling-watch-move: t={d} ei={d} (from ei={d} count={d}) eligible={}", .{
                t.id,                                       exit_instr, t.sibling_watch_exit, t.sibling_watch_count,
                self.siblingHandoffEligible(t, exit_instr),
            });
            // The watch moves at most once per distinct eligible exit; eligibility
            // (which touches `native.compiled`, the loop-done predicate and the
            // bridge memo) is therefore NOT on the per-receipt path. An ineligible
            // exit leaves the watch untouched, so it cannot starve the eligible one.
            if (!self.siblingHandoffEligible(t, exit_instr)) {
                t.sibling_reject_exit = exit_instr;
                return;
            }
            t.sibling_watch_exit = exit_instr;
            t.sibling_watch_count = 0;
        }
        t.sibling_watch_count +|= 1;
        if (t.sibling_watch_count == self.config.hotguard)
            self.pending_sibling_arm = .{ .trace_id = t.id, .exit_instr = exit_instr };
    }

    /// Part S: consume a pending arm request now that the dispatcher has actually
    /// selected and entered `child`. The armed target is therefore the trace the
    /// deterministic dispatch ran — `hit_count` never enters the contract.
    pub fn tryArmSiblingHandoff(self: *TraceState, child: *Trace, safe_to_arm: bool) void {
        const key = self.pending_sibling_arm orelse return;
        if (!safe_to_arm) return; // keep pending; observation window owns the slot
        const parent = self.traceById(key.trace_id) orelse {
            self.pending_sibling_arm = null; // parent retired: request is stale
            return;
        };
        if (parent == child) return; // not a sibling handoff; wait for a real sibling
        if (child.anchor.proto != parent.anchor.proto or child.anchor.pc != parent.anchor.pc)
            return; // different anchor: this entry is not the one the request meant
        self.pending_sibling_arm = null;
        _ = self.publishSiblingArm(parent, key.exit_instr, child);
    }

    /// Shared Part-S / Part-B publication funnel. On success only, publish the
    /// physical sibling arm and perform the complete Part-S latch/counter update.
    pub fn publishSiblingArm(self: *TraceState, parent: *Trace, exit_instr: u32, child: *Trace) bool {
        if (!(self.armNativeLink(parent, exit_instr, child, .sibling_handoff) catch false))
            return false;
        self.dbg("sibling-arm: t={d} ei={d} op={s} -> t={d}", .{
            parent.id, exit_instr, @tagName(parent.instrs[exit_instr].op), child.id,
        });
        self.sibling_handoff_arms +|= 1;
        // Fast-reject key for `hasArmedSiblingHandoff`; decremented by every
        // disarm path via `clearSiblingLatch`.
        parent.sibling_arms +|= 1;
        // Release the watch so this parent's NEXT hot exit can qualify. The
        // just-armed exit is now rejected by `siblingHandoffEligible`, so the
        // watch cannot simply land back on it.
        parent.sibling_watch_exit = std.math.maxInt(u32);
        parent.sibling_watch_count = 0;
        return true;
    }

    /// Record one dispatcher burst's ledger for the Part-B terminal telemetry
    /// (jitdbg builds only; comptime-false → zero cost in normal builds). Called
    /// from `driveDispatcherLedger` with the full burst ledger.
    pub fn dbgNoteBurst(self: *TraceState, entries: []const irinterp.LedgerEntry) void {
        if (comptime jitdbg.enabled) {
            if (!self.config.debug_log) return;
            const len = @min(entries.len, self.dbg_burst_len_hist.len - 1);
            self.dbg_burst_len_hist[len] += 1;
            if (entries.len == 0) return;
            const t = entries[entries.len - 1];
            const gop = self.dbg_burst_terminals.getOrPut(self.gpa, .{
                .trace_id = t.id,
                .exit_instr = t.exit,
                .kind = t.kind,
                .outcome = t.outcome,
            }) catch return; // telemetry: drop on OOM, never fail the burst
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    }

    /// B-3c: aggregate a silent burst's suffix-ledger rows (jitdbg builds only).
    pub fn dbgNoteSuffixLedger(self: *TraceState, entries: []const irinterp.LedgerEntry) void {
        if (comptime jitdbg.enabled) {
            if (!self.config.debug_log) return;
            for (entries) |row| {
                const gop = self.dbg_silent_suffix_rows.getOrPut(self.gpa, .{
                    .trace_id = row.id,
                    .exit_instr = row.exit,
                    .kind = row.kind,
                    .outcome = row.outcome,
                }) catch return; // telemetry: drop on OOM, never fail the drain
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
        }
    }

    fn armedEdgeInBridgeFreeCycle(self: *const TraceState, parent: *const Trace, exit_instr: u32) bool {
        var first_child: ?*Trace = null;
        for (self.armed_links.items) |link| {
            if (link.parent == parent and link.slot_index == exit_instr and link.kind != .region_bridge) {
                first_child = link.child;
                break;
            }
        }
        const child = first_child orelse return false;
        if (child == parent) return true;

        var pending: [64]*Trace = undefined;
        var seen: [64]*Trace = undefined;
        var pending_len: usize = 1;
        var seen_len: usize = 0;
        pending[0] = child;
        while (pending_len > 0) {
            pending_len -= 1;
            const cur = pending[pending_len];
            if (cur == parent) return true;
            var duplicate = false;
            for (seen[0..seen_len]) |s| if (s == cur) {
                duplicate = true;
                break;
            };
            if (duplicate) continue;
            if (seen_len == seen.len) return false;
            seen[seen_len] = cur;
            seen_len += 1;
            for (self.armed_links.items) |link| {
                if (link.parent != cur or link.kind == .region_bridge) continue;
                if (pending_len == pending.len) return false;
                pending[pending_len] = link.child;
                pending_len += 1;
            }
        }
        return false;
    }

    // pub for trace_chain.zig (file-split pass)
    pub fn dbgNoteReplayRow(self: *TraceState, owner: *Trace, exit_instr: u32) void {
        if (comptime jitdbg.enabled) {
            if (!self.config.debug_log) return;
            if (self.armedEdgeInBridgeFreeCycle(owner, exit_instr))
                self.dbg_patchable_cycle_rows +|= 1
            else
                self.dbg_other_replay_rows +|= 1;
        }
    }

    /// Dump the burst-terminal telemetry: ledger-length histogram + every terminal
    /// site sorted is left to the reader (use sort(1)). Same double gate as the
    /// other dbgDump* helpers. This is the Part-B patch target list: each line is
    /// "this exit site handed control back to the runtime N times".
    pub fn dbgDumpBurstStats(self: *TraceState) void {
        if (comptime jitdbg.enabled) {
            if (!self.config.debug_log) return;
            var total: u64 = 0;
            for (self.dbg_burst_len_hist) |c| total += c;
            jitdbg.log("burst stats: {d} dispatcher bursts", .{total});
            const replay_total = self.dbg_patchable_cycle_rows +| self.dbg_other_replay_rows;
            jitdbg.log("  B-3 seam rows: bridge-free-closed={d} rest={d} total={d}", .{
                self.dbg_patchable_cycle_rows, self.dbg_other_replay_rows, replay_total,
            });
            jitdbg.log("  silent: candidates={d} promotions={d} demotions={d} bursts={d} transitions={d} hops={d} budget={d} barren={d} suffix={d}", .{
                self.silent_promotion_candidates, self.silent_promotions,
                self.silent_demotions,            self.silent_bursts_drained,
                self.silent_transitions_total,    self.silent_hops_total,
                self.silent_budget_exhaustions,   self.silent_barren_exhaustions,
                self.silent_suffix_drains,
            });
            jitdbg.log("  silent rejects: bridge={d} region={d} open={d} child-mismatch={d} no-patch={d} cap={d} region-owned={d}", .{
                self.silent_rejects.bridge_member,
                self.silent_rejects.region_mismatch,
                self.silent_rejects.open_chain,
                self.silent_rejects.child_mismatch,
                self.silent_rejects.no_patch_point,
                self.silent_rejects.cap,
                self.silent_rejects.region_owned,
            });
            jitdbg.log("  silent demotions: activation={d} region-close={d} slot={d} trace={d} teardown={d} unfreeze={d} growth={d}", .{
                self.silent_demotion_reasons.activation,
                self.silent_demotion_reasons.region_close,
                self.silent_demotion_reasons.slot_mutation,
                self.silent_demotion_reasons.trace_invalidation,
                self.silent_demotion_reasons.teardown,
                self.silent_demotion_reasons.unfreeze,
                self.silent_demotion_reasons.membership_growth,
            });
            for (self.dbg_burst_len_hist, 0..) |c, len| {
                if (c != 0) jitdbg.log("  burst-len {d}: {d}", .{ len, c });
            }
            var it = self.dbg_burst_terminals.iterator();
            while (it.next()) |e| {
                const k = e.key_ptr.*;
                jitdbg.log("  terminal t={d} ei={d} kind={s} outcome={s}: {d}", .{
                    k.trace_id,          k.exit_instr,  @tagName(k.kind),
                    @tagName(k.outcome), e.value_ptr.*,
                });
            }
            var sit = self.dbg_silent_suffix_rows.iterator();
            while (sit.next()) |e| {
                const k = e.key_ptr.*;
                jitdbg.log("  suffix-row t={d} ei={d} kind={s} outcome={s}: {d}", .{
                    k.trace_id,          k.exit_instr,  @tagName(k.kind),
                    @tagName(k.outcome), e.value_ptr.*,
                });
            }
        }
    }

    pub fn dbgDumpGuardFailures(self: *TraceState) void {
        if (comptime jitdbg.enabled) {
            if (!self.config.debug_log) return;
            jitdbg.log("guard_failures ({d} keys):", .{self.guard_failures.count()});
            var it = self.guard_failures.iterator();
            while (it.next()) |e| {
                jitdbg.log("  anchor pc={d} exit_pc={d} -> {d}", .{
                    e.key_ptr.anchor.pc, e.key_ptr.exit_pc, e.value_ptr.*,
                });
            }
        }
    }

    /// Dump the trace cache (one line per trace: index, id, anchor pc, input/
    /// instr counts, native state, hit count, terminal op). Same double gate.
    pub fn dbgDumpCache(self: *TraceState) void {
        if (comptime jitdbg.enabled) {
            if (!self.config.debug_log) return;
            jitdbg.log("trace cache ({d} traces, {d} armed links):", .{
                self.cache.items.len, self.armed_links.items.len,
            });
            for (self.cache.items, 0..) |t, i| {
                const term: IrOp = if (t.instrs.len != 0) t.instrs[t.instrs.len - 1].op else .loop;
                jitdbg.log("  [{d}] id={d} anchor pc={d} instrs={d} inputs={d} term={s} native={s} hits={d}", .{
                    i,                  t.id,         t.anchor.pc,
                    t.instrs.len,       t.inputs.len, @tagName(term),
                    @tagName(t.native), t.hit_count,
                });
            }
        }
    }

    pub fn deinit(self: *TraceState) void {
        self.dbgDumpBurstStats(); // jitdbg-only burst-terminal telemetry (Part B)
        self.demoteAllSets();
        if (self.pending_demote.items.len != 0)
            @panic("TraceState.deinit: promotion demotion deferred during teardown");
        self.dbg_burst_terminals.deinit(self.gpa);
        self.dbg_silent_suffix_rows.deinit(self.gpa);
        self.counters.deinit(self.gpa);
        self.gate.deinit(self.gpa);
        self.record_gate.deinit(self.gpa);
        self.lleave_count.deinit(self.gpa);
        self.unroll_fail.deinit(self.gpa);
        self.while_yield.deinit(self.gpa);
        self.penalty.deinit(self.gpa);
        self.guard_failures.deinit(self.gpa);
        for (self.values_chunks.items) |c| self.gpa.free(c);
        self.values_chunks.deinit(self.gpa);
        for (self.exec_logs.items) |*l| l.deinit(self.gpa);
        self.exec_logs.deinit(self.gpa);
        self.abort_log.deinit(self.gpa);
        if (self.exec_recorder) |*r| r.deinit();
        self.armed_links.deinit(self.gpa);
        self.pending_demote.deinit(self.gpa);
        if (self.promotion_candidate.len != 0) self.gpa.free(self.promotion_candidate);
        self.promoted_exit_owners.deinit(self.gpa);
        self.promoted_sets.deinit(self.gpa);
        self.provenance_edges.deinit(self.gpa);
        self.trace_by_id.deinit(self.gpa);
        self.coverage.deinit(self.gpa);
        self.edge_cache.deinit(self.gpa); // A-ii.2 (values are plain structs; no per-entry free)
        // A-ii.4: region model. `region_defs` values own members/member_points; the
        // intern map owns its edge slices; the physical indices own their []RegionId.
        var rd_it = self.region_defs.valueIterator();
        while (rd_it.next()) |d| {
            self.gpa.free(d.members);
            self.gpa.free(d.member_points);
            freeRegionBridges(self.gpa, d.bridges);
        }
        self.region_defs.deinit(self.gpa);
        self.region_intern.deinit(self.gpa);
        freeRegionSetMap(ExitKey, &self.source_exit_regions, self.gpa);
        freeRegionSetMap(u32, &self.dest_entry_regions, self.gpa);
        self.region_profit.deinit(self.gpa);
        self.freeObserverFast(); // A-vii-e.1: owned bitset copies
        // Doc 20 §R2-2: VM teardown is the other legal image-free point.
        self.dropEntryPatchState();
        self.code_images.deinit(self.gpa);
        self.entry_patches.deinit(self.gpa);
        self.entry_patch_free.deinit(self.gpa);
        // Free each trace (its `native.deinit()` returns mcode slots to the arena's
        // free-list) *before* tearing down the arena those slots live in.
        for (self.cache.items) |t| t.destroy(self.gpa);
        self.cache.deinit(self.gpa);
        self.mcode_arena.deinit();
        // Doc 22 §B.1: the seeding ctx outlives every compiled page (pages bake
        // `&ctx` as an imm64), so it is freed only after the cache + arena are
        // gone. Null for hand-built test states (see the field doc).
        if (self.native_seed_ctx) |ctx| self.gpa.destroy(ctx);
        self.rec.deinit(self.gpa);
    }

    /// Record one interpreted (tier-0) loop back-edge at `(proto, pc)`, plus the
    /// `cycles` the just-completed tier-0 body iteration took (a `readCycles` delta;
    /// 0 on non-x86_64), for coverage accounting. Classifies it covered (a trace has
    /// been committed at this anchor — the "has a trace but ran interpreted" fallback
    /// smell) vs uncovered via the per-anchor `has_trace` flag — an O(1) map probe,
    /// NOT a `findTrace` cache scan, so this stays cheap on the 10M-back-edge hot path
    /// (coverage is opt-in via `--jit-coverage`/`--jit-stats`, never on the timed
    /// `--time`/bench path). Caller gates on `config.coverage`. On OOM the per-anchor
    /// row is lost but the aggregates are still bumped (counted uncovered — no map
    /// entry means no known trace).
    pub fn noteInterpIter(self: *TraceState, proto: *const Proto, pc: u32, cycles: u64) void {
        const gop = self.coverage.getOrPut(self.gpa, .{ .proto = proto, .pc = pc }) catch {
            self.iters_tier0_uncovered +|= 1;
            self.cycles_tier0_uncovered +|= cycles;
            return;
        };
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.interp +|= 1;
        gop.value_ptr.interp_cycles +|= cycles;
        if (gop.value_ptr.has_trace) {
            self.iters_tier0_covered +|= 1;
            self.cycles_tier0_covered +|= cycles;
        } else {
            self.iters_tier0_uncovered +|= 1;
            self.cycles_tier0_uncovered +|= cycles;
        }
    }

    /// Record `n` loop iterations committed by a trace run anchored at `anchor`, for
    /// coverage accounting. Called from `onSideExit` — the single per-trace-commit
    /// hook every trace run (tier-1a and tier-1b, direct and every `driveChain` hop)
    /// funnels through exactly once with its OWN committed count, so summing here is
    /// double-count-free. Also flips `has_trace` (a run implies a trace exists — a
    /// belt-and-suspenders guard beside the commit-time `markAnchorTraced`). Caller
    /// gates on `config.coverage`. OOM on the per-anchor map is swallowed (the
    /// aggregate `iters_traced` still holds). Time is attributed alongside in
    /// `noteTracedCycles`, also from `onSideExit` — per hop, to this same anchor.
    pub fn noteTraceIters(self: *TraceState, anchor: AnchorKey, n: u64) void {
        self.iters_traced +|= n;
        const gop = self.coverage.getOrPut(self.gpa, anchor) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.traced +|= n;
        gop.value_ptr.has_trace = true;
    }

    /// Charge `cycles` (a `readCycles` delta) of trace-execution time to `anchor`, for
    /// the time-based coverage split. Called from `onSideExit` once per hop with the
    /// span since the previous hop boundary (`last_hop_tsc`), so time is attributed to
    /// the hop's own anchor — the exact time counterpart of the iteration count that
    /// `noteTraceIters` sums per hop. Bumps the aggregate `cycles_traced` and the
    /// per-anchor `traced_cycles`. Caller gates on `config.coverage`; OOM on the
    /// per-anchor map is swallowed (the aggregate still holds).
    pub fn noteTracedCycles(self: *TraceState, anchor: AnchorKey, cycles: u64) void {
        self.cycles_traced +|= cycles;
        const gop = self.coverage.getOrPut(self.gpa, anchor) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.traced_cycles +|= cycles;
    }

    /// Mark `anchor` as having a committed trace, for coverage classification. Called
    /// once per trace commit (gated on `config.coverage`), so interpreted back-edges
    /// taken after the commit are classified covered (fallback-despite-a-trace) while
    /// warmup back-edges before it stay uncovered. O(1). OOM swallowed.
    pub fn markAnchorTraced(self: *TraceState, anchor: AnchorKey) void {
        const gop = self.coverage.getOrPut(self.gpa, anchor) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.has_trace = true;
    }

    /// The `ExecLogRecorder` re-targeted at the execution log for `trace_id` (the
    /// trace's cache index), creating the recorder (lazily) and the per-trace log on
    /// first use. Returns null on OOM (the caller then runs the uninstrumented
    /// `execute`). Only called when `config.record_exec_log`.
    pub fn execRecorderFor(self: *TraceState, trace_id: u32) ?*execlog.ExecLogRecorder {
        if (self.exec_recorder == null) {
            self.exec_recorder = execlog.ExecLogRecorder.init(self.gpa, self.config.exec_log_max_iters, self.config.exec_log_max_entries);
        }
        const log = self.execLogFor(trace_id) catch return null;
        const rec = &self.exec_recorder.?;
        rec.retarget(log);
        return rec;
    }

    /// Find-or-create the `TraceExecLog` for `trace_id`. Linear scan — the cache is
    /// small and so is the set of executed traces.
    fn execLogFor(self: *TraceState, trace_id: u32) !*execlog.TraceExecLog {
        for (self.exec_logs.items) |*l| {
            if (l.trace_id == trace_id) return l;
        }
        try self.exec_logs.append(self.gpa, .{ .trace_id = trace_id });
        return &self.exec_logs.items[self.exec_logs.items.len - 1];
    }

    /// The trace cached for `(proto, pc)` with the highest hit count, or null.
    /// Frequency-based prioritisation: the trace that has committed the most
    /// useful iterations is returned first, so the common path is tried before
    /// rare alternatives.  Stable — does not thrash on alternating types.
    pub fn findTrace(self: *const TraceState, proto: *const Proto, pc: u32) ?*Trace {
        var best: ?*Trace = null;
        var best_hits: u64 = 0;
        for (self.cache.items) |t| {
            // Doc 33 §3(b): consec_refusals is tracked but does NOT suppress
            // selection. Suppression deadlocks: a skipped trace can never be
            // entered, so the counter can never reset. The refusal is already
            // free (no anchor penalty), so the cost of a futile prologue
            // attempt is one native call + ledger row per dispatch — bounded
            // by the caller's own iteration count, not by the counter.
            if (t.anchor.proto == proto and t.anchor.pc == pc) {
                if (best == null or t.hit_count > best_hits) {
                    best = t;
                    best_hits = t.hit_count;
                }
            }
        }
        return best;
    }

    /// Highest-hit cached root trace at `(proto, pc)`. Link hand-offs are only
    /// sound to a real loop-root terminal; a continuation at the same bytecode PC
    /// is not an entry target for `.link`.
    /// A `t` resolved from a fused exit's `final_trace_id` is only safe to consume
    /// as "the inner root that just ran under fusion at `pc`" when it has the exact
    /// shape `findLoopTrace` requires: a `.loop`-terminated root anchored at
    /// `(proto, pc)`. Used to FAIL CLOSED — a fused result must be interpreted as
    /// the trace whose id it baked, never substituted by a same-PC sibling; if the id
    /// resolves to the wrong shape/location the child's exit left `regs[]` with no
    /// known-coherent resume PC, so callers `@panic` (hard invariant failure) rather
    /// than indexing a foreign trace's `instrs` (OOB / misclassified exit /
    /// mis-accounting) or silently resuming at a PC that re-runs a committed loop.
    /// B-iv.3 (doc 22 §B.5): seeded roots pass — shape is anchor + `.loop`
    /// terminal only; enterability is `stubEnterable`'s job, not shape's.
    // pub for trace_link.zig (file-split pass)
    pub fn isInnerLoopRoot(t: *const Trace, proto: *const Proto, pc: u32) bool {
        return t.anchor.proto == proto and t.anchor.pc == pc and
            t.instrs.len != 0 and t.instrs[t.instrs.len - 1].op == .loop;
    }

    pub fn findLoopTrace(self: *const TraceState, proto: *const Proto, pc: u32) ?*Trace {
        var best: ?*Trace = null;
        var best_hits: u64 = 0;
        for (self.cache.items) |t| {
            // Doc 33 §3(b): consec_refusals is tracked but does NOT suppress
            // selection. Suppression deadlocks: a skipped trace can never be
            // entered, so the counter can never reset. The refusal is already
            // free (no anchor penalty), so the cost of a futile prologue
            // attempt is one native call + ledger row per dispatch — bounded
            // by the caller's own iteration count, not by the counter.
            if (t.anchor.proto != proto or t.anchor.pc != pc) continue;
            if (t.instrs.len == 0 or t.instrs[t.instrs.len - 1].op != .loop) continue;
            if (best == null or t.hit_count > best_hits) {
                best = t;
                best_hits = t.hit_count;
            }
        }
        return best;
    }

    /// Highest-hit cached `.link` trace at `(proto, pc)` — i.e. a continuation
    /// (doc 15) or a prime side-trace (doc 16). This is the ping-pong *driver*
    /// the linked burst hands control to after an inner-root loop-done: it is
    /// anchored at the post-inner PC and advances the enclosing loop before
    /// linking back to the inner root. Distinct from `findLoopTrace`, which
    /// finds the `.loop`-terminated inner root itself.
    pub fn findLinkTrace(self: *const TraceState, proto: *const Proto, pc: u32) ?*Trace {
        var best: ?*Trace = null;
        var best_hits: u64 = 0;
        for (self.cache.items) |t| {
            // Doc 33 §3(b): consec_refusals is tracked but does NOT suppress
            // selection. Suppression deadlocks: a skipped trace can never be
            // entered, so the counter can never reset. The refusal is already
            // free (no anchor penalty), so the cost of a futile prologue
            // attempt is one native call + ledger row per dispatch — bounded
            // by the caller's own iteration count, not by the counter.
            if (t.anchor.proto != proto or t.anchor.pc != pc) continue;
            if (t.instrs.len == 0 or t.instrs[t.instrs.len - 1].op != .link) continue;
            // B-iv.3 (doc 22 §B.5): seeded continuations are selectable — the
            // tier-1a seams seed via §B.3 and a native page seeds itself at
            // entry (§B.4 prologue), declining cleanly through the B-iv.2
            // directives when stale.
            if (best == null or t.hit_count > best_hits) {
                best = t;
                best_hits = t.hit_count;
            }
        }
        return best;
    }

    /// B-4 (doc 17 §B4.3 D1'–D4'): the ONE canonical loop-done continuation
    /// selector every loop-done funnel shares — the drain's terminal directive
    /// and the arm sites resolve through this, never through the replay
    /// cursor's path history, so the armed relation per `(inner, exit)` is a
    /// stable pure function of the cache and cannot alternate (§B4.7 MAJOR-2).
    pub const LoopDoneCont = struct { arm: ?*Trace, run: ?*Trace };

    pub fn resolveLoopDoneCont(self: *TraceState, proto: *const Proto, post_pc: u32, regs: ?RegWindow) LoopDoneCont {
        // (1) Build the pure, canonically ordered candidate list FIRST — the
        // `findLinkTrace` structural P-G predicate only (`.link`-tailed,
        // anchored at `(proto, post_pc)`; B-iv.3 admits seeded candidates —
        // enterability is probed downstream); nothing in this pass
        // triggers compilation. Ranking: `hit_count` desc, then LOWEST trace id
        // (deterministic and stable across `cache.swapRemove` reshuffles —
        // §B4.7 tie-break correction). Fixed buffer, allocation-free: this runs
        // per terminal loop-done event. Overflow drops the lowest-ranked tail
        // (a pc with more than 8 eligible continuations exceeds
        // `max_traces_per_anchor` by 2× — unreachable today, bounded anyway).
        var buf: [8]*Trace = undefined;
        var n: usize = 0;
        for (self.cache.items) |t| {
            // Doc 33 §3(b): consec_refusals is tracked but does NOT suppress
            // selection. Suppression deadlocks: a skipped trace can never be
            // entered, so the counter can never reset. The refusal is already
            // free (no anchor penalty), so the cost of a futile prologue
            // attempt is one native call + ledger row per dispatch — bounded
            // by the caller's own iteration count, not by the counter.
            if (t.anchor.proto != proto or t.anchor.pc != post_pc) continue;
            if (t.instrs.len == 0 or t.instrs[t.instrs.len - 1].op != .link) continue;
            var pos: usize = n;
            for (buf[0..n], 0..) |p, idx| {
                if (t.hit_count > p.hit_count or (t.hit_count == p.hit_count and t.id < p.id)) {
                    pos = idx;
                    break;
                }
            }
            if (pos >= buf.len) continue;
            const limit = @min(n + 1, buf.len);
            var j: usize = limit - 1;
            while (j > pos) : (j -= 1) buf[j] = buf[j - 1];
            buf[pos] = t;
            n = limit;
        }
        // (2) ARM target: probe `nativeFor` strictly in ranking order and stop
        // at the FIRST runnable candidate — an `.unsupported` (or
        // compile-failing, memoized) high-hit candidate must skip, not shadow,
        // a runnable sibling (§B4.7 BLOCKER). Probing here, before the run
        // resolution, pins the canonical lazy-compile order (D4').
        var arm_target: ?*Trace = null;
        for (buf[0..n]) |t| {
            if (self.nativeFor(t) != null) {
                arm_target = t;
                break;
            }
        }
        // (3) RUN target, resolved AFTER the arm probe over the same list:
        // when `regs` are provided, fingerprint-matching runnable candidates
        // rank strictly above non-matching ones; otherwise (and when nothing
        // matches) it falls back to the arm target — a mismatching candidate is
        // safe to ATTEMPT (the native prologue fails closed pre-commit), just
        // never preferred. The run choice never touches the armed slot.
        var run: ?*Trace = arm_target;
        if (regs) |r| {
            for (buf[0..n]) |t| {
                if (self.nativeFor(t) == null) continue;
                if (t.matchesFingerprint(r)) {
                    run = t;
                    break;
                }
            }
        }
        return .{ .arm = arm_target, .run = run };
    }

    /// Highest-`hit_count` trace at `(proto, pc)` that is not in `visited`, or
    /// null. Same-anchor walks (the dispatch trial loop and exit-PC chaining)
    /// use this with a growing `visited` set so they visit each candidate
    /// **exactly once** and always terminate: a single-`skip` cursor would make
    /// two equal-priority traces cycle `A→B→A→…` forever whenever both zero-exit
    /// on the same registers (e.g. two stale narrow-lane traces once the live
    /// array has widened past both — see widen-eviction).
    pub fn nextTraceExcluding(self: *const TraceState, proto: *const Proto, pc: u32, visited: []const *Trace) ?*Trace {
        var best: ?*Trace = null;
        var best_hits: u64 = 0;
        outer: for (self.cache.items) |t| {
            // Doc 33 §3(b): consec_refusals is tracked but does NOT suppress
            // selection. Suppression deadlocks: a skipped trace can never be
            // entered, so the counter can never reset. The refusal is already
            // free (no anchor penalty), so the cost of a futile prologue
            // attempt is one native call + ledger row per dispatch — bounded
            // by the caller's own iteration count, not by the counter.
            if (t.anchor.proto != proto or t.anchor.pc != pc) continue;
            for (visited) |v| {
                if (v == t) continue :outer;
            }
            if (best == null or t.hit_count > best_hits) {
                best = t;
                best_hits = t.hit_count;
            }
        }
        return best;
    }

    /// Is a trace already cached for this anchor? (Prevents re-arming.)
    pub fn hasTrace(self: *const TraceState, anchor: AnchorKey) bool {
        return self.findTrace(anchor.proto, anchor.pc) != null;
    }

    /// The cache index (`trace_id`) of a cached trace, or null if not present. This
    /// id is the exec-log key and the viz's trace-selection key. Linear scan (the
    /// cache is small; only the instrumented path calls this).
    pub fn traceIndex(self: *const TraceState, t: *const Trace) ?u32 {
        for (self.cache.items, 0..) |c, i| {
            if (c == t) return @intCast(i);
        }
        return null;
    }

    /// Resolve a stable `Trace.id` (P-B, doc 17 — baked into native exit code as
    /// `final_trace_id`) to its live `*Trace`, or null if no cached trace carries it
    /// (the trace retired, or the id is the `NO_TRACE_ID` sentinel). Linear scan,
    /// mirroring `traceIndex`; ids are unique, so at most one match.
    /// Bump a memo-invalidation generation, skipping the reserved 0 ("never
    /// computed") on u32 wrap — otherwise, ~2^32 mutations in, a freshly
    /// initialized memo (gen 0) would be trusted without ever computing (codex
    /// review of f613c98; same hazard for both `cache_gen` and
    /// `region_defs_gen`).
    // pub for trace_link.zig (file-split pass)
    pub fn bumpGen(gen: *u32) void {
        gen.* +%= 1;
        if (gen.* == 0) gen.* = 1;
    }

    pub fn traceById(self: *const TraceState, id: u32) ?*Trace {
        // O(1) fast path via the id index; a hit is authoritative. A null slot or
        // out-of-range id falls back to the linear scan — that covers hand-built
        // test traces appended straight to `cache` (never indexed) and any
        // fail-soft grow-OOM at commit. For real retired ids both paths miss.
        if (id < self.trace_by_id.items.len) {
            if (self.trace_by_id.items[id]) |t| return t;
        }
        for (self.cache.items) |c| {
            if (c.id == id) return c;
        }
        return null;
    }

    /// A frame of the executor value scratch: where `valuesRelease` must rewind
    /// to. Take it BEFORE the matching `valuesPush`, release it after the last
    /// read of the pushed slice — the release ends the frame's lifetime, so a
    /// `defer` must sit in a scope that outlives every use of the buffer, not in
    /// the block that happens to acquire it.
    /// A mark records the chunk and the OFFSET INTO IT, not the free slice
    /// itself. Storing the slice looks cheaper and is wrong at the base: the
    /// first mark of a session is taken before any chunk exists, so its free
    /// slice is empty, and releasing to it left `values_free` empty even though
    /// chunk 0 was by then allocated and idle. Every subsequent push then missed
    /// the fast path and took the chunk-acquiring one — the cold path ran once
    /// per trace entry (0.65% of scimark-fft, ~45M instructions) and the stack
    /// ping-ponged between two chunks forever. An offset reconstructs correctly
    /// from a base mark, because offset 0 of chunk 0 is the whole chunk.
    pub const ValuesMark = struct { cur: u32, used: u32 };

    /// Slots per scratch chunk (64 KiB at 16 B/`Value`). A frame bigger than
    /// this gets its own exactly-sized chunk, so this is a packing knob only —
    /// no correctness invariant rests on it, and in particular it need not track
    /// `config.maxrecord`.
    const values_chunk_slots: usize = 4096;

    pub fn valuesMark(self: *const TraceState) ValuesMark {
        return .{ .cur = self.values_cur, .used = self.valuesUsed() };
    }

    /// Rewind to `mark`, ending the lifetime of every frame pushed after it.
    /// `cur` has to travel with the offset: a push that spilled into a later
    /// chunk must hand that chunk back, or each release would strand one.
    pub fn valuesRelease(self: *TraceState, mark: ValuesMark) void {
        self.values_cur = mark.cur;
        self.values_free = if (mark.cur < self.values_chunks.items.len)
            self.values_chunks.items[mark.cur][mark.used..]
        else
            &.{};
    }

    /// How far into the current chunk the deepest live frame reaches. Derived
    /// from `values_free` rather than stored, so the push fast path writes one
    /// field instead of two.
    fn valuesUsed(self: *const TraceState) u32 {
        if (self.values_cur >= self.values_chunks.items.len) return 0;
        return @intCast(self.values_chunks.items[self.values_cur].len - self.values_free.len);
    }

    /// Carve a fresh `n`-slot frame for `irinterp.execute`'s `values`. The
    /// returned slice stays valid until the matching `valuesRelease`, INCLUDING
    /// across nested pushes — that stability is the whole point of the segmented
    /// backing (see `values_chunks`). Contents are undefined; the executor
    /// writes every `Ref` it reads.
    pub inline fn valuesPush(self: *TraceState, n: usize) ![]Value {
        // Fits in what is left of the chunk we are already carving from. Also
        // the `n == 0` case (a trace with no instructions), which takes nothing.
        // Split hot/cold: this arm is taken on essentially every trace entry and
        // wants to inline into the dispatcher, while the chunk-acquiring arm
        // below runs a handful of times per process and carries the fallible
        // allocation. Folding them into one body left the whole thing outlined
        // and cost ~1% of scimark-fft in call overhead on the native path — the
        // path that does not even use the buffer.
        if (self.values_free.len >= n) {
            const out = self.values_free[0..n];
            self.values_free = self.values_free[n..];
            return out;
        }
        return self.valuesPushNewChunk(n);
    }

    fn valuesPushNewChunk(self: *TraceState, n: usize) ![]Value {
        @branchHint(.cold);
        // Take the NEXT chunk whole rather than straddling. By the
        // LIFO discipline every chunk from here up holds no live frame, so an
        // undersized one may be freed and replaced outright. Nothing below
        // mutates `values_cur`/`values_free` until all fallible work has
        // succeeded, so a failed push leaves the stack exactly as it found it
        // (the callers absorb the error by declining the entry).
        const next: u32 = if (self.values_chunks.items.len == 0) 0 else self.values_cur + 1;
        if (next == self.values_chunks.items.len) {
            const c = try self.gpa.alloc(Value, @max(n, values_chunk_slots));
            errdefer self.gpa.free(c);
            try self.values_chunks.append(self.gpa, c);
        } else if (self.values_chunks.items[next].len < n) {
            const c = try self.gpa.alloc(Value, n);
            self.gpa.free(self.values_chunks.items[next]);
            self.values_chunks.items[next] = c;
        }
        self.values_cur = next;
        const chunk = self.values_chunks.items[next];
        self.values_free = chunk[n..];
        return chunk[0..n];
    }

    /// Account for a trace entry that side-exited after committing `completed`
    /// iterations. The tier-side-exit accounting hook (doc 17 §A3.2), split as of
    /// A-ii.1 and made authoritative on the region side by A-vii-c:
    ///   • `accountTraceRun` — per-segment SELECTION accounting: coverage/cycle
    ///     receipts + the `hit_count` bump for useful (`>= min_useful`) segments.
    ///     As of A-vii-c it no longer touches `penalty`/`gate`.
    ///   • `accountRegionProfit` — the region-profit half (§A3.5). Its window and
    ///     remainder flushes (`flushRegionWindow`) now OWN the penalty/gate state
    ///     machine, keyed by the region owner anchor. A useful full window clears
    ///     the owner's penalty and gate; low-yield remainders strike, and at
    ///     `max_penalty` gate the owner with the doubling cooldown (`gateAnchor`)
    ///     and conservatively disarm all links.
    /// **A-vii-c regionless fallback, A-vii-c.1 consumption form (Bart's decision,
    /// 2026-08-11/12).** The region machine can only gate what discovery
    /// describes, and discovery mints regions exclusively for cycle-bearing SCCs
    /// of the CROSS-ANCHOR structural-edge graph — a plain loop trace or a
    /// same-anchor sibling group has no region at all, so moving the whole penalty
    /// machine to region windows would leave exactly the thrash shapes the gate
    /// exists for (sibling ping-pong committing ~1 iteration per entry, measured
    /// 961 entries/2000 iterations on the parity loop) permanently ungated.
    ///
    /// The ownership boundary is therefore per RECEIPT, keyed on *consumption*:
    /// `accountRegionProfit` reports whether it credited nonzero work to a live
    /// region accumulator, and the legacy per-trace machine runs iff it did not.
    /// Exactly one machine accounts every trace-run receipt, provable from these
    /// three lines rather than inferred from a membership index — which is what
    /// closes the A-vii-c review blocker: physical membership does NOT imply the
    /// region machine can gate a given receipt (a member's prologue failure,
    /// unresolved-guard exit, or any structurally zero-work exit reaches no
    /// window, and R2-1 keeps zero-work flushes silent), so membership-keyed
    /// suppression left those shapes ungated by both machines. Consumption-keyed
    /// suppression cannot: whatever the region machine does not take, the pre-flip
    /// machine still handles.
    ///
    /// This path is null-keyed, so it never consumes and is exactly the pre-flip
    /// per-trace behaviour.
    pub inline fn onSideExit(self: *TraceState, t: *Trace, completed: usize, charge_kind: ChargeKind) void {
        self.accountTraceRun(t, completed);
        if (charge_kind == .entry_refusal) {
            accountCandidateCharge(t, charge_kind);
            return;
        }
        if (self.accountRegionProfit(null, 0, .deferred)) {
            accountCandidateCharge(t, charge_kind);
            return;
        }
        // Gate-fix arc (2026-08-12): a synthetic steering charge fired while a
        // live QUALIFIED activation's footprint contains `t`'s anchor is an
        // intra-complex transition — the region window/close verdicts own its
        // profitability, exactly as for keyed member receipts. Without this the
        // fused dispatcher's own zero-progress charges (`onSideExit(ramp, 0)`,
        // `onSideExit(seed, 0)`) re-condemn the complex through the legacy
        // machine (measured on nsieve: 83,940 `completed=0` strikes/run on the
        // scan anchor, all from these sites, gating the anchor the region
        // machine had just qualified). Consumed-as-barren: a sustained streak
        // still strikes (`noteBarrenConsumed`, codex BLOCKER 2).
        if (self.qualifiedActiveMember(t.anchor.proto, t.anchor.pc)) |m| {
            accountCandidateCharge(t, charge_kind);
            self.noteBarrenConsumed(m.key, m.accum);
            return;
        }
        self.accountLegacyThrash(t, completed, std.math.maxInt(u32), charge_kind);
    }

    /// Concrete receipt variant. Selection keeps its historical per-segment
    /// `completed`; logical-region work is independent (`region_work`) because an
    /// inner loop-done contributes one outer traversal even when its local loop
    /// count is large.
    pub inline fn onSideExitReceipt(
        self: *TraceState,
        t: *Trace,
        completed: usize,
        exit_instr: u32,
        region_work: usize,
        dest: RegionDestination,
        charge_kind: ChargeKind,
    ) void {
        self.accountTraceRun(t, completed);
        if (charge_kind == .entry_refusal) {
            accountCandidateCharge(t, charge_kind);
            return;
        }
        // Doc 38 yield gate: every ENTERED receipt that ended at a while-loop-
        // done guard feeds the per-anchor trip accumulator — regardless of
        // which profitability machine (region or legacy) consumes the receipt
        // below, because the turnstile cost being measured (entry + seam
        // re-entry per 0–2-trip completion) is real either way.
        if (exit_instr < t.instrs.len and isWhileLoopDoneGuardIndex(t, exit_instr)) {
            self.noteWhileYield(t.anchor, completed);
        }
        const key: ?ExitKey = if (exit_instr < t.instrs.len)
            .{ .trace_id = t.id, .exit_instr = exit_instr }
        else
            null;
        // A-vii-c.1: region-first, then legacy iff unconsumed. The two verdicts can
        // only ever touch the same anchor when this receipt's own region closed and
        // flushed against an owner that happens to be `t.anchor`; applying the
        // receipt-local verdict last keeps the most recent evidence authoritative.
        if (!self.accountRegionProfit(key, region_work, dest)) {
            self.accountLegacyThrash(t, completed, exit_instr, charge_kind);
        } else {
            accountCandidateCharge(t, charge_kind);
        }
    }

    /// Doc 38 glue-sibling eligibility (see `Config.while_glue_max_avg`): may
    /// this anchor's while-loop-done exit accrue side-trace hotness (and so
    /// grow the cond-false glue sibling)? Deterministic — reads the
    /// `while_yield` probe accumulator: requires a minimum sample of 8
    /// entries in the current window AND an observed average strictly below
    /// the glue ceiling. Consulted by the dispatch loop's hot-exit counting.
    pub fn whileDoneHotnessEligible(self: *const TraceState, anchor: AnchorKey) bool {
        const wy = self.while_yield.get(anchor) orelse return false;
        if (wy.entries < 8) return false;
        return wy.iters < wy.entries *| self.config.while_glue_max_avg;
    }

    /// Doc 38 yield gate: remove `anchor`'s dispatch gate UNLESS it is a
    /// `.low_trip_while` yield gate — those are cleared only by
    /// `noteWhileYield` on a genuinely high-trip completion, because the
    /// receipts reaching the ordinary clear-on-productive paths (1–2-trip
    /// while completions) are precisely the evidence the yield gate exists to
    /// act on. Every other reason keeps its doc 31 D2 clear semantics.
    // pub for trace_regionops.zig (file-split pass)
    pub fn clearDispatchGate(self: *TraceState, anchor: AnchorKey) void {
        // Single-hash form (getEntry + removeByPtr, not getPtr + remove):
        // this runs on every productive receipt, and the extra hash of the
        // two-op form was a measured ~2% of a scimark-lu run.
        const e = self.gate.getEntry(anchor) orelse return;
        if (e.value_ptr.reason == .low_trip_while) return;
        self.gate.removeByPtr(e.key_ptr);
    }

    /// Doc 38 yield gate: account one while-loop-done ENTRY receipt
    /// (`completed` = trips this entry ran; 0 for a zero-trip completion —
    /// the top-of-trace condition guard observed "done" before any body ran).
    /// Rationale: a while completion at ANY trip count is productive-shaped,
    /// so neither the legacy strike machine nor the region machine can see the
    /// per-entry runtime turnstile (entry + seam re-entry; our exits are not
    /// patched branches) that makes a 0–2-trip while NET SLOWER on the trace
    /// tier than on tier-0 — fft_bitreverse pays it 25.5M times per run at
    /// ~1.5 trips average, a measured +17% wall regression. This is the
    /// LuaJIT-shape-free analog of the demoted `min_trip_entry` config: gate
    /// on OBSERVED trips, not a predicted minimum. Pure deterministic
    /// counters (mahina determinism): a `while_yield_window`-entry probe per
    /// anchor; average below `while_yield_min_avg` ⇒ dispatch gate with the
    /// standard doubling cooldown; `max_strikes` abandons the anchor to
    /// tier-0 for good. Recovery is probe-based, not per-receipt: after the
    /// cooldown the anchor free-runs one more window, and a probe whose
    /// average clears the bar simply never re-gates. (A per-receipt "one
    /// high-trip completion lifts the gate" rule was tried first and
    /// oscillated: chain-driven entries — driveChain does not consult the
    /// dispatch gate — kept delivering occasional 6-trip completions that
    /// un-gated an anchor still averaging <1 trip/entry, measured live on
    /// fft_bitreverse pc=55: `entries=64 iters=58 -> gate` then
    /// `completed=6 -> ungate`, forever.)
    fn noteWhileYield(self: *TraceState, anchor: AnchorKey, completed: usize) void {
        const min_avg = self.config.while_yield_min_avg;
        if (min_avg == 0) return; // knob disabled
        const gop = self.while_yield.getOrPut(self.gpa, anchor) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{ .entries = 0, .iters = 0 };
        gop.value_ptr.entries +|= 1;
        gop.value_ptr.iters +|= @as(u32, @intCast(@min(completed, std.math.maxInt(u32))));
        if (gop.value_ptr.entries >= self.config.while_yield_window) {
            const entries = gop.value_ptr.entries;
            const iters = gop.value_ptr.iters;
            gop.value_ptr.* = .{ .entries = 0, .iters = 0 };
            if (iters < entries *| min_avg) {
                self.dbg("while-yield: anchor pc={d} probe entries={d} iters={d} (< {d}) -> gate", .{ anchor.pc, entries, iters, entries *| min_avg });
                self.gateAnchor(anchor, .low_trip_while);
            }
        }
    }

    // Region-ops: accounting, bridges, provenance, observer cache — moved to trace_regionops.zig (file-split pass);
    // forwarding decls keep every `self.foo(...)` / `TraceState.Foo` spelling working.
    pub const accountLegacyThrash = trace_regionops_mod.accountLegacyThrash;
    pub const accountLedgerRow = trace_regionops_mod.accountLedgerRow;
    pub const accountCandidateCharge = trace_regionops_mod.accountCandidateCharge;
    pub const accountLedgerRowsBulk = trace_regionops_mod.accountLedgerRowsBulk;
    pub const sameAnchor = trace_regionops_mod.sameAnchor;
    pub const flushRegionWindow = trace_regionops_mod.flushRegionWindow;
    pub const closeRegion = trace_regionops_mod.closeRegion;
    pub const demotePromotionsForRegion = trace_regionops_mod.demotePromotionsForRegion;
    pub const demotePromotionsForRegionReason = trace_regionops_mod.demotePromotionsForRegionReason;
    pub const prepareNativeEntry = trace_regionops_mod.prepareNativeEntry;
    pub const silentStaging = trace_regionops_mod.silentStaging;
    pub const freeObserverFast = trace_regionops_mod.freeObserverFast;
    pub const refreshObserverFast = trace_regionops_mod.refreshObserverFast;
    pub const activeRegionFor = trace_regionops_mod.activeRegionFor;
    pub const openRegion = trace_regionops_mod.openRegion;
    pub const invalidateRegion = trace_regionops_mod.invalidateRegion;
    pub const RegionBridgeDecision = trace_regionops_mod.RegionBridgeDecision;
    pub const RegionBridgeVerdict = trace_regionops_mod.RegionBridgeVerdict;
    pub const traceInRegion = trace_regionops_mod.traceInRegion;
    pub const resolveRegionBridgeChild = trace_regionops_mod.resolveRegionBridgeChild;
    pub const slotInSortedSet = trace_regionops_mod.slotInSortedSet;
    pub const validateRegionBridge = trace_regionops_mod.validateRegionBridge;
    pub const tryArmRegionBridge = trace_regionops_mod.tryArmRegionBridge;
    pub const maybeArmCompositeExit = trace_regionops_mod.maybeArmCompositeExit;
    pub const drainPendingBridgeArm = trace_regionops_mod.drainPendingBridgeArm;
    pub const drainProvenanceArms = trace_regionops_mod.drainProvenanceArms;
    pub const captureProvenanceVerdicts = trace_regionops_mod.captureProvenanceVerdicts;
    pub const provenanceEdgeVerdict = trace_regionops_mod.provenanceEdgeVerdict;
    pub const applyProvenanceVerdicts = trace_regionops_mod.applyProvenanceVerdicts;
    pub const stageSilentSiblingProvenance = trace_regionops_mod.stageSilentSiblingProvenance;
    pub const stageSilentSuffixProvenance = trace_regionops_mod.stageSilentSuffixProvenance;
    pub const applyPendingDisarms = trace_regionops_mod.applyPendingDisarms;
    pub const chooseSource = trace_regionops_mod.chooseSource;
    pub const applyDestination = trace_regionops_mod.applyDestination;
    pub const accountRegionProfit = trace_regionops_mod.accountRegionProfit;
    pub const creditRegionWork = trace_regionops_mod.creditRegionWork;
    pub const noteBarrenConsumed = trace_regionops_mod.noteBarrenConsumed;
    pub const clearMemberAnchorState = trace_regionops_mod.clearMemberAnchorState;
    pub const regionMemberTraceAnchor = trace_regionops_mod.regionMemberTraceAnchor;
    pub const traceRegionMemberMemo = trace_regionops_mod.traceRegionMemberMemo;
    pub const regionMemberPoint = trace_regionops_mod.regionMemberPoint;
    pub const MemberAccum = trace_regionops_mod.MemberAccum;
    pub const qualifiedActiveMember = trace_regionops_mod.qualifiedActiveMember;
    pub const refreshActCache = trace_regionops_mod.refreshActCache;
    pub const observeFast = trace_regionops_mod.observeFast;
    pub const observeRegionProgramPoint = trace_regionops_mod.observeRegionProgramPoint;
    pub const dropRegionActivation = trace_regionops_mod.dropRegionActivation;
    pub const resetRegionProfit = trace_regionops_mod.resetRegionProfit;
    pub const regionProfitCount = trace_regionops_mod.regionProfitCount;
    pub const setRegionContext = trace_regionops_mod.setRegionContext;
    pub const accountTraceRun = trace_regionops_mod.accountTraceRun;
    pub const gateNativeUnsupported = trace_regionops_mod.gateNativeUnsupported;

    // Dispatch/burst/replay chain drivers — moved to trace_chain.zig (file-split
    // pass); forwarding decls keep every `self.foo(...)` / `TraceState.Foo`
    // spelling working (incl. TraceState.NativeCallProvenance in tests).
    pub const seedForTier1a = trace_chain_mod.seedForTier1a;
    pub const StubEntryKind = trace_chain_mod.StubEntryKind;
    pub const stubEnterable = trace_chain_mod.stubEnterable;
    pub const StubEnterability = trace_chain_mod.StubEnterability;
    pub const liveEpisodeProto = trace_chain_mod.liveEpisodeProto;
    pub const stubEnterability = trace_chain_mod.stubEnterability;
    pub const driveChain = trace_chain_mod.driveChain;
    pub const driveSeedSilentResult = trace_chain_mod.driveSeedSilentResult;
    pub const LedgerReplay = trace_chain_mod.LedgerReplay;
    pub const ReplayOrigin = trace_chain_mod.ReplayOrigin;
    pub const BurstCursor = trace_chain_mod.BurstCursor;
    pub const FrozenFast = trace_chain_mod.FrozenFast;
    pub const OrdinaryGuardEntry = trace_chain_mod.OrdinaryGuardEntry;
    pub const EntryMaterialization = trace_chain_mod.EntryMaterialization;
    pub const ReplayCursor = trace_chain_mod.ReplayCursor;
    pub const SuffixInit = trace_chain_mod.SuffixInit;
    pub const applyEdgeCursorTransition = trace_chain_mod.applyEdgeCursorTransition;
    pub const SilentCellOwner = trace_chain_mod.SilentCellOwner;
    pub const silentCellOwner = trace_chain_mod.silentCellOwner;
    pub const SilentSiblingEvidence = trace_chain_mod.SilentSiblingEvidence;
    pub const silentSiblingEvidence = trace_chain_mod.silentSiblingEvidence;
    pub const driveSilentBurst = trace_chain_mod.driveSilentBurst;
    pub const drainSilentResult = trace_chain_mod.drainSilentResult;
    pub const captureSilentSuffixProvenance = trace_chain_mod.captureSilentSuffixProvenance;
    pub const NativeCallProvenance = trace_chain_mod.NativeCallProvenance;
    pub const NativeCallOrigin = trace_chain_mod.NativeCallOrigin;
    pub const captureNativeCallProvenance = trace_chain_mod.captureNativeCallProvenance;
    pub const settleNativeCallProvenance = trace_chain_mod.settleNativeCallProvenance;
    pub const replayLedger = trace_chain_mod.replayLedger;
    pub const replayLedgerSuffix = trace_chain_mod.replayLedgerSuffix;
    pub const replayLedgerFrom = trace_chain_mod.replayLedgerFrom;
    pub const runLinkedBurst = trace_chain_mod.runLinkedBurst;
    pub const driveBurstCore = trace_chain_mod.driveBurstCore;
    pub const noteDispatcherLedgerTerminal = trace_chain_mod.noteDispatcherLedgerTerminal;
    pub const driveDispatcherLedger = trace_chain_mod.driveDispatcherLedger;
    pub const finishDispatcherDirective = trace_chain_mod.finishDispatcherDirective;
    pub const driveDispatcherSilentResult = trace_chain_mod.driveDispatcherSilentResult;
    pub const driveSeedLedger = trace_chain_mod.driveSeedLedger;

    // ----- moved to trace_link.zig (file-split pass): exit/continuation
    // lifecycle + successor resolution. See the forwarding-block comment below.
    pub const hasNativeLoopDoneLink = trace_link_mod.hasNativeLoopDoneLink;
    pub const computeNativeLoopDoneLink = trace_link_mod.computeNativeLoopDoneLink;
    pub const maybeArmContinuation = trace_link_mod.maybeArmContinuation;
    pub const continuationReachesEnclosingBackEdge = trace_link_mod.continuationReachesEnclosingBackEdge;
    pub const maybeStartContinuation = trace_link_mod.maybeStartContinuation;
    pub const maybeStartReplaySide = trace_link_mod.maybeStartReplaySide;
    pub const clearPendingExitAnchor = trace_link_mod.clearPendingExitAnchor;
    pub const noteTakenExit = trace_link_mod.noteTakenExit;
    pub const countGuardFailure = trace_link_mod.countGuardFailure;
    pub const countFingerprintMiss = trace_link_mod.countFingerprintMiss;
    pub const isSourceBranchGuardExit = trace_link_mod.isSourceBranchGuardExit;
    pub const hasArmedSourceBranchLinkAt = trace_link_mod.hasArmedSourceBranchLinkAt;
    pub const countTracesAt = trace_link_mod.countTracesAt;
    pub const anchorPopulation = trace_link_mod.anchorPopulation;
    pub const hasInnerRootAt = trace_link_mod.hasInnerRootAt;
    pub const forLoopEndFor = trace_link_mod.forLoopEndFor;
    pub const SuccAnchor = trace_link_mod.SuccAnchor;
    pub const resolveSuccessorAnchor = trace_link_mod.resolveSuccessorAnchor;
    pub const resolveCompositeBridgeSuccessor = trace_link_mod.resolveCompositeBridgeSuccessor;
    pub const compositeContinueProof = trace_link_mod.compositeContinueProof;

    // Edge-cache / region rebuilds — moved to trace_regionops.zig (file-split pass);
    // forwarding decls keep every `self.foo(...)` / `TraceState.Foo` spelling working.
    pub const rebuildEdgeCache = trace_regionops_mod.rebuildEdgeCache;
    pub const rebuildEdgeCacheFallible = trace_regionops_mod.rebuildEdgeCacheFallible;
    pub const clearPhysicalRegionIndices = trace_regionops_mod.clearPhysicalRegionIndices;
    pub const rebuildRegions = trace_regionops_mod.rebuildRegions;
    pub const rebuildRegionsFallible = trace_regionops_mod.rebuildRegionsFallible;
    pub const closeNonArmableAccumulators = trace_regionops_mod.closeNonArmableAccumulators;
    pub const classifyExit = trace_regionops_mod.classifyExit;

    /// Widen-eviction predicate: is trace `t` permanently dead because the live
    /// array its `guard_lane` pins has monotonically widened past the trace's
    /// recorded lane?  A trace specialises on `tbl.array.lane == aux`; lanes only
    /// ever widen (`array.zig`, `Lane.canWidenTo`) and never re-narrow, so once
    /// the live table sits on a lane that cannot reach the recorded lane, the
    /// guard can never pass again.  Re-derived from the live `regs` (not the
    /// failing-guard index), so it holds identically whether the trace ran on
    /// tier-1a or native — it does not depend on which guard failed.
    ///
    /// Returns true if *any* of `t`'s entry `guard_lane`s is now unsatisfiable.
    /// Reading a now-wider lane off a *different* table that happens to flow
    /// through the same anchor is a benign false positive: eviction only drops a
    /// cache entry (tier-0 stays the oracle and the trace simply re-records), it
    /// can never change observable output.
    pub fn laneWidenedPast(self: *const TraceState, t: *const Trace, regs: RegWindow) bool {
        _ = self;
        for (t.instrs) |ins| {
            if (ins.op != .guard_lane) continue;
            // `guard_lane.a` indexes the table-producing instr; that is a
            // `slot_load` whose `aux` is the tier-0 register the table lives in.
            const ld_idx: usize = @intCast(ins.a);
            if (ld_idx >= t.instrs.len) continue;
            const ld = t.instrs[ld_idx];
            if (ld.op != .slot_load) continue;
            const reg: usize = @intCast(ld.aux);
            if (reg >= regs.len()) continue;
            const v = regs.get(reg);
            if (!v.isHeap() or v.heapType() != .table) continue;
            const live_lane = table_mod.Table.fromHeader(v.asHeap()).array.lane;
            const trace_lane: arr.Lane = @enumFromInt(ins.aux);
            if (live_lane != trace_lane and !live_lane.canWidenTo(trace_lane)) return true;
        }
        return false;
    }

    // ----- moved to trace_link.zig (file-split pass): promotion/demotion,
    // native-link arming, entry patches, cache lifecycle. Forwarding decls
    // keep every `self.X(...)` / `TraceState.X` spelling working; all pub so
    // sibling split files can call them through `self.` too.
    pub const PROMOTED_SET_CAP = trace_link_mod.PROMOTED_SET_CAP;
    pub const PROVENANCE_VERDICT_CAP = trace_link_mod.PROVENANCE_VERDICT_CAP;
    pub const exitPatchFor = trace_link_mod.exitPatchFor;
    pub const patchKindForArm = trace_link_mod.patchKindForArm;
    pub const BridgeValidationError = trace_link_mod.BridgeValidationError;
    pub const validateRegionBridgeReceipt = trace_link_mod.validateRegionBridgeReceipt;
    pub const promotedEdgeFromLink = trace_link_mod.promotedEdgeFromLink;
    pub const PromotionRejectReason = trace_link_mod.PromotionRejectReason;
    pub const rejectPromotion = trace_link_mod.rejectPromotion;
    pub const rowPatchKind = trace_link_mod.rowPatchKind;
    pub const edgeMemberOfRegion = trace_link_mod.edgeMemberOfRegion;
    pub const promotionBelongsToRegion = trace_link_mod.promotionBelongsToRegion;
    pub const detectPromotableSet = trace_link_mod.detectPromotableSet;
    pub const originalRel32Target = trace_link_mod.originalRel32Target;
    pub const patchPromotedEdge = trace_link_mod.patchPromotedEdge;
    pub const promoteSet = trace_link_mod.promoteSet;
    pub const resetPromotionCandidate = trace_link_mod.resetPromotionCandidate;
    pub const samePromotionEdges = trace_link_mod.samePromotionEdges;
    pub const considerSilentPromotion = trace_link_mod.considerSilentPromotion;
    pub const DemotionReason = trace_link_mod.DemotionReason;
    pub const PendingDemotion = trace_link_mod.PendingDemotion;
    pub const queueDemote = trace_link_mod.queueDemote;
    pub const demoteSet = trace_link_mod.demoteSet;
    pub const demoteSetReason = trace_link_mod.demoteSetReason;
    pub const demoteSetsTouching = trace_link_mod.demoteSetsTouching;
    pub const demoteSetsTouchingTrace = trace_link_mod.demoteSetsTouchingTrace;
    pub const demoteAllSets = trace_link_mod.demoteAllSets;
    pub const demoteSetsForRegionDefsMutation = trace_link_mod.demoteSetsForRegionDefsMutation;
    pub const SlotMutationReason = trace_link_mod.SlotMutationReason;
    pub const PreparedSlotMutation = trace_link_mod.PreparedSlotMutation;
    pub const prepareSlotMutation = trace_link_mod.prepareSlotMutation;
    pub const commitSlotMutation = trace_link_mod.commitSlotMutation;
    pub const armNativeLink = trace_link_mod.armNativeLink;
    pub const noteMembershipGrowth = trace_link_mod.noteMembershipGrowth;
    pub const armLinkTerminal = trace_link_mod.armLinkTerminal;
    pub const armLoopDoneLink = trace_link_mod.armLoopDoneLink;
    pub const armLoopDoneLinkTo = trace_link_mod.armLoopDoneLinkTo;
    pub const resetLinksTouching = trace_link_mod.resetLinksTouching;
    pub const disarmAllLinks = trace_link_mod.disarmAllLinks;
    pub const clearSiblingLatch = trace_link_mod.clearSiblingLatch;
    pub const disarmLinkAt = trace_link_mod.disarmLinkAt;
    pub const disarmStaleRegionBridgeLinks = trace_link_mod.disarmStaleRegionBridgeLinks;
    pub const removeTrace = trace_link_mod.removeTrace;
    pub const codeFor = trace_link_mod.codeFor;
    pub const ensureImage = trace_link_mod.ensureImage;
    pub const patchedEntryOp = trace_link_mod.patchedEntryOp;
    pub const resolvePatchPc = trace_link_mod.resolvePatchPc;
    pub const InstallResult = trace_link_mod.InstallResult;
    pub const installEntryPatch = trace_link_mod.installEntryPatch;
    pub const markEntryPatchPending = trace_link_mod.markEntryPatchPending;
    pub const markEntryPatchesAt = trace_link_mod.markEntryPatchesAt;
    pub const drainEntryPatchWork = trace_link_mod.drainEntryPatchWork;
    pub const installPending = trace_link_mod.installPending;
    pub const unpatchSlot = trace_link_mod.unpatchSlot;
    pub const dropEntryPatchState = trace_link_mod.dropEntryPatchState;
    pub const clearCache = trace_link_mod.clearCache;
    pub const clearProvenanceEdges = trace_link_mod.clearProvenanceEdges;
    pub const retireProvenanceEdgesTouching = trace_link_mod.retireProvenanceEdgesTouching;
    pub const condemnProvenanceEdgesAt = trace_link_mod.condemnProvenanceEdgesAt;
    pub const clearGuardFailures = trace_link_mod.clearGuardFailures;
    pub const nativeFor = trace_link_mod.nativeFor;

    /// True while a recording is in flight (the interpreter's recording hook
    /// gates on this).
    pub fn isRecording(self: *const TraceState) bool {
        return self.rec.active;
    }

    /// Doc 26 D1a: kill an active recording because an error is unwinding
    /// through the dispatch loop. Called from `Vm.execWith`'s errdefer — the
    /// raise is not part of the recorded IR, so a surviving recording would
    /// stitch an enclosing pcall's post-catch continuation onto the partial
    /// iteration and could commit a Franken-path trace at the next anchor
    /// reach. Guarded (no-op when idle) so nested `execWith` unwind levels
    /// stay idempotent: the innermost aborts, outer levels see an inactive
    /// recording.
    pub fn abortRaised(self: *TraceState) void {
        if (self.rec.active) self.abort(.raised);
    }

    /// Is this anchor currently gated off tier-1? True while a cooldown window is
    /// still running (back-edge count below `retry_at`) or the anchor has been
    /// permanently abandoned (`strikes >= max_strikes`). False when no gate exists
    /// or its cooldown has elapsed (eligible for one retry). Gates both recording
    /// re-arm (`onBackEdge`) and trace entry (the dispatch loop).
    pub fn isGated(self: *const TraceState, anchor: AnchorKey) bool {
        const g = self.gate.get(anchor) orelse return false;
        if (g.strikes >= self.config.max_strikes) return true;
        return self.tick < g.retry_at;
    }

    /// Doc 31 D1: is `anchor` currently held off *recording* by the record
    /// gate? Same cooldown/permanence arithmetic as `isGated`, separate
    /// history — a record-gated anchor's committed traces keep dispatching.
    pub fn isRecordGated(self: *const TraceState, anchor: AnchorKey) bool {
        const g = self.record_gate.get(anchor) orelse return false;
        if (g.strikes >= self.config.max_strikes) return true;
        return self.tick < g.retry_at;
    }

    /// Doc 31 D1: recording eligibility consults BOTH gates — a
    /// dispatch-gated anchor also declines new recordings (preserving the
    /// old duplicate-suppression), and a record-gated anchor backs off
    /// re-recording without touching dispatch.
    pub fn recordingBarred(self: *const TraceState, anchor: AnchorKey) bool {
        return self.isGated(anchor) or self.isRecordGated(anchor);
    }

    /// Shared escalation arithmetic for both gate maps: start (or double) the
    /// cooldown window and bump the strike count. The next eligibility is
    /// `retry_at` = current global `tick` + window; the window then doubles
    /// (capped at `backoff_max`), and after `max_strikes` the anchor is
    /// abandoned for good. Deterministic — keyed only on the monotonic
    /// back-edge tick. Returns null on OOM (gate simply not escalated).
    fn bumpGateEntry(self: *TraceState, map: *std.AutoHashMapUnmanaged(AnchorKey, Gate), anchor: AnchorKey, reason: GateReason) ?*Gate {
        const gop = map.getOrPut(self.gpa, anchor) catch return null;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .retry_at = 0, .window = self.config.backoff_base, .strikes = 0, .reason = reason };
        }
        const g = gop.value_ptr;
        g.reason = reason;
        g.strikes +|= 1;
        g.retry_at = self.tick +| g.window;
        g.window = @min(g.window *| 2, self.config.backoff_max);
        return g;
    }

    /// Install or escalate the DISPATCH gate on `anchor` (doc 31 D1): its
    /// cached traces are not entered until the cooldown elapses. Sources:
    /// legacy thrash, region decay, native-unsupported — never recording
    /// failures (those go to `gateRecordAnchor`).
    pub fn gateAnchor(self: *TraceState, anchor: AnchorKey, reason: GateReason) void {
        const g = self.bumpGateEntry(&self.gate, anchor, reason) orelse return;
        // Doc 20 unpatch trigger: a dispatch-gated anchor must not keep a
        // patched entry — mark pending; the caller-owned safe-point drain
        // restores same-turn and warming re-decides after the cooldown. A
        // RECORD gate deliberately never unpatches (doc 31 §3).
        self.markEntryPatchesAt(anchor);
        self.dbg("gate[dispatch:{s}]: anchor pc={d} strikes={d} window={d} retry_at={d} tick={d}", .{ @tagName(reason), anchor.pc, g.strikes, g.window, g.retry_at, self.tick });
    }

    /// Install or escalate the RECORD gate on `anchor` (doc 31 D1): no new
    /// recording starts here until the cooldown elapses; committed traces
    /// keep dispatching and their entry patches stay live. Sources:
    /// recording aborts and commit failures (LuaJIT `penalty_pc` analog).
    pub fn gateRecordAnchor(self: *TraceState, anchor: AnchorKey, reason: GateReason) void {
        const g = self.bumpGateEntry(&self.record_gate, anchor, reason) orelse return;
        self.dbg("gate[record:{s}]: anchor pc={d} strikes={d} window={d} retry_at={d} tick={d}", .{ @tagName(reason), anchor.pc, g.strikes, g.window, g.retry_at, self.tick });
    }

    /// Back-edge count recorded for an anchor (0 if never seen). A loop is "hot"
    /// once this reaches `config.hotloop`.
    pub fn backEdgeCount(self: *const TraceState, anchor: AnchorKey) u32 {
        return self.counters.get(anchor) orelse 0;
    }

    // --- hot-count pre-filter ----------------------------------------------

    /// Cheap front gate for the dispatch back-edge handler. Always advances the
    /// global `tick` (so gate cooldowns keep elapsing), then asks: can this
    /// back-edge skip the expensive slow path (`onBackEdge` + trace-entry lookup)?
    ///
    /// Returns `true` (skip — fall straight back to tier-0) when the anchor's
    /// hot-count slot is still counting down. Returns `false` (take the slow path)
    /// when the slot has reached 0, or while a recording is in flight (recording
    /// must see every back-edge so it can close on its own anchor). Only gated /
    /// dead loops ever get a non-zero slot, so hot traced loops and warming loops
    /// always take the slow path and behave exactly as before the pre-filter.
    pub inline fn skipBackEdge(self: *TraceState, proto: *const Proto, pc: u32) bool {
        self.tick +%= 1;
        if (self.rec.active) return false;
        const slot = &self.hotcount[hotIndex(proto, pc)];
        if (slot.* > 0) {
            slot.* -= 1;
            return true;
        }
        return false;
    }

    /// Called after a back-edge took the slow path *without* entering a trace (the
    /// dispatch loop skips this when a trace entry succeeded). If the anchor is
    /// gated, arm its hot-count slot with a `GATE_SKIP` window so the next batch of
    /// back-edges skips the hashmap bookkeeping entirely. `tick` keeps advancing
    /// across the skip, so the gate's cooldown still elapses on schedule and the
    /// anchor is reconsidered when the window expires.
    ///
    /// Doc 31 D1 amendment (measured on the first post-split board): a RECORD-gated
    /// anchor with NO committed trace must also arm the skip — the slow path can
    /// do nothing there (no trace to enter, recording barred), and without the
    /// skip every abort-blacklisted hot loop pays full `onBackEdge` bookkeeping on
    /// every back-edge forever (tbl_ops +40%, euler14-bit +55%, nsieve-bit-fp
    /// +57% jit-vs-t0 drag; pre-split these anchors were dispatch-gated and
    /// skipped). A record-gated anchor WITH a trace must NOT skip: the slow path
    /// is exactly what enters its trace (the review-B3 starvation concern).
    pub fn afterBackEdge(self: *TraceState, proto: *const Proto, pc: u32) void {
        const key: AnchorKey = .{ .proto = proto, .pc = pc };
        if (self.isGated(key) or (self.isRecordGated(key) and !self.hasTrace(key))) {
            self.hotcount[hotIndex(proto, pc)] = GATE_SKIP;
        }
    }

    /// Install a precise hot-count skip of `n` back-edges on `anchor`. Used by the
    /// dispatch loop when it declines to enter a numeric-`for` trace on trip-count
    /// grounds: the rest of that short invocation (exactly `trip - 1` back-edges —
    /// the final `for_loop` exits without one) should run on tier-0 without each
    /// back-edge re-paying full `onBackEdge` bookkeeping, but the window must NOT
    /// bleed past this invocation or it could skip the entry of a following
    /// profitable (long) invocation at the same anchor. Because the count is exact,
    /// it never bleeds. Unlike `GATE_SKIP` this does not imply the anchor is gated.
    pub fn armShortLoopSkip(self: *TraceState, proto: *const Proto, pc: u32, n: u64) void {
        self.hotcount[hotIndex(proto, pc)] = @intCast(@min(n, std.math.maxInt(u16)));
    }

    // --- state machine -----------------------------------------------------

    /// Part S / side-trace precision: consume a pending `wants_side_trace` at a
    /// LEDGER-burst deopt resume instead of waiting for the next back-edge.
    ///
    /// The back-edge consumption in `onBackEdge` is one iteration too late for a
    /// zero-progress deopt: the resume re-runs the FAILING iteration in tier-0, that
    /// iteration's closing back-edge arms the recording, and recording then starts on
    /// the iteration AFTER the failing one — which on an alternating-shape loop is
    /// almost always the other (already-traced) shape. Measured on nsieve N=9: the
    /// zero-trip exit crossed `hotguard`, and every recording it triggered captured
    /// the composite-skip path again — two duplicate traces and the zero-trip shape
    /// still stranded on the runtime turnstile. Arming AT the resume records the
    /// re-run of the failing iteration itself, so the captured path is by
    /// construction the one whose guard kept failing.
    ///
    /// Same guards as the back-edge consumption: gated anchors decline, and the
    /// anchor's failure counters reset so the next crossing needs fresh evidence.
    /// Returns true iff a recording was armed — the caller must then hand the
    /// dispatch loop to `.full` (recording records via the `.full` prologue mirror;
    /// arming from `.fast` and sailing on records NOTHING and commits an empty
    /// trace at the next back-edge, which is exactly what the first cut did).
    /// Arms via `pending_replay_anchor` → `maybeStartReplaySide`, the doc-16
    /// replay-side machinery built for precisely this "record the re-run of the
    /// current iteration from the coherent anchor" shape — not via a raw `arm()`,
    /// which is a back-edge-site primitive.
    pub fn consumeSideTraceWantAtResume(self: *TraceState, proto: *const Proto, resume_pc: u32) bool {
        const wanted = self.wants_side_trace orelse return false;
        if (wanted.proto != proto or wanted.pc != resume_pc) return false;
        const src = self.side_want_src;
        self.wants_side_trace = null;
        self.side_want_src = null;
        const key = AnchorKey{ .proto = proto, .pc = resume_pc };
        if (self.isRecording() or self.pending_replay_anchor != null or self.recordingBarred(key))
            return false;
        self.dbg("side-want-at-resume: arming replay-side recording at pc={d}", .{resume_pc});
        self.pending_replay_anchor = key;
        self.pending_replay_src = src;
        self.clearGuardFailures(key);
        return true;
    }

    /// Close an in-flight recording when dispatch reaches its anchor again through
    /// any control-flow edge. `onBackEdge` handles the common backward edge, but a
    /// nested loop may leave its anchor and later re-enter it through forward flow
    /// after an enclosing back-edge. Waiting for another matching back-edge then
    /// records multiple logical iterations, over-specialising every intervening
    /// branch and heap relation. Called before the dispatch mirror, so the anchor
    /// instruction belongs to the next iteration, not the one being committed.
    pub fn maybeCloseAtAnchor(self: *TraceState, proto: *const Proto, cur_pc: u32, regs: RegWindow) void {
        if (!self.rec.active or self.rec.instrs.items.len == 0) return;
        if (self.rec.anchor.proto == proto and self.rec.anchor.pc == cur_pc) {
            self.closeTrace(regs);
        }
    }

    /// Called by the interpreter whenever a back-edge fires (a backward/self jump
    /// to `target_pc`). Drives the trace lifecycle:
    ///  * **recording, this anchor** → the iteration closed cleanly: commit.
    ///  * **recording, another anchor** → an inner-loop back-edge: keep going
    ///    (the `maxrecord` budget bounds inner-loop unrolling).
    ///  * **not recording** → count this back-edge; on *crossing* `hotloop` (and
    ///    if the anchor is neither already traced nor blacklisted), arm a fresh
    ///    recording that begins on the next loop iteration (at the anchor).
    pub fn onBackEdge(self: *TraceState, proto: *const Proto, target_pc: u32, regs: RegWindow) void {
        if (self.rec.active) {
            if (self.rec.anchor.proto == proto and self.rec.anchor.pc == target_pc) {
                self.closeTrace(regs);
            }
            return;
        }
        const key = AnchorKey{ .proto = proto, .pc = target_pc };

        // Side-trace arming (step 4): a guard inside a trace at this anchor has
        // failed enough times — arm a new recording on the next iteration, even
        // though a trace already exists here. The side trace captures the
        // alternate path through the loop body. This legitimately targets an
        // already-traced anchor, so it must run *before* the has-trace fast path
        // below.
        if (self.wants_side_trace) |wanted| {
            if (wanted.proto == proto and wanted.pc == target_pc) {
                if (!self.recordingBarred(key)) {
                    self.arm(proto, target_pc);
                    // Hotexit provenance rides into the recording so the commit
                    // can DONE-latch the parent exit (`arm` may decline — OOM —
                    // in which case `rec.active` is false and there is nothing
                    // to carry).
                    if (self.rec.active) self.rec.side_src = self.side_want_src;
                    // Clear guard-failure counters for this anchor so we don't
                    // immediately re-trigger on the next outer-loop iteration.
                    self.clearGuardFailures(key);
                }
                self.wants_side_trace = null;
                self.side_want_src = null;
                return;
            }
        }

        // Hot native re-entry fast path. Once an anchor is traced, the warming
        // counter can never arm again (`hasTrace` already gated arming below) and
        // nothing functional reads it — only the warming phase and tests do. So
        // for a traced anchor we skip the per-back-edge hashmap bookkeeping
        // entirely: this removes a wyhash `counters.getOrPut` from *every*
        // tier-0 → native trace entry, which is the dominant remaining hash cost
        // on matmul-class loops that re-enter a native inner trace tens of
        // thousands of times. The dispatch loop's own trace-entry walk owns
        // re-entry from here; the cheap linear cache scan in `hasTrace` (a handful
        // of pointer compares) replaces the hash probe.
        if (self.hasTrace(key)) return;

        const gop = self.counters.getOrPut(self.gpa, key) catch return;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* +|= 1;
        const count = gop.value_ptr.*;
        // Arm a fresh recording when the anchor first becomes hot, or — if it was
        // gated off after an earlier failure — when its backoff cooldown elapses.
        // Each `==` fires exactly once at the crossing point, so we never re-arm
        // on every later iteration. A gated anchor whose cooldown is still running
        // (or that has exhausted `max_strikes`) is skipped by `isGated`. (The
        // `!hasTrace` arm guard is now redundant — we returned above for traced
        // anchors — so only `isGated` remains.)
        if (!self.recordingBarred(key)) {
            // A gate entry (either map, doc 31 D1) that is no longer barring
            // means its `tick` cooldown has just elapsed → take the one retry
            // now. Arming starts a recording, so the next back-edges are
            // consumed by recording rather than re-arming; we never loop
            // re-arming. A fresh (un-gated) anchor arms on the exact back-edge
            // it first crosses `hotloop`. The probe must consult BOTH maps:
            // recording aborts now live in `record_gate`, and without the
            // second `contains` an aborted root recording — whose warming
            // counter is already past the one-shot `== hotloop` crossing —
            // would never retry (doc 31 §3, review B3).
            const arm_now = if (self.gate.contains(key) or self.record_gate.contains(key))
                true // cooldown elapsed → one retry
            else
                count == self.config.hotloop; // first time crossing hot
            if (arm_now) self.arm(proto, target_pc);
        }
    }

    /// Begin recording at `target_pc`. Sizes the recorder's register map to the
    /// frame; recording proper begins at the next dispatch-loop iteration (which
    /// is the anchor instruction). On OOM we simply don't arm.
    fn arm(self: *TraceState, proto: *const Proto, target_pc: u32) void {
        self.rec.reset(self.gpa, .{ .proto = proto, .pc = target_pc }, proto.num_registers) catch return;
    }

    /// Abandon the in-flight recording: deactivate, remember why, and gate the
    /// anchor with exponential backoff so it is retried progressively less often
    /// (and abandoned after `max_strikes`). Tier-0 is untouched — nothing was ever
    /// executed from the trace.
    // pub for trace_recorder.zig (file-split pass)
    pub fn abort(self: *TraceState, reason: AbortReason) void {
        self.rec.abort_reason = reason;
        if (self.config.record_aborts) self.logAbort(reason);
        self.rec.active = false;
        // Doc 27 §3a defense-in-depth: a dead recording must not leave a multret
        // shadow behind (`reset` is the soundness boundary; this narrows the
        // window further so no code path can observe a shadow past the abort).
        self.rec.multret_top = null;
        // Drop hot-exit provenance with the recording: an abort must never leave
        // `side_src` around to latch a parent exit DONE for a LATER, unrelated
        // commit (Pall retries the exit; `gateAnchor` below is our `penalty_pc`).
        self.rec.side_src = null;
        // Doc 38 unroll-first policy: a ROOT recording that chose to unroll an
        // inner while and then died — for ANY reason (too long, nyi op it only
        // reached because it kept going, guard depth, …) — is one proven
        // unroll failure at this outer anchor. At `unroll_fail_flip` failures
        // `recWhileLink` stops unrolling here and decomposes (LINNER).
        if (self.rec.kind == .root and self.rec.unrolled_while) {
            if (self.unroll_fail.getOrPut(self.gpa, self.rec.anchor)) |gop| {
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* +|= 1;
                self.dbg("unroll-fail (record abort): anchor pc={d} count={d}", .{ self.rec.anchor.pc, gop.value_ptr.* });
            } else |_| {}
        }
        // Doc 38 LLEAVE fast retry: which pass a while/repeat-root recording
        // lands on (cond-true → the body root we want, cond-false → LLEAVE) is
        // a race against the loop's trip pattern, not evidence of
        // untraceability. Count the abort but skip the gate strike while under
        // budget, so the anchor retries at its next hot event; a loop that
        // exhausts the budget has proven a low/zero remaining-trip pattern and
        // strikes normally from then on (and unlocks `recWhileLink`'s
        // innerloopleft unroll). On OOM fall through to the normal strike —
        // fail-closed, never a hotter path.
        if (reason == .loop_leave) {
            if (self.lleave_count.getOrPut(self.gpa, self.rec.anchor)) |gop| {
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* +|= 1;
                if (gop.value_ptr.* < self.config.lleave_fast_retries) {
                    // No gate entry is created, so `onBackEdge`'s retry probe
                    // (`gate.contains or record_gate.contains`) won't fire —
                    // and the warming counter is already past its one-shot
                    // `== hotloop` crossing (the review-B3 starvation shape).
                    // Rewind the counter so the next back-edge re-crosses and
                    // re-arms: the retry lands on the same instance's next
                    // trip, which is exactly the cond-true pass we want.
                    self.counters.put(self.gpa, self.rec.anchor, self.config.hotloop -| 1) catch {};
                    self.dbg("lleave fast-retry: anchor pc={d} count={d}", .{ self.rec.anchor.pc, gop.value_ptr.* });
                    return;
                }
            } else |_| {}
        }
        self.gateRecordAnchor(self.rec.anchor, .record_abort);
    }

    /// Append-or-bump the abort diagnostic log (`--dump-aborts`). Deduped by
    /// `(anchor.pc, reason, op)` so a loop aborting on every back-edge is one row
    /// with a growing `count`, not millions. A linear scan is fine — distinct
    /// abort sites are few (a handful of loops × a handful of reasons), and this is
    /// off the hot path entirely (only runs when `config.record_aborts`). On OOM we
    /// simply drop the row: a diagnostic must never perturb execution.
    fn logAbort(self: *TraceState, reason: AbortReason) void {
        const anchor = self.rec.anchor;
        for (self.abort_log.items) |*r| {
            if (r.anchor_pc == anchor.pc and r.proto == anchor.proto and
                r.reason == reason and r.op == self.rec.cur_op)
            {
                r.count += 1;
                return;
            }
        }
        self.abort_log.append(self.gpa, .{
            .proto = anchor.proto,
            .anchor_pc = anchor.pc,
            .abort_pc = self.rec.cur_pc,
            .op = self.rec.cur_op,
            .reason = reason,
            .ir_len = @intCast(self.rec.instrs.items.len),
        }) catch {};
    }

    /// Doc 39: ops admissible inside a type-stabilizing peel (the register-only
    /// rule, enforced over BOTH passes). A WHITELIST, fail-closed: any op not
    /// listed — stores (`astore`/`astore_append`/`hstore`/`gstore`), allocating
    /// producers (the `.alloc` class), match-scratch writers
    /// (`smatch`/`sfindp`/`sgmatch`/`scap_*`), the gmatch cursor
    /// (`sgm_setpos`), grid ops, `guard_gc`, and anything added later —
    /// declines the peel at pass 1 or aborts it at pass 2. Heap READS are
    /// admitted: effect-free, guarded, and their run-once values persist under
    /// the E1 executor contract.
    fn peelAdmissibleOp(op: IrOp) bool {
        return switch (op) {
            .konst,
            .slot_load,
            .phi,
            .preheader,
            .add,
            .sub,
            .mul,
            .div,
            .idiv,
            .mod,
            .pow,
            .band,
            .bor,
            .bxor,
            .shl,
            .shr,
            .sar,
            .eq,
            .ne,
            .lt,
            .le,
            .neg,
            .not,
            .bnot,
            .int_of_float,
            .guard_int,
            .guard_float,
            .guard_number,
            .guard_true,
            .guard_false,
            .guard_func,
            .guard_builtin,
            .fsqrt,
            .fsin,
            .fcos,
            .ffloor,
            .fceil,
            .aref,
            .aload,
            .href,
            .hload,
            .alen,
            .guard_table,
            .guard_lane,
            .guard_bounds,
            .guard_present,
            .guard_hash,
            .slen,
            .guard_string,
            .scp,
            => true,
            else => false,
        };
    }

    /// Doc 39 Phase 0/1 entry decision, called at the FIRST anchor-return of a
    /// recording (from `closeTrace`, before `commit` — never an error out of
    /// commit, which would gate `.commit_failure`). Returns true when
    /// `closeTrace` should return WITHOUT committing: either the peel was
    /// entered (marker emitted, recording continues into iteration 2), or a
    /// mid-entry OOM aborted the recording.
    ///
    /// Eligibility (doc 40 Phase 2 lifts the doc-39 `.root`-only gate): any
    /// recording kind closing as `.loop` at its own plain-while anchor — the
    /// reset-to-int glue records exclusively through the side / continuation
    /// channels (LLEAVE aborts a root on its anchor loop's own exit edge), so
    /// a `.root`-only peel fires on neither fft DOA shape. Side recordings
    /// that link elsewhere stay out (`link_target` below). The rest of the
    /// gate is unchanged: anchor frame closed (no inlining / multret shadow
    /// open), register-only iteration 1 (no pending stores, no allocations,
    /// whitelist-pure IR).
    ///
    /// The instability sweep (doc 40 Phase 3, bidirectional) covers the
    /// anchor window `[0, anchor_num_registers)` only, per-slot: a `.def`
    /// slot whose proven entry kind contradicts the numeric kind its carried
    /// value actually delivers at this anchor return. int-entry/float-carry
    /// is doc 39's RV-3-bailing forward shape; float-entry/int-carry is the
    /// F1-reverse reset-to-int shape (fft_bitreverse's `k = n`). The carried
    /// side reads the LIVE anchor-return register, not the ref's IR `ty` —
    /// an unguarded `slot_load` carries `.ty = .unknown` (exactly the `k = n`
    /// store), while recording is concrete execution, so the live value IS
    /// what the back-edge φ would deliver.
    fn maybeEnterPeel(self: *TraceState, regs: RegWindow) bool {
        if (!self.config.peel) return false;
        const rec = &self.rec;
        if (rec.link_target != null) return false;
        if (rec.inline_depth != 0) return false;
        if (rec.multret_top != null) return false;
        if (rec.pending_stores.items.len != 0) return false;
        if (rec.guard_gc_ref != null or rec.alloc_count != 0) return false;
        if (!isPlainWhileAnchor(rec.anchor.proto, rec.anchor.pc)) return false;
        // Instability sweep before the (linear) purity scan: the sweep is the
        // rarer pass condition, so most closes stop here. Bidirectional
        // (doc 40 Phase 3), per-slot — one recording may widen one slot and
        // narrow another; any single mismatch makes the close unstable.
        var unstable = false;
        for (rec.reg_map[0..rec.anchor_num_registers], 0..) |s, slot| {
            if (s.state != .def or s.entry_kind == .none) continue;
            const v = regs.get(@intCast(slot));
            unstable = switch (s.entry_kind) {
                .int => v.isFloat(),
                .float => v.isInt(),
                .none => unreachable,
            };
            if (unstable) break;
        }
        if (!unstable) return false;
        for (rec.instrs.items) |ins| {
            if (!peelAdmissibleOp(ins.op)) return false;
        }
        // Enter. Snapshot allocation first — a failure here declines cleanly
        // with the stream untouched (ordinary close proceeds).
        const slots = self.gpa.alloc(PeelSlot, rec.anchor_num_registers) catch return false;
        for (slots, rec.reg_map[0..rec.anchor_num_registers]) |*ps, s| {
            ps.* = .{ .ref = s.ref, .state = s.state };
        }
        _ = self.emit(.{ .op = .preheader }) catch {
            // The stream may hold a half-appended marker (instrs vs exit_prov
            // skew) — the recording cannot continue OR commit. Abort; `reset`
            // restores the invariant, exactly as any mid-recording emit OOM.
            self.gpa.free(slots);
            self.abort(.alloc);
            return true;
        };
        rec.peel = .{ .mark_len = rec.instrs.items.len, .slots = slots };
        self.dbg("peel: enter anchor pc={d} marker ir={d}", .{ rec.anchor.pc, rec.instrs.items.len - 1 });
        return true;
    }

    /// Doc 39 Phase 1 close, at the SECOND anchor-return of a peeled recording:
    /// verify the body pass stayed register-only (a forbidden effect means
    /// iteration 2 took a path iteration 1 didn't — abort, ordinary strikes)
    /// and type-stable, then patch every internal φ's back-edge `b` from the
    /// slot's body-final ref (or `a` — a constant carry — when the body only
    /// read it). Returns false when the recording must abort
    /// `.type_instability` instead of committing.
    fn finishPeel(self: *TraceState, p: *PeelState) bool {
        const rec = &self.rec;
        if (rec.link_target != null) return false; // a peeled root never link-closes
        if (rec.pending_stores.items.len != 0) return false;
        if (rec.guard_gc_ref != null or rec.alloc_count != 0) return false;
        for (rec.instrs.items[p.mark_len..]) |ins| {
            if (!peelAdmissibleOp(ins.op)) return false;
        }
        for (p.slots, 0..) |*ps, slot| {
            const pr = ps.phi_ref orelse continue;
            const phi_ins = &rec.instrs.items[@intCast(pr)];
            const cur = rec.reg_map[slot].ref;
            // Body redefined the slot → carry the body-final def; body only
            // read it → constant carry (`b = a`; the init is a run-once value
            // whose executor slot persists, so re-carrying it is exact).
            const b: Ref = if (cur != pr) cur else phi_ins.a;
            // Stability recheck against the φ's carried type (stamped from the
            // iteration-1 def at creation): a mismatch is a genuine
            // per-iteration flip-flop — uncompilable before the peel, stays so.
            if (rec.instrs.items[@intCast(b)].ty != phi_ins.ty) return false;
            phi_ins.b = b;
        }
        self.dbg("peel: close anchor pc={d} body ir={d}..{d}", .{
            rec.anchor.pc, p.mark_len, rec.instrs.items.len,
        });
        return true;
    }

    /// Doc 40 Phase 1 — commit preflight: would this `.loop` close be
    /// self-defeating? A trace whose entry fingerprint pins a carried slot to
    /// one numeric kind while its back-edge φ would store the other can never
    /// take its own back-edge: every entry runs exactly one iteration, exits
    /// on the entry guard, and the accounting machinery mistakes it for
    /// healthy forever (`completed > 0` clears the anchor penalty each entry;
    /// no want channel fires — the doc 40 "failure loop"). Such a close is
    /// refused BEFORE `commit` mutates anything (codex finding 4), keeping the
    /// anchor's accounting live and the producing channel retrying under the
    /// record gate.
    ///
    /// Scope (codex finding 6): proven int↔float contradictions only —
    /// `guard_number` matches both numeric kinds and non-numeric carried slots
    /// have legitimate specialized load/store relationships. The ENTRY side
    /// mirrors the fingerprint-extraction criteria exactly (a guard over a
    /// `slot_load` of an anchor-window slot — `matchesFingerprint` is what
    /// makes the contradiction fatal at re-entry); the STORE side reads the
    /// live anchor-return registers. Commit's φ-emission slot filter is
    /// mirrored too: a slot that gets no φ is never written at the back-edge,
    /// so its entry guard cannot be contradicted.
    fn loopCloseSelfDefeating(self: *const TraceState, regs: RegWindow) bool {
        // The live-value read below indexes the ANCHOR frame; at inline depth
        // the window belongs to a callee. Depth-0 covers every channel the
        // reset-to-int shape records through (glue side / continuation).
        if (self.rec.inline_depth != 0) return false;
        const instrs = self.rec.instrs.items;
        for (instrs, 0..) |ins, i| {
            const want_int = switch (ins.op) {
                .guard_int => true,
                .guard_float => false,
                else => continue,
            };
            const ref: usize = @intCast(ins.a);
            if (ref >= i or instrs[ref].op != .slot_load) continue;
            const slot: usize = @intCast(instrs[ref].aux);
            if (slot >= self.rec.anchor_num_registers) continue;
            const s = self.rec.reg_map[slot];
            if (s.state != .def) continue; // read-only slot: no φ, no back-edge write
            if (self.rec.alloc_count == 0 and
                slot >= self.rec.locals_watermark and !self.readSlot(@intCast(slot))) continue;
            // STORE side: the LIVE value at this anchor return. Recording is
            // concrete execution, so this is exactly what the φ delivers on
            // the recorded path. (The IR `ty` is useless here: an unguarded
            // `slot_load` store — the fft `k = n` reset — is `.unknown`.)
            const v = regs.get(@intCast(slot));
            if (want_int and v.isFloat()) return true;
            if (!want_int and v.isInt()) return true;
        }
        return false;
    }

    /// Finalise a cleanly-closed recording into a cached `Trace`. A build failure
    /// is treated like an abort (discard + gate-with-backoff) so we never thrash.
    ///
    /// Doc 39: this is also the peel's decision point, shared by BOTH
    /// anchor-arrival paths (`onBackEdge` + `maybeCloseAtAnchor`), which both
    /// funnel here. The `mark_len` equality check makes the marker-emitting
    /// return and its immediate re-arrival at the anchor ONE logical return
    /// regardless of which path fires first (a back-edge arrival calls
    /// `onBackEdge` then `maybeCloseAtAnchor` before anything records; a
    /// forward-flow arrival calls only `maybeCloseAtAnchor`).
    // pub for trace_recorder.zig (file-split pass)
    pub fn closeTrace(self: *TraceState, regs: RegWindow) void {
        if (self.rec.peel) |*p| {
            if (self.rec.instrs.items.len == p.mark_len) return; // same arrival
            if (!self.finishPeel(p)) {
                self.abort(.type_instability);
                return;
            }
        } else if (self.maybeEnterPeel(regs)) {
            return; // peel entered (keep recording iteration 2) or aborted
        }
        // Doc 40 Phase 1: refuse a self-defeating `.loop` close (entry
        // fingerprint contradicts a carried φ's numeric kind) for EVERY
        // recording kind — root, side, continuation — the glue channels are
        // precisely where the reset-to-int shape records (codex finding 1).
        // Peeled closes are legitimately entry≠steady by design; `.link`
        // closes carry no back-edge.
        if (self.rec.peel == null and self.rec.link_target == null and
            self.loopCloseSelfDefeating(regs))
        {
            self.dbg("commit refuse: anchor pc={d} self-defeating loop (entry kind vs phi store kind)", .{self.rec.anchor.pc});
            self.abort(.type_instability);
            return;
        }
        self.commit() catch |err| {
            self.dbg("commit failed: anchor pc={d} error={s} ir_len={d}", .{
                self.rec.anchor.pc,
                @errorName(err),
                self.rec.instrs.items.len,
            });
            self.gateRecordAnchor(self.rec.anchor, .commit_failure);
        };
        self.rec.active = false;
        // A successful `commit` consumed `side_src` (DONE latch); a failed one
        // must drop it too, so a stale key can never latch a later commit.
        self.rec.side_src = null;
    }

    /// B-2b commit publication: preserve the logical hotexit provenance only
    /// after the child is registered. A same-anchor relation OOM deliberately
    /// leaves the parent counter live (no DONE-without-edge); cross-anchor side
    /// traces retain the historical DONE latch but never create an arm relation.
    pub fn finishSideTraceProvenance(self: *TraceState, child: *Trace) void {
        const src = self.rec.side_src orelse return;
        defer self.rec.side_src = null;
        if (self.traceById(child.id) != child) return;
        const parent = self.traceById(src.trace_id) orelse return;
        var may_latch_done = true;
        if (parent.anchor.proto == child.anchor.proto and parent.anchor.pc == child.anchor.pc and
            src.exit_instr < parent.instrs.len)
        {
            self.provenance_edges.append(self.gpa, .{
                .parent_id = parent.id,
                .exit_instr = src.exit_instr,
                .child_id = child.id,
            }) catch {
                may_latch_done = false;
            };
            if (may_latch_done) {
                self.provenance_arms_pending = true;
                self.dbg("provenance-edge: t={d} ei={d} -> t={d}", .{ parent.id, src.exit_instr, child.id });
            }
        }
        if (may_latch_done and src.exit_instr < parent.exit_counts.len)
            parent.exit_counts[src.exit_instr] = Trace.EXIT_COUNT_DONE;
    }

    /// Copy the in-progress recording into an owned, cached `Trace`. The exit
    /// snapshot is every register the trace *defined* (its loop-carried writes).
    /// When `config.optimize`, the trace optimizer (`tropt.zig`) rewrites the IR
    /// first; an optimizer OOM falls back to caching the *unoptimized* trace
    /// (correct, just slower) rather than failing the commit.
    fn commit(self: *TraceState) !void {
        // Doc 24 D3: stamp the allocation bound `A` into the entry `guard_gc`'s
        // `aux` (emitted with a placeholder by `emitAlloc`). Stamped on the
        // RECORDED stream, before `tropt.optimize` — the optimizer may CSE an
        // `.alloc` op away (tostr repeats), which only makes the stamped bound a
        // conservative upper bound: a stricter guard is always sound.
        if (self.rec.guard_gc_ref) |gr| {
            std.debug.assert(self.rec.alloc_count > 0);
            self.rec.instrs.items[@intCast(gr)].aux = @intCast(self.rec.alloc_count);
        }
        // The loop-carried writebacks, as slot-bound φ nodes (one per register the
        // trace defined, minus *dead temporaries*), spliced in just before the
        // terminal `loop`. A slot at/above `locals_watermark` is a compiler
        // expression temporary (set only by the anchoring numeric-`for`'s
        // `for_loop`; see `recForLoop`/`Recorder.locals_watermark`): dead at the
        // loop-header resume point on every path and after the loop, so tier-0
        // recomputes it on deopt and post-loop code never reads it — writing it
        // back is pure waste. The `entry_slots` (`readSlot`) guard is a safety net:
        // a slot the trace actually read is never dropped (it is `< watermark`
        // anyway). When the watermark is the `maxInt` sentinel (while / generic-
        // `for` / passed-through `for`), nothing is filtered.
        //
        // A slot-bound φ's init is implicit (`regs[slot]`, read each entry like the
        // matching `slot_load`), so `a` is 0; `b` is the body def (the update).
        // Flush the deferred read-modify-write stores (store-sinking) at the end of
        // the body, below every guard (the body guards + `recForLoop`'s continuation
        // `guard_true`, all already in the stream) and before the φ writebacks +
        // `.loop`. Sinking them below all side-exiting ops makes deopt-replay
        // idempotent: any guard failure leaves *all* of them un-executed, so tier-0
        // re-runs the whole iteration along the original source path and applies
        // exactly that path's stores once each. Flushed FRONT-TO-BACK in the recorded
        // (tier-0 bytecode) order — so two stores that alias the same slot land in the
        // VM's order and last-writer-wins matches tier-0 (`08-multi-store-sinking.md`).
        // This is exactly where inline (non-deferred) `astore`s sit — the body — so
        // the φ block stays contiguous before `.loop`. Gap B (doc 07) was the single
        // store; Gap C (doc 08) generalizes to an ordered set.
        for (self.rec.pending_stores.items) |ps| {
            // `ps.op` is `.astore` for a packed-array RMW or `.hstore` for a
            // hash-field RMW (doc 11); both flush below every guard, in recorded
            // order, just before `.loop`. `lane_ord` is the array `Lane` ordinal
            // for `.astore` and unused (0) for `.hstore`.
            try self.rec.instrs.append(self.gpa, .{
                .op = ps.op,
                .a = ps.aref,
                .b = ps.value,
                .aux = ps.lane_ord,
            });
        }
        for (self.rec.reg_map, 0..) |s, slot| {
            if (s.state != .def) continue;
            // S2 (cross-frame tracing): callee slots are pure internal SSA
            // temporaries — defined-before-use inside the inlined body, dead at the
            // loop boundary, never loop-carried. Only anchor-frame slots may carry
            // across iterations (including the return-mapped `ret_dest..` writes,
            // which land back in the anchor window). Writing a callee slot back here
            // would make the `.loop` flush `regs.set` past the executor's real
            // `[0, anchor_num_registers)` window — a silent OOB slab write.
            if (slot >= self.rec.anchor_num_registers) continue;
            // Doc 24 D3 full-write-set flush rule (codex #6): an ALLOCATING
            // trace flushes EVERY anchor-frame slot the body writes — including
            // dead expression temporaries the watermark filter would drop. The
            // collector roots every physical register below `stack_top`, not the
            // live set; a dead temp holding a per-iteration heap ref (a `tostr_*`
            // result) left at its *pre-burst* value would diverge the sweep's
            // root set from tier-0-only's (which holds the LAST iteration's
            // value there) → divergent de-intern sets → divergent ids. Flushing
            // the full written span makes post-burst regs equal tier-0's after
            // the same iterations exactly. Non-allocating traces keep the
            // watermark filter (arc-A shapes byte-identical: their traceable
            // loops cannot produce per-iteration heap temps).
            if (self.rec.alloc_count == 0 and
                slot >= self.rec.locals_watermark and !self.readSlot(@intCast(slot))) continue;
            // Doc 39: a peeled trace stamps each slot-bound φ's otherwise-
            // unused `a` with the slot's steady-state INTERNAL φ ref — the
            // durable slot↔φ association native analyze needs to connect the
            // entry load (run-once, entry-kinded) with the carried home
            // (internal-φ-kinded) without dataflow guessing (codex round-2
            // finding 4). `a = 0` = no internal φ: a write-before-read or
            // never-touched-in-body slot, the existing write-only class.
            const steady_phi: Ref = if (self.rec.peel) |p| blk: {
                if (slot < p.slots.len) {
                    if (p.slots[slot].phi_ref) |pr| break :blk pr;
                }
                break :blk 0;
            } else 0;
            try self.rec.instrs.append(self.gpa, .{
                .op = .phi,
                .a = steady_phi,
                .b = s.ref,
                .aux = @intCast(slot),
                .ty = self.rec.instrs.items[s.ref].ty,
            });
        }
        // Terminal: a continuation that re-reached an inner root closes with a
        // `.link` hand-off (doc 15, Phase 2) carrying the inner anchor pc in `aux`;
        // every other trace closes with the back-edge `.loop`. The φ block above is
        // the register hand-off snapshot in either case.
        if (self.rec.link_target) |lt| {
            try self.rec.instrs.append(self.gpa, .{ .op = .link, .aux = @intCast(lt) });
        } else {
            try self.rec.instrs.append(self.gpa, .{ .op = .loop });
        }

        const instrs = self.rec.instrs.items;
        const consts = self.rec.consts.items;
        const entry = self.rec.entry_slots.items;

        // Link traces are cached **unoptimized**: `tropt.optimize` asserts a `.loop`
        // terminal and its LICM/φ machinery is written for back-edge loops. Phase 3
        // executes link traces through `driveChain`, but the unoptimized straight-line
        // continuation is the intended hand-off shape. `dupe` preserves `.link`.
        // Doc 39 Phase 1b: peeled traces bypass `tropt` (the link-trace
        // precedent) — the optimizer's liveness roots have no concept of a
        // recorder-emitted `preheader` marker (it synthesizes its own during
        // compaction from a global invariance analysis) and would drop the
        // peel's run-once/steady split; CSE and guard dedup likewise span the
        // whole stream marker-blind. A marker-aware tropt is future work.
        const fields: tropt.Optimized = if (self.config.optimize and self.rec.link_target == null and self.rec.peel == null)
            tropt.optimize(self.gpa, instrs, consts) catch |e| switch (e) {
                // Never fail a commit (or thrash the anchor) over an optimizer
                // allocation failure: cache the unoptimized trace instead.
                error.OutOfMemory => try tropt.dupe(self.gpa, instrs, consts, entry),
            }
        else
            try tropt.dupe(self.gpa, instrs, consts, entry);
        errdefer {
            self.gpa.free(fields.instrs);
            self.gpa.free(fields.consts);
            self.gpa.free(fields.entry_slots);
        }
        // The `tropt` compaction map is transient — used only to remap the exit
        // provenance below, never stored in the `Trace`. Free it on every exit path.
        defer fields.freeMap(self.gpa);

        // Remap the recorder's emission-indexed exit provenance (A-i.1) into the
        // committed, compact `Trace.exit_prov`, keyed by committed instr index. The
        // `dupe` path (link + unoptimized traces) hands back a null map ⇒ identity.
        //
        // A-i.4: the `.link` terminal (edge 2) carries its own provenance on
        // `pending_link_provenance`. It is the trace's last instr — appended directly
        // above, never through `emit`, so it has no lockstep slot — and a link trace
        // always takes the `dupe` (identity) path, so its committed index is
        // `fields.instrs.len − 1`. Release invariant (both set together only in
        // `recForPrepLink`): a `.link` terminal ⇔ a pending link provenance.
        if ((self.rec.link_target != null) != (self.rec.pending_link_provenance != null))
            @panic("commit: link_target / pending_link_provenance invariant violated");
        const link_term: ?ExitProvEntry = if (self.rec.pending_link_provenance) |lp|
            .{ .index = @intCast(fields.instrs.len - 1), .prov = lp }
        else
            null;
        // **FAIL-SOFT (round-14 review, A-i exit_prov parity with `rec_path`):** an OOM in
        // `buildExitProv` must NOT abort the commit — `closeTrace` gates the anchor on a
        // commit error, perturbing tiering, and `exit_prov` is region metadata (read
        // only by `provAt` + the A-ii region classifier, nothing on the selection path). On
        // OOM commit an EMPTY exit table and mark `exit_prov_complete = false` so region
        // discovery treats the edge graph as incomplete and arms/mints nothing that pass.
        // `buildExitProv`'s single alloc is `errdefer`-guarded, so a failure leaks nothing.
        var exit_prov_complete = true;
        var exit_prov_owned: []ExitProvEntry = &.{};
        if (buildExitProv(self.gpa, self.rec.exit_prov.items, fields.old_to_new, link_term)) |ok| {
            exit_prov_owned = ok;
        } else |_| {
            exit_prov_complete = false;
        }
        errdefer if (exit_prov_owned.len != 0) self.gpa.free(exit_prov_owned);

        // A-ii.3/A-ii.4: dup the recorder's ordered program-point path into the
        // committed trace. **FAIL-SOFT (round-14 review finding 1):** an OOM here must
        // NOT abort the commit — `closeTrace` gates the anchor on a commit error, which
        // would perturb tiering, and `rec_path` is region metadata. On ANY
        // unavailability (recorder-path OOM flipped `rec_path_ok`, OR this dup OOMs)
        // commit an empty path and mark membership INCOMPLETE (finding 3), so region
        // discovery fails any region containing this trace CLOSED (`armable = false`)
        // rather than minting on truncated membership. Owned; freed in `destroy`.
        var rec_path_complete = self.rec.rec_path_ok;
        const rec_path_owned: []ProgramPoint = if (self.rec.rec_path_ok and self.rec.rec_path.items.len != 0)
            (self.gpa.dupe(ProgramPoint, self.rec.rec_path.items) catch blk: {
                rec_path_complete = false;
                break :blk &.{};
            })
        else
            &.{};
        errdefer if (rec_path_owned.len != 0) self.gpa.free(rec_path_owned);

        // S3 (cross-frame tracing): pin the verifier's register-window bound to the
        // executor's *real* window (`anchor_num_registers`), not the grown
        // `reg_map.len` (which includes the callee scratch tail). A `slot_load`/`phi`
        // `aux` outside `[0, anchor_num_registers)` is exactly the OOB that S1/S2
        // prevent — so the verifier must reject it, not have its bound widened to
        // hide it.
        assertWellFormed(fields.instrs, fields.consts.len, self.rec.anchor_num_registers, @as(usize, self.rec.anchor_num_registers) + self.rec.input_seeds.items.len);

        // Compute the entry type fingerprint: for each guard_int/guard_float/
        // guard_number/guard_table that guards a slot_load, record the
        // (slot, type) pair.  This lets the dispatch loop skip non-matching
        // traces without a trial entry.
        var entry_guards: std.ArrayListUnmanaged(EntryGuard) = .empty;
        // Covers OOM during the append loop (and a failing `toOwnedSlice`, which
        // leaves the list intact). After `toOwnedSlice` succeeds the list owns
        // nothing, so the freed slice gets its own errdefer below.
        errdefer entry_guards.deinit(self.gpa);
        for (fields.instrs, 0..) |ins, i| {
            const egt: ?EntryGuardType = switch (ins.op) {
                .guard_int => .int,
                .guard_float => .float,
                .guard_number => .number,
                .guard_table => .table,
                else => null,
            };
            if (egt) |ty| {
                const ref: u32 = @intCast(ins.a);
                if (ref < i and fields.instrs[ref].op == .slot_load) {
                    const slot: u16 = @intCast(fields.instrs[ref].aux);
                    // Fingerprint only anchor-frame slots: a synthetic input slot
                    // (`>= anchor_num_registers`, cluster sub-lever 1) is not present
                    // in the narrow `RegWindow` `matchesFingerprint` reads, so adding
                    // it would be an out-of-window read. Its type is still pinned by
                    // the guard in the IR — a mismatch side-exits on a trial entry
                    // instead of being pre-filtered.
                    if (slot < self.rec.anchor_num_registers)
                        try entry_guards.append(self.gpa, .{ .slot = slot, .ty = ty });
                }
            }
        }
        const guards_owned = try entry_guards.toOwnedSlice(self.gpa);
        // Covers OOM in `create(Trace)` and the trailing `cache.append` (the
        // `fields` errdefer above frees the IR arrays; this frees the fingerprint).
        errdefer self.gpa.free(guards_owned);

        // Own the synthetic-input seeding recipe (cluster sub-lever 1). Empty for
        // the common trace (no upvalue/global-reached callee) — a static empty slice
        // needs no free (`destroy` guards on `len != 0`).
        const inputs_owned: []InputSeed = if (self.rec.input_seeds.items.len == 0)
            &.{}
        else
            try self.gpa.dupe(InputSeed, self.rec.input_seeds.items);
        errdefer if (inputs_owned.len != 0) self.gpa.free(inputs_owned);

        const t = try self.gpa.create(Trace);
        errdefer self.gpa.destroy(t);
        // Doc 26 D1: does the committed IR carry a case-mapping op? (`.alloc`
        // ops are never DCE'd, so post-optimizer presence ≡ recorded.) The
        // commit itself is the first checkpoint of the pin invariant: the
        // recorder only reaches these ops by mirroring a successful tier-0
        // upper/lower, which pinned the session's Unicode version.
        var requires_unicode_pin = false;
        for (fields.instrs) |ins| {
            if (ins.op == .supper or ins.op == .slower) requires_unicode_pin = true;
        }
        // Stable id (P-B): assigned once, never reused. A bump before a failed
        // `cache.append` leaves a harmless gap in the id space (ids need only be
        // unique, not contiguous).
        const new_id = self.next_trace_id;
        self.next_trace_id += 1;
        t.* = .{
            .id = new_id,
            .anchor = self.rec.anchor,
            .instrs = fields.instrs,
            .consts = fields.consts,
            .entry_slots = fields.entry_slots,
            .entry_guards = guards_owned,
            .inputs = inputs_owned,
            .exit_prov = exit_prov_owned,
            .exit_prov_complete = exit_prov_complete,
            .rec_path = rec_path_owned,
            .rec_path_complete = rec_path_complete,
            .alloc_bound = self.rec.alloc_count,
            .requires_unicode_pin = requires_unicode_pin,
            .unrolled_while = self.rec.unrolled_while,
            .peeled = self.rec.peel != null,
        };
        // §T.9: memoize the pure `isCompositeBridgeCandidate` oracle over this trace's
        // instruction indices. Must run AFTER `t.*` is populated — the oracle reads the
        // finished trace (`instrs`, `anchor`, `provAt`). FAIL-SOFT: on OOM leave the memo
        // unbuilt, and `isBridgeCandidate` transparently falls back to the oracle, so a
        // failure costs speed and never correctness.
        buildBridgeCandMemo(self.gpa, t);
        errdefer if (t.bridge_cand.len != 0) self.gpa.free(t.bridge_cand);
        // Hotexit substrate (Pall's `snap->count`): one taken-exit counter per
        // committed instruction. FAIL-SOFT on OOM (empty ⇒ `noteTakenExit`
        // no-ops for this trace — hotness lost, correctness untouched).
        if (self.gpa.alloc(u8, fields.instrs.len)) |counts| {
            @memset(counts, 0);
            t.exit_counts = counts;
        } else |_| {}
        errdefer if (t.exit_counts.len != 0) self.gpa.free(t.exit_counts);
        try self.cache.append(self.gpa, t);
        bumpGen(&self.cache_gen); // invalidate Trace.anchor_pop_* memos
        // Register in the O(1) id index (fail-soft: on grow-OOM the id stays
        // unindexed and `traceById` falls back to the cache scan).
        if (t.id >= self.trace_by_id.items.len) {
            const old_len = self.trace_by_id.items.len;
            if (self.trace_by_id.resize(self.gpa, t.id + 1)) {
                @memset(self.trace_by_id.items[old_len..], null);
                self.trace_by_id.items[t.id] = t;
            } else |_| {}
        } else {
            self.trace_by_id.items[t.id] = t;
        }
        // Pall's `snap->count = SNAPCOUNT_DONE` at side-trace link (lj_trace.c:535):
        // this commit was triggered by a hot exit (`side_src` provenance followed
        // the want through consume → pending → recorder), so latch the parent's
        // exit — it now has its side trace and must never count again. The parent
        // may have been evicted mid-recording (`traceById` miss) — then there is
        // nothing to latch.
        self.finishSideTraceProvenance(t);
        // Coverage (gated): a trace now exists at this anchor, so subsequent
        // interpreted back-edges here are "fallback despite a trace."
        if (self.config.coverage) self.markAnchorTraced(t.anchor);
        // A-ii.2: refresh the structural-edge cache — the new trace may add edges
        // FROM itself AND make pre-existing traces' exits newly resolvable. Fail-soft
        // (never fails the commit); any OOM fails CLOSED to an empty cache (round-14
        // finding 6 — this new trace can add a boundary edge that invalidates a prior
        // region's owner, so retaining the prior snapshot could keep a stale arm).
        self.rebuildEdgeCache();
        // A-ii.4: rediscover regions over the refreshed graph. Fail-soft;
        // any OOM fails CLOSED to empty physical indices (arm nothing).
        self.rebuildRegions();
    }

    /// Debug-only structural verifier for the invariants the tier-1a executor
    /// (`irinterp.zig`) relies on, so a recorder bug can never become a wild read
    /// at execution time. Compiled out in release builds (`std.debug.assert`).
    ///   * the trace is non-empty and terminates in exactly one `loop`;
    ///   * every operand `Ref` is defined earlier (linear SSA: ref < its index);
    ///   * `slot_load`/`konst` `aux` is in register / const-pool bounds;
    ///   * every `phi` update `b` precedes the `loop` and its `aux` slot is a
    ///     register (or the internal sentinel).
    /// `num_registers` is the executor's real loop-carried window
    /// (`anchor_num_registers`) — the bound a `phi` flush may write back to (S2/S3).
    /// `input_limit` is that window *plus* the synthetic entry inputs (cluster
    /// sub-lever 1): a `slot_load` may read an input slot in
    /// `[num_registers, input_limit)`, but no `phi` ever names one (inputs are
    /// read-only, never `.def`), so the phi bound stays tight.
    fn assertWellFormed(instrs: []const IrInstr, consts_len: usize, num_registers: usize, input_limit: usize) void {
        std.debug.assert(instrs.len >= 1);
        const last = instrs.len - 1;
        // The trace terminates in exactly one terminal: `.loop` (root/continuation
        // back-edge) or `.link` (continuation hand-off to an inner root, doc 15).
        std.debug.assert(instrs[last].op == .loop or instrs[last].op == .link);
        for (instrs, 0..) |ins, i| {
            switch (ins.op) {
                .slot_load => std.debug.assert(ins.aux >= 0 and @as(usize, @intCast(ins.aux)) < input_limit),
                .konst => std.debug.assert(ins.aux >= 0 and @as(usize, @intCast(ins.aux)) < consts_len),
                .loop => std.debug.assert(i == last), // the only loop, and it is terminal
                // `.link` (doc 15): terminal hand-off to an inner root. Like `.loop`
                // it is the sole terminal; `aux` is the inner anchor pc, not an
                // operand ref, so nothing to bound-check beyond terminality.
                .link => std.debug.assert(i == last),
                // binary ops read both `a` and `b`.
                .add, .sub, .mul, .div, .idiv, .mod, .pow, .band, .bor, .bxor, .shl, .shr, .sar, .eq, .ne, .lt, .le => {
                    std.debug.assert(ins.a < i and ins.b < i);
                },
                // unary ops and guards read `a` only.
                .neg, .not, .bnot, .guard_int, .guard_float, .guard_number, .guard_true, .guard_false, .guard_func => {
                    std.debug.assert(ins.a < i);
                },
                // `int_of_float` reads its sole float operand `a` (a prior node).
                .int_of_float => std.debug.assert(ins.a < i),
                // `alen` reads its sole table operand `a` (a prior node).
                .alen => std.debug.assert(ins.a < i),
                // `fsin`/`fcos`/`ffloor`/`fceil` read their sole numeric operand `a` (a prior node).
                .fsin, .fcos, .ffloor, .fceil => std.debug.assert(ins.a < i),
                // Doc 24 D4: `tostr_*` read their guarded numeric operand,
                // `slen`/`guard_string` their string operand — all prior nodes.
                // Doc 26: `supper`/`slower` read their string operand like `srev`.
                .tostr_int, .tostr_num, .slen, .guard_string, .srev, .schar1, .supper, .slower => std.debug.assert(ins.a < i),
                .srep2 => {
                    std.debug.assert(ins.a < i);
                    std.debug.assert(ins.b < i);
                },
                // ssub's third operand rides `aux` as a Ref (doc 24 codex #4);
                // `scp` shares the three-operand encoding (doc 26 D3), as do
                // doc 30's `sfindp`/`smatch` (subject, init, pattern-in-aux).
                .ssub, .scp, .sfindp, .smatch => {
                    std.debug.assert(ins.a < i);
                    std.debug.assert(ins.b < i);
                    std.debug.assert(ins.aux >= 0 and ins.aux < i);
                },
                // Doc 30 `sgmatch`: `a` = state ref; `aux` = konst-pool id
                // (an immediate, bounds-checked against the pool).
                .sgmatch => {
                    std.debug.assert(ins.a < i);
                    std.debug.assert(ins.aux >= 0 and @as(usize, @intCast(ins.aux)) < consts_len);
                },
                // Doc 30 projections: `a` = the match op ref; `b` = slot
                // immediate within the scratch geometry (never a ref).
                .scap_int, .scap_str => {
                    std.debug.assert(ins.a < i);
                    std.debug.assert(@as(usize, ins.b) < gc.MatchScratch.n_slots);
                },
                // Doc 30 str2num: unary on a proven-string ref.
                .str2num_i, .str2num_f => std.debug.assert(ins.a < i),
                // Doc 30 sgm_setpos: state ref + new-pos ref, both prior.
                .sgm_setpos => {
                    std.debug.assert(ins.a < i);
                    std.debug.assert(ins.b < i);
                },
                // Doc 30 guard_sid: string ref + konst-pool id immediate.
                .guard_sid => {
                    std.debug.assert(ins.a < i);
                    std.debug.assert(ins.aux >= 0 and @as(usize, @intCast(ins.aux)) < consts_len);
                },
                // `guard_gc` (doc 24 D3): operand-free; `aux` is the allocation
                // bound `A` — a positive count stamped by `commit()`.
                .guard_gc => std.debug.assert(ins.aux > 0),
                // `guard_builtin` reads the callee ref `a`; `fsqrt` reads its float
                // operand `a` — both prior nodes.
                .guard_builtin, .fsqrt => std.debug.assert(ins.a < i),
                // `aref` pairs (table, index) into an address descriptor;
                // `astore`/`astore_append` read the `aref` (`a`) and the value (`b`).
                // `href` (table, key konst) and `hstore` (href, value) mirror them.
                .aref, .astore, .astore_append, .href, .hstore => std.debug.assert(ins.a < i and ins.b < i),
                // Grid cell access (doc 14, Phase 8): `garow` pairs (table,row),
                // `gcell` pairs (garow,col), `gstore` reads (gcell, value) — all two
                // prior operands. `gload` and the grid guards read one prior node.
                .garow, .gcell, .gstore, .guard_gcol => std.debug.assert(ins.a < i and ins.b < i),
                .gload, .guard_grid, .guard_stride, .guard_gpresent => std.debug.assert(ins.a < i),
                // `aload` and the array-access guards read one prior node
                // (the table value, or the `aref`). `guard_append` reads the `aref`.
                // `hload`/`guard_hash` read the `href` (`a`).
                .aload, .guard_table, .guard_lane, .guard_present, .guard_fits, .guard_append, .hload, .guard_hash => {
                    std.debug.assert(ins.a < i);
                },
                // `guard_bounds` carries producer-dispatched semantics (doc 18 D3):
                // tier-1a selects the bounds rule from the producer op, so the
                // producer must be one of exactly two memory ops — `aref` (scalar
                // array key) or `garow` (grid row). Both are canonical-to-self in
                // `tropt` (never folded/CSE'd) and `a` is remapped through
                // compaction, so this holds post-optimization too; pin it so
                // malformed IR fails closed here rather than mis-dispatching.
                .guard_bounds => {
                    std.debug.assert(ins.a < i);
                    const producer = instrs[ins.a].op;
                    std.debug.assert(producer == .aref or producer == .garow);
                },
                // φ: the init `a` is an ordinary backward ref (a < i); the update
                // `b` is the back-edge value and may reference a *later* node, like
                // an `exit_store.ref` — only required to precede the `loop` marker.
                // `aux` is the flush slot (a valid register) or the internal sentinel.
                .phi => {
                    std.debug.assert(ins.a < i);
                    std.debug.assert(ins.b < last);
                    std.debug.assert(ins.aux == PHI_INTERNAL or
                        (ins.aux >= 0 and @as(usize, @intCast(ins.aux)) < num_registers));
                    // Doc 39: a slot-bound φ's `a` is either 0 (unused — no
                    // steady-state internal φ; the historical value) or the
                    // slot's INTERNAL φ (the durable slot↔φ association a
                    // peeled trace commits). Unambiguous: instruction 0 can
                    // never be a φ (its `a < i` requires i > 0).
                    if (ins.aux != PHI_INTERNAL and ins.a != 0) {
                        const assoc = instrs[@intCast(ins.a)];
                        std.debug.assert(assoc.op == .phi and assoc.aux == PHI_INTERNAL);
                    }
                },
                // Preheader region boundary (Phase E1): a pure marker, no operands.
                // Structural invariants (at most one; before any φ) are asserted in
                // the global pass below.
                .preheader => {},
            }
        }
        // Preheader structural rules (Phase E1 / LICM): at most one marker, and no
        // `phi` may precede it (loop-carried values must run every iteration, but a
        // φ before the marker would be skipped on iterations 2+).
        var preheader_idx: ?usize = null;
        for (instrs, 0..) |ins, i| {
            if (ins.op == .preheader) {
                std.debug.assert(preheader_idx == null); // at most one
                preheader_idx = i;
            }
        }
        if (preheader_idx) |ph| {
            for (instrs[0..ph]) |ins| std.debug.assert(ins.op != .phi);
        }
    }

    // Per-instruction recording — moved to trace_recorder.zig (file-split
    // pass); forwarding decls keep every `self.recX(...)` spelling working.
    pub const recordInstr = trace_recorder_mod.recordInstr;
    pub const recordOne = trace_recorder_mod.recordOne;
    pub const emit = trace_recorder_mod.emit;
    pub const emitAlloc = trace_recorder_mod.emitAlloc;
    pub const konst = trace_recorder_mod.konst;
    pub const refOf = trace_recorder_mod.refOf;
    pub const noteEntryKind = trace_recorder_mod.noteEntryKind;
    pub const noteEntryKindFromLane = trace_recorder_mod.noteEntryKindFromLane;
    pub const setReg = trace_recorder_mod.setReg;
    pub const defineSlotAbs = trace_recorder_mod.defineSlotAbs;
    pub const readSlot = trace_recorder_mod.readSlot;
    pub const stampProv = trace_recorder_mod.stampProv;
    pub const guard = trace_recorder_mod.guard;
    pub const guardInt = trace_recorder_mod.guardInt;
    pub const guardNum = trace_recorder_mod.guardNum;
    pub const keyIndexOf = trace_recorder_mod.keyIndexOf;
    pub const keyRefNarrowed = trace_recorder_mod.keyRefNarrowed;
    pub const recArith = trace_recorder_mod.recArith;
    pub const recBitwise = trace_recorder_mod.recBitwise;
    pub const recNeg = trace_recorder_mod.recNeg;
    pub const recNot = trace_recorder_mod.recNot;
    pub const recBnot = trace_recorder_mod.recBnot;
    pub const recCompare = trace_recorder_mod.recCompare;
    pub const GetFrame = trace_recorder_mod.GetFrame;
    pub const SetFrame = trace_recorder_mod.SetFrame;
    pub const recArrayGet = trace_recorder_mod.recArrayGet;
    pub const arrayGetShape = trace_recorder_mod.arrayGetShape;
    pub const forwardPendingArrayLoad = trace_recorder_mod.forwardPendingArrayLoad;
    pub const forwardPendingHashLoad = trace_recorder_mod.forwardPendingHashLoad;
    pub const classifyArrayKeyAlias = trace_recorder_mod.classifyArrayKeyAlias;
    pub const intKonstRef = trace_recorder_mod.intKonstRef;
    pub const affineIntKey = trace_recorder_mod.affineIntKey;
    pub const recArraySet = trace_recorder_mod.recArraySet;
    pub const arraySetShape = trace_recorder_mod.arraySetShape;
    pub const recGridGet = trace_recorder_mod.recGridGet;
    pub const recGridSet = trace_recorder_mod.recGridSet;
    pub const traceHasHeapLoad = trace_recorder_mod.traceHasHeapLoad;
    pub const isStringKey = trace_recorder_mod.isStringKey;
    pub const seedHashCell = trace_recorder_mod.seedHashCell;
    pub const recHashGet = trace_recorder_mod.recHashGet;
    pub const hashGetShape = trace_recorder_mod.hashGetShape;
    pub const recHashSet = trace_recorder_mod.recHashSet;
    pub const hashSetShape = trace_recorder_mod.hashSetShape;
    pub const recEq = trace_recorder_mod.recEq;
    pub const recBranch = trace_recorder_mod.recBranch;
    pub const recTForLoop = trace_recorder_mod.recTForLoop;
    pub const recForLoop = trace_recorder_mod.recForLoop;
    pub const recForPrepLink = trace_recorder_mod.recForPrepLink;
    pub const recWhileLink = trace_recorder_mod.recWhileLink;
    pub const recCall = trace_recorder_mod.recCall;
    pub const recBuiltin = trace_recorder_mod.recBuiltin;
    pub const recBMType = trace_recorder_mod.recBMType;
    pub const konstValueOf = trace_recorder_mod.konstValueOf;
    pub const foldInternedStr = trace_recorder_mod.foldInternedStr;
    pub const recBType = trace_recorder_mod.recBType;
    pub const recBTostring = trace_recorder_mod.recBTostring;
    pub const isProvenStringRef = trace_recorder_mod.isProvenStringRef;
    pub const stringArgRef = trace_recorder_mod.stringArgRef;
    pub const intArgRef = trace_recorder_mod.intArgRef;
    pub const recBSLen = trace_recorder_mod.recBSLen;
    pub const recBSSub = trace_recorder_mod.recBSSub;
    pub const recBSRev = trace_recorder_mod.recBSRev;
    pub const recBSChar1 = trace_recorder_mod.recBSChar1;
    pub const recBSRep2 = trace_recorder_mod.recBSRep2;
    pub const recBSCase = trace_recorder_mod.recBSCase;
    pub const recBSCodepoint = trace_recorder_mod.recBSCodepoint;
    pub const PatternPin = trace_recorder_mod.PatternPin;
    pub const patternArgPin = trace_recorder_mod.patternArgPin;
    pub const projectCaptures = trace_recorder_mod.projectCaptures;
    pub const recBSFind = trace_recorder_mod.recBSFind;
    pub const recBSMatch = trace_recorder_mod.recBSMatch;
    pub const recBSGmatchIter = trace_recorder_mod.recBSGmatchIter;
    pub const recBTonumber = trace_recorder_mod.recBTonumber;
    pub const recBSelect = trace_recorder_mod.recBSelect;
    pub const recBRawequal = trace_recorder_mod.recBRawequal;
    pub const recBRawlen = trace_recorder_mod.recBRawlen;
    pub const recBRawget = trace_recorder_mod.recBRawget;
    pub const recBRawset = trace_recorder_mod.recBRawset;
    pub const recAlenShape = trace_recorder_mod.recAlenShape;
    pub const guardBuiltinCallee = trace_recorder_mod.guardBuiltinCallee;
    pub const recPureSqrt = trace_recorder_mod.recPureSqrt;
    pub const recFloatUnary = trace_recorder_mod.recFloatUnary;
    pub const recFloorCeil = trace_recorder_mod.recFloorCeil;
    pub const recReturn = trace_recorder_mod.recReturn;
    pub const recInputGet = trace_recorder_mod.recInputGet;
    pub const recCalleeUpval = trace_recorder_mod.recCalleeUpval;
};

// Recorder support decls + the Recorder struct itself — moved to
// trace_recorder.zig (file-split pass); aliases keep `trace.Recorder`,
// the `rec: Recorder` field, and every internal spelling working.
pub const isPlainWhileAnchor = trace_recorder_mod.isPlainWhileAnchor;
pub const arithResultType = trace_recorder_mod.arithResultType;
pub const obsTypeOf = trace_recorder_mod.obsTypeOf;
pub const SlotState = trace_recorder_mod.SlotState;
pub const EntryKind = trace_recorder_mod.EntryKind;
pub const RegSlot = trace_recorder_mod.RegSlot;
pub const PeelSlot = trace_recorder_mod.PeelSlot;
pub const PeelState = trace_recorder_mod.PeelState;
pub const KonstKey = trace_recorder_mod.KonstKey;
pub const konstKey = trace_recorder_mod.konstKey;
pub const PendingStore = trace_recorder_mod.PendingStore;
pub const AliasClass = trace_recorder_mod.AliasClass;
pub const AffineIntKey = trace_recorder_mod.AffineIntKey;
pub const MAX_CALLEE_REGS = trace_recorder_mod.MAX_CALLEE_REGS;
pub const MAX_TRACE_INPUTS = trace_recorder_mod.MAX_TRACE_INPUTS;
pub const InlineFrame = trace_recorder_mod.InlineFrame;
pub const pathFromFrames = trace_recorder_mod.pathFromFrames;
pub const TraceKind = trace_recorder_mod.TraceKind;
pub const Recorder = trace_recorder_mod.Recorder;

// ---------------------------------------------------------------------------
// Disassembly — same spirit as `bytecode.writeProto`. Invaluable for `--dump-
// traces` and for asserting trace shape in tests.
// ---------------------------------------------------------------------------

pub const writeIrInstr = trace_ir.writeIrInstr;

/// Disassemble a whole trace: header + entry slots + numbered IR (the slot-bound
/// `phi` rows are the loop-carried writebacks that `exit_stores` used to list).
pub fn writeTrace(w: *io.Writer, t: *const Trace) io.Writer.Error!void {
    try w.print("trace {s}:{d}  entry=[", .{ t.anchor.proto.name, t.anchor.pc });
    for (t.entry_slots, 0..) |s, i| {
        if (i != 0) try w.writeAll(" ");
        try w.print("r{d}", .{s});
    }
    // Synthetic entry inputs (upvalue/global/hash-cell snapshots) against the
    // MAX_TRACE_INPUTS policy cap — so a dump answers "how close is this trace
    // to the input budget?" at a glance instead of leaving it to be guessed
    // from abort rows (which once misdiagnosed str_manip as cap-blocked when
    // its main trace used 7 of 8, back when the then-`.too_deep` tag — now
    // split into `.input_cap`/`.frame_bounds`/`.too_deep` — hid which limit
    // fired; CURRENT_TASK LATEST-94).
    try w.print("]  inputs={d}/{d}\n", .{ t.inputs.len, MAX_TRACE_INPUTS });
    for (t.instrs, 0..) |ins, i| {
        try w.print("  %{d:0>3}  ", .{i});
        try writeIrInstr(w, ins);
        try w.writeAll("\n");
    }
}

/// Render the abort log (`--dump-aborts`) as one aligned row per distinct
/// `(anchor, reason, opcode)`, sorted by `count` descending so the loops that
/// abort most — the ones actually keeping a program on tier-0 — are at the top.
/// `rows` is `state.abort_log.items`; the caller owns it (this only reads).
pub fn writeAborts(w: *io.Writer, rows: []AbortRecord) io.Writer.Error!void {
    // Sort a borrowed view in place by count desc, then anchor pc for stability.
    std.mem.sort(AbortRecord, rows, {}, struct {
        fn lt(_: void, a: AbortRecord, b: AbortRecord) bool {
            if (a.count != b.count) return a.count > b.count;
            if (a.anchor_pc != b.anchor_pc) return a.anchor_pc < b.anchor_pc;
            return @intFromEnum(a.op) < @intFromEnum(b.op);
        }
    }.lt);
    try w.print("{s:>12}  {s:>6}  {s:>7}  {s:<14}  {s:>6}  {s:<16}  {s}\n", .{
        "count", "anc@pc", "abrt@pc", "reason", "ir_len", "opcode", "anchor",
    });
    for (rows) |r| {
        try w.print("{d:>12}  {d:>6}  {d:>7}  {s:<14}  {d:>6}  {s:<16}  {s}\n", .{
            r.count,
            r.anchor_pc,
            r.abort_pc,
            @tagName(r.reason),
            r.ir_len,
            @tagName(r.op),
            r.proto.name,
        });
    }
}

/// Percentage `x / total * 100` as an `f64`, or 0 when `total == 0`.
fn pctOf(x: u64, total: u64) f64 {
    if (total == 0) return 0;
    return @as(f64, @floatFromInt(x)) * 100.0 / @as(f64, @floatFromInt(total));
}

/// Cycles-per-iteration for the stats report; 0 when there were no iterations.
fn cyclesPerIter(cycles: u64, iters: u64) f64 {
    if (iters == 0) return 0;
    return @as(f64, @floatFromInt(cycles)) / @as(f64, @floatFromInt(iters));
}

/// One per-anchor coverage row, materialized from the `coverage` map for sorted
/// display (a hashmap has no stable iteration order; the report must be
/// reproducible — Rule Z-3). Carries both the iteration counts and the cycle
/// (time) attribution so the table can weigh loops by cost, not just count.
const CoverageRow = struct {
    name: []const u8,
    /// Stable serialization id of the anchor's proto — the sort tiebreak, so two
    /// distinct protos that share a name (and pc) still order deterministically
    /// (a `Proto` pointer would order by ASLR-dependent address).
    proto_id: u32,
    pc: u32,
    traced: u64,
    interp: u64,
    traced_cycles: u64,
    interp_cycles: u64,
};

/// Render the JIT stats report to `w` (stderr, via `--jit-coverage`/`--jit-stats`).
/// Reads only — never mutates `ts`. `full = false` prints just the one-line coverage
/// summary (for `--jit-coverage`); `full = true` prints the whole block: the event
/// counters, the aggregate native-vs-tier-0 split by BOTH iterations and time, and a
/// per-anchor table. Iteration% flatters the JIT (a traced iteration is ~10-20×
/// cheaper than a tier-0 one), so the time split — present only on x86_64, where
/// `readCycles` returns a real TSC — is the one to trust. Requires `ts.config.coverage`
/// to have been on during the run, else the counts are all zero (the event counters
/// are always live).
pub fn writeJitStats(w: *io.Writer, ts: *const TraceState, full: bool) io.Writer.Error!void {
    const traced = ts.iters_traced;
    const covered_interp = ts.iters_tier0_covered;
    const uncovered = ts.iters_tier0_uncovered;
    const total = traced +| covered_interp +| uncovered;
    // "covered by a trace" = a compiled trace exists at the anchor = ran-as-trace
    // plus fell-back-despite-a-trace.
    const covered = traced +| covered_interp;

    // Time attribution (TSC cycles). `run` is the whole-run denominator so the three
    // loop classes plus `other` (straight-line / non-loop code) partition it.
    const c_traced = ts.cycles_traced;
    const c_cov = ts.cycles_tier0_covered;
    const c_unc = ts.cycles_tier0_uncovered;
    const c_loop = c_traced +| c_cov +| c_unc;
    const run = ts.run_cycles;
    const has_time = run > 0;
    // Clamp: TSC skew across the per-region brackets can make the loop sum slightly
    // exceed the single outer bracket; never report negative "other".
    const c_other = if (run > c_loop) run - c_loop else 0;

    if (!full) {
        // One-liner for --jit-coverage. `fallback` = the smell: had a trace, ran
        // tier-0. The time fragment is what de-misleads the iteration percentages.
        try w.print(
            "mahina: jit coverage — iters: traced {d:.1}% / fallback {d:.1}%",
            .{ pctOf(traced, total), pctOf(covered_interp, total) },
        );
        if (has_time) {
            try w.print(
                "  |  time: traced {d:.1}% / tier-0 {d:.1}% (covered-fallback {d:.1}%)\n",
                .{ pctOf(c_traced, run), pctOf(c_cov +| c_unc, run), pctOf(c_cov, run) },
            );
        } else {
            try w.writeAll("  (time: n/a on this target)\n");
        }
        return;
    }

    try w.writeAll("mahina: JIT stats\n");
    try w.writeAll("  event counters:\n");
    try w.print("    trace entries:        {d} (native bodies: {d})\n", .{ ts.entries, ts.native_entries });
    try w.print("    link arms:            native={d} source={d} loopdone={d} bridge={d}\n", .{ ts.native_link_arms, ts.native_source_link_arms, ts.native_loopdone_link_arms, ts.native_region_bridge_arms });
    try w.print("    bridge arm attempts:  {d} (pipeline runs; vs {d} arms)\n", .{ ts.native_region_bridge_arm_attempts, ts.native_region_bridge_arms });
    try w.print("    link fused:           source={d} loopdone={d} bridge={d}\n", .{ ts.native_source_link_fused, ts.native_loopdone_link_fused, ts.native_region_bridge_fused });
    try w.print("    link disarms:         {d} (peak simultaneous arms: {d})\n", .{ ts.native_link_disarms, ts.native_link_peak });
    try w.print("    native link exits:    {d} (follows={d})\n", .{ ts.native_link_exits, ts.native_link_follow_count });
    try w.print("    ir link exits:        {d} (follows={d})\n", .{ ts.link_ir_exits, ts.link_follow_count });
    try w.print("    prime-side:           arms={d} chain-follows={d} tier0-body-entries={d}\n", .{ ts.prime_side_arms, ts.prime_side_chain_follows, ts.tier0_outer_body_entries });

    try w.writeAll("  coverage by loop iterations (count — flatters the JIT):\n");
    try w.print("    traced (ran as trace):  {d:>12}  ({d:.1}%)\n", .{ traced, pctOf(traced, total) });
    try w.print("    tier-0, has-trace:      {d:>12}  ({d:.1}%)   <- fallback despite a trace\n", .{ covered_interp, pctOf(covered_interp, total) });
    try w.print("    tier-0, no-trace:       {d:>12}  ({d:.1}%)\n", .{ uncovered, pctOf(uncovered, total) });
    try w.print("    total:                  {d:>12}\n", .{total});
    try w.print("    covered by a trace:     {d:.1}%   ran as a trace: {d:.1}%\n", .{ pctOf(covered, total), pctOf(traced, total) });

    if (has_time) {
        // The seam is a sub-interval of the traced bracket (`cycles_seam` doc);
        // clamp so TSC skew can never report negative native time.
        const c_seam = if (ts.cycles_seam < c_traced) ts.cycles_seam else c_traced;
        const c_native = c_traced - c_seam;
        const c_tier0 = c_cov +| c_unc;
        try w.writeAll("  coverage by time (TSC cycles — the honest split):\n");
        try w.print("    traced (ran as trace):  {d:>12}  ({d:.1}% of run)\n", .{ c_traced, pctOf(c_traced, run) });
        try w.print("      native execution:     {d:>12}  ({d:.1}% of run)\n", .{ c_native, pctOf(c_native, run) });
        if (ts.seam_walks > 0) {
            try w.print("      steering seam:        {d:>12}  ({d:.1}% of run)   replayLedger: {d} walks, ~{d} cyc/walk\n", .{
                c_seam, pctOf(c_seam, run), ts.seam_walks, ts.cycles_seam / ts.seam_walks,
            });
        } else {
            try w.print("      steering seam:        {d:>12}  ({d:.1}% of run)   replayLedger: 0 walks\n", .{ c_seam, pctOf(c_seam, run) });
        }
        try w.print("    tier-0 (Vm.exec bodies):{d:>12}  ({d:.1}% of run)\n", .{ c_tier0, pctOf(c_tier0, run) });
        try w.print("      tier-0, has-trace:    {d:>12}  ({d:.1}% of run)   <- fallback despite a trace\n", .{ c_cov, pctOf(c_cov, run) });
        try w.print("      tier-0, no-trace:     {d:>12}  ({d:.1}% of run)\n", .{ c_unc, pctOf(c_unc, run) });
        try w.print("    other (non-loop):       {d:>12}  ({d:.1}% of run)\n", .{ c_other, pctOf(c_other, run) });
        try w.print("    run total:              {d:>12}\n", .{run});
        // Per-iteration / per-entry costs — the numbers that expose transition
        // amortization (few iters per native entry = the seam dominates) and let
        // the native c/it be compared against another VM's whole-run c/it without
        // hand arithmetic.
        if (traced > 0 or covered_interp +| uncovered > 0) {
            try w.writeAll("    cycles/iter:           ");
            if (traced > 0) {
                try w.print(" traced ~{d:.1} (native ~{d:.1} + seam ~{d:.1})", .{
                    cyclesPerIter(c_traced, traced), cyclesPerIter(c_native, traced), cyclesPerIter(c_seam, traced),
                });
            }
            const t0_iters = covered_interp +| uncovered;
            if (t0_iters > 0)
                try w.print("   tier-0 ~{d:.1}", .{cyclesPerIter(c_tier0, t0_iters)});
            try w.writeAll("\n");
            if (traced > 0 and ts.entries > 0)
                try w.print("    iters/native-entry:     ~{d}\n", .{traced / ts.entries});
        }
        if (ts.run_nanos > 0) {
            // Wall time pairs with the TSC total to recover the effective clock
            // (cycles/ns = GHz), turning the cycle percentages above into real time.
            const ns: f64 = @floatFromInt(ts.run_nanos);
            const ghz = @as(f64, @floatFromInt(run)) / ns;
            try w.print("    run wall time:          {d:>9.3} ms   (~{d:.2} GHz effective)\n", .{ ns / 1_000_000.0, ghz });
        }
        try w.print("    ran as a trace: {d:.1}% of run   ({d:.1}% of loop time)\n", .{ pctOf(c_traced, run), pctOf(c_traced, c_loop) });
    } else {
        try w.writeAll("  coverage by time: n/a (no TSC on this target)\n");
    }

    // Per-anchor table, sorted (proto name, pc, proto id) for reproducibility. Fixed
    // buffer: real programs have a handful of hot loops, so it never fills. If it
    // ever DID overflow, the kept subset is the first 256 in hash-map order (which is
    // layout-dependent) — only then is *which* rows survive nondeterministic; the
    // shown rows are always sorted. A `truncated` note flags the (unrealistic) case.
    var rows: [256]CoverageRow = undefined;
    var n: usize = 0;
    var truncated = false;
    var it = ts.coverage.iterator();
    while (it.next()) |e| {
        if (n == rows.len) {
            truncated = true;
            break;
        }
        rows[n] = .{
            .name = e.key_ptr.proto.name,
            .proto_id = e.key_ptr.proto.id,
            .pc = e.key_ptr.pc,
            .traced = e.value_ptr.traced,
            .interp = e.value_ptr.interp,
            .traced_cycles = e.value_ptr.traced_cycles,
            .interp_cycles = e.value_ptr.interp_cycles,
        };
        n += 1;
    }
    std.mem.sort(CoverageRow, rows[0..n], {}, struct {
        fn lt(_: void, a: CoverageRow, b: CoverageRow) bool {
            const c = std.mem.order(u8, a.name, b.name);
            if (c != .eq) return c == .lt;
            if (a.pc != b.pc) return a.pc < b.pc;
            return a.proto_id < b.proto_id;
        }
    }.lt);
    if (n > 0) {
        // Columns: iteration split (traced/interp + trace%), then the time view —
        // this anchor's share of the whole run and how much of ITS OWN time was
        // traced. `run%`/`traced%time` are the ones that expose a hot loop that
        // "has a trace" yet spends its time interpreted. Time cols blank when no TSC.
        try w.writeAll("  per-anchor (loop header):\n");
        try w.print("    {s:<18}  {s:>11}  {s:>11}  {s:>6}   {s:>6}  {s:>8}  {s:>8}  {s:>8}\n", .{ "anchor", "traced-it", "interp-it", "trc%it", "run%", "trc%time", "trc-c/it", "t0-c/it" });
        for (rows[0..n]) |r| {
            var name_pc_buf: [64]u8 = undefined;
            const label = std.fmt.bufPrint(&name_pc_buf, "{s}:{d}", .{ r.name, r.pc }) catch "?";
            const anchor_cycles = r.traced_cycles +| r.interp_cycles;
            if (has_time) {
                try w.print("    {s:<18}  {d:>11}  {d:>11}  {d:>5.1}%   {d:>5.1}%  {d:>7.1}%  {d:>8.1}  {d:>8.1}\n", .{
                    label,                                    r.traced,
                    r.interp,                                 pctOf(r.traced, r.traced +| r.interp),
                    pctOf(anchor_cycles, run),                pctOf(r.traced_cycles, anchor_cycles),
                    cyclesPerIter(r.traced_cycles, r.traced), cyclesPerIter(r.interp_cycles, r.interp),
                });
            } else {
                try w.print("    {s:<18}  {d:>11}  {d:>11}  {d:>5.1}%   {s:>6}  {s:>8}\n", .{
                    label, r.traced, r.interp, pctOf(r.traced, r.traced +| r.interp), "n/a", "n/a",
                });
            }
        }
        if (truncated) try w.writeAll("    … (per-anchor table truncated at 256 anchors)\n");
    }
}

pub const withPhis = trace_ir.withPhis;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
//
// The test suite lives in sibling `*_test.zig` files (split by theme). Zig only
// analyses a file that is reachable by import, so this block is what makes them
// run under `zig build test`.

test {
    _ = @import("trace_ir_test.zig");
    _ = @import("trace_record_test.zig");
    _ = @import("trace_chain_test.zig");
    _ = @import("trace_provenance_test.zig");
    _ = @import("trace_promotion_test.zig");
    _ = @import("trace_replay_test.zig");
    _ = @import("trace_fingerprint_test.zig");
    _ = @import("trace_gate_test.zig");
    _ = @import("trace_region_test.zig");
    _ = @import("trace_entrypatch_test.zig");
}
