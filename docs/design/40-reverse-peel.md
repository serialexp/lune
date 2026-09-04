# Float→int φ narrowing via the reverse peel — Design

Status: partial — Phase 0 landed (the peeled while-done hazard was REAL and is fixed); phases 1+ outstanding
Owner: mahina JIT campaign (doc 39 follow-up)
Last updated: 2026-09-05

## Implementation status

Tracking the gap between this design and what's on the main branch.
Tick items as they land; move whole sections to "done" once everything
inside them is checked. Ordering follows codex finding 10: refusal
first (stops the bleeding), eligibility second, sweep third, native
test-first, retry plumbing only after observing which channel aborts.
Every phase lands behind its own `just test` gate.

### Done

- [x] **Phase 0 — pin the peeled while-done hazard (landed-code
  audit).** Codex finding 3 was a REAL cross-tier divergence in the
  landed doc-39 code: the targeted test (same-frame outer-for +
  inner-while, one instance whose while ends right after the run-once
  iteration) printed 185.5 on `.record_execute` vs tier-0's 186 — the
  `.while_done` chain resumed the post-loop pc on the untouched entry
  boxes, losing the run-once iteration. Two important repro notes:
  (a) the while must share the OUTER loop's frame — inside a called
  function the continuation never arms ("cont-arm refuse: no
  enclosing back-edge") and the test is vacuously green; (b) the fix
  distinguishes exit position: a run-once-region loop-done at zero
  completions really is zero iterations (chain-safe, the doc 38
  argument), only the STEADY-region loop-done at zero completions
  owes a replay. Landed: `whileDoneCoherentAtZero` (trace.zig, next
  to the classifiers), the peel-aware dispatcher classification gate
  (interp.zig, the `while_done_exit` computation), a fail-closed twin
  inside `driveChain`'s `.while_done` walk-pc derivation for future
  callers, the ten-leg matrix test ("doc 40 phase 0"), and a
  permanent `debug_log` knob on the test harness's `CapturedOpts`
  (per-VM jitdbg receipts for a single leg). Suite green, hashgate
  84/84.

### Outstanding
- [ ] **Phase 1 — commit preflight: int↔float kind-coherence refusal.**
  In `closeTrace`, before `commit()` mutates anything (codex finding
  4 — by fingerprint time the stream is already appended/optimized,
  and a commit error is classified `.commit_failure`): sweep
  `reg_map[0..anchor_num_registers]` — the same data
  `maybeEnterPeel` reads — and refuse a would-be `.loop` recording
  (no `link_target`, not in peel mode) any carried slot of which has
  numeric `entry_kind` ≠ numeric carried-ref `ty`. Abort
  `.type_instability`. Scope strictly to proven int↔float pairs
  (codex finding 6: `EntryGuardType`/the entry-kind lattice cannot
  express string/bool/nil coherence, and carried table/string slots
  have legitimate specialized load/store relationships,
  nativegen.zig:3281/3295). Applies to ALL recording kinds — root,
  side, continuation — since a self-contradicting `.loop` is DOA
  regardless of provenance. Measure the removed tier-1a
  1-iteration segments (codex finding 6: no *chain* coverage is lost
  — generic wants need `completed == 0`, productive same-anchor
  chaining needs a branch guard — but the segments themselves go).
- [ ] **Phase 2 — peel eligibility for the channels that actually
  record the glue shape.** The reset-to-int glue is unreachable by
  `.root` recordings (LLEAVE aborts the exit edge, trace.zig:14341/
  14367; the cond-false glue is deliberately side-route-only,
  comment at trace.zig:14355). Empirically (jit-debug, 2026-09-05):
  the fft/repro DOA traces come from the **prime-side** channel
  (`want PRIME side` off the body root's while-condition exit) and
  the **continuation** channel (`cont-arm` at the rotated PC). Extend
  `maybeEnterPeel` eligibility from `kind == .root` to recordings of
  any kind that are closing as `.loop` at their own anchor, keeping
  the rest of the gate (plain-while anchor OR the glue anchor shape,
  no pending stores/allocs/inline depth — re-derive the exact set
  during implementation). This lifts doc 39's "Defer —
  side/continuation recordings" bullet for the glue-loop case only;
  side recordings that link elsewhere stay out.
- [ ] **Phase 3 — bidirectional instability sweep.** Generalize the
  sweep (trace.zig:12341–12349) to both numeric directions; it then
  serves both consumers: peel-eligible recordings enter the peel,
  ineligible ones fall through to Phase 1's refusal. Per-slot
  direction — one peel may widen one slot and narrow another; tests
  pin the mixed case.
- [ ] **Phase 4 — native reverse-shape tests (test-FIRST, then fix
  what fails).** Codex finding 7: the doc-39 Phase-3 machinery is
  already substantially bidirectional (entry homes allocate by entry
  kind incl. XMM/TAG_FLOAT, nativegen.zig:3657/6096; steady homes by
  φ kind, :3691; RV-3 already accepts both numeric mismatches for
  peeled traces, :3336; both deopt flushes use `steady_kind`,
  :7297/:7419; the `entry_rbx` zero-flush skip is kind-independent,
  :7280). Expected deltas: comments/assertions only. Add the
  structural assertion `kinds[phi.a] == kinds[phi]` (codex finding 5
  — `movePlace` treats GP↔XMM as unreachable, nativegen.zig:4616).
- [ ] **Phase 5 — retry lifecycle (only if observation demands it).**
  Codex finding 2 corrects the starvation model: warming aborts
  already retry via the record gate's doubling cooldown
  (trace.zig:12139/12165), and a saturated hot-exit counter re-arms
  on every later eligible exit — only `EXIT_COUNT_DONE` (stamped on
  side-trace COMMIT, not abort) suppresses (trace.zig:8908). So a
  `.type_instability` peel abort on the prime-side channel retries
  organically. What needs design ONLY IF the channels measurably
  starve: preserving channel + `ExitKey` across abort (abort
  destroys `side_src`, trace.zig:12177), want recreation, gate
  coordination, OOM = fail-closed normal backoff, and epoch teardown
  (any new anchor-keyed state joins the `clearCache` reset list,
  trace.zig:11638) (codex finding 9).
- [ ] **Phase 6 — gates + measurement.** Ten-leg matrix tests
  (`expectProgramTuned`) for: reverse peel commits organically on the
  repro shape; refusal on the peel-ineligible variant; mixed
  widen+narrow peel; zero-completion deopt; while-done-during-
  run-once (Phase 0's test, kept). Deterministic trace-SHAPE
  assertions (committed trace count/kinds/peeled flags), not output
  parity alone (codex finding 9). Per-anchor measurements before/
  after (codex finding 8): peel commits, runtime chain follows,
  **rejected persistent-fusion arms** (armNativeLink refuses peeled
  parents/children, trace.zig:10837 — it will refuse at precisely
  these fft anchors), while-yield gates (peeled receipts feed
  `onSideExitReceipt` → the while-yield gate, trace.zig:3728/3801),
  and final `--jit-stats` residency. Full suite + hashgate + bench
  vs a `just shadow` baseline.
- [ ] **Open question — persistent fusion for peeled traces.** The
  doc-39 v1 fusion exclusion caps the win at these anchors (runtime
  `driveChain` still follows, but exit-branch fusion refuses). If
  Phase 6 measures the refusals dominating, lifting the exclusion
  (making the +1 seam adjustment chain-aware) becomes its own arc.
- [ ] **Defer — multi-peel (Pall's `instunroll`).** Budgeted
  re-peeling when iteration 2 also mismatches. v1: exactly one peel;
  the organic channel retry (Phase 5 observation) is expected to
  cover the ~alternating viability of the reset family.
- [ ] **Defer — non-numeric DOA refusal.** Bool flip-flops etc. are
  equally self-defeating but need a semantic-kind model the current
  entry-kind lattice can't express (codex finding 6). Numeric-only
  in this doc.
- [ ] **Defer — the accounting black hole.** `accountLegacyThrash`'s
  productive early-return (trace.zig:3866) lets a 1-iteration-
  per-entry trace clear its anchor's penalty forever. Phase 1
  removes the known producer; raising the clear threshold is a
  broader change left for its own measurement.

## Why this exists — the failure loop

`fft_bitreverse` (bench/luajit/scimark_lib.lua:178–188) still holds
~39% of the scimark-fft run hostage after doc 39: the while-header
anchor (`:55`) is 23.2% of the run at 0.9% traced, the rotated
outer-wrap anchor (`:68`) another 15.5% at ~0%. Both anchors' missing
traces are the same single-slot shape doc 39 explicitly deferred —
**F1-reverse**: a carried slot that enters float and stores int.

```lua
local k = n                                   -- INT store, every outer iteration
while k <= j do j = j - k; k = k / 2 end      -- k/2 floats k
j = j + k
```

Recordings of the glue path start at while back-edge arrivals, where
`k` is float (every inner back-edge floats it), so the recorder pins
`guard_float` on entry (`guardNum`, trace.zig:13373). The recorded
outer-wrap path ends with `k = n` — an int φ store. Committed IR,
from the live tree (trace #2 at `:68`; trace #4 at `:55` is the same
single-slot story):

```
%001  slot_load    r7
%003  guard_float  %1        ← entry pins float
...
%019  slot_load    r1        ← n (int)
%027  phi          update=%19 -> r7    ← back-edge stores INT
```

Such a `.loop` trace is **self-defeating**: its own back-edge always
delivers an int into a float-guarded entry, so it can never take its
back-edge. It is not merely uncompilable — it is a permanent black
hole, because every stage of the machinery mistakes it for healthy
(all sites verified on the live tree, 2026-09-05):

1. `maybeEnterPeel`'s sweep is one-directional (`s.entry_kind != .int`
   → skip, trace.zig:12341–12349) — and would not run anyway: these
   are `.side`/`.continuation` recordings and the gate requires
   `.root` (trace.zig:12329). `closeTrace` commits directly.
2. `commit` emits the slot φ with the body ref's type verbatim
   (trace.zig:12563–12569) and `assertWellFormed` is type-blind — no
   stage compares a φ store type against the entry guard.
3. The moment it commits, `hasTrace` latches the anchor's warming
   (trace.zig:12126) and the continuation channel refuses re-arms
   (`cont-arm refuse: has_trace=true`, observed via jit-debug).
4. nativegen bails RV-3 (nativegen.zig:3336–3368) → `.unsupported` →
   under `--jit-native` the dispatch walk skips it and
   `gateNativeUnsupported` (interp.zig:4149) gates the whole anchor.
5. On tier-1a it enters (the fingerprint matches — the arrival *is*
   float), completes exactly **1** iteration, and exits on the entry
   guard. `completed > 0` then (a) clears the anchor's thrash penalty
   every single time (`accountLegacyThrash`, trace.zig:3866), (b)
   disqualifies the generic side-trace want (needs `completed == 0`,
   trace.zig:8961), and a `guard_float` exit is not a branch guard so
   the prime-side route (trace.zig:8945) never fires either. No want,
   no penalty, no re-record — ever.

Standalone repro: `/tmp/f1rev.lua` (mirrors the reset-to-int shape)
reproduces both DOA traces and the residency collapse (while anchor
1.1% traced, 20.6% of run) with no fft context. The shape is a common
Lua idiom — per-outer-iteration integer reset of a slot a float loop
consumes — not an fft artifact.

### Where these recordings actually come from (codex finding 1)

A `.root` recording at the while anchor cannot record the glue path
at all: LLEAVE aborts a root that takes its anchor loop's own exit
edge (trace.zig:14341/14367), *by design* — the cond-false glue
sibling (the figure-eight) is reachable only through the side route,
which skips the check by kind (comment at trace.zig:14355, with the
measured justification). Verified with jit-debug on the repro:

```
[jit] hotexit: trace id=1 exit=5 count=10 -> want PRIME side at pc=25   ← DOA trace #4's channel
[jit] cont-arm: pending at pc=38 (inner anchor 25)                      ← DOA trace #2's channel
```

So any fix that lives inside `maybeEnterPeel`'s `.root`-only gate
fires on **neither** fft trace. Phase 2 exists because of this; the
"organic trigger" claim below holds for the side/continuation
channels, not for warming roots.

## What LuaJIT does

`lj_opt_loop.c:342–353`: when loop-unrolling finds a loop-carried
value whose type differs between iteration 1 and the re-emitted
iteration 2, Pall (a) widens int→num with an unguarded `CONV NUM_INT`
(exact — his ints are 32-bit), (b) narrows num→int with a guarded
`CONV INT_NUM|CHECK`, (c) anything else raises `TYPEINS`, and at
`lj_opt_loop.c:432` the handler does `loop_undo` **and returns to
recording** — "unrolling via recording fixes many cases" — budgeted
by `instunroll` (4, lj_jit.h:120).

His CONV arms work because loop-unroll *re-emits* iteration 2 through
the fold pipeline, so a conversion integrates into a regenerated body.
mahina records concrete execution — kinds are pinned at record time —
so a recorded body cannot be retyped after the fact. Doc 39 already
made this argument for the forward direction and chose (c) in Pall's
taxonomy: keep recording another iteration. The mahina-shaped
mechanism for that is the peel, and it is already built. This doc is
the reverse application of it, plus the commit-time refusal that arm
(c) implies when no stabilization is possible.

The retype-at-the-φ route (widen the int store to float so the loop
closes: `float_of_int` on the update) is rejected for the same reasons
doc 39 rejected seam conversions and stronger ones: the widened slot
would be physically float where tier-0 holds an int — every exit would
need "semantically int" re-boxing annotations, `math.type` would need
special-casing, and 64-bit int→float widening is inexact past 2^53.
The peel needs none of that.

## Design

### One sweep, two consumers

The generalized instability sweep (any carried slot with numeric
entry kind ≠ numeric carried-ref ty) runs at close time for every
would-be `.loop` recording. Peel-eligible recording → enter the peel
(existing doc-39 plumbing: inline `preheader` marker, iteration 1
verbatim as run-once, iteration 2 against internal φs, `finishPeel`'s
direction-agnostic type re-check at trace.zig:12401–12403).
Peel-ineligible → refuse the commit (abort `.type_instability`).
Nothing self-contradicting ever enters the cache; the anchor's
accounting stays live; the producing channel retries under the
record gate's deterministic doubling cooldown. A refused commit
never produces the doc-38 `gateNativeUnsupported` anchor gate —
there is no unsupported trace to skip.

The refusal must run in `closeTrace` **before** `commit()` (codex
finding 4): by the time the fingerprint step could compare, the
stream has been appended and optimized, and a commit error is
classified `.commit_failure`; the `reg_map` sweep sees the same
information first, with clean abort semantics.

### The reverse seam needs no conversion

This direction is *simpler* than doc 39's:

- Forward (doc 39): the steady φ is float; the iteration-1 int init
  flows into it, and exactness across the seam had to be reasoned
  about (the >2^53 run-once test pins it).
- Reverse: the steady φ is int; its init is iteration-1's back-edge
  store ref, **which is already the int** (`k = n` executed in the
  run-once region). The float entry value dies inside the run-once
  region. No conversion, no exactness condition, nothing to guard at
  the seam.

Codex (finding 5) confirmed the mechanics on the live tree:
`PeelSlot.ref` snapshots the iteration-1 final ref (trace.zig:12355),
the internal φ takes `a = ps.ref, ty = ps.ref.ty` (trace.zig:13235),
tier-1a initializes from `values[a]` (irinterp.zig:493), native seeds
the computed home from the same ref (nativegen.zig:7140). Deopt
re-boxes from the steady home with steady kind = int — byte-exact
against tier-0 by construction, because the int in the steady home
*is* the int tier-0 would hold. The new structural assertion
`kinds[phi.a] == kinds[phi]` pins the invariant `movePlace` relies on
(GP↔XMM unreachable, nativegen.zig:4616).

### Steady-state viability and channel retry

Iteration 2 of a reverse peel is viable only if the concrete
execution's next anchor-return carries the int kinds (for the fft
shape: the next outer iteration's while runs zero trips — roughly
every other one). Otherwise `finishPeel` fails and the recording
aborts `.type_instability` — correctly. Retry then comes from the
producing channel's own machinery: hot-exit counters keep re-arming
after saturation (only a side-trace *commit* stamps
`EXIT_COUNT_DONE`, trace.zig:8908/12467), continuation re-arms are
refused only while a trace exists at the PC, and the record gate
paces everything with its doubling cooldown. v1 builds **no new
retry state**; Phase 5 designs it only if measurement shows a
channel starving (codex findings 2/9).

The steady loop, once committed, side-exits whenever the recorded
path's guards fail (the while must run this iteration) — an ordinary
exit into the existing runtime chain machinery. Note the doc-38
distinction (codex finding 8): runtime `driveChain` follows peeled
traces, but **persistent exit-branch fusion refuses them** (the
doc-39 v1 exclusion, trace.zig:10837) — at precisely these anchors.
Phase 6 measures how much that exclusion costs; lifting it is the
follow-up arc if it dominates.

### Determinism and ten-leg identity

Peel and refusal decisions are pure functions of recorded kinds —
deterministic counters in, no clocks, no addresses. The run-once
region preserves iteration 1's float semantics verbatim; steady-state
ints are the ints tier-0 holds; no value ever converts kind at the
seam. Any new anchor-keyed state joins the epoch-teardown reset list
(trace.zig:11638) and fails closed on OOM. The ten-leg matrix
(`expectProgramTuned`, interp_testutil.zig) asserts output identity;
Phase 6 adds trace-shape assertions (count/kinds/peeled flags) on
top, since output parity alone cannot distinguish "peeled and ran
native" from "refused and ran tier-0" (codex finding 9).

## What this does not fix

The while-loop *trip-count variance* at these anchors (traces pinning
exact trip counts via unrolled branch guards) is the separate,
structural coverage story — the doc-38 while-loopdone chaining already
carries part of it (fft's 15.1% native residency today is largely
fused loopdone chains). This doc removes the DOA traces and gives the
wrap path a real steady-state loop; it does not promise the inner
while's variance disappears. Phase 6's per-anchor measurements pick
the next lever.

## References

- docs/design/39-numeric-phi-widening.md — the forward peel; premise
  gap; Phase 3 entry/steady home split; the F1-reverse and
  side/continuation deferrals this doc lifts (glue-loop case only).
- ~/Projects/LuaJIT/src/lj_opt_loop.c:342–353, 432 — φ type
  unification and the unroll-by-recording fallback; lj_jit.h:120
  (`instunroll`).
- Live-tree evidence (2026-09-05): `--dump-traces`/`--dump-native` on
  bench/luajit/scimark-fft.lua (traces #2/#4 unsupported, single slot
  r7 float-entry/int-store); `/tmp/f1rev.lua` standalone repro;
  `--jit-stats` per-anchor residency; jit-debug channel provenance
  (`want PRIME side`, `cont-arm`).
- Codex review 2026-09-05 (thread 01a06d21-7916-71f2-a006-9c5c5c66519e),
  11 findings: 4 blocking (root-only eligibility vs the glue channels;
  retry model corrections; peeled while-done hazard; commit-check
  insertion point), all reflected in the phasing above.
- Machinery map: LLEAVE glue policy (trace.zig:14330–14375), dispatch
  walk (interp.zig:3945–4200), fingerprint (trace.zig:1577–1589),
  want production (trace.zig:8908–9016), thrash clearing
  (trace.zig:3866), DONE latch (trace.zig:12126), peel trigger
  (trace.zig:12329–12377), finishPeel (trace.zig:12379–12409), RV-3
  (nativegen.zig:3336–3368), fusion exclusion (trace.zig:10837).
