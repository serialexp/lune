# Design Review: doc45 (Revision 5) — General Table Effects and Precise Deoptimization

**Verdict:** **APPROVE** for implementation.

The normative [docs/design/45-table-effects-and-precise-deopt.md](file:///docs/design/45-table-effects-and-precise-deopt.md) Revision 5 resolves all architectural blockers and mandatory clarifications from Round 4 and prior reviews. There are no remaining design-level blockers. As established in the contract, the absence bug in [`nativegen.proveKinds`](file:///src/nativegen.zig#proveKinds) remains an explicit **P0 gate** that blocks landing before effects are introduced.

---

### Key Contract Validations & Verification Summary

#### 1. Snapshots, Admission, and Interning Budgets (§D1, §D2)
- **Interning Budget Disambiguation:** D2 explicitly disambiguates the limits: at most **256 distinct interned slot vectors**, **2000 [`Snapshot`](file:///src/trace_snapshot.zig#Snapshot) records**, and **65536 [`SnapshotSlot`](file:///src/trace_snapshot.zig#SnapshotSlot) entries** per candidate. Vector deduplication and overflow checking abort cleanly with a dedicated `snapshot_limit` reason without publishing partial state.
- **Physical Register Window:** Snapshots represent the full current physical activation window (`register_count == anchor.proto.num_registers`) in ascending slot order, including dead temporaries, backed by entry `slot_load`s to guarantee valid GC roots across all registers.
- **Explicit State-Change Refusal:** D2 explicitly forbids operations modifying dynamic frame state prior to a terminal: dynamic `multret_top`, `stack_top` changes, and close-upvalue operations trigger admission refusal.
- **Staged Inline & Peeling Restrictions:** D1 enforces a hard admission boundary: any candidate with identity-bearing effects and *any* inlined call (before or after the effect) is refused. Allocations in peeled traces and vararg frame reconstructions are excluded from P2.

#### 2. Deterministic Cancellation & Legacy Isolation (§D2, §D3)
- **Re-recording without Retroactive Promotion:** First encounter of `tnew` or precise `tset` immediately aborts the candidate with `needs_precise` without blacklisting.
- **Deterministic Counter Re-arm:** Re-arms hotness counters to threshold saturating-minus-one across loop, head, and cont anchors (mirroring [`trace.zig:loop_leave`](file:///src/trace.zig#3365-3382)), preventing counter starvation past equality crossing.
- **Legacy Pipeline Isolation:** Full entry slot capture occurs strictly when recording under precise mode from anchor start. Legacy `entry_slots`, phi writebacks, and `tropt.dupe` behavior remain completely untouched for non-precise traces.

#### 3. Guest-Effect Ordering & Optimizer Liveness (§D2, §D3)
- **Single Ordered IR Stream:** Precise candidates emit stores directly in guest bytecode order from start; `pending_stores` is asserted empty at finalization.
- **Per-Boundary Failure Order:** D2 enforces that within a single source boundary, no ordinary failing operation may follow an identity-bearing effect or mutation. Helper errors route to `.precise_error`.
- **Optimizer Remapping & Liveness:** [`tnew`](file:///src/trace.zig#tnew) (ordinal 88) and [`tset`](file:///src/trace.zig#tset) (ordinal 89) are pinned as non-CSE/DCE/hoistable effect roots. Snapshot references are added as liveness roots before DCE. Constant folding exports a canonical ref map (covering merged/folded nodes beyond `old_to_new`) prior to compaction. Speculative optimizations assuming entry replay (LICM, strength reduction, phi coalescing) are disabled for precise candidates.

#### 4. GC Budget & Eager Checks (§D4)
- **Eager [`guard_gc`](file:///src/trace.zig#guard_gc):** Emitted immediately after entry `slot_load`s and strictly before any effect; never relocated at finalization.
- **Zero-Bound Mutating Traces:** Aux=0 is legalized for precise non-allocating/mutating bodies (e.g., `tset`-only loops), relaxing finalization assertions while preserving `!gc_stress` and due-GC checks when dropping roots.
- **Deterministic Traversal Bound:** Reserves worst-case allocations for a single body traversal; all link targets re-verify budget before execution.

#### 5. Runtime Error Contract & C ABI (§D5)
- **Single Execution & Non-Transactional Heap:** [`Table.set`](file:///src/table.zig#set) and [`Heap.newTable`](file:///src/heap.zig#newTable) run exactly once via shims in [src/table_runtime.zig](file:///src/table_runtime.zig). Partial mutations from growth, migration, or rehash are preserved without rollback or retry.
- **Clean C ABI:** Helpers take `*Heap` explicitly and access storage via `heap.gpa` (asserted to equal `vm.gpa`), avoiding passing Zig fat `Allocator` structs through C ABI callouts.
- **Error Handoff & Catchability:** Pre-instruction registers are restored and handed to the located-error interpreter path. Uses [`interp.catchable`](file:///src/interp.zig#catchable): `OutOfMemory` is uncatchable (unwinding past `pcall` to protect determinism), whereas `TypeError` is catchable and recovers under `pcall`.

#### 6. Exit ABI & Link Integration (§D6)
- **ABI & Ledger Extensions:** Appends [`ExitReason.precise_resume`](file:///src/trace_exec.zig#ExitReason) and [`ExitReason.precise_error`](file:///src/trace_exec.zig#ExitReason). Appends [`LedgerKind.precise_deopt = 10`](file:///src/trace_exec.zig#LedgerKind) and [`LedgerKind.precise_error = 11`](file:///src/trace_exec.zig#LedgerKind). Adds scalar fields `snapshot_id`, `runtime_error`, `activation_base`, and `activation_depth` to [`ExecResult`](file:///src/trace_exec.zig#ExecResult) / [`NativeResult`](file:///src/nativegen.zig#NativeResult).
- **Exit Stubs & Dispatcher:** Stubs flush snapshots to the current slab, record trace ID, IR index, and snapshot ID, write a final non-yielded ledger entry, and return. Dispatcher validates proto, activation depth/base, and snapshot range before resuming at `resume_pc`.
- **Link Staging:** P2 disallows links into or out of precise pages. P3 admits only clean terminal handoffs (head/cont self-call/return) after complete snapshot flush and budget check. Guard and error exits remain unchainable.

#### 7. Guarded Absence & P0 Gate (§D7)
- **Known P0 Defect Gated:** The [`nativegen.proveKinds`](file:///src/nativegen.zig#proveKinds) issue—where string constants shared between href and [`guard_absent`](file:///src/trace.zig#guard_absent) receive `.none` and pass an unmaterialized pointer—is explicitly designated as a P0 implementation gate. String constants used as values must be promoted to `.heap`, failing closed on `.none`.
- **Accounting Fix:** [`guard_absent`](file:///src/trace.zig#guard_absent) is added to [`isSideExitGuardOp`](file:///src/nativegen.zig#isSideExitGuardOp) to ensure guard exit headroom/penalty accounting is applied.
- **Inline Numeric Path:** Numeric absence checks inlined on the non-grid common path (validating metatable-free state, checking array bounds, and inspecting presence bitmaps/lane tags before calling the shared fallback).

---

### Implementation Phasing & Gates (§D9)

| Phase | Core Objective | Key Deliverables & Gates |
|---|---|---|
| **P0** | Guarded Absence | Fix `proveKinds` href-key `.heap` materialization; add `guard_absent` to `isSideExitGuardOp`; inline non-grid numeric path; full Campaign test board. |
| **P1** | Precise State Substrate | `src/trace_snapshot.zig`; 256 vector / 2000 record / 65536 slot budgets; deterministic re-arm; entry capture isolation; synthetic exit tests. |
| **P2** | Native Construction | `tnew` (88) / `tset` (89); eager `guard_gc` (including aux=0); non-transactional OOM handoff with `interp.catchable`; unlinked loop/head/cont execution. |
| **P3** | Link Integration | Clean terminal handoffs (head/cont self-call and ret); activation validation; final ledger verification; full 7-rep benchmark campaign. |

The design is sound, complete, and approved to proceed to implementation.
