# 54 — Inline native frame motion (recursion without callouts)

**Status:** partial — P0 landed (commits `3891fd1` + `3df7d53`), P1 landed
(commits `4084142` + `aeddcac`); P2–P3 outstanding. Design codex-approved
×7 rounds.
**Owner:** claude (campaign: every benchmark ≤1.2× LuaJIT; weakest-bench arc)
**Last updated:** 2026-09-18

## Implementation status

### Done

- [x] **P0 — static push eligibility + inline same-page push.** Commit-time
  terminal-shape checks decide whether a push epilogue exists at all; the
  eligible head-page fast path is emitted inline (callee guard, walls,
  window init, frame write, tick, ctx refresh) with decline → plain
  terminal exit. The `nativeSelfCallPush` callout is deleted from the
  head-page path. Implementation notes (discovered, per Mode-B duty):
  - **Enablers the design missed** (commit `3891fd1`): (1) the step-6
    field list omitted that `pushFrameVararg`'s struct literal ALSO
    invalidates the doc-20 fetch-image cache — skipping it inline is a
    real stale-image miscompile on frame-slot reuse, and `?u64` has no
    machine-encodable layout, so `code_cache_gen` became a plain u64
    with a `CODE_CACHE_GEN_INVALID = maxInt` sentinel (`cachedCodeFor`
    refuses to hit or fill at the sentinel gen — fail closed, no wrap
    panic); (2) `setRegionContext`'s "two field stores" were really an
    optional-struct store — `RegionPolicy.region_context` split into
    plain payload + `region_context_valid` byte behind
    `regionContext()`/`setContext()`/`clearContext()` accessors;
    (3) nativegen deliberately cannot import interp, so the `Vm`/
    `CallFrame` offsets travel via `FrameMotionAbi`, comptime-derived in
    `interp.zig` with pinned-width asserts and published through the
    seed ctx next to the new `descent_ok` byte.
  - **descent-gate sabotage is a unit matrix, not an integration run**:
    a healthy single run can never observe `descent_ok = 0` — the
    top-level epoch resets region receipts before any episode (verified:
    a receipt planted before `run()` was epoch-wiped and 743 pushes
    happened anyway). That unreachability IS the episode-invariance;
    the publication matrix over `prepareNativeEpisode` breaks each
    conjunct directly, and the emitted `cmp byte` consumer is pinned by
    the helper-removed formation test.
  - **P0 measurement** (interleaved A/B vs `a0e66ae` shadow, quiet
    machine): recursive-fib ≈−5% wall, 27.2× → 25.2× LJ; binary-trees
    flat at 9.8×. Small by design: `--jit-stats`/perf show ~60% of
    fib's run cycles on the two CONT anchors, whose pushes stay on the
    retained helper until P2 — `nativeSelfCallPush` remains in the
    profile via that path only, exactly the protocol's P0 receipt.
    Pushes = every call (7.05M at N=32 ≈ C(32)), pops ~88% of them.

- [x] **P1 — inline pop + open-upvalue ceiling.** The pop fast path emitted
  inline against the episode-structural invariants (each named, argued,
  and asserted); new VM-general `open_upvalue_ceiling` watermark replaces
  the per-pop full list scan; region-activation drop resolved to a
  fast-path skip under the descent gate (assert-verified) or a
  flag-guarded callout. Implementation notes (Mode-B):
  - **Enablers** (commit `4084142`): `open_upvalue_ceiling` on `Vm`, all
    `open_upvalues` mutations centralized (`appendOpenUpvalue` @max
    raise via `captureUpvalue`/keyframe restore/tests,
    `closeUpvaluesFrom` exact recompute on the walk it already does,
    `clearOpenUpvalues`); `FrameMotionAbi` gained
    `vm_self_ret_pops_off` + `vm_open_upvalue_ceiling_off`.
  - **Emission** (commit `aeddcac`): `emitInlineSelfRetPop` + static pop
    eligibility (ineligible pages emit NO pop epilogue);
    `nativeSelfRetPop`/`self_ret_pop_fn`/POP grammar deleted (values
    18/19 stay reserved). New `x64.movzxRegMem16` for the u16 ret-wiring
    loads; the copy loop uses the SIB forms with a runtime `want` and
    emit-time `count`/`a_reg`.
  - **The step-4 "skip" is NOT a pure no-op — design correction.** Under
    the gate `dropRegionActivation` closes nothing, but `nextActivation`
    has a side effect the doc missed: it CLEARS `region_context_valid`
    when the context seq matches the popped frame's (which the push set
    it to — i.e. on every pop). The inline sequence replicates exactly
    that residue (cmp seq + one byte store); the zero-activations
    premise is assert-pinned. No flag-guarded callout was needed.
  - **The invariant asserts live in `nativeFrameMotionAssert`**, a
    jit-debug-only C-ABI callout installed in the ctx and emitted after
    the net floor — zero release cost, and the jit-debug gate runs it on
    every pop. Sabotage-verified: a broken adjacency premise (nreg+1)
    panics the gate; a forced ceiling wall trips formation + ten-legs.
  - **The ceiling wall is defense-in-depth today**: native bodies cannot
    mint closures, so no open cell can appear over an episode-pushed
    frame mid-episode (a side-exit mint ends the episode; a later
    re-entry sees net=0 for that frame). Stale-LOW sabotage therefore
    bites in the maintenance unit matrix + restore test, not at
    integration; the wall becomes essential the day
    closure minting is traced (doc 43 P2+ direction). New
    escaping-closure ten-legs test pins the semantics either way.
  - **`check-jit-boundaries.py` body-callout authority rule**: C-ABI fns
    taking `*Vm`/`NativeSeedCtx` fail the check outside the episode-
    boundary allowlist (`nativeSeedFn`, `nativeSelfCallPush`,
    `nativeFrameMotionAssert`); 5 new scanner unit tests; the audited
    "no body callout carries frame authority" claim is now CI, and the
    real tree passes non-vacuously (scanner sees all 3 helpers).
  - **P1 measurement** (interleaved A/B vs the `a0e66ae` pre-arc shadow,
    load ~3.4): fib 199.6 → 171.6 ms ≈ **−14% cumulative P0+P1** (P1
    alone ≈ −9%); board row 172.4 ms / 24.7× / res 87.2%; btrees flat
    10.0×. Below the doc's −25-30% P0+P1 budget for a known reason the
    P0 receipt already named: cont-page pushes (~60% of fib's motion)
    still ride the C-ABI helper AND every armed transition still writes
    its ledger row + forced-yield cut — both are P2's levers.
    `--jit-stats` receipts: pushes 4.36M (= every call at N=31), pops
    3.63M (83% unwind natively), 925k episode entries (~4.7
    pushes/entry — P2 wants O(warmup)), native 84.4% of cycles, seam ~0.

### Outstanding
- [ ] **P2 — row-free armed frame-motion transitions + descent poll
  budget.** Armed `.ret_cont`/`.call_head` hits go row-free while the
  ledger is empty (rows-first episodes keep today's rows + cap;
  per-slot hit counters drain at episode end into the same accounting
  funnel); a deterministic per-episode transition budget
  replaces `LEDGER_CAP` as the blackout bound for frame-motion cycles.
- [ ] **P3 — warm entry for pushed frames.** Seed-stable pages skip the
  per-entry seed callout on push/pop re-entries (inline seed-slot
  materialization from the page-owned, generation+closure-stamped seed
  image); entry type guards skipped where the pushed arg refs'
  compile-time kinds satisfy them. The LuaJIT-parity end state.
- [ ] **Post-arc measurement.** Full board + `--jit-stats` + profile;
  binary-trees re-profile (its missing return traces are doc 44
  "Return recording breadth", not this doc).

## Why this exists

recursive-fib is the board's weakest bench: 27.0× LuaJIT (186.9 vs 6.9 ms,
board 20260918-173614) at **86.2% residency** — coverage is not the gap.
`--jit-stats` (fib 31): 100% of iterations traced, 0 seam, and still
~1415 cycles/iteration where LuaJIT does a whole call in ~9. The profile
(2026-09-18, 0320f38 + doc 53):

| bucket | % | what |
|---|---|---|
| `nativeSelfCallPush` + `pushFrameVararg` | 21.8 | C-ABI push callout per descent |
| `consumePushedDescent` + `enterHeadNativeQuiet` | 22.9 | dispatcher re-entry after episode cuts |
| `nativeSeedFn` | 8.4 | seed callout per `body_entry` re-entry |
| `nativeSelfRetPop` | 6.3 | C-ABI pop callout per unwind |
| `dropRegionActivation`, `opRet`, `opJCont`, accounting | ~8 | glue |
| actual `[JIT]` code | ~18 | the work |

Two structural causes, confirmed layer-by-layer per the Z-8 ladder:

1. **Every armed transition writes a ledger row.** `.ret_cont`/`.call_head`
   hits (5.65M in fib 31) each run `emitLedgerAppend` (~7 stores) into the
   32-entry ledger; `emitForcedYieldCheck` then guillotines the episode —
   925k episode entries for 879k iterations, `iters/native-entry ~0`.
   Frame-motion links are barred from silent promotion by an explicit v1
   exclusion (`trace_link.zig:843`, from the D12c commit `4893cbc`, no
   recorded rationale — the silent-set contract wants a static
   `resume_pc` per link and a pop's is dynamic), so the rows never stop.
2. **Frame motion itself is a callout.** `nativeSelfCallPush` re-derives
   the full fail-closed preflight per push — although the terminal-shape
   checks (`aux` bounds, `.call`, `b != all_results`, `is_vararg`) are
   compile-time constants of the committed trace and the episode gates
   (`receiptsInert`, `reg_top_pending`) are episode-invariant (its own
   comment says so). The pop twin adds a full open-upvalue list scan per
   pop. Then the OK path jumps to `body_entry`, re-running the seed
   callout + hoisted entry guards per push.

LuaJIT has no callout anywhere on this path: recording continues *through*
the call (`rec_func_lua`), so the push IS trace IR — arg slot stores + a
BASE shift — ending in `LJ_TRLINK_UPREC` (self-link,
`lj_record.c:1877-1888`); the return side is one inline `IR_RETF` guard
(proto + return-pc of the frame returned into, `lj_record.c:1000-1002`)
plus a BASE shift with `retdepth++`. This doc replicates that shape under
mahina's constraints (real `frames[]` structs, `call_seq`/tick streams,
coarse deopt, 8-mode equivalence). Bart's directive (2026-09-18): straight
to the end state, no intermediate mechanisms (no silent-promotion
extension, no helper slimming as its own arc) — the phases below are
slices of the final architecture, per Z-7.

**Generality (Z-6):** this is every recursive shape, not fib —
binary-trees, ackermann-likes, tree walks, parser/visitor recursion. fib
is the instrument; the general gap is "frame motion costs a runtime
round-trip". binary-trees additionally needs its base-case recording gaps
closed (doc 44 Outstanding), which this doc does not own.

## The mechanism

Notation: `proto = t.anchor.proto`, `nreg = proto.num_registers`
(compile-time per page), lanes `rdi` (tags) / `rsi` (payloads), `rdx` =
`*NativeResult`, `rbx` = cumulative counter, all per the existing body
ABI. "Decline" always means: jump to the plain terminal exit already
emitted below the epilogue — byte-identical semantics to today's helper
declines (tier-0 re-executes the call/ret generically, raising any error
itself). Nothing is mutated before the last check passes, so decline
needs no undo — the helper's own ordering, kept.

### P0 — static eligibility + inline same-page push

**Commit-time eligibility.** The four terminal-shape checks move from
run-time preflight to commit: `terminal.aux < proto.code.len`, the
instruction is `.call`, `instr.b != all_results`, `!proto.is_vararg`.
Ineligible pages emit no push epilogue at all (today they emit a callout
that declines on every single push — pure waste). The checked `instr`
fields (`a`, `b`, `c`) become emit-time immediates.

**Episode descent gate.** One byte, `NativeSeedCtx.descent_ok`, published
at `prepareNativeEpisode` from `receiptsInert() and !reg_top_pending and
final_cut == null`. All three are episode-invariant (the push helper's
round-5 comment already argues receipt inertness is; `reg_top_pending`
and `final_cut` are only written by tier-0/host boundaries the episode
cannot cross). Inline: `cmp byte, jne decline`. The gate byte is
re-published on every ctx refresh, so it can never describe a stale
episode.

**Inline push sequence** (head pages, `anchorKind == .head`, replacing
the callout between the terminal flush and the lane shift):

1. `descent_ok` byte check.
2. Callee guard: load tag+payload of slab slot `base + instr.a` (lane
   addressing off `rdi`/`rsi`, compile-time offset), check heap-function
   tag, load `closure.proto`, `cmp` against the baked `proto` pointer.
   This is the same proto-not-identity pin as today (a same-proto
   different-upvalue closure pushes ITS OWN closure pointer into the
   frame — the actual entering object, so upvalue resolution downstream
   is per-activation-correct, the round-5 confirmation verbatim).
3. Walls: `vm.depth < max_call_depth` (load + cmp imm);
   `stack_top + nreg <= reg_capacity` (load, add imm, cmp against
   `ctx.reg_capacity`). `next_call_seq != maxInt` (cmp; decline lets
   tier-0 hit its own panic path).
4. Caller resume freeze: `frames[depth-1].pc = aux + 1` (imm store; the
   frame pointer is derivable as `vm.frames + (depth-1)*@sizeOf(Frame)`).
5. Window init, fully unrolled at emit time: for `j in 0..nreg`: if
   `j < num_params and j < nargs` copy tag+payload from caller slot
   `instr.a + 1 + j`; else store the nil tag. All offsets compile-time.
6. Frame write at `frames[depth]`: closure (the guarded payload),
   `call_seq = next_call_seq` (then increment the VM field), `base =
   stack_top`, `pc = 0`, `ret_dest = instr.a`, `ret_count = instr.c`,
   varargs 0/0 — the `pushFrameVararg` body verbatim, minus its
   re-checked walls (step 3 is those walls).
7. `depth += 1`; `stack_top += nreg`; `setRegionContext(depth,
   call_seq)` inline (its two field stores); `tick +%= 1` (the
   `tickCallEntry` body — one add on the baked `TraceState` field).
8. ctx refresh inline: `ctx.closure`, `ctx.base += nreg`,
   `ctx.call_seq` (proto/`reg_capacity`/`vm` unchanged within the
   episode). Required while P3 is unlanded: the seed prologue at
   `body_entry` reads `ctx.base`, and the pop path compares
   `ctx.base`/`ctx.call_seq`.
9. `self_call_pushes += 1` (the `TraceState` witness counter —
   round-1 should-fix 6: `--jit-stats` and the formation tests consume
   it; one inline add, same as the tick); `pushed_frames += 1`, lane
   shift, `jmp body_entry` — unchanged.

`nativeSelfCallPush` is deleted from this path, not kept as a slow path:
its decline outcomes are exactly the plain terminal exit, and every check
it performs is either an emit-time constant (step 0), the episode gate
(step 1), or steps 2–3. The helper function itself remains for the
cont-page `.call_head` path until P2 rebuilds that path on the same
inline sequence.

### P1 — inline pop

**Commit-time eligibility**, symmetric: `aux` in bounds, `.ret`,
`instr.b != all_results`, `!is_vararg`, `instr.a + instr.b <= nreg`.

**Structural invariants replace re-derivation.** The helper re-verifies
frame identity because a C-ABI boundary is distant; the inline sequence
executes inside the very episode that created the state, so each dropped
check is replaced by a named invariant, asserted in debug builds.
Round-1 should-fix 8 sharpens the premise: it is NOT "no host call" in
the abstract — native bodies DO make runtime callouts (allocation,
string helpers, hash resolves). The actual invariant is that **no body
callout carries frame-mutation authority**: body callouts take `*Heap`
or value operands, never `*Vm` (audited — the current tree conforms),
so none can touch `frames[]`, `depth`, `stack_top`, `reg_top_pending`,
`final_cut`, or the open-upvalue list; native guest calls and
pcall/xpcall remain trace barriers (`interp.zig` ~5914), so no unwind
can occur inside an episode. This contract is made mechanical, not
customary: `tools/check-jit-boundaries.py` gains a rule that body
callout signatures must not take `*Vm` (allowlist for the episode-
boundary helpers that legitimately do), so a future `*Vm` body helper
fails CI instead of silently invalidating every removed identity
check.

- *net > 0* — from the motion counters, both written only by this
  episode's own emitted code (the existing inline computation, kept).
- *top frame is ours* — net > 0 means the top frame was written by step 6
  of an inline push in THIS episode (`frames[]` is untouched by anything
  else mid-episode: no tier-0, no host call — both are episode
  terminators). Hence `frame.base == ctx.base`, `frame.call_seq ==
  ctx.call_seq`, `frame.closure.proto == proto` hold by construction.
- *parent is same-proto* — the parent is either another episode-pushed
  frame (same proto by the push guard) or the episode ENTRY frame, whose
  proto equals the anchor proto by head-entry patching (`jfunc_head` is
  installed per-proto; the entry frame was entered through it or through
  a `guard_func`-covered call). Window adjacency `frame.base ==
  parent.base + nreg` follows from push step 6 (`base = stack_top`).

What genuinely stays per-pop, inline:

1. `descent_ok` byte; net > 0 (existing).
2. **Open-upvalue ceiling**: new VM field `open_upvalue_ceiling: usize`
   — an upper bound on `index+1` over the open list. Round-1 blocker 5:
   the list is NOT mutated at only two sites — keyframe restore rebuilds
   it directly (`keyframeser.zig` ~842), so site-local maintenance
   invites a stale-LOW ceiling (the unsound direction). Therefore the
   maintenance is centralized: all `open_upvalues` mutations go through
   VM methods that own the ceiling (raise on open via `@max`; exact
   recompute in `closeUpvaluesFrom`, which already walks the list, and
   on `swapRemove` compaction; reset to 0 on empty), and keyframe
   restore publishes the ceiling after rebuilding the list (a one-pass
   max over what it just appended). Direct field access outside those
   methods is removed in the same change. The pop check is one load +
   cmp: `ceiling <= frame.base` → no open cell at or above the popped
   window. With centralized maintenance a stale-low ceiling has no
   remaining producer; a stale-high ceiling only declines spuriously —
   fail-closed. This is a VM-general structure (Z-6): it also serves
   any future pop/unwind fast path.
3. Return wiring: `want = frame.ret_count`, `dst_off = frame.ret_dest`
   (dynamic — the frame may have been pushed by a different call site
   than this pop's, e.g. fib's two sites), bounds-checked against `nreg`
   (imm cmps; `ret_count == all_results` declines — cannot occur for
   episode-pushed frames, but the two loads are needed anyway and the
   cmp is free). Result copy: `count`/`a_reg` are emit-time; `want` is a
   small runtime bound — a compact copy loop (nil-fill tail), matching
   `opRet`'s rooting order (copy while the callee window is under
   `stack_top`, then shrink).
4. Region-activation drop: under the descent gate, receipts are inert
   for the whole episode; implementation verifies (targeted debug
   assert + the ten-leg matrix) that `nextActivation(call_seq)` is
   always null for episode-pushed frames under that gate. If confirmed:
   skipped entirely inline (the assert stays). If not: a flag byte in
   ctx (`regions_live`) selects a callout, fail-closed.
5. `depth -= 1`; `stack_top = parent.base + nreg`; ctx refresh (base
   `-= nreg`, closure/call_seq from the parent frame);
   `self_ret_pops += 1` (the `TraceState` witness counter, round-1
   should-fix 6) and the `popped_frames` increment (existing);
   `ret_resume_pc = parent.pc` published to ctx for the existing
   ret-cont compare chain — which is already inline and unchanged. No
   tick (tier-0 `opRet` does not tick; the tick stream stays a pure
   function of the call stream).

`nativeSelfRetPop` is deleted from this path (same argument as the push).

### P2 — row-free armed transitions + descent poll budget

**The rows — and the consumer grammar they require (round-1 blocker 3
rewrote this section).** An armed `.ret_cont` or `.call_head` hit
currently appends a full ledger row and, at `LEDGER_CAP`, force-yields.
The original claim that consumers "only need the final row + top frame"
is FALSE for the current dispatcher: `consumePushedDescent`
(`interp.zig` ~3191-3260) is positional — row 0 must be the entered
trace, cumulative ordering computes per-segment work, and an armed
sibling-handoff row is validated against the OWNER OF THE NEXT ROW.
Unordered counters cannot reconstruct interleavings. P2 therefore ships
a two-mode episode grammar, not a patch to the old one:

Round-2 blocker 1 killed the sticky mid-flight switch (a row-free
prefix makes row 0 a non-entered-trace owner and poisons the first
row's `ledger_cum`); the modes are instead **mutually exclusive per
episode**, enforced by two cheap tests with no retroactive grammar:

- **Row-free mode** (the recursion steady state): a CROSS-PAGE
  frame-motion transition (`.ret_cont`/`.call_head` hit) goes row-free
  only while the ledger is EMPTY (`ledger_len == 0`, one load+test —
  if any row exists, cross-page frame motion appends its row exactly
  as today AND keeps `emitForcedYieldCheck` at the jump, so a
  rows-first episode stays fully positional with the ledger cap as its
  yield bound intact — round-3 blocker 1: the budget cannot REPLACE
  the cap in rows mode, it only adds the pre-mutation decline). The
  first row-free cross-page transition sets
  `NativeResult.frame_motion_taken` (tail-appended byte, initialized 0
  beside the budget in `runWithLinkedLoopDone` — round-2 should-fix
  6's explicit ABI/init contract). **Same-page D11 pushes are rowless
  in BOTH modes and set nothing** (round-3 blocker 2, adjusted): they
  are rowless TODAY, coexist with sibling rows under the current
  grammar (the next recorded row's owner is unchanged by a same-page
  push, so next-row-owner validation is unaffected), and emitting a
  `.call_push` row for them would fail that row's live-`.call_head`
  validation. They consume descent budget. Each link slot owns a `u64`
  hit counter (page-owned storage next to the existing
  `ret_cont_keys`), bumped inline on row-free hits.

  **Bounded drain (round-3 blocker 3 — Rule #20).** The dispatcher
  must not scan the global armed-link registry to find changed
  counters (drain cost would scale with every armed link in the VM).
  Each slot's counter record carries an `episode_gen` stamp; the
  first-hit sequence is order-pinned (round-4 should-fix 3 — without
  the reset, a drain would read lifetime-cumulative counts as episode
  counts): on a row-free hit with `slot.gen != ctx.episode_gen`:
  (1) capacity check (full → decline into the miss path), (2)
  `slot.count = 0`, (3) `touched[touched_len++] = slot`, (4)
  `slot.gen = gen`; then — first hit or not — `slot.count += 1`. One
  load+cmp per hit, the four-step publish on first hit only; the
  descent budget bounds per-episode counts far below overflow.
  `touched` is a fixed-capacity (v1: 64) pointer array + length at the
  `NativeResult` tail, initialized empty per episode. The decline on a
  full list is an ordinary final row + dispatcher bounce (the next
  episode drains fresh) — bounded, deterministic, logged per the
  no-silent-caps rule. Episode-end drain walks
  `touched[0..touched_len]`, O(distinct slots touched), ≤64.
- **Non-frame armed links refuse after frame motion.** Every OTHER
  armed dispatch site (sibling handoff, bridge, …) on EVERY page tests
  `frame_motion_taken` (round-4 should-fix 4: no "frame-motion-capable
  page" qualifier — after a row-free hop, ANY subsequently reachable
  page's non-frame arm would poison the positional grammar, whether or
  not that page has an eligible terminal itself): set → take the miss
  path (final row, return to the dispatcher) instead of following the
  arm. The episode ends with zero intermediate rows — and a final
  row whose owner is the current page, which is ALREADY legal grammar:
  same-page D11 pushes produce exactly that shape today and the motion
  consumer resolves it from the final row + actual top frame. The next
  episode re-enters at the handoff target and may run fully positional.
  Cost: recursion↔handoff interleavings pay one dispatcher bounce per
  non-frame transition — today's price for those transitions, only at
  the mechanism boundary, logged per the no-silent-caps rule.

Ledgers are therefore always all-positional (frame motion never
preceded a row) or empty-plus-final — `consumePushedDescent` keeps its
current code unchanged for the former and gets a totals path for the
latter. Entry identity for the totals path is the dispatcher's own `ct`
(round-2 should-fix 6: NOT `final_trace_id`, which names the final
exiting trace).

**Totals-consumer accounting (round-2 should-fix 5 — exact semantics,
not "multiplicity").** Per drained (owner, target, count): link-hit
diagnostics add the drained count; `accountCandidateCharge(.entered)`
applies once per owner (it only resets `consec_refusals` — idempotent);
`accountTraceRun(owner, 0)` once per owner, preserving today's one-shot
intermediate semantics (intermediate frame rows charge zero `seg_local`
work because `rbx` does not advance on one-shot frame pages — this
zero-work invariant is now stated normatively and asserted in the
drain). The final row keeps its current completed/receipt treatment
untouched. The per-segment cycle split is coarsened to per-owner for
row-free episodes — diagnostic only; drained transition counts are
never reinterpreted as completed iterations (`completed >= min_useful`
feeds steering, so conflating them would corrupt qualification).

Under the descent gate region receipts are inert, so no region
re-pairing consumer exists for the removed rows (the same argument that
admits the descent in the first place).

**The budget.** Removing rows removes `LEDGER_CAP` as the frame-motion
blackout bound, and the doc 44 blackout paragraph's
`max_call_depth + LEDGER_CAP` becomes `max_call_depth + ∞` — not
acceptable: the dispatcher services patch drains, arm consumption, and
interrupt-latency-sensitive facilities at episode boundaries.
Replacement: `NativeResult.descent_budget: u32` — appended at the ABI
TAIL by the frozen-layout rule, initialized to the compile-time
constant (v1: 65,536) in `runWithLinkedLoopDone`, where a fresh
`NativeResult` is created for every native episode
(`nativegen_artifact.zig` ~445 — round-1 confirmed this is the
replay-stable init point; every episode re-entry after a yield gets a
fresh budget by construction). Round-1 blocker 4 relocated the check:
the budget is decremented-and-tested **pre-mutation, at the top of each
frame-motion sequence** (before the push's step 1 / the pop's step 1
and before a `.call_head`/`.ret_cont` jump commits). At zero the
sequence takes its ordinary DECLINE path — plain terminal exit, outcome
`.normal`, no frame mutated — which is already legal grammar at every
one of these sites; no `.yielded` variant, no new final-row kind, no
committed-push cut. The budget is a pure function of the deterministic
transition stream — replay-stable, 8-mode-invisible (it moves WHERE
code runs, never what it computes; the tier-1a legs never see it). GC:
allocating bodies allocate through callouts that can already run GC
steps mid-episode (doc 45); the budget additionally bounds the
dispatcher-service blackout for allocation-free recursion like fib.
`emitForcedYieldCheck` keeps its role for the other link kinds AND for
frame-motion rows in rows-first mode (round-3 blocker 1); only the
row-free path substitutes the budget check for the cap check.

### P3 — warm entry for pushed frames

Post-P0/P1/P2 the remaining per-transition toll is `body_entry` itself:
the seed callout (`nativeSeedFn`, 8.4%) plus hoisted entry type guards
per push/pop re-entry. LuaJIT re-runs neither — recorded call args are
TRefs with known types. Round-1 blockers 1+2 rewrote this section: the
original "copy seeds from the departing window" was geometrically
impossible (synthetic seed slots start at `num_registers` — exactly
where the pushed window begins, so the push's own window init destroys
them first; the pop mirror has no preserved parent image at all), and
"no store to seed sources" does not imply seed EQUALITY across
activations (the push accepts a same-proto DIFFERENT closure, through
which `.upvalue`-class seeds resolve).

**Per-page seed image with a validity stamp (round-2 blockers 2+3
rewrote this).** Seed values are staged in PAGE-owned storage (like
`ret_cont_keys`: allocated at commit, sized to the page's plan count) —
one shared ctx image cannot serve an episode alternating over several
head/cont pages. Each image carries a validity stamp: `(generation,
closure)`. `NativeSeedCtx.episode_gen: u64` is incremented by the
dispatcher's episode-entry funnel (`runWithLinkedLoopDone`, beside the
fresh `NativeResult`) — every dispatcher re-entry makes ALL images cold
by construction, closing the tier-0-mutated-globals-between-episodes
hole. A COLD entry (`nativeSeedFn` path) fills the page's image as a
byproduct of the seeding it already does and stamps it with the current
`episode_gen` and the closure it seeded for. A WARM entry requires
`image.gen == ctx.episode_gen` AND `image.closure == <the entering
closure>` (for a push: the just-guarded callee payload register; for a
ret-cont re-entry: the popped-into frame's closure) — any mismatch
takes the cold `body_entry`, which refills and re-stamps the image for
the NEW closure. No immutable "episode closure" field exists and none
is needed: the pin lives in the per-image stamp, `ctx.closure` remains
the mutable current-activation field, and closure alternation degrades
to cold entries per alternation — sound, thrash-visible in
`--jit-stats` (cold-entry counter), pathological by construction.

**Seed-equality gate (per-kind, conservative — round-2 blocker 4
narrowed it).** A page is warm-eligible only for plans whose every
seed kind is proven identical across episode-internal activations
under the image's closure pin. v1 admits:
- `.upvalue` — resolves through the pinned closure; identity ⇒ same
  cells; seed-stability (below) ⇒ same values.
- `.upvalue_cell` in its ANCHOR-SENTINEL form only (`callee_slot ==
  UPVALUE_CELL_ANCHOR`): the callee-path form resolves through a
  closure read from a body-computed slot, which the pin does not reach
  (`resolveUpvalueCellBits`, interp.zig ~1088).
- `.global` — resolves through the globals table; this page's writers
  are excluded by seed-stability, other pages' native writers are
  detected by the `seed_epoch` comparison, and cross-episode writers
  are fenced by the generation stamp.
Excluded in v1 (any occurrence ⇒ the page keeps the cold path):
`.hash_cell` (cell addresses are per-table-state), `.callee_upvalue` /
`.callee_global` (body-computed slot contents), and
`.upvalue_slot_alias` (its whole doc 53 contract is per-entry
validation of a relation involving the closure in `callee_slot` — the
anchor pin does not pin that slot; admitting it needs its own
callee-slot relation proof, deferred).

**Seed-stability predicate** (unchanged in role, narrowed in claim):
commit-time, over the page IR — no global store, no `ustore`, and no
hash store while a `hash_cell` seed is in the plan. It proves only that
the pinned activation's sources are unwritten BY THIS PAGE; the
per-kind gate above carries the across-activation burden, and the
mutation epoch below carries the across-PAGE burden. fib and every
pure-scalar recursion pass all three.

**Seed mutation epoch (round-4 blocker 2).** Page-local stability does
NOT cover an episode alternating over several frame-linked pages: page
B can `ustore`/global-store an admitted source between two of page A's
warm entries within one `episode_gen` (B's stores are native-emitted
body ops — `hstore`/`ustore`, `nativegen.zig` ~1405/1455 — and the
recorder's seed/store exclusion is recording-session-local). Fix: a
VM-global `seed_epoch: u64`; every native-emitted `ustore` and every
native-emitted hash/global store site bumps it inline (one memory add
— conservative: ANY hstore bumps, because a global store IS an hstore
to the globals table and emit-time cannot cheaply prove a table is not
the globals table; refinement — an emit-time known-not-globals proof
for hrefk-rooted stores — is recorded as deferred). Images stamp
`seed_epoch` at fill; warm entry adds one epoch cmp. Consequence:
table-writing recursion (binary-trees) self-excludes from warm entries
while keeping every P0-P2 win — accepted v1 coarseness, logged.
(`.upvalue_cell` images bake a cell ADDRESS, not contents — cell-
content writes don't invalidate them and the epoch is irrelevant to
that kind; `.upvalue`/`.global` images bake VALUES and are exactly
what the epoch fences. Tier-0 writes between episodes are already
fenced by `episode_gen`.)

**Entry guards at the warm entry (round-1 should-fix 7).** Entry checks
encode more than a slot kind: table-shape guards (type + metatable
absence + lane + element type + stride, `nativegen.zig` ~852), function
proto-id pins (~895), native-builtin identity (~918), hash validation,
alias relations. The warm entry skips ONLY the plain tag check, and only
for slots whose pushed content has an emit-time kind that satisfies it
(arg slots copied from typed homes; nil-filled slots against
nil-expecting guards). Every structural/identity guard class —
table-shape, proto-id, builtin identity, hash, alias — is retained at
the warm entry unless a separate per-class proof exists. The only v1
exception is provenance-scoped (round-2 should-fix 7): the proto-id
guard on exactly the slot whose content the warm path just proved
pointer-equal to `image.closure` (the anchor-callee slot of a push) —
that specific object's proto is the anchor proto by the pin. Every
OTHER `.func` slot (functions from arguments, globals, other upvalues)
keeps its proto-id guard verbatim. Non-seed-stable pages keep today's
full `body_entry` path.

## Soundness

- **Decline-ordering.** Every inline sequence checks everything before
  mutating anything (the helpers' own discipline, preserved
  instruction-for-instruction); a decline is byte-identical to today's
  helper decline: plain terminal exit, tier-0 re-executes generically,
  errors (StackOverflow et al.) raise with intact frames.
- **The callee guard is unchanged in strength.** Proto-pin, not identity
  — safe for the same reason the helper argues: the pushed closure and
  refreshed ctx are the actual entering objects.
- **Structural invariants (P1) are episode-local.** Their premises —
  nothing but this episode's own code mutates `frames[]`/`depth`
  mid-episode — hold because every path that could (tier-0 dispatch,
  host reentry `callValueImpl`, error unwind) is an episode terminator by
  construction. Each dropped check carries a debug assert; the ten-leg
  matrix and the sabotage protocol (below) must prove each assert can
  bite.
- **Open-upvalue ceiling** is an over-approximation maintained by the
  centralized VM methods (including keyframe restore — round-1
  blocker 5); a stale-high ceiling declines (safe), a stale-low ceiling
  has no producer once direct list access is removed.
- **Tick/call_seq streams.** The inline push advances both exactly as
  `opCall`+`pushFrameVararg` do (one tick per successful entry, one
  call_seq per frame); the pop advances neither (as `opRet`). All legs
  identical — hashgate is the gate, as always.
- **Determinism/replay/8-mode.** No clock, no ORDERING-relevant address,
  no randomness enters any decision: eligibility is compile-time, the
  descent gate and budget are pure functions of deterministic streams.
  The P3 warm/cold selection compares closure OBJECT IDENTITY (round-3
  nit: pointer equality as opaque identity, reconstruction-stable, never
  ordered or hashed into a decision) — and like every tiering choice it
  moves only WHERE code runs, never what it computes. The §R1-5 bypass
  set is untouched — replay/suspend/exec-log/safepoint legs never reach
  a patched native entry, so every new inline seam self-disables there
  structurally (the doc 44 sentence, still true).
- **P3 image publication + GC (round-3 should-fix 4).** A cold fill
  invalidates the image stamp FIRST and publishes it LAST, only after
  `SEED_OK` — a partial or declined fill is never warm-visible. The
  image is a non-owning cache, not a GC root, by this proof: a warm
  entry's values are reachable independently at the moment of use (the
  entering closure is live in the frame and roots its admitted
  upvalues/cells; the globals table roots `.global` values), the
  `seed_epoch` comparison rejects any image whose sources a native
  writer touched since the fill (round-5: the page-local no-writer
  predicate does NOT carry this — cross-page stores are exactly what
  the epoch exists for), the generation stamp fences stale
  cross-episode payloads, and the stamp's closure pointer is compared
  as opaque identity, never dereferenced. `episode_gen` follows the
  `call_seq` overflow discipline (refuse at `maxInt`, no wrap);
  `seed_epoch` is RESET TO 0 at episode entry immediately after the
  `episode_gen` bump (round-5/6 overflow contract: only within-episode
  staleness matters — cross-episode is the generation's job. Round-6
  killed the "bounded by budget × store sites" argument: a native LOOP
  executes stores per iteration without consuming any transition, so
  no static bound exists. The mechanism is fail-closed saturation
  instead: store sites increment saturating at `maxInt`; a fill that
  observes `seed_epoch == maxInt` does not publish its stamp (the page
  stays cold for the rest of the episode); therefore no stamp ever
  equals `maxInt`, and once saturated every warm compare fails —
  poison by construction, no wrap-revalidation possible).
- **GC.** The inline push/pop allocate nothing and only read/write VM
  frame state, exactly like the helpers. The pop's result copy precedes
  the `stack_top` shrink (rooting order preserved). P2's budget bounds
  the dispatcher blackout; allocation-driven GC keeps its existing
  callout paths.
- **P3 seed stability** is a compile-time property of the page's own IR
  covering only that page's stores; user code and host effects terminate
  the episode, and OTHER frame-linked pages' native stores — which do
  NOT terminate it — are caught by the `seed_epoch` comparison at the
  next warm entry (round-5 correction of the original page-local
  claim). The warm entry never skips a guard it cannot prove at emit
  time.

## What this deliberately does not do

- No recording changes, no tier-1a changes: recording and the tier-1a
  legs keep the interp terminals byte-identical (the D11 rule). This is
  lowering + runtime only.
- No new link kinds, no new ROW kinds (round-4 nit: P2 does add the
  empty-plus-final totals consumer beside the positional one) — P2
  *removes* rows from an existing kind's row-free path and re-routes
  their accounting.
- binary-trees' missing return traces (recorder gaps: `new_table`
  base-case, nil-child `get_index`) stay doc 44 Outstanding items; this
  doc makes the frames cheap, not the traces exist.

## Measurement protocol

Per phase: `just bench --filter recursive-fib` + binary-trees; full board
at arc end. `--jit-stats` receipts: episode entries should collapse
toward O(warmup) at P2 (`iters/native-entry` from ~1 to ~10³⁺);
`nativeSelfCallPush` should leave the HEAD-page profile at P0 (it
remains on the cont-page `.call_head` path until P2 rebuilds that path
on the inline sequence — round-4 nit); `nativeSelfRetPop`/`nativeSeedFn`
leave at P1/P3 respectively. Wall-time expectations (Rule #20
budget): P0+P1 ≈ −25-30% (callout + helper + dropRegion), P2 ≈ −20-25%
(re-entry glue amortized), P3 ≈ −8-12% (seed callout + guards) —
compounding to roughly 186.9 → 70-90 ms (27× → ~10-13×); the remainder is
body codegen quality (flush-all per transition), a later arc. Sabotage
protocol per phase: every replaced check gets a targeted break proving
the replacing invariant's assert (or decline) bites; every new test must
fail under sabotage before it counts.

## Open questions for review

- [ ] P2 budget value: 65,536 transitions ≈ 100-200 µs of blackout at
  fib densities — acceptable for patch-drain latency? (Deterministic
  constant either way; tuning is free.)

Resolved by codex round-1 (kept for the record): `descent_ok`
episode-invariance verified against all writers (`reg_top_pending` =
tier-0 multret paths only, `final_cut` published only after top-level
return, `receiptsInert()` ⇒ `nextActivation` cannot return a live
activation — the P1 step-4 assert-then-skip is expected to confirm);
tick/call_seq stream claims verified against `opCall`/`opRet`; no
body callout in the current tree carries `*Vm` frame-mutation
authority (premise restated as the audited allowlist + CI rule).

Resolved by codex round-2: per-segment attribution is NOT telemetry-only
(`completed` feeds `hit_count`/qualification) — the totals consumer's
exact semantics above are the answer, with the one-shot zero-work
invariant asserted; tier-1a never warm-enters (it keeps the interp
terminals), so seed images live strictly on the native side and the
tier-1a seeding twin neither produces nor consumes them.

## Review ledger

Codex round-1 (thread `01a0b428-95a3-7771-a38a-08ec6c314dd9`,
2026-09-18, verdict **NEEDS CHANGES** — all items folded into the body
above):

1. [blocker] P3 window-overlap: synthetic seed slots begin at
   `num_registers` = the pushed window's base, so departing-window seed
   copies read destroyed storage (pop mirror: no preserved parent
   image). → Episode seed image in ctx-owned scratch.
2. [blocker] Seed stability ≠ across-activation seed equality (same-
   proto different-closure pushes; per-kind resolution paths). →
   Anchor-closure identity pin + per-kind admission list; `.hash_cell`
   and `.callee_*` excluded in v1.
3. [blocker] `consumePushedDescent` is positional (row 0 = entered
   trace; sibling-handoff validated against the NEXT row's owner);
   unordered counters cannot reconstruct mixed interleavings. →
   Two-mode grammar: pure frame-motion episodes go row-free with a
   totals consumer; first non-frame-motion row sets sticky `rows_live`
   and the episode reverts to today's positional grammar.
4. [blocker] Budget cut had no final-row grammar for same-page pushes
   (`.head_terminal` rejects `.yielded`; `.call_push` finals are
   cont-page-owned). → Budget checked PRE-mutation at the top of each
   frame-motion sequence; exhaustion takes the ordinary decline path
   (`.normal`), no new grammar. Init pinned to `runWithLinkedLoopDone`'s
   fresh-`NativeResult`-per-episode (replay-stable).
5. [blocker] `open_upvalue_ceiling` missed the keyframe-restore direct
   list rebuild → stale-LOW possible. → Centralized VM-method
   maintenance + restore publishes the ceiling; direct access removed.
6. [should-fix] Inline sequences dropped `self_call_pushes`/
   `self_ret_pops` witness counters (`--jit-stats` + formation tests).
   → Kept inline (one add each).
7. [should-fix] Entry guards encode structure/identity beyond tags
   (table shape, proto id, builtin identity). → Warm entry skips ONLY
   emit-provable tag checks; all structural/identity classes retained
   (sole v1 exception: anchor-callee proto-id, discharged by the
   identity pin).
8. [should-fix] P1's "no host call" premise restated as the audited
   "no `*Vm` body callout" contract + `check-jit-boundaries.py` CI
   rule.

Codex round-2 (same thread, 2026-09-18, verdict **NEEDS CHANGES** — all
items folded into the body above):

1. [blocker] Sticky `rows_live` cannot retroactively restore the
   positional grammar (row-free prefix ⇒ row 0 owner ≠ entered trace;
   first live row's `ledger_cum` swallows the prefix work). → Modes made
   mutually exclusive per episode: frame motion is row-free only while
   `ledger_len == 0` (else it appends rows as today), and non-frame
   armed links take their miss path once `frame_motion_taken` is set —
   ledgers are always all-positional or empty-plus-final.
2. [blocker] Seed image ownership/lifecycle unspecified (one ctx image
   can't serve multiple pages; stale reuse across episodes). →
   Page-owned images with `(generation, closure)` validity stamps;
   `episode_gen` bumped per dispatcher episode entry in
   `runWithLinkedLoopDone` makes all images cold on re-entry.
3. [blocker] "Episode closure stashed in ctx" collides with P0's
   mutable `ctx.closure` refresh (the pin would compare against itself).
   → No episode-closure field at all; the pin lives in each image's
   stamp, compared against the entering closure object per warm entry.
4. [blocker] `.upvalue_cell` admitted too broadly (callee-path form
   resolves through a body-computed slot) and `.upvalue_slot_alias`'s
   per-entry validation contract cannot be replaced by an anchor pin. →
   Anchor-sentinel `.upvalue_cell` only; `.upvalue_slot_alias` excluded
   from warm admission in v1.
5. [should-fix] Totals accounting semantics pinned exactly:
   per-owner `accountTraceRun(owner, 0)` + idempotent
   `.entered` charge + drained counts as link-hit diagnostics only;
   one-shot zero-work invariant stated and asserted; transition counts
   never conflated with `completed`.
6. [should-fix] `frame_motion_taken` (né `rows_live`) given the
   explicit tail-append + `runWithLinkedLoopDone`-init contract; entry
   identity corrected to the dispatcher's `ct` (not `final_trace_id`).
7. [should-fix] The proto-id guard exception provenance-scoped to
   exactly the pin-proven slot; all other `.func` slots keep their
   guards.

Codex round-3 (same thread, 2026-09-18, verdict **NEEDS CHANGES** — all
items folded into the body above):

1. [blocker] Rows-first frame motion kept the budget as its only yield
   bound, but rows can hit `LEDGER_CAP` long before the budget. → Mode
   split: rows-first frame rows keep `emitForcedYieldCheck`; only the
   row-free path substitutes the budget check.
2. [blocker] "Frame motion appends its row" cannot cover same-page D11
   pushes (no legal row kind; `.call_push` validates a live cross-page
   link). → Same-page pushes are rowless in BOTH modes — they are
   rowless today, don't change page ownership (next-row-owner
   validation unaffected), and consume budget. Adjusted from the
   round-3 suggestion: they also do NOT set `frame_motion_taken`,
   because the rowless-push + sibling-rows mix is exactly today's
   grammar (flagged for round-4 confirmation).
3. [blocker] Counter drain had no bounded discovery (global registry
   scan = Rule #20 failure). → Episode-gen-stamped slots self-publish
   once into a fixed-capacity (64) touched list at the `NativeResult`
   tail; overflow declines into the miss path; drain is O(touched).
4. [should-fix] Image publication (invalidate-first, publish-last on
   `SEED_OK`) + non-owning GC proof + `episode_gen` overflow discipline
   spelled out in Soundness.
5. [nit] Superseded phrasings fixed (P3 outstanding bullet; determinism
   claim now "object identity, opaque, reconstruction-stable" instead
   of "no address").

Codex round-4 (same thread, 2026-09-18, verdict **NEEDS CHANGES** — all
items folded into the body above):

1. [resolved] The round-3 deviation confirmed correct with a full
   consumer walk: same-page D11 pushes must NOT set
   `frame_motion_taken` (push-before-rows keeps `ledger[0].id ==
   ct.id`; rows-before-push leaves next-row-owner untouched; no hidden
   cumulative work — `rbx` only advances at loop back-edges; `.yielded`
   cuts and budget declines both stay legal).
2. [blocker] Seed-stability was page-local but images must survive
   writers on every frame-linked page visited within an episode (page
   B ustores/global-stores between page A's warm entries). → VM-global
   `seed_epoch` bumped inline at every native-emitted
   `ustore`/`hstore` site; images stamp it at fill, warm entries cmp
   it. Conservative (any hstore bumps — a global store IS an hstore to
   the globals table); table-writing recursion self-excludes from warm
   entries only; known-not-globals emit-time refinement deferred.
3. [should-fix] Touched-slot protocol lacked per-episode counter
   reset. → Order-pinned first-hit sequence: capacity check → count=0
   → publish slot → publish gen → count the hit.
4. [should-fix] `frame_motion_taken` guard scope narrowed by a
   "frame-motion-capable page" qualifier that would let a reachable
   page's arm poison the grammar. → Every non-frame armed site on
   every page tests the flag.
5. [nit] Summary/measurement drift fixed (P2 Outstanding bullet;
   "no new ROW kinds"; `nativeSelfCallPush` leaves the HEAD-page
   profile at P0, fully at P2).

Codex round-5 (same thread, 2026-09-18, verdict **NEEDS CHANGES**, two
wording-level items — folded):

1. [should-fix] `seed_epoch` overflow contract pinned: reset to 0 at
   episode entry right after the `episode_gen` bump; within-episode
   store count bounded by budget × page store sites « 2⁶⁴ so wrap is
   unreachable (cross-episode staleness is the generation's job).
2. [should-fix] Two Soundness sentences still made the page-local
   no-writer claim the epoch amendment disproved → both now cite the
   epoch comparison as the cross-page mechanism.

Also verified in round-5: all native `hstore`/`ustore` emission paths
(body + linked-loop-done snapshot stores) are covered by "every emitted
site"; `.upvalue_cell` bakes the cell address, not contents; the
touched-counter order and universal non-frame guard close their
findings.

Codex round-6 (same thread, 2026-09-18, verdict **NEEDS CHANGES**, one
blocker + one nit — folded):

1. [blocker] The wrap-unreachable "budget × store sites" bound was
   invalid — a native loop executes stores per iteration without
   consuming transitions, so no static bound exists. → Fail-closed
   saturation: store sites saturate at `maxInt`; a fill observing
   `maxInt` never publishes its stamp (page stays cold for the
   episode); no stamp can equal `maxInt`, so a saturated epoch fails
   every warm compare — poison by construction.
2. [nit] The `.global` admission bullet still carried the page-local
   no-writer claim → now cites all three fences (page predicate /
   epoch / generation).

Codex round-7 (same thread, 2026-09-18): both round-6 resolutions
confirmed (saturation sound — next-episode reset cannot revive stale
images because their generation no longer matches; `.global` fences
complete); no remaining inconsistencies; the budget constant correctly
classified as tuning, not soundness. **Final verdict: APPROVED.**

## References

- Doc 44 (call anchors + return tracing; D11 push, D12c pop/links, the
  blackout paragraph, Phase 4 mandate "done when the seam is off the
  fib profile" — this doc IS Phase 4's completion, superseding its
  callout-based form).
- Doc 17 (exit patching, ledger grammar, forced yield), doc 22 (seeding
  twins, §B.4 prologue invariant), doc 31 (receipts/gates), doc 45
  (native allocation/GC), doc 52 (silent-promotion evidence — the
  neighboring mechanism this doc deliberately does NOT extend, per the
  straight-to-C directive).
- `~/Projects/LuaJIT/src/lj_record.c` — `check_call_unroll` (up-recursion
  stop, :1868-1888), the return-to-lower-frame `IR_RETF` guard
  (:997-1010), `check_downrec_unroll` (:897).
- `src/interp.zig` `nativeSelfCallPush`/`nativeSelfRetPop` (the
  contracts being inlined), `pushFrameVararg`, `prepareNativeEpisode`;
  `src/nativegen.zig` terminal lowering (~:2067-2251), seed prologue
  (~:754); `src/nativegen_emit.zig` `emitLedgerAppend` /
  `emitForcedYieldCheck`; `src/trace_link.zig:843` (the frame-motion
  silent-promotion exclusion this doc routes around).
