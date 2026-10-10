# Antigravity — Phase 0 (benchmark and budget) review (round 1, 2026-10-11)

Verbatim reply. Dispositions in `phase0-dispositions.md`.

---

I have launched the test build and benchmark run in `/tmp/lune_test` to verify reproduction of the measurements. I will wait for it to complete.
I have launched `zig build test` in `/tmp/lune_test` and will wait for it to finish.
I have launched `zig build test -Dtest-filter="doc 57 P3"` in `/tmp/lune_test` and will wait for it to finish.
### Verdict: APPROVE WITH CHANGES

The Doc 63 Phase 0 work (`bench/embed/tracecall_probe.c`, `bench/embed/tracecall.py`, `bench/embed/README.md`, `docs/design/63-trace-host-calls.md` §8.1, and `TODO.md`) is high quality, mathematically rigorous, and empirically validated. 

However, the working tree currently contains dirty, unrelated changes in [`src/trace_chain.zig`](file:///home/bart/Projects/lune/src/trace_chain.zig#L257), [`src/trace.zig`](file:///home/bart/Projects/lune/src/trace.zig#L340), and [`src/interp_bool_test.zig`](file:///home/bart/Projects/lune/src/interp_bool_test.zig#L292) where `if (false and ...)` breaks `zig build test` (violating Rule Z-3). In addition, there are minor robustness adjustments for `tracecall.py`.

---

### Verification Details

#### 1. Coverage of §8 shapes & C embedding contract ([`include/mahina.h`](file:///home/bart/Projects/lune/include/mahina.h))
- **Shape coverage**: Every scenario required by [§8](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md#L1039-L1080) is represented:
  - Minimal loop: `min` (global), `minl` (local), `gid` (guest function control).
  - Variations: argument counts (`a0`, `a4`, `a8`), carried window sizes (`w4`, `w8`, `w16`), global seed reads (`s1`, `s4`).
  - Wide window: `wide` (8 carried locals, seeded global `G1`, table write `t[i % 16 + 1] = k`).
  - Disturbing hosts: callbacks (`cb`), table mutations (`tw`), multi-anchor contention (`two`), and runtime errors caught by `pcall` (`fail`).
  - Suspended hot nested loop: `nest`.
- **C embedding API compliance**:
  - **Lifetime & Roots**: Long-lived guest values (`gcb`, `gfail`, `work`, table `T`) are pinned via [`mh_ref_create`](file:///home/bart/Projects/lune/include/mahina.h#L176) before execution and retrieved via [`mh_ref_get`](file:///home/bart/Projects/lune/include/mahina.h#L177). Argument access and result buffers conform to the lifetime and non-aliasing rules.
  - **Reentrancy**: Re-entering the VM via [`mh_call`](file:///home/bart/Projects/lune/include/mahina.h#L149) inside `host_cb`, `host_nest`, and `host_cbfail` is safe and leaves caller `results` uncorrupted.
  - **Error handling**: `host_cbfail` stages errors using [`mh_error_set(vm, MH_STR("cbfail"))`](file:///home/bart/Projects/lune/include/mahina.h#L201) and returns `MH_ERR_RUNTIME`, properly exercising [`cHostCall`](file:///home/bart/Projects/lune/src/capi.zig#L1128) and `pcall`.

#### 2. Soundness of `(count(N) - count(0)) / N`
- **Baseline cancellation**: Calling `shape(0)` executes VM startup, chunk compilation, global registration, and ref creation, while the guest `for` loop body executes 0 times. Subtraction cleanly removes non-loop fixed costs.
- **Shape `two`**: Outer loop `for j = 1, n // 100` executes two inner loops of 50 iterations each. When $N$ is a multiple of 100 ($10^6$ default or $2\times 10^5$ example), total inner iterations and host calls equal $(N // 100) \times 100 = N$. Dividing by $N$ produces the true cost per inner iteration and host call.
- **Shape `nest` split**:
  - `one - base` isolates the first-call overhead (running `work(100000)` inside the callback + 1 outer loop iteration).
  - `(full - one) / (n - 1)` isolates the subsequent $N - 1$ steady-state iterations with mathematical precision.

#### 3. §8.1 Conclusions & Budget Arithmetic
- **Arithmetic verification**:
  - **`minl` budget (230 $\le$ 250)**: Funnel (115) + callout save/restore ($\le$ 40) + shim (~40) + epoch/budget checks (~6) + window flush (~12) + tag check/loop (~15) = 228 $\approx$ 230 $\le$ 250.
  - **`wide` budget (290 $\le$ 320)**: $230 + 20$ (extra 10 flush stores) $+ 15$ (global read) $+ 25$ (table store) = 290 $\le$ 320.
  - **Scaling slopes**:
    - Arguments: $969 - 809 = 160$ across 4 args $\rightarrow$ 40 instrs/arg.
    - Carried locals: $1080 - 856 = 224$ across 4 locals $\rightarrow$ 56 instrs/local; $1528 - 1080 = 448$ across 8 locals $\rightarrow$ 56 instrs/local.
    - Seed reads: $1132 - 799 = 333$ across 3 globals $\rightarrow$ 111 $\approx$ 110 instrs/global.
  - **Threshold 1 cost (Q4)**: $(33.8\text{M} - 1.6\text{M}) / 100{,}000 = 322 \approx 320$ extra instrs per callback-loop iteration.
- **Empirical reproduction** (built in `/tmp/lune_test` against ReleaseFast):
  - `min`: 690.0 / 721.3 (doc: 690 / 721)
  - `minl`: 657.0 / 688.3 (doc: 657 / 688)
  - `gid`: 875.0 / 15.4 (doc: 875 / 14)
  - `wide`: 1544.6 / 1576.1 (doc: 1540 / 1571)
  - `cb`: 1252.1 / 1283.4 (doc: 1252 / 1283)
  - `two`: 1294.2 / 1326.3 (doc: 1294 / 1326)
  - `fail`: 28789.1 / 28820.4 (doc: 28,789 / 28,820)
  - `nest` steady: 673.0 / 706.9 (doc: 673 / 706)
  - `nest` first: 33,801,939 / 1,602,836 (doc: 33.8M / 1.6M)
  - Checksum parity passed on all runs.

#### 4. TODO Diagnosis on `compiler.lineFromOffset`
- [`lineFromOffset`](file:///home/bart/Projects/lune/src/compiler.zig#L186) counts newlines with a linear scan from byte 0 to `offset`.
- It is invoked during error paths:
  1. [`callSiteAt`](file:///home/bart/Projects/lune/src/interp.zig#L1838) via [`raiseLocatedError`](file:///home/bart/Projects/lune/src/interp.zig#L1941)
  2. [`describeFault`](file:///home/bart/Projects/lune/src/interp.zig#L2015) for the leaf instruction
  3. [`backtraceFrames`](file:///home/bart/Projects/lune/src/interp.zig#L2084) for every frame on the call stack
- Profiling `tracecall_probe fail 10000` via `perf record` confirmed:
  - `interp.Vm.raiseLocatedError`: **41.34%**
  - `interp.Vm.backtraceFrames`: **39.62%**
  - Combined: **80.96%** of all user instructions in `fail` are consumed by this scan. The diagnosis in [`TODO.md`](file:///home/bart/Projects/lune/TODO.md#L5-L19) is completely accurate.

---

### Numbered Findings

1. **Severity: High (Test Failure / Rule Z-3)** — Uncommitted changes in [`src/trace_chain.zig`](file:///home/bart/Projects/lune/src/trace_chain.zig#L257), [`src/trace.zig`](file:///home/bart/Projects/lune/src/trace.zig#L340), and [`src/interp_bool_test.zig`](file:///home/bart/Projects/lune/src/interp_bool_test.zig#L292).
   - `src/trace_chain.zig:257` has an active `if (false and materialization == .native_numeric_for_done ...)`.
   - Running `zig build test` currently fails on `interp_bool_test.test.doc 57 P3: a loop-test copy's exit in link mode resumes the owed trip, not the post-loop pc` (`expected: -80, found: 412`).
   - Removing `false and ` makes the test pass. These 3 files belong to doc 57 P3 rather than Doc 63 Phase 0. They must either be completed or excluded/stashed before committing Doc 63 Phase 0 so the tree stays green.

2. **Severity: Low (Bench Robustness)** — `tracecall.py` with `two` assumes `iters % 100 == 0`.
   - In [`tracecall_probe.c`](file:///home/bart/Projects/lune/bench/embed/tracecall_probe.c#L76), `two` loops `for j = 1, n // 100 do`. If a user supplies `--iters 50` or another value not divisible by 100, the formula `(full - base) / n` in [`tracecall.py`](file:///home/bart/Projects/lune/bench/embed/tracecall.py#L102) divides by $n$ rather than $(n // 100) \times 100$.
   - *Recommendation*: In `tracecall.py`, either assert `args.iters % 100 == 0` when `two` is in `args.shapes` or use `actual_iters = (n // 100) * 100 if shape == "two" else n`.

3. **Severity: Low (C Hygiene)** — `host_cb`, `host_tw`, and `host_nest` omit explicit `nargs > 0` defensive checks.
   - While guaranteed safe by the static probe script, checking `if (nargs < 1) return MH_ERR_API;` in [`tracecall_probe.c`](file:///home/bart/Projects/lune/bench/embed/tracecall_probe.c#L114) would match the defensive convention of `host_id` and `host_last`.
