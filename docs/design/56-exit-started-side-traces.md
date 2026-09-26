# 56 — Exit-started side traces (LuaJIT's side-trace mechanism) — Design

Status: Phase 1 done (exit snapshots, exit location map, finalize tests); Phase 2 done (attachability and resume pc); Phase 3 done (tier-1a materialize and exit-side recording); Phase 4 next; design approved. Revision 6. Review rounds: Antigravity round 1 CHANGES REQUESTED, round 2 APPROVE WITH CHANGES; independent sub-agent rounds 3 and 4 CHANGES REQUESTED, round 5 APPROVE WITH CHANGES. All findings are folded in. Bart ruled not to wait for Codex.
Owner: Bart
Last updated: 2026-09-25

## Implementation status

Tracking the gap between this design and what's on the main branch.
Tick items as they land; move whole sections to "done" once everything
inside them is checked. Every phase lands behind `just test` and the
jit-debug gate. Phases 1–2 are inert: they add data that nothing
consumes yet, so every program's output and trace set stays identical.

### Done

- [x] **Diagnosis.** doc 55 §3 "Finding": both fft bit-reverse anchors
  are 0.0% traced (56% of fft's run). Our side-trace analogue re-runs
  the whole iteration from the anchor, so the shapes multiply; LuaJIT
  builds 2 roots and about 8 exit-started side traces.
- [x] **Research round.** LuaJIT side traces (`lj_trace.c`,
  `lj_record.c`, `lj_snap.c`, `lj_asm.c`, `lj_asm_x86.h`); mahina's exit
  state model (coarse deopt, doc 45 precise); mahina's recording and
  linking machinery. Summarised in §2–§3.
- [x] **Design review round 1 (Antigravity): CHANGES REQUESTED.** Three
  blockers, three majors, one nit, all accepted. Dispositions are in
  §11. Codex was unavailable until 2026-09-29.
- [x] **Design review round 2 (Antigravity): APPROVE WITH CHANGES.** Two
  majors, one minor, one nit, all accepted. It also answered Q3, Q6, Q7
  and Q8. Dispositions are in §12.
- [x] **Design review round 3 (independent sub-agent): CHANGES
  REQUESTED.** One blocker, two majors, one minor, one nit, one
  phase-plan gap, all accepted and verified in source. Dispositions are
  in §13. Bart ruled not to wait for Codex (out until 09-29).
- [x] **Design review round 4 (same sub-agent): CHANGES REQUESTED.** Two
  majors and one minor, all verified. They led to revision 5's
  structural change: exit-side traces are continuation traces, and
  there is no new anchor kind. Dispositions are in §14.
- [x] **Design review round 5 (same sub-agent): APPROVE WITH CHANGES.**
  One major, one minor, one nit, all verified and folded in (§15).
- [x] **Phase 0 — baselines.**
  - **Board** (`bench/results/20260924-184058-e587e28.tsv`): fft 205.9
    ms, 12.8× LJ.
  - **fft `--jit-stats`:** `fft_bitreverse:9` is 24.2% of the run and
    0.0% traced; `:55` is 33.1% and 0.0% traced; tier-0-with-a-trace is
    58.3% of the run.
- [x] **Phase 0 — the bit-reverse reduction test.** In
  `src/interp_exit_side_test.zig`: the fft kernel at n = 1024, with
  floats and 30 reps. It must be n = 1024; at n ≤ 128 the outer loop
  still runs ~40–50% traced. The test is byte-identical on all ten legs
  and pins today's reading: both hot anchors under 10% traced. The phase
  that attaches side traces flips it to the §9 target.

### Outstanding
- [ ] **Phase 0 — probes.** jit-debug probes for every new event:
  - snapshot capture;
  - attachability verdict;
  - exit-side want, record, commit and arm;
  - adapter build;
  - materialize;
  - tryside give-up.

  Each probe lands in the phase that creates its event (none of these
  events exist yet). This bullet closes when the last one is in.
  Phase 3 added the `exit-side:` probes (want, record, arm refusal,
  attach, give-up) and `exit-side hop:` (materialize). Adapter build
  is left (Phase 4).
- [x] **Phase 1 — exit snapshots and exit locations (inert).** Done
  2026-09-25 (0889c7b, 1f9b066, and the finalize tests).
  - [x] Boundary ordinals and sparse snapshots per bytecode boundary
    (`exitBoundary`/`commitExitSnap`, `Builder.addSparse`, rewind via
    `Builder.mark`/`truncate` on the doc 47 peel fallback).
  - [x] Every guard and every sunk store carries its boundary ordinal
    (`IrInstr.ord`, `PendingStore.ord`).
  - [x] Snapshots hold only bytecode-live slots (`Proto.reg_live`, §4.2
    "Liveness").
  - [x] `tropt` keeps snapshot refs live and remaps them, and preserves the
    ordinals (a hoisted op loses its ordinal).
  - [x] Finalize validates the snapshots against the committed stream
    (`exitSnapshotsValid`) and drops them all on any defect; memory is in
    `--jit-stats`.
  - [x] The native compiler records where each needed ref lives
    (register, spill, home or constant): `CompiledTrace.exit_locs`,
    built by `nativegen_exitloc.build` after emission (§4.2 "As
    built"). Machine code is byte-identical; memory and the per-exit
    held/lost count are in `--jit-stats`.
  - [x] Finalize tests for the exit snapshots (`trace_finalize_test.zig`):
    - kept as recorded on the unoptimized path;
    - a folded guard's record is compacted away on the tropt path;
    - a ref not defined at its exit drops them all;
    - overflow or no builder attaches none;
    - an allocation-failure sweep on both paths;
    - every `exitSnapshotsValid` rejection rule.

    The compaction and validation legs were each mutation-checked.
- [x] **Phase 2 — attachability and resume pc (inert).**
  `exitAttachable` and `exitResumePc`, including the branch fix-up and
  the Q6 guard-emitter audit. Pure tests. As built:
  - `src/trace_exit_attach.zig`: `classify` returns a `Verdict` (one per
    refusal reason, rules 1–9 in its header); `resumeOf` applies the
    branch fix-up; `resumeClass` is the Q6 audit as an exhaustive `IrOp`
    switch, so a new op won't compile until it is classified.
  - `buildMemo` stores one bit per instruction at finalize (fail-soft,
    like `bridge_cand`); `TraceCode.exitAttachable`/`exitResumePc` read it.
  - `--jit-stats` prints an `exit attach:` line (verdict counts, and the
    held/lost slots of attachable exits); the `exit-loc:` probe shows each
    exit's verdict and `P`.
  - Tests: one fixture per rule in `trace_exit_attach_test.zig` (memo
    pinned equal to the oracle), plus bit-reverse's while-exit in
    `interp_exit_side_test.zig`.
  - Board: fft has 202 attachable exits, sparse 186, nbody 163,
    spectral-norm 150. Most refusals are `trace_shape` or `loop_done`.
  - Review: Antigravity APPROVE WITH CHANGES; both findings were taken
    (`docs/reviews/doc56/antigravity-phase2.md`).
- [x] **Phase 3 — tier-1a materialize and exit-side recording.**
  - `irinterp` materializes at an attached or wanted guard.
  - The dispatcher resumes tier-0 at `P`, with recording when a side
    trace is wanted.
  - Exit-side traces are ordinary `.continuation` recordings at the raw
    `(proto, P)`, started through `pending_exit_anchor` (§4.4). There is
    no new anchor or recorder kind.
  - Commit with `(parent, exit)` provenance and a DONE latch, bounded by
    `tryside` and `maxside`. A wanted exit binds to an existing matching
    continuation at `P` instead of recording.
  - Tests:
    - one continuation at a pc serves both a loop-done arrival and an
      exit arrival (the bit-reverse post-`while` pc);
    - `anchor_abs_base` is correct for an exit arrival (R5-F1);
  - Update the loop-done-only comments on `pending_exit_anchor`
    (`trace.zig:1565-1572`), on `pending_replay_anchor`
    (`trace.zig:1589-1591`) and on dispatch step (9)
    (`interp.zig:2692-2696`) now that there are two producers (R5-F3).
    - `exit_counts`, want bits and DONE latches are charged once per
      receipt on each tier's leg (round 3, unverified item).
  - **Decisions taken at the start of Phase 3 (Bart, 2026-09-25):**
    - *The `for` back-edge link close is new work.* §4.4 "Close" says
      the child closes `.link` at the enclosing loop's back-edge. Only
      the `while` half of that exists: `recWhileLink` links any
      continuation whose backward `jmp` reaches a root. A `for_loop`
      back-edge into a root just records on, so bit-reverse's child
      would unroll the next outer iteration. Bart chose to add the
      `for_loop` close for **every** `.continuation` recording,
      loop-done ones included (LuaJIT's `LJ_TRLINK_ROOT` in
      `rec_loop_jit`). It closes only into a non-peeled `.loop` root
      whose entry guards match the live registers; otherwise it keeps
      recording as today. Loop-done continuations can change shape, so
      the board is measured.
    - *Routing is pulled forward for tier-1a only, and on by default.*
      §4.9's routing is Phase 7, but Phase 3 needs wanted exits. A hot
      attachable exit taken on the **tier-1a** executor becomes
      wanted; native runs keep today's routes until Phase 4. So the
      `--trace` legs of the matrix exercise the path at once, and the
      native board does not move.
  - **Plan (as built, see the Phase 3 notes in CURRENT_TASK.md):**
    - `TraceRecord.exit_side` holds a per-exit state byte (none /
      wanted / attached / gave-up) and `side_children` counts a parent's
      bound children for `maxside`.
    - `noteTakenExit` gains the tier-1a route: at `hotexit` an
      attachable exit becomes wanted and skips the old routes; at
      `hotexit + tryside` without a child it gives up and returns to
      the old routes.
    - The executor takes the state through `ExecCtx.exit_side` and, at a
      wanted or attached exit, applies the earlier bytecodes' sunk stores
      and the snapshot slots, then returns `ExitReason.exit_side`.
    - A new dispatcher arm resumes at `P`. It first chains into a
      `.link` continuation at `P` (`ExitMaterialization.exit_side`),
      which binds a wanted exit (DONE latch, attached). Otherwise it
      arms `pending_exit_anchor` with the exit as `side_src` and
      `pending_anchor_base = base`.
    - v1 scope: only the dispatcher's direct tier-1a entry materializes;
      `driveChain` hops keep the default path.
  - **As built (2026-09-25):**
    - Tier-1a burst "call B" resumed at the ramp's link target instead
      of the link target of the trace that actually ran. Once a
      continuation could link to its *enclosing* root, this gave tier-0
      a stale pc (an endless `while` in bit-reverse). Call B now reads
      `current_link`'s own `.link.aux`, as native `replayLedger` does.
    - `.link` carries a `LinkKind` in `a`: `inner_root` (doc 15's
      hand-off into an inner loop) or `enclosing_iteration` (the link
      goes back to the root of the loop that contains the anchor, so
      one run finished one iteration). The recorder sets it with
      `linkKindAt` (`target <= anchor.pc <= back_edge_pc`), finalize
      validates the tag, and `TraceCode.linkClosesIteration` reads it.
      `runLinkedBurst` seeds `linked_completed` with it, and tier-1a
      call B and `replayLedger`'s `.link_terminal` arm add one per
      such run. Bart ruled it counts as a turn. Without it, the
      zero-progress tail struck the seed continuation and gated it.
      The seed credit is mutation-checked (the thrashing test). The
      call-B and `replayLedger` credits are not observable today:
      `linked_completed` is already ≥ 1 there, and the dispatcher does
      not read `ChainResult.completed`.
    - `resumeOf` refuses every loop-done exit (Bart: "refuse
      while-done"): the `.loop_done` role, numeric-`for` done guards,
      and a while root's own condition (`whileLoopDonePostPc`, now on
      `TraceCode`). Those keep doc 38's route. An inner `while` unrolled
      in an outer root is not the root's done guard and stays
      attachable (the bit-reverse case).
    - A wanted exit binds by chain (a `.link` continuation already
      sits at `P`) or by commit. `--jit-stats` shows
      `binds=N (by chain M)`.
    - `maybeArmExitSide` logs why it refused to arm (recording active,
      another recording pending, anchor barred, anchor full).
    - Round-3 item verified (by reading the code): on tier-1a an
      `exit_side` result returns early from the dispatcher, so each
      firing reaches `noteTakenExit` once. The native leg is Phase 4.
    - Tests (`interp_exit_side_test.zig`): the link-kind oracle, a
      sunk store applied at the exit (mutation-checked), an open
      upvalue read with no `aliased_input`, and one bit-reverse
      post-`while` continuation serving both the loop-done exit and the
      root's wrong-trip exits. The branchy low-yield test pins the new
      behaviour (exit-side takes the exit, no gate). The thrashing test
      runs with exit-side on and off. The doc 40 glue-peel test passes
      on all legs, so it was not narrowed to native.
    - Board: no change (A/B against HEAD via `just shadow`; everything
      within noise). On the tier-1a leg (`--trace`), fft
      `fft_bitreverse:9` goes from 0% to 52.5% traced (5 wants, 5
      binds, 455k chained hops). fft there is 1.79s → 2.02s, because
      tier-1a runs this body at ~2260 cycles per iteration against
      tier-0's ~310. The native path (Phase 4) is where it pays.
    - Review: Antigravity found nothing serious
      (`docs/reviews/doc56/antigravity-phase3.md`).
    - v1 limits: exits of children entered through a chain or burst do
      not materialize, so such a child can still be struck and gated
      (glue pc 24). `set_upval` is NYI in the recorder, which blocks
      some exit-side recordings. An attached exit whose child is
      retired never records again. Each hop scans the cache. All four
      are in TODO.md.
- [ ] **Phase 4 — native exit adapters.**
  - Per-exit adapters built from the Phase-1 exit location map when an
    exit first becomes hot: materialize, then jump through a data cell
    to either the child's entry or the resume-at-`P` return.
  - `ArmKind.exit_side` and its `arm` validation.
  - A child's prologue failure resumes tier-0 at `P` (its anchor), as
    for any continuation.
  - The liveness extension for attachable exits only (§4.6 "Register
    allocation"), so their exit location map rows become "held", with
    its register cost measured on the board (Q3). Bart moved it here
    from Phase 2 (2026-09-25): it changes machine code, and the adapters
    are its only reader.
- [ ] **Phase 5 — ledger grammar and accounting.** `LedgerKind.exit_side`
  rows, the replay grammar, and completion attribution.
- [ ] **Phase 6 — regions and silent promotion.**
  - `exit_side` edges and the side trace's `.link` back are
    intra-iteration edges of the parent's loop region.
  - A new `SilentSiteKind.exit_side`, so the steady cycle promotes and
    stops writing rows (doc 55 §2d machinery).
- [ ] **Phase 7 — tiering policy.**
  - Routing: existing live arms first, then attachable exits to
    exit-side, then today's routes.
  - The legacy-strike exemption for attachable exits that are not yet
    DONE.
  - `tryside` / `maxside` constants.
- [ ] **Phase 8 — measurement and docs.** The §9 budget on fft and the
  full board, compile time, snapshot memory and adapter mcode, and
  updates to docs 17 (§S.8), 40 (open question) and 55 (§3).
- [ ] **Open question Q3 — snapshot liveness cost.** (§8) Direction
  settled in round 2; the number is measured in Phase 4.
- [ ] **Defer — register inheritance.** LuaJIT's `asm_head_side` takes
  the parent's registers directly. v1 adapters hand off through the
  slab, like every mahina link today; the adapter is where inheritance
  would later live.
- [ ] **Defer — typed entry.** Skip the side trace's prologue tag checks
  when the parent's snapshot proves the types.
- [ ] **Defer — peeled parents.** An exit-side hop from a peeled parent
  needs the doc-39 `+1` completion split at the hop. It is computable
  (guard before or after the `.preheader` marker) but not needed for
  bit-reverse; t1 at `:9` is a numeric `for`, which never peels.
- [ ] **Defer — exits inside inlined frames** (`inline_depth > 0`),
  until frame reconstruction exists (doc 45 D1's deferral).
- [ ] **Defer — side traces that leave the anchor frame** (return below
  their start frame; LuaJIT allows it).
- [ ] **Defer — precise-trace exits** (doc 45 "precise links").
- [ ] **Defer — snapshot serialization** (`traceser` v5).

## 1. Why this exists

scimark-fft is 12.6× LuaJIT after doc 55 §2d, and 56% of its run is two
bit-reverse loops that never run as traces (doc 55 §3 "Finding"):

```lua
for i=0,2*n-4,2 do
  if i < j then v[i+1], v[i+2], v[j+1], v[j+2] = v[j+1], v[j+2], v[i+1], v[i+2] end
  local k = n
  while k <= j do j = j - k; k = k / 2 end
  j = j + k
end
```

The root trace at the `for` unrolls the `while` for the one path it
recorded (swap, 3 trips). Real iterations take the swap about half the
time and run 0, 1, 2, … trips with probability 2^-(t+1). Every other
path exits, and our only way to cover an exit is a same-anchor
**sibling**: a whole new trace that re-runs the iteration from the loop
header. The shapes multiply (swap × trip count ≈ 10), against a cap of 4
traces per anchor and a prime-side bound of 2. So the anchor thrashes,
gets gated, and never runs traced again.

LuaJIT (`luajit -jv`, the same function) builds 2 root traces and about
8 **side traces**. Each side trace starts recording **at its parent's
exit**, from the parent's state at that point, and ends by jumping into
a root trace. The prefix before the exit is shared, never re-recorded.
Covering one more path costs one small trace, and the parent's exit is
patched to jump straight into it.

Doc 17 §S chose the whole-iteration sibling on purpose. Mahina exits are
*anchor-coherent*: the slab holds the state at the start of the current
iteration, and tier-0 re-runs it. §S.8 deferred "true per-exit
snapshots (LuaJIT `snap`/`lj_snap_regspmap`) for non-anchor-coherent
exits" until "a workload demands mid-body exit handoffs". Bit-reverse
is that workload, and the shape is not specific to it. Any loop body
with branches or a variable inner trip count multiplies whole-iteration
siblings in the same way. This doc is the contract for Pall's mechanism,
adapted to mahina's deopt and determinism model.

## 2. What LuaJIT does (the reference)

All citations are `~/Projects/LuaJIT/src/`.

- **Hotness.** Every exit goes through `lj_trace_exit` →
  `lj_snap_restore` (restore the Lua stack from the snapshot, data
  driven) → `trace_hotside` (`lj_trace.c:799`): `++snap->count >=
  hotexit` (10) starts recording at the snapshot's pc, from the state
  just restored. `SNAPCOUNT_DONE` (255) latches an exit once a side
  trace is attached. Retries are bounded: `count >= hotexit + tryside`
  (4), or the root already has `maxside` (100) children, gives a trivial
  side trace that links straight to the interpreter
  (`lj_record.c:2883`). A side-trace abort is never penalised
  (`trace_abort` penalises only `parent == 0`, `lj_trace.c:605`).
- **Snapshots.** A snapshot is a sparse slot → IR-ref map plus the
  frame links and the resume pc, 12 bytes of header + 4 per entry
  (`lj_jit.h:179-226`). A guard uses the most recent snapshot, so there
  are fewer snapshots than guards. Snapshots are added after stores and
  side-effecting calls, before comparisons, and so on
  (`lj_record.c:2283`, `2196`). Dead slots are purged
  (`snap_usedef`, `lj_snap.c:208`).
- **The branch fix-up.** `rec_comp_fixup` (`lj_record.c:2205`) rewrites
  a comparison's snapshot pc to the branch target *not* taken on the
  recorded path. A failed comparison guard therefore resumes, in the
  interpreter or in a side trace, at the other branch, and the
  comparison is never re-recorded.
- **Side-trace setup.** `lj_snap_replay` (`lj_snap.c:508`) turns the
  parent's snapshot into the side trace's opening IR: one
  `SLOAD PARENT|INHERIT` per entry (no type check, the type is copied
  from the parent), `PVAL`s for sunk values, and re-materialized sunk
  allocations. Slots the parent never touched load lazily with a normal
  guarded `SLOAD`.
- **Register inheritance.** `asm_head_side` (`lj_asm.c:1941`) coalesces
  the parent's exit registers and spill slots into the side trace's
  entry. `asm_snap_alloc` keeps every snapshot ref in a register or
  spill slot at each guard. A patched exit therefore does no
  materialization at all; only unpatched exits pay `lj_snap_restore`.
- **Linking out.** A side trace that reaches a loop with a trace ends
  with `LJ_TRLINK_ROOT` to it (`rec_loop_jit`, `lj_record.c:660`); that
  can be its own root or another root (an inner loop). Loops without a
  trace are unrolled up to `loopunroll` (15). Values cross into the
  linked trace **through memory** (`asm_tail_link`); only the parent →
  side edge passes registers.
- **Patching.** `lj_asm_patchexit` (`lj_asm_x86.h:3127`) rewrites every
  `jcc` that targets the exit's stub to jump to the side trace. It is
  one-way, done once when the side trace attaches.

## 3. What mahina has today

- **Exit contract.** Ordinary exits are anchor-coherent.
  - The native `deopt_exit` flushes `.carried` homes, so the slab holds
    the current iteration's start state (`nativegen.zig` ~2583).
  - Tier-1a writes `regs` only at `.loop`/`.link`/`.terminal`
    (`irinterp.zig:12-24`).
  - A store that follows any heap read is **sunk** below every guard
    (`pending_stores`, appended by `finalize`), because the re-run
    would otherwise apply it twice (the C1 model).
- **Precise snapshots (doc 45).** `Snapshot {resume_pc, slots_begin,
  slots_len, register_count}` and `SnapshotSlot {slot, ref}` exist
  (`trace_snapshot.zig`), with interning and budgets. Only `new_table`
  anchors are precise. Precise traces refuse inlining, sunk stores,
  `.link` closes, peeling and native links, and skip `tropt`. The native
  materializer `emitPreciseSnapshotFlush` (`nativegen.zig:653`) and the
  `.precise_resume` dispatcher arm (resume tier-0 at `snap.resume_pc`,
  `interp.zig:4052`) work, and so does the tier-1a precise exit tail
  (`irinterp.zig:1290`).
- **Recording.** Every recording starts at an anchor. For the loop,
  head and cont kinds the slab must be coherent there, and slots load
  lazily with type guards (`refOf`). Continuation recordings
  (`maybeArmContinuation`) are the one existing start at a non-header pc
  reached by an exit: a loop-done exit, whose state is naturally
  coherent at the post-loop pc. `.side`/`.continuation` recordings can
  close with `.link` into another anchor's root (`recWhileLink`,
  `recForPrepLink`).
- **Linking.** The patch is slot indirection (`commitSlotMutation`
  writes `c.slots[exit]`), with handoff through the slab: the child
  re-checks tags and reloads. The arm kinds are `link_terminal`,
  `loop_done_linked`, `ordinary_guard`, `sibling_handoff`, `ret_cont`,
  `call_head` and the region bridge. `arm` refuses peeled and precise
  parents and children.
- **Hot exits.** `noteTakenExit` (`trace_link.zig:311`) is the
  `trace_hotside` analogue: `exit_counts[exit]` (u8), `EXIT_COUNT_DONE`
  (255), `hotexit` (10). Its own comment names the gap: "We cannot
  record from an arbitrary mid-body exit". All three routes (prime
  side, replay side, head sibling) record at the parent's anchor.
- **Missing.** Mid-body snapshots on ordinary traces; recording from an
  exit pc; program positions on sunk stores; a guard-pc-coherent native
  exit; an arm kind, ledger row and replay grammar for such a hop;
  cross-anchor provenance.

## 4. The design

### 4.1 Two exit contracts per guard

Every guard keeps today's **anchor-coherent** contract on its default
path, and that path does not change. An exit that is attached (it has
an exit-side trace) or wanted (it is hot and a side trace should be
recorded) takes a second path: the **resume-coherent** contract. There,
the exit makes the tier-0 state at the guard's resume pc `P` real. Then
it continues at `P`, either in the side trace or, when there is none
yet, in tier-0.

Making it real means three writes, in this order:

1. **Stores from earlier bytecodes.** Every sunk store from a bytecode
   **strictly before** the guard's own bytecode is applied, in program
   order (§4.2's ordinals).
2. **Snapshot slots.** Each slot in the guard's snapshot is written from
   its ref's value.
3. **Carried slots the snapshot does not name.** Every carried slot is
   written from its home, because after the first back-edge its slab
   copy is stale.

**Soundness.** On this path nothing is re-run from the anchor. The
parent executed every bytecode before the guard's bytecode `B`; tier-0
or the side trace executes from `P` onward.

- **Stores before `B`.** Applying the sunk stores of bytecodes before
  `B`, in order, is exactly what tier-0 would have done by then.
- **`B`'s own stores are never applied** (review finding 4). A
  non-branch guard resumes at `B` itself, which is re-executed, so its
  store runs once, there. If `guard_fits` failed, forcing the store into
  the lane would also be wrong. A branch guard's `B` stores nothing.
- **Pure-write stores** that ran inline earlier in `B` are rewritten
  with the same value on re-execution. That is today's C1 argument,
  unchanged.
- **Forwarded loads** (`forwardPendingArrayLoad`/`HashLoad`) already saw
  the forwarded values in SSA. Loads before a store in program order
  read the pre-store heap and still precede it.
- **Stores after `B`** stay unexecuted; whoever runs from `P` performs
  its own.

The default path keeps the C1 argument unchanged. It has no extra cost
while an exit is neither wanted nor attached. Replay-to-k runs pure
tier-0, and keyframes are taken only at interpreter safe points, so
neither is affected.

### 4.2 Exit snapshots and boundary ordinals (Phase 1)

The recorder already keeps `reg_map` per bytecode, and precise mode
snapshots the full window at every boundary (`snapBoundary`).

Ordinary traces get, at each bytecode boundary:

- **A boundary ordinal.** A monotonic `u16` counting bytecodes executed
  on the recorded path.
- **A sparse snapshot.** The `.def` slots of the anchor window
  (depth 0) that are **live in the bytecode** at the resume pc, each
  mapped to its ref, plus the resume pc of that boundary. `.undef`
  slots are still coherent in the slab.

  *Liveness (added during Phase 1).* Capturing every `.def` slot is
  wrong: a snapshot ref is an optimizer liveness root, so a dead local
  (written, never read again) would stop `tropt` from deleting it in
  every trace. The first Phase 1 cut did exactly that; the doc 26
  `.pure3` test caught it. LuaJIT drops dead slots per snapshot with a
  forward bytecode scan (`snap_usedef`, `lj_snap.c:208`). Bart chose a
  per-proto table instead: `bc_liveness.compute` runs a backward
  dataflow over the bytecode CFG once, at compile time, and stores
  `Proto.reg_live` (one bit per register per pc). It errs live
  wherever it is unsure:
  - registers captured by a child closure are live everywhere;
  - multret consumers read up to the top of the window;
  - writes with a dynamic extent (`call c=all_results`,
    `vararg_spread`) kill nothing;
  - loop ops kill their loop variable only on the taken edge.

  A proto over 2^18 table words, or a hand-built one, has no table.
  Its traces then carry **no** exit snapshots, so unknown liveness
  never pins slots. Dead slots are left stale at an exit. That is the
  same "tier noise" the loop-exit writeback already leaves above
  `locals_watermark` (doc 21 masks it in final-state keyframes).
  `SnapshotSlot.slot` already exists "so a future sparse form is a
  validation change" (`trace_snapshot.zig:11`). Snapshot record ids
  do increase in construction order (`Builder.add` appends a record per
  call and only interns the slot vector). But sunk store instructions
  have no snapshot record of their own, so guards and stores need a
  shared ordinal space of their own. `TraceCode` gains a small
  `ordinal → snapshot id` table. (Revision 3 wrongly said snapshot ids
  are unordered; review round 3, finding 5.)

Every guard records the ordinal of the bytecode that emitted it, and so
does every **sunk store IR instruction**: the ordinal of the bytecode
whose store it is, stamped when the store is deferred. This is review
blocker 1's fix. The sunk stores already exist as real IR instructions
at the end of the trace, and `tropt` already keeps them and remaps
their operands. Carrying the ordinal on the instruction itself makes
"which stores precede this guard" a question in one coordinate space
(ordinals) that survives DCE, CSE, compaction and LICM. Raw IR indices
do not.

- **The optimizer** must treat snapshot refs as liveness roots, remap
  them through `canon`/`new_index`, and preserve the ordinal fields
  (doc 45's outstanding "optimizer integration"). This is the largest
  Phase 1 item.
- **Budgets.** A trace over the snapshot budget simply has
  non-attachable exits; it never aborts the recording.
- **The exit location map (native).** For each attachable exit, the
  compiler records where every needed ref lives at that guard:
  register, spill slot, carried home or constant. "Needed" means the
  snapshot refs plus the operands of the preceding sunk stores. For an
  array store that includes the table base behind its `aref`
  (`aref.a`) when the table is dynamic, because `emitAStore` loads the
  array's data pointer from it (the liveness rule at
  `nativegen_alloc.zig:777` already extends it to the store). Only
  attachable exits, and only their snapshots' `.def` slots, get their
  liveness extended. The map
  is data, compact and per exit. It is what lets an adapter be built
  later without recompiling the parent (§4.6), and it is exactly the
  input register inheritance will need.

  *As built (Phase 1, 2026-09-25).* Bart picked a **per-value table**
  over per-exit rows or keeping the whole allocator output:
  - `ExitLocMap.values`: one 12-byte `ExitLoc` per distinct needed
    value, sorted by ref. Each row has the place (`reg`/`xmm`/`spill`
    byte displacement/`konst` index/`none`), the boxing kind (for a
    slot load, its slot's kind: a carried table is `.heap`), and
    `live_until`. The allocator never splits a live range, so a value
    has one place for its whole life. The place holds the value at exit
    `e` exactly when `ref < e <= live_until` (`holdsAt`). Refinements:
    - slot homes are held all body long, except a win-2 in-place
      update, which the allocator only allows after the last body exit;
    - a transient whose register its last reader takes over (win-1
      operand reuse) ends one instruction early, because an exit taken
      by that reader (`int_of_float`, `alen`) already sees the new value;
    - an invariant `slot_load` records its own slot (`invariant_slot`):
      restoring that slot needs no store.
  - `ExitLocMap.carried`: the carried homes, exactly the slots
    `deopt_exit` flushes.
  - "Needed" means: every exit-snapshot ref; every ref a sunk store
    below the first exit reads, through its `aref`/`href`/`garow`/`gcell`
    token down to table, index and value; and each carried slot's load.
  - An exit's own view is derived: `exitSnapIdx(e)` → its snapshot's
    slots → `ExitLocMap.at(ref, e)`. There is no per-exit data.
  - It is inert: built after emission, and no liveness is extended. A
    value whose life ended before an exit is simply "lost" there. Phase 4
    extends liveness for attachable exits only (moved from Phase 2 by
    Bart, 2026-09-25). Phase 2's `--jit-stats` `exit attach:` line counts
    the attachable exits' held/lost slots, which is that work list.
  - Board measurement (`--jit-stats`): the map is 90 B – 3 KB per bench
    (fft 2.1 KB against 10 KB of IR). Across the board, 159 of 6195
    restored exit slots (2.6%) are lost: fft has the most (36 of 895),
    grid_matmul the highest share (20 of 325, 6%). Snapshots plus map
    stay under 1× IR everywhere except
    partialsums (1.36×: 26 snapshots of about 8 live floats over a
    1.6 KB trace; the snapshots alone are already 0.98×).

Snapshot and map memory are reported per trace in `--jit-stats`.
LuaJIT's measured snapshot cost is about the size of the IR; ours must
stay in that range.

### 4.3 Attachability and the resume pc (Phase 2)

`exitAttachable(t, exit)` is true only when all of these hold:

- the guard has an ordinal and a snapshot, and `exit_prov` is complete
  for it;
- `inline_depth == 0`;
- the exit is not a loop-done exit (those stay with the continuation
  machinery, which already solves them);
- every sunk store with ordinal below the guard's is one of the kinds
  the flush emitters model (`astore`, `hstore`, `gstore`, `ustore`),
  else fail closed. This is an ordinal filter over the trailing store
  block, **not** `loopDoneSnapshotSupported`. That helper scans forward
  from the exit and accepts only stores until the terminal, which is
  right for a loop-done guard but fails (and would be unsound if
  loosened) for every mid-body guard (review round 3, finding 1);
- the trace is neither precise nor peeled (peeled parents are
  deferred);
- the guard's emitter passed the Q6 audit;
- the resume pc `P` is not the consumer half of a multret pair (a
  `call`/`ret` whose `b` is `all_results`). Tier-0 reads that
  instruction's count from the transient `Vm.reg_top` its producer
  stamped, and no snapshot carries it (found during Phase 2; resuming
  AT the producer is fine, it stamps `reg_top` afresh).

`exitResumePc(t, exit)`:

- **Branch guards** (role `.branch_cond`, source op `jmp_if_*`): the
  successor NOT taken on the recorded path, derived from `source_pc` and
  `polarity`. This is `rec_comp_fixup`. Branch ops write no slots, so
  the boundary snapshot is exact.
- **Every other guard:** the source bytecode `B` itself, re-executed
  from the boundary snapshot taken before it.

The fix-up matters for sharing. On bit-reverse, t1's three
wrong-trip-count exits (ei 60/65/70) all resume at the post-`while` pc
`j = j + k`, so one side trace can serve them (§4.5).

### 4.4 Recording from the exit: materialize first (Phase 3)

Round 1 had tier-0 re-run the iteration from the anchor and start
recording on arrival at `P`. Review blocker 2 showed the flaw: in an
unrolled loop the re-run reaches `P` several times, and the first
arrival is the wrong one. The revision does what LuaJIT does.
`lj_snap_restore` makes the exit state real, and recording starts right
there. There is no re-run and no ambiguity.

- **Want.** When a hot attachable exit reaches `hotexit` in
  `noteTakenExit`, the exit is marked *wanted*.
  - Native: its adapter is built with its data cell set to
    "resume-at-`P`".
  - Tier-1a: a wanted bit is set on the exit.
  - Exits that already have a live arm keep it (Q5, §4.9).
- **Next firing.** The exit materializes (§4.1) and returns
  `ExitReason.exit_side {parent, exit, P}`. The dispatcher sets
  `pending_exit_anchor = (proto, P)` and resumes tier-0 at `P`,
  following the `.precise_resume` precedent. Tier-0's first dispatch is
  at `P`, and dispatch step (9) (`maybeStartContinuation`,
  `interp.zig:2698`) starts the recording there, before the mirror, so
  `P`'s instruction is the trace's first op. This is exactly how a
  loop-done continuation starts today. The same site also sets the
  companion `pending_anchor_base` to the resuming frame's absolute slab
  base (the frame the exit left, i.e. the parent's anchor frame).
  `maybeStartContinuation` seeds `anchor_abs_base` from it
  (`trace_link.zig:231`). Today only the back-edge writes it, just
  before `onBackEdge` (`interp.zig:6314`), so a stale value from an
  unrelated back-edge is a real hazard. A base that is too low only
  over-aborts. A base that is too high (say, a deeper callee's) would
  send a truly aliased open upvalue down the "safe outer read" path in
  `recUpvalSlotAlias` (`trace_recorder.zig:4810-4920`), which is a
  soundness bug (review round 5, R5-F1). A Phase 3 test mirrors the
  `anchor_abs_base` regression in `trace_link_peel_test.zig:256-267`,
  but arriving through an exit. Entry state is the freshly
  materialized slab. Slots load lazily with type guards, and the
  parent's snapshot is not replayed into the recorder (that belongs to
  register inheritance, deferred).
- **An exit-side trace IS a continuation trace** (revision 5, replacing
  revision 4's `AnchorKind.exit`). A loop-done continuation (doc 15,
  doc 38) is:
  - a `.continuation` recording;
  - anchored at the raw `(proto, pc)` of a non-header pc;
  - entered with the slab coherent at that pc;
  - closed by `.link` at the enclosing loop's back-edge.

  An exit-side trace has exactly that contract, so it is recorded,
  stored, selected and linked as one. Only the way it is *entered*
  (from a mid-body exit through an adapter) is new. What this buys:
  - **Sharing across arrival kinds.** One trace at `P` serves both
    loop-done arrivals and exit arrivals. In bit-reverse, the
    post-`while` pc `j = j + k` is both the `:55` loop's done pc and the
    resume pc of t1's ei 60/65/70.
  - **The anchor-kind sites stay as they are.** About 30 sites branch on
    the anchor kind (`!= .loop` / `== .cont`, the entry-patch switches
    in `trace_entry_registry.zig:101-138`, the precise-retry threshold
    at `trace.zig:3619`). A new kind would fall into their one-shot
    branches silently, including the `head_parent` sibling-only arm
    restriction (`trace_link.zig:1664`) and the head-sibling want in
    `noteTakenExit` (`trace_link.zig:355`). With continuation anchors
    none of them change (review round 4, R4-F1/F2).
  - **Their own exits** deopt and resume at `P` under today's rules.
    Their hot exits go through today's `.loop`-kind routes, including,
    once §4.9 lands, exit-side routing for their own attachable exits.
    Those become nested side traces (LuaJIT's T5 off T3).
  - **No entry patch unless one is warranted.** `resolvePatchPc` scans
    for a back-edge targeting `P`, and a non-header `P` has none, so no
    tier-0 entry patch is installed. As in LuaJIT, a side trace is
    entered only from its parents.

  Attachability adds the continuation's own static gate:
  `continuationReachesEnclosingBackEdge(proto, P, parent anchor)`
  (`trace_link.zig:185`). If `P` is itself a loop header, the exit is
  not attachable in v1: the target would be that loop's root, a
  different arm shape.
- **Close.** The `.continuation` recorder's existing grammar. It closes
  `.link` at the enclosing loop's back-edge (usually the parent's loop),
  or at an inner while-loop with a root (`recWhileLink`). Peeled
  targets are refused (review finding 5: a peeled trace's entry guards
  are its run-once iteration's types), so the loop is unrolled instead.
  Leaving the anchor frame aborts, as it does for continuations today.
- **Commit.** The trace commits with provenance
  `ProvenanceEdge{parent, exit, child}`. `finishSideTraceProvenance`
  today requires the same anchor; it grows a cross-anchor branch. The
  commit DONE-latches `parent.exit_counts[exit]` and points the exit's
  cell at the child.
- **An existing continuation at `P`.** When the exit is wanted and a
  continuation already exists at `P` whose entry fingerprint matches
  the exit's static types (§4.5), the exit binds to it with no
  recording. That replaces `maybeArmContinuation`'s "has trace →
  refuse" (`trace_link.zig:175`) for this path. A barred `P`
  (`recordingBarred`) is treated like an abort: it uses up a retry.
- **Retries and caps.** An abort is not a strike (LuaJIT). The exit
  stays wanted, so its next firings still resume at `P`, which is never
  worse than re-running from the anchor. At `hotexit + tryside` the want
  is dropped, the exit latches DONE with no side trace, and it returns
  to the default path; the old routes then apply. The per-root child
  cap is `maxside` (100). Both are deterministic constants.

### 4.5 Sharing by resume pc

An exit-side trace is keyed by `(proto, P)` and selected by entry
fingerprint, like siblings at any anchor. Several exits that resume at
the same `P` with the same types share one trace; their cells all point
at it, and it is recorded once.

The parent knows each exit's slot types statically: they are its IR
types for the snapshot refs. Binding an exit to a child checks that the
child's entry guards match those types. If none matches, the exit stays
wanted and records one. Bit-reverse needs this: at the post-`while`
pc, `k` is an int after 0 trips (`k = n`) and a float after ≥1 trip.

### 4.6 Native exit adapters (Phase 4)

Round 1 emitted a materializer for every attachable exit at compile
time. Review finding 6 priced that at 5–10 KB of cold code per trace,
for the 1–2 exits that ever attach. The revision builds an **adapter
per exit when it first becomes hot**, from the Phase-1 exit location
map. The parent is never recompiled, and exits that never get hot cost
only their map entry.

- **The guard side.** Each attachable exit's mini-stub starts with a
  data-cell test, the §2d pattern: code is never rewritten, and runtime
  state lives in a cell.
  - Cell zero means the default anchor-coherent path, byte-identical to
    today.
  - Cell nonzero means jump to the adapter the cell names.

  The test must not disturb any register holding a needed ref (Q7).
  `rax` and `rcx` are never allocated (`ALLOC_ORDER`,
  `nativegen_alloc.zig:180`), so no value lives in them at a guard, and
  the stub uses `rax` with the cell's absolute address. That is the
  same pattern as §2d's silent check and the precise flush
  (`nativegen.zig:664`):

  ```
  mov rax, imm64          ; this exit's cell (heap-allocated, stable)
  cmp qword [rax], 0
  jne .to_adapter
  ; fall through: today's anchor-coherent exit, unchanged
  .to_adapter:
  jmp qword [rax]
  ```

  Revision 3 used RIP-relative cells "within ±2 GB of the mcode
  arena". The arena does not provide that: each region is an unhinted
  `mmap(null, …)`, and its own comment defers the ±2 GB check
  (`nativegen_mcode.zig:124-131`, `:268-282`). Round 3, finding 2. An
  absolute load needs no placement guarantee, at the cost of about 10
  more bytes per attachable stub. The cells are ordinary heap memory
  owned by the parent trace, like §2d's cells. Inside the adapter,
  `rax` and `rcx` stay free scratch.
- **The adapter.** A small mcode-arena allocation, reading values from
  the locations the map names:
  1. the stores from earlier bytecodes, in order. `finalize` appends
     all sunk stores as one contiguous block just before the phi rows
     and the terminal (`trace_finalize.zig:45-52`), in recording order,
     which is ordinal order: `pending_stores` is append-only, and
     forwarding only reads it. The adapter walks that block and emits
     each store whose ordinal is below the guard's. It reuses the leaf
     emitters (`emitAStore`, `emitHStore`/`emitGStore`, the `ustore`
     arm), not `emitLinkedLoopDoneSnapshot`'s driver, which scans from
     the exit (review round 3, finding 1). The operands of these stores
     are defined before the guard and are used again at the tail, so
     they are already live at the guard;
  2. the snapshot slots, reusing `emitPreciseSnapshotFlush`'s rules
     (never skip `.carried` on ref identity; write-dominated carried
     loads flush the home);
  3. the carried homes;
  4. `jmp` through the adapter's own target cell, which holds either the
     child's `ordinary_entry` or a resume-at-`P` return stub.

  The exit's cell is set once, at want time. Attaching a child only
  rewrites the adapter's target cell.
- **`ArmKind.exit_side`.** The registry records the arm so that
  `resetLinksTouching` and retirement work as for every kind.
  Validation requires:
  - the parent is loop-anchored: `head_parent` is refused, as for every
    non-sibling kind (doc 44 D10: one-shot slots carry only
    `sibling_handoff` arms; `trace_link.zig:1664`). `noteTakenExit`
    already sends one-shot exits elsewhere first; this is the funnel's
    own check (review round 5, R5-F2);
  - the parent exit is attachable;
  - the child is a `.link`-tailed continuation anchored at the raw
    `(proto, P)` of the exit's resume pc, and not peeled;
  - the child's entry fingerprint matches the parent's static types;
  - the child is compiled.

  `exitAttachable` is a pure function of the parent's committed
  `TraceCode` (IR, ordinals, snapshots, exit map), which never changes
  after commit. It is computed once at compile time and stored per
  exit, and `arm` reads that stored verdict. This differs on purpose
  from `sibling_handoff`, which re-proves `exitIsPreEffect` at the
  funnel (`trace_link.zig:1721`). There the predicate is evaluated
  against a watch that can be stale; here there is nothing that can
  drift. The child-side checks above are all re-run at arm time
  (review round 3, finding 4).

  Retiring the child points the target cell back at resume-at-`P`.
  Retiring the parent drops the adapter with the parent's page.
- **Register allocation.** Snapshot refs and preceding store operands
  must be recoverable at attachable guards: in a register, a spill slot,
  a home or the slab. `nativegen_alloc` already extends `last_use` for
  precise snapshot refs (`:795`), and the same extension applies here.
  Q3 measures the pressure; there is no parent recompilation.
- **Prologue failure.** The child's `prologue_fail` resumes tier-0 at
  `P`, which is its anchor, as for any continuation. No new contract.

#### 4.6.1 Phase 4 plan (2026-09-26)

Phase 4 does, for native code, what Phase 3 did for tier-1a: a wanted
or attached exit materializes at `P` and returns to the runtime, which
then chains into the continuation at `P` or records one there. The
adapter's direct jump into the child needs the ledger grammar and so
moves with it to Phase 5.

- **A native-only switch, off by default.** `Config.exit_side_native`.
  Until Phase 5, every native hop returns to the runtime and re-enters
  the child through `driveChain`, which costs about 600 ns. fft makes
  about 500k hops, so turning this on now would make fft slower. The
  switch turns on at the end of Phase 6 (direct jump plus silent cycles)
  and is measured then. Tests turn it on. It also gates the stub and the
  liveness extension below, so with it off the machine code is
  byte-identical and the native board does not change.
- **Who may take the path (v1).** The same rule as Phase 3: only the
  dispatcher's direct entry. A new `NativeResult.exit_side_ok` byte is
  set only by that call site. The stub also requires `ledger_len == 0`
  and `silent_active == 0`: the exiting trace is the entered trace,
  nothing chained before it, and no silent transition ran (a silent
  transition writes no row, so `ledger_len` alone can't see it, and the
  dispatcher sends any `silent_active` result through the silent drain
  and `replayLedgerFrom` first; review finding 1). Every other native run
  (bursts, chains, silent drains, and any trace reached through a link)
  keeps the anchor-coherent exit, so no ledger replay can meet the new
  row yet. Phase 5 widens this.
- **The stub.** For an attachable exit of a native page with a
  non-empty exit location map, right after `exit_instr` is written:

  ```
  mov rax, imm64            ; &exit_side_cells[ei]
  cmp qword [rax], 0
  je  .ordinary
  cmp byte [rdx + exit_side_ok], 0
  je  .ordinary
  cmp qword [rdx + ledger_len], 0
  jne .ordinary
  cmp qword [rdx + silent_active], 0
  jne .ordinary
  jmp qword [rax]           ; the adapter
  .ordinary:                ; today's code, unchanged
  ```

  Only `rax` and the flags are touched, and neither is live at a guard.
  The cells array (one `usize` per instruction, zero by default) is owned
  by the `CompiledTrace`, so its addresses are stable for the page's
  life.
- **The adapter**, built when the exit becomes wanted, from the exit
  location map alone (the allocator's output is gone by then). It gets a
  synthetic `Alloc`:
  - `loc[ref]` comes from the map row (register, XMM or spill);
  - `slot_id_of_ref` is all `-1`, so `arrayFieldReg` reloads the
    array's `data`/`present` pointer from the table ref instead of using a
    hoisted base register (the same pointer, by the B5 invariant);
  - a synthetic `kinds` slice of the trace's length (`.none`, then each
    map row's kind), since the store emitters branch on `kinds[ins.b]`
    (review finding 2);
  - a constant a store reads is first written into a spill cell above
    the parent's frame, so it has a place like any other value. The
    frame's end is `spill_count` plus the boxed-tag spill cells
    (`boxedTagSpill` addresses them past `spill_count`); the map records
    that total at compile time (review finding 5). The trampoline
    reserves `SPILL_MAX` words, so the cells above it are free. Refuse if
    they run out.

  With that, the existing store leaf emitters (`emitAStore`,
  `emitHStore`, `emitGStore`) and `flushSlot` are reused unchanged. The
  snapshot flush is a dedicated loop over the map rows, not
  `emitPreciseSnapshotFlush`, which needs the real slot table (review
  finding 3). The sequence:
  1. every sunk store with `0 < ord < guard.ord`, in stream order;
  2. every carried home (what `deopt_exit` writes: at this exit the slab
     is stale for those);
  3. the exit snapshot's slots, which override step 2. A constant is
     written as an immediate. A slot restored from its own invariant load
     (`ExitLoc.invariant_slot`) is skipped (the slab is current);
  4. `completed = rbx`, `exit_reason = .exit_side`, a
     `LedgerKind.exit_side` row, `final_trace_id`, then `jmp` through
     the adapter's target cell. In Phase 4 the target is always
     `shared_exit`.

  Build refuses, and the exit gives up (it keeps today's routes), when a
  needed value is not held at the exit (`ExitLocMap.at` is null: a
  `uref` placed after the guard, a `.none` load, a φ), when the map is
  empty, or when constant staging would pass `SPILL_MAX`. Refusals are
  counted in `--jit-stats`.
- **Liveness extension** (§4.6 "Register allocation", Q3). With the
  switch on, `nativegen_alloc` extends every value an attachable exit
  needs to that exit: its snapshot refs, the operand closure of every
  sunk store with a lower ordinal, and carried loads (already pinned).
  When the guard itself reads the value, the extension goes one past the
  guard, so operand reuse (win 1) cannot hand its register to the
  guard's result. The attachable set is the Phase 2 memo.
- **Ownership.** New `CompiledTrace` fields: `exit_side_cells: []usize`
  (heap, RW, one per instruction) and the adapter pages, each with its
  own heap target cell (never inside the RX page). Adapter pages live in
  the shared `McodeArena`; `CompiledTrace.deinit` frees them, the cells
  and the target cells (review finding 4). Giving up clears the exit's
  cell back to zero; the page stays until the parent dies.
- **Runtime.**
  - The native run wrappers take the `exit_side_ok` flag, and only the
    dispatcher's direct entry sets it.
  - `ExitReason.exit_side` may now come from native. The dispatcher's
    arm asserts a single `exit_side` row owned by the entered trace, then
    calls `consumeExitSide`, whose chain uses the native tier and whose
    receipt uses `.native_direct` (review finding 6).
    `driveChain`'s `.exit_side` materialization accepts native (its
    tier-1a-only assert goes) and skips the arms that assume an
    anchor-coherent exit (the M1 half-fusion arm and the composite-bridge
    arm of the failed guard).
  - `LedgerKind.exit_side` (append-only ordinal) is added to every
    exhaustive switch: `commitsGuestWork` is true, and region work is
    `local + 1` (§4.8's table). `replayLedgerFrom` panics on it in Phase
    4, since v1 scoping guarantees it never reaches a chain ledger.
  - Routing: a new `ExitRoute.native_direct` from the dispatcher's
    direct native receipt. `routeExitSide` builds the adapter and sets
    the cell at `.none → .wanted`; a failed build goes straight to
    `.gave_up`. `.wanted → .gave_up` clears the cell. An attached exit
    keeps its cell, and every firing returns to the runtime and chains
    until Phase 5 retargets the adapter.
- **Tests.**
  - The Phase 3 exit-side tests on the native legs, with the switch on:
    output parity, and proof that the path actually fires (adapter
    builds, native exit-side hops, binds);
  - adapter unit tests: each store lane (int widths, bool, f64, value
    lane), `hstore`, `ustore`, `gstore`, a spilled operand, a constant
    operand, a float XMM value, a carried home overridden by a snapshot
    slot;
  - a refusal for each reason;
  - the switch off leaves the machine code byte-identical (native sizes
    equal to HEAD).

### 4.7 Tier-1a and the runtime chain (Phase 3)

Tier-1a materializes **inside `irinterp.executeImpl`**, at the guard
failure, where `values[]` is live (review finding 7; the tier-1a
precise exit tail at `irinterp.zig:1290` is the precedent). It applies
the stores from earlier bytecodes through the same store helpers the
linked loop-done flush uses, and sets the snapshot slots, before it
returns. `regs` is therefore coherent at `P` when `driveChain` or the
dispatcher looks at it. This phase proves the semantics on the ten-leg
matrix before any native code exists. P-EBP-2 in doc 17 allows the tiers
to discover different traces, so native legs simply keep today's
behaviour until Phase 4.

### 4.8 Ledger, accounting, regions and silent promotion (Phases 5–6)

Round 1 proposed rowless attached hops. Review blocker 3 rejected that:

- `replayLedgerFrom` validates each row against the armed successor of
  the row before it, so a missing row leaves an orphan owner, which
  panics;
- an all-rowless cycle never reaches `LEDGER_CAP`, so it never yields;
- zero-progress cycle detection needs the rows;
- above all, Rule Z-8: the mechanism that removes per-row cost from a
  steady cycle already exists. It is silent promotion, which since doc
  55 §2d is a data-cell switch.

So:

- **Rows.** Both transitions of the cycle are spelled out (review round
  3, finding 3).
  1. **The hop in: a new `LedgerKind.exit_side` row** (append-only
     ordinal), written by the adapter before its jump. A new
     `replayLedgerFrom` arm validates it:
     - the row's owner is the parent, and its exit is armed
       `exit_side`;
     - the next row's owner is, by id, the child that arm names: the
       continuation at `(proto, P)`.

     The arm's cursor transition is a new `ArmKind.exit_side` case in
     `applyEdgeCursorTransition`: `next_entry = .via_exit_side`,
     `resume_pc = P`, with `cont`/`link_pc` left alone. If the row is
     the last one (a yield), the walk returns with `resume_pc = P`, and
     the slab is coherent there because the adapter materialized
     before the jump.
  2. **The close back: the existing `link_terminal` row.** The child
     ends in `.link` whose `aux` names the loop anchor it closes into,
     the same shape `.side`/`.continuation` recordings use today. The
     existing arm's checks hold as they are:
     - the owner ends in `.link` and `e.exit` is its last instruction;
     - the successor passes `isInnerLoopRoot(succ, proto, aux)`. That
       only asks for a `.loop`-tailed trace anchored at `(proto, aux)`
       (`trace.zig:2287`), which t1 at `:9` is.

     Its cursor transition leaves `cont = child` and
     `link_pc = aux = the loop root's anchor pc`. That is exactly the
     resume contract of the loop root's own later guards, whose
     terminal rows resume at `cursor.link_pc`
     (`trace_chain.zig:2262`). The unarmed and yield path
     (`run_inner_from`) resumes at `aux`, which is also correct. No new
     grammar is needed here. A Phase 5 replay test pins the whole
     parent → `exit_side` → child → `link_terminal` → parent sequence,
     including a yield after each row.
  3. **Continuation lookups see exit-side traces, on purpose.**
     `findLinkTrace`/`resolveLoopDoneCont` (`trace.zig:2374`) will find
     an exit-side trace at `P` when a loop's done pc is `P`. That is
     sharing, not confusion: the entry contract (slab coherent at `P`)
     is identical. `findLoopTrace` still never picks one (it requires a
     `.loop` tail). A `cont = child` cursor is harmless: round 4 traced
     every consumer of `cursor.cont` and found none that inspects its
     value for coherence (`trace_chain.zig:1914-1926`, `2318-2407`).
- **Accounting: four sites, two axes** (review round 4, R4-F3). A
  `LedgerKind`/`ArmKind` variant is priced at four exhaustive switches.
  They answer two different questions, and each needs its own explicit
  value:

  | Site | Question it answers | `exit_side` value | Why |
  |---|---|---|---|
  | `region_work` switch, `trace_chain.zig:1670` | region progress (doc 55 §2 (c)) | `local + 1` | the parent's completed laps (as `.deopt` credits `local`), plus the interrupted iteration, which is committed forward from here and never re-run (the child or tier-0 finishes it from `P`) |
  | `silentKindForArm` / `rowSilentKind`, `trace_link.zig:745`, `:907` | which silent site kind | new `SilentSiteKind.exit_side` | its own epilogue shape |
  | `emitSilentEpilogue`, `nativegen_emit.zig:1287-1443` | the same region work, in machine code | `local + 1`, byte-for-byte the same count as row 1 | doc 55 §2 was a multi-round arc caused by the Zig count and the epilogue count disagreeing |
  | `commitsGuestWork`, `trace_exec.zig:285` | zero-progress edge strikes and retirement (doc 55 §1, `provenanceEdgeVerdict`) | `true` | unlike `.deopt`, which rolls the iteration back to the anchor, the hop makes the partial iteration real (stores and slots are written). A cycle through it cannot be a zero-progress ping-pong in the §1 sense |

  The child's closing `link_terminal` row keeps its existing values
  (`region_work` 0, `commitsGuestWork` true), so each iteration is
  counted exactly once. Coverage credits that iteration to the parent's
  anchor as traced.

  Tests (Phase 5/6):
  - the same bit-reverse cycle run rowed and silent gives identical
    `region_work` totals (row 1 against row 3);
  - native and tier-1a iteration totals agree on the reduction;
  - a `sibling_handoff` edge fed by an `exit_side` hop is not struck.
- **Regions.** `exit_side` edges and the side trace's `.link` back are
  classified as intra-iteration edges of the parent's loop region, the
  way `loop_done_linked` → continuation edges already join nest-cycle
  regions. The steady cycle (parent → side → parent) then forms a
  region like fft_transform's `:131`/`:193` nest did after doc 55 §2.
- **Owner election.** Round 2 found that the enclosure test
  (`trace_region_topology_build.zig:413-421`) compares raw anchor pcs,
  so a tagged `.exit` pc would make the region unarmable. Revision 5
  has no tagged pc: exit-side traces sit at raw `P`, which lies inside
  the parent's `for` span, and that is exactly what the test accepts.
  The decode step is dropped. A Phase 6 test still pins that a
  `:9`-shaped parent-plus-side-trace cycle mints `armable = true`
  (Rule Z-8, layer 2).
- **Silent promotion.** A new `SilentSiteKind.exit_side`: the adapter's
  jump is a silent site, with its data-cell check and its epilogue.
  Once the region qualifies, the cycle promotes and runs with no ledger
  appends, bounded by `silent_budget`.

### 4.9 Tiering policy (Phase 7)

- **Routing precedence** (review Q5), in `noteTakenExit`:
  1. an exit that already has a live arm (sibling handoff, bridge, …)
     keeps it, which protects nsieve's tuned path;
  2. an unarmed attachable exit routes to exit-side;
  3. everything else keeps today's routes (prime side, replay side,
     head sibling).
- **Strikes.** A zero-progress receipt at an attachable exit that is not
  yet DONE does not strike the anchor. The exit is on its way to a side
  trace, and `hotexit + tryside` bounds the wait (Pall: exits never gate
  a trace; only recording aborts are penalised). A DONE exit without a
  side trace strikes as today. This is what keeps `:9` alive long
  enough to grow its tree.
- **Retiring the old routes** for attachable exits is not in v1. Phase 8
  measures whether same-anchor siblings still earn their keep there.

### 4.10 Determinism

Every decision is a pure function of deterministic state:

- `exit_counts`, wanted bits and DONE latches, charged exactly once per
  receipt;
- trace ids and `(proto, pc)` anchors, never addresses;
- the constants `hotexit`, `tryside`, `maxside` and
  the snapshot budgets.

Materialization is data-driven from IR snapshots and ordinals. Cell and
adapter addresses are storage, never inputs to a decision. The ten-leg
matrix (P-EBP-1/2) must hold with side traces firing, and every new test
asserts that they actually fire (trace shape plus arm counts), not just
output parity.

## 5. Bit-reverse under this design (the worked example)

The t1 root at `:9` (swap taken, 3 trips; a numeric `for`, so never
peeled) produces these side traces:

| Exit | Resume pc `P` | Side trace records | Links to |
|---|---|---|---|
| ei 60/65/70 (wrong trip count) | post-`while` `j = j + k` | `j = j + k`, the `for` back-edge | `:9` |
| ei 75 (4th trip taken) | `while` body | `j = j - k; k = k / 2`, back to the while header | `:55`'s root is peeled, so it unrolls up to the limit and links to `:9` |
| ei 12 (`i < j` false) | the no-swap successor | `local k = n`, then the while, unrolled for the observed trips | `:9` |

- **Types.** The post-`while` trace gets two fingerprint variants: `k`
  int (after 0 trips) and `k` float.
- **Nesting.** ei 12's trace has its own trip-count exits, which get
  side traces of their own. That is the same tree LuaJIT builds (T3,
  T5, T7, T8, …).
- **Steady state.** Each outer iteration runs t1 until its first
  mismatch, hops natively through the adapter into the side trace, and
  links back to t1 at `:9`. Once the region promotes, no rows are
  written.
- **Expected count.** About 8–12 side traces for bit-reverse, in line
  with LuaJIT's 8.

## 6. Goals

- LuaJIT's side-trace mechanism on mahina: exit-started recording from
  materialized exit state, resume-coherent native hops, sharing by
  resume pc.
- The fft bit-reverse anchors run as traces (§9).
- No change to any cold exit's behaviour or cost.
- Determinism, the ten-leg matrix and replay are intact.

## 7. Non-goals (v1)

- Register inheritance across the hop (deferred; adapters hand off
  through the slab).
- Peeled parents, exits inside inlined frames, side traces leaving the
  anchor frame, and precise-trace exits (all deferred, listed above).
- Replacing same-anchor siblings. They keep precedence where armed, and
  keep serving non-attachable exits, until measurement says otherwise.
- Snapshot serialization.

## 8. Open questions for review

- **Q1 — row policy.** Resolved in round 1: rows, plus silent promotion
  (§4.8).
- **Q2 — regions.** Resolved in round 1: intra-iteration edges of the
  parent's loop region (§4.8).
- **Q3 — snapshot liveness cost.** Keeping snapshot refs and store
  operands recoverable at every attachable guard (in a register, spill,
  home or the slab) may add register pressure to every trace. Parent
  recompilation is ruled out (round 1). Round 2: under pressure the
  allocator spills rather than fails (`SPILL_MAX = 512`), and a spilled
  snapshot ref is only read on the exit path. The extension applies
  only to attachable exits and their `.def` slots (§4.2). The cost is
  still measured on the board in Phase 4.
- **Q4 — peeled parents.** Resolved in round 1: deferred. Linking into
  peeled children is refused.
- **Q5 — routing precedence.** Resolved in round 1: live arms first
  (§4.9).
- **Q6 — non-branch resume.** Round 1's audit says guards precede their
  bytecode's register and heap writes, apart from the store guards
  (`guard_bounds`, `guard_fits`), which §4.1 handles by never applying
  `B`'s own stores. Phase 2 re-audits every emitter and makes
  `exitAttachable` refuse any guard emitted after a partial effect of
  its own bytecode. Round 2 agrees: `exitAttachable` asserts the guard's
  bytecode has made no irreversible effect before the guard.
- **Q7 — the exit's cell test without a scratch register.** Resolved in
  round 2, revised in round 3: `mov rax, imm64` with the cell's
  absolute address (§4.6). `rax`/`rcx` are never allocated, so nothing
  is disturbed. Reserving an allocatable register was rejected, because
  it would take one of the 9 GP registers from every trace (Rule Z-6).
  Round 2's RIP-relative cells were dropped: the mcode arena gives no
  ±2 GB placement guarantee.
- **Q8 — exec-log `ExitKind`.** Resolved in round 2: no new `ExitKind`.
  The parent logs its normal guard exit, and the hop shows up as the
  side trace's entry, as with `sibling_handoff`.

## 9. Performance budget (Rule #20)

- **fft.** `fft_bitreverse:9` and `:55` at ≥ 90% traced time
  (`--jit-stats`, `trc%time`), from 0.2% / 0.1% today. fft wall clock
  must fall by at least the tier-0 share those anchors lose. The
  estimate is ~200 → ~110 ms; the real number goes on the board.
- **Board.** No bench regresses by more than 3% on `just bench`
  (interleaved A/B against a `just shadow` baseline for anything
  flagged).
- **Compile and memory.** Snapshot + exit-location-map memory per trace
  no more than about 1× its IR bytes (the LuaJIT ratio). Recording and
  compile time on the board's largest traces measured before/after in
  Phase 1, when the data exists but is unused. That isolates the
  capture cost. Adapter mcode is reported per run and scales with
  attached exits only.
- **Side-trace count.** Bit-reverse lands in the 8–12 range. Any bench
  whose side-trace count hits `maxside` gets investigated, not raised.

## 10. References

- doc 55 §3 "Finding" (the diagnosis), §2d (runtime state in data).
- doc 17 §S (sibling handoff, anchor coherence), §S.8 (the deferral this
  doc takes up), P-EBP-1..4 (equivalence obligations), B-3 (silent
  promotion).
- doc 45 (precise snapshots, materializers, `.precise_resume`,
  outstanding optimizer integration).
- doc 38 (while-inner linking, unroll-first, `low_trip_while`), docs
  39/40 (peeling, the fusion exclusion and its open question).
- doc 54 P2 amendment (rowless transitions and their progress bound).
- LuaJIT: `lj_trace.c` (`trace_hotside`, `lj_trace_exit`,
  `trace_stop`), `lj_record.c` (`lj_record_setup`, `rec_comp_fixup`,
  `rec_loop_jit`, `rec_loop_interp`), `lj_snap.c` (`lj_snap_add`,
  `lj_snap_replay`, `lj_snap_restore`, `snap_usedef`), `lj_asm.c`
  (`asm_head_side`, `asm_tail_link`, `asm_snap_alloc`), `lj_asm_x86.h`
  (`lj_asm_patchexit`).

## 11. Review round 1 (Antigravity, 2026-09-24): CHANGES REQUESTED, dispositions

1. **BLOCKER — `PendingStore.pos` against post-`tropt` guard indices.**
   Accepted. Replaced with per-bytecode boundary ordinals carried on
   guards and on the sunk store IR instructions themselves (§4.2).
2. **BLOCKER — the tier-0 re-run reaches `P` several times inside an
   unrolled loop.** Accepted. The reviewer's fix was an occurrence
   count. The revision takes LuaJIT's order instead: materialize at the
   exit, then record from `P` (§4.4). The ambiguity disappears rather
   than being counted.
3. **BLOCKER — rowless hops break replay validation, the yield bound
   and cycle detection, and duplicate silent promotion (Z-8).**
   Accepted. Rows plus region classification plus silent promotion
   (§4.8); the rowless phase is removed.
4. **MAJOR — a bytecode's own sunk stores must not be applied at its
   guards.** Accepted: strictly earlier bytecodes only (§4.1, §4.2).
5. **MAJOR — linking into a peeled child is unsound** (its entry guards
   are the run-once types). Accepted: refused, so the side trace unrolls
   instead (§4.4, §4.6). Peeled parents are deferred. Verified: `:9` is
   a numeric `for`, and `isPlainWhileAnchor` never admits it to peeling
   (`trace_recorder.zig:181`).
6. **MAJOR — compile-time materializers at every attachable exit bloat
   mcode.** Accepted. Adapters are built per exit when it gets hot, from
   a compile-time exit location map (§4.6). This is also the seam where
   register inheritance will go.
7. **NIT — tier-1a materializes in `irinterp`, not `driveChain`.**
   Accepted (§4.7).

## 12. Review round 2 (Antigravity, 2026-09-24): APPROVE WITH CHANGES, dispositions

Receipt: `docs/reviews/doc56/antigravity-r2.md`. All seven round-1
findings were marked RESOLVED.

1. **MAJOR — owner election compares tagged pcs, so `.exit` members
   make every such region unarmable.** Accepted and verified
   (`trace_region_topology_build.zig:419`). Decode with `entryPc`
   (§4.8), landed first and on its own because it also affects cont
   members.
2. **MAJOR — Q7 must not reserve an allocatable register (Z-6).**
   Accepted and verified (`ALLOC_ORDER` has no `rax`/`rcx`,
   `nativegen_alloc.zig:180`). RIP-relative cells (§4.6, §8).
3. **MINOR — a dynamic table's base (`aref.a`) is a needed operand of
   its sunk array store.** Accepted and verified
   (`nativegen_alloc.zig:777`), §4.2.
4. **NIT — spell out `EXIT_PC_BIT` and its decoding.** Accepted:
   `1 << 30`, with the tighter compiler length contract (§4.4).

## 13. Review round 3 (independent sub-agent, 2026-09-24): CHANGES REQUESTED, dispositions

Receipt: `docs/reviews/doc56/subagent-r3.md`. Each claim was checked
against the source before it was accepted.

1. **BLOCKER — `loopDoneSnapshotSupported`/`emitLinkedLoopDoneSnapshot`
   cannot serve mid-body exits.** Verified (`trace_code.zig:495-503`:
   the scan from `exit_instr + 1` accepts only stores until the
   terminal). Every exit in §5's worked example would fail the gate.
   Replaced with an ordinal-bounded filter over the trailing store
   block; only the leaf store emitters are reused (§4.3, §4.6).
2. **MAJOR — the ±2 GB RIP-relative cell region is not something the
   mcode arena provides.** Verified (`nativegen_mcode.zig:124-131`,
   `:268-282`). Replaced with an absolute `mov rax, imm64` cell load,
   the §2d and precise-flush pattern (§4.6, Q7). The reviewer's
   phase-plan gap (build and test the RW region) goes away with it.
3. **MAJOR — the close-back row was waved through as "the same rule
   continuation traces follow".** Accepted and designed now (§4.8).
   - The hop in is a new `exit_side` row with its own arm and cursor
     transition.
   - The close back is the existing `link_terminal` row. Its checks
     (`isInnerLoopRoot`, `trace.zig:2287`) and its cursor state
     (`link_pc` = the loop root's anchor) were read and hold as they
     are.
   - The completion rule is stated.
   - The reviewer's worry that `isInnerLoopRoot` would reject the
     parent does not hold: it only requires a `.loop`-tailed trace at
     `(proto, aux)`.
4. **MINOR — `arm` validation vs the `sibling_handoff` re-proof
   precedent.** Accepted. The attachable verdict is a stored pure
   function of the immutable parent; child-side checks are re-run
   (§4.6).
5. **NIT — "snapshot ids are not ordered" was wrong.** Accepted.
   Corrected, with the real reason: sunk stores have no snapshot
   record (§4.2).
6. **Unverified item — are exit counters charged once per tier?**
   Added as a Phase 3 test.

## 14. Review round 4 (same sub-agent, 2026-09-24): CHANGES REQUESTED, dispositions

Receipt: `docs/reviews/doc56/subagent-r4.md`. Round-3 findings 1–5
were marked RESOLVED, and the unverified item PARTIAL (it became a
test). The `link_terminal` reuse was verified sound.

1. **MAJOR (R4-F1) — `resolvePatchPc`/`installEntryPatch` switch on
   `AnchorPcKind` and the doc never said what `.exit` does there.**
   Verified (`trace_entry_registry.zig:101-138`). Following it further
   turned up about 30 non-exhaustive `!= .loop` / `== .cont` sites that
   a new kind would fall into silently. Among them are the arm funnel's
   `head_parent` restriction (`trace_link.zig:1664`, one-shot parents
   may carry only `sibling_handoff` arms, which would have blocked
   nested side traces) and the head-sibling route in `noteTakenExit`
   (`trace_link.zig:355`). The resolution is structural, not a patch per
   site. Revision 5 drops `AnchorKind.exit`: an exit-side trace is a
   `.continuation` trace at raw `P`, whose contract is identical (§4.4).
   This also supersedes round-2 findings 1 and 4: there is no tagged pc,
   so no owner-election decode and no `EXIT_PC_BIT`.
2. **MINOR (R4-F2) — the precise-retry threshold switch
   (`trace.zig:3619`).** Verified, and dissolved by the same change:
   continuation anchors are `.loop`-kind already.
3. **MAJOR (R4-F3) — "committing kind" spans four sites and two
   accounting axes.** Verified (`trace_chain.zig:1670`,
   `trace_link.zig:745/907`, `nativegen_emit.zig:1287-1443`,
   `trace_exec.zig:285`). §4.8 now has a table with the value and
   reason at each site, and tests for rowed/silent agreement and for
   strike behaviour.

## 15. Review round 5 (same sub-agent, 2026-09-24): APPROVE WITH CHANGES, dispositions

Receipt: `docs/reviews/doc56/subagent-r5.md`. R4-F1/F2/F3 were marked
RESOLVED. The continuation equivalence was attacked at every layer and
verified sound:
- `maybeStartContinuation` never asks why the anchor is pending;
- `continuationReachesEnclosingBackEdge` works for exits, including
  nested ones;
- region membership is purely structural (no `ArmKind` in
  `trace_region_topology_build.zig`), so no fifth accounting site.

1. **MAJOR (R5-F1) — `pending_anchor_base` must be set at the exit
   site too.** Verified (`trace_link.zig:231`, `interp.zig:6314`).
   §4.4 now requires it, with the reason and a Phase 3 test.
2. **MINOR (R5-F2) — the arm funnel's `head_parent` refusal.**
   Verified (`trace_link.zig:1664`). Added to §4.6's validation list.
3. **NIT (R5-F3) — loop-done-only comments on `pending_exit_anchor`
   and its neighbours.** Added to Phase 3.
