# Doc 60 rev 1 — codex review (2026-10-02)

Reviewer: Codex (configured default model), thread 01a0fa76-979a-7ba0-b4dc-fb44dfc37a90.
Source review only; no files modified, no tests run.

CHANGES REQUESTED

**BLOCKERS**

1. **Q1's allocation argument does not justify removing input parking.** Doc 60 asks only whether collection can occur before the window write (60:197). The normative header promises that incoming heap values remain valid **through and after** that call (mahina.h:20). Parameter registers can be overwritten; surplus non-vararg arguments are discarded; the callee frame is popped. None provides that lifetime.

   The allocation/collection audit is:
   - `fromC`, successful `argsSlice`, `resultsSlice`, and `parkClearIfIdle`: none.
   - Current input `park`: overflow can allocate through `vm.gpa`, but does not itself collect; its OOM reporting can allocate `last_error` (capi.zig:313, capi.zig:325).
   - Closure lookup, reentry/depth/capacity checks, both argument layouts, nil-fill, and `pushFrameTrusted`: none (interp.zig:2096, interp.zig:2140).
   - `cachedCodeFor` reads/caches an image; `setRegionContext` stores context; neither allocates. The **first dispatch prologue can collect** (trace_entry_registry.zig:76, trace_region_policy.zig:291, interp.zig:2757).
   - Invalid-input/fatal error reporting can allocate diagnostic storage; these are terminal rejection paths.
   - Native fallback can allocate or collect during invocation without pushing a closure frame. `__call` lookup and redirect-window construction are allocation-free, but the recursively selected callable can allocate or collect (interp.zig:2109, interp.zig:2229).

   Retain input parking, or replace it with roots providing the same complete lifetime. Add regressions for an overwritten parameter, discarded surplus heap argument, and otherwise-unrooted callee, followed by collection during execution **and after return**.

2. **The frame/entry state contract omits executable state.** "Eight fields" is incorrect (60:202): `CallFrame` also has `code_cache` and `code_cache_gen`. The struct-literal push initializes their defaults on every slot reuse; hand-written code must reproduce that invalidation (interp.zig:393, interp.zig:2027). Otherwise a reused frame can execute another closure's cached image.

   Specify who initializes every `ExecState` field, resolves the VM-local patched image, sets `code_gen`, initializes `err`, and owns the state's lifetime (interp.zig:2480, interp.zig:2584). Also preserve `next_call_seq` exhaustion handling (interp.zig:2024). The selected C shim needs a concrete signature and an ownership boundary before H3.

3. **§4.3 needs an ordered exit contract, not just final field comparisons.** Existing execution clears pending exit/replay anchors on completion and suspension, and aborts recording on errors before the enclosing protected boundary handles them (interp.zig:2475). Catchable faults must render while faulting frames remain live, close upvalues, drop region activations, then restore depth/top and clear pending error/final cut. Non-catchable faults poison the VM and retain fault state (capi.zig:345).

   Define fallback before any irreversible entry work. A mid-chain `.switch_mode` must resume the **already-pushed frame at its parked PC with the original stop depth**, rather than call the whole host entry again (interp.zig:2506).

   Suspension is also mischaracterized: `callValue` asserts `suspend_ctl == null` and treats a suspended outcome as unreachable (interp.zig:2099, interp.zig:2201). Routing an armed suspend to that function does not make host-call suspension supported.

4. **The packed word needs mutation ownership beyond "update approximately 31 sites."** The nine-condition inventory is correct (interp.zig:2555); a synchronized `u16` is sound for this single-threaded VM. The proposed synchronization boundary is incomplete, however: production wasm code directly changes both VM controls, and recorder reset clears `active` before a fallible allocation and sets it only after initialization (wasm_entry.zig:711, trace_recorder.zig:6071, trace_recorder.zig:6130).

   Specify setters that mutate payload **and** mask together, initialization/restore rules, and synchronization on recorder success, abort, and OOM paths. One viable design keeps recorder synchronization at owning `TraceState` boundaries and routes VM controls through setters, avoiding a recorder-to-VM backpointer. A stale clear bit skips required hooks; a stale set bit can strand execution in `.full`. The assembly path must also run the debug validator—the assertion inside Zig's `runFastPath` cannot catch an assembly load that bypasses it (60:298).

5. **§6 is insufficient as the determinism/replay gate.** Hashgate hashes CLI stdout and exit status; it does not compare embedding snapshots, effects, traces, or replay cuts (tools/hashgate.py:19). The proposed state comparison omits register contents, safepoint/effect counters, open upvalues, final cut, recorder/anchor state, frame caches, fatal state, and region activations (60:231).

   First compare H1 against the existing protected call path; otherwise H1 and H3 can share the same bug. Then compare H3 against H1 using normalized object identities and serialized artifacts. Require supported embedding keyframe/effect replay cases across the determinism modes, plus Debug and ReleaseFast execution. Add boundary-depth/capacity failures, invalid tags/null heap arguments, result truncation and zero capacity, multret/varargs, frame-slot reuse after image changes, park overflow/OOM, fatal refusal, and nested calls that start recording then raise. Keep callback replay/keyframe exclusions explicit (59:171).

**SHOULD-FIX**

1. **Explicitly preserve the first complete dispatch prologue and existing hook placement.** GC, `safepoint_seq`, region observation, fault PC, anchor activation, and recording mirror have a prescribed order (interp.zig:2741, interp.zig:2784, interp.zig:2864). These can remain owned by the unchanged chain. Conversely, current direct host closure entry does **not** call `onCallEntry`; guest `.call` does, advancing tick/hot-call state (interp.zig:2198, interp.zig:6327, trace.zig:3383). Adding that hook during H1 would change tiering behavior.

2. **The instruction budget is optimistic and incomplete.** The 12–16-instruction frame/state row omits cache defaults and address calculations; the seam row does not account clearly for `ExecState` initialization and image resolution; the rooting row must retain input roots (60:213). ABI register preservation, stack alignment, stack-passed C arguments, and success cleanup also need an owner. A substantial reduction is plausible; **135–160 total instructions is not yet substantiated**.

   Split the ledger into the full public crossing and the internal entry, count every helper inclusively, and measure H1 before treating residual cost as compiler artifact. Include argument/register/result-count scaling and heap-valued/reentrant workloads, rather than only `id(1)`.

3. **M1/M2/M3 need explicit ABI and debugging requirements.**
   - **M1:** the existing stack probe proves a zero-argument naked body, not a callable host entry. The pinned toolchain describes `.naked` functions as uncallable from ordinary Zig code (`…/lib/std/lang.zig:157`). Specify the C-callable declaration/interface, saved registers, alignment, and unwind metadata. A visible symbol alone does not provide reliable stack unwinding.
   - **M2:** the pinned API is `Module.addAssemblyFile` (`…/lib/std/Build/Module.zig:435`). Document preprocessing/generated-offset integration for the **target's** layout during cross-compilation, PIC relocations, symbol visibility, and CFI/source locations.
   - **M3:** existing executable mapping supports x86-64 Linux and RW→RX transitions (nativegen_mcode.zig:78). Define fallback on mapping failure, code ownership/deinitialization, helper-address reachability under ASLR, and unwind/debug registration. Without baked VM addresses, a shared immutable entry can avoid per-VM emission and mapping costs.

   `@offsetOf` handles field locations, not arbitrary optional/error/union representations. Keep those behind the Zig shim or provide a checked representation contract (60:152).

4. **Two M3 comparison claims are false.** LuaJIT generates its interpreter at **build time**, through `host/buildvm`, rather than at VM creation (`/home/bart/Projects/LuaJIT/src/Makefile:675`, `:685`). Its call entry also performs callable validation and can redirect to `vmeta_call` (`vm_x64.dasc:647`). Mahina's encoder already supports indexed/scaled addressing (x64.zig:218, x64.zig:362), contrary to 60:138. Distinguish prohibiting dynamic executable memory from enforcing W^X—the current mapper enforces W^X.

5. **§7 needs a measured admission decision after H1.** Its requirements are reasonable, but H3 is currently scheduled regardless of whether H1 leaves a worthwhile gap (60:32, 60:253). Require an H1/H3 A/B showing cycle or latency benefit on representative workloads, including fallback frequency, code size, and broader regressions. Fewer instructions alone is insufficient: this project already measured an instruction reduction that worsened cycles through code placement (59:134).

**NITS**

1. **Reconcile §4.2 with the settled shim decision.** It still presents handler `.c` conversion as an H2 measurement despite Q2 selecting the shim (60:159, 60:280). Label it as a separate future proposal.

2. **Define "byte-identical VM" precisely.** Independent VMs contain different pointers and unspecified padding. Require byte-identical serialized artifacts and equivalent normalized runtime state, not raw memory equality (60:174, keyframeser.zig:313).
