# lune — Trace Lifecycle

Status: draft, not yet implemented — stub capturing required decisions
Owner: Bart
Last updated: 2026-06-12

Prerequisite for **Phase 5** (hot-path detection + trace recorder) in
`00-architecture.md`. Both external reviewers independently flagged that the
architecture doc names "guards, side exits, snapshots, trace linking" as goals
but specifies none of the *policy*, and that "the failure policies are the
architecture." This doc is where that policy lives.

## Implementation status

### Done

_(nothing yet — design only)_

### Outstanding

- [ ] **Hotness policy.** Back-edge counters, call/entry counters, thresholds
      (LuaJIT defaults: `hotloop`=56, `hotexit`=10 — pick ours), counter decay.
      Affects bytecode + interpreter dispatch (Phase 3), not only Phase 5.
- [ ] **Trace anchors.** What may start a trace: loop headers, hot side exits.
      Root vs side traces.
- [ ] **Trace lifecycle state machine.** `interpreting → recording →
      aborted | compiled_ir → executing_ir → side_exit → linked | blacklisted |
      interpreter`. Define states + transitions explicitly.
- [ ] **Recording termination (clean).** Loop-back close; link to existing
      trace; return below anchor.
- [ ] **Abort policy.** Max IR length (`maxrecord`), unsupported/NYI bytecodes,
      host-call barriers, unstable types, allocation pressure, excessive side
      exits, recursion/unroll caps.
- [ ] **Blacklist + penalty backoff.** Penalty key (bytecode PC? loop header?
      side exit? shape transition?); doubling-with-jitter backoff; permanent
      blacklist threshold → patch hot-counter bytecode back to plain form.
- [ ] **Side traces & linking.** When a hot side exit spawns a side trace; when
      to direct-link vs return to interpreter; side-trace budget per root.
- [ ] **Trace explosion controls.** Polymorphic/megamorphic dispatch, shape
      churn, mixed `i64`/`f64` arithmetic, nested loops; trace-cache count cap
      (`maxtrace`), memory cap, flush policy. **Log what gets dropped** (no
      silent caps).
- [ ] **Invalidation / dependency tracking.** Shape mutation / unfreeze, global
      mutation, function replacement must invalidate dependent traces. Who
      records which traces guard on which shapes?
- [ ] **Snapshot contents.** The full list (see §Snapshots & deopt) — the single
      hardest piece. Frames, PC, upvalues, heap object *identities*, sunk
      allocations, pending stores, error/unwind state, iterator state, GC roots.
- [ ] **Deopt / side-exit restore.** Map IR refs → bytecode frame slots;
      **rematerialise sunk allocations**; hand control back to tier-0. Required
      for tier-1a too — the IR-interpreter does not let us skip this.
- [ ] **Standing design rule.** Every optimization that removes/reorders state
      ships its deopt reconstruction rule *before* it lands (DCE, CSE,
      allocation-sinking, numeric narrowing, bounds-check elimination,
      shape specialization).

## Why this exists

Trace selection — where a trace begins, where it ends, when it aborts, and how
the pieces link — is the genuinely distinctive part of a tracing JIT; the rest
is conventional compiler optimization on a linear IR. It is also where tracing
JITs fail in practice: a recorder can look like it works on toy loops while being
structurally unable to survive real dynamic code. The two trace-head conditions
are trivial (two counters); the abort/snapshot/deopt machinery is the years of
work. This doc pins the policy before implementation.

## Goals

- A fully specified trace lifecycle with explicit states and transitions.
- Bounded behavior under adversarial input: no trace explosion, no re-record
  thrashing, no silent truncation.
- A snapshot/deopt design that serves both side-exit restore *and* (via shared
  substrate) the debugger keyframes.

## Non-goals

- Coroutine traces (general coroutines are out — `00-architecture.md`).
- Cross-tier inlining cleverness before correctness.

## Trace lifecycle (sketch)

```
interpreting --hot--> recording --+--> compiled_ir --> executing_ir --side_exit-->
                                  |                                    |
                                  +--> aborted --> penalty/blacklist   +--> linked
                                                                       +--> interpreter
```

Anchors: hot loop headers seed **root traces**; hot side exits seed **side
traces**. Clean endings: loop-back close, link to existing trace, return below
anchor. Bad ending: abort → penalty (doubling + jitter) → eventual blacklist
(patch the hot-counting bytecode back so the spot is never retraced).

## Snapshots & deopt (the heart)

A snapshot must reconstruct enough to hand control back to tier-0 at a guard. It
is **not** just value registers. The minimum (to be finalized):

- VM call frames, bytecode PC, return PC, varargs, temporaries, live
  closures/upvalues.
- Heap object **identities** (the debugger needs object continuity across time,
  not just values).
- Sunk / scalar-replaced allocations + their rematerialisation recipes.
- Pending stores and store ordering.
- Error / protected-call / unwind state.
- Iterator state and table traversal position.
- Host-call boundaries.
- GC root maps for interpreter, recorder, IR-interpreter, later native codegen.

This shares format and code with the debugger's keyframes
(`04-snapshot-replay-schema.md`) but is a distinct artifact.

## Open questions

- [ ] Counter thresholds and decay — tune empirically; start near LuaJIT's.
- [ ] Penalty key granularity (PC vs loop header vs shape transition).
- [ ] Do we trace through host-effect calls at all, or always barrier? (Lean:
      always barrier — see `02-determinism.md`.)
- [ ] Shape-dependency tracking data structure.

## References

- `00-architecture.md` — §Observability, §Determinism, Phase 5.
- `04-snapshot-replay-schema.md` — shared snapshot/keyframe substrate.
- LuaJIT `lj_trace.c` (penalty/blacklist, state machine), `lj_record.c`
  (recording), `lj_snap.c` (snapshots) — reference implementation.
