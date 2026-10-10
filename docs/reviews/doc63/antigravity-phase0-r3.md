# Antigravity — Phase 0 (benchmark and budget) review (round 3, 2026-10-11)

Verbatim reply from the verdict on. Dispositions in
`phase0-dispositions.md`. Omitted before it: four lines of the CLI's
progress notices ("I have launched … and will wait for it to finish").

---

### Verdict: APPROVE WITH CHANGES

The Phase 0 benchmark and budget revision in [§8.1](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md#L1100-L1221) is thoroughly constructed and empirically verified. The isolation of `nest` by ending both runs at iteration 1000 resolves the post-callback distortion cleanly, argument scaling accurately reflects [`gatherScratch`](file:///home/bart/Projects/lune/src/interp.zig#L1597-L1601), and the Phase 3 optimization options are well-characterized.

One factual correction in the `wide` slot derivation is required before final sign-off: **`r15` is not unused or skipped**. It is written at pc 14 (`move r15 4`, holding `b`), remains live across the call at pc 24, and is read at pc 29 (`move r3 15`). The true count is **23 flushed / 5 skipped**, which adjusts the projection to **~307–330** (matching Codex's round 2 calculation).

---

### Detailed Verification

#### 1. Slot and Liveness Counts Against Bytecode and Flush Emitter
Compiling and disassembling [`minl`](file:///home/bart/Projects/lune/bench/embed/tracecall_probe.c#L56) and [`wide`](file:///home/bart/Projects/lune/bench/embed/tracecall_probe.c#L78) via [`compiler.zig`](file:///home/bart/Projects/lune/src/compiler.zig) and checking against [`emitPreciseSnapshotFlush`](file:///home/bart/Projects/lune/src/nativegen.zig#L723-L785) and [`bc_liveness.zig`](file:///home/bart/Projects/lune/src/bc_liveness.zig):

- **`minl`** (`regs = 12`, call at pc 9):
  ```text
  pc  6: move r8, 2          (copy of s)
  pc  7: move r10, 1         (callee h)
  pc  8: move r11, 6         (arg i)
  pc  9: call r10, 1, 1      live_in = [r1 r3 r4 r5 r8 r10 r11]
  pc 10: move r9, 10         (result)
  pc 11: add  r7, 8, 9       (sum)
  pc 12: move r2, 7          (store to s)
  pc 13: for_loop r3, -8
  ```
  - **Full Window**: 12 registers (`r0..r11`).
  - **Skipped**: 4 invariant slots never written in the body (`r0 = n`, `r1 = h`, `r4 = limit`, `r5 = step`).
  - **Flushed**: 8 slots (`r2 = s`, `r3 = idx`, `r6 = i`, `r7`, `r8`, `r9`, `r10`, `r11`).
  - **Liveness at call (pc 9)**: 4 live flushed slots (`r3 = idx`, `r8`, `r10`, `r11`) out of 8 flushed.
  - *Result*: **100% verified and exact**.

- **`wide`** (`regs = 28`, call at pc 24):
  ```text
  pc 14: move r15, 4         (b into first multi-assign temporary)
  pc 15..20: move r16..r21   (c..k into temporaries)
  pc 21: move r24, 3         (copy of a)
  pc 22: move r26, 1         (callee h)
  pc 23: move r27, 14        (arg i)
  pc 24: call r26, 1, 1      live_in = [r1 r2 r11 r12 r13 r14 r15 r16 r17 r18 r19 r20 r21 r24 r26 r27]
  pc 25: move r25, 26        (result)
  pc 26: add  r23, 24, 25    (a + h(i))
  pc 27: get_global r24, 1   (G1)
  pc 28: add  r22, 23, 24    (8th temporary: a + h(i) + G1)
  pc 29..36: move r3..r10    (assign temporaries r15..r22 back to locals a..k)
  pc 37: move r15, 10        (reuse r15 for k)
  ```
  - **Full Window**: 28 registers (`r0..r27`).
  - **Body Invariants**: Only 5 registers are never written: `r0 = n`, `r1 = h`, `r2 = t`, `r12 = limit`, `r13 = step`.
  - **Register `r15`**: Written at pc 14 (`move r15 4`). Multi-assignment temporaries `b..k` occupy 7 registers: `r15..r21`. The 8th temporary is `r22`. There is no unused gap.
  - **Flushed**: 23 slots ($28 - 5 = 23$), not 22.
  - **Liveness at call (pc 24)**: Of the 16 registers in `live_in`, 4 are invariant (`r1`, `r2`, `r12`, `r13`). Exactly 12 are flushed (`r11`, `r14`, `r15`, `r16`, `r17`, `r18`, `r19`, `r20`, `r21`, `r24`, `r26`, `r27`).
  - *Result*: Numerator is exactly 12, but denominator is **12 of 23**, not 12 of 22.

---

#### 2. Projection Arithmetic Verification

- **`minl` Table Addition**:
  - $115 + 42 + 45 + 6 + 16 + 3 + 15 = \mathbf{242}$
  - $115 + 42 + 45 + 6 + 24 + 3 + 15 = \mathbf{250}$
  - Exact: **~242–250 $\le$ 250**.
  - Live-only (4 flushed slots $\times$ 2–3 instrs = 8–12): $115 + 42 + 45 + 6 + (8\text{–}12) + 3 + 15 = \mathbf{234\text{–}238}$. Exact.

- **`wide` Table Addition**:
  - Under stated table flush 44–66 (22 slots): $115 + 42 + 45 + 6 + (44\text{–}66) + 3 + 50 = \mathbf{305\text{–}327}$. Addition is internally consistent.
  - Under corrected flush 46–69 (23 slots): $115 + 42 + 45 + 6 + (46\text{–}69) + 3 + 50 = \mathbf{307\text{–}330}$.
  - Live-only (12 flushed slots $\times$ 2–3 instrs = 24–36): $115 + 42 + 45 + 6 + (24\text{–}36) + 3 + 50 = \mathbf{285\text{–}297}$. Exact regardless of whether the unoptimized baseline is 22 or 23.

---

#### 3. `nest` Measurement Soundness and Empirical Reproduction

Executed in a clean `/tmp` build via [`tracecall.py`](file:///home/bart/Projects/lune/bench/embed/tracecall.py):
```text
shape         jit off       jit on   (instructions per iteration, N = 200000)
minl            657.0        688.3
wide           1544.6       1576.1
nestq           759.0        790.3
nest         33800884      1602253   (the one disturbing call, total)
```
- **Soundness**: Ending both `nest(1000)` and `nestq(1000)` immediately after call 1000 eliminates all post-callback outer-loop execution. Subtracting `count(nest, 1000) - count(nestq, 1000)` exactly isolates the 100,000-iteration nested loop.
- **Delta**: $33,800,884 - 1,602,253 = 32,198,631$ ($\sim 32.2\text{ M}$, or $\sim 320$ per nested iteration).
- **Post-callback effect**: The residual cost at $N = 1,000,000$ and its run-to-run jitter are properly cataloged in [`TODO.md`](file:///home/bart/Projects/lune/TODO.md#L5-L24) without distorting the benchmark table.

---

#### 4. Disposition Status of Round 2 Findings

| Round 2 Finding | Status | Details |
|---|---|---|
| **Codex r2-1 / AG r2-1** (Full-window precise snapshot) | **Partially Resolved** | Contract cited, dead temporaries included, and `minl` completely accurate. `wide` requires updating from 22/6 to 23/5 due to `r15` being written. |
| **Codex r2-2** (`nest` boundary) | **Resolved** | Both runs end at `NEST_AT = 1000`. Numbers updated in [§8.1](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md#L1109) and [`tracecall.py`](file:///home/bart/Projects/lune/bench/embed/tracecall.py#L110-L112). Post-callback divergence captured in [`TODO.md`](file:///home/bart/Projects/lune/TODO.md#L5-L24). |
| **Codex r2-3** (Argument gathering & scaling) | **Resolved** | [`gatherScratch`](file:///home/bart/Projects/lune/src/interp.zig#L1597-L1601) SoA reconstruction and C conversion detailed; 10–25 instructions provisioned per extra argument; tier-0 slope framed as dispatch. |

---

### Numbered Findings

1. **Severity: Medium (Should-fix / Accuracy)** — *Register `r15` in `wide` is written and live, not unused/skipped*.
   - **Location**: [`docs/design/63-trace-host-calls.md:1141-1146, 1160-1163, 1179-1180`](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md#L1141-L1146), and [`docs/reviews/doc63/phase0-dispositions.md:29`](file:///home/bart/Projects/lune/docs/reviews/doc63/phase0-dispositions.md#L29).
   - **Issue**: §8.1 states:
     > *"wide, 28 registers: `n h t a…k idx limit step i`, an unused `r15`, then `r16…r22` (the multiple assignment's `b…k`)... Skipped: `n`, `h`, `t`, `limit`, `step`, `r15`. Flushed: the other 22. About 44–66 instructions."*
     
     In bytecode, `r15` is explicitly written at pc 14 (`move r15 4`) as the first target of `compileValuesInto` (evaluating `b`), is live across the call at pc 24 (`call r26 1 1`), is read at pc 29 (`move r3 15` assigning `a`), and written again at pc 37 (`move r15 10`).
   - **Fix**:
     1. In §8.1 bullet 2, update `wide`'s enumeration: `r15…r21` are the multi-assignment temporaries `b…k`, and `r22` is the result of `a + h(i) + G1`.
     2. Update counts to **23 flushed / 5 skipped** (`n, h, t, limit, step`).
     3. Update flush cost to **46–69 instructions** and projection to **~307–330** (table and text).
     4. In the Phase 3 live-slot option, update the ratio to **12 of 23** (projection ~285–297 remains unchanged).
