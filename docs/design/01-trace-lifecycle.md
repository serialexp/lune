# mahina — Trace Lifecycle

Status: Phase 5a (recorder) + Phase 6a (IR-interpreter + loop-header deopt) +
Phase 6b (optimizer) + Phase 7 (trace execution log for the visualiser animation)
implemented; full per-guard snapshots / side-exit restore still design-only
Owner: Bart
Last updated: 2026-06-15

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
      the only anchor in 5a. In memory the anchor keys on the borrowed `*const
      Proto` pointer (fast identity for "do I have a trace for this exact loop
      header?"). **On disk (Phase 5b) the pointer becomes a stable, compile-time
      `Proto.id`** — a pointer is meaningless once serialized; the visualiser uses
      the id as a correlation key, never rebinding a live pointer (see
      `04-snapshot-replay-schema.md`). _Hot side exits → side traces are
      outstanding._
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
      because a committed trace's only side effect is a **deopt-replay-idempotent
      array store** (Phase B `astore`): host calls / globals / cross-frame all abort
      recording, and the one mutation that *is* allowed — an in-bounds, in-lane
      packed-array write — is recordable only when its value does not depend on any
      prior packed read (C1: `recArraySet` aborts if any `aload` exists in the
      trace). So re-executing the partial iteration after a side-exit reproduces the
      identical write (re-storing the same value into the same slot) rather than a
      doubled effect; pure register values are recomputed as before. See
      `05-native-codegen.md` §Phase B for the C1/C2 invariants and the tier-0
      deopt-replay oracle that proves heap determinism. Integer `//`/`%`-by-zero is
      the only mid-trace error possible (i64 ops wrap, never trap); it side-exits and
      tier-0 re-raises the identical `DivisionByZero`.
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

### Done (Phase 7 — the trace execution log, `src/execlog.zig`)

- [x] **Recording how a trace *ran* (for the visualiser animation).** The executor
      above discards everything but the `completed` count, so the visualiser had no
      way to *animate* a trace spinning. The fix is a per-trace **execution log** — a
      fourth record family (`04-snapshot-replay-schema.md`), and the first pure
      **observation** log: nothing replays it back. `irinterp.zig` is
      comptime-specialized into `executeImpl(comptime record: bool, rec, …)`;
      `execute` (record=false) compiles **byte-identical** to the Phase 6a executor
      (the JIT fast path pays nothing — the branches fold away), while
      `executeTraced(rec, …)` (record=true) drives an `ExecLogRecorder`. One body, no
      drift in the tier-0-parity-critical evaluator.
- [x] **One entry per exit ramp; capped spinning detail.** Each `execute` call
      produces one `TraceEntry` (every entry / **exit ramp** taken). Within it the
      recorder appends an `ExecEvent` per step — `value` (an SSA result landed),
      `guard_pass` (a guard survived), `commit` (an iteration closed and looped) —
      ending in a terminal `exit` event that names the faulting ref and the
      `ExitKind`: `guard` (a guard failed), `arith` (integer `//`/`%`-by-zero
      side-exit), or `clean` (the trace stopped without faulting). The per-entry
      detail is capped at `exec_log_max_iters` (default 16) — past the cap the
      iteration *count* still advances and the exit is **always** recorded, so only
      the middle spinning detail is elided — and entries-per-trace at
      `exec_log_max_entries` (default 64). Both are surfaced as `capped` /
      `entries_capped` flags, never silent. Off by default
      (`TraceConfig.record_exec_log`); the recorder reuses a per-entry scratch buffer
      (no per-event heap traffic).
- [x] **Scalar values, reusing `EffectResult`.** A trace at this phase computes only
      scalars — `slot_load`/`konst`/arith/compare/guards/`loop`, no table or heap IR
      (those abort recording) — so an event value reuses the **`EffectResult`** union
      the effect log already uses (scalars + an inline string for a `konst`), not a
      heap-ref that could dangle after a side-exit. Serialized by `src/execlogser.zig`
      sharing `effectser`'s value mapping. The `trace_id` is the trace-cache index —
      also the visualiser's selection key — so the selected trace maps straight to its
      log. Proven by recorder tests (hot-loop capture, the detail and entry caps, and
      an **observation-only parity** canary: record on/off agree on `regs`/`completed`)
      plus the `execlogser` round-trip corpus and viz end-to-end `bun test`.

### Done (Phase 6b — the trace optimizer, `src/tropt.zig`)

The optimizer runs **once at commit time** (`commit()` → `tropt.optimize`,
gated by `TraceConfig.optimize`, default on; an OOM falls back to the
unoptimized trace) and rewrites the recorded SSA into a smaller, output-identical
body the executor walks every iteration. Three passes share one forward
fold/CSE stage, one backward liveness stage, and one compaction (the compaction
*is* the ref-remap — refs are instruction indices, so any removal/replacement
renumbers).

**The per-pass deopt-reconstruction rule (the standing design rule, discharged).**
Under loop-header re-entry deopt, reconstruction is "tier-0 reruns the
iteration," independent of the optimized body. So each pass's obligation reduces
to: *preserve every completed iteration's `exit_store` values, and never drop a
load-bearing guard.* Concretely:

- [x] **Constant folding.** Folds a pure op whose operands are all constant by
      calling the **same** `irinterp.evalBinary`/`evalUnary` the executor uses —
      so the folded constant is byte-identical to the runtime result, and
      `exit_store` values are preserved by construction. *Reconstruction rule:* a
      fold that would **error** (integer `//`/`%`-by-zero) is **not** performed —
      the op stays in the trace so it side-exits at runtime and tier-0 re-raises
      the identical error. Folds never delete an erroring op.
- [x] **Guard elimination.** Drops a guard **only** when it provably always
      passes (its operand folded to a constant of the guarded type) or is an
      **exact duplicate** of an earlier guard on the same ref (the earlier
      dominates in linear SSA). *Reconstruction rule:* an always-**fail** guard is
      **kept** (never silently remove a deopt that should fire); since the
      executor has no type-specialized fast paths, no *runtime-reachable* guard is
      ever dropped, so the optimized trace never deopts **later** than the raw one
      would. (Deopting earlier is always safe — tier-0 reruns.)
- [x] **CSE.** Redirects a later pure op identical to an earlier one (same
      `{op, operand-refs, aux, ty}`, operand-order-sensitive — no commutative
      canonicalization) to the earlier canonical ref. *Reconstruction rule:* none
      beyond the above — a merged value is bit-identical, and the canonical
      survivor keeps all guards the duplicate's operands carried.
- [x] **Dead-code elimination.** Backward liveness from explicit roots — the
      `loop` terminator, every **kept guard** (side-effecting), and `canon[ref]`
      for **every `exit_store`** — removes pure values nothing observes.
      *Reconstruction rule:* rooting **every** `exit_store` is load-bearing —
      forgetting one would strip the loop-carried computation and tier-0 would
      resume with a stale register. Guards are never DCE'd (only the two
      provably-redundant cases above remove a guard).

These hold only while the executor has **no type-specialized semantics**, every
side exit resumes at the **loop header**, and the shared evaluator stays
**total** — the five preconditions are stated as a comment block atop
`tropt.zig`; Phase 6c (typed fast paths / richer side exits) must re-derive them.

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
- [~] **Standing design rule.** Every optimization that removes/reorders state
      ships its deopt reconstruction rule *before* it lands. **Discharged for
      Phase 6b** — constant folding, guard elimination, CSE, DCE (see the Phase 6b
      block above, each with its rule). **Still owed by** allocation-sinking,
      numeric narrowing, bounds-check elimination, shape specialization, LICM —
      several of which also invalidate the loop-header-deopt preconditions and so
      need general per-guard snapshot restore first.

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
  not just values). *The identity primitive now exists: every heap object carries
  a stable, deterministic `GcHeader.id` assigned at allocation (`src/gc.zig`) —
  this is what a snapshot/keyframe heap graph keys on, instead of an address.*
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
