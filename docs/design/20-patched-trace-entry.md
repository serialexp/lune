# lune — Patched trace entry (the `BC_JFORL` analogue) — Design

Status: design APPROVED (codex gpt-5.6-sol round 8, 2026-08-14 — §R8 MINOR
§T10-wording fold applied); Phase 0a landed (`d4fd70f`), Phase 0b landed
(`272f75b`), Phase 1 (THE flip) landed; Phase 2 (§P measurement) next
Owner: Bart + agents
Last updated: 2026-08-15

## Implementation status

Tracking the gap between this design and what's on the main branch. Tick items
as they land; move bullets to Done once everything inside them is checked.

### Done

- [x] **Phase 0a — factor the entry/receipt routine** (`d4fd70f`,
      2026-08-14). Trial-walk body (529 lines) extracted into the
      directive-returning `Vm.enterSelectedTrace` + `EntryDirective` +
      `TrialWalkCtx`; the walk's directive switch is the caller-owned
      epilogue (§R3-3 drain site). Gated: full matrix (both flavors) +
      hashgate green; interleaved tier-0 A/B neutral (sieve_int, str_manip)
      to faster (scimark-lu −40%, likely icache — the dispatch loop shed
      529 cold lines).

- [x] **Phase 0b — inert patch substrate** (2026-08-14, `272f75b`). `.jfor_loop` opcode
      (dispatch arm panics until Phase 1 arms installs), per-VM copy-on-patch
      code images with the `image_gen` reload protocol (§R2-1: `codeFor` at
      the three frame-(re)load sites + `code_gen` memo + epilogue re-resolve)
      and epoch-stable lifetime (§R2-2: freed only in `clearCache` +
      `deinit`), stable-address per-slot-heap free-list registry with
      tombstones + `live` + publication/unpatch ordering (§R2-4/6), EntryPlan
      memoized as `seed_count` (the map already lives on `Trace.inputs`),
      `markEntryPatchPending`/`drainEntryPatchWork` (dirty-counter, §R2-4
      no-OOM-mid-grammar) hooked at the caller-owned epilogue, and every
      unpatch trigger wired as pending-mark: `removeTrace` (widen-eviction
      retires through it) via the `entry_slot` back-ref pre-destroy (§R7-2),
      `gateAnchor` (covers `gateNativeUnsupported` + low-yield), all
      `wants_side_trace`/`wants_prime_side` set sites, epoch clear, VM
      deinit. Strike exhaustion is the Phase-1 arm's own mark — substrate
      (`strikes` field + mark/drain) in place. Nothing installs in
      production (`installEntryPatch` is test-exercised only); §T7 pins
      no-image ⇒ pointer-identical canonical `codeFor`, plus lifecycle,
      incumbent-wins, dropped-trace drain, epoch, and trigger tests. Full
      matrix (both flavors) + hashgate green.

- [x] **Phase 1 — THE flip** (2026-08-15). Qualification transitions the
      per-trace `entry_patch` state machine (`eligible → pending → bound /
      suppressed_*`, §R4-2) inside `accountTraceRun`'s `min_useful` block
      behind a single compare; the caller-owned `drainEntryPatchWork`
      revalidates then installs ascending-trace-id (§R3-1/3, §R4-1:
      not-`.compiled` / `.link`-close → `suppressed_permanent`, gated →
      transient `.eligible`, incumbent/capacity → the matching suppressed
      state with tombstone/incumbent wakes); the `.jfor_loop` arm steps the
      canonical `for_loop` exactly once **including the internal-index
      increment** (§R2-3 hazard — omitting that first line re-ran the final
      iteration per strike cycle, guest corruption Δ=strikes×n, caught by
      Δ-analysis + jitdbg receipts), substitutes `patch.orig` for all
      downstream uses, bypasses (recording / suspend / safepoint-lines /
      exec-log / pending-anchor / coverage) to the virgin path, and enters
      via `enterSelectedTrace` with `visited = {ct}` (chain-exclusion
      invariant) + strike accounting (`patch_strikes` = 4, exhaustion marks
      pending-unpatch). Recorder mirror canonicalizes `.jfor_loop` fetches
      to `proto.code[cur]` (§R1-3). `min_trip_entry` demoted to dead config
      (default 0; kept one release for A/B). **Enablement fix in
      `driveChain` hop-0** (pre-existing latent, exposed the moment patched
      entry steered the chain): the scalar `sresult_fused` seam only models
      a `[C.link_terminal, I.x]` head, but a fused span can open with a
      sibling-handoff/M1 `.deopt` (or `.loop_done_linked`) dispatch — those
      heads now route to `driveDispatcherLedger` (the drain that already
      owns that grammar), generalizing the A-vii-d.1 `bridge_headed` special
      case (measured panic on the A-viii cycle: hop-0 candidate t4's
      handoff arm fired straight back into the excluded t3). Gates: full
      matrix both flavors 906/907 + hashgate + A-viii/floatlink repros
      green; the single red is the **pre-existing** `§R3
      capture→restore→resume` keyframeser test — bisected to fail
      deterministically at its own introducing commit (`7f803a8`, pre-doc-20
      entirely); decoded diff isolates it to dead stack slots 9–14 (H-5(i)
      dead-temporary omission from native exit snapshots: tier-0 leaves
      final-iteration temps, native exit flush freezes pre-burst values).
      Not a doc-20 regression; tracked as its own follow-up.

### Outstanding

- [ ] **§P.0 board confirmation** — the full-board neutrality run for Phase
      0a still owed: the first attempt was invalidated by load-70 parallel
      rust builds; re-run `just bench` on a quiet machine and compare vs
      `20260814-210757-99204e8.tsv`.
- [ ] **Phase 2 — measurement per §P.**
- [ ] **Phase 3 — `.jloop` analogue for while/repeat back-edges.** Same
      machinery on the backward `jmp`/`jmp_if_*`; separately measured (fft
      does not need it; bitreverse's `while` and the string loops might).
- [ ] **Open Q2 (§R1-8) — sibling rebind policy.** On strike exhaustion at a
      patched anchor with type-specialized siblings: rebind to the sibling the
      cold path selects, or unpatch and let warming re-decide. Default for
      Phase 1: unpatch + gate cooldown (simplest sound thing); rebind is a
      measured follow-up.

## Why this exists

The fft grounding (CURRENT_TASK LATEST-62, 2026-08-14) ended at a policy, not
a machinery gap: the doc-15/16 chain natively covers FFT's middle+inner nest
once entered (bursts of 341–472 iterations, ledger to CAP=32), but
`min_trip_entry = 24` (interp.zig back-edge epilogue) declines entry whenever
*this one instance* has fewer than 24 remaining trips. FFT's last five stages
have trips 16/8/4/2/1 — the chain never gets its first entry, `:131` is capped
at 37.8% traced, ~73% of the run stays tier-0. The `min_trip_entry = 0`
experiment: fft **535 → 351.5 ms (−34%)**, `:131` → 78% traced, full board
28/28 ok, everything else in noise.

The trip gate is a *symptom*: it exists because our tier-0 → native entry
pays a per-back-edge **discovery and selection cascade** — hot-count probe,
`counters` hashmap, trip computation, gate probe, same-anchor trial walk with
fingerprint matching — before any native cycle runs. LuaJIT has **no trip
gate anywhere** because it pays that cascade zero times per entry:
`trace_stop` (lj_trace.c:509–526) patches the loop's own bytecode
(`BC_FORL → BC_JFORL`, trace number in operand D), so *finding and selecting*
the trace is the interpreter's ordinary opcode dispatch. To be precise (§R1
finding 10): LuaJIT still executes the loop increment/test and the JIT
dispatch on every entry — patching eliminates repeated **discovery/selection**,
not all entry work. That is also exactly what it eliminates for us; lune's
per-entry seeding/observation/ledger work remains and is specified below.

Bart's ruling: options A (drop the constant) and B (conditional bypass) are
interim compensators this mechanism overwrites — build C directly. Per Rule
Z-6 this is the general fix: every loop with a qualified trace gets
discovery-free entry, whatever its trip distribution; fft is the instrument.

## LuaJIT ground truth

- **Patch at trace_stop** (lj_trace.c:509–526): `BC_FORL` op-swapped to
  `BC_JFORL`, trace number in operand D; the matching `BC_FORI` patched to
  `BC_JFORI` so a fresh instance's first iteration enters too. Root traces
  chain off the proto (`pt->trace`) for flush.
- **`BC_JFORL` arm** (vm_x64.dasc:4443): the *exact* FORL increment/bound
  semantics (`vk` path), then the continue direction dispatches into mcode.
- **Unpatch** (`trace_unpatch`, lj_trace.c:203–232): restores `startins` on
  flush; asserts the patch references the trace it unbinds.
- **Thrash brake**: penalty cache + blacklisting (lj_trace.c:377–403).

**Divergence we get for free:** no `JFORI` analogue needed. lune's `for_prep`
jumps forward *to* `for_loop`, whose back-edge to the body start runs on
every iteration **including the first** — one patch point covers trip-1
instances (exactly fft's late stages).

## Mechanism (copy-on-patch images)

### The load-bearing correction from §R1: canonical bytecode is shared and must stay virgin

Round 1 proposed patching `Proto.code` in place. That is unsound three ways
(§R1-1..3): (a) `Proto` is host-owned and shared — a second VM over the same
proto (the wasm visualiser does exactly this: traced run, then a fresh tier-0
VM for the replay index, wasm_entry.zig:663) would meet another VM's patch;
the **static root proto is not recompiled on restore** (only loaded chunks
are, keyframeser.zig:467), so a restored VM would meet a stale patch with an
empty registry; and the visualiser disassembles the proto, leaking tiering
state. (b) A dozen shape predicates treat `proto.code[pc].op == .for_loop` as
semantic metadata — loop-done guard classification (trace.zig:1226,
nativegen.zig:3840), `recForPrepLink`'s matching-loop validation
(trace.zig:12083), continuation arming, composite proofs — and would all
misfire on `.jfor_loop`. (c) The recorder mirrors the *fetched* instruction
(`nextOp`, interp.zig:1945), so a recording crossing a patched loop would
record `.jfor_loop` IR.

**Resolution — copy-on-patch VM-local code images.** Canonical `Proto.code`
stays `[]const Instr` and is **never mutated by anything, ever**. The first
patch installed into a proto clones its code into a VM-owned image
(`vm.trace.code_images: proto → []Instr`); patches mutate only the image.

- **Who reads the image: the dispatch fetch alone.** Each `execImpl`
  invocation resolves `code = image orelse proto.code` at frame entry, and
  **re-resolves it whenever `vm.trace.image_gen` differs from the generation
  it cached** — checked only in the back-edge epilogue (the slow path), never
  per instruction. `image_gen` is a monotone `u64` bumped by every image
  create/publish (§R3-4: `u64` so wrap-aliasing against a long-suspended
  invocation's cached generation is structurally unreachable — `2^64`
  publications do not happen; no wrap protocol needed). This closes both §R2-1 staleness shapes: the install drain
  bumps the generation and the *current* invocation reloads before its next
  back-edge; an **outer invocation suspended on the Zig stack** (nested
  `execWith` created an image for its proto) self-heals at its own next
  back-edge epilogue — until then it runs canonical code, which is merely a
  missed optimization, never an error. Call, return-into-frame, restore, and
  mode-switch paths reconstruct the local anyway. One map probe per *call*
  plus one `u64` compare per back-edge (the frame's cached generation is
  `u64` too — §R4-3); an unpatched program never allocates
  an image and probes an empty map.
- **Who reads canonical: everyone else.** The recorder (`recordInstr` is
  handed the canonical instruction — see §Mid-recording), every
  `proto.code[pc].op` shape predicate, the visualiser/disassembler, keyframe
  machinery. §R1-2 and the recorder half of §R1-3 dissolve: those readers
  cannot observe a patch by construction.
- **Restore / second VM**: images live in the VM; a fresh or restored VM has
  none and runs canonical code until its own traces qualify. The §R1-1
  static-root-not-recompiled fact becomes harmless — canonical code was never
  touched.
- **Image lifetime is epoch-stable (§R2-2).** Images are freed ONLY at the
  `beginTopLevelEpoch` drain (after its `depth == 0` guard) and VM deinit —
  never when their last patch is removed. Unpatching restores the
  instruction's canonical content in place; a live frame (or a lower
  `execImpl` invocation across native reentry) holding the image slice keeps
  a valid, canonical-identical array. No use-after-free is reachable by
  construction.
- Cost: one code-array clone per patched proto per VM (a few KB, VM gpa,
  freed at epoch/deinit). Accepted; the alternative (per-back-edge overlay
  lookup) reinstates the cost this design removes.

### The opcode

`OpCode.jfor_loop`, written **into the image** over a qualified anchor's
`.for_loop`. `.a`/`.aux` preserved verbatim; `.b` (unused by `.for_loop`)
carries the patch-slot index into `vm.trace.entry_patches` — one array index
in the arm, no hash (resolves round-1 Open Q1).

### The registry slot (`EntryPatch`)

- `trace: *Trace` — the bound root (native-supported, proven — see Qualify).
  Valid to dereference **only while `live` is set** (§R7-2): `removeTrace`
  clears `live` (via the trace's `entry_slot` back-reference) *before*
  `t.destroy` frees the allocation (trace.zig:~10050), so a live slot's
  pointer is always valid and a dead slot's pointer is never followed.
- `trace_id: u32` — the bound root's non-reused id, for drain-time identity
  (§R7-2). The drain never dereferences `trace`: it resolves
  `traceById(trace_id)` (trace.zig:3322 — the id slot is nulled on removal),
  and `null` means the trace is already destroyed — restore/tombstone
  proceed without touching trace state, and the entry-patch state transition
  is moot (the trace is dropped).
- `plan: EntryPlan` — the **structural** half of seeding memoized at patch
  time: the input-slot → seed-source map `seedTraceInputs` re-derives today,
  plus the scratch-size high-water mark. Per §R1-4/6 the plan is *not* claimed
  total: seed **values** are re-resolved every entry (upvalue/global reads;
  `hash_cell` state), scratch is borrowed per entry, and the fail-closed
  checks (seed decline, slab capacity vs the *current* frame base) remain in
  `enterSelectedTrace` — a decline falls through to the interpreter body with
  a strike, it never crashes and never needs a static totality predicate.
- `orig: Instr` — the canonical `.for_loop`, restored on unpatch (and debug-
  asserted identical to `proto.code[pc]`, which is the ground truth anyway).
- `proto + pc` — unpatch assertions (`trace_unpatch`'s identity check, kept).
- `live: bool` — cleared by any unpatch mark; inspected by the arm *before*
  the post-return drain, never after (§R2-4, §R7-1).

The `Trace` side carries `entry_slot: ?u16` — the back-reference that lets
`removeTrace` mark the slot (clear `live`, set pending) in O(1) **before**
destruction, and lets qualification assert a trace never binds two slots.

**Slot storage semantics (§R2-6).** `.b` indices are persistent references
baked into image instructions, so the registry is a **stable-address
free-list**: slots are tombstoned on unpatch and reused via the free-list;
never `swapRemove`, never compacted, and backing storage never reallocates
while any arm can hold a slot pointer (segmented/stable-pointer storage).
Publication order: initialize the slot completely, THEN write the image
opcode; unpatch order: restore the opcode, THEN tombstone; reclamation
(free-list push) is deferred to the safe-point drain (§R2-4) — except in the
arm's defensive step-1 transaction, which is outside any grammar and may
reclaim synchronously (§R6-1). Index exhaustion past `maxInt(u16)` fails
closed — the trace goes `.suppressed_capacity` and waits for any tombstone
(§R6-2).

### `enterSelectedTrace` — the single factored entry/receipt routine (§R1-4)

Phase 0a extracts today's trial-walk body into one routine used by **both**
callers (the walk, then the arm). Its contract is the *complete* current
behaviour, per-entry, none of it memoized:

seed-value resolution against the plan's structural map (fail-closed) →
scratch borrow (`valuesScratch`) → coverage brackets (`last_hop_tsc` /
`last_event_tsc` deferred restamp) → `safe_to_arm` derived from live
`suspend_ctl` / `record_safepoint_lines` → `disarmAllLinks` when unsafe →
`tryArmSiblingHandoff` → `prepareNativeEntry` → `run…Capturing` with
`ledger_scratch` + `silentStaging()` → the full result grammar:
`driveDispatcherSilentResult` and every consumer — scalar and multi-row
receipts, `resume_pc`, `consumeSideTraceWantAtResume`, dead-trace
retirement, `drainProvenanceArms`, and the `.switch_mode` return for the
suspend path. Nothing on this list is "implicitly unchanged"; the refactor
moves it verbatim and the matrix pins it before any patch exists.

What patched entry skips is exactly and only the **discovery/selection
prefix**: hot-count probe, `counters` hashmap, trip computation, `isGated`,
`nextTraceExcluding` walk, `matchesFingerprint` pre-check. (The native
prologue's fail-closed type check subsumes the fingerprint's job at entry,
per the B-4 discipline.)

### The dispatch arm

`.jfor_loop` in `Vm.exec`. The §R2-3 discipline governs every step: the
shared `for_loop` step helper executes **exactly once** per dynamic
execution of this instruction, and every taken back-edge — patched or
bypassed — reaches the **ordinary back-edge epilogue carrying the canonical
`.for_loop` instruction** (`patch.orig`), so the epilogue's own
`instr.op == .for_loop` reads (remaining-trips computation, interp.zig:2694 —
§R2-5) and the recorder mirror behave identically to virgin code. There is
no "jump straight to the body" shortcut and no rewind/refetch.

1. **Defensive pre-step check (§R6-1).** With same-turn draining (§R5-1) and
   strike exhaustion converted to a same-turn mark (step 6), a `.jfor_loop`
   dispatch should never observe `!patch.live` — the drain restores the
   opcode in the same turn the mark is made. If it happens anyway (debug
   assert), the arm performs the **complete unpatch transaction
   synchronously**: restore `orig`, tombstone, run the state transitions
   and `.suppressed_incumbent`/`.suppressed_capacity` wakes, push the
   free-list — safe here because the arm is outside any receipt grammar and
   is the only slot-pointer holder — then continues as the virgin
   `.for_loop` arm: the step below runs once and the taken edge lands in
   today's full cascade (`onBackEdge` consuming `wants_side_trace`, gate
   accounting, sibling walk, retirement). The cold path *is* the existing
   cascade, reached by unpatching before the step — never after it (§R2-3's
   double-increment hazard).
2. Execute the **shared** `for_loop` step/publish/branch helper. Guest state
   is byte-identical to tier-0 in every case, both directions.
3. Loop-exit direction → fall through exactly as `.for_loop`. Done.
4. **Bypass check — live authoritative fields, no maintained flag (§R1-5):**
   if `isRecording()` or `suspend_ctl != null` or `record_safepoint_lines`
   or `config.record_exec_log` or `pending_exit_anchor != null` or
   `pending_replay_anchor != null` or `config.coverage` — the `runFastPath`
   `.full` set (interp.zig:1838) plus coverage (§Coverage) — take the
   back-edge through the **ordinary epilogue with `patch.orig`** as the
   presented instruction: recording, coverage attribution, `onBackEdge`,
   and trace closure all see virgin `.for_loop` behaviour. The patch is
   semantically transparent under every observation/pending window; a
   pending continuation replay reaches its post-loop anchor through plain
   tier-0 (the §R1-5 starvation hazard).
5. Otherwise call `enterSelectedTrace(patch.trace, patch.plan)`.
6. **After return — one strict order (§R2-4, §R5-1, §R7-1):**
   `enterSelectedTrace` runs the full receipt grammar, inside which
   `noteTakenExit` (trace.zig:7765) can set `wants_side_trace`, gating can
   fire, and dead-trace retirement can remove the bound trace. All of those
   are **pending-unpatch marks** mid-grammar (clear `live`; never reentrant
   restores/frees inside the grammar). The arm then proceeds in exactly this
   order, with **no slot access after the drain**:
   1. **Inspect the held slot** (pointer still valid pre-drain by §R2-6
      stable storage): if `!patch.live`, the binding died mid-grammar —
      record no strike. Otherwise, on a live non-productive outcome (seed
      decline, prologue fail-closed, zero-progress exit) take a strike —
      and if it reaches `patch_strikes`, mark pending unpatch right here
      (§R6-1); productive outcomes clear strikes.
   2. **Drain** (the caller-owned epilogue's guaranteed same-turn drain —
      §Safe-point-drain): restores, tombstones, transitions, wakes, and
      free-list pushes for the entire pending set. Because unpatches push to
      the free-list before installs run, the held slot may be **reused for a
      different patch by the time the drain returns** (§R7-1 ABA) — which is
      why:
   3. **Never touch the held slot pointer again.** Everything the arm needed
      it read in sub-step 1. Then act on the directive (resume pc /
      switch-mode / fall-through).
   No unpatch work ever waits for a next execution of the patched
   instruction — which may never come (the loop can exit on this very
   iteration: the back-edge block is guarded by `pc <= cur_pc`,
   interp.zig:2649, so an exiting `for_loop` never revisits it).

`wants_side_trace` wanting a side at a patched anchor therefore resolves as:
the want site marks the slot's pending unpatch (it cannot free anything —
§R2-4), the same-turn epilogue drain restores `orig` (§R5-1), and the very
next execution of the now-virgin `.for_loop` runs `onBackEdge`, which arms
the side recording; the side's own qualify re-patches.

### Qualify — install in the receipt-accounting funnel (§R1-7)

"First productive receipt" is defined precisely: in the one accounting funnel
every receipt grammar already passes through (`accountTraceRun`,
trace.zig:4839), a root trace `T` qualifies when **its own
`local_completed ≥ min_useful` in a single receipt** — the selected root's own
work, never a fused child's cumulative count (the §R1-7 zero-work-wrapper
hazard) — and, per §R3-2, `config.native_codegen` is on and **`T.native ==
.compiled` by tag inspection only**. The funnel never calls `nativeFor`:
`nativeFor` compiles lazily on `.unattempted` (trace.zig:10225 — it is not a
predicate), and `accountTraceRun` is shared with tier-1a and synthetic
accounting paths (trace.zig:3382/3413/3505) including modes where native
codegen is off — invoking it there would allocate machine code from the
accounting funnel and mark patches in non-native modes. A `.compiled` tag
means the walk already compiled and productively ran `T`, which is exactly
the qualification event anyway.

**Mark, don't install (§R2-7).** `accountTraceRun` can run more than once per
fused ledger walk and runs *inside* the receipt grammar — it is not a safe
point for allocation or code mutation. So qualification is split:

- `accountTraceRun` only **marks** the deterministic qualified state on the
  trace, never touching images, slots, or frame code pointers. Per §R4-2 the
  mark is not a repeatedly-set boolean but one transition in a per-trace
  **entry-patch state machine** (see below): the funnel's hot check is a
  single state compare (`entry_patch == .eligible`), taken exactly once per
  stable binding — `.bound`/`.pending`/`.suppressed_*` traces cost one
  never-taken compare per receipt and never re-enter the drain. Marking
  under `config.coverage` never happens (§Coverage).
- The **safe-point drain** (§The safe-point drain below — its siting is a
  structural obligation, not "wherever `drainProvenanceArms` happens to sit")
  performs the install: allocate/clone the image if this proto has none,
  resolve the patch pc, initialise a registry slot fully, publish the
  `.jfor_loop` opcode into the image (that write is the publication — §R2-6
  order), bump `image_gen` so the current frame reloads its `code` local
  (§R2-1), and clear the mark.
- **Patch-pc resolution fails closed.** The anchor pc is a back-edge target;
  the drain scans the proto for the `.for_loop` instruction whose taken edge
  targets it. Exactly one match → patch it. Zero or multiple matches →
  install nothing, `.pending → .suppressed_permanent`; OOM cloning the image
  / growing the registry → install nothing, `.pending → .eligible`
  (transient, §R5-2). The walk keeps working either way — a missed
  optimization, never an error.

Both the mark and the drain are pure functions of the deterministic
execution; the patch/unpatch timeline is deterministic per mode, and bytecode
images are tiering state (doc 17 §2.3c) — a no-JIT mode simply never has
images.

### The entry-patch state machine (§R4-2)

Per-trace field `entry_patch: enum { eligible, pending, bound,
suppressed_incumbent, suppressed_capacity, suppressed_permanent }`, initial
`.eligible`. Suppression is split by reason (§R5-2, §R6-2) because the arms
have different wake behaviour. Transitions (all at deterministic events):

- `.eligible → .pending` — the funnel's qualification check fires (the only
  transition `accountTraceRun` may make; a single state compare guards it,
  so a `.bound` trace's productive receipts cost one never-taken branch and
  no drain work — the steady-state overhead this design exists to remove).
- `.pending → .bound` — the drain installs after revalidation (§R4-1).
- `.pending → .eligible` — revalidation fails on a **transient** condition
  (anchor currently gated: cooldown may lift; OOM cloning the image /
  growing the registry). Re-qualification waits for the next productive
  receipt after the condition clears.
- `.pending → .suppressed_incumbent` — same-PC live incumbent (the §R3-1
  rule-2 loser). The blocking slot's identity is recorded with the state.
- `.pending → .suppressed_capacity` — `u16` slot-index exhaustion (§R6-2):
  the registry is full *now*, but tombstones restore capacity, so this is a
  capacity wait, not a permanent verdict. Woken `→ .eligible` by **any**
  slot tombstone (free-list push).
- `.pending → .suppressed_permanent` — permanent ineligibility: trace no
  longer `.compiled`, or **ambiguous patch-pc resolution** (a property of
  the bytecode, which never changes). Never woken; the trace simply keeps
  entering via the walk.
- `.bound → .eligible` — its patch is unpatched (strikes, gate, pending
  drain) while the trace itself survives; a later productive receipt may
  re-qualify (the gate cooldown is the thrash brake).
- `.suppressed_incumbent → .eligible` — **only** when the recorded blocking
  incumbent's slot is tombstoned (drained deterministically), making the
  anchor contendable again. Other tombstones wake nothing (contrast
  `.suppressed_capacity`, which any tombstone wakes).
- any state `→ (dropped)` — trace removal/retirement; a `.bound` trace's
  slot clears via the pending-unpatch path first.

`.bound` and all three `.suppressed_*` states never re-enter the drain and
never re-mark — one qualification attempt per stable binding, not per
receipt (§T15).

### The safe-point drain — siting, ordering, collisions (§R3-1/3, revalidation §R4-1)

**Siting is structural (§R3-3).** The current epilogue is not a funnel: both
`driveDispatcherSilentResult` handling (`continue :outer` at interp.zig:2879)
and the multi-row `driveDispatcherLedger` path (~interp.zig:3052) exit before
the `drainProvenanceArms` site, and both call accounting internally — a drain
parked "where `drainProvenanceArms` sits" would miss marks set on those
paths. Phase 0a therefore makes the drain siting part of the
`enterSelectedTrace` contract: the routine returns a **directive** (resume
pc / switch-mode / fall-through) to **one caller-owned epilogue**, and that
epilogue runs the drain **before acting on any directive** — before every
`continue :outer`, every `.switch_mode` return, and the ordinary
fall-through. The trial walk uses the same epilogue, so both callers drain
identically; there is no exit from a trace-execution turn that skips it.
The drain processes the **entire pending set** — every pending-unpatch mark
and every `.pending` install mark, whatever anchor they belong to (§R6-1) —
so a receipt that condemns a different anchor's patch completes that unpatch
this turn too; nothing waits on the condemned instruction executing again.
(§T12 pins same-turn mark consumption on the silent and multi-row paths.)

**Ordering and same-PC collisions (§R3-1).** Same-anchor siblings are a
supported shape (interp.zig:2717), so one drain turn can carry a pending
unpatch for `T1` and an install mark for `T2` at the same `(proto, pc)` —
or install marks for two siblings at once. The drain's contract:

1. **All pending unpatches first** — restore `orig`, tombstone, push to the
   free-list — then installs. A T1-unpatch + T2-install in one turn is
   therefore a clean unpatch-then-repatch transaction; install-first would
   let T1's later restore overwrite T2's patch.
1b. **Revalidate before every install (§R4-1).** `.pending` is a *claim made
   mid-receipt*, and the rest of the same receipt can invalidate it:
   `onSideExitReceipt` runs `accountTraceRun` first and region/legacy
   profitability after (trace.zig:3413), and region accounting can gate the
   very anchor just marked (`gateAnchor` at trace.zig:3594) or retire the
   trace. The drain — which by rule 1 has already applied this turn's
   unpatches and gates — therefore re-checks at install time: trace still
   cached (not retired), `native == .compiled`, anchor **not gated**
   (`isGated`), no pending unpatch/retirement against it. Failure routes per
   the state machine (`→ .eligible` transient, `→ .suppressed_permanent`) —
   a condemned trace is never repatched past `isGated` (§T14). Revalidation
   at the drain is the single authority; triggers don't need to hunt down
   marks (they can't — they run mid-grammar).
2. **Invariant: exactly one live slot per `(proto, patch_pc)`**, asserted at
   install. If the pc already holds a live patch (bound trace not marked for
   unpatch), the incoming `.pending` goes `.suppressed_incumbent` (recording
   the blocking slot — §R5-2) without installing —
   the incumbent wins; rebind happens only through an explicit unpatch
   (strikes, gate, retirement) followed by a later qualify, never by silent
   replacement.
3. **Sibling ties within one turn resolve deterministically**: install marks
   are drained in ascending trace-id order, so the lowest-id qualified
   sibling binds and the rest go `.suppressed_incumbent` under rule 2. Which
   sibling
   subsequently *runs* is unchanged from today for mismatched types — its
   prologue fail-closed check declines, strikes accumulate, unpatch, and the
   virgin cascade re-selects (Open Q2's rebind policy is the measured
   follow-up).

### Mid-recording (§R1-3)

Two halves, both required:

- **The recorder sees canonical.** The dispatch loop hands `recordInstr` the
  canonical `proto.code[pc]` instruction (the recorder is the slow path; one
  extra indexed load per recorded instruction is noise). A recording crossing
  a patched loop therefore records `.for_loop` IR, and every
  `recForPrepLink`-style shape check reads canonical — byte-identical
  recording behaviour with or without a patch installed.
- **The arm never enters native while recording** — `isRecording()` is in the
  step-4 bypass set, so tier-0 executes the loop and the recorder's
  close-at-back-edge discipline is untouched.

### Unpatch triggers (every one wired in Phase 0b, asserted by §T)

Every trigger below **marks pending unpatch** (clear `patch.live`); the
restore-and-tombstone happens at the caller-owned safe-point drain — the
same drain that installs (§R2-4: triggers fire inside the receipt grammar or
inside `enterSelectedTrace`, where mutating the image under a live arm or
freeing the slot the arm holds a pointer to would be reentrant UAF). Timing
is unambiguous (§R5-1, completed by §R6-1): **every mark drains same-turn.**
Marks raised inside `enterSelectedTrace` — and the arm's own
strike-exhaustion mark, made immediately after it returns — drain at the
caller-owned epilogue before its directive is acted on, and the drain
processes the **entire pending set**, not just the current anchor's slot
(so a receipt that condemns a *different* anchor's patch also completes that
unpatch this turn). No unpatch transaction ever waits for the patched
instruction's next execution, which may never come (loop exit skips the
back-edge block via `pc <= cur_pc`, interp.zig:2649; a gated cold anchor
reaches only `afterBackEdge`). The arm's step-1 self-unpatch is a
**defensive assert-and-recover path**, not a load-bearing mechanism
(§R6-1).

| trigger | today's analogue | action |
|---|---|---|
| trace removed (widen-eviction, `removeTrace`) | dead-walk retire | clear `live` via `entry_slot` back-ref BEFORE `t.destroy` (§R7-2); drain restores `orig` + tombstones via `traceById`, never the dead pointer |
| anchor gated (low-yield penalty #69/#73) | `isGated` decline | mark pending + gate; warming re-decides after cooldown |
| slot strikes exhausted | fingerprint-miss walk skip | arm marks pending post-return (§R6-1); same-turn drain completes → next execution is virgin cascade (Open Q2: rebind later) |
| `wants_side_trace` at a patched anchor | side-arm in `onBackEdge` | mark pending; same-turn epilogue drain restores (§R5-1), virgin `onBackEdge` arms the side next execution |
| `beginTopLevelEpoch` depth==0 drain | H-2 part (3) | drain registry, free images (§R2-2: the ONLY image-free point besides deinit) |
| VM deinit | — | registry + images freed with the cache |

The low-yield gate machine is the thrash brake — the role `min_trip_entry`
was standing in for (the experiment demonstrated sufficiency on the full
board; LuaJIT's penalty/blacklist plays the same role). An image whose last
patch is removed is **not** freed (§R2-2 epoch-stable lifetime): unpatch
restores canonical content in place, so a frame still executing from the
image runs byte-identical-to-canonical code until the epoch drain reclaims
it — no UAF window exists by construction.

### Coverage (§R1-9, resolves round-1 Open Q3)

`--jit-coverage` runs make tiering *measurements*; the back-edge epilogue is
where interpreted-iteration attribution happens (`noteInterpIter`) and the
trace bracket timestamps live. Patched entry is **disabled under coverage**:
`config.coverage` is in the step-4 bypass set AND qualification never
installs patches while coverage is on. Coverage therefore measures the
unpatched machine — the same fidelity caveat `--jit-stats --help` already
carries (coverage perturbs timing; use plain runs for wall-clock). Not an
open question anymore: this is the mechanism.

## Determinism & replay

- **Guest semantics**: `.jfor_loop` step semantics are the shared `for_loop`
  helper; entry reaches the identical `enterSelectedTrace` machinery as the
  walk. The effect/safepoint timeline argument is unchanged from doc 16/17.
- **Canonical code is immutable** — the strongest possible form of "patches
  are not guest-observable": every semantic reader (recorder, predicates,
  serializer, visualiser) reads bytes that cannot change.
- **Mode invariance**: images are per-VM tiering state, exactly like armed
  exit slots; never serialized, never hashed into anything mode-invariant.
- **Keyframes**: keyframes store sources; loaded chunks recompile (doc 19)
  and the static root proto is reused *canonical and virgin* — a restored VM
  starts image-free and re-patches on its own deterministic schedule. Frame
  pcs serialize proto-relative and are image-agnostic (image and canonical
  are index-identical arrays). The v8 zero-allocation recompile check is
  untouched (images/slots are VM-gpa allocations, not heap objects).
- **Replay determinism per mode**: every patch/unpatch trigger is a pure
  function of deterministic events (receipt contents, gate ticks, commit
  order) — the doc 17 arm/disarm argument, one more slot kind.

## §P — measurement protocol

Frozen before Phase 1. Reps 5 via `just bench`, plus:

- **P.1** scimark-fft ≤ 360 ms (the experiment floor; worse means the arm
  pays costs the gate-lift experiment did not).
- **P.2** board flat: no program regresses > 3% vs the pre-flip board.
- **P.3** `--jit-stats` on fft (unpatched machine, see §Coverage — this
  measures the *coverage* effect of removing the trip gate, which the
  experiment already showed: `:131` ≥ 78% traced); wall-clock deltas come
  from P.1/P.2 plain runs.
- **P.4** nsieve/sieve_int/nsieve-bit unchanged (no B-3 frozen-region
  interaction).
- **P.5** hashgate + full 10-mode `zig build test` matrix at every phase.
- **P.0** (Phase 0a gate) the `enterSelectedTrace` refactor alone is
  performance-neutral: full board within noise before any patching lands.

## §T — test matrix

1. Patched loop: 10-mode byte-identical output on an fft-shaped triple nest
   (short-trip late stages included) and a trip-1-only loop.
2. Prologue fail-closed / seed decline: type-unstable loop — patched entry
   falls through with coherent regs; strikes accumulate; on exhaustion the
   same-turn drain restores `orig` (§R6-1); the post-unpatch virgin path
   arms the sibling walk (output byte-identical throughout).
3. Unpatch triggers: widen-eviction marks pending and the drain restores
   `orig` + tombstones; gate unpatches; epoch clear drains registry + images
   (asserted empty); `wants_side_trace` at a patched anchor unpatches via
   the pending path and the side trace records.
4. Observation windows: suspend / safepoint-line / exec-log / coverage runs
   with a patched loop byte-identical to unpatched (live-field bypass); a
   pending continuation replay reaches its post-loop anchor (the §R1-5
   starvation shape).
5. Mid-recording: a continuation/side recording crossing a patched inner
   `for_loop` records canonical `.for_loop` IR (compare against the
   unpatched recording of the same program — identical trace bytes).
6. Keyframe: snapshot mid-flight with patches installed → restore → resume:
   output equivalence; restored VM starts image-free and re-patches
   (registry non-empty after warm-up) — doc 19 §T3 shape. Second-VM-same-
   proto (the wasm shape): both VMs correct, images independent.
7. Warming untouched: a gated / native-unsupported anchor never patches;
   an unpatched run never allocates an image (registry map stays empty).
8. Generation reload (§R2-1): qualification fires while the loop's frame is
   live (single-invocation hot loop) → the frame's next back-edge epilogue
   observes the `image_gen` bump, reloads `code`, and the patched arm runs
   (assert via jit-debug receipt: entry via `.jfor_loop`, not the walk).
9. No double-step (§R2-3/5): a counting loop over a patched anchor — with
   strikes exhausting mid-run and with the bypass set toggling mid-run —
   produces the exact iteration count and control variable sequence of the
   virgin loop (the step helper ran exactly once per dynamic execution, and
   the epilogue's remaining-trips computation saw `.for_loop`).
10. Reentrant unpatch (§R2-4/§R5-1/§R7-1): a hotexit inside
    `enterSelectedTrace` sets `wants_side_trace` for the entered anchor
    itself → no free/restore happens mid-grammar; the arm observes `!live`
    **pre-drain** and records no strike; then the same-turn epilogue drain
    restores `orig` and tombstones before the directive is acted on; the
    next execution runs virgin `.for_loop` (`onBackEdge` arms the side) —
    no UAF under `std.testing.allocator`, and no condemned patch survives
    the turn.
11. Same-PC collisions (§R3-1): two same-anchor siblings qualifying in one
    drain turn → exactly one live slot (lowest trace-id), the other mark
    cleared, output byte-identical; a pending unpatch for T1 + install mark
    for T2 in the same turn → unpatch drains first, T2's patch survives and
    its unpatch identity assertion holds.
12. Drain totality (§R3-3): qualification reached through the silent-result
    path and through the multi-row ledger path both consume the mark
    same-turn (registry non-empty before the next back-edge; assert via
    jit-debug receipt), despite those paths' early `continue :outer` exits.
13. Mode hygiene (§R3-2): a run with native codegen disabled (tier-1a mode)
    never marks, never compiles from the accounting funnel, never allocates
    an image — byte-identical to today.
14. Mark invalidation (§R4-1): a receipt whose `accountTraceRun` qualifies a
    trace and whose region accounting then gates that same anchor
    (`gateAnchor` later in `onSideExitReceipt`) → the drain revalidates and
    installs nothing; no patched entry ever bypasses `isGated`.
15. One attempt per binding (§R4-2): a long-running patched loop — assert
    (jit-debug counters) exactly one install per stable binding; `.bound`
    receipts make no state store and no drain entry; a `.suppressed_incumbent`
    sibling never re-marks until *its recorded* incumbent slot is tombstoned,
    after which it may bind; a `.suppressed_permanent` trace never wakes
    (assert: an unrelated tombstone wakes nothing).
16. Terminal-iteration unpatch (§R6-1): strike exhaustion (and separately, a
    `wants_side_trace` mark) on the loop's **final** iteration — the loop
    exits and the patched instruction never executes again — yet the
    same-turn drain completes the full transaction: opcode restored, slot
    tombstoned, `.bound → .eligible`, recorded-incumbent siblings woken; the
    registry holds no live slot for the anchor afterward (asserted).
17. Capacity wait (§R6-2): registry at `maxInt(u16)` → new qualifier goes
    `.suppressed_capacity`, installs nothing; any slot tombstone wakes it
    `→ .eligible`, and the next productive receipt binds it.
18. Retirement + same-drain reuse (§R7-1/2): (a) the bound trace is retired
    mid-grammar (`removeTrace` → `t.destroy`) → the arm records no strike,
    the drain restores/tombstones via `traceById` (null = dropped) without
    dereferencing the dead pointer — no UAF under `std.testing.allocator`;
    (b) the same drain turn tombstones the arm's slot AND installs a new
    patch that reuses that slot index → the arm (which read everything
    pre-drain) misbehaves in no way, and the new binding's slot state is
    exactly its own (the ABA shape).

## §R1 — Design review round 1 (codex gpt-5.6-sol, 2026-08-14): REVISE → folded

Ten findings: 5 BLOCKER, 4 MAJOR, 1 MINOR. All folded into round 2 above:
(1) shared `Proto.code` / wasm second VM / static root not recompiled →
copy-on-patch VM images, canonical immutable; (2) `.for_loop` shape
predicates → canonical-only readers by construction; (3) recorder mirrors
fetched instr + no `isRecording` check → recorder reads canonical + recording
in the bypass set; (4) per-entry work not memoizable + receipt grammar
consumers dropped → `enterSelectedTrace` factored routine (Phase 0a) used by
both callers, plan holds only structural map + scratch hint; (5) bypass set
incomplete (`pending_exit/replay_anchor`, `isRecording`) + stale-flag hazard
→ live authoritative field reads, `runFastPath`'s `.full` set + coverage;
(6) EntryPlan totality unprovable → fail-closed per-entry checks retained,
no totality claim; (7) "first productive receipt" ambiguous across receipt
grammars → the root's own `local_completed ≥ min_useful` in the
`accountTraceRun` funnel; (8) `onBackEdge` lifecycle work (side-trace
consumption, sibling walk, retirement) lost → cold path = unpatch + virgin
cascade, `wants_side_trace` unpatches immediately; (9) coverage attribution
silently lost → patched entry disabled under coverage, resolved as mechanism;
(10) "free entry" overstated → narrowed to discovery/selection elimination.

## §R2 — Design review round 2 (codex gpt-5.6-sol, 2026-08-14): REVISE → folded

Seven findings: 4 BLOCKER, 2 MAJOR, 1 MINOR. All folded into round 3 above:

- **R2-1 (BLOCKER)** — the live frame's cached `code` local predates image
  creation, so a single-invocation hot loop would never see its patch (and a
  frame could keep running a *freed* image). Fold: `vm.trace.image_gen`
  monotone generation counter bumped on every image create/publish; the
  back-edge epilogue re-resolves `code` when its cached generation differs
  (§Mechanism image-resolution bullet, §T8).
- **R2-2 (BLOCKER)** — freeing an image on last-unpatch is a UAF against any
  frame still executing from it. Fold: epoch-stable image lifetime — images
  are freed ONLY at the `beginTopLevelEpoch` depth==0 drain or VM deinit;
  unpatch restores canonical content in place (§Mechanism image-lifetime
  bullet, unpatch-triggers table).
- **R2-3 (BLOCKER)** — the round-2 arm could double-execute the shared
  `for_loop` step (strike-exhaustion unpatch after the step, then virgin
  re-run) and its bypass "jump to body" skipped the back-edge epilogue
  entirely. Fold: strike/live checks run BEFORE the step; the step executes
  exactly once; bypass and cold paths route through the ordinary epilogue
  (§Dispatch-arm rewrite, §T9).
- **R2-4 (BLOCKER)** — unpatch triggers fire *inside* `enterSelectedTrace`
  (`wants_side_trace` in `noteTakenExit`, gating, retirement): a synchronous
  restore/free there is reentrant mutation under a live arm. Fold: all
  triggers mark pending (`live = false`); restores/tombstones drain at the
  dispatch safe point; the arm re-checks `live` after return (§Dispatch-arm
  step 6, unpatch-triggers preamble, §T10).
- **R2-5 (MAJOR)** — the epilogue itself reads `instr.op == .for_loop` for
  the remaining-trips computation (interp.zig:2694); presenting `.jfor_loop`
  there corrupts trip accounting. Fold: every epilogue entry from the
  patched arm carries the canonical `patch.orig` instruction (§Dispatch-arm
  preamble).
- **R2-6 (MAJOR)** — `.b` slot indices baked into image instructions make
  the registry a persistent reference space: swapRemove/compaction/
  reallocation invalidate live arms. Fold: stable-address free-list with
  tombstones, publication order (init slot fully, then write opcode),
  unpatch order (restore opcode, then tombstone), deferred reclamation,
  `maxInt(u16)` exhaustion fails closed (§Mechanism slot-storage paragraph).
- **R2-7 (MINOR)** — `accountTraceRun` runs multiple times per fused ledger
  walk and inside the receipt grammar; installing there allocates/mutates at
  a non-safe-point. Fold: mark-don't-install split — the funnel only marks
  `wants_entry_patch`; the dispatch-owned safe-point drain installs in
  stable order and fails closed on OOM/ambiguous patch-pc (§Qualify
  rewrite).

## §R3 — Design review round 3 (codex gpt-5.6-sol, 2026-08-14): REVISE → folded

Four findings: 1 BLOCKER, 2 MAJOR, 1 MINOR. All folded into round 4 above:

- **R3-1 (BLOCKER)** — the drain had no ordering or same-PC collision rule;
  same-anchor siblings (interp.zig:2717) can qualify together, and a
  T1-unpatch + T2-install in one turn could let T1's restore overwrite T2's
  patch, or a second install silently orphan the first slot. Fold: drain
  contract — unpatches before installs; exactly-one-live-slot-per-`(proto,
  pc)` invariant asserted at install; incumbent wins (incoming mark clears);
  sibling ties drain in ascending trace-id order (§Safe-point-drain, §T11).
- **R3-2 (MAJOR)** — `nativeFor(T) != null` as the qualification predicate
  would lazily compile from the accounting funnel (trace.zig:10225) on
  tier-1a/synthetic paths (trace.zig:3382/3413/3505), violating mark-only
  and compiling in non-native modes. Fold: qualification requires
  `config.native_codegen` and inspects `T.native == .compiled` by tag only;
  the funnel never invokes compilation (§Qualify, §T13).
- **R3-3 (MAJOR)** — "where `drainProvenanceArms` sits" is not a total
  funnel: `continue :outer` at interp.zig:2879 and the multi-row ledger path
  (~3052) exit earlier and both run accounting. Fold: drain siting made a
  structural Phase 0a obligation — `enterSelectedTrace` returns a directive;
  one caller-owned epilogue drains before acting on any directive, covering
  every exit (§Safe-point-drain, Phase 0a bullet, §T12).
- **R3-4 (MINOR)** — a `u32` `image_gen` can wrap-alias a long-suspended
  invocation's cached generation. Fold: `u64` (§Mechanism image-resolution
  bullet).

## §R4 — Design review round 4 (codex gpt-5.6-sol, 2026-08-14): REVISE → folded

Three findings: 1 BLOCKER, 1 MAJOR, 1 MINOR. All folded into round 5 above:

- **R4-1 (BLOCKER)** — install marks were never invalidated by later
  same-receipt decisions: `onSideExitReceipt` runs `accountTraceRun` first
  and region/legacy profitability after (trace.zig:3413), and region
  accounting can `gateAnchor` the just-marked anchor (trace.zig:3594) or
  retire the trace — the drain (unpatches-first) would then repatch a
  condemned trace, bypassing `isGated`. Fold: drain rule 1b — revalidate at
  install time (cached, `.compiled`, ungated, no pending unpatch/
  retirement); failure routes `.pending → .eligible` (transient) or
  `.suppressed` (permanent). Drain revalidation is the single authority —
  mid-grammar triggers never hunt marks (§Safe-point-drain 1b, §T14).
- **R4-2 (MAJOR)** — a repeatedly-set boolean mark adds a store + drain
  entry to every productive receipt of an already-bound trace, and same-PC
  losers re-mark every receipt — steady-state overhead this design exists
  to remove. Fold: per-trace `entry_patch` state machine (`eligible /
  pending / bound / suppressed`) with deterministic transitions; the funnel's
  hot check is one state compare; `.bound`/`.suppressed` never re-enter the
  drain; `.suppressed` returns to `.eligible` only when the incumbent slot
  tombstones (§Entry-patch-state-machine, §T15).
- **R4-3 (MINOR)** — "one `u32` compare" survived the `u64` change; cached
  generation type unspecified. Fold: both `u64` (§Mechanism image-resolution
  bullet).

## §R5 — Design review round 5 (codex gpt-5.6-sol, 2026-08-14): REVISE → folded

Two findings, both MAJOR. Folded into round 6 above:

- **R5-1 (MAJOR)** — pending-unpatch timing was internally contradictory:
  the unified epilogue drains before acting on any directive, yet the arm
  text and §T10 had the restore waiting for the patch's *next* execution.
  Fold: marks raised inside `enterSelectedTrace` always drain **same-turn**
  at the caller-owned epilogue (a condemned patch never survives the turn);
  step-1 self-unpatch is only the fallback for strike exhaustion and marks
  produced outside the routine. Arm step 6, the `wants_side_trace`
  resolution, the trigger-table preamble/rows, and §T10 all restated.
- **R5-2 (MAJOR)** — `.suppressed` conflated collision suppression with
  permanent ineligibility: an incumbent tombstone would wake permanently
  ineligible traces, and patch-pc ambiguity / `u16` exhaustion had no
  defined transition. Fold: split into `.suppressed_incumbent` (records the
  blocking slot; woken only by *that* slot's tombstone) and
  `.suppressed_permanent` (not-`.compiled`, ambiguous patch-pc, index
  exhaustion; never woken); OOM/gate-cooldown route `→ .eligible`;
  retirement drops. State machine, drain rules 1b/2/3, the patch-pc
  paragraph, and §T15 all restated.

## §R6 — Design review round 6 (codex gpt-5.6-sol, 2026-08-14): REVISE → folded

Two findings: 1 MAJOR, 1 MINOR. Folded into round 7 above:

- **R6-1 (MAJOR)** — the fallback step-1 self-unpatch had no guaranteed
  completion point: an exiting `for_loop` never revisits the back-edge block
  (`pc <= cur_pc` guard, interp.zig:2649) and a gated cold anchor reaches
  only `afterBackEdge`, so a restored-opcode-with-untombstoned-slot state
  (unresolved `.bound`, never-woken siblings) could persist to the epoch
  drain. Fold: **every** unpatch-producing event now drains same-turn —
  strike exhaustion converts to a pending mark made immediately after
  `enterSelectedTrace` returns (before the guaranteed epilogue drain), and
  the drain processes the entire pending set across all anchors. Step 1
  becomes a defensive assert-and-recover path that, if ever taken, performs
  the complete restore/tombstone/state/wake transaction synchronously (safe:
  outside any grammar, sole pointer holder). §T16 pins the
  final-iteration-strike and final-iteration-want shapes.
- **R6-2 (MINOR)** — `u16` index exhaustion is a capacity condition, not a
  permanent verdict, once tombstoned slots are reusable. Fold: new
  `.suppressed_capacity` state, woken `→ .eligible` by **any** slot
  tombstone (contrast `.suppressed_incumbent`'s targeted wake);
  `.suppressed_permanent` narrows to not-`.compiled` and ambiguous patch-pc
  (a bytecode property, immutable). §T17 pins the wait-then-bind shape.

## §R7 — Design review round 7 (codex gpt-5.6-sol, 2026-08-14): REVISE → folded

Three findings: 2 BLOCKER, 1 MINOR. Folded into round 8 above:

- **R7-1 (BLOCKER)** — the arm's post-return protocol both drained-then-
  reread and marked-before-drain (contradictory), and re-reading the held
  slot after the drain is an ABA hazard: unpatches push to the free-list
  before installs, so the slot may already carry a *different* binding.
  Fold: one strict order — return → inspect the held slot and account
  strikes / mark strike-exhaustion (pre-drain, pointer valid) → drain →
  never touch the held pointer again → act on the directive (arm step 6
  sub-steps 1–3, §T18b).
- **R7-2 (BLOCKER)** — `EntryPatch.trace: *Trace` dangles after retirement:
  `removeTrace` swap-removes, nulls `trace_by_id`, and immediately
  `t.destroy`s the allocation (trace.zig:~10047–10050; destroy frees
  `self`, trace.zig:1657). Fold: explicit protocol — the `Trace` carries an
  `entry_slot: ?u16` back-reference; `removeTrace` clears `live` + marks
  pending through it **before** destruction; the slot stores the non-reused
  `trace_id` and the drain resolves `traceById(trace_id)` (null = already
  dropped), never dereferencing the raw pointer; the arm dereferences
  `trace` only while `live` (§Registry-slot bullets, trigger-table row,
  §T18a).
- **R7-3 (MINOR)** — "both `.suppressed_*` states" survived the three-way
  split. Fold: "all three".

## §R8 — Design review round 8 (codex gpt-5.6-sol, 2026-08-14): APPROVE

One MINOR: §T10 still narrated the retired drain-before-read order. Folded
(§T10 now reads "observes `!live` pre-drain … then the drain restores").
The reviewer confirmed the §R7-2 retirement protocol against source
(trace.zig:10049 null-before-destroy, 1657 destroy frees self, 3322
`traceById`) and the capacity-wait fold. Verdict: **APPROVE**.

## References

- lj_trace.c:509–526 (`trace_stop`), 203–232 (`trace_unpatch`), 377–403
  (penalty/blacklist); vm_x64.dasc:4443 (`BC_JFORL` arm).
- interp.zig ~2650–2900 (the cascade + trial walk this factors and, for
  patched anchors, skips), 1838 (`runFastPath` `.full` set), 1945 (`nextOp`
  recorder mirror), 2717 (same-anchor siblings), 2879 + ~3052 (early
  `continue :outer` exits the §R3-3 drain siting must cover); trace.zig
  10225 (`nativeFor` lazy compile — why qualification is tag-inspection
  only), 3382/3413/3505 (tier-1a/synthetic `accountTraceRun` callers),
  config (`min_trip_entry`), 1226 + 12083 and
  nativegen.zig:3840 (canonical shape predicates); keyframeser.zig:467
  (loaded-chunk-only recompile); wasm_entry.zig:663 (second VM, same proto).
- doc 17 §2.3c (tiering state; disarm-on-unsafe), Part B/B-3 (exit patching —
  this is its entry-edge completion), §B-4 (prologue fail-closed).
- doc 19 (restore recompile precedent), CURRENT_TASK LATEST-62 (grounding +
  experiment).
