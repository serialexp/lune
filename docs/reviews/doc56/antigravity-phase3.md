# Doc 56 Phase 3 code review — Antigravity (2026-09-25)

Scope: the uncommitted Phase 3 change (`git diff HEAD -- src`): the
tier-1a exit materializer, the per-exit exit-side state machine and
recording, `LinkKind` and the enclosing-iteration credit, the loop-done
refusal in `resumeOf`, and the tier-1a burst call B resume-pc fix.
Read-only review with tool access, asked to be adversarial.

**Verdict: no serious findings.** No changes requested.

Verified sound by the reviewer:
- materialization order: sunk stores are applied in stream (program)
  order, and only those with `0 < ord < guard.ord`. The guard's own
  bytecode's stores are left out, because tier-0 re-runs that bytecode
  at `P`. Effect stores are refused at commit by `storeRule`. Operands
  past the guard are only `konst`/`uref` (checked at commit by
  `operandReady`), so `ExitRefs.get`'s `unreachable` is safe;
- slot writes come after the stores, and every snapshot ref is `< gi`
  (`exitSnapshotsValid`);
- the base pointer: attachability requires `inline_depth == 0`, so the
  dispatcher's `base` is the resuming frame's base;
- the iteration credit is only given when `.link` is reached, and is
  never doubled across the seed, call B and `replayLedger`;
- determinism: every state transition is a function of exit counts,
  `side_children` and config constants, and `LinkKind` is fixed at
  record time;
- the `exit_side` array is freed on every path (`errdefer` in publish,
  `destroy`);
- `linkKindAt`'s bounds, for both `for` (`[prep+1, for_loop]`) and
  `while` (`[cmp, jmp]`); `a == target` can't happen;
- the loop-done refusal covers the `.loop_done` role, numeric-`for` done
  guards and a while root's own condition, and it leaves an inner
  `while` unrolled in an outer root attachable (bit-reverse);
- the call B fix matches native `replayLedger`.
