# CURRENT TASK — Nested-loop trace linking, Phase 4 (native-to-native chain)

Governing intent (Bart): close the LuaJIT gap one named technique at a time. The
current lever is **nested-loop trace linking** — let an outer loop containing an
inner numeric-`for` tier up the LuaJIT way (the inner loop is the root trace; its
loop-done exit spawns a *continuation* side trace that records the outer body and
links back to the inner root), instead of aborting at the inner `for_prep` and
running the whole nest on tier-0. Approved 5-phase plan:
`~/.claude/plans/rosy-noodling-catmull.md`. Design doc:
`docs/design/15-nested-loop-linking.md` (the proof-obligation contract P1–P4).

This is a **structural JIT-coverage** feature, not codegen tightness. No speedup
until Phase 4 makes the chain native; Phases 1–3 deliver correctness behind the
gate. Tasks: #19 (Phase 1, done), #20 (Phase 2, done), #21 (Phase 3, done),
#22 (Phase 4, done — this session).

## Phase 4 — DONE, GREEN (native chain; implemented by Codex, reviewed here)

Native-to-native chain landed. `just test` green (742 tests, 10-mode matrix +
keyframe/replay goldens). **Payoff measured** (`just bench --filter grid_matmul`,
ReleaseFast): the nested-loop benchmarks now run **6.6× faster than tier-0** on
`grid_matmul` (243.4 → 36.7 ms) and **7.3×** on `grid_matmul_f64` (251 → 34.6 ms),
`cross ok` / `luajit ok`. nsieve + both grid nests link natively
(`native_link_exits` 2 / 198).

### What Phase 4 does

- **Native exit ABI.** `CompiledTrace.run` now returns `irinterp.ExecResult`
  (`completed` + deterministic `exit_instr`) via an `rdx` out-param (`NativeResult`,
  reserved out of both allocator pools). Each body guard routes through a per-guard
  stub that stamps its IR index `i` before the shared deopt flush, so native's
  `exit_instr` == tier-1a's `exit_instr` (both = the failing IR index) **by
  construction**. Prologue declines stay `maxInt` (entry decline, not a chainable
  loop-done). This is what lets a native inner root distinguish its numeric-for
  loop-done guard from ordinary guard/prologue exits.
- **`.link` lowering.** `nativegen.compile` accepts a `.link`-terminated
  continuation; the `.link` arm flushes slot-bound φ hand-off snapshot and returns
  the link instruction index.
- **`tryChainProductiveLoopDoneNative`** (trace.zig) follows continuation ⇄
  inner-root through compiled native pages when both sides are native-able, same
  bounded resume-PC rules as Phase 3; falls back to the tier-1a chainer otherwise.
- **Link-aware loop-done epilogue** (the review fix, see below): the dispatcher
  enters a root that already has a `.link` continuation via a link-aware native
  mode (`runLinkedLoopDone`, a runtime flag in `NativeResult`). Only the numeric-for
  loop-done guard takes a special epilogue that commits post-guard sunk stores
  (`astore`/`hstore`/`gstore`, via the same `emitAStore`/`emitHStore`/`emitGStore`
  helpers the body uses — one source of truth) + φ writeback before returning.
  Ordinary guard exits keep the normal native deopt contract, so single-loop native
  traces are unchanged.

### Review finding (caught here, fixed by Codex) — store under-commit

First Codex round passed `just test` green but was **wrong**: the native chain
silently dropped **one outer iteration's entire inner-loop store pass**, exactly
once, at the outer iteration where the native link first engages (native deopt
exits before committing the sunk final-iteration `astore`). It was masked because
the scalar continuation accumulator uses idempotent φ-writeback — so Codex's
scalar-only Phase-4 test could not see it, and no store-bearing native-linking nest
existed in the matrix. Found empirically: a `a[j]=a[j]+i` inner store diverged
under `--jit-native` only (tier-1a chain stayed byte-identical); inner=30 lost
outer i=256, inner=50 lost outer i=23 (deficit uniform across all cells, fixed for
all larger outer bounds). Fix = the link-aware loop-done epilogue above. Now
byte-identical across a 128-config sweep (inner ∈ {30,50,64,99,100,101,128,200} ×
outer ∈ {24..700}) + hash-store + triple-nested shapes. **Regression added** in
`src/interp.zig`: `"nested-loop: native linked array stores commit exactly once
(Phase 4)"` — the additive-store repro, compares tier-0/tier-1a/native, asserts
`native_link_exits > 0`; fails-before / passes-after (verified).

### Phase-4 files touched

- **`src/nativegen.zig`** — `NativeResult` out-param ABI + per-guard exit stubs;
  `.link` accepted + lowered; `runLinkedLoopDone` + `isNumericForLoopDoneGuard` +
  the loop-done store/φ epilogue; store-emit helpers factored (`emitAStore` /
  `emitHStore` / `emitGStore`) and shared by body + epilogue.
- **`src/trace.zig`** — `tryChainProductiveLoopDoneNative` + `native_link_exits` /
  `native_link_follow_count` counters.
- **`src/interp.zig`** — dispatcher pre-detects an available `.link` continuation
  and enters the inner root in linked-loop-done native mode; native productive
  loop-done exits try the native chainer; the Phase-4 store regression test.
- **`docs/design/15-nested-loop-linking.md`** — Status → done (Phases 1–4);
  Phase-4 checklist ticked; P4 discharged; the store-regression note.

Outstanding (not required for Phase 4, future work): a true in-machine-code direct
tail-jump continuation→inner-root (the landed chain is dispatcher-mediated
native-to-native — each side runs native, the chainer bounces between them). And
2D-grid `m[i][j]` nests still abort recording at fused `get_index2`/`set_index2`,
so they don't link yet (grid_matmul links via the row-accumulator nest, not the
fused 2D store).

## Phase 3 — DONE, GREEN

`ZIG_GLOBAL_CACHE_DIR=/tmp/zig-global-cache just test` green (5/5 steps; 10-mode
determinism matrix + keyframe/replay goldens). Output remains byte-identical
across trace-off, record-only, tier-1a noopt/opt, native mode, and gc-stress. The
`.link` terminator is now executed on the tier-1a exit-PC chain and covered by a
test that asserts the `.link` arm and link-follow counters are both non-zero;
native linking is still deferred to Phase 4.

### What Phase 3 does

The inner loop remains the root trace. The review bug was that the dispatcher
only called `tryChainExit` on zero-iteration side exits; a normal inner loop-done
exit is productive (`completed > 0`), so committed `.link` traces were never
followed. Productive loop-done exits now try the link chain after the continuation
has been recorded. Before entering the continuation, the chainer commits the
final numeric-for iteration's linked hand-off state from the executor scratch:
sunk stores plus slot-bound φs, while leaving the visible loop var at tier-0's
last in-bounds value. It then executes the continuation to `.link`, flushes the
continuation's φ snapshot into the tier-0 register file, and enters the cached
`.loop` inner root. This ping-pongs continuation ⇄ inner-root under the existing
8-hop bound until a real exit.

The guard PC detail is load-bearing: `recordInstr` stamps the post-increment PC,
so the loop-done guard's `aux` is the post-inner-loop continuation anchor and the
actual `for_loop` bytecode is at `exit_pc - 1`.

Roll-up is explicit: an inner root that exits at the continuation anchor's pc has
completed exactly one enclosing-loop iteration. That counts as a successful outer
completion even when the inner root reports `completed == 0`, so a correct
one-trip/loop-done hand-off is not penalized as a low-yield trace.

The chain result carries an optional resume PC. Same-loop side traces resume at
the caller's current loop header. Linked nested-loop bursts resume at the
post-inner-loop PC when registers are at the continuation anchor (including a
flushed initial loop-done exit whose continuation exits before `.link`), or at
the inner root anchor when the 8-hop bound yields immediately after a `.link`;
resuming at the post-inner PC in that state skips a whole inner loop.

### Phase-3 files touched

- **`src/irinterp.zig`**
  - `.link` now performs the same slot-bound φ writeback as `.loop` before
    returning the link exit. This lands the continuation hand-off snapshot
    (`R[a]=init`, `R[a+3]=init`, plus any other carried slots) before entering the
    inner root.
  - Added the linked-only numeric-for loop-done flush used by `tryChainExit` to
    commit the final inner iteration without changing ordinary loop-header deopt.
- **`src/trace.zig`**
  - Removed the inert-link skip from `tryChainExit`; linked continuations now run
    through tier-1a and resolve their `aux` to a cached `.loop` root.
  - Added roll-up for inner loop-done exits and kept the existing 8-hop chain bound.
  - Added `ChainResult.resume_pc` and link execution counters used by the Phase-3
    proof test.
  - Fixed the flushed-but-unlinked tier-1a boundary: after
    `flushNumericForLoopDone` commits a loop-done iteration, the chainer now
    returns a resume PC instead of falling back to loop-header deopt, so sunk
    stores are not replayed by tier-0.
  - Tightened `recForPrepLink` to require `findLoopTrace(...)` rather than any
    cached trace at the inner anchor.
  - Generalized continuation arming to nsieve's shape: the post-inner pc may run
    straight-line outer-body work before reaching the enclosing back-edge. Branch
    guards are filtered out by requiring the failed guard to come from `for_loop`.
  - Made the `for_loop` back-edge layout check a runtime abort instead of a
    debug-only assertion.
  - Added `clearPendingExitAnchor` for stale pending-arm cleanup.
- **`src/interp.zig`**
  - Same-anchor trial walk now explicitly skips `.link` traces; they execute only
    via exit-PC chaining.
  - VM execution clears stale `pending_exit_anchor` on finish, suspend, or error
    unwind.
  - The nested-loop `expectProgram` test now exercises linked Phase 3 execution
    across the 10-mode matrix with a nsieve-shaped statement after the inner loop.
  - Added focused `runExecForTrace` tests that compare against tier-0 output and
    assert `link_ir_exits > 0` and `link_follow_count > 0`, including an additive
    array-store regression for exactly-once store commit.
- **`viz/src/enums.ts`**
  - Fixed the stale opcode ordinal comment (`0..56`).

### Review items folded into Phase 3

- [x] `.link` writes back its exit snapshot before hand-off.
- [x] Same-anchor trial walk explicitly skips `.link`.
- [x] Link precondition requires a cached `.loop` root.
- [x] `pending_exit_anchor` cleanup on finish/suspend/error unwind.
- [x] `for_loop` back-edge identity is checked at runtime.
- [x] Productive loop-done exits actually route to the cached `.link`.
- [x] Linked execution is proven by counters, not output alone.
- [x] Flushed loop-done exits return an explicit resume PC on every chain
      termination path, so tier-0 neither repeats nor skips committed stores.
- [x] `viz/src/enums.ts` ordinal comment updated.
- [x] `flushNumericForLoopDone`'s `gstore` arm is annotated as defensive only:
      linked 2D-grid nests currently abort recording at fused `get_index2` /
      `set_index2` before any continuation link can commit, so no linked flush
      reaches `gstore` today.
- [x] Keyframe loose end closed honestly: the F2c harness is tier-0-only
      (`referenceRun` / `expectResume` use `Vm.init` and never enable
      `trace.config.enabled`), so a literal cut inside a tier-1a link is not
      feasible there. Added a dedicated F2c 400×60 linking-shaped nested
      numeric-for test that proves the same bytecode shape resumes
      byte-identically from a tier-0 keyframe; linked execution itself remains
      proven by the Phase-3 `link_ir_exits` / `link_follow_count` tests.

## Phase 2 — DONE

The Phase 1 continuation (armed on a productive inner loop-done exit, anchored at
the post-inner-loop pc) records the outer body forward and re-reaches the inner
`for_prep`. Phase 2 turns that LINNER abort into a **link**: `recForPrepLink`
reconstructs the inner root's **entry state** and closes the trace with a new
`.link` terminator naming the inner root's anchor pc.

### Hand-off correctness fix (post-review, this session)

A code review (codex + antigravity) plus an empirical IR dump of the inner root's
`entry_slots` disproved the original P2 claim. The inner root anchors at the loop
**body start** and records **body-first**, so its entry state (reached only after
`for_prep` AND the first `for_loop`) is `R[a] = init` **and** the visible loop var
`R[a+3] = init` — both live entry inputs — **not** `R[a] = init − step` with
`R[a+3]` stale. `recForPrepLink` now: guards `init`/`limit`/`step` are numbers (the
`limit` guard was previously missing), emits a first-iteration bounds guard (`init`
within `limit`) so a zero-trip inner loop side-exits to tier-0, and publishes
`R[a] = init` + `R[a+3] = init` into the exit snapshot. Verified by dumping the
link trace IR: `phi(R5) ← init`, `phi(R8) ← init` (were `init−step` / missing).
In Phase 2 the link stayed inert, so the gate remained byte-identical; Phase 3 now
executes that corrected snapshot. P2 in `docs/design/15-…` was rewritten.

### Mechanism (files touched)

- **`src/trace.zig`**
  - New `IrOp.link` (wire ordinal 56, appended at enum end). Terminal like `.loop`;
    `aux` = inner root anchor pc; no operand refs.
  - `Recorder.link_target: ?u32` — set by `recForPrepLink`; `commit()` appends
    `.link{aux=link_target}` instead of `.loop` and caches **unoptimized** (skips
    `tropt`, whose LICM/φ machinery + `instrs[n-1].op == .loop` assert are
    loop-only; Phase 3 executes the unoptimized straight-line continuation).
  - `Recorder.is_continuation: bool` — set only by `maybeStartContinuation`.
    `recForPrepLink` links **iff** continuation (a *root* recording reaching an
    inner `for_prep` still LINNER-aborts — LuaJIT's model; also keeps link anchors
    off real back-edge targets).
  - `recForPrepLink(instr, regs, proto, pc)` — dispatched from the new `.for_prep`
    arm in `recordOne`. Locates the matching `for_loop` (`pc + instr.aux`, verified
    `.op == .for_loop`); inner anchor = `pc` (= the `for_loop` back-edge target =
    body start); links iff a cached `.loop` root exists, else `.nyi_opcode` (LINNER).
    Records `guardNum` idx/step + `.sub`, sets `link_target`, `closeTrace`.
  - `assertWellFormed` accepts `.loop` **or** `.link` as the sole terminal.
  - In Phase 2, `tryChainExit` skipped `.link` traces; Phase 3 removed that skip
    and follows them.
- **`src/irinterp.zig`** — Phase 2 added the `.link` arm; Phase 3 made it flush
  the hand-off snapshot before returning the link exit.
- **`src/tropt.zig` / `src/troptdiag.zig`** — `.link` arms for switch
  exhaustiveness (classified like `.loop`: terminal, no operands/uses).
- **`src/traceser.zig`** — ordinal contract updated (ordinal 56, count 57).
- **`viz/src/enums.ts`** — `IR_OP_NAMES` + `NO_OPERAND_OPS` mirror.

### Bundled Phase-1 fix (in this commit)

`src/interp.zig`'s `runFastPath` now also holds `.full` while
`pending_exit_anchor != null` — without it, after a productive exit's
`switch_mode` the loop re-picked `.fast` and the `.full`-only activation hook
never fired, so the continuation arming stuck pending forever at production
`hotloop = 56`. Logically a Phase-1 correctness fix; it lives in `interp.zig`
alongside the Phase-2 test rewrite, so per Rule #13 (no partial-file commits) it
ships in the same commit.

### Test (green, `src/interp.zig`)

`"nested-loop: a hot inner loop's continuation links to the inner root at the
inner for_prep (Phase 2)"` — `runExecForTrace` (hotloop=4) on the 40×30 nest,
output `381300`, asserts a `.link`-terminated trace is cached **and** its `aux`
resolves to a cached `.loop` root (the inner numeric-for). Replaces the Phase 1
"second for_prep abort site" test (that abort is now a link). The `expectProgram`
10-mode test still pins byte-identical output.

### Gotcha worth remembering

`min_trip_entry = 24`: an inner loop with fewer than 24 trips is **declined** at
tier-1 entry, so its loop-done exit never runs through `irinterp` and the
continuation cannot arm. The tests use a 30-trip inner loop.

## Next — the 5-phase plan is complete (Phases 0–4 all landed)

Optional follow-ups (not part of the approved plan): the in-machine-code direct
tail-jump chain, and extending native linking to 2D-grid fused-store nests (they
currently abort recording). Neither is required — nested numeric-`for` loops now
run native end-to-end.

## Uncommitted tree (Phase 4 — awaiting Bart's commit decision)

Modified (Phase 4): `src/nativegen.zig`, `src/trace.zig`, `src/interp.zig`,
`docs/design/15-nested-loop-linking.md`, `CURRENT_TASK.md`. (`src/main.zig` debug
instrumentation used during review was reverted — no diff.)
Untracked files (`CURRENT_TASK_E3.md`, `SESSION_CHANGES.md`,
`bench/results/*.tsv`, `check_ordinals`) belong to other agents — **do NOT stage**.
