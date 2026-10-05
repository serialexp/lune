# Doc 61 rev 2 — antigravity review (2026-10-05)

Verdict: **REVISE**. Folded into rev 3.

The core thesis is sound in principle: mask the `.gc` root walk using `Proto.reg_live`, and scrub dead window slots to nil. Rev 2, though, has two soundness or lifecycle bugs and one uninitialised-field hazard.

## Blockers

1. **Faulting frames during an `xpcall` handler are misclassified.**
   - The handler is pushed with `depth` still raised (errors.zig:83-88), so the faulting frames are active windows, not gaps.
   - If such a frame's `code[p-1]` happens to be a `call`, §3.3 misclassifies it and scrubs slots `>= a`.
   - If `p == 0`, evaluating `code[p-1]` underflows.
   - Suggested fix: all-live for faulting frames. → Rev 3 §4.4 masks them to ∅ instead, because all-live breaks determinism (codex blocker 5); §4.3 now guards `p >= 1`.
2. **Premature clearing of `in_flight` exposes Zig locals in natives.**
   - Natives keep relying on operands after and between `callValue` calls: `require` (package.zig:300-363) and `table.sort` (table.zig:264).
   - The frame is in flight for the whole native call (`opCall`, interp.zig:6473-6523).
   - Fix: save and restore the flag around each set, never clear it unconditionally. → Rev 3 §4.2.
3. **`dyn_hi` is uninitialised on frame reuse** in the `.S` (hostcall_x64.S:248-257) and the native inline push (nativegen_emit.zig:998-1020). → `dyn_hi` is withdrawn in rev 3 (P2); `in_flight` initialisation is stated for all three pushes.

## Should-fixes

- **Q1:** choose (b), folding only permanently pinned values, over (a); (a) adds substantial GC complexity. → Rev 3 §7 keeps both options and leaves the choice to Bart.
- **Readers (§4.3).** Scrubbing is safe and beneficial for snapshots. `matchesFingerprint` probes only live slots, and `bridgeMatchesExitSnapshot` gates on `liveIn`. Accept nil for the visualiser (Q2).
- **Tests.** Add:
  - an xpcall handler collecting with the fault at `pc == 0` and at `pc > 0` where `code[pc-1]` is a call;
  - a collection between two `callValue` calls in one native activation;
  - `mh_collect` from a host callback via `callHostNative` (interp.zig:2208).

  Mutations to add: omit `dyn_hi = 0` initialisation; prematurely reset `in_flight`. → Rev 3 §8.
