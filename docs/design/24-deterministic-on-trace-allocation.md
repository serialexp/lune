# lune — deterministic on-trace allocation (builtin recording breadth, arc B)

Status: **design revised after codex review (2026-08-27) — v1 pivoted to the
allocation-budget entry guard (codex #11); continuation exits recorded as the
v2 escalation. Implementing.**
Owner: Bart
Last updated: 2026-08-27

Prerequisite reading: `23-builtin-recording-breadth.md` (arc A, and the arc-B
commitment this doc discharges), `02-determinism.md` (the mode matrix),
`03-gc-memory.md` (non-moving, safepoint-only collection), `04-snapshot-replay-
schema.md` (keyframe fields, `next_obj_id`), `21-canonical-snapshot-liveness.md`
(cross-tier snapshot byte-identity, §T-A.2), `01-trace-lifecycle.md`
(loop-header re-entry deopt and its side-effect closure), `22-pall-shape-nest-
coverage.md` §A.2 (heap-φ rooting, the `may_allocate`/`may_collect` split).

Upstream source read: `~/Projects/LuaJIT/src/lj_ffrecord.c` (string handlers),
`lj_ir.h` (`TOSTR`/`SNEW` op classes — **interned-string creation is marked
CSE-able**, "not marked as A[lloc]"), `lj_asm.c` (`asm_snew`/`asm_tostr`/
`asm_gcstep`/`asm_gc_check` — per-allocation `gcsteps` accounting, one
threshold-check-as-guard per loop iteration calling `lj_gc_step_jit`),
`lj_opt_fold.c` (`kfold_tostr_kint/knum`, BUFPUT chain folds), `lj_opt_sink.c`.

## Why this exists

Arc A stopped at the allocation line: any builtin whose result is a **new
guest-heap object** still aborts recording (`.bad_type` on the non-konst
`tostring`, `.host_barrier` on the string library). Measured demand
(`--dump-aborts` + `perf`, 2026-08-27, post-arc-A):

| bench | board | blocker | tracing headroom (perf) |
|---|---|---|---|
| scalar (4.6×) | `bad_type` pc 67 | `tostring(i)` + `#s` on the result | 37.7% dispatch + 16.8% `bType` + 10.2% `lenValue` + 3.5% `bToNumber` all fold/record once the one allocating call records — **the headline row**: everything else in its loop is already arc A |
| str_manip (5.3×) | `host_barrier` | `sub`/`upper`/`lower`/`reverse`/`rep`/`char` | 22.9% dispatch + call plumbing; the ~46% transform bodies remain as callouts |
| str_format (3.3×) | `host_barrier` | `string.format` | **only 8.6% dispatch** — 40% is the exact-decimal core (`decimal.toDigits` 26.2 + `exactDigits` 9.5) + 17% memcpy. Tracing alone caps out ~25% here; the formatter body is a separate, also-general lever. Stated up front so the board delta is read correctly. |
| str_find/match/gmatch/gsub | 2.9×/2.3×/1.4× | pattern engine | **out of scope** — pattern recording is its own arc (LuaJIT does not trace `gsub` either) |
| tbl_ops (2.3×) | `new_table` nyi | table allocation | **out of scope** — a fresh table is NOT idempotent under deopt replay (see D2); needs allocation sinking or an escape story, both deferred per doc 01 |

## The two constraints that killed the naive design

Everything in this doc exists because of two facts (constraint inventory,
2026-08-27; citations in the inventory report):

1. **Total allocation count is byte-observable.** `next_obj_id` is a
   serialized keyframe field (`keyframeser.zig:382`, schema v5/H-2 — added
   precisely so pre-cut *garbage* is accounted), and the §T-A.2 gate compares
   a pure-tier-0 final snapshot byte-for-byte against a traced+native one
   (`keyframeser_resume_test.zig:649`). An allocation tier-0 performs that a
   trace elides — or vice versa — diverges the bytes.
2. **Object ids are program-visible.** `table.ValueContext.hash` keys heap
   values by `GcHeader.id`, so an id divergence changes `pairs`/`next` order —
   real stdout, caught by the ten-leg matrix as a hard failure. Ids are
   assigned monotonically at the single `Heap.link` chokepoint
   (`gc.zig:145-150`).

Together: **the JIT modes must reproduce tier-0's allocation event stream
exactly** — same events, same order, same interleaving with collections. Not
"allocate less" (LuaJIT's licence: sink, elide, batch — Lua promises nothing
about identity) but "allocate *identically*". This is the determinism asterisk
of the LuaJIT-parity doctrine in action: Pall's mechanism (allocate on trace
via the same runtime calls, pace GC by static per-loop accounting) is adapted,
not copied — his `lj_opt_sink` and dead-allocation elimination are exactly the
parts we must NOT take.

## What makes it tractable (measured, not hoped)

- **Intern idempotency is total and free.** `Heap.intern` returns the existing
  `*String` on a hit *before* any allocation and *before* `link`
  (`gc.zig:482-492`) — a hit consumes **no id, no memory, no `object_count`**.
- **Allocation never collects in place.** `shouldCollect` is a predicate; the
  single collect site in the codebase is the tier-0 dispatch prologue
  (`interp.zig:2067`). Allocating inside a trace body is *memory-safe today* —
  nothing can sweep the fresh object mid-burst.
- **The GC is non-moving** (hard commitment, doc 03) — raw `*GcHeader` values
  in registers/spills never need relocation handling, only liveness.
- **Unreachable garbage is never serialized**, and strtab geometry (bucket
  count, chain order) is explicitly unobservable (`gc.zig:100-104`). Only
  object *identity* leaks.
- **Interned-string creation commutes with CSE** — LuaJIT marks `SNEW`/`TOSTR`
  CSE-able for the same reason; the intern table makes the op referentially
  transparent within a non-collecting window.

## D1. Scope: interned-string producers only

Arc B v1 records builtins whose only heap effect is **producing interned
strings** — the class where idempotency holds:

- **`tostr_int`** — `tostring(i)` on an observed int (scalar's blocker). The
  tier-0 body renders into a 128-byte stack buffer and calls `internValue`
  (`basic.zig:63-74`) — the callout needs `(i64, *Heap) → *GcHeader` and
  nothing else.
- **`tostr_num`** — `tostring(f)` on an observed float; same shape (`{d}`
  float rendering is allocation-free stack code).
- **`slen`** — `#s` / `string.len` on a *trace-produced or guarded* string ref:
  loads the cached `cp_len` field. (Arc A only folded the konst case; the
  codex-#7 byte/cp distinction stands: `slen` is code points, `rawlen` stays
  bytes, never one emission.)
- **The `snew` class** — `string.sub`/`reverse`/`rep`(2-arg)/`char`(1-arg):
  transform bytes into a scratch buffer, intern once. Each is a callout to the
  existing tier-0 body (str_manip's row). *(Post-review: `upper`/`lower` are
  OUT of v1 — they touch VM effect state, codex #10, see D4.)*
- *(Post-review: the format chain is demoted to the NEXT arc — see
  Non-goals. Its scratch-buffer op family faces the same arity questions
  codex #4 raised, and keeping v1 reviewable wins.)*

Excluded, with reasons: **tables and any non-interned allocation** (`new_table`,
`table.move`, `concat` building tables — not idempotent under replay; needs the
doc-01 allocation-sinking machinery and per-guard snapshots in full
generality); **the pattern engine** (find/match/gmatch/gsub — own arc);
**metamethod paths** (`__tostring` aborts as today).

## D2. The id-stream argument (why interned allocation can be replayed)

Model an execution as the sequence of *allocation events* (each `Heap.link` =
one id) interleaved with *collection events* (each sweep = a de-intern set).
The contract requires the JIT modes to produce tier-0's exact sequence.

**Lemma (non-collecting window).** Between two collection events, the id
stream is a pure function of the *program's* intern-miss sequence: an intern
hit consumes nothing, a miss consumes exactly one id, and miss-vs-hit depends
only on strtab contents, which change only by interning (monotone within the
window). So any re-execution of a program segment inside one window that
performs the same intern *calls* in the same order produces the same ids —
**re-running a partial iteration is id-neutral**: its first execution's misses
become the re-run's hits.

**Corollary (deopt replay).** Loop-header re-entry deopt stays sound for
allocating traces **iff no collection intervenes between the trace's
allocations and tier-0's re-run of the partial iteration.** The fresh strings
are unrooted at exit (nothing roots trace scratch — inventory §4/§6), so an
intervening sweep would free + de-intern them and the re-run would mint fresh
ids, diverging from a tier-0-only run (where mid-iteration values sit in regs
and survive). D3's protocol guarantees the "no intervening collection" premise
*by construction*, which keeps loop-header re-entry — and its entire existing
soundness argument — intact for every ordinary guard.

**Why order discipline matters (optimizer consequences, D4):** tier-0 executes
every allocating call, unconditionally. A trace that *elides* one (DCE of a
dead `tostring`) diverges `next_obj_id` even though the value is dead —
allocation events are effects on the id stream, not just values. Conversely
CSE of a repeated `tostr_int(x)` within an iteration is safe: tier-0's second
call is a guaranteed intern hit (the first call's result is live in a reg),
and hits are id-neutral. Hoisting is *probably* safe by the same argument
(post-warmup, the invariant string is already interned and rooted by the loop)
but is **excluded from v1** — it needs its own argument about the first burst
after a cold snapshot restore, and nothing in the demand table needs it.

## D3. The collection-boundary protocol — v1: the allocation-budget entry guard

The problem: tier-0 samples `shouldCollect` before **every** instruction; a
burst samples it never. Once traces allocate, `object_count` moves mid-burst,
and tier-0-only would collect at a *mid-iteration* dispatch point with
mid-iteration regs as roots. A loop-header exit cannot reproduce that point.

The draft solved this with a post-allocation `guard_gc` + continuation exits
(recorded below as **v2**). Codex #11 identified the simpler sound baseline,
and codex #3/#5/#6/#7 showed how much machinery the continuation design drags
in (mid-iteration flush plans interacting with sunk stores, chaining
exclusions, optimizer side-table liveness). **v1 adopts the budget guard.**

**Mechanism.** One new guard-class IR op, **`guard_gc`**, emitted **once at
the top of every allocating trace body** (before any effect of the
iteration), with the trace's static allocation bound `A` in `aux`:

```
passes  ⇔  !gc_stress
        ∧  object_count + A < next_gc        (saturating)
```

`A` = the number of allocating ops in the body (each performs at most one
`Heap.link`; helpers are audited for this — D5). If the predicate passes,
**even the worst case (every call misses) cannot make a collection due inside
this iteration**, so:

- no collection is due at any ordinary side exit → the D2 corollary's premise
  holds *by arithmetic*, and loop-header re-entry stays sound unchanged;
- tier-0-only at the same iterations sees the same `object_count` evolution
  (same callout bodies, same order) and also never crosses the threshold →
  neither mode collects during the iteration → id streams match (D2 lemma).

If the predicate fails, the trace exits **at the coherent loop header before
any effect of the iteration** — an ordinary header exit, no continuation
machinery — and tier-0 executes the boundary iterations, collecting exactly
where tier-0-only would (same logical point, same regs — see the flush rule
below). Once the collection resets `next_gc = live×2`, the headroom is fresh
and the next entry attempt passes.

**The full-write-set flush rule (codex #6).** The collector roots every
physical register below `stack_top`, not the live set. After a burst, a slot
the loop body writes but does not carry (a dead temp) holds its *pre-burst*
value, while tier-0-only would hold the *last iteration's* value — divergent
stale heap refs → divergent sweep roots → divergent de-intern sets. Arc A
never hit this because traceable loops could not produce per-iteration heap
temps; arc B introduces them. Rule: **an allocating trace's loop-close flush
writes every register slot the body writes** — loop-carried phis as today,
plus the final iteration's value for every other written slot (they are all
live in trace scratch at the loop close). Post-burst regs then equal tier-0's
regs after the same iterations exactly, for the written span; unwritten slots
are trivially equal. Root-set equivalence at every subsequent tier-0 dispatch
follows. (Gate: compare the *marked object set* after a post-burst collection
across modes, not just reg values — D9.)

**Chaining/entry discipline (codex #5, reduced).** The budget guard is an
**entry invariant**: it sits at the top of every allocating body, so any path
that enters one — root entry, side-trace chain, armed native link — re-checks
it, and a failing check falls out to tier-0 before any effect. Surgery
required: `guard_gc` failures are excluded from hot-guard accounting and
side-trace recording (a side trace anchored at a budget failure would just be
the same loop again; the correct response is tier-0 running the boundary
iterations), and link/fusion paths must not elide the target body's entry
guard. No continuation pc, no patched-exit special case.

**Observation blackout (codex #2).** A keyframe capture between an allocating
partial iteration's side exit and its tier-0 replay would serialize
`next_obj_id` with the fresh strings unreachable — the restore replays into
misses and mints different ids than the uninterrupted run. v1 rule, precedent
doc 17's armed-link blackout: **while suspension/keyframe observation is
armed, allocating traces are not entered** (the replay-to-k driver already
forces pure tier-0). The v2 alternative — a deopt nursery rooting
partial-iteration allocations until replay completes — is recorded, not
built.

**`gc_stress` (codex #1).** Under stress, tier-0 collects before every
instruction, so mid-iteration root-set changes (a `nil` write killing a
string before the allocating call) alter the de-intern history in ways no
header-exit protocol can reproduce. The `!gc_stress` conjunct in the
predicate makes allocating traces never enter under stress — the stress legs
run those loops tier-0-pure, which is trivially identical. (The draft's D8
claim that stress legs "run tier-0 under stress — slow but identical" was
wrong in mechanism — codex #1's interleaving diverges *before* the first
allocation — and is superseded by the entry-guard conjunct.)

**Parked-below-threshold honesty (codex #11's stated defect).** If
`object_count` sits within `A` of `next_gc` and the loop's calls are all
intern hits, tier-0 never crosses the threshold and the budget guard rejects
every entry — the loop runs at tier-0 speed, correct but slow. This needs
`count ∈ [next_gc − A, next_gc)` to hold with no misses ever — rare, and the
cost is the pre-arc-B status quo. Accepted for v1; the v2 escalation removes
it.

## D3v2. Recorded escalation: post-allocation checks + continuation exits

The draft design, kept for when profiling shows the budget guard's boundary
tax or parked case matters: `guard_gc` after every allocating callout
(placement is exactly equivalent to tier-0's check-before-next-dispatch —
codex #14 confirms), failing into a **planned continuation exit** (recorded
flush plan + continuation pc, resuming tier-0 mid-iteration). Its cost, per
codex: pending sunk stores must flush before every allocating callout or
abort (codex #3); the flush plan's refs need full optimizer liveness/remap
integration (codex #7); the plan must reconstruct physical — not logical —
register state (codex #6); every chaining/patched-exit path must treat the
continuation exit as unchainable (codex #5). None of that is v1.

## D4. IR, recorder, optimizer

New IR ops (wire ordinals append-only; current count 60). Codex #4 killed the
`sbuiltin` catch-all (`IrInstr` carries `a`/`b`/`aux` — a variadic operand
vector has no encoding), so per-op nodes with pinned arity:

- **`tostr_int` = 60, `tostr_num` = 61** — allocating producers, `ty = .heap`
  (a string ref). Operand `a` = the guarded int/float ref.
- **`slen` = 62** — pure producer: `cp_len` of a string ref. **`guard_string`
  = 63** pins an observed string operand when it is a loaded slot rather than
  a `tostr_*`/`snew`-class result (whose type is proven).
- **`guard_gc` = 64** — the D3 entry guard; `aux` = the allocation bound `A`
  (codex #12: one field, one meaning; no flush-plan id exists in v1).
- **`ssub` = 65** (`a` = string ref, `b` = start ref, `aux` = end ref — the
  third operand rides `aux` as a ref, pinned by `assertWellFormed`),
  **`srev` = 66** (`a`), **`schar1` = 67** (`a`; the 1-argument `string.char`
  fast shape only — variadic `char` stays a barrier), **`srep2` = 68**
  (`a` = string ref, `b` = count ref; the 2-argument shape — a separator
  aborts).
- **`upper`/`lower` are OUT of v1** (codex #10): `mapCaseUnicode` touches VM
  effect state (`noteUnicodeVersion` — effect append, `unicode_version_pinned`,
  `committed_effect_seq`), so they are not heap-only, cannot take a bare
  `*Heap`, and need their own idempotency proof across deopt replay. v2, with
  a `*Vm` channel and that proof. (Reduces str_manip's v1 win; stated so the
  board delta is read correctly.)

Recorder arms (`recBuiltin`): `tostring` non-konst int/float → `guard_builtin`
+ `guard_int`/`guard_float` + `tostr_*`; string-library arms → `guard_builtin`
+ shape guards (+ `guard_string`) + the per-op node. The recorder tracks
`alloc_count` while emitting; commit stamps it into the entry `guard_gc`.
`RecordedBuiltin` grows ordinals 11+ (append-only): `len = 11`, `sub = 12`,
`reverse = 13`, `char = 14`, `rep = 15`, and (TODO.md carry-over, fold-only,
non-allocating) `mtype = 16` for lua54's `math.type` — the arc-A `recBType`
clone rides along since the registry mechanism is identical. (`upper`/`lower`
get ordinals when v2 admits them.)

Optimizer classification (`tropt.kindOf`):

- `tostr_int`/`tostr_num`/`ssub`/`srev`/`schar1`/`srep2`: a new **`.alloc`
  kind** — side-effecting roots (**never DCE'd** — the id stream, D2),
  **never hoisted**, never reordered across each other or across `guard_gc`
  (allocation order is the id stream).
- **CSE: `tostr_int`/`tostr_num` only** (codex #8). Their repeat execution is
  a guaranteed intern *hit* — pure lookup, no scratch, cannot fail — so
  eliding it is id-neutral AND failure-neutral. The `snew`-class ops allocate
  host scratch before interning; a CSE'd second call would remove a fallible
  operation tier-0 performs (OOM divergence). No CSE for those in v1.
- `guard_gc`: `.guard` root; never deduped (one per body, placed by commit),
  never folded.
- `slen`: pure unary producer (CSE/DCE/hoist all fine — allocates nothing).

## D5. Tiers, callout contract, errors

- **Callout audit rule:** every arc-B helper performs **at most one
  `Heap.link`** per call (one interned string; scratch is host-side and
  unlinked), so `A` = the count of `.alloc` ops. A helper that could link
  more than once must be split or its op must carry its own bound —
  enforced by a doc-comment + test per helper (codex #14's synthetic
  multi-link case pins the audit).
- **Error protocol (codex #9):** callouts return a tagged result
  `{ok: *GcHeader} | {oom} | {vm_error}` (a NaN-boxed-free 2-word struct on
  the native side; tier-1a uses the Zig error union directly). Recorder
  guards make `vm_error` unreachable for the admitted shapes (arity/type
  pinned at record time; where a range can fail — `ssub` indices — the
  tier-0 body's clamping semantics are the recorded semantics, not an
  error). `oom` → side-exit at the loop header; the failed body performed no
  `link` (intern-miss OOM fails before `link`; scratch OOM fails before the
  intern), so the id stream is clean and tier-0's replay re-raises the same
  OOM at the same logical point. Proof obligation per helper: **no `link`
  precedes any fallible step** — pinned by tests.
- **Tier-1a:** op arms call the *same* tier-0 bodies (`internValue` path,
  `stdlib/string.zig` transforms) — one compiled body per builtin, the
  doc-23 D4 bit-identity argument verbatim. `guard_gc` arm: evaluate the
  predicate; fail → ordinary header exit. `values[]` staying unrooted is
  fine: the predicate guarantees no collection during the burst.
- **Native:** allocating callouts ride `emitCalloutSave`/`emitCalloutRestore`.
  The `*Heap` rides as a baked immediate (`movRegImm64` — the `Heap` is not a
  GC object and lives at a stable address for the VM's lifetime); no new
  register-file channel. `BodyCallout` rows gain the doc-22 split:
  **`may_allocate = true, may_collect = false`** — and because allocation
  never collects in place and the GC is non-moving, **heap-φ admission is
  unaffected** (codex confirms, given the error-contract repair): a
  φ-carried raw pointer stays valid across an allocating callout. The
  fail-closed `calloutMayGc` check is renamed to the split; the audit comment
  (nativegen.zig:2230) is re-derived. `guard_gc` lowering: two loads
  (`object_count`, `next_gc`), `lea`/`add` the immediate `A`, cmp, `jae` →
  ordinary exit stub; plus a byte test of the baked `gc_stress` flag address.
- **Loop-close flush:** extended per D3's full-write-set rule (recorder
  already knows the written-slot set; the extra stores ride the existing
  `exit_stores`/phi machinery).

## D6. Exec-log oracle

`EffectResult` already carries an inline-string arm. `tostr_*`/`snew`-class
results are logged through it (bytes, not the pointer), so the scalar-only
constraint of doc 11 is met without a wire change, and no event is dropped.
**`guard_gc` logs the boolean predicate as its guard value** (it has no SSA
operand — codex #13; the two counters it reads are not logged, the decision
is). A failing `guard_gc` is the burst's terminal log event, like any guard
exit.

## D7. The `alen` pending-store refinement (scalar end-to-end)

scalar's loop is `rawset(t,…); rawget(t,…); …; #t; … #tostring(i)`. Arc A's
`alen` aborts when `pending_stores` is non-empty (sunk-store hazard, arc-A
codex #4). The refinement — flush pending sunk stores at the `alen` emission
point (they commit below every guard anyway; emitting them before `alen`
preserves the store→border ordering the abort was protecting) — is a
recorder-local change, gated by the existing alen abort-matrix tests plus a
new rawset-then-len differential. Without it, scalar still aborts before
reaching `tostring(i)`; it is arc B's first commit for that reason. (In the
v1 budget design this is the ONLY pending-store interaction — codex #3's
allocation-boundary flush rule belongs to v2's continuation exits.)

## D8. Determinism analysis (itemized, post-review)

- **Allocation events:** same callout bodies, recorded program order, no
  DCE/hoist/reorder, CSE only where the elided execution is a guaranteed
  total hit ⇒ the trace's intern-call sequence ≡ tier-0's.
- **Collection events:** the budget guard makes a collection arithmetically
  impossible during any traced iteration, in every mode; collections happen
  only while tier-0 executes, at its single prologue site, with regs made
  identical by the full-write-set flush ⇒ same collection points, same root
  sets, same de-intern sets.
- **Partial-iteration replay:** id-neutral by the D2 corollary; premise
  (no intervening collection) guaranteed by the budget arithmetic rather
  than by scheduling.
- **`next_obj_id` / §T-A.2, `pairs` order:** follow from the two streams.
- **Mode matrix:** `record_only` performs the recorder's stack rendering +
  `internedLookup` only (the arc-A recorder-never-interns invariant is
  UNCHANGED — the new arms emit ops; the *executor* allocates).
  `gc_stress` legs never enter allocating traces (predicate conjunct) —
  tier-0-pure, trivially identical. Suspension-armed runs likewise
  (observation blackout).
- **Run-twice stability:** all inputs to every decision are deterministic
  counters and program state; no clock, no address, no RNG.

## D9. Gates (incorporating codex #14)

1. Unit: recorder arms (shape + abort matrices); per-helper pins: at most one
   `link` per call, no `link` before any fallible step; optimizer pins (no
   DCE of `.alloc`, no reorder, CSE only for `tostr_*`); `guard_gc` predicate
   arithmetic incl. saturation; the full-write-set flush (post-burst regs ≡
   tier-0 regs after identical iterations, compared slot-by-slot).
2. Adversarial matrix programs (codex #14): threshold crossing mid-loop with
   the budget guard bouncing entry; two allocating calls per iteration with
   the first crossing; `guard_gc` failing on the first attempted burst and
   after many committed bursts; intern-hit loops parked just below `next_gc`
   (correctness under the parked case, and a board note if it appears in
   practice); a stale heap ref in a written-but-dead slot, collected
   post-burst — compare the *marked object set* across modes; entry via
   side-trace chain and armed native link re-checking the budget guard; OOM
   injection at scratch growth / `createWithHash` / strtab growth;
   `gc_stress` legs with a root-killing write before the allocating call
   (must be tier-0-pure and identical); suspend/keyframe capture armed →
   allocating traces decline (blackout), capture after an ordinary guard
   failure replays identically.
3. §T-A.2-style cross-tier final-snapshot byte identity on an allocating-loop
   program — **the** arc-B acceptance test, plus `next_obj_id` equality
   asserted explicitly, plus a `pairs`-order-sensitive program in the
   ten-leg matrix.
4. hashgate 84/84 both legs; `just bench` 28/28 cross=ok; scalar (and
   str_manip minus upper/lower) tracing end-to-end (`--jit-stats`);
   instruction-count A/B vs HEAD shadow; full suite + `-Djit-debug` leg.

## Non-goals

- Continuation exits / mid-iteration resume (D3v2 — recorded, not built).
- `upper`/`lower` (codex #10 — VM effect state; v2 with a `*Vm` channel and
  an idempotency proof). Variadic `char`, 3-arg `rep`, `__tostring`.
- Table/non-interned allocation, allocation sinking, per-guard snapshots in
  general form.
- Pattern engine recording.
- Formatter-core (decimal.zig) performance — separate lever, separate arc.
- GC pacing changes (`next_gc` formula untouched; arc B reproduces the
  schedule, it does not redesign it).
- Hoisting of allocating ops; CSE of `snew`-class ops (codex #8).
- The format chain: **demoted from "staged within the arc" to next-arc** —
  it needs the per-VM scratch-buffer machinery (BUFHDR/BUFPUT analogue)
  whose ops face the same codex #4 arity questions; scoping it out keeps v1
  reviewable. D1's table stands corrected.

## Codex review ledger (2026-08-27)

Blockers: #1 `gc_stress` divergence before first allocation → `!gc_stress`
entry conjunct. #2 suspend/keyframe capture between exit and replay →
observation blackout. #3 sunk stores vs mid-iteration exit → v1 has no
mid-iteration exit (v2 obligation). #4 `sbuiltin` operand encoding → per-op
nodes, pinned arity. #5 continuation exits unchainable → v1 entry-invariant
guard; reduced surgery (hot-guard/side-trace exclusion only). Majors: #6
physical vs logical root set → full-write-set flush + marked-set gate. #7
flush-plan optimizer integration → v2 obligation. #8 CSE unsound for
`snew` class → CSE restricted to `tostr_*`. #9 callout error protocol →
tagged result + no-link-before-fallible-step proofs. #10 `upper`/`lower`
touch VM effect state → excluded from v1. #11 budget-guard baseline →
ADOPTED as v1; continuation design demoted to D3v2. #14 adversarial gates →
D9.2. Minors: #12 `aux` overload → `aux` = `A` only. #13 exec-log shape →
predicate-as-guard-value, pinned in D6.
