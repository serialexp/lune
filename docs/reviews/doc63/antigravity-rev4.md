APPROVE WITH CHANGES

---

### Round 3 Dispositions Verification

Revision 4 resolves the seven round-3 findings from Codex and four from Antigravity:

1. **Precise Consumer Prior to `traceById` (Codex 1)**: **Resolved**. Routing precise terminal results through the retained entered-trace borrow `ct` before live-ID resolution and post-run drains ([`interp.zig:4492`](file:///home/bart/Projects/lune/src/interp.zig#L4492)) prevents panicking on a logically retired trace. Skipping receipt and memo updates for a retired `ct` isolates the consumer (§5.10).
2. **Phase Q Split and Entry-Patch Release Point (Codex 2)**: **Resolved**. Splitting Phase Q into immediate logical invalidation and physical teardown queued on `TraceState.deferred_retire` protects entry-patch borrows across [`interp.zig:5339`](file:///home/bart/Projects/lune/src/interp.zig#L5339) and [`interp.zig:5455`](file:///home/bart/Projects/lune/src/interp.zig#L5455) until the outermost entry wrapper completes (§5.10).
3. **Seed Scrubbing on Error (Codex 3)**: **Resolved**. Scrubbing the seed span to nil before clearing `trace_seed_span` on error prevents gap-slot rooting during subsequent unwind or `xpcall` handler collections ([`stdlib/errors.zig:104`](file:///home/bart/Projects/lune/src/stdlib/errors.zig#L104), §5.5).
4. **Leaf Slab Coherence via Preflush (Codex 4)**: **Resolved**. Retaining the $S_B$ preflush and setting `frames[depth-1].pc = B` and `in_flight = true` (§5.12) ensures the slab is coherent for `C_B1` on result-tag mismatches ([`nativegen.zig:747`](file:///home/bart/Projects/lune/src/nativegen.zig#L747)) and errors are located at `B` ([`capi.zig:1130`](file:///home/bart/Projects/lune/src/capi.zig#L1130)).
5. **Suspension Checks Preceding JIT Decisions & Recovery (Codex 5)**: **Resolved**. Checking `suspend_depth == 0` in `eligible` ([`interp.zig:7088`](file:///home/bart/Projects/lune/src/interp.zig#L7088)) and at the top of all four patched handlers before `unpatchSlot` ([`interp.zig:5931`](file:///home/bart/Projects/lune/src/interp.zig#L5931), etc.) prevents running unpatched entries and avoids premature non-live mutation during suspension (§5.9).
6. **Pre-Invocation Disturbance Blacklist Check (Codex 6)**: **Resolved**. Emitting `guard_native callee, k` before every traced call to check `native.disturbs < threshold` (§5.1, §5.9) and tracking disturbance in a `defer` inside `callHostNative` ([`interp.zig:2269`](file:///home/bart/Projects/lune/src/interp.zig#L2269)) bounds suspended execution to at most one iteration across all cached callers.
7. **`mh_error_set` Justification (Codex 7)**: **Resolved**. Correctly re-argued as staging text in the box allocator without modifying guest state ([`capi.zig:1128`](file:///home/bart/Projects/lune/src/capi.zig#L1128), [`capi.zig:1152`](file:///home/bart/Projects/lune/src/capi.zig#L1152), §5.6).
8. **Operand Linkage, Read-Only Sites, Stable Heap Epoch, and Native Arguments (AG 1–3)**: **Resolved**. `HostCallSite` carries `preflush_snap` and `callee_k`; `host_epoch` is placed on [`Heap`](file:///home/bart/Projects/lune/src/gc.zig#L108); the shim receives `ctx: *NativeSeedCtx` with stable `vm` ([`trace_code.zig:267`](file:///home/bart/Projects/lune/src/trace_code.zig#L267)).
9. **Executing Trace Tracking for F3 (AG 4)**: **Resolved**. Introduced `TraceState.suspended_trace: ?*Trace` (§5.10).

---

### Findings

#### 1. [blocker] Shim lacks `*Trace` link to record `TraceState.suspended_trace` and resolve `callee_k`

- **Evidence**:
  1. §5.8 lines 553–555 specifies the shim signature:
     ```zig
     mahina_trace_host_call(ctx: *NativeSeedCtx, site: *const HostCallSite) callconv(.c) u32
     ```
  2. §5.8 lines 562–565 states that `mahina_trace_host_call`:
     - *"raises `TraceState.suspend_depth` (§5.9) and records the trace in `TraceState.suspended_trace` (§5.10);"*
     - *"gathers the arguments from the slab and calls `Vm.callHostNative`..."*
  3. Neither [`NativeSeedCtx`](file:///home/bart/Projects/lune/src/trace_code.zig#L249-L275) nor [`HostCallSite`](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md#L277-L285) contains a `*Trace` pointer. [`Vm`](file:///home/bart/Projects/lune/src/interp.zig#L576) does not track the currently executing trace.
  4. [`Vm.callHostNative`](file:///home/bart/Projects/lune/src/interp.zig#L2259) requires `nat: *const function.Native`. `HostCallSite` only stores `callee_k: u32` (a constant pool index into `TraceCode.consts`).
  5. Without an owning trace pointer, `mahina_trace_host_call` cannot assign `TraceState.suspended_trace = trace`, nor can it access `trace.code.consts[site.callee_k]` to extract `nat` for `Vm.callHostNative`.
- **Concrete Fix**:
  - Add `owner: *Trace` to `HostCallSite` in §5.1:
    ```zig
    pub const HostCallSite = struct {
        a: u16,
        nargs: u16,
        nwanted: u16,
        b_pc: u32,
        preflush_snap: SnapIdx,
        callee_k: u32,
        owner: *Trace,
    };
    ```
  - During finalize, initialize `site.owner = t`.
  - In `mahina_trace_host_call`, set `ts.suspended_trace = site.owner`, and resolve `nat = function.Native.fromHeader(site.owner.code.consts[site.callee_k].asHeap())` to pass to `Vm.callHostNative`.

---

#### 2. [should-fix] Deferred physical retirement queue (`TraceState.deferred_retire`) orphaned during tier-0 recording

- **Evidence**:
  1. §5.9 lines 601–603 states: *"callHostNative raises it for two callers: the trace shim, and tier-0 while a recording is active (so a callback cannot feed the outer recording)."*
  2. §5.10 lines 699–705 specifies that physical teardown is queued on `TraceState.deferred_retire` when `suspend_depth > 0`, and:
     *"The release point for the queue is the end of the outermost entry wrapper that entered the suspended trace (`enterPatchedTrace` or the back-edge entry path), after its last access to the patch and the trace record ([interp.zig:5339](file:///home/bart/Projects/lune/src/interp.zig#L5339), [:5455](file:///home/bart/Projects/lune/src/interp.zig#L5455)), with `suspend_depth` back at 0."*
  3. When `callHostNative` is invoked from tier-0 during an active recording ([`interp.zig:6761`](file:///home/bart/Projects/lune/src/interp.zig#L6761)), execution is inside `opCall`. There is no trace entry wrapper on the stack.
  4. If a callback in this tier-0 recording triggers GC and dooms a trace, physical teardown is pushed to `TraceState.deferred_retire`. When the callback returns and `callHostNative` lowers `suspend_depth` back to 0, no entry wrapper exists to release the queue.
  5. The queued traces and patches remain orphaned in `deferred_retire` until an unrelated loop back-edge runs and exits a trace, or permanently leak memory.
- **Concrete Fix**:
  - Specify that physical destruction is deferred to `TraceState.deferred_retire` only when `TraceState.suspended_trace != null` (because during tier-0 recording, no trace record or entry patch is currently executing or borrowed on the stack, allowing physical teardown to proceed immediately);
  - Alternatively, specify that when `callHostNative` lowers `suspend_depth` to 0 with `TraceState.suspended_trace == null`, it drains `TraceState.deferred_retire` immediately before returning.

---

#### 3. [should-fix] Tier-1a `irinterp.ExecCtx` needs `*NativeSeedCtx` to call `mahina_trace_host_call`

- **Evidence**:
  1. §5.8 line 560 and §5.11 line 731 state that tier-1a calls the identical shim `mahina_trace_host_call(ctx: *NativeSeedCtx, site: *const HostCallSite)`.
  2. In [`irinterp.zig:241-256`](file:///home/bart/Projects/lune/src/irinterp.zig#L241-L256), `ExecCtx` contains only `heap: ?*gc.Heap`, `activation_base`, `activation_depth`, and `exit_side`. It does not contain `*NativeSeedCtx` or `*Vm`.
  3. At tier-1a dispatch ([`interp.zig:4343`](file:///home/bart/Projects/lune/src/interp.zig#L4343)), `ir_ctx` is initialized as `.{ .heap = self.heap, .exit_side = ct.exit_side }`.
  4. Tier-1a cannot invoke the body callout without access to `*NativeSeedCtx`.
- **Concrete Fix**:
  - In §5.11, specify that `irinterp.ExecCtx` gains `seed_ctx: ?*NativeSeedCtx = null`, passed from `&self.trace.seed_ctx` by the dispatcher when entering tier-1a.

---

#### 4. [nit] Explicit `IrInstr` operand layout for `site`, `k`, and `A_rem`

- **Evidence**:
  1. §5.1 lines 261–268 defines:
     ```
     guard_native  callee, k          ; snap = S_B (full, resume B)
     call_host     site               ; snap = C_B (failure); preflush site.preflush_snap = S_B
     guard_host_epoch site            ; snap = C_B1; aux = A_rem
     host_result   site, 0            ; tag check; snap = C_B1
     ```
  2. In [`IrInstr`](file:///home/bart/Projects/lune/src/trace_ir.zig#L810-L816), the available fields are `a: Ref`, `b: Ref`, `aux: i32`, `snap: SnapIdx`. For `guard_host_epoch`, `aux` holds `A_rem`, requiring `site` to live in `a`. For `host_result`, both `site` and the result index must be mapped.
- **Concrete Fix**:
  - Explicitly document the `IrInstr` field assignment in §5.1:
    - `guard_native`: `ins.a = callee`, `ins.aux = k`, `ins.snap = S_B`.
    - `call_host`: `ins.aux = site`, `ins.snap = C_B`.
    - `guard_host_epoch`: `ins.a = site`, `ins.aux = A_rem`, `ins.snap = C_B1`.
    - `host_result`: `ins.a = site`, `ins.aux = k` (result index), `ins.snap = C_B1`.

---

### Recommendations on Open Questions (§9)

- **Q1 (Amend doc 00 and doc 02 barrier commitment)**: **Yes**.
  Doc 45 proved execute-once effects (`tnew`) can safely live in traces via precise deopt. Extending this to host calls via pre-call state synchronization, slab-coherent exits, and epoch checking preserves determinism and replay while eliminating the tier-0 seam.
- **Q2 (JIT suspension during callbacks in v1)**: **Yes**.
  Per-VM episode state ([`NativeSeedCtx`](file:///home/bart/Projects/lune/src/trace_code.zig#L249), `touched[]`, hit counters, `ledger_scratch`) is single-instance per VM. Suspending the JIT isolates nested callbacks to tier-0 without multi-episode stack frames.
- **Q3 (Leaf host functions in v1, later, or never)**: **Defer to Phase 4 (later)**.
  Land and verify the unified precise path (Phases 0–3) first per Rule Z-6 and Rule Z-7. Leaf host functions are an optimization that skips the epoch check and suspension; they should be benchmarked against Phase 0 numbers rather than complicating the initial release.
- **Q4 (Disturbance threshold: 1 vs higher)**: **Threshold 1 (LuaJIT's rule)**.
  A host call that mutates VM state or runs callbacks causes an immediate deopt at `guard_host_epoch`. Allowing repeated iterations with a threshold > 1 would induce deopt-thrashing and force callbacks to run in tier-0 under suspension repeatedly. Threshold 1 stops tracing the native immediately on first disturbance, allowing tier-0 to run nested loops with the JIT enabled.
- **Q5 (Multret arguments and results past v1)**: **Yes, defer**.
  Fixed-arity calls cover the common embedding use cases. Dynamic multret windows depend on doc 27 multret shadow mechanics and should be added after the core precise host-call mechanics are stable.
