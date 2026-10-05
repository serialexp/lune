# Doc 61 rev 5 — codex review (2026-10-05)

Thread 01a10986-6a30-78a0-89ac-947d9635c5c3. Verdict: **REVISE**. Folded into rev 6.

All three rev 4 blockers and both reviewers' should-fixes are addressed. The §4.2 flag discipline is sound across the identified catch paths:
- successful nesting restores the previous flag;
- errors retain flags;
- catchers restore the surviving boundary frame.

No error-discard path exists outside `protectedCall` and `guestFault`. The native push checks come before its pc freeze (`nativegen_emit.zig:951-978`).

## Blocker

1. **Composite bridges break the non-maskable coherence guarantee.** `bridgeMatchesExitSnapshot` ignores slots dead at the landing pc whenever liveness exists (`trace_code.zig:787,794,799`). `emitCompositeBridgeSnapshot` writes only the φ-derived emission set (`nativegen_emit.zig:2526-2528`). A dead slot can be omitted, or given a different terminal φ value, and then rooted by an all-live scan. `trace_fingerprint_test.zig:493-513` already models both mismatch forms. → Rev 6 §2 site 4 and §5: bridge admission is gated on `maskable`, with a non-maskable bridge regression.

## Should-fixes

- **Capture the entry flag at entry.** `guestFault` receives entry depth/top after the failure (`capi.zig:382,438,808,851`). The flag must be saved before marking or re-entry and carried through the fault interface, `.S` included. → Rev 6 §4.2.
- **Materialisation covers wanted exits too,** including resumption into tier-0 without a child (`irinterp.zig:1419-1428`, `trace_exec.zig:69-76`). → Rev 6 §2 and the §8 test matrix.
