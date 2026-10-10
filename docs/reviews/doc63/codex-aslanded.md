# Codex — §5.10.1 "As landed" review (round 1, 2026-10-11)

Verbatim reply. Dispositions in `aslanded-dispositions.md`.

---

APPROVE WITH CHANGES

1. **[should-fix] §5.10.1 weakens §5.10’s required physical deferral.** [Doc:848](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:848) leaves slot rewrites and rebuilds undecided, but current [unpublishDoomed:197](/home/bart/Projects/lune/src/trace_registry.zig:197) already invokes physical teardown: [resetLinksTouchingDoomed:740](/home/bart/Projects/lune/src/trace_native_registry.zig:740) demotes promoted sets and rewrites surviving parents’ slots. A callback can doom other, ordinary traces too. **Fix:** explicitly require extracting logical unpublishing from this function and deferring link teardown, slot rewrites and rebuilds with the physical batch until both counters are zero, as §5.10 already requires.

2. **[nit] Seeds are not always above the current `stack_top`.** [Doc:874](/home/bart/Projects/lune/docs/design/63-trace-host-calls.md:874) overlooks nested guest frames: [bindAndPushClosure:2195](/home/bart/Projects/lune/src/interp.zig:2195) initializes slots overlapping the original seed span, then [pushFrameTrusted:2151](/home/bart/Projects/lune/src/interp.zig:2151) raises `stack_top` over them. Those slots can subsequently be walked or scrubbed. **Fix:** qualify this as untouched seeds remaining above `stack_top`; overlapping slots hold initialized guest values, and the changed epoch prevents subsequent seed reads. The safety argument remains sound.

The other factual claims checked match the source, including F1 coverage, collection ordering, recording cancellation and deferred step 8.

Bart, I kept all supplied rules in mind. No files or Git state changed; no builds ran.

[Codex thread: 01a123dc-056c-7e63-b5ed-8bae4448f147]
