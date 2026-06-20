# lune — Determinism & the Host-Effect Boundary

Status: partial — host-effect boundary + record/replay (clock F2d, random F2e) + keyframe capture/restore/resume landed; record-once/replay-to-k driver now in the browser (Phase 7 v8); cross-platform-FP guarantee + guard-snapshots outstanding
Owner: Bart
Last updated: 2026-06-15

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
- [x] **Transparent trace recording** (Phase 5a, `src/trace.zig`). The recorder
      observes tier-0 — it reads pre-execution operands and emits trace IR — but
      tier-0 still executes every instruction, so recording **cannot change a
      program's result**: it is invisible the same way GC is. A host (`native`)
      call is already treated as a **trace barrier** (the recorder aborts with
      `host_barrier`), matching the effect-boundary policy above — when host-effect
      recording lands, that abort becomes the point an effect record is emitted.
- [x] **Transparent trace *execution*** (Phase 6a, `src/irinterp.zig`). The
      tier-1a IR-interpreter now *runs* hot traces, but it remains output-invariant:
      it calls the **same `arith.zig`** as tier-0 (byte-identical numerics) and
      deopts to tier-0 on any guard miss, re-running the partial iteration (sound
      because a committed trace's only side effect is a deopt-replay-idempotent
      packed-array `astore` — recordable only when its value depends on no prior
      packed read, C1; see `05-native-codegen.md` §Phase B and the heap-determinism
      oracle). So a program prints the same
      bytes whether a loop runs in tier-0 or tier-1a — the same "run with or without
      for comparison" property, now extended past recording to execution. The
      evidence is the **extended** `expectProgram` matrix in `src/interp.zig`: every
      end-to-end program runs in every {`gc_stress` off/on} × {off, record-only,
      **record+execute**} combination (8-way once Phase 6b adds the optimizer axis —
      see below) and must print **byte-identical** output. An executor divergence
      (wrong arith, missed guard, bad deopt, exit-store error) surfaces as a
      mismatch there.
- [x] **Optimized traces are output-invariant too (Phase 6b).** The trace
      optimizer (`src/tropt.zig`: constant folding, CSE, dead-code elimination,
      run once at commit) rewrites a trace's IR but **cannot change what it
      prints**. Folding computes with the *same* `arith.zig` evaluator the
      executor uses (byte-identical bits, by construction), and a fold that would
      error is left as a runtime op so tier-0 still re-raises it; only
      always-pass and exact-duplicate guards are dropped, so the optimized trace
      never deopts later than the raw one. The evidence is that the
      `expectProgram` matrix is now **8-way** — {`gc_stress` off/on} × {off,
      record-only, record+execute-**noopt**, record+execute-**opt**} — so
      *optimized output == unoptimized output == tier-0* for every e2e program; a
      seeded differential fuzz (`src/interp.zig`) adds 64 random integer loops
      under the same three execution modes. The optimizer is a transparent
      rewrite, exactly like recording and execution before it.
- [x] **Cross-engine differential validation (Phase 7 v3).** The strongest
      determinism check we have: the *same* source runs through two **different
      engines** — the in-browser **wasm32** VM (`src/wasm_entry.zig`) and the
      **native** binary — and their artifacts are compared **byte-for-byte**
      (`viz/src/diff.ts`, driven from the viz UI's "Run both + diff"; the native
      side is a dev-server `POST /run` subprocess). Two independently-built engines
      agreeing is far stronger evidence than two native runs agreeing: it would
      catch any place where output secretly depended on pointer width, endianness,
      struct layout, or an unlogged ambient input, because those differ between
      wasm and x86-64. **Empirical result:** for a program with *zero recorded
      effects*, the keyframe, effect log, trace, and stdout are **byte-identical**
      across both engines — including basic IEEE-754 float arithmetic (`+`, `-`,
      `*`, `/`), which is deterministic across the two targets. This is also the
      first end-to-end proof that the **clock-as-injected-effect** refactor works
      as intended: wasm has *no* clock syscall, so `clock()` is forced through the
      injected `ClockSource` (a JS `host_now_ns` import); the two engines' clock
      reads differ, and that divergence appears **only** in the effect log (and
      heap state derived from it), labelled *expected*, never in the trace IR or in
      clock-independent output. The validator's byte-identity assertion is scoped
      to deterministic programs; a program that records an effect is verified by
      *replay*, not by this record-vs-record comparison. The current
      implementation is byte-level (decode-free); a *structural* divergence view is
      deferred behind a generated-codec bug (see `TODO.md`).

### Outstanding

- [~] **Effect taxonomy.** Enumerate every nondeterministic source and assign
      each a policy: *forbid in deterministic mode*, *virtualise*, or *log
      inputs/outputs*. **The first input now exists** (F2d): `clock()` — the host
      monotonic clock — is the canonical *log-outputs* effect, carried as a stable
      wire enum `interp.EffectKind` (clock=0). The table below is the full plan;
      `clock` is the first row made real.
- [~] **Host-effect *recording*** — the seam exists (Phase 3, above). **F2d makes
      it real for the first input.** A native may now carry an `effect: ?EffectKind`
      (null = pure host call like `print`; non-null = a nondeterministic input). The
      VM has an `effect_mode ∈ {off, record, replay}`: `record` calls the effect and
      appends `{kind, result}` to an ordered `effect_log`; `replay` does **not** call
      it — it feeds back the next logged result in call order (`EffectLogExhausted`
      past the end, `EffectKindMismatch` if the log disagrees with the call site);
      `off` (default) calls normally, so every pre-F2d test is unaffected. A host
      call was already a trace barrier (a native aborts recording), so the effect
      seam never touches the JIT.
- [x] **Effect record format** — inputs + outputs sufficient to replay without
      re-executing the effect. Landed (F2d) as a third record family in the trace
      schema (`04-snapshot-replay-schema.md`): `Effect { kind, result }` +
      `EffectFile { version, effects[] }`, with its own version word, serialized by
      `src/effectser.zig` (mirroring `traceser`/`keyframeser`). `clock()` has no
      inputs, so kind + result fully describe it; effect *args* are a later
      increment. `result` reuses `SnapValue` but is **non-heap** today (clock returns
      an int) — a standalone effect log carries no heap graph, so a heap result has
      no id to resolve against (`UnsupportedEffectResult`). F2e's `random_seed` rides
      the same non-heap path: the `u64` seed is carried as `Value.int(@bitCast(seed))`,
      so a new effect kind cost **zero** wire/codec change (the kind is a `uint8`
      ordinal; the result is an int the log already serializes).
- [x] **Hash seed fixed.** String/table hashing uses Wyhash with a **fixed seed
      0** (`src/string.zig`, `src/table.zig` `ValueContext`), not a per-run random
      seed — so hashing is already reproducible run-to-run. (A trace *header*
      recording the seed is moot until a seed is ever randomised; revisit if that
      changes.)
- [x] **Heap-object identity is deterministic.** Every heap object carries a
      stable, monotonic `GcHeader.id` stamped at allocation by the heap's single
      link-in chokepoint (`src/gc.zig` `link`), and observable rendering
      (`io.writeValue` for `print` of a table/function) shows that id, **never**
      `@intFromPtr`. So no ASLR address leaks into a program's output. This id is
      also the identity a keyframe's heap graph keys on
      (`01-trace-lifecycle.md`, `04-snapshot-replay-schema.md`). **Identity by id
      is now total**, not just for rendering/hashing: `value.zig` `eql` compares
      two heap refs by `GcHeader.id` rather than address (F2c). Within one heap
      this is equivalent — interning makes equal content the same object, and ids
      are unique and never reused — but it is **load-bearing across heaps for
      replay**: a restored keyframe re-executes against the original program image,
      whose proto string constants live in the compile-time heap while their
      restored twins live in the new heap (same preserved id, different address).
      Address equality would make a resumed `get_global`/table lookup miss its own
      restored key; id equality resolves it, and it aligns `eql` with the
      already-id-based `table.ValueContext.hash`.
- [~] **Table iteration order.** Address-independent and deterministic
      (constrains the table/shape model). **The address dependency is now fixed:**
      `table.ValueContext.hash` hashes a heap key by its stable `GcHeader.id`, not
      its `payload.bits` (the ASLR-dependent address). Previously the hash-part's
      slot layout — hence its iteration order — varied run-to-run; that divergence
      was invisible to a program (no `pairs`/`next`) but became observable the
      moment iteration order was *serialized*, which is exactly what a keyframe
      snapshot does. The keyframe serializer (F2a) surfaced it, and the run-twice
      harness now guards it (byte-identical snapshot bytes — see Replay
      verification). A follow-on hazard at the *serialization* layer was also
      closed: id-keyed hashing fixes which keys collide, but `std.HashMap`'s raw
      slot order under a collision still depends on **insertion order**, so a
      restored table (rebuilt by one-by-one re-insertion) could serialize in a
      different order than its original. The keyframe serializer now emits a
      table's hash part in a **canonical key order** (`keyframeser`
      `sortedHashEntries`/`keyLessThan`: heap keys by id, others by tag+payload
      bits — a strict total order over normalized keys) at both serialization
      sites, so snapshot bytes are a function of the key *set* and ids alone, never
      of insertion history or `std.HashMap`'s layout. Still not actionable at the
      *program* level until a `pairs`/`next` iterator exists; the deterministic
      ordering rule lands fully with that iterator.
- [~] **Floating-point determinism.** FP **mode is pinned**: every float-producing
      function in `src/arith.zig` sets `@setFloatMode(.strict)`, forbidding
      contraction/reassociation regardless of build mode (Zig's default is already
      strict; this guards it explicitly). **Tier-1b (native x86-64) preserves this
      bit-for-bit** (Phase D): float `add`/`sub`/`mul`/`div` lower to scalar SSE2
      (`addsd`/`subsd`/`mulsd`/`divsd`) — the *same* instructions Zig's strict mode
      emits, with no x87 80-bit intermediates and no FMA contraction (both
      structurally absent), so the JIT's result equals the tier-1a oracle's to the
      last bit, including ±inf and the `0.0/0.0` quiet-NaN payload. Int→float
      promotion uses `cvtsi2sd` (round-to-nearest, ties-to-even), which matches
      `@floatFromInt` exactly. Float comparisons use `ucomisd` with NaN-aware flag
      combining that mirrors `value.compareNumeric` (NaN ⇒ lt/le/eq false, ne true);
      *mixed* int/float compares deliberately stay on tier-1a, where the oracle
      compares them exactly (`compareIntFloat`) rather than through a lossy
      cvtsi2sd. Verified by the differential oracle (`expectMatch`, exact payload
      bits) and end-to-end against LuaJIT (`bench/pi_leibniz.lua`). Still open: NaN
      payload canonicalisation, signed-zero policy, and **cross-platform**
      bit-identity (same-machine only for now — see Open questions).
- [x] **GC observability.** ✅ Decided + implemented (Phase 4). The v1 collector
      (stop-the-world mark-sweep, `03-gc-memory.md`) has **no finalizers, weak
      refs, or ephemerons** — nothing a program can observe to react to collection
      — and runs only at fixed safepoints (the interpreter's dispatch-loop top).
      So *when* a collection happens cannot change a program's result; it is
      invisible. The Phase 3 programs run identically with the collector forced at
      every safepoint (`gc_stress`), which is the evidence. (If a generational
      upgrade later adds GC timing that a trace could observe, it must be scheduled
      deterministically and recorded.)
- [x] **Time / randomness / environment** routed through the effect boundary
      (no raw access). **Time is** (F2d): `clock()` reads the host monotonic
      clock and is recorded in `record` mode, fed back in `replay`, never reaching a
      script as raw access. **Randomness is** (F2e): `random()` returns a float in
      `[0,1)` drawn from a PRNG that lives *inside* the VM (`Vm.rng`). Unlike the
      clock — which logs a value *per call* — randomness is **seed-based**: the one
      nondeterministic input is a single `u64` seed, acquired lazily on the first
      `random()` call and recorded **once** as `EffectKind.random_seed`=1; the PRNG
      reproduces the entire draw stream from it on replay, so the effect log holds
      exactly one entry regardless of how many draws a run makes. This pins
      **`std.Random.Xoshiro256` seeded by `.init(seed)`, drawn via `float(f64)`** as
      a spec commitment (the algorithm is referenced by concrete name, not
      `DefaultPrng`, so a future stdlib swap can't silently change the stream); a
      given seed yields an identical stream on native and wasm, so the cross-engine
      differential validator gets randomness for free, and two *fresh* record runs
      differ (different seeds) — that divergence being exactly the nondeterminism
      captured, labelled expected just as `clock()`'s is.
      **Environment/args are** (this increment): three flat builtins ride the same
      boundary — `getenv(name)`→`string|nil` (`EffectKind.getenv`=2), `argc()`→`int`
      (`argc`=3), and `argv(i)`→`string|nil` (`argv`=4). Like `clock()` they log a
      value *per call*; unlike it, two of them return **heap strings**, which forced
      two design choices. (1) The standalone effect log has no heap graph, so a string
      result is carried **inline** (length-prefixed bytes) and re-interned into the
      caller's heap on decode (`effectser.decodeFile` now takes a `*Heap`). The wire
      result type is a dedicated `EffectResult` union with its **own** tag space
      (nil/bool/int/float/**string**), deliberately *not* a `SnapValue` (whose tag
      mirrors `Value.Tag`, where a string is a `heap_ref`); keeping them separate
      makes the effect log's law — "scalars + inline strings, never heap refs" —
      explicit and avoids a dead inline-string branch in the keyframe path. This bumps
      `effect_format_version` 1→2. (2) A string result parked in the `effect_log`
      between the native returning it and serialization (record) or feed-back (replay)
      is otherwise unreferenced, so `forEachRootHeader` now roots `effect_log` heap
      results — without it a safepoint collection mid-run would de-intern and free the
      string. Empty-vs-unset is preserved: a set-but-empty var returns `""` (a real
      heap string), a missing one returns `nil`. The host seam mirrors clock/random —
      a `HostEnv` source injected in the **record** path only (native CLI: real
      `std.process` env + captured argv; wasm: a **null** source — browser has no env,
      so `getenv`→nil, `argc`→0, `argv`→nil); replay reads the log and injects no
      source. An `arg` convenience *table* (Lua-style) is left to stdlib — it would
      need a heap table on the wire, whereas these scalars/strings ride the log
      directly.
      The format was deliberately deferred until the first genuine input+output pair
      (vs. output-only `print`) so it was designed against a real effect, not guessed.
- [x] **Runtime compilation replays deterministically** (L-1/L-2/L-3). `load`,
      `loadfile`, and `dofile` compile source *at runtime* into a callable closure —
      a new dynamic proto tree the VM owns (`Vm.loaded_chunks`). This is sound under
      replay on two counts. (1) **Compilation is a pure function of the source
      bytes** — no clock, entropy, or environment — so it is *not* an effect; like
      every native it is a trace barrier, but it logs nothing and recompiles
      identically. A live `load` closure therefore survives keyframe→restore the
      pure way: the keyframe carries each loaded chunk's **source text**
      (`schema.LoadedChunk`), and restore **re-compiles** it in load order
      (`keyframeser.recompileLoadedChunks`) to regenerate byte-identical protos and
      ids, then resolves each `HeapClosure.proto_id` across the static **and** loaded
      trees (`resolveProto`). Same sources recompiled in the same order ⇒ the same id
      space, so a restored closure rebinds to exactly its proto; no new GC machinery
      (protos stay arena-owned and VM-reachable, the tracer's borrowed-proto liveness
      now holds for dynamic protos too). `snapshot_format_version` 3→4. (2) The one
      genuine nondeterministic input is **file content** for `loadfile`/`dofile`: a
      file read is logged as **`EffectKind.file_read`**=5 in record and fed back in
      replay, so replay **never touches disk** (the test detaches the FS entirely and
      still reproduces byte-identical output). The content rides the *same* inline-
      string `EffectResult` path as `getenv`/`argv`, so the new kind cost zero
      wire/codec change — just the enum arm and `effect_format_version` 2→3. The host
      seam mirrors clock/env: an injected `Vm.fs_source` (real disk in the native
      CLI; null/in-memory elsewhere), consulted only in `record`/`off`, never in
      `replay`; no source ⇒ a non-catchable `FsUnavailable`. The path is ordinary
      program data (it need not be recorded); only the content is the effect, and the
      `cannot open <path>` miss message is a deterministic function of the path, not
      the host's errno text, so it replays byte-identically across machines. A
      decode-boundary guard (`effectser.checkResultShape`) rejects a corrupt log
      whose result type contradicts its kind, so a malformed `file_read` entry
      surfaces as a clean `MismatchedEffectResult` at decode rather than a downstream
      unwrap panic.
- [x] **Compiled-in-table version: `unicode_version`** (S-C, doc 06). Unlike the
      effects above, this records no *host* input — it pins a **constant baked into
      the binary** whose content churns between releases: the simple (1:1) case
      table behind `string.upper`/`string.lower`. The active Unicode version
      (16.0.0, packed `major<<16|minor<<8|patch`) is logged once per session as
      **`EffectKind.unicode_version`**=6 at the first case op, then re-asserted on
      replay; a binary built against a *different* table refuses with a fatal,
      uncatchable `UnicodeVersionMismatch` rather than silently producing different
      casing. It rides the scalar-int `EffectResult` path (the `random_seed`
      template), so the only wire change is the enum arm + `resultShapeOf` →
      `.scalar` and `effect_format_version` 3→4. The "once per session" guard is
      *derived, not stored*: the keyframe carries no PRNG/effect-cursor state, so a
      snapshot resume re-scans the consumed effect-log prefix
      (`versionAlreadyConsumed`) for a pre-cut pin instead of needing a
      `snapshot_format_version` bump — proven by the keyframeser resume test.
- [~] **Host-mediated suspension hook.** Reserve "a host effect may suspend its
      caller" so generators / await / tasks can be added later without new
      machinery. **The substrate now exists** (F2c): the interpreter runs on an
      explicit `Vm.frames` call-stack with an iterative `exec` loop, so suspension
      is no longer blocked on host-stack recursion — a safepoint can already park
      the cursor and return `.suspended` (`Vm.suspend_ctl`). What's reserved-but-not-
      built is exposing that to a *host effect* (vs. the current test/debugger cut)
      and the re-entrant resume surface.
- [~] **Replay verification.** Record-then-replay self-check asserting identical
      observable behaviour. **Landed in its honest current form** (`src/interp.zig`
      "determinism" tests): the VM has no nondeterministic inputs and no keyframes
      yet, so "replay" reduces to a second independent run — and the harness
      asserts two independent VM instances of the same source agree on the printed
      output, the **serialized trace cache** (`traceser.encodeFile`), **and the
      serialized keyframe snapshot** (`keyframeser.encodeSnapshot` — the full
      reachable heap graph + roots), plus an address-leak canary (`print` of a heap
      object renders a small stable id, never an ASLR address). The snapshot
      assertion is the strongest of the three: it serializes the entire heap graph,
      so any address leaking into object identity, edge order, or table iteration
      order diverges the bytes — it is what caught the address-dependent table-key
      hashing above. **Restore (F2b) closes the loop**: a snapshot now decodes back
      into a fresh VM (`keyframeser.restore`) and re-serializes **byte-for-byte
      identical** to the original (`encodeSnapshot ∘ restore == identity`, asserted
      over the corpus). Because the restorer re-stamps each object's *original* id,
      the restored VM reproduces the exact table iteration order — so the
      round-trip is a second, independent guard on the id-keyed hashing above.
      **Mid-execution capture + resume (F2c) extends the spine off the final
      state**: the interpreter now runs on an explicit call-stack array, so a
      safepoint can suspend with a live stack/frames, capture a keyframe, restore
      it into a fresh VM, and **re-execute forward** — `out_before ++ out_after`
      equals the uninterrupted output and the resumed final snapshot is byte-equal
      to the reference. Independent VMs cut at the same safepoint produce
      byte-identical mid keyframes (the determinism property, mid-flight).
      **The effect log (F2d) closes it into *true* keyframe+effect replay**: with a
      nondeterministic input (`clock()`) in hand, a `record` run logs the inputs and
      a `replay` run feeds them back instead of re-calling the clock — so a
      clock()-using program replays to byte-identical output even though a third
      *fresh record* run differs (that difference being exactly the nondeterminism
      now captured). The headline test ties both halves together: restore a *mid-run*
      keyframe of a clock()-using program **and** replay its effect log from the cut
      cursor → `out_before ++ out_after` equals the uninterrupted output. The
      keyframe deliberately does **not** carry the effect log/cursor — that is
      replay-driver state marshalled *alongside* the snapshot (the keyframe is heap +
      stack + frames; the cursor is where in the log the cut fell).
      **Phase 7 v8 puts a record-once / replay-to-k driver in the browser**, the
      first *user-facing* consumer of this spine. The initial run records the
      effect log once; to show the program at step *k* the visualiser re-runs from
      scratch with the suspend control set to the k-th instruction-boundary
      safepoint (`lune_replay`), restoring nothing — re-execution *is* the
      reconstruction, and feeding the recorded effects back makes it reproducible.
      This makes the determinism property directly observable: replay to the same
      *k* yields byte-identical state every scrub, and a `clock()`/`random()`
      program shows the *same* values at the same index every time (a `wasm.test.ts`
      test asserts replay-to-k is deterministic and that replaying past the last
      safepoint reproduces the uninterrupted run). The replay pass runs *pure
      tier-0* (trace execution disabled) so each loop iteration is its own
      safepoint/step — the hot-traced main run would batch iterations and skip
      steps. The step↔line mapping rides a per-safepoint source-line index built
      during the record run, not the keyframe.

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
| Time / clock | log | **landed (F2d)**: `clock()` host effect, `EffectKind.clock`=0 |
| Randomness | seed | **landed (F2e)**: `random()` draws from a VM-owned PRNG; the one recorded effect is the seed, `EffectKind.random_seed`=1 |
| File / network / stdin | log results | **file landed (L-3)**: `loadfile`/`dofile` read content through `EffectKind.file_read`=5; the path is plain program data, only the content is the input. Network/stdin still host effects |
| Environment / args | log at startup | snapshot in header |
| Unicode case table | pin version per recording | **landed (S-C)**: `string.upper`/`lower` use a compiled-in simple-case table; its version is recorded once as `EffectKind.unicode_version`=6 and re-asserted on replay (fatal mismatch) |
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
      only same-machine? (Same-machine is far cheaper.) **Partial data point
      (Phase 7 v3):** the wasm-vs-native differential validator shows *basic*
      IEEE-754 ops (`+`, `-`, `*`, `/`) are already bit-identical across wasm32 and
      x86-64 — those are the deterministic core of the standard. The open risk is
      narrowed to **transcendentals** (`sin`/`exp`/… via libm) and **NaN payload**
      bits, which are not yet exercised (we bundle no libm) and would surface in
      the validator as a flagged divergence. Bit-identical guarantees there would
      need a single software libm bundled into both engines + NaN canonicalisation.
- [ ] Effect-log compaction / interning for high-frequency host calls.

## References

- `00-architecture.md` — §Determinism, §Embedding API, §Observability.
- `04-snapshot-replay-schema.md` — effect record + keyframe formats.
- Prior art: rr, WinDbg Time Travel Debugging; structured concurrency
  (Kotlin / Swift / Trio).
