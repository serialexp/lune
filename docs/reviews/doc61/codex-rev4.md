# Doc 61 rev 4 — codex review (2026-10-05)

Thread 01a10978-f8f4-7670-8baf-b5a666842ac2. Verdict: **REVISE**. Folded into rev 5.

Rev 3 blockers 1 and 4–6, and both should-fixes, are addressed. The interim watermark gate is sound for compiler-generated numeric loops: non-captured slots above `base+4` are dead at body entry and after scope release (`compiler.zig:944`, `bc_liveness.zig:254`). Rev 3 blockers 2 and 3 remain incomplete.

## Blockers

1. **Lower retained faulting frames lose their classification.** §4.2 restores markers on error, but `callValue` deliberately retains the physical frames (`interp.zig:2266`).
   - Example: protected function → Lua `__add` metamethod → fault → collecting `xpcall` handler. The protected function's marker has reverted to false, while its pc still names `.add` (`interp.zig:2965`, `:7106`).
   - Marking only the leaf leaves that parent outside §4.1–4.4. An all-live fallback can root stale slots, and a coincidental preceding `.call` can misclassify it.
   - → Rev 5 §4.2: the flag is left set on error, and the catcher restores the surviving frame.
2. **Keeping every φ does not make non-maskable frames coherent.** Ordinary exit snapshots deliberately omit dead definitions (`trace_recorder.zig:1433`), and materialisation writes only recorded slots (`irinterp.zig:214`). A mid-iteration exit can retain an earlier heap value where tier-0 holds a newer one. → Rev 5 §2: exit snapshots are a third elision site, gated on `maskable` in §5.
3. **The fault-marker snippet underflows at depth zero.** Host entry supports native callees through `runProtected` (`capi.zig:796`). A host-called `xpcall` can catch an invalid callee or a failing native without any frame being pushed (`interp.zig:2216`, `errors.zig:69`). → Rev 5 §4.4: mark only when `depth > entry_depth`.

## Should-fixes

- **Scope the push assertion.** Metamethod re-entry pushes while the caller holds the operator pc. → Rev 5 §4.3.
- **Correct P2's restoration claims.** Native opcode calls have no success-side `stack_top` lowering, and top-level `exec` propagates faults without unwinding (`interp.zig:2511`). → Rev 5 §3 P2.
- **Keep the backtrace correction with the frame-state work.** `backtraceFrames` and `callSiteAt` subtract one from every parent pc (`interp.zig:1975`). → Moved into Phase 0.
