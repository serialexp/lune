CHANGES REQUESTED

Bart, the ordinary-call changes address round-2 #1, #2, #6–#9, #12 and #13; #10 is now an explicit prerequisite. The remaining gaps concern #3, #4, #5 and #11, plus the revised leaf path. Precise loop-done behavior, link refusals, dupe-only finalization and materializer order check out.

1. **[blocker] A logically retired native trace cannot reach the proposed precise consumer.**  
   [63:630](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:630) removes doomed traces from lookup, but [interp.zig:4492](/home/bart/Projects/lune/src/interp.zig:4492) resolves `final_trace_id` and panics on failure **before** `.precise_error` or `.precise_resume` handling. Checking `ct.retired` inside those consumers is too late.  
   **Fix:** route precise terminal results through the retained entered-trace borrow before live-ID resolution and ordinary post-run drains. Validate that their final ID equals `ct.id`. Test callback collection that invalidates the executing trace, on both success and error.

2. **[blocker] The deferred-destruction release point does not cover entry-patch borrows.**  
   [63:634](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:634) permits draining once the dispatcher consumes the result. However, `enterPatchedTrace` retains its patch pointer across `enterSelectedTrace` and accesses it afterward ([interp.zig:5339](/home/bart/Projects/lune/src/interp.zig:5339), [interp.zig:5455](/home/bart/Projects/lune/src/interp.zig:5455)). Phase Q’s transaction also rewrites slots, tears down promoted state and drains/reuses entry patches ([61:1251](/home/bart/Projects/lune/docs/design/61-gc-liveness-masking.md:1251), [61:1274](/home/bart/Projects/lune/docs/design/61-gc-liveness-masking.md:1274)); deferring only record destruction does not isolate that transaction.  
   **Fix:** explicitly split Phase Q into immediate logical invalidation and deferred physical work. Hold a lease through the enclosing entry wrapper’s final patch access, then perform the physical batch and patch drain. Reserve queue storage before execution.

3. **[blocker] Error cleanup exposes unsrubbed seeds as ordinary GC gaps.**  
   [63:436](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:436) clears `trace_seed_span` while leaving `stack_top` raised. If the callback drops a seed’s original reference and fails **without collecting**, the synthetic copy remains. An `xpcall` handler runs before unwind ([errors.zig:104](/home/bart/Projects/lune/src/stdlib/errors.zig:104)); its collection roots those now-unmarked gap slots under [61:977](/home/bart/Projects/lune/docs/design/61-gc-liveness-masking.md:977). Root-set equality still fails.  
   **Fix:** scrub the seed span before clearing its descriptor on error, or retain an owned exclusion through unwind. Test callback mutation without collection, followed by handler collection.

4. **[blocker] Leaf result-type exits use `C_B1` without establishing slab coherence.**  
   The leaf path skips preflush ([63:667](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:667)) and writes only results ([63:673](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:673)). Yet `host_result` mismatch takes the non-restoring `C_B1` exit ([63:288](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:288)). Other locals can remain stale; precise materialization explicitly accounts for carried homes newer than the slab ([nativegen.zig:747](/home/bart/Projects/lune/src/nativegen.zig:747)). The leaf sequence also needs an explicit exception to the placement/admission rule requiring the epoch guard.  
   **Fix:** retain preflush initially, or define a leaf mismatch materializer that restores other slots while preserving every actual result. Specify the leaf placement rule separately. Test result drift after several iterations with changing carried locals.

5. **[blocker] The listed suspension gates miss entry and recovery work outside those gates.**  
   Gating `onBackEdge` ([63:571](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:571)) does not gate the subsequent cached-trace entry decision at [interp.zig:7088](/home/bart/Projects/lune/src/interp.zig:7088). Adding suspension to the patched handlers’ R1-5 bypass also misses their earlier non-live recovery: `unpatchSlot` runs at [interp.zig:5931](/home/bart/Projects/lune/src/interp.zig:5931), before the bypass at `:5980`; all four handlers have this ordering. Callback GC can create exactly that non-live state.  
   **Fix:** gate selection in the shared back-edge entry path, and bypass patched handlers before non-live recovery or physical mutation. Execute the canonical instruction exactly once. Test cached unpatched entry and logically invalidated patched entry during suspension.

6. **[should-fix] The blacklist does not establish “at most once per native.”**  
   [63:603](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:603) retires only the trace whose epoch exit observes disturbance. Other cached traces calling that native remain eligible; `guard_native` checks identity only ([63:272](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:272)). A disturbing call that fails takes `C_B` before the epoch guard, so that retirement rule never runs. The common funnel also currently returns directly on callback failure ([interp.zig:2269](/home/bart/Projects/lune/src/interp.zig:2269)); disturbance accounting must cover that return. Consequently, §8’s bounded suspension budget is unsupported.  
   **Fix:** check the disturbance threshold before every traced invocation, or invalidate all dependent traces on first disturbance. Count disturbance on success and failure identically across tiers. Benchmark two cached callers and repeated caught callback failures.

7. **[nit] `mh_error_set` does not guarantee an error exit.**  
   [63:462](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:462) says it sets the pending error and forces `lua_error`. It actually stages `host_error` text ([capi.zig:1152](/home/bart/Projects/lune/src/capi.zig:1152)); only a non-OK callback return raises ([capi.zig:1128](/home/bart/Projects/lune/src/capi.zig:1128)).  
   **Fix:** justify the exemption by its lack of changes to guest state or trace assumptions, and test staging a message followed by a successful return.

The phase ordering is reasonable with these lifetime and suspension gaps resolved; 250/320 should remain provisional until Phase 0.

Read-only throughout; no builds or tests run. I kept all supplied rules in mind.

[Codex thread: 01a123dc-056c-7e63-b5ed-8bae4448f147]
