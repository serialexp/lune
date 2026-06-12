# lune — Architecture

Status: draft, not yet implemented — architecture firm; companion docs 01–04 stubbed
Owner: Bart
Last updated: 2026-06-12

> Working codename **lune** (Lua means "moon" in Portuguese; *lune* is French
> for moon). Not Lua, doesn't aim to be — see Goals. Rename at will.

## Implementation status

Tracking the gap between this design and what's on the main branch.
Tick items as they land; move whole sections to "Done" once everything
inside them is checked.

### Done

_(nothing yet — design only)_

### Outstanding

**Design prerequisites (companion docs — write before the phases they gate).**

- [ ] **`01-trace-lifecycle.md`** — hotness, abort/blacklist, side traces,
      linking, invalidation, snapshot contents, deopt + sunk-alloc
      rematerialisation. Gates Phase 5.
- [ ] **`02-determinism.md`** — effect taxonomy + host-effect boundary + replay
      policy. Gates Phases 3 and 5.
- [ ] **`03-gc-memory.md`** — heap layout, headers, barriers, roots, safepoints,
      typed-array ownership/leases. Gates Phases 1, 3, 4.
- [ ] **`04-snapshot-replay-schema.md`** — the binschema event model + recording
      modes + volume budget. Gates Phases 5b, 7.

**Build phases.**

- [ ] **Phase 0 — Project scaffold.** `build.zig`, module layout, **vendored +
      pinned** Zig toolchain, a test harness that runs from `zig build test`;
      smoke-test `@call(.always_tail)` in Debug builds. Risk-free; can start now.
- [ ] **Phase 1 — Value representation & object model.** 16-byte tagged value
      (tag + 8-byte payload) with first-class `i64` *and* `f64`; GC object
      header; nil/bool/heap-ref. Also settle here (not later): integer
      overflow / mixed-arithmetic semantics (they fix the guard set), the
      typed-array storage model, and the GC-root/header shape (`03-gc-memory.md`).
- [ ] **Phase 2 — Front end.** Lexer → parser → AST for the Lua-shaped surface
      syntax (leave syntactic room for optional type annotations).
- [ ] **Phase 3 — Bytecode compiler + tier-0 interpreter.** Register-based
      bytecode; a plain interpreter. Includes **basic tables, string interning,
      write-barrier call sites (no-op at first), and the host-effect boundary**
      — real programs and the determinism story need them this early.
      **Milestone: runs real programs.**
- [ ] **Phase 4 — Garbage collector.** A deliberately boring **non-moving**
      collector first (stable object addresses), heap laid out for a later
      generational upgrade; typed-array payloads off-heap / pinnable.
      See `03-gc-memory.md`.
- [ ] **Phase 5 — Hot-path detection + trace recorder.** Per
      `01-trace-lifecycle.md` and the deterministic-replay model (§Observability).
      The load-bearing subsystem; includes snapshots and deopt/side-exit restore.
- [ ] **Phase 5b — Trace serialization format.** Define it as a binschema
      schema (canonical `binschema` dir); generate the TypeScript decoder;
      hand-write the Zig writer; validate the two against each other with
      binschema's cross-language fixtures. See §Trace serialization and
      `04-snapshot-replay-schema.md`.
- [ ] **Phase 6 — Trace IR + optimizer + IR-interpreter (tier 1a).** Optimize
      recorded traces and *interpret the IR* — no native code yet. IR carries
      deopt + GC + future-lowering constraints even without codegen.
      **Milestone: traced execution end-to-end, fully correct, zero codegen.**
- [ ] **Phase 7 — Time-travel debugger / trace visualizer.** SolidJS app that
      reads the trace file via the generated TS decoder. Starts with bounded
      recordings, not "complete history" by default. **Milestone: the feature
      this project is for.**
- [ ] **Phase 8 — Native codegen (tier 1b).** Bespoke fast backend, x86-64
      first. A performance step — but *not* mechanical: regalloc across side
      exits, GC stackmaps/safepoints, and machine-state snapshot-restore are
      native-only. The IR-interpreter is the oracle for IR *semantics*, not these.
- [ ] **Phase 9 — Language surface.** Hidden-class **shapes + freezing** (basic
      tables already exist from Phase 3), optional type annotations, stdlib.
      Table-access guards must be designed shape-ready back in Phase 5.
- [ ] **Phase 9b — Typed unboxed arrays.** Narrow element types (`u8`…`f64`),
      contiguous, no per-element GC; GPU-upload-ready (memcpy / zero-copy handoff
      via the host API, not raw FFI). Storage + ownership settled in Phase 1/4.

### Open questions (block real work — tracked as bullets)

- [x] **Value layout: tagged union vs NaN-boxing.** ✅ Decided — 16-byte
      tagged-union universal slot + typed unboxed containers for homogeneous
      arrays. See §Value representation.
- [x] **Recording/replay model.** ✅ Decided — deterministic replay (record
      effects + keyframe snapshots, recompute between them). See §Observability
      + `02-determinism.md`.
- [x] **Coroutines.** ✅ Decided — general coroutines are a Non-goal (plausibly
      forever); suspension is host-mediated. See Non-goals + `02-determinism.md`.
- [x] **FFI vs embedding.** ✅ Decided — first-class embedding API in; general
      script-level C FFI out. See §Embedding API.
- [ ] **Numeric semantics.** `i64` overflow (wrap / error / promote?), mixed
      `i64`/`f64`, division. Fixes the guard set — decide with the tag encoding,
      before Phase 1.
- [ ] **Table / shape model.** Hidden-class shapes, freezable. Basic tables in
      Phase 3; shapes in Phase 9; the *header* decision touches Phase 1.
- [ ] **Typed-array element widths.** Which narrow element types are
      first-class (`u8`…`f64`)? Drives GPU-upload-ready storage. Sketch with
      the shape model.
- [ ] **GC algorithm.** Non-moving first (decided direction); pick the concrete
      collector and the generational-upgrade path. See `03-gc-memory.md`.
- [ ] **Type-annotation scope.** How much gradual typing, and does any of it
      reach the JIT as guard-elimination hints? Defer the system; reserve the
      syntax in Phase 2.

## Why this exists

Two reasons, both honest: (1) to find out whether a LuaJIT-class tracing JIT
can be built from scratch by a small team using modern tools, and (2) because a
**time-travelling trace visualiser** — step backwards and forwards through a
recorded execution — is a genuinely useful debugger and a great thing to build.

The key architectural bet that ties those together: **a tracing JIT and a
time-travel debugger want the same machinery — recording, snapshots, and
deterministic re-execution — so build it once, deliberately, for both.** One
caveat we take seriously (both external reviewers flagged it): a JIT's snapshots
are *sparse* deopt metadata at guards, and the trace recorder only fires on *hot*
paths — neither is a complete reversible log of the whole program. So the
debugger is not "the JIT's snapshots, read differently." It is a **second
consumer** of a shared substrate whose canonical artifact is a **deterministic
replay log** (recorded effects + periodic keyframe snapshots); earlier moments
are *recomputed* on demand by re-executing forward, not stored exhaustively (see
§Observability). The JIT's guard snapshots and the debugger's keyframes share
format and code, but are not the same artifact. This doc is the contract for
building that shared substrate so it serves both clients from day one —
retrofitting it later means redoing the hardest part of the system.

## Goals

- A dynamically-typed, **Lua-shaped** language: it *looks* like Lua, owes Lua
  nothing (the Luau stance). No Lua source or bytecode compatibility.
- A tracing JIT with the classic shape: tiered execution, hot-path tracing,
  guards, side exits, snapshots, trace linking.
- First-class observability: a time-travel debugger fed by the same recorder
  the optimizer uses.
- **A first-class embedding API.** lune is meant to be embedded in a host (the
  motivating case: a Rust app whose data lives in Rust, scripting its tools /
  UI / game logic in lune). A clean C-ABI surface the host binds to; the host
  registers functions and data, marshals values, and leases buffers. This host
  boundary doubles as the controlled effect boundary the replay model needs
  (§Embedding API).
- 64-bit-native from day one — no 32-bit assumptions to retrofit (the GC64
  lesson from LuaJIT).
- Built to be **maintained by a team**, not one expert. Legible structure,
  designed-in tooling, automated tests across the tiers.

## Non-goals (v1)

- Lua compatibility of any kind beyond surface familiarity.
- Being the fastest VM in the world. Correct, legible, and *fast enough that the
  architecture is validated* beats squeezing the last 10%.
- Multi-architecture native codegen on day one. x86-64 first; the IR-interpreter
  means other arches still *run* (just not natively) until their backend lands.
- Shared-memory threading. Shared-nothing / isolate model, like Lua — leaning
  into it, not fighting it (the GIL lesson).
- **General script-level C FFI** (a script declaring/calling arbitrary C, à la
  LuaJIT `ffi.*`). It is simultaneously a determinism hole, a GC-escape hole,
  and a safety hole. Scripts reach the outside world *only* through the
  host-registered, effect-recorded embedding API (§Embedding API).
- **General (stackful) coroutines** — plausibly forever, not just v1. They abort
  traces (a stack switch mid-trace) and complicate replay scheduling, and they
  yield across host frames badly in an embedded VM. Instead, **suspension is
  host-mediated**: stackless generators, host-mediated `await`, and host-owned
  tasks cover the real uses without the footguns (see `02-determinism.md`).

## Guiding principles

1. **Dynamism is the shared enemy.** Unrestricted dynamism destabilises traces
   (guard failures, deopts) *and* costs replay fidelity (state the debugger must
   record or lose). The language choices that stabilise the JIT are the same
   ones that make replay faithful — so design dynamism *out*: freezable shapes,
   controlled/trackable effects, settled globals.
2. **Observability is a first-class consumer, not a feature.** Every recorder
   and snapshot decision is made knowing two clients read it.
3. **Defer native codegen.** Get trace selection, IR, optimization, snapshots,
   and the visualiser working on an **IR-interpreter** first. Native codegen is
   a later performance graft, validated against the IR-interpreter as a
   correctness oracle. This front-loads the interesting part and removes
   per-arch machine-code risk from the critical path.
4. **Stay on Zig's bedrock.** Manual memory, `comptime`, guaranteed tail calls
   (`@call(.always_tail, …)` for threaded dispatch), inline asm, C ABI. Avoid
   the churning frontier (async/`std.Io`, bleeding-edge stdlib). A VM core barely
   touches stdlib — we write our own allocator and data structures — which
   naturally insulates us from where Zig churns most.
5. **Keep a clean C-ABI escape hatch.** Zig is pre-1.0 and we're pinning a
   `-dev` build. The hedge: Zig speaks and compiles C natively, so a clean
   C-ABI surface means worst-case we retreat toward C incrementally rather than
   rewrite. **Vendor** the exact toolchain (not just `.zig-version`) and enforce
   it in CI; keep compiler upgrades in a separate CI lane; treat them as
   scheduled work. Verify `@call(.always_tail)` in Debug builds before betting
   dispatch on it.

## Execution pipeline

```
source
  └─▶ lexer ─▶ parser ─▶ AST
                          └─▶ bytecode compiler ─▶ register bytecode
                                                     │
                                          ┌──────────┴───────────┐
                                          ▼                      │ hot path
                                  tier-0 interpreter             ▼ detected
                                  (always correct)        trace recorder
                                                                 │
                                                       records ──┤── snapshots
                                                                 ▼        │
                                                            trace IR      │
                                                                 ▼        │
                                                            optimizer     │
                                                                 ▼        │
                                              tier-1a: IR-interpreter     │
                                              tier-1b: native codegen     │
                                                                          ▼
                                                       time-travel debugger /
                                                       trace visualiser
                                                  (second consumer of recorder
                                                   + snapshots)
```

Two clients read the recorder/snapshot stream: the **optimizer/codegen** (lossy
is fine — DCE and allocation-sinking deliberately discard intermediate state)
and the **debugger** (wants full fidelity). See §Observability for how one
recorder serves both.

(The diagram simplifies one thing: snapshots also feed **side-exit / deopt
restore** *inside* the engine — handing control back to tier-0 when a guard
fails — not only the debugger. That path, including rematerialising
allocation-sunk objects, is the hardest part of the recorder and is specified in
the trace-lifecycle doc, not here.)

## Value representation

**Decision (locked): first-class `i64` integers *and* `f64` floats from day
one.** We will not repeat the bolt-on-integers-later mistake. Numeric operations
guard on integer-vs-float from the start — paying the type axis up front is far
cheaper than retrofitting it into a mature JIT and value layout.

Consequence for the layout: classic **NaN-boxing cannot hold a full 64-bit
integer unboxed** (the NaN payload is ~51 bits). With `i64` first-class, boxing
integers would be unacceptable for arithmetic. So:

- **Decided: a 16-byte tagged value** as the universal slot — an explicit tag
  (nil / bool / i64 / f64 / heap-ref / …) plus an 8-byte payload. Costs cache
  footprint vs NaN-boxing, but it is simple, debuggable, and **self-describing**
  — a direct gift to the time-travel visualiser (every recorded value knows what
  it is without reconstruction) and to the trace format (serialises straight to a
  binschema discriminated union).
- **NaN-boxing stays on the table as a later optimization** for a narrower value
  set, if profiling justifies it. Not day one.

### Typed unboxed containers (the footprint escape hatch)

The tagged slot's one real cost — 2× footprint, half the cache density — bites
hardest on big *homogeneous* numeric arrays, which is exactly where you don't
need a per-element tag: the container's shape already names the type. So:

- **Homogeneous arrays store raw, unboxed elements** — the tag lives once on the
  shape, not on every element. A million-element `f64[]` is 8 MB, not 16 MB.
- **Narrow element types are first-class**: `u8`, `u16`, `u32`, `i64`, `f32`,
  `f64`, … — not only the 8-byte value types. This is the voxel/buffer case.
- **GPU-upload-ready by construction.** A contiguous unboxed `u8[]`/`u16[]`
  buffer is a `memcpy` — or a zero-copy pointer handoff over the FFI — straight
  to the GPU: no packing pass, no marshalling, no per-element allocation. The
  perf path (cache density) and the interop path (GPU bandwidth) are the *same*
  design, which is a strong signal it is the right primitive.

This keys off the shape/hidden-class model (§Language surface) and is why the
tagged-slot footprint cost is acceptable: it only lands on scattered,
heterogeneous values where 16-vs-8 bytes barely matters.

GC heap objects carry a common header (type, GC mark/age, shape pointer for
table-likes). 64-bit fields throughout. **Open: finalize the exact tag encoding
and header before Phase 1.**

## Observability — deterministic replay

The hardest, most load-bearing subsystem (snapshots are where LuaJIT's real
engineering went). Naively, time-travel wants "every step ever executed" — but
that is unworkable two ways the reviewers both caught:

- **Coverage.** The JIT recorder only fires on *hot* paths. Tier-0 execution,
  side-exit fallbacks, and aborted traces produce no trace — so the JIT recorder
  cannot be the source of truth for the *whole* program.
- **Volume.** A literal step log runs at gigabytes per second (a modest 50M
  ops/s × ~24 B/step is >1 GB/s); the visualiser would then have to load it.

**Resolution: deterministic replay** (the rr / WinDbg-TTD model). The canonical
artifact is *not* a full step log. It is:

1. an **effect log** — every nondeterministic input the program observed (host
   calls, time, randomness, I/O results, hash seeds; see §Determinism), plus
2. periodic **keyframe snapshots** of VM state.

Any earlier moment is reconstructed by restoring the nearest keyframe and
**re-executing forward deterministically**, feeding recorded effects back in.
Stepping backward = restore keyframe + replay to N−1. This makes the artifact
*megabytes* (effects + keyframes), not gigabytes, and it covers the *whole*
execution, tier-0 included — not just hot traces.

How it relates to the JIT's own snapshots:

- The JIT's **guard snapshots** (for side-exit/deopt restore) and the debugger's
  **keyframes** share format and code — same substrate — but they are *not the
  same artifact*, and the optimizer is **not** forced to consume the debug log
  (that would couple JIT compile cost to debug-recorder bandwidth). The recorder
  front-end tees: it emits IR for the optimizer and, when recording is on,
  effects + keyframes for replay.
- Recording is a **mode**, not always-on: full-replay, bounded ring-buffer window
  (live debugging), keyframe-only, or off. Defaults and a bytes/step budget live
  in `04-snapshot-replay-schema.md`.

The concrete event model, recording modes, and volume budget are specified in
`04-snapshot-replay-schema.md`; the determinism rules that make replay sound are
in `02-determinism.md`.

## Determinism

Deterministic replay is only as sound as the runtime's control over
nondeterminism. The full taxonomy and policy is `02-determinism.md`; the
architectural commitments:

- **Every nondeterministic input is captured at one boundary.** Time, randomness,
  environment, file/network/stdin results, and all host calls flow through the
  host-effect boundary (§Embedding API) and are logged as effect records.
- **Internal nondeterminism is designed out, not recorded.** Hash seeds are fixed
  per recording (stored in the trace header); table iteration order is
  address-independent and deterministic; floating-point mode is pinned. GC must
  not be observable (no finalizers / weak refs in v1, or GC scheduled at recorded
  safepoints).
- **The host-effect boundary is also the suspension mechanism.** An `await` is
  "call a host effect that may suspend the caller." Because every such call is
  already a recorded effect and a trace barrier, host-mediated suspension
  (generators / await / tasks — our coroutine replacement) gets deterministic
  scheduling *for free*. v1 need only **not preclude** it.

## Embedding API

lune is an embeddable VM; the host (motivating case: a Rust app) drives it. This
boundary is load-bearing for three things at once — usability, determinism, and
safety — so it is designed, not incidental. Full design in a later doc; the
commitments:

- **C-ABI surface.** Zig exports a stable C ABI; the host (Rust) binds to it.
  This is also the clean escape hatch of Guiding Principle 5.
- **Host registers functions and data**; scripts call them. There is no other
  path to the outside world (general FFI is a Non-goal).
- **Every host call is an effect and a trace barrier.** Inputs/outputs are
  recorded for replay; the JIT does not trace through it; GC roots are registered
  across the call; native code may not retain raw VM pointers.
- **Buffers cross as leases, not raw pointers.** The zero-copy typed-array / GPU
  path (§Value representation) hands the host a lease with explicit lifetime and
  mutability, over off-heap / pinned storage (`03-gc-memory.md`) — never interior
  pointers into movable GC memory.

## Trace serialization

The recording is the contract between the VM (producer) and any consumer (the
SolidJS visualiser, post-mortem tooling, a future live debugger). We define that
contract as a **binschema** schema — the `binschema` directory is canonical
(`binschema2` is a stale parallel copy, ignore it).

Why binschema fits: the stream is almost entirely **tagged values and snapshot
records** — a tag plus a variant payload — which is exactly a *discriminated
union*, binschema's core feature. Bit-level fields, computed lengths, and
cross-language conformance testing come along for free.

Bring-up plan (don't block lune on tooling):

- **Schema is the source of truth** for the wire format — versioned, documented.
- **TypeScript decoder: generated** from the schema. The visualiser does zero
  hand-written parsing.
- **Zig writer: hand-written** — binschema has no Zig generator yet (its
  backends are TS/Python/Rust/Go). Validated against the generated TS decoder by
  binschema's cross-language JSON fixtures, so the format stays the single source
  of truth even though the encoder is hand-maintained. (If a Zig backend ever
  lands in binschema that's orthogonal, separate work — nothing here depends on
  it, and the writer can be swapped for generated code if it shows up.)

JSON is fine for early bring-up; expect to lean on binschema's compact binary
encoding once traces get long (full-fidelity recordings grow fast).

## Language surface (early sketch — detail in a later doc)

Lua-shaped syntax, with deliberate divergences chosen for JIT stability and
replay fidelity:

- **Freezable shapes.** Tables get hidden-class-style shapes; the ability to
  *freeze* a shape keeps traces stable and lets the visualiser show named struct
  fields instead of opaque hash lookups. (Touches the object header in Phase 1.)
- **Optional type annotations** (Luau-style gradual typing). Not v1, but reserve
  the syntax now. Even light type info means fewer guards *and* a richer
  visualiser. Retrofitting syntax is painful; reserving it is free.
- **Controlled effects.** Lean toward trackable effects and settled globals —
  every uncontrolled nondeterminism source is fidelity the time-traveller must
  record or surrender (`02-determinism.md`).
- **No general coroutines; host-mediated suspension instead.** Stackless
  generators, host-mediated `await`, and host-owned tasks (structured
  concurrency) cover lazy sequences, "do/wait/do" sequencing, and cooperative
  tasks — without stackful-coroutine footguns. See Non-goals + `02-determinism.md`.

## Build order (rationale)

Standard order would be interpreter → GC → JIT → … → debugger last. We **flip
it**: the trace machinery and the visualiser come online *before* any native
code (Phases 5–7), by interpreting the optimized IR (tier-1a). This de-risks the
scary part (per-arch codegen is deferred indefinitely and never blocks
progress), front-loads the feature the project exists for, and gives native
codegen a ready-made correctness oracle when it finally lands.

## Testing strategy

The tiered architecture is unusually well-suited to **differential testing**:
tier-0, tier-1a (IR-interpreter), and later tier-1b (native) must agree on every
program. Differential fuzzing across tiers is the primary correctness mechanism
behind the Goal of "automated tests across the tiers" — divergence is a bug in
the faster tier. Replay determinism is itself testable: record once, replay,
assert identical observable behavior. binschema's cross-language fixtures police
the trace writer / decoder pair.

## References

- LuaJIT source (`lj_trace.c`, `lj_snap.c`, `lj_record.c`, `vm_*.dasc`) — the
  reference implementation of every mechanism here; read for *how*, not as
  scripture.
- Luau — prior art for "Lua-shaped but not Lua," gradual typing, shape stability.
- binschema (`~/Projects/binschema`) — schema-driven binary format + multi-lang
  codegen; defines the trace wire format and generates the visualiser's decoder.
- Companion design docs: `01-trace-lifecycle.md`, `02-determinism.md`,
  `03-gc-memory.md`, `04-snapshot-replay-schema.md` — the failure-policy and
  schema detail this overview defers to.
- Conversation log that produced this doc (tracing JITs, abort/blacklist policy,
  asm-vs-C, Zig-vs-Rust, the dual-consumer recorder insight, GPU-buffer arrays).
- External architecture reviews (Codex / gpt + Fable) — source of the
  deterministic-replay correction, the trace-lifecycle / determinism / GC gaps,
  and the phasing fixes folded in here.
