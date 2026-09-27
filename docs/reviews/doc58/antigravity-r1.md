# Doc 58 rev 1 — design review round 1 (Antigravity, 2026-09-27)

**Verdict: APPROVE WITH CHANGES.** Dispositions are in doc 58 §8.

Summary of the review:

- **§3 fact map:** every claim verified in source, with one caveat: on
  a PEELED trace, `deopt_exit` skips the carried-home flush when
  `rbx == entry_rbx` (`nativegen.zig` ~2738–2743), so the registers
  are not coherent at the post-loop pc there.
- **Option A soundness:** sound for unpeeled `while` roots. The flush is
  the same whether the exit goes to tier-0 or a continuation (no mode
  flag needed). Boxed carried slots only exist on one-shot traces; no
  sunk stores are pending at a top-of-trace condition guard when the
  prefix is pre-effect; `whileLoopDonePostPc` already refuses inline
  depth > 0 and loop-test copies; cumulative rbx is handled by
  `local = rbx - entry_rbx`.
- **Accounting:** region work 1, selection work `local` (not
  `max(local, 1)`), no extra iteration credit — matching the scalar
  receipt at `interp.zig` ~4486–4492.
- **A.1 vs A.2:** A.1 is not buildable (compile-time row kind in
  `emitLedgerAppend`, register pressure around the doc 54 rowless
  sibling fast path, one `.deopt` silent site per exit). A.2 (own label,
  like numeric `for`) is clean.
- **Slot sharing:** S1 would remove doc 38's glue figure-eight (78.5
  vs 137 cycles/iteration on low-trip loops). Recommended S2.
- **Regions:** `resolveSuccessorAnchor` must get the `while` edge; a
  `whileLoopEndFor` twin is enough for owner election. Careful with the
  provenance drain's `isLoopDoneGuardIndex` skip (broadening that
  predicate would stop glue siblings arming).
- **Missing items:** tier-1a already chains (`driveChain(.ir,
  .while_done)`); the `.low_trip_while` gate; keep
  `hasNativeLoopDoneLink` numeric-only; keep doc 56's while-done
  refusal; tests for zero-trip, peeled refusal, sibling coexistence and
  the forced yield.
- **Option B:** not required by Rule Z-7; anchoring at the condition is
  a measured doc 38 choice.

Findings: 2 BLOCKER (A.1 infeasible; no `while` region edge), 3 MAJOR
(peeled roots; S1 loses the glue figure-eight; `hasNativeLoopDoneLink`),
2 MINOR (accounting argument order; `.low_trip_while` gate), 1 NIT
(redundant preconditions).

Not taken as stated: S2 on one cell — one silent site and one data cell
per exit (`trace_native_registry.zig` ~174–196) cannot serve two exit
paths; doc 58 §5 now offers S3 (a second cell) with the test order as
the choice.
