# Antigravity — §5.10.1 "As landed" confirmation (round 2, 2026-10-11)

Verbatim reply.

---

# Confirmation Review: [`docs/design/63-trace-host-calls.md`](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md) (§5.10.1 "As landed")

**Verdict:** **APPROVE**

The three revisions to §5.10.1 documented in [`docs/reviews/doc63/aslanded-dispositions.md`](file:///home/bart/Projects/lune/docs/reviews/doc63/aslanded-dispositions.md) have been re-read and verified against the codebase. All three accurately resolve the review findings and align with the runtime architecture.

---

### Verification of the Three Changes

#### 1. Unpublishing Split & Deferred Physical Teardown (Codex Finding 1 / Antigravity Finding 1)
- **Design text:** §5.10.1 now recognizes that [`unpublishDoomed`](file:///home/bart/Projects/lune/src/trace_registry.zig#L195-L220) currently performs physical work by calling [`resetLinksTouchingDoomed`](file:///home/bart/Projects/lune/src/trace_native_registry.zig#L740-L771) (which demotes promoted sets, drops parked proofs, and rewrites surviving parents' slots via `commitSlotMutation`). It also notes that a callback collection can doom any trace (including ordinary parent traces). Consequently, Phase 2b must extract the logical unpublishing operations (marking `doomed = true`, `trace_by_id` clearing, anchor unlinking, cache compaction, marking entry patches non-live and pending) and defer all physical work (link teardown, slot rewrites, promoted-state teardown, `destroyDoomed`, and graph rebuilds) until both counters (`suspend_depth == 0 && entry_leases == 0`) reach zero.
- **Code verification:**
  - Verified in [`src/trace_registry.zig:197`](file:///home/bart/Projects/lune/src/trace_registry.zig#L197): `self.native_physical.resetLinksTouchingDoomed(&self.mcode_arena, &self.retire_work)` is directly invoked inside `unpublishDoomed`.
  - Verified in [`src/trace_native_registry.zig:756-764`](file:///home/bart/Projects/lune/src/trace_native_registry.zig#L756-L764): `commitSlotMutation` mutates code slots of surviving parents.
  - Verified in [`src/interp.zig:2563-2573`](file:///home/bart/Projects/lune/src/interp.zig#L2563-L2573): `invalidateDeadTraceConsts` scans every trace in `cache`, so a host callback collection can retire arbitrary traces across the system.
  - Deferring this entire physical batch to the release point eliminates race conditions and matches the core requirement of §5.10.

#### 2. Seed Span Qualification for Nested Guest Frames (Codex Finding 2)
- **Design text:** §5.10.1 clarifies that seeds not overwritten by the callback lie above `stack_top` and are neither walked nor scrubbed. However, if a callback invokes a guest closure, a nested guest frame is laid out over part of the seed span via [`bindAndPushClosure`](file:///home/bart/Projects/lune/src/interp.zig#L2176-L2201) and [`pushFrameTrusted`](file:///home/bart/Projects/lune/src/interp.zig#L2151), raising `stack_top`. Those overlapping slots hold that frame's initialized values and may be walked or scrubbed during a collection. In either case, running guest code or collecting increments `host_epoch`, so the resuming trace exits coherently via `C_B1` without reading seeds.
- **Code verification:**
  - Verified in [`src/trace_code.zig:166`](file:///home/bart/Projects/lune/src/trace_code.zig#L166): seed slots are allocated at frame offsets `>= anchor_num_registers`. For the anchor frame, `stack_top = base + anchor_num_registers`.
  - Verified in [`src/interp.zig:2187-2199`](file:///home/bart/Projects/lune/src/interp.zig#L2187-L2199): `bindAndPushClosure` places the callee base at `self.stack_top` and writes parameters / nils into `[cb, cb + nreg)`, directly overlapping the seed span, before `pushFrameTrusted` updates `self.stack_top = cb + nreg`.
  - If GC triggers while the nested frame is on the stack, slots below `stack_top` are walked/scrubbed for that active frame.
  - Because `host_epoch` increments, `guard_host_epoch` fails on resumption, taking the coherent exit `C_B1` (`coherent = true`, `slots_len = 0`) and never reading a seed slot again.

#### 3. F1 Test Dependency on Phase 2c (Antigravity Finding 2)
- **Design text:** §5.10.1 specifies that because `guard_native` is introduced in Phase 2c, the F1 test (verifying that collecting a replaced `Native` retires guarding traces) will land with Phase 2c or earlier using a hand-built trace pool holding a `Native`.
- **Code verification:**
  - Verified that [`heap_consts`](file:///home/bart/Projects/lune/src/trace_finalize.zig#L246-L257) already indexes all heap references (including `Native`), but trace recording of `guard_native` is scheduled for Phase 2c. Providing the option of a hand-built trace in Phase 2b or end-to-end testing in Phase 2c is accurate.

---

### Conclusion

The changes in `git diff docs/design/63-trace-host-calls.md` accurately address all findings from round 1 with full fidelity to the codebase. The design is **APPROVED** to proceed to implementation phases.
