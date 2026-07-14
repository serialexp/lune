# CURRENT_TASK — Exit-branch patching (faithful LuaJIT port), doc 17

## Status 2026-07-14 (LATEST) — 2c-E (#63): E1 LANDED (d4d82d9); E2 spec finalized (codex-approved), implementation next

**Where we are.** 2c-E splits into E1/E2/E3 per two codex `gpt-5.6-sol` rulings (thread
`019f5f48-98ba-73b3-90c8-89ded74aae92`; the rulings are in the session transcript
`~/.claude/projects/-home-bart-Projects-lune/9a281686-...jsonl` lines 21264 + 21272, already
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
`CURRENT_TASK_E3.md`, `bench/results/*.tsv`, and similar.
