# 73 — Coroutines, and async on top of them — Design

Status: partial — P0, P1, P3, P4a and P4b landed (resume/yield on separate
stacks, stops and keyframes inside coroutines, the whole library including
`wrap` and native bodies, the stack pool and its GC weight, coroutines in
the step debugger, `async function`/`await` over a task library, the C
API's host operations); the JIT boundary and the VM's own async functions
(P4c) outstanding.
Every open question decided 2026-10-26 (Q1: §4.2).
Owner: claude (coral-marten)
Last updated: 2026-10-27

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole phases to Done once everything inside them is checked.

### Done

- [x] **Q1 — direction** (§4.2): decided 2026-10-26 — one internal
  mechanism (a delimiter per reserved stack, a tagged suspend to the nearest
  matching one); public surface only Lua's coroutines plus `async`/`await`.
- [x] **Q1 research round 1** (§4.1): Codex and Antigravity surveyed
  single-model designs; reports in `docs/reviews/doc73/`.
- [x] **Q2 — the stack model** (§5): decided 2026-10-26 — option 5.3, a
  stack per coroutine in reserved address space.
- [x] **Q2 on wasm32** (§5): decided 2026-10-26 — the browser VM uses the
  same model and simply holds more memory.
- [x] **Q3 — yielding across an embedder host function** (§6.3): decided
  2026-10-26 — raise Lua's "attempt to yield across a C-call boundary"
  first; a continuation form of the C API maybe later.
- [x] **Q4 — the async surface** (§7): decided 2026-10-26 — `async
  function` / `await` syntax compiling to library calls.
- [x] **Async start** (§7): decided 2026-10-26 — a task starts at the call;
  awaiting a finished task continues at once.
- [x] **Async error timing** (§7): decided 2026-10-26 — as in Lua's
  coroutines, an error surfaces from whatever was running the task's code.
- [x] **Unobserved task errors** (§7): decided 2026-10-26 — fatal unless a
  handler is registered, judged when the scheduler goes idle.
- [x] **P0a — `Vm.frames` behind a pointer** (§5.1): 4e37dfd. t0 cost
  recursive-fib +1.23%, binary-trees/spectral-norm +0.6% instructions;
  accepted by Bart.
- [x] **P0b — the main stack as a `coroutine.Stack`, `SavedContext`, the
  `thread` object and the GC walk of suspended stacks** (§5.1): 9dbdc0b,
  62487c9.
- [x] **P0c — the switch** (§5.1, §6.3): `resume`/`yield` switch stacks in
  the dispatch loop (`opEntry` → `enterResume`/`enterYield`, a coroutine's
  bottom return through `opCoroutineReturn`); a resume from Zig
  (`Vm.resumeSync`, e.g. inside a `sort` comparator) runs a nested loop;
  errors kill the coroutine and return `false, err`; yielding across a Zig
  frame raises Lua's message. A/B: ±0.9%, the outliers (str_gsub +0.7%)
  reproduce from object-id shifts alone (identical code, identical
  allocations).
- [x] **P1 (most) — `coroutine.create`, `resume`, `yield`, `status` (incl.
  `"normal"`), `running` (with a main-thread object), `isyieldable`,
  `close`** with Lua's messages; `src/interp_coroutine_test.zig`.
- [x] **Keyframes carry coroutines** (§6.2), snapshot format 13: a
  `HeapThread` record per coroutine (kind, status, body, resumer, death,
  resume/yield wiring) holding a stack that isn't running as a
  `ThreadContext`, captured and restored with that stack loaded, under the
  collector's keep set. Capture refuses while a coroutine runs, so every
  captured one is suspended or dead. Every-cut resume test, malformed-record
  rejections, a wasm ≡ native viz case.
- [x] **A stop inside a coroutine** (§6.2), snapshot format 14: a suspend may
  land in a coroutine (not in one resumed from Zig, whose Zig frame can't be
  resumed); `exec` continues it; the keyframe names the running coroutine
  (`current_id`) and carries the main stack as `main_context`, with the
  running and normal coroutines' resumer chain and wiring, validated on
  restore. Every-cut tests through nested coroutines.
- [x] **The stack pool** (§5.1): one page-aligned block per stack (scratch,
  payloads, tags, frames carved from it), a pool of at most 16 released
  blocks in the heap (`stack_mem.Pool`, the OS call behind one wrapper,
  Rule Z-2), and `trim` after every sweep handing the blocks pooled since
  the last one back with `madvise(MADV_DONTNEED)` (Linux, Darwin; Windows
  and wasm32 keep them, TODO.md). `co_churn` 341 → 7.9 ms (the mmap/munmap
  and page faults per coroutine were ~47% kernel time), `co_many` 110 →
  76 ms.
- [x] **Benchmarks** (Rule #20): `bench/stdlib/co_pingpong.lua` (switch
  throughput at depth 1/20/150, as `co_pingpong`, `_d20`, `_d150`; the
  runner now reads every `@bench` line of a file), `co_many.lua` (10k live
  shallow coroutines), `co_churn.lua` (create/run/drop churn). First board
  (ReleaseFast, 5 reps, t0 / jit / LuaJIT ms): pingpong 18.0 / 19.4 / 7.2,
  d20 95.7 / 302.7 / 17.0, d150 610.4 / 2193.7 / 75.4, many 76.4 / 76.2 /
  3.0 at 164 MB (LuaJIT 7.6 MB: the floor of a page per region per live
  stack, TODO.md), churn 7.9 / 7.9 / 6.3.

- [x] **GC weight for a thread's stack** (§5.1): a coroutine holding a
  stack charges the heap `Stack.gc_units` pacing units (its committed floor
  over `gc.nominal_object_bytes` = 256, a typical object's footprint),
  refunded when the stack is released. The collector paces on
  `gc_target`, and the threshold the JIT's budget guard reads is derived as
  `next_gc = gc_target -| stack_debt`. Keyframes carry `gc_target`
  (format 15). Before: 150k dropped suspended coroutines over 200k live
  tables peaked at 1.7 GB (LuaJIT 39 MB); after, 105 MB at 1.35 s vs 1.00 s
  (`bench/stdlib/co_garbage.lua`). Suite instruction counts ±0.01%, except
  co_many +1.2% and co_churn +2.0% (earlier collections).
- [x] **Liveness masks for suspended frames** (§6.1): `walkSavedStack`
  loads each stack that isn't running and runs doc 61's `fillKeep` over
  it. Safety builds also assert every saved frame's shape
  (`assertFrameShapesKnown`), which the GC-stress test legs exercise.
- [x] **Restore recompiles the program** (doc 04 F2b follow-up): found
  here. Resumed runs that collected diverged because the restored VM
  borrowed the compile heap's literals.
- [x] **Native coroutine bodies** (extended beyond the original plan):
  `coroutine.create(print)` runs as in Lua. A native body runs under a
  one-line Lua shim, `return function(f, ...) return f(...) end`
  (`coroutine.native_body_source`), compiled once per VM under a reserved
  proto id, so a native that switches (`yield`, `pcall`, `resume`) does so
  from a Lua frame and the saved stack keeps only Lua frames. A fresh shim
  closure per coroutine; keyframe restore rebuilds the shim from its id.
  Bad-argument messages from a native with no Lua call site now name it
  as Lua's `pushglobalfuncname` does (`'io.open'`, `'?'` for a file
  method), by searching `package.loaded`, which also gained its missing
  `coroutine` entry. Every-cut resume test with native bodies suspended.
- [x] **P1 remainder — `coroutine.wrap`** (§4.2): Bart chose (2026-10-27)
  natives with bound values, Lua's C closures, over a Lua shim closure or a
  callable table. `function.Native.bound` holds them (a trailing
  allocation, as `Closure.upvalues`), the collector marks them, and a
  running native reads its own through `Vm.calledNative` (Lua's
  `ci->func`: the unparked native, or the callee of the top frame's call),
  so no call path changed. A wrap function signals `error.ActivateWrap`:
  `enterWrap` resumes its bound coroutine through the same switch as
  `resume`, flagging it `wrapped` so its results come without `true`, and
  an error that kills it is raised again at the call (`raiseWrapped`, with
  `auxwrap`'s location for a string); from Zig, `wrapSync`. Keyframes
  format 16: `HeapNative.bound`, checked on restore against the registry
  row's `bound` count and `bound_ok`, and `HeapThread.wrapped`. Tests
  against Lua 5.4.6 output on every tier, every-cut resume, malformed
  records, a wasm ≡ native case. The same primitive can carry gmatch's and
  codes' iterator state (TODO.md).
- [x] **P3 — the visualiser** (§6.5): a replay step's call chain goes on
  from the running coroutine through every resumer stopped at its resume
  (`Vm.backtraceFrames(.chain)`; each `FaultFrame` carries its stack's
  thread id), and the panel tags each coroutine's run and marks the
  resume. The suspended coroutines are listed with their chains
  (`Vm.suspendedCoroutines`; the wasm `ReplayResult.coroutines` blob), a
  not-started one at its body's first instruction. A native body's shim
  frame is the native to Lua: no step stops in it (`canSuspendHere`), and
  a traceback names it `[C]: in function 'pcall'`, as Lua does.
  `describeFault` and `debug.traceback` stay on the running stack, as
  Lua's tracebacks do. Tests: a Zig replay test over every stop of a
  nested program, a wasm test, `chainSegments`.
- [x] **P4 decisions — §7.1 A1–A4**: decided 2026-10-27 (§7.2).
- [x] **P4a — `async function`, `await` and the task library** (§7.3):
  reserved words, the `intrinsic` op, `stdlib/task.lua` loaded on first
  use, the drain after the main chunk as the main stack's bottom frame,
  snapshot format 17 (`task_lib_id`); tests on every leg
  (`interp_task_test.zig`), every keyframe cut through waiting tasks and
  the drain, a replay step in a drained task, and the parser's.
- [x] **P5 (async, P4a part) — docs**: `docs/differences-from-lua.md`
  (the reserved words and the syntax), the viz editor's keywords.
- [x] **P4b — host operations in the C API** (§7.5): `MH_WAITING`,
  `mh_set_wait_fn`, `mh_pending_new`/`mh_pending_settle`, `mh_tasks_run`,
  `mh_task_result`; the library counts operations in flight and waits on
  the host (`task.host_wait`, `Vm.host_wait`) instead of dropping tasks;
  entries run as tasks when the chunk uses async (`Chunk.uses_tasks`) or,
  for `mh_call`, once the library is loaded, unless a wait callback is
  registered; `mh_run`/`mh_eval` drain. Tests in `capi_task_test.zig` and
  the C smoke test; `mahina-sys` mirrors it.
- [x] **P5 (async, P4b part) — docs**: `include/mahina.h`'s TASKS block,
  doc 59 §3.10.
- [x] **P5 (coroutines) — docs and inventory**: the inventory rows and
  `docs/differences-from-lua.md` track the library; doc 00's Non-goal,
  its decision row and guiding principles, and doc 02's Non-goal and
  "Host-mediated suspension" got follow-up paragraphs (2026-10-27).

### Outstanding

- [ ] **Coroutine stacks' committed floor**: ~16 KiB per live coroutine
  (a page per region) against LuaJIT's ~1 KiB; `co_many` 164 MB vs 7.4 MB,
  and with it the GC weight below (TODO.md).
- [ ] **P2 — the JIT boundary** (§6.4): a switch ends a trace; traces inside a
  coroutine body run as usual. Evidence from the first board: with the yield
  made 20 or 150 calls deep, `--jit-native` is 3.2–3.6× slower than t0
  (302.7 vs 95.7 ms, 2193.7 vs 610.4 ms) at ~41–46% residency.
- [ ] **P4c — async copies of the blocking functions** (§7.2 A1, §7.4): a
  timer and file reads/writes in a module of their own, on a worker-thread
  pool in the CLI, each completion a logged effect (effect format 8), and
  the CLI's `Vm.host_wait`.
- [ ] **The Rust crate's task API**: `mahina` maps `MH_WAITING` to an
  `Error::Api` saying it can't continue the task; a safe surface over
  §7.5's functions is its own design (TODO.md).
- [ ] **P5 — docs for the async layer, remainder**: P4c's module in
  `docs/differences-from-lua.md` and the inventory.
- [ ] **Traces over `intrinsic`**: the recorder doesn't know the op
  (`nyi_opcode`), so a loop that calls an async function or awaits never
  traces in its own frame. Performance work, deferred with P2 (TODO.md).

## 1. Why this exists

`coroutine` is `nil` in mahina. The inventory marks all eight functions
`excluded` and doc 00 lists general coroutines as a Non-goal "plausibly
forever", to be replaced by "stackless generators, host-mediated `await`, and
host-owned tasks" (doc 00 Non-goals; doc 02 "Host-mediated suspension"). None
of the replacement was ever built, so today a Lua program that uses
coroutines — generators written with `coroutine.wrap`, state machines,
producer/consumer pipelines, libraries such as copas — simply fails, and
`docs/differences-from-lua.md` has to say the feature is missing.

Bart (2026-10-25): either build the replacement, so the functionality exists
in another form, or implement coroutines and an easier async form for
functions on the same primitives.

## 2. Doc 00's objections, re-examined

Doc 00 gave three reasons. Each looks different now.

1. **"They abort traces (a stack switch mid-trace)."** LuaJIT does not record
   across `resume`/`yield` either: `coroutine.resume` and `yield` are
   `LJLIB_ASM` fast functions with no recorder, so a trace that reaches one
   stops there (`lib_base.c:611-643`; the recorder only specialises
   `coroutine.wrap`'s aux function as a callee, `lj_record.c:810`). Loops
   inside a coroutine body trace normally. A switch being a trace barrier is
   what LuaJIT ships with, not a blocker.
2. **"They complicate replay scheduling."** Lua coroutines have no
   scheduler. Which coroutine runs is decided by the program's own
   `resume` calls, so a run is exactly as deterministic as one without
   coroutines and records no new effects. The scheduling concern belongs to
   host-scheduled *tasks* (§7), where the host picks the order; that is
   where effects are needed.
3. **"They yield across host frames badly in an embedded VM."** Lua 5.4 says
   "attempt to yield across a C-call boundary" when a C function without a
   continuation is in the way. mahina's own re-entries (metamethods,
   `pcall`, `table.sort`, `gsub`, `require`) are exactly what doc 68 is
   turning into continuation frames so the VM can stop anywhere. Once a site
   is converted, a yield passes through it like a step-debugger stop does.
   Only embedder host functions remain (§6.3).

What does remain hard is real engineering, not a wall: the stack model
(§5), GC roots and keyframes for suspended stacks (§6), and the visualiser.

## 3. Goals

- Lua 5.4's `coroutine` library with Lua's semantics, so existing Lua code
  runs (if Q1 picks it).
- Deterministic by construction; byte-identical across the 8 modes; replay
  and keyframes work with coroutines alive, including a stop inside one.
- No cost to programs that don't use coroutines (a switch may be slow-ish; a
  call must not get slower).

## 4. Options for the direction (Q1)

1. **Lua 5.4 coroutines.** `create`/`resume`/`yield`/`wrap`/`status`/
   `running`/`isyieldable`/`close`, stackful: a yield may come from any depth
   of Lua calls inside the coroutine. Existing Lua code runs unchanged.
2. **Stackless generators only.** New syntax (say `function*` and `yield`),
   yield only from the generator's own body, like Python and JavaScript.
   Suspending saves one frame. Not Lua-compatible: `coroutine` stays absent
   and Lua code still fails.
3. **Lua 5.4 coroutines plus an async layer** (§7). The coroutine is the
   primitive; `async`/`await` and host-owned tasks are a library (or thin
   syntax) over it, with the host's scheduling choices logged as effects.
4. **A single model: one-shot effect handlers or tagged delimited
   suspension** (added 2026-10-26). A function performs a named operation;
   the nearest enclosing delimiter for that tag receives it with a
   continuation it may resume once. Lua's `coroutine` library, generators,
   `async`/`await` and host waits are all surfaces over it. OCaml 5 is the
   reference example, not a limit (§4.1).

### 4.1 Research round 1 (2026-10-26)

Bart leaned to option 4 and asked Codex and Antigravity for a survey
(`docs/reviews/doc73/codex-research-r1.md`,
`docs/reviews/doc73/antigravity-research-r1.md`). Where they agree:

- Multi-shot continuations and stackless state machines are out: the first
  duplicates resources and breaks replay bookkeeping, the second can't
  yield through ordinary Lua calls.
- Asymmetric coroutines and one-shot delimited continuations are equally
  expressive (Moura & Ierusalimschy, "Revisiting Coroutines", 2009); the
  choice is about targeting, composition and cost.
- Tagged delimiters solve the case plain coroutines get wrong: an `await`
  inside a coroutine (or an iterator built on one) must reach the task's
  scheduler, not come out of the inner `coroutine.resume` as an ordinary
  yield.
- Switches are trace barriers; loops inside a body trace as today.
- The debugger stop shares the saved state but stays a privileged VM event
  that guest handlers can't intercept.

Where they differ:

- **Codex** recommends tagged one-shot delimited suspension as the core,
  with each handler body on its own reserved stack segment, so capture
  never copies or moves registers. Its cost is more segments than
  coroutines when handlers nest.
- **Antigravity** recommends asymmetric fibers with tagged yields as the
  core, prompt tags kept as an internal hook, and rejects general effect
  handlers: a handler either needs its own fiber (nested handlers use up
  stacks) or forces frames to be copied, against Q2.

The two agree on the mechanism: a delimiter per reserved stack, with a
tagged suspend that finds the nearest matching ancestor. They differ on
whether to expose it as general handlers. Codex adds points neither draft
had: `coroutine.close` must close open upvalues into the coroutine (not
just mark it dead); a closure can hold an open upvalue into a suspended
coroutine whose handle is unreachable, so the stack must stay alive or be
closed first; and GC and keyframes belong in the first slice, not a later
phase.

### 4.2 Decision (Bart, 2026-10-26)

One internal mechanism, two public surfaces. Each coroutine and each task
runs on its own reserved stack (§5) with a delimiter carrying a tag. A
suspend names a tag and goes to the nearest enclosing delimiter that
matches: `coroutine.yield` to its coroutine's private tag, `await` to the
scheduler's. Lua code sees only the `coroutine` library and `async`/`await`;
general effect handlers (`perform`/`handle`) are not exposed. Because they
would be a surface over the same mechanism, exposing them later needs no
change underneath.

## 5. The stack model (Q2)

Today one VM owns one register file (`Vm.tags`/`Vm.payloads`, 64 Ki slots,
~576 KiB, fixed so frame windows keep stable addresses) and an inline
`frames: [200]CallFrame`. Native code receives the register base as an
entry argument rather than baking its address (no `tags.ptr` immediates in
`nativegen_*`), and `hostcall_x64.S` reads `Vm.frames` at a checked offset.

1. **A stack per coroutine.** Each coroutine owns a register file and frame
   array; `resume` swaps the active ones. Lua 5.4 and LuaJIT do this
   (a `lua_State` per thread). Costs: `Vm.frames` becomes a pointer (one
   more load on call/return paths, and new offsets for the asm); stacks must
   start small and grow, which breaks today's stable-address windows, so
   growth needs Lua's relocation pass (`luaD_reallocstack`) over frame bases
   and open upvalues.
2. **One stack; suspended coroutines copied out.** A coroutine runs on the
   VM stack directly above its resumer. `yield` copies its frames and
   register windows into the coroutine's heap object; `resume` copies them
   back above the new resumer and rebases them. Prior art: Java's virtual
   threads (Loom) copy frames to the heap on yield. Cost per switch is
   proportional to the coroutine's live stack, typically a frame or two for
   generators; the call path is untouched and windows stay stable while
   running. Open upvalues pointing into the copied range must be rebased or
   closed into the heap object.
3. **A stack per coroutine in reserved address space** (added 2026-10-26).
   Each coroutine reserves the full stack size as virtual memory, and pages
   commit when touched; freed stacks are pooled. Addresses never move, so
   there is no relocation pass, and a switch stays a pointer swap. Costs: a
   reservation per new stack (mmap, or VirtualAlloc behind one wrapper, Rule
   Z-2), address space per live coroutine, and the same extra `Vm.frames`
   load on calls as 5.1.

**Decided (Bart, 2026-10-26): option 3.** wasm32 has no
reserve-then-commit, so in the browser VM every stack is fully committed
linear memory. Decided the same day: that's acceptable; the browser build
uses the same model and holds more memory.

### 5.1 The runtime under option 3 (P0 design, 2026-10-26)

Mapped from the tree (`interp.zig` field and line refs as of 4e37dfd).

**What a stack is.** One allocation per coroutine, through the injected
allocator (Rule Z-4): the tag lane (`stack_slots` u8), the payload lane
(`stack_slots` u64), its own `boundary_scratch` (`stack_slots` Value) and a
`[max_call_depth]CallFrame` array, ~1.6 MiB of address space. A large
allocation is an mmap on every real backing allocator, so pages commit when
touched and nothing moves. The scratch lane must be per stack: it is
absolute-indexed like the registers, and a native that re-enters Lua (a
`table.sort` comparator, a metamethod) can resume a coroutine whose natives
would otherwise write over the resumer's live scratch at the same indices.
Freed stacks go to a bounded pool; a pooled stack's pages are returned to
the OS behind one wrapper (`madvise(MADV_DONTNEED)` on POSIX, nothing on
wasm32), so a burst of coroutines doesn't stay committed.

**Active fields stay in `Vm`.** The hot path keeps reading `self.depth`,
`self.tags`, `self.frames` and so on; a switch saves them into the outgoing
thread object and loads the incoming one's. The saved set is one struct,
`SavedContext`, whose field names and types are checked at comptime against
`Vm`, and save/load copy it field by field (`inline for`), so a field
can't be forgotten: `tags`, `payloads`, `boundary_scratch`, `frames`,
`depth`, `stack_top`, `reg_top`, `open_upvalues`, `open_upvalue_ceiling`,
`final_cut`, `native_reentry_depth`. At a switch these must be idle and are
asserted, not saved: `reg_top_pending`, `pending_error`, `unparked_native`.
Per-VM and unchanged: `host_out`/`host_out_top` (a LIFO stack, and resumes
nest LIFO), `gc_keep` (scratch for one walk), `next_call_seq`, heap,
globals, trace state.

**A switch happens in the dispatch loop, never in a Zig frame.**
`coroutine.resume` and `coroutine.yield` are natives that return a switch
request through the cold native-failure path, as `pcall` of a Lua function
already does (`opProtectedEntry`). The dispatcher saves the outgoing
context, loads the incoming one and continues at its top frame. A native
that re-enters Lua runs a nested `execImpl`; a resume inside it switches
inside that nested loop, and the coroutine yields back to it before the
native returns (a yield that would cross the native raises "attempt to
yield across a C-call boundary").

**Bottom of a coroutine.** `ExecState.stop_depth` is swapped with the
context: a coroutine runs with stop depth 0 at its base frame, and the
resumer's stop depth is saved in the thread object. The existing
`depth == stop_depth` boundary test in `opRet` therefore catches a
coroutine's final return with no new check on the return path; the
boundary's (cold) handler tells a coroutine base from a nested-exec stop
and switches back. The same swap stops a coroutine's depth from matching a
nested exec's stop depth by coincidence.

**Errors.** An error unwinds the coroutine's frames to its protect tags as
today; reaching the coroutine's base kills it (status `dead`, error kept for
`close`) and switches to the resumer, where `resume` returns `false, err`
and `wrap` re-raises.

**Open upvalues.** A cell keeps raw lane pointers; with stacks that never
move these stay valid while a coroutine is suspended. Each context keeps its
own `open_upvalues` list. A cell must also name its stack: `loc.open` is an
index, and `upvalueSlotAliasOk` (interp.zig ~1565) compares indices as if
there were one slab; it gains a stack identity. `coroutine.close` and
collecting a dead coroutine close its cells first.

**GC.** Every reachable thread's saved stack is walked like the active one:
`fillKeep` over that stack's frames with doc 61's masks, reusing `gc_keep`
one stack at a time. Threads are ordinary GC objects; the active chain
(running thread and its resumers) is rooted from `Vm`.

**Keyframes.** The schema gains a thread record per live coroutine (status,
resumer, saved frames, stack values, open upvalues) and the active thread
id; `snapshot_format_version` bumps.

## 6. What every option must handle

### 6.1 GC

A suspended coroutine's registers are roots. Under option 5.1 they are a
second stack to walk with doc 61's liveness masks; under 5.2 they are the
heap object's saved windows, walked with the same masks at their saved PCs.

### 6.2 Keyframes and replay

A keyframe carries every live coroutine (its status, frames and registers),
so restore → resume is exact. The step debugger's stop (doc 68) may land
inside a coroutine; capture must then record which stack is active.

### 6.3 Embedder host functions (Q3)

A yield with an embedder host function between the yield and its `resume`:
raise Lua's "attempt to yield across a C-call boundary", or add a
continuation form to the C API (Lua's `lua_yieldk`/`lua_callk`). Lua's error
is the smaller first step.

**Decided (Bart, 2026-10-26):** the error first.

### 6.4 The JIT

`resume` and `yield` are trace barriers (as in LuaJIT); `wrap`'s function
is a known native callee. Traces inside a coroutine body need the active
stack's base, which they already receive as an argument. Side exits and
deopts restore into the active coroutine's frames.

### 6.5 The visualiser

The frame view shows the active coroutine's stack and lists suspended ones;
a step into `resume` moves to the coroutine's stack.

As built (2026-10-27): the step into `resume` needed nothing, since a stop
inside a coroutine already captures its stack as the keyframe's live one,
so the locals and bytecode views follow it. The call chain shows more
than the active stack: it continues through the resumers, because a
coroutine's frames alone don't say who is waiting on it. Lua's own
tracebacks stop at the coroutine's body, so `debug.traceback` and the
uncaught-error traceback still do. The suspended list comes from the VM
(a heap walk per replay step), not from decoding the keyframe in the
viz, so the leaf-versus-call-site rule for each frame stays in one place.
It can list a coroutine that is already garbage, until the next
collection frees it.

## 7. The async layer (Q4, option 4.3)

Built on the coroutine primitive, not beside it:

- An async function is a coroutine; `await x` yields `x` to the scheduler.
- The scheduler is host-owned. Which task resumes next, and with what value,
  is an input from the host, so each resume is a logged effect; replay
  feeds the order back. Coroutines the program resumes itself log nothing.
- Surface options: library only (`task.spawn(f)`, `task.await(x)`), or
  `async function` / `await` syntax compiling to the same calls. Syntax is
  a divergence from Lua that code would have to opt into.

**Decided (Bart, 2026-10-26):** syntax, compiling to the library calls.
Decided the same day: calling an async function starts its task at once
and runs it to its first `await` that must wait (as C#, JavaScript and
Kotlin's `async {}` do; Python coroutines and Rust futures wait to be
awaited or polled). Awaiting a task that has already finished continues at
once, with no switch (C#'s completed-task fast path; JavaScript instead
always defers to a microtask).

Errors, decided the same day, follow Lua's coroutines (an error comes out
of the `resume` that ran the failing code). Before its first waiting
`await` the task runs inside the async call, so an error there is raised
at the call, as `coroutine.wrap` re-raises it. After that the scheduler is
running the task, so the error is stored in the task and raised at each
`await` of it. A failed task that nothing awaits is a fatal error unless a
handler for unobserved task errors is registered. When "nothing awaits"
is judged: decided the same day — when the scheduler goes idle (no task
can run). GC reachability was never an option: collection timing must not
change program behaviour.

### 7.1 P4 design draft (2026-10-27): what is still open

The tree has no way for anything to wait today: a host function is
synchronous (`capi.zig` `cHostCall`), a yield across one is an error, and
the CLI has no sleep and no event loop. So a task can only ever wait on
another task, and the first await of one that must wait needs something at
the bottom that completes later. The pieces below are settled by §7; the
questions after them are not.

Settled shape:

- `async function f(...) ... end` (and `local async function`, and the
  expression form) compiles to a function that makes a task, a coroutine
  running the body, and resumes it at once (§7). The call returns the
  task.
- `await e` is a prefix operator at unary precedence (`parser.zig`
  `parseUnary`) that compiles to the library's await call. Awaiting a
  finished task returns its results (or raises its error) with no switch;
  awaiting a pending one inside a task yields to the scheduler with what
  it waits on.
- The scheduler runs ready tasks first in, first out; which waiting task
  becomes ready, and when, follows from completions. Only a completion
  that comes from outside the VM is nondeterministic, so only that is a
  logged effect (a new `EffectKind`, effect format 8). Tasks that wait
  only on tasks log nothing, which is §7's "coroutines the program resumes
  itself log nothing" carried over.
- An error before the first waiting await is raised at the async call;
  after it, stored and raised at each await; a failed task never awaited
  when the scheduler goes idle is fatal unless a handler is registered.

Open:

- **A1 — what can be awaited, so what can be pending.** (a) Tasks only,
  plus a `task.yield()` that lets the other ready tasks run: no host
  waits, nothing to log in v1, and a CLI program can't wait on time or
  I/O. (b) Tasks and *host pendings*: a host function returns a pending
  value it completes later (`mh_pending_new` / `mh_pending_resolve` in
  the C API, doc 59), the completion order logged; the CLI gets one
  primitive to wait on, a timer (`task.sleep(seconds)`). (c) (b) plus
  async CLI I/O (`io` reads that don't block). Each step is a superset of
  the one before.
- **A2 — `await` outside an async function.** (a) In the main chunk it
  runs the scheduler until what it waits on settles (JavaScript's
  top-level await; the CLI is then the event loop). (b) Only inside an
  async function; the main chunk starts the loop with `task.run(f)`
  (Python's `asyncio.run`). In both, `await` in a plain function inside a
  task is an error, as `yield` across a C boundary is.
- **A3 — the words.** (a) `async` and `await` become reserved words:
  simplest to parse, and a program using either as a name breaks. (b)
  Contextual: `async` only before `function`, `await` only where an
  operand may start and the next token can begin an expression; a name
  `await` keeps working, but `await (x)` is ambiguous with a call and
  needs a rule.
- **A4 — the task library's surface.** At least what the syntax compiles
  to (`task.spawn(f, ...)`, `task.await(t)`) and `task.status(t)`. Open:
  cancellation (`task.cancel(t)`, raising in the task at its await), the
  unobserved-error handler (`task.onerror(h)` in the language, or only a C
  API hook), and combinators (`task.all`, `task.any`), which a program
  can also write itself.

### 7.2 Decisions on §7.1 (Bart, 2026-10-27)

- **A1:** awaiting something outside the VM needs async copies of the
  library functions that block; a task waits on those. So a host pending
  (a value a host function completes later, its completion order the
  logged effect) is the primitive under them.
- **A2:** `await` works anywhere once the VM runs, not only in async
  functions or the main chunk (an ES-module top-level await would come
  to the same thing later). In a task's own coroutine it suspends the
  task; anywhere else it runs the scheduler until what it awaits settles.
- **A3:** `async` and `await` are reserved words.
- **A4:** no extras in v1 (no cancellation, no `task.onerror`, no
  combinators); a follow-up.
- **Tasks:** a library written in mahina over `coroutine.*`, tasks as
  tables; made native only if measurement shows a significant speedup.

Phasing: **P4a** syntax, the task library and its scheduler (tasks wait
only on tasks); **P4b** host pendings (the C API and the effect); **P4c**
the async copies of the blocking functions.

### 7.3 P4a as built (2026-10-27)

- **Syntax.** `async function` (statement, `local`, expression) sets
  `ast.FunctionBody.is_async`; `await e` parses at unary precedence into
  the call `intrinsic(task_await)(e)`, so it gives a call's values and is
  a statement too. The compiler turns an async body into
  `function(...) return intrinsic(task_spawn)(function(params) body end, ...) end`,
  the inner function keeping the declared name for backtraces.
- **`intrinsic a, b`** (new op): `R[a]` = the task library's function `b`
  (`ast.Intrinsic`). A program can't rebind what it names, as it could a
  global.
- **The library** is `src/stdlib/task.lua`, compiled the first time an
  `intrinsic` runs, through `load`'s path into `loaded_chunks` (so a
  restore recompiles it), and called with fresh copies of the natives it
  uses. Its protos are flagged `Proto.system`: no replay step stops in
  them, and a backtrace shows each frame as a native row
  (`[C]: in function 'task.wait'`). It returns
  `{spawn, wait, drain, pending, settle}`, held in `Vm.task_lib`, a VM
  root and the keyframe's `task_lib_id` (format 17); a restore re-flags
  the chunk's protos.
- **Tasks** are tables marked by a private key, each running its function
  in a coroutine of its own that yields only from `await`. A task's own
  `coroutine.yield` is an error ("attempt to yield from outside a
  coroutine"), the task's coroutine being the library's. `await` in the
  task's own coroutine suspends it on what it awaits; anywhere else
  (the main chunk, a plain function, a coroutine inside a task) it runs
  ready tasks in place until what it awaits settles, and an empty queue
  then is a deadlock error (after an unobserved failure, which goes
  first). A task can't await itself. Waiters wake first in, first out.
- **The drain.** When the main chunk returns in a VM that loaded the
  library, `Vm.exec` runs the library's drain as the main stack's bottom
  frame, so a step debugger stops in the tasks it runs and a keyframe
  can be cut in it. Drain takes the main chunk's results packed in a
  table and returns them. After the ready tasks it raises the first
  unobserved failure ("unobserved task error: " before a string); tasks
  still waiting are dropped, until P4b gives them something to wait for.
- **What waits, in P4a.** Nothing a program calls can be pending yet, so
  a task only waits on a task that is itself waiting: in practice every
  P4a program runs synchronously. `pending()` / `settle(op, ok, ...)` are
  the host's half (P4b's foundation) and the tests' stand-in for a host,
  not reachable from a program.

### 7.4 Decisions for P4b/P4c (Bart, 2026-10-27)

- **Handing control to the embedder when every task waits on the host:
  both.** A wait callback when the host registered one (the VM calls it,
  blocking, and the host settles operations inside it); otherwise the
  call returns to the host with a "waiting" status and the host continues
  the tasks later.
- **P4c's first async copies:** a timer (sleep) and file reads and
  writes, run on a small pool of worker threads in the CLI, each
  completion a logged effect.
- **Their names:** a module of their own mirroring the blocking functions
  (`aio.sleep(s)`, `aio.read(f, ...)`; the module name is a placeholder
  until P4c lands).

### 7.5 P4b design (2026-10-27), as built below

What is settled by §7.2/§7.4 and the tree:

- **A host operation is the library's `pending` task.** `mh_pending_new`
  makes one and returns it as a value (the host function returns it to the
  program, which awaits it) plus nothing else: the host keeps the value
  with `mh_ref_create`, as any value it holds. `mh_pending_settle(vm,
  op, ok, values, n)` finishes it (`settle`). The library counts the
  operations in flight, so the count is in every keyframe.
- **The C API logs nothing.** An embedder's host functions aren't logged
  today (the C API has no record/replay surface), so their completions
  aren't either; the logged completion is the VM's own operations' (P4c,
  effect format 8).
- **Waiting.** When `wait` or the drain finds no ready task and
  operations are in flight, the library calls a fresh native,
  `host_wait`. With a callback registered (`mh_set_wait_fn`), it calls
  it and the library looks again. Without one, it depends on where the
  wait is (next).

Asked 2026-10-27, since decided:

- **B1 — what can return "waiting" to the host.** Only a task's own
  coroutine can stop and continue later, so the guest must be running in
  a task. (a) Opt-in entry points: `mh_spawn(vm, callee, args, &op)` runs
  a function as a task and returns it; `mh_tasks_run(vm)` runs the ready
  tasks and returns `MH_WAITING` while operations are in flight;
  `mh_run`/`mh_call` are unchanged, and an await in them with nothing
  ready and no callback is an error ("await would block"). No cost for
  ordinary calls. (b) `mh_run`/`mh_eval` run the chunk as a task, so a
  script's top-level await can return `MH_WAITING`; `mh_call` as in (a).
  The chunk then sees itself as a coroutine (`coroutine.running()`). (c)
  Every top-level entry runs as a task: a coroutine per `mh_call`, a cost
  on every embedder call.

  **Decided (Bart, 2026-10-27): (c), gated.** After measuring a task's cost
  (an awaited async call ~480 ns and ~10.2k instructions against 19.5 ns
  for a plain call): `mh_run`/`mh_eval` run as a task when the chunk's code
  uses `async` or `await` (known when it compiles), `mh_call` once the VM
  has loaded the task library.
- **B2 — the drain for embedders.** (a) `mh_run`/`mh_eval` drain as the
  CLI does (ready tasks, then the callback while operations are in
  flight; without a callback the waiting ones stay for `mh_tasks_run`),
  so a script behaves the same embedded; `mh_call` doesn't drain. (b) No
  drain in the C API: tasks run only when the host calls
  `mh_tasks_run`.

  **Decided (Bart, 2026-10-27): (a).**

As built:

- **The library.** `pending` counts an operation in flight and `settle`
  uncounts it; it now checks it is given a pending operation. `tick` runs
  the ready tasks and, while operations are in flight, calls `host_wait`
  (a fresh copy of the manual registry native `task.host_wait`, which
  calls `Vm.host_wait` or returns false): true once nothing is left to
  run, false when tasks wait and the host can't wait. The drain is `tick`.
  `await` outside a task's own coroutine with nothing ready waits on the
  host too, and is "await would block" when it can't. `result(t)` is the
  host's look at a task (true and its results, false and the task, or its
  error raised), `call(f, ...)` runs `f` as a task the host observes, and
  `enter` is `call` followed by `tick`. `interp.Vm.TaskFn` names the
  indices.
- **One refinement of B1:** with a wait callback registered, no entry runs
  as a task. An await anywhere then waits through the callback and every
  entry finishes synchronously, so the per-call task cost buys nothing;
  the gate only applies when an entry might have to stop.
- **`mh_call`** checks `task_lib` before its tail call (one load and
  branch on the fast path) and goes to `hostcallTasks` when it is set.
- **`mh_run`/`mh_eval`** after a chunk that ran as plain code call `tick`
  when the library is loaded, so tasks it started run; ones still waiting
  on the host stay for `mh_tasks_run`.
- **A failing wait callback** raises its `mh_error_set` message where the
  guest awaits, as a host function's failure does. Operations still in
  flight are waited for again at the next drain.

## 8. Open questions for review

- Q1–Q4 above.
- Whether `coroutine.close` should run pending `__close` handlers. mahina
  has no to-be-closed variables yet (doc 65 Defer item), so `close` would
  only mark the coroutine dead.

## 9. References

- Lua 5.4: `ldo.c` (`lua_resume`, `lua_yieldk`, `luaD_reallocstack`),
  `lcorolib.c`.
- LuaJIT: `lib_base.c:595-660`, `lj_record.c:810`, `vm_x64.dasc`
  (`vm_resume`).
- `00-architecture.md` Non-goals; `02-determinism.md` "Host-mediated
  suspension"; `68-nested-suspension.md` (continuation frames);
  `61-gc-liveness-masking.md`; `04-snapshot-replay-schema.md`.
