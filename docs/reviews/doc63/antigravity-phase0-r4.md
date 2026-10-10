# Antigravity — Phase 0 (benchmark and budget) review (round 4, 2026-10-11)

Verbatim reply. Dispositions in `phase0-dispositions.md`.

---

### Verdict: APPROVE

Round 4 review of [doc 63 §8.1](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md#L1086-L1223) and its companion dispositions in [docs/reviews/doc63/phase0-dispositions.md](file:///home/bart/Projects/lune/docs/reviews/doc63/phase0-dispositions.md#L33-L44) confirms that all Round 3 findings have been completely, accurately, and consistently resolved.

---

### Verification Summary

1. **`wide` Register Enumeration and Flushed Count**:
   - [§8.1](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md#L1141-L1146) correctly enumerates all 28 registers for `wide`:
     - Invariant / skipped (5): `n`, `h`, `t`, `limit`, `step`.
     - Flushed (23): locals `a…k`, loop counters `idx`, `i`, multi-assignment temporaries `r15…r21` (`b…k`), `r22` (new `k`), `r23` (`a + h(i)`), `r24` (copy of `a`, then `G1`), `r25` (call result), `r26` (callee `h`), and `r27` (argument `i`).
   - Register `r15` is correctly recognized as written (at pc 14 and pc 37), making the count **23 flushed / 5 skipped** (at 2–3 instrs/slot = **46–69** instructions).

2. **`wide` Component and Sparse Projections**:
   - Projection arithmetic in the §8.1 cost table matches the updated flush range:
     $$115 + 42 + 45 + 6 + (46\text{–}69) + 3 + 50 = \mathbf{307\text{–}330}$$
   - Liveness at call (pc 24) is verified at **12 of 23** flushed registers (`idx`, `i`, `r15…r21`, `r24`, `r26`, `r27`), giving the sparse projection of $115 + 42 + 45 + 6 + (24\text{–}36) + 3 + 50 = \mathbf{285\text{–}297}$.

3. **`cHostCall` Argument Conversion**:
   - [§8.1](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md#L1150-L1152) accurately notes that [`cHostCall`](file:///home/bart/Projects/lune/src/capi.zig#L1122) passes the [`Value`](file:///home/bart/Projects/lune/src/value.zig) buffer by pointer cast without per-argument conversion, and attributes extra-argument costs to the [`gatherScratch`](file:///home/bart/Projects/lune/src/interp.zig#L1597-L1601) lane assembly and host execution.

4. **`minl` Target Range**:
   - [§8.1](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md#L1167) accurately reports that `minl` (~242–250) meets the $\le 250$ target across its entire range with no margin at the top.

5. **Stale References Check**:
   - An exhaustive sweep of [§8.1](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md#L1086-L1223) confirms zero remaining occurrences of `22` (as flushed slot count), `r16` (as starting multi-assignment register), `44–66` (old flush cost), or `305–327` (old wide total).

---

### Findings

*No findings (0 defects identified).*
