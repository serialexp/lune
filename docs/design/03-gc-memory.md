# lune — GC, Memory & Buffer Ownership

Status: partial — GC v1 (Phase 4) + lane-packed array storage landed; generational upgrade, typed-array payload + buffer lease (Phase 9b), and trace rooting outstanding
Owner: Bart
Last updated: 2026-07-19 (LANDED §"Chunk-constant rooting — the compile→run window": `Vm.retained_chunks` borrow list + `retainChunk`/`releaseChunk` (`orderedRemove`) + `rootProtoConsts` rooted in BOTH `forEachRootHeader` walks, closing the embedding compile-then-defer GC hole surfaced by the doc-17 H-2 part-3 harness. Design went gpt-5.6-sol rounds 1–5 to APPROVE: option A "host re-supplies" restore path (retained chunks are host-authored program image like the main `root`, so `.snapshot` rooting + host re-compile/re-retain preserves constant-id continuity across a snapshot straddle) + borrow lifetime contract (release before `Chunk.deinit`) + same-order re-retain contract. Landed with 4 interp tests + 1 keyframeser snapshot-straddle test, all 4 negative controls verified load-bearing, green under `just test` + `-Djit-debug`.)

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
      (keys `0..asize-1`, identity-mapped — slot == key, doc 18) is stored in the
      narrowest **lane** its contents fit: `.value`
      (today's 16 B tagged `Value`, `nil` in-band — the heterogeneous/heap-bearing
      fallback) or a narrow lane (`boolean` 1 byte/slot, `i8/i16/i32/i64`, `f64`)
      of packed elements. The fixed-width int/float lanes carry a separate 1-bit/
      slot **presence bitmap** (every int/float bit pattern is a valid value, so a
      hole needs an out-of-band marker); the `boolean` lane encodes all three states
      **in-band** in its byte (`0 = absent, 1 = false, 2 = true`) so a slot is a
      single non-RMW `mov byte`/`movzx` — the byte is x86's smallest unit reachable
      with one instruction, and sub-byte packing would force `bt`/`bts`/`btr`
      read-modify-write ops across two cachelines (the prior 2-bit packing did, at
      4× less memory but ~2× the per-write cost). The lane is committed **once**, at the first
      `rehash` that finds a homogeneous run (`ArrayPart.frozen`), and is thereafter
      **monotonic**: an out-of-lane store widens *up* the lattice
      (`boolean`/`i8`→`i16`→`i32`→`i64`→`value`, `f64`→`value`) via `widenFor`, and
      rehash never re-narrows. This bounds an array's total repack work to
      amortised O(1)/slot and closes a repeated widen+re-narrow DoS a *fresh* table
      could otherwise be milked for — each fresh table resets the rehash threshold,
      defeating the doubling amortisation (`bench/repack_adversarial.lua` "storm"
      mode: ~12.3 s pre-monotonic → 0.27 s after, at C=8/M=2000/K=2000, vs ~0.06 s
      in stock LuaJIT). An all-boolean sieve of ~20 M slots
      (`bench/sieve_int.lua 20000000`) drops from ~320 MB (16 B/slot) to ~51 MB
      resident (1 byte/slot in-band + the int `primes` array) — *below* LuaJIT's
      ~264 MB — with byte-identical output.
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
- [x] **Chunk-constant rooting (compile→run window).** LANDED (`src/interp.zig`
      `Vm.retained_chunks` borrow list + `retainChunk`/`releaseChunk` +
      `rootProtoConsts`, rooted in BOTH walks of `forEachRootHeader`; `releaseChunk`
      uses `orderedRemove` to preserve survivor/discovery order). A host-compiled-but-
      not-yet-run chunk's interned constants now survive a GC driven by another
      execution AND keep their ids across a snapshot straddle (restore path A — host
      re-compiles + re-retains the chunk in the same order, like the main `root`). Design
      of record is §"Chunk-constant rooting — the compile→run window" below (gpt-5.6-sol
      rounds 1–5, round 5 = APPROVE). Tests: 4 in `interp.zig` (regression survival under
      `gc_stress`, `releaseChunk` unroot via `interned.get`, `orderedRemove` survivor order
      with 3 chunks, 10-mode byte-identity) + 1 in `keyframeser.zig` (snapshot straddle:
      same-order re-retain → byte-identical, reversed → differs); all four negative controls
      verified load-bearing. Snapshot guarantee scoped to UNRUN retained chunks (multi-host-
      chunk live-closure snapshot remains a pre-existing resolver follow-up, noted below).
      Surfaced by the doc-17 H-2 part-3 harness.

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

## Chunk-constant rooting — the compile→run window (2026-07-19)

**Status: DESIGN — pending `gpt-5.6-sol` review.** Surfaced by the doc-17 H-2 part-3 test
harness; gpt-5.6-sol confirmed it as a real latent product concern deserving its own fix.

**The hole.** A compiled `compiler.Chunk` owns its proto tree (an arena) and each proto's
`constants: []const Value`. Heap-valued constants are **interned string literals** — the
only heap constant kind the compiler emits (`compiler.zig:362`, `internValue`) — and each
is an ordinary GC object on the sweep list. They are kept alive **only transitively**:
`blacken` reaches `markProtoConstants` from a live **closure** (`gc.zig:512`), and
`forEachRootHeader` roots closures only via `frames[0..depth]` + live registers/globals
(`interp.zig:1638`). A `Chunk` with **no live closure over its tree** therefore has
**unrooted** constants.

Collection fires at exactly one point — the dispatch-loop safepoint (`interp.zig:1761`,
gated on `shouldCollect`) — i.e. only **while a VM is executing**, never during
compilation or inside a straight-line native (allocation merely arms `shouldCollect` for
the *next* safepoint; it never sweeps in place). So the exposure is precisely:

> a `Chunk` is compiled, then a **different** execution runs (and GCs) before any closure
> over that chunk's tree exists.

The shipped paths are safe today:
- **CLI main** (`main.zig`): compiles one chunk, then `vm.run(proto)` creates and pushes
  the main closure **before the first safepoint** — no GC window.
- **`load`/`loadfile`/`dofile`**: the native is atomic w.r.t. safepoints (a collection
  cannot fire mid-native), and it returns a closure that roots the tree; after the guest
  drops that closure the loaded chunk's constants are swept — *intended*, and
  mode-consistent post-H-2 (part 1 ensures no trace roots them either).

The **unsafe** path is the **embedding compile-then-defer pattern**: a host compiles
chunk B, then runs chunk A (which GCs under memory pressure or `gc_stress`), then runs B —
B's literals are swept before B ever runs, dangling its `load_const`s. This is exactly
what the H-2 part-3 test harness hit (worked around there by interleaving compile+run per
epoch, so each chunk's constants are live from the moment they exist).

**The fix (Bart's call — root host-retained chunks in the existing root-walk authority,
option A "host re-supplies" for the restore path).** Add a VM-side **non-owning** list of
proto trees the host has asked the VM to keep alive, and root their constants in
`forEachRootHeader`:

- `Vm.retained_chunks: std.ArrayList(*const bytecode.Proto)` — **borrows only**; the host
  still owns the `Chunk` and frees it. A `*const Proto` is the minimal handle; the whole
  tree is reachable from the root via `proto.protos`. Deinited (`retained_chunks.deinit(self.gpa)`,
  list only, no frees) in `Vm.deinit`.
- `pub fn retainChunk(self: *Vm, proto: *const bytecode.Proto) !void` —
  `self.retained_chunks.append(self.gpa, proto)` (pinned-stdlib `ArrayList.append` takes
  the allocator explicitly). Contract: one `retainChunk` per `releaseChunk`. (A stray
  double-retain double-roots harmlessly — marking is idempotent — but the balanced
  contract is what keeps `releaseChunk`'s first-match removal correct.)
- `pub fn releaseChunk(self: *Vm, proto: *const bytecode.Proto) void` — **`orderedRemove`**
  the first pointer match (a borrow, so no free), NOT `swapRemove` (gpt-5.6-sol round-3
  blocker): a swap-remove would reorder the surviving borrows (`release A` from `[A,B,C]`
  leaves `[C,B]`), and since retained constants are serialized in root-**discovery** order,
  a reordered survivor list changes snapshot bytes — breaking the same-ordered-retain
  contract below. `orderedRemove` preserves survivors' relative insertion order.
  Idempotent-safe: a missing entry is a no-op.
- In `forEachRootHeader`, in **BOTH** the `.gc` and `.snapshot` walks (see "Restore
  contract" below), walk each retained proto tree's constants and `cb` the heap ones via a
  recursive helper:
  ```zig
  fn rootProtoConsts(proto: *const bytecode.Proto, ctx: anytype,
                     comptime cb: fn (@TypeOf(ctx), *object.GcHeader) void) void {
      // Compiler-produced protos only (retainChunk's contract): the compiler emits
      // exactly interned-string and scalar constants (compiler.zig:361), never a
      // `row_view` fat value — so `isHeap → asHeap` is complete here (no `markValue`
      // row_view-parent special case needed, matching the item-5 trace-const loop).
      for (proto.constants) |v| if (v.isHeap()) cb(ctx, v.asHeap());
      for (proto.protos) |child| rootProtoConsts(child, ctx, cb);
  }
  ```

**Lifetime contract (gpt-5.6-sol blocker — borrows must not dangle).** `retained_chunks`
holds raw `*const Proto` borrows into a host-owned `Chunk` arena (`Chunk.deinit` frees that
arena, `compiler.zig:58`). The root walk dereferences them at every GC safepoint. The
embedding contract is therefore explicit:
- the host MUST `releaseChunk(proto)` **before** `Chunk.deinit()`;
- the whole proto tree + its arena MUST stay alive from a successful `retainChunk` through
  its `releaseChunk`;
- no VM execution/collection may run after a retained borrow is invalidated but before its
  release (which the two rules above already guarantee);
- VM teardown may discard outstanding borrows only because `Vm.deinit` performs no further
  root walk. (A debug assert that `retained_chunks` is empty at `deinit` is a reasonable
  balance-check, but not required for safety.)

**Restore contract — option A ("host re-supplies", like the main `root` chunk).** A
snapshot is heap + execution state, **not** the program image: `restore(bytes, root,
natives)` takes the program's root proto from the caller (`keyframeser.zig:501`). Retained
chunks are **host-authored program image** — the same category as `root`/main — so the
host re-supplies (re-compiles + re-retains) them on restore, exactly as it re-supplies
`root`. For their already-consumed constant **ids** to line up across the cut:
- retained constants are rooted in the **`.snapshot`** walk too, so they serialize *as
  objects with their ids* (identical to a *reachable* `loaded_chunk`, `keyframeser.zig:541`);
- on restore the objects are reconstructed with those ids; when the host re-compiles + re-
  retains the chunk, `internValue` finds the reconstructed object and **reuses it** (no
  fresh allocation) → the literal keeps its original id → `pairs`/id timeline is identical
  to the uninterrupted run.
- **`encodeSnapshot ∘ restore == identity`** holds *given the host re-establishes its
  program state* — which is already a restore precondition (a bare restore can't even
  resolve closures without `root`). The host re-retains before any execution or re-encode;
  restore itself never runs the VM, so the reconstructed constants can't be swept in the
  gap. This is NOT the trace-const case (item 5, `.gc`-only): trace consts are **mode-
  dependent** (present under record, absent under `.off`) so serializing them would make
  snapshot bytes vary by JIT mode; retained-chunk membership is a **host action, mode-
  invariant**, so rooting it in `.snapshot` is byte-identical across all 10 modes.
- **Order, not just membership, is the deterministic input (gpt-5.6-sol round-2 blocker).**
  Snapshot objects serialize in **root-discovery order**, not sorted by id (`Walk.order`,
  `keyframeser.zig:170`, seeded via `forEachRootHeader(.snapshot, …)`, `:268`). So the host
  must re-retain the pending chunks in the **same order** it originally retained them —
  retaining `[X, Y]` before the cut but `[Y, X]` after would reorder their otherwise-
  unreachable constants and change the snapshot bytes even though the *set* is identical.
  The contract is: same ordered `retainChunk` sequence across the cut (duplicate
  multiplicity is irrelevant after the serializer's dedup; order of first-appearance is
  what matters).

**Scope restriction — the snapshot guarantee is for UNRUN retained chunks only
(gpt-5.6-sol round-2 blocker).** Option A's cross-cut id continuity holds only for a chunk
that is **pending/unrun with no guest-reachable closure over its proto tree** — which is
exactly the compile→run window `retainChunk` exists for (a retained chunk is unrun by
definition; the instant it runs, a closure roots its constants and the host should
`releaseChunk`). If a retained host chunk has *already run* and left a live closure in a
global/table at snapshot time, restore fails **before the host can re-supply the chunk**:
serialized closures carry only `proto_id` (`keyframeser.zig:149`), and `resolveProto`
searches **only** the supplied `root` tree + `vm.loaded_chunks` (`keyframeser.zig:429`),
resolved during pass 1b *before* `restoreSnapshot` returns (`keyframeser.zig:634`). A
secondary host chunk's proto is in neither set → `error.UnknownProto`. This is a
**pre-existing** limitation of the resolver (independent of this fix — it already can't
snapshot a live closure over any non-`root`, non-`loaded` host chunk), and host chunks
compiled with the default `id_base = 0` (`compiler.zig:61`) also collide proto ids with the
static tree. **Out of scope here; noted as a follow-up:** supporting snapshots of live
closures over multiple host-authored program images needs restore to accept a *list* of
program images (not one `root`) as its resolver set, plus a disjoint proto-id contract for
host chunks (mirroring `load`'s `id_base = next_proto_id`). Until then, `retainChunk`'s
snapshot guarantee is documented as unrun-only, and the correct host discipline is: retain
before first run, `releaseChunk` at/after first run (the closure takes over rooting).

**Why not option B (VM owns + auto-recompiles, the `loaded_chunks` machinery).**
`loaded_chunks` are serialized+recompiled *because the host cannot re-supply guest-authored
`load` code*. Host-retained chunks are host-authored, so that reason doesn't apply —
option B would duplicate the load/L-2 subsystem (schema list, recompile path, proto-id
disjointness, ownership transfer) to buy a capability the host already has. A is the
architecturally consistent choice.

**Determinism.** `retained_chunks` membership is a **host action**, identical across all
10 JIT modes and independent of GC timing → rooting the set (in both walks) is
mode-invariant. No new nondeterministic input is introduced; the root steers only object
liveness, never a `Value` a program computes on.

**Considered and excluded — rooting `loaded_chunks`.** *(SUPERSEDED by doc 19,
2026-08-14 — kept for the historical reasoning.)* The original verdict: `load`ed chunks
need no rooting for the compile→run window (`compileToClosure` performs no VM re-entry or
safepoint — collection can only fire at the dispatch-loop safepoint, never mid-native —
and the returned closure roots the tree), and after the closure drops we *wanted* them
swept, so rooting looked like "a memory-retention change with no correctness upside".
Doc 19 reversed this: the upside is **tracing the loaded tree**. Rooting
`vm.loaded_chunks[].chunk.proto` constants in BOTH walks makes them mode-invariantly live
for the VM's lifetime, which makes a trace konst over a loaded proto always redundant —
unreachable H-2 sole-root state — and let the dynamic-proto tracing gate (which kept every
`require`d module JIT-dark) be lifted. The retention cost is a strict subset of the
`Chunk` + source text `loaded_chunks` already holds until deinit. Keyframe v8 pairs with
this (encoder now always serializes loaded-proto literals; restore recompile is
zero-allocation, enforced).

**`run`/`start` need no auto-register.** The main-chunk window is closed by construction
(the closure is pushed before the first safepoint), so `retainChunk` is purely opt-in for
the compile-then-defer host pattern.

**Tests.**
1. **Embedding compile-then-defer survives GC (the regression).** On one VM, `gc_stress`
   on: compile chunk B (whose distinctive string literal is used *inside* it as a
   `load_const`), `retainChunk(B.proto)`, run chunk A (allocates → forces sweeps), then run
   B and assert its output byte-identical to a no-stress reference run. Negative control:
   with `retainChunk` skipped (or the new root removed) B's `load_const` dangles → the
   test reddens.
2. **Snapshot straddle preserves constant ids AND root order (the option-A guarantee).**
   Following the H-2-part-3 construction (stable ids via `pairs` order, **not** a
   dangling-memory probe). Use **three** pending chunks so ordering — and specifically
   `orderedRemove` vs `swapRemove` — is actually exercised (gpt-5.6-sol rounds 3–4; with
   only two chunks, releasing the first leaves a single-element list identical under both
   removals). Compile X, Y, Z, each with a distinct otherwise-unreachable literal, and
   `retainChunk` them in order (compile precedes retain); snapshot; restore into a fresh VM
   (re-supplying `root`), re-compile X/Y/Z and re-retain **in the same order**, and
   **re-encode + assert byte equality with the original snapshot**. Sub-assertions:
   (a) reversed re-retain order (`[Z, Y, X]`) produces *different* bytes (order is the
   deterministic input); (b) `releaseChunk(X)` from `[X, Y, Z]` must leave `[Y, Z]` (ordered)
   — a `swapRemove` would leave `[Z, Y]`, changing root-discovery order and thus the
   re-encoded bytes; (c) a downstream `pairs`-order check over a literal + a later-interned
   marker matches the uninterrupted run (id continuity). Negative controls: `.gc`-only
   rooting reddens (c); `swapRemove` in `releaseChunk` reddens (b)'s byte assertion.
3. **`releaseChunk` unroots.** After `releaseChunk`, the chunk's now-unrooted constants
   are swept by the next stress GC (the retain is not sticky).
4. **10-mode determinism** over a program that retains + runs a deferred chunk — output
   byte-identical across all modes (mode-invariance of the new root in both walks).

**Sequence:** design (this) → `gpt-5.6-sol` review (round 1 = BLOCKER, folded: option-A
`.snapshot` rooting + host-re-supply restore contract, the borrow lifetime contract, the
`compileToClosure`/`row_view`/stable-id-test/`append` nits; round 2 = BLOCKER, folded:
same-ordered re-retain across the cut + re-encode/byte-identity in test 2, and the
unrun-only snapshot scope restriction with the pre-existing multi-host-chunk resolver
limitation noted as a follow-up; round 3 = BLOCKER, folded: `releaseChunk` uses
`orderedRemove` not `swapRemove` (survivor-order preservation); round 4 = BLOCKER, folded:
test 2 uses **three** pending chunks so `orderedRemove` vs `swapRemove` is distinguishable
(two collapse to one survivor); round 5 = **APPROVE**) → land behind `just test` (default +
`-Djit-debug`).

## References

- `00-architecture.md` — §Value representation, §Embedding API, Phases 1/3/4.
- `01-trace-lifecycle.md` — snapshot GC roots, trace-constant rooting.
- `02-determinism.md` — GC-observability rules.
- Prior art: LuaJIT GC (incremental mark-sweep; the unfinished generational GC),
  Immix (regional), V8 (generational + write barriers).
