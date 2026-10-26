# 73 — Coroutines, and async on top of them — Design

Status: draft, not yet implemented. Q2–Q4 decided (2026-10-26); Q1 (the
direction) is open after research round 1 (§4.1).
Owner: claude (coral-marten)
Last updated: 2026-10-26

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole phases to Done once everything inside them is checked.

### Done

- [x] **Q2 — the stack model** (§5): decided 2026-10-26 — option 5.3, a
  stack per coroutine in reserved address space.
- [x] **Q3 — yielding across an embedder host function** (§6.3): decided
  2026-10-26 — raise Lua's "attempt to yield across a C-call boundary"
  first; a continuation form of the C API maybe later.
- [x] **Q4 — the async surface** (§7): decided 2026-10-26 — async with
  syntactic sugar (`async function` / `await`).
- [x] **Q2 on wasm32** (§5): decided 2026-10-26 — the browser VM uses the
  same model and simply holds more memory.
- [x] **Async start** (§7): decided 2026-10-26 — a task starts at the call;
  awaiting a finished task continues at once.
- [x] **Q1 research round 1** (§4.1): Codex and Antigravity surveyed
  single-model designs; reports in `docs/reviews/doc73/`.

### Outstanding

- [ ] **Q1 — direction** (§4, §4.1): Bart leans to a single model (option
  4.4) with Lua's coroutines derived from it; the two reports differ on
  where its delimiters live (§4.1).
- [ ] **Async error timing** (§7): an error raised before the first
  `await` — stored in the task (C#, JS) or raised at the call; and what an
  error in a task nobody awaits does.
- [ ] **P0 — the thread object and stack switch** (§5), `coroutine.create`,
  `resume`, `yield`, `status`, `running`, `isyieldable`, `wrap`, `close`.
- [ ] **P1 — GC, keyframes and replay** (§6.1, §6.2): suspended stacks are
  roots with liveness masks; keyframes carry every coroutine; a step can stop
  inside one.
- [ ] **P2 — the JIT boundary** (§6.4): a switch ends a trace; traces inside a
  coroutine body run as usual.
- [ ] **P3 — the visualiser** (§6.5): coroutines in the frame view.
- [ ] **P4 — the async layer** (§7), if chosen.
- [ ] **P5 — docs and inventory**: the eight `coroutine` rows leave
  `excluded`; `docs/differences-from-lua.md`; doc 00's Non-goal and doc 02's
  "Host-mediated suspension" get a follow-up paragraph.

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
