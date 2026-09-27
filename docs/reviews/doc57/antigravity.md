# Doc 57 rev 2 review — Antigravity (2026-09-27)

Scope: doc 57 rev 2 (Option B, value specialization), checked against named
source ranges in `trace_recorder.zig`, `nativegen_prove.zig`, `nativegen.zig`,
`nativegen_alloc.zig`, `trace_finalize.zig`, `tropt.zig`, and LuaJIT
`lj_record.c`/`lj_opt_loop.c`. Read-only, with tool access.

**Verdict: CHANGES REQUESTED.** Eight findings; all checked in source and
accepted. Folded into doc 57 rev 3.

1. **Blocker — §4.3 carried rule.** "The update is a dynamic `.bool` → fine"
   is wrong when the value carried at close differs from the pin: iteration 2
   fails the guard every time (LuaJIT `GFAIL`). Rule is now: the LIVE carried
   value must strictly equal the pin, whatever produced it; otherwise abort
   `type_instability`. Implemented inside `loopCloseSelfDefeating`
   (`trace_recorder.zig:5758`), which already does this for int/float.
   **Accepted.**
2. **Blocker — `guard_prim` with a konst operand in `b` breaks `tropt`.**
   `.guard` class liveness and compaction only touch `a` (`tropt.zig:730`,
   `:878`), `guardConstPasses` has no access to `b`'s konst (`:275`), and
   `GuardKey` is `(op, a, aux)`. **Accepted, changed shape:** three
   single-operand ops `guard_is_nil`/`guard_is_false`/`guard_is_true` (the
   value is in the opcode, like LuaJIT's `IRT_NIL`/`IRT_FALSE`/`IRT_TRUE`),
   so they are ordinary `.guard`-class type guards with the pc in `aux`.
3. **Major — Pass A must hoist a pin on an internal φ to its `slot_load`
   init** like `guard_int`/`guard_float` (`nativegen_prove.zig:254-267`), or
   the φ fails its kind-equality check. **Accepted.**
4. **Major — "no home" for an invariant pinned slot is not wired.** Alloc gives
   every non-`.none` invariant slot a home and the prologue loads it
   (`nativegen.zig:931-945`). Also `operandReads` must list the new guards.
   **Accepted:** alloc marks such a slot `pin_only` (no home); the prologue
   checks tag and payload in memory and skips the load.
5. **Major — missed consumers.** `recBType` (`type(b)`), `recBTostring`
   (`tostring(b)`) abort on a non-konst bool/nil; `recSetUpval` has the same
   `bool_proven` abort as `recHashSet`. **Accepted:** all three pin.
6. **Minor — `recNot` takes no `regs`.** It needs the observed value to pin.
   **Accepted.**
7. **Minor — integrate the §4.3 check into `loopCloseSelfDefeating`.**
   **Accepted** (same as 1).
8. **Nit — `pinned` map lifecycle:** clear it in `reset`/`realAbort`, free in
   `deinit`. **Accepted.**

# Round 2 — rev 3 (2026-09-27)

**Verdict: APPROVE WITH CHANGES.** All eight r1 findings confirmed resolved.
Answered the `guarded_refs` question: adding bool/nil pins is safe (one ref,
one observed value; the set is only tested for membership; it already held
`guard_func`/builtin guards). Five new findings, all checked and accepted
(folded into rev 4):

1. **Major — `operandReads` lacks `.not`** (`nativegen_prove.zig:1578` falls
   to `else`), so alloc liveness would treat a `not` operand as dead.
2. **Major — a separate `pinned` map goes stale on `peelRewind`**
   (`trace_recorder.zig:1032-1050` only purges `guarded_refs`). Dropped the
   map: `guard` dedups through `guarded_refs`, `konst` interns by value.
3. **Minor — `TraceCode.matchesFingerprint`** (`trace_code.zig:498`), the
   dispatcher's check, needs the new entry types too.
4. **Minor — body lowering must use `placeOfRef`** (an internal φ is not a
   slot); say explicitly that invariant pins and `guard_is_nil` emit nothing.
5. **Nit — the predicate is `isSideExitGuardOp`**, not `isGuard`.

## r3 — P2 implementation review (commit a0f84ab, 2026-09-27)

Scope: soundness of the native lowering only (`git show a0f84ab`), with six
asked-for checks: every `home`/`loc` consumer handles `pin_only`;
`opMayExitInBody` agrees with the lowering; the internal-φ `bool_init` path;
`hasNonPinReader` vs `markBodyReads`/liveness; `.terminal`/`.link` traces;
doc 56 adapters with `pin_only` rows.

Verdict: **no soundness bugs found.** Each check was traced to code: the
prologue skips the `pin_only` payload load and the alloc assertion skips its
home; the precise flush rebuilds a cross-slot `pin_only` capture from
`pinnedValue`; coarse/silent deopt flush only carried slots; both
`opMayExitInBody` and the lowering key on `pinHoisted`; a `bool_init` load is
read by its internal φ so it is never `pin_only`, gets a home and a TAG_BOOL
check, and the φ's body pin catches a wrong entry value on iteration 1; a
store-ref copy of a pinned load makes it non-`pin_only`; an adapter restoring
another slot from a `pin_only` row fails closed (`not_held`).

## r4 — P3 design review (§4.7, 2026-09-27)

Scope: the §4.7 instability-unroll design, checked against source. Verdict:
**APPROVE WITH CHANGES.**

Confirmed: coarse exits stay correct over a multi-iteration trip (stores
sunk or idempotent pure writes; recorder caches key on refs; φs take the
final `reg_map`; doc 56 ordinals stay monotonic; `rec_path` is deduped); the
same-arrival rule is right for `for` and `while` (nothing is recorded between
`onBackEdge` and `maybeCloseAtAnchor`; the other `closeTrace` caller only
fires for `.link`/`.terminal` closes, which are excluded).

Findings (all checked in source and accepted):

1. **MAJOR — branch-shape consumers ignore the role on loop anchors.**
   `isSourceBranchGuardExit` (`trace_link.zig` ~693) only excludes
   `for_loop`-sourced guards, and `noteTakenExit` (~418) and
   `siblingHandoffEligible` (`trace.zig` ~1862) test the source opcode, not
   the role, for loop anchors. A `while` copy (source `jmp_if_false`) would
   be taken for a source-branch exit (prime-side want, sibling handoff).
   Fix: `isSourceBranchGuardExit` rejects a loop-test copy (the funnel for
   both).
2. **MAJOR — `driveChain` hand-rolls the numeric loop-done test**
   (`trace_chain.zig` ~2880: source op `== .for_loop`). A `for` copy would be
   flushed as a loop-done. Fix: consult the copy check.
3. **MINOR — `maybeArmContinuation` hand-rolls it too** (`trace_link.zig`
   ~160). Same fix. (Found while checking: `computeNativeLoopDoneLink`,
   `trace_link.zig` ~105, is a third hand-rolled scan; same fix.)
4. **MINOR — refresh `unroll_mark_len` on every unroll decision**, not only
   the first.
5. **MINOR — tests**: an unrolled `while` (role of each condition copy), a
   budget-exhaustion cycle, a mixed pin + int/float defeat, source-branch
   exclusion of a `while` copy, cross-iteration store forwarding, an inlined
   loop never unrolling.
