APPROVE WITH CHANGES

---

### Round 2 Dispositions Verification

Revision 3 addresses the 13 round-2 findings from Codex and 5 findings from Antigravity with sound architectural foundations:

1. **Slab-Coherent Snapshots (Codex 1, AG 1)**: **Resolved**. Defining an explicit coherent snapshot form (`coherent: bool`, `slots_len == 0`, `register_count == proto.num_registers`) satisfies existing dispatcher assertions ([`interp.zig:4665`](file:///home/bart/Projects/lune/src/interp.zig#L4665), [`interp.zig:4700`](file:///home/bart/Projects/lune/src/interp.zig#L4700)) while bypassing materializer store loops ([`irinterp.zig:1395`](file:///home/bart/Projects/lune/src/irinterp.zig#L1395), [`nativegen.zig:2726`](file:///home/bart/Projects/lune/src/nativegen.zig#L2726)). Contiguity placement rules ensure correctness fail-closed at finalize.
2. **Callback Mutations on Host Errors (Codex 2)**: **Resolved**. Lowering `call_host` failure exits to `.precise_error` through coherent snapshot `C_B` eliminates pre-call register flushes over post-callback slab mutations.
3. **Seed Copies & Root Equality (Codex 3)**: **Resolved**. Excluded from gap-rooting via `Vm.trace_seed_span` and scrubbed during GC walk ([`61:974`](file:///home/bart/Projects/lune/docs/design/61-gc-liveness-masking.md#L974)). The epoch proof (§5.7) proves scrubbed seeds are never read because any collection moves `host_epoch`, forcing an immediate `.precise_resume` exit at `guard_host_epoch`.
4. **Weak Constants & Deferred Destruction (Codex 4)**: **Resolved**. Running logical invalidation between mark and sweep maintains guest GC timing; deferring physical destruction to `TraceState.deferred_destroy` until the executor returns prevents dangling code/pool access on reentrant collections.
5. **Suspension Gates & Recording Callbacks (Codex 5)**: **Resolved**. `callHostNative` raising `suspend_depth` during active recording isolates the recorder. The seven enumerated bypass gates ([`interp.zig:5980`](file:///home/bart/Projects/lune/src/interp.zig#L5980), etc.) cover patched and unpatched execution paths.
6. **Result-Type Tag Checks (Codex 6, AG 5)**: **Resolved**. Checking actual tags in `host_result` prior to unboxing and routing mismatches through `C_B1` preserves boxed results intact on the slab for tier-0 resume.
7. **Heap $\phi$ Homes (Codex 7)**: **Resolved**. Supported via call-site validation in `nativegen_alloc` ([`nativegen_alloc.zig:659`](file:///home/bart/Projects/lune/src/nativegen_alloc.zig#L659)) and §5.7's epoch proof.
8. **Recursion Limits Across Tiers (Codex 8)**: **Resolved**. Removing `native_reentry_depth` increments from the shim matches tier-0 dispatch ([`interp.zig:6761`](file:///home/bart/Projects/lune/src/interp.zig#L6761)).
9. **Leaf Error Locations & Cold Paths (Codex 9, AG 3)**: **Resolved**. Setting `pc = B` before leaf calls ensures `raiseLocatedError` captures the correct frame site ([`capi.zig:1130`](file:///home/bart/Projects/lune/src/capi.zig#L1130), [`interp.zig:1761`](file:///home/bart/Projects/lune/src/interp.zig#L1761)).
10. **Helper OOM Handling (Codex 10)**: **Resolved**. Tracked as Prerequisite A to fix `.precise_resume` degradation in [`irinterp.zig:845`](file:///home/bart/Projects/lune/src/irinterp.zig#L845).
11. **Disturbance Blacklist (Codex 11)**: **Resolved**. `Native.disturbs` bounds suspended nested execution to at most 1 iteration before retirement.
12. **Allocation Epoch Exemptions & Budget (Codex 12, AG 2)**: **Resolved**. Reconciled with explicit exemption table, `mh_string_new`, `mh_table_new`, and formula `!heap.gc_stress and heap.object_count +| A_rem < heap.next_gc`.
13. **Status Ordinals & Admission Boundaries (Codex 13, AG 4)**: **Resolved**. Pinned ordinals 0–4; precise limits vs. native admission separated.

---

### Findings

#### 1. [should-fix] Underspecified `site` descriptor and missing operand linkage for $S_B$ and callee `Native`
- **Evidence**:
  1. §5.1 lines 261–267 specifies the IR sequence:
     ```
     guard_native  k                  ; snapshot S_B (full, resume B)
     call_host     site               ; preflush S_B; error exit C_B
     guard_host_epoch site            ; exit C_B1; aux = A_rem
     host_result   site, 0            ; tag check, exit C_B1
     ```
  2. §5.1 lines 278–279 specifies: "`site` indexes a per-trace table of `{a, nargs, nwanted, B}`".
  3. `IrInstr` has a single `snap: SnapIdx` field ([`trace_ir.zig:816`](file:///home/bart/Projects/lune/src/trace_ir.zig#L816)). For `call_host`, `ins.snap` must be `C_B` so that failure exits take the coherent non-restoring path ([`irinterp.zig:1392`](file:///home/bart/Projects/lune/src/irinterp.zig#L1392), [`nativegen.zig:2546`](file:///home/bart/Projects/lune/src/nativegen.zig#L2546)). However, `call_host` also needs $S_B$ for the inline pre-call state materializer (§5.5). The IR op does not carry $S_B$, and `site` does not store it. Relying on lowerers to inspect the preceding op at `i - 1` is fragile and unvalidated.
  4. In `guard_native`, line 261 lists only `k` (the constant pool index), omitting the operand ref of the callee value being checked (compare with `guard_builtin` in [`irinterp.zig:762`](file:///home/bart/Projects/lune/src/irinterp.zig#L762), which uses `ins.a = callee_ref`).
  5. On an epoch exit from `guard_host_epoch`, §5.9 line 603 states: *"When a trace's epoch exit finds its site's native has reached the threshold, the dispatcher retires the trace"*. However, `regs[a ..]` was already overwritten with the host call's return values by `cHostCall` ([`interp.zig:6767`](file:///home/bart/Projects/lune/src/interp.zig#L6767)). If `site` only holds `{a, nargs, nwanted, B}`, the dispatcher has no direct link to the `Native` object to inspect `native.disturbs`.
- **Concrete Fix**:
  - In §5.1, define `guard_native callee_ref, k` with `ins.a = callee_ref`, `ins.aux = k`, and `ins.snap = S_B`.
  - Expand the per-trace `site` struct to explicitly include `preflush_snap: SnapIdx` and `callee: *function.Native`:
    ```zig
    pub const HostCallSite = struct {
        a: u16,
        nargs: u16,
        nwanted: u16,
        b_pc: u32,
        preflush_snap: SnapIdx,
        callee: *function.Native,
    };
    ```
  - Both executors use `site.preflush_snap` for the inline $S_B$ materializer, and the dispatcher reads `site.callee.disturbs` directly on an epoch exit.

---

#### 2. [should-fix] "Site's per-call scratch" and address stability of `Vm.host_epoch`
- **Evidence**:
  1. §5.6 lines 473–475 states: `host_epoch` equals the value the shim read before the call *(the shim keeps it in the site's per-call scratch; native compares it in a register)*.
  2. `TraceCode` and its metadata are immutable and shared across runs. Writing runtime state (`pre_call_epoch`) into a per-trace `site` table would mutate `TraceCode`, violating Rule Z-4 and risking memory faults if code/metadata pages are read-only.
  3. In [`interp.zig:576-580`](file:///home/bart/Projects/lune/src/interp.zig#L576-L580), `Vm` is explicitly documented as a by-value struct that may move on the stack ([`main.zig:363`](file:///home/bart/Projects/lune/src/main.zig#L363)):
     *"Vm is a by-value struct that may move, but tier-1b native pages bake `&heap.gc_stress` / `&heap.object_count` / `&heap.next_gc` ... and the `*Heap` itself ... as imm64s — the same stability contract as `NativeSeedCtx`"*.
  4. Native code does not hold a pointer to `Vm` in a register. If `host_epoch` is a field on `Vm`, native code cannot bake `&vm.host_epoch` as an imm64 into machine code for `guard_host_epoch`'s compare.
- **Concrete Fix**:
  - Place `host_epoch: u64` on `Heap` (or provide `heap.host_epoch`), whose address is stable and can be baked into native code as an imm64, matching `heap.object_count` and `heap.next_gc`.
  - Replace "the site's per-call scratch" by storing `pre_call_epoch` in a dedicated slot in the native frame's callout save area ([`alloc.callout_save_base`](file:///home/bart/Projects/lune/src/nativegen_emit.zig#L1523)) or on `Heap` (e.g. `heap.trace_epoch_scratch`), ensuring `TraceCode` metadata remains strictly read-only.

---

#### 3. [should-fix] Native code callout argument `vm` in `mahina_trace_host_call`
- **Evidence**:
  1. §5.8 line 518 specifies the body callout signature as `mahina_trace_host_call(vm, site) callconv(.c) u32`.
  2. Because `Vm` can move ([`interp.zig:576`](file:///home/bart/Projects/lune/src/interp.zig#L576)), native code cannot bake `*Vm` as an immediate operand.
  3. The native execution ABI ([`nativegen_artifact.zig:789-792`](file:///home/bart/Projects/lune/src/nativegen_artifact.zig#L789-L792)) only passes `rdi = tags`, `rsi = payloads`, `rdx = *NativeResult`. Native code does not have `vm: *Vm` in any register.
  4. Unlike all existing body callouts which only take `*Heap` ([`nativegen_alloc.zig:1743`](file:///home/bart/Projects/lune/src/nativegen_alloc.zig#L1743), [`nativegen_emit.zig:1821`](file:///home/bart/Projects/lune/src/nativegen_emit.zig#L1821)), `mahina_trace_host_call` requires `*Vm` to drive `Vm.callHostNative`.
- **Concrete Fix**:
  - Specify how native code retrieves `vm: *Vm`: load it via the heap-stable `NativeSeedCtx` ([`trace_code.zig:267`](file:///home/bart/Projects/lune/src/trace_code.zig#L267), where `seed_ctx.vm` already holds `*Vm` for the episode), or add `vm: *anyopaque` to `NativeResult` so native code loads it from `[rdx + @offsetOf(NativeResult, "vm")]` prior to the callout.

---

#### 4. [nit] Tracking the executing trace during `suspend_depth > 0` for the amended F3 invariant
- **Evidence**:
  1. §5.10 lines 646–647 states: *"The amended invariant is asserted in `invalidateDeadTraceConsts` (a doomed trace is either not executing or is suspended at a `call_host`)"*.
  2. `TraceState` currently does not record which trace is actively executing across native reentrancy. Without an explicit field such as `TraceState.suspended_trace: ?*Trace`, `invalidateDeadTraceConsts` cannot distinguish whether a doomed trace is currently suspended at `call_host` versus executing elsewhere.
- **Concrete Fix**:
  - Specify that `TraceState` gains `suspended_trace: ?*Trace` (set by `mahina_trace_host_call` when raising `suspend_depth` and cleared when lowering), allowing `invalidateDeadTraceConsts` to directly verify the amended F3 assertion.

---

### Recommendations on Open Questions (§9)

- **Q1 (Amend doc 00 and doc 02 barrier commitment)**: **Yes**.
  Doc 45 proved that execute-once effects (`tnew`) can safely live in traces via precise snapshots and non-restoring exits. With rev 3's pre-call state synchronization, slab-coherent exits, and GC scrub/epoch proofs, host calls meet the same execute-once contract. Amend both docs.
- **Q2 (JIT suspension during callbacks in v1)**: **Yes**.
  Per-VM episode state ([`NativeSeedCtx`](file:///home/bart/Projects/lune/src/trace_code.zig#L249), `touched[]`, hit counters, `ledger_scratch`) is single-instance per VM. Suspending the JIT (`suspend_depth > 0`) isolates callbacks to tier-0 without complex episode stack frames, and the disturbance threshold ensures hot callbacks quickly retire the outer trace so nested loops can JIT in tier-0.
- **Q3 (Leaf host functions in v1, later, or never)**: **Defer to Phase 4 (later)**.
  Per Rule Z-6 and Rule Z-7, land and measure the unified precise path (Phases 0–3) first. Leaf calls require separate ABI paths, manual SSA marshaling, and special error handling ([`capi.zig:1130`](file:///home/bart/Projects/lune/src/capi.zig#L1130)) which should not complicate the initial release.
- **Q4 (Disturbance threshold: 1 vs higher)**: **Threshold 1 (LuaJIT's rule)**.
  A host call that mutates tables, globals, or executes guest code triggers an immediate deopt at `guard_host_epoch`. Allowing repeated iterations with a threshold > 1 would cause deopt-thrashing and execute nested callbacks in tier-0 under suspension each time. Threshold 1 retires the trace immediately on the first disturbance, allowing the outer loop to run in tier-0 where callbacks can JIT cleanly.
- **Q5 (Multret arguments and results past v1)**: **Yes, defer**.
  Precise mode currently handles fixed-window frames only. Supporting `all_results` dynamically alters window sizing and depends on doc 27 multret shadow mechanics. Keep fixed arity for v1.
