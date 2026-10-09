# 59 — Embedding mahina in Rust: the C-ABI `libmahina` surface and the `mahina` crate

**Status:** partial — E0 (review), E1/E2 (the Zig C-ABI surface, lib build,
tests), E3/E4 (the Rust crates + `just embed-test` gate) and E5 (boundary
benchmark) landed; E6–E9 deferred by design.
**Owner:** claude (fable)
**Last updated:** 2026-10-09

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole phases to Done once everything inside them is checked.

### Done

- [x] Architectural commitment: first-class embedding API, C-ABI surface,
  host-registered functions, no general FFI
  (`00-architecture.md` §Goals, §Non-goals, §Embedding API).
- [x] Precedent: a working one-shot C-ABI surface over the library run path
  (`src/wasm_entry.zig` — alloc/free discipline, Result blocks, diagnostics).
- [x] Host-injection seams the embedding reuses as-is: `ClockSource`
  (`interp.zig:165`), `RandomSeedSource` (`:175`), `HostEnv` (`:188`),
  `FsSource` (`:211`), `Vm.out` writer.
- [x] Host→guest call path: `Vm.callValue` (`interp.zig:1998`) with its
  rooting/reentrancy contract (`native_reentry_depth`, no-suspend assert).
- [x] Program-image ownership precedent: `vm.loaded_chunks`
  (`stdlib/load.zig:148`, rooted at `interp.zig:2239`) — VM-lifetime Chunk +
  source ownership with `next_proto_id` coordination, built for `load()` and
  reused wholesale by this design (§3.2).
- [x] **E0 — design review.** codex + antigravity reviewed rev 1 (both
  CHANGES REQUESTED); every blocker/should-fix/nit folded into rev 2
  (`docs/reviews/doc59/`).
- [x] **E1 — C-ABI core (`src/capi.zig` + `include/mahina.h` + build).**
  VM lifecycle + config (JIT tri-state), compile/run/eval through
  `loaded_chunks` (`id_base` from `next_proto_id`), the parked-results root
  + generational host-ref registry (both `.gc`-walk-only Vm fields),
  protected-entry error boundary (located messages, boundary restore, fatal
  poisoning on non-catchable), scalars + strings + stable `MH_TYPE_*`
  translation with C-side tag validation, globals get/set, output + warn
  sinks, memory stats, `mh_collect`. `zig build lib` (static + header
  install); Zig unit tests + the compiled-C header smoke test
  (`tests/capi_smoke.c`) both on the `zig build test` gate. Deviation from
  the letter of the plan: the output *callback* and clock/random override
  setters are deferred (internal sinks + real CLI-shaped clock/random
  defaults landed); host entries run the VM as one continuous epoch via
  `callValue` (no per-call trace-cache retirement — the game-loop-friendly
  reading; flagged for the implementation review).
- [x] **E2 — host functions + tables + call-in.** `mh_register_fn` (multi-
  result C signature, `function.HostBinding` owned by the `Native` and
  destroyed at GC, builtin-name collision rejection), `mh_call`,
  `mh_error_set` → located catchable guest errors, table new/get/set/len/
  metatable get/set (metamethod-aware get/set), the materialized-key O(1)/
  step iterator. Tests incl. guest-drops-native destructor, reentrant
  callback (`mh_call` from inside a host fn), vm-free-during-callback
  refusal, bad-tag rejection. Mode refusals (`.record`/`.replay`/capture
  with host fns) are NOT yet wired — effects are plain `.off` in embedding
  and nothing exposes mode switching through the C API yet; the refusal
  belongs with whatever first exposes those modes (tracked under E6/E8).
- [x] **E3 — `mahina-sys` crate.** Hand-written extern decls mirroring
  `mahina.h` (`embed/rust/mahina-sys`); `build.rs` (PROFILE→optimize mapping,
  `$ZIG` + `.zig-version` drift check, `MAHINA_LIB_DIR` prebuilt override,
  isolated zig cache under `OUT_DIR`); layout tests + a raw-FFI lifecycle
  smoke test. (The compiled **C** header-consumer smoke test landed in E1 as
  `tests/capi_smoke.c` on the `zig build test` gate.) The lib step needed
  `bundle_compiler_rt = true` — a static archive handed to rustc's linker has
  nothing else providing `__zig_probe_stack`.
- [x] **E4 — safe `mahina` crate.** `Vm` (Rc-shared, `!Send`), `Value` with
  auto-reffed heap handles (every heap value crossing out is promoted to a
  generational ref owned by the `Value`; Drop frees it — the C layer's
  borrow window never reaches safe code), `Error` enum with rendered
  messages, `Script`, `Table` + deterministic iterator, closures as host
  functions (`'static` + `catch_unwind` on call AND destroy), foreign-VM
  rejection via `Rc::ptr_eq`. 25 integration tests (both call directions,
  reentrant callback, panic containment, GC stress, ref churn, values
  outliving the `Vm` handle). Gate: `just embed-test` (= Zig gate + `cargo
  test` in `embed/rust`). Deviations: no compile-fail (trybuild) tests — the
  safe layer's auto-ref design removed the borrow contracts they would have
  pinned (nothing borrowed crosses the safe boundary except `Str::as_bytes`,
  whose lifetime ties to the handle by ordinary borrowck); leak checking
  rides the C layer's `TrackingAllocator` tests rather than a Rust-side
  assert.
- [x] **E5 — boundary benchmark.** `examples/boundary_bench.rs`, run via
  `just embed-bench` — informational, never a gate (global Rule #22), manual
  `Instant` timing rather than cargo-bench (no external dev-deps). First
  numbers (ReleaseFast, 2026-10-01): host→guest call 192 ns, guest→host
  callback ~54 ns, table get/set ~60 ns, iteration ~134 ns/entry, ref
  create+drop 28 ns, compile-small-chunk 2.1 µs, eval 1.1 µs. The bench also
  surfaces the designed VM-lifetime chunk ownership (10k compiles retain
  ~35 MiB — same trade-off as guest `load()`, §3.2).
- [x] **E5b — comparative embedding suite (`bench/embed/`),** extended beyond
  the original plan: identical C host programs drive byte-identical guest
  code through mahina's C ABI, LuaJIT, and Lua 5.4 (one `bench_lua.c` for
  both Lua engines; Lua 5.4 fetched+built into a gitignored cache), with
  checksum parity across engines and best-of-N ns/op ratios, run.py-style
  (`just embed-bench`, see `bench/embed/README.md`). First snapshot
  (2026-10-01): mahina C ABI is 1.6–2.1× LuaJIT on call/get/set, 3.4× on
  callback, 3.4×/4.6× on compile/eval, 0.3× (faster) on ref churn; the two
  structural rows are iteration (8.3× — the materialized deterministic
  iterator amortized per entry, §3.4) and peak RSS (chunk retention, §3.2).
  The Rust safe layer's own numbers (`just embed-bench-rust`) sit well above
  the C-ABI column (192 ns vs 28 ns per host→guest call) — the auto-ref
  promotion per crossing heap value is the gap; a candidate E9 refinement.
- [x] **Tier-0 boundary pass (2026-10-01),** profile-driven (perf +
  callgrind), extending beyond the original plan. The big one: loaded-chunk
  constants are now **pinned once** at retention (`Vm.appendLoadedChunk`, the
  single funnel for `load()`/C API/keyframe restore) instead of re-rooted
  every GC cycle — the per-cycle walk over every chunk ever compiled made
  repeated `mh_eval`/`load()` quadratic (4.1 µs/eval and climbing at 500k
  evals; 1.1 µs flat after; liveness identical, `.snapshot` walk unchanged).
  Plus three general cuts: `dropRegionActivation` empty fast path (was a
  hash-map key walk on EVERY tier-0 return), single-copy param bind in
  `callValue` (no-surplus-varargs case), and the results-buffer contract is
  now "undefined beyond `*nresults`" (the nil-fill cost O(max_results)
  stores per call). Small-size boundary rows are ~unchanged — callgrind
  shows 705→651 instructions/call but the path is latency-bound on the
  serial frame→closure→proto→code chain; the remaining ~2× gap to LuaJIT's
  `lua_pcall` lives in the layered entry protocol (mh_call → runProtected →
  callValue → execWith → execImpl → chain), a doc-42-level structural
  question. Language suite: no regressions (flagged rows A/B'd against a
  shadow baseline — noise).
- [x] **Tier-0 entry flattening (2026-10-02),** the follow-up attacking that
  layered-entry chain (Bart: game-engine host, call latency registers).
  Two changes in `src/interp.zig`: (1) `execWithEntry` — `callValue` enters
  the doc-42 dispatch chain directly, building `ExecState` from the
  closure/proto it already holds (pc = 0) instead of re-deriving
  frame→closure→proto→code through `execWith`→`execImpl`; general fallback
  for recording/suspend/mode-switch preserved. (2) `pushFrameTrusted` —
  `callValue`'s closure arms skip the bounds re-checks they just performed
  and the region-context publish the entry re-derives. Measured (2M-call
  probe, x86-64-v3, perf stat -r 9): 295.4M→248.5M cycles (**−15.9%**),
  ~28.5→~24.5 ns/call; cycles fell faster than instructions on step (1),
  confirming the serial-latency diagnosis, after which the path runs at
  ~4.7 IPC (throughput-bound). eval −2.2%, callback −4.1%, table rows
  instruction-identical. The `.call` opcode arm deliberately KEEPS the
  outlined checked push: inlining it there grew the hottest handler and
  cost scalar ~4% wall from pure code placement (fewer instructions, more
  cycles) — reverted, scalar ties baseline, nsieve/recursive-fib tie.
  Remaining gap to LuaJIT's 13 ns `lua_pcall` is now ~1.9×: the surviving
  per-call costs are the mh_call park/validate contract (~109 insns), the
  CallFrame init, `runFastPath`'s 9 scattered flag loads, and the
  copy-in/copy-out loops — candidates: a packed fast-path flag, a
  prepared-call handle (API addition, caches the closure/proto derivation
  for repeated same-callee calls — the game-engine `update()` shape).
- [x] **Boundary pass vs LuaJIT/mlua (2026-10-02),** driven by a call-only
  comparison (TODO.md "Embedding call boundary"): LuaJIT 304 instructions /
  54 cycles per `lua_pcall`, mahina 567 / 119 per `mh_call`, and 0 vs 7.3
  store→load forwarding stalls per call (AMD `ls_bad_status2.stli_other`).
  (1) **No compiler-rt bundle** — reverses E3's `bundle_compiler_rt = true`,
  whose `memset`/`memcpy`/`memmove` replaced the *host process's* libc
  copies with Zig's byte loops (47% of a Rust call). `capi.zig` now exports
  a weak `__zig_probe_stack` for library builds on x86_64; the archive
  imports `mem*`. (2) **Whole-word value writes** — `Value.storeWords`/
  `loadWords` at every capi out-pointer, the park, and `callValue`'s
  copy-out, so a host's 8-byte reads forward. (3) **`FrameResult` packed
  into one `u32`** — `opRet` wrote it as two `u16` halves that `callValue`
  read back whole; the biggest single stall per call. (4) **`runProtected`
  inline.** (5) **The Rust crate on mlua's model** — E9's typed conversion
  traits for calls (`IntoArgs`/`FromResults` over `IntoValue`/`FromValue`:
  scalars, strings, `Option`, handles, tuples to 8, `&[Value]`/`Vec`), no
  callee clone, inline arg slots, uninit result buffer, handles cache their
  raw value (non-moving GC), conversions `#[inline]` and results read as two
  words (an out-of-line conversion or a whole-struct copy each put one more
  stall on the path). Now: C `mh_call` 518 instructions / ~82 cycles; Rust
  typed `i64 -> i64` call 547 / ~94 cycles, **~20 ns** (was 172 ns at the
  start of the day; mlua+LuaJIT 24–26 ns). Measured and left open (TODO.md,
  awaiting Bart): GC-time dead-stack clearing (3 instructions; keyframes
  serialize every register below `stack_top`) and a packed fast-path word
  (≤15 instructions, ~31 write sites to keep in sync).
- [x] **Host results get a private buffer** (2026-10-09, extended beyond the
  original plan; found by the doc 61 P3 audit). §3.5 had the host write
  straight into the call site's result window. That broke the no-alias
  promise: through `pcall`/`xpcall` (results one slot below the args) and
  `__call` (same slot), `results` overlapped `args`. A window past
  `stack_top` was also overwritten by frames a nested `mh_call` laid out.
  Now `Vm.callHostNative` hands every host call its own range of a VM-owned
  stack (`host_out`; nested host calls go above) and copies the results out
  after the host returns. `max_results` is capped at 256
  (`max_host_results`), also when the caller wants every result, so the
  stack is sized for the deepest nesting `max_native_reentry` allows.
  Regression tests are in `capi_test.zig`.
### Outstanding

- [ ] **E6 — host-call record/replay.** Defer. v1 refuses `.record` AND
  `.replay` whenever a host fn is registered (§3.7). A result-only
  `host_call` EffectKind is NOT sufficient (codex #11 — callbacks mutate
  guest state and nest effects); E6 needs its own design doc covering
  callback identity, failure, reentry, and guest-visible mutation.
- [ ] **E7 — buffer leases / typed-array zero-copy.** Defer; separate doc
  per the `00-architecture.md` lease commitment.
- [ ] **E8 — snapshot/restore with host functions.** Defer. Until then:
  registration rejects names that collide with `base_natives`, and keyframe
  **capture** refuses when any host-bound native exists (codex #8 — name
  collision would silently restore the builtin).
- [ ] **E9 — userdata objects, interrupt hook, typed conversion traits.**
  Defer with intent: host userdata with metatables (the "app data lives in
  Rust" story), an instruction-budget interrupt wired to
  `suspend_ctl.after_safepoints`, `IntoValue`/`FromValue` traits, scoped
  (non-`'static`) callbacks. Each is additive on this ABI. (2026-10-02: the
  traits landed for call arguments/results — see the boundary pass above;
  typed *host-function* signatures, still `&[Value] -> Vec<Value>`, remain.)

## 1. Why this exists

mahina's motivating use case was always "a Rust app scripting its tools / UI /
game logic in mahina" (`00-architecture.md` §Goals). The architecture doc
commits to a C-ABI embedding API and sketches its principles, then says "full
design in a later doc" — this is that doc. Today nothing embeds: the only
consumers are the CLI (`src/main.zig`, host-bound) and the browser wasm entry
(`src/wasm_entry.zig`, one-shot run-and-serialize, no persistent VM handle, no
host functions, no value traffic). An embedder cannot hold a VM across calls,
cannot get a value out except as serialized artifacts, cannot register a
function, and has no C header or Rust crate to link against.

The goal shape is what `mlua`/`rlua` give Lua users: create a VM, eval
source, read/write globals, call guest functions with arguments and get
results, register host (Rust) functions callable from the guest, with sound
ownership and GC behaviour on both sides of the boundary.

## 2. What exists today (fact map)

- **The library module is clean.** `src/root.zig` exposes every subsystem;
  nothing in the VM core touches the OS directly — all host access is injected
  (`ClockSource`, `RandomSeedSource`, `HostEnv`, `FsSource`, `Vm.out`), which
  is exactly the seam an embedder needs. `wasm32-freestanding` proves it.
- **`Value` is already C-ABI.** `value.zig:63`: `extern struct { tag: u8 enum,
  payload: 8-byte union }`, 16 bytes. A C mirror struct is layout-identical —
  but the *tag ordinals* stay private (§3.2's stable type enum).
- **The GC is non-moving** (`03-gc-memory.md`, decided direction). Heap
  pointers and string bytes are stable for an object's lifetime — a host ref
  can hand out borrowed `ptr+len` string bytes without copying, valid while
  the ref roots the object.
- **Program images are VM-owned for dynamic code already.** `load()` appends
  to `vm.loaded_chunks` (`stdlib/load.zig:148`): the VM owns the `Chunk` and
  NUL-terminated source until `deinit`, advances `next_proto_id`
  (`interp.zig:751`) so proto IDs stay VM-unique (JIT `guard_func` validates
  by `Proto.id` alone, `irinterp.zig:747`), and roots the chunk's constants
  in both walks (`interp.zig:2239`). Closures hold raw `*const Proto` into
  the chunk arena and `describeFault` reads `proto.source` — so a chunk may
  **never** be freed while the VM lives (codex #1/#2, antigravity #1).
- **Natives are `fn (ctx: *anyopaque, args: []const Value) anyerror!Value`**
  (`function.zig:140`), `ctx` = the `*Vm` at every call site. The heap
  `Native` object (`function.zig:311`) carries nullable
  `effect`/`multi`/`recorded` tags but no per-native userdata, and nothing
  passes the `*Native` identity into the call — host closures need both
  (§3.5). GC treats `.native` as a leaf (`gc.zig:680`): a Native roots
  neither its name bytes nor (today) any binding.
- **Unknown natives are already trace barriers.** `recorded == null` ⇒ the
  recorder aborts a `recCall` with `.host_barrier`
  (`trace_recorder.zig:4101`). Host functions get the architecture's "the
  JIT does not trace through it" property for free; no new JIT work in v1.
- **`Vm.callValue` is the host→guest entry** (`interp.zig:1998`): takes any
  callable `Value`, contiguous args, writes results. Reentrancy-bounded
  (`max_native_reentry`), works mid-native (it exists for `pcall`/`sort`
  comparators). It restores `stack_top` before returning (`interp.zig:2086`),
  so **its results are unrooted the moment it returns** — the parking root
  (§3.3) exists precisely to bridge that.
- **Errors do not unwind.** A fault leaves frames/stack raised for the
  catcher; `Vm.run` refuses a dirty VM (`DirtyTopLevelEntry`,
  `interp.zig:1586`). The protected-entry recipe (capture boundary, render
  while frames are live, close upvalues, drop region activations, restore) is
  `protectedCall` (`stdlib/errors.zig:63`) — capi's entry points mirror it.
- **Keyframe restore resolves natives by registry name** (`keyframeser.zig:
  669` against `interp.base_natives`). An unknown host name fails cleanly
  (`UnknownNative`) — but a host native named like a builtin would silently
  restore AS the builtin, hence §3.7's capture refusal and registration
  collision check.
- **Build:** `std.Build.addLibrary` exists in the pinned toolchain
  (`Build.zig:763`, `LibraryOptions.linkage` static default). `use_llvm =
  true` is required (tail-call dispatch), same as every other artifact.

## 3. Design

### 3.1 Three layers

```
┌────────────────────────────────────────────┐
│ mahina (Rust, safe)      embed/rust/mahina │  Vm, Value, Ref, closures, Result
├────────────────────────────────────────────┤
│ mahina-sys (Rust, raw) embed/rust/mahina-sys │  extern "C" decls, build.rs
├────────────────────────────────────────────┤
│ libmahina.a   src/capi.zig + include/mahina.h │  C ABI, owns all unsafe-Zig
├────────────────────────────────────────────┤
│ mahina library module      src/root.zig …  │  three small seams (§3.2–3.5)
└────────────────────────────────────────────┘
```

`src/capi.zig` is the only file that speaks C ABI (Rule Z-2 spirit). The VM
core gains exactly three seams, all inert for the CLI and wasm, and **none of
them C-typed** (codex #9 — C types stay out of `function.zig`/`interp.zig`):

1. a `host_refs` root list + `parked_results` root list on `Vm`, rooted in
   the `.gc` walk only;
2. a *generic Zig* host binding on `Native` (§3.5) — capi adapts C function
   pointers into it;
3. an embedder-script list that reuses the `loaded_chunks` mechanism (§3.2).

Everything is prefixed `mh_`. The header `include/mahina.h` is hand-written
and is the normative ABI contract; the Rust `-sys` decls mirror it by hand
(no bindgen — small surface, no clang dependency). Drift is caught twice: a
compiled **C** consumer smoke test validates the header itself (codex #15),
and the E4 integration tests validate the Rust decls.

### 3.2 Handle model and ownership

- **`mh_vm`** — opaque pointer. `mh_vm_new(config, *out) -> mh_status` /
  `mh_vm_free(*mh_vm)`. Internally a heap box holding the `Vm`, its
  `TrackingAllocator` (`mem.zig`) over a backing gpa, the last-error buffer,
  the output sink, and bookkeeping. One OS thread at a time; not thread-safe
  (documented; the Rust `Vm` is `!Send + !Sync`). `mh_vm_free` while a host
  callback is on the stack is a checked API error (the handle knows the
  VM's `native_reentry_depth`); the Rust crate makes it unrepresentable.
- **`mh_value`** — a 16-byte by-value struct, layout-identical to
  `value.Value` (comptime-asserted in capi; layout-tested in Rust and the C
  smoke test). **The internal tag ordinals are not ABI** (codex #12,
  antigravity): the public type is
  `mh_type { MH_NIL, MH_BOOL, MH_INT, MH_FLOAT, MH_STRING, MH_TABLE,
  MH_FUNCTION, MH_OTHER }`, read via `mh_value_type(vm, val)`, and all
  constructors/accessors (`mh_nil()`, `mh_int(i64)`, `mh_value_int(val,
  *out)`, …) go through capi translation — the embedder never interprets
  `tag`/`payload` bytes. `row_view` **never crosses the boundary**
  (antigravity #3): `indexGet` already deflates grid rows
  (`interp.zig:7107`), and every capi exit point asserts/deflates;
  `mh_ref_create` rejects it (`MH_ERR_API`).
  Heap-tagged values are **borrowed** and are valid only while one of the
  three roots of §3.3 holds them.
- **`mh_ref`** — a **generational** handle (antigravity #10): a u64 packing
  `{ index: u32, generation: u32 }` into a `Vm`-side `host_refs` slot array
  (`ArrayList` of `{ value: Value, generation: u32 }` + free list; freed
  slots hold `Value.nil()` so the root walk never marks stale pointers).
  `mh_ref_create(vm, val, *out_ref)`, `mh_ref_get(vm, ref, *out_val)`,
  `mh_ref_free(vm, ref)`; a stale generation is `MH_ERR_API`, deterministic,
  never a dangling read. Rooted in `forEachRootHeader`'s **`.gc` walk only**
  — host refs are host state, not guest-deterministic state, so they must
  not perturb the `.snapshot` walk (same split as trace consts,
  `interp.zig:2243`; snapshot bytes stay embedder-invariant).
- **Strings.** In: `mh_str { ptr, len }` borrowed for the call; capi interns
  immediately (same contract as `HostEnv.getenv`). Out:
  `mh_value_str(vm, val, *out_str)` returns borrowed bytes — stable while
  the value is rooted (non-moving GC), so the safe crate ties the borrow to
  the owning `Ref`'s lifetime (codex #12: borrow from the `Ref`, not `'vm`).
- **Scripts.** `mh_compile(vm, src, name, *out_script)` wraps `parser.parse`
  + `compiler.compileWithOptions(…, .{ .id_base = vm.next_proto_id, … })` +
  an append to the VM's loaded-chunk list — **the VM owns the chunk and the
  source copy until `mh_vm_free`**, exactly like `load()` (codex #1/#2,
  antigravity #1: closures hold raw `*Proto` into the chunk arena, JIT
  guards validate by proto id, `describeFault` reads `proto.source`; an
  independently-freed chunk is unsound, and colliding ids are a
  JIT-correctness hole, not just a snapshot one). `mh_script` is therefore a
  small handle box over a VM-owned image; `mh_script_free` frees only the
  handle. The cost — long-lived VMs accumulate compiled images — is the same
  deal `load()` already makes, documented; reclaiming dead images is future
  work shared with `load()`. `mh_run(vm, script, results…)` executes;
  `mh_eval(vm, src, name, results…)` is compile+run in one call (the image
  still parks in the VM, per the above).

### 3.3 Rooting protocol (the boundary's load-bearing piece)

Three roots cover every way a heap value can be live on the host side; all
three are `.gc`-walk-only:

1. **`host_refs`** — explicit, long-lived (§3.2).
2. **`parked_results`** — a `Vm`-side buffer into which capi copies **every
   heap result** it hands out (from `mh_run`/`mh_eval`/`mh_call`/
   `mh_global_get`/`mh_table_get`/iterator steps). Parked values stay rooted
   until the **next capi entry that can allocate or run guest code**, which
   clears the park first. `mh_ref_create` and the pure accessors
   (`mh_value_type`, `mh_value_int`, `mh_value_str`, …) are documented
   non-clearing, so "get results → promote the ones you keep" is race-free
   (codex #3, antigravity #2 — `callValue` unroots its results by restoring
   `stack_top`; "borrowed until next call" only becomes true because this
   park exists).
3. **The callback window** — inside a host callback, `args` live in the
   caller's rooted registers for the duration of the call (the existing
   native contract).

Arguments the host passes IN to `mh_call`/`mh_table_set`/… must be rooted by
the host for the duration of the call (scalars trivially; heap values via a
ref or the park they came from) — capi copies them into rooted VM storage
(registers / the park) before any allocation can fire, mirroring
`callValue`'s own straight-line parking discipline.

### 3.4 Call-in, globals, tables

- **`mh_call(vm, callee, args, nargs, results, max_results, *nresults)`**
  over `Vm.callValue`. Returns the produced count (≤ `max_results`,
  truncation is by-design Lua semantics); `results[*nresults..max_results]`
  are nil-initialized (codex #13). Heap results are parked (§3.3).
  `callValue`'s preconditions hold for top-level and reentrant (inside a
  callback) calls — the same two paths `pcall`/comparators exercise. A
  runtime fault follows §3.6's protected-entry recipe.
- **Globals:** `mh_global_get(vm, name, *out)`, `mh_global_set(vm, name,
  val)` — over `vm.globals`, interned keys, status-returning (every
  allocating entry point is fallible and status-returning; no
  silent-nil-on-OOM anywhere — codex #13).
- **Tables:** `mh_table_new(vm, *out)`, `mh_table_get(vm, tbl, key, *out)`,
  `mh_table_set(vm, tbl, key, val)`, `mh_table_len(vm, tbl, *out)` routed
  through `Vm.indexGet`/`indexSet` (metamethods behave identically to guest
  code; raw variants deferred to E9), **plus** `mh_table_metatable_get/set`
  (antigravity #6 — table stakes for host object wrappers).
- **Iteration:** NOT via the guest `next` (which allocates + sorts the full
  key list **per step**, `stdlib/base.zig:98` — O(n² log n) traversal, codex
  #14 / Rule #20). Instead an iterator handle: `mh_table_iter_new(vm, tbl,
  *out_iter)` materializes the deterministic key order **once** (same
  ordering source as `next`, `key_order.zig`), `mh_table_iter_next(vm, iter,
  *key, *val)` walks it in O(1) amortized per step (keys that vanished
  mid-iteration are skipped; insertion during iteration is not observed —
  documented, deterministic), `mh_table_iter_free`. The iterator roots its
  snapshot keys via the same host-ref machinery.

### 3.5 Call-out: guest → host (registered functions)

The gap: `NativeFn` receives `ctx = *Vm` and `args`, but not which `Native`
is being called, and `Native` carries no userdata. Decision (both reviewers
concur): **option (c)** — extend `Native`, no new heap type, no trampoline
caps — with the review's corrections applied:

- `function.zig` gains a **generic, C-free** seam (codex #9):

  ```zig
  pub const HostFn = *const fn (ctx: ?*anyopaque, vm: *anyopaque,
      args: []const Value, out: []Value) anyerror!usize;
  pub const HostBinding = struct {
      call: HostFn,
      ctx: ?*anyopaque,
      destroy: ?*const fn (?*anyopaque) void,
      /// Owned copy of the registration name (gpa-allocated); `Native.name`
      /// aliases it, so the bytes live exactly as long as the Native.
      name: []u8,
  };
  ```

  `Native` gains `host: ?*HostBinding = null`. **The `Native` owns its
  binding**: `Native.destroy` runs `destroy(ctx)` and frees the binding +
  name (antigravity #4 — a guest dropping the last reference to a
  registered fn must release the Rust closure at GC time, not at
  `mh_vm_free`; antigravity #8 / codex #7 — the name is duped into the
  binding, never a borrowed C pointer, and is not GC-interned so it cannot
  dangle via the string heap). Bindings are individually heap-allocated
  (stable addresses; no ArrayList-element pointers — codex #7). Failed
  registration frees the binding before returning.
- Invariants: `host != null ⇒ recorded == null and effect == null and
  multi == null` (asserted at creation; recorder-opaque ⇒ trace barrier for
  free). The invocation funnels through **one** helper
  (`interp.callNativeInner` or equivalent) used by the dispatch `.call`
  native arm, `callValue`'s `.native` arm, and `performEffect` — so E6
  cannot later miss a path (codex #9).
- Multi-result **from day one** (antigravity #5 — the fn-pointer typedef
  cannot be widened later without an ABI break):

  ```c
  typedef mh_status (*mh_host_fn)(mh_vm *vm, void *userdata,
                                  const mh_value *args, size_t nargs,
                                  mh_value *results, size_t max_results,
                                  size_t *nresults);
  typedef void (*mh_host_fn_destroy)(void *userdata);
  mh_status mh_register_fn(mh_vm *vm, const char *name, /* "mod.field" or bare */
                           mh_host_fn fn, void *userdata,
                           mh_host_fn_destroy destroy /* nullable */);
  ```

  capi adapts this into a `HostBinding` whose `out` slice is the native call
  site's result window (bounded by the VM's existing multi-result plumbing).
- Registration **rejects a name already present in `base_natives`**
  (`MH_ERR_API`) — a collision would make a later keyframe silently restore
  the builtin in its place (codex #8). Re-registering the same host name
  replaces the global binding; previously escaped closures keep the old
  `Native` (and its binding) alive via GC, which is exactly right.
- **Failure semantics** (codex #6): a host fn returning non-OK raises a
  **located guest error** carrying the message set via `mh_error_set(vm,
  str)` (routed through `raiseLocatedError`-style synthesis so `pcall`
  observes the intended message, not a generic `HostError`). OOM and
  replay-integrity errors stay fatal/uncatchable exactly as they are today.
  Panic containment is the Rust layer's job — `catch_unwind` around every
  closure body **and destructor** (codex #6), converting to the error path;
  a panic never crosses the C boundary.

### 3.6 Errors and the protected entry boundary

`mh_status`: `MH_OK`, `MH_ERR_COMPILE`, `MH_ERR_RUNTIME`, `MH_ERR_OOM`,
`MH_ERR_API` (misuse: stale ref, wrong type, VM busy, name collision, …).
Host-fn failure surfaces to the guest per §3.5 and, if uncaught, exits the
C entry as `MH_ERR_RUNTIME`.

**Every C entry that runs guest code is a protected entry** (codex #5): it
captures the VM boundary up front (depth, stack_top, open-upvalue cursor,
region activations — the `protectedCall` recipe, `stdlib/errors.zig:63`),
and on fault: renders diagnostics **while the faulting frames and source are
live** (`describeFault` against the VM-owned script source), then restores
the boundary — closes discarded upvalues, drops region activations, restores
depth/stack/multret state — so the VM is reusable (`Vm.run`'s
`DirtyTopLevelEntry` guard must never see a dirty VM from capi). Rendered
message goes to the per-VM last-error buffer; `mh_last_error(vm) -> mh_str`
borrows it until the next failing call. Diagnostic-allocation failure
degrades to a static message, never to a dirty VM. Structured diagnostics
(spans/backtraces) are additive later — new functions, no ABI change.

### 3.7 Host sources, output, and modes

- `mh_config` is zero-default with **explicit tri-states** where "default
  on" exists (codex #13): e.g. `jit: { MH_DEFAULT = 0, MH_ON, MH_OFF }`.
  JIT default on = the CLI's production shape — `trace.config.enabled/
  execute/optimize` **and `native_codegen`** (codex #15).
- **Output:** `print`/`io.write` → `vm.out`; **`warn` → `vm.err` is captured
  too** (codex #15 — nothing escapes to the process's real stderr). Default:
  internal growable sinks read via `mh_take_output(vm, *out)` /
  `mh_take_warnings(vm, *out)`; or a `write_cb(userdata, bytes, len)` in
  config, adapted behind one `io.Writer` in capi (Rule Z-2).
- **Clock/random:** default to the CLI's real sources (`main.zig:389,393`);
  overridable in config for deterministic embedding.
- **Env/args/fs:** default absent (`EnvUnavailable`/`FsUnavailable` on use);
  setters mirror `HostEnv`/`FsSource` directly.
- **Effect mode:** v1 embeds with `effect_mode = .off`. With ≥1 registered
  host fn, **both `.record` and `.replay` are refused** (codex #10,
  antigravity #9) — at registration time if the mode is already set, at mode
  selection if a host fn exists — and keyframe **capture** is refused too
  (codex #8). E6 (own design doc) lifts this; a result-only `host_call`
  effect kind was reviewed as insufficient (codex #11) and is not the plan
  of record.

### 3.8 Build and crates

- **build.zig:** `b.addLibrary(.{ .linkage = .static, … })` over a `capi`
  module (`src/capi.zig`, imports `mahina`), `use_llvm = true`;
  `installHeader` for `include/mahina.h`; a `zig build lib` step with
  `-Doptimize` pass-through. Shared-lib variant later if needed; static
  first (no soname story, simplest Rust linkage).
- **capi tests:** `src/capi_test.zig` in `zig build test` — lifecycle, eval,
  globals, refs + parked results under forced `Vm.collect`, host fns (incl.
  a guest `t = nil`-drops-the-native destructor test), protected-entry
  reuse-after-error, leak-checked by `std.testing.allocator`. Plus the **C
  consumer smoke test**: a tiny `.c` file compiled and run by the build
  graph against `mahina.h` + `libmahina.a`, static-asserting layout and
  exercising one full lifecycle (codex #15 — validates the header, which
  Zig-side tests cannot).
- **`embed/rust/`** — a cargo workspace (in-repo; a separate repo can come
  with publishing, not before):
  - `mahina-sys`: hand-written extern decls. `build.rs`: honour
    `MAHINA_LIB_DIR` (prebuilt) else invoke zig at the repo root — the zig
    binary from `$ZIG` if set, else `zig` from PATH with its version checked
    against `.zig-version` (fail loudly on drift, Rule Z-1 / antigravity
    #7); map Cargo `PROFILE` → `-Doptimize=` (`debug`→`Debug`,
    `release`→`ReleaseFast`); use an isolated zig cache dir under `OUT_DIR`
    so cargo and direct zig builds never fight (codex #15);
    `cargo:rustc-link-search` + static link.
  - `mahina`: the safe API. `Vm` (owns `*mh_vm`, `Drop` frees, `!Send +
    !Sync`). `Value<'lua>`-style borrows are tied to the **owning `Ref`
    guard**, not just a `'vm` lifetime; every `Ref` carries its `*mh_vm` and
    cross-VM use is a runtime error (`Error::ForeignVm`) since lifetimes
    cannot distinguish two VMs (codex #4). `register_fn` takes `F: Fn(&mut
    Scope, &[Value]) -> Result<Vec<Value>> + 'static` (scoped non-`'static`
    callbacks are E9); `Scope` is the only path to the VM inside a callback,
    so no overlapping `&mut Vm` can exist; `Vm` cannot be dropped during a
    callback by construction (the callback only ever sees `Scope`).
    `catch_unwind` wraps closure bodies and destructors. Compile-fail tests
    pin the borrow contracts; runtime tests pin foreign-VM rejection
    (codex #4).
- **justfile:** `just lib` = `zig build lib`; `just embed-test` = `zig build
  test` + `cargo test` in `embed/rust/` — the gate for every E3+ change.

### 3.9 Performance posture (Rule #20)

Per crossing: one C call, tag translation, and for heap results one
`parked_results` append (amortized). No per-call allocation on the scalar
path; string in-traffic interns (same cost as guest string creation); string
out-traffic is zero-copy borrowed. Table iteration is O(n log n) once +
O(1)/step (§3.4), never `next`'s per-step re-sort. E5 pins: host→guest call
(int args), guest→host callback, table field get, **large-hash-table
iteration, ref churn under GC pressure, repeated compilation** (codex #14's
additions) — cargo bench, informational, not a gating test (Rule #22).
Bulk data stays out of v1; that's E7's lease design, not a per-item API.

## 4. Non-goals (v1)

- **General C FFI from scripts** — permanently out (`00-architecture.md`).
- **Typed-array / buffer leases, zero-copy bulk data** — E7, separate doc.
- **Record/replay through host functions** — E6, behind the loud refusals.
- **Snapshot capture/restore with host natives** — E8, behind the capture
  refusal + registration collision check.
- **Thread-safe / multi-VM-shared anything** — isolate model.
- **Host userdata objects, raw table ops, interrupt hook, scoped callbacks,
  conversion traits** — E9, all additive on this ABI.
- **Publishing the crates** — in-repo workspace only for now.

## 5. Decisions (was: open questions — resolved by the rev-1 reviews)

- **Host binding = option (c)**, with the binding generic-Zig, Native-owned,
  invariant-checked, and funneled through one invocation helper. Both
  reviewers approved (c) and rejected (a) as churn without benefit.
- **`mh_value` = raw 16-byte struct, but the public type surface is the
  translated `MH_TYPE_*` enum**; internal tag ordinals stay private;
  `row_view` never crosses.
- **Borrowed results + the parking root** (not auto-ref): zero mandatory
  free-traffic on the C side, and the park makes the borrow window real
  instead of aspirational. The safe crate promotes to `Ref` automatically.
- **Effect staging:** off by default; record AND replay AND keyframe capture
  refused while host fns exist; E6 gets its own doc.
- **Layout:** in-repo `embed/rust/{mahina-sys,mahina}` workspace.

## 6. References

- `docs/design/00-architecture.md` — §Embedding API, §Goals, §Non-goals.
- `docs/design/02-determinism.md` — effect/record/replay model.
- `docs/design/03-gc-memory.md` — non-moving GC, rooting, chunk rooting.
- `docs/reviews/doc59/codex-rev1.md`, `docs/reviews/doc59/antigravity-rev1.md`
  — the rev-1 reviews this rev folds in.
- `src/wasm_entry.zig` — the existing C-ABI precedent.
- `src/interp.zig` — `Vm`, `callValue`, `forEachRootHeader`, host sources.
- `src/function.zig` — `NativeFn`, `Native`, `EffectKind`.
- `src/stdlib/load.zig`, `src/stdlib/errors.zig` — the ownership and
  protected-call recipes this design reuses.
- LuaJIT/Lua C API + `mlua` — the ergonomic bar for the Rust layer.
