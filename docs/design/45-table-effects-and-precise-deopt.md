# General table effects and precise deoptimization

Status: partial — Revision 5 approved (Opus + Antigravity); guarded-absence slice implemented per D7; D2 precise-state substrate + tier-1a precise executor landed; P2 CONSTRUCTION SLICE 1 landed (`tnew` recording + tier-1a precise execution of allocating bodies incl. mixed immediate-store bodies, D5 OOM `.precise_error` → `raise_at` contract); D6 NATIVE HALF landed (native precise executor: exit ABI quad, per-snapshot inline materializers, `tnew` callout, selection lifted); `tset`/constructor stores, optimizer integration and serialization outstanding
Owner: Bart
Last updated: 2026-09-11

## Implementation status

### Done

- [x] **Independent design review.** Claude Opus and Antigravity approve the same Revision 5 contract with no remaining design blockers. Receipts: `docs/reviews/doc45/opus-r5.md` and `antigravity-r5.md`. Reviewed body SHA-256 before this status-only update: `de4e3c6b2c123c2d9d524f3c7498ad2a037f9ac3a033039b324739b00a21bdea`. Opus inspected repository source; Antigravity reviewed supplied document/source excerpts because headless tool permissions blocked repository inspection. Approval is for the design, not current code.
- [x] **Baseline investigation.** D12c revision 4893cbc: seven-rep binary-trees 370.0 ms, tier-0 221.3 ms, LuaJIT 39.3 ms. Result: `bench/results/20260909-161243-4893cbc.tsv`. Aborts confirm `new_table` in BottomUpTree and absent `get_index` in ItemCheck. Runtime receipts: `/tmp/mahina-table-recording/`.
- [x] **Replay constraint established.** `IrInstr.snap` is reserved, not implemented. Doc24's interned-string allocation proof explicitly does not cover tables; ordinary guard failures replay from trace entry. A direct allocation callout alone is unsound.
- [x] **Guarded absence (D7).** `guard_absent` (wire 87) as a non-CSE memory effect root: recorder paths for numeric and constant-string keys with pending-store forwarding, the shared `table_runtime.isAbsent` predicate in tier-1a, and native lowering — D7's inline numeric fast path (live lane/asize/data/present/hash-size reads; bool in-band byte, `.value` nil tag, numeric presence bitmap, empty-hash OOB shortcut) with the full-lookup callout for string keys, grids and hash-resident fallbacks. P0 href-key admission fixed (a konst with any real value use leaves the metadata-only `href_key` set and materializes; `guard_absent` refuses `.none` keys). Differential native-vs-tier-1a tests cover holes, hash overflow, insertion, metatable appearance, bool/value lanes, negative keys and the shared-key two-table shape; VM-level tests pin guarded-nil recording and same-iteration store deferral below the guard. `isSideExitGuardOp` includes it; `guardExitPc` stays null; nil is a first-class native kind (zero payload, nil tag, falsy, rejected by numeric/compare arms). Per-anchor receipts: ItemCheck absence traces 1541.8→1341.4 and 229.6→201.4 c/it after inlining.

- [x] **D2 foundations (increments 1–2).** `src/trace_snapshot.zig` (013379c): executor-independent `DeoptMode`/`Snapshot`/`SnapshotSlot`, deterministic admission `Budget` (256 vectors / 2000 records / 65536 slots), `Builder`, `validate`, `refsDefinedAt`, `remapRefs`. Increment 2: `TraceCode` owns `snapshots`/`snapshot_slots` (freed in `deinit`, every candidate error path funnels through it) + `deopt_mode`; `AbortReason.snapshot_limit` and the `.needs_precise` deterministic re-recording policy — non-penalizing cancel on `new_table` under entry-replay mode, `precise_anchor_memo` (never address-keyed), hotness-counter rewind to threshold−1 by anchor kind (loop→hotloop, head/cont→hotcall — the LLEAVE fast-retry mechanics), `arm` seeds `rec.precise` from the memo. Named transition test pins cancel-once → same-anchor precise retry → normal strikes (not blacklisted). All gates green (unit, wasm, hashgate ×2).
- [x] **D2 recorder capture (increment 3).** Precise candidates emit the full entry `slot_load` map + eager `guard_gc` prologue at the FIRST body `recordInstr` (deferred from `arm` so `maybeCloseAtAnchor`'s `instrs.len == 0` empty-body guard still fires), then a full-window `Snapshot` at each guest-bytecode boundary (`snapBoundary`, built in reusable `Builder`+scratch — no per-iteration allocation, `SnapshotLimit` → the `snapshot_limit` abort). `emit` stamps `IrInstr.snap` (one-based) on every body op; the prologue carries `snap == 0` (entry replay for pre-body failures). D3/D4 admission enforced during capture: precise mode refuses inlined calls, all sunk stores (`pending_stores` asserted empty at finalize), dynamic multret, and peeling; legalizes `guard_gc aux == 0` for a nonallocating body. `trace_finalize` takes the dupe path for precise (identity indices), moves the `Builder` output into `TraceCode`, sets `deopt_mode = .precise`, and REJECTS missing/invalid snapshots (`validate` + `refsDefinedAt` + register_count + every fallible body op has a snap → `error.InvalidSnapshotMetadata`, correctness metadata not fail-soft). Native codegen and traceser serialization DECLINE precise traces (their own increments — D6/D8); execution selection declines them too (no precise executor yet → tier-0 owns the loop, so a constructing body can't non-terminate via entry replay). Named test: pre-seeded precise loop commits a full-window snapshot per body bytecode with the prologue at `snap == 0` and every body guard carrying a defined-refs snap.

- [x] **Tier-1a precise executor (increment 4, D2/D6 tier-1a half).** `ExitReason.precise_resume`/`.precise_error` (wire 4/5) + `ExecResult.snapshot_id`; the tier-1a shared exit point materializes the failing op's snapshot into the guest window (`regs[slot] = values[ref]` — sound because the dupe path re-executes every instruction per iteration, so refs `< exit_instr` hold the current iteration's values; `.terminal`/`.link`/`.loop` and `snap == 0` prologue exits excluded). Dispatcher: a `.precise_resume` arm (all anchor kinds) validates snapshot range/register_count and resumes tier-0 at `snapshot.resume_pc` — no sibling trial, no chain, no side-trace want, ordinary productivity/penalty receipt so a thrashing precise anchor still gates (witness counter `precise_resumes`); a loop-anchor prologue-exit arm applies the ordinary entry contract minus D6's suppressed machinery. Selection flipped: tier-1a ENTERS precise traces (native mode still declines via the compileImpl bail + safety net; exec-log sessions never PRODUCE a precise trace — `needs_precise` falls through to an ordinary strike under `record_exec_log`, because `TraceExecLog.trace_id` is a cache index and the wire format can't carry precise until D8). P2 link prohibitions at arm AND dispatch: recorder refuses `.link` closes on precise candidates (both for_prep and while paths, finalize backstop-asserts), `findLinkTrace`/`resolveLoopDoneCont`/`driveChain`'s sibling walk skip precise pages, `armNativeLink` refuses precise on either end. Tests: mid-loop element-guard failure precise-resumes on tier-1a with byte-identical output vs tier-0 + witness ≥ 1; direct-executor divide-by-zero restore proves MID-ITERATION register materialization (x and its operand aliases restored to this-iteration values, loop controls and s untouched — also pinning the post-for_loop anchor entry contract: the increment sits at the body's end); exec-log session commits no precise trace and serializes cleanly. Anchor-entry note for the native half: entry state is post-for_loop (body uses `i` directly; increment + done guard close the body), so the loop-done guard's snapshot resumes AT the for_loop bytecode and tier-0 re-runs the increment.


- [x] **P2 construction slice 1 — `tnew` recording + tier-1a precise execution (D3/D5, tier-1a half).** IR: `tnew` (wire 88, operand-free heap/table producer, ordered effect root) and `tset` (wire 89, RESERVED — finalize traps on it, executor fails closed, nothing emits it); viz `enums.ts` + ordinal pin test updated. Recorder: the precise `.new_table` arm now records `emitAlloc(.{tnew, heap})` + `setReg` (guard_gc budget covers the ID; commit stamps the bound — the pure-construction money trace carries `aux == 1`); the needs_precise transition test now proves the retry gets PAST the construction bytecode (dies at the absent-key insert one bytecode later). Finalize: `requiresPreciseSnapshot(op)` (side-exit guards + `tnew`/`tset`) replaces the guard-only predicate — a snap-less fallible effect past `guard_gc` is `error.InvalidSnapshotMetadata`; `assertWellFormed` pins `tnew` precise-only. Shim: `table_runtime.tnew(heap, out) callconv(.c) Status` (`ok/out_of_memory/type_error`, ABI-pinned) — exactly one `Heap.newTable`, no collect, no rollback. Executor: `.tnew` arm runs the shim once per iteration; on OOM sets `runtime_error` and breaks — the shared exit tail restores the op's snapshot for BOTH `.precise_resume` and `.precise_error`, asserts a precise runtime error never reaches a snap-less op (no degrade to `.normal`), and echoes the D6 activation contract (`ExecResult.runtime_error`/`activation_base`/`activation_depth`, tier-1a always anchor-activation 0/0, dispatcher-asserted). Dispatcher: `.precise_error` consumer (validated like `.precise_resume`; NO receipt/strike/want/chain/mode-switch — the error unwinds) maps `Status.out_of_memory → Error.OutOfMemory` (uncatchable per D5) and returns the new `EntryDirective.raise_at{pc, err}`; all five consumption sites (jfor_loop/jloop/jfunc_head/jcont patched entries + the back-edge walk via `BackEdgeDirective.raise_at`) park `frame.pc = pc` and `parkErr` — the error surfaces at the same bytecode tier-0 would park, with NO re-execution (execute-once, never an OOM retry). Witness counter `precise_errors`. Tests: money identity (pure construction loop commits precise, runs tier-1a, output + `next_obj_id` + `object_count` byte-match tier-0 — exactly-once incl. the final loop-done resume); direct-executor one-shot-OOM (custom fail-Nth allocator over `heap.gpa`: `.precise_error` with status/snapshot/activation fields, registers exactly entry, zero heap effect; then the real heap: 14 iterations = exactly 14 IDs); full-pipeline OOM identity (fail the K-th GUEST heap allocation in both a tier-0 and a traced run: same `Error.OutOfMemory`, same `next_obj_id`/`object_count`/parked pc, `precise_errors == 1` — the raise took the tier-1a precise path); mixed body (immediate `astore` + `tnew` in one precise trace, mid-loop element-guard resume at i==200 — neither effect repeats, output + `next_obj_id` match tier-0). All gates green (unit, wasm, hashgate ×2).

- [x] **Native precise executor (D6 native half).** ABI: `NativeResult`/`ExecResult` gained the tail-append quad `snapshot_id`/`runtime_error`/`activation_base`/`activation_depth` (u32×4 after `popped_frames`, comptime offset-pinned — scalar offsets are baked as imm32 in exit stubs); `LedgerKind.precise_deopt = 10`/`.precise_error = 11` (always terminal, never a chain source or patch window — `rowPatchKind → null`, chain replay panics on them). compileImpl: the precise decline is replaced by an acceptance checklist (loop anchor, terminal `.loop`, un-peeled, `body_start == 0`, zero frame motion, a valid full-window snapshot on every `requiresPreciseSnapshot` op, heap mandatory — `tnew` joins the heapless refusal list); proveKinds admits `.tnew → .heap`, `guard_gc aux == 0` (precise only), and snapshot-only entry loads as kind `.none` (no home, no prologue check; write-dominated carried `.none` slots reclassify to the store kind so `local t = {}` bodies compile). Regalloc: snapshot refs of exit-capable ops extend `last_use` through their exits; `tnew` gets a dedicated out-param frame word and joins `opMayExitInBody` (blocks carried-home coalescing before the last body exit, so the materializer reads stable homes). Codegen: `tnew` body callout (save/restore bracket, status stashed in rcx via `movzx` — SysV leaves upper rax unspecified for a u32 return, Status ordinals comptime-pinned < 256 — new dword store `movMemReg32` writes it into `runtime_error` AFTER the qword `snapshot_id` stamp whose upper bytes zero that dword); per-(snapshot, exit-class) SHARED inline materializers flush the full window (konst → tag+payload imm; invariant own-entry refs skip; carried `.none` loads flush the HOME — the slab is stale after the first back-edge; store budget 1024 → `error.PreciseFlushBudget` bail) into two tails (`.precise_resume`+`.precise_deopt` row / `.precise_error`+`.precise_error` row); precise exits never stage slot dispatch, never open patch windows, never take the linked loop-done branch; the `snap == 0` eager-`guard_gc` exit reuses the ordinary carried-home flush with reason `.normal` (dispatcher's precise prologue path re-runs the iteration in tier-0). Selection: the back-edge walk no longer skips native-unsupported precise candidates (a budget-bailed precise trace still runs tier-1a); the dispatcher's precise arms validate native rows (single terminal non-yielded ledger row of the agreeing kind, no silent/frame motion) instead of asserting `!ran_native`. Tests: native money identity (construction loop compiles + ENTERS natively — `native_entries ≥ 1` gated on x64 — with output/`next_obj_id`/`object_count` byte-matching tier-0 and loop-done riding the resume materializer), native mid-loop mixed-body element-guard resume at i==200 (exactly-once across the native materializer), native full-pipeline OOM identity (K-th guest allocation fails inside the native callout: same error/heap/parked pc as tier-0, `precise_errors == 1`). All gates green (unit, wasm, hashgate ×2).

### Outstanding
- [ ] **Optimizer integration (rest of D6).** Snapshot refs as tropt liveness roots + canonical-map remap (`remapRefs` needs `canon`+`new_index`, not `old_to_new`) so precise traces can leave the dupe path (they currently finalize dupe-only, so `optimize = true` is a no-op for them).
- [ ] **Effect ordering.** Resolve deferred stores before non-replayable effects; preserve already committed effects on every subsequent exit.
- [ ] **Table construction (rest).** `tset` general constructor stores — growth/widening/hash insertion, heap-valued children, the TypeError leg of the D5 error contract — plus native lowering for `tnew`/`tset` (tier-1a `tnew` landed in slice 1).
- [ ] **GC and errors.** Exact IDs, full root sets, allocation-budget gating, OOM/fallible-store behavior, pcall recovery and snapshot/replay tests.
- [ ] **Link integration.** Precise snapshots through ordinary and frame-motion native exits; no linked path may replay committed effects or consume an entry snapshot as precise state.
- [ ] **Acceptance.** Witness native construction, absent loads and return links; run unit/debug/hashgate/wasm/viz gates and the seven-rep full board.

## Why this exists

Table construction is missing from recording, not merely from native lowering. The present model depends on replaying a failed iteration against a heap changed only by replay-idempotent operations. Interned strings tolerate re-execution because their second creation is an intern hit. Tables never do: a repeated allocation consumes another stable object ID, even if the first object is dead. Constructor stores additionally grow, widen and insert, whereas existing recorded stores largely require an already suitable cell.

The foundation to extend is deoptimization state, rather than an allocation cache or ID rollback. LuaJIT's `lj_record.c` records `IR_TNEW` and guards nil loads. mahina must adapt that mechanism to its deterministic identity stream and physical-register GC roots.

## Measurement

Fresh baseline at depth12 reports 37% trace execution time, zero native return pops, and the two missing record shapes above. A depth14 perf sample attributes 15.57% to collection, 10.23% to the native runner, 8.40% to trace entry, 4.64% to tier-0 new-table dispatch and 4.32% to tier-0 return dispatch. Allocator allocation/free account for 6.13%/4.12%. Native runner time includes overhead and is not a measurement of generated instructions alone. No claim that recording removes allocation or GC cost follows from these numbers.

## Guarded absence

An absent result is a successful table lookup, not an invalid container. Check the container is a metatable-free table, then prove the lookup result remains nil. Out-of-array is not sufficient: a numeric key can be hash-resident. Cover narrow-lane presence bits, boolean's zero byte, value-lane nil and hash absence with the same semantic lookup. Existing present fast paths remain available.

A dedicated absence guard reads table and key and exits if the current lookup is non-nil. It produces no payload; the recorder assigns a nil constant only after the guard. It must remain a memory-dependent effect root, not a pure expression or a guard CSE keyed only by table. Deferred writes must be forwarded on proven aliases or conservatively refuse recording, never ignored. Metatable appearance must deopt before an absence result could suppress `__index`.

## Non-replayable effects

Activate explicit snapshots describing a coherent guest instruction boundary. Allocation failure uses the pre-allocation state. Guards after successful allocation preserve that table and resume without executing its allocation again. Table-store failure requires auditing the shared store's partial-mutation/OOM contract; do not assume transactional behavior from its error return.

Snapshot values are liveness roots through optimization and native allocation. Include physical written temporaries, not just source-language live variables: GC roots every register below stack_top. Preserve inline frame reconstruction, current closures, register windows and actual PC where necessary. Both executors must implement the same contract before recording admits the effects.

Deferred stores cannot float past an identity-bearing effect without an explicit ordering proof. Flush them in guest order at the appropriate boundary. No table allocation may be CSE'd, DCE'd or hoisted; even unused allocations consume deterministic IDs.

Existing replay-safe traces may keep entry snapshots. This is not permission to let a trace with committed non-replayable effects take an ordinary entry-replay exit. Every exit path, including arithmetic failures, callout failures, GC budget checks and native links, participates in the precise-state audit.

## GC and native links

Reuse allocation headroom checks to keep collection outside unrooted native execution. Table storage growth uses the injected allocator but does not itself consume GC IDs. Actual table creation consumes exactly one. Write-barrier seams must match tier-0 even though today's stop-the-world collector implements them as no-ops.

A frame-motion episode may end in another activation. Its final precise snapshot belongs to that activation, not the original entry frame. The ledger must make that resume contract explicit. Disable only unsupported links with a stated invariant; do not infer a precise snapshot from a generic guard source/exit PC.

## Verification

Test nil→value transitions, insertion after absence, packed holes and hash-resident numeric keys, metatable transitions, nested and mixed constructors, aliasing, growth and widening. Force guard failures after each effect, verify heap IDs and captured heap state against tier-0, exercise OOM and protected recovery, and collect immediately after exits to compare roots. Add optimizer and serialization round trips for snapshots and witnessed native execution tests, not stdout-only fixtures.

Full gates remain `just test`, JIT-debug tests, both-build hashgate, wasm and visualizer tests. Performance verdicts require fresh canonical benchmarks and jit-stats; a flat result leads back to the profile rather than benchmark-specific specialization.

## Revision 5 — normative implementation contract

The sections below replace the earlier sketch wherever more specific. This is a
reviewed-design candidate, not a claim that the current code implements it.

### D1. Phases and admission

P0 lands guarded absence independently. P1 lands the precise-state substrate with
hand-built traces; P2 enables construction in non-peeled, depth-zero loop/head/cont
recordings; P3 integrates native frame-motion terminal links and runs all gates.
The permanent representation supports extensions; P2 does not pretend to support
reconstructing inlined frames. A recording containing identity-bearing effects
and ANY inlined call is refused, including a call earlier than the first effect.
Conversely no call may be inlined after precision becomes required. Depth-zero
self-call/return terminals remain supported: doc44 already performs real frame
motion after terminal state is materialized. Nested constructors are supported;
nested inline activations are not. This is a checked admission boundary, not a
fallback to replay after committing an effect.

Deferred follow-up: reconstructing inline frames, allocations in peeled traces,
vararg/all-results frame reconstruction, allocation sinking. None is silently
admitted by this change. These are not needed to represent ordinary constructors
in loop/head/continuation traces. No benchmark names or bytecode patterns govern
admission. Full cross-frame precision is a subsequent extension of the snapshot
frame model, not an allocation workaround.

### D2. Snapshot representation and ownership

Add `src/trace_snapshot.zig` (executor-independent types, validation and ref
remapping). `TraceCode` owns `snapshots: []Snapshot` and a flat
`snapshot_slots: []SnapshotSlot`, both freed in deinit and all candidate error
paths. Recorder scratch uses allocator-injected reusable lists. No per-iteration
snapshot allocation. Proposed records:

```
Snapshot { resume_pc: u32, slots_begin: u32, slots_len: u32,
           register_count: u16 }
SnapshotSlot { slot: u16, ref: Ref }
```

Each snapshot describes the CURRENT physical activation of the trace's anchor
proto, relative to that activation's base, not the episode-entry frame. P2 has
exactly one activation per body. Every physical register in the anchor window
is represented exactly once in ascending order, including dead temporaries;
`register_count == anchor.proto.num_registers`. Unwritten slots reference entry
`slot_load`s, not a guessed nil or source-local liveness map. Snapshot creation
forces those entry loads before recording can overwrite their original values.
Revision 4 chooses deterministic re-recording, not retroactive promotion.
Ordinary recordings are unchanged. On first encountering tnew or a general
store requiring precision, discard that candidate with a non-penalizing
needs_precise outcome and mark its anchor for precise recording on the next
normal hotness opportunity. That next recording starts at the anchor, with a
full entry slot_load map emitted before any bytecode. No loads or snapshots are
inserted into an already-running candidate. The mode flag is per-anchor policy,
purely driven by observed bytecode, reset with the anchor's policy lifetime and
never keyed by addresses. It survives the needs_precise cancellation so retry
can happen; no immediate recursive recording or tier0 re-execution is requested.
Explicitly re-arm the deterministic hotness counter to threshold saturating-minus
one, following loop_leave's fast-retry precedent (trace.zig:3365-3382); skipping
blacklisting alone starves a counter already beyond its equality crossing.
Apply the corresponding head/cont counter re-arm, not only loop counters.
Tests drive actual subsequent dispatch/backedges and require a committed precise
trace for each anchor kind.

Only precise recordings incur full entry capture. Legacy entry_slots and phi
writeback membership MUST remain unchanged, including noopt/link/head/cont/peel
finalization. This deliberately avoids changing trace_finalize.zig:52-53's raw
entry_slots filter or relying on tropt.dupe at :85 to prune eager loads (it does
not). The cost is one discarded recording per anchor policy lifetime, rather
than permanent extra inputs and homes in every non-precise trace. Add a named
transition test proving retry is not blacklisted and begins at the real head,
cont or loop anchor with correct original register values.

Snapshot storage has deterministic admission budgets: at most 256 distinct
interned slot vectors, 2000 Snapshot records, and 65536 SnapshotSlot entries per
candidate, including scratch. Snapshot records carry resume_pc and reference a
shared vector via slots_begin/slots_len; two PCs may share a vector but remain
distinct records. The 256 limit applies to vectors, NOT records. Full maps often
differ by one slot, so large bodies can hit the vector/slot bound well before
maxrecord; this is deliberate admission refusal. Intern identical vectors
within these bounds; check before allocation and abort recording with a dedicated
snapshot_limit reason on overflow. No partial candidate publishes. A configured
lower test budget exercises exact-boundary and one-over refusal; native frame
scratch also remains subject to the existing explicit frame-size admission gate.
Budgets depend only on code/recorded maps, never available memory or addresses.

Caller frames and slots outside that activation are untouched. A snapshot does
not change closure, depth, open-upvalue state or stack_top; admission forbids
operations that would require such changes before a terminal: refuse multret_top
updates, stack_top changes, and close-upvalue operations. Require no dynamic
multret state at every snapshot. Existing captured register restrictions still
apply. Guard provenance is not frame state.

Use `IrInstr.snap = 0` for entry replay; positive values are one-based indexes
into `TraceCode.snapshots`. Add `TraceCode.deopt_mode = entry_replay | precise`.
For a precise trace every potentially failing body op has a nonzero snap; entry
prologue/seed failures remain pre-body entry failures. Finalization rejects
missing or invalid snapshots; snapshot allocation failure aborts recording, never
falls back to missing metadata. This is correctness metadata, unlike fail-soft
exit diagnostics.

For precision, create a snapshot at the start of EACH guest bytecode (before its
first IR op), assign it to all its potentially failing IR operations, and update
the register map only with completed instruction results. A successful new_table
binds R[dst] to its result; the next instruction's snapshot therefore resumes at
the next PC with that same table. A failing precondition resumes at the current
instruction, not at its branch target. No sub-bytecode resume is used. Any lowering
with a fallible step after a guest-visible mutation must use D5's error outcome,
not ordinary deopt. Finalization checks each source boundary: after its first
mutation/identity effect no ordinary failing op may follow within that boundary;
an effect helper's own error uses precise_error. Terminal snapshots are the
complete state before ret/call.

Precise recording maintains per-bytecode snapshots from its start, in bounded
scratch reused across recordings. Source-boundary IDs are recorded on IR at
emission and finalization converts them to one-based snapshot indexes. Do not
infer boundaries later from guard aux fields. No retroactive store merge or
recorder-side ref renumbering occurs.

### D3. Effect ordering and optimizer rules

Precise recordings select a single guest-ordered IR stream FROM THE START.
Every store is emitted at its bytecode position; pending_stores must remain
empty and precise finalization asserts that invariant. Legacy recordings retain
their existing deferred-store stream. The needs_precise transition discards the
whole old candidate and resets all its scratch/dedup/provenance state normally;
no reference from it is carried into the next recording. Thus there is no
mid-recording remap of reg_map, exit_prov, input/constant/hash-cell dedup maps,
guarded_refs or pending-link metadata. The only remap is final optimizer
canonicalization/compaction described below. Precise mode records all calls
under D1's no-inline admission, even before its first effect; it cannot acquire
an unsupported inline prefix and then attempt to reconstruct it.

Add `tnew` (next appended ordinal 88) and `tset` (89). `tnew` has no operands,
produces heap/table, and routes through `emitAlloc`: one GC ID, guard_gc budget,
and existing full-write-set finalization (`trace_finalize.zig:52-53`). `tset` reads
table/key/value (`a`, `b`, and ref in `aux`); produces no value; uses shared
Table.set and Heap.writeBarrier semantics. It supports general non-grid,
metatable-free tables, normalized numeric/string/other legal keys and all
ordinary Value values, not just compiler constructor temporaries. Guarded type
specialization may deopt before the operation, but must not reject heap/nil
constructor values by design. Grid/metamethod paths deopt BEFORE mutation.

`tnew` and `tset` are ordered effect roots: no CSE, DCE, hoisting or sinking.
All snapshot refs become liveness roots BEFORE DCE. Constant folding must expose
a canonical-ref map, including removed refs folded/merged into other refs;
`old_to_new` alone (null for eliminated nodes) is insufficient. Apply canonical
mapping then compaction to every snapshot ref; the noopt/dupe path is identity.
A removed redundant guard drops only its own snapshot association, not snapshots
needed by another operation. Precise candidates initially disable LICM,
preheader construction, strength reduction and phi/home coalescing that assume
entry replay; constant folding/CSE/DCE remain enabled after the above liveness
extension. No optimizer may move an effect or a potentially failing instruction
across its guest boundary. Pure value CSE may cross boundaries if it preserves
all snapshot uses and allocation ordering. This restriction is a documented
optimizer capability boundary, not a second execution semantics.

Native allocation extends each SSA value's last use through every snapshot that
references it. Snapshot flush is a parallel copy: stage all sources (including
tag+payload for boxed refs) in bounded frame scratch before writing any slab
slot. Full physical-slot snapshots make arbitrary incoming values necessary:
boxed pass-through must admit snapshot-only uses while still rejecting unproved
typed inspection. No snapshot helper allocates or collects. Full-window maps increase live ranges,
metadata and native home pressure; measure refusals and frame sizes. Snapshot
sparsification (implicit unchanged slots/delta maps without losing physical root
state) is an explicit follow-up, not grounds to omit registers in this contract.

### D4. GC budget and observation

Inherit doc24 D3v2's four obligations explicitly: ordered stores before effects;
precise exits initially unchainable; full physical write/root sets; snapshot refs
participating in optimizer liveness/remapping. Also inherit its observation
blackout and `!gc_stress` budget conjunct. There are no observer callbacks,
keyframes or collections while native/IR scratch holds unmaterialized state.

`guard_gc` executes at each body iteration and each linked page entry, not once
per unbounded burst. It reserves worst-case IDs for ONE body traversal. In a
precise recording emit it eagerly after the entry slot_load block and before
ALL effects; never relocate it at finalization. Legalize aux=0 for precise
nonallocating/mutating bodies, and relax finalize's alloc_count>0 assertion only
for that explicit mode. It still enforces !gc_stress and the ordinary due-GC
check, including tset-only bodies that drop roots. emitAlloc reuses this guard
and increments the bound normally. Failure resumes at the body
entry with the previous iteration's complete physical state. Every link target,
including ordinary_entry/body_entry and same-page self-push, must execute this
check before effects. No target below guard_gc is eligible. GC stress declines
allocating bodies before any effect; tier0 performs its ordinary safepoints.
This preserves the existing deterministic collection boundary argument; it does
not require native collection or a whole-burst allocation reservation.

### D5. Runtime error contract — execute once, never retry OOM

Shared shims live in table_runtime.zig and take *Heap explicitly, using its
injected heap.gpa for storage (assert it is the allocator tier0 passes to set,
vm.gpa). Do not pass a Zig Allocator fat value through the C ABI or reach for a
global allocator. Match the non-grid,
metatable-free tier0 indexSet fallthrough's set/barrier order; the narrow-lane
tier0 shortcut need not call the shim. `tnew` invokes Heap.newTable exactly once; `tset` invokes Table.set
exactly once, with the same barrier ordering as tier0. Both return an explicit
status `ok | out_of_memory | type_error` (fixed C ABI integer) and tnew returns
its pointer via a caller-owned output word. Neither calls VM.collect. Guards
for unsupported grid/metamethod representations fail before invoking the shim.

Table.set is NOT transactional: append then migrate (`table.zig:298-299`), seed
rollback retaining lane state (`302-332`), and rehash then fallible retry
(`348-359`) can leave valid partial mutations. Do not roll them back, retry them,
or make OOM fatal merely for JIT convenience. On error restore pre-instruction
registers, PRESERVE the exact heap left by that single helper invocation, and
propagate the actual error through the interpreter's ordinary located-error
path at the failing bytecode PC. Preserve interp.catchable: OutOfMemory is uncatchable
and unwinds past pcall (catching heap pressure would violate determinism);
TypeError is catchable and uses ordinary pcall recovery. This is an error continuation, not a
bytecode execution continuation. It applies to tnew OOM too, even though tnew
itself links only after successful allocation. It avoids the counterexample of
an injected one-shot OOM succeeding on a second attempted allocation.

No observer/GC/re-entry runs between helper failure and VM error handoff. Earlier
created tables remain in snapshots/registers; unsuccessful tnew has no result.
Barrier calls on error match tier0 exactly. Later representation optimizations
must preserve tier0's single-call partial-error state. Tests compare logical
contents AND serialized array/hash split, next_obj_id and error site. Injection
is targeted at the shared heap/storage allocator operation, not arbitrary global
allocation counts that include compilation/JIT metadata.

### D6. Exit ABI and dispatcher integration

Append `ExitReason.precise_resume` and `.precise_error`; append
`LedgerKind.precise_deopt = 10`, `.precise_error = 11`. Add scalar fields to
ExecResult/NativeResult: `snapshot_id: u32` (one-based),
`runtime_error: u32` (0/oom/type), `activation_base: u32` and
`activation_depth: u32`. The native seed/context exposes the current base/depth;
exit stubs capture them after the last actual frame motion. Tier1a fills them
from its executor context. Result fields are set on every exit (zero for legacy
paths). Use layout offset assertions and ledger encode/decode tests.

Precise exit stubs materialize the snapshot into the CURRENT slab, record final
trace ID + failing IR index + snapshot ID, append a FINAL non-yielded precise
ledger row and return. These exits never patch/jump to another trace. The final
row's ID/index must select the same snapshot as scalar snapshot_id. No extra
snapshot arrays per ledger row are needed because a precise row is always final;
validate this in both ledger consumers. There must be space for the final row:
existing pre-transition capacity checks must yield before entering a child if
no row remains. Precise stubs bypass silent-fusion handlers that assume replay.

Dispatcher validates final trace proto against current activation, base/depth
against the current frame, and snapshot range. It then resumes at resume_pc or
routes the error to the same located-error/pcall path as a failing tier0 opcode.
Validation mismatch is an internal invariant failure, never a replay fallback.
Snapshot sources have already been copied; no stale native spill references
escape the runner. Pushed/popped counters and ledger accounting are drained once
without applying an entry-replay phi flush over the precise state.

P2 prohibits links INTO or OUT OF precise pages. P3 enables only ordinary clean
terminal handoffs (head/cont self-call and return) after full snapshot flush and
body-entry budget checks; precise guard/error exits remain unchainable. Ordinary
side/source, loop-done, composite-bridge, peeled and silent links involving a
precise page stay explicitly ineligible until their own snapshot contracts land.
The predicates must check deopt_mode in BOTH arm and dispatch validation, not
just publication. ret_cont watch keys are bytecode PCs, call_head keys are
terminal IR indexes: never use a generic slot_index as a snapshot index. Lookup
is always `(final trace ID, failing IR index)->snap`, never watch key->snap.

For precise exits, legacy guardExitPc is diagnostic/bucket metadata only, never
a resume PC. P2/P3 suppress wants_side_trace and legacy side-arm requests for
precise guard exits; IR-index taken-exit counters may still be collected. This
prevents a mis-bucketed fallthrough from creating an entry-replay successor.

Required exit audit (each is an implementation checkbox, not an assumption):

- [ ] tier1a guard/arith failures and native shared deopt: choose correct snapshot. *(tier-1a half landed, increment 4; native outstanding)*
- [ ] head/cont deopt: precise pages bypass entryPc(anchor.pc); resume only from snapshot.resume_pc. *(tier-1a `.precise_resume` arm covers all anchor kinds — increment 4; native outstanding)*
- [ ] tnew/tset error: hand error off without retry, preserving partial heap.
- [ ] entry prologue and seed declines: pre-effect only, ordinary entry contract.
- [ ] guard_gc: coherent per-iteration entry state, no effects yet.
- [ ] loop close/terminal: complete physical state and ordered stores committed.
- [ ] loop-done/source/bridge/silent links: precise-page refusal at arm and dispatch.
- [ ] frame-motion final result: current activation validated, no second flush.
- [ ] full-cap yield: no dropped final row and no duplicated effect.

### D7. Absence slice corrections and native path

The current code is NOT approved for landing: `nativegen.proveKinds` admits a
string konst used by both href and guard_absent although href-key marking makes
its kind `.none`. The callout then consumes an unmaterialized pointer. P0 must
make string constants used as values first-class `.heap` values even when also
href keys (update href lowering/proof accordingly); until that support is in
place fail closed on `.none`. Add guard_absent to isSideExitGuardOp so the
existing general guard penalty/headroom accounting recognizes absence exits;
guardExitPc remains null (it is not a branch fallthrough). Add the shared-key two-table regression and require
actual native execution once materialization support lands. Keep the unrelated
`guard_func` comment attached to its own arm. Wire ordinal 87 remains pinned.

Native absence lowering must inline the non-grid numeric common path: validate
metatable-free table; if key is within array bounds, test boolean byte, numeric
presence bitmap, or Value nil tag using current lane/data pointers. If outside
bounds and hash is empty, absence passes; otherwise call the shared full lookup.
Grid tables use full lookup (virtual rows are not nil). All array reads follow
bounds checks; do not dereference numeric bitmaps for bool/value lanes. Hash or
grid fallback preserves live homes via the callout ABI. String keys use lookup.
The table identity/layout is runtime state, never pinned to the recording's
address. The opcode stays a non-CSE memory-dependent effect root.

Pending stores are consulted before lookup; must-alias forwards, may-alias
refuses, no-alias continues. The current skip of hstore in numeric-array
forwarding is valid ONLY for constant-string hstore keys. When general tset is
introduced it is ordered in precise mode, not added blindly to this skip list.
Absence counts as a heap/array read for legacy C1. Test that a following write
cannot change which branch entry replay would take.

Native nil is a distinct boxable kind: materialize zero payload and nil tag,
false truthiness, full phi/snapshot/terminal support, no numeric use. Audit every
kind switch and entry/home/flush path, including one-shot type changes and boxed
copies; do not declare native support solely from the guard helper test.

### D8. Wire format and modules

Extend schema/trace.json with snapshot records and slot vectors, deopt_mode, and
per-trace snapshot arrays. Retain snap's one-based meaning; legacy mode has empty
arrays and zero snaps. Bump traceser.format_version, regenerate Zig and TS codecs
with the repository generator, update enums/decoder/visualizer to render resume
PC and slots, and add a generated binary fixture round-tripped by both languages.
Reject invalid indexes, unordered/duplicate/out-of-window slots, absent required
snapshots, forward refs not defined at that exit, and invalid PCs before native
compilation. Serialized snapshot refs are committed IR refs, never pointers or
native locations. Keyframe capture remains at coherent interpreter safepoints;
restoring a keyframe uses guest state, not ephemeral native snapshot storage.

Keep ownership and pure remapping in trace_snapshot.zig, table C-ABI helpers in
table_runtime.zig, and native snapshot planning/copy logic in a cohesive native
snapshot module. Nativegen integrates these interfaces rather than absorbing
another independent subsystem. Wrappers contain churny stdlib APIs (verify the
pinned source before implementation).

### D9. Acceptance matrix and review gates

Every phase runs bounded just test. No phase enabling effects lands before its
both-tier error/deopt tests. P0 is independently landable only WITH D7's inline
numeric path and the Campaign gate (full board plus jit-stats), not the current
callout-only slice. Investigate and resolve any reproducible regression before
landing; noisy single runs are not acceptance evidence.

| Gate | Required witness |
|---|---|
| P0 absence | numeric holes in every lane, out-of-array hash hit/miss, string shared href key, grid virtual row, metatable transitions; nil->false/heap/int and reverse across entries; native entries >0 |
| P0 C1 | deferred must/no/may aliases, read-controlled following stores, append refusal; optimizer keeps guard and both operand refs |
| P1 snapshot | noopt/opt exact refs, folded/CSE values, full dead-temp roots, boxed parallel cycles/fanout, all snapshot allocation failures leak-free |
| P1 entry capture | needs_precise cancels without blacklist; next recording begins at correct anchor; overwrite slot before effect then deopt before/after it with exact snapshots |
| P1 legacy isolation | non-precise loop/head/cont/link/peel entry_slots and phi-writeback sets unchanged in opt/noopt; no snapshot-only loads leak into dupe path |
| P1 bounds | exact snapshot/map/slot budgets and one-over refusal, repeated-map dedup, OOM cleanup, no partially published trace |
| P1 exits | guards at each instruction, arithmetic failure, clean loop/terminal, missing metadata rejected; no inline or peeled admission |
| P2 construction | empty/nested/mixed-key constructors, identity of dead allocations, heap/nil stores, growth/widen/delete, aliasing, post-allocation type failures; actual tnew/tset native execution |
| P2 errors | targeted OOM at create/seed/append/migration/rehash: uncatchable past pcall, exact error site/partial heap/split/IDs vs one tier0 helper execution, no retry; separate nil/NaN-key TypeError pcall recovery |
| P2 GC | per-iteration budget exhausted, stress refusal, immediate post-exit collect with matched marked-object set and keyframe bytes; no observer mid-body |
| P3 links | real push/pop then precise guard/error, validate activation and final row, cap32 yield, guard_gc on every target; unsupported link kinds refuse |
| Serialization | malformed snapshot rejection, native/TS roundtrip fixture, keyframe restore + continue same IDs/output |
| Campaign | plain/debug unit gates, hashgate both builds, wasm + viz; seven-rep board and jit-stats on flat/regressing rows, profile before optimizing |

The existing absence-only measurement is399.1ms vs370.0ms fresh baseline,
with159869 native pops/159819 return-link hits. It is evidence of execution,
not evidence of speedup. Re-measure inline absence before claiming a performance
result. Known defect A1, doc24 D3v2 obligations, and the Table.set error contract
must be explicitly accepted in subsequent independent reviews.

## References

- Docs 01, 02, 03, 04: lifecycle, determinism, GC and replay contracts.
- Doc24: interned allocation, explicitly excluding non-interned objects.
- Doc44: native frame-motion and continuation links.
- LuaJIT `src/lj_record.c`: `rec_tnew`, `lj_record_idx`.
