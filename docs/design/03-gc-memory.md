# lune — GC, Memory & Buffer Ownership

Status: partial — GC v1 (Phase 4) + lane-packed array storage landed; generational upgrade, typed-array payload + buffer lease (Phase 9b), and trace rooting outstanding
Owner: Bart
Last updated: 2026-06-16

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
- [x] **Collector v1 — stop-the-world tri-colour mark-sweep** (Phase 4,
      `src/gc.zig` + `src/interp.zig`). Non-moving (stable addresses), no
      compaction / finalizers / weak refs / concurrency. Split by ownership: the
      **heap** owns the mechanism — a gray worklist, `markValue`/`markHeader`,
      `traceAll` (blacken + grey children, type-dispatched), and `sweep` (free
      white-and-unpinned, de-intern freed strings, reset survivors to white). The
      worklist is **pre-sized** to the live count before marking, so marking
      itself never allocates; a reserve-OOM just skips the cycle with nothing
      coloured. The **VM** owns the **root set** and runs collection at exactly
      one **safepoint — the top of the dispatch loop** — where every register is
      settled and no half-built object is exposed. Roots: `globals`; live
      registers `stack[0..stack_top]` (a per-frame high-water); the **active-frame
      closures** (the explicit call stack `frames[0..depth]`, each frame's
      `.closure` — this is what keeps a frame's `proto.constants` alive); and open
      upvalue cells.
      Blackening a closure walks `proto.constants` recursively through
      `proto.protos`, so a string constant survives even before its function is
      instantiated. **Interned strings are collectible** (swept → de-interned).
      Trigger: live × 2, floored at an initial threshold, with a `gc_stress` knob
      that collects at every safepoint (the torture test). Generational/incremental
      upgrade is future work (the barrier seams below are already in place).
- [x] **Lane-packed table array part — monotonic narrow-lane storage**
      (`src/array.zig`, `src/table.zig`, `src/gc.zig`). A table's dense array run
      (keys `1..n`) is stored in the narrowest **lane** its contents fit: `.value`
      (today's 16 B tagged `Value`, `nil` in-band — the heterogeneous/heap-bearing
      fallback) or a narrow lane (`boolean` ≈ 2 bits/slot, `i8/i16/i32/i64`, `f64`)
      of packed elements plus a 1-bit/slot **presence bitmap** (a narrow lane has
      no bit pattern for a hole). The lane is committed **once**, at the first
      `rehash` that finds a homogeneous run (`ArrayPart.frozen`), and is thereafter
      **monotonic**: an out-of-lane store widens *up* the lattice
      (`boolean`/`i8`→`i16`→`i32`→`i64`→`value`, `f64`→`value`) via `widenFor`, and
      rehash never re-narrows. This bounds an array's total repack work to
      amortised O(1)/slot and closes a repeated widen+re-narrow DoS a *fresh* table
      could otherwise be milked for — each fresh table resets the rehash threshold,
      defeating the doubling amortisation (`bench/repack_adversarial.lua` "storm"
      mode: ~12.3 s pre-monotonic → 0.27 s after, at C=8/M=2000/K=2000, vs ~0.06 s
      in stock LuaJIT). nsieve's all-boolean sieve drops from ~320 MB (16 B/slot)
      to ~11 MB — *below* LuaJIT's 264 MB — with byte-identical output.
      **GC tie-in:** a narrow lane holds no heap pointers, so `blacken` skips the
      array-marking loop entirely (`ArrayPart.isLeaf()`); only the `.value` lane
      and the hash part are traced. The field layout is a frozen `@offsetOf`
      contract for the tier-1b JIT, now consumed by **Phase B** (lane-aware native
      `t[k]` load/store; see `05-native-codegen.md` §Phase B). The same leaf property
      is what lets the native `astore` write a narrow-lane slot with **no write
      barrier** — a narrow lane can never hold a heap reference, so a store into it
      never creates an old→young / black→white edge the collector must track.
      **Trade-off recorded:** monotonic lanes give up speculative width-reclaim
      when an array's values later shrink (rare; ~1 byte/slot) in exchange for the
      O(1) bound and removing the attack surface. The lane then depends on
      contents-*history*, not just current contents — but that stays **unobservable**
      (array payloads are raw `gpa` allocations with no `GcHeader.id`, and GC
      timing / addresses / memory are non-observable per `02-determinism.md`), so a
      lane that diverges across a snapshot→restore changes no program-visible state;
      capture/restore stays byte-identical and run-twice determinism holds.

### Outstanding
- [x] **Object header.** ✅ Shape settled in Phase 1 (`src/object.zig`):
      16-byte `GcHeader` = `ObjectType` + `GcColor` (white/gray/black, ready for
      mark-sweep) + `GcFlags` (pinned/remembered) + intrusive `next` for the
      sweep list. Embedded as the first field of every concrete object; a
      `Value.heap_ref` is a `*GcHeader`. The shape/hidden-class pointer lives in
      the table object, *not* this universal header (no string bloat).
      Collector *behaviour* (the bullets around this one) is still outstanding.
- [x] **Moving vs non-moving commitment.** ✅ Committed to **non-moving** for v1
      (the mark-sweep above never relocates), so traces and the host/GPU lease
      path may hold raw object pointers. If compaction is ever wanted, it must
      introduce handles / relocation-safe refs at that point.
- [~] **Write barriers.** All three mutating stores have a single centralised
      call site each — `set_index` (table store), `set_global`, and `set_upval`
      in the tier-0 interpreter (`src/interp.zig`) — so every "store a heap value
      into a heap object" point calls `Heap.writeBarrier`. The body is a
      **deliberate no-op, and correct as such**: a stop-the-world mark-sweep sees
      the final heap at mark time and needs no barrier. The seams exist so the
      *generational/incremental* upgrade is a body to fill in (remember-set /
      card mark / grey-stack push); the IR and native executors (Phases 6/8) must
      mirror the call sites, and barriers must then be *recorded into traces*.
- [~] **GC root maps.** The tier-0 interpreter's root map is implemented (the
      `Vm.collect` root set: globals, `stack[0..stack_top]`, active-frame
      closures, open upvalues). Still outstanding for the later executors —
      recorder, IR-interpreter, native codegen — where snapshot metadata must
      coordinate with liveness.
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
- [x] **Allocation under tier-0.** ✅ Resolved by the Phase 4 collector above:
      tier-0 allocates through `gc.Heap` and reclaims at the dispatch-loop
      safepoint, so a long-running tier-0 program stays bounded (a 1,000,000-
      iteration allocating loop runs in ~6 MB). "Tier-0 is always correct" now
      holds under memory pressure.

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
