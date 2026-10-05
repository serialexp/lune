# Doc 61 rev 4 — antigravity review (2026-10-05)

Verdict: **APPROVE**. No blockers. Should-fixes are folded into rev 5.

Antigravity verified every rev 3 finding against the source, both its own and codex's. It judged §4.4 sound under the path lemma, nesting and reader coverage, and the watermark bridge (§2/§5) sound.

## Should-fixes

1. **`protectedCall`'s mark must check `vm.depth > entry_depth`.** `callValue` can fail before pushing a frame, and then `depth - 1` underflows at depth 0 or marks the wrong frame. → Rev 5 §4.4. Its suggested `defer` inside an `if` would have scoped the restore to the `if` block. Rev 5 needs no restore at all.
2. **Remove "not faulting" from the §4.3 heading.** → Done.
3. **`callValue` marking needs `depth > 0`.** → Rev 5 §4.2.
4. **The call-layout check is every `.call` in `F.code`.** → Rev 5 §5.
