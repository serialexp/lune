CHANGES REQUESTED

Bart, round-3 #1 and #3–#7 are addressed in the proposed contracts. #2 remains incomplete. Antigravity’s metadata and stable-address changes are sound, but the shim still needs an explicit trace owner.

1. **[blocker] Protecting seeds changes the observable stack limit.**  
   [63:440](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:440) raises `stack_top` over synthetic seeds. Callback frames start at that higher top and check capacity there ([interp.zig:2122](/home/bart/Projects/lune/src/interp.zig:2122)); the slab has a fixed 65,536-slot limit ([interp.zig:125](/home/bart/Projects/lune/src/interp.zig:125)). A callback that fits in tier-0 can therefore raise `StackOverflow` when traced. Error handlers have the same problem while the protected top remains raised.  
   **Fix:** protect seeds without reducing guest stack capacity—for example, save them in unrooted episode scratch and restore only after the epoch check permits continuation. Add callback and `xpcall`-handler tests at the capacity boundary.

2. **[blocker] Physical retirement is still gated by suspension rather than the borrow lease.**  
   [63:699](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:699) permits immediate physical work whenever `suspend_depth == 0`. But the new blacklist retirement occurs inside the precise consumer at depth zero ([63:663](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:663)), while `enterPatchedTrace` still holds and subsequently accesses its patch ([interp.zig:5455](/home/bart/Projects/lune/src/interp.zig:5455)). Immediate teardown and patch reuse recreate round-3 #2.  
   **Fix:** require both zero suspension depth **and no outstanding entry lease** for physical retirement, slot mutation and patch draining. Apply that condition to every retirement source, including blacklist exits. Test blacklist retirement through a patched entry.

3. **[blocker] Recording-time suspension has no physical-release point.**  
   `callHostNative` also suspends during tier-0 recording ([63:601](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:601)), reached directly from [interp.zig:6761](/home/bart/Projects/lune/src/interp.zig:6761). Callback GC can queue retirement, but the only release point specified is an entry wrapper that entered a trace ([63:701](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:701)); this path has no such wrapper. Queued records and stale physical links can consequently survive into later execution.  
   **Fix:** when the outermost recording-time host call returns, drain deferred work if no entry lease remains, before permitting subsequent trace entry. Cover success and failure, repeated collections, and a recording that aborts without ever entering a trace.

4. **[should-fix] The shim arguments do not identify the owning trace.**  
   [63:554](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:554) passes only `NativeSeedCtx` and `HostCallSite`, yet the shim must set `suspended_trace`. The site contains trace-local indices ([63:277](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:277)); the context contains activation information but no trace owner ([trace_code.zig:266](/home/bart/Projects/lune/src/trace_code.zig:266)). `prepareNativeEpisode` likewise receives no trace ([interp.zig:1480](/home/bart/Projects/lune/src/interp.zig:1480)).  
   **Fix:** pass or publish an explicit borrowed owner before executor entry. Use it for `suspended_trace`, trace-local metadata and the protected-span calculation; retain it through logical invalidation rather than resolving it from the live registry.

5. **[should-fix] The patched bypass must preserve instruction-pointer provenance.**  
   [63:623](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:623) says all four suspended handlers run `patch.orig`. For head and continuation handlers, the source explicitly forbids passing `&patch.orig`: straight-line dispatch advances the instruction pointer, and that detached object has no successor ([interp.zig:6134](/home/bart/Projects/lune/src/interp.zig:6134), [interp.zig:6246](/home/bart/Projects/lune/src/interp.zig:6246)).  
   **Fix:** specify `&proto.code[cur_pc]` for head/continuation bypasses; retain the loop handlers’ existing canonical-step discipline. Test suspended bypass followed by straight-line instructions.

The prerequisite ordering remains reasonable; the instruction budgets still need Phase 0 measurement.

Read-only throughout; no builds or tests run. I kept all supplied rules in mind.

[Codex thread: 01a123dc-056c-7e63-b5ed-8bae4448f147]
