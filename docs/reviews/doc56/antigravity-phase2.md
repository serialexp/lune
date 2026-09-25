# Doc 56 Phase 2 code review — Antigravity (2026-09-25)

Scope: the uncommitted Phase 2 change (`src/trace_exit_attach.zig`, its
tests, the `TraceCode` memo, the finalize hook, the moved
`continuationReachesEnclosingBackEdge`, the `--jit-stats` line and the
real-program test). Read-only review with tool access.

**Verdict: APPROVE WITH CHANGES.**

Verified sound by the reviewer:
- the Q6 `resumeClass` audit (`smatch`/`sgmatch` scratch, the interning
  string producers under doc 24 D2 and `guard_gc`, the read-only ops);
- the branch fix-up in `resumeOf`, against the recorder's
  `jumped = (op == .jmp_if_true) == truthy` polarity stamping;
- rule 7's ordinal comparison and the store operand layouts
  (`hstore` key via `href.b`, `gstore` via `gcell → garow`);
- rule 9: `call`/`ret` with `b == all_results` are the only readers of
  `Vm.reg_top`;
- `buildMemo` equals `classify`, OOM leaves it unbuilt, no bitset
  off-by-one.

Findings:
1. `operandReady` omitted `uref`, so an earlier bytecode's `ustore` whose
   `uref` token sits after the guard was refused as `store_operand`.
   A `uref` has no operands (it reloads from its seed slot), so it is
   always rebuildable. **Taken:** `.konst, .uref => true`. Fail-closed
   before (a false refusal, not unsound).
2. Test gap: the flush-kind loop kept the store's address operand below
   the guard, so the `uref` and `gstore → gcell → garow` chains after the
   guard were never walked. **Taken:** two new cases in
   "a sunk store's operands must be computed when the guard fails",
   including the guard's own result two levels down. The `uref` case was
   mutation-checked (fails without the fix).
