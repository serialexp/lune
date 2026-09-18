# 53 — Open-upvalue slot canonicalization (the `local sqrt = math.sqrt` unblock)

**Status:** complete — P0 landed and measured (nbody 54.5 → 19.8 ms,
11.6× → 4.5× LuaJIT; tier-0-no-trace 35.3% → 0.2%); write-side and
inlined-frame cells deliberately deferred
**Owner:** claude
**Last updated:** 2026-09-18

## Implementation status

### Done

- [x] **P0 — read canonicalization + entry validation seed.** `recInputGet`'s
  open-in-window arm redirects the read to the aliased anchor slot's SSA ref
  (new `refOfAbs`), appends a validation-only `.upvalue_slot_alias` seed, and
  all three seeding twins validate the cell↔slot relation at entry (shared
  `upvalueSlotAliasOk`, byte-identical; tier-1a via the `seedTraceInputs`
  delegate). Tests: record shape (seed fields + aliased-slot `slot_load`, no
  snapshot), per-iteration store visibility, alien-activation refusal —
  each proven to bite by targeted sabotage (validation neutered → refusal
  test fails 25120≠17120; snapshot semantics restored → coherence test
  diverges; abort restored → shape test fails). `just test` +
  `-Djit-debug=true` + JIT boundary check green.
- [x] **P1 — measured.** nbody `--jit-stats` (500k): tier-0 45.2% → 0.3%
  of cycles (no-trace 35.3% → 0.2%), traced 44.9% → 99.2% (native 99.1%),
  steering seam 20.5% → ~0% (499,995 walks → 51), wall 603 → 199 ms.
  `main:211` traces 100.0% of iterations; abort table 4 sites → 1 (the
  by-design LINNER/cross_frame root). Board: **nbody 54.5 → 19.8 ms
  (−63.6%, 11.6× → 4.5× LuaJIT, res 92.9%)**, cross=ok/luajit=ok
  everywhere. Movers vetted ×3 interleaved against an `nm`/behavior-
  verified `just shadow` baseline: tbl_ops/repack/str_format = noise or
  drift; **scimark-fft +3.5% wall in the plain-bench layout is a binary
  code-layout artifact, not a mechanism cost** — every JIT counter is
  bit-identical between binaries (1,016,150 entries, 1,012,995 fused,
  identical iteration splits, identical abort tables) and under
  `--jit-stats` instrumentation the sign flips (NEW 456.6 ms vs OLD
  467.2 ms). The per-entry cost of the new seed-kind branch bounds at
  ~0.5 ms on fft's 1M entries, an order below the delta. The doc 51
  driver-unroll vs decomposed-cycle isolation sweep was NOT needed: on
  nbody the driver trace simply absorbed the nest (advance:34 fell to
  352 traced iterations — warmup only) with no visible competition.

### Outstanding

- [ ] **Defer — `set_upval` canonicalization (the write side).** Same
  conditions, `defineSlotAbs(rel, rval)`; today's open-cell `.nyi_opcode`
  abort in `recSetUpval` is safe. Needs its own φ-writeback/exit-snapshot
  test pass, and `interp.zig` must supply `loc.open` for `set_upval` too.
  No benchmark on the board needs it.
- [ ] **Defer — cells over inlined-frame windows.** Unreachable today
  (requires on-trace closure creation, which aborts — doc 24 territory);
  the arm fails closed on `rel >= anchor_num_registers`. Revisit with
  on-trace closures.
- [ ] **Linked-entry handoff regression test (codex round-1 item 2).**
  Force an armed/fused native→native handoff into a trace carrying an
  `.upvalue_slot_alias` seed and assert the alien-activation decline
  still fires on that path (today it's covered structurally via
  `body_entry`'s shared seed prologue, not by a dedicated test).

## Why this exists

nbody spends 35.3% of its cycles in tier-0 with no trace (fresh
`--jit-stats`, post doc 49 P5): the driver loop `main:211` (19.8%, 500k
it) and the outer nest head `advance:4` (15.5%, 1M it). Doc 51 settled
the strategy: `advance:4`'s root abort at the inner `for_prep` is
working-as-designed (F4, LINNER — the decomposed path covers it), and on
the instrument the **driver-loop trace inlines the whole `advance` call**
(both nests unrolled via `recForPrepLink`'s depth>0 record-through) and,
post Fix A, completes. nbody's driver never gets that far: it aborts at
`ir_len` 95 on `aliased_input get_upval` — the first `sqrt` read inside
the inlined `advance`.

The abort is doc 43 §3.1 (P0a): a `get_upval` whose resolved cell is
OPEN over the trace-writable window (`loc.open >= anchor_abs_base`)
cannot be a per-entry snapshot — an on-trace write to the backing
register would stale it — so recording fails closed. That is the right
verdict for the *snapshot* mechanism, but for exactly this window there
is an exact answer: **the cell IS a tracked slot**. `local sqrt =
math.sqrt` at the top of a chunk plus any hot loop in that same chunk
calling a local function that uses `sqrt` reproduces it — the single
most common Lua performance idiom kills the whole driver trace today.

LuaJIT's `rec_upvalue` (`lj_record.c`) does the corresponding thing: an
open upvalue that aliases an SSA slot of the trace stack redirects reads
to `getslot(J, slot)` and writes to `J->base[slot] = val`, guarded by
`EQ(REF_BASE, uref + k)` — proof that the cell still aliases *this*
frame's slot at execution time. `recSetUpval`'s open-cell comment already
names this as "the LuaJIT SSA-redirect case, deferred". This doc designs
the mahina flavor.

**Generality (Z-6):** this is not an nbody lever. Any trace that inlines
a callee whose closure captured a local of the anchor frame — the
`local f = require(...)`/`local sqrt = math.sqrt` idiom, helper
functions next to their hot caller, every "cache the global in a local"
pattern Lua programmers are taught — currently dies at the first
upvalue read. energy:5/:44 in the same file are the same shape.

## The mechanism

### Recorder (the canonicalization)

In `recInputGet`, the P0a arm (`upval_open >= anchor_abs_base`,
currently `abort(.aliased_input)`) becomes, when ALL of:

1. `rel = open_idx - anchor_abs_base < anchor_num_registers` — the cell
   aliases the **anchor frame's own window**. (Cells over inlined-frame
   windows: abort as today; unreachable anyway, see defers.)
2. `inline_depth > 0` and `upvalAccessPathSlot()` returns a real slab
   slot — the reading frame's closure is re-resolvable at entry (the
   P2×P5 `slot_load`-callee invariant, verbatim). At depth 0 the arm is
   lexically unreachable (a function cannot capture its own locals as
   upvalues; enclosing frames sit below the anchor base), so depth 0
   keeps the abort, fail-closed.

then:

- append a validation-only seed `{ .kind = .upvalue_slot_alias,
  .source = upvalue index, .callee_slot = path_slot, .slot = rel }`
  (dedup on `(kind, callee_slot, source)`; no synthetic executor slot is
  consumed — `slot` here is the *aliased anchor slot*, which is already
  inside every capacity bound);
- record the read as `setReg(dest, try refOfAbs(rel))` — the slot's SSA
  value via the standard lazy machinery (`slot_load` entry input if
  untouched, current def if written, peel φ if peeling). No IR guard, no
  snapshot: within one recording the cell and the slot are the same
  storage, so SSA tracking is exact by construction, including
  read-after-write ordering against anchor-frame stores.

`refOf` is refactored into `refOfAbs(abs)` (the existing body, minus the
`base_off` add) with `refOf(slot) = refOfAbs(base_off + slot)` — the
canonicalized read targets an anchor-absolute index from a depth>0
context, which `refOf`'s frame-relative signature cannot express.

### Entry validation (the three twins)

`guard_func` pins **proto id**, not closure identity — a same-proto
closure from a different live activation passes it while its cell
aliases a *different* frame's slot (LuaJIT guards exactly this relation
per-iteration). mahina's per-entry seed validation is the cheaper
equivalent, valid because the relation cannot change mid-episode (see
soundness). All three twins (`seedTraceInputs`, `nativeSeedFn`,
tier-1a's delegate) run, via one shared helper (the
`resolveUpvalueCellBits` precedent):

```
resolve cv = regGet(base + seed.callee_slot)
cv must be a function closure            else DECLINE
seed.source < cl.upvalues.len            else DECLINE
cl.upvalues[seed.source].loc must be
  .open with idx == base + seed.slot     else DECLINE
(no slab write)
```

DECLINE uses the `upvalue_cell` grammar: the whole candidate declines to
tier-0 (`return null` / `SEED_CAPACITY_DECLINE`) — the canonicalized
slot read has nothing to re-derive from, so no tier-1a downgrade exists.
`computeSeedPlan` keeps the kind in the always-active arm (only
`hash_cell` deactivates), which also preserves the append-order
dependency: the callee's own seed (when the callee was itself loaded
from an upvalue/global) resolves before this seed reads
`slots[callee_slot]`, the `callee_upvalue` precedent verbatim.

### What this unlocks downstream

With the `sqrt` read canonicalized, `main:211` records on through
`advance`: the callee comes from an anchor slot (`guard_func` at the
call site), `recForPrepLink`'s depth>0 record-through + `recForLoop`
unroll the nest (trip counts are stable at nbody=5, the instrument's t3
shape, ~616 instrs there), and doc 51 Fix A keeps the alias guards
honest. Expected effect: the driver trace absorbs `main:211`'s 19.8%
AND the `advance:4` outer-head iterations (15.5%) that structurally
fall out of the decomposed link path, plus the seam those tier-0 rows
currently pay.

## Soundness

- **Within a recording:** cell == slot storage; linear recording makes
  SSA read/write ordering exact. No guard needed for intra-trace
  coherence.
- **Across entries:** the seed re-proves, for the closure the trace will
  actually call (resolved from the same slab slot the trace reads it
  from), that its cell is open over exactly `base + rel`. A same-proto
  closure from another activation whose cell points elsewhere → entry
  declined → tier-0 (correct semantics, no thrash beyond the decline).
  A closure of the *same activation* re-created over the same lexical
  slot passes — and the canonicalized read is then correct for it, too:
  the validation checks the semantic relation itself, not object
  identity.
- **Mid-episode stability:** the relation can only change by the cell
  closing, which happens when its owning scope ends. The owner is the
  anchor frame; the anchor cannot return mid-trace (`ret` at depth 0
  aborts recording / ends the trace), and a scope-exit close inside the
  loop body would require an on-trace closure creation over a
  loop-body local, which aborts (`closure` is not in the record
  switch). A cell observed CLOSED at a later entry fails the `.open`
  check → decline.
- **Callee swap mid-burst:** the callee ref is a loop-invariant
  `slot_load` (the P2×P5 gate rejects computed callees), so natively the
  value is read once at entry — the validated object is the object used
  all burst; `guard_func` still covers proto drift at the call.
- **Single slab:** coroutines are excluded by design (stdlib inventory),
  so `loc.open` indices are all coordinates of one slab and the integer
  relation is well-defined. If multiple stacks ever appear, the
  validation (and P0a itself) must compare slab identity too — noted
  here as the constraint.
- **Determinism / 8-mode:** the emitted IR is plain slot SSA — all tiers
  execute identically; the validation is a pure function of VM state at
  entry, shared byte-identically by the twins; no addresses enter the
  trace (`rel` is lexical, replay-stable).
- **GC:** validation only reads; no new roots, no allocation.

## Measurement protocol (P1)

Doc 51's mandate applies: the driver unroll competes with the decomposed
cycle on exactly this shape, so beyond the normal board + `--jit-stats`
residency split, if the competition is visible on nbody, A/B the three
configurations (normal / unroll off / decomposition off) before drawing
conclusions about either mechanism. Wall-time targets: nbody 54.0 ms →
the tier-0-no-trace 35.3% is the ceiling on the win; `advance:34`'s
9.9% fallback-despite-a-trace and the 20.5% steering seam are separate
(doc 52) territory.

## Review

Codex round-1 (thread `01a0b3fe-0601-7f90-ac5d-7f3ed29e656a`,
2026-09-18, verdict **APPROVED**). Reviewed post-landing (the codex MCP
tool was down in the authoring session; restored via the 0.153.4 pin).
No soundness break found; both attack surfaces flagged above held:
the three seeding twins share one validator (`upvalueSlotAliasOk`,
interp.zig ~1077) on every entry path incl. native `body_entry` and
tier-1a chain reseeding, and mid-episode close-impossibility was
confirmed against the code (`close_upvalues` absent from the record
switch → fail-closed abort; frame returns close only at/above the
returning frame's base). Items:

1. [nit, incorporated] The seed dedup key excludes `rel`, relying on
   the access-path invariant (same `slot_load` callee ⇒ same closure ⇒
   same open cell) to make a repeat hit re-derive the same slot. No
   reachable counterexample today; a `runtime_safety`-gated assert on
   the dedup-hit path now pins `existing.slot == rel` so any future
   widening of callee resolution / on-trace closures fails loudly at
   record time (trace_recorder.zig, `recUpvalSlotAlias`).
2. [question, open] No doc53-specific test forces an armed/fused
   native linked-entry handoff into the seeded trace; the alien-
   activation test covers the ten GC/tier matrix legs but enters via
   the dispatcher. Structurally covered (both native secondary entries
   funnel through `body_entry`'s seed prologue), but a targeted
   linked-entry regression would pin the most fragile entry-path
   claim. Tracked as an Outstanding bullet.

## References

- Doc 43 §3.1 (P0a — the abort this refines), P2×P5 gate
  (`upvalAccessPathSlot`), P5 (`upvalue_cell` seed grammar).
- Doc 51 (nest decomposition diagnosis; F4; the instrument's t3 driver
  trace; isolated-A/B mandate).
- `~/Projects/LuaJIT/src/lj_record.c` `rec_upvalue` (the SSA redirect +
  `REF_BASE` relation guard this adapts).
- `src/trace_recorder.zig` `recInputGet` / `refOf` / `upvalAccessPathSlot`;
  `src/interp.zig` `seedTraceInputs` / `nativeSeedFn` /
  `nativeSeedTier1aFn`; `src/nativegen_alloc.zig` `computeSeedPlan`.
