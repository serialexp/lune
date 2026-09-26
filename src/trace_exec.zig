//! Executor-independent semantic results for trace execution.
//!
//! Both tier-1a and tier-1b produce this contract. Native's layout-pinned extern
//! transport and its explicit decoding remain in `nativegen.zig`.

const std = @import("std");

/// Sentinel `final_trace_id`: "no chain-final trace was identified" — a tier-1a
/// result (which always belongs to the entered trace) or a native result whose
/// exit stub somehow didn't write the id. The dispatcher resolves it to the entered
/// trace `ct`. `maxInt(u32)` is unreachable as a real `Trace.id` (a session never
/// records 4 billion traces).
pub const NO_TRACE_ID: u32 = std.math.maxInt(u32);

/// Why a (possibly chained) native run left its final body. Distinct from
/// `exit_instr` because `exit_instr == maxInt` is overloaded: on tier-1a it means
/// "ran to natural completion" (a real, productive exit), while on native it is ALSO
/// baked by `prologue_fail` (a hoisted entry-type guard failed BEFORE the body
/// committed any of its own iterations — no guard identity, zero local progress).
/// 2.3c-0b (doc 17) splits those apart so the dispatcher/`driveChain` can model a
/// chained child that prologue-fails after the parent committed as three independent
/// facts (final = child, `local_completed == 0`, chain `completed > 0`) instead of
/// re-deriving intent from the `maxInt` artifact. Backed `u32` so it matches the
/// JIT-emitted `movMemImm32` store into `NativeResult`.
pub const ExitReason = enum(u32) {
    /// A guard / terminal / loop-done exit with a valid `exit_instr`, OR a tier-1a
    /// clean loop completion (`exit_instr == maxInt`, `completed > 0`). In every case
    /// `exit_instr`/`completed` mean exactly what they say.
    normal = 0,
    /// Native only: a hoisted entry-type guard failed pre-commit. `exit_instr` carries
    /// no guard identity (`maxInt`); `local_completed == 0` even when the enclosing
    /// chain holds nonzero cumulative progress in `completed`.
    prologue_fail = 1,
    /// Doc 22 §B.2, native only: a seeded page's entry prologue called the seeding
    /// twin (`nativeSeedFn`) and a `hash_cell` seed failed validation (metatable
    /// appeared, key vanished, population drifted). The slab holds exactly the state
    /// VM-side seeding leaves on the same failure (the 0-bits cell slot IS written),
    /// so the dispatcher reruns THIS entry on tier-1a — same shape as the pre-B-ii
    /// `native_eligible = false` route. Like `prologue_fail`: no guard identity
    /// (`exit_instr == maxInt`), zero local progress. No strike is charged.
    seed_hash_decline = 2,
    /// Doc 22 §B.2, native only: the seeding twin declined before ANY slab write
    /// because the seed slots don't fit the register slab (`base + count >
    /// capacity`). The candidate itself is unusable at this depth — the dispatcher
    /// moves to the next candidate (the native analogue of `seedTraceInputs`
    /// returning null). No guard identity, zero local progress, no strike.
    seed_capacity_decline = 3,
    /// Doc 45 D6: a guard/arith failure in a PRECISE trace (`deopt_mode ==
    /// .precise`) whose failing IR op carries a nonzero per-bytecode snapshot.
    /// The executor has ALREADY materialized the snapshot into the guest
    /// registers before returning; `snapshot_id` names the one-based record
    /// whose `resume_pc` tier-0 must resume at. Never chainable, never a
    /// side-trace want, never an entry-replay fallback — the dispatcher
    /// validates and resumes, nothing else. (A precise trace's PROLOGUE
    /// failure — `IrInstr.snap == 0`, iteration-entry coherent — stays
    /// `.normal`: the ordinary entry contract applies.)
    precise_resume = 4,
    /// Doc 45 D5/D6: a runtime error (OOM/type) raised by a precise trace's
    /// effect helper (`table_runtime.tnew` today). The executor has ALREADY
    /// materialized the failing op's snapshot into the guest registers
    /// (pre-instruction state); `snapshot_id` names it and `runtime_error`
    /// carries the shim's `table_runtime.Status` ordinal. The dispatcher
    /// parks the ACTUAL error at the snapshot's `resume_pc` — the partial
    /// heap of the iteration's earlier effects is preserved (D5), the
    /// operation is never retried (execute-once), and no strike/receipt/
    /// chain/side-trace accounting runs (the error is about to unwind).
    precise_error = 5,
    /// Doc 56 §4.1/§4.4 (Phase 3 tier-1a, Phase 4 native): an ORDINARY
    /// trace's guard failed at an exit that is wanted or attached
    /// (`TraceRecord.exit_side`; natively, a published exit adapter), and the
    /// executor took the resume-coherent contract. It has ALREADY
    /// applied the earlier bytecodes' sunk stores and written the exit
    /// snapshot's slots, so the guest registers are the tier-0 state at the
    /// exit's resume pc `P` (`TraceCode.exitResumePc(exit_instr)`), not at
    /// the anchor. The dispatcher resumes (or chains) at `P` and never
    /// re-runs the iteration from the anchor.
    exit_side = 6,
};

/// 2.3c-2a (doc 17): capacity of the per-transition native ledger carried in
/// `NativeResult`. A fused native span (`C→I→C→…` chained under the shared frame)
/// returns ONE result whose scalar fields describe only the TERMINAL body; every
/// intermediate exit is otherwise unrecoverable. Each exit-materialization appends
/// one entry so `runLinkedBurst` can replay the hops it never re-entered Zig to
/// observe. Sized to cover the burst-hop bound (≤9 enclosing iterations × 2
/// transitions/iteration = 18) in a single native span so the common closed-cycle
/// case never forces an early yield; the native append is bounds-guarded, so an
/// over-long span drops the overflow entry (2.3c-2a/b, no cycle → never reached) or,
/// once 2.3c-2c closes the cycle, a chain-source forces a yield to `shared_exit`.
pub const LEDGER_CAP: usize = 32;

/// Doc 54 P2: per-episode frame-motion transition budget — the blackout
/// bound that replaces `LEDGER_CAP` for ROW-FREE frame-motion cycles (rows
/// mode keeps the cap). Initialized into `NativeResult.descent_budget` by
/// the run wrapper for every native episode; every frame-motion sequence
/// (inline push — same-page or cont — and inline pop) decrements-and-tests
/// it PRE-mutation, and at zero takes its ordinary decline path (plain
/// terminal exit, outcome `.normal`, no frame mutated — already legal
/// grammar at every site). A pure function of the deterministic transition
/// stream: replay-stable, 8-mode-invisible (it moves WHERE code runs,
/// never what it computes).
pub const DESCENT_BUDGET: u32 = 65_536;

/// Result of executing a trace.
pub const ExecResult = struct {
    /// Tier-1a: completed guest iterations. Native: raw chain-cumulative back-edge
    /// count, also used by the ledger. For a peeled native trace, local_completed
    /// includes the run-once iteration whereas this raw counter does not.
    completed: usize,
    /// Index of the failing IR instruction when completed==0 (guard/arith
    /// failure). `maxInt(u32)` means the trace ran to completion with no
    /// failure (completed > 0).
    exit_instr: u32,
    /// P-B (doc 17): the stable `Trace.id` of the trace that performed the FINAL
    /// exit of the (possibly chained) native run. Native bakes this per exit stub;
    /// tier-1a leaves it at `NO_TRACE_ID` (a single `execute` call always belongs to
    /// the entered trace). Defaulted so the ~40 tier-1a construction sites are
    /// untouched. The dispatcher maps `(final_trace_id, exit_instr)` → the final
    /// trace; with no linking yet this is always the entered trace.
    final_trace_id: u32 = NO_TRACE_ID,
    /// 2.3b-0 (doc 17): iterations committed by the FINAL trace's OWN loop, as
    /// opposed to `completed` which is the chain-cumulative count (`rbx`). Native
    /// derives its raw count as `completed − entry_rbx`, where `entry_rbx` is the
    /// value at final-body entry. For peeled code, nonzero raw progress gains one
    /// guest iteration for the run-once region. Unchained, non-peeled executions
    /// have equal local and cumulative counts. A child entered under the shared
    /// frame inherits its parent's `rbx`, and the accounting that steers
    /// recording (`onSideExit`) must use this local count, never the inflated
    /// cumulative one. Defaulted to 0 so the ~40 tier-1a construction sites are
    /// untouched; `local_completed` is only ever READ on the native chained path
    /// (`driveChain`, `tier == .native_only`) — the tier-1a chain path reads
    /// `completed` directly (a single `execute` is never fused, so its local count IS
    /// its `completed`).
    local_completed: usize = 0,
    /// 2.3c-0b (doc 17): why the final body exited, disambiguating the overloaded
    /// `exit_instr == maxInt`. Native marshals it from `NativeResult.exit_reason`;
    /// tier-1a leaves it `.normal` (a single `execute` either takes a real guard exit
    /// or completes cleanly — it has no hoisted-entry-guard prologue to fail).
    /// Defaulted so the ~40 tier-1a construction sites are untouched; only ever READ on
    /// the native chained path (`driveChain`, `tier == .native_only`).
    exit_reason: ExitReason = .normal,
    /// Doc 45 D6: one-based index into `TraceCode.snapshots` selecting the
    /// snapshot the executor materialized for a `.precise_resume` exit; the
    /// dispatcher resumes tier-0 at that record's `resume_pc`. 0 (defaulted,
    /// construction sites untouched) everywhere else — legacy exits, precise
    /// prologue failures, terminals. Tier-1a fills it at its shared exit
    /// point; the native exit stubs will bake it when the native precise
    /// executor lands (doc 45 D6, outstanding).
    snapshot_id: u32 = 0,
    /// Doc 45 D5: the `table_runtime.Status` ordinal of the effect-shim
    /// failure behind a `.precise_error` exit (nonzero there, 0 everywhere
    /// else). Kept as the raw C-ABI status — the dispatcher owns the
    /// status→`Error` mapping — so the future native exit stub can bake the
    /// shim's return register verbatim.
    runtime_error: u32 = 0,
    /// Doc 45 D6 activation contract for precise exits: the frame-window
    /// base and inlined-frame depth the snapshot's slots are relative to.
    /// P2 precise recording refuses frame inlining outright, so tier-1a
    /// always reports the anchor activation (base 0, depth 0) and the
    /// dispatcher asserts exactly that before consuming a precise exit —
    /// the fields exist so the assert (and the wire shape the native
    /// executor will fill) is explicit rather than implied.
    activation_base: u32 = 0,
    activation_depth: u32 = 0,
    /// 2.3c-2a (doc 17): number of exit-materializations the (possibly fused) native
    /// span recorded in `NativeResult`'s per-transition ledger. 1 for an un-fused run;
    /// >1 when an armed slot chained bodies under the shared frame (a `C→I` `.link`
    /// fusion records 2 — C's terminal exit then I's). In 2.3c-2a the ledger ENTRIES
    /// are not carried here (the drain still reads scalar fields); `runLinkedBurst`
    /// consumes them in 2.3c-2b. Native only — tier-1a leaves it 0 (defaulted, so the
    /// ~40 tier-1a construction sites are untouched).
    ledger_len: usize = 0,
    /// Doc 17 B-3 frozen silent-burst ABI. Tier-1a and B-3a native runs leave these
    /// zero; B-3b will consume them through the universal native-result drain.
    silent_active: u64 = 0,
    silent_transitions: u64 = 0,
    silent_budget: u64 = 0,
    barren_budget: u64 = 0,
    silent_cell: u64 = 0,
    cur_zero_run: u64 = 0,
    silent_cum: u64 = 0,
    /// Address of the `SilentExitMetadata` of the LAST promoted edge that fired.
    /// Round-6 exactness: the terminal edge is measured, never reconstructed from
    /// the transition count (see `TraceState.silentCellOwner`).
    silent_last_cell: u64 = 0,
    /// Doc 44 D11 / doc 54: how many REAL VM frames the native run pushed via
    /// the inline self-call push sequence. Nonzero breaks the old
    /// episode invariant "a native run never changes the VM frame stack":
    /// BOTH dispatcher consumers must branch on it FIRST — before the silent
    /// drain, the seed-decline handlers, the D10 burst consumer, and every
    /// scalar head consumer — because those all reason against the ENTRY
    /// activation while the top frame is now the descent's leaf. Native only;
    /// tier-1a leaves it 0 (defaulted, construction sites untouched).
    pushed_frames: u64 = 0,
    /// Doc 44 D12c / doc 54 P1: how many episode-pushed frames the native
    /// run popped back via the inline pop sequence. The net floor
    /// (`popped < pushed` at every pop, emitted inline) makes
    /// `popped_frames > 0` imply `pushed_frames > 0`, so the dispatchers'
    /// existing pushed-frame branch already routes every frame-motion result.
    /// Native only; tier-1a leaves it 0.
    popped_frames: u64 = 0,
    /// Doc 54 P2: the episode took at least one ROW-FREE cross-page
    /// frame-motion transition (`.ret_cont`/`.call_head` armed hit with an
    /// empty ledger). Selects the totals path in `consumePushedDescent`:
    /// the ledger is then always empty-plus-final (zero intermediate rows;
    /// the final row's owner is the exiting page, NOT the entered trace),
    /// and the per-slot hit counters published to the seed ctx's touched
    /// list carry the transition counts. Implies `pushed_frames > 0`
    /// (asserted at the marshal). Native only; tier-1a leaves it false.
    frame_motion_taken: bool = false,
};

/// 2.3c-2c (doc 17): which exit-materialization SITE appended a ledger entry —
/// the static discriminator the generic `replayLedger` needs to classify a hop's
/// coherent-resume contract without re-deriving it from the trace IR. There is
/// exactly one value per native exit-materialization site (see `emitLedgerAppend`
/// callers in `nativegen.zig`); the append bakes the site's compile-time constant.
/// Finer distinctions WITHIN `.deopt` (ordinary source-branch guard vs. ordinary
/// numeric-for loop-done vs. plain mid-loop guard) stay derived from `exit` + the
/// trace IR (`guardExitPc` + `for_loop`) exactly as the ≤2-entry drain does today —
/// they all share one emit site and one resume contract (tier-0 at the exit PC), so
/// they need no separate kind.
pub const LedgerKind = enum(u32) {
    /// `.link` terminal hand-off (single-contract). Chain source when its slot is
    /// armed; the linked child is the inner root at `.link.aux`. Regs coherent at
    /// that inner PC.
    link_terminal = 0,
    /// Numeric-`for` loop-done, LINKED materialization (mode 1): the final iteration's
    /// post-guard stores + phi snapshot were committed, so regs are coherent at the
    /// continuation anchor PC. Chain source when its `slot[ei]` is armed (2.3c-2c).
    loop_done_linked = 1,
    /// The shared `deopt_exit` flush: an ordinary per-guard side exit, an ordinary
    /// (mode 0) numeric-`for` loop-done deopt, or a plain mid-loop guard. Regs coherent
    /// at the guard's exit PC for tier-0 replay. Chain source when the mini-stub's
    /// `slot[ei]` is armed (2.3c-1, source-branch guards).
    deopt = 2,
    /// A hoisted entry-type guard failed pre-commit (`exit_instr = -1`,
    /// `reason = .prologue_fail`). Always terminal — never a chain source.
    prologue_fail = 3,
    /// Part A-v (doc 17): a composite-guard bridge committed the parent trace's
    /// dominating phi updates before handing off to an outer-loop successor.
    /// A-v emits this site but never arms it, so no runtime ledger can contain
    /// this kind until A-vii lands the arm and replay contract.
    region_bridge = 4,
    /// Doc 22 §B.2: a seeded page's entry prologue declined on `hash_cell`
    /// validation (`reason = .seed_hash_decline`, `exit_instr = -1`). Always
    /// terminal — the decline happens before the body runs, never a chain source.
    seed_hash_decline = 5,
    /// Doc 22 §B.2: a seeded page's entry prologue declined on slab capacity
    /// (`reason = .seed_capacity_decline`, `exit_instr = -1`, nothing written).
    /// Always terminal.
    seed_capacity_decline = 6,
    /// Doc 44 P0: a head trace's `.terminal` completion — the one-shot φ
    /// writeback committed and tier-0 resumes at the terminal's resume pc.
    /// Always a natural terminal, never a chain source (the dispatcher's
    /// terminal consumer owns resumption; no slot indirection is emitted).
    head_terminal = 7,
    /// Doc 44 D12c: a `.terminal(return_interp)` whose native pop epilogue
    /// COMMITTED (doc 54 P1: the inline sequence): the episode popped one
    /// of its own pushed frames, so the top frame is the popped-into CALLER
    /// and regs are coherent at its frozen one-past-call cursor. With no
    /// `.ret_cont` links armed yet this row is always FINAL (the pop exits
    /// plain); once links land it doubles as the transition row for a pop
    /// that dispatched into a cont page. A DECLINED pop appends the ordinary
    /// `head_terminal` row instead — the two kinds are what let the
    /// dispatcher's motion consumer tell "resume the caller at its cursor"
    /// from "re-execute the leaf's ret at `term.aux`".
    ret_pop = 8,
    /// A continuation page committed a native self-call push and dispatched
    /// through its `.call_head` link into the proto's head page.
    call_push = 9,
    /// Doc 45 D6: a precise trace's guard failed — the per-snapshot
    /// materializer restored the anchor window from the guard's captured
    /// snapshot refs and the body exits `.precise_resume` with the one-based
    /// `snapshot_id` stamped. Always terminal — a precise exit is never a
    /// chain source (no slot indirection, no patch window).
    precise_deopt = 10,
    /// Doc 45 D6: a precise trace's allocating callout FAILED (nonzero
    /// `table_runtime.Status`) — snapshot restored, `runtime_error` stamped,
    /// body exits `.precise_error`. Always terminal; the dispatcher parks the
    /// mapped error at the snapshot's `resume_pc` without re-execution.
    precise_error = 11,
    /// Doc 56 Phase 4: a native exit adapter materialized the tier-0 state at
    /// the exit's resume pc `P` (`reason = .exit_side`): the earlier
    /// bytecodes' sunk stores, the carried homes and the exit snapshot. The
    /// interrupted iteration is committed forward up to `P`. Always terminal
    /// in Phase 4 (the adapter returns to the runtime) and only ever written
    /// by the dispatcher's direct entry with an empty ledger, so no chain
    /// ledger can contain it until Phase 5 adds the direct jump and its
    /// replay arm.
    exit_side = 12,

    /// Whether a row of this kind proves the burst COMMITTED guest work at
    /// that exit, independent of the `cum` back-edge counter. `cum` counts
    /// only taken loop back-edges, so a segment that ran a body and then
    /// committed through a completion exit — a one-trip loop's
    /// `loop_done_linked`, a continuation page's `link_terminal` — advances
    /// the guest while leaving `cum` flat. Zero-progress detectors must
    /// count these rows as progress (doc 55 §1). Conservative: a kind that
    /// commits nothing (`.deopt` re-runs its iteration in tier 0; the
    /// declines run no body) or only commits partially (`.precise_*`) is
    /// NOT proof. A `.deopt` row proves progress on its own only through
    /// `cum`; the detector still credits a later committing row in its suffix.
    pub fn commitsGuestWork(self: LedgerKind) bool {
        return switch (self) {
            .link_terminal,
            .loop_done_linked,
            .region_bridge,
            .head_terminal,
            .ret_pop,
            .call_push,
            // The interrupted iteration is committed forward up to `P`.
            .exit_side,
            => true,
            .deopt,
            .prologue_fail,
            .seed_hash_decline,
            .seed_capacity_decline,
            .precise_deopt,
            .precise_error,
            => false,
        };
    }
};

/// 2.3c-2c (doc 17): what a chain-source exit DID with its (possibly armed) slot —
/// the signal the generic `replayLedger` needs to tell a forced yield apart from a
/// natural terminal, which position alone cannot (both are the LAST ledger entry).
/// Only `.yielded` is stamped at runtime (in the static forced-yield branch of
/// `emitForcedYieldCheck`); `.normal` is the default every append writes.
/// `.normal` is deliberately two-in-one — a non-final `.normal` entry DISPATCHED
/// (an armed slot carried control into the successor recorded next), a final
/// `.normal` entry is a natural TERMINAL (unarmed → `shared_exit`, or a plain
/// deopt/prologue-fail). Replay disambiguates those two by position; the successor-
/// adjacency validation (2.3c-2c) is what makes the positional inference sound.
pub const LedgerOutcome = enum(u32) {
    /// Dispatched into a successor (non-final) OR a natural terminal (final).
    normal = 0,
    /// Forced yield: an ARMED chain source hit a full ledger (`ledger_len == CAP`)
    /// and jumped to `shared_exit` instead of its child, bounding the closed cycle.
    /// The cycle may not be finished — the driver re-enters at the coherent resume
    /// PC to continue it.
    yielded = 1,
};

/// 2.3c-2b (doc 17): one decoded entry from the native per-transition ledger. A
/// fused native span returns ONE `NativeResult` whose scalar fields describe only
/// the TERMINAL body; `runLinkedBurst` copies the parallel `ledger_*[0..ledger_len]`
/// arrays into a `TraceState`-owned scratch of these (via `runCapturingLedger`) and
/// replays each recorded hop instead of reading the terminal-only scalars. `cum` is
/// the cumulative `rbx` at that exit; the per-segment local of entry `i` is
/// `cum[i] − cum[i-1]` (`cum[-1] = 0`, the trampoline-zeroed call-start `rbx`).
pub const LedgerEntry = struct {
    /// Cumulative `rbx` (enclosing-iteration counter) at this exit.
    cum: usize,
    /// `Trace.id` whose body performed this exit.
    id: u32,
    /// That exit's `exit_instr` (`maxInt(u32)` for a prologue fail).
    exit: u32,
    /// Why the body exited (`.normal` / `.prologue_fail`).
    reason: ExitReason,
    /// 2.3c-2c: the exit-materialization site that appended this entry. Written by
    /// `emitLedgerAppend` from a per-site compile-time constant; only READ by the
    /// generic `replayLedger` (2.3c-2c) — inert until then.
    kind: LedgerKind = .deopt,
    /// 2.3c-2c: whether this exit force-yielded. Default `.normal`; the forced-yield
    /// branch stamps `.yielded`. Only READ by the generic `replayLedger` — inert
    /// until the cycle can fill the ledger (2.3c-2e).
    outcome: LedgerOutcome = .normal,
};

test "execution contract defaults" {
    const result = ExecResult{ .completed = 3, .exit_instr = 7 };
    try std.testing.expectEqual(NO_TRACE_ID, result.final_trace_id);
    try std.testing.expectEqual(@as(usize, 0), result.local_completed);
    try std.testing.expectEqual(ExitReason.normal, result.exit_reason);
    try std.testing.expectEqual(@as(usize, 0), result.ledger_len);
    try std.testing.expectEqual(@as(u64, 0), result.silent_last_cell);

    const entry = LedgerEntry{ .cum = 3, .id = 11, .exit = 7, .reason = .normal };
    try std.testing.expectEqual(LedgerKind.deopt, entry.kind);
    try std.testing.expectEqual(LedgerOutcome.normal, entry.outcome);
}

test "execution contract wire ordinals and capacity" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(ExitReason.normal));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(ExitReason.prologue_fail));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(ExitReason.seed_hash_decline));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(ExitReason.seed_capacity_decline));
    try std.testing.expectEqual(@as(u32, 4), @intFromEnum(ExitReason.precise_resume));
    try std.testing.expectEqual(@as(u32, 5), @intFromEnum(ExitReason.precise_error));
    try std.testing.expectEqual(@as(u32, 6), @intFromEnum(ExitReason.exit_side));
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(LedgerKind.link_terminal));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(LedgerKind.loop_done_linked));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(LedgerKind.deopt));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(LedgerKind.prologue_fail));
    try std.testing.expectEqual(@as(u32, 4), @intFromEnum(LedgerKind.region_bridge));
    try std.testing.expectEqual(@as(u32, 5), @intFromEnum(LedgerKind.seed_hash_decline));
    try std.testing.expectEqual(@as(u32, 6), @intFromEnum(LedgerKind.seed_capacity_decline));
    try std.testing.expectEqual(@as(u32, 7), @intFromEnum(LedgerKind.head_terminal));
    try std.testing.expectEqual(@as(u32, 8), @intFromEnum(LedgerKind.ret_pop));
    try std.testing.expectEqual(@as(u32, 9), @intFromEnum(LedgerKind.call_push));
    try std.testing.expectEqual(@as(u32, 10), @intFromEnum(LedgerKind.precise_deopt));
    try std.testing.expectEqual(@as(u32, 11), @intFromEnum(LedgerKind.precise_error));
    try std.testing.expectEqual(@as(u32, 12), @intFromEnum(LedgerKind.exit_side));
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(LedgerOutcome.normal));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(LedgerOutcome.yielded));
    try std.testing.expectEqual(@as(usize, 32), LEDGER_CAP);
}
