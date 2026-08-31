# Nested-Loop Trace Linking — Design

Status: done — Phases 1–4 landed (exit-PC anchors + `.link` tier-1a/native execution)
Owner: Bart
Last updated: 2026-07-08

The tracing JIT cannot trace **nested numeric-`for` loops**. An outer loop that
contains an inner loop never tiers up: the recorder aborts at the inner loop's
`for_prep` (`else => self.abort(.nyi_opcode)`, `trace.zig`), so the whole nest
runs on the tier-0 interpreter. This is a structural JIT-**coverage** gap (not
codegen tightness) and a measurable slice of the remaining LuaJIT gap on nsieve
(the middle/clear-loop nest) and `grid_matmul` (~18% tier-0 at last profile).

This doc is the contract for closing that gap the way LuaJIT does — **trace
linking**, not loop unrolling — and the home for the determinism **proof
obligations** the phases must discharge to stay byte-identical across the 10-mode
matrix.

## Implementation status

Tracking the gap between this design and what's on `master`. Tick items as they
land; move whole sections to Done once everything inside is checked.

### Done

- [x] **Phase 0 — Design doc.** This doc: LuaJIT model verified against
  `~/Projects/LuaJIT/src/lj_record.c`, mahina mapping, proof obligations P1/P2/P4.
- [x] **Foundational (pre-existing, kept).** The `for_prep` LINNER abort already
  matches LuaJIT's root-trace-hits-inner-loop behaviour and is retained, not
  removed (see §The mechanism, step 1).
- [x] **Phase 1 — Non-header (exit-PC) anchors.** `TraceState.pending_exit_anchor`
  + `maybeArmContinuation` (on a productive inner loop-done exit) +
  `maybeStartContinuation` (a `.full`-mode dispatch-prologue activation hook that
  seeds `reg_map` lazily from the live registers at the post-loop pc via
  `refOf`/`slot_load`). The productive-exit tail flips `.fast`→`.full`
  (`switch_mode`) so the inner loop's final-iteration deopt-replay reaches the
  post-loop pc with the hook live. The continuation records the outer body forward
  and re-reaches the inner `for_prep`, where it **aborts (LINNER)** — there is no
  "close with `.loop`" in a real 2-level nest (the recording always reaches the
  inner prep before returning to its own anchor); that abort site is exactly where
  Phase 2's `.link` goes. Native arming was deferred to Phase 4, which added
  native exit identity. Discharged **P1**: pinned by
  an `expectProgram` 10-mode output-invariance test plus a focused
  `runExecForTrace` test asserting a second, distinct `for_prep` abort site (the
  continuation, anchored at the post-loop pc) actually arms.
- [x] **Phase 2 — Link terminator + snapshot hand-off.** New `.link` IR terminator
  (`trace.IrOp`, wire ordinal 56 — appended at the enum end, mirrored in
  `traceser.zig`'s ordinal contract and `viz/src/enums.ts`). `assertWellFormed`
  accepts `.loop` **or** `.link` as the sole terminal; `commit` appends
  `.link{aux = inner anchor pc}` when `Recorder.link_target` is set and caches the
  trace **unoptimized** (`tropt` is skipped — its LICM/φ machinery and the
  `instrs[n-1].op == .loop` assert are written for back-edge loops; Phase 3
  executes the unoptimized straight-line continuation). `recForPrepLink`
  (dispatched from the `.for_prep` recording arm) reconstructs the inner root's entry state
  (`R[a] = init`, visible var `R[a+3] = init`, plus a first-iteration bounds guard)
  and closes with the link **iff** (a) this recording is a *continuation*
  (`Recorder.is_continuation`, set only by `maybeStartContinuation`) — a *root*
  recording that reaches an inner `for_prep` still LINNER-aborts, matching LuaJIT
  and keeping link anchors off real back-edge targets — and (b) the inner loop
  header (the `for_loop` back-edge target == `for_prep`'s post-increment pc) already
  has a cached root trace; otherwise it LINNER-aborts unchanged. Discharged **P2**
  (corrected after empirically dumping the inner root's `entry_slots` — see the P2
  section below): the hand-off reproduces the inner root's *entry state*, which
  (because the root anchors at the loop **body start**, reached only after `for_prep`
  **and** the first `for_loop`) is `R[a] = init` **and** the visible loop var
  `R[a+3] = init` — both live entry inputs — not `R[a] = init − step`. A
  first-iteration bounds guard (`init` within `limit`) gates the link so a zero-trip
  inner loop falls back to tier-0. The link trace is committed but was inert in
  Phase 2, so output stayed byte-identical (pinned by the `expectProgram` matrix
  plus a focused test asserting a `.link`-terminated trace is cached whose `aux`
  resolves to a cached `.loop` root).
- [x] **Phase 3 — Linked execution, tier-1a.** Productive inner loop-done exits now
  route through `tryChainExit` after committing the final numeric-for iteration's
  linked hand-off state (sunk stores + slot-bound φs, with the visible loop var
  left at tier-0's last in-bounds value). `irinterp.execute` flushes a `.link`
  trace's φ snapshot before returning the link exit; `tryChainExit` follows that
  link to the cached `.loop` inner root and ping-pongs continuation ⇄ inner root
  with the existing 8-hop bound until a real exit. The chain returns the bytecode
  PC where tier-0 must resume: post-inner-loop when registers are at the
  continuation anchor (including a flushed initial loop-done exit whose
  continuation exits before `.link`), or the inner root anchor when the bound
  yields immediately after a `.link`. Roll-up treats an inner loop-done exit as
  one successful enclosing-loop completion even when the inner root reports
  `completed == 0`, so the continuation is not penalized for a correct hand-off.
  Link creation now requires a cached `.loop` root, the same-anchor trial walk
  explicitly skips `.link` traces, pending continuation arms are cleared when
  execution leaves the dispatch loop, and the continuation trigger handles the
  nsieve-shaped "work after inner loop, then outer back-edge" form. Pinned by a
  nested-loop `expectProgram` 10-mode test (including the nsieve-shaped post-inner
  statement) plus focused execution-counter tests asserting the `.link` arm and
  follow branch actually ran, including an additive array-store nest that catches
  double-commit across the tier-1a→tier-0 boundary. The keyframe loose end is
  closed as tier-0-shaped coverage, not a literal link-crossing cut: the F2c
  harness creates fresh VMs with tracing disabled, so it cannot suspend inside a
  tier-1a chain. A dedicated F2c test now runs a 400×60 linking-shaped nested
  numeric-for through mid-execution capture/resume to prove the same bytecode
  shape remains snapshot-resumable.
- [x] **Phase 4 — Native-to-native chain.** Native compiled traces now report
  `irinterp.ExecResult` shape (`completed`, deterministic `exit_instr`) through
  an out-param ABI, so a native inner root can distinguish its numeric-for
  loop-done guard from ordinary guard/prologue exits. `nativegen` accepts `.link`
  terminals: a native continuation runs once, flushes its slot-bound hand-off φ
  snapshot, and returns the `.link` instruction index. `tryChainProductiveLoopDoneNative`
  follows continuation ⇄ inner-root using compiled native pages when both sides
  are native-able, with the same bounded resume-PC rules as Phase 3. The dispatcher
  enters roots that already have a `.link` continuation through a link-aware native
  mode; only numeric-for loop-done exits take the special epilogue that commits
  post-guard stores and φ writeback before returning to the chainer. Ordinary guard
  exits keep the normal native deopt contract. Pinned by the 10-mode `expectProgram`
  matrix plus focused Phase-4 regressions that assert `native_link_exits > 0` and
  `native_link_follow_count > 0`, including an additive array-store inner loop so
  an inert or scalar-only native path cannot pass green. Discharged **P4** for the
  current native-able nested numeric-for subset.

### Outstanding

_(none for the initial nested numeric-for linking cut; benchmarking/re-profile is
the follow-up review step.)_

## Why linking, not unrolling

The naive fix — teach the recorder to record `for_prep` — was implemented and
**failed**. The recorder closes a trace only at its `anchor.pc` (`onBackEdge`:
`anchor.proto == proto and anchor.pc == target_pc`). An inner loop's back-edge is
**not** the anchor, so recording does not stop there — it keeps going and
*unrolls* the entire inner loop into the outer-anchored trace. The dump of an
8×8 grid nest showed all 8 inner iterations inlined, the inner loop variable
folded into per-iteration constants, and `guard_gcol` carrying a **forward
reference** (`b=11` pointing at the `gload` two nodes later) — malformed IR that
trips `assertWellFormed`. The single-loop trace model cannot represent a nested
loop as one straight-line body.

LuaJIT reached the same conclusion and does **not** unroll. From `lj_record.c`:

- `rec_loop_jit` — a root trace hits an already-compiled inner loop:
  `lj_trace_err(J, LJ_TRERR_LINNER)`. The comment: *"Better let the inner loop
  spawn a side trace back here."*
- `rec_loop_interp` — a root trace hits an interpreted inner loop: also abort
  `LINNER` (only very short, low-trip inner loops get unrolled, a heuristic we do
  not need initially).

The linking goes the **other direction**. The inner loop is the **root trace**
(it is hottest, so it traces first). Its loop-done exit, once hot, seeds a
**side trace** that records the *outer* body forward; when that side trace
re-reaches the inner (now compiled) loop header, LuaJIT does
`lj_record_stop(J, LJ_TRLINK_ROOT, lnk)` — **link** to the inner root. The result
is a native trace tree: inner-root ⇄ outer-continuation, ping-ponging in native
code, with tier-0 never re-entered.

mahina's current `for_prep` abort already **is** the LINNER step, so the
foundation is correct. What is missing is exactly what `trace.zig` flags as
deferred at the `AnchorKey` definition: *"Loop headers are the only root-trace
anchors in Phase 5a (hot side exits seed side traces later)."* This doc builds
that "later".

## The mechanism (mahina mapping)

1. **Inner loop traces as root.** Unchanged. The inner numeric-`for` anchors at
   its header pc and compiles. An outer-loop recording that reaches the inner
   `for_prep` still **aborts** (LINNER) — kept verbatim.

2. **Inner loop-done exit → continuation side trace (Phase 1).** When the inner
   root trace's loop-done guard (`recForLoop`'s `guard_true` for `idx <= limit`,
   failing because the loop is exhausted) side-exits with zero remaining trips,
   and that exit is hot, we **arm a recording anchored at the exit PC** — the
   bytecode immediately after the inner `for_loop`. This is a *non-header* anchor,
   new in this work. The recording seeds its `reg_map` from the live registers at
   that exit and records the **outer** body forward: the code after the inner
   loop, the outer `for_loop` back-edge, and the re-entry toward the inner header.

3. **Re-reaching the inner header → link (Phase 2).** When the continuation
   recording, going forward, reaches the inner loop header and a **root trace
   already exists there**, it reconstructs the inner root's *entry state* — the
   control index `R[a] = init` and the visible loop var `R[a+3] = init` (see P2 for
   why both, and why `init` and not `init − step`) — guards `init`/`limit`/`step`
   are numbers and the first iteration is in-bounds, then **stops**, emitting a new
   `.link` terminator that names the inner root trace — instead of recording the
   inner `for_loop` (which would unroll). The `.link` is the mahina equivalent of
   `LJ_TRLINK_ROOT`.

4. **Linked execution (Phase 3 tier-1a, Phase 4 native).** On the inner root's
   loop-done exit, `tryChainExit` finds the continuation trace at that exit PC and
   runs it; the continuation runs the outer body and, at its `.link`, transfers
   control back into the inner root. Tier-1a (Phase 3) does this by nesting
   `irinterp.execute`. Because the ordinary tier-1a deopt model leaves registers
   at the loop header on a guard exit, the productive loop-done chain first commits
   the final numeric-for iteration's hand-off state from the executor scratch, then
   resumes tier-0 at the PC that matches the bounded chain's final register state.
   Native (Phase 4) does it by running the continuation and inner root through
   compiled native pages, using native exit identity to follow `.link` boundaries.
   A link-aware native entry mode gives numeric-for loop-done exits their own
   epilogue, so the final iteration's post-guard stores and φ writeback are
   committed by the original native run before the chainer enters the continuation.

## Proof obligations (the determinism contract)

The primary gate is the 10-mode matrix — `{gc_stress off/on} × {trace off,
record-only, record+exec-noopt, record+exec-opt, record+exec-native}` — producing
**byte-identical** output, plus the keyframe/replay goldens. These invariants
must hold and are stated here so a future refactor cannot silently break them.

### P1 — Arming is mode-invariant (Phase 1)

The set of side anchors armed, and the order in which they are armed, is
identical across all `{record+exec-*}` modes (× gc_stress) for a given program.

*Proof sketch.* Recording is transparent: tier-0 executes the identical
instruction stream in every mode (`01-trace-lifecycle.md`). Arming fires when
`countGuardFailure`'s `GuardKey{inner_anchor, inner_for_loop_pc}` counter crosses
`config.hotguard`; that counter is driven by outer-loop iterations, a
deterministic function of the program and inputs. `gc_stress` runs collection at
safepoints but does not change instruction order, back-edge counts, or the
trace-data allocator (`gpa`, separate from the GC heap), so it cannot change when
arming fires. Pin with a test asserting identical cache/anchor state across modes.

### P2 — The `for_prep` hand-off is byte-identical (Phase 2) — load-bearing

At the link point the continuation trace's exit snapshot must reproduce the inner
root trace's **entry state** — every tier-0 register the inner root reads at its
anchor (its `entry_slots`). For a numeric `for j = init, limit, step`, that is
`R[a] = init` (control index), `R[a+3] = init` (the **visible loop var**),
`R[a+1] = limit`, and `R[a+2] = step`.

*Why `init`, not `init − step`, and why the visible var matters.* The inner root
anchors at the loop **body start** — the `for_loop` back-edge target — and records
**body-first** (the body, then the `for_loop` at the bottom). Tier-0 first reaches
that body-start pc only *after* `for_prep` (`R[a] = init − step`) **and** the first
`for_loop` (`R[a] += step → init`, which also publishes the loop var
`R[a+3] = init`). So on entry the inner root sees `R[a] = init` and
`R[a+3] = init`. Both are live inputs: the body reads the visible var `R[a+3]` at
the top, and the bottom `for_loop` reads `R[a]` to step it (confirmed by dumping
the inner root's `entry_slots`, which include the visible-var slot). Feeding
`R[a] = init − step` would make the inner root's `for_loop` recompute `init` and
**re-run the first iteration**; leaving `R[a+3]` unset would feed the body a stale
loop var from the previous outer iteration.

*What the continuation records.* `recForPrepLink` guards `init`/`limit`/`step` are
numbers (all three — tier-0 `for_prep` type-checks `limit` too), emits a
first-iteration bounds guard (`init` within `limit`, mirroring `recForLoop`'s
compare incl. the float-limit→int specialization) so a zero-trip inner loop
side-exits to tier-0 instead of wrongly entering the inner root, then publishes
`R[a] = init` and `R[a+3] = init` into the exit snapshot. `R[a+1]`/`R[a+2]` are
unmutated by the loop and flow through untouched; any other slot the inner root's
entry guards cover (e.g. the accumulator `R0`) is either produced by the
continuation's recorded outer body or retained unchanged in the register file, and
must satisfy those guards by construction (or a runtime entry-guard check fails the
link into a deopt, never a wrong result).

*History.* An earlier Phase-2 draft recorded only `R[a] = init − step` and left
`R[a+3]` stale, on the mistaken premise that the inner root was recorded "at
`for_loop` time reading a pre-decremented idx." Dumping the actual inner-root IR
(`entry_slots = {…, visible-var slot, idx slot, …}`, body-first) disproved it. The
draft was inert in Phase 2 (the link trace is never executed) but would have
produced wrong results in Phase 3. A change to `for_prep`/`for_loop` semantics, to
the root anchor pc, or to *when* the recorder takes `slot_load`s would break this —
hence the written invariant.

### P3 — The link decision is mode-invariant (Phase 2)

The choice to **link** (a root trace exists at the inner header) vs **abort**
(none yet) is a deterministic function of the replayed instruction stream, not of
timing. It follows from the same argument as P1: the inner root trace exists in
the cache at the decision point iff the inner loop reached `hotloop` back-edges
first, which is deterministic; `gc_stress` and trace mode do not change what is
cached. No mode may link where another unrolls/aborts.

### P4 — Native chain == tier-1a chain (Phase 4)

The native linked chain produces byte-identical registers to the tier-1a linked
chain at every link boundary (the existing native-vs-oracle pattern). No
divergence when crossing `.link` in either direction.

### Keyframes and linked traces (Phase 3 finding)

Current F2c keyframe capture/resume tests are **tier-0-only**. The source evidence
is direct: `keyframeser.zig`'s `referenceRun` and `expectResume` both construct a
fresh `Vm.init`, compile the program, and run/start it without setting
`vm.trace.config.enabled`; `TraceState` defaults to disabled, and only the CLI /
`interp.zig` trace helpers opt in.

So a Phase-3 "keyframe cut across a link" is not currently feasible in that
harness. A keyframe records tier-0-visible heap, stack, frame cursors, globals,
and open upvalues at interpreter safepoints. Tier-1a traces have no mid-trace
safepoints, and the linked chain's contract is to flush/deopt to coherent tier-0
state at every boundary where the interpreter resumes. Replay safety is therefore
covered by the existing F2c machinery for any equivalent tier-0 bytecode shape,
plus the separate Phase-3 trace tests that assert `link_ir_exits > 0` and
`link_follow_count > 0` for the same nested-loop class. The added F2c
`linked_shape` test uses outer=400, inner=60, and a post-inner statement: if
tracing were enabled, it is large enough to build and follow the inner-root ⇄
continuation link, but under F2c it proves byte-identical cut/resume at tier-0
safepoints.

## Edge cases & guards

- **Loop-done vs type-change vs `if`-branch exits.** Guards stamp the
  post-increment bytecode PC (`recordInstr`'s `pc` argument), so an inner
  `for_loop` loop-done `guard_true` carries the post-inner-loop PC in `aux`, and
  the actual `for_loop` instruction is at `exit_pc - 1`. An `if`-branch
  `guard_true` carries the branch's own post-increment PC. Distinct bytecode
  offsets ⇒ distinct `GuardKey.exit_pc`, so arming targets the right site.
  Type-change exits are the `guard_int/float/number` guards emitted *before* the
  `guard_true` and are a different failure entirely.
- **`.link` well-formedness.** `assertWellFormed` accepts `.loop` or `.link` as
  the sole terminal, so a linked trace remains verifier-valid.
- **Watermark.** `recForLoop`'s `target == anchor.pc` (which sets
  `locals_watermark`) must fire only for the continuation trace's *own* anchoring
  back-edge, never the inner `for_loop` it passes through, or the exit snapshot
  drops live slots.
- **Roll-up / penalty.** In linked execution, the inner trace's loop-done exit is
  **one successful outer-body completion**, even if the inner root reports
  `completed = 0` (else `onSideExit(., 0)` penalizes and eventually gates a
  correct trace).
- **Bounded resume PC.** Once `flushNumericForLoopDone` has committed a loop-done
  iteration, the chain must not fall back to the ordinary loop-header deopt path:
  tier-0 would replay the final in-bounds iteration and double-apply sunk stores.
  If the continuation exits before `.link` (for example the outer loop is done),
  tier-0 resumes at the continuation anchor. When the bound yields immediately
  after a continuation `.link`, tier-0 resumes at the inner root anchor; resuming
  at the post-inner pc in that state skips a whole inner loop.
- **Termination.** continuation → inner-root → `.loop`; no deeper nesting. Reuse
  `tryChainExit`'s existing 8-deep visited set; `irinterp.execute` does not call
  `tryChainExit`, so a linked run cannot recurse into the chainer.
- **Only continuations link (Phase 2).** `recForPrepLink` links iff
  `Recorder.is_continuation` (set only by `maybeStartContinuation`). A *root*
  recording reaching an inner `for_prep` still LINNER-aborts — LuaJIT's model, and
  the guard that keeps a link trace from anchoring at the outer body start, which
  *is* a real back-edge target the dispatch loop would enter. (A link trace's own
  anchor — the continuation's post-inner-loop pc — is never a back-edge target.)
- **Link traces execute only through exit-PC chaining.** The same-anchor trial walk
  skips `.link` traces; `tryChainExit` is the only tier-1a entry path because it
  has the failed inner root, the continuation anchor, and the 8-hop visited bound.
  `irinterp` flushes the `.link` trace's φ snapshot before reporting the link exit;
  `tryChainExit` then enters the cached `.loop` inner root and rolls an inner
  loop-done exit up as one enclosing-loop completion.
- **`gstore` loop-done flush is defensive today.** Although
  `flushNumericForLoopDone` has a `gstore` commit arm beside `astore`/`hstore`,
  a linked source-level 2D-grid nest cannot currently reach it. The fused
  `m[i][j] = m[i][j] + k` bytecodes record through `get_index2`/`set_index2`;
  for this nest they abort as `nyi_opcode` before any continuation link is
  committed, so `--dump-traces` shows no `gstore` and no linked continuation.
  The arm stays functional for future fused-grid recording work.

## Non-goals (initial cut)

- Unrolling short low-trip inner loops (LuaJIT's `innerloopleft` heuristic).
- Loops deeper than 2 levels in a single tree beyond what recursive
  continuation-of-continuation arming yields naturally — not specially optimized.
- Linking across inlined call frames (`inline_depth > 0`) — continuation traces
  abort on cross-frame inner loops initially (same rail as `recForLoop`).
- Generic-`for`/`while` nests — this work is scoped to numeric-`for` nests first.

## References

- `01-trace-lifecycle.md` — recording transparency, anchors, termination policy.
- `02-determinism.md` — the determinism matrix + replay contract this must satisfy.
- `05-native-codegen.md` — native entry/exit, the oracle pattern (Phase 4).
- `~/Projects/LuaJIT/src/lj_record.c` — `rec_loop_jit`, `rec_loop_interp`,
  `rec_for`, the `LJ_TRLINK_*` link types (`lj_jit.h`).
