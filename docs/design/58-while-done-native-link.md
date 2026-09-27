# 58 — Native loop-done links for `while` roots (doc 56 G5)

**Status:** draft rev 2 (review round 1 APPROVE WITH CHANGES, folded
in, §8); waiting on Bart's §7 (G5-Q1..Q4). Bart's P6-Q4 (a): a `while`
root's loop-done exit gets a native transition, in its own doc (this
one).
**Owner:** claude
**Last updated:** 2026-09-27

## Implementation status

### Done

- [x] Diagnosis (doc 56 §4.8.2 G5, §4.8.3 "Phase 6 landed", §4.8.4).
- [x] Fact map of today's numeric-`for` and `while` loop-done paths
  (§3, with file:line references).

### Outstanding

- [x] Review round 1 (Antigravity): APPROVE WITH CHANGES, 8 findings,
  dispositions in §8.
- [ ] Bart's answers to §7.
- [ ] Implementation, tests, measurement (§6).

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

## 4. The design space

### Option A — a `while_done_linked` arm on the ordinary exit path

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

### Option B — LuaJIT's shape: anchor `while` roots after the condition

Move the `while` root's anchor past the condition (the `BC_LOOP`
analogue): the condition guard then sits at the END of the trace, its
snapshot resumes at the post-loop pc, and it is an ordinary attachable
exit that doc 56's adapters serve like any other. This is what LuaJIT
does and would retire the special `.while_done` chain. It is a large
structural change: doc 38's link into `while` roots (the root's
anchor pc changes), doc 39/40's `while` peel (`isPlainWhileAnchor`),
the LLEAVE rule, the `.low_trip_while` yield gate, `whileLoopDonePostPc`
and its users, and doc 56's "refuse while-done" ruling all move.

### Option C — only the replay fix

Keep the round-trip but resume a while-done `.deopt` row at the
post-loop pc instead of the `while` header, so tier-0 stops re-running
the condition. Cheap, but the cycle still cannot go silent and the
runtime round-trip stays. Listed for completeness.

## 5. Slot sharing (the glue sibling)

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

## 6. Tests and measurement (Option A)

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

## 7. Decisions for Bart

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

## 8. Review round 1 (Antigravity, 2026-09-27): APPROVE WITH CHANGES

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
