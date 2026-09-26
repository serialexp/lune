# Doc 56 Phase 5 code review — Antigravity (2026-09-27)

Scope: the uncommitted Phase 5 change (`git diff HEAD -- src docs`): the
adapter tail's direct jump into an armed child, `ArmKind.exit_side` and its
own physical cell (`exitSideSlot`), the `.exit_side` replay arm and
`.via_exit_side` entry, `ChainResult.exit_side` and the
`consumeExitSide` / `routeExitSide` split, arming after a linked chain and
disarming on child prologue failure, plus the two bug fixes (`driveChain`
linked-ness of a seed ledger headed by the seed's `.link`; region guard
edges in `resolveSuccessorAnchor`). Read-only review with tool access,
asked to be adversarial on six named points.

**Verdict: APPROVE WITH CHANGES** (one minor, one nit; no blockers).

Findings:

1. **Minor — `routeExitSide`'s null `resume_pc` fallback** (`interp.zig`).
   The not-linked path fell back to the parent's anchor when a chain left
   no resume pc. `driveChain` always publishes one under `.exit_side`
   materialization (every return path sets `walk_pc` / `target_pc` = `P`
   or a replayed ledger's pc), and resuming at the loop header would be
   wrong there, since the slab is coherent at `P` or later. **Fixed:** the
   not-linked path now fails loudly (`@panic`) on a missing pc, and the
   doc comment states the two conventions (linked: null means the header;
   not linked: a pc is always published).
2. **Nit — `armedEdgeInBridgeFreeCycle`** (`trace.zig`, jit-debug
   telemetry only). It matched the first armed link on `(parent,
   slot_index)` except bridges, so an `.exit_side` arm could answer for a
   sibling arm on the same exit. **Fixed:** it skips `.exit_side` too.

Verified sound by the reviewer (with file:line evidence in the session):
- adapter tail: `exit_reason = .exit_side` is written before the row
  append; the forced-yield check stamps `.yielded` and redirects to
  `shared_exit`; the reset to `.normal` happens only when jumping into a
  child; nothing is appended after a yield;
- replay accounting: `accountLedgerRow(owner, local + 1, …)` matches the
  direct path's `completed + 1`; `linked_completed += local` leaves the
  interrupted iteration to the child's closing `.link` or to tier-0, so no
  double or missed count; `region_dest = .deferred`; the static contract
  and successor checks; the child's deopt / prologue-fail / seed-decline
  arms under `.via_exit_side` resume at `P`, and prologue failure stages
  the disarm drained after the walk;
- slot layout: `slots`, `link_hit_counters` and `slot_rowless_ok` are all
  sized to `slot_count` on stub pages; every `armed_links` lookup keyed on
  `(parent, slot_index)` either compares the physical slot or filters the
  kind, so a `sibling_handoff` and an `.exit_side` arm on one exit never
  answer for each other (except the telemetry helper in finding 2);
- `resolveSuccessorAnchor`: with the switch off, no correct region edge is
  lost (branch-guard fall-through pcs only anchored traces through
  exit-side children); the loop-done successor pc is the post-loop pc;
- the router's `resume_pc != p` path is required when a continuation
  deopts through an armed sibling handoff and stops elsewhere.
