# CURRENT_TASK — Campaign: every benchmark ≤1.2× LuaJIT (Bart 2026-08-20 mandate)

Loop: profile → worst *general* gap (Z-6) → design → codex (gpt-5.6-sol) review →
Claude implements → gate battery + board → commit → next arc. No per-arc reports
to Bart; this file + the design docs are the record.

Campaign map (from --dump-aborts across the board, 2026-08-20): (1) builtin
recording breadth — ffrecord beyond math.sqrt (scalar 37.6×, partialsums 6.9×,
str_format 18.5× host_barrier call) — **CORRECTED 2026-08-27 (LATEST-84): the
dominant cause of scalar's and str_format's gap was NOT ffrecord but the string
interner (82–89% of runtime); fixed, scalar 4.0×/str_format 3.2×. ffrecord
remains the lever for what's left of them (both now tier-0-bound on dispatch +
builtin calls) and for partialsums** — **arc A landed 2026-08-27 (LATEST-85):
partialsums 2.0×; scalar/str_* remainder is arc B (allocating builtins)**; (2) **[REFRAMED, see LATEST-72]**
Pall-shape nest coverage — NOT "root-recording linkage" (the `.root` LINNER
abort is Pall-faithful, lj_record.c 605–700); the real gaps are backend:
heap φ writeback + seeded-trace seams + inner-root owner election (nbody
38.5×; sparse/euler14/matmul outers abort earlier — recheck after);
(3) return tracing / up-recursion + call-site
hotness (recursive-fib 20.8×, binary-trees 5.5×, cross_frame ret everywhere);
(4) heap-valued (function/table) hash field loads + generic-for (array3d 90×,
method calls). Undiagnosed yet: spectral-norm 28.9×, repack 11.0×.

## HANDOFF → codex (2026-09-16)

Bart is out of Claude budget; you (codex / gpt-5.6-sol) are picking up the
campaign as the implementer. You already know this codebase as the design
reviewer — doc 49 was your review (thread `01a0a86c-f747-7db3-95c5-d4b1e3b7c664`).

**State of the tree**
- HEAD = `76198e5` (doc 49 arc: owned hash part + hrefk, nbody 23.3×→13.4×).
  Full `just test` green; board TSV `bench/results/20260916-141459-858834f.tsv`.
- **master is ahead of origin — do NOT push without Bart's say-so.**
- Older status sections moved to `CURRENT_TASK_ARCHIVE.md`; canonical design
  record is `docs/design/` (start: `00-architecture.md`, then 47/48/49).
- Untracked TSVs from parallel agents may exist under `bench/results/` —
  leave them alone.

**Next-arc candidates** (from the post-doc-49 nbody profile, latest+15 below;
Bart picks, or default to the most *general* gap per Rule Z-6):
1. **Nested `for_prep` tracing** (`nyi_opcode for_prep`): outer loops never
   trace anywhere — nbody advance:4 (13.6% of run), and the same abort gates
   every nested-loop bench. Biggest general rock; tier-0 no-trace is 32.3%
   of nbody cycles and `liveSlotOf` 31.9% of its profile is those tier-0
   probes.
2. **`aliased_input get_upval`** (nbody main:211, 18.5% of run).
3. **replayLedger seam** (~1028 cyc/walk, 16% of nbody run). READ Rule Z-8's
   diagnosis ladder in `CLAUDE.md` + doc 17/47 BEFORE touching this — exit
   patching already exists; do not rebuild it.
4. **Task #18 / doc 44 return tracing** (recursive-fib 27.2×, btrees 9.8×) —
   an in-progress arc with its own doc.
5. Doc 49 defers: guard_hash subsumption on hrefk chains, on-trace insertion
   (asm_newref analogue), scalar-key hrefk.

**Discipline digest** (full text in `CLAUDE.md` / project rules — these are
the ones that bite):
- Profile FIRST (`perf` recipe + tier rollup in CLAUDE.md); `--jit-stats`
  before declaring any bench flat; never conclude a regression from one run —
  ×3 interleaved re-runs (this arc: 3 apparent regressions, all noise).
- Benchmark ONLY via `just bench` (rebuilds ReleaseFast); `just shadow` for
  A/B baselines; a plain `zig build`/`just test` leaves a Debug binary.
- Z-6: never optimise for a single benchmark — fix the general gap.
- Z-1: verify Zig stdlib against the pinned toolchain source; your training
  data about `std` is wrong.
- Debug probes via `src/jitdbg.zig` (`-Djit-debug` + `--jit-debug`), never
  ad-hoc prints.
- New arcs get a design doc (`docs/design/`, status header + Done/Outstanding
  checklist) and land behind full `just test` + board + noise-checked diff;
  update the doc's checklist and this file in the same change.
- Test gotcha (cost me an hour this arc): raw test-created heap objects have
  `GcHeader.id = 0`, and heap `Value.eql`/`hash_part.keyHash` compare BY ID —
  multi-key tests must assign distinct ids (see `assignIdWithSlot` in
  `src/nativegen_hrefk_test.zig`).
- LuaJIT source is at `~/Projects/LuaJIT/src/` — read how Pall did a thing
  before declaring it hard; "replay/determinism forbids it" only ever means
  *adapt* the mechanism (ids not addresses, deterministic counters).

## Status 2026-09-24 (latest+27) — doc 55 §2 + §2d LANDED: fft 14.6× → 12.6× LJ, sparse −31%; silent switch is now data (no runtime code patching)

The record is doc 55 §2 / §2d.
- **§2 had three causes, all fixed.** (a) The inner loop-done lands in
  sibling t7, which was not a region member. It is fixed with a separate
  `arrival_entry_regions` index (Bart's pick, "two indexes").
  `dest_entry_regions` stays the strict member proof for bridge child
  selection; a one-map version broke nsieve by arming the bridge into a
  deopting sibling. (b) Stage tails (2^k − 1 laps) struck the region.
  `beginClose` now waives a `0 < work < N` close after a useful window.
  (c) The silent path counts committing kinds as progress.
- **§2d:** (b) exposed that every silent promote/demote rewrote machine
  code through `mprotect` (lu 53k calls, fft 60k). LuaJIT never flips code
  per activation (`lj_asm_patchexit` is one-way, on side-trace attach). So
  each promotable exit now has a permanent compiled check of its data cell
  (`emitSilentCheck`), and promote/demote are cell writes (Bart's pick,
  "option 1"). The patch machinery is removed, and so is the `arena`
  parameter on promote/demote/`prepareSlotMutation`/`publishValidatedLink`.
- **Measured:** board fft 242.8 → 207.2 ms, sparse 179 → 123, sieve_int
  −20%, repack −11%, nsieve −10%, binary-trees −8.5%, no regressions (the
  fib +5% board delta is noise per an interleaved A/B). lu `mprotect`
  102 → 14. `just test` and the jit-debug gate are green.
- **Review:** Antigravity (codex out until 09-29): APPROVED WITH NITS, both
  applied. Duplicate-exit sets are refused in `checkPromotable` (the old
  patching refused them by accident), pinned in the B-3b.2 test; the tail
  waiver is explicit about `work > 0`. A codex re-review of §1/§2/§2d is
  owed.
- **Next: §3.** fft `--jit-stats`: tier-0-with-a-trace is **63% of the
  run**. That is the bit-reverse peeled traces (`fft_bitreverse:9`, `:55`;
  doc 40 fusion exclusion + the doc-38 `low_trip_while` gate). Needs a
  design pass (doc 40's open question). Doc 54 P3 is still outstanding.
- Naming debt, not done: `ExitPatch` / `ExitPatchKind` /
  `exit_patches` / `emitPatchableExit` still say "patch", though nothing is
  patched any more. It's a rename across ~9 files; left for Bart to decide.

## Status 2026-09-24 (latest+26) — NEW ARC: scimark-fft (weakest bench, 23.3× LJ), doc 55 §1 LANDED (fft → 14.6×); §2/§3 next

Bart picked fft over doc 54 P3 (P3 stays outstanding in doc 54). The
record is `docs/design/55-fft-nest-cycle-residency.md`.

**Finding (Z-8 ladder).** The fft nest traces all exist and are armed as one
cycle: t6 inner `:131` →loop_done_linked→ t7 `:193` →deopt ei=8,
sibling_handoff→ t8 `:193` →link_terminal→ t6. Two zero-progress detectors
each judge it dead:
1. **§1 (fixed in tree).** `provenanceEdgeVerdict` measures progress by
   `cum` (back-edges) only. The last butterfly stage has one-trip inner
   loops, so cum stays flat and the edge is retired permanently after 3
   strikes. Fix: `LedgerKind.commitsGuestWork()` plus a `suffix_commits`
   bit. Tests are in `trace_provenance_test.zig`. Result: entries 1.02M →
   100k, follows 8k → 924k, fft A/B 363 → 252 ms, board 393 → 243 ms, no
   regressions (binary-trees +6% on the board is noise; interleaved A/B
   shows it faster). `just test` green; jit-debug gate exit 0.
2. **§2 (open).** The region activation closes after EVERY t6
   loop_done_linked row (`region: close rid=0 ... work=1`, new probe). That
   gives 8 window-strikes, then a fallback-owner tombstone during warm-up,
   so there's no silent promotion and rows mode costs 30.6% of the run.
   Next step: pin which close site fires and which membership lookup fails.
   Also: the silent epilogue has its own cum-only productive definition,
   which must be reconciled.
3. **§3 (open).** The bitreverse peeled traces are 43% of the run and ~0%
   traced (doc 40 fusion exclusion + `low_trip_while`).

**Review:** Codex is out of credits until 2026-09-29. At Bart's direction,
Antigravity reviewed §1: APPROVED, no blockers. §1 is committed; a codex
re-review is still owed. Antigravity also gave a §2 lead: the close fires in
`applyDestination` because t7 is not in the region's `member_trace_ids`, so
`dest_entry_regions` misses it. Verify that first. Baseline shadow:
`/tmp/lune_d55_base` (HEAD `1c5d1fb`). New dbg probes: `provenance-retire:`,
`region: close`.

(§2 was resolved in latest+27 above; its bisect, the LuaJIT flip-cost
reading, and the options Bart chose between are recorded in doc 55 §2/§2d.)

## Status 2026-09-19 (latest+25) — doc 54 P2 + AMENDMENT LANDED: fib 171.6→~81-87 ms, 24.7×→~10× LJ; episodes 925k→2.3k (task #43)

**The latest+24 block below is resolved.** Bart chose "amend doc 54 + codex
review"; the amendment (rowless armed non-frame transitions with one-shot
targets post-motion) went through 3 codex rounds on the arc thread
(`01a0b527-c784-7983-9fc6-16730a34f5d6`), verdict **APPROVED**, and is now
implemented, gated, benched, and committed together with the held P2 tree.

**What the amendment is** (full spec: doc 54 "### P2 amendment"): post-motion,
an armed `.sibling_handoff` exit whose parent AND child are one-shot pages
FOLLOWS its arm rowlessly instead of bouncing. Mechanisms as landed:
- **Deopt-tail fast path** (`nativegen.zig`, before the `.deopt` row append):
  single memory-staged target load → armed? → motion? → hop window free?
  (`NativeResult.sibling_hop_taken`) → per-slot gate byte? → budget
  dec-and-test → runtime record address (`counters_base + exit_instr*24`) →
  `emitRowFreeHitPublishReg` (new register-record core) → mark hop → `jmp rax`.
  EVERY decline falls into the unchanged rows tail (row + forced-yield bounce).
- **One-hop window**: `sibling_hop_taken` set on a rowless follow, cleared
  ONLY past the last declining check of the inline push/pop and at the two
  row-free frame-hop sites — declined motion never clears, so a zero-progress
  A→B→A cycle degenerates to the old refusal price (constant work, no hidden
  budget burn).
- **Per-slot gate** `CompiledTrace.slot_rowless_ok`, published only by
  `commitSlotMutation`'s paired commit (arm: gate-before-target; disarm:
  target-before-gate-clear; `rowlessOkFor` = sibling kind + both endpoints
  non-loop; identical-rearm short-circuit asserts gate agreement).
- **Counters** extended to `instrs.len + NATIVE_TRANSITION_SLOTS` (ordinary
  cells first, kind `.sibling_handoff`); the totals drain validates sibling
  records strongly (owner one-shot + compiled, address maps to a real
  ordinary cell) and feeds the new `sibling_link_hits` witness (jit-stats
  line "rowless sibling hits").
- **Gen saturation**: `episode_gen` saturates at maxInt(u64) in
  `prepareNativeEpisode` (advance-first), folded into `descent_ok` —
  permanent fail-closed disable instead of the rejected skip-0 wrap.

**Receipts** (fib 31 `--jit-stats`, ReleaseFast, load ~9): pushes 4.36M,
pops 4.35M (vs 32 blocked / 3.63M at P1), ret-cont hits 4.35M, call-head
2.18M, sibling hits 2.18M, trace entries **2,272** (925k at P1 — O(warmup)),
native 99.3% of cycles, 0 fallback. Bench `just bench --filter recursive`:
**87.3 ms, 10.3×** LJ (full-board run: 80.7 ms / 9.8×), res 99.5%.
Interleaved A/B vs `/tmp/lune_pre_arc` shadow: fib 0.08s vs 0.22s wall
(−2.6×), btrees neutral (~0.45s both). Full board: no regressions.

**Gates**: `just test` green; `zig build test -Djit-debug=true` green
(captured to /tmp/p2a_jitdebug_test.log). New battery: two-sibling
adversarial cycle + three-sibling divergence (ten-leg, `hotguard=2`),
gen-saturation unit pin (advance-first, saturate, dead gate, cleared
touched), and the D12c tests' capacity-cut witness (structurally dead now —
row-free chains never fill a positional ledger) replaced by
`sibling_link_hits > 0` + `frame_link_cap_yields == 0`.

**Next**: doc 54 P3 (warm entry for pushed frames — P3 wording already
updated for the saturating gen: warm-image validation rejects
`episode_gen == maxInt`). Then the post-arc measurement bullet (board +
profile + btrees re-profile).

## Status 2026-09-18 (latest+24) — doc 54 P2 IMPLEMENTED BUT BLOCKED: the two-mode grammar degenerates fib — design decision needed (task #43) [RESOLVED — see latest+25]

**State: all P2 source work is in the tree, uncommitted; 1 test red
(`ret pop formation`), and that red is a TRUE POSITIVE.** Do not land
without resolving the design question below.

**What's implemented** (compiles; boundary tool 21/21; the rest of
`just test` green): descent budget (65,536) + `frame_motion_taken` ABI
tail + runtime asserts; `LinkHitCounter` per transition slot
(page-owned, gen-stamped, bounded touched-drain ≤64 in `NativeSeedCtx`
— recorded deviation: ctx-owned, not NativeResult-tail, because
runWithLinkedLoopDone has no ctx handle; init in `prepareNativeEpisode`,
the per-episode funnel); `emitRowFreeHitPublish`; two-mode pop chain +
cont-page push rebuilt on `emitInlineSelfPush` fall-through mode;
`nativeSelfCallPush` DELETED (grammar constants retired, boundary
allowlist shrunk, refusal-matrix test retired with a walls-map note);
non-frame-arm refusal in `emitForcedYieldCheck`; `consumeMotionTotals`
consumer (zero-work invariant asserted, A1 funnel on entered ct,
per-owner accounting, shared `consumeDescentTerminalRow` extraction).

**The finding (jit-debug stream + `--jit-stats`, fib 31 ReleaseFast):**
the doc's P2 grammar self-destructs on branchy recursion. Chain:
cont-push takes the row-free `.call_head` hop (empty ledger → motion
byte set) → head page descends via same-page pushes → base case is an
ARMED SIBLING HANDOFF = non-frame arm → refused (per round-4
should-fix 4's blanket rule) → episode bounces → the unwind starts a
NEW episode at the base/cont page where net=0 → the pop's net floor
(soundness-critical, can't relax) declines EVERY pop → and with zero
committed pops there are zero `.ret_pop` miss rows, so
`noteRetContTransition` gets no evidence and ret-cont links NEVER ARM.
Numbers: pushes 4.36M (fine), **pops 32 (P1: 3.63M)**, **ret-cont
arms 0** (P1: armed+hit 5.65M), episodes **6.53M (P1: 925k — 7×
worse)**; bench recursive-fib jit 391 ms vs t0 177 ms (P1: 171.6 ms).
The doc's "one dispatcher bounce per non-frame transition — today's
price" was wrong twice: pre-P2 the sibling hop was INTRA-episode (no
bounce), and the bounce strands every downstream pop at net=0. fib —
the arc's target — hits this on every leaf.

**Why the end state needs rowless siblings**: the intended episode
(cont push → head → pushes → base → pop → cont → …, one episode per
budget window) only exists if the descent-bottom sibling hop stays
in-episode. Post-motion it must not write a row (grammar) — so it must
either be refused (implemented, degenerate) or go ROWLESS (design
amendment: extend row-freedom to armed non-frame transitions when
`frame_motion_taken` is set; sibling hop = same frame, no motion, no
row; grammar stays empty-plus-final; consumers lose only per-handoff
accounting/watch rows, post-formation). Formation stays sound under
the amendment: early pops DO commit (sibling hop keeps net>0), their
unarmed-chain misses write the final `.ret_pop` evidence rows, links
arm, then steady state goes rowless. Options presented to Bart
(awaiting direction): (1) amend doc 54 (rowless non-frame arms under
motion, + drain/accounting story) + codex review round, then finish
P2; (2) different fix he prefers; (3) park P2 (tree carries it
uncommitted or reverted) and reconsider. jit-debug probe added to the
formation test (permanent, comptime-free). Logs: /tmp/p2_dbg2.log,
stats runs /tmp/p2_fib{20,27,31}.lua.

## Status 2026-09-18 (latest+23) — doc 54 P1 LANDED: inline pop + open-upvalue ceiling (recursive-fib arc, task #43)

Commits `4084142` (enablers) + `aeddcac` (emission + battery + CI rule).
`just test` (incl. the new body-callout scanner rule) + `-Djit-debug=true`
gates green, no flake this round.

**What landed (doc 54 P1 Done notes have the detail):**
- Enablers: `Vm.open_upvalue_ceiling` watermark, all `open_upvalues`
  mutations centralized (append @max raise / closeUpvaluesFrom exact
  recompute / clear reset; keyframe restore republication), ABI offsets
  for ceiling + self_ret_pops.
- Emission: `emitInlineSelfRetPop` (descent byte → net floor → ceiling
  wall → dynamic ret wiring → SIB copy loop → region-context-clear
  replica → pop/ctx refresh/witness); static pop eligibility (ineligible
  pages emit NO epilogue); `nativeSelfRetPop` + POP grammar DELETED;
  `x64.movzxRegMem16` added with golden tests.
- **Design correction found at implementation**: the doc's "skip the
  region drop entirely" was wrong — under the gate `nextActivation` still
  clears `region_context_valid` on seq match (i.e. on every pop). The
  inline sequence replicates that residue; zero-activations premise is
  assert-pinned.
- Invariant asserts = `nativeFrameMotionAssert`, jit-debug-only C-ABI
  callout (zero release cost). Sabotage-verified: adjacency break panics
  the jit-debug gate; forced ceiling wall trips formation+ten-legs;
  stale-LOW maintenance bites in the unit matrix + restore test (the
  emitted wall is defense-in-depth until native closure minting exists).
- `check-jit-boundaries.py`: body-callout authority rule (C-ABI fns must
  not take *Vm/NativeSeedCtx outside the 3-helper allowlist) + 5 scanner
  tests; runs in `just test`.
- New tests: ceiling maintenance matrix, restore republication,
  escaping-closure ten-legs, fail-closed pop extension; helper refusal
  matrix retired (walls relocated — see the doc note in the test file).

**Measurement** (interleaved A/B vs `a0e66ae` shadow, load ~3.4): fib
199.6 → 171.6 ms ≈ −14% cumulative P0+P1 (P1 ≈ −9%); board 172.4 ms /
24.7× / res 87.2%; btrees flat 10.0×. Below the doc's P0+P1 budget for
the reason the P0 receipt named: cont-page pushes (~60% of motion) still
ride the C helper and every armed transition still writes a ledger row +
forced-yield cut — both P2 levers. `--jit-stats`: pushes 4.36M, pops
3.63M (83%), 925k episode entries (~4.7 pushes/entry; P2 wants
O(warmup)), native 84.4% of cycles.

**NEXT: P2 — row-free armed frame-motion transitions + descent poll
budget (the big lever), then P3 warm entries.**

## Status 2026-09-18 (latest+22) — doc 54 P0 LANDED: inline same-page push (recursive-fib arc, task #43)

Commits `a0e66ae` (doc), `3891fd1` (enablers), `3df7d53` (emission + battery).
Full `just test` + `-Djit-debug=true` gates green (one jit-debug flake,
occurrence 7 — TODO.md — same seed passed 1411/1411 on direct rerun + 4 more
clean gates; extra-scrutinized because fresh codegen was in the tree).

**What landed (doc 54 "Implementation status → Done" has the full notes):**
- Enablers: `code_cache_gen` `?u64`→u64 + `CODE_CACHE_GEN_INVALID` sentinel
  (the inline frame write must replicate the struct-literal cache
  invalidation — a design gap found at implementation);
  `region_context` optional→payload+valid-byte split behind accessors;
  `FrameMotionAbi` (comptime Vm/CallFrame offsets published via seed ctx —
  nativegen can't import interp); `NativeSeedCtx.descent_ok` published per
  episode by `prepareNativeEpisode`.
- Emission: commit-time static push eligibility (ineligible pages emit NO
  push epilogue); `emitInlineSelfPush` = the doc's 9-step sequence; head-page
  `nativeSelfCallPush` callout DELETED (helper stays on cont pages until P2,
  now also statically gated).
- Battery: helper-removed inline formation test; frame_abi-null fail-closed
  test; descent-gate publication matrix (unit-level — integration 0 is
  unreachable by episode-invariance, verified: planted receipt epoch-wiped,
  743 pushes anyway).

**Measurement (interleaved A/B vs a0e66ae shadow, quiet machine):** fib
≈−5% wall, 27.2×→25.2×; btrees flat 9.8×. Small as designed: ~60% of fib's
cycles run on the two CONT anchors whose pushes keep the helper until P2.
CAUTION for future benching: a parallel agent's Playwright run had the
machine at load 20 for a while — early "302 vs 187 regression!" was pure
cross-condition noise (LuaJIT itself drifted 6.9→10.1 ms). Always interleave
A/B on this box.

**NEXT: P1 (inline pop + open_upvalue_ceiling + check-jit-boundaries rule),
then P2 (row-free armed frame motion + descent budget), P3 (warm entries).**

## Status 2026-09-18 (latest+21) — doc 54 DESIGN APPROVED (codex ×7): inline native frame motion — recursive-fib arc (task #43)

Bart picked "whichever bench is currently weakest" → recursive-fib 27.0×
(186.9 vs 6.9 ms, res 86.2%!), then "straight to C, no intermediates"
(C = the full LuaJIT-parity mechanism; A = silent-promotion extension and
B = helper slimming were the rejected intermediates).

- **Diagnosis (Z-8 ladder, receipts in doc 54 "Why this exists")**:
  100% traced, 0 seam, yet ~1415 cyc/iter vs LuaJIT ~9. (1) Frame-motion
  links are barred from silent promotion (trace_link.zig:843, explicit
  v1 exclusion) → every armed `.ret_cont`/`.call_head` hit writes a
  ledger row → LEDGER_CAP(32) guillotines the episode every ~6 calls →
  925k episode entries / 879k iterations, re-entry glue ≈32% of run.
  (2) Push/pop are C-ABI callouts re-deriving compile-time/episode-
  invariant preflight per call (+ full open-upvalue scan per pop) ≈28%.
  (3) Seed callout + entry guards re-run per push via body_entry ≈8%.
  Actual [JIT] code ≈18%.
- **Doc 54 written and codex-APPROVED after 7 rounds** (thread
  01a0b428…; ledger in-doc records every blocker: seed-image window
  overlap, across-activation seed equality, positional
  consumePushedDescent grammar, budget-cut row grammar, keyframe-restore
  watermark, rows-first LEDGER_CAP retention, same-page-push row
  semantics — my deviation from codex's prescription CONFIRMED in round
  4 — bounded touched-slot drain, cross-page seed_epoch, epoch
  saturation poison). Phases: P0 inline same-page push (+ static
  eligibility, descent_ok gate), P1 inline pop + open_upvalue_ceiling
  watermark, P2 row-free pure frame-motion episodes + descent budget +
  bounded drain, P3 warm entries (page-owned stamped seed images).
  Expectation: 186.9 → 70-90 ms; remainder = body codegen (later arc).
- **Doc 44 Phase 4 bullet updated** — completion owned by doc 54.
- **NEXT: implement P0** (nativegen terminal lowering: emit the inline
  push; delete the head-page callout; sabotage-verified tests per the
  doc's protocol; gates + fib/btrees bench per phase).
- Session also: codex MCP outage root-caused (codex 0.154.0 removed
  `mcp-server`; pinned 0.153.4 via bun, Bart restarted ccui; wrapper
  TODO tracked by Bart) and docs 53 + 49 P5 codex reviews landed
  (9a2ced2, both APPROVED).

## Status 2026-09-18 (latest+20) — doc 53: open-upvalue slot canonicalization — nbody 54.5 → 19.8 ms (4.5× LJ)

Bart: "Is that 30% of time for nbody in tier-0? Lets try to work on that."
Fresh `--jit-stats` confirmed 35.3% tier-0-no-trace: `main:211` (19.8%,
`aliased_input get_upval`) + `advance:4` (15.5%, LINNER by design per doc 51
F4). Doc 51 had already anointed the get_upval abort as the next candidate —
its instrument proved the driver loop inlines the whole `advance` call once
recording survives.

- **Root cause.** Doc 43 P0a aborts any `get_upval` whose OPEN cell aliases
  the trace-writable window (a snapshot would go stale). But when the cell
  aliases the ANCHOR frame's own window, the cell IS a tracked slot — nbody's
  `advance` captures main's `local sqrt`, and tracing `main:211` died at the
  first sqrt read. The `local sqrt = math.sqrt` idiom killed every driver
  trace that inlines a callee capturing an anchor local.
- **The fix (doc 53 P0)** — mahina flavor of LuaJIT `rec_upvalue`'s SSA
  redirect (`lj_record.c`): `recUpvalSlotAlias` canonicalizes the read to
  the aliased slot's SSA value via new `refOfAbs` (refOf minus the base_off
  add — exact within a recording, the cell IS the slot, store-then-read
  ordering falls out of SSA). Cross-entry soundness: `guard_func` pins only
  PROTO id, so a same-proto closure from another live activation (cell over
  a different frame) is caught by a new VALIDATION-ONLY `.upvalue_slot_alias`
  InputSeed — all three seeding twins re-prove
  `closure_in(callee_slot).upvalues[source].loc.open == base + rel` via
  shared `upvalueSlotAliasOk`, declining the candidate otherwise (the
  `upvalue_cell` grammar; mahina's per-entry equivalent of LuaJIT's
  per-iteration `REF_BASE` guard — cheaper, valid because the relation
  can't change mid-episode: anchor never rets mid-trace, scope-exit close
  needs on-trace closure creation which aborts). Fail-closed keeps the old
  abort for inlined-frame-window cells (unreachable without doc 24) and
  depth 0 (lexically impossible). `computeSeedPlan`: new kind always
  active. Single-slab assumption noted (coroutines excluded by design).
- **Files**: trace_code.zig (InputKind + seed docs), trace_recorder.zig
  (refOfAbs factor, recInputGet arm, recUpvalSlotAlias), interp.zig
  (upvalueSlotAliasOk + arms in seedTraceInputs/nativeSeedFn; tier-1a via
  delegate), nativegen_alloc.zig (computeSeedPlan), interp_trace_test.zig
  (3 tests), docs 53/51, TODO.md (jit-debug flake occurrence 5, seed
  0xe84b76c2, name lost to tail pipe AGAIN — use `> log 2>&1` first).
- **Tests bite-verified** by three targeted sabotages: neutered validation
  → alien-activation test fails (25120≠17120); snapshot-semantics read →
  per-iteration-store test diverges; restored abort → shape test fails.
  Gates: `just test` + `-Djit-debug=true` (one flake occurrence, 3 clean
  re-runs) + boundaries + fmt green.
- **Measured.** nbody `--jit-stats` 500k: tier-0 45.2% → 0.3% of cycles,
  traced 44.9% → 99.2% (native 99.1%), seam 20.5% → ~0% (499,995 → 51
  walks), wall 603 → 199 ms; main:211 traces 100.0% of iterations; aborts
  4 sites → 1 (by-design LINNER root). Board: **nbody 54.5 → 19.8 ms,
  13.9×→11.6× (P5) → 4.5× LJ, res 92.9%**; cross=ok/luajit=ok everywhere.
  Movers vetted ×3 interleaved vs behavior-verified `just shadow` baseline
  (`/tmp/lune-base-doc53`, shows the old abort): tbl_ops/repack noise,
  str_format drift (res 0%); **fft +3.5% is a code-layout artifact**: ALL
  JIT counters bit-identical (1,016,150 entries, 1,012,995 fused, same
  splits, same aborts) and the sign FLIPS under --jit-stats (NEW 456.6 vs
  OLD 467.2 ms). Doc 51's unroll-vs-decomposition isolation sweep not
  needed: the driver trace absorbed the nest outright (advance:34 → 352
  warmup iterations).
- **Deferred (doc 53 Outstanding)**: set_upval write side (open-cell
  stores still abort .nyi, safe), inlined-frame-window cells (doc 24).
- **Codex reviews DONE (2026-09-18, after the 0.153.4 pin restored the
  MCP tool)** — doc 53 round-1 APPROVED (thread `01a0b3fe…`): no
  soundness break; nit incorporated (runtime_safety assert pinning
  `existing.slot == rel` on the seed-dedup-hit path in
  `recUpvalSlotAlias`); open question tracked as a doc 53 Outstanding
  bullet (targeted linked-entry native-handoff test for the seeded
  trace). Doc 49 P5 round-3 APPROVED (thread `01a0b400…`): code clean;
  one doc-wording fix (prove pass doesn't gate on `hrefk_aux` — the
  hrefk-vs-callout choice happens at allocation/emission via
  `effectiveHrefAux`). Both ledgers updated. Gates: `just test` green;
  jit-debug gate flaked once more (occurrence 6, TODO.md — name lost
  to a tail pipe AGAIN, 3 log-captured re-runs clean).
- **nbody next rocks** (from the new profile): res 92.9%, remaining gap
  4.5× is now native codegen quality of the big unrolled driver trace +
  the 0.6% non-loop tail — profile before choosing.

## Status 2026-09-18 (latest+19) — doc 51 Fix B: konst value canonicalization LANDED

Bart picked Fix B as the most general lever. What landed (task #35, all in
`src/tropt.zig` + one move):

- **The change.** Konst instrs and fold results now canonicalize by
  `(value, ty)` to one SSA ref (`KonstCanonKey` + `resolveFold`); fold
  results intern against the pool via a value-keyed `pool_map` seeded from
  the input consts (reuse an equal-valued entry, else append — existing pool
  entries are NEVER renumbered/pruned: `sgmatch.aux`/`guard_sid.aux`/
  `InputSeed.source` are pool indices riding verbatim through compaction).
  Downstream CSE keys hash canonical operand refs, so equal-konst-fed
  expressions now merge; the duplicate konst instr goes non-canonical → dead.
- **Deviation from the codex review, recorded in doc 51:** heap constants
  key by object identity (`konstKey` pointer), NOT `GcHeader.id` — same id-0
  raw-test-object hazard Fix A documented; a test pins two id-0 headers
  apart. Deterministic: consts are GC roots for the trace's lifetime, the
  pointer never enters the emitted trace.
- **Boundary move.** `KonstKey`/`konstKey` moved `trace_recorder.zig` →
  `trace_ir.zig` (re-exported from the recorder): the `just test` JIT
  boundary check correctly rejects `tropt → trace_recorder` (found the hard
  way — first gate run failed on it).
- **Tests.** Four new `tropt doc 51 F3:` unit tests (equal konsts
  canonicalize + unlock CSE; fold reuses an equal pool entry AND an equal
  konst ref; two same-value folds share one konst + one pool entry; distinct
  id-0 heap konsts never merge). Bite-verified: neutering both
  canonicalization points fails the first three; the heap test is a
  deliberate negative (guards against WRONG keying, passes either way).
- **Measurements.** Instrument (`nest_probe`): driver trace pool 37 → 11
  entries (all unique), body 486 → 441 instrs (−9.3%); outputs byte-identical
  across tier-0/`--trace`/`--jit-native`; 82.3% native by cycles. Board
  (`bench/results/20260918-123134-20d7b27.tsv`): all cross=ok/luajit=ok, NO
  regressions; the eight "−5–9% movers" were checked ×3 interleaved against a
  `just shadow` pre-B baseline (nm-verified: shadow lacks `resolveFold`) —
  OLD ≈ NEW on every one, i.e. board drift, and Fix B is **board-neutral**;
  its win is trace quality (size/CSE), general per Z-6.
- **jit-debug gate flake, 2nd occurrence.** `zig build test -Djit-debug=true`
  failed once (seed 0x34eef2f0), then PASSED with the SAME seed + 3 more
  random-seed runs — so not seed-deterministic; parallelism/shared-state
  suspect. Now recorded in TODO.md with capture instructions for the next hit.
- **Rule #6 note (confessed):** the 6-site `recorder.konstKey` →
  `trace.konstKey` rename in tropt was applied via a Python one-liner without
  a dry-run pass first (counts printed and matched, full gate green after,
  but the letter of the rule says dry-run first).

**Outstanding from doc 51:** Fix C (short-burst silent-promotion evidence —
needs a doc-47-grade design first) and the optional statically-false-guard
commit rejection (tri-state evaluator). **Next-arc candidates:** nbody's
driver-loop `aliased_input get_upval` abort (18.5% of its run), Fix C /
replayLedger seam, task #18 doc 44 return tracing.

## Status 2026-09-17 (latest+18) — doc 51: nest diagnosis complete + Fix A (DOA alias guards) LANDED

Ran the Astra-recommended layered diagnosis (doc 50 → **doc 51,
`docs/design/51-nest-decomposition-diagnosis.md`** — full receipts there).
Instruments committed: `bench/nest_probe.lua` (reduced advance:4-shaped
variable-trip nest, faithfully reproduces nbody's jit-stats shape) and
`bench/alias_doa.lua` (flat-loop minimal repro). Headlines:

- **Layer 1/3 healthy**: inner root (`advance:19`) + continuation
  (`advance:44 → link 19`) both commit, both directions armed
  (`loop_done_linked` / `link_terminal`), 7,967 fused native transitions,
  region minted `armable=true` (doc 47 Inc-B works on this shape). PLUS the
  driver loop records a whole-call unrolled 616-instr trace via
  `recForPrepLink`'s depth>0 record-through.
- **F1 (the headline, general recorder defect, Rule #0.5)**: that driver
  trace is DEAD ON ARRIVAL — `forwardPendingHashLoad`/`forwardPendingArrayLoad`
  emit table-identity `ne`+`guard_true` alias-disambiguation WITHOUT
  consulting record-time identity. In the nest, `bodies[j]` of outer i=1 IS
  `bodies[i]` of outer i=2 (konst-pool dump proves k9=k14=2), so the guard
  was false during its own recording → completed=0 every dispatch → 18
  legacy strikes → `legacy_thrash` gate; the side trace has the same defect.
  Reproduces in a FLAT loop (`t = {a, a}`; `bench/alias_doa.lua`) — any two
  SSA paths to one table. Output stays correct; the cost is a hot loop
  pinned to tier-0 + record/side/gate churn.
- **F2 (structural gate)**: silent promotion requires a FULL 32-row
  forced-yield ledger (`considerSilentPromotion`); a nest with outer trip 5
  produces 8-row bursts ending in a natural deopt → candidates=0 forever →
  the armed cycle pays ~1,064 cyc/replayLedger walk = 15.8% of the
  instrument's run. Every short-outer nest (nbody included) is in this class.
- **F3 (optimizer, general)**: `tropt` constant folds append pool slots with
  NO value dedup and konsts have no value canonicalization (unopt pool 5
  entries → opt pool 37, ~13 unique) — equal constants defeat CSE downstream
  everywhere.
- **Fix A LANDED** (same session, after codex review of doc 51 — thread
  `01a0ac91-853c-7b03-b097-a6b7a5abba76`; two material corrections adopted:
  the array arm combines table relation × key class since table identity ≠
  cell identity, and the claimed F3→F1 CSE connection was false because
  aref/aload are never CSE'd). `PendingStore` captures record-time table
  OBJECT identity (header pointer, NOT GcHeader.id — raw test tables share
  id 0; pointer never enters the IR, decision deterministic) + observed
  astore index; observed-equal → forward + `guard_false` pin,
  observed-distinct → today's honest `ne`+`guard_true`, `.may` keys
  observed-equal → abort. Results: instrument driver loop 0 → 97.2% traced,
  seam 15.8% → 1.5%, wall ~3.3×; flat repro 99.9% traced (was 0%, gated).
  Board: no attributable movers (all >5% single-run diffs re-checked ×3
  interleaved vs a `just shadow` pre-fix baseline — identical; sparse's +7%
  vs yesterday exists pre-fix too and its traces have zero grid ops, so
  cb47d95 is excluded as well: board drift). nbody unchanged (63.1 ms,
  13.1×) — its driver loop aborts on `aliased_input get_upval` first (next
  candidate #2 in the handoff list). Tests: 4 unit (bite-verified by
  neutering) + expectProgram flat repro + expectTier0Equiv mini-nest.
- **Fix B (konst canonicalization) and Fix C (short-burst promotion
  evidence) remain outstanding in doc 51** — B is a general optimizer win,
  C needs its own doc 47-grade design.
- Dump improvement landed: `writeTrace` prints the konst pool.
- Gates: full `just test` green; `zig build test -Djit-debug=true` green
  (one unreproducible failure on its very first post-edit run — 5 seed
  re-runs all green; noting for the record).
- NB (Rule #1 confession): two bare `python3 bench/run.py` invocations
  happened during noise-checking before switching to `just bench` — the
  binary was verifiably the fresh ReleaseFast from the immediately-prior
  `just bench`, and the numbers were re-taken via `just bench` anyway.

## Status 2026-09-16 (latest+17) — doc 50 Astra-review follow-ups landed; next arc = nest-decomposition diagnosis

Codex Astra (gpt-6-astra) reviewed the doc 50 arc read-only. Verdicts and what
landed from them (this session, on top of `d35ca63`):

- **`guard_gcol` fail-open gap FIXED** (pre-existing, Rule #0.5): native
  range-checks `guard_gcol.b` while the oracle derives the column from
  `gcell.b`; the prover never tied them, and the shared `.aref` kind let
  aref/garow/gcell impersonate each other while native emitters walk exact-op
  `t.instrs[...]` chains (`guard_bounds` on a gcell even satisfied
  `bounds_ok`, so a gcell-of-gcell chain COMPILED). Prover now enforces
  `guard_gcol.b == gcell.b` + exact op identity along the whole grid chain.
  Three previously-compiling malformed variants pinned in
  nativegen_arrayread_test.zig ("Astra/doc50" tests) — bite verified by
  temporary neutering (they compiled pre-fix), positive control compiles.
- **Heap identity eq coverage extended**: `eq` op (only `ne` was covered),
  mixed invariant-`.ptr`/value-lane-`.heap` operands, top-bit ids
  (sign-extension trap), equal-twin + differing cases. Leftovers in TODO.md:
  spill-pressure variant, real capture/restore differential.
- **Doc 50 amended per review**: rejection scoped to whole-inner-loop cloning
  of variable-trip nests (bounded unrolling of genuinely short loops stays
  legitimate); "no production multi-loop trace" softened to a working
  assumption; "External review" section records verdicts + follow-ups.
- **Next arc (Astra-recommended, recorded in doc 50 "Outstanding
  direction")**: NOT a new mechanism — diagnose why the EXISTING
  `inner root → outer continuation → inner root` decomposition fails to
  cover outer work on a reduced advance:4-shaped variable-trip nest, layer
  by layer (the Z-8 ladder generalized): 1 topology/aborts, 2 entry-guard
  mismatches, 3 exit arming, 4 silent-region promotion / SCC owner
  election, 5 residency + seam cost. End state: inner trace REUSED, outer
  state through continuation φ/writeback, code size independent of inner
  trip count.

## Status 2026-09-16 (latest+16) — task #33 (doc 50): nested `for_prep` investigation — unrolling rejected

**NO FEATURE LANDING.** Doc 50 (`docs/design/50-nested-for-prep-investigation.md`)
records the experiment and measurements. Starting HEAD for this run was
`33d4ced`; do not push without Bart's say-so.

- Profile + `--jit-stats` confirmed the documented nbody gap: `advance:4`
  contributes about 13.5–13.9% of the run with zero traced iterations;
  `advance:34` remains about 87.5% trace-resident. The outer abort is
  `nyi_opcode for_prep`.
- A general bounded numeric-inner-loop recorder prototype (15-trip cap) built
  an approximately 500-IR native outer trace. Variable/shrinking trip counts
  made it match only about one third of nbody outer iterations at ~2,417
  cycles/iteration versus ~485 in tier 0, regressing wall time to ~108 ms.
  Mismatch retirement merely restored the old shape with no durable new
  coverage. A fixed-four-trip control was already covered by the existing
  inner-root/link machinery. Per Z-6, the prototype was removed in full.
- Two independent correctness bugs exposed by the experiment remain fixed:
  `guard_gcol.b` is now marked/remapped through tropt's two-operand effect
  class; and native heap `eq`/`ne` now admits both invariant `.ptr` and
  value-lane `.heap` operands while comparing stable `GcHeader.id`, never
  process address. Differential tests cover distinct IDs, the same object,
  and restored twins with equal IDs at different addresses.
- An owner-aware numeric loop-done classifier was prototyped but removed: its
  only demonstrated need was the rejected multi-loop root, while landing it
  would require a deliberate revision of the replay fixture contract. Doc 50
  records this requirement for any future multi-loop-root design.
- Gates: focused regressions green; full `just test` green; full
  `zig build test -Djit-debug=true` green. Post-removal nbody 50,000 is correct,
  71.8 ms in the sampled stats run, with `advance:4` back to zero trace
  iterations and 50.8% traced time. Full five-repetition `just bench` is
  cross-tier clean and LuaJIT-parity clean on every compatible row; nbody is
  62.4 ms versus 61.7 ms on the post-doc-49 board (noise-scale).
- Next choice returns to the candidate list above. Bounded whole-inner-loop
  cloning is ruled out; a future nested-loop design must preserve the reusable
  inner trace and represent the enclosing state transition instead.

## Status 2026-09-16 (latest+15) — task #32 (doc 49): owned hash part + hrefk — nbody 23.3× → 13.4× LJ

**COMPLETE — committed as `76198e5` on master (not pushed).** Doc 49
(`docs/design/49-owned-hash-part-hrefk.md`, codex-approved rounds 1–3, thread
`01a0a86c-f747-7db3-95c5-d4b1e3b7c664`) holds the full design + measurements.
Bart chose "Own hash part (B)" over the std-map layout-discovery hack. Summary:

- **P1 `src/hash_part.zig`**: mahina-owned extern-layout open-addressing map
  (interleaved 32 B `Node{key,value}`, `{nodes, mask, live, used}` header).
  Lua-style deletion: free ⇔ nil KEY tag; dead ⇔ live key + nil VALUE, dead
  heap-key payload rewritten to `GcHeader.id` bits (pointer-free dead nodes).
  `keyHash` = splitmix64 over (tag, id-or-bits). 8 inline tests.
- **P1b battery**: owned map BEATS std map at tier-0 (nbody −4.7%, array3d
  −5.8%, churn −6.3%, field-hash −6.8%; miss micro +2.2% = predicted
  no-fingerprint cost). binary-trees "+13.9%" disproven as noise ×3.
- **P2 swap**: `table.Map = hash_part.HashPart`, call sites migrated,
  `hash_size` → `live`. Table 112→120 B, same 128 B SmpAllocator class.
- **P2b restore contract**: geometry (slot/mask/dead nodes/used) deliberately
  NOT serialized; divergence across restore PERMISSIBLE (doc 02 Done-bullet
  added). Pinned by `doc 49 P2b` test in keyframeser_restore_test.zig:
  used>live history restores dead-node-free, `encodeSnapshot ∘ restore ==
  identity`, second restore layout-identical slot-for-slot.
- **P3 hrefk**: recorder pins live `(slot, mask)` via `Table.hashSlotOf` into
  `href.aux` (`trace_ir.HrefAux`, 3-domain contract: aux≥0 seed slab / −1
  callout / ≤−2 hrefk); `emitHrefK` (~7 instr, 4 loads, NO callout/save
  frame) with CONTRACTUAL guard order mask → live-cell → key tag → key id
  (ids, never payload bits — restore moves strings). Prover admits hrefk only
  at `.heap` roots; static-root-with-hrefk-aux fails closed.
  Tests `src/nativegen_hrefk_test.zig` (7): same-shape distinct-table read
  vs oracle; guard_table agreement; two-universe RMW store; swapped-slot
  sibling (native exits at pinned iteration K with hand-computed regs, oracle
  completes N — the documented conservative divergence); delete+unrelated-
  insert dead-node STORE TRAP (live-cell guard exits before key deref —
  neutering it segfaults on the id-bits deref, proving the guard order);
  rehash + empty-map mask exits; static-root bail. All guards
  neuter-verified to bite. GOTCHA for future tests: raw-created heap objects
  default `GcHeader.id = 0` and heap `Value.eql`/`keyHash` go BY ID — a test
  with >1 heap key must assign distinct ids itself (see `assignIdWithSlot`).
- **P4 board** (TSV 20260916-141459-858834f, cross+luajit ok everywhere):
  **nbody 106.4 → 61.7 ms, 23.3× → 13.4×**; repack −14.1%, btrees −7.4%,
  grid_matmul_f64 −7.4%, nsieve −6.5%; tier-0 broadly down. str_gsub/
  str_manip/array3d apparent jit regressions disproven ×3 interleaved.
  Full `just test` green on the final tree.
- **Next rocks (out of scope, recorded in doc 49)**: nbody remaining gap is
  tier-0 COVERAGE, not the traced loop — `--jit-stats` 50000: advance:4
  nested for_prep (13.6% run, `nyi_opcode for_prep`), main:211
  `aliased_input get_upval` (18.5%), tier-0 no-trace 32.3% of cycles;
  liveSlotOf 31.9% of profile is those tier-0 probes. Seam:
  replayLedgerFrom 7.5%, ~1028 cyc/walk. Defers: guard_hash subsumption on
  hrefk chains, on-trace insertion (asm_newref analogue), scalar-key hrefk.

## Status 2026-09-18 (latest+16) — task #36 (doc 51 Fix C → doc 52): P0 recurrence evidence LANDED

**P0 committed; P1 (resident promotion, mixed support) + P2 (measurement) outstanding.**
Doc: `docs/design/52-recurrence-resident-promotion.md` (codex rounds 1–3, thread
`01a0b2b9-914e-7020-82f6-0633070a6376`; all blockers folded). Bart's decisions:
mixed support (one activation set + one resident set live simultaneously) in
scope for P1 — NOT the coarse exclusivity I proposed; `recurrence_promote_after`
default 4.

- **Problem (nbody)**: 499,995 dispatcher bursts, 99.5% identical 8-row
  natural-terminal ledgers; each drain replays the ledger ~11.9k cyc = 20.5% of
  wall, on a cycle that already runs native→native via armed links. Four gates
  block silent promotion for short bursts: evidence needs LEDGER_CAP+.yielded;
  fallback-elected region mints dormant; min_useful=8 vs work=6; activation-
  scoped sets demoted at closeRegion. Doc 52 = recurrence evidence (K=4
  consecutive identical qualifying ledgers) + region-lifetime RESIDENT sets.
- **P0 (this increment, behavior-neutral)**: `RegionDef` recurrence fields
  (parallel u32 sig arrays cap 32, streak, probe-charge budget cap 64);
  qualifying grammar (len∈[2,CAP), terminal strictly deopt/normal/normal, NOT
  an armed candidate edge, non-final rows pass `detectPromotableSetMembers`
  (new core, member_rows=len−1, child-match over FULL ledger; 2-arg delegate
  unchanged)); cheap signature-first steady state; deterministic min-RegionId
  owner resolution charging every probed def win-or-lose; streak resets on
  every non-qualifying observed ledger (incl. full-cap branch) AND
  qualifying-but-unowned; threshold path logs "held" — nothing promotes.
  Config: `recurrence_promote_after=4`, `recurrence_probe_cap=64`.
- **Files**: src/trace_region.zig (fields + RECURRENCE_SIG_CAP), src/trace.zig
  (config + re-exports), src/trace_link.zig (grammar core + tryRecurrence-
  Promotion + resets), src/trace_promotion_test.zig (2 tests: full lifecycle
  incl. grammar-3 armed-terminal reject, child-mismatch, full-cap reset,
  non-qualifying reset + charge-free cheap re-match; min-RegionId determinism
  with reset-loser). Gates: `just test` green, jit-debug battery green.
- **Flake note**: jit-debug gate flaked once during the P0 gate (occurrence
  #3, seed 0x4fa150f3); exact binary + same seed rerun passes 1402/1402 —
  proven NOT seed-deterministic. TODO.md updated; capture full output FIRST
  next time.
- **Next**: doc 52 P1 — resident sentinel key (activation=maxInt) + isResident,
  mixed-support drain (per-fired-set transitions_credit split, entry-set global
  credit at trace_chain.zig:1135 removed, barren settlement re-target),
  barren_exempt epilogue flag, PROVENANCE_VERDICT_CAP 48→64, count caches,
  demotion notice → streak zero, election-tier reset, full test battery; then
  P2 measurement (nbody before/after, adversarial benches, sensitive boards).

## Status 2026-09-18 (latest+17) — task #36 (doc 52): P1 resident promotion + mixed support LANDED

P0+P1 now on master; P2 (measurement) is the remaining doc 52 phase.

- **P1 delivers**: at the recurrence threshold (K=4 identical qualifying
  short natural-terminal ledgers) an eligible dormant fallback region now
  promotes a RESIDENT silent set — sentinel key {rid, activation=maxInt},
  region stays dormant, no accumulator — that coexists and co-fires with ≤1
  activation-scoped set (Bart's mixed-support decision).
- **Mechanisms**: `SilentExitMetadata.barren_exempt` + per-arm epilogue
  branch (resident firings neither advance nor reset cur_zero_run; verified
  END TO END — a real promoted native a→b→a cycle left cur_zero_run at 0
  across 6 link-terminal firings, and the intentional-break check proved the
  assertion bites); registry count caches (activation_set_count/
  resident_set_count) moved strictly at physical publication/removal with
  debug list-agreement assertions (queued demotions leave patched reality —
  and counts — untouched until drainBarrier); checkPromotable invariants
  (one resident set globally → PromotionResidentOccupied; per-RegionId
  dual-key backstop → PromotionRegionIdOwned) + new reject counters;
  PROVENANCE_VERDICT_CAP → 2×PROMOTED_SET_CAP+LEDGER_CAP (64);
  prepareNativeEntry/silentStaging count-gated fast paths (resident sets
  survive the activation sweep; staging skips the activeRegionFor walk when
  no activation set is live, budgets still staged); driveSilentBurst
  per-keying drain (activation required iff an activation set fired; barren
  settlement re-targets to the fired activation set, fail-closed on barren
  exhaustion with none; per-fired-set transitions_credit split for BOTH
  keyings, entry-set global credit removed); resident-demotion notice
  (single ?RegionId slot) drained in syncNativeInvalidation → streak+sig
  zeroed; election-tier flip + invalidateRegion recurrence clears;
  threshold path in tryRecurrencePromotion now charges win-or-lose, resets
  streak on probe/authorization failure, resets the probe budget only on
  success.
- **Tests**: 4 new "doc 52 P1" tests (threshold promotion incl. exempt
  metadata + occupied hold + notice; mixed invariants + dual-key backstop +
  synthetic mixed drain credit split/barren purity; REAL native
  resident-only cycle with no activation open; demotion funnels —
  activation-close skip, deferred count timing, defs mutation). P0 test
  re-pinned to evidence-only via promote_after=100 (threshold behavior has
  its own tests now). Gates: `just test` green, jit-debug battery green
  (×2), ReleaseFast builds.
- **Flake occurrence #4** (doc 52 P1 gate): NEW SHAPE — stray `failed
  command` (seed 0x8fdb0d0b) on stderr with overall exit 0, full stderr
  captured this time; clean rerun green. TODO.md updated.
- **Next**: doc 52 P2 — nbody --jit-stats/perf before-after, adversarial
  benches (never-qualifying probe cost, unrelated-phase entry tax vs
  ≤-noise budget, alternating A/B cap saturation), sensitive boards
  (scimark-sparse, grid_matmul, scimark-lu), full board, tick doc 51 Fix C.

## Status 2026-09-18 (latest+18) — task #36 (doc 52) CLOSED: P2 measurement — memset regression found+fixed, verdict ~break-even

- **The P1 board regressions (+7% nbody, +26% scimark-fft) were NOT the
  resident mechanism.** fft promotes nothing (silent counters all zero on
  both binaries) and regressed anyway — that was the tell. `perf` showed
  `compiler_rt.memset` at 19.9% of the fft run, called from
  `driveDispatcherLedger`: the P1 `PROVENANCE_VERDICT_CAP` bump (48→64)
  pushed `@sizeOf(NativeCallProvenance)` to 1032 bytes (0x408 — exactly
  the memset size in the disassembly), which flipped the aggregate
  `= .{}` init past the compiler's undef-elision threshold. Every one of
  the 8 `var provenance: NativeCallProvenance = .{};` sites began
  zeroing the whole 1 KiB struct; the hottest is once per dispatcher
  walk (~1M/run fft, ~500k nbody). Base binary at CAP=48 (776 B): no
  memset, just `len=0`.
- **Fix (985110b)**: `var p: NativeCallProvenance = undefined; p.len = 0;`
  at all 12 sites (8 hot + 4 test), via a Rule-#6 dry-run script;
  struct field defaults REMOVED so `= .{}` is now a compile error, with
  a comment naming the failure mode (same family as the by-value-return
  memcpy already documented on captureNativeCallProvenance). Verified by
  disassembly: zero 0x408 memsets remain in the binary. Gate green
  (`just test` + boundaries check), zig fmt clean.
- **Post-fix interleaved A/B (vs P0 df246a0 shadow, nm-verified)**:
  fft 0.33–0.35 s vs base 0.34–0.36 (restored, even slightly better);
  nbody residual +1–2% (median 0.63 vs 0.62). `--jit-stats` nbody split:
  seam 1081→1050 cyc/walk (resident set saves −30: drain rollup + 1-row
  suffix vs the 8-row frozen walk), native +24 cyc/walk (silent-epilogue
  exact accounting replacing the cheap row write). **Verdict:
  ~break-even** — my earlier "epilogue is ~57 cyc/firing fatter" claim
  was mostly the memset in disguise.
- **Full board (20260918-150154-985110b.tsv)**: everything in band —
  fft 329.2 (band 322–340), nbody 62.8 (prior 62.1–62.4), lu 141.6,
  sor 81.0, sparse 153.8, grid_matmul 25.1/25.0, pi_leibniz 36.8,
  field_hash 13.0 (no probe tax on never-qualifying benches).
- **Docs**: doc 52 status → complete, P2 bullet moved to Done as a
  negative-result-on-payoff entry, payoff model gets a dated P2
  correction (the pre-arc "~11.9k cyc/walk = 20.5% of run" figure was
  wrong — the dormant region's walk was already frozen-cheap ~1.1k);
  new deferred bullet: lean resident epilogue (shed part of the
  measurement contract for barren-exempt edges — design question first).
  Doc 51 Fix C ticked with the same verdict.
- **Commits (local, NOT pushed)**: a247e84, df246a0 (P0), 5d9b5cf (P1),
  985110b (memset fix), + this docs commit.
- **Open question for Bart**: is the +1–2% nbody residual worth a
  lean-epilogue design round, or do we accept break-even (the mechanism
  is correct, tested, and self-contained) and move to the next campaign
  gap?

## Status 2026-09-18 (latest+19) — doc 49 P5: hrefk fallback for seeded carried-heap hrefs — nbody 62.8 → 54.0 ms

- **Bart: "since we are already here, might as well try to make it a bit
  better?"** Profiled nbody post-985110b: the big cost adjacent to the
  arc was NOT the resident-epilogue residual (+1–2%) but 16.7% of the
  run in JIT→`resolveHashCell` full-hash callouts. Asked Bart which
  lever; he picked the seed-hint fast path over the lean epilogue.
- **Corrected diagnosis**: doc 52's deferred "per-entry seed
  re-resolution" was actually PER-ITERATION callouts: a `hash_cell`-
  seeded href whose root turns out carried-heap at emission (nbody
  advance:132's `bi` — φ `%122` rewrites r7 each iteration) has its
  seed deactivated by `computeSeedPlan` and lowers to the
  `resolveHashCell` callout, and the hrefk `(slot, mask)` was never
  recorded because `hrefAuxFor` returns the seed slot first. 6 seeded
  hrefs ×2 trace copies = the 6 JIT call sites in the perf chain.
- **Doc 49 P5 (designed in doc 49, landed this commit)**:
  `InputSeed.hrefk_aux` (encoded HrefAux, default −1) stamped by
  `seedHashCell` via the new shared `hrefkAuxOf` helper;
  emission-side `effectiveHrefAux` (nativegen_alloc) substitutes the
  hint for a deactivated seed, routed through BOTH `bodyCalloutOf`
  (save-frame decision) and the href emit dispatch (mismatch would be
  a missing/dead save frame — one helper, one decision); `emitHrefK`
  reused verbatim on an aux-substituted instr copy. `computeSeedPlan`,
  prover, tier-1a, and all seeding twins untouched (hint is pure
  compile-time data).
- **Tests**: (1) correct hint → seed stays inactive + full expectMatch
  agreement battery on the carried-read shape; (2) wrong-slot hint →
  oracle completes N, native exits at iteration 0 — proof the hint
  reaches lowering (a callout would have completed). Toggle script
  (/tmp/toggle_p5_test.py, Rule #6) flipped the stamp to −1: test
  failed "expected 0, found 8" = callout path restored by default −1,
  test can fail. Full `just test` + boundaries green; fmt clean.
- **Measured**: `resolveHashCell` GONE from nbody profile; `liveSlotOf`
  30.7% → 15.2% (rest = tier-0 untraced outer loops advance:4 /
  main:211 — known, separate arc). **nbody 62.8 → 54.0–54.5 ms
  (13.9× → 11.6× LJ)**; binary-trees 386.3 → 373.3; sparse 153.8 →
  149.0; board otherwise in band (array3d 12.7 re-ran at 12.1 =
  noise); all cross-tier ok. Boards: 20260918-1542xx-5dcdacc.tsv.
- **Z-6 check**: fully general — any loop re-picking a record-shaped
  receiver from a container (`bi = bodies[i]`) records this shape.
- **Process note**: campaign loop calls for a codex review; no codex
  MCP tool in this session (Rule #21 — did not substitute another
  provider). Review pending on request.
- **Deferred/remaining**: lean resident epilogue (doc 52, +1–2% nbody);
  doc 49 defers unchanged (guard_hash subsumption, on-trace insertion,
  scalar-key hrefk); nbody's next rocks are outer-loop coverage
  (for_prep / aliased_input get_upval, ~30% tier-0).
