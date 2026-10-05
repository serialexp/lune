# Doc 61 rev 7 — codex review (2026-10-05)

Thread 01a1099b-a20b-7f43-b7be-307bb52247c5. Verdict: **APPROVE**. No blockers.

The rev 6 blocker is resolved. The site-5 gate is sufficient: a captured `a+3` is live everywhere, so skipping it is forbidden. Both options are sound:
- (i) flush the retained pre-test binding;
- (ii) decline linked completion before committing its stores, and replay through the coarse deopt.

The safe exclusions are documented. No design blocker remains in the document.

## Should-fix

- **The captured-case test must be non-vacuous.** A closure created in the loop body aborts recording today (`trace_recorder.zig:1704`). Use a constructed captured-slot proto/trace, and assert that the completion links or deliberately declines, so the mutations exercise the gate. → Folded into §8.
