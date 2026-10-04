# Antigravity — doc 60 H3 implementation review (2026-10-04)

# Code Review: Doc 60 Phase H3 (Linux x86-64 Hand-Written Host-Call Entry)

**Verdict:** **APPROVE**

The H3 implementation in [`src/asm/hostcall_x64.S`](file:///home/bart/Projects/lune/src/asm/hostcall_x64.S), [`src/capi.zig`](file:///home/bart/Projects/lune/src/capi.zig), and the associated tests and tools is sound, rigorous, and faithful to the §4.3 ordered state contract and the reference H1 behavior. All 1,624 unit tests pass, and the hostcall acceptance suite (`tools/hostcall-acceptance.sh`) passes in both `ReleaseFast` and `Debug` (including DWARF CFI unwinding, frame-pointer unwinding, negative controls, and single-step DWARF unwinding across every instruction of the entry).

---

## Detailed Evaluation by Review Topic

### 1. Soundness Against §4.3 Contract and H1 Reference
- **Off-by-ones & capacity checks:**
  - Register window: `add VM(VM_STACK_TOP), %rax` vs `VM(VM_PAYLOADS + SLICE_LEN)` uses `ja` (unsigned strictly greater than capacity), matching Zig's `cb + nreg > self.regCapacity()`.
  - Park capacity: `count` is computed as `1 (callee) + num_heap_args`. In idle state (`r10d == 0`), `cmp $PARKED_INLINE_CAP, %eax; ja slow` checks `count > 6`. In non-idle state, `add parked_inline_len, %eax` checks `parked_inline_len + count > 6`. Both match `park` capacity and idle clearing semantics.
  - Varargs: `CF_BASE = entry_top + nargs`, `CF_VARARGS_BASE = entry_top + num_params`, `CF_VARARGS_COUNT = nargs - num_params`. For non-varargs with surplus, `base = entry_top`, parameter registers `[0..min(np, nargs)]` are bound, and surplus arguments `[min(np, nargs)..nargs]` are parked via `PARK_ARG` without register allocation.
  - Results: `produced = min(count, max_results)` via `cmova`, exactly matching `callClosure` (`@min(@as(usize, fr.count), results.len)`). When `max_results == 0` or `results == null`, `produced` is 0 and output buffers are untouched.
- **The idle flag in `r10`:**
  - Computed pre-commit at [L193–194](file:///home/bart/Projects/lune/src/asm/hostcall_x64.S#L193-L194) (`movzwl native_reentry_depth, %r10d; or depth, %r10d`).
  - No instruction in the prologue touches `%r10`.
  - At [L224–228](file:///home/bart/Projects/lune/src/asm/hostcall_x64.S#L224-L228), `test %r10d, %r10d; jnz 6f` zeroes both `parked_inline_len` and `parked_results.items.len` iff idle, matching `parkClearIfIdle` and Q12(a).
- **Nil-fill:**
  - Tag zeroing uses `mov %rax, (%rdi)` (8 tags at a time, since `TAG_NIL == 0`).
  - Payload zeroing uses 4x `movups %xmm0, ...(%rsi)` (64 bytes = 8 payloads). Unaligned vector stores are safe for 8-byte aligned payload pointers.
  - Remainder (0..7) is handled by the scalar loop (`movb $TAG_NIL, (%rdi); movq $0, (%rsi)`). The zero-register edge case (`rdx == 0`) branches directly to `23f` without writing.
- **GC rooting & lifetimes:**
  - Callee and heap arguments are parked in `parked_inline` before the frame push and before `mahina_hostcall_chain` can trigger any allocation or safepoint.
  - Results are copied out and parked inline; on inline park saturation, the entry switches to `.Lpark_overflow` and delegates remaining result parking to `mahina_hostcall_park_rest`, which appends to `parked_results`.
  - On error inside guest code, `guestFault` runs inside `mahina_hostcall_chain` while the faulting frame stack is still live.
- **`ChainResult` decoding:**
  - Returned in `rax` as `extern struct { status: u32, frame_result: u32 }`.
  - Shift `shr $48, %rcx` extracts `FrameResult.count` (bits 16..31 of upper half); `shr $32, %rax` + `movzwl %ax, %eax` extracts `FrameResult.reg` (bits 0..15 of upper half). Validated against `@bitOffsetOf` in [`src/asm/offsets_x64.zig`](file:///home/bart/Projects/lune/src/asm/offsets_x64.zig#L170-L171).
- **Calling convention, callee-saved registers, stack alignment & CFI:**
  - Prologue pushes `%rbp, %rbx, %r12, %r13, %r14` (5 pushes = 40 bytes + 8 bytes return address = 48 bytes = 0 mod 16 alignment).
  - All calls (`mahina_hostcall_chain`, `mahina_hostcall_park_rest`) occur with 16-byte stack alignment.
  - CFI directives accurately track CFA and register locations throughout, verified instruction-by-instruction by `ExpectWalkSteps`.

### 2. Regression Coverage & Differential Tests
- `capi_hostcall_test.zig` covers all 22 scenarios across JIT off, Tier-1 interpreter, and native, comparing normalized deep snapshots between the `.S` entry and `mhCallViaH1`.
- A dedicated admission test (`the .S entry admits closure calls...`) validates that all positive shapes take the `.S` chain path and every edge rejection falls back to H1.
- Acceptance walks in `tools/hostcall-acceptance.sh` exercise all paths (success with callback, guest handler, result overflow helper, fallback, error).
- Only one code path in the `.S` file is not exercised by tests: the pre-commit check for `next_call_seq == -1` (see Finding 3 below).

### 3. Documentation Alignment
- §5.8 and §6.3 accurately reflect the implementation, including measurements, table deltas, and inlined frame structures (`opRet ← chain ← entry ← main`).
- There is a minor overstatement in the Status Checklist regarding scenario-level path counters (see Finding 2).

---

## Numbered Findings

### 1. [non-blocking] Implicit 4th argument setup for `mahina_hostcall_chain`
- **Location:** [`src/asm/hostcall_x64.S:357-366`](file:///home/bart/Projects/lune/src/asm/hostcall_x64.S#L357-L366)
- **Problem:**
  `mahina_hostcall_chain` takes four arguments: `(box, base, entry_top, entry_depth)`. In SysV ABI, argument 4 is passed in `%rcx`.
  At lines 357–360, `%ecx` is loaded with `VM(VM_DEPTH)` as temporary scratch to compute `depth + 1`:
  ```assembly
  mov VM(VM_DEPTH)(%rbx), %ecx
  lea 1(%rcx), %eax
  mov %eax, VM(VM_DEPTH)(%rbx)
  ```
  Then at lines 363–366:
  ```assembly
  mov %rbx, %rdi
  mov %r14, %rsi
  mov %r13, %rdx
  call SYM(mahina_hostcall_chain)
  ```
  `%rdi`, `%rsi`, and `%rdx` are explicitly assigned, but `%rcx` is not loaded or referenced at the call site. It works only because `%rcx` happens to have retained `entry_depth` from the `depth` increment 6 instructions earlier.
- **Risk:**
  If step 5 is refactored (e.g. changing the increment to `incl VM(VM_DEPTH)(%rbx)` or using `%eax`), `%rcx` would silently pass stale garbage into `mahina_hostcall_chain`.
- **Recommendation:**
  Add a comment at line 365 (`/* rcx already holds entry_depth from step 5 */`) or explicitly move `%r13`/`entry_depth` to make the ABI argument setup self-evident.

---

### 2. [nit] Status checklist overstates per-scenario admission verification
- **Location:** [`docs/design/60-hand-written-machine-code.md:162-163`](file:///home/bart/Projects/lune/docs/design/60-hand-written-machine-code.md#L162-L163)
- **Problem:**
  The Status Checklist states:
  > *"Stage-2 differential tests (§6.1): every scenario test runs `mh_call` (the `.S`) against `mhCallViaH1`, on the three tiers, in Debug and ReleaseFast. A test-only counter proves each scenario actually takes the path it's meant to."*
  
  In the code, `Pair.call` executes both legs and compares snapshots, but does not assert on `capi.hostcall_counts`. The counter verification is done in the dedicated unit test `the .S entry admits closure calls within its limits and falls back on everything else`, as correctly described in §5.8 (L1542).
- **Recommendation:**
  Adjust line 162 in the checklist to match §5.8 ("A dedicated test asserts which calls the entry admits and which it hands to H1, shape by shape").

---

### 3. [non-blocking] `next_call_seq` exhaustion check is untested
- **Location:** [`src/asm/hostcall_x64.S:152`](file:///home/bart/Projects/lune/src/asm/hostcall_x64.S#L152)
- **Problem:**
  `cmpq $-1, VM(VM_NEXT_CALL_SEQ)(%rdi); je SYM(mahina_hostcall_slow)` is the sole pre-commit check in `hostcall_x64.S` not reached by any test in the test suite.
- **Context:**
  This is already acknowledged on the doc's Outstanding list ([L182–186](file:///home/bart/Projects/lune/docs/design/60-hand-written-machine-code.md#L182-L186)), because triggering `next_call_seq == -1` panics in `pushFrameTrusted` and requires a subprocess execution harness not yet present in `zig build test`.
- **Recommendation:**
  No change needed for H3 landing; keep tracked in Outstanding tasks for when subprocess test harnesses are added.

---

### 4. [commentary / evaluation] Decision on Landing H3 Without Record/Replay Legs
- **Location:** [`docs/design/60-hand-written-machine-code.md:174-181`](file:///home/bart/Projects/lune/docs/design/60-hand-written-machine-code.md#L174-L181)
- **Evaluation:**
  The status section records an open question: §6.1 originally specified running record/replay legs before H3 lands, but the embedding currently has no record/replay mode (`createVm` fixes `effects` to `.off`).
  
  **Soundness Assessment:** There is **no soundness reason** specific to H3 that requires holding H3 back for record/replay legs:
  1. **Determinism isolation:** H3 strictly preserves determinism invariants. `next_call_seq` and `safepoint_seq` progress identically to H1.
  2. **Fast-word discipline:** Any condition that touches recording, pending anchors, or arm requests sets `fast_block != 0`. H3 checks `fast_block` pre-commit and immediately bails out to H1. Thus, trace recording/replaying never starts from or crosses through unmediated `.S` entry code.
  3. **Artifact equality:** The differential tests already verify byte-for-byte identity of all serialized artifacts that record/replay mode would inspect (serialized keyframes, committed traces, effect logs) across all scenarios and tiers.
  
  Holding H3 until embedding record/replay is built would create an artificial dependency on an unrelated embedding feature. Landing H3 and running the record/replay legs against both H1 and H3 when the embedding gains that mode is completely sound.
