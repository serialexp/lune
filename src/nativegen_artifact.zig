//! Compiled-artifact types for tier-1b native codegen (split from
//! `nativegen.zig`, file-split pass): the proved `Kind` lattice, the
//! `NativeResult` exit ABI + silent-episode ledger layouts, exit-patch
//! descriptors, the entry `SeedPlan`, and `CompiledTrace`/`NativeState` —
//! the callable artifact and its run wrappers.

const std = @import("std");
const trace_exec = @import("trace_exec.zig");
const trace_code = @import("trace_code.zig");
const RegWindow = @import("regwindow.zig").RegWindow;
const mcode = @import("nativegen_mcode.zig");
const Trace = trace_code.TraceCode;
const NativeSeedCtx = trace_code.NativeSeedCtx;
const ExecPage = mcode.ExecPage;
const mapExecutable = mcode.mapExecutable;

/// The proven kind of each SSA ref.
///   - `none`  — produces no usable value (a guard / the `loop` marker);
///               referencing it as an operand is a bail.
///   - `int` / `bool` — a boxed scalar (GP register) that may be carried, flushed,
///               or stored.
///   - `float` — a boxed f64 (Phase D). Lives in an XMM register / a shared 8-byte
///               spill cell; carried & flushed (TAG_FLOAT + `movsd`) like an int but
///               in the disjoint XMM pool. `div`/`pow` results and any arithmetic
///               with a float operand are `.float`.
///   - `ptr`   — a raw `*GcHeader` (a `guard_table`-covered table `slot_load`).
///               Classified `invariant`, loaded once; **must never** reach
///               `exit_stores` (the deopt flush boxes as TAG_INT — C2).
///   - `func`  — a raw `*GcHeader` for a Lua closure (a `guard_func`-covered
///               `slot_load`: the cross-frame callee snapshot, U1). Like `.ptr` it
///               is an invariant heap pointer loaded once and tag-checked TAG_HEAP,
///               but the prologue verifies it is a closure of the recorded
///               `Proto.id` (not a table+lane). Consumed ONLY by `guard_func` (an
///               entry guard) — never feeds arithmetic, an `aref`, or a flush.
///   - `aref`  — the paired `(table, index)` addressing token produced by `aref`
///               (its register holds `idx0 = index-1`). A distinct kind so it can
///               neither feed arithmetic nor be flushed to a slot.
///   - `href` — the hash-part value-cell pointer produced by `href` (H1). A
///               loop-invariant `*Value` into a table's hash part, **seeded** into a
///               slab slot per entry (`seedTraceInputs`) and loaded from
///               `[rsi + aux*8]`, not computed from the operands. Like `.aref` it is a
///               distinct addressing kind — it can neither feed arithmetic nor be
///               flushed to a slot (C2). Consumed only by `hload`/`hstore`/`guard_hash`.
pub const Kind = enum { none, int, bool, ptr, aref, float, func, href, native, heap, boxed, nil };

pub const NativeResult = extern struct {
    completed: usize,
    exit_instr: u32,
    linked_loop_done: u64,
    /// P-B (doc 17): the stable `Trace.id` of the trace performing the final exit,
    /// baked as an imm32 into every exit stub (`emitReturn`). With no linking yet it
    /// is always the entered trace's id; once a native parent `jmp`s into a linked
    /// child (2.3), the child's exit stub overwrites it, so the dispatcher can map
    /// the result back to the correct final trace instead of assuming the parent.
    final_trace_id: u32,
    /// 2.3b-0 (doc 17): the value of the `rbx` iteration counter at the moment this
    /// body was entered, snapshotted by the first body instruction
    /// (`mov [rdx+entry_rbx], rbx`). A fresh trampoline entry zeroes `rbx`, so for an
    /// un-fused run this is 0 and `local_completed == completed`. Once a native parent
    /// `jmp`s into a child under the shared frame (2.3b-1) `rbx` already holds the
    /// parent's cumulative count, so the child's body records that baseline here and
    /// the Zig wrapper recovers the child's OWN committed count as
    /// `completed − entry_rbx`. Written by whichever body performs the FINAL exit
    /// (each body's entry overwrites it), so the returned value always describes the
    /// final trace. Not consumed by the host — pure scratch that rides in the result.
    entry_rbx: usize,
    /// 2.3c-0b (doc 17): why the final body exited — `trace_exec.ExitReason` as a raw
    /// `u32`. The wrapper inits it to `.normal` (0); ONLY the `prologue_fail` stub
    /// overwrites it (to 1) via `movMemImm32`, so it splits a native prologue-fail from
    /// the tier-1a "ran to completion" meaning of `exit_instr == maxInt`. Written by
    /// whichever body performs the FINAL exit (each exit path either leaves it 0 or, at
    /// prologue_fail, sets 1), so the returned value describes the final trace.
    exit_reason: u32,
    /// 2.3c-0 (doc 17): the resolved absolute dispatch target for the shared
    /// `deopt_exit` flush. Each ordinary / loop-done-ordinary mini-stub RESOLVES its
    /// dispatch target and stashes it HERE, in memory, BEFORE the carried-home flush
    /// runs — an ordinary guard derefs its own `slot[ei]` (holds `shared_exit` while
    /// unarmed, a child body entry once 2.3c-1 arms it); a loop-done ordinary deopt uses
    /// `shared_exit` directly (its `slot[ei]` is the EXCLUSIVE linked exit, P-C option
    /// (b)). `deopt_exit` ends with `jmp qword [rdx+exit_target]`. Why a memory field
    /// and not a register: `flushSlot`'s spilled-payload path clobbers rax, so a
    /// register-staged holder would be destroyed by any spilled carried home before the
    /// jump; a `*NativeResult` field is flush-immune. Frameless production path only
    /// (the self-framed test page tears down + `ret`, never reading this). Pure scratch,
    /// not host-consumed; the wrapper inits it to 0 and every deopt exit overwrites it.
    exit_target: usize,
    /// 2.3c-2a (doc 17): per-transition ledger. A fused native span (`C→I→C→…` chained
    /// under the shared frame) returns ONE `NativeResult` whose scalar fields describe
    /// only the TERMINAL body; every intermediate exit is otherwise lost. Each
    /// exit-materialization (`emitLedgerAppend`, called by all four exit sites) appends
    /// one entry — parallel arrays indexed by `ledger_len` — so `runLinkedBurst` can
    /// replay the hops it never re-entered Zig to observe (2.3c-2b+ consume it; 2.3c-2a
    /// only writes + cross-checks the terminal entry against the scalar fields). Parallel
    /// (not array-of-struct) so the JIT indexes each lane with a native SIB scale — 8 for
    /// `ledger_cum`, 4 for the u32 lanes — with no ×stride multiply. `ledger_cum[i]` is
    /// the cumulative `rbx` counter at hop `i`, so a segment's OWN count is
    /// `ledger_cum[i] − ledger_cum[i-1]` (`− entry_rbx` for i==0). The Zig wrapper inits
    /// `ledger_len = 0` (arrays left `undefined`; only `[0..ledger_len]` is read). MUST
    /// stay LAST: every scalar field's `@offsetOf` is baked into the exit stubs, so
    /// appending here keeps them byte-identical.
    ledger_len: usize,
    ledger_cum: [trace_exec.LEDGER_CAP]usize,
    ledger_id: [trace_exec.LEDGER_CAP]u32,
    ledger_exit: [trace_exec.LEDGER_CAP]u32,
    ledger_reason: [trace_exec.LEDGER_CAP]u32,
    /// 2.3c-2c (doc 17): parallel `LedgerKind` lane — the exit-materialization SITE
    /// that appended each hop (one static constant per `emitLedgerAppend` caller).
    /// The generic `replayLedger` reads it to classify a hop's coherent-resume
    /// contract without re-deriving it from the trace IR. Like the other ledger
    /// lanes, appended AFTER the scalar fields so every baked scalar `@offsetOf` in
    /// the exit stubs stays byte-identical.
    ledger_kind: [trace_exec.LEDGER_CAP]u32,
    /// 2.3c-2c (doc 17): parallel `LedgerOutcome` lane — `.normal` for every entry by
    /// default (written by `emitLedgerAppend`), rewritten to `.yielded` by
    /// `emitForcedYieldCheck` when an armed chain source hits a full ledger. Lets
    /// `replayLedger` tell a forced yield apart from a natural terminal at the last
    /// entry. Appended last (after `ledger_kind`), same byte-identity rationale.
    ledger_outcome: [trace_exec.LEDGER_CAP]u32,
    // Doc 17 B-3 frozen tail. These stay unreachable/zero in B-3a: only a future
    // validated exit patch can enter a silent epilogue.
    silent_active: u64,
    silent_transitions: u64,
    silent_budget: u64,
    barren_budget: u64,
    silent_cell: u64,
    cur_zero_run: u64,
    silent_cum: u64,
    /// Round-6 exactness: the `*SilentExitMetadata` of the LAST promoted edge that
    /// fired in this call, overwritten by every silent epilogue. `silent_cell` keeps
    /// the FIRST (entry ownership); this keeps the terminal one. Zig derives the
    /// resume contract from this instead of reconstructing it as
    /// `(first_phase + transitions - 1) % len`, which silently assumed a strict
    /// round-robin that neither a repeated-parent ring nor two concurrently live
    /// promoted cycles obey.
    silent_last_cell: u64,
    /// Doc 44 D11: count of successful native self-call frame pushes this run
    /// (the `.terminal(self_call_interp)` push epilogue increments it after
    /// `nativeSelfCallPush` returns PUSH_OK). At the ABI TAIL by the frozen-
    /// offset rule: every scalar field's `@offsetOf` is baked into exit stubs,
    /// so this may only ever be appended, never inserted. The wrapper inits it
    /// to 0 and marshals it into `ExecResult.pushed_frames`.
    pushed_frames: u64,
    /// Doc 44 D12c / doc 54 P1: count of committed native frame pops this
    /// run (the `.terminal(return_interp)` pop epilogue increments it after
    /// the inline pop sequence falls through). Appended at the ABI tail like
    /// its push twin; the wrapper inits it to 0 and marshals it into
    /// `ExecResult.popped_frames`. The emitted sequence also READS both
    /// motion counters for its net-pushed floor.
    popped_frames: u64,
    /// Doc 45 D6: one-based `TraceCode.snapshots` index stamped by a precise
    /// exit (`.precise_resume` / `.precise_error`); 0 otherwise. Appended at
    /// the ABI tail by the frozen-offset rule (every scalar `@offsetOf` is
    /// baked into exit stubs — append only, never insert). The wrapper inits
    /// it to 0 and marshals it into `ExecResult.snapshot_id`.
    snapshot_id: u32,
    /// Doc 45 D6: raw `table_runtime.Status` ordinal from a failed allocating
    /// callout (nonzero ⟺ `exit_reason == .precise_error`). Stamped by the
    /// exit stub BEFORE any flush/ledger code (those clobber rax). Zero-init;
    /// marshaled into `ExecResult.runtime_error`.
    runtime_error: u32,
    /// Doc 45 D6: activation window of a precise exit. Always 0/0 while the
    /// precise recorder refuses frame inlining; the dispatcher asserts that.
    /// Zero-init; marshaled into `ExecResult.activation_base`/`_depth`.
    activation_base: u32,
    activation_depth: u32,
};

/// Host-staged bounds/state for a native call that may enter a promoted silent
/// cycle. Keeping these values together makes the wrapper initialization the
/// single ABI staging point for every native-call origin.
pub const SilentStaging = struct {
    silent_budget: u64 = 0,
    barren_budget: u64 = 0,
    cur_zero_run: u64 = 0,
};

/// The pre-B-3 ABI prefix, retained solely as a compile-time layout oracle. Appending
/// the silent tail must not move any existing ledger lane.
pub const NativeResultLedgerLayout = extern struct {
    completed: usize,
    exit_instr: u32,
    linked_loop_done: u64,
    final_trace_id: u32,
    entry_rbx: usize,
    exit_reason: u32,
    exit_target: usize,
    ledger_len: usize,
    ledger_cum: [trace_exec.LEDGER_CAP]usize,
    ledger_id: [trace_exec.LEDGER_CAP]u32,
    ledger_exit: [trace_exec.LEDGER_CAP]u32,
    ledger_reason: [trace_exec.LEDGER_CAP]u32,
    ledger_kind: [trace_exec.LEDGER_CAP]u32,
    ledger_outcome: [trace_exec.LEDGER_CAP]u32,
};

comptime {
    for (.{ "ledger_len", "ledger_cum", "ledger_id", "ledger_exit", "ledger_reason", "ledger_kind", "ledger_outcome" }) |field|
        std.debug.assert(@offsetOf(NativeResult, field) == @offsetOf(NativeResultLedgerLayout, field));
    std.debug.assert(@offsetOf(NativeResult, "silent_active") == @sizeOf(NativeResultLedgerLayout));
    std.debug.assert(@offsetOf(NativeResult, "silent_cum") == @offsetOf(NativeResult, "silent_active") + 6 * @sizeOf(u64));
    std.debug.assert(@offsetOf(NativeResult, "silent_last_cell") == @offsetOf(NativeResult, "silent_active") + 7 * @sizeOf(u64));
    // Doc 44 D11: `pushed_frames` is appended at the very tail — nothing that
    // was baked before it may have moved.
    std.debug.assert(@offsetOf(NativeResult, "pushed_frames") == @offsetOf(NativeResult, "silent_last_cell") + @sizeOf(u64));
    // Doc 44 D12c: `popped_frames` appended after its push twin, same rule.
    std.debug.assert(@offsetOf(NativeResult, "popped_frames") == @offsetOf(NativeResult, "pushed_frames") + @sizeOf(u64));
    // Doc 45 D6: the precise-exit quad is appended after the frame-motion
    // counters, same append-only rule — nothing baked before it may move.
    std.debug.assert(@offsetOf(NativeResult, "snapshot_id") == @offsetOf(NativeResult, "popped_frames") + @sizeOf(u64));
    std.debug.assert(@offsetOf(NativeResult, "runtime_error") == @offsetOf(NativeResult, "snapshot_id") + @sizeOf(u32));
    std.debug.assert(@offsetOf(NativeResult, "activation_base") == @offsetOf(NativeResult, "runtime_error") + @sizeOf(u32));
    std.debug.assert(@offsetOf(NativeResult, "activation_depth") == @offsetOf(NativeResult, "activation_base") + @sizeOf(u32));
}

pub const SilentSummaryCell = extern struct {
    region_work: u64,
    selection_work: u64,
    qualifying_rows: u64,
    productive_firings: u64,
    /// Dynamic local of this edge's most recent firing in the native call.
    last_local: u64,
    /// One-based silent-transition ordinal of this edge's most recent
    /// productive firing; zero means none in this call.
    last_productive_ordinal: u64,
    /// Round-6 exactness: how many times THIS edge fired in this call, counted by
    /// the epilogue itself. Replaces the derived `transitions/len + …` round-robin
    /// estimate, which is only valid when every trace owns exactly one phase of
    /// exactly one live ring — a property the detector does not enforce.
    firings: u64,
    /// One-based silent-transition ordinal of this edge's most recent firing
    /// (productive or not); zero means it never fired in this call.
    last_ordinal: u64,
};

comptime {
    std.debug.assert(@sizeOf(SilentSummaryCell) == 8 * @sizeOf(u64));
    std.debug.assert(@offsetOf(SilentSummaryCell, "productive_firings") == 3 * @sizeOf(u64));
    std.debug.assert(@offsetOf(SilentSummaryCell, "last_local") == 4 * @sizeOf(u64));
    std.debug.assert(@offsetOf(SilentSummaryCell, "last_productive_ordinal") == 5 * @sizeOf(u64));
    std.debug.assert(@offsetOf(SilentSummaryCell, "firings") == 6 * @sizeOf(u64));
    std.debug.assert(@offsetOf(SilentSummaryCell, "last_ordinal") == 7 * @sizeOf(u64));
}

/// Runtime-owned payload addressed through a compile-time-owned pointer cell. B-3a
/// freezes this transport; B-3b will allocate/populate instances before patching.
pub const SilentExitMetadata = extern struct {
    summary: *SilentSummaryCell,
    slot: *usize,
    min_useful: u64,
    reporting_target: usize,
    /// Doc 52 P1: nonzero for edges of a RESIDENT promoted set. Barren-run is
    /// an activation-decay detector; a resident set has no activation, so its
    /// firings must neither advance nor reset `cur_zero_run`. The epilogue
    /// branches around both the increment arms and the `reset_zero` store when
    /// this is set (data-driven — one code variant, per-edge metadata). The
    /// unconditional budget/barren tail compares still run for exempt edges
    /// and are provably harmless: every staged `cur_zero_run` is < the barren
    /// budget, and only an activation-edge increment can reach the bound.
    barren_exempt: u64,
};

pub const ExitPatchKind = enum(u8) { deopt, link_terminal, loop_done_linked, region_bridge };
/// Four dynamic return-continuation slots plus one continuation-to-head slot.
pub const RET_CONT_SLOTS: usize = 4;
pub const NATIVE_TRANSITION_SLOTS: usize = RET_CONT_SLOTS + 1;
pub const EXIT_NOP5 = [5]u8{ 0x0F, 0x1F, 0x44, 0x00, 0x00 };

pub const ExitPatch = struct {
    kind: ExitPatchKind,
    exit_instr: u32,
    patch_off: u32,
    original: [5]u8,
    epilogue_off: u32,
    metadata_cell: *usize,
};

/// Doc 22 §A.1b/§B.4: the page-owned seed plan — which of `t.inputs` this
/// compiled page actually consumes at entry. A committed `Trace` is immutable
/// (its `inputs` cannot be edited at analysis time), and the carried-heap
/// rewrite makes some recorded `hash_cell` seeds redundant: an `href` rooted at
/// a carried-heap slot re-resolves the CURRENT table's cell per iteration via
/// the `resolveHashCell` callout and never reads the entry-seeded slab slot.
/// Processing such a seed normally is worse than wasteful — its entry-table
/// validation could hash-decline the whole entry even though the emitted body
/// deliberately re-resolves per iteration. So compilation *deactivates* it here
/// instead. The Phase-B seeding helper (`NativeSeedCtx.seed_fn`) resolves only
/// active seeds (inactive slab slots stay unwritten), and "does this page seed
/// at entry" is defined as `plan.nonEmpty()` — never raw `inputs.len`.
/// Computed by `computeSeedPlan` for every compile; consumed by the Phase-B
/// entry prologue (inert until B-ii emits it).
pub const SeedPlan = struct {
    /// LSB-first bitmap over `t.inputs` indices; bit set ⇒ the seed is active.
    /// 64 bits bounds `inputs.len` for seeded pages (`computeSeedPlan` bails
    /// beyond it, fail closed — real traces carry a handful of inputs).
    bits: u64 = 0,

    pub fn nonEmpty(self: SeedPlan) bool {
        return self.bits != 0;
    }

    pub fn isActive(self: SeedPlan, i: usize) bool {
        return i < 64 and (self.bits >> @intCast(i)) & 1 != 0;
    }

    // pub for nativegen.zig's computeSeedPlan (file-split pass).
    pub fn activate(self: *SeedPlan, i: usize) void {
        self.bits |= @as(u64, 1) << @intCast(i);
    }
};

/// A compiled trace: an executable page whose entry is
/// `fn(tags: [*]u8, payloads: [*]u64, result: *NativeResult) callconv(.c) void` —
/// the SoA register file's two base pointers (tags in rdi, payloads in rsi), plus
/// an out-param in rdx for the committed iteration count and deterministic exit
/// instruction. Semantically identical to `irinterp.execute(t, regs, scratch)`.
pub const CompiledTrace = struct {
    page: ExecPage,
    /// Frameless dispatch (P-A / doc 17 Increment 2). `null` → the page is a
    /// self-framed function (test path via `compile`/`mapExecutable`), called
    /// directly as `EntryFn`. Non-null → the page is a frameless body; run it by
    /// calling this shared trampoline with `page.code.ptr` as the body_entry arg.
    trampoline_entry: ?usize = null,
    /// Link-slot table (doc 17 Increment 2.3), one 8-byte absolute target per IR
    /// instruction index. A chainable exit (`.link` terminal / linked-loop-done stub)
    /// jumps through `jmp qword [&slots[i]]`; the default value is the shared
    /// trampoline teardown (`shared_exit`), so an unarmed slot behaves exactly like
    /// 2.1's direct `jmp shared_exit`. `driveChain` arms a slot (2.3b+) by storing a
    /// child's frameless body entry into it — a plain data write (the array is
    /// ordinary GPA heap memory, always RW; no `mprotect`, no rel32 constraint since
    /// the exit loads the slot address as a full imm64). Empty for self-framed test
    /// pages (`trampoline_entry == null`). Owned; freed in `deinit` via `gpa`.
    slots: []usize = &.{},
    /// Resume-PC keys parallel to the four trailing `.ret_cont` cells. A zero
    /// target means unarmed; keys are metadata, never executable addresses.
    ret_cont_keys: []u32 = &.{},
    /// The allocator that owns `slots` (needed at `deinit`, which has no other handle
    /// to a gpa — the page frees itself through its own owner).
    gpa: std.mem.Allocator = undefined,
    /// Secondary entry point (doc 17 Increment 2.3b-0): absolute address of the
    /// `linked_entry` stub, which presets `NativeResult.linked_loop_done = 1` then
    /// falls through to `body_entry`. When a native parent arms a `.link`-terminal
    /// handoff into this trace (2.3b-1), the slot targets THIS address, not
    /// `page.code.ptr`, so the child materializes its numeric-for loop-done in linked
    /// mode (commit the final iteration) exactly as `runLinkedLoopDone` would — a bare
    /// jump to the body would leave `linked_loop_done = 0` and mis-deopt. `null` for
    /// self-framed test pages (never chained) and non-frameless builds. Points into
    /// the same owned `page`, so it needs no separate free.
    linked_entry: ?usize = null,
    /// Secondary entry point (doc 17 Increment 2.3c-0): the dual of `linked_entry`.
    /// Presets `NativeResult.linked_loop_done = 0` then falls through to `body_entry`.
    /// A FUSED handoff inherits whatever `linked_loop_done` sits in the shared
    /// `NativeResult` (rdx) — and `linked_entry` leaves it stuck at 1. The
    /// inner→continuation hop (2.3c-2) arms the inner's linked-loop-done slot into a
    /// continuation that must run in ORDINARY mode, so it targets THIS entry to clear
    /// the inherited flag; a bare jump to `body_entry` would let the continuation's own
    /// numeric-for loop-done guard wrongly take the linked-materialization path. `null`
    /// on the same builds as `linked_entry` (frameless production only). Points into
    /// the same owned `page`; no separate free. INERT until 2.3c-2 arms a slot to it.
    ordinary_entry: ?usize = null,
    /// B-3a patch descriptors and stable per-exit metadata pointer cells. The cells
    /// remain null and every epilogue unreachable until B-3b publishes promotion.
    exit_patches: []ExitPatch = &.{},
    metadata_cells: []usize = &.{},
    /// Doc 22 §B.4: which of the trace's `inputs` this page consumes at entry
    /// (see `SeedPlan`). Set by `compileImpl` for every page; "this page seeds
    /// at entry" is `seed_plan.nonEmpty()`, never raw `inputs.len`. The Phase-B
    /// invariant `seed_plan.nonEmpty() == seed_prologue` is release-asserted by
    /// `trace.TraceState.stubEnterable` at every arm/link gate (B-iv).
    seed_plan: SeedPlan = .{},
    /// Doc 22 §B.4: whether the emitted body actually carries the seed prologue,
    /// recorded at emission time (see `EntryStubs.seed_prologue`). Independent
    /// witness for the `seed_plan.nonEmpty() ⟺ prologue-present` invariant.
    seed_prologue: bool = false,
    /// Doc 44 D9: whether the ACTIVE seed plan contains a `.hash_cell` input —
    /// the only seed whose prologue can raise `seed_hash_decline` (the one
    /// decline needing the dispatcher's tier-1a rerun machinery;
    /// `nativeSeedFn` raises it solely while resolving an active hash cell,
    /// every other failure is a capacity decline). The quiet head episode
    /// refuses pages with this set. Computed from active PLAN bits, not raw
    /// `inputs` (an inactive hash cell never seeds).
    has_hash_seed: bool = false,
    /// Doc 39: the compiled trace is a PEELED root (`Trace.peeled`). Its first
    /// back-edge closes TWO tier-0 iterations (the run-once stabilizing pass +
    /// the first steady-state pass), so the run wrapper adds 1 to the reported
    /// `local_completed` whenever local progress is nonzero — mirroring
    /// irinterp's `completed += 1 + (peeled and completed == 0)` at `.loop`.
    peeled: bool = false,

    pub const EntryFn = fn ([*]u8, [*]u64, *NativeResult) callconv(.c) void;
    /// The shared frameless trampoline's C-ABI type: SoA lanes + result out-param,
    /// plus the body entry address in the 4th arg (rcx).
    pub const TrampolineFn = fn ([*]u8, [*]u64, *NativeResult, *const anyopaque) callconv(.c) void;

    /// Run the trace over the register file `regs` (mutated in place at each loop
    /// commit, exactly as the IR-interpreter does). Returns the committed-iteration
    /// count plus the failing IR instruction when native can identify it. The two
    /// lanes are passed as the SysV first two args (rdi=tags, rsi=payloads); the
    /// result pointer is the third (rdx), reserved out of the allocator pools.
    pub inline fn run(self: CompiledTrace, regs: RegWindow) trace_exec.ExecResult {
        return self.runWithLinkedLoopDone(regs, false, null, .{});
    }

    /// Run in the chain-consumed loop-done mode. Numeric-for loop-done exits commit
    /// the final iteration's post-guard stores and phi snapshot before returning,
    /// so the native nested-loop chainer can jump to the `.link` continuation
    /// without tier-0 replay.
    pub inline fn runLinkedLoopDone(self: CompiledTrace, regs: RegWindow) trace_exec.ExecResult {
        return self.runWithLinkedLoopDone(regs, true, null, .{});
    }

    /// 2.3c-2b (doc 17): like `run` (ordinary mode, `linked_loop_done = 0`) but ALSO
    /// decodes the native per-transition ledger into `ledger_out[0..ledger_len]`, so
    /// `runLinkedBurst` replays each fused `C→I` hop the terminal-only scalar fields
    /// hide instead of re-reading them. `ledger_out` must have room for `LEDGER_CAP`
    /// entries (the native append is bounds-guarded at that cap). The borrow is
    /// consumed immediately by the caller's replay — no native call / resize / nested
    /// replay may intervene between this capture and its consumption.
    pub inline fn runCapturingLedger(self: CompiledTrace, regs: RegWindow, ledger_out: []trace_exec.LedgerEntry, silent: SilentStaging) trace_exec.ExecResult {
        return self.runWithLinkedLoopDone(regs, false, ledger_out, silent);
    }

    /// 2.3c-2d (D1): the LINKED-mode counterpart of `runCapturingLedger`. Call A
    /// (`runLinkedBurst`'s first inner drive, trace.zig) needs the chain-consumed
    /// loop-done materialization (`linked_loop_done = 1`: the final inner iteration's
    /// post-guard stores + phi snapshot are committed so regs are coherent at the
    /// continuation anchor) AND the per-transition ledger. A literal `runCapturingLedger`
    /// swap would flip the mode to ordinary (0) and leave the final iteration for tier-0
    /// replay, corrupting the coherent resume — so capture MUST preserve the mode. Same
    /// borrow contract as `runCapturingLedger`: `ledger_out` holds `LEDGER_CAP` entries
    /// and is consumed immediately, with no intervening native call.
    pub inline fn runLinkedLoopDoneCapturing(self: CompiledTrace, regs: RegWindow, ledger_out: []trace_exec.LedgerEntry, silent: SilentStaging) trace_exec.ExecResult {
        return self.runWithLinkedLoopDone(regs, true, ledger_out, silent);
    }

    /// Task #28 (doc 45 seam overhead): this wrapper and the four public
    /// entries above are FORCED inline. The ~1.3KB `NativeResult` stack init
    /// and the `ExecResult` marshal are only cheap when LLVM can scalarize
    /// and dead-store-eliminate them per call site (constant `linked_loop_done`
    /// / `ledger_out` / `silent` at every caller); when the doc-45 D6 code
    /// growth pushed this out of the cost model's inline budget at the
    /// dispatcher's hottest call site, the out-of-line copy alone cost ~250M
    /// cycles per binary-trees run (~+9% wall). Both levels must stay inline:
    /// forcing only the inner fn would just move the call boundary to the
    /// ~1KB public wrappers.
    inline fn runWithLinkedLoopDone(self: CompiledTrace, regs: RegWindow, linked_loop_done: bool, ledger_out: ?[]trace_exec.LedgerEntry, silent: SilentStaging) trace_exec.ExecResult {
        var result = NativeResult{
            .completed = 0,
            .exit_instr = std.math.maxInt(u32),
            .linked_loop_done = if (linked_loop_done) 1 else 0,
            .final_trace_id = trace_exec.NO_TRACE_ID,
            .entry_rbx = 0,
            .exit_reason = @intFromEnum(trace_exec.ExitReason.normal),
            .exit_target = 0,
            // 2.3c-2a: fresh span → zero recorded transitions. Arrays stay `undefined`;
            // only `[0..ledger_len]` is ever read, and every appended slot is fully
            // written by `emitLedgerAppend` before `ledger_len` counts it.
            .ledger_len = 0,
            .ledger_cum = undefined,
            .ledger_id = undefined,
            .ledger_exit = undefined,
            .ledger_reason = undefined,
            .ledger_kind = undefined,
            .ledger_outcome = undefined,
            .silent_active = 0,
            .silent_transitions = 0,
            .silent_budget = silent.silent_budget,
            .barren_budget = silent.barren_budget,
            .silent_cell = 0,
            .cur_zero_run = silent.cur_zero_run,
            .silent_cum = 0,
            .silent_last_cell = 0,
            .pushed_frames = 0,
            .popped_frames = 0,
            .snapshot_id = 0,
            .runtime_error = 0,
            .activation_base = 0,
            .activation_depth = 0,
        };
        if (self.trampoline_entry) |tramp| {
            const f: *const TrampolineFn = @ptrFromInt(tramp);
            f(regs.tags, regs.payloads, &result, self.page.code.ptr);
        } else {
            self.page.entry(EntryFn)(regs.tags, regs.payloads, &result);
        }
        // 2.3b-0/2.3b-1: the final trace's OWN committed count = cumulative rbx − the
        // rbx it inherited at entry. `-%` because a spurious wrap is never worse than the
        // old behaviour and there is no valid case where entry_rbx > completed. Before
        // 2.3b-1 armed a slot, every body was entered fresh (rbx = 0 → entry_rbx = 0) and
        // this equalled `completed`; now that a parent `.link` slot can `jmp` straight
        // into a child under the shared frame, the fused child inherits the parent's
        // cumulative `rbx`, so `entry_rbx > 0` is the expected steady state and the old
        // `assert(entry_rbx == 0)` no longer holds.
        const local: usize = blk: {
            const raw = result.completed -% result.entry_rbx;
            // Doc 39: a peeled trace's first back-edge closes TWO tier-0
            // iterations (run-once pass + first steady pass) but increments rbx
            // once, so nonzero local progress under-counts by exactly 1. Add it
            // back HERE — the seam where tier-1a's contract (irinterp bakes the
            // +1 into its returned `completed`) meets native's raw rbx delta —
            // so every consumer sees the same iteration accounting on both
            // tiers. `result.completed` itself stays the raw chain-cumulative
            // rbx (the ledger asserts below compare raw values); peeled traces
            // are excluded from fusion (armNativeLink refuses them), so the
            // raw/adjusted split never crosses a chain boundary. Zero local
            // progress stays zero: an exit before the first back-edge replays
            // both partial iterations on tier-0.
            break :blk if (self.peeled and raw > 0) raw + 1 else raw;
        };
        // 2.3c-2a: the per-transition ledger's TERMINAL entry must reproduce the scalar
        // result fields. The ledger's whole reason to exist — recover the HIDDEN
        // intermediate hops a fused span drops — is only trustworthy if its last entry
        // agrees with the body that actually returned. A debug tripwire while the drain
        // still reads scalar fields (2.3c-2b flips the drain to consume the ledger
        // authoritatively); it proves the append fired (`ledger_len ≥ 1`), stayed in
        // bounds, and that the scale-8 `ledger_cum` store landed at the right index with
        // `rbx`. Native only (tier-1a never enters this wrapper).
        if (std.debug.runtime_safety) {
            const n = result.ledger_len;
            std.debug.assert(n <= trace_exec.LEDGER_CAP);
            std.debug.assert(result.silent_active != 0 or n >= 1);
            if (n != 0) {
                std.debug.assert(result.ledger_cum[n - 1] == result.completed);
                std.debug.assert(result.ledger_id[n - 1] == result.final_trace_id);
                std.debug.assert(result.ledger_exit[n - 1] == result.exit_instr);
                std.debug.assert(result.ledger_reason[n - 1] == result.exit_reason);
                // 2.3c-2c: the site tag must agree with the scalar reason on the only
                // axis the scalar fields expose — each non-`.normal` reason ⟺ its
                // matching terminal site (prologue_fail, and doc 22 §B.2's two seed
                // declines), and vice-versa. (link_terminal / loop_done_linked /
                // deopt all carry reason `.normal`, so the ledger `kind` is what tells them
                // apart; nothing scalar cross-checks those three yet — the generic replay
                // validates them structurally in 2.3c-2c.)
                const term_kind: trace_exec.LedgerKind = @enumFromInt(result.ledger_kind[n - 1]);
                std.debug.assert((result.exit_reason == @intFromEnum(trace_exec.ExitReason.prologue_fail)) ==
                    (term_kind == .prologue_fail));
                std.debug.assert((result.exit_reason == @intFromEnum(trace_exec.ExitReason.seed_hash_decline)) ==
                    (term_kind == .seed_hash_decline));
                std.debug.assert((result.exit_reason == @intFromEnum(trace_exec.ExitReason.seed_capacity_decline)) ==
                    (term_kind == .seed_capacity_decline));
                // Doc 45 D6: the precise reasons are likewise site-paired —
                // each terminal tail stamps its reason then appends its own
                // kind — and always carry a one-based snapshot id.
                std.debug.assert((result.exit_reason == @intFromEnum(trace_exec.ExitReason.precise_resume)) ==
                    (term_kind == .precise_deopt));
                std.debug.assert((result.exit_reason == @intFromEnum(trace_exec.ExitReason.precise_error)) ==
                    (term_kind == .precise_error));
                if (term_kind == .precise_deopt or term_kind == .precise_error)
                    std.debug.assert(result.snapshot_id >= 1);
            }
        }
        // 2.3c-2b: decode the per-transition ledger for the caller's replay. Only
        // `[0..ledger_len]` is meaningful; the append fully writes every counted slot.
        if (ledger_out) |out| {
            std.debug.assert(out.len >= result.ledger_len);
            var k: usize = 0;
            while (k < result.ledger_len) : (k += 1) {
                out[k] = .{
                    .cum = result.ledger_cum[k],
                    .id = result.ledger_id[k],
                    .exit = result.ledger_exit[k],
                    .reason = @enumFromInt(result.ledger_reason[k]),
                    .kind = @enumFromInt(result.ledger_kind[k]),
                    .outcome = @enumFromInt(result.ledger_outcome[k]),
                };
            }
        }
        return .{
            .completed = result.completed,
            .exit_instr = result.exit_instr,
            .final_trace_id = result.final_trace_id,
            .local_completed = local,
            .exit_reason = @enumFromInt(result.exit_reason),
            .ledger_len = result.ledger_len,
            .silent_active = result.silent_active,
            .silent_transitions = result.silent_transitions,
            .silent_budget = result.silent_budget,
            .barren_budget = result.barren_budget,
            .silent_cell = result.silent_cell,
            .cur_zero_run = result.cur_zero_run,
            .silent_cum = result.silent_cum,
            .silent_last_cell = result.silent_last_cell,
            .pushed_frames = result.pushed_frames,
            .popped_frames = result.popped_frames,
            .snapshot_id = result.snapshot_id,
            .runtime_error = result.runtime_error,
            .activation_base = result.activation_base,
            .activation_depth = result.activation_depth,
        };
    }

    pub fn pageGeneration(self: *const CompiledTrace) ?u64 {
        return switch (self.page.owner) {
            .arena => |slot| slot.generation,
            .owned => null,
        };
    }

    pub fn deinit(self: *CompiledTrace) void {
        self.page.deinit();
        if (self.slots.len > 0) self.gpa.free(self.slots);
        if (self.ret_cont_keys.len > 0) self.gpa.free(self.ret_cont_keys);
        if (self.exit_patches.len > 0) self.gpa.free(self.exit_patches);
        if (self.metadata_cells.len > 0) self.gpa.free(self.metadata_cells);
        self.* = undefined;
    }
};

/// Per-trace memoized native-codegen status (a tri-state, so "not yet attempted"
/// never aliases "known unsupported"). Lives on the cached `Trace`; lazily resolved
/// on the first native dispatch and then terminal — a `.compiled` page runs forever,
/// an `.unsupported` trace stays on tier-1a forever. Runtime-only (not serialized).
pub const NativeState = union(enum) {
    /// Native compilation has not been attempted yet.
    unattempted,
    /// The trace is outside the proven-int/bool subset (or this is an off-target
    /// build): it runs on the tier-1a IR-interpreter. Never retried.
    unsupported,
    /// Successfully lowered to an executable page.
    compiled: CompiledTrace,

    /// Free any owned executable page and reset to `unattempted`.
    pub fn deinit(self: *NativeState) void {
        switch (self.*) {
            .compiled => |*c| c.deinit(),
            .unattempted, .unsupported => {},
        }
        self.* = .unattempted;
    }
};
