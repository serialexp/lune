# Codex — Phase 0 (benchmark and budget) review (round 1, 2026-10-11)

Verbatim reply. Dispositions in `phase0-dispositions.md`.

---

APPROVE WITH CHANGES

1. **[should-fix] `two` cannot exercise two cached callers.** It calls the callback-producing host immediately ([probe:75](/home/bart/Projects/lune/bench/embed/tracecall_probe.c:75)). Under §5.9, that native becomes disturbing before either host-calling trace can commit. **Fix:** add a deterministic clean warm-up phase for both anchors, then enable callbacks. Verify both traces exist before triggering the disturbance when Phase 2c/3 lands.

2. **[should-fix] The budget arithmetic understates some costs.** [§8.1:1119](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:1119) allows ≤40 save/restore instructions, but the current emitter saves and restores 21 lanes: **42 instructions**, before call setup. Flushes also require three instructions for constants or spilled payloads ([constant flush:735](/home/bart/Projects/lune/src/nativegen.zig:735), [spill flush:527](/home/bart/Projects/lune/src/nativegen_emit.zig:527)). A compiler probe finds 12-register `minl` and 28-register `wide` windows; the assumed flushed subsets need justification. Argument gathering also remains in the shim ([§5.8:633](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:633), [gatherScratch:1597](/home/bart/Projects/lune/src/interp.zig:1597)), contradicting the claim that scaling becomes just two stores. **Fix:** retain the targets, but recalculate the projection with these costs and explicitly derive which snapshot slots are skipped.

3. **[should-fix] `nest` establishes a workload-specific projection, not a suspension bound.** Its expensive work runs on the first invocation ([probe:165](/home/bart/Projects/lune/bench/embed/tracecall_probe.c:165)), before recording; the measured difference is approximately **32.2 million instructions for this summation workload**. [§8.1:1135](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:1135) generalizes that into a bound without exercising suspension. Moreover, the nested result is discarded, so checksum parity does not validate that work. **Fix:** describe the number as a projection, add a delayed disturbance after warm-up, and validate `work(100000)` returns `5000050000`.

4. **[nit] Validate iteration counts and normalize `two` accurately.** [Runner:100](/home/bart/Projects/lune/bench/embed/tracecall.py:100) divides by zero for `nest --iters 1`; ordinary shapes divide by zero at zero. `two` executes `100 × floor(N/100)` host calls, while the runner divides by N. **Fix:** reject invalid counts before building and require multiples of 100 for `two`, or report its actual call count.

5. **[nit] Qualify the TODO’s scaling statement.** [lineFromOffset:189](/home/bart/Projects/lune/src/compiler.zig:189) scans only through the requested offset. [TODO:15](/home/bart/Projects/lune/TODO.md:15) therefore cannot infer a 30× slowdown merely from a 100 KB source file; appending text after the relevant locations changes nothing. **Fix:** state O(scanned prefix) per lookup, summed across rendered locations. The underlying diagnosis is correct.

6. **[nit] Entry-lease overhead needs its A/B in Phase 2b.** [§8.1:1143](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:1143) assigns all overhead measurement to Phase 1, but leases arrive in [Phase 2b:68](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:68). **Fix:** specify Phase 1’s initial A/B and Phase 2b’s additional lease measurement.

The reported counts reproduced with the existing probe; profiling a baseline CPU build under `/tmp` confirmed the call-cost split and scan dominance. I found no C API lifetime or reentrancy violation in these workloads.

Bart, I kept all supplied rules in mind. No repository files or Git state changed; builds ran only under `/tmp`.

[Codex thread: 01a123dc-056c-7e63-b5ed-8bae4448f147]
