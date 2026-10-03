# Doc 60 H1 implementation review, round 2 — codex

Reviewer: codex (`mcp__codex__delegate`, same thread as round 1),
2026-10-03. Input: `/tmp/h1-r2.diff`, doc 60 §10 "H1 implementation review".
Disposition: doc 60 §10.

---

VERDICT: CHANGES REQUESTED

1. **Major — Closure identity is still incompletely compared.** src/capi_hostcall_test.zig:150, :990.

   Closures identify their proto only by name. Both closures returned by the new `pair` fixture are named `anonymous` and share the same upvalue. Swapping those two results therefore produces identical normalized snapshots, despite returning functions with different behavior. Keyframes are disabled for this fixture. Anchors have the same name-only weakness.

   **Fix:** include the VM-unique `proto.id` in closure, anchor and frame rendering. Add a check proving that swapping the fixture's two closures changes the snapshot.

2. **Major — Active recording constants are counted, not compared.** src/capi_hostcall_test.zig:255.

   Despite the comment promising every recorded constant, the dump includes only `rec.consts.items.len`. IR constant operands contain pool indices, so identical IR and pool lengths can hide different constant values. Committed-trace serialization does not cover an unfinished recording. The new peek fixture also does not assert that it observed an active recording with nonempty constants.

   **Fix:** render every constant through the shared alias-aware `Dump.val`, and add a nonvacuous snapshot fixture checking an active, nonempty constant pool and detecting a changed value. Round-1 finding 1 remains partially unresolved.

3. **Minor — Deep table rendering loses grid contents and row-view identity.** src/capi_hostcall_test.zig:112, :134.

   Grid rows use keys `1..rows`, as Table.getInt (src/table.zig:137) specifies. Iterating `0..asize` includes key zero and omits the final row. Remaining rows render only their row number: neither their cells nor their parent identity is compared. Different grid contents can consequently produce identical dumps, particularly during peeks where no keyframe is captured.

   **Fix:** add nonmutating grid-aware rendering of every logical row and cell, preserve parent identity for row views, and add a fixture that asserts it actually observed a grid.

4. **Minor — Record/replay coverage claims remain contradictory.** docs/design/60-hand-written-machine-code.md:1094, :1151.

   The revised checklist correctly marks embedding record/replay legs outstanding, but §6.1 still says those modes run, and §6.2 still describes embedding-supported modes as existing today. The §10 disposition therefore overstates resolution of round-1 finding 6.

   **Fix:** align both sections with the checklist: three tiers currently run; embedding record/replay legs await the missing embedding capability.

Round-1 findings **2–5 are resolved**: the lifecycle checks and positive fixtures are substantive, suspension is checked before mutation, blobs are compared byte for byte, and §5.5 now qualifies its conclusions appropriately. I found no new supported-path runtime regression, missed setter, spurious lifecycle assertion, or leak in the new snapshot ownership paths. Hash-slot ordering is deterministic for the current fresh-VM legs; restore legs would need separate treatment.

Validation: **1,612 Debug tests passed**, both filtered ReleaseFast suites passed, and dependency checks passed. Project files remained unchanged.
