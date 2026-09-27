# 58 — `while` loops in LuaJIT's shape: a loop op after the condition (doc 56 G5)

**Status:** draft rev 3: **Option B, LuaJIT's `BC_LOOP` shape**
(Bart, 2026-09-27; §4). Reviewed (§8, APPROVE WITH CHANGES, folded
in); B0 next. Rev 2's Option A
design and its review are kept as Appendix R2.
**Owner:** claude
**Last updated:** 2026-09-27

## Implementation status

### Done

- [x] Diagnosis (doc 56 §4.8.2 G5, §4.8.3 "Phase 6 landed", §4.8.4).
- [x] Fact map of today's numeric-`for` and `while` loop-done paths
  (§3, with file:line references).
- [x] Rev 2 (Option A) review round 1: APPROVE WITH CHANGES
  (Appendix R2). It was superseded by the choice of B.
- [x] Mechanism chosen: B (§7 records why the question was moot).
- [x] Inventory of every site that depends on the condition anchor
  (§4.1).

### Outstanding

- [x] Rev 3 design review: r2 CHANGES REQUESTED, r3 APPROVE WITH
  CHANGES, all folded in (§8).
- [x] B0: baseline (§5, "B0 done").
- [ ] B1: the `loop` op is emitted and every walker knows it; inert
  (§5).
- [ ] B2: `while`/`repeat` anchors move to after the `loop` op; the
  condition guard becomes an ordinary exit; the machinery whose
  premise was the condition anchor is deleted (§5).
- [ ] B3: `repeat` and low-trip probes (§5).
- [ ] B4: measure with the doc 56 switch off and on; flip it; re-run
  doc 56 §4.8.4's G6 experiment (§5).

## 1. The problem

A `while` loop that has its own root trace ends every time through a
runtime round-trip. The loop's exit (the condition going false) is an
ordinary guard failure: the native code flushes, writes a `.deopt`
row and returns to the dispatcher. From there, one of two things
happens:

- A one-row ledger goes through the `.while_done` chain
  (`interp.zig` ~4454–4600): the dispatcher finds the continuation
  anchored after the loop and runs it through `driveChain`.
- A longer ledger (the `while` root was reached by a link from another
  trace) is drained by `driveDispatcherLedger` first. Its replay
  resumes tier-0 at the `while` **header** (`.deopt` arm (b),
  `trace_chain.zig` ~2437–2452), and tier-0 re-runs the condition.

Numeric `for` loops do not pay this. Their loop-done exit has a native
link (`loop_done_linked`): the exit jumps straight into the
continuation trace after the loop, and the cycle can go silent.

**Evidence.** fft's bit-reverse (`while k <= j do … end` inside a
`for`):

- Switch on (doc 56 exit adapters): about 20k of 22k ledgers end at
  the inner `while` root's loop-done `.deopt` (t2 exit 5), so the
  armable cycle never fills a ledger and never promotes (doc 56 §4.8.3
  "Phase 6 landed"). fft's seam is 26% of the run.
- With doc 56 §4.8.4's G6 change (side recordings link to the outer
  root): switch on, the seam is 35% of a 131 ms run; switch off, the
  new cycles pay 540k ledger walks and fft goes 215 → 512 ms. G5 is the
  blocker for G6 option (a).

This is general: every `while` loop whose exit continues in traced
code pays a runtime round-trip per exit. Doc 38 (`while`-inner
linking) built the link INTO a `while` root; nothing links OUT of one.

## 2. What LuaJIT does

LuaJIT has no loop-done kind at all, for either loop shape.

- `parse_while` (`lj_parse.c` ~2413–2430) emits the condition, the
  exit jump, `BC_LOOP`, the body, and `JMP` back. A root trace starts
  at `BC_LOOP`, which is AFTER the condition, so the condition guard
  sits at the END of the trace.
- `rec_comp_fixup` (`lj_record.c` ~2205–2224) rewrites that guard's
  snapshot to the branch target NOT taken — the pc after the loop —
  and shrinks `maxslot`. So the exit resumes after the loop with the
  post-body state.
- It is an ordinary exit: it gets hot (`trace_hotside`), a side trace
  is recorded from it, the exit is patched to jump there
  (`lj_asm_patchexit`), and the side trace links on
  (`rec_loop_jit` → `LJ_TRLINK_ROOT`).
- `FORL` is the same: `rec_for` (`lj_record.c` ~567–585) takes the
  snapshot at the pc after the loop.

So in LuaJIT a `while` exit is served by the ordinary side-trace
mechanism — in mahina terms, doc 56's exit-side adapters.

## 3. What mahina has today

### 3.1 Numeric `for`: `loop_done_linked`

- **Identification** is structural: `TraceCode.isNumericForLoopDoneGuard`
  (`trace_code.zig` ~622–642) and `trace.isLoopDoneGuardIndex`
  (`trace.zig` ~181–210): a `guard_true` whose source op is `for_loop`.
- **Slot.** The guard's own `slots[ei]`, reserved for the loop-done
  link ("P-C option (b)", `trace.zig` ~270–276; enforced in `arm`,
  `trace_link.zig` ~1994–2013).
- **Arming.** `armLoopDoneLink` (`trace_link.zig` ~2225–2268):
  `post_pc = guardExitPc`, target from `resolveLoopDoneCont` (a
  `.link`-tailed trace at `post_pc`), `ArmKind.loop_done_linked`, into
  the continuation's `ordinary_entry`.
- **Native.** A runtime mode flag `NativeResult.linked_loop_done`
  (set by the `linked_entry` stub or the run wrappers). The exit stub
  (`nativegen.zig` ~2594–2615) branches to a linked label only in that
  mode; the label (`~2668–2686`) runs `emitLinkedLoopDoneSnapshot`
  (commits the final iteration's sunk stores and flushes every
  slot-bound φ except the visible loop variable), `completed = rbx`, the
  silent site, the `.loop_done_linked` row, and `jmp [slot]`.
  In mode 0 the exit skips the slot and deopts (tier-0 replays the
  final iteration from the anchor).
- **Replay** (`trace_chain.zig` ~2074–2181): region work 1, selection
  work `max(local, 1)`, `linked_completed += 1` (the final iteration
  ran in the trace), resume at `post_pc`, and on a non-terminal row the
  cursor moves to the continuation. The silent epilogue's
  `.loop_done_linked` arm matches it.
- **Regions:** `resolveSuccessorAnchor` gives the guard a structural
  edge to `guardExitPc` (`trace_link.zig` ~889–894); owner election
  uses `forLoopEndFor` (`trace_region_topology_build.zig` ~407–421).

### 3.2 `while` roots

- **Shape.** The root is anchored at the condition. The condition
  guard (`guard_true`, role `.branch_cond`) sits at the TOP of the
  trace; a root that sees its own exit direction aborts LLEAVE
  (`trace_recorder.zig` ~3295–3370).
- **Identification:** `TraceCode.whileLoopDonePostPc`
  (`trace_code.zig` ~650–679): `guard_true` sourced at a
  `jmp_if_false` whose forward target is preceded by a `jmp` back to the
  anchor; the post-loop pc is that jump target. `isWhileLoopDoneGuardIndex`
  wraps it (`trace.zig` ~212–238).
- **State at the exit.** The failing pass ran only the condition
  prefix. Completed iterations are already committed at their `.loop`
  terminals, so no final-iteration flush is owed: after the ordinary
  deopt flush of carried homes, the registers are coherent at the
  anchor AND at the post-loop pc (`trace.zig` ~224–228; `interp.zig`
  ~4583–4587; `trace_chain.zig` ~525–531). This is the one big
  difference from numeric `for`, and it makes the native side simpler:
  the ordinary flush is the right materialization.
- **Native today.** The guard takes the ordinary path: its exit stub
  stages `slots[ei]` as the exit target, `deopt_exit` flushes the
  carried homes, appends a `.deopt` row and jumps to the target
  (`nativegen.zig` ~2654–2663, ~2722–2775). An armed `slots[ei]` is
  already followed — that is how a sibling handoff works.
- **What's missing** compared with numeric `for`:
  1. no arm kind accepts the exit (`arm`, `armLoopDoneLink` and
     `hasNativeLoopDoneLink` are numeric-only);
  2. `guardExitPc` is the loop BODY for a `while` guard, not the
     post-loop pc, and it is used as "the post-loop pc" in four places
     (`driveChain` ~295, `armLoopDoneLink` ~2236, promotion validation
     `trace_link.zig` ~1196, replay ~2087);
  3. replay resumes a while-done `.deopt` row at the `while` header;
  4. no region edge (`resolveSuccessorAnchor` is numeric-only; exit
     attach refuses the exit; it is not a bridge candidate), and owner
     election fails for `while` roots ("non-numeric roots
     conservatively fail", `forLoopEndFor`);
  5. the slot is not reserved: `siblingHandoffEligible` excludes only
     numeric loop-done guards (`trace.zig` ~1858), so the doc 38
     "glue figure-eight" sibling handoff can hold `slots[ei]` today.
- **Doc 56 refuses it** as an exit-side exit: `resumeOf` returns
  `.refused = .loop_done` for any `whileLoopDonePostPc` guard
  (`trace_exit_attach.zig` ~346–351; Bart's "refuse while-done").
- **Side effects in the condition.** The `.while_done` chain never
  checks `exitIsPreEffect` on the condition prefix (`interp.zig`
  ~4461–4463); doc 38 accepted this as a known concern.

## 4. The design (rev 3): a `loop` op after the condition

### 4.0 The idea in one paragraph

Give mahina LuaJIT's `BC_LOOP`. `compileWhile` emits a `loop` op
right after the condition's `jmp_if_false`, and `compileRepeat` emits one at
the loop top. The `loop` op does nothing in tier-0 except act as a back-edge
whose target is the next instruction, the start of the body. Backward
`jmp`/`jmp_if_false` stop being back-edges. After this, **every loop's
anchor is the start of its body, and its test sits at the end of the
trace**: `for_loop`, `tfor_loop` and `repeat` are already shaped like that,
and `while` joins them. The condition guard of a `while` root then sits
at the end of the trace. Its exit resumes at the post-loop pc through
the branch fix-up `resumeOf` already does (LuaJIT's `rec_comp_fixup`).
Doc 56's exit-side traces serve it like any other exit, which is how
LuaJIT serves it. Everything doc 38 built around a condition at the
top of the trace, like the `.while_done` chain, goes away.

### 4.1 What depends on the condition anchor today

An inventory (2026-09-27) found about 95 non-test sites and about 45
tests. Most of them derive "the anchor" from "the target of a backward
jump". **Defining the `loop` op as a back-edge whose target is `pc + 1`
keeps the rule "anchor = back-edge target" true**, so most of those
sites need no change: hot counting (`skipBackEdge`, `onBackEdge`,
`hotcount`), `backEdgeEpilogue` and its trace entry, gates, coverage,
`arm`, and `consumeRecordingAbort`'s counter rewinds. What does
change, grouped:

| Group | Sites | §4 item |
|---|---|---|
| Compiler, tier-0 dispatch, patching | `compileWhile`, `compileRepeat`, `opJump`, a new `opLoop`, `opJLoop`, `patchedEntryOp`, `resolvePatchPc`, `installEntryPatch`, `recordingMirrorInstr`, `onRetResume`'s closer list | 4.2 |
| Walkers | `bc_liveness.effectOf`, `interp.handlerFor`, `writeInstr`, `backEdgeTarget`/`isLoopHeader`/`buildMemo`, `continuationReachesEnclosingBackEdge`, `resolveCompositeBridgeSuccessor`, `isPlainWhileAnchor` | 4.2, 4.6 |
| Recorder | the `.jmp` handler (`recWhileLink`), a new `.loop` handler, `recordInstr`'s inner-root lookup, `recBranch`'s LLEAVE arms, `isOwnWhileTestCopy` | 4.3 |
| The exit | `whileLoopDonePostPc` and every user, `ExitMaterialization.while_done`, the `.while_done` chain, `whileDoneCoherentAtZero`, `resumeOf`'s refusal, `maybeArmContinuation`'s `while` leg | 4.4, 4.5 |
| Topology | `forLoopEndFor` → a loop-extent helper for any loop op | 4.6 |
| Tests | the doc 38/39/40/56/57 `while` tests, `trace_entrypatch_test`, `interp_lanes_test`'s `jloop` tests, `trace_exit_attach_test`'s fixture | 4.8 |

### 4.2 The bytecode op and tier-0

- **`OpCode.loop`**, appended to the end of the enum (it must stay dense,
  as `jfunc_head` and `jcont` were). The name matches LuaJIT's `BC_LOOP`.
  The patched image op stays `.jloop` (LuaJIT: `LOOP → JLOOP`). The IR
  terminal `.loop` is a different enum; the two never meet in one
  switch.
  - `b` = the loop kind: 0 `while`, 1 `repeat`. The peel gate
    (§4.6) needs it; nothing else does.
  - `aux` = offset from `pc + 1` to the loop's exit pc, the first
    instruction after the loop. It is patched at the end of the loop,
    like LuaJIT's `jmp_patchins(fs, loop, fs->pc)`. Owner election
    (§4.6) reads the extent from it.
  - `a` is unused. LuaJIT uses `A` to shrink `maxslot`; mahina's
    snapshots use `Proto.reg_live` (doc 56 Phase 1).
  - Because `aux` is the exit offset, the usual `pc + 1 + aux` target
    formula is wrong for a `loop` op. So **one helper,
    `bytecode.loopHeaderOf(ins, pc) ?u32`**, gives a loop op's header
    for all three ops: `for_loop`/`tfor_loop` → `pc + 1 + aux`, `loop`
    → `pc + 1`, anything else → null. Every walker that today computes
    a loop header from `aux` (`resolvePatchPc`, `isPlainWhileAnchor`,
    `trace_exit_attach.backEdgeTarget`/`isLoopHeader`) switches to it,
    and it replaces the local copies.
  - Two walkers need the loop's extent, not its header: `linkKindAt`
    (review r2 finding 6) and owner election (§4.6). **`loopExtentFor(proto,
    header) ?{ start, end }`** gives the first and the last
    instruction of the loop whose header is `header`:
    - numeric `for`: `[header, the for_loop]`;
    - generic `for`: `[header, the tfor_loop]`. The forward `jmp` to
      the test block at `header − 1` runs only on entry, like
      numeric `for`'s `for_prep` (review r3 finding 3);
    - `while`: `[C, E − 1]`;
    - `repeat`: `[the loop op, the closer]`.

    It is one function, and it replaces both copies of
    `forLoopEndFor` (`trace_link.zig` ~827 and
    `trace_region_topology_build.zig` ~27, review r2 finding 8).
    `linkKindAt(header)` reports `.enclosing_iteration` when the
    recording's anchor lies inside that extent.
- **`compileWhile`**: `cond; jmp_if_false → exit; loop; body; jmp → cond`.
  **`compileRepeat`**: `loop; body; cond; jmp_if_false → loop`. The
  backward branch targets the `loop` op, not the body. This is LuaJIT's
  `parse_repeat`.
- **Tier-0 `opLoop`**: if tracing is on, `musttail` into `backEdgeHandler`
  with target `pc` (the handler's `pc` is already the next
  instruction, the body start); otherwise go to the next instruction.
  So hot counting, trace entry, gates and coverage all run exactly
  once per iteration, keyed on the body start, as for `for_loop`.
- **`opJump` loses its backward-jump test.** No backward jump is a
  back-edge any more, since the compiler has no `goto`. Numeric and
  generic `for` keep their own back-edge handlers. A debug check in the
  compiler (run at the end of each proto) pins the two closer shapes,
  which are the only backward jumps (review r2 finding 4):
  - `while`: a backward `jmp` at `E − 1` targets `C`, where `C` is
    the loop's first condition instruction. The `loop` op sits at
    `m`, with `code[m − 1]` a `jmp_if_false` to `E`, and
    `C ≤ m − 1 < m < E`.
  - `repeat`: a backward `jmp_if_false` targets a `loop` op of kind
    `repeat`.
- **Patching** (doc 20 Phase 3): `patchedEntryOp` maps `.loop → .jloop`,
  `.tfor_loop → .jloop`, `.for_loop → .jfor_loop`. `.jmp` and
  `.jmp_if_false` are never patched. `resolvePatchPc` keeps its rule
  (the unique closer whose header is the anchor) but reads the header
  through `loopHeaderOf`, and drops its "target is backward" test: a
  `loop` op's header is forward. In `opJLoop`, the `.jmp` and `.jmp_if_false` arms
  of `patch.orig` go away; the `.loop` arm always "takes" its
  back-edge.
- **Tier-0 cost.** A `while` or `repeat` iteration runs one more
  instruction, the `loop` op, and `opJump` loses a compare. LuaJIT pays
  the same. B0/B4 measure the tier-0 legs of pi_leibniz,
  nsieve-bit-fp and fft. Budget: no tier-0 bench more than 2% slower.
- **Walkers.**
  - `bc_liveness.effectOf`: `loop` reads and writes nothing, and
    falls through.
  - `writeInstr` prints `loop` with its kind and exit offset.
  - `backEdgeTarget`/`isLoopHeader`/`buildMemo`: a `loop` op's header
    is `pc + 1`.
  - `continuationReachesEnclosingBackEdge` keeps its `jmp` arm (review
    r2 finding 3). It scans forward from the post-inner-loop pc, so
    what it meets is the enclosing loop's physical bottom: a `while`'s
    backward `jmp`, whose target (the condition) is still before the
    inner anchor. The `loop` op itself sits at the top, behind the
    scan.
    - A `repeat`'s bottom is a backward `jmp_if_false`, and today the
      function has no arm for it. That is a pre-existing gap (review
      r3 finding 4): a loop inside a `repeat` never arms a
      continuation.
    - B2 adds the arm. Its target is the `loop` op, which is before the
      inner anchor.
  - `resolveCompositeBridgeSuccessor` walks through a `loop` op.
  - `onRetResume`'s closer list learns `.loop`. `recordingMirrorInstr`
    already mirrors `.jloop` from `proto.code[pc]` (review r2 finding
    9); the recorder's `.loop` handler is §4.3's.
- **Determinism and replay.** Hot counts stay deterministic counters,
  keyed on the same `(proto, pc)` shape. Keyframes and the trace file
  store pcs, not ops. `anchor_pc` keeps its schema meaning ("loop
  header pc" = the back-edge target). Traced and interpreted coverage
  now agree for `while` loops: today the interpreted side is keyed at
  the back-edge target and the traced side at `t.code.anchor`, and
  those are the same pc. The viz fixture is a numeric `for` and does
  not change.

### 4.3 Recording

- **Root start.** A root arms when the `loop` op crosses `hotloop` and
  starts recording at the body. LuaJIT starts at the `LOOP` op too,
  with `pc++` in `rec_setup_root`. Doc 39's finding that "a root can
  never start at trip 1" stops being true, because the `loop` op
  counts on trip 1. LuaJIT behaves the same way; §4.6 checks the peel
  against it.
- **Close.** The body's backward `jmp` is recorded as nothing (LuaJIT
  `BC_JMP` only shrinks `maxslot`). The condition is recorded next and
  its branch becomes a guard. Falling through to the `loop` op then
  calls `onBackEdge` with target = anchor, and the trace closes, the
  same path `for_loop` takes.
- **LLEAVE** (`recBranch`): the own-loop test becomes structural and
  local. For `while`, the branch is at `b`, `code[b + 1]` is a `loop`
  op, and `b + 2 == anchor`; the recorded direction leaves the loop.
  For `repeat`, the backward `jmp_if_false` targets `anchor − 1`, a
  `loop` op, and the recorded direction falls through. The fast-retry
  budget (`lleave_fast_retries`) and `lleave_count` stay: they are
  deterministic evidence about trip patterns, not about where the
  condition sits. B4 re-measures them; LuaJIT has no fast retry.
- **Links into an inner loop** (doc 38 `recWhileLink`): these move from the
  inner loop's backward `.jmp` to its `loop` op, which is LuaJIT's
  `rec_loop_jit` on `JLOOP`.
  - A continuation or side recording that reaches another loop's
    `loop` op, when a root exists at `pc + 1`, closes with `.link` to
    that root.
  - A root keeps the unroll-first policy (`unroll_while`,
    `unroll_fail`, LINNER), keyed on the `loop` op's target.
  - If the inner condition is false on arrival, the recording has
    already recorded that guard and simply continues past the loop.
    This is LuaJIT's "side trace continues across a loop that's left
    or not entered". The inner root is never entered for zero trips.
  - `recordInstr`'s inner-root lookup reads the `loop` op's target
    instead of a `.jmp` target.
  - The `.jmp` handler becomes a no-op.
- **The loop's own test is a loop exit, not a branch** (review r2
  finding 5). `isSourceBranchGuardExit` must not treat it as a branch
  alternation. If it did, `noteTakenExit` would raise
  `wants_prime_side` and unpatch the entry, and the dispatcher would
  chain same-anchor siblings on every loop completion. Today
  `isLoopTestCopy` and the `for_loop` check keep those out for `for`
  loops, and `whileDoneHotnessEligible` keeps them out for `while`.
  `repeat`'s own test is NOT kept out today; that is a gap.
  - B replaces these with one structural classifier,
    **`TraceCode.isOwnLoopTest(idx)`**: a depth-0 guard whose source
    instruction is the test of the loop whose header is the trace's
    anchor. That is:
    - a `for_loop` with `loopHeaderOf == anchor`;
    - a `jmp_if_false` followed by a `loop` op with header == anchor
      (`while`);
    - a backward `jmp_if_false` to a `loop` op with header == anchor
      (`repeat`).
  - It matches every unrolled copy, because a copy has the same source
    instruction. It needs no role.
  - **A loop exit feeds only exit-side** (review r3 finding 1).
    - `isSourceBranchGuardExit` excludes it.
    - `noteTakenExit` returns right after `routeExitSide` for it. This
      stops it falling into the `completed == 0` same-anchor side want,
      which would unpatch the entry and record a pass that ends in
      LLEAVE.
    - The dispatcher's hotness classification (`interp.zig` ~4452–4467:
      `any_loop_done` / `count_exit`) reads `isOwnLoopTest` in place
      of the loop-done classifiers.
    - Today numeric-`for` loop-done exits are already kept out of
      hotness in this way; B makes all loop kinds uniform. The doc 38
      glue channel (a same-anchor sibling grown from the `while` exit)
      stops forming. Its LuaJIT counterpart is the side trace from the
      exit, which is exit-side's job.
  - The `while` condition guard keeps role `.branch_cond`. That role
    describes the shape of the guard, and `resumeOf` needs it for the
    branch fix-up.
  - `isOwnWhileTestCopy` and the `while` use of `.loop_test_copy`
    go. The role existed so the top-of-trace `while`-done classifier
    would not claim a later pass's condition (doc 57's mutation
    proof: a wrong answer through the `.while_done` chain's no-flush
    resume). That classifier is gone. Numeric `for` copies keep the
    role, because `isNumericForLoopDoneGuard` and the native
    loop-done link need it.
  - Behaviour change: `repeat` loop exits stop feeding
    `wants_prime_side`. No bench has a `repeat` loop; B3 measures
    with a probe.

### 4.4 The exit

The failing pass ran the whole body, then the condition. The guard's
exit is an ordinary exit:

- **State.** The per-exit snapshot at the guard (doc 56 Phase 1)
  describes the state after the body. `resumeOf`'s branch fix-up
  gives `P` = the post-loop pc. That is LuaJIT's `rec_comp_fixup`.
  `resumeOf`'s `while` refusal is deleted.
- **Who serves it:**
  - **Native, doc 56 switch on:** the exit adapter materializes at
    `P`. An exit-side child (a `.continuation` at `P`) is recorded,
    the exit is armed (Phase 5) and the cycle can go silent
    (Phase 6). This is LuaJIT's side trace from the exit, patched in.
  - **Tier-1a:** exit-side routing (on by default).
  - **Native, switch off:** the ordinary coarse deopt. Tier-0 replays
    the final pass from the anchor: the body and then the condition.
    Today it replays only the condition. So B makes a low-trip `while`
    pay one extra tier-0 body pass per exit until the switch flips.
    That is why B4 flips the switch in this arc. The flip was already
    queued behind G5 (this doc) and G6.
- **Why the coarse deopt is sound** (review r2 findings 1–2 claimed it
  runs the body twice; rejected). A coarse deopt does not resume
  with the state after the body. It resumes at the anchor with the
  state at the START of the failing pass:
  - Carried values live in their homes, and the homes are updated only
    at the back-edge shuffle. So `deopt_exit` flushes the values the
    pass started with (`nativegen.zig` ~2724–2760).
  - Stores are sunk until the `.loop` commit.
  - Tier-1a side-exits "before committing a partial iteration"
    (`interp.zig` ~6495–6501).

  Tier-0 then runs the pass once: the body, then the false condition,
  then out. With `while n < 3 do n = n + 1 end`, the last pass starts
  at `n = 2`, the trace computes 3, the guard fails, the deopt restores
  2, and tier-0 computes 3 and exits. Every guard in the middle of a
  numeric `for` body relies on this same contract today.
  - A precise trace (doc 45) resumes at the guard's own pc from its
    snapshot, where tier-0 evaluates the branch and leaves.
  - A peeled trace with zero local completions skips the flush and
    replays both passes from the entry state (doc 39).

  So all three paths are correct. The only cost is the replayed body
  pass, which is the performance point above, not a soundness one.
- **Zero trips no longer exist at a root.** A root is entered at the
  body, so every entry runs at least one pass. A loop that runs zero
  times never reaches its `loop` op; its condition runs in tier-0,
  or in the enclosing trace as an ordinary guard.

### 4.5 What is deleted

These all exist because the condition sat at the top of the trace.
With B their premise is gone, so they are deleted, not adapted
(Rule Z-7):

- `TraceCode.whileLoopDonePostPc`, `trace.whileLoopDonePostPc`,
  `isWhileLoopDoneGuardIndex`, the `while` leg of
  `isAnyLoopDoneGuardIndex`, `whileDoneCoherentAtZero`.
- `ExitMaterialization.while_done`, and the `.while_done` chain in the
  dispatcher (`interp.zig` ~4452–4600), in `driveChain` (`walk_pc`,
  the no-flush arm) and in the linked burst (`trace_chain.zig`
  ~2940–2980).
- `maybeArmContinuation`'s `while` leg. The exit-side route arms the
  continuation at `P`.
- The special cases in `trace_regionops.zig` (~129–137, zero-completion
  receipts) and in `interp.zig` (~4645, the same-anchor sibling
  exclusion).
- The doc 38 glue channel: `whileDoneHotnessEligible` and
  `while_glue_max_avg`. The exit becomes an ordinary exit for hotness
  and exit-side wanting. Whether a same-anchor glue sibling still
  forms (body → condition false → outer tail → back to the `loop` op)
  is then up to the generic sibling rules and doc 56 R1 ("the stub
  yields to a live ordinary arm").
- The `.low_trip_while` gate: `noteWhileYield`, `WhileYield`,
  `while_yield_window`, `while_yield_min_avg`, `GateReason.low_trip_while`,
  and its exemptions (`clearDispatchGate`, region amnesty). The gate
  exists because each `while` exit paid a runtime round-trip that
  cost more than tier-0 (doc 38 "Topology arbitration"). With the
  switch on, an armed exit pays no round-trip. B4 measures the
  low-trip shapes (fft bit-reverse, the `j = i % 64` nest from doc
  38) against it. If they regress, the fix goes into the exit-side
  path, not back into a `while`-specific gate.
- `isOwnWhileTestCopy` (§4.3).
- The doc 38 `.jmp`-based `recWhileLink` detection (it moves to `.loop`,
  §4.3).

Kept, re-keyed on the `loop` op: unroll-first (`unroll_fail`,
`unroll_fail_flip`), LINNER, LLEAVE and its fast retry,
`gateNativeUnsupported`'s compiled-sibling exemption, and the peel
(§4.6). None of these depends on where the condition sits.

### 4.6 Peel, regions, bridges

- **Peel** (doc 39/40). `maybeEnterPeel` is shape-agnostic apart from its
  gate. `isPlainWhileAnchor` becomes: `code[anchor − 1]` is a `loop`
  op with kind `while`. It keeps today's scope (only `while` loops
  peel; `repeat` and `for` loops do not). Under B:
  - The run-once pass and the steady pass are each body, then
    condition. The doc 39 "STEADY loop-done at zero completions owes
    a replay" hazard came from the `.while_done` chain resuming
    without a flush. That chain is gone, and a peeled trace's
    condition exit takes the ordinary path. Doc 56 defers adapters
    for peeled parents, so that path is a coarse deopt, which
    `deopt_exit` already handles for a peeled trace (the
    `rbx == entry_rbx` skip replays from the anchor).
  - Recording can now start on trip 1, so the doc 39 reset-to-int
    family (`k = n`, int on trip 1, float after) can now be recorded
    at an int entry. That is the peel's original motivation. B4
    checks whether fft's bit-reverse now peels or bails, and records
    the finding.
- **Regions.** An ordinary branch exit to `P` already gets a plain guard
  edge to `P` when it is an exit-side exit (doc 56 Bug 2 fix). So
  `resolveSuccessorAnchor` needs no `while` case. Owner election
  replaces `forLoopEndFor` with `loopExtentFor(anchor)`, which
  handles all three loop ops:
  - numeric `for`: today's rule;
  - `while`/`repeat`: from the `loop` op's `aux` to the exit pc, back
    to the loop's first instruction (the condition for `while`, the
    `loop` op for `repeat`);
  - generic `for`: from the `tfor_loop`.

  This removes "non-numeric roots conservatively fail". The member
  test (`trace_region_topology_build.zig` ~419, today
  `b.pc <= a.pc or b.pc > flp`) checks both ends of the extent. A
  `while` member in the condition has `pc < anchor` and is still
  inside the loop (review r2 finding 8).
- **Bridges.** `classifyBridgeCandidate` is anchor-relative
  (`exit_pc >= anchor.pc` refuses). A `while` exit to the post-loop pc
  is past the anchor, so it is refused, as the numeric-`for` loop-done
  exit is. Exit-side serves it instead.

### 4.7 Why this is sound (the review should attack these)

1. **Coarse deopt at the new anchor.** Every committed iteration ends at
   the `loop` op, so the state at the anchor is the state after a
   true condition. Tier-0 resuming at the anchor re-runs body and
   condition. That is the same contract `for_loop` anchors have today.
2. **Entry.** A trace is entered only from `opLoop`/`opJLoop` (after
   a true condition) or from a `.link` recorded at a `loop` op (also
   after a true condition). No path enters with the condition
   unevaluated.
3. **Condition side effects** (old G5-Q3). A condition with effects
   now runs inside the pass like any body code. Its guard is an
   ordinary guard after those effects, covered by precise deopt (doc
   45) or by the ordinary pre-effect rules. There is no longer a
   "condition prefix before the anchor" to reason about. Doc 38's
   accepted concern goes away.
4. **`break`.** A `break` jumps forward to the exit pc, past the `loop`
   op, exactly as today. On trace, it is an ordinary exit or the
   recorded path.

## 5. Phases

Each phase lands behind `just test` and the jit-debug gate. The
increments are slices of the final shape, not scaffolding.

- **B0 — baseline.** Board. Tier-0, native (switch off) and native
  (switch on) timings, best of 5, for pi_leibniz, nsieve-bit-fp, fft,
  `/tmp/bitrev.lua`, and the doc 38 `j = i % 64` nest (recreated and
  copied into this doc). `--jit-stats` for each. Shadow build at the
  B0 commit.
  - **B0 done (2026-09-27, HEAD 062a9b0).**
    - Board: `bench/results/20260927-132931-9c98fcd.tsv`. There are no
      code changes since that board.
    - Timings: best of 5 wall ms, `/tmp/b0.sh` (ReleaseFast). LuaJIT
      is best of 5 (fft best of 3).

      | program | tier-0 | native | native + switch | LuaJIT |
      |---|---|---|---|---|
      | lowtrip (below) | 331 | 201 | 197 | 34 |
      | hightrip (below) | 727 | 72 | 81 | 156 |
      | `/tmp/bitrev.lua` | 210 | 226 | 236 | 13 |
      | pi_leibniz | 1784 | 364 | 363 | 46 |
      | nsieve-bit-fp 6 | 282 | 309 | 306 | 19 |
      | scimark-fft 500 | 680 | 211 | 220 | 22 |

    - `--jit-stats` (native, switch off):
      - lowtrip: 99% of iterations traced, but the seam is **74% of
        the run** (123k `replayLedger` walks at about 9.3k cycles each).
      - bitrev: 0.1% traced (the `.low_trip_while` gate); tier-0 with
        a trace is 99%.
      - nsieve-bit-fp: 31% traced; tier-0 with a trace is 49% of the
        run.
    - Probe sources:

      ```lua
      -- /tmp/lowtrip.lua: doc 38's bounded-variance nest, ~5 trips/entry
      local floor = math.floor
      local s = 0
      for i = 1, 2000000 do
        local j = i % 64
        while j > 0 do j = floor(j / 2); s = s + 1 end
      end
      print(s)
      -- /tmp/hightrip.lua: ~100 trips/entry, a while and a repeat
      local s = 0
      for i = 1, 200000 do
        local k = 0
        while k < 100 do k = k + 1; s = s + k end
        local r = 0
        repeat r = r + 1; s = s - r until r >= 100
      end
      print(s)
      ```

    - Aside: with `math.floor` written inline in the loop, lowtrip
      never traces (`nyi_opcode get_index` in the main chunk). That
      gap is logged in TODO.md.
- **B1 — the op exists, inert.**
  - The compiler emits `loop`. Tier-0 runs it as a no-op. It is not
    yet a back-edge, and backward jumps keep their back-edge role, so
    anchors do not move.
  - `repeat`'s closer still targets the body, not the `loop` op, so
    its back-edge target does not move either (review r2 finding 7).
  - These walkers learn it: liveness, disasm, the recorder (records
    nothing), and the composite-bridge walk.
  - `loopHeaderOf` and `loopExtentFor` land here, and their callers
    switch to them. In B1, `loopHeaderOf` still recognises today's
    closers (a backward `jmp`/`jmp_if_false`, `for_loop`, `tfor_loop`)
    and has no `loop` arm, so it gives today's answers. B2 swaps the
    backward-jump arms for the `loop` arm.
  - Tests that pin pcs are updated for the shift.
  - Check: `--dump-traces` IR is identical, up to pc numbering, on
    every bench.
- **B2 — the anchor moves, and everything in §4.5 goes.**
  - `opLoop` becomes the back-edge, and `opJump` drops its test.
  - Patching moves to the `loop` op.
  - The recorder changes in §4.3 go in, including `isOwnLoopTest`
    and its readers.
  - `resumeOf` stops refusing the `while` exit.
  - `loopHeaderOf` swaps arms; `isPlainWhileAnchor` changes.
  - `continuationReachesEnclosingBackEdge` gets its `repeat` arm.
  - All of §4.5 is deleted here, because B2 makes every one of those
    classifiers unable to match (review r3 finding 2, applied to the
    whole list). That covers the `.while_done` chain, the glue knobs,
    `.low_trip_while` and `isOwnWhileTestCopy`.
  - The doc 38/39/40/57 tests are rewritten to the new shape with the
    same outputs. Tests that pinned deleted behaviour (the
    `.low_trip_while` gate, the glue route) are replaced by tests of
    the new behaviour (§6).
  - This is the large phase. It cannot be split without leaving dead
    classifiers in the tree.
- **B3 — `repeat` and low-trip probes.** Measure the behaviour changes
  that no bench covers: `repeat` exits no longer feed the prime-side
  want, and loops inside a `repeat` can now arm continuations. Also
  measure doc 38's low-trip nest with the switch off and on. The
  probes are recorded in this doc.
- **B4 — measure, then flip.** Switch off and on against B0. Flip
  `Config.exit_side_native` on by default, with doc 56's own flip
  checklist. Re-run doc 56 §4.8.4's G6 widening experiment with the
  new default, then G6-Q2 goes back to Bart with numbers.

## 6. Tests and measurement

- **Compiler.** `while` emits `loop` after the branch and `repeat` at
  the top, with the right `b` and `aux`. A debug assertion checks that
  every backward jump targets a `loop` op.
- **Tier-0.** The hot count ticks on trip 1. A zero-trip `while` never
  counts. Entry happens at the body.
- **Recorder.**
  - A `while` root's IR ends with the condition guard, then `.loop`.
  - LLEAVE fires on the last pass (`while` and `repeat`).
  - A continuation reaching an inner `loop` op with a root closes with
    `.link`.
  - A false inner condition on arrival continues past the loop.
- **The exit.** `resumeOf` gives the post-loop pc for a `while`
  condition guard, including an unrolled copy (doc 57 P3) and a
  compound condition (`a and b`).
- **Cross-tier parity** (all test legs): the doc 38 shapes (a `while`
  inside a `for`, `while` in `while`, always-zero-trip, `repeat`), the
  doc 39/40 peel matrix, doc 57's unrolled `while` tests, `break` out
  of a traced `while`, and a condition with a call.
- **doc 56.** The bit-reverse exit-side tests are rewritten. The
  `while` exit is attachable with `P` = post-loop, and with the switch
  on the bit-reverse cycle promotes (`silent_promotions > 0`).
- **Measurement budget.**
  - Switch on after B4: fft at or below doc 56 §4.8.4's 131 ms, then
    lower once G6 is re-run.
  - No bench slower than B0 with the switch on.
  - Tier-0 no worse than 2%.
  - The doc 38 low-trip nest at or below doc 38's glue figure of 78.5
    cycles per iteration.

## 7. Decisions

- **G5-Q1 (mechanism): B.** Bart pointed out that the rules already
  decide this. Z-7 says do not stack arm kinds, row kinds and replay
  arms on an anchor shape LuaJIT does not have, when the shape itself
  is the cause. The LuaJIT rule says replicate `BC_LOOP`. B subsumes
  A. The question should not have been asked.
- **G5-Q2 (slot sharing)**: moot. The exit is ordinary; doc 56 R1
  already orders an exit-side arm after a live ordinary arm.
- **G5-Q3 (condition side effects)**: moot (§4.7 item 3).
- **G5-Q4 (`.low_trip_while`)**: deleted in B2 (§4.5). B3/B4 measure
  the low-trip shapes.
- No open questions. If review finds one that the rules do not
  decide, it goes to Bart.

## 8. Review round 2 (Antigravity, 2026-09-27, rev 3): CHANGES REQUESTED

Receipt: `docs/reviews/doc58/antigravity-r2.md`. Every finding was
checked in source.

1. **BLOCKER, coarse deopt runs the body twice: rejected.** The premise
   is that a coarse deopt resumes with the post-body state. It resumes
   with the pass's start state: homes are updated only at the
   back-edge (`nativegen.zig` ~2724–2760), stores are sunk until the
   commit, and tier-1a exits before committing (`interp.zig`
   ~6495–6501). §4.4 now spells this out, with the `n < 3` example
   worked through. The `hotexit` point is true but harmless for the
   same reason.
2. **BLOCKER, peeled traces: rejected** for the same reason. The
   zero-completion peel skip replays both passes from the entry state.
   The cost is performance only; §4.6 already says so.
3. **MAJOR, `continuationReachesEnclosingBackEdge`: accepted.** It keeps
   the backward `jmp`/`jmp_if_false` (§4.2).
4. **MAJOR, the compiler assertion: accepted.** It now pins the two
   closer shapes (§4.2).
5. **MAJOR, the loop exit read as a branch: accepted, with a different
   fix.** A structural `isOwnLoopTest` classifier replaces a role
   (§4.3). It also closes the same gap for `repeat` that exists today.
6. **MAJOR, `linkKindAt`: accepted.** It uses `loopExtentFor` (§4.2).
7. **MINOR:** the B2 sequencing part is rejected (it follows from
   finding 1). The `repeat` part is accepted: B1 keeps `repeat`'s
   closer on the body (§5).
8. **MINOR, owner election bounds and the duplicate `forLoopEndFor`:
   accepted** (§4.2, §4.6).
9. **NIT, `recordingMirrorInstr`: accepted** (§4.2).

## 8b. Review round 3 (Antigravity, 2026-09-27): APPROVE WITH CHANGES

Receipt: `docs/reviews/doc58/antigravity-r3.md`. The reviewer
re-checked the rejection of r2 findings 1–2 against source and
**agreed that they are not blockers**. It checked:
- the homes are written only by the `.loop` parallel move;
- coalescing is refused before any body guard (`nativegen_alloc.zig`
  ~1180);
- sunk stores are flushed after the guards;
- pure-write stores are idempotent;
- `astore_append` replays as an in-bounds overwrite;
- `tnew` exists only on precise traces;
- `rbx` counts only at `.loop`;
- tier-1a flushes only at terminals.

1. **MAJOR, the loop exit falls into the `completed == 0` side want:
   accepted.** Loop exits feed only exit-side (§4.3).
2. **MINOR, delete `isOwnWhileTestCopy` in B2: accepted,** and
   applied to all of §4.5 (§5).
3. **MINOR, generic `for` extent: accepted.** It is `[header,
   tfor_loop]`.
4. **NIT, `continuationReachesEnclosingBackEdge` has no `repeat` arm:
   accepted** as a pre-existing gap, fixed in B2 (§4.2).

## Appendix R2 — rev 2 text (Option A, superseded)

Kept for the record. §3 above is still accurate for today's tree.

### R2.4 The design space

#### Option A — a `while_done_linked` arm on the ordinary exit path

Reuse what is already there: the ordinary flush is the right state, and
an armed `slots[ei]` is already followed.

1. **Arm kind** `ArmKind.while_done_linked` (appended). `arm` accepts
   it only on an `isWhileLoopDoneGuardIndex` exit whose condition prefix
   is pre-effect (`exitIsPreEffect`), into the `ordinary_entry` of a
   `.link`-tailed continuation anchored at `whileLoopDonePostPc`,
   in the same proto, at inline depth 0.
2. **One post-loop pc helper.** `loopDonePostPc(code, ei)` returns
   `guardExitPc` for a numeric loop-done guard and
   `whileLoopDonePostPc` for a `while` one; the four call sites in §3.2
   item 2 use it. `resolveLoopDoneCont` and `armLoopDoneLink` take it.
3. **A distinct row, from its own label.** `LedgerKind.while_done_linked`
   (appended). Like numeric `for`, an armed while-done guard branches
   to its own label, which emits the carried-home flush (a copy of
   `deopt_exit`'s loop), `completed = rbx`, the `.while_done_linked`
   silent site, the row, and `emitReturn` through the link's cell.
   `deopt_exit` is untouched. Code size: one flush per `while` root
   (one while-done guard per root). *(Rev 1 also offered "A.1": share
   `deopt_exit` and stage the row kind at run time. Dropped (review
   finding 1): `emitLedgerAppend` bakes its kind at compile time, the
   staging would sit on the doc 54 rowless-sibling fast path's
   registers, and the exit's one silent site would be `.deopt`.)*
   **Peeled roots never link** (review finding 3): `deopt_exit` skips
   the flush on a peeled trace with zero local iterations (doc 39), so
   the registers are NOT coherent at the post-loop pc there. `arm`
   already refuses peeled parents and children (`trace_link.zig`
   ~1985); the label is not emitted for a peeled trace either.
4. **Replay.** A `.while_done_linked` arm, matching the dispatcher's
   scalar receipt (`interp.zig` ~4486–4492: selection work
   `local_done`, region work 1): region work 1, selection work `local`
   (0 for a zero-trip exit), and NO extra iteration credit — every
   completed iteration already bumped rbx at its `.loop`, and the
   failing pass ran only the condition (numeric `for`'s `+1` credits a
   final iteration whose `for_loop` guard failed before the back-edge;
   there is none here). Resume at `whileLoopDonePostPc`; on a
   non-terminal row the cursor moves to the continuation. A terminal
   row resolves and arms like `.loop_done_linked`.
5. **Silent.** `SilentSiteKind.while_done_linked`, with a matching
   epilogue arm; promotion validation uses `loopDonePostPc`.
6. **Regions.** `resolveSuccessorAnchor` gives a while-done guard a
   structural edge to its post-loop pc when a trace is bound there;
   owner election learns the `while` loop's extent (a
   `whileLoopEndFor` twin of `forLoopEndFor`, from the same
   `jmp_if_false`/back-`jmp` pair `whileLoopDonePostPc` reads).
7. **Where it arms.** Wherever `armLoopDoneLink` is called today (the
   `.while_done` chain in `driveChain`, `runLinkedBurst` call A, replay
   terminal convergence), plus the dispatcher's `.while_done` path.
8. **No mode flag.** Unlike numeric `for`, the linked and unlinked
   paths materialize the same state, so there is no
   `linked_loop_done` mode for `while`: an armed link is always
   followed. `hasNativeLoopDoneLink` stays numeric-only (review finding
   5): the dispatcher's `ran_native_link_mode` branch passes
   `.native_numeric_for_done` to `driveChain` (`interp.zig` ~4576).
9. **The `.low_trip_while` gate** (review finding 7): a `while` anchor
   gated for low trips (`noteWhileYield`, `trace.zig` ~2885) is not
   dispatched natively, so its link cannot pay. Open: should an armed
   while-done link (or a promoted region containing it) exempt the
   anchor from that gate? The gate exists because the runtime turnstile
   per exit cost more than tier-0; the link removes the turnstile.

#### Option B — LuaJIT's shape: anchor `while` roots after the condition

Move the `while` root's anchor past the condition (the `BC_LOOP`
analogue): the condition guard then sits at the END of the trace, its
snapshot resumes at the post-loop pc, and it is an ordinary attachable
exit that doc 56's adapters serve like any other. This is what LuaJIT
does and would retire the special `.while_done` chain. It is a large
structural change: doc 38's link into `while` roots (the root's
anchor pc changes), doc 39/40's `while` peel (`isPlainWhileAnchor`),
the LLEAVE rule, the `.low_trip_while` yield gate, `whileLoopDonePostPc`
and its users, and doc 56's "refuse while-done" ruling all move.

#### Option C — only the replay fix

Keep the round-trip but resume a while-done `.deopt` row at the
post-loop pc instead of the `while` header, so tier-0 stops re-running
the condition. Cheap, but the cycle still cannot go silent and the
runtime round-trip stays. Listed for completeness.

### R2.5 Slot sharing (the glue sibling)

A while-done `slots[ei]` can hold a `.sibling_handoff` today: doc 38's
glue figure-eight (`38-while-inner-linking.md` ~277–288). For a
low-trip `while` (≤ 8 trips per entry), the condition guard records a
same-anchor glue sibling (`guard_false` → outer body → outer back-edge
→ `.loop`), and the guard's slot hands off to it; measured at 78.5
cycles per iteration against 137 for root + link. A
`while_done_linked` arm wants an exit path too.

The two arms need different code at the exit — the glue sibling takes
the ordinary path (`deopt_exit`, the `.deopt` silent site on
`metadata_cells[ei]`), the continuation link takes item 3's label with
its `.while_done_linked` site — and a page has one silent site and one
data cell per exit (`silentSiteAt`, `resolveSilentSite`). So the stub
must know which arm it is following. Choices:

- **S1 — reserve the slot** for the loop-done link, as numeric `for`
  does ("P-C option (b)"): `siblingHandoffEligible` also excludes
  while-done guards. Loses the glue figure-eight on low-trip loops
  (review finding 4); whether the continuation link recovers that
  speed there is not measured.
- **S3 — a second cell** for the link, doc 56's exit-side pattern: the
  link lives in `slots[whileDoneSlot(ei)]` (a new cell past the
  exit-side cells) with its own data cell; the stub tests it and
  branches to item 3's label, else takes today's ordinary path through
  `slots[ei]`. Keying by cell (doc 56 Phase 6) already handles two
  promotable sites on one exit. The order of the two tests (link first,
  or a live sibling first, as doc 56 R1 does) is part of this choice.

(Rev 1's "S2, first come first served on one cell" is not buildable
as stated: one cell cannot tell the stub which of the two exit paths to
take. The reviewer's recommendation of S2 amounts to S3 with
"live sibling first".)

### R2.6 Tests and measurement (Option A)

- Recorder/IR: `loopDonePostPc` for both loop shapes, including a
  `while` whose body ends in a `break` and a `repeat` (excluded).
- Native harness: an armed while-done slot writes one
  `.while_done_linked` row and runs the continuation with the registers
  coherent at the post-loop pc (a sunk store before the guard, a
  carried float, zero trips and many trips).
- Replay vs silent on a `while`-inside-`for` cycle: identical totals.
- A condition with a side effect (a call) never arms.
- Regions: the bit-reverse cycle's owner election succeeds with the
  `while` edge; promotion reaches `silent_promotions > 0` (the doc 56
  Phase 6 bit-reverse test gets its promotion checks).
- Existing `while` tests (doc 38/39/40, `interp_bool_test` mid-trip
  copy) stay green.
- Measure: bit-reverse alone, fft 500 (switch off and on), then doc 56
  §4.8.4's G6 experiment again with the switch off; the board.
  Budget: no bench slower with the switch off; fft with the switch on
  at or below 131 ms once combined with G6.

### R2.7 Decisions for Bart (rev 2)

- **G5-Q1 — mechanism.** (A) `while_done_linked` with its own exit
  label (§4 A); (B) re-anchor `while` roots after the condition
  (LuaJIT's shape; large); (C) replay fix only.
- **G5-Q2 — the slot (A only).** S1 reserve the slot (loses the doc 38
  glue figure-eight); S3 a second cell, with either the link or a live
  glue sibling tested first.
- **G5-Q3 — condition side effects.** (a) Arm only when the condition
  prefix is pre-effect; (b) that, and also add the same check to the
  `.while_done` runtime chain, which does not check it today (doc 38's
  accepted concern).
- **G5-Q4 — the `.low_trip_while` gate** (§4 A item 9). (a) Leave it;
  (b) exempt an anchor whose while-done link is armed; (c) exempt it
  only while its region is promoted.

**Bart's answers (2026-09-27, partial).** G5-Q2: **S3, a live glue
sibling tested first**. G5-Q1: asked for the A-vs-B trade-offs first
(open). G5-Q3, G5-Q4: open.

**G5-Q1 settled (2026-09-27): Option B.** Bart pointed out that B
subsumes A and that Rule Z-7 plus the "replicate LuaJIT" rule already
decide it: A adds a new arm kind, row kind, silent site and replay arm
onto an anchor shape that LuaJIT does not have, which is the kind of
stacking Z-7 forbids. The question should not have been asked. G5-Q2
(slot sharing), G5-Q3 (condition side effects) and G5-Q4
(`.low_trip_while`) are re-examined under B: most of them dissolve,
because the condition guard becomes an ordinary exit at the end of the
trace. Doc 58 is to be rewritten around B (rev 3).

### R2.8 Review round 1 of rev 2 (Antigravity, 2026-09-27): APPROVE WITH CHANGES

Every §3 claim verified in source, with one caveat (peeled roots, below).
Findings and dispositions:

1. **BLOCKER — A.1 is not buildable** (compile-time row kind in
   `emitLedgerAppend`, the doc 54 fast path's registers, the one
   `.deopt` silent site). Accepted: A.1 dropped; A is the own-label
   form.
2. **BLOCKER — `resolveSuccessorAnchor` has no `while` edge.** Already
   §4 A item 6; no change beyond naming it as required.
3. **MAJOR — peeled roots:** `deopt_exit` skips the flush on a peeled
   trace with zero local iterations. Accepted: §4 A item 3 now says
   peeled roots never link (and `arm` already refuses them).
4. **MAJOR — S1 loses the glue figure-eight.** Accepted as a fact in §5.
   Its recommendation, S2, is not buildable on one cell (one silent
   site and data cell per exit, verified in
   `trace_native_registry.zig` ~174–196); §5 now offers S3 with the
   test order as the choice.
5. **MAJOR — `hasNativeLoopDoneLink` must stay numeric-only.**
   Accepted (§4 A item 8).
6. **MINOR — accounting argument order.** Verified against
   `interp.zig` ~4486–4492: selection work is `local_done`, region work
   is 1. Accepted (§4 A item 4).
7. **MINOR — the `.low_trip_while` gate.** Accepted as open question
   G5-Q4.
8. **NIT — `whileLoopDonePostPc` already refuses inline depth > 0 and
   loop-test copies.** Noted; `arm` relies on it.

It also judged Option B not required by Rule Z-7 (anchoring at the
condition is a measured doc 38 choice that the glue figure-eight uses)
and recommended (A), S2 and G5-Q3 (b). Those are recorded as its
recommendations; the choices are Bart's.
