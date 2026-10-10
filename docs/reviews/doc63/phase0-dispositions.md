# Phase 0 (benchmark and budget) review, round 1 — dispositions (2026-10-11)

Reviews: `codex-phase0.md` (APPROVE WITH CHANGES),
`antigravity-phase0.md` (APPROVE WITH CHANGES).

The probe was re-run after these fixes; §8.1's table carries the new
numbers (`two`, `cb`, `fail`, `wide` and `tw` moved by a few
instructions with the probe changes; `nest` is now a different
measurement, see Codex 3).

| Finding | Disposition |
|---|---|
| Codex 1: `two` disturbs before either trace can form | Fixed. `two` calls `host_late(i, on)` with `on = j > 10`: the first 10 rounds (500 calls per loop, 1,000 in all) only return the argument, then every call calls back. Both anchors pass `hotloop` during the warm-up. Checking that both traces exist before the disturbance needs Phase 2c (today the loops cannot trace); the Phase 2c/3 re-run checks it with `--jit-stats`. |
| Codex 2: budget arithmetic understates save/restore and flush; flushed subset unjustified; gathering stays in the shim | Fixed. §8.1 now uses 42 for save/restore, 2–3 instructions per flushed slot, and derives the flushed and skipped slots of `minl` (5 flushed, 4 skipped) and `wide` (19 flushed, 5 skipped) from `compileNumericFor`'s layout and `emitPreciseSnapshotFlush`'s invariant skip. The shim row includes argument gathering. Projection: `minl` ~236–241 of 250, `wide` ~299–318 of 320. Both targets kept; the doc says the margin is small and names the flush as the first place Phase 3 looks. |
| Codex 3: `nest` is a workload-specific projection, not a bound; the first call precedes recording; the nested result was unchecked | Fixed. `nest` now disturbs once, on its 1,000th call, after the loop is hot; `nestq` is the same loop with no disturbance, and the runner reports nest(N) − nestq(N), the one call's total. `host_nest` checks that `work(100000)` returns 5000050000 and fails the run otherwise. §8.1 calls the ~31 M (about 310 per callback-loop iteration) a projection for this workload, not a constant. The delayed call costs 3.0 M with the JIT on today, against 1.6 M for the old first-call measurement; the doc uses the delayed number. |
| Codex 4 / Antigravity 2: iteration validation, `two` normalisation | Fixed. `tracecall.py` rejects unknown shapes and any N that is not a multiple of 100 or is below 2000, before building. `two` then makes exactly N host calls, so per-iteration is per call; the table says so. |
| Codex 5: TODO scaling statement | Fixed. The TODO entry says each lookup is linear in the prefix it scans, summed over the error and its frames, and frames the 30× as an error raised deep in a 100 KB script. |
| Codex 6: entry-lease A/B belongs to Phase 2b | Fixed. The Phase 1 checklist bullet carries the A/B of the epoch compare and the `suspend_depth` checks; the Phase 2b bullet carries the lease's. §8 and §8.1 say the same. |
| Antigravity 1: uncommitted `src/trace_chain.zig`, `src/trace.zig`, `src/interp_bool_test.zig` break `zig build test` | Not ours. Those files are another agent's work in flight (doc 57 P3) and are not part of this commit, which stages only the Phase 0 files. We do not touch them (global Rule #14). |
| Antigravity 3: `nargs` checks in `host_cb`, `host_tw`, `host_nest` | Fixed. Every host that reads an argument checks `nargs` and returns `MH_ERR_API`. |

## Round 2

Reviews: `codex-phase0-r2.md` (APPROVE WITH CHANGES),
`antigravity-phase0-r2.md` (APPROVE, with one low finding).

| Finding | Disposition |
|---|---|
| Codex r2-1 / Antigravity r2-1: the slot derivation omits the expression temporaries; precise snapshots are full | Fixed. §8.1 now cites the full-window contract (`trace_snapshot.zig`) and enumerates every register from the bytecode. `minl`: 12 registers, 8 flushed (`s idx i r7 r8 r9 r10 r11`), 4 skipped. `wide`: 28 registers, 22 flushed, 6 skipped (`n h t limit step` and the never-written `r15`); Codex counted 23/5, but nothing in the body writes `r15`, so it is an invariant own-slot load and is skipped. Projection: `minl` ~242–250, `wide` ~305–327. The doc no longer claims both fit; the targets stay. It lists two ways for Phase 3 to shrink the flush, skipping slots dead at the resume pc and a sparse snapshot form, with what each would give (`minl` 4 live of 8, `wide` 12 of 22), as options, not a decision. |
| Codex r2-2: nest(N) − nestq(N) includes outer-loop costs after the call | Fixed. The runner measures nest(1000) − nestq(1000): both runs end right after the disturbing call. JIT on: 1.60 M (it was 3.0 M at N = 1,000,000). §8.1's projection becomes ~32 M, ~320 per callback-loop iteration. The leftover effect is real and varies between identical runs (`nest 1000000`: 795.10 M, 795.10 M, 796.23 M; `nestq` steady at 792.07 M), so it is now a TODO.md entry ("A guest callback slows the host-calling loop that follows it"); the run-to-run variation suggests address-dependent behaviour. |
| Codex r2-3: argument scaling understates gathering | Fixed. §8.1 describes `gatherScratch` (rebuild each `Value` from the two lanes and copy it into scratch) and `cHostCall`'s conversion. Both are inside the funnel and shim rows for one argument. Each extra argument is provisioned at 10–25 beyond its flush, for Phase 3 to measure. The tier-0 slope is now "mostly dispatch". |

## Round 3

Reviews: `codex-phase0-r3.md` (APPROVE WITH CHANGES),
`antigravity-phase0-r3.md` (APPROVE WITH CHANGES). Both resolve round 2's
`nest` and gathering findings.

| Finding | Disposition |
|---|---|
| Codex r3-1 / Antigravity r3-1: `wide`'s `r15` is written (pc 14 and 37), so the count is 23 flushed / 5 skipped | Accepted; my round-2 count was wrong, as both bytecode dumps show. §8.1 now enumerates `r15…r21` as `b…k`, `r22` the new `k`, `r23` `a + h(i)`, `r24` the copy of `a` then `G1`, `r25` the result. 23 flushed / 5 skipped, flush 46–69, total ~307–330, live 12 of 23 (sparse projection ~285–297 unchanged). The round-2 row above is kept as written. |
| Codex r3-2: `cHostCall` does no per-argument conversion | Fixed. Checked `capi.zig` `cHostCall`: it passes the `Value` buffer to the C function by pointer cast, and its validation loop covers results only. §8.1 says so; the per-argument allowance is the gather plus host-side work. |
| Codex r3-3: `minl`'s whole range meets the target | Fixed: "meets its target across the range, with no margin at the top; `wide` may miss by up to ten." |

## Round 4

Reviews: `codex-phase0-r4.md` (APPROVE), `antigravity-phase0-r4.md`
(APPROVE). No findings.
