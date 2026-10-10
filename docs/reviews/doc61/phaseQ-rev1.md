# Doc 61 §7.1 Phase Q design, rev 1: reviews (2026-10-10)

Codex thread 01a123db-e74d-7de0-94c4-454814be90a7; antigravity one-shot.
Both reviews were read-only.

## Codex: REVISE

F1–F4 hold for production paths. F2 is too broad as literally worded,
because entry seeding reads activation state. F3 should name host-issued
`mh_collect`.

### Blockers

1. `const_swept` must cancel unconditionally. `RecordingSession.abort()`
   (`trace_recorder.zig:990`) can rewind a link peel into a `.link` close
   that keeps the pool. Use `realAbort` semantics.
2. `PendingLinkClose.contract` borrows a cached inner trace's
   `entry_guards` (`trace_recorder.zig:307`, read at `:3644`). Retiring that
   trace dangles the borrow even when `rec.consts` has nothing dead.
3. Exec logs keep raw string `Value`s (`execlog.zig:160`), which are
   serialized later (`execlogser.zig:68`, `wasm_entry.zig:662`). They are
   keyed by cache index (`trace.zig:2529`), and `swapRemove` reshuffles
   those indices.
4. The batch is still Θ(N²): cache searches, `countTracesAt`, and the
   provenance/link/promotion scans all run per trace. Specify bulk
   filtering.
5. Replay across a keyframe cut taken before the sweep loses an intern hit
   for an unreachable but unswept string. This predates Q; the design must
   state how it is handled.

### Should-fixes

- Use the predicate `white && !pinned`.
- Build `heap_consts` from the full pool. The "live `konst` users only" idea
  is unsafe.
- `reset` protects the recorder maps after a real abort. Add an
  address-reuse test.
- One final rebuild is sound only under conditions: teardown first, no
  execution during the batch, fail-closed.

Wider tests and benchmarks: N sweep, survivors, links/promotions, an
`mh_collect` harness (`collectgarbage` is not implemented), and structural
counts instead of timing in tests.

### Nits

- The scan is O(traces + heap constants), not O(heap constants).
- `heap_consts` must not be `u16` (`maxrecord` is a `u32`).
- The slots to inspect are on the surviving parents.

### Arbitrary-safepoint retirement

Pending arms resolve safely (`trace.zig:1917`,
`trace_regionops.zig:824`). Side recordings survive parent retirement
(`trace.zig:3881`). Entry patches clear `live` before they are destroyed
(`trace_entry_registry.zig:180`). No host-callback path runs beneath an
unfinished trace-selection frame.

## Antigravity: REVISE

F1–F4 verified. Retirement at an arbitrary safepoint was checked against
pending arms, side recordings, entry patches and dispatcher locals, and is
safe.

### Blocker

1. Pinned constants: white is not the same as freed (`gc.zig:757`). Use
   `white && !pinned`, or every trace over a loaded chunk retires on every
   cycle.

### Should-fixes

- Read the anchor before `retire` destroys the trace.
- Return early on an empty set.
- `drainEntryPatchWork()` at the end of the batch.
- Tests for pinned survival and for a parent retiring mid-recording.

### Nits

- The slots to check are on the surviving traces.
- Poison `EntryPatch.trace` on retire.
- Free `heap_consts` in `TraceCode.deinit`.

## Disposition (rev 2)

Every item is folded into §7.1 rev 2:
- items 2–7 cover the predicate, cancel, owned contract, id-keyed maps,
  bulk `removeTraces`, the no-alloc scratch and the exec-log policy;
- item 8 narrows the claim to tier identity, and the replay gap goes to
  TODO.md as pre-existing;
- the tests and benchmarks were widened as asked.

## Rev 2

**Antigravity: APPROVE.** Every rev 1 item was verified against the code.

**Codex: REVISE.**
1. The rebuild R(T) is itself superlinear:
   - `topologyView`/`hasInnerRootAt` cache scans;
   - `buildEdges`' pairwise exit match;
   - region construction's rescans;
   - the drain's `unpatchSlot` scans;
   - `prepareSlotMutation`'s proof rescans.
2. `konstKey` is shared with tropt, so equal-id distinct headers must stay
   distinct there.
3. The exec-log artifact policy is incomplete: no wire `id`, and retired
   traces' logs end up orphaned.

Should-fixes: `PendingStore.tab_obj`; wants are not resolved through
`traceById`; contract ownership on every path; reserve all scratch.

Rev 3 handles these as follows:
- The budget is O(T + L + P + E + D) plus one R(T) per non-empty
  collection. Every commit already pays R. R's own complexity goes to
  TODO.md.
- The drain is bulk, and slot teardown uses a bulk variant.
- The recorder gets its own id keys.
- Logs own their bytes, carry a wire `id`, and are dropped on retirement.
- Wants are cleared in the bulk pass.
- `clearPendingLinkClose` is the single ownership funnel.

## Rev 3

**Codex: APPROVE.** The topology rewrite is no longer a Phase Q
prerequisite. Usable performance must still be shown by measurement before
landing.

Should-fixes, all folded:
- compare rebuilds on equivalent graphs, and report total latency and
  sparse churn;
- the drain's semantics (unpatches before installs, id order, several
  traces per anchor, both suppression kinds);
- cache `resolvePatchPc` on the patch, and count patch records and log
  bytes in the budget;
- check surviving proofs before R, since R drops parked proofs;
- log ownership transfer on append, and both failure paths.

Wording nit, applied: Phase Q "reuses the existing rebuild algorithm once
per non-empty batch".

