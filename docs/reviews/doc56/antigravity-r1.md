# Design Review: doc 56 (Revision 1) — Exit-started side traces

Reviewer: Antigravity (gemini-3.1-pro), 2026-09-24. Receipt copied verbatim
from the review response. Dispositions are in doc 56 §11.

# Verdict: CHANGES REQUESTED

The core objective of doc 56—bringing exit-started side traces with resume-coherent hops to mahina to break the combinatorial sibling explosion on branchy/variable-trip loops like `scimark-fft`—is the right architectural direction and honors Rule Z-7. However, the document has three critical soundness and architectural blockers: (1) a fatal coordinate-space mismatch between pre-optimization `PendingStore.pos` and post-`tropt` IR indices, (2) an unhandled ambiguity in the tier-0 recording re-run when resume PC `P` lies inside an unrolled loop (e.g. `fft_bitreverse:55`), and (3) an ad-hoc "rowless" mode in Phase 7 that bypasses `replayLedgerFrom`'s validation and violates Rule Z-8 (exit patching and silent promotion already exist).

---

## Numbered Findings

### 1. [BLOCKER] `PendingStore.pos` vs `guard index` coordinate space mismatch under `tropt`
- **Evidence:** doc 56:273-278, `src/trace_finalize.zig:45-50, 98`, `src/tropt.zig:743-785`.
- **Analysis:** Doc 56 specifies:
  > `PendingStore.pos`: The IR length at the time the store was deferred, i.e. its program position. The armed exit applies `{s | s.pos < guard index}`, in order.

  `s.pos` is captured from `rec.instrs.items.len` during recording. In `trace_finalize.zig`, `pending_stores` are appended at the end of the trace, and then `tropt.optimize` runs. `tropt` performs dead code elimination, constant folding, CSE (`canon`), compaction (`new_index`), and LICM preheader hoisting (`order`). Consequently, `guard index` in the committed trace is in compacted post-optimization coordinate space, while `s.pos` is in uncompacted pre-optimization space. If instructions preceding the guard are eliminated or compacted, a store that preceded the guard in guest execution can have `s.pos >= guard.index`, causing it to be silently dropped by the materializer. Furthermore, `PendingStore` is not stored in `TraceCode`, and its operand references (`aref`, `value`) are never remapped through `tropt`'s `new_index[canon[...]]`.
- **Suggested Fix:** Discard raw IR length comparisons. Associate each sunk store with its guest bytecode boundary / snapshot index (`store.snap = cur_snap`). In `TraceCode`, retain the sunk store descriptors with their `aref` and `value` operands remapped through `tropt` (just as the trailing store IR nodes are). The exit materializer then applies stores satisfying `store.snap < guard.snap`.

---

### 2. [BLOCKER] Ambiguity and false triggers in tier-0 re-run when resume PC `P` is inside an unrolled loop
- **Evidence:** doc 56:314-320, 465-470, doc 55:405-416, `src/trace_types.zig:87-97`.
- **Analysis:** Doc 56 specifies starting exit-side recording by letting tier-0 re-run the iteration from the anchor header until it reaches `P`:
  > When tier-0 reaches `P` in the anchor frame, before the next back-edge to the parent's anchor, the dispatch prologue starts a `.exit_side` recording at `P`.

  In unrolled loops (which `fft_bitreverse:9` specifically is, unrolling `while k <= j`), an inner bytecode PC `P` is visited on *every unrolled trip*. For exit 75 (the 4th trip taken), the alternate path is the `while` body `P = :57`. During the tier-0 re-run from the outer `for` header, tier-0 executes `P = :57` on trip 0, trip 1, trip 2, and trip 3. Triggering recording on the first arrival at `pc == P` causes recording to begin on **trip 0** instead of trip 3. The recorder captures the entry fingerprint and values of trip 0 (`k = 1024, j = 1024`) instead of trip 3 (`k = 128, j = 0`). When the compiled parent trace deopts at exit 75 and hops to this side trace, its entry guards will immediately fail or compute garbage.
- **Suggested Fix:** Disambiguate the arrival during the tier-0 re-run. The want descriptor must be `wants_exit_side = {parent_id, exit_instr, P, skip_count}`, where `skip_count` is the number of times `P` was executed in the parent trace prior to `exit_instr`. The dispatch hook in tier-0 decrements `skip_count` on each visit to `P` and initiates recording only when `skip_count == 0`.

---

### 3. [BLOCKER] Phase 7 "rowless" mode bypasses ledger validation, cycle retirement, and blackout bounds (violates Rules Z-7 & Z-8)
- **Evidence:** doc 56:60-63, 417-427, 502-506, `src/trace_chain.zig:1472-1477, 1862-1864, 2061-2075`, doc 55:264-328.
- **Analysis:** Phase 7 proposes:
  > A DONE-latched attached exit needs no hotness accounting, so its hop writes no row...

  Omitting intermediate rows in `NativeResult.ledger` breaks foundational invariants in `replayLedgerFrom`:
  1. `replayLedgerFrom` validates adjacent rows against registered armed successors. If a parent hops rowlessly to a child, and the child logs a terminal row, the ledger has an orphan row whose owner was never entered, triggering release `@panic`s (e.g. `replayLedger: unexpected transition` or `driveSeedLedger: first entry does not belong to the seed`).
  2. If the entire cycle runs rowlessly, `ledger_len` never increments, so `LEDGER_CAP` never triggers, creating an unbounded execution blackout with no yield mechanism.
  3. Provenance cycle retirement (`max_edge_strikes`) depends on observing `local == 0` rows to detect spinning zero-progress cycles.
  4. Most importantly, Rule Z-8 explicitly warns: *native exit patching and silent promotion are BUILT and always on*. Doc 55 §2d established that closed cycles eliminate per-row overhead via data-driven **silent promotion** under `silent_budget`. Inventing an ad-hoc un-budgeted rowless mode is disposable scaffolding that violates Rules Z-7 and Z-8.
- **Suggested Fix:** Eliminate Phase 7. In Phase 6, emit standard `LedgerKind.exit_side` rows during discovery/warmup. Classify `exit_side` hops and the child's `.link` back as intra-region edges of the parent's loop region (Q2). Once the region qualifies, let the existing **silent promotion** engine promote the cycle. It will execute with zero ledger appends, bounded safely by `silent_budget`.

---

### 4. [MAJOR] Sunk stores of the current bytecode must not be flushed on non-branch guard failures
- **Evidence:** doc 56:298-305, 529-533, `src/trace_recorder.zig:2280-2338`.
- **Analysis:** For non-branch guards (e.g. `guard_bounds`, `guard_fits` during `set_index`), doc 56 specifies:
  > Every other guard: the source bytecode itself, which is re-executed from the boundary snapshot taken before it.

  If the guard failed during lowering of a store bytecode (e.g. `guard_fits` fails because `v` does not fit the current array lane), the source bytecode is that `set_index` instruction. If the materializer flushes stores up to that instruction including this store, the value would be forced into the array lane before deopting. Then tier-0 would re-execute `set_index` and execute the store a second time. Worse, if `guard_fits` failed, forcing the store into the lane would corrupt the lane or violate memory safety.
- **Suggested Fix:** State normatively that at a guard in bytecode $B$, the materializer applies only stores from strictly *prior* bytecodes (`store.snap < guard.snap`). Any store originating from bytecode $B$ itself is excluded from the exit materializer.

---

### 5. [MAJOR] Linking into a peeled child is unsound due to entry-state type mismatch
- **Evidence:** doc 56:382-384, 518-524, `src/trace_link.zig:1642`, `src/trace_recorder.zig:5348-5358`.
- **Analysis:** Doc 56 considers lifting the doc-39 peeled fusion exclusion for `exit_side` links (Q4). While a peeled parent can exit if the run-once vs. steady completion split is accounted for, linking **into** a peeled child (`child.code.peeled`) is unsound. A peeled trace's `ordinary_entry` executes its run-once region and enforces entry type guards for the un-stabilized iteration 1 types (e.g. integer `k`). A side trace running in steady state (where `k` is float) jumping into `child.ordinary_entry` will fail the child's entry guards on every iteration.
- **Suggested Fix:** Maintain `!child.code.peeled` in `arm` validation for `exit_side`. Note that `fft_bitreverse:9` is a numeric `for` loop (`isPlainWhileAnchor` returns false), so `t1` at `:9` is NOT peeled. The peeled child restriction does not affect the fft bit-reverse target.

---

### 6. [MAJOR] Machine code bloat from unrolled static materializers at every attachable exit
- **Evidence:** doc 56:384-396.
- **Analysis:** Emitting a fully unrolled out-of-line machine code stub (preceding sunk stores, snapshot slot flushes, carried home flushes) for *every* attachable exit at compile time will severely bloat mcode. In loops with 30–50 unrolled guards (such as unrolled bit-reverse or matrix loops), each materializer stub can reach 150–250 bytes. That adds 5–10 KB of cold code per trace, even though only 1 or 2 exits ever become hot and attach.
- **Suggested Fix:** Rather than emitting inline register moves for all snapshot slots at every exit, have the exit stub load a pointer to the static snapshot descriptor and call a shared runtime materializer helper (analogous to LuaJIT's `lj_snap_restore`). Only emit direct unrolled materializer stubs if profiling proves the memory handoff in the shared helper is a measurable bottleneck.

---

### 7. [NIT] Tier-1a materialization locus: `irinterp` vs `driveChain`
- **Evidence:** doc 56:359-366, `src/irinterp.zig:1290-1326`, `src/trace_chain.zig:220-230`.
- **Analysis:** Doc 56 states that in Phase 4, `driveChain` materializes the snapshot and sunk stores because "`irinterp` has every ref's value". In the implementation, SSA `values[]` is local to `irinterp.executeImpl` and is not passed to `driveChain`.
- **Suggested Fix:** State clearly that tier-1a materialization of snapshot slots and sunk stores must occur inside `irinterp.executeImpl` at the guard failure point (following the `.precise_resume` precedent), ensuring `regs` is already coherent when `driveChain` inspects it.

---

## Answers and Recommendations for Open Questions Q1–Q6

### Q1 — Row policy for attached hops
- **Recommendation:** **Reject ad-hoc rowless mode.** Omitted rows break `replayLedgerFrom`'s graph validation, lose cycle strike detection, and remove the yield bound. Emit `LedgerKind.exit_side` rows during Phase 6 warmup, and achieve zero per-row overhead in steady state via **silent promotion** (doc 17 B-3 / doc 55 §2d) under `silent_budget`.

### Q2 — Region topology for `exit_side` edges
- **Recommendation:** **Classify `exit_side` and the side trace's `.link` back as internal edges of the parent's loop region.** Exit-side traces complete an iteration started by the parent and link back to the parent's loop header; they are intra-iteration CFG branches. Including them in the parent's region allows the region to close and qualify for silent promotion.

### Q3 — Snapshot liveness
- **Recommendation:** **Do not recompile parent pages.** Recompiling parents creates mcode churn and code cache invalidation. Sparse snapshots already restrict liveness to `.def` slots. Keep snapshot refs live in the parent's linear scan, but if register pressure forces spills, allow snapshot slots to read from spill slots or the coherent slab.

### Q4 — Peeled parents
- **Recommendation:** **Defer peeled parent linking to a follow-up increment; never link into peeled children.** Bit-reverse's outer loop `t1` at `:9` is a numeric `for` loop, which is never peeled (`isPlainWhileAnchor` rejects it). Bit-reverse does not require peeled parent support to achieve the §9 budget.

### Q5 — Routing precedence
- **Recommendation:** **Prioritize existing live arms over new exit-side recording.** If an exit already has an armed link (`sibling_handoff` or bridge), dispatch through it. Only un-armed attachable exits should route to `wants_exit_side`. This prevents regressing tuned workloads like `nsieve`.

### Q6 — Non-branch resume
- **Recommendation:** **Enforce strict inter-bytecode snapshot scoping.** The audit confirms that within single bytecodes, guards precede register/heap writes. However, store bytecodes emit guards (`guard_bounds`, `guard_fits`) before their store executes. The materializer must only flush stores satisfying `store.snap < guard.snap`, ensuring the current bytecode's store is never flushed prior to re-execution in tier-0.
