# Owned hash part + HREFK constant-key slot specialization — Design

Status: complete — P1–P5 landed and green (P1–P4: nbody 23.3× → 13.4× LJ; P5: 13.9× → 11.6×, resolveHashCell callouts eliminated from nbody); defers recorded below
Owner: mahina JIT campaign (nbody arc, task #32; P5: task #41)
Last updated: 2026-09-18

## Implementation status

Tracking the gap between this design and what's on the main branch.
Tick items as they land; move whole sections to "done" once everything
inside them is checked.

### Done

- [x] **P1 — `src/hash_part.zig`: the owned map.** Landed: extern
  `Node{key,value}` (32 B, comptime-asserted), `HashPart{nodes, mask,
  live, used}`, Lua-style deletion (free ⇔ nil key tag; dead ⇔ live
  key + nil value, heap key payload rewritten to `GcHeader.id` bits),
  publication ordering, `liveSlotOf`/`probeForPut` two-layer split,
  splitmix64 `keyHash` over (tag, id-or-bits), min capacity 4, ¾ load
  limit tripped only by genuinely-free inserts. 8 inline tests incl.
  deterministic-layout, resurrection, collision+dead-reuse,
  FailingAllocator sweep; leak-checked.
- [x] **P1b — map performance battery (Rule #20).** Measured vs the
  std-map shadow baseline (tier-0, best-of-N interleaved): nbody
  −4.7%, array3d −5.8%, field-hash micro −6.8%, delete/reinsert churn
  −6.3%, sieve −0.5%, repack −1.5%, miss micro +2.2% (the predicted
  no-fingerprint miss cost, within noise), binary-trees noise
  (−0.9%/−0.4%/+4.2% across three re-runs). Interleaved layout
  confirmed a win, not just a hypothesis.
- [x] **P2 — swap into `Table.hash`.** `table.Map =
  hash_part.HashPart`; external call sites migrated; `ValueContext`
  delegates to `keyHash`; `ArrLayout.hash_size` re-pointed at `live`.
  Table 112→120 B — same SmpAllocator 128 B class, no boundary
  crossed. Full gate green first try (determinism/keyframe/GC suites
  included).
- [x] **P2b — restore-boundary contract.** Contract documented in
  doc 02 (Done-list bullet: geometry divergence across restore is
  permissible; artifacts byte-identical for identical executions;
  hrefk guards re-validate live state, ids not addresses). Pinned by
  the `doc 49 P2b` keyframeser restore test: `used > live` history
  restores to a dead-node-free twin (layout genuinely diverges),
  `encodeSnapshot ∘ restore == identity`, and a second restore
  reproduces the first's layout slot-for-slot.
- [x] **P3 — HREFK record + native lowering.** Landed:
  `Table.hashSlotOf` (live slots only), `trace_ir.HrefAux`
  encode/decode (3-domain aux contract, round-trip tested), recorder
  `hrefAuxFor` at both href emission sites, prover aux validation,
  `bodyCalloutOf` hrefk exemption (no save frame), `emitHrefK`
  (contractual guard order: mask → live-cell → key tag → key id) +
  dispatch. Tests (`nativegen_hrefk_test.zig`): same-shape
  distinct-table read loop vs oracle, guard_table agreement,
  two-universe RMW store, swapped-slot sibling (native exits at the
  pinned iteration, oracle completes — the conservative divergence),
  delete+unrelated-insert dead-node store trap (live-cell guard exits
  before key deref; `live` accounting untouched), rehash + empty-map
  mask-guard exits, static-root-with-hrefk-aux fail-closed bail. All
  three guards verified to bite via temporary neutering (dead-node
  test segfaults without the live-cell guard — the id-bits deref).
  Headline: nbody JIT 107.8 → 61.9 ms (−43%), outputs byte-identical
  across tier-0/jit/baseline; native body ~843 → ~297 cyc/it.
- [x] **P4 — gate battery + board.** Full `just test` green. Full
  board (TSV `20260916-141459-858834f`, all cross ok / luajit ok):
  **nbody 106.4 → 61.7 ms JIT, 23.3× → 13.4× LJ (−42%)**; free
  riders repack −14.1%, binary-trees −7.4%, grid_matmul_f64 −7.4%,
  nsieve −6.5%, and tier-0 down broadly (field_hash −9.7%, array3d
  −6.2%, nbody −5.4%) from the cheaper owned-map probe. Apparent
  regressions (str_gsub +15%, str_manip +7%, array3d jit +5%) all
  disproven by ×3 interleaved re-runs (str_gsub 51.2/51.9/52.0 vs
  old-board 54.8 — actually faster). Re-profile at bench size
  (`--jit-stats` 50000): advance:34 87.5% traced, trc ~466 c/it
  (native ~321 + seam ~147); whole-run traced 51.0% of cycles.
  perf: `liveSlotOf` 31.9% + `Table.set` 9.9% — almost all TIER-0
  probes from the still-untraced outer loops (advance:4 nested
  for_prep 13.6% run, main:211 aliased_input get_upval 18.5%,
  tier-0 no-trace 32.3% of cycles), plus `replayLedgerFrom` 7.5%
  (~1028 cyc/walk seam). Those are the next rocks, out of scope
  here (recorded below).

- [x] **P5 — hrefk fallback for seeded hrefs on carried-heap roots.**
  LANDED 2026-09-18. `InputSeed.hrefk_aux` stamped by `seedHashCell`
  (shared `hrefkAuxOf` helper with `hrefAuxFor`), emission-side
  `effectiveHrefAux` routing both `bodyCalloutOf` and the href emit
  dispatch, `emitHrefK` reused verbatim on the substituted aux. Tests:
  correct-hint agreement battery + wrong-hint divergence proof (native
  side-exits where the callout would complete — the hint demonstrably
  reaches lowering; toggling the stamp to `-1` restores the callout
  end-to-end). Measured: `resolveHashCell` GONE from the nbody profile
  (`liveSlotOf` 30.7% → 15.2%, remainder is tier-0's untraced outer
  loops), **nbody 62.8 → 54.0–54.5 ms (−13%, 13.9× → 11.6× LJ)**,
  binary-trees −3.4%, sparse −3%, rest of the board in band, all
  cross-tier ok.

### Outstanding
- [ ] **Defer — guard_hash subsumption.** With mask + key + live-cell
  guards per iteration, the aggregate `guard_hash` count check is
  likely redundant on hrefk chains; dropping it is a separate measured
  cheapening.
- [ ] **Defer — on-trace hash insertion (`asm_newref` analogue).**
  The owned layout makes it possible. Forward constraint recorded
  below: insertion may reallocate `nodes` after an hrefk cell pointer
  is produced but before a sunk `hstore` commits — it must be ordered
  after all outstanding cell uses, invalidate them, or force an exit.
- [ ] **Defer — scalar-key hrefk.** v1 admits the recorder's current
  konst-string keys only. Numeric keys would additionally need an
  array/hash-residency story (rehash can migrate integer keys to the
  array part).

## Why this exists

nbody sits at 23.3× LuaJIT with 67.6% native residency — the traced
inner loop (`advance:34`, 87.5% of its iterations native) costs
~843 cyc/it against LuaJIT's ~36 cyc/it for the whole program. perf
says where it goes: **every named-field access (`bi.x`, `b.vx = …`) in
native code is a full runtime hash probe through the
`resolveHashCell` callout** — `Table.fieldPtr` 24.2% of the run,
`Value.eql` under the probe another ~3.1%, plus the callout's
save/restore of every caller-saved home around each of the ~18 field
accesses per iteration. In total ~30% of nbody's wall clock is spent
resolving hash cells the recorder already knew the location of.

LuaJIT closes exactly this gap with **HREFK** (`lj_record.c:1493`,
`asm_hrefk`): when the key is a constant, record the *node slot index*
observed at record time, then guard cheaply at runtime —
`hmask == K` and `node[slot].key == key` — and use the node's value
cell directly. No hashing, no probe loop, no call. It works for
loop-varying table roots (`bodies[i]`) because same-shaped tables
(same keys, same insertion history) have identical slot layouts, and
the guard side-exits when they don't.

This is a fully general lever (Rule Z-6): every program using tables
as records — nbody, binary-trees nodes, OO-style code everywhere —
pays the callout today, in loads *and* stores (on-trace `hstore`
writes through the same `href` cell, so cell resolution is the shared
cost).

### Why an owned hash part (decision: Bart, 2026-09-16)

The native sequence must read the hash part's keys/values/capacity
inline. mahina's hash part is `std.HashMapUnmanaged`, which keeps
those in a **private `Header` decl** behind the metadata pointer —
inaccessible to `@offsetOf` from our code, with unspecified field
order, in a stdlib we already treat as a moving target (Rule Z-1).
Two routes were put to Bart: (A) keep the std map and reverse-engineer
the Header word offsets at startup via probe maps, or (B) replace the
hash part with a mahina-owned map with a JIT-first extern layout.
**Bart chose B.** Rationale on file: no layout-discovery hack riding
on private stdlib internals; interleaved key/value nodes put a field
access on one cacheline instead of two (std is SoA keys[] + values[]
+ a header indirection); and the JIT's need to reach into the hash
part inline is permanent — HREFK is the first of several accesses
(on-trace insertion, sized grow) that want a layout we control.
Rule Z-2 keeps churn confined to wrappers; this goes one step further
and removes the churning surface from the hot path entirely, which is
Rule Z-7's "fix the foundation now" applied to the table.

## The owned map: `HashPart`

One module, `src/hash_part.zig`, allocator-injected (Rule Z-4).

```zig
pub const Node = extern struct {
    key: Value,   // 16 B, extern (tag @0, payload @8)
    value: Value, // 16 B
};                // 32 B — a 64 B cacheline holds 2 nodes; one node's
                  // key+value never straddle a line (alloc 32-aligned).

pub const HashPart = extern struct {
    nodes: ?[*]Node, // single allocation, capacity power-of-2
    mask: u32,       // capacity - 1; 0 when nodes == null (empty)
    live: u32,       // entries with a live value (the count() answer)
    used: u32,       // occupied slots: live + dead
};
```

### Node states (normative)

| state | key                                     | value    |
|-------|-----------------------------------------|----------|
| free  | tag == nil                              | (unused) |
| live  | the real key `Value` (heap key: pointer)| non-nil  |
| dead  | key tag preserved; **heap-key payload REWRITTEN to the stable `GcHeader.id`**; scalar-key payload kept raw | nil |

The discriminator between live and dead is the value's nil-ness —
there is no tombstone tag, no metadata array, and no new `Tag`
member. Probe termination is "stop at a free slot" (nil key), exactly
the Lua/LuaJIT dead-node model (`lj_tab.c` keeps nodes until rehash).

**Dead heap keys hold no pointer** (codex round-1 item 2): on
`remove` of a heap-keyed entry, the key's payload is rewritten from
the object pointer to the object's stable id, the value goes nil, and
`live` decrements. GC marks **live nodes only** (keys + values); dead
nodes are pointer-free by construction, so a deleted key's object —
and its whole graph — is collectable immediately, with no dangling
deref possible from a later probe. Dead-node key storage is internal:
it is never exposed through the logical API as a `Value`.

Probe matching against a **dead** node compares
`(node.key.tag == q.tag) and (node.key.payload.bits == deadBitsOf(q))`
where `deadBitsOf` is the id for heap keys and the raw payload for
scalars; against a **live** node it is ordinary `Value.eql`. Since
strings are interned and heap `eql` is id-based (doc 02), a
delete/reinsert of the same logical key finds and **resurrects** the
same slot — which is precisely what keeps hrefk slot pins stable
through `t.x = nil; t.x = 1.5` churn. No tag-collision hole exists
between heap id-bits and scalar raw payloads: the tag compares first,
and ids are globally unique within the allocation timeline (codex
round-2).

Two representation-contract details (codex round-2 item 2):

- **Publication ordering.** Deletion writes `value = nil` BEFORE
  rewriting the heap-key payload to id bits; resurrection restores
  the real key `Value` BEFORE publishing the non-nil value. Invariant
  for GC and `emitHrefK`: any node with a non-nil value holds a valid
  live key. (Single-threaded stop-the-world today, but the contract
  is prescribed so the ordering never becomes accidental.)
- **`row_view` keys are rejected at the HashPart boundary**
  (asserted). A row view is tagged non-heap but its raw payload
  contains a parent pointer, so "scalar payload kept raw" would
  smuggle a pointer into a dead node. Consistent with the existing
  "row views never escape" invariant; persistent tables never hold
  row-view keys.

### Two API layers (codex round-1 item 3)

- **Logical layer** (the drop-in `std.HashMapUnmanaged` mirror that
  `table.zig` + the ~14 external sites consume): `get`/`getPtr`/
  `contains`/`remove`/`count` (= `live`)/`iterator`/`keyIterator`/
  `valueIterator` all treat dead nodes as **absent** — `get` on a
  dead node returns null exactly like the std map after `remove`,
  iterators skip free AND dead. `put` with a nil value is illegal by
  contract (asserted): deletion goes through `remove`, matching how
  `Table.set` already routes nil assignments (`table.zig:366`).
- **Internal probe layer** (`hash_part.zig`-private + the named
  crossing points): slot location for insert/resurrect, the GC
  live-node walk, keyframeser's logical live-entry serialization, and
  `Table.hashSlotOf` for the recorder (live slots only, never dead).

### Counter transitions (normative)

| operation                    | `live` | `used`      |
|------------------------------|-------:|------------:|
| insert into free slot        | +1     | +1          |
| overwrite live slot          | 0      | 0           |
| resurrect matching dead slot | +1     | 0           |
| remove live slot             | −1     | 0           |
| remove absent/dead key       | 0      | 0           |
| rehash                       | =live  | := live     |

`guard_absent`'s "hash empty" fast path reads `live == 0`, which
soundly proves every hash lookup yields nil even when `used > 0`.

### Hashing, probing, growth

- **Hash**: the existing deterministic `ValueContext.hash` (splitmix64
  avalanche over `(tag, payload-or-heap-id)`) — unchanged, replay-safe.
- **Probe**: linear, `idx = hash & mask`, step 1, wraparound. No
  metadata/fingerprint array in v1 — field-table hits land on the
  first probe in the common case, and the string-keyed miss-heavy path
  (`guard_absent`) already callouts today. P1b measures whether this
  holds at adversarial loads; the choice is provisional, not a
  conclusion.
- **Growth**: `put` FIRST probes for a live or matching dead slot —
  overwrite and resurrection never consult the load test, so a
  delete/reinsert at the threshold cannot trigger a rehash and defeat
  slot stability (codex round-2 item 3). Only an insert landing in a
  genuinely free slot applies `(used + 1) * 4 > capacity * 3` (75%
  load); on trip, rehash into the smallest power-of-2 capacity with
  `(live + 1) * 4 <= capacity * 3` (overflow-safe arithmetic; dead
  nodes squeezed, capacity can shrink after heavy deletion). Minimal
  capacity 4. Amortised O(1) per insert; layout is a pure function of
  the deterministic hash and the insertion/deletion history.
- **Native contract**: comptime-pinned offsets (`@offsetOf` on our own
  extern structs — no discovery, no asserts against private types).
  `ArrLayout.hash_size` re-points at `live` (guard_hash and
  guard_absent keep their one-instruction `cmp dword [tbl+off], imm`
  shape).
- **Iteration order** is internal-only at runtime: `pairs`/`next` and
  `keyframeser.sortedHashEntries` impose the canonical `key_order`
  sort (doc 02), so probe layout never leaks into observable guest
  order.

Rule #20 analysis: one allocation per map, no per-entry allocations;
get/put O(1) amortised with linear-probe clustering bounded by the
75% load cap; rehash O(n) amortised over ≥ capacity/4 inserts. Known
trade-offs vs the std map, to be measured in P1b rather than assumed
away: full-`Value` compares on occupied probes (no fingerprint
filter), dead-node accumulation until growth, 32 B minimum node reads
for key-only iteration, 128 B floor for a one-entry hash part.

## HREFK: record + lowering

### Recording

In the dynamic-root `href` path (where `seedHashCell` declines because
the root isn't a `slot_load` — e.g. `aload`/`hload`-produced tables),
the recorder additionally asks the observed table for the key's slot:

```zig
// table.zig
pub fn hashSlotOf(self: *const Table, key: Value) ?struct { slot: u32, mask: u32 }
```

**Live slots only** — a dead or absent key returns null and the path
falls back to the callout (which side-exits on miss, as today).

The result packs into the existing `href.aux` (i32) through **one
shared typed encode/decode helper** (codex round-1 item 6) used by
recorder, prover, allocator, and emitter alike:

- `aux >= 0` — entry-seed slab slot (invariant roots; unchanged — a
  once-at-entry resolution beats any per-iteration guard).
- `aux == -1` — no seed, no slot: the `resolveHashCell` callout
  (unchanged fallback; also the path for capacity > 2^20 or slot ≥
  2^20 — LuaJIT caps hslot at 65535 for the same reason).
- `aux <= -2` — **hrefk**: `aux = -(2 + (log2(mask+1) << 20 | slot))`.
  Slot fits 20 bits, capacity log2 fits 5; decode validates
  `slot <= mask`, mask ≥ 3, and rejects malformed log values. The
  encoding keeps the "negative = unseeded" invariant every current
  consumer relies on.

Consumers that must become aux-aware (audited, codex round-1 item 6):
`nativegen_prove.zig:852` (currently requires exactly `aux == -1`),
`nativegen_alloc.zig:1704` (callout save-frame reservation — **an
hrefk href reserves NO callout frame**, or the "no save/restore" win
evaporates), `nativegen.zig:1323` (emit dispatch), and the seed-plan
logic at `nativegen_alloc.zig:1748` (negative == unseeded stays true).

The tier-1a oracle ignores `aux` entirely (it re-resolves via
`fieldPtr`), so tier-1a semantics are untouched.

### Native lowering (`emitHrefK`, replacing the callout)

```
mov  rax, [tbl_home]                          ; *GcHeader == *Table
cmp  dword [rax + HASH_MASK_OFF], K           ; mask guard
jne  exit                                     ; (K >= 3 ⇒ nodes non-null:
                                              ;  empty map has mask 0)
mov  rax, [rax + HASH_NODES_OFF]              ; nodes base
cmp  byte [rax + S*32 + 16], TAG_NIL          ; LIVE-CELL guard: value
je   exit                                     ;   tag != nil (dead/stale)
cmp  byte [rax + S*32 + 0], imm8(key.tag)     ; key tag guard
jne  exit
mov  rcx, [rax + S*32 + 8]                    ; key payload (heap: ptr)
cmp  dword [rcx + GCHEADER_ID_OFF], imm32(id) ; key IDENTITY guard by
jne  exit                                     ;   stable GcHeader.id
lea  dest, [rax + S*32 + 16]                  ; the value cell
```

~9 instructions, 4 loads, no call, no save/restore — against today's
full-home save + SysV call + hash probe + restore per field access.
The exit is the same side-exit the callout-miss path uses today.

Two guards here exist because of codex round-1:

- **Live-cell guard** (item 1). Without it, a store-only hrefk chain
  is unsound: delete the target field (dead node keeps the key,
  `live` N→N−1), insert an unrelated key (`live` back to N) — mask,
  key, and `guard_hash`'s aggregate count ALL pass, and the sunk
  native `hstore` would write through the dead cell without bumping
  `live`, diverging from tier-1a (whose `fieldPtr` oracle rejects
  dead nodes). The value-tag check closes it for loads and stores
  alike; for pure loads it is redundant with `hload`'s typed tag
  check, but store-only chains have no `hload`. Guard order matters:
  live-cell BEFORE key deref, so a dead node (id bits, not a pointer)
  is never dereferenced.
- **Id-compare, not payload-bits-compare** (item 4). Heap `Value.eql`
  is deliberately id-based: keyframe restore gives interned strings
  new addresses (doc 02 §identity-by-id), so a recorded payload-bits
  imm64 would spuriously exit forever after restore. The recorded
  imm is the key's **stable id** (replay-safe by construction — ids
  are the one heap identity allowed in trace IR); the one extra deref
  reads the node key's `GcHeader.id`. Scalar-key hrefk (deferred)
  would compare normalized tag+payload bits directly and skip the
  deref.

### Soundness

- `mask == K` bounds the slot: encode guarantees `S <= K`, so the
  node read is in-bounds whenever the guard passes. Reloading `nodes`
  from the live table each iteration makes same-mask reallocation
  safe.
- Live + tag + id guards passing imply this is the right, live cell
  **regardless of the table's rehash history** — we don't care how
  the key got to slot S, only that it's there, alive, now. If a
  rehash moved the key, the guard exits; if it returned it to the
  same slot, using the current cell is correct.
- The guard passing says nothing about *other* keys — irrelevant: the
  cell is keyed storage, and `hload`/`hstore` only touch this cell.
  The value-type pin stays where it is today (the `hload` tag check /
  consumer `guardNum`).
- `guard_table` immediately before the chain already pins table-ness
  and metatable-absence (`nativegen.zig:1049`), unchanged.
- Constant string keys never migrate to the array part, so the
  rehash-split recompute (`rehash_threshold`) can never move a
  hrefk-pinned key out of the hash part.
- **Spurious exits are safe**: coarse deopt re-runs the iteration in
  tier-0. Only a *missed* exit would be unsound, and every guard is
  re-evaluated from the live table each iteration; stores sink below
  all guards (C1, doc 08).

### Determinism / replay

The serialized trace cache is part of the byte-identical comparison
set (doc 02: "the keyframe, effect log, trace, and stdout are
byte-identical"; the harness compares `traceser.encodeFile` across
independent runs). So `(slot, mask)` in `href.aux` must be — and is —
deterministic for identical execution histories: the layout is a pure
function of the deterministic id-based hash and the guest's
insertion/deletion sequence, identical in all 8 modes and across
independent runs, on both engine targets (u64 math, width-independent).

**Keyframe restore is the subtle case** (codex round-1 item 5,
resolved round-2): today's keyframe serializes live entries in
canonical sorted order, so a restored table's physical layout differs
from the uninterrupted run's — a trace recorded post-restore can
carry different `(slot, mask)` than the same recording in the
original timeline. **This divergence is declared permissible.** It
matches the established snapshot model: keyframes preserve *semantic*
state and reconstruct private runtime-optimization state (array lanes
are recomputed on restore, `keyframeser.zig:723`; `no_grid` is reset,
`gc.zig:403`; `rehash_threshold` is not serialized either, so
physical shaping already diverges after restore today). The
guarantees that DO hold, and are asserted by tests: identical
full executions from source produce byte-identical trace artifacts
(the harness's actual comparison); a restored VM is deterministic
from its restored state; nothing address-shaped enters trace IR on
either side of the boundary; and canonical *observable* order
(pairs/next, sortedHashEntries) is unaffected — it was always a
runtime sort, not a storage order. Preserving every JIT-visible
physical input (slots, dead payloads, counters, `rehash_threshold`,
home-bucket reachability validation) was considered and rejected as
scope without a consumer.

The recorded hrefk immediates are `(slot, mask, tag, id)` — no
address enters the IR (the old callout's imm64 payload embedding
disappears along with the callout on this path).

### What this does NOT cover (recorded, out of scope)

The rest of the nbody profile, for the next arcs:

- **Nested `for_prep` recording** — the outer loops (`advance:4`,
  9.2% of run) abort `nyi_opcode for_prep`; `main:211` (11.7%) aborts
  `aliased_input get_upval`. Outer-loop coverage is its own arc.
- **`replayLedger` seam** — ~1014 cyc/walk, 5.6% of run.
- **Computed (non-konst) keys** — still abort per doc 43 v1 scope.
- **energy/offsetMomentum** — cold, irrelevant.

## P5 — hrefk fallback for seeded hrefs on carried-heap roots (2026-09-18)

### The gap

`hrefAuxFor` prefers the entry seed: when `seedHashCell` accepts a root
(any `slot_load`), the href's aux is the seed slab slot and no hrefk
`(slot, mask)` is ever recorded. But seed validity is decided again at
EMISSION: `computeSeedPlan` deactivates a `hash_cell` seed whose href
root is dynamic (`isDynTableRoot` — a carried-heap slot the body
rewrites each iteration, e.g. nbody's `bi = bodies[i]`), and the emit
dispatch then lowers that href to the per-iteration `resolveHashCell`
callout ("its recorded seed, if any, is ignored"). Result: the one
lowering doc 49 was built to kill — full hash probe + caller-saved
save/restore per iteration — survives on exactly the record-shape where
the root LOOKED invariant to the recorder. Measured (nbody 500000,
post-985110b): 16.7% of the run is `liveSlotOf` reached from these
callouts (6 sites — advance:132's 6 seeded hrefs, ×2 trace copies);
`--dump-traces` shows zero aux=-1 hrefs, i.e. every callout in the
profile is a silently-degraded seed.

### The fix

Record the hrefk encoding alongside the seed, and let emission fall
back to it:

1. **`InputSeed` (`trace_code.zig`)**: new field `hrefk_aux: i32 = -1`
   (`hash_cell` only) — the `HrefAux`-encoded `(slot, mask)` observed
   at record time, `-1` when unavailable (scalar key, encode overflow,
   key not live). Reuses the one shared encode/decode helper —
   no second encoding scheme.
2. **Recorder (`seedHashCell` + its two callers)**: the call sites
   (`recHashGet`/`recHashSet` paths) already hold the observed table
   and key; compute the same `tbl.hashSlotOf(vkey)` →
   `HrefAux.encode` value the non-seeded branch of `hrefAuxFor` uses,
   and pass it into `seedHashCell` for stamping. The dedup map keeps
   the first stamp (same table_reg + key ⇒ same observed table ⇒ same
   hint within one recording).
3. **Emission consumers**: one shared resolution, no per-consumer
   re-derivation — `effectiveHrefAux(t, kinds, slots, slot_id_of_ref,
   idx) i32`: for a dyn-rooted href with `aux >= 0`, look up the
   `hash_cell` seed with `seed.slot == aux` and return its
   `hrefk_aux`; else return `ins.aux` unchanged. Audited consumers
   (the doc 49 round-1 list, same four): `nativegen_prove.zig`
   (as built, prove does NOT gate on the hint — a guarded href with a
   nonnegative seed-slot aux proves as before, and the hrefk-vs-callout
   choice is made later, at allocation/emission, by `effectiveHrefAux`;
   an absent/undecodable hint safely dispatches to the callout — codex
   round-3 corrected the original "admit iff the hint decodes" wording
   here), `bodyCalloutOf` (no save frame when
   the effective aux decodes), the emit dispatch (route to
   `emitHrefK` with the effective aux), and `computeSeedPlan`
   (UNCHANGED — the seed stays inactive; the hint is compile-time
   data, not a slab consumer).
4. **Lowering**: `emitHrefK` verbatim — it already takes the dynamic
   root's per-iteration table pointer from its home and guards
   mask/live/key-id before producing the cell address. Guard failure
   side-exits at the same instruction index the callout-miss exit
   uses today, with the same regs[] contract (hrefk clobbers no homes
   before the exit).

### Soundness

Unchanged from doc 49's hrefk argument: the hint is speculation, the
per-iteration guards are the proof. A stale hint (rehash, different
table shape at this slot, dead cell) fails the mask/key-id/live guards
and side-exits — identical observable behavior to the callout's miss
exit. Tier-0/tier-1a never read `hrefk_aux` (the oracle re-resolves via
`fieldPtr`), so 8-mode equivalence is untouched: native either
produces the identical cell or exits at the same point. Determinism:
the hint is a pure function of the recorded table's layout (itself
deterministic — doc 49 P1's deterministic-layout property), no address
enters the IR (slot+mask only, same as P4).

### Expected payoff (to be measured, Rule #20 / Z-6)

nbody: kills ~16.7%-of-run callout+hash cost, replaced by hrefk's ~7
inline instructions per access — the same trade P4 measured as a win on
the dynamic-root path. General (Z-6): every OO-shaped loop whose
receiver is re-picked per iteration from a container records exactly
this seeded-then-carried shape; P4's hrefk only reached roots the
recorder ALREADY saw as non-`slot_load`. Also removes those pages'
`SEED_HASH_DECLINE` surface (fewer spurious native declines) and
shrinks their callout save frames.

## Review ledger

Codex round-1 (thread `01a0a86c-f747-7db3-95c5-d4b1e3b7c664`,
verdict NEEDS CHANGES — all items incorporated above):

1. Dead-node store-only corruption of `live` → live-cell guard in
   `emitHrefK` + the delete/insert-unrelated differential test family.
2. Dead heap keys vs GC → dead-key id encoding; GC marks live nodes
   only; dead nodes are pointer-free.
3. Logical vs physical presence → two-layer API + normative counter
   table; `put(nil)` illegal; `hashSlotOf` live-only.
4. Heap-key payload-bits compare breaks after restore → id-compare
   lowering.
5. `(slot, mask)` replay stability across restore unproven → P2b
   keyframe geometry preservation.
6. aux packing OK but centralize + audit consumers → shared helper,
   the four audited sites, no-callout-frame classification for hrefk.

Codex round-2 (same thread, verdict NEEDS CHANGES → resolved):

1. P2b geometry preservation dropped — restore-boundary trace-artifact
   divergence declared permissible (precedent: recomputed lanes,
   `no_grid` reset, unserialized `rehash_threshold`); P2b is now a
   contract note + restore test.
2. Publication ordering prescribed (nil value before key-bit rewrite;
   key restore before value publish); `row_view` keys rejected at the
   HashPart boundary (raw payload holds a parent pointer). No
   tag-collision hole in dead-key matching.
3. `put` probes (overwrite/resurrect) before the load test; post-rehash
   sizing formula pinned. Guard ordering in `emitHrefK` confirmed
   sound with no remaining missed-exit hazard.

Codex round-3, P5 only (thread `01a0b400-9ce3-7e71-aa26-ceb0d72d67d2`,
2026-09-18, verdict **APPROVED**):

1. [nit] The P5 §3 "Emission consumers" text overstated the prove pass
   ("admit iff the hint decodes"); as built, `proveKinds` does not read
   `hrefk_aux` — carried-root detection and the hrefk-vs-callout choice
   happen later (allocation/emission via `effectiveHrefAux`), with the
   callout as the safe fallback. Wording corrected in place.

No correctness findings: stale-hint guard ordering (mask/live/key-id
before the href home write, all failures on the href's own exit index,
`rax`/`rcx` reserved scratch), first-stamp dedup vs on-trace rehash
(stores require a present cell; recordable append requires an empty
hash part), synthetic hash-cell slot uniqueness + `.hash_cell` filter
in `effectiveHrefAux`, and single-helper `(slot,mask)` packing
(`HrefAux` + `hrefkAuxOf`) all verified against the code.

Load factor 75% / min capacity 4 / no-fingerprint remain provisional
pending P1b measurements.

## References

- LuaJIT: `lj_record.c` (`rec_idx_key`, HREFK emission ~1493),
  `lj_asm_x86.h` (`asm_hrefk`), `lj_tab.c`/`lj_tab.h` (Node layout,
  nil-value deletion, rehash).
- mahina: doc 43 (hash-field recording), doc 45 (guard_absent), doc 08
  (store sinking / C1), doc 02 (determinism, interning, identity by
  id, key order), doc 04 (keyframe format history).
- Profile: nbody 2026-09-16 — `Table.fieldPtr` 24.2%,
  `Table.set` 9.1% (tier-0), `Vm.indexGet` 9.0% (tier-0),
  `replayLedgerFrom` 5.6%, `arith.eq` 5.4%; `--jit-stats`:
  advance:34 87.5% traced-it, ~843 native cyc/it, seam ~145 cyc/it.
