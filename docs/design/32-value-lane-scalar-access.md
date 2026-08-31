# 32 — `.value`-lane scalar array access

Status: v2 after codex review (2026-08-29; ledger §8). The review BLOCKED
v1 over a missing store-value type pin; §3 now requires `guardNum` on the
`.value` write, and four factual claims are corrected. Follows doc 31.
Closes the first of
four JIT *coverage* holes that a three-agent grounding pass isolated as
dominating the remaining LuaJIT gap — the one with the largest measured
single-benchmark effect and the cleanest general statement.

## 1. The evidence (spectral-norm, N=200)

`bench/luajit/spectral-norm.lua:33` seeds the working vector with
**integers**:

```lua
local u, v, t = {}, {}, {}
for i=1,N do u[i] = 1 end
```

`AtAv(v, u, t, N)` later calls `Atv(t, u, N)`, whose `y[i] = a` writes
**floats** into `u`. `array.zig widenFor` has no int→f64 rung, so the
array demotes to the type-generic `.value` lane and — because
`narrow ⇒ frozen` and `convert` carries `frozen` through — can never
re-narrow. From that point the JIT is blind to `u`:

```
count  anc@pc  abrt@pc  reason      opcode     anchor
    6       9       13  nyi_opcode  get_index  Av
    2      22       26  bad_type    set_index  Atv
```

Six aborts is `max_strikes`; the `Av` inner loop is abandoned for the rest
of the run.

Changing exactly one character — `u[i] = 1` → `u[i] = 1.0`, output
identical at `1.274223601` — removes the demotion and with it the aborts:

| | int init | float init |
|---|---|---|
| wall (ReleaseFast, `--trace --jit-native`) | 77–82 ms | 12.9–13.4 ms |
| native execution | **6.2%** of run | **60.2%** of run |
| tier-0, *no trace at all* | 90.2% | 4.8% |
| cycles/iter, traced | 25.5 | 24.9 |

The traced code is equally good in both runs (25.5 vs 24.9 c/it). The
entire 6× is *coverage*: in the int-init run the hot loop never gets a
trace.

## 2. What is actually wrong

Two record-time refusals in `src/trace.zig`:

* `arrayGetShape` accepts a `.value`-lane read only when the loaded
  element is a metatable-free **table** (the array-of-structs pattern,
  `bodies[i].x`). Every other element — including every int and every
  float — aborts `.nyi_opcode`.
* `arraySetShape` aborts `.nyi_opcode` on a `.value` lane
  **unconditionally**, for any value.

So a `.value`-lane array is invisible to the JIT unless it holds tables.
That is the general defect. spectral-norm is the instrument that revealed
it, not the target (Rule Z-6): the same hole swallows any array that ever
mixes int and float, and any array that starts empty and is filled
heterogeneously.

### Why the "obvious" fix is wrong

Adding an `int → f64` rung to `widenFor` would keep the array narrow.
It is not available to us: mahina distinguishes integers from floats
observably (`math.type`, `//`, `%`, `tostring`, `string.format`), so
re-encoding already-stored integers as doubles changes program output.
`.value` is the *correct* representation for a mixed array. The bug is
that the recorder cannot read or write it.

## 3. The admission rule

Admit `.value`-lane elements that are **int or float**. Everything else
keeps aborting.

This mirrors `hashGetShape` (`trace.zig:13191`), which restricts hash
fields to int/float, and it inherits that site's reasoning — with one
correction established during grounding:

* **Reason (2) — strict type guards — is the real constraint and it
  holds.** `guard_int` / `guard_float` pin the element's type so a later
  iteration that changes it side-exits. A bool element has no such guard
  (`guard_true` would wave a truthy heap value through); a string element
  would need `guard_string` plus content reasoning. Both stay out.
* **Reason (1) — "the exec-log encoder cannot encode a heap value" — is
  not a soundness constraint.** `execlog.zig` *silently drops*
  unencodable values (`isUnencodable`), and the exec log is mutually
  exclusive with native (`trace.zig` `native_codegen` doc comment); it is
  visualiser instrumentation, not a cross-mode oracle. Today's `.value`
  heap `aload` already relies on that drop. Int/float loads are strictly
  *more* encodable than what ships. This doc records the correction; the
  comment at `hashGetShape` should be softened when it is next touched.

### The emitted read sequence

```
guard_table(tab)            table, no metatable
guard_lane(tab, .value)     lane still .value
<key ref, narrowed>
aref(tab, key, .value)
guard_bounds(aref)
aload(aref, .value) : int|float
guard_int / guard_float(aload)
```

No `guard_present`. The `.value` lane has no presence bitmap — a hole is
an in-band `nil` `Value` — and a `nil` fails the trailing type guard. This
is exactly how the existing heap path is already sound: it emits no
`guard_present` either and lets `guard_table` reject `nil`.

### The emitted write sequence

```
guard_int | guard_float (val)    <- REQUIRED; the v1 omission the review blocked
guard_table(tab)
guard_lane(tab, .value)
<key ref, narrowed>
aref(tab, key, .value)
guard_bounds(aref)
astore(aref, val, .value)        (or deferred into pending_stores)
```

**`guardNum` on the stored value is mandatory, and it is the whole reason
the write is sound.** For a narrow lane, `guard_fits` doubles as the value's
type pin — `laneFits(.i32, v)` implies `v.isInt()`. On `.value`,
`laneFits(.value, _)` is unconditionally `true`, so `guard_fits` degenerates
to a no-op and pins nothing. Recording observed an int or a float once; the
producing SSA ref is not thereby guaranteed to stay numeric on a later
iteration. Without an explicit pin, tier-1a's `setInLane` would happily
store a drifted bool/heap/nil (its `assert(fits(val))` passes for `.value`),
while native `proveKinds` had assumed a numeric kind — an oracle divergence.

This is not a new mechanism: `hashSetShape` already emits exactly this
`guardNum(rval, vval, .value_type, f.val_od)` for the identical reason, and
its comment names the parallel outright ("this guard is the analogue of the
array path's `guard_fits`"). The `.value` array store is the second site
where there is no lane to constrain the value, so it needs the same pin.

The guard is emitted **inline, before** the store — it stays in the body
even when the store sinks into `pending_stores`, so a drifted value
side-exits *before* the write lands.

`guard_fits` is then correctly omitted: nothing downstream depends on it
(`tropt.guardConstPasses` folds it as always-pass; tier-1a's assert is
vacuous for `.value`; native's `fits_ok` exists only to stop width
truncation in narrow int lanes, which cannot arise here). The comment at
`arraySetShape` asserting "`.value` aborts above, so `lane` here is always
narrow" becomes false and must be rewritten.

This pin is also what makes **store-to-load forwarding** sound. A forwarding
hit returns before `aref`/`aload`/the trailing load guard are emitted, so a
forwarded read inherits its type pin entirely from the pending store's
value. Re-asserting `guardNum` in the must-alias arm would be defence in
depth; pinning at store creation is the actual invariant, so that is where
it goes. Forwarding itself is lane-agnostic — it reasons about table
identity and static key aliasing only — so heterogeneous per-index element
types are fine.

`.value` is the top of the widen lattice, so unlike a narrow lane there is
no "this store would change the shape" hazard: every value fits.

## 4. Constraints checked before designing (all clear)

**Exec log.** `effectser.toEffectResult` encodes nil/bool/int/float and
heap *strings*; anything else errors, and `execlog.zig` filters those out
before they can reach the encoder. Int and float loads encode natively.
`astore` logs only its own SSA result, which is always `nil`. No work.

**GC.** `gc.zig writeBarrier` is a deliberate no-op — the collector is a
stop-the-world, non-moving, tri-colour mark-sweep, and `blacken` re-walks
the whole `.value` array at collection time through logical `Value`s. A
store of an int or a float creates no heap edge. The store allocates
nothing and calls nothing, so it consumes no `guard_gc` budget, needs no
`HelperCaps` row, and cannot affect heap-φ admission (which rejects only
bodies containing a callout that *may collect*, and no current callout
does).

Precedent for the *legality* of a native `Value` write into a `.value`
cell already ships: `sgm_setpos` reaches
`table.zig setInLaneValueInt`, which writes `Value.int(x)` over an int
cell with no barrier. Note the review's correction — that is a native-body
**C callout**, not inline tag/payload codegen, so it is precedent for the
memory model, not for the lowering. The lowering template for writing the
tag explicitly is `hstore`.

Two qualifications kept honest: heap-valued `.value` stores stay out of
scope and are the one shape a generational post-write barrier would have to
cover; and "no barrier ever needed for a scalar overwrite" would *not*
survive a move to an incremental SATB collector, which needs a **pre**-write
barrier for the overwritten old reference.

**Widen-eviction.** `laneWidenedPast` asks whether the live lane can still
reach the recorded lane. `canWidenTo(L, .value)` is true for every *scalar*
lane, so a `.value`-recorded trace is not widen-evicted when the array
narrows — correctly, because a narrowed array can widen back and the guard
is therefore not permanently unsatisfiable. It is **not** true that such a
trace can never be evicted: `canWidenTo(.grid, .value)` is `false`, so a
table that inflates to a grid does evict its `.value` trace. The accepted
cost is narrower than v1 claimed: if a `.value` array narrows at a
`Table.rehash` while `!frozen`, the trace becomes a zombie holding one of
the four `max_traces_per_anchor` slots until cache pressure clears it.
Recorded, not fixed.

**Keyframe restore.** `keyframeser.zig` recomputes the optimal lane after a
restore and repacks — but `optimalLane` returns a narrow lane only for a
**homogeneous** run (all-int or all-float). A genuinely mixed int+float
array, which is precisely the shape this doc admits, stays `.value` across
a restore. v1 additionally claimed a pre-snapshot trace would take a
`guard_lane` side-exit post-restore; that is **false** — restore constructs
a fresh VM and does not restore the trace cache, so there is no surviving
trace to fail. The test to write is therefore the plain round-trip: a mixed
`.value` array still records and still produces byte-identical output after
a restore. (The comment motivating the repack with "a restored sieve is
untraceable (the recorder aborts on `.value`)" is partly obsoleted by this
change; the repack is still wanted for density.)

## 5. Native lowering

The tag-check-and-side-exit shape already exists twice and is reused, not
invented:

* `hload` (`nativegen.zig`) discriminates `TAG_INT` vs `TAG_FLOAT` on a
  boxed hash cell and side-exits on mismatch. This is the template for the
  scalar `.value` `aload`.
* the `.value` `aload` heap path already does
  `cmpByteMemImm(rax, VALUE_TAG_OFF, TAG_HEAP)` + `jccNativeExit(.ne)`
  after `shl 4` + `add data`. Only the expected tag and the payload
  destination change; `opMayExitInBody` already reports any `VALUE_LANE`
  `aload` as body-exiting.

The `.value` `astore` is new: address, tag byte, payload (`mov` for int,
`movsd` for float), and — unlike every narrow lane — **no presence
`bts`**, because `present` is `null` on a `.value` part. The hoisted-base
pass must therefore not reserve a presence base for it; the existing
bool-lane exemption generalises. The tag must be written explicitly as
`TAG_INT` or `TAG_FLOAT` (that is what preserves integer-vs-float
identity); `hstore` is the existing site that does exactly this.

Writing only tag and payload, leaving `Value`'s seven padding bytes
untouched, is safe: the padding is explicit in `value.zig`, equality
compares semantic fields rather than raw memory, keyframe capture
serialises logical values through `array.get`, and the review found no
`memcmp`, raw bitcast, or snapshot path that observes it.

Float bit patterns survive: `.value` keeps the raw 64-bit payload, `movsd`
preserves every bit including NaN payloads, and the snapshot float encoder
bitcasts to `u64` — the same treatment the `.f64` lane already gets, so
there is no normalisation asymmetry between the two representations.

`proveKinds` gains int/float on the `VALUE_LANE` `aload` arm and a
`VALUE_LANE` arm on `astore` that requires a proven `.int`/`.float` value
and a dominating bounds check, and requires no `fits_ok` (there is nothing
to fit).

The redundant `guard_int`/`guard_float` the recorder emits after the load
costs nothing on native: `proveKinds` discharges a guard on an
already-proven kind statically and the body emits no instruction for it —
the same treatment `hload` + `guardNum` already gets.

## 6. Scope cuts (deliberate, recorded in TODO.md)

* **`.value` `astore_append`.** The append fast path admits `.boolean` and
  the int lanes only. Growing a `.value` array on-trace stays a tier-0
  side-exit. Nothing measured needs it.
* **Non-numeric `.value` elements** (bool, string, function). No strict
  type guard; string would additionally need `guard_string` plumbing.
* **Heap-valued `.value` stores.** The one shape that would need a real
  write barrier under a future generational collector.
* **`laneConsistent`** — one array lane per whole trace
  (`nativegen.zig`). A loop touching a `.value` array *and* an `.f64`
  array will now record but fail to compile natively. That is B3, the next
  bug in the queue, deliberately not fixed here so this change reads as a
  single variable on the board.

## 7. Expected result and the falsification rule

Prediction: spectral-norm's `jit` column goes ~81 ms → ~15 ms, its native
residency 6.2% → ~60%, and the `get_index nyi_opcode` rows disappear from
`--dump-aborts`. Everything else on the board is expected within noise.

Per doc 31 §7, **any above-noise regression is a real finding to
investigate, not to tune around.** The predicted mechanism for one is a
loop that previously aborted now recording, mixing a `.value` array with a
differently-laned array, failing `laneConsistent`, and being gated
`native_unsupported`. If that shows up, it is evidence for B3's priority,
not a reason to narrow this admission.

Output must not change anywhere: `tools/hashgate.py` stays 84/84 with **no
ref regeneration**.

## 7b. Measured result (2026-08-30)

**The prediction was half right, and the half that failed found a new bug.**

The coverage claim held exactly. `--dump-aborts` no longer shows a single
`get_index nyi_opcode` row at spectral-norm's `Av` anchor, and iteration
coverage went **54.7% → 99.5%**. Output did not change anywhere:
`tools/hashgate.py` is 84/84 on both the ReleaseFast and Debug legs with no
ref regeneration.

The *speed* claim did not. Predicted ~81 ms → ~15 ms; measured **−4.2%**.

### Why the board is trustworthy this time

The first attempt at a board was taken on the development desktop and was
**contaminated and discarded**: every row regressed +11% to +46% *including
the pure tier-0 column*, which this change cannot affect. The cause was a
game running at 790% CPU (load average 12.9–17.3). No conclusion was drawn
from it.

The board below was taken on the Gothab remote profile pool (`gt profile`,
2 vCPU Xeon 6975P-C, isolated, nothing else scheduled) — see
`.gothab/workflows/profile-bench.yml`. Three full runs were taken:
baseline (this arc reverted, harness kept), B2, and B2 again. The third run
exists to measure the pool's per-row run-to-run noise **directly**, rather
than inferring it:

| | value |
|---|---|
| max per-row \|Δ\| between two runs of *identical* code | **1.3%** |
| total `jit` wall, baseline → B2 | 4276.8 ms → 4281.9 ms (**+0.12%**) |
| spectral-norm `jit`, baseline → B2 | 89.6 ms → 85.8 ms (**−4.2%**) |
| spectral-norm native residency | 10.3% → 11.4% |

So −4.2% is ~3× the noise floor and reproduces; everything else on the
board is flat.

### The two above-noise rows, investigated (not tuned around)

§7's rule required investigating any above-noise regression. Two rows
qualified: `str_find_match` +3.3% and `scimark-lu` +2.0%, both above the
1.3% band. **Neither is caused by this change**, and the evidence is
structural rather than timing-based:

| | `str_find_match` | `scimark-lu` |
|---|---|---|
| trace entries, base → B2 | 1 → 1 | 99000 → 99000 |
| native bodies | 1 → 1 | 99000 → 99000 |
| recorded aborts | — | 13 → 13 |
| native residency | 98.8% → 98.7% | 39.8% → 41.3% |
| `--dump-native` instruction stream | identical (585 lines both) | — |

For `str_find_match` the emitted machine code was diffed directly: the two
builds differ **only** in embedded 64-bit immediates (heap pointers, and one
callee address shifted by 8 bytes), with an identical instruction sequence
and identical length. Neither benchmark touches a `.value` lane at all.

The residual is therefore **binary code layout** — editing `nativegen.zig`
and `trace.zig` moved functions in the mahina image, changing I-cache and
branch-predictor alignment for unrelated code. This is a measurement
confound, not a behaviour change, and it cancels across the suite (total
+0.12%). Recorded here so the next arc does not re-investigate it: on this
pool, a ±2–3% single-row move with unchanged trace structure is layout, and
the way to tell is to diff `--dump-native` rather than to re-time.

### Why the speed prediction failed: B2b

The prediction assumed coverage was the only thing between `Av` and its
trace. It was not. With the trace now recordable, **89.3% of spectral-norm's
run is "tier-0, has-trace"** — a committed, healthy, 20×-faster trace that
dispatch declines to enter:

```
Av:9    traced-it 118622   interp-it 681378   trc%it 14.8%   run% 89.3%
                                        native 22.2 c/it   tier-0 434.3 c/it
Atv:9   traced-it 791942   interp-it   8058   trc%it 99.0%
```

`Av` is called alternately over `u` (`.value`) and `v` (`.f64`) — one anchor,
two lanes. The trace compiles for one; when the other array arrives the
**prologue refuses entry** (`exit_instr == maxInt(u32)`, `completed == 0`,
nothing executed). `accountLegacyThrash` scores that refusal as a thrash
strike, and ~60 consecutive refusals per call drive
`gate[dispatch:legacy_thrash]` with escalating 256→4096-tick cooldowns that
block the *good* calls too. `Atv`, which is monomorphic, sits at 99.0%.

Two distinct defects, both outside this arc's approved scope:

1. a prologue entry refusal is not thrash — nothing ran, so pricing it as
   turnstile cost is a category error; and
2. the anchor never records a second trace for the second lane shape, where
   LuaJIT's answer is another root or side trace, not a penalty.

This is B2b. It is filed in `TODO.md`; this arc is not extended into it
without an explicit scoping decision.

## 8. Review ledger

Codex review of v1, 2026-08-29. Verdict: **BLOCKED as written**, with one
soundness blocker and five factual corrections. All accepted; none
disputed.

| # | Finding | Disposition |
|---|---|---|
| 1 | **BLOCKER** — the `.value` write emits no type pin. `guard_fits` is vacuous on `.value`, so a stored SSA value that drifts non-numeric on a later iteration reaches tier-1a's `setInLane` (whose `fits` assert passes for `.value`) while native assumed a numeric kind. Oracle divergence. | Accepted. §3 now requires `guardNum` on the stored value, emitted inline before the store, mirroring `hashSetShape`. This is also what makes store-to-load forwarding sound, since a forwarding hit returns before any load guard is emitted. |
| 2 | "`laneWidenedPast` never evicts a `.value`-recorded trace" is too broad — `canWidenTo(.grid, .value)` is `false`, so a table that inflates to a grid *does* evict. | Accepted; §4 corrected and narrowed. |
| 3 | Restore re-narrows only a **homogeneous** `.value` array; a mixed int+float array — the shape this doc admits — stays `.value`. | Accepted; §4 corrected. |
| 4 | "A pre-snapshot `.value` trace side-exits after restore" is false: restore builds a fresh VM and does not restore the trace cache. | Accepted; §4 corrected and the planned test replaced with a plain round-trip. |
| 5 | `sgm_setpos` is a native-body **C callout**, not inline tag/payload codegen — precedent for the memory model, not for the lowering. | Accepted; §4 and §5 corrected, with `hstore` named as the lowering template. |
| 6 | The no-barrier argument holds for the current collector and for a conventional generational post-write barrier, but not for an incremental SATB collector (which needs a pre-write barrier for the overwritten reference). | Accepted; recorded as a qualification in §4. |

Confirmed by the review, not merely asserted: dropping `guard_present` on a
`.value` read is sound in every tier (a hole reads back as in-band `nil` and
the trailing type guard rejects it); dropping `guard_fits` on the write is
safe *once* finding 1 is fixed; `.aload` is neither LICM-hoisted nor CSE'd,
so the per-iteration tag check cannot be optimised away; there is no float
bit-pattern or `Value`-padding divergence; the GC argument holds; and the
rejection of an int→f64 `widenFor` rung is correct (it would lose the
observable integer tag and, for large integers, precision). The reviewer
also agreed that more aggressive re-narrowing is not a cheaper substitute —
it would need a versioned shape/epoch plus an amortisation policy, and would
still not cover genuinely heterogeneous arrays.
