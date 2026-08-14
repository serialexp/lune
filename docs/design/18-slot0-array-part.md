# Slot-0 Array Part (LuaJIT-faithful 0-based storage) — Design

Status: complete — Phases 0–4 landed (`823f7ed` design, `81b73c2` Phase 1, `838fd75` Phase 2 THE flip, `0829bb7` Phase 3 doc sweep, Phase 4 measurement recorded in §P below); only the deliberately-deferred hash-part integer-key recording arc remains open
Owner: Bart / Claude
Last updated: 2026-08-14

## Implementation status

Tracking the gap between this design and what's on the main branch.
Tick items as they land; move whole sections to "done" once everything
inside them is checked.

### Done

- [x] **Phase 0 — review to ACCEPT.** codex `gpt-5.6-sol` rounds 1–3
  (REVISE → REVISE → APPROVE) + Antigravity rounds 1–2 (REVISE →
  CONFIRM); all findings folded (§R1/§R2/§R3). Landed `823f7ed`.
- [x] **Phase 1 — inert preparation (no behaviour change).**
  Producer-dispatched `guard_bounds` in tier-1a, the shared
  `inArray(k, extent)` helper routed through every non-native gate
  site, and `ArrayPart.seedAt` wired at today's semantics. Gate held:
  both builds green, seven hashes + repros byte-identical. Landed
  `81b73c2`.
- [x] **Phase 2 — THE atomic flip.** Layout (`asize`) + all three JIT
  tiers + interpreter fast paths + GC walks + grid
  inflate/deflate/getInt fixes + keyframe v7 (positional 0-based +
  restore bulk lane rebuild + `ArrayResidentKeyInHash` validation) +
  `pairs` walk, in ONE gated commit. Gate held: tests green in both
  builds (`-Djit-debug` included), all seven stdout hashes + three
  repros UNCHANGED (GATE PASS), the §T cross-tier matrix green
  (unit + 8-mode script + f2c corpus coverage), and nsieve-bit
  `--dump-aborts` reports **no recording aborts** — the motivating
  idx<1 `.bad_type` abort is gone. (No byte-frozen keyframe goldens
  existed to re-freeze; round-trip corpora are structural and the
  version bump guards compatibility.) Landed `838fd75`.
- [x] **Phase 3 — pins + docs.** `pairs`-order pin (doc 02), grid
  key-0 policy pins (doc 14 note), doc sweep (02/03/04/05/14 +
  `schema/trace.json` description + doc 04 v7 entry + `table.zig`
  module docs).

- [x] **Phase 4 — measurement per §P.** nsieve-bit + full board both
  promotion states, plus the §P.6 memory board via the new
  `--mem-stats` CLI flag (TrackingAllocator wrap in `main.zig`).
  Results recorded in §P ("Measured results") below. Headline:
  nsieve-bit 37.2 → 15.4 ms (LuaJIT gap 5.8× → 2.4×), 100% loop
  coverage / 91.2% of run cycles in traces, board otherwise within
  noise, memory board within noise (zero leaks), exact-2^i boundary
  overshoot confirmed at +48% peak on a targeted micro.
- [x] **Post-landing review (§R4) + fixes.** codex `gpt-5.6-sol` REVISE:
  append-over-hash-resident-key duplicate/shadow (set() absorbs
  newly-covered hash keys), `next()` control-key normalization, and
  the two missing §R3 tests (JIT-enabled restore-resume;
  failing-allocator bulk-repack restore). All fixed + tested.

### Outstanding

- [ ] **Deferred — hash-part integer-key recording.** Negative/sparse
  integer keys remain untraceable (abort, as today). Rare; own arc.

## Why this exists

lune's table array part covers logical keys `1..len` (`array.zig:36-38`);
key 0 is hash-resident. Tier-0 handles that fine, but the JIT recorder has
no hash-integer path: any recording that observes `t[0]` aborts
`.bad_type` (`trace.zig:11290/11434`), and each abort feeds the trace
gate's exponential backoff. On nsieve-bit (`p[i>>6]` = `p[0]` for `i<64`;
init loop `for i=0,…`) this starves the scan-segment trace until ~2/3
through the run — no fusion, no promotion until the tail — leaving the
benchmark at 6.6× LuaJIT (doc 17 §B4.8, Outstanding bullet B-5).

LuaJIT never sees this because its array part is 0-based and *includes
key 0*: `inarray(t,key) = (MSize)key < t->asize` (`lj_tab.h:79`), sizes
are non-inclusive ("asize=128 creates array slots for 0..127",
`lj_tab.c:132`), `countint` counts key 0 as array-eligible and rejects
negatives via unsigned wrap (`lj_tab.c:294-306`), and `rehashtab` regrows
the array to swallow a key-0 write like any other candidate
(`lj_tab.c:357`). Zero-indexing is a common user pattern (C habit,
off-by-one, bit-bucket math like nsieve-bit's `i>>6`); Pall pays one slot
per table for it. Per the general-mechanism rule (project Rule Z-6) and
LuaJIT-replication doctrine, we adopt the same layout: **the array part
covers logical keys `0..asize-1`, physical slot = key (identity
mapping)**. This is a *general* fix — every 0-indexing program gets the
fast path and stops poisoning trace recording — not an nsieve-bit patch.

Grounding: a very-thorough tree inventory of every 1-based assumption
(2026-08-14, 8 groups, file:line-cited) is the substrate for the sections
below; the LuaJIT reference is `~/Projects/LuaJIT/src/lj_tab.{h,c}`.

## D1 — Index mapping: key identity, non-inclusive `asize`

Physical slot for logical key `k` is `k` itself. The field formerly
named `len` becomes **`asize`** for scalar arrays (rename enforced by
compiler): non-inclusive physical slot count; valid keys are
`0..asize-1`. A conventional sequence `t[1..n]` built by appends
occupies slots `1..n` with slot 0 a hole and `asize = n+1` — one slot
of overhead on the append path. (Rehash-created extents are power-of-
two-sized and can overshoot more at boundaries — see D7's honesty
note.)

**The field contract is CONDITIONAL on shape (§R1 finding 3).** For a
**grid** the same Layout field keeps today's meaning: **row count**
(internal rows `0..rows-1` for outer keys `1..rows`). Grids are fully
encapsulated behind `garow`/`gcell`/`rowView` and their own guards; they
do not adopt identity mapping (D6). Every consumer of the field is
audited against this two-case contract; the frozen JIT `Layout` struct
(`array.zig:233-243`) is unchanged in shape (field rename only — no new
field, layout regression test updated for the name).

Why identity and not "keep `k-1`, bolt on a zero slot": a separate zero
slot bifurcates every fast path (two range checks), adds a Layout field,
and doesn't simplify anything. Identity mapping gives one unsigned
compare per access and *removes* the `sub 1` from native `aref`
emission (`nativegen.zig:4603-4618`) — the hot path gets shorter.

**The one bounds contract — exact Zig formulation (§R1 finding 6).**
Defined ONCE as a helper and routed through every non-native gate site:

```zig
inline fn inArray(k: i64, asize: usize) bool {
    return @as(u64, @bitCast(k)) < @as(u64, asize);
}
```

`@bitCast`, NOT `@intCast` — a negative key must *fail the compare* via
two's-complement wrap, never trap. Native mirrors it as `cmp key, asize;
jae` (the shape `guard_bounds` already emits, `nativegen.zig:4621-4635`
— today against `idx0 = k-1`; after the flip against `k` directly).
Covers key 0, rejects negatives, no `-1` anywhere on the scalar path.

## D2 — `asize` disambiguation: every consumer of the old `len`

The inventory found `len` overloaded four ways for scalars — plus the
grid row-count meaning (D1's conditional contract). Each consumer:

1. **Bounds limit** (recorder gate, `guard_bounds` after `.aref`,
   tier-1a mirror, native `len_home`): `inArray(k, asize)`. Grid rows
   are NOT under this rule — see D3 producer dispatch.
2. **`#t` border** (`table.zig:462-494`): unchanged 1-based semantics;
   `t[0]` present MUST NOT change `#t` (pinned by test). The border
   search seeds from the top array key, which is now
   `n = if (asize == 0) 0 else asize - 1` — the explicit empty-array
   guard (§R1 finding: `asize - 1` underflows at 0 before the existing
   `n > 0` loop can help). Then the existing trailing-nil trim + border
   search runs from that `n`, never visiting key 0.
3. **Append-successor identity**: "append" = writing key `k == asize`
   (the next physical slot), growing `asize` by one. Sites:
   `table.zig:228/295`, `trace.zig:11404`, `irinterp.zig:771`,
   `nativegen.zig:4801`. `guard_append`'s clauses become `hash empty ∧
   k == asize ∧ asize < cap`; `astore_append` stores `data[k]` and
   publishes `asize += 1` last (same memory-resident publish discipline,
   `nativegen.zig:4808-4868`). **Fresh-table seeding is a special case
   and is NOT covered by append** — see D2a.
4. **Physical count** (`ensureCapacity` copy sizes `array.zig:713-751`,
   `optimalLane`/`convert` walks `:415-452/:756-783`, presence sizing
   `:523-539`): `asize` is exactly the physical count; the physical
   walks (`decode(i)` for `i in 0..asize`) are index-space-agnostic and
   keep their meaning with the bound re-scoped.
5. **Grid row count** (D1 conditional contract): `gridRows`, `garow`
   bounds, native grid `len_home` use, `inflateToGrid`/`deflateGridImpl`
   — all under D6's rules, none under `inArray`.

**Every logical walk moves to `get(i) for i in 0..asize` (§R1: GC/serializer
off-by-one).** The `get(i+1) for i in 0..len` idiom appears at:
`gc.zig:485-488` (`.value` mark walk — a blind rename would BOTH skip
slot 0, leaking/UAF-ing a heap ref there, AND call `get(asize)` OOB on
the last iteration), `keyframeser.zig:139` (capture) and `:217`
(reachability walk), `table.zig:383-385` (rehash array scan),
`stdlib/base.zig:152-155` (`nextStep`). All five rewritten to the
0-based walk in the atomic flip; each gets a slot-0-heap-ref test.

### D2a — Fresh-table seeding + eager lane commit (§R1 findings 5/B2)

Without a special case, the first write `t[1] = v` to a fresh table
fails `k == asize` (1 ≠ 0) and falls into the hash part — every standard
1-based array in the language would start life hash-resident AND the
recorder's append trace shape would never form. And the eager
narrow-lane commit keys off `len == 0` (`array.zig:333-373`): neither
`resize(2)+setInPlace` nor "append nil then v" preserves it (the first
never commits; the second sees a nonzero extent).

Resolution: a new primitive **`ArrayPart.seedAt(gpa, k, v)`**, valid
only for `k ∈ {0, 1}` on an empty part (`asize == 0`) **and a non-nil
`v`** (§R2 finding 4: `Table.set` deliberately creates no extent for a
nil write — `t[0] = nil` on a fresh table must stay the no-op/hash
delete it is today, never mint an empty positional extent that changes
snapshot shape for a semantic no-op; the fresh-routing arm tests
`!v.isNil()` before calling, and `seedAt` asserts it). On allocation
failure `seedAt` leaves the part untouched (`asize` stays 0 —
OOM-atomic, pinned by a failing-allocator test):

- creates the part with `asize = k+1` (slot 0 a hole for `k == 1`),
- commits the lane **from `v`** (the first *real* value — hole slots
  never influence lane choice), exactly the eager-commit semantics of
  today's first append,
- sets presence for slot `k` only.

Routing: `Table.set`'s fresh-array arm calls `seedAt` for keys 0 and 1
ONLY. **All other integer keys route to the hash part and the
threshold-driven histogram rehash exactly as today** (§R1 finding 10 —
no "small k" generalization; direct seeding beyond {0,1} would bypass
the density policy and invent a storage shape neither lune nor LuaJIT
has). Key 1 keeps today's effective behaviour (first write of a
sequence goes array-resident with an eagerly-committed lane); key 0
gains it. The recorder does not need a `seed` IR shape: recording only
begins on hot loops, by which time the part exists; a recorded append
loop still guards `k == asize` per D2.3 (for a table seeded at 0 or 1,
subsequent contiguous writes ARE appends under the new identity).

## D3 — Three-tier JIT contract, producer-dispatched bounds

**`guard_bounds` is shared by scalar `aref` and grid `garow`**
(`trace.zig:11309-11335` vs `:11535-11540`; tier-1a applies one rule at
`irinterp.zig:724-735`; native's `garow` keeps `sub 1` at
`:4870-4887`). A global tier-1a re-derivation would admit grid row 0
while native still wraps it — a three-tier divergence (§R1 finding 2).
Resolution: **tier-1a `guard_bounds` dispatches on the producer op of
its operand** — `.aref` producer → `inArray(k, asize)`; `.garow`
producer → today's row semantics unchanged (`1 <= row <= rows`,
internal `row-1`). The recorder's two paths are already separate
functions (`recArrayGet/Set` vs `recGridGet/Set`) and change
independently; native's two paths are already separate emission arms
(`.aref` loses `sub 1`; `.garow` keeps it). No new opcode, no wire
change (`traceser.zig:337/342` ordinals untouched); the producer
dispatch lands in Phase 1 with both arms at today's semantics, so the
flip itself only changes the `.aref` arm. Explicit row-0 three-tier
differential tests in §T.

Producer recoverability is confirmed (§R2 answer to Q2): `.aref`/
`.garow` are memory ops, canonical to themselves, never folded/CSE'd
(`tropt.zig:333-339`), and `guard_bounds.a` is remapped through
compaction (`tropt.zig:564-573`) — the optimized operand still names
the producer directly. To make the dispatch fail closed on malformed
IR, `assertWellFormed` (which today only checks `guard_bounds.a` is an
earlier ref, `trace.zig:10879-10884`) additionally pins the producer op
∈ {`.aref`, `.garow`} (§R2 finding 6), with optimized array + grid
trace coverage.

Per-tier statement of the scalar re-derivation (all in the atomic flip):

- **Recorder** (`trace.zig`): `recArrayGet` gate (`:11290`) and
  `recArraySet` in-bounds gate (`:11434`) → `!inArray(idx, asize)`
  abort; append branch (`:11404`) → `idx == asize`. The key-0
  `.bad_type` abort disappears — the B-5 payoff. Negative keys still
  abort via the same unsigned test. Hole/nil-load abort unchanged. IR
  doc comments restated (`guard_bounds` `:140-141`,
  `guard_append`/`astore_append` `:216-239`).
- **Tier-1a** (`irinterp.zig`): `.guard_bounds` `.aref` arm →
  `inArray`; `.guard_append` (`:766-777`) → `idx == asize`;
  `.astore`/`flushNumericForLoopDone` pass the key into the (now
  0-based) array API — the `@intCast(i64→usize)` at `:257/:515` is safe
  for key 0; negatives are excluded structurally by the upstream guard.
- **Native** (`nativegen.zig`): `.aref` drops `sub reg, 1` (`:4603`) —
  the token's home holds the key; `.guard_bounds` keeps `cmp/jae`;
  `guard_present`/`aload`/`emitAStore` unchanged in shape with
  `idx0 := key`; `.guard_append` compares `key` to `[asize]`/`[cap]`;
  `Kind.aref` doc (`:661-671`) and `bounds_ok` dominance rationale
  (`:1329-1345`) restated. Reviewer question honoured (§R1 Q5): audit
  every consumer of the aref token for assumptions that `idx0 < len ⇒
  idx0` fits some narrower range — the presence `bt` and lane scaling
  use the same registers either way; the only numeric delta is +1,
  within all addressing modes.

**Atomicity (§R1 finding 1, both reviewers).** The old three-tier math
against the new layout is not "conservative", it is wrong-address
execution: post-flip `t[1]` at `asize=2` would be addressed at physical
slot 0 by an old `aref`, and old bounds `idx <= len` would admit
`idx == asize` (OOB). Therefore the layout flip and ALL scalar JIT
re-derivation land as ONE gated change (Phase 2). Phase 1 contains only
refactors that are semantically inert under the OLD layout.

## D4 — Keyframe schema: v6 → v7

`HeapTable.array` is positional with in-band nil holes
(`keyframeser.zig:132-152`, `schema/trace.json:106-109`, "keys 1..n,
positionally"). Under D1 it becomes **slots `0..asize-1` positionally**
(index = key, holes in-band nil). `snapshot_format_version` 6 → 7
(`keyframeser.zig:68`); no compat shims (global Rule #8); v6 files are
rejected by the existing version check. Restore (`keyframeser.zig:
665-670`) rebuilds by append-from-slot-0 (equivalent to
`resize+setInPlace` under identity mapping — every positional value
including the slot-0 nil is appended, so physical slot = key holds).
The reachability walk (`:212-236`) covers `0..asize` so a slot-0-only
heap ref is rooted. `restoreEntry` (`table.zig:281-285`) keeps
bypassing migration so a captured split round-trips.

**Restore must re-commit the lane (§R2 finding 2 — the consequential
one).** Append-from-slot-0 rebuilds every conventional array with a
leading nil append at zero extent, so ordinary append's eager-commit
heuristic (`array.zig:348`, zero extent + non-nil) never fires and
EVERY restored array would stay `.value` — which `recArraySet` rejects
(untraceable) and, worse, grid inflation rejects (`gc.zig:214-219`
requires packed numeric rows), so a captured grid (grids deflate before
capture) could never re-inflate after restore. Resolution: restore uses
a bulk logical rebuild — decode all `asize` slots, then commit the lane
chosen by `optimalLane` over the *present* values (the existing
`optimalLane`/`convert` machinery, `array.zig:415-452/756-783`) — a
restore-only path that does not touch ordinary append's heuristic.
Exact operation (§R3 finding 1 — mirror the ordinary rehash caller's
two steps, `table.zig:446-450`): if `optimalLane()` is narrow →
`repack(target)` **then `frozen = true`** (repack alone does not
freeze, `array.zig:454-465`; skipping the freeze would let a later
widen+rehash re-narrow, violating the one-shot monotonic-lane
invariant); if it returns `.value` → leave `frozen = false`, matching
ordinary rehash semantics. Lane identity is absent from guest-visible
logical state and snapshot bytes; memory accounting and transient
tiering behaviour may differ after restore (§R3 NIT wording — restore
deliberately discards transient JIT state, `keyframeser.zig:534-537`).
The functional requirement: restored narrow arrays regain a usable
narrow lane (frozen, widening monotonically), and a restored deflated
grid re-inflates on the next fused store. All pinned in §T.

**New v7 restore validation (§R1 finding 11 + §R2 finding 5): reject
any `entries` (hash) key whose `normalizeKey` result is an integer `k`
with `inArray(k, asize)`** — validation runs on the NORMALIZED key, so
a malformed float-spelled `0.0` (which `restoreEntry` would collapse to
integer 0, shadowed by positional slot 0) is caught, not just
`tag == int`. Fail closed. Round-trip goldens (`keyframeser.zig:1105+`)
re-frozen deliberately with a diff-and-justify note, never silently.

## D5 — Observable `pairs` order change

Key 0 moves from the sorted-hash walk (`stdlib/base.zig:144-147`,
order per `key_order.zig`) to the **front** of the array walk
(`nextStep` scan becomes `0..asize-1`; nil-control start = key 0; the
resume gate becomes `inArray(ctrl, asize)`). Observable
language-behaviour change for `t[0]`+`pairs` programs — deterministic
across all 8 modes (one rule everywhere), replay-safe, allowed
(Rule #8). `ipairs` (`nInext1`/`nInextN`, control 0, reads `i+1`) is
UNCHANGED — its control is an iterator cursor, not a table key; it
still starts at `t[1]`. Pinned by a new `pairs`-order test, a
capture/resume-while-control-is-key-0 test (§T), and a
`docs/design/02-determinism.md` §iteration-order update.

## D6 — Grids: 1-based outer keys, row-count field, key-0 policy

Grids do NOT adopt identity mapping. The Layout field means **row
count** for grids (D1 conditional contract); internal rows stay 0-based
(`row = key - 1`); `Value.rowView` (16-bit 0-based row,
`value.zig:49/92-96`) is untouched. Consequences, each a §R1 finding:

- **`Table.getInt` grid arm** (`table.zig:133-144`): the new unsigned
  gate would admit `i == 0` on a grid and execute
  `rowView(header, i - 1)` → `@intCast(-1)` panic. The grid arm keeps
  an explicit `i >= 1` gate (grid rows are keys `1..rows`); grid key 0
  falls through to the hash part like today.
- **`deflateGridImpl`** (`gc.zig:286-325`): rebuilds the outer array by
  appending rows from an empty part — under identity append the first
  row would land at KEY 0, shifting every row down by one. Deflation
  seeds the outer part with a slot-0 hole first (`seedAt`-shape resize
  to 1, or append the hole explicitly), then appends rows at keys
  `1..rows`.
- **`inflateToGrid`** (`gc.zig:182-258`): `rows` is read from a
  *scalar* parent whose field now means `asize`, so
  `rows = asize - 1` — but ONLY behind guards, in this order (§R2
  BLOCKER: the path is reachable with an empty outer table via every
  fused store on a non-grid table, `interp.zig:3678-3688`, and
  `asize - 1` underflows at 0; `asize == 1` has no 1-based rows):

  ```zig
  if (parent.array.asize <= 1) return false;      // before ANY subtraction
  if (!parent.array.get(0).isNil()) return false; // slot 0 populated blocks
  const rows = parent.array.asize - 1;
  ```

  The slot-0-absent rule is conservative and costs only the
  optimization, never correctness (deflation stays the escape hatch);
  codex confirmed no previously-successful promotion is newly blocked —
  before the flip a populated key 0 was hash-resident and inflation
  already rejects any parent/row hash part (`gc.zig:185-196/211-214`).
  Row reads become `get(r + 1)` over `r in 0..rows` — keys `1..rows`,
  unchanged logically.
- **Key-0 access policy, stated per path (§R1 finding 9 — the two
  paths differ today and keep differing):** *bare* `a[0]` read or write
  on a grid-shaped table deflates first (today's blanket bare-access
  policy, `interp.zig:3738-3760/3814-3829`) and then proceeds on the
  deflated table, whose outer part covers key 0 per D1. *Fused*
  `a[0][j]` stays in-grid and follows the outer-miss fault path
  (`interp.zig:3649-3671`) — row 0 does not exist, same as any
  out-of-range row today. Both pinned in §T.

Revisit identity-mapped grids only if 0-indexed grid workloads show up
(deferred, not decided-forever).

## D7 — Rehash / sizing: complete derivation (§R1 findings 4/M1)

The round-1 sketch ("keys 0..2 → bin 0") was wrong for lune: LuaJIT's
`bestasize` may return non-power-of-two sizes (bin 0 → asize 3,
`lj_tab.c:345-355`) while lune's `computeArraySize` returns powers of
two (`table.zig:339-356`) — under that constraint a lone key 1 in bin 0
would select size 1, which cannot hold physical slot 1. Complete
replacement derivation:

- **Eligibility** (`countKey`, `table.zig:322-328`): array-eligible ⇔
  `@as(u64, @bitCast(k)) < MAX_ASIZE` — key 0 counts, negatives
  excluded by wrap.
- **Binning**: `bin(k) = ceillog2(k + 1)` — the smallest `b` with
  `2^b > k`, i.e. the smallest power-of-two size whose slot range
  `0..2^b-1` contains key `k`. Key 0 → bin 0 (size 1), key 1 → bin 1
  (size 2), keys 2–3 → bin 2 (size 4), keys 4–7 → bin 3, … This also
  dissolves the `ceillog2(0)` histogram-overflow hazard structurally:
  `ceillog2(0 + 1) = 0`, no special case, no bucket-64 escape.
- **Size selection** (`computeArraySize`): unchanged algorithm shape —
  walk bins ascending, accumulate the populated count `na(b)` of keys
  `< 2^b`, select the largest `2^b` meeting the existing density gate —
  with the gate's population term now counting *populated keys*
  (holes, including the slot-0 hole, are not population; they are
  covered range). The returned size IS `asize` (a non-inclusive slot
  count). A table with keys {1,2}: bin 1 has 1 key covered by size 2,
  bin 2 has 2 keys covered by size 4 → size-4 density 2/4, size-2
  density 1/2; whichever the existing gate picks, the chosen size
  *contains* every key accumulated through the selected bin by
  construction — the round-1 defect (chosen size excludes counted
  keys) is impossible under `bin(k) = ceillog2(k+1)`. Keys in
  deliberately-rejected higher bins stay hash-resident, as today.
- **Memory honesty (§R2 finding 3).** Keeping power-of-two extents
  (lune's existing constraint; LuaJIT's `bestasize` allows
  non-power-of-two terminal sizes, `lj_tab.c:345-355`) means a dense
  run whose maximum key sits on a power-of-two boundary grows to the
  NEXT power after the +1 shift: the `2..64` shape
  (`table.zig:674-697`) needs slot 64 → bin 7 → `asize = 128` where
  the old scheme could stop at 64 — approaching 2× logical coverage at
  exact boundaries. Accepted and MEASURED (§P.6 restated accordingly;
  TrackingAllocator board deltas + exact boundary sizing tests for max
  keys 63/64/65/127/128 in §T). Adopting non-power-of-two terminal
  extents is recorded as a follow-up option if measurement objects,
  not folded into this change.
- **Drain** (`table.zig:403-421`): walks keys `old_asize ..
  new_asize-1` pulling hash residents into slots. **OOM rollback (§R1
  finding 7): on failure at key `k`, publish `asize = k`** — the first
  uncommitted physical slot — not the old `k-1` (which under identity
  would drop the last migrated slot or shadow a live hash entry).
- **`migrateFromHash` successor** (`table.zig:295`): `array.len + 1` →
  `asize` (the D2.3 identity).
- **Fresh seeding**: D2a only (`{0,1}` via `seedAt`); every other key
  goes hash + histogram, exactly today's policy — no density
  ping-pong surface beyond what exists now.

## D8 — GC + interpreter sites

All from the inventory, all in the atomic flip: the `.value`-lane mark
walk becomes `get(i) for i in 0..asize` (`gc.zig:485-488` — see D2's
walk list for the dual failure mode of a blind rename);
`interp.zig` `.get_index`/`.set_index` fast paths (`:2237-2307`) adopt
`inArray` + the D2a seed call on the fresh-array arm; fused grid paths
keep `i-1`/`j-1` per D6; `inflateToGrid`/`deflateGridImpl` per D6.

## D9 — What does NOT change

`#t` (1-based border), `ipairs` (from `t[1]`), `table.insert/remove/
concat/move/pack/unpack/sort` (sequence-defined, `stdlib/table.zig`),
string byte-sequence semantics (`s:decode`, doc 06), `normalizeKey`
(0.0→0 already works), `fieldPtr` (hash-only by design), grid outer
mapping and `rowView` (D6), trace wire schema ordinals, `key_order` for
the hash part, the `Layout` struct shape (field rename only). The
stdlib inventory CSV (Rule Z-5) is unaffected — no function is added,
finished, renamed, namespaced, or dropped.

## §T — Cross-tier test matrix (required by Phase 2's gate)

Beyond unchanged stdout hashes (necessary, not sufficient — §R1
finding 12), Phase 2 lands with tests for, at minimum:

- Keys `-1`, `0`, `asize-1`, `asize` at get/set in all three tiers
  (tier-0 direct; recorded trace via tier-1a; native) — same results,
  same side-exit behaviour.
- Slot-0 hole vs present value in every lane (bool bitmap, packed
  int widths, f64, `.value`); presence bits around slots 63/64
  (the word-rounding edge).
- In-bounds store, append at `k == asize`, append-capacity exit;
  fresh-seed at key 0 and key 1 (lane eagerly committed from the
  seeded value; slot-0 hole for the key-1 seed).
- Grid row 0: recorder aborts / tier-1a rejects / native wraps —
  identically; bare `a[0]` deflates; fused `a[0][j]` faults through
  the outer miss; deflation preserves outer keys (no down-shift);
  inflation blocked by a populated slot 0.
- Key-0 heap ref: GC mark walk roots it; snapshot capture + restore
  round-trips it; reachability walk finds a slot-0-only ref.
- Metatable `__index`/`__newindex` fire on a slot-0 hole (nil read
  routes through the metatable exactly like any absent key).
- Capture/resume while `next`'s control is key 0.
- `#t` unchanged by a present `t[0]`; `#t` on empty / slot-0-only /
  trailing-hole / hash-extended tables.
- v7 restore rejects an `entries` integer key inside the positional
  extent — including a float-spelled `0.0` (normalized-key
  validation).
- `pairs` order: key 0 first, then `1..`, then sorted hash.
- (§R2 additions:) empty and slot-0-only (`asize <= 1`)
  `inflateToGrid` attempts decline without underflow; snapshot restore
  of narrow bool/int/f64 arrays regains a usable narrow lane; captured
  grid → restore → next fused store re-inflates; restore byte-identity
  with heterogeneous logical values; `seedAt` never called for nil
  (fresh `t[0] = nil` stays a no-op) + failing-allocator atomicity;
  exact power-of-two rehash boundary sizes (max keys 63/64/65/127/128)
  asserted, not just `>=`; optimized `guard_bounds` producer preserved
  through `tropt` (well-formedness pin); recorder still aborts on a
  first-write-inside-trace to an existing empty table (pre-existing
  conservative behaviour, pinned so D2a never leaks into recording);
  deleting key 0 during `next` traversal, then resuming from control 0.
- (§R3 additions:) restored narrow array has `frozen == true` and
  subsequently only widens monotonically; one capture→restore→resume
  test WITH tracing + optimization + native codegen enabled after
  restore (the existing F2c harness runs without tracing,
  `keyframeser.zig:2287-2293`) asserting uninterrupted/resumed output
  + final logical snapshots agree, a restored narrow array records and
  executes its array trace, and a restored matrix re-inflates and
  executes the grid path (trace-cache identity exempt — restore
  discards transient JIT state by design); failing-allocator restore
  during the bulk repack leaks neither the original `.value` buffer
  nor the partial narrow buffers (`errdefer` chain,
  `keyframeser.zig:530-533`); the existing rehash-drain OOM test
  (`table.zig:931+`) extended to assert the exact rollback extent
  `asize == k`.

## §P — Frozen predictions (measured in Phase 4)

1. nsieve-bit 6: `--dump-aborts` index-`.bad_type` aborts drop to 0
   (the 24×:41 / 5×:58 / 6×:7 / 1×:17 population); the pc-58 scan trace
   records in the first backoff windows, not at log line ~220k;
   terminal loop-done failures collapse (the B-4 positional mechanism,
   doc 17 §B4.8, now has candidates to select).
2. nsieve-bit 6 wall improves materially from 36–37 ms toward the
   LuaJIT 5.6 ms scale (magnitude honestly unknown: earlier recording
   unlocks fusion+promotion for ~all of the run, but the scan segments'
   44 traced-cyc/it codegen quality is a separate, already-recorded
   lever).
3. Seven **stdout** hashes: UNCHANGED (stdout never encodes layout; the
   suite doesn't print `pairs` over `t[0]` tables). Any change is a
   defect, not a re-freeze.
4. Keyframe goldens: CHANGED (schema v7) — re-frozen with
   justification.
5. nsieve 9 / sieve_int / pi_leibniz / full board: within noise both
   promotion states (their tables never touch key 0; the only hot-path
   delta is `aref` losing an instruction, and D2a preserves 1-based
   seeding + eager lane commit bit-for-bit in behaviour).
6. Memory: +1 slot on the append path; rehash-created extents may
   grow to the next power of two at exact boundaries (D7 honesty
   note, up to ~2× covered range for max-key = 2^i shapes).
   TrackingAllocator deltas on the board measured and reported —
   expected within noise for the suite (its dense runs are
   append-built), any boundary-shape outlier called out explicitly.

### Measured results (Phase 4, 2026-08-14, post-flip rev `0829bb7` vs pre-flip `7b65d79`)

Boards: `just bench` (reps 5, ReleaseFast), both promotion states
(`silent_promotion_enabled` flipped in source, rebuilt, restored).
TSVs: pre-flip ON `20260814-121953`, pre-flip OFF `20260814-122259`,
post-flip ON `20260814-155221`, post-flip OFF `20260814-155531`.

1. **P.1 — CONFIRMED.** `--dump-aborts` on nsieve-bit 6 reports **"no
   recording aborts"** — the whole idx<1 `.bad_type` population
   (24×:41 / 5×:58 / 6×:7 / 1×:17) is gone. `--jit-stats`: **100.0%
   of loop iterations run as traces** (4,129,873 traced vs 730
   tier-0), 91.2% of run cycles traced (88.4% native + 2.9% seam);
   all four anchors — nsieve:7 (the formerly-aborting init loop),
   :17, :41, and the pc-58 scan loop — at ≥99.3% traced iterations.
   273 trace entries, 13 native link arms, 50,043 loop-done +
   50,027 bridge fused transitions, 1 disarm.
2. **P.2 — CONFIRMED, large.** nsieve-bit 6 wall (promotion ON):
   **37.2 → 15.4 ms** (−59%); LuaJIT 6.4 ms, so the gap closes
   5.8× → **2.4×**. Promotion OFF: 38.5 → 23.1 ms — pre-flip the
   promotion knob was ~neutral on this benchmark (37.2 vs 38.5)
   because recording aborted before promotion had material traces
   to promote; post-flip it buys a further −33% (23.1 → 15.4).
3. **P.3 — CONFIRMED.** All seven stdout hashes + three repros
   byte-identical (GATE PASS, recorded at the Phase 2 landing).
4. **P.4 — CONFIRMED (vacuous).** No byte-frozen keyframe goldens
   existed; corpora are structural and re-gated under v7.
5. **P.5 — CONFIRMED.** Full board within noise in both states.
   nsieve 12.9/13.6, sieve_int 6.4/6.6, pi_leibniz 12.0/12.0
   (ON, post/pre). Two apparent outliers investigated: scimark-lu
   ON 1221 vs 1136 re-repped at 1133 (reps 7) — noise; str_format
   +6–8% on BOTH tiers (573→607 t0, 564→627 jit) — the program
   touches no tables at all (pure `string.format` loop), and
   `perf` shows 81.8% of its time in `gc.Heap.internValue`, whose
   logic is untouched but whose code layout shifted with the
   gc.zig edits — an alignment artifact, not a semantic
   regression.
6. **P.6 — CONFIRMED.** Measured via the new `--mem-stats` flag
   (added to `main.zig` this phase; pre-flip binary patched
   identically from a `git archive` copy). Whole 28-program board:
   peak-bytes delta is a uniform **−288 B** (static structure
   delta, −0.02% typical), zero leaked bytes/allocations on every
   program under `--trace --jit-native`; nsieve-bit is −5.4% peak
   (fewer aborted recordings → less recorder scratch). Boundary
   shape: ascending fill to exactly N=2^20 peaks 3.24 MB pre vs
   4.82 MB post (**+48%** — slot count 2^20+1 doubles the extent,
   inside the "up to ~2×" honesty bound); off-boundary N=10^6
   identical (−160 B), descending/hash-dominated fill identical.

## §R4 — Post-landing implementation review (codex `gpt-5.6-sol`, 2026-08-14): REVISE → fixed

Reviewed the landed 838fd75/0829bb7/890c2c7 against this doc. Verdict
REVISE, two blockers + one §T coverage gap, all fixed in the follow-up
commit:

1. **Array/hash duplicate on append over a hash-resident key.**
   Key `== asize` in the hash is a *valid* state (D7's OOM rollback
   leaves the failed key there; a v7 restore reproduces any captured
   split), but `set()`'s append branch never dropped it — the next
   capture then failed `ArrayResidentKeyInHash`. Worse in the D2a
   fresh-1 seed: a hash-resident key 0 was *shadowed by the seeded
   hole* (value silently lost). Fix: both branches absorb
   newly-covered hash keys after the array insert (`hash.count() != 0`
   guarded, so sequential builds pay nothing); the seed variant writes
   the absorbed key-0 value into slot 0. Unit tests pin both shapes.
2. **`next()` control key not identity-normalized.** `next(t, 0.0)` /
   `next(t, -0.0)` denote array-resident key 0 but fell into the
   hash-successor arm and found nothing (pre-existing for any
   float-spelled control; array-relevant now that key 0 is
   array-resident). Fix: `nextStep` and `rowViewNextStep` fold the
   control through `normalizeKey` before classification; 8-mode test.
3. **§T (§R3 additions) coverage gap.** The required
   capture→restore→resume test WITH tracing + optimization + native
   codegen enabled after restore, and the failing-allocator
   bulk-repack restore test, had not landed. Both added
   (`keyframeser.zig`): the JIT-resume test asserts resumed output +
   final snapshot equality, post-restore trace recording AND dispatch
   (native entries on x86-64), grid re-inflation on the fused store
   path, and narrow-lane residency; the OOM test drives
   `checkAllAllocationFailures` through `restore` over a
   narrow-rebuildable snapshot.

Confirmed sound by the same review: scalar identity mapping, unsigned
bounds, native `aref`, grid conditional `asize`, GC walks, D7 binning,
length border logic, v7 validation (float-integer folding, −0.0, NaN),
and the `--mem-stats` tracker lifetime.

**Round 2** (same reviewer): the round-1 fix for the seed absorption
was itself not OOM-atomic — it removed the hash entries *before* the
slot-0 write, whose lane-widening (`{[0]=100000}` into a fresh u8
lane) can allocate and fail, losing key 0. Fixed transactionally:
PEEK the key-0 value (no removal), seed, do the possibly-widening
slot-0 write — on failure unwind the seed via `resize(0)` (shrink:
allocation-free, punches holes) so the untouched hash entries remain
the truth — and drop the hash copies only after the array holds both
values. Pinned by a `checkAllAllocationFailures` test asserting
value-preservation at every induced failure point. Round-1 repro
paths re-verified closed; blockers 2/3 confirmed resolved.

**Round 3** (same reviewer): **APPROVE**, no blocker findings. The
accepted residue — a surviving frozen narrow lane with `asize == 0`
after an unwound failure — confirmed harmless (no live values, invisible
to GC/serialization, retryable, monotonic widening preserved).

## §R1 — Round-1 review record (codex `gpt-5.6-sol` + Antigravity, 2026-08-14): REVISE ×2, convergent

Both reviewers independently confirmed the LuaJIT layout claims
(`lj_tab.h:79-84`, `lj_tab.c:128-139/294-306`), the motivating
abort+backoff chain, the v7 approach, the determinism of the `pairs`
change, and `ipairs` neutrality — and converged on the same defects,
all folded above:

1. **Phase 1/2 split unsound (BLOCKER ×2)** → Phases restructured:
   inert prep + ONE atomic flip. Old `aref` `sub 1` against the new
   layout mis-addresses every access; old `idx <= len` admits
   `idx == asize` (OOB tier-1a). Not trace-shape drift — corruption.
2. **`guard_bounds` producer ambiguity (BLOCKER)** → D3
   producer-dispatched semantics; grid arm unchanged; row-0
   differential tests.
3. **Grid row-count is a fifth `len` meaning (BLOCKER)** → D1
   conditional field contract + D6 rewrites: `getInt` grid-arm `i >= 1`
   gate (rowView `@intCast(-1)` panic), deflation slot-0 hole seed
   (row down-shift), inflation `rows = asize - 1` + slot-0-absent
   requirement (silent never-inflate regression).
4. **Sizing derivation broken (BLOCKER + MAJOR)** → D7 rewritten:
   `bin(k) = ceillog2(k+1)` (chosen size always contains counted keys;
   `ceillog2(0)` hazard dissolves), density counts populated keys,
   drain rollback publishes `asize = k`.
5. **Fresh `t[1]` regresses to hash + loses eager lane commit
   (BLOCKER ×2)** → D2a `seedAt` primitive, `{0,1}` only, lane
   committed from the first real value; all other keys keep the
   histogram path (also resolves the "small k undefined" MAJOR).
6. **GC/serializer/rehash/`nextStep` walk off-by-ones (BLOCKER +
   MINOR)** → D2's explicit five-site walk list; each with a slot-0
   heap-ref test (blind rename = skip slot 0 AND read OOB at
   `get(asize)`).
7. **Unsigned contract must be `@bitCast` (MAJOR)** → D1 exact helper.
8. **`#t` empty-array underflow (MAJOR)** → D2.2 explicit guard.
9. **Grid key-0 policy ambiguous between bare/fused paths (MAJOR)** →
   D6 states both (bare deflates, fused faults), both pinned.
10. **v7 restore validation (MINOR)** → D4 fail-closed extent check.
11. **Cross-tier test matrix (MINOR)** → §T, part of Phase 2's gate.

## §R2 — Round-2 review record (codex `gpt-5.6-sol`, 2026-08-14): REVISE, all folded

Round 2 confirmed the round-1 structural resolutions (atomic flip,
producer dispatch, conditional grid contract, `@bitCast` helper,
`{0,1}` seeding, v7 positional layout, walk inventory) and answered
the round-2 open questions:

- **Q1 (trace observes `seedAt`?): NO** — `new_table` is
  recorder-unsupported (`.nyi_opcode`, `trace.zig:10945-11055`)
  including inlined callees, and a first write inside a trace to an
  existing empty table aborts at the `.value`-lane reject
  (`trace.zig:11375-11388`) before any store is recorded. No seed IR
  needed; the conservative behaviour is pinned in §T.
- **Q2 (producer recoverable post-`tropt`?): YES** — folded into D3
  with the new well-formedness pin.
- **Q3 (inflation newly blocked?): NO** — pre-flip key 0 was
  hash-resident and inflation already rejects hash parts; folded into
  D6.
- **Q4 (splits change?): YES at boundaries** — the finding-3 memory
  honesty note.

New findings, all folded: **BLOCKER** `inflateToGrid` `asize <= 1`
guard ordered before subtraction + slot-0-nil check (reachable with an
empty outer via every fused store, `interp.zig:3678-3688`) → D6.
**MAJOR** restore-by-append never eager-commits → every restored array
`.value` → untraceable AND restored grids never re-inflate
(`gc.zig:214-219`) → D4 bulk lane rebuild via `optimalLane`/`convert`.
**MAJOR** power-of-two boundary overshoot falsified "+1 slot"/§P.6 →
D7 memory honesty + boundary tests. **MAJOR** `seedAt` nil
precondition (fresh `t[k] = nil` must stay a no-op) → D2a. **MINOR**
v7 validation on normalized keys (float `0.0`) → D4. **MINOR**
`assertWellFormed` pins the `guard_bounds` producer → D3. Plus seven
§T additions.

## §R3 — Round-3 review record (codex `gpt-5.6-sol`, 2026-08-14): **APPROVE**

No BLOCKER/MAJOR remain; four MINORs + one NIT, all folded: (1) the
restore lane rebuild must `repack` **then `frozen = true`** for narrow
lanes (repack alone doesn't freeze — one-shot monotonic-lane invariant)
→ D4; (2) §T gains a tracing+native-ENABLED capture→restore→resume
test (the existing F2c harness runs without tracing) → §T; (3)
failing-allocator coverage for the new bulk-repack restore allocation
→ §T; (4) the existing rehash-drain OOM test pins the exact rollback
extent `asize == k` → §T; (NIT) "lane is unobservable" qualified to
"absent from guest-visible logical state and snapshot bytes; memory
accounting and transient tiering may differ" → D4.

Round-3 answers, recorded: restore choosing a different optimal lane is
safe under the formal replay contract (doc 02:298-310 — identical
logical bytes/output; transient JIT state deliberately reset on
restore); `seedAt` routing is complete (ordinary first writes enter via
`Table.set`; rehash does its own whole-array commitment;
`migrateFromHash` follows an established append; restore is the
dedicated bulk path; grid deflation seeds its own slot-0 hole) — only
fresh scalar non-nil writes at keys {0,1} need `seedAt`.

**Antigravity round-2 confirmation (same day): CONFIRM — design
ready.** It re-verified all seven of its round-1 blockers as soundly
folded, independently re-derived the `bin(k) = ceillog2(k+1)`
containment property, confirmed the `tropt` compaction argument for
producer dispatch, the restore repack+freeze+errdefer chain, and that
the D5 `pairs` walk matches LuaJIT's `lj_tab_next` successor order
(nil ctrl → index 0 → array part front). No new findings.

**Design status: ACCEPTED (both reviewers). Bart's implementation
go-ahead pending.**

## References

- Inventory: 8-group 1-based-assumption sweep, 2026-08-14 (in-session;
  key findings inlined with file:line).
- LuaJIT: `lj_tab.h:79` (`inarray`), `lj_tab.c:132` (non-inclusive
  sizes), `:294-306` (`countint`), `:308-330` (`countarray`),
  `:345-355` (`bestasize` — non-power-of-two, NOT ported verbatim),
  `:357` (`rehashtab`), `:231` (`lj_tab_resize`).
- lune: doc 17 §B4.8 + Outstanding B-5 (motivating gap); doc 02
  (iteration order), doc 03 (`1..n` prose), doc 04 + `schema/trace.json`
  (positional array), doc 05 (Phase B `idx0 = k-1`), doc 06 (string
  bytes), doc 14 (grids).
