CHANGES REQUESTED

Bart, precise mode resolves the loop-done and armed-exit replay problems. Dupe-only finalization, materializer order, link refusals and the LuaJIT bool correction check out. The callback boundary still has these gaps:

1. **[blocker] Empty snapshots need a new validated contract.**  
   [63:224](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:224) proposes an empty precise snapshot, but [trace_snapshot.zig:247](/home/bart/Projects/lune/src/trace_snapshot.zig:247) requires a full window, native admission repeats that requirement, and [interp.zig:4700](/home/bart/Projects/lune/src/interp.zig:4700) requires the actual register count. Setting that count to zero cannot work. **Fix:** define an explicit slab-coherent snapshot/exit form, restricted to approved sites, and update validation, admission and both consumers in Phase 2.

2. **[blocker] Host errors would still overwrite callback mutations — R1 #12 remains incomplete.**  
   [63:381](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:381) says callback mutations survive, but tier-1a restores the pre-call snapshot at [irinterp.zig:1395](/home/bart/Projects/lune/src/irinterp.zig:1395), and native errors call the same restoring materializer at [nativegen.zig:2731](/home/bart/Projects/lune/src/nativegen.zig:2731). A callback can change an open upvalue, collect its former value, then fail; restoration can resurrect a freed pointer. **Fix:** keep the full `B` snapshot for preflush, but use a non-restoring error continuation at `B`. Test mutation + collection + host failure.

3. **[blocker] Seed copies are extra roots after callback mutation — R1 #6 remains open.**  
   The equality argument at [63:308](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:308) holds only while the original references remain. Seeds copy globals/upvalues into synthetic slots ([interp.zig:1198](/home/bart/Projects/lune/src/interp.zig:1198)); doc 61 roots gaps wholesale ([61:974](/home/bart/Projects/lune/docs/design/61-gc-liveness-masking.md:974)). A callback clearing the original reference and collecting leaves the seeded copy alive only in the traced run. **Fix:** separate overwrite protection from GC rooting; exclude synthetic seed storage from semantic roots and prove remaining register-held pointers safe on the forced exit. Test explicit callback collection with `gc_stress` off: the entry guard rejects traces under stress ([irinterp.zig:833](/home/bart/Projects/lune/src/irinterp.zig:833)).

4. **[blocker] Deferring retirement does not protect weak constants — R1 #8 remains open.**  
   [63:393](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:393) defers retirement, while doc 61 requires invalidation before sweep and assumes no executing trace ([61:1137](/home/bart/Projects/lune/docs/design/61-gc-liveness-masking.md:1137)). Sweep still frees white objects ([gc.zig:757](/home/bart/Projects/lune/src/gc.zig:757)); retained code/pools then contain dangling pointers, including during a second callback collection. **Fix:** specify immediate logical invalidation, exclusion from subsequent pool scans, and deferred physical destruction until the outer executor and consumer release their borrows. Preserve guest GC timing. Extend Phase Q’s string-only audit to `Native` constants and make this a Phase 2 prerequisite.

5. **[blocker] Shim-only suspension leaves recording callbacks uncovered — R1 #7 is only partly resolved.**  
   [63:406](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:406) leaves tier-0 host calls unaffected. During precise recording, however, tier-0 makes the host call ([interp.zig:6761](/home/bart/Projects/lune/src/interp.zig:6761)); nested guest instructions feed the same recorder ([interp.zig:3237](/home/bart/Projects/lune/src/interp.zig:3237)), whose snapshot builder assumes the anchor activation ([trace_recorder.zig:1493](/home/bart/Projects/lune/src/trace_recorder.zig:1493)). **Fix:** suspend recorder driving across recorded tier-0 host calls too, then reconcile or cancel recording after callback mutation. Enumerate suspension gates for patched entries, backedges, head/continuation hooks, unwind hooks and physical teardown; selecting fast/full dispatch alone does not gate patched entries ([interp.zig:5978](/home/bart/Projects/lune/src/interp.zig:5978)).

6. **[blocker] Result-type failure must preserve the actual boxed results.**  
   [63:227](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:227) uses an ordinary precise snapshot for result guards. Existing materialization boxes by the statically proved kind ([nativegen.zig:767](/home/bart/Projects/lune/src/nativegen.zig:767)); it cannot restore an unexpected actual type through an unboxed result home. Ordinary derived numeric guards also emit nothing ([nativegen.zig:1120](/home/bart/Projects/lune/src/nativegen.zig:1120)). **Fix:** specify dynamic tag checks before unboxing, with non-restoring `B+1` exits while results remain authoritative in the slab. Test int→float, bool→heap, nil, and a mismatch in a later result.

7. **[should-fix] Precise traces do have heap φ homes.**  
   [63:355](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:355) contradicts precise write-dominated carried-slot admission at [nativegen_alloc.zig:515](/home/bart/Projects/lune/src/nativegen_alloc.zig:515). Flushing roots a value; it does not eliminate its machine home. **Fix:** replace the “no heap φs” assertion with a call-site rooting/liveness proof, retaining admission refusal for unsupported cases. Cover carried tables and repeated `tnew` in native tests.

8. **[blocker] Q4 changes the observable recursion limit by tier.**  
   The shim adds a reentry level ([63:359](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:359)); tier-0 host dispatch adds none ([interp.zig:6761](/home/bart/Projects/lune/src/interp.zig:6761)). Callback `callValue` already increments and checks that counter ([interp.zig:2314](/home/bart/Projects/lune/src/interp.zig:2314)). The traced path can therefore raise `StackOverflow` earlier. **Fix:** count uniformly across tiers or use a separate internal host-buffer bound. Test the exact limit across tiers.

9. **[should-fix] Leaf error location is captured before cold materialization.**  
   [63:430](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:430) skips frame writes, but `cHostCall` immediately calls `raiseLocatedError` ([capi.zig:1130](/home/bart/Projects/lune/src/capi.zig:1130)), which reads the current frame PC ([interp.zig:1762](/home/bart/Projects/lune/src/interp.zig:1762)). Later materialization cannot repair the already located message. **Fix:** publish `pc=B` before invocation or defer location construction to the cold continuation. Compare caught messages across tiers.

10. **[should-fix] Snapshot coverage alone does not fix helper OOM handling.**  
    [63:260](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:260) includes allocation failures, but string-helper null returns leave `runtime_error` zero ([irinterp.zig:845](/home/bart/Projects/lune/src/irinterp.zig:845)), producing `.precise_resume` and retrying the failed allocation. A one-shot OOM can then disappear. **Fix:** distinguish helper errors from guard misses and propagate allocation failures through `.precise_error`; test injected OOM after a host call.

11. **[should-fix] The callback performance bound is incompatible with suspension.**  
    [63:515](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:515) allows only one exit/reentry overhead, but today nested execution can JIT ([interp.zig:2726](/home/bart/Projects/lune/src/interp.zig:2726)). Suspending a hot nested guest loop adds work proportional to its entire execution. **Fix:** make that tradeoff explicit and benchmark substantial hot nested workloads. Also vary argument count, physical window size and seeds. Keep 250/320 provisional; land the coherent-exit ABI, statuses and GC lifetime protocol before Phase 2 executes callbacks.

12. **[nit] The allocation epoch policy contradicts itself.**  
    [63:328](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:328) bumps every C API entry outside a whitelist, but line 333 exempts allocations absent from that whitelist. The actual symbol is `mh_string_new` ([capi.zig:990](/home/bart/Projects/lune/src/capi.zig:990)). **Fix:** explicitly list allocation-only exemptions and their no-reentry/no-collection arguments, or consistently bump them. The budget recheck is otherwise the right mechanism.

13. **[nit] §3 conflates native admission with all precise traces.**  
    [63:162](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:162) describes precise traces as loop-only, but tier-1a precise head traces are supported and tested ([interp_trace_test.zig:7140](/home/bart/Projects/lune/src/interp_trace_test.zig:7140)). **Fix:** identify this as the current native limit and the proposed host-call admission policy.

Read-only throughout; no builds or tests run. I kept all supplied rules in mind.

[Codex thread: 01a123dc-056c-7e63-b5ed-8bae4448f147]
