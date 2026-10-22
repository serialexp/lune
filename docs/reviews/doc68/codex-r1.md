# Doc 68 — round-1 review (codex, 2026-10-22)

Asked for a read-only review of doc 68 rev 1 against the tree and LuaJIT:
soundness holes, pcall/xpcall with embedder entries, resumable natives,
performance, Q2/Q3, phasing. Findings as given, lightly condensed (code
excerpts and link markup dropped; every claim and citation kept):

---

Bart, I recommend revising the design before P0. The continuation direction is workable, but `cont + cont_aux` does not yet describe all the persistent state needed for GC, protected calls, and native activations.

This is a static review of the current working tree. I read doc 68 in full and checked the requested source paths and LuaJIT comparison. I edited no files and ran no builds or tests.

## Critical findings

### 1. A native cannot occupy `CallFrame.closure` under the existing frame contract

`interp.zig:421` declares `closure: *const Closure`. `Closure` contains a `Proto` pointer, whereas `Native` contains a function pointer and different metadata (`function.zig:99`, `function.zig:343`). Frame reload and execution dereference `closure.proto` (`interp.zig:3207`, `:5843`); GC derives window sizes and masks from that proto (`:2694`); fault reporting and backtraces do the same (`:2027`, `:2100`); restore explicitly rejects a native frame target (`keyframeser.zig:875`).

Proposed fix: a typed frame representation before resumable natives — a Lua/native discriminant, typed payloads, a common explicit window extent. Native frames need a stable registry descriptor (step function, state layout); restore rebinds it by name. Define which synthetic frames appear in backtraces and `error(..., level)`.

### 2. Advancing the interrupted PC breaks the existing GC-liveness classification

`interp.zig:2651` recognizes a non-innermost, out-of-flight frame only when `code[pc - 1]` is `.call`. A parent suspended during `.add`, `.get_index2`, `.set_index2` becomes `.unknown`; maskable protos then fail the assertion at `:2667`. Using the next instruction's liveness row is also wrong: the second key of `get_index2` may be dead after the instruction but needed after its first metamethod returns. `cont_aux` pointing at xpcall's handler argument does not root it: suspended-call masks exclude slots at and above the call base (`:2701`). Scanning whole windows instead breaks doc 61's determinism argument.

Proposed fix: explicit persistent suspension states (originating instruction, resume cursor, pending operation phase), with masks and extra rooted operands in `fillKeep`, serialized or reconstructed before restore validates tombstones; a separate faulted-frame state for xpcall's retained frames.

## High-severity findings

### 3. Protection must exist independently of a successfully pushed Lua callee

Today protection surrounds the whole `callValue` attempt (`errors.zig:78`), which accepts natives, closures and callable tables and can fail before pushing a frame (`interp.zig:2408`, `:2439`): `pcall(nil)`, `pcall(error, "boom")`, `pcall(pcall, f)`, `pcall(callable_table)`. One return-action enum cannot express protection and the enclosing return action when the protected operation itself needs a native activation.

Proposed fix: a protected activation established before callable resolution; protection state separate from its incoming return continuation; it invokes any callable through the common result protocol; it gives xpcall's handler a rooted home.

### 4. xpcall needs a serialized "handling error" state and an explicit unwind owner

The current code captures entry depth/top, synthesizes the error before unwinding, clears `pending_error`, runs the handler above retained fault frames, and distinguishes catchable from fatal handler errors (`errors.zig:69`, `:104`). After a suspension in the handler the design must still know which protection owns it, which frames are retained faults, where unwinding ends, and whether the protection is already handling. Otherwise a handler failure rediscovers the `.protected` frame and runs the handler again; and treating every error above a handler as "error in error handling" would bypass a nested `pcall` inside the handler.

Proposed fix: `calling`/`handling` phases, rooted handler and error slots, an unwind boundary; the search honours newer protections first; only an uncaught catchable handler failure becomes "error in error handling"; non-catchable failures propagate with frames retained. Handler results must survive closing upvalues and dropping fault frames.

### 5. `stop_depth` needs an ownership contract for directly host-entered protected calls

`stop_depth`'s boundary frame is `stop_depth - 1` (`interp.zig:2290`), and the return handler processes it before ordinary result wiring (`:7531`). `mh_call` can invoke `pcall` directly through `runProtected` (`capi.zig:831`, `:451`). If that `pcall` pushes `f` as the boundary frame, the scan excludes its `.protected` tag and the boundary-return branch bypasses its success transformation.

Proposed fix: protection ownership separate from the dispatch return boundary; a host-entered protected activation completes its transformation before returning to C; do not simply widen the scan. Test both directions.

### 6. Catching inside `execImpl` bypasses essential JIT error cleanup

Errors run `abortRaised()` and `clearPendingExitAnchor()` through `execWith`'s errdefers (`interp.zig:3011`) so a recording can't splice a pcall continuation onto a partial iteration. Catching inside `execImpl` (`:5864`) skips them.

Proposed fix: caught-error processing runs the JIT cleanup explicitly (keeping `trace.zig:3238`'s JIT-suspension behaviour), then closes upvalues, drops region activations, restores stack/depth, clears an invalid final cut, reloads state, reselects mode. Regression: recording active when a catchable arithmetic error happens inside a protected function.

### 7. The site survey misses fused stores and misclassifies VM-owned native metamethods

`fusedStore` does `indexGet(container, key1)` then `indexSet(mid, key2, val)` (`interp.zig:8347`); `set_index2` needs a continuation retaining key2 and the value. Field opcodes use the helpers too (`:7050`, `:7087`). A native metamethod can be `tostring`, which calls guest `__tostring` (`basic.zig:63`).

Proposed fix: a fused-store continuation; cover `get_field`/`set_field`; route continuation-issued calls through one callable dispatcher (closures, synchronous natives, resumable natives, host functions, callable tables). Keep `__call` chains bounded: removing `callValue` recursion removes the counter that ends callable-table cycles. List `mh_table_set` (`capi.zig:1326`).

### 8. `NativeStep` lacks a sufficient register and multret protocol

The register file is SoA; contiguous `Value` slices are boundary scratch (`interp.zig:1611`), so changes left in scratch are neither roots nor serialized. `done: u8` can't carry `dofile`'s forwarded results (`load.zig:265`). The call request doesn't say argument/result ranges or wanted counts.

Proposed fix: register indices or `RegWindow`; argument range, result range, wanted count, actual count, window capacity, at VM limits. Intermediate callback returns must not publish `reg_top_pending`; only the original producer's completion does (`:685`).

### 9. Updating assembly offsets is insufficient: every physical push must initialize the new fields

`nativegen_emit.zig:987` and `hostcall_x64.S:246` build frames field by field. A reused slot could keep `.protected` or `.native_resume`; an uninitialized `cont_aux` makes snapshot bytes nondeterministic.

Proposed fix: initialize defaults on all three push paths; extend the ABI checker; test slot reuse after a special continuation and after an error unwind; canonicalize unused wire payloads.

### 10. Q3's proposed counter does not identify every live host boundary

`native_reentry_depth` counts nested VM execution, not executing host callbacks: `callHostNative` doesn't raise it (`interp.zig:2351`). Today `in_flight` also blocks capture there; narrowing the refusal to the counter loses that.

Recommendation for Q3: refuse, with an explicit non-resumable boundary depth, checked when arming and before entering a synchronous host boundary while armed; C API entries, host-native invocation, synchronous table metamethod APIs; disarming always allowed; the refusal must not become a catchable Lua error. If defer is chosen, the same tracking is needed, the API must expose the actual stop position, a top-level synchronous C entry may never reach another boundary, and deferral can defeat the replay-index cap.

## Medium-severity findings

### 11. gsub needs more pending-match state; Q2 should use a GC-owned byte buffer

After the replacement returns, gsub still uses the match end `e` and start `src` (`string.zig:1479`, `:1532`), so the pending match end is state too.

Recommendation for Q2: a GC-owned growable byte buffer rooted by the activation; serialize used bytes; store match start/end and an awaiting-replacement phase; allocate it the same way in every mode. Reuse it for `require`'s diagnostics: `package.searchers` is mutable (`package.zig:327`), so "a handful at most" is unsupported and rebuilding the string is quadratic.

### 12. "Keyframe anywhere resumes byte-identically" needs an explicit replay envelope

Snapshots carry heap, stack, frames, loaded chunks (`keyframeser.zig:393`); replay tests reattach effect state separately (`keyframeser_replay_test.zig:47`, `:366`). Specify the resume artifact as keyframe plus replay envelope (effect position, PRNG state, logical counters, output prefix). Restore tests must resume inside nested code after a committed effect.

### 13. The performance budget omits frame layout and callback-state copying

The x64 frame stride is 80 bytes with return wiring at 72/74 (`offsets_x64.inc:62`); adding fields may change the stride. The source records a ~4% regression from moving call-handler code (`interp.zig:2157`). Gathering a whole activation's state per callback would make e.g. `print` of many arguments quadratic.

Proposed fix: keep the ordinary call path outlined; touch persistent state through registers; measure stride, handler code, instructions, allocations, time; zero per-comparison allocations for sort; linear state copying, gsub growth and diagnostics; an agreed A/B tolerance for tier-0 call/return rows.

## JIT return-path clarification

`emitInlineSelfRetPop` (`nativegen_emit.zig:1133`) refuses to pop unless the episode has a net pushed frame, so an episode's entry frame — a metamethod or protected function — already returns through tier-0, and pushed recursive children are `.none`. A defensive check should test the popped frame's action. Precise tracing refuses inlining (`trace_recorder.zig:4233`); doc 61 documents coarse re-execution for exits in inlined callees (`61-gc-liveness-masking.md:481`). No multi-frame snapshot reconstruction needs continuation payloads.

## Recommended phasing changes

1. P0 establishes the frame contract: typed activations, suspension/fault states, rooted payloads, result protocol, serialization, push initialization; synthetic non-`.none` tests.
2. Q3's boundary guard before enabling nested suspension; unconverted paths stay guarded.
3. The shared callable driver with P1 (natives, callable tables, fused reads and stores, field ops, bounded `__call`).
4. Protection with its error state machine and entry-boundary tests in P2.
5. Gates per native conversion: GC stress, capture→restore→recapture identity, resumed output, eight-mode equivalence; native-motion witnesses; a benchmark each.

Keep pushes/pops on the existing activation-identity and region-context funnels; keep `final_cut` publication at public `exec`.

[Codex thread: 01a161cf-da70-7391-a229-8b05decde4d3]
