# Doc 56 Phase 4 plan review — Antigravity (2026-09-26)

Scope: doc 56 §4.6.1 "Phase 4 plan" (native exit adapters that
materialize at `P` and return to the runtime), checked against the
native emitter, allocator, exit location map, arena, dispatcher and
ledger replay. Read-only review with tool access.

**Verdict: APPROVE WITH CHANGES.** All six findings were taken into
§4.6.1.

1. **Silent runs slip past the `ledger_len == 0` check.** A promoted
   silent transition writes no ledger row but sets `silent_active`, and
   the dispatcher sends such a result through `driveDispatcherSilentResult`
   → `replayLedgerSuffix` → `replayLedgerFrom` before the `.exit_side` arm,
   which would panic on the new row. **Taken:** the stub also requires
   `silent_active == 0`.
2. **The store emitters index `kinds[ins.b]`**, which neither `Alloc` nor
   the map keeps. **Taken:** the adapter builds a synthetic `kinds` slice
   from the map rows.
3. **`emitPreciseSnapshotFlush` needs the real slot table** (it refuses a
   `slot_load` with `slot_id_of_ref < 0`). **Taken:** the snapshot flush is
   a dedicated loop over map rows, using `ExitLoc.invariant_slot`.
4. **No ownership fields yet** for adapter pages and cells. **Taken:**
   `CompiledTrace` gets `exit_side_cells`, the adapter pages and their heap
   target cells, all freed in `deinit`; target cells never live in the RX
   page.
5. **Boxed-tag spill cells sit past `spill_count`** (`boxedTagSpill`).
   **Taken:** constant staging starts past them; the map records the
   frame's true end.
6. **`driveChain` asserts `.exit_side` is tier-1a only**, and
   `consumeExitSide` hard-codes `.tier1a_direct`. **Taken:** both change.

Confirmed sound by the reviewer: `rax` and the flags are dead at every
guard exit (the stub already clobbers `rax`), and the materialization
order (stores → carried homes → snapshot slots) is correct, with carried
homes the right base for slots the sparse snapshot omits.
