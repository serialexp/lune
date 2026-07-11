# Coherent-State Native Exit Chaining — Design

Status: complete — Phases 0–3 landed. Mechanism is general infrastructure; near-inert on nsieve specifically (coverage-bound, see Phase 2/3 Done notes), kept on for the transition shape it *does* cover and for future workloads.
Owner: Bart
Last updated: 2026-07-11 (Phases 2–3 landed)

The tracing JIT compiles every hot loop in nsieve to native code, yet ~93% of
cycles still run on the tier-0 interpreter and lune sits ~2× off LuaJIT (N=9:
tier-0 0.60s, `--trace --jit-native` 0.23s, LuaJIT 0.12s). The traces are not the
problem — **the transitions between them are.** After a trace side-exits
productively, control falls back to tier-0 even when another compiled trace is
sitting exactly where the registers are coherent, ready to run. This doc is the
contract for closing those "drop to tier-0" holes with **one** general, bounded,
determinism-preserving chaining mechanism, and for the recorder change nsieve
specifically needs to make the mechanism have a target to chain to.

It generalizes the nested-loop linking machinery (`15-nested-loop-linking.md`)
from the single "inner loop-done → continuation" shape to *any* productive
side-exit whose coherent PC has a fingerprint-matching compiled trace.

## Implementation status

Tracking the gap between this design and what's on `master`. Tick items as they
land; move whole sections to Done once everything inside is checked.

### Done

- [x] **Phase 0 — Design doc + review.** This doc: problem diagnosed + profiled,
  the coherent-state soundness argument, the unified driver API, termination bound,
  phasing, test plan. Independently reviewed by gpt-5.6-sol (original designer) and
  Antigravity; both confirmed the coherent-anchor soundness claim and their
  implementation-contract findings (per-hop `runLinkedLoopDone` selection, Phase 2
  immediate-replay arming, explicit `TraceKind`, `initially_excluded` scoping,
  counter-based mode-invariance, tier-0-work counter) are folded into the sections
  below.
- [x] **Phase 1 — Unified coherent-state chain driver.** Replaced the three split
  chain entry points (`tryChainExit`, `tryChainProductiveLoopDone`,
  `tryChainProductiveLoopDoneNative`, plus shared `tryChainExitInternal`) with one
  bounded `driveChain` carrying an explicit `walk_pc`/`resume_pc` cursor, parameterized
  by `ChainTier {ir, native_only}` and `ExitMaterialization`. All three existing
  dispatcher call sites (native-link-productive, ir-productive, zero-exit) reroute
  through it. Byte-identical: full 10-mode determinism matrix + Phase 3/4 link-counter
  unit assertions green; nsieve identical output across tier-0/record-only/tier-1a/native.
- [x] **Open question — chain tier under `--jit-native`.** Resolved: `driveChain`'s
  `native_only` tier resolves `snt = nativeFor(sct) orelse return {0, walk_pc}` — it
  never silently drops to tier-1a on the chain path, matching the native-unsupported gate.
- [x] **Phase 2 — Outer-header prime side-trace (closes Hole A).** On a
  *productive* branch-guard exit (`isSourceBranchGuardExit` discriminator — a
  `guard_true`/`guard_false` whose exit PC is not preceded by `for_loop`), a
  per-`(anchor, exit_pc)` counter in the sibling `prime_exits` map arms
  `wants_prime_side` at `config.hotguard`. The productive-exit site then forces
  `.full` via `pending_replay_anchor` and re-enters tier-0 at the coherent anchor;
  the `.full` prologue hook `maybeStartReplaySide` records the taken-branch body as
  a `.side` trace (`TraceKind` refactor: `root`/`side`/`continuation`, root never
  links) linking into the inner root. `driveChain`'s `.ordinary_header`
  materialization walks `failed.anchor.pc` (the coherent anchor) rather than the
  guard exit PC, so the chain enters that new prime side-trace. Counters
  `prime_side_arms` + `prime_side_chain_follows` prove arm + fire; a differential
  nsieve test pins byte-identical output tier-0 vs `--jit-native` with both
  counters > 0. Mode-invariant: keys only off `result.completed` and static
  bytecode PCs.
- [x] **Phase 3 — Composite-path sibling continuation / driver swap (closes Hole
  B).** The linked burst's `current_link` is a mutable ping-pong driver. On the
  inner loop-done exit (`proto.code[inner_exit_pc-1].op == .for_loop` discriminator),
  when the driver is still the prime-side *entry ramp* (anchored at the outer
  header, `anchor.pc != inner_exit_pc`), `findLinkTrace(proto, inner_exit_pc)` swaps
  it to the post-inner continuation and — under `native_only` — resolves that
  continuation's native page, so the burst stays native across the prime cluster
  instead of dropping to tier-0. If no continuation exists there, resume tier-0 at
  the post-inner PC (never the inner header — the idempotent marking loop must not
  re-run).
- [x] **Re-profiled.** nsieve reality recorded below; the mechanism is
  **coverage-bound near-inert** on nsieve and carries a small reproducible
  wall-clock regression — kept on as general infrastructure, not as an nsieve win.

### nsieve outcome (why "complete" ≠ "nsieve got faster")

The doc's founding premise — *"the traces are not the problem, the transitions
are"* — does **not** hold for nsieve, and the profiling in this session
established why:

- **The skip trace reaches a prime only ~55 times per N=7 run** (measured:
  `prime_side_chain_follows` + native link-follows in the low tens). The
  skip→prime transition the whole design targets fires a few dozen times, not
  millions — there is almost nothing to accelerate.
- **~96% of nsieve is the untraceable INIT loop** `for i=2,m do p[i]=true end`,
  which array-grows every iteration, aborts recording, and runs fully
  interpreted with *no trace at all* (CLAUDE.md's documented lever #1). Chaining
  cannot touch code that never records.
- **The prime marking loop is idempotent**, so even when a misclassification
  re-ran it (the Phase 2 regression), output stayed byte-identical — masking the
  bug until profiled. Phase 3's driver swap fixed the redundant re-execution.
- **Net wall-clock: a reproducible ~10% regression** (N=9 interleaved A/B: chain
  on ~0.25s vs off ~0.23s), from the per-productive-exit counting + arming
  bookkeeping on a path whose payoff never materializes at nsieve's coverage.

Kept **on** because the mechanism is correct, general, and determinism-preserving
(the founding premise holds for *other* transition-dense workloads); nsieve is
simply the wrong benchmark to prove it, and its remaining LuaJIT gap is JIT
*coverage* of the init loop, not transition cost. See the CLAUDE.md nsieve
verdict, which this session's profiling independently reproduced.

## Why this exists

### The nsieve kernel and its four traces

```lua
local function nsieve(p, m)
  for i=2,m do p[i] = true end          -- INIT loop
  local count = 0
  for i=2,m do                          -- OUTER loop
    if p[i] then
      for k=i+i,m,i do p[k] = false end -- INNER sieve loop
      count = count + 1
    end
  end
  return count
end
```

Four traces record and **all four compile to native** (verified via
`--dump-native`):

| Trace | Anchor pc | Shape | Terminal |
|-------|-----------|-------|----------|
| Init | `main:6` | `p[i]=true`, array-growing | `astore_append` + `loop` |
| Skip | `main:16` | outer loop, `p[i]==false` composite path | `guard_false(p[i])` + `loop` |
| Continuation / link | `main:31` | post-inner body: `count+1`, advance outer, if next `i` prime re-enter inner | `link -> 26` |
| Inner | `main:26` | inner sieve `p[k]=false` | `guard_true(k<=m)` + `loop` |

The anchors are genuine, distinct bytecode PCs (`trace {name}:{anchor.pc}`,
`trace.zig:3629`). **The skip trace and the prime path do not share an anchor**
(16 vs 31) — this fact is load-bearing for the whole design (see §The
coherent-PC correction).

### The workload shape

At N=9 there are ~5.12M outer iterations: ~356K prime (~7%), ~4.76M composite
(~93%), a ~1:14 ratio. Critically, ~94% of primes exceed `m/24`, so their inner
loop runs **fewer than `min_trip_entry` (=24)** iterations. Two consequences:

1. The **cold-dispatch trip gate** (`interp.zig:2445`, the `else if (eligible and
   !trip_ok)` arm) declines those short inner loops on the normal back-edge path —
   they run tier-0.
2. The only way those short inner loops run native is via **linked execution**,
   which deliberately bypasses the trip gate (`tryChainProductiveLoopDoneNative`,
   `trace.zig:1134`). But linked execution is reachable only from an inner
   loop-done exit, and it `break`s to tier-0 the moment the link/continuation
   trace side-exits on a composite.

So the runtime shape is: skip trace runs a native run of composites → hits a prime
→ **productively exits to tier-0** → tier-0 interprets the outer body + the (short)
inner loop → back-edge → eventually re-enters the skip trace. Every prime↔composite
boundary pays a full tier-0 excursion. That is where the 93% goes.

### The two holes

Both are in the productive-exit path (`interp.zig:2595`, `if (result.completed >
0)`). After a trace does useful work then side-exits at a guard:

- **Hole A.** The **skip trace** exits productively at `guard_false(p[i])` (it hit
  a prime). `ran_native_link_mode` is false (the skip trace has no loop-done link),
  so neither chain path fires; it `continue :outer`s straight to tier-0. Registers
  are coherent at the outer header (pc 16) — but there is no trace at pc 16 that
  handles the prime case to chain into.
- **Hole B.** The linked-execution burst (`trace.zig:1203`) `break`s to tier-0
  when the continuation zero-exits at `guard_true(p[i])` on the next composite.

They are the same shape: *after a productive side-exit, there is (or should be) a
compiled trace at the coherent PC we could enter — native, bypassing the trip
gate — instead of dropping to tier-0.* This pattern is general: it applies to any
polymorphic loop with 2+ branch/type specializations at one anchor, and any
loop-nest boundary — not just nsieve.

## The coherent-PC correction (the soundness core)

The naive framing — "after a side-exit at guard G, enter any fingerprint-matching
trace anchored at `guardExitPc(G)`" — is **fast but unsound** under the
single-snapshot deopt model. The reason:

> On an **ordinary** guard side-exit, both executors leave `regs` coherent for the
> failed trace's **anchor pc**, *not* for the bytecode instruction carrying the
> guard.

This is the dispatcher's re-entry contract (`interp.zig:2432`: "`irinterp.execute`
returns with `regs` coherent for the header — it side-exits *before* committing a
partial iteration"). Native ordinary guard exits honour the same contract; only
the link-aware numeric-for loop-done epilogue commits a *different* state
(`15-nested-loop-linking.md` §P2, and the "Bounded resume PC" edge case). So a
trace may only be entered when `regs` are coherent **at that trace's own anchor**.

Fingerprint matching (`matchesFingerprint`, `trace.zig:607`) proves register
*types*, not bytecode-position equivalence. A trace at a different PC can pass the
fingerprint and still be entered against registers that mean something different at
its anchor — a wrong result, not just a deopt.

**Consequence for nsieve.** After the skip trace (anchor 16) exits productively,
`regs` are coherent at pc 16. The prime path was recorded as a *continuation*
trace at pc 31 (armed by `maybeArmContinuation`, `trace.zig:1353`), coherent at
the *post-inner* anchor — **not** at pc 16. Chaining skip→continuation is therefore
unsound as-is. Closing Hole A is not purely a dispatch change: it needs the
recorder to produce a **prime side-trace anchored at pc 16** (§Phase 2). This is
the single biggest correction relative to the initial "just chain on the exit PC"
idea.

The four exit kinds and their coherent PCs (the `ExitMaterialization` union below
carries the three *guard*-exit variants; the `.link` terminal is a transition, not
an entry materialization, hence three union variants but four rows here):

| Exit kind | Coherent PC after exit | Notes |
|-----------|------------------------|-------|
| Ordinary guard (zero or productive) | `failed.anchor.pc` | Failing iteration uncommitted; a sibling at the same anchor may run it exactly where tier-0 would replay. |
| Numeric-for loop-done, tier-1a | `guardExitPc(guard)` after **one** `flushNumericForLoopDone` | Final iteration's sunk stores + φ hand-off committed; tier-0 must NOT resume at inner header (double-apply). |
| Numeric-for loop-done, native | `guardExitPc(guard)` (already materialized by `runLinkedLoopDone`) | No second flush. |
| `.link` terminal | `link.aux` (inner anchor) | Both executors flush the `.link` φ snapshot before reporting the terminal (`irinterp.zig:692`, `nativegen.zig` link arm). |

## The mechanism — one bounded chain driver

Replace `tryChainExit` / `tryChainProductiveLoopDone` /
`tryChainProductiveLoopDoneNative` with a single driver that owns an explicit
coherent-state cursor and a hard invocation budget.

### Proposed API (trace.zig)

```zig
pub const ChainTier = enum { ir, native_only };

pub const ExitMaterialization = union(enum) {
    ordinary_header,                    // regs coherent at failed.anchor.pc
    ir_numeric_for_done: []Value,       // executor scratch; needs one flush
    native_numeric_for_done,            // already materialized by runLinkedLoopDone
};

pub fn driveChain(
    self: *TraceState,
    failed: *Trace,
    result: irinterp.ExecResult,
    proto: *const Proto,
    regs: RegWindow,
    tier: ChainTier,
    materialization: ExitMaterialization,
    initially_excluded: []const *Trace,   // walk's visited set; applies ONLY at the initial anchor
) ?ChainResult
```

`ChainResult` is unchanged (`trace.zig:466`, `{ completed: usize, resume_pc: ?u32
}`), but its contract tightens:

- `null` — nothing ran; **no** register-state transition committed; caller falls
  to tier-0 at `failed.anchor.pc` exactly as today.
- non-null, `resume_pc == null` — `regs` coherent at `failed.anchor.pc`.
- non-null, `resume_pc = X` — `regs` coherent at X. Once a loop-done flush or a
  `.link` hand-off has changed the coherent PC, the driver **must** return
  non-null even if no further trace completes (returning `null` would strand
  tier-0 at the wrong PC).

Internal cursor: `coherent_pc`, `total_completed`, `hop_count`,
`zero_progress_visited: [8]*Trace`, `resume_pc`.

**Initialization (per `materialization` — resolves review CRITICAL, sol/AG).** The
entry state is *not* uniformly "header-coherent, nothing committed"; it depends on
how `failed` exited:

- `ordinary_header`: `coherent_pc = failed.anchor.pc`; nothing committed;
  `total_completed = result.completed`; a `null` return legally strands tier-0 at
  the anchor.
- `ir_numeric_for_done`: the `[]Value` is the executor's `values_scratch` and
  **aliases reusable state** (`irinterp.zig:68`). The driver must flush it via
  `flushNumericForLoopDone` **before** any candidate runs (candidates reuse the
  scratch) and set `coherent_pc = guardExitPc`. A transition has already committed,
  so the driver **must** return non-null (a `null` return would strand tier-0 at
  the wrong PC). `zero_progress_visited` starts empty at the post-loop PC.
- `native_numeric_for_done`: `runLinkedLoopDone` already materialized the post-loop
  snapshot before `driveChain` is called, so `coherent_pc = guardExitPc` and the
  `null → resume failed.anchor.pc` outcome is **impossible** — non-null mandatory,
  same as above.

### State machine

At each step, given `coherent_pc`:

1. Enumerate traces anchored at `coherent_pc` via `nextTraceExcluding`
   (hit-count order, `trace.zig:978`).
2. Skip traces in `zero_progress_visited` (already tried without progress at this
   coherent state). Also skip `initially_excluded` — **but only while `coherent_pc`
   is still the initial anchor** (resolves review SHOULD-FIX, sol). Once a
   transition advances `coherent_pc`, `initially_excluded` no longer applies: a
   candidate the dispatcher's same-anchor walk already tried-and-declined at the
   *entry* state may be the correct specialization at a *later* coherent state.
3. Skip `isGated` anchors (the proven-thrash brake still applies).
4. Skip traces with synthetic inputs (`inputs.len != 0`) — chaining has no `*Vm`
   to run `seedTraceInputs`; first cut declines them (matches the existing chain
   paths, `trace.zig:1263`).
5. Require `matchesFingerprint(regs)`.
6. In `native_only` mode, require `nativeFor(candidate) != null`; a
   native-unsupported candidate is **skipped, never run on tier-1a** (see the open
   question).
7. **Choose the candidate's execution mode BEFORE running it (resolves review
   CRITICAL, sol/AG).** A plain `CompiledTrace.run` leaves a numeric-for loop-done
   exit *header-coherent* — it does **not** commit the post-loop snapshot; only
   `runLinkedLoopDone` (`nativegen.zig:366`) materializes it. So for *every* hop —
   not just the initial `failed` trace — if the candidate is a numeric-for root
   whose loop-done exit has a compiled continuation
   (`hasNativeLoopDoneLink(candidate)`, `trace.zig:1102`), it **must** be run via
   `runLinkedLoopDone`; otherwise `run`. Picking `run` for a loop-done-linked root
   and then advancing `coherent_pc = guardExitPc` would enter the next trace with
   incoherent registers. The tier-1a side is symmetric: use the link-aware
   `executeLinked` path when a continuation exists.
8. Run the candidate **without** consulting `forRemainingTrips` / `min_trip_entry`.

Transitions on the candidate's exit:

- **Ordinary guard exit**: `coherent_pc` stays. If `completed > 0`, clear
  `zero_progress_visited` and accumulate; else add candidate to
  `zero_progress_visited` and try the next.
- **Numeric-for loop-done** (recognized terminal guard, continuation exists):
  tier-1a flushes once (`flushNumericForLoopDone`); native already materialized by
  `runLinkedLoopDone` (per step 7). `coherent_pc = guardExitPc`; **clear
  `zero_progress_visited`** (coherent state changed). Counts as progress.
- **`.link` terminal**: `coherent_pc = link.aux`; **clear `zero_progress_visited`**;
  next candidate must be a `.loop` root there. Consumes a hop; counts as progress (a
  correct hand-off, per the existing roll-up, `15-nested-loop-linking.md` §Roll-up).
- **No candidate / unsupported-native / OOM / gate / budget exhausted**: yield.
  `resume_pc = coherent_pc`.

Invariant: `zero_progress_visited` is scoped to a *single* `coherent_pc` value —
it is cleared on every transition that changes `coherent_pc` (loop-done flush,
`.link` hand-off) and on any committed iteration. It only ever accumulates siblings
that zero-exited *at the current coherent state* (this is what makes the C2/C3
arguments hold: a candidate wrongly excluded at S0 is reconsidered at S1).

`.link` traces remain excluded from the cold same-anchor walk (`interp.zig:2516`);
they are valid candidates **only** inside this driver.

### Branch-direction and structural guards

`guard_true`/`guard_false` are intentionally outside the fingerprint (they depend
on computed values). A candidate may pass its fingerprint and immediately fail its
branch guard — that is **safe**: `regs` stay coherent at the candidate's anchor, so
the driver just tries the next candidate (bounded). Same treatment for structural
guards not in the fingerprint (array lane/bounds/presence, hash shape).

## Termination

Two complementary bounds:

- **Hard budget: 8 trace invocations** across all anchors (`hop_count`). Essential
  because legitimate linking revisits traces (`continuation → inner → continuation
  → inner …`), so a global "never revisit a pointer" rule would break productive
  chaining. Every invocation consumes one hop regardless of outcome.
- **`zero_progress_visited` (≤8)**: candidates that zero-exited *at the current
  coherent state*, cleared after any committed iteration or consumed loop-done.
  This is what prevents A→B→A spin among sibling specializations at one anchor
  (the same failure the same-anchor walk's visited set guards, `interp.zig:2480`).

On exhaustion, resume tier-0 at `coherent_pc` — the only generally correct PC
(inner-root after a `.link`, post-inner after a loop-done, anchor otherwise). This
preserves the "Bounded resume PC" rule from `15-nested-loop-linking.md:314`.

## Why bypassing the trip gate is sound on the chain path

`min_trip_entry` is an **entry-cost heuristic**, not a semantic requirement
(`trace.zig:706` / config). It throttles *cold* dispatch, where paying trace
entry/exit for a handful of iterations loses to tier-0. A chained trace is a
different situation: it is already compiled and hot, reached from another
*successful* trace, bounded by the 8-hop budget, and still protected by
fingerprints, native-support checks, and `isGated`. The existing linked-execution
path already bypasses the trip gate for exactly this reason
(`tryChainProductiveLoopDoneNative` never calls `forRemainingTrips`); this design
extends that established policy to all safe native hand-offs, including the short
inner loops that are precisely what we want to reclaim. The proven-thrash brake
(`isGated`) is **not** bypassed.

## Dispatcher integration (interp.zig)

At the productive-exit site (`interp.zig:2595`) and the zero-exit site
(`interp.zig:2668`+):

1. Keep `onSideExit` and `maybeArmContinuation`.
2. Keep the pending-continuation priority (`interp.zig:2621`): if a continuation
   just armed, switch to `.full` so tier-0 replays and records it — this must run
   *before* the driver so the target gets recorded.
3. Otherwise call `driveChain` after every identified guard exit (productive **or**
   zero), seeding `initially_excluded` with the current same-anchor walk's
   `visited[0..nvisited]`.
4. On non-null: apply `chain.resume_pc` and `continue :outer`.
5. On `null`: the driver committed nothing; **candidates it declined at the initial
   anchor must be reflected back into the dispatcher's same-anchor `visited` set**
   so the outer walk does not immediately re-try and re-penalize them this
   back-edge (resolves review SHOULD-FIX, sol). Concretely, the driver either
   *shares* the walk's `visited` buffer (updates in place) or returns the declined
   set; pick one and state it — do not keep two independent visited lists that
   penalize the same trace twice.
6. Remove the three separate call sites (`interp.zig:2636`, `:2642`, `:2685`).

Tier selection: `record_exec_log` → `.ir` **run through `executeTraced`, not plain
`irinterp.execute`** — the visualizer's "one execution-log entry per execute call"
contract (`execlog.zig`) must see every chained ramp, or replay diverges (resolves
review SHOULD-FIX, sol). `--jit-native` → `.native_only`; plain trace execution →
`.ir`.

**Behaviour is NOT inert before Phase 2 (correcting the Phase 1 checklist lede).**
Calling the driver after *productive* exits — which the old code never did — can
already run an unvisited same-anchor sibling or an existing `.link` target that the
three old call sites skipped, changing hit counts, penalties, and `onSideExit`
accounting even with no new recorder targets. Phase 1's gate is therefore not "zero
diff" but "the 10-mode matrix stays byte-identical **and** the link/back-edge
counters move only in explainable ways" — capture a before/after counter snapshot
on nsieve as part of landing Phase 1.

## Phase 2 — the recorder change that gives Hole A a target

To make skip→prime chaining sound, a **prime side-trace at the outer header (pc
16)** must exist. Today the prime path is only ever recorded as the continuation
at pc 31. The change:

- **Count productive branch-guard exits for side-trace arming**, not only zero
  exits — the current restriction is `interp.zig:2585` (`if (result.completed ==
  0)`). A productive `guard_false(p[i])` exit that keeps hitting the prime branch
  should arm. Distinguish a **source-level branch guard** (`if p[i]`) from a
  numeric-for terminal `guard_true` — only the former is a prime-side-trace
  candidate; the latter is loop-done and already handled by continuations.
- **Arm-and-record the *immediate* replay of the failing (prime) iteration — the
  existing `wants_side_trace` machinery does NOT do this** (resolves review
  CRITICAL, sol/AG). `countGuardFailure` sets `wants_side_trace`
  (`trace.zig:1439`), which today is consumed at the *next back-edge*
  (`onBackEdge`, `trace.zig:1683`) — i.e. it records the *next* outer iteration,
  which in nsieve is ~93% likely to be a **composite**, the wrong path. Phase 2
  needs a distinct "arm at this deopt PC now" signal: on the productive prime exit,
  switch tier-0 to `.full` mode **for the replay of that same iteration** (anchored
  at the failed outer header), record the taken prime branch forward through the
  inner `for_prep`, and close with `.link` to the inner root. This `.full`-priority
  arm must run *before* `driveChain` (same ordering as the existing pending-
  continuation priority, step 2 above), so the target exists before we try to chain
  to it.
- **Give the recorder an explicit trace-kind; do NOT merely relax
  `is_continuation`** (resolves review CRITICAL, sol/AG). `recForPrepLink`
  (`trace.zig:3023`) currently closes with `.link` only when `is_continuation`.
  Unconditionally relaxing that would make the **initial outer-loop root** (also
  not a continuation) close with `.link` too — and since `.link` traces are
  excluded from the same-anchor walk (`interp.zig:2516`), the outer loop could then
  never be entered from its back-edge and would run entirely tier-0. Fix: thread a
  `TraceKind { root, side, continuation }` through recording; permit `.link`
  closure for `continuation` **and** `side`, never for `root`. Equivalent guard:
  only link when a root already exists at the anchor (`hasTrace(anchor)`). The
  header-anchored `.link` side-trace must be verified to stay excluded from the
  walk (it is a valid `driveChain` candidate only).

Resulting sound shape:

```
outer-header skip trace  (guard_false, loop)
      productive exit on a prime
outer-header prime side-trace  (guard_true(p[i]), … , link -> inner)   ← NEW
      link
inner root  (loop)
```

The driver then chains skip → prime side-trace → inner, all native, all bypassing
the trip gate.

## Phase 3 — Hole B (composite sibling continuation)

Inside the linked burst, replace the `break` on continuation zero-exit
(`trace.zig:1203`) with a `driveChain` step at the continuation's coherent anchor
(post-inner, pc 31). The sound target is a **composite-path sibling continuation**
recorded at that same post-inner anchor (a `guard_false(p[i])`-shaped sibling of
the existing prime continuation), so the burst chains through composites. The
alternative — full per-guard snapshots advancing coherent state to the outer
header — is higher risk and rejected for the first cut.

**The sibling needs a new arming path (resolves review SHOULD-FIX, sol).**
`maybeArmContinuation` (`trace.zig:1353`) refuses an anchor that already has a
trace, and ordinary side-trace arming only fires at matching *back-edges* — neither
will record a second specialization at the already-occupied pc-31 anchor. Phase 3
must count the continuation's productive/zero exits and, on the composite side,
yield to tier-0 in `.full` mode at pc 31 to record the sibling (mirroring the
Phase 2 immediate-arm signal, but at the post-inner anchor rather than the outer
header). Without this, Hole B never acquires a chain target.

## Proof obligations

The gate is the existing 10-mode matrix (`{gc_stress off/on} × {trace off,
record-only, record+exec-noopt, record+exec-opt, record+exec-native}`) plus
keyframe goldens. Stated here so a refactor cannot silently break them.

### C1 — Chaining is output-invariant

Every chained entry leaves `regs` and side effects exactly as tier-0 would at the
same coherent PC. Follows from: (a) only entering a trace at its own coherent
anchor (§The coherent-PC correction); (b) the ordinary-exit "failing iteration
uncommitted, tier-0/sibling re-runs it" discipline; (c) the loop-done single-flush
+ `.link` φ-flush rules inherited from `15` §P2/§"Bounded resume PC". Pinned by an
nsieve-shaped `expectProgram` asserting `.off ≡ .record_execute ≡
.record_execute_native`.

### C2 — Different-PC entry is forbidden

A trace whose anchor ≠ `coherent_pc` is never entered, even on a fingerprint
match. This is the negation test: a candidate at `guardExitPc` (which differs from
the anchor for ordinary exits) must be *rejected*. Pin with a focused test that
constructs a fingerprint-matching trace at a non-coherent PC and asserts the driver
does not run it.

### C3 — Termination

No input drives more than 8 trace invocations per `driveChain` call; two zero-exit
siblings cannot cycle. Pin with a two-zero-exit-traces test asserting ≤8
invocations then tier-0 yield at the correct PC.

### C4 — Native chain ≡ tier-1a chain

Byte-identical registers at every hand-off boundary in `.native_only` vs `.ir`
tiers (the existing native-vs-oracle pattern, `15` §P4). **Register equality is
not sufficient (review SHOULD-FIX, sol):** the two tiers must also agree on the
`completed` roll-up, `onSideExit` calls, hit counts, guard-failure counts, and
penalty/gate state at every boundary — those feed *future* trace selection, so a
divergence there is a determinism bug even when the current registers match. Assert
the observable counters, not just the value window.

### C5 — Arming is mode-invariant (Phase 2/3)

The set and order of prime side-traces **and** composite sibling continuations
armed is identical across all `{record+exec-*}` modes × gc_stress — same argument
as `15` §P1 (arming is driven by deterministic guard-failure / exit counters,
unaffected by gc_stress or trace mode). The immediate-`.full`-arm signals added in
Phases 2 and 3 must themselves be counter-driven and mode-invariant, not keyed off
anything native-only.

**Status after Phases 2–3 (2026-07-11):** all five hold and are pinned green.
C1 — the differential nsieve test asserts byte-identical stdout tier-0 vs
`--jit-native` (`.off ≡ .record_execute_native`), and the full 10-mode matrix
stays green. C2 — `driveChain`'s `.ordinary_header` walks `failed.anchor.pc`, never
the guard exit PC, so a sibling at a non-coherent PC is not entered; the burst's
loop-done discriminator (`for_loop` predecessor) further prevents entering the
inner header on a completed loop. C3 — the burst is still bounded by
`visited.len` (8) hops; the prime-side→continuation swap replaces the driver
in place, it does not add hops. C4 — the `native_only` swap resolves the
continuation's native page (`nativeFor(cont)`) or yields to tier-0, and the
`.ir`/`native_only` paths share the same `completed`/`onSideExit` roll-up. C5 —
arming keys only off `result.completed` and static bytecode PCs
(`isSourceBranchGuardExit`, the `prime_exits` counter vs `config.hotguard`); the
`TraceKind` link-permission test pins root-never-links, and the matrix would trip
on any native-only signal leaking into the arm decision.

## Failure modes to watch

- **Polymorphic-anchor thrash.** Aggressive chaining could re-introduce the
  "running the trace was slower than tier-0" regression the trip gate and
  native-unsupported gate exist to prevent (`interp.zig:2703` safety net, and the
  TODO.md "polymorphic-anchor thrash" note). Mitigation: `isGated` is still
  honoured on the chain path; keep the two-traces-per-anchor cap
  (`countGuardFailure`, `trace.zig:1439`); apply `onSideExit` to each chained
  target so low-yield accounting still fires.
- **Alternating one-iteration A/B traces.** The principal regression risk; the
  8-hop budget + `zero_progress_visited` bound the damage, but re-profile nsieve
  after each phase to confirm the outer back-edge counter flattens.
- **Native-unsupported leaking to tier-1a.** Under `--jit-native`, tier-1a can be
  slower than tier-0 on these bodies (`trace.zig:1047` / the native safety net).
  The driver must skip native-unsupported candidates, never run them on tier-1a.

## Test plan

**Keep green** (must not regress):

- `link_ir_exits` / `link_follow_count` assertions (`interp.zig:9484`, `:9518`).
- `native_link_exits` / `native_link_follow_count` (`interp.zig:9549`, `:9593`).
- tier-1a linked array-store exactly-once (double-commit catcher).
- the full 10-mode `expectProgram` matrix.

**Add**:

- Productive trace A exits; native sibling B at the same coherent anchor runs
  (Hole A unit).
- Fingerprint-mismatching B skipped.
- Branch-mismatching B zero-exits; another sibling tried (C-branch handling).
- Two zero-exit traces bounded at ≤8 invocations (C3).
- Ordinary exit forbidden from entering a different-PC trace despite matching
  fingerprint (C2, the load-bearing negation).
- IR + native loop-done materialization advances `coherent_pc` to the continuation
  anchor; budget-exhaustion-after-`.link` resumes at inner root; after loop-done
  resumes post-inner.
- Native-unsupported candidate yields to tier-0, never tier-1a.
- **nsieve differential** (`min_trip_entry` = 24, range large enough for many
  short inner loops): `.off ≡ .record_execute ≡ .record_execute_native`, and the
  native run additionally asserts new deterministic counters (productive-chain
  follows > 0, short inner trace entered via chaining, all relevant targets
  genuinely `.compiled`, and a **new tier-0-work counter** trending to ~0 after
  warm-up). **Output equality alone is insufficient** — full tier-0 fallback also
  passes, so the counter assertions are what prove the chains fire. Note the
  existing outer back-edge counter is the *wrong* signal (review SHOULD-FIX, sol):
  once any trace exists at the anchor, `onBackEdge` (`trace.zig:1711`) returns
  before incrementing it, so it "flattens" even under full tier-0 fallback. Add a
  counter that actually measures tier-0 outer-body execution (e.g. count tier-0
  entries to the outer-header PC) instead.

## Non-goals (initial cut)

- Seeding synthetic-input traces (upvalue/global callee) on the chain path —
  declined, as the existing chain paths do.
- Chaining across inlined call frames (`inline_depth > 0`).
- Generic-`for` / `while` specializations — scoped to numeric-`for` + branch
  specializations first.
- Per-guard full snapshots for Hole B (the higher-risk alternative to the sibling
  continuation).

## References

- `01-trace-lifecycle.md` — recording transparency, anchors, termination.
- `02-determinism.md` — the 10-mode matrix + replay contract.
- `05-native-codegen.md` — native entry/exit, the oracle pattern.
- `15-nested-loop-linking.md` — the linking machinery this generalizes (Phases
  1–4, P1/P2/P4, the "Bounded resume PC" and roll-up rules).
- `~/Projects/LuaJIT/src/lj_record.c` — side-trace seeding, `LJ_TRLINK_*`.
