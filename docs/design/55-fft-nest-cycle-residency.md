# 55 — Nest-cycle residency: why scimark-fft's linked traces fall back to the dispatcher

**Status:** partial. §1 landed (committed completion rows count as
progress; fft 23.3× → 14.6× LJ; Antigravity-approved, codex re-review
owed). §2 (region laps) and §3 (bit-reverse peeled traces) are diagnosed
but not designed.
**Owner:** claude (campaign: every benchmark ≤1.2× LuaJIT; weakest-bench arc)
**Last updated:** 2026-09-24

## Implementation status

### Done

- [x] **Diagnosis — layered, per the Z-8 ladder.** `--jit-stats`, `perf`,
  and `-Djit-debug` receipts on scimark-fft (below). Two new permanent
  probes: `provenance-retire:` (a provenance edge struck out) and
  `region: close rid= activation= work=` (every region activation close,
  with its window work).

- [x] **§1 — committed completion rows are progress.** `LedgerKind.commitsGuestWork`
  plus a suffix bit in `provenanceEdgeVerdict`. Implemented in the tree with
  pinned unit tests. Gates green and board measured (fft 23.3× → 14.6× LJ,
  no regressions). Codex was unavailable (usage limit until 2026-09-29), so
  at Bart's direction Antigravity reviewed it instead: **APPROVED**, no
  blockers, one comment nit (applied). Codex re-review is still owed once
  credits return.

### Outstanding

- [ ] **Codex re-review of §1** once credits return (2026-09-29).
- [ ] **§2 — the region never sees a whole lap.** The nest cycle's region
  activation closes after every inner-loop exit with `work=1`, strikes 8
  times, and gets tombstoned during warm-up. So no silent promotion, and the
  cycle runs in rows mode forever (30.6% of the run is replay). Needs a
  root-cause pass on the close site, then a design.
- [ ] **§3 — bit-reverse peeled traces barely dispatch.** `fft_bitreverse:9`
  and `:55` have committed peeled traces but run ~0% traced (43% of the run
  after §1). This is doc 40's open question (fusion exclusion for peeled
  traces) plus the doc-38 `low_trip_while` gate. Needs its own design pass.
- [ ] **Post-arc measurement.** Full board, `--jit-stats`, and a re-profile.

## Why this exists

scimark-fft is the weakest board entry after doc 54: 393 ms vs LuaJIT
16.9 ms (23.3×) at `beec337`. `--jit-stats` at `1c5d1fb` (fft 500, one
run on a loaded machine):

| | value |
|---|---|
| wall | 545 ms |
| trace entries | 1,016,150 |
| native link follows | 8,468 |
| ran as trace | 27.1% of cycles |
| tier-0 with a trace present | 47.7% of cycles |
| replay seam | 12.8% (1.01M walks, ~302 cyc/walk) |

`perf`: `replayLedgerFrom` 14.1%, `enterSelectedTrace` 11.2%,
`driveDispatcherLedger` 3.5%. Roughly 31% is seam, 43% is tier 0, and only
12% is native code.

The traces all exist, and they are the right shape. This is the LuaJIT
nest: the inner butterfly loop (`fft_transform:131`, t6), a
middle-loop-done continuation (`:193`, t7), and its same-anchor sibling for
"middle loop continues" (`:193`, t8, which links back into t6). They are
armed as one cycle:

```
t6 --loop_done_linked--> t7 --deopt ei=8, sibling_handoff--> t8 --link_terminal--> t6
```

So the problem is not coverage. The problem is that two separate
zero-progress detectors each judge this cycle unproductive and switch it
off.

## §1 — Committed completion rows are progress (provenance strikes)

### Finding

The provenance edge `t7 ei=8 → t8` is retired permanently
(`provenance-retire: t=7 ei=8 -> t=8 strikes=3`). The three strikes all
come from the last butterfly stage. There, `dual2 == n`, so the inner loop
runs **one trip** per entry. A one-trip loop takes no back-edge, and `cum`
counts only back-edges. So a whole 32-row burst reads `cum=0` on every row,
even though each lap commits a full butterfly body (t6's `loop_done_linked`),
the middle-loop step (t8's `link_terminal`), and the setup for the next
inner loop.

`provenanceEdgeVerdict` defines progress as `cum` only. That matches doc 17
§B.5 as written ("zero cumulative progress through the alternation").
Retirement is permanent (the edge is `swapRemove`d). So once the one-trip
stage is seen, every later stage of every transform loses the arm. Each
middle-loop iteration then pays a dispatcher round-trip, a replay walk, and
a tier-0 iteration of t8's path plus the first inner iteration. That is the
1.01M entries and 1.01M tier-0 iterations at `:131`/`:99`.

### Change

A ledger row *kind* can prove committed guest work that `cum` cannot see:

- `link_terminal`: a page ran to its terminal and committed.
- `loop_done_linked`: the final iteration's stores and φ snapshot were committed.
- `region_bridge`: dominating φ updates were committed.
- `head_terminal`, `ret_pop`, `call_push`: frame-motion commits.

These kinds do not prove progress: `deopt` (tier 0 re-runs the iteration;
it proves progress only through `cum`), `prologue_fail` and the seed
declines (no body ran), and `precise_deopt`/`precise_error` (partial
commit; always terminal anyway).

`LedgerKind.commitsGuestWork()` is an exhaustive switch, so every future
kind has to decide. `provenanceEdgeVerdict` carries a `suffix_commits` bit
next to `suffix_max`, and a matched row resets when either shows progress.
The backward-walk equivalence argument is unchanged, because the new bit is
the same kind of suffix aggregate.

### Soundness and progress argument (Z-8: widening a gate)

- **Soundness.** Arming, eligibility, and the physical publish predicates
  do not change. The verdict only decides whether an already-armed,
  already-validated edge is *retired*. Keeping an edge armed longer is the
  same state the edge has on any productive run.
- **Progress.** The strike exists to stop a JIT livelock: siblings bouncing
  on coarse deopts, where tier 0 re-runs the same iteration and the guest
  never advances (doc 17 §B.5 major 4). Such a cycle has only `.deopt`,
  `prologue_fail`, or decline rows, and all of them still strike (pinned
  tests 3 and 5). A cycle with a committing row advances the guest at
  least one committed segment per lap. If it repeats forever, that is the
  guest program's own loop, not a JIT livelock.
- **Branch-only scar.** The nsieve `for_prep` zero-trip +128% ping-pong
  was an *eligibility* scar (`siblingHandoffEligible`). It is untouched.

### Measurement (prototype, fft 500, single runs, load ~9–16)

| | before | after §1 |
|---|---|---|
| wall (`--jit-stats` run) | 545 ms | 445 ms |
| trace entries | 1,016,150 | 100,180 |
| native link follows | 8,468 | 923,986 |
| `:131` tier-0 iterations | 1,012,586 | 97,068 |
| replay walks | 1.01M @ ~302 cyc | 97k @ ~6,150 cyc |
| seam share | 12.8% | 30.6% |

Interleaved A/B against a `just shadow` baseline at `1c5d1fb`
(`commitsGuestWork` absent from the baseline binary, checked with `nm`):
fft 356/360/374 ms → 262/243/251 ms. Full board (`just bench`,
`20260924-130332`): scimark-fft 393.0 → 242.8 ms (23.3× → 14.6× LJ).
Every other row is flat or better. binary-trees read +6% on the board, but
interleaved A/B shows the new binary is faster (433/429/426/419/445 →
403/400/417/385/420 ms), so that reading is load noise. Gates: `just test`
green; `zig build test -Djit-debug=true` exit 0.

The cycle now stays linked, but it runs in **rows mode**: 3,519 bursts
end at `LEDGER_CAP` with a `yielded` row, and each row is repriced by
`replayLedgerFrom` (~190 cyc/row). That is §2.

## §2 — The region never sees a whole lap (silent promotion blocked)

### Finding (diagnosis incomplete)

Z-8 ladder layer 2: the arms are live (`yielded` rows prove it), but rows
are written on every burst. `silent: candidates=0`.

- `region: mint id=0 kind=cross_trace_cycle members=2 armable=true`
  appears right after t8 commits.
- `region: dormant admission rid=0` comes on the first full-cap yielded
  ledger.
- Then comes `region: close rid=0 activation=2054 work=1` **after every
  t6 `loop_done_linked` row**, each followed by a `window-strike` (work 1 <
  `min_useful` 8). After 8 strikes: `fallback owner strike-out — tombstone
  rid=0 owner pc=131`. That happens during warm-up and is permanent.

So the activation opens, earns 1 unit of work (the `loop_done_linked`
row's region credit), and closes at the next transition. It never
accumulates a window. Candidates (to confirm next):

1. The `t6 → t7` destination does not resolve to region 0
   (`dest_entry_regions` / member-point mapping for a *second* trace at a
   member anchor).
2. The same-anchor sibling row `t7 → t8` is deliberately `.deferred`
   (§A8-v). Its successor `t8 → t6` may then be misread as a departure.

The comment above `applyWindowDecision` already names this exact shape:
"fft's butterfly: work=1 early stages, work=512 late". The tombstone was
the fix for the cost of repeated global disarms on it. That fix was
correct as damage control. What it doesn't address is why a closed cycle
closes its activation every lap.

**Lead from the §1 review (Antigravity; to verify).** The close fires in
`applyDestination` (`trace_region_policy.zig` ~192: the selected source is
not among the destination's candidates). `dest_entry_regions` is built only
from each region's `member_trace_ids` (`trace_region_topology_build.zig`
~688), and t7 is not a member trace. So the `t6 → t7` row reads as a
departure on every lap. That matches candidate 1 above, and the topology
builder already knows the concept ("sibling non-member exit at a member
anchor", ~683).

### Open questions

- [ ] Pin the close site: `applyDestination` vs `chooseSource` vs
  `observeRegionProgramPoint`, and which membership lookup fails.
- [ ] Is region work = "owner loop-done count" the right unit for a nest
  whose owner is the *inner* loop? Per lap, the cycle's real work is one
  middle iteration plus 1..n/2 inner iterations.
- [ ] **The silent path has its own cum-only progress definition.** In the
  promoted-epilogue summary (`emitSilentEpilogue`, `nativegen_emit.zig`
  ~1319), a firing is "productive" only when `local != 0`, and a
  `link_terminal` firing advances the barren run as zero work. Both
  disagree with §1's definition. It's dormant on fft today (nothing
  promotes), but §2 has to reconcile it before the cycle can go silent.
  Otherwise the silent provenance verdict (`silentSiblingEvidence`) will
  re-strike the same one-trip stage that §1 fixed for rows mode.

## §3 — Bit-reverse peeled traces barely dispatch

`fft_bitreverse:9` (outer `for`) and `:55` (inner `while k <= j`) are
type-unstable on first iteration (`k = k / 2` makes `k` float, and `j`
follows). Docs 39 and 40 made them record as peeled traces. After §1 they
are 43% of the run (18.5% + 24.8%) at ~0% traced. Doc 40 already names
two blockers:

1. The doc-39 v1 **fusion exclusion**: `armNativeLink` refuses peeled
   parents and children, so exits are never patched.
2. The doc-38 **`low_trip_while`** dispatch gate (the `:55` while-loop
   averages <3 trips per entry).

Not investigated further in this pass. It needs its own design (doc 40
"Open question — persistent fusion for peeled traces").

## References

- Doc 17 §B.5/§B.6 (provenance edges, `max_edge_strikes`), §B-3 (silent
  promotion).
- Doc 38 (while-inner linking, `low_trip_while`), doc 39/40 (peels, fusion
  exclusion).
- Doc 47 Increment B (fallback owner election, tombstones), doc 51/52
  (variable-trip nests, recurrence promotion).
- `src/trace_regionops.zig` `provenanceEdgeVerdict`, `applyWindowDecision`,
  `closeRegion`; `src/trace_exec.zig` `LedgerKind`.
