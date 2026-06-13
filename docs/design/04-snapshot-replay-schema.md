# lune — Snapshot & Replay Schema

Status: draft — trace artifact + keyframe capture/restore (F2a+F2b) landed; replay outstanding
Owner: Bart
Last updated: 2026-06-13

Prerequisite for **Phase 5b** (trace serialization format) and **Phase 7** (the
visualiser). This doc owns the *concrete wire format* — the binschema schema that
is the versioned contract between the VM (producer) and every consumer
(visualiser, post-mortem tooling, future live debugger). Codex's review noted the
architecture doc says "the layout is defined by the trace schema below" but no
schema follows; this is that schema's home.

## Implementation status

### Done

- [x] **Trace artifact wire format (Phase 5b — Zig round-trip).** The committed
      trace cache serializes to a versioned, on-disk binary form. The format is
      defined declaratively in **`schema/trace.json`** (binschema); the Zig
      encoder/decoder is **generated** from it by binschema's Zig backend
      (`tools/regen-trace-schema.sh`) and **vendored** under `src/gen/` — committed
      output, so lune builds with no dependency on the binschema repo.
      `src/traceser.zig` maps a `trace.Trace` onto the schema structs and writes a
      `TraceFile { version, traces[] }`; the CLI's `--emit-traces <file>` drops it
      after a run. Schema shape: `Trace { anchor_proto_id, anchor_pc, instrs[],
      consts[], entry_slots[], exit_stores[] }`; `ConstValue` is a discriminated
      union tagged on lune's `Value.Tag` (nil/boolean/int/float + a `ConstString`
      variant for the only heap const a trace can hold). **Decisions made here:**
      (a) the in-memory `*const Proto` anchor pointer is replaced by a stable,
      compile-time **`Proto.id`** — a pointer is meaningless on disk, and the
      visualiser uses the id only as a correlation key (trace → proto →
      disassembly), never rebinding a live pointer; (b) a minimal **`version`**
      word heads the file; the richer recording header (hash seed, FP mode, env
      snapshot) belongs with effect-recording and is deferred. Round-trip is proven
      byte/struct-exact for real recorded traces (numeric + a string const) and a
      hand-built edge corpus (`INT64_MIN/MAX`, i32-aux extremes, FP specials,
      NUL-bearing strings). **Landed in Phase 7:** the generated **TypeScript
      decoder** (vendored under `viz/src/gen/`, same regen script) + a binschema
      **cross-language fixture** (`viz/fixtures/counting-loop.lunetrace`,
      Zig-encoded, decoded + asserted by `viz` `bun test`). **Deferred → later:**
      reload-into-VM (id→`*Proto` rebind
      + proto-hash validation, string interning, live `Value` reconstruction).

- [x] **Keyframe snapshot SERIALIZER (Phase 7 v2 / F2a — Zig round-trip +
      run-twice determinism).** A whole-VM keyframe — the full reachable heap
      graph + VM roots at a moment — serializes to a versioned, on-disk binary
      form, sharing the same generated binschema codec as the trace artifact. The
      schema (`schema/trace.json`) gains an **additive** record family alongside
      the `Trace*`/`Const*` types, headed by its **own** version word so the trace
      format (`traceser.format_version` = 1) is untouched: `SnapshotFile { version,
      keyframe }`; `Keyframe { globals_id, objects[], stack[], frames[],
      open_upvalues[] }`; `HeapObject { id, obj_type, body }` — a flat array keyed
      by `GcHeader.id`, `body` a discriminated union on `obj_type` (mirroring the
      `ObjectType` ordinals: `HeapString`=0 / `HeapTable`=1 / `HeapClosure`=2 /
      `HeapNative`=3 / `HeapUpvalue`=4; `typed_array`/`host` have no variant yet and
      the serializer errors `UnsupportedObject`). Every inter-object edge is a
      `u32` id, never a pointer: `SnapValue { tag, body }` reuses the `Const*`
      variants and adds `HeapRef { id }` for `heap_ref` (tag 4); `HeapClosure`
      carries `proto_id` + `upvalue_ids[]` (the proto's constants are reached as
      their own `HeapObject`s, never inlined); `HeapUpvalue` carries
      `closed` + the captured `SnapValue`. `src/keyframeser.zig` maps a live VM
      onto these structs (its object-dispatch mirrors `gc.blacken` exactly, so it
      is provably complete against the GC's own edge set) and the reachable-set
      walk is seeded from the **same** roots `Vm.collect` marks — both drive one
      `Vm.forEachRootHeader` helper, so capture and GC can never drift. The CLI's
      `--emit-keyframe <file>` drops a snapshot after a run (independent of
      tracing). Round-trip is proven byte/struct-exact for a hand-built edge corpus
      (empty + array/hash tables, NUL/high-byte strings, 0- and N-upvalue closures,
      open vs closed upvalue, a self-referential table) and structurally for a
      VM-driven program (globals/closures/upvalues/cycle), and the run-twice
      determinism harness now asserts the **snapshot bytes** are byte-identical
      across two independent VMs. Surfacing this latent property fixed a real
      determinism bug: `table.ValueContext.hash` hashed a heap key by its
      *address*, so hash-part iteration order (hence serialized `entries` order)
      varied run-to-run; it now hashes by stable `GcHeader.id` (see
      `02-determinism.md` §"Table iteration order").

- [x] **Keyframe snapshot RESTORE (Phase 7 v2 / F2b — round-trip into a live VM).**
      `keyframeser.restore`/`restoreSnapshot` decode a `SnapshotFile` and rebuild
      the heap graph into a fresh, **bare** VM (`Vm.initBare` — an empty heap, no
      auto-seeded globals/natives, so restore owns every id). Reconstruction is
      two-pass: pass 1 creates each object shell (string ⇒ re-intern; table; closure
      with its `proto` resolved by walking the program's prototype tree, since
      `Proto.id` has no runtime registry; upvalue; native rebound by name through
      the shared `interp.base_natives` registry) and records `id → *GcHeader`; pass
      2 wires every edge (table array + hash, closure upvalues, upvalue values) so
      cycles and forward refs resolve; then globals + stack + frames + open upvalues
      are rebound. **Ids are preserved exactly** via a restore-only `gc.Heap`
      seam (`linkRestored` + `adoptNextId`): because table hash-iteration order is
      keyed on `GcHeader.id`, re-stamping the original ids makes a restored VM
      re-serialize **byte-for-byte identical** to the snapshot it came from — the
      verification headline (`encodeSnapshot ∘ restore == identity`, proven over the
      VM-driven corpus + the run-twice determinism programs). Plus restore-specific
      structural assertions, a full restore of the hand-built edge corpus (cycles,
      open+closed upvalues, 0/N-upvalue closures, non-empty stack/frames/open
      upvalues), and failure-mode tests (`UnresolvedHeapRef` / `UnknownProto` /
      `UnknownNative` / `GlobalsNotATable` / `DuplicateId` / `UnsupportedVersion`).
      A restore-only `Table.restoreEntry` populates the hash part without triggering
      array migration, preserving the captured array/hash split. **Deferred → later:**
      mid-execution capture at a GC safepoint (non-empty stack + OPEN upvalues — the
      restore code already handles these roots, but producing such a snapshot needs
      the safepoint hook) and snapshot→restore→re-execute equivalence (meaningful
      only once a live stack is captured).

### Outstanding

- [~] **Two artifacts, one substrate.** Define **optimizer guard-snapshots**
      (for deopt) and **debugger keyframes + effect log** (for replay) as
      distinct record types that share encoding — *not* one fused artifact. The
      keyframe half exists end-to-end (F2a serializer + F2b restore, above):
      `SnapshotFile` is a distinct record family with its own version word, sharing
      the trace artifact's generated codec, and round-trips losslessly through a
      live VM. Guard-snapshots and the effect log are still outstanding.
- [ ] **Event model.** Minimum event set: event id, bytecode PC, frame id,
      register writes, heap writes, allocation ids, guard snapshots, side exits,
      host/external calls, nondeterministic inputs (effect records), GC events,
      checkpoint/keyframe indexes.
- [ ] **Effect record format** — inputs + outputs sufficient to replay without
      re-running the effect (shared with `02-determinism.md`).
- [x] **Keyframe format** — VM-state snapshot for replay restore (shares code
      with guard snapshots, `01-trace-lifecycle.md`). Both halves are done: capture
      (F2a `SnapshotFile`) and restore into a live VM (F2b `keyframeser.restore`),
      proven inverse by a byte-identical re-snapshot. What remains for *replay* is
      not the keyframe itself but the effect log it interleaves with (below) and a
      mid-execution capture point (a non-empty stack to re-execute forward from).
- [ ] **Recording modes.** Full-replay, bounded ring-buffer window, keyframe-only,
      off. Define defaults and per-mode capture filters (bytecode events / heap
      writes / host calls / allocations / source lines).
- [ ] **Volume budget.** Back-of-envelope bytes/step × steps/sec; keyframe
      interval; hard size limits and graceful truncation semantics. **Log what is
      truncated** (no silent caps).
- [ ] **File layout.** Chunked / mmap-friendly with a seek index; string / value
      interning; trace header (hash seed, FP mode, env snapshot, schema version).
- [~] **binschema schema + generated codec.** Done for the **trace artifact**:
      `schema/trace.json` (in the lune repo) + **generated, vendored** codecs for
      **both** targets — Zig encoder/decoder under `src/gen/` and the TS decoder
      under `viz/src/gen/`, emitted from the one schema by
      `tools/regen-trace-schema.sh`. Cross-language agreement is proven by a
      committed fixture decoded under `viz` `bun test`. The schema now also covers
      the **keyframe** record family (F2a `SnapshotFile`, above) — the Zig codec is
      regenerated and vendored, and the TS codec under `viz/src/gen/` is too (a
      cross-language snapshot fixture trails F2a). Still outstanding: extending the
      schema to the rest of the event model below (effects / guard-snapshots).
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

Values serialise straight from the self-describing tagged slot. Heap objects in a
keyframe / `HeapWrite` / `Alloc` reference each other by the stable, deterministic
`GcHeader.id` (assigned at allocation, `src/gc.zig`) — **never** an address — so a
keyframe's object graph is reproducible and replay-stable. (That identity is
already live: it is what `print` of a heap object renders, see
`02-determinism.md`.)

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
