# Pall-shape nest coverage — heap φ writeback, seeded-trace seams, inner-root owners

Status: partial — Phase A + Phase B through the gate audit (B-i…B-iv) landed (2026-08-20), B-v + Phases C–D outstanding
Owner: Claude (campaign arc 2; Bart 2026-08-20 mandate: every benchmark ≤1.2× LuaJIT)
Last updated: 2026-08-20

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

### Outstanding

- [ ] **Phase B-v — §B.6 tests + Phase-B measurement.** Remaining §B.6
  matrix (redundant-seed, fused-decline; chained hash-drift landed with
  B-iii) + A/B vs
  `just shadow` baseline; check nbody advance:132 bridge records/compiles/
  runs natively and link arms > 0.
- [ ] **Phase C — canonical owner election + gate reopening.** Elect the
  unique inner-root-shaped member of a closed cycle as the *canonical
  accounting owner* (not a proven entry point — the region must accept
  activation opening at ANY member), and add the deterministic
  unarmable→armable transition rule that clears the members' legacy
  strike/gate state exactly once so a pre-gated anchor can still receive the
  receipts that qualify the region.
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
