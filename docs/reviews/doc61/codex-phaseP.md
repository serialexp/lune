# Codex review: doc 61 Phase P implementation (2026-10-09)

Codex thread `01a11e7d-429b-7400-a312-a9bd32ee7093`. A read-only review of the
uncommitted P1–P4 hunks. Codex ran the Debug `zig build test` and the Phase P
tests in ReleaseFast, and both passed. A nested-callback program agreed across
tier-0, trace and native.

## Findings and disposition

1. **Blocker: the executing native callee was unrooted in `callValue`.**
   - Codex's finding: only `args` were parked. A metamethod native whose
     callback removes the last reference to it and collects is freed while it
     runs, along with a host fn's `CHostCtx` and userdata. `cHostCall` then
     reads freed `h.box`.
   - **Fixed.** `callValue` parks `[callee, args...]`. Confirmed by the test
     "doc 61 P3: a native callee reached through a metamethod stays rooted
     while it runs", which fails with the callee park mutated out.
2. **Blocker (pre-existing, audit row 7): host `args`/`out` alias each other**
   via the bytecode `__call` arm and `pcall`/`xpcall`.
   - Parking roots the values but doesn't restore the no-alias contract.
   - **Open.** It's in coral-marten's area (see TODO.md).
3. **Blocker (pre-existing, audit row 8): a nested re-entry can overwrite
   partially written host results** in `boundary_scratch`.
   - **Open.** It's in coral-marten's area (see TODO.md).
4. **Should-fix: P4 overstated its scope.**
   - A native called directly from bytecode doesn't bump
     `native_reentry_depth`, and capture inside one is still accepted.
   - **Wording narrowed.** The `in_flight` check that closes it is added to
     Phase 0's checklist, which also flips the test expectation.
5. **Nit: the doc still described a `transient_roots` stack, and the audit
   lacked its safe cases.**
   - Codex's safe cases:
     - `table.sort`'s retained table and comparator;
     - `gsub`'s subject, pattern and replacement;
     - `require`'s searcher and loader callees;
     - fused operands across the first lookup;
     - the interpreter's arithmetic, comparison and `__tostring` paths;
     - capi table access.
   - Codex found no additional unrooted transient among them.
   - **The doc is reconciled.** §6.1, §6.2, §6.3, §8 and §9 now describe
     parking.

Codex confirmed:
- **P1:** `varargs_end <= callee_base`. The restore's ordered windows are
  sound, and the recorder refusal is sound.
- **P2:** success restore and failure retention match the catchers.
- **Parking overlap:** registers and `args` slices never share memory.
- **Tiers:** no new tier divergence.
