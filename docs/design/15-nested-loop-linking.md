# Nested-Loop Trace Linking — Design

Status: partial — Phases 1–2 (exit-PC anchors + `.link` terminator) landed; Phases 3–4 outstanding
Owner: Bart
Last updated: 2026-06-27

The tracing JIT cannot trace **nested numeric-`for` loops**. An outer loop that
contains an inner loop never tiers up: the recorder aborts at the inner loop's
`for_prep` (`else => self.abort(.nyi_opcode)`, `trace.zig`), so the whole nest
runs on the tier-0 interpreter. This is a structural JIT-**coverage** gap (not
codegen tightness) and a measurable slice of the remaining LuaJIT gap on nsieve
(the middle/clear-loop nest) and `grid_matmul` (~18% tier-0 at last profile).

This doc is the contract for closing that gap the way LuaJIT does — **trace
linking**, not loop unrolling — and the home for the determinism **proof
obligations** the phases must discharge to stay byte-identical across the 8-mode
matrix.

## Implementation status

Tracking the gap between this design and what's on `master`. Tick items as they
land; move whole sections to Done once everything inside is checked.

### Done

- [x] **Phase 0 — Design doc.** This doc: LuaJIT model verified against
  `~/Projects/LuaJIT/src/lj_record.c`, lune mapping, proof obligations P1/P2/P4.
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
  Phase 2's `.link` goes. Native arming deferred (native loop-done exits carry
  `exit_instr = maxInt`, no per-guard pc) to Phase 4. Discharged **P1**: pinned by
  an `expectProgram` 10-mode output-invariance test plus a focused
  `runExecForTrace` test asserting a second, distinct `for_prep` abort site (the
  continuation, anchored at the post-loop pc) actually arms.
- [x] **Phase 2 — Link terminator + snapshot hand-off.** New `.link` IR terminator
  (`trace.IrOp`, wire ordinal 56 — appended at the enum end, mirrored in
  `traceser.zig`'s ordinal contract and `viz/src/enums.ts`). `assertWellFormed`
  accepts `.loop` **or** `.link` as the sole terminal; `commit` appends
  `.link{aux = inner anchor pc}` when `Recorder.link_target` is set and caches the
  trace **unoptimized** (`tropt` is skipped — its LICM/φ machinery and the
  `instrs[n-1].op == .loop` assert are written for back-edge loops, and a Phase-2
  link trace is never executed anyway). `recForPrepLink` (dispatched from the
  `.for_prep` recording arm) records `for_prep`'s pre-decrement `R[a] = init − step`
  and closes with the link **iff** (a) this recording is a *continuation*
  (`Recorder.is_continuation`, set only by `maybeStartContinuation`) — a *root*
  recording that reaches an inner `for_prep` still LINNER-aborts, matching LuaJIT
  and keeping link anchors off real back-edge targets — and (b) the inner loop
  header (the `for_loop` back-edge target == `for_prep`'s post-increment pc) already
  has a cached root trace; otherwise it LINNER-aborts unchanged. Discharged **P2**:
  the recorded `R[a] = init − step` is byte-identical to the inner root's
  `entry_slots[R[a]]` (the inner root reads its pre-execution idx at `for_loop`
  time, i.e. exactly what `for_prep` leaves). The link trace is committed but
  **never executed** in Phase 2 — `tryChainExit` skips any `.link`-terminated trace,
  and the continuation's post-loop anchor pc is not a back-edge target the dispatch
  loop enters — so output stays byte-identical (pinned by the `expectProgram` matrix
  plus a focused test asserting a `.link`-terminated trace is cached whose `aux`
  resolves to a cached `.loop` root). `irinterp` has the `.link` arm (a clean
  zero-commit fall-through) ready for Phase 3, but it is dead in Phase 2.

### Outstanding
- [ ] **Phase 3 — Linked execution, tier-1a.** `irinterp.execute` follows
  `.link`; roll-up treats the inner loop-done exit as one outer success.
  Nested-loop program in the `expectProgram` 8-mode matrix incl. a keyframe
  cut→resume across a link. Correct but not yet faster.
- [ ] **Phase 4 — Native-to-native chain.** `nativegen` lowers `.link` to a
  native jump/tailcall into the inner trace's native entry; inner loop-done exit
  returns into the continuation's native code. Discharge **P4**. Re-profile.

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

lune's current `for_prep` abort already **is** the LINNER step, so the
foundation is correct. What is missing is exactly what `trace.zig` flags as
deferred at the `AnchorKey` definition: *"Loop headers are the only root-trace
anchors in Phase 5a (hot side exits seed side traces later)."* This doc builds
that "later".

## The mechanism (lune mapping)

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
   already exists there**, it records `for_prep`'s subtract (`R[a] = init − step`)
   and then **stops**, emitting a new `.link` terminator that names the inner root
   trace — instead of recording the inner `for_loop` (which would unroll). The
   `.link` is the lune equivalent of `LJ_TRLINK_ROOT`.

4. **Linked execution (Phase 3 tier-1a, Phase 4 native).** On the inner root's
   loop-done exit, `tryChainExit` finds the continuation trace at that exit PC and
   runs it; the continuation runs the outer body and, at its `.link`, transfers
   control back into the inner root. Tier-1a (Phase 3) does this by nesting
   `irinterp.execute`; native (Phase 4) does it with a direct jump/tailcall into
   the inner trace's native entry.

## Proof obligations (the determinism contract)

The primary gate is the 8-mode matrix — `{gc_stress off/on} × {trace off,
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

At the link point the continuation trace's exit snapshot for the inner control
slot `R[a]` equals `init − step`, which is **byte-identical** to the inner root
trace's `entry_slots[R[a]]`.

*Why it holds.* tier-0's `for_prep` (`interp.zig`) pre-decrements:
`R[a] = sub(R[a], R[a+2])` = `init − step`, then jumps to `for_loop`, whose first
act is to add `step` back. The inner root trace was recorded **at `for_loop`
time**, and the recorder reads *pre-execution* operands — so the inner trace's
`slot_load` for `R[a]` captured the value `for_prep` had just left on the
**immediately preceding** outer iteration, i.e. a pre-decremented idx. Therefore
the continuation trace recording `for_prep`'s subtract and terminating at the
`for_loop` boundary leaves `R[a] = init − step`, exactly what the inner trace's
entry expects. `R[a+1]` (limit) and `R[a+2]` (step) are unmutated by `for_prep`
and flow through untouched; any other slot the inner trace's `entry_guards` cover
is produced by the continuation's recorded outer body and must satisfy those
guards by construction (verified, or a runtime entry-guard check fails the link
into a deopt, never a wrong result). A change to `for_prep` semantics or to *when*
the recorder takes `slot_load`s would break this — hence the written invariant.

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

## Edge cases & guards

- **Loop-done vs type-change vs `if`-branch exits.** The inner `for_loop`'s
  `guard_true` carries the `for_loop` PC in its `aux` (per-guard PC recording);
  an `if`-branch `guard_true` carries the branch instruction's PC. Distinct
  bytecode offsets ⇒ distinct `GuardKey.exit_pc`, so arming targets the right
  site. Type-change exits are the `guard_int/float/number` guards emitted *before*
  the `guard_true` and are a different failure entirely.
- **`.link` well-formedness.** `assertWellFormed` currently asserts the terminal
  op is `.loop`. Phase 2 must extend it to accept `.link` as a valid terminal, or
  every linked trace panics the debug-build verifier (a correctness-oracle
  regression).
- **Watermark.** `recForLoop`'s `target == anchor.pc` (which sets
  `locals_watermark`) must fire only for the continuation trace's *own* anchoring
  back-edge, never the inner `for_loop` it passes through, or the exit snapshot
  drops live slots.
- **Roll-up / penalty.** In linked execution, the inner trace's loop-done exit
  returns `completed = 0`; the continuation must treat that as **one successful
  outer-body completion**, not a failed trace (else `onSideExit(., 0)` penalizes
  and eventually gates a correct trace).
- **Termination.** continuation → inner-root → `.loop`; no deeper nesting. Reuse
  `tryChainExit`'s existing 8-deep visited set; `irinterp.execute` does not call
  `tryChainExit`, so a linked run cannot recurse into the chainer.
- **Only continuations link (Phase 2).** `recForPrepLink` links iff
  `Recorder.is_continuation` (set only by `maybeStartContinuation`). A *root*
  recording reaching an inner `for_prep` still LINNER-aborts — LuaJIT's model, and
  the guard that keeps a link trace from anchoring at the outer body start, which
  *is* a real back-edge target the dispatch loop would enter. (A link trace's own
  anchor — the continuation's post-inner-loop pc — is never a back-edge target.)
- **Link traces are inert until Phase 3.** `tryChainExit` skips any
  `.link`-terminated trace (the only path that could otherwise reach the
  continuation's anchor pc). Running one straight through would execute the outer
  body's sunk stores and then fall through at `.link` with `completed == 0`,
  double-applying them on the tier-0 redo. **Phase 3 must remove that skip** as it
  teaches the chain to *follow* the link (run the inner root, ping-pong) — the
  `irinterp` `.link` arm is already a clean zero-commit fall-through placeholder.

## Non-goals (initial cut)

- Unrolling short low-trip inner loops (LuaJIT's `innerloopleft` heuristic).
- Loops deeper than 2 levels in a single tree beyond what recursive
  continuation-of-continuation arming yields naturally — not specially optimized.
- Linking across inlined call frames (`inline_depth > 0`) — continuation traces
  abort on cross-frame inner loops initially (same rail as `recForLoop`).
- Generic-`for`/`while` nests — this work is scoped to numeric-`for` nests first.

## References

- `01-trace-lifecycle.md` — recording transparency, anchors, termination policy.
- `02-determinism.md` — the 8-mode matrix + replay contract this must satisfy.
- `05-native-codegen.md` — native entry/exit, the oracle pattern (Phase 4).
- `~/Projects/LuaJIT/src/lj_record.c` — `rec_loop_jit`, `rec_loop_interp`,
  `rec_for`, the `LJ_TRLINK_*` link types (`lj_jit.h`).
