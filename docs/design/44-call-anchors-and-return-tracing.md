# 44 — call anchors and return tracing (making recursion trace at all)

Status: partial — P0 recording + tier-1a entry/execution landed (fib re-enters
through the patched head, res% 30.6%); native `.terminal` lowering and P1+
outstanding. Codex-reviewed (gpt-5.6-sol, verdict sound-with-changes; all 8
required changes folded in, ledger at bottom)
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

### Outstanding

- [ ] **Phase 0 — remaining: native `.terminal` lowering.** Tier-1a head
      entry costs ~420 cycles/hop on a 9-op fib body, so `--trace` is
      currently 3.3× SLOWER than tier-0 on recursive-fib (residency without
      speed). Lower `.terminal` as the loop-done-snapshot twin: φ one-shot
      writeback flush + a terminal exit stub reporting the terminal's
      instruction index; lift the `nativeFor` loop/link-only terminal gate
      and add the proveKinds arm.
- [ ] **Phase 0 — the minimum viable function-entry tracing milestone.**
      Hot-call counting (advancing the gate tick), typed head anchors,
      `pending_call_anchor` arming (carrying `call_seq`, cleared on every
      unwind/abort path), recorder kind `.head` (root-like in every
      root-only policy) closing at BOTH depth-0 terminators — `ret` AND
      direct self-call — via the parameterized `.terminal` IR op; the
      terminal-exit contract (distinct from side exits); function-entry
      deopt snapshot; vararg protos refused; recorder stack-depth guard for
      inlined calls; tier-1a + native execution; entry via the `jfunc_head`
      patch kind; `traceser.format_version` bump. Exit target:
      recursive-fib records a non-base trace and re-enters through the
      patched head (res% > 0 from 0).
- [ ] **Phase 1 — recursion ergonomics.** Bounded recursive unrolling
      (`recunroll` budget for depth>0 self-calls), base-vs-non-base side
      traces off the branch guard, lifecycle hardening under the abort/GC/
      error matrix, binary-trees receipts.
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
