# 44 — call anchors and return tracing (making recursion trace at all)

Status: partial — P0 complete, P1a (D8 head siblings), P1b (D9 quiet head
episode + S1/S2/S4), P4 slice 1 (D10 head-sibling exit-branch patching), P4
slice 2 (D11 native frame push — true up-recursion on the descent side), and
§D12 slices a+b+c implemented. D12c closes the native push/pop cycle through
continuation and call-head links. The final seven-rep board measures fib
185.7 ms (pre-D12c 402.8 ms) and binary-trees 394.7 ms (425.7 ms).
Binary-trees still has no native pops: its table-construction and nil-child
base-case recorder gaps prevent the required return traces from forming.
Remaining P1/P2/P4 work below is not claimed complete.
Codex-reviewed ×6 (gpt-5.6-sol, all sound-with-changes, every required change
folded; ledger at bottom)
Owner: Bart
Last updated: 2026-09-08

Prerequisite reading: doc 10 (cross-frame tracing, inline frames, `guard_func`),
doc 16 (coherent state chaining — the seam-cost lesson that shapes this arc's
phasing), doc 20 (entry patching), doc 31 (gates), doc 42 (tier-0 tail-call
dispatch — where the call-entry hook lives), CLAUDE.md §"LuaJIT is dedication"
(the determinism asterisk on tiering decisions).

## Implementation status

Tracking the gap between this design and master. Tick items as they land; move
to Done once everything inside a phase is checked.

### Done

- [x] **P0 layers 1–3 — record a head trace at all.** The parameterized
      `.terminal` IR op (`TerminalKind{return_interp, self_call_interp}`,
      wire 86); `FUNC_HEAD_PC` sentinel identity + fail-closed classifier
      audit; `hotcall` counting in `opCall` (tick-advancing, vararg refused,
      counts successful entries only) with the `.fast`-mode park-and-flip so
      the `.full` prologue's step (10b) consumer arms at callee pc 0;
      recorder kind `.head` closing at BOTH depth-0 terminators (`ret` and
      direct self-call; `all_results` refused at both); finalize keeps every
      defined depth-0 slot as φ writeback rows and terminates with
      `.terminal` (cached unoptimized). Recorder-shape tests (return_interp,
      fib self_call_interp, vararg never counts, multret forwarding aborts);
      all gates green (test, hashgate ×2, wasm, viz, boundaries).

- [x] **P0 layer 4 — head entry + terminal execution (tier-1a).** The
      `jfunc_head` bytecode op (appended, dense-enum rule; handler
      tail-dispatches `&proto.code[0]` on decline — NEVER `&patch.orig`,
      straight-line handlers walk `instrNext`); `EntryPatch.patched_op` as a
      first-class field (head patches overwrite an arbitrary pc-0 op);
      `resolvePatchPc` head arm → pc 0; install-at-commit (gated on
      `config.execute`; the receipt funnel can't qualify what it never
      sees) with an immediate drain; `installPending` head bypass of the
      native-only gate (the patch is the sole entry, tier-1a legs included);
      terminal-exit consumer in `enterSelectedTrace` — a PRODUCTIVE receipt
      (one run = one iteration; clears penalty/gate per doc 31 D2, else
      base-case zeros ratchet a gate successes could never un-earn) then
      resume at `terminal.aux`; head zero-exit consumer — ordinary zero
      receipt, `.next_candidate` (thrash gate stays live; no hot-exit
      wants — they'd only unpatch the sole entry), skipping the whole
      loop-anchor grammar; coverage NOT in the jfunc_head bypass set
      (unlike loop arms — no walk fallback exists, `--jit-stats` would
      read 0%% by construction); `traceser` v4. Receipts: recursive-fib
      1,346,206 head completions, res%% 0 → 30.6%% of run cycles, ten-leg
      e2e (fib steady state, hot non-recursive call, upvalue-seed closure
      swap) all green. **Exit target met: fib records a non-base trace and
      re-enters through the patched head.**

- [x] **P0 layer 5 — native `.terminal` lowering.** `nativeFor` gate admits
      `.terminal`; proveKinds arm (terminal position only, kind `.none`);
      the analyze type-instability exemption shared verbatim with `.link`
      (one-shot flush, never loops back); the `.terminal` lower arm — φ
      one-shot `flushSlot` per store_ref with the STORE value's kind,
      `completed ← rbx`, `exit_instr ← i`, a `head_terminal` ledger row
      (LedgerKind 7; every native exit appends ≥1 row), then
      `emitReturn(slot_addr=null)` — a head terminal is a COMPLETION through
      shared_exit and never a chain source (fail-closed `@panic` arms in
      `replayLedger`, `null` in `rowPatchKind`). Unlocked along the way,
      both as GENERAL rules (Z-6): (a) `.func` values are flushable — a
      guard_func-covered closure is a raw `*GcHeader` boxed TAG_HEAP like
      `.ptr` (φ-boxability + flushSlot); write-only `.func`/`.native` slots
      skip the prologue id-stash loops (`load_ref < 0` — was an @intCast
      panic); (b) truthiness widening — a proven non-bool value kind is
      statically truthy, so `guard_true` on int/float/ptr/heap/func/native
      lowers to nothing and `guard_false` to an unconditional side-exit.
      Receipts: fib(30) 2,692,425 entries, 100% native bodies, correct
      output; board recursive-fib jit 521→477 ms (res 34.3), binary-trees
      468→370 ms (res 28.6, both head traces compile), spectral-norm
      40→30 ms (truthiness widening); all gates green (test, hashgate ×2,
      wasm, viz, boundaries).

- [x] **P0 layer 6 — D1 exclusion-site kind checks + tests.** The audit's
      "fail-closed by construction" claim did NOT hold for
      `classifyBridgeCandidate`: fib's base-case branch guard carries
      `.branch_cond` provenance with slot-bound φs below it, and
      `exit_pc >= anchor.pc` is vacuous against the sentinel — the head
      trace's guard classified as a bridge candidate (harmless today only
      because the dispatcher's head consumers return before every
      consumer). Explicit `isHeadAnchorPc` kind checks added at all five
      sites — `classifyBridgeCandidate`, `isNumericForLoopDoneGuard`
      (trace_code.zig), `isLoopDoneGuardIndex` (trace.zig), `driveChain`
      (trace_chain.zig — the sentinel must never become a walk pc),
      `resolveSuccessorAnchor` (trace_link.zig) — plus a recorded-fib
      classifier sweep test (verified to FAIL with the check neutralized)
      and a synthetic head-anchored driveChain test with a reachable
      same-anchor sibling.

- [x] **Phase 1a — head path siblings (D8).** All four pieces landed:
      head route in `noteTakenExit` (want + src provenance, no unpatch),
      sibling walk in `enterPatchedTrace` (`nextTraceExcluding` hit-count
      order, truncation never strikes, `removeTrace` idempotence keeps
      mid-walk removal safe), current-activation want transfer into
      `pending_call_anchor` (parked through the `.full` prologue so
      `maybeStartHead` arms pc 0 of the failing activation), patch
      retention below sibling capacity, DONE-latch on NON-source sibling
      completion (a source completing proves nothing about the failing
      path), idempotent `maybeRepatchHead` recovery in `onCallEntry`.
      Receipts: fib(15)/fib(25) — the P0 coverage-collapse inputs — now
      grow the recursive sibling and keep 100% coverage; fib(30) grows the
      base sibling (2.69M completions, 100% of calls, cycles/iter
      405→301); the non-recursive two-path e2e pins Z-6 generality; want
      self-retires via the DONE-latch. All gates green.
      **Board cost note:** absorbing a trivial alternate path natively
      currently LOSES wall clock (fib jit 477→550 ms, btrees 370→397) —
      each absorbed call pays the ~300-cycle dispatcher episode twice
      where tier-0 ran the 3-op base case in ~30 ns. This is the same
      per-entry seam P4 exists to remove, not a D8 defect; revisit the
      pair after P4's native frame push / lean head entry.
- [x] **Phase 1b — quiet head episode (D9, lean entry).** Landed
      (d0e9d8e): `headEpisodeQuiet` predicate + `enterHeadNativeQuiet`
      at both `enterPatchedTrace` entry sites; the round-3
      `hasNativeLoopDoneLink` head refusal; S1 (`onCallEntry`
      image-first), S2 (inline receipt early-outs), S4 (frame-cached
      code image, `?u64` gen); `CompiledTrace.has_hash_seed` from active
      plan bits. Hashgate byte-identical. Board: fib jit 550→435 ms,
      btrees 397→~365-373, rest flat — recovers the D8 cost and more.
      Remaining fib gap is structural (leaf calls pay incumbent
      zero-exit + sibling full episode; penalty churn keeps the sibling
      non-quiet) — P4's exit-branch patching owns it.
- [x] **P4 slice 1 — head-sibling exit-branch patching (D10).** Landed
      per the round-4-amended design: the central arm validator rejects
      head parents for every non-`.sibling_handoff` kind and refuses
      hash-seeded children for head handoff arms (the durable "head
      slots carry only handoff arms" invariant); `siblingHandoffEligible`
      demands non-inlined `.branch_cond` provenance for head parents;
      the walk-local `head_walk_fail` evidence channel (reset per walk,
      set only by real native head guard deopts, consumed at terminal
      completions via `noteSiblingTerminal`); `consumeHeadBurst` at both
      dispatch sites, keyed on `ledger_len > 1` BEFORE the scalar head
      consumers, with release-mode per-row validation (owner/anchor/
      kind/outcome, `hasArmedSiblingHandoff` adjacency, `.yielded` only
      at full cap) and per-row accounting (intermediates: run + candidate
      charge, no zero receipt, no hot-exit charge; final row: verbatim
      scalar terminal / zero-exit / prologue-fail / capacity-decline
      semantics); burst owners merge into the walk's `visited` via the
      `head_burst_visited` scratch; quiet predicate v2 drops the global
      `armedLinks` line (un-starves the quiet path in mixed loop+call
      programs, Z-6). The `replayLedger` `head_terminal` panics stay as
      backstop; heads still never enter `replayLedger`. Receipts: fib
      jit 442→317 ms (res 43.5→46.3), binary-trees ~flat (362→368),
      rest of the board within noise; validator + arm-formation + ten-leg
      output-equality tests; all gates green (both test builds, hashgate
      84×2 — output-equality claim, not byte-identical-by-construction:
      D10 changes tiering/receipt streams on native legs — wasm, viz,
      boundaries).

- [x] **P4 slice 2 — native frame push at the self-call terminal
      (D11).** Landed per the round-5-amended design: nativegen-only
      lowering of `.terminal(self_call_interp)` (flush → save/restore
      rdi/rsi/rdx around the baked `nativeSelfCallPush` callout →
      `pushed_frames` bump → lane shift by `num_registers` →
      `linked_loop_done = 0` → `jmp body_entry`; refusal falls through
      to the byte-identical plain terminal). Helper = `opCall`-verbatim
      (round-5 distant-invariant re-verification, actual-callee proto
      match with no closure-identity pin, depth/capacity walls,
      `receiptsInert` descent gate, window layout, one-past-call cursor
      freeze, real `pushFrameVararg`, episode-ctx refresh, factored
      `tickCallEntry` after success only). `NativeResult.pushed_frames`
      at the ABI tail (frozen offsets pinned by a new comptime assert)
      → `ExecResult.pushed_frames`; BOTH dispatcher paths branch on
      `pushed > 0` FIRST into `consumePushedDescent` — a sibling of
      `consumeHeadBurst` sharing the factored row core
      (`resolveHeadRowOwner`/`accountHeadIntermediateRow`) with none of
      the walk-local state, six-way terminal grammar, every disposition
      → `.resume_pushed_frame` (reload + dispatch the LEAF; the leaf's
      own jfunc_head walk owns non-terminal failure accounting —
      charging the final deopt row here too would double-count).
      Recording + tier-1a legs byte-identical (no recorded change).
      `self_call_pushes` witness counter (+ `--jit-stats` line). Tests:
      ten-leg pins (deep linear descent, StackOverflow through the
      wall + pcall parity, type change at depth, mid-run callee rebind
      — an in-trace rebind is unreachable in v1 since function-valued
      `ustore` aborts recording), native formation proof on the
      witness, helper refusal matrix through the installed fn pointer
      (bounds/non-call/all_results/vararg/multret-pending/non-function/
      foreign-proto/capacity + positive control asserting the real
      frame, cursor, tick, ctx stamp). Receipts: fib jit 317→263.5 ms
      (arc: 550 D8 → 435 D9 → 317 D10 → 263.5 D11; LuaJIT 7.5, 35×),
      binary-trees 368→287.7 ms (−22%); board otherwise noise-flat.
      Known Piece-6 artifact carried openly: `--jit-stats` res%/
      iterations-per-entry undercount descents (binary-trees res%
      reads 9% while getting 22% faster). All gates green.

- [x] **D12a — descent-symmetric handoff evidence.** Landed per the
      round-6-amended design. A1: one evidence funnel at the top of
      `consumePushedDescent`, keyed on the ENTERED trace's id
      (`consumeHeadWalkFail(ct.id)` + `noteHeadSiblingCompletion(…,
      ct.id)`, exactly once per consumed descent, disposition-
      independent; the `head_terminal` branch's duplicate completion
      call removed — round-6 change 5). A2: `pending_descent_fail`
      carry (`DescentFailCarry` in trace_types) set only for the final
      `.deopt`+`.normal` real-guard row, pinned to the leaf frame's
      `call_seq`; consumed-or-discarded at the head walk start AFTER
      the freshness reset (globally-monotone `call_seq` makes stale
      false-matches impossible — the `maybeStartHead` argument).
      Receipts: fib(27)-shape (base-case incumbent) goes from ZERO arms
      + 196,391 per-leaf penalty strikes + 2–3 episodes/call to BOTH
      directions armed by warmup end, 61 strikes total, and 196,330
      fused `pushed-descent terminal` episodes — the lucky shape's
      ideal steady state, now formation-order-independent. Test: the
      bad shape pinned deterministically (`hotcall=4`, `fib(4)` warmup
      makes call #4 the base case) asserting `sibling_handoff_arms >=
      2` (lucky shape produces exactly 1) + live descents + exact
      output. Board: fib 262.4 / btrees 287.9 (7-rep) — neutral on the
      lucky-shape board, as designed. All gates green (both test
      builds, hashgate 84×2, wasm, viz 69, boundaries).

- [x] **D12b — continuation anchors.** Landed per the round-6-amended
      design. Identity: `CONT_PC_BIT` (bit 31) tagged resume pcs,
      `anchorKind`/`entryPc`/`contAnchorPc` in trace_code (head sentinel
      classified before the cont bit; compiler hard-fails protos at the
      2^31 instruction limit so no legal pc aliases). Counting:
      `onRetResume` in opRet's resume path only (stop-depth boundary
      naturally excluded), shared `counters` map at the cont key,
      `hotcall` threshold, NO tick; vararg callers and physical-pc
      collisions (any already-patched op or `patchedEntryOp`-accepted
      op at the resume pc — fail-closed by OP) refused at counting.
      Recording: `pending_ret_anchor` consumed by `maybeStartCont` in
      the `.full` prologue; `.fast` parks via `.switch_mode`; TraceKind
      `.cont` inherits the head one-shot close grammar plus a stricter
      rule — ANY loop back-edge aborts `.cont_backedge` (generic
      funnel + both link-time sites). Entry: first-class `jcont` patch
      kind (opcode appended last; registry `resolvePatchPc` bounds-
      checked switch; cross-kind incumbents mutually exclude), opJCont
      mirrors opJFuncHead with `pending_ret_anchor` in the §R1-5
      bypass set and `.resume_pushed_frame` → panic (push epilogue is
      head-only). One-shot walk: `enterPatchedTrace` parameterized on
      EXACT anchor pc + kind (freshness, quiet path, burst merge,
      sibling walk, retention, want transfer split head/cont);
      fail-closed kind audit across trace_code/trace/trace_link/
      trace_chain/nativegen/interp (every `isHeadAnchorPc` reviewed →
      `anchorKind != .loop` or exact-kind). D8 recovery: `maybeRepatchCont`.
      Tests: identity round-trips; fib forms 1 head + 2 cont traces
      (kind-counted, one self_call_interp + one return_interp cont);
      non-recursive call site forms a return_interp cont trace;
      loop-body resume pcs gate `.cont_backedge`; collision refusal
      pinned on a call whose resume pc IS the `for_loop` back-edge
      (shape premise asserted); registry patch/incumbent/unpatch/OOB.
      Receipts (`--jit-stats`): 100% residency, zero fallback on every
      cont anchor — fib 2×2.18M entries (~250–390 c/entry), btrees
      3×657k. Board: fib 262→413.5 ms, btrees 288→450.4 ms — the
      predicted-flat verdict was WRONG: each cont entry pays the full
      unlinked episode toll (iters/entry ~1), ~150 extra cycles ×
      4.36M entries on fib. Formation infrastructure is correct and
      consumed by D12c, whose links remove exactly this toll; the
      regression is carried openly until D12c lands (next slice, same
      arc). All gates green (both test builds, hashgate 84×2, wasm,
      viz 69, boundaries).

- [x] **D12c — native return and call-head links.** Four retained physical
      return-key slots and one call-head cell, registry-owned disarm/retirement,
      deterministic hotguard evidence/retries, ordinary-entry reseeding and
      live-registry ledger adjacency. Frame-motion consumers reload the current
      activation and use the final owner's exact entry PC on failure. Capacity
      cuts, native link formation, key retention/fifth refusal, changed return
      types, protected overflow/recovery and ten-leg GC equivalence are tested.
      General prerequisites: boxed tag/payload pass-through with parallel tag
      snapshots, and immutable entry homes for terminal one-shot roots independent
      of outgoing register kinds. Plain/jit-debug tests, hashgate84×2, wasm/viz69
      and full28-program board pass. Board:20260909-155852-06bab1b.tsv.

### Outstanding
- [ ] **Phase 1a follow-ups.** Remaining review-round-2 matrix tests
      (want-during-recording, sibling abort/cooldown retry,
      `max_traces_per_anchor == trial_visited_cap` truncation, unpatch
      recovery e2e); commit-time provenance latch (today's latch fires at
      the walk's completion site only).
- [ ] **Phase 1 — remaining recursion ergonomics.** Bounded recursive
      unrolling (`recunroll` budget for depth>0 self-calls), lifecycle
      hardening under the abort/GC/error matrix, binary-trees receipts. P0 field note strengthening the
      case for base-vs-non-base sides: WHICH call is hot-call #112 decides
      the recorded shape — fib(15)/fib(25) seed a BASE-CASE head trace
      (guard_true n<2), the majority non-base entries then strike the
      patch out in 4 consecutive `.next_candidate`s (`patch_strikes`), and
      since a retired head never re-arms (hasTrace blocks `onCallEntry`,
      installs only at commit) coverage collapses to 0 for those inputs.
- [ ] **Return recording breadth.** Binary-trees base-case/return paths abort
      on `new_table` (BottomUpTree) and nil-child `get_index` (ItemCheck).
      Native link infrastructure does not substitute for these missing traces.
- [ ] **Phase 2 — RETF return tracing. SUPERSEDED for the recursion/return
      shape by §D12** (real-frame pop over single-frame traces needs no
      two-frame recording ABI, no modeled upvalue close, no multi-result
      top state). What remains of P2 — recording *through* a depth-0 `ret`
      for cross-frame inlining — stays deferred to its own doc if a
      profile ever demands it. (Original scope, for the record: two-frame
      execution ABI, guards on frame kind/return pc/caller proto/
      activation identity, multi-result top state, modeled upvalue close,
      bar on protected/host/stop-depth frames.)
- [ ] **Phase 3 — down-recursion.** Return-anchored traces (LuaJIT patches
      `JLOOP` over a hot `RET`) so the unwind phase runs traced. **Owned
      by §D12 (D12b+D12c are its mahina-shaped form: anchor at the resume
      pc after the tier-0/native pop, not at the `ret` itself — no
      cross-frame recording needed).**
- [ ] **Phase 4 — de-seam the recursion links.** Native frame push for the
      self-call terminal (true up-recursion), then exit-branch patching.
      MUST either include safepoint/hook/replay polling in the native
      frame-push path or self-disable whenever those facilities are active
      (the tier-0 prologue services they'd otherwise skip). Done when the
      seam is off the fib/binary-trees profile. **Completion now OWNED BY
      DOC 54** (inline native frame motion, codex-approved 2026-09-18):
      the D11/D12c callout-based form measured ~1415 cycles/call
      (fib 27.0× at 86% residency, `iters/native-entry ~0`); doc 54
      replaces the callouts with inline sequences, removes rows from
      row-free frame-motion episodes, and adds warm entries.
- [ ] **Open question — trace stitching at un-inlinable calls.** LuaJIT's
      `trace_stop` `BC_CALL` case links the previous trace to a new one
      instead of aborting. Kills a whole abort class (`.too_deep`, vararg
      callees, `__call`); decide after P1 whether it joins this arc.
- [ ] **Open question — binary-trees' `get_upval aliased_input` site**
      (main@65, 6 strikes). Diagnose once head anchors land.
- [ ] **Defer — vararg callees, `__call` inlining.** Stitching is the
      general answer, not special cases.

## 1. Why this exists

The 2026-09-08 board (rev e0c3b3e) has a zero-residency group that no amount
of loop-side work can touch:

| bench | jit/lj | res% | why |
|---|---|---|---|
| recursive-fib | 21.3× | 0.0 | **no recording is ever attempted** — pure recursion has no loop back-edge, and back-edges are our only anchor source |
| binary-trees | 5.7× | 0.0 | loops exist but the hot work is recursive `BottomUpTree`/`ItemCheck`; plus a 6-strike `get_upval aliased_input` site (main@65) |
| euler14-bit | 20.5× | 0.0 | different levers: nested `for_prep` NYI, `get_index bad_type`, `close_upvalues` (the doc-43 deferral) — this arc will NOT fix euler14 |
| scimark-sparse | 21.2× | 0.0 | `set_index bad_type` ×3, nested `for_prep`, one `upvalue_mutable` memo — mostly not this arc either |

`--dump-aborts` receipts (2026-09-08): recursive-fib prints **"no recording
aborts"** — the recorder never runs. That is the defining datum: the gap is
anchor *sourcing*, not recording capability. Mandate for this arc (Bart,
2026-09-08): "It'd be nice if all the things start tracing at least" —
coverage first, seam removal second (but scheduled as Phase 4, not deferred
forever).

## 2. The LuaJIT mechanism (what we are replicating, staged)

All references `~/Projects/LuaJIT/src/`. Every piece below is read, not
recalled.

1. **Hot calls share the loop hotcount table.** `lj_dispatch.h:74-79`:
   `HOTCOUNT_LOOP=2`, `HOTCOUNT_CALL=1` — a function head must be hit twice
   as many times as a loop back-edge before it triggers
   (`lj_dispatch.c:89`). The trigger routes through `lj_dispatch_call`
   (`lj_dispatch.c:467`, the `(uintptr_t)pc & 1` hot marker) →
   `lj_trace_hot` (`lj_trace.c:781`) → root trace anchored at the
   **function head** (`BC_FUNCF`).
2. **Recording a call pushes a virtual frame** (`lj_record_call`,
   `lj_record.c:863`) with callee specialization (our `guard_func`).
   Recording at a function start takes a **root snapshot and performs
   stack checks** (`lj_record.c:2893` region) — mahina needs the same
   function-entry deopt snapshot, not just seeded SSA values.
3. **Recursion converts into trace links, not aborts.** `check_call_unroll`
   (`lj_record.c:1868-1893`): when the target of a recursive call is the
   trace's own start and the unroll budget is spent, stop as **TAILREC**
   (`framedepth+retdepth==0`) or **UPREC** (frames accumulate). Note the
   ordering: LuaJIT records the call, enters the callee header, THEN
   recognizes recursion — our P0 mechanism (stop *before* the self-call)
   is a deliberate staged analogue, not a literal replication; Phase 4's
   native frame push converges on the real model.
4. **Returns are recorded, including into frames the trace never entered.**
   `lj_record_ret` (`lj_record.c:921-1010`): depth>0 pops the virtual
   frame (our `recReturn`); depth-0 emits `IR_RETF` guarding the return
   target and continues in the caller (`retdepth++`) — handling Lua,
   protected-call, vararg, and continuation frames each explicitly; a
   loop-anchored root instead errors LLEAVE (our `.cross_frame`, correctly
   scoped to loop roots only). Repeated returns of the anchor proto close
   **DOWNREC** (`lj_record.c:897-917`); returning to a non-Lua frame stops
   cleanly with a **RETURN** link (`lj_record.c:952`).
5. **Entry is bytecode patching.** `trace_stop` (`lj_trace.c`):
   `BC_FUNCF → BC_JFUNCF`; **`BC_RET*` anchors get `BC_JLOOP`** (down-rec
   roots enter at a `ret`); un-inlinable calls stitch (`BC_CALL` case).

## 3. What mahina already has, and the exact gaps

From the 2026-09-08 machinery map (explorer sweep; file:line spot-checked)
plus the codex review pass:

**Reusable as-is:**
- `AnchorKey` maps (counters, gate, record_gate, penalty, coverage, memos)
  are generic `(proto, pc)` (`trace_types.zig:319`).
- `findTrace`/`nextTraceExcluding`/`hasTrace` are pc-generic
  (`trace.zig:1888+`).
- Non-back-edge **arming precedent**: `pending_exit_anchor` /
  `maybeStartContinuation`, `pending_replay_anchor` /
  `maybeStartReplaySide` (`trace_link.zig:208-245`) — dispatch-prologue
  activation, `.full`-pinned.
- Doc-42 dispatch: `opCall`'s `.function` arm ends in `dispatchTail`
  (`interp.zig:4305`), so callee pc 0 always flows through the full
  prologue.
- Doc-20 image-based entry patching; the recorder's frame machinery
  (`InlineFrame`, `recCall`, `recReturn`, `MAX_INLINE_DEPTH=3`).

**The gaps (review-hardened list):**
1. No hot-call counter; back-edges are the only counting site.
2. **`anchor.pc` is treated as an executable bytecode pc in several
   places**, so a bare sentinel is NOT transparent: bridge selection
   compares exit pcs against `anchor.pc` (`trace_code.zig:284`), the loop
   classifier reads CFG back-edges at it (`trace.zig:163`), chaining
   derives resume pcs from it (`trace_chain.zig:264`), structural
   successor logic reads bytecode at it (`trace_link.zig:500`), and
   `arm()` uses it as the recording start (`trace.zig:2924`). Identity and
   entry pc must be SEPARATED (D1).
3. `resolvePatchPc`/`patchedEntryOp` derive the patched op from the
   original op and re-derive on unpatch (`trace_entry_registry.zig:75,
   99, 166`) — a head patch needs a first-class patch kind, plus mirror
   canonicalization (`interp.zig:6049`) and prologue ordering (pending
   processed before mirroring, `interp.zig:2425`).
4. Recorder aborts `.cross_frame` on depth-0 `ret`
   (`trace_recorder.zig:802-807`) — correct for loop roots, needs a
   `.head` arm. Root-only policies (e.g. inner-loop LINNER at
   `trace_recorder.zig:2730`) must treat `.head` as root-like.
5. Terminator set is `{loop, link}`; a one-shot (non-cyclic) trace is a
   new shape with its own finalization (no loop φs) and its own exit
   contract (D5).
6. `opRet`/`opCall` consult dynamic result-top state for `all_results`
   (`interp.zig:4430, 4262`) — the terminal snapshot must carry it or the
   shape must be refused in P0.
7. No function-header opcode (`compiler.zig:1188-1198`); no tail-call
   opcode (`return f()` is `call`+`ret`, so tail recursion rides
   up-recursion).
8. Determinism (CLAUDE.md; `trace.zig:682-695` precedent): tiering
   decisions must be pure functions of deterministic counters — stated
   narrowly in D7.

## 4. Design

### D1 — head-anchor identity: typed, with entry pc separated

Anchor identity gains a **kind**, and the executable pc is stored
separately from the key:

- `AnchorKey` stays the map key, with pc = `FUNC_HEAD_PC` (`maxInt(u32)`)
  for head anchors — the maps don't care. But every consumer that
  *executes or inspects bytecode at* `anchor.pc` goes through a new
  `entryPc(anchor) u32` / `anchorKind(anchor)` pair: head anchors resolve
  to entry pc 0 and kind `.function_head`; loop anchors are unchanged.
- **Head traces are explicitly excluded** from loop-region bridging
  (`classifyBridgeCandidate` — the `trace_code.zig:284` pc comparison),
  loop back-edge classification (`trace.zig:163`), and ordinary
  anchor-state chaining (`trace_chain.zig:264` resume-pc derivation) —
  each site gets a kind check, fail-closed, with a test per site.
- Why not pc 0 as the key: a `while` at the top of a function anchors a
  loop at pc 0; the two must not share counters/gates/cache rows.
- **Serialization**: the u32 fits, but the schema now carries meaning —
  bump `traceser.format_version` (`traceser.zig:30`), serialize the kind,
  and mirror in the viz decoder.

### D2 — hot-call counting

Site: `opCall`'s `.function` arm, immediately after `reloadTopFrame` —
after tier-0's own capacity/depth checks and frame push, so failed calls
never count (`interp.zig:4271-4299`). A new `TraceState.onCallEntry`:

- Existing `counters` map on the head key; threshold `config.hotcall`,
  default `2 * hotloop = 112` (LuaJIT's ½-weight as a separate threshold —
  the loop pre-filter stays untouched). No direct-mapped pre-filter for
  calls in v1; add only if a tier-0 profile demands it (nsieve lesson).
- **Calls advance the gate-cooldown `tick`.** (Review finding: a call-only
  recursive workload that aborts recording would otherwise stay gated
  forever — cooldowns must elapse in call-time too. Deterministic: tick is
  an event counter either way.)
- Gates: `recordingBarred(head_key)` exactly as for loops; strikes/backoff
  inherited.
- Vararg callees: **refused** in P0 (`cp.is_vararg` → no count, no arm) —
  head arming happens after the call, bypassing `recCall`'s vararg
  rejection, so the refusal must live here.
- Hot verdict → set `pending_call_anchor` (D3). Never arm inside `opCall`:
  recording must start under `.full` with the mirror active (T3).

### D3 — arming: `pending_call_anchor`, lifecycle-hardened

The `maybeStartContinuation` twin, with the review's lifecycle additions:

- The pending record carries `{ head_key, base, call_seq }` —
  `call_seq` (stamped at `pushFrame`, `interp.zig:1706`) pins the
  activation, so a stale pending can never attach to a later frame.
- Armed from the dispatch prologue at callee pc 0, `.full`-pinned, BEFORE
  the recording mirror step (ordering per review change 2).
- **Cleared on every exit path**: VM error/unwind, recording abort,
  cache/registry reset, and the doc-20 bypass set gains the new pending
  (as the two existing pendings already do, `interp.zig:3902-3908`).
- Arm → `RecordingSession` kind `.head`, recording start pc 0,
  `anchor_abs_base` = callee base, plus a **function-entry deopt
  snapshot**: guard failures anywhere in the trace restore function-entry
  state at real pc 0 (the LuaJIT root-snapshot analogue) — NOT the
  terminal state.

### D4 — recording a head-anchored root

Existing machinery carries over (anchor frame = callee; `inline_depth`
counts frames above it). Deltas:

- **Depth-0 `ret` closes** via `.terminal` kind `.return_interp` — the
  trace ends *before* executing the ret.
- **Depth-0 direct self-call closes** (IN P0 — review change 6) via
  `.terminal` kind `.self_call_interp` — ends *before* the call, args
  materialized. For fib this is decisive: the bench computes `fib(n-2)`
  first (`bench/luajit/recursive-fib.lua:4`), so the arming invocation is
  generally non-base; without the self-call terminal, recording inlines to
  `MAX_INLINE_DEPTH` and aborts `.too_deep` before any depth-0 ret. The
  useful non-base P0 trace: entry guards → base-branch guard → `n-2` arg
  prep → self-call terminal; tier-0 performs the call; the patched head
  re-enters.
- Depth>0 self-calls: `recunroll` budget (default 2) then abort
  `.too_deep` (P1 tunes this).
- **Stack-depth guard**: recorder-inlined calls don't physically push
  frames, so recording guards that tier-0 depth + inline depth stays
  below `max_call_depth` — tracing must never suppress a program-visible
  stack overflow.
- **`all_results` shapes**: a depth-0 `ret` with dynamic multret (`b ==
  all_results`), or a terminal self-call feeding one, is **refused in P0**
  (abort `.nyi_opcode`) — the terminal snapshot doesn't carry
  `reg_top` state yet (gap 6). Revisit in P1.
- `.head` is root-like in every root-only policy (inner-loop LINNER
  `trace_recorder.zig:2730`, peel eligibility, etc.) — audited as a
  checklist item, one test per site.

### D5 — the `.terminal` IR op and the terminal-exit contract

One appended IR op **`.terminal`** (wire ordinal 86): `a` = TerminalKind
(`return_interp` / `self_call_interp`; room for `tailrec`/`downrec`
later), `aux` = the real resume pc (the ret or call pc). No operands —
like `.loop`/`.link` it's a terminator; `assertWellFormed` requires it
last, and requires kind `.head` ⟺ terminal-terminated.

**A successful terminal exit is NOT a side exit.** The review's central
correction, now the contract:

- Ordinary guard failure in a head trace → restore the function-entry
  snapshot, resume tier-0 at pc 0 (replay-from-anchor, the existing
  discipline).
- `.terminal` success → **publish terminal state** (flush φ-less
  writebacks + sunk stores exactly once — C1 idempotence holds because
  the terminator was never executed in-trace), resume tier-0 at
  `terminal.aux`, and execute only that one unexecuted instruction.
- The terminal result is a distinct variant in the entry directive
  (kind, resume_pc, productive-iteration accounting) that **bypasses**
  guard-hotness accounting, side-trace formation, `driveChain`, and
  loop-done classification — otherwise a healthy head trace reads as a
  zero-progress entry and gets gated/unpatched
  (`interp.zig:3361` strike accounting).
- Finalization: a `.head` trace gets its own path in `trace_finalize` —
  pending stores appended below the last guard as today, but **no loop
  φs** (one-shot shape); the loop-φ pass asserts it never sees `.head`.

### D6 — execution: `jfunc_head` as a first-class patch kind

- New bytecode op **`jfunc_head`** (appended; dense-enum + `handlerFor`
  mirrored). `EntryPatch` gains the patch kind (or stores the patched op)
  so install/incumbent-detect/unpatch/image-regen stop deriving it from
  the original op (`trace_entry_registry.zig:75/99/166`).
- `resolvePatchPc`: kind `.function_head` → pc 0, no closer search.
- `opJFuncHead` mirrors `opJLoop`: bypass set → canonical step from
  `patch.orig`; else enter the head trace. `recordingMirrorInstr` gains
  the `jfunc_head` arm (recordings see virgin bytecode).
- All call sites share the patch (it lives in the callee's image) — the
  `JFUNCF` economics.
- Native lowering of `.terminal`: flush like the loop-done snapshot, jump
  to a terminal stub that reports the terminal directive (not a guard
  exit index). Prologue/seeding contract unchanged.

### D7 — determinism + replay, stated narrowly

- The call counter is a deterministic function of **successful Lua-callee
  entries observed by tier-0 dispatch**. It is NOT invariant under
  tiering (recorder-inlined and future native-to-native calls don't pass
  through `opCall`) — acceptable because tiering state is not
  program-visible output, and pinned by ten-leg equivalence tests (same
  outputs across the matrix, as always).
- No addresses, no time, no RNG in any verdict (LuaJIT's pointer-hash +
  `lj_prng` retry jitter are explicitly NOT copied — deterministic
  equivalents only, the hotcount precedent).
- Anchors serialize as `(Proto.id, kind, pc)`; format_version bumped.

### D8 — P1a: base-vs-non-base head SIBLINGS (same-anchor walk + head re-arm)

**The problem (P0 field data).** The recorded head shape is decided by
whichever call trips `hotcall` — fib(15)/fib(25) seed a BASE-CASE trace
(`guard_true n<2`), the majority non-base entries then zero-exit it, four
consecutive `.next_candidate`s exhaust `patch_strikes`, and a retired head
never re-arms (`onCallEntry` refuses on `hasTrace`): coverage collapses to
0 for those inputs. Symmetrically, a non-base incumbent (fib 18/30) eats a
zero exit on every base-case call — survival is a shape accident (max
base-case run 3 < 4 strikes).

**The shape is the loop-anchor sibling discipline, not the side-trace
discipline.** A head guard fail at `completed == 0` leaves the registers
coherent at function entry — the exact state every OTHER head trace at the
same anchor wants. So the alternate path is a same-anchor SIBLING (the
prime-side/branch analogue), selected by trial entry, NOT an exit-pc
side trace (there is no coherent mid-function resume state to anchor one
on). LuaJIT's equivalent is recording a new trace from `BC_JFUNCF` when
the existing one keeps exiting (`lj_dispatch` hot-call path re-fires).

Four pieces, all reusing standing machinery (as revised by review round 2
— the walk consumes the want on the CURRENT activation, and the head patch
gets its own retention/recovery lifecycle):

1. **Hot-exit accounting for heads** — the head zero-exit consumer calls
   `noteTakenExit` (P0 skipped it entirely). A new HEAD route inside
   `noteTakenExit`, before the branch/generic routes: on `isHeadAnchorPc`,
   set a dedicated `wants_head_sibling: ?{anchor, src trace id, src exit}`
   (occupancy-gated like the other wants, capped by
   `anchorPopulation >= max_traces_per_anchor`, `recordingBarred`-gated)
   and — decisively — do NOT `markEntryPatchesAt`. Unpatching is the
   loop-anchor trigger for re-arming via the virgin back-edge walk; a head
   has no back-edge walk, and unpatching would sever the SOLE entry to
   every sibling. The exit counter (`t.exit_counts` + `hotexit`) is shared
   and stays deterministic.
2. **Sibling walk at the patched entry** — `enterPatchedTrace`, on a
   `.next_candidate` directive from the incumbent, walks the OTHER head
   traces at the anchor through `enterSelectedTrace`, extending the
   `visited` set as it goes. Selection order is `nextTraceExcluding`'s
   real deterministic order: highest `hit_count` first, registry insertion
   order as tiebreak (NOT bare registry order). Any terminal completion
   resolves the entry (strikes reset by the existing
   `directive != .next_candidate` rule). If the walk TRUNCATES at
   `trial_visited_cap` with unvisited siblings remaining, the decline does
   NOT strike (all-declined semantics require all-visited). The second
   trace's `installEntryPatch` returns `.incumbent` and stays slotless —
   sibling dispatch rides the walk, never a second patch. No candidate's
   `wctx.dead` removal happens until the walk ends (caller-owned removal
   for the whole walk).
3. **Want consumption on the CURRENT activation** (review round 2's
   reframe — no delayed `onCallEntry` arming): when the incumbent AND
   every sibling decline and `wants_head_sibling` matches this anchor,
   transfer the want into `pending_call_anchor` pinned to the CURRENT
   activation (`proto`, `base`, this frame's `call_seq`) and route back
   through the `.full` prologue so `maybeStartHead` arms at pc 0 of the
   VERY activation whose path just failed every candidate — recording the
   observed failing path exactly. This kills the delayed-consumption
   hazards wholesale: no "calls stopped" stuck want, no duplicate-shape
   recording, no cross-proto want blocking. Transfer rules: leave the want
   intact while `rec.active` or another `pending_call_anchor` exists;
   re-check `recordingBarred` at transfer; clear want state on cache
   reset. Recording under a live patch already works (`opJFuncHead`
   declines to canonical while `isRecording`; the mirror canonicalizes).
4. **Head patch retention + recovery** (review round 2 blockers): (a) a
   head entry patch accrues NO ordinary retirement strikes while
   `anchorPopulation < max_traces_per_anchor` — otherwise
   `patch_strikes=4 < hotexit=10` retires the sole entry before any exit
   can get hot, reproducing the P0 collapse; at capacity, ordinary strikes
   resume. (b) On a sibling's terminal completion, clear a matching want
   AND latch the want's source `(trace, exit)` counter to
   `EXIT_COUNT_DONE` — else a saturated incumbent exit re-raises the want
   forever and records duplicates. (c) Every OTHER unpatch source
   (`gateAnchor`'s `markEntryPatchesAt`, strike exhaustion at capacity,
   incumbent retirement) gets a deterministic recovery route: `onCallEntry`,
   on `hasTrace` with no live entry patch and `recordingBarred` clear,
   re-requests install for the anchor's best surviving trace (idempotent —
   an `.incumbent` result is a no-op).

**Receipts contract.** Sibling completions route through the SAME terminal
consumer (productive receipt, clear-on-productive); sibling zero exits
charge their own trace's ordinary zero receipt, so the gate can still
retire an individually useless sibling while the anchor stays healthy.

**Determinism.** Every trigger is a pure function of deterministic
counters (exit counts, want occupancy, hit counts, registry order); no
addresses, no time. The ten-leg matrix pins equivalence as always.

**Z-6 note (review round 2).** The mechanism is path-polymorphic
function-head specialization — general over any stable branch/type/callee
split at a function head, with "base vs non-base recursion" merely the
motivating instance. No predicate inspects recursion or numeric base
cases; the test set includes a non-recursive two-path head.

### D9 — P1b: the quiet head episode (lean entry)

**Profile receipt (2026-09-08, fib 31, ReleaseFast, `perf record`).** Per
the house recipe: native `[JIT]` code is **6.4%** of cycles; the
dispatcher episode around it is ~60% (`enterSelectedTrace` self 22.9%,
`accountRegionProfit` 8.6%, `nativeSeedFn` 4.0%, `opJFuncHead` 4.1%,
wyhash+hashmap ~7%, provenance capture/settle ~3.6%, silent/staging/arms
~4%); tier-0 `opCall`/`opRet` ~14%. Annotating the hot receipt functions
shows the bodies all early-out in O(1) — the cost is **the call frames
themselves**: ~15 outlined calls per episode, each 5–30 cycles of
prologue + cold-field loads (`accountRegionProfit` alone builds a
344-byte frame 4M+ times to immediately return false), plus 3–4 hash
lookups and `enterSelectedTrace`'s own 344-byte worst-case frame.
Total ≈ 640 cycles wrapping a ~20-cycle native body.

**Shape of the fix — one predicate, not fifteen pre-checks.** Scattering
`if (empty) skip` guards at each call site is seam polish. The general
mechanism: compute once, per entry, an O(1) **quiet predicate** — "no
machinery that could observe or steer this episode is live" — and run a
dedicated small-frame episode function when it holds. Non-quiet states
(anything armed, promoted, penalized, regioned, pending) take today's
full path unchanged. This survives P4 (fewer episodes, same entry code)
and the predicate + structure extend to loop-anchor entries as a
follow-up — heads first because their result grammar is tiny (D5/D8:
terminal, zero exit, prologue-fail, two seed declines; no links, no
chains, no ledgers > 1).

**The quiet predicate** (all O(1) loads, computed fresh per entry — no
cached flag to drift; the `captureProvenanceVerdicts` comment's
emptiness-over-counter rule):

- `config.native_codegen` (review round 3: `.compiled` alone does not
  imply the config would RUN it native — the full path gates page
  resolution on this)
- `ct.native == .compiled` and `!compiled.has_hash_seed` (new bool set at
  compile time iff the seed plan has an ACTIVE `hash_cell` bit — active
  plan bits, not raw inputs; `nativeSeedFn` raises the hash decline only
  from an active `.hash_cell`, every other seed failure is a capacity
  decline — the one decline that needs the tier-1a rerun machinery; such
  traces always take the full path)
- `registry.native_physical.armedLinks().len == 0` (⇒ no fusion: scalar
  result, `final == ct`, `silent_active == 0`, `ledger_len <= 1`;
  `disarmAllLinks` is a no-op). `hasNativeLoopDoneLink` is NOT covered by
  this (review round 3: it scans logical continuation traces + memoizes,
  independent of physical arms, and its scanner did not reject head
  anchors — a latent misclassification for a head with a coincident
  exit-pc link terminal). Fix: the D1-style
  `isHeadAnchorPc → return false` check lands in `hasNativeLoopDoneLink`
  itself, before its memo, so BOTH paths structurally select ordinary
  entry mode for heads and the quiet path omits the call.
- `pending_demote.items.len == 0 and !pending_disarm_all` and no pending
  native invalidation (⇒ `applyPendingDisarms`/`drainBarrier`/
  `syncNativeInvalidation` are no-ops), and
  `native_physical.debug_log == config.debug_log` (review round 3:
  `applyPendingDisarms` unconditionally syncs that field — a mismatch
  takes one full entry to synchronize rather than an unconditional store
  on every quiet entry)
- `promotedSets().len == 0` (⇒ `prepareNativeEntry` no-op,
  `silentStaging() == .{}`, no silent epilogue reachable)
- `provenance_edges.items.len == 0` and `pending_sibling_arm == null` and
  `pending_bridge_arm == null` (⇒ capture/settle/drain provenance and
  `tryArmSiblingHandoff` are no-ops)
- `region_policy.receiptsInert()` (⇒ `accountRegionProfit` returns false)
- `penalty.count() == 0 and gate.count() == 0` (⇒ the productive-clear
  hashes are no-ops; heads' gate reads stay correct because a non-empty
  map forces the full path)
- `!config.coverage` (coverage runs want the tsc stamps; `--jit-stats`
  keeps full-path attribution)

Recording/suspend/exec-log/pending-anchor states need no predicate bits:
the `jfunc_head` §R1-5 bypass set already routes those to the canonical
instruction before any entry runs (debug-asserted in the quiet path).

**The quiet episode** (`enterHeadNativeQuiet`), per entry: unicode-pin
debug assert; `entries`/`native_entries` counters; `prepareNativeEpisode`
(7 stores — the native page still seeds itself); `runCapturingLedger(regs,
&ledger_scratch, .{})`; `last_exit_instr`; then the head grammar:

- **`.terminal`** → `accountTraceRun(ct, 1)` (kept in full — it mutates
  `hit_count` and can mark entry-patch installation pending) +
  `accountCandidateCharge(ct, .entered)` (= exactly what
  `onSideExitReceipt` reduces to under the predicate: region false,
  legacy productive path's two map removals no-op on empty maps) +
  `noteHeadSiblingCompletion` (null-check fast) →
  `.resume_tier0(term.aux)`. The jit-debug terminal receipt (`dbg`) is
  kept so debug stderr stays behavior-identical (comptime-free
  otherwise).
- **`seed_capacity_decline`** → dbg + counter → `.next_candidate`
  (verbatim the full path's handler; nothing committed).
- **zero exit / prologue-fail** → the real `noteTakenExit` +
  `onSideExitReceipt` calls, verbatim semantics (these MUTATE penalty
  state, correctly ending quietness for subsequent entries) →
  `.next_candidate` into the D8 sibling walk, where each sibling entry
  retries the quiet path itself.

Debug asserts on the guarantees the predicate buys:
`result.final_trace_id == ct.id`, `silent_active == 0`,
`ledger_len <= 1`, `exit_reason != .seed_hash_decline`.

**Byte-identical by construction.** Every skipped call is proven no-op
under the predicate; every taken action is the same calls the full path
makes. The gate battery (hashgate 84×2) must stay byte-identical — this
slice has no behavioral latitude at all.

**Companion general slices (same arc, separately landable):**

- **S1 — `onCallEntry` image-first.** The call site (opCall, post
  `reloadTopFrame`) already holds the callee image in `st.code`; pass it
  in. Review round 3 ordering: `tick +%= 1` and the
  enabled/rec.active/vararg bars keep their exact current order; the new
  bounds-checked `img[0].op == .jfunc_head → return` sits after them
  (entry is the patch's job — `maybeRepatchHead` already returns on this
  same opcode check). Removes the per-call `hasTrace` hash and the
  per-call `codeFor` hash D8's `maybeRepatchHead` introduced (part of
  the 477→550 regression) from the PATCHED steady state only — the
  unpatched path keeps `hasTrace` so D8 repatch recovery stays live.
- **S4 — frame-cached code image.** `CallFrame` gains
  `code_cache: []const Instr` + `code_cache_gen: ?u64` (review round 3:
  `image_gen` is u64; `null` is the validity bit — gen 0 is real and
  `len == 0` must not double as invalid, empty images are cacheable).
  Push invalidates (covers frame-slot reuse and keyframe restore, which
  recreates frames through push); one shared helper validates/refills
  and serves `reloadTopFrame`, `execImpl` construction, and the
  patched-entry post-drain refreshes. Kills the per-pop `codeFor` hash
  in `opRet` (1.36% of fib inside `getIndex` alone) for every program
  with calls, head-traced or not. The snapshot schema keeps omitting
  transient fields.

**Non-goals.** No change to what receipts/gates/wants DO — only to when
the no-op paths are physically executed. The loop-anchor quiet episode is
a follow-up once the head shape proves out. P4 still owns removing the
episode-per-call structure for recursion; this makes the episodes that
remain (and every episode P4 keeps: outermost entries, side exits) cheap.

### D10 — P4 slice 1: head-sibling exit-branch patching

**The measured residual (D9 re-profile).** With the quiet episode landed,
every LEAF call of fib still pays: incumbent A entry → base-guard zero
exit (noteTakenExit + zero receipt, penalty insert) → D8 walk → sibling
B full episode (the penalty insert forces B non-quiet) → terminal
(penalty remove). Two episodes plus map churn per leaf, ~half of all
calls. LuaJIT's answer is exit-branch patching: the failing guard jumps
straight into the side trace's native code. **We already built the
machine for loop anchors** — Part S sibling handoffs (`noteSiblingTerminal`
watch → `pending_sibling_arm` → `tryArmSiblingHandoff` at the selection
site → `armNativeLink(.sibling_handoff)`); D10 is that machine admitted
to head anchors, not a new mechanism (Z-6: path-polymorphic sibling
fusion at any shared anchor; heads are one instance).

**Why `.sibling_handoff` fits verbatim.** Its arm validator already
demands everything a head handoff needs: same-anchor parent/child,
`exitIsPreEffect` (head guards precede any store — regs and heap
untouched since pc 0, so re-entering the sibling at entry state is
coherent), NOT loop-done / NOT bridge candidate (both structurally false
for heads since D1), `stubEnterable(.ordinary)` (a seeded child
self-seeds from the episode ctx, which is fresh — same closure/base/
proto, it's the same activation). The ping-pong hazard is already
solved: `siblingHandoffEligible` arms **source-branch guards only** — a
branch guard failing means the program took the other branch, exactly
the base/non-base split; head entry TYPE guards stay unarmed. A
no-sibling-matches value walks the armed chain once and yields at the
native ledger cap — bounded, and the final row is a real zero exit.

**Piece 1 — evidence + arming (all existing machinery).** Evidence is
a walk-local channel (round 4 — not `last_exit_instr`, which episodes
overwrite on paths that are not guard evidence): `head_walk_fail:
?ExitKey`, reset at walk start; SET by every real head guard-deopt
consumer (scalar zero exit, fused final deopt — the LAST failed trace,
not the entered one); UNCHANGED by declines/prologue-fails (evidence
survives an intervening decline); CONSUMED at every terminal-completion
consumer: if the completing trace differs from the recorded failer,
call `noteSiblingTerminal(failer, exit)` and clear. The existing watch
accrues per (trace, exit), crosses `hotguard`, and raises
`pending_sibling_arm`. Consumption needs ZERO new code: a standing
pending forces the quiet predicate false, and the full path's
entry-sited `tryArmSiblingHandoff(entered)` fires on a LATER walk when
the dispatcher again selects a real sibling after the parent's failure
(round-4 timing note: not on the threshold-crossing entry itself — B
was already entered when the watch crossed) — `publishSiblingArm` then
patches A's exit stub to B's `ordinary_entry`.

Head eligibility is strengthened in `siblingHandoffEligible` (round 4):
for a head parent the guard must carry exact non-inlined
`.branch_cond` provenance — `isSourceBranchGuardExit`'s shape-only
check can misclassify an inlined guard through a coincidental
source-pc opcode. And the central arm validator makes "a head slot
carries only `.sibling_handoff` arms" a DURABLE invariant: every other
arm kind explicitly rejects a head parent (today that exclusion is a
distributed fact about triggers; quiet-v2 correctness must not rest on
it).

**Piece 2 — the fused-result consumer (dispatcher-level, NOT
replayLedger).** A fused head run returns a multi-row ledger. Round-4
correction: without a new consumer the fused ledger would NOT panic —
it would be **silently mis-consumed** by the scalar terminal / head
zero-exit consumers (which read only the terminal body's fields and
drop the intermediate rows); `driveDispatcherLedger` → the
`head_terminal` `@panic` sits after them and is only the backstop. So
the head-burst consumer is keyed on `ledger_len > 1` BEFORE the scalar
head consumers, at both dispatch sites; the chain machine's fail-closed
arms stay (heads still never enter `replayLedger`).

The full grammar (round 4 — the child's `ordinary_entry` runs its seed
+ hoisted-type prologues, so decline terminals are reachable):
`[A.deopt…, B.head_terminal | B.deopt | B.deopt(.yielded, full-cap
only) | B.prologue_fail | B.seed_capacity_decline]`.
`seed_hash_decline` is excluded at ARM time instead: a head
`.sibling_handoff` arm refuses a hash-seeded child (`has_hash_seed`,
the D9 flag) — the tier-1a rerun contract cannot be met mid-fusion.

Release-mode validation (round 4 — matching the generic replay's
registry-adjacency discipline, not a debug assert): every non-final row
must resolve, anchor at the entered head's `{proto, FUNC_HEAD_PC}`, be
`kind == .deopt` with normal reason/outcome, and carry an exact armed
`.sibling_handoff` edge to the next row's owner
(`hasArmedSiblingHandoff`); `.yielded` is valid only as the last row of
a full-cap ledger. Per row:
- **Intermediate rows**: `accountTraceRun(row, 0)` AND
  `accountCandidateCharge(row, .entered)` (round 4: an intermediate
  handoff is a successfully entered candidate — the refusal streak must
  reset exactly as ordinary ledger accounting preserves it). NO zero
  receipt, NO `noteTakenExit` — a patched branch is a designed edge,
  not thrash (doc 38 precedent); this deletes the per-leaf penalty
  churn. The exit counter is already saturated/armed.
- **Final `head_terminal`**: the existing terminal consumer — REAL
  `onSideExitReceipt` productive receipt on the final trace (shared
  between quiet and full paths, so it must be the real funnel — S2
  makes it cheap when maps are empty), `noteHeadSiblingCompletion`,
  resume at its `term.aux`.
- **Final deopt (normal)**: the existing head zero-exit consumer on the
  final trace (`noteTakenExit` + zero receipt) → `.next_candidate`.
- **Final deopt (.yielded)**: cap artifact, not hotness evidence — zero
  receipt without `noteTakenExit` → `.next_candidate` (entry image
  still coherent, the walk continues).
- **Final prologue-fail / capacity-decline**: the existing scalar
  handlers' semantics → `.next_candidate`.
The consumer records the fused-FAILED owners (deduped — a full-cap
cyclic chain has 32 rows but few unique siblings; the walk buffer holds
8) into a walk-visible scratch; the D8 walk merges them into `visited`,
setting `walk_truncated` on overflow so strike semantics stay honest.

**Piece 3 — quiet predicate v2.** Drop the global
`armedLinks().len == 0` line — it was doing two jobs. The job it keeps
via OTHER predicate lines: no silent state (`promotedSets` empty), no
provenance scans (`provenance_edges` empty), no pending consumption
(`pending_sibling_arm == null`). The job it loses on purpose: "no
fusion ⇒ scalar ledger" — the quiet consumer now walks the (small)
ledger instead of asserting `ledger_len <= 1`, with a debug assert that
every row resolves to a head-anchored trace. This also fixes a real
D9 generality gap: the old line turned the quiet path off in ANY
program with armed loop links (scimark et al.), starving exactly the
mixed loop+call workloads (Z-6).

**Accounting/determinism.** Everything is a pure function of the
deterministic ledger. Native legs fuse; tier-1a legs walk unfused and
so see a different receipt stream — that is already true of every
native-vs-tier-1a tiering difference; the ten-leg gate pins OUTPUT
equality, which guard re-verification preserves (a fused entry commits
exactly what the unfused walk would have committed). Arms are
native-physical only; exec-log legs bypass patched entries entirely.

**Lifecycle.** Retirement/disarm of either sibling rides the existing
P-E teardown (`removeTrace` → link disarm paths); `EXIT_COUNT_DONE` and
the D8 want machinery are unaffected (the want records NEW siblings
below capacity; the arm fuses EXISTING ones — they compose).

### D11 — P4 slice 2: native frame push at the self-call terminal

**Profile receipt (post-D10, fib(31), f31fab4).** The accounting
machinery is off the board; what remains is the per-call turnstile
itself: tier-0 call/return scaffolding ≈45% (opCall 14.7%, opRet 9.5%,
opLoad 9.3%, opJFuncHead 6.9%, opGetUpval 4.4%, opBinNum 6.5%), episode
entry ≈17% (`runCapturingLedger` wrapper 21.1% incl. the native body —
bare `[JIT]` rows only ~2.5% — `enterHeadNativeQuiet` 10.5%,
`consumeHeadBurst` 5.6%), per-call `codeFor` hash ≈5.5%. `--jit-stats`:
100% head residency, traced 45.5% of cycles at ~248 c/iter, "other
(non-loop)" 54.5%. Every self-call today exits native, re-enters tier-0,
runs `opCall` + the jfunc_head dispatch, and opens a fresh episode —
hundreds of cycles for what LuaJIT does with an in-trace frame push
(`lj_record.c` up-recursion). This slice replicates that descent-side
mechanism; returns (down-recursion) stay tier-0 and belong to P3.

**The shape.** A head trace ending in `.terminal(self_call_interp)`
gets, on the NATIVE lowering only, a frame-push epilogue instead of the
plain exit: flush the terminal snapshot into the caller window (exactly
today's flush — it is what makes tier-0's re-executed call correct, so
by construction it materializes the argument registers), call a runtime
helper that replicates `opCall`'s Lua-closure arm verbatim (callee
window layout + `pushFrameVararg` + caller resume-cursor freeze), shift
the window lane pointers by the anchor proto's `num_registers`
(compile-time constant — self-call ⇒ same proto), and jump to the
page's own `ordinary_entry` so the hoisted entry-type guards and seed
prologue re-run against the new activation. The recursion descent
becomes a native loop over real VM frames.

**Nothing is recorded differently.** The `TerminalKind` stays
`self_call_interp`; the push is a LOWERING decision inside nativegen
(the doc's own P0 note anticipated "native-resuming kinds alongside" —
we go one better: no new recorded kind at all, so recording and the
tier-1a legs are byte-identical to today, and the ten-leg matrix keeps
its D10 shape: native legs descend natively, tier-1a legs keep the
interp terminal).

**Piece 1 — runtime eligibility lives in the helper, not the trace.**
P0 deliberately emits NO callee pin at the self-call ("tier-0
re-executes the call generically", recCall) — so the native push must
re-derive legality per push, fail-closed to the plain terminal exit
(publish `exit_instr` + `head_terminal` row + `shared_exit`; tier-0
re-executes the call generically, including raising the proper errors):
- the callee value in the caller window is a heap `.function` whose
  `proto == anchor.proto` (the actual value, read from the just-flushed
  window — a rebound name at run time simply declines; closure IDENTITY
  is deliberately not required — same-proto different-upvalue closures
  are safe because the pushed closure and refreshed ctx are the ACTUAL
  entering ones, round 5 confirmation);
- `depth < max_call_depth` and `callee_base + nreg <= regCapacity()`
  (the two `opCall` overflow walls — on refusal tier-0 re-runs the call
  and raises `StackOverflow` with intact frames for `describeFault`);
- round 5 change 6 — the record-time exclusions are DISTANT invariants
  and the helper is the fail-closed boundary, so it re-verifies them
  before any mutation: `terminal.aux` in bounds and naming a `.call`;
  `instr.b != all_results` (the recorder refuses these, recCall, but
  verify anyway); the anchor proto non-vararg; `!vm.reg_top_pending`.
  Surplus args on a non-vararg callee nil-fill exactly as `opCall` does
  (`va_count = 0`); `instr.c == all_results` is safe return wiring the
  real frame stores and `opRet` already resolves;
- round 5 change 2 — `region_policy.receiptsInert()` must hold, checked
  once per EPISODE at the descent-capable entry (not per push): a
  descent's ledger rows are consumed after the episode against the LEAF
  activation's region context, but D10 handoff rows can originate in
  ancestor activations — `pushed_frames` is a total and cannot re-pair
  rows with their originating `call_seq`, so replaying rows into live
  region accounting would attach receipts to the wrong activation.
  V1 disables descents while region receipts are live (mirroring the
  quiet predicate's own line); the larger per-row-activation-identity
  alternative is recorded as a non-goal.

**Piece 2 — the helper is `opCall` verbatim, plus the episode ctx.**
`nativeSelfCallPush` (C-ABI callout, absolute `mov rax,imm64; call` like
the hash-cell callout; context pointer baked at compile time) performs,
in order: read the call instr fields (`a`/`b`/`c`) from
`anchor.proto.code[terminal.aux]`; the checks above; the callee-window
layout loop (bind params, nil-fill the rest — straight-line,
allocation-free, above `stack_top` until the push raises it, same as
tier-0); freeze the CALLER frame's resume cursor to `terminal.aux + 1`
(the one-past-call cursor `opCall` freezes — this is what keeps
`backtraceFrames`, `opRet`, and any mid-descent fault byte-identical);
`pushFrameVararg(cl, callee_base, instr.a, instr.c, 0, 0)` — the real
funnel: frame struct, `depth`, `stack_top`, `next_call_seq` bump,
`setRegionContext` — so the call_seq STREAM is identical to the tier-0
legs by construction; refresh the native episode ctx
(`prepareNativeEpisode` equivalent: entering closure, proto, new base)
so per-activation seeds (upvalues — the D9 closure-swap pin) re-resolve
against the pushed activation and `stubEnterable`'s freshness clause
keeps matching `region_context.call_seq`; increment a new
`NativeResult.pushed_frames` counter; return a status word. On any
refusal: nothing mutated, status → the plain-exit path.
`onCallEntry`'s hasTrace/repatch body is NOT re-run (the callee's head
is the very trace we are inside; its patched image early-outs at the S1
opcode check anyway) — but its UNCONDITIONAL `tick +%= 1`, which runs
before that early-out on every successful tier-0 Lua entry and drives
cooldown expiry, MUST be replicated per successful push (round 5 change
1): factor a shared "successful Lua entry tick" primitive so the tick
stream stays a pure function of the call stream on every leg. Ordering:
tick only AFTER the push succeeds (failed calls never tick in tier-0
either).

**Piece 3 — real frames make every downstream event coherent.** This is
the structural payoff that justifies the callout cost. Because each
push creates a REAL activation
(frame/depth/stack_top/call_seq all live), every later event needs no
new machinery:
- a guard deopt at depth k flushes carried homes into the CURRENT
  window (the lane pointers shifted with the descent) and tier-0
  resumes at pc 0 of a real frame — the ordinary head-deopt contract;
- a D10 armed handoff mid-descent transfers within the CURRENT
  activation — untouched;
- a prologue-fail on the post-push re-entry (arg types changed at some
  depth) exits with its ordinary row; tier-0 resumes the pushed frame
  at pc 0 and the jfunc_head dispatch runs the leaf's own walk;
- errors raise only in tier-0 (native raises nothing), and the frames
  the descent pushed are exactly what `describeFault`/pcall unwind
  expects.

**Piece 4 — the dispatcher contract change (the one real ABI break).**
Today's episode invariant is "a native run never changes the VM frame
stack"; the descent breaks it, and BOTH consumers must branch on
`result.pushed_frames > 0` IMMEDIATELY after the native return — before
`driveDispatcherSilentResult`, before the scalar seed-decline handlers,
before the D10 `ledger_len > 1` consumer, and before every scalar head
consumer (round 5 change 3; a pushed-descent ledger can be `len == 1`
and every one of those would mis-act against the ENTRY activation):
- new `EntryDirective` variant `.resume_pushed_frame: usize` — both
  dispatch sites reload the top frame (`reloadTopFrame`) and dispatch
  at the given pc of the NEW frame;
- the pushed-descent terminal grammar is SIX-way (the post-push
  `ordinary_entry` re-runs both the seed and hoisted-type prologues):
  `head_terminal` → resume at `term.aux`; final `.deopt` (normal or
  full-cap `.yielded`) → resume at pc 0; `prologue_fail` → pc 0;
  `seed_capacity_decline` → pc 0; **`seed_hash_decline` → pc 0 as
  well** — it must NOT take the existing scalar tier-1a rerun, which
  would execute against the ENTRY activation's base/closure; the
  reloaded leaf's own jfunc_head walk makes the rerun/downgrade
  decision (round 5 change 3). In every case the jfunc_head arm then
  runs the LEAF's own walk — penalty, D8 want, D10 evidence all charge
  per-activation exactly as scalar entries do;
- round 5 change 4 — the pushed consumer is a SIBLING of
  `consumeHeadBurst`, sharing a factored row-validation/accounting
  core (owner resolution, head-anchor check, adjacency for armed
  transitions, per-row run + candidate charges,
  `noteHeadSiblingCompletion` on a genuine terminal), but NONE of the
  walk-local state: no `head_burst_visited` publication, no
  `head_walk_fail` pairing (rows cross activations), no
  `.next_candidate` (every disposition converts directly to
  `.resume_pushed_frame`), and the entry patch counts the episode
  productive (`strikes = 0` — the descent entered native and did real
  work regardless of how the leaf exited);
- the quiet predicate is UNCHANGED: pushes mutate no receipt state,
  and the quiet path routes `pushed_frames > 0` to the same consumer.

**Piece 5 — determinism, GC, and the polling question.** The P4 bullet
demands the push "poll safepoint/hook/replay natively or self-disable";
D11 satisfies it via the ALREADY-EXISTING observation-mode bypass, and
that phrasing supersedes the older Phase 4 bullet's wording (round 5
reconciliation note):
- replay/suspend/exec-log/safepoint-lines legs never reach a patched
  native entry (the §R1-5 bypass set) — the self-disable is already
  structural. `safepoint_seq` is INTENTIONALLY native-leg-specific: a
  per-instruction tier-0 counter that native execution already skips
  today for covered instructions; within-leg consistency is what
  replay cuts need (and those legs never go native), and cross-leg the
  gate pins output only — no cross-tier state identity is claimed
  (round 5 wording fix);
- the call_seq stream is identical across legs because the helper runs
  the real `pushFrameVararg` (Piece 2);
- GC: the descent runs up to `max_call_depth` (200) activations without
  a `shouldCollect` poll. This is strictly WITHIN existing precedent —
  a native loop trace already runs unbounded iterations (including
  doc-24 interning producers) with no mid-loop poll; collection happens
  at the next tier-0 boundary. Depth-bounded blackout, no new
  mechanism. If the loop precedent ever gains a native poll, the push
  joins it.

**Piece 6 — accounting v1.** `rbx` is deliberately untouched by pushes
(a `cum` bump would corrupt the D10 seg-local column and the head
zero-exit receipts); the episode still charges one receipt at its
terminal row. Consequence to carry openly: `--jit-stats`
iterations/entry undercounts descents (calls ≫ episodes), and
`hit_count` accrues per-episode, not per-call — both noted, neither
carries correctness weight; revisit only if trace selection misbehaves
on recursion-heavy anchors.

**Piece 7 — lowering mechanics (round 5 changes 5 and 7).**
- C-ABI protocol: at body entry `rdi/rsi/rdx` hold tags/payloads/
  `*NativeResult` and all three are caller-saved under SysV — the push
  epilogue must save and restore them around the callout before
  shifting `rdi/rsi` (the seed prologue's three-push preservation and
  the hash-cell callout's `rsp % 16 == 8` alignment correction are the
  in-tree precedents to copy verbatim).
- `NativeResult.pushed_frames` goes at the ABI TAIL, zero-initialized
  by the run wrappers; the frozen ledger field offsets must not move.
- Ledger publication: a SUCCESSFUL push appends NO row and publishes NO
  terminal result — only the eventual real exit produces the final row.
  A REFUSAL executes today's complete plain-terminal sequence unchanged
  (flush already done; `completed = rbx`, `exit_instr = terminal index`,
  `head_terminal` append, `final_trace_id` stamp, `shared_exit` jump) —
  which is exactly right in both worlds: with zero prior pushes the
  existing scalar terminal consumer sees today's bytes; with prior
  pushes the pushed consumer sees a `head_terminal` final row and
  resumes the reloaded frame at its `term.aux` (the refusing
  activation IS the top frame — tier-0 re-executes its call
  generically, raising any overflow error with intact frames).
  `emitLedgerAppend` capacity stays safe: an armed source at a full
  ledger force-yields before dispatching (the existing LEDGER_CAP
  branch), so descents cannot overflow the row arrays.

**v1 non-goals.** Inline-store lowering of the push (the callout is
~tens of cycles against the ~500-cycle turnstile it replaces; inlining
is later codegen tightening inside the same boundary — Z-7 compliant),
general non-self call pushes, down-recursion/returns (P3), RETF (P2),
`rbx`-per-push accounting, any GC poll inside the descent, per-row
activation identity in the ledger (the receiptsInert episode gate is
the v1 answer to cross-activation region accounting — see Piece 1).

**Tests.** Deep-recursion e2e: fib ten-leg (existing) must stay green
with descents active; `StackOverflow` at `max_call_depth` through a
native descent (error message + backtrace identical across legs — the
helper's refusal hands tier-0 the raise); pcall catching that overflow
with intact frames; a self-call whose argument type changes at depth
(prologue-fail mid-descent → leaf walk); a rebound-callee program (the
name `fib` reassigned mid-run → helper declines, generic call still
correct); GC-stress legs via the existing matrix. Unit: helper refusal
matrix (depth wall, capacity wall, non-function callee, foreign proto).

### D12 — the return side: evidence symmetry, continuation anchors, native pop

**Profile receipt (post-D11, fib(32), 19855df).** With the descent native,
what remains is (a) the per-node tier-0 return turnstile — opRet 8.0% +
opCall 11.3% + resume glue: after every subtree completes, the parent runs
`ret`-result-move / arith / the second `call` / its own `ret` entirely in
tier-0 — and (b) the per-subtree episode entry block ≈25% (enterSelectedTrace
11.5% + quiet 3.0% + driveDispatcherSilentResult 5.3% + consumePushedDescent
3.4% + nativeSeedFn 2.0%): every second call re-opens an episode, every
episode re-runs the seed prologue.

**Formation receipts (jit-debug, 2026-09-08, this section's defining
datum).** Which sibling records FIRST is a deterministic coin flip per input
(the D8 field note: whichever call is hot-call #112). The two outcomes are
NOT symmetric:

- *Lucky shape* (fib(22), fib(31); descender = t0 = incumbent): the leaf
  walk pairs evidence naturally (t0 zero-exit → t1 terminal in ONE walk),
  `noteSiblingTerminal` arms t0@exit5 → t1 at `hotguard`, and the steady
  state is ideal on the descent side — `pushed-descent terminal: rows=2
  final t=1 resume=5`: descend, bottom, armed handoff fires MID-DESCENT
  (the D11 Piece-3 claim, now observed), base case completes natively, one
  fused episode ending at the leaf's ret pc. Zero strikes.
- *Bad shape* (fib(27); base case = t0 = incumbent): **neither arming
  pathway can ever fire.** The entry walk's completion is a productive
  DESCENT (`pushed_frames > 0`, final row a deopt) — `consumePushedDescent`
  deliberately runs none of the walk-local evidence machinery, so the
  t0-zero-exit evidence dangles and t0→t1 never arms. And the descent's
  bottom deopt (t1@5, in the LEAF activation) is never carried into the
  leaf's walk — `enterPatchedTrace` resets `head_walk_fail` at walk start —
  so t1→t0 never arms either. Steady state: 196,391 legacy strikes on
  196,381 descents (one penalty insert + productive remove per LEAF,
  forever), t0 zero-exit + full-path episode + t1 descent episode + leaf
  walk episode per call. `--dump-aborts` clean; both traces healthy; purely
  an evidence starvation.

The board's fib(31) got the lucky shape, so 263.5 ms already includes the
fused descent. The 35× residue is therefore: the return turnstile, the
episode-entry block, and the formation coin flip as a robustness landmine.
Three slices.

**D12a — descent-symmetric handoff evidence (the leaf-exit contract).**
Two additions, both pure functions of the walk/descent event stream
(D7-narrow determinism):

- *A1, productive-descent completion — ONE exact evidence funnel (round 6
  change 5).* The arm's semantic claim is "when X zero-fails at exit E,
  this sibling handles the call productively" — a descent that pushed real
  frames IS productive handling; requiring a terminal conflates
  "productive" with "completed without deopt". But the completing IDENTITY
  must be the trace the walk actually selected after the failure — `ct`,
  the entered trace — NOT the final ledger row's owner (an armed handoff
  can make the final owner a different sibling, and
  `noteHeadSiblingCompletion` deliberately keeps a want alive when the
  completer equals its source). And the existing `head_terminal` branch
  already fires completion — a naive second call would double-fire with a
  potentially different id. Design: capture
  `productive_handler_id = ct.id` at the top of `consumePushedDescent`
  and run one post-disposition funnel exactly once per consumed descent —
  consume `head_walk_fail` against it, retire a standing head want
  against it — with the genuine `head_terminal` receipt/accounting kept
  separate and unchanged.
- *A2, descent-bottom failer carry.* The descent's final deopt happened IN
  the leaf activation (the D11 deopt contract flushes into the CURRENT
  window), so it is legitimate walk-local evidence FOR the leaf's own
  walk — the reset-at-walk-start rule was about *stale cross-activation*
  evidence, which this is not. Carry: `consumePushedDescent` records
  `pending_descent_fail = {trace_id, exit_instr, call_seq}` ONLY for the
  final `.deopt`+`.normal` disposition with a valid real-guard exit
  (round 6 change 5: never for `.yielded`, prologue-fail, or seed
  declines — those carry no branch-alternative meaning); the jfunc_head
  walk start consumes it into `head_walk_fail` iff the top frame's
  `call_seq` matches (else discards — the activation died). One carry
  slot, overwritten by later descents, cleared on consume-or-mismatch AND
  on unwind/reset/cache-reset paths (the same lifecycle set that clears
  `head_walk_fail`); never crosses an activation by construction.

Result: both directions arm regardless of formation order, and the bad
shape converges to the SAME fused steady state as the lucky one (roles
swapped): entry → armed handoff → descend → bottom → armed handoff → base
case → one episode. The per-leaf penalty churn disappears with the scalar
zero-exits (fused rows charge via `accountHeadIntermediateRow`, which never
touches the legacy thrash half). Expected board: fib(31)/btrees unchanged
or slightly better; the win is eliminating the coin flip — pin the bad
shape in a test, not the board.

**D12b — continuation anchors (post-call resume traces).** The return-side
coverage gap in mahina terms: after `opRet` copies results and pops, it
tail-dispatches the caller at the frozen one-past-call cursor **through the
caller's doc-20 image with a full prologue** (interp.zig `opRet` → 
`reloadTopFrame` → `dispatchTail`, T-3). That pc is a legitimate one-shot
root anchor, and everything a root needs already exists there:

- *Identity (D1 discipline, hardened — round 6 change 2).*
  `CONT_PC_BIT = 1 << 31`; anchor pc `CONT_PC_BIT | resume_pc`;
  `FUNC_HEAD_PC = maxInt` stays distinct. The encoding is only sound with
  its boundary made a CONTRACT, not an assumption: (a) the compiler
  hard-fails any proto whose code length reaches `1 << 31` (today nothing
  bounds it — compiler.zig appends unbounded), which also excludes
  `resume_pc == 0x7fffffff` (would alias `FUNC_HEAD_PC`); (b) ALL
  encode/decode goes through two helpers, `anchorKind(pc)` /
  `entryPc(pc)` — no raw bit tests at use sites; (c) the D1 audit is a
  grep-driven sweep of EVERY direct `anchor.pc` comparison against
  executable pcs, not just the five D1 sites — round 6 named five more
  (recording closure trace.zig:2919, back-edge closure :2934, while
  recognition trace_recorder.zig:2318, numeric-for :2458, while-link
  :2751) and the implementation gate is the full grep, each site either
  proven kind-safe or routed through the helpers. (A typed
  `AnchorKey.kind` field is the recorded alternative; the encoding is
  chosen for map-layout stability with the boundary contract above.)
- *Counting.* In the `opRet` resume path only (the `stop_depth` boundary
  return exits `execImpl` and naturally never counts): bump the same
  `counters` map at the cont key, threshold `hotcall` (shared — returns
  into a site are calls of its continuation). Not the back-edge hotcount
  array; same discipline as `onCallEntry`. Gated by `recordingBarred` and
  `hasTrace` exactly as the head counter is.
- *Recording — with the `.fast` parking rule (round 6 change 1).* At
  threshold, `pending_ret_anchor` (a `pending_call_anchor` twin pinned to
  the CALLER's `call_seq`/base), consumed by a `maybeStartCont` in the
  `.full` prologue. Pending consumers exist ONLY in `.full`; `opRet`
  tail-dispatches in the current mode — so the counting funnel reports
  "armed" and `opRet`, in `.fast`, parks `frame.pc` at the resume pc and
  returns `.switch_mode` (the exact opCall precedent at interp.zig:5168);
  the pending also joins every bypass/reset/unwind cleanup set
  `pending_call_anchor` is in, and is processed before the recording
  mirror. Recording kind `.cont` inherits D4 wholesale (root snapshot at
  the resume pc, seeded SSA, same abort policies) and the D5 terminal
  grammar verbatim: depth-0 `ret` → `.terminal(return_interp)`, direct
  self-call of the caller's own proto → `.terminal(self_call_interp)`. A
  loop back-edge met while recording a `.cont` root aborts (new reason
  `.cont_backedge`) — loops have their own anchor machinery; v1 keeps
  cont shapes straight-line-to-terminal.
- *Entry.* First-class patch kind `jcont` at the resume pc (D6 shape:
  entry-registry slot in the operand, mirror canonicalization, pending
  processed before mirroring, unpatch recovery). Entered from `opRet`'s
  dispatchTail like any patched op — and from straight-line flow into the
  same pc, which is free extra coverage (the trace guards its own entry
  types). **Physical-pc collision rule (round 6 change 3): the entry
  registry holds ONE patch per physical pc, and a resume pc can itself be
  a patchable loop site — v1 REFUSES cont formation (no counting, no
  recording, no patch) at any physical pc that is already patched or is a
  patchable loop-anchor site, documented and tested; a multiplexed entry
  opcode dispatching several logical anchors at one physical pc is the
  recorded durable follow-up.** Episode consumers: cont anchors join the
  head family as "one-shot roots" — but round 6 change 4: one-shot is a
  BEHAVIOR class, never an identity equivalence. A proto now has many
  one-shot anchors, so the walk, patch retention, want state, row-owner
  resolution, and adjacency validation are parameterized by the EXACT
  `AnchorKey` (a factored `OneShotWalkCtx` carrying it), replacing today's
  hard-coded `FUNC_HEAD_PC` in sibling selection (interp.zig:4092),
  retention counting (:4158), and proto+is-head row validation (:2846) —
  a fused row from cont-anchor A must never validate against an entry at
  cont-anchor B.
- *v1 non-goals.* No D11 push from cont pages (their self-call terminal
  exits plain until D12c links land — the push's `jmp body_entry` targets
  its OWN page, which is wrong for a cont page); no `all_results` /
  vararg-caller shapes (recorder refuses, P0 grammar); no pcall-boundary
  counting (structurally excluded above).

Expected board: ≈flat alone (the glue it covers is small and each cont
entry pays the episode toll D12c removes). This slice is judged on
formation receipts (`--jit-stats` residency + cont-trace counts), not
wall-clock — doc 31 D3 rule, stated here so a flat board doesn't read as
failure.

**D12c — native frame pop + return links (down-recursion, the payoff).**
Symmetric twin of D11, closing the cycle so the whole recursion tree runs
as ONE native episode chain (LuaJIT's FUNCF root + DOWNREC + patched side
exits, expressed as one-shot roots + armed cross-page links over real
frames):

- *The pop.* `.terminal(return_interp)` gets a NATIVE-LOWERING-ONLY pop
  epilogue (recording and tier-1a legs byte-identical, the D11 rule):
  flush → C-ABI callout `nativeSelfRetPop` → on POP_OK bump
  `NativeResult.popped_frames`, shift lanes DOWN by `nreg` (compile-time —
  see the invariant below), refresh episode ctx to the caller activation,
  then the link dispatch. Refusal falls through to today's plain terminal
  bytes.
- *The invariant that keeps v1 closed.* An episode may only pop frames IT
  pushed: the helper refuses at net `pushed - popped == 0` (the episode
  entry frame's own return stays tier-0). Round 6 change 7: the current
  push-helper ABI carries no frame-motion counters, so the floor must be
  made explicit in the ABI — the helper takes the `*NativeResult` (or the
  episode's immutable entry depth stashed in the seed ctx at
  `prepareNativeEpisode`) and derives net from it; "refuse at net 0" is
  otherwise unimplementable. Every episode-pushed frame is a same-proto
  self-call frame (D11), so the popped-into frame is same-proto and the
  lane shift is the compile-time `nreg` — exactly the push's mirror. Net
  ≥ 0 always; the dispatcher's frame-motion branch (`pushed_frames > 0`
  generalizes to `pushed != 0 or popped != 0`; the directive renamed
  `.resume_frame_motion`) reloads the top frame generically, so
  intermediate net states need no new directive shape.
- *The helper is `opRet` verbatim minus what it refuses — full preflight
  BEFORE any mutation (round 6 changes 6+7).* Fail-closed; the complete
  contract, checked in order with nothing written until all pass:
  `depth > 1` and net > 0; top frame matches `ctx.base`/`ctx.call_seq`
  and its proto is `ct.anchor.proto`; parent frame exists with the same
  proto; exact window adjacency `callee.base == parent.base +
  proto.num_registers` (the push laid it out; verify anyway — distant
  invariant); `terminal.aux` in bounds naming a `.ret` with
  `b != all_results`; the popped frame's STORED return-wiring
  (`ret_count`/`ret_dest` from the frame struct, never a re-decode) not
  `all_results`, source range within the callee window, `ret_dest + want`
  within the parent window; no pending dynamic multret state
  (`!reg_top_pending`); **no open upvalue anywhere in the open-upvalue
  list with `index >= popped base` — a FULL read-only scan; the list is
  append-discovery-ordered and `swapRemove`-compacted (interp.zig:6222,
  :6256), so no single-compare shortcut exists** (decline hands tier-0
  the `closeUpvaluesFrom`; the P2 "modeled upvalue close" stays out, and
  the v1 helper never mutates cells); `receiptsInert` shared with the
  push (same episode gate). Only then: result copy WHILE the callee
  window is still under `stack_top` (opRet's rooting order,
  interp.zig:5332), `dropRegionActivation`, `depth -= 1`, `stack_top`
  shrink, ctx refresh. No tick (tier-0 `opRet` does not tick — the tick
  stream stays a pure function of the CALL stream on every leg).
- *Return links.* After a pop, the resume pc is the caller's frozen cursor
  — dynamic per pop (fib returns into after-call-1 OR after-call-2). The
  epilogue gets K = 4 patchable link slots (new kind `.ret_cont`): each
  armed slot bakes (resume-pc const → cont page `ordinary_entry`);
  compare-chain, miss → plain exit with the frame-motion directive
  (tier-0 dispatches the resume pc, hits `jcont`, ordinary episode —
  still one `opRet` cheaper than today). Round 6 (Z-7 note + change 8):
  the K slots are NOT a side table — they extend the physical-link
  registry (`armNativeLink`/disarm/invalidation blast radius, ledger
  ownership) with a kind whose slot key is a RESUME PC rather than an IR
  exit index; the `arm()` funnel's head-parent validation (today
  `.sibling_handoff`-only, trace_link.zig:1245) gets the two new kinds as
  first-class branches. Slot allocation is deterministic (first K
  distinct resume pcs to reach the arm threshold; no eviction in v1 — a
  fifth pc stays unlinked and exits plain, logged by the no-silent-caps
  rule). Arming: deterministic hotguard-style counter on (returning page,
  resume pc) → pending arm consumed when the dispatcher actually enters
  the cont page (the `tryArmSiblingHandoff` shape); disarm rides the
  existing physical-registry lifecycle.
- *Cont-page self-call links.* The same armed-link mechanism gives cont
  pages their push: `.terminal(self_call_interp)` on a cont page runs the
  D11 push helper, then jumps through an armed `.call_head` link to the
  anchor proto's HEAD page `ordinary_entry` (cross-page descent). Unarmed:
  push, then exit with the pushed-frame directive (leaf's jfunc_head walk
  enters the head page as its own episode — correct, one seam, arms away).
- *Ledger grammar (round 6 change 8 — defined here, not inherited).* The
  D10 validator accepts only `.deopt`-with-armed-`sibling_handoff`
  intermediates; frame motion needs its own rows. Two new `LedgerKind`s:
  `.ret_pop` (a committed native pop that then took a `.ret_cont` link)
  and `.call_push` (a committed cont-page push that took a `.call_head`
  link) — each row carries the owner page and the transition target, is
  validated per-kind against the LIVE registry (an armed `.ret_cont` /
  `.call_head` must exist from that owner to that target, the adjacency
  rule D10 established), and charges `accountTraceRun` +
  `accountCandidateCharge(.entered)` like other intermediates. A pop or
  push whose link MISSES appends no transition row — it terminates the
  episode with the ordinary final row (`head_terminal` for the terminal
  grammar, `.deopt` shapes otherwise) plus the frame-motion counters, and
  the dispatcher derives the resume target from the FINAL top frame +
  final row exactly as `consumePushedDescent` does today (generalized to
  net motion; `.yielded` cut mid-chain resumes the current top frame at
  the final row's pc).
- *Blackout bound (round 6 change 9 — stated honestly).* Same-page D11
  pushes deliberately append NO row, so LEDGER_CAP alone does not bound
  the blackout: the bound is `max_call_depth + LEDGER_CAP` segments (a
  descent can push up to depth-wall frames row-free before the first
  transition row; every cross-page transition then consumes ledger
  capacity, and the existing full-cap branch force-yields). Both terms
  are deterministic constants; GC stays at tier-0 boundaries within that
  bound — the native-loop precedent, now with an explicit two-term bound.
  Per-push rows (or a native poll budget) are the recorded follow-up if
  GC latency ever demands a tighter bound.
- *What the chain buys.* Steady-state fib: head page descends (pushes),
  base case via armed sibling handoff, pop via `.ret_cont` into cont-1,
  cont-1 pushes via `.call_head` back into the head page, …, pops chain
  through cont-2 up the tree — tier-0 touched once per LEDGER_CAP rows.
  The episode-entry block (~25%) amortizes across the cap; opRet/opCall
  and the per-call seed prologue leave the profile for covered shapes.

**Implementation clarification (D12c).** A committed push/pop miss uses a
final `.call_push`/`.ret_pop` row rather than pretending the unexecuted terminal
still belongs to the new top frame. Intermediate rows of those kinds require
a live matching link; final rows resume the actual top frame (pc0 after push,
frozen caller cursor after pop), including full-cap cuts. Return keys and
bounded hot watches retain the first four observed PCs for the page lifetime;
disarm clears targets, not keys. This differs from the proposed first-four-to-
threshold ordering above, keeping hot-path evidence allocation-free. Saturated
miss observations retry arming deterministically, and capacity refusal logs
through jitdbg. The observer-only cap-yield counter pins that tests exercise
mixed-chain cuts, not merely output-equivalent unlinked episodes.

**Determinism, GC, replay (whole section).** The §R1-5 bypass set is
untouched — replay/suspend/exec-log/safepoint legs never reach a patched
native entry, so every new native seam self-disables there structurally.
`call_seq` streams stay identical across legs because push and pop both run
the real frame funnel (`pushFrameVararg` / the opRet-verbatim pop). All
arming counters are pure functions of deterministic event streams; links
move WHERE code runs, never what it computes — hashgate (84 × 2) is the
gate, per phase, as always.

**Tests (per slice).** D12a: bad-shape formation e2e (fib(27)-shape pinned
via a hotcall-tuned harness or the witness counters: assert BOTH handoff
directions arm and legacy strikes stay O(warmup), not O(leaves)); ten-leg
matrix stays green. D12b: cont-trace formation on fib + on a non-recursive
hot call site (generality pin); jcont patch/unpatch/mirror recovery;
`.fast`-mode arming (the parking rule); the physical-pc collision refusal
(a resume pc that is a patched/patchable loop site must form NO cont
anchor); abort matrix (`.cont_backedge`, vararg caller, `all_results`).
D12c: pop-refusal matrix (net-zero floor, open upvalue at depth — the
full-scan case with an older frame's cell first in the list, `all_results`
wiring, aux bounds, window-adjacency violation); deep-unwind ten-leg pins;
StackOverflow + pcall through fused chains; type-change at depth
(prologue-fail on a linked cont entry); GC-stress legs; LEDGER_CAP
force-yield mid-chain (round 6: mandatory gates, all of these).

## 5. Phasing

P0 is the coverage milestone and is deliberately self-contained (both
terminals, the full exit contract, entry patching). P1 hardens recursion
ergonomics. P2–P4 change the execution/frame ABI and stay separate —
P2 likely graduates to its own doc. Each phase: ten-leg tests +
`just test` + hashgate + wasm + viz, checklist tick, fib/binary-trees
board delta, commit.

## 6. Review ledger

**Round 1 (codex gpt-5.6-sol, 2026-09-08): sound-with-changes; 8 required
changes, all folded in above.** (1) typed anchor / entry-pc separation +
exclusion list + format_version bump → D1, D7. (2) first-class patch kind
+ mirror + prologue ordering → D6, D3. (3) terminal-exit contract distinct
from side exits → D5. (4) terminal materialization / C1 / no-loop-φ
finalization / `all_results` refusal → D4, D5. (5) `.terminal` as one
parameterized op; `.uprec` reframed as staged analogue → D5, §2.3.
(6) self-call terminal moved into P0 (fib's `fib(n-2)`-first shape) +
root-like audit → D4, P0. (7) hot-call lifecycle (call_seq pin, clearing,
tick advance — the doc's "leaning no" was unsafe) + narrow determinism →
D2, D3, D7. (8) P2 scope expanded (two-frame ABI, upvalue close,
protected frames) and flagged for its own doc → P2. Noted risks adopted:
function-entry snapshot (D3), stack-overflow guard (D4), vararg refusal
(D2), Phase-4 hook/safepoint polling (P4 bullet), open-upvalue bar on P2.

**Round 2 (codex gpt-5.6-sol, 2026-09-08, D8 only): sound-with-changes; 7
required changes, all folded into D8.** (1) head patch retention below
sibling capacity (`patch_strikes=4 < hotexit=10` would retire the sole
entry before hotness). (2) want consumption on the CURRENT activation
(the `consumeSideTraceWantAtResume` analogue) instead of delayed
`onCallEntry` arming — kills stale-want/duplicate-shape/cross-proto
blocking wholesale. (3) DONE-latch the want's source exit on sibling
completion. (4) recovery routes for every other unpatch source
(gateAnchor, strikes-at-capacity, incumbent retirement) via idempotent
re-install from `onCallEntry`. (5) walk truncation at `trial_visited_cap`
never strikes. (6) selection order is `nextTraceExcluding`'s hit-count
order, not registry order. (7) caller-owned dead removal across the whole
walk. Z-6 reinforcement: framed as path-polymorphic head specialization
with a non-recursive two-path test.

**Round 3 (codex gpt-5.6-sol, 2026-09-08, D9 only): sound-with-changes; 5
required changes, all folded into D9.** (1) predicate gains
`config.native_codegen` (`.compiled` ≠ "config would run it"). (2)
`hasNativeLoopDoneLink` gets the D1 head check itself (it scans logical
continuations + memoizes, independent of `armedLinks`; a head with a
coincident exit-pc link terminal could select linked entry mode — latent
bug, fixed for both paths). (3) `applyPendingDisarms`'s unconditional
`debug_log` sync → predicate bit (`native_physical.debug_log ==
config.debug_log`); jit-debug receipts kept in the quiet path. (4) S1
keeps tick/enabled/rec/vararg order, bounds-checks `img`, and only the
patched steady state loses the hashes. (5) S4: `?u64` gen (image_gen is
u64, gen 0 valid, empty images cacheable), push-time invalidation, one
shared validate/refill helper. Confirmed sound: the skip-claim audit for
every other call, grammar completeness, active-plan-bits `has_hash_seed`
airtightness, D8 walk symmetry (a post-zero-exit sibling correctly goes
non-quiet — the penalty insert ends quietness by design).

**Round 4 (codex gpt-5.6-sol, 2026-09-08, D10 only): sound-with-changes;
5 required changes, all folded into D10.** (1) fused grammar expanded to
the decline terminals (`prologue_fail`, `seed_capacity_decline`) with
`seed_hash_decline` excluded at ARM time (refuse hash-seeded head
children). (2) factual correction: an unhandled fused head ledger is
silently mis-consumed by the scalar consumers, not a panic — the burst
consumer keys on `ledger_len > 1` BEFORE them; the replayLedger `@panic`
arms stay as backstop. (3) release-mode ledger validation (owner
resolution, head-anchor match, kind/reason/outcome, registry adjacency
via `hasArmedSiblingHandoff`, `.yielded` only at full cap) + deduped
`visited` merging. (4) intermediate rows also charge
`accountCandidateCharge(.entered)` (refusal-streak reset —
`accountTraceRun` alone does not). (5) walk-local `head_walk_fail`
evidence channel with explicit set/survive/consume rules + head
eligibility requires non-inlined `.branch_cond` provenance + the central
arm validator rejects head parents for every non-`sibling_handoff` kind.
Confirmed sound: physical stub fit (pre-effect carried-home flush is
entry-identical for heads; no loop-pc assumption; cap yields cleanly),
quiet-v2 safety inventory, accounting rationale (suppressed intermediate
zero receipts; last-failed sibling still raises wants), P-E lifecycle
composition.

**Round 5 (codex gpt-5.6-sol, 2026-09-08, D11 only): sound-with-changes;
7 required changes, all folded into D11.** (1) `onCallEntry`'s
unconditional `tick +%= 1` (pre-early-out, drives cooldown expiry) must
be replicated per successful push — factor a shared successful-entry
tick primitive, tick only after the push. (2) descents require
`receiptsInert()` (episode-level): rows are consumed against the LEAF's
region context but can originate in ancestor activations —
`pushed_frames` cannot re-pair them; per-row activation identity is the
recorded non-goal alternative. (3) the pushed branch runs IMMEDIATELY
after the native return (before silent-result, scalar seed-decline, D10
burst, scalar head consumers) and the terminal grammar is six-way —
both seed declines resume the reloaded leaf at pc 0; `seed_hash_decline`
must NOT take the entry-activation tier-1a rerun. (4) the pushed
consumer shares a factored validation/accounting core with
`consumeHeadBurst` but none of its walk-local state (no burst-visited,
no `head_walk_fail`, no `.next_candidate`). (5) ABI: save/restore
`rdi/rsi/rdx` around the callout (SysV caller-saved), hash-callout
alignment protocol, `pushed_frames` at the ABI tail with frozen ledger
offsets untouched. (6) the helper re-verifies the distant record-time
invariants pre-mutation (`terminal.aux` bounds + `.call`, `b !=
all_results`, non-vararg anchor, `!reg_top_pending`). (7) successful
push appends no row; refusal runs today's full plain-terminal sequence
(correct for both the zero-push scalar consumer and the pushed
consumer). Confirmed sound: same-proto/different-upvalue closures (push
the actual closure, no identity pin), rebound/`__call` decline paths,
terminal-flush sufficiency for fixed-arg calls, real-frame
unwind/backtrace/pcall coherence, the no-GC-poll argument (within the
native-loop precedent), `instr.c == all_results` return wiring.
Wording fixes: `safepoint_seq` is intentionally native-leg-specific;
the D11 bypass-based self-disable supersedes the older P4 bullet's
polling phrasing.

**Round 6 (codex gpt-5.6-sol, 2026-09-08, D12 only): sound-with-changes;
9 required changes, all folded into D12.** (1) `pending_ret_anchor`
raised under `.fast` must park and `.switch_mode` (pending consumers are
`.full`-only; the opCall precedent at interp.zig:5168), plus join every
bypass/reset/unwind cleanup set. (2) `CONT_PC_BIT` is only sound as a
CONTRACT: compiler hard-limit on proto code length (`< 1 << 31`, which
also excludes the `FUNC_HEAD_PC` alias at `resume_pc == 0x7fffffff`),
centralized `anchorKind`/`entryPc` decoding, and a grep-driven audit of
ALL direct `anchor.pc` comparisons (round 6 named five beyond the D1
five: trace.zig:2919/:2934, trace_recorder.zig:2318/:2458/:2751); typed
`AnchorKey.kind` recorded as the alternative. (3) one patch per physical
pc — a resume pc can be a patchable loop site; v1 refuses cont formation
there (documented + tested); multiplexed entry opcode is the durable
follow-up. (4) "one-shot" is a behavior class, never an identity
equivalence: walk/retention/want/row-owner/adjacency must be
parameterized by the exact `AnchorKey` (`OneShotWalkCtx`), replacing
hard-coded `FUNC_HEAD_PC` at interp.zig:4092/:4158/:2846. (5) D12a needs
ONE evidence funnel keyed on `productive_handler_id = ct.id` (the
ENTERED trace, not the final row owner — armed handoffs diverge them;
the `head_terminal` branch already fires completion, a second call
double-fires); A2 carry only for `.deopt`+`.normal` real-guard bottoms,
cleared on the full `head_walk_fail` lifecycle set. (6) the open-upvalue
check must be a FULL read-only list scan (append-ordered +
`swapRemove`-compacted, interp.zig:6222/:6256 — no head-compare
shortcut; a stale first element hides a capturing later one → popped
cell would point above `stack_top`, unrooted). (7) the pop helper's
preflight contract enumerated in full (frame/ctx/proto identity, window
adjacency, wiring bounds, `reg_top_pending`, floor made explicit in the
ABI — the push ABI carries no frame-motion counters today), all checks
before any mutation, result copy under `stack_top` (opRet rooting
order, interp.zig:5332). (8) the D12c ledger grammar defined, not
inherited: new `.ret_pop`/`.call_push` row kinds with per-kind
live-registry adjacency, link slots extend the physical-link registry
(never a side table — the Z-7 risk codex flagged), deterministic K-slot
allocation with the no-silent-caps log, `.resume_pushed_frame` →
`.resume_frame_motion` with reload whenever either counter is nonzero.
(9) the blackout bound stated honestly as `max_call_depth + LEDGER_CAP`
(same-page D11 pushes append no row); per-push rows / native poll budget
recorded as the follow-up if GC latency demands tighter. Confirmed
sound: D12b is not scaffolding (counter, identity, kind, patch all
consumed by D12c); staged push-disable on cont pages; Z-6 generality
(cont anchors cover arbitrary hot call resumptions; the non-recursive
witness test is important); error/pcall coherence via the entry-frame
floor + non-throwing helper.

## References

- LuaJIT: `lj_record.c` (rec_call/rec_ret/check_call_unroll/
  check_downrec_unroll/rec_func_lua §2 cites), `lj_dispatch.c:440-510`,
  `lj_dispatch.h:74-79`, `lj_trace.c:770-800` + `trace_stop`.
- mahina machinery map 2026-09-08: `trace_types.zig:319`,
  `trace.zig:163/673-696/2826-2934`, `trace_code.zig:284`,
  `trace_chain.zig:264`, `trace_link.zig:208-245/500/1548-1674`,
  `trace_entry_registry.zig:75-166`,
  `trace_recorder.zig:802-807/2730/2794-2884/4639`,
  `interp.zig:1706/2425-2515/3361/3902-3908/4249-4493/4575-4855/6049`,
  `compiler.zig:1188-1198`, `traceser.zig:30/86`.
- Board: `bench/results/20260908-075259-e0c3b3e.tsv`.
