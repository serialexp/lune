# lune — Trace Lifecycle

Status: Phase 5a (recorder) + Phase 6a (IR-interpreter + loop-header deopt)
implemented; full per-guard snapshots / side-exit restore still design-only
Owner: Bart
Last updated: 2026-06-13

Prerequisite for **Phase 5** (hot-path detection + trace recorder) in
`00-architecture.md`. Both external reviewers independently flagged that the
architecture doc names "guards, side exits, snapshots, trace linking" as goals
but specifies none of the *policy*, and that "the failure policies are the
architecture." This doc is where that policy lives.

## Implementation status

### Done (Phase 5a — the recorder, `src/trace.zig` + `src/interp.zig`)

- [x] **Hotness policy (recording slice).** Back-edge counters keyed by
      `(proto, target-pc)`, saturating; `hotloop` threshold (default 56, LuaJIT's)
      arms a recording **once**, at the moment the count crosses it (`==`, so no
      re-arm churn). Detected at a single seam in the dispatch loop (`pc <= cur_pc`
      ⇔ a backward/self jump), gated on `config.enabled`. _Call/entry counters and
      counter decay are still outstanding (below)._
- [x] **Trace anchors (root, loop headers).** A hot loop header `(proto, pc)` is
      the only anchor in 5a. _Hot side exits → side traces are outstanding._
- [x] **Trace lifecycle state machine (recording slice).** `interpreting →
      recording → (loop-back) committed→cached | aborted→blacklisted`. The
      `executing_ir → side_exit` half is now Phase 6a (below); `linked` (side
      traces) is still outstanding.
- [x] **Recording termination (clean).** Loop-back to the anchor closes the
      trace: append `loop`, snapshot the loop-carried register→ref writes
      (`exit_stores`), dupe into an owned `Trace`, append to the cache. _Linking
      to an existing trace / returning below the anchor are Phase 6._
- [x] **Abort policy (first cut).** Explicit reasons: `maxrecord` length cap,
      `nyi_opcode` (tables/globals/upvalues/concat/…), `host_barrier` (native
      call), `cross_frame` (Lua `call`/`ret`/`halt`), `bad_type` (non-numeric
      operand to an arithmetic/compare op), `alloc`. An abort discards the partial
      trace, leaves tier-0 untouched, and blacklists the anchor. _Excessive-side-
      exit and recursion/unroll caps are outstanding._
- [x] **Transparency invariant.** Recording never perturbs tier-0: it reads
      pre-execution operands and emits IR, but tier-0 still executes every
      instruction. Enforced by the `expectProgram` matrix ({gc_stress} ×
      {recorder}, identical output) and noted in `02-determinism.md`.
- [x] **CLI opt-in.** `--trace` now records **and** executes hot loops (Phase 6a);
      `--trace-record-only` records but lets tier-0 execute (Phase 5a, IR
      inspection); `--dump-traces` also prints each cached trace's IR
      (disassembler) to stderr. Default off ⇒ identical to the pre-Phase-5 driver.

### Done (Phase 6a — the IR-interpreter + loop-header deopt, `src/irinterp.zig`)

- [x] **Executing IR (tier-1a).** `execute(t, regs, values)` walks a cached
      trace's linear SSA body, computing into a private, **reused** `values[]`
      scratch (grown to the high-water trace length on `TraceState`, never
      per-iteration), calling the **same `arith.zig`** functions tier-0 uses — that
      shared implementation *is* the byte-identical guarantee. Entered at the
      back-edge seam in `src/interp.zig` immediately after `onBackEdge`, so a trace
      is only ever run at exactly `anchor.pc`.
- [x] **Loop-header re-entry deopt.** `execute` writes the tier-0 register file
      **only** at a clean `loop` close (applying `exit_stores`). So `regs` is a
      coherent loop-header state at every iteration boundary, and any guard failure
      / arithmetic error mid-iteration simply *side-exits* — returns with `regs`
      untouched since the iteration start — and tier-0 re-runs that one partial
      iteration from `anchor.pc`. **No per-guard snapshot is consulted.** Sound
      because a committed trace has **no side effects** (host calls / tables /
      globals / cross-frame all abort recording), so re-executing the partial
      iteration recomputes only pure register values — never a doubled effect.
      Integer `//`/`%`-by-zero is the only mid-trace error possible (i64 ops wrap,
      never trap); it side-exits and tier-0 re-raises the identical `DivisionByZero`.
- [x] **No GC safepoint inside `execute`.** A committed trace allocates nothing, so
      no collection is ever needed mid-trace — which is what makes the unrooted
      `values[]` scratch safe: any live heap value in it is also reachable via
      `regs` or the GC-rooted const pool, and a stale ref after a side-exit is never
      dereferenced (linear SSA: recomputed before use on the next entry).
- [x] **Re-entry brake.** `onSideExit(t, completed)` keeps a per-anchor `penalty`:
      an entry yielding `>= min_useful` iterations clears it; a low-yield one bumps
      it; at `max_penalty` the anchor is **blacklisted** so tier-0 owns the loop.
      Bounds both *zero-yield* (types no longer match) and *low-yield* (branchy,
      e.g. `if i%2==0`) thrash — the real fix (side traces) is deferred.
- [x] **Execution transparency.** The `expectProgram` matrix runs every e2e
      program under {gc_stress} × {off, record-only, **record+execute**}, all
      byte-identical — a wrong arith mapping, missed guard, bad deopt, or exit-store
      mistake diverges here. A debug-only commit-time structural verifier
      (`assertWellFormed`) checks the IR invariants `execute` relies on (terminal
      `loop`, operand refs < index, exit refs < `loop`, in-bounds `aux`).

### Outstanding

- [ ] **Hotness policy (rest).** Call/entry counters, a `hotexit` threshold,
      counter decay.
- [ ] **Blacklist + penalty backoff.** 5a uses a **permanent** blacklist (no
      machinery, prevents re-record thrash). Still to do: penalty key choice
      (PC? loop header? side exit? shape transition?), doubling-with-jitter
      backoff so a temporarily-unstable loop can succeed later, and a permanent-
      blacklist threshold that patches the hot-counter bytecode back to plain form.
- [ ] **Side traces & linking.** When a hot side exit spawns a side trace; when
      to direct-link vs return to interpreter; side-trace budget per root.
- [ ] **Trace explosion controls.** Polymorphic/megamorphic dispatch, shape
      churn, mixed `i64`/`f64` arithmetic, nested loops; trace-cache count cap
      (`maxtrace`), memory cap, flush policy. **Log what gets dropped** (no
      silent caps).
- [ ] **Invalidation / dependency tracking.** Shape mutation / unfreeze, global
      mutation, function replacement must invalidate dependent traces. Who
      records which traces guard on which shapes?
- [ ] **Snapshot contents.** _Phase 5a records the **minimal** snapshot the
      future restore needs — `entry_slots` (registers read as `slot_load` inputs)
      and `exit_stores` (loop-carried register→ref writes at close) — and every
      guard carries a `SnapIdx` placeholder._ The full per-guard snapshot is still
      outstanding (see §Snapshots & deopt) — the single hardest piece: frames, PC,
      upvalues, heap object *identities*, sunk allocations, pending stores,
      error/unwind state, iterator state, GC roots.
- [~] **Deopt / side-exit restore.** _Phase 6a ships the **loop-header re-entry**
      deopt (above): because tier-1a never mutates `regs` mid-iteration, a
      side-exit needs no restore at all — tier-0 just re-runs the partial iteration
      from `anchor.pc`._ The **general** restore — mapping IR refs → frame slots at
      an *arbitrary* guard, **rematerialising sunk allocations**, restoring PC /
      upvalues / iterator state — is still outstanding, and is only *needed* once an
      optimization (6b) sinks state or we mutate `regs` mid-trace / trace across
      calls. Until then the minimal `entry_slots`/`exit_stores` maps suffice.
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
