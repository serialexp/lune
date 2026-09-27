# 57 — Native booleans (value-specialized `nil`/`true`/`false` inputs)

**Status:** design rev 4 (Bart picked Option B, LuaJIT's model); reviewed
twice (Antigravity: r1 CHANGES REQUESTED, r2 APPROVE WITH CHANGES), all
findings folded in — not implemented
**Owner:** claude
**Last updated:** 2026-09-27

## Implementation status

### Done

- [x] Bart picked the model (2026-09-27): **B — value specialization**, as
  LuaJIT does (§3).
- [x] Review r1 (Antigravity): CHANGES REQUESTED, 8 findings, all accepted
  and folded into rev 3 (`docs/reviews/doc57/antigravity.md`).
- [x] Review r2 (Antigravity) on rev 3: APPROVE WITH CHANGES, 5 findings, all
  accepted and folded into rev 4 (same file).
- [x] P1 — IR + recorder + tier-1a (2026-09-27). As built:
  - Ops `guard_is_nil/false/true` at wire ordinals 90–92 (aux = recording
    pc); helpers `primPinValue/primPinOp/primPinPasses` in `trace_ir.zig`.
  - `pinPrim` in the recorder pins `slot_load`/`phi` inputs and returns a
    konst; used by branches, `not`, `eq`/`ne`, array/hash/upvalue stores,
    `type`/`math.type`/`tostring`. `boolTyped` admits the typed producers.
  - Close check in `loopCloseSelfDefeating` aborts `type_instability` when
    a carried value no longer passes its pin.
  - Entry fingerprint: `EntryGuardType.nil/false_/true_` + `accepts(v)`.
  - Tests: `src/interp_bool_test.zig` (11, mutation-checked); two older
    tests rewritten for the new behaviour (the fingerprint polarity test
    now uses a compare result as its falsy operand; the "unproven bool
    store aborts" hash test now expects the pin + store).
  - Tier-1a runs the pins; native does not yet (a trace with a pin still
    stays on tier-1a / falls back until P2).
- [x] P2 — native (2026-09-27). As built:
  - `proveKinds`: Pass A records each slot_load's pin (`pin_of`; two
    different pins on one load bail) and types an internal φ's slot_load
    init `.bool` (`bool_init`). Pass B: pinned load → `.bool`/`.nil`;
    `guard_is_false/true` need `.bool`, `guard_is_nil` a `.nil` slot_load;
    `not` `.bool → .bool`; `eq/ne` `(.bool, .bool) → .bool`; an unknown-ty
    internal φ over a `.bool` init is `.bool`. `operandReads` lists `not`
    and the pins.
  - `nativegen_alloc`: `SlotInfo.pin` (the pinned payload) and `pin_only`
    (invariant pinned slot read only by its own pin → no home). A carried
    `.bool` is admitted (RV-3 still demands a `.bool` update; a `.nil` is
    never carried). `pinHoisted` (operand is an invariant slot's load) is
    shared by the lowering and `opMayExitInBody`. `not` is a transient.
  - Prologue: `TAG_BOOL`/`TAG_NIL` tag rows; an invariant bool pin also
    compares the payload (`cmp qword [rsi+slot*8], 0/1`). A `pin_only` slot
    skips the payload load.
  - Body: a hoisted pin and `guard_is_nil` emit nothing; a carried/φ pin is
    `cmp home, 0/1; jne exit`. `not` is `xor 1` (new `xorRegImm32`
    encoder + encoding test). Bool `eq/ne` uses the int compare.
  - Exits: the precise flush rebuilds a `pin_only` slot captured for
    another slot from its pin (`pinnedValue`), and flushes a homed `.nil`.
    The doc 56 exit map gives a `pin_only` load no place (an adapter
    restoring its own slot skips it; any other use fails closed).
  - Tests: `src/nativegen_bool_test.zig` (6: invariant pin_only true/nil,
    copied pin keeps a home, carried body compare incl. mid-run exit,
    `not`/`eq`/`ne`, bails). Mutation-checked: dropping the prologue
    payload compare fails 4 tests (incl. the interp flag-changes-value
    test — the fingerprint alone does not cover every entry); dropping the
    carried compare fails 2; `xor 0` fails 2.
  - Probe (`--jit-stats`): shape A (`if flag`) 99.9% native at ~4 c/it;
    `t[i] = f` / `u[i] = g` / `if t[i] and not u[i]` 0% → 99.9% native.
  - Review r3 (Antigravity) on the P2 commit: no soundness bugs
    (`docs/reviews/doc57/antigravity.md`).
- [x] P4 — tests + measurement (2026-09-27).
  - Tests: `interp_bool_test.zig` asserts on the native leg that every
    trace holding a pin (shapes A, F, nil, carried compare) or a `not`/bool
    `eq` (D, E) compiled (`expectNativeHolds`; mutation: rejecting `not`
    in `proveKinds` fails it). The §5 mutation list is covered (payload
    compare, `xor`, close check).
  - Board (`bench/results/20260927-094715-4d3595c.tsv`): no regression;
    ×3 interleaved A/B vs the P1 shadow build is noise-level on every row
    checked. nsieve (doc 56 switch off) unchanged, 0.04 s.
  - nsieve with the doc 56 switch ON: +30% (0.82 → 1.08 s). Its exit-side
    child now compiles native and each of 4.4M hops pays the runtime seam
    (`accountRegionProfit`, `driveChain`) — tracked in TODO.md for doc 56
    Phase 6, not a doc 57 defect.
  - Shape B (flipped carried bool) still aborts `type_instability` → P3.
  - Shape C (a compare-result branch that flips for good) is the doc 56
    Phase 6 case already in TODO.md, not a bool gap.

### Outstanding

- [ ] P3 — instability unroll (LuaJIT `instunroll`) for the flipped carried
  bool. Own investigation first (§4.7).

## Why this exists

Five of six small boolean loops never run as native code (probe from the doc 56
Phase 5 findings, `TODO.md`):

| shape | today | where it stops |
| --- | --- | --- |
| A `if flag then` (invariant bool local) | tier-0/1a | untyped `slot_load` in `proveKinds` |
| B `b = not b; if b` (carried bool) | tier-0/1a | untyped `slot_load` + `not` has no native kind |
| C `local lt = i < 500; if lt` | native | — (compare result is already `.bool`) |
| D `if t[i] == true` | no trace | recorder aborts `bad_type` in `recEq` |
| E `if not t[i]` | tier-1a | `not` has no native kind |
| F `t[i] = flag` (bool-lane store of a local) | tier-0/1a | bool-lane `guard_fits` proves no kind |

This is general native coverage, not a benchmark lever. It also blocks doc 56's
switch: nsieve's exit-side child (`p[i] = true`, with `true` held in a register)
never compiles, so that exit never arms.

## What we have today

- `Kind.bool` exists in the native backend: a 0/1 payload in a GP register.
  Compare results (`eq/ne/lt/le`), bool-lane `aload`, bool `hload` fields and
  bool konsts produce it. `guard_true`/`guard_false` on `.bool` lower to
  `cmp` + `jcc`. `flushSlot` boxes `.bool` as `TAG_BOOL` + payload.
- There is **no guard that pins a boolean or nil**. The recorder says so
  (`recEq`: "bool/nil/heap have no strict type guard to pin them";
  `recHashSet` aborts an unproven bool store value). `guard_true`/`guard_false`
  pin truthiness, not type. So a `slot_load` holding a bool or nil never gets a
  native kind.
- Gaps found while reading, all fixed by this doc:
  1. `proveKinds` Pass A has no proof for a bool/nil `slot_load` (the bool-lane
     `guard_fits` arm: "no bool_guarded array exists").
  2. The native prologue tag switch has no `TAG_BOOL`/`TAG_NIL` row; its
     `else` arm checks `TAG_INT`. Harmless today only because no slot can be
     `.bool`.
  3. `nativegen_alloc` refuses a carried `.bool` slot (RV-4) and a
     write-dominated `.bool` slot (same missing row).
  4. `not` has no arm in `proveKinds` or the lowering.
  5. `recEq` aborts when neither side is a number, unless both are konsts.
  6. `EntryGuardType` (the dispatcher's entry fingerprint) has no bool/nil.

## How LuaJIT does it

`lj_record.c`: `nil`, `false` and `true` are separate IR **types** (`IRT_NIL`,
`IRT_FALSE`, `IRT_TRUE`). Every `SLOAD` is type-guarded, so a primitive slot is
specialized on its *value*. Then:

- `BC_IST`/`BC_ISF` (the `if`): "Type specialization suffices" — nothing is
  emitted.
- `BC_NOT`: "Type specialization already forces const result" — a constant.
- `BC_ISEQP` on primitives: `lj_record_objcmp` folds.
- A loop-carried value whose type differs at the loop end (the flipped boolean)
  fails `lj_opt_loop` with `LJ_TRERR_TYPEINS`/`GFAIL`; `lj_opt_loop` then
  **keeps recording** another iteration ("Unrolling via recording fixes many
  cases, e.g. a flipped boolean", bounded by `instunroll`, default 4).

Our bytecode differs in one way: `eq/lt/le` write a boolean into a register (no
fused compare-and-branch), and we compile that to `setcc` → dynamic `Kind.bool`.
So dynamic booleans stay in our traces for *producer* results (compares, bool-
lane array loads, bool hash fields). Value specialization applies to the
*untyped* sources: `slot_load` and `phi`.

## §3 The choice (decided)

Option A (a tag-only `guard_bool`, the 0/1 stays dynamic) and Option C (A plus
folding) were offered. **Bart picked B: value specialization.** The trade he
accepted: a flag that changes value exits the trace (a second trace or a side
trace serves the other value), and a carried flipped bool is type-unstable
until P3.

## §4 Design

### 4.1 IR: `guard_is_nil`, `guard_is_false`, `guard_is_true`

Three single-operand guards; the pinned value is in the opcode, like LuaJIT's
`IRT_NIL`/`IRT_FALSE`/`IRT_TRUE` types. (Rev 2 had one `guard_prim` with a
konst ref in `b`; review r1 finding 2: `tropt`'s guard class only tracks `a`,
so `b` would be dropped and left stale by compaction.) Below, "`guard_is_*`"
means all three, and "the pin" is the value the opcode names.

- `a` = value ref. Passes iff the value is exactly the pin: tag `nil`; or tag
  `boolean` with payload 0 / 1. Appended at the end of `IrOp` (wire ordinals
  stay stable).
- `aux` = the recording pc, like the other type guards (`emit` stamps it;
  `guardExitPc` and `isSideExitGuardOp` list them; `guardKeyAux` treats it as
  PC-bearing).
- Result: none (a guard). The recorder uses a konst of the pin for every later
  read.
- `tropt`: class `.guard` (with `guard_int` etc.); `guardConstPasses` → the
  konst strictly equals the pin.
- tier-1a (`irinterp`): strict check, exit like `guard_int`.
- Doc 56 `resumeClass`: same class as `guard_int` (a type guard at the
  instruction's own pc).
- `nativegen_prove.operandReads` lists them (they read `a`), and `.not` too —
  it is missing today, so allocator liveness would treat a `not` operand as
  dead (review r2 finding 1).
- Finalize: a `guard_is_*` on an anchor-window `slot_load` becomes an entry
  guard. `EntryGuardType` gains `nil`, `false_`, `true_`; the three
  fingerprint checks (`TraceCode.matchesFingerprint` — the dispatcher's —
  plus `entryGuardsMatch`) check the exact value;
  `entryGuardsMismatchPromotable` says not promotable.
  So a second specialization of the same anchor (the flag entered as `false`)
  is selected by fingerprint, like an int-vs-float twin today.

### 4.2 Recorder: `pinPrim`

`pinPrim(ref, v, role, operand) !?Ref` returns the konst ref that stands for
`ref` from here on, or null when no pin applies:

- `v` is not nil/bool → null.
- `ref` is a konst → return `ref`.
- `ref` is a `slot_load` or a `phi` → `self.guard(ref, guard_is_*)` (deduped
  by `guarded_refs`) and return `self.konst(v)` (konsts are interned by value).
  No separate `pinned` map (review r2 finding 2): `guarded_refs` already
  survives `peelRewind` correctly — it purges guards above the rewind point —
  and a second map would keep stale pins there and let a re-close skip a
  required guard. Adding bool/nil pins to `guarded_refs` is safe: one SSA ref
  has one observed value, so no ref can collect both a numeric guard and a pin
  (`guarded_refs` is only ever tested for membership).
- Anything else → null. Typed producers (compares, `not`, bool-lane `aload`,
  bool `hload`/`uload`) stay dynamic `.bool`; value-lane loads keep today's
  behaviour.

Provenance: every pin is stamped `(.operand_type, <operand>)`, also at a
branch. A pin failing at a branch is not always "the other CFG edge" (`true` →
a table stays truthy), so it must not claim `.branch_cond` polarity; the
branch-only gates (sibling handoff eligibility, region CFG overlay) therefore
do not see it. Revisit only with evidence.

The pin does **not** rebind the register: the slot stays `.input` (no φ, no
writeback). Other registers holding the same ref get the same konst through the
`pinned` map the next time a consumer pins them.

Call sites (every place a consumer inspects a nil/bool value):

- `recBranch`: pin, then the existing konst fold removes the branch (shape A).
- `recNot` (now takes `regs` to see the observed value): pin the operand; a
  konst operand folds to the konst result. A dynamic `.bool` operand (compare
  result, bool-lane load) still emits `not` (shape E).
- `recEq`: pin both sides first, then:
  - konst × konst → the existing fold (shape A-style `flag == true`);
  - dynamic bool × konst bool or dynamic bool × dynamic bool → emit `eq`/`ne`
    (`ty = .boolean`) (shape D);
  - dynamic bool × konst non-bool → fold (a typed producer is always a bool);
  - the existing number × konst non-number fold is unchanged, and a pinned
    input is a konst there.
- `recHashSet` and `recSetUpval`: pin the store value; replaces their
  `nyi_opcode` abort for an unproven bool.
- `recBType` (`type(v)`) and `recBTostring` (`tostring(v)`): pin the argument,
  so the existing konst folds give `"boolean"`/`"nil"` and
  `"true"`/`"false"`/`"nil"`.
- Bool-lane `astore`: pin the store value (shape F), so the stored value is a
  konst and `guard_fits` on it folds away in `tropt`.
- Numeric paths are unchanged.

### 4.3 Close-time instability (the flipped carried bool)

A pinned `slot_load` of a slot the trace also writes: its φ update must equal
the pin, or the second iteration fails the guard every time (LuaJIT's
`GFAIL`/`TYPEINS`). `loopCloseSelfDefeating` (`trace_recorder.zig`, called
from `close()`) already does this check for `guard_int`/`guard_float` on a
`.def` anchor slot's `slot_load`. It gains the three `guard_is_*` arms: the
LIVE value at the back-edge (what the φ carries on the recorded path) must
strictly equal the pin, whatever produced it:

- equal → fine. If the update is a dynamic `.bool` (e.g. `b = i < 5`), the
  guard stays a real per-iteration check and native lowers it as `cmp`+`jne`;
- anything else → **P1: abort `type_instability`** (existing reason, existing
  strikes). P3 replaces the abort with unroll-by-recording.

(Review r1 finding 1: rev 2 said a dynamic update was always fine, which
would commit a trace that fails on every second iteration.)

### 4.4 `proveKinds`

- Pass A: a `guard_is_*` on a `slot_load` records the pin on it. On an
  internal φ whose init is a `slot_load`, the pin goes on the init (the doc 40
  hoist `guard_int`/`guard_float` already do; review r1 finding 3). Bool-lane
  `guard_fits` on a `slot_load` is no longer reachable for an input (F pins
  first), so it stays as is.
- Pass B:
  - pinned `slot_load`: `true`/`false` → `.bool`; `nil` → `.nil`.
  - `guard_is_false`/`guard_is_true`: operand `.bool` → `.none`;
    `guard_is_nil`: operand `.nil` → `.none`; anything else bails.
  - `not`: operand `.bool` → `.bool`. (Other operand kinds keep bailing: the
    recorder folds every konst/pinned case, so only dynamic bools reach it.)
  - `eq/ne`: `(.bool, .bool)` → `.bool`.

### 4.5 Native

- Prologue tag switch: `.bool → TAG_BOOL`, `.nil → TAG_NIL`. A `.nil` slot has
  no home and no payload load (like `.none`); it is never carried (alloc bails
  a carried `.nil`).
- Pinned bool slot:
  - invariant class (never written): the prologue also compares the payload
    with the pin (`cmp qword [rsi+slot*8], imm8` + `jne prologue_fail`), and the
    body `guard_is_*` emits nothing.
  - **pin-only** (review r1 finding 4): an invariant pinned slot whose
    `slot_load` has no body reader other than its own `guard_is_*` (the common
    case — every consumer got the konst) needs no home. `nativegen_alloc`
    marks it `pin_only`: no register or spill cell; the prologue does the tag
    and payload compares in memory and skips the payload load. A `.nil` slot
    is always pin-only.
  - carried class: GP home (as an int); the body `guard_is_*` is `cmp <place>,
    imm; jne exit`, with the place from `placeOfRef(alloc, ins.a)` (so a pin on
    an internal φ uses the φ's computed home). `nativegen_alloc` admits a
    carried `.bool` (RV-3: load and update must both be `.bool`).
  - The body lowering emits nothing for a pin on an invariant slot or for any
    `guard_is_nil`: the prologue already checked it.
- `not` on `.bool`: `mov dst, src; xor dst, 1`.
- `eq/ne` on two `.bool`s: the int compare path on the 0/1 payloads (a konst
  bool materializes as imm 0/1).
- Exit adapters and the exit location map (doc 56): `.bool` is a GP kind,
  `.nil` has no location; check `nativegen_exitloc`/`nativegen_adapter` treat
  them so (the snapshot restores `nil` from the konst anyway).

### 4.6 Soundness

- Every `.bool` home holds 0 or 1: the prologue loads a `TAG_BOOL` payload
  (`Value.boolean` is canonical 0/1), `setcc` writes 0/1, `xor 1` keeps it.
  `flushSlot` rebuilds `Value.boolean` exactly.
- A pinned input that differs on a later entry fails the prologue (tag or
  payload) → `prologue_fail` → tier-1a, where `guard_is_*` is a real check.
- A pinned invariant slot cannot change during a native run (the trace never
  writes it). A carried one is re-checked every iteration by the body guard.
- Every fold the recorder makes from a pin is only reached after the pin's
  guard passed, on every tier.
- Determinism: no clock, address or RNG enters any decision. The fingerprint
  grows a value check that is a pure function of the register window.

### 4.7 P3: instability unroll (design, 2026-09-27 — decided; review r4 APPROVE WITH CHANGES, folded in)

Until P3, shape B aborts `type_instability` and runs on tier-0.

#### 4.7.1 What LuaJIT does (read, not remembered)

- `lj_trace.c` `LJ_TRACE_END`: a trace that links to itself runs
  `lj_opt_loop`. If that fails, the link is cleared and the state goes back to
  `LJ_TRACE_RECORD` ("Try to continue recording").
- `lj_opt_loop.c` `lj_opt_loop`: only `LJ_TRERR_TYPEINS` (a carried ref's type
  differs from its `SLOAD`) and `LJ_TRERR_GFAIL` (a guard would always fail)
  are caught. `loop_undo` rolls back the half-built loop copy, and recording
  goes on while `--J->instunroll >= 0` (default 4, `lj_jit.h`). Any other
  error propagates.
- `J->instunroll` is set per recording (`lj_record_setup`) and zeroed when the
  recording crosses a compiled loop (`rec_loop_jit`), an `ITERN` or a compiled
  function.
- So the flipped bool becomes one trace whose loop body is two source
  iterations. Iteration 1's `FORL` test stays as an ordinary mid-body guard;
  its snapshot restores iteration 1's state and resumes after the loop.

#### 4.7.2 Where our shape differs

- We close with φs, not by copying the body. So "the loop copy failed" is
  our close-time check `loopCloseSelfDefeating` (§4.3), and "undo" is
  nothing: we have not built anything yet when it fires.
- Our ordinary exits are **coarse**: a failing guard resumes tier-0 at the
  anchor with the trip-start registers (stores are sunk below every guard), and
  tier-0 re-runs the trip. That stays correct for a two-iteration trip: tier-0
  re-runs iteration 1 (and the part of iteration 2 before the exit).
- Only **loop-done exits** are not coarse. They are classified by *shape*, not
  by position:
  - numeric `for` (`isNumericForLoopDoneGuard` / `isLoopDoneGuardIndex` /
    `flushNumericForLoopDone`): any `guard_true` sourced at the anchor's
    `for_loop`. Its exit commits the final iteration (the linked flush) and
    resumes after the loop.
  - `while` (`whileLoopDonePostPc`, doc 38): any `guard_true` at the anchor's
    own `jmp_if_false`. Its exit resumes after the loop with the registers
    untouched, because it sits at the trip TOP.

  In an unrolled trace, iteration 1's `for_loop` test and iteration 2's
  `while` test both match those shapes, but neither is at the right place:
  - iteration 1's `for` test sits mid-trip. Today's flush would decline (the
    whitelist in `loopDoneSnapshotSupported` sees iteration 2's ops after it),
    but the arming side (`loop_done_linked`, `trace_link.zig`), native's
    loop-done slot handling (`nativegen.zig` ~2571/2639) and
    `linked_one_trip` in `interp.zig` would still treat it as a loop-done.
  - iteration 2's `while` test sits mid-trip. A while-done exit there would
    resume after the loop with the trip-start registers and **lose iteration
    1** — a wrong answer.

  So the one real soundness item: a copy of the loop's own test that is not in
  its natural place must be an ordinary (coarse) exit everywhere.

#### 4.7.3 Proposed shape

1. **Trigger.** In `close()`, after the peel check: if `loopCloseSelfDefeating`
   fires, count the defeats by kind. When every defeat is a doc 57 pin
   (`guard_is_nil/false/true`) and the budget allows, enter unroll mode instead
   of aborting. An int/float defeat still aborts: another iteration cannot fix
   it (a float stays a float; that is doc 39's peel, and LuaJIT fixes it with
   `CONV`, not by unrolling).
2. **Unroll mode.** `RecordingSession.unroll_left` (from a new
   `Config.instunroll`, default 4 like LuaJIT) and `unroll_mark_len` (the
   `instrs.len` at the decision). `close()` returns false and the recording
   keeps going; tier-0 runs the back-edge and the next iteration is recorded as
   more body. A second `close()` call at the SAME arrival (`onBackEdge` then
   `maybeCloseAtAnchor`, the doc 39 shared-arrival rule) is seen by
   `instrs.len == unroll_mark_len` and ignored. The next real arrival re-runs
   the whole check: stable → commit; still pin-defeated → unroll again while
   the budget lasts; else abort `type_instability` as today.
3. **Not eligible** (fall back to today's abort): a precise recording (doc 45
   D3 refuses the peel for the same reason), a `.link` close, a pending doc 47
   link peel, a doc 39 peel already in flight, a doc 44 terminal close, or
   `inline_depth != 0`. A peel is never entered once unroll mode started (the
   two would each own the back-edge).
4. **Loop-test copies.** Mark the misplaced copies at record time and teach the
   shape classifiers to skip them:
   - numeric `for`: at the unroll decision, the loop-done guard just emitted by
     `recForLoop` for the anchor's `for_loop` (the last `.loop_done`
     provenance entry at depth 0 with that source pc) is re-marked;
   - `while`: in unroll mode, `recBranch` marks the guard it emits for the
     anchor's own condition (the same structural test `recBranch` already
     does for LLEAVE);
   - `repeat … until`: nothing to do (its test is already an ordinary
     `branch_cond` guard).

   Then `isNumericForLoopDoneGuard`, `isLoopDoneGuardIndex`,
   `flushNumericForLoopDone` and `whileLoopDonePostPc` return "not a loop-done"
   for a marked guard, and the doc 56 attach classifier refuses it (new
   `Verdict`). How to mark it is **decision P3-D1** below (decided: a new
   `GuardRole.loop_test_copy`, read through one `TraceCode.isLoopTestCopy`).

   Review r4 found more places that decide "loop test" by source opcode
   alone; each consults `isLoopTestCopy` too:
   - `isSourceBranchGuardExit` (`trace_link.zig`) — the funnel for
     `noteTakenExit` and `siblingHandoffEligible`, so a `while` copy never
     becomes a prime-side want or a sibling handoff;
   - `driveChain`'s `numeric_done` (`trace_chain.zig`);
   - `maybeArmContinuation` and `computeNativeLoopDoneLink`
     (`trace_link.zig`).

   `unroll_mark_len` is refreshed at every unroll decision (a period-3 cycle
   decides twice).
5. **Accounting.** One trip is now k source iterations. `completed` and the
   ledger count trips, as they do for any trace; only heuristics read them.
   The per-anchor trip statistics that gate low-trip loops
   (`low_trip_while`, `whileDoneHotnessEligible`) will see half the trips;
   noted, not changed.
6. **Probe + stats.** `unroll:` jit-debug line at each decision
   (`anchor pc, iteration k, defeated slots`); `--jit-stats` gets a count of
   committed unrolled traces.

What stays as is, and why:

- tier-1a and native just see a longer body: φs carry the end-of-trip values
  (for shape B the φ carries konst `true`, equal to the pin).
- Store sinking, store forwarding and alias guards (doc 51) already handle a
  read after an earlier store in the same trip; iteration 2 reading what
  iteration 1 stored is the same case.
- Doc 56 ordinals keep counting up through iteration 2, so every exit keeps
  its own resume-coherent snapshot.
- Region membership (`rec_path`) is a set of program points; visiting each
  twice changes nothing.

#### 4.7.4 Decisions for Bart

**Decided 2026-09-27:** P3-D1 **(a) new `GuardRole`**; P3-D2 **(a) pin
defeats only**; P3-D3 **`Config.instunroll = 4`, no CLI flag**. P3-D4 stays a
measured follow-up.

- **P3-D1: how to mark a misplaced loop-test copy.**
  - (a) A new `GuardRole` (e.g. `loop_test_copy`) replacing `loop_done` /
    `branch_cond` on that guard. The classifiers compare roles; every
    role-keyed consumer then sees a plain non-branch guard (no composite
    bridge, no sibling handoff at that exit).
  - (b) A `copy: bool` flag on `GuardProvenance`, role unchanged. The loop-done
    classifiers check the flag; other role consumers keep treating a `while`
    copy as a `branch_cond` (so a composite bridge or sibling handoff could
    still form there).
  - (c) No mark; the classifiers use position ("the numeric loop-done is the
    last guard sourced at that `for_loop`; the while-done is the first").
    Needs a scan per query unless cached, and is only as good as
    "nothing reorders guards" (tropt keeps order today).
- **P3-D2: trigger scope.**
  - (a) Pin defeats only (above). Converges for any period ≤ 5 value cycle of
    nil/false/true.
  - (b) LuaJIT-literal: any `loopCloseSelfDefeating` defeat. The int/float
    cases never converge here, so they would spend up to 4 extra iterations of
    recording and then abort anyway.
- **P3-D3: budget.** `Config.instunroll` = 4 (LuaJIT's default), CLI flag or
  not.
- **P3-D4: optional follow-up.** When a pinned slot's φ always carries its pin
  (shape B's `true`), the per-trip body pin can never fail after the prologue
  checked it. A tropt fold could turn it into the invariant (`pin_only`)
  class. Not needed for correctness; measure first.

#### 4.7.5 Tests (P3)

- Recorder: shape B commits one trace with two `for_loop` tests, exactly one of
  them classified loop-done (the last); a period-3 cycle (`s` over
  nil/false/true) commits with three iterations; a budget of 0 aborts as
  today; an int/float defeat still aborts; a precise recording never unrolls.
- The same-arrival rule: one arrival never unrolls twice (mutation: drop the
  `unroll_mark_len` check).
- Parity per tier: shape B with odd and even trip counts (the loop ends at
  iteration 1's test, which must resume by re-running, not by the flush); a
  `while` version whose iteration-2 test fails (the lose-iteration-1 bug:
  mutation — drop the `while` mark, must fail); stores in both iterations; an
  exit in iteration 2 after an iteration-1 store.
- Native: shape B's trace compiles and holds (`expectNativeHolds`).
- Replace the "refused at close (until P3)" test with the committed shape.
- From review r4: an unrolled `while` (the first condition guard keeps
  `branch_cond`, the later ones are copies); a cycle longer than the budget
  aborts; a mixed pin + int/float defeat aborts without unrolling; a `while`
  copy is not a source-branch exit; iteration 2 reads an array cell iteration
  1 stored; a loop inside an inlined callee never unrolls.

#### 4.7.6 Measurement

- Shape B (`/tmp/boolshapes.lua` B alone): `--jit-stats` residency and time,
  before/after.
- Board before/after, ×3 interleaved A/B against a `just shadow` baseline on
  any row that moves. No bench is expected to move (none has a flipped
  carried value); this is coverage.

### 4.8 Costs

- Tier-1a: an input that was observed bool/nil at a branch now carries a strict
  guard. If it later holds another value, the trace exits where it used to stay
  on (a truthy table where `true` was seen). That is the trade LuaJIT makes.
- Native: nothing new on already-native traces — none of them has a bool/nil
  `slot_load` today (they all bail).

## §5 Tests (P4)

- Record shape: each probe shape records the expected `guard_is_*` placement and
  folds (no `guard_true` left for shape A, no `not` left for a pinned operand).
- Per-tier parity on the six shapes, plus: a flag that changes value between
  entries (prologue fail → correct result, and a second trace for the other
  value); a flag that changes type (`true` → a table); a carried dynamic bool
  (`b = i < 5` read next iteration); `x == nil`/`x == 1` folds on a pinned
  input; a nil-pinned input.
- Native: shapes A, D, E, F run native.
- Mutation checks: drop the prologue payload compare (flag-change test must
  fail); drop the `xor` (shape E must fail); drop the close-time check (shape B
  must hang or mis-run under the harness).

## §6 Measurement (P4)

- Board before/after, noise-checked ×3 interleaved against a `just shadow`
  baseline.
- `--jit-stats` on the six-shape probe and nsieve (doc 56 switch off and on).

## References

- `TODO.md` "Doc 56 Phase 5 findings" (the probe and the nsieve finding).
- `src/trace_recorder.zig` `recEq`, `recBranch`, `recNot`, `recHashSet`,
  `close`, `maybeEnterPeel`.
- `src/nativegen_prove.zig` Pass A/B, `src/nativegen.zig` prologue,
  `src/nativegen_alloc.zig` RV-3/RV-4.
- LuaJIT `lj_record.c` `BC_IST`/`BC_NOT`/`BC_ISEQP`, `lj_ir.h`
  `tref_istruecond`, `lj_opt_loop.c` `lj_opt_loop` (`instunroll`).
