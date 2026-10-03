# Doc 60 rev 4 — codex review (2026-10-03)

Reviewer: Codex (configured default model), thread 01a0fff5-15ac-7310-88e6-63e5cc2d9ec1.
No repository files changed (probe and caches under /tmp); project builds and tests not run.

CHANGES REQUESTED

## BLOCKERS

1. **The shared runner must preserve H1's initial dispatch-mode check.** doc60:408 specifies unconditional `chainEntry(.fast)`, and line 436 says H1 uses that runner too. But fast-word rejection sends calls with active recording or pending hooks to H1. Today, interp.zig:2478 checks `runFastPath()` before entering `.fast`; otherwise it uses `execWith(stop_depth)`. Starting H1 in `.fast` skips the recording and anchor hooks guarded by `.full` at interp.zig:2880. Specify the initial check in `runPushedFrame`, before dispatch, and test calls entering with nonzero fast words.

## SHOULD-FIX

1. **Q12(a)'s proposed layout verification does not work.** doc60:297 proposes recovering slice component offsets from pointer type information and checking their order through comptime `@bitCast`. The pinned compiler rejects `@bitCast` from a slice: the `/tmp` probe produced `error: cannot @bitCast from '[]const u8'`. Pointer metadata at pinned `lib/std/lang.zig:597` contains no physical component offsets; constructing an `extern struct` establishes that struct's layout, not the slice's. Replace this with an executable verification mechanism covering `[]u8`, `[]u64`, and `[]Value`.

   Q12(b)'s pointer mirrors and idle fallback preserve the representation boundary, but `parked_overflow_len: u32` narrows an unbounded `usize` length. capi.zig:333 imposes no such limit. Use `usize` or a nonempty flag, updated only after successful append and on clear. **Q12 remaining undecided is not itself a blocker.**

2. **The unwind acceptance still requires frames that do not exist on two paths.** doc60:859 applies `host → entry → shim → handler` to normal execution, fallback, and the park helper. The pre-prologue `jmp` removes the assembly entry from the fallback's physical stack; during result parking, the chain and shim have already returned (doc60:528). Specify expected retained frames separately for each path. For the frame-pointer test, configure the host fixture and callbacks as well as Zig modules; explicitly enable the unwind information needed by the DWARF test.

3. **Force archive extraction in the visibility/PIC acceptance test.** doc60:849 does not specify what pulls `libmahina.a` members into the shared library. An unused archive can yield an empty library that passes every listed check. Require whole-archive inclusion or a retained consumer referencing `mh_call`, and verify that the entry was linked. Also distinguish defined symbols from undefined references: marking only the entry `.hidden` at doc60:469 does not establish hidden visibility for every assembly reference required by the per-object check.

4. **The owned-recorder migration misses a direct stop mutation.** The documented 58 reset sites and their per-file counts are correct. However, trace_gate_test.zig:1067 directly writes `state.rec.active = false` after starting through `onBackEdge`. That also bypasses synchronization. Include it in doc60:715's migration, using an owner operation that preserves the test's intended abort/gate behavior.

5. **Compare reentry depth explicitly in the differential tests.** doc60:773 lists depth and stack top but omits `native_reentry_depth`. Add it after every call, particularly catchable errors, fatal errors, nested calls, and parking OOM.

   The proposed error decrement itself **does match today**: interp.zig:2103 decrements once through `defer`, after execution's error cleanup and before `guestFault`. §4.3's abort → anchor clear → decrement → fault handling order is consistent with that source.

## NITS

1. **The coexistence conclusion holds, but "checks only `rec.active`" remains inaccurate.** doc60:666 describes `onRetResume`, which additionally checks configuration, varargs, resume bounds, patch collisions, existing traces, recording eligibility, allocation, and hotness (trace.zig:3448). The table likewise omits several guards. Label it as an inventory of guards relevant to coexistence, or enumerate the remaining guards. The corrected consumers, displacement, stale-parent cleanup, and three coexistence cases are supported by source.

2. **Clarify the null-argument test expectation.** doc60:802 associates `.err_api` with both null-argument lengths. `args == NULL, nargs == 0` is valid; only the nonzero case is rejected (capi.zig:708).

3. **Correct two source descriptions.** doc60:430 calls `callValue`'s decrement an *errdefer*; it is a *defer*. Also, doc60:279 should distinguish the frame-cache sentinel, which forces a miss, from a sentinel **registry generation**, which prevents both hits and fills (interp.zig:2652).

The rev-3 audit leaves Codex S1, S2, S4, and consequently S7 partially addressed for the reasons above. The remaining "addressed" findings—Codex B1, S3, S5, S6, N1–N3; Antigravity B1, S1–S4, N1–N3—are specified at design level. Both B2 findings remain intentionally open, subject to the Q12 corrections above. All new file:line citations were checked; the issues found concern their descriptions rather than displaced line numbers.
