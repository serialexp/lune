# Doc 60 §5.6 + H1.5 review — codex

Reviewer: codex (`mcp__codex__delegate`, read-only brief), 2026-10-04.
Input: `/tmp/h15.diff`. Disposition: doc 60 §10.

---

VERDICT: CHANGES REQUESTED

1. **Minor — docs/design/60-hand-written-machine-code.md:1124: Incorrect loop-cost attribution.** The saved H1 binary's nil-fill (`0x1f7cbb–0x1f7cf9`) is a scalar loop with lane/count reloads, without the claimed four-way-unroll remainder setup. Bind and copy-out have that setup. **Fix:** correct the attribution and recalculate the associated ~25–30 instruction estimate.

2. **Minor — docs/design/60-hand-written-machine-code.md:1199: Conclusion exceeds the evidence.** Measuring A/B/C establishes their spill/setup trade-offs; it does not establish that further Zig reshaping can only redistribute spills. **Fix:** limit the conclusion to the measured variants and label the broader claim as a hypothesis.

No supported-path soundness issue found in A/B/C: register windows remain stable, parking cannot collect, OOM restores `stack_top` and preserves park order, and every production source write satisfies the anchor invariant.

Saved callgrind data reproduces 461 instructions/crossing and 341 `mh_call` sites. The authorized filtered gate and `just test` passed from a `/tmp` copy.

No repo files were modified.
