# Design Review: doc 56 (Revision 3) — Exit-started side traces

Reviewer: independent Claude sub-agent (technical-architect), 2026-09-24.
Round 3, requested by Bart instead of waiting for Codex. Receipt copied
from the review response. Dispositions are in doc 56 §13.

## Verdict: CHANGES REQUESTED

Revision 3 fixed everything the two Antigravity rounds flagged, but a fresh, source-level check of the specific reuse claims in §4.3/§4.6 (not just their existence, but their actual behavior) turns up a new BLOCKER that neither prior round caught: the two functions doc 56 names by name for materializing an attachable exit's sunk stores are built for a topologically different case, and — concretely — the doc's own flagship worked example (bit-reverse's ei 12/60/65/70) fails their literal eligibility gate. Two further MAJORs (an unverified ±2GB addressing assumption for the exit-cell region, and a ledger-grammar reuse claim that glosses over real structural specificity in `replayLedgerFrom`) round out the required fixes. None of these invalidate the architecture — materialize-first, boundary ordinals, and lazy adapters are all sound — but the mid-body materializer path needs a real (not borrowed) implementation before Phase 3/4 can be built on it.

---

### 1. [BLOCKER] `loopDoneSnapshotSupported`/`emitLinkedLoopDoneSnapshot` are unsound for mid-body attachable exits — the doc's own worked example fails their literal gate

- **Evidence:** doc 56:340-342, doc 56:458-459; `src/trace_code.zig:495-503` (`loopDoneSnapshotSupported`); `src/nativegen_emit.zig:2451-2490` (`emitLinkedLoopDoneSnapshot`); `src/trace_finalize.zig:44-52`; doc 56 §5 worked example table.
- **Analysis:** `trace_finalize.zig:45-52` shows every deferred store (across the whole recorded iteration) is appended as one contiguous block immediately before the phi rows and the terminal — before `tropt.optimize`, so the block stays a single contiguous run at the tail. `loopDoneSnapshotSupported(exit_instr)` and `emitLinkedLoopDoneSnapshot(..., exit_instr)` both scan forward from `exit_instr + 1`, requiring every instruction until `.phi`/`.loop`/`.link` to be a store — correct only because a loop-done guard sits immediately before that trailing block by construction. §4.3 explicitly excludes loop-done exits from attachability, so this is being invoked on exactly the class of guard it was never designed for.
  - **ei 12** (`i<j` false) sits near the start of the trace; `exit_instr+1` is the swap's RHS `aload`s — `loopDoneSnapshotSupported(12)` hits `else => return false` immediately.
  - **ei 60/65/70** (post-`while`) sit before the `j=j+k` add, a normal instruction physically preceding the store block. Same failure.

  Reusing the helpers verbatim would silently make mid-body exits non-attachable; loosening the gate to keep scanning past non-store ops would flush stores from bytecodes after `B`, violating §4.1.
- **Suggested fix:** Use §4.2's per-store boundary ordinal: locate the trailing store block once and at an attachable exit with guard ordinal `G`, flush `{ s in store_block | s.ordinal < G }` in block order. Reuse the leaf emitters (`emitAStore`, `emitHStore`/`emitGStore`), not the driver. Update §4.3's gate to "every store with `ordinal < G` is a kind {astore,hstore,gstore,ustore}".

---

### 2. [MAJOR] §4.6/Q7's RW exit-cell region assumes ±2 GiB proximity to the mcode arena that `McodeArena` neither provides nor guarantees

- **Evidence:** doc 56:441-451; `src/nativegen_mcode.zig:124-131` ("the ±2 GiB reachability check is deliberately deferred"); `src/nativegen_mcode.zig:268-282` (`mapRegion` calls `std.posix.mmap(null, len, ...)` with no hint or reservation, once per region).
- **Analysis:** Multiple regions are separate unhinted `mmap(null, …)` calls; nothing reserves or verifies their relative distance. Doc 56 additionally assumes a separate RW data region lands within ±2 GiB of that arena. Unhinted anonymous maps are usually nearby on Linux but that is not a guarantee, and it can drift over a long-running process (Rule #20).
- **Suggested fix:** Either (a) reserve one address range up front and assert co-location on every grow, or (b) use an absolute 64-bit load (`movabs rax, cell_addr; cmp qword [rax], 0; jne .to_adapter`) — the pattern already used by `emitPreciseSnapshotFlush` (`src/nativegen.zig:664-667`). Option (b) costs a few bytes per stub and removes the dependency.

---

### 3. [MAJOR] §4.8's "same rule continuation traces follow" elides that `LedgerKind.link_terminal`'s replay grammar is structurally specific to the Continuation→Inner-loop-root topology

- **Evidence:** doc 56:520-524; `src/trace_chain.zig:1819-1886` (`.link_terminal` arm of `replayLedgerFrom`).
- **Analysis:** The `.link_terminal` arm validates `isInnerLoopRoot(succ, proto, owner_inner_pc)` and drives `cursor`/`link_pc` state that later arms depend on. Doc 56 proposes a new `LedgerKind.exit_side` row for the entry transition but never says what validates the child's own `.link` row back to the parent — whether it hits the existing arm (and whether its checks and cursor state fit) or a new one.
- **Suggested fix:** Spell out the closing transition as its own explicit case in §4.8, including what `replayLedgerFrom` checks and what cursor state it leaves.

---

### 4. [MINOR] `ArmKind.exit_side` validation doesn't re-prove `exitAttachable`'s soundness conditions at the arm funnel, unlike the `sibling_handoff` precedent

- **Evidence:** doc 56:469-476; `src/trace_link.zig:1721-1724` (sibling_handoff: "Re-proved at arm time, not merely trusted from the watch").
- **Analysis:** If `exitAttachable` is a pure function of the immutable committed `TraceCode`, trusting it is fine, but the doc should say so explicitly.
- **Suggested fix:** State that the conditions are properties of the immutable parent and safe to trust, explaining the departure from `sibling_handoff` (or re-prove at arm time).

---

### 5. [NIT] "Snapshot ids are not ordered" is contradicted by `trace_snapshot.zig`

- **Evidence:** doc 56:293-294; `src/trace_snapshot.zig` `Builder.add()` (records appended unconditionally, one-based monotonically increasing id; only the slot vector is interned); `remapRefs()` never reorders records.
- **Suggested fix:** Justify the ordinal by the real reason: sunk store instructions have no snapshot record to anchor an id to.

---

### 6. Phase-plan gap

Phase 4 assumes the RW cell region + addressing mechanism already exists. Add an explicit phase item to design, implement and test whichever fix finding 2 chooses.

### Unverified (flagged, not asserted)

- **Cross-tier determinism.** §4.10's "charged exactly once per receipt" is plausible provided `exit_counts`/want bits/DONE latches are single shared per-exit state; not confirmed this round — worth a Phase 3 test.
- **`pending_stores` ordering under forwarding** — verified, not a concern: `forwardPendingArrayLoad`/`forwardPendingHashLoad` (`src/trace_recorder.zig:1942-2008`) only read `pending_stores`; the list is append-only, so ordinal order and list order coincide.
