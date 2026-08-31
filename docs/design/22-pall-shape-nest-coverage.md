# Pall-shape nest coverage — heap φ writeback, seeded-trace seams, inner-root owners

Status: partial — Phases A + B landed; Phase C through C.5c4 plus the C.5c5 ownership extraction and default-disabled graduation mechanism is correctness-green but remains UNCOMMITTABLE. The focused post-B gate still fails (lu +16.8%, spectral +13.5%, grid twins +3.7–4.6%). Enabled-vs-disabled G=8 measurement is neutral, while an exploratory G=1 threshold regresses sharply, so chronic-success graduation is not enabled by default and requires profiling before Phase D/final landing.
Owner: Claude (campaign arc 2; Bart 2026-08-20 mandate: every benchmark ≤1.2× LuaJIT)
Last updated: 2026-08-22

## Implementation status

Tracking the gap between this design and what's on the main branch.
Tick items as they land; move whole sections to "done" once everything
inside them is checked.

### Done

- [x] **Phase A — heap φ writeback.** Admit a carried slot whose load kind is
  `.ptr` and whose φ-update kind is `.heap` (or `.ptr`) through BOTH
  `proveKinds` and `analyze` as a *carried-heap* slot class (raw `*GcHeader`
  in a GP home, `TAG_HEAP` on every flush, entry check = tag only, NO hoisted
  table checks — all structural guards stay in-body), **including the
  carried-slot-aware lowering rewrite (§A.1b): in-body `guard_table`,
  seed-ignoring per-iteration `href` resolution, in-body `guard_hash`** for
  every access rooted at a carried-heap slot, and the `opMayExitInBody`
  home-coalescing safety predicate. Includes the
  helper-capability table (§A.2) pinning the "no GC-capable callout" rule.
  Landed 2026-08-20 with the §A.3 test matrix in
  `src/nativegen_carriedheap_test.zig` (carried-heap read loop expectMatch +
  frameless, dual-universe hstore-through-carried-root, the Rule-0.5
  coalescing pin, and the fail-closed array-op bail — the two pins
  mutation-verified: each fails when its guard code is reverted). NOTE: the
  §D "advance:132 compiles AND runs native" criterion is NOT yet checkable
  e2e — in a live nbody run the bridge is never recorded/entered because the
  seams aren't seeded (link arms = 0); that observation moves with Phase B.
- [x] **Phase B-i — inert seed substrate.** `NativeSeedCtx` (§B.1) in stable
  heap storage (recorded deviation: heap-allocated by `Vm.initBare`, not
  owned inline by `TraceState`; `proto` is `?*const anyopaque = null` until
  driveChain needs it), per-episode refresh (`prepareNativeEpisode`),
  `SeedPlan` derivation at compile time, `compileSeeded`/`compileInto` ctx
  plumbing, and the two new exit reasons + ledger kinds
  (`seed_hash_decline`, `seed_capacity_decline`) — all inert: no prologue
  emitted, no gate flipped. Landed 2026-08-20 (f037529) with plan-derivation
  pins in `nativegen_carriedheap_test.zig`.
- [x] **Phase B-ii — prologue seeding + the DIRECT-entry decline flip.**
  §B.2 for direct entries: the compiled page's entry prologue calls the
  baked `seed_fn` (recorded deviation: the plan crosses the ABI as
  `plan_bits: u64` BY VALUE, not `*const SeedPlan` — `CompiledTrace` is
  returned by value so `&ct.seed_plan` cannot be baked as an imm64;
  `t`/`ctx` are stable and bake fine) with fail-closed tri-state dispatch:
  SEED_OK falls through to the body, hash-decline exits with a terminal
  `seed_hash_decline` row (completed = rbx = 0, regs untouched) and the
  dispatcher reruns the entry on tier-1a through the unchanged ordinary
  grammar, capacity-decline steps to the next candidate with no strike; any
  out-of-grammar seed_fn return routes to the capacity exit. Fused declines
  are statically impossible until B-iv (every arm site still requires
  `inputs.len == 0`) and `replayLedger` panics loudly on one. Both new
  ledger kinds are inert for region accounting (0 work) and exit patching
  (null). `compileImpl` fails closed when the plan is non-empty and ctx is
  null. Landed 2026-08-20 with §B.6-shape pins (SEED_OK oracle bit-match,
  both declines terminal + regs byte-untouched, fail-closed routing) in
  `nativegen_carriedheap_test.zig`; six-hash gate + 3 repros + 28/28 bench
  cross=ok on the flip.
- [x] **Phase B-iii — tier-1a chain seeding (§B.3).** driveChain's three
  tier-1a chain seams (side-walk, driveBurstCore link-follow, burst
  re-entry) seed a seeded successor via the episode ctx before EVERY
  `irinterp.execute` (per-entry re-resolution, burst hops included), through
  a dedicated non-C-ABI twin (`NativeSeedCtx.seed_tier1a_fn` →
  interp.zig `nativeSeedTier1aFn`, delegating to `seedTraceInputs` for
  byte-identical resolution — the C-ABI plan twin can't serve here: tier-1a
  needs the FULL input set, plans only carry the ACTIVE bitmap). Disposition
  per §B.3: SEED_OK **and** SEED_HASH_DECLINE run tier-1a (`href` re-derives
  cells and side-exits at the same guard — the dispatcher's old
  `native_eligible=false` downgrade); SEED_CAPACITY_DECLINE declines the
  candidate; missing ctx/twin fails closed to the pre-B-iii skip. The NATIVE
  walk still requires input-free candidates until B-iv. Landed 2026-08-20
  with the §B.6 chained hash-drift pin (twin-stub driveChain test: hash
  decline chains with the seeded value observable in the result; capacity
  decline and missing ctx skip) in `trace_chain_test.zig`.
- [x] **Phase B-iv — `stubEnterable` + the ~15-site gate audit (§B.5).**
  Landed 2026-08-20 in three steps: **B-iv.1** (34ebb88) the inert
  substrate — `seed_prologue` recorded on `CompiledTrace` plus the shared
  `stubEnterable(t, entry_kind, proto)` predicate (compiled page, requested
  entry stub present, `seed_plan.nonEmpty() == seed_prologue` invariant
  panic, unseeded → always enterable, seeded → fail-closed episode
  freshness: live `native_seed_ctx`, ctx.proto match, anchor.proto match,
  `region_context.call_seq == ctx.call_seq`; hash/capacity are NOT
  enterability — a decline leaves the stub enterable). **B-iv.2** (62312df)
  the decline directives — interp ledger gates + the §B.2 fused-decline
  replay arms (drain the silent prefix, resume at the decliner's coherent
  anchor, no receipt/strike/side-exit/chain-source; codex-approved deviation
  in thread 01a01ae1: fused declines do NOT rerun the decliner tier-1a
  in-drain). **B-iv.3** (0adc9ef) THE flip — every `inputs.len != 0`
  hard-decline at the chain/link/arm/replay seams (findLinkTrace,
  findLoopTrace, isInnerLoopRoot, resolveLoopDoneCont,
  computeNativeLoopDoneLink, promotedEdgeFromLink, armLinkTerminal,
  armLoopDoneLinkTo, armNativeLink `.sibling_handoff`,
  validateRegionBridge, the driveChain walk seams) replaced with
  `stubEnterable`. Two recorded deviations, both widening-preserving:
  (1) the replayLedger fused-successor asserts are **conditional on
  `succ.inputs.len != 0`** — an unconditional `stubEnterable` would have
  NARROWED the pre-B-iv zero-input shape-only contract (and broken the
  deliberately-uncompilable synthetic fixtures); the seed-freshness proof
  only exists for seeded rows (kind-carrying ledgers are native-only, so
  a seeded fused row implies a same-frame self-seed under the live
  episode ctx). (2) `validateRegionBridge` declines a non-enterable
  seeded child **transiently** (null, no `invalidateRegion` tombstone) —
  ctx staleness is per-episode, not structural. Regression pins: seeded
  selection + `.sibling_handoff` no-ctx/stale/fresh ladder
  (`trace_chain_test.zig`), both widened asserts' positive seeded paths
  byte-identical to their zero-input twins (`trace_replay_test.zig`),
  transient-decline + positive seeded-enterable region legs
  (`trace_region_test.zig`).

- [x] **Phase B-v — §B.6 tests + Phase-B measurement.** Landed 2026-08-20
  (d2a51c6). All eight §B.6 rows covered: structural upvalue-seeded chain +
  ten-leg-nest-with-upvalue-builtin + hash-drift-decline e2e tests
  (`interp_native_test.zig`, with `assertSeededChainExercised` /
  `assertHashDriftDeclined` inspect witnesses — the §B.4 seeds_at_entry
  invariant `seed_plan.nonEmpty() == seed_prologue` is asserted per compiled
  trace); redundant-seed deactivation as a *run* test (stale hash seed
  excluded by the plan never blocks entry, its slab slot stays bit-for-bit
  unwritten; `nativegen_carriedheap_test.zig`) plus a `compileImpl`
  release-assert that no emitted body instruction reads a plan-inactive
  seed's slot; and the fused terminal-decline *placement pin*
  (`trace_replay_test.zig`): a 3-row `[loop_done_linked, link_terminal,
  seed_hash_decline]` ledger returns completed == 1 — the predecessor's
  per-row grant (`.loop_done_linked` grants `linked_completed += 1`, one
  committed outer iteration; the ledger `cum` feeds only region accounting)
  is preserved past the decline, resume at the decliner's own anchor.
  Diagnostic `seed_hash_declines`/`seed_capacity_declines` counters wired at
  all five decline drain seams (interp direct capacity+hash handlers,
  replayLedger silent M1 + dispatcher-grammar terminal arms, driveChain
  hop-0); no tiering path reads them. **Measurement (A/B vs `just shadow`
  baseline at a468fa2, nm/strings-verified):** nbody advance:132 records,
  all 3 traces compile native, and it runs fused via loopdone links (79,975
  fused follows; link arms native=1 loopdone=1) — **nbody 180.5 → 99.4 ms
  (40.4× → 21.9× LuaJIT, −45%)**; pi_leibniz 12.9 → 11.2 ms (−13%),
  scimark-sor 80.0 → 75.4 ms (−6%); the rest of the 28-program board within
  noise, cross=ok throughout, no regressions. Gate battery green (962 tests,
  jit-debug build, six-hash gate both modes, repros 109/109/18135).

- [ ] **Phase C — canonical owner election + gate reopening. ATTEMPTED OVER
  NINE ROUNDS, NEVER NET-POSITIVE, REVERTED 2026-08-25.** The design and every
  measurement are kept below (§C.1–§C.5c5) because the negative result is the
  most useful thing in this file. Summary:

  C.1 recast region ownership as *canonical accounting identity*, which made
  nest regions armable that were owner-ambiguous before. That is what it was
  for — but armable ⇒ `openRegion` per activation ⇒ a per-activation
  open→account→close lifecycle whose fixed costs the post-B tree structurally
  never paid. The landing board against post-B:

  | benchmark | post-B jit ms | post-C jit ms | delta |
  |---|---:|---:|---:|
  | nbody | 99.4 | 182.5 | **+84%** |
  | scimark-fft | 292.4 | 597.8 | **+104%** |
  | spectral-norm | 57.6 | 106.7 | **+85%** |
  | scimark-lu | 166.6 | 193.7 | +16% |
  | scimark-sor | 75.4 | 84.3 | +12% |
  | grid_matmul | 38.0 | 40.3 | +6% |

  `--jit-stats` on nbody: post-B ran **84.7%** of cycles as native trace code;
  post-C ran **0.1%** — 199,844 of 199,921 loop entries were "tier-0,
  has-trace", the dispatcher refusing entry.

  Nine mechanisms were then built to claw that back — C.4 (dual-unit
  profitability), C.5 (lifecycle amortization), C.5a (observer span cache),
  C.5b (syscall-free patching), C.5c1 (mechanical costs), C.5c2 (dormancy),
  C.5c3 (receipt memo), C.5c4 (per-event hooks), C.5c5 (extraction +
  graduation). Final state, with graduation already default-disabled: lu
  +16.8%, spectral +13.5%, grid +4.6%, nbody ~+3%. **lu began the cascade at
  +16.6% and ended at +16.8%.**

  Why it was reverted rather than tuned further: the graduation/lease machinery
  is not a LuaJIT mechanism. What we took from Pall is trace trees, side traces,
  hot-exit counters, loop recording, snapshots and direct compiled-trace
  linking. Persistent `RegionDef` objects, source/destination classification on
  every receipt, `RegionAccum` profitability windows, dormancy/observer/memo
  accounting, graduation and leases are all Mahina-specific. LuaJIT does not run
  classify→choose→lookup→classify→update per successful receipt; it patches the
  exit and stops thinking. We copied the trace *shape* and not the steady-state
  *cost model*, then spent nine rounds building a cache hierarchy over the cost
  model we should not have had. Rule Z-7 names this exactly: repeated failure of
  local fixes is evidence to move up a level, not an invitation to invent one
  more local fix.

  What survived the revert: the region **data model** extraction into
  `src/trace_region.zig` + `src/trace_types.zig` (a pure move, behaviour-free,
  measured neutral), and three general provenance wins that were never region
  policy (see the C.5c1/C.5c4 notes). C.5b (dual-mapped mcode arena) was also
  dropped — re-measured on the post-B tree it relieves **6 mprotect calls across
  the entire 28-program suite**, not the 8,006 recorded below; that figure was
  an artifact of Phase C's own arm/disarm churn. Worth revisiting only if
  exit-branch patching makes patch frequency real.

  The likely correct direction, if this is picked up again: a directly attached,
  epoch-validated route (patch the exit, validate by epoch, re-patch on
  invalidation) rather than a per-receipt accounting layer with a cache
  hierarchy on top.

### Outstanding

- [ ] **Phase D — measurement.** Per-phase A/B vs `just shadow` baseline;
  Phase A success = advance:132-shaped trace compiles AND runs native
  (direct entry, every snapshot form, the `.ptr`-entry→`.heap`-update
  transition); A+B adds seeded-direct-entry A/B + board-wide non-regression;
  A+B+C = nbody coverage collapse + full board. Gate battery throughout.
- [ ] **Defer — rooting heap φs across allocating callouts.** Today no body
  callout can allocate (§A.2), so the fail-closed rule costs nothing. If a
  future helper allocates, either decline heap-φ traces containing it or
  add spill-before-call rooting. Revisit when such a helper exists.
- [ ] **Defer — low-trip-count inner-loop unrolling (`innerloopleft`).**
  LuaJIT's escape hatch: a root reaching an inner loop that repeatedly
  failed gets unrolled into the root (bounded by `loopunroll`). Defer until
  the side-trace tree economics above are exhausted.
- [ ] **Defer — self-contained traces (seeds as trace IR).** The
  LuaJIT-faithful endgame: resolve upvalue/global/hash-cell addresses as
  trace prologue IR (his HREFK + LICM hoisting) instead of dispatcher-side
  `InputSeed` machinery. Phase B's seam seeding is the incremental step.

## Why this exists

nbody sits at **38.5× LuaJIT** (182 ms vs 4.7 ms) with the JIT *on*. Arc-1's
hash-cell alias classification removed the recording blocker, and the recorder
now produces exactly the trace structure Mike Pall's own machinery would want
(`lj_record.c` 605–700: `rec_loop_interp` aborts LINNER at an interpreted inner
loop from a root; coverage comes from side traces off the *inner* root that
record the outer body and `lj_record_stop(J, LJ_TRLINK_ROOT, lnk)` back to it):

- `advance:34` — the inner j-loop root, `.loop` terminal, **compiles native**
  (17 KB x86-64).
- `advance:132` — the outer-body bridge: writes bi's six accumulated fields,
  advances the outer `for_loop`, loads the next `bi = bodies[i]`, preloads its
  seven fields, sets up the next inner range, `.link -> 34`. Exactly Pall's
  side trace.
- The region discovery even mints the cycle:
  `region: mint id=0 kind=cross_trace_cycle members=2` (pc 34 ⇄ pc 132).

And yet nbody runs ~0.6% traced, 50.1% tier-0-with-trace-fallback: the cycle
never arms, every anchor ends up strike-gated
(`legacy-strike: anchor pc=34 completed=0` → `gate: … window=8192`). Three
independent, *general* blockers — each one a mechanism gap, not an nbody
special case (Rule Z-6):

1. **`advance:132` doesn't compile.** The visible decline is `proveKinds`
   (nativegen.zig:2009): a slot-bound φ whose update value has kind `.heap`
   (`%122 phi update=%72 -> r7`, %72 = the per-iteration `bodies[i]` table
   from a `.value`-lane aload) bails the whole trace. Behind it sits a second
   gate: `analyze`'s carried-slot classification (nativegen.zig:2336) admits
   only `{int, float}` carried loads and requires load-kind == store-kind, so
   the `.ptr` anchor load / `.heap` update pair bails there too. *Any* loop
   or continuation that carries a table/element local across an iteration
   boundary — the array-of-objects pattern — hits this.
2. **One `InputSeed` disqualifies a trace from every seam but the
   dispatcher's.** `advance:34` carries exactly one seed — the file-local
   `sqrt` upvalue (`%033 slot_load r31`, `%046 guard_pure [sqrt]`) — and
   `advance:132` carries `hash_cell` seeds for the slot-rooted `bi` cells.
   ~15 sites hard-decline `inputs.len != 0` (audit in §B.5): `isInnerLoopRoot`,
   `findLinkTrace`, driveChain's link-follow and side-walk, `armNativeLink`
   callers, stub-enterability, loop-done continuation arming, the region owner
   scan, provenance drain, `replayLedger` validation. The stated reason is
   uniform: "`ordinary_entry` cannot seed synthetic inputs (that is
   dispatcher-side)" — and it is *true* today, because native bodies receive
   only `(rdi=tags, rsi=payloads, rdx=*NativeResult, rcx=body_entry)`
   (nativegen.zig:247) and have no VM, closure, base, or capacity to seed
   with. Any hot code that touches a global/upvalue builtin or a slot-rooted
   table field — i.e. most Lua — is locked out of nest fusion.
3. **A closed cycle entered at an inner root elects no owner, and its
   anchors strike out while it waits.** The A-vii-d.1 owner predicate wants
   a unique member that is (external-entry ∨ enclosing) ∧ inner-root-shaped.
   nbody's steady-state cycle {34, 132} covers the *entire* outer loop body,
   so there is no enclosing member (the outer loop at pc 4 correctly never
   traces — that's the LINNER abort, Pall-faithful), no external structural
   edge, and today not even inner-root shape (blocker 2's `inputs.len == 0`
   clause). `owner_unique=false` → `armable=false` → no freeze, no B-3 exit
   patching. Meanwhile the legacy strike machinery, seeing zero-work entries,
   gates the anchors with doubling windows and — at `max_strikes` —
   **permanently** (`isGated`, trace.zig:10708 gates trace entry too), which
   starves the region of the very receipts that would qualify it. And doc
   16's corrected verdict applies with full force: tier-1a/driveChain
   transitions (~600 ns re-entry) are *neutral* on 1–4-iteration inner-loop
   clusters, which is precisely nbody's n=5 shape. Only the frozen
   native↔native patched cycle pays.

The three fixes compose into one statement: **when the recorder has already
built Pall's trace tree, the backend must be able to run it.** LuaJIT never
had these gaps by construction — TValue stores box anything, his traces are
self-contained (HREFK/upvalue loads are trace IR, hoisted by LICM into the
per-entry preamble), and his tree has no owner bookkeeping to satisfy.

### What this does NOT change

- The root-at-inner-loop LINNER abort (`recForPrepLink` `.root → nyi`) stays.
  It matches `rec_loop_interp`/`rec_loop_jit`; the coverage comes from the side
  trace, not from unrolling the root through the inner loop.
- Recording, IR shape, determinism model, replay schema: untouched. Every
  mechanism here is backend/selection-side; guest-visible behaviour is
  byte-identical by the usual ten-leg `expectProgram` gate.

## Phase A — heap φ writeback (carried-heap slot class)

### A.1 The change — BOTH gates, one new slot class

Two gates must open together; opening only `proveKinds` (the original draft)
achieves nothing because `analyze` bails first on the same shape:

1. **`proveKinds` Pass-C** (nativegen.zig:2005–2010): φ writeback kinds
   currently `{int, bool, float, ptr}` — add `.heap`.
2. **`analyze` carried-slot classification** (nativegen.zig:2324–2342): a
   slot that is both loaded and φ-stored currently requires
   `lk ∈ {int, float} ∧ sk == lk`. Add the **carried-heap** case:
   `lk == .ptr ∧ sk ∈ {.ptr, .heap}` (the anchor `slot_load` of a
   guard_table-covered table, updated each iteration by an `aload` `.value`
   result or another table ref). Unified representation: the raw `*GcHeader`
   payload in a GP home — identical machine representation for `.ptr` and
   `.heap`, so no transition cost.

The RV-4 comment at nativegen.zig:2332 warns why `.ptr` carried was banned:
a carried `.ptr` load must NOT inherit the *invariant*-slot treatment, where
the prologue hoists the table-type/metatable/lane checks once — the φ swaps
in a different table every iteration, so hoisted per-table facts would be
stale. The carried-heap class therefore gets:

- **Prologue**: tag check only (`TAG_HEAP`), like the existing `.ptr` entry
  tag check (nativegen.zig:4254). No hoisted guard_table facts, no lane pin,
  no array-base hoist keyed on this slot.
- **Flush**: `flushSlot` (nativegen.zig:3410) maps `.heap → TAG_HEAP`, same
  arm as `.ptr`. All five writeback paths funnel through `flushSlot`
  (link 4112, loop-done 4129, composite 5055, deopt 5209, silent deopt
  5284 — verified), so the sweep is that one switch plus the entry check.
- **Register class**: GP, same as `.ptr`; coalescing/home rules identical.

Grep-audit remains: every `switch` over `Kind` in nativegen.zig gets an
explicit decision for `.heap` reaching it via a carried slot (Zig's
exhaustive switches surface the gaps at compile time).

### A.1b Carried-slot-aware lowering (the round-2 blocker)

"All structural guards stay in-body" is NOT free — today's lowering makes
them free-riders on entry facts, which is unsound once the slot's value
changes per iteration:

- The recorder seeds any `slot_load`-rooted table operand
  (`seedHashCell`, trace.zig:12288–12313), so a carried-heap slot's `href`
  gets `aux >= 0` and native lowering loads the **entry-seeded cell
  pointer** each iteration (nativegen.zig:4546) — after the φ swaps tables,
  that cell still belongs to the *previous* table.
- `guard_table` on a `.ptr`-classified operand lowers to a no-op
  (nativegen.zig:4417), and `guard_hash` likewise trusts the seeded cell
  (nativegen.zig:4433) — so the "in-body guards" the design relies on
  currently compile to nothing.

The rewrite is keyed on ONE carried-aware predicate used at **every** stage
of native compilation, not just final lowering [round-3 blocker — the
callout path is prepared by earlier allocator stages that all key on
`kinds[ins.a] == .heap` today: operand liveness extension
(nativegen.zig:2470), callout save-area reservation (nativegen.zig:2931),
then lowering's choice (nativegen.zig:4551); flipping only the last one
emits a callout with missing operand liveness and `callout_save_count == 0`
— a release-build wild write past the reserved frame]:

```zig
/// Does this href need per-iteration dynamic cell resolution?
/// true when the table operand's kind is .heap OR its root slot is
/// classified carried-heap.
fn hrefNeedsCallout(...) bool
```

required at: operand/liveness analysis, callout save-area reservation,
helper-capability admission (§A.2), `guard_hash` lowering, and final `href`
lowering. Plus a structural assertion: any dynamically-resolved href in the
emitted trace implies a nonzero, correctly-sized callout save area.

**Home-coalescing safety** [round-4 blocker]: coalescing lets a carried
scalar's update overwrite its slot home only when no *later side exit*
exists (nativegen.zig:2698), and its side-exit inventory (nativegen.zig:2717)
does not know the three newly-dynamic operations. A coalesced scalar update
preceding a dynamic `guard_table`/`href`-miss/`guard_hash` failure would let
the common deopt flush (nativegen.zig:5200) commit part of an aborted
iteration. The carried-aware mechanism therefore also provides an
**`opMayExitInBody`** predicate — the existing exit set ∪ {dynamic
`guard_table`, `hrefNeedsCallout` hrefs, dynamic `guard_hash`} — and
coalescing analysis uses it. Pinned by an e2e test (§A.3): a coalescible
scalar φ update ordered before a carried-table hash/type failure → the OLD
scalar value survives the deopt, byte-identical to tier-0.

With that predicate in place:

- `guard_table` on a carried-heap-rooted ref **executes in-body** (real
  type-tag + metatable check against the current register value).
- `href` rooted at a carried-heap slot resolves via `resolveHashCell` per
  iteration — the already-existing fused producer-exit callout path.
- `guard_hash` on such an href checks the **current** table's population
  in-body (the callout path already carries this; verify).
- **Seeds made redundant by this rewrite** [round-3]: a committed `Trace`
  is immutable (trace.zig:1506), so `t.inputs` cannot be edited at analysis
  time, and processing the stale seed normally is *wrong* — its entry-table
  validation could hash-decline the whole entry even though the emitted
  body deliberately re-resolves the current table per iteration.
  Compilation therefore produces a page-owned **seed plan** (an
  active-input bitmap on `NativeCode`), baked/passed to the seeding helper,
  which resolves only active seeds; inactive slab slots stay unwritten and
  are release-asserted unread by the page. `seeds_at_entry` (§B.4) is
  defined against the active plan, not raw `inputs.len`.
- **A→B phase boundary** [round-4]: plan *filtering* and the
  unwritten-slot guarantee begin in **Phase B** (the seeding helper is a
  Phase-B deliverable). In Phase A alone the dispatcher's existing
  `seedTraceInputs` path (interp.zig:2098/2152) still resolves and
  validates ALL raw inputs, including plan-inactive ones — harmless
  writes the body never reads, plus a *conservative* entry validation: a
  redundant seed that fails hash validation downgrades to
  `native_eligible=false` (tier-1a), never a wrong execution. That is
  acceptable for A because at direct entry the carried slot holds the
  current, valid table, so its hash cells validate — the staleness the
  rewrite defends against only arises mid-body after the φ swaps; the
  A-alone success criterion (Phasing) is worded accordingly, and the
  unwritten/unread release-assertion plus the §B.6 redundant-seed test
  land with B.
- `analyze` still bails (fail closed) if any aref/lane/array-base hoist
  keys on a carried-heap slot.

Note advance:132 (`.link`) would not expose the stale-cell bug — the φ
update flushes at the terminal and the body reads only the entry value.
A **`.loop`** trace with the same shape would. The test matrix (§A.3) pins
the `.loop` case explicitly.

### A.2 GC safety — helper-capability table, not an opcode scan

Corrected inventory (round-1 review): **no body callout can allocate or
trigger GC today.**

- `astore_append` does NOT grow on-trace: `guard_append`
  (nativegen.zig:4800) side-exits when `idx0 != asize`, `idx0 >=u cap`, or
  the hash is non-empty, so the realloc/migrate only ever runs at tier-0
  after the exit; the native op is in-place stores + `inc asize`
  (nativegen.zig:4834–4870, "the on-trace append never allocates").
- The only body helper is `resolveHashCell` → `Table.fieldPtr` →
  `HashMap.getPtr` — a lookup, no allocation (table.zig:214).
- GC runs at dispatcher safepoints, never inside a native body.

So a φ-carried heap value in a GP register is always rooted for the body's
duration by whichever container it was loaded from (the traced stores in the
same body cannot free it — nothing collects mid-body), and it is re-boxed to
a register-file slot (`TAG_HEAP`) at every flush, where the normal root walk
sees it.

To keep this a *checked* invariant rather than a comment: add a
`HelperCaps` table in nativegen.zig — one row per C-ABI helper a body can
call, with a `can_gc: bool` — and have the heap-φ admission in
`analyze`/`proveKinds` require `can_gc == false` for every callout in the
trace. All current rows are `false`, so nothing regresses; a future
allocating helper must either flip its row (declining heap-φ traces that
contain it, fail closed) or bring the spill-before-call rooting protocol
(deferred, see checklist).

### A.3 Tests

- runForTrace structural: a `bodies[i]`-shaped continuation (table loaded
  from a slot, updated by aload, φ'd back) classifies carried-heap,
  `native == .compiled`, and the writeback stores `TAG_HEAP`.
- runForTrace structural negative: same shape where an array-base hoist
  would key on the carried slot → bail (the fail-closed rule in A.1).
- expectProgram e2e (ten-leg byte-identity): nbody-shaped two-body advance
  where the carried `bi` table's fields are read in the *next* outer
  iteration — exercises direct native entry with a `.ptr`-tagged slot,
  `.heap` update, flush through every snapshot form (loop-done, guard exit,
  link handoff).
- e2e with a mid-loop side exit (type drift in a field) → deopt snapshot
  writes `TAG_HEAP`, tier-0 resumes byte-identically.
- **`.loop` stale-cell pin (round-2 blocker test)**: a `.loop` trace whose
  carried-heap slot alternates between two *distinct* tables with identical
  field names/types (e.g. `t = pair[t.next_idx]` shape) — field reads must
  track the current table every iteration; byte-identity across all legs.
  This is the test the `.link`-only nbody shape cannot catch.
- Structural: an href rooted at a carried-heap slot lowers to the
  per-iteration callout (seed ignored/dropped), and its guard_table is
  in-body (assert via the emitted-guard accounting, not disassembly).
- **Coalescing-safety pin (round-4 blocker test)**: e2e where a
  coalescible carried-scalar φ update is ordered before a carried-table
  hash/type failure mid-body → the deopt restores the OLD scalar value
  (the dynamic exit was in `opMayExitInBody`, so coalescing was refused);
  byte-identical to tier-0 across all legs.
- Success criterion (Phase D): NOT "proveKinds accepts" — the trace must
  compile, enter native directly, and pass all snapshot-form tests.

## Phase B — seeded-trace seams

### B.1 The seed context (the missing ABI)

`seedTraceInputs` (interp.zig:930) needs the current **closure** (upvalue
seeds), **globals/constants** via vm+proto (global seeds), **base** and
**register capacity** (slab writes), and the **table registers'** live values
(hash-cell seeds). None of that reaches native code today (ABI:
nativegen.zig:247), and `driveChain` (trace.zig) has proto+RegWindow but no
vm/closure either. So Phase B's first deliverable is a context boundary:

```zig
// *heap-allocated* by TraceState.init (gpa), freed in deinit — the Vm (and
// the TraceState inside it) is a BY-VALUE type (Vm.init returns the struct,
// interp.zig:773/826) and may move; only separately-allocated storage gives
// the stable address native pages bake as imm64. [round-2 fix]
pub const NativeSeedCtx = struct {
    vm: *anyopaque,          // opaque: trace.zig/nativegen.zig must not import interp
    closure: *anyopaque,     // current activation's closure
    base: usize,             // frame base into the register file
    reg_capacity: usize,     // slab bound (seedTraceInputs' capacity check)
    // Episode identity stamp [round-4]: written by Vm.prepareNativeEpisode
    // alongside the frame fields; this is what stubEnterable's dynamic
    // freshness check (§B.5) reads — a persistent Trace carries no
    // call_seq, so freshness lives here, not on the trace.
    proto: *const anyopaque, // anchor proto of the episode's frame
    call_seq: u64,           // activation token of that frame
    seed_fn: *const fn (ctx: *const NativeSeedCtx, t: *const Trace, plan: *const SeedPlan) callconv(.c) u64,
};
// TraceState.native_seed_ctx: *NativeSeedCtx  (pointer, not embedded value)
```

- `seed_fn` is the only thing installed at init (a static function — safe to
  install early); it wraps `seedTraceInputs`'s body — an opaque callback so
  no `interp ↔ nativegen` import cycle. It takes the page's **seed plan**
  (§A.1b) and resolves only plan-active seeds. Returns a tri-state (§B.2):
  `1` = seeded+validated, `2` = hash-cell validation failure, `3` =
  capacity short.
- **Context refresh is a new VM-side seam, not the existing sweep**
  [round-3]: `prepareNativeEntry()` is a `TraceState` method
  (trace.zig:3734) also called at internal native re-entry sites that have
  no vm/closure/base (trace.zig:5121, 6994, 7207) — it cannot fill the ctx.
  Add `Vm.prepareNativeEpisode()` (fills `{vm, closure, base,
  reg_capacity}` from the live frame), called at the dispatcher's direct
  native entry (next to interp.zig:2166) and at `enterSelectedTrace`'s
  patched-entry path — i.e. exactly the seams where a fresh episode begins.
  `TraceState.prepareNativeEntry()` stays what it is (the promotion sweep).
- The fill is **episode-invariant**: all native hops are
  same-proto/same-frame today (successor discovery pins `t.anchor.proto`,
  trace.zig:8075–8082; cross-proto resumes are deferred; no native hop
  pushes/pops a frame; patched entries re-enter via `enterSelectedTrace`
  with the live closure/base, establishing a fresh fill). One fill covers
  every hop of the episode.
- **Release-enforced, not assumed** [round-2/3/4]: the enforcement is
  **context freshness**, not a per-trace token (a persistent `Trace` has no
  `call_seq` to compare). `Vm.prepareNativeEpisode` stamps
  `{proto, call_seq}` into the ctx; `stubEnterable`'s dynamic clause (§B.5)
  checks that the ctx is fresh for the *current* `{proto, call_seq}` and
  that the candidate trace's `anchor.proto` equals `ctx.proto` — parent and
  child anchors share that proto (successor discovery pins it,
  trace.zig:8075–8082), so both are covered by the one stamp. When
  cross-proto successors eventually land they are *ineligible* for seeded
  entry until a context-switching stub exists.
- Tier-1a (§B.3) uses the same ctx + a non-C-ABI twin of `seed_fn`.
- `ctx` (the heap pointer) and `t` are bakeable imm64s at lower time (both
  stable for the page's lifetime; a freed trace unmaps its page first).

### B.2 The prologue seeding step in the entry stubs

When the page's seed plan is non-empty (`plan.nonEmpty()`, §A.1b/§B.4 —
NOT raw `t.inputs.len`, which over-counts carried-heap-deactivated seeds),
`lower` emits into the shared `body_entry` path of the entry stubs (nativegen.zig:5292 — both `linked_entry` and
`ordinary_entry` fall into it, and B-3 patched exit branches target these
stubs, so **every hop of a fused episode runs it**):

- **after** the `entry_rbx` stamp (nativegen.zig:4241) — a decline must
  carry *this* body's entry counter, or a chained failure would corrupt
  `local_completed` accounting with the previous body's rbx;
- **before** the hoisted entry guards — they may read seeded slots (the U1
  `.func` prologue check reads the sqrt slot);
- a callout (standard save/restore, precedent: the aux=-1 href callout)
  loading `&native_seed_ctx`, `t`, and the page's `&seed_plan` as imm64s
  and calling `ctx.seed_fn(ctx, t, plan)`; capacity is validated inside
  before any slab write (already first in `seedTraceInputs`). `seed_fn`
  gets its own `HelperCaps{ .can_gc = false }` row under §A.2's
  one-row-per-helper rule (approval note, round 5) — seeding resolves and
  validates, it never allocates.

On decline the stub jumps to a dedicated **seed-decline exit** modeled on
the existing `prologue_fail` path (nativegen.zig:5248–5272), because the
round-1 sketch's `completed = 0` was wrong for fused episodes:

- **Cumulative semantics** [round-2]: `completed` is cumulative rbx, and the
  wrapper release-asserts the terminal ledger row's cumulative value equals
  scalar `completed` (nativegen.zig:1000). The decline therefore writes
  `completed = rbx` (preserving committed predecessors) and appends a
  terminal ledger row with `cum = rbx` (`local_completed = rbx − entry_rbx
  = 0`).
- **Subtype transport** [round-3]: `ExitReason` is a payload-less scalar
  enum (irinterp.zig:75) and `LedgerEntry` carries only that enum
  (irinterp.zig:218), so "one reason carrying a tri-state" cannot survive
  the ledger copy. The subtype is encoded as **two distinct reasons**:
  `ExitReason.seed_hash_decline` and `ExitReason.seed_capacity_decline`
  (with matching `LedgerKind` rows) — replay then knows the route with no
  payload plumbing.
- No guest-state writeback beyond that — nothing of this body ran, and
  prior bodies flushed at their link terminals, so the register file is
  consistent at this trace's anchor.

**Dispatcher semantics** [rounds 1–3]:

- A plain zero-work exit would be charged as a strike and excluded from the
  candidate walk (interp.zig:2550–2611) — the decline must NOT take that
  route, and on a *patched* entry it must also not increment patch strikes
  (a bare `.next_candidate` does, interp.zig:2640). The result consumer
  dispatches on the exit reason instead.
- **Silent prefix first**: silent-promoted transitions own live metadata
  mailboxes and are drained as the first action after native return
  (trace.zig:5620–5626). A seed decline after silent hops is therefore a
  reporting *suffix*: the consumer drains/applies the committed silent
  prefix normally, THEN handles the decline. `replayLedger`'s grammar gains
  the two decline rows as terminals: valid only as the last row,
  `local_completed == 0`. Because `driveDispatcherSilentResult` returns
  only `?ChainResult` (trace.zig:7486) and the tier-1a rerun needs the VM
  (which owns `seedTraceInputs` and the full result grammar), ledger replay
  surfaces a **VM-facing terminal directive** `{kind, decliner_trace,
  anchor, committed}` rather than acting itself.
- **Then, by reason**:
  - `seed_hash_decline` → the VM returns to the `enterSelectedTrace` path
    for the *decliner*: seed a widened window via its own
    `seedTraceInputs` (whose hash failure downgrades, never aborts),
    execute **that exact trace** through tier-1a, and feed the result back
    through the complete ordinary result grammar. Not a bare
    `resume_tier0` (wouldn't guarantee reselecting the decliner). No
    strike, no patch-strike.
  - `seed_capacity_decline`, **direct entry** (no committed prefix) → a
    no-strike next-candidate at the same anchor — same selection behaviour
    as the dispatcher's own `null` return today (interp.zig:2098).
  - `seed_capacity_decline`, **fused** (committed prefix exists) → today's
    payload-free `.next_candidate` is relative to the *original* walk's
    anchor (interp.zig:2047) and could reselect at the wrong PC and
    re-execute committed work. The directive instead restarts selection at
    the **decliner's anchor** with the decliner excluded — or, simplest
    sound fallback, resumes tier-0 there. No strike, no patch-strike.
- Deterministic: seeding is a pure function of guest state, so every leg
  takes the same route at the same entry. Persistent decliners are priced
  by the existing receipt machinery on the *region* (fused receipts stop
  arriving → disarm/retire), and by tier-1a's ordinary economics for direct
  entries.

Dispatcher dedup: the dispatcher's direct-native path stops calling
`seedTraceInputs` (the prologue owns it — no double seeding); its tier-1a
path keeps it.

### B.3 Tier-1a chain seeding

driveChain's link-follow and side-walk run successors through
`irinterp.execute` dispatcher-side. Before executing a seeded successor they
call the ctx's non-C-ABI seeding twin (same resolution + validation).
Disposition matches today's dispatcher semantics [round-3 correction —
tier-1a's `href` re-derives cells and ignores the seeded pointer, so a hash
failure does NOT make tier-1a unrunnable]:

- `ok` AND `hash_decline` → execute the successor on tier-1a (hash failure
  merely means the seeded fast cell is unusable — exactly
  `native_eligible=false` at the dispatcher, interp.zig:930's downgrade).
- `capacity_decline` → decline that successor, as an unenterable child
  today.

Pinned by a chained hash-drift test (§B.6). The ctx is already filled for
the episode (§B.1), so driveChain needs no new parameters — only
`TraceState.native_seed_ctx` access, which it has.

### B.4 Seeded-page invariant

"Page exists ⇒ its entry seeds" holds because native state is runtime-only
(never serialized) and there is exactly one production compile path
(`compileImpl`), which after Phase B emits the prologue for every trace
whose **seed plan** (§A.1b) is non-empty. Encode it: `NativeCode` carries
the seed plan (active-input bitmap) set by the compiler, and the shared
enterability predicate (§B.5) release-asserts
`plan.nonEmpty() == prologue-present` — with the plan, not raw
`inputs.len`, as the source of truth (carried-heap rewrites deactivate
seeds without mutating the immutable `Trace`).

### B.5 The gate audit — one predicate, then the table

All operational sites move to one shared predicate:

```zig
/// May control flow enter this trace at `entry_kind` without the
/// dispatcher's seeding help, within the given episode?
fn stubEnterable(self: *const TraceState, t: *const Trace, entry_kind: EntryKind, episode: EpisodeId) bool
```

covering: compiled production page present ∧ correct secondary entry for
`entry_kind` ∧ (seed plan empty ∨ prologue present — release-asserted equal,
§B.4) ∧ page live ∧ **context freshness** — the `NativeSeedCtx` is stamped
for the current episode (`ctx.{proto, call_seq}` match the live frame) and
the candidate's `anchor.proto == ctx.proto` (§B.1 round-4; the trace itself
carries no activation token — freshness lives on the ctx).
Tier-1a seams (driveChain) don't use it — they seed via §B.3. The
release-panic validators (`armNativeLink`, `replayLedger`,
`promotedEdgeFromLink`, region validation, loop-done selection) all assert
through this same predicate — widened *with* the rule, never deleted.

| site (trace.zig) | today | after |
| --- | --- | --- |
| `isInnerLoopRoot` :3271 | requires 0 | drop the clause (shape = anchor + `.loop`) |
| `findLinkTrace` :3301 | skips seeded | accept |
| positional buffer :3332 | skips seeded | accept |
| region child validate :4039 | invalidates region | `stubEnterable` |
| provenance drain :4231 | declines child | accept |
| side-walk :5098 | skips seeded sct | seed via §B.3, accept |
| `armNativeLink` ordinary :5151/:5242 | requires 0 | `stubEnterable(.ordinary)` |
| replayLedger validation :6537 | panics unless 0 | assert `stubEnterable` |
| link-follow :6974 | breaks | seed via §B.3, follow |
| `armNativeLink` link_terminal :7175 | requires 0 | `stubEnterable(.linked)` |
| helper :7712 | skips | accept |
| stub target resolve :9184 | null | `stubEnterable` |
| stub-enterable :9794 | false | `stubEnterable` (becomes the impl) |
| loop-done cont arm :10018 | returns | `stubEnterable` |

Each row lands with the test that would catch its regression.

### B.6 Tests

- Structural: a `.loop` trace with an upvalue seed (the `local sqrt =
  math.sqrt` shape) + its `.link` continuation → chain arms,
  `armNativeLink` succeeds, frozen replay validates,
  `seeds_at_entry` asserted.
- e2e ten-leg: nest whose inner loop calls an upvalue builtin, verifying
  byte-identity across all legs with chaining live.
- Decline determinism: a hash-cell seed invalidated between entries (field
  type drift / population change) → `seed_decline(hash)` at the prologue,
  dispatcher drains any silent prefix then runs *the decliner* on tier-1a,
  output identical to tier-0; no strike charged; ledger for a fused episode
  ends with the `seed_decline` terminal row at the decliner's anchor with
  `cum == completed == rbx` (the round-2 cumulative pin).
- Capacity decline, direct: `seed_capacity_decline` → no-strike
  next-candidate, matching the dispatcher's own capacity-wall behaviour.
- Capacity decline, fused: committed prefix applied, selection restarts at
  the *decliner's* anchor (never the original walk's) — no committed work
  re-executed, byte-identical output.
- Chained hash-drift [round-3]: a driveChain successor whose hash seed
  fails validation still executes on tier-1a (only capacity declines the
  child); output identical across legs.
- Redundant-seed deactivation: a carried-heap trace whose stale hash seed
  would fail entry validation still enters natively (the seed plan excludes
  it); the inactive slab slot is release-asserted unread.
- Placement: a chained entry whose predecessor completed work, then the
  successor declines → `completed` preserves the predecessor's rbx and the
  decliner's `local_completed == 0` (the entry_rbx-ordering pin).

## Phase C — canonical owner election + gate reopening

> **REVERTED 2026-08-25 — recorded negative result, not current design.**
> Everything from here to the end of §C.5c5 describes a mechanism that was
> built, measured over nine rounds, and never beat the post-B baseline on any
> benchmark. It is retained deliberately: it is the evidence for why a runtime
> region-policy layer on the steady-state path is the wrong architecture. See
> the Phase C entry under "Implementation status" for the board and the
> reasoning. Do not treat any of the following as describing the tree.


### C.1 Owner = canonical accounting identity, NOT a proven entry point

Round-1 correction: a closed SCC with no incoming structural edge does *not*
mean the dispatcher can only enter at one member — advance:132 is itself
dispatcher-enterable (Phase A makes that the norm), and tier-0 can arrive at
any member's anchor independently. So the election is recast: the owner is
the **canonical accounting identity** the region's profitability, gating,
and freeze bookkeeping key on — nothing more.

Election rule (deterministic, pure function of the recorded trace set):
in a closed cycle with no `enclosing` member, if **exactly one member
trace** — by physical region membership (`member_trace_ids`), NOT the
cache-wide `hasInnerRootAt` anchor scan (trace.zig:8041), which a same-anchor
non-member `.loop` sibling could satisfy spuriously [round-2] — has
inner-root shape (post-Phase-B: `.loop` terminal, seeds allowed), it is the
canonical owner and its anchor the canonical anchor. Ambiguity (zero or 2+
such member traces) → `armable=false`, fail closed, exactly today.

What must then be *proven in implementation*, not assumed: **activation and
receipts are entry-agnostic.** An activation may open at any member's entry
(dispatcher chooses by its ordinary selection at whatever anchor tier-0
reaches first); receipts from every member count toward the region's
profitability window; promotion/freeze arms the whole edge set regardless of
which member's entry opened the activation. The A-ii.4/A-vii-d accounting is
audited for owner-anchor assumptions as part of this phase — any site that
implicitly equates "region entry" with "owner anchor" is a bug to fix here.

### C.2 The gate-reopening rule (was a Phase-D contingency; now in scope)

Live evidence: pc 34 legacy-strike-gates on zero-work entries, and
`isGated` (trace.zig:10706) blocks trace *entry* — at `max_strikes`
permanently. A formerly-unarmable region that becomes armable (Phase A gives
132 a page; Phase B gives 34 inner-root shape; C.1 elects the owner) could
sit forever behind gates minted under the old regime, starved of the
receipts that qualify it.

Deterministic transition rule: **when a region first transitions
unarmable→armable** (at mint or at the re-scan that first elects an owner),
clear the legacy penalty/gate state of every member anchor — exactly once
per region (a `gates_cleared` latch on the region def). From then on the
region's own profitability window governs; if it fails to qualify, the
normal legacy machinery re-gates the anchors on fresh evidence.
Deterministic: the transition is a pure function of the trace/region set (no
ticks compared across VMs — the *clear* is keyed to the armability edge, not
to time).

### C.3 Tests

- Region corpus (trace_region_test.zig, sibling of the A-ii.4 / A-vii-d.0
  suites): Pall-shape closed 2-cycle (inner root + link-back continuation) →
  owner == inner root, armable.
- Entry-agnostic: the same cycle entered (a) at the inner root, (b) at the
  continuation's anchor — both open activations, receipts from both members
  accumulate, promotion arms the same edge set.
- Ambiguity: a 3-member closed cycle with two inner-root-shaped members →
  `armable=false`.
- Non-member sibling [round-2]: a `.loop` trace cached at the same anchor as
  a member *continuation* but NOT itself a region member → election ignores
  it (physical membership, not anchor scan); the region stays correctly
  owned/unowned by its own members only.
- Gate reopening: pre-gate the owner anchor to `max_strikes` (permanent),
  then make the region armable → gates cleared once, receipts flow,
  qualification proceeds; a second unarmable→armable flap does NOT clear
  again (latch).
- [round-2] Same-anchor two-root ambiguity: TWO root-shaped member traces
  cached at one anchor → fail closed, in BOTH the primary path (the anchor
  is ext/enclosing: `ambiguous_roots` blocks `armable_owner` even at
  `both_count == 1`) and the fallback (global root count ≥ 2 → no
  election).
- [round-2] Owner movement: region with a live PARTIAL window → rebind
  moves the owner → the remainder flushes against the OLD owner (its
  penalty/gate state moves, the new owner's doesn't) and the activation is
  closed before the new owner publishes.
- [round-2] Owner collision: two live regions where a rebind moves one's
  owner onto the other's → the moved region's live accumulator is closed
  at publish (no two live accumulators share an owner behind
  `openRegion`'s back).
- [round-2] Generalized fallback: an ext-entry member that is NOT
  root-shaped + exactly one root-shaped member elsewhere → fallback elects
  the root member.
- [round-2] Tombstoned-in-the-same-pass: a region that arms and tombstones
  in one rebuild performs NO gate clear (latch stays unset).

### C-impl — grounded implementation design (2026-08-20)

Live evidence, `-Djit-debug` probe on nbody 1000: the {advance:34,
advance:132} region mints `armable=false (owner_unique=false
membership_complete=true bridges=0)`. Owner scan shows both members
`ext_entry=false` (fully closed cycle — dispatcher-entered, no incoming
structural edge) and `enclosing=false` — the static enclosure test
*structurally cannot* pass for sibling loops: 132's `for_loop` body span
`(132, flp]` can never contain 34 (`34 < 132`), and symmetrically 34's span
excludes 132's continuation shape. `--dump-traces` pins the shapes: trace@34
terminal `%134 loop` (inner root), trace@132 terminal `%135 link -> 34`
(continuation). Exactly one inner-root member — C.1's election has a unique
winner. Separately observed: `hasInnerRootAt` goes true at BOTH anchors on
the second discovery pass (the round-2 spurious same-anchor sibling case is
live, not hypothetical).

**C.1 election — member-scoped primary + member-shape fallback** (owner
scan, trace.zig `3e.` block ~:9085):

- Replace the cache-wide `has_root = hasInnerRootAt(proto, a.pc)` with a
  member-scoped COUNT: `member_root_count = |{tid ∈ member_trace_ids :
  traceById(tid)` resolves and `isInnerLoopRoot(t, proto, a.pc)}|`. Same
  shape test, restricted to the region's physical realizers — kills the
  round-2 spurious sibling in the PRIMARY predicate too (C.3 test 4). A
  `traceById` miss simply doesn't count (and `membership_complete` is
  already false on any unresolvable member, so the region can't arm
  regardless — fail-closed composition, no new edge).
- **Counting TRACES, not nodes, in the primary too** [codex round-2
  blocker 2]: a per-node *existential* predicate would collapse two
  root-shaped member traces cached at one external/enclosing anchor into
  `both_count == 1` and elect through the ambiguity. Rule: any node with
  `member_root_count >= 2` sets a sticky `ambiguous_roots` flag; the
  primary predicate is `(is_ext or enclosing) and member_root_count == 1`;
  final `armable_owner = (both_count == 1) and !ambiguous_roots` — a
  same-anchor two-root region fails closed even when a *different* node
  qualifies cleanly.
- Fallback tier, `both_count == 0 and !ambiguous_roots` only: count member
  traces whose terminal is `.loop` at their own anchor
  (`isInnerLoopRoot(t, t.anchor.proto, t.anchor.pc)`). Exactly ONE → elect
  that trace's anchor node as owner (`both_count := 1`); zero or ≥2 → the
  existing deterministic-placeholder + `armable=false` path, unchanged.
- The fallback is gated on `both_count == 0` alone, not on "no member has
  `is_ext`": that subsumes the closed-cycle wording above (a closed cycle
  has no ext member, so both_count==0 whenever no enclosing member passes),
  and additionally elects the unique root member when an ext-entry member
  exists but isn't root-shaped. Sound because owner is *accounting identity
  only* (C.1 recast), entry-agnosticism holds (audit below), and
  external-entry status is consulted by neither activation nor receipt
  classification [codex round-2 confirms] — the general mechanism, not an
  nbody special case (Rule Z-6).
- Determinism: a pure function of the recorded trace set + region graph
  (member_trace_ids is sorted/deduped; the scan order is node order; the
  fallback scans member_trace_ids in sorted order). No ticks, no addresses.

**C.1b owner movement closes live accumulators** [codex round-2 blocker 1
— pre-existing hazard (staged_owner_updates has always been able to move
the owner), made hot by the fallback]:

- `RegionAccum` is keyed `{region_id, call_seq}` only; `flushRegionWindow`
  reads `def.owner` at flush time (:3753). Publishing a moved owner while
  an accumulator is live means (a) work accumulated under owner A later
  strikes/clears owner B, (b) two live regions can silently converge on
  the same owner without `openRegion`'s same-owner collision replacement
  (:3969) ever running, and (c) an armable→unarmable rebind that also
  moved the owner flushes its remainder against the NEW owner in
  `closeNonArmableAccumulators` (which runs after publication).
- Fix: during rebind staging, when `!sameAnchor(stored.owner, cand.owner)`
  record the region id in a scratch `owner_moved` list. In the publish
  phase, BEFORE the `d.owner = u.owner` loop (:9366), close every live
  accumulator whose key matches a moved region id (victim-scan +
  `closeRegion`, the `closeNonArmableAccumulators` pattern) — the
  remainder flushes against the still-installed OLD owner, the correct
  blast radius for the evidence that produced it. `closeRegion` is
  infallible (map ops + flush + demote), publish-phase safe.

**C.2 gate-reopening latch** (publish phase, after the tombstone loop
~:9388):

- `RegionDef` gains `gates_cleared: bool = false` — the once-per-region
  latch. Never reset, not even by tombstone (tombstoned regions can never
  re-arm, so a reset would be dead).
- **Anchor-only clear, NOT the footprint-wide `clearMemberAnchorState`**
  [codex round-2 blocker 3]: `clearMemberAnchorState` walks the full
  `member_points` footprint — every member trace's recorded-path PC —
  which is justified at first qualification (the region then owns
  footprint-wide barren-receipt attribution via `qualifiedActiveMember`)
  but NOT at mere armability: before qualification, unrelated legacy
  traces at interior footprint PCs still own their profitability evidence.
  New helper `clearMemberTraceAnchorGates(member_trace_ids)`: resolve each
  member trace via `traceById`, drop `penalty` + `gate` entries at its
  anchor `AnchorKey` only (removals idempotent; no dedup needed). Inherent
  collateral, documented: an unrelated trace cached at the *same anchor*
  as a member shares the anchor-level gate and gets its gate dropped too —
  gates are anchor-keyed, that granularity is the design.
- Sweep `active_regions` (deterministic candidate order) right after the
  tombstone publication: for each entry with `a.armable`, fetch the def;
  if `!def.gates_cleared` → `clearMemberTraceAnchorGates(a.member_trace_ids)`
  + `def.gates_cleared = true` + dbg line. Sweeping active_regions (not
  all region_defs) suffices: every armable transition flows through
  mint/rebind in this pass, and both append to active_regions.
- Ordering constraints, all satisfied by the site: (1) after `d.armable =
  u.armable` publication and (2) after tombstones re-clear armable
  (:9382), so a region tombstoned in the same pass never clears gates —
  `active_regions[i].armable` already reflects tombstone conditions, and
  the def re-check makes it belt-and-braces; (3) infallible (hash-map
  removals + a bool store), publish-phase safe; (4) precedes the single
  `bumpGen(&region_defs_gen)` so the def mutation rides the rebuild's one
  transaction bump.
- The existing first-qualification `clearMemberAnchorState` call
  (creditRegionWork :4747) STAYS — footprint-wide is correct *there*; C.2
  covers only the anchor gates that would starve the region of entries
  forever (`isGated` blocks trace entry permanently at `max_strikes`).
- Owner-anchor gates are member-anchor gates (the owner is a member
  trace's anchor), so `flushRegionWindow`'s owner-keyed penalties/gates
  are covered by the anchor sweep.

**Entry-agnosticism audit (open question 4) — PASS, no offenders.**
`openRegion` keys activations on `{region_id, ctx.call_seq}` (:3957); owner
is consulted only for same-owner collision replacement.
`accountRegionProfit`/`creditRegionWork` classify receipts via the edge
classification indices + `regionMemberTraceAnchor` membership, never the
owner anchor. `flushRegionWindow` keys penalty/gate state on `def.owner` —
pure accounting identity, exactly C.1's recast. No site equates "region
entry" with "owner anchor".

**Hygiene, same commit:** fix the stale `hasInnerRootAt` doc comment
(:8448) still claiming the `inputs.len == 0` shape — `isInnerLoopRoot` has
been anchor + `.loop`-terminal only since B-iv.3.

### C.4 — dual-unit profitability verdict (the Phase C regression fix)

**Status: round-2 form landed 2026-08-20 and measured INSUFFICIENT (board did
not recover); superseded by the round-3 rule below (`.flow` never strikes —
Pall/hotexit-faithful). C is NOT committable without round 3.**

#### The regression, measured

Post-C `just bench` vs the post-B board (t0 columns flat between runs, so
machine load is excluded — only the JIT column moved, and only on
region-cycle benchmarks):

| benchmark     | post-B jit ms | post-C jit ms | delta   |
|---------------|--------------:|--------------:|---------|
| nbody         | 99.4          | 182.5         | +84%    |
| scimark-fft   | 292.4         | 597.8         | +104%   |
| spectral-norm | 57.6          | 106.7         | +85%    |
| scimark-lu    | 166.6         | 193.7         | +16%    |
| scimark-sor   | 75.4          | 84.3          | +12%    |
| grid_matmul   | 38.0          | 40.3          | +6%     |

`--jit-stats` on nbody 20000: post-B ran 84.7% of cycles as native trace
code (advance:34 = 87.5% of its entries traced); post-C runs **0.1%** —
199,844 of 199,921 loop entries are "tier-0, has-trace" (a trace exists,
the dispatcher refuses entry). `--jit-debug` shows the exact chain, on
every affected benchmark (nbody pc=34, spectral-norm pc=22/pc=4, fft
pc=131):

```
region: mint id=0 … armable=true            (C.1 fallback election — works)
region: gates cleared … (C.2 latch)          (C.2 — works)
disarm-reason: window gate-strike owner pc=34 work=4
gate: anchor pc=34 strikes=1 … strikes=6 window=8192
```

#### Root cause: traversal units price the wrong thing at the wrong blast radius

The receipts and the machinery all behave exactly as designed — the design
itself has a unit/blast-radius mismatch that Phase C exposed by arming a
region *shape* that could never arm before:

1. **The work unit is outer traversals** (doc 17 A.2.2, deliberate): a
   `.loop_done_linked` receipt contributes `region_work = 1` regardless of
   its local committed count `k`, so one big inner loop cannot inflate the
   window. Right rule for the shape it was written against (nsieve: owner =
   an outer composite loop; members are cheap; profit *is* traversal
   frequency).
2. **Phase C's fallback election arms fully-closed sibling cycles whose
   members ARE the heavy loops**, dispatched from an untraced tier-0 caller
   (nbody `advance`, spectral-norm `A`/`At`, fft/sor/lu/matmul kernels).
   One activation = one function call; the cycle traverses 1–4 times per
   activation, then the activation closes → `closeRegion` flushes a
   remainder `0 < work < min_useful` → strike. Every single activation
   strikes, unconditionally: this shape *cannot* reach a full window, ever,
   at any hotness — its traversal count per activation is a structural
   constant, while its per-traversal native work (the inner `k`s: hundreds
   of committed iterations) is invisible to the verdict.
3. **The strike's blast radius is the owner ANCHOR**: at `max_penalty` it
   `gateAnchor(owner)` (which `isGated`-blocks *plain trace entry*, not
   just region arming) + `condemnProvenanceEdgesAt` + `disarmAllLinks()`
   (whole-registry). The verdict "this region's transitions don't amortize"
   escalates to "never run any trace at this anchor" — condemning traces
   that are massively profitable *per entry*.

Pre-C these regions were unarmable, no accumulator ever opened, and the
legacy per-trace machine priced the very same receipts by their LOCAL
committed counts (`completed >= min_useful` → clear): heavy loops stayed
hot. Post-C the region machine consumes those receipts (A-vii-c.1
consumption boundary — correct), prices them in traversal units (wrong for
this shape), and gates.

#### The rule (general, not per-benchmark; round-2 form after codex REVISE)

The gate's question is "does this complex earn its seams, or would tier-0
be cheaper?" — and the direct measure of earned native work is **committed
iterations**, exactly the unit the legacy machine has always priced
(`completed >= min_useful` = useful segment). Traversals remain the window
**cadence** (deterministic, tier-independent, the anti-inflation rule for
window COMPLETION is untouched); the low-yield **verdict** gains a
**per-receipt** legacy-useful exemption, scoped to the pre-qualification
regime:

> A flush with `0 < work < min_useful` on an activation that has **never
> completed a full traversal window** (`!useful_window_seen`) is a useful
> verdict (clear owner penalty + gate) **iff at least one credited receipt
> individually carried `local >= min_useful`** (`local_useful_seen`).
> Synthetic barren verdicts are always strikes. Everything else is
> unchanged.

Equivalently: pre-qualification, the region machine may never strike an
owner on the strength of receipts at least one of which the legacy machine
would have individually priced as useful. Round 1 proposed a summed local
floor (`Σ local >= min_useful` since the last flush); codex rejected it
with two blockers and a major (see the review-round record below) — the
sum can be assembled from receipts legacy would strike individually (four
`work=1, local=2` receipts sum to 8 and would launder ping-pong), a
window-crossing receipt's credit would be consumed by the full-window
flush and leave a later remainder falsely bare (`work=10, local=10` →
window eats all 10 locals → `work=2` close strikes where legacy saw one
useful `completed=10` receipt), and pending credit would launder barren
streaks through `noteBarrenConsumed`'s `flushRegionWindow(key, 1)`. The
per-receipt flag + pre-qualification scoping dissolves all three:

- **Per-receipt, not summed:** `local_useful_seen |= (local >=
  min_useful)` at credit time. Four `local=2` receipts never set it; one
  `local=200` receipt does. Exactly legacy's per-receipt economics.
- **Scoped to never-qualified activations:** the regression shape (heavy
  members, 1–4 traversals per activation) *structurally cannot* complete a
  window, so it is always in this regime. Once an activation qualifies
  (`useful_window_seen`), the verdict machinery is exactly as today —
  full windows clear, remainders strike, freeze/silent-burst economics
  untouched. This kills the window-boundary attribution problem: in the
  exemption's regime there ARE no full-window flushes, so the flag is
  monotone per activation and no flush "consumes" it.
- **Synthetic barren verdicts force-strike:** `flushRegionWindow` gains an
  explicit verdict kind (`.flow` from credit/close paths, `.barren` from
  `noteBarrenConsumed`); `.barren` never consults the flag. A qualified
  activation decaying into barren execution is still priced (and an
  unqualified one's zero-work receipts were never consumed to begin with —
  they keep full legacy gating).

What it deliberately does NOT change:
- **Window completion stays traversal-only.** Qualification and
  freeze-after-qualify still require a genuine full traversal window —
  heavy-local regions simply stay unqualified and unfrozen (their work
  lives inside native loop bodies, not seam rows, so freezing buys them
  nothing). No inflation path returns.
- **True thrash still strikes.** Sibling ping-pong (locals ≈ 1–2 per
  entry) closes with low traversals and no individually-useful receipt →
  strike, exactly as today.
- **Frozen/promoted execution is untouched.** `driveSilentBurst` credits
  only frozen (⇒ qualified) activations, where the exemption never
  applies — no silent-summary plumbing needed (codex MAJOR 3 resolved by
  the scoping). The frozen shortcut inside `creditRegionWork` (bypasses
  `flushRegionWindow` when both maps are empty) carries no per-flush local
  state to reset — the flag is monotone and never consulted post-
  qualification.
- **Post-qualification remainder strikes stay.** A qualified activation
  closing on a low remainder strikes as today even if `local_useful_seen`
  (e.g. one `work=10, local=10` receipt: the full window already cleared
  penalty+gate; the `work=2` close costs one penalty point, recoverable by
  the next useful window — pre-C.4 economics, deliberately preserved).
  **[SUPERSEDED by round 3 below: measurement showed this preserved
  economics is itself the regression — the remainder strike is the
  pre-hotexit non-Pall invention re-created one level up.]**

#### Plumbing (receipts already carry both units — R2-1 orthogonality)

Doc 17's round-2 rule "work and structural role are orthogonal per
receipt" already forced every receipt site to have the local committed
count in hand; C.4 just stops discarding it:

- `RegionAccum` gains `local_useful_seen: bool = false` — latched when any
  credited receipt individually carries `local >= min_useful`.
  Activation-local, monotone, never reset by flushes.
- `creditRegionWork(key, accum, work, local)` — new `local` param; sets
  the latch before the window loop. The frozen shortcut needs no change
  beyond the parameter.
- `flushRegionWindow(key, work, kind: .flow | .barren)` — low-yield path:
  `.flow` + `!useful_window_seen` + `local_useful_seen` → clear penalty +
  gate and return (NEW); otherwise strike as today. `.barren` (from
  `noteBarrenConsumed` only) never consults the latch. A def-less flush
  (observer-closed) is unchanged.
- `accountRegionProfit(key, work, local, dest)` — new `local` param,
  passed through to `creditRegionWork`. Zero-work paths ignore it.
- Call sites: replayLedger row passes the row's `local` (already in scope,
  :6538) — both the slow path and the frozen fast path
  (`creditRegionWork(ff.key, ff.accum, region_work, local)`);
  `onSideExitReceipt` passes its `completed`; tier-1a/driveChain sites pass
  `cresult.completed`; `driveSilentBurst`'s direct `creditRegionWork` call
  passes 0 (frozen ⇒ qualified ⇒ latch never consulted; do NOT thread
  silent-summary evidence — out of the exemption's regime by design).

Determinism: local counts are committed iteration counts — pure functions
of the deterministic receipt stream, same as traversals (ledger cumulative
deltas, tier-1a `completed`, and native `local_completed` all deterministic;
codex confirmed). C.1b owner-move close flushes the latch's verdict against
the OLD owner — correct, the receipts were earned under it. C.2's latch is
orthogonal (gate clearing at arm, not verdict pricing).

#### C.4 tests (codex-required minimum in round 1)

- Heavy-local regression shape: receipts `work=1, local=200` ×3, close →
  CLEARS a pre-seeded owner penalty, no strike, no gate.
- Ping-pong pin: four receipts `work=1, local=2`, close (`work=4`, summed
  local 8) → still STRIKES — the sum-floor laundering shape, now the
  regression pin for the per-receipt rule.
- Barren laundering: qualified activation, then a `work=1, local=200`
  receipt, then `max_barren_run` consumed zero-work receipts → the
  synthetic `.barren` verdict still STRIKES despite the latch.
- Window-boundary pin: one `work=10, local=10` receipt → full window
  clears + qualifies; close remainder `work=2` → strikes (post-
  qualification economics preserved; documents the scoping decision).
- Window completion unaffected: `work=1` ×8 with tiny locals still
  completes the window and qualifies exactly as today.

#### Round 3 (2026-08-20, post-landing measurement): the per-receipt latch is NOT sufficient — the `.flow` strike itself is the non-Pall invention

The round-2 form landed exactly as approved (all four implementation pins
honored), passed the full gate battery (tests, six hashes both tiers,
three repros), and the board did **not** recover. `--jit-debug` tallies of
`window-clear` / `window-strike` / `disarm-reason: window gate-strike` /
`barren-run strike` per benchmark, current binary:

| benchmark     | post-B | +C.4 r2 | clears | strikes | gates | mechanism |
|---------------|-------:|--------:|-------:|--------:|------:|-----------|
| nbody         | 99.4   | 180.5   | 0      | 7 (w=3–4) | 6   | latch can never set: 5-body inner loops commit `local`=4–5 < 8 |
| scimark-fft   | 292.4  | 595.0   | 42     | 13 (w=1)  | 6   | short butterfly-stage activations don't latch; their strikes accumulate between clears → gate → `disarmAllLinks` ×6 (fft_transform:131: 78% traced → 0%) |
| spectral-norm | 57.6   | 70.2    | 0      | 12        | 0   | penalty never empties → frozen-shortcut famine (below) |
| scimark-lu    | 166.6  | 193.5   | 0      | 435,000   | 0   | strike per activation close; full windows recycle the penalty |
| scimark-sor   | 75.4   | 84.3    | 0      | 50,000    | 0   | same |
| grid_matmul   | 38.0   | 41.4    | 0      | 2         | 0   | 2 early strikes, never cleared → penalty persists the whole run |

Zero `barren-run strike` events anywhere: **every** striking flush is the
`.flow` close-remainder. Three distinct cost mechanisms, one root cause:

1. **Gate collapse** (nbody, fft): remainder strikes reach `max_penalty` →
   `gateAnchor(owner)` blocks plain trace entry + `condemnProvenanceEdgesAt`
   + `disarmAllLinks()` — native coverage 84.7% → 0.1% (nbody).
2. **Frozen-shortcut famine** (spectral-norm, grid_matmul; amplifies sor/lu):
   `creditRegionWork`'s frozen shortcut requires `penalty.count() == 0 and
   gate.count() == 0` — a single persistent penalty entry anywhere disables
   it globally, so every full window pays the full `flushRegionWindow`
   pipeline for the rest of the run.
3. **Per-close strike overhead** (sor 50k, lu 435k activation closes):
   `penalty.getOrPut` + unfreeze + promotion-demotion scan per close.

The grounding rounds 1–2 missed sits in `accountLegacyThrash` itself: the
hotexit arc (task #74) already removed exactly this invention from the
per-trace machine — *"a PRODUCTIVE segment is never a strike, however
short. LuaJIT has no `min_useful` analog at all … the only backoff
machine, `penalty_pc`, fires exclusively on recording ABORTS"* — legacy
strikes **only** `completed == 0`. The region machine's low-yield remainder
strike re-created the pre-hotexit rule one level up: `0 < work <
min_useful` at close is *productive traversal evidence* (the cycle DID
traverse; the native bodies DID commit work), and legacy would have priced
every one of those receipts as no-op-or-clear, never strike. The round-2
latch tried to carve an exemption into a strike that should not exist.

##### The round-3 rule

> A `.flow` flush **never strikes**. `work >= min_useful` clears
> (unchanged). `0 < work < min_useful` with the round-2 latch
> (never-qualified + `local_useful_seen`) clears (unchanged). Any other
> `0 < work < min_useful` `.flow` flush is a **no-op**: return without
> touching penalty, gate, freeze, or promotions. `.barren` — the synthetic
> zero-progress decay verdict — is the ONLY region strike, exactly as
> legacy's only strike is `completed == 0`.

Verified against the complete production caller set (`closeRegion`
remainder `.flow`; `creditRegionWork` full windows `.flow`, always `work ==
min_useful`; `noteBarrenConsumed` `.barren`):

- The strike path (unfreeze + `demotePromotionsForRegionReason(.unfreeze)`
  + penalty escalation + gate/condemn/disarm at `max_penalty`) becomes
  reachable only via `.barren`. The only production low-yield `.flow`
  caller is `closeRegion`'s remainder — and `closeRegion` demotes this
  activation's promotions (`.region_close`) and removes the accumulator
  immediately after the flush, so nothing depended on the unfreeze there.
- **What still gates, exhaustively:** (a) never-qualified activations'
  zero-work receipts are unconsumed → full legacy pricing (Option-A
  headroom, then gate); (b) qualified activations decaying to zero-work
  receipts → barren-run exhaustion (`max_barren_run`) → `.barren` strikes →
  gate at `max_penalty`; (c) recording aborts → the legacy abort-penalty
  path. Productive-but-small regions are accepted — the same acceptance the
  hotexit arc made per-trace: coverage growth (side traces, doc 16 patched
  exits) is the answer to short segments, not gating.
- **The round-2 latch clear is retained unchanged**: it actively clears
  owner penalty (accumulated via `.barren` or via legacy verdicts on the
  owner anchor) on legacy-useful per-receipt evidence, mirroring legacy's
  `completed >= min_useful` clear. Without it a `.barren`-struck owner
  whose region recovers through heavy-local (but low-traversal) activations
  would have no clearing signal until a full window.
- Diagnostics (`region_profit_flushes`, `region_profit_flushed_work`) keep
  counting no-op flushes — they price flush *traffic*, not verdicts.

##### Round-3 test updates

- Ping-pong pin (round-2 test 2) becomes the **no-op pin**: four
  `work=1, local=2` receipts + close, with a pre-seeded owner penalty →
  penalty **survives untouched** (the flush neither strikes nor clears).
- Window-boundary pin (round-2 test 5) becomes the **scoping no-op pin**:
  `work=10, local=10` qualifies via the full window (clearing as today);
  re-seed the owner penalty; close remainder `work=2` → penalty survives
  (latch is set but `useful_window_seen` scopes the clear off; and no
  strike).
- Tests 1 (latch clears), 3 (barren laundering strikes), 4 (`.barren`
  precedence at `min_useful=1`), 6 (window completion) unchanged.
- The provenance test that exercised the strike→condemn path via a direct
  low-yield `.flow` flush must switch to `.barren` — the only remaining
  strike kind.
- Gate-battery audit: any `trace_gate_test` that reaches the strike path
  via low-yield `.flow` flushes must be re-expressed via `.barren` or
  legacy receipts (audited in the change).

#### Alternatives considered

- **Disarm-only strikes (never `gateAnchor` from region verdicts):**
  unsound — the consumption boundary means legacy never sees consumed
  receipts, so fused thrash complexes would be ungated by both machines
  (the exact A-vii-c review blocker).
- **Credit locals into `outer_traversals` (capped or scaled):** reopens
  the window-inflation hole A.2.2 exists to close, and muddies
  qualification/freeze semantics.
- **Summed local floor (round-1 proposal):** REJECTED by codex review —
  launderable by many-small-receipt shapes, misattributes window-crossing
  receipts, and laundered barren streaks through the synthetic flush. The
  per-receipt latch above is its principled replacement.
- **`receipts_since_flush * 2`-style thresholds:** arbitrary heuristics
  that still change legacy economics; rejected with the sum floor.

### C.5 — amortize the per-activation region lifecycle (round 4, 2026-08-20)

Round 3 fixed the strike policy but **not the board**: nbody recovered
(102.4 vs 99.4 postB) and nothing else did — fft +90.3%, spectral-norm
+20.7%, lu +16.5%, sor +12.1%, grid_matmul +7–9% (r3 board
`20260820-082710` vs postB `20260820-063434`, jit ms). Coverage is fully
restored (fft :131 at 78% traced / 101.5M entries; sor native cyc/iter
identical to postB at 32.2 vs 32.1), so the residual is not policy and
not codegen — it is the **cost of the region-accounting lifecycle
itself**, paid per activation, on regions postB never opened at all.

#### The mechanism, measured

Phase C's canonical owner election (C.1) makes nest regions *armable*
that were owner-ambiguous before — that is its purpose. But armable ⇒
`openRegion` per activation ⇒ a per-activation open→account→close
lifecycle whose fixed costs postB structurally never paid (its receipts
were all `barren-noactive`: 9.8M/run on sor, no live activation, one dbg
line each). Two independent costs, both proven by direct measurement on
the r3 binary:

1. **fft — the observer span rebuild is 35.6% of the entire run.**
   fft(1024) runs **2,074,609 open/close pairs** (jit-debug tally;
   window-noop 1.96M, window-clear 117k — only 5.6% of activations ever
   qualify). Every `closeRegion` frees the `observer_fast` bitset spans
   and every non-`found_existing` `openRegion` reallocates + rebuilds
   them (`refreshObserverFast`: alloc spans, alloc words, memset,
   repopulate) — 2M times, with **identical content** each time, since
   the spans are a pure function of `def.member_points` and a stored
   def's `member_points` is immutable for the `RegionId`'s lifetime
   (rebind never replaces it — an incompatible rebind tombstones; frees
   happen only at epoch clear/deinit). `perf` on fft(1024):
   `refreshObserverFast` **35.59%** self, plus `openRegion` 2.8%,
   `accountRegionProfit` 1.8%, `flushRegionWindow` 1.1%, `closeRegion`
   0.6%, allocator+memcpy ~3% — the lifecycle is ~43% of the run. This
   is the textbook per-item-allocation failure mode: per-activation
   rebuild of a per-def constant.

2. **sor — the promotion mprotect churn is 100% of its promotion cost.**
   sor's activation is one outer-loop iteration; each one re-qualifies
   (12 windows), re-freezes, re-promotes, and the close demotes:
   **8 mprotect flips per activation** (`patchWindow`/`patchRel32` each
   flip the mcode region RW→RX around a small in-place write), 8,006 at
   bench size, 400k at the no-arg size. Two A/B experiments on the r3
   tree (5 reps each, `/usr/bin/time`, sor 1000):
   - `silent_promotion_enabled=false`: 0.085s → **0.070s** — promotion
     is currently a net *loss* on sor; re-earning the patches per
     activation costs more than the silent bursts save.
   - promotion ON + protection flips no-op'd (regions mapped RWX):
     **0.070s**, identical — the promote/demote *bookkeeping* is free;
     the syscalls are the entire cost.
   Kernel time never shows in perf (~0.2%) because the cost is TLB/CR3
   work and page-walk fallout attributed to user symbols afterwards.

Non-finding, recorded for the next round: lu/spectral/matmul show
*neither* signature dominant (lu: receipt-path ~13% incl.
`driveChain`/`driveDispatcherSilentResult`; spectral: 83.5% tier-0
`Vm.exec` + `observeRegionProgramPoint` 2.5%; lu 4 / spectral 10 /
sparse 6 mprotects total). They are smaller regressions (+7–21%) and are
re-diagnosed against a fresh board after C.5 lands — some of their delta
may be second-order fallout of the same lifecycle costs (allocator
pressure, act_cache invalidation per open).

#### C.5a — def-owned observer span cache

Move the `ObserverSpan` storage from `observer_fast` (freed and rebuilt
per refresh) to the `RegionDef` (built lazily once, freed with the def):

- `RegionDef` gains `observer_spans: ?[]ObserverSpan = null` (owned) and
  `observer_spans_failed: bool = false` — the build-refusal paths
  (per-proto range over `observer_span_max_range`, `maxInt(u32)` pc,
  alloc failure) set the sentinel so refusal is remembered instead of
  retried per open. Cache and sentinel are **never reset** for the
  def's lifetime: `member_points` is immutable per `RegionId` (verified
  above), so there is nothing to invalidate on rebind.
- `refreshObserverFast` becomes: resolve the def → if
  `observer_spans == null and !observer_spans_failed`, build once (the
  existing span-construction loop, verbatim) into the def → publish
  `observer_fast = { key, root_frame_depth, root_call_seq, spans =
  def.observer_spans.? }` as a **borrow**. The per-activation fields
  (key/depth/seq) still refresh per open; only the span storage is
  amortized.
- `freeObserverFast` stops freeing spans (it only clears the struct and
  the inline hot cache); the def's `deinit` path (`clearCache` epoch
  sweep, `TraceState.deinit`, and the staged-cleanup free at the
  discovery-failure unwind) frees `observer_spans` alongside
  `member_points`. **Ordering obligation (codex round-4 REVISE: the
  current tree gets this WRONG in both sites and must be reordered):**
  `deinit` frees defs at trace.zig:3229 *before* `freeObserverFast`,
  and `clearCache` frees defs at :11242 *before* `resetRegionProfit`
  clears the observer borrow. Fix: clear `observer_fast`/`observer_hot`
  before freeing any cached spans — in `clearCache`, move
  `resetRegionProfit()` ahead of the def-free loop; in `deinit`, call
  `freeObserverFast()` ahead of it. Factor one `freeRegionDef` helper
  (spans' words + span slice + members + member_points + bridges) used
  by published AND staged def teardown. Lazy cache mutation does not
  bump `region_defs_gen` (changes no membership verdict — codex
  confirmed).
- Determinism: pure memoization of a pure function of `member_points`.
  Same spans, same verdicts, zero behavioural change — the observer
  fast-path probe semantics are untouched.

#### C.5b — syscall-free exit patching (dual-mapped mcode arena)

Make `patchRel32`/`patchWindow` plain memory writes. Options weighed:

- **(i) Map mcode regions RWX permanently.** One-line simplicity; loses
  W^X entirely. The A/B above is literally this experiment, so its win
  is exact (sor 0.085→0.070).
- **(ii) Dual-mapping (chosen; codex round-4 APPROVED with a required
  fallback):** `memfd_create` + two `mmap` views of the same pages —
  one RW (writes: compile emit, patches), one RX (execution; all
  published addresses, rel32 targets, trampoline). No single mapping is
  ever W+X, and after setup there are **zero** protection syscalls —
  patching becomes `rw_base + (addr - rx_base)` stores. Confined to
  `McodeArena` in `nativegen.zig` (the platform-churn wrapper, per Rule
  Z-2). x86-64, single-threaded VM: no icache concern (coherent I/D;
  patches never run while arena code is on the stack — the existing
  invariant that makes the whole-region RW flip safe today).
  **Codex-required hardening (round 4):**
  - **Fallback backend, not unconditional replacement:** executable
    memfd mappings can be rejected by SELinux/seccomp or Linux
    `vm.memfd_noexec` even where anonymous mmap→mprotect works. On
    memfd creation, sizing (`ftruncate`), or executable-view mmap
    failure, fall back to the CURRENT anonymous-map + RW↔RX mprotect
    backend — never to RWX, never to compilation failure.
    `protectRegion` therefore stays, used only by the fallback.
  - Both aliases `MAP_SHARED` (`MAP_PRIVATE` diverges after COW).
  - `ExecPage.code` and every published/rel32 address stay in the RX
    view; rel32 arithmetic entirely in RX address space (the two views
    never mix in range checks — promotion targets are page-local and
    restored targets were already proven representable).
  - Writes translate via validated region-local offsets into the RW
    view; unmap both views exactly once at teardown; the fd may close
    once both mappings succeed; no `F_SEAL_WRITE` while the writable
    alias lives.
  - The pinned stdlib's `std.os.linux.MFD` lacks `MFD_EXEC`; keep any
    raw flag/probe inside `McodeArena` and fall back on older-kernel
    rejection (verify against the pinned toolchain source per Rule
    Z-1).
- The standalone one-shot page path (`alloc`'s non-arena
  mmap→memcpy→mprotect at nativegen:171) stays as-is: 2 syscalls per
  *compile*, amortized, not churn.
- Determinism: none — code addresses never enter VM semantics (existing
  invariant), and patch *decisions* are unchanged; only their cost.

Both C.5a and C.5b are general mechanisms (Z-6): every program that
opens an armable region stops paying the rebuild; every patch/unpatch —
present and future (entry patching, link arm/disarm on the arena path) —
stops paying syscalls. Nothing is conditioned on a benchmark shape.

#### What C.5 deliberately does NOT do

- **No def-level dormancy / persistent-freeze state.** Both were on the
  candidate list (stop opening chronically-unqualifying regions; open
  pre-frozen once earned). The experiments say the *bookkeeping* is
  already cheap once the two real costs are gone — adding cross-
  activation policy state (new invalidation obligations against rebind/
  tombstone/strike, new determinism surface) is not yet paid for by any
  measured residual. Re-open only if the post-C.5 board still shows
  lifecycle cost. **Follow-up (2026-08-20): it did — fft +26.8% /
  spectral +17.7% / lu +16.6% vs postB, all grounded as measurement-of-
  never-qualifying-defs cost. Dormancy is designed and scoped in §C.5c
  below; persistent-freeze stays unpaid-for.**
- **No change to promotion keying or the B-3 safety architecture.**
  Promotions stay activation-scoped with close-time demotes; C.5b makes
  the demote/re-promote cycle cheap instead of fighting the
  activation-matched drain invariants (`driveSilentBurst` panics on any
  key mismatch — the whole-set accounting depends on it).

#### C.5 tests

- **Span-cache reuse pin**: two activations of the same region def →
  the second `refreshObserverFast` publishes the same `spans.ptr`
  (pointer-identity: cache hit, no rebuild). Existing observer
  fast-path behaviour tests continue to pass unchanged.
- **Refusal sentinel pin**: a hand-built def with an over-range
  `member_points` span → first refresh leaves cache null + sentinel
  set; second refresh does not retry the build (observable via the
  sentinel; behaviour = slow path, as today).
- **Dual-map patch pin** (C.5b): arm + disarm a link on an
  arena-owned page → code bytes change at the RX view; execution
  through the patched site behaves as today (covered by the whole
  existing link/promotion battery — the pin is that the battery runs
  with zero mprotect syscalls, asserted in one test via
  `/proc/self/status`-free means: not asserted at runtime, verified by
  strace in the measurement protocol instead).
- Full existing battery: `just test`, `zig build test -Djit-debug=true`,
  six frozen hashes both modes, three repros.

#### C.5 measurement protocol

Board vs postB shadow (`20260820-063434-d2a51c6.tsv`). Expected: fft
recovers ≥35% (the refresh share), sor to ≈postB (both experiments
recovered it fully), nbody stays recovered; lu/spectral/matmul deltas
re-diagnosed from fresh perf if still >noise. strace count on sor bench
size must drop from 8,006 mprotects to O(traces).

#### C.5c — the post-board lifecycle residual (round 5, 2026-08-20)

The post-C.5a/b board (`20260820-093721`) recovered sor (+0.9%) and held
nbody, but the re-open clause above fired: fft +26.8%, spectral +17.7%,
lu +16.6%, matmul_f64 +10.6% vs postB — all lifecycle cost, none of it
the span rebuild or the syscalls.

**C.5c1 (landed, no wall-clock change — diagnostic value only).** Two
mechanical costs perf flagged inside the trio: `region_defs.get` copied
the whole `RegionDef` by value per open/flush/scan (→ `getPtr` + copy
out only the owner; safe — `region_defs` never inserts during close
paths, so pointers stay valid), and `captureProvenanceVerdicts`
re-scanned the ledger tail per matched row (O(rows²) per edge, 2.3% of
fft SELF → backward walk with a suffix cum-maximum, semantics pinned in
the code comment). Green, hashes/repros unchanged, fft wall identical —
which is the finding: the residual is *structural*, not copy overhead.

**The structural mechanism, grounded per benchmark** (jit-debug
histograms + perf + postB shadow A/B):

- **fft (N=60): 121,545 open→close pairs, one per outer iteration, all
  rid=0, all fresh inserts, zero qualifications.** Every close is
  `applyDestination dest=known_trace` — the steady state ping-pongs
  between the inner region and a non-member outer trace, and both the
  open (chooseSource) and the close (applyDestination) happen inside a
  SINGLE `accountRegionProfit` call. Each pair pays the accum
  getOrPut/remove, two `refreshObserverFast`, the act-cache
  invalidation, and the close-time flush — per outer iteration,
  forever. 114,720 productive-noop remainders, 6,825 C.4 local-useful
  clears, 37 legacy strikes; the owner (pc=131) is never condemned, so
  the gate machine (correctly, per the A-vii-e one-traversal-close
  lesson) never stops the churn.
- **lu (size 30): 2,970 opens, all departure-closed, 2,610
  productive-noop remainders, zero qualifications** — same futility,
  different close path (observer departure). On top: 148,499 receipts
  pay the full classify/choose/destination walk. Perf at bench size:
  `accountRegionProfit` 5.09% SELF + `isGated` 2.65% +
  `captureNativeCallProvenance` 1.81% + hashing — none of these in the
  postB top table.
- **spectral (N=100): only 19 opens — but each spans an entire outer
  A·v call (departure-closed), so a live activation with observer
  spans exists for essentially the whole 84%-tier-0 run.** 16/19 close
  futile. Shadow A/B: postB 1.41s vs now 1.55s at N=1000; the delta
  decomposes as `observeRegionProgramPoint` 2.73% SELF (absent in
  postB) + `execImpl` absolute growth ~7% (the inlined per-instruction
  span check). Per-instruction measurement cost, paid for activations
  that never qualify.

One sentence: **the region machinery measures every activation at full
price, forever, even when 121K consecutive activations of the same def
have produced zero qualifications.** Measurement must be finite.

> **STALE (kept for the record — see §C.5c3).** The lu and spectral
> close-verdict numbers above were measured BEFORE the C.4 dual-unit
> verdict and C.5a/b/c1 landed in-tree; re-measured post-c2 with the
> `region-close` probe, both defs now chronically QUALIFY (lu 2,760
> qualified : 120 futile; spectral 17/19 qualified). Dormancy — built
> from this grounding — therefore correctly never fires on them; their
> residual is per-receipt steering + observer cost on SUCCESSFUL defs,
> which is c3's problem statement. fft's futility grounding remains
> accurate.

**C.5c2 — def-level futility dormancy with deterministic backoff.**
The same shape as the legacy anchor gate machine (strikes → window →
retry), one level up: a def whose activations chronically close without
qualifying stops being *measured* — with exponentially-backed-off
retries so a slow qualifier is delayed, never lost. This is general
(Z-6): every program whose region defs qualify keeps exactly today's
behaviour; every program with never-qualifying defs stops paying
per-activation, per-receipt, and per-instruction measurement overhead —
whatever the benchmark. Nothing conditions on shape.

Mechanism (all counters are pure functions of the receipt stream, like
`frozen` — every mode ticks them on the same receipt, so replay cannot
diverge; all counter arithmetic SATURATES: `+|=`, `-|`, `*|`):

- `RegionDef` gains six fields: `futile_streak: u32 = 0`,
  `dormant_remaining: u32 = 0` (a COUNTDOWN of declined attempts, not
  a deadline — its maximum is the capped window, so saturation can
  never manufacture permanent dormancy; codex round-2), `probing:
  bool = false`, `probe_budget: u8 = 0`, `probe_inflight: u8 = 0`
  (admitted-but-not-yet-closed probes; codex round-3 BLOCKER — see
  the epoch close-out rule below), `probe_epoch: u64 = 0` (a
  wrapping generation counter, incremented every time a new probe
  epoch is armed; u64 so aliasing is lifetime-impossible).
  `RegionAccum` gains `probe_epoch: u64 = 0` and
  `is_probe: bool = false`; a close — natural OR administrative —
  retires a probe ticket (`probe_inflight -|= 1`) only when
  `accum.is_probe and accum.probe_epoch == def.probe_epoch and
  def.probing` (codex round-4 BLOCKER 2: a boolean tag alone lets an
  accumulator surviving a full wake retire a ticket from a LATER
  epoch, ending it prematurely; the generation match makes stale tags
  inert against every future epoch, not just the probing=false
  window).
- **Close provenance is explicit** (codex round-1 BLOCKER 1): not every
  `closeRegion` is a profitability verdict. `closeRegion` gains a
  `kind: RegionCloseKind` parameter; the nine call sites classify as:
  - **Natural** (the activation genuinely ran and departed — these
    feed the verdict): `applyDestination` source-close
    (`.destination_departure`, fft's 121K), chooseSource
    active-not-in-candidates (`.transition_departure`), observer
    fast/slow departure (`.observed_departure`, lu's 2,970 +
    spectral's 19), `dropRegionActivation` (`.frame_death`), and the
    observer slow loop's not-inside/activation-mismatch victims.
  - **Administrative** (lifecycle bookkeeping, NO verdict): the H-3
    same-owner collision replacement in `openRegion`
    (`.owner_collision` — the victim was displaced, not measured), the
    openRegion stale/cap eviction loop, chooseSource's
    tombstoned-active close (`.tombstone` — the def is still IN
    `region_defs`, `armable=false`; a null-getPtr test would misfire),
    `closeAccumulatorsForRegion` (both callers: owner-move rebind
    staging and the non-armable/tombstoned rebuild sweep), and the
    observer slow loop's vanished-def arm.
  Without this split, repeated rebinds or owner movement could
  manufacture K futile closes and put a viable def to sleep.
- **Verdict at natural close**: `!accum.useful_window_seen` is
  **futile**; `futile_streak +|= 1`. A qualified close fully wakes the
  def: `futile_streak = 0`, `probing = false`, `probe_budget = 0`,
  `probe_inflight = 0`, `dormant_remaining = 0` (a probe that
  qualifies after a re-sleep must still cancel the sleep).
- **`local_useful_seen` does NOT make a close non-futile.** C.4's latch
  protects the owner ANCHOR from gate strikes (blocking trace entry);
  dormancy blocks only measurement — the member traces still run
  native and enter freely, so the C.4 collapse cannot recur. And
  arithmetically it must not reset the streak: fft interleaves one
  local-useful clear per ~17 noops (6,825 : 114,720), so any streak
  threshold >17 would never fire. Qualification — the one outcome
  measurement exists to detect — is the only reset.
- **Dormancy trigger.** Two cases, both at close of an activation:
  - **Awake def (not probing), natural futile close**: if
    `futile_streak >= K`, sleep: `dormant_remaining = W` where
    `W = W0 *| (@as(u32, 1) << @min(futile_streak -| K, cap_shift))` —
    exponential backoff, capped.
  - **Probing def — epoch close-out via in-flight accounting** (codex
    round-3 BLOCKER: without it, an epoch whose admitted probes are
    ALL closed administratively — H-3 collision, stale/cap eviction —
    strands `probing = true, probe_budget = 0` with no natural close
    left to schedule the next countdown, and the def wedges into
    permanent decline). Every close of a CURRENT-epoch probe
    accumulator (the generation-matched retirement rule above),
    natural or administrative, does `probe_inflight -|= 1`. A natural
    close also verdicts first (strike or full wake). Then, still
    probing, if `probe_budget == 0 and probe_inflight == 0` the epoch
    is over without qualification → close out (codex round-4
    BLOCKER 3 guard): if `futile_streak >= K`, re-sleep —
    `probing = false; dormant_remaining = W` (computed from the
    CURRENT streak, so an epoch ended by a natural futile close
    re-sleeps with the escalated window, while one ended by an
    administrative close re-sleeps with the unchanged window: no
    verdict, no escalation, but no wedge either); if
    `futile_streak < K`, just end probing — the def returns to fully
    awake and the normal K-strike path governs from there
    (unreachable while rebind only grants epochs to dormant/probing
    defs, whose streak is necessarily ≥ K — kept as defense-in-depth
    so no epoch path can ever sleep a below-threshold def). Overlap
    corollary: a futile
    probe closing while a sibling probe is still in flight leaves the
    def awake (`probe_inflight > 0`) — new opens still decline on
    `probe_budget == 0`, and the sibling's eventual verdict ends the
    epoch.
  Backoff quantum (codex round-3 concern): the exponent advances per
  futile ACTIVATION, not per epoch — a fully-futile B=2 epoch adds two
  strikes, so successive windows grow ×2^B per epoch (×4 at B=2).
  Deliberate: dormancy exists to bound measurement cost, and faster
  escalation to the cap costs strictly less; the capped tail (the
  sampling floor) is unchanged, and a qualifying probe still fully
  wakes regardless of how large the window grew.
  Config handling: there is no central validated setter
  (`trace.config` fields are mutated directly), so the use sites clamp
  deterministically instead — `B_eff = @max(B, 1)`,
  `W0_eff = @max(@min(W0, 1 << 15), 1)`,
  `shift = @min(cap_shift, 16)` — pure functions of config, identical
  in every mode. Proposed defaults (config fields, test-overridable):
  `region_futility_strikes K = 4`, `region_dormancy_base W0 = 16`,
  `region_dormancy_cap_shift = 8` (max window 4,096 attempts),
  `region_probe_burst B = 2`. `K = 0` disables the whole mechanism —
  no counter reads OR writes anywhere (the config escape hatch for
  tests pinning pre-dormancy open/close mechanics, and zero open-path
  cost when off).
- **Decline at open — AFTER the H-3 collision scan AND the
  existing-accumulator check** (codex round-1 BLOCKER 2 + round-4
  BLOCKER 1): `openRegion` order becomes (1) getPtr + `armable` check,
  (2) the existing H-3 same-owner collision close
  (`.owner_collision`) — replacement semantics are an INVARIANT, not
  measurement: a receipt whose destination uniquely enters a dormant
  region B while same-owner region A is live must still close A, or
  A's observer and accounting stay active after positive departure
  evidence, (3) the existing-accumulator check: build the
  `(id, call_seq)` key and, if an accumulator is already live for it
  (the found-existing reselection path — a normal path today),
  return it with NO dormancy interaction whatsoever (no ticket
  consumed, no countdown decrement, no decline — the activation is
  already open; this also covers the def that went to sleep while
  this activation was live), (4) the dormancy state machine below,
  applied only to FRESH admissions, (5) the cardinality scan,
  getOrPut, observer refresh, and act-cache invalidation only for
  ADMITTED opens. Admission is TRANSACTIONAL: `probe_budget` /
  `probe_inflight` / the accumulator's probe tag are only committed
  after `getOrPut` successfully inserts — an allocation failure must
  not leave an in-flight ticket with no accumulator to retire it.
  (The countdown decrement on a declined attempt needs no
  transaction: a decline allocates nothing.) A declined open costs
  the getPtr, the collision scan over a ≤1-entry map, one map probe,
  and one decrement.
- **Probe admission is bounded at OPEN, not consumed at close** (codex
  round-2 BLOCKER: overlapping activations of one def — nested or
  recursive calls give distinct `call_seq`s — would otherwise all be
  admitted during a probe epoch before any close consumes the budget,
  creating unboundedly many accumulators and killing the
  single-accumulator observer fast path). The open-time state machine:
  - `dormant_remaining > 0` → `dormant_remaining -|= 1`; if it just
    reached 0, arm the next epoch (`probing = true`,
    `probe_budget = B`, `probe_inflight = 0`,
    `probe_epoch +%= 1` — the generation bump that makes every
    older probe tag inert); either way DECLINE this attempt.
  - `probing` → if `probe_budget > 0` { ADMIT at full price;
    after the successful insert commit `probe_budget -= 1`,
    `probe_inflight +|= 1`, and tag the new accumulator
    (`is_probe = true`, `accum.probe_epoch = def.probe_epoch`) } else
    DECLINE (all B tickets issued; the epoch ends when the last
    in-flight probe closes).
  - otherwise (fully awake) → ADMIT (untagged).
  Admissions per epoch are exactly ≤ B regardless of close ordering.
  An administrative close of a probe activation records no verdict
  and does NOT reissue the ticket — it retires it (the
  generation-matched `probe_inflight` decrement), so one epoch
  under-samples and the next corrects; the epoch can never strand.
  Accumulators tagged in an OLDER epoch (survivors of a full wake or
  rebind wake) can never retire a later epoch's ticket: retirement
  requires `accum.probe_epoch == def.probe_epoch`, and every epoch
  arm bumps the generation.
- **What a dormant def stops paying**: the accum churn and act-cache
  kills (fft), the credit/flush/close work (lu), and — because no
  activation ever opens — `refreshObserverFast` leaves
  `observer_fast` empty, so the per-instruction observer check
  collapses to its empty fast-out (spectral). The receipt path still
  pays classification-only (~3 hash lookups: classifyExit,
  dest_entry_regions, the declined open's getPtr) — same as today's
  barren-noactive path, which fft already took 122,880 times.
- **Probe epochs sample B activations each**: the countdown's last
  decline arms the epoch, the next B open attempts are admitted and
  measured at full price. B=2 bursts cut the sampling-aliasing risk
  of single-activation probes against periodic workloads. If any
  probe qualifies the def fully wakes; if all close futile the streak
  has grown by B and the next window is ×2^B. Total measured
  activations over N attempts ≈
  `K + B·ceil(cap_shift/B) + B·N/(capW+1)` — the capped tail is a
  sampling floor, not O(log N); for fft's 121,545 attempts that is
  roughly 4 + 8 + 60 ≈ 72 measured instead of 121,545.
- **Rebind wakes — but only defs that were asleep or probing** (codex
  round-4 BLOCKER 3: unconditionally granting an epoch would let a
  rebind of a fully-awake, below-K def start a B-probe epoch whose
  close-out could sleep it with `futile_streak < K`, bypassing the
  strike threshold). A same-id re-record updates the stored def in
  place, so the counters persist naturally — but new members/bridges/
  owner can change profitability, so a successful rebind PUBLISH that
  leaves the def ARMABLE also checks
  `dormant_remaining > 0 or probing`: if so, wake into a fresh probe
  epoch (`dormant_remaining = 0`, `probing = true`,
  `probe_budget = B`, `probe_inflight = 0`, `probe_epoch +%= 1`,
  `futile_streak` preserved) — improved physical coverage gets an
  immediate probe burst instead of waiting out up to 4,096 attempts;
  if the def is fully awake it simply stays awake (the normal K-strike
  path already measures every activation). A same-pass tombstone skips
  the wake (waking a def the armable check permanently blocks would be
  dead state). Tombstone wins over dormancy trivially (armable check
  sits first); tombstoned defs keep whatever counters they had — they
  can never open again.

What c2 deliberately does NOT do:

- **No global receipt early-out (yet).** An awake-def-count fast-flag
  at the top of `accountRegionProfit` could skip even the
  classification hashes when everything is dormant. It adds a cross-def aggregate to
  maintain at every dormancy transition; the classification-only path
  is ~3 hashes and fft already demonstrates it at 122K/run without
  showing in the top table. Re-open from post-c2 perf if the receipt
  path is still visible.
- **No persistent-freeze (open pre-frozen once earned).** Orthogonal
  and still unpaid-for; dormancy removes the churn that made it look
  attractive.

C.5c2 tests (alongside the full existing battery + hashes + repros):

- **Futility streak pin**: K natural futile closes of one def → next
  open declines (openRegion null, no accum inserted); a qualified
  close among them resets (K more needed).
- **Administrative closes do not strike**: tombstone close,
  non-armable rebuild sweep, owner-move staging close, and H-3
  collision close each leave `futile_streak` untouched.
- **H-3 across dormancy pin** (the round-1 blocker shape): dormant
  destination region B, live same-owner region A → the declined open
  of B still closes A; no accumulator or observer state survives the
  transition.
- **Backoff pin**: each futile activation advances the exponent —
  a fully-futile B-probe epoch grows the next window by 2^B, up to the
  cap; the countdown's last decline arms the epoch and the very next
  attempt is admitted.
- **Probe burst pin**: an epoch admits exactly B activations — also
  under OVERLAP (B+1 fresh opens before any close → the B+1st
  declines); a qualifying probe cancels the burst and clears the
  streak.
- **Stranded-epoch pin** (the round-3 blocker shape): B=1, the single
  admitted probe is administratively closed (H-3 collision) → the def
  re-sleeps with the UNCHANGED window (no verdict, no escalation) and
  the following countdown expiry admits a fresh probe — no permanent
  decline.
- **Epoch overlap pin**: two live probes, first closes futile with
  budget 0 → def stays awake (`probe_inflight = 1`), new opens still
  decline; the second's qualified close fully wakes it (or its futile
  close re-sleeps with both strikes).
- **Existing-accumulator bypass pin** (round-4 blocker 1): a redundant
  `openRegion` for an already-live `(id, call_seq)` returns the live
  accumulator without consuming a ticket, decrementing the countdown,
  or declining — including when the def went dormant while that
  activation was live.
- **Stale-tag generation pin** (round-4 blocker 2): probe P2 of epoch
  A survives a full wake (its sibling qualified); the def later
  re-sleeps and arms epoch B; P2's close during epoch B does NOT
  retire an epoch-B ticket (generation mismatch) and epoch B ends
  only by its own probes' closes.
- **Rebind below-K pin** (round-4 blocker 3): rebinding a fully-awake
  def with `futile_streak < K` grants NO probe epoch — the def stays
  awake and only the normal K-strike path can sleep it; rebinding a
  dormant def wakes it into a probe burst.
- **Reset pin**: a qualifying retry activation clears the streak; the
  def opens freely afterward.
- **Observer interaction pin**: def dormant → `observer_fast` stays
  empty across receipts that would previously have opened (no
  per-instruction observation).
- **`K = 0` disable pin**: existing open/close churn behaviour intact.
- **Rebind wake pin**: re-record of the same id preserves the streak,
  clears the countdown, grants a probe burst.
- **Saturation pin**: `futile_streak` near `maxInt` neither wraps nor
  panics nor overflows the window computation (`dormant_remaining` is
  structurally bounded by the capped window).
- **Cross-mode counter equivalence**: the same program driven through
  the trace modes leaves identical
  (`futile_streak`, `dormant_remaining`, `probing`, `probe_budget`,
  `probe_inflight`, `probe_epoch`)
  per def AND an identical per-def ADMISSION count — the receipt
  stream is mode-invariant, and the admission count pins that no
  execution route takes a redundant extra `openRegion` (equal terminal
  counters alone could mask divergent-then-reconverged intermediate
  dormancy, which would alter JIT coverage).
- Existing gate/region tests that open >K futile activations get the
  config override (`K = 0`) where their intent is to pin pre-dormancy
  lifecycle mechanics, or the streak semantics where their intent is
  pricing.

C.5c2 measurement: quick A/B (fft N=500 wall, lu 200, spectral 1000)
vs the postB shadow, then the full clean board (nothing concurrent).
Expected: fft recovers most of +26.8% (121K × full lifecycle → ~72
measured activations, the capped-tail estimate above); spectral most
of its observer share — jit-debug confirms ZERO qualifications across
its 19 opens (two defs: rid=0 opens once, rid=1 the rest), so rid=1
sleeps after K=4 and observer coverage drops to ~1/4 of the run; lu's
open/close churn disappears but its 148K-receipt classification-only
path may remain visible — post-c2 perf must separate classification
cost from lifecycle cost before claiming lu recovered (the "most of
+16.6%" expectation is weaker than fft's). sor/nbody unchanged; no
benchmark regresses.

#### C.5c3 — chronic-qualifier residual: receipt steering memo + observer above-root fast-out

**Post-c2 board verdict (reps 5, jit ms, tree vs postB 80e199c).**
Dormancy did exactly what it was designed to: fft's futile def sleeps
(121K attempts → ~72 measured activations, +26.8% → +9.7%) and the c2
battery is green. But the "no benchmark regresses" gate FAILS:

| benchmark       | Δ vs postB | close verdicts (probe)        | def state during run |
|-----------------|-----------:|-------------------------------|----------------------|
| scimark-lu      |     +17.8% | 2,760 qualified : 120 futile  | awake, qualifying    |
| spectral-norm   |     +20.3% | 17 / 19 qualified             | awake, qualifying    |
| grid_matmul_f64 |     +10.4% | 202 qualified : 0 futile      | awake, qualifying    |
| scimark-fft     |      +9.7% | (dormant after K=4)           | dormant              |
| grid_matmul     |      +4.5% | (int twin of _f64)            | awake, qualifying    |
| nbody           |      +3.5% | —                             | —                    |
| pi_leibniz / str_gmatch / tbl_ops | +2.8–3.1% | — | near noise floor |

**The pre-c2 futility grounding is STALE.** §C.5c's pre-c2 numbers said
lu 2,610/2,970 futile and spectral 16/19 futile; measured with the new
`region-close` jit-debug probe the verdicts have inverted (lu 92:4
qualified per outer iteration, spectral 17/19 qualified) — C.4's
dual-unit verdict and C.5's amortizations changed the qualification
landscape between that grounding and now. Dormancy is a FUTILITY
mechanism and therefore correctly never fires on these defs. Their
residual is the price of SUCCESS: chronic QUALIFIERS never graduate
out of per-receipt measurement. c2 made chronic FAILURE finite; c3
must make chronic success (near-)free.

**Grounded mechanisms.** Two, not three — grid_matmul*/lu/fft all
reduce to (1):

1. **Per-receipt steering pricing.** Every ledger receipt pays the full
   classification walk even when its outcome has been identical for a
   million consecutive receipts: `classifyExit` (hash on
   `source_exit_regions`) → `chooseSource` (`activeRegionFor` map
   iteration + `region_defs.getPtr` tombstone check) →
   `region_profit.getPtr` credit lookup → `applyDestination`
   (`dest_entry_regions` hash + possibly a SECOND `openRegion`
   attempt). Grounding:
   - **fft** (dormant def): trace/walk counts vs postB IDENTICAL
     (1,015,077 entries / 1,012,527 walks) but the steering seam went
     210 → 335 cyc/walk — the entire +9.7%. `perf annotate`: 65% of
     `replayLedgerFrom` SELF sits at the per-row out-of-line
     `callq accountRegionProfit`. The only def is DORMANT — the memo
     answer is "decline" 1M+ times, re-derived from scratch each time.
     This is carve-out #1's re-open clause firing.
   - **lu** (awake def): 148K receipts fully priced —
     `accountRegionProfit` 3.59% + `hash.auto_hash` 3.91% +
     `wyhash.final` 2.23% SELF ≈ 9.7% vs base 3.3%. NOTE: the
     freeze-after-qualify latch (`accum.frozen`, C.5b) already
     amortizes the window/flush machinery INSIDE `creditRegionWork`;
     what lu pays is the steering AROUND the credit. So the "chronic
     qualifier graduation / persistent-freeze" carve-out #2 largely
     collapses into this memo — the frozen fast path exists, the memo
     is the missing steering half.
   - **grid_matmul_f64** (awake def): postB never armed a region here
     AT ALL (10 region dbg events per run); Phase C's owner election
     armed it, and now 160K native exits (N=400) each pay a receipt.
     jit-stats: identical traced-iteration counts and native c/it
     (11.9 vs 11.6), but the hot anchor's tier-0 bucket went 126.9 →
     404.8 c/it over 160,056 interp-entries ≈ +280 cyc/receipt ≈ the
     whole +10.4%. grid_matmul is the int twin, same shape.
2. **Observer inline-cache depth miss** — **spectral**: the activation
   spans the whole outer `A·v` call, so most interpreted instructions
   run at `depth > root_frame_depth`. `observeFast` requires exact
   `h.depth == depth`, so every such instruction misses the inline
   cache and pays the outline `observeRegionProgramPoint` call (5.02%
   SELF) just to hit its FIRST check, `depth > f.root_frame_depth →
   return` (survive). The commonest verdict isn't answerable inline.

**Fix (a) — receipt steering memo.** A small direct-mapped memo on
`TraceState` over the pure-structure half of `accountRegionProfit`
steering (fixed array, no allocation — hot-loop rule), invalidated by
WHOLESALE CLEAR at every mutation funnel (see "Memo invalidation"
below — no generation stamp; codex round-1 BLOCKER 2). Key:
`(exit_key.trace_id, exit_key.exit_instr, dest)` where `dest` is the
destination tag + trace id (`applyDestination`'s verdict depends on
it). Entry: `{ key, shape, rid, def: *RegionDef, ticks: u8 }` with two
memoizable shapes:

- **credit-to-active** (lu, grid_matmul*): recorded when
  `classifyExit == {rid}`, the receipt credited a live qualified accum
  for `rid`, and `applyDestination` was a no-op (source ∈ dest
  candidates, or dest `.deferred`). Hit requires
  `refreshActCache(ctx.call_seq)` valid (on a warm cache: two integer
  compares) AND `act_cache.key.region_id == rid` — then credit directly
  (`creditRegionWork` on the cached accum ptr; `work == 0` →
  `noteBarrenConsumed`, consumed=true — `act_cache` only ever holds a
  QUALIFIED accum, matching the slow path's `useful_window_seen` arm).
  Skips classify/choose/applyDestination entirely. Sound because with
  a live matching accum the slow path provably closes nothing and
  applies no destination action. `.terminal_outside` (and any dest
  whose candidates EXCLUDE rid) is NEVER memoized as credit — the slow
  path closes the source there (`destination_departure`).
- **dormant-decline** (fft): recorded when `classifyExit == {rid}`,
  no live accum existed (`region_profit.count() == 0` — one integer
  test on hit), and **every** open attempt this receipt made declined
  on dormancy **and targeted the SAME `rid`** (codex round-1 BLOCKER
  1: `chooseSource` opens the source candidate and `applyDestination`
  opens the destination candidate — those can be DIFFERENT defs, an
  ordered vector of `(def, decrement)` side effects, not one scalar;
  a mixed-def receipt is never memoized). Hit requires (via the
  cached def ptr) `region_futility_strikes != 0` (codex round-1 MAJOR
  3: dormancy can be config-disabled after populate, after which the
  slow path stops touching dormancy state entirely), `def.armable`,
  dormant (`dormant_remaining > ticks`), `!def.probing` — then
  decrement `dormant_remaining` by `ticks` (1, or 2 when
  `applyDestination` re-attempts the same rid; a pure function of the
  gen-valid indices for a same-rid singleton shape) and return false
  (not consumed). **The countdown MUST keep ticking on hits** —
  decline attempts are what count a dormant def toward its probe
  epoch; a memo that skipped them would starve the countdown and turn
  "delayed" into "lost" (the c2 invariant). When
  `dormant_remaining <= ticks` or `def.probing`: MISS — fall through
  to the full path so probe-epoch arming/admission happens in exactly
  one place (`openRegion`).

Every other receipt shape (no candidates, multi-candidate ambiguity,
unqualified accum, member-unclassified, tombstoned def, active-accum
mismatch) takes the existing slow path unchanged and does not populate
the memo. The memo is a pure cache: a hit's side effects are IDENTICAL
(not merely equivalent) to the slow path's — countdown ticks, credit
amounts, consumed verdicts — so mode-invariance is by construction,
and the cross-mode counter-equivalence pin extends to memo-on runs.

**Memo invalidation — wholesale clear, no generation stamp.** Codex
round-1 BLOCKER 2: a raw `*RegionDef` guarded by a wrapping `u32` gen
has an ABA hole — after 2³² bumps a stale slot's gen can alias back to
"valid" with a pointer into a rehashed/freed map. Instead of a wider
gen, the memo is CLEARED WHOLESALE at every point the defs or the
classification indices can change: it's a small fixed array and those
points are cold (`invalidateRegion`, the discovery-rebuild publish,
`clearCache`, plus `clearPhysicalRegionIndices`, covering
`rebuildRegions`' two fail-closed paths, which publish EMPTY indices
WITHOUT bumping the gen — a hole found while grounding: pre-memo it
was harmless because `Trace.region_memo_*` depends only on defs,
untouched there, but a steering memo caches index verdicts). Placement
matters (codex round-2 MAJOR): the clear must run BEFORE the first
pointer-invalidating operation on each path, not at the shared
`demoteSetsForRegionDefsMutation` funnel — the rebuild publish calls
`region_defs.ensureUnusedCapacity` (may rehash, ~trace.zig:9894)
BEFORE reaching that funnel (~9975), and `clearCache` frees defs
(~11619) before it (~11627), so a funnel-sited clear would leave a
window where entries hold dangling pointers. No receipt currently
interleaves in those windows, but the invariant must be structural,
not incidental: clear at the TOP of each mutating path (immediately
before capacity growth / def teardown / index clear). With that
placement, an entry only ever lives between two consecutive mutation
points, where def pointers are stable (`region_defs` only rehashes on
insert, and inserts only happen inside those cleared paths) — no gen
field, no ABA, no dangle. Dormancy state (sleep/wake/probing) changes
do NOT clear the memo — hits re-validate those through the cached def
ptr on every probe, as above; `region_profit` mutations do NOT clear
it either — hits re-validate map state (`count() == 0` /
`refreshActCache`) on every probe.

**Fix (b) — observer above-root fast-out.** Extend `ObserverHot` with
`root_depth_plus1: u64 = 0` (0 = cold), set by `refreshObserverFast`
whenever it publishes `observer_fast` (= `@as(u64, f.root_frame_depth)
+ 1`) and cleared with the rest of the struct by `freeObserverFast`
(`observer_hot = .{}`). The field is `u64`, not `u32`, because
`root_frame_depth + 1` is not total over `u32` (codex round-1 MAJOR 4):
at `root_frame_depth == maxInt(u32)` a wrapping `+1` gives 0 (= cold, a
silent fast-out loss and an aliased sentinel), and a saturating `+|1`
is UNSOUND — it leaves the threshold at `maxInt`, so `depth == maxInt`
(which IS root depth, not above it) would wrongly take the above-root
branch. Widening to `u64` makes the `+1` total and keeps `depth >=
root_depth_plus1` exact for every `u32` depth. `observeFast` answers
the above-root survive verdict inline, BEFORE the words/span probe
(spectral's hot-span half is cold at `depth > root`, so ordering after
it would never fire):

```zig
if (h.root_depth_plus1 != 0 and depth >= h.root_depth_plus1) {
    self.region_context = .{ .depth = depth, .call_seq = call_seq };
    return true;
}
```

— exactly the outline path's first check (`depth > f.root_frame_depth
→ return`) plus its entry `region_context` assignment, hoisted. Sound
by the same argument as e.2: a `true` re-derives the identical verdict
of a pure function of `(depth, ObserverFast)`, and the field dies with
the cache. Cost to depth==root workloads (nsieve): one predictable
compare on an already-loaded cache line — but the e.2 ordering
sensitivity at the interp call site (+11% on sor from one reorder)
means nsieve/sor A/B is mandatory before accepting it.

**What c3 deliberately does NOT do:**
- **No full persistent-freeze / qualifier graduation.** The frozen
  accum fast path + the steering memo should take a chronic
  qualifier's receipt to ~a probe + compare + frozen credit. If lu
  still regresses after c3, carve-out #2 re-opens as C.5c4 (graduate
  the DEF, not the activation: skip accumulation entirely for a
  proven-permanent region).
- **No memoization of close/open transitions.** Any receipt that
  closes or opens anything is a slow-path receipt by definition. The
  memo only serves receipts that change nothing but one counter or one
  accumulator.

**C.5c3 test battery** (extends the c2 battery; a config switch —
`receipt_memo = false` — pins slow-path equivalence):
- **Memo-equivalence pin**: a qualifying activation's receipts produce
  byte-identical accum state (traversals, windows, flush counts,
  `useful_streak`, frozen latch) and identical consumed verdicts with
  the memo on vs off.
- **Decline-tick pin**: with a dormant def, memo-on and memo-off runs
  leave identical (`futile_streak`, `dormant_remaining`, `probing`,
  `probe_budget`, `probe_inflight`, `probe_epoch`) at every receipt
  index — including the wake: the countdown's expiry receipt falls
  through to the slow path and arms the probe epoch at the same
  receipt index.
- **Terminal-dest pin**: a receipt with `dest = .terminal_outside`
  (or dest candidates excluding the source) is never served from the
  memo — the `destination_departure` close still happens.
- **Stale-memo pin**: a rebind between two identical receipts clears
  the memo (wholesale, at the mutation funnel); the second receipt
  misses and re-derives (catches both the normal rebuild and the NEW
  fail-closed `clearPhysicalRegionIndices` clear — pin the fail-closed
  path specifically: force an incomplete-`exit_prov` rebuild between
  receipts, memo must not serve the pre-rebuild classification). Per
  codex round-1 MINOR 8, the fail-closed case must also cover
  DESTINATION classification, not just source: a memoized credit entry
  whose `.known_trace` dest membership disappears in the
  incomplete-provenance rebuild must fall to the slow path, which then
  closes the source (`destination_departure`) instead of crediting.
- **Decline structural pins** (codex round-1 MINOR 5): (i) a
  single-attempt decline receipt memoizes with ticks=1 and replays 1
  decrement/hit; (ii) a two-attempt same-def receipt memoizes ticks=2;
  (iii) a source-A/dest-B mixed-def decline receipt is NEVER memoized
  — both defs keep slow-path countdowns; (iv) two dormant defs with
  unequal `dormant_remaining`, one near probe-arm: the near one's
  expiry receipt misses (countdown guard `dormant_remaining > ticks`)
  and arms its probe in `openRegion` at the identical receipt index as
  memo-off; (v) `region_futility_strikes` zeroed AFTER a decline entry
  was recorded: next hit fails the `!= 0` predicate, falls through,
  and the slow path leaves dormancy untouched thereafter.
- **act_cache lifetime pin** (codex round-1 MINOR 6): a credit-shape
  hit must re-read the accum ptr through `refreshActCache` on EVERY
  hit, never cache `*RegionAccum` in the memo — pinned by interleaving
  a `region_profit.getOrPut` growth (open a second region) between two
  hits of the same entry and checking the credit lands in the moved
  accum.
- **Probe-epoch bypass pin**: `def.probing` forces a miss — probe
  admission runs the real `openRegion` path.
- **Unqualified bypass pin**: `work == 0` receipts of an unqualified
  activation still reach the legacy machine (consumed=false) — the
  memo can't serve them (act_cache holds only qualified accums).
- **Observer above-root pin**: with a warm `observer_fast`, a
  `depth > root` query answers true inline with `region_context`
  updated; with `observer_fast` null it answers false; the outline
  path's verdict is unchanged (pure-function equivalence, the e.2
  test shape).
- **Observer lifetime pins** (codex round-1 MINOR 7): (i) opening a
  second accum frees `observer_fast` → `root_depth_plus1` reads 0 →
  fast-out dead; (ii) closing back to one accum republishes with the
  NEW root's depth, not the old one's; (iii) `resetRegionProfit` and
  `clearCache` both zero the field; (iv) `root_frame_depth ==
  maxInt(u32)` publishes `root_depth_plus1 == 1 << 32` exactly —
  `depth == maxInt(u32)` (root) does NOT take the fast-out, and no
  depth can (nothing above root exists at maxInt).
- **Cross-mode counter equivalence** re-run with the memo ON (the c2
  pin already covers OFF-equivalence semantics).

C.5c3 measurement: fft seam cyc/walk (expect back toward 210), lu/
spectral/grid_matmul* quick A/B, then the full clean board vs postB.
Gate: **no benchmark regresses** (the c2 gate, inherited). nsieve/sor
specifically A/B'd for the observeFast reorder.

#### C.5c4 — the awake machine's per-event hooks (round 6, 2026-08-20)

##### Where c3 landed, and what the feature-bisect proved

The c3 memo resolved fft (A/B −1.0%, seam back to 219 cyc/walk) and a
third shape (`.inert`: unclassified receipt, empty `region_profit`,
structurally no-op destination — spectral serves 21,940 of its 22,005
receipts from it). The gate still fails: **lu +15.4%, spectral +13.5%,
grid_matmul +3.7%, grid_matmul_f64 +3.2%** vs postB. Two scratch
experiments bound the residual exactly:

- **E1 (observer gate disabled, regions live).** lu drops 417M insn
  but only ~14–62M cyc; spectral drops ~70M insn, wall unchanged. The
  per-instruction observer is an instruction tax the OoO core absorbs
  almost entirely — it is NOT the regression. Deprioritized.
- **E2 (`rebuildRegions` no-op — the machine never wakes).**
  Instructions return to postB *exactly* (spectral 1.4231B vs postB's
  1.4220B; lu 3.636B vs 3.664B) and cycles land BELOW postB (spectral
  min 277.8M vs 296.9M; lu 823.2M vs 859M — Phase C minus the region
  tax is a net win; e.g. postB's `Gate.remove` at 3.29% of lu SELF is
  gone under C.2's latch). **100% of the lu/spectral gate failure is
  steady-state runtime cost of the AWAKE region machine, and E2 is
  the ceiling: with those hooks free, every failing benchmark beats
  postB.**

Per-benchmark localization of that tax (jit-stats per-anchor on lu —
trustworthy there; plain-run `perf` on spectral, where the
rdtsc-per-back-edge instrumentation inverts rankings and cannot be
trusted):

- **lu**: the whole +106M cyc sits at lu_factor:128's tier-0 surround
  (+274.7 c/it × 396,056 interp-its; every other anchor ≤ +8 c/it).
  396K native entries, each paying the full per-entry hook stack.
  Receipt counters: credit-hits 334,089, **lapses 60,791**, records
  7,441, misses 9. The lapses are structural, not churn: lu_factor is
  called ~8000 times, each call a fresh activation whose accumulator
  re-warms from zero — and BOTH memo predicates deliberately exclude
  the warmup (`refreshActCache` filters on `useful_window_seen`, so a
  `.credit_active` hit lapses until qualification; the record path
  declines unqualified accums at the same predicate, "legacy-priced").
  8000 activations × ~8 warmup receipts ≈ the 61K observed. Every
  lapse pays the full slow path: `classifyExit` hashing +
  `chooseSource` (with its linear `activeRegionFor` scan) +
  `applyDestination` + the declined record.
- **spectral**: +43M cyc, all inlined into `execImpl` (no outlined
  machinery symbols in the profile). The per-event population is NOT
  the 22K native entries — it is the **~18M interpreted `Av:9`
  iterations** (only 10.0% of Av:9 runs traced — a pre-existing
  coverage hole, identical under postB, NOT a Phase-C regression; it
  goes on the #103 queue, Atv:9 traces 99.8% with the same body
  shape). Each interpreted iteration makes an inner `A(i,j)` call →
  **~18M returns, each paying an outlined `dropRegionActivation`
  call** (interp.zig:3646/:3678; trace.zig:5783) whose
  `region_profit.keyIterator()` walks the map's allocated CAPACITY
  buckets — nonzero forever after spectral's brief early accumulator
  (41 credit-hits) grew the map. 18M × ~10–15 insn ≈ the +200M
  non-observer insn; 18M × ~2–3 cyc ≈ the +43M cyc.
- **Both**: `link arms: native=0 …, peak simultaneous arms: 0` — yet
  `captureNativeCallProvenance` runs per native call (396K on lu; 8
  sites incl. `.dispatcher_root` :8615 and `.inner_call` :8198) and
  its edge loop pays `provenance_edges × (2× traceById +
  parent.sibling_arms check)` before discovering nothing is armed.
  `settleNativeCallProvenance`'s four drains all early-out cheaply
  (flag/null/len checks) — settle is fine; capture is not.

##### The c4 rule: an awake machine may only charge events it can act on

All three fixes are the same general mechanism the memo and the
`provenance_arms_pending` settle cache already use — **an O(1)
precondition, maintained by the rare mutating events, guards every
per-event hook** — applied to the three hooks that still charge
per-event when they have nothing to do. Nothing is benchmark-shaped
(Rule Z-6): every function return in any program pays (i); every
warming activation in any program pays (ii); every native call in any
program pays (iii).

- **c4-i — per-return region fast-out.** `dropRegionActivation`
  becomes an inline wrapper: `region_profit.count() == 0` (an O(1)
  size-field read) short-circuits to the `region_context` clear check
  and returns — no outlined call, no capacity iteration. The outlined
  slow half (the existing scan-and-close loop) runs only with live
  accumulators. Kills spectral's 18M per-return walks (its steady
  state is count==0 — that is what `.inert` proves 21,940 times) and
  prices every return in every region-free program at 2 loads + 2
  branches. `dropRegionActivationsFromDepth` (interp.zig:1634) keeps
  calling the wrapper PER FRAME — no hoisted guard (codex round-1
  BLOCKER 1: a hoisted skip would drop the per-frame
  `region_context`-clear semantics on unwind-to-zero, leaving a stale
  context published; the inline wrapper already prices each frame at
  2 loads, so hoisting bought nothing).
- **c4-ii — serve the warmup: unfilter `act_cache`.** The cache drops
  its `useful_window_seen` filter and holds the live activation's
  accumulator UNQUALIFIED; qualification is read live through the
  cached pointer at each use site (it is a `*RegionAccum` — the field
  read replaces the stale-latch class where a mid-activation
  qualification left a valid-but-null cache until the next gen bump).
  Use sites re-audited: the memo `.credit_active` arm serves
  `work != 0` receipts against ANY live accum (`creditRegionWork`
  never required qualification on the slow path — :5409 credits
  unconditionally), serves `work == 0` against a qualified accum
  (`noteBarrenConsumed` requires `useful_window_seen`, same as slow
  path :5412), and serves `work == 0` against an unqualified accum as
  the slow path does: consumed=false, no side effects, return false
  (slow path :5407–5416 falls through both arms; the record then
  declines at both predicates — memo-serving this is
  side-effect-identical). `qualifiedActiveMember` (:5639) re-checks
  `m.accum.useful_window_seen` explicitly to keep its contract;
  `replayLedger`'s frozen-fast probe keys on `accum.frozen`, and
  freeze-after-qualify makes frozen ⇒ qualified — unaffected. The
  record path's qualified-only predicate (:5274–5275) is then DROPPED:
  a consumed credit receipt records regardless of qualification, so a
  fresh activation's first classified receipt re-arms the memo and the
  remaining ~8000×8 warmup receipts hit. The `.credit_active` hit's
  rid-match validation is unchanged — the memo still caches structure
  only.
- **c4-iii — armed-handoff global count.** A
  `TraceState.armed_sibling_total: usize` with the CENTRALIZED
  registry invariant (codex round-1 BLOCKER 2): after every
  successful registry mutation, `armed_sibling_total ==
  count(armed_links where kind == .sibling_handoff)`. Both the
  parent latch and the global count move INTO the authoritative
  `armNativeLink` mutation — the fresh-append path and the re-arm
  path increment when the NEW kind is `.sibling_handoff`
  (`publishSiblingArm` drops its external `parent.sibling_arms`
  increment; direct test arms then maintain the latch too), and
  `clearSiblingLatch` takes `self` and decrements both — which
  already funnels every removal/replacement path (identical sibling
  republication's clear-then-reincrement, sibling→ordinary
  displacement, `resetLinksTouching` retirement of parent or child,
  `disarmAllLinks`, `disarmLinkAt`). The global count is
  correctness-bearing, so it is EXACT, not saturating (codex minor
  7): `usize`, debug-assert nonzero before decrement; the parent
  latch keeps its existing saturating behavior (performance-only).
  `captureProvenanceVerdicts` gains the O(1) precondition
  `armed_sibling_total == 0 → return 0` ahead of the edge loop
  (mirroring `hasArmedSiblingHandoff`'s per-parent fast-reject,
  lifted global). With zero arms — lu and spectral's permanent state
  — capture is one load; the edge×traceById loop and the
  per-armed-edge ledger walk run only when a physical arm exists to
  verdict.

##### What c4 deliberately does NOT do

- **No observer change.** E1 priced it: cycles ~free. The insn tax is
  real on narrower cores but is not what fails the gate.
- **No dense live-activation index (yet).** `activeRegionFor`'s linear
  map scan still runs on memo misses/lapses and `chooseSource` — after
  c4-ii those are rare (fresh-activation first receipts). If
  grid_matmul* still fails the gate with live accumulators keeping
  `count() != 0` through c4-i, the follow-up is a small dense
  `(activation, RegionKey)` array maintained by open/close — general,
  but not built on speculation.
- **No touching the Av:9 coverage hole.** Pre-existing, symmetric with
  postB, belongs to the campaign queue not the c3/c4 gate.

##### c4 tests (extend the c3 battery; codex round-1 majors 3–5 baked in)

- **Warmup-memo pin**: a fresh activation over a def with a live
  `.credit_active` entry serves its pre-qualification `work != 0`
  receipts from the memo with accum state (traversals, windows,
  `useful_streak`, qualification latch point) byte-identical to
  memo-off; its `work == 0` pre-qualification receipts return false
  unconsumed from the memo (replacing the c3 "Unqualified bypass pin",
  which asserted the opposite disposition by design).
- **Cold-memo warmup record pin** (codex major 3 — pins the CHANGED
  record predicate, not just hit service): from an empty memo, a
  fresh unqualified activation's first classified `work != 0` receipt
  takes the slow path, stays unqualified, and RECORDS
  `.credit_active`; the second same-key receipt hits; accum state and
  the qualification-latch receipt index match memo-off exactly.
- **Unfiltered act_cache pin**: mid-activation qualification is
  visible through a previously-refreshed cache entry without a gen
  bump (the stale-latch class c4-ii removes); `qualifiedActiveMember`
  still refuses an unqualified member (silent promotion cannot fire
  pre-qualification).
- **Qualification-crossing zero-work pin** (codex major 5 — proves
  every qualification-dependent behavior reads `useful_window_seen`
  live through ONE cached pointer, no gen bump anywhere in the
  sequence): `work == 0` hit pre-qualification → false, `barren_run`
  untouched; `work != 0` memo hits carry the accum ACROSS
  qualification; the next `work == 0` hit → true with
  `noteBarrenConsumed` run.
- **Fast-out equivalence pin**: with `region_profit` empty but
  `region_context` live at the dying call_seq, the inline
  `dropRegionActivation` still clears the context; with a live
  accumulator at the seq it still closes (`.frame_death`) — slow-path
  equivalence over a scripted open/return sequence. Includes the
  unwind shape: `dropRegionActivationsFromDepth` to depth 0 with an
  empty-but-capacity-retaining `region_profit` leaves NO stale
  `region_context` (the codex blocker-1 scenario).
- **Armed-count invariant ladder** (codex major 4 — every registry
  mutation class, asserting `armed_sibling_total ==
  count(armed_links, kind == .sibling_handoff)` after each step):
  fresh sibling arm; sibling→ordinary displacement; ordinary→sibling
  replacement; identical sibling republication (clear-then-reincrement
  balances); targeted `disarmLinkAt`; `resetLinksTouching` with a
  retiring parent AND a retiring child; deferred `disarmAllLinks`
  through `applyPendingDisarms`; direct `disarmAllLinks`. Count
  returns to 0 at the end.
- **Zero-arm capture bypass pin**: with `armed_sibling_total == 0`
  and a NON-EMPTY `provenance_edges`, `captureProvenanceVerdicts`
  returns 0 without touching the edges — pinned structurally (codex
  major 4's instrumentation note): the edge scan moves to a testable
  helper the precondition guards, and the test calls the public entry
  against a poisoned-edge fixture (an edge whose parent id would
  panic/assert if resolved) so any touch is loud. With one armed
  handoff, the capture verdict for a strike ledger and a reset ledger
  is identical to the precondition-free helper called directly.
- **Cross-mode counter equivalence** re-run (inherited gate).

Comment sweep rides along (codex minor 6): the `act_cache` contract
comments (:2660–2668, `refreshActCache`'s doc block, the memo
`.credit_active` arm) all currently define null as "no QUALIFIED
activation" — after c4-ii null means only "no live activation for
this call_seq", and qualification is read live at each use site.
Stale comments here are load-bearing wrong.

c4 measurement: lu + spectral + grid_matmul* A/B vs postB first (the
four gate failures), then fft/nsieve/sor re-confirmed, then the full
clean board vs postB. Gate unchanged: **no benchmark regresses**.

#### C.5c5 — own the lifecycle, then graduate chronic success (2026-08-22)

##### Why this is structural

The c4 mechanisms are correct and remove their named mechanical taxes, but
repeated ReleaseFast A/B still leaves lu roughly +10–15%, spectral +11–14%,
and the grid twins roughly +1–5% versus postB. Conversely, suppressing region
publication makes lu/spectral/grid beat postB while making nsieve about 238%
slower. The region machine is therefore necessary, but charging its full
measurement lifecycle forever after a definition has repeatedly qualified is
not. This is no longer evidence for another call-site cache: graduation changes
admission, receipt accounting, close, invalidation, bridge, promotion, and
rebuild semantics together.

`trace.zig` currently owns all of those concerns alongside trace IR, cache,
recording, replay, native links, promotion patching, and native provenance. Per
Rule Z-7, chronic-success policy will not be added to that mixed 15k-line owner.
The lifecycle is extracted first into one durable ownership boundary, and the
new policy is implemented there.

##### Ownership boundary

A new `trace_region.zig` owns:

- `RegionId`, `RegionKey`, definitions/classifiers/bridges and their sole
  teardown path;
- logical interning, physical source/destination indices, generation, and
  transactional discovery publication;
- activations, context, accumulators, activation cache, observer spans/hot
  state, receipt memo, dormancy/probes, diagnostics, reset and invalidation;
- chronic-success mode, leases, deterministic reprobes, and revocation.

It takes an injected allocator and owns every allocation. It never accepts a
`*TraceState` and never reaches into trace cache, native links, promotions,
provenance, generic gates, or debug transport. `TraceState` retains trace/native
orchestration and owns one `regions: RegionState`; thin inline wrappers remain
only where interpreter or replay code generation needs stable syntax. Existing
public region names remain compatibility re-exports during this campaign.

If declarations needed by both graph orchestration and discovery would create
an import cycle, only region-neutral leaf declarations (`AnchorKey`, `ExitKey`,
`ProgramPoint`, or structural edge descriptors actually required on both sides)
move to `trace_types.zig`. `Trace`, native ABI records, link records, and
promotion records do not move merely to balance file sizes.

##### Explicit effects and transactions

Region APIs mutate only `RegionState` and return bounded decisions/effects for
`TraceState` to apply. Effects cover anchor gate/penalty clear or condemnation,
stale-link disarm, region/promotion demotion or candidate reset, bridge-arm
requests, and definition-generation mutation. Hot operations use compact
results or caller-owned fixed scratch: no per-event allocation, virtual
dispatch, aggregate copies, or added hash probes.

`TraceState` applies effects in the existing semantic order. During replay,
demotions and disarm-all remain deferred until the ledger walk completes;
bridge-arm handling follows those drains; provenance-arm publication remains
last. Bridge discovery returns structural proof only. Native capability checks,
`stubEnterable`, patch installation, and `NativeLink` stamping stay in
`trace.zig`; structural rejection flows back through the centralized region
invalidation funnel.

Discovery remains transactional. All fallible graph/catalog and index staging
completes before definitions and physical indices publish. OOM preserves
logical coherence and fails physical indices closed exactly as the current
implementation does. Owner moves close old-owner accumulators before owner
publication; gate-clear latches, incomplete-provenance behavior, and generation
invalidation are preserved byte-for-byte through extraction.

##### Deterministic chronic-success graduation

Graduation is a definition lifecycle distinct from futility dormancy:
`awake`, `graduated`, or deterministic `reprobe`. A definition tracks its
consecutive qualified-natural-close streak, graduation epoch, and fresh-
admission reprobe countdown/backoff. A graduated activation uses a compact
activation-indexed lease carrying region key, epoch, root identity, and exact
`barren_run`; it does not allocate a full `RegionAccum`.

The rules are:

1. Awake measurement remains the current authoritative path.
2. Only qualified natural closes advance the success streak. Futile natural
   closes reset it; administrative closes neither earn success nor manufacture
   failure.
3. Graduation occurs only at a close safe point with no live bridge,
   promotion, link, or gate obligation.
4. A graduated fresh admission creates a lease. Productive receipts reset its
   barren run; zero-work consumed receipts increment it exactly.
5. At the exact `max_barren_run` receipt, graduation is revoked *before* the
   authoritative barren strike is applied through the normal policy path. A
   long activation therefore cannot postpone decay until its next admission.
6. Leases cannot qualify bridge arms or promotion. Any bridge/promotion
   opportunity, gate or penalty mutation, topology change, owner move,
   tombstone, ambiguous receipt, or structural uncertainty revokes graduation
   and returns to full measurement.
7. Every deterministic Nth fresh admission is a full reprobe; redundant opens
   do not tick the countdown. Successful reprobes may increase a capped
   deterministic interval; failure resets the definition to awake.
8. One `revokeGraduation` funnel bumps the epoch first, clears lease/memo
   references, closes stale leases administratively, and resets policy state.
9. Dormancy/probing and graduation are mutually exclusive; the product-state
   invariant is asserted.

Policy thresholds are general deterministic constants justified by correctness
bounds and the broad benchmark board, never benchmark identity or wall time.

##### Implementation and gates

Implementation order:

1. establish shared leaves only if required, add `RegionState` ownership and
   move storage/teardown/reset behind it;
2. extract transactional discovery and topology publication through a
   read-only trace graph/catalog view;
3. extract admission, receipt accounting, close/invalidate, observers, memo,
   dormancy, and replay/promotion queries as one cohesive state machine;
4. normalize tests around a region-owned fixture/inspection API while keeping
   `trace.zig` the single test root;
5. add graduation and an always-awake oracle/config switch.

After every extraction phase, `just test`, `zig build test -Djit-debug=true`,
and `git diff --check` must pass, including allocator/leak and fail-closed OOM
coverage. Before graduation measurement, a canonical ReleaseFast shadow of the
pre-extraction working tree must show extraction-neutral counters and timing on
lu, spectral-norm, both grids, fft, nsieve, and sor; hot-wrapper symbols and
disassembly are checked where necessary.

The graduation matrix compares the default policy with the always-awake oracle
after every scripted receipt: consumed verdict, accum/lease state, strike
index, close verdict, mode/reprobe counters, and link/promotion effects. It pins
the G−1/G boundary, futile and administrative closes, fresh versus redundant
admission, capped reprobe backoff, long-activation barren decay, productive
reset, bridge/promotion revocation and requalification, topology/owner/
tombstone/incomplete-provenance/OOM/retirement/epoch invalidation, nested and
recursive activation, stale lease epochs, memo on/off, and tier-1a/native
equivalence. Existing nsieve bridge/promotion/silent-burst counters may not
fall.

The final gate is the focused post-B board (lu, spectral, grid twins plus
fft/nsieve/sor controls), followed by the full board and cross-mode output.
**No benchmark may regress versus postB.** Only then may C.5c3/c4/c5 and Phase C
be marked complete and the overlapping Phase-C/extraction/graduation working
tree land as the single Rule-13 commit.

##### Implementation checkpoint (2026-08-22)

The ownership extraction and default-disabled graduation state machine are now
implemented and correctness-green. Tests cover the graduation boundary, lease
productive/barren accounting and no-memo rule, deterministic reprobes and capped
backoff, bridge/promotion/gate/topology revocation, activation collisions,
observer closure, and lease/reprobe allocation failure. Scripted always-awake
and graduated streams agree on consumed verdict and strike boundaries; this
matrix found one real policy discrepancy, now fixed: `max_barren_run == 0`
disables decay for both full accumulators and leases.

Measurement does not yet justify enabling the mechanism. Eleven-run
enabled-vs-disabled medians at G=8 are effectively neutral (lu +0.23%, spectral
−0.69%, grid −1.78%, grid-f64 −0.36%; fft +0.02%, nsieve −1.02%, sor +0.25%).
Against the authoritative post-B binary, however, the focused best-of-five gate
remains red: lu +16.8%, spectral +13.5%, grid +4.6%, grid-f64 +3.7%. An
exploratory G=1 threshold makes the board substantially worse rather than
removing the awake residual (lu +55.6%, spectral +18.9%, grids +13.6/+17.7%).
It was reverted and graduation remains default-disabled. The next investigation
must instrument graduation/lease/revocation counts and profile the enabled G=8
path before changing policy or marking C.5c5 complete.

## Phasing & measurement

Land A → B → C as separate commits, each behind the full gate battery
(`just test`, `zig build test -Djit-debug=true`, six frozen hashes on both
tiers, three repros, 28/28 board cross=ok). Measure per phase against a
`just shadow` baseline:

- **A alone**: advance:132 compiles AND runs native on direct dispatcher
  entry (n.b. 132's hash cells are slot-rooted → it carries seeds → until
  Phase B its native page is reachable only via the dispatcher's own seeded
  entry — which works today). Per the A→B boundary (§A.1b round-4), A-alone
  seeding is the dispatcher's raw-input path: redundant seeds are still
  written (unread) and validated conservatively, so the criterion is
  "enters native when its entry seeds validate" — which they do for the
  carried-slot shape, since at entry the slot holds the current valid
  table; a redundant-seed validation failure downgrades to tier-1a, never
  misexecutes. Watch for a *regression* shape: more native
  entries each doing ~1 outer iteration of work with full per-entry dispatch
  cost. If A alone is wall-clock-negative on nbody, that is acceptable and
  expected to invert at C (record it, don't tune it away) — but the board
  must not regress elsewhere.
- **A+B**: chains/links arm across seeded traces. Adds: seeded-direct-entry
  A/B (the prologue callout replaces inline dispatcher seeding — measure the
  seam delta on a seed-carrying benchmark), and board-wide non-regression
  (nsieve-family must stay frozen-fast under the widened validators).
- **A+B+C**: the {34,132} cycle arms + freezes → native↔native patched
  cycle; nbody target: the 50.1% fallback + 37% untraced-outer collapse into
  traced time. Board-wide: any nest with an upvalue/global builtin or
  table-field inner loop is now fusable — watch scimark-sor/lu, grid_matmul,
  partialsums.

## Open questions for review

1. Phase A: is GP-home unification of `.ptr`-load/`.heap`-update carried
   slots complete, or does any consumer (coalescing, spill slot typing,
   guard operand classes) distinguish the two kinds in a way that needs an
   explicit conversion?
2. Phase B ctx: are link/cycle hops truly always same-frame (same closure,
   same base) — including loop-done continuations and side-walk successors —
   so the episode-invariant fill is sound? If any seam can cross frames, the
   ctx fill must move to that seam.
3. Phase B SEED_DECLINE for fused episodes: is "ledger ends at the
   decliner's anchor, resume tier-0 there" expressible in the current
   replayLedger grammar, or does it need a new row kind?
4. Phase C: is the receipts/promotion machinery actually entry-agnostic
   today, or does the audit in C.1 have known offenders?

## References

- `~/Projects/LuaJIT/src/lj_record.c` 605–700 — `rec_loop_interp`,
  `innerloopleft`, `rec_loop_jit`, the LINNER/side-trace/link model.
- doc 15 (nested-loop linking), doc 16 (coherent state chaining, incl. the
  corrected nsieve outcome: runtime-re-entry chaining is neutral on low-trip
  clusters), doc 17 (regions, arming, B-3 exit patching), doc 20 (patched
  entry), doc 11 (hash-field tracing, H1 seeding), doc 08 (store sinking).
- 0e311f9 — ptr-phi boxing (the `.ptr` flush precedent Phase A extends).
- Codex round-1 review (2026-08-20, gpt-5.6-sol): 8 issues — seed-context
  ABI missing (→ §B.1), analyze gate missed (→ §A.1), GC inventory wrong
  (astore_append never allocates on-trace; → §A.2), decline semantics wrong
  (→ §B.2), owner-as-entry proof invalid (→ §C.1), gate race must be solved
  not observed (→ §C.2), shared enterability predicate (→ §B.5),
  phase-local perf gates (→ Phasing).
- Codex round-2 review (2026-08-20): 5 issues — carried-heap hash lowering
  unsound in `.loop` traces (seeded cell reuse; → §A.1b), SEED_DECLINE
  cumulative-ledger/tri-state/silent-prefix protocol (→ §B.2), NativeSeedCtx
  needs stable heap storage + per-episode vm refresh (→ §B.1), same-frame
  invariant release-enforced (→ §B.1), owner election by physical membership
  not anchor scan (→ §C.1).
- Codex round-3 review (2026-08-20): 5 issues — carried-aware
  `hrefNeedsCallout` through ALL allocator stages, not just lowering
  (→ §A.1b), decline subtype/directive transport (two ExitReasons, VM-facing
  terminal directive, fused-capacity anchor correctness, patched-entry
  no-strike; → §B.2), page-owned seed plan instead of mutating immutable
  `t.inputs` (→ §A.1b/§B.4), tier-1a hash-decline still runs tier-1a
  (→ §B.3), `Vm.prepareNativeEpisode` split from the `TraceState` promotion
  sweep + episode identity in `stubEnterable` (→ §B.1/§B.5).
- Codex round-4 review (2026-08-20): 3 issues — home-coalescing exit
  inventory blind to the newly-dynamic guards (→ `opMayExitInBody`, §A.1b +
  the coalescing-safety pin, §A.3), A-alone seed-plan phase boundary
  unspecified (→ option (b): filtering begins in B, A-alone dispatcher
  raw-seeding is conservative; §A.1b + Phasing), seed/episode API
  inconsistencies (→ `seed_fn(ctx, t, plan)` in the struct + emission,
  `plan.nonEmpty()` as the §B.2 emission key, `{proto, call_seq}` stamp on
  `NativeSeedCtx` + context-freshness semantics for `stubEnterable`;
  §B.1/§B.2/§B.5).
- Grounding session receipts (2026-08-20): `--jit-debug` on nbody — mint
  `armable=false (owner_unique=false)`, `legacy-strike pc=34 completed=0`,
  gates at pc 4/34/211; `--dump-native` — trace #0 compiled 17149 B, trace #1
  unsupported; `--dump-traces` — the two IR listings quoted in §Why.
