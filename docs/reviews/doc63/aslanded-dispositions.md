# §5.10.1 "As landed" review, round 1 — dispositions (2026-10-11)

Reviews: `codex-aslanded.md` (APPROVE WITH CHANGES),
`antigravity-aslanded.md` (APPROVE).

| Finding | Disposition |
|---|---|
| Codex 1 / Antigravity 1: unpublishing already does physical work (`unpublishDoomed` calls `resetLinksTouchingDoomed`); §5.10.1 left the slot rewrites undecided, weaker than §5.10 | Fixed. §5.10.1 now states that unpublishing is not purely logical today, that a callback's collection can doom ordinary traces too, and that Phase 2b extracts the logical part of unpublishing and defers link teardown, slot rewrites, promoted-state teardown, `destroyDoomed` and the graph rebuilds until both counters are zero, as §5.10 requires. The deferred step 8 drain runs after that batch. |
| Codex 2: seeds are not always above `stack_top` | Fixed. A nested guest frame can be laid out over part of the seed span; those slots hold that frame's values and may be walked or scrubbed. The epoch has moved in that case, so no seed is read again. |
| Antigravity 2: the F1 test needs `guard_native`, which arrives in Phase 2c | Fixed: the test lands with Phase 2c, or earlier on a hand-built trace whose pool holds a `Native`. |
