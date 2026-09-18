# Recurrence-resident silent promotion for short natural-terminal bursts — Design

Status: complete (P0–P2 landed; P2 verdict: mechanism sound, payoff ~break-even — see the P2 correction under the payoff model). Deferred: lean resident epilogue, multi-resident, signature relaxation, per-entry seed re-resolution
Owner: Bart + agents
Last updated: 2026-09-18

## Implementation status

Tracking the gap between this design and what's on the main branch.
Tick items as they land; move whole sections to "done" once everything
inside them is checked.

### Done

- [x] **P0 — recurrence evidence detection.** `RegionDef` recurrence fields
  (signature as parallel scalar arrays + streak + separate probe budget),
  the natural-terminal pure-burst grammar (terminal-class constraint,
  full-ledger child-match, terminal-not-a-candidate check), cheap
  signature-first steady state, deterministic owner resolution
  (min-`RegionId`, both cheap and expensive paths), streak resets in both
  branches of `considerSilentPromotion` (incl. the qualifying-but-unowned
  case), `detectPromotableSetMembers` core with the 2-arg delegate
  unchanged, `-Djit-debug` probes, unit tests on synthetic ledgers
  (`trace_promotion_test.zig` "doc 52 P0: …"). Nothing promotes.

- [x] **P1 — resident promotion with mixed support.** Resident
  authorization branch (`promoteResidentSet` — recurrence-eligible class +
  per-edge membership + shared link-identity validation, no
  accumulator/frozen check), sentinel-keyed set publication behind
  `isResident()`/`isResidentKey` helpers, invariants (one resident set
  globally, `error.PromotionResidentOccupied`; per-`RegionId` uniqueness
  across keyings, `error.PromotionRegionIdOwned`) at the threshold gate
  AND storage-level in `checkPromotable` with distinct reject counters,
  `SilentExitMetadata.barren_exempt` + per-arm epilogue branch (proven end
  to end: a real promoted native a→b→a cycle leaves `cur_zero_run` at its
  staged zero across six link-terminal firings),
  `PROVENANCE_VERDICT_CAP` → `2×PROMOTED_SET_CAP + LEDGER_CAP` (=64, test
  assertion updated), `prepareNativeEntry` / `silentStaging` count-gated
  fast paths + `assertSetCountsConsistent` debug assertions in both
  publication and removal, `driveSilentBurst` per-keying drain (activation
  required iff an activation set fired; barren settlement re-targeted to
  the fired activation set and fail-closed when barren-exhausted with none;
  per-fired-set `transitions_credit` split for both keyings, entry-set
  global credit removed), registry→coordinator resident-demotion notice
  drained in `syncNativeInvalidation` (streak + signature zeroed),
  election-tier reset list + `invalidateRegion` recurrence clears,
  demotion-funnel tests (activation-close skip, deferred/`drainBarrier`
  count timing, defs mutation, trace retirement), threshold-promotion /
  occupied-hold / mixed-drain / resident-only-drain tests
  (`trace_promotion_test.zig` "doc 52 P1: …"). Full gate battery green
  (`just test`, jit-debug battery, ReleaseFast build).

- [x] **P2 — measurement (negative result on the payoff; mechanism
  verified).** nbody `--jit-stats` before/after: promotion fires once,
  stays resident, zero churn; seam −30 cyc/walk vs native +24 cyc/walk →
  **~break-even, nbody +1–2% (edge of noise)** — the pre-arc "20.5% of
  run in the walk" figure was wrong (actual ~1.1k cyc/walk, already
  frozen-cheap). En route, found and fixed a compiler artifact of the P1
  CAP bump — a 1 KiB memset per dispatcher walk from the
  `NativeCallProvenance = .{}` init (+26% fft, most of the +7% nbody) —
  in 985110b. Post-fix full board in band everywhere (fft 329.2,
  nbody 62.8, lu 141.6, sor 81.0, sparse 153.8, grid_matmul 25.1);
  never-qualifying benches show no probe tax. See the P2 correction under
  the payoff model.

### Outstanding
- [ ] **Lean resident epilogue.** If the nbody residual (+1–2%) is worth
  chasing: shed part of the measurement contract (firings/zero-run exact
  accounting) for barren-exempt edges, keeping only what the drain's
  credit split needs. Design question first — not built.
- [ ] **Defer — multiple concurrent resident sets.** v1 caps at one; the
  price of lifting it is a further provenance-capacity re-argument
  (beyond the 2-set sizing v1 already carries) and the demotion notice
  growing from one slot to a list.
- [ ] **Defer — relaxing signature identity.** v1 requires K fieldwise-
  identical qualifying bursts; shape-set equivalence only against a
  measured workload.
- [ ] **Defer — per-entry seed re-resolution.** Out of scope (see "What
  this does NOT fix"); doc 49 follow-on.

## Why this exists

Doc 51's Fix C slot. nbody's `advance()` decomposes into a two-trace closed
cycle (doc 50/51 territory) that already runs **native→native** through armed
links — and still pays a per-call runtime tax that is 20.5% of the whole run.

The measured shape (`--jit-debug` burst dump + `--jit-stats`, nbody 500000):

- 499,995 dispatcher bursts, **99.5% identical**: 8 ledger rows —
  alternating `id=0 loop_done_linked exit=125` / `id=1 link_terminal
  exit=135` (×3, cum 3/5/6), then a terminal `id=1 deopt exit=119
  outcome=normal`, `completed=6`.
- Every burst ends in a **natural terminal** (`.normal` — the loop is done),
  never a forced yield: the ledger drains at 8 rows, a quarter of
  `LEDGER_CAP` (32).
- Each drain runs a full `replayLedger` walk: ~11,861 cycles × 499,995 =
  **20.5% of wall clock** re-walking rows whose jumps were all taken
  natively. The walk is pure accounting; the cycle's execution already
  happened on native code.
- `silent:` counters are all zero — the cycle never promotes, so every armed
  transition materializes a row and every burst pays the walk.

### Why the existing promotion machinery can never fire here

Four gates, each individually sufficient to block nbody, and they compound:

1. **Evidence gate** (`considerSilentPromotion`, trace_link.zig:1113):
   candidacy — and dormant admission (`tryDormantAdmission`,
   trace_link.zig:1219) — require `entries.len == LEDGER_CAP` **and** a final
   `.yielded` row. That grammar encodes "truncation is the volume proof": a
   burst that *hit the ceiling* self-evidences enough drain pressure to
   amortize patching (doc 17 §B3/B4). A burst that ends **naturally** at 8
   rows can never satisfy it, no matter how many million times it recurs.
   The doc-17 record shows the short-burst case was never *rejected* — it
   was never considered; the gate is economic, not soundness
   (`detectPromotableSet`'s doc comment: zero-evidence member promotion is
   already an accepted trade; validation owns correctness).
2. **Dormancy**: nbody's region is fallback-elected (closed SCC, doc 47
   Increment B: `mint … cross_trace_cycle members=2 armable=true`), so it
   mints **dormant** — out of the receipt maps, no activation ever opens
   (`region_profit` count stays 0). Admission needs the same full-cap
   `.yielded` ledger. Blocked by (1) forever.
3. **Economics of admission**: even if admitted, activations open and close
   per call with `work=6 < min_useful=8` (trace.zig:539) — every close is a
   remainder strike (`applyWindowDecision`, trace_regionops.zig:241), which
   feeds `instability` and tombstones the region. The window machinery is
   sized for long-running activations; a 6-iteration recurring activation
   can only lose.
4. **Activation-scoped residency**: promoted sets are keyed by
   `RegionKey{region_id, activation}` (trace_region.zig:44); `closeRegion`
   demotes them (trace_regionops.zig:326) and `prepareNativeEntry` sweeps
   any set whose key isn't the active activation (trace_regionops.zig:387).
   The candidate streak also resets at every `closeRegion`
   (trace_regionops.zig:338). Doc 47 measured the parked-proof reuse cycle
   (promote → close → re-promote) at ~20.5k cycles — **more** than the
   11.9k-cycle walk it would replace. Per-activation promotion is
   structurally unable to pay on per-call regions; only residency across
   activations can.

Per Rule Z-6 this is general, not an nbody special case: *any* program whose
hot cycle is entered through a short recurring call (a per-frame `update()`,
a per-element visitor, nbody's per-step `advance()`) produces exactly this
signature — armed, natively-executing, never-promoted, paying a full ledger
walk per call. LuaJIT has no analogue of this tax at all: its side traces
are patched once and stay patched for the trace's lifetime, with no
per-activation teardown. Residency-across-activations is the
determinism-compatible equivalent of that lifetime.

### What this does NOT fix

The same diagnosis found a second, independent ~19% of nbody: the native
**entry seed prologue**. Every seeded page runs `nativeSeedFn` →
`seedTraceInputs` → `fieldPtr` hash resolution on **every entry kind** —
`linked_entry` and `ordinary_entry` both fall through to `body_entry` and
"a seeded page seeds on EVERY entry kind — this bit is
entry-kind-independent by construction" (nativegen.zig:2652–2655). Armed
*and* silent native→native transitions therefore still re-resolve ~6
invariant hash cells per hop. Promotion does not change transition targets,
so this doc's ceiling is the walk + row-write share (~20.5% on nbody), not
the seed share. The seed cost is a doc 49 follow-on (seed caching /
hrefk-ing invariant entry seeds) and deliberately out of scope here.

## Goals

- A short burst that ends in a natural terminal and recurs **identically**
  across dispatcher drains can promote its member edges to silent, without
  the region ever entering the activation/receipt accounting pipeline.
- Promoted sets born from recurrence evidence are **resident**: they survive
  activation close and are torn down only by the existing safety funnels
  (region invalidation, defs mutation, member slot/trace demotes, teardown)
  — each of which also resets the recurrence proof.
- Near-zero steady-state cost for programs that never qualify: the per-drain
  path is a signature compare against a handful of `RegionDef`s; the
  expensive region-total probe runs only at owner resolution and at the
  promotion threshold, both bounded by a dedicated budget.
- Determinism: every input to the promotion instant is a pure function of
  the deterministic ledger stream and `RegionDef` counters — equal across
  all replay modes, with the same allocation caveat as the existing gate.

## Non-goals (v1)

- More than one live resident set. Forbidden by construction (see "Mixed
  support"); mixed resident + activation firing IS in scope.
- Relaxing signature identity between qualifying bursts.
- Promoting non-fallback (primary-tier) regions through this path.
- Touching the full-cap `.yielded` *evidence* path — it stays as is; the
  recurrence branch is additive. (The full-cap branch does gain one line:
  a recurrence-streak reset — see "Observation universe".)
- Frame-motion edges (`ret_cont`, `call_head`) — still excluded, still
  panic in the drain.
- The entry-seed cost (above).

## Design

### Evidence: recurrence replaces truncation as the volume proof

The full-cap gate's insight is "the burst was *cut off* — there was more".
The recurrence gate's insight is the dual: "the burst was *complete* and the
program immediately did it again, K times, identically". Both are volume
proofs; they differ only in where the volume shows up (within one ledger vs
across consecutive ledgers).

A ledger qualifies as a **recurrent pure burst** for region R iff:

1. `entries.len >= 2` and `entries.len < LEDGER_CAP` (full-cap ledgers
   belong to the existing gate).
2. The final row is a **natural terminal in the strict class**:
   `kind == .deopt ∧ reason == .normal ∧ outcome == .normal` — the same
   precise terminal class `noteDispatcherLedgerTerminal` keys on
   (trace_chain.zig:2972–2987). `.normal` outcome alone is deliberately
   overloaded (trace_exec.zig:254–268; prologue failures and seed declines
   are also `.normal`-outcome terminals) and is NOT sufficient.
3. The final row's `(id, exit)` must **not** resolve to any candidate armed
   edge: an armed chain-source with ledger room dispatches onward
   (nativegen_emit.zig:750–758), so a final row that *is* a live candidate
   edge means the registry and the execution disagree — reject, never
   promote on it.
4. Every **non-final** row satisfies the `detectPromotableSet` per-row
   checks (trace_link.zig:1033–1047): row ∈ region-total armed candidate,
   kind-exact.
5. Child adjacency is checked over the **full** ledger including the
   terminal: for every member row `i` (all `i < len-1`), the matched edge's
   `child.id == entries[i+1].id`. The last member row's successor proof is
   the terminal row's owner — this must not be dropped by slicing the
   ledger before detection.

**This is a new, deliberately weaker grammar than the full-cap one, and the
doc says so explicitly.** In the existing grammar the final `.yielded` row
IS membership-checked (kind-exact candidate member, trace_link.zig:
1033–1044) and is exempt only from *child matching* (trace_link.zig:1045),
because `emitForcedYieldCheck` suppressed its armed jump
(nativegen_emit.zig:765). Here the terminal row is a **non-member**
unpatched exit; its replacement negative proof is (2) + (3) + the child-match
into it from (5). After promotion this row becomes the burst's reporting
suffix (§B3.17 R1) that terminates silence.

Implementation: `detectPromotableSet` grows an explicit
`member_rows: usize` parameter (full-cap callers pass `entries.len`;
recurrence passes `entries.len - 1`) — membership/kind checks run over
`entries[0..member_rows]`, child adjacency over the full slice, plus the
terminal-class and terminal-not-a-candidate checks for the recurrence case.

### Recurrence state: on `RegionDef`, not the activation

`RegionDef` already carries exactly this kind of cross-activation learning
(`admission_failures`, `instability`, `no_candidate_runs`,
`receipts_debit`/`transitions_credit`). Add:

```zig
/// Doc 52: signature of the last qualifying recurrent pure burst, as
/// parallel scalar arrays (id, exit, kind) — parallel arrays, not a struct
/// array, so identity is a fieldwise compare over the initialized prefix
/// and never a byte-compare over padding.
recurrence_len: u8 = 0,
recurrence_ids: [trace_exec.LEDGER_CAP]u32 = undefined,
recurrence_exits: [trace_exec.LEDGER_CAP]u32 = undefined,
recurrence_kinds: [trace_exec.LEDGER_CAP]trace_exec.LedgerKind = undefined,
/// Consecutive identical qualifying observed dispatcher ledgers. Promote
/// at `config.recurrence_promote_after`. Reset by: any observed
/// non-qualifying or non-identical ledger (INCLUDING full-cap ledgers),
/// resident-set demotion (any reason), election-tier flip, invalidation.
recurrence_streak: u8 = 0,
/// Dedicated probe budget (NOT shared with `admission_failures` — short
/// irrelevant bursts must never exhaust the full-cap admission budget).
/// Charged on EVERY expensive probe of this def — owner resolution
/// (successful or not, winner included) and threshold attempts — so that
/// alternating valid shapes cannot buy unbounded armed-registry scans
/// (codex round 2 blocker 2). At `config.recurrence_probe_cap` the def
/// stops being probed entirely (owner resolution AND threshold). Reset
/// only by a successful resident promotion.
recurrence_probe_charges: u8 = 0,
```

Signature rows are `(id, exit, kind)` — the exact fields the grammar
checks. `cum` is excluded so a cycle with data-dependent per-burst
`completed` counts still recurs "identically" in shape; the silent summary
machinery measures dynamic work per firing anyway
(nativegen_emit.zig:819–899), so nothing downstream assumes fixed work.
Comparison covers `[0..recurrence_len]` only; a `recurrence_len == 0` def
has no signature. Nothing here is serialized (transient tiering state).

Storage: ~300 bytes per `RegionDef`; `region_defs` holds a handful of
entries per program.

New config: `recurrence_promote_after` (default 4, floor 1),
`recurrence_probe_cap` (default 64, mirroring
`region_admission_probe_cap`).

### Per-drain flow: signature first, expensive probe rarely

The naïve mirror of `tryDormantAdmission` — full `detectPromotableSet` per
eligible def per drain — is `O(eligible_defs × armed_links)` plus a sort
and a transient allocation per drain (trace_link.zig:996–1051), which
violates the cost goal on programs with many short natural-terminal drains.
Instead the steady state is signature-only:

```
tryRecurrencePromotion(entries):
  if not (len in [2, CAP) and terminal-class check (grammar 2)):
      reset all eligible defs' streaks; return
  build sig from entries (stack, no alloc)
  # cheap match: scan ALL eligible defs (fallback_owner ∧ armable ∧
  # dormant ∧ !tombstoned), collect every stored-signature match, pick
  # the MINIMUM RegionId — never break on first hit: two defs can hold
  # the same signature (overlapping memberships, stale losers), and
  # break-on-first would make the owner depend on hashmap iteration
  # order (codex round 2 blocker 1).
  matched = min-RegionId eligible def with sig == stored signature
  if matched:
      matched.recurrence_streak +|= 1     # saturating: "held at threshold"
      reset every OTHER eligible def's streak
      if matched.recurrence_streak >= recurrence_promote_after:
          # ALL of these gate BEFORE any expensive work (round 2 blocker 3):
          if matched.recurrence_probe_charges >= recurrence_probe_cap: return
          if resident_set_count != 0: return
              # blocked by the one-resident-set invariant: do NOTHING
              # expensive; the saturating streak holds, and the first
              # qualifying drain after the blocker clears runs exactly
              # one detector pass. (A live activation set does NOT block
              # — mixed support.)
          charge matched.recurrence_probe_charges
          full probe: detectPromotableSet(member_rows = len-1)
            + terminal-not-a-candidate check (grammar 3)
          on success → resident authorization + promotion (below)
          on failure (incl. transient allocation failure — inherited
            semantics, same as detectPromotableSet's .cap reject) →
            reset streak (the charge above already counted)
  else:
      # owner resolution — the only other expensive path, budget-bounded
      for each eligible def with probe_charges < recurrence_probe_cap:
          charge def.recurrence_probe_charges        # win or lose
          probe with detectPromotableSet(member_rows = len-1) + grammar 3
          (free the candidate allocation for every non-winning success)
      winner = min RegionId among matches (deterministic; two disjoint
        regions cannot both cover every member row unless memberships
        overlap — same argument as tryDormantAdmission)
      if winner: store sig on winner, streak = 1, reset others' streaks
      else: reset ALL streaks — a qualifying ledger no def owns still
        breaks consecutiveness for every in-progress streak
```

Reject-diagnostic save/restore around probes, as in `tryDormantAdmission`
(trace_link.zig:1236–1244). Charging every probe — including successful
owner resolutions — is what bounds the alternating-valid-shapes case
(A/B/A/B for the same region would otherwise re-resolve, full armed-link
scan + sort + allocation, every drain, forever); with the default cap of
64 a region gets 64 expensive probes per promotion lifetime, then goes
signature-silent until a successful promotion resets the charge. The
expensive probe therefore runs once **per promotion attempt** — owner
resolution on new signatures plus threshold attempts — never per drain.
Steady state (streak building, held-at-threshold, and programs that never
qualify but have short natural drains) is a fieldwise compare + O(defs)
streak-reset writes; bounded, not constant — the many-def adversarial
bench in P2 is the check on the "handful of defs" assumption
(`region_defs` persists for the epoch, trace_region_policy.zig:35–41).

### Observation universe — what "consecutive" means

`considerSilentPromotion` has exactly one production call site:
`driveDispatcherLedger` (trace_chain.zig:3035), reached only for
dispatcher-native multi-row ledgers (interp.zig:4042–4067). Call-A/call-B
walks, the seed-ledger driver, and scalar dispatcher settlements do NOT
pass through it (trace_chain.zig:2608, 2836, 3215, 3152–3170).

The streak is therefore defined as **K consecutive observed dispatcher
multi-row ledgers** — not K consecutive drains of any kind — and the doc
claims no more than that. Resets happen on every *observed* non-qualifying
ledger: the recurrence branch resets on shape mismatch and terminal-class
failure, and the **full-cap branch gains a streak reset** too (a full-cap
ledger for the region is decisive evidence the shape is not a short
recurring burst). The full-cap reset runs at the **top** of that branch,
before `tryDormantAdmission` — resetting all eligible defs' recurrence
streaks before admission can mutate eligibility is the simplest
deterministic ordering. Unobserved drains (call-A/B, seed, scalar)
neither build nor reset the streak.

Why this is safe: recurrence evidence is *economic*, exactly like the gate
it extends. Soundness is owned entirely by promotion validation (edge
membership, link identity, physical exit ownership, enterability) and by
the patch machinery; a promotion admitted on evidence that unobserved
drains would have contradicted executes correctly — silent transitions are
real armed jumps either way — and merely risks being unprofitable, in
which case the demotion funnels and (worst case) region invalidation
bound the damage. The observation-universe narrowing can therefore not
create a correctness hole, only a mis-estimate, and the strict identity
requirement plus the full-cap reset keep mis-estimates rare.

### Residency: sentinel key + explicit helpers

Resident sets are keyed `RegionKey{ .region_id = rid, .activation =
RESIDENT_ACTIVATION }` with `RESIDENT_ACTIVATION = std.math.maxInt(u64)` —
unreachable by real activations (call creation panics long before
`call_seq` could get there, interp.zig:1916). The sentinel is the
**storage representation only**; every policy site goes through explicit
helpers (`PromotedSet.isResident()` / a registry-level
`residentSetCount()`), never a raw `activation == maxInt` compare — codex
round 1's fragility point.

What the sentinel buys at key-equality sites:

- **`closeRegion` → `demotePromotionsForRegion(key)`**
  (trace_regionops.zig:356): full-key match — a resident set's sentinel key
  never equals a real activation's key, so activation close naturally
  skips it. No change.
- **Safety funnels catch resident sets with no change** because none of
  them filter by activation: `invalidateRegion` →
  `demoteSetsForRegionDefsMutation` (wholesale on defs mutation),
  `demoteSetsTouching`/`demoteSetsTouchingTrace` (member slot/trace
  identity), `demoteAllSets`, registry-internal deferred demotions
  (trace_native_registry.zig:810–824) and slot/trace/teardown demotes
  (trace_native_registry.zig:400–475). P1 includes an explicit audit +
  test per funnel.

Sites that must change (each behind the helpers):

- **`prepareNativeEntry`** (trace_regionops.zig:379): sweep predicate
  becomes "activation-scoped set whose key ≠ active key" — resident sets
  exempt. Gated by cached counts (below) so the common cases stay cheap.
- **`promoteSet` authorization**: see next section.
- **`driveSilentBurst`**: see "The drain".

### Promotion authorization: a resident branch, not `promoteSet` unchanged

Codex round 1 blocker, confirmed: `promotionBelongsToRegion` requires a
`region_profit` accumulator and `accum.frozen` (trace_link.zig:959–963) —
a dormant region has neither, by design. The registry-level publisher
itself needs no activation (it validates edges, patches exits, stores the
key — trace_native_registry.zig:605–677).

So promotion splits into shared physical validation + per-path
authorization:

- **Shared** (both paths): per-edge `edgeMemberOfRegion` with bridge stamp
  (trace_link.zig:941), `def.armable`, link/slot/patch identity,
  enterability — everything the registry publisher and the existing
  validators enforce.
- **Activation path** (unchanged): accumulator exists ∧ frozen.
- **Resident path** (new): `fallback_owner ∧ dormant ∧ armable ∧
  !tombstoned` ∧ `recurrence_streak ≥ recurrence_promote_after` ∧ the
  retained invariants below (one resident set; per-`RegionId`
  uniqueness). The region **stays dormant** — it never enters the receipt
  maps; dormant promotion requires no receipt-map membership (confirmed
  against the publisher, registry:605–677).

### Mixed support: resident and activation sets coexist and co-fire

**Decision (Bart, 2026-09-18): mixed support is in scope for v1** — a
resident set and an activation-scoped set may be live simultaneously and
may fire in the same native call. (An earlier revision proposed global
resident ⊕ activation exclusivity; Bart rejected the coarseness. The
review-record entry preserves that history.) Three code facts shape the
design:

- One call-global barren/silent-budget image (`cur_zero_run`,
  `barren_budget`, `silent_budget` in `ExecResult`, trace_exec.zig:150–163)
  that fired promoted edges mutate (nativegen_emit.zig:847–910) and that
  settles into exactly one accumulator (trace_chain.zig:1085–1112).
- Doc 17 sized silent provenance capacity on one live set:
  `PROVENANCE_VERDICT_CAP = PROMOTED_SET_CAP + LEDGER_CAP = 48`
  (trace_link.zig:733–738), overflow a release panic
  (trace_regionops.zig:1072, 1111).
- Registry admission rejects only an exactly-equal `RegionKey`
  (trace_native_registry.zig:598–612), so a sentinel key and a real
  activation key for the same `RegionId` could otherwise coexist.

Retained invariants (enforced at the coordinator authorization sites AND
storage-level in `NativePhysicalRegistry.checkPromotable`, with reject
counters and debug count/list-agreement assertions):

1. **At most one live resident set globally** (multi-resident stays
   Deferred; its price is a further capacity re-argument). A second
   region's streak holds — saturating — until the first set demotes.
2. **At most one live activation-scoped set at native-call time** — not
   new: `prepareNativeEntry` already sweeps every activation set whose
   key differs from the unique active key (trace_regionops.zig:379–390),
   and registry admission enforces one set per exact key.
3. **Per-`RegionId` uniqueness across both keyings**: promotion (either
   path) rejects any live set with the same `region_id` regardless of
   activation — closing the sentinel/real dual-key hole. In practice the
   collision is near-impossible (resident regions are dormant and never
   open activations), so this is a fail-closed backstop with a counter,
   not an expected path.

So at most **two** sets are live at any native call: ≤1 activation +
≤1 resident. The mixed-firing mechanisms:

**(a) Per-edge barren exemption — `SilentExitMetadata.barren_exempt`.**
Barren-run is an *activation-decay* detector; a resident set has no
activation, so its firings must neither advance nor reset the run. The
silent epilogue machine code is compiled once per exit
(`emitSilentEpilogue`, nativegen_emit.zig:788) and reads a per-edge
`*SilentExitMetadata` that promotion allocates and publishes
(trace_native_registry.zig:622) — so the exemption is data-driven: a new
`barren_exempt` field, set at promotion time from the set's residency,
and the epilogue branches around **both** the `cur_zero_run` increment
arms (nativegen_emit.zig:857, 878, 894) and the `reset_zero` store
(nativegen_emit.zig:898–899), jumping straight to `zero_done`. No second
code variant. Cost honesty (codex round 3): the metadata test +
conditional branch execute on **every** promoted firing — activation
edges pay the test too; only the taken bypass is resident-only — which
is why the sensitive-board runs in P2 matter. The budget/barren
exhaustion compares at the tail (nativegen_emit.zig:902–910) stay
unconditional and are provably harmless for exempt edges: the invariant
is **every staged `cur_zero_run` < `barren_budget`** — a non-exhausted
settlement stores a value already proven below the budget
(trace_chain.zig:1101–1112), and an exhausted one writes `max−1` only as
an intermediate step before `noteBarrenConsumed`, whose receipt resets
the accumulator to zero at the bound (trace_region_policy.zig:150). So a
resident edge firing first sees at most `max−1 < max` and cannot trip
`.ae`; only an activation-edge increment can reach the bound, and that
edge's own tail check exhausts first. Exempt edges never *modify* the
run (they do still read it in the unconditional tail compare). Per-arm
branch placement is clean because the kind-switch is compile-time — each
emitted epilogue contains exactly one arm: `.deopt` before the
local-zero test, `.loop_done_linked` before its `jmp reset_zero`,
`.link_terminal`/`.region_bridge` before their increments. The skip
bypasses exactly the increment/reset; `silent_cum`/`silent_active`
publication, first-cell ownership, and all per-cell summary writes
(nativegen_emit.zig:807–845) are before the exemption point and
unaffected. Metadata is fully initialized before pointer-cell
publication and patching (trace_native_registry.zig:625), so adding the
field opens no partially-initialized firing window.

**(b) Drain settlement by keying.** In `driveSilentBurst`'s per-set loop:
an activation-scoped fired set must match the active key and resolve a
frozen accumulator (today's rules, trace_chain.zig:1073–1083); a resident
fired set is exempt from both and instead credits **its own firings sum**
(Σ `cell.firings` over its cells — computable in the existing loop) into
its `RegionDef.transitions_credit` — suppressed-transition units, per the
units note below. The call-global `result.silent_transitions` remains the
cross-check total (trace_chain.zig:994) across both sets. Barren
settlement (trace_chain.zig:1101–1112) re-targets from "the entry set's
accumulator" to "the fired **activation** set's accumulator" — remembered
during the loop; unique by invariant 2; skipped entirely when no
activation set fired. The `origin == .inner_call` first-phase hop
adjustment (trace_chain.zig:1096) and the measured terminal-resume check
(trace_chain.zig:1115+) are keying-agnostic measurements and run
unchanged. The "silent burst outside an activation" panic
(trace_chain.zig:1000) becomes: an activation is required iff an
activation-scoped set fired.

**(c) Provenance capacity re-argument.** Prefix relations come from fired
`sibling_handoff` edges (staged once per fired edge,
trace_regionops.zig:1061–1084); with ≤2 live sets the prefix bound
doubles: `PROVENANCE_VERDICT_CAP = 2 × PROMOTED_SET_CAP + LEDGER_CAP =
64`. The comment's component-sum argument (trace_link.zig:734–737)
updates to match; every overflow path stays release-panicking — the cap
is an invariant, not a truncation.

**(d) Staging and sweep.** `silentStaging`: unchanged semantics — when
`activation_set_count != 0` it resolves the activation and stages its
`barren_run` (existing path); when only resident sets are live it returns
the zero image via the count fast path (resident firings are
barren-exempt, so the staged image is inert for them either way).
`prepareNativeEntry`: sweeps only activation-scoped sets; resident sets
exempt; `activation_set_count == 0` skips activation resolution entirely.

**(e) Parked proofs.** With mixed support, activation promotion is NOT
rejected while a resident set is live, so the round-2 concern about
`takeParkedProof` destroying a non-stale proof on an exclusivity
rejection evaporates — the only remaining rejection cause at that point
is the same-`RegionId` backstop, which cannot fire for a parked proof
(parked proofs come from regions that open activations; resident regions
are dormant and never do). No take-gating needed.

### The drain: per-set rules by keying

`driveSilentBurst` changes, all behind `isResident()` helpers — the
mixed-support mechanism (b) above, restated as the concrete rule set:

- **Panics generalize, not vanish.** "Silent burst outside an activation"
  (trace_chain.zig:1000) becomes "an activation is required iff an
  activation-scoped set fired"; the per-fired-set active-key panic
  (trace_chain.zig:1075) applies to activation-scoped fired sets only. A
  fired activation set with no activation, or with a key ≠ active, still
  panics — nothing gets weaker for the existing path.
- **Credit split per fired set — both keyings** (codex round 3 blocker:
  `creditRegionWork` and `transitions_credit` are different accounting
  systems, and the existing once-per-burst block at
  trace_chain.zig:1135–1141 attributes EVERY call-global transition to
  the entry set's def — under mixed firing that double-counts or
  misattributes no matter which set is the entry). The rule: for every
  fired set compute `set_firings = Σ cell.firings`; if that set's
  `RegionDef` is a fallback owner, add `set_firings` to **that def's**
  `transitions_credit` — resident and activation-scoped alike
  (suppressed-transition units, exactly what the field is documented to
  hold, trace_region.zig:254–261). The entry-set-based global credit at
  trace_chain.zig:1135 is **removed**; the call-global
  `silent_transitions_total`/`silent_hops_total` counters
  (trace_chain.zig:1132) stay call-global. Separately, only
  activation-scoped fired sets run the frozen-accumulator checks +
  `creditRegionWork(region_work)` (trace_chain.zig:1077–1083) — that
  path feeds the activation *window* accumulator
  (trace_regionops.zig:1306), a different ledger. Resident regions'
  `receipts_debit` stays untouched — not in the receipt maps, debit
  genuinely ~0, the net-work invalidation test never fires for them;
  staleness is the demotion funnels' job, not economics'. Activation
  fallback regions keep exact `transitions_credit` (now per-set instead
  of entry-set-attributed), so `chargePayoffReceipt`'s credit-vs-debit
  test (trace_regionops.zig:1205) keeps working on true per-region
  numbers.
- **Barren settlement re-targets.** From "the entry set's accumulator"
  (trace_chain.zig:1085–1088) to "the fired activation set's accumulator"
  — unique by invariant 2, remembered during the loop, skipped when no
  activation set fired. Sound because resident firings are barren-exempt
  at the epilogue (mechanism (a)), so the settled `cur_zero_run` is a
  pure activation-edge measurement even in a mixed burst.
- The measured terminal-resume check (trace_chain.zig:1115+) and the
  per-edge counter rollups (`native_link_exits`,
  `native_loopdone_link_fused`, sibling provenance, …) are
  keying-agnostic measurements and run unchanged.

Hot-path cost: the registry caches two counts — `activation_set_count`
and `resident_set_count` — maintained strictly at **physical
publication/removal**: incremented when a set is actually patched in,
decremented when it is actually unpatched and swap-removed
(trace_native_registry.zig:406) — never when a deferred demotion is
merely *queued* (trace_native_registry.zig:400), since the patches are
still live until `drainBarrier` applies it and the count-gated staging/
sweep fast paths must agree with the patched reality (with debug
count/list-agreement assertions). `silentStaging`
(trace_regionops.zig:395): `activation_set_count == 0` ⇒ return the
zero-run image without the `activeRegionFor` walk + `region_profit`
probe (the +10%-on-pi_leibniz failure mode the code comment documents,
trace_regionops.zig:396–403); otherwise the existing path stages the
activation's `barren_run`, correct in mixed bursts because resident
edges never modify the run (they only read it in the tail compare). `prepareNativeEntry`:
`activation_set_count == 0` ⇒ nothing to sweep (resident sets are
exempt); skip activation resolution.

### Demotion must reset the proof — the notice channel

The doc requires every resident demotion (any reason) to zero the owning
def's `recurrence_streak` (a demoted set's proof must be re-earned against
the post-demotion world). The demotion owner is `NativePhysicalRegistry`,
which has no `RegionDef` access, and several demotions happen entirely
inside registry code: deferred demotions applied in `drainBarrier`
(trace_native_registry.zig:810–824), slot-mutation / trace-invalidation /
teardown / defs-mutation demotes (trace_native_registry.zig:400–475),
trace retirement (trace_registry.zig:55–66). `demoteSetReason` today
resets only the activation-scoped candidate
(trace_native_registry.zig:419–430).

Mechanism: the registry records the demoted resident set's `region_id` in
a **resident-demotion notice** — v1: a single `?RegionId` slot, sufficient
because at most one resident set exists — set by the demote funnel
whenever the demoted set `isResident()`. The coordinator drains the notice
in `syncNativeInvalidation` (already `defer`-called by every trace_link
wrapper around registry mutation, trace_link.zig:1263 et al.) and zeroes
that def's `recurrence_streak` + `recurrence_len`. A notice for a def that
no longer exists is dropped.

Additionally, the election-tier flip reset list
(trace_region_policy.zig:344–358) — which today resets the fallback
learning counters — extends to the recurrence fields, and
`invalidateRegion`/tombstone paths clear them with the rest of the def's
learning state.

### Resident lifetime: tenancy is deliberate, with a named contingency

A resident set has no economic eviction: `receipts_debit` stays 0, no
low-utility verdict exists for it, and a resident set that outlives its
workload phase blocks the resident slot (one-resident-set invariant) for
other recurring regions while keeping the count-gated native-entry path
warm (codex round 2 concern, on record; with mixed support it no longer
blocks activation-scoped promotion). This is a deliberate v1 trade — the safety
funnels bound *correctness* damage, and the whole point of residency is
not paying per-phase teardown — but it needs an acceptance budget, not a
shrug. P2's promote-once-then-unrelated-phase bench is the gate (Rule
#20): the budget is **no measurable regression (≤ noise) on the
unrelated phase**, since both hot paths are one branch + one load behind
the count cache. If the measurement fails the budget, the named
contingency is a deterministic **disuse eviction**: a per-set counter of
observed dispatcher ledgers in which the set fired zero transitions
(counted at the same drain tail — pure function of the receipt stream),
demoting the set at a config threshold; that demotion flows through the
normal funnels, resets the recurrence streak via the notice, and lets the
region re-promote if its phase returns. Not built in v1 unless the bench
demands it.

### Timing note: evidence vs candidate instant

The hook runs at the post-walk drain tail (trace_chain.zig:3031–3035),
after `settleNativeCallProvenance`, deferred disarms, and any pending
region rebuild — a valid mutation safe point (`replay_walk_depth` is 0,
codex round 1 confirmed the ordering at trace_chain.zig:1294–1309). That
means the ledger evidence reflects the **pre-settlement** armed registry
while candidate construction and validation observe the **post-settlement**
registry. This asymmetry already exists in the full-cap path and is an
accepted trade (§B3.18 R5(c), trace_link.zig:982–987): recurrence proves
repeated *execution shape*; final authorization validates the *current*
region-total physical set. Stated here so nobody rediscovers it as a bug.

### What a promoted burst costs at runtime (payoff model)

Today, per `advance()` call: 8 materialized rows + full `replayLedger` walk
(~11.9k cyc). After promotion: 7 member transitions run **silent** (summary
cells only, no rows), the terminal deopt writes the 1-row reporting suffix,
`replayLedger` walks 1 row, `driveSilentBurst` does a bounded rollup over
the set's cells. Expected recovery: most of the 20.5% walk share plus the
row-write share, minus the rollup. The armed jumps themselves are already
native and unchanged — and still pay the seed prologue per hop (out of
scope, above).

**P2 correction (2026-09-18): the model above was built on a wrong input,
and the measured outcome is ~break-even, not a 20.5% recovery.** Kept per
house rules so the stale reasoning stays visible; what P2 actually
measured (nbody 500000, interleaved ReleaseFast A/B vs P0 HEAD~1, both
`--jit-stats`):

- **The pre-arc "~11.9k cyc/walk = 20.5% of run" figure was wrong.** The
  dormant region's 8-row ledgers were already receipts-inert/frozen-cheap:
  the real walk cost at the P0 baseline is **~1,081 cyc/walk** (540.6M cyc
  = 17.3% of run for the whole steering seam, of which the walk is one
  part). The 20.5% prize this doc was sized against does not exist; the
  recoverable share was always the row-write + short-walk delta, a few
  percent of the seam at best.
- **The mechanism works exactly as designed**: rid=0 qualifies at 4/4,
  promotes one 2-edge RESIDENT set, stays resident for the whole run, zero
  churn (`--jit-debug` confirms one owner-resolve, one promotion, no
  demotions).
- **Measured economics, memset artifact removed (see below)**: seam
  1,081 → 1,050 cyc/walk (−30 cyc/walk — the 8-row frozen walk becomes a
  drain rollup + 1-row suffix); native +24 cyc/walk (silent-epilogue
  exact accounting — cell/zero-run bookkeeping plus the 2-instruction
  `barren_exempt` branch — replacing the cheap ledger-row write). Net:
  **~break-even**; interleaved wall shows nbody at +1–2% of the P0
  baseline, at the edge of the noise band (board best-of-5: 62.8 ms vs
  62.1–62.4 prior).
- **The +7% nbody / +26% scimark-fft wall regressions initially blamed on
  this design were a compiler artifact, not the mechanism.** Raising
  `PROVENANCE_VERDICT_CAP` 48 → 64 pushed `@sizeOf(NativeCallProvenance)`
  to 1032 bytes, which flipped the aggregate `= .{}` init past the
  undef-elision threshold: every dispatcher walk began paying a full
  1 KiB zero memset (19.9% of the fft profile; fft promotes nothing and
  regressed anyway, which is what exposed it). Fixed in 985110b
  (`undefined` init + explicit `len = 0`; field defaults removed so
  `.{}` is a compile error). Post-fix boards: fft 329.2 (band 322–340),
  lu 141.6, sor 81.0, sparse 153.8, grid_matmul 25.1 — all in band.
- **Adversarial cost is unmeasurable** on the full board: never-qualifying
  benches (pi_leibniz 36.8, field_hash 13.0) show no probe/streak tax.

The honest verdict for doc 51 Fix C: the seam this fix targeted was
already an order of magnitude cheaper than diagnosed, and what the
resident set saves on the walk it pays back in exact epilogue accounting.
A future lever, if the residual matters: a **lean resident epilogue**
(skip the firings/zero-run measurement contract for barren-exempt edges,
keeping only what the drain's credit split needs) — a design question on
how much of the measurement contract residency may shed, deliberately not
built in this arc.

### Determinism

Every promotion input is deterministic: ledger row contents, `RegionDef`
counters and signatures (fieldwise compare over the initialized prefix —
never a byte compare over possibly-padded storage), armed-link registry
state, min-`RegionId` tie-breaks, config thresholds. No clock, no address.
The one caveat is inherited unchanged from the existing gate: the
threshold/owner probes allocate their candidate result
(trace_link.zig:1049), so an OOM at that instant changes whether a region
matches — the same failure surface `detectPromotableSet` already has, not
a new one. The signature-first steady state is allocation-free, which is
precisely why the expensive probe is confined to two rare instants.

## Phasing

- **P0 — evidence only.** RegionDef fields (parallel arrays + streak +
  probe budget + config), `detectPromotableSet` `member_rows` parameter
  (full-cap callers pass `len` — behavior-identical), the recurrence
  grammar (terminal class, terminal-not-a-candidate, full-ledger
  child-match), signature-first flow + owner resolution, streak resets in
  both `considerSilentPromotion` branches, dbg probes (`recurrence:
  qualify rid=… len=… streak=k/K`, `recurrence: owner-resolve …`,
  `recurrence: probe-cap …`). Unit tests: qualifying/non-qualifying
  ledgers (incl. prologue-fail and seed-decline terminals rejected),
  armed-terminal rejection, last-member→terminal child-match, streak
  reset on shape change and on full-cap, min-id winner, probe-budget
  saturation, full-cap path untouched. Nothing promotes — land green.
- **P1 — resident promotion with mixed support.** Sentinel key +
  `isResident()` helpers, resident authorization branch, retained
  invariants + reject counters (one resident set; per-`RegionId`
  uniqueness — coordinator + storage-level `checkPromotable`),
  `SilentExitMetadata.barren_exempt` + epilogue branch around the
  zero-run increment/reset, `PROVENANCE_VERDICT_CAP` →
  `2×PROMOTED_SET_CAP + LEDGER_CAP` with updated comment argument,
  registry set-count cache with debug count/list-agreement assertions
  (publication, unwind, queued demotion before/after `drainBarrier`,
  swap-removal, teardown), `prepareNativeEntry`/`silentStaging` fast
  paths, `driveSilentBurst` per-keying drain (barren settlement
  re-targeted to the fired activation set's accumulator; per-fired-set
  `transitions_credit` split for both keyings with the entry-set global
  credit removed; `trace_provenance_test.zig:567` capacity assertion
  updated to the two-set formula), resident-demotion notice +
  `syncNativeInvalidation` drain, election-tier + invalidation resets,
  per-funnel demotion tests (deferred, slot, trace, teardown,
  defs-mutation, rebuild, retirement), same-`RegionId` dual-key
  rejection, mixed-burst drain tests (resident-only, activation-only,
  both fired: barren purity + per-set credit split + provenance at the
  2-set bound), held-at-threshold behavior tests, 8-mode equivalence,
  full gate battery.
- **P2 — measurement + docs.** nbody `--jit-stats`/`perf` before-after;
  adversarial benches per Rule #20: (a) many short natural-terminal drains
  that never qualify (probe/steady-state cost, many-def `O(defs)` reset
  writes), (b) promote-once then run unrelated native traces (entry-tax,
  against the ≤-noise acceptance budget — disuse eviction is the named
  contingency if it fails), (c) alternating shapes A/B (must show
  probe-cap saturation, not per-drain expensive probes); sensitive boards
  (scimark-sparse, grid_matmul, scimark-lu) unregressed; full board; tick
  doc 51 Fix C; update this doc.

## Open questions for review

1. **Dormant-only, or any fallback region?** v1 gates the probe on
   `d.dormant`. A short-activation *admitted* region (blocked by gates 3–4
   but not 2) would also benefit, but mixes resident sets with live
   activation accounting on the same region — same-region mixing is a
   step beyond the cross-region mixed support v1 carries. Defer?
2. **Streak reset scope**: a program alternating two burst shapes A/B for
   the same region never promotes either (each drain resets the other
   sig's streak) — and, per the probe-charging rule, saturates its probe
   budget and then goes signature-silent. Accepted as conservative v1;
   tracking last-N signatures is the escape hatch if a real workload
   shows this.

### Resolved

- **Exclusivity vs mixed support** — Bart, 2026-09-18: mixed support in
  scope now. The design carries per-edge barren exemption, the drain's
  per-keying rules, and the 2-set provenance capacity (see "Mixed
  support"). One-resident-set and per-`RegionId` uniqueness remain.
- **`recurrence_promote_after` default** — Bart, 2026-09-18: 4, matching
  `promote_after`.

## Review record

- **Codex round 1 (2026-09-18)**: 6 blockers, all folded in above —
  resident authorization branch (promoteSet could not run unchanged:
  accumulator/frozen requirement, trace_link.zig:959–963); exclusivity
  invariants (barren-image ABI, provenance capacity, one-set-per-RegionId
  via full-key-only admission); grammar corrections (terminal class
  `deopt/normal/normal`, terminal-not-a-candidate, full-ledger
  child-match, and the factual fix that the existing `.yielded` row is
  membership-checked and only child-match-exempt); observation-universe
  definition + full-cap streak reset; registry→coordinator demotion
  notice; separate probe budget + signature-first cost structure.
  Concerns adopted: fieldwise/initialized-prefix signatures, adversarial
  benches, timing note, test list. Nits: `LedgerKind` (not
  `LedgerRowKind`), softened cost claims.
- **Codex round 2 (2026-09-18)**: confirmed 4/6 round-1 blockers resolved
  (authorization, exclusivity, grammar, observation universe; demotion
  notice verified against every production demote path — all reach
  `syncNativeInvalidation`; final `TraceState.deinit` teardown benign).
  3 new blockers in the signature-first flow, folded in: (1) cheap match
  must scan all defs and pick min-`RegionId`, never break-on-first
  (hashmap iteration order); (2) probe budget charges EVERY expensive
  probe including successful owner resolutions — renamed
  `recurrence_probe_charges` — so alternating valid shapes saturate
  instead of scanning forever; (3) threshold path gates on probe cap AND
  exclusivity before any expensive work, with saturating
  held-at-threshold streaks. Concerns adopted: parked-proof take gated on
  resident exclusivity (never destroy a non-stale proof), storage-level
  invariant enforcement in `checkPromotable`, resident-tenancy acceptance
  budget + disuse-eviction contingency, suppressed-transition credit
  units, count-cache assertions, full-cap reset ordered before dormant
  admission.
- **Bart decision (2026-09-18)**: rejected the v1 resident ⊕ activation
  exclusivity in favor of full mixed support now; the exclusivity design
  (and its parked-proof take-gating, which mixed support obsoletes) is
  preserved in this record. `recurrence_promote_after` default confirmed
  at 4. The "Mixed support" section replaced the "Exclusivity" section:
  per-edge `barren_exempt` metadata + epilogue branch, drain settlement
  by keying with barren re-targeted to the fired activation set,
  `PROVENANCE_VERDICT_CAP = 2×PROMOTED_SET_CAP + LEDGER_CAP`.
- **Codex round 3 (2026-09-18)**: mixed design confirmed structurally
  sound — barren exemption implementable per-arm (compile-time
  kind-switch, one arm per emitted epilogue; shared summary writes
  unaffected), tail-compare harmlessness argument verified (staged run
  always < budget; `barrenReceipt` resets at the bound,
  trace_region_policy.zig:150), drain entry/last-set measurements
  keying-agnostic (first/last cells may already belong to different
  sets, trace_chain.zig:956/1005), capacity 64 conservative for ≤2 sets
  (prefix appends are per fired sibling cell, not per firing). One
  blocker, folded in: per-fired-set `transitions_credit` split for BOTH
  keyings + removal of the entry-set global credit (trace_chain.zig:
  1135) — `creditRegionWork` (window accumulator) and
  `transitions_credit` (lifetime payoff ledger, chargePayoffReceipt at
  trace_regionops.zig:1205) are different systems and must both stay
  exact. Concerns folded in: counts change only at physical
  publication/removal (never queued demotion); epilogue-cost claim
  corrected (test runs on every promoted firing); barren invariant
  rephrased. Nits: capacity assertion in trace_provenance_test.zig:567
  updates to the two-set formula; "never modify" wording.

## References

- `docs/design/51-nest-decomposition-diagnosis.md` — Fix C slot, the nest
  decomposition diagnosis this doc completes.
- `docs/design/47-f64-array-append.md` — dormant minting, admission,
  instability, net-work ledger; the "resident-but-disabled patches"
  direction this converges with.
- `docs/design/17-exit-branch-patching.md` (§A/§B) — region model,
  promotion grammar, §B3.17 R1 reporting suffix, §B3.18 R5 accepted
  trades, provenance capacity sizing.
- `src/trace_link.zig` — `considerSilentPromotion`, `detectPromotableSet`,
  `tryDormantAdmission`, `promotionBelongsToRegion`.
- `src/trace_regionops.zig` — `closeRegion`, `applyWindowDecision`,
  `prepareNativeEntry`, `silentStaging`, `invalidateRegion`.
- `src/trace_chain.zig` — `driveDispatcherLedger` (hook point),
  `driveSilentBurst` (drain), `noteDispatcherLedgerTerminal` (terminal
  class).
- `src/trace_region.zig` — `RegionKey`, `RegionDef`.
- `src/trace_native_registry.zig` — set storage, admission, demote
  funnels.
- nbody measurements 2026-09-17/18: burst dump, `--jit-stats`, perf tier
  rollup (CURRENT_TASK.md latest+19 and this arc's notes).
