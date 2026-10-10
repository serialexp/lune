# Antigravity — Phase 0 (benchmark and budget) review (round 2, 2026-10-11)

Verbatim reply from the verdict on. Dispositions in
`phase0-dispositions.md`. Omitted before it: the CLI's echoed
tool-completion notices (a `/tmp` test run of the other agent's
`interp_bool_test` doc 57 P3 test failing, a bytecode dump of `minl` and
`wide`, and the `two nestq nest` reproduction run). The review quotes
the last of these below.

---

### Verdict: APPROVE

Every disposition from `phase0-dispositions.md` has been verified against the working tree and the uncommitted Phase 0 files ([`bench/embed/tracecall_probe.c`](file:///home/bart/Projects/lune/bench/embed/tracecall_probe.c), [`bench/embed/tracecall.py`](file:///home/bart/Projects/lune/bench/embed/tracecall.py), [`bench/embed/README.md`](file:///home/bart/Projects/lune/bench/embed/README.md), [`docs/design/63-trace-host-calls.md`](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md), and [`TODO.md`](file:///home/bart/Projects/lune/TODO.md)). The slot derivations, projection arithmetic, delayed-disturbance mechanics, and validation logic are sound.

---

### Detailed Verification

#### 1. §8.1 Slot Derivation for `minl` and `wide`
Verified against [`compileNumericFor`](file:///home/bart/Projects/lune/src/compiler.zig#L935) in [`src/compiler.zig`](file:///home/bart/Projects/lune/src/compiler.zig) and [`emitPreciseSnapshotFlush`](file:///home/bart/Projects/lune/src/nativegen.zig#L723) in [`src/nativegen.zig`](file:///home/bart/Projects/lune/src/nativegen.zig):

- **Compiler Layout**:
  - `minl`: Prototype allocates 12 registers (`num_registers = 12`). Layout: `r0 = n`, `r1 = h`, `r2 = s`, `r3 = idx`, `r4 = limit`, `r5 = step`, `r6 = i`, followed by evaluation temporaries (`r8 = s`, `r10 = h`, `r11 = i`).
  - `wide`: Prototype allocates 28 registers (`num_registers = 28`). Layout: `r0 = n`, `r1 = h`, `r2 = t`, `r3..r10 = a..k`, `r11 = idx`, `r12 = limit`, `r13 = step`, `r14 = i`, followed by seven temporaries for the multiple assignment `r16..r22 = b..k`, `r24 = a`, `r26 = h`, `r27 = i`.
- **Flush vs. Skip Behavior** ([`nativegen.zig:745-770`](file:///home/bart/Projects/lune/src/nativegen.zig#L745-L770)):
  - **Skipped**: Dead invariant slots (`k == .none`, `class == .invariant`) and invariant own-entry slots (`s.slot == ss.slot and s.class == .invariant`) are skipped because their slab locations are untouched and remain coherent. For `minl`, this skips 4 slots (`n, h, limit, step`); for `wide`, 5 slots (`n, h, t, limit, step`).
  - **Flushed**: Carried slots (`class == .carried`) are never skipped because their values evolve across back-edges while the slab becomes stale. Newly written slots (`i`, callee, argument, and intermediate assignment temporaries) must be flushed.
  - **Derivation Counts**:
    - `minl`: 5 slots flushed (`s`, `idx`, `i`, callee, arg), 4 skipped. Flushed cost: $5 \times (2\text{ to }3) = 10\text{–}15$ instructions.
    - `wide`: 19 slots flushed (8 carried locals, `idx`, `i`, 7 temporaries `b..k`, callee, arg), 5 skipped. Flushed cost: $19 \times (2\text{ to }3) = 38\text{–}57$ instructions.

#### 2. Projection Table Arithmetic
Verified across all component rows in [§8.1](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md#L1145-L1162):
- **`minl`**:
  - Low bound: $115 + 42 + 45 + 6 + 10 + 3 + 15 = \mathbf{236}$
  - High bound: $115 + 42 + 45 + 6 + 15 + 3 + 15 = \mathbf{241}$
  - Range: $\sim 236\text{–}241 \le 250$ (margin: 9–14 instrs).
- **`wide`**:
  - Low bound: $115 + 42 + 45 + 6 + 38 + 3 + 50 = \mathbf{299}$
  - High bound: $115 + 42 + 45 + 6 + 57 + 3 + 50 = \mathbf{318}$
  - Range: $\sim 299\text{–}318 \le 320$ (margin: 2–21 instrs).
- The arithmetic is exact, and §8.1 accurately emphasizes that `wide`'s margin is tight.

#### 3. Soundness of `nest` Isolation and Empirical Reproduction
- **Soundness**:
  - `nestq(N)` runs $N$ quiet 2-argument host calls ($at = 0$, $i \ne at$).
  - `nest(N)` runs $N$ 2-argument host calls where calls $1..999$ and $1001..N$ are calm ($at = 1000$, $i \ne at$). On iteration 1000, it executes `work(100000)` and validates that the sum equals `5000050000LL`.
  - Subtracting `count(nest, N) - count(nestq, N)` cancels VM startup, script compilation, ref establishment, and the steady-state loop iterations, isolating the single disturbing invocation.
  - Validation is enforced at two layers: `tracecall_probe.c` returns `MH_ERR_API` if `work` does not return `5000050000LL`, and `tracecall.py` validates that JIT-off and JIT-on checksums match identically (`MH_NOJIT` vs default).
- **Reproduction**:
  Executed in `/tmp/lune_review` via `python3 bench/embed/tracecall.py --iters 200000 two nestq nest`:
  ```text
  shape         jit off       jit on   (instructions per iteration, N = 200000)
  two            1372.4       1404.7
  nestq           758.8        790.1
  nest         33789394      2985331   (the one disturbing call, total)
  ```
  Matches the doc's published numbers (`two`: 1373 / 1405; `nestq`: 759 / 790; `nest`: 33.8 M / 3.0 M). Compilation under `cc -Wall -Wextra -Werror` produced zero warnings.

---

### Verification of Dispositions

| Finding | Status | Verification Summary |
|---|---|---|
| **Codex 1** (`two` warm-up) | **Resolved** | `host_late(i, on)` with `on = j > 10` executes 1,000 calm iterations (500 per inner loop), allowing both loops to pass the `hotloop` threshold before callbacks begin. |
| **Codex 2** (Budget arithmetic & flush derivation) | **Resolved** | §8.1 uses 42 instructions for 21 save/restore lanes, accounts for argument gathering in the shim (~45), derives the flushed/skipped subsets from `compileNumericFor`, and documents projection ranges (236–241 $\le$ 250; 299–318 $\le$ 320). |
| **Codex 3** (`nest` projection & checksum) | **Resolved** | `nest` disturbs at iteration 1000 after warm-up; `host_nest` checks `sum == 5000050000LL`; difference reported as total cost of the one call against `nestq`; framed as a workload projection. |
| **Codex 4 / Antigravity 2** (Iteration validation) | **Resolved** | `tracecall.py` enforces $N \ge 2000$ and $N \pmod{100} == 0$, preventing division-by-zero and ensuring `two` executes exactly $N$ host calls. Unknown shapes rejected up front. |
| **Codex 5** (TODO prefix scaling) | **Resolved** | [`TODO.md`](file:///home/bart/Projects/lune/TODO.md#L9-L16) correctly frames `lineFromOffset` as $O(\text{scanned prefix})$ summed across the error and backtrace frames, contextualizing the 30× factor for errors raised deep in 100 KB scripts. |
| **Codex 6** (Entry lease in Phase 2b) | **Resolved** | Checklist and §8/§8.1 assign epoch and suspension check A/Bs to Phase 1, and entry-lease A/B to Phase 2b. |
| **Antigravity 1** (Dirty working tree tests) | **Resolved** | Confirmed out of scope: `src/trace_chain.zig`, `src/trace.zig`, and `src/interp_bool_test.zig` belong to an in-flight branch (doc 57 P3) and are not part of the Phase 0 commit. |
| **Antigravity 3** (`nargs` checks in C probe) | **Resolved** | [`tracecall_probe.c`](file:///home/bart/Projects/lune/bench/embed/tracecall_probe.c) now guards `host_cb`, `host_tw`, `host_cbfail`, `host_late`, and `host_nest` with explicit `nargs` checks returning `MH_ERR_API`. |

---

### Numbered Findings

1. **Severity: Low (Informational / Budget Observation)** — *Expression accumulator temporaries live across the call*.
   - In [`compileNumericFor`](file:///home/bart/Projects/lune/src/compiler.zig#L935), evaluating `s = s + h(i)` allocates temporary `r8 = s` before emitting the call operands (`r10 = h`, `r11 = i`). Similarly, in `wide`, `r24 = a` is allocated before `r26 = h`, `r27 = i`.
   - At the bytecode `call` boundary, this accumulator temporary is live in the activation window. If the precise deopt snapshot restores this live temporary, flushed slots would become 6 for `minl` ($12\text{–}18$ instrs $\rightarrow$ total $238\text{–}244 \le 250$) and 20 for `wide` ($40\text{–}60$ instrs $\rightarrow$ total $301\text{–}321$).
   - *Impact*: In the worst case where every slot spills (3 instructions/slot), `wide` touches $321 \approx 320$. Because almost all of these slots reside in machine registers ($2$ instructions/slot in practice), it remains within budget. This confirms §8.1's note that Phase 3 should prioritize flush density if `wide` is close to the threshold.
