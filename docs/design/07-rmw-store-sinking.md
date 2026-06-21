# lune — RMW array stores via store-sinking (relaxing C1)

Status: **implemented** (2026-06-22) — recorder defers/sinks the single RMW
`astore` below every loop-exit guard; green under `zig build test` and 8-mode
determinism. Design was reviewed (Codex + Antigravity both confirmed sound) before
implementation. Measured: scimark-sor 46.9× → **4.5×** vs LuaJIT (10.5× JIT
speedup over tier-0), scimark-lu 74.5× → **12.4×** (6×). FFT (4 stores/iter) and
sparse (indirect gather) remain out of scope — see §6. Gap A (the f64 array lane,
tier-1b) landed first and is the prerequisite the float-array read/store encodings
build on.
Owner: Bart
Last updated: 2026-06-22

Prerequisite reading: `01-trace-lifecycle.md` §"Loop-header re-entry deopt" (the
deopt model this rests on) and `05-native-codegen.md` §Phase B (the C1/C2
invariants). This doc proposes relaxing **C1** — the recorder rule that aborts any
trace which stores into a packed array after reading one — so read-modify-write
(RMW) float-array loops can record and run native.

## 1. Problem: C1 blocks every scimark hot loop

Profiling the scimark corpus (`perf record`, per the project profile-first rule)
puts scimark-lu/sor/fft at **0 % native** despite Gap A having unlocked the f64
array lane. The reason is not codegen tightness — it is *trace coverage*. Every
scimark hot loop is a read-modify-write over a float array, and the recorder's C1
rule (`trace.zig` `recArraySet`) aborts the whole trace the moment an `astore`
follows any `aload`:

```zig
// C1: refuse to record a write into a trace that has already read the packed array
if (self.traceHasArrayLoad()) return self.abort(.bad_type);
```

The kernels (verbatim shapes from `bench/luajit/scimark_lib.lua`):

| kernel | inner loop | reads | stores | store last? |
|---|---|---|---|---|
| **SOR** | `v[x] = om4*((vp[x]+vn[x])+(v[x-1]+v[x+1])) + om1*v[x]` | 5 | 1 (`v[x]`) | yes |
| **LU daxpy** | `vi[k] = vi[k] - eij*vj[k]` | 2 | 1 (`vi[k]`) | yes |
| **LU scale** | `v[j] = v[j]*recp` | 1 | 1 (`v[j]`) | yes |
| **matrix copy** | `vd[x] = vs[x]` | 1 | 1 (`vd[x]`, *different* array) | yes |
| **FFT** | `v[j],v[j+1]=…; v[i],v[i+1]=…` | 4 | 4 | reads-first, then 4 stores |

All but FFT are **one store, and that store is the last array access in the body**.
C1 rejects them solely because a read precedes the write. Relaxing C1 for exactly
this shape unblocks SOR + both LU kernels + matrix copy. FFT (four stores) is a
documented multi-store follow-on (§6).

## 2. Why C1 exists — the deopt-replay hazard (recap)

lune's deopt is **coarse loop-header re-entry** (`01-trace-lifecycle.md`,
`irinterp.executeImpl`). A trace runs N *fully completed* iterations natively; on
any guard/arith side-exit mid-body it returns `completed = N` with the tier-0
register file **left at the start of the partial iteration N+1** (the φ writebacks
only flush at the clean `.loop` back-edge — `irinterp.zig` increments `completed`
only there). Tier-0 then resumes at the loop header (`anchor.pc`, the body start)
and **re-runs iteration N+1 from scratch**.

The register state is rolled back (regs are untouched since the iteration start),
but **the heap is not**. So if the partial iteration N+1 performed an `astore`
*before* the side-exit, that store is already committed when tier-0 re-runs the
whole iteration — and an RMW (`v[x] = f(v[x])`) double-applies `f`. A data-only
check is insufficient: a read can steer a store's *control flow* too
(`if t[i] then t[i]=false else t[i]=true end` stores a constant yet replays
differently if the guard that picked the branch fails after the store). C1's
blunt "no `aload` may precede any `astore`" closes both the data and control
channels with one obviously-sound rule — at the cost of every RMW loop.

## 3. The insight: sink the store below the last loop-exit guard

C1 is overbroad because it pessimises on *read-before-write in program order*,
when the property that actually matters is *guard-after-write in trace order*. The
double-apply hazard requires a guard that can side-exit **after** the store has
executed within the same iteration. Eliminate that and the hazard is gone.

We can eliminate it by construction. The `astore` is **effectful but not
value-producing** — nothing in the trace reads its result — so it can be freely
reordered *later* in the trace as long as no subsequent instruction reads the slot
it writes. Move the `astore` IR node to the very end of the iteration body, after
**every** guard (including the numeric-`for` continuation guard `guard_true`, which
`recForLoop` emits at the bottom of the body), immediately before the `.loop`
terminator. Then:

- **Clean iteration:** all guards pass → the sunk store executes → `.loop`
  increments `completed`. Each completed iteration stores exactly once. ✓
- **Any side-exit** (a read's `guard_bounds`/`guard_present`, the store's
  `guard_fits`, a body branch guard, *or* the loop-end `guard_true`): the exit is
  now strictly *above* the store, so the store **has not executed on-trace**.
  Tier-0 re-runs the whole iteration from the header and performs the store
  exactly once. No double-apply. ✓

The store becomes the last effect, dominated by all guards. This is the same
soundness principle nativegen already uses for in-place slot-home coalescing
(`nativegen.zig` `last_body_guard`: "no side-exit follows the in-place update").
We apply it to the heap write.

### 3.1 Why sinking only the `astore` node is enough

We sink **only** the `astore` node — not its address (`aref`), not its guards, not
the value computation. Those stay in the body where they are:

- The **`aref`** (`&data[key]`) is computed from the key ref captured at body time
  (the *pre-increment* loop index). lune's IR is SSA-shaped: the `astore` node
  references the `aref` node by index, and `recForLoop`'s `setReg(a, rnext)`
  repoints the *slot*, not the already-emitted `aref` node. So the sunk store
  addresses `v[x]` (the current iteration's element), never `v[x+1]`. The XMM
  register holding the computed value stays live across the `for_loop` compare
  because the `astore` (its last use) keeps it live — automatic from the existing
  liveness scan; the `for_loop` compare uses GP/int registers and never clobbers
  the value XMM.
- The store's **guards** (`guard_table`/`guard_lane`/`guard_int`/`guard_bounds`/
  `guard_fits`) stay inline and continue to dominate the store. They must — the
  store assumes in-bounds, in-lane, correct shape. Sinking the store *below* them
  only strengthens their domination.

### 3.2 The one constraint: the store must be the last array access

Sinking is unsound if an `aload` of the **same slot** follows the store in program
order — on-trace that read would see the pre-store value while tier-0 (which stores
then reads on its re-run) sees the post-store value: divergence. The conservative,
streaming-checkable sufficient condition is: **no later heap-observing op may be
recorded after a sunk store.** Today the only heap-observing trace ops are the
packed-array accesses `aload`/`astore`/`astore_append` (everything else — host
calls, globals, hash-part/`__index`, general table ops — already aborts the trace,
`trace.zig` ~1311), so in practice this is "no later array op." It is phrased as
"heap-observing" deliberately: if a future change ever traces `#t`, a hash-part
read, a global, or a call, this invariant must extend to it, not silently stay
array-only. Since the recorder is a forward stream that cannot see the future, we
enforce it reactively: defer the store, and if any later heap-observing op appears
before the trace closes, **abort** `.bad_type` (exactly as today — no regression).
All four first-cut kernels have the store last, so they never trip this.

## 4. Soundness summary (the argument reviewers must check)

For a trace with a single deferred `astore` flushed immediately before `.loop`:

1. **No side-exiting op is below the store.** It is flushed below every guard; the
   only ops `commit()` appends after it are `.phi` writebacks and the `.loop`
   terminator, neither of which can side-exit (φ writebacks flush registers at the
   clean back-edge only; they never fail). Therefore every side-exit happens with
   the store un-executed → tier-0 re-runs the iteration and stores once →
   idempotent. This covers the **data** channel (RMW) and the **control** channel
   (read-steered branch), because *no* read-derived decision sits below the store.
2. **No heap-observing op follows the store** (enforced by the abort in §3.2).
   Therefore no on-trace read can observe a stale pre-store value relative to
   tier-0's replay.
3. **At most one store per trace** — a **recorder** invariant this change must
   enforce itself (B2 below). `tropt` does *not* impose it: it classifies every
   `astore`/`astore_append` as effectful (`.astore`, a non-reorderable,
   never-DCE'd alias barrier, `tropt.zig` ~63, ~265) and would happily keep
   several. Multiple sunk stores are out of scope here (§6), so the recorder
   aborts on a second eligible store.
4. **Determinism is inherited, not re-argued.** The native/oracle/tier-0 store
   move byte-identical bits (Gap A established `movsd` ↔ `@bitCast` parity for the
   f64 lane; int/bool lanes were settled earlier). Store-*sinking* changes only
   *when* the store is emitted in the trace, not *what* it writes, so all 8
   determinism modes stay byte-identical. The tier-1a oracle (`irinterp`) executes
   the same reordered IR, so it remains the correctness oracle the native backend
   is differentially tested against.

The net rule replaces C1's "abort if any prior `aload`" with: **defer the store;
sink it past all guards at trace close; abort if a second store or any post-store
array access appears.**

## 5. Implementation plan (staged, each behind `zig build test` + 8-mode)

All changes are in **`src/trace.zig`** (the recorder); `tropt`, `irinterp`, and
`nativegen` need confirmation but — by §4.3 and the existing `astore` handling —
likely no new code. Stage:

- **B1 — recorder defer/flush (`trace.zig`).** In `recArraySet`, when the store
  follows an `aload` (today's C1 abort site) and the eligibility predicate holds
  (single store, in-bounds present slot, `fits`, no metatable, narrow lane), emit
  the address + guards inline as today but **stash the `astore` node parameters in
  a `pending_store` field** instead of emitting it. Flush the pending store in
  `commit()` after `recForLoop`'s `guard_true` (already in the stream) — placed
  just before the `.loop` terminator so it is unambiguously the last non-terminator
  op (φ writebacks never side-exit, so order relative to them is immaterial). Keep
  the pure-write fast path (no prior `aload`) exactly as-is — those already emit
  inline and pay nothing.
- **B2 — post-store array-access guard (`trace.zig`).** While a `pending_store` is
  live, any subsequent `recArrayGet`/`recArraySet`/append aborts `.bad_type`
  (the §3.2 constraint). A second eligible store also aborts (single-store scope).
- **B3 — confirm the consumers.** Verify `tropt` keeps the sunk `astore` as a live
  root and does not hoist a guard below it (it classifies `astore` as
  `.astore`/side-effecting already); verify `irinterp` executes the reordered IR
  identically (it is position-independent — it just runs instructions in order);
  verify `nativegen` lowers an `astore` that sits after `last_body_guard` (it
  should: the store is just emitted last, and liveness keeps the value XMM alive).
  Add code only where a confirmation fails.
- **B4 — tests.** Recorder unit tests (an RMW trace records with the store sunk
  below `guard_true`; a store-then-read trace aborts; a two-store trace aborts).
  A nativegen unit test (the sunk f64 RMW store compiles and matches the oracle,
  incl. an idempotent deopt-replay across a forced mid-body side-exit — the
  load-bearing test). An `interp.zig` `expectProgram` 8-mode e2e: an SOR-shaped
  RMW loop is byte-identical across all 8 determinism modes.
- **B5 — measure + docs + review.** `just bench --filter scimark` (expect lu/sor
  to move off 0 % native; report the t0-vs-native speedup and the remaining
  LuaJIT gap). Update this doc's status, `05-native-codegen.md`, and `TODO.md`.
  Then **Codex + Antigravity review** of the determinism-sensitive recorder change
  before Bart's commit approval.

## 6. Out of scope (follow-ons)

- **Multi-store sinking (FFT).** FFT writes four slots per iteration with all reads
  before all stores. Sinking *all* stores (in order) below the loop guard is sound
  by the same argument, but needs the single-store `tropt` invariant lifted and a
  multi-pending-store recorder. Separate plan.
- **Store-then-read same trace.** Genuinely needs store→load forwarding (read the
  pending value, not the heap) — a larger change. Aborted here, as today.
- **`__newindex` / hash-part / `.value`-lane stores.** Unchanged — still abort
  (metatable dispatch, non-packed, heap-value write barriers are all out of scope).

## 7. Open questions for review

1. **Is "no array access after a sunk store" the right granularity, or should it
   be the tighter "no `aload` of an aliasing slot"?** The coarse rule is obviously
   sound and costs the first-cut kernels nothing; the tighter rule needs alias
   analysis. Recommendation: ship coarse, revisit only if a real kernel needs it.
2. **Does any guard get emitted *after* `commit()` begins?** The plan assumes
   `recForLoop`'s `guard_true` is the last guard and `commit()` runs strictly
   after it. Confirm no path emits a guard between the pending-store flush and the
   `.loop` marker (φ writebacks are not guards and never side-exit, so their order
   relative to the store is immaterial).
3. **Native value-liveness across the loop compare.** Confirm the XMM holding the
   RMW result is not spilled/clobbered by the `for_loop` int compare before the
   sunk store reads it (expected fine — disjoint register classes + liveness, but
   worth a reviewer's eye since it is the one new live-range extension).
