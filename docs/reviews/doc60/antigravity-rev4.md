# Doc 60 rev 4 — antigravity review (2026-10-03)

Reviewer: Antigravity (tools enabled, read-only instruction). No files modified.

Verdict: CHANGES REQUESTED

### Summary of Revision 4 Review

Revision 4 makes substantial progress:
1. **§10 Review Disposition Verification**: All 16 rev-3 findings from codex and antigravity have been verified against the source code, tests, headers, and the pinned Zig stdlib (`0.17.0-dev.813+2153f8143`). Null buffer handling (`results == null`, `args == null`) is properly gated in `mh_call` and pre-commit checks; `mahina_hostcall_park_rest` accepts nullable `?[*]const mh_value`; the straight-line argument limit is strictly enforced (≤ 8 in assembly, > 8 falls back to H1); the audit correctly lists 10 standalone recorder tests (from `trace_recorder.zig:6148`) and 58 owned-recorder reset test sites; and `libmahina` correctly restricts assembly to Linux x86-64 because `mh_new` installs Linux-only syscall sources (`capi.zig:414, :450`).
2. **§5.4 Producer/Consumer Table & Coexistences**: Every guard, producer, consumer, and clearer in the corrected table was checked against `src/trace.zig`, `src/trace_link.zig`, and `src/interp.zig`. All three reachable coexistence cases are fully verified in the code:
   - Exit anchor + ret anchor: `onRetResume` (`interp.zig:6560`, `trace.zig:3448`) fires on non-boundary returns without clearing or checking `pending_exit_anchor`.
   - Exit anchor + replay anchor: `consumeSideTraceWantAtResume` (`trace.zig:3193`) checks `rec.active`, `pending_replay_anchor`, and barred status, but explicitly permits an active `pending_exit_anchor`.
   - Arm requests (`pending_ret_cont_arm`, `pending_call_head_arm`) coexist across long intervals until consumed at trace selection/entry (`interp.zig:4039`, `trace.zig:1906–1927`).
3. **Q12 Options**: Both Option (a) (stated slice exception with indirect comptime layout validation) and Option (b) (primitive mirror fields on `Vm` with fallback on overflow) are sound and correctly described for the project owner's decision.

However, two new blockers were discovered in rev 4: an unsound asymmetric lifecycle for `native_reentry_depth` across the `runPushedFrame`/`mahina_hostcall_chain` boundary that causes double-decrement hazards on H1 error paths, and impossible stack trace requirements in the §6.3 acceptance checks for fallback and park-helper paths.

---

### BLOCKERS

#### 1. Unsound asymmetric `native_reentry_depth` decrement contract in `runPushedFrame`
- **Evidence:** doc60:427–431, :510, :535, :554; `src/interp.zig:2101–2104`.
- **Details:**
  1. §4.1 line 429 states: *"Then it decrements `native_reentry_depth`, matching `callValue`'s errdefer, and returns the error."*
  2. In reality, `callValue` (`src/interp.zig:2101–2104`) has **no errdefer**. It has a paired, normal `defer`:
     ```zig
     if (self.native_reentry_depth >= max_native_reentry) return Error.StackOverflow;
     self.native_reentry_depth += 1;
     defer self.native_reentry_depth -= 1;
     ```
     `defer` executes symmetrically on *both* success and error returns.
  3. Under doc 60's split, `native_reentry_depth` is incremented by `.S` at Step 3 (doc60:510), decremented by `.S` on success at Step 9 (doc60:535), but decremented inside `runPushedFrame` on error at Step 13 (doc60:554).
  4. This creates an asymmetric lifecycle: `runPushedFrame` decrements a field on the error path that it did not increment on entry and does not decrement on the success path.
  5. Crucially, §4.1 line 436 mandates: *"H1 uses this same function after its own Zig push. So H1 and H3 differ only in the push and copy-out, not in the run."* If H1 increments `native_reentry_depth` and uses standard Zig `defer self.native_reentry_depth -= 1` (matching `callValue` today), any guest error will cause a **double-decrement** (once in `runPushedFrame`'s error path, once in H1's defer), underflowing `native_reentry_depth` (`0 - 1 = 65535`).
- **Required Fix:** Choose one of two clean contracts:
  - **Option A (Recommended — Fully encapsulate in `runPushedFrame`):** Let `runPushedFrame` own `native_reentry_depth` symmetrically:
    ```zig
    pub fn runPushedFrame(self: *Vm, entry_depth: u32) Error!FrameResult {
        self.native_reentry_depth += 1;
        defer self.native_reentry_depth -= 1;
        ...
    ```
    Pre-commit checks in `.S` only need to read `native_reentry_depth < max_native_reentry`. Neither `.S` nor H1 touches `native_reentry_depth` at steps 3, 9, or 13. On error, `defer` decrements the depth before returning to `mahina_hostcall_chain`, so `guestFault` sees the decremented value exactly as today, while on success it decrements before returning `FrameResult`.
  - **Option B (Caller owns both edges):** If `.S` and H1 own the increment, remove the decrement from `runPushedFrame`. In `mahina_hostcall_chain`, decrement `native_reentry_depth` on the error edge right before invoking `guestFault(box, entry_depth, entry_top, err)`.

#### 2. §6.3 Unwind acceptance test requires impossible physical stack frames on fallback and park-helper paths
- **Evidence:** doc60:859–863; :329–333, :442–444, :536–541.
- **Details:**
  §6.3 lines 859–862 specify:
  > *"DWARF: a test makes gdb (or `perf --call-graph dwarf`) walk `host → entry → shim → handler` and back. It covers the normal path, a pre-commit fallback, and a stop inside the park helper."*

  This assertion is physically impossible for two of the three listed paths:
  1. **Pre-commit fallback:** Per §3.3 lines 329–333, pre-commit checks execute *before* the `.S` prologue; a failed check executes a bare `jmp mahina_hostcall_slow`. Because `mh_call` tail-called `entry` without a frame and `entry` jumped without a frame, the physical stack during fallback is `host → mahina_hostcall_slow`. Neither `entry`, `shim`, nor `handler` exists on the stack.
  2. **Stop inside the park helper:** Per §4.3 Steps 6–10, `mahina_hostcall_park_rest` is invoked in Step 10 *after* `mahina_hostcall_chain` (`shim`) and the guest execution (`handler`) have successfully completed and returned (`MH_OK`). At that point, `shim` and `handler` frames have already been popped; the physical stack is `host → entry → mahina_hostcall_park_rest`.

  Any acceptance test asserting that all three paths walk `host → entry → shim → handler` will unconditionally fail.
- **Required Fix:** Disambiguate the acceptance criteria by explicitly specifying the expected frame sequence for each path:
  - Normal path (inside guest handler): `host → entry → shim → handler`
  - Pre-commit fallback path: `host → mahina_hostcall_slow`
  - Park-overflow helper path: `host → entry → mahina_hostcall_park_rest`

---

### SHOULD-FIX

#### 1. Dead `base` parameter in `mahina_hostcall_chain` and dependent-load penalty in `runPushedFrame`
- **Evidence:** doc60:408–418, :462–463; `src/interp.zig:2470–2488`.
- **Details:**
  - §4.2 line 462 declares: `fn mahina_hostcall_chain(box: *VmBox, base: usize, entry_top: usize, entry_depth: u32) callconv(.c) ChainResult;`.
  - §4.1 lines 408 and 439 show that `mahina_hostcall_chain` calls `box.vm.runPushedFrame(entry_depth)` and passes only `(box, entry_depth, entry_top, err)` to `guestFault`. The parameter `base: usize` is never used.
  - Furthermore, today's `execWithEntry` (`src/interp.zig:2470`) takes `base` as an argument specifically to build `ExecState` without paying a dependent-load spine through `frame.base`.
  - If `runPushedFrame` only accepts `entry_depth`, it must re-read `frame = &self.frames[self.depth - 1]` and `base = frame.base` from memory, re-introducing that dependent load.
- **Recommendation:** Either pass `base` into `runPushedFrame(entry_depth, base)` to eliminate the redundant load, or remove `base` from `mahina_hostcall_chain`'s signature.

#### 2. Omission of entry `final_cut = null` in §4.3 ordered state contract
- **Evidence:** doc60:269–274, :411, :499–527.
- **Details:**
  - §3.2 line 269 and §4.1 line 411 state that `runPushedFrame` clears `final_cut`.
  - In §4.3's ordered Entry sequence (Steps 1–6), `final_cut` is never mentioned, whereas Success exit explicitly documents step 7 (*"The anchor clear has already run, in `runPushedFrame`"*).
  - Also, in §4.3 Steps 4–5, sampling `entry_top` and `entry_depth` into registers (required for step 9's restore and step 6's arguments) must occur before Step 5 mutates `depth` and `stack_top`.
- **Recommendation:** In §4.3 Step 6, explicitly note that `runPushedFrame` clears `final_cut = null` before building `ExecState`, and note in Step 4 that `entry_top` and `entry_depth` are captured before frame push.

#### 3. Missing PIC / `-fPIC` specification for shared-library acceptance in §6.3
- **Evidence:** doc60:851–857; `build.zig:106–120`, pinned `Module.zig:225`.
- **Details:**
  §6.3 specifies linking `libmahina.a` into a shared library with `-Wl,-z,text`. On Linux x86-64, linking static archive objects into a `.so` with text-relocation checks requires that the archive members be compiled as Position Independent Code (`.pic = true` in Zig's `Module`) and that `hostcall_x64.S` uses RIP-relative addressing. `build.zig` currently does not set `.pic = true` on `capi_mod`.
- **Recommendation:** State explicitly in §6.3 that the build configuration for the shared-library acceptance check must enable PIC on the module (`.pic = true`), and that the assembly must use RIP-relative addressing for all symbol references.

#### 4. Inverted `ChainResult` field order adds unnecessary register shuffle on error path
- **Evidence:** doc60:461, :474–480.
- **Details:**
  - `ChainResult` is declared as: `const ChainResult = extern struct { frame_result: u32, status: u32 };`.
  - In the SysV x86-64 ABI, an 8-byte struct is returned in `%rax`, where the first field occupies bits 0–31 (`%eax`) and the second occupies bits 32–63.
  - Because `frame_result` is first, `%eax` holds `frame_result` and `status` is in the upper 32 bits. On an error return, the `.S` entry must shift `%rax` (`shr $32, %rax`) before returning `status` in `%eax`.
- **Recommendation:** Define `ChainResult` as `extern struct { status: u32, frame_result: u32 };`. On error, `%eax` naturally holds `status`, allowing the assembly to restore callee-saved registers and return immediately.

---

### NITS

1. **Zig LIFO `errdefer` evaluation order in `runPushedFrame`** (doc60:427–430): §4.1 states: *"Errors go through today's errdefers, in order: `abortRaised()`, then `clearPendingExitAnchor()`... Then it decrements `native_reentry_depth`"*. Note that Zig executes `errdefer` in reverse (LIFO) order of declaration, so declarations must appear in inverse order to their execution.
2. **Missing exact citation line for `safepoint_seq`** (doc60:525, `src/interp.zig:2784, :2789`): §4.3 Step 6 cites `interp.zig:2784` (the `dispatchPostGc` function header). The exact line incrementing `safepoint_seq` is `src/interp.zig:2789`. Adding `:2789` improves citation precision.
3. **Q12 Soundness Confirmation** (doc60:282–318): Both Option (a) and Option (b) were reviewed. Option (a) correctly uses `@typeInfo` and bitcast round-trips to bypass `@offsetOf`'s slice limitations, while Option (b) cleanly insulates assembly from `ArrayList` internals via mirror fields and H1 fallback. Both are sound.
