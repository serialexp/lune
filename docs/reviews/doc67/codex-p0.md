# Doc 67 — P0 findings review (codex, 2026-10-21)

Asked for a recommendation on doc 67 §11.3 Q5–Q7 after the P0 dry run.
Read-only; codex thread 01a15e06-1d40-7bf0-8b03-3b5de172bde7. Verbatim:

---

I recommend **Q5(d): retain P0 and park P1–P3 for now**. The mechanism can be made sound, but recovering the hot links requires more machinery than the original design anticipated, against a roughly 2–3% instruction ceiling. If you continue, I would use a bounded combination of (b), seeded proven entries, and guard-derived facts initially restricted to `.link` terminals.

**Q5 — pass-through facts.** Option (b) is sound if imported predicates are actually emitted as checks, every operand remains unchanged through the parent—including seed writes and back-edge writes—and every referenced slot is safe to read. “Absent from the exit facts” is insufficient evidence: `dbgProvenMiss` classifies “untouched” by searching the parent’s fact list, not its IR or complete write footprint (trace_native_registry.zig:1067). Importing numeric predicates also requires their supporting tag checks; imported checks should remain separate from allocation so they do not acquire homes or loads.

Its payoff needs qualification. In root → continuation → root, importing the root’s `p` check into the continuation moves that check one hop earlier. While root → continuation remains checked, `p` is still checked once per cycle. Option (b) saves checks already shared between the pages, but does not itself eliminate the newly imported pass-through checks around that cycle.

Option (c) can eliminate those repeated checks once both pages establish the necessary contract. However, “one recompile per root” describes a simple pair, not general trace graphs: dependencies can propagate through several pages. It needs bounded, deterministic propagation and artifact replacement, with the resulting disarms and silent-set demotions. Existing republication deliberately treats a changed child entry address as a real target change (trace_native_registry.zig:1142). I would not introduce that churn for this measured ceiling.

Option (a) directly removes the proven subset without strengthening the parent’s dispatcher entry. It is the most flexible option, but retains the missing checks, adds another jump, and introduces executable-code ownership per relation. The stub must initialize the child’s entry bookkeeping **before any possible failure**, particularly `entry_rbx`; otherwise a failure can misattribute inherited progress (nativegen.zig:884). Its cost is justified only by dynamically frequent links with substantial removable checks.

**Q6 — seeded children.** The exclusion can be lifted, but I recommend a different layout: **preserve the existing checked entry and give the proven entry its own seed-first prefix**, followed by seed-dependent checks, then join the common prologue. This duplicates some code per child and preserves checked-entry failure ordering without introducing a runtime mode test.

The actual helper supports that split. It writes active seed destinations through `regSet`; verifier and slot-alias seeds validate without writing. It performs resolution without allocation or GC (interp.zig:1392, interp.zig:1407, interp.zig:1457). Partition predicates by intersection with the **actual seed write set**: a `nov` touching either seeded operand must remain after seeding. Distinguish facts required from the parent from the full facts established before the body; outgoing transfers still need the latter.

The proposed pre-seed layout is also defensible for safely readable unseeded slots, but changes failure priority: an unseeded mismatch can now produce `prologue_fail` before a seed would have declined. Those paths have different accounting—seed declines intentionally avoid strikes and receipts (trace_chain.zig:2545).

Also, “prologue failure leaves the entire slab untouched” is already too strong for seeded pages. Seeding precedes tag checks today, and alias-resolution failure can return `SEED_CAPACITY_DECLINE` after earlier scratch writes (nativegen.zig:898, interp.zig:1368). Genuine capacity overflow writes nothing; the shared decline reason does not guarantee that universally. Preserve both decline paths and their committed-prefix handling. Retain episode-freshness validation (trace_chain.zig:183). Finally, the 31 seeded misses are **masked cases**, not 31 assured proofs.

**Q7 — guard-derived facts.** Yes, with exact value correspondence. A successful earlier guard establishes a predicate on its SSA operands; export it only when the exit materializes those same values with compatible representations. A guard on `i` proves nothing automatically about a written `i + step`. For `nov`, map both operands through the final write mapping; for pins, require the actual boolean-value predicate.

This is straightforward for `.link`: writebacks expose their source refs (nativegen_boundary.zig:166). It is more delicate elsewhere:

- Carried exits usually flush current homes with `ref = null`, not `store_ref` (nativegen_boundary.zig:199).
- Loop-done writes use `phi.b`; a predicate on the incoming value does not automatically transfer to that update (nativegen_boundary.zig:175).
- P0 shares one carried fact list across all ordinary exits. Guard-prefix facts are exit-specific, so adding them to that shared list would be unsound (nativegen_facts.zig:123).

LICM is compatible: its hoisted guards depend on invariant operands (tropt.zig:647). Body guards must have succeeded in the current iteration; never carry a previous iteration’s result across a φ update. Excluding peeled pages helps, but does not remove ordinary loop-carried values. I would start with `.link`, leaving ambiguous home/φ cases unproven.

Index guards once by operand refs and execution position. Avoid rescanning every guard for every write and exit, and cap alias expansion: several destination slots for each operand can make `nov` generation quadratic. Preserve the existing fail-closed fact budget (nativegen_factbuild.zig:61).

**Publication, silent promotion, and replay.** Every implementation needs one target resolver shared by publication, identical re-arm, candidate invalidation, and silent promotion; promotion currently checks an explicitly reconstructed checked-entry address (trace_link.zig:1393). Preserve the staged target used by rowless siblings (nativegen.zig:2825), the silent epilogues’ slot dispatch, and disarm/retirement to `shared_exit`. Residual stubs additionally need artifact-generation-aware ownership and invalidation.

Make fact selection, variant admission, and recompilation triggers functions of committed artifacts and deterministic events, with fixed budgets and canonical ordering. Native addresses may identify executable targets; they must not determine optimization policy. Check reordering and hoisting can change deterministic receipts and tiering even when language results agree, so they need the full equivalence/replay gate.

A useful variant of (a), if pursued, is **bounded child-owned residual-entry variants**, shared by identical residual predicates. That limits code growth and avoids per-arm stub ownership, although target consumers still need explicit variant identity.

My estimate is **sub-1% instruction reduction for the bounded combination**, and perhaps **1–2% for broader coverage**, with uncertain wall-time benefit. These are estimates, not measurements. The §1 measurements are cumulative, so step/overflow savings must not be added again to the final −2.25%/−2.61% rows (67-proven-link-entry.md:116). Arm counts also do not reveal dynamic savings. Given that evidence, I would keep P0 and defer further implementation.
