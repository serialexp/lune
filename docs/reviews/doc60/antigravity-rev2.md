# Doc 60 rev 2 — antigravity review (2026-10-02)

Reviewer: Antigravity (tools enabled, read-only instruction). No files modified.

Verdict: CHANGES REQUESTED

Revision 2 is a major step forward. The four rev-1 blockers — `CallFrame.code_cache_gen` invalidation, `.switch_mode` transition handling, exit lifecycle hooks (`abortRaised` / `clearPendingExitAnchor`), and input parking retention — have been incorporated. The test plan in §6 is now comprehensive, the instruction ledger in §5.3 is realistic and accounts for `ExecState` construction, and the DynASM/W^X claims in §1 and §3 have been corrected.

However, three soundness blockers remain in the revised architecture:
1. **Pre-commit fallback omits null-pointer and fatal checks (§4.1)**: If `vm == NULL`, the entry immediately segfaults on Step 1 (`fast_block` load); if `box.fatal == true`, it executes guest code in a poisoned VM; and if `nresults == NULL`, Step 10 segfaults.
2. **The shim signature lacks `box: *VmBox` and `entry_top: usize` (§4.2, §4.3 Step 13)**: The shim cannot call `guestFault` without `box` (to render messages and poison `box.fatal`), and without `entry_top` (which differs from `base` in vararg calls with surplus args), closing upvalues and stack-top restoration will leak stack slots and corrupt upvalues.
3. **Missing result parking overflow mechanism (§4.1, §4.3 Step 10)**: `vm.parked_inline` holds only 6 values. While incoming arguments can be checked pre-commit, guest code can return more heap results than remaining capacity. Straight-line assembly cannot append to `ArrayList(Value)` or report OOM, and it cannot fall back to H1 after guest execution has completed.

---

### Verification of Rev-1 Findings & Citations

All citations in rev 2 were verified against the codebase and the pinned toolchain (`0.17.0-dev.813+2153f8143`):
- [x] **Antigravity B1 / Codex B2 (`CallFrame` cache invalidation & `ExecState`)**: Addressed in §3.2, §4.1, §4.3 Step 5. Verified `src/interp.zig:404-411` (`code_cache_gen: u64 = CODE_CACHE_GEN_INVALID`) and `src/interp.zig:2659-2665` (`cachedCodeFor`). All 10 fields and the `-1` sentinel store are specified. `next_call_seq` exhaustion check (`src/interp.zig:2024-2026`) is preserved.
- [x] **Antigravity B2 / Codex B3 (`.switch_mode` transition)**: Addressed in §4.1. Resumes the pushed frame at parked PC via `self.execWith(stop_depth)` (`src/interp.zig:2506-2512`).
- [x] **Antigravity B3 / Codex B3 (Exit hooks)**: Addressed in §4.3 Steps 7, 11. `trace.clearPendingExitAnchor()` on success (`src/interp.zig:2496`), `abortRaised()` + `clearPendingExitAnchor()` on error (`src/interp.zig:2476-2477`).
- [x] **Antigravity B4 / Codex B1 (Input parking retention)**: Abandoned the proposal to drop parking. Header contract (`include/mahina.h:20-25`) preserved; callee and heap args parked in §4.3 Step 2. Regressions included in §6.1.
- [x] **Antigravity S5 / Codex S2 (Instruction budget)**: Addressed in §5.3. Two inclusive ledgers, inclusive of `ExecState` (30–40 instr in shim) and address calculations.
- [x] **Antigravity S6 / Codex B4 (`TraceState` modularity & fast word)**: Moved `fast_block` to `TraceState` to avoid reaching into `Vm`. Production writes in `src/wasm_entry.zig:711` routed through `Vm` setters.
- [x] **Antigravity S7 / Codex S4 (DynASM, W^X, `x64.zig`)**: Corrected build-time generation (`LuaJIT/src/Makefile:675-688`), `x64.zig` indexed/scaled addressing (`src/x64.zig:218, 362`), and executable mapping.
- [x] **Antigravity S8 / Codex B5 (Hashgate & test plan)**: Addressed in §6. Clarified `just hashgate` is CLI-only. Added two-stage differential testing and keyframe comparisons.
- [x] **Codex S1 (Dispatch prologue order & `onCallEntry`)**: Unchanged prologue order preserved (`src/interp.zig:2741, 2784, 2864`); `onCallEntry` not called on host entry (`src/interp.zig:6327`).
- [x] **Codex S3 / Antigravity N9 (Toolchain APIs & CFI)**: Toolchain APIs verified in `lib/std/Build/Module.zig:435` (`addAssemblyFile`) and `lib/std/lang.zig:157` (`naked`). DWARF CFI directives mandated in §3.3.

---

### BLOCKERS

#### 1. Pre-commit fallback omits null-pointer and fatal checks, causing SIGSEGV on invalid host calls
- **Evidence:** doc60:189-195, `src/capi.zig:693-696`.
- **Details:** §4.1 specifies:
  > *"The entry checks, in order: the fast word (§5.4), the callee tag and heap type (closure only; natives and `__call` go to Zig), the depth limit, the reentry limit, the register capacity, and park capacity for every value it must park. Any failure makes it tail-jump to the H1 Zig entry with the original arguments, before any VM state is mutated."*

  In `src/capi.zig:693-696`, the C API entry validates:
  ```zig
  const box = vm orelse return .err_api;
  const nres = nresults orelse return .err_api;
  nres.* = 0;
  if (checkFatal(box)) |s| return s;
  ```
  If `entry` receives the raw C arguments and immediately loads `fast_block`:
  1. If `vm == NULL` (`%rdi == 0`), dereferencing `vm.trace.fast_block` will immediately `SIGSEGV`.
  2. If `box.fatal == true` (the VM is poisoned from an earlier non-catchable fault like OOM or replay corruption), the check is skipped and guest code is executed in a poisoned VM.
  3. If `nresults == NULL`, Step 10 dereferences `%rax` / stack argument to store `*nresults = count`, causing a `SIGSEGV`.

  **Required Fix:** The pre-commit checks in assembly must begin with `test %rdi, %rdi; jz .Lfallback`, `cmp byte [rdi + OFF_BOX_FATAL], 0; jne .Lfallback`, and validating `nresults != NULL` (passed at `16(%rsp)`). Any failure must tail-jump to H1 where `checkFatal` and `err_api` rendering run.

#### 2. The shim signature lacks `box: *VmBox` and `entry_top: usize`, making `guestFault` invocation unsound
- **Evidence:** doc60:219-222, doc60:275-280, `src/capi.zig:345-359`, `src/interp.zig:2176-2189`.
- **Details:** §4.2 defines the shim signature:
  ```zig
  fn hostcallChain(vm: *Vm, cl: *const Closure, base: usize, stop_depth: u32,
                   out_status: *mh_status) callconv(.c) u32
  ```
  And §4.3 Step 13 specifies that the shim executes `guestFault`:
  > *"13. `guestFault`: render the located message while the faulting frames are live, then for catchable errors `closeUpvaluesFrom(entry_top)`, `dropRegionActivationsFromDepth(entry_depth)`, restore `depth` and `stack_top`, and clear `pending_error` and `final_cut`. Non-catchable errors poison the VM (`box.fatal`) and keep their fault state (`capi.zig:345–359`)."*

  However, `guestFault` in `src/capi.zig:345` is:
  ```zig
  fn guestFault(box: *VmBox, entry_depth: u32, entry_top: usize, err: interp.Error) mh_status
  ```
  The shim signature cannot perform Step 13:
  1. `vm: *Vm` does not have access to `box: *VmBox`. `Vm` is the core VM struct in `src/interp.zig` and has no pointer to `VmBox`. `guestFault` requires `box` to allocate formatted error diagnostics from `box.backing`, write `box.last_error`, and set `box.fatal = true`.
  2. For vararg callees with surplus arguments (`src/interp.zig:2176-2189`), `base` is `callee_base = entry_top + args.len`. `base` is **not** `entry_top`! If `base` is passed to `guestFault` instead of `entry_top`, `closeUpvaluesFrom(entry_top)` will fail to close upvalues spanning the surplus arguments, and `vm.stack_top` will be restored to `base` instead of `entry_top`, permanently leaking `args.len` slots on the stack on every guest error.

  **Required Fix:** Update the shim signature in §4.2 to pass `box: *VmBox` (or pass `box` from `entry`), `entry_top: usize`, and `stop_depth: u32` (from which `entry_depth = stop_depth - 1`).

#### 3. Missing result parking overflow mechanism
- **Evidence:** doc60:189-195, doc60:268, `src/capi.zig:325-335`, `src/interp.zig:804`.
- **Details:** §4.3 Step 10 assigns result parking to the assembly entry: *"Park each heap result, report `nresults`, return `MH_OK`."* And §4.1 states: *"The entry does only the straight-line fast work... On `.finished` it returns the `FrameResult` (one `u32`) to the entry, which does the copy-out and the parking."*

  `vm.parked_inline` holds exactly 6 values (`src/interp.zig:804`).
  Pre-commit checks in §4.1 cannot know how many heap results the guest function will return. If a function returns 5 heap results when 2 values were already parked in `parked_inline`, the 6-slot buffer will overflow.
  In `src/capi.zig:333`, `park()` handles overflow by appending to `vm.parked_results.append(vm.gpa, v)`, which is fallible and can trigger OOM (`oom(box)`).
  Straight-line assembly cannot perform `ArrayList` reallocations or OOM handling (§3.2 strictly prohibits interpreting non-primitive types in `.S`), and it **cannot** fall back to H1 because the guest code has already executed and mutated the VM state.

  **Required Fix:** Either:
  - (A) Pre-commit checks must reserve `max_results` in `parked_inline` (`parked_inline_len + 1 + num_heap_args + max_results <= 6`), falling back to H1 before execution if the buffer might overflow; OR
  - (B) Result copy-out and parking must be performed inside the Zig shim (or call a Zig helper) where `vm.parked_results.append` and `oom(box)` are already implemented.

---

### SHOULD-FIX

#### 4. Contradiction on assembly entry visibility and call hierarchy
- **Evidence:** doc60:142, doc60:178, doc60:193-195, doc60:317-331.
- **Details:** The doc has conflicting statements about what the `.S` symbol is:
  - §3.1 line 142 states: *"(the entry is internal to the library and is not exported from the C API)"*.
  - §3.3 line 178 shows a 3-frame stack trace: *`host → mh_call → entry → shim → guest`*.
  - §4.1 line 193 states: *"Any failure makes it tail-jump to the H1 Zig entry with the original arguments"*.
  - §5.3 budgets the full public crossing as "internal entry (~90–120) + guest code (~60) + host's own call and result read (~30) = ~180–230 per mh_call", allocating 0 instructions for a Zig `mh_call` frame.

  If `mh_call` is an exported Zig function in `capi.zig` that calls `entry`, it has its own prologue/epilogue and register shuffling that must be budgeted, and `entry` cannot tail-jump to H1 unless `mh_call` tail-called `entry`. If `hostcall_x64.S` defines the exported C symbol `mh_call` directly on x86-64, it *is* exported, contradicting line 142.

  **Recommendation:** Clarify that on x86-64, `hostcall_x64.S` defines the external symbol `mh_call` directly (or `capi.zig` exports `mh_call` as an explicit tail-call jump to `entry`), removing the intermediate `mh_call` frame from line 178 and resolving line 142.

#### 5. `RecordingSession` standalone unit tests will break if `trace_recorder.zig` touches `fast_block`
- **Evidence:** doc60:353-357, `src/trace_recorder.zig:6150-6508`.
- **Details:** §5.4 states: *"`isRecording()`'s bit is set and cleared at the recorder's own success, abort and OOM boundaries (`trace_recorder.zig` resets `active` before a fallible allocation and sets it only after initialization, `:6071`, `:6130`), so no path can leave the bit disagreeing with `active`."*
  `RecordingSession` does not have a pointer to `TraceState` or `Vm`. In `src/trace_recorder.zig:6150-6508`, 12 standalone unit tests instantiate `RecordingSession` directly on the stack without any `TraceState`. If `RecordingSession` attempts to mutate `fast_block` via `@fieldParentPtr(TraceState, "rec", self)` or an uninitialized backpointer, all 12 tests will crash.

  **Recommendation:** Keep the synchronization of `isRecording()`'s bit on `fast_block` at the `TraceState` boundary functions (`armWithPolicy`, `closeTrace`, `consumeRecordingAbort`, `abortRaised`), ensuring `RecordingSession` remains independent.

#### 6. SysV calling convention and frame setup timing for pre-commit tail-jump
- **Evidence:** doc60:173-176, doc60:193-195.
- **Details:** §3.3 specifies a standard SysV prologue with callee-saved registers preserved and stack alignment. But under SysV ABI, if callee-saved registers are pushed before the pre-commit checks, `%rsp` is modified, and a tail-jump (`jmp H1`) on fallback cannot execute without popping them.
  Under SysV ABI, argument registers `%rdi, %rsi, %rdx, %rcx, %r8, %r9` and caller-saved registers `%rax, %r10, %r11` are scratch. All pre-commit checks can run using `%rax, %r10, %r11` *before* the prologue. On failure, a single `jmp H1` preserves pristine argument registers and stack arguments (`max_results` at `8(%rsp)`, `nresults` at `16(%rsp)`).

  **Recommendation:** Explicitly document in §3.3 and §4.1 that pre-commit checks run prior to prologue execution and stack frame allocation.

#### 7. Comptime target verification in §3.2 will fail when cross-compiling to non-x86 targets
- **Evidence:** doc60:151-156.
- **Details:** §3.2 states that the target build verifies `offsets_x64.inc` at comptime by parsing `.set` lines and comparing each value with `@offsetOf`/`@sizeOf` on the target being compiled.
  When cross-compiling to `wasm32-freestanding` (used by `src/wasm_entry.zig`) or `aarch64`, the target struct layout is wasm32/aarch64, while `offsets_x64.inc` contains x86-64 offsets. If the comptime check runs unconditionally, cross-compilation will fail.

  **Recommendation:** Explicitly state that the comptime verification file is only compiled / executed when `builtin.cpu.arch == .x86_64`.

---

### NITS

#### 8. Inaccurate condition count in §5.4
- **Evidence:** doc60:343-344.
- **Details:** §5.4 states: *"because eight of the nine conditions are `TraceState`'s own"*. As listed in lines 339–342, 2 conditions belong to `Vm` (`suspend_ctl != null`, `record_safepoint_lines`) and 7 belong to `TraceState` (`isRecording` + 6 `pending_*` fields). It should say 7 of 9.

#### 9. Redundant mention of `ExecState` in §3.2
- **Evidence:** doc60:147.
- **Details:** §3.2 lists `ExecState` among the structs whose offsets live in `offsets_x64.inc`. Because `ExecState` is constructed in the Zig shim (§4.1), the `.S` file never accesses `ExecState` fields. Its offsets are unnecessary in `offsets_x64.inc`. Conversely, `offsets_x64.inc` needs offsets for `VmBox`, `Closure`, `Proto`, and `ObjectHeader`.

#### 10. Return value optimization for the C shim signature
- **Evidence:** doc60:219-225.
- **Details:** §4.2 has the shim return `FrameResult` (`u32`) and write `out_status: *mh_status` via a pointer. In SysV x86-64 ABI, returning an 8-byte struct `extern struct { result: FrameResult, status: mh_status }` returns both in `%rax` directly, eliminating the need to pass an out-pointer, allocate a stack slot in `.S`, or perform extra memory reads/writes.

---

### Plausibility of Instruction Ledger (§5.3)

The internal entry budget of **~90–120 instructions** is plausible:
- **Pre-commit checks (15–20 instr)**: Fast-word test (2), callee tag/payload/header type (4–6), depth limit (2), reentry limit (2), regCapacity (3–4), `call_seq` wrap (2), park capacity (2), 1 arg tag (2–3). Total: ~19–23 instructions.
- **Park-clear + park callee/args (8–12 instr)**: Idle test + clear lengths (5–6), callee store to `parked_inline` (3–4), 1 arg store (3–4). Total: ~8–14 instructions.
- **Reentry/final_cut, bind 1 arg + nil-fill (6–10 instr)**: `reentry += 1`, `final_cut = null` (2), load/store tag + payload to stack window (3–4), nil-fill 1 temp (2). Total: ~7–10 instructions.
- **Frame write (10 fields) + depth/stack_top (14–18 instr)**: 10 field stores (including code cache invalidation: `code_cache = empty` and `code_cache_gen = -1`), `depth += 1`, `stack_top` update. Total: ~14–18 instructions.
- **Shim (30–40 instr)**: SysV prologue/epilogue (4–6), stack alloc (1), `ExecState` 11 stores (11), `cachedCodeFor` inline check and cache fill (5–8), `setRegionContext` (2), setting up 6 SysV argument registers for `chainEntry` (6), call into `chainEntry` (1), outcome switch (3–4). Total: ~35–42 instructions.
- **Success exit (15–20 instr)**: Clear exit anchors (4), copy 1 result word-wise (4–5), restore `stack_top` and `native_reentry_depth` (2), inline park 1 result (3–4), store `nresults.*` and return status (2). Total: ~15–19 instructions.

Sum of internal entry: **~98–123 instructions**.
With guest code (~60 instructions for `id`) and host probe overhead (~30 instructions), a total of **~190–220 instructions** per `mh_call` is realistic, easily beating LuaJIT's 304 instructions.

---

### Trade-offs on Open Questions Q6 & Q7

#### Q6: Where the fast word lives (Packed `u16` on `TraceState` vs. Single Tagged Union for Pending Fields)

- **Option A (§5.4 default: Packed `u16` bitmask on `TraceState`)**:
  - *Pros:*
    1. **Zero assumption of mutual exclusivity**: Does not assume the 6 pending anchors and arms cannot coexist. In fact, `pending_ret_cont_arm` and `pending_call_head_arm` can linger or accumulate independently of exit/replay anchors (`src/trace.zig:1886-1892`).
    2. **Single 16-bit load and test**: Fast dispatch check is a single `test word [trace + fast_block], 0; jz` (2 instructions in assembly or Zig).
    3. **Zero payload changes**: Existing fields retain their exact types and payloads without union conversions.
  - *Cons:*
    1. **Synchronization surface**: All write sites must update `fast_block` alongside the underlying field.
    2. **Split ownership**: 7 bits belong to `TraceState`, but 2 bits belong to `Vm` (`suspend_ctl`, `record_safepoint_lines`), requiring `Vm` to call `TraceState` setters.
    3. **Dual state**: Duplicates boolean information already present in field nullness.

- **Option B (Alternative: Single Tagged Union on `TraceState` for pending anchors)**:
  - *Pros:*
    1. **Single source of truth**: Clearing all pending anchors is a single assignment `trace.pending = .none`, eliminating multi-site synchronization bugs.
    2. **Smaller `TraceState` footprint**: Merges 6 separate structs into a single union, improving cache locality.
    3. **No bitmask drift**: Tests cannot get out of sync with a separate mask.
  - *Cons:*
    1. **Requires mutual-exclusivity proof**: If any trace condition can file a `ret_cont_arm` while an `exit_anchor` or `replay_anchor` is pending, the union will silently overwrite one with the other.
    2. **Does not eliminate the fast-path checks**: The other 3 conditions (`suspend_ctl != null`, `record_safepoint_lines`, and `isRecording()`) are orthogonal to pending anchors. Checking `runFastPath` would still require checking the union tag plus the remaining 3 conditions (at least 4 checks instead of 1 bitmask check), or still requiring a bitmask for the rest.

#### Q7: Offsets mechanism (Checked-in `offsets_x64.inc` with Comptime Verification vs. Zig-Emitted Absolute Symbols)

- **Option A (§3.2 default: Checked-in `src/asm/offsets_x64.inc` verified at comptime)**:
  - *Pros:*
    1. **Immediate displacements in machine code**: Displacements are known at assembly time, enabling compact ModRM encodings (e.g. `disp8` for small offsets < 128 bytes) with zero linker relocation overhead.
    2. **Human-readable and inspectable**: Developers and debuggers can inspect `offsets_x64.inc` directly to understand struct layouts without disassembling linked binaries.
    3. **Target verification**: Comptime verification catches toolchain bumps or struct field additions immediately at compile time.
  - *Cons:*
    1. **Maintenance on struct edits**: Adding or reordering fields in `Vm`, `CallFrame`, etc. requires updating the `.inc` file (though compiler errors print the exact corrected line).
    2. **Target specificity**: The checked-in file is specific to x86-64. If field layout ever differed between OS targets (e.g. Windows x64 vs Linux x64), multiple files would be needed.

- **Option B (Alternative: Zig-emitted global absolute symbols via module-level `asm`)**:
  - *Pros:*
    1. **Zero maintenance**: No checked-in file to maintain or sync; symbols automatically reflect the exact target struct layout on every build.
    2. **Immune to layout churn**: Toolchain bumps or struct changes never break the build.
    3. **Cross-compilation friendly**: Uses the exact target layout automatically without hardcoded files.
  - *Cons:*
    1. **Linker relocations (`disp32`)**: The assembler cannot resolve external symbol displacements into immediate bytes, forcing 32-bit relocations (`R_X86_64_32S`) on every displacement, bloating code size and preventing 1-byte `disp8` optimizations.
    2. **PIC / Shared Library hazards**: External absolute symbol references in text sections can cause text relocations (TEXTREL) or linker errors in position-independent shared libraries (`libmahina.a` / `.so`) unless explicitly marked hidden and handled by the linker.
    3. **Opaque assembly source**: The `.S` source code contains symbolic names without visible offsets, making standalone assembly review harder.
