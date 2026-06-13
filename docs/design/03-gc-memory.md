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

- [x] **Heap object lifecycle — allocate-and-link** (Phase 3, `src/gc.zig`).
      Every heap object (string, table, closure, upvalue, native) is allocated
      through `gc.Heap` and prepended to a single **intrusive sweep list** via the
      `GcHeader.next` field settled in Phase 1; `Heap.deinit` walks that list and
      frees everything wholesale. This is the allocate-only precursor to the
      collector: tier-0 never frees an individual object, so object addresses are
      trivially stable and the sweep list is already the exact structure a
      mark-sweep will traverse. **String interning** lives here too (a content→
      object map, so equal strings are one object and key/equality become pointer
      compares — also the canonicalisation a deterministic table-iteration order
      will rely on).

### Outstanding

- [ ] **Collector choice (v1).** A deliberately boring **non-moving** collector
      (stable object addresses) — e.g. non-moving mark-sweep. Decide the exact
      algorithm and the generational-upgrade path.
- [x] **Object header.** ✅ Shape settled in Phase 1 (`src/object.zig`):
      16-byte `GcHeader` = `ObjectType` + `GcColor` (white/gray/black, ready for
      mark-sweep) + `GcFlags` (pinned/remembered) + intrusive `next` for the
      sweep list. Embedded as the first field of every concrete object; a
      `Value.heap_ref` is a `*GcHeader`. The shape/hidden-class pointer lives in
      the table object, *not* this universal header (no string bloat).
      Collector *behaviour* (the bullets around this one) is still outstanding.
- [ ] **Moving vs non-moving commitment.** Non-moving means traces may hold raw
      object pointers. If moving/compaction is ever wanted, design
      handles / relocation-safe refs from day one. (Default: non-moving v1.)
- [~] **Write barriers from Phase 3.** The mutating stores all exist and are
      centralised: `set_index` (table store), `set_global`, and `set_upval` each
      go through one code path in the tier-0 interpreter (`src/interp.zig`) /
      `table.set` (`src/table.zig`) — so the barrier has exactly one attach point
      per store kind rather than scattered call sites. The barrier *body* is still
      a deliberate no-op: there is no generational collector yet to remember
      old→young edges, so emitting a stub now would be untested dead code. Phase 4
      adds the real barrier at these existing seams (and the IR/native executors,
      Phases 6/8, must mirror it); barriers must also be *recorded into traces*.
- [ ] **GC root maps** for every executor: interpreter, recorder, IR-interpreter,
      native codegen. Snapshot metadata must coordinate with liveness.
- [ ] **Safepoints in long-running traces** so a hot loop can't block collection.
- [ ] **Trace-constant rooting + invalidation.** Traces embed object refs
      (constants, shape pointers) → GC roots; collecting a referenced prototype
      invalidates dependent traces (ties to `01-trace-lifecycle.md`).
- [~] **Typed-array payload storage.** Descriptor settled in Phase 1
      (`src/object.zig` `TypedArray`: `GcHeader` + `ElementType` + len/cap +
      off-heap `data` pointer + `BufferOwner`). Still outstanding: actually
      allocating the off-heap/non-moving payload, alignment to
      `ElementType.alignBytes()`, and endianness guarantees for GPU upload —
      Phase 9b.
- [~] **Buffer ownership model.** Enum settled in Phase 1 (`src/object.zig`
      `BufferOwner`: `vm_owned`, `external_borrowed`,
      `external_owned_with_finalizer`, `pinned_export`). Still outstanding: the
      **lease** mechanism itself (lifetime + mutability rules; never a raw
      interior pointer) — implemented with the typed-array container in Phase 9b.
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
