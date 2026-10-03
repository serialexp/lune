# Doc 60 rev 5 — antigravity review (2026-10-03)

Reviewer: Antigravity (tools enabled, read-only instruction). No files modified.

Verdict: APPROVED

### Summary of Revision 5 Review

Revision 5 successfully resolves all outstanding blockers and should-fix issues from revision 4 across both reviewers:
1. **Reentry lifecycle encapsulation (Antigravity B1)**: `runPushedFrame` now symmetrically owns `native_reentry_depth += 1` with a paired `defer self.native_reentry_depth -= 1`. Nothing between parameter binding/push and `runPushedFrame` reads or mutates `native_reentry_depth`, making the move completely unobservable.
2. **Initial dispatch-mode check (Codex B1)**: `runPushedFrame` now checks `runFastPath()` before dispatching to `.fast` or falling back to `execWith(stop_depth)`, preserving the `.full` mode hooks guarded at `src/interp.zig:2880`.
3. **Unwind acceptance per path (Codex S2 / Antigravity B2)**: §3.3 and §6.3 separate expected stack frames for normal execution, host callbacks, pre-commit fallback, and result-park overflow. The build requirements accurately reference the pinned stdlib (`unwind_tables` at `Build/Module.zig:214`, `omit_frame_pointer` at `Build/Module.zig:229`).
4. **Q12 representation options**: Both options are soundly and accurately described. Option (a) replaces the rejected comptime slice `@bitCast` with executable verification in unit tests and VM creation, while Option (b) widens `parked_overflow_len` to `usize` to match `src/capi.zig:333`.
5. **Acceptance and linkage fixes**: archive member extraction (`--whole-archive`, consumer referencing `mh_call`), hidden visibility on undefined assembly references, the test direct-stop migration via `stopRecordingForTest()` (`src/trace_gate_test.zig:1067`), `ChainResult` field order (`status` first in `%eax`), PIC module compilation (`.pic = true`, `Build/Module.zig:225`), and explicit `native_reentry_depth` differential comparisons are all accurately specified.

### Verification of Rev-4 Findings (§10 Claims vs Codebase)

All 17 rev-4 items in §10 were audited against the repository sources and pinned stdlib and verified: Codex B1 (mode check, `interp.zig:2478`, `.full` via `execWith` at `:2528`, hooks at `:2880`); Antigravity B1 (symmetric reentry); Codex S2 / Antigravity B2 (per-path frames); Codex S1 (executable Q12(a) verification, `usize` mirror); Codex S3 (archive extraction, hidden references); Codex S4 (`stopRecordingForTest`); Codex S5 (reentry comparison); Antigravity S1 (`base` forwarded); Antigravity S2 (`final_cut`, entry capture); Antigravity S3 (PIC); Antigravity S4 (`ChainResult` order); Codex N1–N3; Antigravity N1–N3.

### Observability of moving the `native_reentry_depth` increment

Completely unobservable.
1. The only runtime reads/writes of `native_reentry_depth` are `vmIdle` (`src/capi.zig:307`) and `callValue` (`src/interp.zig:2101–2103`); the rest are the declaration (`:616`) and comments.
2. Between the old increment point and the new one, the code runs the depth check (`interp.zig:2145`), the register-capacity check (`:2163`), the straight-line bind and nil-fill (`:2165–2185`), and `pushFrameTrusted` (`:2020–2039`). None reads `native_reentry_depth`.
3. Binding and push are allocation-free and straight-line; no GC safepoint or callback can intervene.
4. Error paths: today a failed depth/capacity check returns `StackOverflow` and the `defer` restores the counter; in the new design those checks run before the increment. The post-failure value is identical.
5. During guest execution the counter is already incremented, so a nested `mh_call` from a host callback sees `vmIdle == false`. On error and on success the `defer` restores it before `guestFault` / result parking, matching `runProtected` today (`capi.zig:401`, `:403`).

### BLOCKERS

None.

### SHOULD-FIX

None.

### NITS

1. **Ensure runtime evaluation for the Q12(a) pointer-cast check.** Under the pinned compiler, comptime-evaluating `@as(*const [2]usize, @ptrCast(&s))` for a comptime-known slice fails with `error: comptime dereference requires '[]const u8' to have a well-defined layout`. The test must use a runtime value (`var s`, or escape the address via `_ = &s`).
2. **Constructor name.** Lines 78, 311 and 1127 say `mh_new`; the public symbol is `mh_vm_new` (`include/mahina.h:119`, `src/capi.zig:475`).

(Both nits fixed in the rev-5 commit.)
