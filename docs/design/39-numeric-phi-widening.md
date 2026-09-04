# Doc 39 — Numeric φ widening via a type-stabilizing peel

Status: draft v3, not yet implemented — v1 (eager entry coercion) rejected by
codex round 1; v2 (the peel) architecture confirmed by codex round 2, which
supplied the minimum-sound-v1 constraints this revision incorporates.
Owner: Claude (fable), for Bart
Last updated: 2026-09-04

## Implementation status

Tracking the gap between this design and what's on the main branch.
Tick items as they land; move whole sections to "done" once everything
inside them is checked.

### Done

_(nothing yet)_

### Outstanding

- [ ] **Phase 0 — instability detection.** `Recorder.RegSlot` gains an
  `entry_kind` that (a) is captured CENTRALLY on every numeric-proof
  route covering a `slot_load` — `guardNum`, `guardInt`/
  `keyRefNarrowed`, bitop guards, `guard_fits` — not just when
  `guardNum` itself emits (dedup via `guarded_refs` must not skip the
  stamp), and (b) SURVIVES every whole-`RegSlot` assignment (`setReg`,
  inlined-callee seeding, return mapping — audit all writes). At the
  first anchor-return of a plain-while `.root` recording, sweep slots
  `[0, anchor_num_registers)` only (assert `inline_depth == 0`, no
  multret/call shadow open): int-entry/float-body ⇒ peel mode.
- [ ] **Phase 1 — peel recording.** A `peel_state` generation shared by
  BOTH anchor-close paths (`onBackEdge` + `maybeCloseAtAnchor`) so the
  immediate re-arrival at the anchor after the marker is one logical
  return, not a premature close. Emit the `preheader` marker inline,
  snapshot `reg_map`; lazy internal-φ creation on first body read of a
  slot iteration 1 DEFINED (invariant `.input` slots are referenced
  directly — no φ, and no false uncompilability from non-numeric
  invariants); eligibility rejects pending stores, `sgm_setpos`/cursor
  state, and allocations (`guard_gc`) — enforced over BOTH passes
  (iteration-1 effects prevent entering peel mode; a forbidden effect
  during the body pass aborts) — register-only peel in v1. Close at
  the second anchor-return (stability re-check, φ back-edge patch,
  slot-bound φ `a` = its steady-state internal φ ref as the durable
  slot↔φ association, or 0 for write-before-read slots which fall to
  the existing write-only class, writebacks from body refs);
  `AbortReason.type_instability` if still unstable (budget: one peel).
- [ ] **Phase 1b — peeled traces bypass tropt.** v1 caches peeled traces
  unoptimized (the link-trace precedent): tropt's liveness/LICM/CSE has
  no concept of a semantic marker and would drop or re-derive it. A
  marker-aware optimizer is future work.
- [ ] **Phase 2 — completion accounting + serialization.** First
  back-edge completes TWO tier-0 iterations (`Trace.peeled`); the flag
  is SEMANTIC and must be serialized — schema/trace.json version bump,
  generated Zig + TS codecs, traceser round-trip, viz exec-log
  interpretation.
- [ ] **Phase 3 — nativegen peeled shape.** `analyze` splits the
  entry-load location/tag (int, run-once) from the steady-state
  internal-φ home/kind (float, back-edge-updated) and the final
  writeback — `SlotInfo`'s single kind/home assumption is the work
  here, resolved via the slot-bound φ's `a` association; DEOPT flush
  skips carried-slot writes when `rbx == entry_rbx` (LOCAL zero
  completions — cumulative `rbx == 0` is wrong under chain entry) on
  BOTH the shared `deopt_exit` and the silent patched epilogues;
  prologue-fail ordering asserted.
- [ ] **Phase 4 — tests + gates + bench.** e2e parity all tiers on the
  fft shape; byte-identity probes (deopt before first back-edge sees
  `math.type == "integer"` at tier-0, after sees `"float"`);
  large-int (>2^53) first-iteration semantics; F1 reverse shape still
  bails; peel-ineligible shapes (pending stores / gmatch / alloc)
  decline cleanly; region/rec_path sanity on a two-traversal committed
  path (no duplicate region edges, sibling formation from both
  passes); hashgate 84/84; fft A/B + full bench sweep vs shadow
  baseline.
- [ ] **Open question — resumed-instance float sibling.** A deopt
  mid-loop re-dispatches at the anchor with float slots; the peeled
  trace's int fingerprint refuses it. The plain float-entry sibling
  that covers resumed instances should form organically via the
  existing sibling machinery — verify it does, or file the gap.
- [ ] **Defer — side/continuation recordings.** v1 scopes the peel to
  initial `.root` recordings; side traces and continuations keep
  today's behavior (their retry arming is hot-exit-driven, not
  warming-counter-driven, per codex finding 8).
- [ ] **Defer — float→int φ narrowing (the F1 reverse shape).** Entry
  float, body stores int. LuaJIT handles it with a guarded
  `CONV INT_NUM|CHECK` (per-iteration exit risk). No benchmark
  demonstrates demand; RV-3 keeps bailing it, a safe status quo.
- [ ] **Defer — multi-peel budgets.** LuaJIT's `instunroll` allows
  several stabilization iterations; v1 allows exactly one (int→float
  stabilizes in one; genuine flip-flops abort `.type_instability` and
  were uncompilable before).

## Why this exists

`fft_bitreverse` (bench/luajit/scimark_lib.lua:178–188) sits at 0%
native residency on its while anchors because the carried slots are
recorded with the wrong numeric kind:

```lua
local k = n                                    -- k is INT at record time
while k <= j do j = j - k; k = k / 2 end       -- k/2 is ALWAYS float
```

Lua `/` produces float unconditionally (`arithResultType`,
trace.zig:15784), so `k` enters int and leaves the first body float;
`j = j - k` then floats `j` too. The recorder pins the entry kind from
the runtime value at record time (`guardNum`, trace.zig:13057 —
`guard_int` because `v.isInt()`), records the body anyway, and `commit`
emits the slot φ with the *body* ref's type (trace.zig:12324) — no
comparison, no abort reason for the mismatch. The failure surfaces
downstream, three ways:

1. **RV-3 analyze bail** (nativegen.zig:3298): a `.loop` trace whose
   carried slot loads int but stores float can't compile — the hoisted
   prologue guard checks once and the home's register class (GP vs XMM)
   is fixed at analyze time. The trace runs tier-1a forever.
2. **Per-entry guard thrash**: every fresh instance enters with `k = n`
   (int), runs one iteration, and the second pass fails the `guard_int`
   on the now-float carry — one iteration per entry, forever.
3. **Anchor starvation**: the bailed siblings feed `.native_unsupported`
   gating pressure (doc 38 already taught that gate to respect compiled
   siblings because of this exact anchor family).

This is the named next technique from doc 38 / CURRENT_TASK LATEST-103.

## How LuaJIT does it — and what mahina must do differently

LuaJIT (`lj_opt_loop.c:336–372`) unrolls a second copy of the recorded
iteration in IR. When a loop-carried ref's second-iteration type differs
from the first, it patches the *copy*: iter-1 num / iter-2 int takes a
free `CONV NUM_INT`; iter-1 int / iter-2 num takes a guarded
`CONV INT_NUM|CHECK`; anything else throws `TYPEINS`, which
`lj_opt_loop.c:428–443` converts into "undo and keep recording" —
literal unrolling on a budget (`instunroll`). Note the structural fact
that makes this sound: **the peeled first iteration keeps the original
typed IR.** Iteration 1 runs int semantics exactly as recorded; only the
steady-state copy is retyped.

The v1 draft of this doc tried to skip the peel: coerce the entry value
to float once (`guard_number` + a new `float_of_num` op) and record one
homogeneous float body. Codex review rejected it, correctly: **eager
entry coercion changes first-iteration semantics.** On iteration 1,
tier-0 still computes with the int — `j = j - k` on two ints is
*integer* subtraction (wraps, produces an int `j` that `math.type` can
observe), mixed compares above 2^53 differ, and int overflow wrapping is
not float rounding. LuaJIT tolerates the corresponding flush because 5.1
has no observable int/float distinction; mahina is 5.4-shaped and holds
byte-identity across 8 modes, so a homogeneous float body cannot
represent an observable int→float transition. The doc-0 determinism
asterisk applies: adapt the mechanism, don't skip it — and the honest
adaptation is the same one LuaJIT's own fallback uses: **give iteration
1 its own typed code.**

## Design: record until the types stabilize, then close

The peel is not a clone-and-retype IR pass (mahina has no unroll pass,
and building one just to retype is surgery the replay model doesn't
want). It falls out of the recorder: **when the first anchor-return
would close a type-unstable φ, don't close — emit the `preheader`
marker and keep recording.** Iteration 2 records against the live
runtime values, which by then genuinely *are* float — `guardNum` emits
`guard_float` naturally, `recCompare` sees float/float and demotes
nothing, `keyRefNarrowed` narrows array keys on demand exactly as
designed. Nothing is ever synthetically retyped, no new IR op exists,
and every recorded guard mirrors a decision tier-0 actually made. At
the second anchor-return the carried kinds are float=float and the
trace closes.

The run-once/looping split this needs **already exists end-to-end** —
it is the Phase E1/E2 (LICM + strength reduction) machinery:

- **IR**: the `preheader` marker (trace.zig:188–202) — everything
  before it runs once per entry, everything after runs every iteration;
  `assertWellFormed` enforces the single-marker rule and keeps φs out
  of the run-once region.
- **Internal φ**: `phi` with `aux == PHI_INTERNAL` (trace.zig:163–186)
  carries `a` = init ref (a run-once value) and `b` = back-edge value.
- **tier-1a**: skips the run-once region on iterations ≥ 2
  (irinterp.zig:457–473); an internal φ takes its init on the first
  pass and retains the back-edge-carried value after
  (irinterp.zig:492–500).
- **native**: the run-once region is emitted before `loop_top` with
  once-written computed homes; internal φs get homes updated by the
  back-edge parallel move (nativegen.zig:2431–2444, 3197, 3600–3639,
  6148). E2's strength-reduction accumulator already ships internal φs
  through the *full* pipeline — this is battle-tested, not new.

What doc 39 adds is the recorder-side construction of that structure
from two live iterations, plus two accounting rules.

### Phase 0 — detection

`RegSlot` (trace.zig:15806) gains `entry_kind: enum { none, int,
float }`. Two capture rules, both from codex round 2:

- **Central capture** (finding 11): the stamp happens wherever a
  numeric proof first covers a `slot_load`-backed ref — `guardNum`,
  but equally `guardInt` via `keyRefNarrowed` (an array key like
  `a[k]` pins `k` int before any arith sees it), bitop guards, and
  `guard_fits`. And the stamp must fire even when `guarded_refs`
  dedup suppresses the guard *emission* — the proof exists either way.
- **Survival** (finding 2): `setReg` (trace.zig:13003) and every other
  whole-`RegSlot` assignment (inlined-callee seeding, return mapping)
  replace the struct today and would erase the evidence exactly when
  `k = k/2` writes the float. Every such site preserves `entry_kind`.

At the first anchor-return of an eligible recording (the close decision
in `maybeCloseAtAnchor` / `onBackEdge`, trace.zig:11974/12056 — *not*
an error out of `commit`, which `closeTrace` would misread as
`.commit_failure` and gate, trace.zig:12223), sweep the `.def` slots in
`[0, anchor_num_registers)` **only** (finding 12: `reg_map` extends
into inlined-callee scratch that commit deliberately excludes from
writeback; assert `inline_depth == 0` and no open multret/call shadow
at the boundary): any slot with `entry_kind == .int` whose current ref
has `ty == .float` (body defs are arith results and carry real types;
only `slot_load` is `.unknown`) ⇒ peel mode. All unstable slots are
visible in this one sweep — fft's `k` and `j` both — so one peel
suffices.

**Eligibility is plain-while roots** (finding 9), not every `.root`:
the numeric-for completion machinery (`flushNumericForLoopDone`,
linked-completion +1 paths, `linked_one_trip`'s exact-one semantics)
carries assumptions a peel would need a separate audit to preserve.
The anchor-shape test is the doc-38 structural classifier (a plain
backward `jmp` while anchor). And the peel is **register-only** in v1
(findings 6, 7, 13): a recording that has pending stores, gmatch
cursor state (`sgm_setpos` — deliberately deferred so the *next*
iteration reads the advanced position, which a peel would break by
running iteration 2 before the first flush: it would re-match the
first token), or allocations (`guard_gc` is emitted once with a
whole-trace bound and would sit skipped in the run-once region while
steady-state allocations run unchecked) closes as today at the first
return — unstable, tier-1a-only, exactly the status quo. **The
restriction is enforced over the entire two-pass recording** (codex
round-3): iteration-1 effects prevent *entering* peel mode; a
forbidden effect emitted during the body pass — nothing stops
iteration 2 from taking a path iteration 1 didn't — aborts the peel
(`.type_instability`, ordinary strikes). The
existing replay-idempotence proofs for inline stores were written for
one logical iteration; rather than re-litigating them per effect
class, v1 keeps effects out of the peel entirely.

The sweep only ever fires on a recording that *reached* the
anchor-return; the LLEAVE exit-first passes (trace.zig:14014) abort
before it, and the two retry mechanisms stay independent: LLEAVE
retries land a body pass, then the peel check runs on that body pass.
`.phi_widen`-style abort machinery from v1 is gone entirely — no
abort, no strike, no `unroll_fail` interaction (round-1 finding 7),
no per-anchor evidence map to scope (round-1 finding 9).

### Phase 1 — the peel recording

On entering peel mode at the first anchor-return:

1. **Enter a shared `peel_state` generation** (finding 1 — the race
   this exists to kill: after `onBackEdge` handles the back-edge, the
   interpreter's very next dispatch calls `maybeCloseAtAnchor`
   (interp.zig:2168) with the recorder active, non-empty, and at its
   anchor — which would `closeTrace` immediately, before any of
   iteration 2 records. Both close paths consult the generation so the
   marker-emitting return and its immediate anchor re-arrival are ONE
   logical return, and only the *next* arrival closes).
2. **Emit the `preheader` marker inline** — the stream is at exactly
   the iteration boundary, so no splicing and no ref remapping ever
   happens.
3. **Snapshot `reg_map`** (slot → pre-marker ref, the iteration-1
   results), bounded to the anchor window.
4. **Keep recording.** Two rules while in the body region:
   - *Lazy internal φ, carried slots only* (finding 10): the first
     body **read** of a slot that iteration 1 **defined** (`.def` in
     the snapshot) emits
     `phi(aux=PHI_INTERNAL, a=snapshot_ref, b=patched-at-close)` and
     rebinds `reg_map[slot]` to the φ ref. Every subsequent consumer
     naturally uses the φ — φ-before-use falls out of laziness, and no
     operand rewrite pass exists. Slots still `.input` (invariant
     reads — tables, strings, functions, untouched numerics) are
     referenced directly: their run-once `values[]` persist by the E1
     contract, no φ is created, and non-numeric invariants can't
     poison compilability (native internal φs admit only
     int/float/bool, nativegen.zig:2446).
   - *Body writes* rebind as today (`setReg`); no φ is created for a
     slot the body writes before reading.
5. **Close at the second anchor-return**: re-run the stability sweep
   against the marker snapshot's kinds. Stable (the int→float case
   lands float=float) ⇒ patch each internal φ's `b` to the slot's
   final body ref, emit the slot-bound writeback φs from the
   body-final refs — **with each slot-bound φ's currently-unused `a`
   set to its steady-state internal φ ref, or kept 0 for a slot with
   none** (finding 4: the committed trace otherwise carries no durable
   slot↔internal-φ association, and native slot discovery keys on
   `slot_load.aux`/`phi.aux` alone; dataflow inference is ambiguous
   under shared init refs or write-before-read bodies. The `a` field of
   a slot-bound φ is documented unused-kept-zero today, so this is a
   backward-compatible claim on it; `assertWellFormed` learns the
   invariant. A **write-before-read** slot deliberately has no internal
   φ — its body value is redefined from other φ'd inputs every
   iteration, so it has no cross-iteration dataflow of its own — and
   its `a = 0` means "no steady-state φ: treat as the existing
   write-only slot class" that the native back-edge already handles
   separately from carried homes, flush kind from the body def) — then
   commit. Still unstable ⇒ `abort(.type_instability)` — a new reason
   with ordinary strike semantics; a genuine flip-flop was
   uncompilable before and stays so (v1 budget: one peel).

**Peeled traces bypass tropt in v1** (finding 3): the optimizer's
liveness roots don't include a `preheader` marker (it synthesizes its
own during compaction from a global invariance analysis,
tropt.zig:437/666), so a recorder-emitted marker would be dropped and
the peel semantics re-derived away; CSE and guard dedup also span the
whole stream with no marker concept. Link traces already commit
unoptimized — peeled traces join them. (A marker-aware tropt is the
future-work path; note finding 17 verified the *executor-side* φ
machinery — remap, DCE roots, `b`-patching — is sound if the marker
survives, and that φs are never CSE'd or folded. The v2 aside that
tropt "may fold" a degenerate φ was wrong; a slot read but never
written in the body simply closes its φ with `b = a`, executing as a
constant carry.)

Guard dedup (`guarded_refs`) needs no change: iteration-2 refs are
fresh SSA values and earn their own guards; the iteration-1 guards in
the run-once region check exactly what tier-0's first iteration
checks.

### Phase 2 — completion accounting

The run-once region of a peeled trace IS a tier-0 iteration, unlike an
LICM preheader. Two consequences, both mechanical:

- **First back-edge counts two.** `Trace.peeled: bool`; tier-1a's
  `completed` arithmetic and the native completion counter add
  `1 + @intFromBool(peeled)` on the first back-edge, `1` after.
  Receipts (`onSideExitReceipt`, the doc-38 yield accounting) then see
  true tier-0 iteration counts with no change of their own — codex
  round 2 (finding 20) verified the accounting consumers treat
  `completed` as a count, not unit increments; the exact-one
  assumptions live in the numeric-for/link machinery the while-only
  scope excludes. **`peeled` is semantic state and is serialized**
  (finding 15): it changes execution on both tiers and the deopt
  materialization, and cannot be inferred from the marker (ordinary
  LICM'd traces carry the same marker). Schema version bump in
  schema/trace.json, generated Zig + TS codecs, traceser round-trip,
  viz exec-log interpretation.
- **Exits before the first back-edge report `completed = 0`** and
  resume at the header — tier-0 replays iteration 1 (and the partial
  iteration 2) in full int semantics. This is the byte-identity core:
  `regs[]` is untouched until the first `.loop` flush (the tier-1a
  replay-from-header invariant, irinterp.zig:12–24 — narrowly, the
  fact that register writes happen only in `flushPhiWriteback` at the
  `.loop` marker; the header's broader "no side effects" text is
  stale, per codex finding 16), so the resumed tier-0 sees the
  original ints. The redundant replay of one extra iteration is the
  price of the peel and only paid on a pre-first-back-edge exit.

### Phase 3 — nativegen

The peeled shape reaching `analyze`: entry `slot_load`s + `guard_int`s
in the run-once region, carried dataflow riding internal φs whose init
refs are run-once values, slot-bound writeback φs whose `b` refs are
body defs. Changes:

- **The entry-load / steady-home split** (finding 5 — this is the real
  Phase 3 work, not a re-keying): `SlotInfo` today carries ONE
  kind/home per slot, the load kind selects it, every `slot_load` maps
  to it, and `slot_load` is explicitly not a computed-home op
  (nativegen.zig:2885/3237/3593/3016). A peeled carried slot needs
  three distinguishable pieces: the **entry load** (int tag check +
  run-once location — the prologue keeps demanding `TAG_INT`, which is
  what fresh instances present), the **steady-state home** (the
  internal φ's float XMM home, updated by the back-edge parallel
  move — machinery E2 already exercises), and the **final writeback**
  (from the slot-bound φ). The slot-bound φ's `a` association is what
  lets `analyze` connect them without dataflow guessing. The
  `sk != lk` RV-3 bail keeps firing for *non-peeled* mismatches
  (nothing regresses; the F1 test shape still bails).
- **DEOPT flush gating on LOCAL completions** (finding 8): the skip
  predicate is `rbx == entry_rbx`, NOT `rbx == 0` — native `rbx` is
  chain-cumulative and a peeled trace entered through an armed link
  starts with `rbx > 0`; local completion is already computed as
  `result.completed - result.entry_rbx` (nativegen.zig:1035/5925).
  When local completions are zero, skip the carried-slot box writes —
  the box still holds the entry state tier-0 needs for its replay.
  Otherwise flush as today (homes hold the post-completion header
  state). This conditional is behaviorally new *only* for peeled
  traces: in a non-peeled trace the home at zero local completions
  still equals the entry value, so today's unconditional flush was a
  value-level no-op there. The skip applies identically on **every**
  ordinary-deopt materialization path — the shared `deopt_exit`
  (nativegen.zig:7159) *and* the silent patched epilogues
  (nativegen.zig:7263). The link-terminal / linked-loop-done /
  composite-bridge snapshot paths don't apply to a peeled `.loop` root
  in v1 (peel is root-scoped) but get an assert.
- **Run-once guards deopt ordinarily** (finding 19, verified): the
  hoisted entry type guards stay prologue-fail entry refusals
  (`exit_instr == maxInt`, before any body work); other iteration-1
  guards lower through normal exit labels and reach `deopt_exit` with
  zero local completions — coherent with the flush-skip above.
- **Prologue-fail ordering** (codex finding 6): all entry tag checks
  still complete before any box mutation — the run-once region writes
  homes, never boxes, so the existing contract holds; an assert pins
  it.

No `proveKinds` weakening: `guard_int` on a non-int operand still
hard-fails; the peeled body's proofs ride the ordinary typed refs
(arith results, `guard_float` on φ-fed values) that E2's internal-φ
traces already exercise.

### What happens around the peeled trace

- **Fingerprint**: the peeled trace's entry guards are iteration-1's
  `guard_int`s ⇒ `entry_guards` say int ⇒ every *fresh* instance
  (`k = n`) matches. `matchesFingerprint` needs no change (codex
  finding 17).
- **Resumed instances**: a deopt mid-loop leaves tier-0 iterating with
  float slots; its back-edge re-warms the anchor with a float entry
  state that the peeled trace refuses. The plain float-entry sibling
  that covers this shape is type-stable (float=float, no peel needed)
  and should form through the ordinary sibling machinery — tracked as
  an open question to verify rather than assumed.
- **Demotion sites are untouched.** `recCompare`'s
  `int_of_float` demotion (trace.zig:13154) and `keyRefNarrowed`
  (trace.zig:13085) keep keying on runtime values — on the peel's
  iteration 2 those values are genuinely float, so the collision the
  v1 draft tried to patch with ref-kind re-keying (and which codex
  finding 4 showed would regress the nsieve float-limit win for
  normal traces) never arises.
- **Doc-38 machinery**: no new abort in the common path means no
  `unroll_fail` / `lleave_count` cross-talk; the `.low_trip_while`
  yield gate still owns the "does running it pay" decision
  post-commit. Widening makes traces *compilable*; the gate decides
  *profitable*.

### Considered and rejected

- **Eager entry coercion (v1 of this doc).** `guard_number` + a new
  `float_of_num` op, homogeneous float body. Rejected by codex review:
  changes observable first-iteration semantics (integer arithmetic,
  `math.type`, >2^53 compares, overflow wrapping); also required a
  typed-guard lattice (`effectiveRefKind`), retry plumbing with
  doc-38 cross-talk, and per-anchor evidence with sibling-unsafe
  scope. Kept here as the record of why the peel is not optional.
- **IR-level clone-and-retype pass (LuaJIT-literal unroll).** mahina
  has no loop-peel pass; building one just to substitute types
  re-derives what recording iteration 2 gives for free, without the
  live values that make the retype decisions trivial.
- **Self-link + type-sibling decomposition.** Close the unstable root
  as a `.link` to its own anchor (RV-3's `.link` numeric exemption
  already converts at the writeback); the float steady-state sibling
  forms organically. Sound and cheap to build, but pays a per-instance
  handoff seam forever — strictly worse steady-state than the peel,
  and doc 16's correction (~600ns runtime re-entry) says seams on
  ~10-trip loops are material. Viable fallback if the peel stalls.
- **Back-edge demotion** (`int_of_float` on the stored value): exits
  every time the value goes non-integral — fft hits `k = 1 → 0.5`
  every instance. Wrong side of the narrowing philosophy
  (`lj_opt_narrow.c:22–82`): never narrow general arithmetic.

## Verification plan

- e2e: the fft_bitreverse while shape commits a peeled `.loop` root
  (marker present, internal φs for `k`/`j`), compiles native, loops;
  parity across tier-0/tier-1a/native.
- Byte-identity probes: deopt before the first back-edge ⇒ tier-0
  observes `math.type(k) == "integer"`; deopt after ⇒ `"float"`.
  A >2^53 int entry value exercising first-iteration int arithmetic.
- Completion accounting: `--jit-stats` iteration counts match tier-0
  loop counts on a peeled trace (the first back-edge counts two).
- The F1 reverse-shape test (float load / int store) still bails; a
  flip-flop shape aborts `.type_instability` with ordinary strike
  semantics (it eventually gates, as an uncompilable shape should).
- Doc-38 matrix re-run: nest parity, nsieve-bit-fp scale 12,
  fft A/B (`:9`-family anchors gaining residency is the target;
  `:55` stays yield-gated), full `just bench` vs shadow baseline,
  hashgate 84/84.

## References

- LuaJIT: `lj_opt_loop.c:336–372` (unroll + CONV patching; the peeled
  first iteration keeps original types), `lj_opt_loop.c:428–443`
  (TYPEINS → undo + keep recording), `lj_opt_narrow.c:22–82`
  (narrowing philosophy).
- mahina: trace.zig:188–202 (`preheader`), 163–186 (`phi`
  internal/slot-bound), 12324 (`commit` φ), 13057 (`guardNum`), 13154
  (`recCompare` demotion), 13085 (`keyRefNarrowed`), 15806
  (`RegSlot`), 11974/12056 (close decision), 14014 (LLEAVE);
  irinterp.zig:457–500 (preheader skip + internal φ), 12–24
  (replay-from-header); nativegen.zig:3298 (RV-3), 3600–3639 (run-once
  homes + internal φ homes), 7159/7263 (deopt flush paths), 6942
  (back-edge order).
- Codex review round 1 (2026-09-04, thread
  01a06c9e-12c8-7971-99d6-a9dfd83a36aa): findings 1–18, verdict
  "reject eager coercion; first-iteration semantics need their own
  representation" — the shape v2 adopted.
- Codex review round 2 (same thread): architecture confirmed; findings
  1–21 supplied the minimum-sound-v1 constraints this v3 incorporates
  (peel-generation close state, entry_kind capture/survival, tropt
  bypass, slot↔φ association via slot-bound φ `a`, entry/steady home
  split, register-only effect scope, `rbx == entry_rbx` flush
  predicate, while-root scope, `peeled` serialization, rec_path/region
  tests).
- docs/design/38-while-inner-linking.md; CURRENT_TASK LATEST-103;
  TODO.md "Numeric φ widening".
