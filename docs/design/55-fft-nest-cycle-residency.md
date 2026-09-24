# 55 — Nest-cycle residency: why scimark-fft's linked traces fall back to the dispatcher

**Status:** partial. §1 landed (committed completion rows count as
progress; fft 23.3× → 14.6× LJ; Antigravity-approved, codex re-review
owed). §2 (a)/(b)/(c) plus §2d (the silent switch as data) landed:
fft 14.6× → 12.6× LJ, sparse −31%, no regressions; Antigravity
approved with nits (applied), codex re-review owed. §3 (bit-reverse
peeled traces, now 63% of fft's run) is diagnosed but not designed.
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

- [x] **§2 — the region never sees a whole lap.** Root cause: (a) the
  landing sibling, (b) remainder strikes, (c) silent cum-only progress.
  Fixed with tests. (a) is split into two indexes (`arrival_entry_regions`,
  Bart's pick) after the one-map version broke nsieve.
- [x] **§2d — silent switch as data.** A compiled per-exit cell check
  (`emitSilentCheck`) replaces runtime code patching (Bart's pick, "option
  1"). `patchRel32` / `patchWindow` and their machinery are removed. Board:
  fft 242.8 → 207.2 ms (12.6× LJ), sparse −31%, no regressions; lu
  `mprotect` 53,134 → 14. `just test` and the jit-debug gate are green.
  Antigravity review (codex still out): **APPROVED WITH NITS**. Both are
  applied: (1) `checkPromotable` now refuses a set naming one exit twice
  (code patching used to refuse it by accident), pinned in the B-3b.2 test;
  (2) the tail waiver is explicit about `work > 0`.

### Outstanding

- [ ] **Codex re-review of §1** once credits return (2026-09-29).
- [ ] **Codex re-review of §2/§2d** once credits return (2026-09-29).
- [ ] **§3 — bit-reverse peeled traces barely dispatch.** `fft_bitreverse:9`
  and `:55` have committed peeled traces but run ~0% traced (43% of the run
  after §1; tier-0-with-a-trace is 63% of fft's cycles after §2d). This is doc 40's open question (fusion exclusion for peeled
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

### Finding (completed 2026-09-24)

The lead held. There are three causes, each needing its own change:

- **(a) Landing sibling.** The inner loop-done lands in t7, a sibling at
  `:193` that only hands off to t8 (the realizer of the back-edge). t7
  realizes no internal edge, so it is not in `member_trace_ids`.
  `applyDestination` then reads every lap as a departure.
- **(b) Remainder strikes.** Even with (a) fixed, every butterfly stage
  ends with a tail of 2^k − 1 laps (< `min_useful`). `beginClose` struck
  each tail, which unfroze and demoted the silent set every stage.
- **(c) The silent path's cum-only progress** (open question below).

### Change (in tree, uncommitted)

- **(a) Two indexes.** `dest_entry_regions` stays the strict member proof,
  read by `traceInRegion` for bridge child selection. A new
  `arrival_entry_regions` is `dest_entry` closed over same-anchor
  provenance links (`SiblingLink` in the topology `View`). Only
  `applyDestination` and `receiptsInert` read it. It extends neither
  `member_points` nor `source_exit_regions`. A first version used one map
  for both jobs. That broke nsieve: the bridge t2 ei=23 armed into t3, the
  sibling that deopts on entry. Trace entries went 364 → 10k, the seam went
  8.7% → 45.8%, and nsieve went 13 → 19 ms. Hence the split (Bart's pick).
- **(b) Remainder-tail rule.** In `beginClose`, a close with
  `work < min_useful` after a useful window has already been seen is not
  low-yield evidence (no strike, no flush).
- **(c) Committing kinds count as progress on the silent path:**
  `stageSilentSuffixProvenance`, plus the `emitSilentEpilogue` productive
  mark (only `.deopt` needs `local != 0`).

### Measurement — (b) exposes the silent flip cost

Plain-timing A/B against `4619829`, with (a) as one map, bisected:

| bench | base | (a)+(b)+(c) | (b) off |
|---|---|---|---|
| fft | 235–259 ms | 270–295 | 231–241 |
| lu | 148–155 | 197–221 | 150–151 |
| nsieve | 13–14 | 18–19 (a) | 20–21 (a) |

(c) alone is neutral. With (b), the fft and lu regions are never struck,
so they live forever. Every activation close parks the silent set, and
every re-entry re-promotes it: lu flips 6,640 times and fft 4,998 times.
**Every flip rewrites machine code**: `patchRel32` / `patchWindow`, each an
RX→RW→RX `mprotect` pair per edge. That's lu 102 → 53,134 `mprotect` calls
and fft 24 → 60,000. On fft the seam fell 449M → 147M cycles, but "other"
rose 55M → 218M, so the net is zero. On lu, `lu_factor:11` tier-0 went
145 → 14,867 cyc/iter.

### §2d — The silent switch is data, not code

**What LuaJIT does.** `lj_asm_patchexit` rewrites an exit only when a side
trace attaches (`lj_trace.c:531`). The patch is one-way and is never
undone; only a flush clears it. Code changes are rare, monotonic compile
events, and everything that changes at run time lives in data. The only
knob Pall offers for protection-toggle cost is the opt-in RWX build
(`LUAJIT_SECURITY_MCODE=0`, "ONLY if page protection twiddling becomes a
bottleneck"). He never flips code per activation. Silent mode has no
LuaJIT counterpart (the ledger is ours), so the mahina equivalent of his
rule is: **promote/demote must not touch code.**

**Design.** Each patchable exit already owns a per-exit data cell
(`CompiledTrace.metadata_cells[exit]`, heap RW). It is 0 when the exit is
not promoted and `*SilentExitMetadata` when it is, and `promoteSet`
already writes it before patching. The patch site stops being a
`nop5` / `jmp deopt_exit` rewritten at run time. It becomes a permanent
check emitted once at compile time:

```
mov  rax, imm64 &metadata_cells[exit]
cmp  qword [rax], 0
jne  silent_epilogue
<original reporting path>     ; ledger append / jmp deopt_exit
```

`rax` and the flags are dead at all four sites. The `nop5` sites are
followed by `emitLedgerAppend`, which loads `rax` fresh. At the deopt site,
`exit_target` is staged in memory because `deopt_exit` clobbers `rax`.
The epilogue keeps its own reload of the cell: the `.deopt` epilogue's
carried-home flush clobbers `rax` before it.
`reporting_target` (where the epilogue goes when a reporting prefix exists)
becomes the fall-through address after the `jnz`, the same for every kind.
For `.deopt` that is `jmp deopt_exit`, identical to the old
`originalRel32Target`. Promote and demote become cell writes (publication:
metadata first, then the cell). The deferred demote during a replay walk
stays, because it protects the lifetime of summary/metadata storage, not
code. `patchRel32`, `patchWindow`, and their validation become dead and are
removed. `ExitPatch` keeps `kind`, `exit_instr`, `resume_off`, and
`metadata_cell`.

**Cost.** About 20 bytes per patchable exit stub (cold code), and one
load + compare + branch per firing of a patchable exit. That is cheap next
to the ledger append the firing already does. Measured, not assumed (below).

As built, `promoteSet` proves every edge's site (`silentSiteFor`: live
compiled parent, a check of the edge's kind, testing that exit's own cell)
before it allocates anything. Publication is then an infallible cell write,
so the old patch-unwind path is gone. The `arena` parameter left the whole
promote/demote family (`promoteSet`, `demoteSet*`, `prepareSlotMutation`,
`publishValidatedLink`), because none of them touch code any more. Removed:
`McodeArena.patchRel32` / `patchWindow` / `applyPatch` /
`validatePatchPage`, `PatchError`, `x64.nop5`, `EXIT_NOP5`,
`originalRel32Target`, and `CompiledTrace.pageGeneration`. Kept: the page
generation plus `live_pages`, which still guard `McodeArena.free` against a
double free.

### §2 + §2d measurement

Interleaved plain-timing A/B against `4619829` (ReleaseFast, 4 reps, ms):

| bench | base | §2 + §2d |
|---|---|---|
| fft | 264 259 246 272 | 214 216 223 226 |
| lu | 168 159 156 159 | 156 153 155 162 |
| nsieve | 21 14 12 13 | 13 13 14 13 |
| sor | 90 86 88 88 | 86 86 84 90 |
| sparse | 40 36 35 31 | 26 24 25 27 |
| nbody | 47 40 40 41 | 42 43 41 41 |
| recursive-fib (5 reps) | 79 80 78 79 80 | 81 80 78 87 78 |
| str_format (5 reps) | 106 108 104 107 107 | 104 105 104 105 110 |

`mprotect` calls: lu 102 → 14 (fewer than the base, since the base's early
promotions patched code too). fft: 24, the same as the base (60,000 with
§2 alone). What remains is compile-time allocation only.

Board (`just bench`, 5 reps) vs the §1 board (`20260924-130332`): fft
242.8 → 207.2 ms (14.7× → **12.6× LJ**), sparse 179.1 → 122.8 (−31%),
sieve_int −20%, repack −11%, nsieve −10%, binary-trees −8.5%,
grid_matmul(_f64) −5.5/−7.9%. recursive-fib showed +5.3% on the board, but
the interleaved A/B above puts it at parity (noise). Everything else is
within ±3%.

fft `--jit-stats` after §2d: 23k trace entries (1.02M at the arc start),
seam 13.5%, native 19.4%, and **tier-0 with a trace present at 63% of the
run**. That is §3 (the bit-reverse peeled traces), now clearly the next
lever.

**Why not "stay patched longer" (doc 52 residents).** That cuts the number
of flips but keeps every flip expensive. Each new reason to flip
(invalidation, membership growth, a second resident) brings the cost
back. Once a flip is a data write, "should a set stay silent across
closes" becomes a pure policy question that can be decided on its merits.

### Open questions

- [x] Pin the close site: `applyDestination` vs `chooseSource` vs
  `observeRegionProgramPoint`, and which membership lookup fails.
  → `applyDestination`; t7 was missing from `dest_entry_regions` (see (a)).
- [ ] Is region work = "owner loop-done count" the right unit for a nest
  whose owner is the *inner* loop? Per lap, the cycle's real work is one
  middle iteration plus 1..n/2 inner iterations.
- [x] **The silent path has its own cum-only progress definition.** → (c).
  In the
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
