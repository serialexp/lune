# 58 — `while` loops in LuaJIT's shape: a loop op after the condition (doc 56 G5)

**Status:** rev 3: **Option B, LuaJIT's `BC_LOOP` shape**
(Bart, 2026-09-27; §4). Reviewed (§8, APPROVE WITH CHANGES, folded in).
B0 and B1 landed. B2 was implemented, then REVIEW-REJECTED by codex
(2026-09-30, `docs/reviews/doc58/codex-b2.md`, three blockers — §5 "B2
REVIEW OUTCOME"). Bart picked "fix all of them" (2026-10-01): all three
blockers and every should-fix are fixed (§5 "B2 FIX-ALL"), §4.8 adds the
closed-SCC owner tie-break that blocker 3 turned out to need, and doc 56's
`exit_side_native` switch is **ON by default** in the same change (B4's
flip pulled forward, because the switch-off path is what B2 regresses;
`--jit-no-exit-side-native` is the ablation). B2 + flip landed as one commit
(2026-10-01, at Bart's call, before the re-review). It carries a known
regression: nsieve/nsieve-bit/sieve_int ~3× from the pre-existing switch-on
cost (§5 "B2 FIX-ALL" item 7, doc 56 G6). That fix comes next, and the codex
re-review covers B2 and it together. B3 (probes) and B4's remaining measurement and
G6 re-run follow. Rev 2's Option A design and its review are kept as
Appendix R2.
**Owner:** claude
**Last updated:** 2026-10-01

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
- [x] B1: the `loop` op is emitted and every walker knows it; inert
  (§5, "B1 done").
- [x] B2: `while`/`repeat` anchors move to after the `loop` op; the
  condition guard becomes an ordinary exit; the machinery whose
  premise was the condition anchor is deleted (§5, "B2 done").
- [x] B2 review fix-all: three blockers, six should-fixes, §4.8 owner
  tie-break, default flip of `exit_side_native` (§5 "B2 FIX-ALL").
- [x] B2 + flip committed (2026-10-01, Bart's call, before re-review).
- [ ] Fix the sieve switch-on regression (doc 56 G6 + silent promotion).
- [ ] codex re-review of B2 + fix-all + flip + the sieve fix.
- [ ] B3: `repeat` and low-trip probes (§5).
- [ ] B4: measure with the doc 56 switch off and on (the flip itself is
  done with B2); re-run doc 56 §4.8.4's G6 experiment (§5).

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

**Revised 2026-10-01 (B2 review, Q1): the zero-completion receipt
exemption is split, not deleted.** Its numeric half survives B2 — a
`for` root whose loop-done fires with zero committed iterations must not
strike the anchor — so `trace_regionops.zig` now states two policies:

1. **Numeric final test** (`isLoopDoneGuardIndex`): exempt, exactly as
   before B2, including its refusal of `.loop_test_copy`.
2. **Marker loop (`while`/`repeat`) own test** (`isOwnLoopTestIndex` and
   the instruction above the header is a `loop` marker): exempt **only
   while exit-side serves that exit** — wanted/waiting, or attached with
   `exit_side_native` on. Every unrolled copy matches; that is safe
   because the exemption only withholds a strike. Once exit-side gave
   up, or cannot run natively, the zero-completion receipt strikes like
   any other, so the old `.low_trip_while` gate's job (stop paying a
   coarse deopt per one-trip entry) falls to the ordinary window policy
   instead of a `while`-specific gate.

Pinned by "doc 58 §4.5: a while root's zero-completion own-test exits
are exempt only while exit-side serves them" (served leg: binds, not
gated; unserved leg: gated), mutation-checked both ways.

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

### 4.8 Closed-SCC owner election with several loop roots (B2 blocker 3, 2026-10-01; rev 2)

Rev 1 below was reviewed by codex (`docs/reviews/doc58/codex-b3-election.md`,
APPROVE WITH CHANGES). Rev 2 — what was built — follows rev 1's text as
"As built (rev 2)"; where they differ, rev 2 wins.

**Finding.** After blockers 1 and 2 were fixed, codex's blocker 3 (fft
slower with the switch on) is not the entry-contract failure it was
diagnosed as. fft's 46k `prologue_fail`s came from the unsound bridge
(blocker 1), and they are gone: 5 remain. The regression that is left
is one Z-8 layer up — owner election. Evidence (`-Djit-debug`, fft 100,
switch on):

- B0: `fft_transform:131` 211 cyc/it. Region `{131, 193}` mints
  `armable=true`. 919 promotions, 838 parked reuses, 514k silent
  transitions.
- B2 + fixes: `fft_transform:132` 1053 cyc/it, 82.5% of the run in the
  steering seam. 18,399 bursts end at `LEDGER_CAP`, and the yielded
  terminal `t=11 ei=8 deopt` alone accounts for 17,599. That is Z-8
  layer 2: the slot is armed, but no promotion holds.
- Why: B2 makes the `repeat` back-path traceable. A new continuation at
  pc 73 (after the first `for i` loop) links into the `for i` root at
  25 through the `repeat` marker. The whole `repeat` body becomes one
  **closed** SCC — `{25, 73, 132, 194}`, regions 4/5,
  `armable=false`. Increment B's fallback tier finds **two**
  qualifying roots:
  - 25, fed by `.link` from 73 and from t11@194;
  - 132, fed by `.link` from t12@194.

  Doc 47 Increment B deliberately leaves "several qualifying roots"
  unarmable, and the `inc-B ambiguity` test pins exactly this shape:
  rootA → contA → rootB → contB → rootA.
- Hypothesis test: a temporary hack electing the lowest-pc qualifier.
  fft 100 went from 284 to 73 ms (B0: 198). The board with the switch
  on: fft 325 → 178 ms (−45%). Every other bench moved within ±3%
  noise. So blocker 3 is exactly this election.

**What the owner is.** `RegionDef.owner` is only the window
policy's blast-radius key — penalty, gate and condemn on a strike
(`applyWindowDecision`) — plus rebind identity. It is not soundness
state; `armable` gates arming. A fallback-elected region does not even
lean on the gate: at `max_penalty` it tombstones the whole region,
one-shot (`trace_regionops.zig` ~331). So the question is which root
*represents* the region, deterministically and stably.

**Rule (proposed).** In the fallback tier, when two or more roots
qualify, elect the one whose loop **gate** dominates every other SCC
member anchor in the proto's bytecode CFG, rooted at pc 0. Exactly one
→ elect it (`fallback_owner = true`, as today). Zero or several → stay
unarmable, as today.

- **The gate of a root at header `h`** is the instruction every entry
  into its loop body passes through: the `loop` marker at `h − 1` for
  `while`/`repeat` (doc 58 shape), and for numeric/generic `for` the
  loop's back-edge op `loopExtentFor(h).back_edge_pc`. `for_prep`
  never falls through (`bc_liveness.effectOf`). It jumps to the
  `for_loop`, which performs the first test. So the `for_loop` lies on
  every path into the body, *including* the zero-trip path that skips
  `h`.
  - The header itself does not work: a zero-trip numeric `for`
    reaches its post-loop code without passing `h`. fft's 25 does not
    dominate 132; its `for_loop` does.
  - No gate (`loopExtentFor` null or ambiguous, an unknown shape) →
    that root does not qualify (fail closed).
- **"G dominates M"** ⇔ M is unreachable from pc 0 when G is removed
  from the CFG. Successors come from `bc_liveness`'s existing
  `effectOf` (exposed as `bc_liveness.successors`), the same CFG
  liveness is computed on, so there is one successor model, not two.
  `proto.code` is the canonical image: entry patches live in
  `EntryRegistry.code_images`, never in the proto.
- **Uniqueness.** In fft, 25's gate (its `for_loop`) dominates 73, 132
  and 194; 132's gate does not dominate 25. Two roots in sibling
  branches (`if c then <loop A> else <loop B> end` inside a closed
  cycle) dominate nothing of each other. Neither qualifies, so the
  region stays unarmable — the conservative status quo for genuine
  ambiguity.
- **Scope.** The rule applies only where Increment B today refuses
  (≥2 qualifiers). The single-qualifier election, the primary
  `(is_ext or enclosing)` tier, and every downstream fallback policy
  (dormancy, tombstone, net-work balance, parked proofs) are unchanged.
- **Cost (Rule #20).**
  - Per candidate region: one BFS over `proto.code` per qualifying
    root — O(k·n). k is the qualifier count (2 in practice), and n is
    in the hundreds for real protos.
  - Scratch: one bitset plus one worklist of n, allocated once per
    `buildTopology` call from its existing `gpa` and reused across
    candidates.
  - It runs only at topology build — commit/rebind time, not per
    receipt.
  - Adversarial case: a 64k-instruction proto with a cycle of k roots
    costs k BFS passes of 64k, so microseconds per rebuild.

**Rejected alternatives.**

- (i) Lowest pc: correct on fft only by coincidence of layout, with no
  structural meaning. It is the experiment, not a rule.
- (ii) An owner *set* (gate every qualifying root): it changes
  `RegionDef.owner`'s shape, rebind identity and every strike site.
  The fallback strike-out already tombstones the whole region, so
  the larger blast radius buys nothing.
- (iii) Generalising the primary `enclosing` test to a non-member
  enclosing loop still needs a tie-break among the member roots inside
  it. That tie-break is dominance.

**Tests.**

- The `inc-B ambiguity` fixture splits:
  - two roots in sequence inside a closed cycle → the dominating
    (first-gated) root is elected;
  - two roots in sibling branches → unarmable.
- Unit tests for `dominates` cover: straight line, a diamond (neither
  arm dominates the join), zero-trip `for`, and an unreachable member.
- An fft-shaped interp test asserts the region mints `armable=true`
  and `silent_promotions > 0` with the switch on.

#### As built (rev 2, codex review findings 1–7 folded in)

- **Dominance is a compile-time fact, not a per-rebuild BFS (finding
  1, the blocker).** `bc_dom.zig` computes the dominator tree of each
  proto's bytecode CFG, rooted at pc 0, once at compile time into
  `Proto.dom` — exactly as `bc_liveness` fills `Proto.reg_live`.
  - Algorithm: Cooper–Harvey–Kennedy over reverse postorder, then a
    DFS of the tree gives each pc a `[pre, post]` interval.
    `DomTree.dominates(a, b)` is interval containment, O(1).
  - Cost: O(n · passes) per proto (two or three passes on the reducible
    CFGs the compiler emits). One scratch allocation, freed before
    return; the successor model is evaluated once per pc into a flat
    array. The result is two `u32` arrays from the compile arena.
  - `loopExtentFor`/`loopGateOf` are O(1) checked queries (below), so
    the tie-break costs O(k·m) dominance lookups per candidate region
    (k qualifiers, m members), with no allocation and nothing
    proportional to proto size.
  - Measured at the rebuild boundary (`zig build bench-topology`,
    ReleaseFast, `src/bench_topology.zig`, repeated rebuilds of one
    closed cycle with k loop roots): k=128 ≈ 0.2 ms, k=512 ≈ 3.5 ms per
    rebuild, and flat in proto size. The tie-break is ~2% of that; the
    rest is the pre-existing per-node `hasInnerRootAt` and edge loops,
    which are ~k² (TODO.md, "Topology rebuild is ~k²").
- **Non-vacuous and fail-closed (finding 2).**
  - A pc unreachable from pc 0 has no tree interval: it dominates
    nothing and is dominated by nothing, so dead membership can never
    count as evidence. A proto with no tree (hand-built fixtures) gives
    "nothing dominates" — the region stays unarmable.
  - A dropped successor (a jump outside the code) leads to no
    instruction, so it can never hide a path to a real pc: dominance
    over the remaining graph is exact for every executable path, and a
    malformed target cannot manufacture a proof.
  - `loopExtentFor` no longer calls the asserting `loopMarkerExit`. It
    validates every shape it reads (marker kind, branch position and
    target, closer op and target, `for_prep` → `for_loop`, `jmp` →
    `tfor_loop`) and returns null on anything else. "doc 58 B2 review:
    loopExtentFor fails closed on malformed loop shapes instead of
    trapping" pins each refusal.
- **Numbers without logging (finding 3).** The structural diagnosis
  stands (the yielded `t=11 ei=8` terminal proves an armed slot; with the
  tie-break the four-anchor region mints armable and promotes, and the
  problematic yields fall 17,599 → 229). Rev 1's 82.5% seam share and
  284 → 73 ms were taken from a `-Djit-debug` run with live logging, so
  they do not count as timings. The non-logging board with the lowest-pc
  experiment was fft 325.3 → 178.0 ms; the as-built number is in §5 "B2
  FIX-ALL".
- **Lifecycle tests (finding 4).**
  - `trace_region_test.zig` "doc 58 §4.8: sequential loop roots in a
    closed cycle elect the root whose gate dominates — stable across
    rebinds, trace order and tier flips". It uses a compiled proto
    (`compileFixture`, fft's shape), not a malformed hand-built CFG. For
    each of four trace-cache orders it checks: first-sight fallback
    election of root A; a same-RegionId rebind; an external entry that
    hands the region to the primary tier (same id and owner,
    `fallback_owner` cleared) and back; and a tombstone that stays
    sticky across the multi-root re-election.
  - "… loop roots in sibling branches of a closed cycle stay unarmable
    (no gate dominates)".
  - Strike-out, dormancy and net-work balance go through the unchanged
    fallback-owner paths. Their existing inc-B tests cover them, and
    they apply to an elected owner however it was chosen: proof
    lifecycle does not depend on the tie-break.
  - Integration: `interp_exit_side_test.zig` "doc 58 §4.8:
    fft_transform's multi-root repeat cycle elects its first loop,
    admits and promotes". It requires the expected owner (the first
    `for_loop`'s header), `fallback_owner`, admission (`!dormant`),
    silent promotion, parked reuses, and identical output in every
    `expectProgramTuned` mode.
- **The qualifier count decides the path (finding 5).** The single- vs
  multi-root branch is taken on the *structural* qualifier count. A root
  with no gate only drops out of the dominance vote, so an ambiguous
  case can never collapse into the single-qualifier shortcut. The
  single-qualifier rule is unchanged: a legitimate continuation may
  precede a sole root's gate on first entry.
- **What the owner is (finding 6, corrects rev 1).**
  - Besides the window policy's blast-radius key, the owner also
    participates in `openCollision`.
  - It is **not** RegionId identity: internal structural edges decide
    identity, so electing an owner does not re-key a region.
  - In fft, the fix acts on **region 5** (four anchors
    `{25, 73, 132, 194}`). Region 4 (three anchors) stays unarmable
    even under the experiment; rev 1 conflated the two.
- **Rejected alternatives, sharpened (finding 7).**
  - (i) Lowest pc is deterministic and not shown unsound. Its cost is
    that the attribution is arbitrary, and it admits more of the
    ambiguous shapes (sibling-branch loops) that Increment B
    deliberately refuses.
  - (ii) An owner set adds lifecycle complexity (rebind identity,
    strike sites, `openCollision`) for no established benefit.
  - (iii) A non-member enclosing owner changes the representative
    contract (the owner is no longer a member) and still needs a
    selection rule among the member roots.

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
  - **B1 done (2026-09-27).** As built:
    - `OpCode.loop`, `LoopKind` and `loopMarkerExit` in `bytecode.zig`.
      `compileWhile` emits the marker after the branch;
      `compileRepeat` emits it at the top, and its closer still targets
      the body.
    - Tier-0 `opLoop` is a fall-through. `bc_liveness` treats it as a
      fall-through. The recorder records nothing for it.
      `resolveCompositeBridgeSuccessor` steps over it.
    - `bytecode.loopHeaderOf` replaces `trace_exit_attach.backEdgeTarget`,
      and `resolvePatchPc` and `isPlainWhileAnchor` now call it.
    - `bytecode.loopExtentFor` (returns `LoopExtent`, with
      `back_edge_op`) replaces both `forLoopEndFor` copies. The
      `trace_link` copy only had a dead alias in `trace_regionops`.
      Owner election keeps B1 inert by requiring
      `back_edge_op == .for_loop`; B2 drops that. The member test now
      reads `b.pc == a.pc or b.pc < ext.start or b.pc > ext.end`, which
      equals the old test while `start == header`.
    - Tests:
      - compiler: the `while` marker (branch, exit, `break`, header,
        extent) and the `repeat` marker;
      - `bc_liveness`: the marker falls through. Mutation-checked:
        reading `aux` as a branch fails the test.
    - Gates: `just test` 0; `-Djit-debug=true` 0, empty log.
    - Inertness: `/tmp/irdiff.sh`, `--dump-traces` IR with pcs
      normalised. All 28 benches are identical to the B0 shadow.
    - Tier-0 cost: noise level. lowtrip 394 → 401 ms; pi_leibniz and
      hightrip were within ±2% (interleaved, best of 5, loaded
      machine).
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
  - **B2 done (2026-09-30).** As built:
    - **Tier-0.** `opLoop` tail-calls `backEdgeHandler` with target `pc`
      (already the header) when tracing is on, else falls through.
      `opJump` lost its backward test entirely — no jump is a back-edge.
      `opJLoop` replaced the `npc <= cur_pc` direction test with an
      explicit `took` flag, because a marker's header is FORWARD; its
      `.jmp`/`.jmp_if_false` arms are gone and `.loop` always takes.
      `patchedEntryOp` maps `.loop`/`.tfor_loop → .jloop`.
    - **Compiler.** `compileRepeat`'s closer targets the marker
      (`loop_top = marker`). `bytecode.assertLoopClosersWellFormed`
      (safe builds, once per finished proto) pins the two closer shapes.
      It identifies a `while`'s marker by its extent ENDING at the
      closer, not by being the nearest one — scanning back from the
      closer finds an INNER loop's marker first, which is how the first
      version of the assert fired on `while` inside `while`.
    - **`loopExtentFor` is a real extent now**, not `[header,
      back_edge]`: `while` → `[C, E − 1]` (the condition sits BELOW the
      header), `repeat` → `[marker, E − 1]`, `for` → unchanged.
      `linkKindAt` takes `(proto, header)` and asks it, replacing the
      old "target ≤ anchor ≤ back_edge_pc" pc-ordering (review r2
      finding 6); it fails closed to `.inner_root` when the extent is
      ambiguous. Owner election dropped its `back_edge_op == .for_loop`
      gate, so `while`/`repeat` roots can be elected.
    - **`isOwnLoopTest`** (`TraceCode`) is the one structural classifier
      for all three shapes, replacing the whole `while`-done chain. It
      deliberately matches every unrolled copy of the test.
      **CORRECTED 2026-09-30 (codex review, answer to Q2):** the claim
      that "its consumers only ever REFUSE things" is FALSE. No consumer
      reaches `resumeOf`, snapshot construction, or stored guard-role
      assignment — so matching an early copy cannot select a wrong resume
      pc, which was the soundness point — but two consumers do more than
      refuse: through the dispatcher it changes a receipt's `region_work`
      to 1 (`interp.zig` ~4459, a POSITIVE accounting use), and the
      source-branch predicate reaches ledger-replay validation
      (`trace_chain.zig` ~2226), which can panic on inconsistent rows.
      codex also judges the hotness suppression "already functionally
      wrong" — see blocker 2 in "B2 REVIEW OUTCOME".
    - **Recorder.** The `.jmp` handler records nothing; the `.loop`
      handler carries the linking decision (`recLoopLink`, was
      `recWhileLink`), keyed on the marker's header. `recordInstr`'s
      inner-root lookup reads `.loop`/`.for_prep` → `pc`. LLEAVE is
      local now (the branch sits next to the marker), and `repeat`'s own
      test is excluded for the first time.
      `isOwnWhileTestCopy`/`.loop_test_copy`-for-`while` are gone, so a
      `while` condition guard always carries `.branch_cond`, which is
      what `resumeOf`'s branch fix-up needs.
    - **`continuationReachesEnclosingBackEdge`** gained the
      `jmp_if_false` arm, so a loop inside a `repeat` can arm a
      continuation (review r3 finding 4).
    - **Deviation from §4.5, flagged for review.** The zero-completion
      receipt exemption in `trace_regionops.zig` was NOT deleted; it was
      re-keyed from `isAnyLoopDoneGuardIndex` to `isOwnLoopTestIndex`.
      §4.5's premise ("B makes every one of those classifiers unable to
      match") does not hold for it: its numeric-`for` half still matches
      (a `for` root whose loop-done fires with zero committed
      iterations), so deleting it would have made a 1-trip `for`
      completion strike the anchor.
      **CORRECTED 2026-09-30 (codex review, answer to Q1):** codex agrees
      the objection to deleting the whole exemption is valid — the numeric
      zero-completion case does survive B2 — but "re-keying keeps numeric
      behaviour byte-identical" is FALSE. The old numeric predicate
      explicitly REJECTS `.loop_test_copy` (`trace.zig:207`); the new one
      matches every copy, and additionally requires the test to belong to
      the trace's own anchor. Both are observable classification changes.
      The fix is to SPLIT the policy explicitly: (i) a numeric
      final-test zero-completion exemption, preserved as-is, and (ii) a
      NEW marker-loop zero-completion policy that states its decision
      about unrolled copies and about exit-side being unavailable. (ii) is
      a new policy decision, not preservation of the old top-condition
      exemption, and needs weighing against the removed yield gate.
    - **Everything else in §4.5 is deleted:** `whileLoopDonePostPc`
      (both copies), `isWhileLoopDoneGuardIndex`,
      `isAnyLoopDoneGuardIndex`, `whileDoneCoherentAtZero`,
      `ExitMaterialization.while_done` and its three driver arms, the
      dispatcher's `while_done` classification and chain,
      `maybeArmContinuation`'s `while` leg, `resumeOf`'s `while`
      refusal, `whileDoneHotnessEligible`, `while_glue_max_avg`,
      `noteWhileYield`, `WhileYield`, `while_yield`,
      `while_yield_window`, `while_yield_min_avg`,
      `GateReason.low_trip_while` and its two exemptions.
    - **Tests.** 20 tests pinned the old shape and were rewritten.
      **CORRECTED 2026-09-30 (codex review):** the blanket "not relaxed"
      claim is too broad and does not survive audit. codex audited all 20
      and found two that no longer establish what they advertise, plus
      four weakened in a narrower way:
      - `interp_tier1a_test.zig:1132` ("low-trip yield gate → ordinary
        attachable exit") only calls `resumeOf` and accepts EVERY refusal
        except `loop_done`, despite claiming only `no_snapshot` is
        acceptable. It never requires attachability or actual attachment
        — which is why blocker 2 below passed unnoticed.
      - `interp_native_test.zig:1727` (doc 40 phase-0 zero-completion
        peel) no longer reaches the steady region at all: starting trip 5
        with `i=5`, the body takes `i` to 6 and the ending condition
        fails immediately against bound 6. Use bound 7, and assert the
        failed guard's region and the zero completion count.
      - Weaker but still useful: `interp_exit_side_test.zig:334`'s
        link-kind oracle now recomputes production `loopExtentFor`
        containment, so a wrong extent makes oracle and implementation
        agree; `interp_exit_side_test.zig:76`'s `anchors >= 2` lets a
        continuation stand in for one of the two intended loop headers
        (identify both explicitly); `interp_tier1a_test.zig:1067`'s
        repeat link check silently skips `null` extents and never
        requires a link into the repeat root; and the boolean/unrolling
        tests keep the harness default `exit_side_native = false`
        (`interp_testutil.zig:85`), so none of them covers the native
        path implicated in blocker 1.
      The other 14 codex judged faithful migrations. The rewrites
      themselves: the compiler marker tests (the marker is the back-edge;
      extents), the entry-patch fixtures (patch site = the marker; the
      closers are never patched), the exit-attach fixture (its loop is
      spelled with a real back-edge; the `while`-condition sub-case is
      now decided by the generic back-edge rule), doc 57 P3's
      classification counts (`flush`/`own`/`copies`/`branch` — one
      flush-owing loop-done, every copy structurally own, zero branch
      consumers), doc 39/40's peel matrix, and the doc 38/56 nest tests.
      New: a `repeat` anchors at its marker's header; a low-trip `while`
      root's own condition is an ordinary attachable exit resuming at
      the post-loop pc.
    - **Peel trip alignment (§4.6, expected).** The marker counts on
      trip 1, where the condition anchor only counted from trip 2, so
      every trip-aligned peel threshold moved up by exactly one
      (`hotloop = 4 → 5` in five doc 39/40 tests). The peel itself is
      unaffected. Two findings: the doc-40 reset-to-int shape now peels
      at the `while`'s own ROOT anchor instead of through the deleted
      GLUE side channel — the peel's original motivation, reached
      directly; and the doc 38/56 nest link now forms through doc 56's
      exit-side route instead of the deleted `while`-done continuation
      arm.
    - **Gates:** `just test` 0; `-Djit-debug=true` 0 with an empty log.
      Parity sweep: 28 benches × {tier-0, `--trace`, `--jit-native`,
      `--jit-native --jit-exit-side-native`} all identical (ReleaseSafe),
      plus the `while`/`repeat`/nest probes.
  - **B2 measured (2026-09-30, ReleaseFast, best of 5, quiet machine,
    interleaved ×2 against the B0 shadow).**

      | program | tier-0 B0→B2 | native B0→B2 | native+switch B0→B2 |
      |---|---|---|---|
      | lowtrip | 339 → 357 (+5.3%) | 200 → 430 (+115%) | 198 → **61** (−69%) |
      | hightrip | 725 → 758 (+4.6%) | 72 → **9** (−87%) | 82 → **9** (−89%) |
      | bitrev | 4 → 4 | 6 → 7 | 7 → **5** |
      | pi_leibniz | 1787 → 1824 (+2.1%) | 366 → 365 | 365 → 364 |
      | nsieve-bit-fp 6 | 276 → 281 (+1.8%) | 312 → 312 | 315 → 310 |
      | scimark-fft 500 | 689 → 673 (−2.3%) | 208 → 363 (+75%) | 215 → 336 (+56%) |

    - **Coverage, the point of the arc.** fft's bit-reverse kernel
      (`/tmp/bitrev.lua`, the doc 55 §3 shape) goes from 0.2% / 36.8% of
      iterations traced at its two hot anchors to **83.4% / 75.7%** with
      the switch on. Doc 56 Phase 0's "barely runs traced" baseline test
      is replaced by one asserting both hot anchors are majority-traced.
      Iteration counts are deterministic, so that is a real gate.
    - **Tier-0 budget MISSED on the `while`-only probes.** §4.2 budgeted
      2%; lowtrip is +5.3% and hightrip +4.6%. Both are synthetic loops
      whose bodies are two or three instructions, so one extra dispatched
      marker per iteration is a large relative share. The real benches
      are inside or near budget (pi_leibniz +2.1%, nsieve-bit-fp +1.8%,
      fft −2.3%). LuaJIT pays the same instruction; the alternative
      (keeping backward jumps as back-edges) is what B replaces. Bart's
      call whether the probe overage matters.
    - **Switch OFF regresses, as §4.4 predicted.** A `while` exit is now
      a coarse deopt that replays the final body pass in tier-0 and arms
      no continuation, so lowtrip (+115%) and fft (+75%) pay per loop
      completion. fft's evidence: `replayLedger` walks 21,028 → 98,069
      (4.7×) and seam cycles 184M → 445M, even though iteration coverage
      IMPROVED (73.0% → 76.3%). This is the state B4 exists to end.
    - **Switch ON is a large win on the low-trip shapes** (lowtrip −69%,
      hightrip −89%, bitrev −29%) and **still short on fft** (336 ms vs
      B0's 215, and vs §6's 131 ms target). The seam is the remaining
      cost: the exit-side cycles here are not promoting to silent
      (`silent_promotions` 0 on bitrev). **CORRECTED 2026-09-30:** "so
      every 32 rows costs a replay walk" mischaracterises the traffic.
      Measured on fft (§5 "B2 REVIEW OUTCOME", finding 2), **70% of
      dispatcher bursts end in `prologue_fail`** — entry failures, mostly
      well before the cap — not full-cap drains. Prologue failures satisfy
      NEITHER promotion route's evidence class (full-cap `.yielded` at
      `trace_link.zig:1505`, short natural-terminal deopt at ~1724), so
      the entry-contract failure is UPSTREAM of the promotion question.
      Fix the entry contract first (codex should-fix #4: `recLoopLink`
      closes the inner-root link with no `entryGuardsMatch` check). That
      is B4's first measurement, not a B2 tuning job (Z-7).

    **B2 REVIEW OUTCOME 2026-09-30 — codex: DO NOT LAND.** Receipt
    `docs/reviews/doc58/codex-b2.md` (codex CLI 0.159.2, its default
    `gpt-6-astra`, read-only sandbox). B2 stays uncommitted. codex holds the
    marker architecture itself to be "a general improvement consistent with
    Z-6/Z-7" — the objection is to its replacement *execution path*, not to
    the shape. Three blockers:

    1. **Mode-equivalence violation — verified independently.**
       `/tmp/codex-repro.lua` prints 76 under tier-0, `--trace` and
       `--jit-native`, and **215** under
       `--jit-native --jit-exit-side-native`. A HEAD shadow (`just shadow`,
       src restored with `git show HEAD:<f>`, emptiness of
       `nm | grep isOwnLoopTest` checked) prints 76 in both modes, so **B2
       introduces it**. Minimal repro `/tmp/repro40.lua`: 1202 vs 1225.
       - **Symptom:** the `while` overruns its bound by **exactly one
         iteration**, on outer iterations r=34/37/39 only, and only once
         the exit-side child has armed (first divergence r=34). Bisected
         with `/tmp/trace40b.lua`, which logs `i*1000000 + s` per outer
         iteration into a table — note that `print`ing inside the loop
         perturbs recording and hides the bug entirely.
       - **Necessary ingredients** (each removal fixes it): a compound
         **`and`** condition, a **varying trip count** (`r % 9 + 3`), and a
         **loop-carried boolean** (`b = not b`). The same `and` in an `if`,
         or assigned to a real local, does not diverge on B2 *or* HEAD.
       - **Shape.** `compileWhile` evaluates the whole condition into one
         register and emits a single `jmp_if_false`, and
         `compileBinary(.and_)` lowers the short-circuit inside it, giving
         pc 14 `jmp_if_false cr → 16` (the `and`), pc 15 `loadk true → cr`,
         pc 16 `jmp_if_false cr → post` (the while's own test), pc 17
         `loop` marker, pc 18 body = anchor. Trace 0 (`main:18`) is the
         body unrolled 2×; its exits 21 and 27 are the two copies of the
         lhs test and both carry `resume=16`. The exit-side child (trace 1)
         is recorded AT pc 16 and opens `slot_load r7; guard_is_false %0`
         — r7 IS `cr`, so the child correctly expects `cr` falsy.
       - **Two hypotheses ruled out.** (i) This is NOT the LuaJIT-`ISTC`
         hazard: `compileBinary(.and_)` writes `dest` BEFORE the
         short-circuit jump, so `cr` is defined on both edges — already
         equivalent to `ISTC`/`ISFC`'s copy-and-test (`lj_parse.c:731`).
         The tier-0 bytecode is correct. (ii) `resumeOf`'s branch fix-up
         arithmetic is correct: `14 + 1 + aux = 16` is the right not-taken
         successor, matching `rec_comp_fixup` (`lj_record.c:2205`).
       - **Next concrete step:** decide between (a) trace 0's exit-21
         snapshot failing to carry slot 7 ← `%020`, and (b) the native exit
         adapter's state transfer into the child. Trace 1's own exit 24
         *does* carry `slot 7 ← ref 23`, which is exactly the shape exit 21
         needs — so diff the two. Trace 0's `exit-snap:` block is absent
         from the debug log (only trace 1's is emitted); finding out why
         and getting it is the first move.

    2. **Direct loop exits cannot warm the replacement path.**
       `interp.zig` ~4434's `count_exit = exit_ok and !any_loop_done`
       includes `isOwnLoopTestIndex`, so direct `while`/`repeat` completion
       exits never reach `noteTakenExit` — while `trace_link.zig` ~378
       deliberately routes hot exits to exit-side *before* its own
       own-loop-test early return. The dispatcher blocks the intended route
       upstream. codex measured 40 native entries with attachable exits, no
       classification refusals, and **zero** wants, records, bindings,
       adapters or hops; tier-1a never wants the side trace either. Fix:
       let ordinary marker-loop exits reach exit-side hotness accounting,
       keep the legacy-sibling suppression *after* exit-side routing,
       preserve the numeric final-flush classification, and add
       direct-entry tests that demand real wants and bindings. (Not yet
       reproduced by me.)

    3. **The deleted low-trip protection has no effective default
       replacement.** `exit_side_native` still defaults false
       (`trace.zig:649`) and the exit is now an ordinary coarse deopt
       (`interp.zig` ~4451). Moving the marker does prevent *zero*-trip
       entry, but it does not remove the cost of repeatedly entering a
       one-trip trace, failing its ending condition before a coarse
       completion, and replaying the body in tier-0 — so removing
       `.low_trip_while` removed load-bearing protection. The measured
       +115% low-trip / +75% fft regressions are that cost. Land the
       migration together with a correct replacement and its default
       configuration, not before.

    **codex's answers to the three open questions.** Q1 and Q2 are folded
    into §4.5 and the `isOwnLoopTest` bullet above as CORRECTED notes. Q7a:
    B2 must not land separately from an effective replacement, and a
    combined B2-plus-flip is not sufficient today either, since switch-on
    is incorrect (blocker 1) and fft remains ~56% slower than baseline —
    this argues for finishing the new execution boundary, not for restoring
    the old architecture. Q7b: answered in the corrected §5 note above —
    entry failures, not failed owner election; the closed-SCC fallback
    already exists (`trace_region_topology_build.zig:426`) and a closed SCC
    alone does not establish failed election. Q7c: the tier-0 marker
    overage is real evidence, not a probe artifact — small bodies expose
    dispatch overhead precisely because they contain little else, and they
    are valid workloads for a general language (Z-6); the +5.3%/+4.6%
    results miss the stated 2% budget, and any budget change is Bart's
    call. Report absolute cost per iteration alongside percentages, from
    interleaved runs, and keep timing in benchmarks (global Rule #22).

    **Other should-fixes** (full text in the receipt): `loopExtentFor` does
    not consistently fail closed on malformed bytecode — it calls the
    asserting `loopMarkerExit` before validating its result (a negative
    exit offset can trap rather than return `null`), the `while` arm never
    validates the condition branch before the marker or that branch's exit
    target, the `repeat` arm validates its closer not at all (a marker with
    exit `marker + 1` yields an extent containing only the marker), and
    `isWhileHeader` accepts `header == code.len`. `assertLoopClosersWellFormed`'s
    forward scan is sound for compiler output — each generated loop owns a
    distinct closer and exit, so nesting cannot produce two valid markers —
    but it accepts the first match and does not prove uniqueness on
    malformed input; keeping it debug-only is judged reasonable, and
    external bytecode would need validation at its own boundary instead.
    The `isOwnLoopTestIndex` imports in `trace_chain.zig` and
    `trace_link.zig` are unused. The `routeExitSide` panic
    (`interp.zig:3693`) is PRE-EXISTING in HEAD, not introduced by B2, and
    codex found no legitimate path reaching it. Tier-0 dispatch, the receipt
    condition `local_done > 0 or linked_one_trip`, the deleted
    `.while_done` materialization/chain and the deleted while-copy role all
    pass review. No newly introduced clock-, RNG- or address-based policy
    was found — but blocker 1 is itself an execution-mode-equivalence
    failure, and the 28-bench parity sweep does not establish the broader
    guarantee, because no bench carries this shape.

    **B2 FIX-ALL 2026-10-01 (Bart: fix all of them).**

    1. **Blocker 1 — fixed. The root cause was in doc 17's composite
       bridge, not in B2.** `TraceCode.classifyBridgeCandidate` committed
       every slot-bound φ whose update ref is defined before the guard,
       taking that to mean "the slot was written before the guard".
       Konst interning and CSE break that inference.
       - In the probe, the unrolled root's second-copy guard (exit 27)
         has `phi r7 ← %3 = konst true`, but the `loadk true → cr`
         happens AFTER the guard.
       - So the armed `region_bridge` (exit 27 → the pc-16 child)
         committed `cr = true`, and the child's `guard_is_false r7`
         deopted at pc 16: one extra trip.
       - The exit snapshot (`slot 7 ← %26`) was right all along.

       Fix: `bridgeMatchesExitSnapshot`. A bridge is a candidate only if
       it agrees with the guard's exit snapshot on every slot that is
       live at the bridge's LANDING pc (the untaken branch edge). No
       snapshot ⇒ refuse. Liveness at the guard itself wrongly refused
       nsieve, whose `if flags[i]` temp is dead past the branch.

       Tests:
       - Fourteen hand-built bridge fixtures now declare a sound bridge
         through `trace_testutil.snapshotBranchGuardsFromPhis`.
       - `§T.9c`: four refusal variants.
       - e2e "doc 58 B2: a composite bridge never commits a φ the exit
         snapshot contradicts", verified FAILING under the old rule.
       - `bench/while_shortcircuit_probe.lua` joins the parity sweep.

       Bridge arms are identical on all 28 other benches.
    2. **Blocker 2 — fixed.** The dispatcher now counts own-loop-test
       exits (`count_exit` no longer excludes `isOwnLoopTestIndex`), so
       they reach `noteTakenExit`. That function routes them to exit-side
       first and stops them before every legacy route (sibling watch,
       prime-side, hotguard). The low-trip test now demands real wants
       and bindings (`exit_side_binds >= 1`), not just `resumeOf`
       attachability. The numeric final-flush classification is
       unchanged.
    3. **Blocker 3 — fixed, in two parts.**
       - (a) The fft regression is owner election in a multi-root
         closed SCC; the fix is the gate-dominance tie-break (§4.8).
       - (b) `exit_side_native` is **on by default**: `Config` and the
         CLI default to true, `--jit-no-exit-side-native` is the
         ablation, and the test harness follows the config default
         (`exit_side_native: ?bool = null`). The replacement for the
         deleted `.low_trip_while` is therefore the shipped path, as
         codex's 7a required.
    4. **Should-fixes — all done.**
       - `loopExtentFor`/`loopGateOf` are O(1) checked queries that
         fail closed (§4.8 rev 2). `isWhileHeader` reads the marker kind
         through `std.enums.fromInt` and refuses `header == code.len`.
       - **`recLoopLink` checks the entry contract** (`regs` is no longer
         discarded): no link into a peeled `while` root, and none unless
         `entryGuardsMatch(inner_root_guards, regs)` holds, mirroring
         `recForLoop`. Test: "doc 58 B2 review: a continuation links
         into a while root only under its entry contract" (int → no
         link, float → link, peeled → no link), mutation-checked.
       - The doc 40 zero-completion peel test uses bound 7 and asserts
         the failed guard is in the steady region. The witness is the
         new `peeled_steady_zero_exits` counter
         (`TraceCode.isSteadyRegionExit`), mutation-checked.
       - The link-kind oracle (`interp_exit_side_test.zig`) derives
         loops from the CFG itself — back edges whose successor
         dominates the tail, the natural-loop body by reverse BFS —
         instead of recomputing `loopExtentFor`.
       - Bit-reverse identifies its `for_loop` header and its `loop`
         marker header explicitly, and requires each to run ≥1000
         iterations with a traced majority.
       - The `repeat` test requires a trace at the repeat header and at
         least one `.link` into it with `back_edge_op == .loop`.
       - Unused `isOwnLoopTestIndex` imports are gone from
         `trace_chain.zig` and `trace_link.zig`.
       - §4.5 is split into two explicit policies (see §4.5 "Revised
         2026-10-01").
    5. **Flip fallout, fixed in the same change.**
       - **A one-shot `.link` trace classifies a loaded+stored slot as
         `.invariant`, like `.terminal` already did**
         (`nativegen_alloc.zig`). An exit-side child that starts
         mid-statement loads a table temp that its body then reuses for
         an int; the carried-slot path saw `sk != lk` and bailed native.
         A one-shot trace has no back edge, so nothing is carried; its
         φs flush from `store_ref` with the store kind. The old doc 34
         numeric `.link`/`.terminal` exemption in the carried branch is
         subsumed and removed.
       - **Five tests pin a legacy arm kind** and set
         `exit_side_native = false` explicitly, each with a comment:
         Part S head arms D10, doc 16 prime-side (nsieve prime path),
         doc 17 A-viii mid-epoch scope, doc 47 same-anchor sibling
         convergence, and the adapter-off layout. Doc 47 gained a
         default-config twin. In it, the append continuation's
         `guard_append` exit binds an in-bounds exit-side child (an
         `astore` f64 that ends in `.link`), which silent-promotes.
       - `trace_evict_test`'s monotonic census is scoped to fill's
         `for_loop` header. The exit-side child it was miscounting
         exposed a real gap: exit-side children are not retired with
         their parents (TODO.md).
       - The trace_link diagnostic probe now analyses with the real
         `exit_side` option, so it reports the actual bail site.
    6. **Gates.** `just test`: 1552/1552. `-Djit-debug=true`:
       1552/1552, empty log. Parity sweep (ReleaseSafe, 29 benches
       including the short-circuit probe × {tier-0, `--trace`, native
       switch off, native switch on}): all identical. `/tmp/codex-repro.lua`,
       `/tmp/repro40.lua` and the lowtrip, hightrip and bitrev probes are
       identical in all four modes.
    7. **Measured (2026-10-01, ReleaseFast, best of 5; HEAD = the
       `55137e0` shadow at `/tmp/b0shadow`, nm-verified).**

       | program | HEAD (switch off) | new, switch off | new, switch on (default) |
       |---|---|---|---|
       | lowtrip | 204 | 464 | **76** |
       | hightrip | 79 | 10 | **10** |
       | bitrev | 6 | 9 | **5** |
       | pi_leibniz | 369 | 368 | 369 |
       | nsieve-bit-fp 6 | 314 | 325 | 313 |
       | scimark-fft 500 | 209 | 380 | **179** |
       | nsieve (board) | 12 | 12 | **39** |
       | nsieve-bit (board) | 14 | 14 | **33** |
       | sieve_int (board) | 6 | 6 | **24** |

       Board (`bench/results/20261001-114121-55137e0.tsv` vs a
       same-session HEAD board): fft 206.7 → 177.4 ms; every other row
       within noise **except the three sieve rows, which regress
       ~3×**. The sieve regression is **not B2**: HEAD with
       `--jit-exit-side-native` is already 39/35/24 ms on them, and the
       new tree with the switch off matches HEAD. It is the
       pre-existing switch-on cost, doc 56 §4.8.4 G6, which the flip
       now makes the default.
       - **G6 widening re-measured on top of B2** (doc 56 G6-Q1(a),
         one condition: `recForLoop`'s link close also takes `.side`;
         experiment reverted). Switch on: nsieve 39 → 26, nsieve-bit
         33 → 19, sieve_int 24 → 11, fft 179 → 178. Switch off: fft
         375 (G5's switch-off cost, as predicted), the sieves unchanged.
         So G6 alone leaves the sieves 1.4–2× behind switch-off.
       - **nsieve, switch on, `--jit-stats`:** trace entries 360 →
         27,754; steering seam 9.2% → **52.4%** of the run
         (`replayLedger` 316 → 30,717 walks); exit-side binds 5, fused
         hops 206k, burst skips 4,218. The exit-side cycles hop but
         never go silent: Z-8 layer 2 (silent promotion), on top of
         G6's short ledgers. Not yet diagnosed further.

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
