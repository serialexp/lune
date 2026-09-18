# 51 — Variable-trip nest decomposition: layered diagnosis + DOA alias guards

**Status:** diagnosis complete; Fix A (record-time truth), Fix B (konst
canonicalization) and Fix C (doc 52 recurrence-resident promotion —
mechanism landed, payoff ~break-even) done; only the optional
statically-false guard backstop outstanding. Design reviewed by codex (gpt-5.6-sol, thread
`01a0ac91-853c-7b03-b097-a6b7a5abba76`) — see "External review" for the two
material corrections, both folded into the implemented matrix
**Owner:** claude
**Last updated:** 2026-09-18

## Implementation status

### Done

- [x] **Instrument.** `bench/nest_probe.lua` — reduced `advance:4`-shaped
  variable-trip numeric nest (outer `i=1,n`, inner `j=i+1,n`, hash-field
  reads + writeback, n=5, byte-identical output across tier-0 / `--trace` /
  `--jit-native`). Minimal flat-loop repro `bench/alias_doa.lua` for finding
  F1. Neither carries an `-- @bench` header, so `run.py` skips both.
- [x] **Layered diagnosis (doc 50 "Outstanding direction", all 5 layers).**
  Findings F1–F4 below, each with receipts.
- [x] **Dump improvement.** `writeTrace` now prints the trace's konst pool
  (`konsts: k0=… k1=…`) so identity/alias questions about `konst kN` operands
  are answerable from a dump (this diagnosis needed exactly that).

- [x] **Fix A — record-time truth for alias-disambiguation guards
  (recorder).** Landed per the review's matrix: `PendingStore` captures the
  store's record-time table OBJECT identity (header pointer, deliberately
  not `GcHeader.id` — raw test tables share id 0, which would make distinct
  tables falsely forward; the pointer never enters the IR and the equality
  decision is deterministic because object identity is replay-stable) plus
  the observed `astore` index. Hash observed-equal → forward + `guard_false`
  pin; array arms follow the matrix (`.must` different-ref → pin + forward;
  `.may` observed-different → key guard only; `.may` observed-equal →
  abort). Four unit tests (bite-verified: neutering the observed-equal arm
  fails the forward + abort tests) + full-matrix `expectProgram` on the flat
  repro + `expectTier0Equiv` on a mini-nest.
- [x] **Re-measure.** Instrument (`bench/nest_probe.lua`, 2000 calls):
  driver loop 0% → 97.2% traced iterations, replayLedger walks 2004 → 51,
  seam 15.8% → 1.5% of run, wall ~3.3× faster, byte-identical output across
  tiers. Flat repro: 99.9% traced (was 0%, thrash-gated). Full board
  `cross=ok`/`luajit=ok` everywhere; every >5% single-run mover re-checked
  ×3 interleaved against a `just shadow` pre-fix baseline — sparse/scalar/
  field_hash identical pre/post (board drift vs yesterday's TSV, and
  sparse's traces contain zero grid ops so the cb47d95 prover tightening is
  excluded too). nbody itself is unchanged (63.1 ms, 13.1×) — its driver
  loop aborts earlier on `aliased_input get_upval`, the separately-recorded
  next candidate. **(Follow-up 2026-09-18: that candidate landed as doc 53 —
  open-upvalue slot canonicalization; nbody's driver then records the whole
  `advance` call exactly as this doc's instrument predicted, 54.5 → 19.8 ms,
  4.5× LJ.)**

- [x] **Fix B — konst value canonicalization in the optimizer (F3).** Landed
  2026-09-18. Konst instrs and fold results canonicalize by `(value, ty)` to
  one SSA ref; fold results intern against the pool (reusing equal-valued
  entries; existing entries never renumbered or pruned — `sgmatch.aux`/
  `guard_sid.aux`/`InputSeed.source` ride verbatim). One deliberate deviation
  from the review: heap constants key by object identity via `konstKey`'s
  pointer, NOT `GcHeader.id` — raw test-created objects share id 0, so
  id-keying would falsely conflate distinct objects (the same hazard Fix A
  hit); a dedicated test pins two id-0 headers apart. `KonstKey`/`konstKey`
  moved from `trace_recorder.zig` to `trace_ir.zig` (re-exported) — tropt
  must not depend on the recorder per the JIT boundary check, and the pool
  the key describes is trace IR's. Four unit tests, three bite-verified (the
  heap test is a negative — it guards against wrong keying, not absence).
  Measured on the instrument: driver trace pool 37 → 11 entries (all
  unique), body 486 → 441 instrs (−9.3%, unlocked CSE); board NEUTRAL — the
  full-board "-5–9% movers" were re-checked ×3 interleaved against a
  `just shadow` pre-B baseline (`nm`-verified: shadow lacks `resolveFold`)
  and are baseline drift, OLD ≈ NEW on every one.

### Outstanding

- [ ] **Statically-false-guard commit rejection (optional Fix B backstop).**
  Loud tri-state evaluator (proven-pass / proven-fail / unknown) rejecting a
  candidate whose guard provably always fails on constants; would NOT have
  caught F1 (see review note). Not built with Fix B — needs its own
  justification.
- [x] **Fix C — silent-promotion evidence for short bursts (doc 47
  follow-on).** Built as doc 52 (recurrence-resident promotion, P0–P2
  landed through 985110b). Verdict: mechanism sound (nbody's 8-row cycle
  promotes once and stays resident, zero churn), **payoff ~break-even** —
  the "20.5% of run in the walk" figure this fix was sized against was
  wrong (the dormant region's walk was already frozen-cheap, ~1.1k
  cyc/walk); the −30 cyc/walk the resident set saves on the seam is paid
  back as +24 cyc/walk of silent-epilogue exact accounting. See doc 52's
  P2 correction for the numbers and the deferred lean-epilogue lever.

## Why this exists

Doc 50 (Astra review) directed this arc: instrument a small variable-trip
numeric nest and walk the EXISTING `inner root → outer continuation → inner
root` decomposition layer by layer, instead of building new mechanism. This
doc records what each layer actually does on that instrument — and the two
general defects plus one structural gate the walk uncovered.

## The instrument

Same decomposition shape as nbody's `advance`: outer numeric loop carrying
locals, inner loop with shrinking trip count (`j = i+1, n`), hash-field
reads/writes on tables held in an array, writeback after the inner loop,
called 2000× from a driver loop. `--jit-stats` on it reproduces nbody's
profile shape faithfully: inner loop 87% traced, outer loop 0%, driver loop
0%, seam ~16% of cycles.

## Layer-by-layer findings

### Layer 1 — trace topology: the decomposition WORKS structurally

Five traces commit:

| trace | anchor | shape |
|---|---|---|
| t0 | `advance:19` | inner root, 48 instrs, ends `loop` |
| t1 | `advance:44` | outer continuation, 69 instrs, ends `link → 19` — writeback, outer step, next head, re-entry |
| t2 | `advance:44` | replay-side sibling of t1 (hotexit at %57), ends `loop` |
| t3 | `main:34` | driver-loop root: the whole `advance` call inlined with BOTH nests unrolled via `recForPrepLink`'s depth>0 record-through — 616 instrs |
| t4 | `main:34` | side trace at t3's hot exit %197 — same 616-instr shape, same defect |

So the intended cycle exists, and additionally the driver loop records a
whole-call unrolled trace (legitimate current machinery: at `inline_depth >
0` the link path can't work, so `recForPrepLink` record-throughs and
`recForLoop` unrolls, specializing to observed trip counts — with n=5
constant the trips are stable and the trace *should* match every call).

### Layer 2 — entry/guard behaviour: **F1, the DOA alias guard** (the arc's headline)

t3 dispatches and **completes 0 iterations, every time**: 18
`legacy-strike completed=0` → `gate[dispatch:legacy_thrash]`. t4 (the side
trace recorded to rescue the hot exit) has the same property. The driver
loop — 19.3% of the run — is permanently tier-0, with recording,
side-trace and gate churn stacked on top.

The exit is `%197 guard_true(%196 = ne %182, %69)` — a store-forwarding
alias-disambiguation guard (`forwardPendingHashLoad`, "same key, unproven
table identity"). The konst-pool dump proves the defect: `%69 =
aload(aref %45, k9)`, `%182 = aload(aref %45, k14)`, and **k9 = k14 = 2**.
Both refs held `bodies[2]` — the same table — during the very recording
(`bodies[j]` of outer iteration i=1 IS `bodies[i]` of outer iteration
i=2). The recorder emitted `guard_true(ne)` on a condition that was
already false while it recorded. Tier-1a takes the same exit (verified) —
not a native miscompile; the trace contradicts its own recording run and
can never complete.

Root cause: `forwardPendingArrayLoad`'s different-table arm and
`forwardPendingHashLoad`'s same-key/different-table arm emit the identity
guard **without consulting record-time identity** — unlike every other
guard in the recorder, which specializes to the observed direction. (The
key-alias classifier `classifyArrayKeyAlias` does consult values for konst
keys; the table-identity path never does.)

**Generality (Z-6):** a flat single loop reproduces it — no nest at all:

```lua
local a = { v = 0 }
local t = { a, a }
local acc = 0
for i = 1, 100000 do
  t[1].v = t[1].v + 1   -- hstore via t[1]'s SSA ref
  acc = acc + t[2].v    -- hload via t[2]'s SSA ref — same table
end
```

49-instr trace, `completed=0` forever, thrash-gated. Output stays correct
(coarse deopt is sound); the cost is a hot loop pinned to tier-0 plus the
churn. Any program with two SSA paths to one table (aliased rows, shared
sub-objects, `t[i]`/`t[j]` collisions) is exposed. Rule #0.5: this is a
live defect today, independent of nests.

### Layer 3 — exit arming: healthy

`loop_done_linked` (t0 %42 → t1) and `link_terminal` (t1 %68 → t0) both
arm; 7,967 fused native transitions in a 2000-call run; region minted
`kind=cross_trace_cycle members=2 armable=true` — doc 47 Increment B's
owner election works on this shape. Nothing to fix here.

### Layer 4 — silent promotion: **F2, cannot bootstrap from short bursts under the current evidence gate**

Despite the armed, armable cycle: `silent: candidates=0 promotions=0 …`
all zeros. Cause is the production gate in `considerSilentPromotion`:

> only a full forced-yield ledger from a frozen activation is evidence —
> `entries.len == LEDGER_CAP (32)` and last outcome `.yielded`.

The nest's bursts are **8 rows** (4 armed outer iterations × 2 rows + the
terminal), ending in a *natural* deopt: outer trip count is 5, and the
last iteration's zero-trip inner loop fails the continuation link's
first-iteration bounds guard. A burst can never fill 32 rows, so the
evidence class never occurs, so the armed cycle pays the per-row ledger
cost forever: 2,004 `replayLedger` walks × ~1,064 cyc = **15.8% of the
run** — the single largest JIT-side cost on the instrument. Any armed
cycle whose natural burst length is < 32 (short outer loops, i.e. every
nbody-like nest) is in this class.

### Layer 5 — residency + seam accounting

`--jit-stats`, 2000 calls: 39.0% of cycles run as traces (native 23.2% +
seam 15.8%); tier-0 has-trace 13.9% (mostly the DOA driver loop), tier-0
no-trace 15.2%; non-loop 31.9%. Per-iteration: traced ~377 cyc (native
~224 + seam ~153) vs tier-0 ~484. The outer head (`advance:4`) keeps ~2
tier-0 iterations per call — the zero-trip (i=5) and trip-1 (i=4) inner
instances that structurally fall out of the link path. Residency is
guard-starved by F1 and seam-taxed by F2; codegen tightness is not the
bottleneck.

### F3 — optimizer konst duplication (contributing, general)

The recorder's `konst()` dedupes by `(tag, bits)`; the **optimizer's
constant folder does not**: both fold sites append to `out_consts`
unconditionally, and konst instrs are never canonicalized by value. The
unoptimized t3 pool has 5 entries; the optimized pool has 37 with ~13
unique values (`k6=1 k8=1 k9=2 k14=2 …` — the unrolled `for_prep`/
`for_loop` arithmetic folds). Equal-valued constants under distinct refs
defeat CSE downstream for the ops that DO CSE. General optimizer-quality
gap, not nest-specific.

**Correction (codex review):** the original draft claimed konst
canonicalization would collapse the aliased `aref`/`aload` chains and so
"remove the fuel" for F1 in the unrolled trace. That is false — `aref`,
`aload`, and stores are deliberately never CSE'd in `tropt` (memory ops
carry effects), so F3 is fully independent of F1: a worthwhile general
improvement, but it does not touch the alias failure. Collapsing those
chains would need a separately-justified memory-load CSE mechanism,
which nobody is proposing here.

### F4 — abort-side noise (minor, recorded for completeness)

The outer head (`advance:4`) as a root anchor aborts `nyi_opcode` at the
inner `for_prep` by design (LINNER: let the inner spawn its root) and
`cross_frame` at `ret` when recording the last outer iteration —
`record_abort` gating handles both. Working as designed.

## Fix options (Bart picks; Rule #17)

**Fix A (F1) — record-time truth in the disambiguation arms.** Capture the
buffered store's record-time table identity (`GcHeader.id`) — and, for
array stores, its observed integer index — in `PendingStore` (the store
recorder has both in hand); at the load, compare with the loading side's
record-time values and specialize to the observed direction.

For the HASH path (key already proven equal by interned-konst identity):
- table ids differ → `ne` + `guard_true` exactly as today (now guaranteed
  true at record time — honest specialization).
- table ids equal → the store aliases the load's cell: forward the pending
  value (the `.must` semantics — at record time tier-0 has executed the
  store, so the observed loaded value IS the stored value) and guard the
  equality (`ne` + `guard_false`).

For the ARRAY path, table identity alone is NOT cell identity (codex
review correction — equal tables can still have different indices); the
decision combines both dimensions:

| observed table relation | key class / observed values | action |
|---|---|---|
| different | any | `guard(table ≠ store_table)`, continue |
| equal | `.no` | continue — no identity guard needed |
| equal | `.must` | `guard(table = store_table)`, forward |
| equal | `.may`, observed keys differ | `guard(key ≠ store_key)` only — do NOT add a table-equality guard (over-specialization) |
| equal | `.may`, observed keys equal | abort `.store_fwd_ambiguity` (this increment — see below) |

The observed-equal `.may`-key case aborts rather than forwarding behind
key+table equality guards: forwarding is semantically sound but pins an
unproven loop-varying collision, the turnstile the pre-existing policy
comment explicitly warns against. If stable equal-key cases ever matter,
the general answer is teaching `classifyArrayKeyAlias` to PROVE the SSA
relation, not specializing on a record-sample coincidence. Either way the
DOA shape — guarding against the observed state — becomes impossible.

Soundness of the forwarding cases in the coarse-deopt model (per the
review): pending stores are searched newest→oldest (last-writer-wins,
so the first alias found is the newest store) and flushed oldest→newest
below all guards at finalize; if any guard fails, no pending heap store
has executed and coarse deopt replays the whole iteration; if all pass,
the forwarded SSA value equals what the ordered flush makes visible.

**Fix B (F3) — konst canonicalization in `tropt`.** A value-keyed map over
the pool: konst instrs and fold results resolve to a canonical ref; the
pool gains one slot per distinct new value. Review-driven constraints:
- Key scalars by exact `(tag, bits)` (deterministic incl. `-0`/NaN
  payloads); key HEAP constants by `GcHeader.id`, not address — id is the
  language's semantic identity, preserved across replay, and handles
  restored same-id twins (the recorder's `konstKey` address usage is safe
  as a within-heap lookup but the optimizer should make the id invariant
  explicit).
- Do NOT prune or renumber the existing pool: `sgmatch.aux`,
  `guard_sid.aux`, and `InputSeed.source` are pool indices that ride
  unchanged through the current compaction. Intern new fold results
  against existing entries and canonicalize SSA refs only.
- This does NOT collapse aref/aload chains (memory ops are never CSE'd)
  and is independent of F1.

**Follow-up (2026-09-18, as landed):** heap constants key by object identity
(`konstKey`'s pointer), not `GcHeader.id` as the review suggested — the same
id-0 raw-test-object hazard Fix A documented applies here (distinct unlinked
objects share id 0 and would falsely conflate), and within one `optimize()`
call the pointer is exactly as replay-stable as the id (consts are GC roots
for the trace's lifetime; the pointer never enters the emitted trace). A
dedicated test pins two id-0 headers apart. `KonstKey`/`konstKey` moved to
`trace_ir.zig` (re-exported from the recorder) because the JIT boundary check
correctly rejects `tropt → trace_recorder`.

Optional backstop: a guard proven to always FAIL on constants shows the
trace can never complete — reject the candidate at commit (loud: its own
diagnostic + counter, checked on the finalized candidate so opt, no-opt,
and optimizer-fallback paths are all covered), never silently drop.
Requires a tri-state evaluator (proven-pass / proven-fail / unknown) —
today's `guardConstPasses == false` often means "not analyzed", not
"fails". Note (review): this backstop would NOT catch the present F1
trace — the `ne`'s aload operands never fold to constants — so it
complements Fix A, never replaces it.

**Fix C (F2) — an additional silent-promotion evidence class.** E.g. K
consecutive bursts with an identical armed-edge prefix and a natural
terminal (cycle purity across bursts) admit the same candidate path the
full-cap yielded ledger does. This touches doc 17 B-3/B-4's core
drain-pressure argument, so it wants its own careful increment — flagged
here, not designed here. The review adds concrete open questions any
such design must answer first: `replayLedger` processes region lifecycle
BEFORE `considerSilentPromotion`, and a clean `.region_close` demotes
promotions — so a short-natural-terminal design must specify when
evidence is captured, whether the activation is still open at that
point, and how a learned set becomes active before the next short burst
(prefix recognition at burst end may simply promote too late to pay).

Sequencing note (not a recommendation): A, B, and C are mutually
independent; A removes the defect, B is a general optimizer win
(independent of F1 — see the F3 correction), C addresses the seam tax
that remains even with A for cycles that stay decomposed.

## Intended end state (unchanged from doc 50)

Inner trace reused, outer state through continuation φ/writeback, code
size independent of inner trip count. Note the tension surfaced here: for
SMALL FIXED nests the whole-call unrolled driver trace (t3, once F1 is
fixed) covers the nest with zero seam cost, while the decomposed cycle
pays F2's ledger tax — the two mechanisms compete on exactly the nbody
shape. Per the review: for general variable-trip nests the reusable
inner-root/continuation cycle remains the intended architecture; the
driver unroll may stand as a valid secondary optimization for genuinely
small stable-trip calls — current evidence justifies deleting neither.
Post-fix measurement must use ISOLATED A/B runs, not just natural
competition: (i) normal competition, (ii) driver unrolling disabled
(decomposed cycle exposed), (iii) decomposed linking disabled or
separately accounted (driver trace exposed), sweeping stable AND varying
trip counts, and reporting native code size, compile cost, residency,
and seam cycles alongside wall time.

## External review (codex gpt-5.6-sol, 2026-09-17)

Thread `01a0ac91-853c-7b03-b097-a6b7a5abba76`, read-only. Verdicts:
diagnosis strong, F1 real and general; two material corrections, both
folded into the sections above:

1. **Fix A's array case conflated table identity with cell identity** —
   equal tables can still have different indices; the decision must
   combine table relation × key class (matrix now in Fix A), and
   `PendingStore` must capture the store's observed integer index as
   well as its table id. Observed-equal `.may` keys: abort this
   increment (policy continuity with the anti-turnstile comment);
   observed-different keys on the same table get ONLY the key guard.
2. **The F3→F1 connection was false** — `aref`/`aload`/stores are never
   CSE'd in `tropt`, so konst canonicalization cannot collapse the
   aliased chains. F3 stands as an independent general improvement.

Also from the review: forwarding soundness confirmed (newest→oldest
search vs oldest→newest flush below all guards; coarse deopt replays the
iteration if any guard fails); konst canonicalization should key heap
constants by `GcHeader.id` and must not renumber the existing pool
(`sgmatch.aux`/`guard_sid.aux`/`InputSeed.source` are pool indices);
statically-false-guard rejection is a sound loud backstop needing a
tri-state evaluator but would not catch F1 itself; F2's "structurally
unreachable" softened to "cannot bootstrap from short bursts under the
current evidence gate"; Fix C's evidence-class sketch is not yet a
design (region-lifecycle ordering questions recorded above).

## References

- Doc 50 §Outstanding direction (the 5-layer ladder this executes).
- Doc 17 B-3/B-4 (silent promotion evidence), doc 47 Increment B (owner
  election — verified working here).
- `src/trace_recorder.zig` `forwardPendingArrayLoad` /
  `forwardPendingHashLoad` (F1), `src/tropt.zig` fold sites (F3),
  `src/trace_link.zig` `considerSilentPromotion` (F2).
