# CURRENT TASK — Nested-loop trace linking, Phase 2 (the `.link` terminator)

Governing intent (Bart): close the LuaJIT gap one named technique at a time. The
current lever is **nested-loop trace linking** — let an outer loop containing an
inner numeric-`for` tier up the LuaJIT way (the inner loop is the root trace; its
loop-done exit spawns a *continuation* side trace that records the outer body and
links back to the inner root), instead of aborting at the inner `for_prep` and
running the whole nest on tier-0. Approved 5-phase plan:
`~/.claude/plans/rosy-noodling-catmull.md`. Design doc:
`docs/design/15-nested-loop-linking.md` (the proof-obligation contract P1–P4).

This is a **structural JIT-coverage** feature, not codegen tightness. No speedup
until Phase 4 makes the chain native; Phases 1–3 deliver correctness behind the
gate. Tasks: #19 (Phase 1, done), #20 (Phase 2, done), #21 (Phase 3), #22 (Phase 4).

## Phase 2 — DONE, GREEN

`just test` green (5/5 steps, 737 tests; 10-mode determinism matrix +
keyframe/replay goldens). Output byte-identical: the continuation now **commits a
`.link` trace** instead of aborting, but the link trace is never *executed* in
Phase 2, so observable behaviour is unchanged — discharges **P2/P3** at record
time and keeps the matrix byte-identical.

### What Phase 2 does

The Phase 1 continuation (armed on a productive inner loop-done exit, anchored at
the post-inner-loop pc) records the outer body forward and re-reaches the inner
`for_prep`. Phase 2 turns that LINNER abort into a **link**: `recForPrepLink`
records `for_prep`'s pre-decrement `R[a] = init − step` and closes the trace with
a new `.link` terminator naming the inner root's anchor pc.

### Mechanism (files touched)

- **`src/trace.zig`**
  - New `IrOp.link` (wire ordinal 56, appended at enum end). Terminal like `.loop`;
    `aux` = inner root anchor pc; no operand refs.
  - `Recorder.link_target: ?u32` — set by `recForPrepLink`; `commit()` appends
    `.link{aux=link_target}` instead of `.loop` and caches **unoptimized** (skips
    `tropt`, whose LICM/φ machinery + `instrs[n-1].op == .loop` assert are
    loop-only and a link trace is never executed anyway).
  - `Recorder.is_continuation: bool` — set only by `maybeStartContinuation`.
    `recForPrepLink` links **iff** continuation (a *root* recording reaching an
    inner `for_prep` still LINNER-aborts — LuaJIT's model; also keeps link anchors
    off real back-edge targets).
  - `recForPrepLink(instr, regs, proto, pc)` — dispatched from the new `.for_prep`
    arm in `recordOne`. Locates the matching `for_loop` (`pc + instr.aux`, verified
    `.op == .for_loop`); inner anchor = `pc` (= the `for_loop` back-edge target =
    body start); links iff `hasTrace(inner_anchor)`, else `.nyi_opcode` (LINNER).
    Records `guardNum` idx/step + `.sub`, sets `link_target`, `closeTrace`.
  - `assertWellFormed` accepts `.loop` **or** `.link` as the sole terminal.
  - `tryChainExit` skips any `.link`-terminated trace (the inert-link guard).
- **`src/irinterp.zig`** — `.link` arm: clean zero-commit fall-through (break with
  `completed` unchanged, no φ writeback). Dead in Phase 2; ready for Phase 3.
- **`src/tropt.zig` / `src/troptdiag.zig`** — `.link` arms for switch
  exhaustiveness (classified like `.loop`: terminal, no operands/uses).
- **`src/traceser.zig`** — ordinal contract updated (ordinal 56, count 57).
- **`viz/src/enums.ts`** — `IR_OP_NAMES` + `NO_OPERAND_OPS` mirror.

### Bundled Phase-1 fix (in this commit)

`src/interp.zig`'s `runFastPath` now also holds `.full` while
`pending_exit_anchor != null` — without it, after a productive exit's
`switch_mode` the loop re-picked `.fast` and the `.full`-only activation hook
never fired, so the continuation arming stuck pending forever at production
`hotloop = 56`. Logically a Phase-1 correctness fix; it lives in `interp.zig`
alongside the Phase-2 test rewrite, so per Rule #13 (no partial-file commits) it
ships in the same commit.

### Test (green, `src/interp.zig`)

`"nested-loop: a hot inner loop's continuation links to the inner root at the
inner for_prep (Phase 2)"` — `runExecForTrace` (hotloop=4) on the 40×30 nest,
output `381300`, asserts a `.link`-terminated trace is cached **and** its `aux`
resolves to a cached `.loop` root (the inner numeric-for). Replaces the Phase 1
"second for_prep abort site" test (that abort is now a link). The `expectProgram`
10-mode test still pins byte-identical output.

### Gotcha worth remembering

`min_trip_entry = 24`: an inner loop with fewer than 24 trips is **declined** at
tier-1 entry, so its loop-done exit never runs through `irinterp` and the
continuation cannot arm. The tests use a 30-trip inner loop.

## Next — Phase 3 (task #21)

Linked execution at tier-1a. **Remove the `tryChainExit` inert-link skip** and
teach the chain to *follow* `.link`: run the continuation to its `.link`, then
`irinterp.execute` the inner root, ping-ponging inner-root ⇄ continuation until a
real exit. Roll-up: the inner loop-done exit (`completed = 0` after N inner
iterations) counts as **one** successful outer completion, not a penalty. Wire
productive-exit entry; generalize the trigger to nsieve's shape; add a nested-loop
`expectProgram` 10-mode test incl. a keyframe cut→resume across a link. Correct
but not yet faster (tier-1a ≈ tier-0).

## Uncommitted tree

Modified (mine): `src/trace.zig`, `src/interp.zig`, `src/irinterp.zig`,
`src/tropt.zig`, `src/troptdiag.zig`, `src/traceser.zig`, `viz/src/enums.ts`,
`docs/design/15-nested-loop-linking.md`, `CURRENT_TASK.md`. Untracked files
(CURRENT_TASK_E3.md, SESSION_CHANGES.md, bench/results/*.tsv, check_ordinals)
belong to other agents — **do NOT stage**.
