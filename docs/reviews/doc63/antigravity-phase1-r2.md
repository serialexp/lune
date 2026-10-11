### Confirmation Review: Doc 63 Phase 1

This confirmation review evaluates the uncommitted Phase 1 changes in `/home/bart/Projects/lune` across [`git diff`](file:///home/bart/Projects/lune) and untracked files [`src/capi_epoch_test.zig`](file:///home/bart/Projects/lune/src/capi_epoch_test.zig) and [`src/capi_suspend_test.zig`](file:///home/bart/Projects/lune/src/capi_suspend_test.zig), specifically assessing the updated [`docs/design/63-trace-host-calls.md §5.9.1`](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md#L792-L990) and the author's dispositions in [`docs/reviews/doc63/phase1-dispositions.md`](file:///home/bart/Projects/lune/docs/reviews/doc63/phase1-dispositions.md).

---

### Detailed Verification Against the 4 Areas

#### 1. "Suspended implies never dispatching in `.fast`" on every path
**Verdict: Holds unconditionally.**
- **Hand-written x86-64 Entry ([`src/asm/hostcall_x64.S:138-139`](file:///home/bart/Projects/lune/src/asm/hostcall_x64.S#L138-L139))**:
  The pre-commit check tests `cmpw $0, VM(VM_TRACE + TRACE_FAST_BLOCK)(%rdi)`. When suspended, bit 7 (`FastBit.jit_suspended` = `0x80`) is set, so this comparison evaluates non-zero. The entry unconditionally takes `jne SYM(mahina_hostcall_slow)` into H1 (`hostcallSlow`). The layout offset `TRACE_FAST_BLOCK` was updated for `TraceState.suspend_depth` in [`src/asm/offsets_x64.inc`](file:///home/bart/Projects/lune/src/asm/offsets_x64.inc#L37) and is verified at compile-time by [`src/asm/offsets_x64.zig:106`](file:///home/bart/Projects/lune/src/asm/offsets_x64.zig#L106).
- **H1 / Public Entry Funnels ([`src/interp.zig:2924-2980`](file:///home/bart/Projects/lune/src/interp.zig#L2924-L2980))**:
  `runPushedFrame` and `callValue` route through `execWithEntry`, which gates `.fast` on `if (self.runFastPath())`. Because `fast_block != 0`, `runFastPath()` returns `false`, bypassing `chainEntry(.fast)` and entering `execWith(stop_depth)`. `execWith` likewise evaluates `runFastPath()` on every iteration of its dispatch loop and enters `execImpl(.full, stop_depth)`.
- **Mode-Switch Handoffs ([`src/interp.zig:4439`](file:///home/bart/Projects/lune/src/interp.zig#L4439), [`:5376`](file:///home/bart/Projects/lune/src/interp.zig#L5376), [`:7608`](file:///home/bart/Projects/lune/src/interp.zig#L7608))**:
  All transitions that could switch mode from `.full` to `.fast` (`switch_mode_at`) explicitly gate on `if (self.runFastPath())`. With `jit_suspended` set, no handoff to `.fast` can ever be issued.
- **Fail-Safe Assertion ([`src/interp.zig:3021-3026`](file:///home/bart/Projects/lune/src/interp.zig#L3021-L3026))**:
  In `.fast`, `Vm.jitSuspended(comptime mode)` asserts `std.debug.assert(!self.trace.suspended())`. Any violation immediately panics in debug / test builds.

#### 2. `fast_block` synchronization with `suspend_depth`
**Verdict: Invariant strictly preserved.**
- **Sole Writers ([`src/trace.zig:3051-3060`](file:///home/bart/Projects/lune/src/trace.zig#L3051-L3060))**:
  `TraceState.raiseSuspend` and `TraceState.lowerSuspend` are the only writers of `suspend_depth` in the entire codebase. `raiseSuspend` increments `suspend_depth` and executes `self.setFastBit(FastBit.jit_suspended, true)`. `lowerSuspend` asserts `suspend_depth != 0`, decrements `suspend_depth`, and executes `self.setFastBit(FastBit.jit_suspended, self.suspend_depth != 0)`.
- **Bit Allocation ([`src/trace.zig:3063-3085`](file:///home/bart/Projects/lune/src/trace.zig#L3063-L3085))**:
  `FastBit.jit_suspended` occupies bit 7 (`1 << 7`). Trace-owned bits are cleanly defined as `(1 << 8) - 1` (bits 0–7), and VM bits are shifted to 8–10 (`vm_suspend: 1 << 8`, `vm_safepoint_lines: 1 << 9`, `vm_final_cut: 1 << 10`).
- **Nesting & Coexistence ([`src/interp_fastblock_test.zig:72-81`](file:///home/bart/Projects/lune/src/interp_fastblock_test.zig#L72-L81))**:
  Nesting preserves `jit_suspended` across multiple levels and clears it on the final decrement. Recomputation via `traceFastBits()` and `fastBlockReference()` includes `self.suspend_depth != 0`, asserted bit-for-bit on every `runFastPath()` call in safety builds.

#### 3. Verification of Dispositions
**Verdict: All 12 round-1 dispositions are completely done and verified.**
- **Codex 1 / AG 4 (`pending_anchor_base` & slow path)**: Gated behind `if (!self.trace.skipBackEdge(proto, anchor_pc) and !self.jitSuspended(mode))` in [`src/interp.zig:7341`](file:///home/bart/Projects/lune/src/interp.zig#L7341). `onBackEdge` now asserts `!self.suspended()` at [`src/trace.zig:3442`](file:///home/bart/Projects/lune/src/trace.zig#L3442). Pinned by [`src/capi_suspend_test.zig:196`](file:///home/bart/Projects/lune/src/capi_suspend_test.zig#L196) and [`:342`](file:///home/bart/Projects/lune/src/capi_suspend_test.zig#L342).
- **Codex 2 (`Vm.exec` bump)**: Bumps `self.heap.bumpHostEpoch()` at [`src/interp.zig:2885`](file:///home/bart/Projects/lune/src/interp.zig#L2885). Pinned by exact delta 1 in [`src/capi_epoch_test.zig:276-279`](file:///home/bart/Projects/lune/src/capi_epoch_test.zig#L276-L279).
- **Codex 3 / AG 2 / AG 5 (Epoch isolation & test coverage)**: All 19 non-exempt C API entries and `hostcallReference` are tested with early-rejecting arguments for exact delta 1 ([`src/capi_epoch_test.zig:100-158`](file:///home/bart/Projects/lune/src/capi_epoch_test.zig#L100-L158)); `mh_collect` is pinned at delta 2; the 5 core bump sites are pinned with exact deltas ([`:270-315`](file:///home/bart/Projects/lune/src/capi_epoch_test.zig#L270-L315)).
- **Codex 4 (Suspension test controls & coverage)**: All 4 patch kinds tested with isolated suspended-vs-control runs ([`src/capi_suspend_test.zig:124-178`](file:///home/bart/Projects/lune/src/capi_suspend_test.zig#L124-L178)); tier-1a cached unpatched entry tested ([`:180-201`](file:///home/bart/Projects/lune/src/capi_suspend_test.zig#L180-L201)); invalidated pending patches tested ([`:203-244`](file:///home/bart/Projects/lune/src/capi_suspend_test.zig#L203-L244)); active outer recording isolation verified ([`:311-348`](file:///home/bart/Projects/lune/src/capi_suspend_test.zig#L311-L348)).
- **Codex 5 (Cost claims & measurements)**: Per-shape table (+19 `cb`, +19 `two`, +21 `fail`, +23 `tw`) added; 0.00% repeat spread documented; hot patched path cost eliminated via `fast_block` bit (euler14-bit −0.01%); tier-0 `opCall` reg-alloc overhead documented in Outstanding.
- **Codex 6 (Wording consistency)**: Corrected in §5.9.1; inert state noted; all 3 unlisted paths documented.
- **AG 1 (`abortRaised` control)**: Added at [`src/capi_suspend_test.zig:370-371`](file:///home/bart/Projects/lune/src/capi_suspend_test.zig#L370-L371).
- **AG 2 (`mhCallViaH1` test)**: Added at [`src/capi_epoch_test.zig:115-116`](file:///home/bart/Projects/lune/src/capi_epoch_test.zig#L115-L116).
- **AG 3 (`mh_vm_new` / `mh_vm_free` tests)**: Added at [`src/capi_epoch_test.zig:229-254`](file:///home/bart/Projects/lune/src/capi_epoch_test.zig#L229-L254).
- **AG 5 (`hostcallReference` bump)**: Added at [`src/capi.zig:909`](file:///home/bart/Projects/lune/src/capi.zig#L909) and tested at [`src/capi_epoch_test.zig:118-119`](file:///home/bart/Projects/lune/src/capi_epoch_test.zig#L118-L119).
- **AG §3 (`setRegionContext`)**: Explicitly noted in §5.9.1 and tracked in Outstanding ([`docs/design/63-trace-host-calls.md:81`](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md#L81), [`:912`](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md#L912)).

---

### Numbered Findings

#### Finding 1: Inaccurate Scope Description for `dispatchPostObserve` in §5.9.1 Table
- **Severity**: Should-fix
- **Location**: [`docs/design/63-trace-host-calls.md:885`](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md#L885)
- **Description**: The table row for "Recording feed" describes `dispatchPostObserve` as follows:
  > *"`dispatchPostObserve` computes `jit_live = mode == .full and !jitSuspended(mode)` and uses it for every step after the observation: continuation and replay starts, call-anchor arming, the head and region hooks, the drain."*
  
  This overstates and misattributes what `dispatchPostObserve`'s `jit_live` actually guards in [`src/interp.zig:3371-3460`](file:///home/bart/Projects/lune/src/interp.zig#L3371-L3460):
  1. `dispatchPostObserve` guards steps (8)–(11): anchor closing (`maybeCloseAtAnchor`), continuation starts (`maybeStartContinuation`, `maybeStartCont`), replay starts (`maybeStartReplaySide`), head starts (`maybeStartHead`), and the instruction mirror (`recordInstr`).
  2. It does **not** perform call-anchor arming (which is filed in `onCallEntry`).
  3. It does **not** gate region hooks (the region observer is step 5 in `regionTrampoline`, which precedes `dispatchPostObserve` and is explicitly ungated per lines 915–934).
  4. It does **not** call `drainEntryPatchWork` (drains occur in `onCallEntry`/`onRetResume` via `maybeRepatch*` and `backEdgeEpilogue`).
- **Remedy**: Update the table text to accurately list the steps inside `dispatchPostObserve`:
  *"...uses it for every step after the observation: continuation and replay starts, head and continuation anchor starts, anchor closing, and the recording mirror."*

#### Finding 2: Unqualified "+11 per host call" Claim in Phase 1 Checklist Summary
- **Severity**: Nit
- **Location**: [`docs/design/63-trace-host-calls.md:76`](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md#L76)
- **Description**: In the Phase 1 checklist summary, line 76 states:
  > *"Measured cost: +11 instructions per host call, and up to +0.18% on stdlib-heavy tier-0 `bench/` rows (Outstanding decision)."*
  
  While §5.9.1 lines 965–976 carefully clarifies that +11 is specifically the cost of **pure** host calls (`min`/`minl`), and that disturbing shapes cost +19 to +23 instructions (`cb`: +19, `two`: +19, `fail`: +21, `tw`: +23), the summary line in the checklist leaves "+11 per host call" unqualified.
- **Remedy**: Qualify line 76 as:
  *"Measured cost: +11 instructions per pure host call (+19–23 for disturbing shapes), and up to +0.18% on stdlib-heavy tier-0 `bench/` rows (Outstanding decision)."*

---

### Overall Verdict

**VERDICT: ACCEPT (GREEN / SOUND)**

1. The architectural invariants of Phase 1 are completely met: the fast-block bit guarantees that suspended execution remains strictly confined to `.full` on every execution path, including the hand-written x86-64 assembly entry.
2. The `fast_block` word stays strictly in sync with `suspend_depth` at all times, verified by whole-word runtime assertions and exhaustive unit tests.
3. Every disposition from round 1 has been executed with rigor, pairing all suspended behaviors with unsuspended controls and exact delta pinning.
4. Correcting the description in §5.9.1 line 885 (Finding 1) and qualifying line 76 (Finding 2) will ensure complete precision in the design documentation before landing.
