# Doc 61 rev 6 — antigravity review (2026-10-05)

Verdict: **APPROVE**. No blockers.

Antigravity verified every rev 5 finding against the source. It audited the following candidate writers and found each either harmless or covered by sites 1–4:
- sunk stores;
- `ret_cont`;
- sibling handoff;
- region bridges;
- `link_terminal`;
- native coarse, precise and side exits;
- inlined-callee frames;
- `loop_done` exits.

It classified the linked `loop_done` skip of `a+3` as matching tier-0's "no update on completion". Codex's rev 6 blocker shows that this holds only when the body did not reassign the loop variable. → Rev 7 §2 site 5.

## Should-fix

- **§6.4 line references.** `matchesFingerprint` is at `trace_code.zig:548`, and `bridgeMatchesExitSnapshot` is at `:781-805`. → Corrected in rev 7.
