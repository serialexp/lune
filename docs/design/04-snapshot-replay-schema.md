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
- [~] **binschema schema + generated codec.** Done for the **trace artifact**:
      `schema/trace.json` (in the lune repo) + **generated, vendored** codecs for
      **both** targets — Zig encoder/decoder under `src/gen/` and the TS decoder
      under `viz/src/gen/`, emitted from the one schema by
      `tools/regen-trace-schema.sh`. Cross-language agreement is proven by a
      committed fixture decoded under `viz` `bun test`. Still outstanding:
      extending the schema to the full event model below (effects / keyframes /
      guard-snapshots).
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
