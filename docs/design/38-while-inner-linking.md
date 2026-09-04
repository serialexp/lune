# Doc 38 — While-inner nested-loop linking

## Problem

Numeric-`for` inner loops already link via `recForPrepLink` (doc 15 Phase 2):
when a continuation/side recording re-reaches an inner `for_prep` whose loop
header already has a root trace, it closes with a `.link` terminal to that root.
The inner root handles the variable-trip-count loop body, and the continuation
handles the outer loop's advance + re-entry.

**While loops have no equivalent.** A while loop compiles to:
```
  <cmp>            ; e.g. le k j → boolean
  jmp_if_false     ; exit if false
  <body>
  jmp <back>       ; back-edge (backward jump) to <cmp>
```

The backward `jmp` triggers `onBackEdge`, so while loops DO get root traces
(anchored at `<cmp>`'s PC). But when a continuation recording encounters the
inner while loop, it unrolls the while body inline — the `.jmp` handler is
`{}` (no-op). Different outer-loop iterations have different while-loop trip
counts, so the unrolled guards fail and the trace has near-zero residency.

**Concrete impact:** `fft_bitreverse`'s inner `while k <= j` loop eats 33% of
scimark-fft's runtime on the interpreter. The outer for-loop trace (`:9`)
unrolls the while body and pins exact trip counts via `guard_true`/`guard_false`
sequences — trip-count polymorphism kills residency.

## LuaJIT's solution

LuaJIT has a dedicated `BC_LOOP` opcode at while/repeat loop headers, and the
JIT-hot variant `BC_JLOOP`. The recording function `rec_loop_jit` (line 660 of
`lj_record.c`) is trivial:

```c
static void rec_loop_jit(jit_State *J, TraceNo lnk, LoopEvent ev) {
  if (J->parent == 0 && J->exitno == 0) {  /* Root trace → abort LINNER */
    lj_trace_err(J, LJ_TRERR_LINNER);
  } else if (ev != LOOPEV_LEAVE) {  /* Side/cont enters compiled loop */
    J->instunroll = 0;
    if (same-loop)
      lj_record_stop(J, LJ_TRLINK_LOOP, J->cur.traceno);
    else
      lj_record_stop(J, LJ_TRLINK_ROOT, lnk);  /* Link to the loop */
  }
}
```

Key insight: `LJ_TRLINK_ROOT` (our `.link`) is used for ALL loop types. No
special prep arithmetic for while/repeat — the link just stops recording and
hands off to the inner root. The inner root's entry state is whatever slots its
`SLOAD`s (our `slot_load`s) demand.

## Design

### Detection: when the recorder sees a backward `.jmp`

Currently `.jmp` is a no-op in `recordOne`. Change it to call `recWhileLink`
when ALL of these conditions are true:

1. **Backward jump**: `@as(i64, pc) + instr.aux` < `pc` (the target is before
   the current instruction). Must bounds-check: `target_i >= 0` and
   `target_i < proto.code.len` (matching `recForPrepLink`'s defensive pattern).
2. **Not our own anchor**: the target != `self.rec.anchor.pc` (our own back-edge
   is handled by `maybeCloseAtAnchor` / `onBackEdge`, not by the recorder)
3. **An inner root trace exists** at the target: `findLoopTrace(proto, target)`
   returns non-null
4. **At inline depth 0**: links at depth > 0 can't work (the `driveChain`
   target resolution happens in the anchor proto, not the callee's — same
   constraint as `recForPrepLink`)

Root recordings are NOT filtered at the call site — they enter `recWhileLink`
and abort LINNER inside it (matching `recForPrepLink` line 13830 and LuaJIT's
root gate).

When conditions 1–3 fail, the `.jmp` stays a no-op (the recording unrolls the
while body, exactly as today). Condition 3 failing (no inner root yet) means
the while loop will eventually get its own root trace via `onBackEdge` — not
during THIS recording (which holds `rec.active`), but on a later execution
when no recording is active.

When condition 4 fails (root recording), `recWhileLink` IS called but aborts
LINNER — matching `recForPrepLink`'s root-abort (line 13830) and LuaJIT's
`rec_loop_jit` root gate. The inner loop must spawn its own root first; once
it does, a later continuation/side links here.

### `recWhileLink`: the link function

Much simpler than `recForPrepLink` because there's no pre-decrement arithmetic
to redo. The while loop has no setup opcode — the entry point IS the comparison
at the top.

```
fn recWhileLink(self, instr, regs, proto, pc):
    target_i = @as(i64, pc) + instr.aux
    if target_i < 0 or target_i >= proto.code.len: return  // OOB → no-op
    target = @intCast(u32, target_i)

    // Not backward or is own anchor → no-op
    if target >= pc: return
    if target == rec.anchor.pc: return
    if rec.inline_depth > 0: return

    // No inner root → no-op (inner loop will warm up later)
    if findLoopTrace(proto, target) == null: return

    // Root recordings: UNROLL-FIRST policy (see "Topology arbitration").
    //  a) proven low/zero-trip inner (lleave_count ≥ lleave_fast_retries):
    //     record through — the innerloopleft escape
    //  b) fewer than `unroll_fail_flip` unroll failures at this anchor:
    //     record through (unroll), flagging rec.unrolled_while so an abort
    //     or a later .legacy_thrash gate bumps `unroll_fail`
    //  c) unrolling has failed ≥ unroll_fail_flip times: abort LINNER —
    //     decompose into inner root + .link continuation
    if rec.kind == .root: (a)/(b) return, (c) abort(.nyi_opcode)

    // Set link_target + provenance, then close
    rec.link_target = target
    rec.pending_link_provenance = ...
    closeTrace(regs)
```

**No explicit bounds guard needed.** Unlike `recForPrepLink`, which must check
that the numeric-for's first iteration is within bounds (the inner root
assumes ≥1 iteration), a while-link does NOT need a first-iteration guard.
The while root's early instructions evaluate the loop condition (comparison +
branch guard) BEFORE any loop-body code executes. If the while loop would
zero-trip, the inner root's own `guard_true`/`guard_false` fires during the
condition prefix and side-exits cleanly to tier-0.

For pure conditions (like `fft_bitreverse`'s `k <= j`), the condition prefix
is effect-free — just a `le` comparison and a `jmp_if_false` guard. The
zero-trip side-exit is safe because no committed state changes precede it.

**Note on effectful conditions:** a while condition involving function calls
or other side-effecting expressions could theoretically produce effects before
the branch guard. This is a pre-existing concern for while-loop roots in
general (not introduced by linking). In practice, effectful while conditions
are rare in performance-critical loops; the linking design inherits whatever
safety guarantees the root trace already has for its condition prefix.

This matches LuaJIT: `rec_loop_jit` calls `lj_record_stop(TRLINK_ROOT)` with
no bounds check.

**No explicit register setup needed.** The hand-off invariant is:

- Every anchor-frame slot *modified* by the continuation is `.def` and gets a
  φ writeback at the `.link` terminal (`commit()` line 11841). The inner root
  re-reads these via `slot_load`.
- Slots the continuation *never touched* remain coherent in the physical
  register file — their values haven't changed since the last tier-0 write.
  The inner root's `slot_load` picks them up from the live register window.

This is the same invariant that makes numeric-for linking work: the φ block
writes back what changed, the physical file preserves what didn't. No
while-specific register reconstruction is needed.

### `locals_watermark` for while loops

While-loop roots currently leave `locals_watermark` at `maxInt` (the "unknown"
sentinel), meaning no temporaries are filtered from the exit snapshot. This is
correct and unchanged by this design — while loops don't have a fixed register
window like numeric-for's `a..a+3`.

### What changes

| file | change |
|---|---|
| `src/trace.zig` | `.jmp` dispatch: detect backward jump + inner root → call `recWhileLink`. New `recWhileLink` function: abort LINNER for roots, set `link_target` + provenance, close trace. |

### What does NOT change

- `recForPrepLink` — unchanged, handles numeric-for linking as before
- `recForLoop` — unchanged
- `commit()` — already handles `link_target != null` → `.link` terminal
- `driveChain` — already chains `.link`-terminated traces (the link-to-root
  hand-off works for while roots too; the limitation is on the *exit* side)
- `onBackEdge` — already handles while-loop root traces
- `maybeCloseAtAnchor` — already handles while-loop self-close
- Tier-1a / nativegen — `.link` traces already execute through `driveChain`
- `tropt` — link traces already skip optimization

### While loop-done materialization (LANDED with this doc)

Originally scoped as a follow-up; implemented in the same arc because
without it the link machinery deadlocks (the outer root's LINNER abort
record-gates the outer anchor, prime-side arming is population-capped, and
no continuation could ever arm at a while's post-loop pc):

- `whileLoopDonePostPc` / `isWhileLoopDoneGuardIndex` — anchor-tied
  classifier: a `guard_true` whose source is a forward `jmp_if_false` whose
  branch target's preceding instruction is a backward `jmp` to the trace's
  own anchor. Returns the post-loop pc (the branch target). Rejects
  unrolled inner whiles and inlined-frame guards structurally.
- `maybeArmContinuation` — while-done exits arm the continuation at the
  post-loop pc (numeric-for keeps `guardExitPc`).
- `continuationReachesEnclosingBackEdge` — backward `.jmp` to/behind the
  inner anchor recognized as an enclosing back-edge (while-in-while).
- `driveChain` / `driveBurstCore` — a `.while_done` `ExitMaterialization`:
  **no flush is owed** (the guard sits at the trace TOP; every completed
  iteration already committed at its `.loop` terminal — the failing pass
  ran only the condition prefix), and the walk/resume pc is the post-loop
  pc, not `guardExitPc` (which is the body start).

### Execution flow after the change

1. The inner while loop (`:55`) first gets a root trace via `onBackEdge`
   (this happens naturally during interpreted warmup)
2. The outer for-loop root (`:9`) starts recording. When it reaches the
   inner while loop's backward `jmp`, `recWhileLink` aborts LINNER — the
   root doesn't link, it aborts so the continuation machinery takes over
3. A continuation recording is armed at the outer `:9` back-edge. It
   records the outer body: `if i < j`, swap, `local k = n`
4. It reaches the inner while loop's backward `jmp` (re-entry to `:55`)
5. `recWhileLink` fires: finds inner root at `:55`, sets `link_target = 55`,
   closes the continuation with a `.link` terminal
6. At runtime: the continuation runs the outer body, hits the `.link`, and
   `driveChain` enters the inner while root
7. The inner while root runs for as many iterations as the trip count allows,
   then **deopt-exits via its loop-done branch guard** (ordinary side-exit)
8. Tier-0 resumes at the while-loop header, re-evaluates the (now-false)
   condition, and continues past the while loop: `j = j + k` and the rest
   of the outer body, then the outer `for_loop` back-edge
9. The outer continuation re-enters at `:9`, driving the next outer iteration

**Update (landed):** the loop-done materialization above means step 7's exit
no longer deopts to tier-0 — `driveChain` walks continuations at the
post-loop pc (`.while_done`, no flush owed) on both tiers, so the
I→C ping-pong runs the post-while tail and the outer back-edge on trace.

### LLEAVE + unconditional LINNER (LuaJIT `rec_loop_interp` parity)

Landed with this arc after the first end-to-end run exposed two races:

1. **LLEAVE** (`AbortReason.loop_leave`): a ROOT recording anchored at a
   while/repeat header that observes its own loop's exit direction on the
   condition branch aborts — "must loop back to form a root trace"
   (LuaJIT `LJ_TRERR_LLEAVE`, `lj_record.c:636`). Without it the root
   wanders into the enclosing loop and commits a rotated outer trace at
   the inner anchor — frequently type-unstable across the enclosing
   back-edge (`local k = 64` int vs the body's float — the nativegen
   RV-3 analyze bail), which then poisons the anchor. Detection is
   anchor-tied and structural in `recBranch` (while: forward
   `jmp_if_false` whose target's predecessor is a backward `jmp` to the
   anchor; repeat: backward `jmp_if_false` to the anchor, fall-through).
2. **LLEAVE fast retry** (`config.lleave_fast_retries`, default 8): which
   pass a recording lands on (cond-true → the body root we want,
   cond-false → LLEAVE) is a race against the loop's trip pattern, so a
   `loop_leave` abort under budget skips the record-gate strike and
   rewinds the warming counter (`hotloop - 1`) so the next back-edge
   re-arms — the retry lands on the same instance's next trip. Past the
   budget the loop has proven a low/zero remaining-trip pattern: strikes
   resume, and `recWhileLink` lets an enclosing root unroll it (LuaJIT's
   `innerloopleft`, but reason-specific via the dedicated per-anchor
   `lleave_count`, exactly as LuaJIT keys on LLEAVE/LINNER penalties).
3. **LINNER for roots — superseded by unroll-first**: the arc first landed
   unconditional LINNER (a root reaching an inner while's backward `jmp`
   aborts whether or not the inner root exists yet, so the outcome is not
   a recording race). Measurement then showed the root+link decomposition
   is the WRONG topology for bounded-trip nests (3.5× worse than HEAD's
   unrolled/glue family on a `j = i % 64` nest) and the RIGHT one for
   high-trip whiles (4× better on nsieve-bit-fp scale 12). The landed
   policy is evidence-based per anchor — see "Topology arbitration".
4. **Per-anchor `native_unsupported` gate respects compiled siblings**
   (`gateNativeUnsupported`): "unsupported" is a per-TRACE verdict; the
   anchor is no longer dispatch-gated while a compiled sibling still
   serves it. Without this, fft_bitreverse:55's float-stable body root
   was starved (176 native entries in 101M passes) because one wandering
   proveKinds-bailed sibling kept gating the anchor.

### Topology arbitration (landed after the first A/B round)

An enclosed while has THREE competing trace topologies, and the measured
winner depends on the loop's **trips per entry**:

1. **Glue figure-eight** (HEAD's organic shape, only expressible because
   mahina anchors whiles at the CONDITION, not LuaJIT's body-start
   `BC_LOOP`): two `.loop` siblings at the while anchor — the body root
   (`guard_true → body → loop`) plus a cond-false glue sibling
   (`guard_false → outer body → outer back-edge → same anchor → loop`).
   The sibling-handoff arms fuse them. Measured **78.5 cyc/it** on a
   bounded-variance nest (`j = i % 64`, avg 5 trips).
2. **Root + `.link` decomposition** (this doc's mechanism): inner body
   root + continuation; pays a runtime re-entry per inner completion.
   **137 cyc/it** on the same nest — but **4× faster** than the glue
   family on nsieve-bit-fp scale 12 (17.4s vs 70.7s), whose
   normalization whiles run ~30+ trips per entry.
3. **Outer unroll**: the outer root records through the while inline —
   correct only while the trip count is stable (trip-count variance
   kills it on branch guards).

The cost model behind the split: the glue family amortizes the
per-instance entry+seam turnstile, which dominates at LOW trips; at HIGH
trips the body loop amortizes the seam by itself and the glue siblings
only add guard pressure and family churn. Three deterministic mechanisms
arbitrate (all pure counters — replay-safe):

- **While entry-yield gate** (`.low_trip_while`, `noteWhileYield`): per
  anchor, a `while_yield_window` (64) probe of entries vs completed
  trips fed from while-done receipts in `onSideExitReceipt`; average
  below `while_yield_min_avg` (3) trips/entry dispatch-gates the anchor
  (the trace tier is a net LOSS there — fft_bitreverse pays the
  turnstile 25.5M times/run at ~1.5 trips, a measured +25% wall
  regression before this gate). Recovery is probe-based only; a
  per-receipt "one high-trip completion un-gates" rule oscillated
  (chain-driven entries bypass the dispatch gate and deliver occasional
  6-trip completions to an anchor still averaging <1). `.low_trip_while`
  gates are exempt from every clear-on-productive path
  (`clearDispatchGate`) — those receipts are the very evidence the gate
  acts on.
- **Trip-conditional glue formation** (`whileDoneHotnessEligible`):
  while-done exits count toward side-trace hotness ONLY when the
  anchor's observed average is below `while_glue_max_avg` (8)
  trips/entry. Glue siblings therefore form exclusively via the
  SIDE-trace route on proven low-trip anchors: ROOT recordings keep
  LuaJIT's unconditional LLEAVE (the fast retry lands the body root
  first, and a fresh anchor has no receipts to judge by), while `.side`
  recordings skip the LLEAVE check by kind and record the cond-false
  glue once the evidence arrives. An intermediate state that let
  enclosed-while ROOTS record through cond-false ("LLEAVE enclosure
  refinement") leaked glue-shaped roots onto high-trip anchors and was
  reverted.
- **Unroll-first root policy** (`unroll_fail`, `unroll_fail_flip` = 2):
  a root reaching an inner while's backward `jmp` unrolls by default,
  flagging the recording (`rec.unrolled_while`); an abort of such a
  recording or a `.legacy_thrash` gate on such a trace bumps the outer
  anchor's `unroll_fail`. At `unroll_fail_flip` failures the root flips
  to the LINNER abort and the decomposition takes over. Stable-trip
  nests keep the cheap unrolled shape; variant-trip nests earn the
  link.

Measured matrix (ReleaseFast, vs HEAD baseline, this machine):

| workload | base | landed | note |
|---|---|---|---|
| nest `j=i%64` (2M outer, avg 5 trips) | 0.07s | 0.07s | glue via side route |
| nsieve-bit-fp scale 12 (~30+ trips) | 70.7s | 17.4s | decomposition, 4× |
| nsieve-bit-fp bench scale | 287.7ms | 256.2ms | |
| scimark-fft bench scale | 387.8ms | 307.7ms | yield gate: :55 anchor 4M→389 gated entries |
| scimark-fft 20000 reps | 12.3–13.1s | 12.4–13.7s | noise-level parity |
| scimark-lu bench scale | 167.0ms | 165.6ms | after hot-path fixes below |

**Hot-path cost lesson (scimark-lu +10% regression, fixed):** the
per-completion productive path runs 2M+ times per lu run, and three
innocuous-looking additions cost ~10% wall between them until profiled
(`perf stat` showed +1.4B instructions, `perf report` put ~10% under
`AnchorKey` hashing): (a) map lookups passed as ARGUMENTS to the
comptime-disabled `dbg()` — argument expressions are evaluated even when
the body compiles to nothing; hoist them into locals that the branch
already needs; (b) `clearDispatchGate` as getPtr+remove = two hashes
where base's bare `remove` paid one — use `getEntry`+`removeByPtr`;
(c) re-classifying the same exit (`isAnyLoopDoneGuardIndex` /
`isWhileLoopDoneGuardIndex`) up to four times per exit — classify once
into `numeric_for_done`/`while_done_exit` locals and reuse.

### Correctness argument

1. **Determinism**: the link decision is a pure function of `(proto, target_pc,
   findLoopTrace result)` — all deterministic. No runtime values affect the
   decision.
2. **Sound hand-off**: the inner root anchors at `target_pc` and its
   `entry_slots` are populated from `slot_load`s during root recording. The
   continuation's φ writeback ensures all modified slots are coherent at the
   link point.
3. **Zero-trip safety**: the inner root's first instruction is the while
   condition comparison + branch guard. A zero-trip fires the guard immediately
   → side-exit to tier-0. No "assumed ≥1 iteration" invariant to violate.
4. **Unrolling fallback**: for SIDE/continuation recordings with no inner
   root yet, the `.jmp` stays a no-op and the body unrolls — the historical
   behavior; the inner loop's own `onBackEdge` eventually arms a root. For
   ROOT recordings the fallback is the innerloopleft escape only (see the
   LLEAVE section): a proven low/zero-trip inner may be unrolled; otherwise
   the root aborts LINNER and waits for the inner to trace.

### Expected impact

- `fft_bitreverse`'s inner while loop transitions from unrolled-in-continuation
  (dead on trip-count mismatch) to linked (inner root handles variable trips)
- scimark-fft's `:9` outer trace residency should improve significantly
- General: any benchmark with a while inner loop inside a traced outer loop
  benefits. This is NOT a benchmark-specific optimization — it extends the
  linking machinery to a loop type that was missing (rule Z-6).

### Verification

- `just test` — all green
- `python3 tools/hashgate.py` — 84/84
- `--jit-stats` on scimark-fft: `:9` residency should increase
- `just bench`: no regressions, `cross=ok`

Test cases (landed in `interp_tier1a_test.zig`, "doc 38:" prefix):
1. **Basic while-link**: variable-trip while inside a for; `.link` terminal
   committed, its target is a cached `.loop` root's anchor, `link_ir_exits`
   and `link_follow_count` non-zero, tier-0 output parity
2. **LINNER holds (no unroll)**: with `unroll_fail_flip = 0` (decomposition
   mode — the organic default unrolls first), no cached trace carries ≥ 2
   `jmp_if_false`-sourced branch guards (the unroll signature)
3. **Native**: same nest under `--jit-native`; `native_link_exits` /
   `native_link_follow_count` non-zero, parity
4. **Always-zero-trip while**: the while anchor never warms; the outer root
   traces over the condition (no LLEAVE — not its own exit; no LINNER — the
   backward `jmp` is unreachable); parity
5. **`repeat..until` exclusion**: backward `jmp_if_false` never links — no
   `.link` trace commits; parity
6. **Yield gate**: a low-trip while (`i % 3`) with `while_yield_window = 8`
   and `unroll_fail_flip = 0` commits a `.loop` root AND earns a
   `.low_trip_while` dispatch gate

Results on this machine (ReleaseFast, `--trace --jit-native`) — see the
"Topology arbitration" matrix for the full A/B. Anchor-level: the
decomposition lifted a synthetic high-trip nest from 0% → 92.3% traced
iterations (100% link follows), and nsieve-bit-fp scale 12 runs 4× faster;
`fft_bitreverse:55` commits a healthy body root but its ~1.5 trips/entry
average makes the trace tier a net loss, so the yield gate holds it at
tier-0 (dispatch entries 4M → 389 — that IS the win there).
`fft_bitreverse:9` stays 0%: its carried slots are int/float unstable
(`j`/`k` — the Fable finding); needs the numeric φ widening arc
(LuaJIT `CONV int→num` unification), the named next technique.
