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

_(nothing yet — design only)_

### Outstanding

- [ ] **Effect taxonomy.** Enumerate every nondeterministic source and assign
      each a policy: *forbid in deterministic mode*, *virtualise*, or *log
      inputs/outputs*.
- [ ] **Host-effect boundary in the calling convention** (Phase 3) — the single
      point all external interaction flows through; every call is an effect
      record + trace barrier.
- [ ] **Effect record format** — inputs + outputs sufficient to replay without
      re-executing the effect. Lives in the trace schema
      (`04-snapshot-replay-schema.md`).
- [ ] **Hash seed policy.** Fixed per recording, stored in the trace header.
- [ ] **Table iteration order.** Address-independent and deterministic
      (constrains the table/shape model).
- [ ] **Floating-point determinism.** Pin FP mode; define NaN payload
      canonicalisation, signed zero, and a fixed math-library policy across
      platforms.
- [ ] **GC observability.** No finalizers / weak refs / ephemerons in v1, *or*
      GC scheduled at recorded safepoints so timing is reproducible. Decide.
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
