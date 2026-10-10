# Antigravity — §5.10.1 "As landed" review (round 1, 2026-10-11)

Verbatim reply. Dispositions in `aslanded-dispositions.md`.

---

# Design-Doc Review: `docs/design/63-trace-host-calls.md` (§5.10.1 "As landed", Prerequisite B)

**Verdict:** **APPROVE**

The uncommitted changes to [`docs/design/63-trace-host-calls.md`](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md) accurately record the landed state of doc 61 Phase Q (`f1ea468` … `b462369`) and Phase 1 (`0225b4d`). All factual claims in §5.10.1 are verified against the codebase, and the architectural reasoning integrates cleanly with doc 63 §5.3, §5.5, §5.7, §5.9, and §5.10.

---

## 1. Verification of Factual Claims in §5.10.1

### 1.1 F1 Needs No New Code
- **Claim:** Finalize indexes every heap value in the pool into `heap_consts` ([`src/trace_finalize.zig`](file:///home/bart/Projects/lune/src/trace_finalize.zig#L246-L257)), not only strings; `Native` is a heap object; `guard_native`'s constant is scanned by `invalidateDeadTraceConsts` as soon as it is in the pool.
- **Verification against code:**
  - In [`src/trace_finalize.zig`](file:///home/bart/Projects/lune/src/trace_finalize.zig#L246-L257), `heap_consts` is built by iterating over `fields.consts` and including every constant where `v.isHeap()` is true.
  - In [`src/value.zig`](file:///home/bart/Projects/lune/src/value.zig#L149-L151), `v.isHeap()` checks `self.tag == .heap_ref`.
  - In [`src/object.zig`](file:///home/bart/Projects/lune/src/object.zig#L22), `ObjectType.native` is a heap object type; [`Native`](file:///home/bart/Projects/lune/src/function.zig#L343) in [`src/function.zig`](file:///home/bart/Projects/lune/src/function.zig#L343-L345) embeds `header: GcHeader`. A `Value` wrapping a `*Native` has tag `.heap_ref`.
  - In [`src/interp.zig`](file:///home/bart/Projects/lune/src/interp.zig#L2563-L2573), `invalidateDeadTraceConsts` scans every index in `t.code.heap_consts` with `gc.Heap.willFree(t.code.consts[i].asHeap())`. In [`src/gc.zig`](file:///home/bart/Projects/lune/src/gc.zig#L689-L692), `Native` is treated as a leaf heap object (`.native => {}`).
  - **Verdict:** **Verified.**

### 1.2 What is Already Split, and What is Not
- **Claim:** `removeTraces` ([`src/trace_link.zig`](file:///home/bart/Projects/lune/src/trace_link.zig#L2391-L2463)) runs Phase Q's steps 2–7 as one transaction: `doomed` bit, relation/want drops, unpublishing (cache compaction, `trace_by_id`, anchor index, entry patches marked non-live and pending), anchor reopening, `destroyDoomed`, and graph rebuilds. Step 8 (entry-patch drain) runs at the next safe point; non-live patches dispatched before it take the §R6-1 recovery arm ([`docs/design/61-gc-liveness-masking.md`](file:///home/bart/Projects/lune/docs/design/61-gc-liveness-masking.md#L1370-L1385)).
- **Verification against code:**
  - In [`src/trace_link.zig`](file:///home/bart/Projects/lune/src/trace_link.zig#L2391-L2463), `removeTraces`:
    - Step 2: marks `t.doomed = true` (line 2402).
    - Step 3 (logical): drops provenance edges, wants, exec logs (lines 2421–2423).
    - Steps 3 (physical) & 4: calls `self.registry.unpublishDoomed(doomed)` (line 2426), which resets links touching doomed, marks entry patches pending (`owner_retired = true`, `p.live = false`, `p.trace = undefined`), unlinks anchors, clears `trace_by_id`, and compacts `cache`.
    - Step 5: reopens empty anchors (lines 2440–2453).
    - Step 6: calls `self.registry.destroyDoomed(doomed)` (line 2455).
    - Step 7: calls `syncNativeInvalidation()`, `rebuildEdgeCache()`, `rebuildRegions()` (lines 2460–2462).
  - Step 8 ([`drainEntryPatchWork`](file:///home/bart/Projects/lune/src/trace_link.zig#L2602)) is *not* called inside `removeTraces`; it runs at dispatch safe points (e.g. [`src/interp.zig:5712`](file:///home/bart/Projects/lune/src/interp.zig#L5712), [`:7464`](file:///home/bart/Projects/lune/src/interp.zig#L7464), [`:7511`](file:///home/bart/Projects/lune/src/interp.zig#L7511)).
  - The four patched entry handlers (`jfor_loop`, `jwhile_loop`, `jfunc_head`, `jcont` in [`src/interp.zig:6160`](file:///home/bart/Projects/lune/src/interp.zig#L6160), [`:6274`](file:///home/bart/Projects/lune/src/interp.zig#L6274), [`:6375`](file:///home/bart/Projects/lune/src/interp.zig#L6375), [`:6481`](file:///home/bart/Projects/lune/src/interp.zig#L6481)) all check `if (!patch.live)` and run `self.trace.unpatchSlot(slot)` (the §R6-1 recovery arm).
  - **Verdict:** **Verified.**

### 1.3 Collection Inside a Recording-Time Callback Cancelling the Recording
- **Claim:** `invalidateDeadTraceConsts` cancels an active recording that names a swept constant via `cancelRecording(.const_swept)`. During a recording-time host call, the recording is cancelled before the next instruction hook. Phase 2c keeps pending host-call state in `RecordingSession`.
- **Verification against code:**
  - In [`src/interp.zig`](file:///home/bart/Projects/lune/src/interp.zig#L2553-L2560):
    ```zig
    if (ts.isRecording()) {
        for (ts.rec.consts.items) |v| {
            if (v.isHeap() and gc.Heap.willFree(v.asHeap())) {
                ts.cancelRecording(.const_swept);
                break;
            }
        }
    }
    ```
  - In [`src/trace.zig`](file:///home/bart/Projects/lune/src/trace.zig#L3731-L3736), `cancelRecording` invokes `self.rec.cancel(reason)`, clearing the active recording state (`syncRecordingBit()`).
  - When tier-0 resumes after the callback and reaches the next instruction, `ts.isRecording()` is already `false`. Keeping pending host-call state on `RecordingSession` ensures it is cleanly discarded upon cancellation.
  - **Verdict:** **Verified.**

### 1.4 Collections Scrub Dead Registers
- **Claim:** `collect` nils registers below `stack_top` that the masked walk did not keep (`scrubDeadRegisters`), after invalidation and before sweep. Anchor frame is `in_flight` at `B`, masked with `live_in[B]` up to `num_registers`; seeds are above `stack_top` (unscrubbed); scrub implies collection moving `host_epoch`, triggering coherent exit.
- **Verification against code:**
  - In [`src/interp.zig`](file:///home/bart/Projects/lune/src/interp.zig#L2536-L2538), the sequence in `collect` is:
    ```zig
    self.invalidateDeadTraceConsts();
    self.scrubDeadRegisters();
    self.heap.sweep();
    ```
  - In [`src/interp.zig`](file:///home/bart/Projects/lune/src/interp.zig#L2613), `frameShape` returns `.{ .kind = .in_flight, .pc = f.pc }` when `f.in_flight == true`.
  - In [`src/interp.zig`](file:///home/bart/Projects/lune/src/interp.zig#L2669-L2675), `frameMask` for `.in_flight` checks:
    ```zig
    const ins = proto.code[shape.pc];
    break :blk if (ins.op == .call and ins.b == bytecode.all_results) f.multret_top else nreg;
    ```
    For a fixed-count call (`ins.b != all_results`), `limit` is `nreg = proto.num_registers`, and the mask row is `proto.reg_live.row(B)` (`live_in[B]`).
  - In [`src/interp.zig`](file:///home/bart/Projects/lune/src/interp.zig#L2733-L2744), `scrubDeadRegisters` operates strictly on `[0, self.stack_top)`.
  - Seeds reside at slab offsets beyond `proto.num_registers` ([`src/trace_code.zig:162`](file:///home/bart/Projects/lune/src/trace_code.zig#L162), [`src/interp.zig:1396-1400`](file:///home/bart/Projects/lune/src/interp.zig#L1396-L1400)), which lie above `stack_top` during a fixed-count call ([`docs/design/63-trace-host-calls.md#L482-L485`](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md#L482-L485)).
  - **Verdict:** **Verified.**

### 1.5 F3 Assertion Home
- **Claim:** `invalidateDeadTraceConsts` documents "no trace code is on the stack here". Phase 2b replaces this comment with the restated F3 assertion.
- **Verification against code:**
  - In [`src/interp.zig`](file:///home/bart/Projects/lune/src/interp.zig#L2545-L2548), the doc-comment explicitly states:
    > "No trace code is on the stack here (collection runs only at the tier-0 safepoint or from `mh_collect`), so nothing observes the retirement mid-flight."
  - **Verdict:** **Verified.**

---

## 2. Coherence and Reasoning Against Doc 63

The reasoning in §5.10.1 holds across all cited sections of doc 63:

1. **The Scrub Argument (§5.5, §5.7, §5.10):**
   - At call setup, the trace sets `frames[depth-1].pc = B` and `in_flight = true`.
   - If a collection runs inside a host callback:
     - The anchor frame is masked with `live_in[B]` up to `num_registers`. Dead registers in `[0, stack_top)` are scrubbed to `nil` by `scrubDeadRegisters`.
     - Seeds lie above `stack_top`, so they are neither walked as roots nor scrubbed.
     - The collection bumps `Heap.host_epoch` (§5.6).
     - Upon return to compiled code, `guard_host_epoch` fails and exits via `C_B1`.
     - `C_B1` is slab-coherent (`coherent = true`, `slots_len = 0`), writing nothing back to registers.
     - Tier-0 resumes at `B + 1` with the exact scrubbed register state that tier-0 would have produced.
   - If no collection ran during the call:
     - No scrub occurred, and `host_epoch` is unchanged.
     - Pre-call values held in registers/spill slots across the call are read only after `guard_host_epoch` passes.
     - Because `guard_host_epoch` passed, no collection (and thus no scrub) occurred, upholding §5.7's safety proof.

2. **The Recording-Cancel Argument (§5.3, §5.9):**
   - When a host call occurs during trace recording, the host call executes in tier-0 with suspension enabled (`suspend_depth > 0`).
   - If a collection occurs and frees a constant held in the active recording's pool, `invalidateDeadTraceConsts` calls `cancelRecording(.const_swept)`.
   - The recording session is terminated immediately. By placing pending host-call state inside `RecordingSession`, the cancellation automatically cleans up this state, preventing leaks or dangling hooks when tier-0 reaches the next bytecode instruction.

3. **Boundary of the Logical/Physical Split (§5.10):**
   - Doc 61 Phase Q as landed already deferred Step 8 (`drainEntryPatchWork`) to dispatch safe points.
   - The logical half (marking `doomed = true`, unpublishing from cache/id/anchor tables, marking entry patches non-live and pending) must run immediately at the sweep to ensure later collections in the same callback do not scan freed constants.
   - The physical half that must be deferred until the release point (`entry_leases == 0 && suspend_depth == 0`) is at minimum `destroyDoomed` for leased or suspended trace records, avoiding use-after-free while execution unwinds.

---

## 3. Analysis of Landed Code Interactions

No landed changes from Phase Q (`f1ea468` … `b462369`) or Phase 1 (`0225b4d`) invalidate the design of doc 63. Key architectural assumptions were cross-checked:
- **`Proto.maskable` Gating:** Phase 1 added `Proto.maskable` gating for store-elision sites. Precise traces do not use store sinking (they are dupe-only, materializing all window slots at bytecode boundaries), so this does not conflict with coherent snapshots or host-call preflushes.
- **`CallFrame.multret_top` (Option B):** Phase 1 introduced `CallFrame.multret_top` to clamp masked ranges for multret consumers. Doc 63 v1 restricts host calls to fixed-count returns (Decision Q5 / §5.3), so `ins.b != bytecode.all_results` applies and `num_registers` is used, leaving the design unaffected until Q5 is addressed.
- **Entry Patch Poisoning (`patch.trace = undefined`):** In [`src/trace_registry.zig:205`](file:///home/bart/Projects/lune/src/trace_registry.zig#L205), `unpublishDoomed` poisons `patch.trace = undefined`. In [`src/interp.zig:5445`](file:///home/bart/Projects/lune/src/interp.zig#L5445), `enterPatchedTrace` reads `const ct = patch.trace` *before* entering the trace and never reads `patch.trace` again upon return. The dispatcher's borrow `TraceState.executing` (`ct`) is held directly rather than through `patch.trace`.

---

## 4. Findings and Observations

### Finding 1: Slot mutation location in `unpublishDoomed`
- **Severity:** Informational / Implementation Note
- **Details:** §5.10.1 states:
  > "Phase 2b decides where the slot rewrites and the graph rebuilds fall, using the facts that a precise page never links (so the suspended trace's own slots are never rewritten) and that nothing enters a trace while suspended."
  In the current implementation, slot rewrites ([`resetLinksTouchingDoomed`](file:///home/bart/Projects/lune/src/trace_native_registry.zig#L740)) are called directly on line 197 of [`src/trace_registry.zig:unpublishDoomed`](file:///home/bart/Projects/lune/src/trace_registry.zig#L197). If Phase 2b chooses to treat slot rewrites as part of the deferred physical half, `resetLinksTouchingDoomed` will need to be extracted from `unpublishDoomed`. If Phase 2b decides slot rewrites can run immediately (since precise traces never link and no code enters traces while suspended), `resetLinksTouchingDoomed` can remain inside `unpublishDoomed`.

### Finding 2: `Native` constant testing in Phase 2b
- **Severity:** Informational
- **Details:** As noted in §5.10.1, `heap_consts` already indexes all heap objects (`v.isHeap()`). However, `guard_native` is not introduced until Phase 2c. Thus, the Phase 2b test verifying that a dying `Native` retires its guarding trace will either need a manually constructed trace pool or will validate F1 integration as part of Phase 2c's recording pipeline.

---

## Conclusion

The diff in [`docs/design/63-trace-host-calls.md`](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md) accurately documents the landed dependencies, resolves Prerequisite B, and establishes a sound foundation for Phase 0 and Phase 2b. The change is **APPROVED**.
