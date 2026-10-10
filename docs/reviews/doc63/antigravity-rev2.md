APPROVE WITH CHANGES

---

### Round 1 Dispositions Verification

Revision 2's pivot to forcing precise mode ([doc 45](file:///home/bart/Projects/lune/docs/design/45-table-effects-and-precise-deopt.md)) for host calls cleanly resolves the fundamental execute-once dilemmas that plagued revision 1:

1. **Loop-done exits**: **Resolved**. In precise mode, loop-done exits bypass [trace_exit_attach.zig](file:///home/bart/Projects/lune/src/trace_exit_attach.zig#L351) completely and ride the resume materializer to `for_loop` bytecode ([nativegen.zig:2532-2563](file:///home/bart/Projects/lune/src/nativegen.zig#L2532-L2563), tested in [interp_trace_test.zig:6741](file:///home/bart/Projects/lune/src/interp_trace_test.zig#L6741)). Tier-0 tests loop completion and terminates without re-running the body.
2. **Sibling handoff & `.ordinary_guard` arms**: **Resolved**. Precise pages categorically refuse link arming ([trace_link.zig:2011](file:///home/bart/Projects/lune/src/trace_link.zig#L2011)), and precise native exit stubs bypass all slot checking and patch windows ([nativegen.zig:2515-2563](file:///home/bart/Projects/lune/src/nativegen.zig#L2515-L2563)). Adding `call_host` to [`isStateEffectOp`](file:///home/bart/Projects/lune/src/trace_ir.zig#L872) provides an additional independent defense.
3. **Leaf host functions reading stale slab**: **Resolved in principle**. §5.10 specifies marshaling arguments from current SSA values into an on-stack array, and running cold materialization on error (see Finding 3 below for two implementation details).
4. **In-flight frame PC breaking GC masking**: **Resolved**. §5.4 sets `frames[depth-1].pc = B` and `in_flight = true` during the call, matching [doc 61 §4.2](file:///home/bart/Projects/lune/docs/design/61-gc-liveness-masking.md) and [`interp.zig:6718-6719`](file:///home/bart/Projects/lune/src/interp.zig#L6718-L6719).
5. **`mh_table_get` running `__index`**: **Resolved**. The epoch boundary is drawn at the VM boundary (§5.5), including all guest reentry, metamethod dispatches, and table/grid mutations.
6. **Nested episodes clobbering `TraceState` and `NativeSeedCtx`**: **Resolved**. §5.8 suspends the JIT (`suspend_depth > 0`) during callbacks from trace-called host functions, confining nested execution to tier-0.
7. **Performance budget**: **Resolved**. §8 splits the budget into minimal loops (≤250 instrs) and wide windows (≤320 instrs), marked provisional pending Phase 0.
8. **Epoch guard IR and snapshot**: **Resolved**. `guard_host_epoch site` is introduced with an empty snapshot at `B + 1` (see Finding 1 below).

---

### Soundness Analysis of New Components

- **Empty-snapshot epoch exit (§5.5)**: **Sound in design**. Because the pre-call materializer flushed the slab at `B`, the shim wrote results to `regs[a ..]`, and callbacks may have written open upvalues in `regs`, the slab is already authoritative. An empty snapshot avoids clobbering callback mutations with stale SSA values. (Needs validator and recorder specification; see Finding 1).
- **GC-budget recheck (§5.5)**: **Sound in design**. Allocations inside the C API (e.g. [`mh_string_new`](file:///home/bart/Projects/lune/src/capi.zig#L990)) advance `heap.object_count` without triggering collection. Checking remaining budget at `guard_host_epoch` ensures that if headroom is depleted, execution exits `.precise_resume` to `B + 1` where tier-0's prologue safely triggers [`vm.collect()`](file:///home/bart/Projects/lune/src/interp.zig#L3053). (Needs formula and whitelist reconciliation; see Finding 2).
- **JIT suspension during nested execution (§5.8)**: **Sound**. Completely avoids state collisions in [`NativeSeedCtx`](file:///home/bart/Projects/lune/src/trace_code.zig#L249), `touched[]`, and `ledger_scratch`. Suspending trace retirement during `suspend_depth > 0` ensures outer traces on the C stack are not collected.
- **Protected span & root-set argument (§5.4)**: **Sound**. Setting `stack_top` to `base + count` ensures nested callback frames lay out strictly above seed slots. Because seed slots contain copies of globals, proto constants, or upvalue cells already reachable in tier-0, and raw upvalue seeds carry integer tags ignored by the GC, the reachable set under the trace is identical to tier-0.
- **Leaf path (§5.10)**: **Sound in principle**, though several lowering details remain unstated (see Finding 3). Deferring leaf functions past v1 (per Q3) is strongly recommended.

---

### Findings

#### 1. [should-fix] Snapshot validation and recorder minting for the empty epoch snapshot
- **Evidence**:
  1. [`trace_snapshot.validate`](file:///home/bart/Projects/lune/src/trace_snapshot.zig#L247) strictly checks:
     ```zig
     if (s.slots_len != s.register_count) return false; // v1: full window only
     ```
     An empty snapshot has `slots_len == 0` while `register_count == proto.num_registers`. As written, [`trace_finalize`](file:///home/bart/Projects/lune/src/trace_finalize.zig#L247-L248) will reject any trace containing `guard_host_epoch` with `error.InvalidSnapshotMetadata`.
  2. In [`trace_recorder.zig:1493-1504`](file:///home/bart/Projects/lune/src/trace_recorder.zig#L1493-L1504), `snapBoundary(pc)` mints a full-window snapshot for the current bytecode `B` (`cur_snap`). `call_host` uses `cur_snap` (resuming at `B`). `guard_host_epoch` cannot inherit `cur_snap` (which would resume at `B` and re-run the host call).
- **Concrete Fix**:
  - Amend [`trace_snapshot.validate`](file:///home/bart/Projects/lune/src/trace_snapshot.zig#L247) to allow empty snapshot vectors: `if (s.slots_len != 0 and s.slots_len != s.register_count) return false;`.
  - In §5.1 / §5.2, explicitly specify that the recorder mints a dedicated snapshot record with `resume_pc = B + 1` and `slots_len = 0` specifically for `guard_host_epoch`.

---

#### 2. [should-fix] GC-budget recheck formula, operand storage, and whitelist contradiction
- **Evidence**:
  1. §5.5 line 328 gives a conservative whitelist of non-bumping C API accessors: "`mh_value_*` scalar reads, `mh_value_str`, `mh_error_set`, `mh_ref_get`". It omits [`mh_string_new`](file:///home/bart/Projects/lune/src/capi.zig#L990). However, line 333 states "`mh_str_new` and other allocations do not bump it, but they spend the `guard_gc` budget". If [`mh_string_new`](file:///home/bart/Projects/lune/src/capi.zig#L990) is not on the whitelist, it bumps `host_epoch`, causing any host call creating a string to deopt.
  2. §5.1 / §5.5 states `guard_host_epoch` checks that "the trace's remaining allocation budget still holds", but does not specify where the post-call remaining allocation bound $A_{\text{rem}}$ is stored or how the check is structured.
- **Concrete Fix**:
  - Add [`mh_string_new`](file:///home/bart/Projects/lune/src/capi.zig#L990) to the non-bumping whitelist in §5.5 (and fix the `mh_str_new` typo).
  - Specify that the recorder calculates the remaining worst-case allocation bound $A_{\text{rem}}$ from $B + 1$ to the back-edge, stores it in `guard_host_epoch` (via `ins.aux` or `site`), and lowers the check as `!heap.gc_stress and (heap.object_count +| A_rem) < heap.next_gc`.

---

#### 3. [should-fix] Leaf host function result handling and cold-path error invariants
- **Evidence**:
  1. §5.10 specifies argument marshaling from SSA into an on-stack array, but does not define how results are returned. In the standard path, the shim writes results to `regs[a ..]`, and `host_result` reads from the slab. If §5.10 skips the shim, the result passing convention between the C function and native code is undefined.
  2. §5.10 skips pre-call frame writes (`pc = B`, `in_flight = true`, `stack_top`). If a leaf call fails and enters the cold materializer before raising `.precise_error`, `frames[depth-1]` will have stale `pc` and `!in_flight`. When the catcher or an `xpcall` handler receives the error, doc 61 frame shape classification will see an un-marked frame.
- **Concrete Fix**:
  - In §5.10, specify that the leaf invocation either passes a small stack buffer and copies results to `regs[a ..]`, or calls a minimal leaf shim that does so.
  - Specify that on leaf failure, the cold path updates `frames[depth-1].pc = B`, sets `in_flight = true`, and raises `stack_top` alongside running the materializer before dispatching `.precise_error`.

---

#### 4. [nit] Pinned ordinals for extended `.precise_error` Status enum
- **Evidence**:
  - [`table_runtime.Status`](file:///home/bart/Projects/lune/src/table_runtime.zig#L9-L14) has comptime-pinned ordinals (`ok = 0`, `out_of_memory = 1`, `type_error = 2`).
  - §5.7 introduces `lua_error` and `stack_overflow` without assigning explicit integer ordinals for the C-ABI callout return and native stub decoding.
- **Concrete Fix**:
  - Assign explicit ordinals (e.g. `lua_error = 3`, `stack_overflow = 4`) and require extending the status ABI ordinal test in `table_runtime.zig`.

---

#### 5. [nit] Default kind for unguarded `host_result` SSA refs
- **Evidence**:
  - §5.1 defines `host_result site, k`. If a guest program discards a host result (`local _ = host_call()`) or passes it without type specialization, `host_result` will not be followed by a type guard.
- **Concrete Fix**:
  - Specify that `proveKinds` classifies an unguarded `host_result` ref as `.boxed`, lowered by loading both tag byte and payload from the slab.

---

### Recommendations on Open Questions

- **Q1 (Amend doc 00/02 barrier commitment)**: **Yes**. Amend both docs to define host calls as execute-once effects permitted in precise traces.
- **Q2 (JIT suspension in v1)**: **Yes**. Suspending the JIT (`suspend_depth > 0`) during re-entrant callbacks is robust, isolates per-VM episode state, and avoids complex episode cloning.
- **Q3 (Leaf host functions)**: **Defer to Phase 4 (post-v1)**. The standard path with precise deopt covers all use cases soundly; leaf specialization can land once the primary funnel is measured.
- **Q4 (Count against `max_native_reentry`)**: **Yes**. Ensures `host_out` buffer sizing holds and bounds recursion.
- **Q5 (Multret arguments/results)**: **Defer to past v1**. Fixed-count arguments and results match the existing precise mode admission profile.
