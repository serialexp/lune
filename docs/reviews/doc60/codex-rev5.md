# Doc 60 rev 5 — codex review (2026-10-03)

Reviewer: Codex (configured default model), thread 01a10006-f83f-7f63-a6fe-5540a168c25b.
No repository files changed (probes and caches under /tmp); project test suite not run.

APPROVED

## BLOCKERS

1. None. All 18 rev-4 findings are addressed at design level or explicitly superseded as §10 claims. This includes dispatch-mode selection, symmetric reentry ownership, unwind paths/settings, archive extraction, PIC/visibility, recorder migration, and differential comparisons.

2. The delayed reentry increment is unobservable. Between today's increment and dispatch, closure binding and frame push perform bounds checks and stores; neither reads `native_reentry_depth` nor invokes callbacks or safepoints (binding interp.zig:2141, register stores interp.zig:1073, push interp.zig:2020). The other runtime reader, `vmIdle` (capi.zig:306), runs during park clearing before this interval. The runner's paired `defer` preserves callback-time depth and restores it before fault handling or result parking.

## SHOULD-FIX

1. None. Q12's openness is acceptable, and both options are correctly described. Option (a)'s executable pointer/length checks—including actual `[]Value`, ArrayList items, and clearing the length word—passed pinned-toolchain probes in Debug and ReleaseFast. Option (b)'s `usize` mirror and successful-append/idle-clear updates cover the production mutations (capi.zig:313).

## NITS

1. Document line 311 names `mh_new`; the constructor is `mh_vm_new` (capi.zig:475). The same naming slip appears at lines 78 and 1127.

2. Document line 436 cites `interp.zig:2470` for the signature; its exact location is interp.zig:2475.

(Both nits fixed in the rev-5 commit.)
