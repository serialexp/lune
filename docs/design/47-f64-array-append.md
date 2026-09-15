# f64 array append recording — Design

Status: partial — increments D (0fb8eb2), f64 append + A (7a6ca81, peel
fallback 3ab724a), and B (closed-SCC owner election + the full
regression-elimination arc: strike-out tombstone, instability eviction,
deferred maps rebuild, dormant admission, net-work backstop, parked
promotion proofs, page-windowed patch mprotect — this change) landed;
increment C (dead-append-cont entry-refusal thrash, spectral) and the codex
round-3 D cheapenings outstanding
Owner: Claude (campaign loop), codex review threads
01a09045-973c-79d1-9070-d94fbb7955ac (f64 append / A / C),
01a0a3df-2eb7-79f3-8cae-d4dfa776a007 (increment B)
Last updated: 2026-09-15

## Implementation status

Tracking the gap between this design and what's on the main branch.
Tick items as they land; move whole sections to "done" once
everything inside them is checked.

### Done

- [x] **Recorder: admit the f64 lane in the append branch.** `arraySetShape`'s
  append gate is `(lane == .boolean or lane.isInt() or lane == .f64)`;
  everything downstream (guard_table/guard_lane/aref/guard_append/guard_fits/
  astore_append, all `lane_ord`-parameterised) was already lane-generic.
  "Phase A" scope comment updated.
- [x] **proveKinds: `.float` arm for `astore_append`.** Mirrors the in-bounds
  `astore` float proof — `kinds[ins.b] == .float`, no `fits_mask` bit (any
  float fits f64; the f64 `guard_fits` is the type pin and native lowers it to
  nothing). Stale guard_append comment updated.
- [x] **Native emit: F64_LANE branch in `.astore_append`.** Value staged into
  `XMM_SCRATCH0` FIRST (same scratch-aliasing discipline as the in-bounds
  f64 `astore`), then `lea rax = &data[idx0*8]`, `movsd [rax], xmm`, presence
  `bts` (f64 is a presence-bitmap lane), shared trailing len bump — bump LAST
  publishes the fully-written slot, the same soundness argument as the int
  branch. Boolean-only description comment updated.
- [x] **Stale scope comments elsewhere.** `array.zig` `Lane.isInt` doc now
  says f64 is excluded from that predicate only for its store SHAPE (XMM),
  not for missing support.
- [x] **Lowering tests.** f64 fill expectMatch-style native test (compiled
  `astore_append` f64 + tier-0 output equality) with 5000 slots (presence
  bits 63/64 crossed) and `-0.0` sign preservation (`1/t[2500] == -inf`);
  8-mode byte-identity incl. a NaN fill (`z/z`) re-read via `t[i] ~= t[i]`;
  `.value`-lane append refusal.
- [x] **End-to-end convergence regression test (codex-required).** Grow-then-
  reuse (sparse_mult shape, parameters not upvalues): asserts BOTH `.link`
  continuations exist at the same anchor (append-shaped + in-bounds sibling),
  `native_loopdone_link_fused > 0`, no record_gate entry for the continuation
  anchor, and the stale append trace still cached (no retirement needed).
  jit-debug confirmed the full arm chain: `loop_done_linked` 3→4,
  `sibling_handoff` 4→5 (via the provenance drain, `guard_append` slot),
  `link_terminal` 4→3 and 5→3.
- [x] **Gates.** unit (all green incl. the four new tests), wasm build,
  8-mode hashgate 84×2 green.

- [x] **The doc-47 hold RELEASED — f64 append + Increment A landed together
  (7a6ca81, `perf(jit): doc 47 — f64 array append + continuation link
  peeling`).** Increment A shipped as continuation-scoped link peeling: a
  `.continuation` recording that reaches an inner `for_prep` whose root's
  entry guards have a float-on-int mismatch peels one inner body iteration to
  promote types before closing `.link` (two-phase `await_initial_entry →
  peeling` state machine in `RecordingSession`). Killed the prologue-fail
  thrash (3M replayLedger walks × ~531 cyc = 42% of sparse's runtime). A/B at
  landing: sparse 605→310 ms (−49%), spectral −19%, grid_matmul_f64 −9%.
  Follow-up 3ab724a: peel-to-link FALLBACK — an abort inside the peeled body
  (spectral's `get_upval aliased_input`) falls back to the plain `.link`
  close instead of killing the whole continuation recording (prevented an
  8× spectral regression).

- [x] **Increment B — closed-SCC owner election (this change).** The
  `{inner, post-inner continuation}` cycle minted `armable=false` forever, so
  silent promotion never engaged and every burst drained at LEDGER_CAP=32
  through the runtime seam (~4889 cyc × 13.65M/run = 55% of sparse
  wall-clock, measured 2026-09-15). Landed as a FALLBACK TIER in the owner
  predicate (`trace_region_topology_build.zig` step 3e-b), per codex review
  01a0a3df: runs only when the primary `(is_ext or enclosing) and has_root`
  pass yields `both_count == 0`, and requires the full closed-SCC proof —
  no incoming boundary edge, all members one proto, and exactly ONE member
  that is a loop root fed by an internal top-level same-proto
  `.link_terminal` edge from a non-root member (destination NODES counted,
  not edges; several qualifying roots stay unarmable). Unit tests
  (`trace_region_test.zig` "inc-B …": election + rebind stability, guard-fed/
  foreign-proto/inlined negatives, two-root ambiguity, node-counting, open-SCC
  refusal) plus promotion assertions in the doc 47 convergence test
  (armable cycle region, `silent_promotions > 0`, all three arm kinds,
  clean rejects). A/B (5-rep interleaved ReleaseFast, vs 09bb515 shadow):
  scimark-sparse 322–378 → 204–207 ms (~−40%).

- [x] **Increment B follow-up — the regression-elimination arc (codex thread
  01a0a48c-6935-7960-873e-e9409784c036, rounds 1–3).** Increment B as first
  landed regressed fft/lu/sor/spectral/nbody on the board; Rule #2 held the
  commit until every one was eliminated. Five policy mechanisms + one
  structural change, each diagnosed from profiles/probes rather than tuned:
  - **Fallback strike-out tombstone (fft):** a fallback-elected owner at
    `max_penalty` invalidates one-shot instead of the primary tier's
    repeating gate + registry-wide `disarmAllLinks` (which re-fired on EVERY
    strike at saturation — ~2× fft wall on its phase-variant butterfly).
  - **Instability eviction (lu/sor, half 1):** `.unfreeze` demotion of a
    LIVE promotion charges `RegionDef.instability`; clean `.region_close`
    survival decrements; tombstone at 8. Catches the 435k-strike/175k-cycle
    oscillation that per-anchor penalties (remove-on-recover) never saturate
    on.
  - **`pending_region_rebuild` (lu/sor, half 2 — decisive):**
    `invalidateRegion` left the dead region's receipt-map entries live
    forever, so `receiptsInert()` stayed false and EVERY receipt
    program-wide paid the pipeline for a tombstone. The flag defers a maps
    rebuild to the end of `settleNativeCallProvenance` (the common
    settlement funnel every ledger driver passes through — codex round-2
    blocker (b) moved it off the dispatcher-only drain); `rebuildRegions`
    consumes it.
  - **Dormant admission (spectral):** fallback regions mint `dormant` —
    excluded from the source/dest receipt maps, so the pipeline stays
    short-circuited until a full-cap forced-yield ledger proves via the
    candidacy detector that the region owns a promotable set
    (`tryDormantAdmission`, order-independent per codex round-2 blocker
    (c): probe every eligible region, min-RegionId winner, failures charged
    to non-matchers, publish after the loop; `admission_failures` cap 64 =
    terminal dormancy). Spectral (2 minted regions, zero promotable
    ledgers, +16% pre-gating) never admits and pays nothing.
  - **Deterministic net-work balance (codex round-2 blocker (a)):**
    `receipts_debit` (per priced receipt) vs `transitions_credit`
    (suppressed silent transitions at burst drain); after a 4096-receipt
    minimum sample, survive only while `credit × region_profit_weight(4) ≥
    debit`. NEVER reset by promotion — grid_matmul promotes 203× while
    remaining net-negative, so "a promotion occurred" is not repayment.
    Empirically a RECEIPT-TAX BACKSTOP, not a profitability oracle (codex
    round 3): sparse debit 4096/credit 180k and grid debit 4096/credit 34k
    both survive — grid's real cost was never receipts.
  - **No-candidate settlement:** consecutive dry full-cap ledgers for an
    active frozen fallback region saturate `no_candidate_runs` (8) →
    invalidate; any successful promotion resets the consecutive count.
  - Unit tests: `trace_region_test.zig` ("inc-B fallback_owner flag",
    "inc-B strike-out policy", "inc-B dormancy", "inc-B net-work balance",
    "inc-B null-effective receipt attribution") and
    `trace_promotion_test.zig` ("inc-B dormant admission" ×2, "inc-B
    no-candidate settlement", "inc-B instability").

- [x] **Parked promotion proofs (codex round-3 C′) + page-windowed patch
  mprotect — the grid_matmul residual.** After the mechanisms above, grid
  remained +8%: 203 promote→one-burst→`.region_close`→re-promote cycles at
  ~20.5k cycles each (per-anchor TSC: main:37 246→20,939 c/it × 200
  activations), each re-earning the `promote_after`(=4) full-ledger streak +
  `detectPromotableSet`. Codex rejected pricing promotions into the balance
  (dimensionally weak, Z-6 risk) and prescribed the lifetime split:
  **persistent physical-set evidence, activation-scoped authorization.** A
  clean `.region_close` demote of a fallback-owned set parks its edge array
  keyed by RegionId (`NativePhysicalRegistry.parked_proofs`); the region's
  next activation (full-cap yielded ledger + live FROZEN accumulator)
  re-promotes through the FULL fail-closed `promoteSet` validation, skipping
  only re-detection and the streak. Take semantics (a failed validation
  discards the proof); `.unfreeze`/growth/slot/trace demotions park nothing;
  proofs hold *Trace pointers so they drop eagerly in `resetLinksTouching`,
  `disarmAllLinks`, `demoteSetsForRegionDefsMutation` (covers
  `invalidateRegion` + every rebuild), and deinit. Second cost cut:
  `applyPatch`/`alloc` flipped the whole 1 MiB mcode region RW↔RX around
  every 5-byte patch (1,640 region-wide mprotects/run on grid — PTE rewrite
  + TLB + icache refetch for every co-located trace); `protectWindow` now
  flips only the page(s) spanning the write. Results: grid 199/203
  promotions via parked proofs, 0 stale, suppressed transitions 54,873 →
  73,977 (+35%); sparse reuses 96/101 and drops ~205 → ~150 ms (−49% total
  vs 09bb515, 5.4× LJ); grid residual +8% → ~+2-3% ≈ the measured
  code-layout noise band (fft ±1.5%, btrees ±3%, both with zero region
  activity). Tests: `trace_promotion_test.zig` "C' parked proof" ×3
  (park/reuse-without-detection, never-park reasons, drop funnels +
  stale-proof fail-closed into detection).

- [x] **Increment D — RESOLVED and LANDED separately (0fb8eb2,
  `fix(jit): retain lane traces for unfrozen arrays`).** The "warmup/
  bookkeeping scaling" framing was a symptom-list; the single root cause was
  **widen-eviction mint-retire churn**: `laneWidenedPast` treated a fresh
  unfrozen `.value` array (the next outer iteration's `{}` — `.value` is the
  widening-lattice top, `canWidenTo` always false) as "monotonically widened
  past" the fill trace's `guard_lane` pin, evicted it, reset the warm
  counter, and re-recorded an identical trace every outer iteration — ~600
  record+optimize+compile+topology-rebuild+entry-patch rounds per
  grid_matmul run (2448 rec-arms → 12 after the fix). The perf symptoms
  (topology_build, session-reset memset, Gate lookups, allocator churn) were
  all downstream. Monotonicity begins at `ArrayPart.frozen`
  (`commitFreshLane`), so the fix skips unfrozen arrays in the predicate;
  regression pair + reachability cases in `src/trace_evict_test.zig`. The
  churn predates this doc (int fills had it too): D-only interleaved A/B vs
  baseline — grid_matmul **−36%**, repack **−55%**, spectral −5%, rest
  neutral; sparse +5% wall proven layout noise (byte-identical traces and
  counts, −0.9% instructions, +18% L1-icache misses; codex-ruled
  non-blocking). Codex split-land ruling (rounds 4–6): D lands alone; the
  f64 append stays held until A + C clear sparse/spectral.

- [x] **Increment A — compatible loop-entry stitching (the sparse seam);
  landed as the continuation-scoped link peeling in 7a6ca81 (see the
  hold-release entry above for what shipped). The design narrative below is
  kept verbatim — the round-3 rejection reasoning is a standing constraint.**
  Codex round-2 diagnosis: the steady-state burst is
  `inner.loop_done → append.guard fail → sibling.link → inner.linked_entry
  PROLOGUE_FAIL → replayLedger` (~576 cyc) once per 5-iteration row. The
  continuation resets `sum` with INT 0; the inner root recorded after an
  interpreted first iteration when `sum` was already FLOAT, so its entry
  prologue (`guard_float`) rejects the linked state every row. The link
  machinery closed a structural cycle that is not dynamically enterable —
  link eligibility checks destination pc only.

  **Round 3 — eager int→float conversion at the link boundary REJECTED
  (codex BLOCKER; keep this reasoning).** The tempting adaptation of
  DUALNUM-LuaJIT's `lj_opt_narrow` promote-at-loop-boundary is unsound for
  mahina's observable numeric types, in two independent ways, and ordering
  the conversion below the last continuation guard fixes neither:
  1. A successful handoff changes ITERATION 1's guest semantics: the float
     root describes steady-state iterations, and a body may observe the
     accumulator BEFORE the arithmetic that naturally promotes it —
     `out[i] = math.type(sum)` prints "integer" on tier-0's iteration 1 but
     "float" after eager conversion; integer division (`0//2` int vs
     `0.0//2` float), >2^53 arithmetic, and formatting give more
     counterexamples. (LuaJIT's conversions are sound only because its
     UNROLLED first iteration keeps the original typed IR; conversion
     applies at the steady-copy boundary.)
  2. The child PROLOGUE is itself a side-exitable boundary that checks far
     more than numeric tags (table lane/metatable, grid shape, closure
     identity, seed resolution): `.link` has already flushed the converted
     slot, so a non-type prologue failure resumes tier-0 with `sum=0.0`
     where the pure timeline had int 0. This is doc 39's already-rejected
     eager-coercion shape.
  Two further holes for ANY entry-contract design: `.link` stores an anchor
  PC, not the identity of the root whose contract was checked — arm-time
  selection can pick a different sibling, the scanned root can retire — so
  the contract must PERSIST and every later arm/re-arm must select a
  compatible child; and the linked-entry prologue derives from
  `proveKinds → analyzeInner → Alloc.slots`, NOT from a naive
  slot_load→guardNum IR-prefix scan (write_only/boxed/none slots differ,
  tropt moves/dedups guards) — an entry signature must come from a shared
  logical analysis that native allocation asserts agreement with.

  **The accepted design: continuation-scoped peeling / entry stitching.**
  Record iteration 1 INSIDE the continuation with its original int
  semantics (the record-through path recForPrepLink already has records
  `for_prep` as plain arithmetic; recording then unrolls into the body),
  and close `.link` at the first BACK-EDGE (`recForLoop`, continue
  direction) where the live recorded state genuinely matches the steady
  root's entry contract — reusing doc 39's entry-kind/steady-kind model
  for the match, with a persisted entry contract consulted at arm time.
  Bound the peel (1–2 iterations) with a deterministic counter; still-
  mismatched → today's LINNER abort. `float_of_int` may exist as an
  internal primitive but cannot carry the design. Codex-required negative
  tests: `math.type(sum)` observed before promotion; int division / >2^53
  arithmetic before promotion; a nonnumeric child-prologue failure after
  handoff; the record-time root superseded by an incompatible sibling at
  arm time.

### Outstanding

- [ ] **Codex D cheapenings (round 3, independent follow-up):** O(1) current-
  activation resolution instead of the `activeRegionFor` linear map walk (it
  runs per receipt AND per native entry via `prepareNativeEntry`); an indexed
  owner/active-set check instead of sweeping all promoted sets per entry;
  cheaper `accountRegionProfit` classification (measured ~600 cyc/receipt on
  grid). Lowers the promotion break-even everywhere; not required for the
  current board (grid residual is at the layout-noise band) so deferred.
- [ ] **Resident-but-disabled patches (codex round-3 escalation):** only if a
  future workload shows the remaining patch/unpatch cost (2 page-windowed
  mprotects per edge per promote/demote) is material — the parked-proof +
  windowed-mprotect combination made it immaterial on the current board.
  Requires an activation enable/disable token in the silent epilogue; codex
  flagged the permanent exit-path tax as the risk to measure first.
- [ ] **Increment C — kill the dead-append-cont thrash (spectral is the
  concrete case).** Original framing was "repoint the loop-done arm off the
  dead append cont as cleanup after A"; the spectral-norm diagnosis
  (2026-09-11, increment D session) upgraded it to a required increment for
  landing this doc. Mechanism: with f64 append recordable, the loop-done
  continuation at Av/Atv pc=22 (`y[i]=a`) records during the FIRST call
  (append phase, `v` empty); every later call stores in-bounds, and the
  cont's entries refuse at the **prologue/fingerprint stage — NOT at a guard
  terminal — so the sibling-handoff convergence path below never produces a
  want.** Result: 3334 `gate[dispatch:legacy_thrash]` cooldown cycles at
  pc=22 (baseline: 4), the inner loop loses its linked bursts (364k tier-0
  fallback iterations vs 13.7k), each paying an un-inlined A head-trace call
  (~244cyc × 366k), spectral +9.6%. Design constraint stands (codex round 3):
  base the cure on the proven relation — feed entry-refusal evidence into the
  same side-specialization path guard terminals feed, or disarm/repoint off
  the cont via parent-guard-failed → sibling-entered → sibling-terminal —
  never a "failed last N entries" heuristic (phase-dependent arm churn).

## Board outcome (2026-09-11, the hold decision)

Boards: 20260911-210929-877fbf4 (this tree) vs 20260911-195243-318382b
(HEAD). Everything below verified by interleaved per-bench A/B against an
nm-clean HEAD shadow, not board rows alone. The f64 append is semantically
correct, fully gated, and general — but it EXPOSES two pre-existing
structural costs at new call sites: (1) the per-row runtime boundary when a
linked cycle is not dynamically enterable (increment A/B), and (2)
per-anchor warmup bookkeeping that scales badly with trace count
(increment D). Codex verdict: land only with the rest of the board
neutral-or-better — which failed — so the tree holds until the increments
above make it net-positive. jit-stats on the real sparse bench with this
tree: loopdone fused 150M (was 0), residency 58%, but wall 573→701ms.

## Why this exists

Task #30's diagnosis. scimark-sparse's inner loop runs native after doc 46,
but at ~5 elements/row the dispatcher seam (~380-cycle `replayLedger` walk per
entry, 3.0M walks) eats the win: ~3 iterations amortise nothing. The designed
cure — the doc 15/17 loop-done link, where a continuation records the outer
tail (`vy[r]=sum`, outer back-edge, next row's preamble) and closes `.link`
into the inner root — already works elsewhere (nbody: `loopdone=199975`
fused). On sparse it never fired: `loopdone=0`.

Root cause (reproduced in a 25-line script, `sp_calib` shape): scimark's
harness makes a calibration call with `cycles=1` first. `vy` starts `{}`, so
during that entire first call every `vy[r]=sum` is an **append** to a growing
f64-lane array. The inner root compiles within that call; the loop-done
continuation anchor gets hot within it too; and every recording attempt hits
the recorder's append gate — which admits only bool + int lanes — falls
through to the in-bounds check, and aborts `.bad_type`. Six aborts =
`max_strikes` → the record_gate **permanently** blacklists the anchor. Later
calls store in-bounds, but no recording is ever attempted again.

The general gap (Z-6 — we fix the language, never a benchmark) is "float
array fill loops don't record". Float fills are as common as int fills in
numeric code (`random_vector`'s `x[i]=rand()`, any table-building loop). The
append machinery (doc 18 D2.3, Phase A) stopped one lane short of f64 only
because the native array path had no XMM store at the time; it has had one
since the in-bounds F64_LANE `astore` landed. This doc extends append by
exactly that lane. `.value`-lane append stays out of scope (same write-
barrier reasoning as the in-bounds `.value` restrictions, doc 32).

## Steady-state convergence (the reviewed story)

With f64 append recordable, the calibration call's continuation COMMITS an
append-shaped trace (`guard_append`: `idx==asize`, hash empty, `len<cap`).
At steady state that guard fails on every entry. The original design claimed
thrash-gate → retirement → re-record; codex review showed that is **wrong**:

- A dispatch-gated anchor's committed trace is not evicted (`gateAnchor`
  only suppresses entry), and `onBackEdge` returns immediately on `hasTrace`
  — so cooldown/re-record never happens while the trace is cached.
- The failing tail is penalty-neutral anyway: the preceding
  `.loop_done_linked` row counts as productive (`linked_completed > 0`), and
  the `.deopt`/`ends_link` burst consumers deliberately don't charge the
  terminal continuation row.

The path that actually converges is **hot-exit side specialization**:

1. `noteDispatcherLedgerTerminal` counts the terminal `guard_append` failure
   even inside a productive burst.
2. A non-loop-done zero-progress exit raises `wants_side_trace` after
   `config.hotexit` failures (`noteTakenExit`).
3. `consumeSideTraceWantAtResume` starts a recording at the continuation
   anchor, which now observes the in-bounds store shape and commits a
   sibling continuation.
4. Commit preserves parent-exit → child provenance; the provenance drain
   compiles the sibling and arms a **direct guard → sibling handoff** on the
   stale continuation's `guard_append` exit (pre-effect, so
   `exitIsPreEffect` admits it).

The direct handoff matters: both continuations can end up with equal
`hit_count`, and canonical loop-done selection breaks ties toward the OLDER
(append) trace — so without the armed handoff the stale trace could keep
winning selection. Retirement is neither required nor available. No
record_gate forgiveness/decay is warranted: the blacklist never engages once
the append records.

## Non-goals

- `.value`-lane append (write-barrier territory, doc 32 reasoning).
- Grid (`set_index2`) appends / grid growth — different machinery entirely.
- Any change to record_gate / blacklist semantics.

## References

- Codex review thread `01a09045-973c-79d1-9070-d94fbb7955ac` (this design):
  convergence-story blocker + test requirements.
- `src/trace_recorder.zig` `arraySetShape` — the append branch.
- `src/nativegen_prove.zig` — `guard_append` / `astore_append` proofs.
- `src/nativegen.zig` — `.astore_append` lowering.
- Doc 18 (append Phase A), doc 32 (value lane), docs 15/17 (loop-done
  linking), doc 31 (record_gate semantics), doc 46 (the arc that exposed
  this as sparse's next lever).
