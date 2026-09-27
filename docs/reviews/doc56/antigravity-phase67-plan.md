# Doc 56 combined Phase 6–7 plan review — Antigravity (2026-09-27)

Scope: doc 56 §4.8.3 (R1–R4: routing and G1–G4), checked against source
with tool access. Read-only.

**Verdict: CHANGES REQUESTED.** Six findings, each checked in source and
folded into §4.8.3.

Confirmed without change:

- R1: `slots[ei] != shared_exit` is exactly "a live ordinary arm" for every
  attachable exit. `slots[ei]` starts at `shared_exit` and only
  `commitSlotMutation` changes it (arm → child entry, disarm/retire →
  `shared_exit`). rcx is outside `ALLOC_ORDER` (`nativegen_alloc.zig` ~193)
  and the bridge stub below already uses it as scratch.
- R2: a prologue refusal leaves the slab untouched (native and tier-1a) and
  charges `.entry_refusal` (no strike). A continuation's carried homes keep
  their entry values up to its last body guard (`nativegen_alloc.zig`
  ~1141-1180), so a pre-effect deopt restores the state at `P`. Scratch is
  per candidate (`valuesMark`); `visited[8]` bounds the walk; continuations
  are never precise and their loop-done guards take the coarse mode 0.
- R2: `linked = true` is set in two places, and `sct` is the linked trace in
  both (the seed-ledger head and `runLinkedBurst`, fused or not).
  `armExitSide` → `armNativeLink(.exit_side)` keeps every gate.
- R2 item: `armLoopDoneLink` picks through `resolveLoopDoneCont` too; one
  slot per loop-done exit, one static type per exit. Not flagged as a bug.
- R4: the legacy thrash counter is the only strike a deopting unclassified
  exit earns; clearing the DONE latch on give-up cannot loop (`.gave_up`
  never re-enters `.wanted`; legacy routes are bounded by
  `max_traces_per_anchor` and `max_penalty`).
- Determinism: all decisions are pure functions of counters, cache scans and
  IR ordinals.

Findings:

1. **BLOCKER — R3: a wanted exit CAN end a dispatcher-origin ledger in a
   terminal `.deopt`** (an adapter build refused in `nativeFor`,
   `trace_link.zig` ~2662; `silent_active` before Phase 6; a `driveChain`
   multi-row ledger drained by `driveDispatcherLedger` with
   `exit_side_ok = 0`, `trace_chain.zig` ~467). Reported `.native_direct`,
   `routeExitSide` counts it as a materialized firing and it gives up after
   `tryside` without ever recording. Fix: pass `.native_direct` only while
   the exit's state is `.none`. **Accepted.**
2. **MAJOR — `exitIsPreEffect` omits `.ustore` and `.sgm_setpos`**
   (`trace.zig` ~1816), which `trace_code.zig` ~723 lists as effects. A
   next-candidate retry (and, today, a sibling handoff) after one of them
   would re-run a mutation. Fix: one shared effect-op list. **Accepted**; it
   is also a pre-existing gap in sibling-handoff eligibility.
3. **MAJOR — R4: an unconditional `.none` exemption is unbounded.** An
   attachable exit that can never go wanted (`maxside` reached, or R1's live
   ordinary arm) stays `.none` for good. Fix: exempt `.none` only while its
   counter is below `hotexit`. **Accepted.**
4. **MINOR — `driveDispatcherLedger` is also called from `driveChain`**
   (~467) for a candidate's multi-row ledger, whose run had
   `exit_side_ok = 0`. The plan's "dispatcher only" claim is wrong; with
   finding 1's fix only a `.none → .wanted` step can happen there, which is
   the direct route's own contract. **Accepted** (text corrected).
5. **MINOR — `nextTraceExcluding` breaks hit-count ties by cache order**
   (`trace.zig` ~2568), unlike `resolveLoopDoneCont` (~2504, then lowest id).
   R2's candidate order should be the same pick. Fix: tie-break by id.
   **Accepted.**
6. **NIT — stub emission order.** Test the ordinary cell first (rax, rcx),
   then load the exit-side cell into rax and `jmp [rax]`, so rax needs no
   reload. **Accepted.**
