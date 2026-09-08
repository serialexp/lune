# 44 — call anchors and return tracing (making recursion trace at all)

Status: partial — P0 complete, P1a (D8 head siblings), P1b (D9 quiet head
episode + S1/S2/S4), and P4 slice 1 (D10 head-sibling exit-branch patching)
landed; fib jit 317 ms / binary-trees ~368 ms with 100% head coverage. The
remaining fib gap is the per-call episode turnstile itself — P4's native
frame push (true up-recursion) owns it.
Codex-reviewed ×4 (gpt-5.6-sol, all sound-with-changes, every required change
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
- [ ] **Phase 2 — RETF return tracing (expanded scope — likely its own
      doc).** Record *through* a depth-0 `ret` into the caller: needs a
      two-frame execution ABI (slab+base addressing, not one RegWindow),
      guards on frame kind/return pc/caller proto/activation identity,
      multi-result top state, modeled upvalue close before the pop, and an
      explicit bar on protected/host/stop-depth frames. Decide at P1 close
      whether it stays in this arc.
- [ ] **Phase 3 — down-recursion.** Return-anchored traces (LuaJIT patches
      `JLOOP` over a hot `RET`) so the unwind phase runs traced.
- [ ] **Phase 4 — de-seam the recursion links.** Native frame push for the
      self-call terminal (true up-recursion), then exit-branch patching.
      MUST either include safepoint/hook/replay polling in the native
      frame-push path or self-disable whenever those facilities are active
      (the tier-0 prologue services they'd otherwise skip). Done when the
      seam is off the fib/binary-trees profile.
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
