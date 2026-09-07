# 43 — heap-valued fields, assert, and upvalue stores (tracing the OOP + closure-iterator idioms)

Status: **PARTIAL — P0a/P0b/P0d correctness fixes landed (2026-09-07); P0c
(bridge-exit vs sunk-store) verification outstanding; arc phases P1–P5 not yet
authorized. Two review rounds folded in (codex + technical-architect; ledger at
bottom). The adversarial sweep (a01–a20) is green on all three tiers.**
Owner: Bart
Last updated: 2026-09-07

Prerequisite reading: doc 10 (cross-frame tracing, input seeds, `guard_func`),
doc 11 (hash-field tracing), doc 32 (value-lane scalar access — the exec-log
correction §"Reason (1)"), doc 07 (C1 store-sinking / deopt-replay idempotence),
doc 02 (identity rules: ids, never pointers), doc 23 (RecordedBuiltin
discipline).

## Implementation status

Tracking the gap between this design and master. Tick items as they land; move
to Done once everything inside a phase is checked.

### Done

- [x] **Phase 0a — fix the `recCalleeUpval` open-cell aliasing miscompile.**
      Fail-closed abort (`.aliased_input`) when an inlined callee's upvalue is
      open over a slot at/above the anchor window base (precise anchor-base
      check, not conservative any-open). `anchor_abs_base`/`upval_open` plumbed
      through trace.zig + interp.zig; a01 sweep + regression pass.
- [x] **Phase 0b — fix the global-seed aliasing miscompile.** A recorded
      `hstore`/`astore` into the globals table (via `_G`/`rawset`) after a
      `.global` seed now aborts (`globalsStoreBars`); `rec_globals_header`
      refreshed at Vm.init AND keyframe restore. a02/a03 sweep pass. (Key-level
      refinement deferred — open Q4.)
- [x] **Phase 0d — fix the append double-apply under loop-done replay.**
      `t[#t+1] = v` (length-dependent append) now aborts fail-closed via
      `traceHasAlenOf(rtab)` in `arraySetShape`'s append branch: any `alen` of
      the same table in the trace bars the append. a16/a20 sweep pass; nsieve's
      loop-var-indexed append still records `astore_append` (unaffected).
      Correct native tracing of the push idiom is a perf follow-up.

- [x] **Phase 0c — RESOLVED: composite bridge exits vs sunk stores (pinned).**
      Verified structurally (nativegen.zig:7171–7216 + `emitCompositeBridgeSnapshot`):
      an ARMED composite bridge flushes ONLY slot φs then `jmpMem`s straight to
      the successor — NO tier-0 replay — so a deopt-sunk `astore`/`hstore`/
      `gstore`/`sgm_setpos` (appended below every body guard by `trace_finalize`)
      WOULD be lost on a bridge exit. Empirically the combination arms 0 bridges
      today (a sunk store and a branch-candidate guard never coexist in one
      trace — the sieve's bridge trace has zero store ops), so it is a LATENT,
      not currently-live, miscompile. Made fail-closed and explicit:
      `classifyBridgeCandidate` now refuses candidacy when any store op sits
      below the branch guard (trace_code.zig). Coverage-neutral now (sieve still
      arms bridge=2); pins the invariant against the arc's new `hstore` shapes
      (P1–P3). Regression test §T.9b in `trace_fingerprint_test.zig`.

### Outstanding

- [ ] **Phase 1 — bool-valued hash fields (load + store).** `hload ty=.boolean`
      with fused tag exit; bool `hstore`; native arms.
- [ ] **Phase 2 — function-valued hash fields → method-call inlining.**
      `hload ty=.heap` + body `guard_func`; native checklist: proveKinds
      Pass A + Pass B, body lowering, **and `opMayExitInBody`**.
- [ ] **Phase 3 — table-valued hash fields.** `hload ty=.heap` + `guard_table`
      → dynamic-root `href`/`aref` chain (mirror of the `.value`-lane heap
      `aload`).
- [ ] **Phase 4 — `assert` as a RecordedBuiltin.** `guard_true(arg1)` +
      pass-through; joins the variable-result `all_results` EXCLUSION list;
      fixed-`c` = copy `min(nargs, c)` + nil-pad.
- [ ] **Phase 5 — closed-cell upvalue stores (`uref`/`uload`/`ustore`),
      SCALAR stored values only in v1.** Physical-cell alias classes,
      entry-decline (not downgrade) seed grammar, three-site loop-done flush +
      eligibility whitelist conversion, existing-classifier arms, anchor+callee
      cell sources, wire-format work. Unlocks generic-for iterator closures.
- [ ] **Invariant (P2×P5): `recCalleeUpval`'s slot_load gate is load-bearing.**
      Any P5 cell-resolution path must inherit it unchanged, or `guard_func`
      identity must tighten to closure `GcHeader.id` first (§5).
- [ ] **Open question — P0a scope.** Precise anchor-base aliasing check vs
      conservative any-open abort (measure abort-table fallout on the suite).
- [ ] **Open question — P5 read routing.** Anchor-keyed mutable-upvalue memo
      (abort-once-and-retry) vs always-`uload` for callee upvalue reads.
- [ ] **Open question — P0/arc sequencing.** Land P0a+P0b (+0c if real) as an
      immediate bugfix commit ahead of the arc, or as the arc's first phase.
- [ ] **Defer — heap-valued `ustore`.** Needs a native write-barrier callout
      ABI (rooting, save set, may-it-collect) that doesn't exist; v1 is
      scalar-only, which array3d's `y`/`z` (ints) satisfies.
- [ ] **Defer — `close_upvalues` + on-trace `.closure` creation.** Needed by
      euler14-bit; separate arc (own doc) once this one lands.
- [ ] **Defer — open-cell upvalue stores / SSA-slot redirect.** LuaJIT's
      open-aliasing case (a); v1 records closed cells only.
- [ ] **Defer — prologue hoisting of invariant method loads.** v1 pays
      ~4–5 body instructions per method call per iteration; hoisting is an
      optimization on top of the same IR, not a replacement.

## 1. Why this exists

The 2026-09-07 board (`bench/results/20260907-162347-bf164e8.tsv`) has nine
rows at (near-)zero native residency. `--dump-aborts` decomposes the worst,
array3d (31.1x vs LuaJIT), into one loop we already fixed (the checksum fold —
the eq-vs-nil lever, 49604e1) and one loop that is a **cascade of general
recorder gaps**, every one of them an everyday Lua idiom:

```lua
for x,y,z in arr:points() do   -- iterator closure: reads AND writes upvalues y,z
  arr:set(x, y, z, x*x)        -- method call: `set` is a FUNCTION stored in a table
end
-- array_set body: assert(x >= 0 and ..., "msg")   -- assert
--                 if self.packed then ...          -- BOOL field
--                 local image = self.image          -- TABLE field
--                 self.changed = true               -- BOOL field store
```

The first abort is `nyi_opcode` at the `get_index` of `arr.set`
(`trace_recorder.zig:1842`: hash fields must be int/float); fixing each gap
exposes the next. The abort census across the other zero-residency rows shows
the same gaps are not array3d-specific: `set_upval` blocks scimark-sparse and
(with `close_upvalues`) euler14-bit; host-barrier builtins block str_format and
tbl_ops. Per Z-6 every phase here is a general-idiom lever — metatable-less OOP
(function/bool/table fields), `assert`, and closure iterators — that array3d
merely happens to exercise all at once.

And Phase 0 exists because scoping this arc surfaced **two confirmed live
miscompiles** (§3) in the entry-snapshot machinery — 8-mode equivalence is
broken today on ~10-line programs.

## 2. What LuaJIT does (read from source, `~/Projects/LuaJIT/src`)

Per the house rule: name the technique, read how Pall did it, adapt under the
determinism constraint.

- **Method dispatch** (`lj_record.c:1596-1613`, `:794-827`): `obj:m()` is just
  `TGETS` + `CALL`. The load is a *guarded typed load* — `IRTG(IR_HLOAD,
  IRT_FUNC)`; the call then pins identity with `IRTG(IR_EQ, IRT_FUNC)` against
  the function constant and **replaces the callee slot with the konst**, so
  inlining sees a constant. Three-tier identity: closure konst → proto-only
  (`PROTO_CLC_POLY`) → ffid-only.
- **Booleans are types** (`lj_ir.h:320`): `IRT_TRUE`/`IRT_FALSE` are distinct
  IR types, so a bool field load is `IRTG(IR_HLOAD, IRT_TRUE)` — the tag check
  *is* the value check; the result canonicalizes to a constant and branches
  fold. A flip side-exits on the load's type guard.
- **`assert` records as zero IR** (`lj_ffrecord.c:214-218`): argument type
  guards already exclude nil/false; `recff_assert` just passes all args
  through.
- **Upvalues** (`lj_record.c:1784-1863`): three cases — open aliasing a trace
  stack slot → redirect to the SSA slot (no load/store at all); open elsewhere
  → `UREFO` + an address-window guard proving the cell lies outside the
  trace's stack; closed → `UREFC` (unguarded when the closure is a konst).
  `ULOAD` is type-guarded; `USTORE` is a plain store + write barrier (`OBAR`)
  for GC values. Immutable upvalues constify outright. Alias analysis
  (`lj_opt_mem.c:465-484`) is on the *physical* uref with a per-upvalue
  disambiguation hash — cells shared between closures alias correctly.
- **Invariant hoisting is unroll-copy CSE** (`lj_opt_loop.c:23-89`), not LICM:
  the second iteration's reload + guards CSE against the first and live only
  in the pre-roll. mahina has no unroll pass — v1 pays the per-iteration
  cost and lists hoisting as a follow-up (it is an optimization over the same
  IR, so building the unhoisted form first survives the end state — Z-7).

## 3. Phase 0 — entry-snapshot coherence (BUGS, fix first)

The per-entry input-seed machinery (doc 10) rests on the invariant *"a seeded
value cannot change within one trace episode."* Scoping this arc found the
invariant is enforced only against `set_upval`/`set_global` aborts — but
**recorded stores through aliasing paths break it today**, twice confirmed:

### 3.1 Callee-upvalue snapshot aliasing a trace-mutated register (tier-1a)

```lua
local acc = 0
local function get() return acc end
local s = 0
for i = 1, 100000 do
  acc = i
  s = s + get()
end
print(s)      -- tier-0/native: 5000050000   --trace (tier-1a): 5698404
```

`get`'s upvalue `acc` is OPEN over an anchor-frame local (`Upvalue.Loc.open` =
absolute slab index inside the anchor window). `recCalleeUpval`
(`trace_recorder.zig:3723`) snapshots it per **entry**
(`InputKind.callee_upvalue`); the loop then writes `acc` every iteration as an
ordinary φ-carried register — the snapshot is stale from iteration 2 on.
Depth-0 `recInputGet` cannot hit this (capture plans only name
*enclosing*-frame locals — verified against `compiler.zig:405-420` plus
`recCall`'s non-overlapping frame windows; no coroutines/tail calls exist to
break the stack-growth argument). Only the inlined-callee path can alias the
window. (Why native came out right on this repro needs a decline check during
implementation — likely the page declined and tier-0 ran.)

**Fix (fail-closed):** at `recCalleeUpval`, resolve the *cell* (plumb it from
the dispatch-side pre-resolve at `interp.zig:2404-2415` — today only the
`Value` crosses) and abort when `loc == .open` and the open index falls
at-or-above the anchor frame's absolute base. Scope choice (open question):
precise (`open_index >= anchor_abs_base`; needs new `anchor_abs_base` plumbing
— `anchor_num_registers` is a relative count today) vs conservative (any open
cell aborts; price via a suite-wide `--dump-aborts` sweep). Closed cells stay
recordable (they cannot alias registers).

### 3.2 Global seed aliased by a recorded hstore through `_G` (tier-1a AND native)

```lua
x = 0
local g = _G
local s = 0
for i = 1, 100000 do
  g.x = i
  s = s + x
end
print(s)      -- tier-0: 5000050000   --trace: 5698404   --jit-native: 5698404
```

`_G` hands the program the VM's globals table (`interp.zig:1167`). The
`get_global x` read is snapshotted per entry (`InputKind.global`,
`seedTraceInputs`), while `g.x = i` records as an ordinary `hstore` into that
same table — `set_global` aborting protects nothing, because the mutation
arrives via the hash-store path. Both tier-1a and native diverge (verified
2026-09-07).

**Fix (fail-closed):** the general invariant is *"no recorded store may target
a location an entry snapshot reads."* Cheapest sound enforcement: when
recording a `hstore`/`astore` whose runtime table **is the globals table** and
the trace carries (or later adds) any `.global` seed, abort; symmetrically,
`recInputGet(.global)` aborts if a store to the globals table is already
recorded. Identity check is a pointer compare against `vm.globals` at record
time (record-time-only, never serialized — fine under doc 02). A finer
key-level check (only abort when the stored key collides with a seeded global
name) is a follow-up refinement if the coarse version costs coverage.

### 3.3 Bridge exits vs sunk stores (verification item, possible third bug)

Review (codex round 1) observed: composite bridge exits do not replay the
iteration; their materializer flushes only dominance-safe slot φs
(`nativegen.zig:5914`) and bridge eligibility does not reject traces carrying
sunk heap stores (`trace_code.zig:240`). If a bridge can arm at a guard that a
sunk `hstore`/`astore` was deferred below, the store is skipped — silently.
Whether the existing gating (arm sites, dominance rules) already excludes this
must be established by reading + a targeted repro before P5 adds a third store
kind to the same discipline. If it is live, it is a P0 fix; if not, document
the excluding invariant and pin it with a test.

### 3.4 Append double-apply under loop-done replay (tier-1a AND native)

Found by the 2026-09-07 adversarial sweep (20 shapes, `/tmp/doc43_sweep/`):

```lua
local a = {}
for i = 1, 100 do a[#a + 1] = i end
print(#a, a[101])   -- tier-0: 100, nil    --trace and --jit-native: 101, 100
```

The final iteration's `astore_append` executes on-trace; the loop-done exit
then replays the iteration coarsely and tier-0 appends **again** — the array
ends one element long, with `a[101] == a[100]`. Appends are exempt from C1
sinking ("they change len"); that exemption is replay-safe only when the
re-run is idempotent — nsieve's `p[i] = v` shape is (the replayed store lands
in-bounds on the same slot), which is why the suite never caught it — but a
**length-dependent index** (`#a + 1`) recomputes against the mutated length
and appends a phantom element. Both tiers diverge; every round of a
loop-in-loop shape adds one (sweep a20: +1 per round). Fix direction is
root-caused during implementation: make the final-iteration append replay-
idempotent (sink it into the loop-done flush like other stores, abort the
shape, or make the exit not replay a completed body) — chosen against doc
07's discipline, not ad hoc.

**Sweep boundary pins (safe, to become regression tests):** sunk RMW stores
at loop-done apply exactly once (a17 hash, a18 array); idempotent counting
appends replay harmlessly (a19); two-ref same-table forwarding is correct or
fail-closed (a05/a06/a10); cold-branch mutations re-seed correctly on the
side-exit re-entry (a14/a15 — the mutation must be ON-trace to trigger the
snapshot class); `set_upval`/`set_global` aborts still protect their direct
paths (a04/a08); disjoint array-part stores don't alias string-keyed globals
(a11); cross-entry hash growth is caught by the count guard (a13).

**Common to all of P0:** regression tests pin cross-mode equality on every
divergent repro; all sweep shapes (divergent AND boundary pins) join the test
corpus, the divergent ones additionally the hashgate corpus (`--generate`,
rationale in the commit).

## 4. Phase 1 — bool-valued hash fields

The old objection is two halves, one dead and one real. Dead: "the scalar
exec-log encoder can't take it" — doc 32 already corrected this (the log
silently drops unencodables, is viz-only, and is mutually exclusive with
native; and `effectser.toEffectResult` encodes bools anyway). Real: "there is
no strict bool guard — `guard_true` waves a truthy heap value through." The
answer is LuaJIT's: make the **load's tag check** the strict guard.

- **Recorder** (`hashGetShape`): admit `fv.isBool()` → `hload ty=.boolean`,
  prov-stamped `.field_type/.loaded` like the scalar path; **no `guardNum`**.
  Soften the stale exec-log comment while touching it (doc 32's standing
  instruction). Store side (`hashSetShape`): admit a store value that is a
  konst bool or a ref whose `.ty == .boolean`; anything else keeps aborting
  (the drifting-store-value hole the scalar path plugs with `guardNum`).
- **Tier-1a**: `irinterp` `.hload` `type_ok` gains `.boolean => fv.isBool()`
  (the fused exit — a tag flip side-exits at the load, before any consumer).
  `hstore` needs no change (it writes a whole `Value`).
- **Native**: `proveKinds` `.hload` gains `.boolean => .bool`; lowering
  mirrors the int arm with `TAG_BOOL` + a byte payload load. `hstore` gains
  the bool store arm. `guard_true`/`guard_false` already accept `Kind.bool`.
- **Branches**: `if self.packed` records through the existing `recBranch`
  truthiness guard on a now-bool-proven ref; with a konst-bool store the
  branch folds, LuaJIT-style, for free via the existing konst machinery.
- **C1**: `forwardPendingHashLoad` forwards bool refs unchanged (the value is
  an SSA ref; nothing in the buffer is type-specific) — add the test.

## 5. Phase 2 — function-valued hash fields → method-call inlining

The call side already works: `recCall` takes the callee from the live register
and emits its own `guard_func` (`trace_recorder.zig:2612-2616`). The entire
gap is that `hashGetShape` refuses to define that register from a function
field.

- **Recorder**: admit `fv.isHeap() and fv.heapType() == .function` →
  `hload ty=.heap`, then immediately `guard_func(rload, aux=proto.id)`
  stamped `.callee_identity` (tropt's aux-keyed guard CSE — verified
  `tropt.zig:277-296` — dedups the second `guard_func` `recCall` emits on the
  same ref). `setReg` → `recCall` inlines as today.
- **Identity discipline** (doc 02): proto-id, never a pointer — properly a
  **proto/code guard**, not closure identity. For hload-loaded callees this
  is sound *today* because a method that reads its own upvalues hits
  `recCalleeUpval`'s requirement that the callee ref be a `slot_load` — an
  `hload` ref is not — and aborts `.cross_frame`, fail-closed (gate verified
  watertight under the current frame-window model). **Hard invariant, not an
  open question (review round 1, both reviewers):** P5's cell-resolution
  path must inherit this slot_load gate unchanged; if any later change lets
  an `hload`-loaded callee reach upvalue access, `guard_func` must first
  tighten to closure `GcHeader.id` — otherwise two closures over one proto
  with different cells alias under an instance-blind guard and reopen a
  P0-class miscompile. The existing warning at `trace_ir.zig:220-224` says
  exactly this; the doc elevates it to a landing condition.
- **Tier-1a**: `type_ok` gains `.heap => fv.isHeap()`; the existing
  `guard_func` arm does the function+proto-id check next instruction.
- **Native — four named pieces** (review round 1 added the fourth):
  1. `proveKinds` Pass A: accept a `.heap`-kinded (non-`slot_load`)
     `guard_func` operand (`nativegen.zig:1646-1653` currently rejects).
  2. Pass B: classify the body form (`nativegen.zig:1842-1849`).
  3. Body lowering: inline `header.type == function` + `proto.id == aux`
     cmp + exit — the `guard_table`-on-`aload` precedent
     (`nativegen.zig:6271-6283`); today `guard_func` unconditionally lowers
     to nothing (`nativegen.zig:6250`).
  4. **`opMayExitInBody` (`nativegen.zig:2642`) gains dynamic `guard_func`**
     — it already lists dynamic `guard_table`; without it, carried-home
     coalescing may commit a resumable home before this new exit and a
     failed method-identity guard becomes a partial-iteration register
     commit at the shared deopt flush (`nativegen.zig:7250`).
- **`hload .heap` native lowering**: mirror the `.value`-lane heap `aload`
  (tag==heap check + payload load, `nativegen.zig:2196-2215`).
- **Cost**: `href` is entry-seeded (invariant cell), so the body pays
  hload + guard_func ≈ 4–5 instructions per method call per iteration.
  Acceptable v1; prologue hoisting deferred (§ Outstanding).

## 6. Phase 3 — table-valued hash fields

`local image = self.image` then `image[pos] = p`. Direct mirror of the
`.value`-lane array-of-structs path that already ships end-to-end
(`trace_recorder.zig:1222-1274`, `nativegen_carriedheap_test.zig`):

- **Recorder**: admit table fields → `hload ty=.heap` + `guard_table(rload)`
  (metatable-free check at record time, type+metatable guard at run time).
  Downstream `recArrayGet`/`recArraySet`/`recHashGet` chain from the loaded
  ref exactly as they chain from a `.value`-lane `aload` today.
- **Tier-1a**: covered by the Phase-2 `type_ok` widening plus the existing
  `guard_table` arm.
- **Native**: `hload .heap => Kind.heap` feeds the existing dynamic-table-root
  machinery — body `guard_table`, `href aux=-1` → `resolveHashCell` callout,
  dynamic `aref`. The per-iteration `href` branch already exists unused by
  any producer (`nativegen.zig:2101-2114`, "Phase 2, per-iteration"); this
  wires the first producer into it.
- **P0b interaction**: a table field load that yields the globals table joins
  the §3.2 fail-closed rule like any other handle to it.

## 7. Phase 4 — `assert` as a RecordedBuiltin

mahina cannot get LuaJIT's zero-IR version (our refs don't carry
nil/false-excluding types), but one deduped guard is close enough:

- Add `assert` to `RecordedBuiltin` (append-only ordinal, base-host tier —
  no Z-5 CSV change: recordability is not an inventory column).
- `recBuiltin` arm: arity ≥ 1 else abort; `guard_true(refOf(arg1))` (the
  observed value is truthy — a falsy one would have thrown in tier-0 and
  never reached the recorder). The message argument is evaluated but
  unguarded (only observed on the error path, a side-exit by construction).
- **Result discipline (review round 1, both reviewers):** `assert` returns
  all its arguments, making it structurally a variable-result builtin like
  `select` — it joins the `all_results` **exclusion** switch
  (`trace_recorder.zig:2690-2695`), NOT the fixed-single-result path. For a
  fixed `c`: copy `min(nargs, c)` argument refs to the destination window and
  nil-pad the remainder. `c == all_results` aborts (exclusion list), exactly
  as `select` does today. Zero requested results (`assert(x)` as statement,
  the array3d shape) copies nothing.
- Native/tier-1a: nothing new — `guard_true` exists everywhere.

## 8. Phase 5 — closed-cell upvalue stores (`uref`/`uload`/`ustore`), scalar v1

The iterator closure (`array_points`) reads **and writes** its captured
`y`, `z` every iteration. Facts that shape the design: an open cell's value
lives in a VM slab slot (write-through via `Vm.upvalSet`); a closed cell owns
its `Value` inline; cells are GC objects with stable addresses (non-moving GC,
doc 03) but addresses never survive keyframe restore (doc 02 — so cell
pointers may be *seeded per entry*, never serialized or konst'd). Cells are
**deliberately shared**: two closures capturing one local get one cell
(`interp.zig:5246-5256`), and inherited captures copy the same pointer
(`interp.zig:5237`). In array3d's shape the cells are closed (`array_points`
returned long ago; `opRet` closed its locals). v1 records **closed cells and
scalar stored values only** (int/float/bool — the write-barrier question for
heap values is deferred with its own bullet).

- **Physical-cell alias classes (review round 1, codex — the v1 token rule
  was wrong).** Aliasing is a property of the `*Upvalue` cell, not of the
  `(callee_slot, upvalue_index)` access path: different slots, closures, and
  indices can reach one shared cell. The recorder therefore keys everything
  on the **observed cell** at record time: one alias class (and one `uref`)
  per distinct `*Upvalue`; two access paths that resolve to the same cell
  share the class (MUST-alias), distinct observed cells are NO-alias, and any
  path whose cell cannot be resolved is MAY → abort. Because the record-time
  alias relation must also hold at entry time, each `.upvalue_cell` seed for
  a class carries every access path that mapped to it, and entry validation
  re-resolves **all** paths and declines unless they still agree (same cell,
  still closed). The mutable-read routing (below) is likewise
  alias-class-wide, not per-path.
- **Input kind `.upvalue_cell`, two source shapes (review round 1, codex):**
  a tagged source — *anchor closure + upvalue index* (depth-0 `set_upval`)
  or *callee slab slot + upvalue index* (inlined callee), mirroring how
  `.upvalue` vs `.callee_upvalue` seeds already split. Seeds the cell
  **pointer** into a synthetic slab slot (the `hash_cell` pattern, including
  the tagged-as-int trick so GC scans never mistake it for a header).
- **Entry-failure grammar: decline the ENTRY, not "downgrade to tier-1a"
  (review round 1, codex — the v1 grammar was unsound).** `hash_cell`'s
  downgrade works only because tier-1a ignores the seeded pointer and
  re-derives the cell from `href`'s `(table, key)` operands
  (`interp.zig:943`, `trace_code.zig:39`). `uref` has no operands to
  re-derive from — a zeroed/stale slab pointer would be dereferenced. A
  failed `.upvalue_cell` resolution therefore declines the whole trace
  candidate to tier-0 (`.next_candidate`, the capacity-decline grammar), for
  tier-1a and native alike.
- **IR ops**, mirroring the href/hload/hstore family: `uref` (aux = seed
  slot; invariant token, one per alias class), `uload (a=uref) ty=T` with the
  fused tag exit per observed type, `ustore (a=uref, b=value)`. tropt
  classifies with the existing memory-op discipline (loads verbatim, stores
  as effect roots).
- **C1 integration — the full checklist (review round 1, both reviewers; v1
  named only a subset):**
  1. `PendingStore` gains the op; `finalize` emission
     (`trace_finalize.zig:37-44`) is shape-compatible.
  2. **Existing classifiers get explicit arms**: `forwardPendingArrayLoad`
     (`trace_recorder.zig:1308-1311`) and `forwardPendingHashLoad`
     (`:1354-1358`) are fail-closed on unknown ops — without
     `.ustore => continue` (a cell write can never alias a table slot), any
     mixed trace (P1/P3 field access + P5 stores — array3d's exact shape!)
     aborts `.bad_type` and the arc's own target loop never tiers.
  3. The new `uload` forwarder gets the symmetric `.astore/.hstore =>
     continue` arms, MUST on same `uref`, and fail-closed `else`.
  4. **Loop-done linked-exit flush is a THREE-file lockstep**
     (`trace_code.zig:216-224` eligibility, `irinterp.zig:96-126` tier-1a
     flush, `nativegen.zig:5872-5908` native twin — v1 named only tier-1a).
     Additionally: convert the eligibility denylist and both materializers'
     silent `else => {}` fallthroughs to closed whitelists / fail-fast
     (the `sgm_setpos` precedent at `nativegen.zig:5890-5894`), so a future
     fourth store kind cannot reintroduce this bug class silently. Tests
     cover tier-1a AND native linked loop-done exits with sunk `ustore`s.
  5. `assertWellFormed` and nativegen's sinkable-store map.
  6. P0c's bridge-exit answer gates this phase: if bridges can skip sunk
     stores, `ustore`-bearing traces reject bridge arming until the general
     fix lands.
- **Read routing**: reads of an upvalue whose alias class is *also stored*
  in the same trace must go through `uload` (per-iteration), not the
  per-entry snapshot. Recording is linear, so a read snapshotted before the
  first store to that class is already baked. v1 policy (open question, two
  candidates): abort once and memo the class as mutable in the anchor's
  record-gate state so the retry routes its reads through `uload` from the
  start (LuaJIT-flavoured penalty/retry); or route *all* callee upvalue
  reads through `uload` unconditionally (simpler; costs the read-only common
  case its snapshot hoist). Within one iteration, RMW chains forward through
  the pending-store buffer exactly like hash RMWs.
- **No φ needed**: the trace body is one iteration; each iteration loads,
  computes, stores the cell. Loop-carried-ness lives in the cell, not a φ —
  correct and general; forwarding the load away across the back edge is
  future unroll/hoist work, not v1.
- **Scalar-only stored values (v1)**: `ustore` admits int/float/bool refs
  (konst or producer-typed). This sidesteps the native write-barrier ABI
  entirely for v1 — `heap.writeBarrier` matters only for heap values. The
  tier-1a arm still routes through a helper that keeps the barrier seam
  callable; the native callout ABI (rooting, save set, may-it-collect) is
  specified when heap-valued `ustore` lands, not before (deferred bullet).
- **Doc-39 peel whitelist**: `uref`/`uload`/`ustore` are absent from
  `peelAdmissibleOp` (`trace_recorder.zig:3789-3844`) and stay so —
  fail-closed, loops containing them are peel-ineligible in v1. Known
  coverage cost, same category as the hoisting deferral.
- **Wire format / viz (review round 1, codex):** IR op ordinals are
  serialized and mirrored positionally in the visualizer
  (`viz/src/enums.ts`). New ops are append-only schema changes with codec
  regeneration, enum-name/operand-shape tables, and wire-ordinal tests.
  Traces carrying `.upvalue_cell` seeds are **non-reloadable** in v1
  (`InputSeed` is runtime-only today; a rebindable cell-source recipe is
  future keyframe work) — stated, not accidental.
- **Still aborting, deliberately**: `set_upval` on an *open* cell (the
  LuaJIT SSA-redirect case, deferred), `set_global` (unchanged), heap-valued
  stores (deferred), `close_upvalues` and on-trace `.closure` (the euler14
  arc), stores where the recorder can't resolve the cell (MAY class).

## 9. Costing, order, and what moves when

P0a+P0b are correctness fixes and go first (sequencing vs the arc: open
question — my default assumption is an immediate separate commit, gated like
any other: repro tests, hashgate corpus additions, full gates). P0c is a
bounded investigation with either a fix or a pinned invariant as its output.

Phases 1–5 are independent, individually green, and individually testable via
the abort table — but array3d's iterator loop tiers up only when **all** of
P1+P2+P3+P4+P5 have landed (the cascade reveals each next abort). Expected
per-phase collateral before then: P1/P2/P3 unlock OOP-field loops suite-wide
(nbody's residual, lua54's dispatch), P4 unlocks assert-guarded loops, P5
unlocks scimark-sparse's `random_vector` (its `set_upval` abort) ahead of
array3d.

Every phase carries its native arm (tier-1a-only coverage is ~cost-neutral on
the board — nsieve history: `--trace` 1.20s vs tier-0 0.79s), its recorder
shape tests, cross-mode e2e (`expectProgramTuned`), and the standard gates
(`just test`, hashgate both legs, wasm). Receipts per phase: `--dump-aborts`
delta + `--jit-stats` residency on the affected rows, interleaved A/B timing
only (the 2026-09-07 thermal-phantom rule).

## 10. Open questions for review

1. **P0a scope** — precise anchor-base aliasing check vs conservative
   any-open abort; needs an abort-table sweep to price the conservative
   variant.
2. **P0 sequencing** — immediate bugfix commit(s) ahead of the arc, or the
   arc's first phase.
3. **P5 read routing** — mutable-class memo + retry vs always-`uload`.
4. **P0b refinement** — is the coarse "any store to the globals table +
   any global seed → abort" rule cheap enough on the suite, or is the
   key-level collision check needed from the start?

(v1's open questions on assert discipline and P2 identity were resolved by
review round 1: exclusion list; hard invariant respectively.)

## 11. Review ledger

- **v1 → v2 (2026-09-07, codex `gpt` round + technical-architect round,
  independently):**
  - codex: found + live-confirmed the P0b global-seed miscompile (worse than
    reported: native diverges too, verified here); killed P5's per-token
    alias rule (shared cells) → physical-cell alias classes; killed the
    `.upvalue_cell` tier-1a-downgrade grammar → entry decline; raised the
    bridge-exit sunk-store question (P0c); named `opMayExitInBody` for P2;
    scalar-only v1 for `ustore` (write-barrier ABI deferral); anchor vs
    callee cell sources; wire-format/viz work; assert result semantics.
  - architect: existing `forwardPending…` classifiers fail closed on unknown
    store ops → mixed P1/P3+P5 traces would abort without explicit
    `.ustore` arms (would have silently defeated the arc's own target
    loop); loop-done flush is a three-file lockstep (found the nativegen
    twin v1 missed) + recommends whitelist/fail-fast conversion; elevated
    P2's proto-id argument from open question to hard invariant (the
    `trace_ir.zig:220-224` warning); assert belongs on the `all_results`
    exclusion list; peel-whitelist note. Verified sound: P0a mechanism +
    fix, depth-0 non-aliasing claim, P2 CSE dedup + native precedents,
    conservative-vs-precise trade-off framing.

## 12. References

- LuaJIT: `lj_record.c` (rec_idx 1436–1613, rec_call_specialize 794–827,
  rec_upvalue 1784–1863), `lj_ffrecord.c:214-218` (assert),
  `lj_opt_loop.c:23-89` (unroll-CSE hoisting), `lj_ir.h:320` (bool types),
  `lj_opt_mem.c:465-484` (uref alias analysis).
- mahina: `trace_recorder.zig` (hashGetShape 1825–1880, recCall 2559–2649,
  recBuiltin 2659–2730, recInputGet 3661–3711, recCalleeUpval 3723–3772,
  peelAdmissibleOp 3789–3844, forwardPending 1295–1380), `irinterp.zig`
  (hload type_ok 509–522, loop-done flush 96–126), `nativegen.zig`
  (proveKinds hload 2131–2151, guard_func 1646–1653 + 6147–6172 + 6250,
  opMayExitInBody 2642, loop-done twin 5872–5908, bridge materializer 5914,
  heap aload 2196–2215, dyn href 2101–2114), `trace_finalize.zig:37-68`
  (C1 flush), `trace_code.zig` (InputSeed 39–79, loopDoneSnapshotSupported
  216–224, bridge eligibility 240), `interp.zig` (globals/_G 1167, upvalue
  model 5235–5294, seedTraceInputs 952–999, pre-resolve 2404–2415),
  `function.zig:41-134` (Upvalue/Closure), `viz/src/enums.ts` (wire
  ordinals).
- Docs: 02, 03, 07, 10, 11, 23, 32; abort census §1; board
  `bench/results/20260907-162347-bf164e8.tsv`; repros
  `/tmp/doc43_uvalias.lua`, `/tmp/doc43_galias.lua` (to be checked into the
  test corpus in P0).
