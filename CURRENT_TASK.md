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

## Status 2026-09-07d — doc 43 P0 (all four) LANDED + gated; arc P1–P5 not started

The array3d-coverage arc (doc 43) began with a correctness pass. An adversarial
alias sweep (20 shapes, `/tmp/doc43_sweep/`) + two reviews found **four** entry-
snapshot / store-sinking miscompiles; all now fixed FAIL-CLOSED (abort the unsafe
recording; correctness > coverage). NONE committed yet — awaiting Bart.

- **P0a — callee-upvalue open aliasing.** `recInputGet` aborts `.aliased_input`
  when an inlined callee's upvalue is open over a slot at/above the anchor window
  base. Plumbed `anchor_abs_base`/`upval_open` through trace.zig + interp.zig.
- **P0b — global-seed staleness.** An `hstore`/`astore`/`rawset` into the globals
  table after a `.global` seed aborts (`globalsStoreBars`); `rec_globals_header`
  refreshed at Vm.init AND keyframe restore.
- **P0d — length-dependent append double-apply.** `t[#t+1]=v` aborts via
  `traceHasAlenOf(rtab)` in `arraySetShape`'s append branch. nsieve's loop-var
  append still records `astore_append` (unaffected). Correct push-idiom tracing
  is a perf follow-up.
- **P0c — composite bridge vs sunk stores (LATENT, now pinned).** Verified in
  codegen: an ARMED composite bridge flushes only slot φs then `jmpMem`s to the
  successor — NO tier-0 replay — so a sunk `astore`/`hstore`/`gstore`/`sgm_setpos`
  would be LOST. Empirically arms 0 bridges today (store-bearing traces and
  branch-candidate traces are disjoint), so latent not live. Made explicit:
  `classifyBridgeCandidate` (trace_code.zig) refuses candidacy when any store op
  sits below the branch guard. Coverage-neutral (sieve still `bridge=2`).

Permanent corpus: the 20 sweep shapes are now `expectProgram` tests in
`src/trace_p0_alias_test.zig` (full ten-leg tier matrix, stronger than the shell
sweep and stronger than the bench-corpus hashgate — which is why they went here,
not into `bench/`). P0c pinned by §T.9b in `trace_fingerprint_test.zig`.

Gates all green: `just test`, `just hashgate` 84/84 both legs, `zig build wasm`.
Bench abort sweep: only binary-trees hits `aliased_input` (P0a guard firing
correctly; binary-trees is 0%-traced by nature — recursion, not loops — so no
coverage lost; hashgate proves its output byte-identical). array3d coverage
unchanged (50%, 2.1% native — the P1–P3 target).

Doc 43 checklist: P0a/P0b/P0c/P0d all `[x]`. Outstanding = P1 (bool hash fields),
P2 (fn hash fields + method inlining), P3 (table hash fields), P4 (assert), P5
(closed-cell upvalue stores). NOT authorized to implement beyond P0 yet.

## Status 2026-09-07c — doc 42 arc LANDED: tail-call dispatch conversion complete

The conversion commit is in (one commit: interp.zig conversion + T-6 test +
two inline-fn fixes in trace_link/trace_entry_registry). Read
**docs/design/42 §9** for the as-landed amendments + full measured receipts;
short form:

- Uniform six-arg musttail signature (`st, pc, instr: *const Instr, vm,
  tags, payloads` — exact SysV int-register fit). The §4.6 widening was
  REQUIRED: baseline signature was +4.3% t0 from load-port saturation.
- Hot prologue is CALL-FREE via handler-shaped trampolines (gc, region
  probe) — callable sites force per-hop callee-saved spills otherwise.
  `@branchHint(.cold)` is the anti-inline device (noinline breaks the
  musttail type match).
- Straight-line handlers fetch via `instr + 1` (`instrNext`), putting the
  opcode-load address in hand at handler entry.
- Final battery: t0 beats pre-conversion HEAD on 5/7 (pi -10.8%,
  fft -8.9%, euler14 -5.9%, grid -4.6%, array3d -4.2%; fib/lua54 ≈ +2%);
  jit within noise except fft +6.9% (trace-chain seam per profile, R3).
  icache lottery structurally dead (9.1K misses). Binary +2.2%; cold
  ReleaseFast build FASTER (40.8s vs 46.3s). All gates green (just test,
  hashgate 84/84 both legs, wasm).
- OPEN for Bart: `omit_frame_pointer` module flag = further ~1.5–3.5% t0
  (doc 42 §9.4). NOT landed (degrades fp-based perf -g call graphs).
- **Methodology warning, sharper than before:** a `just bench` board run
  launched right after two back-to-back 40s all-core cold builds produced
  PHANTOM +30%/+54% rows (recursive-fib, scimark-fft) — the machine was
  still thermally throttled, proven by LuaJIT's OWN column inflating 50%
  in the same run (24.4 vs 16.2 lj_ms on fft) and by hand-interleaved
  re-timing of the identical binary/command showing parity-or-better.
  The earlier "+4.5% phantom medians" note understated it. NEVER cite a
  sequential board taken near heavy builds; interleaved A/B or an idle-
  machine re-run only. (The garbage TSVs were deleted.)

## Status 2026-09-07b — doc 42 arc (design/prep phase, superseded by 07c above)

Bart authorized the structural fix for the interpreter i-cache fragility
("absolutely number 1"). State of the arc:

- **docs/design/42-tier0-tail-call-dispatch.md** (commit 233d0c0) — the full
  design, codex-reviewed (gpt-5.6-sol, sound-with-changes, all folded in).
  READ IT FIRST; it contains the verified toolchain facts (musttail rejects
  error-union/sret returns; bare-word + fn-table tails compile to per-handler
  `jmp *table`; wasm tail_call feature already on in build.zig), the
  normative 11-step prologue order (the determinism contract), the
  reloadTopFrame/dispatchCurrentAt split, and the five mechanical
  translation rules for arm bodies.
- **Prep commit c38ffb9** — interp_dispatch_test.zig (T-1..T-5 behavior pins
  at safepoint granularity: call/ret suspend boundaries, fast/full handoff
  safepoint-count equality, error-mid-recording cleanup, reentrant
  callValue) + the OpCode density comptime assert in bytecode.zig. All green.
- **NEXT: the conversion, ONE commit** (doc 42 §6.2): ExecState +
  HandlerResult + per-op handler fns (56 ops × fast/full comptime tables) +
  musttail dispatch tail + noinline back-edge epilogue; the labeled-switch
  loop deleted. Then §6.3's measurement battery vs BOTH the 8a9ef56 shadow
  (/tmp/mahina-baseline, still on disk) and current HEAD: pi_leibniz t0,
  euler14/recursive-fib/array3d/lua54, fft, grid_matmul, full just bench
  (INTERLEAVED per-program A/B only — sequential suites showed +4.5% phantom
  medians from thermal drift, see 2026-09-07 status), L1-icache-load-misses
  perf stat, binary size, wasm smoke. Then T-6 (real-handler O(1)-stack
  chain test) + T-7 as part of the conversion commit, ABI tuning per §4.6
  only if assembly justifies it.
- Zig gotchas already hit: `@typeInfo(E).@"enum"` now has
  field_names/field_values parallel arrays (no .fields); doc comments can't
  attach to comptime blocks. The pinned toolchain's Type lives in
  std/lang.zig.

## Status 2026-09-07 — doc-41 perf regression: mechanical halves fixed, i-cache finding remains

Follow-up to the 2026-09-06 review below; Bart authorized attacking TODO
"Doc-41 follow-ups" item 1 (topologyView perf). Two mechanical fixes landed
(both verified by interleaved A/B against the /tmp/mahina-baseline shadow at
8a9ef56, all gates green: just test + boundary checker, hashgate 84/84 both
legs, zig build wasm):

- **Lazy bridge-emission queries.** The eager O(traces×exits×slots×IR)
  materialization in `topologyView` is gone: `CompositeBridgeEmissionIterator`
  moved from nativegen onto `TraceCode` as `bridgeEmissions`/`bridgeEmitsSlot`
  (a pure immutable-IR query, same file as its sibling scan
  `classifyBridgeCandidate`; trace_code already imports trace_ir so no
  boundary change), `ExitFact.emitted_slots` + `TraceRecord.emitsSlot` deleted,
  and the topology builder's three query sites call
  `parent.code.bridgeEmitsSlot(...)` lazily — the exact pre-split pattern.
  Equivalence argument: every queried slot comes from `live_in`/`required`,
  seeded from member `entry_slots` ⊆ the union the eager set was computed
  over, and the direct-IR answer is the pre-split truth. topologyView lost its
  `with_slots` flag, slots hashmap, and per-exit scratch lists.
  grid_matmul +14% → +5.4%.
- **`RegionPolicy.receiptsInert()` early-out** in the coordinator's
  `accountRegionProfit`: with `region_profit`/`source_exit_regions`/
  `dest_entry_regions` all empty the pipeline is provably a no-op end to end
  (no candidates, no activation, no dest entries — nothing to close, credit,
  open, or invalidate), yet scimark-fft ran it ~1M times/run at ~95 cyc (its
  single region is armable=false → the armable-only physical indices stay
  empty forever). Three O(1) size loads now gate it; pure function of
  deterministic policy state. fft +8.8% → +3.7%, grid_matmul +5.4% → +3.7%;
  fft's region/link profile tier is now CHEAPER than pre-split (5.7 vs 7.9ms).

**Remaining regression is the interpreter, not the JIT bookkeeping** — see
TODO item 1b for the full evidence chain: pi_leibniz tier-0 +12.7%
(interleaved, interp.zig untouched by the split), L1-icache-load-misses
19.7M vs 14K (±0.4%), IPC 4.57→4.13. LLVM block placement of the 48KB
`execImpl` flipped bad when the split reshaped the trace helpers inlined at
dispatch points. Structural fix = threaded/computed-goto tier-0 dispatch
(nsieve-verdict lever #3); awaiting Bart's direction.

Methodology note that bit us AGAIN today: sequential suite runs (even
same-machine, minutes apart) showed phantom +4.5% median on tier-0 columns
whose code was untouched — thermal/frequency drift. Only interleaved
per-program A/B (alternating binaries rep by rep) produced citable deltas.
The bench TSVs from tonight: bench/results/20260907-002106-1945e27.tsv (tree)
vs /tmp/mahina-baseline/bench/results/20260907-002307-8a9ef56.tsv — read the
jit column with that caveat.

## Status 2026-09-06 — doc-41 split reviewed, committed, boundaries hardened

The ownership extraction was reviewed on three axes (three parallel cluster
reviews + independent gate reruns + a shadow-baseline bench A/B) and committed
as 243c434; the confirmed cheap boundary findings were fixed and committed as
ce4c6ec (replay-walk bracket API, entry_patch_dirty funnel, promotedSets const
view + clearSilentSummaries, shared checkPromotable prologue, candidate
take-before-publish in commit(), dead re-export/wrapper removal, reset() dedup).
All gates green after both commits: just test + boundary checker, zig build
wasm, 84-digest hashgate Debug+ReleaseFast.

**Open, tracked in TODO.md ("Doc-41 follow-ups")**: (1) topologyView rebuild
cost — a REAL diagnosed perf regression (grid_matmul +14%, fft +10%, suite
median +2.4%; decisions byte-identical, cost is eager O(traces×exits×slots)
fact materialization per rebuild) — fix before the next benchmark-sensitive
arc; (2) the 176-forward TraceState facade (doc 41's outstanding coordinator
phase); (3) RegionPolicy pub-field reach-ins; (4) finalize's `rec: anytype`.
The four foreign-agent files (gc.zig, wasm_entry.zig, viz/*) remain
uncommitted — not ours (Rule #14).

## Status 2026-09-05 — architectural ownership arc STARTED (doc 41)

Bart approved starting with JIT ownership and eventually covering the full
repository architecture review. Plan: shared trace/execution contracts → sole
registry/link mutation owner → region policy → recording lifecycle. See
`docs/design/41-jit-ownership.md`; follow-up runtime/replay/compiler/UI work is
explicitly tracked in TODO.md.

Latest increment: `trace_entry_registry.EntryRegistry` now owns entry images,
stable patch slots and their physical publication/restore/teardown, with no
coordinator reference. Qualification and deterministic unpatch-before-install
drain remain coordinator policy. All source field consumers migrated. Two owner
tests cover publication/dead-record retirement/reuse and OOM refusal. `just test`,
wasm and both 84-digest hashgate legs pass; `just test` rerun after focused tests.
Next increment also implemented: `NativePhysicalRegistry` owns native links,
live promotions, candidate storage and deferred demotion/disarm/replay depth,
with explicit arena borrowing and no coordinator/policy callbacks. Physical
teardown disarms before record destruction. Review found no demonstrated
production regression; same-generation region-proof changes now invalidate
bridge replay memos (regression test added). Final `just test` (13 boundary
tests), wasm and both 84-digest hashgate legs pass. This preserves existing
last-row replay convergence, not a blanket prohibition on all mid-walk mutation.
Registry extraction is now complete: `TraceRegistry` composes both physical
owners and owns cache/ID publication and retirement, arena and seed context.
Clear independently disarms and drops candidate references before freeing records.
Const topology reads, proof-keyed memo updates and owner candidate observation
close the policy-write gaps; targeted destructive operations enforce safe windows.
Five physical debug messages restored with synchronized runtime logging gates.
Four registry tests cover ownership/OOM, identity/order and candidate cleanup;
final `just test` passes with 14 boundary tests; wasm and both 84-digest hashgate
legs pass. Region policy and recorder lifecycle remain separate outstanding
phases. No new benchmark run or commit.

Region-policy and recording-lifecycle extractions are now implemented too:
RegionPolicy owns normalized consumption/window/lifecycle/observer decisions and
staged topology publication; the coordinator applies physical/gate effects in
order. RecordingSession owns emission/reset/abort/peel/close/finalization, receives
explicit instruction context and returns an independently owned candidate.
Publication transfers code only on success; side provenance is explicit. Reset
OOM and inactive-session boundaries are hardened and tested. Removed duplicate
verifier; old public remap/memo helpers now exercise production finalization.
Final combined tests, wasm and both 84-digest hashgate legs pass; 15 dependency
tests pass and diff check is clean. Remaining doc41 items are arc-wide review/
artifact/performance closure and the later architecture arcs, not these two
ownership extractions. No benchmark rerun or commit.

First implemented slice: pure arithmetic evaluation now lives in `ir_eval.zig`.
Optimizer production imports use `trace_ir.zig` and `ir_eval.zig`, eliminating
its dependency on interpreter/lifecycle code. The existing bounded-loop
execution differential test imports runtime modules locally. No compatibility
forwarders were retained. Baseline and post-change `just test` both passed.

Shared execution contract is now implemented in `trace_exec.zig`: results,
exit reasons, ledger vocabulary/capacity and sentinel are imported directly by
both executors and lifecycle consumers. No irinterp compatibility reexports.
Native transport remains backend-owned; focused defaults/ordinal tests and
`just test` passed. Standalone `zig test src/ir_eval.zig` also passed 40 tests,
including mixed-numeric, signed-zero and exact-integer comparison cases.

TraceCode is now embedded by value in the existing stable heap Trace record.
Compiler/executor/serializer consume code directly; native compile APIs receive
an explicit trace ID, and seed callbacks receive the stable embedded code pointer.
Record destruction releases native state before code arrays. Static bridge and
loop-done classification now belong to code. All callers/tests migrated; no
extra per-trace allocation. `just test`, `zig build wasm`, and `just hashgate`
(84 digests each Debug/ReleaseFast) passed after migration. Further verification
is in progress; phase 1 is NOT yet declared complete.

Added tools/check-jit-boundaries.py and 9 scanner tests, wired into just test.
Native differential expectMatch now uses the production arena/trampoline and
compares guest local progress and exit identity, allowing explicit native
prologue refusal and value-lane fused-load tag guard identity differences.
The stricter exit check initially exposed that documented fused identity
asymmetry (IR reports guard, native reports its load); normalization checks the
actual load/guard relation, not an unconditional mismatch allowance.

Continuation: added four TraceCode ownership/const-interface/fingerprint tests
and a TraceRecord teardown test. Mutable TraceRecord now lives in
trace_record.zig (no direct coordinator import); the obsolete duplicate was
removed. Serializer integration tests moved to traceser_test.zig, eliminating
a module-scope runtime import from the codec. Dependency checker now enforces
executor/serializer direct boundaries and optimizer/code transitive boundaries
with 10 scanner tests. Full executor transitive isolation still crosses the
known stdlib→VM capability cycle, tracked in the later runtime arc.

Started registry publication contract: trace_link.ArmRequest includes region
identity/generation. Region policy no longer arms and then edits the registry
row; fresh/changed/identical arms publish or refresh proof metadata inside the
owner. Added tests for proof refresh, row count stability and invalid kind/proof
rejection. This is a prerequisite, NOT the completed registry ownership move;
arm still takes TraceState and old non-region callers use armNativeLink.
Next: move physical links/promotion/barrier state into the registry with no
coordinator back-reference, preserving demotion/settle ordering, then policy and
recording ownership. Duplicated frameless helper removed;
its callers use the strengthened production-path expectMatch. Final just test
passed after consolidation. Existing gc/viz changes preserved; wasm serialization
caller adapted in a separate region from its preexisting compile fix.
Some delegated shell writes hit a Gothab internal path panic; parent completed
migration using working shell/edit tools. No commits made.

## Status 2026-09-05 (LATEST-106) — cleanup pass: trace.zig dead-code sweep + 5-slice file split LANDED

trace.zig 17,128 → 4,993 lines, pure code motion (Bart-approved plan:
forwarding decls now, composition later). Commits: 0c8b20b (stage 0
dead-code sweep: fusedSourceBranchLinkSlot, whileEnclosingAnchorPc +
while_static, silent_promotion_rejects, 3 always-true doc-17 flags
folded, ~20 comment-rot fixes), 249bfef (trace_ir.zig, 788, leaf),
eace1b1 (trace_link.zig, 2,371), edf4d8c (trace_regionops.zig, 2,587),
c62dfad (trace_chain.zig, 3,271), e47a45d (trace_recorder.zig, 3,712).
Mechanism: methods become free fns taking *TraceState in sibling files,
re-exported inside TraceState as forwarding decls — every self.foo(...)
/ TraceState.Foo / trace.Recorder spelling unchanged; all 46 importers
still @import("trace.zig"). ~13 annotated pub-promotions total
("// pub for trace_X.zig (file-split pass)"). Every slice verified
byte-identical modulo dedent+pub by script, gated green (1151/1151 +
hashgate 84/84) and committed separately.

Final bench A/B vs pre-cleanup shadow (/tmp/mahina-split-base, HEAD
2900692, both ReleaseFast, reps 5): 23/28 rows within ±3%. Five
outliers (binary-trees +4.2%, recursive-fib +3.1%, sieve_int −4.6%,
lua54 −3.1%, str_format −5.9% — mixed directions) all have
byte-identical perf-stat instruction+branch counts (<0.001% delta) →
binary-layout artifact, not a behaviour change. TSVs:
bench/results/20260905-102022-e47a45d.tsv vs shadow's
20260905-102224-2900692.tsv.

Still in trace.zig: TraceState fields/init/deinit/dbg, lifecycle
(onBackEdge/abort/gates/closeTrace/commit/assertWellFormed, peel
entry), sibling handoff, side-exit entry points, module types, writers,
re-export/forwarding blocks. Composition (real ownership split instead
of forwarding) is a possible future arc, per Bart's choice.

## Status 2026-09-04 (LATEST-105) — doc 39 IMPLEMENTED: the peel works end-to-end; premise gap found and documented

All doc 39 phases (0–3) + the core of Phase 4 are landed and green: full
suite (incl. five new 10-mode matrix tests in `interp_native_test.zig`
with a peel-committed+compiled inspect), hashgate 84/84, CLI probes
byte-identical across tier-0/tier-1a/native on every peel shape
(recurring re-entry, zero-completion deopt, >2^53 run-once int
exactness, F1-reverse no-peel, numeric-for-anchor no-peel). The peeled
trace records (preheader mid-stream, internal φs, slot φ `steady=%N`
associations — the disassembler now prints them), compiles native
(RV-3 relaxed via `SlotInfo.steady_phi`/`steady_kind`), enters
repeatedly, and deopts correctly at zero local completions (flush
skipped on both `deopt_exit` and silent epilogues, `rbx == entry_rbx`).
Fusion around peeled traces is refused (`armNativeLink`) and the run
wrapper adds the +1 local completion at the unfused seam, mirroring
irinterp's `completed += 2` first back-edge.

**THE FINDING (doc 39 "What implementation revealed")**: the fft
premise was wrong on the post-doc-38 tree. Warming can never start a
root recording at instance trip 1 (recording begins at the arming
BACK-EDGE arrival, trip ≥ 2), so the reset-to-int family (fft
bitreverse `k = n`) always records FLOAT-entry — the :55 root compiles
already; the remaining fft RV-3 bails (:68 + second :55) are the
deferred **F1 reverse shape** (float entry, int store). The peel's
organic trigger is **transition-trip alignment** (slot flips int→float
at exactly the warming trip) — real (converts a dead-on-commit thrash
trace into a compiled one that every later instance re-enters) but
absent from the bench suite, so the bench sweep is expected ~neutral.
The fft lever is a FOLLOW-UP DECISION for Bart: F1-reverse narrowing /
continuation-scope peel vs. other campaign arcs.

Repro scripts used (in /tmp, recreate from doc if needed): peel_align
(transition-trip scan), peel_nested (reset-to-int nest — no peel, as
now understood), peel_reenter (recurring value shape: 932/932 entries
native), peel_bigint, peel_deopt0. Baseline shadow for the A/B:
/tmp/mahina-base39 (HEAD aea79c2 sources for my files, verified
trace #0 unsupported there).

## Status 2026-09-04 (LATEST-104) — doc 39 DESIGN landed: numeric φ widening via type-stabilizing peel

The named-next-technique arc from LATEST-103, design phase complete through
three codex review rounds (thread 01a06c9e-12c8-7971-99d6-a9dfd83a36aa).
`docs/design/39-numeric-phi-widening.md` (v3) is the contract; its
implementation-status checklist is the work plan. The short version:

- **v1 (eager entry coercion — the TODO.md sketch) was REJECTED**: coercing
  the entry int to float changes observable first-iteration semantics
  (integer arith wraps vs float rounds, `math.type`, >2^53 compares). LuaJIT
  gets away with flush-anywhere because 5.1 has no observable int/float;
  we don't. The determinism asterisk demanded an adaptation, not a skip.
- **The sound architecture is a type-stabilizing PEEL**, riding the E1/E2
  machinery that already exists end-to-end: at the first anchor-return of a
  plain-while root whose carried slot is int-entry/float-body, emit the
  `preheader` marker inline and keep recording; iteration 1 becomes the
  run-once region (int semantics, exactly as tier-0 executes), iteration 2
  records against genuinely-float runtime values (guard_float natural, NO
  new IR op, demotion sites untouched); carried dataflow crosses via lazily
  created internal φs (PHI_INTERNAL a=init/b=back-edge — E2's
  strength-reduction machinery, battle-tested on both tiers).
- **Minimum-sound-v1 constraints (codex round 2/3)**: peel-generation state
  shared by both anchor-close paths (else maybeCloseAtAnchor closes before
  iteration 2 records); entry_kind captured on EVERY numeric proof route and
  surviving whole-RegSlot writes; peeled traces bypass tropt (link-trace
  precedent — tropt would drop the marker); slot↔internal-φ association via
  the slot-bound φ's unused `a` (0 = write-only class); native entry-load /
  steady-home split in analyze; register-only scope enforced over BOTH
  passes (no pending stores / gmatch cursor / allocations — the gmatch
  cursor would double-match, guard_gc would sit skipped); DEOPT flush skip
  keyed on rbx == entry_rbx (LOCAL completions, chain-safe); first
  back-edge counts TWO iterations; `Trace.peeled` is semantic and
  serialized (schema bump + codecs + traceser + viz).

Implementation NOT started. Next: doc 39 checklist Phase 0 onward.

## Status 2026-09-04 (LATEST-103) — doc 38: while-inner linking + topology arbitration LANDED

The doc 15/16 continuation/link machinery, numeric-for-only until now, extended
to `while` inner loops end-to-end — plus the recording discipline AND the
topology arbitration the first A/B rounds proved necessary.
`docs/design/38-while-inner-linking.md` is the full record; the "Topology
arbitration" section there is the distilled model. Summary:

- **Classification**: `whileLoopDonePostPc` / `isWhileLoopDoneGuardIndex` —
  anchor-tied structural classifier for a while root's loop-done `guard_true`
  (source `jmp_if_false`, branch target's predecessor a backward `jmp` to the
  trace's own anchor). `ExitMaterialization.while_done`: NO flush owed (guard
  at trace TOP; completed iterations committed at their `.loop` terminals),
  walk/resume at the post-loop pc.
- **Arming**: `maybeArmContinuation` arms while-done continuations at the
  post-loop pc; `continuationReachesEnclosingBackEdge` recognizes backward
  `.jmp` as an enclosing back-edge; `driveChain`/`driveBurstCore` chain
  `.while_done` on both tiers; `recWhileLink` closes continuations with a
  `.link` to the inner while root at the backward `jmp`.
- **LLEAVE** (`AbortReason.loop_leave`): a ROOT at a while/repeat header that
  observes its own loop's exit direction aborts unconditionally (LuaJIT
  LJ_TRERR_LLEAVE) — the fast-retry budget (`lleave_fast_retries` = 8,
  per-anchor `lleave_count`, warming-counter rewind) lands the retry on a
  cond-true pass so the BODY root always forms first. An intermediate
  "enclosure refinement" (enclosed whiles record through cond-false) leaked
  glue-shaped roots onto high-trip anchors and was reverted.
- **Topology arbitration** (the core finding): an enclosed while has three
  topologies — the glue figure-eight (two `.loop` siblings at the condition
  anchor, fused by sibling handoff; 78.5 cyc/it on a `j=i%64` nest),
  the root+`.link` decomposition (137 cyc/it there, but 4× faster on
  high-trip nsieve-bit-fp), and the outer unroll. Which wins is a pure
  function of observed trips/entry, arbitrated by three deterministic
  mechanisms: (1) `.low_trip_while` entry-yield gate — 64-entry probe of
  while-done receipts, avg < 3 trips/entry ⇒ dispatch gate, probe-based
  recovery ONLY (per-receipt un-gating oscillated via chain-driven entries),
  exempt from all clear-on-productive paths; (2) trip-conditional glue
  formation — while-done exits earn side-trace hotness only below avg 8
  trips/entry (`whileDoneHotnessEligible`), so glue forms exclusively via
  the side route (`.side` recordings skip LLEAVE by kind) on proven low-trip
  anchors; (3) unroll-first root policy — roots unroll the inner while by
  default, and flip to the LINNER decomposition after `unroll_fail_flip` = 2
  failures (recording abort or `.legacy_thrash` gate of an
  `unrolled_while`-flagged trace, per-anchor `unroll_fail`).
- **Gate fixes**: `gateNativeUnsupported` no longer dispatch-gates an anchor
  that still owns a COMPILED sibling; fused-M1 replay validation keyed on the
  exact exit slot (`hasArmedSourceBranchLinkAt`) instead of first-slot-per-pair
  (a latent bug unrolled parents with multiple armed source-branch guards hit).
- **Hot-path cost lesson** (scimark-lu +10%, fixed; full recipe in doc 38):
  the per-completion productive path runs 2M+/run — (a) map lookups as
  ARGUMENTS to comptime-disabled `dbg()` still evaluate (hoist into locals);
  (b) `clearDispatchGate` uses single-hash `getEntry`+`removeByPtr`;
  (c) exit classification computed ONCE into
  `numeric_for_done`/`while_done_exit` locals, not up to 4× per exit.

Measured (ReleaseFast, A/B vs f663984 shadow baseline, nm-verified):
- nest `j=i%64` (avg 5 trips): 0.07s = 0.07s parity (glue via side route).
- nsieve-bit-fp scale 12 (~30+ trips): **70.7s → 17.4s (4×)** — decomposition.
- bench board: nsieve-bit-fp 287.7→256.2ms, scimark-fft 387.8→307.7ms
  (yield gate: fft_bitreverse:55 dispatch entries 4M→389 — the trace tier was
  a net LOSS at ~1.5 trips/entry), scimark-lu 165.6ms parity, rest noise.
- fft 20000-rep: 12.3–13.1s base vs 12.4–13.7s — noise-level parity.
- fft_bitreverse:9 stays 0%: carried slots int/float-unstable (j/k — the
  Fable finding). NEXT NAMED TECHNIQUE: numeric φ widening (LuaJIT CONV
  int→num unification) — a while-body root recorded at trip 1-2 pins an int
  entry that floats through the body (RV-3 analyze bail); the recorder/tropt
  must unify the carried slot to float with an explicit conversion, keeping
  deopt flushes byte-identical (pre-φ flushes reference the original int ref).
- Queued behind that: doc-39 family-arbitration design (deterministic slot
  competition between glue siblings and link chains), body-start while
  anchoring, exit-branch patching (doc 16 correction).

Gates: `zig build test` green (6 "doc 38:" e2e tests in
interp_tier1a_test.zig, incl. the `.low_trip_while` yield-gate test),
hashgate 84/84, full bench sweep cross=ok all rows.

## Status 2026-08-31 (LATEST-102) — **PROJECT RENAMED: lune -> mahina.** Not a
campaign arc; a name collision. Gates green, one real bug caught by the rename.

`lune` collides with [lune-org/lune](https://github.com/lune-org/lune), an
established standalone Luau runtime (~935 stars, Rust, MPL-2.0). Same language
family, same shape of tool — unworkable. **mahina** is Hawaiian for *moon*,
continuing the Lua (Portuguese) / Luau / Lune (French) habit. Checked free on
crates.io, npm, and exact-name GitHub repos before picking. (`aeon` was
considered and rejected: five separate languages already use it.)

Mechanical sweep via `tools/rename_project.py` (dry-run by default, Rule #6):
2031 occurrences across 291 files, three case forms, longest-first. A survey of
every `\w*lune\w*` in the tree first confirmed **no English word contains "lune"
as a substring** — every hit was the project — so a blanket substring replace was
safe with no word-boundary logic. The five owned file extensions fell out for
free (`.lune`/`.lunetrace`/`.lunesnap`/`.luneeff`/`.lunecov` ->
`.mahina`/`.mahinatrace`/...), plus 7 `git mv`s on viz/ files.

**`build.zig.zon` fingerprint.** The low half is a checksum of `.name`, so the
rename invalidated it. `zig build` refuses the stale value and prints the correct
one: `0xc428eee2feabed4a` -> `0xd9a5db7eaf66e979`. Comment at the field corrected
— it previously claimed the fingerprint is "generated once and never changed",
which is false under a rename.

**The one real bug the rename exposed.** `bench/stdlib/str_find_match.lua` had the
project name inside its *corpus string* (`"key=value; name=lune; ..."`), not just
in a comment. `lune`(4) -> `mahina`(6) lengthened the corpus, which shifted the
offsets returned by the plain `find(text, "year")`, which moved `acc` — and so
moved all three frozen digests. Caught by `tools/hashgate.py`, which is exactly
what it is for.

Analysis: `acc` depends on that token **only through its byte length** (the two
other matches are anchored before it or on a separate constant string). So the
fix is a *length-preserving* neutral token — `name=moon` — which restores the
frozen digests byte-for-byte AND removes the project-name coupling permanently.
No ref regeneration. A comment at the site now records why the token is 4 bytes.

Gate battery, all green:
- `zig build test`, `zig build test -Djit-debug=true`, `just check-version`
- `just release` + `tools/hashgate.py` -> **84/84, refs file diff is the two
  header comment lines only** (verified with `git diff`)
- `str_find_match` agrees across five engines: t0 / `--trace` / `--jit-native` /
  LuaJIT / lua5.4, all `acc=47800000`
- `npx tsc --noEmit` in `viz/` clean (the 7 renamed TS/TSX files typecheck)
- 9 aligned usage-comment blocks re-padded (`luajit` was hand-aligned against the
  old 4-letter name). Comment-only; the dry run caught and spared one prose line
  a naive regex would have mangled.

**Not done, needs Bart:** the gothab remote is still `serialexp/lune`, and the
working directory is still `~/Projects/lune`. Both are outside the tree.

## Status 2026-08-30 (LATEST-101) — **DOC 32 ARC (B2, `.value`-lane scalar access) IMPLEMENTED, NOT COMMITTED — awaiting Bart's scoping call. Coverage claim MET (spectral-norm `get_index nyi_opcode` aborts GONE, iteration coverage 54.7% → 99.5%); speed claim MISSED (−4.2%, not the predicted ~5×) because the payoff is blocked by a NEW distinct bug, B2b. Benchmarking MOVED to the Gothab remote profile pool (`gt profile`) — the desktop board is unusable.**

### What landed in the tree (uncommitted)

Recorder (`trace.zig`): `arrayGetShape` admits `.value` elements that are int or
float (heap tables keep the existing array-of-structs path); `arraySetShape` admits
int/float stores. The `.value` write emits `guardNum` on the STORED value instead of
`guard_fits` — `laneFits(.value, _)` is unconditionally true, so `guard_fits` is
vacuous there and pins nothing. That was the codex review's BLOCKER; it also carries
the forwarded read, since `forwardPendingArrayLoad` returns before any load guard is
emitted. No `guard_present`: the `.value` lane has no bitmap and an in-band nil is
caught by the type guard.

Native (`nativegen.zig`): `proveKinds` accepts VALUE_LANE `aload` at `.int`/`.float`
and a new VALUE_LANE `astore` arm; `.aload` tag-checks inline (`cmpByteMemImm` +
`jccNativeExit`, no `guard_*` node — the recorder's trailing guard is statically
discharged by `proveKinds` and emits nothing); `emitAStore` writes tag byte + payload
with NO presence `bts`. Hoisted-base pass no longer sets `need_present` for VALUE_LANE
(a `.value` array's `present` pointer is null).

**Pre-existing bug fixed on the way (Rule #0.5):** the EXISTING `.value` heap `aload`
computed its element address as `mov rax, idx; shl rax,4; add rax, datareg`, but
`arrayFieldReg(..., .rax)` RETURNS `.rax` when `data` was not hoisted (`pickRegFrom`
can fail) — so under register pressure it emitted `add rax, rax` and computed garbage.
Reordered to park the index in scratch `rcx` first.

Tests: 3 recorder IR-shape tests + 3 native read + 3 native write (incl. deopt-replay
idempotence), 3 e2e in `interp_lanes_test.zig` behind a local `expectRecordedProgram`
(10-leg parity PLUS `entries > 0`, because parity alone cannot see a silent return to
aborting), and a restore round-trip in `keyframeser_restore_test.zig`. That last one
uses a deliberately HETEROGENEOUS array: `optimalLane` repacks a homogeneous `.value`
array back to a narrow lane on restore, so an all-int test would have silently stopped
testing `.value` at the boundary. Stale prose in `keyframeser.zig` ("a restored sieve
is untraceable — the recorder aborts on `.value`") corrected in the same change.

Gates: `zig build test` and `zig build test -Djit-debug=true` both green;
`tools/hashgate.py` 84/84 on ReleaseFast AND the Debug leg, no ref regeneration.

### The board is now remote — and the old one was garbage

The first board was taken on the desktop and DISCARDED: every row regressed +11% to
+46% INCLUDING the pure tier-0 column, which no JIT change can affect. Cause: a game
at 790% CPU, load average 12.9–17.3. Nothing was concluded from it.

`gt profile` now runs the suite on the Gothab isolated autoscale pool
(`.gothab/profiles.yml` + `.gothab/workflows/profile-bench.yml`, plus
`bench/run.py --json` and `tools/bench_profile.py`). Notes worth keeping:

  * the pinned Zig `-dev` tarball is GC'd from ziglang.org; the workflow walks the
    official community-mirror list at a PINNED sha256, verified bit-identical to the
    known-good local toolchain and agreed on by two independent mirrors;
  * `gt profile` ships committed-but-unpushed + staged + unstaged as ONE diff vs
    `origin/master`, so an arc is benchmarkable before it is pushed — but **untracked
    files are NOT in that diff**, they must be `git add`ed first;
  * the contract is correctness-only for now (cross-tier mismatches, LuaJIT diffs,
    run errors, discovery count). Timing thresholds wait until the pool's noise band
    is established, per Gothab's own guidance.

Three full runs: baseline (this arc reverted via `just shadow` + `git show HEAD:`,
harness kept), B2, and B2 AGAIN — the third to measure per-row noise on identical
code directly rather than infer it.

  * max per-row |Δ| on identical code: **1.3%**
  * total `jit` wall: 4276.8 → 4281.9 ms (**+0.12%**, flat)
  * spectral-norm: 89.6 → 85.8 ms (**−4.2%**), residency 10.3% → 11.4%

Two rows came in above the noise band and were INVESTIGATED, not tuned around:
`str_find_match` +3.3% and `scimark-lu` +2.0%. Both have IDENTICAL trace structure
between the builds (str_find_match 1 entry / 1 native body; scimark-lu 99000 entries /
99000 bodies / 13 aborts), neither touches a `.value` lane, and a `--dump-native` diff
on str_find_match shows an identical 585-line instruction stream differing ONLY in
embedded addresses. The residual is binary code LAYOUT (editing nativegen/trace moved
functions, changing I-cache and branch-predictor alignment) and it cancels across the
suite. Recorded in TODO.md so the next arc does not re-investigate it.

### Why the speed prediction missed: B2b (NEW, out of scope, filed in TODO.md)

The prediction assumed coverage was the only thing between `Av` and its trace. With
the trace now recordable, **89.3% of the run is "tier-0, has-trace"** — a committed
20×-faster trace that dispatch declines to enter:

```
Av:9    traced-it 118622  interp-it 681378  trc%it 14.8%  run% 89.3%
                                     native 22.2 c/it  tier-0 434.3 c/it
Atv:9   traced-it 791942  interp-it   8058  trc%it 99.0%
```

`Av` is called alternately over `u` (`.value`) and `v` (`.f64`) — ONE anchor, TWO
lanes. The prologue refuses entry for the wrong lane (`exit_instr == maxInt(u32)`,
`completed == 0`, nothing executed), `accountLegacyThrash` scores that refusal as a
thrash STRIKE, and ~60 consecutive refusals per call drive
`gate[dispatch:legacy_thrash]` with escalating 256→4096-tick cooldowns that block the
good calls too. `Atv` (monomorphic) sits at 99.0%. Two defects: an entry refusal is
not thrash (nothing ran), and the anchor never records a second trace for the second
shape (LuaJIT's answer is another root/side trace, not a penalty). Adjacent to B3
(`laneConsistent`: one array lane per whole trace).

### Open with Bart

Nothing committed, nothing pushed (~37 unpushed commits). The scoping choice is his:
land B2 alone and take B2b as its own arc, or extend this arc into B2b's
entry-refusal accounting so the board shows what B2 is actually worth.

## Status 2026-08-29 (LATEST-100) — **DOC 31 ARC LANDED: the gate is split (dispatch `gate` vs new `record_gate`) and `accountLegacyThrash` clears on ANY productive receipt. str_gmatch native residency 3.3% → 75% (gmatch anchor, by iterations), wall 52.6 → 49.4 ms. Board carries a new `res%` column (native residency by TSC cycles, from a dedicated `--jit-stats` run) — the D3 "stop circling this" fix, with the standing `--jit-stats`-before-verdict rule now in the project CLAUDE.md.**

Pre-arc, two small general levers landed the same day (Bart: "Inline len
seems straightforward", "after that lets look at gmatchAuxCore and the
region gate exit classification"): 122b186 inline string-`#` in tier-0
dispatch (instructions −2.8% on str benches but cycles −0.9% — the ILP
trap: at IPC 4.3 a 20%-of-cycle-samples symbol was NOT 20% removable;
instruction-count A/B is the honest metric, noted in the commit), and
a818c79 B03-shape fast path in the tier-0 gmatch iterator (`inLaneValueAt`
read twin; −6.5% instr, str_gmatch 56.2 → 52.6 ms). Also measured on
Bart's demand: the gmatch cost split is matcher ~41% / gmatchAuxCore ~23%
/ intern ~2% — which KILLED the L3-for-gmatch justification (L3 remains
relevant only for str_manip-shaped workloads; the open L3 yes/no is now
deprioritized).

The pathology (doc 31 §1, found while chasing "gmatchAuxCore + the region
gate"): a HEALTHY committed gmatch trace (completed=7 × 2647 receipts) ran
at 3.3% native residency because (1) designed-exit zeros (sgmatch
exhaustion, guard_gc admission) struck the legacy penalty, (2) the clear
threshold `completed >= min_useful=8` was unreachable for 7-token
instances so the penalty ratcheted monotonically, and (3) failed
side-recordings of the unrecordable generic-for done-direction gated the
ROOT anchor's DISPATCH (LuaJIT's penalty_pc only ever suppresses
re-recording). Codex BLOCKED the first design ((1)+(3) exit
classification): sgmatch's executors collapse non-OK statuses into one
exit_instr, guard_gc must keep striking, and the v1 split leaked in three
want/pending paths. Bart switched to (1)+(2) — the reviewer's
recommendation — via AskUserQuestion.

Landed (doc 31 §9 has the full table): D1 gate split with all three B3
leak fixes (want production gated in noteTakenExit/countGuardFailure/
countFingerprintMiss; final `recordingBarred` at maybeStartContinuation/
maybeStartReplaySide; onBackEdge retry probe consults both maps), D2
clear-on-productive (accepted give: 1-productive/1-zero alternation never
gates; escalation path = deterministic work-credit score, NOT an IR-op
list), D3 GateReason dbg tags + board res% + CLAUDE.md rule. Tests: 7 new
(5 unit trace_gate_test, 1 entrypatch, 1 e2e ratchet regression) + the
old "branchy low-yield blacklists" test DELIBERATELY inverted (it pinned
the ratchet; probe gate=0 penalty=0 entries=98 — §4's accepted give,
now pinned as such). Both legs + jit-debug green, hashgate 84/84.

**Measured vs predicted:** residency 75% vs >80% predicted; wall 49.4 vs
44–48 predicted. The residual is the per-instance ENTRY SEAM, not gating:
2 of 8 iterations/instance run tier-0 (~541 c/it) before native entry
catches (6 × ~265 c/it) — recorded in TODO.md as the follow-up lever
(first-header-reach entry patching, doc-30 `.jloop` territory).

**First board was NOT neutral → D1 amendment (doc 31 §9a).** Benches
whose hot loops abort recording and never trace regressed 40–57% in jit
mode (tbl_ops/euler14-bit/nsieve-bit-fp/sparse, all res% 0.0): the
GATE_SKIP pre-filter armed on `isGated` (dispatch) only, so abort-
blacklisted anchors — now living solely in `record_gate` — paid full
`onBackEdge` bookkeeping on every back-edge forever. Amendment:
`afterBackEdge` arms the skip when dispatch-gated OR (record-gated AND
no trace); record-gated WITH a trace still never skips (B3 starvation).
Pin test in trace_entrypatch_test.zig. Final board (§9b): str_manip −37%,
scalar −11%, gmatch −9%, find_match −6%; everything else ≤ noise
(repack + str_format cleared by same-conditions A/B — str_format is
instruction-identical, +2.8% cycles pure layout). Board-positive, no
above-noise regression.

## Status 2026-08-29 (LATEST-99, superseded) — **DOC 30 ARC LANDED (c1–c5): find/match/gmatch-iteration/tonumber(string) record as guarded callouts. str_find_match 32.4 → 20.1 ms (2.4× → 1.5× LJ, ≤20 target MET, zero recording aborts). str_gmatch flat at 57 — residue PROVEN constant-factor, not coverage (LJ runs it in ~25 ms with `-joff`; gmatch is NYI in LJ's recorder too). L3 intern-hash yes/no still open with Bart — now the identified next lever on gmatch.**

Commits: 625ec2b (c1 cores/scratch/shims), c2+c3 (IR ops 72–80 + tier-1a +
nativegen lowering), d32103b (c4 recorder arms + `recTForLoop` generic-for
back-edge), b008140 (c4b carried-string slot classification — the gmatch
for-in loop goes native end-to-end, 2995 bytes, completed=7..20/entry),
c28202a (§8 audit: `loopDoneSnapshotSupported` decline for deferred
`sgm_setpos` + tier-1a pin test), c5 (adversarial matrix + two general
recorder fixes). Full landed-results table in doc 30 §11 — including the
before/after `--dump-aborts` profile (find_match: host_barrier×6 → NONE;
gmatch body barrier → gone, ctor barrier stays by design §7).

**c5's two general fixes** (each surfaced by the board, both general per
Z-6): (1) `recBranch` statically-decided fold — konst-with-matching-
truthiness or proven-string-truthy branches emit NO guard (a string is
never nil/false; tautological guards were bailing `proveKinds` on
`if match(s,"^key")` shapes; worth 30.4 → 20.2 on find_match); (2)
`tfor_loop → .jloop` entry patching (patchedEntryOp + interp orig-arm
replaying canonical tfor semantics), so generic-for anchors can enter
native without waiting for the back edge.

**A/B (whole board, nm-verified 1755f0c shadow):** all rows ≤ noise
except find_match −31% and lua54 t0 +11% — the latter proven layout-only
by `perf stat` (instructions +0.3%, icache misses 7×; ~230 KB of new code
shifted tier-0 dispatch alignment; TODO.md note, not chased).

**Known residue / observations (TODO.md):** gmatch instances complete 7
native iterations (8 tokens, iter 1 lost to the nil-ctrl prologue) =
`work=7 < min_useful=8` → region-window gates ~half the entries; NOT
tuned (Z-6) — recorded as a gate-design question (designed exhaustion
exits vs thrash). `get_index` module-table indexing is NYI and blocks
inline `string.find` shapes. value16 full-Value shuttle slots would
generalize generic-for breadth (pairs/ipairs next).

## Status 2026-08-29 (LATEST-98, superseded) — **DOC 30 ARC IN FLIGHT: Bart approved ("less barriers is good, we want everything traced"). c1 LANDED (625ec2b); c2–c5 remain. Grammar decision RESOLVED (superset criterion; trim fix 1755f0c). L3 answered ("wyhash is good, the lever is O(1) sampling") — still awaiting Bart's yes/no.**

Bart's three answers (2026-08-29): (1) tonumber must accept a superset of
Lua 5.4 + LuaJIT — verified with a 77-case three-engine probe; ONE gap
(\v/\f trim) found and fixed (1755f0c); grammar (a) frozen, B3 scanner dead.
(2) Doc 30 GO. (3) asked whether the intern hash is "shitty" — answered: it
is wyhash (top-tier); the lever is byte COUNT (O(len) vs LuaJIT's O(1)
4-word sampling = doc 28 §5 L3, determinism-clean, ~-11% str_manip) — his
yes/no on L3 still open.

**Doc 30 c1 landed (625ec2b), tree green both legs + hashgate 84/84:**
- pattern.zig: `locateMatch` (the ONE anchored-scan loop; wrappers + tests
  refactored onto it), `census` (static capture count/kinds/anchored/
  specials walk on classEnd stepping; null = fail-closed), `Span`, `CapKind`.
- gc.zig: `Heap.match_scratch` (`MatchScratch`, extern; slot pairs; header
  `subj` ptr; `n_slots = 3 + 32 + 1`, `slot_next_pos` fixed; non-root,
  non-serialized).
- stdlib/string.zig: `MatchStatus` (negative-status ABI, M03), `smatchCore`,
  `sfindPlainCore`, `sgmatchCore` (read-only, identity + B03 checks),
  `scapStrCore`, `fillMatchScratch`; comptime slot-geometry assert.
- table.zig: `inLaneValueIntCell`/`setInLaneValueInt` (the B03 shape).
- stralloc.zig: shims `smatchRuntime`, `sfindpRuntime`, `sgmatchRuntime`,
  `scapStrRuntime`, `sgmSetposRuntime` (defensive re-verify, status i64),
  `str2numRuntime` (`Str2NumResult extern {status, value}`).

**c2 next (task #56)**: IR ops appended after `scp` (71): `sfindp` 72
(a=s, b=init, aux=pat ref — scp's ternary encoding, `.pure3`), `smatch` 73
(same operands, `.scratch3`), `sgmatch` 74 (a=state, aux=pat KONST ID
immediate, `.scratch1k`), `scap_int` 75 (a=match ref, b=slot imm, `.proj`),
`scap_str` 76 (ditto, ty .heap, `.alloc_proj`), `str2num_i` 77 / `str2num_f`
78 (unary a=s), `sgm_setpos` 79 (a=state, b=pos ref; deferred store),
`guard_sid` 80 (a=string ref, aux=konst id; joins guardKeyAux; NOT in
guardExitPc/isSideExitGuardOp — pinned). Sweep per doc 30 §8: trace.zig enum
+ doc comments + assertWellFormed + writeIrInstr; traceser ordinal pins;
viz/src/enums.ts (+TERNARY_AUX_OPS for sfindp/smatch); tropt kindOf + FOUR
new kinds through every switch (canonicalization ~:402, liveness ~:468,
LICM ~:560, remap ~:658, guardKeyAux :256, alloc-root :420) each pinned;
troptdiag operand walks (:157/:285 pattern); irinterp arms (executor has
heap; call the stralloc shims). c3: nativegen (proveKinds; BodyCallout rows;
emitters — smatch/sgmatch callout + status cmp; scap_int baked load;
scap_str snew protocol; str2num rax/rdx; sgm_setpos callout status-checked;
guard_sid ptr cmp vs compile-time konst; heap-null bail list +=
smatch/sgmatch/scap_int/scap_str). c4: recorder arms (RecordedBuiltin
find=20/match=21/gmatch_iter=22; recBTonumber string arm; census pin P1/P2;
B02 all-captures; M04 nil-pad; one-pending-sgm_setpos pin; doc 27 D1
stances). c5: §9 adversarial matrix + gates + board + docs.

## Status 2026-08-28 (LATEST-97) — **MATCHER + TONUMBER CONSTANT FACTORS (doc 29 A1–A4 + B(a)) LANDED. str_gsub 60.5 → 53.3 ms = 1.2× LJ (AT CAMPAIGN TARGET); find_match 2.4× → 2.2×; instr −17%/−12%/−8% on gsub/find/gmatch, format+scalar exactly flat. Doc 30 (pattern/tonumber recording) at v3, awaiting Bart's go-ahead.**

Bart approved levers 1+2+3 ("Ok, lets try to do 1, 2 and 3"). Lever 2
(matcher) + lever 3's grammar-(a) phase are this arc; lever 1 is doc 30,
design-complete (two codex rounds, v3) but NOT implemented — its status line
requires Bart's explicit go-ahead.

1. **A1 — table-driven `matchClass`** (`pattern.zig`): comptime
   `char_bits[256]` + `class_map[32]` built by evaluating the OLD predicates
   at comptime (so parity is by construction), LuaJIT's `(cl&0xc0)==0x40` +
   case-bit trick. Pinned by a full 256×256 cross-product test against an
   independent verbatim copy of the old switch (`refMatchClass`).
2. **A2/A3 — cheap hot-path widths**: 1-byte literal compare in
   `singleMatch`; `seqLen` ASCII fast path; `matchWidth` literal width is
   `ep−p` with the malformed-pattern carve-out (`ep−p==1 && pat[p]>=0x80`
   keeps `seqLen` — preserves the lone-`\xC3` defensive contract, codex M3).
3. **A4 — `countRun`**: `maxExpand`'s per-char item re-dispatch hoisted into
   one switch + per-kind counting loops ('.', class via table, bracket,
   literal stride; escaped-literal fallback when class map is 0 — `%z+` etc,
   codex M2). Old-loop parity test across 14 pattern kinds × every start
   offset.
4. **B(a) — `fastDecInt`** (`arith.zig`): strict-subset fast path in
   `toNumber`'s string arm (optional sign + 1..19 pure digits, i64 range,
   sign-asymmetric min); EVERYTHING else falls through to the untouched
   std.fmt pipeline, so routing/tags are preserved by construction (codex
   Blocker #1 redesign). Subset property pinned directed + pseudo-exhaustive
   (all strings len 1–4 over a 14-char alphabet) + end-to-end tag matrix.
5. **Gates**: `zig build test` green, `-Djit-debug` leg green, hashgate
   84/84, full board 28/28 cross=ok. Shadow instruction A/B (nm-verified
   baseline): gsub −16.9%, find_match −12.2%, gmatch −7.6%, format −0.00%,
   scalar +0.00%. Honest misses: gmatch only −4% wall (bracket class still
   linear-scans; dominant cost is tier-0 dispatch = doc 30's lever), gsub
   −11% wall vs predicted −20-25% (still reached 1.2×). A5 skip-scan
   deferred until after doc 30. Landed-results section in doc 29.

**OPEN DECISIONS for Bart** (Rule #17): (i) doc 29 §B2 tonumber grammar —
(a) freeze today's std.fmt-artifact grammar (fast path already landed, valid
under any choice) / (b) Lua 5.4 grammar / (c) LuaJIT grammar. Today mahina
accepts `"1_000"`→1000, `"0o17"`, `"0b101"`, `"inf"` — none Lua-legal.
(ii) doc 30 v3 go-ahead (ops 72–79: sfindp/smatch/sgmatch/scap_*/str2num_*/
sgm_setpos + guard_sid; kills the host_barrier on find/match/gmatch/tonumber;
gsub+format stay barriers in v1). (iii) doc 28 §5 L3 sparse intern hash
(still open from LATEST-96).

## Status 2026-08-28 (LATEST-96) — **STRING OP-CORE ARC (doc 28) LANDED, c1–c3b: exact per-string ASCII bit + seam fast paths + known-fact interning. str_manip 23.9 → 18.8 ms (5.0× → 4.0×), find_match −9.7%, gsub −5.3%. L3 (sparse hash) awaits Bart's call.**

Bart: "Lets do the strings first. Everyone will run into those at some point."
Four commits: 6194693 (c1), 511033a (c2), 435f383 (c3a), 37591cf (c3b).

1. **c1 — exact `GcFlags.str_ascii` bit + L1 seam helpers.** One fused
   construction scan; sound for ANY bytes (the effect log parks raw
   non-UTF-8 host input as interned strings — validate-after-log — so
   `cp_len == len` can be counterfeited and must NOT be the predicate;
   the codex review's "assert valid UTF-8 in createWithHash" must-fix was
   itself wrong, discovered by 6 failing S-B tests; recorded in doc 28 §2).
   `charByteOffsetS`/`byteToCharS`/`cpCountPrefixS`/`charPrefixEndS`/
   `strObjOf` + sub/codepoint/codes ASCII fast paths.
2. **c2 — pattern/format seams consume the caches.** `resolveInit` was an
   O(len) `cpCount` per find/match CALL → cached `cp_len`; result seams
   and position captures O(1) on ASCII subjects (threading: writeCaptures/
   captureValue take the subject `*String`, gmatchAuxCore recovers it from
   state[1], gsub threads it to addRepl*). `emitString` takes caller-known
   character counts; width/precision parse is checked (huge digit runs
   reject instead of overflowing usize — pre-existing wrap fixed).
3. **c3a — ONE `internImpl` + `Heap.internKnown(content, String.Known)`.**
   Producer-known facts skip the miss-path scan halves; asserted against
   the scan on miss AND against the existing object's caches on hit.
   `Known = {cp_len: ?usize, ascii: ?bool}` — the reviewed `known_cp`-only
   signature predates the §2 exact bit (a count can't produce the bit);
   reconciliation recorded in doc 28 §6.
4. **c3b — L2 block paths + §6 known-fact sites.** caseCore ASCII =
   resize-once byte map (append/grow discipline was ~15% of str_manip);
   reverseCore ASCII = plain byte reverse; subCore j−i+1, caseCore
   count-preserving claim (ASCII bit only on the block path — U+212A
   KELVIN → 'k' crosses the boundary, pinned by test), reverseCore
   permutation-exact both caches, rep2Core checked cp×n (`*String`
   signature, sRep + srep2Runtime updated), char1Core {1, code<0x80}.

**Board (20260828-191940 vs 20260828-171400):** str_manip −21%,
find_match −9.7% (prediction 32–33 landed at 32.4), gsub −5.3%, gmatch
flat as predicted. **str_format +4%: A/B'd + bisected (doc 28 §11)** —
~1% is the fused scan (the exact bit's principled price), ~3% is LLVM
inline/layout churn in decimal/sFormat code the slices never touched
(perf-diff attribution swings in untouched fns; forced-inline internImpl
tried and reverted). Not chased per Z-6; the decimal arc (§7 non-goal,
~45% of str_format) owns that cluster. Gates: suite green (1070),
hashgate 84/84, board 28/28 cross=ok, no non-string mover beyond noise.

**OPEN — L3 decision for Bart (doc 28 §5 is the decision text):** swap
`String.hash` wyhash → LuaJIT-style sparse sampled hash (4 u32 loads,
O(1) in length) + deterministic chain-length-triggered dense rehash in
the same change. Determinism-clean (hash feeds ONLY the intern table;
table keys hash by `GcHeader.id`; iteration order canonically sorted).
Biggest single remaining string lever (wyhash 11.3% of str_manip).

## Status 2026-08-28 (LATEST-95) — **diagnosability follow-ups to LATEST-94 (Bart-requested): every dump now names the input budget, and the overloaded `.too_deep` abort tag is split.**

Bart: "add that number somewhere in the trace debug — then next time we'll
know it is 7 and not hitting that cap", then "that seems like a healthy
change if we notice it now" on the abort-tag split. Both misdiagnosis
ingredients from LATEST-94 are now closed:

1. **`inputs=N/cap` in the dumps** (commit 087f451): `--dump-traces` trace
   headers and both `--dump-native` per-trace lines (compiled AND
   unsupported/tier-1a) render the committed trace's synthetic-input count
   against `MAX_TRACE_INPUTS` (now `pub` for the dumps only). str_manip
   shows `inputs=7/64` on its main trace. Tests pin `inputs=0/` (unit,
   cap-agnostic) and `inputs=2/` (two-upvalue anchor, integration).
2. **`.too_deep` split three ways** (this commit): the single tag covered
   THREE unrelated limits, which is why we had to guess. Now: `.too_deep` =
   only `MAX_INLINE_DEPTH` call nesting; `.frame_bounds` = `reg_map`
   reservation overflow (recCall callee window, recReturn dynamic writes);
   `.input_cap` = the input budget + the u16 slot-index wrap guard. No
   behavior change — same aborts, honest labels. `--dump-aborts` on the
   70-input probe now reads `input_cap @ get_upval`. The 70-input test
   asserts the reason (`record_aborts=true` leg: some `.input_cap`, zero
   `.too_deep`); doc 10's checklist got a split note.

Gates: suite green, hashgate 84/84 (both changes are flag-gated stderr
diagnostics only).

## Status 2026-08-28 (LATEST-94) — **INPUT-CAP ARC LANDED: `MAX_TRACE_INPUTS` raised 8→64 after an empirical sweep found NO breaking point — the input machinery is free through N=64. Bonus finding: LATEST-93's "str_manip blocked by the cap" diagnosis was WRONG (main trace commits at cap 8; corrected in TODO.md + doc 27 §11).**

Bart: "lets do that nest limit, we need to see where higher than 8 breaks."
Answer, measured: **it doesn't** — at least not through 64.

**What `MAX_TRACE_INPUTS` actually is (trace.zig):** the budget for synthetic
entry inputs — upvalue/global/hash_cell snapshots a trace needs seeded per
entry. `recInputGet` (~14239) aborts `.too_deep` past it; the hash_cell
seeder (~12882) declines native. Slots allocate from `next_input_slot =
num_registers` upward into dead slab scratch; `seedTraceInputs` (interp.zig
~959) re-resolves each per entry (upvalGet/globals.get + regSet), capacity-
checked DYNAMICALLY (declines entry on overflow), and `entry_guards`
excludes input slots from the fingerprint. So the constant is pure policy —
not a layout invariant, not a fixed array bound.

**The sweep (ReleaseFast, best-of-5/7 wall):** generated N-upvalue-callee
loops (`local fK = function(x) return x + K end` ×N, hot loop summing
`f1(i)+..+fN(i)` inside `run()`) in two shapes — steady-state (one long
loop) and entry-heavy (many short re-entries, stressing per-entry seeding) —
at N = 2, 4, 8, 12, 16, 24, 32, 48, 64 with the cap lifted to 128. Result:
jit cost FLAT (~1.1 ms, ~45× vs tier-0's linear growth) at every N in both
shapes. Control: identical programs with the callees as ANCHOR-LOCALS
(zero synthetic inputs) vs upvalues at N=8/16/32/64 — deltas ±0.05–0.17 ms,
inside noise. Conclusion: seeding cost is per-entry and tiny; the guard cost
is `guard_func` per input, which the trace amortizes. No cliff exists to
tune around; 64 is a backstop against degenerate anchors (maxrecord bounds
IR growth anyway — each input costs ≥2 ops).

**The wrong diagnosis, falsified:** flipping the cap back to 8 shows
str_manip's main-path 74-op trace COMMITTING (ssub→supper→slower→srev→slen→
scp×2; 7 inputs: sub/base/upper/lower/reverse/len/byte; 8593 bytes native;
the 1/64 branch folds to `guard_false`). The 518 `too_deep` hits in
LATEST-93 were that branch's SIDE-traces, which additionally read `char`/
`rep` (inputs #8/#9); at cap ≥16 they die at 3-arg `rep` instead
(`recBSRep2` is 2-arg — rep3 frontier). Bench ~5.0× at ANY cap. str_manip's
real remainder (perf rollup): tier-0 exec 21.5%, caseCore ~17.3% (full-
Unicode machinery on ASCII data), memcpy 13.1%, wyhash 10.4% (interning),
subCore 8.9%, reverseCore 7.5%, codepointCore 5.1%, decodeAt 4.1% — op-core
cost, not coverage. TODO.md entry rewritten; doc 27 §11 got a correction
block.

**Landed:** `MAX_TRACE_INPUTS = 64` with a measurement-bearing comment
(trace.zig). Two tests (interp_trace_test.zig, "input cap" prefix): 12
distinct upvalue callees RECORD via `expectRecordedProgram` (the shape the
old cap silently killed → "19200\n"), and 70 callees (comptime-generated
source) fail CLOSED — 10-leg parity + a dedicated leg pinning
`entries == 0` ("277200\n"). Gotcha rediscovered: CLI-default hotloop means
50-iteration probes never record — the 70-input CLI probe needed 500 iters
to show the `.too_deep` abort (3 hits, get_upval, ir_len 580); the test
harness's hotloop=4 needs only ~5.

**Gates:** suite green (`just test`), hashgate 84/84, full board
(20260828-171400) vs the committed cap-8 baseline (20260828-163336): flat
within noise (uniform +2–4% t0 drift = today's machine, not the change);
str_manip 23.9 ms / 5.0× unchanged as predicted. The only >5% movers —
recursive-fib −33%, scimark-fft −36% — are the two rows LATEST-93 already
flagged as contention-inflated in the baseline (their LuaJIT columns were
21.4/25.1 ms there vs 7.2/16.4 today); both are back at historical norms.

**Next-arc candidates for Bart:** str_manip op cores (ASCII fast path in
caseCore/decodeAt, interning cost), rep3 recording, or board-worst rotation
(array3d ~29×, spectral-norm ~30×).

## Status 2026-08-28 (LATEST-93) — **MULTINEST LANDED (doc 27): dynamic-multret pairs record via a one-instruction recorder shadow — `f(g(x))` at any depth, closure composition included, recorder-only, board flat, ~~str_manip's blocker moved to the `MAX_TRACE_INPUTS=8` cap~~ (WRONG — corrected in LATEST-94 above).**

Bart chose multinest ("lets go for multinest — does that mean two nested
things or arbitrarily nested?" → arbitrarily: the mechanism is per-call-site,
depth never appears). Full loop ran: grounding (tier-0 `reg_top` resolution,
mirror-before-execute ordering, LuaJIT `BC_CALLM` reading `L->top`, compiler
pair-adjacency, anchor-replay deopt) → doc 27 → codex review (approved; 2
MUST-FIX folded in: shadow lifetime across `maxrecord` aborts/reset, u32
width + sentinel-collision checks; plus the §3b dual-role stash and a §5
rewrite — recordings only ever start at coherent anchors, never bare guard
exit pcs) → implement → 14 tests → gates.

**Mechanism (trace.zig, recorder-only — no new IR ops, no tier-1a/nativegen/
tier-0 changes):** `Recorder.multret_top: ?u32` shadows tier-0's
`reg_top`/`reg_top_pending` handshake; `recordOne` stashes+clears it per
instruction (scope = exactly the designated consumer); cleared in `reset`
(soundness boundary) and `abort` (defense-in-depth). D1: single-result
builtin arms accept `c=all_results` via whitelist (`codepoint`/`select`
excluded — `.multi` projections), record under effective `c=1`, publish
shadow post-arm (gated on `rec.active`). D2/D3: `call b=all_results`
(builtin + closure) resolves `nargs = top-(a+1)` — tier-0's own arithmetic,
frame-relative so `base` never enters; fail-closed on null shadow and on
counts ≥ the sentinel. D4: closure `call c=all_results` stores the sentinel
in `ret_count` verbatim; `recReturn` maps exactly `produced` (no nil-fill)
and re-exports the shadow in caller frame-space. D5: `ret b=all_results`
resolves `produced = top - a` (counts fixed prefixes: `return x, g()`).
recReturn also gained a reg_map bounds check (`.too_deep`) for the dynamic
shapes. §5 invariant (why no LuaJIT-style `needsnap` needed): deopt is
anchor-replay — tier-0 redoes the whole iteration, re-executing the producer
itself, and no resumption pc can split the compiler-adjacent pair.

**Tests:** 14 "doc 27" tests in interp_trace_test.zig via new
`expectRecordedProgram` (10-leg parity + a dedicated `entries>0` leg —
parity alone can't see silent-abort regressions): flagship native
`lower(upper(s))` with supper→slower provenance chain + effect record/replay,
depth-3 (dual-role middle call), mixed args (nargs=3), closure consumer,
closure producer, D1+D2+D4+D5 chain `up(ap(low, base))`, return prefixes
(zero/one/multi legs), method-call parity (lookup is NYI `get_index` —
comment says to upgrade when recordable), `select('#', g())` (resolution
off-by-one = wrong VALUE), rawset-as-producer, zero-produced `f(g())`,
fail-closed (cp multi-producer, vararg spread), §3a lifetime pair (reset
clears a planted shadow; `maxrecord=8` run leaves null shadow + parity),
deopt-through-pair (3 mid-run side exits, byte-identical). Gotcha for future
tests: closure legs must be PARAM-clean — an upvalue/global read inside an
inlined callee hits the pre-existing U0 barrier and masks the multret path.

**Gates:** suite green (19 matching tests pass), hashgate 84/84, board
28/28 cross=ok vs HEAD shadow baseline (/tmp/mahina-base-multinest, sources
restored via `git show HEAD:`): flat within noise (recursive-fib/scimark-fft
looked inflated but LuaJIT's own column moved too — re-runs confirmed
contention). Board tsv 20260828-163336 committed.

**str_manip (honest):** MULTRET abort GONE (zero cross_frame), 5.2×→5.0× —
the same loop now dies at `recInputGet`'s `MAX_TRACE_INPUTS=8` cap
(`too_deep` @ `get_upval`, 518 hits): >8 distinct cached-builtin upvalues,
each one synthetic entry input + guard_func. New TODO.md entry with the
lever analysis (input cost is per-trace-entry — profile before raising the
cap; general-language wall, any loop calling >8 cached functions). That cap
is the natural NEXT arc candidate.

## Status 2026-08-28 (LATEST-92) — **effect-cursor bug FIXED (Bart: validate-before-advance) before starting multinest. `nextLoggedEffect` now kind-checks before advancing; `noteUnicodeVersion` peeks (`peekLoggedEffect`), validates, consumes only on success — a rejected wrong-version entry stays in front of the cursor, every retry re-raises, no silent mismatched-table pin.**

Bart: "tempted to go towards multinest, but I don't want to leave the
pre-existing bug in if I can help it" → fix first, then the MULTRET
nested-call arc (TODO.md #1).

- Cursor position is now a truthful "consumed successfully" record — the
  contract `versionAlreadyConsumed`'s prefix scan silently depended on; it is
  now documented on `nextLoggedEffect`/`peekLoggedEffect`.
- Regression tests (interp_effects_test): self-erasing retry (direct
  `noteUnicodeVersion` after the fault re-raises, cursor 0, pin false ×2);
  kind-diverged entry not consumed on `EffectKindMismatch`; cursor/pin
  asserts added to the corrupt-float leg.
- Found while testing: `beginTopLevelEpoch` ALREADY refuses re-`run` of a
  faulted VM (`DirtyTopLevelEntry`, depth != 0) — the 2026-07-17
  faulted-but-live TODO entry was stale on that point and is amended (what
  remains: non-`run` entry points + depth/stack_top never reset). The seam
  this fix actually closes is host-driven calls / resumed sessions.
- Gates: full suite green; hashgate 84/84 (replay path untouched by the 3
  bench modes, but cheap insurance).
- **Next: multinest** — TODO.md #1, nested last-arg builtin calls (MULTRET
  → `.cross_frame`), now str_manip's sole blocker; fix shape sketched there
  (resolve `nargs` from `reg_top` exactly as tier-0 does; accept inner
  `c = all_results` when the consumer takes one value).

## Status 2026-08-28 (LATEST-91, superseded by 92) — **doc 26 LANDED: upper/lower/codepoint record + run natively (supper/slower/scp, ordinals 69/70/71). str_manip UNCHANGED (5.1×) — its `lower(upper(a))` spelling aborts at the pre-existing MULTRET nested-call frontier (TODO.md #1), which is now its SOLE blocker and the next general lever.**

Bart's go-ahead: "proceed with upper/lower please". Full loop ran: doc 26
written → codex-reviewed (no blockers, 8 majors folded in) → c1 (D1a,
3d0b946) → c2 (this commit) → gates.

- **c1 (already committed, 3d0b946)**: D1a — errors unwinding mid-recording
  now abort it (`errdefer self.trace.abortRaised()` in `execWith`, new
  `AbortReason.raised`). Pre-existing Franken-path hazard, reachable TODAY
  via schar1-under-pcall; bisection-pinned test.
- **c2 (this commit)**: the three ops end-to-end.
  - `supper`/`slower` = snew `.alloc` class (emitAlloc → guard_gc bound;
    `emitSnewCallout` srev arg shape; shared `caseCore` — the FULL Unicode
    core, heap-only per the D1 pin-monotonicity invariant: any committed
    trace containing them implies a tier-0 upper/lower already pinned the
    version in the same VM, `requires_unicode_pin` bit + entry/driveChain
    asserts enforce it).
  - `scp` = new `.pure3` OpKind (all-3-operand liveness/compaction, CSE+LICM
    fail-closed v1, DCE admitted); plain `emit` (never inflates A); separate
    `emitScpCallout` — (s,i,j) in rdi/rsi/rdx, NO heap arg, −1 sentinel
    full-width signed compare (U+0000 is a real result); empty range →
    side-exit, tier-0 replays to nil through any continuation.
  - M5 retrofit: result-`ty` fail-closed checks added to ALL existing
    snew/tostr proveKinds arms (a malformed ssub stamp used to compile).
  - Else-arm audit found ONE miss beyond the doc's sweep: `isProvenStringRef`
    gained supper/slower. `emit` PC-stamping correctly excludes scp (aux is
    a REF — M7); `guardExitPc` null for all three.
- **Tests**: +12 (flagship native e2e under effect-record: ONE
  `.unicode_version` entry for 400 case calls + replay leg byte-identical;
  scp arg-shape matrix incl. b==aux ref sharing; empty-range deopt-STATE
  parity (object_count/next_obj_id) through nil-consuming AND raising
  continuations; `.pure3` contract pins (dead scp DCE'd, identical scps
  never CSE'd, compaction remaps aux, alloc_bound 0, no pin required);
  recorder fail-closed matrix (float index / multi-result / non-string
  raise); hand-built native parity (full Unicode both directions, U+0000,
  heap-less scp compile, M5 malformed-stamp matrix + control).
- **Gates**: suite green both legs (+ `-Djit-debug`); hashgate 84/84; bench
  28/28 cross=ok ×2 stable; instruction A/B vs 3d0b946 shadow (nm-verified
  baseline): scalar +0.0006%, nsieve −0.0004%, fft −0.05%, str_manip −0.56%.
- **The honest outcome + next lever**: str_manip did not move. Probe:
  the bench's `lower(upper(a))` puts the inner call in last-arg position →
  MULTRET → `.cross_frame` abort at the call; the SAME core via an
  intermediate local records with ZERO aborts. So doc 26's machinery works
  and the abort moved onto TODO.md #1 (nested last-arg builtin calls, fix
  shape already sketched there) — a general recorder gap that benefits every
  composed builtin expression (Z-6). That is the natural next arc for the
  string family; `rep(char(..),4,"-")` (3-arg rep) hides behind a 1/64
  branch and can stay a side-exit.
- **Flagged for Bart (Rule #0.5, not fixed)**: TODO.md — `nextLoggedEffect`
  advances the cursor BEFORE validation; after an uncatchable
  `UnicodeVersionMismatch`, a host re-running the faulted-but-live VM pins
  the MISMATCHED table silently via `versionAlreadyConsumed`. Fix is a
  design choice (peek/commit split vs validated-flag).

## Status 2026-08-28 (LATEST-90, superseded by 91) — **mod/idiv NATIVE LOWERING LANDED (doc 25): scalar 4.3× → 0.9× LuaJIT (−87.6% instructions). `%` no longer poisons native entry anywhere. Pre-existing `minInt % -1` SIGFPE found and fixed in the oracle.**

Bart asked whether the doc-24 v2 escalation overrides mod/idiv work — it
doesn't (v2 is recorder/exit protocol; mod/idiv already record + run tier-1a,
only the nativegen lowering was missing) — and said "lets do those first".
Full campaign loop: doc 25 written → codex-reviewed → implemented → gates.

- **Codex review verdict on the design**: sound except ONE BLOCKER —
  `(minInt, -1)` must NOT side-exit (tier-1a computes the defined value —
  `mod` 0 / `idiv` minInt — and CONTINUES; a native exit would diverge via
  the deopt ledger + iteration replay of earlier heap stores). Fixed: the
  pair is detected (it #DE-traps in hardware) and its result materialized
  INLINE, no exit. Two mediums also folded in: exhaustive `ty` switch in the
  proveKinds arm (the add/sub/mul arm's `else` treats a malformed
  `.boolean`/`.nil` stamp as int — don't copy) + `a<i`/`b<i` bounds; and
  `div_save` as an allocator-OWNED unique spill slot outside the callout
  region (never its padding slot).
- **Int lane** (`ty == .int`, both operands proven int): inline
  `cqo`/`idiv` + floor adjustment in `emitIntDivMod` (~16 instrs). rdx (the
  live `*NativeResult`) parks in `Alloc.div_save` for the duration; rax/rcx
  scratch; result canonically in rax. ONE side-exit: zero divisor → tier-0
  re-raises DivisionByZero from the instruction-`i` snapshot (same point
  tier-1a errors). Rejected: the generalized callout (full GP+XMM sweep,
  ~40 moves — LuaJIT's `lj_vm_modi` is a minimal-clobber asm helper, NOT a
  SysV call, so "Pall calls out" licenses nothing heavy).
- **Float lane** (`ty == .float`, ≥1 proven float operand): body callout to
  NEW shared kernels `fmath.fmodRuntime` (`x - floor(x/y)*y`) and
  `fmath.floordivRuntime` (`floor(x/y)`), strict FP, noinline, callconv(.c)
  — and `arith.mod`/`arith.floorDiv` float paths REFACTORED to call them, so
  all three tiers share one compiled body (the powRuntime discipline. Total
  functions: y==0 → NaN/inf through IEEE, NO exit). `emitFloatCallout`
  binary-staging extended (pow → pow|mod|idiv), BodyCallout rows
  fmod/ffloordiv.
- **x64.zig**: `cqo` (REX.W 99), `idivReg` (REX.W F7 /7), `Cond.ns` (0x9);
  golden-byte tests incl. the REX.B lane.
- **PRE-EXISTING BUG FOUND (Rule #0.5)**: `arith.mod`'s comment claimed
  "@mod is floored; minInt % -1 == 0 (no overflow)" — FALSE. `@mod` lowers
  to hardware idiv → `minInt % -1` SIGFPE'd tier-0 mahina (CLI-reproduced).
  Exposed by the doc-25 pair test exercising the tier-1a oracle. Fix:
  `y == -1 → 0` special case (mathematically x % -1 == 0 for EVERY x under
  floored mod; Lua 5.4's luaV_mod does the same). Pinned in arith tests
  (`7 % -1`, `minInt % -1`). `floorDiv` already had its pair special case.
- **Tests**: sign-matrix parity (4 quadrants + exact-division no-adjust +
  minInt with ordinary divisors + absolute pin −6/−9 for 7,−3×3 iters);
  (minInt,−1) native-CONTINUES leg (completed 1, exit at the loop guard,
  results 0/minInt, regs parity); divisor-hits-0 mid-run side-exit parity
  at the op's own instruction (both ops, `inline for`); float lane parity
  incl. y==0→NaN CONTINUING natively and ±inf; mixed int%float promotion;
  malformed-ty fail-closed (boolean stamp; float stamp on two int operands);
  combined int-div + float-callout + 18-slot spill pressure with structural
  asserts (`div_save` exists, > callout base+count → past the padding slot,
  < spill_count); VM e2e: `u = u + i % 10 + i // 7; f = f + i % 2.5` under
  FULL native config → output == tier-0 truth AND `native_entries > 0` (the
  arc-B vacuity trap inverted into the payoff assertion).
- **Gates**: full suite both legs (incl. -Djit-debug) green; hashgate 84/84;
  `just bench` 28/28 cross=ok all-luajit-ok ×2 runs. **scalar jit 5.8–6.0ms
  vs LuaJIT 6.4–6.5ms = 0.9× — first sub-1.0× row of the campaign** (was
  4.3×; −87.6% instructions, 633.7M → 78.7M). Instruction A/B vs a 9ce7344
  shadow (nm-verified, rc-checked, 3 reps): partialsums jit +0.0001%, nsieve
  jit +0.001%, tbl_ops jit −0.03%, t0 drifts ≤ +0.24% (recompiled-unit
  codegen jitter + the tier-0 y==−1 compare; recursive-fib's +0.24% has no
  mod at all — pure jitter). **Wall-clock boards were taken under load ~20
  (parallel agents) and swung ±70% on unchanged-instruction rows — the
  instruction A/B is the authoritative regression record.** Stale
  "mod blocks native" comments updated in interp_trace_test /
  keyframeser_resume_test / doc 24 notes / TODO item 3.
- **Remaining named frontiers**: upper/lower recording (v2, `*Vm` effect
  channel, codex #10) — now THE str_manip blocker (5.3×); nbody/spectral/
  fft per the campaign map. array3d 25–29× (heap-valued hash field loads +
  generic-for) unchanged.

## Status 2026-08-28 (LATEST-89, superseded by 90) — **arc B COMPLETE (c4): adversarial matrix + §T-A.2 acceptance green, board 28/28, doc 24 → landed. Next lever: mod/idiv native lowering (TODO item 3 — currently blocks scalar/e2e traces from native entirely via the safety net).**

**c4 (this commit)** — the D9.2/D9.3 gates for the whole arc, plus docs:

- **D9.2 adversarial matrix** (nativegen_lowering_test + interp_trace_test):
  two-allocs-per-iteration headroom boundary (guard_gc declines entry when
  only ONE would fit; minimal headroom exhausts identically across tiers);
  intern-hit loop parked just below `next_gc` completes natively with
  `object_count` unchanged; OOM injection via `std.testing.FailingAllocator`
  (verified in pinned-toolchain source: `fail_index` is STICKY — allocation N
  and all later ones fail) at fail points {3,5,8,13,21} → tier-equal
  completed/exit_instr/regs/heap-deltas (the D2 id-stream proof); `gc_stress`
  bounces allocating traces to tier-0 with identical output (`entries > 0` —
  they enter, guard_gc exits them); observation blackout keeps allocating
  traces OUT of the executors (`entries == 0` is the load-bearing assert; the
  gc_stress twin proves the same config otherwise enters); threshold bouncing
  across REAL GC cycles — mod-free source, `object_count`/`next_gc`/
  `next_obj_id` all equal vs tier-0, `native_entries > 0` on x64.
- **D9.3 acceptance** (keyframeser_resume_test): allocating snew/tostr loop →
  cross-tier final snapshots **byte-identical** (`expectEqualSlices` on the
  encoded files), `keyframe.next_obj_id` decoded and asserted equal
  explicitly (> 1000), pairs-order-sensitive fold over 26 string keys pinned.
  CLI-verified production shape: 16 native entries, 77.5% traced iterations.
- **Chain/link budget re-check**: needed NO bespoke test — `guard_gc` is a
  body op, so every entry path (fresh / `tryChainExit` / armed native link)
  re-executes it by construction. Recorded in doc 24 implementation notes.
- **D9.4 board**: `just bench` 28/28 cross=ok all-luajit-ok
  (results/20260828-000644-4c34598.tsv); hashgate 84/84. Instruction A/B vs
  c2 shadow (just shadow + git-show restore + nm-verified, medians of 3):
  str_gsub +0.00%, scalar +0.00%, **str_manip +0.16%** (~0.9M instr) —
  bounded recording overhead (c3 records through sub/reverse/len before the
  `upper` abort where c2 aborted at the first `sub`); wall unchanged; pays
  off when upper/lower land (v2). **A/B lesson: the first measurement run
  was BOGUS — zsh doesn't word-split unquoted `$var`, so every leg was
  measuring startup+FileNotFound (~410k instr) and "+0.00%" was vacuously
  reproducible. Check `rc` and sanity-check magnitudes (str_manip is ~572M
  instr) before believing any perf-stat delta.**
- **Docs**: doc 24 status → landed + "Implementation notes" section (lazy
  guard_gc placement; chain re-check by construction; null-collapse; stable
  `Vm.heap` pointer; string provenance passes + prologue pin; ssub.aux
  liveness; b==nargs arity pins; MULTRET frontier; the native-safety-net
  vacuity trap → **every VM-level JIT test must assert `entries`**).
  Inventory (Z-5): no rows change — len/sub/reverse/char/rep were
  `implemented` before c3 and recording state is not an inventory column.
- **Arc B summary** (c1 495f1e5 → c2 0d2c3ed → c3 4c34598 → c4): allocating
  builtins record and run natively under full determinism — budget entry
  guard, shared cores for byte-and-id-identical allocation, blackout for
  replay. scalar 4.3× / str_manip 5.6× vs LuaJIT remain: scalar is blocked
  from native by `mod` (safety net declines the whole trace — no lowering),
  str_manip by `upper` (v2). Both frontiers are named, neither is allocation.

## Status 2026-08-27 (LATEST-88, superseded by 89) — **arc B c3 LANDED: the snew class (ssub/srev/schar1/srep2 + guard_string native) records, optimizes, and runs NATIVELY end-to-end. str_manip's abort frontier moved from `sub` (first builtin) to `upper` (out of v1 by design, codex #10). c4 (adversarial matrix/board/docs) remains.**

**c3 (this commit)** — everything from recorder to native codegen for the four
allocating string→string producers (doc 24 D4), plus native `guard_string`:

- **Recorder** (trace.zig): `isProvenStringRef` (tostr/snew results),
  `stringArgRef`/`intArgRef` (the `!?Ref` null-=-aborted convention; konst
  passes, proven passes, observed → guard_string/guard_int pin, else
  `.bad_type`), five arms recBSLen/SSub/SRev/SChar1/SRep2 dispatched from the
  registry tags (string.zig rows len/sub/reverse/char/rep → `.recorded`).
  **Arity pins are `instr.b == nargs`** (NOT nargs+1 — b IS the arg count;
  caught by the shape tests, worth remembering). 2-arg sub records its default
  end as `konst(-1)` (shared op, codex #4: end rides `aux` — the ONE
  three-operand op). 1-arg char only (variadic aborts), 2-arg rep only
  (separator aborts), both `.cross_frame`.
- **Cores are shared** (stdlib/string.zig pub subCore/reverseCore/char1Core/
  rep2Core; stralloc.zig C-ABI shims call the SAME functions tier-0's natives
  wrap) → tier-identical bytes AND allocation counts by construction. A shim's
  null return collapses BOTH D5 failure arms (OOM and the tier-0 raise —
  invalid codepoint / negative... n<=0 is NOT an error, rep2Core interns "")
  into one clean side-exit; no `Heap.link` precedes the fallible step.
- **nativegen**: `string_guarded`/`is_string` provenance in proveKinds (a
  guard_string-covered slot_load classifies `.heap` invariant + `is_string`;
  slen generalized from tostr-only to `is_string`; guard_string discharges to
  `.none`); SlotInfo.is_string + a new prologue loop pinning
  `header.type == string` once per entry (STRING_TYPE const); analyzeInner
  bails an invariant `.heap` slot with NO covering guard_string (fail closed);
  **ssub.aux liveness is an explicit `last_use` extension** (operandReads'
  two-field shape can't express a third operand — the dyn-href precedent);
  BodyCallout rows ×4 (may_allocate, NOT may_collect); `emitSnewCallout`
  modeled on emitTostrCallout (rdi=baked heap, rsi=a, rdx=b, rcx=aux-for-ssub;
  rcx arg/result-stash dual use is safe — the call consumes the arg);
  compileImpl heap-null bail extended to the snew ops.
- **tropt/troptdiag/traceser/viz**: `.alloc` kind (never CSE'd/DCE'd/hoisted
  — codex #8: a repeat is a fallible op tier-0 performed), multi-operand
  liveness+compaction remap incl. ssub.aux; wire pins 65–68 (count 69).
- **Tests**: recorder shapes + abort matrix (trace_record_test); native tier
  parity incl. UTF-8 cp semantics on multibyte windows, n<=0 empty repeat,
  invalid-codepoint mid-run side-exit (completed/exit_instr/heap-delta all
  equal), guard_string prologue-fail legs (table → STRING_TYPE check, int →
  tag lane, regs untouched both ways), no-heap compile decline
  (nativegen_lowering_test); e2e VM-level snew loop (alloc_bound=4, one
  guard_gc aux=4, output == tier-0 truth) and the no-CSE + ssub.aux-remap
  pin through real tropt compaction (interp_trace_test).
- **Frontier notes**: nested last-arg calls (`rev(sub(...))`) compile to
  MULTRET and abort `.cross_frame` — new TODO entry with the fix shape
  (resolve `reg_top`-derived nargs like tier-0 does; general win for any
  `f(g(x))`). str_manip v1 recording now aborts at `upper`
  (`mapCaseUnicode` touches VM effect state — out of v1, codex #10). Konst
  heap-string operands still decline native (konst arm accepts heap consts
  only as href keys) — c4 note. Carried string slots (`s = sub(s, ...)`)
  bail in classification (lk==.heap falls to the scalar-only arm) — fine,
  read-only subjects are the bench shape.
- **Gates run**: both full test legs (incl. -Djit-debug=true), hashgate
  84/84, str_manip byte-identical t0/--trace/--jit-native/LuaJIT
  (acc=20207538 at N=100k).

## Status 2026-08-27 (LATEST-87, superseded by 88) — **arc B c1+c2 LANDED: scalar's `#tostring(i)` loop records END-TO-END (zero aborts) and runs tier-1a (~849 c/it vs ~1480 tier-0; wall 0.29→0.20 s at N=1M). Native is blocked ONLY by the deferred `mod` lowering (TODO item 3). c3 (snew class) + c4 (adversarial matrix/board) remain.**

**c1 (495f1e5):** mtype fold arm (RecordedBuiltin mtype=11) + alen sunk-store
refinement (D7). lua54's abort frontier moved pc 21 → 65 (`table.pack`, out of
v1 scope — TODO entry). **c2 (this commit):** the whole D3/D4/D5 scalar slice —
see the commit message for the mechanism inventory. Highlights and the
implementation decisions that now bind (recorded as doc-24 implementation notes
to write in c4):

- **Wire ops as built (count 60→65):** tostr_int=60, tostr_num=61, slen=62,
  guard_string=63, guard_gc=64 (aux=A). c3 plan: ssub=65, srev=66, schar1=67,
  srep2=68; RecordedBuiltin len=12, sub=13, reverse=14, char=15, rep=16
  (mtype took 11 in c1 — supersedes the LATEST-86 numbering sketch).
- **guard_gc is placed LAZILY before the trace's first `.alloc` op** (not
  physical index 0): preceding effects are already header-replay-idempotent
  under C1, and a failing guard_gc ⇒ zero allocations this iteration ⇒ clean
  D2 replay. Avoids renumbering every existing trace shape.
- **Exit-PC exclusion is STRUCTURAL:** guard_gc is simply not in
  `guardExitPc`/`isSideExitGuardOp`, so hot-guard counters, side-trace
  recording, and exit chaining all ignore it with zero surgery.
- **tropt got two new OpKinds:** `.alloc` (tostr — effectful value-producing
  roots, never DCE/hoist/fold/CSE; CSE-for-tostr admitted by codex #8 but
  deferred) and `.gcguard` (guard_gc's `a` is UNUSED — classifying it `.guard`
  would misread instr 0 as its operand).
- **`Vm.heap` is now a stable `*gc.Heap`** (gpa.create in initBare): native
  pages bake `&heap.gc_stress`/`object_count`/`next_gc` and pass the heap to
  the `stralloc` callouts as imm64s. The by-value Vm may move (the
  NativeSeedCtx precedent), so the heap HAD to leave it. ~94 mechanical
  `&vm.heap`→`vm.heap` sites; `TraceState.exec_heap` is the once-set mutable
  channel (vs `rec_heap`, still refreshed per recordInstr).
- **Blackout (codex #2) = two candidate-loop skips:** trial walk declines
  `alloc_bound > 0` traces while `suspend_ctl != null or
  record_safepoint_lines`; driveChain reuses the already-threaded
  `safe_to_arm` (identical condition). Armed-slot fusion needs no extra gate —
  `disarmAllLinks` already fires on unsafe.
- **guard_string native lowering deferred to c3** (proveKinds bails; the
  scalar slice never needs it — tostr results are producer-proven).
- **Gates run:** `zig build test` + `-Djit-debug=true` (1006/1006); hashgate
  84/84; scalar t0/--trace/--jit-native/LuaJIT all byte-identical
  (acc=2188895 / 22888896 at N=1M); `--dump-aborts`: NO aborts; recorder-shape
  + tier-1a/native differential tests incl. same-allocation-count (D2),
  guard_gc decline legs (budget/gc_stress/no-heap), and the tostr_num
  shared-renderer pin ("1"/"1.5" shortest-round-trip).
- **Found & fixed en route:** H-2 clearCache test used `#tostring(i)` as its
  abort-log seed — now records, so the seed moved to `tostring(t)` (table,
  still aborts); five `const gc` locals in irinterp shadowed the new gc
  import (renamed `gcell`); float `lt`+`add` hand-built traces need `.ty =
  .float` stamped (recorder always stamps; tests didn't).
- **`--jit-native` scalar is unchanged vs pre-arc-B** (tier-0 owned it then
  via the recording abort, owns it now via the native-unsupported gate on
  `mod`). The tier-1a win is real and the native win is one small general
  lowering away (int `mod`: idiv + floored-sign fix — TODO item 3, priority
  note added).

## Status 2026-08-27 (LATEST-86, superseded by 87) — **arc B designed + codex-reviewed: doc 24 "deterministic on-trace allocation", v1 pivoted to the allocation-budget entry guard.**

Design record (full detail in docs/design/24-deterministic-on-trace-allocation.md
+ its codex ledger; constraint inventory citations in the doc):

- **The two constraints:** `next_obj_id` is a byte-compared cross-tier keyframe
  field (total allocation count observable, garbage included), and `pairs`
  order keys on object id → id divergence = stdout divergence. So JIT modes
  must reproduce tier-0's allocation event stream EXACTLY — Pall's sink/elide
  licence is exactly what we cannot take.
- **What makes it work:** intern hits consume no id/memory (idempotent across
  non-collecting windows); collection only at the single tier-0 prologue site;
  non-moving GC. D2 lemma: within a non-collecting window the id stream is a
  pure function of the intern-call sequence → partial-iteration deopt replay
  is id-neutral (first run's misses become the replay's hits).
- **v1 protocol (codex #11):** `guard_gc` ENTRY guard per allocating body:
  `!gc_stress ∧ object_count + A < next_gc` (A = static alloc bound). Passing
  makes a mid-burst collection arithmetically impossible in every mode →
  loop-header re-entry stays sound untouched; failing exits pre-effect and
  tier-0 runs the boundary iterations. No continuation exits in v1 (that
  design is recorded as D3v2 with its codex-enumerated obligations #3/5/6/7).
- **Key review outcomes:** gc_stress legs never enter allocating traces
  (codex #1); observation blackout while suspension armed (codex #2);
  per-op IR nodes NOT an sbuiltin catch-all (codex #4: IrInstr can't encode
  variadic operands; ssub carries its 3rd ref in aux); full-write-set
  loop-close flush so post-burst regs ≡ tier-0 regs (codex #6 — physical
  root set, not liveness); CSE only for tostr_int/num (codex #8 — snew-class
  repeat calls are fallible); callout tagged-result error protocol with
  no-link-before-fallible-step proofs (codex #9); upper/lower OUT of v1
  (codex #10 — VM effect state); format chain demoted to next arc.
- **Planned wire ops (append-only, count 60→):** tostr_int=60, tostr_num=61,
  slen=62, guard_string=63, guard_gc=64 (aux=A), ssub=65, srev=66, schar1=67,
  srep2=68. RecordedBuiltin 11+: len=11, sub=12, reverse=13, char=14, rep=15,
  mtype=16 (lua54 fold-only ride-along).

**Implementation order (arc B commits):**
1. D7 first: alen pending-store flush refinement (scalar can't reach tostring
   without it) + rawset-then-len differential test.
2. mtype fold arm (trivial, clears the lua54 TODO entry).
3. tostr_int/tostr_num + slen/guard_string + guard_gc + .alloc optimizer kind
   + full-write-set flush + callout error protocol → scalar end-to-end.
   THE acceptance gate: §T-A.2-style cross-tier snapshot byte identity on an
   allocating loop + next_obj_id equality + pairs-order program in the matrix.
4. snew class (ssub/srev/schar1/srep2) → str_manip (minus upper/lower).
5. D9 adversarial matrix (codex #14 list), gates, board, commit.

Profile artifacts: scalar = 37.7% dispatch + foldable builtins, tostring the
one allocating call; str_format is only 8.6% dispatch (decimal core 40% —
separate arc); str_manip 22.9% dispatch + ~46% transform bodies.

## Status 2026-08-27 (LATEST-85) — **doc 23 arc A landed: builtin recording breadth (non-allocating). partialsums 6.9× → 2.0× LuaJIT (−79.3% instructions, 100% native iterations); `#t`/rawget/rawset/type/select/tonumber/rawequal loops now record. `pow` and int→float promotion turned out to be the hidden headline blockers.**

**What landed (doc 23, arc A — everything that records without guest-heap
allocation).** RecordedBuiltin ordinals 1–10 (append-only wire enum in
`guard_builtin` aux): fold arms `type`/`select('#')`/`tonumber`(konst)/
`rawequal`/`tostring`(konst)/`rawlen`(konst string) — read-only
`internedLookup`, abort on miss, NEVER intern (the no-allocation invariant,
pinned by strtab_count tests); index-shape extraction (Get/SetFrame +
OperandDesig .a1/.a2/.a3) shared by the opcode arms and call-shaped
`rawget`/`rawset` (statement-tolerant c∈{0,1}); `alen` (IrOp 57) for `#t` +
observed-table `rawlen` — fast-case border max(asize−1,0) under
`Lane.scalarPresenceLane()` (grid EXCLUDED: its bitmap is per-cell, `#t` is row
count — a comptime assert in the native lowering pins the lane range), guarded
producer, `.aload` alias discipline, aborts on pending sunk stores;
`fsin`/`fcos` (IrOp 58/59) through ONE `noinline` `fmath.sinRuntime`/
`cosRuntime` kernel every tier calls — cross-tier bit-identity by construction,
never constant-folded, no side-exit.

**The two blockers the design missed (both general, both landed):**
1. **Int args.** D4 scoped sin/cos/sqrt float-only ("tier-0 owns promotion") —
   but partialsums' `k` is an INTEGER (Lua 5.4 for-loop), so `sin(k)` aborted
   and the headline loop never recorded. Fix: pin the observed type
   (`guard_int`/`guard_float`) and promote int operands the way float binops
   already do (`@floatFromInt` ≡ `cvtsi2sd` in `floatOperandToXmm`). No new IR
   op; lifts `fsqrt` too.
2. **`pow`.** With recording fixed the trace still ran 0% — nativegen deferred
   `.pow`, the whole trace declined to tier-1a, and the gate correctly retired
   it (tier-1a ≈ tier-0 here; `--jit-debug` receipt: "native unsupported in
   proveKinds"). `pow` became the second user of the generalized body-callout:
   `arith.pow` → shared `noinline` `fmath.powRuntime` (software `std.math.pow`,
   strict FP), native calls the same kernel (xmm0/xmm1 → xmm0, mayGc=false).
   The callout save-area predicate is now `bodyCalloutOf(...) != null` — the
   SAME mapping the lowering and heap-φ GC audit dispatch on, so a new callout
   can never silently miss its save area. Save/restore extracted into shared
   `emitCalloutSave`/`emitCalloutRestore` (rax/rcx/xmm0/xmm1 deliberately
   untouched — results ride through the restore).

**Measured.** partialsums: 100% native iterations, 278 c/it vs 5340 tier-0,
wall 245→63.5 ms, instructions 4.469B→0.926B (**−79.3%**), board 6.9× → 2.0×
LuaJIT. rawget/rawset hot loop ~50 c/it native vs 6672 t0; `#t`/rawlen loop
14.1 c/it vs 10697. Instruction A/B vs HEAD shadow (`just shadow`, baseline
verified by nm): lua54 +0.0002%, nsieve +0.003%, str_find_match +0.2% — the
board's lua54 +7%/nsieve −19% wall deltas were noise, not code. Gates: full
suite + `-Djit-debug` leg green; hashgate 84/84 on BOTH legs (Debug jit-debug +
ReleaseFast); `just bench` 28/28 cross=ok, luajit ok; partialsums byte-identical
across t0/tier-1a/native AND vs LuaJIT.

**Post-arc abort inventory (`--dump-aborts` sweep — what's left, per row):**
scalar `bad_type` pc 67 (`tostring(i)` — arc B, stated up front, did not move:
28.5 ms t0-bound); lua54 `host_barrier` (`math.type` — TODO.md fold-arm note);
str_* `host_barrier` (string library — arc B); str_gmatch also `nyi_opcode len`
(non-konst string `#s` = cp_len needs a string guard — deliberately excluded,
codex #7: `#s` is code points, `rawlen` is bytes, never share an emission);
tbl_ops `new_table` nyi; binary-trees `cross_frame` (campaign item 3);
array3d/euler14 `get_index`/`for_prep` nyi (campaign item 4).

**Next:** arc B (deterministic on-trace allocation: `tostring(i)`, string
library — own design doc + codex review) or campaign item 2 (nbody heap-φ
writeback). Both need Bart's pick of worst general gap after this board.

## Status 2026-08-27 (LATEST-84) — **scalar's 41× and str_format's 20.5× were ONE bug: the string interner. Replaced the std hash map with an lj_str.c-shape chained stringtable. scalar 4.0×, str_format 3.2×, board median 5.6× → 5.3×.**

**Profile first, again.** Bart picked scalar (the worst row); the campaign map
said "ffrecord breadth". `perf` said otherwise: **89.4% of scalar's and 82.2%
of str_format's TOTAL runtime — both tiers — was `gc.Heap.internValue`.** The
map's attribution was wrong; corrected in the header above.

**Root cause.** `interned: std.StringHashMapUnmanaged(*String)` + GC sweep
`remove()` per dead string. Open addressing turns every remove into a
tombstone, and only a rehash reclaims them — the pinned stdlib's own doc
comment names this exact insert/delete pattern as the degradation case. Free
slots monotonically become tombstones, so every intern MISS (every new
`tostring(i)` / `string.format` result) probes enormous clusters. Isolated
harness (same map, intern-shaped churn): 124 ns/op without removes, **12,896**
with, 41 with rehash-after-sweep. In-tree probe (one rehash line in sweep):
scalar 251→25ms, str_format 563→95ms. Scaling is linear-with-huge-constant,
NOT quadratic (periodic grows bound it) — my first prediction was wrong,
measured before claiming.

**Fix (Bart's call: no band-aid, structural).** lj_str.c's shape:
`Heap.strtab` = power-of-2 bucket array chained through a new
`String.next_intern` field (weak edge — never traversed by blacken/snapshot).
Intern = stored-hash + len + memcmp down a ~1-length chain; miss allocates the
string (hash threaded via `createWithHash`, no double hash) and pushes at the
head — transactional, every fallible step before any mutation (codex).
Grow ×2 at 100% load. **Sweep REBUILDS the chains from survivors during the
existing walk** (codex's catch: per-dead unlink is O(k²) on an interleaved
live/dead bucket; the rebuild is O(buckets+objects) and rides the walk we
already do). Shrink = optional post-sweep maintenance, halve below 25%,
OOM keeps the current table — `beginCollect` stays a collection's only
fallible step. Lazy first allocation keeps `Heap.init` infallible.
No hash-flood hardening (explicit trust-model decision, recorded at the field;
recorded-seed is the future path). keyframeser restore: `internRestoredUnique`
preserves the DuplicateInternedString rejection exactly (test at
keyframeser_restore_test.zig:1234 still green untouched).

**Measured (instruction counts, ±0.01% across reps, vs a HEAD shadow):**
scalar t0 6.249B→0.617B (**10.1×**), str_format t0 13.92B→2.20B (**6.3×**),
fft-jit −0.03%, binary-trees t0 ±0.00005%, nsieve-jit −0.02% — zero cost where
strings don't churn. Board (quiet, 20260827-163810): scalar 41.0×→**4.0×**,
str_format 20.5×→**3.2×**, median 5.6×→**5.3×**, 28/28 cross=ok, luajit all ok.
(The 163235 board same rev is noisy — its LuaJIT column moved too; kept as
history, read 163810.) A wall-clock "fft +6%" scare was ambient load —
instruction counts killed it.

**Post-fix scalar profile:** 44.5% dispatch, 12.4% lenValue, 10.1% bType —
tier-0-bound on the untraceable builtin loop, which is the queued ffrecord arc
(campaign item 1): the loop still aborts `host_barrier` at its first `type()`
call. New worst rows: spectral-norm 29.4× (nyi_opcode for_prep/get_index —
different lever), array3d 28.1×, nbody 22.1×.

Gates: `just test` + `-Djit-debug=true` OK, hashgate 84/84 both legs, bench
28/28. New tests: bucket-collision interleaved live/dead sweep, grow-past-min
pointer stability, mass-death shrink to min, churn stress, embedded-NUL/empty,
chain-integrity checker.

## Status 2026-08-27 (LATEST-83) — **the native path's dead executor-frame push is now lazy: LATEST-82's residual cost repaid with interest (fft-native −0.52%, lu-native −0.43% by instruction count).**

The LATEST-82 follow-up, done. `enterSelectedTrace` pushed the tier-1a executor
frame unconditionally, but every `buf` consumer (executor, exec-log,
`.ir_numeric_for_done`) is off the successful-native road — native paid the most
while using it least. Now: push only when `native_page == null` (covers exec-log,
which forces the page null); release deferred on a `buf_live` flag; the one
native road back to the executor — the seed-hash-decline tier-1a rerun — takes a
fresh mark and re-pushes at its own site (fresh is correct: the burst machinery's
pushes above it are all released by then).

**Measured (3 reps, medians, `perf stat -e instructions:u`; base = 31ff9db built
in a `just shadow` copy with `src/interp.zig` restored from HEAD, grep-verified):**
fft-native −0.523% (spread 0.02/0.06%), lu-native −0.433% (0.38/0.20%), fft
tier-1a −0.088% (within its 0.26–0.28% spread → unchanged), tier-0 +0.000%,
nsieve-native −0.002%. Better than LATEST-82's +0.43/+0.59 cost because the lazy
path also skips the mark, not just push/release.

**Verified beyond the gates:** outputs byte-identical old-vs-new across t0 /
`--trace` / `--jit-native` on fft, lu, nsieve (scimark run from `bench/luajit/`
cwd — the first equivalence sweep silently compared module-not-found error text,
caught by ~650k-instruction counts where billions were expected); `--jit-stats`
byte-identical (same JIT behaviour). The decline-site re-push is exercised by the
B-v decline-determinism e2e test and is load-bearing: mutating the re-push away
crashes exactly the two hash-drift tests on the executor entry assert.

Gates: `just test` + `-Djit-debug=true` OK, `just hashgate` 84/84 on both legs,
`just bench` 28/28 cross=ok (board 20260827-082328-31ff9db.tsv; lua54's
`luajit=skip` is its permanent state, not a regression).

## Status 2026-08-26 (LATEST-82) — **the two `driveChain` panics were ONE bug: a use-after-free of the tier-1a executor scratch. Fixed with a segmented scratch stack; the gate gains a safety-checked leg. Board neutral except where trace entries dominate.**

**Root cause, proven not inferred.** `TraceState.values_scratch` was one flat
growable `ArrayListUnmanaged(Value)`, but trace execution nests:
`enterSelectedTrace` holds a frame across `driveChain` (it IS the
`.ir_numeric_for_done` payload) while the candidate walk takes one of its own. A
candidate longer than the entering trace `resize`d the buffer, it moved, and the
dispatcher's slice dangled. Instrumented both reproducers and caught the move
directly — nsieve-bit `38 → 59` slots, `ptr …d0f0 → …6b70`; scimark-sparse
`44 → 57`, `…e010 → …7950`. One fault, both symptoms: the flush reads the freed
block, so `values[ar.a].asHeap()` trips the tag assert on one program and
`regs.set(p.aux, values[p.b])` writes a garbage tag byte that the next
`regs.get` decodes as an invalid enum on the other. Pre-reserving so the buffer
cannot move makes both panics vanish and both programs agree with tier-0 and
LuaJIT — causal chain closed end to end.

**Two corrections to LATEST-81's TODO entry.** The hypothesis there ("the flush
walks store instructions past the live prefix") is wrong: the flush is correct,
its memory is gone. And it is not Debug-only UB — **the buffer moves in
ReleaseFast too**. Release printed the right answer only because the process
allocator neither scrubs a freed block nor had reused it yet. Stale-correct
bytes, not benign garbage.

**Fix (Bart's pick of three).** A segmented scratch stack: `values_chunks` +
`valuesMark`/`valuesPush`/`valuesRelease`. Chunks are independent allocations so
growth never moves a live frame; frames release LIFO, which is what makes a
chunk at or above the cursor provably dead and therefore safe to reallocate when
an oversized frame needs it. A frame larger than a chunk gets its own chunk, so
nothing straddles and no invariant depends on `config.maxrecord`. Same
discipline `interp.zig`'s register stack and `boundary_scratch` already document.

**A design bug of my own, found by profiling and worth recording.** The mark
first stored the free *slice*. That is wrong at the base: the first mark of a
session predates chunk 0, so releasing to it left `values_free` empty even
though chunk 0 was allocated and idle — every push then missed the fast path,
the cold chunk-acquiring path ran once per trace entry, and the stack
ping-ponged between two chunks forever. Cost 0.65% of scimark-fft, visible only
because `valuesPushNewChunk` showed up in an instruction-event profile where it
had no business being. The mark stores an offset now; a test pins 64 base-state
mark/push/release cycles to exactly one chunk and one address.

**Measured (instructions retired, not wall-clock — wall noise here is ±2%).**
The discipline costs ~10–55 instructions per trace entry:

| program (`--jit-native`) | entries | Δ instructions |
|---|---|---|
| nsieve | 825 | +0.002% |
| nsieve-bit | — | +0.001% |
| scimark-sparse | — | +0.007% |
| nbody | 1.0M | +0.021% |
| scimark-sor | 3.5k | +0.161% |
| scimark-fft | 1.0M | +0.434% |
| scimark-lu | 2.5M | +0.589% |

Sanity check that the number means what it says: tier-0, which never touches the
scratch, is **0.000%**, and tier-1a fft — which touches it hardest — is +0.102%,
i.e. *less* than native fft. That inversion is the whole reason the follow-up in
TODO.md is "stop pushing a frame the native path never uses" rather than "make
the stack cheaper."

**Gate.** `just test` + `-Djit-debug=true` green. `just hashgate` 84/84 on BOTH
legs — the second one new: `--also-mahina` runs the identical corpus under a
safety-checked Debug build, since the gate had only ever seen ReleaseFast and
that is precisely why these two bugs survived. Proven load-bearing: with the fix
reverted the release leg passes 6/6 on the affected programs while the Debug leg
reports the abort. `just bench` 28/28 `cross=ok`, LuaJIT parity throughout.

**Tests, mutation-verified.** Three new pins in `trace_chain_test.zig` (nested
oversized push, base-state cycle reuse, and the real `driveChain
.ir_numeric_for_done` shape with a candidate longer than the caller's frame).
Reverting `valuesPush` to HEAD's exact body fails **exactly** those three and
nothing else — which is also the honest answer to "why did no existing test
catch this." Worth noting separately: an *exact-fit* realloc mutation (rather
than HEAD's geometric `ArrayList` growth) additionally breaks six pre-existing
`interp_semantics`/`interp_tier1a` tests, so the same defect was one allocation
policy away from firing much more widely than the two programs that showed it.

## Status 2026-08-25 (LATEST-81) — **the two follow-up commits from the Phase C unwind: three salvaged provenance wins, then three behaviour bugs + dead code. Board neutral; two of the three bugs turn out to be latent, not hot — recorded below because the original estimates said otherwise.**

**Commit d0d844e — salvaged provenance wins (perf).** Three mechanical
improvements found inside the Phase C diff that were never region policy, so
they survive the revert independently. Profiled at that revision rather than
inherited on faith: on scimark-lu `memcpyFast` was 4.04% with 3.94% reached
through `captureNativeCallProvenance`. (1) caller-owned capture storage kills a
776-byte aggregate-return memcpy on every native entry; (2)
`provenanceEdgeVerdict` replaces an O(rows²) ledger-tail rescan with a single
backward suffix-cum-max walk; (3) an `armed_links.items.len == 0` bypass — the
conservative form, chosen over Phase C's maintained `armed_sibling_total`
counter because it cannot under-count and skip a live edge.

**Commit — three behaviour bugs + dead code (correctness).**

1. **A seeded decline struck the wrong trace.** `replayLedger`'s terminal
   seed-decline routed the `ends_link` case to `.break_burst`, whose consumers
   end in `onSideExit(seed, 0)` — a zero-progress strike on the burst SEED,
   which in a `C1 → I → C2` span is not the decliner. Same bug at
   `driveBurstCore`'s tier-1a call-A seeding seam, where a bare `break` fell
   into the same tail. Both now return penalty-neutral.
   **This one is a determinism improvement, not just a cleanup:** the NATIVE
   twin of the call-A site already returned chargeless, so `record_execute` and
   `record_execute_native` were recording *different penalties from the same
   decline event* and could make different tiering decisions. The tail's own
   comment claims "Mode-invariant: … no mode records a different penalty here";
   it wasn't true. Invisible to the stdout oracle, which is why it survived.
   Scope, measured rather than assumed: live on hop 0 only (later hops carry
   `linked_completed >= 1`, so the tail already returned neutral) — but hop 0 is
   the common case, since a burst whose inner can't be seeded declines on its
   first hop every time. The tier-1a **call-B** seam got the same treatment and
   is explicitly documented as hardening, NOT a fix: `start_at_continuation` is
   set at four sites, all `.native_only`, so `linked_completed >= 1` was
   guaranteed there and the old `break` was already neutral by a non-local
   accident.
2. **The provenance drain could never settle.** `drainProvenanceArms` charged a
   failed `publishSiblingArm` to one "transient, retry later" flag. Since
   B-iv.3 that failure includes a seeded child whose anchor proto isn't the live
   episode's — and `provenance_edges` is global across protos, so one long-lived
   cross-proto edge re-latched the flag on every pass and the gate could never
   close. The gate exists because the scan it guards was 5.7% of nsieve-bit
   wall. Fixed by splitting `stubEnterable` into a three-state
   `stubEnterability` (`.ok` / permanent / `.no_episode`) and giving the
   episode case its own flag, stamped with the episode identity it is waiting
   past — so the edge is deferred, not silently dropped.
3. **`validateRegionBridge`'s transient decline had no memo and no bound.** The
   caller memoized only the already-armed case, so a durably non-enterable child
   re-ran the whole arm pipeline on every terminal composite deopt, forever.
   Now memoized on `(exit, defs_gen, call_seq)`, which re-opens on a discovery
   rebuild or a new activation. `validateRegionBridge` also returns a
   three-way verdict so "structurally disproved, region tombstoned" stops being
   spelled the same as "proof held, page not enterable".

**Honest measurement — two of these are latent, not hot.** The A/B vs d0d844e
is neutral across all seven hot programs (−1.6% … +0.8%, i.e. noise), and a
suite-wide sweep with the bug-3 memo compiled out shows the memo **never fires
on any of the 28 benchmarks** (identical attempt counts everywhere; only
nsieve/nsieve-bit/sieve_int run the bridge pipeline at all, at 32/32/28 attempts
total). The original report's "2.4% of nsieve N=5" was the cost of
`validateRegionBridge` *when the pipeline runs*, and the pipeline runs a few
dozen times per program — not per composite deopt as implied. Bugs 2 and 3 are
therefore fixes to unbounded-work paths that this suite does not exercise; they
are worth having because the bound is what stops a future workload from falling
off a cliff, but they bought nothing measurable here and should not be cited as
if they did. Bug 1 is a correctness/determinism fix with no perf claim.

**Dead code deleted** (each verified unreachable, not merely unused): the
release `@panic` in `nativegen.zig` whose condition was the exact negation of
`computeSeedPlan`'s activation condition over the same pure predicate and args
(unsatisfiable — replaced with a real `runtime_safety` assert over
`entry_slots`, plus a `seed_plan.nonEmpty() == seed_prologue` assert at the
`CompiledTrace` construction site); `stubEnterable`'s "two independent
witnesses" panic (one fact, not two); the `.seed_trace_inputs` `BodyCallout`
row (never returned by `bodyCalloutOf`, so `calloutMayGc` never consulted it —
the audit moved into the enum's header as an explicit exclusion). Stale
comments fixed: `interp.zig`'s claim that `driveChain` only enters zero-input
traces (false since B-iii/B-iv — `findLinkTrace` admits seeded continuations;
the `regs` argument is still right, for a different reason, now stated), and
`validateRegionBridge`'s "region invalidated" on a path that invalidated
nothing.

**Tests.** Four new pins, each **mutation-tested** (revert the fix → that test
and only that test fails): a directive-level `replayLedger` assertion (the
existing dispatcher-level test reaches the same end state via `.break_burst` +
the tail, so it structurally cannot see the directive); a `runLinkedBurst`
driver-level test that observes the tier-1a charge; a foreign-episode drain
test asserting the general flag settles while the episode flag defers, then
that the deferred edge arms when the episode changes; and a
`native_region_bridge_arm_attempts` counter proving one pipeline run instead of
two, re-opening on both `defs_gen` and activation. Coverage gap stated rather
than papered over: the tier-1a call-B seam has no test, because on `.ir` it is
unreachable with `linked_completed == 0` — see the fix's own comment.

**Gate.** `just test` + `-Djit-debug=true` green; `tools/hashgate.py` 84/84;
`just bench` 28/28 `cross=ok`, LuaJIT parity ok throughout.

## Status 2026-08-25 (LATEST-80) — **doc 22 Phase C REVERTED in full (Bart's call). The region data model is extracted into leaf modules; the board is back at post-B. C.5b dropped too — its justification did not survive re-measurement.**

Bart's mandate: "keep the extraction, remove the graduation, remove everything
that is a liability rather than an asset."

**Why Phase C went.** C.1's owner election made nest regions armable that were
owner-ambiguous before — which is what it was for, but armable ⇒ `openRegion`
per activation ⇒ a per-activation open→account→close lifecycle post-B never
paid for. nbody went from 84.7% of cycles on native trace code to **0.1%**
(199,844 of 199,921 loop entries "tier-0, has-trace"). Nine successive
mechanisms (C.4, C.5, C.5a/b, C.5c1–c5) were built to claw it back and the
final state was still lu +16.8% / spectral +13.5% / grid +4.6% / nbody ~+3%.
**lu began the cascade at +16.6% and ended at +16.8%.** Rule Z-7's exact
pattern. Full board + reasoning recorded in doc 22 §"Phase C" (kept as a
negative result, with a banner so nobody mistakes it for current design).

The deeper diagnosis (the other agent's, and it is right): graduation/leases
are not a Pall mechanism. Trace trees, side traces, hot-exit counters, loop
recording, snapshots and direct linking are LuaJIT. Persistent `RegionDef`s,
per-receipt source/destination classification, `RegionAccum` windows, dormancy,
memos, graduation and leases are ours. LuaJIT does not run
classify→choose→lookup→classify→update per successful receipt — it patches the
exit and stops thinking. We copied the trace shape, not the steady-state cost
model, then built a cache hierarchy over the cost model we should not have had.

**What landed (this commit).**
- `src/trace_types.zig` (326 lines) — trace-graph identities, moved verbatim
  with their doc comments: `CallEdge`/`GuardRole`/`GuardProvenance`/
  `ExitProvenance`/`StructuralEdgeId`/`AnchorKey`/`MAX_INLINE_DEPTH` + the
  field-wise order/hash helpers. Leaf module: `std` + `bytecode.Proto` only.
- `src/trace_region.zig` (388 lines) — the region DATA MODEL, moved verbatim:
  `RegionId`/`Key`/`Accum`/`Destination`/`Context`/`Classifier`/`BridgeDef`/
  `Def`/`InternMap`, the observer caches, the set builders.
- `trace.zig` 14,147 → 13,520 lines, with a re-export block so every existing
  `trace.X` spelling still resolves. Behaviour-free by construction.

**Scope correction worth knowing.** "Keep the extraction" could not mean the
working tree's 2,839-line module. That module had no `*TraceState` parameter
*because Phase C restructured the interaction into classify/decide/apply* —
the decoupling was itself a Phase C artifact. At post-B the region policy
methods reach straight into `penalty`, `gate`, `promoted_sets`, `gateAnchor`,
`condemnProvenanceEdgesAt`, `disarmAllLinks`: the region layer IS the tiering
policy layer and there is no seam to cut along without changing behaviour. So
the state-free data model came out (a pure move, checkable) and the ~25 policy
methods stayed on `TraceState`, which is where they honestly belong today.

**C.5b dropped as well.** Its recorded justification was "sor 8,006 mprotects
→ 0, 0.085s → 0.070s". Re-measured against post-B: **6 mprotect calls across
the entire 28-program suite**, and best-of-9 wall-clock is noise (sor +1.2%,
lu −1.4%, nbody +1.2%, fft −2.9%, spectral +0.1%). The 8,006 was an artifact
of Phase C's own arm/disarm churn. It is 141 lines of memfd/dual-map plus a
rarely-exercised SELinux/seccomp fallback, and it defeats W^X by keeping a
permanently-RW alias of executable memory — not worth carrying for 6 syscalls.
Archived; re-appliable in one command if exit-branch patching ever makes patch
frequency real.

**Gate.** `just test` + `-Djit-debug=true` green; `tools/hashgate.py` 84/84
digests match the post-B references; `just bench` 28/28 `cross=ok`, LuaJIT
parity ok throughout; best-of-9 A/B vs a verified `just shadow` post-B binary
neutral-to-better on all five hot programs (sor +0.3%, lu −1.3%, nbody −1.6%,
fft −3.3%, spectral −0.2%).

**Everything Phase C is archived** at `~/mahina-phasec-archive/` (full tree copy
+ `phaseC-tracked.patch` + the untracked modules + the commit-4 bug design).
Nothing was lost; it is simply not in the tree.

**Follow-ups from this arc landed as their own commits — see LATEST-81.**

**Also landed just before this:** `tools/hashgate.py` + `bench/refs/` — the
"six-hash gate" cited by ~15 commit messages only ever existed in `/tmp` and
was lost to a disk cleanup. Rebuilt in-repo, 28 programs × 3 modes. It exposed
a real hole: array3d and the four scimark kernels print **nothing**, so their
digest is sha256("") and `bench/run.py`'s `cross=ok` is comparing "" == "" ==
"" for them. Three of those five (fft, lu, sor) are the float kernels the JIT
leans on hardest. Closing it means giving the kernels a deterministic checksum,
which touches LuaJIT-vendored files and must keep byte-parity with LuaJIT's own
run — flagged to Bart, not done drive-by.

## Status 2026-08-20 (LATEST-76) — **Doc 22 Phase B COMPLETE (B-iv gate flip + B-v test battery + measurement): seeded traces now enter native at EVERY seam, and nbody drops 40.4× → 21.9× LuaJIT (180.5 → 99.4 ms, −45%).**

- B-iv.1/2/3 (34ebb88, 62312df, 0adc9ef): `stubEnterable` replaced every
  `inputs.len != 0` hard-decline at the ~15 chain/link/arm/replay seams;
  fused declines drain through the two new ledger kinds. Deviations recorded
  in doc 22 (conditional fused-successor asserts; transient
  validateRegionBridge decline).
- B-v (d2a51c6): full §B.6 matrix — 3 e2e tests w/ inspect witnesses
  (seeds_at_entry invariant `seed_plan.nonEmpty() == seed_prologue` per
  compiled trace; hash-drift decline fires in production `nativeSeedFn`),
  redundant-seed run test (plan-inactive slab slot bit-for-bit unwritten) +
  compileImpl release-assert, fused terminal-decline placement pin.
  **Grant semantics pinned:** `.loop_done_linked` grants
  `linked_completed += 1` per row (one committed outer iteration); the
  ledger `cum` feeds only region accounting; a terminal seed-decline returns
  the accumulated grant (completed==1 in the 3-row pin), resume at the
  decliner's own anchor. Diagnostic `seed_hash_declines` /
  `seed_capacity_declines` counters at all five decline drain seams.
- Measurement (A/B vs `just shadow` at a468fa2, strings-verified baseline):
  advance:132 records, 3/3 traces compile native, runs fused via loopdone
  links (79,975 fused follows; arms native=1 loopdone=1). nbody 40.4× →
  21.9×; pi_leibniz −13%; scimark-sor −6%; rest of 28-board noise, 28/28
  cross=ok, no regressions. Remaining nbody gap is coverage elsewhere:
  advance:4 (8.8% run, 0% traced), main:211 (13.3%), tier-0 no-trace 22.4%
  of run + seam 9.0% — Phase C (owner election) + later arcs.
- NEXT: doc 22 Phase C — canonical owner election by physical region
  membership + C.2 gates_cleared latch; then Phase D full-board measurement.

## Status 2026-08-20 (LATEST-75) — **Doc 22 Phase B-iii (tier-1a chain seeding, §B.3) LANDED: driveChain's chain seams now seed InputSeed-carrying successors and run them on tier-1a. The NATIVE walk stays input-free-gated until B-iv.**

- The twin: `NativeSeedCtx.seed_tier1a_fn` (trace.zig, optional field after
  `seed_fn`; plain Zig fn ptr — chain seams aren't JIT code, nothing baked)
  → interp.zig `nativeSeedTier1aFn`, installed at Vm.initBare beside the
  C-ABI twin. It delegates to `seedTraceInputs(ct, ctx.base, closure, proto,
  RegWindow.empty, &native_eligible)` — byte-identical resolution+validation
  to a dispatcher entry, FULL input set (the C-ABI plan twin can't serve:
  `SeedPlan.bits` carries only ACTIVE seeds, tier-1a slot_loads read every
  synthetic slot). Mapping: null window → SEED_CAPACITY_DECLINE;
  `native_eligible=false` → SEED_HASH_DECLINE (the 0-bits slot IS written,
  like the dispatcher); else SEED_OK. Returned widened window discarded —
  chain seams execute with the caller's window; synthetic slots live in dead
  scratch above the frame the capacity check bounded, RegWindow accessors
  are unbounded pointer offsets into the same slab.
- The gate: `TraceState.seedForTier1a(t, proto)` (trace.zig:5088) —
  inputs-free short-circuits true; missing ctx/twin fails CLOSED (pre-B-iii
  skip; hand-built test TraceStates); asserts `ctx.proto == proto`
  (freshness — every seam runs right after `prepareNativeEpisode`); returns
  `rc != SEED_CAPACITY_DECLINE` (hash-decline RUNS: tier-1a `href`
  re-derives cells from operands and side-exits at the same guard — the old
  dispatcher `native_eligible=false` downgrade).
- Three seams converted from hard `inputs.len != 0` skips (tier-split: the
  NATIVE walk still requires input-free until B-iv stubEnterable):
  driveChain side-walk (:5212, ordered AFTER the shape filters so a
  filtered-out candidate is never spuriously seeded), driveBurstCore
  link-follow inner gate, and the burst re-entry before every tier-1a
  `irinterp.execute` of `current_link` — per-entry re-resolution is the
  contract; a burst hop is one more entry (seeds are loop-invariant only
  over the trace's own region).
- §B.6 chained hash-drift pin (trace_chain_test.zig): stub twin smuggled
  via `ctx.vm` writes the seeded slot into the SAME lanes the chain window
  views, then scripts the disposition. (1) no ctx → fail closed, twin never
  consulted; (2) SEED_HASH_DECLINE → chains, completed=1, r0=2 — both only
  reachable through the seeded increment, proving the write precedes
  execute; (3) SEED_CAPACITY_DECLINE → declined, null.
- Gate battery green: `zig build test`, `-Djit-debug=true`, six-hash × both
  tiers, repros 109/109/18135, `just bench` 28/28 cross=ok. Board unchanged
  (expected — seeded successors still can't ARM native links until B-iv;
  nbody 39.9× jit).
- NEXT: B-iv stubEnterable + ~15-site audit (§B.5; replaces the B-ii
  replayLedger fused-decline panic with the §B.2 fused directive) → B-v
  §B.6 remainder (redundant-seed, fused-decline) + A/B measurement (nbody
  advance:132 native, link arms > 0) → Phase C.

## Status 2026-08-20 (LATEST-74) — **Doc 22 Phase B-i (inert seed substrate) + B-ii (prologue seeding + the DIRECT-entry decline flip) LANDED. Seeded traces (InputSeed-carrying, e.g. nbody advance:34's `local sqrt = math.sqrt` upvalue) now run NATIVE on direct entry. Fused entries stay gated until B-iv.**

- B-i (inert, committed f037529): `NativeSeedCtx` (trace.zig:1524; SEED_OK=1
  / SEED_HASH_DECLINE=2 / SEED_CAPACITY_DECLINE=3; fields vm/closure/base/
  reg_capacity/proto/call_seq/seed_fn) heap-allocated by `Vm.initBare`
  [recorded deviation: not owned inline by TraceState — stable address is
  what matters for imm64 baking; `proto: ?*const anyopaque = null` until
  B-iii needs it]; per-episode refresh in `prepareNativeEpisode`
  (interp.zig:1047); `SeedPlan` derived at compile; `compileSeeded`/
  `compileInto(…, seed_ctx)` plumbing; exit reasons + ledger kinds
  `seed_hash_decline`/`seed_capacity_decline` (irinterp.zig).
- B-ii (the flip): nativegen `lower()` emits a prologue at body_entry iff
  `plan.nonEmpty()`: push rdi/rsi/rdx → imm64 ctx/t/plan.bits → callReg rax
  → pops → fail-closed tri-state (`cmp SEED_OK; je body; cmp
  SEED_HASH_DECLINE; je hash_exit; jmp cap_exit` — ANY garbage return =
  capacity). [Recorded deviation: plan crosses the ABI as `plan_bits: u64`
  BY VALUE — CompiledTrace is returned by value so `&ct.seed_plan` can't be
  baked; t/ctx are stable.] Decline exits: completed=rbx(=0), exit_instr=-1,
  reason stored BEFORE emitLedgerAppend, then emitReturn. `nativeSeedFn`
  (interp.zig:996): active-seeds-only capacity check; hash_cell resolution
  writes the cell ptr (0-bits slot on miss → hash-decline). Dispatcher
  (enterSelectedTrace): native entries pass the NARROW regs;
  `seed_capacity_decline` → no-strike `.next_candidate`;
  `seed_hash_decline` → VM `seedTraceInputs` + tier-1a rerun feeding the
  FULL ordinary grammar with ran_native=false (byte-identical to the
  pre-flip H1 route). Fused declines statically impossible until B-iv →
  loud `replayLedger` panic; both kinds inert for region work (0) and
  rowPatchKind (null). `compileImpl` fails closed on non-empty plan + null
  ctx.
- Tests (nativegen_carriedheap_test.zig §B-ii): SEED_OK — seed_fn called
  exactly once, plan_bits==ct.seed_plan.bits, native bit-matches the
  tier-1a oracle on all semantic slots (H1 bounded loop: guard_table → href
  STATIC→seeded slot → guard_hash count==1 → hload int); SEED_HASH_DECLINE
  and SEED_CAPACITY_DECLINE — terminal before the body: completed==0,
  exit_instr==maxInt(u32), ledger_len==1 with the right kind, ALL lanes
  byte-untouched; fail-closed pin: seed_fn returning 77 routes to the
  capacity exit. B-i plan-inspection pins updated to `compileSeeded` with a
  dummy ctx (compile() now fails closed on seeded plans).
- Gotcha pinned in tests: irinterp `href` stores nil and `hload` resolves
  via `tbl.get` from operands — the tier-1a oracle NEVER reads the seeded
  slab slot, so the SEED_OK comparison excludes the scratch slot itself.
- Gate battery green: `zig build test` (949), `-Djit-debug=true`, six-hash
  × both tiers, repros 109/109/18135, `just bench` 28/28 cross=ok. Board:
  field_hash 1.7×, nsieve 1.2×✓, sieve_int 1.2×✓ — no regressions; nbody
  still 38.9× as expected (advance:132 bridge needs B-iii/B-iv arming).
- NEXT: B-iii driveChain tier-1a seeding (§B.3) → B-iv stubEnterable +
  ~15-site audit (§B.5, replaces the fused-decline panic) → B-v §B.6 tests
  + A/B measurement (nbody advance:132 native, link arms > 0) → Phase C.

## Status 2026-08-20 (LATEST-72) — **Arc 2 grounded + design written (doc 22, `docs/design/22-pall-shape-nest-coverage.md`): the LATEST-71 "root-recording LINNER linkage" framing was WRONG — LuaJIT also LINNER-aborts a root at an interpreted inner loop; the side-trace tree ALREADY EXISTS on nbody and three general backend gaps keep it from running.**

- Evidence (nbody, --jit-debug + --dump-native + --dump-traces at 3bcc337):
  advance:34 (inner j-loop root, `.loop`) compiles native, 17149 B;
  advance:132 (outer-body bridge, `.link -> 34` — Pall's side trace exactly)
  records but is `unsupported`; region machinery mints the {34,132} cycle
  (`kind=cross_trace_cycle members=2`) but `armable=false owner_unique=false`;
  all anchors legacy-strike-gate (completed=0 → windows 256→8192); run is
  0.6% traced / 50.1% tier-0-with-fallback.
- The three general blockers (doc 22 phases): **A** proveKinds rejects `.heap`
  φ writebacks (nativegen.zig:2009) while `.ptr` already boxes TAG_HEAP —
  kills any array-of-objects continuation (132's `%122 phi update=%72` is the
  per-iteration bodies[i] table); **B** ~15 `inputs.len != 0` sites in
  trace.zig lock any InputSeed-carrying trace (34 has ONE upvalue seed:
  `local sqrt = math.sqrt`) out of links/regions/arming — fix = native
  prologue seeding + driveChain seedTraceInputs + audited gate relaxation
  (site table in doc 22 §B.4); **C** closed cycle entered at an inner root
  elects no owner (no ext edge, no enclosing member — outer root correctly
  never traces) — extend A-vii-d.1 with cycle-entry election.
- Doc 16's corrected verdict is the reason C matters: tier-1a/driveChain
  chaining is NEUTRAL on 1–4-trip clusters (nbody n=5); only the frozen
  native↔native patched cycle (B-3) pays.
- Sequencing A → B → C, each gated + measured vs `just shadow` baseline.
- Doc 22 APPROVED by codex (round 5, thread 01a01ae1-bba9-7be2-a197-fc093d179c24).
- NEXT: implement Phase B (seeded-trace seams, doc 22 §B) → C → D.

## Status 2026-08-20 (LATEST-73) — **Doc 22 Phase A LANDED: carried-heap slot class (heap φ writeback) in nativegen.zig + §A.3 test matrix. Wall-clock neutral as designed — the payoff ships with B (seams) + C (owner election).**

- nativegen.zig: carried-heap classification (`class=.carried, kind=.heap`
  when load kind `.ptr` ∧ store kind ∈ {`.ptr`,`.heap`}); Pass-C admits
  `.heap` φ.b; `flushSlot` + entry-tag switch grew `.heap → TAG_HEAP` arms;
  guard_table/href/guard_hash lowering keys on `isDynTableRoot` (per-iteration
  `.heap` value OR carried-heap root) → in-body dynamic guard_table +
  guard_hash + `resolveHashCell` callout, seed `aux` ignored (option (b):
  seedTraceInputs still redundantly seeds; a seed-validation failure only
  declines native entry → tier-1a, never misexecutes); fail-closed structural
  bails (aref/garow/guard_lane/guard_grid/guard_stride rooted at a carried-heap
  slot; pre-marker placement of the dynamic forms); §A.2 HelperCaps table
  (BodyCallout enum, `calloutMayGc`, heap-φ admission refuses GC-capable
  callouts — resolve_hash_cell is the only row, non-allocating).
- [Rule #0.5] PRE-EXISTING BUG fixed: the `last_body_guard` coalescing
  inventory was a hand-kept op list missing SIX mid-body exit classes
  (dynamic guard_table, href callout miss, dynamic guard_hash, VALUE_LANE
  aload tag check, guard_gcol, guard_gpresent) — a coalesced in-place φ
  update ordered before any of them committed early on that exit. Replaced
  with `opMayExitInBody` (single predicate, doc 22 §A.1b).
- Tests: `src/nativegen_carriedheap_test.zig` (registered in nativegen.zig's
  test block): carried-heap read loop expectMatch ×4 entry states (incl.
  entry-tag-mismatch decline + mid-loop TAG_HEAP flush) + frameless variant;
  dual-universe hstore-through-carried-root (field-by-field + corresponding-
  element pointer check); Rule-0.5 coalescing pin; fail-closed array-op bail.
  BOTH pins mutation-verified (reverting each guard makes exactly that test
  fail: "expected 4, found 5" / bail-test compiles).
- Gate battery green: `just test`, `zig build test -Djit-debug=true`,
  six-hash × both tiers, three repros (109/109/18135), `just bench` 28/28
  cross=ok, board within noise (nbody 40.7× ≈ baseline — expected: in a live
  run the advance:132 bridge is never recorded/entered, link arms=0, until
  Phase B seeds the seams).
- NEXT: Phase B — seeded-trace seams (NativeSeedCtx, prologue seeding
  tri-state, SEED_DECLINE exit + ledger row, driveChain seeding callback,
  audited `inputs.len != 0` relaxation behind `stubEnterable`, §B.4/§B.5).

## Status 2026-08-20 (LATEST-71) — **Arc 1 (hash-cell alias classification, doc 08 §2026-08-20) LANDED: `recHashGet` classifies pending stores instead of blanket-aborting. nbody's recording blocker is gone; wall-clock unchanged as predicted — the win ships with the root-LINNER arc.**

- H1: `forwardPendingHashLoad` (trace.zig, before the guard_table emit in
  `recHashGet`): newest→oldest walk of `pending_stores`; `.astore` → NO
  (airtight: only in-bounds astores buffer, astore_append is inline-only);
  different key konst → NO (interning + konst dedup ⇒ konst-ref equality is
  exact key identity — numeric keys never reach the hash recorders, dispatch
  routes them to the array path); same key + same table SSA ref → MUST
  (forward `ps.value`; the store side already emitted
  guard_table/href/guard_hash/guardNum on the same refs, so NO chain is
  re-emitted); same key + different table refs → MAY, abort `.bad_type`
  fail-closed (never guard a runtime identity relation).
- H2: 10 new tests in `interp_trace_test.zig` ("hash alias" family) — 5
  recorder/structural: NO different-key (2 hloads + 2 hstores), MUST
  last-writer-wins (exactly 1 hload, 2 hstores, order pinned), MAY two-refs
  abort, astore-vs-hload NO, and (codex round 3) every sunk hstore's VALUE
  ref carries its own guard_int/guard_float — the raw-IR pin an e2e can't
  detect losing; 5 `expectProgram` e2e (every GC×trace-mode leg):
  nbody-shaped multi-field RMW; cell type drift side-exits cleanly;
  side exit after a NO-read flushes the deferred store exactly once;
  (codex round 2) executable same-cell double-store last-writer-wins;
  store-VALUE type drift with the cell still int at entry.
- H3 gates: `just test` + `-Djit-debug` green; six-hash gate PASS (all six
  jit≡t0≡frozen); repros 109/109/18135; board 28/28 cross=ok, no
  regressions (sieve_int 1.1×✓, nsieve 1.2×✓).
- nbody diagnosis (jit-stats, N=1000): inner j-loop advance:34 now records
  AND compiles, but runs ~1 iter/native-entry (n=5 bodies → trips 1–4), so
  traced time is 0.6%; advance:4 root recording still aborts `.nyi_opcode
  for_prep` at the inner header (`recForPrepLink` `.root` restriction).
  **Next arc: root-recording LINNER linkage** — that's mechanism (2) and it
  gates nbody, sparse, euler14, and the matmul outers.

## Status 2026-08-16 (LATEST-70) — **"Make fft_bitreverse traceable": recorder gaps CLOSED (codex, 3 rounds), coverage deliberately deferred to exit-branch stitching. LANDED `0e311f9` (Bart: commit as-is; fft jit +3% ≈ noise floor accepted).**

- Codex thread `01a007bf-34be-7f13-9f89-601103c003d8`, three rounds under
  Claude verification. GROUNDING CORRECTIONS to LATEST-69's verdict: (a) the
  `:55 bad_type get_index` abort was the doc-08 post-deferred-store load
  prohibition (the recording crossed the swap's 4 sunk stores into the next
  read), NOT key narrowing — `guard_float + int_of_float` was already
  emitted; (b) `:9` DID commit a trace — native `proveKinds` rejected its
  exact mixed int/float compare, the native-only gate backed the anchor off,
  and `--dump-aborts` was silent because native-unsupported is not a
  recorder abort.
- Landed general mechanisms (all enabling, Z-6-clean): static virtual-store
  forwarding (LuaJIT `aa_ahref` model: SSA affine base+const keys, MUST
  forwards / NO skips / MAY aborts fail-closed; NO runtime key-relation
  guards; `MAX_PENDING_STORES` cap removed, allocator-backed buffer); exact
  mixed int/float compare narrowing (`.operand_int` int_of_float on
  integral floats); write-only table-pointer φs boxed TAG_HEAP in native
  (lifts a whole proveKinds rejection class — the :9 trace now compiles);
  CFG-cycle recording closure (`maybeCloseAtAnchor`); jitdbg probes for
  commit-fail + native-unsupported.
- ROUND-2 EXPERIMENT REJECTED ON MY BOARD MEASUREMENT (recorded in doc 20):
  exempting zero-progress guard exits from legacy strikes + tree/walk bounds
  4/8→32 made bitreverse run traces (433k iters) but wrecked the board —
  nsieve 12.1→43.3 ms, sieve_int 5.7→11.8, nsieve-bit 14.1→19.0, fft
  301→445 (entry storms: nsieve 825→322,633 entries). Round 3 rolled the
  economics back to baseline (Option-A gating, 4/8 bounds); event counters
  byte-match baseline (nsieve 825/780/337,587 etc.).
- Verdict: bitreverse traces now record AND compile (trace #0 9,736 B —
  previously unsupported) but run only 3–16 iters before striking out —
  **sustained coverage needs LuaJIT-style native exit-branch STITCHING**
  (patched guard jumps straight into the side trace, no runtime re-entry) —
  the doc 16 "nsieve outcome (corrected)" lever, now doubly motivated.
- Gates: both flavors green, six-hash gate + repros PASS, board 28/28 at
  baseline. Interleaved A/B (genuine `just shadow` baseline, nm-verified):
  nsieve/sieve_int/nsieve-bit exact parity; **fft jit +8–10 ms (+3%)
  consistent** — attributed to 2 extra per-run native compiles (~18 KB: the
  newly-compilable :9 + one sibling) + 27 extra entries; our measured
  two-build noise floor on fft is ~2%, so the real cost is ≈1%. lu +1.5%
  (same attribution). Everything else noise.
- State: tree UNCOMMITTED (8 src + 3 doc files). Options for Bart: (i) land
  as-is (+~1-3% fft for the enabling mechanisms, honest doc trail), (ii)
  hold for the stitching arc, (iii) codex round 4 to shave the residual.

## Status 2026-08-16 (LATEST-69) — **Doc 20 Phase 3 LANDED (codex-authored, Claude-verified): `.jloop` patched entry for while/repeat closers. Perf-NEUTRAL; the fft bitreverse premise is REFUTED — those loops never trace at all.**

- Codex (gpt-5.6-sol, thread `01a007a0-0529-71c0-a579-87b67fadff3c`)
  implemented Phase 3 per doc 20: the compiler's actual loop closers —
  backward `.jmp` (while) and backward `.jmp_if_false` (repeat) — patch to a
  shared `.jloop` image opcode at qualification. The arm executes the
  canonical jump once, enters only on a taken back-edge, and shares the
  factored patched-entry tail (`enterPatchedTrace`, now `inline` to keep the
  pre-Phase-3 code shape in the `.jfor_loop` arm) + strike/unpatch/drain
  policy with `.jfor_loop`. `resolvePatchPc` generalized (backward-only,
  fail-closed on ambiguity); recorder mirroring canonicalizes both patched
  opcodes (`recordingMirrorInstr`). `.jmp_if_true`/`.jmp_if_not_nil`
  deliberately unpatched (no language producer). Open Q2 untouched.
- Gates: `just test` + `-Djit-debug` both green; six-hash gate PASS
  (jit ≡ tier-0 ≡ frozen refs on all six workloads); repros 109/109/18135;
  full board 28/28 cross+luajit ok. New pins: lifecycle/ambiguity/
  skipped-opcode/strike-policy in `trace_entrypatch_test.zig`, ten-mode
  determinism + recording-crosses-patched-pc + real prologue-strike
  exhaustion in `interp_lanes_test.zig`.
- **Measured: perf-NEUTRAL** (genuine interleaved pre/post A/B, 3 rounds
  min-of-5: fft jit 293–296→291–293, lu jit 164→165–167, tier-0 legs equal).
  The Phase-2 "remaining fft lever" prediction is REFUTED:
  `fft_bitreverse:9`/`:55` (33% of the fft run) are 0% traced pre AND post —
  `:9` never records, `:55` aborted once (`bad_type` on `get_index`, the
  float-valued `j`/`k` from `k = k / 2`) and never re-enters; zero `.jloop`
  installs on fft. **Next fft lever: make bitreverse traceable** (recorder
  typing at the swap indices + why `:9` never records), not entry machinery.
- **Measurement trap (new, cost an hour): a `cp -r` shadow tree inherits
  `.zig-cache`/`zig-out`, and `zig build` there produced a POST-source
  binary** — the first "A/B" was post-vs-post and its consistent "+2% fft"
  was pure two-builds-of-identical-source layout noise (a useful noise-floor
  datum: ~2% on fft). Always `rm -rf .zig-cache zig-out` in a shadow tree
  before building; verify with `nm <bin> | grep <new-symbol>`.
- Doc 20 status: Phases 0a/0b/1/2/3 all Done; Outstanding = Open Q2 only.

## Status 2026-08-15 (LATEST-68) — **Doc 21 Phase A LANDED: H-5(i) fixed, §R3 green with the full JIT, matrix 918/918.**

- Bart chose option (b) (canonicalize dead slots at capture). Design doc 21
  (`docs/design/21-canonical-snapshot-liveness.md`) went through 3 codex
  gpt-5.6-sol rounds (REVISE B-1..B-6 + M-1..M-4 → APPROVE). Key restructure
  from review: the final-state mask derives from the **runtime result span**
  (`Vm.final_cut`, published by public `exec` alone on a finish netting depth
  0), NOT a compiler statement-frontier — stronger (robust to any future
  dead-store pruning, handles `all_results`) and immune to the depth-0
  `callValue` aliasing (B-1) and stamp-collision (B-2) holes. B-6 bonus fix:
  a top-level `return f()` with more results than the root's static window
  used to silently DROP the surplus from capture (`stack_top` never covered
  them); publication now raises `stack_top` over the dynamic span first.
- Implementation: `final_cut` validated-not-trusted at capture (depth 0 +
  `stack_top` match + in-bounds + no open upvalues; any miss → mask nothing);
  invalidated at `pushFrameVararg` / `beginTopLevelEpoch` / `callValue` entry
  / all three `protectedCall` unwinds; one capture policy applied to BOTH the
  `.snapshot` root walk (`forEachRootHeader` gained a `snapshot_mask` param;
  `.gc` walk untouched, asserts null) and the stack serialization (dead slots
  → canonical nil, dead-slot-only garbage excluded from the reachable set).
  Keyframe v8 → v9 (encoding-identity contract; doc 04 updated). JIT/recorder
  untouched — `locals_watermark` pruning stays.
- Gates: **918/918** both flavors (the §R3 test passes UNMODIFIED with
  tracing+opt+native — first time ever, incl. at its introducing commit
  `7f803a8`) + hashgate + new §T-A.2–.6 pins in
  `keyframeser_resume_test.zig` (cross-tier byte-identity on the minimized
  g-loop, span preservation + garbage exclusion, B-6 all_results surplus,
  depth-0 callValue invalidation, pcall/xpcall).
- Doc 17's H-5(i) grounding closed with a RESOLVED pointer to doc 21.
- **Perf sanity DONE — and it caught a real one.** The quiet-machine
  interleaved A/B (3 rounds, load <2.5) showed the per-push
  `final_cut = null` store in `pushFrameVararg` costing a reproducible
  **13–17% tier-0** on call-heavy rows (scimark-lu 748→880 ms, scimark-fft
  685→775) and ~+3% jit. Follow-up commit replaces it with a debug assert —
  sound because every execution path reaching a push starts at a cold
  boundary that already nulled the cut (`beginTopLevelEpoch` / `callValue`
  entry; an exec-resume implies a suspended VM that never finished). A/B
  re-run: parity restored exactly (lu 745/164 vs pre 748/164, fft 685/294 vs
  690/293); full matrix (asserts active) + jit-debug + hashgate green — the
  assert never fires. Doc 21 Phase B (mid-flight frontier masking)
  deliberately deferred — no pin needs it.

## Status 2026-08-15 (LATEST-67) — **Test-suite extraction: the four biggest files split into thematic `*_test.zig` siblings. No production logic changed.**

Pure file-organisation work at Bart's request, orthogonal to the doc-17/20 arc.
A third of the tree (25,414 of 77,427 lines, 937 `test` blocks) was inline test
code, clustered in trailing regions behind each file's own banner comments.

| file | before | after |
|---|---|---|
| `interp.zig` | 13,464 | **4,839** |
| `trace.zig` | 20,972 | **13,542** |
| `nativegen.zig` | 8,332 | **5,338** |
| `keyframeser.zig` | 3,348 | **839** |

- **Test bodies are copied byte-for-byte**; each destination file gets a prelude
  recreating the identifier namespace (the original import/alias block plus
  `const X = <mod>.X;` bridges). The diff is a pure move.
- **Discovery**: Zig only analyses a file reachable by import, so each source
  keeps a `test { _ = @import("..._test.zig"); }` block. Without it the suite
  silently stops running — that is the failure mode this work had to guard, and
  the guard is a checked test count, not a green build.
- **Counts, checked at every step**: 935 named tests across `src/` before and
  after. `zig build test` 908 → 912, the +4 being exactly one anonymous
  discovery block per split file.
- **The §R3 red is untouched** — still failing deterministically at byte offset
  5667, now reported from `keyframeser_resume_test.zig`. The H-5(i) decision
  below is still open and was deliberately not touched.
- **Visibility cost, and it is asymmetric**: `trace.zig` needed **53** widenings
  to `pub` (47 of them `TraceState` members — `promoteSet`, `replayLedger`,
  `openRegion`, `rebuildRegions`, `emit`, `refOf`, …), `interp.zig` needed
  **6**. The difference is what the suites do: interp's tests are behavioural
  (run Lua source, compare output); trace's white-box the recorder. Bart
  reviewed this and chose to keep the wider surface rather than route it through
  a `test_hooks` gateway. **Consequence to keep in mind: those 47 are now real
  public API on the JIT's core type.**
- **Gotcha worth remembering**: Zig does not care about declaration order inside
  a container, so a test-region `const irinterp = @import(...)` was being used at
  29 *production* sites in `nativegen.zig`. A test banner is not automatically a
  dependency boundary. `tools/check-split.py` now catches this class up front.
- Tooling: `tools/split-tests.py` (dry-run default, refuses to apply on a
  test-count mismatch), `tools/check-split.py` (production leaks + cross-block
  helpers), `tools/pubify.py` (reviewable visibility widenings).
- **Rungs 2/3 deliberately NOT done** (Bart's call): extracting trace.zig's pure
  value-type modules would move only ~1,060 lines, and the bulk — `TraceState`
  at 10,632 lines — needs method→free-function conversion. See TODO.md.

## Status 2026-08-15 (LATEST-66) — **Doc 20 Phase 2 (§P measurement) COMPLETE. Outstanding: Phase 3 `.jloop`, Open Q2, and the H-5(i) keyframeser decision (Bart's call).**

- **§P verdicts** (full detail in doc 20 "§P — Measured results"): P.1 PASS
  (fft jit 295.7 ms ≤ 360, quiet board `20260815-131357-627f7f2.tsv`); P.2
  PASS (no >3% regression; the board's field_hash 13.5→15.6 riser settled by
  a quiet load<2 interleaved A/B — post 13.4/13.0/13.0 vs pre 13.1/13.1/15.5
  ms, the 15.x blip reproduced on the PRE-flip binary, so it was scheduling
  noise); P.3 PASS (`fft_transform:131` 78.0% of iterations traced, from
  37.8%); P.4 PASS (sieve family unchanged); P.5 PASS (matrix both flavors
  906/907 + hashgate at every phase commit; the 1 red is the pre-existing
  H-5(i) §R3 keyframeser test, see LATEST-65); P.0 superseded (pre/post A/B
  carries 0a+0b on both sides).
- **Key measurement correction**: pre-flip fft reads **301.2 ms quiet** —
  LATEST-62's 535 ms was load-inflated (load-70 era). The flip's own fft
  wall-clock effect is ≈ −2% with the +40 pp trace-coverage win. The big
  remaining fft lever is **Phase 3 `.jloop`**: `fft_bitreverse:9`/`:55`
  `while` loops are 30.4% of the run and never tier up.
- **Decision waiting on Bart** (Rule #17, options in LATEST-65): the H-5(i)
  dead-slot exit-snapshot fix — (a) stop liveness-pruning written slots from
  exit snapshots, (b) mask dead slots at capture, (c) relax §R3 to logical
  comparison.
- Shadow tree `/tmp/mahina-preflip` removed after the A/B. Bench TSVs remain
  untracked per standing rule.

## Status 2026-08-15 (LATEST-65) — **Doc 20 Phase 1 (THE flip) LANDED; Phase 2 (§P measurement) next. Pre-existing §R3 keyframeser red diagnosed (H-5(i)), NOT a doc-20 regression.**

- **Phase 1 (this commit)**: the full flip per doc 20 —
  - `EntryPatchState` machine (`eligible → pending → bound / suppressed_{
    incumbent,capacity,permanent}`) on `Trace`; qualify inside
    `accountTraceRun`'s `min_useful` block behind ONE compare (tag-only
    `native == .compiled`, no `nativeFor`); `drainEntryPatchWork` unpatches
    first then installs ascending-trace-id with `installPending` revalidation
    (not-compiled / `.link`-close → `suppressed_permanent`; gated → transient
    `.eligible`; `InstallResult` routing installed/incumbent/capacity/oom);
    `unpatchSlot` wakes (`suppressed_capacity` on ANY tombstone,
    `suppressed_incumbent` on matching incumbent).
  - The real `.jfor_loop` arm: steps the canonical `for_loop` exactly once
    **including the internal-index increment** (the §R2-3 hazard — omitting
    that first line corrupted guests by Δ=strikes×n, found via Δ-analysis +
    jitdbg receipts), `instr = patch.orig` downstream, bypass set
    (recording/suspend/safepoint-lines/exec-log/pending-anchors/coverage) →
    virgin path, else `enterSelectedTrace` with `visited={ct}` + strike
    accounting (`patch_strikes=4` → pending-unpatch). Recorder mirror
    canonicalizes `.jfor_loop` → `proto.code[cur]` (§R1-3). `min_trip_entry`
    demoted to dead config (default 0, kept one release for A/B).
  - **driveChain hop-0 routing fix** (pre-existing latent, exposed by patched
    entry steering): the scalar `sresult_fused` seam models only a
    `[C.link_terminal, I.x]` head; sibling-handoff/M1 `.deopt` (and
    `.loop_done_linked`) heads now route to `driveDispatcherLedger` (which
    already owns that grammar) — generalizes A-vii-d.1's `bridge_headed`
    special case. Repro was the A-viii cycle panic ("fused final trace is not
    the expected inner root"): the chain excluded just-failed t3, picked
    sibling t4, whose handoff arm fired straight back into t3.
  - Gates: full matrix both flavors **906/907** + hashgate + all repros green.
- **The 1 red is PRE-EXISTING**: `keyframeser §R3 capture→restore→resume with
  tracing+opt+native` — bisected in a shadow tree (src byte-identical per
  `git diff`) to fail **deterministically at its own introducing commit
  `7f803a8`** (doc 18 §R4, pre-doc-20 entirely), despite LATEST-60's "green"
  claim. Decoded-snapshot diff isolates it: all 232 heap objects +
  `next_obj_id` identical; only dead stack slots 9–14 differ — exactly the
  doc-17 **H-5(i) dead-temporary omission**: tier-0 rewrites dead expression
  temporaries every iteration (final values 1845/1636/209 = g-loop i=3,j=3),
  the native exit flush omits them (frozen pre-burst values 1221/1015/206 =
  i=2). Doc 17's grounding already adjudicated this "a concrete bug the
  mandatory native-F2c test must catch" — the test is right, the exit
  snapshot is incomplete. Fix directions to put to Bart: (a) stop
  liveness-pruning written slots from exit snapshots (extra exit stores,
  upholds byte-identical); (b) mask dead slots at capture (needs liveness
  metadata, changes snapshot semantics); (c) relax the test to logical
  comparison. NOT decided unilaterally (Rule #17).
- **Codex post-landing review of 7fa7e1a → REVISE, both findings fixed**:
  (BLOCKER) the walk's post-epilogue retire/miss/gate sites marked bound
  patches with no same-turn drain → added a second drain + image re-resolve
  after them; AND the recorder-abort `gateAnchor(rec.anchor)` sites mark
  mid-dispatch where draining is structurally impossible (no epilogue to
  re-resolve the frame image) → the arm's `!live` §R6-1 recovery is now the
  defined deferred-unpatch path in ALL builds (safety-panic removed; doc 20
  §R6-1 + unpatch-trigger timing rewritten to match). (MINOR) slot-capacity
  check off-by-one (`>=` → `>` maxInt(u16); index 65535 is valid).
- **Next**: Phase 2 §P measurement (P.1 fft ≤360ms, P.2 board ≤3%); §P.0
  quiet-machine board still owed; Phase 3 `.jloop` + Open Q2 outstanding.

## Status 2026-08-14 (LATEST-64) — **Doc 20 Phase 0a (d4fd70f) + Phase 0b (inert substrate) LANDED; Phase 1 (the flip) next.**

Bart approved implementation ("if codex is satisfied i certainly am").

- **Phase 0a (d4fd70f)**: the 529-line trial-walk per-candidate body factored
  verbatim into directive-returning `Vm.enterSelectedTrace` (+ `EntryDirective`
  {next_candidate, resume_tier0, switch_mode_at}, `TrialWalkCtx`); the walk's
  directive switch is the caller-owned epilogue (§R3-3 drain site). Interleaved
  A/B neutral-to-faster; the **full-board §P.0 confirmation is still owed** —
  first run invalidated by load-70 parallel rust builds; re-run `just bench` on
  a quiet machine vs `bench/results/20260814-210757-99204e8.tsv`.
- **Phase 0b (this commit)**: `.jfor_loop` opcode (arm panics until Phase 1);
  `TraceState.code_images` copy-on-patch + `image_gen` reload protocol
  (`codeFor` at the three interp frame-(re)load sites, `code_gen` memo,
  epilogue re-resolve after `drainEntryPatchWork`); `EntryPatch` per-slot-heap
  stable-address free-list registry (tombstones, publish-last/restore-first
  ordering, `maxInt(u16)` fail-closed, `seed_count` = the EntryPlan structural
  memo — the map itself already lives on `Trace.inputs`); mark/drain with a
  dirty counter (no OOM mid-grammar); triggers wired: `removeTrace` via
  `entry_slot` back-ref BEFORE `t.destroy` (§R7-2), `gateAnchor`, all
  `wants_side_trace`/`wants_prime_side` sets (`markEntryPatchesAt`), epoch
  `clearCache` + `deinit` (`dropEntryPatchState`, the only image-free points).
  `installEntryPatch` is production-uncalled (tests only). 6 new tests (§T7
  no-image pointer-identity, lifecycle/incumbent/reuse, dropped-trace drain,
  epoch, triggers). Full matrix (both flavors) + hashgate green.
- **Phase 1 next** (task #98): state machine in the accountTraceRun funnel
  (tag-inspection `native == .compiled`, NEVER nativeFor), drain
  revalidate-then-install, the real `.jfor_loop` arm calling
  `enterSelectedTrace` (§R2-3/5 exactly-once-step), `min_trip_entry` demoted.
  Then Phase 2 §P measurement (P.1 fft ≤360ms, P.2 board ≤3%).

## Status 2026-08-14 (LATEST-63) — **Doc 20 (patched trace entry, the BC_JFORL analogue) design APPROVED round 8 — awaiting Bart's go for implementation.**

Bart ruled option C ("no point skipping it for a win we'll overwrite —
design doc time"). `docs/design/20-patched-trace-entry.md` written and driven
through eight codex gpt-5.6-sol review rounds (§R1–§R8 recorded in the doc;
rounds 1–7 REVISE with 9 BLOCKER + 8 MAJOR + 6 MINOR total, all folded;
round 8 APPROVE with one §T10 wording MINOR, folded). The design that
survived review:

- **Copy-on-patch VM-local code images** — canonical `Proto.code` immutable
  forever; only the dispatch fetch reads the image (`image orelse
  proto.code` at frame entry + `image_gen: u64` re-resolution in the
  back-edge epilogue); recorder/predicates/visualiser/keyframes read
  canonical by construction. Images epoch-stable (freed only at
  beginTopLevelEpoch depth==0 / deinit).
- **`.jfor_loop`** opcode over qualified anchors; `.b` = slot index into a
  stable-address free-list registry (tombstones, publish = opcode write,
  `trace_id` + `Trace.entry_slot` back-ref so retirement never dangles —
  drain resolves `traceById`, null = dropped).
- **`enterSelectedTrace`** (Phase 0a): today's whole trial-walk
  body factored into one directive-returning routine; ONE caller-owned
  epilogue drains the ENTIRE pending set before acting on any directive
  (covers the 2879/3052 early `continue :outer` exits). Patched entry skips
  exactly the discovery/selection prefix, nothing else.
- **Entry-patch state machine** per trace: eligible/pending/bound/
  suppressed_incumbent/suppressed_capacity/suppressed_permanent; funnel
  marks only (tag-inspection `native == .compiled`, never nativeFor);
  drain revalidates (same-receipt gate can condemn the marked anchor) then
  installs, unpatches-before-installs, one-live-slot-per-pc, lowest-id tie
  break. Every unpatch drains same-turn (strike exhaustion converts to a
  post-return mark; loop-exit never revisits the back-edge block —
  pc <= cur_pc guard). Arm ordering: inspect held slot pre-drain → drain →
  never touch pointer again (ABA).
- Bypass = runFastPath `.full` set + coverage (live field reads); §P gates
  (P.1 fft ≤360ms, P.2 board ≤3%, P.0 refactor-neutral); §T1–T18.

Phases 0a (factor) / 0b (inert substrate) / 1 (flip) / 2 (measure) /
3 (.jloop while/repeat) in the doc's Outstanding checklist. NOT started —
next step is Bart's go.

## Status 2026-08-14 (LATEST-62) — **fft arc: float-key narrowing landed (318fa0d); nest-coverage hole grounded to min_trip_entry — awaiting Bart's pick.**

Lever A landed: `keyRefNarrowed` (guard_float + int_of_float, mirror of
`normalizeKey` / LuaJIT lj_opt_narrow) in recArrayGet/recArraySet + dispatch
routes number keys; GuardRole.key_int; doc 17 vocabulary rows updated; recorder
+ 10-mode end-to-end tests. fft wall ~flat (bitreverse still dark behind the
0-3-trip inner while + C1 sunk-store rule) but the mechanism is general and
proven native on an isolated repro.

Region B grounded — the ~73% fft coverage hole is ENTRY POLICY, not machinery:
the doc-15/16 chain covers middle+inner stages natively (bursts completing
341-472 iterations, ledger up to CAP=32), but `min_trip_entry=24` (interp.zig
back-edge epilogue) declines trace entry for FFT's late stages (trips
16/8/4/2/1), so no chain ever STARTS there; :131 stuck at 37.8% traced.
EXPERIMENT min_trip_entry=0 (reverted, TSV deleted): full board 28/28 ok, fft
535->351.5 ms (32.5x->21.5x), :131 78% traced, everything else in noise (the
#69/#73 low-yield entry-penalty gate now provides the thrash brake that
min_trip_entry originally supplied). LuaJIT ground truth (lj_trace.c:515,526):
entry is a patched JFORL/JLOOP opcode — unconditional, free, no trip gate.

Options for Bart: (A) drop/lower min_trip_entry default (proven -34% fft, board
clean); (B) surgical: bypass the trip gate only when the anchor owns armed
chain links (entry = chain doorway); (C) LuaJIT-faithful patched tier-0->native
entry (extends B-3 patching to the entry edge; makes the gate moot). Remaining
fft blockers after any of these: fft_bitreverse (~33% of run: short-trip while
+ C1 sunk-store abort), then residual interp share.

## Status 2026-08-14 (LATEST-61) — **Doc 19 LANDED: loaded tree traces — H-2 dynamic-proto gate lifted, keyframe v8. scimark-lu 1160→217ms (73.5×→13.6×).**

Worst-board investigation (scimark-lu 73.5×, jit 43% SLOWER than t0) found the
whole module system JIT-dark: `require` rides `loadChunk`, which stamped every
proto `Proto.dynamic=true`, and the doc-17 H-2 gate refused to anchor/inline
anything dynamic — zero traces, zero aborts, 92.2% of the run in one
untraceable loop. Fix (doc 19, codex-approved round 2 after a v8-blocker round
1): root `vm.loaded_chunks[].chunk.proto` constants via `rootProtoConsts` in
BOTH `forEachRootHeader` walks (mode-invariant, `retained_chunks` precedent) →
the H-2 sole-root state is unreachable → gates + `Proto.dynamic` + AbortReason
`.dynamic_proto` removed entirely. Keyframe v7→v8: encoder now always carries
loaded-proto literals, restore recompile is zero-allocation (enforced,
`LoadedChunkRecompileAllocated`); pre-v8 snapshots rejected (timeline fork).
Tests: gate tests flipped to trace-parity, July-scenario expectProgram now
pins the uniform "victim first" timeline across all 10 modes, §R2 schema
boundary (v7 reject + hand-corrupted v8 trip), §T3 restore-resume traces a
LOADED proto anchor. Board 20260814-202701: lu 216.8ms/13.6×, sor 93.8/4.4×,
fft 531.8/32.4×, sparse ~flat (next frontier: name its aborts — doc 19
Outstanding). 28/28 cross+luajit ok, hashgate PASS, both test builds green.
Also this session: bench harness peak-RSS columns (ca99421, GNU-time
trampoline — fork/posix_spawn floors ru_maxrss at the Python runner's RSS),
str_manip LuaJIT fix (5de9c0a), history strip (00889ad). Post-landing codex
review of the doc-19 implementation (commit 6516ea2): **APPROVE**, no
blockers — 2 MINOR test-coverage hardenings recorded in doc 19 Outstanding
(cross-mode snapshot-byte diff; loaded-proto continuation/replay-side
exercises) + 1 NIT stale `arm` comment, fixed in the follow-up commit. Doc
19 seam closed; named follow-ups: §R3 MINOR hardening, scimark-sparse/fft
abort frontier, the 43%-overhead-with-zero-traces observation.

## Status 2026-08-14 (LATEST-60) — **B-5 post-landing codex review (REVISE) folded: two blockers fixed + two missing §R3 tests landed. Doc 18 fully closed.**

codex `gpt-5.6-sol` post-landing review of 838fd75/0829bb7/890c2c7 →
REVISE; all findings fixed (doc 18 §R4):

1. **set() append over a hash-resident key** (valid state after D7 OOM
   rollback or v7 restore) left an array/hash duplicate → next capture
   failed `ArrayResidentKeyInHash`; the D2a fresh-1 seed variant was
   worse — its slot-0 hole SHADOWED a hash-resident key 0 (value
   silently lost). Both branches now absorb newly-covered hash keys
   (count()!=0-guarded; sequential builds unaffected); 2 unit tests.
2. **next() control key not normalized**: `next(t, 0.0)`/`-0.0` fell
   into the hash arm and yielded nothing. `nextStep` +
   `rowViewNextStep` now fold through `normalizeKey`; 8-mode test.
3. **Missing §R3 coverage landed**: capture→restore→resume WITH
   tracing+opt+native (asserts output + final snapshot equality,
   post-restore trace record/dispatch incl. native entries, grid
   re-inflation, narrow-lane residency) + failing-allocator restore
   through the bulk lane repack (checkAllAllocationFailures).

Gate: both builds green, hashes + repros GATE PASS. Review confirmed
sound: identity mapping, unsigned bounds, native aref, GC walks, D7
binning, v7 validation, --mem-stats lifetime.

## Status 2026-08-14 (LATEST-59) — **B-5 COMPLETE: Phase 4 measurement recorded in doc 18 §P; nsieve-bit 37.2 → 15.4 ms (LuaJIT gap 5.8× → 2.4×).**

Phase 4 per doc 18 §P, all six frozen predictions CONFIRMED (full
record in doc 18 "§P — Measured results"):

- **P.1**: nsieve-bit `--dump-aborts` → no recording aborts;
  `--jit-stats` → 100.0% of loop iterations traced, 91.2% of run
  cycles (88.4% native), all four anchors ≥99.3% incl. the formerly
  aborting init loop nsieve:7.
- **P.2**: nsieve-bit 6 wall 37.2 → **15.4 ms** ON (LuaJIT 6.4 →
  2.4× gap); OFF 38.5 → 23.1 — promotion was ~neutral pre-flip (no
  material traces to promote), now buys a further −33%.
- **P.5**: board otherwise within noise both states (four TSVs
  20260814-{121953,122259,155221,155531}). Outliers cleared:
  scimark-lu re-rep 1133 (noise); str_format +6–8% both tiers is a
  code-layout artifact (no tables in the program; 81.8% of time in
  untouched-logic `gc.Heap.internValue` whose alignment shifted).
- **P.6**: NEW `--mem-stats` CLI flag (TrackingAllocator wrap in
  main.zig, Rule Z-4 style) — 28-program board peak delta uniform
  −288 B, zero leaks everywhere; nsieve-bit −5.4% peak; boundary
  micro: exact-2^20 ascending fill +48% peak (inside the accepted
  ~2× bound), off-boundary/descending identical. Pre-flip
  comparison binary built from a `git archive 7b65d79` copy in /tmp
  with the same --mem-stats patch.

Doc 18 status → complete (Phases 0–4); only the deliberately-parked
hash-part integer-key recording arc remains. Post-landing codex
review of the Phase 2/4 commits is the remaining house-pattern step.

## Status 2026-08-14 (LATEST-58) — **B-5 Phases 1–3 LANDED: slot-0 array part is live (`81b73c2` inert prep, `838fd75` THE atomic flip, doc sweep follows). Phase 4 measurement outstanding.**

Doc 18 implemented on Bart's go-ahead. The array part now covers keys
`0..asize-1` identity-mapped (LuaJIT's layout): one unsigned bounds
compare, `t[0]` array-resident, recorder's idx<1 `.bad_type` abort gone.

- **Phase 1 (`81b73c2`)**: inert prep — shared `inArray` helper routed
  through every non-native gate, producer-dispatched `guard_bounds`
  (`.aref` vs `.garow`), `seedAt` wired at old semantics. Byte-identical.
- **Phase 2 (`838fd75`)**: ONE atomic commit, 9 files. array.zig
  `len`→`asize` + identity get/set + `commitFreshLane`-factored
  seedAt{0,1}; table.zig getInt grid `i>=1` gate, set append at
  `key == asize` + fresh {0,1} routing, D7 rehash (unsigned countKey,
  `bin(k)=ceillog2(k+1)`, drain `[old_asize,new_asize)`, OOM rollback
  `asize=k`), length() empty-extent guard; gc 0-based mark walk +
  inflate guards (`asize<=1`, populated slot 0 blocks outer AND rows) +
  deflate slot-0-hole seed (no row down-shift); recorder/tier-1a/native
  append `idx == asize`; nativegen `.aref` drops `sub 1` (garow keeps
  it); keyframe v7 (positional 0-based, restore bulk lane rebuild
  repack+freeze, `ArrayResidentKeyInHash` validation incl. float-0.0);
  pairs walks key 0 first (the signed-off observable change). Full §T
  matrix: unit (bounds edges, seedAt per-lane + OOM, presence 63/64,
  computeArraySize 63/64/65/127/128 boundary overshoot, grid key-0
  blocks, deflation no-down-shift, slot-0 GC edge, v7 validation +
  lane rebuild) + five 8-mode script tests + an f2c resume corpus
  source. **Gate: both builds green (incl. -Djit-debug), seven hashes
  + three repros UNCHANGED (GATE PASS), nsieve-bit --dump-aborts →
  "no recording aborts".**
- **Phase 3**: pins + doc sweep — doc 02 pairs-order pin, doc 03/05
  extent wording, doc 04 v7 entry, doc 14 grid note, schema/trace.json
  description, table.zig module docs, doc 18 checklist ticked.

NEXT: **Phase 4 — measurement per doc 18 §P**: nsieve-bit promotion at
run start + wall-clock, full board both promotion states vs the B-4
baseline (36.7 ms nsieve-bit), memory deltas (append +1 slot; the
accepted power-of-two boundary overshoot), then post-landing codex
review. Then the deferred hash-int recording stays parked.

## Status 2026-08-14 (LATEST-57) — **B-5 REDIRECTED to slot-0 array part (Bart's call); design doc 18 written + ACCEPTED by both reviewers. Awaiting implementation go-ahead.**

Bart's direction on the B-5 recording gap: instead of hash-part
integer-key recording, extend the internal array part by one slot so
key 0 is array-resident — LuaJIT's exact layout (`inarray = (MSize)key
< asize`, non-inclusive sizes, slot 0 allocated; verified in
`lj_tab.{h,c}`). General fix per Z-6: every 0-indexing program gets the
fast path AND stops poisoning trace recording (the abort+backoff chain
of §B4.8). Hash-int recording demoted to a deferred follow-up (only
cover for negative/sparse keys).

Work done this arc:

- **Grounding**: very-thorough 8-group inventory of every 1-based
  assumption (Explore agent; array.zig conversion layer, table.zig
  routing/rehash, keyframeser positional wire format, recorder,
  nativegen address math, irinterp, stdlib/base nextStep, gc walks,
  rowView) — six cross-cutting surprises, the `len` multi-overload
  being the crux. LuaJIT reference read (countint/countarray/
  bestasize/rehashtab).
- **docs/design/18-slot0-array-part.md** written per the design-doc
  skill: D1 identity mapping + conditional field contract (scalar
  `asize` vs grid row count) + exact `@bitCast` unsigned helper; D2
  asize disambiguation incl. the five `get(i+1)` walk sites; D2a
  `seedAt` fresh-seed primitive (non-nil keys {0,1} only); D3
  producer-dispatched `guard_bounds` + atomic-flip mandate; D4
  keyframe v6→v7 + restore bulk lane rebuild (repack+frozen) +
  normalized-key validation; D5 pairs-order change (deterministic,
  pinned); D6 grids stay 1-based, deflate-on-key-0, guarded inflation;
  D7 complete sizing derivation (bin(k)=ceillog2(k+1), memory honesty
  at power-of-two boundaries, drain rollback asize=k); §T cross-tier
  test matrix; §P frozen predictions (stdout hashes UNCHANGED is a
  prediction — any change is a defect).
- **Reviews to acceptance**: codex gpt-5.6-sol rounds 1–3
  (REVISE ×2 → APPROVE; 5 BLOCKER + 4 MAJOR + 4 MINOR + NIT across
  rounds, all folded — §R1/§R2/§R3 records in doc 18) + Antigravity
  rounds 1–2 (REVISE with 7 blockers → CONFIRM, re-verifying each).
  Convergent round-1 finding worth remembering: the naive Phase split
  would have been wrong-address CORRUPTION, not trace-shape drift —
  the flip must be atomic across layout + all three tiers + walks.

NEXT (pending Bart): implement per doc 18 phasing — Phase 1 inert prep
(producer dispatch, inArray helper, seedAt), Phase 2 the atomic flip,
Phase 3 pins/docs, Phase 4 measurement (§P: nsieve-bit aborts → 0,
promotion at run start, wall toward LuaJIT scale; board within noise).

## Status 2026-08-14 (LATEST-56) — **B-4 REFRAMED, DESIGNED, LANDED (positional loop-done resolution); predictions failed on nsieve-bit; TRUE root cause found = B-5 (`idx < 1` recording abort).**

Full arc in doc 17 §Part B-4 (§B4.1–§B4.8). The compressed story:

1. **Original premise refuted by ablation.** B-4 was minted as "probation
   for the nsieve-bit t=5 mega-trace". A maxrecord=100 ablation binary
   (only t=5 aborts) is **+31.3% slower** — t=5 is the automaton's scan
   segment (`.link -> 41`), net-profitable. The B-2b-era condemnation was
   measured under `--jit-stats` accounting overhead (74.9 vs 36.0 ms).
   Probation NOT built (Rule Z-6). §B4.1.
2. **Reframed on measurement**: 27,554 `break_burst` events at the
   terminal `.loop_done_linked` replay directive, which only consulted
   `cursor.cont` and never looked up continuations positionally at
   `post_pc`. Designed D1'–D4' (§B4.3/§B4.7): canonical selector
   `resolveLoopDoneCont(proto, post_pc, regs_or_null)` over the P-G
   predicate — ranking hit-count desc → lowest id, `.unsupported`
   skip-not-shadow, canonical arm probe order (D4'), `regs` fingerprint
   preference for the RUN target only (arm stays cache-pure).
   Three codex `gpt-5.6-sol` rounds: REVISE (BLOCKER + 2 MAJOR) →
   REVISE (new MAJOR = probe-order memoization hazard → D4') → ACCEPT.
3. **Landed** (src/trace.zig): selector + `armLoopDoneLink` resolves
   internally (`armLoopDoneLinkTo` keeps re-validation + arm) + terminal
   positional fallback + `regs: ?RegWindow` threaded through
   `replayLedgerFrom`/`replayLedger`/`replayLedgerSuffix`/
   `driveSilentBurst`/`drainSilentResult` (/tmp/b4_thread_regs.py,
   dry-run first). New unit test pins unsupported-skip, id tie-break,
   arm-vs-run divergence, R6 no-re-arm, cleared-cache → break_burst.
   Gates: `just test` both builds green; seven hashes + three repros PASS.
4. **Measured: predictions 1–3 FAILED; wall NEUTRAL.** Still 27,554
   terminal failures (now "no eligible continuation"); interleaved A/B
   vs HEAD: nsieve-bit 36.9→36.7 ms (−0.4%), nsieve 9 50.3→50.7 ms
   (+0.8%) — noise. A permanent jitdbg probe in the failure path proved
   **zero traces anchored at post-PC 58 during all events** — the
   mechanism is correct but had nothing to select. Landed anyway: it is
   the general contract three reviewers accepted, neutral where it can't
   fire, and removes avoidable break_bursts wherever a positional
   continuation exists.
5. **True root cause (open, doc 17 Outstanding bullet B-5).**
   `--dump-aborts`: recorder aborts `.bad_type` at the `get_index`/
   `set_index` bounds check `idx < 1` (trace.zig ~11290) — nsieve-bit's
   `p[i>>6]` is `p[0]` for `i < 64` and its init loop is `for i=0,…`.
   Every recording that captures a small-`i` iteration dies (24× anchor
   :41, 5× :58, 6× :7, 1× :17); gate exponential backoff (128→65536,
   max_strikes 6) then starves the pc-58 scan trace until log line
   ~220k/349k — exactly where break_bursts stop. LuaJIT is immune (0-based
   array part). **General gap: the recorder cannot trace index-0/hash-part
   table access.** Options to ground next: hash-part recording, array-part
   indexing revisit, softer gate escalation for data-transient aborts.

Board unchanged: nsieve 1.0× LuaJIT, sieve_int 1.0×, pi_leibniz 2.7×,
nsieve-bit 6.6× (blocked on B-5), grid_matmul 5.6×, scimark 23–73×.

## Status 2026-08-14 (LATEST-55) — **B-3d.4 frozen measurement DONE → B-3d COMPLETE. nsieve is at LuaJIT PARITY (1.0×).**

The measurement protocol frozen in §B3.18 ran on the e56252f tree:

- **Predictions verified** (nsieve 9, release jit-stats): suffix drains
  3411 → 13 against 174 budget exhaustions (bursts now end almost
  exclusively by budget); steering seam 30.6% → 6.2% of run (replayLedger
  12,427 → 780 walks, wall 72.2 → ~49–53 ms); tier-0-has-trace by
  iteration count 12,468 → 2,354. The residual tier-0-has-trace *time*
  bucket (~13.8% of run) is 78 interpreted warm-up iterations of the
  outer `nsieve:4` loop at ~370k cyc each — nested-work attribution, not
  a seam: the former feedstock anchors nsieve:14/24 run 98.9–99.3%
  traced by time.
- **Budget re-sweep** (`--trace-silent-budget` 1024…2^30, nsieve 11,
  best-of-5): flat within noise, output byte-identical at every value.
  The knob stays a non-lever — now because the seam it metered is gone.
- **Full board, both promotion states** (bench/results/20260814-121953
  ON, 20260814-122259 OFF): promotion is worth nsieve 2.1× → **1.0×
  LuaJIT (13.6 vs 13.5 ms — parity)**, sieve_int 2.1× → 1.0×,
  pi_leibniz 3.7× → 2.7×; every other row within noise, no regressions.
  The one correctness flag (str_manip luajit=ERR) is pre-existing on the
  LuaJIT side (same flag in both prior boards).
- Tree restored to promotion ON, `just release` rebuilt, hashgate PASS.

The owed codex `gpt-5.6-sol` review ran same day (quota returned early
2026-08-14): **APPROVE**, zero BLOCKER/MAJOR/MINOR. It independently
verified: every mutation path (membership growth, changed re-arms, disarms,
trace retirement, defs mutation, region close, activation change, unfreeze,
cache/state teardown) reaches demotion; identical non-sibling re-arms
short-circuit while sibling re-arms keep latch balance; edges/summary/
metadata transfer ownership only after successful publication and are freed
exactly once; R1 one-set-per-region enforced plus exclusive physical-exit
ownership; D4 sound from `emitSilentEpilogue`'s write order (terminal
metadata + ordinal precede the `silent_transitions` bump, no route back
into silence after reporting starts). One NIT — residual "cycle"
locals/comments in the migrated code — fixed in 3f77f34 (42 lines, script
/tmp/b3d_nit_rename.py dry-run first; tests both builds + hashgate PASS).
**B-3d is CLOSED.** Recorded next candidates: B-4 trace-quality probation
(nsieve-bit at 6.6×), grid_matmul 5.6×, scimark family (untraced, 23–73×).

## Status 2026-08-14 (LATEST-54) — **B-3d.2+.3 LANDED MERGED (e56252f): set candidacy + measured drain. Next: B-3d.4 frozen measurement.**

The core of B-3d, landed as ONE gated change. The plan's .2/.3 split proved
unlandable: the first set-shaped promotion panics `driveSilentBurst`'s
ring-successor assert and `computeSiblingReturnDistances`' revolution proof,
so .2 alone crashes the nsieve hashgate. Grammar and drain moved together.

What changed (src/trace.zig only, +693/−407):

- **D1 candidacy** — `detectPromotableSet` (replaces `detectPhysicalCycle`):
  candidate = every armed, patch-pointed (`promotedEdgeFromLink`), un-owned,
  region-member edge at the observation instant, insertion-sorted by
  (parent id, exit); the forced-yield ledger is validated as *evidence*
  (kind-exact via `rowPatchKind`, per-adjacent-pair child match, final row
  exempt) but no longer defines the unit — zero-evidence member edges
  promote on registry proof (R5(c)).
- **D2 storage** — `PromotedCycle`→`PromotedSet` (mechanical sweep via
  /tmp/b3d2_rename.py, 124 word-boundary hits); `sibling_return_distance`
  deleted along with `computeSiblingReturnDistances`.
- **D3 measurement** — `silentSiblingEvidence` is now a method: sibling
  `returned_to_parent` := a strictly-later firing of any live cell with the
  same parent id (R3: a self-edge's own firing does NOT count), OR a suffix
  row with `row.id == parent id` (R4: arrival ownership is `row.id`).
- **D4 terminal** — `driveSilentBurst` resolves entry/terminal cells by
  measured ordinals; ring-successor assert replaced by a terminal assert
  (`last_set` cell owns `silent_transitions`) that runs BEFORE the summary
  mailbox clear; R5(a)/(b) comment-asserts at the expansion loop and the
  two-phase drain boundary.
- **R1 one-set-per-region** — `promoteSet` rejects
  `error.PromotionRegionOwned` (counter `region_owned`; the dead
  `already_owned` reject retired — owned edges are excluded from candidacy
  and surface as `open_chain`); arming a NEW armable member edge of an
  owning region demotes via `DemotionReason.membership_growth` at the
  `armNativeLink` funnel (`noteMembershipGrowth`, both re-arm and fresh-arm
  paths, after successful arm only).
- **R7 shared predicate** — `edgeMemberOfRegion(edge, region_id,
  require_bridge_stamp)` used by candidacy (strict), promoteSet
  re-validation (strict), and the growth trigger (stamp=false: it runs
  before `tryArmRegionBridge`'s restamp; wider is safe — worst case an
  extra demote-and-regrow).
- **Tests migrated set-shaped, never deleted** (871 green): candidacy
  accept/reject matrix (rotation-independence, footprint shrink, foreign
  region, non-member rows, kind mismatch, adjacent-pair break, over-cap,
  region-owned), repeated-parent measured-terminal pins (R3/R4), M1 test
  now also pins `membership_growth` firing on a sibling publish over a live
  set, and a NEW 4-edge repeated-parent set (parent with two armable exits
  — the shape ring grammar structurally cannot promote) promoted from
  partial evidence then drained from an out-of-order rowless burst image,
  resume contract from the measured terminal.

Gates: `just test` green both builds; hashgate seven hashes + three repros
PASS, promotion ON and OFF (default flip/restore). Telemetry (nsieve N=7,
dbg): promoted units become set-shaped (lens 6/7/8 vs 2-edge rings),
**suffix drains 3411 → 13**, bursts 3557 → 187 (~19× longer each),
transitions 612900 → 721685 (+17.7%), budget exhaustions 146 → 174,
`growth=0` on this suite (regrowth via unfreeze/trace demotions).
nsieve 9 release: **steering seam 30.6% → 5.7% of run**, replayLedger
walks 12,427 → 780, wall 72.2 → 53.4 ms (−26%), native execution 57.2% →
73.8%. The B-3d seam thesis measured true.

Remaining: **B-3d.4** frozen measurement (budget re-sweep now that bursts
end mainly by budget, full `just bench` board, both promotion states,
telemetry sanity, doc records). Owed: codex `gpt-5.6-sol` review of the
whole B-3d design+implementation when quota returns 2026-08-20.

## Status 2026-08-14 (LATEST-53) — **B-3d.1 funnel hygiene LANDED (63dd733). Next: B-3d.2 (set candidacy + promotion).**

First gated sub-step of the accepted B-3d landing plan (doc §B3.18):

- **R6 identical-re-arm short-circuit** in `armNativeLink`'s re-arm branch:
  return true immediately when child, kind, AND slot target are all unchanged
  — identical convergence re-arms (2c-E sites 3/4) no longer demote owned
  sets via `prepareSlotMutation`. The target compare is load-bearing (a
  recompiled child at a new address must still take the mutation path).
  `.sibling_handoff` is excluded: `publishSiblingArm` bumps the latch +1
  after a true return, balanced only by the re-arm branch's
  `clearSiblingLatch` — the short-circuit would leak it (pinned by the
  extended sibling-latch test asserting `sibling_arms` stays 1 on a double
  publish).
- **R2 demote-on-unfreeze** in `flushRegionWindow`: the low-yield unfreeze
  now calls `demotePromotionsForRegionReason(key, .unfreeze)` in the same
  act (new `DemotionReason.unfreeze` + counter + dump line), closing the
  pre-existing Rule-#0.5 panic path (unfreeze with live patches →
  `driveSilentBurst` frozen-accumulator panic on next drain). Covers both
  the direct depth-0 path and the depth>0 queued/`applyPendingDisarms` path
  (new test pins both).
- Tests: slot-mutation test reworked (identical re-arm asserts NO demote;
  changed-relation re-arm to a new trace still demotes + unpatches);
  new "low-yield unfreeze demotes in the same act" test.

Gates: `just test` green both builds; hashgate seven hashes + three repros
PASS with promotion ON and OFF (default flipped for the OFF leg, restored).
Telemetry (nsieve N=7, -Djit-debug): demotions re-attribute
`region-close 3→1, unfreeze 0→2` (total still 4), every other counter
byte-identical (candidates=16 promotions=4 bursts=3557 transitions=612900
budget=146 barren=0 suffix=3411) — proof the R2 window was genuinely live
at activation end, and that demoting earlier is behavior-equivalent here.

Owed: codex `gpt-5.6-sol` review of the whole B-3d design+implementation
when quota returns 2026-08-20, before the final landing gate (B-3d.4).

## Status 2026-08-14 (LATEST-52) — **B-3d set-promotion design ACCEPTED (doc §B3.16–§B3.18) after three adversarial rounds. Next: land B-3d.1 (funnel hygiene).**

B-3d generalizes silent promotion from exact detected rings to the frozen
region's armed-edge SET, so non-ring automata (the nsieve:14 sibling triangle)
run silent regardless of firing order — the ~40%-of-run drain seam from
LATEST-51. Round-6's per-cell measurement already de-ring-ified the
accounting; the design closes the three remaining ring dependencies with
measured, order-free replacements.

Review history (Antigravity + independent general-purpose agent each round;
codex quota-blocked until Aug 20, a gpt-5.6-sol pass owed before final
landing): round 1 REVISE (BLOCKER: one-set-per-region unenforced/broken by
growth; MAJORs: trigger can't see suffix ledgers, barren-unfreeze→live-patch
panic, PROVENANCE_VERDICT_CAP arithmetic; Antigravity's O3 answer refuted
against the source) → round 2 revision (R1 demote-and-regrow + enforced
invariant, R2 demote-on-unfreeze, per-adjacent-pair child-match, D3 self-edge
correction) → round 2 REVISE ×2 convergent (same MAJOR both reviewers: owned
identical re-arms demote via prepareSlotMutation — the stale "harmless
supersede" convergence arms) → round 3 revision (R6 short-circuit at the
armNativeLink funnel, `.sibling_handoff` excluded for latch balance; R7
wording/scope) → confirmation ACCEPT ×2.

Two pre-existing bugs (Rule #0.5) confirmed by both reviewers, fixed by
construction: (1) barren-exhaustion → `flushRegionWindow` unfreeze leaves
patches live → next drain panics on the frozen check (unreached on the suite,
reachable by construction); (2) ring `returned_to_parent` bounds against the
CALL-GLOBAL transition count, so a second live cycle's firings can fake a
return → false strike (D3's parent-specific measured arrival eliminates it).

Landing plan (each sub-step behind full gates, both promotion states):
**B-3d.1** funnel hygiene (R6 short-circuit + R2 demote-on-unfreeze —
independently landable, fixes the latent bugs); **B-3d.2** set candidacy +
promotion (D1 grammar, promoteSet, membership_growth, storage rename);
**B-3d.3** drain generalization (D3/D4 measured evidence + test migration);
**B-3d.4** frozen measurement (predicted: seam 30.6% → single digits,
tier-0-has-trace ~0, budget knob live again).

## Status 2026-08-14 (LATEST-51) — **B-3c DONE (commit 2f3c929, doc §B3.15): the budget is a ~1% lever; the real seam feedstock is the NON-RING sibling automaton → proposed B-3d set-promotion.**

The prescribed sweep + re-profile ran and answered B-3c's own question in the
negative. Landed: `--trace-silent-budget <N>` CLI override (output
byte-identical at N=1/1024/2^32/default) + two permanent jitdbg probes
(`silent-promote` edge lists, `suffix-row` suffix-ledger composition). Gates:
`just test` green in normal and `-Djit-debug` builds; seven-hash + three-repro
GATE PASS on ReleaseFast.

Findings (all in doc 17 §B3.15):

- **Budget: ~1%.** 534 exhaustions ≈ 4% of ~12.9k drains; unbounding removes
  exactly them (walks 12,960 → 12,427; 57.34 → 56.73 ms interleaved
  min-of-55 at nsieve 9). Default stays 4096. But note 534 × 4096 ≈ 99% of
  all silent TRANSITIONS — the hot cycles always run to the cap; the other
  12.3k bursts average ~1.5.
- **What ends bursts: ledger-full suffix drains.** nsieve:14 is three sibling
  traces t3/t4/t5 (sibling_handoff deopts). The live promotion covers the
  5-ring clear→cont→t4→t3→t4→clear; the suffix rows are exactly the OTHER
  triangle edges (t3.ei12 ≈34.0k, t4.ei18 ≈37.4k, t5.ei14 ≈37.4k at N=7).
  Unequal counts ⇒ the firing order is data-dependent, NOT a fixed ring ⇒
  `detectPhysicalCycle`'s exact-repeat grammar can structurally never promote
  it. Expressiveness limit, not tuning.
- **Drain cost ≈ 10k cyc each ≈ 40% of the run.** Suffix walk ~7.8k cyc PLUS
  one tier-0 re-entry iteration ~2.3k cyc (`tier-0, has-trace` = 12,468 iters
  ≈ drain count exactly). The 30.6% seam bucket and the 9.0% tier-0-has-trace
  bucket are the same phenomenon.
- **nsieve:14 "heavy codegen" (task #82) resolved: it isn't.** trc-c/it 18.9
  is the seam billed to the first replayed hop; the composite-spin IR is ~10
  tight ops, ~7.7 cyc/it native after seam subtraction.

**Identified next general lever (NOT yet mandated): B-3d set-promotion** —
promote the frozen region's armed-edge SET instead of exact rings. Round-6
per-cell measurement (`firings`/`last_ordinal`/`silent_last_cell`) already
de-ring-ified the accounting; the ring is still load-bearing for metadata
grouping, sibling-evidence return distances, and the terminal-resume successor
assert. Design-first with review rounds. Alternative smaller lever: cheapen
the drain round-trip (skip the tier-0 re-entry iteration after a drain).

## Status 2026-08-14 (LATEST-50) — **B-3b LANDED: the seam is closed. nsieve 1.1× LuaJIT (was 1.9×), sieve_int 1.0× (was 1.5×). Commit 8942ef6.**

Promoted cycles now transition trace→trace natively without appending ledger
rows; Zig expands a per-kind summary that is accounting-equivalent to the
row-by-row replay it replaced. Landed in four gated sub-steps (b.1 `ReplayCursor`
extraction, b.2 promotion registry + patch lifetime, b.3 the flip, b.4 bridge
promotion), then hardened over SIX adversarial review rounds.

Measured (nsieve N=9): replay rows **2,547,824 → 394,179**; native `[JIT]`
43.0% → 50.5%; the 46.2% Zig seam that motivated Part B is gone as a dominant
cost. Board: **nsieve 24.4 → 16.2 ms (1.1× LuaJIT)**, **sieve_int 11.3 → 7.5 ms
(1.0×)**. Telemetry: 16 candidates, 4 promotions, 2,205,469 silent transitions,
12,824 bursts, 534 budget exhaustions, 0 barren, rejects all zero except
`open=1`.

Rounds 1–5 (codex `gpt-5.6-sol`) found eleven soundness defects, all fixed
without weakening a check or disabling an edge kind. Round 6 ran on Antigravity
+ an independent agent (codex hit its usage limit until Aug 20) and found three,
recorded in doc 17 §B3.14:

1. **BLOCKER — burst endpoints were reconstructed, not measured.**
   `(first_phase + transitions ± 1) mod len` assumes every silent transition is
   the next phase of ONE ring where each trace owns exactly ONE phase. Neither
   is enforced: `computeSiblingReturnDistances` explicitly supports
   repeated-parent rings, and several rings can be live at once, all
   incrementing the same call-global `silent_transitions`. A wrong terminal edge
   ⇒ wrong tier-0 resume PC (the A-viii "missing prime 307" class) + wrong
   committed count, silently. Fixed by making native publish what happened:
   per-cell `firings`/`last_ordinal` + `NativeResult.silent_last_cell`, a
   `silentCellOwner` resolver for both endpoints, a release-checked
   `Σ firings == silent_transitions` invariant, and expansion/clearing over
   every live cycle. This corrects §B3.13(5) of the accepted design.
2. **Sibling evidence indexed an edge's FIRST firing**, so progress preceding a
   final barren firing masked a strike. Now indexed to the most recent firing;
   the return-to-parent bound moved to total transitions (a row is appended by
   every materialized transition, including the unfollowed final one).
3. **The ≤1-row provenance settle was in the wrong function** — double-settling
   the driveChain seed while leaving `driveDispatcherSilentResult`, the origin
   its own comment names, unsettled.

Gates: 869 tests green in both the normal and `-Djit-debug` builds; all seven
frozen stdout hashes + the three soundness repros match with
`silent_promotion_enabled` **both ON and OFF**; telemetry byte-identical across
round 6; interleaved min-of-11 ReleaseFast A/B neutral.

**Two measurement traps that cost real time this session — read before timing
anything.** (a) `just test` and `zig build test` leave a **Debug**
`zig-out/bin/mahina`; a binary copied after them times ~3× slow and produces
garbage A/Bs (this fooled me twice — the tell was `-Djit-debug` telemetry being
byte-identical, i.e. no tiering change could explain the delta). Always re-run
`just release` before copying. (b) A single wall-clock board row can be an
outlier: `pi_leibniz` read 39.3 ms on one board and 12.8 ms on the next while
`mahina_jit_execns` stayed at 38.8 M — identical work. Cross-check the exec-ns
column before believing a wall delta.

Open next: **B-3c** budget tune (534 of 12,824 bursts exhaust `silent_budget =
4096`); **B-4** deterministic trace-quality probation (nsieve-bit still 36.3 ms,
6.3× LuaJIT). Untracked bench boards remain in `bench/results/` (uncommitted by
choice). The `str_manip` ok/ERR board flag is pre-existing and unrelated (the
LuaJIT leg calls an unavailable `string.codepoint`).

## Status 2026-08-13 (LATEST-49) — **B-3a substrate LANDED (flag off, all gates green, seam coverage 73.5% ≥ 70% gate). Next: B-3b runtime promotion.**

B-3a reverse-authored (Codex implemented on thread
019ffa90-924c-7520-85ae-05865ffded52, Claude reviewed the full diff + ran
every gate). What landed: per-kind patch points (recorded `E9` for ordinary
`.deopt` mini-stubs, excluding loop-done guards and composite-bridge
candidates; `nop5` windows between materialization and reporting at
`.link_terminal`/`.loop_done_linked`; nothing for `.region_bridge`),
out-of-line per-kind silent epilogues implementing the §B3.11(1) summary
transforms + §B3.13 absolute barren compare + `silent_cum` + first-cell
ownership (UNREACHABLE: metadata cells null, no patch applied anywhere),
`McodeArena.patchRel32`/`patchWindow` with page-generation validation
(live-allocation records; free-list reuse gets a fresh generation), exact
original-bytes restore, RX-restore-failure `@panic`; frozen
`NativeResult`/`ExecResult` silent ABI tail appended after `ledger_outcome`
with a comptime layout oracle (`NativeResultLedgerLayout`); the
`prepareSlotMutation`/`commitSlotMutation` two-phase funnel over all five
physical slot-write sites (armNativeLink fresh + re-arm,
resetLinksTouching, disarmAllLinks, disarmLinkAt) preserving
registry-before-slot ordering; `prepareNativeEntry` (B-3b sweep hook) at
all four native-call origins; `closeRegion` → `demotePromotionsForRegion`
hook; `dbgNoteReplayRow` seam partition counter.

Gates: `just test` + `-Djit-debug` green (857 lib tests). Seven stdout
hashes identical to ba29ff2 AND to the frozen references — after
re-tripping the LATEST-47 trap myself: nsieve/nbody are at
`bench/luajit/*.lua` (NOT `bench/*.lua`), and piping `2>&1` into sha256sum
hashes the FileNotFound message, which "matches" across binaries. Hash
stdout only, and confirm the program path exists first. Soundness repros
109/109/18135. Flag-off timing: sieve_int min-of-60 +0.8% (earlier
min-of-21 runs scattered +0.25…+4.5% — machine variance), nsieve 9 and
pi_leibniz within noise → "identical modulo NOP" gate passes. Seam
telemetry at nsieve 9: **bridge-free-closed = 1,872,025 of 2,547,824 rows
= 73.5% ≥ 70%** — B-3b proceeds as designed, no re-scope.

Review nits (fine for B-3a, revisit in B-3b): `movMemImm32` stores to u64
silent fields (sound little-endian for the small staged values; worth a
widening or comment); `dbgNoteReplayRow` does a per-row bounded DFS (64
nodes) — double-gated behind jitdbg+debug_log so zero production cost.

---

## Status 2026-08-13 (LATEST-48) — **B-3 design ACCEPTED after five codex review rounds (§B3.6–§B3.13 in doc 17). Next: B-3a substrate implementation.**

Bart: "Ok, lets go for the full B-3 thing. It's the biggest lever we have for
parity." Target: the measured 46.2% Zig seam at nsieve N=9 (replayLedger
29.24% + driveDispatcherLedger 14.71%; native 43.0%, tier-0 4.3%).

Design went through FIVE codex `gpt-5.6-sol` rounds (thread
019ffa79-75fe-77a2-8972-470c49f2bd28), REJECT ×4 then ACCEPT. Every round is
recorded verbatim-in-spirit in doc 17 (§B3.6/8/10/12 findings, §B3.7/9/11/13
revisions). The three round-1 mistakes that shaped everything: (a) one shared
patch tail — but the four chain-source kinds have different materialization
shapes (ordinary `.deopt` has an existing `E9` to swap; `.link_terminal`/
`.loop_done_linked` fall through into `emitLedgerAppend` and need a 5-byte
NOP window; `.region_bridge` is v1-ineligible); (b) silent terminals routed
through `replayLedger`'s grammar — replaced by `driveSilentBurst` +
`replayLedgerSuffix` over an explicit `ReplayCursor`, with terminals owned
end-to-end and release-panic on impossible grammar; (c) accounting
precomputed from observed locals — WRONG, locals are runtime quantities
(`e.cum - prev_cum`); replaced by dynamic per-kind native summary cells
`{region_work, selection_work, qualifying_rows}` mirroring replayLedger's
kind switch (trace.zig:4920), an absolute-count barren budget striking AT
the boundary, and a `silent_cum` baseline for the suffix.

Other load-bearing contracts pinned by review: per-exit metadata-cell
transport (compile-time stable cell, promotion publishes metadata → cell →
patch LAST; demotion restores code FIRST); activation binding — promotion is
RegionKey-local while the patch is physical, so v1 carries a STATIC
promotion predicate over the verified same-activation edge shapes
(trace.zig:2671/7810/7820+/4490+), a conservative global pre-entry sweep
demoting any promotion whose RegionKey ≠ active key, and a direct
`closeRegion` demotion hook; ALL `CompiledTrace.slots[]` writes (incl.
trace.zig:7758/7871/7912/7948) move behind two-phase
`prepareSlotMutation`/`commitSlotMutation` preserving armNativeLink's
registry-before-slot OOM order; drain at all FOUR native-call origins
(direct dispatcher, driveChain seed, driveBurstCore call A/B); ABI tail
appended after `ledger_outcome`: silent_active, silent_transitions,
silent_budget, barren_budget, silent_cell, cur_zero_run, silent_cum (all
u64, comptime @offsetOf asserts).

Landing plan: **B-3a** substrate — per-kind patch points, out-of-line silent
epilogues UNREACHABLE until patched, metadata cells, frozen ABI,
patchRel32/patchWindow validation suite; flag off; gates = identical-
modulo-NOP bench run + a `-Djit-debug` seam-coverage counter proving ≥70%
of the ~1.7M rows sit in a bridge-free closed armed subcycle (if that fails,
B-3b is re-scoped BEFORE implementation). **B-3b** runtime promotion:
PromotedCycle + closure detector + driveSilentBurst + summaries + demotion
transaction, full frozen measurement protocol. **B-3c** budget sweep.

Still open for Bart (carried from LATEST-47): nsieve-bit +17% ship-vs-revert
(B-4 filed); two seam-round-2 MINORs; stray untracked
bench/results/20260813-140214-84c86bc.tsv.

---

## Status 2026-08-13 (LATEST-47) — **Part B B-1 + B-2 LANDED: the hotexit misroute is fixed, the provenance arm closes the full native cycle. nsieve walks ÷6.1, nsieve 9 −21%, sieve_int −20% (board: nsieve 1.9× LJ was 2.7×, sieve_int 1.5× was 2.4×). KNOWN REGRESSION nsieve-bit +17% → follow-up B-4 (trace-quality probation).**

### What landed (Bart: "Ok, go and continue with B") — commits 5e5b7a4 (B-1), c8256fa (B-2a), this commit (B-2b)

Full narrative + the five landing deltas are in doc 17 §B.7; short form:

1. **B-1** — `noteTakenExit` routes on the POSITIVE branch property (`jmp_if_*`
   source); zero-trip `for_prep` guards feed the generic side want. Substrate
   only (telemetry unmoved until B-2).
2. **B-2a** — ProvenanceEdge storage + shared `publishSiblingArm` + lifecycle
   wrappers, flip OFF, byte-identical.
3. **B-2b** — the flip + the deltas found while landing:
   - drain compiles the child on demand via `nativeFor` (a provenance child is
     never dispatcher-selected — waiting for lazy `.compiled` deadlocks
     publication; `.unsupported` deletes the edge per §B.6(5));
   - `noteSiblingTerminal` fires at ANY local count (zero-progress was §S's
     discovery heuristic, not coherence; the gate blocked every cycle's
     CLOSING arm — with it, nsieve walks did not move at all);
   - `provenance_arms_pending` event-driven drain gate (the unconditional
     per-walk edge×armed_links scan measured 5.7% of nsieve-bit wall; set at
     edge append / any physical disarm / in-place sibling re-arm; settles
     after a pass with no transient decline);
   - `armNativeLink` in-place re-arm now releases the displaced sibling latch
     (codex post-landing blocker; sibling→ordinary→sibling→disarm test pins
     1→0→1→0);
   - B-2b can supersede M1 discovery → doc-16 Phase-2 test signals generalize
     to `prime_side_chain_follows + sibling_handoff_fused` and
     `native_source_link_arms + sibling_handoff_arms`.
4. **build.zig: `-Dtest-filter=<substr>`** wired into both test steps
   (verified against the pinned stdlib `Build.TestOptions.filters`).

### Measured (interleaved min-of-21, vs B-1 binary /tmp/mahina-B1)

nsieve 9: 109→86ms (−21%); nsieve 7 −18%; nsieve 3 −19%; sieve_int −20%;
walks at N=9: 330,206 → 53,746 (53,625 at LEDGER_CAP — the full native cycle
scan→cont→skip→scan formed; the ~45k prediction held). All SEVEN output
hashes identical (NB: bench programs live at `bench/*.lua`, NOT
`bench/programs/` — a wrong path hashes the error message and "matches" on
all binaries); aviii/aviii-which=109, floatlink=18135; 853/853 tests both
builds.

### KNOWN REGRESSION — nsieve-bit 6: 31→36ms (+17%), commit shipped anyway (codex recommendation)

Isolated: a relax-only build (arming off) is neutral — the arming causes both
the wins and this. Mechanics (§B.7): the armed cycle halves nsieve-bit's walk
count but (a) pushes more rows through the replayLedger steering grammar
(~14% combined replay+drive in perf), and (b) a second-order hotness shift
lets a low-quality 247-instr root continuation trace (t=5 at pc=58) record
and link; it normal-deopts ~11.7k times at four scattered exits (ei
56/98/140/182), each costing wasted native work + a tier-0 deopt-replay
re-run. Codex verdict: the provenance edges are locally successful; disarming
them for exposing a poor ROOT trace would misattribute the cost. **Follow-up
= B-4 deterministic trace-quality probation** (score native entries against
committed work / normal-deopt frequency / exit dispersion / size; gate or
retire large low-yield roots — general, benchmark-agnostic).

### Open for Bart

- The nsieve-bit +17% ship-vs-block call above was made per the reviewer's
  recommendation — say the word and B-2b flips off (`provenance_arming_enabled`,
  one const) or reverts cleanly.
- Still unanswered from LATEST-46: the two seam-round-2 MINORs (u32 cache_gen
  wrap; hit_count dependence if max_traces_per_anchor >8) and the stray
  untracked bench/results/20260813-140214-84c86bc.tsv.

## Status 2026-08-13 (LATEST-46) — **Seam round 2 closed: ldl memo kept (+inline credit), FrozenFast/act_cache consolidation tried and REVERTED (measured slower). Remaining seam self-time is structural → doc-17 Part B next.**

### What landed (Bart: "do the known things before B first")

1. **`hasNativeLoopDoneLink` memoized per-trace under `cache_gen`**
   (`Trace.ldl_memo`/`ldl_memo_gen`; body split into
   `computeNativeLoopDoneLink`). It ran per native dispatch
   (interp.zig:2848) doing an O(instrs) scan + cache probes. Measured: native
   bucket 51.2M→44.1M cycles at nsieve N=7 (−14%, repeatable via jit-stats).
2. **`creditRegionWork` made `inline`** — called per credited ledger row from
   the frozen fast path; perf annotate showed the call frame as a visible
   slice. Neutral-to-slightly-better (nsieve 9 −1.1%, sieve_int ±0 at
   min-of-41); walk cost unchanged (763 cyc/walk both sides).

### What was tried and REVERTED (kept as a comment in replayLedger)

Serving the FrozenFast walk-prelude from the shared `act_cache` slot via an
extracted `refreshActCache(call_seq)` — replacing the per-walk
`activeRegionFor` map iteration + `region_profit.getPtr` probe with two
compares. **Measured slower**: +51 cyc/walk at N=7 (816→867), +2% wall. The
map has 1–2 entries, so the direct iteration is already cheaper than the
extra layout/branch cost the shared path added. The revert comment sits at
the FrozenFast setup so nobody re-tries it blind. (`refreshActCache` itself
was NOT kept — `qualifiedActiveMember` retains its original inline body.)

NB an important measurement artifact found on the way: restructuring
functions in trace.zig moves replayLedger's code layout enough to shift the
seam bucket ±90 cyc/walk with ZERO functional change (the ldl memo — which
never touches the walk — reproduced the "regression" alone). Judge seam
changes by the native bucket + min run total + interleaved wall clock
together, never by cyc/walk alone.

### Where the remaining round-2 candidates went (profiled at nsieve 9)

- `replayLedger` self 20.5%: **diffuse** — no instruction above 3.1%; it's the
  per-row grammar itself. The lever is fewer walks/rows = Part B, not micro.
- `driveDispatcherLedger` self 5.1%: **skid artifact** — 78% of its samples on
  one unconditional `jmp` right after the `driveBurstCore` call return.
- `wyhash` 1.2%: diffuse (tier-0 interpreter-side lookups mostly).
- `memset` 1.9%: tier-0 array-part growth zero-fill (fresh-nil semantics),
  compulsory work, not seam.

### Gates (all green at this state)

`zig build test` + `-Djit-debug=true` both OK; all SEVEN output hashes OK
(incl. nsieve-bit 6 = 49601107e4d95035 — NB run `bench/luajit/nsieve-bit.lua`,
the 5.4-syntax mahina copy, not the LuaJIT-tree file which needs `bit`);
aviii/aviii-which → 109, floatlink → 18135.

### Next (agreed with Bart)

**Doc-17 Part B: true exit-branch patching** — patch the guard to jump
straight into the side trace/continuation, attacking walk COUNT (98,483
walks at N=7) rather than walk cost. That's where the remaining ~40% seam
share lives.

---

## Status 2026-08-13 (LATEST-45) — **Seam-shrink arc, round 1: four measured memoizations, nsieve 5 −22% / nsieve 9 −18% / sieve_int −16% cumulative. Doc-17 Part B (true exit patching) is the agreed follow-up.**

### Why (Bart: "start with shrinking, B as follow-up")

The new `--jit-stats` seam split + perf agreed: at small N the run is dominated
by the steering seam (`replayLedger` ~48% self at N=3, ~1,279 cyc/walk over
1–3 row ledgers), NOT trace codegen (native bodies ~5 cyc/iter, already below
LuaJIT's whole-run average). Profile-first recipe applied; each step A/B'd
min-of-15 before the next.

### What landed (each general, none benchmark-keyed)

1. **`noteTakenExit` arming-gate reorder** — saturated exits no longer run
   `isSourceBranchGuardExit` + `countTracesAt` per receipt; decode/scan only
   when a want could actually be set.
2. **`anchorPopulation` memo** — `cache_gen` (bumped on cache append/remove/
   clear) + per-trace `anchor_pop_*`; steady-state anchor-population query is
   one gen compare instead of an O(cache) scan per receipt.
3. **`maybeArmCompositeExit` already-armed early-out** — every burst's
   terminal composite deopt was re-running the whole arm pipeline
   (classifyExit → def/profit hash probes → `validateRegionBridge` full
   structural proof, 2.4% of N=5) to supersede an identical arm.
4. **`.region_bridge` row memo** — the slow row resolution (provAt → def
   lookup → members scan with `exitOrder` compares) is a pure function of the
   armed link + `region_defs`; memoized on `NativeLink`
   (`bridge_edge`/`bridge_edge_gen` stamped with `region_defs_gen`), dropped
   on re-arm supersede; steady-state row = gen compare + succ check. All
   release-panics intact on the slow path.
5. **O(1) `traceById`** — `trace_by_id` id-indexed array (ids monotonic,
   never reused); fail-soft (grow-OOM or hand-built test traces fall back to
   the linear scan); nulled on remove, cleared wholesale on `clearCache`.

### Measured (min-of-15, --trace --jit-native, vs pre-seam e3316c2 binary)

nsieve 3: 3.5→3.0 (−15%); nsieve 5: 11.2→8.7 (−22%); nsieve 7: 38.0→30.6
(−19%); nsieve 9: 142.8→116.6 (−18%, LuaJIT 144.2 same harness); sieve_int:
64.4→54.3 (−16%); nsieve-bit: 31.5→31.6 (flat). Per-step deltas in the git
log. N=3 seam: ~1279→~1132 cyc/walk, run total 24.8M→19.1M cycles.

### Gates

Tests green both builds; seven output-identity hashes byte-identical; A-viii
109/109; floatlink 18135.

### Still on the table (seam round 2 candidates, unstarted)

- `replayLedger` self still ~20%: FrozenFast setup hash probes per walk
  (consolidate with `qualifiedActiveMember`'s act_cache), per-row
  `accountLedgerRow` residue, `driveDispatcherLedger` 6% self.
- wyhash ~3%: remaining region_profit/defs probes.
- Then: doc-17 Part B true exit-branch patching (the structural fix — longer
  bursts, fewer walks).

---

## Status 2026-08-13 (LATEST-44) — **Pall-faithful hotexit landed: one per-(trace,exit) taken-exit counter (`snap->count`), threshold 10, DONE latch at side-trace commit, productive receipts never strike. Small-N warmup fixed (nsieve N=3: scan loop 0%→94.5% traced, −17.5% wall). All green, all six hashes identical.**

### Why (Bart: "the most correct change — start with what Pall does")

The N-sweep showed mahina's small-N nsieve gap is not process startup (0.34ms vs
LuaJIT 0.30ms empty script) but the scan loop never tiering up below N≈7: at
N=3 its receipts are all `completed=1..5` (prime-gap segments, below
`min_useful=8`), every one struck, the anchor gated within 8 receipts, and a
gated anchor gets no dispatch, so exit hotness never accrued (38 traced vs
140k interpreted iterations). Read the source (`~/Projects/LuaJIT/src/
lj_trace.c`): `trace_hotside` (:798) counts EVERY taken exit
(`++snap->count >= hotexit(10)` → side trace), `SNAPCOUNT_DONE=255` latches at
side-trace link (:535), and `penalty_pc` fires ONLY on recording aborts.
LuaJIT has NO per-segment productivity strike machine — ours was the non-Pall
invention.

### What landed (this commit)

1. **`Trace.exit_counts: []u8`** — Pall's `snap->count`: one taken-exit counter
   per committed instr, alloc-once at commit (fail-soft), one byte RMW per
   receipt (no hashing — the Part S lesson). `EXIT_COUNT_DONE=255`.
2. **`config.hotexit = 10`** (lj_jit.h `JIT_P_hotexit`).
3. **`noteTakenExit(t, exit, completed, proto)`** — the single per-exit hotness
   charge, called from interp step-4 (scalar) and the driveDispatcherLedger
   terminal (bursts; now charges productive terminals too), loop-done exits
   excluded (continuation territory). **Routing (the shape-fidelity rule —
   found the hard way):** Pall records FROM the exit, so his side trace is the
   right shape by construction; we route to whichever recorder captures the
   right shape: source-branch guard → `wants_prime_side` (doc-16 immediate
   replay of THIS iteration); other guard + zero-progress → `wants_side_trace`
   (resume-timed replay of the failing iteration); other guard + productive →
   count only, NO want (the back-edge recorder captures the NEXT iteration —
   wrong shape; first cut routed branch exits there and collapsed nsieve's
   entire fusion: bridge arms 25 940→0, +53% wall).
4. **DONE latch** — want carries `(parent trace, exit)` provenance
   (`side_want_src`/`prime_want_src` → `pending_replay_src` →
   `Recorder.side_src`); commit latches the parent exit `EXIT_COUNT_DONE`.
   Abort drops it (Pall retries; abort's own `gateAnchor` is our `penalty_pc`).
5. **Productive receipts never strike** — `accountLegacyThrash` returns before
   the penalty bump when `completed > 0`. Zero-progress strikes stay (our exits
   re-enter the runtime, LuaJIT's are patched branches) with Option-A headroom,
   now `max_penalty +| hotexit`.
6. **Removed:** `countProductiveBranchExit` + `prime_exits` map +
   `clearPrimeExits` (the hotguard-50 prime counter — redundant, one counter
   now), `shape_guard_exit_pc` sentinel (subsumed by per-exit counting).
7. Four tests re-pinned from "short productive segment strikes" to the Pall
   semantics (null penalty).

### Measurements (min-of-21 vs /tmp/mahina-optA = prior commit, /tmp/mahina-hotexit3)

nsieve 3 −17.5%, nsieve 7 −4.4%, nsieve 9 −0.6%, nsieve 10 −1.9%; sieve_int/
pi_leibniz/grid_matmul/nbody flat (±2%). N-sweep ratios vs LuaJIT: N=1 2.3×,
N=3 3.3×, N=7 2.9×, N=9 1.1×. nsieve:14 at N=3: 0.0% → 94.5% traced-it;
whole-run as-trace 5.9% → 60.9%. Remaining small-N gap is recording/compile
warmup + per-transition overhead ("other (non-loop)" 18.6% at N=3), not
coverage starvation.

### Gates

`just test` green (also `-Djit-debug=true`); A-viii repros 109; floatlink
18135; all six output-identity hashes byte-identical.

### Fix-up commit (same arc): nsieve-bit panic + codex review findings

The full board caught a panic the six-hash gate missed (nsieve-bit wasn't in
it — it is now, hash 49601107e4d95035): `replayLedger: terminal loop-done
carries an invalid continuation`. Ledger `[2.deopt/23 → 3.link_terminal/48 →
0.loop_done_linked/33]` — a hotexit-armed prime-side composite (anchored at
the GUARD pc, ends `.link`) enters the linked grammar via `.link_terminal`,
which sets `cont = owner`; the inner's terminal loop-done then requires `cont`
anchored at its post-loop pc and release-panicked. The shape is legitimately
reachable (not a wiring bug) once prime sides arm at threshold 10; the old
hotguard-50 machinery just never recorded one here before the run ended.
Fix: the terminal validates the full continuation contract (same P-G
eligibility `armLoopDoneLink` enforces) and on mismatch returns `.break_burst`
— tier-0 resumes at `post_pc`, where regs are coherent regardless of `cont`
(the same directive the hop-budget bound takes; the site-3 arm was already
fail-closed via P-G, so no bogus native edge ever armed). Non-last fused
successor validation stays a panic (arm-time-validated). Also from the codex
84c86bc review: `noteTakenExit` now increments BEFORE the capacity check (Pall
counts every non-DONE exit; cap suppresses arming only), and `abort()` /
`closeTrace()` clear `rec.side_src` so a dropped recording can never latch a
later commit's parent exit DONE. Plus two permanent jitdbg probes (per-row
ledger dump, invalid-cont diagnostic). **nsieve-bit min-of-15: 58.9 → 31.9ms
(−45.7%)** — the prime-side fusion the panic was blocking. nsieve/sieve_int/
pi_leibniz unchanged (±2%).

### Follow-ups (noted, not started)

- driveChain inner receipts (mid-chain deopts) still charge no exit hotness.
- `countFingerprintMiss` + sibling-watch still at hotguard=50 — candidates for
  the hotexit threshold, measured separately.
- The remaining `min_useful` uses (flushRegionWindow window verdict, hit_count
  gating) are burst-level and stay.

---

## Status 2026-08-13 (LATEST-43) — **Option A: guard-failure-aware gating. nsieve −48%, sieve_int −32%; nsieve now at/below LuaJIT wall-clock on this box (nsieve 9: mahina 136ms vs LuaJIT 144ms; nsieve 10: 266ms vs 427ms; sieve_int parity 63ms vs 62ms). All green, all six hashes identical.**

### The problem (diagnosed last arc)

nsieve creates `local primes = {}` ONCE and reuses it across 3 sieve sizes. The
first size records the init loop (`for i=2,m do p[i]=true end`) append-shaped
(`guard_append`+`astore_append`). Sizes 2/3 hit in-bounds OVERWRITES →
`guard_append` fails at i=2 → zero-progress receipts → the legacy 8-strike gate
condemned the anchor before side-trace hotness (`hotguard=50`) could fire.
Worse: array/shape guards store a lane ordinal in `aux`, not a PC, so
`guardExitPc` returns null and they never charged `countGuardFailure` AT ALL —
side-trace hotness was structurally impossible for shape mismatches. Result:
~36% of the run (init loop, anchor nsieve:4) pure tier-0.

Bart picked **Option A** (LuaJIT's model: a hot guard exit gets its own
hotcount and spawns a side trace; the parent anchor is never blacklisted for
it) over B (count shape-guard exits toward the existing per-PC hotness) and C
(reset the strike counter on side-trace record).

### What landed (this commit)

1. **`shape_guard_exit_pc` sentinel (`maxInt(u32)`) + `isSideExitGuardOp`**
   (trace.zig, next to `guardExitPc`) — the 19-op guard-family predicate.
2. **Sentinel hotness charges** — both zero-progress charge sites (interp.zig
   scalar step-4 + `driveDispatcherLedger`'s ledger terminal) gained an
   else-branch: a side-exit guard WITHOUT a PC charges
   `countGuardFailure(anchor, shape_guard_exit_pc)`. Shape mismatches can now
   reach `hotguard` and trigger `wants_side_trace` → resume-timed side record.
3. **Widened legacy gate under side headroom** — `accountLegacyThrash` takes
   the receipt's `exit_instr`; when `completed == 0`, the exit is a side-exit
   guard op, and `countTracesAt(anchor) < max_traces_per_anchor`, the gate
   threshold becomes `max_penalty +| hotguard` (58) instead of 8 — the
   side-trace machine wins the race. Genuinely thrashing anchors still gate
   (bounded), and once the anchor is at trace capacity the plain threshold
   applies. Threaded `exit_instr` through `onSideExit` (maxInt),
   `onSideExitReceipt` (its param), `accountLedgerRow` (+param: `e.exit` on
   `.deopt` arms, maxInt on loop-done/prologue-fail arms).

Verified live (`--jit-debug`, nsieve 2): strikes climb `penalty=N/58`, at 51
(one past hotguard) the next entry runs `local=19947` — the overwrite side
trace recorded and completes the whole init loop natively; third size selects
it after ONE strike. `--jit-stats` nsieve 9: anchor nsieve:4 went 3.9% → 53.9%
traced-time, its run share 37.8% → 6.1%; whole-run traced time 69.1%.

### Measurements (min-of-21 vs /tmp/mahina-memo1 = prior commit, /tmp/mahina-optA)

nsieve 9 −47.8% (259.8→135.7ms), nsieve 10 −47.1% (503.0→266.2ms), sieve_int
−31.8% (92.3→62.9ms), pi_leibniz +0.3%, grid_matmul −1.7%, nbody +2.7% (noise;
no coverage there). LuaJIT same harness: nsieve 9 144.2ms, nsieve 10 426.8ms,
sieve_int 62.1ms.

### Gates

`just test` green (also with `-Djit-debug=true`); A-viii repros print 109;
floatlink prints 18135; all six output-identity hashes byte-identical.

### Next levers (unchanged)

nsieve:14 residual (96.1% it-traced but 73.6% time-traced — exits/seams);
tier-0 dispatch (threaded/computed-goto); replayLedger walk self-time;
dynamic-proto gate for scimark (53% of suite runtime, 0% coverage).

---

## Status 2026-08-13 (LATEST-42) — **THE TRACES FUSE. Part S sound + armed, the third nsieve shape records (zero-trip for_prep record-through), and the per-row pricing seam is KILLED (freeze-after-qualify). nsieve/sieve_int ~14–27% faster than the pre-S baseline. All green, all six hashes identical.**

LATEST-41 below is **stale in its central verdict**: the §S premise was NOT
falsified and the handoff is NOT unsound. The A-viii 108-vs-109 drop was
`replayLedger`'s terminal arm resuming at a stale `link_pc` when a burst mixed
`.link_terminal` rows with a later handoff row — fixed by entry-provenance
(`next_via_handoff`, mirroring the `entered_via_bridge` precedent). Arming is
back ON. Full story in the `sibling_handoff_arming_enabled` doc comment.

### What landed this arc (all uncommitted → this commit)

1. **Part S soundness fix** — entry-provenance in `replayLedger`: a handoff
   successor terminal-resumes at its ANCHOR, never `link_pc`. A-viii prints 109.
2. **Part S arming re-enabled** with hardened eligibility: the guard's source
   opcode must be a real conditional branch (`jmp_if_*`) — a `for_prep`-sourced
   zero-trip check ping-pongs to LEDGER_CAP (measured +128% before the rule).
3. **Ledger-path guard-failure hotness** — `driveDispatcherLedger` charges
   `countGuardFailure` for zero-progress normal deopt terminals (the scalar
   step-4 site never runs for `ledger_len > 1`), so side traces can get hot
   from fused bursts. Plus `max_traces_per_anchor` moved to config (default 4).
4. **Resume-timed side recording** — `consumeSideTraceWantAtResume`: consume
   `wants_side_trace` at the deopt RESUME (recording the failing iteration's
   re-run), not the next back-edge (which records the wrong shape). Arms via
   `pending_replay_anchor` + `.switch_mode` so the recorder actually runs.
5. **Zero-trip `for_prep` record-through** (the recorder frontier): the
   recorder no longer force-closes with `.link` at every `for_prep`. It decides
   the direction with the SAME value ops tier-0 uses; a zero-tripping loop is
   recorded as the plain `sub` + fall-through, and `recForLoop` is now
   polarity-aware (`guard_false` on the continue test, `R[a+3]` NOT published,
   recording continues straight-line). nsieve's third shape (prime with
   `i+i > m`) records and compiles.
6. **Freeze-after-qualify (the seam kill)** — `RegionAccum.frozen` latches
   after `config.freeze_windows` consecutive useful windows; `replayLedger`
   then prices member→member rows through a direct-credit fast path (no
   classifyExit / chooseSource / destination hashing; membership via per-trace
   `region_memo_*` keyed on `region_defs_gen`). Any strike unfreezes.
   `accountRegionProfit` fell 18.1% → 0.0% of nsieve wall-clock.
7. **`noteSiblingTerminal` reject memo** — single-slot ineligible-exit memo on
   Trace (`sibling_reject_exit`); 84k/run eligibility re-scans → one compare.
8. **`qualifiedActiveMember` activation cache** — single-slot (`act_cache_*`),
   invalidated in `freeObserverFast` (every `region_profit` mutation funnels
   there) + the qualification flip + `region_defs_gen`.

### Measurements (min-of-21, vs /tmp/mahina-memo1 pre-S baseline, noisy box)

nsieve 9 −14…−23%, nsieve 10 −14…−26%, sieve_int −23…−42%, pi_leibniz ~0.
Profile after: `accountRegionProfit` 0%, `replayLedger` self ~13%, tier-0
`execImpl` ~25% — the next seam is tier-0 dispatch + the remaining ledger walk.

### Gates

`just test` green; A-viii repros (`/tmp/aviii.lua`, `/tmp/aviii-which.lua`,
`--trace-hotguard 3`) print 109; all six output-identity hashes byte-identical
(nsieve 4053ed86223d7060, nbody 9dcd7fa2f7e9e93e, sieve_int db55c0f98f98851b,
pi_leibniz f57ace5316c0fd19, grid_matmul 395ff5566b31eb18, field_hash
89b64d3d25ae188f).

---

## Status 2026-08-13 (LATEST-41) — STALE (kept for the diagnosis trail; central verdict disproved above) — **Part S BUILT and MEASURED. The "50% = runtime re-entry" premise is DISPROVED, and the handoff is UNSOUND. Arming is off (`sibling_handoff_arming_enabled = false`); everything else is landed and green.**

### 1. The premise behind Part B is wrong

Part B assumed the ~50% seam is the cost of *returning to the runtime* per burst,
so fusing bursts would eliminate it. Built it; measured it. On nsieve N=9:

| config | bursts | traced time | wall-clock |
|---|---|---|---|
| pre-Part-S | 641,431 | 51.0% | 243 ms |
| handoff, first accounting | 25,595 (**−96%**) | 7.2% | 307 ms (**+18%**) |
| handoff, accounting fixed | 330,000 (−48%) | 52.7% | 231 ms (−7.3%) |

**96% fewer bursts made it 18% SLOWER.** Dispatcher re-entry is not the seam.
What the seam actually is: per-ROW pricing (`accountRegionProfit` 15–18%,
`replayLedger`, hashing) — and fusion does not remove rows, it only moves them
between bursts. In the middle row above the seam *looks* eliminated
(`accountRegionProfit` 17.7%→1.5%) purely because the JIT stopped running.

Corollary for whoever picks this up: **the remaining lever is per-row pricing
cost or the freeze, not burst count.** Task #72 (hoist the per-row hashmap
lookups) is on the real critical path; Part B's fusion is not.

### 2. Two accounting bugs found (both real, both fixed)

- `accountLedgerRow` on a handoff row applied the legacy-thrash VERDICT to a
  zero-progress TRANSITION → a penalty strike per fused hop → `pc=14` hit
  `max_penalty`, the anchor gated, traced time collapsed 51%→7.2%. A fused
  handoff never reaches the runtime and must be invisible to profitability;
  it now charges `accountTraceRun` only.
- The production never advanced `prev_cum`, so the sibling's row re-counted the
  parent's committed iterations.
- Also: the charge site must be `driveDispatcherLedger`, NOT `replayLedger` — a
  walk can return a directive from an interior row and never visit the last one.
  Sited in the walk it saw 25,939 of 330,000 terminals and the dominant exit
  could never qualify.

### 3. The handoff is not semantics-preserving — this is the blocker

With the charge site fixed so every terminal is observed, **A-viii prints 108
where the unfused run prints 109**: one iteration silently dropped. §S's stated
coherence condition is "a zero-progress pre-effect deopt is coherent at the
anchor". Both halves were then implemented, and **both are insufficient**:

- static: `exitIsPreEffect` (no `astore`/`astore_append`/`hstore`/`gstore`
  precedes the exit) — still 108.
- runtime: `term_local == 0` at the charge site — still 108.

So the premise is falsified, not under-enforced. Some state the sibling's
`ordinary_entry` needs is not reconstructible from a carried-homes flush, and
identifying it is the open work. This is §S.8's "true per-exit snapshots"
deferral turning out to be load-bearing — which is what codex round 1 said.

Note the first cut passed the suite only by luck: it armed exactly ONE exit.

### 4. What is landed (green, arming off)

`sibling_handoff_arming_enabled = false` in src/trace.zig. Kept because it is
the part that is right: `ArmKind.sibling_handoff` + arm-time validator, the
three-scalar allocation-free watch on `Trace` (`sibling_watch_exit/_count`,
`sibling_arms`) replacing the hashmap whose per-receipt probe was itself worth
15%, `clearSiblingLatch` on every disarm path, `exitIsPreEffect`, the replay
production, and the M1 sub-case (b) interaction fix. Suite green; all six
output-identity controls unchanged.

### 5. Open question for Bart

Three ways forward, no recommendation: (a) close the soundness hole with real
per-exit snapshots (the original Part B, largest job); (b) drop fusion and go
after per-row pricing cost directly, which is where the measurement now points;
(c) leave Part S inert and pick a different lever entirely (e.g. the parked
dynamic-proto gate blocking SciMark — 53.5% of suite runtime at 0% coverage).


## Status 2026-08-13 (LATEST-40) — **Part S designed + twice-reviewed, ready for S-a. The whole 50% seam is TWO exit sites; the fix is a native sibling handoff compiled into the deopt stub.**

**Bart's mandate (verbatim intent):** "every single program will eventually hit
this problem we have on nsieve … do whatever we need until we have part B and
that 50% is eliminated." Standing autonomy: fix codex findings with best
judgement and proceed.

**What landed (3c17238):**
1. **Burst-terminal telemetry probe** (`dbgNoteBurst`/`dbgDumpBurstStats`,
   jitdbg-only, permanent). nsieve N=9: **641,431 bursts, ALL terminating at
   t=4 ei=9 (337k) or ei=16 (304k)** — two deopt exits of the prime-found
   continuation at anchor pc=14. One runtime turnstile visit per prime.
2. **doc 17 §Part S** — the design, with two codex `gpt-5.6-sol` REJECT rounds
   folded in and recorded inline. Round 1's central finding SIMPLIFIED the
   design: a zero-progress pre-effect deopt is coherent at the ANCHOR
   (interp.zig:3224) — no gap to record, no stitch traces, no per-exit
   snapshots; the sibling trace already IS the alternate path; doc 16's
   runtime coherent-anchor chain just needs compiling into the exit stub.

**The S-a implementation contract (round-2-pinned, START HERE):**
- Pre-effect eligibility bitset per trace (pattern: §T.9 `bridge_cand` memo) —
  exit index eligible iff no effectful op precedes it (anchor-coherent at any
  iteration count; verified nativegen.zig:4554-4592/4729-4739/2397-2425).
- New counter keyed `(parent Trace.id, exit_instr)` charged EXACTLY ONCE per
  receipt: replayLedger's terminal normal-deopt arm ∪ interp's scalar
  zero-exit branch (mutually exclusive — interp.zig:3010 returns before 3017).
  Parity test required. `guard_failures` is NOT reusable (aliases by
  (anchor,exit_pc), stops at 2 traces, blind to ledger terminals).
- `ArmKind.sibling_handoff` + **separate slot namespace** (slot[ei] is
  loop_done_linked-reserved, trace.zig:1211/6511; ordinary loop-done deopts
  bypass to shared_exit, nativegen.zig:4653).
- Stub (S-b, but emitted inert in S-a with slot hard-wired to shared exit):
  load slot → armed test → armed: append `.sibling_handoff`, forced-yield
  check (target in rax, may rewrite + stamp `.yielded`), `jmp rax` (precedent:
  loop-done-linked site nativegen.zig:4762, NOT A2.4); unarmed: append
  `.deopt`, shared exit — byte-identical today's row.
- Zero-input siblings only (`inputs.len == 0` — ordinary_entry cannot seed;
  interp.zig:885-929, trace.zig:3697/4265/6650).
- S-b arm: one-shot pending `(parent, exit)` set at terminal consumption;
  armed at the dispatcher's ACTUAL successful sibling entry
  (nextTraceExcluding site, interp.zig:2737-2762); safe_to_arm at slot write;
  cleared on departure/frame death/epoch.
- Ledger: `LedgerKind.sibling_handoff` — non-final: next row same-anchor;
  final: `.yielded` only. Accounting: `region_work = local`, one
  `accountLedgerRow`, destination **`.deferred`** (never `.known_trace` — the
  generic rule at trace.zig:4051 would let applyDestination reproduce the
  §A8-v cross-credit pathology).
- **Freeze DEFERRED to v2** (would remove the barren decay detector,
  trace.zig:3328; design v2 after S-b's measurement, with close-remainder
  policy trace.zig:2748 explicit).

**Pre-registered expectation:** dispatcher entries ÷≈9 (avg burst 3.58 rows →
LEDGER_CAP=32); per-row pricing (~26% of wall) SURVIVES until freeze v2. Six
workload hashes must stay: nsieve=4053ed86223d7060, nbody=9dcd7fa2f7e9e93e,
sieve_int=db55c0f98f98851b, pi_leibniz=f57ace5316c0fd19,
grid_matmul=395ff5566b31eb18, field_hash=89b64d3d25ae188f (ReleaseFast,
`--trace --jit-native`, run each command individually).

**Also this session:** Part T formally superseded (twice-rejected; §Part T
kept as review record); §T.9 seam profile; bridge-candidate memo (a0cedc8,
nsieve −6.3%, sieve_int −8.9%); codex full-suite finding parked: SciMark = 53%
of suite runtime with ZERO coverage (dynamic-proto gate, `arm()` trace.zig
~7037 + load.zig:118) — separate lever, H-2 hard half, NOT part of this arc.

## Status 2026-08-13 (LATEST-39) — **Part T rejected TWICE pre-implementation; profiling the seam it targets changed the plan. First "free" memoization landed: nsieve −6.3%, sieve_int −8.9%, zero contract change.**

**What happened.** Bart's lever ("LuaJIT does the B part right — not having to
go through the runtime is the single highest lever") became Part T:
commit-once transitions, LuaJIT `SNAPCOUNT_DONE` semantics. He chose
"commit-once first, then patching." Two codex `gpt-5.6-sol` pre-implementation
reviews **rejected** it (3 BLOCKER + 3 MAJOR each round). The two corrections
that mattered — both were my errors, recorded inline in doc 17 §Part T rather
than edited away:

1. *"Worst case is mis-tiering"* was **false**. A terminal `.loop_done_linked`
   returns a specific sibling `*Trace`, and fused M1 sub-cases (b)/(c) resume at
   the **predecessor's** anchor — so a lossy summary can double-commit
   iterations and **corrupt `regs[]`**.
2. *"Qualified hop receipts are accounting no-ops"* was **false**. Consumed ≠
   no-op: they still credit work, reset `barren_run`, flush windows, drive
   `applyDestination`, update coverage/`hit_count`.

Round 2 still REJECT (barren interleavings vs a bulk aggregate; terminal
`ChainResult.completed`; the bridge two-cell reservation at nativegen.zig:4675;
per-receipt `hit_count`). **Part T has NOT proceeded to T-a.**

**The thing I should have done first (doc 17 §T.9).** Two designs rejected on a
mechanism whose payoff split was never measured — against this project's own
"profile FIRST" rule. Per-symbol attribution of the 50.1% seam says it is *not*
mostly "walking rows": ~**15%** of wall-clock is pure lookup/validation that is
memoizable with **no contract change, no determinism argument, no
accounting-equivalence proof**, and only ~20% is what Part T's contested
contract buys. Bart chose **"take the free 15% first."**

**Landed (a0cedc8).** `isCompositeBridgeCandidate` — a pure function of
immutable recorded data ending in an O(`instrs`) scan, called per receipt from
seven hot sites, 4.68% of wall — is now a per-trace bitset built at commit
(`buildBridgeCandMemo`), read via `Trace.isBridgeCandidate`. The oracle remains
the definition: unbuilt memo falls back to it, the build is fail-soft, codegen
and all existing tests still call it directly, and a new differential test
asserts memo == oracle at *every* index across unbuilt/true-bit/all-false/empty.
Measured ReleaseFast best-of-15 A/B: nsieve 9 **−6.3%**, nsieve 10 −3.4%,
sieve_int **−8.9%**, pi_leibniz +0.1% (correct negative control — one tight
loop, no bridge traffic). Six workload hashes identical to the frozen controls.
Both gates green. `perf` confirms the symbol is gone from the profile.

**Next (task #72, not started).** Remaining memoizable pool ≈ 9%: hashing 6.44%
(`wyhash` 4.11 + `auto_hash` 2.33, essentially all per-receipt map lookups —
`classifyExit` = one `source_exit_regions.get(ExitKey)`, plus
`region_profit.getPtr`) and `qualifiedActiveMember` 2.44%. The shape is an
ObserverHot-style inline cache, but `classifyExit` returns a **slice into map
storage** and `getPtr` a **map-interior pointer**, so it needs a generation
counter bumped on every mutation of those maps — start fresh, that hazard class
deserves its own careful increment. `accountRegionProfit` now reads 20.18% (was
16.04%) purely from the shrinking denominator, not a regression.

**Do not commit** `bench/results/20260813-050325-44da392.tsv` as-is: the harness
stamped it with the baseline commit while measuring the uncommitted memo build.

## Status 2026-08-12 (LATEST-38) — **The region-profit gate FIX landed: the gate was condemning its own region. After the codex review round: nsieve −29% (103.2 → 73.2ms), sieve_int −37% (41.1 → 25.7ms), links persist for whole sieves, nsieve:14 coverage 2.4% → 91.5%.**

**Codex post-landing review: 2 BLOCKER + 2 MAJOR, all four fixed same-session
(doc 17 §A8-v has the full record):** (1) fallback receipts now thread the live
activation through to `applyDestination` as the effective source (was: foreign
dest could open a second accumulator at one call_seq; the fix also killed the
per-receipt no-op `openRegion`, worth a further −12% on nsieve); (2)
`barren_run` + `max_barren_run=64` — a consumed-barren streak with no credit
flushes a synthetic low-yield strike, so a qualified activation that decays is
still priced (the post-qualification thrash hole); (3) qualification amnesty —
the first useful window clears legacy penalty/gate on every member anchor
(`clearMemberAnchorState`), killing the latent stale-penalty re-gate; (4)
publish-phase `closeNonArmableAccumulators` — a rebuild that un-arms/tombstones
a def closes its live accumulators (no resurrection with `useful_window_seen`
latched). All re-measured + hashes verified after the round.

Bart's mandate: "the only thing the fix set out to do failed… try to fix it
again — maybe now constantly checking soundness *and* profitability." Both
gates (`just test`, `zig build test -Djit-debug=true`) plus counters + raw
wall-clock + output hashes were re-run after **every** change. Four fixes, all
in src/trace.zig, all general mechanisms (Z-6) — full record in doc 17 §A8-v:

1. **`chooseSource` no longer closes the live accumulator on UNCLASSIFIED
   exits** (ephemeral-edge-cache miss = "no information", not "we left").
   Tombstoned/vanished defs still close immediately (positive evidence; pins
   test (5e)). Window strikes 3,603 → 0, mid-run `disarmAllLinks` 703 → 0.
2. **`armLinkTerminal` (arm site 4)** — the `.link`-terminal edition of site 3's
   loop-done convergence; previously 6,931 spans/run died unarmed at the prime
   ramp's `.link`, one runtime seam per prime.
3. **Consumption boundary revised** (the big one): (i) zero-work member
   receipts of a QUALIFIED activation (`useful_window_seen`) are consumed —
   they're polarity-flip transitions, not thrash; unqualified activations keep
   full pre-flip legacy gating (A-vii-c blocker shape stays gated); (ii)
   unclassified nonzero-work receipts from traces anchored in the live
   activation's `member_points` footprint credit the accumulator
   (`regionMemberTraceAnchor`); (iii) null-keyed synthetic steering charges
   (`onSideExit(ramp,0)`/`(seed,0)`) on member anchors of a live qualified
   activation are region-owned (`qualifiedActiveRegionOwns`). Before: 94k
   `completed=0` legacy strikes/run kept re-gating (exponential backoff →
   permanent abandonment) the scan anchor the region machine had just
   qualified. Pinned by the new "gate-fix consumption boundary" test (a–g).
4. **`openRegion` refreshes the observer cache only on real map mutation.**
   THE PROFITABILITY TRAP OF THE ARC: after 1–3, coverage exploded (91.5%
   traced, fused source ≈ every prime, disarms 0) and wall-clock got *WORSE*
   (+12% N=9) — `applyDestination` no-op re-opens the active region once per
   fused receipt, and each re-open freed + reallocated the observer bitset and
   killed `ObserverHot` (9.6% of wall). Coverage converted only after this fix.

**Measured** (interleaved A/B vs /tmp/mahina-fast2 = 182cb87+49f3984): nsieve N=9
0.32 → 0.30–0.31s raw; full suite nsieve −19.6% (103.2 → 83.0ms), sieve_int
−25.9% (41.1 → 30.5ms), all else within ±3.3%. Six-workload output hashes ≡
frozen controls. New permanent dbg probes: gateAnchor, legacy-strike,
window-strike, close-reason (chooseSource/applyDestination/openRegion/drop),
unclassified-exit, barren-*, openRegion.

**Where nsieve stands NOW (profile on file, §A8-v):** per-receipt accounting is
the bottleneck — `accountRegionProfit` 17.8% self + hashing ~11% +
`replayLedger` 8.1% + `runCapturingLedger` 4.0%; 91% native coverage buys only
−20% wall because every fused receipt runs classify/choose/apply-destination
with several hashmap ops. Next levers, in order: (a) steady-state receipt fast
path (one-entry cache in the e.1/e.2 mold, pure accelerator); (b) §A2.4/Part B
exit-branch patching, which removes the runtime from steady-state transitions
entirely. Residuals: 51 strikes/run at pc=14 remain (inter-activation,
pre-qualification) → 7 transient gates; anchor pc=29 gets gated 545× (t=2
continuation receipts arriving with no live activation) — worth a look in the
next arc; the "region decays after qualifying" shape is priced only at close
(remainder flush) — noted in §A8-v as an accepted weak spot.

## Status 2026-08-12 (LATEST-37) — **A-vii-e.2: the region observer's per-instruction CALL is gone. nsieve −27%, sieve_int −28%, everything else flat. Started as "do the §A2.4 native in-page handoff"; the profile said otherwise.**

Bart asked for the §A2.4 native in-page handoff (doc 17's stated payoff for the
A-vii bridge). Profiled first, per the project recipe — and the handoff is not
where nsieve's time is:

1. **`observeRegionProgramPoint` was 43.5% of nsieve N=9**, more than the whole
   interpreter dispatch (`Vm.execImpl`, 31.7%). A-vii-e.1 removed the hashmap
   walk but left a real *call* per interpreted instruction; `perf annotate` puts
   ~70% of that 43.5% in the call's own prologue/epilogue (`push rbp` + five
   callee-saved pushes + `sub rsp, 0x68` — a frame sized by the cold slow path).
2. **Fix = `ObserverHot`**, a one-entry inline cache over e.1's spans: the span
   that answered the last survive verdict, keyed by the *whole* query
   (`proto_id`, `depth`, `call_seq`) + precomputed `base_pc`/`span_pcs`. Only a
   `true` must be sound; a `false` defers to the real observer, which still owns
   every close. Invalidated wholesale in `freeObserverFast` (sole owner of the
   borrowed bitset), so it cannot dangle or outlive its `ObserverFast`.
3. **Call-site ORDER is load-bearing** — the first attempt probed the hot cache
   *before* the `region_profit.count()` test and touched a second `TraceState`
   cache line on every instruction of every region-free program: a uniform
   **+11%** on scimark-sor tier-0 (interleaved A/B). Empty-map test stays first.
4. **Measured** (min of two interleaved full-suite runs per binary): nsieve
   −27%, sieve_int −28%, all others within ±4%, tier-0 flat. Raw nsieve N=9
   0.43s → 0.31s.
5. **Determinism**: six workload hashes unchanged, tier-0 ≡ native, and every
   `--jit-stats` event counter bit-identical (33662 entries; arms
   335/1320/2282/2267; fused 5824/12630/14724; 6204 disarms; peak 4) — the
   accelerator changes no tiering decision. Tests: an inline-cache boundary test
   plus a **differential** test (one query stream through the interp.zig call
   site vs the bare observer on two identical states → equal accumulator state
   and flush history). `just test` + `-Djit-debug` green.

**Where nsieve stands now** (this is the honest next-lever list, and it is NOT
the in-page handoff): the observer is gone from the profile; the run is 70.6%
`Vm.execImpl` + ~16% out-of-line arith helpers (`arith.lt`/`le`,
`value.compareNumeric`). Per-anchor, **nsieve:14 — the branchy outer scan — is
63.7% of the run at 0.7% traced iterations** (8.9M interpreted iterations), while
nsieve:24 is already 94.9% traced and costs 21.5% of its anchor's time. So the
gap is (a) tier-0 dispatch + arith, and (b) why the outer scan trace almost never
runs. Also worth noting for §A2.4 itself: the bridge stub at `nativegen.zig:4691`
**already** ends in `jmp qword [rdx+exit_target]` — an in-page native→native
handoff to `skip.ordinary_entry`. Doc 17's "each bridge firing still crosses the
runtime seam" line needs re-grounding against that before any §A2.4 work starts.

## Status 2026-08-12 (LATEST-36) — **A-viii round-2 revision (codex round 2 = CHANGES REQUIRED: 3 MAJOR + 1 MINOR). §A8 step 8 stays ticked; the bridge residual is now its OWN Outstanding bullet in doc 17 instead of being absorbed into a ticked step.**

1. **MAJOR — `entries` cannot carry R2-4.** True: it's bumped at
   `interp.zig:2785` BEFORE the dispatcher chooses native vs tier-1a, so a run
   that fell back to the IR interpreter every time would still advance it.
   Added **`TraceState.native_entries`**, bumped only where `nativeFor(ct)`
   resolves and `ran_native` is set; the mid-epoch test now pins THAT advancing
   across the window-open event. Also printed in `--jit-stats` next to
   `entries`.
2. **MAJOR — the unit test's physical slot shapes were still fake.** All three
   traces shared one guard array, so the "bridge" slot was physically a
   loop-done guard and the "terminal" slot a `guard_true`. Rebuilt with a
   per-trace IR array: genuine numeric-for loop-done guard for `inner`, terminal
   `.link` op for the C⇄I back edge, a real `isCompositeBridgeCandidate` guard
   (full `recForLoop` shape: dominating loop-continue guard consuming the
   stepped index + slot-bound phis for both `for_loop`-written slots) for edge
   4, plain non-composite guard for the ramp. All four now arm **through
   `armNativeLink`** — every kind's validator runs for real, nothing is
   hand-appended to `armed_links`.
3. **MAJOR — the bridge residual vs "A-viii complete".** Resolved by tracking:
   the residual is now its own `- [ ]` bullet in doc 17's Outstanding list,
   phrased "not achieved in this workload", NOT "impossible" (codex's point:
   a different workload, a cold-path placement, or a non-perturbing debug hook
   at the dispatcher/bridge-publication boundary would each close it).
4. **MINOR — two unpinned premises.** The mid-epoch test now asserts
   `native_region_bridge_arms == 0` (so the documented scope boundary fails
   loudly if it ever moves) and the disarm delta EXACTLY (`==`, not `>=`):
   once the window is open nothing can re-arm, so the first blackout charges
   the captured set and nothing else.
5. **`capturedGraphHasCycle` rewritten** as a visited-set BFS over the ≤32
   endpoint ids. The earlier path-frontier version could truncate a branching
   frontier at 16 and report a false negative (codex confirmed no false
   positives, but the completeness comment was overstated).

Codex also confirmed: the `threadlocal` capture is sound (synchronous callback
on the same thread + TLS; the "all tests run in order on one thread" comment was
stronger than needed), and no false positives in the cycle check.

**Still open (doc 17 Outstanding):** observe a live `.region_bridge` link at a
mid-epoch window-open instant. Also unpinned, and worth knowing: WHAT empties
the registry between outer iterations. A region activation is keyed to the
frame's `call_seq`, not to one scan-loop invocation, and `closeRegion` drops
profitability state without itself disarming the physical link — so the actual
teardown trigger hasn't been identified, and identifying it may reveal a
workable probe placement.

Gates: `just test` + `zig build test -Djit-debug=true` green; six-workload
output identity holds (same six hashes as LATEST-35).

## Status 2026-08-12 (LATEST-35) — **A-viii REVISED per codex review (round 1). §A8 step 8 stays ticked; three of LATEST-34's claims below were WRONG and are corrected here. NEXT = the §A2.4 native in-page handoff (the real payoff), or Part B (rel32).**

Codex returned CHANGES REQUIRED on 5cf93e8 (1 BLOCKER + 4 MAJORs). All fixed;
full corrected record in doc 17 §A8-iv. What changed:

1. **BLOCKER — "the mid-epoch window is host-unreachable" is FALSE.** Natives
   are invoked as `nat.func(@ptrCast(self), args)` (`interp.zig:2466`) — every
   native receives the `*Vm`. So a host-installed native called from Lua CAN
   set `record_safepoint_lines` with an epoch and a full armed registry live.
   LATEST-34 item 2 was wrong, and the "containment by prevention / teardown is
   unit-level by necessity" framing built on it was wrong too.
   **New third test** (`interp.zig`, "…MID-EPOCH…"): a test-installed
   `aviii_probe()` native, called from the sieve's scan loop, waits until
   `armed_links` holds a ≥3-link multi-kind graph, records it BY KIND and BY
   `(parent.id, child.id)`, flips the window open, and is re-called for the
   rest of the run. Measured at the event: 3 links (`.link_terminal` +
   `.loop_done_linked` + `.ordinary_guard`, containing a directed cycle —
   asserted by a bounded-reachability check, since the captured graph is a
   2-cycle plus a feeder, NOT every-child-is-a-parent); `native_link_disarms`
   0 → 3; `armed_links.len` → 0; `entries` 20 → 40.
2. **MAJOR — `peak >= 3` doesn't prove the CYCLE was simultaneous.** True: it's
   a lifetime high-water mark over any kinds. Kept as a coarse assertion +
   `--jit-stats` diagnostic, but the real simultaneity claim now rests on the
   mid-epoch capture's kinds + `(parent, child)` pairs.
3. **MAJOR — `contained.entries >= armed.entries` is unsound.** Withdrawn. The
   two legs select DIFFERENT traces (the armed leg's fused hops change which
   exits are ever taken, so which side traces get recorded at all), so neither
   direction is a law. The whole-run leg now asserts only `entries > 0`; the
   event-scoped version (`entries` advancing after a mid-run blackout, both
   sides from ONE selection history) lives in the new test.
4. **MAJOR — the unit topology was fictional.** LATEST-34's three-edge shape had
   no `.loop_done_linked`. Rebuilt to the topology measured on nsieve 9 under
   `--jit-debug` (inner=24 / cont=29 / skip=14): `inner --loop_done_linked-->
   cont`, `cont --link_terminal--> inner`, `cont --region_bridge--> skip`,
   `skip --ordinary_guard--> inner` — all four `ArmKind`s, the loop-done slot
   built on a real numeric-for guard (`isLoopDoneGuardIndex` asserted at
   construction), one `disarmAllLinks` resetting all four and touching nothing
   else.
5. **MAJOR — the containment leg never exercised teardown.** It still doesn't
   (nothing arms, so there's nothing to tear down — that's the leg's point);
   the teardown-with-a-live-registry demand is met by the new mid-epoch test.

**Residual, stated not glossed:** no test observes a live `.region_bridge` link
at a window-open instant. The probe call is itself a tier-0 effect inside the
scan loop and perturbs the region shape enough that the profit gate never
qualifies it (`native_region_bridge_arms == 0` probed vs 39 unprobed); every
placement that keeps the bridge armed leaves the registry empty at the call,
(an empirical result — see LATEST-36, the actual emptying mechanism is not
pinned down). Edge
4's arming/firing is covered by the two-leg test, its teardown byte-for-byte by
the unit test. Closing the residual needs an observation hook that isn't a
Lua-visible effect inside the region.

Gates: `just test` + `zig build test -Djit-debug=true` green; six-workload
output identity holds (nsieve `4053ed86223d7060`, nbody `9dcd7fa2f7e9e93e`,
sieve_int `db55c0f98f98851b`, pi_leibniz `f57ace5316c0fd19`, grid_matmul
`395ff5566b31eb18`, field_hash `89b64d3d25ae188f`).

## Status 2026-08-12 (LATEST-34) — **SUPERSEDED IN PART BY LATEST-35: items 2, 3 and 4 below are WRONG (mid-epoch window IS host-reachable; the cross-run `entries` comparison is unsound; the unit topology was fictional). A-viii LANDED: §A8 step 8 ticked, ALL EIGHT §A8 STEPS COMPLETE. NEXT = the §A2.4 native in-page handoff (the real payoff), or Part B (rel32).**

Full record in doc 17 §A8-iv. What landed and what it cost:

1. **Integration test (`interp.zig`): the OUTER cycle arms as a CLOSED cycle
   and fires.** Scaled the A-vii-c region shape (`for j=1,40` over a 600-flag
   sieve, hotloop=4, hotguard=3) until the gate qualifies: 39 bridge arms,
   156 fused bridge hops, 430 fused loop-done hops. Added
   `native_link_peak` (high-water mark of `armed_links.len`, diagnostic-only)
   because the per-kind counters are LIFETIME TOTALS and can't tell a standing
   closed cycle from three edges armed and torn down in turn. Pins `peak >= 3`
   (nsieve measures 4). Also printed in `--jit-stats`.
2. **The finding that reshaped the step: containment is by PREVENTION, not
   teardown.** `safe_to_arm = suspend_ctl == null and !record_safepoint_lines`;
   both flags are only writable by the host BETWEEN `exec()` calls, and parking
   requires `suspend_ctl` to already be set — which already blocks arming. So
   **no host-reachable sequence opens a window mid-epoch over a live
   registry.** Measured: window open for the whole run ⇒ `peak == 0`, bridge
   arms 0, `native_link_disarms == 0` (nothing to charge). The
   `disarmAllLinks`-on-unsafe call is correct but currently
   unreachable-by-construction; it goes live when a debugger hook can arm a
   suspend on a RUNNING VM. Hence the teardown half is unit-level by necessity.
   **Bart's call, deliberately not assumed:** whether to make the mid-epoch
   window reachable so that path gets end-to-end coverage.
3. **R2-4 pinned:** the contained leg asserts `entries >= armed.entries`
   (measured 540 vs 460) — with the window open, exits that used to fuse now
   return to the dispatcher and RE-ENTER traces. Not a collapse to tier-0
   bodies. Both legs print `109`, so containment is output-transparent.
4. **Unit test (`trace.zig`): one `disarmAllLinks` tears down the whole outer
   cycle, bridge edge included** — `skip --ordinary_guard--> inner
   --link_terminal--> cont --region_bridge--> skip`, all three slots back to
   `shared_exit`. The bridge kind is the one that postdates the disarm path;
   a kind-sensitive teardown (like the deliberately-selective
   `disarmStaleRegionBridgeLinks` sweep) would strand a live handoff.
5. **Dead ends worth not repeating.** (a) "Safepoint-sequence identity vs
   tier-0" is NOT a valid window oracle — native trace iterations legitimately
   emit no per-iteration safepoints (measured 320 333 under the window vs
   516 251 tier-0). (b) The A-vii-c shape at its original size (80 flags, j=1..5)
   arms loop-done links but NO bridge; scale is what qualifies the region gate.
   (c) A bridge-arming run ends with an EMPTY registry (final gate flush
   disarms), so "still armed at end of Phase A" is not a usable negative
   control — hence the peak counter.

Gates: `just test` + `-Djit-debug=true` green; six-workload output identity
holds; nsieve N=9 389 ms / N=7 102 ms (unchanged — the peak counter sits in
`armNativeLink`, not a hot path).

Remaining: codex post-landing review of A-viii, then the §A2.4 native in-page
handoff — where nsieve:24's 94.9% coverage finally converts to wall-clock.

## Status 2026-08-12 (LATEST-33) — **A-vii-e MEASURED + A-vii-e.1 observer fast path LANDED: §A8 step 7 COMPLETE. NEXT = A-viii (outer-cycle disarm coverage) and/or the native in-page handoff (§A2.4).**

Full narrative in doc 17 §A8-iii item 5. The short version:

1. **Codex post-landing review of d/d.1 closed:** one BLOCKER (bridged
   `.link`-ending successors bypassed the bridged terminal contract — the
   `ends_link` split was tested first, so a zero-progress deopt dropped the
   successor's receipt and double-charged the parent via hop-0's
   `onSideExit(seed, 0)`). Fixed in fcee9b7 (`entered_via_bridge` first in
   both terminal arms, requiring `ends_link or ends_loop`) + regression
   test; re-review = APPROVE.
2. **A-vii-e frozen protocol run (before = 9ee7d4b, after = flip tree).**
   Raw flip: nsieve ~2× WALL REGRESSION (N=7 102→203 ms, N=9 429→795 ms;
   an earlier "flat at N=9" read was --jit-stats TSC overhead masking it)
   despite coverage moving right (nsieve:24 56.7%→94.9% traced, bridge
   fused 14 724/run at N=9). Comptime ablation (arm site declines, all else
   live) timed IDENTICAL → the bridge is cost-neutral; the regression was
   elsewhere. perf (profile-first recipe): `observeRegionProgramPoint` =
   49.1% of runtime — the A-iv per-instruction departure observer's
   empty-map guard stopped guarding once d.1 made nsieve mint an armable
   region whose accumulator is open for ~the whole run (hashmap-iterator +
   linear member_points scan per interpreted instruction; general, not
   nsieve-specific).
3. **A-vii-e.1 fix:** `ObserverFast` — when exactly one accumulator is
   live, the survive verdict is two integer compares + a per-proto bitset
   test on OWNED COPIES of `member_points` (never borrows def memory).
   Rebuilt at the three region_profit mutation funnels
   (openRegion/closeRegion/resetRegionProfit; clearCache resets via the
   third). Any refresh failure ⇒ cache null ⇒ original slow scan, identical
   semantics — OOM cannot diverge replay. --jit-stats event counters are
   bit-identical with/without it. Gotchas hit: (a) `zig build
   -Djit-debug=true` overwrites zig-out with a DEBUG binary — the first
   "after" timings were 20× garbage until `just release` was re-run (the
   documented stale-binary trap, again); (b) a hand-built test RegionDef
   has UNSORTED member_points — the span builder now takes min/max per
   proto run and the probe checks every span; (c) the frozen pi_leibniz
   control hash was for a NO-ARGS invocation (bench @bench args=5000000
   differs) — with matching args all six workloads are byte-identical.
4. **Final numbers (before → after+e.1):** nsieve N=9 436→396 ms (−9%),
   N=7 105→99 ms (−6%); `just bench --filter nsieve --reps 7` jit
   101.0→102.9 ms (noise); full suite: no mahina-side flags (str_manip
   luajit=ERR is the LuaJIT binary failing that bench, unrelated). Gates:
   `just test` (836) + `-Djit-debug=true` green. Doc 17 §A8 step 7 TICKED;
   status header updated.
5. **Honest residuals for A-viii+:** (i) nsieve:14's standalone-trace share
   fell 10.9%→0.7% at N=7 (wall-neutral today; revisit with churn work);
   (ii) ~700 `disarmAllLinks`/run at N=7 window churn still forces full
   chain re-arm cycles; (iii) the flip's win stays modest until the native
   in-page handoff (§A2.4) removes the per-firing `driveChain` seam —
   that's where the 94.9% coverage converts to wall-clock.

Codex post-landing review of e.1 (thread continues the d/d.1 one): MAJOR
(bitset sizing u32 overflow for near-maxInt pc ranges → u64 arithmetic +
4M-pc per-proto range cap, f84d9c4) + MINOR (test gaps → shallower-frame
verdicts, funnel-exercised multi-accumulator disabling, over-cap decline
test; 92eb5ee) → re-review = **APPROVE**. Commits this arc: daed882
(e.1 + measurement docs), f84d9c4, 92eb5ee.

Remaining: A-viii per §A8 step 8 (outer-cycle disarm coverage +
negative control; note the ~700 disarmAllLinks/run churn × bridge re-arm
interaction), and — the real payoff — the §A2.4 native in-page handoff to
convert nsieve:24's 94.9% coverage into wall-clock.

## Status 2026-08-12 (LATEST-32) — **A-vii-d + A-vii-d.1 LANDED: edge 4 is ARMED AND FIRING (bridge fused ~25k/run on nsieve). NEXT = commit → codex post-landing review → A-vii-e measurement.**

The flip is live end-to-end. A-vii-d proper (flag flip, `tryArmRegionBridge`
with the §A-vii.2 gates + permanent decline probes, arm/fused counters +
jit-stats lines) landed first; grounding then showed the spec'd arm site was
unreachable (two gaps, doc 17 A-vii-d.1 entry), and the corrected design —
gpt-5.6-sol design-reviewed, five blockers folded — landed on top:

- **Gap 1 (discovery):** a branch guard's committed exit pc is the H-1b
  re-execute pc, never the opposite path's landing anchor, so the cont→skip
  edge never entered `edge_cache`. Fix: `resolveCompositeBridgeSuccessor`
  overlay — opposite-polarity static-CFG target, walk across `jmp` + at most
  ONE numeric `for_loop` continue edge, with `compositeContinueProof` (exact
  recForLoop dataflow: both written slots {a, a+3} phi-bound to the same add
  ref R, a dominating `.loop_done` guard whose `le` consumes R) GATING
  publication. Plus the closed-SCC owner fix: no boundary edge exists into a
  fully-closed SCC, so owner = `(ext_entry ∨ enclosing) ∧ inner_root` where
  `enclosing` = the member whose for_loop body span contains all other
  members. nsieve now mints `id=1 members=3 armable=true owner_unique=true
  bridges=1`.
- **Gap 2 (receipts):** composite deopts never surface at driveChain's head
  on nsieve. Arm sites now: driveChain head (kept), the chain-run "not a
  completed link run" exits, and — two-phase — `pending_bridge_arm` recorded
  by replayLedger's terminal composite `.deopt` row, drained by all four
  ledger drivers AFTER the walk.
- **Landing surfaced 3 more consumer gaps, all fixed + test-pinned:**
  (i) driveChain's hop-0 scalar seam misread the 2-row `[C.region_bridge,
  S.term]` ledger as the `[C.link, I.x]` fused shape → bridge-headed ledgers
  route to driveSeedLedger (head grammar now accepts a `.region_bridge` first
  row). (ii) A bridged successor runs mode 0 → its terminal `.deopt`/
  `.prologue_fail` resumes at ITS OWN anchor (the bridge row published it
  into resume_pc; hard-verified), ordinary loop-done legal — never link_pc.
  (iii) The mid-walk disarm hazard generalizes review blocker 5:
  `flushRegionWindow` strikes / `invalidateRegion` run per ledger row and
  called `disarmAllLinks` MID-WALK, erasing the armed provenance the same
  ledger's fused M1 rows validate (measured panic the moment the region gate
  went live). `disarmAllLinks` defers under `replay_walk_depth`; drivers
  `applyPendingDisarms()` right after the walk, before the bridge-arm drain
  (a deferred disarm also drops the pending arm, fail-closed).
- **Stale-region lifecycle (review blocker 3):** `NativeLink.{kind,
  region_id}`; `.region_bridge` replay rows validate through the armed
  link's EXACT region (def live + armable + edge in THAT def, no global
  scan); every rebuild ends with `disarmStaleRegionBridgeLinks(live_armable)`
  and every fail-closed empty-physical path disarms all bridge links.

Measured (ReleaseFast, nsieve 9): `link arms: … bridge=961`, `link fused: …
bridge=25186`. Six-workload output-identity control ALL-PASS against the
frozen hashes (nsieve 4053ed86223d7060, nbody 9dcd7fa2f7e9e93e, sieve_int
db55c0f98f98851b, pi_leibniz f57ace5316c0fd19, grid_matmul 395ff5566b31eb18,
field_hash 89b64d3d25ae188f), native ≡ tier-0. Gates: `just test` green (835),
`zig build test -Djit-debug=true` green. New tests: overlay polarity/jmp/
self-edge; continue proof (pass + 2 violation shapes); bridged `.loop`-ending
successor terminal incl. ordinary loop-done; disarm deferral; stale-region
rebuild sweep; two-phase pending arm. Doc 17 A-vii-d.1 entry + status header
updated.

Remaining: commit, codex post-landing review (fix findings on own judgment
per Bart's standing mandate), then **A-vii-e** per the frozen protocol
(`just bench --filter nsieve --reps 7`, per-anchor `--jit-stats` both trees,
output equality first, report flat/negative honestly, Z-6 no special-casing).
§A8 step 7 ticks only after e. NB for A-viii: the observation-window disarm
churn (~2k disarms/run) now interacts with bridge arm persistence — bridges
re-arm each round trip (961 arms/run), worth revisiting there.

## Status 2026-08-12 (LATEST-31) — **A-vii-d.0 LANDED: armability recomputed per rebind; the region gate machine is LIVE on real shapes. NEXT = A-vii-d proper (the driveChain arm + region_bridge_arming_enabled=true).**

The A-vii-d opening question is answered. A permanent `region: owner-scan`
jitdbg probe on nsieve showed the owner predicate is RIGHT — `both_count`
evolves 0→0→1 across rebuilds as the external-entry side trace records — but
armability was frozen at first sight (`eff_armable = stored.armable ∧ …`,
monotone-decreasing), and first sight NECESSARILY precedes the entry edge: the
internal cycle is what triggers minting, and the entry source is a guard-hot
side trace recorded later. So every real region was first-seen unarmable and
could never rise. Fix (general, Z-6-clean): discovery recomputes
`armable = owner-unique ∧ membership-complete ∧ !tombstoned` on EVERY rebind, in
both directions, via a staged armable-update list; the fail-closed stickiness
moved to a new `RegionDef.tombstoned` bit (set by `invalidateRegion` and by
incompatible/truncated rebinds, never cleared). "Graph incomplete when we
looked" is now recoverable; "misbehaved" stays permanent.

Measured: nsieve arms on the entry-edge rebind (`rebind id=0 armable
false→true owner_unique=true`); the matrix sieve shape arms in the harness; the
A-vii-c dormancy tripwire fired exactly as designed and is upgraded to the
EXERCISED oracle (renamed back to `assertRegionGateExercised`: ≥1 armable
region, ≥1 live indexed member, ≥1 authoritative window flush on every execute
leg). The consumption boundary and the replayLedger double-charge fix are now
exercised by the matrix, not only by synthetic unit tests. New trace.zig unit
test pins the lifecycle: first-sight unarmable (excluded from physical
indices) → entry-edge rebind arms + indexes → invalidateRegion tombstone sticky
across an identical rebind.

Gates: `just test` green (829); `-Djit-debug` green; six-workload tier-0≡native
output control ALL-PASS (output contract — selection now genuinely diverges on
region shapes, and that is the designed A-vii-c surface finally non-empty).

Remaining for A-vii-d proper: the driveChain arm site (§A-vii.2 steps 1-3,
beside the M1 `.ordinary_guard` arms), `region_bridge_arming_enabled = true`,
arm/handoff integration tests, the `.region_bridge` no-owner-penalty firing
test, confirm `invariant_slots = S \ E` soundness, keyframe restore equality.
Then A-vii-e measurement per the frozen protocol.

## Status 2026-08-12 (LATEST-30) — **A-vii-c.1 consumption-keyed accounting boundary LANDED (closes the codex BLOCKER on A-vii-c) + region-dormancy tripwire. NEXT = codex re-review → Bart APPROVE → A-vii-d (which is itself blocked on the `armable_owner` question below).**

Codex `gpt-5.6-sol` reviewed the A-vii-c commit and returned **BLOCKER**,
correctly: membership-keyed suppression assumed physical membership in a live
region implies the region machine can gate that trace's receipts. It does not.
A member's prologue failure has no valid `ExitKey`; an exit absent from
`edge_cache` resolves to no candidate; and a structurally zero-work receipt is
deliberately silent (R2-1). The dispatcher sends exactly that last shape on its
zero-iteration path (`interp.zig`, comment: *"Zero iterations: apply the
penalty"*), so a member failing its guard on every entry was gated by NEITHER
machine — and the landed unit test pinned half of that unsafe state as if it
were the contract. Verified in the tree before acting.

**Fix (Bart's call, option (a) taken further): the boundary is CONSUMPTION, not
membership.** `accountRegionProfit` now returns whether it consumed the receipt
(nonzero work credited to a live accumulator); callers that also run selection
accounting apply `accountLegacyThrash` iff it did not. `traceHasRegion` is
deleted. Exactly one machine accounts every trace-run receipt, provable from the
call site rather than inferred from an index, and every shape the region machine
cannot gate falls back to pre-flip behaviour by construction. Null-keyed
`onSideExit` never consumes ⇒ that path is pre-flip verbatim. Ordering is
region-first then legacy (receipt-local verdict last). One deliberate exception,
documented in code and doc: `replayLedger`'s `.region_bridge` arm stays
selection-only — its ownership is *proven* by the replay grammar, and legacy
striking there would gate productive regions once per intra-region hop.

**Measured while hardening the matrix (codex finding 2): on every workload
measured so far the region gate machine is DORMANT — A-vii-c is inert on them.**
A new permanent `region: mint` jitdbg probe shows the test sieve shape AND
nsieve both mint their cross-trace cycle with `armable=false`
(`members=2 owner_unique=false membership_complete=true`): `armable_owner` wants
exactly one component node that is both externally entered and carries an inner
root (`both_count == 1`), and neither shape satisfies it. `openRegion` refuses
non-armable defs, so no accumulator opens and `flushRegionWindow` is not reached
outside unit tests. Hence the byte-identity control still passes unchanged —
dormancy, not a contract. Scope it honestly (re-review finding 2): two
observations, NOT a recorder invariant — discovery does accept a synthetic
`both_count == 1` graph in the unit tests. **This blocks A-vii-d** on those
workloads: the arm site could never fire. First question for that piece is "why
does no recorded shape reach `both_count == 1`, and is it the right predicate?",
ahead of writing the arm.

Second-round fix (re-review BLOCKER, same session): `replayLedger` was
discarding its per-row `region_consumed` while its kind arms took their
selection receipt through `onSideExit` — re-entering the region machine with a
second null-keyed receipt AND applying the legacy verdict unconditionally, so a
consumed `.loop_done_linked`/`.deopt` row would be charged by BOTH machines once
armability exists. The arms now use `accountLedgerRow(owner, completed,
region_consumed)`; the `succ` zero-exit receipts keep `onSideExit` (no region row
of their own ⇒ unconsumed by construction). New positive-control replay test:
a consumed `[I.loop_done_linked, C.deopt]` pair takes no legacy strike on either
anchor while the region accumulates 4 traversals; the pre-existing
`[I.loop_done_linked, C.prologue_fail]` grammar test is the negative control.

Tests: the 10-mode matrix now runs at `hotguard=3` through a new
`expectProgramTuned`/`CapturedOpts` harness (post-run `inspect` hook against the
live VM) and asserts the measured truth as a **tripwire** — region discovered,
`armable == 0`, `flushes == 0` — so the moment A-vii-d makes armability
reachable this test FAILS and forces an upgrade to the exercised form instead of
silently passing. The redundant single-mode companion is deleted. The
gate-machine unit test's member half is rewritten to pin consumed (no strike) vs
unconsumed-zero-work / unconsumed-unclassified (strike) / unconsumed-useful
(clears) / tombstoned (reverts to legacy).

Gates: `just test` green; `zig build test -Djit-debug=true` green; ReleaseFast
six-workload tier-0≡native control ALL-PASS (same six prefixes as LATEST-29).

## Status 2026-08-11 (LATEST-29) — **A-vii-c gate-consumption flip LANDED with the regionless fallback (first selection-diverging step).**

The flip: `accountTraceRun` is now selection-only (coverage/cycle receipts +
`hit_count`; the per-trace penalty/gate block is gone). The authoritative gate
machine is `flushRegionWindow(key, work)`, owner-keyed per `RegionDef.owner`:
`work >= min_useful` clears the owner's penalty+gate; `0 < work < min_useful`
strikes; at `max_penalty` → `gateAnchor(owner)` + `disarmAllLinks()`.
`accountRegionProfit` is the only full-window consumer and latches
`RegionAccum.useful_window_seen` (the A-vii-d qualification seam); `closeRegion`
routes its nonzero remainder through the same machine (zero-remainder closes are
silent). `region_bridge_arming_enabled` stays `false` — no behavior-changing arm
yet.

**Design-gap discovery (the important part).** The design's premise that
"self-loop/lone-trace regions reproduce the old useful/low-yield decision" is
FALSE: discovery mints regions only for cycle-bearing SCCs of the cross-anchor
structural-edge graph (`resolveSuccessorAnchor` rejects `wp == t.anchor.pc` for
guards; `rebuildRegionsFallible` needs `comp_size >= 2 or has_self`). Plain loop
traces and same-anchor sibling groups get NO region, so a spec-faithful flip
left them entirely ungated — measured: parity loop `if i % 2 == 0` → two sibling
traces at `main:5`, **961 trace entries / 2000 iterations, no gate** (old
machine gated after 8); 7 pre-existing tests broke. Escalated to Bart;
**his call = the regionless fallback**: receipts of a physical member of a live
(armable) region — membership via `dest_entry_regions.get(trace_id)` + per-id
`def.armable` recheck (`traceHasRegion`), so tombstones bite immediately — are
penalty-neutral on the selection side; every other trace keeps the exact
pre-flip per-trace machine (`accountLegacyThrash`, keyed by its own anchor,
driven by `completed`), on both `onSideExit` and `onSideExitReceipt` paths.
Consequence: selection is byte-identical for ALL non-region shapes (the entire
pre-existing suite passed unchanged); the divergence surface is exactly
region-member traces. Doc 17 has the full addendum ("A-vii-c correction at
landing") + corrected byte-identity boundary note; sub-step 3 ticked; §A8
step 7 stays UNTICKED (d/e remain).

Tests: rewrote the A-ii.1 split pin as "regionless onSideExit keeps the legacy
gate; bare accountTraceRun is selection-only"; new trace.zig gate-machine test
(N=8 windows qualify+clear owner, sub-N remainders strike, max_penalty gates +
disarms an armed link, tombstoned member reverts to legacy); new interp.zig
10-mode matrix test on a region-forming mini-sieve (numeric-for inner loop —
a while inner does NOT close the cycle) + an introspection companion pinning
`region_defs.count() >= 1` at hotguard=3 (at default hotguard the shape mints
no region and the matrix test would silently not exercise the flip).

Gates: `just test` green (828 tests); `zig build test -Djit-debug=true` green;
ReleaseFast six-workload tier-0≡native output-identity control ALL-PASS
(nsieve `4053ed86223d7060`, nbody `9dcd7fa2f7e9e93e`, sieve_int
`db55c0f98f98851b`, pi_leibniz `f57ace5316c0fd19`, grid_matmul
`395ff5566b31eb18`, field_hash `89b64d3d25ae188f`).

Process note: codex is REVIEW-ONLY now (usage limits); Claude implements.
Codex review of this diff requested by Bart — run via `mcp__codex__codex`
(read-only sandbox, no model pin). A-vii-d next: arm-site flip
(`tryArmRegionBridge` in `driveChain` beside the M1 `.ordinary_guard` arms,
`region_bridge_arming_enabled = true`), must confirm the `invariant_slots =
S \ E` soundness assumption flagged at A-vii-b; then A-vii-e measurement per
the frozen protocol.

## Status 2026-07-25 (LATEST-28) — **A-vii-b descriptor/validator LANDED, unarmed + byte-identical-inert. NEXT = A-vii-c gate-consumption flip.**

`RegionDef` now owns canonical-sorted per-bridge descriptors containing the exact
`StructuralEdgeId`, successor `AnchorKey`, `required_slots = S`, and proven
edge-invariant slots. Discovery computes `S` by a backward-liveness fixed point
over the entire SCC: each anchor starts with the union of its physical member
traces' `entry_slots`; successor live-ins propagate backward over every internal
edge until stable, with a dominance-safe slot phi defining the slot on that
edge. A bridge therefore retains its successor entry slots plus values that stay
live through later region edges, rather than approximating `S` from child
inputs. All descriptor and nested slot slices are allocator-owned, staged before
infallible publish, replaced on same-`RegionId` re-record, and freed from staged
rollback, `TraceState.deinit`, and `clearCache`.

`nativegen.compositeBridgeEmissions` is the sole immutable-IR query for A-v's
emitted set `E` (slot-bound phi, non-internal, `p.b < exit_instr`).
`emitCompositeBridgeSnapshot` and the arm-time `compositeBridgeEmitsSlot`
predicate both consume that query. The new resolver preserves existing stable
highest-`hit_count` selection while requiring the physical child to be listed
for the same `RegionId` in `dest_entry_regions`, excluding same-anchor siblings.
`validateRegionBridge` is allocation-free and publish-incapable: it resolves the
stored exact edge, proves every `S` slot is in `E ∪ invariants`, independently
requires `child.inputs.len == 0`, and returns only `{child, bridge}`. Failure
uses `invalidateRegion`; success and failure install no `NativeLink`.

The focused discovered-cycle test proves `S={r0,r1,r2}` from child
`entry_slots={r0,r1}` plus live-through `r2`, `E={r0}`, and
`invariants={r1,r2}`. It covers the positive decision, higher-hit non-member
sibling exclusion, missing-live-through-proof tombstoning, seeded-child
tombstoning, same-logical-region descriptor replacement after fresh physical
trace IDs, owned-slice leak checking, zero `armed_links`, and the parent slot
remaining `shared_exit`.

Gates: `just test` green; `zig build test -Djit-debug=true` green. ReleaseFast
tier-0 and `--trace --jit-native` both match all expected SHA-256 prefixes:
nsieve `4053ed86223d7060`, nbody `9dcd7fa2f7e9e93e`, sieve_int
`db55c0f98f98851b`, pi_leibniz `f57ace5316c0fd19`, grid_matmul
`395ff5566b31eb18`, field_hash `89b64d3d25ae188f`.
`region_bridge_arming_enabled` remains `false`; there is no `driveChain` caller,
no `.region_bridge` publish path, and §A8 step 7 remains unticked.

---

## Status 2026-07-25 (LATEST-27) — **A-vii-a strict bridge replay LANDED, unreachable + byte-identical-inert. NEXT = A-vii-b descriptor/validator.**

Replaced only `replayLedger`'s `.region_bridge` tripwire with the additive
A-vii.3 grammar. Replay now requires a normal, non-yielded, non-final composite
guard; resolves the next owner; proves the exact `{parent, slot, child}` backlink
in `armed_links`; and resolves exactly one live `RegionDef.members` edge from the
owner anchor plus committed `ExitProvenance`. Missing, duplicate, tombstoned, or
successor-mismatched edges release-`@panic`. The coherent resume cursor comes
from the stored child anchor, never merely `guardExitPc` or the next ledger row.
The bridge accepts nonzero cumulative progress and sends `max(local, 1)` through
`accountTraceRun`; its already-separate region-profit receipt remains structural
work zero with the known successor.

The synthetic replay guard constructs
`[cont.region_bridge(cum=3), skip.deopt(cum=5)]`, the armed backlink, and an
owned registered region edge directly. Its stored skip PC deliberately differs
from the guard exit PC, proving the returned cursor is region-owned; `N=3`
proves the bridge's synthesized selection completion increments the continuation
hit exactly once while the skip's local work remains independently low-yield.
The pinned Zig stdlib has no in-process panic-expectation helper, so the four
release-panic negative paths are explicit in the arm and documented by the test.
All allocations use `std.testing.allocator`; `TraceState.deinit` owns the copied
region slices and the stack-owned trace cache is detached before teardown.

Gates: `just test` green; `zig build test -Djit-debug=true` green. ReleaseFast
tier-0 and `--trace --jit-native` both match the expected SHA-256 prefix for all
six controls: nsieve `4053ed86223d7060`, nbody `9dcd7fa2f7e9e93e`,
sieve_int `db55c0f98f98851b`, pi_leibniz `f57ace5316c0fd19`, grid_matmul
`395ff5566b31eb18`, field_hash `89b64d3d25ae188f`.
`region_bridge_arming_enabled` remains `false`; no driveChain arm site,
descriptor/validator, gate-consumption, M1 `.deopt`, monotonic-cumulative, or
zero-progress/terminal rule changed. §A8 step 7 remains unticked.

---

## Status 2026-07-25 (LATEST-26) — **A-vi native-F2c logical-cut harness LANDED, inert + green. NEXT = A-vii (arm edge 4 + region-profit gate) per §A8 step 7.**

A-vi landed in three ordered pieces. Piece 0 bumps keyframes to schema v6:
`FrameRef` now carries `varargs_base`/`varargs_count`, generated Zig/TypeScript
codecs were regenerated, capture serializes them, and restore validates their
canonical/range/proto shape before rebuilding frames through `pushFrameVararg`.
The live-vararg suspend/resume guard proves byte-identical mid-keyframe
round-trip plus identical forward output/final state.

Piece 1 adds VM-local `committed_effect_seq` and the single
`onEffectCommitted()` hook. Its four post-validation call sites are normal
native effects, lazy random-seed materialization, a genuinely new Unicode pin
(already-consumed replay re-entry does not advance), and validated file reads.
All four families are mode-identical across off/record/replay; a fault commits
nothing. No selection/gating path reads the counter.

Piece 2 adds the optional logical `SuspendCtl.after_committed_effects` trigger:
the existing tier-0 suspend boundary walks until `seq >= N` while retaining the
`reg_top_pending` and depth eligibility gates. F-5 executes a real compiled
native numeric-for burst, commits a fixed-result clock effect, and compares the
serialized semantic keyframe plus serialized effect prefix/cursor/counter,
output prefix, and Xoshiro256 state against tier-0. It restores into an empty
trace cache, reattaches the omitted driver facets, resumes, and matches the
uninterrupted final output/keyframe/PRNG state. H-3 coverage now explicitly
proves clean-epoch wholesale clear and dirty-entry non-mutation; A-iv already
covers activation cleanup and one-per-owner cardinality.

Files touched: `schema/trace.json`, regenerated `src/gen/trace_schema.zig` and
`viz/src/gen/generated.ts`, `src/keyframeser.zig`, `src/interp.zig`, this file,
and `docs/design/17-exit-branch-patching.md`. Inertness/soundness: no arming flag
or gate changed; the new counter has test/harness consumers only; the logical
suspend field defaults null; schema v6 closes a pre-existing restore hole.
Piece-local `zig build` gates, `just test` (823/823), and
`zig build test -Djit-debug=true` (823/823) are green. ReleaseFast tier-0 stdout
is byte-identical to `--trace --jit-native` for all six controls, matching the
committed SHA-256 prefixes: nsieve `4053ed86223d7060`, nbody
`9dcd7fa2f7e9e93e`, sieve_int `db55c0f98f98851b`, pi_leibniz
`f57ace5316c0fd19`, grid_matmul `395ff5566b31eb18`, field_hash
`89b64d3d25ae188f`.

Reviewer risks: validate that `varargs_end <= frame.base` covers both bytecode
calls and host re-entry layouts; confirm every effect hook remains downstream of
its family-specific validation; stress the logical cut with multret
`reg_top_pending`; and verify the F-5 expression-temporary shape continues to
compile and execute natively (the test asserts both traced iterations and a
compiled native trace).

---

## Status 2026-07-24 (LATEST-25) — **A-v edge-4 bridge stub emission LANDED, unarmed + inert. NEXT = A-vi (native-F2c harness + H-3/H-4 tests) per §A8 step 6.**

Every composite ordinary guard accepted by the trace-local classifier now emits the
§A2.4 bridge head and dead armed body: `slot[ei] == shared_exit → ordinary_mini`,
cap-check-first at `ledger_len > LEDGER_CAP-2`, dominance-scoped phi snapshot `E`,
`.region_bridge` ledger append, and staged indirect handoff. `ordinary_mini` is shared
by unarmed and ledger-full cases and preserves today's `exit_instr → deopt_exit`
behaviour; the bridge writes no `final_trace_id` and has no forced-yield check.

Classifier/arming decisions: committed `GuardProvenance` must be a same-anchor-proto
`.branch_cond` whose source PC matches the IR guard and whose exit precedes the trace
anchor; `E` is every slot-bound phi with `update_ref < guard_index`, excluding internal
and post-guard updates. Existing `.ordinary_guard` arming rejects bridge candidates.
`ArmKind.region_bridge` derives `child.ordinary_entry` but is release-fail-fast behind
`region_bridge_arming_enabled = false`, so A-v has no publishing call site and every
bridge slot stays unarmed until A-vii.

Files touched for A-v: `src/nativegen.zig` (classifier, E snapshot, stub emission,
machine-prefix/unarmed test), `src/trace.zig` (`ArmKind`, derive-not-trust target,
inert arm guards), `src/irinterp.zig` (`LedgerKind.region_bridge` plus pre-A-vii replay
tripwire), this file, and `docs/design/17-exit-branch-patching.md`. Inertness proof:
`zig build` after each of the three requested sub-steps; `just test` green;
`zig build test -Djit-debug=true` green. ReleaseFast tier-0 output was byte-identical
to `--trace --jit-native` for all six controls, with committed SHA-256 prefixes:
nsieve `4053ed86223d7060`, nbody `9dcd7fa2f7e9e93e`, sieve_int
`db55c0f98f98851b`, pi_leibniz `f57ace5316c0fd19`, grid_matmul
`395ff5566b31eb18`, field_hash `89b64d3d25ae188f`.

Reviewer risks to check: the classifier's `exit_pc < anchor.pc` definition of outer
re-test, the slot-bound-phi-as-successor-live interpretation of `E`, and the deliberate
A-vii flip point (`region_bridge_arming_enabled` plus replay panic).

---

## Status 2026-07-22 (LATEST-24) — **A-iv `region_profit` accumulator LANDED, inert + green (reverse-authored by Codex). NEXT = A-v (edge-4 bridge stub, unarmed) per §A8 step 5.**

`accountRegionProfit` now ACCUMULATES (was a no-op) per-activation `RegionKey{region_id, activation:call_seq}
→ RegionAccum{outer_traversals, window_base, root_frame_depth, root_call_seq}` windows into a VM-persistent
`region_profit` map, but does NOT gate: `onSideExitReceipt = accountTraceRun` (byte-for-byte the legacy
tiering path) `+ accountRegionProfit`, whose full-`min_useful` windows flush into diagnostic-only counters
(`region_profit_flushes/_flushed_work`) that no selection/tiering/penalty path reads (A-vii swaps that sink
for the real gate). `observeRegionProgramPoint(proto_id, pc, depth, call_seq)` runs in the dispatch loop
behind an `if regionProfitCount() != 0` guard (no per-op call/alloc on the common path; account fns return
`void` + `getOrPut … catch return null`, so no OOM propagates into execution). Activation-scoped cleanup
drops entries at EVERY frame-destroy site — normal pop ×2 (`dropRegionActivation`) and pcall/xpcall unwind ×3
(`dropRegionActivationsFromDepth`, before the depth restore); mahina has **no coroutines**, so that set is
complete. `region_profit` is transient (NOT serialized; keyframe schema stays v5) and reset at restore +
every `beginTopLevelEpoch` (`clearCache → resetRegionProfit`). §A5 cardinality (≤1 accumulator per
`(activation, owner-anchor)`) is release-`@panic`-enforced and unreachable by construction.

**Reverse-setup workflow (per Bart):** Codex designed + implemented; Claude + antigravity reviewed. The codex
MCP run overran the 30-min idle timeout (A-iv is large) and the client aborted mid-run, but the detached
subprocess left a compiling, green tree; after it went quiet I reviewed the dirty tree cold. **antigravity
returned BLOCKER (2 findings), both adjudicated N/A against mahina's actual code/design:** (F4) tail-call frame
reuse — mahina has no Lua-level TAILCALL opcode, every call/return is balanced through push/drop, so no orphan;
(F5) release `@panic` in `openRegion` — §A5 *mandates* a release-enforced invariant (same as A-iii's
`call_seq` exhaustion panic), and it's unreachable by construction, so downgrading to `std.debug.assert` would
violate the design. Claude verdict = APPROVE.

Guards codex added: window-persist-across-re-entry, activation-cleanup-drops-only-dying, same-activation
collision-flush, pcall-unwind-drops-entry, restore-doesn't-persist (seeds an entry pre-snapshot, asserts it
neither changes v5 bytes nor survives restore). `just test` + `-Djit-debug` green; ReleaseFast nsieve 9 /
nbody 20000 / sieve_int / pi_leibniz / grid_matmul / field_hash tier-0 ≡ `--trace --jit-native`
byte-identical (SAME hashes as the A-iii baseline ⇒ inert). Files: src/trace.zig (+428), src/interp.zig
(+35), src/keyframeser.zig (+17), src/stdlib/errors.zig (+42, pcall-unwind hook + test).

---

## Status 2026-07-21 (LATEST-23) — **A-iii `call_seq` plumbing LANDED, inert + green. NEXT = A-iv (`region_profit` accumulator) per §A8 step 4.**

Added transient `CallFrame.call_seq: u64` and per-VM monotonic `next_call_seq`. The single physical
frame-push choke point `pushFrameVararg` assigns the current key and advances it; verified both bytecode
`.call` and host-reentrant `callValue` funnel through it, with no bypass except keyframe restore. Counter
exhaustion is release-enforced by a pre-publication `@panic` at `maxInt(u64)`, so silent wrap and key reuse
are impossible. Restore deterministically re-keys the live physical stack by index and parks the next key
above it (`frames[i].call_seq = i`, `next_call_seq = depth`). No wire field and no schema bump (the tree's
existing H-2 schema remains v5); no production path reads `call_seq`, and `accountRegionProfit` stays a
no-op.

Guard coverage advances the counter in a prior epoch, suspends with several simultaneous recursive-proto
activations, proves pre-restore monotonic assignment, then proves restore + re-record index ordering and a
subsequent push at `depth`. `just test` green default + `-Djit-debug`; ReleaseFast nsieve 9 / nbody 20000 /
sieve_int / pi_leibniz / grid_matmul / field_hash tier-0 ≡ `--trace --jit-native` byte-identical.

---

## Status 2026-07-21 (LATEST-22) — **A-i `exit_prov` fail-soft parity + F5/F6 folded → re-APPROVED (checkpoint boundary still holds).** NEXT = A-iii (`call_seq` plumbing) per §A8 step 3.

Second review arc on the A-ii landing. Bart approved extending the F1-style fail-soft treatment to the
**earlier-phase (A-i) `exit_prov` dup at commit**, and the reviewer (gpt-5.6-sol) surfaced two more blockers
(F5, F6) on the way. All folded, re-certified **APPROVE**:

- **A-i `exit_prov` fail-soft parity** (Bart-approved extension). The commit-time `exit_prov` dup
  (`buildExitProv`, A-i / GuardProvenance scope) shared the same `try`-can-abort → `closeTrace`'s
  `commit() catch { gateAnchor }` pattern as F1. Made fail-soft: `if (buildExitProv(...)) |ok| {...} else |_| {
  exit_prov_complete = false; }`, published into new `Trace.exit_prov_complete: bool = true`. Unlike `rec_path`,
  a truncated `exit_prov` drops that trace's structural EDGES — and a lost *boundary* edge could shrink an
  owner's competing-entry count and spuriously ARM. So the gate is graph-wide, not per-region: at the top of
  `rebuildRegionsFallible`, any cached trace with `!exit_prov_complete` bails the whole pass (retain logical
  `region_defs`, mint nothing, empty physical via `clearPhysicalRegionIndices`).
- **F5 — wrong-arm on boundary-edge evolution (pre-existing bug, Rule #0.5).** The rebind path folded only
  `stored.armable`, never the CURRENT `cand.armable_owner`. A boundary-only graph change flips `both_count`
  1→2 while re-interning the SAME `RegionId` (identity = internal edge set, boundary excluded) → the stale
  `stored.armable=true` wrong-arms an ambiguous owner. Fixed: `eff_armable and= cand.armable_owner` (pure
  tightening — can only disarm, auto-recovers when unambiguous again) + refresh the stored `owner` via
  `staged_owner_updates` (the unique external entry can move while id stays stable).
- **F6 — `.retain` disposition unsafe.** F5's insight voids F2's "prior physical snapshot is still coherent"
  premise: a new commit can invalidate a prior owner, so retaining a physical snapshot on a rebuild OOM can
  keep a stale arm. Removed the `RegionOom` enum entirely; `rebuildEdgeCache` and `rebuildRegions` now take no
  disposition arg and ALWAYS fail CLOSED to empty (`catch self.clearPhysicalRegionIndices()` /
  `catch self.edge_cache.clearRetainingCapacity()`) — arm nothing, auto-recover next rebuild. All 28 call
  sites converted to no-arg.

New tests: exit_prov fail-soft 3-phase (complete→armed, taint one trace→disarmed + logical retained,
clear→re-armed); F5 boundary-flip (ext2→inner@7 flips `both_count` 1→2, same id disarmed, owner refreshed to
placeholder); F6 FailingAllocator (region-rebuild OOM empties physical, retains logical). `just test` **813**
green (default + `-Djit-debug`); nsieve 9 / nbody 20000 / sieve_int / pi_leibniz / grid_matmul / field_hash
tier-0 ≡ `--trace --jit-native` byte-identical (ReleaseFast).

**Commits:** `59501e2` exit_prov fail-soft + graph-completeness gate · `9029aac` F5 rebind armable_owner + owner
refresh · `6ffb3aa` F6 remove RegionOom / always fail-closed. A-i + A-ii remain inert, byte-identical across the
10 replay modes. Piece boundary (APPROVE) reached — pausing for go-ahead on A-iii.

---

## Status 2026-07-21 (LATEST-21) — **A-ii COMPLETE + APPROVED (checkpoint boundary reached).** A-i + A-ii both landed, inert, reviewer-certified. NEXT = A-iii (`call_seq` plumbing) per §A8 step 3.

**A-ii checkpoint review = gpt-5.6-sol APPROVE + antigravity LGTM.** The post-landing review (mirrors A-i)
returned **BLOCKER with four findings, all folded and re-certified to APPROVE**:
- **F1 — commit-abort tiering perturbation.** The commit-time `rec_path` dup (`src/trace.zig:~5145`) was
  `try` → OOM propagated out of `commit` to `closeTrace`'s `commit() catch { gateAnchor }`, gating the
  anchor and perturbing tiering. Made fail-soft: `catch blk: { rec_path_complete = false; break :blk &.{}; }`.
- **F2 — `.retain` not honored on upstream OOM.** `rebuildEdgeCache` cleared-then-put, so a commit-path
  OOM emptied `edge_cache` and the subsequent `rebuildRegions(.retain)` ran over an empty graph. Made
  transactional: `rebuildEdgeCacheFallible` computes `upper = Σ exit_prov.len`, `ensureTotalCapacity(upper)`
  BEFORE `clearRetainingCapacity`, then `putAssumeCapacity`; `rebuildEdgeCache(on_oom: RegionOom)` (commit
  `.retain` / retire `.empty`).
- **F3 — armable on truncated membership.** Added `Trace.rec_path_complete: bool = true` (false on a
  recorder-path OOM OR the F1 commit-dup OOM). `rebuildRegionsFallible` computes per-candidate
  `membership_complete` (all members found by `traceById` ∧ `rec_path_complete`); gates `armable` first-sight
  AND rebind (sticky tombstone on `!compatible OR !membership_complete`). Region *identity* stays purely
  structural (unaffected) → replay-stable.
- **F4 — capacity trap.** `@intCast(upper)`→`ensureTotalCapacity` could panic (`ceilPowerOfTwo(u32,…) catch
  unreachable`) past ~1.7e9. Added a `1<<30` soft-OOM guard so an over-large graph fails through `RegionOom`
  instead of trapping (unreachable in practice; the inert path must never trap).

New test: incomplete member path mints the region NON-armable, classifies nothing. `just test` **809** green
(default + `-Djit-debug`); nsieve 9 / nbody 20000 / sieve_int / pi_leibniz / grid_matmul / field_hash tier-0 ≡
`--trace --jit-native` byte-identical (ReleaseFast).

**Commits:** `6ebceb6` A-ii.4 land · `5d6a5b3` fold F1/F2/F3 · `1dcf1ba` fold F4. (Earlier this session:
`ac276da` A-ii.1 · `7b0c500` A-ii.2 · `2c4de54` A-ii.3.)

**FLAG for Bart (Rule #17, not changed unilaterally):** the `exit_prov` dup at commit
(`src/trace.zig:~5133`, `const exit_prov_owned = try buildExitProv(...)`) shares the SAME `try`-can-abort →
`gateAnchor` pattern F1 fixed, but it is **A-i scope** (already approved/landed), so I left it as-is. If you
want the commit path uniformly non-perturbing on OOM, that A-i site should get the same fail-soft treatment —
your call.

**NEXT:** A-iii (`call_seq` plumbing) per §A8 step 3. Then A-iv (`region_profit` accumulator + window +
state machine; threads a real `?ExitKey` to `accountRegionProfit`, which stays a **no-op** until then).
Subsequent: A-v (edge-4 bridge stub, unarmed) → A-vi (native-F2c harness) → A-vii (FLIP: arm edge 4 + gate B
consumes `region_profit`) → A-viii (disarm coverage). Also the Q6 `FrameRef` varargs schema-bump ticket
before F2c.

---

## Status 2026-07-21 (LATEST-20) — A-i COMPLETE; A-ii CODE COMPLETE (A-ii.1–4 all LANDED+green+byte-identical); NEXT = post-landing gpt-5.6-sol review of the whole A-ii impl (the checkpoint-APPROVE, mirrors A-i).

**A-ii.4 landed this session (uncommitted at time of writing → commit next):** `region_defs` discovery +
`RegionId` interning + classification indices + `classifyExit`, all inert. In `src/trace.zig`:
- Types: `RegionId=enum(u64)`, `RegionClassifier`, `RegionDef{members,member_points,owner,classifier,armable}`,
  hand-written `RegionInternMap` (bucket→intrusive-chain, element-wise `setsEqual`, collision-safe),
  `RegionSetBuilder(K)` + `freeRegionSetMap` helpers, `programPointLess`/`programPointsEqual`/`regionIdLess`.
- Fields on TraceState: `region_defs`, `region_intern`, `next_region_id`, `source_exit_regions`,
  `dest_entry_regions`.
- `rebuildRegions(on_oom)` → `rebuildRegionsFallible`: proto_by_id map → nodes/edges from edge_cache →
  CSR + iterative Tarjan SCC → cycle-bearing candidates → sorted-set canonical order → intern/stage
  (transactional: dupes with errdefers + pre-reserved staged lists so appends infallible) → physical
  src/dst builders → finalize → `reserve` logical maps → INFALLIBLE publish (interns, defs, tombstones,
  swap physical). OOM: commit `.retain` / retire `.empty` (`clearPhysicalRegionIndices`). `classifyExit`
  pure query. Owner = unique external-entry ∧ loop-root else placeholder+armable=false. Rebind
  tombstone on incompatible member_points.
- Wired: commit (`.retain`), removeTrace (`.empty`), clearCache (clears logical+physical), deinit (frees
  all), interp.zig:9030 flush-guard (asserts all 5 region/edge maps empty).
- 6 tests (all green): owner target graph (skip→ramp→inner→cont→skip + boundary → owner==skip@14 ∧
  armable), re-record RegionId stability, intern set-identity, sibling candidate sets, rebind tombstone,
  removeTrace-preserves-vs-clearCache-empties lifetime. `just test` 808 pass default + `-Djit-debug`;
  nsieve 9 / nbody 100000 / sieve_int / pi_leibniz / grid_matmul / field_hash tier-0 ≡ `--trace
  --jit-native` byte-identical.

**Prior sub-steps (committed earlier this session):**
- `ac276da` A-ii.1 split; `7b0c500` A-ii.2 StructuralEdgeId+edge_cache; `2c4de54` A-ii.3 rec_path.

**NEXT:** request the post-landing gpt-5.6-sol review of the whole A-ii implementation (the
checkpoint-APPROVE). Then §A8 step 3 = A-iii (call_seq plumbing). accountRegionProfit stays no-op until
A-iv (region_profit accumulator + window + state machine + threads real ?ExitKey).

---

## Status 2026-07-21 (LATEST-19) — A-i COMPLETE; A-ii DESIGNED+APPROVED; A-ii.1/2/3 LANDED+COMMITTED+green; A-ii.4 (the big one) remaining, fully grounded.

**Landed this session (all green: `just test` default + `-Djit-debug`; nsieve/nbody/mandelbrot tier-0≡native):**
- `ac276da` A-ii.1 split (onSideExit → accountTraceRun + no-op accountRegionProfit; ExitKey type).
- `7b0c500` A-ii.2 StructuralEdgeId + field-wise order/eql/hash + edge_cache + rebuildEdgeCache
  (resolveSuccessorAnchor faithful to driveChain; hasInnerRootAt; wired commit/removeTrace/clearCache/deinit).
- `2c4de54` A-ii.3 ProgramPoint + Recorder.rec_path/rec_path_ok (fail-soft recordInstr hook) →
  owned Trace.rec_path at commit; freed in destroy; reset/deinit wired.

**NEXT: A-ii.4 — region_defs discovery + RegionId interning + classification indices + classifyExit
(inert).** Full spec = doc 17 §A8-ii discovery algorithm (steps 1-4) + the round-11/12/13 folds. Concrete
build list (all on TraceState; edge_cache/StructuralEdgeId/ProgramPoint/rec_path already exist):
- Types: `RegionId = enum(u64){_}`; `RegionClassifier{kind: {self_loop,cross_trace_cycle}, member_count:u32}`;
  `RegionDef{members:[]StructuralEdgeId (sorted internal), member_points:[]ProgramPoint (sorted union),
  owner:AnchorKey, classifier, armable:bool}`.
- `RegionInternMap`: hand-written (key = variable-length sorted []StructuralEdgeId; hash-bucketed via
  StructuralEdgeId.hash fold; a hit confirmed by element-wise `StructuralEdgeId.eql`; collision mints a
  distinct RegionId). Owns a copy of the sorted slice.
- Fields: `region_defs: AutoHashMap(RegionId, RegionDef)` (Proto/VM-lifetime, NEVER removeTrace-cleaned;
  cleared ONLY in clearCache); `region_intern` (same lifetime); `source_exit_regions: AutoHashMap(ExitKey,
  []RegionId)`, `dest_entry_regions: AutoHashMap(u32 trace_id, []RegionId)` (physical, wholesale rebuilt).
- Discovery (`rebuildRegions`, called right after `rebuildEdgeCache` at commit + removeTrace):
  1. Build anchor-node graph from edge_cache (nodes = {proto_id,pc} anchors, edges = StructuralEdgeId).
  2. Tarjan SCC; each SCC with a cycle (size≥2 or self-edge) = region candidate.
  3. Internal vs boundary edge partition (boundary = leaves SCC; EXCLUDED from intern set). Sort internal
     by StructuralEdgeId.lessThan → intern → RegionId. getOrPut region_defs: first-sight build; rebind →
     compare canonical member_points → mismatch tombstones (armable=false) + exclude from physical indices.
  4. owner = UNIQUE anchor that is external-entry (dest of an incoming boundary edge from OUTSIDE the SCC)
     AND loop-root (hasInnerRootAt / a bound trace isInnerLoopRoot); else placeholder = canonically-smallest
     SCC anchor {proto.id,pc} + armable=false.
  5. Physical member = live trace realizing ≥1 internal edge (has the keyed exit whose StructuralEdgeId ∈
     members). source_exit_regions[{T.id,e}]∋R incl. boundary-leave from a member anchor realized by T;
     dest_entry_regions[T'.id]∋R only for physical-member successors. Exclude armable==false.
  - **TRANSACTIONAL + FAIL-SOFT** (round-12 findings 1/2): stage ALL (new interns, new/updated defs,
    tombstones, physical indices) in scratch, `ensureUnusedCapacity` on the live maps for the delta, then
    ONE infallible apply. OOM in staging → discard scratch, leave prior maps intact. **Commit-OOM retains
    prior snapshot; retirement-OOM publishes EMPTY physical indices** (prior refs a dead trace).
- `classifyExit(key: ExitKey) []RegionId` → source_exit_regions[key] or empty (pure query, unread, unit-tested).
- Teardown: clearCache clears region_defs+region_intern+source_exit_regions+dest_entry_regions (+ the
  interp.zig:9030 "empty after flush" guard test — ADD these maps to it); removeTrace rebuilds physical
  indices wholesale (region_defs untouched); deinit frees all (RegionDef.members/member_points owned;
  region_intern owns slices; the []RegionId values in the physical maps owned).
- Tests (mandatory): synthetic skip→ramp→inner→cont→skip graph WITH the outer incoming boundary edge into
  skip@14 → owner==skip@14 ∧ armable==true; stable RegionId; re-record (new Trace.ids) → same RegionId;
  forced hash collision → distinct id; sibling boundary-edge → candidate SETS correct (member vs non-member);
  rebind-mismatch tombstone; boundary edges excluded from intern set; clearCache empties all incl region_defs
  while removeTrace leaves region_defs intact.
- accountRegionProfit STAYS no-op (A-ii is inert end-to-end). After A-ii.4: request post-landing gpt-5.6-sol
  review of the whole A-ii implementation (the checkpoint-APPROVE), mirroring A-i.

**Watch:** Rule Z-1 `**` array-repeat needs the explicit-loop form (bit us twice). AutoHashMap value slices
([]RegionId) must be freed per-entry on clear/rebuild/deinit (iterate valueIterator) — no leak.

---
## Status 2026-07-21 (LATEST-18) — A-i COMPLETE; A-ii DESIGNED+APPROVED; A-ii.1 LANDED+COMMITTED; A-ii.2 grounded, ready to code.

**Cadence (Bart):** "First fix the current task, then design it first, then ask gpt-5.6-sol for a review,
and maybe antigravity too. Autonomous, checkpoint per piece — the piece boundary being an APPROVE."

**Where we are in §A8 landing sequence:** A-i (GuardProvenance) DONE. Now on **A-ii — region discovery +
classifier, inert** (§A8 step 2). Design note = doc 17 **§A8-ii** (search "A8-ii"), reviewer-certified:
gpt-5.6-sol rounds 11–13 BLOCKER (all folded) → **APPROVE**. Four inert sub-steps A-ii.1–A-ii.4; each
green + byte-identical (nsieve/nbody/mandelbrot tier-0≡native, `just test` default + `-Djit-debug`).

**Commits (branch master, NOT pushed):**
- `121e22a` docs(17): A-ii landing design (§A8-ii)
- `ac276da` feat(trace): **A-ii.1** accountTraceRun/accountRegionProfit split (inert) — LANDED, green.
  onSideExit (trace.zig:1759) is now an `inline` wrapper → `accountTraceRun` (old body verbatim) +
  no-op `accountRegionProfit(?ExitKey)`; added `ExitKey{trace_id,exit_instr}` (trace.zig:592). Zero
  call-site changes. Equivalence test appended after the A-i.4 test.

**NEXT: A-ii.2 — StructuralEdgeId + ephemeral edge_cache + anchor successor resolution (inert).** Fully
grounded (do not re-derive):
- `StructuralEdgeId = {anchor_proto_id, anchor_pc, exit: ExitProvenance, succ_anchor_proto_id,
  succ_anchor_pc}`. Needs **field-wise** `canonicalLessThan`/`canonicalEql`/`canonicalHash` honoring
  `inline_depth` (compare `path[0..inline_depth]` only; NO `std.mem.asBytes`/full-union `eql` — the union
  has padding + an inactive arm). Types near ExitProvenance (trace.zig:548/570), ExitKey at 592.
- **edge_cache** `AutoHashMapUnmanaged(ExitKey, StructuralEdgeId) = .empty` on TraceState; built at commit
  (after cache.append ~4148), cleared in clearCache (3664), WHOLESALE-rebuilt from surviving cache in
  removeTrace (3615, fail-closed empty on OOM), freed in deinit (1510). Read by nothing ⇒ byte-identical.
- **Successor resolution** (per driveChain, trace.zig:1893-1934, faithfully): for each **keyed** exit e
  of trace T (`T.provAt(e)` non-null):
  - `.link_terminal`: succ anchor = `{T.anchor.proto, aux}` where `aux` = the `.link` instr's aux (inner
    root pc); validate a trace bound at (proto,aux) is `isInnerLoopRoot` (1654). Else no edge.
  - guard: `wp = guardExitPc(T.instrs[e])` (454; only guard_int/float/number/true/false/int_of_float →
    non-null). Require `wp != null`, `wp != 0`, `wp != T.anchor.pc`, AND a trace bound at
    `{T.anchor.proto, wp}` (existence scan of cache — NOT findTrace's selected identity). succ =
    `{T.anchor.proto, wp}`. Else no edge.
  - succ_proto = **T.anchor.proto** (same-proto; matches driveChain's single `proto` threading).
    Cross-proto resume-proto is a known deferred refinement (nsieve doesn't exercise it). NOTE this in code.
  - **Self-loop worry was UNFOUNDED:** ordinary same-anchor deopts have `guardExitPc` null or
    `wp==anchor.pc`, so they form NO edge. Only numeric/branch guards + `.link_terminal` do.
- Tests: cache built on a hand-built 2-anchor graph incl. a `.link_terminal` edge; wholesale rebuild on
  retire; canonical-order total-order property. `Trace.id` is u32 (ExitKey.trace_id).

**Then A-ii.3** (recordInstr hook @4257 capturing `{proto.id, source_pc = pc -| 1}` per recorded op,
transient per-trace, fail-soft no-`.alloc`-abort) **and A-ii.4** (Tarjan-SCC over anchors; region_intern
w/ canonicalEql; region_defs Proto/VM-lifetime; physical member-scoped classification indices;
executable owner predicate = unique external-entry loop root else armable=false; def-consistency rebind
tombstone; transactional+fail-soft: stage-all→ensureUnusedCapacity→infallible publish, commit-OOM
retains / retire-OOM empties; classifyExit pure query; interp.zig:9030 empty-after-flush guard test).
accountRegionProfit stays no-op through all of A-ii.

**Rules kept in mind:** #13 (per-file/ bundled commits, never `add -p`), CLAUDE.md+TODO.md never staged,
#15 git allowlist, Z-1 (verify stdlib), Z-3 (green+tested), Z-6 (no single-benchmark opt), design-doc
skill (status header + checklist ticked as work lands). Monitor tool NOT used. Review model = gpt-5.6-sol
(never pin gpt-5.2*).

---
## Status 2026-07-18 (LATEST-16) — ROUND-9 LANDING PLAN written + reviewed + COMMITTED. Design-only (no code). Bart: "go back to bigger increments" → chose the round-9 landing track. gpt-5.6-sol = BLOCKER (6 defects), all tree-verified + folded.

**Bart's steer:** back to bigger increments; picked "Round-9 landing" over H-2 hard half / GuardProvenance-only.

**Plan (doc-17 §"Round-9 landing plan"):** sequences the grounded blockers into code, split by whether the
consumer machinery exists.
- **9-A (small/safe/immediate):** (i) `pure ⇒ !effect` — the H-4 barrier made structural; (ii) `depth==0`
  clean-entry precondition before `beginTopLevelEpoch`'s disarm (H-3).
- **9-B (foundational plumbing, NO consumer yet):** the `GuardProvenance` IR extension as a **transient
  side table** keyed by the **committed** instr index (NOT a field on `IrInstr`). Tag = `{path:[3]call-edges,
  source_proto_id, source_pc, role, operand}`.
- **Deferred to Increment-3 machinery** (NOT round 9): F2c native-cut harness (H-4 cut) + region cap (H-3
  cap) — need `region_profit`/native-F2c.

**gpt-5.6-sol review = BLOCKER → resolved (design only); 6 defects, ALL tree-verified before folding:**
1. **‡ THE damaging one — emission-time instr-index key is STALE at commit.** `tropt.optimize` renumbers
   (`new_index` `tropt.zig:535`), drops duplicate/always-pass guards (`:299-312`), inserts `.preheader`
   (`:530`) → a side table copied unchanged points at the wrong instrs. **Fix: provenance is remapped by
   the optimizer via `new_index` + copied by `dupe`, keyed by the COMMITTED index.** Guard-dedup survivor
   keeps its own tag (H-1c many-to-one).
2. **Tag dropped leaf `source_proto_id`** (cross-leaf-proto collision) + mis-sized path. Fix: leaf
   `(source_proto_id, source_pc)` are separate tag fields; `path:[MAX_INLINE_DEPTH=3]` holds **edges only**.
3. **"IrInstr field forces schema bump" was WRONG** — `traceser.toSchemaTrace` maps 6 fields explicitly
   (`traceser.zig:66`). Side table chosen for the 16-byte `IrInstr` budget (`trace.zig:5849`) + minority-of-
   ops, not serialization.
4. **`pure⇒!effect` at `interp.zig:916` alone insufficient** — `.manual` early-returns (`:914`), restore
   (`keyframeser.zig:606`), package (`package.zig:434`), synthetic `.pure` sets (`trace.zig:6501/6534`)
   bypass it. Fix: comptime-over-static-tables + restore-path assert.
5. **`depth!=0` "skip-reset" option UNSOUND** — `run`/`start` push a FRESH top-level frame
   (`interp.zig:1025-1035/1046-1052`), never continue; resume is via `exec()`. Fix: fail-closed only,
   **release-enforced** (error/panic, not `std.debug.assert`).
6. **Stamping list incomplete + errors** — omitted `recArrayGet` (`4277`), `recHashGet` (`4698`),
   `recForPrepLink` (`4939`); `source_pc = cur_pc−1` not `cur_pc` (post-increment `trace.zig:5394`); lane
   ordinal must NOT be an `operand` (observed input breaks determinism). Fix: stamp structurally in the
   guard `emit` helper with per-site `(role, operand)`.

- Files: `docs/design/17-exit-branch-patching.md` (§"Round-9 landing plan" + review outcome + header +
  Outstanding bullets). CURRENT_TASK.md. Committed `9acebc1` (doc-only).

**9-A LANDED (code) — `pure ⇒ !effect` + `depth==0` fail-closed:**
- `pure ⇒ !effect`: a `comptime` block over the whole static `base_natives` registry (`interp.zig`,
  after `base_natives`) `@compileError`s if any builtin sets both — structural, covers `manual` entries,
  no install-site bypass. Restore path (`keyframeser.zig:~611`) gets a `std.debug.assert` for a
  caller-supplied `NativeRegistry` (defense-in-depth; the static tables are comptime-proven).
- `depth==0`: `beginTopLevelEpoch` now returns `Error!void` and rejects `depth != 0` with a new
  `Error.DirtyTopLevelEntry` BEFORE `disarmAllLinks` (release-enforced — a returned error, not an
  assert). `run`/`start` `try` it; `catchable()` classifies the new tag not-catchable (unreachable in
  `pcall`). Doc-comment marks where the future region-clear goes (after the same guard).
- Test: "top-level re-entry on a suspended (dirty) VM fails closed" — suspends at depth 3, asserts both
  `start`/`run` return `DirtyTopLevelEntry`, then resumes via `exec()` to completion. **Negative control:
  neutralizing the check fails exactly this test (772 pass / 1 fail), silent `.suspended` misuse.**
- Gate: `just test` green (default + `-Djit-debug`); nsieve tier-0≡native byte-identical. Commit `9fcc2c4`.

**9-B DEFERRED (Bart, 2026-07-18).** The round-9 landing stops after 9-A. The GuardProvenance IR extension
is design-clean but large, must touch the optimizer (`tropt` remap of the side table — emission-index keys
are stale at commit), and has **no consumer** — so per H-1a's grounding it waits until region accounting /
Increment 3 is built and can co-design the exact tag layout it will read. Design of record is preserved in
doc-17 §"Round-9 landing plan" + the deferred Outstanding bullet. **No open round-9 work remains.**

**Remaining doc-17 candidates (not directed):** H-2 hard half (weak-intern id-timeline reconciliation +
`{gc,snapshot}` root-walk split; piece 1 `next_obj_id` v4→v5 landed) — the scope/architecture call Bart
reserved; and, eventually, the Increment-3 machinery that 9-B + the F2c-cut/region-cap pieces attach to.

## Status 2026-07-18 (LATEST-15) — H-3 + H-4 GROUNDED + COMMITTED. Design-only (no code). The two mechanics blockers, grounded against the tree. gpt-5.6-sol = NEEDS-CHANGE (both); all corrections tree-verified + folded.

**Bart's steer:** defer H-1a landing until GuardProvenance is relevant; do the small independent H-3/H-4 first.

**H-3 — region-map cap bound + `beginTopLevelEpoch` clean-entry:**
- **Scope fact:** the `region_profit` accounting map does NOT exist in the tree yet (unlanded round-3/4/5
  Part-A design) — so this grounds a *contract* the round-9 map must satisfy, plus today's epoch entry.
- **(i) Live set bounded ⇒ fail-closed/lifetime-scoped safe, SILENT evict-live banned.** `max_call_depth
  = 200` is hard (`interp.zig:119`, fixed `frames[200]`, `pushFrame` guard `:1347`). BUT `regions_per_frame
  ≤ static anchor count` was OVERSTATED (review) — regions have distinct RegionIds + can share an anchor;
  round 9 must state an explicit per-`(activation,anchor)` cardinality invariant. No global
  `max_anchors_per_proto` (dynamic load) ⇒ leans toward the lifetime-scoped (uncapped-over-live-set)
  option. Only *silent* eviction of a live armed region is banned (atomic disarm-to-fail-closed eviction
  could be safe).
- **(ii) Clean-entry gap REAL and broader than framed.** `depth` has no reset-to-zero; `pcall`/`xpcall`
  restore it directly (`errors.zig:101/109/117`), keyframe-restore assigns it (`keyframeser.zig:710`) —
  so "moved only by ±1" was wrong. The load-bearing invariant: *any* uncaught error leaves frames live
  (explicit `interp.zig:1454`; `StackOverflow` is CATCHABLE contra my draft, but catchability is beside
  the point). Second dirty-entry case the finding missed: a **suspended** VM (no fault needed). Corruption
  worse than "push above stale" — top-level `stop_depth==1` can resume a stale frame. Round 9 needs a
  **`depth==0` precondition checked BEFORE `disarmAllLinks`/map-clear** (else rejecting a run on a
  suspended VM corrupts its resumable epoch). `beginTopLevelEpoch` today only `disarmAllLinks()` (`:1012`).

**H-4 — the only implementable F2c logical cut:**
- **Mechanism:** `suspend_ctl{min_depth, after_safepoints}` (`interp.zig:418`) checked at ONE tier-0 site
  (`:1716`), safepoint-counted (`:1704`); native runs bursts and doesn't advance `safepoint_seq` ⇒ a
  safepoint cut is tier-dependent (G-4). (`suspend_ctl != null` doesn't stop native *running* — only
  disables fusion, `:2627`.)
- **Effect boundary = the one implementable tier-independent cut.** Host effects abort the trace
  (`.host_barrier` `trace.zig:5046`; only `PureBuiltin` sqrt inlines, no effect) ⇒ no effect ever commits
  on-trace ⇒ the tier-0 boundary after the Nth effect is always reached. BUT (review) the barrier isn't
  structural: `pure`/`effect` are independent fields (`function.zig:229/238`), `recCall` checks pure
  first ⇒ round 9 must **enforce `pure != null ⇒ effect == null`**.
- **"Iteration K" not implementable** (effect-free loop, native overshoots to burst end) without a new
  native logical-yield.
- **Immediate post-effect boundary NOT always suspendable** (review): multret producer sets
  `reg_top_pending` which the suspend gate refuses (`:1719/3685`); a faulting effect has no next boundary.
  ⇒ cut at "first snapshot-eligible boundary after `effect_cursor == N`" on a successful fixed-result
  effect. `SuspendCtl` has no effect-count field ⇒ harness steps one eligible boundary at a time.
- **Assertion = full semantic keyframe** (stack + frames{closure,pc,base,return-wiring,varargs} + heap +
  object-id counter + open upvalues, `keyframeser.zig:279`) **+ replay-driver** (effect log + cursor,
  OMITTED from keyframe `:2090`) **+ output prefix** — not `effect_cursor` alone. Cut after result install
  (`:2272`), never inside `logEffect`. Dovetails with H-5(i)'s omitted dead-temporary bug.

- Files: `docs/design/17-exit-branch-patching.md` (H-3 + H-4 grounding subsections + finding cross-refs +
  header). **COMMITTED** (doc-only).

## Status 2026-07-18 (LATEST-14) — H-1c GROUNDED + COMMITTED. Design-only (no code). Pinned the per-opcode guard-site vocabulary that completes GuardProvenance. gpt-5.6-sol = NEEDS-CHANGE; all corrections tree-verified + folded. The identity shrinks from G-1's 4 axes to **3**.

**Bart's steer:** keep working through the known small-scope pieces. H-1c is the last H-1 sub-part.

**Outcome — the closed guard-site vocabulary (`role`/`operand`, and why `occurrence` dies):**
- **Load-bearing finding:** the IR op kind is a *runtime-varying attribute* of a guard site, not its
  identity — `guardNum`→`guard_int`/`guard_float` by observed value (`trace.zig:4187`); `recBranch`→
  `guard_true`/`guard_false` by taken path (`4834`). So `role` must be a **structural label**, exactly the
  reason `exit_ordinal` was killed, restated one level down.
- **The vocabulary** (closed set of `role`s, corrected against the tree after review) is a per-opcode
  ordered list of `(role, operand)` guard slots — full table in the doc. Review REFUTED my first draft on:
  `set_index` container is `a` not `b`; `for_loop`/`for_prep` guard THREE operand-types (a, a+1, a+2)
  first; hash-set guards the value type FIRST; grid guards row+col types; pure-call guards its arg
  (a+1); +a missing `get_upval`/`get_global`→`guard_func` row. `guard_fits` is every-narrow-lane, not
  int-only (`4480`).
- **`role` is a closed vocab with a RUNTIME-SELECTED realized subset** (not a static function of the
  opcode): `get_index`/`set_index` route array-vs-hash by observed key type (`4052/4063`), `call` routes
  closure-vs-pure (`5033`), `get_upval` emits `guard_func` only if the input is a closure. Not fatal:
  identity must be *non-shifting under sibling elision* (the real G-1 requirement), and structural labels
  are; a differently-shaped re-recording legitimately has different guards.
- **`operand`** must be a register *designator* covering a/b/c + derived a+1/a+2 (numeric-for) + register-
  valued `aux` (grid) — not just instr.b/instr.c. Static bytecode field ⇒ stable. (`recCompare` gt/ge
  swap is AFTER guard emission, so operand tracks the source register — confirmed.)
- **`occurrence` REFUTED → DROPPED (decisive).** Recording-order is a *dynamic* ordinal (branch
  truthiness, inner-loop trip counts via `onBackEdge` peel `3588`, `for_prep` link-vs-loop by cache state)
  → it *slides*, the `exit_ordinal` failure again. Within one opcode-execution `(role,operand)` is already
  unique; duplicates arise ONLY from unrolling, whose copy-index is inherently dynamic ⇒ no stable value.
  **Resolution:** provenance keys the guest-static site `{source_pc, call-path, role, operand}`; unrolled
  physical copies **share** one tag (physical-exit→provenance is many-to-one, correct: same guest check,
  same anchor/counter). `guarded_refs` dedup makes it many-to-one the other way too (a static slot may
  emit no guard) — and my "fresh ref per unrolled iter" claim was false (invariant/konst/pure-callee refs
  stay shared).
- **Follow-on for round 9:** fused native exits aren't all `guard_*` — `hload`/`aload`/`href` side-exit at
  the producer node (`nativegen.zig:4022/4120/3517`); they need `role`s + source-PC stamps too (extends
  H-1b's stamp-every-exit obligation past the 6 PC-carrying ops).
- **Scope:** inseparable from the GuardProvenance IR extension → lands *with* it in round 9, not
  standalone (no non-speculative early subset). Files: `docs/design/17-exit-branch-patching.md` (H-1c
  grounding subsection + finding cross-ref + header). **COMMITTED** (doc-only).

## Status 2026-07-18 (LATEST-13) — H-1a GROUNDED + COMMITTED. Design-only (no code). Pinned exactly what the recorder stores for inlining vs what GuardProvenance needs, so the round-9 provenance landing is turnkey. gpt-5.6-sol = CONFIRMED directional + 3 sharpenings, all folded in.

**Bart's steer:** keep working through the known small-scope pieces. H-1a is the next H-1 sub-part.

**Outcome — the inline call-site path the recorder must carry:**
- **Gap (confirmed, real collision):** `InlineFrame = {base_off, ret_dest, ret_count}` (`trace.zig:5324`)
  stores neither the caller proto id nor the `.call` PC. `recCall` has both (`proto.id` + the call's
  source PC) but discards them (`trace.zig:5095-5099`). So `f(a); f(b)` both inlined → every guard in `f`
  gets identical `{callee_proto, source_pc, inline_depth}` AND identical `base_off` (base_off is a
  function of caller frame layout, not the call opcode) → genuine collision. Unrecoverable from *recorder*
  state (though present in the live VM call stack — `frame.pc-1` + caller `proto.id` — which recCall sees).
- **Fix:** extend `InlineFrame` with `{caller_proto_id: u32, call_pc: u32}` set in `recCall`; provenance
  path = `[(caller_proto_id, call_pc) per open frame] ++ (source_proto_id, source_pc)`. Ordered (multiset
  unsafe — recursion to depth 3 is reachable, `recCall` has no "already-inlined" check, contra doc-10).
  Deterministic: `proto.id` replay-stable (preorder compile ids, disjoint load ranges, reconstructed on
  restore), `call_pc = cur_pc-1`. Precondition: proto-id uniqueness holds for the canonical one-image +
  `load` model, not for hand-built/default-0 protos.
- **Necessary but NOT sufficient:** the ordered path is the static-inline-context PREFIX only — the
  recorder can unroll (`skipBackEdge`, `trace.zig:3580`), so the same path+leaf can emit repeatedly →
  full GuardProvenance still needs H-1c's role/operand/occurrence. H-1a delivers the prefix.
- **Cost:** +8B × 3 = +24B recorder-only; `InlineFrame`/`Recorder` are serialized nowhere (confirmed) →
  purely additive, no wire/behaviour change.
- **Land-now vs defer (Bart's call):** unlike H-1b (which replaced 8 existing derivations), these fields
  have NO consumer until GuardProvenance is built, so landing now adds 2 unread fields. Recommend **defer**
  to the GuardProvenance landing (its consumer, will co-design the tag layout); grounding spec stands.
- Files: `docs/design/17-exit-branch-patching.md` (H-1a grounding subsection + finding cross-ref +
  header). **COMMITTED** (doc-only).

## Status 2026-07-18 (LATEST-12) — H-5 GROUNDED (both hazards) + COMMITTED. Going-in hypothesis "discharge as N/A" REFUTED by gpt-5.6-sol; both hazards are REAL, tree-verified. Doc-only (no code). The grounding's value: it found two real issues and correctly folded each into an existing tracked blocker.

**Bart's steer:** pick up H-5 (both "needs grounding" round-8 items) as a small-scoped, non-breaking piece.

**Outcome — both REAL, neither independently closeable:**
- **H-5(ii) (metadata id leakage) ⊆ H-2.** No *direct* leak — trace metadata is `gpa`/mmap and never
  calls `gc.link` (the only `next_obj_id` bumper). BUT cached/in-progress trace consts are GC roots
  (`interp.zig:1560/1583`), so a trace-rooted interned string survives a sweep tier-0 would collect
  (`gc.zig:531/542`); a later re-intern allocates fresh under tier-0 (bumps counter) but reuses the
  rooted original under the JIT (no bump) → tier-dependent counter + intern identity + snapshot
  reachability (`keyframeser.zig:268`). That IS H-2's hard half. Also corrected a stale premise:
  `new_table`/`concat`/`closure` **abort recording** (`.nyi_opcode`, `trace.zig:4093`) — traces
  materialize no such guest objects today.
- **H-5(i) (dead-register poisoning) ⊆ F-5.** Confirmed safe on the cut side: suspend checked only in
  tier-0 `step` (`interp.zig:1716`), native is a synchronous trampoline returning via `shared_exit`,
  links disarmed under `suspend_ctl != null` (`interp.zig:2632/2643`), F2c serializes only after
  `.suspended` — **no cut is ever taken mid-native-frame**. BUT register coherence is FALSE: numeric-`for`
  traces omit dead expression temporaries from the exit snapshot (`trace.zig:3761`, permanent proof
  `interp.zig:9180`), so those physical slots hold stale pre-entry values after a native run while
  tier-0 overwrote them. A post-native-exit mid-execution cut serializes the full window
  (`keyframeser.zig:279`) → **divergent bytes vs tier-0**. Unreachable today ONLY because F2c's
  mid-execution harness is tier-0-only (`keyframeser.zig:1972/2014`) = the F-5 gap. This upgrades F-5
  from "unverified obligation" to "has a concrete coherence bug to catch," and makes the native-F2c
  test **mandatory before** any native mid-execution cut lands.
- Files: `docs/design/17-exit-branch-patching.md` (H-5 grounding subsection + finding cross-ref +
  header). **COMMITTED** (doc-only). No Antigravity round — counterexamples concrete + tree-verified.

## Status 2026-07-18 (LATEST-11) — FOUNDATIONAL PIECE 2 (H-1b) LANDED + COMMITTED. Named the source-opcode PC distinctly from the resume/exit PC via a canonical `guardSourcePc` accessor; centralized the 8 open-coded `guardExitPc(g)-1` derivations; fixed conflated docs. Non-breaking (no `aux`/wire/control-flow value changed). `gpt-5.6-sol` review = NEEDS-CHANGE→clean (design-only fixes). `just test` green (772, default + `-Djit-debug`), nsieve byte-identical, test proven load-bearing.

**Bart's steer (this session):** pick up **H-1b** next ("split source-opcode PC from resume PC in guard
metadata") — a foundational, non-breaking piece of the H-1 guard-provenance blocker that shrinks
round-9 scope.

**Piece 2 LANDED — H-1b source/resume PC split.** The recorder conflated two PCs: `recordInstr` gets
the *post-increment* pc (`interp.zig:1762` = `cur+1`), guards stamp it into `aux`, so a committed
guard only carried the **resume/exit** PC — while `GuardProvenance` (G-1) needs the **source-opcode**
index. Landing (recommended derived-accessor shape; heavier stored-field alt deferred to G-1):
- New `pub fn guardSourcePc(ins) ?u32` in `trace.zig` = `guardExitPc − 1` (null on the 0 sentinel) — the
  single canonical "which bytecode op owns this guard" definition.
- Rerouted the 8 open-coded `code[guardExitPc(g)-1]` source derivations through it: `irinterp.zig:229`;
  `trace.zig:489/2548/2909/2960/3089`; `nativegen.zig:3396/3617` (last drops a now-dead `exit_pc`).
- Fixed the 3 conflated doc comments (`RecState.cur_pc`, `emit`, `guardExitPc` "five"→"six") + a stale
  `countProductiveBranchExit` identity comment.
- Test `"guardSourcePc: source-opcode PC is exit PC − 1 (H-1b), pinned independently"`: review-mandated
  *independent known-index* assertion (recorded `get_index` at chosen N ⇒ `guardSourcePc==N`,
  `guardExitPc==N+1`) + `emit`-fixture for `guard_number`/`int_of_float` (never recorder-emitted) + null
  cases. Load-bearing: dropping the `−1` reddens 16 tests (10 fail + 6 crash).
- Non-breaking: no `exit_pc`/`aux` value, control-flow target, IR layout, or serialized byte changed;
  10-mode-invariant by construction. `gpt-5.6-sol` confirmed soundness + all 8 `.?` unwraps safe.
- **COMMITTED** (see below). H-1's remaining round-9 scope: `source_pc` is now a named, tested,
  single-owner accessor `GuardProvenance` reads directly.

## Status 2026-07-17 (LATEST-10) — BART DECIDED + FOUNDATIONAL PIECE 1 LANDED. H-2 fix = keyframe schema bump (reverses the "v4 stays" reshaping insight). Bart: land the safe foundational pieces first to shrink scope. Piece 1 (`next_obj_id` serialization, v4→v5) DONE — `just test` green (default + `-Djit-debug`), viz builds.

**Bart's two decisions (this session):**
1. **H-2 → fix now with a schema bump** — serialize `next_obj_id` + reconcile weak-intern identity so
   restore reproduces the id timeline regardless of tiering. Keyframe schema moves (was "v4 stays").
2. **Don't land Increment 3 all at once** — pick up the earlier foundational pieces that are
   unambiguously useful + non-breaking first, so later work shrinks.

**Piece 1 LANDED — `next_obj_id` serialization (keyframe v4 → v5):** the counter-drift half of H-2,
and a pre-existing determinism gap independent of the JIT. The restorer reconstructed the heap id
counter as `max(id)+1` (`gc.zig:149`, `keyframeser.zig:~555`) — correct only with no pre-cut garbage,
a limitation the F2c harness itself admitted (`keyframeser.zig:~1758`). Now serialized as a `Keyframe`
field and restored verbatim, validated `>= max(id)+1` (`NextObjIdBelowObjects`). Garbage-free runs are
unaffected (serialized == max+1); only the previously-unsupported garbage case becomes correct.
- Files: `schema/trace.json` (+ regenerated `src/gen/trace_schema.zig`, `viz/src/gen/generated.ts`),
  `src/keyframeser.zig` (encode/restore/version-bump/tests), `docs/design/04-snapshot-replay-schema.md`,
  doc 17 §"H-2 decision + foundational piece 1 LANDED".
- Tests: `"H-2: next_obj_id survives pre-cut garbage"` (gc_stress, garbage after survivor → counter >
  live count → restored verbatim + byte-identical round-trip; proven load-bearing by an impossible-bound
  flip that reddened exactly it) + a `NextObjIdBelowObjects` corrupt-snapshot case. 772 tests, green.
- **Not committed** (Rule #15 — awaiting Bart).

**Still owed for H-2 (the HARD half — needs its own design + review):** weak-intern identity
reconciliation + the safe `{gc,snapshot}` root-walk split. Serializing `next_obj_id` fixes counter
*drift* but a *dropped trace-only interned object* still re-interns fresh at the (now correct) high
counter ≠ its original low id. So the split stays unsafe until interned identity survives a drop —
the next H-2 design pass. Mechanics blockers H-1 (guard provenance), H-3 (cap + clean-entry), H-4
(logical cut) are untouched by piece 1 and remain round-9 design work.

**Candidate next foundational pieces (for Bart to steer):** (a) design the H-2 intern-identity half
(the hard part; design→review loop); (b) H-1b — split source-opcode PC from resume PC in guard
metadata (clean, useful, but touches the recorder — needs care); (c) pause and pick up the mechanics
design (H-1/H-3/H-4) instead.

---

## Status 2026-07-17 (LATEST-9) — ROUND-8 REVIEWED = BLOCKER (both) with a FOUNDATIONAL finding (H-2) that BOTH reviewers built the SAME counterexample for. ESCALATED TO BART — a scope/architecture decision is needed before round 9. NO code.

**The inflection (H-2 ‡‡ — foundational, escalated):** G-2's `{gc,snapshot}` root-split is necessary
but NOT sufficient. Dropping a **trace-only interned** constant (a folded string kept alive only by
the trace root, object id N) changes the observable heap-**id** timeline: the uninterrupted VM later
re-finds the interned object → recovers id N, but the restored VM (empty trace cache, no intern entry)
re-allocates → id N′ ≠ N. Object ids are **semantic** — equality `value.zig:197`, table hash
`table.zig:545`, `pairs` order `key_order.zig:21`, `tostring` `io.zig:166` — so `pairs()` output and
serialized table capacity **diverge**. Compounding: `next_obj_id` is **not serialized** (restore =
`max(id)+1`, `keyframeser.zig:521`) and the F2c test **already** only supports programs with no
discarded pre-cut objects (`keyframeser.zig:1755`) — dropping the highest-id trace-only object hits
exactly that unsupported case. **codex + Antigravity built the identical counterexample independently.**
This is **broader than Increment 3** (any trace-materialized object under snapshot) and its clean fix
likely **serializes `next_obj_id` → bumps the keyframe schema, reversing the reshaping insight** — or
restricts when snapshots may be cut. **This is Bart's call (scope + approach) before any round 9.**

**Mechanics blockers that survive (round-9 work, once H-2's direction is set):**
- **H-1 (G-1)** `GuardProvenance` still collides: `inline_depth` counts nesting not the call PATH
  (`f(a);f(b)` → same tuple, distinct exits) → need a full inline call-site path
  `[(caller_proto_id, call_opcode_pc)…]`; `source_pc` is the **post-increment** resume-PC not the
  opcode index (`interp.zig:1762`) → need both distinct; `operand`/`occurrence` under-defined for
  derived-value guards (one `get_index` guards container/lane/bounds/presence/loaded-value) → need a
  **closed per-opcode `GuardSite` vocabulary** ranked independent of emission order/elision.
- **H-3 (G-3)** mandatory deletion bounds the map but doesn't prove a bounded cap can't evict a LIVE
  entry (need cap ≥ proven max simultaneous live regions with a hard `regions_per_frame` bound, or
  fail-closed insert); `beginTopLevelEpoch` still doesn't enforce clean entry (an unconditional clear
  after a non-catchable fault deletes still-live activation accounting) → must pick reject-unless-
  `depth==0` / real reset / poisoned-VM.
- **H-4 (G-4)** "Kth committed outer iteration" is unimplementable (native runs many iterations per
  call; `suspend_ctl` only checked at dispatcher return `interp.zig:1716` → native overshoots with
  extra committed non-effect state) → only "immediately after the Nth committed **effect** opcode
  boundary" works; assert the whole logical-cut identity, not just the effect cursor.
- **H-5 (Antigravity, to ground)** dead-register poisoning on a native-frame cut; JIT-metadata id
  leakage (almost certainly N/A — object ids are `GcHeader.id`, trace IR is `gpa` metadata — but
  ground that trace metadata never touches `next_obj_id`).
- **G-5 RESOLVED** — single physical stack today; re-key invariant vacuous-but-correct.

**Trajectory note:** the exit-branch-patching *mechanics* are converging (H-1/H-3/H-4 are each
well-scoped engineering). H-2 is the outlier — a foundational JIT×replay heap-identity question that
predates and exceeds doc 17. That's why it's escalated rather than ground into a round-9 pass.

---

## Status 2026-07-17 (LATEST-8) — ROUND-7 DESIGN WRITTEN + REVIEWED = BLOCKER (both), two deep new findings on the JIT↔snapshot boundary → ROUND-8 DESIGN WRITTEN (G-1..G-5 resolved+grounded). codex+Antigravity round-8 review PENDING. NO code until round-8 review-clean.

**What happened since LATEST-7:**
- **Round-7 design pass WRITTEN** (doc 17 §Part A — round-7 design) resolving F-1..F-8, both round-6
  forks collapsed to single sound answers.
- **Round-7 REVIEW DONE (codex gpt-5.6-sol + Antigravity) = BLOCKER (both).** Four resolutions hold
  (F-3 exact-frame; F-4 allocator, reworded to "replay-equivalence conditional on no
  allocator/mcode exhaustion"; F-5 obligation; F-6 polarity). Two DEEP new findings survive, plus two
  more:
  - **G-1 ‡ (codex STILL-BLOCKER + Antigravity UNSOUND)** — round-7's `exit_ordinal` by IR position
    is NOT re-recording-stable: recording is guest-value-dependent (`guardNum` picks int/float
    `trace.zig:4165`, array-guard sequences vary `:4255/:4382`, type-feedback guard elision / LICM
    shifts ranks). AND grounded: `guardExitPc` (`trace.zig:451`) supplies `exit_pc` for ONLY the 5
    PC-carrying guards + `int_of_float` — array/table/grid guards leave `aux`=lane/zero, so the IR
    **cannot** key those exits at all today.
  - **G-2 ‡ (codex STILL-BLOCKER — THE DEEP ONE, I confirmed against the tree)** — the transient
    trace cache roots heap objects INTO the serialized snapshot. `keyframeser.zig:265` seeds its
    reachable-set walk from the shared `forEachRootHeader`, whose **item 5** (`interp.zig` ~1560/1583)
    roots every cached-trace + in-progress-recording const; its own comment: *"a cached trace can
    outlive its proto's reachability."* So a tiering-dependent `region_profit` history → different
    live traces → different otherwise-dead heap objects retained → **final-snapshot bytes can
    differ.** Round-7's "the snapshot carries neither field so bytes are unchanged" is FALSE (roots
    leak in indirectly). Latent today only because the F2c harness is tier-0-only.
  - **G-3 (codex STILL-BLOCKER)** — monotonic keys stop mistaken-reuse, but a bounded/LRU cap can
    still **evict LIVE activation accounting** → perturbs region gating; and no enforced clean-entry
    rule (`run`/`start` don't require `depth==0`).
  - **G-4 (codex STILL-BLOCKER for cuts)** — a native F2c cut selected by safepoint count is
    tier-dependent (native runs fewer dispatch safepoints → `suspend_ctl` cuts at a different logical
    point → different-length effect-log prefix).
  - **G-5 (Antigravity)** — cross-stack coroutine re-key collision: grounded **N/A** (mahina has ONE
    physical stack; keyframeser has no multi-stack path). Invariant pinned for a future coroutine
    feature.
- **Round-8 design pass WRITTEN** (doc 17 §Part A — round-8 design), grounded (`guardExitPc` gap +
  the shared-root serializer seed both verified in the tree):
  - **G-1** → abandon the IR-position ordinal; stamp a guest-logical `GuardProvenance`
    `{source_proto_id, source_pc, inline_depth, role, operand, occurrence}` at guard emission for
    ALL guard kinds (a new IR metadata obligation). Key is a pure function of guest semantics →
    stable across re-recording **by construction of the tag**, not by asserting recording-determinism
    over guest-value-dependent inputs.
  - **G-2 ‡** → split `forEachRootHeader(kind: {gc, snapshot})`. Collector uses `.gc` (unchanged —
    trace consts stay rooted, never prematurely freed). `keyframeser` uses `.snapshot` (trace +
    recording consts **excluded** from the serialized walk). Proof: every trace const is either
    (case 1) also semantic-reachable ⇒ excluding the trace edge changes nothing, or (case 2)
    trace-only ⇒ **semantically dead** because deopt resumes at the loop header and *recomputes* it →
    correctly dropped. Makes ALL snapshotting JIT-independent **by construction** — the general fix.
  - **G-3** → make activation-scoped cleanup MANDATORY (delete each `region_profit` entry at frame
    pop `interp.zig:2345/2364/2395` + all three `protectedCall` unwinds `errors.zig:100/108/117`,
    centralized with the depth restore). Entry lifetime = activation lifetime ⇒ the map holds only
    live accounting ⇒ the cap can **never** evict a live activation (defeated by lifetime
    construction, not a heuristic). Plus unconditional `beginTopLevelEpoch` region-clear.
  - **G-4** → define the native F2c capture cut by a **tier-independent logical event** (Nth
    committed effect / Kth committed outer iteration), assert on the effect-log **cursor/prefix at
    that logical cut**, not on safepoint counts; final-snapshot byte-identity now enabled by G-2.
  - **G-5** → pin the single-stack re-key invariant (if coroutines/multiple serialized stacks are
    ever added, `call_seq` re-key MUST become global-flat monotonic across all stacks).
  - Keyframe stays **v4**. Two new impl obligations: the **`GuardProvenance` IR extension** and the
    **`{gc,snapshot}` root-walk split**.

**Next:** launch codex gpt-5.6-sol + Antigravity round-8 reviews (stress G-1 provenance-tag
determinism, G-2 the case-1/case-2 semantic-root proof — esp. whether any trace-only const is
semantically LIVE-but-unreachable-from-semantic-roots, G-3 mandatory-sweep completeness). If clean,
design is implementation-ready (still NO code until Bart's workflow confirms review-clean). If new
blockers, iterate to round 9.

---

## Status 2026-07-17 (LATEST-7) — ROUND-6 DESIGN WRITTEN + REVIEWED. Reshaping insight SURVIVES; BLOCKER on the restore path → ROUND-7 needed (F-1..F-8, two forks for Bart). NO code until round-7 review-clean.

**What happened since LATEST-6:**
- **Three parallel tree-grounding sweeps** ran first (trace inlining + deopt frame reconstruction;
  keyframe/snapshot schema + versioning; coroutine + error-unwind model) so round 6 is code-anchored.
- **Round-6 design pass WRITTEN** (doc 17 §Part A — round-6 design) resolving E-1..E-7 around **one
  reshaping insight ‡**: `region_profit` + `call_seq` are **transient JIT-tiering state, NOT
  replay-serialized** (same category as the trace cache / `safepoint_seq` / `effect_cursor` — none
  ride the keyframe) because they steer only *which tier* runs, never *what it computes* (native ≡
  tier-0 in output). That **collapses E-5 to NO keyframe v4→v5 schema bump** (reset-on-restore, the
  reviewers' own "logical reset" alternative) and **collapses E-2** (activation key = the *anchor*
  frame's `call_seq`, assigned in tier-0 at `pushFrameVararg` interp.zig:1346, never mutated
  on-trace since inlined callees push no physical frame → tier-invariant, no new IR op). This is a
  **deviation** from LATEST-6's recorded "build the v4→v5 schema" — flagged in-doc for veto.
- **Round-6 REVIEW DONE (codex gpt-5.6-sol + Antigravity) = reshaping insight SURVIVES / BLOCKER.**
  - codex (read the tree): **"a v4→v5 schema bump is not inherently required"** → **E-5 deviation
    VINDICATED, keyframe stays v4.** Marks E-3/E-4/E-6 RESOLVED.
  - Antigravity: UNSOUND, but its sharpest counterexamples are **defused by mahina facts codex
    verified** — address-dependent `pairs()` (mahina iteration keyed on monotonic `GcHeader.id`,
    address-independent), side-exit callee-frame reconstruction (mahina resumes at loop header, no
    rebuild), `__gc` finalizers (finalizer-free GC), background compilation (synchronous). Recorded
    as "we checked, doesn't apply" notes that strengthen the doc.
  - **Surviving round-7 blockers (F-n), the work is restore-path precision:**
    - **F-1 ‡** `StructuralEdgeId{proto,anchor_pc,exit_pc,succ_anchor_pc}` can **collide** — recorder
      emits multiple guards per bytecode instr, all sharing `rec.cur_pc` (trace.zig:3956/4084). FIX:
      add a stable guard-ordinal + role/op/polarity discriminator, proven stable across re-recording.
    - **F-2 ‡ (the central correction)** restore is a physical-frame construction path
      (`keyframeser.zig:671` writes `vm.frames[i]` directly, bypassing `pushFrameVararg`), so
      "reset call_seq=0, per-frame irrelevant" is **WRONG**: restored live frames can enter regions
      and recursive snapshots hold several live same-proto instances needing distinct keys. FIX:
      reset `region_profit` empty; **assign each restored live frame a fresh unique transient
      `call_seq` by frame order**; set `next_call_seq` above that range. Still **no wire field**
      (map empty) → v4 holds; only the reset *procedure* changes.
    - **F-3** activation key must be the EXACT current physical frame (`frames[depth-1]`), not a
      proto match (wrong activation under recursion); + `next_call_seq` exhaustion contract (u64 wrap
      → fail-closed).
    - **F-4 (FORK for Bart)** JIT + VM share the backing allocator → a divergent post-restore tiering
      timeline can OOM one timeline only (truncated output). Options: (i) exclude allocator exhaustion
      from replay equivalence, (ii) isolate/budget JIT allocations, (iii) fail-closed policy.
    - **F-5** current F2c/F2d harness is tier-0-only (keyframeser.zig:1863/1905) → owe a
      **native-F2c test** (restore with empty trace/region cache, re-enable JIT, assert output +
      effect order/cursor + final snapshot byte-identical).
    - **F-6** E-6 exit-test polarity in the round-6 text is **backwards** — correct: close region iff
      `outside-region identity AND current_depth <= captured_anchor_depth` (deeper re-entrant call →
      anchor still live → don't close).
    - **F-7 (FORK for Bart)** non-catchable faults don't guarantee whole-VM teardown (host may reuse
      the VM). Options: (i) explicit VM reset dropping activation-owned region state, (ii) cleanup at
      every public execution boundary on escaping error, (iii) documented poisoned-VM invariant. Also
      centralize accumulator cleanup with `protectedCall`'s **3-site** depth restore
      (errors.zig:100/108/117).
    - **F-8** ground (not assert) that a tier-dependent `safepoint_seq` count can't perturb the
      serialized effect-log ordering/cuts. Almost certainly a non-issue (native already runs fewer
      safepoints; `safepoint_seq` re-derived, not serialized) but must be verified in the tree.
    - Phrasing: soften "native ≡ tier-0 by construction" → **asserted by the 10-mode matrix
      (P-EBP-1), not assumed by construction.**

**NEXT ACTION:** Round-7 design pass folding F-1..F-8. Ground F-4 (allocator sharing) + F-8
(effect-log cut drivers) in the tree first. Present the two forks (F-4, F-7) to Bart. Then
re-review (codex gpt-5.6-sol + Antigravity). NO code until round-7 is review-clean. Task #21.

---

## Status 2026-07-17 (LATEST-6) — ROUND-5 DESIGN WRITTEN + REVIEWED = BLOCKER (both). Edge-4 bridge mechanism (D-1/D-2/D-6) now SOUND; surviving blockers are cross-cutting integration surfaces (E-1..E-7). The review RE-WEIGHTS Bart's D-3c=β choice → **α/β RE-CALL surfaced to Bart**. NO code until round-6 review-clean.

**What happened since LATEST-5:**
- **Round-5 design pass WRITTEN** (doc 17 §Part A — round-5 design, D.1–D.6) folding Bart's
  D-3c = **(β) build activation discrimination** via a per-VM monotonic `call_seq` on `CallFrame`.
- **Round-5 REVIEW DONE (codex gpt-5.6-sol continued its own thread + Antigravity) = BLOCKER (both).**
  Both RESOLVED D-1 (two-cell cap reserve — codex verified the induction against the real append
  sites), D-2 (set E vs S, drop `final_trace_id`), D-6 (precisions). Surviving items (doc 17
  §Review outcome — round 5 as E-1..E-7) are NOT bridge flaws — they're integration surfaces the
  round-5 machinery pulls in:
  - **E-1 ‡ `RegionDef` must not be keyed by ephemeral `Trace.id`.** Persistent region_defs is
    Proto/VM-lifetime but members = `(trace_id, exit_instr)`; re-recorded edges get NEW ids
    (trace.zig:3841) after retirement (:3397) → won't match. FIX: stable structural edge id
    (proto+bytecode-anchor+target) for the persistent def + ephemeral `(Trace.id,exit_instr)→edge`
    lookup rebuilt on commit, removed on retirement. Load-bearing — E-3/E-4/E-5 lean on it.
  - **E-2 ‡ `call_seq` can't be a physical `CallFrame`-push counter** — tracing inlines cross-frame
    calls (trace.zig:4014), so native ≠ interp frame pushes → tier-divergent counter. FIX: (a)
    tier-independent logical-call event, or (b) fail-closed decline regions whose root can be
    trace-inlined. **β-specific.**
  - **E-3 classifier key absent at synthetic scalar sites** — onSideExit(seed,0) (trace.zig:2708/2873)
    has no exit_instr; `0` misclassifies. FIX: optional/unclassified key or separate synthetic API.
  - **E-4 overlapping-PC region exit** — leaving region A for sibling B sharing A's PC leaves A's
    accumulator open. FIX: a transition to a region identity outside the active region is a genuine
    exit even when the PC overlaps.
  - **E-5 ‡ keyframe capture/restore** — CallFrame has no field (interp.zig:327), schema doesn't
    carry it (schema/trace.json:163, keyframeser.zig:274/671), format still v4 (:59). FIX: serialize
    `call_seq` + VM counter + active `region_profit`, bump v4→v5 — OR define snapshot as a logical
    region reset done identically in both timelines. **`call_seq` half is β-specific.**
  - **E-6 coroutine thread-scoped depth** — the `depth <= root_frame_depth` exit check must be
    against the originating coroutine's stack (Antigravity MF2).
  - **E-7 error-unwind cleanup** — pcall/xpcall unwinding must drop active region_profit whose root
    frames unwind; `__gc` finalizers must not run guest code at non-deterministic points (MF3).

**THE α/β RE-CALL (Bart's decision, prompted by the review):** When Bart chose (β) the visible cost
was "add a `call_seq` field." The review shows β's TRUE cost = E-2 (tier-independent logical-call
event, because of trace inlining) + the `call_seq` half of E-5 (v4→v5 snapshot schema bump). (α)
fail-closed-exclude-recursion avoids ALL of that and unblocks nsieve (non-recursive) now, deferring
β until a recursive region appears. **Independent floor (required under BOTH α and β):** E-1, E-3,
E-4, E-6, E-7, and the `region_profit` half of E-5 — these are general obligations of region-level
accounting, not of recursion discrimination. So α doesn't make Part A trivial; it just removes the
`call_seq`/schema-bump/inlining-invariance sub-project.

**NEXT: await Bart's α/β re-call, then round-6 design pass** — fold E-1/E-3/E-4/E-6/E-7 (+ E-5
region_profit half) unconditionally; E-2 + E-5 call_seq half per the re-call. Then re-review. NO
code until review-clean.

---

## Status 2026-07-17 (LATEST-5) — ROUND-4 DESIGN WRITTEN + REVIEWED = BLOCKER (both), direction reconfirmed. Five converging round-5 must-fixes (D-1..D-5) + one scope fork (D-3c recursion) for Bart. NO code until round-5 review-clean.

**What happened since LATEST-4:**
- **Round-4 design pass WRITTEN** (doc 17 §Part A — round-4 design, subsections C.1–C.6),
  folding Bart's B-3 decision = **(b) generic stubs, armed later**. Resolved B-1..B-9:
  cap-check-first→`ordinary_mini` (B-1/B-2), trace-local generic stub (B-3), persistent
  VM-level region table (B-4), tier-independent classifier (B-6), live-through set (B-5),
  replay-owned resume PC (B-7), synthesized `completed` (B-8), split lifetimes (B-9).
- **Round-4 REVIEW DONE (codex gpt-5.6-sol + Antigravity) = BLOCKER (both), but the direction
  is reconfirmed sound and most of B-1..B-9 are resolved.** codex (the stricter, code-grounded
  reviewer — trust it on overlaps): B-2/B-5/B-7/B-8/B-9 RESOLVED, B-1/B-3/B-4/B-6 still-blocker.
  Antigravity: B-1..B-8 resolved, B-9 still-blocker.
- **The unifying theme both reviewers circle: split the LOGICAL layer from the PHYSICAL layer.**
  The logical region definition (membership, profit accumulator, classifier) must be a pure
  function of the recorded trace graph, owned at **Proto/VM lifetime**, readable by every tier,
  and **NEVER mutated by trace retirement**; only the physical armed-edge (slot + `NativeLink`)
  metadata is retirement-cleaned. Round 4 conflated the two.
- Five converging round-5 must-fixes (doc 17 §Review outcome — round 4 as D-1..D-5):
  - **D-1 (B-1, codex) cap-check off-by-one.** `jae CAP` still lets `len==CAP-1` commit its own
    entry then dispatch → child terminal append dropped, terminal entry describes parent →
    tripwire (nativegen:779) + scalar ABI (:568) violated. FIX: reserve **two** cells →
    `len >= CAP-1 → ordinary_mini`; prove `len<=CAP-1` on stub entry (every armed dispatch
    leaves ≥1 free cell). Retain `exit_instr` write (:4560).
  - **D-2 (B-3, codex) separate compile-time set E from arm-time set S.** eligibility must ref
    only parent-trace-local emitted set E (not C.4 `live_through`, which is arm-time); child
    `inputs.len==0` is arm-time not `t.inputs.len`; DROP `mov final_trace_id,child.id` (impossible
    for a generic stub AND unnecessary — child's `emitReturn` :3249 stamps its id). Arm iff S ⊆ E
    ∪ invariants.
  - **D-3 (B-4, codex) four accounting-state defects.** (a) window remainder: `window_base += N`
    (loop), not jump to total. (b) `RegionKey` needs identity/edge `region_id` — `{AnchorKey,
    activation}` aliases sibling regions sharing `(proto,14)`; keep AnchorKey only as GATE key.
    (c) `FrameId = depth+PC` is NOT a real frame id (frames carry no gen/id, reused —
    interp.zig:327/1346/2364); don't invent one. (d) membership must be discovered from the
    recorded trace GRAPH in every tier (tier-1a never arms), not "at arm time"; region-exit by
    identity/edge not bare PC-set.
  - **D-4 (B-6, codex) classifier keyed `(trace_id, exit_instr)`**, not `(proto, exit_pc)` —
    siblings record opposite guards at the same source PC (`skip.guard_false` vs `cont.guard_true`).
    All tiers have it (native `LedgerEntry`, tier-1a entered-trace + `ExecResult.exit_instr`).
    Split at EVERY `onSideExit` site (replay :2068, driveChain :1815, dispatcher 2852/3010, scalar
    burst), not one per tier.
  - **D-5 ‡ (B-9, both — the convergent determinism fix) logical map never retirement-cleaned.**
    C.1.4(ii) cleans region-map in removeTrace → `gc_stress on` drops membership PC, off keeps it →
    region-exit check diverges → gate divergence. FIX: logical region map = Proto/VM lifetime,
    cleaned only at proto teardown; only the physical armed-edge registry is retirement-cleaned.
  - **D-6 minor:** B-2 "byte-identical" = VM-state/output not literal mcode; B-5 fixed-point over
    cycles + arm iff S ⊆ E; B-7 the C.5 `.yielded region_bridge` prose is wrong (bridge has no
    post-append yield; next hop owns yield).

**ONE SCOPE FORK for round 5 (D-3c, Bart's call) — recursion handling:** a region whose root frame
can be re-entered recursively has two live activations of one `region_id` on the stack. Options:
(α) **fail-closed exclude** — decline to arm any region whose membership includes a call back to
the region-root proto (recursion detectable from the trace graph), exactly like `inputs.len != 0`
is already excluded; nsieve is non-recursive so this unblocks the target with ZERO
activation-discrimination machinery, reversible later. (β) **build activation discrimination** — a
deterministic per-activation accumulator (needs a real frame-activation identity the VM doesn't
currently carry). Correctness-neutral; pure scope.

**NEXT: round-5 design pass** — fold D-1..D-6 with Bart's D-3c decision. Then re-review (codex +
Antigravity). Per Bart: NO code until review-clean.

---

## Status 2026-07-17 (LATEST-4) — ROUND-3 DESIGN WRITTEN into doc 17 §Part A — round-3 design; all nine round-2 blockers resolved with code-grounded contracts. Re-review (codex gpt-5.6-sol + Antigravity) is the next step; NO code until the review is clean.

**What happened since LATEST-3:**
- **Round-3 design pass WRITTEN** (doc 17 §Part A — round-3 design), grounded by reading
  `nativegen.zig:3597-3625`/`4543-4705`, `trace.zig:1550-1581`/`3098-3395`/`2148-2160`,
  `irinterp.zig:154-217`, and the nsieve cont(29) native-IR dump. All nine specifics have
  concrete contracts (A.1 bridge, A.2 accounting, A.3 ledger grammar, A.4 min_useful).
- **Two reframing findings that sharpen the design:**
  1. **An armed ordinary guard is ALREADY a native in-page handoff** (`nativegen.zig:4569-4573`
     resolves `exit_target` through its own `slot[ei]`; `deopt_exit` ends `jmp qword
     [rdx+exit_target]`, :4631-4633). So edges 1–3 all fuse natively today; **edge 4 is the
     ONLY per-iteration Zig re-entry left** (cont's composite guard is unarmed → shared
     `deopt_exit` → dispatcher). Closing edge 4 removes that single re-entry per outer iter.
  2. **Edge 4's coherence gap is exact and grounded to IR indices.** cont computes `count+1`
     (%004) and `next i` (%011) BEFORE its `%023` composite guard, but the phi writebacks that
     store them to homes (`%031→r2`, `%032→r3`, `%033→r6`) are AFTER %023. So at %023-failure
     the shared `deopt_exit` carried-home flush (`:4602-4603`) commits STALE {count, current i}
     — skip needs {count+1, next i}. Hence the dominance-scoped bridge snapshot (commit only
     phis with `update_index < 23` whose target slot is live at skip.entry). Edge 1 needs no
     such snapshot: skip's `%012 guard_false` fires before skip's back-edge, so pre-update
     homes are already correct for ramp.
- **The bridge is an in-page stub, not a heap object** — structurally identical to the existing
  `linked_loop_done_labels` stubs (`:4583-4596`), emitted at compile time in cont's page, INERT
  until armed, branching on slot-armedness (unarmed → `jmp deopt_exit`, byte-identical). The
  existing registry (`resetLinksTouching`/`disarmAllLinks`, reset by `(parent,slot_index)`)
  covers its lifetime for FREE — no separate free path. This dissolves round-2 BLOCKER-1 item 4.
- **Accounting split keeps the common path identical:** a lone trace = a degenerate one-member
  region flushed per-segment, so `accountRegionProfit(region_key, local)` == today's gating for
  every non-fused trace; only fused regions aggregate. `accountTraceRun` keeps `hit_count`
  per-segment so trace SELECTION is byte-identical.
- Doc 17 updated: §Part A — round-3 design added; 3A checklist bullet + Status header + Last
  updated header all note ROUND-3 WRITTEN / re-review pending. Tasks #9 done, #10/#11 (reviews)
  created.

**ROUND-3 REVIEW DONE (codex gpt-5.6-sol + Antigravity) = BLOCKER (both).** They confirmed the
sound sub-parts (A.1.1–1.3 bridge coherence/dominance/ordinary_entry, A.2.1–2.3 accounting
split/normalized-unit/RegionKey, A.3 additive grammar) and converged on 9 concrete fixes
(recorded in doc 17 §Review outcome — round 3 as B-1..B-9):
- **B-1 ‡ (both) forced-yield is broken.** commit-then-yield stamps final_trace_id=skip.id but
  skip never runs if ledger full → terminal-consistency assert (nativegen:771) + scalar ABI
  (:572) + replay desync. FIX (converged): cap-check FIRST; if full → branch to the *unarmed*
  ordinary deopt_exit (stages static parent PC 29, commits nothing, clean tier-0 resume).
- **B-2 unarmed stub must stage exit_target=shared_exit** before jmp deopt_exit (deopt_exit
  unconditionally jmps [rdx+exit_target], field starts 0). Folds into B-1 (reuse the mini-stub).
- **B-3 (NEW, codex) compile-time classifier temporally impossible.** native lowering gets only
  *Trace, not TraceState/region map; pages memoized permanently (trace.zig:3450); the region
  edge is discovered LATER at arm time. → EMISSION-STRATEGY FORK (Bart's call): (a) precompute
  immutable bridge metadata pre-first-compile from trace-local info; (b) emit GENERIC
  bridge-capable stubs at every eligible composite guard, armed later; (c) invalidate+recompile
  the page when the region is discovered.
- **B-4 ‡ (both) logical-window state machine under-specified + physical leaks.** tier-1a/unlinked
  don't arm → can't get RegionKey "at arm time"; "region exit = PC outside membership" breaks on
  NESTED CALLS (gate on stack-depth ≤ region-root frame) and sibling traces; N/crossing/re-entrancy
  unspecified; **accumulator must be a PERSISTENT VM-level region table (proto/VM lifetime), NOT
  trace state, and must NEVER flush on trace retirement** (GC-physical → gc_stress divergence).
- **B-5 fail-closed needs a defined successor live-through set** (r2 is live-through, not in
  skip.entry); B-6 tier-1a/unlinked ledger classifier undefined; B-7 replay must own resume-PC
  from the region edge (LedgerEntry has none); B-8 accountTraceRun must use synthesized completed
  (max(local,1)) not raw local; B-9 region-map lifetime is explicit metadata, not "free".

**NEXT: round-4 design pass** — (1) rewrite forced-yield to cap-check-first→ordinary-deopt
(B-1/B-2), (2) resolve the B-3 emission-strategy fork (ASK BART), (3) spec the persistent
VM-level region table + stack-depth-gated logical-window + tier-independent membership/classifier
(B-4/B-6), (4) fold B-5/B-7/B-8/B-9. Then re-review. Per Bart: NO code until review-clean.
The B-3 emission fork is a genuine architecture decision (Rule #17) — surface to Bart before round-4.

## Status 2026-07-17 (LATEST-3) — Direction DECIDED (gate B); round-2 review of the B design = DIRECTION APPROVED but DESIGN still BLOCKER. Needs a round-3 design pass before any code.

**What happened since LATEST-2:**
- **Trace-selection investigation DONE → arming/patching confirmed LuaJIT-faithful.** doc 15
  + recorder (`recForPrepLink` LINNER) + `luajit -jdump=t` on the same nsieve (3 self-loop
  roots + 8 side traces patched into roots) all show mahina fragments IDENTICALLY to LuaJIT.
  "Fix trace selection / record as one trace" is RULED OUT (both tried-and-rejected it).
- **Gate strategy DECIDED = B (region-level accounting), Bart's call.** Reasoned on merits
  (B measures the right unit / correct regardless of transition cost / retains cold-region
  retirement) over C (exempt-armed). Round-2 review then *corrected the decisive reason* to
  **determinism**: C's "armed" is a physical native-compile state tier-1a/record-only can't
  share → gate-exemption on it diverges across the 10-mode matrix. B still wins; better arg.
- **Doc 17 §Increment 3 rewritten** — added §Part A (RESOLVED) (strategy) + §Review outcome
  — round 2 (the codex+Antigravity re-review of the B design). 3A checklist bullet + Status
  header updated.
- **Round-2 reviews (codex gpt-5.6-sol + Antigravity gemini-3.1-pro) BOTH: direction/gate-B
  APPROVED, design BLOCKER.** They went deep (not rubber-stamps). Nine specifics must be
  nailed in a round-3 pass before code:
  - BRIDGE: (1) dominance-scoped snapshot (only phis dominating cont's composite guard —
    NOT the full `.link` flush, which commits post-guard inner phis that are undefined at
    edge 4); (2) materialize `regs[]` + enter `skip.ordinary_entry` so the child prologue
    re-runs type/shape/identity guards (this is what resolves the invariant-bypass hazard) —
    NOT a physical register shuffle to the loop head; (3) require `skip.inputs.len==0`; (4)
    bridge lifetime/ABI (it's a new object parent-slot→bridge→child, not just an ArmKind).
  - ACCOUNTING: (5) SPLIT `onSideExit` — `accountTraceRun`(coverage/cycle/**hit_count**,
    per-segment) vs `accountRegionProfit`(penalty/gate only); calling it once on skip would
    change hit_count → change WHICH traces select/record (breaks "heuristic-only"); (6)
    NORMALIZED traversal unit (skip composite iters + one per prime cycle; NEVER sum raw
    `rbx`/inner `k` — a big inner sieve loop would look like thousands of outer traversals);
    (7) stable identity `RegionKey` owner `AnchorKey (proto,14)`, not the selected `*Trace`;
    (8) TIER-INDEPENDENT LOGICAL window feeding ONE accumulator (native LEDGER_CAP=32 vs
    tier-1a 8-hop vs unlinked per-segment must NOT define profitability events) + GC-safepoint
    exits excluded (else gates under gc_stress on but not off); (9) additive cross-anchor
    ledger grammar that does NOT weaken the same-anchor `.deopt` provenance(3098)/zero-
    progress(2159) invariants.
  - `min_useful` retune attaches to the BRIDGE not Part B (2.3a indirect slot already removed
    the ~600ns hop; rel32 only removes the slot load). 8 holds IFF the logical window is
    multi-prime; else it gates skip in the dense prefix before the sparse tail → scale→1
    pre-patch. Q4 is subsumed by getting the window right.
  - P-EBP-2 equivalence assertable over the 6 `record+exec-* × gc_stress` modes only.

**NEXT: round-3 design pass** resolving the nine specifics (chiefly: the bridge
dominance-snapshot + ordinary_entry contract, and the region-accounting state machine =
API split + normalized unit + identity RegionKey + tier-independent logical window). THEN
re-review, THEN code. No code until the design is round-clean. Nothing implementation-side
touched this session; tree changes = CURRENT_TASK.md + doc 17 only.

---

## Status 2026-07-17 (LATEST-2) — Increment 3 DESIGN written + BOTH pre-impl reviews in = BLOCKER. AWAITING BART'S DIRECTION CALL before any code.

The doc-17 Increment 3 design and both reviews are recorded in
`docs/design/17-exit-branch-patching.md` → `### Increment 3` (Part A, Part B, and the
two `#### Review outcome` subsections). Summary of where it stands:

- **Design written:** Part 3A = arm the one missing native edge `cont(29).composite-guard
  → skip(14).ordinary_entry` to close `skip→ramp→inner→cont→skip` as one region and
  escape the `onSideExit` gate; Part 3B = faithful `lj_asm_patchexit` rel32 port +
  in-place-patch P-E.
- **Grounding experiment (reverted):** `--jit-stats` shows nsieve:14 = 59% wall / 5%
  traced because GATED; a throwaway `max_penalty=1e9` A/B lifted it to 92.8% traced but
  moved wall time only ~1% → the wall is **per-transition Zig re-entry, not codegen**.
- **codex `gpt-5.6-sol` review = BLOCKER; Antigravity (gemini-3.1-pro) = confirms both
  blockers.** (1) **Edge-4 coherence:** cont's composite guard is coherent at cont's own
  anchor, not skip's header (stale `i`/count) — needs its own materialization/bridge
  contract that commits the outer-back-edge phis, NOT `.ordinary_guard` reuse. (2)
  **Accounting:** `replayLedger` bills per-segment local deltas, so dense short gaps
  (1–3 < `min_useful`) still gate the anchor; the "summed count → never gates"
  mechanism is retracted. Plus the M1 grammar is same-anchor-only (trace.zig:3098) and
  panics on an `rbx`-advancing successor (2159) → new cross-anchor replay grammar
  needed. Part B: "co-location ⇒ rel32 reaches" is FALSE (arena defers cross-region
  reachability), raw rel32 bypasses the forced-yield cap, ordinary guards have no
  per-exit patch point, discovery needs a cross-anchor PC map.

### Trace-selection investigation (Bart asked "investigate trace selection first") — DONE, verdict below

**Verdict: mahina's SKIP/CONT/INNER fragmentation is DELIBERATE and byte-for-byte
LuaJIT-faithful. Antigravity's "record as one trace" reframe is a DEAD END that
*diverges* from LuaJIT, not converges.** Three independent sources agree:
- **doc 15 (`15-nested-loop-linking.md`):** the one-trace approach "was implemented and
  **failed**" (unrolls the inner loop, produces forward-referencing malformed IR that
  trips `assertWellFormed`); "The single-loop trace model cannot represent a nested loop
  as one straight-line body. LuaJIT reached the same conclusion and does not unroll."
- **Recorder code (Explore agent, file:line-cited):** `recForPrepLink` (trace.zig:4917)
  LINNER-aborts any `.root` reaching an inner `for_prep` (:4925); nsieve:29 is a
  `.continuation` trace (not an independent root) that links back to inner root 24. This
  is LuaJIT's `rec_loop_jit → LJ_TRERR_LINNER` verbatim.
- **LuaJIT itself (`luajit -jdump=t` on the SAME nsieve, /tmp/ljd.txt):** 11 traces = **3
  self-loop roots** (line 3 init, line 7 inner, line 5 outer-skip) + **8 side traces each
  patched into a root** (`stop -> 1/3/6`). This maps 1:1 onto mahina: mahina nsieve:24 = LJ
  trace 3 (inner root), nsieve:14 = LJ trace 6 (outer-skip root), nsieve:29→link 24 = LJ
  trace 4 (side 3/3 line 8, `stop -> 3`). **LuaJIT fragments IDENTICALLY.**

The ONLY structural difference LuaJIT→mahina: LuaJIT's `stop -> 3` = the side trace's exit
is **patched** (rel32 jump straight into root 3's mcode, zero interpreter re-entry).
mahina's `.link` goes through per-transition Zig re-entry (~600ns/hop) — which the A/B
experiment already fingered as the wall-clock cost. **That gap IS exit-branch patching =
Increment 3.** So the investigation *confirms* the arming/patching direction and closes
off the "fix trace selection" alternative.

**PENDING DECISION (Bart) — two levels, see doc §Increment 3 → Review outcome:**
1. **Direction:** stay on the *arming/patching* approach (Increment 3, now confirmed as
   the LuaJIT-faithful path) — the reviews' blockers define the real work, NOT a trace-
   selection rewrite. Antigravity's "record as one trace" reframe is **ruled out** by the
   investigation above (it's the exact thing mahina + LuaJIT both tried-and-rejected).
2. **If arming:** which gate strategy — (a) per-segment accounting + measure (partial
   win; entry still gated), (b) region-level accounting (P-EBP-2 redesign), or (c)
   Antigravity's "exempt armed edges from the deopt penalty" (cleanest; still
   P-EBP-2-relevant). Plus the edge-4 bridge-materialization contract is mandatory
   regardless.

No code has been written for Increment 3. The only tree change this session is this
file + doc 17. The `max_penalty` A/B experiment was reverted; baseline restored.

---

## Status 2026-07-17 (prior) — Increment 2 (all of 2c-*) + coverage-viz arc DONE; NEXT = doc 17 **Increment 3** (exit-branch patching + P-E lifetime)

**Reality reconciliation (the block below dated 2026-07-14 is SUPERSEDED — it reads as
if 2c-E/E2 were mid-flight; they landed and are committed).** What actually happened
since:

- **2c-E LANDED + committed** — `42ae4ba` "feat(jit): close native continuation↔inner
  cycle (2c-E) + add compile-gated jitdbg". E1/E2/E3 all landed (the E2 spec in the
  superseded block was implemented; `armLoopDoneLink` + the `native_loopdone_link_*`
  counters are live in `src/trace.zig`).
- **2c-F LANDED + committed** — `eb21d7e` (disarm integration tests + `native_link_disarms`)
  and `0352beb` (harden + epoch-contain the fused native C↔I cycle; `beginTopLevelEpoch`
  → `disarmAllLinks` at every fresh top-level run). See TODO.md "RESOLVED (2c-F)" for the
  cold-re-entry root cause + fix.
- **This completes doc 17 Increment 2** (shared trampoline + frameless bodies + the native
  C↔I cycle, P-A/B/C/F/G). Increment 1 (shared arena, P-D) was already `a970da4`. The
  native transition today still hands off **through `driveChain` — the ~600 ns Zig
  re-entry**; removing that is Increment 3.
- **Coverage instrumentation + visualizer arc LANDED + committed** (`513f5b4` accounting +
  `--jit-coverage/--jit-stats` → TSC time split → `e6250ff` serialization + `--emit-coverage`
  → `bf94928` WASM surface → `713d099` viz Phase 3 line-shading + stats → real-time units →
  `8cf0cde` run the wasm VM in a Web Worker = current HEAD). Built precisely because we kept
  optimizing the *already-traced* 5% of nsieve; the instrument now shows the honest
  wall-clock split.

**Coverage measurement of nsieve 9 (`--jit-stats --jit-native`, ReleaseFast, 2026-07-17)
— this picks the next target:**
- By iteration count: 69.4% traced (flatters the JIT). **By TSC time: only 6.3% of the run
  ran as native trace; 92.5% is "tier-0, has-trace" — a native trace EXISTS but the
  dispatcher fell back to the interpreter.**
- Per-anchor (`proto:pc`, not source line): **`nsieve:14` (outer scan `for i=2,m do if p[i]
  then <inner> end end`) = 58.1% of wall clock, 5.0% traced.** `nsieve:24` (inner sieve) =
  13.6%, 96% traced (healthy). `nsieve:4` (init) = 27.1%, 57% traced.
- Diagnosis (measured, not inferred): **zero recording aborts; all 5 traces native-compiled
  (928–1434 B x86-64).** The full linked structure exists — root trace (`p[i]==false` common
  path) + side trace (`p[i]==true`) + `nsieve:29 … link -> 24` into the inner loop — and the
  native chaining fires (`prime-side chain-follows=40289`, `native link exits=40291`). So the
  loss is **purely re-entry**: the outer loop can't stay native across its `if p[i]` branch +
  nested-loop return; it drops to tier-0 and re-warms every ~11 iterations. Exactly what doc
  16's correction predicted.

**NEXT — doc 17 Increment 3 (line 1269): Exit-branch patching + lifetime (P-E).** The two
structural blockers that once made this a new-ABI problem (per-trace C frames P-A;
non-co-located pages P-D) were removed by Increments 1+2, so it's now the tractable
`lj_asm_patchexit` port it couldn't have been before. Three pieces:
1. **The patch** — port `lj_asm_patchexit` (`~/Projects/LuaJIT/src/lj_asm_x86.h:3127`):
   rewrite a guard's `jcc`/tail-`jmp` rel32 in place → jump straight into the child body,
   replacing the `driveChain` re-entry. Patch site already exists (per-`exit_instr`
   `jmp deopt_exit` stub, `nativegen.zig:3845`); needs `exit_instr → mcode-offset` map
   persisted on `CompiledTrace` + a `mprotect(RW)→write→mprotect(RX)` bracket on `ExecPage`.
2. **Lifetime (P-E)** — unpatch-on-retire: `removeTrace` restores parents' exits to
   `deopt_exit` via a back-reference (mirror LuaJIT's RW window + GC-exit skip at
   `lj_asm_x86.h:3153`).
3. **Determinism gates (P-EBP-1..4)** — the patched jump SKIPS the dispatcher's
   future-steering accounting (`onSideExit`, arming, gating, lane-widen eviction), so
   byte-identity is NOT free: replicate that accounting on the patched path OR prove each
   skipped counter inert post-link, then the 10-mode matrix + replay goldens + the
   safe-point argument.

**Plan of attack (Bart, 2026-07-17):** (1) fix this file [DONE]; (2) read Pall's
`lj_asm_patchexit` + `lj_mcode_patch`, write the Increment 3 design into doc 17; (3) codex
gpt-5.6-sol pre-implementation review; (4) Antigravity (gemini-3.1-pro) second review; then
implement.

---

## Status 2026-07-14 (SUPERSEDED — see the 2026-07-17 block above; 2c-E/E2/E3 + 2c-F all landed) — 2c-E (#63): E1 LANDED (d4d82d9); E2 spec finalized (codex-approved), implementation next

**Where we are.** 2c-E splits into E1/E2/E3 per two codex `gpt-5.6-sol` rulings (thread
`019f5f48-98ba-73b3-90c8-89ded74aae92`; the rulings are in the session transcript
`~/.claude/projects/-home-bart-Projects-mahina/9a281686-...jsonl` lines 21264 + 21272, already
fully distilled below — do NOT re-read the transcript).

- **E1 — DONE, commit `d4d82d9`** ("feat(jit): 2c-E1 — model deep fused receipts,
  prologue-fail grammars, and call-B handover (nothing armed)"). All control-flow wiring for
  the armed `C↔I` cycle, with NOTHING armed: call-A drain in `driveBurstCore`
  (`ledger_len>1` → `replayLedger(.inner_call)`), `BurstCursor.start_at_continuation` +
  `call_a:` labeled block (a `run_continuation` handover enters call B without re-running the
  inner), `driveSeedLedger` (hop-0 >2-entry drain, private), `driveDispatcherLedger` maps
  `run_continuation` → cursor, replayLedger M1 sub-case (c) (fused `[skip.deopt,
  ramp.prologue_fail]`) + terminal-loop-done continuation release-validation, dispatcher gate
  widened to `if (ran_native and result.ledger_len > 1)` (interp.zig ~2738). Plus 4 blocking
  unit tests (M1 sub-case c; dispatcher `[I.loop_done_linked, C.prologue_fail]`; deep hop-0
  seed ledger single-charge; real-native `start_at_continuation` no-double-run).
- **E2 — NEXT (spec below, codex-approved).** The intentional behavior changes: persistent
  I→C arming (3 sites), terminal-replay arming convergence, non-last link-follow accounting,
  native one-trip linked-loop-done correction, + 5 blocking tests.
- **E3 — after E2:** byte-identity sweep (6 benchmarks × tier-0/tier-1a/native, stdout +
  keyframe/replay goldens), doc 17 + this file updated, then codex full-diff review.

### E2 implementation progress (2026-07-14, this session)

**Code items 1–6 are ALL IMPLEMENTED and green** (`just test` exit 0, 756 tests; nsieve 9
byte-identical tier-0 == tier-1a == native with the cycle LIVE). What landed:
- Counters `native_loopdone_link_arms` / `native_loopdone_link_fused` (trace.zig ~977–988).
- `armLoopDoneLink` helper right after `armNativeLink` (trace.zig ~2990): all gates as spec'd.
- `safe_to_arm` threaded into `replayLedger` (last param) + all 4 call sites.
- Site 1 (scalar call-A, after the `arm_term` block), site 2 (driveChain: both the `>2`
  driveSeedLedger branch AND the is_link classify branch, gated
  `materialization == .native_numeric_for_done`), site 3 (replayLedger terminal
  `.loop_done_linked`, before the hop-budget check).
- Follow bumps in non-last `.link_terminal` (trace.zig ~1753) + fused counter in non-last
  `.loop_done_linked` (~1823).
- One-trip fix in interp.zig: `linked_one_trip` computed after `local_done` (~2713); guard-fail
  gate `and !linked_one_trip`; productive gate `or linked_one_trip` with
  `onSideExit(final, if (linked_one_trip) 1 else local_done)`.
- **E1 test D expectation updated** (was the one red test): the new non-last `.link_terminal`
  follow bump makes `native_link_follow_count == 2` (fused C→I edge + physical post-C hop),
  and `native_loopdone_link_fused == 1` (entry 0→1 edge) — both now asserted.

**⚠️ TREE STATE (2026-07-14, second pass): RESTORED — nothing left to restore.**
1. ~~One-trip fix temporarily disabled~~ — DONE: the `false and` is removed; the
   fix is LIVE and the full suite is green (`just test`, 759 tests).
2. ~~Temporary debug scaffolding to DELETE~~ — DONE (2026-07-14): every ad-hoc DBG
   print was removed and replaced by the permanent **jitdbg facility** (Bart's ask):
   `src/jitdbg.zig` (new) + `-Djit-debug=true` build option + `--jit-debug` CLI flag
   + `vm.trace.config.debug_log` runtime gate + `TraceState.dbg()` /
   `dbgDumpGuardFailures()` / `dbgDumpCache()` + permanent call sites (dispatcher
   receipt in interp.zig, arm/re-arm in armNativeLink, disarmAllLinks,
   retire-reset in resetLinksTouching). Compiled out entirely by default; both
   `just test` and `zig build test -Djit-debug=true` green; smoke run shows
   receipts + the 2c-E loop-done arm event live. Documented in project CLAUDE.md
   (Build section). Touches build.zig, src/jitdbg.zig, root.zig, trace.zig,
   interp.zig, main.zig — NOT yet committed (rides with the E2 commit; interp.zig
   holds both changes and can't be split, Rule #13).
3. Everything else in the tree is final E2 code (items 1–6 of the spec, all landed).
4. Side discovery: `zig build wasm` is broken at HEAD (pre-existing 64-bit
   assumptions in `hotIndex` + `rowViewParent`, nothing gates it) — TODO.md has
   the details; my build_options wiring for wasm is fine.

**Test status:**
- Test (ii) "2c-E (doc 17): loop-done inner→continuation arm fires…" — WRITTEN + GREEN
  (arms>0 ∧ fused>0 fire on a plain 400×30 nested loop via `runNativeForTrace`).
- Test (i) "2c-E (doc 17): native one-trip linked loop-done…" — **GREEN + PROVEN
  LOAD-BEARING (2026-07-14, second pass)**, with a MAJOR upgrade to what it proves:
  after setting `native_vm.trace.config.min_trip_entry = 0;` before
  `runNativeForTrace` (the reachability fix — default 24 + EXACT `forRemainingTrips`
  makes one-trip dispatcher receipts unreachable otherwise), disabling the fix
  (`false and`) makes the test fail on **BYTE-IDENTITY, not the guard-count
  assertion**: native prints 2253 vs tier-0's 2252. So the scalar zero path on a
  one-trip linked receipt is an actual **MISRESUME / correctness bug** — the linked
  snapshot already committed the final iteration into regs, and the zero path
  re-runs it (double-commit, +1). `linked_one_trip` is a *correctness* fix, not
  just accounting; at default config only the `min_trip_entry` heuristic keeps the
  broken path unreachable. Test comment updated to say exactly this. The `%`-in-
  outer-body trick works as designed (continuation records `.link`, inputs=0, but
  nativegen-bails → armLoopDoneLink fails closed → slot unarmed → receipts stay
  scalar). Secondary assertion: every guard_failures value < 4.
- Tests (iii)/(iv)/(v) — **ALL WRITTEN + GREEN (2026-07-14)**. Key realization that
  made them cheap: they DON'T need real nativegen compilation. `replayLedger` only
  READS trace shape and accounts/arms — it never executes native code — so:
  - **(iii) convergence arm** "replayLedger convergence (2c-E site 3): a TERMINAL
    loop_done_linked arms the I→C slot" (trace.zig, before "driveChain
    ordinary_header"). Calls `replayLedger` DIRECTLY (isolates the arm from the
    risky native execution tail of driveDispatcherLedger). Uses hand-built
    `.compiled` stubs (`page = undefined`, heap `slots`, cont's `ordinary_entry` =
    sentinel `0xC0FFEE_1234`) — same trick as the P-E registry test — so NO
    x86_64 gate. Ledger `[I.done(fused), C.link, I.done(terminal)]`, safe_to_arm=
    true → asserts `native_loopdone_link_arms == 1`, `inner_slots[0] ==
    ordinary_entry sentinel`, the armed_links record {parent=inner, slot=0,
    child=cont}, `native_loopdone_link_fused == 1` (the interior k=0 fused),
    directive == `.run_continuation(cont)`. Frees slots manually + clears cache/
    armed_links before deinit (undefined page must never be destroyed).
  - **(iv) forced yield at LEDGER_CAP** "replayLedger forced yield (2c-B/2c-E): a
    CAP-length ledger ending .yielded replays cleanly" (trace.zig, before (iii)).
    Plain non-compiled traces (terminal is a `.link`, never arms → no compile
    needed). Runtime-filled 32-entry alternating `[I.loop_done_linked, C.link]`
    ledger, last `.link` stamped `.yielded`. Asserts replayLedger ACCEPTS it (no
    panic on the last-of-full guard), `linked_completed == 16`, directive
    `.run_inner_from(cont)`, `resume_pc == 5`, `native_link_exits == 16`.
  - **(v) disarm-on-unsafe** "disarmAllLinks (2c-E / 2.3c-0e): resets EVERY armed
    slot on entering the observation blackout" (trace.zig, before the P-C-invariant
    test). Hand-built compiled stubs, arm a full C↔I cycle (2 links via
    armNativeLink), one `disarmAllLinks` → BOTH slots back to shared_exit(0) +
    registry empty; asserts idempotence (second call no-op).
- **Pre-existing bug found (recorded in TODO.md, NOT mine — reproduced at HEAD
  d4d82d9):** `--trace` (tier-1a) panics "invalid enum value" in regwindow.get via
  `driveChain .ir` entering the `%`-continuation on the probe program (see TODO.md
  for repro). tier-0 + native fine.

**After tests: E3** — byte-identity sweep (nsieve DONE this session: 3 modes
byte-identical, md5 0c22770a…336; still owed: nsieve-bit/fannkuch/mandelbrot/nbody/
spectral-norm + keyframe/replay goldens), `just bench --filter nsieve`, doc 17
Done/Outstanding update, commit E2 (conventional, co-author trailer, bundle
src/trace.zig + src/interp.zig + doc 17 + CURRENT_TASK.md + TODO.md; do NOT stage
CURRENT_TASK_E3.md / bench/results/*.tsv), then codex gpt-5.6-sol diff review
(thread 019f5f48-98ba-73b3-89ded74aae92 — NB correct id is
019f5f48-98ba-73b3-90c8-89ded74aae92).

**Discoveries needed for writing the remaining tests:**
- `hasNativeLoopDoneLink` (trace.zig:2597) = "a zero-input `.link` continuation EXISTS at
  some loop-done exit PC of this trace" — NOT "slot armed". So linked-mode dispatcher entry
  happens pre-arm whenever the continuation trace exists.
- **One-trip reachability (test i) — CORRECTED (the first version of this bullet was
  wrong):** a 1-iteration inner NEVER enters via the dispatcher (entry is on back-edges; a
  1-trip loop takes none). A **2-trip inner** enters at the first back-edge (j=2) and hits
  loop-done LINKED with `local_completed == 0` (final linked snapshot commits WITHOUT the
  back-edge rbx increment, nativegen:4567) — **BUT only if `min_trip_entry` allows it**:
  the default (24) makes the dispatcher decline any numeric-for entry with < 24 exact
  remaining trips (interp.zig:2455–2461 + forRemainingTrips:3661), so the scalar one-trip
  path is unreachable at default config and the test must set
  `vm.trace.config.min_trip_entry = 0` before the harness call. Program shape: warm with a
  wide inner (`m=30`), flip to `m=2`, keep `s = s % 100000007` in the outer body so the
  continuation is nativegen-unsupported (→ slot never arms → receipts stay scalar).
- **Penalty nuance:** productivity 1 still bumps `penalty` (`onSideExit` clears only at
  `completed >= min_useful=8`) — the one-trip fix does NOT change penalty accumulation
  (replayLedger's `max(local,1)` has the same property; E1 tests pin penalty==1 per
  one-trip). Load-bearing observables for the fix are instead: countGuardFailure SKIPPED,
  the `.native_numeric_for_done` driveChain FIRING (→ `native_link_exits`), and resume
  steering. Verify a test is load-bearing by temporarily reverting the fix and watching it
  fail.
- Counter-asserting end-to-end pattern: see interp.zig ~9860–10021 (`runNativeForTrace`
  harness at 10103 with lowered hotloop=4; the doc-16 nsieve test at 9931 uses the inline
  default-threshold harness instead — copy THAT for chain-shape-sensitive programs).

### E2 spec (recovered + codex-ruled; implement exactly this)

1. **Two new `TraceState` counters** next to `native_source_link_fused` (trace.zig ~976):
   `native_loopdone_link_arms: u64 = 0` (bumped by the helper on a successful arm) and
   `native_loopdone_link_fused: u64 = 0` (bumped in replayLedger's NON-last
   `.loop_done_linked` branch — proves the armed edge actually fired).
2. **Shared fail-closed helper** `armLoopDoneLink(self, inner: *Trace, guard_idx: u32,
   cont: *Trace, safe_to_arm: bool) void`. Gates, each `return` (never panic — arming is
   opportunistic): `safe_to_arm`; `guard_idx != maxInt(u32)` + `< inner.instrs.len`;
   `isLoopDoneGuardIndex(inner, guard_idx)` (explicit — armNativeLink's kind/shape invariant
   is a *debug* assert + release fail-close, don't rely on it); `post_pc =
   guardExitPc(inner.instrs[guard_idx]) orelse return`; `cont.inputs.len == 0`; cont ends
   `.link`; `cont.anchor.proto == inner.anchor.proto and cont.anchor.pc == post_pc`; then
   `nativeFor(cont)` → `.ordinary_entry` **optional, never `.?`** (missing entry leaves slot
   unarmed) → `armNativeLink(inner, guard_idx, cont, oe, .loop_done_linked) catch false` →
   on true bump `native_loopdone_link_arms`. armNativeLink already fail-closes on
   non-compiled `inner` / OOB slot, supersedes same-slot in place, and appends to the P-E
   registry BEFORE the slot write.
3. **Thread `safe_to_arm: bool` into `replayLedger`** (new param). Call sites to update (all
   already have `safe_to_arm` in scope): call-A drain in driveBurstCore, call-B loop in
   driveBurstCore, `driveDispatcherLedger`, `driveSeedLedger`.
4. **Arm at 3 sites** (target = `ordinary_entry` NOT `linked_entry`: the continuation is a
   `.link` trace with no numeric-for loop-done of its own; nativegen.zig:4675 —
   `ordinary_entry` clears inherited linked mode):
   - **Site 1, scalar call-A loop-done** (driveBurstCore): right after the existing 2.3b-1
     `C.link→I.linked_entry` arm block (`arm_term`), post driver-swap + roll-up:
     `armLoopDoneLink(inner, iresult.exit_instr, current_link, safe_to_arm)` gated
     `tier == .native_only` (`current_link` is post-swap = the continuation at the inner's
     exit PC; `iresult.exit_instr` already validated loop-done by the scalar classify).
   - **Site 2, driveChain hop-0** under `materialization == .native_numeric_for_done`
     (inner=`failed`, guard=`exit_instr`, cont=`sct`): mirror the M1
     `native_source_link_arms` arm placement — BOTH the is_link classify branch AND the
     `ledger_len > 2` branch (arm before routing to driveSeedLedger). In
     `.native_numeric_for_done`, `failed` = the inner I, `walk_pc` = post-loop pc from
     guardExitPc, `sct` = continuation C.
   - **Site 3, replayLedger terminal `.loop_done_linked` is_last branch** (inner=owner,
     guard=`e.exit`, cont=`cont`): this is the *convergence* arm — a terminal unarmed
     `I.loop_done_linked` arms the edge for its next occurrence. Decision made: is_last
     branch only (non-last means the edge already fused → already armed). Arming on a
     forced-yield terminal is harmless (in-place supersede). Place it so it runs even when
     the hop budget then breaks the burst (scalar parity: scalar site arms on the last hop
     too).
5. **Follow-count bumps** in replayLedger's NON-last `.link_terminal` branch (after
   validation, next to `cont = owner`): `native_link_follow_count +|= 1` AND
   `link_follow_count +|= 1` — mirrors the physical call-A top so the
   `start_at_continuation` skip is accounting-exact. And `native_loopdone_link_fused +|= 1`
   in the NON-last `.loop_done_linked` branch.
6. **Native one-trip linked-loop-done fix (interp.zig, native-only).** A linked-mode native
   receipt commits its final linked snapshot (nativegen.zig:4567) even at
   `local_completed == 0` (a one-iteration inner: loop-done fires before any back-edge rbx
   increment) — regs ARE coherent at the post-loop pc, but the scalar dispatcher takes the
   `local_done == 0` path (countGuardFailure + `onSideExit(final, 0)` zero path) while
   replayLedger uses `max(local,1)`. Fix: compute
   `linked_one_trip = ran_native and ran_native_link_mode and result.exit_reason == .normal
   and exit_instr-in-bounds and trace.isLoopDoneGuardIndex(final, result.exit_instr) and
   local_done == 0` (bounds check BEFORE isLoopDoneGuardIndex; exit==maxInt excluded by it);
   then (a) skip the guard-failure counting block (`if (local_done == 0 and
   !linked_one_trip)`), (b) enter the productive block (`if (local_done > 0 or
   linked_one_trip)`) with `onSideExit(final, if (linked_one_trip) 1 else local_done)`,
   (c) pass the ORIGINAL `result` to driveChain (real exit identity, no fabricated count).
   `maybeArmContinuation`/`countProductiveBranchExit` stay — inert (former sees the cached
   continuation, latter rejects loop-done guards). **Tier-1a unchanged** (it hasn't committed
   the final iteration; assigning count 1 there would be wrong — would need
   flushNumericForLoopDone).
7. **Five E2-blocking tests:** (i) native one-trip linked loop-done (local_completed==0 →
   productivity 1, no guard-failure count); (ii) actual I→C arm + `native_loopdone_link_fused`
   assertion (armed edge fires); (iii) replay-terminal arming convergence (terminal unarmed
   sibling I becomes armed for its next occurrence); (iv) forced yield at LEDGER_CAP via a
   CONSTRUCTED native cycle — non-deferrable, it's the only bound on the newly-live cycle;
   don't rely on nsieve; (v) minimal deterministic disarm-on-unsafe proving BOTH halves of an
   armed C↔I cycle reset (`resetLinksTouching` covers both directions).

Then: `just test` green + nsieve byte-identity across the 3 modes → commit E2 → E3.

### Verified code map (line numbers as of d4d82d9 — saves re-reading trace.zig)

- **`LedgerEntry`** (irinterp.zig:200): `{cum: usize, id: u32, exit: u32 (maxInt =
  prologue-fail), reason: ExitReason (.normal/.prologue_fail), kind: LedgerKind = .deopt,
  outcome: LedgerOutcome = .normal}`; `LedgerKind = {link_terminal=0, loop_done_linked=1,
  deopt=2, prologue_fail=3}`; `LEDGER_CAP=32`; forced yield (`.yielded`) only as LAST entry
  of a FULL (==CAP) ledger; per-segment local = `cum[i]−cum[i-1]`, `cum[-1]==0`.
  `ExecResult.exit_reason: ExitReason = .normal` (irinterp.zig:133).
- **`replayLedger`** (trace.zig:1626, signature at 1626–1637): the single authoritative
  graph-walk drain. Branch geography: `.link_terminal` non-last validation+`cont=owner` at
  1710–1722 (**follow-bump goes here**), is_last `run_inner_from` 1700–1708;
  `.loop_done_linked` 1724–1777 — `onSideExit(owner, max(local,1))` 1741, `first_inner`
  no-hop rule 1749, is_last budget check 1755 + terminal cont release-validation 1761 +
  `run_continuation` 1765 (**site-3 arm + fused-counter go around here**), non-last succ
  validation 1770–1776; `.deopt` M1 non-last 1795–1884 (sub-case b 1835, c 1856, a
  fall-through 1880–1884), terminal (a)/(b) 1900–1926; `.prologue_fail` 1928–1956.
- **`driveChain`** (trace.zig:1314): native path sets `flushed_resume_pc = walk_pc` before
  every candidate (~1407) → a prologue-fail short-circuits at the "Not a completed link run"
  tail with `onSideExit(sct,0)`, never retries (retry tail is tier-1a-only). Hop-0 capture
  ~1412; `ledger_len > 2` branch ~1423 arms M1 then routes to `driveSeedLedger`; `==2` stays
  on the scalar `fused_inner` seam. **M1 arm pattern to mirror for site 2** (~1424–1434 and
  ~1483–1493): gates safe_to_arm + `.ordinary_header` + inputs empty +
  isSourceBranchGuardExit, `nativeFor(sct).ordinary_entry` optional,
  `armNativeLink(failed, exit_instr, sct, oe, .ordinary_guard)`,
  `native_source_link_arms+1`.
- **`driveBurstCore`**: hop loop `hop: while (hops < max_hops=8)`; `call_a: {}` labeled block
  consumes `start_at_continuation` once via `break :call_a`; scalar call-A loop-done
  classify → tier-1a flush → driver swap via findLinkTrace → roll-up
  `onSideExit(inner, max(local,1))` + `linked_completed++` → **2.3b-1 arm block
  (`arm_term`) — site 1 goes right after it**. Call B: `snt.runCapturingLedger` + while-loop
  over `replayLedger(.continuation_call)` directives. Tail: `linked_completed>0`
  penalty-neutral, else `onSideExit(seed,0)`.
- **`driveSeedLedger`** (trace.zig:~2464, private): hop-0 >2 drain; release checks (len≥3,
  seed ends `.link`, e0=={seed.id,.link_terminal,exit==len-1}); NO wrapper
  `native_link_exits` precharge; origin `.continuation_call`.
- **`driveDispatcherLedger`** (trace.zig:~2380, pub): origin `.dispatcher_root`; `inner_pc =
  seed.anchor.pc` placeholder; `run_continuation` → cursor `start_at_continuation=true`.
- **`armNativeLink(parent, slot_index, child, target, kind) !bool`** (trace.zig:~2882):
  fail-closed non-compiled parent/OOB slot; kind-vs-slot-shape invariant (loop-done slots
  exclusively `.loop_done_linked`) is debug assert + release fail-close; in-place same-slot
  supersede; registry-append-before-slot-write. `resetLinksTouching` (~2937) both directions.
- **Helpers:** `guardExitPc` (450 — only guard_int/float/number/true/false/int_of_float
  carry a PC in aux); `isLoopDoneGuardIndex` (463 — guard_true + `code[exit_pc-1]==.for_loop`,
  safe on OOB idx); `isInnerLoopRoot` (1151 — anchor match + inputs empty + ends `.loop`);
  `isSourceBranchGuardExit` (2714); `fusedSourceBranchLinkSlot` (2750); `traceById` (1234);
  `nativeFor` (3032 — lazy compileInto, memoizes `.compiled`/`.unsupported`);
  `onSideExit` (1256 — completed ≥ min_useful(8) → hit; else penalty++ → gate at 8).
  `ArmKind` (478) = {link_terminal, ordinary_guard, loop_done_linked}.
- **interp.zig dispatcher exit consumer (E2-6 target), ~2692–3001:** `local_done = if
  (ran_native) result.local_completed else result.completed` (2692); ledger-drain gate
  2738–2743; guard-failure block `if (local_done == 0)` 2752–2760 (**skip when
  linked_one_trip**); productive block `if (local_done > 0)` 2762 with
  `onSideExit(final, local_done)`, maybeArmContinuation 2773, countProductiveBranchExit
  2783, `.native_numeric_for_done` driveChain call 2843–2848 (gated `ran_native and
  ran_native_link_mode`); zero path `onSideExit(final, 0)` 2922. `ran_native_link_mode` set
  from hasNativeLoopDoneLink at entry (~2593).
- **nativegen facts:** compile bails (returns null) for terminal not `.loop`/`.link` (879);
  slot_load without covering guard_int bails; add on unproven operands bails (→ easy way to
  make a trace deliberately uncompilable in tests); `ordinary_entry` clears inherited linked
  mode (4675); linked snapshot commits at 4567 even at local_completed==0; forced yield
  validated at 3331; `CompiledTrace.runCapturingLedger` (719) /
  `runLinkedLoopDoneCapturing` (732); `NativeState.deinit()` frees page/slots.
- **Test patterns that work** (see the four E1 tests, inserted after "armNativeLink: P-C
  option (b) invariant"): stack `var t: Trace` + `state.cache.append(gpa, &t)` + `defer
  state.cache.clearRetainingCapacity()` registered AFTER `defer state.deinit()` (LIFO →
  clear first); compiled stubs `.native = .{ .compiled = .{ .page = undefined, .slots =
  heap_slots, .gpa = gpa } }` with defer-freed slots; real native compile via
  `nativeFor` + `defer t.native.deinit()`, gate on x86_64-linux via local `const builtin =
  @import("builtin");` + `error.SkipZigTest`; protos via `Proto{ .code = &.{
  Instr.op0(.ret), Instr.op0(.for_loop) }, .name = "t", .num_registers = N }`;
  `TestRegs{.regs = &regs}` + `.view()` + `.commit()`. Reference trace.zig NOT as
  `NativeState.x` — use `t.native == .unsupported` style tag checks.
- **Codex lifecycle confirmations (no work needed):** capture→replay has no intervening
  mutation (single-threaded); same-slot rearm supersedes in place; removeTrace resets links
  before mcode reuse; widen-eviction retires a fused child at its own anchor.

### Deferred to 2c-F (#65)
Full sibling cross-link topology; full two-phase same-VM disarm negative control;
widen-eviction integration both directions; broader prologue-fail coverage; extra
forced-yield stress; full codex diff review of the 2.3c-2 arc; flag the 2-valued
LedgerOutcome deviation and the terminal-continuation @panic-vs-swap choice.

---

## Status 2026-07-14 (prev) — 2.3c-2d COMPLETE (#62): D1 + D2a + D2b-i + D2b-ii all LANDED (green, byte-identical); 2c-E NEXT (arm I→C)

Task #62 (2c-D, "capture everywhere") is DONE. All four native-entry sites now capture the
per-transition ledger and drain it through the single authoritative `replayLedger`; the bespoke
scalar M1 recognizer is gone. Next: **2c-E (#63)** — persistently arm `I.loopdone →
C.ordinary_entry` (the `.loop_done_linked` / `isLoopDoneGuardIndex` gate), closing the native
`C↔I` cycle so `ledger_len>1` fused spans appear at call A and the dispatcher's `run_continuation`
path (both already wired, dormant). Also wire call-A's dormant `ledger_len>1` drain (currently
panics at nativegen call site) and exercise `driveBurstCore`'s `.run_continuation` re-run.

**D2b landed since D2a:**
- **2c-D D2b-i** (commit 1e8141d, pure refactor, byte-identical): extracted `BurstCursor
  { current_link, linked_completed, resume_pc, hops }` + a shared `driveBurstCore` hop-loop core
  from `runLinkedBurst`. The wrapper keeps the one-time entry counters
  (`native_link_exits`/`link_ir_exits`, `prime_side_chain_follows`), builds a zero-progress cursor,
  and hands off. The core owns NO entry counters, so a caller with an already-accounted cursor can
  enter the same ping-pong. Tail `onSideExit` now takes the explicit `seed`.
- **2c-D D2b-ii** (commit 7875dac, the LIVE change): folded the M1 fused-guard drain into
  `replayLedger`'s `.deopt` non-last arm (armed-edge provenance validation + `native_source_link_fused`
  + `onSideExit(skip, skip_local)`; sub-case (a) `.link_terminal` fall-through → `run_inner_from`,
  sub-case (b) inline `onSideExit(ramp,0)` + `return_result{resume_pc: skip.anchor.pc}`). New public
  `trace.driveDispatcherLedger` drains a dispatcher-entry ledger via `replayLedger(.dispatcher_root)`
  and maps the directive onto `driveBurstCore`, charging `prime_side_chain_follows` on the
  `run_inner_from` path (the one counter replayLedger does not own). The old ~60-line scalar M1 block
  in interp.zig is replaced by a thin gate `if (ran_native and ledger_len>1 and exit_reason==.normal)`.
  Routing by reason keeps a prologue-fail-terminal fused span on the old scalar path (byte-identical
  to the old `exit_instr < instrs.len` gate). `native_source_link_fused` is now bumped ONLY inside
  `replayLedger`, so the nsieve native test's `> 0` assertion proves the new path fires.

**Verify (D2b):** `just test` green; nsieve/fannkuch/nbody/spectral-norm stdout byte-identical
across tier-0 / tier-1a / native.

**Codex `gpt-5.6-sol` checkpoint review of D2b — DONE (thread 019f5edc), all blockers resolved:**
- Blocker 1 (a `[C.link, I.x]` dispatcher receipt would misroute through the widened `ledger_len>1`
  gate) — **false positive**, confirmed by codex: the dispatcher walk skips `.link` traces
  (interp.zig:2526) BEFORE fingerprint/native entry, so a continuation is never a dispatcher seed,
  and a non-`.link` seed can't emit a `.link_terminal` first ledger entry. Pre-2c-E `entries[0]` of
  a `ledger_len>1` dispatcher receipt is therefore ALWAYS the M1 source-branch `.deopt` → the new
  gate is equivalent to the old `fusedSourceBranchLinkSlot` recognizer for every case it fired on.
- Blocker 2 + 3 — **hardened** (commit 2f0f457, byte-identical): M1 sub-case (b) resumes at
  `owner.anchor.pc` (not `seed_owner`) and requires the ramp deopt to be the LAST entry;
  `prime_side_chain_follows` moved into replayLedger's M1 `.deopt` sub-case (a) fall-through (tied to
  source-guard provenance) instead of driveDispatcherLedger's generic `run_inner_from` mapping.

**Codex ruling: D2b is sound; safe to build 2c-E on it.** One ACTIVATION CONSTRAINT for 2c-E (already
in #63 scope, do NOT skip): arming `I→C` makes call A (nativegen.zig `runLinkedLoopDoneCapturing`,
trace.zig ~2031) immediately return `[I.loop_done_linked, C.…]` and hit the existing
`if (iresult.ledger_len > 1) @panic(...)`. So 2c-E is NOT arm-only — it must FIRST/ALSO route call-A
multi-entry receipts through `replayLedger(..., .inner_call)` and map the directive WITHOUT re-running
the already-executed inner body, then flip the `I.loopdone → C.ordinary_entry` arm. The dispatcher's
`run_continuation` mapping is already wired (dormant); call A is the remaining dormant path.

D2b commits: 1e8141d (D2b-i refactor), 7875dac (D2b-ii live fold), 2f0f457 (codex hardening).

### Prior 2c-D detail (D1 + D2a)

Landed since 2c-C:

- **2c-B forced-yield cap** (#64, committed): chain-source exit sites reload `ledger_len` after
  the append and `jmp shared_exit` (stamping the terminal `.yielded`) at CAP, bounding a closed
  cycle to ≤CAP entries per trampoline entry. Byte-identical/inert pre-cycle.
- **2c-C generic replayLedger** (#61, commit 0aac370): four per-kind validated arms
  (`.link_terminal` / `.loop_done_linked` / `.deopt` / `.prologue_fail`), each release-`@panic`s
  on a contract mismatch. Call B (`runLinkedBurst` continuation drain) rerouted through it; the
  `.deopt` NON-last (M1) arm still panics "not modeled until 2.3c-2d".
- **2c-D D1** (commit 7f3cac2): `nativegen.runLinkedLoopDoneCapturing` (LINKED-mode counterpart
  of `runCapturingLedger` — a literal swap flips mode 1→0 and corrupts coherent resume). P1a:
  `run_continuation`/`run_inner_from` now carry the exact `*Trace` (continuation `cont`, resp.
  `.link` driver) so a `C1→I→C2` sibling swap re-runs C2, caller `nativeFor()`s the carried
  trace. `ReplayOrigin` + cursor fix: `.loop_done_linked` computes `post_pc` before accounting
  and always resumes there; an `.inner_call` seed's first loop-done does NOT consume a re-run hop
  (else a trailing `run_inner_from→continue :hop` double-increments `hops`). Call A routed through
  the capturing wrapper; `ledger_len>1` (fused I→C, 2c-E only) release-panic-guarded until D2b.
- **2c-D D2a** (commit dcacf7d): dispatcher native entry routed through the capturing wrappers
  (preserving `ran_native_link_mode`), while RETAINING the existing scalar/M1 consumer. Inert:
  scalar `result` unchanged pre-cycle, consumer reads only scalar fields, `ledger_scratch` fill
  unread until D2b.

**Verify (D1+D2a):** `just test` green; nsieve/fannkuch/nbody/spectral-norm stdout byte-identical
across tier-0 / tier-1a / native.

**NEXT — 2c-D D2b (the LIVE one):** activate `ledger_len>1` replay seeded at `ct` in the
dispatcher; FOLD the M1 fused-`.link` consumer (`fusedSourceBranchLinkSlot`, interp.zig:2717-2773)
into replayLedger's `.deopt` NON-last arm; factor a burst CORE so a replayed M1 terminal
`run_inner_from(ramp)` continues the ping-pong from already-accounted state; remove the old
consumer. This is NOT inert — it changes the live `ledger_len==2` M1 path (`[skip.deopt,
ramp.link]` continue-burst AND `[skip.deopt, ramp.deopt/prologue]` resume-at-`ct.anchor.pc`), so
it must be proven byte-identical against the current consumer. Two M1 sub-shapes to preserve:
sub-case (a) ramp reached `.link` → continue burst; sub-case (b) ramp deopted pre-`.link` →
`onSideExit(ct,skip_local); onSideExit(ramp,0); resume ct.anchor.pc` (NOT the generic `.deopt`
`link_pc`). Most-likely regression (codex): treating a replayed M1 terminal link as a FRESH
`runLinkedBurst` entry (resets `linked_completed`/`hops`, double `native_link_exits`). Get codex
gpt-5.6-sol to review the concrete D2b design before writing it. Then 2c-E (arm I→C persistently)
+ 2c-F (disarm load-bearing test + docs + full-diff review).

---

## Status 2026-07-13 (prev) — 2.3c-2b native call-B drain rerouted through ledger replay LANDED (green, byte-identical)

Second sub-step of 2.3c-2 (task #56), per Bart's "Ok, 2b next :)". Reroute ONLY the native
continuation drain (call B) of `runLinkedBurst` through the 2.3c-2a ledger; call A (hop-top
inner), the driver swap, burst-entry accounting, and the tier-1a scalar path stay UNCHANGED.
Byte-identical: nothing new armed I→C, so every call-B ledger is ≤2 entries whose terminal ==
the old scalar result.

- **nativegen.zig.** `runWithLinkedLoopDone` gained a `ledger_out: ?[]irinterp.LedgerEntry`
  out-param; `run`/`runLinkedLoopDone` pass `null`. New `pub fn runCapturingLedger(regs,
  ledger_out)` = ordinary mode + copies `NativeResult.ledger_*[0..ledger_len]` into `ledger_out`
  (asserts `out.len ≥ ledger_len`). Option (b): the 32-slot arrays never enter the by-value
  `ExecResult`; only the caller's borrowed scratch is filled.
- **irinterp.zig.** New `pub const LedgerEntry = struct { cum: usize, id: u32, exit: u32, reason:
  ExitReason }` — one decoded ledger row.
- **trace.zig.** `TraceState.ledger_scratch: [LEDGER_CAP]LedgerEntry` (borrowed capture→replay
  window, not a GC root). New `ContinuationReplay` directive union + `replayContinuationLedger`
  phase-machine (starts in `continuation` phase): resolves the first entry's owner strictly
  (`traceById`, assert==current_link), branches on `.link`-terminal vs continuation-own-deopt;
  charges `native_link_exits` ONCE on the `C.link` marker (replaces the old per-span 1726 +
  standalone-`.link` 1789 bumps — identical count); resolves the fused inner strictly by id +
  `isInnerLoopRoot`, `flocal = cum[1]-cum[0]`, loop-done via `guardExitPc`+`for_loop`. Directives:
  `run_continuation` (re-run `snt.runCapturingLedger`), `run_inner` (`continue :hop`),
  `return_result` (yield/finish), `break_burst` (`break :hop` → penalty-neutral tail). The old
  scalar `while (final != current_link.id)` drain + standalone/`completed>0`/break tail are gone
  on the native path; the `hop:` while is now labeled. Tier-1a keeps the scalar single-exit path.
- **codex BLOCKER fix.** `entries.len ≤ 2` is RELEASE-enforced with `@panic` (not a debug assert):
  a `C.link→I.guard→R.link` composition — an inner whose OWN ordinary source guard is armed to a
  ramp (2.3c-1) — could yield 3 entries; a debug-only assert would let ReleaseFast silently drop
  R's hop and misresume. The panic aborts loudly in every build, matching the old scalar drain's
  "unexpected fused shape" hard-stop. Not reachable in the test suite (assert never fired);
  2.3c-2c's full-ledger replay lifts the cap.
- **Verify.** `just test` green; the 6-benchmark matrix (nsieve, nsieve-bit, fannkuch, mandelbrot,
  nbody, spectral-norm) tier-0==tier-1a==native byte-identical; `just bench --filter nsieve` flat
  (`cross ok`, jit 92.9ms). Post-impl codex gpt-5.6-sol review confirmed exact accounting parity
  for every ≤2-entry shape (native_link_exits count, resume_pc, completed, onSideExit args,
  hops/break-continue-return mapping) — the hop-budget `hops==max` vs old `max+1` is dead-after-tail
  (not observable).

**NEXT:** commit 2.3c-2b (conventional, local only, bundled: irinterp.zig + nativegen.zig +
trace.zig + doc 17 + CURRENT_TASK.md; do NOT stage other-agent files). Then **2.3c-2c** — replace
chain-source drop-if-full with a forced yield to `shared_exit`, arm
`I.loopdone-slot[ei]→C.ordinary_entry` (`.loop_done_linked`, `isLoopDoneGuardIndex` gate), route
call A + seed receipts through the now-tested `replayContinuationLedger` (lifting the ≤2 cap),
normalize follow-counters, add a load-bearing disarm-on-unsafe test (two-phase same-VM + negative
control), peer-review the full 2.3c-2 diff with codex gpt-5.6-sol before final commit.

---

## Status 2026-07-13 — 2.3c-2a per-transition ledger ABI + emission LANDED (green, byte-identical)

First sub-step of 2.3c-2 (task #56). Bart's decision: **"Promote the M2 ledger"** — the
inner→continuation arm (2.3c-2c) closes a `C→I→C→I…` cycle in ONE trampoline entry whose
scalar `NativeResult` fields describe only the terminal hop, so the intermediate hops are
unrecoverable and the dispatcher drain can't account them. The M2 per-transition ledger,
previously "rejected/deferred", is therefore promoted and built here first — ABI + emission
only, with NO accounting change yet (that's 2.3c-2b) and NO cycle-closing arm yet (2.3c-2c).

- **irinterp.zig.** `pub const LEDGER_CAP: usize = 32` (covers the burst-hop bound: ≤9
  iterations × 2 transitions = 18 in one span; native append is bounds-guarded). `ExecResult`
  gains a defaulted `ledger_len: usize = 0` → the ~40 tier-1a `ExecResult{…}` sites untouched;
  read only on the native path.
- **nativegen.zig NativeResult.** Appended AT THE TAIL (keeps all existing `@offsetOf` baked
  into exit stubs byte-identical): `ledger_len: usize`, `ledger_cum: [LEDGER_CAP]usize`
  (scale-8), `ledger_id`/`ledger_exit`/`ledger_reason: [LEDGER_CAP]u32` (scale-4).
- **nativegen.zig `emitLedgerAppend(a, trace_id)`.** New helper emitted at all FOUR
  exit-materialization sites (`.link` terminal, linked_loop_done stub, shared `deopt_exit`,
  `prologue_fail`). Bounds-guarded drop-if-full (`cmp ledger_len, LEDGER_CAP; jae full`),
  then SIB-indexed stores `ledger_cum[len]=rbx` (cum counter), `ledger_id[len]=trace_id`
  (imm), `ledger_exit[len]=exit_instr` (reloaded from memory), `ledger_reason[len]=exit_reason`
  (reloaded), `inc len`. Scratch: rax=index, rcx=staging, rbx=cum — all dead at exits.
- **nativegen.zig `runWithLinkedLoopDone` wrapper.** `runtime_safety` tripwire asserts the
  TERMINAL ledger entry matches the scalar result (`ledger_cum[n-1]==completed`, id/exit/reason
  match, `1≤n≤CAP`); threads `ledger_len` into the returned `ExecResult`.
- **Byte-identity argument.** Appends write ONLY `NativeResult` scratch (never `regs[]` or
  program state); the drop-if-full branch is never taken pre-cycle. Control flow + scalar
  result fields unchanged → identical stdout across all modes.
- **Verify.** `just test` green — the terminal-consistency assert held across EVERY native run
  in the Debug suite (single-trace hot path AND the fused C→I spans, which already emit 2 ledger
  entries per 2.3b-1: C's `.link` exit + I's loop-done exit; the scalar drain only ever sees
  the terminal `final_trace_id==I.id`). nsieve/nbody/mandelbrot tier-0==tier-1a==native
  byte-identical; `just bench` nsieve flat (jit_execns 89.7M vs 95.9M baseline `1f39d8a`,
  nsieve-bit 50.9M vs 52.7M, nsieve-bit-fp 276M vs 279M — no regression).

**NEXT:** commit 2.3c-2a (conventional, local only, bundled: irinterp.zig + nativegen.zig +
doc 17 + CURRENT_TASK.md). Then **2.3c-2b** — route `runLinkedBurst`'s native drain through a
ledger replay (resolve each entry's owner strictly by trace_id; per-segment local =
`cum[i]-cum[i-1]`; reproduce `onSideExit`/`linked_completed`/`native_link_exits` identically),
byte-identical. Then **2.3c-2c** — replace chain-source drop-if-full with a forced yield to
`shared_exit`, arm `I.loopdone-slot[ei]→C.ordinary_entry` (`.loop_done_linked`,
`isLoopDoneGuardIndex` gate), add a load-bearing disarm-on-unsafe test, peer-review the full
2.3c-2 diff with codex gpt-5.6-sol before final commit.

---

## Status 2026-07-13 — 2.3c-1 M1 half-fusion LANDED (green, byte-identical)

Implemented the reviewed M1 contract end-to-end:

- **trace.zig arm.** `driveChain` now arms the failing skip trace's source-branch guard
  slot → the prime-side ramp's `ordinary_entry`
  (`armNativeLink(failed, exit_instr, sct, oe, .ordinary_guard)`), gated
  `tier == .native_only ∧ safe_to_arm ∧ materialization == .ordinary_header ∧
  sct.inputs.len == 0 ∧ isSourceBranchGuardExit(failed, exit_instr, proto)`. `failed` is
  now `*Trace` (mutable, `armNativeLink` needs it). New counter `native_source_link_arms`.
- **trace.zig `runLinkedBurst`.** Extracted the ping-pong burst body out of `driveChain`
  into a now-`pub` method so both `driveChain` and the dispatcher consumer enter it with
  an already-run ramp result. Verified it reads `sresult` ONLY via
  `fused_inner = if (sresult_fused) sresult else null` — with `sresult_fused == false`
  (M1 seed) the seed result is entirely unused, so passing the fused `result`
  (`completed == skip_local`) is byte-identical to the unarmed seed (`completed == 0`).
- **trace.zig `fusedSourceBranchLinkSlot`.** Provenance recognizer: returns `ct`'s
  source-branch guard slot if an armed record `{parent==ct, child==final}` exists whose
  slot is `isSourceBranchGuardExit` and `final.anchor == ct.anchor`; else null. Excludes
  the 2.3b-1 `.link_terminal` continuation→inner edge (its slot is a `.link` op, not a
  guard) and, once 2.3c-2 lands, the persistently-armed inner→continuation.
- **interp.zig fused-`.link` consumer.** Inserted after `local_done`, before guard-
  failure counting. Gated `ran_native ∧ final != ct ∧ result.exit_reason == .normal ∧
  result.exit_instr < final.instrs.len`; on provenance match: `native_source_link_fused`
  bump, `onSideExit(ct, skip_local = result.completed)`, two inert-hook asserts, then
  split — ramp `.link` → `runLinkedBurst(final, result, false, nt, .native_only,
  .ordinary_header, …)`; internal-guard deopt → `onSideExit(final, 0)` + resume at
  `ct.anchor.pc` (byte-identical to the unarmed `driveChain` seed's `{0, walk_pc}`).
  Fused prologue-fail (`exit_reason != .normal`, unreachable in practice — value-branch
  guards fire with types coherent) falls through to normal handling per the reviewed gate.
- **Verify.** `just test` green (incl. the 10-mode differential/keyframe goldens + two
  new `> 0` counter asserts in the Phase-2 nsieve chain test). 6 benchmarks
  tier-0==tier-1a==native byte-identical; nsieve `--emit-keyframe` tier-0==native
  byte-identical. Perf expected ~neutral on nsieve tiny clusters (consistent with
  2.3b-1) — value is completing native chain coverage + de-risking Increment 3, not a
  standalone speedup.

**NEXT:** commit (conventional, local only), then Increment 2.3c-2 (arm loop-done
inner→continuation — closes the native cycle; land only after 2.3c-0e disarm-on-unsafe
is proven load-bearing).

---

## Status 2026-07-13 — 2.3c fused-transition contract DESIGNED + review-clean

- **2.3c-1 re-scoped to M1 half-fusion (design only, not yet coded).** A codex
  gpt-5.6-sol pre-implementation review found the terse "arm skip→prime-side" scope
  *incoherent*: the prime-side is a `.link` **entry ramp** (no numeric-for back-edge),
  so arming `skip.guard` alone lands the fused run at the ramp's `.link` terminal with
  regs coherent at the **inner** PC while the dispatcher misreads it as an outer-header
  zero-exit → semantic **misresume**. Wrote `docs/design/17` §"Increment 2.3c —
  fused-transition contract" choosing **M1 (half-fusion)**: arm ONLY
  `skip.guard → prime_side.ordinary_entry`; decode the root's own count as
  `result.completed` (ramp commits 0 iterations → **no new NativeResult field**); add a
  dispatcher *fused top-level `.link` consumer* that replays `onSideExit(ct, skip_local)`
  + continues the burst via a `driveChain` seed of the already-run ramp result WITHOUT
  re-running the ramp. Rejected **M2** (full single-call skip→ramp→inner fusion) as
  needing the deferred P-F per-hop ledger nothing on the roadmap requires.
- **codex round-2 review of the written M1 design: confirmed + 1 BLOCKER + 1 SHOULD-FIX,
  both folded into the doc.** Confirmed: receipt decode (ramp never `inc rbx` between
  `ordinary_entry` and its `.link`), register coherence, inert-hook asserts, `onSideExit`
  ordering. BLOCKER: the fused-`.link` recognizer must discriminate on **P-E armed-edge
  provenance** (`parent==ct ∧ child==final ∧ slot_index` a source-branch guard) with a
  `exit_reason==.normal ∧ exit_instr<len` bounds gate — NOT the bare
  `final.instrs[exit_instr].op==.link` opcode, which OOBs on a fused prologue-fail
  (`exit_instr==maxInt`) and false-positives once 2.3c-2 persistently arms the
  inner→continuation slot (a directly-entered inner can return `final==continuation`,
  `final[exit_instr].op==.link`). SHOULD-FIX: the driveChain seed must consume a
  `current_link`-owned `.link` receipt at trace.zig:~1390, NOT initialize `fused_inner`
  from the ramp result (that field means the result already belongs to an inner root,
  resolved via `isInnerLoopRoot` → would panic/misclassify).
- **NEXT: implement 2.3c-1 M1** (task #55) now that the design is review-clean.

## Status 2026-07-12 (previous latest)

- **Increment 2.3c-0 (inert contracts + post-review blocker fixes): LANDED.** Six
  inert sub-steps a–f (commits `7523d1e` re-scope, `094ff89` 0b, `c295586` 0c,
  `131bc10` 0d, `bebbd48` 0e, `fd3c42e` 0f, `d276353` 0a), each byte-identical.
  Then a **codex gpt-5.6-sol contract review found 3 blockers, now all closed**
  (commit `e6b618c` fix + `5411105` test-strengthen):
  1. **Blocker 1 (broke correctness on a spilled carried home).** 0f's shared
     `deopt_exit` staged the dispatch holder in rax, but `flushSlot`'s spilled-
     carried-home `.mem` path scratches rax — clobbering the holder before the jump.
     Fix: stage the RESOLVED target in a new flush-immune `NativeResult.exit_target`
     memory field; `deopt_exit` ends `jmp qword [rdx+exit_target]`. Proven load-
     bearing by a negative control (revert tail to `jmp rax` → only the frameless
     carried-spill regression crashes).
  2. **Blocker 2 (reserved cell arm-addressable).** The exit_target fix let the
     reserved `slots[n]` "direct cell" be DELETED → `slots.len == instrs.len`, so
     `armNativeLink`'s `slot_index >= slots.len` bound rejects index n.
  3. **Blocker 3 (`final` dropped under driveChain's 8-cap).** Dispatcher `excl`
     buffer now orders `final` FIRST so driveChain's own `[8]` copy retains it.
  codex re-review: all closed, no new correctness blocker. `just test` green; 6
  benchmarks byte-identical tier-0/tier-1a/native. **NEXT: 2.3c-1** (task #55) — arm
  skip→prime-side ordinary source-branch guard (no cycle).

## Status 2026-07-12

- **Increment 1 (P-D, shared mcode arena): LANDED** — commit `a970da4`.
- **Increment 2.1 (P-A, frameless chain-entry ABI): LANDED** — commit `3f46d5e`.
  Frameless trampoline + frameless bodies; all exits pinned to `shared_exit`.
- **Increment 2.2 (P-B, chain-wide result contract): LANDED** — commit `1f39d8a`.
  Stable `Trace.id` + `NativeResult.final_trace_id` baked at every native exit +
  `traceById` dispatcher resolve/assert. No linking yet; every exit bakes its own
  `ct.id`, so `final == ct` and behaviour is byte-identical.
- **Increment 2.3a (indirect exit + link-slot table + P-E registry): LANDED** —
  commit `b8fc3fa` (+ hardening `286b145`). Indirect `jmp qword [&slot]` exit;
  per-trace heap-owned `slots: []usize` defaulting to `shared_exit`; inert P-E
  backlink registry. Byte-identical.
- **Increment 2.3b-0 (inert arming scaffolding): LANDED** — commits `9d16711`,
  `963bdbb`, `319da11`, `954ea89` (+ review `e658d07`). S3 cumulative-rbx prep,
  fail-closed `traceById`, `entry_rbx`→`local_completed`, `linked_entry` stub.
  Nothing armed; `final == ct`; byte-identical.
- **Increment 2.3b-1 (flip `.link` arming on): LANDED** — Step B (dispatcher routes
  through `final`) committed `66107a7`; Step A (driveChain persistent arming +
  unified fusion drain) is THIS commit. See the 2.3b-1 section below.
- **Increment 2.3c-0: LANDED** (see the latest-status block at the top).
- **Increment 2.3c-1 / 2.3c-2 : DESIGNED + PEER-REVIEWED + DECIDED** — see
  `docs/design/17-exit-branch-patching.md` (Done/Outstanding) and the plan file.

## What 2.2 changed (the chain-wide result contract, P-B)

Files: `src/irinterp.zig`, `src/trace.zig`, `src/nativegen.zig`, `src/interp.zig`.

- **`irinterp.zig`**: `pub const NO_TRACE_ID: u32 = maxInt(u32)` sentinel;
  `ExecResult` gains `final_trace_id: u32 = NO_TRACE_ID` (**defaulted** → the ~40
  tier-1a `ExecResult{…}` sites are untouched, zero churn).
- **`trace.zig`**: `Trace.id: u32` (stable, monotonic, never reused — the cache
  index is `swapRemove`'d so it can't be a baked constant); `TraceState.next_trace_id`
  bumped + assigned at finalize; `traceById(id)` resolver.
- **`nativegen.zig`**: `NativeResult.final_trace_id: u32`; `emitReturn` takes a
  `trace_id` param and bakes it via `movMemImm32(.rdx, @offsetOf(NativeResult,
  "final_trace_id"), trace_id)` before teardown/jump (rdx = `*NativeResult` at every
  exit); the 4 `lower` call sites pass `t.id`; `runWithLinkedLoopDone` inits and
  marshals the field.
- **`interp.zig`**: dispatcher resolves `final = traceById(result.final_trace_id)
  orelse ct` and `if (ran_native) assert(final == ct)` — validates the full baked-id
  round-trip while staying byte-identical (consumers still route through `ct`; 2.3
  switches them to `final`).

### Verification done for 2.2
- `just test` green (EXIT=0; Debug asserts active).
- nsieve 9: tier-0 == tier-1a == native byte-identical; `--jit-native` exit 0
  (assert `final == ct` passed for all native traces).
- Differential tier-0 vs native OK on: nsieve, nsieve-bit, fannkuch, mandelbrot,
  nbody, spectral-norm.

## What 2.1 changed (the frameless ABI move)

Files: `src/x64.zig`, `src/nativegen.zig`.

- **`x64.zig`**: added `jmpReg` (FF /4, indirect near jump through a GP register) +
  golden-byte test (`jmp rcx/rax/r15`).
- **`nativegen.zig`**:
  - `pub const SPILL_MAX: u32 = 512` — frameless spill ceiling (4 KiB). Even, so
    `SPILL_MAX*8` is 16-aligned → body `rsp % 16 == 8` (same invariant the
    self-framed prologue gave, which the hash-cell callout relies on).
  - `McodeArena.ensureTrampoline()` — emits the shared trampoline ONCE into a
    permanent (never-freed) arena slot; returns `{entry, shared_exit}` absolute
    addrs. Trampoline: `push rbx/rbp/r12/r13/r14/r15; sub rsp,SPILL_MAX*8;
    xor rbx,rbx; jmp rcx`. `shared_exit`: `add rsp,SPILL_MAX*8; pop …; ret`.
    C-ABI `fn(rdi=tags, rsi=payloads, rdx=*NativeResult, rcx=body_entry)`.
  - `CompiledTrace.trampoline_entry: ?usize` + `TrampolineFn` type; `run` dispatches
    through the trampoline for arena (production) pages, directly (`EntryFn`) for
    owned (test) pages.
  - `compileImpl`: when `arena != null`, bail if `alloc.spill_count > SPILL_MAX`,
    else `ensureTrampoline` and pass `shared_exit` into `lower`; sets
    `trampoline_entry` on the result.
  - `lower(…, shared_exit: ?usize)`: prologue push/sub guarded behind
    `shared_exit == null`; every exit now calls `emitReturn(a, frame, callee,
    shared_exit)` — self-framed teardown when null, `movabs rax,shared_exit;
    jmp rax` (absolute, direct) when set.
  - Test path (`compile`, `arena == null`) keeps the OLD self-framed ABI → ~60
    standalone-page tests untouched + built-in A/B of both ABIs.

Refinement vs the doc's final design: 2.1 uses a *direct* absolute jmp to
`shared_exit` at each exit (no per-trace slot table). 2.3 replaces it with the
indirect `jmp [slot]` handoff (slot default = `shared_exit`) when link population
lands. Behaviourally identical while no slot is armed.

### Verification done for 2.1
- `just test` green (EXIT=0).
- nsieve 9: tier-0 == tier-1a == native byte-identical.
- 5 native traces compile+run frameless (`--dump-native`).
- Differential tier-0 vs native OK on: nsieve, nsieve-bit, fannkuch, mandelbrot,
  nbody, spectral-norm, sieve_int, **field_hash** (the resolveHashCell callout —
  most rsp-alignment-sensitive), array3d, grid_matmul.
- `just bench --filter nsieve --reps 5`: jit ms flat (93.3→91.5 nsieve;
  52.5→53.3 nsieve-bit; within noise). ABI move is perf-neutral (expected — no
  linking yet, just one extra indirect jmp per trace entry/exit).

## What 2.3a changed (indirect exit + slot table + P-E registry, byte-identical)

Files: `src/x64.zig`, `src/nativegen.zig`, `src/trace.zig`.

- **`x64.zig`**: added `jmpMem(base, disp)` (FF /4 memory form, indirect near jump
  through `[base+disp]`) + golden-byte tests (`FF 20`, `FF 60 08`, `41 FF 20`).
- **`nativegen.zig`**: `CompiledTrace` gains `slots: []usize` (owned, one per IR
  instruction index, default-filled `shared_exit`) + a `gpa` handle for `deinit`.
  `emitReturn` takes `slot_addr: ?usize` — when set (frameless + chainable exit) it
  emits `movabs rax, &slot; jmp qword [rax]`; `null` (deopt_exit/prologue_fail) keeps
  the direct `movabs rax, shared_exit; jmp rax`. `compileImpl` allocs `slots` *before*
  `lower` (stable imm64), frees on every failure path; `slotAddr(slots, i)` helper.
- **`trace.zig`**: `NativeLink{parent, slot_index, child}` + `TraceState.armed_links`
  list; `armNativeLink` (records dependency, supersedes same-slot record, then writes
  slot); `resetLinksTouching(t)` (child-retire → reset parent slots to `shared_exit`;
  parent-retire → drop record; slot addr re-derived from live parent, never cached);
  `removeTrace` calls it *before* `destroy`. Focused unit test pins both directions +
  re-arm supersede + OOB/non-compiled no-ops.

Nothing arms a slot yet → `armed_links` always empty, every exit still resolves to
its own `ct.id`, so `final == ct` holds and output is byte-identical.

### Verification done for 2.3a
- `just test` green (EXIT=0; Debug asserts + P-E registry unit test).
- nsieve 9: tier-0 == tier-1a == native byte-identical.
- Differential tier-0 vs native OK on: nsieve, nsieve-bit, fannkuch, mandelbrot,
  nbody, spectral-norm.
- `just bench --filter nsieve --reps 5`: jit ms flat (nsieve 94.2 vs 2.1's 91.5;
  nsieve-bit 53.8 vs 53.3; within noise — one extra load per exit is perf-neutral).

## 2.3a foundation review (two independent models) — DONE, hardening landed

Reviewed the `b8fc3fa` foundation with codex gpt-5.6-sol + a fable
technical-architect pass (Bart's call: review the foundation now, not just at the
end). Both returned **"approve with changes"** and converged: byte-identical holds,
S2 reset ordering correct both directions, slot addressing sound, and the flat
identity-keyed registry is genuinely *better* than the plan's pointer-map (which
would dangle its cached `*usize` on parent-retire).

**Hardening landed as a follow-up commit (still inert / byte-identical):**
- **BUG-1 (real latent OOM-only UAF, mine):** `armNativeLink` re-arm did
  `swapRemove(old)` then `try append(new)`; a failed append stranded the slot armed
  but untracked → S2 UAF on the old child's retire. Fixed: mutate the record in
  place on supersede (no allocation on the re-arm path). Doc comment corrected.
- `armNativeLink` now returns `bool` (armed vs no-op) for P-F accounting; pinned
  "only writer of `slots[i]`" invariant; unit test updated.
- doc 17: recorded the `rdi`/`rsi` liveness contract (P-A) and the
  slot-index-vs-exit-kind collision open question (P-C, blocks 2.3c).

**Bart's decisions from the review:**
- `armNativeLink` **keeps** the explicit `target` param + gets a Debug
  bounds-assert (`target` within `child`'s page). Deferred to 2.3b because the
  assert reads `child.page` → needs real compiled children (= fable's real
  retire-then-reuse test, item 6).
- **Pull S3 forward into 2.3b:** fix the chain-safe result contract (child
  prologue-fail must carry cumulative `rbx` + a distinct reason, never
  `completed=0`) BEFORE arming any slot, so the first arm is unconditionally
  chain-safe. codex flagged this as a hard prerequisite to the first real arm.

## NEXT: Increment 2.3b — arm `.link`-terminal handoffs (now incl. S3)

Slot table + P-E registry exist but nothing arms a slot. 2.3b makes `driveChain`
store a child's frameless body entry into the parent's slot for the **single-contract
`.link` terminal only** (avoids S1 loop-done dual materialization):
- **S3 result contract FIRST (pulled forward):** split `prologue_fail` so a child
  whose entry guard fails *after* the parent committed writes cumulative `rbx` +
  `final_trace_id=child` + a distinct reason, never `exit_instr=-1`/`completed=0`.
- **Bounds-assert + BUG-2:** add the Debug `target`-within-`child`-page assert in
  `armNativeLink` and the missing-trampoline assert in `resetLinksTouching`; add a
  real retire-then-reuse lifetime test (arm, force `removeTrace`, assert parent slot
  reset before the arena slot can be reused).
- **Eligibility (P-G):** child `.compiled`, `inputs.len == 0`, exit kind `.link`.
- **Arming point (P-F):** inside `driveChain` *after* the existing per-hop
  `onSideExit`/counters run, so every accounting side effect still happens; then
  `armNativeLink(&parent, E, child, child.page.code.ptr)` (now returns bool).
- **Safepoint blackout:** do NOT arm when `suspend_ctl`/replay-line/exec-log active.
- **Dispatcher (P-B payoff):** DROP `assert(final == ct)`; route consumers through
  `final` not `ct` — `last_exit_instr`, guard-fail counting
  (`final.instrs[exit_instr]`), `onSideExit(final,…)`, `maybeArmContinuation`,
  productive-branch counting, source-branch discrimination (interp.zig ~2586–2807).
Then 2.3c (ordinary guards + loop-done, S1; slot-identity collision decision), 2.3d
(P-E lane-widen end-to-end + peer-review full diff). Increment 3 = full
`lj_asm_patchexit` port (guard-jump rel32 patching, no runtime re-entry).

## 2.3b CONTRACT REVIEW (codex gpt-5.6-sol) — planned scope is WRONG, re-plan pending

Ran the arming contract past codex before coding the dispatcher rewire. Verdict:
**"do NOT implement 2.3b as 'arm the slot, drop `final==ct`, route everything
through `final`'."** Two substantive findings the plan missed:

- **BLOCKER — the `.link` terminal is NOT single-contract on the child side.**
  The L→I hop (a `.link` continuation reaching its terminal, handing off to the
  inner-loop root `I`) is run today via `int_native.runLinkedLoopDone(regs)`, which
  sets `NativeResult.linked_loop_done = 1`; `I`'s inner loop-done guard READS that
  flag (nativegen ~4213) to pick linked-completion materialization vs ordinary
  deopt. A bare armed `jmp I.page.code.ptr` does **not** set the flag → `I` takes
  ordinary `deopt_exit`, never commits its final iteration → wrong state. So arming
  `.link`→inner drags in the S1 mode-propagation that was supposed to be deferred to
  2.3c. Fix needs one of: (a) a second entry point on `I` (`linked_entry`) that
  presets the flag then falls into the body — armed slot targets that; (b) a per-arm
  stub that sets the flag then jumps; (c) enter armed parents with the flag already
  set. (a) is cleanest (compile-time, no runtime thunk, `I` codegen unchanged).
- **DETERMINISM TRAP — "route consumers through `final`" is unsafe as-is.** Exit
  IDENTITY (`exit_instr`, guard lookup, exit PC, resume PC) must use `final`. But
  the recording-STEERING accounting (`onSideExit`, `maybeArmContinuation`,
  `countProductiveBranchExit`) must reproduce driveChain's *logical* per-hop events,
  which are specific (validate loop-done → `onSideExit(I, max(local,1))` → +1
  enclosing progress; NO `maybeArmContinuation`/`countProductiveBranchExit` on that
  hop). Calling the dispatcher's whole productive-exit block against `final` invents
  accounting the unarmed chain never did → different penalties/gates → different
  later trace recording → **non-byte-identical across modes.** Worse,
  `NativeResult.completed` is cumulative `rbx`, NOT `I`'s LOCAL count nor
  `ChainResult.completed`; feeding cumulative `rbx` to `onSideExit` can flip a
  low-yield event to "useful". Needs a WIDER result contract: final identity + final
  exit reason + final's **local** committed count + enclosing-chain progress — the
  current 4 `NativeResult` fields are insufficient.
- Minor: once linking is live, `traceById(id) orelse ct` (interp ~2595) should
  **fail closed** (assert), not silently reinterpret a child exit as the parent's.

Net: the first real arm needs (i) child linked-entry mode propagation, (ii) a wider
`NativeResult` (local completed + enclosing progress), (iii) a driveChain-faithful
accounting split (identity via `final`, steering-accounting replicates the hop's
logical events), (iv) fail-closed `traceById`. That's materially bigger than the
one-commit 2.3b in the plan.

**Bart's decision:** split into 2.3b-0 (inert scaffolding, reviewed) then 2.3b-1
(flip arming on + accounting split).

## 2.3b-0 — inert scaffolding: LANDED (byte-identical, awaiting peer review)

Four inert commits, each `just test` green + nsieve 3-mode byte-identical + tier-0
== `--jit-native` on the 6-benchmark differential. Nothing armed yet.
- **`9d16711`** — S3 prep: `prologue_fail` commits cumulative `rbx`, not literal 0.
  Byte-identical unchained (rbx provably 0); preserves progress once chained.
- **`963bdbb`** — fail-closed `traceById`: under `ran_native` assert the baked id
  resolves BEFORE `orelse ct` (kills the P-E dangling-link mask); keep `== ct`.
- **`319da11`** — `NativeResult.entry_rbx` snapshot (first body instr) → wrapper
  derives `ExecResult.local_completed = completed − entry_rbx`. Invariant
  `entry_rbx == 0` while unchained pins the mechanism; `local_completed` defaulted 0
  on tier-1a sites, read only on the native chained path (2.3b-1).
- **`954ea89`** — `linked_entry` stub (Trap-1 fix): every frameless body emits a
  secondary entry that presets `linked_loop_done=1` then falls through to
  `body_entry`; `CompiledTrace.linked_entry` = its abs addr (new
  `x64.Assembler.labelOffset`). Wiring invariant `arena ⟺ linked_entry`. Inert —
  nothing targets it until 2.3b-1.

## 2.3b-1 — flip `.link` arming ON: LANDED (byte-identical)

Two commits. **Step B (`66107a7`, committed):** dispatcher routes exit consumers
through `final = traceById(final_trace_id)` (strict on native — `@panic` on null,
release too; tier-1a still `ct`), productivity via `local_completed`.
**Step A (THIS commit):** `driveChain` actually arms + drains fused hops.

- **Arming** (`trace.zig`): after a hop is accounted, arm the continuation's
  `.link`-terminal slot → `inner.linked_entry` via `armNativeLink(current_link,
  len-1, inner, le)`. Eligibility: `tier == .native_only`, `safe_to_arm`,
  `inner.inputs.len == 0`, and the terminal (re-read AFTER the driver swap) is
  `.link` with `aux == inner_pc`. `safe_to_arm = suspend_ctl == null and
  !record_safepoint_lines`, computed in the dispatcher and threaded into
  `driveChain` (all 6 call sites). New counter `native_link_arms`.
- **Fused drain** (`trace.zig`): a `snt.run(current_link)` whose `final_trace_id !=
  current_link.id` fused straight into a child inner root. The drain resolves that
  child **STRICTLY** by `traceById(final_trace_id)` + `isInnerLoopRoot` shape check
  (never `findLoopTrace` substitution — a previously-armed slot can target a sibling
  `findLoopTrace` no longer picks). Loop-done vs. mid-loop is classified by
  `guardExitPc(child.instrs[exit_instr])` following a `for_loop`; steering uses the
  child's OWN `local_completed` (it inherits the parent's cumulative rbx). Same
  strict resolution seeds hop-0.
- **Hard-fail on identity break:** an unresolvable/mis-shaped fused id is a `@panic`,
  NOT a bail — the child's exit leaves `regs[]` with no known-coherent resume PC, so
  a `break`+resume could re-run a committed inner loop (silent double-count). Applies
  to hop-0 seed, the drain, and the dispatcher's native resolution.
- **Asserts dropped:** `assert(final == ct)` (interp.zig) and `assert(entry_rbx ==
  0)` (nativegen `runWithLinkedLoopDone`) — both false once fusion is live (a fused
  child inherits the parent's cumulative rbx and performs the final exit ≠ ct).

### Bug fixed during 2.3b-1 (under-count, native 2346810 vs 2406000)
A `guard_fits` array-guard mid-loop deopt on the fused inner's first trip
(`local_completed == 0`) was misclassified as loop-done, because `guardExitPc`
returns null for array guards and the drain's `fdone` defaulted null → `true`,
counting a phantom outer iteration and stranding iteration i=N. FIX: default the
null-`guardExitPc` and `exit_instr == maxInt` (prologue_fail) cases to `false`
(mid-loop → resume inner header, don't count).

### Peer review (codex gpt-5.6-sol, 3 rounds) — CLOSED
Round 1: 5 issues (prologue_fail maxInt phantom, fused-consumed-as-findLoopTrace,
pre-swap terminal validation, leftover `final==ct`, within-burst identity hole) —
all fixed. Round 2: demanded strict fail-closed identity resolution (no
substitution) — applied. Round 3: the fail-closed bails must `@panic` not `break`
(no safe resume PC), + strict native dispatcher resolution in release — applied.
Verdict: **no correctness blocker**; two doc nits (bail-comment wording, mirror the
9-completion bound into doc 17) — both addressed.

### Verification done for 2.3b-1
- `just test` green (EXIT=0; Debug asserts + link-counter tests).
- N-sweep 22/23/24/25/30/50/100/400: tier-0 == tier-1a == native byte-identical.
- Differential tier-0 == tier-1a == native OK on: nsieve, nbody, mandelbrot,
  fannkuch (spectralnorm.lua absent locally).

### Deferred out of 2.3b-1 (non-blocking, recorded in doc 17)
- **Issue 4:** native drain permits ≤ `visited.len + 1` (9) completions vs tier-1a's
  8 — a heuristic burst max, not a correctness contract; the "8-hop" comments should
  be reconciled to the 9-vs-8 split.
- **Issue 5 → P-F:** a slot stays armed and keeps fusing after `safe_to_arm` goes
  false; always correctly accounted, but widens the observation blackout window.
  Reset/decline-on-observation deferred to P-F.

NEXT: Increment 2.3c — arm ordinary source-branch guards + loop-done (S1 dual
materialization, S3 prologue-fail split, slot-identity collision decision).

## Unpushed local commits (Rule #15 — don't push unless asked)
master is well ahead of origin/master; do NOT push without Bart's say-so.

## Untracked files that belong to OTHER agents — do NOT stage
`CURRENT_TASK_E3.md` and similar scratch files.

**`bench/results/*.tsv` is NOT in that category** (corrected 2026-08-26). This
note used to list it, which read as "never commit these" and was wrong:
`bench/README.md` is explicit that the snapshots ARE committed — they are the
suite's history, and `latest.tsv` is the only git-ignored one. What the note
meant was "not *yet*": don't sweep up a board another agent is mid-run on.

So the rule is per-file, not per-glob — stage the snapshots YOUR session
produced (match the timestamp to your own `just bench` runs) and leave the rest.
That distinction had not been drawn since 2026-08-14, which is how 23 boards
piled up untracked; they need an owner to claim them or a deliberate sweep.
