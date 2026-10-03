# Doc 60 H1 implementation review — antigravity

Reviewer: antigravity (`mcp__antigravity__delegate`, tools allowed, read-only
brief), 2026-10-03. Input: the uncommitted H1 tree, `/tmp/h1.diff`, doc 60
with §5.5. Disposition of each finding: doc 60 §10, "H1 review".

---

VERDICT: APPROVE

The implementation of Phase H1 in the working tree is correct, robust, and sound. Differential tests comparing H1 against the verbatim pre-H1 path (`capi.hostcallReference`) pass across all three execution tiers (`.off`, `.tier1`, `.native`), mutation tests for `fast_block` cover all coexistence and lifecycle transitions, and the entire mahina test suite passes (`zig build test` in Debug: all tests green, `capi smoke: OK`, and JIT dependency boundaries verified). The measured performance improvements in §5.5 were independently reproduced and verified down to the exact instruction.

### Detailed Review

#### 1. Correctness and Soundness
- **Call-path equivalence**: For closure callees, `callClosure` (`pushHostCall` + `runPushedFrame`) preserves the exact behavior of `runProtected` + `callValue`:
  - **Pre-execution validation & error ordering**: Parameter validation (`vm`, `nresults`), `checkFatal`, argument decoding, and the idle park clear + re-park occur in the exact same sequence before `callClosure` is entered.
  - **Limits & Overflow**: Re-entry limit (`native_reentry_depth >= max_native_reentry`), call depth limit (`self.depth >= max_call_depth`), and register capacity (`cb + cp.num_registers > regCapacity()`) are checked prior to mutating frame or register state, returning `Error.StackOverflow` which maps to `guestFault` and `.err_runtime`.
  - **Fault Handling & Unwinding**: On error in `execWithEntry`, `runPushedFrame` decrements `native_reentry_depth` via `defer`, leaving faulting frames live for `renderFault` before `guestFault` restores `entry_depth`, `entry_top`, closes upvalues from `entry_top`, drops region activations, and clears `final_cut`. Non-catchable errors (`OutOfMemory`) mark `box.fatal = true` and return `.err_oom`.
  - **OOM during Result Parking**: Results are copied to the host buffer before `vm.stack_top = entry_top`, and then parked. If `park()` fails on result overflow, `callClosure` leaves `*nresults = 0`, restores `stack_top`, leaves `box.fatal = false`, and returns `.err_oom` — identical to `runProtected`.
  - **Parking Contract & GC Rooting**: When binding non-vararg closures, parameters land directly in the callee window. For vararg closures with surplus arguments, `bindAndPushClosure` places arguments at `arg_base` and copies fixed parameters to the callee window above it, raising `stack_top` over the whole span to root surplus varargs during execution.
  - **`final_cut`**: Explicitly set to `null` on entry in `pushHostCall` and `runPushedFrame`, ensuring stale top-level cuts from prior `eval`s are not retained.
  - **Non-closure callees**: Natives, non-callable values, and `__call` metatable redirects continue through `runProtected` → `callValue` unchanged.
- **`fast_block` drift prevention**:
  - Global analysis of all writes across `src/` confirms that every update to `pending_*` fields, `suspend_ctl`, `record_safepoint_lines`, and `rec.active` goes strictly through the setters (`setPending*`, `setSuspendCtl`, `setRecordSafepointLines`) or the recording funnels (`startRecording`, `abort`, `closeTrace`, `commit`).
  - `TraceState.init` initializes `fast_block = 0`, matching the zero state of all nine fields.
  - Keyframe restore (`initBare`) starts with an empty heap and zero-state `TraceState`, never mutating source fields behind setters.
  - `clearCache` resets only the trace-owned fields via their respective setters, keeping the VM bits intact.
  - Debug assertions in `runFastPath`, `execWithEntry`, and `hostcallSlow` continuously assert `fast_block == fastBlockReference()`.

#### 2. Soundness of Deviations in §5.5
- **`runPushedFrame` reusing `execWithEntry`**: Sound. `execWithEntry` already sets up `ExecState`, sets region context, resolves cached code images, and manages `.finished`, `.switch_mode`, and errdefers (`clearPendingExitAnchor`, `abortRaised`). Reusing it avoids ~40 lines of duplicated execution machinery and eliminates potential divergence.
- **Inlining `pushHostCall`, `runPushedFrame`, and `execWithEntry`**: Sound. Out-of-line functions returning `Error!T` force a 16-byte stack write and load that stalls store-forwarding on every host crossing. Inlining these small wrappers flattens the entry path while leaving the main execution loop (`chainEntry(.fast)`) outlined via `@call(.never_inline, ...)`.
- **Flat setters on `TraceState`**: Sound. Avoids the complexity and overhead of `@fieldParentPtr` required by a nested struct while achieving the same safety guarantees.
- **Whole-word volatile skip-if-unchanged store (`setFastBit`)**: Sound. A 16-bit volatile store prevents LLVM from narrowing updates to byte-wide `orb`/`andb` instructions on x86-64, ensuring subsequent 16-bit loads in `runFastPath` can store-forward. Skipping writes when `nw == w` eliminates redundant memory stores on the hot clear paths.
- **No `Vm.recomputeFastBlock()`**: Sound. Neither `initBare` nor keyframe restore ever mutates the source fields behind a setter; `fast_block` is initialized to 0 and maintained incrementally.

#### 3. Test Adequacy against §6.1
- The 15 scenario tests in `src/capi_hostcall_test.zig` cover argument variations (0..9, fewer and more than parameters), varargs, result truncation, null buffers, fallback callees, guest runtime errors, fatal errors, final_cut invalidation, tier-up, aborted recordings, parking under GC stress, input/result park overflow, helper OOM, re-entrant calls, and register capacity limits.
- The 4 mutation tests in `src/interp_fastblock_test.zig` verify each bit individually, audit coexistences, displacement, stale-parent drops, and `clearCache` survival.
- Differential snapshots normalize heap addresses into deterministic IDs and verify results, registers, sequences, effect logs, upvalues, keyframes, traces, and parked root lists after every call.

#### 4. Verification of Measurements in §5.5
- We compiled `bench/embed/hostcall_probe.c` against `bench/embed/.cache/mahina-prefix/lib/libmahina.a` and benchmarked via `perf stat` with `MH_NOJIT=1`:
  - `a0` (0 args, 1 result): **403.00 instructions/call** (exactly matches table: 443 → 403, Δ −40).
  - `a1` (1 arg, 1 result): **452.00 instructions/call** (exactly matches table: 491 → 452, Δ −39).
- The claims in §5.5 are accurate and substantiated.

#### 5. Checklist and Documentation Accuracy
- The checklist in doc 60 accurately tracks completed versus outstanding items, with only minor wording adjustments noted below.

### Numbered Findings

#### Finding 1 (Minor): Scenario test count discrepancy in doc 60 (15 vs 16 tests)
- **Reference**: docs/design/60-hand-written-machine-code.md:61-63 and :882-907
- **Details**: The checklist and §5.5 state that `capi_hostcall_test.zig` has "16 scenario tests". However, inspecting src/capi_hostcall_test.zig reveals exactly 15 `test` blocks. The 16th test outlined in §6.1 (`next_call_seq` exhaustion) requires a subprocess harness to catch `@panic` and is tracked as outstanding in the checklist (line 71).
- **Suggested Fix**: Update doc 60 §5.5 and the checklist item to state "15 scenario tests" (noting that the 16th test is deferred to the subprocess harness).

#### Finding 2 (Minor): `suspend_ctl` omitted from fast-word differential scenario test
- **Reference**: src/capi_hostcall_test.zig:561-596
- **Details**: In `test "hostcall diff: fast word nonzero at entry..."`, the `Setup` enum tests 8 conditions: `exit_anchor`, `replay_anchor`, `call_anchor`, `ret_anchor`, `ret_cont_arm`, `call_head_arm`, `recording`, and `safepoint_lines`. The 9th condition, `suspend_ctl` (`FastBit.vm_suspend`), is omitted. This omission is technically sound because host calls with an active suspend trigger are illegal preconditions that assert `self.suspend_ctl == null` in both `callValue` and `runPushedFrame` (and `interp_fastblock_test.zig` already tests `vm_suspend` across all mutations).
- **Suggested Fix**: Add a brief comment in `src/capi_hostcall_test.zig` inside that test explaining why `suspend_ctl` is excluded from the `Setup` enum (i.e. host calls assert `suspend_ctl == null` on entry).

#### Finding 3 (Nit): Unused constant `FastBit.trace_owned` in `src/trace.zig`
- **Reference**: src/trace.zig:3028
- **Details**: `pub const trace_owned: u16 = (1 << 7) - 1;` is defined in `FastBit`, but no caller or test references it because `clearCache` selectively clears each trace bit via individual setters.
- **Suggested Fix**: Keep as documentation of the trace-owned bitmask or add a clarifying comment explaining its informational role.

#### Finding 4 (Nit): Clarify ReleaseFast testing guidance vs `capi-smoke`
- **Reference**: docs/design/60-hand-written-machine-code.md:61-63 and TODO.md:5-11
- **Details**: Doc 60 states that tests are run in "Debug and ReleaseFast". However, running `zig build test -Doptimize=ReleaseFast` (even with `-Dtest-filter=...`) invokes the `capi-smoke` run step added to `test_step` in `build.zig:152`, which hangs due to `-DNDEBUG`.
- **Suggested Fix**: Note in the doc that running the differential test binary in ReleaseFast requires invoking the test artifact directly or temporarily commenting out `test_step.dependOn(&run_smoke.step)` until `tests/capi_smoke.c` is updated to avoid `assert()`.
