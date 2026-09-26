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
