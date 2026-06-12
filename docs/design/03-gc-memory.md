# lune — GC, Memory & Buffer Ownership

Status: draft, not yet implemented — stub capturing required decisions
Owner: Bart
Last updated: 2026-06-12

Prerequisite for **Phase 1** (object header + GC-root model), **Phase 3**
(write-barrier call sites), and **Phase 4** (the collector). Both reviewers
flagged that "start simple, design for generational later" under-specifies three
contracts that a tracing JIT and a zero-copy GPU path both depend on: pinning/
ownership, write barriers, and trace rooting.

## Implementation status

### Done

_(nothing yet — design only)_

### Outstanding

- [ ] **Collector choice (v1).** A deliberately boring **non-moving** collector
      (stable object addresses) — e.g. non-moving mark-sweep. Decide the exact
      algorithm and the generational-upgrade path.
- [ ] **Object header.** Type, GC mark/age, shape pointer for table-likes;
      64-bit fields. Settled in Phase 1 (it leaks into value layout, trace
      encoding, FFI ABI, debugger display).
- [ ] **Moving vs non-moving commitment.** Non-moving means traces may hold raw
      object pointers. If moving/compaction is ever wanted, design
      handles / relocation-safe refs from day one. (Default: non-moving v1.)
- [ ] **Write barriers from Phase 3.** Barrier *call sites* on table/array/object
      stores must exist from the interpreter onward (no-op until generational),
      including stores emitted by IR (Phase 6) and native code (Phase 8).
      Barriers must be *recorded into traces*.
- [ ] **GC root maps** for every executor: interpreter, recorder, IR-interpreter,
      native codegen. Snapshot metadata must coordinate with liveness.
- [ ] **Safepoints in long-running traces** so a hot loop can't block collection.
- [ ] **Trace-constant rooting + invalidation.** Traces embed object refs
      (constants, shape pointers) → GC roots; collecting a referenced prototype
      invalidates dependent traces (ties to `01-trace-lifecycle.md`).
- [ ] **Typed-array payload storage.** Off-heap / non-moving, with a GC'd header
      referencing a stable payload. Alignment + endianness guarantees (for GPU
      upload).
- [ ] **Buffer ownership model.** Explicit owner enum: `vm_owned`,
      `external_borrowed`, `external_owned_with_finalizer`, `pinned_export`.
      A zero-copy export returns a **lease** (lifetime + mutability rules), never
      a raw interior pointer.
- [ ] **Allocation under tier-0.** A bump allocator alone makes "tier-0 always
      correct" false under memory pressure — need at least the non-moving
      collector by Phase 3/4.

## Why this exists

A tracing JIT bakes GC assumptions into snapshots, write barriers, safepoints,
allocation fast paths, object headers, and root maps. Get the GC contracts wrong
and you pay for it in the hardest-to-debug place: a moved or freed object behind
a raw pointer in a trace, or a buffer collected while the GPU still reads it.
The zero-copy "GPU-upload-ready" promise (`00-architecture.md` §Value
representation) collides head-on with a moving collector unless ownership and
pinning are designed up front. This doc makes those three contracts explicit.

## Goals

- A v1 GC that is boring, correct, and JIT/replay-friendly, with a clear upgrade
  path to generational.
- A buffer ownership model that makes zero-copy GPU/FFI handoff safe (no
  use-after-free across the boundary) without exposing movable GC memory.

## Non-goals (v1)

- Moving / compacting collection (deferred; keep the door open via the header).
- Finalizers, weak refs, ephemerons — determinism hazards (see
  `02-determinism.md`); banned or deferred in v1.
- Concurrent collection.

## Buffer ownership (sketch)

The zero-copy path hands the host a **lease**, not a pointer:

- Payload lives **off-heap / non-moving** (so addresses are stable for the GPU).
- A GC'd header keeps it alive; the lease pins it for the host's borrow window.
- The lease carries lifetime + mutability; lune may not mutate a buffer the host
  has leased mutably to the GPU, and the buffer is not freed until the lease ends.
- No interior pointers into movable GC memory ever cross the boundary.

## Open questions

- [ ] Exact non-moving collector (mark-sweep with free-lists? segregated fits?).
- [ ] Generational upgrade: remembered-set representation; nursery design.
- [ ] Large-object / off-heap space layout for typed-array payloads.
- [ ] Lease revocation semantics if the host outlives the VM or vice-versa.

## References

- `00-architecture.md` — §Value representation, §Embedding API, Phases 1/3/4.
- `01-trace-lifecycle.md` — snapshot GC roots, trace-constant rooting.
- `02-determinism.md` — GC-observability rules.
- Prior art: LuaJIT GC (incremental mark-sweep; the unfinished generational GC),
  Immix (regional), V8 (generational + write barriers).
