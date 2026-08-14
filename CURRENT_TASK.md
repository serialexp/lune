# CURRENT_TASK — Exit-branch patching (faithful LuaJIT port), doc 17

## Status 2026-08-14 (LATEST-58) — **B-5 Phases 1–3 LANDED: slot-0 array part is live (`81b73c2` inert prep, `838fd75` THE atomic flip, doc sweep follows). Phase 4 measurement outstanding.**

Doc 18 implemented on Bart's go-ahead. The array part now covers keys
`0..asize-1` identity-mapped (LuaJIT's layout): one unsigned bounds
compare, `t[0]` array-resident, recorder's idx<1 `.bad_type` abort gone.

- **Phase 1 (`81b73c2`)**: inert prep — shared `inArray` helper routed
  through every non-native gate, producer-dispatched `guard_bounds`
  (`.aref` vs `.garow`), `seedAt` wired at old semantics. Byte-identical.
- **Phase 2 (`838fd75`)**: ONE atomic commit, 9 files. array.zig
  `len`→`asize` + identity get/set + `commitFreshLane`-factored
  seedAt{0,1}; table.zig getInt grid `i>=1` gate, set append at
  `key == asize` + fresh {0,1} routing, D7 rehash (unsigned countKey,
  `bin(k)=ceillog2(k+1)`, drain `[old_asize,new_asize)`, OOM rollback
  `asize=k`), length() empty-extent guard; gc 0-based mark walk +
  inflate guards (`asize<=1`, populated slot 0 blocks outer AND rows) +
  deflate slot-0-hole seed (no row down-shift); recorder/tier-1a/native
  append `idx == asize`; nativegen `.aref` drops `sub 1` (garow keeps
  it); keyframe v7 (positional 0-based, restore bulk lane rebuild
  repack+freeze, `ArrayResidentKeyInHash` validation incl. float-0.0);
  pairs walks key 0 first (the signed-off observable change). Full §T
  matrix: unit (bounds edges, seedAt per-lane + OOM, presence 63/64,
  computeArraySize 63/64/65/127/128 boundary overshoot, grid key-0
  blocks, deflation no-down-shift, slot-0 GC edge, v7 validation +
  lane rebuild) + five 8-mode script tests + an f2c resume corpus
  source. **Gate: both builds green (incl. -Djit-debug), seven hashes
  + three repros UNCHANGED (GATE PASS), nsieve-bit --dump-aborts →
  "no recording aborts".**
- **Phase 3**: pins + doc sweep — doc 02 pairs-order pin, doc 03/05
  extent wording, doc 04 v7 entry, doc 14 grid note, schema/trace.json
  description, table.zig module docs, doc 18 checklist ticked.

NEXT: **Phase 4 — measurement per doc 18 §P**: nsieve-bit promotion at
run start + wall-clock, full board both promotion states vs the B-4
baseline (36.7 ms nsieve-bit), memory deltas (append +1 slot; the
accepted power-of-two boundary overshoot), then post-landing codex
review. Then the deferred hash-int recording stays parked.

## Status 2026-08-14 (LATEST-57) — **B-5 REDIRECTED to slot-0 array part (Bart's call); design doc 18 written + ACCEPTED by both reviewers. Awaiting implementation go-ahead.**

Bart's direction on the B-5 recording gap: instead of hash-part
integer-key recording, extend the internal array part by one slot so
key 0 is array-resident — LuaJIT's exact layout (`inarray = (MSize)key
< asize`, non-inclusive sizes, slot 0 allocated; verified in
`lj_tab.{h,c}`). General fix per Z-6: every 0-indexing program gets the
fast path AND stops poisoning trace recording (the abort+backoff chain
of §B4.8). Hash-int recording demoted to a deferred follow-up (only
cover for negative/sparse keys).

Work done this arc:

- **Grounding**: very-thorough 8-group inventory of every 1-based
  assumption (Explore agent; array.zig conversion layer, table.zig
  routing/rehash, keyframeser positional wire format, recorder,
  nativegen address math, irinterp, stdlib/base nextStep, gc walks,
  rowView) — six cross-cutting surprises, the `len` multi-overload
  being the crux. LuaJIT reference read (countint/countarray/
  bestasize/rehashtab).
- **docs/design/18-slot0-array-part.md** written per the design-doc
  skill: D1 identity mapping + conditional field contract (scalar
  `asize` vs grid row count) + exact `@bitCast` unsigned helper; D2
  asize disambiguation incl. the five `get(i+1)` walk sites; D2a
  `seedAt` fresh-seed primitive (non-nil keys {0,1} only); D3
  producer-dispatched `guard_bounds` + atomic-flip mandate; D4
  keyframe v6→v7 + restore bulk lane rebuild (repack+frozen) +
  normalized-key validation; D5 pairs-order change (deterministic,
  pinned); D6 grids stay 1-based, deflate-on-key-0, guarded inflation;
  D7 complete sizing derivation (bin(k)=ceillog2(k+1), memory honesty
  at power-of-two boundaries, drain rollback asize=k); §T cross-tier
  test matrix; §P frozen predictions (stdout hashes UNCHANGED is a
  prediction — any change is a defect).
- **Reviews to acceptance**: codex gpt-5.6-sol rounds 1–3
  (REVISE ×2 → APPROVE; 5 BLOCKER + 4 MAJOR + 4 MINOR + NIT across
  rounds, all folded — §R1/§R2/§R3 records in doc 18) + Antigravity
  rounds 1–2 (REVISE with 7 blockers → CONFIRM, re-verifying each).
  Convergent round-1 finding worth remembering: the naive Phase split
  would have been wrong-address CORRUPTION, not trace-shape drift —
  the flip must be atomic across layout + all three tiers + walks.

NEXT (pending Bart): implement per doc 18 phasing — Phase 1 inert prep
(producer dispatch, inArray helper, seedAt), Phase 2 the atomic flip,
Phase 3 pins/docs, Phase 4 measurement (§P: nsieve-bit aborts → 0,
promotion at run start, wall toward LuaJIT scale; board within noise).

## Status 2026-08-14 (LATEST-56) — **B-4 REFRAMED, DESIGNED, LANDED (positional loop-done resolution); predictions failed on nsieve-bit; TRUE root cause found = B-5 (`idx < 1` recording abort).**

Full arc in doc 17 §Part B-4 (§B4.1–§B4.8). The compressed story:

1. **Original premise refuted by ablation.** B-4 was minted as "probation
   for the nsieve-bit t=5 mega-trace". A maxrecord=100 ablation binary
   (only t=5 aborts) is **+31.3% slower** — t=5 is the automaton's scan
   segment (`.link -> 41`), net-profitable. The B-2b-era condemnation was
   measured under `--jit-stats` accounting overhead (74.9 vs 36.0 ms).
   Probation NOT built (Rule Z-6). §B4.1.
2. **Reframed on measurement**: 27,554 `break_burst` events at the
   terminal `.loop_done_linked` replay directive, which only consulted
   `cursor.cont` and never looked up continuations positionally at
   `post_pc`. Designed D1'–D4' (§B4.3/§B4.7): canonical selector
   `resolveLoopDoneCont(proto, post_pc, regs_or_null)` over the P-G
   predicate — ranking hit-count desc → lowest id, `.unsupported`
   skip-not-shadow, canonical arm probe order (D4'), `regs` fingerprint
   preference for the RUN target only (arm stays cache-pure).
   Three codex `gpt-5.6-sol` rounds: REVISE (BLOCKER + 2 MAJOR) →
   REVISE (new MAJOR = probe-order memoization hazard → D4') → ACCEPT.
3. **Landed** (src/trace.zig): selector + `armLoopDoneLink` resolves
   internally (`armLoopDoneLinkTo` keeps re-validation + arm) + terminal
   positional fallback + `regs: ?RegWindow` threaded through
   `replayLedgerFrom`/`replayLedger`/`replayLedgerSuffix`/
   `driveSilentBurst`/`drainSilentResult` (/tmp/b4_thread_regs.py,
   dry-run first). New unit test pins unsupported-skip, id tie-break,
   arm-vs-run divergence, R6 no-re-arm, cleared-cache → break_burst.
   Gates: `just test` both builds green; seven hashes + three repros PASS.
4. **Measured: predictions 1–3 FAILED; wall NEUTRAL.** Still 27,554
   terminal failures (now "no eligible continuation"); interleaved A/B
   vs HEAD: nsieve-bit 36.9→36.7 ms (−0.4%), nsieve 9 50.3→50.7 ms
   (+0.8%) — noise. A permanent jitdbg probe in the failure path proved
   **zero traces anchored at post-PC 58 during all events** — the
   mechanism is correct but had nothing to select. Landed anyway: it is
   the general contract three reviewers accepted, neutral where it can't
   fire, and removes avoidable break_bursts wherever a positional
   continuation exists.
5. **True root cause (open, doc 17 Outstanding bullet B-5).**
   `--dump-aborts`: recorder aborts `.bad_type` at the `get_index`/
   `set_index` bounds check `idx < 1` (trace.zig ~11290) — nsieve-bit's
   `p[i>>6]` is `p[0]` for `i < 64` and its init loop is `for i=0,…`.
   Every recording that captures a small-`i` iteration dies (24× anchor
   :41, 5× :58, 6× :7, 1× :17); gate exponential backoff (128→65536,
   max_strikes 6) then starves the pc-58 scan trace until log line
   ~220k/349k — exactly where break_bursts stop. LuaJIT is immune (0-based
   array part). **General gap: the recorder cannot trace index-0/hash-part
   table access.** Options to ground next: hash-part recording, array-part
   indexing revisit, softer gate escalation for data-transient aborts.

Board unchanged: nsieve 1.0× LuaJIT, sieve_int 1.0×, pi_leibniz 2.7×,
nsieve-bit 6.6× (blocked on B-5), grid_matmul 5.6×, scimark 23–73×.

## Status 2026-08-14 (LATEST-55) — **B-3d.4 frozen measurement DONE → B-3d COMPLETE. nsieve is at LuaJIT PARITY (1.0×).**

The measurement protocol frozen in §B3.18 ran on the e56252f tree:

- **Predictions verified** (nsieve 9, release jit-stats): suffix drains
  3411 → 13 against 174 budget exhaustions (bursts now end almost
  exclusively by budget); steering seam 30.6% → 6.2% of run (replayLedger
  12,427 → 780 walks, wall 72.2 → ~49–53 ms); tier-0-has-trace by
  iteration count 12,468 → 2,354. The residual tier-0-has-trace *time*
  bucket (~13.8% of run) is 78 interpreted warm-up iterations of the
  outer `nsieve:4` loop at ~370k cyc each — nested-work attribution, not
  a seam: the former feedstock anchors nsieve:14/24 run 98.9–99.3%
  traced by time.
- **Budget re-sweep** (`--trace-silent-budget` 1024…2^30, nsieve 11,
  best-of-5): flat within noise, output byte-identical at every value.
  The knob stays a non-lever — now because the seam it metered is gone.
- **Full board, both promotion states** (bench/results/20260814-121953
  ON, 20260814-122259 OFF): promotion is worth nsieve 2.1× → **1.0×
  LuaJIT (13.6 vs 13.5 ms — parity)**, sieve_int 2.1× → 1.0×,
  pi_leibniz 3.7× → 2.7×; every other row within noise, no regressions.
  The one correctness flag (str_manip luajit=ERR) is pre-existing on the
  LuaJIT side (same flag in both prior boards).
- Tree restored to promotion ON, `just release` rebuilt, hashgate PASS.

The owed codex `gpt-5.6-sol` review ran same day (quota returned early
2026-08-14): **APPROVE**, zero BLOCKER/MAJOR/MINOR. It independently
verified: every mutation path (membership growth, changed re-arms, disarms,
trace retirement, defs mutation, region close, activation change, unfreeze,
cache/state teardown) reaches demotion; identical non-sibling re-arms
short-circuit while sibling re-arms keep latch balance; edges/summary/
metadata transfer ownership only after successful publication and are freed
exactly once; R1 one-set-per-region enforced plus exclusive physical-exit
ownership; D4 sound from `emitSilentEpilogue`'s write order (terminal
metadata + ordinal precede the `silent_transitions` bump, no route back
into silence after reporting starts). One NIT — residual "cycle"
locals/comments in the migrated code — fixed in 3f77f34 (42 lines, script
/tmp/b3d_nit_rename.py dry-run first; tests both builds + hashgate PASS).
**B-3d is CLOSED.** Recorded next candidates: B-4 trace-quality probation
(nsieve-bit at 6.6×), grid_matmul 5.6×, scimark family (untraced, 23–73×).

## Status 2026-08-14 (LATEST-54) — **B-3d.2+.3 LANDED MERGED (e56252f): set candidacy + measured drain. Next: B-3d.4 frozen measurement.**

The core of B-3d, landed as ONE gated change. The plan's .2/.3 split proved
unlandable: the first set-shaped promotion panics `driveSilentBurst`'s
ring-successor assert and `computeSiblingReturnDistances`' revolution proof,
so .2 alone crashes the nsieve hashgate. Grammar and drain moved together.

What changed (src/trace.zig only, +693/−407):

- **D1 candidacy** — `detectPromotableSet` (replaces `detectPhysicalCycle`):
  candidate = every armed, patch-pointed (`promotedEdgeFromLink`), un-owned,
  region-member edge at the observation instant, insertion-sorted by
  (parent id, exit); the forced-yield ledger is validated as *evidence*
  (kind-exact via `rowPatchKind`, per-adjacent-pair child match, final row
  exempt) but no longer defines the unit — zero-evidence member edges
  promote on registry proof (R5(c)).
- **D2 storage** — `PromotedCycle`→`PromotedSet` (mechanical sweep via
  /tmp/b3d2_rename.py, 124 word-boundary hits); `sibling_return_distance`
  deleted along with `computeSiblingReturnDistances`.
- **D3 measurement** — `silentSiblingEvidence` is now a method: sibling
  `returned_to_parent` := a strictly-later firing of any live cell with the
  same parent id (R3: a self-edge's own firing does NOT count), OR a suffix
  row with `row.id == parent id` (R4: arrival ownership is `row.id`).
- **D4 terminal** — `driveSilentBurst` resolves entry/terminal cells by
  measured ordinals; ring-successor assert replaced by a terminal assert
  (`last_set` cell owns `silent_transitions`) that runs BEFORE the summary
  mailbox clear; R5(a)/(b) comment-asserts at the expansion loop and the
  two-phase drain boundary.
- **R1 one-set-per-region** — `promoteSet` rejects
  `error.PromotionRegionOwned` (counter `region_owned`; the dead
  `already_owned` reject retired — owned edges are excluded from candidacy
  and surface as `open_chain`); arming a NEW armable member edge of an
  owning region demotes via `DemotionReason.membership_growth` at the
  `armNativeLink` funnel (`noteMembershipGrowth`, both re-arm and fresh-arm
  paths, after successful arm only).
- **R7 shared predicate** — `edgeMemberOfRegion(edge, region_id,
  require_bridge_stamp)` used by candidacy (strict), promoteSet
  re-validation (strict), and the growth trigger (stamp=false: it runs
  before `tryArmRegionBridge`'s restamp; wider is safe — worst case an
  extra demote-and-regrow).
- **Tests migrated set-shaped, never deleted** (871 green): candidacy
  accept/reject matrix (rotation-independence, footprint shrink, foreign
  region, non-member rows, kind mismatch, adjacent-pair break, over-cap,
  region-owned), repeated-parent measured-terminal pins (R3/R4), M1 test
  now also pins `membership_growth` firing on a sibling publish over a live
  set, and a NEW 4-edge repeated-parent set (parent with two armable exits
  — the shape ring grammar structurally cannot promote) promoted from
  partial evidence then drained from an out-of-order rowless burst image,
  resume contract from the measured terminal.

Gates: `just test` green both builds; hashgate seven hashes + three repros
PASS, promotion ON and OFF (default flip/restore). Telemetry (nsieve N=7,
dbg): promoted units become set-shaped (lens 6/7/8 vs 2-edge rings),
**suffix drains 3411 → 13**, bursts 3557 → 187 (~19× longer each),
transitions 612900 → 721685 (+17.7%), budget exhaustions 146 → 174,
`growth=0` on this suite (regrowth via unfreeze/trace demotions).
nsieve 9 release: **steering seam 30.6% → 5.7% of run**, replayLedger
walks 12,427 → 780, wall 72.2 → 53.4 ms (−26%), native execution 57.2% →
73.8%. The B-3d seam thesis measured true.

Remaining: **B-3d.4** frozen measurement (budget re-sweep now that bursts
end mainly by budget, full `just bench` board, both promotion states,
telemetry sanity, doc records). Owed: codex `gpt-5.6-sol` review of the
whole B-3d design+implementation when quota returns 2026-08-20.

## Status 2026-08-14 (LATEST-53) — **B-3d.1 funnel hygiene LANDED (63dd733). Next: B-3d.2 (set candidacy + promotion).**

First gated sub-step of the accepted B-3d landing plan (doc §B3.18):

- **R6 identical-re-arm short-circuit** in `armNativeLink`'s re-arm branch:
  return true immediately when child, kind, AND slot target are all unchanged
  — identical convergence re-arms (2c-E sites 3/4) no longer demote owned
  sets via `prepareSlotMutation`. The target compare is load-bearing (a
  recompiled child at a new address must still take the mutation path).
  `.sibling_handoff` is excluded: `publishSiblingArm` bumps the latch +1
  after a true return, balanced only by the re-arm branch's
  `clearSiblingLatch` — the short-circuit would leak it (pinned by the
  extended sibling-latch test asserting `sibling_arms` stays 1 on a double
  publish).
- **R2 demote-on-unfreeze** in `flushRegionWindow`: the low-yield unfreeze
  now calls `demotePromotionsForRegionReason(key, .unfreeze)` in the same
  act (new `DemotionReason.unfreeze` + counter + dump line), closing the
  pre-existing Rule-#0.5 panic path (unfreeze with live patches →
  `driveSilentBurst` frozen-accumulator panic on next drain). Covers both
  the direct depth-0 path and the depth>0 queued/`applyPendingDisarms` path
  (new test pins both).
- Tests: slot-mutation test reworked (identical re-arm asserts NO demote;
  changed-relation re-arm to a new trace still demotes + unpatches);
  new "low-yield unfreeze demotes in the same act" test.

Gates: `just test` green both builds; hashgate seven hashes + three repros
PASS with promotion ON and OFF (default flipped for the OFF leg, restored).
Telemetry (nsieve N=7, -Djit-debug): demotions re-attribute
`region-close 3→1, unfreeze 0→2` (total still 4), every other counter
byte-identical (candidates=16 promotions=4 bursts=3557 transitions=612900
budget=146 barren=0 suffix=3411) — proof the R2 window was genuinely live
at activation end, and that demoting earlier is behavior-equivalent here.

Owed: codex `gpt-5.6-sol` review of the whole B-3d design+implementation
when quota returns 2026-08-20, before the final landing gate (B-3d.4).

## Status 2026-08-14 (LATEST-52) — **B-3d set-promotion design ACCEPTED (doc §B3.16–§B3.18) after three adversarial rounds. Next: land B-3d.1 (funnel hygiene).**

B-3d generalizes silent promotion from exact detected rings to the frozen
region's armed-edge SET, so non-ring automata (the nsieve:14 sibling triangle)
run silent regardless of firing order — the ~40%-of-run drain seam from
LATEST-51. Round-6's per-cell measurement already de-ring-ified the
accounting; the design closes the three remaining ring dependencies with
measured, order-free replacements.

Review history (Antigravity + independent general-purpose agent each round;
codex quota-blocked until Aug 20, a gpt-5.6-sol pass owed before final
landing): round 1 REVISE (BLOCKER: one-set-per-region unenforced/broken by
growth; MAJORs: trigger can't see suffix ledgers, barren-unfreeze→live-patch
panic, PROVENANCE_VERDICT_CAP arithmetic; Antigravity's O3 answer refuted
against the source) → round 2 revision (R1 demote-and-regrow + enforced
invariant, R2 demote-on-unfreeze, per-adjacent-pair child-match, D3 self-edge
correction) → round 2 REVISE ×2 convergent (same MAJOR both reviewers: owned
identical re-arms demote via prepareSlotMutation — the stale "harmless
supersede" convergence arms) → round 3 revision (R6 short-circuit at the
armNativeLink funnel, `.sibling_handoff` excluded for latch balance; R7
wording/scope) → confirmation ACCEPT ×2.

Two pre-existing bugs (Rule #0.5) confirmed by both reviewers, fixed by
construction: (1) barren-exhaustion → `flushRegionWindow` unfreeze leaves
patches live → next drain panics on the frozen check (unreached on the suite,
reachable by construction); (2) ring `returned_to_parent` bounds against the
CALL-GLOBAL transition count, so a second live cycle's firings can fake a
return → false strike (D3's parent-specific measured arrival eliminates it).

Landing plan (each sub-step behind full gates, both promotion states):
**B-3d.1** funnel hygiene (R6 short-circuit + R2 demote-on-unfreeze —
independently landable, fixes the latent bugs); **B-3d.2** set candidacy +
promotion (D1 grammar, promoteSet, membership_growth, storage rename);
**B-3d.3** drain generalization (D3/D4 measured evidence + test migration);
**B-3d.4** frozen measurement (predicted: seam 30.6% → single digits,
tier-0-has-trace ~0, budget knob live again).

## Status 2026-08-14 (LATEST-51) — **B-3c DONE (commit 2f3c929, doc §B3.15): the budget is a ~1% lever; the real seam feedstock is the NON-RING sibling automaton → proposed B-3d set-promotion.**

The prescribed sweep + re-profile ran and answered B-3c's own question in the
negative. Landed: `--trace-silent-budget <N>` CLI override (output
byte-identical at N=1/1024/2^32/default) + two permanent jitdbg probes
(`silent-promote` edge lists, `suffix-row` suffix-ledger composition). Gates:
`just test` green in normal and `-Djit-debug` builds; seven-hash + three-repro
GATE PASS on ReleaseFast.

Findings (all in doc 17 §B3.15):

- **Budget: ~1%.** 534 exhaustions ≈ 4% of ~12.9k drains; unbounding removes
  exactly them (walks 12,960 → 12,427; 57.34 → 56.73 ms interleaved
  min-of-55 at nsieve 9). Default stays 4096. But note 534 × 4096 ≈ 99% of
  all silent TRANSITIONS — the hot cycles always run to the cap; the other
  12.3k bursts average ~1.5.
- **What ends bursts: ledger-full suffix drains.** nsieve:14 is three sibling
  traces t3/t4/t5 (sibling_handoff deopts). The live promotion covers the
  5-ring clear→cont→t4→t3→t4→clear; the suffix rows are exactly the OTHER
  triangle edges (t3.ei12 ≈34.0k, t4.ei18 ≈37.4k, t5.ei14 ≈37.4k at N=7).
  Unequal counts ⇒ the firing order is data-dependent, NOT a fixed ring ⇒
  `detectPhysicalCycle`'s exact-repeat grammar can structurally never promote
  it. Expressiveness limit, not tuning.
- **Drain cost ≈ 10k cyc each ≈ 40% of the run.** Suffix walk ~7.8k cyc PLUS
  one tier-0 re-entry iteration ~2.3k cyc (`tier-0, has-trace` = 12,468 iters
  ≈ drain count exactly). The 30.6% seam bucket and the 9.0% tier-0-has-trace
  bucket are the same phenomenon.
- **nsieve:14 "heavy codegen" (task #82) resolved: it isn't.** trc-c/it 18.9
  is the seam billed to the first replayed hop; the composite-spin IR is ~10
  tight ops, ~7.7 cyc/it native after seam subtraction.

**Identified next general lever (NOT yet mandated): B-3d set-promotion** —
promote the frozen region's armed-edge SET instead of exact rings. Round-6
per-cell measurement (`firings`/`last_ordinal`/`silent_last_cell`) already
de-ring-ified the accounting; the ring is still load-bearing for metadata
grouping, sibling-evidence return distances, and the terminal-resume successor
assert. Design-first with review rounds. Alternative smaller lever: cheapen
the drain round-trip (skip the tier-0 re-entry iteration after a drain).

## Status 2026-08-14 (LATEST-50) — **B-3b LANDED: the seam is closed. nsieve 1.1× LuaJIT (was 1.9×), sieve_int 1.0× (was 1.5×). Commit 8942ef6.**

Promoted cycles now transition trace→trace natively without appending ledger
rows; Zig expands a per-kind summary that is accounting-equivalent to the
row-by-row replay it replaced. Landed in four gated sub-steps (b.1 `ReplayCursor`
extraction, b.2 promotion registry + patch lifetime, b.3 the flip, b.4 bridge
promotion), then hardened over SIX adversarial review rounds.

Measured (nsieve N=9): replay rows **2,547,824 → 394,179**; native `[JIT]`
43.0% → 50.5%; the 46.2% Zig seam that motivated Part B is gone as a dominant
cost. Board: **nsieve 24.4 → 16.2 ms (1.1× LuaJIT)**, **sieve_int 11.3 → 7.5 ms
(1.0×)**. Telemetry: 16 candidates, 4 promotions, 2,205,469 silent transitions,
12,824 bursts, 534 budget exhaustions, 0 barren, rejects all zero except
`open=1`.

Rounds 1–5 (codex `gpt-5.6-sol`) found eleven soundness defects, all fixed
without weakening a check or disabling an edge kind. Round 6 ran on Antigravity
+ an independent agent (codex hit its usage limit until Aug 20) and found three,
recorded in doc 17 §B3.14:

1. **BLOCKER — burst endpoints were reconstructed, not measured.**
   `(first_phase + transitions ± 1) mod len` assumes every silent transition is
   the next phase of ONE ring where each trace owns exactly ONE phase. Neither
   is enforced: `computeSiblingReturnDistances` explicitly supports
   repeated-parent rings, and several rings can be live at once, all
   incrementing the same call-global `silent_transitions`. A wrong terminal edge
   ⇒ wrong tier-0 resume PC (the A-viii "missing prime 307" class) + wrong
   committed count, silently. Fixed by making native publish what happened:
   per-cell `firings`/`last_ordinal` + `NativeResult.silent_last_cell`, a
   `silentCellOwner` resolver for both endpoints, a release-checked
   `Σ firings == silent_transitions` invariant, and expansion/clearing over
   every live cycle. This corrects §B3.13(5) of the accepted design.
2. **Sibling evidence indexed an edge's FIRST firing**, so progress preceding a
   final barren firing masked a strike. Now indexed to the most recent firing;
   the return-to-parent bound moved to total transitions (a row is appended by
   every materialized transition, including the unfollowed final one).
3. **The ≤1-row provenance settle was in the wrong function** — double-settling
   the driveChain seed while leaving `driveDispatcherSilentResult`, the origin
   its own comment names, unsettled.

Gates: 869 tests green in both the normal and `-Djit-debug` builds; all seven
frozen stdout hashes + the three soundness repros match with
`silent_promotion_enabled` **both ON and OFF**; telemetry byte-identical across
round 6; interleaved min-of-11 ReleaseFast A/B neutral.

**Two measurement traps that cost real time this session — read before timing
anything.** (a) `just test` and `zig build test` leave a **Debug**
`zig-out/bin/lune`; a binary copied after them times ~3× slow and produces
garbage A/Bs (this fooled me twice — the tell was `-Djit-debug` telemetry being
byte-identical, i.e. no tiering change could explain the delta). Always re-run
`just release` before copying. (b) A single wall-clock board row can be an
outlier: `pi_leibniz` read 39.3 ms on one board and 12.8 ms on the next while
`lune_jit_execns` stayed at 38.8 M — identical work. Cross-check the exec-ns
column before believing a wall delta.

Open next: **B-3c** budget tune (534 of 12,824 bursts exhaust `silent_budget =
4096`); **B-4** deterministic trace-quality probation (nsieve-bit still 36.3 ms,
6.3× LuaJIT). Untracked bench boards remain in `bench/results/` (uncommitted by
choice). The `str_manip` ok/ERR board flag is pre-existing and unrelated (the
LuaJIT leg calls an unavailable `string.codepoint`).

## Status 2026-08-13 (LATEST-49) — **B-3a substrate LANDED (flag off, all gates green, seam coverage 73.5% ≥ 70% gate). Next: B-3b runtime promotion.**

B-3a reverse-authored (Codex implemented on thread
019ffa90-924c-7520-85ae-05865ffded52, Claude reviewed the full diff + ran
every gate). What landed: per-kind patch points (recorded `E9` for ordinary
`.deopt` mini-stubs, excluding loop-done guards and composite-bridge
candidates; `nop5` windows between materialization and reporting at
`.link_terminal`/`.loop_done_linked`; nothing for `.region_bridge`),
out-of-line per-kind silent epilogues implementing the §B3.11(1) summary
transforms + §B3.13 absolute barren compare + `silent_cum` + first-cell
ownership (UNREACHABLE: metadata cells null, no patch applied anywhere),
`McodeArena.patchRel32`/`patchWindow` with page-generation validation
(live-allocation records; free-list reuse gets a fresh generation), exact
original-bytes restore, RX-restore-failure `@panic`; frozen
`NativeResult`/`ExecResult` silent ABI tail appended after `ledger_outcome`
with a comptime layout oracle (`NativeResultLedgerLayout`); the
`prepareSlotMutation`/`commitSlotMutation` two-phase funnel over all five
physical slot-write sites (armNativeLink fresh + re-arm,
resetLinksTouching, disarmAllLinks, disarmLinkAt) preserving
registry-before-slot ordering; `prepareNativeEntry` (B-3b sweep hook) at
all four native-call origins; `closeRegion` → `demotePromotionsForRegion`
hook; `dbgNoteReplayRow` seam partition counter.

Gates: `just test` + `-Djit-debug` green (857 lib tests). Seven stdout
hashes identical to ba29ff2 AND to the frozen references — after
re-tripping the LATEST-47 trap myself: nsieve/nbody are at
`bench/luajit/*.lua` (NOT `bench/*.lua`), and piping `2>&1` into sha256sum
hashes the FileNotFound message, which "matches" across binaries. Hash
stdout only, and confirm the program path exists first. Soundness repros
109/109/18135. Flag-off timing: sieve_int min-of-60 +0.8% (earlier
min-of-21 runs scattered +0.25…+4.5% — machine variance), nsieve 9 and
pi_leibniz within noise → "identical modulo NOP" gate passes. Seam
telemetry at nsieve 9: **bridge-free-closed = 1,872,025 of 2,547,824 rows
= 73.5% ≥ 70%** — B-3b proceeds as designed, no re-scope.

Review nits (fine for B-3a, revisit in B-3b): `movMemImm32` stores to u64
silent fields (sound little-endian for the small staged values; worth a
widening or comment); `dbgNoteReplayRow` does a per-row bounded DFS (64
nodes) — double-gated behind jitdbg+debug_log so zero production cost.

---

## Status 2026-08-13 (LATEST-48) — **B-3 design ACCEPTED after five codex review rounds (§B3.6–§B3.13 in doc 17). Next: B-3a substrate implementation.**

Bart: "Ok, lets go for the full B-3 thing. It's the biggest lever we have for
parity." Target: the measured 46.2% Zig seam at nsieve N=9 (replayLedger
29.24% + driveDispatcherLedger 14.71%; native 43.0%, tier-0 4.3%).

Design went through FIVE codex `gpt-5.6-sol` rounds (thread
019ffa79-75fe-77a2-8972-470c49f2bd28), REJECT ×4 then ACCEPT. Every round is
recorded verbatim-in-spirit in doc 17 (§B3.6/8/10/12 findings, §B3.7/9/11/13
revisions). The three round-1 mistakes that shaped everything: (a) one shared
patch tail — but the four chain-source kinds have different materialization
shapes (ordinary `.deopt` has an existing `E9` to swap; `.link_terminal`/
`.loop_done_linked` fall through into `emitLedgerAppend` and need a 5-byte
NOP window; `.region_bridge` is v1-ineligible); (b) silent terminals routed
through `replayLedger`'s grammar — replaced by `driveSilentBurst` +
`replayLedgerSuffix` over an explicit `ReplayCursor`, with terminals owned
end-to-end and release-panic on impossible grammar; (c) accounting
precomputed from observed locals — WRONG, locals are runtime quantities
(`e.cum - prev_cum`); replaced by dynamic per-kind native summary cells
`{region_work, selection_work, qualifying_rows}` mirroring replayLedger's
kind switch (trace.zig:4920), an absolute-count barren budget striking AT
the boundary, and a `silent_cum` baseline for the suffix.

Other load-bearing contracts pinned by review: per-exit metadata-cell
transport (compile-time stable cell, promotion publishes metadata → cell →
patch LAST; demotion restores code FIRST); activation binding — promotion is
RegionKey-local while the patch is physical, so v1 carries a STATIC
promotion predicate over the verified same-activation edge shapes
(trace.zig:2671/7810/7820+/4490+), a conservative global pre-entry sweep
demoting any promotion whose RegionKey ≠ active key, and a direct
`closeRegion` demotion hook; ALL `CompiledTrace.slots[]` writes (incl.
trace.zig:7758/7871/7912/7948) move behind two-phase
`prepareSlotMutation`/`commitSlotMutation` preserving armNativeLink's
registry-before-slot OOM order; drain at all FOUR native-call origins
(direct dispatcher, driveChain seed, driveBurstCore call A/B); ABI tail
appended after `ledger_outcome`: silent_active, silent_transitions,
silent_budget, barren_budget, silent_cell, cur_zero_run, silent_cum (all
u64, comptime @offsetOf asserts).

Landing plan: **B-3a** substrate — per-kind patch points, out-of-line silent
epilogues UNREACHABLE until patched, metadata cells, frozen ABI,
patchRel32/patchWindow validation suite; flag off; gates = identical-
modulo-NOP bench run + a `-Djit-debug` seam-coverage counter proving ≥70%
of the ~1.7M rows sit in a bridge-free closed armed subcycle (if that fails,
B-3b is re-scoped BEFORE implementation). **B-3b** runtime promotion:
PromotedCycle + closure detector + driveSilentBurst + summaries + demotion
transaction, full frozen measurement protocol. **B-3c** budget sweep.

Still open for Bart (carried from LATEST-47): nsieve-bit +17% ship-vs-revert
(B-4 filed); two seam-round-2 MINORs; stray untracked
bench/results/20260813-140214-84c86bc.tsv.

---

## Status 2026-08-13 (LATEST-47) — **Part B B-1 + B-2 LANDED: the hotexit misroute is fixed, the provenance arm closes the full native cycle. nsieve walks ÷6.1, nsieve 9 −21%, sieve_int −20% (board: nsieve 1.9× LJ was 2.7×, sieve_int 1.5× was 2.4×). KNOWN REGRESSION nsieve-bit +17% → follow-up B-4 (trace-quality probation).**

### What landed (Bart: "Ok, go and continue with B") — commits 5e5b7a4 (B-1), c8256fa (B-2a), this commit (B-2b)

Full narrative + the five landing deltas are in doc 17 §B.7; short form:

1. **B-1** — `noteTakenExit` routes on the POSITIVE branch property (`jmp_if_*`
   source); zero-trip `for_prep` guards feed the generic side want. Substrate
   only (telemetry unmoved until B-2).
2. **B-2a** — ProvenanceEdge storage + shared `publishSiblingArm` + lifecycle
   wrappers, flip OFF, byte-identical.
3. **B-2b** — the flip + the deltas found while landing:
   - drain compiles the child on demand via `nativeFor` (a provenance child is
     never dispatcher-selected — waiting for lazy `.compiled` deadlocks
     publication; `.unsupported` deletes the edge per §B.6(5));
   - `noteSiblingTerminal` fires at ANY local count (zero-progress was §S's
     discovery heuristic, not coherence; the gate blocked every cycle's
     CLOSING arm — with it, nsieve walks did not move at all);
   - `provenance_arms_pending` event-driven drain gate (the unconditional
     per-walk edge×armed_links scan measured 5.7% of nsieve-bit wall; set at
     edge append / any physical disarm / in-place sibling re-arm; settles
     after a pass with no transient decline);
   - `armNativeLink` in-place re-arm now releases the displaced sibling latch
     (codex post-landing blocker; sibling→ordinary→sibling→disarm test pins
     1→0→1→0);
   - B-2b can supersede M1 discovery → doc-16 Phase-2 test signals generalize
     to `prime_side_chain_follows + sibling_handoff_fused` and
     `native_source_link_arms + sibling_handoff_arms`.
4. **build.zig: `-Dtest-filter=<substr>`** wired into both test steps
   (verified against the pinned stdlib `Build.TestOptions.filters`).

### Measured (interleaved min-of-21, vs B-1 binary /tmp/lune-B1)

nsieve 9: 109→86ms (−21%); nsieve 7 −18%; nsieve 3 −19%; sieve_int −20%;
walks at N=9: 330,206 → 53,746 (53,625 at LEDGER_CAP — the full native cycle
scan→cont→skip→scan formed; the ~45k prediction held). All SEVEN output
hashes identical (NB: bench programs live at `bench/*.lua`, NOT
`bench/programs/` — a wrong path hashes the error message and "matches" on
all binaries); aviii/aviii-which=109, floatlink=18135; 853/853 tests both
builds.

### KNOWN REGRESSION — nsieve-bit 6: 31→36ms (+17%), commit shipped anyway (codex recommendation)

Isolated: a relax-only build (arming off) is neutral — the arming causes both
the wins and this. Mechanics (§B.7): the armed cycle halves nsieve-bit's walk
count but (a) pushes more rows through the replayLedger steering grammar
(~14% combined replay+drive in perf), and (b) a second-order hotness shift
lets a low-quality 247-instr root continuation trace (t=5 at pc=58) record
and link; it normal-deopts ~11.7k times at four scattered exits (ei
56/98/140/182), each costing wasted native work + a tier-0 deopt-replay
re-run. Codex verdict: the provenance edges are locally successful; disarming
them for exposing a poor ROOT trace would misattribute the cost. **Follow-up
= B-4 deterministic trace-quality probation** (score native entries against
committed work / normal-deopt frequency / exit dispersion / size; gate or
retire large low-yield roots — general, benchmark-agnostic).

### Open for Bart

- The nsieve-bit +17% ship-vs-block call above was made per the reviewer's
  recommendation — say the word and B-2b flips off (`provenance_arming_enabled`,
  one const) or reverts cleanly.
- Still unanswered from LATEST-46: the two seam-round-2 MINORs (u32 cache_gen
  wrap; hit_count dependence if max_traces_per_anchor >8) and the stray
  untracked bench/results/20260813-140214-84c86bc.tsv.

## Status 2026-08-13 (LATEST-46) — **Seam round 2 closed: ldl memo kept (+inline credit), FrozenFast/act_cache consolidation tried and REVERTED (measured slower). Remaining seam self-time is structural → doc-17 Part B next.**

### What landed (Bart: "do the known things before B first")

1. **`hasNativeLoopDoneLink` memoized per-trace under `cache_gen`**
   (`Trace.ldl_memo`/`ldl_memo_gen`; body split into
   `computeNativeLoopDoneLink`). It ran per native dispatch
   (interp.zig:2848) doing an O(instrs) scan + cache probes. Measured: native
   bucket 51.2M→44.1M cycles at nsieve N=7 (−14%, repeatable via jit-stats).
2. **`creditRegionWork` made `inline`** — called per credited ledger row from
   the frozen fast path; perf annotate showed the call frame as a visible
   slice. Neutral-to-slightly-better (nsieve 9 −1.1%, sieve_int ±0 at
   min-of-41); walk cost unchanged (763 cyc/walk both sides).

### What was tried and REVERTED (kept as a comment in replayLedger)

Serving the FrozenFast walk-prelude from the shared `act_cache` slot via an
extracted `refreshActCache(call_seq)` — replacing the per-walk
`activeRegionFor` map iteration + `region_profit.getPtr` probe with two
compares. **Measured slower**: +51 cyc/walk at N=7 (816→867), +2% wall. The
map has 1–2 entries, so the direct iteration is already cheaper than the
extra layout/branch cost the shared path added. The revert comment sits at
the FrozenFast setup so nobody re-tries it blind. (`refreshActCache` itself
was NOT kept — `qualifiedActiveMember` retains its original inline body.)

NB an important measurement artifact found on the way: restructuring
functions in trace.zig moves replayLedger's code layout enough to shift the
seam bucket ±90 cyc/walk with ZERO functional change (the ldl memo — which
never touches the walk — reproduced the "regression" alone). Judge seam
changes by the native bucket + min run total + interleaved wall clock
together, never by cyc/walk alone.

### Where the remaining round-2 candidates went (profiled at nsieve 9)

- `replayLedger` self 20.5%: **diffuse** — no instruction above 3.1%; it's the
  per-row grammar itself. The lever is fewer walks/rows = Part B, not micro.
- `driveDispatcherLedger` self 5.1%: **skid artifact** — 78% of its samples on
  one unconditional `jmp` right after the `driveBurstCore` call return.
- `wyhash` 1.2%: diffuse (tier-0 interpreter-side lookups mostly).
- `memset` 1.9%: tier-0 array-part growth zero-fill (fresh-nil semantics),
  compulsory work, not seam.

### Gates (all green at this state)

`zig build test` + `-Djit-debug=true` both OK; all SEVEN output hashes OK
(incl. nsieve-bit 6 = 49601107e4d95035 — NB run `bench/luajit/nsieve-bit.lua`,
the 5.4-syntax lune copy, not the LuaJIT-tree file which needs `bit`);
aviii/aviii-which → 109, floatlink → 18135.

### Next (agreed with Bart)

**Doc-17 Part B: true exit-branch patching** — patch the guard to jump
straight into the side trace/continuation, attacking walk COUNT (98,483
walks at N=7) rather than walk cost. That's where the remaining ~40% seam
share lives.

---

## Status 2026-08-13 (LATEST-45) — **Seam-shrink arc, round 1: four measured memoizations, nsieve 5 −22% / nsieve 9 −18% / sieve_int −16% cumulative. Doc-17 Part B (true exit patching) is the agreed follow-up.**

### Why (Bart: "start with shrinking, B as follow-up")

The new `--jit-stats` seam split + perf agreed: at small N the run is dominated
by the steering seam (`replayLedger` ~48% self at N=3, ~1,279 cyc/walk over
1–3 row ledgers), NOT trace codegen (native bodies ~5 cyc/iter, already below
LuaJIT's whole-run average). Profile-first recipe applied; each step A/B'd
min-of-15 before the next.

### What landed (each general, none benchmark-keyed)

1. **`noteTakenExit` arming-gate reorder** — saturated exits no longer run
   `isSourceBranchGuardExit` + `countTracesAt` per receipt; decode/scan only
   when a want could actually be set.
2. **`anchorPopulation` memo** — `cache_gen` (bumped on cache append/remove/
   clear) + per-trace `anchor_pop_*`; steady-state anchor-population query is
   one gen compare instead of an O(cache) scan per receipt.
3. **`maybeArmCompositeExit` already-armed early-out** — every burst's
   terminal composite deopt was re-running the whole arm pipeline
   (classifyExit → def/profit hash probes → `validateRegionBridge` full
   structural proof, 2.4% of N=5) to supersede an identical arm.
4. **`.region_bridge` row memo** — the slow row resolution (provAt → def
   lookup → members scan with `exitOrder` compares) is a pure function of the
   armed link + `region_defs`; memoized on `NativeLink`
   (`bridge_edge`/`bridge_edge_gen` stamped with `region_defs_gen`), dropped
   on re-arm supersede; steady-state row = gen compare + succ check. All
   release-panics intact on the slow path.
5. **O(1) `traceById`** — `trace_by_id` id-indexed array (ids monotonic,
   never reused); fail-soft (grow-OOM or hand-built test traces fall back to
   the linear scan); nulled on remove, cleared wholesale on `clearCache`.

### Measured (min-of-15, --trace --jit-native, vs pre-seam e3316c2 binary)

nsieve 3: 3.5→3.0 (−15%); nsieve 5: 11.2→8.7 (−22%); nsieve 7: 38.0→30.6
(−19%); nsieve 9: 142.8→116.6 (−18%, LuaJIT 144.2 same harness); sieve_int:
64.4→54.3 (−16%); nsieve-bit: 31.5→31.6 (flat). Per-step deltas in the git
log. N=3 seam: ~1279→~1132 cyc/walk, run total 24.8M→19.1M cycles.

### Gates

Tests green both builds; seven output-identity hashes byte-identical; A-viii
109/109; floatlink 18135.

### Still on the table (seam round 2 candidates, unstarted)

- `replayLedger` self still ~20%: FrozenFast setup hash probes per walk
  (consolidate with `qualifiedActiveMember`'s act_cache), per-row
  `accountLedgerRow` residue, `driveDispatcherLedger` 6% self.
- wyhash ~3%: remaining region_profit/defs probes.
- Then: doc-17 Part B true exit-branch patching (the structural fix — longer
  bursts, fewer walks).

---

## Status 2026-08-13 (LATEST-44) — **Pall-faithful hotexit landed: one per-(trace,exit) taken-exit counter (`snap->count`), threshold 10, DONE latch at side-trace commit, productive receipts never strike. Small-N warmup fixed (nsieve N=3: scan loop 0%→94.5% traced, −17.5% wall). All green, all six hashes identical.**

### Why (Bart: "the most correct change — start with what Pall does")

The N-sweep showed lune's small-N nsieve gap is not process startup (0.34ms vs
LuaJIT 0.30ms empty script) but the scan loop never tiering up below N≈7: at
N=3 its receipts are all `completed=1..5` (prime-gap segments, below
`min_useful=8`), every one struck, the anchor gated within 8 receipts, and a
gated anchor gets no dispatch, so exit hotness never accrued (38 traced vs
140k interpreted iterations). Read the source (`~/Projects/LuaJIT/src/
lj_trace.c`): `trace_hotside` (:798) counts EVERY taken exit
(`++snap->count >= hotexit(10)` → side trace), `SNAPCOUNT_DONE=255` latches at
side-trace link (:535), and `penalty_pc` fires ONLY on recording aborts.
LuaJIT has NO per-segment productivity strike machine — ours was the non-Pall
invention.

### What landed (this commit)

1. **`Trace.exit_counts: []u8`** — Pall's `snap->count`: one taken-exit counter
   per committed instr, alloc-once at commit (fail-soft), one byte RMW per
   receipt (no hashing — the Part S lesson). `EXIT_COUNT_DONE=255`.
2. **`config.hotexit = 10`** (lj_jit.h `JIT_P_hotexit`).
3. **`noteTakenExit(t, exit, completed, proto)`** — the single per-exit hotness
   charge, called from interp step-4 (scalar) and the driveDispatcherLedger
   terminal (bursts; now charges productive terminals too), loop-done exits
   excluded (continuation territory). **Routing (the shape-fidelity rule —
   found the hard way):** Pall records FROM the exit, so his side trace is the
   right shape by construction; we route to whichever recorder captures the
   right shape: source-branch guard → `wants_prime_side` (doc-16 immediate
   replay of THIS iteration); other guard + zero-progress → `wants_side_trace`
   (resume-timed replay of the failing iteration); other guard + productive →
   count only, NO want (the back-edge recorder captures the NEXT iteration —
   wrong shape; first cut routed branch exits there and collapsed nsieve's
   entire fusion: bridge arms 25 940→0, +53% wall).
4. **DONE latch** — want carries `(parent trace, exit)` provenance
   (`side_want_src`/`prime_want_src` → `pending_replay_src` →
   `Recorder.side_src`); commit latches the parent exit `EXIT_COUNT_DONE`.
   Abort drops it (Pall retries; abort's own `gateAnchor` is our `penalty_pc`).
5. **Productive receipts never strike** — `accountLegacyThrash` returns before
   the penalty bump when `completed > 0`. Zero-progress strikes stay (our exits
   re-enter the runtime, LuaJIT's are patched branches) with Option-A headroom,
   now `max_penalty +| hotexit`.
6. **Removed:** `countProductiveBranchExit` + `prime_exits` map +
   `clearPrimeExits` (the hotguard-50 prime counter — redundant, one counter
   now), `shape_guard_exit_pc` sentinel (subsumed by per-exit counting).
7. Four tests re-pinned from "short productive segment strikes" to the Pall
   semantics (null penalty).

### Measurements (min-of-21 vs /tmp/lune-optA = prior commit, /tmp/lune-hotexit3)

nsieve 3 −17.5%, nsieve 7 −4.4%, nsieve 9 −0.6%, nsieve 10 −1.9%; sieve_int/
pi_leibniz/grid_matmul/nbody flat (±2%). N-sweep ratios vs LuaJIT: N=1 2.3×,
N=3 3.3×, N=7 2.9×, N=9 1.1×. nsieve:14 at N=3: 0.0% → 94.5% traced-it;
whole-run as-trace 5.9% → 60.9%. Remaining small-N gap is recording/compile
warmup + per-transition overhead ("other (non-loop)" 18.6% at N=3), not
coverage starvation.

### Gates

`just test` green (also `-Djit-debug=true`); A-viii repros 109; floatlink
18135; all six output-identity hashes byte-identical.

### Fix-up commit (same arc): nsieve-bit panic + codex review findings

The full board caught a panic the six-hash gate missed (nsieve-bit wasn't in
it — it is now, hash 49601107e4d95035): `replayLedger: terminal loop-done
carries an invalid continuation`. Ledger `[2.deopt/23 → 3.link_terminal/48 →
0.loop_done_linked/33]` — a hotexit-armed prime-side composite (anchored at
the GUARD pc, ends `.link`) enters the linked grammar via `.link_terminal`,
which sets `cont = owner`; the inner's terminal loop-done then requires `cont`
anchored at its post-loop pc and release-panicked. The shape is legitimately
reachable (not a wiring bug) once prime sides arm at threshold 10; the old
hotguard-50 machinery just never recorded one here before the run ended.
Fix: the terminal validates the full continuation contract (same P-G
eligibility `armLoopDoneLink` enforces) and on mismatch returns `.break_burst`
— tier-0 resumes at `post_pc`, where regs are coherent regardless of `cont`
(the same directive the hop-budget bound takes; the site-3 arm was already
fail-closed via P-G, so no bogus native edge ever armed). Non-last fused
successor validation stays a panic (arm-time-validated). Also from the codex
84c86bc review: `noteTakenExit` now increments BEFORE the capacity check (Pall
counts every non-DONE exit; cap suppresses arming only), and `abort()` /
`closeTrace()` clear `rec.side_src` so a dropped recording can never latch a
later commit's parent exit DONE. Plus two permanent jitdbg probes (per-row
ledger dump, invalid-cont diagnostic). **nsieve-bit min-of-15: 58.9 → 31.9ms
(−45.7%)** — the prime-side fusion the panic was blocking. nsieve/sieve_int/
pi_leibniz unchanged (±2%).

### Follow-ups (noted, not started)

- driveChain inner receipts (mid-chain deopts) still charge no exit hotness.
- `countFingerprintMiss` + sibling-watch still at hotguard=50 — candidates for
  the hotexit threshold, measured separately.
- The remaining `min_useful` uses (flushRegionWindow window verdict, hit_count
  gating) are burst-level and stay.

---

## Status 2026-08-13 (LATEST-43) — **Option A: guard-failure-aware gating. nsieve −48%, sieve_int −32%; nsieve now at/below LuaJIT wall-clock on this box (nsieve 9: lune 136ms vs LuaJIT 144ms; nsieve 10: 266ms vs 427ms; sieve_int parity 63ms vs 62ms). All green, all six hashes identical.**

### The problem (diagnosed last arc)

nsieve creates `local primes = {}` ONCE and reuses it across 3 sieve sizes. The
first size records the init loop (`for i=2,m do p[i]=true end`) append-shaped
(`guard_append`+`astore_append`). Sizes 2/3 hit in-bounds OVERWRITES →
`guard_append` fails at i=2 → zero-progress receipts → the legacy 8-strike gate
condemned the anchor before side-trace hotness (`hotguard=50`) could fire.
Worse: array/shape guards store a lane ordinal in `aux`, not a PC, so
`guardExitPc` returns null and they never charged `countGuardFailure` AT ALL —
side-trace hotness was structurally impossible for shape mismatches. Result:
~36% of the run (init loop, anchor nsieve:4) pure tier-0.

Bart picked **Option A** (LuaJIT's model: a hot guard exit gets its own
hotcount and spawns a side trace; the parent anchor is never blacklisted for
it) over B (count shape-guard exits toward the existing per-PC hotness) and C
(reset the strike counter on side-trace record).

### What landed (this commit)

1. **`shape_guard_exit_pc` sentinel (`maxInt(u32)`) + `isSideExitGuardOp`**
   (trace.zig, next to `guardExitPc`) — the 19-op guard-family predicate.
2. **Sentinel hotness charges** — both zero-progress charge sites (interp.zig
   scalar step-4 + `driveDispatcherLedger`'s ledger terminal) gained an
   else-branch: a side-exit guard WITHOUT a PC charges
   `countGuardFailure(anchor, shape_guard_exit_pc)`. Shape mismatches can now
   reach `hotguard` and trigger `wants_side_trace` → resume-timed side record.
3. **Widened legacy gate under side headroom** — `accountLegacyThrash` takes
   the receipt's `exit_instr`; when `completed == 0`, the exit is a side-exit
   guard op, and `countTracesAt(anchor) < max_traces_per_anchor`, the gate
   threshold becomes `max_penalty +| hotguard` (58) instead of 8 — the
   side-trace machine wins the race. Genuinely thrashing anchors still gate
   (bounded), and once the anchor is at trace capacity the plain threshold
   applies. Threaded `exit_instr` through `onSideExit` (maxInt),
   `onSideExitReceipt` (its param), `accountLedgerRow` (+param: `e.exit` on
   `.deopt` arms, maxInt on loop-done/prologue-fail arms).

Verified live (`--jit-debug`, nsieve 2): strikes climb `penalty=N/58`, at 51
(one past hotguard) the next entry runs `local=19947` — the overwrite side
trace recorded and completes the whole init loop natively; third size selects
it after ONE strike. `--jit-stats` nsieve 9: anchor nsieve:4 went 3.9% → 53.9%
traced-time, its run share 37.8% → 6.1%; whole-run traced time 69.1%.

### Measurements (min-of-21 vs /tmp/lune-memo1 = prior commit, /tmp/lune-optA)

nsieve 9 −47.8% (259.8→135.7ms), nsieve 10 −47.1% (503.0→266.2ms), sieve_int
−31.8% (92.3→62.9ms), pi_leibniz +0.3%, grid_matmul −1.7%, nbody +2.7% (noise;
no coverage there). LuaJIT same harness: nsieve 9 144.2ms, nsieve 10 426.8ms,
sieve_int 62.1ms.

### Gates

`just test` green (also with `-Djit-debug=true`); A-viii repros print 109;
floatlink prints 18135; all six output-identity hashes byte-identical.

### Next levers (unchanged)

nsieve:14 residual (96.1% it-traced but 73.6% time-traced — exits/seams);
tier-0 dispatch (threaded/computed-goto); replayLedger walk self-time;
dynamic-proto gate for scimark (53% of suite runtime, 0% coverage).

---

## Status 2026-08-13 (LATEST-42) — **THE TRACES FUSE. Part S sound + armed, the third nsieve shape records (zero-trip for_prep record-through), and the per-row pricing seam is KILLED (freeze-after-qualify). nsieve/sieve_int ~14–27% faster than the pre-S baseline. All green, all six hashes identical.**

LATEST-41 below is **stale in its central verdict**: the §S premise was NOT
falsified and the handoff is NOT unsound. The A-viii 108-vs-109 drop was
`replayLedger`'s terminal arm resuming at a stale `link_pc` when a burst mixed
`.link_terminal` rows with a later handoff row — fixed by entry-provenance
(`next_via_handoff`, mirroring the `entered_via_bridge` precedent). Arming is
back ON. Full story in the `sibling_handoff_arming_enabled` doc comment.

### What landed this arc (all uncommitted → this commit)

1. **Part S soundness fix** — entry-provenance in `replayLedger`: a handoff
   successor terminal-resumes at its ANCHOR, never `link_pc`. A-viii prints 109.
2. **Part S arming re-enabled** with hardened eligibility: the guard's source
   opcode must be a real conditional branch (`jmp_if_*`) — a `for_prep`-sourced
   zero-trip check ping-pongs to LEDGER_CAP (measured +128% before the rule).
3. **Ledger-path guard-failure hotness** — `driveDispatcherLedger` charges
   `countGuardFailure` for zero-progress normal deopt terminals (the scalar
   step-4 site never runs for `ledger_len > 1`), so side traces can get hot
   from fused bursts. Plus `max_traces_per_anchor` moved to config (default 4).
4. **Resume-timed side recording** — `consumeSideTraceWantAtResume`: consume
   `wants_side_trace` at the deopt RESUME (recording the failing iteration's
   re-run), not the next back-edge (which records the wrong shape). Arms via
   `pending_replay_anchor` + `.switch_mode` so the recorder actually runs.
5. **Zero-trip `for_prep` record-through** (the recorder frontier): the
   recorder no longer force-closes with `.link` at every `for_prep`. It decides
   the direction with the SAME value ops tier-0 uses; a zero-tripping loop is
   recorded as the plain `sub` + fall-through, and `recForLoop` is now
   polarity-aware (`guard_false` on the continue test, `R[a+3]` NOT published,
   recording continues straight-line). nsieve's third shape (prime with
   `i+i > m`) records and compiles.
6. **Freeze-after-qualify (the seam kill)** — `RegionAccum.frozen` latches
   after `config.freeze_windows` consecutive useful windows; `replayLedger`
   then prices member→member rows through a direct-credit fast path (no
   classifyExit / chooseSource / destination hashing; membership via per-trace
   `region_memo_*` keyed on `region_defs_gen`). Any strike unfreezes.
   `accountRegionProfit` fell 18.1% → 0.0% of nsieve wall-clock.
7. **`noteSiblingTerminal` reject memo** — single-slot ineligible-exit memo on
   Trace (`sibling_reject_exit`); 84k/run eligibility re-scans → one compare.
8. **`qualifiedActiveMember` activation cache** — single-slot (`act_cache_*`),
   invalidated in `freeObserverFast` (every `region_profit` mutation funnels
   there) + the qualification flip + `region_defs_gen`.

### Measurements (min-of-21, vs /tmp/lune-memo1 pre-S baseline, noisy box)

nsieve 9 −14…−23%, nsieve 10 −14…−26%, sieve_int −23…−42%, pi_leibniz ~0.
Profile after: `accountRegionProfit` 0%, `replayLedger` self ~13%, tier-0
`execImpl` ~25% — the next seam is tier-0 dispatch + the remaining ledger walk.

### Gates

`just test` green; A-viii repros (`/tmp/aviii.lua`, `/tmp/aviii-which.lua`,
`--trace-hotguard 3`) print 109; all six output-identity hashes byte-identical
(nsieve 4053ed86223d7060, nbody 9dcd7fa2f7e9e93e, sieve_int db55c0f98f98851b,
pi_leibniz f57ace5316c0fd19, grid_matmul 395ff5566b31eb18, field_hash
89b64d3d25ae188f).

---

## Status 2026-08-13 (LATEST-41) — STALE (kept for the diagnosis trail; central verdict disproved above) — **Part S BUILT and MEASURED. The "50% = runtime re-entry" premise is DISPROVED, and the handoff is UNSOUND. Arming is off (`sibling_handoff_arming_enabled = false`); everything else is landed and green.**

### 1. The premise behind Part B is wrong

Part B assumed the ~50% seam is the cost of *returning to the runtime* per burst,
so fusing bursts would eliminate it. Built it; measured it. On nsieve N=9:

| config | bursts | traced time | wall-clock |
|---|---|---|---|
| pre-Part-S | 641,431 | 51.0% | 243 ms |
| handoff, first accounting | 25,595 (**−96%**) | 7.2% | 307 ms (**+18%**) |
| handoff, accounting fixed | 330,000 (−48%) | 52.7% | 231 ms (−7.3%) |

**96% fewer bursts made it 18% SLOWER.** Dispatcher re-entry is not the seam.
What the seam actually is: per-ROW pricing (`accountRegionProfit` 15–18%,
`replayLedger`, hashing) — and fusion does not remove rows, it only moves them
between bursts. In the middle row above the seam *looks* eliminated
(`accountRegionProfit` 17.7%→1.5%) purely because the JIT stopped running.

Corollary for whoever picks this up: **the remaining lever is per-row pricing
cost or the freeze, not burst count.** Task #72 (hoist the per-row hashmap
lookups) is on the real critical path; Part B's fusion is not.

### 2. Two accounting bugs found (both real, both fixed)

- `accountLedgerRow` on a handoff row applied the legacy-thrash VERDICT to a
  zero-progress TRANSITION → a penalty strike per fused hop → `pc=14` hit
  `max_penalty`, the anchor gated, traced time collapsed 51%→7.2%. A fused
  handoff never reaches the runtime and must be invisible to profitability;
  it now charges `accountTraceRun` only.
- The production never advanced `prev_cum`, so the sibling's row re-counted the
  parent's committed iterations.
- Also: the charge site must be `driveDispatcherLedger`, NOT `replayLedger` — a
  walk can return a directive from an interior row and never visit the last one.
  Sited in the walk it saw 25,939 of 330,000 terminals and the dominant exit
  could never qualify.

### 3. The handoff is not semantics-preserving — this is the blocker

With the charge site fixed so every terminal is observed, **A-viii prints 108
where the unfused run prints 109**: one iteration silently dropped. §S's stated
coherence condition is "a zero-progress pre-effect deopt is coherent at the
anchor". Both halves were then implemented, and **both are insufficient**:

- static: `exitIsPreEffect` (no `astore`/`astore_append`/`hstore`/`gstore`
  precedes the exit) — still 108.
- runtime: `term_local == 0` at the charge site — still 108.

So the premise is falsified, not under-enforced. Some state the sibling's
`ordinary_entry` needs is not reconstructible from a carried-homes flush, and
identifying it is the open work. This is §S.8's "true per-exit snapshots"
deferral turning out to be load-bearing — which is what codex round 1 said.

Note the first cut passed the suite only by luck: it armed exactly ONE exit.

### 4. What is landed (green, arming off)

`sibling_handoff_arming_enabled = false` in src/trace.zig. Kept because it is
the part that is right: `ArmKind.sibling_handoff` + arm-time validator, the
three-scalar allocation-free watch on `Trace` (`sibling_watch_exit/_count`,
`sibling_arms`) replacing the hashmap whose per-receipt probe was itself worth
15%, `clearSiblingLatch` on every disarm path, `exitIsPreEffect`, the replay
production, and the M1 sub-case (b) interaction fix. Suite green; all six
output-identity controls unchanged.

### 5. Open question for Bart

Three ways forward, no recommendation: (a) close the soundness hole with real
per-exit snapshots (the original Part B, largest job); (b) drop fusion and go
after per-row pricing cost directly, which is where the measurement now points;
(c) leave Part S inert and pick a different lever entirely (e.g. the parked
dynamic-proto gate blocking SciMark — 53.5% of suite runtime at 0% coverage).


## Status 2026-08-13 (LATEST-40) — **Part S designed + twice-reviewed, ready for S-a. The whole 50% seam is TWO exit sites; the fix is a native sibling handoff compiled into the deopt stub.**

**Bart's mandate (verbatim intent):** "every single program will eventually hit
this problem we have on nsieve … do whatever we need until we have part B and
that 50% is eliminated." Standing autonomy: fix codex findings with best
judgement and proceed.

**What landed (3c17238):**
1. **Burst-terminal telemetry probe** (`dbgNoteBurst`/`dbgDumpBurstStats`,
   jitdbg-only, permanent). nsieve N=9: **641,431 bursts, ALL terminating at
   t=4 ei=9 (337k) or ei=16 (304k)** — two deopt exits of the prime-found
   continuation at anchor pc=14. One runtime turnstile visit per prime.
2. **doc 17 §Part S** — the design, with two codex `gpt-5.6-sol` REJECT rounds
   folded in and recorded inline. Round 1's central finding SIMPLIFIED the
   design: a zero-progress pre-effect deopt is coherent at the ANCHOR
   (interp.zig:3224) — no gap to record, no stitch traces, no per-exit
   snapshots; the sibling trace already IS the alternate path; doc 16's
   runtime coherent-anchor chain just needs compiling into the exit stub.

**The S-a implementation contract (round-2-pinned, START HERE):**
- Pre-effect eligibility bitset per trace (pattern: §T.9 `bridge_cand` memo) —
  exit index eligible iff no effectful op precedes it (anchor-coherent at any
  iteration count; verified nativegen.zig:4554-4592/4729-4739/2397-2425).
- New counter keyed `(parent Trace.id, exit_instr)` charged EXACTLY ONCE per
  receipt: replayLedger's terminal normal-deopt arm ∪ interp's scalar
  zero-exit branch (mutually exclusive — interp.zig:3010 returns before 3017).
  Parity test required. `guard_failures` is NOT reusable (aliases by
  (anchor,exit_pc), stops at 2 traces, blind to ledger terminals).
- `ArmKind.sibling_handoff` + **separate slot namespace** (slot[ei] is
  loop_done_linked-reserved, trace.zig:1211/6511; ordinary loop-done deopts
  bypass to shared_exit, nativegen.zig:4653).
- Stub (S-b, but emitted inert in S-a with slot hard-wired to shared exit):
  load slot → armed test → armed: append `.sibling_handoff`, forced-yield
  check (target in rax, may rewrite + stamp `.yielded`), `jmp rax` (precedent:
  loop-done-linked site nativegen.zig:4762, NOT A2.4); unarmed: append
  `.deopt`, shared exit — byte-identical today's row.
- Zero-input siblings only (`inputs.len == 0` — ordinary_entry cannot seed;
  interp.zig:885-929, trace.zig:3697/4265/6650).
- S-b arm: one-shot pending `(parent, exit)` set at terminal consumption;
  armed at the dispatcher's ACTUAL successful sibling entry
  (nextTraceExcluding site, interp.zig:2737-2762); safe_to_arm at slot write;
  cleared on departure/frame death/epoch.
- Ledger: `LedgerKind.sibling_handoff` — non-final: next row same-anchor;
  final: `.yielded` only. Accounting: `region_work = local`, one
  `accountLedgerRow`, destination **`.deferred`** (never `.known_trace` — the
  generic rule at trace.zig:4051 would let applyDestination reproduce the
  §A8-v cross-credit pathology).
- **Freeze DEFERRED to v2** (would remove the barren decay detector,
  trace.zig:3328; design v2 after S-b's measurement, with close-remainder
  policy trace.zig:2748 explicit).

**Pre-registered expectation:** dispatcher entries ÷≈9 (avg burst 3.58 rows →
LEDGER_CAP=32); per-row pricing (~26% of wall) SURVIVES until freeze v2. Six
workload hashes must stay: nsieve=4053ed86223d7060, nbody=9dcd7fa2f7e9e93e,
sieve_int=db55c0f98f98851b, pi_leibniz=f57ace5316c0fd19,
grid_matmul=395ff5566b31eb18, field_hash=89b64d3d25ae188f (ReleaseFast,
`--trace --jit-native`, run each command individually).

**Also this session:** Part T formally superseded (twice-rejected; §Part T
kept as review record); §T.9 seam profile; bridge-candidate memo (a0cedc8,
nsieve −6.3%, sieve_int −8.9%); codex full-suite finding parked: SciMark = 53%
of suite runtime with ZERO coverage (dynamic-proto gate, `arm()` trace.zig
~7037 + load.zig:118) — separate lever, H-2 hard half, NOT part of this arc.

## Status 2026-08-13 (LATEST-39) — **Part T rejected TWICE pre-implementation; profiling the seam it targets changed the plan. First "free" memoization landed: nsieve −6.3%, sieve_int −8.9%, zero contract change.**

**What happened.** Bart's lever ("LuaJIT does the B part right — not having to
go through the runtime is the single highest lever") became Part T:
commit-once transitions, LuaJIT `SNAPCOUNT_DONE` semantics. He chose
"commit-once first, then patching." Two codex `gpt-5.6-sol` pre-implementation
reviews **rejected** it (3 BLOCKER + 3 MAJOR each round). The two corrections
that mattered — both were my errors, recorded inline in doc 17 §Part T rather
than edited away:

1. *"Worst case is mis-tiering"* was **false**. A terminal `.loop_done_linked`
   returns a specific sibling `*Trace`, and fused M1 sub-cases (b)/(c) resume at
   the **predecessor's** anchor — so a lossy summary can double-commit
   iterations and **corrupt `regs[]`**.
2. *"Qualified hop receipts are accounting no-ops"* was **false**. Consumed ≠
   no-op: they still credit work, reset `barren_run`, flush windows, drive
   `applyDestination`, update coverage/`hit_count`.

Round 2 still REJECT (barren interleavings vs a bulk aggregate; terminal
`ChainResult.completed`; the bridge two-cell reservation at nativegen.zig:4675;
per-receipt `hit_count`). **Part T has NOT proceeded to T-a.**

**The thing I should have done first (doc 17 §T.9).** Two designs rejected on a
mechanism whose payoff split was never measured — against this project's own
"profile FIRST" rule. Per-symbol attribution of the 50.1% seam says it is *not*
mostly "walking rows": ~**15%** of wall-clock is pure lookup/validation that is
memoizable with **no contract change, no determinism argument, no
accounting-equivalence proof**, and only ~20% is what Part T's contested
contract buys. Bart chose **"take the free 15% first."**

**Landed (a0cedc8).** `isCompositeBridgeCandidate` — a pure function of
immutable recorded data ending in an O(`instrs`) scan, called per receipt from
seven hot sites, 4.68% of wall — is now a per-trace bitset built at commit
(`buildBridgeCandMemo`), read via `Trace.isBridgeCandidate`. The oracle remains
the definition: unbuilt memo falls back to it, the build is fail-soft, codegen
and all existing tests still call it directly, and a new differential test
asserts memo == oracle at *every* index across unbuilt/true-bit/all-false/empty.
Measured ReleaseFast best-of-15 A/B: nsieve 9 **−6.3%**, nsieve 10 −3.4%,
sieve_int **−8.9%**, pi_leibniz +0.1% (correct negative control — one tight
loop, no bridge traffic). Six workload hashes identical to the frozen controls.
Both gates green. `perf` confirms the symbol is gone from the profile.

**Next (task #72, not started).** Remaining memoizable pool ≈ 9%: hashing 6.44%
(`wyhash` 4.11 + `auto_hash` 2.33, essentially all per-receipt map lookups —
`classifyExit` = one `source_exit_regions.get(ExitKey)`, plus
`region_profit.getPtr`) and `qualifiedActiveMember` 2.44%. The shape is an
ObserverHot-style inline cache, but `classifyExit` returns a **slice into map
storage** and `getPtr` a **map-interior pointer**, so it needs a generation
counter bumped on every mutation of those maps — start fresh, that hazard class
deserves its own careful increment. `accountRegionProfit` now reads 20.18% (was
16.04%) purely from the shrinking denominator, not a regression.

**Do not commit** `bench/results/20260813-050325-44da392.tsv` as-is: the harness
stamped it with the baseline commit while measuring the uncommitted memo build.

## Status 2026-08-12 (LATEST-38) — **The region-profit gate FIX landed: the gate was condemning its own region. After the codex review round: nsieve −29% (103.2 → 73.2ms), sieve_int −37% (41.1 → 25.7ms), links persist for whole sieves, nsieve:14 coverage 2.4% → 91.5%.**

**Codex post-landing review: 2 BLOCKER + 2 MAJOR, all four fixed same-session
(doc 17 §A8-v has the full record):** (1) fallback receipts now thread the live
activation through to `applyDestination` as the effective source (was: foreign
dest could open a second accumulator at one call_seq; the fix also killed the
per-receipt no-op `openRegion`, worth a further −12% on nsieve); (2)
`barren_run` + `max_barren_run=64` — a consumed-barren streak with no credit
flushes a synthetic low-yield strike, so a qualified activation that decays is
still priced (the post-qualification thrash hole); (3) qualification amnesty —
the first useful window clears legacy penalty/gate on every member anchor
(`clearMemberAnchorState`), killing the latent stale-penalty re-gate; (4)
publish-phase `closeNonArmableAccumulators` — a rebuild that un-arms/tombstones
a def closes its live accumulators (no resurrection with `useful_window_seen`
latched). All re-measured + hashes verified after the round.

Bart's mandate: "the only thing the fix set out to do failed… try to fix it
again — maybe now constantly checking soundness *and* profitability." Both
gates (`just test`, `zig build test -Djit-debug=true`) plus counters + raw
wall-clock + output hashes were re-run after **every** change. Four fixes, all
in src/trace.zig, all general mechanisms (Z-6) — full record in doc 17 §A8-v:

1. **`chooseSource` no longer closes the live accumulator on UNCLASSIFIED
   exits** (ephemeral-edge-cache miss = "no information", not "we left").
   Tombstoned/vanished defs still close immediately (positive evidence; pins
   test (5e)). Window strikes 3,603 → 0, mid-run `disarmAllLinks` 703 → 0.
2. **`armLinkTerminal` (arm site 4)** — the `.link`-terminal edition of site 3's
   loop-done convergence; previously 6,931 spans/run died unarmed at the prime
   ramp's `.link`, one runtime seam per prime.
3. **Consumption boundary revised** (the big one): (i) zero-work member
   receipts of a QUALIFIED activation (`useful_window_seen`) are consumed —
   they're polarity-flip transitions, not thrash; unqualified activations keep
   full pre-flip legacy gating (A-vii-c blocker shape stays gated); (ii)
   unclassified nonzero-work receipts from traces anchored in the live
   activation's `member_points` footprint credit the accumulator
   (`regionMemberTraceAnchor`); (iii) null-keyed synthetic steering charges
   (`onSideExit(ramp,0)`/`(seed,0)`) on member anchors of a live qualified
   activation are region-owned (`qualifiedActiveRegionOwns`). Before: 94k
   `completed=0` legacy strikes/run kept re-gating (exponential backoff →
   permanent abandonment) the scan anchor the region machine had just
   qualified. Pinned by the new "gate-fix consumption boundary" test (a–g).
4. **`openRegion` refreshes the observer cache only on real map mutation.**
   THE PROFITABILITY TRAP OF THE ARC: after 1–3, coverage exploded (91.5%
   traced, fused source ≈ every prime, disarms 0) and wall-clock got *WORSE*
   (+12% N=9) — `applyDestination` no-op re-opens the active region once per
   fused receipt, and each re-open freed + reallocated the observer bitset and
   killed `ObserverHot` (9.6% of wall). Coverage converted only after this fix.

**Measured** (interleaved A/B vs /tmp/lune-fast2 = 182cb87+49f3984): nsieve N=9
0.32 → 0.30–0.31s raw; full suite nsieve −19.6% (103.2 → 83.0ms), sieve_int
−25.9% (41.1 → 30.5ms), all else within ±3.3%. Six-workload output hashes ≡
frozen controls. New permanent dbg probes: gateAnchor, legacy-strike,
window-strike, close-reason (chooseSource/applyDestination/openRegion/drop),
unclassified-exit, barren-*, openRegion.

**Where nsieve stands NOW (profile on file, §A8-v):** per-receipt accounting is
the bottleneck — `accountRegionProfit` 17.8% self + hashing ~11% +
`replayLedger` 8.1% + `runCapturingLedger` 4.0%; 91% native coverage buys only
−20% wall because every fused receipt runs classify/choose/apply-destination
with several hashmap ops. Next levers, in order: (a) steady-state receipt fast
path (one-entry cache in the e.1/e.2 mold, pure accelerator); (b) §A2.4/Part B
exit-branch patching, which removes the runtime from steady-state transitions
entirely. Residuals: 51 strikes/run at pc=14 remain (inter-activation,
pre-qualification) → 7 transient gates; anchor pc=29 gets gated 545× (t=2
continuation receipts arriving with no live activation) — worth a look in the
next arc; the "region decays after qualifying" shape is priced only at close
(remainder flush) — noted in §A8-v as an accepted weak spot.

## Status 2026-08-12 (LATEST-37) — **A-vii-e.2: the region observer's per-instruction CALL is gone. nsieve −27%, sieve_int −28%, everything else flat. Started as "do the §A2.4 native in-page handoff"; the profile said otherwise.**

Bart asked for the §A2.4 native in-page handoff (doc 17's stated payoff for the
A-vii bridge). Profiled first, per the project recipe — and the handoff is not
where nsieve's time is:

1. **`observeRegionProgramPoint` was 43.5% of nsieve N=9**, more than the whole
   interpreter dispatch (`Vm.execImpl`, 31.7%). A-vii-e.1 removed the hashmap
   walk but left a real *call* per interpreted instruction; `perf annotate` puts
   ~70% of that 43.5% in the call's own prologue/epilogue (`push rbp` + five
   callee-saved pushes + `sub rsp, 0x68` — a frame sized by the cold slow path).
2. **Fix = `ObserverHot`**, a one-entry inline cache over e.1's spans: the span
   that answered the last survive verdict, keyed by the *whole* query
   (`proto_id`, `depth`, `call_seq`) + precomputed `base_pc`/`span_pcs`. Only a
   `true` must be sound; a `false` defers to the real observer, which still owns
   every close. Invalidated wholesale in `freeObserverFast` (sole owner of the
   borrowed bitset), so it cannot dangle or outlive its `ObserverFast`.
3. **Call-site ORDER is load-bearing** — the first attempt probed the hot cache
   *before* the `region_profit.count()` test and touched a second `TraceState`
   cache line on every instruction of every region-free program: a uniform
   **+11%** on scimark-sor tier-0 (interleaved A/B). Empty-map test stays first.
4. **Measured** (min of two interleaved full-suite runs per binary): nsieve
   −27%, sieve_int −28%, all others within ±4%, tier-0 flat. Raw nsieve N=9
   0.43s → 0.31s.
5. **Determinism**: six workload hashes unchanged, tier-0 ≡ native, and every
   `--jit-stats` event counter bit-identical (33662 entries; arms
   335/1320/2282/2267; fused 5824/12630/14724; 6204 disarms; peak 4) — the
   accelerator changes no tiering decision. Tests: an inline-cache boundary test
   plus a **differential** test (one query stream through the interp.zig call
   site vs the bare observer on two identical states → equal accumulator state
   and flush history). `just test` + `-Djit-debug` green.

**Where nsieve stands now** (this is the honest next-lever list, and it is NOT
the in-page handoff): the observer is gone from the profile; the run is 70.6%
`Vm.execImpl` + ~16% out-of-line arith helpers (`arith.lt`/`le`,
`value.compareNumeric`). Per-anchor, **nsieve:14 — the branchy outer scan — is
63.7% of the run at 0.7% traced iterations** (8.9M interpreted iterations), while
nsieve:24 is already 94.9% traced and costs 21.5% of its anchor's time. So the
gap is (a) tier-0 dispatch + arith, and (b) why the outer scan trace almost never
runs. Also worth noting for §A2.4 itself: the bridge stub at `nativegen.zig:4691`
**already** ends in `jmp qword [rdx+exit_target]` — an in-page native→native
handoff to `skip.ordinary_entry`. Doc 17's "each bridge firing still crosses the
runtime seam" line needs re-grounding against that before any §A2.4 work starts.

## Status 2026-08-12 (LATEST-36) — **A-viii round-2 revision (codex round 2 = CHANGES REQUIRED: 3 MAJOR + 1 MINOR). §A8 step 8 stays ticked; the bridge residual is now its OWN Outstanding bullet in doc 17 instead of being absorbed into a ticked step.**

1. **MAJOR — `entries` cannot carry R2-4.** True: it's bumped at
   `interp.zig:2785` BEFORE the dispatcher chooses native vs tier-1a, so a run
   that fell back to the IR interpreter every time would still advance it.
   Added **`TraceState.native_entries`**, bumped only where `nativeFor(ct)`
   resolves and `ran_native` is set; the mid-epoch test now pins THAT advancing
   across the window-open event. Also printed in `--jit-stats` next to
   `entries`.
2. **MAJOR — the unit test's physical slot shapes were still fake.** All three
   traces shared one guard array, so the "bridge" slot was physically a
   loop-done guard and the "terminal" slot a `guard_true`. Rebuilt with a
   per-trace IR array: genuine numeric-for loop-done guard for `inner`, terminal
   `.link` op for the C⇄I back edge, a real `isCompositeBridgeCandidate` guard
   (full `recForLoop` shape: dominating loop-continue guard consuming the
   stepped index + slot-bound phis for both `for_loop`-written slots) for edge
   4, plain non-composite guard for the ramp. All four now arm **through
   `armNativeLink`** — every kind's validator runs for real, nothing is
   hand-appended to `armed_links`.
3. **MAJOR — the bridge residual vs "A-viii complete".** Resolved by tracking:
   the residual is now its own `- [ ]` bullet in doc 17's Outstanding list,
   phrased "not achieved in this workload", NOT "impossible" (codex's point:
   a different workload, a cold-path placement, or a non-perturbing debug hook
   at the dispatcher/bridge-publication boundary would each close it).
4. **MINOR — two unpinned premises.** The mid-epoch test now asserts
   `native_region_bridge_arms == 0` (so the documented scope boundary fails
   loudly if it ever moves) and the disarm delta EXACTLY (`==`, not `>=`):
   once the window is open nothing can re-arm, so the first blackout charges
   the captured set and nothing else.
5. **`capturedGraphHasCycle` rewritten** as a visited-set BFS over the ≤32
   endpoint ids. The earlier path-frontier version could truncate a branching
   frontier at 16 and report a false negative (codex confirmed no false
   positives, but the completeness comment was overstated).

Codex also confirmed: the `threadlocal` capture is sound (synchronous callback
on the same thread + TLS; the "all tests run in order on one thread" comment was
stronger than needed), and no false positives in the cycle check.

**Still open (doc 17 Outstanding):** observe a live `.region_bridge` link at a
mid-epoch window-open instant. Also unpinned, and worth knowing: WHAT empties
the registry between outer iterations. A region activation is keyed to the
frame's `call_seq`, not to one scan-loop invocation, and `closeRegion` drops
profitability state without itself disarming the physical link — so the actual
teardown trigger hasn't been identified, and identifying it may reveal a
workable probe placement.

Gates: `just test` + `zig build test -Djit-debug=true` green; six-workload
output identity holds (same six hashes as LATEST-35).

## Status 2026-08-12 (LATEST-35) — **A-viii REVISED per codex review (round 1). §A8 step 8 stays ticked; three of LATEST-34's claims below were WRONG and are corrected here. NEXT = the §A2.4 native in-page handoff (the real payoff), or Part B (rel32).**

Codex returned CHANGES REQUIRED on 5cf93e8 (1 BLOCKER + 4 MAJORs). All fixed;
full corrected record in doc 17 §A8-iv. What changed:

1. **BLOCKER — "the mid-epoch window is host-unreachable" is FALSE.** Natives
   are invoked as `nat.func(@ptrCast(self), args)` (`interp.zig:2466`) — every
   native receives the `*Vm`. So a host-installed native called from Lua CAN
   set `record_safepoint_lines` with an epoch and a full armed registry live.
   LATEST-34 item 2 was wrong, and the "containment by prevention / teardown is
   unit-level by necessity" framing built on it was wrong too.
   **New third test** (`interp.zig`, "…MID-EPOCH…"): a test-installed
   `aviii_probe()` native, called from the sieve's scan loop, waits until
   `armed_links` holds a ≥3-link multi-kind graph, records it BY KIND and BY
   `(parent.id, child.id)`, flips the window open, and is re-called for the
   rest of the run. Measured at the event: 3 links (`.link_terminal` +
   `.loop_done_linked` + `.ordinary_guard`, containing a directed cycle —
   asserted by a bounded-reachability check, since the captured graph is a
   2-cycle plus a feeder, NOT every-child-is-a-parent); `native_link_disarms`
   0 → 3; `armed_links.len` → 0; `entries` 20 → 40.
2. **MAJOR — `peak >= 3` doesn't prove the CYCLE was simultaneous.** True: it's
   a lifetime high-water mark over any kinds. Kept as a coarse assertion +
   `--jit-stats` diagnostic, but the real simultaneity claim now rests on the
   mid-epoch capture's kinds + `(parent, child)` pairs.
3. **MAJOR — `contained.entries >= armed.entries` is unsound.** Withdrawn. The
   two legs select DIFFERENT traces (the armed leg's fused hops change which
   exits are ever taken, so which side traces get recorded at all), so neither
   direction is a law. The whole-run leg now asserts only `entries > 0`; the
   event-scoped version (`entries` advancing after a mid-run blackout, both
   sides from ONE selection history) lives in the new test.
4. **MAJOR — the unit topology was fictional.** LATEST-34's three-edge shape had
   no `.loop_done_linked`. Rebuilt to the topology measured on nsieve 9 under
   `--jit-debug` (inner=24 / cont=29 / skip=14): `inner --loop_done_linked-->
   cont`, `cont --link_terminal--> inner`, `cont --region_bridge--> skip`,
   `skip --ordinary_guard--> inner` — all four `ArmKind`s, the loop-done slot
   built on a real numeric-for guard (`isLoopDoneGuardIndex` asserted at
   construction), one `disarmAllLinks` resetting all four and touching nothing
   else.
5. **MAJOR — the containment leg never exercised teardown.** It still doesn't
   (nothing arms, so there's nothing to tear down — that's the leg's point);
   the teardown-with-a-live-registry demand is met by the new mid-epoch test.

**Residual, stated not glossed:** no test observes a live `.region_bridge` link
at a window-open instant. The probe call is itself a tier-0 effect inside the
scan loop and perturbs the region shape enough that the profit gate never
qualifies it (`native_region_bridge_arms == 0` probed vs 39 unprobed); every
placement that keeps the bridge armed leaves the registry empty at the call,
(an empirical result — see LATEST-36, the actual emptying mechanism is not
pinned down). Edge
4's arming/firing is covered by the two-leg test, its teardown byte-for-byte by
the unit test. Closing the residual needs an observation hook that isn't a
Lua-visible effect inside the region.

Gates: `just test` + `zig build test -Djit-debug=true` green; six-workload
output identity holds (nsieve `4053ed86223d7060`, nbody `9dcd7fa2f7e9e93e`,
sieve_int `db55c0f98f98851b`, pi_leibniz `f57ace5316c0fd19`, grid_matmul
`395ff5566b31eb18`, field_hash `89b64d3d25ae188f`).

## Status 2026-08-12 (LATEST-34) — **SUPERSEDED IN PART BY LATEST-35: items 2, 3 and 4 below are WRONG (mid-epoch window IS host-reachable; the cross-run `entries` comparison is unsound; the unit topology was fictional). A-viii LANDED: §A8 step 8 ticked, ALL EIGHT §A8 STEPS COMPLETE. NEXT = the §A2.4 native in-page handoff (the real payoff), or Part B (rel32).**

Full record in doc 17 §A8-iv. What landed and what it cost:

1. **Integration test (`interp.zig`): the OUTER cycle arms as a CLOSED cycle
   and fires.** Scaled the A-vii-c region shape (`for j=1,40` over a 600-flag
   sieve, hotloop=4, hotguard=3) until the gate qualifies: 39 bridge arms,
   156 fused bridge hops, 430 fused loop-done hops. Added
   `native_link_peak` (high-water mark of `armed_links.len`, diagnostic-only)
   because the per-kind counters are LIFETIME TOTALS and can't tell a standing
   closed cycle from three edges armed and torn down in turn. Pins `peak >= 3`
   (nsieve measures 4). Also printed in `--jit-stats`.
2. **The finding that reshaped the step: containment is by PREVENTION, not
   teardown.** `safe_to_arm = suspend_ctl == null and !record_safepoint_lines`;
   both flags are only writable by the host BETWEEN `exec()` calls, and parking
   requires `suspend_ctl` to already be set — which already blocks arming. So
   **no host-reachable sequence opens a window mid-epoch over a live
   registry.** Measured: window open for the whole run ⇒ `peak == 0`, bridge
   arms 0, `native_link_disarms == 0` (nothing to charge). The
   `disarmAllLinks`-on-unsafe call is correct but currently
   unreachable-by-construction; it goes live when a debugger hook can arm a
   suspend on a RUNNING VM. Hence the teardown half is unit-level by necessity.
   **Bart's call, deliberately not assumed:** whether to make the mid-epoch
   window reachable so that path gets end-to-end coverage.
3. **R2-4 pinned:** the contained leg asserts `entries >= armed.entries`
   (measured 540 vs 460) — with the window open, exits that used to fuse now
   return to the dispatcher and RE-ENTER traces. Not a collapse to tier-0
   bodies. Both legs print `109`, so containment is output-transparent.
4. **Unit test (`trace.zig`): one `disarmAllLinks` tears down the whole outer
   cycle, bridge edge included** — `skip --ordinary_guard--> inner
   --link_terminal--> cont --region_bridge--> skip`, all three slots back to
   `shared_exit`. The bridge kind is the one that postdates the disarm path;
   a kind-sensitive teardown (like the deliberately-selective
   `disarmStaleRegionBridgeLinks` sweep) would strand a live handoff.
5. **Dead ends worth not repeating.** (a) "Safepoint-sequence identity vs
   tier-0" is NOT a valid window oracle — native trace iterations legitimately
   emit no per-iteration safepoints (measured 320 333 under the window vs
   516 251 tier-0). (b) The A-vii-c shape at its original size (80 flags, j=1..5)
   arms loop-done links but NO bridge; scale is what qualifies the region gate.
   (c) A bridge-arming run ends with an EMPTY registry (final gate flush
   disarms), so "still armed at end of Phase A" is not a usable negative
   control — hence the peak counter.

Gates: `just test` + `-Djit-debug=true` green; six-workload output identity
holds; nsieve N=9 389 ms / N=7 102 ms (unchanged — the peak counter sits in
`armNativeLink`, not a hot path).

Remaining: codex post-landing review of A-viii, then the §A2.4 native in-page
handoff — where nsieve:24's 94.9% coverage finally converts to wall-clock.

## Status 2026-08-12 (LATEST-33) — **A-vii-e MEASURED + A-vii-e.1 observer fast path LANDED: §A8 step 7 COMPLETE. NEXT = A-viii (outer-cycle disarm coverage) and/or the native in-page handoff (§A2.4).**

Full narrative in doc 17 §A8-iii item 5. The short version:

1. **Codex post-landing review of d/d.1 closed:** one BLOCKER (bridged
   `.link`-ending successors bypassed the bridged terminal contract — the
   `ends_link` split was tested first, so a zero-progress deopt dropped the
   successor's receipt and double-charged the parent via hop-0's
   `onSideExit(seed, 0)`). Fixed in fcee9b7 (`entered_via_bridge` first in
   both terminal arms, requiring `ends_link or ends_loop`) + regression
   test; re-review = APPROVE.
2. **A-vii-e frozen protocol run (before = 9ee7d4b, after = flip tree).**
   Raw flip: nsieve ~2× WALL REGRESSION (N=7 102→203 ms, N=9 429→795 ms;
   an earlier "flat at N=9" read was --jit-stats TSC overhead masking it)
   despite coverage moving right (nsieve:24 56.7%→94.9% traced, bridge
   fused 14 724/run at N=9). Comptime ablation (arm site declines, all else
   live) timed IDENTICAL → the bridge is cost-neutral; the regression was
   elsewhere. perf (profile-first recipe): `observeRegionProgramPoint` =
   49.1% of runtime — the A-iv per-instruction departure observer's
   empty-map guard stopped guarding once d.1 made nsieve mint an armable
   region whose accumulator is open for ~the whole run (hashmap-iterator +
   linear member_points scan per interpreted instruction; general, not
   nsieve-specific).
3. **A-vii-e.1 fix:** `ObserverFast` — when exactly one accumulator is
   live, the survive verdict is two integer compares + a per-proto bitset
   test on OWNED COPIES of `member_points` (never borrows def memory).
   Rebuilt at the three region_profit mutation funnels
   (openRegion/closeRegion/resetRegionProfit; clearCache resets via the
   third). Any refresh failure ⇒ cache null ⇒ original slow scan, identical
   semantics — OOM cannot diverge replay. --jit-stats event counters are
   bit-identical with/without it. Gotchas hit: (a) `zig build
   -Djit-debug=true` overwrites zig-out with a DEBUG binary — the first
   "after" timings were 20× garbage until `just release` was re-run (the
   documented stale-binary trap, again); (b) a hand-built test RegionDef
   has UNSORTED member_points — the span builder now takes min/max per
   proto run and the probe checks every span; (c) the frozen pi_leibniz
   control hash was for a NO-ARGS invocation (bench @bench args=5000000
   differs) — with matching args all six workloads are byte-identical.
4. **Final numbers (before → after+e.1):** nsieve N=9 436→396 ms (−9%),
   N=7 105→99 ms (−6%); `just bench --filter nsieve --reps 7` jit
   101.0→102.9 ms (noise); full suite: no lune-side flags (str_manip
   luajit=ERR is the LuaJIT binary failing that bench, unrelated). Gates:
   `just test` (836) + `-Djit-debug=true` green. Doc 17 §A8 step 7 TICKED;
   status header updated.
5. **Honest residuals for A-viii+:** (i) nsieve:14's standalone-trace share
   fell 10.9%→0.7% at N=7 (wall-neutral today; revisit with churn work);
   (ii) ~700 `disarmAllLinks`/run at N=7 window churn still forces full
   chain re-arm cycles; (iii) the flip's win stays modest until the native
   in-page handoff (§A2.4) removes the per-firing `driveChain` seam —
   that's where the 94.9% coverage converts to wall-clock.

Codex post-landing review of e.1 (thread continues the d/d.1 one): MAJOR
(bitset sizing u32 overflow for near-maxInt pc ranges → u64 arithmetic +
4M-pc per-proto range cap, f84d9c4) + MINOR (test gaps → shallower-frame
verdicts, funnel-exercised multi-accumulator disabling, over-cap decline
test; 92eb5ee) → re-review = **APPROVE**. Commits this arc: daed882
(e.1 + measurement docs), f84d9c4, 92eb5ee.

Remaining: A-viii per §A8 step 8 (outer-cycle disarm coverage +
negative control; note the ~700 disarmAllLinks/run churn × bridge re-arm
interaction), and — the real payoff — the §A2.4 native in-page handoff to
convert nsieve:24's 94.9% coverage into wall-clock.

## Status 2026-08-12 (LATEST-32) — **A-vii-d + A-vii-d.1 LANDED: edge 4 is ARMED AND FIRING (bridge fused ~25k/run on nsieve). NEXT = commit → codex post-landing review → A-vii-e measurement.**

The flip is live end-to-end. A-vii-d proper (flag flip, `tryArmRegionBridge`
with the §A-vii.2 gates + permanent decline probes, arm/fused counters +
jit-stats lines) landed first; grounding then showed the spec'd arm site was
unreachable (two gaps, doc 17 A-vii-d.1 entry), and the corrected design —
gpt-5.6-sol design-reviewed, five blockers folded — landed on top:

- **Gap 1 (discovery):** a branch guard's committed exit pc is the H-1b
  re-execute pc, never the opposite path's landing anchor, so the cont→skip
  edge never entered `edge_cache`. Fix: `resolveCompositeBridgeSuccessor`
  overlay — opposite-polarity static-CFG target, walk across `jmp` + at most
  ONE numeric `for_loop` continue edge, with `compositeContinueProof` (exact
  recForLoop dataflow: both written slots {a, a+3} phi-bound to the same add
  ref R, a dominating `.loop_done` guard whose `le` consumes R) GATING
  publication. Plus the closed-SCC owner fix: no boundary edge exists into a
  fully-closed SCC, so owner = `(ext_entry ∨ enclosing) ∧ inner_root` where
  `enclosing` = the member whose for_loop body span contains all other
  members. nsieve now mints `id=1 members=3 armable=true owner_unique=true
  bridges=1`.
- **Gap 2 (receipts):** composite deopts never surface at driveChain's head
  on nsieve. Arm sites now: driveChain head (kept), the chain-run "not a
  completed link run" exits, and — two-phase — `pending_bridge_arm` recorded
  by replayLedger's terminal composite `.deopt` row, drained by all four
  ledger drivers AFTER the walk.
- **Landing surfaced 3 more consumer gaps, all fixed + test-pinned:**
  (i) driveChain's hop-0 scalar seam misread the 2-row `[C.region_bridge,
  S.term]` ledger as the `[C.link, I.x]` fused shape → bridge-headed ledgers
  route to driveSeedLedger (head grammar now accepts a `.region_bridge` first
  row). (ii) A bridged successor runs mode 0 → its terminal `.deopt`/
  `.prologue_fail` resumes at ITS OWN anchor (the bridge row published it
  into resume_pc; hard-verified), ordinary loop-done legal — never link_pc.
  (iii) The mid-walk disarm hazard generalizes review blocker 5:
  `flushRegionWindow` strikes / `invalidateRegion` run per ledger row and
  called `disarmAllLinks` MID-WALK, erasing the armed provenance the same
  ledger's fused M1 rows validate (measured panic the moment the region gate
  went live). `disarmAllLinks` defers under `replay_walk_depth`; drivers
  `applyPendingDisarms()` right after the walk, before the bridge-arm drain
  (a deferred disarm also drops the pending arm, fail-closed).
- **Stale-region lifecycle (review blocker 3):** `NativeLink.{kind,
  region_id}`; `.region_bridge` replay rows validate through the armed
  link's EXACT region (def live + armable + edge in THAT def, no global
  scan); every rebuild ends with `disarmStaleRegionBridgeLinks(live_armable)`
  and every fail-closed empty-physical path disarms all bridge links.

Measured (ReleaseFast, nsieve 9): `link arms: … bridge=961`, `link fused: …
bridge=25186`. Six-workload output-identity control ALL-PASS against the
frozen hashes (nsieve 4053ed86223d7060, nbody 9dcd7fa2f7e9e93e, sieve_int
db55c0f98f98851b, pi_leibniz f57ace5316c0fd19, grid_matmul 395ff5566b31eb18,
field_hash 89b64d3d25ae188f), native ≡ tier-0. Gates: `just test` green (835),
`zig build test -Djit-debug=true` green. New tests: overlay polarity/jmp/
self-edge; continue proof (pass + 2 violation shapes); bridged `.loop`-ending
successor terminal incl. ordinary loop-done; disarm deferral; stale-region
rebuild sweep; two-phase pending arm. Doc 17 A-vii-d.1 entry + status header
updated.

Remaining: commit, codex post-landing review (fix findings on own judgment
per Bart's standing mandate), then **A-vii-e** per the frozen protocol
(`just bench --filter nsieve --reps 7`, per-anchor `--jit-stats` both trees,
output equality first, report flat/negative honestly, Z-6 no special-casing).
§A8 step 7 ticks only after e. NB for A-viii: the observation-window disarm
churn (~2k disarms/run) now interacts with bridge arm persistence — bridges
re-arm each round trip (961 arms/run), worth revisiting there.

## Status 2026-08-12 (LATEST-31) — **A-vii-d.0 LANDED: armability recomputed per rebind; the region gate machine is LIVE on real shapes. NEXT = A-vii-d proper (the driveChain arm + region_bridge_arming_enabled=true).**

The A-vii-d opening question is answered. A permanent `region: owner-scan`
jitdbg probe on nsieve showed the owner predicate is RIGHT — `both_count`
evolves 0→0→1 across rebuilds as the external-entry side trace records — but
armability was frozen at first sight (`eff_armable = stored.armable ∧ …`,
monotone-decreasing), and first sight NECESSARILY precedes the entry edge: the
internal cycle is what triggers minting, and the entry source is a guard-hot
side trace recorded later. So every real region was first-seen unarmable and
could never rise. Fix (general, Z-6-clean): discovery recomputes
`armable = owner-unique ∧ membership-complete ∧ !tombstoned` on EVERY rebind, in
both directions, via a staged armable-update list; the fail-closed stickiness
moved to a new `RegionDef.tombstoned` bit (set by `invalidateRegion` and by
incompatible/truncated rebinds, never cleared). "Graph incomplete when we
looked" is now recoverable; "misbehaved" stays permanent.

Measured: nsieve arms on the entry-edge rebind (`rebind id=0 armable
false→true owner_unique=true`); the matrix sieve shape arms in the harness; the
A-vii-c dormancy tripwire fired exactly as designed and is upgraded to the
EXERCISED oracle (renamed back to `assertRegionGateExercised`: ≥1 armable
region, ≥1 live indexed member, ≥1 authoritative window flush on every execute
leg). The consumption boundary and the replayLedger double-charge fix are now
exercised by the matrix, not only by synthetic unit tests. New trace.zig unit
test pins the lifecycle: first-sight unarmable (excluded from physical
indices) → entry-edge rebind arms + indexes → invalidateRegion tombstone sticky
across an identical rebind.

Gates: `just test` green (829); `-Djit-debug` green; six-workload tier-0≡native
output control ALL-PASS (output contract — selection now genuinely diverges on
region shapes, and that is the designed A-vii-c surface finally non-empty).

Remaining for A-vii-d proper: the driveChain arm site (§A-vii.2 steps 1-3,
beside the M1 `.ordinary_guard` arms), `region_bridge_arming_enabled = true`,
arm/handoff integration tests, the `.region_bridge` no-owner-penalty firing
test, confirm `invariant_slots = S \ E` soundness, keyframe restore equality.
Then A-vii-e measurement per the frozen protocol.

## Status 2026-08-12 (LATEST-30) — **A-vii-c.1 consumption-keyed accounting boundary LANDED (closes the codex BLOCKER on A-vii-c) + region-dormancy tripwire. NEXT = codex re-review → Bart APPROVE → A-vii-d (which is itself blocked on the `armable_owner` question below).**

Codex `gpt-5.6-sol` reviewed the A-vii-c commit and returned **BLOCKER**,
correctly: membership-keyed suppression assumed physical membership in a live
region implies the region machine can gate that trace's receipts. It does not.
A member's prologue failure has no valid `ExitKey`; an exit absent from
`edge_cache` resolves to no candidate; and a structurally zero-work receipt is
deliberately silent (R2-1). The dispatcher sends exactly that last shape on its
zero-iteration path (`interp.zig`, comment: *"Zero iterations: apply the
penalty"*), so a member failing its guard on every entry was gated by NEITHER
machine — and the landed unit test pinned half of that unsafe state as if it
were the contract. Verified in the tree before acting.

**Fix (Bart's call, option (a) taken further): the boundary is CONSUMPTION, not
membership.** `accountRegionProfit` now returns whether it consumed the receipt
(nonzero work credited to a live accumulator); callers that also run selection
accounting apply `accountLegacyThrash` iff it did not. `traceHasRegion` is
deleted. Exactly one machine accounts every trace-run receipt, provable from the
call site rather than inferred from an index, and every shape the region machine
cannot gate falls back to pre-flip behaviour by construction. Null-keyed
`onSideExit` never consumes ⇒ that path is pre-flip verbatim. Ordering is
region-first then legacy (receipt-local verdict last). One deliberate exception,
documented in code and doc: `replayLedger`'s `.region_bridge` arm stays
selection-only — its ownership is *proven* by the replay grammar, and legacy
striking there would gate productive regions once per intra-region hop.

**Measured while hardening the matrix (codex finding 2): on every workload
measured so far the region gate machine is DORMANT — A-vii-c is inert on them.**
A new permanent `region: mint` jitdbg probe shows the test sieve shape AND
nsieve both mint their cross-trace cycle with `armable=false`
(`members=2 owner_unique=false membership_complete=true`): `armable_owner` wants
exactly one component node that is both externally entered and carries an inner
root (`both_count == 1`), and neither shape satisfies it. `openRegion` refuses
non-armable defs, so no accumulator opens and `flushRegionWindow` is not reached
outside unit tests. Hence the byte-identity control still passes unchanged —
dormancy, not a contract. Scope it honestly (re-review finding 2): two
observations, NOT a recorder invariant — discovery does accept a synthetic
`both_count == 1` graph in the unit tests. **This blocks A-vii-d** on those
workloads: the arm site could never fire. First question for that piece is "why
does no recorded shape reach `both_count == 1`, and is it the right predicate?",
ahead of writing the arm.

Second-round fix (re-review BLOCKER, same session): `replayLedger` was
discarding its per-row `region_consumed` while its kind arms took their
selection receipt through `onSideExit` — re-entering the region machine with a
second null-keyed receipt AND applying the legacy verdict unconditionally, so a
consumed `.loop_done_linked`/`.deopt` row would be charged by BOTH machines once
armability exists. The arms now use `accountLedgerRow(owner, completed,
region_consumed)`; the `succ` zero-exit receipts keep `onSideExit` (no region row
of their own ⇒ unconsumed by construction). New positive-control replay test:
a consumed `[I.loop_done_linked, C.deopt]` pair takes no legacy strike on either
anchor while the region accumulates 4 traversals; the pre-existing
`[I.loop_done_linked, C.prologue_fail]` grammar test is the negative control.

Tests: the 10-mode matrix now runs at `hotguard=3` through a new
`expectProgramTuned`/`CapturedOpts` harness (post-run `inspect` hook against the
live VM) and asserts the measured truth as a **tripwire** — region discovered,
`armable == 0`, `flushes == 0` — so the moment A-vii-d makes armability
reachable this test FAILS and forces an upgrade to the exercised form instead of
silently passing. The redundant single-mode companion is deleted. The
gate-machine unit test's member half is rewritten to pin consumed (no strike) vs
unconsumed-zero-work / unconsumed-unclassified (strike) / unconsumed-useful
(clears) / tombstoned (reverts to legacy).

Gates: `just test` green; `zig build test -Djit-debug=true` green; ReleaseFast
six-workload tier-0≡native control ALL-PASS (same six prefixes as LATEST-29).

## Status 2026-08-11 (LATEST-29) — **A-vii-c gate-consumption flip LANDED with the regionless fallback (first selection-diverging step).**

The flip: `accountTraceRun` is now selection-only (coverage/cycle receipts +
`hit_count`; the per-trace penalty/gate block is gone). The authoritative gate
machine is `flushRegionWindow(key, work)`, owner-keyed per `RegionDef.owner`:
`work >= min_useful` clears the owner's penalty+gate; `0 < work < min_useful`
strikes; at `max_penalty` → `gateAnchor(owner)` + `disarmAllLinks()`.
`accountRegionProfit` is the only full-window consumer and latches
`RegionAccum.useful_window_seen` (the A-vii-d qualification seam); `closeRegion`
routes its nonzero remainder through the same machine (zero-remainder closes are
silent). `region_bridge_arming_enabled` stays `false` — no behavior-changing arm
yet.

**Design-gap discovery (the important part).** The design's premise that
"self-loop/lone-trace regions reproduce the old useful/low-yield decision" is
FALSE: discovery mints regions only for cycle-bearing SCCs of the cross-anchor
structural-edge graph (`resolveSuccessorAnchor` rejects `wp == t.anchor.pc` for
guards; `rebuildRegionsFallible` needs `comp_size >= 2 or has_self`). Plain loop
traces and same-anchor sibling groups get NO region, so a spec-faithful flip
left them entirely ungated — measured: parity loop `if i % 2 == 0` → two sibling
traces at `main:5`, **961 trace entries / 2000 iterations, no gate** (old
machine gated after 8); 7 pre-existing tests broke. Escalated to Bart;
**his call = the regionless fallback**: receipts of a physical member of a live
(armable) region — membership via `dest_entry_regions.get(trace_id)` + per-id
`def.armable` recheck (`traceHasRegion`), so tombstones bite immediately — are
penalty-neutral on the selection side; every other trace keeps the exact
pre-flip per-trace machine (`accountLegacyThrash`, keyed by its own anchor,
driven by `completed`), on both `onSideExit` and `onSideExitReceipt` paths.
Consequence: selection is byte-identical for ALL non-region shapes (the entire
pre-existing suite passed unchanged); the divergence surface is exactly
region-member traces. Doc 17 has the full addendum ("A-vii-c correction at
landing") + corrected byte-identity boundary note; sub-step 3 ticked; §A8
step 7 stays UNTICKED (d/e remain).

Tests: rewrote the A-ii.1 split pin as "regionless onSideExit keeps the legacy
gate; bare accountTraceRun is selection-only"; new trace.zig gate-machine test
(N=8 windows qualify+clear owner, sub-N remainders strike, max_penalty gates +
disarms an armed link, tombstoned member reverts to legacy); new interp.zig
10-mode matrix test on a region-forming mini-sieve (numeric-for inner loop —
a while inner does NOT close the cycle) + an introspection companion pinning
`region_defs.count() >= 1` at hotguard=3 (at default hotguard the shape mints
no region and the matrix test would silently not exercise the flip).

Gates: `just test` green (828 tests); `zig build test -Djit-debug=true` green;
ReleaseFast six-workload tier-0≡native output-identity control ALL-PASS
(nsieve `4053ed86223d7060`, nbody `9dcd7fa2f7e9e93e`, sieve_int
`db55c0f98f98851b`, pi_leibniz `f57ace5316c0fd19`, grid_matmul
`395ff5566b31eb18`, field_hash `89b64d3d25ae188f`).

Process note: codex is REVIEW-ONLY now (usage limits); Claude implements.
Codex review of this diff requested by Bart — run via `mcp__codex__codex`
(read-only sandbox, no model pin). A-vii-d next: arm-site flip
(`tryArmRegionBridge` in `driveChain` beside the M1 `.ordinary_guard` arms,
`region_bridge_arming_enabled = true`), must confirm the `invariant_slots =
S \ E` soundness assumption flagged at A-vii-b; then A-vii-e measurement per
the frozen protocol.

## Status 2026-07-25 (LATEST-28) — **A-vii-b descriptor/validator LANDED, unarmed + byte-identical-inert. NEXT = A-vii-c gate-consumption flip.**

`RegionDef` now owns canonical-sorted per-bridge descriptors containing the exact
`StructuralEdgeId`, successor `AnchorKey`, `required_slots = S`, and proven
edge-invariant slots. Discovery computes `S` by a backward-liveness fixed point
over the entire SCC: each anchor starts with the union of its physical member
traces' `entry_slots`; successor live-ins propagate backward over every internal
edge until stable, with a dominance-safe slot phi defining the slot on that
edge. A bridge therefore retains its successor entry slots plus values that stay
live through later region edges, rather than approximating `S` from child
inputs. All descriptor and nested slot slices are allocator-owned, staged before
infallible publish, replaced on same-`RegionId` re-record, and freed from staged
rollback, `TraceState.deinit`, and `clearCache`.

`nativegen.compositeBridgeEmissions` is the sole immutable-IR query for A-v's
emitted set `E` (slot-bound phi, non-internal, `p.b < exit_instr`).
`emitCompositeBridgeSnapshot` and the arm-time `compositeBridgeEmitsSlot`
predicate both consume that query. The new resolver preserves existing stable
highest-`hit_count` selection while requiring the physical child to be listed
for the same `RegionId` in `dest_entry_regions`, excluding same-anchor siblings.
`validateRegionBridge` is allocation-free and publish-incapable: it resolves the
stored exact edge, proves every `S` slot is in `E ∪ invariants`, independently
requires `child.inputs.len == 0`, and returns only `{child, bridge}`. Failure
uses `invalidateRegion`; success and failure install no `NativeLink`.

The focused discovered-cycle test proves `S={r0,r1,r2}` from child
`entry_slots={r0,r1}` plus live-through `r2`, `E={r0}`, and
`invariants={r1,r2}`. It covers the positive decision, higher-hit non-member
sibling exclusion, missing-live-through-proof tombstoning, seeded-child
tombstoning, same-logical-region descriptor replacement after fresh physical
trace IDs, owned-slice leak checking, zero `armed_links`, and the parent slot
remaining `shared_exit`.

Gates: `just test` green; `zig build test -Djit-debug=true` green. ReleaseFast
tier-0 and `--trace --jit-native` both match all expected SHA-256 prefixes:
nsieve `4053ed86223d7060`, nbody `9dcd7fa2f7e9e93e`, sieve_int
`db55c0f98f98851b`, pi_leibniz `f57ace5316c0fd19`, grid_matmul
`395ff5566b31eb18`, field_hash `89b64d3d25ae188f`.
`region_bridge_arming_enabled` remains `false`; there is no `driveChain` caller,
no `.region_bridge` publish path, and §A8 step 7 remains unticked.

---

## Status 2026-07-25 (LATEST-27) — **A-vii-a strict bridge replay LANDED, unreachable + byte-identical-inert. NEXT = A-vii-b descriptor/validator.**

Replaced only `replayLedger`'s `.region_bridge` tripwire with the additive
A-vii.3 grammar. Replay now requires a normal, non-yielded, non-final composite
guard; resolves the next owner; proves the exact `{parent, slot, child}` backlink
in `armed_links`; and resolves exactly one live `RegionDef.members` edge from the
owner anchor plus committed `ExitProvenance`. Missing, duplicate, tombstoned, or
successor-mismatched edges release-`@panic`. The coherent resume cursor comes
from the stored child anchor, never merely `guardExitPc` or the next ledger row.
The bridge accepts nonzero cumulative progress and sends `max(local, 1)` through
`accountTraceRun`; its already-separate region-profit receipt remains structural
work zero with the known successor.

The synthetic replay guard constructs
`[cont.region_bridge(cum=3), skip.deopt(cum=5)]`, the armed backlink, and an
owned registered region edge directly. Its stored skip PC deliberately differs
from the guard exit PC, proving the returned cursor is region-owned; `N=3`
proves the bridge's synthesized selection completion increments the continuation
hit exactly once while the skip's local work remains independently low-yield.
The pinned Zig stdlib has no in-process panic-expectation helper, so the four
release-panic negative paths are explicit in the arm and documented by the test.
All allocations use `std.testing.allocator`; `TraceState.deinit` owns the copied
region slices and the stack-owned trace cache is detached before teardown.

Gates: `just test` green; `zig build test -Djit-debug=true` green. ReleaseFast
tier-0 and `--trace --jit-native` both match the expected SHA-256 prefix for all
six controls: nsieve `4053ed86223d7060`, nbody `9dcd7fa2f7e9e93e`,
sieve_int `db55c0f98f98851b`, pi_leibniz `f57ace5316c0fd19`, grid_matmul
`395ff5566b31eb18`, field_hash `89b64d3d25ae188f`.
`region_bridge_arming_enabled` remains `false`; no driveChain arm site,
descriptor/validator, gate-consumption, M1 `.deopt`, monotonic-cumulative, or
zero-progress/terminal rule changed. §A8 step 7 remains unticked.

---

## Status 2026-07-25 (LATEST-26) — **A-vi native-F2c logical-cut harness LANDED, inert + green. NEXT = A-vii (arm edge 4 + region-profit gate) per §A8 step 7.**

A-vi landed in three ordered pieces. Piece 0 bumps keyframes to schema v6:
`FrameRef` now carries `varargs_base`/`varargs_count`, generated Zig/TypeScript
codecs were regenerated, capture serializes them, and restore validates their
canonical/range/proto shape before rebuilding frames through `pushFrameVararg`.
The live-vararg suspend/resume guard proves byte-identical mid-keyframe
round-trip plus identical forward output/final state.

Piece 1 adds VM-local `committed_effect_seq` and the single
`onEffectCommitted()` hook. Its four post-validation call sites are normal
native effects, lazy random-seed materialization, a genuinely new Unicode pin
(already-consumed replay re-entry does not advance), and validated file reads.
All four families are mode-identical across off/record/replay; a fault commits
nothing. No selection/gating path reads the counter.

Piece 2 adds the optional logical `SuspendCtl.after_committed_effects` trigger:
the existing tier-0 suspend boundary walks until `seq >= N` while retaining the
`reg_top_pending` and depth eligibility gates. F-5 executes a real compiled
native numeric-for burst, commits a fixed-result clock effect, and compares the
serialized semantic keyframe plus serialized effect prefix/cursor/counter,
output prefix, and Xoshiro256 state against tier-0. It restores into an empty
trace cache, reattaches the omitted driver facets, resumes, and matches the
uninterrupted final output/keyframe/PRNG state. H-3 coverage now explicitly
proves clean-epoch wholesale clear and dirty-entry non-mutation; A-iv already
covers activation cleanup and one-per-owner cardinality.

Files touched: `schema/trace.json`, regenerated `src/gen/trace_schema.zig` and
`viz/src/gen/generated.ts`, `src/keyframeser.zig`, `src/interp.zig`, this file,
and `docs/design/17-exit-branch-patching.md`. Inertness/soundness: no arming flag
or gate changed; the new counter has test/harness consumers only; the logical
suspend field defaults null; schema v6 closes a pre-existing restore hole.
Piece-local `zig build` gates, `just test` (823/823), and
`zig build test -Djit-debug=true` (823/823) are green. ReleaseFast tier-0 stdout
is byte-identical to `--trace --jit-native` for all six controls, matching the
committed SHA-256 prefixes: nsieve `4053ed86223d7060`, nbody
`9dcd7fa2f7e9e93e`, sieve_int `db55c0f98f98851b`, pi_leibniz
`f57ace5316c0fd19`, grid_matmul `395ff5566b31eb18`, field_hash
`89b64d3d25ae188f`.

Reviewer risks: validate that `varargs_end <= frame.base` covers both bytecode
calls and host re-entry layouts; confirm every effect hook remains downstream of
its family-specific validation; stress the logical cut with multret
`reg_top_pending`; and verify the F-5 expression-temporary shape continues to
compile and execute natively (the test asserts both traced iterations and a
compiled native trace).

---

## Status 2026-07-24 (LATEST-25) — **A-v edge-4 bridge stub emission LANDED, unarmed + inert. NEXT = A-vi (native-F2c harness + H-3/H-4 tests) per §A8 step 6.**

Every composite ordinary guard accepted by the trace-local classifier now emits the
§A2.4 bridge head and dead armed body: `slot[ei] == shared_exit → ordinary_mini`,
cap-check-first at `ledger_len > LEDGER_CAP-2`, dominance-scoped phi snapshot `E`,
`.region_bridge` ledger append, and staged indirect handoff. `ordinary_mini` is shared
by unarmed and ledger-full cases and preserves today's `exit_instr → deopt_exit`
behaviour; the bridge writes no `final_trace_id` and has no forced-yield check.

Classifier/arming decisions: committed `GuardProvenance` must be a same-anchor-proto
`.branch_cond` whose source PC matches the IR guard and whose exit precedes the trace
anchor; `E` is every slot-bound phi with `update_ref < guard_index`, excluding internal
and post-guard updates. Existing `.ordinary_guard` arming rejects bridge candidates.
`ArmKind.region_bridge` derives `child.ordinary_entry` but is release-fail-fast behind
`region_bridge_arming_enabled = false`, so A-v has no publishing call site and every
bridge slot stays unarmed until A-vii.

Files touched for A-v: `src/nativegen.zig` (classifier, E snapshot, stub emission,
machine-prefix/unarmed test), `src/trace.zig` (`ArmKind`, derive-not-trust target,
inert arm guards), `src/irinterp.zig` (`LedgerKind.region_bridge` plus pre-A-vii replay
tripwire), this file, and `docs/design/17-exit-branch-patching.md`. Inertness proof:
`zig build` after each of the three requested sub-steps; `just test` green;
`zig build test -Djit-debug=true` green. ReleaseFast tier-0 output was byte-identical
to `--trace --jit-native` for all six controls, with committed SHA-256 prefixes:
nsieve `4053ed86223d7060`, nbody `9dcd7fa2f7e9e93e`, sieve_int
`db55c0f98f98851b`, pi_leibniz `f57ace5316c0fd19`, grid_matmul
`395ff5566b31eb18`, field_hash `89b64d3d25ae188f`.

Reviewer risks to check: the classifier's `exit_pc < anchor.pc` definition of outer
re-test, the slot-bound-phi-as-successor-live interpretation of `E`, and the deliberate
A-vii flip point (`region_bridge_arming_enabled` plus replay panic).

---

## Status 2026-07-22 (LATEST-24) — **A-iv `region_profit` accumulator LANDED, inert + green (reverse-authored by Codex). NEXT = A-v (edge-4 bridge stub, unarmed) per §A8 step 5.**

`accountRegionProfit` now ACCUMULATES (was a no-op) per-activation `RegionKey{region_id, activation:call_seq}
→ RegionAccum{outer_traversals, window_base, root_frame_depth, root_call_seq}` windows into a VM-persistent
`region_profit` map, but does NOT gate: `onSideExitReceipt = accountTraceRun` (byte-for-byte the legacy
tiering path) `+ accountRegionProfit`, whose full-`min_useful` windows flush into diagnostic-only counters
(`region_profit_flushes/_flushed_work`) that no selection/tiering/penalty path reads (A-vii swaps that sink
for the real gate). `observeRegionProgramPoint(proto_id, pc, depth, call_seq)` runs in the dispatch loop
behind an `if regionProfitCount() != 0` guard (no per-op call/alloc on the common path; account fns return
`void` + `getOrPut … catch return null`, so no OOM propagates into execution). Activation-scoped cleanup
drops entries at EVERY frame-destroy site — normal pop ×2 (`dropRegionActivation`) and pcall/xpcall unwind ×3
(`dropRegionActivationsFromDepth`, before the depth restore); lune has **no coroutines**, so that set is
complete. `region_profit` is transient (NOT serialized; keyframe schema stays v5) and reset at restore +
every `beginTopLevelEpoch` (`clearCache → resetRegionProfit`). §A5 cardinality (≤1 accumulator per
`(activation, owner-anchor)`) is release-`@panic`-enforced and unreachable by construction.

**Reverse-setup workflow (per Bart):** Codex designed + implemented; Claude + antigravity reviewed. The codex
MCP run overran the 30-min idle timeout (A-iv is large) and the client aborted mid-run, but the detached
subprocess left a compiling, green tree; after it went quiet I reviewed the dirty tree cold. **antigravity
returned BLOCKER (2 findings), both adjudicated N/A against lune's actual code/design:** (F4) tail-call frame
reuse — lune has no Lua-level TAILCALL opcode, every call/return is balanced through push/drop, so no orphan;
(F5) release `@panic` in `openRegion` — §A5 *mandates* a release-enforced invariant (same as A-iii's
`call_seq` exhaustion panic), and it's unreachable by construction, so downgrading to `std.debug.assert` would
violate the design. Claude verdict = APPROVE.

Guards codex added: window-persist-across-re-entry, activation-cleanup-drops-only-dying, same-activation
collision-flush, pcall-unwind-drops-entry, restore-doesn't-persist (seeds an entry pre-snapshot, asserts it
neither changes v5 bytes nor survives restore). `just test` + `-Djit-debug` green; ReleaseFast nsieve 9 /
nbody 20000 / sieve_int / pi_leibniz / grid_matmul / field_hash tier-0 ≡ `--trace --jit-native`
byte-identical (SAME hashes as the A-iii baseline ⇒ inert). Files: src/trace.zig (+428), src/interp.zig
(+35), src/keyframeser.zig (+17), src/stdlib/errors.zig (+42, pcall-unwind hook + test).

---

## Status 2026-07-21 (LATEST-23) — **A-iii `call_seq` plumbing LANDED, inert + green. NEXT = A-iv (`region_profit` accumulator) per §A8 step 4.**

Added transient `CallFrame.call_seq: u64` and per-VM monotonic `next_call_seq`. The single physical
frame-push choke point `pushFrameVararg` assigns the current key and advances it; verified both bytecode
`.call` and host-reentrant `callValue` funnel through it, with no bypass except keyframe restore. Counter
exhaustion is release-enforced by a pre-publication `@panic` at `maxInt(u64)`, so silent wrap and key reuse
are impossible. Restore deterministically re-keys the live physical stack by index and parks the next key
above it (`frames[i].call_seq = i`, `next_call_seq = depth`). No wire field and no schema bump (the tree's
existing H-2 schema remains v5); no production path reads `call_seq`, and `accountRegionProfit` stays a
no-op.

Guard coverage advances the counter in a prior epoch, suspends with several simultaneous recursive-proto
activations, proves pre-restore monotonic assignment, then proves restore + re-record index ordering and a
subsequent push at `depth`. `just test` green default + `-Djit-debug`; ReleaseFast nsieve 9 / nbody 20000 /
sieve_int / pi_leibniz / grid_matmul / field_hash tier-0 ≡ `--trace --jit-native` byte-identical.

---

## Status 2026-07-21 (LATEST-22) — **A-i `exit_prov` fail-soft parity + F5/F6 folded → re-APPROVED (checkpoint boundary still holds).** NEXT = A-iii (`call_seq` plumbing) per §A8 step 3.

Second review arc on the A-ii landing. Bart approved extending the F1-style fail-soft treatment to the
**earlier-phase (A-i) `exit_prov` dup at commit**, and the reviewer (gpt-5.6-sol) surfaced two more blockers
(F5, F6) on the way. All folded, re-certified **APPROVE**:

- **A-i `exit_prov` fail-soft parity** (Bart-approved extension). The commit-time `exit_prov` dup
  (`buildExitProv`, A-i / GuardProvenance scope) shared the same `try`-can-abort → `closeTrace`'s
  `commit() catch { gateAnchor }` pattern as F1. Made fail-soft: `if (buildExitProv(...)) |ok| {...} else |_| {
  exit_prov_complete = false; }`, published into new `Trace.exit_prov_complete: bool = true`. Unlike `rec_path`,
  a truncated `exit_prov` drops that trace's structural EDGES — and a lost *boundary* edge could shrink an
  owner's competing-entry count and spuriously ARM. So the gate is graph-wide, not per-region: at the top of
  `rebuildRegionsFallible`, any cached trace with `!exit_prov_complete` bails the whole pass (retain logical
  `region_defs`, mint nothing, empty physical via `clearPhysicalRegionIndices`).
- **F5 — wrong-arm on boundary-edge evolution (pre-existing bug, Rule #0.5).** The rebind path folded only
  `stored.armable`, never the CURRENT `cand.armable_owner`. A boundary-only graph change flips `both_count`
  1→2 while re-interning the SAME `RegionId` (identity = internal edge set, boundary excluded) → the stale
  `stored.armable=true` wrong-arms an ambiguous owner. Fixed: `eff_armable and= cand.armable_owner` (pure
  tightening — can only disarm, auto-recovers when unambiguous again) + refresh the stored `owner` via
  `staged_owner_updates` (the unique external entry can move while id stays stable).
- **F6 — `.retain` disposition unsafe.** F5's insight voids F2's "prior physical snapshot is still coherent"
  premise: a new commit can invalidate a prior owner, so retaining a physical snapshot on a rebuild OOM can
  keep a stale arm. Removed the `RegionOom` enum entirely; `rebuildEdgeCache` and `rebuildRegions` now take no
  disposition arg and ALWAYS fail CLOSED to empty (`catch self.clearPhysicalRegionIndices()` /
  `catch self.edge_cache.clearRetainingCapacity()`) — arm nothing, auto-recover next rebuild. All 28 call
  sites converted to no-arg.

New tests: exit_prov fail-soft 3-phase (complete→armed, taint one trace→disarmed + logical retained,
clear→re-armed); F5 boundary-flip (ext2→inner@7 flips `both_count` 1→2, same id disarmed, owner refreshed to
placeholder); F6 FailingAllocator (region-rebuild OOM empties physical, retains logical). `just test` **813**
green (default + `-Djit-debug`); nsieve 9 / nbody 20000 / sieve_int / pi_leibniz / grid_matmul / field_hash
tier-0 ≡ `--trace --jit-native` byte-identical (ReleaseFast).

**Commits:** `59501e2` exit_prov fail-soft + graph-completeness gate · `9029aac` F5 rebind armable_owner + owner
refresh · `6ffb3aa` F6 remove RegionOom / always fail-closed. A-i + A-ii remain inert, byte-identical across the
10 replay modes. Piece boundary (APPROVE) reached — pausing for go-ahead on A-iii.

---

## Status 2026-07-21 (LATEST-21) — **A-ii COMPLETE + APPROVED (checkpoint boundary reached).** A-i + A-ii both landed, inert, reviewer-certified. NEXT = A-iii (`call_seq` plumbing) per §A8 step 3.

**A-ii checkpoint review = gpt-5.6-sol APPROVE + antigravity LGTM.** The post-landing review (mirrors A-i)
returned **BLOCKER with four findings, all folded and re-certified to APPROVE**:
- **F1 — commit-abort tiering perturbation.** The commit-time `rec_path` dup (`src/trace.zig:~5145`) was
  `try` → OOM propagated out of `commit` to `closeTrace`'s `commit() catch { gateAnchor }`, gating the
  anchor and perturbing tiering. Made fail-soft: `catch blk: { rec_path_complete = false; break :blk &.{}; }`.
- **F2 — `.retain` not honored on upstream OOM.** `rebuildEdgeCache` cleared-then-put, so a commit-path
  OOM emptied `edge_cache` and the subsequent `rebuildRegions(.retain)` ran over an empty graph. Made
  transactional: `rebuildEdgeCacheFallible` computes `upper = Σ exit_prov.len`, `ensureTotalCapacity(upper)`
  BEFORE `clearRetainingCapacity`, then `putAssumeCapacity`; `rebuildEdgeCache(on_oom: RegionOom)` (commit
  `.retain` / retire `.empty`).
- **F3 — armable on truncated membership.** Added `Trace.rec_path_complete: bool = true` (false on a
  recorder-path OOM OR the F1 commit-dup OOM). `rebuildRegionsFallible` computes per-candidate
  `membership_complete` (all members found by `traceById` ∧ `rec_path_complete`); gates `armable` first-sight
  AND rebind (sticky tombstone on `!compatible OR !membership_complete`). Region *identity* stays purely
  structural (unaffected) → replay-stable.
- **F4 — capacity trap.** `@intCast(upper)`→`ensureTotalCapacity` could panic (`ceilPowerOfTwo(u32,…) catch
  unreachable`) past ~1.7e9. Added a `1<<30` soft-OOM guard so an over-large graph fails through `RegionOom`
  instead of trapping (unreachable in practice; the inert path must never trap).

New test: incomplete member path mints the region NON-armable, classifies nothing. `just test` **809** green
(default + `-Djit-debug`); nsieve 9 / nbody 20000 / sieve_int / pi_leibniz / grid_matmul / field_hash tier-0 ≡
`--trace --jit-native` byte-identical (ReleaseFast).

**Commits:** `6ebceb6` A-ii.4 land · `5d6a5b3` fold F1/F2/F3 · `1dcf1ba` fold F4. (Earlier this session:
`ac276da` A-ii.1 · `7b0c500` A-ii.2 · `2c4de54` A-ii.3.)

**FLAG for Bart (Rule #17, not changed unilaterally):** the `exit_prov` dup at commit
(`src/trace.zig:~5133`, `const exit_prov_owned = try buildExitProv(...)`) shares the SAME `try`-can-abort →
`gateAnchor` pattern F1 fixed, but it is **A-i scope** (already approved/landed), so I left it as-is. If you
want the commit path uniformly non-perturbing on OOM, that A-i site should get the same fail-soft treatment —
your call.

**NEXT:** A-iii (`call_seq` plumbing) per §A8 step 3. Then A-iv (`region_profit` accumulator + window +
state machine; threads a real `?ExitKey` to `accountRegionProfit`, which stays a **no-op** until then).
Subsequent: A-v (edge-4 bridge stub, unarmed) → A-vi (native-F2c harness) → A-vii (FLIP: arm edge 4 + gate B
consumes `region_profit`) → A-viii (disarm coverage). Also the Q6 `FrameRef` varargs schema-bump ticket
before F2c.

---

## Status 2026-07-21 (LATEST-20) — A-i COMPLETE; A-ii CODE COMPLETE (A-ii.1–4 all LANDED+green+byte-identical); NEXT = post-landing gpt-5.6-sol review of the whole A-ii impl (the checkpoint-APPROVE, mirrors A-i).

**A-ii.4 landed this session (uncommitted at time of writing → commit next):** `region_defs` discovery +
`RegionId` interning + classification indices + `classifyExit`, all inert. In `src/trace.zig`:
- Types: `RegionId=enum(u64)`, `RegionClassifier`, `RegionDef{members,member_points,owner,classifier,armable}`,
  hand-written `RegionInternMap` (bucket→intrusive-chain, element-wise `setsEqual`, collision-safe),
  `RegionSetBuilder(K)` + `freeRegionSetMap` helpers, `programPointLess`/`programPointsEqual`/`regionIdLess`.
- Fields on TraceState: `region_defs`, `region_intern`, `next_region_id`, `source_exit_regions`,
  `dest_entry_regions`.
- `rebuildRegions(on_oom)` → `rebuildRegionsFallible`: proto_by_id map → nodes/edges from edge_cache →
  CSR + iterative Tarjan SCC → cycle-bearing candidates → sorted-set canonical order → intern/stage
  (transactional: dupes with errdefers + pre-reserved staged lists so appends infallible) → physical
  src/dst builders → finalize → `reserve` logical maps → INFALLIBLE publish (interns, defs, tombstones,
  swap physical). OOM: commit `.retain` / retire `.empty` (`clearPhysicalRegionIndices`). `classifyExit`
  pure query. Owner = unique external-entry ∧ loop-root else placeholder+armable=false. Rebind
  tombstone on incompatible member_points.
- Wired: commit (`.retain`), removeTrace (`.empty`), clearCache (clears logical+physical), deinit (frees
  all), interp.zig:9030 flush-guard (asserts all 5 region/edge maps empty).
- 6 tests (all green): owner target graph (skip→ramp→inner→cont→skip + boundary → owner==skip@14 ∧
  armable), re-record RegionId stability, intern set-identity, sibling candidate sets, rebind tombstone,
  removeTrace-preserves-vs-clearCache-empties lifetime. `just test` 808 pass default + `-Djit-debug`;
  nsieve 9 / nbody 100000 / sieve_int / pi_leibniz / grid_matmul / field_hash tier-0 ≡ `--trace
  --jit-native` byte-identical.

**Prior sub-steps (committed earlier this session):**
- `ac276da` A-ii.1 split; `7b0c500` A-ii.2 StructuralEdgeId+edge_cache; `2c4de54` A-ii.3 rec_path.

**NEXT:** request the post-landing gpt-5.6-sol review of the whole A-ii implementation (the
checkpoint-APPROVE). Then §A8 step 3 = A-iii (call_seq plumbing). accountRegionProfit stays no-op until
A-iv (region_profit accumulator + window + state machine + threads real ?ExitKey).

---

## Status 2026-07-21 (LATEST-19) — A-i COMPLETE; A-ii DESIGNED+APPROVED; A-ii.1/2/3 LANDED+COMMITTED+green; A-ii.4 (the big one) remaining, fully grounded.

**Landed this session (all green: `just test` default + `-Djit-debug`; nsieve/nbody/mandelbrot tier-0≡native):**
- `ac276da` A-ii.1 split (onSideExit → accountTraceRun + no-op accountRegionProfit; ExitKey type).
- `7b0c500` A-ii.2 StructuralEdgeId + field-wise order/eql/hash + edge_cache + rebuildEdgeCache
  (resolveSuccessorAnchor faithful to driveChain; hasInnerRootAt; wired commit/removeTrace/clearCache/deinit).
- `2c4de54` A-ii.3 ProgramPoint + Recorder.rec_path/rec_path_ok (fail-soft recordInstr hook) →
  owned Trace.rec_path at commit; freed in destroy; reset/deinit wired.

**NEXT: A-ii.4 — region_defs discovery + RegionId interning + classification indices + classifyExit
(inert).** Full spec = doc 17 §A8-ii discovery algorithm (steps 1-4) + the round-11/12/13 folds. Concrete
build list (all on TraceState; edge_cache/StructuralEdgeId/ProgramPoint/rec_path already exist):
- Types: `RegionId = enum(u64){_}`; `RegionClassifier{kind: {self_loop,cross_trace_cycle}, member_count:u32}`;
  `RegionDef{members:[]StructuralEdgeId (sorted internal), member_points:[]ProgramPoint (sorted union),
  owner:AnchorKey, classifier, armable:bool}`.
- `RegionInternMap`: hand-written (key = variable-length sorted []StructuralEdgeId; hash-bucketed via
  StructuralEdgeId.hash fold; a hit confirmed by element-wise `StructuralEdgeId.eql`; collision mints a
  distinct RegionId). Owns a copy of the sorted slice.
- Fields: `region_defs: AutoHashMap(RegionId, RegionDef)` (Proto/VM-lifetime, NEVER removeTrace-cleaned;
  cleared ONLY in clearCache); `region_intern` (same lifetime); `source_exit_regions: AutoHashMap(ExitKey,
  []RegionId)`, `dest_entry_regions: AutoHashMap(u32 trace_id, []RegionId)` (physical, wholesale rebuilt).
- Discovery (`rebuildRegions`, called right after `rebuildEdgeCache` at commit + removeTrace):
  1. Build anchor-node graph from edge_cache (nodes = {proto_id,pc} anchors, edges = StructuralEdgeId).
  2. Tarjan SCC; each SCC with a cycle (size≥2 or self-edge) = region candidate.
  3. Internal vs boundary edge partition (boundary = leaves SCC; EXCLUDED from intern set). Sort internal
     by StructuralEdgeId.lessThan → intern → RegionId. getOrPut region_defs: first-sight build; rebind →
     compare canonical member_points → mismatch tombstones (armable=false) + exclude from physical indices.
  4. owner = UNIQUE anchor that is external-entry (dest of an incoming boundary edge from OUTSIDE the SCC)
     AND loop-root (hasInnerRootAt / a bound trace isInnerLoopRoot); else placeholder = canonically-smallest
     SCC anchor {proto.id,pc} + armable=false.
  5. Physical member = live trace realizing ≥1 internal edge (has the keyed exit whose StructuralEdgeId ∈
     members). source_exit_regions[{T.id,e}]∋R incl. boundary-leave from a member anchor realized by T;
     dest_entry_regions[T'.id]∋R only for physical-member successors. Exclude armable==false.
  - **TRANSACTIONAL + FAIL-SOFT** (round-12 findings 1/2): stage ALL (new interns, new/updated defs,
    tombstones, physical indices) in scratch, `ensureUnusedCapacity` on the live maps for the delta, then
    ONE infallible apply. OOM in staging → discard scratch, leave prior maps intact. **Commit-OOM retains
    prior snapshot; retirement-OOM publishes EMPTY physical indices** (prior refs a dead trace).
- `classifyExit(key: ExitKey) []RegionId` → source_exit_regions[key] or empty (pure query, unread, unit-tested).
- Teardown: clearCache clears region_defs+region_intern+source_exit_regions+dest_entry_regions (+ the
  interp.zig:9030 "empty after flush" guard test — ADD these maps to it); removeTrace rebuilds physical
  indices wholesale (region_defs untouched); deinit frees all (RegionDef.members/member_points owned;
  region_intern owns slices; the []RegionId values in the physical maps owned).
- Tests (mandatory): synthetic skip→ramp→inner→cont→skip graph WITH the outer incoming boundary edge into
  skip@14 → owner==skip@14 ∧ armable==true; stable RegionId; re-record (new Trace.ids) → same RegionId;
  forced hash collision → distinct id; sibling boundary-edge → candidate SETS correct (member vs non-member);
  rebind-mismatch tombstone; boundary edges excluded from intern set; clearCache empties all incl region_defs
  while removeTrace leaves region_defs intact.
- accountRegionProfit STAYS no-op (A-ii is inert end-to-end). After A-ii.4: request post-landing gpt-5.6-sol
  review of the whole A-ii implementation (the checkpoint-APPROVE), mirroring A-i.

**Watch:** Rule Z-1 `**` array-repeat needs the explicit-loop form (bit us twice). AutoHashMap value slices
([]RegionId) must be freed per-entry on clear/rebuild/deinit (iterate valueIterator) — no leak.

---
## Status 2026-07-21 (LATEST-18) — A-i COMPLETE; A-ii DESIGNED+APPROVED; A-ii.1 LANDED+COMMITTED; A-ii.2 grounded, ready to code.

**Cadence (Bart):** "First fix the current task, then design it first, then ask gpt-5.6-sol for a review,
and maybe antigravity too. Autonomous, checkpoint per piece — the piece boundary being an APPROVE."

**Where we are in §A8 landing sequence:** A-i (GuardProvenance) DONE. Now on **A-ii — region discovery +
classifier, inert** (§A8 step 2). Design note = doc 17 **§A8-ii** (search "A8-ii"), reviewer-certified:
gpt-5.6-sol rounds 11–13 BLOCKER (all folded) → **APPROVE**. Four inert sub-steps A-ii.1–A-ii.4; each
green + byte-identical (nsieve/nbody/mandelbrot tier-0≡native, `just test` default + `-Djit-debug`).

**Commits (branch master, NOT pushed):**
- `121e22a` docs(17): A-ii landing design (§A8-ii)
- `ac276da` feat(trace): **A-ii.1** accountTraceRun/accountRegionProfit split (inert) — LANDED, green.
  onSideExit (trace.zig:1759) is now an `inline` wrapper → `accountTraceRun` (old body verbatim) +
  no-op `accountRegionProfit(?ExitKey)`; added `ExitKey{trace_id,exit_instr}` (trace.zig:592). Zero
  call-site changes. Equivalence test appended after the A-i.4 test.

**NEXT: A-ii.2 — StructuralEdgeId + ephemeral edge_cache + anchor successor resolution (inert).** Fully
grounded (do not re-derive):
- `StructuralEdgeId = {anchor_proto_id, anchor_pc, exit: ExitProvenance, succ_anchor_proto_id,
  succ_anchor_pc}`. Needs **field-wise** `canonicalLessThan`/`canonicalEql`/`canonicalHash` honoring
  `inline_depth` (compare `path[0..inline_depth]` only; NO `std.mem.asBytes`/full-union `eql` — the union
  has padding + an inactive arm). Types near ExitProvenance (trace.zig:548/570), ExitKey at 592.
- **edge_cache** `AutoHashMapUnmanaged(ExitKey, StructuralEdgeId) = .empty` on TraceState; built at commit
  (after cache.append ~4148), cleared in clearCache (3664), WHOLESALE-rebuilt from surviving cache in
  removeTrace (3615, fail-closed empty on OOM), freed in deinit (1510). Read by nothing ⇒ byte-identical.
- **Successor resolution** (per driveChain, trace.zig:1893-1934, faithfully): for each **keyed** exit e
  of trace T (`T.provAt(e)` non-null):
  - `.link_terminal`: succ anchor = `{T.anchor.proto, aux}` where `aux` = the `.link` instr's aux (inner
    root pc); validate a trace bound at (proto,aux) is `isInnerLoopRoot` (1654). Else no edge.
  - guard: `wp = guardExitPc(T.instrs[e])` (454; only guard_int/float/number/true/false/int_of_float →
    non-null). Require `wp != null`, `wp != 0`, `wp != T.anchor.pc`, AND a trace bound at
    `{T.anchor.proto, wp}` (existence scan of cache — NOT findTrace's selected identity). succ =
    `{T.anchor.proto, wp}`. Else no edge.
  - succ_proto = **T.anchor.proto** (same-proto; matches driveChain's single `proto` threading).
    Cross-proto resume-proto is a known deferred refinement (nsieve doesn't exercise it). NOTE this in code.
  - **Self-loop worry was UNFOUNDED:** ordinary same-anchor deopts have `guardExitPc` null or
    `wp==anchor.pc`, so they form NO edge. Only numeric/branch guards + `.link_terminal` do.
- Tests: cache built on a hand-built 2-anchor graph incl. a `.link_terminal` edge; wholesale rebuild on
  retire; canonical-order total-order property. `Trace.id` is u32 (ExitKey.trace_id).

**Then A-ii.3** (recordInstr hook @4257 capturing `{proto.id, source_pc = pc -| 1}` per recorded op,
transient per-trace, fail-soft no-`.alloc`-abort) **and A-ii.4** (Tarjan-SCC over anchors; region_intern
w/ canonicalEql; region_defs Proto/VM-lifetime; physical member-scoped classification indices;
executable owner predicate = unique external-entry loop root else armable=false; def-consistency rebind
tombstone; transactional+fail-soft: stage-all→ensureUnusedCapacity→infallible publish, commit-OOM
retains / retire-OOM empties; classifyExit pure query; interp.zig:9030 empty-after-flush guard test).
accountRegionProfit stays no-op through all of A-ii.

**Rules kept in mind:** #13 (per-file/ bundled commits, never `add -p`), CLAUDE.md+TODO.md never staged,
#15 git allowlist, Z-1 (verify stdlib), Z-3 (green+tested), Z-6 (no single-benchmark opt), design-doc
skill (status header + checklist ticked as work lands). Monitor tool NOT used. Review model = gpt-5.6-sol
(never pin gpt-5.2*).

---
## Status 2026-07-18 (LATEST-16) — ROUND-9 LANDING PLAN written + reviewed + COMMITTED. Design-only (no code). Bart: "go back to bigger increments" → chose the round-9 landing track. gpt-5.6-sol = BLOCKER (6 defects), all tree-verified + folded.

**Bart's steer:** back to bigger increments; picked "Round-9 landing" over H-2 hard half / GuardProvenance-only.

**Plan (doc-17 §"Round-9 landing plan"):** sequences the grounded blockers into code, split by whether the
consumer machinery exists.
- **9-A (small/safe/immediate):** (i) `pure ⇒ !effect` — the H-4 barrier made structural; (ii) `depth==0`
  clean-entry precondition before `beginTopLevelEpoch`'s disarm (H-3).
- **9-B (foundational plumbing, NO consumer yet):** the `GuardProvenance` IR extension as a **transient
  side table** keyed by the **committed** instr index (NOT a field on `IrInstr`). Tag = `{path:[3]call-edges,
  source_proto_id, source_pc, role, operand}`.
- **Deferred to Increment-3 machinery** (NOT round 9): F2c native-cut harness (H-4 cut) + region cap (H-3
  cap) — need `region_profit`/native-F2c.

**gpt-5.6-sol review = BLOCKER → resolved (design only); 6 defects, ALL tree-verified before folding:**
1. **‡ THE damaging one — emission-time instr-index key is STALE at commit.** `tropt.optimize` renumbers
   (`new_index` `tropt.zig:535`), drops duplicate/always-pass guards (`:299-312`), inserts `.preheader`
   (`:530`) → a side table copied unchanged points at the wrong instrs. **Fix: provenance is remapped by
   the optimizer via `new_index` + copied by `dupe`, keyed by the COMMITTED index.** Guard-dedup survivor
   keeps its own tag (H-1c many-to-one).
2. **Tag dropped leaf `source_proto_id`** (cross-leaf-proto collision) + mis-sized path. Fix: leaf
   `(source_proto_id, source_pc)` are separate tag fields; `path:[MAX_INLINE_DEPTH=3]` holds **edges only**.
3. **"IrInstr field forces schema bump" was WRONG** — `traceser.toSchemaTrace` maps 6 fields explicitly
   (`traceser.zig:66`). Side table chosen for the 16-byte `IrInstr` budget (`trace.zig:5849`) + minority-of-
   ops, not serialization.
4. **`pure⇒!effect` at `interp.zig:916` alone insufficient** — `.manual` early-returns (`:914`), restore
   (`keyframeser.zig:606`), package (`package.zig:434`), synthetic `.pure` sets (`trace.zig:6501/6534`)
   bypass it. Fix: comptime-over-static-tables + restore-path assert.
5. **`depth!=0` "skip-reset" option UNSOUND** — `run`/`start` push a FRESH top-level frame
   (`interp.zig:1025-1035/1046-1052`), never continue; resume is via `exec()`. Fix: fail-closed only,
   **release-enforced** (error/panic, not `std.debug.assert`).
6. **Stamping list incomplete + errors** — omitted `recArrayGet` (`4277`), `recHashGet` (`4698`),
   `recForPrepLink` (`4939`); `source_pc = cur_pc−1` not `cur_pc` (post-increment `trace.zig:5394`); lane
   ordinal must NOT be an `operand` (observed input breaks determinism). Fix: stamp structurally in the
   guard `emit` helper with per-site `(role, operand)`.

- Files: `docs/design/17-exit-branch-patching.md` (§"Round-9 landing plan" + review outcome + header +
  Outstanding bullets). CURRENT_TASK.md. Committed `9acebc1` (doc-only).

**9-A LANDED (code) — `pure ⇒ !effect` + `depth==0` fail-closed:**
- `pure ⇒ !effect`: a `comptime` block over the whole static `base_natives` registry (`interp.zig`,
  after `base_natives`) `@compileError`s if any builtin sets both — structural, covers `manual` entries,
  no install-site bypass. Restore path (`keyframeser.zig:~611`) gets a `std.debug.assert` for a
  caller-supplied `NativeRegistry` (defense-in-depth; the static tables are comptime-proven).
- `depth==0`: `beginTopLevelEpoch` now returns `Error!void` and rejects `depth != 0` with a new
  `Error.DirtyTopLevelEntry` BEFORE `disarmAllLinks` (release-enforced — a returned error, not an
  assert). `run`/`start` `try` it; `catchable()` classifies the new tag not-catchable (unreachable in
  `pcall`). Doc-comment marks where the future region-clear goes (after the same guard).
- Test: "top-level re-entry on a suspended (dirty) VM fails closed" — suspends at depth 3, asserts both
  `start`/`run` return `DirtyTopLevelEntry`, then resumes via `exec()` to completion. **Negative control:
  neutralizing the check fails exactly this test (772 pass / 1 fail), silent `.suspended` misuse.**
- Gate: `just test` green (default + `-Djit-debug`); nsieve tier-0≡native byte-identical. Commit `9fcc2c4`.

**9-B DEFERRED (Bart, 2026-07-18).** The round-9 landing stops after 9-A. The GuardProvenance IR extension
is design-clean but large, must touch the optimizer (`tropt` remap of the side table — emission-index keys
are stale at commit), and has **no consumer** — so per H-1a's grounding it waits until region accounting /
Increment 3 is built and can co-design the exact tag layout it will read. Design of record is preserved in
doc-17 §"Round-9 landing plan" + the deferred Outstanding bullet. **No open round-9 work remains.**

**Remaining doc-17 candidates (not directed):** H-2 hard half (weak-intern id-timeline reconciliation +
`{gc,snapshot}` root-walk split; piece 1 `next_obj_id` v4→v5 landed) — the scope/architecture call Bart
reserved; and, eventually, the Increment-3 machinery that 9-B + the F2c-cut/region-cap pieces attach to.

## Status 2026-07-18 (LATEST-15) — H-3 + H-4 GROUNDED + COMMITTED. Design-only (no code). The two mechanics blockers, grounded against the tree. gpt-5.6-sol = NEEDS-CHANGE (both); all corrections tree-verified + folded.

**Bart's steer:** defer H-1a landing until GuardProvenance is relevant; do the small independent H-3/H-4 first.

**H-3 — region-map cap bound + `beginTopLevelEpoch` clean-entry:**
- **Scope fact:** the `region_profit` accounting map does NOT exist in the tree yet (unlanded round-3/4/5
  Part-A design) — so this grounds a *contract* the round-9 map must satisfy, plus today's epoch entry.
- **(i) Live set bounded ⇒ fail-closed/lifetime-scoped safe, SILENT evict-live banned.** `max_call_depth
  = 200` is hard (`interp.zig:119`, fixed `frames[200]`, `pushFrame` guard `:1347`). BUT `regions_per_frame
  ≤ static anchor count` was OVERSTATED (review) — regions have distinct RegionIds + can share an anchor;
  round 9 must state an explicit per-`(activation,anchor)` cardinality invariant. No global
  `max_anchors_per_proto` (dynamic load) ⇒ leans toward the lifetime-scoped (uncapped-over-live-set)
  option. Only *silent* eviction of a live armed region is banned (atomic disarm-to-fail-closed eviction
  could be safe).
- **(ii) Clean-entry gap REAL and broader than framed.** `depth` has no reset-to-zero; `pcall`/`xpcall`
  restore it directly (`errors.zig:101/109/117`), keyframe-restore assigns it (`keyframeser.zig:710`) —
  so "moved only by ±1" was wrong. The load-bearing invariant: *any* uncaught error leaves frames live
  (explicit `interp.zig:1454`; `StackOverflow` is CATCHABLE contra my draft, but catchability is beside
  the point). Second dirty-entry case the finding missed: a **suspended** VM (no fault needed). Corruption
  worse than "push above stale" — top-level `stop_depth==1` can resume a stale frame. Round 9 needs a
  **`depth==0` precondition checked BEFORE `disarmAllLinks`/map-clear** (else rejecting a run on a
  suspended VM corrupts its resumable epoch). `beginTopLevelEpoch` today only `disarmAllLinks()` (`:1012`).

**H-4 — the only implementable F2c logical cut:**
- **Mechanism:** `suspend_ctl{min_depth, after_safepoints}` (`interp.zig:418`) checked at ONE tier-0 site
  (`:1716`), safepoint-counted (`:1704`); native runs bursts and doesn't advance `safepoint_seq` ⇒ a
  safepoint cut is tier-dependent (G-4). (`suspend_ctl != null` doesn't stop native *running* — only
  disables fusion, `:2627`.)
- **Effect boundary = the one implementable tier-independent cut.** Host effects abort the trace
  (`.host_barrier` `trace.zig:5046`; only `PureBuiltin` sqrt inlines, no effect) ⇒ no effect ever commits
  on-trace ⇒ the tier-0 boundary after the Nth effect is always reached. BUT (review) the barrier isn't
  structural: `pure`/`effect` are independent fields (`function.zig:229/238`), `recCall` checks pure
  first ⇒ round 9 must **enforce `pure != null ⇒ effect == null`**.
- **"Iteration K" not implementable** (effect-free loop, native overshoots to burst end) without a new
  native logical-yield.
- **Immediate post-effect boundary NOT always suspendable** (review): multret producer sets
  `reg_top_pending` which the suspend gate refuses (`:1719/3685`); a faulting effect has no next boundary.
  ⇒ cut at "first snapshot-eligible boundary after `effect_cursor == N`" on a successful fixed-result
  effect. `SuspendCtl` has no effect-count field ⇒ harness steps one eligible boundary at a time.
- **Assertion = full semantic keyframe** (stack + frames{closure,pc,base,return-wiring,varargs} + heap +
  object-id counter + open upvalues, `keyframeser.zig:279`) **+ replay-driver** (effect log + cursor,
  OMITTED from keyframe `:2090`) **+ output prefix** — not `effect_cursor` alone. Cut after result install
  (`:2272`), never inside `logEffect`. Dovetails with H-5(i)'s omitted dead-temporary bug.

- Files: `docs/design/17-exit-branch-patching.md` (H-3 + H-4 grounding subsections + finding cross-refs +
  header). **COMMITTED** (doc-only).

## Status 2026-07-18 (LATEST-14) — H-1c GROUNDED + COMMITTED. Design-only (no code). Pinned the per-opcode guard-site vocabulary that completes GuardProvenance. gpt-5.6-sol = NEEDS-CHANGE; all corrections tree-verified + folded. The identity shrinks from G-1's 4 axes to **3**.

**Bart's steer:** keep working through the known small-scope pieces. H-1c is the last H-1 sub-part.

**Outcome — the closed guard-site vocabulary (`role`/`operand`, and why `occurrence` dies):**
- **Load-bearing finding:** the IR op kind is a *runtime-varying attribute* of a guard site, not its
  identity — `guardNum`→`guard_int`/`guard_float` by observed value (`trace.zig:4187`); `recBranch`→
  `guard_true`/`guard_false` by taken path (`4834`). So `role` must be a **structural label**, exactly the
  reason `exit_ordinal` was killed, restated one level down.
- **The vocabulary** (closed set of `role`s, corrected against the tree after review) is a per-opcode
  ordered list of `(role, operand)` guard slots — full table in the doc. Review REFUTED my first draft on:
  `set_index` container is `a` not `b`; `for_loop`/`for_prep` guard THREE operand-types (a, a+1, a+2)
  first; hash-set guards the value type FIRST; grid guards row+col types; pure-call guards its arg
  (a+1); +a missing `get_upval`/`get_global`→`guard_func` row. `guard_fits` is every-narrow-lane, not
  int-only (`4480`).
- **`role` is a closed vocab with a RUNTIME-SELECTED realized subset** (not a static function of the
  opcode): `get_index`/`set_index` route array-vs-hash by observed key type (`4052/4063`), `call` routes
  closure-vs-pure (`5033`), `get_upval` emits `guard_func` only if the input is a closure. Not fatal:
  identity must be *non-shifting under sibling elision* (the real G-1 requirement), and structural labels
  are; a differently-shaped re-recording legitimately has different guards.
- **`operand`** must be a register *designator* covering a/b/c + derived a+1/a+2 (numeric-for) + register-
  valued `aux` (grid) — not just instr.b/instr.c. Static bytecode field ⇒ stable. (`recCompare` gt/ge
  swap is AFTER guard emission, so operand tracks the source register — confirmed.)
- **`occurrence` REFUTED → DROPPED (decisive).** Recording-order is a *dynamic* ordinal (branch
  truthiness, inner-loop trip counts via `onBackEdge` peel `3588`, `for_prep` link-vs-loop by cache state)
  → it *slides*, the `exit_ordinal` failure again. Within one opcode-execution `(role,operand)` is already
  unique; duplicates arise ONLY from unrolling, whose copy-index is inherently dynamic ⇒ no stable value.
  **Resolution:** provenance keys the guest-static site `{source_pc, call-path, role, operand}`; unrolled
  physical copies **share** one tag (physical-exit→provenance is many-to-one, correct: same guest check,
  same anchor/counter). `guarded_refs` dedup makes it many-to-one the other way too (a static slot may
  emit no guard) — and my "fresh ref per unrolled iter" claim was false (invariant/konst/pure-callee refs
  stay shared).
- **Follow-on for round 9:** fused native exits aren't all `guard_*` — `hload`/`aload`/`href` side-exit at
  the producer node (`nativegen.zig:4022/4120/3517`); they need `role`s + source-PC stamps too (extends
  H-1b's stamp-every-exit obligation past the 6 PC-carrying ops).
- **Scope:** inseparable from the GuardProvenance IR extension → lands *with* it in round 9, not
  standalone (no non-speculative early subset). Files: `docs/design/17-exit-branch-patching.md` (H-1c
  grounding subsection + finding cross-ref + header). **COMMITTED** (doc-only).

## Status 2026-07-18 (LATEST-13) — H-1a GROUNDED + COMMITTED. Design-only (no code). Pinned exactly what the recorder stores for inlining vs what GuardProvenance needs, so the round-9 provenance landing is turnkey. gpt-5.6-sol = CONFIRMED directional + 3 sharpenings, all folded in.

**Bart's steer:** keep working through the known small-scope pieces. H-1a is the next H-1 sub-part.

**Outcome — the inline call-site path the recorder must carry:**
- **Gap (confirmed, real collision):** `InlineFrame = {base_off, ret_dest, ret_count}` (`trace.zig:5324`)
  stores neither the caller proto id nor the `.call` PC. `recCall` has both (`proto.id` + the call's
  source PC) but discards them (`trace.zig:5095-5099`). So `f(a); f(b)` both inlined → every guard in `f`
  gets identical `{callee_proto, source_pc, inline_depth}` AND identical `base_off` (base_off is a
  function of caller frame layout, not the call opcode) → genuine collision. Unrecoverable from *recorder*
  state (though present in the live VM call stack — `frame.pc-1` + caller `proto.id` — which recCall sees).
- **Fix:** extend `InlineFrame` with `{caller_proto_id: u32, call_pc: u32}` set in `recCall`; provenance
  path = `[(caller_proto_id, call_pc) per open frame] ++ (source_proto_id, source_pc)`. Ordered (multiset
  unsafe — recursion to depth 3 is reachable, `recCall` has no "already-inlined" check, contra doc-10).
  Deterministic: `proto.id` replay-stable (preorder compile ids, disjoint load ranges, reconstructed on
  restore), `call_pc = cur_pc-1`. Precondition: proto-id uniqueness holds for the canonical one-image +
  `load` model, not for hand-built/default-0 protos.
- **Necessary but NOT sufficient:** the ordered path is the static-inline-context PREFIX only — the
  recorder can unroll (`skipBackEdge`, `trace.zig:3580`), so the same path+leaf can emit repeatedly →
  full GuardProvenance still needs H-1c's role/operand/occurrence. H-1a delivers the prefix.
- **Cost:** +8B × 3 = +24B recorder-only; `InlineFrame`/`Recorder` are serialized nowhere (confirmed) →
  purely additive, no wire/behaviour change.
- **Land-now vs defer (Bart's call):** unlike H-1b (which replaced 8 existing derivations), these fields
  have NO consumer until GuardProvenance is built, so landing now adds 2 unread fields. Recommend **defer**
  to the GuardProvenance landing (its consumer, will co-design the tag layout); grounding spec stands.
- Files: `docs/design/17-exit-branch-patching.md` (H-1a grounding subsection + finding cross-ref +
  header). **COMMITTED** (doc-only).

## Status 2026-07-18 (LATEST-12) — H-5 GROUNDED (both hazards) + COMMITTED. Going-in hypothesis "discharge as N/A" REFUTED by gpt-5.6-sol; both hazards are REAL, tree-verified. Doc-only (no code). The grounding's value: it found two real issues and correctly folded each into an existing tracked blocker.

**Bart's steer:** pick up H-5 (both "needs grounding" round-8 items) as a small-scoped, non-breaking piece.

**Outcome — both REAL, neither independently closeable:**
- **H-5(ii) (metadata id leakage) ⊆ H-2.** No *direct* leak — trace metadata is `gpa`/mmap and never
  calls `gc.link` (the only `next_obj_id` bumper). BUT cached/in-progress trace consts are GC roots
  (`interp.zig:1560/1583`), so a trace-rooted interned string survives a sweep tier-0 would collect
  (`gc.zig:531/542`); a later re-intern allocates fresh under tier-0 (bumps counter) but reuses the
  rooted original under the JIT (no bump) → tier-dependent counter + intern identity + snapshot
  reachability (`keyframeser.zig:268`). That IS H-2's hard half. Also corrected a stale premise:
  `new_table`/`concat`/`closure` **abort recording** (`.nyi_opcode`, `trace.zig:4093`) — traces
  materialize no such guest objects today.
- **H-5(i) (dead-register poisoning) ⊆ F-5.** Confirmed safe on the cut side: suspend checked only in
  tier-0 `step` (`interp.zig:1716`), native is a synchronous trampoline returning via `shared_exit`,
  links disarmed under `suspend_ctl != null` (`interp.zig:2632/2643`), F2c serializes only after
  `.suspended` — **no cut is ever taken mid-native-frame**. BUT register coherence is FALSE: numeric-`for`
  traces omit dead expression temporaries from the exit snapshot (`trace.zig:3761`, permanent proof
  `interp.zig:9180`), so those physical slots hold stale pre-entry values after a native run while
  tier-0 overwrote them. A post-native-exit mid-execution cut serializes the full window
  (`keyframeser.zig:279`) → **divergent bytes vs tier-0**. Unreachable today ONLY because F2c's
  mid-execution harness is tier-0-only (`keyframeser.zig:1972/2014`) = the F-5 gap. This upgrades F-5
  from "unverified obligation" to "has a concrete coherence bug to catch," and makes the native-F2c
  test **mandatory before** any native mid-execution cut lands.
- Files: `docs/design/17-exit-branch-patching.md` (H-5 grounding subsection + finding cross-ref +
  header). **COMMITTED** (doc-only). No Antigravity round — counterexamples concrete + tree-verified.

## Status 2026-07-18 (LATEST-11) — FOUNDATIONAL PIECE 2 (H-1b) LANDED + COMMITTED. Named the source-opcode PC distinctly from the resume/exit PC via a canonical `guardSourcePc` accessor; centralized the 8 open-coded `guardExitPc(g)-1` derivations; fixed conflated docs. Non-breaking (no `aux`/wire/control-flow value changed). `gpt-5.6-sol` review = NEEDS-CHANGE→clean (design-only fixes). `just test` green (772, default + `-Djit-debug`), nsieve byte-identical, test proven load-bearing.

**Bart's steer (this session):** pick up **H-1b** next ("split source-opcode PC from resume PC in guard
metadata") — a foundational, non-breaking piece of the H-1 guard-provenance blocker that shrinks
round-9 scope.

**Piece 2 LANDED — H-1b source/resume PC split.** The recorder conflated two PCs: `recordInstr` gets
the *post-increment* pc (`interp.zig:1762` = `cur+1`), guards stamp it into `aux`, so a committed
guard only carried the **resume/exit** PC — while `GuardProvenance` (G-1) needs the **source-opcode**
index. Landing (recommended derived-accessor shape; heavier stored-field alt deferred to G-1):
- New `pub fn guardSourcePc(ins) ?u32` in `trace.zig` = `guardExitPc − 1` (null on the 0 sentinel) — the
  single canonical "which bytecode op owns this guard" definition.
- Rerouted the 8 open-coded `code[guardExitPc(g)-1]` source derivations through it: `irinterp.zig:229`;
  `trace.zig:489/2548/2909/2960/3089`; `nativegen.zig:3396/3617` (last drops a now-dead `exit_pc`).
- Fixed the 3 conflated doc comments (`RecState.cur_pc`, `emit`, `guardExitPc` "five"→"six") + a stale
  `countProductiveBranchExit` identity comment.
- Test `"guardSourcePc: source-opcode PC is exit PC − 1 (H-1b), pinned independently"`: review-mandated
  *independent known-index* assertion (recorded `get_index` at chosen N ⇒ `guardSourcePc==N`,
  `guardExitPc==N+1`) + `emit`-fixture for `guard_number`/`int_of_float` (never recorder-emitted) + null
  cases. Load-bearing: dropping the `−1` reddens 16 tests (10 fail + 6 crash).
- Non-breaking: no `exit_pc`/`aux` value, control-flow target, IR layout, or serialized byte changed;
  10-mode-invariant by construction. `gpt-5.6-sol` confirmed soundness + all 8 `.?` unwraps safe.
- **COMMITTED** (see below). H-1's remaining round-9 scope: `source_pc` is now a named, tested,
  single-owner accessor `GuardProvenance` reads directly.

## Status 2026-07-17 (LATEST-10) — BART DECIDED + FOUNDATIONAL PIECE 1 LANDED. H-2 fix = keyframe schema bump (reverses the "v4 stays" reshaping insight). Bart: land the safe foundational pieces first to shrink scope. Piece 1 (`next_obj_id` serialization, v4→v5) DONE — `just test` green (default + `-Djit-debug`), viz builds.

**Bart's two decisions (this session):**
1. **H-2 → fix now with a schema bump** — serialize `next_obj_id` + reconcile weak-intern identity so
   restore reproduces the id timeline regardless of tiering. Keyframe schema moves (was "v4 stays").
2. **Don't land Increment 3 all at once** — pick up the earlier foundational pieces that are
   unambiguously useful + non-breaking first, so later work shrinks.

**Piece 1 LANDED — `next_obj_id` serialization (keyframe v4 → v5):** the counter-drift half of H-2,
and a pre-existing determinism gap independent of the JIT. The restorer reconstructed the heap id
counter as `max(id)+1` (`gc.zig:149`, `keyframeser.zig:~555`) — correct only with no pre-cut garbage,
a limitation the F2c harness itself admitted (`keyframeser.zig:~1758`). Now serialized as a `Keyframe`
field and restored verbatim, validated `>= max(id)+1` (`NextObjIdBelowObjects`). Garbage-free runs are
unaffected (serialized == max+1); only the previously-unsupported garbage case becomes correct.
- Files: `schema/trace.json` (+ regenerated `src/gen/trace_schema.zig`, `viz/src/gen/generated.ts`),
  `src/keyframeser.zig` (encode/restore/version-bump/tests), `docs/design/04-snapshot-replay-schema.md`,
  doc 17 §"H-2 decision + foundational piece 1 LANDED".
- Tests: `"H-2: next_obj_id survives pre-cut garbage"` (gc_stress, garbage after survivor → counter >
  live count → restored verbatim + byte-identical round-trip; proven load-bearing by an impossible-bound
  flip that reddened exactly it) + a `NextObjIdBelowObjects` corrupt-snapshot case. 772 tests, green.
- **Not committed** (Rule #15 — awaiting Bart).

**Still owed for H-2 (the HARD half — needs its own design + review):** weak-intern identity
reconciliation + the safe `{gc,snapshot}` root-walk split. Serializing `next_obj_id` fixes counter
*drift* but a *dropped trace-only interned object* still re-interns fresh at the (now correct) high
counter ≠ its original low id. So the split stays unsafe until interned identity survives a drop —
the next H-2 design pass. Mechanics blockers H-1 (guard provenance), H-3 (cap + clean-entry), H-4
(logical cut) are untouched by piece 1 and remain round-9 design work.

**Candidate next foundational pieces (for Bart to steer):** (a) design the H-2 intern-identity half
(the hard part; design→review loop); (b) H-1b — split source-opcode PC from resume PC in guard
metadata (clean, useful, but touches the recorder — needs care); (c) pause and pick up the mechanics
design (H-1/H-3/H-4) instead.

---

## Status 2026-07-17 (LATEST-9) — ROUND-8 REVIEWED = BLOCKER (both) with a FOUNDATIONAL finding (H-2) that BOTH reviewers built the SAME counterexample for. ESCALATED TO BART — a scope/architecture decision is needed before round 9. NO code.

**The inflection (H-2 ‡‡ — foundational, escalated):** G-2's `{gc,snapshot}` root-split is necessary
but NOT sufficient. Dropping a **trace-only interned** constant (a folded string kept alive only by
the trace root, object id N) changes the observable heap-**id** timeline: the uninterrupted VM later
re-finds the interned object → recovers id N, but the restored VM (empty trace cache, no intern entry)
re-allocates → id N′ ≠ N. Object ids are **semantic** — equality `value.zig:197`, table hash
`table.zig:545`, `pairs` order `key_order.zig:21`, `tostring` `io.zig:166` — so `pairs()` output and
serialized table capacity **diverge**. Compounding: `next_obj_id` is **not serialized** (restore =
`max(id)+1`, `keyframeser.zig:521`) and the F2c test **already** only supports programs with no
discarded pre-cut objects (`keyframeser.zig:1755`) — dropping the highest-id trace-only object hits
exactly that unsupported case. **codex + Antigravity built the identical counterexample independently.**
This is **broader than Increment 3** (any trace-materialized object under snapshot) and its clean fix
likely **serializes `next_obj_id` → bumps the keyframe schema, reversing the reshaping insight** — or
restricts when snapshots may be cut. **This is Bart's call (scope + approach) before any round 9.**

**Mechanics blockers that survive (round-9 work, once H-2's direction is set):**
- **H-1 (G-1)** `GuardProvenance` still collides: `inline_depth` counts nesting not the call PATH
  (`f(a);f(b)` → same tuple, distinct exits) → need a full inline call-site path
  `[(caller_proto_id, call_opcode_pc)…]`; `source_pc` is the **post-increment** resume-PC not the
  opcode index (`interp.zig:1762`) → need both distinct; `operand`/`occurrence` under-defined for
  derived-value guards (one `get_index` guards container/lane/bounds/presence/loaded-value) → need a
  **closed per-opcode `GuardSite` vocabulary** ranked independent of emission order/elision.
- **H-3 (G-3)** mandatory deletion bounds the map but doesn't prove a bounded cap can't evict a LIVE
  entry (need cap ≥ proven max simultaneous live regions with a hard `regions_per_frame` bound, or
  fail-closed insert); `beginTopLevelEpoch` still doesn't enforce clean entry (an unconditional clear
  after a non-catchable fault deletes still-live activation accounting) → must pick reject-unless-
  `depth==0` / real reset / poisoned-VM.
- **H-4 (G-4)** "Kth committed outer iteration" is unimplementable (native runs many iterations per
  call; `suspend_ctl` only checked at dispatcher return `interp.zig:1716` → native overshoots with
  extra committed non-effect state) → only "immediately after the Nth committed **effect** opcode
  boundary" works; assert the whole logical-cut identity, not just the effect cursor.
- **H-5 (Antigravity, to ground)** dead-register poisoning on a native-frame cut; JIT-metadata id
  leakage (almost certainly N/A — object ids are `GcHeader.id`, trace IR is `gpa` metadata — but
  ground that trace metadata never touches `next_obj_id`).
- **G-5 RESOLVED** — single physical stack today; re-key invariant vacuous-but-correct.

**Trajectory note:** the exit-branch-patching *mechanics* are converging (H-1/H-3/H-4 are each
well-scoped engineering). H-2 is the outlier — a foundational JIT×replay heap-identity question that
predates and exceeds doc 17. That's why it's escalated rather than ground into a round-9 pass.

---

## Status 2026-07-17 (LATEST-8) — ROUND-7 DESIGN WRITTEN + REVIEWED = BLOCKER (both), two deep new findings on the JIT↔snapshot boundary → ROUND-8 DESIGN WRITTEN (G-1..G-5 resolved+grounded). codex+Antigravity round-8 review PENDING. NO code until round-8 review-clean.

**What happened since LATEST-7:**
- **Round-7 design pass WRITTEN** (doc 17 §Part A — round-7 design) resolving F-1..F-8, both round-6
  forks collapsed to single sound answers.
- **Round-7 REVIEW DONE (codex gpt-5.6-sol + Antigravity) = BLOCKER (both).** Four resolutions hold
  (F-3 exact-frame; F-4 allocator, reworded to "replay-equivalence conditional on no
  allocator/mcode exhaustion"; F-5 obligation; F-6 polarity). Two DEEP new findings survive, plus two
  more:
  - **G-1 ‡ (codex STILL-BLOCKER + Antigravity UNSOUND)** — round-7's `exit_ordinal` by IR position
    is NOT re-recording-stable: recording is guest-value-dependent (`guardNum` picks int/float
    `trace.zig:4165`, array-guard sequences vary `:4255/:4382`, type-feedback guard elision / LICM
    shifts ranks). AND grounded: `guardExitPc` (`trace.zig:451`) supplies `exit_pc` for ONLY the 5
    PC-carrying guards + `int_of_float` — array/table/grid guards leave `aux`=lane/zero, so the IR
    **cannot** key those exits at all today.
  - **G-2 ‡ (codex STILL-BLOCKER — THE DEEP ONE, I confirmed against the tree)** — the transient
    trace cache roots heap objects INTO the serialized snapshot. `keyframeser.zig:265` seeds its
    reachable-set walk from the shared `forEachRootHeader`, whose **item 5** (`interp.zig` ~1560/1583)
    roots every cached-trace + in-progress-recording const; its own comment: *"a cached trace can
    outlive its proto's reachability."* So a tiering-dependent `region_profit` history → different
    live traces → different otherwise-dead heap objects retained → **final-snapshot bytes can
    differ.** Round-7's "the snapshot carries neither field so bytes are unchanged" is FALSE (roots
    leak in indirectly). Latent today only because the F2c harness is tier-0-only.
  - **G-3 (codex STILL-BLOCKER)** — monotonic keys stop mistaken-reuse, but a bounded/LRU cap can
    still **evict LIVE activation accounting** → perturbs region gating; and no enforced clean-entry
    rule (`run`/`start` don't require `depth==0`).
  - **G-4 (codex STILL-BLOCKER for cuts)** — a native F2c cut selected by safepoint count is
    tier-dependent (native runs fewer dispatch safepoints → `suspend_ctl` cuts at a different logical
    point → different-length effect-log prefix).
  - **G-5 (Antigravity)** — cross-stack coroutine re-key collision: grounded **N/A** (lune has ONE
    physical stack; keyframeser has no multi-stack path). Invariant pinned for a future coroutine
    feature.
- **Round-8 design pass WRITTEN** (doc 17 §Part A — round-8 design), grounded (`guardExitPc` gap +
  the shared-root serializer seed both verified in the tree):
  - **G-1** → abandon the IR-position ordinal; stamp a guest-logical `GuardProvenance`
    `{source_proto_id, source_pc, inline_depth, role, operand, occurrence}` at guard emission for
    ALL guard kinds (a new IR metadata obligation). Key is a pure function of guest semantics →
    stable across re-recording **by construction of the tag**, not by asserting recording-determinism
    over guest-value-dependent inputs.
  - **G-2 ‡** → split `forEachRootHeader(kind: {gc, snapshot})`. Collector uses `.gc` (unchanged —
    trace consts stay rooted, never prematurely freed). `keyframeser` uses `.snapshot` (trace +
    recording consts **excluded** from the serialized walk). Proof: every trace const is either
    (case 1) also semantic-reachable ⇒ excluding the trace edge changes nothing, or (case 2)
    trace-only ⇒ **semantically dead** because deopt resumes at the loop header and *recomputes* it →
    correctly dropped. Makes ALL snapshotting JIT-independent **by construction** — the general fix.
  - **G-3** → make activation-scoped cleanup MANDATORY (delete each `region_profit` entry at frame
    pop `interp.zig:2345/2364/2395` + all three `protectedCall` unwinds `errors.zig:100/108/117`,
    centralized with the depth restore). Entry lifetime = activation lifetime ⇒ the map holds only
    live accounting ⇒ the cap can **never** evict a live activation (defeated by lifetime
    construction, not a heuristic). Plus unconditional `beginTopLevelEpoch` region-clear.
  - **G-4** → define the native F2c capture cut by a **tier-independent logical event** (Nth
    committed effect / Kth committed outer iteration), assert on the effect-log **cursor/prefix at
    that logical cut**, not on safepoint counts; final-snapshot byte-identity now enabled by G-2.
  - **G-5** → pin the single-stack re-key invariant (if coroutines/multiple serialized stacks are
    ever added, `call_seq` re-key MUST become global-flat monotonic across all stacks).
  - Keyframe stays **v4**. Two new impl obligations: the **`GuardProvenance` IR extension** and the
    **`{gc,snapshot}` root-walk split**.

**Next:** launch codex gpt-5.6-sol + Antigravity round-8 reviews (stress G-1 provenance-tag
determinism, G-2 the case-1/case-2 semantic-root proof — esp. whether any trace-only const is
semantically LIVE-but-unreachable-from-semantic-roots, G-3 mandatory-sweep completeness). If clean,
design is implementation-ready (still NO code until Bart's workflow confirms review-clean). If new
blockers, iterate to round 9.

---

## Status 2026-07-17 (LATEST-7) — ROUND-6 DESIGN WRITTEN + REVIEWED. Reshaping insight SURVIVES; BLOCKER on the restore path → ROUND-7 needed (F-1..F-8, two forks for Bart). NO code until round-7 review-clean.

**What happened since LATEST-6:**
- **Three parallel tree-grounding sweeps** ran first (trace inlining + deopt frame reconstruction;
  keyframe/snapshot schema + versioning; coroutine + error-unwind model) so round 6 is code-anchored.
- **Round-6 design pass WRITTEN** (doc 17 §Part A — round-6 design) resolving E-1..E-7 around **one
  reshaping insight ‡**: `region_profit` + `call_seq` are **transient JIT-tiering state, NOT
  replay-serialized** (same category as the trace cache / `safepoint_seq` / `effect_cursor` — none
  ride the keyframe) because they steer only *which tier* runs, never *what it computes* (native ≡
  tier-0 in output). That **collapses E-5 to NO keyframe v4→v5 schema bump** (reset-on-restore, the
  reviewers' own "logical reset" alternative) and **collapses E-2** (activation key = the *anchor*
  frame's `call_seq`, assigned in tier-0 at `pushFrameVararg` interp.zig:1346, never mutated
  on-trace since inlined callees push no physical frame → tier-invariant, no new IR op). This is a
  **deviation** from LATEST-6's recorded "build the v4→v5 schema" — flagged in-doc for veto.
- **Round-6 REVIEW DONE (codex gpt-5.6-sol + Antigravity) = reshaping insight SURVIVES / BLOCKER.**
  - codex (read the tree): **"a v4→v5 schema bump is not inherently required"** → **E-5 deviation
    VINDICATED, keyframe stays v4.** Marks E-3/E-4/E-6 RESOLVED.
  - Antigravity: UNSOUND, but its sharpest counterexamples are **defused by lune facts codex
    verified** — address-dependent `pairs()` (lune iteration keyed on monotonic `GcHeader.id`,
    address-independent), side-exit callee-frame reconstruction (lune resumes at loop header, no
    rebuild), `__gc` finalizers (finalizer-free GC), background compilation (synchronous). Recorded
    as "we checked, doesn't apply" notes that strengthen the doc.
  - **Surviving round-7 blockers (F-n), the work is restore-path precision:**
    - **F-1 ‡** `StructuralEdgeId{proto,anchor_pc,exit_pc,succ_anchor_pc}` can **collide** — recorder
      emits multiple guards per bytecode instr, all sharing `rec.cur_pc` (trace.zig:3956/4084). FIX:
      add a stable guard-ordinal + role/op/polarity discriminator, proven stable across re-recording.
    - **F-2 ‡ (the central correction)** restore is a physical-frame construction path
      (`keyframeser.zig:671` writes `vm.frames[i]` directly, bypassing `pushFrameVararg`), so
      "reset call_seq=0, per-frame irrelevant" is **WRONG**: restored live frames can enter regions
      and recursive snapshots hold several live same-proto instances needing distinct keys. FIX:
      reset `region_profit` empty; **assign each restored live frame a fresh unique transient
      `call_seq` by frame order**; set `next_call_seq` above that range. Still **no wire field**
      (map empty) → v4 holds; only the reset *procedure* changes.
    - **F-3** activation key must be the EXACT current physical frame (`frames[depth-1]`), not a
      proto match (wrong activation under recursion); + `next_call_seq` exhaustion contract (u64 wrap
      → fail-closed).
    - **F-4 (FORK for Bart)** JIT + VM share the backing allocator → a divergent post-restore tiering
      timeline can OOM one timeline only (truncated output). Options: (i) exclude allocator exhaustion
      from replay equivalence, (ii) isolate/budget JIT allocations, (iii) fail-closed policy.
    - **F-5** current F2c/F2d harness is tier-0-only (keyframeser.zig:1863/1905) → owe a
      **native-F2c test** (restore with empty trace/region cache, re-enable JIT, assert output +
      effect order/cursor + final snapshot byte-identical).
    - **F-6** E-6 exit-test polarity in the round-6 text is **backwards** — correct: close region iff
      `outside-region identity AND current_depth <= captured_anchor_depth` (deeper re-entrant call →
      anchor still live → don't close).
    - **F-7 (FORK for Bart)** non-catchable faults don't guarantee whole-VM teardown (host may reuse
      the VM). Options: (i) explicit VM reset dropping activation-owned region state, (ii) cleanup at
      every public execution boundary on escaping error, (iii) documented poisoned-VM invariant. Also
      centralize accumulator cleanup with `protectedCall`'s **3-site** depth restore
      (errors.zig:100/108/117).
    - **F-8** ground (not assert) that a tier-dependent `safepoint_seq` count can't perturb the
      serialized effect-log ordering/cuts. Almost certainly a non-issue (native already runs fewer
      safepoints; `safepoint_seq` re-derived, not serialized) but must be verified in the tree.
    - Phrasing: soften "native ≡ tier-0 by construction" → **asserted by the 10-mode matrix
      (P-EBP-1), not assumed by construction.**

**NEXT ACTION:** Round-7 design pass folding F-1..F-8. Ground F-4 (allocator sharing) + F-8
(effect-log cut drivers) in the tree first. Present the two forks (F-4, F-7) to Bart. Then
re-review (codex gpt-5.6-sol + Antigravity). NO code until round-7 is review-clean. Task #21.

---

## Status 2026-07-17 (LATEST-6) — ROUND-5 DESIGN WRITTEN + REVIEWED = BLOCKER (both). Edge-4 bridge mechanism (D-1/D-2/D-6) now SOUND; surviving blockers are cross-cutting integration surfaces (E-1..E-7). The review RE-WEIGHTS Bart's D-3c=β choice → **α/β RE-CALL surfaced to Bart**. NO code until round-6 review-clean.

**What happened since LATEST-5:**
- **Round-5 design pass WRITTEN** (doc 17 §Part A — round-5 design, D.1–D.6) folding Bart's
  D-3c = **(β) build activation discrimination** via a per-VM monotonic `call_seq` on `CallFrame`.
- **Round-5 REVIEW DONE (codex gpt-5.6-sol continued its own thread + Antigravity) = BLOCKER (both).**
  Both RESOLVED D-1 (two-cell cap reserve — codex verified the induction against the real append
  sites), D-2 (set E vs S, drop `final_trace_id`), D-6 (precisions). Surviving items (doc 17
  §Review outcome — round 5 as E-1..E-7) are NOT bridge flaws — they're integration surfaces the
  round-5 machinery pulls in:
  - **E-1 ‡ `RegionDef` must not be keyed by ephemeral `Trace.id`.** Persistent region_defs is
    Proto/VM-lifetime but members = `(trace_id, exit_instr)`; re-recorded edges get NEW ids
    (trace.zig:3841) after retirement (:3397) → won't match. FIX: stable structural edge id
    (proto+bytecode-anchor+target) for the persistent def + ephemeral `(Trace.id,exit_instr)→edge`
    lookup rebuilt on commit, removed on retirement. Load-bearing — E-3/E-4/E-5 lean on it.
  - **E-2 ‡ `call_seq` can't be a physical `CallFrame`-push counter** — tracing inlines cross-frame
    calls (trace.zig:4014), so native ≠ interp frame pushes → tier-divergent counter. FIX: (a)
    tier-independent logical-call event, or (b) fail-closed decline regions whose root can be
    trace-inlined. **β-specific.**
  - **E-3 classifier key absent at synthetic scalar sites** — onSideExit(seed,0) (trace.zig:2708/2873)
    has no exit_instr; `0` misclassifies. FIX: optional/unclassified key or separate synthetic API.
  - **E-4 overlapping-PC region exit** — leaving region A for sibling B sharing A's PC leaves A's
    accumulator open. FIX: a transition to a region identity outside the active region is a genuine
    exit even when the PC overlaps.
  - **E-5 ‡ keyframe capture/restore** — CallFrame has no field (interp.zig:327), schema doesn't
    carry it (schema/trace.json:163, keyframeser.zig:274/671), format still v4 (:59). FIX: serialize
    `call_seq` + VM counter + active `region_profit`, bump v4→v5 — OR define snapshot as a logical
    region reset done identically in both timelines. **`call_seq` half is β-specific.**
  - **E-6 coroutine thread-scoped depth** — the `depth <= root_frame_depth` exit check must be
    against the originating coroutine's stack (Antigravity MF2).
  - **E-7 error-unwind cleanup** — pcall/xpcall unwinding must drop active region_profit whose root
    frames unwind; `__gc` finalizers must not run guest code at non-deterministic points (MF3).

**THE α/β RE-CALL (Bart's decision, prompted by the review):** When Bart chose (β) the visible cost
was "add a `call_seq` field." The review shows β's TRUE cost = E-2 (tier-independent logical-call
event, because of trace inlining) + the `call_seq` half of E-5 (v4→v5 snapshot schema bump). (α)
fail-closed-exclude-recursion avoids ALL of that and unblocks nsieve (non-recursive) now, deferring
β until a recursive region appears. **Independent floor (required under BOTH α and β):** E-1, E-3,
E-4, E-6, E-7, and the `region_profit` half of E-5 — these are general obligations of region-level
accounting, not of recursion discrimination. So α doesn't make Part A trivial; it just removes the
`call_seq`/schema-bump/inlining-invariance sub-project.

**NEXT: await Bart's α/β re-call, then round-6 design pass** — fold E-1/E-3/E-4/E-6/E-7 (+ E-5
region_profit half) unconditionally; E-2 + E-5 call_seq half per the re-call. Then re-review. NO
code until review-clean.

---

## Status 2026-07-17 (LATEST-5) — ROUND-4 DESIGN WRITTEN + REVIEWED = BLOCKER (both), direction reconfirmed. Five converging round-5 must-fixes (D-1..D-5) + one scope fork (D-3c recursion) for Bart. NO code until round-5 review-clean.

**What happened since LATEST-4:**
- **Round-4 design pass WRITTEN** (doc 17 §Part A — round-4 design, subsections C.1–C.6),
  folding Bart's B-3 decision = **(b) generic stubs, armed later**. Resolved B-1..B-9:
  cap-check-first→`ordinary_mini` (B-1/B-2), trace-local generic stub (B-3), persistent
  VM-level region table (B-4), tier-independent classifier (B-6), live-through set (B-5),
  replay-owned resume PC (B-7), synthesized `completed` (B-8), split lifetimes (B-9).
- **Round-4 REVIEW DONE (codex gpt-5.6-sol + Antigravity) = BLOCKER (both), but the direction
  is reconfirmed sound and most of B-1..B-9 are resolved.** codex (the stricter, code-grounded
  reviewer — trust it on overlaps): B-2/B-5/B-7/B-8/B-9 RESOLVED, B-1/B-3/B-4/B-6 still-blocker.
  Antigravity: B-1..B-8 resolved, B-9 still-blocker.
- **The unifying theme both reviewers circle: split the LOGICAL layer from the PHYSICAL layer.**
  The logical region definition (membership, profit accumulator, classifier) must be a pure
  function of the recorded trace graph, owned at **Proto/VM lifetime**, readable by every tier,
  and **NEVER mutated by trace retirement**; only the physical armed-edge (slot + `NativeLink`)
  metadata is retirement-cleaned. Round 4 conflated the two.
- Five converging round-5 must-fixes (doc 17 §Review outcome — round 4 as D-1..D-5):
  - **D-1 (B-1, codex) cap-check off-by-one.** `jae CAP` still lets `len==CAP-1` commit its own
    entry then dispatch → child terminal append dropped, terminal entry describes parent →
    tripwire (nativegen:779) + scalar ABI (:568) violated. FIX: reserve **two** cells →
    `len >= CAP-1 → ordinary_mini`; prove `len<=CAP-1` on stub entry (every armed dispatch
    leaves ≥1 free cell). Retain `exit_instr` write (:4560).
  - **D-2 (B-3, codex) separate compile-time set E from arm-time set S.** eligibility must ref
    only parent-trace-local emitted set E (not C.4 `live_through`, which is arm-time); child
    `inputs.len==0` is arm-time not `t.inputs.len`; DROP `mov final_trace_id,child.id` (impossible
    for a generic stub AND unnecessary — child's `emitReturn` :3249 stamps its id). Arm iff S ⊆ E
    ∪ invariants.
  - **D-3 (B-4, codex) four accounting-state defects.** (a) window remainder: `window_base += N`
    (loop), not jump to total. (b) `RegionKey` needs identity/edge `region_id` — `{AnchorKey,
    activation}` aliases sibling regions sharing `(proto,14)`; keep AnchorKey only as GATE key.
    (c) `FrameId = depth+PC` is NOT a real frame id (frames carry no gen/id, reused —
    interp.zig:327/1346/2364); don't invent one. (d) membership must be discovered from the
    recorded trace GRAPH in every tier (tier-1a never arms), not "at arm time"; region-exit by
    identity/edge not bare PC-set.
  - **D-4 (B-6, codex) classifier keyed `(trace_id, exit_instr)`**, not `(proto, exit_pc)` —
    siblings record opposite guards at the same source PC (`skip.guard_false` vs `cont.guard_true`).
    All tiers have it (native `LedgerEntry`, tier-1a entered-trace + `ExecResult.exit_instr`).
    Split at EVERY `onSideExit` site (replay :2068, driveChain :1815, dispatcher 2852/3010, scalar
    burst), not one per tier.
  - **D-5 ‡ (B-9, both — the convergent determinism fix) logical map never retirement-cleaned.**
    C.1.4(ii) cleans region-map in removeTrace → `gc_stress on` drops membership PC, off keeps it →
    region-exit check diverges → gate divergence. FIX: logical region map = Proto/VM lifetime,
    cleaned only at proto teardown; only the physical armed-edge registry is retirement-cleaned.
  - **D-6 minor:** B-2 "byte-identical" = VM-state/output not literal mcode; B-5 fixed-point over
    cycles + arm iff S ⊆ E; B-7 the C.5 `.yielded region_bridge` prose is wrong (bridge has no
    post-append yield; next hop owns yield).

**ONE SCOPE FORK for round 5 (D-3c, Bart's call) — recursion handling:** a region whose root frame
can be re-entered recursively has two live activations of one `region_id` on the stack. Options:
(α) **fail-closed exclude** — decline to arm any region whose membership includes a call back to
the region-root proto (recursion detectable from the trace graph), exactly like `inputs.len != 0`
is already excluded; nsieve is non-recursive so this unblocks the target with ZERO
activation-discrimination machinery, reversible later. (β) **build activation discrimination** — a
deterministic per-activation accumulator (needs a real frame-activation identity the VM doesn't
currently carry). Correctness-neutral; pure scope.

**NEXT: round-5 design pass** — fold D-1..D-6 with Bart's D-3c decision. Then re-review (codex +
Antigravity). Per Bart: NO code until review-clean.

---

## Status 2026-07-17 (LATEST-4) — ROUND-3 DESIGN WRITTEN into doc 17 §Part A — round-3 design; all nine round-2 blockers resolved with code-grounded contracts. Re-review (codex gpt-5.6-sol + Antigravity) is the next step; NO code until the review is clean.

**What happened since LATEST-3:**
- **Round-3 design pass WRITTEN** (doc 17 §Part A — round-3 design), grounded by reading
  `nativegen.zig:3597-3625`/`4543-4705`, `trace.zig:1550-1581`/`3098-3395`/`2148-2160`,
  `irinterp.zig:154-217`, and the nsieve cont(29) native-IR dump. All nine specifics have
  concrete contracts (A.1 bridge, A.2 accounting, A.3 ledger grammar, A.4 min_useful).
- **Two reframing findings that sharpen the design:**
  1. **An armed ordinary guard is ALREADY a native in-page handoff** (`nativegen.zig:4569-4573`
     resolves `exit_target` through its own `slot[ei]`; `deopt_exit` ends `jmp qword
     [rdx+exit_target]`, :4631-4633). So edges 1–3 all fuse natively today; **edge 4 is the
     ONLY per-iteration Zig re-entry left** (cont's composite guard is unarmed → shared
     `deopt_exit` → dispatcher). Closing edge 4 removes that single re-entry per outer iter.
  2. **Edge 4's coherence gap is exact and grounded to IR indices.** cont computes `count+1`
     (%004) and `next i` (%011) BEFORE its `%023` composite guard, but the phi writebacks that
     store them to homes (`%031→r2`, `%032→r3`, `%033→r6`) are AFTER %023. So at %023-failure
     the shared `deopt_exit` carried-home flush (`:4602-4603`) commits STALE {count, current i}
     — skip needs {count+1, next i}. Hence the dominance-scoped bridge snapshot (commit only
     phis with `update_index < 23` whose target slot is live at skip.entry). Edge 1 needs no
     such snapshot: skip's `%012 guard_false` fires before skip's back-edge, so pre-update
     homes are already correct for ramp.
- **The bridge is an in-page stub, not a heap object** — structurally identical to the existing
  `linked_loop_done_labels` stubs (`:4583-4596`), emitted at compile time in cont's page, INERT
  until armed, branching on slot-armedness (unarmed → `jmp deopt_exit`, byte-identical). The
  existing registry (`resetLinksTouching`/`disarmAllLinks`, reset by `(parent,slot_index)`)
  covers its lifetime for FREE — no separate free path. This dissolves round-2 BLOCKER-1 item 4.
- **Accounting split keeps the common path identical:** a lone trace = a degenerate one-member
  region flushed per-segment, so `accountRegionProfit(region_key, local)` == today's gating for
  every non-fused trace; only fused regions aggregate. `accountTraceRun` keeps `hit_count`
  per-segment so trace SELECTION is byte-identical.
- Doc 17 updated: §Part A — round-3 design added; 3A checklist bullet + Status header + Last
  updated header all note ROUND-3 WRITTEN / re-review pending. Tasks #9 done, #10/#11 (reviews)
  created.

**ROUND-3 REVIEW DONE (codex gpt-5.6-sol + Antigravity) = BLOCKER (both).** They confirmed the
sound sub-parts (A.1.1–1.3 bridge coherence/dominance/ordinary_entry, A.2.1–2.3 accounting
split/normalized-unit/RegionKey, A.3 additive grammar) and converged on 9 concrete fixes
(recorded in doc 17 §Review outcome — round 3 as B-1..B-9):
- **B-1 ‡ (both) forced-yield is broken.** commit-then-yield stamps final_trace_id=skip.id but
  skip never runs if ledger full → terminal-consistency assert (nativegen:771) + scalar ABI
  (:572) + replay desync. FIX (converged): cap-check FIRST; if full → branch to the *unarmed*
  ordinary deopt_exit (stages static parent PC 29, commits nothing, clean tier-0 resume).
- **B-2 unarmed stub must stage exit_target=shared_exit** before jmp deopt_exit (deopt_exit
  unconditionally jmps [rdx+exit_target], field starts 0). Folds into B-1 (reuse the mini-stub).
- **B-3 (NEW, codex) compile-time classifier temporally impossible.** native lowering gets only
  *Trace, not TraceState/region map; pages memoized permanently (trace.zig:3450); the region
  edge is discovered LATER at arm time. → EMISSION-STRATEGY FORK (Bart's call): (a) precompute
  immutable bridge metadata pre-first-compile from trace-local info; (b) emit GENERIC
  bridge-capable stubs at every eligible composite guard, armed later; (c) invalidate+recompile
  the page when the region is discovered.
- **B-4 ‡ (both) logical-window state machine under-specified + physical leaks.** tier-1a/unlinked
  don't arm → can't get RegionKey "at arm time"; "region exit = PC outside membership" breaks on
  NESTED CALLS (gate on stack-depth ≤ region-root frame) and sibling traces; N/crossing/re-entrancy
  unspecified; **accumulator must be a PERSISTENT VM-level region table (proto/VM lifetime), NOT
  trace state, and must NEVER flush on trace retirement** (GC-physical → gc_stress divergence).
- **B-5 fail-closed needs a defined successor live-through set** (r2 is live-through, not in
  skip.entry); B-6 tier-1a/unlinked ledger classifier undefined; B-7 replay must own resume-PC
  from the region edge (LedgerEntry has none); B-8 accountTraceRun must use synthesized completed
  (max(local,1)) not raw local; B-9 region-map lifetime is explicit metadata, not "free".

**NEXT: round-4 design pass** — (1) rewrite forced-yield to cap-check-first→ordinary-deopt
(B-1/B-2), (2) resolve the B-3 emission-strategy fork (ASK BART), (3) spec the persistent
VM-level region table + stack-depth-gated logical-window + tier-independent membership/classifier
(B-4/B-6), (4) fold B-5/B-7/B-8/B-9. Then re-review. Per Bart: NO code until review-clean.
The B-3 emission fork is a genuine architecture decision (Rule #17) — surface to Bart before round-4.

## Status 2026-07-17 (LATEST-3) — Direction DECIDED (gate B); round-2 review of the B design = DIRECTION APPROVED but DESIGN still BLOCKER. Needs a round-3 design pass before any code.

**What happened since LATEST-2:**
- **Trace-selection investigation DONE → arming/patching confirmed LuaJIT-faithful.** doc 15
  + recorder (`recForPrepLink` LINNER) + `luajit -jdump=t` on the same nsieve (3 self-loop
  roots + 8 side traces patched into roots) all show lune fragments IDENTICALLY to LuaJIT.
  "Fix trace selection / record as one trace" is RULED OUT (both tried-and-rejected it).
- **Gate strategy DECIDED = B (region-level accounting), Bart's call.** Reasoned on merits
  (B measures the right unit / correct regardless of transition cost / retains cold-region
  retirement) over C (exempt-armed). Round-2 review then *corrected the decisive reason* to
  **determinism**: C's "armed" is a physical native-compile state tier-1a/record-only can't
  share → gate-exemption on it diverges across the 10-mode matrix. B still wins; better arg.
- **Doc 17 §Increment 3 rewritten** — added §Part A (RESOLVED) (strategy) + §Review outcome
  — round 2 (the codex+Antigravity re-review of the B design). 3A checklist bullet + Status
  header updated.
- **Round-2 reviews (codex gpt-5.6-sol + Antigravity gemini-3.1-pro) BOTH: direction/gate-B
  APPROVED, design BLOCKER.** They went deep (not rubber-stamps). Nine specifics must be
  nailed in a round-3 pass before code:
  - BRIDGE: (1) dominance-scoped snapshot (only phis dominating cont's composite guard —
    NOT the full `.link` flush, which commits post-guard inner phis that are undefined at
    edge 4); (2) materialize `regs[]` + enter `skip.ordinary_entry` so the child prologue
    re-runs type/shape/identity guards (this is what resolves the invariant-bypass hazard) —
    NOT a physical register shuffle to the loop head; (3) require `skip.inputs.len==0`; (4)
    bridge lifetime/ABI (it's a new object parent-slot→bridge→child, not just an ArmKind).
  - ACCOUNTING: (5) SPLIT `onSideExit` — `accountTraceRun`(coverage/cycle/**hit_count**,
    per-segment) vs `accountRegionProfit`(penalty/gate only); calling it once on skip would
    change hit_count → change WHICH traces select/record (breaks "heuristic-only"); (6)
    NORMALIZED traversal unit (skip composite iters + one per prime cycle; NEVER sum raw
    `rbx`/inner `k` — a big inner sieve loop would look like thousands of outer traversals);
    (7) stable identity `RegionKey` owner `AnchorKey (proto,14)`, not the selected `*Trace`;
    (8) TIER-INDEPENDENT LOGICAL window feeding ONE accumulator (native LEDGER_CAP=32 vs
    tier-1a 8-hop vs unlinked per-segment must NOT define profitability events) + GC-safepoint
    exits excluded (else gates under gc_stress on but not off); (9) additive cross-anchor
    ledger grammar that does NOT weaken the same-anchor `.deopt` provenance(3098)/zero-
    progress(2159) invariants.
  - `min_useful` retune attaches to the BRIDGE not Part B (2.3a indirect slot already removed
    the ~600ns hop; rel32 only removes the slot load). 8 holds IFF the logical window is
    multi-prime; else it gates skip in the dense prefix before the sparse tail → scale→1
    pre-patch. Q4 is subsumed by getting the window right.
  - P-EBP-2 equivalence assertable over the 6 `record+exec-* × gc_stress` modes only.

**NEXT: round-3 design pass** resolving the nine specifics (chiefly: the bridge
dominance-snapshot + ordinary_entry contract, and the region-accounting state machine =
API split + normalized unit + identity RegionKey + tier-independent logical window). THEN
re-review, THEN code. No code until the design is round-clean. Nothing implementation-side
touched this session; tree changes = CURRENT_TASK.md + doc 17 only.

---

## Status 2026-07-17 (LATEST-2) — Increment 3 DESIGN written + BOTH pre-impl reviews in = BLOCKER. AWAITING BART'S DIRECTION CALL before any code.

The doc-17 Increment 3 design and both reviews are recorded in
`docs/design/17-exit-branch-patching.md` → `### Increment 3` (Part A, Part B, and the
two `#### Review outcome` subsections). Summary of where it stands:

- **Design written:** Part 3A = arm the one missing native edge `cont(29).composite-guard
  → skip(14).ordinary_entry` to close `skip→ramp→inner→cont→skip` as one region and
  escape the `onSideExit` gate; Part 3B = faithful `lj_asm_patchexit` rel32 port +
  in-place-patch P-E.
- **Grounding experiment (reverted):** `--jit-stats` shows nsieve:14 = 59% wall / 5%
  traced because GATED; a throwaway `max_penalty=1e9` A/B lifted it to 92.8% traced but
  moved wall time only ~1% → the wall is **per-transition Zig re-entry, not codegen**.
- **codex `gpt-5.6-sol` review = BLOCKER; Antigravity (gemini-3.1-pro) = confirms both
  blockers.** (1) **Edge-4 coherence:** cont's composite guard is coherent at cont's own
  anchor, not skip's header (stale `i`/count) — needs its own materialization/bridge
  contract that commits the outer-back-edge phis, NOT `.ordinary_guard` reuse. (2)
  **Accounting:** `replayLedger` bills per-segment local deltas, so dense short gaps
  (1–3 < `min_useful`) still gate the anchor; the "summed count → never gates"
  mechanism is retracted. Plus the M1 grammar is same-anchor-only (trace.zig:3098) and
  panics on an `rbx`-advancing successor (2159) → new cross-anchor replay grammar
  needed. Part B: "co-location ⇒ rel32 reaches" is FALSE (arena defers cross-region
  reachability), raw rel32 bypasses the forced-yield cap, ordinary guards have no
  per-exit patch point, discovery needs a cross-anchor PC map.

### Trace-selection investigation (Bart asked "investigate trace selection first") — DONE, verdict below

**Verdict: lune's SKIP/CONT/INNER fragmentation is DELIBERATE and byte-for-byte
LuaJIT-faithful. Antigravity's "record as one trace" reframe is a DEAD END that
*diverges* from LuaJIT, not converges.** Three independent sources agree:
- **doc 15 (`15-nested-loop-linking.md`):** the one-trace approach "was implemented and
  **failed**" (unrolls the inner loop, produces forward-referencing malformed IR that
  trips `assertWellFormed`); "The single-loop trace model cannot represent a nested loop
  as one straight-line body. LuaJIT reached the same conclusion and does not unroll."
- **Recorder code (Explore agent, file:line-cited):** `recForPrepLink` (trace.zig:4917)
  LINNER-aborts any `.root` reaching an inner `for_prep` (:4925); nsieve:29 is a
  `.continuation` trace (not an independent root) that links back to inner root 24. This
  is LuaJIT's `rec_loop_jit → LJ_TRERR_LINNER` verbatim.
- **LuaJIT itself (`luajit -jdump=t` on the SAME nsieve, /tmp/ljd.txt):** 11 traces = **3
  self-loop roots** (line 3 init, line 7 inner, line 5 outer-skip) + **8 side traces each
  patched into a root** (`stop -> 1/3/6`). This maps 1:1 onto lune: lune nsieve:24 = LJ
  trace 3 (inner root), nsieve:14 = LJ trace 6 (outer-skip root), nsieve:29→link 24 = LJ
  trace 4 (side 3/3 line 8, `stop -> 3`). **LuaJIT fragments IDENTICALLY.**

The ONLY structural difference LuaJIT→lune: LuaJIT's `stop -> 3` = the side trace's exit
is **patched** (rel32 jump straight into root 3's mcode, zero interpreter re-entry).
lune's `.link` goes through per-transition Zig re-entry (~600ns/hop) — which the A/B
experiment already fingered as the wall-clock cost. **That gap IS exit-branch patching =
Increment 3.** So the investigation *confirms* the arming/patching direction and closes
off the "fix trace selection" alternative.

**PENDING DECISION (Bart) — two levels, see doc §Increment 3 → Review outcome:**
1. **Direction:** stay on the *arming/patching* approach (Increment 3, now confirmed as
   the LuaJIT-faithful path) — the reviews' blockers define the real work, NOT a trace-
   selection rewrite. Antigravity's "record as one trace" reframe is **ruled out** by the
   investigation above (it's the exact thing lune + LuaJIT both tried-and-rejected).
2. **If arming:** which gate strategy — (a) per-segment accounting + measure (partial
   win; entry still gated), (b) region-level accounting (P-EBP-2 redesign), or (c)
   Antigravity's "exempt armed edges from the deopt penalty" (cleanest; still
   P-EBP-2-relevant). Plus the edge-4 bridge-materialization contract is mandatory
   regardless.

No code has been written for Increment 3. The only tree change this session is this
file + doc 17. The `max_penalty` A/B experiment was reverted; baseline restored.

---

## Status 2026-07-17 (prior) — Increment 2 (all of 2c-*) + coverage-viz arc DONE; NEXT = doc 17 **Increment 3** (exit-branch patching + P-E lifetime)

**Reality reconciliation (the block below dated 2026-07-14 is SUPERSEDED — it reads as
if 2c-E/E2 were mid-flight; they landed and are committed).** What actually happened
since:

- **2c-E LANDED + committed** — `42ae4ba` "feat(jit): close native continuation↔inner
  cycle (2c-E) + add compile-gated jitdbg". E1/E2/E3 all landed (the E2 spec in the
  superseded block was implemented; `armLoopDoneLink` + the `native_loopdone_link_*`
  counters are live in `src/trace.zig`).
- **2c-F LANDED + committed** — `eb21d7e` (disarm integration tests + `native_link_disarms`)
  and `0352beb` (harden + epoch-contain the fused native C↔I cycle; `beginTopLevelEpoch`
  → `disarmAllLinks` at every fresh top-level run). See TODO.md "RESOLVED (2c-F)" for the
  cold-re-entry root cause + fix.
- **This completes doc 17 Increment 2** (shared trampoline + frameless bodies + the native
  C↔I cycle, P-A/B/C/F/G). Increment 1 (shared arena, P-D) was already `a970da4`. The
  native transition today still hands off **through `driveChain` — the ~600 ns Zig
  re-entry**; removing that is Increment 3.
- **Coverage instrumentation + visualizer arc LANDED + committed** (`513f5b4` accounting +
  `--jit-coverage/--jit-stats` → TSC time split → `e6250ff` serialization + `--emit-coverage`
  → `bf94928` WASM surface → `713d099` viz Phase 3 line-shading + stats → real-time units →
  `8cf0cde` run the wasm VM in a Web Worker = current HEAD). Built precisely because we kept
  optimizing the *already-traced* 5% of nsieve; the instrument now shows the honest
  wall-clock split.

**Coverage measurement of nsieve 9 (`--jit-stats --jit-native`, ReleaseFast, 2026-07-17)
— this picks the next target:**
- By iteration count: 69.4% traced (flatters the JIT). **By TSC time: only 6.3% of the run
  ran as native trace; 92.5% is "tier-0, has-trace" — a native trace EXISTS but the
  dispatcher fell back to the interpreter.**
- Per-anchor (`proto:pc`, not source line): **`nsieve:14` (outer scan `for i=2,m do if p[i]
  then <inner> end end`) = 58.1% of wall clock, 5.0% traced.** `nsieve:24` (inner sieve) =
  13.6%, 96% traced (healthy). `nsieve:4` (init) = 27.1%, 57% traced.
- Diagnosis (measured, not inferred): **zero recording aborts; all 5 traces native-compiled
  (928–1434 B x86-64).** The full linked structure exists — root trace (`p[i]==false` common
  path) + side trace (`p[i]==true`) + `nsieve:29 … link -> 24` into the inner loop — and the
  native chaining fires (`prime-side chain-follows=40289`, `native link exits=40291`). So the
  loss is **purely re-entry**: the outer loop can't stay native across its `if p[i]` branch +
  nested-loop return; it drops to tier-0 and re-warms every ~11 iterations. Exactly what doc
  16's correction predicted.

**NEXT — doc 17 Increment 3 (line 1269): Exit-branch patching + lifetime (P-E).** The two
structural blockers that once made this a new-ABI problem (per-trace C frames P-A;
non-co-located pages P-D) were removed by Increments 1+2, so it's now the tractable
`lj_asm_patchexit` port it couldn't have been before. Three pieces:
1. **The patch** — port `lj_asm_patchexit` (`~/Projects/LuaJIT/src/lj_asm_x86.h:3127`):
   rewrite a guard's `jcc`/tail-`jmp` rel32 in place → jump straight into the child body,
   replacing the `driveChain` re-entry. Patch site already exists (per-`exit_instr`
   `jmp deopt_exit` stub, `nativegen.zig:3845`); needs `exit_instr → mcode-offset` map
   persisted on `CompiledTrace` + a `mprotect(RW)→write→mprotect(RX)` bracket on `ExecPage`.
2. **Lifetime (P-E)** — unpatch-on-retire: `removeTrace` restores parents' exits to
   `deopt_exit` via a back-reference (mirror LuaJIT's RW window + GC-exit skip at
   `lj_asm_x86.h:3153`).
3. **Determinism gates (P-EBP-1..4)** — the patched jump SKIPS the dispatcher's
   future-steering accounting (`onSideExit`, arming, gating, lane-widen eviction), so
   byte-identity is NOT free: replicate that accounting on the patched path OR prove each
   skipped counter inert post-link, then the 10-mode matrix + replay goldens + the
   safe-point argument.

**Plan of attack (Bart, 2026-07-17):** (1) fix this file [DONE]; (2) read Pall's
`lj_asm_patchexit` + `lj_mcode_patch`, write the Increment 3 design into doc 17; (3) codex
gpt-5.6-sol pre-implementation review; (4) Antigravity (gemini-3.1-pro) second review; then
implement.

---

## Status 2026-07-14 (SUPERSEDED — see the 2026-07-17 block above; 2c-E/E2/E3 + 2c-F all landed) — 2c-E (#63): E1 LANDED (d4d82d9); E2 spec finalized (codex-approved), implementation next

**Where we are.** 2c-E splits into E1/E2/E3 per two codex `gpt-5.6-sol` rulings (thread
`019f5f48-98ba-73b3-90c8-89ded74aae92`; the rulings are in the session transcript
`~/.claude/projects/-home-bart-Projects-lune/9a281686-...jsonl` lines 21264 + 21272, already
fully distilled below — do NOT re-read the transcript).

- **E1 — DONE, commit `d4d82d9`** ("feat(jit): 2c-E1 — model deep fused receipts,
  prologue-fail grammars, and call-B handover (nothing armed)"). All control-flow wiring for
  the armed `C↔I` cycle, with NOTHING armed: call-A drain in `driveBurstCore`
  (`ledger_len>1` → `replayLedger(.inner_call)`), `BurstCursor.start_at_continuation` +
  `call_a:` labeled block (a `run_continuation` handover enters call B without re-running the
  inner), `driveSeedLedger` (hop-0 >2-entry drain, private), `driveDispatcherLedger` maps
  `run_continuation` → cursor, replayLedger M1 sub-case (c) (fused `[skip.deopt,
  ramp.prologue_fail]`) + terminal-loop-done continuation release-validation, dispatcher gate
  widened to `if (ran_native and result.ledger_len > 1)` (interp.zig ~2738). Plus 4 blocking
  unit tests (M1 sub-case c; dispatcher `[I.loop_done_linked, C.prologue_fail]`; deep hop-0
  seed ledger single-charge; real-native `start_at_continuation` no-double-run).
- **E2 — NEXT (spec below, codex-approved).** The intentional behavior changes: persistent
  I→C arming (3 sites), terminal-replay arming convergence, non-last link-follow accounting,
  native one-trip linked-loop-done correction, + 5 blocking tests.
- **E3 — after E2:** byte-identity sweep (6 benchmarks × tier-0/tier-1a/native, stdout +
  keyframe/replay goldens), doc 17 + this file updated, then codex full-diff review.

### E2 implementation progress (2026-07-14, this session)

**Code items 1–6 are ALL IMPLEMENTED and green** (`just test` exit 0, 756 tests; nsieve 9
byte-identical tier-0 == tier-1a == native with the cycle LIVE). What landed:
- Counters `native_loopdone_link_arms` / `native_loopdone_link_fused` (trace.zig ~977–988).
- `armLoopDoneLink` helper right after `armNativeLink` (trace.zig ~2990): all gates as spec'd.
- `safe_to_arm` threaded into `replayLedger` (last param) + all 4 call sites.
- Site 1 (scalar call-A, after the `arm_term` block), site 2 (driveChain: both the `>2`
  driveSeedLedger branch AND the is_link classify branch, gated
  `materialization == .native_numeric_for_done`), site 3 (replayLedger terminal
  `.loop_done_linked`, before the hop-budget check).
- Follow bumps in non-last `.link_terminal` (trace.zig ~1753) + fused counter in non-last
  `.loop_done_linked` (~1823).
- One-trip fix in interp.zig: `linked_one_trip` computed after `local_done` (~2713); guard-fail
  gate `and !linked_one_trip`; productive gate `or linked_one_trip` with
  `onSideExit(final, if (linked_one_trip) 1 else local_done)`.
- **E1 test D expectation updated** (was the one red test): the new non-last `.link_terminal`
  follow bump makes `native_link_follow_count == 2` (fused C→I edge + physical post-C hop),
  and `native_loopdone_link_fused == 1` (entry 0→1 edge) — both now asserted.

**⚠️ TREE STATE (2026-07-14, second pass): RESTORED — nothing left to restore.**
1. ~~One-trip fix temporarily disabled~~ — DONE: the `false and` is removed; the
   fix is LIVE and the full suite is green (`just test`, 759 tests).
2. ~~Temporary debug scaffolding to DELETE~~ — DONE (2026-07-14): every ad-hoc DBG
   print was removed and replaced by the permanent **jitdbg facility** (Bart's ask):
   `src/jitdbg.zig` (new) + `-Djit-debug=true` build option + `--jit-debug` CLI flag
   + `vm.trace.config.debug_log` runtime gate + `TraceState.dbg()` /
   `dbgDumpGuardFailures()` / `dbgDumpCache()` + permanent call sites (dispatcher
   receipt in interp.zig, arm/re-arm in armNativeLink, disarmAllLinks,
   retire-reset in resetLinksTouching). Compiled out entirely by default; both
   `just test` and `zig build test -Djit-debug=true` green; smoke run shows
   receipts + the 2c-E loop-done arm event live. Documented in project CLAUDE.md
   (Build section). Touches build.zig, src/jitdbg.zig, root.zig, trace.zig,
   interp.zig, main.zig — NOT yet committed (rides with the E2 commit; interp.zig
   holds both changes and can't be split, Rule #13).
3. Everything else in the tree is final E2 code (items 1–6 of the spec, all landed).
4. Side discovery: `zig build wasm` is broken at HEAD (pre-existing 64-bit
   assumptions in `hotIndex` + `rowViewParent`, nothing gates it) — TODO.md has
   the details; my build_options wiring for wasm is fine.

**Test status:**
- Test (ii) "2c-E (doc 17): loop-done inner→continuation arm fires…" — WRITTEN + GREEN
  (arms>0 ∧ fused>0 fire on a plain 400×30 nested loop via `runNativeForTrace`).
- Test (i) "2c-E (doc 17): native one-trip linked loop-done…" — **GREEN + PROVEN
  LOAD-BEARING (2026-07-14, second pass)**, with a MAJOR upgrade to what it proves:
  after setting `native_vm.trace.config.min_trip_entry = 0;` before
  `runNativeForTrace` (the reachability fix — default 24 + EXACT `forRemainingTrips`
  makes one-trip dispatcher receipts unreachable otherwise), disabling the fix
  (`false and`) makes the test fail on **BYTE-IDENTITY, not the guard-count
  assertion**: native prints 2253 vs tier-0's 2252. So the scalar zero path on a
  one-trip linked receipt is an actual **MISRESUME / correctness bug** — the linked
  snapshot already committed the final iteration into regs, and the zero path
  re-runs it (double-commit, +1). `linked_one_trip` is a *correctness* fix, not
  just accounting; at default config only the `min_trip_entry` heuristic keeps the
  broken path unreachable. Test comment updated to say exactly this. The `%`-in-
  outer-body trick works as designed (continuation records `.link`, inputs=0, but
  nativegen-bails → armLoopDoneLink fails closed → slot unarmed → receipts stay
  scalar). Secondary assertion: every guard_failures value < 4.
- Tests (iii)/(iv)/(v) — **ALL WRITTEN + GREEN (2026-07-14)**. Key realization that
  made them cheap: they DON'T need real nativegen compilation. `replayLedger` only
  READS trace shape and accounts/arms — it never executes native code — so:
  - **(iii) convergence arm** "replayLedger convergence (2c-E site 3): a TERMINAL
    loop_done_linked arms the I→C slot" (trace.zig, before "driveChain
    ordinary_header"). Calls `replayLedger` DIRECTLY (isolates the arm from the
    risky native execution tail of driveDispatcherLedger). Uses hand-built
    `.compiled` stubs (`page = undefined`, heap `slots`, cont's `ordinary_entry` =
    sentinel `0xC0FFEE_1234`) — same trick as the P-E registry test — so NO
    x86_64 gate. Ledger `[I.done(fused), C.link, I.done(terminal)]`, safe_to_arm=
    true → asserts `native_loopdone_link_arms == 1`, `inner_slots[0] ==
    ordinary_entry sentinel`, the armed_links record {parent=inner, slot=0,
    child=cont}, `native_loopdone_link_fused == 1` (the interior k=0 fused),
    directive == `.run_continuation(cont)`. Frees slots manually + clears cache/
    armed_links before deinit (undefined page must never be destroyed).
  - **(iv) forced yield at LEDGER_CAP** "replayLedger forced yield (2c-B/2c-E): a
    CAP-length ledger ending .yielded replays cleanly" (trace.zig, before (iii)).
    Plain non-compiled traces (terminal is a `.link`, never arms → no compile
    needed). Runtime-filled 32-entry alternating `[I.loop_done_linked, C.link]`
    ledger, last `.link` stamped `.yielded`. Asserts replayLedger ACCEPTS it (no
    panic on the last-of-full guard), `linked_completed == 16`, directive
    `.run_inner_from(cont)`, `resume_pc == 5`, `native_link_exits == 16`.
  - **(v) disarm-on-unsafe** "disarmAllLinks (2c-E / 2.3c-0e): resets EVERY armed
    slot on entering the observation blackout" (trace.zig, before the P-C-invariant
    test). Hand-built compiled stubs, arm a full C↔I cycle (2 links via
    armNativeLink), one `disarmAllLinks` → BOTH slots back to shared_exit(0) +
    registry empty; asserts idempotence (second call no-op).
- **Pre-existing bug found (recorded in TODO.md, NOT mine — reproduced at HEAD
  d4d82d9):** `--trace` (tier-1a) panics "invalid enum value" in regwindow.get via
  `driveChain .ir` entering the `%`-continuation on the probe program (see TODO.md
  for repro). tier-0 + native fine.

**After tests: E3** — byte-identity sweep (nsieve DONE this session: 3 modes
byte-identical, md5 0c22770a…336; still owed: nsieve-bit/fannkuch/mandelbrot/nbody/
spectral-norm + keyframe/replay goldens), `just bench --filter nsieve`, doc 17
Done/Outstanding update, commit E2 (conventional, co-author trailer, bundle
src/trace.zig + src/interp.zig + doc 17 + CURRENT_TASK.md + TODO.md; do NOT stage
CURRENT_TASK_E3.md / bench/results/*.tsv), then codex gpt-5.6-sol diff review
(thread 019f5f48-98ba-73b3-89ded74aae92 — NB correct id is
019f5f48-98ba-73b3-90c8-89ded74aae92).

**Discoveries needed for writing the remaining tests:**
- `hasNativeLoopDoneLink` (trace.zig:2597) = "a zero-input `.link` continuation EXISTS at
  some loop-done exit PC of this trace" — NOT "slot armed". So linked-mode dispatcher entry
  happens pre-arm whenever the continuation trace exists.
- **One-trip reachability (test i) — CORRECTED (the first version of this bullet was
  wrong):** a 1-iteration inner NEVER enters via the dispatcher (entry is on back-edges; a
  1-trip loop takes none). A **2-trip inner** enters at the first back-edge (j=2) and hits
  loop-done LINKED with `local_completed == 0` (final linked snapshot commits WITHOUT the
  back-edge rbx increment, nativegen:4567) — **BUT only if `min_trip_entry` allows it**:
  the default (24) makes the dispatcher decline any numeric-for entry with < 24 exact
  remaining trips (interp.zig:2455–2461 + forRemainingTrips:3661), so the scalar one-trip
  path is unreachable at default config and the test must set
  `vm.trace.config.min_trip_entry = 0` before the harness call. Program shape: warm with a
  wide inner (`m=30`), flip to `m=2`, keep `s = s % 100000007` in the outer body so the
  continuation is nativegen-unsupported (→ slot never arms → receipts stay scalar).
- **Penalty nuance:** productivity 1 still bumps `penalty` (`onSideExit` clears only at
  `completed >= min_useful=8`) — the one-trip fix does NOT change penalty accumulation
  (replayLedger's `max(local,1)` has the same property; E1 tests pin penalty==1 per
  one-trip). Load-bearing observables for the fix are instead: countGuardFailure SKIPPED,
  the `.native_numeric_for_done` driveChain FIRING (→ `native_link_exits`), and resume
  steering. Verify a test is load-bearing by temporarily reverting the fix and watching it
  fail.
- Counter-asserting end-to-end pattern: see interp.zig ~9860–10021 (`runNativeForTrace`
  harness at 10103 with lowered hotloop=4; the doc-16 nsieve test at 9931 uses the inline
  default-threshold harness instead — copy THAT for chain-shape-sensitive programs).

### E2 spec (recovered + codex-ruled; implement exactly this)

1. **Two new `TraceState` counters** next to `native_source_link_fused` (trace.zig ~976):
   `native_loopdone_link_arms: u64 = 0` (bumped by the helper on a successful arm) and
   `native_loopdone_link_fused: u64 = 0` (bumped in replayLedger's NON-last
   `.loop_done_linked` branch — proves the armed edge actually fired).
2. **Shared fail-closed helper** `armLoopDoneLink(self, inner: *Trace, guard_idx: u32,
   cont: *Trace, safe_to_arm: bool) void`. Gates, each `return` (never panic — arming is
   opportunistic): `safe_to_arm`; `guard_idx != maxInt(u32)` + `< inner.instrs.len`;
   `isLoopDoneGuardIndex(inner, guard_idx)` (explicit — armNativeLink's kind/shape invariant
   is a *debug* assert + release fail-close, don't rely on it); `post_pc =
   guardExitPc(inner.instrs[guard_idx]) orelse return`; `cont.inputs.len == 0`; cont ends
   `.link`; `cont.anchor.proto == inner.anchor.proto and cont.anchor.pc == post_pc`; then
   `nativeFor(cont)` → `.ordinary_entry` **optional, never `.?`** (missing entry leaves slot
   unarmed) → `armNativeLink(inner, guard_idx, cont, oe, .loop_done_linked) catch false` →
   on true bump `native_loopdone_link_arms`. armNativeLink already fail-closes on
   non-compiled `inner` / OOB slot, supersedes same-slot in place, and appends to the P-E
   registry BEFORE the slot write.
3. **Thread `safe_to_arm: bool` into `replayLedger`** (new param). Call sites to update (all
   already have `safe_to_arm` in scope): call-A drain in driveBurstCore, call-B loop in
   driveBurstCore, `driveDispatcherLedger`, `driveSeedLedger`.
4. **Arm at 3 sites** (target = `ordinary_entry` NOT `linked_entry`: the continuation is a
   `.link` trace with no numeric-for loop-done of its own; nativegen.zig:4675 —
   `ordinary_entry` clears inherited linked mode):
   - **Site 1, scalar call-A loop-done** (driveBurstCore): right after the existing 2.3b-1
     `C.link→I.linked_entry` arm block (`arm_term`), post driver-swap + roll-up:
     `armLoopDoneLink(inner, iresult.exit_instr, current_link, safe_to_arm)` gated
     `tier == .native_only` (`current_link` is post-swap = the continuation at the inner's
     exit PC; `iresult.exit_instr` already validated loop-done by the scalar classify).
   - **Site 2, driveChain hop-0** under `materialization == .native_numeric_for_done`
     (inner=`failed`, guard=`exit_instr`, cont=`sct`): mirror the M1
     `native_source_link_arms` arm placement — BOTH the is_link classify branch AND the
     `ledger_len > 2` branch (arm before routing to driveSeedLedger). In
     `.native_numeric_for_done`, `failed` = the inner I, `walk_pc` = post-loop pc from
     guardExitPc, `sct` = continuation C.
   - **Site 3, replayLedger terminal `.loop_done_linked` is_last branch** (inner=owner,
     guard=`e.exit`, cont=`cont`): this is the *convergence* arm — a terminal unarmed
     `I.loop_done_linked` arms the edge for its next occurrence. Decision made: is_last
     branch only (non-last means the edge already fused → already armed). Arming on a
     forced-yield terminal is harmless (in-place supersede). Place it so it runs even when
     the hop budget then breaks the burst (scalar parity: scalar site arms on the last hop
     too).
5. **Follow-count bumps** in replayLedger's NON-last `.link_terminal` branch (after
   validation, next to `cont = owner`): `native_link_follow_count +|= 1` AND
   `link_follow_count +|= 1` — mirrors the physical call-A top so the
   `start_at_continuation` skip is accounting-exact. And `native_loopdone_link_fused +|= 1`
   in the NON-last `.loop_done_linked` branch.
6. **Native one-trip linked-loop-done fix (interp.zig, native-only).** A linked-mode native
   receipt commits its final linked snapshot (nativegen.zig:4567) even at
   `local_completed == 0` (a one-iteration inner: loop-done fires before any back-edge rbx
   increment) — regs ARE coherent at the post-loop pc, but the scalar dispatcher takes the
   `local_done == 0` path (countGuardFailure + `onSideExit(final, 0)` zero path) while
   replayLedger uses `max(local,1)`. Fix: compute
   `linked_one_trip = ran_native and ran_native_link_mode and result.exit_reason == .normal
   and exit_instr-in-bounds and trace.isLoopDoneGuardIndex(final, result.exit_instr) and
   local_done == 0` (bounds check BEFORE isLoopDoneGuardIndex; exit==maxInt excluded by it);
   then (a) skip the guard-failure counting block (`if (local_done == 0 and
   !linked_one_trip)`), (b) enter the productive block (`if (local_done > 0 or
   linked_one_trip)`) with `onSideExit(final, if (linked_one_trip) 1 else local_done)`,
   (c) pass the ORIGINAL `result` to driveChain (real exit identity, no fabricated count).
   `maybeArmContinuation`/`countProductiveBranchExit` stay — inert (former sees the cached
   continuation, latter rejects loop-done guards). **Tier-1a unchanged** (it hasn't committed
   the final iteration; assigning count 1 there would be wrong — would need
   flushNumericForLoopDone).
7. **Five E2-blocking tests:** (i) native one-trip linked loop-done (local_completed==0 →
   productivity 1, no guard-failure count); (ii) actual I→C arm + `native_loopdone_link_fused`
   assertion (armed edge fires); (iii) replay-terminal arming convergence (terminal unarmed
   sibling I becomes armed for its next occurrence); (iv) forced yield at LEDGER_CAP via a
   CONSTRUCTED native cycle — non-deferrable, it's the only bound on the newly-live cycle;
   don't rely on nsieve; (v) minimal deterministic disarm-on-unsafe proving BOTH halves of an
   armed C↔I cycle reset (`resetLinksTouching` covers both directions).

Then: `just test` green + nsieve byte-identity across the 3 modes → commit E2 → E3.

### Verified code map (line numbers as of d4d82d9 — saves re-reading trace.zig)

- **`LedgerEntry`** (irinterp.zig:200): `{cum: usize, id: u32, exit: u32 (maxInt =
  prologue-fail), reason: ExitReason (.normal/.prologue_fail), kind: LedgerKind = .deopt,
  outcome: LedgerOutcome = .normal}`; `LedgerKind = {link_terminal=0, loop_done_linked=1,
  deopt=2, prologue_fail=3}`; `LEDGER_CAP=32`; forced yield (`.yielded`) only as LAST entry
  of a FULL (==CAP) ledger; per-segment local = `cum[i]−cum[i-1]`, `cum[-1]==0`.
  `ExecResult.exit_reason: ExitReason = .normal` (irinterp.zig:133).
- **`replayLedger`** (trace.zig:1626, signature at 1626–1637): the single authoritative
  graph-walk drain. Branch geography: `.link_terminal` non-last validation+`cont=owner` at
  1710–1722 (**follow-bump goes here**), is_last `run_inner_from` 1700–1708;
  `.loop_done_linked` 1724–1777 — `onSideExit(owner, max(local,1))` 1741, `first_inner`
  no-hop rule 1749, is_last budget check 1755 + terminal cont release-validation 1761 +
  `run_continuation` 1765 (**site-3 arm + fused-counter go around here**), non-last succ
  validation 1770–1776; `.deopt` M1 non-last 1795–1884 (sub-case b 1835, c 1856, a
  fall-through 1880–1884), terminal (a)/(b) 1900–1926; `.prologue_fail` 1928–1956.
- **`driveChain`** (trace.zig:1314): native path sets `flushed_resume_pc = walk_pc` before
  every candidate (~1407) → a prologue-fail short-circuits at the "Not a completed link run"
  tail with `onSideExit(sct,0)`, never retries (retry tail is tier-1a-only). Hop-0 capture
  ~1412; `ledger_len > 2` branch ~1423 arms M1 then routes to `driveSeedLedger`; `==2` stays
  on the scalar `fused_inner` seam. **M1 arm pattern to mirror for site 2** (~1424–1434 and
  ~1483–1493): gates safe_to_arm + `.ordinary_header` + inputs empty +
  isSourceBranchGuardExit, `nativeFor(sct).ordinary_entry` optional,
  `armNativeLink(failed, exit_instr, sct, oe, .ordinary_guard)`,
  `native_source_link_arms+1`.
- **`driveBurstCore`**: hop loop `hop: while (hops < max_hops=8)`; `call_a: {}` labeled block
  consumes `start_at_continuation` once via `break :call_a`; scalar call-A loop-done
  classify → tier-1a flush → driver swap via findLinkTrace → roll-up
  `onSideExit(inner, max(local,1))` + `linked_completed++` → **2.3b-1 arm block
  (`arm_term`) — site 1 goes right after it**. Call B: `snt.runCapturingLedger` + while-loop
  over `replayLedger(.continuation_call)` directives. Tail: `linked_completed>0`
  penalty-neutral, else `onSideExit(seed,0)`.
- **`driveSeedLedger`** (trace.zig:~2464, private): hop-0 >2 drain; release checks (len≥3,
  seed ends `.link`, e0=={seed.id,.link_terminal,exit==len-1}); NO wrapper
  `native_link_exits` precharge; origin `.continuation_call`.
- **`driveDispatcherLedger`** (trace.zig:~2380, pub): origin `.dispatcher_root`; `inner_pc =
  seed.anchor.pc` placeholder; `run_continuation` → cursor `start_at_continuation=true`.
- **`armNativeLink(parent, slot_index, child, target, kind) !bool`** (trace.zig:~2882):
  fail-closed non-compiled parent/OOB slot; kind-vs-slot-shape invariant (loop-done slots
  exclusively `.loop_done_linked`) is debug assert + release fail-close; in-place same-slot
  supersede; registry-append-before-slot-write. `resetLinksTouching` (~2937) both directions.
- **Helpers:** `guardExitPc` (450 — only guard_int/float/number/true/false/int_of_float
  carry a PC in aux); `isLoopDoneGuardIndex` (463 — guard_true + `code[exit_pc-1]==.for_loop`,
  safe on OOB idx); `isInnerLoopRoot` (1151 — anchor match + inputs empty + ends `.loop`);
  `isSourceBranchGuardExit` (2714); `fusedSourceBranchLinkSlot` (2750); `traceById` (1234);
  `nativeFor` (3032 — lazy compileInto, memoizes `.compiled`/`.unsupported`);
  `onSideExit` (1256 — completed ≥ min_useful(8) → hit; else penalty++ → gate at 8).
  `ArmKind` (478) = {link_terminal, ordinary_guard, loop_done_linked}.
- **interp.zig dispatcher exit consumer (E2-6 target), ~2692–3001:** `local_done = if
  (ran_native) result.local_completed else result.completed` (2692); ledger-drain gate
  2738–2743; guard-failure block `if (local_done == 0)` 2752–2760 (**skip when
  linked_one_trip**); productive block `if (local_done > 0)` 2762 with
  `onSideExit(final, local_done)`, maybeArmContinuation 2773, countProductiveBranchExit
  2783, `.native_numeric_for_done` driveChain call 2843–2848 (gated `ran_native and
  ran_native_link_mode`); zero path `onSideExit(final, 0)` 2922. `ran_native_link_mode` set
  from hasNativeLoopDoneLink at entry (~2593).
- **nativegen facts:** compile bails (returns null) for terminal not `.loop`/`.link` (879);
  slot_load without covering guard_int bails; add on unproven operands bails (→ easy way to
  make a trace deliberately uncompilable in tests); `ordinary_entry` clears inherited linked
  mode (4675); linked snapshot commits at 4567 even at local_completed==0; forced yield
  validated at 3331; `CompiledTrace.runCapturingLedger` (719) /
  `runLinkedLoopDoneCapturing` (732); `NativeState.deinit()` frees page/slots.
- **Test patterns that work** (see the four E1 tests, inserted after "armNativeLink: P-C
  option (b) invariant"): stack `var t: Trace` + `state.cache.append(gpa, &t)` + `defer
  state.cache.clearRetainingCapacity()` registered AFTER `defer state.deinit()` (LIFO →
  clear first); compiled stubs `.native = .{ .compiled = .{ .page = undefined, .slots =
  heap_slots, .gpa = gpa } }` with defer-freed slots; real native compile via
  `nativeFor` + `defer t.native.deinit()`, gate on x86_64-linux via local `const builtin =
  @import("builtin");` + `error.SkipZigTest`; protos via `Proto{ .code = &.{
  Instr.op0(.ret), Instr.op0(.for_loop) }, .name = "t", .num_registers = N }`;
  `TestRegs{.regs = &regs}` + `.view()` + `.commit()`. Reference trace.zig NOT as
  `NativeState.x` — use `t.native == .unsupported` style tag checks.
- **Codex lifecycle confirmations (no work needed):** capture→replay has no intervening
  mutation (single-threaded); same-slot rearm supersedes in place; removeTrace resets links
  before mcode reuse; widen-eviction retires a fused child at its own anchor.

### Deferred to 2c-F (#65)
Full sibling cross-link topology; full two-phase same-VM disarm negative control;
widen-eviction integration both directions; broader prologue-fail coverage; extra
forced-yield stress; full codex diff review of the 2.3c-2 arc; flag the 2-valued
LedgerOutcome deviation and the terminal-continuation @panic-vs-swap choice.

---

## Status 2026-07-14 (prev) — 2.3c-2d COMPLETE (#62): D1 + D2a + D2b-i + D2b-ii all LANDED (green, byte-identical); 2c-E NEXT (arm I→C)

Task #62 (2c-D, "capture everywhere") is DONE. All four native-entry sites now capture the
per-transition ledger and drain it through the single authoritative `replayLedger`; the bespoke
scalar M1 recognizer is gone. Next: **2c-E (#63)** — persistently arm `I.loopdone →
C.ordinary_entry` (the `.loop_done_linked` / `isLoopDoneGuardIndex` gate), closing the native
`C↔I` cycle so `ledger_len>1` fused spans appear at call A and the dispatcher's `run_continuation`
path (both already wired, dormant). Also wire call-A's dormant `ledger_len>1` drain (currently
panics at nativegen call site) and exercise `driveBurstCore`'s `.run_continuation` re-run.

**D2b landed since D2a:**
- **2c-D D2b-i** (commit 1e8141d, pure refactor, byte-identical): extracted `BurstCursor
  { current_link, linked_completed, resume_pc, hops }` + a shared `driveBurstCore` hop-loop core
  from `runLinkedBurst`. The wrapper keeps the one-time entry counters
  (`native_link_exits`/`link_ir_exits`, `prime_side_chain_follows`), builds a zero-progress cursor,
  and hands off. The core owns NO entry counters, so a caller with an already-accounted cursor can
  enter the same ping-pong. Tail `onSideExit` now takes the explicit `seed`.
- **2c-D D2b-ii** (commit 7875dac, the LIVE change): folded the M1 fused-guard drain into
  `replayLedger`'s `.deopt` non-last arm (armed-edge provenance validation + `native_source_link_fused`
  + `onSideExit(skip, skip_local)`; sub-case (a) `.link_terminal` fall-through → `run_inner_from`,
  sub-case (b) inline `onSideExit(ramp,0)` + `return_result{resume_pc: skip.anchor.pc}`). New public
  `trace.driveDispatcherLedger` drains a dispatcher-entry ledger via `replayLedger(.dispatcher_root)`
  and maps the directive onto `driveBurstCore`, charging `prime_side_chain_follows` on the
  `run_inner_from` path (the one counter replayLedger does not own). The old ~60-line scalar M1 block
  in interp.zig is replaced by a thin gate `if (ran_native and ledger_len>1 and exit_reason==.normal)`.
  Routing by reason keeps a prologue-fail-terminal fused span on the old scalar path (byte-identical
  to the old `exit_instr < instrs.len` gate). `native_source_link_fused` is now bumped ONLY inside
  `replayLedger`, so the nsieve native test's `> 0` assertion proves the new path fires.

**Verify (D2b):** `just test` green; nsieve/fannkuch/nbody/spectral-norm stdout byte-identical
across tier-0 / tier-1a / native.

**Codex `gpt-5.6-sol` checkpoint review of D2b — DONE (thread 019f5edc), all blockers resolved:**
- Blocker 1 (a `[C.link, I.x]` dispatcher receipt would misroute through the widened `ledger_len>1`
  gate) — **false positive**, confirmed by codex: the dispatcher walk skips `.link` traces
  (interp.zig:2526) BEFORE fingerprint/native entry, so a continuation is never a dispatcher seed,
  and a non-`.link` seed can't emit a `.link_terminal` first ledger entry. Pre-2c-E `entries[0]` of
  a `ledger_len>1` dispatcher receipt is therefore ALWAYS the M1 source-branch `.deopt` → the new
  gate is equivalent to the old `fusedSourceBranchLinkSlot` recognizer for every case it fired on.
- Blocker 2 + 3 — **hardened** (commit 2f0f457, byte-identical): M1 sub-case (b) resumes at
  `owner.anchor.pc` (not `seed_owner`) and requires the ramp deopt to be the LAST entry;
  `prime_side_chain_follows` moved into replayLedger's M1 `.deopt` sub-case (a) fall-through (tied to
  source-guard provenance) instead of driveDispatcherLedger's generic `run_inner_from` mapping.

**Codex ruling: D2b is sound; safe to build 2c-E on it.** One ACTIVATION CONSTRAINT for 2c-E (already
in #63 scope, do NOT skip): arming `I→C` makes call A (nativegen.zig `runLinkedLoopDoneCapturing`,
trace.zig ~2031) immediately return `[I.loop_done_linked, C.…]` and hit the existing
`if (iresult.ledger_len > 1) @panic(...)`. So 2c-E is NOT arm-only — it must FIRST/ALSO route call-A
multi-entry receipts through `replayLedger(..., .inner_call)` and map the directive WITHOUT re-running
the already-executed inner body, then flip the `I.loopdone → C.ordinary_entry` arm. The dispatcher's
`run_continuation` mapping is already wired (dormant); call A is the remaining dormant path.

D2b commits: 1e8141d (D2b-i refactor), 7875dac (D2b-ii live fold), 2f0f457 (codex hardening).

### Prior 2c-D detail (D1 + D2a)

Landed since 2c-C:

- **2c-B forced-yield cap** (#64, committed): chain-source exit sites reload `ledger_len` after
  the append and `jmp shared_exit` (stamping the terminal `.yielded`) at CAP, bounding a closed
  cycle to ≤CAP entries per trampoline entry. Byte-identical/inert pre-cycle.
- **2c-C generic replayLedger** (#61, commit 0aac370): four per-kind validated arms
  (`.link_terminal` / `.loop_done_linked` / `.deopt` / `.prologue_fail`), each release-`@panic`s
  on a contract mismatch. Call B (`runLinkedBurst` continuation drain) rerouted through it; the
  `.deopt` NON-last (M1) arm still panics "not modeled until 2.3c-2d".
- **2c-D D1** (commit 7f3cac2): `nativegen.runLinkedLoopDoneCapturing` (LINKED-mode counterpart
  of `runCapturingLedger` — a literal swap flips mode 1→0 and corrupts coherent resume). P1a:
  `run_continuation`/`run_inner_from` now carry the exact `*Trace` (continuation `cont`, resp.
  `.link` driver) so a `C1→I→C2` sibling swap re-runs C2, caller `nativeFor()`s the carried
  trace. `ReplayOrigin` + cursor fix: `.loop_done_linked` computes `post_pc` before accounting
  and always resumes there; an `.inner_call` seed's first loop-done does NOT consume a re-run hop
  (else a trailing `run_inner_from→continue :hop` double-increments `hops`). Call A routed through
  the capturing wrapper; `ledger_len>1` (fused I→C, 2c-E only) release-panic-guarded until D2b.
- **2c-D D2a** (commit dcacf7d): dispatcher native entry routed through the capturing wrappers
  (preserving `ran_native_link_mode`), while RETAINING the existing scalar/M1 consumer. Inert:
  scalar `result` unchanged pre-cycle, consumer reads only scalar fields, `ledger_scratch` fill
  unread until D2b.

**Verify (D1+D2a):** `just test` green; nsieve/fannkuch/nbody/spectral-norm stdout byte-identical
across tier-0 / tier-1a / native.

**NEXT — 2c-D D2b (the LIVE one):** activate `ledger_len>1` replay seeded at `ct` in the
dispatcher; FOLD the M1 fused-`.link` consumer (`fusedSourceBranchLinkSlot`, interp.zig:2717-2773)
into replayLedger's `.deopt` NON-last arm; factor a burst CORE so a replayed M1 terminal
`run_inner_from(ramp)` continues the ping-pong from already-accounted state; remove the old
consumer. This is NOT inert — it changes the live `ledger_len==2` M1 path (`[skip.deopt,
ramp.link]` continue-burst AND `[skip.deopt, ramp.deopt/prologue]` resume-at-`ct.anchor.pc`), so
it must be proven byte-identical against the current consumer. Two M1 sub-shapes to preserve:
sub-case (a) ramp reached `.link` → continue burst; sub-case (b) ramp deopted pre-`.link` →
`onSideExit(ct,skip_local); onSideExit(ramp,0); resume ct.anchor.pc` (NOT the generic `.deopt`
`link_pc`). Most-likely regression (codex): treating a replayed M1 terminal link as a FRESH
`runLinkedBurst` entry (resets `linked_completed`/`hops`, double `native_link_exits`). Get codex
gpt-5.6-sol to review the concrete D2b design before writing it. Then 2c-E (arm I→C persistently)
+ 2c-F (disarm load-bearing test + docs + full-diff review).

---

## Status 2026-07-13 (prev) — 2.3c-2b native call-B drain rerouted through ledger replay LANDED (green, byte-identical)

Second sub-step of 2.3c-2 (task #56), per Bart's "Ok, 2b next :)". Reroute ONLY the native
continuation drain (call B) of `runLinkedBurst` through the 2.3c-2a ledger; call A (hop-top
inner), the driver swap, burst-entry accounting, and the tier-1a scalar path stay UNCHANGED.
Byte-identical: nothing new armed I→C, so every call-B ledger is ≤2 entries whose terminal ==
the old scalar result.

- **nativegen.zig.** `runWithLinkedLoopDone` gained a `ledger_out: ?[]irinterp.LedgerEntry`
  out-param; `run`/`runLinkedLoopDone` pass `null`. New `pub fn runCapturingLedger(regs,
  ledger_out)` = ordinary mode + copies `NativeResult.ledger_*[0..ledger_len]` into `ledger_out`
  (asserts `out.len ≥ ledger_len`). Option (b): the 32-slot arrays never enter the by-value
  `ExecResult`; only the caller's borrowed scratch is filled.
- **irinterp.zig.** New `pub const LedgerEntry = struct { cum: usize, id: u32, exit: u32, reason:
  ExitReason }` — one decoded ledger row.
- **trace.zig.** `TraceState.ledger_scratch: [LEDGER_CAP]LedgerEntry` (borrowed capture→replay
  window, not a GC root). New `ContinuationReplay` directive union + `replayContinuationLedger`
  phase-machine (starts in `continuation` phase): resolves the first entry's owner strictly
  (`traceById`, assert==current_link), branches on `.link`-terminal vs continuation-own-deopt;
  charges `native_link_exits` ONCE on the `C.link` marker (replaces the old per-span 1726 +
  standalone-`.link` 1789 bumps — identical count); resolves the fused inner strictly by id +
  `isInnerLoopRoot`, `flocal = cum[1]-cum[0]`, loop-done via `guardExitPc`+`for_loop`. Directives:
  `run_continuation` (re-run `snt.runCapturingLedger`), `run_inner` (`continue :hop`),
  `return_result` (yield/finish), `break_burst` (`break :hop` → penalty-neutral tail). The old
  scalar `while (final != current_link.id)` drain + standalone/`completed>0`/break tail are gone
  on the native path; the `hop:` while is now labeled. Tier-1a keeps the scalar single-exit path.
- **codex BLOCKER fix.** `entries.len ≤ 2` is RELEASE-enforced with `@panic` (not a debug assert):
  a `C.link→I.guard→R.link` composition — an inner whose OWN ordinary source guard is armed to a
  ramp (2.3c-1) — could yield 3 entries; a debug-only assert would let ReleaseFast silently drop
  R's hop and misresume. The panic aborts loudly in every build, matching the old scalar drain's
  "unexpected fused shape" hard-stop. Not reachable in the test suite (assert never fired);
  2.3c-2c's full-ledger replay lifts the cap.
- **Verify.** `just test` green; the 6-benchmark matrix (nsieve, nsieve-bit, fannkuch, mandelbrot,
  nbody, spectral-norm) tier-0==tier-1a==native byte-identical; `just bench --filter nsieve` flat
  (`cross ok`, jit 92.9ms). Post-impl codex gpt-5.6-sol review confirmed exact accounting parity
  for every ≤2-entry shape (native_link_exits count, resume_pc, completed, onSideExit args,
  hops/break-continue-return mapping) — the hop-budget `hops==max` vs old `max+1` is dead-after-tail
  (not observable).

**NEXT:** commit 2.3c-2b (conventional, local only, bundled: irinterp.zig + nativegen.zig +
trace.zig + doc 17 + CURRENT_TASK.md; do NOT stage other-agent files). Then **2.3c-2c** — replace
chain-source drop-if-full with a forced yield to `shared_exit`, arm
`I.loopdone-slot[ei]→C.ordinary_entry` (`.loop_done_linked`, `isLoopDoneGuardIndex` gate), route
call A + seed receipts through the now-tested `replayContinuationLedger` (lifting the ≤2 cap),
normalize follow-counters, add a load-bearing disarm-on-unsafe test (two-phase same-VM + negative
control), peer-review the full 2.3c-2 diff with codex gpt-5.6-sol before final commit.

---

## Status 2026-07-13 — 2.3c-2a per-transition ledger ABI + emission LANDED (green, byte-identical)

First sub-step of 2.3c-2 (task #56). Bart's decision: **"Promote the M2 ledger"** — the
inner→continuation arm (2.3c-2c) closes a `C→I→C→I…` cycle in ONE trampoline entry whose
scalar `NativeResult` fields describe only the terminal hop, so the intermediate hops are
unrecoverable and the dispatcher drain can't account them. The M2 per-transition ledger,
previously "rejected/deferred", is therefore promoted and built here first — ABI + emission
only, with NO accounting change yet (that's 2.3c-2b) and NO cycle-closing arm yet (2.3c-2c).

- **irinterp.zig.** `pub const LEDGER_CAP: usize = 32` (covers the burst-hop bound: ≤9
  iterations × 2 transitions = 18 in one span; native append is bounds-guarded). `ExecResult`
  gains a defaulted `ledger_len: usize = 0` → the ~40 tier-1a `ExecResult{…}` sites untouched;
  read only on the native path.
- **nativegen.zig NativeResult.** Appended AT THE TAIL (keeps all existing `@offsetOf` baked
  into exit stubs byte-identical): `ledger_len: usize`, `ledger_cum: [LEDGER_CAP]usize`
  (scale-8), `ledger_id`/`ledger_exit`/`ledger_reason: [LEDGER_CAP]u32` (scale-4).
- **nativegen.zig `emitLedgerAppend(a, trace_id)`.** New helper emitted at all FOUR
  exit-materialization sites (`.link` terminal, linked_loop_done stub, shared `deopt_exit`,
  `prologue_fail`). Bounds-guarded drop-if-full (`cmp ledger_len, LEDGER_CAP; jae full`),
  then SIB-indexed stores `ledger_cum[len]=rbx` (cum counter), `ledger_id[len]=trace_id`
  (imm), `ledger_exit[len]=exit_instr` (reloaded from memory), `ledger_reason[len]=exit_reason`
  (reloaded), `inc len`. Scratch: rax=index, rcx=staging, rbx=cum — all dead at exits.
- **nativegen.zig `runWithLinkedLoopDone` wrapper.** `runtime_safety` tripwire asserts the
  TERMINAL ledger entry matches the scalar result (`ledger_cum[n-1]==completed`, id/exit/reason
  match, `1≤n≤CAP`); threads `ledger_len` into the returned `ExecResult`.
- **Byte-identity argument.** Appends write ONLY `NativeResult` scratch (never `regs[]` or
  program state); the drop-if-full branch is never taken pre-cycle. Control flow + scalar
  result fields unchanged → identical stdout across all modes.
- **Verify.** `just test` green — the terminal-consistency assert held across EVERY native run
  in the Debug suite (single-trace hot path AND the fused C→I spans, which already emit 2 ledger
  entries per 2.3b-1: C's `.link` exit + I's loop-done exit; the scalar drain only ever sees
  the terminal `final_trace_id==I.id`). nsieve/nbody/mandelbrot tier-0==tier-1a==native
  byte-identical; `just bench` nsieve flat (jit_execns 89.7M vs 95.9M baseline `1f39d8a`,
  nsieve-bit 50.9M vs 52.7M, nsieve-bit-fp 276M vs 279M — no regression).

**NEXT:** commit 2.3c-2a (conventional, local only, bundled: irinterp.zig + nativegen.zig +
doc 17 + CURRENT_TASK.md). Then **2.3c-2b** — route `runLinkedBurst`'s native drain through a
ledger replay (resolve each entry's owner strictly by trace_id; per-segment local =
`cum[i]-cum[i-1]`; reproduce `onSideExit`/`linked_completed`/`native_link_exits` identically),
byte-identical. Then **2.3c-2c** — replace chain-source drop-if-full with a forced yield to
`shared_exit`, arm `I.loopdone-slot[ei]→C.ordinary_entry` (`.loop_done_linked`,
`isLoopDoneGuardIndex` gate), add a load-bearing disarm-on-unsafe test, peer-review the full
2.3c-2 diff with codex gpt-5.6-sol before final commit.

---

## Status 2026-07-13 — 2.3c-1 M1 half-fusion LANDED (green, byte-identical)

Implemented the reviewed M1 contract end-to-end:

- **trace.zig arm.** `driveChain` now arms the failing skip trace's source-branch guard
  slot → the prime-side ramp's `ordinary_entry`
  (`armNativeLink(failed, exit_instr, sct, oe, .ordinary_guard)`), gated
  `tier == .native_only ∧ safe_to_arm ∧ materialization == .ordinary_header ∧
  sct.inputs.len == 0 ∧ isSourceBranchGuardExit(failed, exit_instr, proto)`. `failed` is
  now `*Trace` (mutable, `armNativeLink` needs it). New counter `native_source_link_arms`.
- **trace.zig `runLinkedBurst`.** Extracted the ping-pong burst body out of `driveChain`
  into a now-`pub` method so both `driveChain` and the dispatcher consumer enter it with
  an already-run ramp result. Verified it reads `sresult` ONLY via
  `fused_inner = if (sresult_fused) sresult else null` — with `sresult_fused == false`
  (M1 seed) the seed result is entirely unused, so passing the fused `result`
  (`completed == skip_local`) is byte-identical to the unarmed seed (`completed == 0`).
- **trace.zig `fusedSourceBranchLinkSlot`.** Provenance recognizer: returns `ct`'s
  source-branch guard slot if an armed record `{parent==ct, child==final}` exists whose
  slot is `isSourceBranchGuardExit` and `final.anchor == ct.anchor`; else null. Excludes
  the 2.3b-1 `.link_terminal` continuation→inner edge (its slot is a `.link` op, not a
  guard) and, once 2.3c-2 lands, the persistently-armed inner→continuation.
- **interp.zig fused-`.link` consumer.** Inserted after `local_done`, before guard-
  failure counting. Gated `ran_native ∧ final != ct ∧ result.exit_reason == .normal ∧
  result.exit_instr < final.instrs.len`; on provenance match: `native_source_link_fused`
  bump, `onSideExit(ct, skip_local = result.completed)`, two inert-hook asserts, then
  split — ramp `.link` → `runLinkedBurst(final, result, false, nt, .native_only,
  .ordinary_header, …)`; internal-guard deopt → `onSideExit(final, 0)` + resume at
  `ct.anchor.pc` (byte-identical to the unarmed `driveChain` seed's `{0, walk_pc}`).
  Fused prologue-fail (`exit_reason != .normal`, unreachable in practice — value-branch
  guards fire with types coherent) falls through to normal handling per the reviewed gate.
- **Verify.** `just test` green (incl. the 10-mode differential/keyframe goldens + two
  new `> 0` counter asserts in the Phase-2 nsieve chain test). 6 benchmarks
  tier-0==tier-1a==native byte-identical; nsieve `--emit-keyframe` tier-0==native
  byte-identical. Perf expected ~neutral on nsieve tiny clusters (consistent with
  2.3b-1) — value is completing native chain coverage + de-risking Increment 3, not a
  standalone speedup.

**NEXT:** commit (conventional, local only), then Increment 2.3c-2 (arm loop-done
inner→continuation — closes the native cycle; land only after 2.3c-0e disarm-on-unsafe
is proven load-bearing).

---

## Status 2026-07-13 — 2.3c fused-transition contract DESIGNED + review-clean

- **2.3c-1 re-scoped to M1 half-fusion (design only, not yet coded).** A codex
  gpt-5.6-sol pre-implementation review found the terse "arm skip→prime-side" scope
  *incoherent*: the prime-side is a `.link` **entry ramp** (no numeric-for back-edge),
  so arming `skip.guard` alone lands the fused run at the ramp's `.link` terminal with
  regs coherent at the **inner** PC while the dispatcher misreads it as an outer-header
  zero-exit → semantic **misresume**. Wrote `docs/design/17` §"Increment 2.3c —
  fused-transition contract" choosing **M1 (half-fusion)**: arm ONLY
  `skip.guard → prime_side.ordinary_entry`; decode the root's own count as
  `result.completed` (ramp commits 0 iterations → **no new NativeResult field**); add a
  dispatcher *fused top-level `.link` consumer* that replays `onSideExit(ct, skip_local)`
  + continues the burst via a `driveChain` seed of the already-run ramp result WITHOUT
  re-running the ramp. Rejected **M2** (full single-call skip→ramp→inner fusion) as
  needing the deferred P-F per-hop ledger nothing on the roadmap requires.
- **codex round-2 review of the written M1 design: confirmed + 1 BLOCKER + 1 SHOULD-FIX,
  both folded into the doc.** Confirmed: receipt decode (ramp never `inc rbx` between
  `ordinary_entry` and its `.link`), register coherence, inert-hook asserts, `onSideExit`
  ordering. BLOCKER: the fused-`.link` recognizer must discriminate on **P-E armed-edge
  provenance** (`parent==ct ∧ child==final ∧ slot_index` a source-branch guard) with a
  `exit_reason==.normal ∧ exit_instr<len` bounds gate — NOT the bare
  `final.instrs[exit_instr].op==.link` opcode, which OOBs on a fused prologue-fail
  (`exit_instr==maxInt`) and false-positives once 2.3c-2 persistently arms the
  inner→continuation slot (a directly-entered inner can return `final==continuation`,
  `final[exit_instr].op==.link`). SHOULD-FIX: the driveChain seed must consume a
  `current_link`-owned `.link` receipt at trace.zig:~1390, NOT initialize `fused_inner`
  from the ramp result (that field means the result already belongs to an inner root,
  resolved via `isInnerLoopRoot` → would panic/misclassify).
- **NEXT: implement 2.3c-1 M1** (task #55) now that the design is review-clean.

## Status 2026-07-12 (previous latest)

- **Increment 2.3c-0 (inert contracts + post-review blocker fixes): LANDED.** Six
  inert sub-steps a–f (commits `7523d1e` re-scope, `094ff89` 0b, `c295586` 0c,
  `131bc10` 0d, `bebbd48` 0e, `fd3c42e` 0f, `d276353` 0a), each byte-identical.
  Then a **codex gpt-5.6-sol contract review found 3 blockers, now all closed**
  (commit `e6b618c` fix + `5411105` test-strengthen):
  1. **Blocker 1 (broke correctness on a spilled carried home).** 0f's shared
     `deopt_exit` staged the dispatch holder in rax, but `flushSlot`'s spilled-
     carried-home `.mem` path scratches rax — clobbering the holder before the jump.
     Fix: stage the RESOLVED target in a new flush-immune `NativeResult.exit_target`
     memory field; `deopt_exit` ends `jmp qword [rdx+exit_target]`. Proven load-
     bearing by a negative control (revert tail to `jmp rax` → only the frameless
     carried-spill regression crashes).
  2. **Blocker 2 (reserved cell arm-addressable).** The exit_target fix let the
     reserved `slots[n]` "direct cell" be DELETED → `slots.len == instrs.len`, so
     `armNativeLink`'s `slot_index >= slots.len` bound rejects index n.
  3. **Blocker 3 (`final` dropped under driveChain's 8-cap).** Dispatcher `excl`
     buffer now orders `final` FIRST so driveChain's own `[8]` copy retains it.
  codex re-review: all closed, no new correctness blocker. `just test` green; 6
  benchmarks byte-identical tier-0/tier-1a/native. **NEXT: 2.3c-1** (task #55) — arm
  skip→prime-side ordinary source-branch guard (no cycle).

## Status 2026-07-12

- **Increment 1 (P-D, shared mcode arena): LANDED** — commit `a970da4`.
- **Increment 2.1 (P-A, frameless chain-entry ABI): LANDED** — commit `3f46d5e`.
  Frameless trampoline + frameless bodies; all exits pinned to `shared_exit`.
- **Increment 2.2 (P-B, chain-wide result contract): LANDED** — commit `1f39d8a`.
  Stable `Trace.id` + `NativeResult.final_trace_id` baked at every native exit +
  `traceById` dispatcher resolve/assert. No linking yet; every exit bakes its own
  `ct.id`, so `final == ct` and behaviour is byte-identical.
- **Increment 2.3a (indirect exit + link-slot table + P-E registry): LANDED** —
  commit `b8fc3fa` (+ hardening `286b145`). Indirect `jmp qword [&slot]` exit;
  per-trace heap-owned `slots: []usize` defaulting to `shared_exit`; inert P-E
  backlink registry. Byte-identical.
- **Increment 2.3b-0 (inert arming scaffolding): LANDED** — commits `9d16711`,
  `963bdbb`, `319da11`, `954ea89` (+ review `e658d07`). S3 cumulative-rbx prep,
  fail-closed `traceById`, `entry_rbx`→`local_completed`, `linked_entry` stub.
  Nothing armed; `final == ct`; byte-identical.
- **Increment 2.3b-1 (flip `.link` arming on): LANDED** — Step B (dispatcher routes
  through `final`) committed `66107a7`; Step A (driveChain persistent arming +
  unified fusion drain) is THIS commit. See the 2.3b-1 section below.
- **Increment 2.3c-0: LANDED** (see the latest-status block at the top).
- **Increment 2.3c-1 / 2.3c-2 : DESIGNED + PEER-REVIEWED + DECIDED** — see
  `docs/design/17-exit-branch-patching.md` (Done/Outstanding) and the plan file.

## What 2.2 changed (the chain-wide result contract, P-B)

Files: `src/irinterp.zig`, `src/trace.zig`, `src/nativegen.zig`, `src/interp.zig`.

- **`irinterp.zig`**: `pub const NO_TRACE_ID: u32 = maxInt(u32)` sentinel;
  `ExecResult` gains `final_trace_id: u32 = NO_TRACE_ID` (**defaulted** → the ~40
  tier-1a `ExecResult{…}` sites are untouched, zero churn).
- **`trace.zig`**: `Trace.id: u32` (stable, monotonic, never reused — the cache
  index is `swapRemove`'d so it can't be a baked constant); `TraceState.next_trace_id`
  bumped + assigned at finalize; `traceById(id)` resolver.
- **`nativegen.zig`**: `NativeResult.final_trace_id: u32`; `emitReturn` takes a
  `trace_id` param and bakes it via `movMemImm32(.rdx, @offsetOf(NativeResult,
  "final_trace_id"), trace_id)` before teardown/jump (rdx = `*NativeResult` at every
  exit); the 4 `lower` call sites pass `t.id`; `runWithLinkedLoopDone` inits and
  marshals the field.
- **`interp.zig`**: dispatcher resolves `final = traceById(result.final_trace_id)
  orelse ct` and `if (ran_native) assert(final == ct)` — validates the full baked-id
  round-trip while staying byte-identical (consumers still route through `ct`; 2.3
  switches them to `final`).

### Verification done for 2.2
- `just test` green (EXIT=0; Debug asserts active).
- nsieve 9: tier-0 == tier-1a == native byte-identical; `--jit-native` exit 0
  (assert `final == ct` passed for all native traces).
- Differential tier-0 vs native OK on: nsieve, nsieve-bit, fannkuch, mandelbrot,
  nbody, spectral-norm.

## What 2.1 changed (the frameless ABI move)

Files: `src/x64.zig`, `src/nativegen.zig`.

- **`x64.zig`**: added `jmpReg` (FF /4, indirect near jump through a GP register) +
  golden-byte test (`jmp rcx/rax/r15`).
- **`nativegen.zig`**:
  - `pub const SPILL_MAX: u32 = 512` — frameless spill ceiling (4 KiB). Even, so
    `SPILL_MAX*8` is 16-aligned → body `rsp % 16 == 8` (same invariant the
    self-framed prologue gave, which the hash-cell callout relies on).
  - `McodeArena.ensureTrampoline()` — emits the shared trampoline ONCE into a
    permanent (never-freed) arena slot; returns `{entry, shared_exit}` absolute
    addrs. Trampoline: `push rbx/rbp/r12/r13/r14/r15; sub rsp,SPILL_MAX*8;
    xor rbx,rbx; jmp rcx`. `shared_exit`: `add rsp,SPILL_MAX*8; pop …; ret`.
    C-ABI `fn(rdi=tags, rsi=payloads, rdx=*NativeResult, rcx=body_entry)`.
  - `CompiledTrace.trampoline_entry: ?usize` + `TrampolineFn` type; `run` dispatches
    through the trampoline for arena (production) pages, directly (`EntryFn`) for
    owned (test) pages.
  - `compileImpl`: when `arena != null`, bail if `alloc.spill_count > SPILL_MAX`,
    else `ensureTrampoline` and pass `shared_exit` into `lower`; sets
    `trampoline_entry` on the result.
  - `lower(…, shared_exit: ?usize)`: prologue push/sub guarded behind
    `shared_exit == null`; every exit now calls `emitReturn(a, frame, callee,
    shared_exit)` — self-framed teardown when null, `movabs rax,shared_exit;
    jmp rax` (absolute, direct) when set.
  - Test path (`compile`, `arena == null`) keeps the OLD self-framed ABI → ~60
    standalone-page tests untouched + built-in A/B of both ABIs.

Refinement vs the doc's final design: 2.1 uses a *direct* absolute jmp to
`shared_exit` at each exit (no per-trace slot table). 2.3 replaces it with the
indirect `jmp [slot]` handoff (slot default = `shared_exit`) when link population
lands. Behaviourally identical while no slot is armed.

### Verification done for 2.1
- `just test` green (EXIT=0).
- nsieve 9: tier-0 == tier-1a == native byte-identical.
- 5 native traces compile+run frameless (`--dump-native`).
- Differential tier-0 vs native OK on: nsieve, nsieve-bit, fannkuch, mandelbrot,
  nbody, spectral-norm, sieve_int, **field_hash** (the resolveHashCell callout —
  most rsp-alignment-sensitive), array3d, grid_matmul.
- `just bench --filter nsieve --reps 5`: jit ms flat (93.3→91.5 nsieve;
  52.5→53.3 nsieve-bit; within noise). ABI move is perf-neutral (expected — no
  linking yet, just one extra indirect jmp per trace entry/exit).

## What 2.3a changed (indirect exit + slot table + P-E registry, byte-identical)

Files: `src/x64.zig`, `src/nativegen.zig`, `src/trace.zig`.

- **`x64.zig`**: added `jmpMem(base, disp)` (FF /4 memory form, indirect near jump
  through `[base+disp]`) + golden-byte tests (`FF 20`, `FF 60 08`, `41 FF 20`).
- **`nativegen.zig`**: `CompiledTrace` gains `slots: []usize` (owned, one per IR
  instruction index, default-filled `shared_exit`) + a `gpa` handle for `deinit`.
  `emitReturn` takes `slot_addr: ?usize` — when set (frameless + chainable exit) it
  emits `movabs rax, &slot; jmp qword [rax]`; `null` (deopt_exit/prologue_fail) keeps
  the direct `movabs rax, shared_exit; jmp rax`. `compileImpl` allocs `slots` *before*
  `lower` (stable imm64), frees on every failure path; `slotAddr(slots, i)` helper.
- **`trace.zig`**: `NativeLink{parent, slot_index, child}` + `TraceState.armed_links`
  list; `armNativeLink` (records dependency, supersedes same-slot record, then writes
  slot); `resetLinksTouching(t)` (child-retire → reset parent slots to `shared_exit`;
  parent-retire → drop record; slot addr re-derived from live parent, never cached);
  `removeTrace` calls it *before* `destroy`. Focused unit test pins both directions +
  re-arm supersede + OOB/non-compiled no-ops.

Nothing arms a slot yet → `armed_links` always empty, every exit still resolves to
its own `ct.id`, so `final == ct` holds and output is byte-identical.

### Verification done for 2.3a
- `just test` green (EXIT=0; Debug asserts + P-E registry unit test).
- nsieve 9: tier-0 == tier-1a == native byte-identical.
- Differential tier-0 vs native OK on: nsieve, nsieve-bit, fannkuch, mandelbrot,
  nbody, spectral-norm.
- `just bench --filter nsieve --reps 5`: jit ms flat (nsieve 94.2 vs 2.1's 91.5;
  nsieve-bit 53.8 vs 53.3; within noise — one extra load per exit is perf-neutral).

## 2.3a foundation review (two independent models) — DONE, hardening landed

Reviewed the `b8fc3fa` foundation with codex gpt-5.6-sol + a fable
technical-architect pass (Bart's call: review the foundation now, not just at the
end). Both returned **"approve with changes"** and converged: byte-identical holds,
S2 reset ordering correct both directions, slot addressing sound, and the flat
identity-keyed registry is genuinely *better* than the plan's pointer-map (which
would dangle its cached `*usize` on parent-retire).

**Hardening landed as a follow-up commit (still inert / byte-identical):**
- **BUG-1 (real latent OOM-only UAF, mine):** `armNativeLink` re-arm did
  `swapRemove(old)` then `try append(new)`; a failed append stranded the slot armed
  but untracked → S2 UAF on the old child's retire. Fixed: mutate the record in
  place on supersede (no allocation on the re-arm path). Doc comment corrected.
- `armNativeLink` now returns `bool` (armed vs no-op) for P-F accounting; pinned
  "only writer of `slots[i]`" invariant; unit test updated.
- doc 17: recorded the `rdi`/`rsi` liveness contract (P-A) and the
  slot-index-vs-exit-kind collision open question (P-C, blocks 2.3c).

**Bart's decisions from the review:**
- `armNativeLink` **keeps** the explicit `target` param + gets a Debug
  bounds-assert (`target` within `child`'s page). Deferred to 2.3b because the
  assert reads `child.page` → needs real compiled children (= fable's real
  retire-then-reuse test, item 6).
- **Pull S3 forward into 2.3b:** fix the chain-safe result contract (child
  prologue-fail must carry cumulative `rbx` + a distinct reason, never
  `completed=0`) BEFORE arming any slot, so the first arm is unconditionally
  chain-safe. codex flagged this as a hard prerequisite to the first real arm.

## NEXT: Increment 2.3b — arm `.link`-terminal handoffs (now incl. S3)

Slot table + P-E registry exist but nothing arms a slot. 2.3b makes `driveChain`
store a child's frameless body entry into the parent's slot for the **single-contract
`.link` terminal only** (avoids S1 loop-done dual materialization):
- **S3 result contract FIRST (pulled forward):** split `prologue_fail` so a child
  whose entry guard fails *after* the parent committed writes cumulative `rbx` +
  `final_trace_id=child` + a distinct reason, never `exit_instr=-1`/`completed=0`.
- **Bounds-assert + BUG-2:** add the Debug `target`-within-`child`-page assert in
  `armNativeLink` and the missing-trampoline assert in `resetLinksTouching`; add a
  real retire-then-reuse lifetime test (arm, force `removeTrace`, assert parent slot
  reset before the arena slot can be reused).
- **Eligibility (P-G):** child `.compiled`, `inputs.len == 0`, exit kind `.link`.
- **Arming point (P-F):** inside `driveChain` *after* the existing per-hop
  `onSideExit`/counters run, so every accounting side effect still happens; then
  `armNativeLink(&parent, E, child, child.page.code.ptr)` (now returns bool).
- **Safepoint blackout:** do NOT arm when `suspend_ctl`/replay-line/exec-log active.
- **Dispatcher (P-B payoff):** DROP `assert(final == ct)`; route consumers through
  `final` not `ct` — `last_exit_instr`, guard-fail counting
  (`final.instrs[exit_instr]`), `onSideExit(final,…)`, `maybeArmContinuation`,
  productive-branch counting, source-branch discrimination (interp.zig ~2586–2807).
Then 2.3c (ordinary guards + loop-done, S1; slot-identity collision decision), 2.3d
(P-E lane-widen end-to-end + peer-review full diff). Increment 3 = full
`lj_asm_patchexit` port (guard-jump rel32 patching, no runtime re-entry).

## 2.3b CONTRACT REVIEW (codex gpt-5.6-sol) — planned scope is WRONG, re-plan pending

Ran the arming contract past codex before coding the dispatcher rewire. Verdict:
**"do NOT implement 2.3b as 'arm the slot, drop `final==ct`, route everything
through `final`'."** Two substantive findings the plan missed:

- **BLOCKER — the `.link` terminal is NOT single-contract on the child side.**
  The L→I hop (a `.link` continuation reaching its terminal, handing off to the
  inner-loop root `I`) is run today via `int_native.runLinkedLoopDone(regs)`, which
  sets `NativeResult.linked_loop_done = 1`; `I`'s inner loop-done guard READS that
  flag (nativegen ~4213) to pick linked-completion materialization vs ordinary
  deopt. A bare armed `jmp I.page.code.ptr` does **not** set the flag → `I` takes
  ordinary `deopt_exit`, never commits its final iteration → wrong state. So arming
  `.link`→inner drags in the S1 mode-propagation that was supposed to be deferred to
  2.3c. Fix needs one of: (a) a second entry point on `I` (`linked_entry`) that
  presets the flag then falls into the body — armed slot targets that; (b) a per-arm
  stub that sets the flag then jumps; (c) enter armed parents with the flag already
  set. (a) is cleanest (compile-time, no runtime thunk, `I` codegen unchanged).
- **DETERMINISM TRAP — "route consumers through `final`" is unsafe as-is.** Exit
  IDENTITY (`exit_instr`, guard lookup, exit PC, resume PC) must use `final`. But
  the recording-STEERING accounting (`onSideExit`, `maybeArmContinuation`,
  `countProductiveBranchExit`) must reproduce driveChain's *logical* per-hop events,
  which are specific (validate loop-done → `onSideExit(I, max(local,1))` → +1
  enclosing progress; NO `maybeArmContinuation`/`countProductiveBranchExit` on that
  hop). Calling the dispatcher's whole productive-exit block against `final` invents
  accounting the unarmed chain never did → different penalties/gates → different
  later trace recording → **non-byte-identical across modes.** Worse,
  `NativeResult.completed` is cumulative `rbx`, NOT `I`'s LOCAL count nor
  `ChainResult.completed`; feeding cumulative `rbx` to `onSideExit` can flip a
  low-yield event to "useful". Needs a WIDER result contract: final identity + final
  exit reason + final's **local** committed count + enclosing-chain progress — the
  current 4 `NativeResult` fields are insufficient.
- Minor: once linking is live, `traceById(id) orelse ct` (interp ~2595) should
  **fail closed** (assert), not silently reinterpret a child exit as the parent's.

Net: the first real arm needs (i) child linked-entry mode propagation, (ii) a wider
`NativeResult` (local completed + enclosing progress), (iii) a driveChain-faithful
accounting split (identity via `final`, steering-accounting replicates the hop's
logical events), (iv) fail-closed `traceById`. That's materially bigger than the
one-commit 2.3b in the plan.

**Bart's decision:** split into 2.3b-0 (inert scaffolding, reviewed) then 2.3b-1
(flip arming on + accounting split).

## 2.3b-0 — inert scaffolding: LANDED (byte-identical, awaiting peer review)

Four inert commits, each `just test` green + nsieve 3-mode byte-identical + tier-0
== `--jit-native` on the 6-benchmark differential. Nothing armed yet.
- **`9d16711`** — S3 prep: `prologue_fail` commits cumulative `rbx`, not literal 0.
  Byte-identical unchained (rbx provably 0); preserves progress once chained.
- **`963bdbb`** — fail-closed `traceById`: under `ran_native` assert the baked id
  resolves BEFORE `orelse ct` (kills the P-E dangling-link mask); keep `== ct`.
- **`319da11`** — `NativeResult.entry_rbx` snapshot (first body instr) → wrapper
  derives `ExecResult.local_completed = completed − entry_rbx`. Invariant
  `entry_rbx == 0` while unchained pins the mechanism; `local_completed` defaulted 0
  on tier-1a sites, read only on the native chained path (2.3b-1).
- **`954ea89`** — `linked_entry` stub (Trap-1 fix): every frameless body emits a
  secondary entry that presets `linked_loop_done=1` then falls through to
  `body_entry`; `CompiledTrace.linked_entry` = its abs addr (new
  `x64.Assembler.labelOffset`). Wiring invariant `arena ⟺ linked_entry`. Inert —
  nothing targets it until 2.3b-1.

## 2.3b-1 — flip `.link` arming ON: LANDED (byte-identical)

Two commits. **Step B (`66107a7`, committed):** dispatcher routes exit consumers
through `final = traceById(final_trace_id)` (strict on native — `@panic` on null,
release too; tier-1a still `ct`), productivity via `local_completed`.
**Step A (THIS commit):** `driveChain` actually arms + drains fused hops.

- **Arming** (`trace.zig`): after a hop is accounted, arm the continuation's
  `.link`-terminal slot → `inner.linked_entry` via `armNativeLink(current_link,
  len-1, inner, le)`. Eligibility: `tier == .native_only`, `safe_to_arm`,
  `inner.inputs.len == 0`, and the terminal (re-read AFTER the driver swap) is
  `.link` with `aux == inner_pc`. `safe_to_arm = suspend_ctl == null and
  !record_safepoint_lines`, computed in the dispatcher and threaded into
  `driveChain` (all 6 call sites). New counter `native_link_arms`.
- **Fused drain** (`trace.zig`): a `snt.run(current_link)` whose `final_trace_id !=
  current_link.id` fused straight into a child inner root. The drain resolves that
  child **STRICTLY** by `traceById(final_trace_id)` + `isInnerLoopRoot` shape check
  (never `findLoopTrace` substitution — a previously-armed slot can target a sibling
  `findLoopTrace` no longer picks). Loop-done vs. mid-loop is classified by
  `guardExitPc(child.instrs[exit_instr])` following a `for_loop`; steering uses the
  child's OWN `local_completed` (it inherits the parent's cumulative rbx). Same
  strict resolution seeds hop-0.
- **Hard-fail on identity break:** an unresolvable/mis-shaped fused id is a `@panic`,
  NOT a bail — the child's exit leaves `regs[]` with no known-coherent resume PC, so
  a `break`+resume could re-run a committed inner loop (silent double-count). Applies
  to hop-0 seed, the drain, and the dispatcher's native resolution.
- **Asserts dropped:** `assert(final == ct)` (interp.zig) and `assert(entry_rbx ==
  0)` (nativegen `runWithLinkedLoopDone`) — both false once fusion is live (a fused
  child inherits the parent's cumulative rbx and performs the final exit ≠ ct).

### Bug fixed during 2.3b-1 (under-count, native 2346810 vs 2406000)
A `guard_fits` array-guard mid-loop deopt on the fused inner's first trip
(`local_completed == 0`) was misclassified as loop-done, because `guardExitPc`
returns null for array guards and the drain's `fdone` defaulted null → `true`,
counting a phantom outer iteration and stranding iteration i=N. FIX: default the
null-`guardExitPc` and `exit_instr == maxInt` (prologue_fail) cases to `false`
(mid-loop → resume inner header, don't count).

### Peer review (codex gpt-5.6-sol, 3 rounds) — CLOSED
Round 1: 5 issues (prologue_fail maxInt phantom, fused-consumed-as-findLoopTrace,
pre-swap terminal validation, leftover `final==ct`, within-burst identity hole) —
all fixed. Round 2: demanded strict fail-closed identity resolution (no
substitution) — applied. Round 3: the fail-closed bails must `@panic` not `break`
(no safe resume PC), + strict native dispatcher resolution in release — applied.
Verdict: **no correctness blocker**; two doc nits (bail-comment wording, mirror the
9-completion bound into doc 17) — both addressed.

### Verification done for 2.3b-1
- `just test` green (EXIT=0; Debug asserts + link-counter tests).
- N-sweep 22/23/24/25/30/50/100/400: tier-0 == tier-1a == native byte-identical.
- Differential tier-0 == tier-1a == native OK on: nsieve, nbody, mandelbrot,
  fannkuch (spectralnorm.lua absent locally).

### Deferred out of 2.3b-1 (non-blocking, recorded in doc 17)
- **Issue 4:** native drain permits ≤ `visited.len + 1` (9) completions vs tier-1a's
  8 — a heuristic burst max, not a correctness contract; the "8-hop" comments should
  be reconciled to the 9-vs-8 split.
- **Issue 5 → P-F:** a slot stays armed and keeps fusing after `safe_to_arm` goes
  false; always correctly accounted, but widens the observation blackout window.
  Reset/decline-on-observation deferred to P-F.

NEXT: Increment 2.3c — arm ordinary source-branch guards + loop-done (S1 dual
materialization, S3 prologue-fail split, slot-identity collision decision).

## Unpushed local commits (Rule #15 — don't push unless asked)
master is well ahead of origin/master; do NOT push without Bart's say-so.

## Untracked files that belong to OTHER agents — do NOT stage
`CURRENT_TASK_E3.md`, `bench/results/*.tsv`, and similar.
