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

### Outstanding

- [ ] P2 — native: prove/alloc/prologue, `not` and `eq` on dynamic `.bool`.
- [ ] P3 — instability unroll (LuaJIT `instunroll`) for the flipped carried
  bool. Own investigation first (§4.7).
- [ ] P4 — tests + measurement (board, `--jit-stats` on the probe and nsieve).

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

### 4.7 P3: instability unroll (sketch, needs its own investigation)

LuaJIT keeps recording past the back-edge until the carried types match the
entry (`instunroll` ≤ 4). Our nearest machinery is doc 39's peel
(`maybeEnterPeel`), which also keeps recording past the back-edge, but it is
narrow (plain `while`, pure ops) and makes iteration 1 a run-once prefix — it
does not converge for a period-2 flip. P3 needs:

- a recorder mode that re-records the next iteration as more straight-line body
  (no prefix), bounded by an `instunroll`-style budget, and closes when every
  pinned slot's carry equals its pin;
- the mid-body `for_loop` guard of the unrolled iteration classified correctly
  (it is a loop-done exit that is not the trace's terminal guard: region
  topology, doc 56 attachability, `loop_done` roles);
- measurement on shape B and on the board.

Until P3, shape B aborts `type_instability` and runs on tier-0 (today it runs a
tier-1a trace that is not faster than tier-0 on that body).

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
