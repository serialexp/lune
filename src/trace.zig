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
const native_physical = @import("trace_native_registry.zig");
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
const trace_exec = @import("trace_exec.zig");
const jitdbg = @import("jitdbg.zig");
const Value = value.Value;
const Proto = bytecode.Proto;
const Instr = bytecode.Instr;
const OpCode = bytecode.OpCode;
const table_mod = @import("table.zig");
const arr = @import("array.zig");
const string_mod = @import("string.zig");
const gc = @import("gc.zig");
const object = @import("object.zig");
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
const trace_link_mod = @import("trace_link.zig");
const trace_regionops_mod = @import("trace_regionops.zig");
const trace_chain_mod = @import("trace_chain.zig");
const trace_recorder_mod = @import("trace_recorder.zig");
const trace_code = @import("trace_code.zig");
const trace_record = @import("trace_record.zig");
const traceser = @import("traceser.zig");
const exit_attach = @import("trace_exit_attach.zig");
pub const trace_entry_registry = @import("trace_entry_registry.zig");

pub const TraceCode = trace_code.TraceCode;
pub const TraceRecord = trace_record.TraceRecord;
pub const Trace = TraceRecord;
pub const EntryPatchState = trace_record.EntryPatchState;
pub const EntryGuard = trace_code.EntryGuard;
pub const LanePin = trace_code.LanePin;
pub const InputKind = trace_code.InputKind;
pub const InputSeed = trace_code.InputSeed;
pub const UPVALUE_CELL_ANCHOR = trace_code.UPVALUE_CELL_ANCHOR;
pub const FUNC_HEAD_PC = trace_code.FUNC_HEAD_PC;

/// Doc 44: a hot function head waiting for the dispatch prologue to arm a
/// `.head` recording at the callee's pc 0. See `TraceState.onCallEntry` /
/// `maybeStartHead`.
pub const PendingCallAnchor = struct {
    proto: *const Proto,
    /// The callee frame's absolute slab base (the head trace's anchor base).
    base: usize,
    /// The activation stamp from `pushFrame` — pins the pending to exactly
    /// the frame that went hot.
    call_seq: u64,
    /// A1' (doc 45 / task 27): this pending is an ordinary-probe request at a
    /// precise-occupied anchor — `arm()` suppresses the precise memo seed and
    /// the recording's `.needs_precise` aborts strike normally.
    force_ordinary: bool = false,
};
/// A1' (doc 45 / task 27): per-anchor value of `precise_anchor_memo`. The
/// entry's EXISTENCE is the doc 45 D2 "record precise here" policy;
/// `ordinary_probe` additionally requests one ordinary-probe recording so a
/// precise-occupied ONE-SHOT anchor can grow a native-runnable ordinary
/// sibling (set at precise one-shot commit, consumed/kept by the patched
/// entry walk, cleared on ordinary commit / gate-barred / population cap).
pub const PreciseAnchorMemo = struct { ordinary_probe: bool = false };
/// Doc 44 D12b: a hot post-call resume pc waiting for the dispatch prologue
/// to arm a `.cont` recording at the CALLER's frozen cursor. Set by
/// `onRetResume` (the `opRet` funnel), consumed by `maybeStartCont`.
pub const PendingRetAnchor = struct {
    proto: *const Proto,
    /// The caller's frozen one-past-call cursor — the cont anchor's entry pc.
    resume_pc: u32,
    /// The caller frame's absolute slab base (the cont trace's anchor base).
    base: usize,
    /// The activation stamp from `pushFrame` — pins the pending to exactly
    /// the caller activation the hot return resumed.
    call_seq: u64,
    /// A1' (doc 45 / task 27): ordinary-probe request — see PendingCallAnchor.
    force_ordinary: bool = false,
};
pub const isHeadAnchorPc = trace_code.isHeadAnchorPc;
pub const AnchorPcKind = trace_code.AnchorPcKind;
pub const anchorKind = trace_code.anchorKind;
pub const entryPc = trace_code.entryPc;
pub const contAnchorPc = trace_code.contAnchorPc;
pub const NativeSeedCtx = trace_code.NativeSeedCtx;
pub const TOUCHED_CAP = trace_code.TOUCHED_CAP;
pub const FrameMotionAbi = trace_code.FrameMotionAbi;

pub const Ref = trace_ir.Ref;
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

const trace_types = @import("trace_types.zig");
const trace_region = @import("trace_region.zig");

pub const Polarity = trace_types.Polarity;
pub const GuardRole = trace_types.GuardRole;
pub const OperandDesig = trace_types.OperandDesig;
pub const GuardProvenance = trace_types.GuardProvenance;
pub const ExitProvenance = trace_types.ExitProvenance;
pub const ExitProvEntry = trace_types.ExitProvEntry;
pub const ExitKey = trace_types.ExitKey;
const DescentFailCarry = trace_types.DescentFailCarry;
pub const ProgramPoint = trace_types.ProgramPoint;
pub const StructuralEdgeId = trace_types.StructuralEdgeId;
pub const AnchorKey = trace_types.AnchorKey;
pub const AnchorMap = trace_types.AnchorMap;
pub const RetireStep = trace_types.RetireStep;
pub const RetireWork = trace_types.RetireWork;
pub const exitOrder = trace_types.exitOrder;

pub const RegionId = trace_region.RegionId;
pub const RegionKey = trace_region.RegionKey;
pub const RegionAccum = trace_region.RegionAccum;
pub const RegionDestination = trace_region.RegionDestination;
pub const RegionContext = trace_region.RegionContext;
pub const CloseReason = trace_region.CloseReason;
pub const RegionClassifier = trace_region.RegionClassifier;
pub const RegionBridgeDef = trace_region.RegionBridgeDef;
pub const RegionDef = trace_region.RegionDef;
pub const RECURRENCE_SIG_CAP = trace_region.RECURRENCE_SIG_CAP;
pub const RegionInternMap = trace_region.RegionInternMap;
pub const ObserverSpan = trace_region.ObserverSpan;
pub const freeRegionBridges = trace_region.freeRegionBridges;
pub const cloneRegionBridges = trace_region.cloneRegionBridges;
pub const freeRegionSetMap = trace_region.freeRegionSetMap;
pub const RegionSetBuilder = trace_region.RegionSetBuilder;
pub const programPointsEqual = trace_region.programPointsEqual;
pub const appendUniqueSlot = trace_region.appendUniqueSlot;
pub const programPointLess = trace_region.programPointLess;

/// Whether IR instruction `idx` of `t` is a numeric-for loop-done guard: a
/// `guard_true` whose deopt PC lands immediately after a `for_loop` bytecode op.
/// The arming side's name for `TraceCode.isNumericForLoopDoneGuard` (the P-C
/// option (b) invariant, 2.3c-0a), which reads the commit-time memo. Safe on
/// synthetic traces with an undefined anchor and empty `instrs`: both the memo and
/// its oracle refuse an out-of-range `idx` before touching the anchor.
pub fn isLoopDoneGuardIndex(t: *const Trace, idx: usize) bool {
    return t.code.isNumericForLoopDoneGuard(idx);
}

/// Doc 58: the test of the loop this trace is anchored at, for ALL three loop
/// shapes — `for_loop`/`tfor_loop`, `while` (the branch above the `loop`
/// marker) and `repeat` (the backward branch onto it). Use at accounting sites
/// where "the loop ran to completion" matters regardless of loop shape
/// (hot-exit exclusion, receipt region-work) and wherever a loop exit must not
/// be mistaken for a branch alternation. Kind-specific machinery (the native
/// linked materialization, `flushNumericForLoopDone`) keeps using
/// `isLoopDoneGuardIndex` / `isNumericForLoopDoneGuard`, because only a
/// numeric/generic `for` owes the final-iteration flush.
///
/// This replaces doc 38's `while`-specific chain (`whileLoopDonePostPc`,
/// `isWhileLoopDoneGuardIndex`, `whileDoneCoherentAtZero`,
/// `isAnyLoopDoneGuardIndex`): with the condition at the END of the trace, a
/// `while` exit is an ordinary exit that resumes after the loop, so there is
/// nothing left for those to classify.
pub fn isOwnLoopTestIndex(t: *const Trace, idx: usize) bool {
    return t.code.isOwnLoopTest(idx);
}

/// Caller-declared intent for `armNativeLink`, enforcing the P-C option (b) invariant
/// (doc 17, 2.3c-0a): a numeric-for loop-done guard's `slot[ei]` is EXCLUSIVELY its
/// linked-materialized exit. So only a `.loop_done_linked` arm may target a loop-done
/// guard slot, and conversely `.link_terminal` / `.ordinary_guard` arms must never
/// land on one (a loop-done ordinary deopt reaches `shared_exit` through the memory-
/// staged `NativeResult.exit_target`, never through `slot[ei]`).
pub const ArmKind = native_physical.ArmKind;

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
    /// Doc 56 Phase 3: the `driveChain` candidate whose `.link` continuation
    /// ran to its `.link` terminal — through the scalar burst, or (Phase 5)
    /// as the head row of a native span drained through the seed ledger,
    /// however far its armed `.link` then fused. The exit-side router reads
    /// it to bind a wanted exit to the child that served it and (§4.8.3 R2)
    /// to arm exactly that child, which need not be the canonical pick at
    /// `P` when an earlier candidate refused its entry. Null when no
    /// candidate reached its `.link`.
    linked_trace: ?*Trace = null,
    /// Doc 64 §10 step 2: the deopt that ended a chain that did not link,
    /// when it is one candidate's own exit (a scalar run whose ledger never
    /// left the candidate, `exit_reason == .normal`). The exit-side router
    /// reads it to tell a chain that ran into the end of an enclosing loop
    /// from a misfit (`exitSideChainOutcome`). Null for every other shape,
    /// which the router counts as a misfit, as before.
    terminal: ?ExitKey = null,
    /// Doc 56 Phase 5: a ledger replay ended on an UNARMED exit adapter's
    /// row (the exit is wanted, or attached but not armed): the slab is
    /// coherent at `resume_pc` (the exit's resume pc) and the row's receipt
    /// is already charged. The dispatcher runs the routing half of the
    /// exit-side consumer for it (chain, bind, arm, or ask for a recording).
    exit_side: ?ExitSideTerminal = null,
};

/// Doc 64 §10 step 2 (2d): a given-up exit waiting for a trace to commit at
/// its resume point `{proto_id, pc}`.
pub const ExitSideWaiter = struct { proto_id: u32, pc: u32, exit: ExitKey };

/// Doc 56 Phase 5: the exit whose adapter ended a replayed ledger, and the
/// work its row committed (the parent's laps plus the interrupted
/// iteration, as `consumeExitSide`'s `completed + 1`).
pub const ExitSideTerminal = struct { trace: *Trace, exit: u32, done: usize };

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
///                                `failed.code.anchor.pc` and nothing is owed.
///   * `.ir_numeric_for_done`   — a tier-1a numeric-`for` loop-done exit; the final
///                                iteration's sunk stores + φ hand-off are still in
///                                the carried executor scratch (`[]Value`) and must
///                                be flushed via `flushNumericForLoopDone` before a
///                                continuation runs.
///   * `.native_numeric_for_done` — a native numeric-`for` loop-done exit; the root
///                                was entered with `runLinkedLoopDone`, so the final
///                                iteration is already materialized — no flush owed.
///                                `driveChain` declines any exit whose guard does
///                                not emit the linked flush (`linkedLoopDoneEmitted`).
pub const ExitMaterialization = union(enum) {
    ordinary_header,
    ir_numeric_for_done: []Value,
    native_numeric_for_done,
    /// Doc 56 Phases 3–4: an exit-side exit. The executor (tier-1a) or the
    /// exit adapter (native) already made the slab coherent at the exit's
    /// resume pc `P` (the payload), so the chain walks `.link` continuations
    /// at `P` and a zero-progress candidate resumes tier-0 at `P`, never at
    /// the anchor.
    exit_side: u32,
};

/// Doc 20 (patched trace entry): one registry slot binding a `.jfor_loop` or
/// `.jloop`
/// patched into a per-VM code image to its qualified root trace. Slots are
/// **stable-address** (§R2-6): each is its own heap allocation, the index in
/// `TraceState.registry.entry_registry.entry_patches` is baked into the image instruction's `.b`, and
/// tombstoned slots are reused via `entry_patch_free` — never compacted.
pub const EntryPatch = trace_entry_registry.EntryPatch;

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
    /// Why the LAST escalation fired (doc 31 D3 receipt line).
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
    record_abort,
    commit_failure,
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
    kind: trace_exec.LedgerKind,
    outcome: trace_exec.LedgerOutcome,
};

// ---------------------------------------------------------------------------
// Recorder + trace state
// ---------------------------------------------------------------------------

/// Why a recording was abandoned. Aborting discards the partial trace and leaves
/// tier-0 entirely untouched; the anchor may be retried later (penalty/blacklist
/// backoff is a later increment — see the lifecycle doc). `recordInstr` and the
/// state machine fill these in (Increment B).
pub const AbortReason = trace_recorder_mod.AbortReason;

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
    /// Doc 57 P3 (LuaJIT `instunroll`, `lj_jit.h` default 4): how many extra
    /// source iterations one recording may add to its loop body when the
    /// close finds a value-pinned carried slot (nil/false/true) holding
    /// another value — the flipped boolean. 0 = abort `type_instability`
    /// at the first such close (pre-P3 behaviour).
    instunroll: u8 = 4,
    /// Doc 56 G6-Q1(d) (LuaJIT `loopunroll`, `lj_jit.h` default 15): how many
    /// loop iterations a side or continuation recording may unroll — loops it
    /// goes round without linking to a root — before aborting `.loop_unroll`.
    loopunroll: u8 = 15,
    /// Back-edge count at which a loop header becomes a trace anchor.
    hotloop: u32 = 56,
    /// Doc 44: call count at which a Lua function head becomes a trace anchor.
    /// Default `2 * hotloop` — LuaJIT's ½-weight for calls (`HOTCOUNT_CALL=1`
    /// vs `HOTCOUNT_LOOP=2`) expressed as a separate threshold so the loop
    /// hot-count pre-filter stays untouched. Counted in `onCallEntry` on
    /// SUCCESSFUL Lua-callee entries only (tier-0's own depth/capacity checks
    /// already passed), a pure function of executed calls — no addresses, no
    /// time (the determinism rule, doc 44 D7).
    hotcall: u32 = 112,
    /// Maximum IR instructions in one trace before aborting (`too_long`).
    maxrecord: u32 = 2000,
    /// Doc 45 D2: deterministic snapshot admission budgets for PRECISE
    /// recordings — a pure function of the recorded maps, never available
    /// memory. Tests inject smaller values to exercise exact-boundary and
    /// one-over refusal.
    snapshot_budget: @import("trace_snapshot.zig").Budget = .{},
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
    /// Doc 47 Increment B follow-up: fallback-region instability tombstone.
    /// A fallback-elected region whose promotions are destroyed by `.unfreeze`
    /// demotions (window strike killing a live promotion) this many times —
    /// net of clean `.region_close` survivals, which decrement — is
    /// invalidated: the promote/patch + demote/unpatch churn costs more than
    /// the ledger drains it saves (measured: scimark-lu, 175k cycles/run).
    region_instability_tombstone: u8 = 8,
    /// Fallback-region failed-opportunity tombstone: full-cap `.yielded`
    /// ledgers for an ACTIVE frozen fallback region that produce no promotable
    /// candidate. Reset by a successful promotion. 2× `promote_after`.
    region_no_candidate_tombstone: u8 = 8,
    /// Dormant-admission probe cap: after this many failed admission probes a
    /// dormant fallback region is never probed again (terminal dormancy),
    /// bounding the probe cost on shapes that never qualify.
    region_admission_probe_cap: u8 = 64,
    /// Doc 52: consecutive identical qualifying recurrent pure bursts (short
    /// natural-terminal dispatcher ledgers) required before a resident
    /// promotion — the recurrence-evidence analogue of `promote_after`.
    recurrence_promote_after: u8 = 4,
    /// Doc 52: recurrence probe budget. Charged on EVERY expensive detector
    /// probe of a def — owner resolution, win or lose, and threshold
    /// attempts — so alternating valid shapes saturate instead of scanning
    /// the armed registry forever. At the cap the def stops being probed.
    /// Reset only by a successful resident promotion. Deliberately separate
    /// from `region_admission_probe_cap`: short bursts must never exhaust
    /// the full-cap dormant-admission budget.
    recurrence_probe_cap: u8 = 64,
    /// Net-profitability minimum sample: priced receipts a fallback region
    /// may accumulate before the credit/debit balance is enforced. Below
    /// this, no verdict — admission evidence plus the other triggers
    /// (instability, no-candidate) govern the warmup.
    region_payoff_receipts: u32 = 4096,
    /// Net-profitability weight: one suppressed silent transition repays
    /// this many priced receipts. Grounded in measured micro-costs, not a
    /// benchmark: a suppressed ledger row saves its share of the ~4889-cycle
    /// LEDGER_CAP drain (~150 cycles/row), while a priced receipt costs the
    /// classify/choose walk (tens of cycles) — the ratio sits in the low
    /// single digits; 4 keeps a margin toward keeping regions alive.
    region_profit_weight: u32 = 4,
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
    /// Doc 56 (LuaJIT `JIT_P_tryside` = 4): once an attachable exit is wanted
    /// (at `hotexit`), how many further firings it gets to record or bind an
    /// exit-side child before it gives up and returns to today's routes.
    tryside: u8 = 4,
    /// Doc 56 (LuaJIT `JIT_P_maxside` = 100): the most exit-side children one
    /// parent trace may bind; past it no exit of that trace becomes wanted.
    maxside: u32 = 100,
    /// Doc 56 Phase 3: exit-side routing on the tier-1a executor. Native
    /// runs keep today's routes until Phase 4 regardless. A test/ablation
    /// knob; on by default (Bart, 2026-09-25).
    exit_side: bool = true,
    /// Doc 56 Phase 4: exit-side routing on NATIVE pages (needs
    /// `exit_side`). Compiles the exit-side stub at every attachable exit
    /// and keeps the values its adapter reads live there; a wanted or
    /// attached exit then materializes at `P` natively. On by default since
    /// doc 58 B2: a `while`/`repeat` loop's own test is an ordinary exit at
    /// the end of its trace, and exit-side is what serves it (the deleted
    /// doc 38 `.while_done` chain and `.low_trip_while` gate did before).
    /// Off (`--jit-no-exit-side-native`), the machine code is byte-identical
    /// to a pre-Phase-4 page — an ablation knob, not a supported tier.
    exit_side_native: bool = true,
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

/// Hash `(proto, pc)` into a hot-count slot, keyed on `proto.id` rather than the
/// address (like `AnchorKeyContext`): which anchors share a slot is then the same
/// on every run, so tiering timing and instruction counts don't vary with ASLR.
/// A collision only changes *which* back-edges take the slow path, never the
/// result. `proto` must be live; every caller is the dispatch loop running it.
inline fn hotIndex(proto: *const Proto, pc: u32) usize {
    // Mix in u64 explicitly: the golden-ratio constant is 64-bit, so a `usize`
    // accumulator overflows on a 32-bit target (wasm32). The final mask keeps
    // the result within `HOTCOUNT_SIZE`, so the `@intCast` back to usize is safe.
    var h: u64 = proto.id;
    h ^= @as(u64, pc) *% 0x9E3779B97F4A7C15;
    h ^= h >> 29;
    return @intCast(h & (HOTCOUNT_SIZE - 1));
}

/// One armed native link (P-E, doc 17 Increment 2.3): `parent`'s frameless exit slot
/// at `slot_index` currently jumps straight into `child`'s body. Keyed by trace
/// identity (not a raw slot address) so lifetime resets stay valid no matter which
/// end retires first — the slot address is re-derived from the live `parent` at reset.
pub const NativeLink = native_physical.NativeLink;

pub const PromotedEdge = native_physical.PromotedEdge;

/// B-3d (doc 17 §B3.16 D2): the promoted unit is the frozen region's armed-edge
/// SET in canonical (parent id, exit) order — no ring order exists and none is
/// stored. A ring is just a set whose automaton happens to be periodic; every
/// per-edge fact reporting needs is MEASURED into `summary` by the epilogues
/// (`firings`/`last_ordinal`/`last_productive_ordinal`), never reconstructed
/// from position.
// pub for trace_chain.zig (file-split pass)
pub const PromotedSet = native_physical.PromotedSet;
/// Doc 52 P1: resident-set sentinel + storage-blind helper (see
/// trace_native_registry.zig — policy sites never compare raw activations).
pub const RESIDENT_ACTIVATION = native_physical.RESIDENT_ACTIVATION;
pub const isResidentKey = native_physical.isResidentKey;

const PromotionRejects = struct {
    bridge_member: u64 = 0,
    region_mismatch: u64 = 0,
    open_chain: u64 = 0,
    no_silent_site: u64 = 0,
    child_mismatch: u64 = 0,
    cap: u64 = 0,
    /// B-3d (§B3.17 R1): `promoteSet` refused because the region already owns a
    /// live set — one set per region key is an ENFORCED invariant, and candidacy
    /// must restart from fully-reporting windows after the owning set demotes.
    region_owned: u64 = 0,
    /// Doc 52 P1 invariant 3: promotion (either keying) refused because a live
    /// set with the same RegionId exists under the OTHER keying — the
    /// sentinel/real dual-key backstop. Near-impossible in practice (resident
    /// regions are dormant and never open activations); fail-closed.
    region_id_owned: u64 = 0,
    /// Doc 52 P1 invariant 1: resident promotion refused because the single
    /// global resident slot is occupied by another region's set. The streak
    /// holds saturating until the occupant demotes.
    resident_occupied: u64 = 0,
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
/// anchored here; `interp` = interpreted (tier-0) back-edges taken at this anchor;
/// `fallback` = the part of `interp` taken once `has_trace` was set (the rest is
/// warm-up before the first trace committed), so `traced` vs `fallback` says
/// whether the loop ran as a trace once it could — warm-up no longer dilutes it.
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
    fallback: u64 = 0,
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
    /// Doc 43 §3.1 (P0a): the dispatch loop's `st.base` at the current back-edge,
    /// stashed just before `onBackEdge` so `arm` can seed the recorder's
    /// `anchor_abs_base` (the arm sites live inside `onBackEdge` and don't carry
    /// the absolute slab index otherwise). Read once at arm; stale between
    /// back-edges is harmless (only consumed at the arming instant).
    pending_anchor_base: usize = 0,
    /// Doc 43 §3.1 (P0a): per-instruction supply of an OPEN `get_upval` cell's
    /// `loc.open` slab index (null otherwise), the mirror of `rec_heap`'s
    /// supply-per-call discipline. Copied into the recorder's `InstructionContext`
    /// by `recordInstr`; consumed by `recInputGet` to reject aliasing snapshots.
    rec_upval_open: ?usize = null,
    /// Doc 43 P5: per-instruction supply of a `get_upval`/`set_upval`'s
    /// resolved `*Upvalue` cell (null for other ops) — the recorder keys
    /// closed-cell alias classes and the snapshot-read set on its address.
    /// Same supply-per-call discipline as `rec_upval_open`.
    rec_upval_cell: ?*function.Upvalue = null,
    /// Doc 43 §3.2 (P0b): the VM globals table's `GcHeader` address, so the
    /// recorder can recognise a store into `_G`. Stable per VM; set by `Vm.initBare`
    /// (null in bare test harnesses — the globals coherence check then no-ops).
    rec_globals_header: ?*const object.GcHeader = null,
    /// MUTABLE execution-heap channel (doc 24 D5): the heap the tier-1a
    /// executor's `.alloc` arms and tier-1b's baked callouts/`guard_gc`
    /// allocate against. Unlike `rec_heap` (refreshed defensively per
    /// `recordInstr`), this may be stored once: `Vm.heap` is itself
    /// heap-allocated with a stable address for exactly this purpose (see the
    /// `Vm.heap` field doc). Set by `Vm.initBare`; null in bare test harnesses,
    /// where allocating traces fail closed (tier-1a side-exits the `.alloc`
    /// arm, `compileInto` declines the page).
    exec_heap: ?*gc.Heap = null,
    registry: @import("trace_registry.zig").TraceRegistry,
    /// Back-edge counters keyed by loop-header anchor. Only touched on the *slow*
    /// path (when the hot-count pre-filter trips), so for a non-gated anchor it
    /// still counts every back-edge (the pre-filter leaves un-gated slots at 0),
    /// preserving the arm-at-`hotloop` timing exactly. A gated anchor's count is
    /// coarse (the pre-filter skips most of its back-edges), which is fine — the
    /// gate's own cooldown is driven by `tick`, not this.
    counters: AnchorMap(u32) = .empty,
    /// Monotonic global back-edge tick. Incremented on *every* back-edge in the
    /// dispatch loop — including ones the hot-count pre-filter skips — so it is the
    /// one clock that never freezes. The gate's `retry_at` cooldown is measured in
    /// these ticks, which is why a transiently-gated loop's cooldown keeps elapsing
    /// while the pre-filter is cheaply skipping its back-edges. Deterministic.
    tick: u64 = 0,
    /// Doc 63 §5.9: while non-zero, guest code runs on tier-0 only. Nothing
    /// records, enters, arms, links, drains or repatches; hot counters still
    /// count. Exactly one party raises and lowers it per host call (the
    /// traced-call shim, or `callHostNative` for a call made while
    /// recording). Changed only through `raiseSuspend`/`lowerSuspend`, which
    /// keep `FastBit.jit_suspended` in step; read through `suspended`.
    suspend_depth: u32 = 0,
    /// Direct-mapped hot-count pre-filter (see `hotIndex`/`HOTCOUNT_SIZE`). A slot
    /// holds the number of back-edges to skip cheaply before re-consulting the slow
    /// path for the anchor(s) that hash there. Zero ⇒ take the slow path now. Set
    /// to `GATE_SKIP` when an anchor is found gated, so a dead loop's millions of
    /// back-edges cost an array decrement instead of three hashmap probes apiece.
    hotcount: [HOTCOUNT_SIZE]u16 = @splat(0),
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
    /// A-vii-d.1: at most one bridge-arm request recorded by `replayLedger` when
    /// it walks a terminal composite `.deopt` row, drained by the ledger DRIVERS
    /// via `drainPendingBridgeArm` after the replay returns (never mid-walk —
    /// review blocker 5: a mid-ledger `invalidateRegion → disarmAllLinks` could
    /// erase the armed provenance later `.region_bridge` rows validate against).
    /// Cleared at every `replayLedger` entry so a stale request can never leak
    /// across ledgers.
    pending_bridge_arm: ?ExitKey = null,
    /// Doc 56 Phase 5: an armed exit-side child failed its prologue in a
    /// replayed ledger; its `.exit_side` arm is disarmed after the walk
    /// (`drainPendingExitSideDisarm`, never mid-walk). The exit stays
    /// attached and re-arms only when a chain into the child links again.
    /// Cleared at every `replayLedger` entry, like `pending_bridge_arm`.
    pending_exit_side_disarm: ?ExitKey = null,
    /// Doc 47 Increment B follow-up: set by `invalidateRegion`; drained at the
    /// dispatcher drain tail (post-replay-walk safe point) by
    /// `drainPendingRegionRebuild` — rebuilds the region topology so the
    /// invalidated region leaves the source/dest receipt maps and
    /// `receiptsInert()` can short-circuit receipts again.
    pending_region_rebuild: bool = false,
    /// Part S: one-shot arm request. Set when a `Trace.sibling_watch_count` crosses
    /// `hotguard`; consumed by `tryArmSiblingHandoff` at the dispatcher's NEXT
    /// successful same-anchor trace entry — so the armed child is the trace the
    /// deterministic dispatch actually ran, never a hit-count guess made here.
    pending_sibling_arm: ?ExitKey = null,
    /// Returning owner + dynamic caller resume PC; consumed only when that
    /// continuation page is actually selected by the dispatcher.
    pending_ret_cont_arm: ?ExitKey = null,
    /// A continuation self-call terminal awaiting entry of the proto head page.
    pending_call_head_arm: ?ExitKey = null,
    /// Doc 44 D10: WALK-LOCAL evidence channel for head sibling-handoff arming.
    /// A head episode's zero-exit (real guard deopt, `completed == 0`) records
    /// the failing `(trace, exit)` here; when a LATER trace in the SAME
    /// `enterPatchedTrace` sibling walk completes terminally, the terminal
    /// consumer charges `noteSiblingTerminal(failer, exit)` — "trace A's branch
    /// guard failed and sibling B then finished the call" is exactly the
    /// handoff-profitable pattern. Reset at every walk start; set ONLY by real
    /// head guard deopts (never declines — a `prologue_fail` or
    /// `seed_capacity_decline` says nothing about the branch); survives
    /// intermediate declines within the walk; consumed (and cleared) at the
    /// terminal-completion consumers when the completing trace differs from the
    /// recorded failer. NOT a per-receipt counter — the counting lives in the
    /// existing Part-S watch (`noteSiblingTerminal`).
    head_walk_fail: ?ExitKey = null,
    /// Doc 44 D12a (A2): descent-bottom failer carry. A pushed descent's final
    /// real-guard deopt happens IN the leaf activation (the D11 deopt contract
    /// flushes into the CURRENT window), so it is legitimate walk-local
    /// evidence FOR the leaf's own upcoming walk — the walk-start reset rule
    /// guards against *stale cross-activation* evidence, which this is not.
    /// `consumePushedDescent` records the final `.deopt`+`.normal` row here
    /// (never `.yielded`, prologue-fail, or seed declines — those carry no
    /// branch-alternative meaning), pinned to the leaf frame's `call_seq`;
    /// the next head walk start consumes it into `head_walk_fail` iff the
    /// entering frame's `call_seq` matches, else discards (the activation
    /// died — and `call_seq` is globally monotone, so a stale carry can never
    /// false-match, the `maybeStartHead` argument). One slot, overwritten by
    /// later descents, consume-or-discard at every head walk start.
    pending_descent_fail: ?DescentFailCarry = null,
    /// Doc 44 D10: owner ids the last fused head burst ENTERED (deduped),
    /// published by the dispatcher's `consumeHeadBurst` for the
    /// `enterPatchedTrace` walk to merge into its visited set — a burst owner
    /// already ran this activation and must not be re-selected by the walk.
    /// Reset at each burst; capacity matches the walk's `trial_visited_cap`
    /// (8). On overflow recording simply stops — the walk's own cap branch
    /// then reports truncation, which is exactly the all-visited-strike
    /// semantics the D8 retention rule wants.
    head_burst_visited: [8]u32 = @splat(0),
    head_burst_visited_len: usize = 0,
    /// A-vii-d.1: nonzero while a `replayLedger` walk is in progress. While set,
    /// `disarmAllLinks` DEFERS (`pending_teardown = .all`), and a region
    /// teardown (`disarmRegionLinks`, doc 64 §15) marks its links and defers
    /// (`.condemned`), instead of mutating the armed-link registry:
    /// later rows of the very ledger being
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
    /// Anchors currently held off tier-1 with a doubling cooldown (`Gate`). Set
    /// when a recording aborts, a commit fails, or the low-yield re-entry penalty
    /// maxes out. Unlike the old permanent blacklist, an anchor here is *retried*
    /// once its cooldown window of back-edges elapses; a re-failure doubles the
    /// window, and after `config.max_strikes` escalations it is abandoned for
    /// good. A loop that was only *temporarily* unstable (type-unstable early,
    /// then settled) recovers; see `isGated` / `gateAnchor`.
    gate: AnchorMap(Gate) = .empty,
    /// Doc 31 D1: anchors currently held off *recording* (never dispatch) with
    /// the same doubling cooldown. Set on recording aborts and commit
    /// failures — LuaJIT's `penalty_pc` analog: a failed recording backs off
    /// RE-RECORDING at its start anchor; a committed trace at the same anchor
    /// keeps dispatching. Recording eligibility consults BOTH maps
    /// (`recordingBarred`); dispatch consults only `gate`. At `max_strikes`
    /// the anchor is permanently record-blacklisted (survives trace
    /// retirement — accepted `penalty_pc` blacklist semantics, doc 31 §3).
    record_gate: AnchorMap(Gate) = .empty,
    /// Doc 38: per-anchor count of `loop_leave` aborts (a while/repeat root
    /// recording that observed its own loop's exit direction). Below
    /// `config.lleave_fast_retries` the abort is a silent retry (no record-gate
    /// strike); at/past it, the anchor is treated as a proven low-trip loop —
    /// gate strikes resume AND `recWhileLink`'s innerloopleft check lets an
    /// enclosing root unroll it. Reset wholesale with the gates (epoch
    /// boundary) so a freed proto's key never lingers.
    lleave_count: AnchorMap(u32) = .empty,
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
    unroll_fail: AnchorMap(u32) = .empty,
    /// Doc 43 P5 (the read-routing memo): anchors where a recording aborted
    /// `.upvalue_mutable` — a `set_upval` hit a cell whose value the same
    /// recording had already baked into the per-entry snapshot. The gated
    /// retry arms with `route_upvalue_reads`, so scalar closed-cell reads go
    /// through per-iteration `uload`s from the start and the store records.
    /// Read-only loops never land here and keep their free snapshot hoist —
    /// the LuaJIT-flavoured penalty/retry answer to doc 43 §8's open question.
    /// Grows monotonically (an anchor set is never cleared: the loop's shape
    /// is lexical); bounded by the number of distinct upvalue-mutating loops.
    upvalue_mutable_memo: AnchorMap(void) = .empty,
    /// Doc 45 D2 (deterministic re-recording): anchors whose recording met a
    /// bytecode that needs per-instruction precise deopt (`new_table` today).
    /// The `.needs_precise` cancel memoizes here without a gate strike and
    /// re-arms the hotness counter; `arm` seeds `rec.precise` from this memo
    /// so the retry records the whole episode in precise mode from the first
    /// instruction. Per-anchor POLICY that survives the cancelled candidate —
    /// never keyed by addresses, so it replays byte-identically. Grows
    /// monotonically like `upvalue_mutable_memo` (lexical loop shape),
    /// bounded by the number of distinct constructing anchors.
    precise_anchor_memo: AnchorMap(PreciseAnchorMemo) = .empty,
    /// A1' (task 27): number of anchors whose memo currently has
    /// `ordinary_probe` set. Steady-state fast reject for the patched-entry
    /// probe check (`ordinaryProbeNeeded`): one branch on this counter
    /// instead of a hashmap probe per one-shot entry. Maintained ONLY by
    /// `setOrdinaryProbe`/`clearOrdinaryProbe`.
    ordinary_probe_count: u32 = 0,
    /// Re-entry penalty per anchor: a low-yield trace entry bumps it, a
    /// productive one clears it (doc 31 D2); at `config.max_penalty` the anchor
    /// is gated off with a doubling cooldown (`onSideExit` → `gateAnchor`).
    penalty: AnchorMap(u32) = .empty,
    region_policy: @import("trace_region_policy.zig").RegionPolicy = .{},
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
    /// `for_prep` first trips handed to their loop's live `.jfor_loop` slot
    /// (`Vm.patchedForEntry`, LuaJIT's JFORI) instead of the discovery walk.
    /// Diagnostic/test only — no tiering path reads it.
    for_prep_patched: u64 = 0,
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
    /// Doc 45 D6 diagnostic: tier-1a `.precise_resume` exits consumed — a
    /// PRECISE trace's body guard failed, the executor materialized its
    /// per-bytecode snapshot into the guest registers, and the dispatcher
    /// resumed tier-0 at the snapshot's `resume_pc`. Output equality alone
    /// cannot prove the precise path fired (for the pure bodies P1 admits,
    /// entry replay is observationally equivalent) — the executor tests
    /// assert on this witness. No tiering path reads it.
    precise_resumes: u64 = 0,
    /// Doc 64 §11 diagnostics (`--jit-stats` "region closes:" and "dispatch
    /// gates:" lines): region accumulator closes by `CloseReason`, and
    /// `gateAnchor` escalations by `GateReason`. No tiering path reads them.
    region_closes: std.EnumArray(CloseReason, u64) = .initFill(0),
    dispatch_gates: std.EnumArray(GateReason, u64) = .initFill(0),
    /// Doc 56 Phase 3 diagnostics (`--jit-stats` "exit side:" line). No
    /// tiering path reads them.
    /// Exits that became wanted (`noteTakenExit`'s tier-1a route).
    exit_side_wants: u64 = 0,
    /// Wanted exits that gave up after `tryside` firings without a child.
    exit_side_giveups: u64 = 0,
    /// `.exit_side` exits consumed by the dispatcher (materialized at `P`).
    exit_side_hops: u64 = 0,
    /// Of those, the ones that chained into a continuation at `P`.
    exit_side_chains: u64 = 0,
    /// Wanted exits bound to a child (by chaining or by a commit).
    exit_side_binds: u64 = 0,
    /// Of those, the ones bound by CHAINING into a continuation that already
    /// lived at `P` (e.g. a loop-done continuation serving an exit arrival
    /// too) — no recording spent.
    exit_side_chain_binds: u64 = 0,
    /// Recordings armed at `P` for a wanted exit.
    exit_side_records: u64 = 0,
    /// Doc 56 Phase 4: of `exit_side_hops`, the ones a native exit adapter
    /// materialized.
    exit_side_native_hops: u64 = 0,
    /// Doc 56 Phase 5: armed exit-side hops replayed from a ledger (the
    /// adapter jumped straight into the child).
    exit_side_fused: u64 = 0,
    /// Doc 56 Phase 5: armed exit-side hops that force-yielded instead (the
    /// adapter found the ledger full and went back to the runtime). The
    /// rest of `exit_side_native_hops` minus `exit_side_fused` returned
    /// unarmed.
    exit_side_yields: u64 = 0,
    /// Doc 56 Phase 5: `.exit_side` arm requests the registry accepted
    /// (identical re-arms included) / arms disarmed after a child prologue
    /// failure.
    exit_side_arms: u64 = 0,
    exit_side_disarms: u64 = 0,
    /// Doc 56 §4.8.3 R2: exit-side chain candidates at `P` that refused
    /// their entry or deopted before any effect, after which the walk tried
    /// the next continuation there.
    exit_side_retries: u64 = 0,
    /// Doc 56 §4.8.3 R4: attached exits that gave up after `tryside`
    /// consecutive chains at `P` that did not link (also counted in
    /// `exit_side_giveups`).
    exit_side_miss_giveups: u64 = 0,
    /// Doc 64 §10 step 2: attached-exit chains that ended at the exit of a
    /// loop enclosing the resume pc (neither a link nor a miss).
    exit_side_natural_stops: u64 = 0,
    /// Doc 64 §10 step 2 (2d): given-up exits returned to `.none` because a
    /// trace committed at their resume pc.
    exit_side_revivals: u64 = 0,
    /// Doc 64 §10 step 3: routed exit-side firings served by the loop root
    /// behind the `.loop` marker at their resume pc (`exitSideRootServes`).
    exit_side_root_routes: u64 = 0,
    /// Doc 64 §10 step 3: exit-side arms released from a continuation at
    /// `P` because a loop root committed behind the marker there.
    exit_side_root_retargets: u64 = 0,
    /// Doc 64 §10 step 2 (2d): every given-up exit that a later commit could
    /// serve, keyed by its resume point. `reviveExitSideAt` consumes the
    /// entries at a commit's anchor (and drops entries whose trace is gone),
    /// so each give-up is revived at most once per commit at its `P`. A flat
    /// list: commits are rare and the list holds at most one entry per
    /// given-up exit of a live trace.
    exit_side_waiting: std.ArrayListUnmanaged(ExitSideWaiter) = .empty,
    /// Doc 56 §4.8.2 item 10 (P6-Q3): native calls from a burst origin
    /// (`exit_side_ok = 0`) that ended on an ordinary deopt at an exit whose
    /// adapter is published and whose ordinary cell is unarmed — exits the
    /// direct entry would have sent to the adapter. Measures what widening
    /// `exit_side_ok` to bursts would reach.
    exit_side_burst_skips: u64 = 0,
    /// Doc 56 Phase 4: native exit adapters built.
    exit_adapter_builds: u64 = 0,
    /// Doc 56 Phase 4: adapter builds refused, per `adapter.Refusal`.
    exit_adapter_refusals: [@typeInfo(nativegen.adapter.Refusal).@"enum".field_names.len]u64 = @splat(0),
    /// Doc 45 D5 diagnostic: tier-1a `.precise_error` exits consumed — a
    /// PRECISE trace's effect shim (`tnew`) raised a runtime error, the
    /// executor restored the failing op's snapshot, and the dispatcher
    /// parked the mapped error at the snapshot's pc (no receipt, no strike,
    /// no retry). The OOM identity test asserts on this witness — output/
    /// heap equality alone cannot prove the raise took the precise path.
    /// No tiering path reads it.
    precise_errors: u64 = 0,
    /// Doc 44 D11 diagnostic: successful native self-call frame pushes (the
    /// inline push sequence). Output equality alone cannot prove a
    /// descent actually pushed (the plain-terminal turnstile is
    /// output-equivalent, just slower) — the formation test asserts on this
    /// witness. No tiering path reads it.
    self_call_pushes: u64 = 0,
    /// Doc 44 D12c / doc 54 P1: count of committed native frame pops (the
    /// inline pop sequence's witness increment) — symmetric to
    /// `self_call_pushes`. No tiering path reads it.
    self_ret_pops: u64 = 0,
    ret_cont_link_arms: u64 = 0,
    ret_cont_link_hits: u64 = 0,
    call_head_link_arms: u64 = 0,
    call_head_link_hits: u64 = 0,
    /// Doc 54 P2 amendment: rowless armed sibling-handoff follows drained
    /// from the touched-slot records (one-shot→one-shot non-frame hops
    /// taken without a ledger row). Diagnostic witness only.
    sibling_link_hits: u64 = 0,
    /// Observation-only witness: full ledgers returning from frame-motion chains.
    frame_link_cap_yields: u64 = 0,
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
    /// Doc 40 phase 0 (doc 58 B2 review): dispatcher exits of a PEELED trace
    /// from its steady region with ZERO local completions — the run-once
    /// iteration ran but no back-edge committed, so the coarse deopt must
    /// replay from the entry state. Witness only: `> 0` is the "that exit was
    /// actually taken" signal its regression test needs (the output alone
    /// cannot tell it from a run-once-region exit).
    peeled_steady_zero_exits: u64 = 0,
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
    silent_promotion_candidates: u64 = 0,
    /// Promotions that reused a parked proof (codex C′) instead of re-earning
    /// the `promote_after` observation streak — the "activation churn skipped"
    /// counter for repeated activations of the same fallback region.
    silent_parked_reuses: u64 = 0,
    silent_rejects: PromotionRejects = .{},

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
    /// Doc 56 G6 follow-up: full ledgers whose last row is a `.yielded` deopt
    /// at a bridge-candidate exit — an armed bridge suppressed by the ledger
    /// cap (nativegen's `bridge_full`), reported the way every other arm kind
    /// reports its cap. Stays 0 if the cap falls back to a plain deopt.
    native_region_bridge_cap_yields: u64 = 0,
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
    /// execution to *this hop's own anchor* (`t.code.anchor`). This is what makes per-anchor
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
    coverage: AnchorMap(AnchorCoverage) = .empty,
    /// The in-progress recording (at most one at a time).
    rec: RecordingSession = .{},
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
    /// `trace_exec.LEDGER_CAP`, the native append's own bound, so a full span always
    /// fits. Not a GC root (holds decoded scalars, no `Value`s).
    ledger_scratch: [trace_exec.LEDGER_CAP]trace_exec.LedgerEntry = undefined,
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
    dbg_burst_len_hist: [trace_exec.LEDGER_CAP + 1]u64 = @splat(0),
    dbg_burst_terminals: std.AutoHashMapUnmanaged(DbgTerminalKey, u64) = .empty,
    /// B-3c telemetry: composition of silent-burst SUFFIX ledgers — every
    /// materialized row a burst still produced despite live promotion, keyed
    /// like the terminals. These rows are what end bursts (ledger-full) and
    /// what the suffix replay walks, so they are the remaining seam feedstock:
    /// any hot key here is a candidate for a further promoted set.
    dbg_silent_suffix_rows: std.AutoHashMapUnmanaged(DbgTerminalKey, u64) = .empty,
    /// B-3a seam gate input: every replay row is partitioned by whether its physical
    /// armed edge belongs to any bridge-free closed directed subcycle.
    dbg_promotable_cycle_rows: u64 = 0,
    dbg_other_replay_rows: u64 = 0,
    /// When non-null, the next back-edge to this anchor will arm a side-trace
    /// recording (even if a trace already exists there).  Set by
    /// `countGuardFailure` when a guard-failure crosses `hotguard`; cleared
    /// by `onBackEdge` when the side trace is armed.
    /// **Doc 44 D8 (P1a).** When non-null, a HEAD trace's guard exit went hot
    /// (`noteTakenExit`'s head route): the anchor wants a path SIBLING — a new
    /// `.head` recording at the same function-entry anchor capturing the path
    /// the existing traces keep failing on. Unlike `wants_side_trace` this
    /// never unpatches (a head has no virgin back-edge walk; the pc-0 patch is
    /// the sole entry for every sibling); it is consumed on the CURRENT
    /// activation by `enterPatchedTrace` after the whole sibling walk declines
    /// (transfer into `pending_call_anchor`, review round 2's reframe).
    wants_head_sibling: ?AnchorKey = null,
    /// Provenance of `wants_head_sibling` (mirrors `side_want_src`): the
    /// `(trace, exit)` whose hot counter raised it — DONE-latched when a
    /// sibling completes terminally, else a saturated exit re-raises the want
    /// forever and records duplicate shapes. Cleared wherever the want drops,
    /// so `head_want_src != null ⇒ wants_head_sibling != null`.
    head_want_src: ?ExitKey = null,
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
    /// **Continuation recording request.** When non-null, a *continuation*
    /// recording is pending at this (non-header) anchor, a bytecode pc where
    /// tier-0 holds a coherent slab. `maybeStartContinuation` consumes it in
    /// the dispatch prologue the moment `cur_pc` reaches the anchor. It is not
    /// a back-edge target, so it cannot arm in `onBackEdge`. Two producers
    /// (doc 56 R5-F3):
    ///   * **loop-done** (doc 15, doc 38): `maybeArmContinuation` on a hot
    ///     inner loop-done exit, at the post-loop pc. Tier-0 replays the final
    ///     inner iteration from the inner anchor first, so the continuation
    ///     records the **outer** body forward, not a stray inner iteration.
    ///   * **exit-side** (doc 56 Phase 3): `maybeArmExitSide` on a wanted
    ///     attachable exit, at its resume pc `P`. The executor already
    ///     materialized there and tier-0 resumes AT `P`, so `P`'s instruction
    ///     is the first one recorded. `pending_exit_src` names the exit.
    /// Both set `pending_anchor_base` to the resuming frame's slab base. The
    /// recording closes with a `.link`: into an inner loop's root
    /// (`LinkKind.inner_root`), or at the back-edge of the loop containing
    /// its anchor (`LinkKind.enclosing_iteration`).
    pending_exit_anchor: ?AnchorKey = null,
    /// Doc 56 Phase 3: the wanted exit `(parent, exit)` an exit-side
    /// `pending_exit_anchor` was armed for; null for a loop-done request.
    /// Transferred to `Recorder.side_src` by `maybeStartContinuation` (so
    /// the commit can bind the exit) and cleared with `pending_exit_anchor`.
    pending_exit_src: ?ExitKey = null,
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
    /// `pending_exit_anchor` (a raw `.continuation` pc: a post-inner-loop pc, or
    /// a doc 56 exit-side resume pc), this anchor is the
    /// failed trace's OWN coherent anchor — the registers are already coherent there
    /// on the productive exit, so tier-0 re-enters at the anchor and
    /// `maybeStartReplaySide` starts the `.side` recording the instant `cur_pc`
    /// reaches it, capturing the prime branch of that same iteration. Cleared by
    /// `maybeStartReplaySide` (consumed) or `clearPendingExitAnchor` (frame unwind).
    pending_replay_anchor: ?AnchorKey = null,
    /// **Doc 44 P0.** When non-null, a Lua function head went hot in `opCall`
    /// (`onCallEntry`) and a `.head` recording should arm the moment the
    /// dispatch prologue reaches the callee's pc 0 — the `.full`-pinned
    /// prologue-activation discipline of the two pendings above. `call_seq`
    /// pins the exact activation (stamped by `pushFrame`), so a pending left
    /// behind by an error/unwind can never attach to a later frame: the
    /// consumer clears the pending on the FIRST prologue it sees, match or
    /// mismatch (self-cleaning; no unwind hook needed).
    pending_call_anchor: ?PendingCallAnchor = null,
    /// **Doc 44 D12b.** When non-null, a post-call resume pc went hot in
    /// `opRet` (`onRetResume`) and a `.cont` recording should arm the moment
    /// the dispatch prologue reaches the caller's frozen cursor — the same
    /// `.full`-pinned prologue-activation discipline and `call_seq` pinning
    /// as `pending_call_anchor` above, with the same self-cleaning consumer
    /// (`maybeStartCont` clears on the FIRST prologue, match or mismatch).
    pending_ret_anchor: ?PendingRetAnchor = null,
    /// **Doc 60 §5.4 — the packed fast-path word.** One bit per condition that
    /// keeps tier-0 out of `.fast` dispatch (`FastBit`); zero means fast
    /// dispatch is allowed, so `Vm.runFastPath` and the host-call entry test
    /// one `u16` instead of ten scattered fields. Seven bits mirror state this
    /// struct owns (`isRecording()` + the six pending fields above) and are
    /// written only by the `setPending*` setters and `syncRecordingBit`; the
    /// three VM bits are written by `Vm`'s setters and survive `clearCache`.
    /// Always updated as a whole-word read-modify-write: a byte store followed
    /// by this 16-bit load would not store-forward (doc 59). Debug builds check
    /// it bit-for-bit against `Vm.fastBlockReference()`.
    fast_block: u16 = 0,
    /// Per-trace execution logs for the visualizer (`execlog.zig`), populated only
    /// when `config.record_exec_log`. Keyed by the stable `Trace.id` (doc 61 §7.1
    /// item 7; never the cache index, which retirement compacts); a retired
    /// trace's log is dropped with it. Empty and untouched on the normal JIT path.
    exec_logs: std.ArrayListUnmanaged(execlog.TraceExecLog) = .empty,
    /// The recorder driving `exec_logs`, lazily created on first use so the off path
    /// allocates nothing. Reused (per-entry scratch retained) across every entry.
    exec_recorder: ?execlog.ExecLogRecorder = null,
    /// Aborted-recording diagnostic log, populated only when `config.record_aborts`
    /// (the `--dump-aborts` CLI flag). Deduped by `(anchor, reason, op)`; see
    /// `AbortRecord` and `logAbort`. Empty and untouched on the normal path.
    abort_log: std.ArrayListUnmanaged(AbortRecord) = .empty,
    /// Doc 61 §7.1: traces retired through `removeTraces`, and the number of
    /// non-empty batches (each pays exactly one graph rebuild). Structural
    /// counts for tests; never steer anything.
    retired_traces: u64 = 0,
    retire_batches: u64 = 0,
    /// Full `rebuildRegions` runs (commit, retirement, deferred request).
    region_rebuilds: u64 = 0,
    /// Side traces that committed after their source parent retired (doc 61
    /// §7.1 item 4): no provenance edge is recorded for them.
    side_commits_orphaned: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) TraceState {
        return .{ .gpa = gpa, .registry = @import("trace_registry.zig").TraceRegistry.init(gpa) };
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
    pub fn hasArmedFrameLink(self: *const TraceState, parent: *const Trace, key: u32, child: *const Trace, kind: ArmKind) bool {
        for (self.registry.native_physical.armedLinks()) |l| {
            if (l.kind == kind and l.parent == parent and l.slot_index == key and l.child == child) return true;
        }
        return false;
    }

    pub fn hasArmedSiblingHandoff(self: *const TraceState, parent: *const Trace, exit_instr: u32, child: *const Trace) bool {
        // Fast reject: `sibling_arms` counts this parent's armed handoffs and is
        // maintained by every arm/disarm path, so `== 0` is an exact necessary
        // condition for the scan below to find anything. This runs once per non-final
        // `.deopt` row in the hot replay walk; the registry scan must not.
        if (parent.sibling_arms == 0) return false;
        for (self.registry.native_physical.armedLinks()) |l| {
            if (l.kind == .sibling_handoff and l.parent == parent and
                l.slot_index == exit_instr and l.child == child) return true;
        }
        return false;
    }

    /// Doc 56 Phase 5: does an armed `.exit_side` link send exit
    /// `exit_instr` of `parent` into `child`? Validates a non-last
    /// `.exit_side` ledger row by armed-edge provenance, the way
    /// `hasArmedSiblingHandoff` validates a handoff row.
    ///
    /// O(1) on the hot replay path (one call per fused hop): the exit-side
    /// cell has a single writer, the registry's `commitSlotMutation`, which
    /// writes a child's `ordinary_entry` there only for a registered
    /// `.exit_side` link — so the cell holding `child`'s entry IS the proof.
    /// Debug builds cross-check the registry.
    pub fn hasArmedExitSide(self: *const TraceState, parent: *const Trace, exit_instr: u32, child: *const Trace) bool {
        const pc = switch (parent.native) {
            .compiled => |*c| c,
            else => return false,
        };
        const cc = switch (child.native) {
            .compiled => |*c| c,
            else => return false,
        };
        const cell = pc.exitSideSlot(exit_instr) orelse return false;
        const entry = cc.ordinary_entry orelse return false;
        const armed = pc.slots[cell] == entry;
        if (comptime std.debug.runtime_safety) {
            var registered = false;
            for (self.registry.native_physical.armedLinks()) |l| {
                if (l.kind == .exit_side and l.parent == parent and
                    l.slot_index == exit_instr and l.child == child) registered = true;
            }
            std.debug.assert(armed == registered);
        }
        return armed;
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
    /// The ops are `trace_ir.isStateEffectOp`, shared with the bridge-candidate
    /// test (doc 56 §4.8.3 review 2: this list once named only four of
    /// `tropt.kindOf`'s `.astore` class and missed `ustore`, which the recorder
    /// emits INLINE when the trace has no heap load). `sgm_setpos` only enters
    /// the IR through the pending-store sink, below every guard, so it cannot
    /// precede an exit today, but the shared list names it anyway rather than
    /// resting on that sinking discipline. Guards (which side-exit but mutate
    /// nothing) and `int_of_float` are deliberately fine. The doc-24 allocating
    /// producers (`tostr_*`, snew, `scap_str`) also fall through: they only
    /// intern (grow the heap), never mutate guest-visible state, so re-running
    /// the iteration re-interns identically (D2 id-stream).
    // pub for trace_link.zig (file-split pass)
    pub fn exitIsPreEffect(t: *const Trace, exit_instr: u32) bool {
        const n = @min(@as(usize, exit_instr), t.code.instrs.len);
        for (t.code.instrs[0..n]) |ins| if (trace_ir.isStateEffectOp(ins.op)) return false;
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
        if (exit_instr >= c.slots.len or exit_instr >= t.code.instrs.len) return false;
        // Already armed here: the slot is taken, so counting it again could only
        // produce a redundant arm. Consulted on the watch-MOVE path only, never
        // per receipt, so the registry scan stays off the hot path.
        if (t.sibling_arms != 0) {
            for (self.registry.native_physical.armedLinks()) |l| {
                if (l.kind == .sibling_handoff and l.parent == t and l.slot_index == exit_instr)
                    return false;
            }
        }
        // Loop-done slots belong to `.loop_done_linked` (P-C option (b)), and the
        // ordinary loop-done deopt bypasses `slot[ei]` entirely in emission.
        if (isLoopDoneGuardIndex(t, exit_instr)) return false;
        // Bridge candidates run the A-v bridge stub body, not the plain path.
        if (t.code.isBridgeCandidate(exit_instr)) return false;
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
        if (!self.isSourceBranchGuardExit(t, exit_instr)) return false;
        if (t.code.anchorCondBranch(exit_instr) == null) return false;
        // Doc 44 D10 (round 4) / D12b: one-shot parents (head + cont) demand
        // the POSITIVE provenance proof, not just the source-opcode shape
        // above: a real guard stamped `.branch_cond`. (`anchorSourcePc`
        // already refused an inlined callee's guard, for every anchor kind.)
        if (anchorKind(t.code.anchor.pc) != .loop) {
            const prov = t.code.provAt(exit_instr) orelse return false;
            switch (prov) {
                .guard => |gp| if (gp.role != .branch_cond) return false,
                .link_terminal => return false,
            }
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
    pub fn noteRetContTransition(self: *TraceState, owner: *Trace, resume_pc: u32) void {
        var free: ?usize = null;
        for (&owner.ret_cont_watch_pcs, 0..) |*pc, i| {
            if (pc.* == resume_pc) {
                owner.ret_cont_watch_counts[i] +|= 1;
                if (owner.ret_cont_watch_counts[i] >= self.config.hotguard) {
                    owner.ret_cont_watch_counts[i] = 0;
                    self.fileRetContArm(owner, resume_pc);
                }
                return;
            }
            if (free == null and pc.* == std.math.maxInt(u32)) free = i;
        }
        // K distinct PCs are retained for the page lifetime. A fifth is a
        // deterministic plain miss: no eviction and no displaced evidence.
        const i = free orelse {
            self.dbg("ret-cont watch capacity: owner={d} resume={d} cap={d}", .{ owner.id, resume_pc, nativegen.RET_CONT_SLOTS });
            return;
        };
        owner.ret_cont_watch_pcs[i] = resume_pc;
        owner.ret_cont_watch_counts[i] = 1;
        if (self.config.hotguard == 1)
            self.fileRetContArm(owner, resume_pc);
    }

    /// B1' (task 27): install-or-displace the single pending ret-cont arm
    /// request. Per-owner-per-pc watches accumulate INDEPENDENTLY of the slot
    /// (no early return above), so an owner that re-crosses `hotguard` while
    /// a stale request under a DIFFERENT key occupies the slot displaces it —
    /// one unsatisfiable request can no longer starve the system. Same-key
    /// re-crossings are no-ops (the request is already filed).
    fn fileRetContArm(self: *TraceState, owner: *Trace, resume_pc: u32) void {
        const req: ExitKey = .{ .trace_id = owner.id, .exit_instr = resume_pc };
        if (self.pending_ret_cont_arm) |cur| {
            if (cur.trace_id != req.trace_id or cur.exit_instr != req.exit_instr) {
                self.setPendingRetContArm(req);
                self.dbg("ret-cont arm request DISPLACED: old t={d} ei={d} -> parent t={d} resume={d}", .{ cur.trace_id, cur.exit_instr, owner.id, resume_pc });
            }
        } else {
            self.setPendingRetContArm(req);
            self.dbg("ret-cont arm request: parent t={d} resume={d}", .{ owner.id, resume_pc });
        }
    }

    pub fn tryArmFrameLinks(self: *TraceState, child: *Trace, safe_to_arm: bool) void {
        if (!safe_to_arm) return;
        if (self.pending_ret_cont_arm) |key| {
            if (self.traceById(key.trace_id)) |parent| {
                if (child.code.anchor.proto == parent.code.anchor.proto and
                    child.code.anchor.pc == contAnchorPc(key.exit_instr))
                {
                    self.setPendingRetContArm(null);
                    if (self.armNativeLink(parent, key.exit_instr, child, .ret_cont) catch false)
                        self.ret_cont_link_arms +|= 1;
                }
            } else self.setPendingRetContArm(null);
        }
        if (self.pending_call_head_arm) |key| {
            if (self.traceById(key.trace_id)) |parent| {
                if (child.code.anchor.proto == parent.code.anchor.proto and anchorKind(child.code.anchor.pc) == .head) {
                    self.setPendingCallHeadArm(null);
                    if (self.armNativeLink(parent, key.exit_instr, child, .call_head) catch false) {
                        self.call_head_link_arms +|= 1;
                    } else self.dbg("call-head arm FAILED: parent t={d} exit={d} child t={d}", .{ parent.id, key.exit_instr, child.id });
                }
            } else self.setPendingCallHeadArm(null);
        }
    }

    pub fn tryArmSiblingHandoff(self: *TraceState, child: *Trace, safe_to_arm: bool) void {
        const key = self.pending_sibling_arm orelse return;
        if (!safe_to_arm) return; // keep pending; observation window owns the slot
        const parent = self.traceById(key.trace_id) orelse {
            self.pending_sibling_arm = null; // parent retired: request is stale
            return;
        };
        if (parent == child) return; // not a sibling handoff; wait for a real sibling
        if (child.code.anchor.proto != parent.code.anchor.proto or child.code.anchor.pc != parent.code.anchor.pc)
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
            parent.id, exit_instr, @tagName(parent.code.instrs[exit_instr].op), child.id,
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
    pub fn dbgNoteBurst(self: *TraceState, entries: []const trace_exec.LedgerEntry) void {
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
    pub fn dbgNoteSuffixLedger(self: *TraceState, entries: []const trace_exec.LedgerEntry) void {
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
        for (self.registry.native_physical.armedLinks()) |link| {
            // Doc 56 Phase 5: an `.exit_side` arm shares its logical slot
            // with the exit's ordinary cell but is not a promotable edge yet
            // (Phase 6), so it must not answer for a sibling arm here.
            if (link.parent == parent and link.slot_index == exit_instr and
                link.kind != .region_bridge and link.kind != .exit_side)
            {
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
            for (self.registry.native_physical.armedLinks()) |link| {
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
                self.dbg_promotable_cycle_rows +|= 1
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
            const replay_total = self.dbg_promotable_cycle_rows +| self.dbg_other_replay_rows;
            jitdbg.log("  B-3 seam rows: bridge-free-closed={d} rest={d} total={d}", .{
                self.dbg_promotable_cycle_rows, self.dbg_other_replay_rows, replay_total,
            });
            jitdbg.log("  silent: candidates={d} promotions={d} parked-reuses={d} demotions={d} bursts={d} transitions={d} hops={d} budget={d} barren={d} suffix={d}", .{
                self.silent_promotion_candidates,               self.registry.native_physical.silent_promotions,
                self.silent_parked_reuses,
                self.registry.native_physical.silent_demotions, self.silent_bursts_drained,
                self.silent_transitions_total,                  self.silent_hops_total,
                self.silent_budget_exhaustions,                 self.silent_barren_exhaustions,
                self.silent_suffix_drains,
            });
            jitdbg.log("  region maps: profit count={d} cap={d} source={d} dest={d} arrival={d} defs={d}", .{
                self.region_policy.region_profit.count(),
                self.region_policy.region_profit.capacity(),
                self.region_policy.source_exit_regions.count(),
                self.region_policy.dest_entry_regions.count(),
                self.region_policy.arrival_entry_regions.count(),
                self.region_policy.region_defs.count(),
            });
            jitdbg.log("  silent rejects: bridge={d} region={d} open={d} child-mismatch={d} no-silent-site={d} cap={d} region-owned={d} rid-owned={d} resident-occupied={d}", .{
                self.silent_rejects.bridge_member,
                self.silent_rejects.region_mismatch,
                self.silent_rejects.open_chain,
                self.silent_rejects.child_mismatch,
                self.silent_rejects.no_silent_site,
                self.silent_rejects.cap,
                self.silent_rejects.region_owned,
                self.silent_rejects.region_id_owned,
                self.silent_rejects.resident_occupied,
            });
            jitdbg.log("  silent demotions: activation={d} region-close={d} slot={d} trace={d} teardown={d} unfreeze={d} growth={d}", .{
                self.registry.native_physical.silent_demotion_reasons.activation,
                self.registry.native_physical.silent_demotion_reasons.region_close,
                self.registry.native_physical.silent_demotion_reasons.slot_mutation,
                self.registry.native_physical.silent_demotion_reasons.trace_invalidation,
                self.registry.native_physical.silent_demotion_reasons.teardown,
                self.registry.native_physical.silent_demotion_reasons.unfreeze,
                self.registry.native_physical.silent_demotion_reasons.membership_growth,
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
                self.registry.cache.items.len, self.registry.native_physical.armedLinks().len,
            });
            for (self.registry.cache.items, 0..) |t, i| {
                const term: IrOp = if (t.code.instrs.len != 0) t.code.instrs[t.code.instrs.len - 1].op else .loop;
                jitdbg.log("  [{d}] id={d} anchor pc={d} instrs={d} inputs={d} term={s} native={s} hits={d}", .{
                    i,                  t.id,              t.code.anchor.pc,
                    t.code.instrs.len,  t.code.inputs.len, @tagName(term),
                    @tagName(t.native), t.hit_count,
                });
            }
        }
    }

    pub fn syncNativeInvalidation(self: *TraceState) void {
        if (self.registry.native_physical.takeInvalidation()) self.provenance_arms_pending = true;
        // Doc 52 P1: a demoted resident set's recurrence proof must be
        // re-earned against the post-demotion world — any demotion reason.
        // The registry (which owns every demotion funnel, including deferred
        // ones applied in drainBarrier) records the notice; this drain zeroes
        // the named def's streak AND signature. A notice for a def that no
        // longer exists is dropped.
        if (self.registry.native_physical.takeResidentDemotionNotice()) |rid| {
            if (self.region_policy.region_defs.getPtr(rid)) |d| {
                d.recurrence_streak = 0;
                d.recurrence_len = 0;
            }
        }
    }

    pub fn deinit(self: *TraceState) void {
        self.dbgDumpBurstStats(); // jitdbg-only burst-terminal telemetry (Part B)

        self.dbg_burst_terminals.deinit(self.gpa);
        self.dbg_silent_suffix_rows.deinit(self.gpa);
        self.counters.deinit(self.gpa);
        self.gate.deinit(self.gpa);
        self.record_gate.deinit(self.gpa);
        self.lleave_count.deinit(self.gpa);
        self.unroll_fail.deinit(self.gpa);
        self.upvalue_mutable_memo.deinit(self.gpa);
        self.precise_anchor_memo.deinit(self.gpa);
        self.penalty.deinit(self.gpa);
        self.guard_failures.deinit(self.gpa);
        for (self.values_chunks.items) |c| self.gpa.free(c);
        self.values_chunks.deinit(self.gpa);
        for (self.exec_logs.items) |*l| l.deinit(self.gpa);
        self.exec_logs.deinit(self.gpa);
        self.abort_log.deinit(self.gpa);
        if (self.exec_recorder) |*r| r.deinit();
        self.provenance_edges.deinit(self.gpa);
        self.exit_side_waiting.deinit(self.gpa);

        self.coverage.deinit(self.gpa);
        self.region_policy.deinit(self.gpa);
        // Doc 20 §R2-2: VM teardown is the other legal image-free point.

        self.registry.native_physical.debug_log = self.config.debug_log;
        self.registry.deinit();
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
        const gop = self.coverage.getOrPut(self.gpa, .{ .proto = proto, .pc = pc, .proto_id = proto.id }) catch {
            self.iters_tier0_uncovered +|= 1;
            self.cycles_tier0_uncovered +|= cycles;
            return;
        };
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.interp +|= 1;
        gop.value_ptr.interp_cycles +|= cycles;
        if (gop.value_ptr.has_trace) {
            gop.value_ptr.fallback +|= 1;
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
    /// trace's stable `Trace.id`), creating the recorder (lazily) and the per-trace log on
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
        var it = self.registry.tracesAt(.{ .proto = proto, .pc = pc, .proto_id = proto.id });
        while (it.next()) |t| {
            // Doc 33 §3(b): consec_refusals is tracked but does NOT suppress
            // selection. Suppression deadlocks: a skipped trace can never be
            // entered, so the counter can never reset. The refusal is already
            // free (no anchor penalty), so the cost of a futile prologue
            // attempt is one native call + ledger row per dispatch — bounded
            // by the caller's own iteration count, not by the counter.
            if (best == null or t.hit_count > best_hits) {
                best = t;
                best_hits = t.hit_count;
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
        return t.code.anchor.proto == proto and t.code.anchor.pc == pc and
            t.code.instrs.len != 0 and t.code.instrs[t.code.instrs.len - 1].op == .loop;
    }

    pub fn findLoopTrace(self: *const TraceState, proto: *const Proto, pc: u32) ?*Trace {
        var best: ?*Trace = null;
        var best_hits: u64 = 0;
        var it = self.registry.tracesAt(.{ .proto = proto, .pc = pc, .proto_id = proto.id });
        while (it.next()) |t| {
            // Doc 33 §3(b): consec_refusals is tracked but does NOT suppress
            // selection. Suppression deadlocks: a skipped trace can never be
            // entered, so the counter can never reset. The refusal is already
            // free (no anchor penalty), so the cost of a futile prologue
            // attempt is one native call + ledger row per dispatch — bounded
            // by the caller's own iteration count, not by the counter.
            if (t.code.instrs.len == 0 or t.code.instrs[t.code.instrs.len - 1].op != .loop) continue;
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
        var it = self.registry.tracesAt(.{ .proto = proto, .pc = pc, .proto_id = proto.id });
        while (it.next()) |t| {
            // Doc 33 §3(b): consec_refusals is tracked but does NOT suppress
            // selection. Suppression deadlocks: a skipped trace can never be
            // entered, so the counter can never reset. The refusal is already
            // free (no anchor penalty), so the cost of a futile prologue
            // attempt is one native call + ledger row per dispatch — bounded
            // by the caller's own iteration count, not by the counter.
            if (t.code.instrs.len == 0 or t.code.instrs[t.code.instrs.len - 1].op != .link) continue;
            // Doc 45 D6 (P2): no links INTO a precise page. Structurally
            // unreachable — the recorder refuses link closes on precise
            // candidates, so no precise trace is `.link`-tailed — but the
            // doc requires the predicate at BOTH arm and dispatch.
            if (t.code.deopt_mode == .precise) continue;
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
        var it = self.registry.tracesAt(.{ .proto = proto, .pc = post_pc, .proto_id = proto.id });
        while (it.next()) |t| {
            // Doc 33 §3(b): consec_refusals is tracked but does NOT suppress
            // selection. Suppression deadlocks: a skipped trace can never be
            // entered, so the counter can never reset. The refusal is already
            // free (no anchor penalty), so the cost of a futile prologue
            // attempt is one native call + ledger row per dispatch — bounded
            // by the caller's own iteration count, not by the counter.
            if (t.code.instrs.len == 0 or t.code.instrs[t.code.instrs.len - 1].op != .link) continue;
            // Doc 45 D6 (P2): no links INTO a precise page (see findLinkTrace).
            if (t.code.deopt_mode == .precise) continue;
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
                if (t.code.matchesFingerprint(r)) {
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
        var it = self.registry.tracesAt(.{ .proto = proto, .pc = pc, .proto_id = proto.id });
        outer: while (it.next()) |t| {
            // Doc 33 §3(b): consec_refusals is tracked but does NOT suppress
            // selection. Suppression deadlocks: a skipped trace can never be
            // entered, so the counter can never reset. The refusal is already
            // free (no anchor penalty), so the cost of a futile prologue
            // attempt is one native call + ledger row per dispatch — bounded
            // by the caller's own iteration count, not by the counter.
            for (visited) |v| {
                if (v == t) continue :outer;
            }
            // Ties go to the lowest id, like `resolveLoopDoneCont` (doc 56
            // §4.8.3 review 5), so a chain's first candidate at a pc is the
            // canonical pick there whatever the cache order.
            if (best == null or t.hit_count > best_hits or (t.hit_count == best_hits and t.id < best.?.id)) {
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

    /// Resolve a stable `Trace.id` (P-B, doc 17 — baked into native exit code as
    /// `final_trace_id`; the exec-log key) to its live `*Trace`, or null if no
    /// cached trace carries it (the trace retired, or the id is the
    /// `NO_TRACE_ID` sentinel).
    pub fn traceById(self: *const TraceState, id: u32) ?*Trace {
        return self.registry.traceById(id);
    }

    /// Serialize the trace cache (cache order) to a versioned trace file, each
    /// trace paired with its stable id (wire v5). Owned by `gpa`. The
    /// serializer sees only `{id, code}` — never the lifecycle record.
    pub fn encodeTraceFile(self: *const TraceState, gpa: std.mem.Allocator) ![]u8 {
        const cache = self.registry.cache.items;
        const wire = try gpa.alloc(traceser.WireTrace, cache.len);
        defer gpa.free(wire);
        for (cache, wire) |t, *w| w.* = .{ .id = t.id, .code = &t.code };
        return traceser.encodeFile(gpa, wire);
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
        if (self.qualifiedActiveMember(t.code.anchor.proto, t.code.anchor.pc)) |m| {
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
        const key: ?ExitKey = if (exit_instr < t.code.instrs.len)
            .{ .trace_id = t.id, .exit_instr = exit_instr }
        else
            null;
        // A-vii-c.1: region-first, then legacy iff unconsumed. The two verdicts can
        // only ever touch the same anchor when this receipt's own region closed and
        // flushed against an owner that happens to be `t.code.anchor`; applying the
        // receipt-local verdict last keeps the most recent evidence authoritative.
        //
        // Doc 44 D9 (S2): replicate `accountRegionProfit`'s first three
        // side-effect-free early-outs inline before paying its (large,
        // outlined) call frame — on region-free workloads this receipt runs
        // per completion (4M+/run on recursive-fib) and the call was 8-12% of
        // wall doing nothing. Behavior-identical: the callee returns false on
        // exactly these conditions with nothing mutated before them.
        const region_live = key != null and
            self.region_policy.regionContext() != null and
            !self.region_policy.receiptsInert();
        if (!(region_live and self.accountRegionProfit(key, region_work, dest))) {
            self.accountLegacyThrash(t, completed, exit_instr, charge_kind);
        } else {
            accountCandidateCharge(t, charge_kind);
        }
    }

    /// Remove `anchor`'s dispatch gate (doc 31 D2 clear-on-productive).
    // pub for trace_regionops.zig (file-split pass)
    pub fn clearDispatchGate(self: *TraceState, anchor: AnchorKey) void {
        // Single-hash form (getEntry + removeByPtr, not getPtr + remove):
        // this runs on every productive receipt, and the extra hash of the
        // two-op form was a measured ~2% of a scimark-lu run.
        const e = self.gate.getEntry(anchor) orelse return;
        self.gate.removeByPtr(e.key_ptr);
    }

    // Region-ops: accounting, bridges, provenance, observer cache — moved to trace_regionops.zig (file-split pass);
    // forwarding decls keep every `self.foo(...)` / `TraceState.Foo` spelling working.
    pub const accountLegacyThrash = trace_regionops_mod.accountLegacyThrash;
    pub const accountLedgerRow = trace_regionops_mod.accountLedgerRow;
    pub const accountCandidateCharge = trace_regionops_mod.accountCandidateCharge;
    pub const accountLedgerRowsBulk = trace_regionops_mod.accountLedgerRowsBulk;
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
    pub const traceInRegion = trace_regionops_mod.traceInRegion;
    pub const resolveRegionBridgeChild = trace_regionops_mod.resolveRegionBridgeChild;
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
    pub const stubEnterable = trace_chain_mod.stubEnterable;
    pub const liveEpisodeProto = trace_chain_mod.liveEpisodeProto;
    pub const stubEnterability = trace_chain_mod.stubEnterability;
    pub const driveChain = trace_chain_mod.driveChain;
    pub const driveSeedSilentResult = trace_chain_mod.driveSeedSilentResult;
    pub const silentCellOwner = trace_chain_mod.silentCellOwner;
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
    pub const maybeStartContinuation = trace_link_mod.maybeStartContinuation;
    pub const maybeStartReplaySide = trace_link_mod.maybeStartReplaySide;
    pub const clearPendingExitAnchor = trace_link_mod.clearPendingExitAnchor;
    pub const noteTakenExit = trace_link_mod.noteTakenExit;
    pub const ExitRoute = trace_link_mod.ExitRoute;
    pub const exitSideNative = trace_link_mod.exitSideNative;
    pub const bindExitSide = trace_link_mod.bindExitSide;
    pub const armExitSide = trace_link_mod.armExitSide;
    pub const ordinaryArmLive = trace_link_mod.ordinaryArmLive;
    pub const noteExitSideChain = trace_link_mod.noteExitSideChain;
    pub const exitSideChainOutcome = trace_link_mod.exitSideChainOutcome;
    pub const reviveExitSideAt = trace_link_mod.reviveExitSideAt;
    pub const exitSideTarget = trace_link_mod.exitSideTarget;
    pub const setExitSideEntry = trace_link_mod.setExitSideEntry;
    pub const exitSideRoot = trace_link_mod.exitSideRoot;
    pub const exitSideRootServes = trace_link_mod.exitSideRootServes;
    pub const drainPendingExitSideDisarm = trace_link_mod.drainPendingExitSideDisarm;
    pub const maybeArmExitSide = trace_link_mod.maybeArmExitSide;
    pub const noteExitSideCommit = trace_link_mod.noteExitSideCommit;
    pub const noteHeadSiblingCompletion = trace_link_mod.noteHeadSiblingCompletion;
    pub const countGuardFailure = trace_link_mod.countGuardFailure;
    pub const countFingerprintMiss = trace_link_mod.countFingerprintMiss;
    pub const isSourceBranchGuardExit = trace_link_mod.isSourceBranchGuardExit;
    pub const hasArmedSourceBranchLinkAt = trace_link_mod.hasArmedSourceBranchLinkAt;
    pub const countTracesAt = trace_link_mod.countTracesAt;
    pub const hasInnerRootAt = trace_link_mod.hasInnerRootAt;
    pub const SuccAnchor = trace_link_mod.SuccAnchor;
    pub const resolveSuccessorAnchor = trace_link_mod.resolveSuccessorAnchor;
    pub const resolveCompositeBridgeSuccessor = trace_link_mod.resolveCompositeBridgeSuccessor;

    // Edge-cache / region rebuilds — moved to trace_regionops.zig (file-split pass);
    // forwarding decls keep every `self.foo(...)` / `TraceState.Foo` spelling working.
    pub const rebuildEdgeCache = trace_regionops_mod.rebuildEdgeCache;
    pub const rebuildEdgeCacheFallible = trace_regionops_mod.rebuildEdgeCacheFallible;
    pub const clearPhysicalRegionIndices = trace_regionops_mod.clearPhysicalRegionIndices;
    pub const drainPendingRegionRebuild = trace_regionops_mod.drainPendingRegionRebuild;
    pub const minOpenRegion = trace_regionops_mod.minOpenRegion;
    pub const chargePayoffReceipt = trace_regionops_mod.chargePayoffReceipt;
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
    ///
    /// The monotonicity argument holds only for a **frozen** array part: `frozen`
    /// is the one-shot lane commitment (`commitFreshLane`), and only after it does
    /// "lanes never re-narrow" apply. A fresh, unfrozen `.value` array is
    /// lane-UNDECIDED — its first real store will commit it to a narrow lane, so a
    /// narrow `guard_lane` absolutely can pass on a later entry. Without this
    /// exclusion, any loop that fills a fresh table per outer iteration
    /// (`local r = {}; for j=1,n do r[j] = v end`) enters its fill trace once with
    /// the next iteration's still-unfrozen `{}`, gets widen-evicted, and re-records
    /// an identical trace EVERY outer iteration — a permanent mint-retire-recompile
    /// churn (~600 rounds on grid_matmul_f64's row fills, doc 47 increment D) that
    /// costs far more than the traces save.
    /// Doc 48: identity-pinned widen-eviction predicate. Lane monotonicity
    /// (a frozen array only widens) is a per-TABLE invariant, so eviction may
    /// only fire against the very table the recorder observed — matched by
    /// deterministic `GcHeader.id`, never an address. A DIFFERENT table at
    /// the guarded register (a polymorphic anchor, doc 33) proves nothing:
    /// evicting there churned spectral-norm's f64 sibling once per u-burst
    /// (8 commit→retire cycles, 364k tier-0 iterations). This stays a
    /// HEURISTIC, not a proof of permanent death — the trace is lane- not
    /// identity-specialized, so a same-lane sibling table could still have
    /// used it after the pinned table widened; the cost of that miss is one
    /// re-record, accepted (codex round-1). A trace with no pins is never
    /// evicted here (fail-safe: pins are best-effort metadata).
    pub fn laneWidenedPast(self: *const TraceState, t: *const Trace, regs: RegWindow) bool {
        _ = self;
        for (t.code.lane_pins) |pin| {
            const ins = t.code.instrs[pin.guard_ref];
            std.debug.assert(ins.op == .guard_lane);
            // `guard_lane.a` indexes the table-producing instr; that is a
            // `slot_load` whose `aux` is the tier-0 register the table lives in.
            const ld_idx: usize = @intCast(ins.a);
            if (ld_idx >= t.code.instrs.len) continue;
            const ld = t.code.instrs[ld_idx];
            if (ld.op != .slot_load) continue;
            const reg: usize = @intCast(ld.aux);
            if (reg >= regs.len()) continue;
            const v = regs.get(reg);
            if (!v.isHeap() or v.heapType() != .table) continue;
            const header = v.asHeap();
            if (header.id != pin.table_id) continue; // different table: no evidence
            const live_arr = &table_mod.Table.fromHeader(header).array;
            if (!live_arr.frozen) continue; // pre-commitment: no monotonicity, guard may pass later
            const live_lane = live_arr.lane;
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
    pub const silentSiteAt = trace_link_mod.silentSiteAt;
    pub const validateRegionBridgeReceipt = trace_link_mod.validateRegionBridgeReceipt;
    pub const promotedEdgeFromLink = trace_link_mod.promotedEdgeFromLink;
    pub const rejectPromotion = trace_link_mod.rejectPromotion;
    pub const edgeMemberOfRegion = trace_link_mod.edgeMemberOfRegion;
    pub const promotionBelongsToRegion = trace_link_mod.promotionBelongsToRegion;
    pub const detectPromotableSet = trace_link_mod.detectPromotableSet;
    pub const detectPromotableSetMembers = trace_link_mod.detectPromotableSetMembers;
    pub const resetRecurrenceStreaks = trace_link_mod.resetRecurrenceStreaks;
    pub const promoteSet = trace_link_mod.promoteSet;
    pub const promoteResidentSet = trace_link_mod.promoteResidentSet;
    pub const resetPromotionCandidate = trace_link_mod.resetPromotionCandidate;
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
    pub const disarmRegionLinks = trace_link_mod.disarmRegionLinks;
    pub const linkDependsOnRegion = trace_link_mod.linkDependsOnRegion;
    pub const clearSiblingLatch = trace_link_mod.clearSiblingLatch;
    pub const disarmLinkAt = trace_link_mod.disarmLinkAt;
    pub const disarmStaleRegionBridgeLinks = trace_link_mod.disarmStaleRegionBridgeLinks;
    pub const removeTrace = trace_link_mod.removeTrace;
    pub const removeTraces = trace_link_mod.removeTraces;
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

    /// Doc 63 §5.9: the JIT is suspended (see `suspend_depth`). Every gate
    /// tests this before any JIT decision or JIT-state mutation on its path.
    /// Suspension sets a `fast_block` bit, so a suspended VM never dispatches
    /// in `.fast`: the dispatch handlers' gates fold to false there
    /// (`Vm.jitSuspended`) and cost the hot path nothing.
    pub inline fn suspended(self: *const TraceState) bool {
        return self.suspend_depth != 0;
    }

    /// Doc 63 §5.9: suspend the JIT for the guest code a host call runs. Pair
    /// with `lowerSuspend` around the call.
    pub inline fn raiseSuspend(self: *TraceState) void {
        self.suspend_depth += 1;
        self.setFastBit(FastBit.jit_suspended, true);
    }

    pub inline fn lowerSuspend(self: *TraceState) void {
        std.debug.assert(self.suspend_depth != 0);
        self.suspend_depth -= 1;
        self.setFastBit(FastBit.jit_suspended, self.suspend_depth != 0);
    }

    /// Bit assignment of `fast_block` (doc 60 §5.4).
    pub const FastBit = struct {
        pub const recording: u16 = 1 << 0;
        pub const exit_anchor: u16 = 1 << 1;
        pub const replay_anchor: u16 = 1 << 2;
        pub const call_anchor: u16 = 1 << 3;
        pub const ret_anchor: u16 = 1 << 4;
        pub const ret_cont_arm: u16 = 1 << 5;
        pub const call_head_arm: u16 = 1 << 6;
        /// Doc 63 §5.9: `suspend_depth != 0`. Holding `.full` while suspended
        /// is what lets every `.fast` handler drop its suspension check.
        pub const jit_suspended: u16 = 1 << 7;
        /// The eight bits `TraceState` owns (the rest are `Vm`'s), as
        /// `assertTraceBitsInSync` compares them against `traceFastBits()`.
        pub const trace_owned: u16 = (1 << 8) - 1;
        pub const vm_suspend: u16 = 1 << 8;
        pub const vm_safepoint_lines: u16 = 1 << 9;
        /// A published `Vm.final_cut`. Not a dispatch condition: nothing
        /// executes at depth 0 before the cut is retired. It sends the host
        /// call entry's first call after a run down H1, whose
        /// `pushHostCall` nils the dead final registers before the H3 entry
        /// would push over them (`Vm.retireFinalCut`).
        pub const vm_final_cut: u16 = 1 << 10;
    };

    /// Set or clear one `fast_block` bit as a whole-word read-modify-write.
    /// The store goes through a `volatile` pointer because a plain one is not
    /// enough: LLVM narrows `w & ~bit` / `w | bit` on memory to a byte-wide
    /// `andb`/`orb`, and the next entry's 16-bit load of the word then fails
    /// store-forwarding (measured on the host-call path, doc 60 H1: the
    /// per-call `clearPendingExitAnchor` byte store stalled the following
    /// call's `runFastPath`). A volatile store is emitted at its declared
    /// width; the load stays ordinary. An unchanged word is not stored at
    /// all: most writes are clears of an already-clear bit (every finished
    /// exec runs `clearPendingExitAnchor`), and skipping them keeps the next
    /// entry's load off a store-to-load dependency.
    pub inline fn setFastBit(self: *TraceState, bit: u16, on: bool) void {
        const w = self.fast_block;
        const nw = if (on) w | bit else w & ~bit;
        if (nw == w) return;
        const word: *volatile u16 = &self.fast_block;
        word.* = nw;
    }

    /// The trace-owned bits recomputed from the fields they mirror.
    pub fn traceFastBits(self: *const TraceState) u16 {
        var w: u16 = 0;
        if (self.rec.active) w |= FastBit.recording;
        if (self.pending_exit_anchor != null) w |= FastBit.exit_anchor;
        if (self.pending_replay_anchor != null) w |= FastBit.replay_anchor;
        if (self.pending_call_anchor != null) w |= FastBit.call_anchor;
        if (self.pending_ret_anchor != null) w |= FastBit.ret_anchor;
        if (self.pending_ret_cont_arm != null) w |= FastBit.ret_cont_arm;
        if (self.pending_call_head_arm != null) w |= FastBit.call_head_arm;
        if (self.suspend_depth != 0) w |= FastBit.jit_suspended;
        return w;
    }

    /// Re-read `rec.active` into its bit. Called after every `TraceState` call
    /// into the recorder that can start or stop a recording (start, record,
    /// close, finalize, abort) — `RecordingSession` itself stays unaware of
    /// `fast_block`, so its standalone tests are untouched.
    pub inline fn syncRecordingBit(self: *TraceState) void {
        self.setFastBit(FastBit.recording, self.rec.active);
    }

    /// Debug: the trace-owned bits of `fast_block` equal the fields they
    /// mirror. Checked at the recorder's lifecycle boundaries (start, every
    /// recorded instruction, close, abort), so a missed sync trips at the
    /// transition that caused it rather than at the next dispatch-mode pick,
    /// which `runFastPath`'s whole-word check covers.
    pub inline fn assertTraceBitsInSync(self: *const TraceState) void {
        if (std.debug.runtime_safety) std.debug.assert((self.fast_block & FastBit.trace_owned) == self.traceFastBits());
    }

    // The six pending-field setters: payload and bit always written together.
    pub inline fn setPendingExitAnchor(self: *TraceState, v: ?AnchorKey) void {
        self.pending_exit_anchor = v;
        self.setFastBit(FastBit.exit_anchor, v != null);
    }
    pub inline fn setPendingReplayAnchor(self: *TraceState, v: ?AnchorKey) void {
        self.pending_replay_anchor = v;
        self.setFastBit(FastBit.replay_anchor, v != null);
    }
    pub inline fn setPendingCallAnchor(self: *TraceState, v: ?PendingCallAnchor) void {
        self.pending_call_anchor = v;
        self.setFastBit(FastBit.call_anchor, v != null);
    }
    pub inline fn setPendingRetAnchor(self: *TraceState, v: ?PendingRetAnchor) void {
        self.pending_ret_anchor = v;
        self.setFastBit(FastBit.ret_anchor, v != null);
    }
    pub inline fn setPendingRetContArm(self: *TraceState, v: ?ExitKey) void {
        self.pending_ret_cont_arm = v;
        self.setFastBit(FastBit.ret_cont_arm, v != null);
    }
    pub inline fn setPendingCallHeadArm(self: *TraceState, v: ?ExitKey) void {
        self.pending_call_head_arm = v;
        self.setFastBit(FastBit.call_head_arm, v != null);
    }

    /// The single funnel for arming a recording from `TraceState` (root arm,
    /// continuation, prime side): starts the session and syncs the recording
    /// bit on both outcomes. False when the allocator declined the reset.
    pub fn startRecording(self: *TraceState, key: AnchorKey, num_registers: u16) bool {
        // Doc 63 §5.9: every start path (`onBackEdge`, the prologue's
        // continuation and replay-side starts) is gated on suspension.
        std.debug.assert(!self.suspended());
        defer {
            self.syncRecordingBit();
            self.assertTraceBitsInSync();
        }
        self.rec.start(self.gpa, key, num_registers, self.config.debug_log) catch return false;
        return true;
    }

    /// Test-only: start an owned recording directly (bypassing the arming
    /// policy) and keep `fast_block` in sync — the replacement for poking
    /// `rec.reset` from a test.
    pub fn startRecordingForTest(self: *TraceState, gpa: std.mem.Allocator, anchor: AnchorKey, num_registers: u16) !void {
        defer self.syncRecordingBit();
        try self.rec.reset(gpa, anchor, num_registers);
    }

    /// Test-only: stop an owned recording directly (simulating an abort's
    /// effect without its side effects) and keep `fast_block` in sync.
    pub fn stopRecordingForTest(self: *TraceState) void {
        self.rec.active = false;
        self.syncRecordingBit();
    }

    /// Doc 26 D1a: kill an active recording because an error is unwinding
    /// through the dispatch loop. Called from `Vm.execWith`'s errdefer — the
    /// raise is not part of the recorded IR, so a surviving recording would
    /// stitch an enclosing pcall's post-catch continuation onto the partial
    /// iteration and could commit a Franken-path trace at the next anchor
    /// reach. Guarded (no-op when idle) so nested `execWith` unwind levels
    /// stay idempotent: the innermost aborts, outer levels see an inactive
    /// recording.
    ///
    /// Doc 63 §5.9: not while suspended. A callback's raise is not the outer
    /// recording's; if it escapes the host call, the outer `execWith`'s own
    /// errdefer aborts after suspension is lowered; if the host catches it,
    /// §5.3's epoch check (Phase 2c) aborts the recording at the next
    /// instruction.
    pub fn abortRaised(self: *TraceState) void {
        if (self.rec.active and !self.suspended()) self.abort(.raised);
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

    /// A1' (task 27): PERMANENT-only variant of `recordingBarred` — true only
    /// once either gate has abandoned the anchor for good (`strikes >=
    /// max_strikes`), never during a transient cooldown window. The
    /// ordinary-probe policy rides cooldowns (retries resume when the window
    /// elapses) and resolves as hopeless only on abandonment.
    pub fn recordingAbandoned(self: *const TraceState, anchor: AnchorKey) bool {
        if (self.gate.get(anchor)) |g| {
            if (g.strikes >= self.config.max_strikes) return true;
        }
        if (self.record_gate.get(anchor)) |g| {
            if (g.strikes >= self.config.max_strikes) return true;
        }
        return false;
    }

    /// Shared escalation arithmetic for both gate maps: start (or double) the
    /// cooldown window and bump the strike count. The next eligibility is
    /// `retry_at` = current global `tick` + window; the window then doubles
    /// (capped at `backoff_max`), and after `max_strikes` the anchor is
    /// abandoned for good. Deterministic — keyed only on the monotonic
    /// back-edge tick. Returns null on OOM (gate simply not escalated).
    fn bumpGateEntry(self: *TraceState, map: *AnchorMap(Gate), anchor: AnchorKey, reason: GateReason) ?*Gate {
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
        self.dispatch_gates.getPtr(reason).* +|= 1;
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

    /// `skipBackEdge`'s skip outcome alone, for the interpreter's loop handlers
    /// to test inline before calling into the back-edge epilogue. When it
    /// returns true it has done exactly what `skipBackEdge` does on a skip
    /// (advance `tick`, decrement the slot); when it returns false it has
    /// changed nothing, so the epilogue's own `skipBackEdge` still counts this
    /// back-edge once. Never skips during a recording, like `skipBackEdge`.
    pub inline fn skipGatedBackEdge(self: *TraceState, proto: *const Proto, pc: u32) bool {
        if (self.rec.active) return false;
        const slot = &self.hotcount[hotIndex(proto, pc)];
        if (slot.* == 0) return false;
        slot.* -= 1;
        self.tick +%= 1;
        return true;
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
        const key: AnchorKey = .{ .proto = proto, .pc = pc, .proto_id = proto.id };
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
        const key = AnchorKey{ .proto = proto, .pc = resume_pc, .proto_id = proto.id };
        if (self.isRecording() or self.pending_replay_anchor != null or self.recordingBarred(key))
            return false;
        self.dbg("side-want-at-resume: arming replay-side recording at pc={d}", .{resume_pc});
        self.setPendingReplayAnchor(key);
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
        // Doc 63 §5.9: no selection, no recording start, and a suspended
        // callback's back-edges neither close nor abort the outer recording.
        // The caller (`backEdgeEpilogue`) skips the whole slow path.
        std.debug.assert(!self.suspended());
        if (self.rec.active) {
            // Doc 44 D12b: a `.cont` recording is straight-line-to-terminal —
            // ANY executed loop back-edge (while jmp, repeat closer, numeric/
            // generic for, at any inline depth) aborts, one funnel for every
            // closer shape. (A cont anchor's own pc is tagged, so the
            // close-at-anchor compare below can never match it.)
            if (self.rec.kind == .cont) {
                self.abort(.cont_backedge);
                return;
            }
            // Doc 47 increment A: a pending link peel only tolerates the target
            // inner `for_loop` back-edge. Any OTHER back-edge (a while-loop or
            // repeat-loop inside the peeled inner body) can't be modeled by the
            // peel. Abort (which triggers the rewind-to-link fallback) and then
            // check `close_requested` in case the rewind set it.
            if (self.rec.pending_link_close) |plc| {
                if (target_pc != plc.inner_anchor_pc) {
                    self.abort(.nyi_opcode);
                    if (self.rec.close_requested) self.closeTrace(regs);
                    return;
                }
            }
            if (self.rec.anchor.proto == proto and self.rec.anchor.pc == target_pc) {
                self.closeTrace(regs);
            }
            return;
        }
        const key = AnchorKey{ .proto = proto, .pc = target_pc, .proto_id = proto.id };

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
    fn configureRecording(self: *TraceState) void {
        self.rec.options = .{ .maxrecord = self.config.maxrecord, .peel = self.config.peel, .instunroll = self.config.instunroll, .loopunroll = self.config.loopunroll, .optimize = self.config.optimize, .snapshot_budget = self.config.snapshot_budget };
    }
    pub fn recordInstr(self: *TraceState, instr: Instr, regs: RegWindow, proto: *const Proto, pc: u32, resolved: Value) void {
        // In sync on the way in (nothing between two recorded instructions
        // may leave the word stale) and on the way out (self-abort, close).
        self.assertTraceBitsInSync();
        defer self.assertTraceBitsInSync();
        self.configureRecording();
        const target_i: i64 = @as(i64, pc) + instr.aux;
        // The loop header this instruction leads into, when it is one a
        // recording can link to: doc 56 Phase 3 resolves a `for_loop`
        // back-edge target so a `.continuation` recording can close `.link`
        // into the root there (`recForLoop`, the `rec_loop_jit` /
        // `LJ_TRLINK_ROOT` analogue), and doc 58 resolves a `loop` marker's
        // header the same way (its own `pc + 1`, which is this post-increment
        // cursor) for `while`/`repeat` — the `.jmp` closer carries no header.
        const target: ?u32 = if (instr.op == .for_prep or instr.op == .loop)
            pc
        else if (instr.op == .for_loop and target_i >= 0 and target_i < proto.code.len)
            @intCast(target_i)
        else
            null;
        self.rec.context = .{ .heap = self.rec_heap, .upval_open = self.rec_upval_open, .globals_header = self.rec_globals_header, .upval_cell = self.rec_upval_cell };
        if (target) |dest| {
            const inner = self.findLoopTrace(proto, dest);
            self.rec.context.inner_root = inner != null;
            self.rec.context.inner_root_peeled = if (inner) |t| t.code.peeled else false;
            self.rec.context.inner_root_guards = if (inner) |t| t.code.entry_guards else &.{};
            const leaves = self.lleave_count.get(.{ .proto = proto, .pc = dest, .proto_id = proto.id }) orelse 0;
            const fails = self.unroll_fail.get(self.rec.anchor) orelse 0;
            self.rec.context.unroll_while = leaves >= self.config.lleave_fast_retries or fails < self.config.unroll_fail_flip;
        }
        self.rec.recordInstr(instr, regs, proto, pc, resolved);
        self.syncRecordingBit();
        self.consumeRecordingAbort();
        if (self.rec.close_requested) self.closeTrace(regs);
    }

    /// Doc 44 D11: the unconditional "successful Lua entry" tick, shared by
    /// `onCallEntry` (every tier-0 Lua-callee entry) and the native inline
    /// push sequence (step 7's `incMemQword` twin, one per push). Factored so the
    /// gate-cooldown `tick` stream stays a pure function of the CALL stream on
    /// every leg — a native descent that pushed k frames advances the tick by
    /// exactly the k the tier-0 legs would (round 5 change 1). Tick only after
    /// a SUCCESSFUL entry; failed calls never tick in tier-0 either.
    pub inline fn tickCallEntry(self: *TraceState) void {
        self.tick +%= 1;
    }

    /// Doc 44: count a successful Lua-callee entry toward the callee's
    /// function-head anchor. Called from `opCall`'s `.function` arm AFTER the
    /// frame push + `reloadTopFrame` (failed calls never count). Advances the
    /// gate-cooldown `tick` (review round 1: a call-only recursive workload
    /// whose recording aborts must still see cooldowns elapse). Vararg protos
    /// are refused here — head arming bypasses `recCall`'s vararg rejection,
    /// so the bar must sit at the counting site (doc 44 D2).
    ///
    /// Inline down to the `enabled` test: with tracing off a call pays the
    /// tick and one compare, not an out-of-line call (~30 instructions a
    /// Lua call, callgrind).
    pub inline fn onCallEntry(self: *TraceState, proto: *const Proto, base: usize, call_seq: u64, img: []const Instr) void {
        self.tickCallEntry();
        if (!self.config.enabled) return;
        self.onCallEntryTraced(proto, base, call_seq, img);
    }

    fn onCallEntryTraced(self: *TraceState, proto: *const Proto, base: usize, call_seq: u64, img: []const Instr) void {
        // A recording owns the stream; don't compete. Suspended (doc 63
        // §5.9): no repatch (it drains) and no pending call anchor. Both
        // conditions are `fast_block` bits: one load and test.
        if ((self.fast_block & (FastBit.recording | FastBit.jit_suspended)) != 0) return;
        if (proto.is_vararg) return;
        // Doc 44 D9 (S1): the caller passes the callee's freshly-reloaded
        // image, so the patched steady state is one bounds-checked opcode
        // compare — entry is the patch's job (`maybeRepatchHead` returned on
        // this exact check via its own `codeFor` hash; the D8-era per-call
        // `hasTrace` + `codeFor` hashes both fall away here). The unpatched
        // path below keeps `hasTrace` so D8 repatch recovery stays live.
        if (img.len != 0 and img[0].op == .jfunc_head) return;
        const key = AnchorKey{ .proto = proto, .pc = FUNC_HEAD_PC, .proto_id = proto.id };
        if (self.hasTrace(key)) {
            // Doc 44 D8 (review round 2 blocker 4): entry is the patch's job —
            // but every unpatch source outside the head lifecycle (gateAnchor's
            // markEntryPatchesAt, strike exhaustion at sibling capacity,
            // incumbent retirement) would otherwise strand the surviving
            // traces forever (a head has no virgin back-edge walk). Recovery:
            // when the anchor has traces but pc 0 is NOT patched and the gate
            // has cleared, deterministically re-request install for the best
            // surviving trace. Idempotent — a live patch short-circuits on the
            // image check, and `installEntryPatch` returns `.incumbent` on a
            // raced re-install.
            self.maybeRepatchHead(proto, key, img);
            return;
        }
        if (self.recordingBarred(key)) return;
        const gop = self.counters.getOrPut(self.gpa, key) catch return;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* +|= 1;
        if (gop.value_ptr.* < self.config.hotcall) return;
        gop.value_ptr.* = 0; // reset so a declined/aborted arm re-warms, the loop discipline
        // A body that is only its `ret` has nothing to trace, and the head's
        // terminal would resume at the patched pc 0 (`.self_terminal`).
        // Refused here, at the threshold, so no other call pays the test.
        if (proto.code[0].op == .ret) return;
        self.setPendingCallAnchor(.{ .proto = proto, .base = base, .call_seq = call_seq });
    }

    /// Doc 44 D8: deterministic head entry-patch recovery (see the call site
    /// in `onCallEntry`). Cheap-gated: an already-patched pc 0 returns on one
    /// hashmap probe + opcode compare.
    fn maybeRepatchHead(self: *TraceState, proto: *const Proto, key: AnchorKey, img: []const Instr) void {
        if (!self.config.execute) return; // same gate as install-at-commit
        if (img.len == 0 or img[0].op == .jfunc_head) return; // live patch (or empty proto)
        if (self.recordingBarred(key)) return;
        const best = self.nextTraceExcluding(proto, FUNC_HEAD_PC, &.{}) orelse return;
        self.dbg("head repatch: re-requesting install for trace={d}", .{best.id});
        self.registry.entry_registry.markInstallPending(best);
        self.drainEntryPatchWork();
    }

    /// Doc 44 D12b: count a return through a post-call resume pc toward its
    /// CONTINUATION anchor (`onCallEntry`'s return-side twin — returns into a
    /// site are calls of its continuation, so the threshold is `hotcall`).
    /// Called from `opRet` after the pop + reload, with the CALLER's frozen
    /// cursor and freshly-reloaded image. No tick: the gate-cooldown tick
    /// stream stays a pure function of the CALL stream on every leg (D12c
    /// rule, applied from the start). Refusals, in order:
    /// - the physical-pc collision rule (round 6 change 3): ONE patch per
    ///   physical pc — a resume pc that is already patched (any kind) or is
    ///   a patchable loop-closer site forms NO cont anchor (no counting, no
    ///   recording, no patch). A live `.jcont` at the pc short-circuits to
    ///   "entry is the patch's job" exactly like the head's D9 S1 check.
    /// - vararg callers (the head counter's D2 discipline: cont arming
    ///   bypasses `recCall`'s vararg rejection, so the bar sits here).
    /// - the boundary return never reaches this funnel (`opRet`'s
    ///   `stop_depth` path exits `execImpl` before it).
    /// `opRet` calls it only with tracing enabled.
    pub fn onRetResume(self: *TraceState, proto: *const Proto, resume_pc: u32, base: usize, call_seq: u64, img: []const Instr) void {
        std.debug.assert(self.config.enabled);
        // A recording owns the stream; don't compete. Suspended (doc 63
        // §5.9): as `onCallEntry`, one `fast_block` test for both.
        if ((self.fast_block & (FastBit.recording | FastBit.jit_suspended)) != 0) return;
        if (proto.is_vararg) return;
        if (resume_pc >= img.len) return; // resume at end-of-code (no instruction to anchor)
        // Patched steady state: one bounds-checked opcode compare (D9 S1).
        const resumed_op = img[resume_pc].op;
        if (resumed_op == .jcont) return;
        // Collision rule: the pc hosts (or could host) a different patch kind.
        if (resumed_op == .jfor_loop or resumed_op == .jloop or resumed_op == .jfunc_head) return;
        if (trace_entry_registry.EntryRegistry.patchedEntryOp(proto.code[resume_pc].op) != null) return;
        const key = AnchorKey{ .proto = proto, .pc = contAnchorPc(resume_pc), .proto_id = proto.id };
        if (self.hasTrace(key)) {
            // D8 recovery, cont flavour: traces exist but the pc is unpatched
            // (gate blast, strike exhaustion) — re-request install for the
            // best survivor once the gate clears. Idempotent.
            self.maybeRepatchCont(proto, key, img);
            return;
        }
        if (self.recordingBarred(key)) return;
        const gop = self.counters.getOrPut(self.gpa, key) catch return;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* +|= 1;
        if (gop.value_ptr.* < self.config.hotcall) return;
        gop.value_ptr.* = 0; // reset so a declined/aborted arm re-warms
        // A resume pc that is the caller's own `ret` (`f() end`, or `local
        // s = f() return s`) has nothing to trace, and the continuation's
        // terminal would resume at its own patched pc (`.self_terminal`).
        // Refused at the threshold, so no other return pays the test.
        if (proto.code[resume_pc].op == .ret) return;
        self.setPendingRetAnchor(.{ .proto = proto, .resume_pc = resume_pc, .base = base, .call_seq = call_seq });
    }

    /// Doc 44 D12b: deterministic cont entry-patch recovery (`maybeRepatchHead`
    /// twin). Cheap-gated: an already-patched resume pc returns on one compare.
    fn maybeRepatchCont(self: *TraceState, proto: *const Proto, key: AnchorKey, img: []const Instr) void {
        if (!self.config.execute) return; // same gate as install-at-commit
        const resume_pc = trace_code.entryPc(key.pc);
        if (resume_pc >= img.len or img[resume_pc].op == .jcont) return; // live patch
        if (self.recordingBarred(key)) return;
        const best = self.nextTraceExcluding(proto, key.pc, &.{}) orelse return;
        self.dbg("cont repatch: re-requesting install for trace={d}", .{best.id});
        self.registry.entry_registry.markInstallPending(best);
        self.drainEntryPatchWork();
    }

    /// Doc 44 D12b: dispatch-prologue consumer of `pending_ret_anchor` (the
    /// `maybeStartHead` twin). Returns true iff a `.cont` recording armed at
    /// this prologue step. ALWAYS clears the pending — same consume-or-discard
    /// self-cleaning as the head consumer.
    pub fn maybeStartCont(self: *TraceState, proto: *const Proto, pc: u32, base: usize, call_seq: u64) bool {
        const pending = self.pending_ret_anchor orelse return false;
        self.setPendingRetAnchor(null); // consume-or-discard, never linger
        if (pending.proto != proto or pending.resume_pc != pc or pending.call_seq != call_seq or pending.base != base) return false;
        if (self.rec.active) return false;
        self.armWithPolicy(proto, contAnchorPc(pc), pending.force_ordinary);
        if (!self.rec.active) return false; // reset OOM-declined
        self.rec.kind = .cont;
        self.rec.anchor_abs_base = pending.base;
        return true;
    }

    /// Doc 44: dispatch-prologue consumer of `pending_call_anchor` (the
    /// `maybeStartContinuation` twin). Returns true iff a `.head` recording
    /// armed at this prologue step. ALWAYS clears the pending — a mismatch
    /// means the pending activation is gone (error/unwind between set and
    /// consume), and `call_seq` makes reuse impossible by construction.
    pub fn maybeStartHead(self: *TraceState, proto: *const Proto, pc: u32, base: usize, call_seq: u64) bool {
        const pending = self.pending_call_anchor orelse return false;
        self.setPendingCallAnchor(null); // consume-or-discard, never linger
        if (pc != 0 or pending.proto != proto or pending.call_seq != call_seq or pending.base != base) return false;
        if (self.rec.active) return false;
        self.armWithPolicy(proto, FUNC_HEAD_PC, pending.force_ordinary);
        if (!self.rec.active) return false; // reset OOM-declined
        self.rec.kind = .head;
        self.rec.anchor_abs_base = pending.base;
        return true;
    }

    fn arm(self: *TraceState, proto: *const Proto, target_pc: u32) void {
        self.armWithPolicy(proto, target_pc, false);
    }

    fn armWithPolicy(self: *TraceState, proto: *const Proto, target_pc: u32, force_ordinary: bool) void {
        if (!self.startRecording(.{ .proto = proto, .pc = target_pc, .proto_id = proto.id }, proto.num_registers)) return;
        self.dbg("rec-arm: pc={d} force_ordinary={}", .{ target_pc, force_ordinary });
        // Doc 43 §3.1 (P0a): seed the anchor's absolute slab base for the open-cell
        // aliasing check. `reset` zeroes it; the dispatch loop stashed `st.base`
        // in `pending_anchor_base` just before this `onBackEdge` call.
        self.rec.anchor_abs_base = self.pending_anchor_base;
        // Doc 43 P5: arm with the anchor's mutable-upvalue memo, so a retry
        // after an `.upvalue_mutable` abort routes scalar closed-cell reads
        // through `uload` from the first instruction.
        self.rec.route_upvalue_reads = self.upvalue_mutable_memo.contains(.{ .proto = proto, .pc = target_pc, .proto_id = proto.id });
        // Doc 45 D2: arm with the anchor's precise-mode memo, so a retry after
        // a `.needs_precise` cancel records per-bytecode snapshots from the
        // first instruction (deterministic re-recording, never a retroactive
        // mid-candidate promotion). The full-entry prologue is NOT emitted here
        // — `maybeCloseAtAnchor` uses `instrs.len == 0` to skip the arming
        // iteration's spurious close, so emitting anything now would close an
        // empty-body trace. The recorder emits the prologue lazily at its first
        // body `recordInstr` instead (`beginPrecise` / `precise_prologue_done`).
        // A1' (task 27): an ordinary-probe recording SUPPRESSES the memo seed
        // (that is its whole point — record the construction-free path as an
        // ordinary sibling next to the precise incumbent); the memo itself is
        // never mutated here.
        self.rec.force_ordinary = force_ordinary;
        self.rec.precise = !force_ordinary and
            self.precise_anchor_memo.contains(.{ .proto = proto, .pc = target_pc, .proto_id = proto.id });
    }

    /// Abandon the in-flight recording: deactivate, remember why, and gate the
    /// anchor with exponential backoff so it is retried progressively less often
    /// (and abandoned after `max_strikes`). Tier-0 is untouched — nothing was ever
    /// executed from the trace.
    // pub for trace_recorder.zig (file-split pass)
    pub fn abort(self: *TraceState, reason: AbortReason) void {
        self.rec.abort(reason);
        self.syncRecordingBit();
        self.consumeRecordingAbort();
        self.assertTraceBitsInSync();
    }
    /// Kill the in-flight recording with `RecordingSession.cancel` semantics:
    /// no peel rewind into a `.link` close (doc 61 §7.1 item 2). Otherwise the
    /// same bookkeeping as `abort`.
    pub fn cancelRecording(self: *TraceState, reason: AbortReason) void {
        self.rec.cancel(reason);
        self.syncRecordingBit();
        self.consumeRecordingAbort();
        self.assertTraceBitsInSync();
    }
    fn consumeRecordingAbort(self: *TraceState) void {
        const notice = self.rec.takeAbortNotice() orelse return;
        const reason = notice.reason;
        if (self.config.record_aborts) self.logAbort(notice);
        // Doc 38 unroll-first policy: a ROOT recording that chose to unroll an
        // inner while and then died — for ANY reason (too long, nyi op it only
        // reached because it kept going, guard depth, …) — is one proven
        // unroll failure at this outer anchor. At `unroll_fail_flip` failures
        // `recWhileLink` stops unrolling here and decomposes (LINNER).
        if (notice.kind == .root and notice.unrolled_while) {
            if (self.unroll_fail.getOrPut(self.gpa, notice.anchor)) |gop| {
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* +|= 1;
                self.dbg("unroll-fail (record abort): anchor pc={d} count={d}", .{ notice.anchor.pc, gop.value_ptr.* });
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
        // Doc 43 P5: memoize the anchor before the ordinary gate strike — the
        // gated retry re-records with `route_upvalue_reads` (see `arm`) and the
        // store that aborted here then records. OOM drops the memo: the retry
        // simply re-aborts and re-tries the memo, never a hotter path.
        if (reason == .upvalue_mutable) {
            self.upvalue_mutable_memo.put(self.gpa, notice.anchor, {}) catch {};
        }
        // Doc 45 D2: `.needs_precise` is a non-penalizing cancellation, not a
        // strike — the shape isn't untraceable, it just needs the anchor
        // re-recorded in precise mode. Memoize the anchor, then rewind its
        // hotness counter to threshold-minus-one (the LLEAVE fast-retry
        // mechanics: the warming counter is past its one-shot crossing, so
        // without the rewind the retry starves) and return before the gate.
        // The counter family follows the anchor kind: back-edge counters warm
        // to `hotloop`, head/cont counters to `hotcall`. On memo OOM fall
        // through to the ordinary gate strike — fail-closed, never an
        // ungated infinite retry.
        if (reason == .needs_precise) {
            // Doc 45 D8 interim: an exec-log session must never PRODUCE a
            // precise trace — the wire format has no snapshot schema until
            // the D8 bump, and `traceser.encodeFile` (correctly) hard-errors
            // on one. Skip the memo + retry entirely: the abort falls through
            // to the ordinary gate strike and the anchor stays tier-0 for the
            // session. `record_exec_log` is set once at session setup, so
            // this is a deterministic pure function of config.
            //
            // A1' (task 27): an ordinary-PROBE session hitting construction is
            // the probe's expected failure mode, not new evidence — it takes
            // the ordinary gate strike below (bounded retries via the record
            // gate; strikes eventually bar the anchor and the walk clears the
            // probe flag). The memo is NOT touched and NO precise re-record is
            // armed: the anchor already has its precise trace.
            if (self.config.record_exec_log or notice.force_ordinary) {
                // fall through to the ordinary strike below
            } else if (self.precise_anchor_memo.getOrPut(self.gpa, notice.anchor)) |gop| {
                // FIRST memoization only: an anchor already in the memo means
                // this recording SHOULD have armed precise but didn't (the
                // trace_link starters bypass `arm()` — the round-2 seam). A
                // second non-penalized retry would repeat identically: fall
                // through to the ordinary gate strike instead (fail-closed,
                // never a livelock).
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{}; // A1': fresh memo, no probe requested yet
                    const threshold = switch (anchorKind(notice.anchor.pc)) {
                        .loop => self.config.hotloop,
                        .head, .cont => self.config.hotcall,
                    };
                    self.counters.put(self.gpa, notice.anchor, threshold -| 1) catch {};
                    self.dbg("needs-precise retry: anchor pc={d}", .{notice.anchor.pc});
                    return;
                }
            } else |_| {}
        }
        if (reason == .loop_leave) {
            if (self.lleave_count.getOrPut(self.gpa, notice.anchor)) |gop| {
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
                    self.counters.put(self.gpa, notice.anchor, self.config.hotloop -| 1) catch {};
                    self.dbg("lleave fast-retry: anchor pc={d} count={d}", .{ notice.anchor.pc, gop.value_ptr.* });
                    return;
                }
            } else |_| {}
        }
        self.gateRecordAnchor(notice.anchor, .record_abort);
    }

    /// Append-or-bump the abort diagnostic log (`--dump-aborts`). Deduped by
    /// `(anchor.pc, reason, op)` so a loop aborting on every back-edge is one row
    /// with a growing `count`, not millions. A linear scan is fine — distinct
    /// abort sites are few (a handful of loops × a handful of reasons), and this is
    /// off the hot path entirely (only runs when `config.record_aborts`). On OOM we
    /// simply drop the row: a diagnostic must never perturb execution.
    fn logAbort(self: *TraceState, notice: @import("trace_recorder.zig").RecordingSession.AbortNotice) void {
        const reason = notice.reason;
        const anchor = notice.anchor;
        for (self.abort_log.items) |*r| {
            if (r.anchor_pc == anchor.pc and r.proto == anchor.proto and
                r.reason == reason and r.op == notice.op)
            {
                r.count += 1;
                return;
            }
        }
        self.abort_log.append(self.gpa, .{
            .proto = anchor.proto,
            .anchor_pc = anchor.pc,
            .abort_pc = notice.pc,
            .op = notice.op,
            .reason = reason,
            .ir_len = notice.ir_len,
        }) catch {};
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
        defer self.assertTraceBitsInSync(); // success, failed close, failed commit
        self.configureRecording();
        const ready = self.rec.close(regs);
        self.syncRecordingBit();
        if (self.rec.takePeelNotice()) |notice| switch (notice) {
            .enter => |n| self.dbg("peel: enter anchor pc={d} marker ir={d}", .{ n.anchor_pc, n.marker }),
            .close => |n| self.dbg("peel: close anchor pc={d} body ir={d}..{d}", .{ n.anchor_pc, n.begin, n.end }),
        };
        if (!ready) {
            self.consumeRecordingAbort();
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
        // No terminal-state writes here: `finalize`'s defer clears `active` and
        // `side_src` on success AND failure, so a stale key can never latch a
        // later commit.
    }

    /// B-2b commit publication: preserve the logical hotexit provenance only
    /// after the child is registered. A same-anchor relation OOM deliberately
    /// leaves the parent counter live (no DONE-without-edge); cross-anchor side
    /// traces retain the historical DONE latch but never create an arm relation.
    pub fn finishSideTraceProvenance(self: *TraceState, child: *Trace, source: ?ExitKey) void {
        const src = source orelse return;
        if (self.traceById(child.id) != child) return;
        const parent = self.traceById(src.trace_id) orelse {
            self.side_commits_orphaned +|= 1;
            return;
        };
        var may_latch_done = true;
        if (parent.code.anchor.proto == child.code.anchor.proto and parent.code.anchor.pc == child.code.anchor.pc and
            src.exit_instr < parent.code.instrs.len)
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
        // Doc 56 Phase 3: an exit-side child binds (or retires) its wanted
        // exit. Always cross-anchor (the child sits at the exit's resume pc,
        // never a loop header), so `may_latch_done` holds.
        self.noteExitSideCommit(parent, src.exit_instr, child);
        if (may_latch_done and src.exit_instr < parent.exit_counts.len)
            parent.exit_counts[src.exit_instr] = Trace.EXIT_COUNT_DONE;
    }

    /// Copy the in-progress recording into an owned, cached `Trace`. The exit
    /// snapshot is every register the trace *defined* (its loop-carried writes).
    /// When `config.optimize`, the trace optimizer (`tropt.zig`) rewrites the IR
    /// first; an optimizer OOM falls back to caching the *unoptimized* trace
    /// (correct, just slower) rather than failing the commit.
    // ------------------------------------------------------------------
    // A1' (doc 45 / task 27): ordinary-probe policy at precise-occupied
    // one-shot anchors. The flag lives in `precise_anchor_memo`'s value;
    // `ordinary_probe_count` keeps the steady-state check one branch.
    // ------------------------------------------------------------------

    pub fn ordinaryProbeNeeded(self: *const TraceState, anchor: AnchorKey) bool {
        if (self.ordinary_probe_count == 0) return false;
        const memo = self.precise_anchor_memo.get(anchor) orelse return false;
        return memo.ordinary_probe;
    }

    fn setOrdinaryProbe(self: *TraceState, anchor: AnchorKey) void {
        const memo = self.precise_anchor_memo.getPtr(anchor) orelse return;
        if (memo.ordinary_probe) return;
        memo.ordinary_probe = true;
        self.ordinary_probe_count += 1;
        self.dbg("ordinary-probe set: anchor pc={d}", .{anchor.pc});
    }

    pub fn clearOrdinaryProbe(self: *TraceState, anchor: AnchorKey) void {
        const memo = self.precise_anchor_memo.getPtr(anchor) orelse return;
        if (!memo.ordinary_probe) return;
        memo.ordinary_probe = false;
        self.ordinary_probe_count -= 1;
        self.dbg("ordinary-probe cleared: anchor pc={d}", .{anchor.pc});
    }

    /// Does the anchor already hold a non-precise (ordinary) trace?
    fn hasOrdinaryTraceAt(self: *const TraceState, anchor: AnchorKey) bool {
        var it = self.registry.tracesAt(anchor);
        while (it.next()) |t| {
            if (t.code.deopt_mode != .precise) return true;
        }
        return false;
    }

    fn commit(self: *TraceState) !void {
        var candidate = r: {
            defer self.syncRecordingBit();
            break :r try self.rec.finalize();
        };
        defer candidate.deinit(self.gpa);
        const t = try self.registry.allocate();
        errdefer self.registry.discardAllocation(t);
        // Ownership transfer per RecordingCandidate's contract: take() BEFORE
        // the code is reached through the record — never a shallow copy of a
        // live candidate. From here `t.code` is the sole owner; on a failed
        // publish the errdefer below returns the arrays (`discardAllocation`
        // destroys only the record, never code), and the candidate's deferred
        // deinit is a no-op after take(). `side_src` stays readable by design.
        t.code = candidate.take().?;
        errdefer t.code.deinit(self.gpa);
        if (self.gpa.alloc(u8, t.code.instrs.len)) |counts| {
            @memset(counts, 0);
            t.exit_counts = counts;
        } else |_| {}
        errdefer if (t.exit_counts.len != 0) self.gpa.free(t.exit_counts);
        // Doc 56 Phase 3: the per-exit exit-side state, only for traces that
        // can use it. Fail-soft like `exit_counts`.
        // §4.8.3 R4: the miss counters come with it, and (doc 64 step 3)
        // the bound entries (all three or none).
        if (t.code.anyExitAttachable()) alloc: {
            const n = t.code.instrs.len;
            const sides = self.gpa.alloc(exit_attach.ExitSide, n) catch break :alloc;
            const misses = self.gpa.alloc(u8, n) catch {
                self.gpa.free(sides);
                break :alloc;
            };
            const entries = self.gpa.alloc(u32, n) catch {
                self.gpa.free(sides);
                self.gpa.free(misses);
                break :alloc;
            };
            @memset(sides, .none);
            @memset(misses, 0);
            @memset(entries, Trace.NO_EXIT_SIDE_ENTRY);
            t.exit_side = sides;
            t.exit_side_misses = misses;
            t.exit_side_entry = entries;
        }
        errdefer if (t.exit_side.len != 0) {
            self.gpa.free(t.exit_side);
            self.gpa.free(t.exit_side_misses);
            self.gpa.free(t.exit_side_entry);
        };
        try self.registry.publish(t);
        if (comptime jitdbg.enabled) if (self.config.debug_log) {
            // Lane pins (guard_lane aux per table guard) identify which array
            // shape a sibling specializes on — the alternating-lane churn
            // diagnosis needed exactly this at commit time.
            var lanes: [4]i32 = .{ -1, -1, -1, -1 };
            var nl: usize = 0;
            for (t.code.instrs) |ins| {
                if (ins.op == .guard_lane and nl < lanes.len) {
                    lanes[nl] = ins.aux;
                    nl += 1;
                }
            }
            self.dbg("commit: trace={d} anchor pc={d} ir_len={d} proto={s} lanes={any}", .{ t.id, t.code.anchor.pc, t.code.instrs.len, t.code.anchor.proto.name, lanes[0..nl] });
            // Doc 56 Phase 1 probe: the exit snapshots the trace carries.
            self.dbg("exit-snap: trace={d} ords={d} snaps={d} slots={d}", .{ t.id, t.code.exit_snap_by_ord.len -| 1, t.code.exit_snapshots.len, t.code.exit_snapshot_slots.len });
            // One line per kept snapshot: which slots it restores, from which
            // committed refs (`r<slot>=%<ref>`), at which resume pc.
            for (t.code.exit_snap_by_ord, 0..) |si, ord| {
                if (si == 0) continue;
                const s = t.code.exit_snapshots[si - 1];
                self.dbg("exit-snap:   ord={d} snap={d} resume_pc={d} slots={any}", .{ ord, si, s.resume_pc, t.code.exit_snapshot_slots[s.slots_begin..][0..s.slots_len] });
            }
            // The committed IR, as `--dump-traces` prints it — at commit
            // time, so a run that never finishes still shows its traces.
            const ew = io.stderrWriter();
            writeTrace(ew, t) catch {};
            ew.flush() catch {};
        };
        self.finishSideTraceProvenance(t, candidate.side_src);
        // Doc 64 §10 step 2 (2d): a continuation at a given-up exit's resume
        // point is the new evidence that revives it.
        self.reviveExitSideAt(t);
        // Coverage (gated): a trace now exists at this anchor, so subsequent
        // interpreted back-edges here are "fallback despite a trace."
        if (self.config.coverage) self.markAnchorTraced(t.code.anchor);
        // A-ii.2: refresh the structural-edge cache — the new trace may add edges
        // FROM itself AND make pre-existing traces' exits newly resolvable. Fail-soft
        // (never fails the commit); any OOM fails CLOSED to an empty cache (round-14
        // finding 6 — this new trace can add a boundary edge that invalidates a prior
        // region's owner, so retaining the prior snapshot could keep a stale arm).
        self.rebuildEdgeCache();
        // A-ii.4: rediscover regions over the refreshed graph. Fail-soft;
        // any OOM fails CLOSED to empty physical indices (arm nothing).
        self.rebuildRegions();
        // Doc 44 P0/D12b: a ONE-SHOT trace's (head or cont) ONLY entry is its
        // patched pc (`jfunc_head` at pc 0 / `jcont` at the resume pc) — no
        // back-edge walk ever reaches a sentinel/tagged anchor, so it can
        // never qualify through the receipt funnel (`accountTraceRun`).
        // Qualify at commit and drain immediately: without a loop-trace entry
        // this turn there may be no other drain site, and marks are legal
        // anywhere (§R6-1) while this drain runs post-publish, outside any
        // receipt grammar.
        // Gated on `config.execute`: with execution off (the recording-shape
        // test harness) loop patches are unreachable too — they qualify via
        // receipts, which need traces to run — and a one-shot patch must not
        // become the one path that runs a trace anyway.
        if (self.config.execute and anchorKind(t.code.anchor.pc) != .loop) {
            self.registry.entry_registry.markInstallPending(t);
            self.drainEntryPatchWork();
        }
        // A1' (doc 45 / task 27): one-shot anchor population policy.
        // A PRECISE commit requests exactly one ordinary-probe recording
        // (unless an ordinary sibling already exists or the anchor is full) so
        // the anchor can also grow a native-runnable ordinary trace — without
        // this, a precise incumbent permanently claims the anchor: sibling
        // recording only triggers on hot exits of ENTERED traces, and under
        // native mode a declined precise trace never enters (binary-trees lost
        // its whole BottomUpTree descent this way). An ORDINARY one-shot
        // commit resolves any outstanding probe. Mode-independent by design
        // (codex 01a08f8d): the probe fires in tier-1a-only runs too, so the
        // trace population never depends on backend capability.
        if (anchorKind(t.code.anchor.pc) != .loop) {
            const anchor = t.code.anchor;
            if (t.code.deopt_mode == .precise) {
                if (!self.hasOrdinaryTraceAt(anchor) and
                    self.countTracesAt(anchor) < self.config.max_traces_per_anchor)
                    self.setOrdinaryProbe(anchor);
            } else {
                self.clearOrdinaryProbe(anchor);
            }
        }
    }

    // Emission and finalization are owned by RecordingSession.
};

// The recorder lives in trace_recorder.zig. Only the names this module and its
// direct consumers genuinely use are re-exported; everything else is imported
// from trace_recorder.zig at the point of use.
pub const MAX_TRACE_INPUTS = trace_recorder_mod.MAX_TRACE_INPUTS;
pub const RecordingSession = trace_recorder_mod.RecordingSession;

// ---------------------------------------------------------------------------
// Disassembly — same spirit as `bytecode.writeProto`. Invaluable for `--dump-
// traces` and for asserting trace shape in tests.
// ---------------------------------------------------------------------------

pub const writeIrInstr = trace_ir.writeIrInstr;

/// Disassemble a whole trace: header + entry slots + numbered IR (the slot-bound
/// `phi` rows are the loop-carried writebacks that `exit_stores` used to list).
pub fn writeTrace(w: *io.Writer, t: *const Trace) io.Writer.Error!void {
    try w.print("trace {s}:{d}  entry=[", .{ t.code.anchor.proto.name, t.code.anchor.pc });
    for (t.code.entry_slots, 0..) |s, i| {
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
    try w.print("]  inputs={d}/{d}\n", .{ t.code.inputs.len, MAX_TRACE_INPUTS });
    // Konst pool values, so a dump can answer alias/identity questions about
    // `konst kN` operands (e.g. "are these two aref indices the same value?")
    // without a debugger. One line, only when the pool is non-empty.
    if (t.code.consts.len != 0) {
        try w.writeAll("  konsts:");
        for (t.code.consts, 0..) |kv, ki| {
            try w.print(" k{d}=", .{ki});
            try io.writeValue(w, kv);
        }
        try w.writeAll("\n");
    }
    for (t.code.instrs, 0..) |ins, i| {
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
    try w.print("    for_prep patched:     {d} (first trips through the loop's patched entry)\n", .{ts.for_prep_patched});
    try w.print("    self-call pushes:     {d} (doc 44 D11 native descents)\n", .{ts.self_call_pushes});
    try w.print("    self-ret pops:        {d} (doc 44 D12c native unwinds)\n", .{ts.self_ret_pops});
    try w.print("    frame links:          ret-cont arms={d} hits={d}; call-head arms={d} hits={d}\n", .{ ts.ret_cont_link_arms, ts.ret_cont_link_hits, ts.call_head_link_arms, ts.call_head_link_hits });
    try w.print("    rowless sibling hits: {d} (doc 54 P2 amendment hops)\n", .{ts.sibling_link_hits});
    try w.print("    link arms:            native={d} source={d} loopdone={d} bridge={d}\n", .{ ts.native_link_arms, ts.native_source_link_arms, ts.native_loopdone_link_arms, ts.native_region_bridge_arms });
    try w.print("    bridge arm attempts:  {d} (pipeline runs; vs {d} arms)\n", .{ ts.native_region_bridge_arm_attempts, ts.native_region_bridge_arms });
    {
        // Doc 67 P0: per arm kind, the arms a proven entry could have taken,
        // of the arms published, of the funnel runs; then the fact tables.
        const d = &ts.registry.native_physical.proven_dry_run;
        try w.writeAll("    proven dry run:      ");
        for (std.enums.values(native_physical.ArmKind)) |k| {
            if (k.provenShape() == null) continue;
            try w.print(" {s}={d}/{d}/{d}", .{ @tagName(k), d.eligible.get(k), d.arms.get(k), d.attempts.get(k) });
        }
        try w.writeAll(" (eligible/arms/attempts)\n");
        var n_pages: usize = 0;
        var n_tables: usize = 0;
        var n_entry: usize = 0;
        var n_exits: usize = 0;
        var fact_bytes: usize = 0;
        for (ts.registry.cache.items) |t| {
            const c = switch (t.native) {
                .compiled => |*c| c,
                else => continue,
            };
            n_pages += 1;
            const f = &(c.facts orelse continue);
            n_tables += 1;
            n_entry += f.entry_len;
            n_exits += f.exits.len;
            fact_bytes += f.bytes();
        }
        try w.print("    fact tables:          pages={d} built={d} entry facts={d} exit lists={d} bytes={d}\n", .{ n_pages, n_tables, n_entry, n_exits, fact_bytes });
    }
    try w.print("    link fused:           source={d} loopdone={d} bridge={d} (bridge cap yields={d})\n", .{ ts.native_source_link_fused, ts.native_loopdone_link_fused, ts.native_region_bridge_fused, ts.native_region_bridge_cap_yields });
    try w.writeAll("    region closes:       ");
    for (std.enums.values(CloseReason)) |why| try w.print(" {s}={d}", .{ @tagName(why), ts.region_closes.get(why) });
    try w.writeAll("\n    dispatch gates:      ");
    for (std.enums.values(GateReason)) |why| try w.print(" {s}={d}", .{ @tagName(why), ts.dispatch_gates.get(why) });
    try w.writeAll("\n");
    try w.print("    link disarms:         {d} (peak simultaneous arms: {d})\n", .{ ts.registry.native_physical.native_link_disarms, ts.registry.native_physical.native_link_peak });
    try w.print("    native link exits:    {d} (follows={d})\n", .{ ts.native_link_exits, ts.native_link_follow_count });
    try w.print("    ir link exits:        {d} (follows={d})\n", .{ ts.link_ir_exits, ts.link_follow_count });
    try w.print("    prime-side:           arms={d} chain-follows={d} tier0-body-entries={d}\n", .{ ts.prime_side_arms, ts.prime_side_chain_follows, ts.tier0_outer_body_entries });
    {
        // Doc 57 P3: live traces whose loop body is several source
        // iterations (instability unroll), and the extra iterations total.
        var n_unrolled: usize = 0;
        var n_extra: usize = 0;
        for (ts.registry.cache.items) |t| {
            if (t.code.instunrolled == 0) continue;
            n_unrolled += 1;
            n_extra += t.code.instunrolled;
        }
        try w.print("    instability unroll:   traces={d} extra iterations={d}\n", .{ n_unrolled, n_extra });
    }
    {
        // Doc 56 §4.2: exit-snapshot memory over the live traces, next to the
        // IR it describes (LuaJIT's snapshots cost about the IR's size; ours
        // must stay in that range).
        var n_traces: usize = 0;
        var n_snaps: usize = 0;
        var n_slots: usize = 0;
        var n_ords: usize = 0;
        var n_ir: usize = 0;
        for (ts.registry.cache.items) |t| {
            if (t.code.exit_snap_by_ord.len != 0) n_traces += 1;
            n_snaps += t.code.exit_snapshots.len;
            n_slots += t.code.exit_snapshot_slots.len;
            n_ords += t.code.exit_snap_by_ord.len;
            n_ir += t.code.instrs.len;
        }
        const tsnap = @import("trace_snapshot.zig");
        const snap_bytes = n_snaps * @sizeOf(tsnap.Snapshot) + n_slots * @sizeOf(tsnap.SnapshotSlot) + n_ords * @sizeOf(trace_ir.SnapIdx);
        try w.print("    exit snapshots:       traces={d} snaps={d} slots={d} bytes={d} (ir bytes={d})\n", .{ n_traces, n_snaps, n_slots, snap_bytes, n_ir * @sizeOf(trace_ir.IrInstr) });
        // Doc 56 §4.2 (Phase 1): the native exit location maps of the
        // compiled traces, and — per exit, per restored slot — whether the
        // body still holds the value there (`lost` is what a later phase
        // pays for in extended liveness).
        var n_mapped: usize = 0;
        var n_values: usize = 0;
        var n_carried: usize = 0;
        var map_bytes: usize = 0;
        var held: usize = 0;
        var lost: usize = 0;
        for (ts.registry.cache.items) |t| {
            const c = switch (t.native) {
                .compiled => |*c| c,
                else => continue,
            };
            const m = &c.exit_locs;
            if (m.values.len == 0) continue;
            n_mapped += 1;
            n_values += m.values.len;
            n_carried += m.carried.len;
            map_bytes += m.bytes();
            for (0..t.code.instrs.len) |ei| {
                const si = t.code.exitSnapIdx(ei) orelse continue;
                const s = t.code.exit_snapshots[si - 1];
                for (t.code.exit_snapshot_slots[s.slots_begin..][0..s.slots_len]) |ss| {
                    if (m.at(ss.ref, ei) != null) held += 1 else lost += 1;
                }
            }
        }
        try w.print("    exit locations:       traces={d} values={d} carried={d} bytes={d} exit-slots held={d} lost={d}\n", .{ n_mapped, n_values, n_carried, map_bytes, held, lost });
        // Doc 56 §4.3 (Phase 2): the attachability verdict of every exit
        // that has a snapshot, and — over the attachable ones only — how
        // many restored slots the native body still holds (the Phase 4
        // liveness extension's work list).
        var by_verdict = std.enums.EnumArray(exit_attach.Verdict, usize).initFill(0);
        var att_held: usize = 0;
        var att_lost: usize = 0;
        for (ts.registry.cache.items) |t| {
            for (0..t.code.instrs.len) |ei| {
                const si = t.code.exitSnapIdx(ei) orelse continue;
                const v = exit_attach.classify(&t.code, ei);
                std.debug.assert((v == .attachable) == t.code.exitAttachable(ei));
                by_verdict.getPtr(v).* += 1;
                if (v != .attachable) continue;
                const m = switch (t.native) {
                    .compiled => |*c| &c.exit_locs,
                    else => continue,
                };
                const s = t.code.exit_snapshots[si - 1];
                for (t.code.exit_snapshot_slots[s.slots_begin..][0..s.slots_len]) |ss| {
                    if (m.at(ss.ref, ei) != null) att_held += 1 else att_lost += 1;
                }
            }
        }
        try w.print("    exit attach:          attachable={d} slots held={d} lost={d}; refused:", .{ by_verdict.get(.attachable), att_held, att_lost });
        var any_refused = false;
        for (std.enums.values(exit_attach.Verdict)) |v| {
            if (v == .attachable or by_verdict.get(v) == 0) continue;
            try w.print(" {s}={d}", .{ @tagName(v), by_verdict.get(v) });
            any_refused = true;
        }
        try w.writeAll(if (any_refused) "\n" else " none\n");
        // Doc 56 Phase 3: the tier-1a exit-side path.
        try w.print("    exit side:            wants={d} records={d} binds={d} (by chain {d}) giveups={d} hops={d} chained={d} retries={d} miss-giveups={d}\n", .{ ts.exit_side_wants, ts.exit_side_records, ts.exit_side_binds, ts.exit_side_chain_binds, ts.exit_side_giveups, ts.exit_side_hops, ts.exit_side_chains, ts.exit_side_retries, ts.exit_side_miss_giveups });
        try w.print("    exit-side chain ends: natural stops={d} revivals={d}\n", .{ ts.exit_side_natural_stops, ts.exit_side_revivals });
        try w.print("    exit-side loop roots: routes={d} retargets={d}\n", .{ ts.exit_side_root_routes, ts.exit_side_root_retargets });
        // Doc 56 Phase 4: native exit adapters.
        try w.print("    exit adapters:        built={d} native hops={d}; refused:", .{ ts.exit_adapter_builds, ts.exit_side_native_hops });
        var any_adapter_refused = false;
        for (std.enums.values(nativegen.adapter.Refusal)) |why| {
            const c = ts.exit_adapter_refusals[@intFromEnum(why)];
            if (c == 0) continue;
            try w.print(" {s}={d}", .{ @tagName(why), c });
            any_adapter_refused = true;
        }
        try w.writeAll(if (any_adapter_refused) "\n" else " none\n");
        // Doc 56 Phase 5: the adapter's direct jump into the child.
        try w.print("    exit-side arms:       armed={d} fused hops={d} yields={d} disarmed (child prologue)={d} burst skips={d}\n", .{ ts.exit_side_arms, ts.exit_side_fused, ts.exit_side_yields, ts.exit_side_disarms, ts.exit_side_burst_skips });
    }

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
    _ = @import("trace_p0_alias_test.zig");
    _ = @import("trace_evict_test.zig");
    _ = @import("trace_link_peel_test.zig");
}
