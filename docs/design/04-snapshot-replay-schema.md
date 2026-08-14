# lune — Snapshot & Replay Schema

Status: partial — trace artifact + keyframe capture/restore/resume (F2a+F2b+F2c) + effect log (F2d: clock, F2e: random seed) + in-browser replay-to-k driver (Phase 7 v8) landed; keyframe now **v7** (v5 = H-2 `next_obj_id`; v7 = doc 18 slot-0 array part: positional 0-based array serialization + restore-time validation and lane rebuild); guard-snapshots outstanding
Owner: Bart
Last updated: 2026-06-15

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
      keyframe }`; `Keyframe { globals_id, string_metatable_id, next_obj_id,
      objects[], stack[], frames[], open_upvalues[], loaded_chunks[] }`;
      `HeapObject { id, obj_type, body }` — a flat array keyed
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
      walk is seeded from one shared `Vm.forEachRootHeader` helper — the same root
      inventory `Vm.collect` marks, with **one intentional policy split** (its
      `RootKind` param): trace-constant roots (`trace.cache[].consts`,
      `trace.rec.consts`) are `.gc`-only GC-liveness roots and are **excluded from
      the `.snapshot` semantic-root walk** (doc 17 H-2 / G-2), so a heap object
      reachable only via a cached trace — transient, tiering-dependent JIT state —
      never lands in the snapshot and capture bytes are identical regardless of what
      the JIT recorded. Every other root is shared, so capture and GC can't drift
      on semantic state. The CLI's
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
      `02-determinism.md` §"Table iteration order"). A second, subtler hazard was
      later closed: even with id-keyed *hashes*, `std.HashMap`'s internal **slot
      layout is insertion-order-sensitive** under a probe collision, so a restored
      table (rebuilt by re-inserting entries one-by-one) could iterate in a
      different raw order than the original — making `encodeSnapshot ∘ restore`
      not byte-identical. The serializer now emits a table's hash part in a
      **canonical key order** (`keyframeser.sortedHashEntries`: heap keys by id,
      others by tag+payload bits — a strict total order over normalized keys),
      applied to BOTH the `entries` array and the BFS child-discovery walk. This
      makes the snapshot bytes a function of the key *set* and ids alone, never of
      insertion history or `std.HashMap`'s implementation across Zig versions.

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
      VM-driven corpus + the run-twice determinism programs). **v5 (H-2):** the heap's
      monotonic allocation counter `next_obj_id` is now **serialized** and restored
      verbatim, not reconstructed as `max(id) + 1`. The old reconstruction was only
      correct when a run left **no pre-cut garbage** (an object allocated then GC'd
      before the cut bumps the counter but leaves no `objects` entry, so `max(id)+1`
      drifts the counter low → every subsequent id diverges, and ids are observable
      via table/`pairs` order). Restore validates `next_obj_id >= max(id)+1` (a live
      object holding an unallocated id is corrupt → `NextObjIdBelowObjects`).
      **v7 (doc 18):** a `HeapTable.array` is positional **0-based** — entry `i`
      IS logical key / physical slot `i`, holes (incl. the ubiquitous slot-0
      hole) ride in-band as nils; restore appends from slot 0, then runs a
      **bulk lane rebuild** (repack + freeze a homogeneous narrow run, exactly
      rehash's one-shot commit — a leading hole would otherwise defeat append's
      eager lane commit and leave restored sieves untraceable / deflated grids
      un-reinflatable), and rejects any hash entry whose normalized integer key
      is array-covered (`ArrayResidentKeyInHash`, incl. float-spelled `0.0` —
      such an entry would be permanently shadowed). This
      also unblocks the later JIT-under-snapshot work (doc 17 H-2): dropping a
      trace-only object from the snapshot only stays determinism-safe once the id
      timeline is independent of *which* objects survive. Plus restore-specific
      structural assertions, a full restore of the hand-built edge corpus (cycles,
      open+closed upvalues, 0/N-upvalue closures, non-empty stack/frames/open
      upvalues), and failure-mode tests (`UnresolvedHeapRef` / `UnknownProto` /
      `UnknownNative` / `GlobalsNotATable` / `DuplicateId` / `UnsupportedVersion`).
      A restore-only `Table.restoreEntry` populates the hash part without triggering
      array migration, preserving the captured array/hash split. This stays correct
      now that `Table.set` runs a Lua-style **rehash** (array-part sizing — a dense
      run of integer keys like nsieve's `t[2..m]` migrates out of the hash into the
      contiguous array part): the rehash fires **only from `set`**, never on the
      restore path, so a captured split — array holes included — is still reproduced
      verbatim by `restoreEntry` + direct array append, and `encodeSnapshot ∘ restore`
      remains byte-identical (the round-trip corpus includes a sieve-shaped table).
      F2b proved the inverse property only for a **final-state** snapshot (empty
      stack/frames); the mid-execution case is F2c, below.

- [x] **Mid-execution capture + RESUME (Phase 7 v2 / F2c).** The interpreter's
      host-stack recursion (`execClosure`→`doCall`→`execClosure`) became an explicit
      **call-stack array** (`Vm.frames: [N]CallFrame`) driven by one iterative loop
      (`Vm.exec`), so a frame's whole cursor — executing closure, `pc`, register-window
      `base`, and return-wiring (`ret_dest`/`ret_count`) — is reified data, not host
      locals. A loop-top **safepoint** (instruction boundary, never mid-opcode/native)
      can now park `pc` into the top frame and return `.suspended` (`Vm.suspend_ctl`
      gates on a free-running `safepoint_seq` and a minimum depth, so a test/debugger
      can cut mid-loop *or* inside a nested call). The keyframe `FrameRef` carries the
      cursor (`pc/base/ret_dest/ret_count`); capture emits `frames[0..depth]`, and
      restore rebuilds them with a **contiguity guard** (`base[i+1] == base[i] +
      num_registers`, `base[0] == 0`) → `FrameWindowMismatch` on a torn window.
      **Resume re-executes forward from the restored cut**, and `out_before ++
      out_after` equals the uninterrupted output `F`, with the resumed final-state
      snapshot byte-identical to the reference `Sf`. The subtle enabler: a restored
      VM borrows the original program image (`chunk.proto`), whose string constants
      live in the *compile-time* heap — a **different heap** than the restored one.
      That resolves only because heap identity is by stable `GcHeader.id` (not by
      address): `value.zig` `eql` now compares heap refs by `id`, matching the
      already-id-based table hash, so a borrowed proto constant and its restored twin
      (same id, different address) compare equal and a resumed `get_global`/table
      lookup hits. Before this fix, resume failed with `TypeError` (`print` resolved
      to `nil`). Verified by a corpus (nested calls + loops + closure/open-upvalue +
      3-deep stack) replayed at two cuts each, an independent-VM determinism check
      (same cut ⇒ byte-identical mid keyframes), and the `FrameWindowMismatch` failure
      mode. The 8-way `expectProgram` matrix stays byte-identical — the recursion→loop
      refactor is behaviourally invisible. **Still outstanding for replay:** the
      effect log (F2d) — re-executing *past a nondeterministic input* needs the
      recorded effect fed back.

- [x] **Effect log (Phase 7 v2 / F2d) — the first nondeterministic input.** A
      native can now carry an `effect: ?EffectKind` (null = pure host call like
      `print`; non-null = a nondeterministic input), and the first one — `clock()`,
      the host monotonic clock — lands as `EffectKind.clock`=0, a **stable wire
      enum** whose ordinals must never be renumbered. The VM gained an
      `effect_mode ∈ {off, record, replay}` plus an ordered `effect_log` and a
      `effect_cursor`: `record` calls the effect and appends `{kind, result}`;
      `replay` does **not** call it, feeding back the next logged result in call
      order (`EffectLogExhausted` past the end, `EffectKindMismatch` on a log/site
      disagreement); `off` (default) is the pre-F2d behaviour. The wire format is a
      **third record family** with its own version word, sharing the binschema
      encoding: `Effect { kind: uint8, result: SnapValue }` + `EffectFile { version,
      effects[] }`, serialized by `src/effectser.zig` (mirroring
      `traceser`/`keyframeser`). `result` reuses `SnapValue` but is **non-heap**
      today — `clock` returns an int, and a standalone effect log carries no heap
      graph, so a heap result has no id to resolve against (rejected as
      `UnsupportedEffectResult`). Proven by: an `effectser` round-trip corpus
      (empty/single/multi, int+float, stable-bytes, wrong-version, unknown-kind,
      heap-ref-rejected); an in-VM record→replay headline (replay reproduces the
      recorded output byte-for-byte while a *fresh record* differs — the captured
      nondeterminism); the `EffectLogExhausted` short-log failure mode; and the
      **combined demo** that ties F2c+F2d together — restore a *mid-run* keyframe of
      a clock()-using program **and** replay its effect log from the cut cursor →
      `out_before ++ out_after` equals the uninterrupted output. The keyframe
      deliberately does **not** carry the log/cursor: that is replay-driver state
      marshalled alongside the snapshot (keyframe = heap+stack+frames; cursor = where
      in the log the cut fell). CLI: `--emit-effects <file>` writes the log after a
      run (mirrors `--emit-keyframe`); a user-facing replay driver trails the
      visualiser work.
- [x] **Seed-based randomness (Phase 7 v2 / F2e) — the second input.** `random()`
      adds `EffectKind.random_seed`=1 (a new wire ordinal — append-only, the `uint8`
      `kind` needs no schema/codec change). It is **seed-based**, not per-call: the
      PRNG (`std.Random.Xoshiro256`) lives inside the VM (`Vm.rng`), and the single
      recorded effect is a `u64` **seed**, acquired lazily on the first `random()`
      call and logged **once**, from which the whole draw stream reproduces on
      replay. So `random()` registers as a *pure* native (`effect = null` — dispatch
      calls it directly); only the seed crosses the record/replay boundary, *inside*
      `nativeRandom`. The seed rides the existing **non-heap** result path unchanged:
      it is carried as `Value.int(@bitCast(seed))` — an int the log already encodes —
      so a multi-draw program logs exactly one `Effect`. Proven by: an `effectser`
      round-trip case for the new ordinal; an in-VM record→replay headline (one
      logged seed reproduces a three-draw stream byte-for-byte while two distinct
      seeds differ); the `EffectLogExhausted` empty-log failure mode; a
      `RandomUnavailable` no-source case; and a `[0,1)` range check. Cross-engine:
      native and wasm share the stdlib PRNG, so a given seed yields the identical
      stream on both — the differential validator labels a `random()` program's
      one-effect divergence *expected*, exactly as for `clock()`.
- [x] **In-browser replay driver (Phase 7 v8) — the user-facing replay surface.**
      The replay driver that "trails the visualiser work" in the F2d note now
      exists, in the browser, as a **stateless replay-to-k** model rather than a
      restore-from-keyframe one. The record run reports a total safepoint count
      and a **safepoint-line index** — a `u32`-per-safepoint array
      (`safepoint_lines[k-1]` = the source line of the instruction pending at
      safepoint *k*), recorded only under a gated `Vm.record_safepoint_lines`
      flag so tier-0 pays nothing by default. To show step *k*, the wasm export
      `lune_replay(src, effects, k)` re-compiles, sets `effect_mode = .replay`
      with the decoded effect blob, runs a **pure tier-0** pass (trace disabled,
      so each loop iteration is its own safepoint) with
      `suspend_ctl.after_safepoints = k`, and on suspend returns the keyframe
      (decoded by the same generated `SnapshotFileDecoder` the inspector uses) +
      stdout-so-far + the pending line/span + a deepest-first backtrace (the
      `Vm.describeFault` frame-walk was factored into a reusable
      `backtraceFrames`). Re-execution *is* the reconstruction — no keyframe is
      restored — so the keyframe still carries no log/cursor, consistent with the
      "two artifacts" split. A `safepoint_count`/`safepoint_capped` pair surfaces
      the safepoint cap (bounded, never silent). The line index is **in-memory /
      ABI-only**: it rides the hand-rolled wasm `Result`/`ReplayResult` extern
      structs, not the binschema wire format, so no schema change was needed.
- [x] **Trace execution log (Phase 7) — the fourth record family, and the first
      pure *observation* log.** The JIT-trace iteration animation needed a record of
      how a cached trace actually *ran* — which the tier-1a executor
      (`irinterp.execute`) discarded, returning only a `completed` count. So
      `irinterp.zig` is comptime-specialized into
      `executeImpl(comptime record: bool, …)`: `execute` (record=false) compiles
      byte-identical to before (the JIT fast path pays nothing), while
      `executeTraced` drives an `ExecLogRecorder` (`src/execlog.zig`). For **every
      trace entry / exit ramp** (one `TraceEntry` per `execute` call) it records the
      per-iteration `ExecEvent` stream — `value` (an SSA result landed), `guard_pass`,
      `commit` (an iteration looped) — terminated by an `exit` event naming the
      faulting ref and the `ExitKind` (guard / arith / clean). The per-entry detail is
      capped (`exec_log_max_iters`, default 16 — the exit is always kept and
      `iterations` stays exact) and entries-per-trace are capped
      (`exec_log_max_entries`, default 64); both surface `capped`/`entries_capped`
      flags, never silent. The wire format is the **fourth record family**:
      `ExecEvent { kind: uint8, ref: uint32, value: EffectResult }` →
      `TraceEntry { iterations, exit_ref, exit_kind, capped, events[] }` →
      `TraceExecLog { trace_id, entries_capped, entries[] }` → `ExecLogFile { version,
      logs[] }`, serialized by `src/execlogser.zig` (mirroring the three siblings) at
      `exec_log_format_version` 1. It **reuses `EffectResult`** for event values — trace
      IR produces only scalars at this phase (no heap/table ops; those abort tracing),
      so the same scalar+inline-string union the effect log uses fits exactly, sharing
      `effectser.toEffectResult`/`fromEffectResult`. Unlike its siblings it is an
      **observation** log — nothing replays it back; `trace_id` is the trace-cache
      index, which is also the visualiser's trace-selection key, so the selected trace
      maps straight to its log. It rides Zig → wasm (`exec_log` Buf appended at the
      `Result` tail, offsets stable) → TS like the others, and the visualiser's
      `TraceView` animates the flattened event stream over the IR table. Proven by:
      an `execlogser` round-trip corpus (every event kind, both exit kinds, the cap
      flags; empty; wrong-version; unknown-event-kind), four `interp`-level recorder
      tests (hot-loop capture, detail cap, entry cap, observation-only parity:
      record=on/off agree on `regs`/`completed`), and viz `bun test` end-to-end (the
      default hot loop yields a decodable log with value/guard/commit + a terminal
      exit; a non-looping program yields zero logs).

### Outstanding

- [~] **Two artifacts, one substrate.** Define **optimizer guard-snapshots**
      (for deopt) and **debugger keyframes + effect log** (for replay) as
      distinct record types that share encoding — *not* one fused artifact. The
      keyframe half exists end-to-end (F2a serializer + F2b restore, above):
      `SnapshotFile` is a distinct record family with its own version word, sharing
      the trace artifact's generated codec, and round-trips losslessly through a
      live VM. **The effect log is now a third such family** (F2d `EffectFile`, its
      own version word, same shared encoding), and the **trace execution log a
      fourth** (Phase 7 `ExecLogFile` — the first pure *observation* log, above).
      Only optimizer guard-snapshots remain outstanding.
- [ ] **Event model.** Minimum event set: event id, bytecode PC, frame id,
      register writes, heap writes, allocation ids, guard snapshots, side exits,
      host/external calls, nondeterministic inputs (effect records), GC events,
      checkpoint/keyframe indexes.
- [x] **Effect record format** — inputs + outputs sufficient to replay without
      re-running the effect (shared with `02-determinism.md`). Landed (F2d):
      `Effect { kind, result }` + `EffectFile { version, effects[] }`, consumed in
      call order on replay. `clock()` has no inputs, so kind + result suffice;
      effect *args* (inputs) are a later increment when an effect that takes them
      lands.
- [x] **Keyframe format** — VM-state snapshot for replay restore (shares code
      with guard snapshots, `01-trace-lifecycle.md`). All three halves are done:
      capture (F2a `SnapshotFile`), restore into a live VM (F2b
      `keyframeser.restore`), and **mid-execution capture + resume-to-equivalence**
      (F2c — a non-empty live stack/frames are captured at a safepoint and
      re-executed forward to the same output and final state). The **effect log**
      it interleaves with also landed (F2d, above), so re-execution past a
      nondeterministic input (`clock()`) is now reproducible — the combined
      keyframe+effect replay demo closes the loop.
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
      cross-language snapshot fixture trails F2a). It now also covers the **effect**
      record family (F2d `Effect`/`EffectFile`), Zig + TS codecs regenerated and
      vendored. It now also covers the **trace execution-log** record family
      (Phase 7 `ExecEvent`/`TraceEntry`/`TraceExecLog`/`ExecLogFile`, reusing
      `EffectResult` — two array-nesting levels deep, logs→entries→events), Zig + TS
      codecs regenerated and vendored. Still outstanding: extending the schema to
      optimizer guard-snapshots.
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

- One binschema schema, multiple record families (guard-snapshots, keyframes,
  effects, and the trace execution log), shared primitives (the self-describing
  16-byte tagged value → discriminated union; the scalar `EffectResult` reused by
  the effect and execution logs).
- Bounded, seekable, interned trace files; megabyte-scale recordings via
  effects + keyframes (not gigabyte step logs).
- A generated TS decoder so the SolidJS visualiser does zero hand-parsing.

## Non-goals

- A general-purpose serialization framework (binschema already is that).
- Forcing the optimizer to consume the full debug log (decoupled by design —
  `00-architecture.md` §Observability).

## Event model (sketch — to be made concrete)

Discriminated union over record kinds (binschema's core feature):

- `Effect{ kind, result }` — a recorded nondeterministic input (F2d, **landed**:
  `kind` is a stable `EffectKind` ordinal — `clock`=0 (F2d), `random_seed`=1 (F2e),
  `getenv`=2, `argc`=3, `argv`=4 (env/args). `result` is an **`EffectResult`** —
  *not* a `SnapValue`. `EffectResult` is a discriminated union over its **own** tag
  space (nil=0/bool=1/int=2/float=3/string=4) reusing the `Const*` leaves, where the
  `string` arm carries **inline length-prefixed bytes**. It is deliberately separate
  from `SnapValue` (whose tag mirrors `Value.Tag`, so a string there is a `heap_ref`
  resolved against a keyframe's idmap): a standalone effect log has no heap graph, so
  `getenv`/`argv` string results must travel inline and are re-interned into the
  replaying VM's heap on decode. effect *inputs* are added when the first effect that
  takes them lands — none of these has any). Note `random_seed` is logged **once per
  run** (the PRNG seed), not per `random()` call; the env/args effects log **once per
  call** like `clock`. The effect-log wire format is at **version 2** (v1 was
  scalars-only, before the inline-string `EffectResult`).
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
