# CURRENT TASK — Nested-loop trace linking, Phase 1 (non-header exit-PC anchors)

Governing intent (Bart): close the LuaJIT gap one named technique at a time. The
current lever is **nested-loop trace linking** — let an outer loop containing an
inner numeric-`for` tier up the LuaJIT way (the inner loop is the root trace; its
loop-done exit spawns a *continuation* side trace that records the outer body and
links back to the inner root), instead of aborting at the inner `for_prep` and
running the whole nest on tier-0. Approved 5-phase plan:
`~/.claude/plans/rosy-noodling-catmull.md`. Design doc:
`docs/design/15-nested-loop-linking.md` (the proof-obligation contract P1/P2/P4).

This is a **structural JIT-coverage** feature, not codegen tightness. No speedup
until Phase 4 makes the chain native; Phases 1–3 deliver correctness behind the
gate. Tasks: #19 (Phase 1), #20 (Phase 2), #21 (Phase 3), #22 (Phase 4).

## Phase 1 — DONE, GREEN (uncommitted, pending Bart approval / commit)

`just test` green (10-mode determinism matrix). Output byte-identical: the
continuation always **aborts** (LINNER) before committing anything, so arming is
transparent — discharges **P1**.

### What Phase 1 does

The inner numeric-`for` traces as a root (unchanged). On its **productive**
loop-done exit (the `for_loop` `guard_true` failing because the loop is
exhausted, `completed = N > 0`), we arm a **continuation recording anchored at the
post-inner-loop pc** — a *non-header* anchor, the new machinery. The continuation
records the outer body forward, re-reaches the inner `for_prep`, and **aborts**
there. That abort site is exactly where Phase 2's `.link` terminator will go.
There is NO "close with `.loop`" in a real 2-level nest (the plan's original
wording was wrong) — the continuation always reaches the inner prep first.

### Mechanism (files touched)

- **`src/trace.zig`**
  - `TraceState.pending_exit_anchor: ?AnchorKey` — holds a deferred continuation
    recording at a non-header anchor (one in flight at a time).
  - `maybeArmContinuation(failed, exit_instr, proto)` — called from the productive
    side-exit path. Bails on `exit_instr == maxInt` (native: no per-guard pc →
    arming deferred to Phase 4), on an already-active/pending recording, on a
    non-`guard_true` exit, on `exit_pc == 0 / == anchor.pc / out of range`, and
    unless `code[exit_pc]` is a `for_loop`/`tfor_loop` (the enclosing loop). Skips
    if a trace already exists / the anchor is gated. Otherwise sets
    `pending_exit_anchor`.
  - `maybeStartContinuation(proto, cur_pc)` — the activation: when the deferred
    anchor's pc is reached, `rec.reset(gpa, key, num_registers)` starts recording.
    `reset` is anchor-PC-agnostic; `reg_map` is seeded **lazily** from the live
    registers at the exit because `refOf` emits a `slot_load` on first read.
  - `recForLoop` watermark only fires on `target == anchor.pc`; the continuation's
    anchor (post-loop pc) ≠ the outer back-edge target, so no watermark — correct.
- **`src/interp.zig`**
  - `nextOp` dispatch prologue (`mode == .full` only): if
    `pending_exit_anchor != null`, call `maybeStartContinuation(proto, cur)`.
  - Productive-exit path: `maybeArmContinuation(ct, result.exit_instr, proto)`
    after `onSideExit`.
  - Productive-exit tail: when `pending_exit_anchor != null`, flip `.fast`→`.full`
    (`return .switch_mode`) — or `continue :outer` if already `.full` — so the
    inner loop's final-iteration **deopt-replay** (which walks tier-0 from the
    inner anchor to the post-loop pc) runs with the `.full`-only activation hook
    live. Without this the hook never fires in the steady-state `.fast` loop.

### Tests (both green, `src/interp.zig`)

1. `"nested-loop: a 2-deep numeric-for nest is byte-identical across all modes
   (Phase 1)"` — `expectProgram` 10-mode output gate (`381300\n`), pins P1.
2. `"nested-loop: a hot inner loop arms a continuation recording at the post-loop
   pc (Phase 1)"` — `runExecForTrace` (hotloop=4, `record_aborts` on) asserting a
   **second, distinct `for_prep` abort site** exists (the continuation anchored at
   the post-loop pc, ≠ the outer-anchored recording) — proves the continuation
   genuinely armed, which the output test alone cannot.

### Gotcha worth remembering

`min_trip_entry = 24`: an inner loop with fewer than 24 trips is **declined** at
tier-1 entry, so its loop-done exit never runs through `irinterp` and the
continuation cannot arm. The tests use a 30-trip inner loop so the inner trace is
genuinely entered. (First test draft used a 12-trip inner loop → arming never
fired → `prep_sites >= 2` failed.)

## Next — Phase 2 (task #20, blocked by #19)

Link terminator (`.link`) + snapshot hand-off (P2, the load-bearing invariant):
`assertWellFormed`/`commit`/`tropt` accept `.link` as a valid terminal; the
continuation records `for_prep`'s subtract (`R[a] = init − step`) then emits
`.link` to the inner root instead of recording the inner `for_loop`. Convert the
current LINNER abort into the link. Watermark guard. Land green at tier-1a.

## Uncommitted tree

Modified (mine): `src/trace.zig`, `src/interp.zig`,
`docs/design/15-nested-loop-linking.md`. Untracked files (CURRENT_TASK_E3.md,
SESSION_CHANGES.md, bench/results/*.tsv, check_ordinals) belong to other agents —
**do NOT stage**.
