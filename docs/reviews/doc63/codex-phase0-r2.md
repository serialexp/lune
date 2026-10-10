# Codex — Phase 0 (benchmark and budget) review (round 2, 2026-10-11)

Verbatim reply. Dispositions in `phase0-dispositions.md`.

---

APPROVE WITH CHANGES

Dispositions: **#1 resolved**, with cached-trace verification still scheduled for Phase 2c/3; **#2 partially resolved**; **#3’s requested edits landed, but its new measurement needs correction**; **#4, #5 and #6 resolved**.

1. **[should-fix] The slot derivation still omits temporaries.** [§8.1:1132](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:1132) counts 9 slots for `minl` and 24 for `wide`. Running the unchanged compiler under `/tmp` confirms **12 and 28**. Missing slots are `minl`’s r7–r9 and `wide`’s r22–r25, including the left operand copied before the call. Precise snapshots include dead temporaries ([snapshot contract:8](/home/bart/Projects/lune/src/trace_snapshot.zig:8)); write-dominated carried slots must flush their previous-iteration homes ([emitter:745](/home/bart/Projects/lune/src/nativegen.zig:745)). With the stated invariant skips, that gives **8 flushed / 4 skipped** and **23 flushed / 5 skipped**. The table’s addition is correct, but corrected inputs produce **242–250** and **307–330**. **Fix:** enumerate the complete windows, update the projection and remove the claim that both upper estimates fit. Keep the performance targets.

2. **[should-fix] `nest(N) − nestq(N)` includes subsequent outer-loop costs.** [Runner:101](/home/bart/Projects/lune/bench/embed/tracecall.py:101) labels the difference as one call’s total. Rebuilding the revised C probe under `/tmp` against the cached library gives JIT-on differences of **1,610,335 instructions at N=2,000** and **3,033,963 at N=1,000,000**, despite identical nested work executed once. Thus [§8.1:1175](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:1175)’s 3.0 M includes effects after the callback. Future blacklisting further separates the two callers’ execution tiers. **Fix:** end both measurement runs immediately after iteration 1,000, or report the existing result as the whole-run incremental cost and measure callback suspension separately. Update the table, README and disposition accordingly.

3. **[should-fix] Argument scaling still understates gathering.** [§8.1:1142](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:1142) describes each argument as a flush plus one load. [gatherScratch:1597](/home/bart/Projects/lune/src/interp.zig:1597) reconstructs each `Value` from the slab’s tag and payload lanes and copies it into contiguous scratch. This work remains under the proposed shim. **Fix:** describe that copy explicitly and provision or measure its per-argument cost; revise the “all of it dispatch” scaling claim.

Bart, I kept all supplied rules in mind. I made no repository or Git-state changes; scratch builds ran only under `/tmp`.

[Codex thread: 01a123dc-056c-7e63-b5ed-8bae4448f147]
