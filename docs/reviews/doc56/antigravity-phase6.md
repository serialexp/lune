# Doc 56 Phase 6 — code review (Antigravity, 2026-09-27)

Scope: the uncommitted Phase 6 diff (items 1–10 of §4.8.2), against
§4.8.2 and the "Phase 6 landed" notes in §4.8.3.

**Verdict: APPROVE.**

Verified in source (reviewer's summary):

- `emitSilentEpilogue`'s `.exit_side` arm: `last_local` is stored before
  `inc r8`; region and selection work get `local + 1`; the shared tail
  reloads r8 from `silent_transitions`; rax keeps the metadata pointer
  through the slot jump.
- Data-cell lifetime: `exit_side_metadata_cells` is allocated with
  `exit_side_cells` and freed in `CompiledTrace.deinit`; `unpublish`
  leaves the adapter and its cell alive until parent teardown;
  `resolveSilentSite` results are used synchronously.
- Cell keying: `promoted_cell_owners`, `prepareSlotMutation` on the
  physical cell, `demoteSetReason` zeroing the edge's own cell,
  `noteExitSideChain` disarming before it unpublishes.
- `detectPromotableSetMembers` sorts and deduplicates on `(parent,
  cell)` and matches rows by `(id, exit, kind)`.
- Accounting parity between the replay grammar and the silent drain,
  including the `.link` iteration credit and the rowless return.
- The dispatcher's silent branch routes `ChainResult.exit_side`; the
  burst-skip counter's conditions.
- Determinism: integer keys, deterministic sort order.

## Findings and dispositions

1. **MINOR — test gap.** No test disarms an already-promoted
   `.exit_side` link directly (test (c) disarms before promoting; (e)
   demotes through `resetLinksTouching`). **Taken:** new block (d') in
   `checkSilentExitSide` promotes `{link, exit_side}`, disarms the
   exit-side link with `disarmLinkAt`, and checks one demotion, no live
   set, a zero adapter data cell and the cell no longer owned.
   Mutation-checked: making `demoteSetsTouching` skip exit-side cells
   fails it in (d').
2. **NIT — `promoteSet`'s pre-validation omits `validated.cell !=
   edge.cell`** (harmless: `silentSiteFor` checks it). **Taken** in both
   validation loops (activation and resident paths), for symmetry.
