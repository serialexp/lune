# Doc 58 rev 3 (Option B) — design review round 3 (Antigravity, 2026-09-27)

**Verdict: APPROVE WITH CHANGES.** Dispositions are in doc 58 §8b.

**Round 2 findings 1–2 (coarse deopt runs the body twice): the reviewer
agrees they are refuted.** Evidence it cited:

- `deopt_exit` flushes `slotHomePlace(s)` (`nativegen.zig` ~2724–2761);
  the homes are written only by the `.loop` parallel move
  (~2110–2162).
- In-place home coalescing is refused when any side-exiting instruction
  follows the store (`nativegen_alloc.zig` ~1180, `opMayExitInBody`
  ~1631–1685), so no home is overwritten before the condition guard.
- Worked example: `while n < 3 do n = n + 1 end` ends with `n == 3`.
- Sunk stores (`astore`/`hstore`/`ustore`/`sgm_setpos`) flush just
  before `.phi`/`.loop`, after the guard (`trace_recorder.zig`
  ~2686–2704, ~3203–3212, ~4800–4803, ~5707–5716; `trace_finalize.zig`
  ~45–56).
- Pure-write stores (no prior heap load) are deopt-idempotent
  (`trace_recorder.zig` ~2634).
- `astore_append` bumps `len` in memory; a replay is an in-bounds
  overwrite (`nativegen.zig` ~1875–1893).
- `tnew` exists only on precise traces (`nativegen.zig` ~1395,
  `trace_finalize.zig` ~324).
- `rbx` increments only at `.loop` (`nativegen.zig` ~2160).
- The peeled zero-completion skip replays from the entry state
  (~2738–2744).
- Tier-1a flushes only at `.loop`/`.link`/terminal (`irinterp.zig`
  ~1319).

Findings:

1. **MAJOR:** with `isOwnLoopTest` excluded from
   `isSourceBranchGuardExit`, a loop exit that `routeExitSide` does not
   take falls into `noteTakenExit`'s `completed == 0` route
   (`trace_link.zig` ~424–450). That route raises a same-anchor side
   want, unpatches the entry, and records a pass that ends in LLEAVE.
   Today, numeric `for` avoids this because `any_loop_done` suppresses
   `count_exit` (`interp.zig` ~4465). Fix: return right after
   `routeExitSide` for own-loop tests.
2. **MINOR:** `isOwnWhileTestCopy` can never match after B2 (the
   backward `jmp` targets the condition, not the anchor); delete it in
   B2, not B3.
3. **MINOR:** the generic `for` extent `[header − 1, tfor_loop]` is
   asymmetric with numeric `for`'s `[header, for_loop]`; use
   `[header, tfor_loop]`.
4. **NIT:** `continuationReachesEnclosingBackEdge`
   (`trace_exit_attach.zig` ~488–502) has no `.jmp_if_false` arm, so an
   enclosing `repeat` is not recognised today.
