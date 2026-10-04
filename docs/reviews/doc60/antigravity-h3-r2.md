# Antigravity — doc 60 H3 implementation review, round 2 (2026-10-04)

# Code Review (Round 2): Doc 60 Phase H3

**Verdict:** **APPROVE**

The Round 1 fixes addressing the surplus-vararg register-capacity gap, the `ecx` argument coupling, the checklist claims, and §5.8's timing analysis are correct, complete, and sound.

---

## 1. Verification of Fixes

### A. Register-Capacity Check & Surplus Vararg Boundary Coverage
- **Location:** [`src/capi_hostcall_test.zig:1417–1490`](file:///home/bart/Projects/lune/src/capi_hostcall_test.zig#L1417-L1490)
- **Codex Round 1 Blocking Finding:** Dropping the surplus-vararg term (`add %r8, %rax` at [`src/asm/hostcall_x64.S:185`](file:///home/bart/Projects/lune/src/asm/hostcall_x64.S#L185)) passed all existing tests.
- **Verification:**
  - The new test `"the .S entry's register-capacity check is exact, with and without surplus varargs"` tests both:
    1. A plain callee (`p3`, `nargs = 3`, `surplus = false`).
    2. A surplus-vararg callee (`vonly`, `nargs = 3`, `surplus = true`, `proto.num_params = 0`).
  - For each callee, it tests both exact boundary conditions:
    1. `fits = true`: nested call requires exactly `need` slots, with `free == need` slots available $\implies$ admitted through the `.S` fast path (`chain == 1, slow == 0`).
    2. `fits = false`: nested call requires `need` slots, with `free == need - 1` slots available $\implies$ rejected pre-commit by `.S` and routed to H1 (`slow == 1, chain == 0`).

### B. Soundness of the New Test

#### 1. Assumption that free slots fall by exactly one per outer argument
- **Analysis:**
  - The test defines `function outer(...) capprobe() end` (`num_params = 0`, `is_vararg = true`).
  - An initial probe call with $f_0 = 1000 > \text{ARGS\_MAX}$ forces `outer` through H1 (`callClosure` $\to$ `bindAndPushClosure`).
  - Under `bindAndPushClosure` with surplus varargs:
    $$\text{arg\_base} = \text{stack\_top}_{\text{entry}} = 0$$
    $$\text{callee\_base} = \text{arg\_base} + \text{nargs} = N$$
    $$\text{stack\_top} = \text{callee\_base} + \text{proto.num\_registers} = N + \text{num\_registers}$$
  - The callback `capprobe` is an embedder host native function (`mh_register_fn`). Host natives execute inline via `cHostCall` without pushing a `CallFrame` or adjusting `stack_top`.
  - Inside `capFn`:
    $$\text{ctx.free} = \text{regCapacity} - \text{stack\_top} = \text{regCapacity} - \text{num\_registers} - N$$
  - Because $\text{regCapacity}$ and $\text{num\_registers}$ are invariant constants, every increment of $+1$ to the outer argument count $N$ decreases `ctx.free` by exactly $1$.
  - **Dynamic Assertion:** Line 1486 explicitly asserts `try testing.expectEqual(free, ctx.free)` before checking admission, turning any violation of this arithmetic invariant into an immediate test failure.

#### 2. Mutation Detection in `ReleaseFast`
- **Analysis & Verification (executed in an isolated `/tmp` shadow tree):**
  - **Mutation 1 (Codex mutation: `add %r8, %rax` replaced with `nop`):**
    - Under `ReleaseFast`, `builtin.is_test` is true for test targets, so `capi.hostcall_counts` remains active.
    - When `fits = false` for `vonly`, without `+ nargs` the `.S` pre-commit check miscalculates required slots as $\le \text{regCapacity}$, erroneously admitting the call (`ctx.admitted = true`).
    - At line 1487, `try testing.expectEqual(@as(?bool, fits), ctx.admitted)` immediately aborts with:
      ```text
      expected false, found true
      ```
    - Additionally, the resulting out-of-bounds register write corrupts the allocation canary, triggering a panic in `SafeAllocator` during VM cleanup.
  - **Mutation 2 (Strictness check: `ja` replaced with `jae` at line 188):**
    - When `fits = true`, an exact fit has `rax == regCapacity`. With `jae`, the entry erroneously rejects the call and falls back to H1 (`ctx.admitted = false`).
    - In both `Debug` and `ReleaseFast`, line 1487 fails with:
      ```text
      expected true, found false
      ```

---

## 2. Other Findings from Round 1

1. **`ecx` implicit 4th argument coupling ([`src/asm/hostcall_x64.S:353–364`](file:///home/bart/Projects/lune/src/asm/hostcall_x64.S#L353-L364)):**
   - Step 5 now has: `ecx is loaded with entry_depth here as the chain's fourth argument, below.`
   - Step 6 now has: `with entry_depth already in ecx (step 5).`
   - Explicitly documents the ABI register reuse without adding redundant instructions.
2. **Status checklist claim narrowed ([`docs/design/60-hand-written-machine-code.md:160–166`](file:///home/bart/Projects/lune/docs/design/60-hand-written-machine-code.md#L160-L166)):**
   - Correctly notes that the scenario differential tests verify behavioral equivalence, while the dedicated tests verify admission vs. fallback and exact capacity boundaries.
3. **§5.8 timing analysis ([`docs/design/60-hand-written-machine-code.md:1613–1618`](file:///home/bart/Projects/lune/docs/design/60-hand-written-machine-code.md#L1613-L1618)):**
   - Accurately rephrased: notes that instruction deltas do not determine cycle wins/losses, and describes `r0` and `overflow` cycle differences as uncertain within host noise.
4. **§10 Review Log Updated ([`docs/design/60-hand-written-machine-code.md:2087–2099`](file:///home/bart/Projects/lune/docs/design/60-hand-written-machine-code.md#L2087-L2099)):**
   - Table records all findings from Round 1 and their resolutions.

---

## 3. Suite & Acceptance Run Results

- **Unit Tests:** All 23 `hostcall` unit tests pass cleanly in both `Debug` and `ReleaseFast`.
- **H3 Build Acceptance (`tools/hostcall-acceptance.sh`):**
  - **`ReleaseFast`:** All checks passed (visibility, `-z text` PIE and shared links, non-executable stack, tail-call jump, 9 DWARF walks including 4 instruction-by-instruction single-step CFI walks across all 4 execution paths, 4 frame-pointer walks, negative controls).
  - **`Debug`:** All checks passed.

---

## 4. Findings

### Finding 1: [non-blocking / tracking] `next_call_seq` fallback remains untested
- **Location:** [`src/asm/hostcall_x64.S:152`](file:///home/bart/Projects/lune/src/asm/hostcall_x64.S#L152)
- **Problem:**
  `cmpq $-1, VM(VM_NEXT_CALL_SEQ)(%rdi); je SYM(mahina_hostcall_slow)` remains the only pre-commit check not exercised by the test suite.
- **Context:**
  Already documented on the Outstanding list ([`docs/design/60-hand-written-machine-code.md:182–186`](file:///home/bart/Projects/lune/docs/design/60-hand-written-machine-code.md#L182-L186)) as awaiting a subprocess test harness because exhaustion panics. No action required for H3.
