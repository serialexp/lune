# Doc 61 Phase Q — implementation review dispositions (2026-10-10)

Reviewers: codex (thread `01a124f3-15b9-7e53-9154-758a8bd976b2`) and
antigravity, over the uncommitted Phase Q tree (doc 61 §7.1 rev 3). This
file records what each finding became. The reviews themselves were
conversational, and only their findings are kept here.

## Blockers — fixed

1. **Widen-eviction retired its dead list twice.** Batch retirement now
   destroys records, so a second `removeTraces` over the same list read
   freed memory. Fixed with `Vm.WalkDead`, whose `retire` empties the list
   before submitting it. `removeTraces` now asserts that every member is
   live and published. Test: "the trial walk's dead list retires once — a
   second retire is a no-op" (mutation-checked).
2. **`recForPrepLink` swallowed OOM on the contract/saved-regs dupes**
   (`catch return`, which left a half-built link close). Both dupes now
   `try` (with errdefers), so OOM aborts the recording through
   `abort(.alloc)`.
3. **`McodeArena.free` scanned `live_pages` linearly and could allocate on
   the collection path.** `live_pages` is now a generation-keyed hash map,
   and `alloc` reserves the free-list room. `free` is O(1) and never
   allocates. Test: "McodeArena: freeing every live page never allocates;
   stale and repeated frees are ignored".
4. **Entry-patch owner unbinding after retirement.** `unpublishDoomed`
   poisons `EntryPatch.trace` and sets `owner_retired`, and the drain skips
   unbinding a retired owner.

## Should-fix — dispositions

5. **Step 8 says drain entry patches at collection.** Kept at the next safe
   point, and doc 61 step 8 now says why. An install moves `image_gen` under
   frames that hold a cached image pointer they cannot re-resolve inside a
   collection. A non-live patch dispatched before the drain takes the §R6-1
   recovery arm, which unpatches synchronously and runs the original
   instruction.
6. **The bench should separate R(survivors) from teardown.** Done.
   `bench-retire` reports `R(surv)` and `teardown = collect - gc base -
   R(surv)`. Still open (CURRENT_TASK): it has no compiled pages, links or
   entry patches.
7. **R(T) is superlinear** (topology view scans, linear `traceById`,
   per-component rescans, sibling closure). Fixed in the same change.
   `TraceRegistry.by_anchor` indexes anchors, `View.init` indexes the view,
   and `build` is per-component with an O(1) enclosing test, a dominance
   envelope and a BFS closure. R(T) at N=4000 went from 92 ms to 3.0 ms.

## Missing tests — open (tracked in CURRENT_TASK.md)

The following are not yet written:
- parked proofs intact before R, dropped after R;
- promoted sets demoted;
- drain order (restore before install, id order, several traces per
  anchor, both wake kinds);
- region index OOM;
- real finalize/commit of a side recording after its parent retires;
- identity maps (`PendingStore.tab_obj`, `callee_global_dedup`,
  `upvalue_cell_classes`, `snapshot_read_cells`) under address reuse;
- a mid-peel inner-root retirement, and peel-setup OOM;
- each `clearPendingLinkClose` path, leak-checked;
- a `callee_global` non-konst dependency dooming its trace;
- `mh_collect` from a host callback's nested Lua run;
- exec logs after retire + re-record;
- a lazy compile after a sweep;
- per-step counters.

## Nits

- `srcDoomed` keeps wants whose source is already missing: left as is,
  because a missing source cannot start a recording.
- `cancelRecording`'s gate-map `getOrPut` can allocate on the collection
  path. Its failure is caught and the gate is skipped, which is a missed
  optimisation, never unsound.
