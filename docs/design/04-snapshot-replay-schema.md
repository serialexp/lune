# lune — Snapshot & Replay Schema

Status: draft, not yet implemented — stub capturing required decisions
Owner: Bart
Last updated: 2026-06-12

Prerequisite for **Phase 5b** (trace serialization format) and **Phase 7** (the
visualiser). This doc owns the *concrete wire format* — the binschema schema that
is the versioned contract between the VM (producer) and every consumer
(visualiser, post-mortem tooling, future live debugger). Codex's review noted the
architecture doc says "the layout is defined by the trace schema below" but no
schema follows; this is that schema's home.

## Implementation status

### Done

_(nothing yet — design only)_

### Outstanding

- [ ] **Two artifacts, one substrate.** Define **optimizer guard-snapshots**
      (for deopt) and **debugger keyframes + effect log** (for replay) as
      distinct record types that share encoding — *not* one fused artifact.
- [ ] **Event model.** Minimum event set: event id, bytecode PC, frame id,
      register writes, heap writes, allocation ids, guard snapshots, side exits,
      host/external calls, nondeterministic inputs (effect records), GC events,
      checkpoint/keyframe indexes.
- [ ] **Effect record format** — inputs + outputs sufficient to replay without
      re-running the effect (shared with `02-determinism.md`).
- [ ] **Keyframe format** — VM-state snapshot for replay restore (shares code
      with guard snapshots, `01-trace-lifecycle.md`).
- [ ] **Recording modes.** Full-replay, bounded ring-buffer window, keyframe-only,
      off. Define defaults and per-mode capture filters (bytecode events / heap
      writes / host calls / allocations / source lines).
- [ ] **Volume budget.** Back-of-envelope bytes/step × steps/sec; keyframe
      interval; hard size limits and graceful truncation semantics. **Log what is
      truncated** (no silent caps).
- [ ] **File layout.** Chunked / mmap-friendly with a seek index; string / value
      interning; trace header (hash seed, FP mode, env snapshot, schema version).
- [ ] **binschema schema** in the canonical `binschema` repo; **generate the TS
      decoder**; **hand-write the Zig writer**; validate via cross-language
      fixtures.
- [ ] **Versioning / compat policy.** The schema will churn during Phases 5–7.
      State the policy (likely: visualiser reads traces only from the same VM
      commit) so version skew is handled, not surprising.

## Why this exists

Once a separate tool reads the recording, the format is a real interface —
versioned and deliberate, not "whatever structs were convenient." It also has to
serve two readers with different needs (lossy optimizer vs full-fidelity
debugger) from shared encoding, and stay small enough that a long recording is
still loadable by a browser app. Getting the event model and recording modes
right here is what keeps the visualiser feasible and the JIT decoupled from
debug-recorder bandwidth.

## Goals

- One binschema schema, two record families (guard-snapshots, keyframes+effects),
  shared primitives (the self-describing 16-byte tagged value → discriminated
  union).
- Bounded, seekable, interned trace files; megabyte-scale recordings via
  effects + keyframes (not gigabyte step logs).
- A generated TS decoder so the SolidJS visualiser does zero hand-parsing.

## Non-goals

- A general-purpose serialization framework (binschema already is that).
- Forcing the optimizer to consume the full debug log (decoupled by design —
  `00-architecture.md` §Observability).

## Event model (sketch — to be made concrete)

Discriminated union over record kinds (binschema's core feature):

- `Effect{ id, kind, inputs, outputs }` — a recorded nondeterministic input.
- `Keyframe{ index, vm_state_ref }` — periodic full-ish snapshot for replay.
- `GuardSnapshot{ trace, exit, ir_to_slot_map, sunk_allocs }` — deopt restore.
- `SideExit{ trace, exit, target }`, `TraceEvent{ ... }`, `GCEvent{ ... }`,
  `HeapWrite{ obj, slot, value }`, `Alloc{ id, shape }` — as capture mode dictates.

Values serialise straight from the self-describing tagged slot.

## Open questions

- [ ] Keyframe interval (fixed N events vs adaptive vs heap-delta triggered).
- [ ] JSON for bring-up → compact binary cutover point.
- [ ] How much heap state a keyframe captures (full heap vs delta-from-previous).
- [ ] Interning scope (per-chunk vs per-file string/shape tables).

## References

- `00-architecture.md` — §Observability, §Trace serialization, Phases 5b/7.
- `01-trace-lifecycle.md` — guard-snapshot contents (shared encoding).
- `02-determinism.md` — effect record semantics.
- binschema (`~/Projects/binschema`) — discriminated unions, computed lengths,
  cross-language fixtures; TS decoder generation.
