# Doc 61 rev 5 — antigravity review (2026-10-05)

Verdict: **APPROVE**. No blockers. Should-fixes are folded into rev 6.

Antigravity verified codex's three rev 4 blockers and every rev 4 should-fix against the source. It judged the following sound:
- the left-set-on-error `in_flight` discipline with catcher-owned restore, on every catch path;
- the elision-site gating;
- the fault-pc invariant.

## Should-fixes

1. **The capi entry flag must be captured at entry**, alongside `entry_depth`/`entry_top`, and passed into `guestFault`. → Rev 6 §4.2.
2. **Pre-freeze checks.** `opCall`'s depth/capacity checks (`interp.zig:6383-6384`) raise before the pc freeze. Phase 0 should re-store on `pushFrameVararg` failure, or freeze only after a successful push. → Rev 6 §4.4.
3. **The native adapter** reads `t.exit_snapshots` (`nativegen_adapter.zig:280`), so gating at commit covers it. → Rev 6 §5.
