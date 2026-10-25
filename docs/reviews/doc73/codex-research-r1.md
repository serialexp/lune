# Doc 73 research round 1 — Codex (Q1: a single control-flow model)

Date: 2026-10-26. Brief: survey one-primitive designs (effect handlers, delimited continuations, coroutines, WasmFX, Loom, ...) for mahina given the decided stack model (reserved address space per coroutine), yield-across-host = error, async with syntax sugar.

Bart, **my recommendation is a one-shot, delimited suspension model with tagged operations, implemented using the reserved stacks you already chose**. Lua coroutines would be one protocol over it; async tasks another. Debugger stops would share the saved execution state but remain privileged VM control events.

A coroutine-first implementation is also credible: published work demonstrates one-shot effect handlers implemented over Lua coroutines. The distinction is therefore practical—composition, handler scope, resource lifetime, and cost—not a fundamental expressiveness gap.

All mahina-specific designs and complexity estimates below are proposals or analysis, not measured results.

## 1. What the existing runtime establishes

The current implementation already represents much of a continuation explicitly:

- [`CallFrame`](/home/bart/Projects/lune/src/interp.zig:497) contains the closure, register-window base, PC, return destination/count, varargs, and control byte.
- [`Vm`](/home/bart/Projects/lune/src/interp.zig:756) owns separate `tags` and `payloads` register lanes, an inline frame array, stack cursors, open-upvalue tracking, and execution-control state.
- [`Upvalue`](/home/bart/Projects/lune/src/function.zig:41) retains direct pointers to both register lanes, alongside its open-slot index. Stable stacks preserve those pointers during execution, but serialization still needs stack ownership plus an index.
- Native trace entry already takes register bases as arguments. Conversely, [`hostcall_x64.S`](/home/bart/Projects/lune/src/asm/hostcall_x64.S:248) constructs frames using the current inline-array layout. Changing stack ownership requires auditing both generated code and assembly.

The register lanes alone reserve **576 KiB at today’s 65,536-slot limit**: 65,536 × nine bytes. The current 200 × 80-byte frame array adds about 15.6 KiB. These are capacity figures, not the physical-memory cost required by the proposed demand-paged implementation.

Two qualifications affect every candidate:

1. **Doc 68 is partly implemented.** Lua `pcall`/`xpcall` bodies use frame tags; metamethods and several native callback sites still need conversion. A coroutine or effect design cannot preserve resumable state still living only in an ordinary Zig activation. See [doc 68’s implementation status](/home/bart/Projects/lune/docs/design/68-nested-suspension.md:43).
2. **Embedding replay is unfinished independently of suspension.** Doc 59 explicitly defers arbitrary host-callback record/replay and snapshots with registered host functions. It identifies callback identity, re-entry, failure, and guest mutation as unresolved—not merely missing result logging. See [E6/E8](/home/bart/Projects/lune/docs/design/59-rust-embedding-api.md:222).

The coroutine exclusions in [doc 00](/home/bart/Projects/lune/docs/design/00-architecture.md:495), [doc 02](/home/bart/Projects/lune/docs/design/02-determinism.md:406), and the inventory are historical context; your stated decisions supersede them for this assessment.

## 2. The central distinction: control mechanism versus policy

A useful common model is:

> A suspended computation owns a delimited execution state. Resuming consumes its current suspension and supplies values or an exceptional outcome. It may subsequently produce another suspension.

“One-shot” applies to **each captured suspension**, not to the computation’s entire lifetime. A generator can yield a million times. Each individual continuation can be resumed at most once.

That mechanism does not, by itself, specify:

- which handler receives an operation;
- who schedules runnable tasks;
- whether cancellation can be caught;
- what cleanup abandonment performs;
- whether a function call creates a task;
- whether debugger suspension is visible to guest code.

Those are necessary policies, even with one underlying control-flow model.

There is substantial theoretical support for choosing a small substrate. De Moura and Ierusalimschy establish expressive equivalence between full coroutines and one-shot continuation models. Kawahara and Kameyama specifically implement one-shot algebraic effects as libraries over asymmetric coroutines, including Lua. Neither result establishes equal runtime cost or automatic resource safety. [*Revisiting Coroutines*, 2009](https://www.cs.tufts.edu/comp/150FP/archive/roberto-ierusalimschy/revisiting-coroutines.pdf), [*One-shot Algebraic Effects as Coroutines*, 2020](https://www.logic.cs.tsukuba.ac.jp/~sat/pdf/tfp2020-postsymposium.pdf).

## 3. Comparison of candidates

Here, **all required surfaces** means Lua’s coroutine protocol, generators, async/await, and host waits. Every candidate still needs a privileged debugger-stop path; exposing a user operation alone does not provide instruction stepping.

Let:

- `h` = intervening handler/delimiter depth;
- `s` = saved live execution state;
- `v` = values transferred.

### Semantics, surface, and runtime cost

| Candidate | Expressiveness for mahina | Dynamic-language surface | Switching, lookup, memory, ordinary calls |
|---|---|---|---|
| **Full asymmetric coroutines** | All required surfaces; effect handlers through an additional protocol. Arbitrary nested Lua calls can yield. | Familiar `create/resume/yield`; async can hide them. Internal tagged messages distinguish protocols. | Direct switch targets known resumer: O(1 + v), excluding page faults/cleanup. O(s) committed state. No handler search on ordinary calls. Forwarding effects through nested coroutines can require O(h) handoffs. |
| **OCaml-style one-shot dynamic handlers** | All required surfaces, plus user-defined resumable operations and abortive handlers. No continuation cloning. | `perform(tag, ...)` and `handle(...)`; nearest matching active handler wins. New concepts, but no effect type system is required for runtime dispatch. | With separate delimiter stacks, capture avoids copying registers. Lookup/chain traversal O(h) initially. Handler installation costs a boundary/segment. Ordinary calls need no effect lookup. |
| **Lexical capability handlers, adapted from Effekt** | Same one-shot control expressiveness; operation target comes from a captured/passed capability. | `reader:read(...)` or `emit(value)` where the capability is lexically bound. More explicit dependencies. | O(1) target resolution is plausible; reaching/capturing the delimiter chain can still cost O(h). Capability arguments/closures cost something where used. Uninvolved calls can remain unchanged. |
| **Koka-style evidence passing and selective translation** | General handlers; its compilation techniques cover more than one-shot scheduling. | Runtime tokens could replace typed operation declarations, but mahina would lose static effect information that guides compilation. | Evidence enables efficient handler selection and direct calls for restricted operations. A wholesale translation could affect calling conventions and continuation allocation. Benefits cannot simply be assumed in mahina. |
| **One-shot multi-prompt delimited control** | All required surfaces; handlers are encodings over tagged prompts and capture/resume. | `prompt(tag, f)`, `capture(tag, f)`, `resume(k, ...)`. Small machinery, comparatively unfamiliar application API. | Similar stack representation to one-shot handlers. Prompt lookup O(h) unless indexed. No mandatory ordinary-call search; delimiter installation and capture bear the cost. |
| **Multi-shot continuations / unrestricted `call/cc`** | More expressive: reusable control histories, backtracking. More than these requirements need. | Powerful but difficult interactions with mutation, cleanup, and foreign resources. | Cannot consume one uniquely owned stack in place. Requires copying, persistent state, or equivalent machinery. Captured control does not automatically copy mutable heap state or external resources. |
| **WasmFX / Wasm stack-switching model** | Tagged suspension, continuation resumption, exceptional resumption, and optional symmetric switching cover the required control mechanisms. | Hide low-level continuation instructions behind Lua libraries and async syntax; use runtime validation instead of Wasm’s static continuation types. | Excellent conceptual fit for reserved stacks. Normal calls need no evidence parameter. Actual switching and handler-chain costs depend on mahina’s representation. |
| **Selective state machines / CPS: Kotlin, C#, Swift, old Zig async** | Async and generators fit. Arbitrary yielding through unannotated Lua helpers needs broader transformation or another stackful mechanism. | Familiar `async/await`, but suspension eligibility becomes a language rule or compiler inference problem. | Compact saved frames can avoid large stack reservations. Costs occur in transformed calls, state objects, and resumption chains. Nonparticipating functions can retain their ABI. |
| **Rust futures / poll** | Strong host/executor interface. Alone, it cannot suspend arbitrary ordinary Lua calls. | `poll → Pending/Ready`; usually hidden behind `await`. Poor direct Lua surface. | A poll can traverse nested futures. Saved state is explicit and often compact. Does not require changing ordinary calls outside async code. |
| **Loom scoped continuations** | Stackful suspension supports the required surfaces with additional protocols. Virtual threads themselves are a scheduling surface, not general effect handlers. | Direct-style code and scoped parking; Lua coroutine wrappers remain necessary. | Loom’s heap stack chunks are a different storage implementation from your fixed-address decision. Its separation of continuation machinery from thread policy remains relevant. |
| **Go goroutines / Erlang processes** | Async concurrency fits; explicit Lua resume/yield still needs a protocol. Actors/channels do not subsume general resumable handlers by themselves. | Friendly task/message APIs, but introduce scheduler and communication semantics. | Runtime-owned scheduling, stacks/process state, queues, and potentially parallel execution. Much more machinery than cooperative suspension alone requires. |

### JIT, replay, embedding, and implementation risk

These are **mahina-specific assessments**, rather than claims that the referenced systems already support mahina’s guarantees.

| Candidate | Tracing JIT | GC, replay, keyframes | C/Rust embedding | Complexity and commitment |
|---|---|---|---|---|
| **Asymmetric coroutines** | Switch barriers; body loops trace normally. Forwarding may multiply barriers. | Walk reachable stacks; save logical resumer relationships and protocol state. Script scheduling needs no external log. | Straightforward `drive → yielded/finished/error`; host scheduling adds logged inputs. | Smallest coroutine implementation; effect forwarding and nested async become additional protocol work. |
| **Dynamic one-shot handlers** | Start with installation/perform/resume barriers. Later guard handler resolution. | Save handler closures, captured stack chains, ownership and consumed state. | Host can receive a suspended request and retained continuation after native code returns. | Moderate/high: nonlocal capture, forwarding, cleanup, deep/shallow semantics. |
| **Lexical capabilities** | Direct target is easier to specialize; still guard capability validity. | Capabilities need serializable owners and scope/activation validation. | Natural host service capabilities and scoped schedulers. | Runtime escape checks replace static guarantees; explicit propagation affects API design. |
| **Evidence passing / CPS** | Potentially efficient specialized operations; larger compiler/JIT integration. | Generated continuation/evidence objects become ordinary traced and serialized state. | Bridges work, but do not make C stacks resumable. | Highest compiler disruption among plausible one-shot approaches. |
| **One-shot prompts** | Same barriers as handlers; surface encodings may add calls. | Save prompt identities and delimited chains. | Small generic capture/resume ABI. | Minimal semantic core, substantial library semantics; prompt composition becomes public contract. |
| **Multi-shot control** | Requires reconstructing reusable control state and guarding lifetimes. | Snapshotting stacks alone does not fork the VM’s heap or outside world. | Foreign leases, transactions, and callbacks need explicit duplication/re-entry rules. | Highest resource/replay risk; unnecessary for the stated requirements. |
| **WasmFX-inspired core** | Barrier-based implementation fits existing architecture. | One-shot ownership and tagged stack chains are explicit; serialization still must be designed. | Outcome-based driving maps well onto an embedding API. | Moderate/high. Borrow the model, without depending on browser implementation or adopting Wasm’s type system. |
| **State machines / CPS** | Trace between suspension states; generated dispatch may complicate trace shapes. | Excellent explicit-state visibility, provided every relevant activation participates. | Good async adapters; ordinary foreign callbacks remain boundaries. | Competing execution representation if added alongside existing VM frames. |
| **Poll futures** | Trace individual polls; no arbitrary stack suspension. | Future graph must be guest-owned/serializable; opaque host futures are insufficient. | Particularly good Rust adapter around a stackful core. | Low as an adapter, poor fit as mahina’s sole language primitive. |
| **Loom-style continuations** | Relevant boundary model; JVM implementation details do not transfer directly. | Native stack chunks are not a portable mahina keyframe format. | Native-frame restrictions still apply. | Useful precedent, but stack copying conflicts with your selected implementation. |
| **Go/Erlang scheduling** | Requires explicit deterministic preemption boundaries if adopted. | Scheduling, delivery, selection, and external inputs need deterministic rules or logging. | Less compatible with a host-owned game-loop scheduler. | Broad concurrency architecture beyond Q1’s suspension mechanism. |

### What the research languages contribute

**OCaml 5** is the closest precedent for adding handlers without converting an existing language wholesale to CPS. The PLDI implementation represents continuations with fibers, caches stacks, and does not capture intervening C frames. It also retains a separate cheap exception mechanism—useful evidence that one control model need not force every operation through identical runtime machinery. It does **not** establish zero overhead for mahina. [PLDI 2021 paper, §§5–6](https://anil.recoil.org/papers/2021-pldi-retroeff.pdf).

OCaml distinguishes **deep handlers**, automatically reinstated when a continuation resumes, from **shallow handlers**, where the next handler is supplied explicitly. Its runtime rejects repeated continuation resumption. These are independent design choices from static effect checking. [OCaml handler semantics](https://ocaml.org/manual/5.2/effects.html), [Effect API](https://ocaml.org/manual/5.3/api/Effect.html).

**Koka** contributes compilation techniques, not a requirement to adopt effect types. Generalized evidence passing carries handler information; restricted tail-resumptive operations can become direct calls instead of general capture/resume. For mahina, those are possible later optimizations after profiling. Koka’s dynamic binding and Effekt’s lexical capability model should not be conflated. [Xie–Leijen, ICFP 2021](https://www.microsoft.com/en-us/research/publication/generalized-evidence-passing-for-effect-handlers/), [Koka book, handler implementation](https://koka-lang.github.io/koka/doc/book.html).

**Effekt** contributes lexical targeting and scope safety. Its static machinery prevents capabilities escaping their handlers. A dynamically typed adaptation needs runtime checks or different lifetime semantics; retaining a capability object alone does not make invoking it valid. [*Effects, Capabilities, and Boxes*, §2](https://plg.uwaterloo.ca/~e45lee/publication/boxes/boxes.pdf).

**Eff, Frank, and Unison** demonstrate effects as a general programming interface. Eff includes choice handlers; Frank integrates handling into its operator model and supports multihandlers; Unison exposes operation requests and continuations through ability handlers. Their surface ideas are useful, but their broader functional/type-system designs are optional for mahina. [Eff](https://www.eff-lang.org/), [Frank: *Do Be Do Be Do*](https://arxiv.org/abs/1611.09259), [Unison abilities reference](https://www.unison-lang.org/docs/language-reference/abilities-and-ability-handlers/).

**Racket** contributes distinct tagged prompts, abortive versus composable control, and continuation barriers. A one-shot restriction would be mahina’s adaptation, not Racket semantics. `shift/reset` and `control/prompt` also differ in delimiter reinstatement/composition; choosing names without specifying those rules would leave the design incomplete. [Racket continuation reference](https://docs.racket-lang.org/reference/cont.html).

**WasmFX** is especially relevant as a small control substrate: creation, tagged suspension, resumption, and optional direct switching. The evolving Wasm proposal also makes continuation consumption explicit. This is a model to borrow, not a dependency mahina needs. [WasmFX paper](https://arxiv.org/abs/2308.08347), [Wasm stack-switching explainer](https://github.com/WebAssembly/stack-switching/blob/main/proposals/stack-switching/Explainer.md).

## 4. Three concrete options

The APIs and syntax below are illustrative proposals.

### Option A — Asymmetric computations as the core

**Core:** create a computation, resume it, suspend to its immediate resumer, finish or fail.

```lua
local c = computation.create(function()
    local reply = computation.suspend("hello")
    return reply + 1
end)

local event = computation.resume(c)
-- yielded("hello")

event = computation.resume(c, 41)
-- returned(42)
```

Internally, use tagged outcomes rather than overloading ordinary yielded Lua values:

```text
Returned(values)
Yielded(protocol, values)
Failed(error)
Stopped(debug_cursor)
```

**Lua library derivation**

A Lua thread object wraps the computation:

- `create` allocates an unstarted computation.
- `resume` drives it and translates yield/return/error into Lua results.
- `yield` suspends with a private Lua-yield protocol.
- `wrap` captures the thread object and applies Lua’s error/close behavior.
- Status and identity come from the logical thread object.
- `close` invokes the destruction/cleanup path.

**Async derivation**

```lua
async function load_scene(path)
    local bytes = await io.read_request(path)
    return decode_scene(bytes)
end
```

For a proposed **cold-task** interpretation:

```lua
function load_scene(path)
    return task.create(function()
        local bytes = task.await(io.read_request(path))
        return decode_scene(bytes)
    end)
end
```

The choice of cold versus immediately started tasks remains a surface decision. `task.await` suspends with a private await protocol; a host driver handles the request and later resumes the task.

**Runtime and JIT**

One reserved stack per computation, constant-sized cursor swaps, argument/result transfer, no ordinary-call handler lookup. Switches are trace barriers; loops inside computations trace normally.

**Main cost and risk**

General effects require forwarding through intermediate computations. In particular:

```lua
async function outer()
    local co = coroutine.create(function()
        return await io.read_request("scene.dat")
    end)
    return coroutine.resume(co)
end
```

A naïve implementation returns the await request as a successful Lua yield. To make the host wait suspend `outer`, `coroutine.resume` must retain its unfinished activation and relay the await outward, then resume the child inward. That protocol must preserve errors, GC roots, and debugger state.

**Assessment:** smallest direct route to Lua coroutines; viable common foundation if this forwarding protocol is deliberately part of the final architecture.

---

### Option B — Tagged one-shot delimited suspension

**Core:** create a computation, resume it under a handler set, suspend with a tag, and consume/close its continuation.

A public deep-handler library could look like:

```lua
local Ask = effect.new("Ask")

local answer = effect.handle(
    function()
        return 2 * effect.perform(Ask, "quantity")
    end,
    {
        [Ask] = function(k, question)
            return k:resume(21)
        end
    }
)
-- answer == 42
```

`Ask` is an opaque identity. Its label is diagnostic: another `effect.new("Ask")` creates a different operation. Matching uses identity, not string spelling or arbitrary Lua equality methods.

**Lua library derivation**

Each Lua coroutine has a private yield delimiter. `coroutine.yield(...)` targets that delimiter, regardless of intervening unrelated effect handlers.

The stable Lua thread object holds its latest suspension. The underlying continuation token is consumed at each resume; subsequent yielding supplies a new suspension.

**Async derivation**

`await request` performs the standard await operation. The host-owned task delimiter handles it:

```lua
async function load_scene(path)
    local bytes = await io.read_request(path)
    return decode_scene(bytes)
end
```

Conceptually:

```lua
local bytes = effect.perform(task.Await, io.read_request(path))
```

A Lua yield targets the coroutine delimiter; an await can target an enclosing task delimiter. This directly expresses the distinction needed by the nested example above.

**Runtime sketch**

Install capture boundaries proactively:

1. A handler body runs on a separate reserved stack segment.
2. Ordinary calls within it use the existing call mechanism.
3. `perform` locates the matching delimiter.
4. The intervening segment chain becomes the suspended continuation.
5. Handler code runs outside that captured chain.

This avoids relocating live register windows.

**The important memory consequence:** arbitrary nested handlers may require **more stack segments than Lua coroutine objects**. A single pointer swap is not a complete implementation of arbitrary delimited capture from the middle of one monolithic stack.

Initially, handler lookup and chain processing can be O(h). A linked-chain representation can avoid walking every saved frame, but constant-time nonlocal capture should not be promised without specifying ownership, parent links, and metadata updates.

**JIT story**

P0 treats installation, perform, and resume as boundaries. Later, handler resolution can be specialized with guards on tag and handler-environment identity/version. Resumption still enters coherent VM state; it need not remain on the same native trace.

**Main risks**

Deep/shallow behavior, forwarding, continuation escape, cleanup, and handler visibility become language semantics. More foundational work than Option A, with more direct composition afterward.

**Assessment:** strongest match for “one primitive, many surfaces,” while retaining ordinary direct-style calls.

---

### Option C — Lexically targeted capabilities

**Core:** a delimiter provides a capability; invoking that capability suspends to its associated handler.

```lua
local result = effect.scope(
    function(ask)
        local function quantity()
            return ask:perform("quantity")
        end
        return 2 * quantity()
    end,
    function(k, question)
        return k:resume(21)
    end
)
```

The nested helper closes over `ask`. An unrelated inner handler cannot accidentally intercept it.

**Lua library derivation**

The runtime supplies the currently executing Lua coroutine’s private yield capability. Legacy `coroutine.yield` accesses that capability internally, so Lua callers need no new parameters.

**Async derivation**

An async body receives or captures a task capability:

```lua
local loader = task.create(function(ctx)
    local bytes = ctx:await(io.read_request("scene.dat"))
    return decode_scene(bytes)
end)
```

`async function` / `await` can hide that binding within async bodies. Ordinary helpers that need it can capture or explicitly receive it.

**Runtime and JIT**

Capability target resolution can be direct. However, the runtime must validate that the target delimiter belongs to the active continuation chain; merely checking that its object still exists is insufficient.

Captured segments, memory ownership, barriers, GC, and snapshots resemble Option B. Traces can guard a capability’s owner and generation.

**Main costs and risks**

Explicit capability propagation affects APIs. Hiding propagation through dynamic context brings back dynamic lookup. Passing a hidden evidence argument through every Lua call would jeopardize the normal-call requirement.

Without Effekt’s type system, scope escape becomes a runtime error unless mahina chooses broader retained-scope semantics.

**Assessment:** attractive for explicit host services and predictable handler targeting; a larger departure from Lua programming style if used universally.

## 5. Semantics every option must pin down

### Lua coroutine behavior is more than switching

The adapter must preserve:

| Operation | Required behavior |
|---|---|
| `create` | Unstarted thread identity; body arguments arrive on first resume. |
| `resume` / `yield` | Multiple values, including trailing nils; later resume arguments become yield results. Resume returns a success flag. |
| `status` | Includes `"normal"` for a coroutine waiting for a coroutine it resumed—not just running/suspended/dead. |
| `running` | Current logical coroutine plus the main-thread boolean. |
| `isyieldable` | Optional target coroutine; main-thread and non-yieldable boundary restrictions. |
| `wrap` | Removes the success flag; propagates errors with Lua’s close behavior. |
| `close` | Accepts dead/suspended states; reports original or cleanup errors and performs required closing. |

The status and wrapping mechanics are visible in [Lua’s `lcorolib.c`](https://www.lua.org/source/5.4/lcorolib.c.html); the library contract is in the [Lua 5.4 manual](https://www.lua.org/manual/5.4/manual.html#6.2).

**Doc 73’s “only mark the coroutine dead” description is insufficient even before `<close>` exists.** Open upvalues must retain escaped variables correctly, stack ownership must be released safely, and a failed coroutine’s error must support `close`’s result. Full `<close>` compatibility additionally requires the missing language feature; no control primitive supplies it automatically.

A new host-wait state also needs an explicit relationship to Lua-visible status and external resumability. Lua specifies ordinary coroutine states, not mahina’s future task scheduler states.

### Suspension, errors, cancellation, and destruction differ

| Action | Meaning |
|---|---|
| Suspend | Preserve frames and resources for continuation. |
| Resume with error | Raise at the suspended operation; guest handlers may catch it if policy permits. |
| Cancel task | Request or enforce termination according to task policy. |
| Close Lua coroutine | Apply Lua’s closing rules. |
| Debugger stop | Preserve execution without a guest-visible yield or unwind. |
| Replay-integrity failure | Terminate through the VM’s fatal path. |

A resumable error can be a user effect. Ordinary `error()` should not silently become resumable.

Likewise, injecting a catchable cancellation exception is not guaranteed destruction: code can catch it. A destruction operation needs rules for cleanup failures and attempts to suspend during cleanup.

Abandonment must be specified. GC can reclaim unreachable VM memory without executing guest code; deterministic resource cleanup should occur at an explicit close or task-scope boundary. One-shot ownership removes duplication, but does not automatically release resources. The early one-shot continuation literature establishes the copying advantage, not a complete resource policy. [Bruggeman–Waddell–Dybvig, PLDI 1996](https://legacy.cs.indiana.edu/~dyb/pubs/call1cc.pdf).

### Debugger suspension shares storage, not guest authority

The existing [`canSuspendHere`](/home/bart/Projects/lune/src/interp.zig:3958) requires a coherent instruction boundary, no native re-entry, and no pending multret handoff.

A shared substrate can preserve that cursor and all relevant stack segments. Nevertheless:

- Guest handlers must not swallow debugger stops.
- A stop inside a child must preserve the pending parent resume chain.
- Stopping must not run cleanup or make `coroutine.resume` return.
- “Anywhere” remains a representable VM boundary, not an arbitrary machine instruction with unresolved native temporaries.

Early exit can use an abortive delimiter operation without constructing a first-class continuation. Sharing the model does not require allocating a continuation for every exit.

## 6. Runtime, JIT, replay, and embedding design

### Stack ownership and normal calls

Split state conceptually into:

- **VM/session:** heap, globals, effect log, code registry, shared runtime configuration.
- **Execution context:** register/frame bases, depths/tops, open-upvalue ownership, logical thread, delimiter chain, pending resumptions.
- **Transient execution machinery:** active recording, native episode state, reusable scratch.

The exact placement requires auditing existing assumptions; blindly copying all `Vm` fields into each coroutine would be wrong.

The normal-call target should be:

> No handler lookup, evidence-vector propagation, continuation allocation, or coroutine-status check on an ordinary call.

But reserved stacks alone do not prove that target. Replacing inline `Vm.frames` addressing with a pointer can add loads. Keeping active bases in dispatch state may help; assembly and generated push/pop paths must be measured. **No candidate has a demonstrated zero-regression implementation yet.**

Avoid accidentally touching the entire reservation during initialization or collection. Pool storage, not logical identities, and cap pool retention.

The existing wasm visualizer also needs an address-stable storage backend behind the same contract. Native `mmap` is not itself a wasm implementation; wasm32’s address-space budget needs explicit treatment without changing suspension semantics.

### Tracing JIT

LuaJIT’s checked-in coroutine fast functions lack recorder implementations for the switches. `vm_x64.dasc` performs argument/result transfers and yield/resume transitions. The `coroutine_wrap_aux` special case in `lj_record.c` concerns callee specialization; it is not cross-coroutine tracing. See [local `lib_base.c`](/home/bart/Projects/LuaJIT/src/lib_base.c:611), [`vm_x64.dasc`](/home/bart/Projects/LuaJIT/src/vm_x64.dasc:1521), and [`lj_record.c`](/home/bart/Projects/LuaJIT/src/lj_record.c:810).

For mahina, the initial contract should be:

1. Finish or abort recording before transfer.
2. Reach a precise, coherent VM state.
3. Preserve completed effects and the exact continuation PC.
4. End the native episode before replacing active stack bases.
5. Re-enter dispatch using the resumed context.

A coarse exit that repeats a suspension request or committed effect is unsound.

Later handler specialization is plausible, but must guard shadowing and environment changes. A cached raw handler address cannot become serialized identity. Cross-switch native linking is a separate optimization, not necessary for body loops to compile.

### GC and keyframes

Suspended state must be reachable through GC-managed owners. **Do not make every created coroutine an immortal global root.**

A particularly important case is:

```lua
-- A closure survives, retaining an open variable in a suspended coroutine,
-- while the original coroutine handle becomes unreachable.
```

Stable addresses prevent relocation, not premature reclamation. The upvalue must keep its backing owner alive, or an explicit lifecycle operation must close it before the stack can be pooled.

Extend the existing [liveness/root machinery](/home/bart/Projects/lune/src/interp.zig:3495) to reachable suspended contexts and segment chains. Save:

- logical thread/task and segment identities;
- frames, PCs, native continuation phases, and live registers;
- `(segment_id, slot_index)` for open upvalues;
- handlers, capabilities, parents, and pending resume relationships;
- suspension generations and consumed/closed states;
- pending requests and VM-owned task bookkeeping;
- the existing replay envelope.

Raw virtual addresses, JIT PCs, function pointers, and OS request handles are not portable snapshot identity. Restoring into a new process requires rebinding to newly reserved ranges. Stable addresses during execution do not require restoring at identical addresses.

### Deterministic scheduling

Script-directed `coroutine.resume` introduces no new external scheduling input.

For host-driven tasks, record the guest-visible decisions and results:

```text
request identity and operation
completion/failure payload
task or continuation chosen to run
cancellation delivery
host tick/input, when guest-visible
```

The exact record structure is a design choice. It must correlate requests and completions and reject duplicate/stale completions.

Replay must not restart recorded I/O. A future live restore needs a separate policy for rebinding, restarting safe operations, or refusing unrecoverable host resources.

A host-owned queue existing only in a Rust allocation is not captured by a VM keyframe. Pending guest relationships must be VM-owned or included through a defined host snapshot protocol.

For game-loop fairness, use deterministic logical work budgets or logged host decisions. CPU-time-driven tiering or unlogged scheduling would violate the constraints. Native traces need accounting or forced exits compatible with that budget.

### Proposed embedding shape

An outcome-based interface works with all three options:

```c
/* Illustrative, not existing API. */
mh_drive(vm, computation, input, &outcome);

/* outcome:
   RETURNED(values)
   REQUEST(operation_id, request_id, payload, continuation)
   FAILED(error)
   STOPPED(cursor)
*/
```

For each tick, the host delivers selected logged completions, drives selected tasks, handles new requests, and renders.

A host handler either returns immediately or retains a rooted continuation/request handle and returns to its caller. **It must not retain a live C/Rust activation and expect pointer swapping to resume it.**

An I/O binding can construct a request descriptor, return, and let the VM suspend afterward. This respects your initial boundary decision. Yielding from a guest callback across an active ordinary host call remains an error; Lua’s `lua_yieldk` stores an explicit continuation for the later API extension. [Lua `ldo.c`, `lua_yieldk`](https://www.lua.org/source/5.4/ldo.c.html#lua_yieldk).

A Rust `Future` adapter can register a waker and report readiness through the host queue. It should not retain a borrowed `&mut Vm` or raw register slice across `Pending`; waking should enqueue work rather than re-enter the VM from an arbitrary thread. Rust’s poll protocol is useful here as an adapter. [Rust `Future`](https://doc.rust-lang.org/std/future/trait.Future.html).

## 7. Lessons from mainstream async systems

These systems offer useful surfaces and policies without requiring their execution models:

- **Kotlin:** compiler-supported continuation passing/state machines plus library context and scheduling. Useful precedent for keeping scheduler policy outside core syntax. [Kotlin specification](https://kotlinlang.org/spec/asynchronous-programming-with-coroutines.html).
- **Swift:** task trees, cooperative cancellation, and actors. Structured task lifetime is worth considering; actors are a separate isolation feature. [Swift concurrency](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html).
- **C#:** sequential-looking async code compiled into state machines. Useful surface, but it would add a second representation beside mahina’s explicit VM frames. [C# async documentation](https://learn.microsoft.com/en-us/dotnet/csharp/asynchronous-programming/).
- **JavaScript/Python generators:** good iterator protocols, but nested delegation is explicit. They do not provide arbitrary Lua-style yielding through ordinary helper calls. Python’s `throw`/`close` also illustrates that cleanup is a protocol with error cases. [ECMAScript generators](https://tc39.es/ecma262/multipage/control-abstraction-objects.html#sec-generator-objects), [PEP 342](https://peps.python.org/pep-0342/), [PEP 380](https://peps.python.org/pep-0380/).
- **Old Zig async:** explicit frame, suspend, resume, and await demonstrate separating suspension from an event loop. This is historical prior art, not an API available to assume in mahina’s pinned compiler. [Zig 0.10.1 documentation](https://ziglang.org/documentation/0.10.1/#Async-Functions).
- **Loom:** scoped continuations underneath a familiar task/thread interface support separating machinery from policy. Its heap stack chunks differ from your chosen storage. [Original Loom proposal](https://cr.openjdk.org/~rpressler/loom/Loom-Proposal.html), [JEP 444](https://openjdk.org/jeps/444).
- **Go/Erlang:** communication and scheduling policies need separate decisions. Go specifies pseudo-random selection among ready `select` cases; Erlang documents reduction-based preemption but does not promise invariant scheduling. Neither should be imported unchanged as mahina’s deterministic policy. [Go specification](https://go.dev/ref/spec#Select_statements), [Erlang scheduling](https://www.erlang.org/docs/26/man/erlang.html#process_flag-2).

## 8. Staged implementation and acceptance criteria

I would adjust doc 73’s staging so GC and keyframes are part of the first usable suspension slice.

| Stage | Concrete scope |
|---|---|
| **P0: execution ownership** | Reserved stack/context abstraction; main context; pointer/cursor switch; one-shot state validation; GC ownership; keyframe encoding/restore; no public general handlers yet. |
| **P1: Lua protocol** | All eight coroutine functions; nested calls and resume chains; error/close behavior; host-boundary refusal; required doc 68 conversions. |
| **P2: tagged composition** | Handler delimiters, nonlocal forwarding, explicit deep/shallow rules, abandonment and cleanup. This is foundational work if Option B is chosen, not an unrelated future subsystem. |
| **P3: async and embedding** | Request/completion protocol, host scheduling log, pending-request snapshots, task lifetime/cancellation, syntax. |
| **Later optimizations** | Profile-guided handler indexing/specialization, tail-resumptive operations, optional direct symmetric transfer. |

For performance, use deliberate release benchmarks, not timing assertions in correctness tests:

| Boundary | Representative experiment and expectation |
|---|---|
| Ordinary calls | Existing call-heavy corpus plus trivial call/return benchmark: no reproducible slowdown; inspect instruction counts and assembly changes. |
| Switching | Warm ping-pong at depths 1, 20, and the configured limit: no register/frame copying proportional to depth. Report transferred bytes and allocations. |
| Handler lookup | Match at depths 1, 10, 100; verify the documented search complexity and later cache behavior. |
| Suspended memory | 10,000 shallow contexts, with a larger deliberate stress run: committed memory scales with touched state, not full reservation size. |
| Lifecycle | Repeated create/suspend/close cycles: bounded pool retention, no dangling upvalues or leaked owners. |
| Snapshot/restore | Many live contexts and pending requests: no per-context whole-VM rewrites or scans of untouched reservations. |
| Game-loop driver | Ready subsets among many waiting tasks: work proportional to delivered/ready work rather than scanning every task per tick. |

Behavioral gates should include GC stress, eight-mode equivalence, every representable suspension cut through nested callbacks, restore/recapture identity, stale-token rejection, nested await through `coroutine.resume`, and close/error interactions.

## 9. Recommendation and trade-offs — my opinion

**I favor Option B**, with a small internal resume/suspend protocol and tagged delimiters, while initially exposing familiar coroutine and async surfaces.

The reasons are:

- It distinguishes Lua yield, host await, and unrelated user effects directly.
- It can capture the enclosing pending resume chain without interpreting an await as an ordinary Lua yield.
- Reserved stack segments fit one-shot ownership without relocation.
- It leaves ordinary calls in direct style.
- It provides a path to lexical capability APIs without requiring evidence passing through every call.

Its price is real: delimiter ownership, segment chains, cleanup, and keyframes must be designed together. Nested handler scopes may consume more segments than coroutine count suggests. “One primitive” does not make those costs disappear.

**Option A is a reasonable alternative** if you prefer the coroutine protocol as the foundation. The papers support its expressiveness. I would make tagged forwarding, pending resume activations, and nested-await behavior part of that design immediately; otherwise the async layer would expose a structural gap.

**Option C is most attractive if explicit capability ownership is a primary language goal.** I would use it selectively for host services before making every effectful helper carry capabilities.

I would not choose multi-shot control or a wholesale CPS/evidence-passing compiler rewrite for these requirements. They introduce capabilities and costs that the current use cases do not require.

The expensive-to-change commitments are public semantics: handler targeting, deep versus shallow resumption, cross-coroutine effect propagation, continuation escape, cancellation/cleanup, and async start behavior. Internal lookup indexes and stack-pool policies are much easier to replace.

The remaining uncertainty is empirical: **none of these proposals has demonstrated the required normal-call performance in mahina**. That is an implementation acceptance gate, not a conclusion available from the literature.
