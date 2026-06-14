# lune — Architecture

Status: partial — Phases 0–6b landed; Phase 7 through v8 (in-browser deterministic replay + timing); Phases 8–9 outstanding
Owner: Bart
Last updated: 2026-06-15

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

- [x] **Phase 0 — Project scaffold.** `build.zig`, module layout, pinned Zig
      toolchain (`.zig-version` + `-Denforce-zig-version` guard), a test harness
      that runs from `zig build test`, and an `@call(.always_tail)` threaded-
      dispatch smoke test (2M tail calls in constant stack). **Finding:** the
      now-default self-hosted `stage2_x86_64` backend rejects guaranteed tail
      calls; the build forces `use_llvm = true` (principle #4). Done.
      **The smoke test (`src/dispatch.zig`) is a permanent capability gate, not
      disposable code** — its *toy loop* is throwaway, but guaranteed tail calls
      are pillar #4 and the test is what keeps them verified on every target. The
      current tier-0 (`interp.zig`, Phase 3) is intentionally a `while/switch`
      correctness oracle that does **not** thread its dispatch yet; threaded
      dispatch is a reserved fast-path technique. Any new target (e.g. wasm32) must
      **keep this test green** (enable the target's tail-call feature, mirroring
      `use_llvm = true` on native) — a target that can't emit guaranteed tail calls
      must fail here loudly, never be silently gated out.
- [x] **Phase 1 — Value representation & object model.** Done.
      16-byte tagged `Value` (tag at offset 0 + 8-byte payload, comptime-asserted)
      with first-class `i64` *and* `f64` (`src/value.zig`); 16-byte `GcHeader`
      (type/color/flags/intrusive-next) with the embedding convention and
      `ObjectType` (`src/object.zig`); nil/bool/heap-ref. Numeric semantics are
      settled and tested (`src/arith.zig`): **`i64` overflow wraps**, mixed
      `i64`/`f64` promotes to `f64`, `/` is always float, `//` is integer
      floor-division (errors on integer zero divisor), `%` is floored modulo;
      cross-type numeric compare is **exact** (no `f64`-rounding collisions). The
      typed-array storage model (`ElementType` `u8`…`f64`, off-heap `TypedArray`
      descriptor + `BufferOwner`) is fixed; allocation/leases land in Phase 9b.
- [x] **Phase 2 — Front end.** Done.
      Hand-written scanner (`src/lexer.zig` + `src/token.zig`) with an
      `int_literal`/`float_literal` lexical split; shared diagnostics sink
      (`src/diag.zig`) with byte-span + line and error recovery; arena-owned
      pointer-based AST with per-node spans (`src/ast.zig`); recursive-descent
      statements + Pratt expressions with full Lua precedence and right-assoc
      `..`/`^` (`src/parser.zig`). Optional **type annotations are parsed and
      retained** (unchecked, per the language-surface sketch). Deferred and noted
      in source: long-bracket string literals, hex floats, call sugar
      (`f"s"`/`f{…}`), `repeat`/`until`, `goto`/labels. 55 tests pass.
- [x] **Phase 3 — Bytecode compiler + tier-0 interpreter.** Done.
      Register-based 12-byte bytecode ISA (`src/bytecode.zig`) with a total
      disassembler; a single-pass compiler (`src/compiler.zig`) with
      stack-discipline register allocation, back-patched control flow, and
      local→upvalue→global name resolution; a recursive switch-dispatch tier-0
      interpreter (`src/interp.zig`) over a fixed, never-reallocated register/call
      stack (the **correctness oracle**, not a hot tier). Runtime heap
      (`src/gc.zig` + `src/string.zig`/`src/table.zig`/`src/function.zig`): an
      intrusive object list, **interned strings** (content→unique object, so
      equality/keys are pointer compares), **basic tables**, and closures with
      classic **open/closed upvalues**. Functions, calls (register-window call
      convention), `local function` recursion, and globals all land here. The
      **host-effect boundary** is a type-erased `Native` (`print`) writing through
      an injectable `Vm.out` sink — output never touches real stdout in tests.
      **Write-barrier call sites are deferred to Phase 4** (the collector that
      needs them): the tier-0 mutator allocates through the heap and links every
      object onto the sweep list, so the seam is the heap allocator itself. A real
      CLI (`src/main.zig`) runs a `.lua` file or `-e` chunk through
      parse→compile→run. **Milestone met: runs real programs.** 128 tests pass,
      including end-to-end source→output integration tests.
- [x] **Phase 4 — Garbage collector.** Done.
      A deliberately boring **stop-the-world, non-moving, tri-colour mark-sweep**
      (`src/gc.zig` + `src/interp.zig`): stable object addresses (later trace
      tiers may hold raw pointers), no compaction, no finalizers/weak refs, no
      concurrency. The heap owns the mechanism — gray worklist, `markValue`/
      `traceAll`/`sweep`, pre-sized so marking can't allocate; the VM owns the
      **root set** (globals, live registers via a `stack_top` high-water, the
      active-frame closures, open upvalue cells) and runs collection at a single
      **safepoint at the top of the dispatch loop**, where no half-built object is
      exposed. Blackening a closure walks its `proto.constants` recursively
      through `proto.protos`, so every string constant stays alive even before its
      function is instantiated. **Interned strings are collectible** (a swept
      string is de-interned). Trigger is live×2 (floored), with a `gc_stress`
      knob. The write barrier stays a no-op (correct for stop-the-world; the seams
      remain for a generational upgrade). Verified by running the Phase 3 programs
      under GC-at-every-safepoint and a 1,000,000-iteration allocating loop in
      bounded (~6 MB) memory. 135 tests pass. See `03-gc-memory.md`.
- [~] **Phase 5 — Hot-path detection + trace recorder.** **Done (Phase 5a):**
      the recorder (`src/trace.zig` + `src/interp.zig` wiring). Back-edge counters
      keyed by `(proto, target-pc)` with a `hotloop` threshold arm a recording at
      a hot loop header; the recorder mirrors each executed instruction into a
      **linear SSA trace IR** (`slot_load`/`konst` inputs, the arithmetic/compare
      subset, **type guards** synthesised from observed operand types, a `loop`
      close), reading **pre-execution** operands so guards pin the types tier-0
      actually saw. It closes cleanly on loop-back to the anchor (building the
      exit slot-store snapshot) and **aborts** with explicit reasons (cross-frame
      `call`/`ret`, host barrier, NYI opcode, bad type, `maxrecord`, alloc),
      discarding the partial trace and blacklisting the anchor (permanent in 5a —
      backoff is later). Traces are cached on the VM and their **constants are GC
      roots**. Crucially the recorder is **transparent**: tier-0 still executes
      everything, so output is byte-identical with the recorder on or off — the
      `expectProgram` matrix runs every e2e program under {gc_stress} × {recorder}
      and asserts identical output. Opt-in via `--trace` / `--dump-traces`, default
      off. Per `01-trace-lifecycle.md` and the deterministic-replay model
      (§Observability). **Deferred:** *executing* traces, the optimizer, and
      deopt/side-exit **restore** → Phase 6 (each guard already carries a
      `SnapIdx` placeholder and the entry/exit slot maps the restore will need);
      penalty/blacklist backoff, side traces & linking, cache invalidation, and
      counter decay → later.
- [~] **Phase 5b — Trace serialization format.** **Done (Zig round-trip):** the
      committed trace cache now serializes to a versioned, on-disk wire format.
      The format is defined declaratively in `schema/trace.json` (binschema); the
      Zig encoder/decoder is **generated** from it (`tools/regen-trace-schema.sh`)
      and **vendored** under `src/gen/` — so lune builds with no dependency on the
      binschema repo (the generated runtime is committed). `src/traceser.zig` maps
      a `trace.Trace` onto the schema structs; `--emit-traces <file>` drops the
      cache after a run. The in-memory `*const Proto` anchor pointer is replaced by
      a stable, compile-time `Proto.id` (a pointer is meaningless on disk; the
      visualiser uses the id as a correlation key). Round-trip is proven
      byte/struct-exact for real recorded traces (numeric + a string const) and a
      hand-built edge corpus (`INT64_MIN/MAX`, FP specials, NUL-bearing strings).
      **Landed in Phase 7 (the visualiser hosts them):** the **TypeScript
      decoder** (generated + vendored under `viz/src/gen/`) and the binschema
      **cross-language fixture** (`viz/fixtures/counting-loop.lunetrace`, decoded
      + asserted by `bun test`). **Deferred → later:** reload-into-VM (id→`*Proto` rebind + proto-hash
      validation), and the richer recording header / effect log / keyframes (the
      rest of `04-snapshot-replay-schema.md`, gated on the host-effect boundary).
      See §Trace serialization and `04-snapshot-replay-schema.md`.
- [~] **Phase 6 — IR-interpreter (tier 1a) + deopt.** **Done (Phase 6a):** the
      tier-1a executor (`src/irinterp.zig` + the back-edge seam in `src/interp.zig`)
      *runs* recorded traces — no native code. `execute` walks the linear SSA IR
      into a private, reused `values[]` scratch, calling the **same `arith.zig`**
      tier-0 does (byte-identical results), and writes the tier-0 register file
      **only** at a clean `loop` close (applying `exit_stores`). **Deopt is
      loop-header re-entry:** because `regs` is coherent for the loop header at
      every iteration boundary, any guard failure / arithmetic error mid-iteration
      just *side-exits* (returns with `regs` untouched) and tier-0 re-runs the
      partial iteration from `anchor.pc` — **no per-guard snapshot needed**, sound
      because a committed trace has no side effects (host calls / tables / globals
      abort recording). A **re-entry brake** (`onSideExit`: per-anchor `penalty`,
      `min_useful`/`max_penalty`) blacklists type-unstable / branchy loops that
      thrash. **Execution is transparent**: the `expectProgram` matrix now runs
      every e2e program under {gc_stress} × {off, record-only, **record+execute**}
      and asserts byte-identical output; a debug-only commit-time structural
      verifier (`assertWellFormed`) guards the executor's IR invariants. `--trace`
      now records **and** executes; `--trace-record-only` is Phase 5a behaviour.
      **Milestone met: traced execution end-to-end, fully correct, zero codegen.**
      **Deferred → Phase 6b / later:** the trace **optimizer** (constant-fold /
      DCE / narrowing, each with its deopt-reconstruction rule); full **per-guard
      snapshots** + general side-exit restore (needed only once we mutate `regs`
      mid-trace or trace across calls); **side traces & linking** (the real fix for
      branchy hot loops, vs. the blacklist brake); penalty **backoff** & counter
      decay; cache **invalidation**.
- [x] **Phase 6b — Trace optimizer (rewrite passes).** **Done.** `src/tropt.zig`
      rewrites a freshly-recorded trace **once at commit time** (never in the
      executor hot loop) into a smaller, output-identical body: **constant
      folding**, **CSE**, and **dead-code elimination**, sharing one forward
      fold/CSE stage + backward liveness + compaction (the compaction *is* the
      ref-remap, since refs are instruction indices). **Why the sound set is so
      small:** under loop-header re-entry deopt the executor writes `regs` only at
      the `loop` close and any side-exit re-runs the whole partial iteration, so
      deopt reconstruction is *independent of the optimized body*. A rewrite is
      sound iff (a) completed iterations produce byte-identical `exit_store` values
      and (b) it never drops a **load-bearing** guard. Because the executor has
      **no type-specialized fast paths** (every op re-dispatches through
      `arith.zig`), the only guards droppable are ones that **provably always
      pass** (on a value the optimizer proved constant) or **exact duplicates**;
      an always-*fail* guard is kept. Constant folding calls the **same**
      `irinterp.evalBinary`/`evalUnary` the executor uses, so a folded constant is
      byte-identical to the runtime computation by construction; a fold that would
      *error* (integer `//`/`%`-by-zero) is **left as a runtime op** so it
      side-exits and tier-0 re-raises — never deleted. **Transparency** is the
      8-way `expectProgram` matrix ({gc_stress} × {off, record-only,
      record+execute-noopt, record+execute-opt}) plus a seeded differential fuzz;
      the optimizer-does-work proof is deterministic `instrs.len`-reduction unit
      tests. `TraceConfig.optimize` (default on) gates it; an optimizer OOM falls
      back to caching the unoptimized trace. `--trace-no-opt` records & executes
      raw IR; `zig build bench` (ReleaseFast) reports per-loop raw/opt instruction
      counts + wall-time. **Note (honest):** the tier-1a IR-interpreter is a
      *boxed SSA walk* (one switch dispatch + guard checks per IR instr per
      iteration), so today it is **slower than tier-0** on these loops — the
      optimizer shrinks the body and is never slower than no-opt, but the real
      speed win waits on typed fast paths / native codegen. **Deferred (cross the
      no-executor-change line):** type **narrowing/unboxing** (typed `add_i64`… +
      unboxed scratch + load-bearing guards — the big arithmetic win, payoff in
      Phase 8) and **LICM** (a once-only trace preheader in the executor); plus
      algebraic identities and const-pool pruning. **Landed since:** record-time
      **konst interning** (the recorder dedups constants, so identical
      subexpressions share operand refs and CSE now fires on real traces — e.g.
      the two `i+7` in `(i+7)*(i+7)` collapse to one `add`; see `src/trace.zig`
      `konst`, tests in `src/interp.zig`).
- [~] **Phase 7 — Time-travel debugger / trace visualizer.** SolidJS app that
      reads the trace file via the generated TS decoder. Starts with bounded
      recordings, not "complete history" by default. **Milestone: the feature
      this project is for.**
      **Landed (v1 — static trace inspector, `viz/`):** Bun + Vite + SolidJS app
      that loads a `.lunetrace` and renders each trace's IR exactly as
      `--dump-traces` does (header, numbered instrs, consts pool, exit stores),
      driven by the **generated** TS decoder vendored under `viz/src/gen/` (one
      schema → both Zig and TS codecs via `tools/regen-trace-schema.sh`). The
      `IrOp`/`ObsType`/`Tag` wire ordinals are pinned by a guard test in
      `src/traceser.zig` and mirrored in `viz/src/enums.ts`. A committed
      cross-language fixture (`viz/fixtures/counting-loop.lunetrace`, Zig-encoded)
      is decoded + asserted by `bun test`, proving Zig-encode ↔ TS-decode agree.
      `?src=<url>` deep-links a trace. **v2 begun — the determinism bedrock:**
      time-stepping needs deterministic record-and-replay (restore a keyframe,
      re-execute forward feeding recorded effects back), which is only sound if an
      identical run is bit-reproducible. The first v2 increment makes that real and
      guards it: a stable deterministic **`GcHeader.id`** replaces the `@intFromPtr`
      address `print` used to leak (so output no longer depends on ASLR), FP mode
      is pinned `.strict` in `arith.zig`, and a **determinism self-check** asserts
      two independent runs of a program agree on output *and* serialized traces
      (doc 02 §Replay verification). **F2a (keyframe serializer) landed:** a
      whole-VM keyframe — the full reachable heap graph + roots, keyed on
      `GcHeader.id`, every edge a `u32` id — serializes to a versioned wire record
      (`SnapshotFile`, an additive record family sharing the trace artifact's
      generated codec; doc 04). `src/keyframeser.zig` mirrors `gc.blacken`'s edge
      set and is seeded from the same roots `Vm.collect` marks (one
      `Vm.forEachRootHeader` helper, no drift); `--emit-keyframe <file>` drops a
      snapshot after a run. The run-twice harness now also asserts byte-identical
      **snapshot** bytes — which caught a real determinism bug (table keys hashed
      by address, now by stable id; doc 02 §Table iteration order). **F2b (keyframe
      restore) landed:** a snapshot decodes back into a fresh, bare VM
      (`keyframeser.restore`) — two-pass heap-graph rebuild (id→pointer rebind,
      string re-interning, Proto-by-id / Native-by-name rebind, stack + frame +
      open-upvalue reconstruction). Ids are re-stamped to their *originals* via a
      restore-only `gc.Heap` seam, so a restored VM re-serializes **byte-for-byte
      identical** to its snapshot (`encodeSnapshot ∘ restore == identity`) — capture
      and restore proven exact inverses, for a *final-state* snapshot. **F2c
      (mid-execution capture + resume) landed:** the interpreter's host-stack
      recursion became an explicit `Vm.frames` call-stack driven by one iterative
      `exec` loop, so a frame's full cursor (closure, `pc`, window `base`,
      return-wiring) is reified data and a safepoint can suspend with a live stack.
      A keyframe captured mid-loop / inside a nested call restores into a fresh VM
      and **re-executes forward** to the same output (`out_before ++ out_after == F`)
      and the same byte-identical final snapshot. The enabler: heap identity is now
      total by stable `GcHeader.id` — `value.zig` `eql` compares heap refs by id, not
      address — so a restored VM resolves globals/keys against the borrowed program
      image whose constants live in a *different* heap (same id, different address);
      address equality silently broke resume (`print` → `nil`). The recursion→loop
      refactor is behaviourally invisible (the 8-way `expectProgram` matrix stays
      byte-identical). **F2d (effect log) landed:** the first nondeterministic
      *input* now exists — `clock()`, the host monotonic clock, carried as a stable
      `EffectKind` enum. A native may flag itself an effect; the VM runs in
      `off`/`record`/`replay` modes with an ordered `effect_log` — `record` logs each
      effect result, `replay` feeds the logged results back instead of re-calling the
      effect. The log is a **third record family** (`EffectFile`, own version word,
      shared binschema encoding; `src/effectser.zig`), and the combined demo ties
      F2c+F2d together: restore a mid-run keyframe of a clock()-using program **and**
      replay its effect log from the cut cursor → identical forward output, even
      though a fresh record run differs (the captured nondeterminism). `--emit-effects`
      writes the log. **F2-recap → Phase 7 v3 (run lune *in the browser*):** the VM
      core compiles to **wasm32-freestanding** (`src/wasm_entry.zig`, `zig build
      wasm`) and runs **in the page** — the viz app now authors, executes, *and*
      inspects in one place ("Run (wasm)"). wasm forced a clean determinism seam:
      with no clock syscall, `clock()` had to route through an injected
      `ClockSource` (a JS `host_now_ns` import; the native CLI injects the Linux
      monotonic clock — the interpreter holds no platform clock of its own). The
      guaranteed-tail-call pillar (#4) holds on wasm too: the artifact exports the
      `dispatch.zig` smoke test (compile-time gate — `@call(.always_tail)` would
      fail the build if wasm couldn't emit `return_call`) and a `bun` test runs 2M
      hops in O(1) stack (runtime gate). The payoff is the **dual-execution
      differential validator** ("Run both + diff", `viz/src/diff.ts`): the same
      source runs through the wasm VM *and* the native binary (a dev-server `POST
      /run` subprocess) and every artifact is compared byte-for-byte. Two different
      engines agreeing is the strongest determinism evidence yet — for a
      deterministic program, keyframe + effects + trace + stdout are byte-identical
      across wasm and x86-64 (incl. basic float ops); a `clock()` program's
      divergence appears only in the effect log, labelled expected (doc 02
      §cross-engine differential validation). **Phase 7 v4 (in-browser editor):**
      the authoring textarea became a CodeMirror 6 editor with lune syntax
      highlighting (a small mode keyed to the real lexer/token set, not a borrowed
      Lua grammar) and **live validation**: as you type, the editor runs the source
      through a compile-only wasm entry (`lune_check` — parse + compile, no
      execution, so an infinite loop can't hang the tab) and underlines errors with
      the *same diagnostics the native compiler emits*. Validation against the real
      frontend can't drift from the language. The compiler also gained a Luau-style
      **unknown-global warning** (deferred two-phase: collect every global read +
      write across the chunk, then warn on a read whose name is never assigned and
      isn't a builtin — so forward references to later `function f()` declarations
      stay quiet); it surfaces as a yellow squiggle in the editor and a warning line
      on the native CLI. **Phase 7 v5 (located runtime errors):** the VM used to
      raise a bare Zig error (`@errorName` → the single word "TypeError"); now the
      compiler emits a per-instruction `Proto.spans` array (parallel to `code`,
      in-memory only — no wire-format change) and, at the error boundary,
      `Vm.describeFault` reads the **un-popped** faulting frame to synthesize a
      Lua-style message naming the operation and the offending operand type
      ("attempt to perform arithmetic on a nil value") plus a 1-based line and a
      byte span. The hot loop pays only a one-store-per-iteration `frame.pc` sync
      (tier-0 is the correctness oracle, not the speed tier); everything else is a
      cold path. The editor underlines the faulting span with a wavy squiggle in a
      decoration channel *separate* from the compile linter (the two would
      otherwise overwrite each other). **Phase 7 v6 (multi-frame backtrace):**
      because `exec` does not unwind `Vm.frames` on error, the entire live call
      stack survives; `describeFault` now walks it into a deepest-first
      `FaultFrame` chain (each frame's function name + the source line/span of its
      active instruction — the faulting pc for the leaf, the call-site `pc-1` for
      each parent). The native CLI prints a Lua-style `stack traceback:`; the wasm
      `Result` carries a structured backtrace blob that the viz flattens to a
      one-line "`foo:5 → bar:12 → main:3`" traceback under the error (the editor
      squiggle stays on the leaf). **F2e (seed-based randomness) landed:** `random()`
      is the second nondeterministic input (`EffectKind.random_seed`=1), but
      seed-based rather than per-call — the PRNG (`std.Random.Xoshiro256`, pinned by
      name as a spec commitment) lives inside the VM, and the *one* recorded effect
      is a `u64` seed acquired lazily on the first draw, from which the whole stream
      reproduces on replay. The seed rides the existing non-heap int result path, so
      a new effect kind cost zero wire/codec change. A given seed yields the same
      stream on native and wasm, so the differential validator labels a `random()`
      program's one-effect divergence *expected*, exactly as for `clock()`.
      **Phase 7 v8 (in-browser deterministic replay + timing) landed:** the
      visualiser now *drives* the replay spine. Two parts. (1) An execution-time
      readout — the wasm `Result` carries an `exec_ns` measured around `vm.start`
      alone, and the viz shows `ran in T ms (execute E ms)` (total wall-clock vs.
      VM-execute-only). (2) A user-facing step debugger built on a **stateless
      "replay to k"** model: the initial run records the effect log once and
      reports a total safepoint count plus a per-safepoint source-line index; to
      show the program at step *k* the viz calls `lune_replay(src, effects, k)`,
      which re-compiles, replays the recorded effects with
      `suspend_ctl.after_safepoints = k` (a separate *pure tier-0* pass so every
      loop iteration is its own step), and snapshots the keyframe + stdout-so-far
      + current line/span + backtrace. Scrubbing the slider re-runs from scratch
      each time — O(k) per step, trivially fast at visualiser scale, and a direct
      demonstration that replay to the same k yields *identical* state every time.
      The panel offers both **instruction** grain (one stop per safepoint) and
      **line** grain (stops where the source line changes, derived from the index
      with no extra round-trips), shows locals + globals + the call chain decoded
      from the keyframe, and highlights the current source line in the editor (its
      own decoration channel, alongside the lint and runtime-error channels).
      A generous safepoint cap bounds pathological loops and is surfaced, never
      silent. **Environment/args landed:** three flat builtins — `getenv(name)`
      (`EffectKind.getenv`=2), `argc()` (=3), `argv(i)` (=4) — extend the effect
      spine to the last common nondeterministic input. The crux was that `getenv`/
      `argv` return **heap strings** while a standalone effect log has no heap graph,
      so the wire result type became a dedicated `EffectResult` union (own tag space,
      inline length-prefixed string bytes, *not* a `SnapValue` heap-ref) re-interned
      into the replaying heap on decode (`effect_format_version` 1→2), and
      `forEachRootHeader` now roots `effect_log` string results so a mid-run
      collection can't free one in flight. The host seam mirrors clock/random (native
      CLI reads real `std.process` env + captured argv; wasm injects a null source →
      nil/0/nil); a Lua-style `arg` *table* is deferred to stdlib (it would need a
      heap table on the wire). **Still to come:** the visualiser's JIT-trace
      iteration animation.
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
- [x] **Numeric semantics.** ✅ Decided + implemented (`src/arith.zig`):
      `i64` overflow **wraps** (two's complement — branchless, deterministic,
      trace-stable; the op never traps or changes type, so arithmetic needs only
      operand type guards); mixed `i64`/`f64` promotes to `f64`; `/` is always
      float division; `//` is integer floor-division (errors on an integer zero
      divisor, `minInt // -1` wraps); `%` is floored modulo (divisor's sign);
      cross-type compare is exact. Trap and promote-to-float were rejected.
- [ ] **Table / shape model.** Hidden-class shapes, freezable. Basic tables in
      Phase 3; shapes in Phase 9; the *header* decision touches Phase 1.
- [x] **Typed-array element widths.** ✅ Decided — first-class `ElementType`:
      `u8`/`u16`/`u32`/`u64`, `i8`/`i16`/`i32`/`i64`, `f32`/`f64` (element width
      == alignment). Off-heap `TypedArray` descriptor + `BufferOwner` shape fixed
      in `src/object.zig`; storage/lease behaviour is Phase 9b.
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
   naturally insulates us from where Zig churns most. Where we *do* need a churny
   surface (e.g. stdout for the CLI/diagnostics needs `std.Io`'s writer), it is
   confined to a single wrapper (`src/io.zig`) so a toolchain bump is a one-file
   fix, not a sweep — the VM core and `Value` stay free of the dependency.
   **Verified (Phase 0):** on the pinned toolchain, guaranteed tail calls are an
   *LLVM-backend-only* feature — the now-default self-hosted `stage2_x86_64`
   backend errors with "does not support tail calls on target architecture
   x86_64". The build therefore sets `use_llvm = true` on every artifact that
   uses threaded dispatch. This is a real constraint, not a footnote: dropping
   to the self-hosted backend (faster Debug builds) is blocked until it learns
   tail calls. Re-check on each toolchain bump.
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

GC heap objects carry a common 16-byte header (`GcHeader`: `ObjectType`, GC
color, flags, intrusive next-pointer). Concrete objects embed it as their first
field; a `Value.heap_ref` payload *is* a `*GcHeader`. The shape/hidden-class
pointer lives in the table object, not the universal header (it would bloat every
string), per `03-gc-memory.md`. **Resolved in Phase 1** (`src/value.zig`,
`src/object.zig`): the tag is coarse — `nil`/`boolean`/`int`/`float`/`heap_ref`
— with the concrete heap kind in the header (one source of truth); promoting hot
heap kinds to value-level tags is a later optimisation, like NaN-boxing.

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

Bring-up plan (don't block lune on tooling) — **updated now that binschema has a
Zig backend** (it did not when this section was first written, which is why it
once planned a hand-written Zig writer; that's superseded):

- **Schema is the source of truth** for the wire format — versioned, documented.
  Lives in the lune repo at `schema/trace.json` (revisit moving it into the
  canonical `binschema` dir if other projects ever need it).
- **Zig encoder/decoder: generated** from the schema by binschema's Zig backend
  (`tools/regen-trace-schema.sh`) and **vendored** under `src/gen/` — committed,
  so the build needs no binschema checkout. lune never hand-writes encode/decode;
  it only *maps* `trace.Trace` ↔ the generated structs (`src/traceser.zig`).
- **TypeScript decoder: generated** from the same schema and **vendored** under
  `viz/src/gen/` (the same `tools/regen-trace-schema.sh` emits both Zig and TS
  from `schema/trace.json`) — **landed in Phase 7** with the visualiser. The TS
  decoder and Zig encoder are validated against each other via a committed
  cross-language fixture: `viz/fixtures/counting-loop.lunetrace` is Zig-encoded by
  `lune --emit-traces`, then decoded and asserted by `viz` `bun test` (including a
  `traceToText` rendering that matches `--dump-traces`), keeping the schema the
  single source of truth.

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
assert identical observable behavior. The same idea extends *across engines*: the
VM compiled to wasm and the native binary must produce byte-identical
keyframe/effect/trace output for any deterministic program — two independent
codegen backends agreeing is a stronger determinism check than two native runs
(see `02-determinism.md`'s cross-engine differential validator). binschema's
cross-language fixtures police the trace writer / decoder pair.

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
