# Doc 61 rev 6 — codex review (2026-10-05)

Thread 01a10990-6d32-7713-a99e-9edfaa912e5a. Verdict: **REVISE**. Folded into rev 7.

The rev 5 blocker and both should-fixes are resolved, tests and mutations included. One additional site is missing.

## Blocker

1. **Linked numeric-for completion skips the visible loop variable unconditionally.**
   - `nativegen_emit.zig:2508` and `irinterp.zig:130` omit `a+3`. Tier-0 preserves that slot when the final test fails (`interp.zig:5683`).
   - So a body such as `i = tostring(i)` leaves a heap value in tier-0, but an earlier numeric value after linked execution. A non-maskable all-live frame then sees different GC roots despite the four gates.
   - Flushing the terminal φ is insufficient, because it holds the next iteration's index (`trace_recorder.zig:3563`).
   - Fix: preserve the actual pre-test value, or decline linked completion and replay.
   - → Rev 7 §2 site 5 and §5, gated on `maskable` and a dead `a+3`. A captured loop variable is also covered, because it is live everywhere.

## Should-fix

- **Record the safe exclusions explicitly:**
  - inlined-callee stores outside the surviving frame window (`trace_finalize.zig:59`);
  - precise snapshot skips that preserve already-coherent slots;
  - `ret_cont` result copies;
  - sibling/native deopt paths that preserve entry state.

  → Rev 7 §2 "Audited non-sites".
