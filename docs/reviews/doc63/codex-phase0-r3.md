# Codex — Phase 0 (benchmark and budget) review (round 3, 2026-10-11)

Verbatim reply. Dispositions in `phase0-dispositions.md`.

---

APPROVE WITH CHANGES

Round-2 finding #2 (`nest`) is resolved: I reproduced **33.8 M instructions off / 1.60 M on** at the fixed endpoint. Finding #1 remains partially resolved; #3’s gathering allowance is addressed, with a wording correction below.

1. **[should-fix] `wide`’s r15 is written, so the count remains 23 flushed / 5 skipped.** Compiling the [current shape:79](/home/bart/Projects/lune/bench/embed/tracecall_probe.c:79) produces `pc14: move r15,r4` and `pc37: move r15,r10`. Multiple-assignment temporaries start at **r15**, not r16. Consequently, [the own-slot invariant skip:760](/home/bart/Projects/lune/src/nativegen.zig:760) does not apply. **Fix:** correct [§8.1:1141](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:1141) and the disposition: r15–r21 hold `b…k`, r22 the new `k`, r23 `a+h(i)`, r24 the saved `a` then `G1`, and r25 the call result. Restore **46–69 flush instructions / 307–330 total**. The liveness counts are correct: `minl` has **4 of 8** live flushed slots; `wide` has **12 of 23**, specifically r11, r14, r15–r21, r24, r26 and r27. Their sparse projections remain **234–238 / 285–297**.

2. **[nit] `cHostCall` performs no per-argument conversion.** [§8.1:1150](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:1150) attributes conversion work to it, but [capi.zig:1122](/home/bart/Projects/lune/src/capi.zig:1122) passes the layout-identical `Value` buffer by pointer cast. Its validation loop checks **results**. **Fix:** describe the extra-argument allowance as gathering/copying and host-side work; remove the per-argument C-conversion claim.

3. **[nit] The `minl` range meets the target throughout.** [§8.1:1166](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:1166) says only its bottom meets the target, but **242–250 is entirely ≤250**. **Fix:** say it meets the projection with no margin at the upper end.

Bart, I kept all supplied rules in mind. I changed no repository files or Git state; scratch builds stayed under `/tmp`.

[Codex thread: 01a123dc-056c-7e63-b5ed-8bae4448f147]
