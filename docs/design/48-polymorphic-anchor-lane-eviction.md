# Polymorphic-anchor lane eviction (identity-pinned widen-eviction) — Design

Status: complete — landed (codex round-3: approved after two mechanical
fixes, both applied; final full gate green on the landing tree). Only the
--jit-stats coverage-divergence Defer bullet remains open (its own arc).
Owner: fable (campaign arc, task #31 / doc 47 Increment C)
Last updated: 2026-09-16

## Implementation status

Tracking the gap between this design and what's on the main branch.

### Done

- [x] **Guard-dedup peel-rewind staleness fix.** `guarded_refs` now maps
  ref → guard-instruction index, and `rewindPeelAndCloseLink` purges entries
  whose *guard* was truncated (previously it purged on the guarded ref's own
  index, which is always lower — a ref below the rewind point whose guard sat
  above it stayed marked "guarded" with the guard gone, so the re-emitted
  `.link` close silently skipped `guard_int` on the inner-loop limit and the
  committed cont carried an unguarded `slot_load`; `proveKinds` then rejected
  the whole trace → tier-1a-only cont forever). Also removed the purge's
  fixed 64-slot scratch (nothing stale can survive now). Side effect on
  spectral: both loop-done conts (`Av:22`/`Atv:22`) compile natively, and the
  dead-append-cont convergence doc 47 Increment C worried about **already
  works** — the append-shaped cont's `guard_append` fails in steady state,
  the hot-guard path records an in-bounds `astore` sibling, and Atv's
  loop-done cycle fuses (4000 bursts → ~200 receipts).
- [x] **Diagnostics.** `proveKinds` failure index probe
  (`nativegen_prove.dbg_last_idx`, `-Djit-debug` only, threadlocal per codex)
  + trace_link `proveKinds fail-at` line; `guard_lane` prints its lane in IR
  dumps; commit/retire probes print proto + lane pins; receipts print the
  trace id. All probes log deterministic ids, never addresses (codex).
- [x] **P1 — record-time table pin.** Recorder captures, per
  `container_lane` `guard_lane` on a slot_load-covered table
  (`emitLaneGuardPinned`, all four emission sites), the record-time table's
  **deterministic `GcHeader.id`** — not the un-rooted `*GcHeader` originally
  proposed; codex round-1 made the id form a blocker, and it also answers the
  first open question below. Committed into `TraceCode.lane_pins`
  (`{guard_ref, table_id}`); peel rewind truncates pins with
  `guard_ref >= ir_rewind_len`; finalize remaps `guard_ref` through tropt's
  `old_to_new` compaction map (dropped guard ⇒ dropped pin) — a codex
  round-1 blocker: preheader insertion/compaction shifts committed indices,
  so an emission-space pin would point at the wrong instruction. Pin capture
  is best-effort (`catch {}`): a missing pin only suppresses eviction.
- [x] **P2 — identity-pinned `laneWidenedPast`.** Walks `lane_pins`; evicts
  only when the LIVE table's `header.id` equals the pin's id AND the array is
  frozen AND its lane widened past the guarded lane. A different table at the
  register is no evidence → no evict. No pins → never evicts (fail-safe).
  Explicitly a **heuristic, not a proof of permanent death** (codex): the
  trace is lane- not identity-specialized, so a same-lane sibling could still
  have used an evicted trace; accepted cost is one re-record, and the
  A-widens/B-remains test pins that behavior.
- [x] **P3 — tests** (`trace_evict_test.zig`). (a) polymorphic anchor: a
  different table at the guarded register is no evidence, the sibling
  survives (+ control: same state on the pinned table evicts); (b) the
  original monotonic cases (unfrozen-never-evicts, `canWidenTo`
  reachability, i64-past-i16 evicts) rewritten against pins; (c) no-pins
  fail-safe; (d) A-widens/B-remains adversarial (codex-required); (e)
  optimized-root pin remap: guard index shifts BOTH ways (fill trace down
  via compaction drop, read trace up past an inserted preheader) and pins
  track it — verified non-vacuous by asserting the shift against the
  unoptimized run (codex-required; a peel-only test would miss it); (f)
  `guarded_refs` peel-rewind staleness regression (spectral cont shape,
  asserts the cont compiles native; verified to FAIL under the simulated
  old keying); (g) tier-0 equivalence for both reproducers under the full
  native pipeline.
- [x] **Codex round-2 changes (all landed).** (1) Blocker: fail-soft pin
  finalization leaked the temporary list when `toOwnedSlice` itself failed
  (verified against the pinned stdlib: a failed `toOwnedSlice` leaves
  ownership with the list) — now a `defer pins.deinit` around the whole
  block, and the failing-allocator finalizer test carries a lane pin so the
  path is swept. (2) `id == 0` is a valid identity (globals table; heap ids
  start at 0) — no zero-rejection added, test comments corrected, review
  ledger entry. (3) Doc body rewritten from the pointer design to the id
  design with a follow-up note (this section). (4) Dispatch-level policy
  tests added: polymorphic siblings coexist at the anchor + the widened-past
  zombie is retired (fails under BOTH a neutered predicate and the simulated
  pre-doc-48 live-table predicate), and monotonic same-table widening still
  retires the stale narrow trace at the shared `fill` anchor (fails under
  the neutered predicate; phase-1 anchors never re-entered legitimately
  survive — eviction is entry-driven). (5) The remap test now asserts the
  shift in BOTH directions (down via compaction, up past a preheader) and
  matches guards by pc+lane+table_id, not pc alone. (6) `trace-retire` probe
  prints the same lane summary as the commit probe. (7) Pin capture is now
  conditional on a slot_load root (capture-then-ignore eliminated).
- [x] **P4 — full gate + board.** `just test` green (1379 tests). Full
  28-bench board vs the 20260915-200333 baseline
  (TSV 20260916-091642-6a2b334): spectral −41.8%, everything else within
  noise — the board's +4-6% flags (sparse/repack/sor/grid_f64) were re-run
  best-of-7 and came back at baseline (152.8/23.3/83.6/26.4 vs
  150.2/24.1/83.1/25.5); ambient noise this session was wide (LuaJIT's own
  wall moved ±5-15% between runs, tier-0 +2-6% on the flagged rows).
  nsieve/array3d (original monotonic-eviction users) flat.
- [x] **Codex round-3 (approved w/ two mechanical fixes, applied).** (1)
  The polymorphic dispatch test now matches siblings by anchor proto AND
  pc (pcs are proto-local) and requires a DISTINCT trace, so one trace
  guarding several lanes cannot masquerade as two coexisting siblings.
  (2) "i64 zombie" wording corrected to "narrow-int zombie" everywhere
  (small int literals commit to `.u8`, ordinal 7 — the earlier .i64 lane
  census was vacuous, which is what surfaced the terminology bug). Final
  full `just test` re-run green on the exact landing tree.
- [x] **P4 — spectral measurement.** `just bench --filter spectral`
  (TSV 20260916-085252-6a2b334): **30.175 → 17.4 ms, 13.3× → 9.4× LuaJIT**,
  cross ok, luajit ok — better than the neuter experiment's 25.9 ms because
  the narrow-int zombie now dies precisely (first mismatched u-entry) instead of
  surviving to eat 20k-refusal walks. Receipt sums: 772k/800k Av iterations
  native. NB the board's `res%` for spectral (61.9) is UNDER-REPORTED — see
  the Defer bullet; wall/cross columns are unaffected.

### Outstanding
- [ ] **Defer — `--jit-stats` coverage-path divergence.** A coverage run
  forces the ordinary discovery epilogue (interp.zig ~5203) and disables the
  post-walk fast path (~2912) on the assumption the slow path selects
  identically. On this polymorphic anchor it does not: the coverage run
  leaves ~46% of `Av:9` iterations interp while the uninstrumented run
  enters them natively — so the board's `res%` column under-reports
  whenever selection differs between the paths. Wall columns are
  unaffected (measured without stats). Needs its own diagnosis; out of
  scope here.

## Why this exists

spectral-norm sits at 13.3× LuaJIT (board 20260915, jit 30.2 ms vs 2.27 ms)
with `Av:9` — one of its two identical hot inner loops — running 54% of its
800k iterations on tier-0 *despite committed traces*. The diagnosis
(jit-debug receipts, N=200):

- `Av(x,y,N)` is called alternately with `x = u` and `x = v`.
  `u` is built by `u[i] = 1` (i64 lane) and later overwritten with floats,
  which widens it **to `.value`** (Lua-shaped int/float distinction makes
  f64 unsound for mixed history); `v` is float-born → f64 lane. So one
  anchor legitimately sees two array lanes forever — a *polymorphic anchor*
  (exactly doc 33's case).
- The value-lane sibling (t=7) commits and serves u-bursts natively.
  Every f64 sibling (t=9…t=16 — eight of them) commits during a v-burst and
  is **retired by widen-eviction on the next u-burst**: `laneWidenedPast`
  sees live lane `.value` vs guarded lane `.f64`, `canWidenTo` false →
  "guard can never pass again" → evict. But the premise is per-TABLE
  monotonicity; the guard is on *whatever table occupies the register at
  entry*, and `v` still passes. The v-bursts then run interp (364k
  iterations), re-attempting the value sibling's prologue every ~4
  iterations (91k zero-progress receipts), and each interp iteration pays a
  ~245-cycle un-inlined `A` head-trace call (366k entries, ~9% of run).
- With eviction neutered (1-line experiment): all three siblings coexist
  (narrow-int zombie, f64, value), both burst flavors run native (receipt-sum
  772k/800k iterations), bench wall 30.2 → 25.9 ms, cross/luajit ok.

The general gap (Z-6): **any** loop whose table argument alternates between
lanes — polymorphic containers are ordinary Lua (caches, mixed-history
arrays, the doc 33 shape) — loses its native coverage to eviction churn.
LuaJIT has no analogue of this eviction: a side-exit on a shape guard just
selects/records another trace; traces die by flush pressure, not by a
mismatched entry.

## The defect, precisely

`laneWidenedPast` (trace.zig, from commit e53fbe8) implements *"this
trace's array lane guard can never pass again"* as:

```
live table at guard's register: lane L_live (frozen)
guarded lane: L_t
evict if L_live != L_t and !canWidenTo(L_live, L_t)
```

Lane monotonicity (frozen arrays only widen) is a **per-table** invariant.
The implementation quantifies over the wrong thing: it treats one entry's
live table as *the* table. At a monomorphic anchor those coincide and the
original fix (dense fill i8→i16→i32 leaving dead narrow traces that clog
the anchor and block the wider steady state) is sound. At a polymorphic
anchor it evicts a live sibling every time the other table shows up.

## Fix: pin the record-time table identity

`guard_lane` semantically means "the table now in register R has lane L".
The monotonicity argument applies to the table the *recorder observed*. So
(as landed — this section originally proposed pinning the raw `*GcHeader`;
codex round-1 replaced that with the deterministic id, see the follow-up
note below):

- **P1**: the recorder captures the observed table's **deterministic
  `GcHeader.id`** at every `container_lane` `guard_lane` emission whose
  operand is a slot_load-rooted table (`emitLaneGuardPinned`; non-slot_load
  roots — doc 43 P3 hloaded tables — are not captured, since the predicate
  could never resolve them). Commit moves the list into
  `TraceCode.lane_pins: []LanePin = {guard_ref: u32, table_id: u32}`. Two
  index-lifetime transitions apply (same staleness class as `guarded_refs`;
  both are now tests): peel rewind truncates entries with
  `guard_ref >= ir_rewind_len`, and finalize remaps `guard_ref` through
  tropt's `old_to_new` compaction map (a dropped guard drops its pin;
  preheader insertion and compaction shift committed indices both ways).
  Capture and finalization are fail-soft: a missing pin only suppresses
  eviction. NB `id == 0` is a valid identity (the globals table).
- **P2**: `laneWidenedPast` walks `lane_pins` instead of scanning IR:
  resolve the live value at the pinned guard's register (existing
  `guard_lane.a → slot_load.aux` logic); evict only if
  `live_header.id == pin.table_id` **and** the live array is frozen **and**
  `live_lane != L_t and !canWidenTo(live_lane, L_t)`. A trace with no pins
  is never evicted by this path (fail-safe). This is a **heuristic, not a
  proof of permanent death**: the trace is lane- not identity-specialized,
  so a same-lane sibling table could still have used an evicted trace; the
  accepted cost of that miss is a single re-record (adversarial
  A-widens/B-remains test pins the behavior).

**Follow-up (codex round-1): pointer pin → id pin.** The original proposal
above pinned the un-rooted `*GcHeader` and argued dangling/reuse was benign
because the pointer was compared, never dereferenced. Codex rejected it:
address reuse makes the comparison replay-hostile in principle and the
"never dereferenced" argument fragile under maintenance, while
`GcHeader.id` (object.zig) already exists precisely as the deterministic,
replay-stable identity that rendering and keyframes use. The id form also
needs no GC awareness at all — a collected table's id is simply never seen
live again.

Behavior on the motivating cases:

- Monotonic fill (same table widens): identity matches, eviction fires
  exactly as today. nsieve/array3d unchanged.
- spectral / alternating lanes: the f64 sibling's pin is `v`; a u-burst
  presents `u` → identity mismatch → no evict. The narrow-int zombie's pin is `u`;
  once `u` widens past its int lane, any u-burst entry evicts it — the zombie dies
  *sooner and more precisely* than today (today it survives because... it
  is entered first in the walk and evicted only via the same live-lane
  check that also kills the f64 sibling — with churn noise; with the pin
  it dies on first mismatched u-entry and never returns).

### Soundness / determinism / GC notes

- The pin is **eviction metadata only** — never an entry condition, never
  code. Wrong/stale pins can only cause a missed or spurious eviction
  (perf, not correctness).
- The pin is an id, not a pointer (see the follow-up note above), so there
  is nothing to root and nothing to dangle. The lane/frozen fields
  consulted after an identity MATCH are read from the LIVE table value in
  the register, which is alive by construction. Ids are monotonic and
  never reused within a session, so a collected table's pin simply never
  matches again.
- Determinism: `GcHeader.id` is assigned in deterministic allocation order
  and is replay-stable by design (it exists so observable rendering avoids
  `@intFromPtr`). No address, ordering, or hash feeds any decision; probes
  log ids only.

## Alternatives considered

- **Remove eviction, add cap-pressure replacement** (LuaJIT-flush-like:
  evict the stalest sibling only when the per-anchor budget blocks a new
  commit). More general — also handles freed-table zombies — but a bigger
  policy surface (staleness bookkeeping, deterministic tie-breaks), and the
  hot-counter-reset-on-last-trace behavior of today's eviction would need a
  new home. The identity pin is strictly smaller and keeps the existing,
  tested shape. Can be layered later if zombie accumulation ever shows up.
- **Consecutive-refusal eviction** (evict after K refusals with no pass):
  rejected — the "failed last N" phase-dependence codex banned for arm
  churn applies verbatim (a long u-phase would evict the f64 sibling and
  re-churn at every phase boundary).

## Review ledger (resolved questions)

- ~~Is the un-rooted `*GcHeader` pin acceptable, or should the pin be an
  allocation-order serial (deterministic table id)?~~ **Resolved (codex
  round-1): the id.** `GcHeader.id` exists exactly for this; see the
  follow-up note in the Fix section.
- ~~`lane_pins` on guard_lane over non-slot_load roots (doc 43 P3
  per-iteration `.heap` roots)?~~ **Resolved (codex round-2): not
  captured.** `emitLaneGuardPinned` appends a pin only for slot_load
  roots — the predicate could never resolve any other root, so capturing
  them would be dead weight.
- ~~Should `laneWidenedPast` reject `pin.table_id == 0`?~~ **Resolved
  (codex round-2): no.** Id 0 is a valid identity — the heap assigns ids
  from 0 and the globals table holds it. Zero cannot distinguish linked
  from unlinked and must not be used as that check.

## References

- e53fbe8 (widen-eviction introduction), 0fb8eb2 (frozen gate)
- docs/design/33-entry-refusal-is-not-thrash.md (polymorphic anchors are
  legitimate; per-candidate, not per-anchor, penalties)
- docs/design/47-f64-array-append.md Increment C (the spectral thrash this
  arc closes)
