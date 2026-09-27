# Doc 56 Phase 6 plan review — Antigravity (2026-09-27)

Scope: doc 56 §4.8.2 (Phase 6 plan, silent exit-side cycles), checked
against source with tool access. Read-only.

**Verdict: CHANGES REQUESTED.** Nine findings. Each was checked in source
before being folded into §4.8.2.

Confirmed without change:

- The `.exit_side` epilogue accounting (`region_work` and `selection_work`
  `+= local + 1`, productive, barren reset) equals the replay row's charge
  (`trace_chain.zig` ~1744 `local + 1`; `accountLedgerRow(owner, local + 1,
  …)` ~1843; `accountLedgerRowsBulk` applies the bulk twin).
- The silent drain credits no `linkClosesIteration` `+1` today; the replay
  credits every `.link` row before its `is_last` test, so `fires` (not
  `followed`) is the right count.
- The dispatcher drains a silent result (`interp.zig` ~3896) before its
  scalar `.exit_side` arm (~4224).
- The epilogue's `ledger_len != 0 → reporting_target` rule keeps silence
  from resuming after an adapter row.
- A suffix whose first row is `.exit_side`, and a promoted `.exit_side`
  edge as the last silent edge (`applyEdgeCursorTransition` sets
  `.via_exit_side` and `resume_pc = P`), both replay cleanly.
- Register discipline: after the adapter's materialization rax and the
  flags are dead; the epilogue keeps rdi/rsi/rdx/rbx, the child's entry
  contract. The exhausted path leaves the slab coherent at `P`. The silent
  path never writes `exit_reason`, which the wrapper's
  `ledger_len == 0 ⇒ exit_reason == .normal` assert needs.
- G1–G4 confirmed in source: `armExitSide` picks through
  `resolveLoopDoneCont(proto, p, null).arm` (`trace_link.zig` ~594; the pick
  is by hit count then id, no types, `trace.zig` ~2504); the stub branches
  to the adapter before the bridge/ordinary slot (`nativegen.zig`
  ~2561-2568); the exit-side disarm is set only in the `.prologue_fail` arm
  (`trace_chain.zig` ~2419), so a body-guard deopt never disarms.

Findings:

1. **BLOCKER (accepted as MAJOR) — the rowless silent return drops
   `linked_completed`.** `driveSilentBurst` returns `completed =
   silent_cum` (rbx) with no suffix (~1271), and `finishDispatcherDirective`
   passes `.return_result` through unchanged. In an exit-side cycle the
   parent never reaches its `.loop` and `.link` does not bump rbx, so the
   count is lost. Verified; downgraded to MAJOR because the dispatcher
   origin does not read `ChainResult.completed` (burst origins do). Fix:
   the rowless return reports what replaying the same rows would; pinned by
   the rowed-vs-silent equality test.
2. **BLOCKER — `interp.zig` ~3903 asserts `chain.exit_side == null`** after
   the silent drain. A suffix ending in an unarmed `.exit_side` row makes it
   non-null. Fix: route it there as the ledger path does (~4380).
3. **BLOCKER — `promoteSet` builds `slot` and `reporting_target` from the
   parent page** (`&compiled.slots[edge.exit]`, `compiled.page.code.ptr +
   resume_off`, `trace_native_registry.zig` ~749-753). For an adapter site
   both are wrong (wrong cell; an address inside the parent's code). Fix:
   `&slots[edge.cell]` and the adapter page's base.
4. **MAJOR — `demoteSet` zeroes `metadata_cells[edge.exit]`** (~460): for an
   exit-side edge that clears the ordinary cell and leaves the adapter
   promoted. Fix: zero the edge's own cell.
5. **MAJOR — `dropParkedProofsTouchingExit` compares `edge.exit` with the
   PHYSICAL slot** `prepareSlotMutation` passes (~406), so an exit-side
   parked proof is never dropped. Fix: compare `edge.cell`.
6. **MAJOR — `detectPromotableSetMembers` sorts and deduplicates on
   `(parent, exit)`** (`trace_link.zig` ~1304-1317), rejecting an exit with
   both a sibling handoff and an exit-side arm. Fix: `(parent, cell)`.
7. **MAJOR — `silentSiteFor`/`silentSiteAt` search only the parent page's
   `silent_sites` and test `metadata_cells[edge.exit]`** (~143, ~341). Fix:
   an `.exit_side` edge resolves the adapter's site and its
   `exit_side_metadata_cells` cell.
8. **MINOR — `noteMembershipGrowth` asks `exitIsPromoted(parent, slot_index)`
   with the logical exit** (~2042). Fix: the cell for the arm's kind.
9. **NIT — spell out the epilogue registers for `local + 1`** (r8 holds
   `local`; the `.exit_side` arm must not leave r8 changed for later code,
   or must use r9).
