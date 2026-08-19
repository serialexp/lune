# lune — multi-store sinking (FFT butterfly) — Design

Status: complete — implemented (2026-06-22), extended 2026-08-16 (array-load
forwarding, `0e311f9`) and 2026-08-20 (hash-load classification, §below; codex
APPROVE after 3 review rounds) — recorder generalized to an
ordered virtual store buffer, flushed front-to-back below every guard at trace close;
post-store array AND hash loads now forward or prove non-aliasing statically; the
mode-equivalence gate is green. The mandatory constraint both reviewers converged
on — `commit()` flushes the pending stores **front-to-back in bytecode-execution
order** (§mechanism, §7.2) — is implemented and Codex's three doc-accuracy tightenings
are folded in below (recorded order = tier-0 bytecode order; the side-exit invariant
is "trace applies none, replay applies the source-path's stores"; later store guards
are sound only because in-bounds `astore` cannot change what they guard). Gap B
(doc 07, single-store) is the landed prerequisite.
Owner: Bart
Last updated: 2026-08-20

Prerequisite reading: `07-rmw-store-sinking.md` (Gap B — single-store sinking, the
mechanism this generalizes) and `01-trace-lifecycle.md` §"Loop-header re-entry
deopt" (the deopt model the soundness argument rests on). This doc extends Gap B's
single deferred `astore` to an **ordered set** of deferred stores, so loops
that write several array slots per iteration — the FFT butterfly — record and run
native.

## 2026-08-16 extension — guarded virtual-store forwarding

The original implementation deliberately rejected every array load after the first
deferred store and capped the fixed buffer at four entries. `fft_bitreverse` exposed
that as a general trace-region boundary: a recording anchored at its inner `while`
crosses the outer swap, defers four stores, then reaches the next swap's reads. The
reported `bad_type get_index` was this post-store-load rejection, **not** failure of
integral-float key narrowing. `keyRefNarrowed` had already emitted
`guard_float + int_of_float` for the arithmetic-derived `j` key.

The recorder now models an ordered virtual store buffer, following LuaJIT's general
`aa_ahref` / `fwd_ahload` technique (`lj_opt_mem.c`):

- `pending_stores` is allocator-backed and naturally bounded by the trace's
  `maxrecord` budget rather than an FFT-sized constant.
- A later load scans pending array stores newest-to-oldest. The key IR is classified
  `MUST`/`NO`/`MAY`: identical refs and the same integer base plus equal constant
  offsets must-alias; distinct integer constants or the same base plus distinct
  offsets cannot alias. `MUST` forwards, `NO` continues scanning, and `MAY` aborts
  recording fail-closed. No runtime equality guard pins an incidental relation
  between loop-varying keys. Last-writer-wins therefore stays exact.
- Distinct table SSA refs remain ambiguous—two refs may hold the same table at
  runtime—so that case aborts recording fail-closed. Hash/grid reads and appends retain
  their conservative boundaries; appends change array shape.
- If an `int_of_float` key ceases to be integral, native exits before mutation and
  tier-0 replays the source operation with its normal array/hash and metamethod
  semantics. Store flush order is unchanged.

This section supersedes the fixed-cap and “no post-store read” scope statements in
the original June design below; those passages are retained as the historical v1
argument.

## 2026-08-20 extension — hash-cell alias classification (`aa_href` for `hload`)

The 2026-08-16 extension fixed post-store **array** loads but left `recHashGet`'s
blanket rejection in place: any `hload` while `pending_stores` is non-empty aborted
`.bad_type`. That is the exact same trace-region boundary one storage class over, and
it kills the canonical OO field-mutation loop. nbody's inner loop is the type
specimen: `bj.vx = bj.vx + …` defers an `hstore("vx")`, and the very next statement's
`hload("vy")` hits the blanket abort — the whole 38.8× benchmark records two opcodes
per attempt. LuaJIT disambiguates these with `aa_href` (`lj_opt_mem.c`): hash
references to *different constant keys* can never alias, same key + same table
must-alias, same key + unproven-distinct tables may alias.

Our recorder makes this classification **exact, with no MAY case beyond table
identity**, because of the invariants already in the tree (codex-verified 2026-08-20):

1. Both `recHashGet` and `recHashSet` require the key ref to be a `.konst` (computed
   hash keys abort — v1 scope, unchanged here).
2. **Every key that reaches the hash recorders is an interned string.** Dispatch
   routes all numeric keys to `recArrayGet`/`recArraySet` (trace.zig ~11485), and
   `recArrayGet` rejects an out-of-array numeric key rather than falling through —
   so `t[1.0]`-vs-`t[1]` normalization (`table.normalizeKey`) can never produce an
   `hstore`/`hload` pair today. If numeric hash access is ever recorded, the
   classifier must compare `konstKey(normalizeKey(k))` and `seedHashCell`'s
   `(table_reg, key_const)` dedup must be normalized too; both are explicitly
   future-facing, not part of this extension.
3. Interned strings + `konst()` dedup on `(tag, bits)` (heap bits = pointer) ⇒ for
   these keys, equal content ⇔ same string object ⇔ the **same konst ref**. Key
   comparison is therefore konst-ref equality.

The rules, mirrored on the array classifier and walked newest→oldest so
last-writer-wins stays exact:

- Pending `.hstore` vs new `hload`:
  - key konst refs **differ** → **NO** alias (different interned-string keys are
    different cells regardless of which table each ref holds) → keep scanning.
  - key refs **equal**, same table SSA ref → **MUST** → forward the pending
    store's value ref (no `href`/`guard_hash`/`hload` emitted; the forwarded ref
    already carries the store-side `guardNum` type pin plus the store's own
    `guard_table`/`href`/`guard_hash` structure chain, and at record time tier-0 has
    already executed the store, so the observed loaded value *is* the stored value).
  - key refs equal, different table refs → **MAY** → abort fail-closed (two SSA
    refs may hold the same table).
- Pending `.astore` vs new `hload`: **NO**, airtight. Only in-bounds `.astore`s and
  `.hstore`s are ever buffered (`astore_append` is emitted inline, never deferred,
  and its `guard_append` requires an empty hash part), an in-bounds array store
  neither grows the array nor migrates hash cells, and every recordable `hload` key
  is a string. LuaJIT's migration warning (`lj_opt_mem.c` aa_ahref/NEWREF) concerns
  insertion/rehash, which the deferred-store IR cannot express.
- The reverse direction (`aload` after pending `.hstore`) keeps its existing skip:
  `recHashSet` only lands on a *present* hash cell, present hash keys are today
  string-only, and in any valid VM state no hash cell key lies inside the array
  range (maintained by `table.set`/append/rehash; `restoreEntry` can transiently
  violate it but only mid-restore, never at record time).

Everything else is untouched: `guard_hash` population pins stay sufficient (deferred
`hstore`s are present-key overwrites, population never changes), flush order at
`commit()` is unchanged (scan newest→oldest, flush oldest→newest — the pair that
makes repeated same-cell stores exact), and a NO-classified `hload` reading the heap
mid-buffer is sound because the pending stores provably don't touch its cell — on-trace
the read happens before the sunk stores execute, and the cell's value is identical
either way; on a side exit, deopt-replay applies the source path's stores exactly as
before. Forwarding removes an `hload` exec-log event, but every execution mode runs
the same forwarded SSA graph and the value stays scalar and guarded, so the scalar
exec-log oracle is unaffected.

## Implementation status

Tracking the gap between this design and what's on the main branch.
Tick items as they land; move whole sections to "done" once everything inside is
checked.

### Done

- [x] **C1 — recorder: `pending_store` → ordered `pending_stores` list (`trace.zig`).**
  Replaced the single optional, then the v1 fixed array, with an allocator-backed list;
  `recArraySet` appends each deferred store; `commit()` flushes
  all front-to-back (recorded bytecode order) below every guard, before the φ writebacks
  + `.loop`.
- [x] **C2 — recorder: post-store load forwarding (`trace.zig`).** Array loads now
  forward a statically must-alias pending value or skip a statically non-aliasing
  key before reading the heap. Ambiguous keys/table identity and shape-changing appends abort
  fail-closed. The trace budget replaces the v1 fixed capacity cap.
- [x] **C3 — consumers handle N sunk stores (`tropt`/`irinterp`/`nativegen`).** Confirmed
  no change needed: `tropt` already classifies every `astore` as an effectful,
  never-DCE'd root with no single-store invariant; `irinterp` runs IR positionally;
  `nativegen` lowers each `astore` independently and the XMM allocator keeps the N
  result doubles live to the flush (the 2-store nativegen unit + fft `cross=ok` confirm
  no miscompile under pressure).
- [x] **C4 — tests.** Recorder units: a 2-store butterfly records with both stores sunk
  (distinct arefs, no `astore` in-stream pre-commit); must-alias reads forward,
  statically distinct keys read the heap, and ambiguous keys abort. The buffer grows
  past the historical four-store cap. Nativegen unit: a 2-store f64 RMW to two distinct indices matches the
  oracle bit-for-bit. `interp.zig` 8-mode e2e: a two-store butterfly loop
  byte-identical across all 8 determinism modes (the load-bearing idempotence test).
- [x] **C5 — measure + docs.** `just bench --filter scimark`: scimark-fft t0 993.9 ms →
  jit 715.7 ms (1.39× tier-0 speedup; the butterfly now records native, `cross=ok`),
  jit/lj 54.3× → 39.1×. Remaining LuaJIT gap is structural FFT *coverage* (bit-reversal
  + non-butterfly work still tier-0), not this mechanism. Docs updated: this doc,
  `05-native-codegen.md`, `07`'s §6, `TODO.md`.
- [x] **Open question — `MAX_PENDING_STORES` value.** Superseded by the 2026-08-16
  allocator-backed buffer; `maxrecord` bounds it and native allocation spills or
  rejects a completed trace normally.
- [x] **Open question — aliasing among the N stores.** §7.2. Resolved: `commit()` flushes
  front-to-back in recorded order and never reorders, so trace and tier-0 agree on
  last-writer-wins regardless of aliasing.
- [x] **H1 — hash-load classifier (`trace.zig`).** Landed 2026-08-20:
  `forwardPendingHashLoad` in `recHashGet`, replacing the blanket
  `pending_stores.len > 0 → abort` with the §2026-08-20 rules — newest→oldest walk,
  `.astore` → NO (skip), different key konst → NO (keep scanning), same key + same
  table ref → MUST (forward the pending value ref, no re-emitted load chain), same
  key + different table refs → MAY (abort `.bad_type`, fail-closed).
- [x] **H2 — tests** (codex-augmented list), in `interp_trace_test.zig` ("hash
  alias" family — hash keys need genuine interned-konst `load_const`s, so these
  drive real Lua source): (a) NO different-key RMW chain, both stores sunk, 2
  hloads; (b)+(d)+(e) last-writer-wins MUST — exactly 1 `hload`, 2 `hstore`s in
  source order, distinct `.x` literal sites deduping to one konst, no re-emitted
  chain; (c) same key via two table refs (same runtime table, two slots → two
  slot_load refs) aborts MAY; (f) hload after pending astore is NO, mixed loop
  records. e2e (`expectProgram`, every GC×trace-mode leg): nbody-shaped
  multi-field RMW loop byte-identical; MUST-forwarded cell whose type drifts
  mid-run side-exits cleanly; side exit after a NO-classified read flushes the
  deferred store exactly once; plus the codex post-landing blockers —
  executable same-cell double-store last-writer-wins (wrong walk/flush order
  diverges), store-VALUE type drift (cell still int at entry) caught by the
  up-stream guards before the forwarded read consumes it, and the load-bearing
  structural pin: every sunk hstore's VALUE ref must carry its own
  guard_int/guard_float in the raw IR (verified to FAIL when `recHashSet`'s
  `guardNum` is removed — no e2e test can detect that loss, since upstream
  operand guards mask it in every reachable drift shape).
- [x] **H3 — measure.** Gate battery green (both test builds, six output hashes,
  three soundness repros, full board 28/28 `cross=ok`). nbody wall-clock is
  **unchanged** (182 ms, 38.5×) — expected: the classifier removes the recording
  blocker (the `bad_type get_index` abort at advance:114 is gone; the inner j-loop
  now records and compiles), but `--jit-stats` shows it runs ~1 iteration per
  native entry (n=5 bodies → inner trips of 1–4), so coverage stays ~0.6%. The
  remaining nbody lever is outer-loop linking: `advance:4`'s root recording still
  aborts `.nyi_opcode for_prep` at the inner header (`recForPrepLink`'s
  `.root`-kind restriction). This arc is the prerequisite; the win ships with the
  root-LINNER arc.

- [x] **Implementation review.** The 2026-08-16 array-forwarding recorder change
  went through 3 codex rounds and Bart approved the commit as-is (`0e311f9`). The
  2026-08-20 hash-classification extension went through codex post-landing review
  (gpt-5.6-sol, thread `01a01abe-1850-7032-903a-822bdfb4babb`), 3 rounds → APPROVE
  (round 2 added the executable last-writer-wins + store-VALUE-drift e2e; round 3
  added the structural store-side `guardNum` pin test, verified load-bearing).
  Committed under the 2026-08-20 campaign mandate (codex reviews, commit, continue).

### Outstanding

_(nothing — this design is fully landed)_

## Why this exists

Gap B (doc 07) relaxed the C1 rule for the **single-store** RMW shape and moved
scimark-sor from 46.9× → 4.5× and scimark-lu 74.5× → 12.4× vs LuaJIT. The two
remaining scimark numbers it left untouched are **scimark-fft (62×)** and
scimark-sparse (35×). Sparse is an indirect-gather kernel (`x[col[k]]`) and a
genuinely different problem. **FFT is not** — profiling shows it is blocked by
exactly one thing: it writes more than one array slot per iteration.

Profiled diagnosis (the project's profile-first rule; `--dump-native` on isolated
butterfly probes, June 2026):

| probe | shape | result |
|---|---|---|
| `bf1` | single-store RMW, one index (`v[i]=v[i]+1`) | **compiles native** (Gap B) |
| `bf2` | two stores, two indices (`v[j]=…; v[i]=…`) | **no trace — aborts** |
| `bf4` | full butterfly (4 reads, 4 stores, two indices) | **no trace — aborts** |

The cliff is precisely **1 → 2 stores**: Gap B's `recArraySet` aborts the second
eligible store via its `pending_store != null` guard (doc 07 §3.2 / §4.3 — single
store was an explicit scope limit). Everything else FFT's butterfly needs already
works: two-index addressing (`j = i+dual2`), the loop-variant stride `2*dual2`, and
multi-*read* (SOR reads 5 slots and compiles). So multi-store deferral is the *only*
blocker, and it is a direct generalization of the just-landed, twice-reviewed Gap B
mechanism.

The FFT inner loop (verbatim shape from `bench/luajit/scimark_lib.lua`):

```lua
for i=a,a+2*(n-dual2),2*dual2 do
  local j = i+dual2
  local jr, ji = v[j], v[j+1]               -- 2 reads
  local dr, di = wr*jr - wi*ji, wr*ji + wi*jr
  local ir, ii = v[i], v[i+1]               -- 2 reads
  v[j], v[j+1] = ir - dr, ii - di           -- 2 stores
  v[i], v[i+1] = ir + dr, ii + di           -- 2 stores
end
```

**All four reads precede all four stores.** No `aload` follows any store — the
shape Gap B's §3.2 invariant already requires. The values stored (`ir,ii,jr,ji` and
the products) are all derived from pre-store reads, so deferring all four stores to
the end of the body and flushing them in source order yields byte-identical results.

## Goals

- Record + natively compile loops that perform **2..N** packed-array stores per
  iteration, where every store follows every read (no read after any store).
- Preserve Gap B's soundness guarantee exactly: on any side-exit, *none* of the
  deferred stores have executed on-trace, so tier-0 re-runs the iteration and applies
  each store exactly once.
- Keep all 8 determinism modes byte-identical; keep the tier-1a oracle valid.
- Land behind `zig build test` + 8-mode determinism, reviewed before commit.

## Non-goals (historical v1; superseded where noted above)

- **Store-then-read in the same trace.** Still aborts. Needs store→load forwarding
  (read the pending value, not the heap) — a larger change, unchanged from Gap B.
- **Unbounded store counts.** A small fixed cap (`MAX_PENDING_STORES`, §7.1) bounds
  native register pressure; loops above the cap abort cleanly (no regression — they
  abort today too).
- **Aliasing-dependent reordering.** We flush in recorded (program) order and never
  reorder stores relative to each other, so aliasing is a non-issue (§7.2). We do not
  attempt to coalesce or eliminate stores to the same slot.
- **`__newindex` / hash-part / `.value`-lane stores.** Unchanged — still abort.

## The original v1 mechanism: defer an ordered set, flush all below the last guard

Gap B's insight (doc 07 §3) is unchanged and is what makes this a small change: an
`astore` is **effectful but not value-producing** — nothing in the trace reads its
result — so it can be freely sunk *later* in the trace as long as no later
instruction reads the slot it writes. Gap B sinks one; we sink several.

Concretely, generalize the recorder's single `pending_store: ?PendingStore` to an
ordered, bounded list `pending_stores: [MAX]PendingStore` (+ count):

- **`recArraySet`** (in-bounds RMW path): when the store follows an `aload` (the
  deferral condition) it **appends** a `PendingStore{aref, value, lane_ord}` to the
  list instead of emitting the `astore` inline. The address node (`aref`) and the
  store's guards (`guard_table`/`guard_lane`/`guard_int`/`guard_bounds`/`guard_fits`)
  are still emitted inline, exactly as in Gap B — only the `astore` node is deferred.
  If the list is already at capacity, abort `.bad_type` (clean, no regression).
- **`commit()`**: before the φ writeback loop and the `.loop` terminator, iterate the
  pending list **front-to-back** and append one `astore` node per entry. "Recorded
  order" here means **tier-0 bytecode execution order** — the order the recorder saw
  the `set_index` ops, which *is* the VM's actual store order (not textual Lua order,
  though for straight-line code they coincide). The flush must not coalesce, sort,
  reverse, or group the stores by table/index: appending front-to-back places all N
  stores below every guard (the body guards + `recForLoop`'s continuation `guard_true`,
  all already in the stream) and in the VM's store order — so the trace's
  last-writer-wins matches tier-0's exactly (§7.2).
- **Post-store invariant (unchanged from Gap B §3.2):** while the pending list is
  non-empty, any subsequent `aload` (`recArrayGet`) or `astore_append` aborts
  `.bad_type`. The stores must be the trace's **last array accesses**; no read may
  observe a stale pre-store value relative to tier-0's store-then-read replay. A
  further in-bounds `astore` does **not** abort — it appends to the list (that is the
  whole point of this change) until the cap is hit.

The pure-write fast path (no prior `aload`) is untouched: those stores emit inline
and pay nothing, exactly as today.

## Soundness summary (what reviewers must check)

For a trace with an ordered set of K deferred `astore`s (1 ≤ K ≤ MAX) flushed, in
recorded order, immediately before `.loop`:

1. **No side-exiting op is below any store.** All K stores are flushed below every
   guard; the only ops `commit()` appends after them are `.phi` writebacks and
   `.loop`, neither of which can side-exit. So *every* side-exit happens with **all K
   stores un-executed** — there is no partial-application state. The precise invariant
   (Codex's tightening): on a side-exit the **trace applies none** of the K stores;
   tier-0 then re-runs the iteration along **the original source path** and applies
   **exactly the stores that path executes** — once each. For the straight-line
   butterfly that is all K; for a control-channel shape with a branch *between* source
   stores (`if c then t[x]=… end; t[y]=…`) it is whichever stores that branch reaches.
   Either way trace and tier-0 agree, because the trace applied nothing and tier-0
   runs the real bytecode. This is the crux: with one store it was "the store hasn't
   run"; with K it is "*none* of the K have run," exactly as clean because the flush is
   atomic w.r.t. side-exits (no guard sits between any two sunk stores). Covers the
   data channel (RMW values) and the control channel (read-steered branches), since no
   read-derived decision sits below any store.
   - **Why the later stores' guards are still valid (Codex/Antigravity caveat).** With
     K stores, the inline `guard_bounds`/`guard_lane`/`guard_fits` for store #2..#K are
     emitted in the body *before* any store executes (the stores all sink below them),
     yet in source order they sat *after* store #1. This reordering is sound only
     because an in-bounds `astore` cannot change anything those guards check: it does
     not touch table identity (`guard_table`), the lane (`guard_lane` — out-of-lane
     values abort at record time and `guard_fits` runs inline before any store), the
     length/capacity (`guard_bounds` — `setInLane` leaves `len`/`cap` untouched), or
     destroy presence (storing nil aborts). `astore_append` is the exception — it
     changes `len` — so it is **never** deferred and **always** aborts after a pending
     store (it is the §mechanism post-store invariant, not a sinkable op).
2. **No heap-observing op follows any store** (enforced reactively, §mechanism). So
   no on-trace read can observe a stale pre-store value relative to tier-0's replay.
3. **Order is preserved.** Stores are flushed in recorded (program) order, so if two
   sunk stores alias the same slot (not the case in the butterfly, where `j=i+dual2`
   with `dual2≥2` makes the indices distinct, but the recorder need not prove that),
   the trace and tier-0 agree on which write wins — both apply them in the same order.
4. **Determinism is inherited, not re-argued.** Each sunk store moves byte-identical
   bits (Gap A `movsd` ↔ `@bitCast` parity; int/bool lanes settled earlier).
   Multi-store sinking changes only *when/how-many* stores are emitted, never *what*
   they write. The tier-1a oracle executes the same reordered IR, so it stays the
   differential oracle for the native backend.

The net rule replaces Gap B's "defer one store; abort on a second" with: **defer up
to MAX stores; sink them all, in order, past every guard at trace close; abort on any
post-store read/append or on exceeding MAX.**

## Phasing

See the Implementation-status checklist above (C1–C5). C1+C2 are the recorder change
(one file, `trace.zig`); C3 is a read-only confirmation of the three consumers with
code added only where lowering actually needs it (the likely spot: ensuring N result
XMMs stay live to the flush point — see §7.3); C4 is the test trio; C5 is
measure + docs lockstep + review + Bart approval.

## Open questions for review

### 7.1 — `MAX_PENDING_STORES` value
The butterfly needs exactly 4. A cap of 4 covers it while bounding the worst-case
live-range pressure on the XMM allocator (4 simultaneously-live result values held
from their computation to the flush). Higher caps risk spilling. Recommendation:
**4**, revisit only if a real kernel needs more. Confirm in review.

### 7.2 — aliasing among the N stores
If two deferred stores target the same slot, the result depends on store order. We
flush in recorded order and never reorder, so trace and tier-0 agree. The butterfly's
indices are provably distinct (`j=i+dual2`, `dual2≥2`), but **we deliberately do not
rely on that** — order preservation makes aliasing irrelevant to correctness. Confirm
the flush loop iterates the pending list front-to-back (source order), not reversed.

### 7.3 — native XMM liveness across N stores (the one real codegen risk)
Gap B extended a single value XMM's live range to the flush point; liveness handled
it automatically. With K stores, K result XMMs must stay live from their computation
through the `for_loop` int compare to the flush. The `for_loop` compare uses GP/int
registers (disjoint class), so it cannot clobber them — but K=4 simultaneously-live
doubles plus the loop's other float temps could exceed the XMM budget and force a
spill. Spilling is *correct* (just slower), but a reviewer should confirm: (a) the
allocator spills rather than miscompiles under pressure, and (b) K=4 actually fits
for the butterfly without pathological spilling. If it spills badly, that caps the
real-world win and argues for a lower MAX or a store-scheduling tweak — measure in C5.

### 7.4 — does any guard get emitted after `commit()` begins?
Same assumption as Gap B (doc 07 §7.2), now load-bearing for K stores: `recForLoop`'s
`guard_true` is the last guard, and `commit()` runs strictly after it. Confirm no path
emits a guard between the first pending-store flush and the `.loop` marker. (φ
writebacks are not guards and never side-exit, so their order relative to the stores
is immaterial — but the stores must all precede them to keep the body contiguous.)

## References

- `07-rmw-store-sinking.md` — Gap B, the single-store mechanism this generalizes.
- `05-native-codegen.md` §Phase B (C1/C2 invariants), §Phase D Gap A (f64 array lane).
- `01-trace-lifecycle.md` §"Loop-header re-entry deopt" — the deopt model.
- `bench/luajit/scimark_lib.lua` — the FFT butterfly source.
- `src/trace.zig` — `recArraySet`, `recArrayGet`, `commit`, `PendingStore`,
  `Recorder.pending_store` (the Gap B field this change generalizes).
