# 64 — Heavy-iteration loop nests: region decay, exit-side give-ups, the marker root

Status: **reviewed (round 1, §9), decided (§10); step 1 (diagnosis)
done (§11), which corrects §3 P1. No policy change built yet.**
Bart asked for this doc and for Codex's and Antigravity's opinions
before picking options. Corrections from the reviews are applied in
place and listed in §9. Where the reviewers disagreed, Bart asked me to
break the tie; §10 records the choices and the reasons.

## 1. Why this doc

nsieve-bit-fp is the board's worst row: 16.1× LuaJIT on `2752e6c`
(342.4 ms JIT, 382.0 ms tier-0). TODO.md carried its remaining cost as
"the `while` inside `for k` has no looping root trace". That reading came
from the m=5000 kernel, and it is wrong at the board size
(`nsieve-bit-fp.lua 6`, m = 640000/320000/160000): the `while` root
exists. The real causes are four separate mechanisms in doc 17's region
accounting and doc 56's exit-side routing. Each one is a policy in core
tiering machinery, so the fix wants a design pass rather than a patch
(Z-7, Z-8).

The kernel (vendored LuaJIT `nsieve-bit-fp.lua`, lines 14–29):

```lua
for i=2,m do                                   -- anchor 23 (outer)
  local r = p[idx] / bit
  if r - floor(r) >= 0.5 then
    local kidx, kbit = idx, bit
    for k=i+i,m,i do                           -- anchor 45 (for k)
      kidx = kidx + i
      while kidx >= cm do kidx = kidx - cm; kbit = kbit + kbit end
                                               -- pc 53 `.loop` marker, header 54
      local x = p[kidx]                        -- pc 63 (after the while)
      local r = x / kbit
      if r - floor(r) >= 0.5 then p[kidx] = x - kbit*0.5 end
    end
    count = count + 1
  end
  idx = idx + 1
  if idx >= cm then idx = 0; bit = bit + bit end
end
```

`cm = ceil(m/50)` (12800 at m = 640000). The `while` runs about
`i / cm` times per `k` step: 0 or 1 while `i < cm` (`kidx` keeps the
previous remainder, so adding `i` can cross `cm`), and up to ~25 once `i`
approaches `m/2`. One outer iteration for a prime `i` contains
a whole `for k` loop of `m/i` steps.

## 2. Where the time goes

`--jit-stats` on `2752e6c` (release build):

| bucket | share of run |
|---|---|
| native execution | 27.4% |
| steering seam (ledger replay, 115,763 walks, ~7.3k cycles each) | 37.3% |
| tier-0, the anchor has a trace | 21.1% |
| tier-0, no trace | 4.8% |
| other (non-loop) | 9.4% |

Per anchor: the outer `for i` (23) ran 532,161 iterations in tier-0 at
~800 cycles each against 640k traced at ~280. That is nearly all of the
21.1%. The `while` header (54) ran 292,490 iterations in tier-0 at
~350 cycles, the 4.8%.

Traces (ids from a `-Djit-debug` run):

| id | anchor | shape |
|---|---|---|
| t1 | 45 | `for k` root; exit 15 is the `while` test, resume 53 |
| t2 | 53 | exit-side child of t1 e15: one `while` trip, `link -> 45` |
| t6 | 53 | t2's sibling: two trips, `link -> 45`; its e10 is exit-side-armed to itself |
| t4 | 23 | outer `for i` root |
| t7 | 54 | the `while` root, `loop` terminal (committed after 5 recording aborts) |
| t8 | 63 | exit-side child of t7 e10: post-`while` body, then the `for k` test (e33), `link -> 45` |

## 3. The four problems

### P1. Region decay gates the outer `for i`

> **Corrected by §11:** the gated owner is the `for k` header (pc 45), not
> the outer `for i`, and its activations close because the `for k` loop
> finished. The text below is the round-0 reading.

Region rid=2 is minted as a `cross_trace_cycle` with owner anchor 23.
`beginCredit` adds each row's credited work to `outer_traversals`
(`trace_region_policy.zig`). The unit is per row kind
(`trace_chain.zig` ~1802): 1 for `.loop_done_linked`, `local` for
`.deopt`, `local + 1` for `.exit_side`, 0 for structural rows. Each
activation of this region closes with 3–6 units credited, though each
outer traversal holds a whole `for k` loop. The observed bursts end at
23 rows (a `.deopt` at t6 e41), below `LEDGER_CAP` (32), and a yield
alone does not close an accumulator. **What closes these activations is
not established yet** (Codex): a destination classification, source
normalization, or a tier-0 program point outside recorded membership
(`trace_regionops.zig` ~1555) can each close it. So every activation
closes below `min_useful` (8), `beginClose` → `flushWindow` returns
`.strike` (no useful window was ever seen, so doc 55's tail rule does
not apply), and
`applyWindowDecision` (`trace_regionops.zig`) adds a penalty. At
`max_penalty` (8) it calls `gateAnchor(owner, .region_decay)`, which
backs off 256 → 8192 ticks, then `condemnProvenanceEdgesAt(owner)` and
`disarmAllLinks()` (14 armed links on this run). This run logged 3,559
window strikes and 5,808 `region_decay` gates.

Doc 17 §A3.2 built the gate to retire genuinely cold regions (< N
traversals) and to stop an armed edge that ping-pongs from staying
pinned. Here the region is neither: it is hot, and its members run
natively. "Traversals per activation" stands in for "useful work per
activation". The stand-in breaks when one traversal is itself a long
loop.

LuaJIT has no equivalent. A root trace is only blacklisted when
recording fails (`lj_trace.c` penalty on abort), never because its runs
end after few iterations of the outer loop.

### P2. A chain that ends at the enclosing loop's own exit counts as a miss

t7 (the `while` root) exits at its own loop test (e10). Its exit-side
child t8 at pc 63 runs the post-`while` body and exits at e33, which is
the `for k` loop-done (`guard_true` after `for_loop`): the `for k` loop
finished. `driveChain` reports the chain as not linked
(`linked_trace == null`, `completed = 0`, ledger 1), and
`noteExitSideChain` (`trace_link.zig`) counts a miss. After
`tryside` (4) consecutive misses the exit gives up for good: arm
disarmed, adapter unpublished, state `.gave_up`. Same story for t1 e15
(see P3) and for t4 e25. In the log, t7 e10's chains before the give-up
had `completed = 18`: eighteen `while` trips, then the post-`while`
body, all native.

Caveat (Codex): t8's e33 is an ordinary deopt, not the linked loop-done
flush, so tier-0 replays the interrupted iteration from t8's anchor; "the
loop finished" describes the control-flow condition, not committed
state. The miss counter also counts routed firings only
(`interp.zig` ~4417), not every run through an armed child.

Doc 56 §R4 defined the give-up as the turnstile for "no continuation at
`P` fits". A chain that runs natively until the enclosing loop finishes
did fit. `linked_trace` only answers "did the candidate reach its
`.link`", so the loop ending is scored like a misfit.

LuaJIT: `tryside` (4) bounds failed **recording attempts** for an exit
(`lj_record.c` ~2884: past `hotexit + tryside` the side trace is stopped
as `LJ_TRLINK_INTERP`). Once a side trace exists, the exit is patched to
it permanently. Nothing ever un-attaches a side trace because of how its
runs end.

### P3. The exit-side chain at a `.loop` marker never tries the loop's root

t1's `while` exit (e15) is attachable with resume pc 53, which is the
`while`'s `.loop` marker. Its header is 54 (`bytecode.loopHeaderOf`:
`.loop` → `pc + 1`). Doc 56 rule 8 refuses a header as `P` (the
`resume_header` verdict: "the target would be that loop's root"), so a
`while` exit always resumes on the marker. `driveChain` asks
`nextTraceExcluding(proto, 53)` (`trace.zig`), which returns only traces
anchored at 53: the composites t2 and t6, recorded while no `while` root
existed. They unroll one and two trips, then `link -> 45`. Once the
`while` needs 3+ trips, both deopt at their own `while` test, the chain
ends unlinked, and t1 e15 gives up after 4 (P2's mechanism, here with a
real misfit). t7 is never offered, though tier-0's entry patch for t7
sits on that same marker (`entry-patch install: pc=54 patch_pc=53`): at
pc 53 tier-0 enters t7 for nothing.

Offering t7 is not only a lookup change. Two gates reject a child that
does not end in `.link` (Antigravity): `driveChain` skips such an
exit-side candidate (`trace_chain.zig` ~355, `!is_link`), and `arm`'s
`.exit_side` case requires `child.code.anchor.pc == P` and a `.link`
terminal (`trace_link.zig` ~2079–2080). Replay, promotion validation and
structural successor discovery also encode "the child is anchored at
`P`" (Codex: `trace_link.zig` ~1122, ~881; `trace_chain.zig` ~1941,
~2432).

The recorder side already exists: a continuation recording that reaches
a `.loop` marker whose header has a compiled, unpeeled root with
matching entry guards closes with `link -> header`
(`trace_recorder.zig` ~4125–4150, LuaJIT's `LJ_TRLINK_ROOT`). t2 and t6
predate t7, and nothing re-records or rebinds them once t7 commits.

LuaJIT: a side trace that reaches a compiled loop op links into it
(`rec_loop_jit`, `lj_record.c` 660–672: `LJ_TRLINK_ROOT` to the loop's
trace). It also refuses to let a root trace unroll an inner loop that
loops back (`rec_loop_interp`, `LJ_TRERR_LINNER`). Instead it waits for
the inner loop's own root and lets side traces link to it.

### P4. One ledger row per t6 hop

t6's `while` exit (e10) resumes at 53, and its exit-side child is t6
itself (same anchor, same pc). So a long `while` runs as a string of t6
hops (each covers one or two trips), each an `.exit_side` ledger row; the
observed bursts hold ~18 of them. Across the run, 390,454 of 1,245,483
ledger rows are an `.exit_side` row repeating the previous row's
`(trace, exit)`. Each row is replayed by the seam. No other bench in the
suite has a single such row.

Why those rows never go silent (Antigravity): `resolveSuccessorAnchor`
(`trace_link.zig` ~883) drops an exit-side successor whose resume pc
equals the trace's own anchor (`p != t.code.anchor.pc`), so the
`t6 e10 → t6` edge never enters the structural graph or a region, and
silent promotion needs one.

## 4. How general this is

Z-6 asks whether these are nsieve-bit-fp quirks or general gaps. A survey
over every `@bench` program (jit-debug and `--jit-stats`, `2752e6c`
behaviour):

| bench | region_decay gates | window strikes | exit-side miss give-ups | tier-0 with a trace | seam |
|---|---|---|---|---|---|
| nsieve-bit-fp | 5808 | 3559 | 3 | 17.0% | 42.2% |
| nsieve | 2 | 0 | 1 | 9.2% | 13.9% |
| scimark-lu | 0 | 560 | 0 | 1.6% | 9.8% |
| grid_matmul(_f64) | 0 | 0 | 1 | 2.7–4.5% | ~1.9% |
| repack | 0 | 0 | 4 | 11.3% | 9.1% |
| scimark-fft | 0 | 0 | 0 | 11.2% | 22.9% |
| everything else | 0 | 0 | 0 | — | — |

(tier-0-with-trace and seam shares from a single `--jit-stats` run
each; euler14-bit's 74.5% and str_gmatch's 32.9% tier-0-with-trace have
other causes, not these.)

So in the suite, P1 and P4 bite only nsieve-bit-fp, and P2 shows up on
a handful. The shapes are not exotic, though: a loop whose iterations
each run an inner loop of data-dependent length (P1), a `while` nested
in a `for` whose trip count grows over the run (P3/P4), and any
exit-side chain that runs into the end of its enclosing loop (P2). The
suite is thin on them. Every fix below needs its own small test program
(Preference #3), not nsieve-bit-fp as its witness.

## 5. Options

These are the options as I see them, for the reviewers to attack or
extend. None is preferred here (Rule 17).

### P1 — region decay

- **1a. Count work in member iterations.** Credit the accumulator with
  the iterations every member row completed (the rows' `local`), not
  only the owner's outer traversals. A `for k` with 500 steps then
  counts 500. `min_useful` keeps its meaning ("enough native work to be
  worth the arm"). Risk: doc 55's fft butterfly (work=1 early stages,
  512 late) and doc 17's ping-pong case were tuned on traversal counts.
- **1b. Strike only on evidence of ping-pong, not on short activations.**
  Keep traversals, but do not strike a close whose members ran many
  native iterations. Keeps the counter, changes what is "low yield".
  (Round 0 also said "or cycles"; both reviewers rejected that: a
  measured cycle count in a tiering decision breaks determinism. Counts
  only.)
- **1c. Drop the owner gate; keep the targeted tools.** A strike-out
  demotes the region's silent sets and tombstones the region (as the
  `fallback_owner` path does), but never gates the owner anchor and never
  runs `disarmAllLinks`. The fallback path is not a model for the second
  half: its `invalidateRegion` also calls `disarmAllLinks`
  (`trace_regionops.zig` ~512, Codex). Closest to LuaJIT (no runtime
  blacklisting of a working root). Loses doc 17's "retire genuinely cold
  regions" unless 1a/1b supplies it.
- **1d. Replace `disarmAllLinks` with the region's own links**, so a
  strike-out stops tearing down unrelated nests. Independent of 1a–1c;
  doc 17 §A3 notes M1/loop-done links carry no region identity yet,
  which is why it is global today.

### P2 — give-up accounting

- **2a. A chain that ends at a loop-done counts as linked.** If the last
  candidate's terminal exit is a numeric-`for` loop-done
  (`isNumericForLoopDoneGuard`) or the own loop test of a loop that
  contains the parent's exit, reset the miss counter.
- **2b. Same condition, but neutral:** neither reset nor count.
- **2c. LuaJIT's semantics.** Count only failed recordings and failed
  child prologues against `tryside`; once attached, never give up on
  run outcomes. A real misfit (P3's composites) then has to be repaired
  by binding a better child, not by unbinding (needs P3).
- **2d. Give-ups expire.** Keep today's counting, but let `.gave_up`
  return to `.none` after a re-heat (TODO "Exit-side give-ups are
  permanent"). Independent of 2a–2c.

### P3 — the root behind the marker

- **3a. Offer the header root in the chain.** When `driveChain`'s
  exit-side walk is at a `.loop` marker, offer the loop roots at its
  header after (or before) the traces anchored at the marker. Entering
  the root there is what tier-0 does at that pc.
- **3b. Bind the exit to the header root.** `routeExitSide` treats a
  loop root at `loopHeaderOf(P)` as an existing matching child, so the
  native arm jumps from the exit adapter straight into the root's entry.
  Needs the arm/adapter contract checked for a target anchored at
  `P + 1` rather than `P`.
- **3c. Recorder links to a compiled loop.** Already built (see P3).
  What is missing is replacing or rebinding composites recorded before
  the root existed (t2/t6), e.g. a fresh forwarding continuation and a
  deterministic rebind of their parents. Retiring them wholesale is too
  broad: other exits may still use them (Codex).
- **3d. Lift rule 8 when a root exists.** Let `P` be the header itself
  when a compiled root is there, so ordinary candidate lookup finds it.
  Rule 8's reason ("the target would be that loop's root") becomes the
  feature.

### P4 — one row per trip

- **4a. Nothing beyond P3.** With P3 the `while` runs inside t7's own
  `loop`, and the t6 self-hop no longer happens on this shape.
- **4b. A self-targeted exit-side arm forms a loop.** When the child of
  an exit-side exit is the parent itself at the same pc, record or treat
  it as an extra loop (LuaJIT's `LJ_TRLINK_LOOP` when a side trace
  returns to its start pc, `rec_loop_jit`), so the trips are a native
  back-edge, not ledger rows.
- **4c. Silent-promote the self-cycle.** Let the self-arm join a silent
  set so its rows stop being written (doc 17 B-3/B-4).

## 6. Interactions

- P3 (any of 3a–3d) makes t7 run the `while`, which removes P4's rows on
  this shape and turns t1 e15's misses into links. But t7's own exit
  then hits P2 every time the `for k` loop ends. So P3 without P2 gives
  up again after 4 such chains.
- P1 is independent of the other three and is the largest single slice
  (the 21%).
- 2c leans on P3: if misses no longer give up, a misfit has to be fixed
  by binding a better child.

## 7. Questions for the reviewers

1. Is the P1 diagnosis right that "outer traversals per activation" is
   the wrong evidence for a cross-trace cycle whose traversals contain
   inner loops? Which of 1a–1d, or what else, preserves doc 17's and doc
   55's protections (cold regions, ping-pong, fft's phase-variant
   butterfly)?
2. For P2, is "the chain ended at a loop-done of an enclosing loop" a
   sound "this continuation fits" signal? Are there shapes where it hides
   a real misfit?
3. For P3, which of 3a–3d is sound under doc 56's resume-coherence rules
   (the slab is coherent at the marker; tier-0 enters the root there),
   and which composes with exit patching (doc 17) without a new arm
   kind?
4. Does 4a hold, or is P4 a general gap (any exit-side child equal to
   its parent) that wants 4b or 4c regardless?
5. Anything in the evidence that looks misread?

## 8. Evidence

- `--jit-stats`, `nsieve-bit-fp.lua 6`, release build of `2752e6c`.
- `-Djit-debug` log of the same run. The JIT's decisions are identical
  on 397831e and `2752e6c` (the facts table changes no answer; all
  outputs and counters match). Key lines: `region: mint id=2
  kind=cross_trace_cycle members=2 armable=true`; `window-strike:
  owner pc=23 work=4 penalty=7/8`; `disarm-reason: window gate-strike
  owner pc=23 work=6`; `chain-candidate: failed=7 ei=10 walk_pc=63
  mat=exit_side cand=8 exit=33 completed=0`; `exit-side: trace=7
  exit=10 gave up after 4 unlinked chains`; `chain-candidate: failed=1
  ei=15 walk_pc=53 mat=exit_side cand=2 exit=10 completed=0
  ledger_len=2 final=6`.
- LuaJIT: `src/lj_record.c` 629–672 (`rec_loop_interp`,
  `rec_loop_jit`), ~2882–2892 (the `tryside` side-trace stop),
  `src/lj_trace.c` ~798–810 (`trace_hotside`), `src/lj_jit.h` 117–118
  (`hotexit` 10, `tryside` 4).

## 9. Review round 1 (2026-10-20)

Codex (`docs/reviews/doc64/codex-r1.md`) and Antigravity
(`docs/reviews/doc64/antigravity-r1.md`) reviewed the round-0 text
read-only. Both confirm all four mechanisms in the code and the LuaJIT
comparison.

**Corrections applied above.**

- `LEDGER_CAP` is 32. The 23-row bursts end at a `.deopt` (t6 e41), not
  at the cap. (Codex; Antigravity repeated the 23 as the cap, which is
  wrong.)
- P1's close cause is not established: a yield does not close an
  accumulator, so something else closes these activations with 3–6
  units. Credit units differ per row kind. (Codex)
- P2's terminal is an ordinary deopt, so tier-0 replays the last
  iteration; the miss counter counts routed firings only. (Codex)
- P3 needs more than a lookup: the `is_link` filter in `driveChain` and
  `arm`'s `.exit_side` anchor/terminal checks reject t7, and replay,
  promotion and topology assume the child sits at `P`. (Antigravity,
  Codex)
- 3c already exists in the recorder; what's missing is rebinding the
  pre-root composites. (Codex)
- P4's rows are per t6 hop (one or two trips each), and they cannot go
  silent because `resolveSuccessorAnchor` drops a resume pc equal to the
  trace's own anchor. (Codex, Antigravity)
- 1c: the fallback path's `invalidateRegion` also runs
  `disarmAllLinks`. (Codex)
- 1b: no measured cycles in a tiering decision. (both)
- Kernel: `i < cm` does not mean zero trips. (Codex)

**Where they agree.**

- P3 → **3b**: bind the exit to the root behind an effect-free `.loop`
  marker, as an extension of `ArmKind.exit_side` (no new arm kind), with
  entry through the root's ordinary entry and its entry checks. Codex
  adds: one resolved-target description that separates the adapter's
  resume pc from the child's entry pc, used by arming, replay, promotion
  and topology alike; and the root offered **before** the marker
  composites, since a composite can mutate state before later candidates
  run.
- P4 → **4a** first: with P3, the `while` runs on t7's own back-edge.
  Profile again before anything else.
- 1d (targeted teardown instead of `disarmAllLinks`) is sound on its
  own. Codex: dependency-based, not a filter on `region_id`.
- P2 must be fixed with or before P3, or t7's exit gives up again at
  every `for k` end.
- 2c (LuaJIT's "count recording failures only") is the eventual
  direction, but needs a repair path for stale children first.

**Where they differ.**

| question | Codex | Antigravity |
|---|---|---|
| P2 | 2b (neutral), with an explicit outcome type (served / natural stop / entry refusal or misfit / yield); reset only on proven service by the candidate; never via `linked_trace`, which also picks the child to arm | 2a (counts as linked), plus 2d (give-ups expire after a cooldown) |
| P2 soundness | a loop-done terminal can hide a misfit (a copy whose loop continues, another loop's or an inlined frame's guard, a child that commits nothing) | reaching the enclosing loop's done guard proves the body ran, so no misfit hides |
| 2d | only on new deterministic evidence (e.g. a new root at `P`), bounded backoff; not plain periodic expiry | expiry after a cooldown |
| 3d | rejected: attachability and resume pc are immutable commit-time facts (`exit_facts`); target availability must stay dynamic | 3b + 3d |
| P1 order | establish the close cause first; then corrected 1a (work by materialization kind, same rules in rowed, scalar and silent accounting) only if productive short activations remain; 1c later, as an explicit policy | 1a (`loop_done_linked => local`) + 1c now |
| P4 later | 4c (silent self-cycle) if a productive self-cycle remains; 4b deferred (needs a real loop contract) | 4b scheduled for generality |

**Order proposed.** Codex: (1) find P1's close cause and pin it with
tests, (2) P2 explicit outcomes with 2b, (3) 3b with 3a's runtime path,
(4) re-measure P1, corrected 1a if still needed, (5) 1d, (6) 4a and
re-profile. Antigravity: (1) P2 2a + 2d, (2) P3 3b + 3d, (3) P1 1a + 1c,
(4) P4 4b.

Open for Bart: which P2 variant (2a or 2b; 2d now or later), whether 3d
is in, and the P1 order (diagnose the close cause first, or 1a + 1c
now).

## 10. Decision (2026-10-20)

Bart asked me to break the tie where the reviewers disagree, and to
write the reasons down. The agreed points stand as in §9 (3b with the
root offered before the marker composites, 4a first, 1d, P2 with or
before P3). The choices on the disputed ones:

**P2: 2b (neutral), with an explicit chain outcome.** A chain's result
becomes a typed outcome instead of being read off `linked_trace`:
*served* (the candidate reached its `.link`), *natural stop* (it ended
at a loop-done or own-loop-test exit of a loop that encloses the
parent's exit, as resolved through the facts table), *misfit* (it
deopted anywhere else, or its entry refused). Served resets the miss
counter, natural stop neither resets nor counts, misfit counts.

Why not 2a: Codex's counterexamples are concrete, and Antigravity's
answer ("reaching the done guard proves the body ran") does not hold
here. t8's e33 is an ordinary deopt, so tier-0 replays the interrupted
iteration; nothing the candidate did is proven committed. A copy whose
loop continues past the guard, another loop's guard, or an inlined
frame's guard all look the same at that exit. 2b still fixes P2, since
t7 e10's chains stop counting, and it only loses the reset. A
child that alternates natural stops with real misfits still gives up,
which is what the turnstile is for. Splitting the outcome from
`linked_trace` also removes the overload Codex pointed out:
`linked_trace` also chooses the child to arm.

**2d: now, but triggered by evidence, not a timer (Codex's form).** A
`.gave_up` exit returns to `.none` when a new trace that could serve it
commits: a trace anchored at `P`, or (with 3b) a loop root at
`loopHeaderOf(P)`. Each commit allows at most one revival, so the
backoff stays bounded. It has to come now, not later. t1 e15 can give
up on the t2/t6 composites before t7 commits, and a permanent give-up
would then hide the root that 3b binds. A cooldown (Antigravity's
form) would also revive exits where nothing has changed, and it would
need a clock-like counter in a tiering decision for no gain over the
commit event, which is already deterministic.

**3d: out.** Attachability and resume pc are commit-time facts of the
parent: `ExitFacts` memoises them, and replay and the viz read them
as fixed. 3d would make them depend on whether some other trace
exists, which is dynamic. 3b gets the same binding while keeping that
split: the parent's facts stay the same, and target resolution
(marker → header root) happens at route time, in the one
resolved-target description that §9 says arming, replay, promotion
and topology all use.

**P1: find the close cause first.** Two reasons. First, the doc
cannot yet say what closes these activations (§3 P1), and Z-8's ladder
says to find the layer before changing the policy: if a classification
or membership gap closes them early, 1a would hide that bug behind a
larger count. Second, 1a + 1c change the protections doc 17 and doc 55
were tuned on (cold-region retirement, ping-pong, fft's phase-variant
butterfly), and P2/P3 change what runs inside this region. Once 3b
binds t7, the activations look different, so tuning 1a now would tune
it against a shape that is about to disappear. After that, 1a (in
Codex's corrected form: work by materialization kind, applied the same
way in rowed, scalar and silent accounting) comes only if productive
short activations remain. 1c, if still wanted, comes later as its own
explicit policy change. 1d does not depend on either and can land
whenever.

**P4: 4a, then re-profile; 4c before 4b if a self-cycle remains.** With
3b, the `while` runs on t7's back-edge. 4b needs a real loop contract
for exit-side self-links, which is new machinery, so it needs its own
doc (Z-8). 4c reuses existing machinery and comes first if the
re-profile shows a productive self-cycle.

**Order:**

1. P1 diagnosis: find what closes rid=2's activations and pin the
   finding with a test. No policy change in this step.
2. P2: the typed chain outcome, 2b, and evidence-triggered 2d.
3. P3: 3b, with 3a's runtime path, root before composites, one
   resolved-target description.
4. Re-profile. Corrected 1a only if short productive activations
   remain.
5. 1d.
6. P4: re-profile; 4c if needed.

Each step gets a small test program of its own (§4), not
nsieve-bit-fp as the only witness, and a board run.

## 11. Step 1 result: what closes the activations (2026-10-20)

Measured with a close-reason probe (`CloseReason`, logged by
`closeRegionBecause` under `-Djit-debug` and counted in
`TraceState.region_closes`, the `--jit-stats` "region closes:" line) on
`nsieve-bit-fp.lua 6`, without coverage. No policy changed.

**§3 P1 named the wrong region.** The regions on this run:

| rid | owner | edges (anchor pc → successor pc) | what it is |
|---|---|---|---|
| 1 | 45 (`for k`) | 45→53, 53→45, 45→87, 53→87, 87→45 | the `for k` cycle |
| 2 | 23 (`for i`) | 23→101, 101→23 | the outer loop, composite-`i` path |
| 3 | 23 | 23→101, 23→93, 93→101, 93→23, 101→23 | the outer loop, prime path |

Of the 5,808 `region_decay` gates, **5,801 are on pc 45**, the `for k`
owner; 7 are on pc 23. The outer loop's regions take 3,555 window
strikes but almost never reach the gate, because runs of composite `i`
fill windows and recover the penalty.

**rid=1 closes because the `for k` loop finished.** All 27,602 of its
closes are departures at pc 88, which is tier-0 running the code after the
`for k` loop. Each activation is one whole `for k` loop, and for every
prime above m/8 that loop has fewer than `min_useful` (8) steps. Such an
activation fills no window, so its close is a strike (work 0–7 in the
log). The close itself is correct, and the activation was fully
productive; the strike rule calls it low-yield only because it was short.

**rid=2 closes when the outer iteration enters the inner loop.** 5,800
closes are `source_outside` (t1's e15 receipt classifies to rid=1 while
rid=2 is the active region in the same frame), and 3,426 are departures at
pc 53 (tier-0 at the `while` marker, outside rid=2's membership). One
activation per frame means a nested region displaces the enclosing one.
This costs strikes but almost no gates, so it is not the expensive part.

**The gate is effectively permanent, and each strike still tears down.**
The `for k` anchor's gate reaches `max_strikes` (6) at the sixth gate and
is never cleared afterwards (its strike count climbs to 11,597 with no
reset), so `isGated` holds for the rest of the run. Every later strike
still runs `gateAnchor` → `condemnProvenanceEdgesAt` → `disarmAllLinks`.
The legacy machine also gates the same anchor: 5,796 `legacy_thrash` gates
on pc 45 and 5,798 on pc 37.

**What lifting the gate buys on its own** (throwaway build with
`max_penalty` = 10⁹, then reverted): output identical; instructions
−7.6%; tier-0-with-a-trace 17.2% → 7.3% of cycles; ledger walks 115,763
→ 135,113; seam 42.2% → 47.6%; cycles +1–2% (perf stat -r 7, loadavg
~3.7). The tier-0 time moves into the seam, so on its own the gate fix
is not a win. This supports the §10 order: P2 and P3 change what runs
inside the `for k` region first, then P1 is re-measured.

**What this means for step 4.** Option 1a (count member iterations)
cannot fix this: a `for k` loop of three steps is three iterations under
any count. The evidence the strike rule lacks is *why* the activation
ended. A close at the owner loop's own exit is the region analogue of
P2's natural stop, and the same rule fits it: a natural stop is neutral,
neither strike nor recover. Call this **1e**. Step 4 decides between 1e
and the alternatives on the re-measured shape; nothing is decided here.

**Measurement caveat for §2.** `--jit-stats` implies coverage, and
coverage turns entry patching off (doc 20 §R1-9: "coverage measures the
unpatched machine"). On this bench that changes tiering decisions, not
just timing. With coverage there are 7 `region_decay` gates (all on pc
23) and 5,794 `legacy_thrash` gates on pc 45, against 5,808 and 11,600
without. §2's time split therefore describes the unpatched machine, while
the board times the patched one. The findings above come from runs
without coverage.

**Witness.** `src/interp_nest_test.zig` "doc 64 step 1" runs the kernel at
m = 160000 (smaller m does not saturate the penalty). It asserts that the
`for k` header ends permanently gated, that at least 500 `region_decay`
gates fire (755 today), and that departure closes (10,862) outnumber
`source_outside` closes (753) more than four to one. Step 4 flips the
gate assertions.
