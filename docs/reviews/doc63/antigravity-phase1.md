### Comprehensive Code Review: Doc 63 Phase 1

This review evaluates the uncommitted Phase 1 implementation of [doc 63](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md) (epoch, disturbance, suspension gates, and inert state) against the architectural contracts specified in §5.6, §5.9, §5.9.1, and §8.

---

### Analysis of the 5 Checklist Areas

#### 1. Epoch Bump Sites & C API Exemptions (§5.6, §5.9.1)
- **Bump Sites Covered**:
  - [`Vm.callValue`](file:///home/bart/Projects/lune/src/interp.zig#L2372): Bumped after native reentry depth check (`self.heap.bumpHostEpoch()`). Covers metamethod dispatches (`__index`, arithmetic metamethods) and `pcall`.
  - [`Vm.execWithEntry`](file:///home/bart/Projects/lune/src/interp.zig#L2924): Bumped at the top of chunk runs and closure calls.
  - [`Vm.collect`](file:///home/bart/Projects/lune/src/interp.zig#L2528): Bumped after `self.heap.beginCollect()`.
  - [`Heap.deflateGrid`](file:///home/bart/Projects/lune/src/gc.zig#L381): Bumped after the array replacement swap.
  - [`capi.bumpEpoch`](file:///home/bart/Projects/lune/src/capi.zig#L430): Invoked in all non-exempt C API functions: `mh_collect`, `mh_compile`, `mh_run`, `mh_eval`, `mh_call`, `mhCallViaH1`, `mh_global_get`, `mh_global_set`, `mh_ref_create`, `mh_ref_free`, `mh_register_fn`, `mh_table_get`, `mh_table_set`, `mh_table_len`, `mh_table_metatable_get`, `mh_table_metatable_set`, `mh_table_iter_new`, `mh_table_iter_next`, and `mh_table_iter_free`.
- **Exemptions Soundness**:
  - Pure value constructors and readers (`mh_nil`, `mh_bool`, `mh_int`, `mh_float`, `mh_value_*`): Sound; do not touch heap state or the VM.
  - `mh_error_set`: Sound; stages text in `box.host_error` (the box allocator, outside the GC heap).
  - `mh_ref_get`: Sound; reads a host ref slot in `box.vm.host_refs`.
  - `mh_string_new`, `mh_table_new`: Sound; allocate fresh objects without modifying existing objects; accounted for by `guard_host_epoch`'s allocation budget check ($A_{\text{rem}}$).
  - Box-side readers/clearers (`mh_last_error`, `mh_output`, `mh_output_clear`, `mh_warnings`, `mh_warnings_clear`, `mh_mem_stats_get`): Sound; operate strictly on `VmBox` diagnostic/buffering structures.
  - `mh_script_free`: Sound; frees the box-side wrapper handle `ScriptBox`, while the proto image remains VM-owned in `loaded_chunks`.
  - `mh_vm_new`, `mh_vm_free`: Sound; `mh_vm_new` creates a new VM; `mh_vm_free` refuses (`.err_api`) if `depth != 0`, preventing mid-callback destruction while keeping epoch untouched.

#### 2. Gate Placement & Canonical Instruction Execution (§5.9)
- **Gate Placement**:
  - [`onBackEdge`](file:///home/bart/Projects/lune/src/trace.zig#L3420): `if (self.suspended()) return;` sits at the very top, before any state inspection, recording closure, or side-trace arming.
  - [`backEdgeEpilogue`](file:///home/bart/Projects/lune/src/interp.zig#L7349-L7352): `eligible` checks `!self.trace.suspended()`. Trace entry is bypassed before candidate selection, fingerprint checks, or unpatch work.
  - [`opJForLoop`](file:///home/bart/Projects/lune/src/interp.zig#L6140-L6214) & [`opJLoop`](file:///home/bart/Projects/lune/src/interp.zig#L6274-L6323): Both check `suspended` before `!patch.live` (skipping `unpatchSlot`), execute the canonical loop step exactly once, and on a taken back-edge tail-call `backEdgeHandler(mode)` with `&patch.orig`, taking the virgin cascade without touching the patch.
  - [`opJFuncHead`](file:///home/bart/Projects/lune/src/interp.zig#L6388-L6390) & [`opJCont`](file:///home/bart/Projects/lune/src/interp.zig#L6501-L6503): Both check `self.trace.suspended()` before `!patch.live` and tail-call the canonical instruction handler at `&st.proto.code[cur_pc]` directly, executing the canonical instruction once and preserving straight-line execution into `proto.code`.
  - [`dispatchPostObserve`](file:///home/bart/Projects/lune/src/interp.zig#L3356): `const jit_live = mode == .full and !self.trace.suspended();` guards steps (8) `maybeCloseAtAnchor`, (9) `maybeStartContinuation`, (10) `maybeStartReplaySide`, (10b) `maybeStartHead`, (10c) `maybeStartCont`, and (11) `recordInstr`. None run when suspended.
  - [`onCallEntry`](file:///home/bart/Projects/lune/src/trace.zig#L3582) & [`onRetResume`](file:///home/bart/Projects/lune/src/trace.zig#L3648): Both exit immediately if `self.suspended()` before checking `hasTrace` or repatching (which would trigger drains).
  - [`clearPendingExitAnchor`](file:///home/bart/Projects/lune/src/trace_link.zig#L327): Returns early if `self.suspended()`, preserving exit and replay anchors set by outer frames.
  - [`abortRaised`](file:///home/bart/Projects/lune/src/trace.zig#L3187): Does not abort active outer recordings while suspended.
  - **Assertions**: [`startRecording`](file:///home/bart/Projects/lune/src/trace.zig#L3148), [`arm`](file:///home/bart/Projects/lune/src/trace_link.zig#L1938), and [`drainEntryPatchWork`](file:///home/bart/Projects/lune/src/trace_link.zig#L2585) assert `!self.suspended()`.

#### 3. Reachable Ungated JIT-State Mutations
- Aside from the region-accounting gap documented in §5.9.1 (`observeRegionProgramPoint`, `dropRegionActivation`, `dropRegionActivationsFromDepth`, and `setRegionContext`), only one minor write to a `TraceState` field is reachable:
  - [`self.trace.pending_anchor_base = st.base;`](file:///home/bart/Projects/lune/src/interp.zig#L7327) in `backEdgeEpilogue` runs prior to `onBackEdge` (which returns early when suspended). (See Finding 4).

#### 4. Test Coverage & Unsuspended Controls
- `capi_epoch_test.zig`: Tests 18 C API entries, non-C-API bump sites (`callValue`, `indexGet`, `collect`, `deflateGrid`), and `disturbs` accounting (pure, allocating, callback success/failure in both funnels, saturation, staged errors).
- `capi_suspend_test.zig`: Tests loop and head recording suppression, trace entry prevention with all 4 patch kinds installed, pending unpatch survival, and pending exit anchor preservation.
- **Gaps Identified**:
  - `test "doc 63 suspend: abortRaised leaves an active recording to its owner while suspended"` lacks an unsuspended control.
  - `mhCallViaH1` is not tested in `capi_epoch_test.zig`.
  - `mh_vm_new` and `mh_vm_free` lack explicit `expectExempt` assertions in `capi_epoch_test.zig`.

#### 5. Honesty of §5.9.1 Cost Accounting
- The reported +11 instructions per host call is honest and accurate.
- Inlined [`callHostNative`](file:///home/bart/Projects/lune/src/interp.zig#L2307) introduces two live variables (`epoch: u64` and `nat: *Native`) that must be preserved across the foreign C call `hb.call(...)`. Under the C ABI, this increases callee-saved register pressure and forces spills/reloads across `opCall`'s argument/result marshalling and frame management.
- The standard `bench/` suite shows neutral performance (+0.22% to -1.58% across tier-0/JIT), consistent with compile-time code alignment variation.

---

### Numbered Findings

#### Finding 1: Missing Unsuspended Control in `abortRaised` Test
- **Severity**: Should-fix
- **Location**: [`src/capi_suspend_test.zig:217-229`](file:///home/bart/Projects/lune/src/capi_suspend_test.zig#L217-L229)
- **Description**: While Tests 1–4 in `capi_suspend_test.zig` pair their suspended runs with an unsuspended control, Test 5 (`"doc 63 suspend: abortRaised leaves an active recording to its owner while suspended"`) only asserts that `tr.rec.active` remains `true` when `tr.suspend_depth = 1`. It does not execute the unsuspended counterpart (`tr.suspend_depth = 0; tr.abortRaised();`) to verify that `abortRaised` actually clears `tr.rec.active` under normal execution.

#### Finding 2: `mhCallViaH1` Omitted from `capi_epoch_test.zig`
- **Severity**: Should-fix
- **Location**: [`src/capi_epoch_test.zig:94-206`](file:///home/bart/Projects/lune/src/capi_epoch_test.zig#L94-L206)
- **Description**: §5.9.1 specifically lists `mhCallViaH1` among the C API entries that bump `host_epoch`:
  > *"capi.bumpEpoch, first thing in every non-exempt C API entry: mh_collect, mh_compile, mh_run, mh_eval, mh_call and its doc 60 hand-written path (mhCallViaH1)..."*
  
  While [`capi.mhCallViaH1`](file:///home/bart/Projects/lune/src/capi.zig#L797) correctly contains `bumpEpoch(box);`, `capi_epoch_test.zig` only tests `mh_call` and does not call `mhCallViaH1` in `expectBumps`.

#### Finding 3: `mh_vm_new` and `mh_vm_free` Lack Tests in `capi_epoch_test.zig`
- **Severity**: Should-fix
- **Location**: [`src/capi_epoch_test.zig:208-282`](file:///home/bart/Projects/lune/src/capi_epoch_test.zig#L208-L282)
- **Description**: §5.9.1 claims:
  > *"Exemptions added beyond §5.6's table. Each has its argument in code and a test (`capi_epoch_test.zig`): ... `mh_vm_new`, `mh_vm_free`"*
  
  Although `mh_vm_new` and `mh_vm_free` are used in test setup/teardown helpers (`newVm`/`freeVm`), they are not tested in `test "doc 63 epoch: the exempt C API entries leave it alone"` using `expectExempt`. Specifically, testing that `mh_vm_free` on an active VM (`depth != 0`) returns `.err_api` while leaving `host_epoch` unchanged would validate the exemption contract.

#### Finding 4: Ungated Write to `pending_anchor_base` in `backEdgeEpilogue`
- **Severity**: Nit
- **Location**: [`src/interp.zig:7327`](file:///home/bart/Projects/lune/src/interp.zig#L7327)
- **Description**: In `backEdgeEpilogue`:
  ```zig
  if (!self.trace.skipBackEdge(proto, anchor_pc)) {
      self.trace.pending_anchor_base = st.base;
      self.trace.onBackEdge(proto, anchor_pc, regs);
  ```
  `self.trace.pending_anchor_base` is overwritten on every non-skipped back-edge prior to `onBackEdge` returning early on `self.suspended()`. This write is benign because `pending_anchor_base` is only consumed upon arming a new recording in `armWithPolicy` (which cannot run while suspended). However, guarding this write behind `if (!self.trace.suspended())` or moving it inside `onBackEdge` would maintain strict JIT-state immutability under suspension.

#### Finding 5: `hostcallReference` Lacks `bumpEpoch`
- **Severity**: Nit
- **Location**: [`src/capi.zig:907-920`](file:///home/bart/Projects/lune/src/capi.zig#L907-L920)
- **Description**: [`capi.hostcallReference`](file:///home/bart/Projects/lune/src/capi.zig#L907) is an internal test reference leg for `mh_call`. If `hostcallReference` succeeds, it calls `runProtected` $\rightarrow$ `callValue`, which bumps `host_epoch`. However, if it errors early (e.g., `checkFatal`, `badValue`, `err_oom`), `host_epoch` is not bumped. Adding `bumpEpoch(box);` at its top would keep it in exact alignment with `mh_call` and `mhCallViaH1`.

---

### Overall Verdict

**VERDICT: ACCEPT WITH MINOR TEST FIXES (GREEN / SOUND)**

The Phase 1 implementation cleanly delivers the core invariants of doc 63:
1. `Heap.host_epoch` and `Native.disturbs` accurately capture VM-boundary disturbances across both execution funnels on success and failure.
2. The suspension gates strictly protect the JIT from nested callbacks without re-entry hazards, double execution of canonical bytecode instructions, or patch corruption.
3. The region accounting gap is properly isolated and documented for Phase 2c.
4. The performance budget analysis in §5.9.1 is transparent and rigorously substantiated.
5. Addressing Findings 1, 2, and 3 will close all test gaps against §5.9.1's documentation before landing.
