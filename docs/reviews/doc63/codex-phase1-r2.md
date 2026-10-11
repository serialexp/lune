1. **[nit] The checklist still carries two round-1 overclaims.** [doc63:62](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:62) says there are no production readers, although `callHostNative` reads the epoch and updates `disturbs`. Lines 76 and 88 still say “+11 per host call,” while §5.9.1 correctly qualifies pure hosts and lists the larger disturbing-shape costs. **Fix:** copy those qualifications into the checklist and Outstanding item. Disposition 6 is therefore only partially reflected throughout the doc.

2. **[nit] §5.9.1 overstates what the gates and tests cover.** [doc63:885](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:885) includes region hooks and draining under `dispatchPostObserve`’s gate, but region observation precedes it at [interp.zig:3336](/home/bart/Projects/lune/src/interp.zig:3336) and remains explicitly deferred. Lines 891–895 also claim assertions execute in every test; the direct `abortRaised` test has no suspended back-edge ([capi_suspend_test.zig:365](/home/bart/Projects/lune/src/capi_suspend_test.zig:365)). **Fix:** list the actual gated recording steps, and restrict the assertion claim to tests exercising those paths.

The substantive dispositions resolve findings 1–5. The rewritten tests isolate epoch bumps, exercise cached unpatched entry, invalidate all four patch kinds, preserve a real outer recording, and supply the missing controls and lifecycle checks. The remeasured performance figures match the saved artifacts.

I found no dispatch-invariant defect in the current paired usage. The bit prevents nested `.fast` entry: assembly rejects the nonzero whole word ([hostcall_x64.S:138](/home/bart/Projects/lune/src/asm/hostcall_x64.S:138)), H1 reaches `execWithEntry`, and mode handoffs reselect through `runFastPath`. An outer `.fast` handler remains paused during the callback; the owner’s defer lowers suspension before it resumes. Setting the bit alone does **not** switch an already-running chain, so that ownership ordering remains essential.

Nested raise/lower keeps the bit synchronized, and unrelated bit clears preserve it. I found no new implementation blocker.

**Overall verdict: APPROVE**, with the documentation nits above.

Bart, I kept all supplied rules in mind. No files or git state changed; I ran no builds or tests.

[Codex thread: 01a123dc-056c-7e63-b5ed-8bae4448f147]
