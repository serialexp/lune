APPROVE WITH CHANGES

---

### Verification of Round 4 Dispositions & §5.5 Invariant

Revision 5 resolves the five round-4 findings from Codex and four from Antigravity:

1. **Stack Limit Preservation & Seed Rooting (Codex 1)**: **Verified sound**. Seeds are no longer protected by artificially raising `stack_top`. Leaving seeds above `stack_top` preserves the fixed 64K stack capacity limit ([`interp.zig:125`](file:///home/bart/Projects/lune/src/interp.zig#L125), [`:2122`](file:///home/bart/Projects/lune/src/interp.zig#L2122)) for callbacks and `xpcall` handlers. Because the GC root walk explicitly halts at `self.stack_top` ([`interp.zig:2595`](file:///home/bart/Projects/lune/src/interp.zig#L2595)), unrooted seeds above `stack_top` cannot root values tier-0 would collect, nor become rooted gaps on error unwind (§5.5).
2. **Physical Retirement Gating via Borrow Leases (Codex 2)**: **Resolved**. Introducing `TraceState.entry_leases` ([`interp.zig:5339`](file:///home/bart/Projects/lune/src/interp.zig#L5339), [`:5484`](file:///home/bart/Projects/lune/src/interp.zig#L5484)) and requiring both `suspend_depth == 0` and `entry_leases == 0` ensures physical destruction and patch reuse are deferred while `enterPatchedTrace` or post-entry handlers still access `patch` (§5.10).
3. **Recording-Time Release Point (Codex 3, AG 2)**: **Resolved**. Adding `callHostNative` lowering `suspend_depth` to 0 with `entry_leases == 0` as an explicit physical release point guarantees that retirements queued during tier-0 recording callbacks do not leak or orphan (§5.10).
4. **Trace Owner Borrow & Callee Resolution (Codex 4, AG 1)**: **Resolved**. The dispatcher publishes `TraceState.executing = ct` prior to execution, which the shim borrows for `TraceState.suspended_trace`. Reading the callee directly from the preflushed slab via `regs[ctx.base + site.a]` eliminates `callee_k` from `HostCallSite` and avoids fragile registry lookups (§5.1, §5.8).
5. **Instruction Pointer Provenance in Patched Bypass (Codex 5)**: **Resolved**. Head and continuation handlers correctly specify `&st.proto.code[cur_pc]` rather than `&patch.orig` ([`interp.zig:6134`](file:///home/bart/Projects/lune/src/interp.zig#L6134), [`:6246`](file:///home/bart/Projects/lune/src/interp.zig#L6246)), preserving instruction succession across straight-line dispatch (§5.9).
6. **Tier-1a Seed Context (AG 3)**: **Resolved**. `irinterp.ExecCtx` gains `seed_ctx: ?*NativeSeedCtx = null`, populated by the dispatcher from `&self.trace.seed_ctx` ([`interp.zig:4343`](file:///home/bart/Projects/lune/src/interp.zig#L4343), §5.8).
7. **`IrInstr` Operand Layout (AG 4)**: **Resolved**. Field mapping table documented in §5.1.

---

### Detailed Audit of §5.5: Slab Invariance Above `stack_top`

The §5.5 claim states:
> *"If the epoch is unchanged after the call, no guest code ran, so no frame was laid out above `stack_top`. Nothing else writes the slab above `stack_top` during a host call either: arguments are gathered into `boundary_scratch`, results go through `host_out`, the C API parks values in `parked_inline`/`parked_results` ([`capi.zig:368`](file:///home/bart/Projects/lune/src/capi.zig#L368)), and every other slab-writing operation is guest execution or collection, which bump the epoch. The seeds are intact."*

A line-by-line audit against the codebase confirms this invariant holds:
- **Invocation buffers**: Arguments are gathered into `boundary_scratch` ([`interp.zig:1532-1536`](file:///home/bart/Projects/lune/src/interp.zig#L1532-L1536)), an independent heap allocation from the register slab (`tags`/`payloads`). `callHostNative` writes results to `self.host_out` ([`interp.zig:2261-2268`](file:///home/bart/Projects/lune/src/interp.zig#L2261-L2268)), also an independent heap allocation.
- **C API Exemption List**: None of the exempt functions (`mh_nil`, `mh_bool`, `mh_int`, `mh_float`, `mh_value_type`, `mh_value_truthy`, `mh_value_int`, `mh_value_float`, `mh_value_bool`, `mh_value_str`, `mh_error_set`, `mh_ref_get`, `mh_string_new`, `mh_table_new`) touch `self.tags`, `self.payloads`, `regSet`, or any `RegWindow`. Parking writes strictly to `vm.parked_inline` or `vm.parked_results` ([`capi.zig:368-378`](file:///home/bart/Projects/lune/src/capi.zig#L368-L378)).
- **All other VM / C API writes**: Every other C API function, guest execution (`callValue`, `execWithEntry`, metamethods), and GC collection (`collect`) unconditionally advances `host_epoch`.
- **Stack bounds**: Fixed-count calls satisfy `base + a + 1 + nargs <= base + proto.num_registers == stack_top`. Seeds are allocated starting at `base + proto.num_registers` ([`trace_recorder.zig:5374-5382`](file:///home/bart/Projects/lune/src/trace_recorder.zig#L5374-L5382)). Because the GC mark loop terminates at `< self.stack_top` ([`interp.zig:2595-2599`](file:///home/bart/Projects/lune/src/interp.zig#L2595-L2599)), seeds are invisible to GC walks, and an epoch-clean host call leaves all seed slots completely unmodified.

---

### Findings

#### 1. [should-fix] Conflicting specification of who raises `TraceState.suspend_depth`

- **Evidence**:
  1. §5.8 lines 603–608 specifies that the trace shim directly manages suspension:
     - *"1. raises `TraceState.suspend_depth` (§5.9) and sets `TraceState.suspended_trace = executing` (§5.10);"*
     - *"3. lowers `suspend_depth`, clears `suspended_trace`..."*
  2. However, §5.9 lines 642–643 states:
     - *"`callHostNative` raises it for two callers: the trace shim, and tier-0 while a recording is active (so a callback cannot feed the outer recording)."*
  3. If `callHostNative` raises `suspend_depth` whenever invoked by the shim, `suspend_depth` is incremented twice (reaching 2). When `callHostNative` returns, it decrements `suspend_depth` back to 1.
  4. This conflicts with §5.10 lines 763–765, which states that `callHostNative` drains deferred retirement upon lowering `suspend_depth` to 0. It also leaves `suspend_depth` non-zero until step 3 in the shim completes.
- **Concrete Fix**:
  - Update §5.9 line 642 to clarify ownership: `callHostNative` raises/lowers `suspend_depth` **only** when invoked from tier-0 during an active recording (`self.trace.isRecording()`).
  - For traced calls, `mahina_trace_host_call` (the trace shim) exclusively owns raising/lowering `suspend_depth` alongside `suspended_trace`.

---

#### 2. [should-fix] Shim copies results from `callHostNative`'s returned slice; `callHostNative` does not write registers

- **Evidence**:
  1. §5.8 line 605 states:
     - *"calls `Vm.callHostNative`, the single funnel (E6 will log there), which writes the results to `regs[a ..]`, nil-padding up to `nwanted`;"*
  2. In [`interp.zig:2258-2271`](file:///home/bart/Projects/lune/src/interp.zig#L2258-L2271), `callHostNative` writes results to its private buffer `self.host_out` and returns a `[]const Value` slice. By architecture design ([`interp.zig:2247-2256`](file:///home/bart/Projects/lune/src/interp.zig#L2247-L2256)), `callHostNative` never touches guest register destinations or destination slots.
  3. In tier-0 ([`interp.zig:6761-6774`](file:///home/bart/Projects/lune/src/interp.zig#L6761-L6774)), the caller copies the slice from `callHostNative` into `regs[out_lo ..]` and performs nil-padding.
  4. Saying that `callHostNative` writes to `regs[a ..]` misrepresents the funnel's contract and implementation.
- **Concrete Fix**:
  - Rephrase §5.8 step 2:
    > *"calls `Vm.callHostNative`, the single funnel (E6 will log there); the shim then copies the returned slice of `host_out` into `regs[base + site.a ..]`, nil-padding up to `site.nwanted`;"*

---

#### 3. [nit] Inconsistent site index operand location across IR host operations

- **Evidence**:
  1. §5.1 lines 294–302 specifies:
     - `call_host`: `ins.a = —`, `ins.aux = site index`, `ins.snap = C_B`
     - `guard_host_epoch`: `ins.a = site index`, `ins.aux = A_rem`, `ins.snap = C_B1`
     - `host_result`: `ins.a = site index`, `ins.aux = result index`, `ins.snap = C_B1`
  2. In `call_host`, `ins.a` is unused (`—`), while `guard_host_epoch` and `host_result` place the site index in `ins.a`.
- **Concrete Fix**:
  - In §5.1, place `site index` in `ins.a` for `call_host` as well (`ins.a = site index`, `ins.aux = —` or 0), making `ins.a` consistently identify the call site across all host-related instructions.

---

### Recommendations on Open Questions (§9)

- **Q1 (Amend doc 00 and doc 02 barrier commitment)**: **Yes (Approve)**.
  Doc 45 proved execute-once effects (`tnew`) safely live in traces via precise snapshots and resume-coherent deopt. Extending this to host calls with epoch validation and slab-coherent exits preserves determinism, 8-mode equivalence, and replay while eliminating the tier-0 loop barrier.
- **Q2 (JIT suspension during callbacks in v1)**: **Yes (Approve)**.
  Per-VM native episode state ([`NativeSeedCtx`](file:///home/bart/Projects/lune/src/trace_code.zig#L249), `touched[]`, hit counters, `ledger_scratch`) is single-instance per VM. Suspending the JIT avoids nested episode state collisions without multi-episode stack frames. Paired with disturbance tracking (threshold 1), this bounds suspended execution to at most one iteration before retiring the trace.
- **Q3 (Leaf host functions in v1, later, or never)**: **Defer to Phase 4 (later)**.
  Per Rule Z-6 and Rule Z-7, land and verify the unified precise path (Phases 0–3) first. Leaf host functions are an optimization (skipping the epoch guard and suspension) and should be evaluated against Phase 0 baselines once the core path is stable.
- **Q4 (Disturbance threshold: 1 vs higher)**: **Threshold 1 (LuaJIT's rule)**.
  A host call that mutates VM state or runs callbacks causes an immediate deopt at `guard_host_epoch`. Allowing repeated iterations with a threshold > 1 causes deopt-thrashing and forces callbacks to run in tier-0 under suspension repeatedly. Threshold 1 stops tracing the native immediately on first disturbance, allowing tier-0 to run nested loops with the JIT enabled.
- **Q5 (Multret arguments and results past v1)**: **Yes (Defer)**.
  Fixed-arity calls cover embedder host-call use cases. Dynamic multret windows depend on doc 27 multret shadow mechanics and should be added after the core precise host-call mechanics are stable.
