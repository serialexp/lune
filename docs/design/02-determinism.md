# lune — Determinism & the Host-Effect Boundary

Status: draft, not yet implemented — stub capturing required decisions
Owner: Bart
Last updated: 2026-06-12

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
- [ ] **Hash seed policy.** Fixed per recording, stored in the trace header.
- [ ] **Table iteration order.** Address-independent and deterministic
      (constrains the table/shape model).
- [ ] **Floating-point determinism.** Pin FP mode; define NaN payload
      canonicalisation, signed zero, and a fixed math-library policy across
      platforms.
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
      (no raw access).
- [ ] **Host-mediated suspension hook.** Reserve "a host effect may suspend its
      caller" so generators / await / tasks can be added later without new
      machinery.
- [ ] **Replay verification.** Record-then-replay self-check asserting identical
      observable behavior (ties to the testing strategy).

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
