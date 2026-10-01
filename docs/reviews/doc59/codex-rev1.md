# codex review — doc 59 rev 1 (2026-10-01)

Verdict: **CHANGES REQUESTED**. Verbatim findings below.
[Codex thread: 01a0f6a6-a993-7400-b08d-7bf1625b92bf]

---

Option **(c) is viable**, and rooted string borrows are sound under the current
non-moving GC. The proposal still needs explicit ownership and error-boundary
designs before implementation.

1. **Blocker — §3.2: freeing a script can invalidate escaped closures.**
   `retainChunk` roots constants; it does **not** own the prototype tree
   (interp.zig:783). `Chunk.deinit` frees that tree, while closures retain
   `proto` pointers. Thus `mh_eval("return function() ... end")`, or an eval
   that installs a global function, can leave dangling pointers after its
   compile→run→free sequence. Source text also remains necessary because every
   compiled proto borrows it (compiler.zig:182). Define VM ownership of
   executed program images, or another ownership mechanism covering closures,
   frames, and cached traces. Releasing the script handle must not free
   reachable code.

2. **Blocker — §3.2/E1: independently compiled scripts need VM-wide prototype
   IDs.** `compileWithOptions` defaults `id_base` to zero (compiler.zig:71).
   Multiple scripts retained in one VM would consequently share IDs. This is a
   correctness issue before snapshots: `guard_func` validates **only
   `Proto.id`** (irinterp.zig:747), so replacing a function with one from
   another script could pass a guard for different code. Reserve disjoint ID
   ranges during compilation, coordinated with runtime `load`; test replacement
   across scripts with JIT execution enabled.

3. **Blocker — §§3.2–3.4/§5: borrowed results require an actual rooting
   protocol.** Successful closure `callValue` copies results out and then
   shrinks `stack_top`, removing their register roots (interp.zig:2086). The
   direct-native path does not park external arguments in rooted registers.
   The wrapper must root callee/arguments throughout operations that can
   execute guest code, including metamethods, and preserve returned heap
   values until promotion. "Before the next VM call" also needs an exception
   for `mh_ref_create`, including promotion of multiple results. Either use
   automatic refs or a rooted, nesting-aware borrowed-result scope with batch
   promotion. Merely documenting a borrowed window is insufficient.

4. **Blocker — §3.8/E4: Rust lifetimes alone do not establish VM ownership or
   reentrancy safety.** `Value<'vm>` does not distinguish two VMs borrowed for
   the same lexical lifetime; the safe crate must reject foreign-VM heap
   values and refs. Specify shared access/interior mutability so values can
   remain live while calling the VM, and ensure callbacks never create
   overlapping exclusive references to the VM. VM-owned callbacks need
   `'static` captures or explicitly scoped invalidation. Define whether
   callback values can escape, and prohibit VM destruction during an active
   callback. Add compile-fail and runtime tests for these contracts.

5. **Blocker — §§3.3/3.6: error returns leave the VM dirty.** `callValue`
   intentionally leaves faulting frames and raised stack state intact;
   `Vm.run` rejects a subsequent run with `DirtyTopLevelEntry`
   (interp.zig:1586). Every protected C entry must capture its boundary,
   render diagnostics while frames/source are live, close discarded upvalues,
   drop region activations, restore depth/stack state, and clear transient
   error/multret state. The existing example is stdlib/errors.zig:63. Cover
   failures from table metamethods and reentrant calls, including
   diagnostic-allocation failure. Also specify that callback `eval/run`
   cannot simply invoke `Vm.run` while outer frames are active.

6. **Should-fix — §§3.5–3.6: the existing error path does not preserve
   `mh_error_set` messages.** Unknown native errors become `HostError`;
   `describeFault` does not read a C-wrapper error buffer (interp.zig:7354).
   Convert callback failure into a guest error value, for example through
   `raiseLocatedError`, so `pcall` receives the intended message. Preserve
   OOM and replay-integrity errors as fatal rather than converting everything
   into a catchable host error. `MH_ERR` also appears in §3.5 but is absent
   from §3.6's status enum. Panic containment must cover Rust destructors and
   other Rust callbacks, not only registered function bodies.

7. **Blocker — §3.5: binding pointers and native names need stable
   ownership.** A `Native.host` pointer cannot refer to an element of a
   growing `ArrayList(HostBinding)` stored by value. Specify stable
   allocation for bindings, including replacement and failed-registration
   cleanup. Additionally, an interned name's byte slice is **not** rooted by
   a native: GC treats `.native` as a leaf (gc.zig:680). If the registration
   key is removed while the function survives elsewhere, its name can dangle.
   Own the name bytes with the binding or add an explicit string edge/root.
   Define teardown order so closure destructors holding refs can release them
   safely.

8. **Blocker — §2/§3.5/§4/E8: host natives do not always fail restoration
   with `UnknownNative`.** Snapshots serialize only `Native.name`
   (keyframeser.zig:188); restore resolves that name against the registry
   (keyframeser.zig:669). A host override named `print` or `math.sqrt`
   silently restores as the builtin, potentially gaining a recordable-builtin
   tag. Until E8, reject capture containing host-bound natives explicitly, or
   encode distinguishable host identity. A name→binding map also cannot
   distinguish older escaped closures after re-registration under the same
   name.

9. **Should-fix — §3.5 option (c): retain it, but keep C-specific bindings
   out of the core.** The recorder already aborts untagged natives
   (trace_recorder.zig:4101); a new heap type is unnecessary for that
   property. Require `host != null ⇒ recorded == null`, and define the
   interaction with `effect`/`multi`. Putting `mh_vm`, `mh_status`, and C
   callback types into dependency-light `function.zig` contradicts §3.1's
   wrapper boundary. A generic Zig binding/invocation seam with a capi-owned
   trampoline avoids that coupling. Centralize invocation: `performEffect`
   also directly calls `nat.func`, so E6 would otherwise bypass a branch
   added only at the two ordinary call sites (interp.zig:7463).

10. **Should-fix — §3.7: the v1 staging is defensible, but its refusal policy
    is incomplete.** `.off` already exists as the default
    (02-determinism.md:97), so an explicitly non-replayable embedding
    milestone is consistent with current implementation staging. It does not
    yet fulfill the architecture's recorded-host-call commitment. Until E6,
    reject **both record and replay** with host bindings, covering
    registration, mode transitions, restore, and invocation. Otherwise a host
    native with `effect == null` still executes during replay.

11. **Should-fix — §3.7/E6: recording only the result cannot replay the
    proposed callbacks.** A callback may mutate globals/tables, invoke guest
    functions, produce nested effects, or fail. Recording its final
    scalar/string result and skipping it on replay loses mutations and nested
    execution. Nested effects also enter the current log before the enclosing
    callback returns. Doc 02 explicitly specifies host calls as logging
    inputs and outputs (02-determinism.md:390). E6 needs either a restricted
    external-effect callback contract or a protocol representing callback
    identity, failures, reentry, and guest-visible changes. Serializable
    return values alone are insufficient.

12. **Should-fix — §§3.2/5: choose one value ABI model explicitly.** A raw
    mirror and independently translated tag enum are different contracts.
    Translation requires conversion at every boundary; layout assertions do
    not make a reinterpretation correct after internal tags change. Prefer a
    stable public representation with fixed-width tags and explicit
    conversion, defining exposed heap kinds and rejecting internal `row_view`
    values. Verify size, alignment, offsets, and aggregate calling
    conventions through a compiled C consumer. Rooted string bytes can safely
    remain borrowed across GC and reentrant execution, provided the root and
    VM remain alive; borrow from the owning `Ref`, not merely `'vm`.

13. **Should-fix — §§3.2–3.7: complete the fallible API contracts.**
    String/table creation, ref creation, global setters, and metamethod
    getters can fail, yet several sketches return only values or nothing. Use
    consistent status/out-parameter forms. Define `mh_call`'s actual result
    count, truncation, and initialization of unused slots. Specify
    invalid/stale-ref behavior for reused indices, VM association,
    registration ownership on failure, and output-buffer ownership/freeing.
    Zero-default configuration also needs a way to distinguish "default JIT
    on" from "explicitly off."

14. **Should-fix — §§3.4/3.9/E5: iteration exposes a scaling problem the
    proposed benchmark misses.** Existing `next` allocates and sorts all hash
    keys on every step (stdlib/base.zig:98). Reusing it directly gives
    approximately **O(n² log n)** traversal with repeated O(n) scratch
    allocation. Specify a reusable iterator or mutation-aware ordered view.
    Benchmark large hash-table traversal, ref churn/root scanning, and
    repeated compilation—not just scalar crossings. Define representative
    sizes and allocation/work expectations before the corresponding phases
    land.

15. **Should-fix — E1–E8/§3.8: move prerequisites and ABI verification
    earlier.** E1 already returns heap strings and script results, so
    rooting, program-image ownership, and protected error boundaries belong
    in E1. Add a real C header-consumer test before relying on Rust
    integration tests; Zig and handwritten Rust declarations can agree while
    the header differs. Cargo's build must honor its target and use isolated
    output/cache paths. Add Rust tests to the normal validation gate once E4
    exists. `addLibrary` and static-default linkage are confirmed in the
    pinned toolchain. Separately, §3.7 must set `native_codegen`, not only
    enabled/execute/optimize, and capture `Vm.err` so `warn` does not escape
    to process stderr.

16. **Should-fix — API inventory/§4: clarify the practical embedding
    milestone.** Beyond the listed primitives, mlua users commonly expect
    typed argument/result conversions and tuples, independently created
    function values, mutable callbacks, scoped borrowed callbacks, host
    userdata, metatable/raw-table access, memory limits/accounting, and
    execution interruption. These need explicit priorities or exclusions;
    userdata especially matters to the stated "application data lives in
    Rust" use case. Multi-result host functions also deserve an earlier
    decision because they affect callback signatures.
