# lune — Determinism & the Host-Effect Boundary

Status: draft, not yet implemented — stub capturing required decisions
Owner: Bart
Last updated: 2026-06-13

Prerequisite for **Phase 3** (the host-effect boundary must exist in the calling
convention) and **Phase 5** (replay) in `00-architecture.md`. Deterministic
replay was chosen as the recording model; this doc is its foundation. Both
reviewers stressed that determinism is currently asserted, not designed — and
that for a time-travel debugger it *is* the architecture.

## Implementation status

### Done

- [x] **Host-effect boundary — structural seam** (Phase 3). Every external
      interaction is a host function (`Native`, `src/function.zig`): a
      type-erased `*const fn(ctx, args) -> Value` installed as a global. The first
      one is `print`. Crucially, its output does not go to the OS directly — it
      goes through a single injectable redirection point, `Vm.out: ?*io.Writer`
      (`src/interp.zig`): `null` means the process's stdout, but a test (and,
      later, the effect recorder/replayer) points it at an in-memory writer and
      observes the effect without it ever reaching the real world. That one field
      is the proof-of-concept that *all* I/O can be diverted from one place. The
      taxonomy, the effect-record format, and routing time/randomness through this
      seam are still outstanding (below).
- [x] **Transparent trace recording** (Phase 5a, `src/trace.zig`). The recorder
      observes tier-0 — it reads pre-execution operands and emits trace IR — but
      tier-0 still executes every instruction, so recording **cannot change a
      program's result**: it is invisible the same way GC is. A host (`native`)
      call is already treated as a **trace barrier** (the recorder aborts with
      `host_barrier`), matching the effect-boundary policy above — when host-effect
      recording lands, that abort becomes the point an effect record is emitted.
- [x] **Transparent trace *execution*** (Phase 6a, `src/irinterp.zig`). The
      tier-1a IR-interpreter now *runs* hot traces, but it remains output-invariant:
      it calls the **same `arith.zig`** as tier-0 (byte-identical numerics) and
      deopts to tier-0 on any guard miss, re-running the partial iteration (sound
      because committed traces have no side effects). So a program prints the same
      bytes whether a loop runs in tier-0 or tier-1a — the same "run with or without
      for comparison" property, now extended past recording to execution. The
      evidence is the **extended** `expectProgram` matrix in `src/interp.zig`: every
      end-to-end program runs in every {`gc_stress` off/on} × {off, record-only,
      **record+execute**} combination (8-way once Phase 6b adds the optimizer axis —
      see below) and must print **byte-identical** output. An executor divergence
      (wrong arith, missed guard, bad deopt, exit-store error) surfaces as a
      mismatch there.
- [x] **Optimized traces are output-invariant too (Phase 6b).** The trace
      optimizer (`src/tropt.zig`: constant folding, CSE, dead-code elimination,
      run once at commit) rewrites a trace's IR but **cannot change what it
      prints**. Folding computes with the *same* `arith.zig` evaluator the
      executor uses (byte-identical bits, by construction), and a fold that would
      error is left as a runtime op so tier-0 still re-raises it; only
      always-pass and exact-duplicate guards are dropped, so the optimized trace
      never deopts later than the raw one. The evidence is that the
      `expectProgram` matrix is now **8-way** — {`gc_stress` off/on} × {off,
      record-only, record+execute-**noopt**, record+execute-**opt**} — so
      *optimized output == unoptimized output == tier-0* for every e2e program; a
      seeded differential fuzz (`src/interp.zig`) adds 64 random integer loops
      under the same three execution modes. The optimizer is a transparent
      rewrite, exactly like recording and execution before it.

### Outstanding

- [ ] **Effect taxonomy.** Enumerate every nondeterministic source and assign
      each a policy: *forbid in deterministic mode*, *virtualise*, or *log
      inputs/outputs*.
- [ ] **Host-effect *recording*** — the seam exists (Phase 3, above); what's left
      is making each host call emit an effect record (inputs + outputs) and act as
      a trace barrier, so replay can feed the outputs back without re-executing the
      effect.
- [ ] **Effect record format** — inputs + outputs sufficient to replay without
      re-executing the effect. Lives in the trace schema
      (`04-snapshot-replay-schema.md`).
- [x] **Hash seed fixed.** String/table hashing uses Wyhash with a **fixed seed
      0** (`src/string.zig`, `src/table.zig` `ValueContext`), not a per-run random
      seed — so hashing is already reproducible run-to-run. (A trace *header*
      recording the seed is moot until a seed is ever randomised; revisit if that
      changes.)
- [x] **Heap-object identity is deterministic.** Every heap object carries a
      stable, monotonic `GcHeader.id` stamped at allocation by the heap's single
      link-in chokepoint (`src/gc.zig` `link`), and observable rendering
      (`io.writeValue` for `print` of a table/function) shows that id, **never**
      `@intFromPtr`. So no ASLR address leaks into a program's output. This id is
      also the identity a future keyframe's heap graph keys on
      (`01-trace-lifecycle.md`, `04-snapshot-replay-schema.md`).
- [~] **Table iteration order.** Address-independent and deterministic
      (constrains the table/shape model). **The address dependency is now fixed:**
      `table.ValueContext.hash` hashes a heap key by its stable `GcHeader.id`, not
      its `payload.bits` (the ASLR-dependent address). Previously the hash-part's
      slot layout — hence its iteration order — varied run-to-run; that divergence
      was invisible to a program (no `pairs`/`next`) but became observable the
      moment iteration order was *serialized*, which is exactly what a keyframe
      snapshot does. The keyframe serializer (F2a) surfaced it, and the run-twice
      harness now guards it (byte-identical snapshot bytes — see Replay
      verification). Still not actionable at the *program* level until a
      `pairs`/`next` iterator exists; the deterministic ordering rule lands fully
      with that iterator.
- [~] **Floating-point determinism.** FP **mode is pinned**: every float-producing
      function in `src/arith.zig` sets `@setFloatMode(.strict)`, forbidding
      contraction/reassociation regardless of build mode (Zig's default is already
      strict; this guards it explicitly). Still open: NaN payload canonicalisation,
      signed-zero policy, and **cross-platform** bit-identity (same-machine only
      for now — see Open questions).
- [x] **GC observability.** ✅ Decided + implemented (Phase 4). The v1 collector
      (stop-the-world mark-sweep, `03-gc-memory.md`) has **no finalizers, weak
      refs, or ephemerons** — nothing a program can observe to react to collection
      — and runs only at fixed safepoints (the interpreter's dispatch-loop top).
      So *when* a collection happens cannot change a program's result; it is
      invisible. The Phase 3 programs run identically with the collector forced at
      every safepoint (`gc_stress`), which is the evidence. (If a generational
      upgrade later adds GC timing that a trace could observe, it must be scheduled
      deterministically and recorded.)
- [ ] **Time / randomness / environment** routed through the effect boundary
      (no raw access). *Not yet actionable: none of these inputs exist in the
      language — `print` is the only host function, and it is output-only. The
      effect-record format (above) is deliberately deferred until the first such
      input lands, so it is designed against a genuine input+output pair rather
      than output-only `print`.*
- [ ] **Host-mediated suspension hook.** Reserve "a host effect may suspend its
      caller" so generators / await / tasks can be added later without new
      machinery.
- [~] **Replay verification.** Record-then-replay self-check asserting identical
      observable behaviour. **Landed in its honest current form** (`src/interp.zig`
      "determinism" tests): the VM has no nondeterministic inputs and no keyframes
      yet, so "replay" reduces to a second independent run — and the harness
      asserts two independent VM instances of the same source agree on the printed
      output, the **serialized trace cache** (`traceser.encodeFile`), **and the
      serialized keyframe snapshot** (`keyframeser.encodeSnapshot` — the full
      reachable heap graph + roots), plus an address-leak canary (`print` of a heap
      object renders a small stable id, never an ASLR address). The snapshot
      assertion is the strongest of the three: it serializes the entire heap graph,
      so any address leaking into object identity, edge order, or table iteration
      order diverges the bytes — it is what caught the address-dependent table-key
      hashing above. **Restore (F2b) closes the loop**: a snapshot now decodes back
      into a fresh VM (`keyframeser.restore`) and re-serializes **byte-for-byte
      identical** to the original (`encodeSnapshot ∘ restore == identity`, asserted
      over the corpus). Because the restorer re-stamps each object's *original* id,
      the restored VM reproduces the exact table iteration order — so the
      round-trip is a second, independent guard on the id-keyed hashing above. This
      is the regression spine that generalises to true keyframe+effect replay once a
      mid-execution capture point and the effect log exist.

## Why this exists

Deterministic replay reconstructs any past moment by restoring the nearest
keyframe and re-executing forward, feeding recorded effects back in. That is only
*sound* if everything not in a keyframe is reproducible. Every uncaptured,
non-reproducible input is a point where replay silently diverges from reality —
the worst kind of debugger bug. So the runtime must either eliminate a
nondeterminism source, virtualise it, or record it. This doc is the exhaustive
accounting that makes "deterministic" true rather than aspirational.

## Goals

- A complete, enforced taxonomy: no nondeterministic input reaches a script
  except through a recordable boundary.
- The same boundary serves embedding (host calls), replay (effect log), the JIT
  (trace barriers), and future async (host-mediated suspension).

## Non-goals

- General script-level C FFI (an unrecordable effect hole — out per
  `00-architecture.md`).
- General coroutines (replaced by host-mediated suspension; see below).

## Effect taxonomy (to be completed)

| Source | Policy (forbid / virtualise / log) | Notes |
|---|---|---|
| Host function calls | log inputs+outputs | the primary boundary |
| Time / clock | log | via host effect |
| Randomness | log or seed | seed stored in trace header |
| File / network / stdin | log results | host effect |
| Environment / args | log at startup | snapshot in header |
| Hash seed | fix per recording | header |
| Table iteration order | design out | address-independent |
| FP mode / NaN / signed zero | pin / canonicalise | platform math policy |
| GC timing (if observable) | forbid observability or schedule deterministically | no finalizers/weak refs v1 |

## Host-mediated suspension (the coroutine replacement)

General stackful coroutines are out (`00-architecture.md` Non-goals). The
replacement is built *on this boundary*: an `await` is "call a host effect that
may suspend the caller." Because every host call is already a recorded effect and
a trace barrier, the suspend/resume schedule is captured as effects and replays
deterministically for free. The three surface forms — stackless generators,
host-mediated `await`, host-owned tasks (structured concurrency) — are a later
language-surface design; v1 only has to **not preclude** a suspending host
effect.

## Open questions

- [ ] Finalizers/weak refs: ban for v1, or deterministic GC scheduling?
- [ ] Cross-platform FP: do we guarantee bit-identical replay across machines, or
      only same-machine? (Same-machine is far cheaper.)
- [ ] Effect-log compaction / interning for high-frequency host calls.

## References

- `00-architecture.md` — §Determinism, §Embedding API, §Observability.
- `04-snapshot-replay-schema.md` — effect record + keyframe formats.
- Prior art: rr, WinDbg Time Travel Debugging; structured concurrency
  (Kotlin / Swift / Trio).
