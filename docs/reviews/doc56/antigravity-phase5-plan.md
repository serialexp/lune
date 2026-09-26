# Doc 56 Phase 5 plan review — Antigravity (2026-09-26)

Scope: doc 56 §4.8.1 "Phase 5 plan" (the adapter's direct jump into the
child, `ArmKind.exit_side`, the `.exit_side` ledger row in replay,
dispatcher routing), checked against `src/trace_chain.zig`,
`src/trace_native_registry.zig`, `src/interp.zig`. Read-only review with
tool access. The first attempt (a broad prompt) timed out after 900 s; the
second, scoped to the plan plus named source ranges, answered.

**Verdict: CHANGES REQUESTED.** Eight findings, all verified in source and
accepted. Dispositions are folded into §4.8.1 ("Review" at its end).

1. **Blocker — the dispatcher's `.exit_side` arm swallows multi-row
   ledgers.** `interp.zig:4154` runs before `driveDispatcherLedger`
   (`:4305`) and asserts `ledger_len == 1`; once `ledger_len == 0` leaves
   the stub, a cycle that yields at the adapter returns `exit_reason =
   .exit_side` with a full ledger, which would assert (debug) or drop the
   prefix (release). Fix: gate the arm on `!ran_native or ledger_len <= 1`,
   like the seed-decline handlers (`:3858`). **Accepted.**
2. **Blocker — `publishValidatedLink` does not work unchanged.** It derives
   `physical_slot` from the kind (`trace_native_registry.zig:796-814`); an
   `.exit_side` kind would fall to `else` and write `c.slots[ei]`, the
   ordinary deopt cell. Fix: an explicit `.exit_side` case,
   `physical_slot = exit_side_base + slot_index`. **Accepted** (the plan
   meant only prepare/commit/disarm were unchanged; now explicit).
3. **Major — `region_dest` for a non-last `.exit_side` row.** The existing
   expression (`trace_chain.zig:1708-1713`) yields `.known_trace` for every
   non-last non-handoff row. Fix: add `e.kind == .exit_side` to the
   `.deferred` condition. **Accepted** (the plan stated the value, now it
   names the site).
4. **Major — `EntryMaterialization` has no `via_exit_side` and
   `applyEdgeCursorTransition` takes no exit.** The prologue-fail disarm
   needs `(parent, exit)`. Fix: `ExitSideEntry { parent, exit }` variant;
   `applyEdgeCursorTransition` grows an `edge_exit` argument (all callers
   updated). **Accepted.**
5. **Major — `ChainResult` cannot carry the terminal exit-side directive**,
   and the dispatcher reads only `resume_pc` after `driveDispatcherLedger`
   (`interp.zig:4306`). Fix: `ChainResult.exit_side: ?ExitSideTerminal`,
   populated by the driver, handled by the dispatcher before its generic
   resume. **Accepted.**
6. **Minor — hop counters on the ledger path.** `exit_side_hops` /
   `exit_side_native_hops` are bumped only in `consumeExitSide`; ledger
   rows must bump them too (`interp_native_test.zig:882` pins
   `exit_side_hops == exit_side_chains + 1` on tier-1a). **Accepted.**
7. **Minor — M1 row switch.** Needs an explicit `.exit_side` case with
   `row_local == 0` asserted. **Accepted** (already planned; the assert is
   now spelled out).
8. **Nit — parallel per-slot arrays.** `link_hit_counters` and
   `slot_rowless_ok` are sized `n + NATIVE_TRANSITION_SLOTS`; size them to
   `slots.len` on stub pages so every per-slot invariant holds. **Accepted.**
