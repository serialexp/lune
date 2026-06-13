# TODO

Deferred items noted in passing (Rule #10) so they don't get lost.

## Recorder: intern duplicate konsts / subexpressions at record time

The trace recorder emits a **separate** `konst` instruction for every literal it
sees, even when the same constant recurs in the loop body. Example: `acc +
(i + 7) * (i + 7)` records `k0 = 7` and `k1 = 7` as distinct instrs, so the two
`i + 7` adds have different operand refs `(slot, k0)` vs `(slot, k1)` — and the
optimizer's CSE (operand-ref-sensitive) cannot merge them. CSE therefore rarely
fires on real traces today (the `tropt` CSE pass is correct and unit-tested; it
just isn't reached). Const-guard elimination *does* fire on those duplicate-konst
guards, so the loops still shrink.

**Fix:** dedup constants in the recorder's const pool (a small
`AutoHashMap(value-bits → ref)`), and optionally hash-cons pure subexpressions as
they're recorded. Then identical subexpressions share refs and CSE collapses
them. Out of scope for Phase 6b (optimizer-only); revisit when touching the
recorder. — noted during Phase 6b Increment C.
