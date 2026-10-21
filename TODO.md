# TODO

Deferred items noted in passing (Rule #10) so they don't get lost.

## Tier-0 interpreter cost survey (noted 2026-10-20)

Measured at HEAD 1806b9b, ReleaseFast, `perf stat -e instructions:u`,
two-point difference per iteration (exact; per-symbol sampling is not,
because AMD skid misattributes across tail jumps). Against LuaJIT
`-joff`. Probes and scripts are in `bench/opprobe/` (since 2026-10-21;
earlier in `/tmp/t0micro/`).

- [x] **Bug: `next`/`pairs` re-sorts every hash key on every `next`
      call** (`stdlib/base.zig` `sortedHashKeys`), so one traversal of k
      hash keys is O(k² log k). 16,000 string keys took 17.9 s (LuaJIT
      0.00 s); ×4 keys cost ×30 time. Fixed 2026-10-20:
      `HashPart.nextLive` keeps a sorted view of the live keys' identities
      and slots, rebuilt only when a key becomes live and dropped by a
      collection. `bench/stdlib/pairs_hash.lua 2` went from 25.5 s to
      0.02 s; at 2000 reps it runs 0.42 s (LuaJIT 0.04 s). A step is now a
      constant ~670 instructions at any size (LuaJIT `-joff` 54).
- [ ] **`pairs` steps go through the generic native-call path.** Of the
      ~670 instructions per step, ~173 are `opCall`'s native path and ~160
      register moves of the generic-`for` protocol; `next` itself is ~216.
      LuaJIT walks `next` with a dedicated bytecode (`ITERN`, after
      `ISNEXT` checks the iterator is the real `next`) and no call. Belongs
      with the bytecode-forms item below.
- [x] **`for_loop` has no integer fast path.** An empty `for` loop costs
      206 instructions per iteration (LuaJIT 18). Every iteration calls
      `arith.add`, `arith.lt(step, 0)` and `arith.le` out of line, with
      Values spilled through memory, and pushes five callee-saved
      registers. `jfor_loop` shares the same step. Fixed 2026-10-20:
      `Vm.forLoopStep` computes all-int and all-float loops on the raw
      lanes, and the mixed remainder (`forLoopStepMixed`) is out of line.
      Per iteration: empty loop 206 → 72, `s = s + i` 335 → 201, float
      add 343 → 209, a Lua call 917 → 783, an array read 624 → 490. The
      five register pushes stay; they come from the dispatch prologue
      (item below), not the step.
- [x] **The compiler copied every local operand into a temporary.**
      `s = s + i` was `move t1, s; move t2, i; add t3, t1, t2; move s, t3`,
      ~25 instructions per `move`. Found 2026-10-20 while profiling `t.x`
      (most of its "load" cost was moves). Fixed: operands, `if`/`while`
      conditions, field/index objects and keys are read from the local's
      register in place (Lua's `exp2anyreg`), `x = e` compiles `e` into `x`
      when `e` writes its destination last, and `s += i` is one `add`.
      An operand evaluated before code that could write it (a call, an
      `__index`, anything not `isInert`) is still copied first, so results
      are unchanged; `compiler.zig` tests pin both. Instruction counts over
      every `@bench` program (HEAD vs HEAD + the change): tier-0 −1% to −27%
      (scimark-fft −26.6%, nsieve-bit-fp −19.8%, pi_leibniz −19.7%, nbody
      −17.7%), JIT 0 to −12.8% (nsieve-bit-fp −12.8%, euler14-bit −10.7%),
      compile_multret_chain +0.01%.
- [x] **An int-index `for` with a float limit takes the generic step.**
      `for i = 1, n / 2` has a float `R[a+1]`, so it missed both raw lanes
      of `forLoopStep`. Fixed 2026-10-21 in tier-0 alone, without
      converting the limit at `for_prep`: each raw lane also takes the
      other number type as its limit and compares it exactly with
      `value.compareNumeric`, so no other tier changes. nsieve (whose
      limit is float) went from +9% to −40.6% tier-0 instructions.
- [x] **Bug: a trace baked in its `for` loop's direction without guarding
      the step's sign** (found 2026-10-21). `recForLoop`,
      `recForPrepLink` and the peel-rewind re-close picked
      `le(next, limit)` or `le(limit, next)` from the observed step and
      guarded only its type. So a trace recorded on `run(2000, 1, -1)` ran
      a later `run(1, 3, 1)` with the descending test, and under `--trace`
      and `--jit-native` that call never ended; nested loops printed wrong
      totals. Fixed 2026-10-21 the LuaJIT way (`rec_for_check`): a
      non-constant step gets `guard_step_up` (`0 < step`, Lua 5.4's
      rule, so a NaN step counts down) or `guard_step_down` (wire ordinals
      97–98). These are new ops rather than
      `lt` + `guard_true`/`guard_false`, because every loop-test
      classifier reads a truthiness guard sourced at the anchor's
      `for_loop` as the loop test, whose exit resumes after the loop. They
      are `.cvt`-kind in `tropt`, so LICM hoists them to once per entry.
      They are lowered in tier-1a and native (int `cmp 0`; float
      `ucomisd 0, step`) and listed in `viz/src/enums.ts`. Tests: three
      `numeric for:` semantics tests (ten legs each) and a native-vs-tier-1a
      op test over ints, ±0.0, NaN and ±inf, all mutation-checked.
      `recForPrepLink`'s own guard is not pinned by any test: removing only
      that one changes no output found so far. Cost over every `@bench`
      program: tier-0 0%, JIT 0 to +0.57% instructions (scimark-sparse
      +0.57%, nsieve-bit-fp +0.55%, scimark-fft +0.55%, sieve_int +0.53%,
      nsieve +0.47%).
- [ ] **Continuation traces re-check a `for` step every run.** Most of the
      step guard's +0.5% JIT cost (above) comes from one-shot traces
      (`link -> N (iteration)` continuations) that cross an enclosing
      `for_loop`. They have no preheader, so the guard runs on every
      execution. LuaJIT pays the same `rec_for_check` in its side traces,
      but a side trace inherits constants from its parent's snapshot, so the
      step is usually a constant there and needs no guard. Mahina's
      continuations read the step as a `slot_load`. The lever is
      parent-constant inheritance for continuation inputs (or an entry-time
      pin, like doc 57's prologue-checked value pins).
- [x] **A zero `for` step looped forever instead of raising** (noted
      2026-10-21). `for i = 1, 3, 0` and `for i = 1, 3, 0.0` never ended;
      Lua 5.4's `forprep` raises `'for' step is zero`. Fixed 2026-10-21:
      tier-0 `for_prep` raises the new catchable `Error.ForStepZero` for
      int `0` and `±0.0` (`arith.forStepIsZero`; NaN is not zero), and
      `recForPrepLink` aborts on it. A `for` type error now names the
      control value, as Lua 5.4 does (`'for' limit must be a number`),
      where it used to print a bare `TypeError`. Tests: three `for:`
      semantics tests (ten legs each), one of them a hot loop whose inner
      step turns zero.
- [x] **`next` returns no values at the end of a traversal** (noted
      2026-10-20). `select("#", next({}))` is 0; Lua 5.4 returns one `nil`
      (1). Decided 2026-10-21 (Bart): deliberate, keep it. A generic `for`
      reads a missing result as nil.
- [x] **Bug: an integer `for` that reaches `math.maxinteger` /
      `math.mininteger` never ends.** `for i = math.maxinteger - 1,
      math.maxinteger do … end` wrapped `idx` to `mininteger` and kept
      going (Lua 5.4: 2 iterations). Same in tier-0, `--trace` and
      `--jit-native`. Fixed 2026-10-21 in Lua 5.4's `forprep` shape:
      `for_prep` no longer pre-subtracts the step. It validates, raises on
      a zero step, takes the first index as `init` itself
      (`arith.forFirstIndex`), runs the first trip test, and enters the
      header with `R[a]`/`R[a+3]` published. The int lane of
      `forLoopStep` then stops when `idx + step` overflows. Traces guard
      that with the new op `guard_for_nov` (wire ordinal 99; LICM hoists
      it when the limit is invariant), lowered in tier-1a and native.
      Moving the first trip into `for_prep` broke two link paths, both
      fixed in the same change. First, a `for_prep` whose loop is patched
      to `.jfor_loop` now takes that patched entry, as LuaJIT patches FORI
      to JFORI (`TraceState.for_prep_patched` counts it; euler14-bit had
      recorded a duplicate sibling and thrashed, +65%). Second, the
      `for_prep` first-trip test is a `.for_entry` guard, an attachable
      exit: an exit-side child records at the `for_prep`, and
      `recForPrepLink` records through a header with no root only when
      the recording starts at that `for_prep` (scimark-fft's region had
      split, +33%). The exit adapter also copies an invariant slot's raw
      value into another slot now (nsieve-bit-fp's `refused: kind`).
      Board, instructions vs HEAD: scimark-fft −1.4%, euler14-bit −1.6%,
      scimark-lu +0.1%, every other row flat. Tests: two `for:` semantics
      tests (the integer edge, and `init` as the first value with a NaN
      step counting down), a native-vs-tier-1a `guard_for_nov` op test,
      a patched-entry test, the fft region test (five members) and an
      LU test that no continuation records into a rootless loop. All
      mutation-checked.
- [ ] **A continuation cannot record through a rootless loop's
      `for_prep`.** `recForPrepLink` aborts a recording that reaches a
      `for_prep` whose header has no root unless the recording started at
      that `for_prep`. Allowing it everywhere made scimark-lu +13% (noted
      2026-10-21). The continuation after `lu_factor`'s scaling loop then
      recorded into the elimination nest, which entered the inner
      `for k` ↔ `for i` cycle from outside, and silent promotion of that
      cycle collapsed. The general fix is region-prefix support: a region
      admits a straight-line prefix trace that enters the cycle at one
      member without counting it as an outside entry. The test
      `for_prep: a continuation that reaches a rootless loop's for_prep
      ends there` pins today's behaviour and flips when that lands.
- [x] **Compare, `eq` and `mod`/`idiv` had no fast path.** Every `<` went
      through `compareMeta`, every `==` through `valuesEqual`, and `%`/`//`
      through `opArithMeta`, all out of line. Fixed 2026-10-21 in tier-0:
      `opCompare` decides two ints or two floats on the raw lanes (`gt`/`ge`
      swap operands); `opEqNe` decides same-tag numbers, nil, booleans and
      heap identity, and false for any non-number tag mix; `opModIdiv`
      handles two ints with a nonzero divisor (`y == -1` special-cased, so
      `mininteger // -1` wraps the way `arith` does). Everything else, plus
      two floats for `%`/`//` (through `fmath`), goes to the slow half via
      `slowTail`: mixed pairs, strings, two distinct tables (`__eq`),
      metamethods, zero divisors. Marginal instructions over the `s = s + i` loop
      (before → after, LuaJIT `-joff` in brackets): `<`/`<=` 117 → 39 (32),
      `==` 127 → 43 (38), `~=` 128 → 44 (33), float `<` 210 → 118 (63),
      string `==` 205 → 124 (67), int `%` 110 → 83 (39), `//` 103 → 78,
      float `%` 164 → 153 (52), `if i < 0` 178 → 98 (32). Over every `@bench`
      program: tier-0 0 to −16.7% (nsieve-bit-fp −16.7%, while_shortcircuit
      −10.8%, pi_leibniz −10.1%, array3d −9.8%, recursive-fib −8.9%), JIT 0
      to −5.6% (lua54 −5.6%, euler14-bit −2.2%, nsieve-bit-fp −2.1%), no
      row above +0.00%. Tests: three "fast paths: every operand mix" semantics
      tests (ten legs each), mutation-checked on the table-identity, strict,
      `y == -1` and float-lane branches. Strings are interned, so string
      `==` is decided by id on the fast lane; the float-`<`, string-`==` and
      float-`%` probes read their operands from upvalues, so most of what
      remains there is the upvalue loads. Float `%` also pays for `slowTail`
      and the out-of-line `fmath` call.
- [ ] **No constant-operand or fused forms in the bytecode.** `t.x` is
      `load_const` + `get_index`; `i - 7` is `load_int` + `sub`; `if a < b`
      is `lt` into a register + `jmp_if_false`. Each extra op pays the
      ~18-instruction dispatch prologue plus a register round trip.
      Marginal costs (mahina vs LuaJIT): `<` 171/32, `==` 181/38,
      `- k` 100/15, `if a < b` 205/32. Design: doc 66
      (`docs/design/66-bytecode-forms.md`, draft 2026-10-21). After items
      1–3 the gap is mostly op count: one op is a ~25-instruction floor,
      and a `pairs` step is 459 against LuaJIT's 17. Q1–Q5 are open for
      Bart.
- [x] **Constant-key field access has no per-site hint.** `t.x` read
      272/42, `t.x = v` 328/45, a method call `o:get()` ~1250 total.
      Globals already have doc 62's slot hints and are at parity (32/30).
      Fixed 2026-10-20 without hints: `get_index` / `set_index` probe a
      heap key inline (`HashPart.liveHeapNode`, call-free linear probe),
      reads walk `__index` chains of plain tables inline
      (`Vm.heapKeyChainGet`), a live key's store overwrites in place, and
      everything else leaves through `slowTail`. That covers dynamic keys
      (`t[k]`, table keys) too, and nothing ping-pongs between tables of
      different layouts. Marginal instructions over the `s = s + i` loop
      (`bench/opprobe/fields.lua`; LuaJIT `-joff` in brackets): `t.x` 233 →
      126 (29), `t.x = v` 262 → 125 (32), method lookup through `__index`
      427 → 210 (203), method call 925 → 708 (284); the first column is
      after the in-place-operand compiler change. The rest of `t.x` is the
      `load_const` of the key (constant-operand forms, below) and five
      register pushes from handler register pressure.
- [ ] **Lua call + return.** 0-arg call 461/63, 1-arg 611/74. The callee
      window is filled by a generic per-register loop, then
      `pushFrameVararg`, `reloadTopFrame` and `onCallEntry`.
- [ ] **Dispatch prologue, ~18 instructions per op** (doc 42 §4.2): GC
      check (two dependent loads), `safepoint_seq` bump, region count
      test, `frame.pc` store, fetch, jump. LuaJIT's is ~5. Each step is
      part of the determinism contract, so changing one needs a design
      argument.
- [ ] **`#t` on a table is ~177 instructions** (string `#` ~48): the
      `__len` metatable probe plus `Table.length`'s border scan.

## nsieve-bit-fp, the board's worst row (noted 2026-10-19)

18.6× LuaJIT on the 1b60a01 board, and JIT (394 ms) slower than tier-0
(371 ms). `--jit-stats`: native 26.5% of cycles, steering seam 35%
(251k ledger walks at ~2k cycles each); perf puts the seam (replay,
`accountRegionProfit`, region observers, trampoline) at ~65% of cycles.
Seam share elsewhere: fft 21%, nsieve 16%, sparse 14%, lu 11%.

- [x] **A wanted exit never bound to a continuation whose `.link` was
      silent.** `driveSeedSilentResult` dropped `linked_trace`, so the
      exit gave up after `hotexit + tryside` firings and deopted coarsely
      for the rest of the run (t2 exit 31: 98k burst ends). Fixed
      2026-10-19 (test "doc 56 Phase 3: a wanted exit binds to a
      continuation whose .link runs silent"); `397831e`. Board against
      1b60a01: nsieve-bit-fp 393.9 → 350.9 ms (−10.9%), scimark-fft
      276.6 → 219.9 ms (−20.5%), the rest within noise.
- [ ] **The `while` inside `for k` and the outer `for i` (diagnosed
      2026-10-20 at the board size, `nsieve-bit-fp.lua 6`; design doc 64,
      reviewed round 1, which corrects some details below).** The earlier
      "no looping root" reading was the m=5000 kernel: at board size the
      `while` root exists (t7, anchor 54, after 5 recording aborts). Where
      the time goes (`--jit-stats`): native 27%, seam 37%, tier-0 with a
      trace 21% (almost all anchor 23, the outer `for i`: 532k iterations
      at ~800 c/it against ~280 traced), tier-0 without a trace 5% (the
      `while` header at 54). Four separate causes:
      1. **Region decay gates the `for k` owner** (corrected by doc 64
         §11; the round-0 text blamed the outer `for i`). Region rid=1
         (owner pc 45) closes each time the `for k` loop finishes (tier-0
         departure at pc 88). For primes above m/8 the loop has fewer than
         `min_useful` (8) steps, so the close strikes; 5,801 of the 5,808
         `region_decay` gates are on pc 45, each also running
         `disarmAllLinks`. Short is not low-yield here. LuaJIT has no such
         gate. Candidate fix "1e" (a close at the owner loop's own exit is
         neutral) is for doc 64 step 4. **2026-10-21: step 2 removed these
         gates (5,801 → 3, doc 64 §12)**; the strikes came from activations
         that had lost t7's `while` arm. After the two late give-ups below,
         the turnstile returns as 22,015 `legacy_thrash` gates on pc 45.
         **After step 3 (doc 64 §13, pcs shifted by 69fec42: header now
         36)** the gates are split 10,890 `region_decay` / 10,540
         `legacy_thrash`, all in the third `nsieve` call, after t7 e10's
         give-up (item 2). Step 4 decides between 1e and 2c.
         **Fixed 2026-10-21 (doc 64 step 4, 1e, §14):** a close where
         tier-0 leaves the owner loop in the activation's own frame is a
         `loop_exit`, neutral when short. 0 gates on the `for k` header;
         nsieve-bit-fp −6.98% instructions, nsieve −2.41%.
      2. [x] **A chain that ends at the enclosing loop's own loop-done
         counted as a miss.** Fixed 2026-10-21 (doc 64 step 2, §12):
         chains are classified served / natural stop / misfit, and a
         natural stop is neutral. 5,814 natural stops on the bench;
         instructions −11.70%, cycles −9.8%. t7 e10 still gives up late on
         4 real misfits at t8 e23 (the post-`while` branch flips direction
         when the next `nsieve` call re-initialises the array; a sibling at
         pc 63 would serve it and revive the exit).
      3. [x] **The exit-side chain at a `.loop` marker never tries the root
         at its header.** Fixed 2026-10-21 (doc 64 step 3, §13): the root
         is offered first (`exitSideRootServes`), bound per exit
         (`exit_side_entry`, which the topology reads), and a root commit
         retargets exits armed to composites. t1's exit now stays bound to
         the root. Instructions: nsieve-bit-fp −16.02%, fft −23.67%. t1's `while` exit resumes at pc 53, the
         `.loop` marker whose header is 54 (rule 8 refuses a header as
         `P`). `driveChain` offers only traces anchored at 53, the
         composites t2/t6 (one and two trips, `link -> 45`), never t7,
         though tier-0's entry patch for t7 sits on that marker. Once the
         `while` needs 3+ trips both composites deopt and t1 e15 gives up
         after 4 chains. LuaJIT's side trace links into the inner loop's
         root when it reaches its `BC_LOOP` (`rec_loop_jit`).
      4. **One ledger row per `while` trip.** t6's `while` exit is
         exit-side-armed to t6 itself (resume 53), so a 20-trip `while`
         writes ~20 `.exit_side` rows; bursts reach 23 rows and the seam
         replays each (~7k cycles per walk). **Gone after step 3 (doc 64
         step 6, §16):** repeated rows 390,454 → ~2,100, t6 e10 writes
         2,590 rows. 4c not built.
      5. **The `for k` silent set is re-earned every activation (doc 64
         §16).** 2,448 promotions, 2,447 `region_close` demotions, about
         580 replayed rows per activation; the seam is still 50.9% of the
         run. Parked-proof reuse never fires (`fallback_owner`-only).
         Parking for every armable region was measured: fft −6.43%
         instructions, nsieve-bit-fp +35.21%. The gate widening is sound
         (Codex + Antigravity). The regression is discovery starvation:
         the `while` root at pc 40 is never recorded (its sixth
         loop-leave abort is its last try), because the `while` runs on
         t2 → t6 → t6 natively. Options (a), (e)–(g) in §16, waiting on
         Bart.
- [ ] **Measured P6-Q3(b), bursts take exit adapters (experiment,
      reverted 2026-10-19).** The cause of the `for k` root's give-up
      above: inside `driveChain` the native call runs with
      `exit_side_ok = 0`, so t6's own adapter, which loops the `while`
      natively, is skipped and every chain "misses". Flipping both
      burst-origin wrappers (`runCapturingLedger`,
      `runLinkedLoopDoneCapturing`) to `true` is NOT one flag: nsieve-bit-fp
      then dies at line 22 ("arithmetic on a nil value"), so some burst
      consumer mis-resumes an `.exit_side` terminal. The other seam-heavy
      benches kept their output and did not speed up (best of 3,
      `--time`): fft 125 → 147 ms, lu 138 → 138, sparse 108 → 109,
      nsieve 12.4 → 12.0, sieve_int 5.25 → 5.17.
- [x] **Exit-side give-ups are permanent.** `.gave_up` "returns to
      today's routes for good", so a program whose shape changes phase
      (above) keeps the coarse deopt after the phase that defeated it.
      LuaJIT has no such latch on a parent exit; its blacklisting is on
      recording failures. Fixed 2026-10-21 (doc 64 step 2, 2d): a given-up
      exit waits under its resume pc, and the next `.link` continuation
      committed there returns it to `.none`, once per commit. The
      loop-root half (a root at `loopHeaderOf(P)`) landed with step 3.
- [ ] **A chain that hands off to a same-anchor sibling which then links
      is not counted as linked** (`routeExitSide` reads `linked_trace`,
      set only when the entered candidate's own `.link` row heads the
      span). Sound to count it: a coarse deopt of a trace anchored at the
      resume pc leaves the slab coherent there. Not observed on the bench
      or the m=5000 kernel (a prototype changed no counter), so no test
      can pin it yet; revisit if a give-up shows `[A.deopt, B.link]` rows
      with A and B at the same anchor.
- [x] **Per-row replay re-derives static exit facts.** `resumeOf`,
      `isNumericForLoopDoneGuard`, `guardExitPc`/`guardSourcePc` and
      `isOwnLoopTest` decoded IR and provenance for every replayed row
      (~8% of nsieve-bit-fp's cycles inclusive, through `exitResumePc` in
      the `.exit_side` replay arm and `promotedEdgeFromLink`). Done
      2026-10-20: `TraceCode.exit_facts`, one `ExitFacts` per instruction
      (attachable, resume pc, numeric-for loop-done, own loop test) built
      at finalize, replacing the `exit_attach` bitset; `isLoopDoneGuardIndex`
      (a line-for-line copy) now delegates. The four functions are gone from
      the profile. Instructions (`--jit-native`, every @bench program,
      outputs identical): nsieve-bit-fp −4.85%, fft −1.49%, euler14-bit
      −1.27%, spectral-norm −1.08%, array3d −1.03%, none worse. `2752e6c`;
      board (pt-default) against 397831e: nsieve-bit-fp 350.9 → 342.4 ms
      (−2.4%), fft 219.9 → 215.7 (−1.9%), spectral-norm and euler14-bit
      −1.1%, every other row within ±1% except tbl_ops +2.0% (20 ms, its
      instruction count unchanged: noise).
- [ ] **Region accounting is now the seam's biggest slice.** On
      nsieve-bit-fp after the facts table (frame-pointer profile,
      `-Dcli-frame-pointers=true`): `accountRegionProfit` 10.9% self,
      the region trampoline 8.3%, `refreshObserverFast` 4.1%,
      `regionMemberPoint` 2.4%, the `RegionKey` map `get` 1.8%,
      `flushWindow` 1.3%. That is per-receipt region bookkeeping
      (`classifyExit` → `chooseSource` → credit) and the per-instruction
      region observer, not static facts. Diagnose before designing.
- [ ] **`--jit-stats` runs a different machine from the board.**
      Coverage turns entry patching off (doc 20 §R1-9), and on
      nsieve-bit-fp that changes tiering decisions, not just timing: 7
      `region_decay` gates with coverage, 5,808 without; `legacy_thrash`
      5,794 against 11,600. The CLAUDE.md standing rule ("a `--jit-stats`
      run BEFORE any verdict") and the board's `res%` column both read
      the unpatched machine. Options to weigh: attribute coverage on the
      patched path too, or at least print a warning when patches would
      have been installed. Found in doc 64 §11.
- [ ] **A permanently gated anchor keeps paying for each new strike.**
      Once a dispatch gate reaches `max_strikes`, `isGated` holds for
      good, yet every further region-decay strike on that owner still runs
      `gateAnchor`, `condemnProvenanceEdgesAt` and `disarmAllLinks`
      (nsieve-bit-fp: the `for k` gate's strike count reaches 11,597 with
      no reset). Doc 64 step 4 may remove the strikes on this shape; the
      repeated teardown of an already-abandoned owner is a separate
      question. (2026-10-21: step 4's 1e removed them on nsieve-bit-fp;
      the general question stands, and step 5's 1d narrows each teardown.)
- [ ] **fft's bit-reverse records duplicate identical `while` roots**
      (t7/t13/t14/t16 at pc 47, same shape). Predates doc 64 step 3, which
      only picks among them (most hits, lowest id). Find why a root
      already present does not stop the re-recording. Doc 64 §13.
- [ ] **A root commit retargets exits whose types the root refuses.**
      `reviveExitSideAt` disarms every exit armed to a continuation at
      `P` that `exitSideTarget` admits, which is a shape check only. On
      fft, t5 e6 (int `j`) is disarmed, re-routes, is refused by the float
      root and re-arms to its continuation. Bounded by commits. Refinement:
      check the exit snapshot's static types against the root's entry
      guards at commit. Doc 64 §13.
- [ ] **Exit-side give-ups cost euler14-bit ~23% of its instructions.**
      Doc 64 §14 experiment A (`tryside` = 255, so no exit ever gives up):
      euler14-bit −23.47%, nsieve-bit-fp −7.56%, str_manip −3.24%, nsieve
      −2.09%, repack_adversarial +1.24%, outputs identical. Not a fix as
      is: §10's 2c (count only failed recordings and failed child
      prologues, never run outcomes) needs a repair path for stale children
      first. Diagnose euler14-bit's give-ups (which exits, which misfits)
      before designing. Since doc 64 step 5 (1d, §15) nsieve-bit-fp gives up
      nothing (its give-ups followed the global teardowns); euler14-bit's two
      give-ups are unchanged: wanted exits that never got a child, not
      attached exits missing (`miss-giveups=0`).
- [ ] **No unit test for owner election after an exit-side bind change.**
      Doc 64 step 3's per-exit bound entry exists because a topology that
      disagreed with the arm made fft's region non-armable (+47.6%). Only
      the fft A/B covers it. Doc 64 §13.

## Vendor bundle leftovers (noted 2026-10-13)

- [ ] **`mahina-sys`'s zig fallback ignores cargo's `TARGET`.** Without
      `MAHINA_PREBUILT_ROOT`/`MAHINA_LIB_DIR`, `build.rs` runs `zig build lib`
      with no `-Dtarget`. A `cargo build --target <other>` inside lune links
      a host-arch archive and fails at the link. The Rust→zig triple map
      already exists in `tools/mahina-bundle.sh` (`TARGETS`), so the fallback
      could pass the mapped `-Dtarget`. Pre-existing; the bundle path is
      unaffected.
- [x] **`just bundle-smoke` legs that this machine SKIPs** (aarch64 runs,
      Windows, darwin). Covered by `.github/workflows/bundle.yml` on the
      GitHub mirror (2026-10-16): every target builds and runs natively there
      under `--strict`. Locally they stay SKIPs unless qemu-user-static,
      cargo-xwin + wine, or an Apple SDK are installed.
- [ ] **aarch64-windows `SelfInfo` opt-out** (`TargetSelfInfo` in
      `src/jit_unwind.zig`). Drop it once the pinned Zig's
      `std/debug/SelfInfo/Windows.zig` compiles for aarch64. Until then a
      panic there prints unsymbolised addresses. Still broken in the 0.17.0
      release (the file is identical).

## CLI release leftovers (noted 2026-10-16)

- [x] **`viz/bun.lock` is stale; `viz/README.md` still says `bun install`.**
      Done 2026-10-20: `bun.lock` dropped, pnpm only (`packageManager`
      pins pnpm 11.28.6, CI's action-setup reads it), bun stays the
      `pnpm test` runner.
- [x] **This machine has no Node >= 22.13.** Wrong: nvm had 24.13 all
      along, just not on the tool shell's PATH. nvm default is now 24.22.0.
- [x] **A stale global bun 1.2.2 in `~/.local/share/pnpm`** (a pnpm-10
      global; crashes the viz wasm tests). Removed 2026-10-20 with
      `pnpm@10 rm -g bun`; the only buns left are the two 1.4.3s.
- [x] **The CLI has no `--version`.** Done 2026-10-17: build.zig.zon's
      version plus `-Dversion-commit` (the release CLIs pass LUNE_COMMIT).

## Zig std unwinder vs JIT code (noted 2026-10-16, needs Bart)

- [ ] **Upstream report, if wanted (outward-facing, so Bart's call).** A
      stack-trace walk that reaches a PC outside every loaded module (any
      JIT) makes std's ELF `SelfInfo.findModule` rebuild its module list.
      0.17.0 (and Codeberg master) also `@memset`s the unwind cache, so
      every such walk re-parses the binary's `.eh_frame`: 1m44 / 5.6 GB for
      a test that `SafeAllocator`-traces each allocation. dev.813 didn't
      clear the cache, but its traces came back empty for the rest of the
      process after the first such PC. mahina no longer depends on either:
      `src/jit_unwind.zig` answers JIT PCs before std sees them.
- [ ] **`zig fmt` builtin migration (needs Bart: 73-file mechanical
      rename, global Rule #6).** 0.17's `zig fmt` rewrites `@intFromEnum`
      → `@backingInt` and `@enumFromInt(x)` → `@fromBackingInt(@intCast(x))`
      (641 uses in 73 files), so `zig fmt --check src tests` fails on the
      pre-existing tree. Nothing gates on fmt yet and the old builtins still
      compile; new code from the 0.17 switch is fmt-clean.

## Keyframes dereference garbage closures' protos (noted 2026-10-11, needs Bart)

- [ ] **Doc 61 Phase K's whole heap reaches closures whose proto may be
      gone.** Codex review, BLOCKER 3. `toSchemaHeapObject` reads
      `closure.proto.id` for every unswept closure. `Vm.run` documents that
      the main closure's `proto` is only dereferenced during the call, yet
      that closure stays on the heap until the next sweep. A host that runs
      a chunk, frees it and then captures reads freed memory. A garbage
      closure from another host chunk also fails restore (`UnknownProto`),
      or binds to the root tree's proto with the same id (ids are per tree).
      The CLI, the C API (`mh_eval` chunks are VM-owned) and the wasm entry
      keep their chunks alive, so today this needs a Zig embedder. Options:
      (a) the closure stores its proto id at creation, so capture never
      dereferences, and restore binds an unresolvable closure to a detached
      sentinel proto (garbage cannot be called, but a reachable one from an
      unsupported chunk would no longer fail loudly); (b) tighten the
      contract: every chunk run on a VM stays alive while the VM can capture,
      and a keyframe covers one root tree plus loaded chunks, checked at
      capture; (c) capture marks reachability once more, carrying garbage
      closures without their proto. Not chosen; Bart's call.

## Restore drops the PRNG state (noted 2026-10-11)

- [ ] **A keyframe carries no `rng`.** Codex review of doc 61 Phase K. After
      `math.randomseed(7)` and a draw, a cut restores with `rng == null`, so
      the next draw asks for a fresh seed (an effect) instead of continuing
      the seeded stream. That diverges in every mode, not only the
      record-mode resume noted under S-C below. Fix at the keyframe layer:
      carry the generator state (and with it the once-per-session guards),
      with a format bump. Pre-existing.

## Restored closures borrow the original proto's heap constants (noted 2026-10-11)

- [ ] **Constants cross heap boundaries.** Codex review of doc 61 Phase K.
      Restore binds closures to the supplied root tree, whose heap constants
      (interned strings) point into the ORIGINAL VM's heap.
      `gc.markProtoConstants` then marks those foreign headers, not their
      restored twins, so a twin referenced only by a proto constant can be
      swept, and the root tree's constants dangle once the original VM dies.
      Loaded chunks avoid it by recompiling into the restored heap. Options:
      recompile the root too, or rebind the root tree's constants to the
      restored twins by id. Pre-existing.

## Object ids wrap silently at 2³² in release builds (noted 2026-10-11)

- [ ] **`Heap.link` does `next_obj_id += 1` on a `u32`.** A safety build
      panics at 2³² allocations; ReleaseFast wraps, and the next object
      reuses id 0, which collides with live objects (ids key table hashing
      and keyframes). Doc 14 Phase 7's reserved-id scheme claimed an
      assertion that the counter stays below 2³¹; with that scheme gone
      (doc 61 Phase K) nothing guards the counter. Options: a release-mode
      check that raises a fatal error, or a `u64` id (wire format change).
      Pre-existing in spirit: the old bound was also only a debug assertion.

## A guest callback slows the host-calling loop that follows it (noted 2026-10-11)

- [x] **After one host call that runs a long guest loop, the calling loop
      runs more instructions for the rest of the run, and how many more
      varies between identical runs.** Doc 63 Phase 0's `nest` and `nestq`
      shapes (`bench/embed/tracecall_probe.c`) are the same loop except
      that `nest`'s 1,000th host call runs `work(100000)`. With the JIT
      on, ending both runs right after that call, the difference is
      1.60 M instructions (the call). At N = 1,000,000 it is 3.0 M or
      4.2 M: three back-to-back runs of `nest 1000000` gave 795.10 M,
      795.10 M and 796.23 M user instructions, while `nestq 1000000` gave
      792.07 M every time. So something after the callback costs ~1.4–2.6 M
      over the next ~1 M iterations (anchor or gate state left behind by
      the nested trace activity?), and it is bimodal between runs. The
      bimodality matters more than the size: the VM is meant to be
      deterministic, so an instruction count that varies between identical
      runs points at address-dependent behaviour (hashing, allocator
      layout) somewhere on this path. Diagnose with `--jit-stats` and
      `-Djit-debug` on both shapes. It may not be callback-specific: on
      2026-10-11 the JIT-on runs of `bench/luajit/spectral-norm.lua 200`
      and `binary-trees.lua 12` also varied by about ±1% in user
      instructions between identical runs of one binary (e.g. 256.3 M to
      258.6 M), while tier-0 runs were stable to a few hundred.
      **Diagnosed (2026-10-11):** the run-to-run variation is ASLR.
      `setarch -R` makes every count stable, and the count-based
      `--jit-stats` output (trace entries, iterations, arms) is identical
      across runs, so no JIT decision changed in these benchmarks. Three
      runtime structures hash the raw proto address: `AnchorKeyContext`
      (`trace_types.zig`, the hasTrace/gate maps), `hotIndex` (`trace.zig`,
      the direct-mapped hot counter) and `EntryRegistry.code_images`
      (`trace_entry_registry.zig`, wyhash of the pointer, on a hot path).
      An experiment that hashed through `k.proto.id` was reverted: it
      crashes tests whose keys carry `undefined` protos, and it makes every
      map touch require a live proto. No design doc had considered and
      rejected id hashing; the pointer hash was `AutoContext`'s default,
      kept by `hotIndex` (cf4e43c) and `AnchorKeyContext` (dc3340f) under
      the "output identity, not trace-selection identity" contract (doc 17,
      P-EBP). **Fixed (Bart chose the id-in-key form):** `AnchorKey`
      carries `proto_id` (copied at construction, required field, 439
      literals rewritten by a reviewed dry-run script), `AnchorKeyContext`
      and `hotIndex` hash the id, and `code_images` keys on an `ImageKey`
      that stores the id. Equality stays on the pointer. Counts are now
      identical run to run with ASLR on (binary-trees 7,646 M ×3). Cost:
      one `proto.id` load per key construction; an instruction A/B over
      all 30 benches against best-of-3 ASLR layouts of HEAD runs −0.08% to
      +0.53% (euler14-bit; callgrind on an x86_64_v3 build puts it at
      +0.14%, ~1 instruction per probe). **Residue explained (2026-10-11),
      not a callback effect:** `nest` − `nestq` grows ~1.49 instructions
      per iteration after the call (3.10 M at N = 1 M, 4.59 M at 2 M).
      callgrind: both shapes take the gated loop's slow path equally often
      (~15.5 k times, once per `GATE_SKIP` + 1 back-edges), but in `nest`
      each visit costs ~110 more instructions in the hash probes of
      `backEdgeEpilogue`, `onBackEdge` and `afterBackEdge`. `nestq`'s VM
      never holds a trace, so its tiering maps stay empty and hit their
      `count() == 0` early outs; after `work(100000)` is traced they don't.
      That's the normal state of any program with a trace, so `nestq` is
      the unrealistically cheap baseline. The loop is gated only because
      it can't trace a host call yet (doc 63).

## Global-read slow path leaves via a volatile `var` pointer (noted 2026-10-05)

- [x] **`opGetGlobal` (src/interp.zig) tail-calls `GetGlobalSlow(mode).handler`
      through a volatile load of a never-written `var`.** Fixed 2026-10-20:
      a per-mode slow-handler table indexed by `instr.op` (`Vm.slowTail`,
      doc 62 §4.3 follow-up), also used by `get_index` / `set_index`. It keeps LLVM from
      inlining the slow handler, which would make every hint hit save and
      restore five callee-saved registers (global read 73 → 61 instructions).
      `noinline` changes the fn type and breaks `.always_tail`; a volatile
      load of a `const` is folded. Accepted for now (Bart, 2026-10-05); look
      for a less tricky shape (e.g. a slow-handler table the dispatcher
      already owns, or a future Zig attribute) and apply it to other
      handlers with cold slow paths.

## JIT-on callback loop runs ~95 extra instructions per iteration (noted 2026-10-05)

- [ ] **`s = s + host_id(i)` costs ~984 instructions per iteration with the
      JIT on vs ~880 with it off** (AVX2 build, HEAD before the global
      slot-hint work, callback probe `/tmp/cbprobe.c` shape `host`). Host
      natives are recorder-opaque (doc 59 §3.5), so the loop never compiles,
      but something still charges per iteration. Suspect: repeated recording
      attempts/aborts or hotcount bookkeeping on the uncompilable loop. Check
      with `--jit-stats` / `--dump-aborts` before the option-3 (compiled code
      calls host natives directly) design doc.
      **Fixed 2026-10-09:** it was neither host calls nor recording retries
      (6 aborts, then gated). Every back-edge of *any* gated loop reached
      the hot-count skip through the `noinline` back-edge epilogue and the
      full `dispatchTail` (~95 instructions). `gatedBackEdgeHandler`
      (interp.zig) now takes the skip without a call: the callback loop went
      from 758 to 704 instructions per iteration (JIT off: 664); with the
      JIT on, `tbl_ops` −3.1%, `euler14-bit` −1.2%, `nsieve-bit-fp` −1.0%;
      tier-0 is unchanged. The remaining ~40 are the skip's hash (~20) and
      the slow path every 64th back-edge (~14), which the blacklisting item
      below would remove.

## Blacklist gated loops by patching their back-edge (noted 2026-10-09)

- [ ] **Design doc first: LuaJIT-style blacklisting** (`blacklist_pc`,
      `lj_trace.c:380`: after `PENALTY_MAX`, `FORL` becomes `IFORL`, which
      never counts again). For mahina: when a gated anchor's backoff is
      exhausted, patch its back-edge instruction to a variant that never
      enters the JIT path. The doc 42 patched-arm machinery already exists.
      Questions for the doc:
      - The patch must be recorded so replay and keyframes reproduce it
        (Bart, 2026-10-09: "we can record a patch").
      - Today gates retry forever with exponential backoff; blacklisting
        makes it permanent until a flush.
      - A patched loop stops advancing `tick`, which other gates' cooldowns
        are measured in.
      - Removes the last ~40 instructions per gated back-edge.

## Repeated `load` grows memory without bound (noted 2026-10-09)

- [ ] **`bench/compile_multret_chain.lua` peaks at 31 MB with 20 loads and
      530 MB with 400 loads** of the same 2000-deep chunk (ReleaseFast). Each
      chunk is garbage after its one call, so its proto (code, liveness
      table, dominator data) appears never to be freed. Check whether
      `load`ed protos are deliberately immortal (trace caches can outlive
      proto reachability, doc 03) or just never released. A long-running
      host that `load`s generated code would leak either way.

## Armed composite bridge may skip the carried-home flush (noted 2026-10-09)

- [x] **Fixed 2026-10-09.** Confirmed by the test "an armed bridge out of a
      `.loop` source commits the carried homes its local iterations advanced"
      (`trace_promotion_test.zig`): before the fix it read acc 100, not 104.
      `emitCompositeBridgeSnapshot` now runs `emitCarriedHomesFlush` (skipping
      E's slots) before E. The ordinary and silent deopt flushes share the
      same helper. Codex approved it (Phase 0 thread, follow-up). No natural
      Lua repro was found: today's recorder links a continuation into the
      outer header's trace, so bridge sources close with `.link`. The
      original note follows.
- [x] **Verify or refute: the armed native bridge stub flushes only its
      emitted set E, then jumps to the successor** (`nativegen.zig:2641-2650`).
      It never reaches `deopt_exit`, where carried homes are flushed
      (`nativegen.zig:2771-2783`). A carried slot updated after the guard is
      in neither E nor the exit snapshot, so `bridgeMatchesExitSnapshot`
      never checks it. The comment at `trace_code.zig:775` ("which the
      carried flush already leaves in place") assumes a flush that doesn't run
      on this path. Found by doc 61's Phase 0 audit (§2); **codex's Phase 0
      review calls it a real admitted hole** (`docs/reviews/doc61/codex-phase0.md`
      blocker 1): a `.loop`-closed source rotates its carried homes, so a
      slot updated after the guard is stale in the slab at the bridge, and
      the region check (`trace_region_topology_build.zig:352`) labels a
      required non-E slot "invariant" without proving it coherent. `.link`
      sources keep immutable entry homes (`nativegen_alloc.zig:439`), which
      makes them safe. Repro attempt `/tmp/bridge_carried2.lua` (the A-viii
      sieve plus `acc = acc + i` after the `if`) gives the right answer
      because its bridge source (trace 2, `main:43`) closes with
      `link_terminal`. **Next:** build a repro whose armed bridge source is
      `.loop`-closed and runs local iterations before the bridge fires. Then
      flush the carried homes before overlaying E (the exit adapter's order:
      sunk stores, carried homes, snapshot), or refuse such sources, and pin
      it with a test. Queued right after doc 61 Phase 0 lands.

## Keyframe cut before a sweep loses an intern hit on restore (noted 2026-10-10)

- [x] **Fixed by doc 61 Phase K (2026-10-11):** a keyframe now carries the
      whole unswept heap plus `next_gc` (option (a), widened to every object).
      Repro: `keyframeser_resume_test`, "keyframe cut before a sweep", swept
      over every cut. A sibling found on the way, also fixed there: a cut
      while a grid was live restored nested rows, so the later genuine
      deflation's allocations never happened (keyframes now carry the
      physical array part).
      **Original note (codex, doc 61 Phase Q rev 1 blocker
      5).** A string can be unreachable but not yet swept, and
      `internedLookup` still finds it (`gc.zig:567`). `encodeSnapshot`
      (`keyframeser.zig:322`) serializes only reachable objects. So a cut in
      that window, followed by a re-intern, gets a hit in the uninterrupted
      run but allocates a new id after restore (`next_obj_id` is preserved,
      `:636`). Options:
      - (a) serialize the intern table's unswept strings too. GC timing is
        tier-identical, so the bytes stay mode-invariant;
      - (b) collect at every capture, in record and in normal runs alike.
        This changes GC timing whenever capture is on;
      - (c) make interning never hit a white string. That needs a mark-state
        query between collections, so it is likely infeasible.

      Needs a repro test first, then a decision from Bart.

## Keyframe capture serialises dead slots the JIT left stale (noted 2026-10-11)

- [x] **Decided (Bart, 2026-10-11): (a′) a tombstone.** Implemented as doc
      61 Phase K (§9a); pinned by `keyframeser_replay_test`, "a register the
      dead-φ filter left stale". Capture writes a
      dedicated "dead" marker for each dead slot (a new value tag in the
      keyframe schema); restore turns it back into nil, so it never enters
      a running VM. Keyframes are then byte-identical across tiers, and a
      keyframe tells a blanked slot from a genuine nil. The visualiser reads
      its dead labels from the marker, and `ReplayResult.live` (Phase V)
      is removed.
      **Background (doc 61 Phase 1, §2 "Phase 0 audit"; codex Phase 1
      review should-fix).** Masking scrubs dead slots only at collections.
      Mid-execution capture (`keyframeser.zig:341`) serialises every
      register of every window, and the `.snapshot` root walk roots them
      all. A dead slot that sites 3–5 left stale on a JIT run therefore
      differs from tier-0's in capture bytes and in the reachable set, until
      the next collection scrubs it. Options:
      - (a) capture masks dead slots with the same rows the collector uses:
        serialise nil for them and do not root them. Keyframe bytes are then
        identical across tiers. Same `frameMask`, so no new analysis;
      - (b) declare that keyframe byte identity across tiers was never
        claimed, and leave capture as it is.

## Region graph rebuild R(T) is superlinear in traces and exits (noted 2026-10-10)

- [x] **Fixed 2026-10-10.** The registry now keeps a per-anchor index
      (`TraceRegistry.by_anchor`: an intrusive cache-order list per anchor,
      with its trace count and inner-root count), so `countTracesAt`,
      `hasInnerRootAt` and every per-anchor lookup (`findTrace`,
      `findLoopTrace`, `findLinkTrace`, `nextTraceExcluding`,
      `resolveLoopDoneCont`, `resolveRegionBridgeChild`) cost O(traces at
      that anchor), not O(cache). The topology view is indexed (id → record,
      inner-root anchors), `buildEdges` pairs exits by position, and `build`
      works per component on CSR node/edge lists, with an O(1) owner test,
      a dominance envelope for the fallback tie-break and a BFS sibling
      closure. Results: `bench-retire` R(T) at N=4000 went from 92 ms to
      3.0 ms, and retiring 10% of it from 45.8 ms to 1.25 ms.
      `bench-topology` now scales n log n up to k=2048 (2.97 ms). Tests
      install records through `TraceRegistry.attach`/`detach`/`detachAll`,
      never by writing `registry.cache` directly.

      The original finding: every trace commit (`trace.zig:4028`) runs
      `rebuildEdgeCache` plus `rebuildRegions`. Codex's doc 61 Phase Q rev 2 review found
      superlinear work inside:
      - `topologyView` → `hasInnerRootAt`, a cache scan per trace
        (`trace_link.zig:832`);
      - successor resolution scans (`:889`);
      - the topology view's linear `traceById` (`trace_region_topology.zig:37`);
      - `buildEdges`' pairwise exit-fact match (`:59`);
      - per-component edge rescans and liveness propagation
        (`trace_region_topology_build.zig:213`, `:297`);
      - the sibling closure (`:755`).

      Fix with indexed trace/anchor lookup, direct exit-fact matching and
      component-local adjacency. Measure with `zig build bench-topology` and
      Phase Q's retirement benchmark, which reports R(T) on its own.

      Measured with `zig build bench-retire` (2026-10-10, load average about
      16, so absolute numbers are noisy): on one closed cycle of N/2 linked
      roots, R(T) took 0.25 ms at N=250, 4.0 ms at N=1000 and 85 ms at
      N=4000. That is roughly quadratic. A Phase Q batch pays exactly one
      R(T): retiring 10% of N=4000 costs 41 ms, against 18.6 s for the old
      per-trace removal. So R(T) is now the whole retirement cost.

## Every commit still pays a whole-graph rebuild (noted 2026-10-10)

- [ ] R(T) is now near-linear, but each commit (and each retirement batch)
      still rebuilds the edge cache and every region from scratch. That is
      O(T) per commit, so O(T²) over a run that commits T traces: about
      3 ms per commit at T=4000. Most commits touch one anchor's
      neighbourhood. An incremental rebuild (re-derive only the components
      reachable from the changed anchors) would make a commit
      O(neighbourhood). It has to keep the transactional, fail-closed
      publish and the replay-stable id assignment. Profile a large real
      program before designing it.

## Native bookkeeping found by bench-retire's native table (noted 2026-10-10)

- [ ] **Arming a link scans every armed link.** `publishValidatedLink`
      (`trace_native_registry.zig`) finds the existing (parent, physical
      slot) record with a linear walk over `armed_links`. So each arm is
      O(L) and arming L links is O(L²): 15% of the bench's setup at
      N=16000. The same walk appears at about 20 consumers (`trace.zig`
      `hasArmedFrameLink`, `armedEdgeInBridgeFreeCycle`, `trace_link.zig`,
      `trace_regionops.zig`, `trace_chain.zig`, `memoizeBridgeEdge`). Almost
      all of them filter by `parent`.

      Scale today: peak simultaneous arms across the LuaJIT bench set is
      13 (nsieve-bit-fp), and arms are compile-time events, so this is not
      hot yet. The general fix is a per-parent index: each trace's armed
      links (bounded by its exits), kept in step by every append,
      swap-remove, compaction and reset. Consumers that look up by parent
      then cost O(that trace's links). Do it before programs with
      thousands of live links exist.
- [ ] **Retirement time per trace grows with heap size.** The batch's work
      and instructions are linear (≈1.2k instructions per retired native
      trace at both N=4000 and N=16000). Its time per trace still rises,
      from ≈225 ns to ≈520 ns, because dTLB misses grow ×9 per ×4 N. A
      trace is a dozen separate heap allocations: the record, the IR,
      compiled state, slots, exit tables and so on. Carving them from one
      per-trace block (or a size-classed trace arena) would put them on one
      or two pages. Measure with `zig build bench-retire` before and after.
- [ ] **`McodeArena.alloc` reuses with a first-fit walk of the free list.**
      It is O(free slots) per compile, and adjacent freed slots never
      coalesce. After a large retirement, every compile walks the whole
      list. LuaJIT's `lj_mcode` uses areas plus a trace-ordered bump. Use a
      size-bucketed free list, or coalesce on free.
- [ ] **`resolvePatchPc` scans the whole proto** for a loop anchor's back
      edge, once per trace (the result is cached on the trace). That is
      O(function length) per installed patch. It only shows up in
      bench-retire's single giant proto (65% of setup), but the recorder
      already knows the back-edge pc and could hand it over.

## viz tests crash under bun 1.3.0 (noted 2026-10-10)

- [x] **Fixed 2026-10-20 by upgrading:** `/usr/local/bin/bun` and
      `~/.bun/bin/bun` are both 1.4.3 now, and `pnpm test` passes 72/72.
      `bun test` in `viz/` segfaults loading the wasm module under bun
      1.3.0 (the `bun` on PATH). `~/.bun/bin/bun` 1.3.14 passes all 70.
      Either pin the bun version (`packageManager`/engines, or the justfile
      recipe calls `~/.bun/bin/bun`) or upgrade the system bun.
      **Diagnosed 2026-10-11:** a JSC wasm-JIT bug, not ours. A plain
      4000-iteration array append in the wasm VM is enough (it crashes
      once JSC tiers the code up, not at load). Node 24 (V8) runs the same
      `mahina.wasm` cleanly. Bun 1.3.0 passes with `BUN_JSC_useOMGJIT=0` or
      `BUN_JSC_useBBQJIT=0`, and Bun 1.4.3 passes the whole suite (72/72).

## `releaseChunk` leaves traces over released protos (noted 2026-10-10)

- [ ] `releaseChunk` (`interp.zig:871`) only drops the proto from
      `retained_chunks`. Cached traces keep raw `anchor.proto` pointers, and
      `.global` seeds read `proto.constants` at entry, until the next epoch
      clears the cache. There is no production caller of `retainChunk`
      today. Fix with doc 61 Phase Q's `removeTraces`, retiring every trace
      anchored in the released proto tree.

## `{f()}` keeps only the first result (noted 2026-10-09)

- [ ] **A call as the last item of a table constructor is truncated to
      one value.** `local function f() return 1,2,3 end print(#{f()})`
      prints 1 (Lua: 3). Doc 27 §7 says the compiler has no
      `all_results` bytecode shape for constructors. Decide whether this
      is intended for mahina or a gap. If it's a gap, add the shape
      (Lua: `SETLIST` with `C=0` after a multret call; `{...}` is the
      same case) along with the recorder/JIT side.

## Precise traces retry a failed string-helper allocation (noted 2026-10-10)

- [x] **Doc 45 D5 says a precise trace never retries an OOM, but string
      helpers do.** `tostr_int`/`tostr_num` (and the other stralloc
      producers) side-exit on a null return without setting
      `runtime_error` (`irinterp.zig:845`). Every precise body op carries
      its boundary snapshot (`trace_recorder.zig:1741`), so the exit is
      `.precise_resume` and tier-0 runs the allocation again. Under a
      one-shot injected OOM the traced run succeeds where tier-0 raises.
      Fix: in precise traces, helper allocation failures set
      `out_of_memory` and exit `.precise_error`, in tier-1a and native,
      with an injected-OOM test per helper. Found by Codex in the doc 63
      round-2 review; doc 63 Prerequisite A.
      **Fixed 2026-10-10.** The allocating shims return a one-word
      `stralloc.StrResult`: the `*GcHeader`, the OOM `Status` ordinal, or
      0 for a decline (out-of-range `string.char`, stale match scratch).
      Precise traces raise the OOM through `.precise_error` in tier-1a and
      native; a decline still resumes. Tests: "pipeline (string helper
      OOM…)" (tostr plus all seven snew/scap helpers, both tiers) and
      "pipeline (string helper decline…)", mutation-checked per tier.

## Ordinary traces retry a transient string-helper OOM (noted 2026-10-10)

- [ ] **Decide whether ordinary (non-precise) traces may retry an OOM.**
      An ordinary trace still side-exits on a string-helper OOM, and
      tier-0 replays the whole iteration, running the allocation again.
      Doc 24 D5 assumes the replay "re-raises the same OOM", which holds
      for a persistent failure (a full heap, a budget allocator) but not
      for a transient one: under a one-shot injected failure the traced
      run survives where tier-0 raised. Doc 45 D5's never-retry rule was
      written for precise traces only. Ordinary traces do carry some
      bytecode-boundary state (doc 56's exit-side materialization rebuilds
      the registers at a resume pc), but only for attachable side-exit
      guards; a helper exit carries no snapshot and its raise has nowhere
      to park. The options: (a) accept the retry (it is invisible unless
      allocation failures are transient); (b) route allocating loops
      through precise recording; (c) extend the helper-error integration
      to ordinary traces — give allocating helpers a boundary snapshot
      and a precise-error-style consumer, at the cost of keeping those
      refs live (and blocking LICM across them) in optimized traces.
      Needs Bart's call.

## Traced host calls: multret arguments and results (deferred 2026-10-10)

- [ ] **Doc 63 v1 records host calls only with a fixed argument count
      and a fixed wanted-result count.** A call with `c == all_results`
      or with arguments fed by a multret producer stays a
      `host_barrier`. Lifting it needs doc 27's multret shapes in
      precise traces (variable window tail, result count as a value).
      Deferred past doc 63 v1 by Bart (Q5).

## Coverage mode changes `tick` (noted 2026-10-09)

- [ ] **`config.coverage` is documented as never affecting tiering, but a
      coverage run ends at a different `trace.tick` than a normal run.** In
      three 3000-iteration `pcall` loops (the gated-back-edge test in
      `interp_dispatch_test.zig`), a coverage run ends at 9019 and a normal
      run at 9012. The gap was already there before the gated-skip handler:
      it is unchanged with the skip disabled. Gate cooldowns are measured in
      `tick`, so a coverage run can gate and retry at different points than
      the run it is meant to describe. Find where the epilogue's coverage
      path counts extra back-edges, and either make it tick-neutral or
      correct the doc comment.

## `capi-smoke` hangs under `zig build test -Doptimize=ReleaseFast` (noted 2026-10-03)

- [x] **`tests/capi_smoke.c` puts every API call inside `assert(...)`** (30
      sites). Zig compiles C with `-DNDEBUG` in release modes, so the calls
      vanish: the `mh_table_iter_next` loop never advances and spins
      forever (found while running doc 60 H1's tests in ReleaseFast; the
      Debug gate never sees it). Fix: a `CHECK(expr)` macro that always
      evaluates, or `-UNDEBUG` on the smoke module in `build.zig:147`.
      **Fixed 2026-10-04:** `#undef NDEBUG` before `<assert.h>` in the
      smoke test; `zig build test -Doptimize=ReleaseFast` now completes.

## `zig build test -Doptimize=ReleaseFast` runs the VM core's tests in Debug (noted 2026-10-04)

- [ ] **`mod_tests` ignore `-Doptimize`.** The `mahina` module
      (`b.addModule("mahina", …)`, `build.zig:48`) sets no `.optimize`, so
      its test compile is always Debug (`--summary all` shows
      `compile test Debug native` under `-Doptimize=ReleaseFast`). Only the
      capi and CLI test binaries follow the flag, so the ~1600 core tests
      have never run in ReleaseFast. Giving `mod` `.optimize = optimize`
      would fix the tests; check first what that changes for the module's
      other importers (the CLI and `capi_mod` set their own root optimize
      mode).

## libmahina.a replaces the host's memset/memcpy with byte loops (noted 2026-10-02)

- [x] **`capi_lib.bundle_compiler_rt = true` (build.zig, doc 59 E3) exports
      Zig compiler-rt's `memset`/`memcpy`/`memmove` from the static lib, and
      the host linker prefers them to glibc's.** Every mem* call in the whole
      host process (a Rust game engine, say) becomes Zig's generic loop:
      `memset` is 8 single-byte stores per iteration. Measured: the Rust
      crate's call cost was 47% `compiler_rt.memset`. A shadow build with
      `stack_check = false` on the lib modules and no compiler-rt bundle (so
      `__zig_probe_stack`, the reason for bundling, is never referenced)
      links clean under cargo and takes a Rust call from 172 to 76 ns.
      Options to choose between: (1) `stack_check = false` with no bundle
      (big frames lose their probes); (2) keep the bundle and
      strip or weaken the mem* symbols from the archive; (3) ship only the
      stack-probe routine. Also check `tests/capi_smoke.c` still links.
      **Done (2026-10-02), option 3:** no bundle; `capi.zig` exports a weak
      `__zig_probe_stack` (the pinned compiler-rt routine) for library
      builds on x86_64, and helpers like `__divti3` come from the host's
      libgcc/compiler_builtins. The archive now has `U memset/memcpy/memmove`.

## Embedding call boundary vs LuaJIT/mlua (noted 2026-10-02)

Measured with call-only probes, JIT off: LuaJIT 304 instructions / 54
cycles per `lua_pcall`, mahina 567 / 119 per `mh_call`; mlua 24–26 ns vs
our Rust crate 172 ns. Store→load forwarding stalls per call: LuaJIT 0,
mahina C API 7.3, Rust crate 26.8. Items, each measured on its own:

- [x] **Rust crate on mlua's model.** No `Function` clone per call (it
      creates and frees a GC ref), no `Vec`s, no 1 KB zeroed results
      buffer; typed argument/result conversion through traits (E9's
      `IntoValue`/`FromValue`) so `f.call::<i64>(x)` touches no heap.
      **Done (2026-10-02):** `IntoArgs`/`FromResults` (scalars, strings,
      `Option`, handles, tuples up to 8, `&[Value]`/`Vec<Value>`), 8 inline
      arg slots, uninit result buffer, handles cache their raw value,
      `#[inline]` on the conversions (out of line, each `Result<mh_value>`
      went through memory and stalled on the reload), results read as two
      words. Typed `i64 -> i64` call: 76 → ~20 ns (575 → 547 instructions,
      ~94 cycles); mlua+LuaJIT is 24–26 ns. The untyped `&[Value] ->
      Vec<Value>` form is ~36 ns (the `Vec` alloc/free).
- [x] **Whole-word value stores at the boundary.** `mh_value` is written
      as a tag byte plus payload and read back as two 8-byte loads, which
      cannot store-forward. Write the tag as a zero-extended 8-byte word.
      **Done (2026-10-02):** `Value.storeWords`/`loadWords`, used by every
      capi out-pointer, the park, and `callValue`'s copy-out. Same session:
      `FrameResult` became `packed struct(u32)` — `opRet` wrote it as two
      `u16` halves and `callValue` read it whole, the largest single stall
      per call (Rust call 123 → 105 cycles).
- [x] **Build calls in place.** Today args are validated, parked, copied
      into the callee window, and results copied out and parked again.
      LuaJIT's host pushes straight into the callee's frame slots.
      **Reframed and done (2026-10-02):** a push API saves nothing here —
      LuaJIT's glue around `lua_pcall` is ~143 instructions, ours ~53 — so
      the work was cheapening the existing path: `runProtected` is `inline`
      (C call 540 → 518 instructions, ~86 → ~82 cycles). Tried and
      reverted: binding/copying through one `RegWindow` (lanes loaded once)
      — LLVM then unrolls the 1-element loops by 4 and it nets +8
      instructions.
- [ ] **Clear the dead stack at GC time instead of nil-filling every
      callee register per call** (LuaJIT `gc_traverse_thread`). Must keep
      keyframes and cross-tier output byte-identical. **Measured
      (2026-10-02), not done:** dropping the nil-fill saves 3 instructions
      per call, cycles within noise. And `keyframeser.zig` serializes every
      register below `stack_top` mid-run, so stale, tier-dependent data
      would land in keyframes unless the serializer clears dead slots
      itself. Needs Bart's call on whether 3 instructions justify that.
- [ ] **One packed fast-path word.** `runFastPath` reads nine scattered
      flags on every entry; keep them as bits in one word. **Measured
      (2026-10-02), not done:** removing the check outright saves 15
      instructions and 2–6 cycles per call (the ceiling). The flags have
      ~31 production write sites (trace.zig, trace_link.zig, interp.zig,
      the recorder's `active`), each of which would have to keep the
      word in sync. Needs Bart's call. **Folded into doc 60 H1
      (2026-10-03):** a `u16` on `TraceState`; the six pending fields
      coexist, so no single union (doc 60 §5.4).
- [ ] **macOS x86-64 host-call entry (doc 60).** The `.S` entry is Linux
      only for now (Bart, 2026-10-03). Prerequisite: `libmahina` itself
      doesn't build for macOS — `mh_vm_new` installs Linux-only clock/entropy
      sources (`capi.zig:414`, `std.os.linux`). Make the C API portable,
      then add the Mach-O macros (symbol prefix, sections,
      `.private_extern`) and a macOS build/link acceptance case.
- [ ] **Windows x64 host-call entry (doc 60).** The `.S` entry targets the
      SysV ABI only; Windows x64 uses its own calling convention and runs
      the Zig H1 path. Write `hostcall_win64.S` (or
      equivalent) only if a Windows embedder's profile asks for it.

## Frame pc conventions: two pre-existing suspects (noted 2026-10-05, doc 61 fact-finding)

- [ ] **`backtraceFrames`/`callSiteAt` (interp.zig ~1719, ~1973) assume every
      parent frame's pc is one past its call.** A frame re-entered through
      `callValue` from inside an instruction (metamethods, `pcall`, `sort`,
      `gsub`, `require`, load, capi) has `frame.pc` = the in-flight
      instruction itself (dispatch prologue step 6), so its reported call
      site is one instruction off. Doc 61 Phase 0's in-flight marker gives
      the fix; land it as its own change.
- [x] **Multret arguments may be unrooted across a call.** Both halves
      CONFIRMED and fixed by doc 61 P1 (overlap) and P2 (unrooted), 2026-10-09.
- [x] **Doc 61 P1 — surplus varargs past the caller window are CLOBBERED**
      (and the non-vararg overlap variant silently summed wrong). Fixed
      2026-10-09: the callee window sits above the argument span, the
      recorder refuses the shape, and keyframe restore accepts gaps.
- [x] **Doc 61 P2 — dynamic argument spans above `stack_top`.** CONFIRMED
      use-after-free from plain Lua (`print` + `__tostring`). Fixed
      2026-10-09: the `.call` native and `__call` arms raise `stack_top` over
      the span.
- [x] **Doc 61 P3 — Zig-held transient values across re-entry.** The audit
      is in doc 61 §3 P3. CONFIRMED use-after-free from plain Lua (the fused
      `a[i][j]` with a native `__index`/`__newindex` such as `table.sort`).
      Fixed 2026-10-09: `callValue`'s native arm parks `args` at `stack_top`.
- [x] **capi host-call bugs from the doc 61 P3 audit** (coral-marten's
      area, reported to them 2026-10-09). The third, `cHostCall` reading
      `h.box` after a callback that freed its own Native, is fixed by P3's
      callee parking.
  - The dispatch `__call` arm and `pcall`/`xpcall` from bytecode hand a host
    fn `args` and `out` slices that alias in `boundary_scratch`, which
    breaks the host no-alias contract (capi.zig:207).
  - The dispatch native arm's host branch fills `boundary_scratch[out_lo..]`.
    A nested `mh_call` from the host can overwrite slots it already filled
    when the result range reaches past `stack_top`, before the copy-down.
  - **Fixed 2026-10-09** (both, one cause). `Vm.callHostNative` gives every
    host call a private range of a VM-owned stack (`host_out`), and the
    caller copies the results out once the host returns. `max_results` is
    now capped at 256 (`max_host_results`), also when the caller wants all
    results. Cost: +13 instructions per host call (727 → 740 per iteration
    of a pure callback loop). Tests in `capi_test.zig`; doc 59 updated.

## `hashgate.py --generate --filter X` wipes every other program's refs (noted 2026-10-01)

- [ ] `write_refs` writes only the observed (filtered) rows, so a filtered
      generate replaces `bench/refs/output-hashes.tsv` with X's rows alone.
      Merge instead: load the existing refs, replace the rows for the
      programs regenerated this run, keep the rest. Workaround for now:
      generate into a scratch `--refs` and add the rows by hand.

## A module field read inside a main-chunk loop aborts recording (noted 2026-09-27)

- [ ] **`math.floor(x)` inside a loop in the MAIN chunk aborts
      `nyi_opcode get_index`** (`/tmp/lowtrip.lua` from doc 58 B0,
      before `floor` was hoisted to a local: 2 anchors, 6 aborts each,
      0% traced, native slower than tier-0). With `local floor =
      math.floor` the same loop traces 99%. LuaJIT records `math.floor`
      through the global table plus an `HREFK`. The bench corpus
      hoists these, so no board row shows it, but real programs don't.
      Find which `get_index` shape the recorder refuses (the global
      `math` table's hash field; doc 49 hrefk?) and close it.

## Doc 57 P3 follow-ups (noted 2026-09-27)

- [ ] **Numeric-`for` step is a register load, not a konst.** `recForLoop`
      reads the step through `refOf(a + 2)` (a `slot_load`), so `idx + step`
      is never affine in the loop index. Seen in P3: an unrolled
      `t[i] = t[i-1] + …` aborts `store_fwd_ambiguity`, because iteration 2's
      `i - 1` cannot be proven equal to iteration 1's `i`. LuaJIT folds a
      constant step (`lj_record.c` `fori_arg` → `find_kinit`, which finds the
      `KSHORT`/`KNUM` that initialized the slot before `FORI`). General gap
      (any trace that indexes with the loop variable after a step), not a
      P3 defect. Test: "doc 57 P3: array stores in both iterations stay
      correct" (parity only today).
- [ ] **P3-D4: a pinned carried slot whose φ always carries its pin** (shape
      B's `true`) re-checks the pin every trip, and the φ rewrites the konst
      home. Once the prologue checked the entry, the body pin cannot fail. A
      tropt fold could move it to the invariant (`pin_only`) class. Shape B
      runs at ~1.75× LuaJIT (200M turns: 67 ms vs 38 ms); measure what this
      buys before building it.
- [ ] **Trace file / visualiser does not know about unrolled trips.**
      `traceser` writes `peeled` (wire v3) but not `instunrolled`, so the viz
      labels an unrolled trip as one iteration. A schema bump (wire v5,
      `schema/trace.json`, regenerated codecs, `TraceView.tsx` label) would
      fix it; display-only.

## Loop-exit writeback could use bytecode liveness instead of the watermark

- [ ] `trace_finalize` drops loop-end writebacks above `locals_watermark`, a
      lexical-scope heuristic. The doc 56 per-proto `Proto.reg_live` table
      gives real liveness at the loop-exit pc and would drop more dead slots
      (and keep none that are live), on every trace. Evaluate after doc 56
      Phase 1 lands.

## Multi-loop trace roots need loop-done ownership

- [ ] Before enabling any recorder path that can put guards from more than one
      numeric loop in a single root trace, replace the current source-opcode-only
      loop-done classifier with an owner-aware contract. The rejected doc 50
      unrolling prototype showed that treating an inner `for_loop` exit as the
      root's linked completion materializes the wrong live locals. Specify the
      ownership representation first and update the synthetic replay fixtures,
      which currently model loop-done by exit source alone.

## JIT coverage labels conflate traced and native execution (D12c baseline)

- [ ] Audit `--jit-stats` native-cycle attribution for tier-1a fallbacks. The
      D12c baseline (06bab1b, recursive-fib 31) reports 6,534,740 trace entries
      but only 4,356,544 native bodies, while labeling all traced cycles as
      native execution. `perf` independently puts 18.27% in `irinterp.executeCtx`
      through `opJCont`. Thus 100% trace residency does not prove native
      continuation residency. Keep formation witnesses separate from coverage
      percentages; correct attribution in a focused diagnostics change.

## Architecture roadmap (2026-09-05, Bart: eventually cover all boundaries)

Start with docs/design/41-jit-ownership.md: shared contracts, registry, region
policy, then recording-session ownership. Remaining review findings are tracked
work, not implemented by that first arc:

- [ ] Canonical IR operand roles/remapping and release-safe boundary validation.
- [ ] Precise native compile declines and fallible assembler finalization; design retry policy separately.
- [ ] Runtime-owned protected invocation/unwinding and loaded-program registration; narrow stdlib capabilities.
- [ ] EffectSession ownership and atomic replay attachment.
- [ ] Runtime snapshot capture/restore separate from codec; non-mutating canonical grid projection.
- [ ] Program-image retention/lifetime API and common CLI/wasm runner.
- [ ] Stable runtime scratch/context ownership distinct from collector mechanism.
- [ ] Visualizer session/artifact ownership, injected execution clients, and stale async result tests (retain Solid stores).
- [ ] Native registry uniqueness and restore identity validation, without assuming backwards compatibility.

## `require` returns 1 value, Lua 5.4 returns 2

Found while smoke-testing the `.mah`/`.lua` split (2026-08-31). Running the same
`.lua` file under both:

    mahina entry.lua  ->  lua-module
    lua5.4 entry.lua  ->  lua-module	./luaonly.lua

Lua 5.4's `require` returns the module **and** the loader data (the resolved
path); mahina returns only the module. `searchPathCore` already computes and
returns the path as `out[1]`, so the value exists — it is `require` that drops
it. Under the extension contract just adopted (`.lua` = a Lua program, must run
under stock Lua too) this is a real 5.4 incompatibility, not a nicety. Not fixed
here to stay focused; it needs a check of whether anything depends on the arity.

## Doc 30 arc observations (noted 2026-08-29, c5)

Four items surfaced while landing pattern/str2num recording; none belongs
to that arc, all recorded here so they aren't lost:

- ~~**Region-window gate vs designed loop-done exits.**~~ **RESOLVED
  2026-08-29 by doc 31** (the mechanism turned out to be the LEGACY
  thrash machine + `abortRecording` gating dispatch, not
  `flushRegionWindow`): the gate split into dispatch vs record maps, and
  `accountLegacyThrash` now clears on ANY productive receipt instead of
  `completed >= min_useful` — the exit-classification idea below was
  reviewed (codex, BLOCKED) and shelved: `sgmatch`'s executors collapse
  all non-OK statuses into one exit_instr, and `guard_gc` must keep
  striking. str_gmatch residency 3.3% → 75%, wall 52.6 → 49.4 ms. The
  region-window remainder strike (`0 < work < min_useful` in
  `flushRegionWindow`) has the same conceptual issue but was NOT the
  mechanism here; doc 31 §4 leaves it untouched pending its own
  evidence.
- **gmatch/for-in entry seam: 2 of 8 iterations per instance run tier-0**
  (doc 31 §9, 2026-08-29). After doc 31 the remaining str_gmatch gap to
  the `--jit-stats` ideal is not gating: per instance the for-in loop
  runs 2 header iterations tier-0 (~541 c/it) before native entry
  catches (6 native at ~265 c/it) — ~40% of the loop's cycles at bench
  scale. The tfor `.jloop` entry patch (doc 30) covers the back-edge
  path; getting entry onto the FIRST header reach of a fresh instance
  (patched header dispatch, LuaJIT-style `JLOOP` at the header) is the
  follow-up lever. General: any short-instance iterator loop pays this
  seam, not just gmatch.
- **value16 full-Value shuttle slots for generic-for breadth.** The
  carried-string classification (doc 30 c4b) covers string control
  variables; `pairs`/`ipairs` iterators carry arbitrary key types, which
  today can't home natively (no tagged full-Value slot representation in
  the native frame). A 16-byte tagged shuttle slot kind would generalize
  `recTForLoop` coverage to any iterator whose ctrl type varies —
  the next breadth lever for generic-for once a bench demands it.
- **`get_index` module-table indexing NYI blocks inline `string.find`
  shapes.** `local find = string.find` records fine (slot_load + guard);
  writing `string.find(...)` inline at the call site needs a heap-valued
  hash field load of the `string` module table (`get_index` on a
  function value), which is the campaign-map item (4) gap. Noted so the
  overlap is visible when that arc starts.
- **lua54 t0 is layout-sensitive (~±11%).** The doc-30 A/B showed lua54
  t0 27.6 → 30.8 ms with instructions +0.3% but L1-icache misses 7×
  (perf stat, both binaries): ~230 KB of new recorder/nativegen code
  shifted tier-0 dispatch alignment. No semantic change. If tier-0
  dispatch perf becomes an arc (campaign map item: threaded dispatch),
  hot/cold function splitting or explicit dispatch-loop alignment is the
  general fix; until then expect this row to wobble across rebuilds.

## ~~Nested last-arg builtin calls compile to MULTRET and abort recording~~ RESOLVED 2026-08-28 (doc 27, "multinest")

**Landed exactly along the sketched fix shape, generalized** (doc
27-multret-nested-call-recording.md): the recorder keeps a one-instruction
`multret_top` shadow of tier-0's `reg_top`/`reg_top_pending` handshake and
resolves BOTH pair halves against it — consumers (`call b=all_results`, `ret
b=all_results`) compute the fixed count with tier-0's own arithmetic; producers
(single-result builtin arms under `c=all_results`, and inlined-closure `ret`s
into a dynamic caller window) publish it. Arbitrary nesting and closure
composition fall out (no depth anywhere in the mechanism); `codepoint`/`select`
producers and vararg spreads stay fail-closed barriers. `lower(upper(a))` and
every probed composed form record with zero aborts and run natively.

**str_manip outcome (honest):** the MULTRET abort is gone but the bench moved
only 5.2×→5.0× — because the main path's 74-op trace now COMMITS and the
remaining time is op-core cost, not coverage (see the corrected
`MAX_TRACE_INPUTS` entry below — the cap was never the main-path blocker).
Original note kept for history:

## Original MULTRET note (noted 2026-08-27, doc 24 c3) — historical

`rev(sub(base, 2, 5))` — an inner call in the outer call's LAST argument
position — compiles to the multret shape (inner `c = all_results`, outer
`b = all_results`), and every recorded-builtin arm pins exact arity
(`instr.b`/`instr.c` literals), so recording aborts `.cross_frame` at the call.
The same expression through an intermediate local (`local t = sub(...); rev(t)`)
records fine, and a nested call in NON-last position (`rep(char(x), n)`) also
records fine — only the last-arg statically-1-result case is lost. Fix shape:
when `instr.b == all_results` the actual argument count is
`reg_top - (base + a + 1)` (exactly how tier-0 resolves `nargs`); the recorder
could resolve it the same way and re-enter the pinned-arity path when the
dynamic count matches, plus accept inner `c = all_results` when the consumer
takes exactly one value. General win: any composed builtin expression
(`f(g(x))`) benefits, not one bench. None of str_manip's v1-recordable ops hit
this today (its only nestings are `lower(upper(a))` — out of v1 anyway — and
`rep(char(...), 4, "-")` — 3-arg rep, its own frontier), so it stayed a note.

**UPDATE (2026-08-28, doc 26 landed):** this is now THE str_manip blocker.
upper/lower/codepoint all record (supper/slower/scp, native-lowered), and the
A/B probe confirms the prediction: the intermediate-local form of the
str_manip core (`local u = upper(base); lower(u)`) records with ZERO aborts,
while the bench's actual `lower(upper(a))` still aborts `.cross_frame` at the
nested call — the abort moved from "case ops unsupported" to exactly this
frontier. Every other op in str_manip's hot path (`sub`, `reverse`, `len`,
2-arg `codepoint`) now records, so lifting this one shape should let the whole
loop trace (`rep(char(..), 4, "-")` sits behind a 1-in-64 branch and can stay
a side-exit). *(Post-landing correction: "should let the whole loop trace" was
RIGHT — the main path's 74-op trace commits (needing 7 inputs, under the
then-cap of 8). The bench barely moved because the remaining time is op-core
cost, not trace coverage — see the corrected entry below.)*

## ~~str_manip's NEW sole blocker: `MAX_TRACE_INPUTS = 8` cap~~ WRONG DIAGNOSIS — cap raised 8→64 anyway (2026-08-28, input-cap arc)

**The original claim below was falsified by the input-cap arc.** str_manip's
main path needs only SEVEN inputs (`sub`, `base`, `upper`, `lower`, `reverse`,
`len`, `byte`) and its 74-op trace was committing AT cap 8 all along (8593
bytes native; the 1/64 `rep(char(..))` branch folds to a `guard_false`). The
518 `too_deep` hits were that rare branch's SIDE-TRACES, which additionally
read `char`/`rep` (inputs #8/#9); at cap ≥16 those same side-traces die at the
3-arg `rep` instead (`recBSRep2` is 2-arg only — the rep3 frontier). Bench
unchanged (~5.0×) at ANY cap value.

**What the arc landed:** empirical sweep of N-upvalue-callee loops (steady +
entry-heavy shapes, N=2..64) shows flat jit cost at every N, and an
upvalue-vs-anchor-local control is identical within noise — the input
machinery (synthetic seeds + per-entry re-resolve in `seedTraceInputs`) is
FREE through 64. `MAX_TRACE_INPUTS` is now 64: a pure-policy backstop against
degenerate anchors, dynamically capacity-checked, not a layout invariant. Any
loop calling ≤64 distinct cached-in-locals functions now records (Z-6 general
win); tests pin both sides of the boundary.

**str_manip's ACTUAL remaining gap (perf, ReleaseFast, cap irrelevant):**
tier-0 exec 21.5% (1/64-branch side exits + entries), memcpy 13.1%, caseCore
~17.3% (full-Unicode machinery running on ASCII data), wyhash 10.4% (result
interning), subCore 8.9%, reverseCore 7.5%, codepointCore 5.1%, decodeAt 4.1%
(full UTF-8 decode on ASCII). Levers, all general: ASCII fast paths in the op
cores, interning cost, 3-arg `rep` recording (rep3), tier-0 side-exit
fraction.

**UPDATE (2026-08-28, doc 28 string arc landed, LATEST-96):** the "ASCII fast
paths in the op cores" lever is DONE (exact `str_ascii` bit + seam helpers +
block paths + known-fact interning; str_manip 23.9 → 18.8 ms, 4.0×). Still on
the table from the list above: **interning cost** (L3 sparse hash — Bart
decision pending, doc 28 §5), **rep3 recording**, **tier-0 side-exit
fraction**, and the **decimal renderer** for str_format (doc 28 §7 non-goals).

**UPDATE (2026-08-28, doc 29 matcher/tonumber arc landed, LATEST-97):** the
matcher constant factor is DONE (table-driven matchClass, cheap widths,
countRun; str_gsub 53.3 ms = **1.2× LJ, at campaign target**; find_match
2.2×). Deferred from doc 29: **A5 first-item skip-scan** (land after doc 30,
measured in the recorded-callout world), **matchBracket bitset precompute**
(gmatch's `[^,]+` still linear-scans per byte — revisit only with a profile
showing bracket heat after doc 30). Open Bart decisions: **doc 29 §B2
tonumber grammar** (a/b/c — today mahina accepts `"1_000"`/`"0o17"`/`"0b101"`/
`"inf"`, all std.fmt artifacts, none Lua-legal) and **doc 30 v3 go-ahead**
(pattern/tonumber recording — kills the string benches' host_barrier).

## `table.pack`/`table.unpack` recording (noted 2026-08-27, ex-`math.type` entry)

The `math.type` fold arm from this entry LANDED with arc B c1 (doc 24;
`RecordedBuiltin.mtype = 11`, `recBMType` cloning `recBType`'s pin structure).
What remains of the original observation: `bench/stdlib/lua54.lua`'s loop now
records past all three `mtype` sites and aborts `host_barrier` at
`pack(i, i+1, i+2)` — `table.pack` allocates a fresh table (TNEW-class), which
is beyond even doc 24 v1's string-scalar scope. Revisit when on-trace *table*
allocation gets its arc (doc 24 D2's id-stream lemma applies unchanged; the
budget-guard protocol was designed to cover it).

## FIXED 2026-08-26 — the two `driveChain` panics were ONE bug: a use-after-free of the tier-1a executor scratch

Kept on file because the diagnosis corrected two things the original report got
wrong, and because the follow-up below came out of it.

**What it actually was.** `TraceState.values_scratch` was a single flat
`ArrayListUnmanaged(Value)` grown with `resize`, but trace execution nests:
`enterSelectedTrace` takes a frame for the trace it enters and keeps it live
across `driveChain` (it is the `.ir_numeric_for_done` payload), and the
candidate walk takes a frame of its own. A candidate longer than the entering
trace reallocated the buffer and the dispatcher's slice became a dangling
pointer. `flushNumericForLoopDone` then read the freed block, which produced
*both* reported symptoms from one fault: `values[ar.a].asHeap()` tripping the
tag assert (nsieve-bit, 38-instr entry vs 59-instr candidate), and
`regs.set(p.aux, values[p.b])` writing a garbage tag byte that the next
`regs.get` decoded as an invalid enum (scimark-sparse, 44 vs 57).

**Both original hypotheses were wrong.** It was not "the flush walks store
instructions past the live prefix" — the flush is correct, its memory is gone.
And it was not Debug-only UB: the buffer moves in ReleaseFast too (measured).
Release printed the right answer purely because the process allocator neither
scrubs a freed block nor had reused it — stale-but-correct bytes, not benign
garbage.

**Fix:** the scratch is now a segmented stack (`values_chunks` + `valuesMark` /
`valuesPush` / `valuesRelease`). Chunks are independent allocations, so growth
never moves a live frame; frames are released LIFO, which is what makes a chunk
at or above the cursor provably dead and safe to reallocate. Mirrors the
discipline `interp.zig`'s register stack and `boundary_scratch` already use.

**Audited alongside:** `values_scratch` was the only function in the tree
handing out a slice into a growable `ArrayList` (`grep 'return self\..*\.items'`).
`ledger_scratch` is a fixed-size array and every consumer re-derives its slice
after each capture; the register lanes and `boundary_scratch` are fixed and
documented as never reallocated.

**Process fix, done:** `just hashgate` now has a second leg (`--also-mahina`)
running the same 84 configurations under a safety-checked Debug build. The gate
had only ever seen ReleaseFast, which is exactly why two real bugs sat in the
corpus. Demonstrated load-bearing: with the fix reverted, the release leg passes
6/6 on the affected programs and the Debug leg reports the abort.

### Follow-up DONE (2026-08-27): the native path no longer pushes a scratch frame it never uses

`enterSelectedTrace` used to push the executor value frame unconditionally, but
on a successful native entry `buf` was used by nothing — the tier-1a executor,
the exec-log path, and the `.ir_numeric_for_done` chain are all off that road,
so native paid the most for the discipline while using it least (inverse to
actual use: tier-0 0.000%, tier-1a fft +0.10%, native fft +0.43%). Now the push
happens only when `native_page == null` (which also covers exec-log — it forces
the page null), the release is deferred on a `buf_live` flag, and the one
native road back onto the executor — the seed-hash-decline downgrade — re-pushes
at its tier-1a rerun site. Measured by instruction count (3 reps, medians):
scimark-fft `--jit-native` −0.523%, scimark-lu −0.433%, tier-1a fft and tier-0
unchanged, nsieve −0.002%. The decline-site re-push is pinned by the B-v
decline-determinism e2e test (mutation-verified: dropping the re-push crashes
exactly the two hash-drift tests on the executor's entry assert).

## DECIDED, kept on file (2026-08-26): `tostring`/`print` of a float uses shortest-round-trip where Lua uses `%.14g`

**Bart's call: deliberate, keep it.** Recorded here rather than dropped, because
it is undocumented in the design docs, it is a real and permanent divergence
from reference Lua, and it is the reason behind a bench convention that would
otherwise read as superstition. Not a defect and not scheduled work.

Note this is deliberately NOT the same choice as `string.format`, which was
moved to exact C semantics the same day (`src/stdlib/decimal.zig`): `%.2f` of
`2.675` is `2.67` here, as in C. So `print(x)` speaks mahina's own
lossless-presentation dialect while `string.format` speaks C. The two disagree
about what a double "is" — `print(2.675)` says `2.675`, `%.20f` says
`2.67499999999999982236` — and that seam is intentional.

| expression | mahina | Lua 5.4 / LuaJIT |
|---|---|---|
| `print(1/3)` | `0.3333333333333333` | `0.33333333333333` |
| `print(0.1+0.2)` | `0.30000000000000004` | `0.3` |
| `print(5e-7)` | `0.0000005` | `5e-07` |
| `print(1e100)` | `1` + 100 zeros | `1e+100` |
| `print(2^53)` | `9007199254740992` | `9.007199254741e+15` |

Reference Lua renders with `LUAI_NUMFFORMAT` = `"%.14g"`: 14 significant digits
and a switch to exponent form outside a magnitude band. mahina renders the
shortest string that round-trips, always in positional form.

Shortest-round-trip is lossless and is what JS/Python/Rust do; `%.14g` silently
hides the `0.1+0.2` result. The cost accepted with it: `print(1e100)` emits 101
characters, and **no benchmark can `print` a bare float and claim
`luajit=compatible`**. That constraint is absorbed by the bench convention
"accumulate an *integer* checksum" — `bench/README.md` now states this as the
reason rather than leaving it as folklore.

## Weak-but-nonzero bench output coverage (noted 2026-08-26)

The empty-stdout hole is closed, but the *next* weakest link is worth naming.
Eight `bench/stdlib/` programs collapse an entire run into a single accumulator
line — `scalar.lua:36`, `tbl_ops.lua:32`, `str_gsub.lua:32`,
`str_find_match.lua:33`, `str_manip.lua:40`, `lua54.lua:35` print one
`acc=<int>`; `str_gmatch.lua:34` and `str_format.lua:31` are only slightly
richer. A single summed integer will catch a gross error but can absorb
compensating ones, and it pins nothing about intermediate state. Not urgent —
these are genuinely non-empty and do constrain output — but if a subtle
string/table bug ever slips past the suite, this is the first place to look.

**Sweep result (2026-08-27), decided with Bart: accepted as-is.** A full
suite sweep (all 28 benches × 3 tiers × LuaJIT, plus a halved-workload
sensitivity probe) found no silent failures: every error class exits nonzero
and `run.py` catches it, no stderr channels, refs ↔ discovery in lockstep, no
orphaned benches, LuaJIT parity real everywhere. The one structural note:
**scimark-lu and scimark-sparse checksums are cycle-count-insensitive** — LU
re-factors a fresh copy each cycle and SPARSE overwrites `vy` each cycle, so
the final state (fully folded) witnesses the last cycle only, and the ×cycles
repetition is semantically dead. This is upstream scimark's own shape (Pall's
suite discards even the flop counts) and is NOT a correctness hole — output
equivalence is the contract, and work an engine can legally skip is not owed.
It only matters if an engine ever grows cross-iteration store sinking / dead-
loop elision strong enough to elide the repetition, which neither mahina nor
LuaJIT (15 years in) has; and doing so would announce itself as an absurd
step-change in exactly these two board rows. If that day comes, the fix is a
one-element-per-cycle fold into the checksum (~0.1% SPARSE, ~0.002% LU).

## DEFERRED (Aug 2026): further decomposition of trace.zig / interp.zig

The test-suite extraction (LATEST-67) took the four biggest files down a lot,
but stopped at moving tests. Bart explicitly chose to stop there; recording the
mapping so it does not have to be re-derived.

**trace.zig, still 13,542 lines.** `TraceState` alone is ~10,632 of them
(~220 methods, 109 fields) — it *is* the file. Zig 0.17 removed
`usingnamespace`, so nothing moves out without converting methods to free
functions taking `*TraceState`. Known seams, in ascending difficulty:

- *Pure value types + free functions, no `TraceState` dependency* — the IR
  section (~444 lines), guard/exit provenance types + ordering/hashing (~289),
  and the disassembler/stats printer (~330). Movable as-is, but `IrOp`/`IrInstr`
  are referenced from 11 other files, so it needs re-export shims in trace.zig.
  Total win only ~1,060 lines, which is why it was skipped.
- *The recorder* (per-instruction recording, ~1,500 lines) touches only
  `self.rec`, `self.gpa`, `self.config` and its own helpers — **zero** references
  to region, link, promotion or gate state. `commit()` is the single bridge.
  Strongest structural seam in the file.
- *Region discovery + region profit* share `region_defs_gen` as an invalidation
  clock; they move together or not at all.
- *Dispatch/replay* (`driveChain`, `driveSilentBurst`, `replayLedgerFrom` — that
  last one is 770 lines on its own) has the highest fan-in in the file. Least
  separable; leave alone.

**interp.zig, still 4,839 lines.** `Vm` is ~3,684 of them, and half of that is
the exec dispatch loop. The free-function-taking-`*Vm` pattern is **already
established** in this file (the effect/host-seam helpers use it), so extending it
is not a new pattern. Candidates: error/fault reporting (~285 lines), stdlib
install (~114 + the natives), metamethod dispatch (~218), table/grid indexing
(~219), closures/upvalues (~71), GC rooting (~110), and `enterSelectedTrace`
(~537, the biggest single move, but its `EntryDirective` contract with `execImpl`
is currently implicit and would have to be made explicit).

**Do NOT split** `execImpl` + `nextOp` + `runFastPath`. Cross-module `inline fn`
plus the comptime `mode: ExecMode` specialisation make the dispatch loop's
codegen fragile, and that is the hot tier-0 path — any change there needs a
benchmark, not just a green test run.

## RESOLVED (2c-F, July 2026): fused native cycle re-entered COLD from a fresh top-level epoch

Found while writing the 2c-F disarm integration test. Re-running a **completed
top-level proto** a second time via `vm.run(chunk.proto)` on the **same VM**, when
that proto's inner `C↔I` native cycle was already fully armed+fused from the first
run and **no observation window was open**, once produced a spurious `TypeError`
from the fused native→native handoff (the arith `isNumber` guard). It reproduced
**exactly once in ~25 runs** and vanished when the set of compiled tests changed —
address-/mcode-arena-layout dependent (the S2 "fused handoff jumps through a slot
whose correctness depends on memory layout" signature). Could not be reproduced
again in 1600 in-process reruns nor in codex's 64-layout + forced-retire/reuse
harness — extremely elusive.

**Root cause + fix (two codex `gpt-5.6-sol` reviews).** The arc's supported paths
all reviewed sound; the one blocker was this unconfined rerun failure. Two layers
landed:
1. **Hardening (codex, root-cause route):** `armNativeLink` now DERIVES its target
   from `child`+`kind` (never trusts a caller-supplied address), and `compileImpl`
   release-validates each secondary-entry offset lies in the child's live mcode page
   before publishing. Reviewed defensive-only — it proves address *provenance* but
   not dynamic-entry validity across an epoch.
2. **Epoch containment (the actual fix):** `Vm.beginTopLevelEpoch` calls
   `disarmAllLinks()` at every fresh `run`/`start` entry (NOT `exec()` resume — that
   is the same epoch, governed by the 2.3c-0e dispatcher window-disarm — and NOT
   nested calls). A stale link can pass both hardening checks (valid in-page address,
   correct live child) yet still fire into a fresh-epoch frame; the fresh-run disarm
   restores the dispatcher boundary before any old edge can fire. Links re-arm from
   observations made during the new run.

**Tests (all green, both default and `-Djit-debug` builds):**
- Containment integration test *"a fresh top-level run disarms the prior epoch's LIVE
  armed cycle"* — Phase A negative control (`native_link_disarms == 0` within one
  epoch) + Phase B fresh run disarms the live cycle (`> 0`, byte-identical, no window).
  Proven load-bearing (disabling `beginTopLevelEpoch` fails exactly this test).
- Supported cold-re-entry guard *"a hot armed cycle inside a repeatedly-called
  function stays correct on re-entry"* (nested calls, byte-identical across ASLR).
- `disarmAllLinks` unit test + `native_link_disarms` counter idempotence.

**Follow-up (nice-to-have, not blocking):** a suspend/resume-with-active-window
integration test for the 2.3c-0e dispatcher window-disarm specifically (currently
unit-covered by the `disarmAllLinks` test; the containment test exercises the same
`disarmAllLinks` end-to-end via the epoch boundary). The keyframeser suspend/resume
harness (keyframeser.zig:2069/2175) is the vehicle if this is ever built out.

## Hash-field (string-keyed) tracing — H0+H1 LANDED (June 2026, uncommitted, pending approval)

`obj.field` get/set now records a trace (`href`/`hload`/`hstore`/`guard_hash`) and
runs **native** via a seed-resolved loop-invariant value-cell pointer (Approach B):
`seedTraceInputs` resolves the cell each entry into a synthetic slab slot; `Kind.href`
reads it as an invariant home; `hload` tag-checks + loads payload; `hstore` writes
tag+payload; `guard_hash` lowers to nothing (per-entry seed eligibility gates native
vs the tier-1a oracle). Byte-identical across 8 modes + keyframe replay. Doc:
`docs/design/11-hash-field-tracing.md` (status: complete).

**Measured (`bench/field_hash.lua`, `t.x = t.x + t.y` RMW):** tier-0 1534 ms →
native 22.3 ms (**68.8×**), within **2.6× of LuaJIT** (8.5 ms); `perf record` shows
**99.9%** native `[JIT]`, `Table.get/set` 0.0%.

**Honest scope caveat (told to Bart):** this lever alone moves zero corpus benches
— nbody also calls `sqrt` (host_barrier abort) and array3d also has a stateful
closure iterator; each needs a companion lever. H0/H1 unblock the *first* abort so
those companions can land on top.

**Deferred follow-ons:** computed-key `t[expr]` (runtime key-identity guard) and
absent-key insert / `__index` (grow-aware cell re-resolve) — out of v1 scope.

## Cross-frame tracing — the *cluster lever* (June 2026)

Cross-frame Phase 0 (`docs/design/10-cross-frame-tracing.md`) inlines pure
local/param-leaf Lua calls. **Sub-lever 1 — U0 (done, uncommitted):** the recorder
now also reaches a callee through a loop-invariant **upvalue / global** (entry
snapshot + `guard_func`), so spectral-norm's inner loop records a trace. No speedup
yet — that trace carries `guard_func`, which native auto-declines until **U1**
(native `guard_func` lowering; task #186). The remaining JIT-inert shapes still
abort: **method / `__index` dispatch** (`arr:set`, array3d), **generic-for closure
iterators** (array3d's `for … in arr:points()`), and **native callees** (scalar's
`type`/`tostring`/…, correctly never inlined) — each its own change. Tripwire (still
open): U0's callee reads no upvalues of *its own*, so `Proto.id` is still a sound
`guard_func` key; the day we inline a callee whose own body reads an upvalue,
tighten `Proto.id` → closure `GcHeader.id`.

## nativegen — pre-existing latent shape: conflicting-aux duplicate guards on one slot_load (June 2026)

U1's `guard_func` native lowering hardened its prologue-id scan in `analyzeInner`
to **bail** if two `guard_func`s cover one snapshot `slot_load` with *different*
recorded `aux` (the prologue checks one id; the oracle re-checks each and would
side-exit on the second — a native≠oracle divergence). The **`.ptr`/`guard_lane`
scan immediately above it has the identical first-match shape** and is *not*
hardened: two `guard_lane`s on one table `slot_load` with different lane `aux`
would likewise miscompile. Neither is reachable today (the recorder dedups each
snapshot to one synthetic slot → one resolved value → one guard), so this is a
robustness gap in the verifier-gated native subset, not a live bug. If the lane
path is ever generalized, mirror the func-scan's duplicate-aux bail (and consider
lifting the check into `proveKinds` to cover all guard kinds uniformly).

## LuaJIT benchmark corpus — blocked benches (June 2026)

`bench/luajit/` vendors the 14 CLBG/SciMark ports that run byte-identical to
LuaJIT today (array3d, binary-trees, euler14-bit, nbody, nsieve, nsieve-bit,
nsieve-bit-fp, partialsums, recursive-fib, spectral-norm, and scimark-fft/lu/sor/
sparse). The remaining LuaJIT benches are each blocked by one identified gap —
knocking any of these down unlocks the listed benches as new corpus members:

- **`coroutine` library** (none yet): unlocks `chameneos`, `coroutine-ring`.
  Largest lift; intersects determinism (coroutine resume order must be replayable).
- **LuaJIT `bit.*` library** — RESOLVED, not added (June 2026). mahina already has
  native 64-bit bitwise *operators* (`&` `|` `~` `<<` `>>`, wired by the metamethod
  arc). Bart's call: do **not** add a `bit` module — its int32-normalization would
  bolt a 32-bit-semantics island onto a 64-bit language, which Lua 5.4 itself
  rejected in favour of native operators. mahina also stays strict integer-only
  (unlike 5.4 it does not coerce integral floats in bitwise ops; the error message
  was fixed to the Lua-shaped "number has no integer representation" / "attempt to
  perform bitwise operation on a <type> value"). `euler14-bit` and `nsieve-bit` are
  now in the corpus, **rewritten** to native operators (semantically equivalent,
  not code-identical); LuaJIT runs the verbatim `bit.*` originals under
  `bench/luajit/_ref/` via the new `luajit_src=` metadata key, and both halves are
  byte-identical. `mandelbrot-bit`/`md5` remain blocked on binary output / non-ASCII
  escapes, independent of bitwise support.
- **Leveled long-bracket strings `[[…]]` / `[=[…]=]`** — DONE (June 2026, lexer +
  compiler, 8-mode tested). This was a genuine Lua 5.4 conformance gap (mahina
  previously lacked long strings entirely, even `[[…]]`). It did **not** unlock the
  dynamic-codegen ports as hoped: `fasta`/`pidigits-nogmp`/`revcomp`/`meteor` each
  pile on further LuaJIT-isms — the `jit.*` module, `loadstring` with a *numeric*
  chunkname, stdin (`revcomp`), and `...` forwarded into the loaded chunk. Left
  blocked; revisit per-bench if those land. `loadstring` (a 5.1 alias of
  `load(string)`) was deliberately **not** added — it unlocks nothing measurable on
  its own and is a 5.1-ism; reconsider alongside the broader compat-alias question.
- **`require`-from-cwd in `bench/run.py`** — DONE (June 2026). `run.py` now runs
  every child (mahina all tiers + LuaJIT) with `cwd` set to the bench's own
  directory (`run_once`/`time_best` gained a `cwd=` param), mirroring LuaJIT's
  `run.sh` `cd $BENCH_DIR`, so `package.path`'s `./?.lua` resolves the shared
  `scimark_lib.lua` (no `@bench` header). Unlocked the four
  `scimark-{fft,lu,sor,sparse}` kernels (corpus 10→14). They sit 35–76× off
  LuaJIT — the float/array throughput the JIT is still a no-op on. They were
  vendored as pure-timing benches (discarded flop count → empty stdout →
  empty==empty parity); **that stopped being true on 2026-08-26**, when all
  five silent benches gained result checksums and `scimark_lib.lua`'s RNG
  branch was forced portable — see `bench/README.md` and the note in
  `tools/hashgate.py`.
- **Binary / Latin-1 output** (`io.write` of non-UTF-8 bytes) or non-UTF-8 source:
  `life` (Latin-1 source string), `mandelbrot`/`fannkuch` (binary PBM output +
  a perm-printing branch divergence). Needs care re: the UTF-8 source/output policy.
- **Missing functions**: `k-nucleotide`, `sum-file` (io.read/io.lines shapes).
- **Deep non-tail recursion** overflows mahina's call stack at LuaJIT's N:
  `recursive-ack` (Ack(3,6) overflows; matches only at small N). Needs a growable
  / deeper VM call stack.
- Excluded: programs that print their own `os.clock` timing (`series`) — stdout is
  not byte-comparable across runs (the clock is an effect, legitimately varying).

### Pre-existing bench bug (separate, Rule #10): `bench/stdlib/str_manip.lua` is mislabeled `luajit=compatible`
Discovered while vendoring scimark (June 2026). `str_manip.lua:17` does `local byte =
string.codepoint`, but `string.codepoint` is a Lua 5.3+ function LuaJIT (5.1) lacks,
so on LuaJIT `byte` is nil and line 28 errors `attempt to call upvalue 'byte'`. The
harness has always shown this as `luajit=ERR` (independent of the new per-bench cwd —
it errors identically from the repo root). The names don't line up across engines:
mahina has only `string.codepoint` (S-B removed `string.byte` for code-point semantics),
LuaJIT 5.1 has only `string.byte`. The bench's own comment notes the base string is
all-ASCII, so a mahina code point equals a LuaJIT byte — so parity is achievable two
ways: (a) flip the bench to `luajit=skip` (simplest, loses the parity check), or (b)
use the `luajit_src=` mechanism (the `_ref/` file calls `string.byte`, the mahina file
calls `string.codepoint`), the same shape as the `euler14-bit`/`nsieve-bit` split. Out
of scope for the scimark commit; left for a separate bench-fix pass so it isn't bundled
with unrelated corpus work.

## Unicode-native strings (design doc 06) — S-A..S-E ALL LANDED (June 2026)

S-A (text↔bytes boundary, `src/stdlib/string.zig`, `sEncode`/`sDecode`):
`string.encode`/`s:encode()` → byte array (table, integer keys `1..n`, `0..255`),
total; `string.decode(bytes)` → interned string, raising a **catchable** error on
invalid UTF-8 / out-of-range / non-integer elements.

S-B (code-point-native strings, the breaking core): a `string` is a sequence of
Unicode code points. `#s`/`string.len`/`sub`/`reverse`/`string.char`/
`string.codepoint`/`s:codes()` index by code point; cached `cp_len` on the heap
`String` (computed in `String.create`, recomputed on restore — no schema bump);
`#s` is tier-0-only so all 8 modes inherit it (no JIT change). `\u{…}` lexer
escape; `\xNN`/`\ddd` are ASCII-only (byte ≥ 0x80 → compile error); every literal
validated UTF-8 at construction (`decodeString` + `utf8ValidateSlice`).
`string.byte` removed; no `utf8` module ships. CSV + doc-06 updated in lockstep.

**S-D LANDED (June 2026) — patterns on code points + character indices.** The
matcher (`src/stdlib/pattern.zig`) now steps the **subject** by code point: `.`
matches one whole code point, a literal multibyte char is one item (`classEnd`
groups the UTF-8 sequence), and quantifiers/anchors/captures advance by code-point
width. Greedy `maxExpand` backtracks one code point at a time via a backward
continuation-byte scan (`cur -= 1; while (src[cur] & 0xC0)==0x80`), so `MatchState`
stays **allocation-free** (no scratch). Class shorthands (`%a %d …`) and bracket
sets stay **ASCII**, guarded by `src[s] < 0x80` in `singleMatch` — load-bearing,
not an optimization: without it a high byte wrongly satisfies a *complement* class
(`%A`/`%D`/`[^…]`). At the `string.zig` seam, `find`/`match`/`gmatch`/`gsub` accept
and return 1-based **character** indices (`resolveInit`→`charByteOffset`, byte
offsets→`cpCount`, position captures `()`→`byteToChar`); captures stay byte offsets
inside the engine and convert only at the boundary. The matcher is a pure,
allocation-free function of its byte inputs — no host effect, no recorded input —
so 8-mode determinism is inherited (asserted by an `expectProgram` test). **Caveat
(documented, out of scope):** multibyte chars inside bracket sets (`[é]`, `[é-ñ]`)
and multibyte `%b` delimiters stay byte/ASCII-level; Unicode property classes
(`\p{L}`) deferred. CSV + doc-06 updated in lockstep.

**RESOLVED — host-input UTF-8 boundary.** S-B's review (Codex + Antigravity) flagged
that the "every string is valid UTF-8 by construction" invariant held for string
*literals* and `string.decode` but NOT for host-sourced strings. Bart's call: **reject**
— the host-input boundary now validates and raises a *catchable* error (like
`string.decode`). `Vm.validateHostText` (`interp.zig`) checks `utf8ValidateSlice` and
raises a located error; it is called on the *logged* result in `performEffect`
(`getenv`/`argv`) and `obtainFileRead` (`file_read`) — **after** `logEffect`, so record
(fresh intern) and replay (re-intern from the log) validate identical bytes and raise
identically — and inline in `populateArgs` (load-time `arg[]`, before intern). No
malformed string can now reach a program, so the `cp_len`/`charByteOffset` divergence is
gone too. `internValue` stays raw (internal callers are valid by construction; the
replay re-intern path must not re-raise mid-feed).

**S-C LANDED (June 2026) — case mapping + recorded `unicode_version`.**
`string.upper`/`string.lower` are now Unicode-aware via the vendored, versioned
**simple (1:1)** case table (`src/gen/unicode_case.zig`, generated by
`tools/gen_unicode_case.py` from `vendor/ucd/16.0.0/UnicodeData.txt` fields 12/13;
`just gen-unicode` regenerates). ASCII is the branch-free fast path; non-ASCII
maps one code point → one code point (count-preserving — `ß`/`ﬀ` unchanged). The
active version (16.0.0, packed `major<<16|minor<<8|patch`) is recorded once per
session as `EffectKind.unicode_version`=6 at the first case op (`noteUnicodeVersion`,
modeled on `obtainRandomSeed`) and re-asserted on replay — a mismatch is a fatal,
**uncatchable** `Error.UnicodeVersionMismatch`. `effect_format_version` 3→4 (the
only wire bump; rides the scalar-int `EffectResult` path). The "once per session"
pin is **derived, not stored**: the keyframe carries no effect-cursor/PRNG state,
so a snapshot resume re-scans the consumed effect-log prefix
(`versionAlreadyConsumed`) instead of needing a `snapshot_format_version` bump
(proven by the keyframeser resume test).

**FOLLOW-UP (pre-existing, separate, Rule #10): once-per-session effects across a
*record-mode* snapshot resume.** The keyframe carries no `effect_log`/`effect_cursor`/
PRNG state (that's what made S-C's *replay* pin a sound *derived* guard). The flip
side, flagged by Codex's S-C review: snapshotting a **live recording** and resuming
it *in record mode* would re-log every once-per-session effect — both the **RNG
seed** (`EffectKind.random_seed`) and now the **`unicode_version`** pin — because
`restore` resets their in-memory guards and the record arm has no recorded prefix to
derive from. The replay-resume path (the harness we actually ship) is correct; only
the hypothetical "resume a live recording as a fresh recording" flow is exposed, and
it is exposed *symmetrically* for both effects, so the fix belongs at the keyframe
layer (persist `rng`/`effect_cursor`/`effect_log` + a `snapshot_format_version` bump),
not as a per-effect patch. Out of scope for S-C — noted so it isn't lost.

**S-E LANDED (June 2026) — the `u8` (unsigned-byte) array lane.** Byte arrays
(integers in `[0,255]`) now pack at **1 byte/slot** instead of `i16`'s two (a byte
overflows signed `i8`'s 127 ceiling). `u8` is the final rung appended to the
`Lane` enum (ordinal 7, so existing ordinals stay put — trace IR embeds them in
`guard_lane.aux`). It is a *sibling* entry point, not below `i8`: a new
`intLaneForRange(lo,hi)` chooser maps a non-negative `[lo,hi] ⊆ [0,255]` to `u8`
and routes `laneForValue`/`optimalLane` through it; a negative or `>255` store
widens to the smallest *signed* lane covering the **combined** range
`[min(0,v),max(255,v)]` — always `≥ i16`, never `i8`, never back to `u8` (so high
bytes survive), via `widenFor`'s `.u8` arm. `canWidenTo(.u8,·)={i16,i32,i64,value}`;
nothing widens *to* `u8`. `decode` zero-extends (`@as(i64, byte)`), `encode`
`@intCast`s, `laneFits`/`dataBytes`/`usesPresenceBitmap`/`isInt` get `u8` arms. In
`nativegen.zig`: a `U8_LANE` const, `laneKind→.int`, `intLaneWidth→1`, an `aload`
that zero-extends (`movzx` — the existing `loadRegMemSib(width=1, signed=false)`,
**no new x64 op**) instead of the signed lanes' `movsx`, and a `guard_fits` that
range-checks `[0,255]` derived from the *lane* (not the width, since width-1 is now
ambiguous with `i8`). The store path (width-truncate + presence `bts`) is
signedness-agnostic and unchanged; the trace recorder gate (`lane.isInt()`) now
includes `u8` automatically. Lanes are never serialised and the native load matches
tier-0 `decode` byte-for-byte, so determinism/8-mode parity is inherited. **Accepted
trade (Bart's framing):** `{1,2,3}`→`u8` (was `i8`, both 1 B/slot); `{1,2,-3}`→`u8`
then widens to `i16` (was `i8`). Tests: array unit (commit/zero-extend-decode/
combined-range widen), nativegen unit (zero-extend read scan, in-range write,
`guard_fits` side-exit at 256 and −1), interp 8-mode (byte-array workload + `u8→i16`
widen). doc-06 S-E `[x]` + open-question resolved; bench `cross: ok`, no regression.

## `load` / `loadfile` / `dofile` LANDED — deferred follow-ups (June 2026)

The full runtime-compile arc is in (`src/stdlib/load.zig`):
- **L-1 `load(chunk [, chunkname])`** — string chunk → vararg closure, `(nil, msg)`
  on syntax error, VM-owned `loaded_chunks` (freed at `Vm.deinit`), globally-unique
  proto ids via `compiler.Options.id_base`/`vararg_root`, per-proto `source` so
  faults report the loaded chunk's line/name.
- **L-2 recompile-on-restore** — a live `load` closure survives snapshot→restore:
  the keyframe carries each load's source text (`schema.LoadedChunk`) and restore
  recompiles deterministically (`recompileLoadedChunks`), resolving `proto_id`
  across static + dynamic trees. Hardened against `DuplicateInternedString` and
  `IdSpaceExhausted` (Codex review).
- **L-3 `loadfile`/`dofile`** — file content read via the injected `fs_source` seam
  and logged as `EffectKind.file_read` (record) / fed back from the log (replay);
  `effect_format_version` 2→3. `loadfile` → closure or `(nil, "cannot open <path>")`;
  `dofile` runs the chunk with no args and returns its results, raising on
  read/compile error.

Deferred:
- **Reader-function `chunk`** — only the string form is accepted today.
- **`mode` arg (`"t"`/`"b"`)** — mahina has no binary bytecode; `string.dump` is
  excluded, so only text loading exists. The arg is simply ignored/unsupported.
- **`env` arg** — mahina has no `_ENV` upvalue, so no per-chunk environment.
- **Per-chunk arena reclamation** — `load` in a loop accumulates `LoadedChunk`s
  until VM teardown (correct, leak-free per `testing.allocator`, but unbounded
  within a run). GC-integrated chunk lifetime is a later optimization.

## `_G` + error ergonomics LANDED (June 2026)

Lua-compat chunk: `_G`, `xpcall` before-unwind handler, `debug.traceback`.
- **`_G`** — the global environment exposed as a self-reference into the globals
  table (id 0), seeded in `installBaseLib` next to `arg`/`_VERSION`. The
  self-edge serializes as `HeapRef{id=0}` and round-trips the keyframe path; the
  unknown-global lint knows it (added to `builtin_global_names`).
- **`xpcall`** — the message handler now runs **before** the stack unwinds
  (`protectedCall` in `stdlib/errors.zig` reordered: call the handler with the
  faulting frames live, restore `depth`/`stack_top` only after it returns). pcall
  unchanged; handler-faults (catchable → `"error in error handling"`,
  non-catchable → re-raise) unchanged.
- **`debug.traceback`** — new `src/stdlib/debug.zig`, one native reusing
  `Vm.backtraceFrames`. Lua-shaped: no `thread` arg (no coroutines); a
  non-string, non-nil message passes through unchanged; `level` (default 1) skips
  leaf frames. Pure function of static proto names + source offsets → 8-mode
  deterministic; a native call is a trace barrier so no recorder/JIT change.

**Intentional semantic change:** because the handler now runs on the *live*
faulting stack, a located error *inside* the handler (`error(msg, level)` with
`level` reaching the faulting frames) resolves to the original error site, not
the restored xpcall boundary — this is Lua's before-unwind behavior and is
deterministic across all 8 modes (Codex flagged it; it's the intended effect).

**Pre-existing (noted, not in scope):** `nError`'s `raiseLocatedError(bytes,
@intCast(level))` and any `@intCast(i64→usize)` of a user level can trap on a
32-bit target (wasm32) for a huge in-`i64`-range level. `debug.traceback`'s own
level handling was made 32-bit-safe here; the `error()` path is unchanged and the
wasm build is already broken for an unrelated reason (see the `zig build wasm`
section). Fix alongside that.

**Deferred / known cosmetics:**
- Traceback lines render a named function's name as *both* chunk and function
  (`foo:5: in function 'foo'`) because mahina conflates per-function `proto.name`
  with the chunk name (consistent with existing `chunk:line:` error messages).
  Cosmetic; not worth a per-function chunk/name split yet.
- The rest of `debug.*` (`getinfo`/`sethook`/`getlocal`/…) stays unimplemented —
  most is determinism-hostile or excluded in the inventory.

## Metatables — chunks 2a + 2b LANDED; remaining follow-ups

Chunk 2a (the OO core) landed (June 2026): `Table.metatable` field + GC mark +
keyframe persistence (`HeapTable.metatable_id`, `Keyframe.string_metatable_id`,
snapshot v3); `setmetatable`/`getmetatable` (with `__metatable` protection);
`__index`/`__newindex` (table + function forms, bounded chain via
`Vm.indexGet`/`indexSet` + `MetatableChainLoop`); the shared string metatable so
`("x"):upper()` resolves through `string`; and the recorder aborts
(`AbortReason.has_metatable`) at `recArrayGet`/`recArraySet` so metatable-bearing
tables run tier-0. The dispatch keystone is `Vm.metatableOf` + `Vm.metamethod`
(interp.zig) over the cached `Vm.mm` name strings.

Chunk 2b (the operator metamethods) landed (June 2026): `__add __sub __mul __div
__mod __pow __idiv` (arith), `__unm` (neg), `__band __bor __bxor __shl __shr
__bnot` (bitwise), `__eq` (two-tables-only), `__lt`/`__le` (with `>`/`>=` via
operand swap), `__concat`, `__len`, `__call` (single + multret), and
`__tostring` (`tostring`/`print`). All route the tier-0 op's TypeError /
non-callable path through one shared helper set in interp.zig
(`binMeta`/`unMeta`/`arithMeta`/`unArithMeta`/`compareMeta`/`valuesEqual`/
`lenValue`/`metaToString`), each ultimately calling `Vm.callValue` — a trace
barrier, so every recorded op already aborts on a non-number operand and
side-exits to tier-0. 8-mode parity + a deterministic hot-loop `__add` corpus
under `interp.zig` tests.

**Deferred metamethod follow-ups:**
- `__name` metafield in `tostring`/error rendering (not yet honoured; only
  `__tostring` is). Out of the 2b scope.
- `string.format %s` honouring `__tostring` (currently raw-renders).

**Perf follow-up (separate):** a `guard_no_metatable` IR op so the recorder can
keep tracing metatable-*free* tables across a polymorphic site instead of the
current whole-trace abort. Not needed for correctness — only to recover JIT
coverage on code that mixes plain and metatable'd tables.

## `zig build wasm` is broken (wasm32 `usize` overflow in trace.zig hotIndex) — PRE-EXISTING

Discovered during the metatables M0 work (June 2026), unrelated to it. `zig
build wasm` fails to compile:

```
src/trace.zig:504: error: type 'usize' cannot represent integer value '11400714819323198485'
    h ^= @as(usize, pc) *% 0x9E3779B97F4A7C15;
```

On wasm32 `usize` is **32-bit**, so the 64-bit golden-ratio constant in
`hotIndex` overflows at compile time (and `@intFromPtr(proto)` is 32-bit too).
The line is unchanged at HEAD — this is a latent breakage from an earlier
trace/hotcount change, not the metatable work. Consequence: the committed
`zig-out/bin/mahina.wasm` is **stale**, so `viz/test/diff.test.ts`'s cross-engine
byte-identity check cannot be rebuilt/rerun and its pass/fail reflects an old
artifact (on top of the separate known `arg`-table divergence below). **Fix:**
make `hotIndex` width-correct on wasm32 — hash in `u64` explicitly
(`@as(u64, pc) *% 0x9E3779B97F4A7C15`, fold to `usize` at the end) and use a
stable proto id instead of `@intFromPtr` for the wasm path. The native
`zig build test` gate is unaffected and green.

## tier-0 interpreter perf — next lever (after T1+T3)

Two interpreter wins landed: T1 (inline table array fast-path in
`get_index`/`set_index`) and T3 (hook-elision fast/slow `execImpl(comptime mode)`
split). nsieve tier-0 0.81s → 0.65s (~20%), `--trace --jit-native` 0.33 → 0.28.

**Threaded dispatch (labeled-switch-continue) was profiled OUT, not done.** nsieve
tier-0 has branch-misses at **0.03%** and IPC **4.32** — the interpreter is
instruction-count bound, not misprediction bound, so threading the dispatch switch
buys ~nothing here. Don't revisit it expecting a win unless a *different*
benchmark shows real indirect-branch misprediction (check `perf stat -e
branch-misses` first — the documented "polished the 3%" trap).

The real remaining lever is **fewer instructions retired per opcode**, since we're
near peak IPC. Biggest structural candidate: the `Value` is 16 bytes, so every
`regs[x]` is a 16-byte load and arith goes through tag dispatch — **NaN-boxing to
8 bytes** would roughly halve register traffic. That's a large, determinism-
sensitive change (touches every Value site + the snapshot/replay schema), so it
needs its own design doc + Codex/Antigravity review. Smaller nibbles: the
per-instruction back-edge epilogue check, and tightening the hottest arith arms.

## stdlib `math` — deferred functions

First `math` cut landed in `src/stdlib/math.zig` (the stdlib now lives in
per-library modules under `src/stdlib/`, concatenated into `interp.base_natives`
via each module's `natives`/`constants` slice — not piled into `interp.zig`).
Implemented: `abs ceil floor sqrt exp log sin cos tan asin acos atan deg rad
fmod modf max min tointeger ult` + constants `pi huge maxinteger mininteger`.
`math.modf` landed on the new native multi-return ABI
(`function.NativeMultiFn` + multret-in-last-position for `local`/assignment).
Still deferred, each blocked on a capability mahina doesn't have yet:

> **Update:** *dynamic* multret (the `all_results = 0xFFFF` sentinel) has since
> landed too — `print(f())`, `print(0, f())`, `return f()`, method-call last-arg
> expansion, and `print(table.unpack(t))` all expand fully now (VM `reg_top` +
> safepoint-atomic `reg_top_pending`; compiler emits `all_results` in the call-arg
> and `return` last positions). So `math.frexp` (item 2) really is just "implement
> it" now.

1. **`math.type`** — returns a *string* (`"integer"`/`"float"`/`nil`). Needs heap
   interning, i.e. a `*Vm`/heap in the native. Either thread heap access to the
   pure modules or special-case it like the effect natives. (Forces the only
   `math.*` dependency on `interp`, hence held back.)
2. **`math.frexp`** — returns *two* values (mantissa, exponent). The multi-return
   ABI is ready now (see `math.modf`); just needs implementing alongside the other
   C99 float helpers.
3. ~~**`math.random` / `math.randomseed`**~~ — **LANDED (June 2026).** Now
   namespaced under `math` (the flat `random` global is gone), with all three Lua
   5.4 forms: `math.random()` float `[0,1)`, `math.random(n)` int `[1,n]` (`n==0` →
   full-width int), `math.random(m,n)` int `[m,n]` (`m>n` → "interval is empty"
   bad-argument error). Uniformity comes from our own Mersenne-rejection
   `projectU64` on the pinned `Xoshiro256` word stream (Rule Z-2 — off the churny
   `std.Random.intRangeAtMost`; Lua-*shaped*, deliberately **not** PUC-stream-
   compatible). `math.randomseed(x)` re-seeds deterministically (logs no effect);
   `math.randomseed()` pulls fresh OS entropy through the existing `.random_seed`
   record/replay boundary and returns the single `u64` seed used. Both stay
   Vm-touching natives in `interp.zig` (PRNG + effect log), installed into the
   `math` table via their registry `.module`/`.field`. This finishes the base-host
   tier — only `basic.warn` and `os.clock`'s `partial` remain outside cli-binding.

   **LANDED (June 2026): base-host tier closed.** `os.clock` now returns
   Lua-faithful **float seconds** (`nativeClock`, namespaced under `os`; the
   recorded `.clock` effect now carries the float — the serializer round-trips
   float scalars); the flat `clock` global is gone. Added the mahina extension
   `os.nsclock()` → raw **integer nanoseconds** (shares the `.clock` effect).
   `warn(...)` (Lua 5.4) landed as pure stderr output (`Vm.err`, NOT a recorded
   effect, like `print`): all args must be strings, concatenated to one
   `mahina warning: …` line; a single `@`-prefixed piece is a control message
   (`@off`/`@on` toggle `Vm.warn_enabled`, recognized even while off; unknown `@…`
   ignored). `warn_enabled` is per-session, not serialized.

   **LANDED (June 2026): require/package module system.** `require` + the
   `package` table (`src/stdlib/package.zig`), built on the existing
   `fs_source`/`file_read` effect — base-host, host-injectable loader, no new seam.
   Faithful searchers-as-functions model (`package.searchers` = preload + path,
   both `manual` natives rebound by name on restore). `package.searchpath`,
   `package.loaded` (pre-seeded with built-ins), `package.preload`, `package.path`,
   `package.config`; `package.cpath` is an inert empty field (no native loading
   under determinism), `package.loadlib` stays excluded.

   - FOLLOW-UP (require cycles): a `require` cycle (A requires B requires A) is not
     yet detected with a dedicated "loop or previous error loading module" message —
     it currently bottoms out in `StackOverflow` via `native_reentry_depth`. Lua
     marks `package.loaded[name]` with a sentinel during loading to detect this;
     add the sentinel + a clear cyclic-require error.

## stdlib `table` — deferred functions

First `table` cut landed in `src/stdlib/table.zig`: `insert remove concat move
pack unpack` (all tier `core`, `implemented` in the inventory). Unlike `math`,
these natives take a `*Vm` (heap/alloc), so the module imports `interp` for the
`Vm` type — the mutual import is fine (`Vm` is used only in fn bodies). `unpack`
is a multi native and rides the dynamic-multret path above.

Still deferred:

1. **`table.sort`** — a Lua comparator needs the VM to **re-enter** and call a
   closure from inside a native; there's no `callValue`/`callClosure` entry point
   today, and `arith.lt` is numeric-only (no string ordering). Both are their own
   cuts. Row stays `not-started`.

## Native codegen (tier-1b) — follow-ups

Phase 8 cut 1 landed (x64 encoder + prove-typed int/bool compiler + tier wiring +
`--jit-native`/`--dump-native` + docs/bench). **Cut 2 landed** (register-homed
loop-carried slots + loop-invariant hoisting + single-snapshot deopt +
register-resident transients). **Cut 3 landed** (two-operand in-place arithmetic):
the `acc=acc+i` loop is now ~46× over tier-1a and **~1.10× off LuaJIT** (cut 2 was
~1.8×). Named follow-ups, in rough value order (see
docs/design/05-native-codegen.md §Out of scope):

1. ~~**Relax `guard_int` onto proven-`Int` *derived* values**~~ — **DONE.** Pass A
   no longer bails on a non-`slot_load` guard operand (only `slot_load` guards mark
   the prologue tag-check); Pass B validates a derived `guard_int` against its
   already-computed kind (`Int`-op-of-`Int`s is closed over `Int`) and it lowers to
   nothing. Landed "CSE-able body" (5.40 ms, 33×) and "multi-var" (5.86 ms, 35×) on
   the native path — both were tier-1a fallbacks. Reviewed clean by Codex +
   Antigravity. **Finding:** the multi-op shapes sit ~2.5× off LuaJIT (vs ~1.10× on
   single-accumulator `acc=acc+i`) — the simple loop was overfit-favorable; longer
   operand chains / 2 accumulators expose real codegen headroom (spill/staging on
   chains; win-2 still inert because the loop-exit guard is recorded last).
1b. ~~**Drop dead-temporary writebacks from the exit snapshot ("A")**~~ — **DONE.**
   The recorder now drops compiler expression temporaries (numeric-`for` slots
   `>= base+4`, gated on the `for_loop` whose back-edge *is* the trace anchor) from
   `exit_stores` at `commit()`: they're dead at the loop header (tier-0 recomputes
   on deopt) and after the loop, so the per-iteration writeback was pure waste.
   Closed the multi-op gap — cse `5.40→1.70 ms`, mv `5.86→1.90 ms` (~3× each); both
   now below LuaJIT on these micro-loops. Codex found + helped fix a real
   anchor-attribution bug (a trace passing *through* a non-anchor `for_loop`);
   Antigravity review didn't land (timed out). Follow-ups: (a) **loop-invariant
   konst hoist** — the leftover per-iteration `movabs rNN,konst` for `i+7`, a
   nativegen regalloc/hoisting job independent of the snapshot; (b) **while /
   generic-`for` watermark** — needs a compiler-emitted watermark, no bench
   coverage yet.
2. **Float / mixed / heap traces** — xmm registers, tag dispatch, libm `call`-outs.
3. **Deferred ops** — logical `not`. (`shl`/`shr` LANDED June 2026 —
   branch-bracketed `cl`-shift in `nativegen.emitShift`; `div` and `pow`
   landed after — float divsd and the pow callout. ~~`idiv`/`mod`~~ **LANDED
   2026-08-28, doc 25:** int lane inline cqo/idiv + floor adjust with a
   zero-divisor side-exit and inline (minInt, -1) materialization; float lane
   via shared `fmath.fmodRuntime`/`floordivRuntime` kernel callouts. scalar
   went 4.3× → **0.9× LuaJIT** (−87.6% instructions); en route the oracle's
   `minInt % -1` was found to SIGFPE in every tier and fixed in `arith.mod`
   with a `y == -1` special case.)
4. ~~**Linear-scan register allocation**~~ — **DONE (cut 2).** Loop-carried &
   invariant slots get register/spill homes loaded once; transients get registers
   via forward linear scan; `regs[]` written only on side-exit (single snapshot).
4b. ~~**Two-operand in-place arithmetic**~~ — **DONE (cut 3).** Win 1 (read ALU
   operands straight from their register/spill home + reuse a dying operand's
   register for the result) replaced cut-2's rax/rcx staging and took `acc=acc+i`
   to ~1.10× off LuaJIT. Win 2 (in-place home update + elided back-edge shuffle) is
   implemented behind a single-snapshot safety predicate but **inert on the counted
   loop** (its loop-exit guard is recorded last → predicate cond 1 declines).
   Commits 188251a/1e6a59b/b96ad70/ece721d.
4c. **Sink accumulator updates below the loop-exit guard** — the win-2 enabler on
   counted loops. The recorder emits the back-edge `guard_true` last, so win-2's
   "no side-exit after an in-place home update" condition never holds on
   `acc=acc+i`. A schedule pass that sinks pure ops feeding carried `exit_store`s
   past the last guard unlocks it (sound under cut-2's re-run-from-loop-header
   deopt: a sunk op isn't computed on guard-fail, tier-0 recomputes). Marginal
   (~10% over win-1) but the principled single-`add` form. New transformation →
   fresh plan + Codex/Antigravity review first.
5. **Per-exit identity / side traces** — cut 1 has a single shared exit epilogue.
6. **Proto-id stale-cache hardening** — `AnchorKey` borrows a raw `*const Proto`
   and the cache is never invalidated; a freed-then-reallocated `Proto` at the same
   address could hit a stale trace (now stale *machine code*). Pre-existing in
   tier-1a; surfaced to Bart as a separate task, not expanded into Phase 8.
7. **A wasm codegen backend** — a separate consumer of the same lowering seam.
8. **scimark-sparse trip-decline / recorder-bookkeeping residual (~17% jit>t0).**
   Found while landing the native-unsupported safety net (June 2026). `--jit-native`
   leaves scimark-sparse ~17% slower than pure tier-0, but it is **not** a
   native-unsupported / tier-1a problem (the safety net is inert here: gates=0,
   skips=0, entries=0). Root cause: the hot inner kernel
   `for i=row[r],row[r+1]-1 do sum=sum+vx[col[i]]*val[i] end` runs exactly
   `nr=floor(nz/n)=floor(5000/1000)=5` trips — below `min_trip_entry=24` — so dispatch
   **trip-declines** entry every invocation and the trace never runs (native or
   tier-1a). The cost is pure trace-dispatch bookkeeping on a short hot loop nested in
   a hot outer loop: per-back-edge `onBackEdge` (hashmap getOrPut) + `isGated` +
   `armShortLoopSkip`, plus the middle loop (`for r=1,n`, 1000 trips) which never
   commits a trace and re-pays `onBackEdge` + fingerprint-miss every back-edge. Pure
   tier-0 (no `--trace`, `config.enabled=false`) skips all of it. Addressable only by
   cheaper warming-loop bookkeeping or by tracing the middle loop with the inner loop
   unrolled — neither is the safety net nor shift codegen. Distinct, pre-existing
   JIT-coverage issue.
9. **Int-lane astore of a constant bails native (guard_fits DCE'd).** Found while
   landing shl/shr (June 2026) by diagnosing why nsieve-bit's array-init loop
   `for i=0,(m>>6) do p[i]=-1 end` stays native-unsupported (`trace #2`) on the
   2nd/3rd `nsieve` call (in-bounds store into the reused `primes` table). The
   recorder emits a `guard_fits` ahead of every int-lane `astore` (trace.zig:1712),
   but `tropt` **DCE's it when the value is a constant** that provably fits the lane
   — so `proveKinds`' unconditional `if (!fits_ok[ins.b]) return false`
   (nativegen.zig int-lane `astore` arm) rejects the trace. This is the *exact* case
   already exempted for the **f64 lane** (the `astore` requires no `fits_ok` because
   a `movsd` never narrows; nativegen.zig:~624 comment) and the **bool lane**. The
   narrow int lanes (i8/i16/i32) genuinely need the range check for *free-variable*
   stores, but a constant that survived `tropt`'s fold provably fits — the fix is to
   admit a constant (or otherwise statically-in-lane) int `astore` value without a
   covering `guard_fits`, mirroring the f64/bool exemption, while still requiring it
   for free-variable int stores. Determinism subtlety: must prove the constant fits
   the *recorded* lane width (the prologue `guard_lane` pins it), so a later
   wider-lane store still side-exits. Net effect: would unlock the init loop's
   constant fill to native (currently 100% tier-0). Distinct from shl/shr; new
   nativegen analysis change → fresh plan + Codex/Antigravity review first.

### Native shl/shr lowering (nsieve-bit shift loops) — LANDED (June 2026)

`shl`/`shr` now lower to native (`nativegen.emitShift`): a **branch-bracketed
`cl`-shift** that reproduces Lua's shift semantics (`arith.shiftLeft`/`shiftRight`)
exactly — the x86 `shl/shr reg,cl` only honours the low 6 bits of the count, so the
lowering brackets the hardware shift with explicit range checks: count `< 0` →
negate and shift the other direction; `|count| ≥ 64` → result 0; else the bare
`cl`-shift. Confined to `nativegen.zig` (proveKinds Int arm, `isTransient`,
`operandReads`, `emitShift`, lower dispatch) + `x64.zig` (`shlRegCl`/`shrRegCl`,
`Cond.s`) — **no** new IR op, no recorder/snapshot/irinterp/tropt change (shl/shr
stay opaque ops; only native lowering was added). Uses only the dst register (or rax
for a spilled dst) + rcx scratch, so it fits the cut-2 allocator's two scratch
registers regardless of operand homes (count loaded into rcx *first*, since the
allocator may reuse a dying operand's home as the result reg). Differential-tested
vs the tier-1a oracle across every count regime (in-range, ≥64→0, negative→reverse,
INT64_MIN). Measured: nsieve-bit **t0 139 ms → jit 55 ms (2.5× native win)** — the
two shift-bearing inner loops now compile native (538 + 448 bytes); previously they
were the native-unsupported traces the Part 1 safety net retired to tier-0. (The
array-init loop `trace #2` stays unsupported for the separate constant-store reason
in item 9 above.)

### f64 array lane (Phase D Gap A) — LANDED (June 2026)

The float (`.f64`) array lane now lowers to native (`nativegen.zig`): `laneKind`
admits `.f64 → .float`, the `aload` arm classifies a loaded double as `.float`, and
the `aload`/`astore`/`guard_fits` lowering arms mirror the int lanes with `movsd`
(`lea` addr → `movsd` load into the XMM/spill home; stage value → `movsd` store +
presence `bts`; `guard_fits` no-op). The f64 `astore` requires **no `fits_ok`** (a
full-width `movsd` never narrows — mirrors the bool lane, not the narrow int lanes),
so a constant-float fill compiles even after `tropt` folds the redundant guard.
Measured: pure float read reduction **13.9×** over tier-0, constant fill **9.0×**
(both were 0% native before); ~4–7× off LuaJIT now (codegen tightness, not coverage).
8-mode byte-identical (read + fill e2e in `interp.zig`); nativegen unit tests for the
write + idempotent-deopt-replay. Reviewed by Codex + Antigravity, Bart-approved.

**Gap B (store-sinking) — LANDED (June 2026, doc 07):** the scimark hot loops are
read-modify-write (`vi[k] = vi[k] - eij*vj[k]`) and array copies, which the recorder's
old **C1 rule** (`trace.zig` `recArraySet`: any `astore` after any `aload` →
`.bad_type`) aborted — so scimark-lu/sor were unmoved by Gap A (jit ≈ t0). Lifting C1:
the recorder now **defers the single RMW `astore` and re-emits it in `commit()` just
before `.loop`** — below every loop-exit guard. No side-exit can follow the store, so
coarse deopt never re-runs a half-applied iteration (tier-0 re-runs the iteration from
the loop header and stores exactly once). Constrained to one store that is the trace's
*last* array access (any later aload/astore/append aborts). Measured: scimark-sor
**46.9× → 4.5×** vs LuaJIT (10.5× over tier-0), scimark-lu **74.5× → 12.4×** (6×).
8-mode byte-identical (RMW `expectProgram` e2e in `interp.zig`; recorder + nativegen
unit tests). Reviewed by Codex + Antigravity (design + implementation).

**Gap C (multi-store) — LANDED (June 2026, doc 08):** generalized Gap B's single
deferred `astore` to a bounded ordered set (`MAX_PENDING_STORES = 4`) flushed
front-to-back in recorded (bytecode) order below every guard, so FFT's butterfly (4
reads then 4 RMW stores to two indices) records + runs native. A second/third/fourth
in-bounds RMW `astore` now appends to the pending set instead of aborting; a post-store
`aload`/`astore_append` or exceeding the cap still aborts cleanly. Measured: scimark-fft
**54.3× → 39.1×** vs LuaJIT (t0 993.9 ms → jit 715.7 ms; 1.39× over tier-0; `cross=ok`).
8-mode byte-identical (two-store butterfly `expectProgram` e2e + recorder/nativegen
units). **Remaining scope:** sparse (indirect `x[col[k]]` gather, not a same-index RMW)
stays ~35× off LuaJIT; FFT's remaining gap is structural coverage (bit-reversal +
non-butterfly work still tier-0), not codegen tightness.

**Tier-0 array decode/encode fast path — LANDED (June 2026):** profiling pure tier-0
(no `--trace`) of the array-heavy scimark kernels showed the bottleneck is NOT dispatch
(the interpreter `jmp` is 0.46%) but `array.ArrayPart.decode` — 55% of scimark-sparse /
11% of scimark-fft, as an *out-of-line call per element* across the interp.zig→array.zig
module boundary. Fix (src/array.zig only): (1) marked `get`/`setInLane`/`decode`/`encode`
`inline` so the read/write chain folds into `execImpl` (the loop-invariant lane `switch`
hoists; the per-element call vanishes — decode dropped from a 55% symbol to fully inlined,
execImpl 98%); (2) removed a gratuitous `@memcpy` stack-buffer round-trip in
`readInt`/`writeInt` (byte-identical, same `.little`). Tier-0 wins, all `cross=ok`:
scimark-sparse 866→770 ms (~11%), lu 1162→1019 (~12%), sor 953→871 (~9%), fft 994→911
(~8%); other benches flat (not decode-bound). NaN-boxing was explicitly ruled out — the
16-byte tagged `Value` is foundational to determinism+replay; this cuts cost *around* the
Value. Reviewed (Codex + Antigravity, both sound). The remaining `execImpl` cost is
inherent 16-byte `Value` register-file shuffling (`vmovapd` spills + `×16` offsets), not
addressable without changing the Value rep.

**Minor finding (pre-existing, int lanes):** a constant-int *fill* (`a[k] = 7`) also
fails to compile — `tropt` folds its `guard_fits` (the constant provably fits), so the
int `astore` arm's `fits_ok[value]` requirement is never satisfied → bail. Unlike f64
(full-width, every value fits), a narrow int lane genuinely needs the range proof, so
the fix would be a proveKinds path that range-checks a *constant* store value directly
(at prove time) instead of relying on a runtime `guard_fits`. Low priority; not a
regression (predates Gap A). Noted so it isn't re-discovered as a bug.

## Benchmark north-star: run a real LuaJIT bench (`~/Projects/LuaJIT/bench/`)

Goal (Bart): pick a real LuaJIT benchmark to *work toward* end-to-end on mahina, even
if unrunnable today — it defines the feature roadmap. None of the bench/ programs
run verbatim: they all need `tonumber`, `io.write`, `string.format`, `unpack`,
generic-`for`/`pairs`, `repeat/until`, `math.*`. mahina now has most of these
(`math.*`, `table.*` incl. `unpack`, `tonumber`/`string.format`/`io.write`,
generic-`for` + `pairs`/`ipairs`/`next`, `repeat/until`, and bare varargs `...` —
see below). Remaining vararg work: named `...rest` (`#rest`/`rest[i]`), keyframe
persistence, and `{...}`/`{f()}` table-spread.

### ~~Generic-`for` + `pairs`/`ipairs`/`next` (deterministic iteration)~~ — DONE
`for v1..vn in explist` now compiles (`compiler.compileGenericFor` → one new
`tfor_loop` opcode; the per-iteration iterator call is a real bytecode `.call`, so
closures and natives both work with no VM re-entrancy). The basic-library iterators
live in `src/stdlib/base.zig`: `next`/`pairs`/`ipairs` plus a hidden `@ipairs_iter`
(un-spellable name, GC-root + keyframe-restorable by name). `next` walks the array
part ascending then the hash part in **canonical key order** (tag → heap id → bits),
lifted into `src/key_order.zig` and shared with the keyframe serializer — so a
mid-iteration snapshot resumes the exact same traversal (F2c corpus covers it).
First cut sorts the hash keys **on each `next` call** (correct, trivially
snapshot-safe). **Follow-up:** a per-table lazily-built sorted-key cache for `next`,
invalidated at the four hash key-set mutation sites — pure perf, behind the same
D1-D9 tests.

### ~~`repeat ... until cond` (post-test loop)~~ — DONE
`repeat`/`until` are now lexer keywords, an `ast.repeat` node, a parser
`parseRepeat`, and `compiler.compileRepeat` (no new opcode — reuses
`jmp_if_false` as a backward branch, the post-test mirror of `while`). The Lua
subtlety that `until`'s condition sees locals declared in the body is handled by
reserving the condition register *below* the body scope so it survives `endScope`'s
register pop, letting `endScope` close per-iteration upvalue cells normally before
the back-edge. Covered by compiler unit tests, an all-modes e2e, and a mid-loop
keyframe resume in the F2c corpus.

### ~~Bare varargs `...` (zero-copy stack cursor)~~ — V1+V2 DONE
A vararg function's surplus arguments already sit in a stable, GC-rooted region of
the shared `stack` (the `.call` ABI copies only `num_params` and *drops* the rest,
but never reallocates the slab), so varargs are a **zero-copy cursor**
`(varargs_base, varargs_count)` on `CallFrame` — no heap object, no new `Value`
kind, no allocation. Four opcodes read the current frame's cursor: `vararg_first`
(single-value position), `vararg_len` (`#`), `vararg_get` (1-based, bounds-checked
index), and `vararg_spread` (the dynamic-`reg_top` multret producer, bounded vs
`stack.len`). The compiler lowers bare `...`: first-value in single position,
per-slot `vararg_get` with constant indices for a destructure (`local a,b = ...`,
nil-padded), and `vararg_spread` + a consuming `call`/`ret` in every expanding
position — forward `f(...)`, `g(x, ...)`, `obj:m(...)`, `return ...`, and a nested
`f(g(...))` (the trailing-arg expansion was unified into `compileArgList` /
`compileMethodArgs` so an inner call's own trailing `...` also spreads). `(...)`
truncates to one value via the existing `.paren` node. `...` outside a vararg
function is a clean compile error. Trace recorder aborts (`nyi_opcode`) on the four
opcodes, so vararg functions never form a trace. Covered by V1 VM unit tests,
compiler diagnostics, three all-modes e2e programs, and a determinism-corpus entry.
**Remaining:** V3 named `...rest` (`#rest`/`rest[i]` + capture diagnostic), V4
keyframe persistence (frame schema + version bump + suspend-in-vararg F2c), and the
`{...}`/`{f()}` table-spread follow-up (also fixes the latent `{f()}` bug).

**Recommended target: `nsieve.lua`** — integer + boolean + tables, numeric-`for` hot
loops; closest to mahina's int/bool tier-1b strength and drives the natural next
expansion (heap/table ops in native codegen). Incremental roadmap:
  1. ~~derived `guard_int`~~ — DONE (#1 above; unlocks pure-int derived loops).
  2. ~~**Minimal host stdlib** for the harness~~ — **DONE.** `tonumber`,
     `string.format` (fuller printf: `d i u o x X c f F e E g G s q %`, flags
     `- + space 0 #`, width, precision), `io.write`, and the `arg` global table.
     nsieve runs end-to-end on tier-0/1a and prints **byte-identical to LuaJIT**
     (verified N∈{1,4,6,9}, Debug + ReleaseFast). Module fns (`string.format`,
     `io.write`) live in `base_natives` with `module`/`field` qualifiers so keyframe
     restore resolves them by name; `arg` is populated at the host boundary
     (main.zig) to keep the VM exec core deterministic. A latent keyframe-serializer
     fragility (std.HashMap insertion-order slot layout) was surfaced by the larger
     globals table and fixed with canonical (sorted) hash-part serialization —
     reviewed clean by Codex. **This is the correctness milestone; hot loops still
     interpret.**
  2b. ~~**Table array-part rehash** (Lua `computesizes`)~~ — **DONE.** Profiling found
     nsieve's keys lived entirely in the **hash part** (it sets `t[2..m]`, never
     `t[1]`, and mahina only grew the array on a contiguous `len+1` append) — the cause
     of *both* the ~6× memory and the fact that a tier-1b array fast path could never
     fire. `Table.set` now runs Lua's histogram-driven rehash (`src/table.zig`:
     `rehash`/`computeArraySize`/`countKey`, density gate `na <= nh*3`), migrating
     dense integer runs into the array part. **Result (N=11): memory 1.6 GB → 320 MB
     (~1.2× LuaJIT), time 32 s → 4.7 s** (~7× LuaJIT, was ~46×) — array indexing beats
     hash probing even on the interpreter. Output still byte-identical (N∈{1,4,6,9,11}).
     Codex review found + fixed a double-count-on-update and an O(n²) sparse-insert
     path; Antigravity timed out (one clean review). Keyframe round-trip stays
     byte-identical (rehash never runs on restore). Residual ~1.2× memory vs LuaJIT is
     Value width (16 B vs 8 B) — a separate packing step.
  3. **tier-1b heap/table support** — array load/store in native codegen so the hot
     inner loops (`p[k]=false`) actually JIT. **Now unblocked** by 2b (keys are in the
     array part). Needs recorder IR ops (`tget`/`tset` + `guard_table`/
     `guard_array_bounds`), irinterp execution, x64 SIB indexed addressing, nativegen
     lowering. **← next north-star item.**
  4. head-to-head vs `~/Projects/LuaJIT/src/luajit`.
Alt target `mandelbrot.lua` instead drives **float/xmm** tier-1b (follow-up #2) — the
second north-star once floats land. (Pick not locked; revisit with Bart.)

## ~~Recorder: intern duplicate konsts at record time~~ — DONE

**Resolved.** The recorder now interns constants: `TraceState.konst` keys a
`AutoHashMap(KonstKey → Ref)` on the value's tag + payload bits and reuses an
existing `konst` instruction's ref (and pool slot) for a recurring literal
(`src/trace.zig`). Slot reads were already cached by `refOf`, so with konsts
deduped, identical subexpressions get identical operand refs and the optimizer's
CSE collapses them. Verified end-to-end: for `acc + (i + 7) * (i + 7)`, the two
`i + 7` adds merge to a single ref and the multiply becomes `mul %4 %4` (see the
`--dump-traces` opt-vs-no-opt contrast and the tests in `src/interp.zig`:
"recorder: a recurring literal is interned…" and "konst interning lets CSE
collapse a repeated subexpression end-to-end").

### Optional follow-on (not needed for the common case)
General hash-consing of *arbitrary* pure subexpressions at record time (beyond
konsts + the existing slot-read cache) would let CSE merge structurally-identical
expressions that don't share operand refs by construction. Low priority — konst
interning + slot caching already cover the common recurring-subexpression
patterns. Revisit only if a real trace shows un-merged duplicates.

## ~~Generated TS codec: wrong discriminator field for *nested* unions~~ — FIXED upstream

**Resolved (binschema `aa0a270`).** The vendored TS decoder mis-decoded a
discriminated union sitting in a NAMED struct field (vs an array element): it
emitted `x.key.tag = readUint8()` for the tag read but branched on `x.tag`
(undefined), so every branch missed and it threw
`Unknown discriminator value: undefined`. This broke `EffectDecoder` (effect
logs) and `SnapshotFileDecoder` (any keyframe with a table — `TableEntry.key`/
`.val`, plus `HeapUpvalue.value`). Array-element unions (`Keyframe.stack`,
`HeapTable.array`) and the standalone `SnapValueDecoder`/`TraceFileDecoder` were
unaffected, which is why traces decoded but snapshots/effects didn't.

Root cause was in the generator (`~/Projects/binschema`
`packages/binschema/src/generators/typescript.ts`): the discriminator-branch
condition was resolved against the enclosing scope instead of the inlined
struct's local path. Reported in `binschema/BUG-nested-union-named-field-ts.md`
with a minimal repro; fixed in `aa0a270` (TS + Go). Both codecs were regenerated
here via `tools/regen-trace-schema.sh` (binschema `aa0a270`); the Zig codec was
already correct so only `viz/src/gen/generated.ts` changed. `viz/src/snapshot.ts`
uses the generated `SnapshotFileDecoder` directly — no hand-rolled byte reader.

Now-unblocked follow-ons (separate from the v8 replay work): a *structural*
divergence view in `diff.ts` (decode both sides, show the first differing field)
and a keyframe/effect inspector panel.


## viz `diff.test.ts` "wasm ≡ native" fails — `arg` global heap divergence (host setup)

The cross-engine byte-identity test (`viz/test/diff.test.ts`) fails on every
integer/float case. Root-caused (not E0): the **native** host (`main.zig`)
populates an `arg` global table from process args, while the **wasm** host
(`wasm_entry.zig`) injects a null env/args source (argc=0, argv=nil). So the
native keyframe carries one extra heap object (the `arg` table, +44 bytes) the
wasm keyframe lacks — even for a no-trace program like `print(1)`. Trace bytes
are byte-identical across engines; only the keyframe heap differs. This is the
env/args stdlib feature (tasks #98–102/#132–137), not the trace/phi work.
**Fix (concurrent stdlib task's call):** either have the wasm host also build an
empty `arg` table, or teach the diff test to tolerate the host-injected `arg`
global. Flagged here per Rule #10; left for that task's owner.

## tier-1b: "CSE-able body" / "multi-var" bench programs fall back to tier-1a
Confirmed via instrumentation: both bail in **`proveKinds`** (the stage cut-2 did
not touch — NOT a regression). Root cause is exactly follow-up #1 above: the
recorder emits a `guard_int` on a *derived* value (`i+7`), and Pass A only proves a
`guard_int` whose operand is a `slot_load`. Fixing #1 (relax `guard_int` onto
already-proven-`Int` derived values → no-op) lifts this fallback. Tracked under #1;
no separate work item.

## Native int store: constant-value stores stay tier-1a (pre-existing, shared)
A constant int store into a narrow lane (`t[i]=7`, both in-bounds `astore` and
grow `astore_append`) does NOT lower to native: the trace optimizer folds the
provably-in-range `guard_fits`, so `proveKinds` finds no `fits_ok` proof for the
value and rejects the trace. Dynamic values (`t[i]=i`) are unaffected and compile.
Fix (separate, benefits both store paths): in `nativegen.proveKinds`, treat an
int-lane store value as fits-proven when it is a `konst` whose constant fits the
guard_lane-pinned lane width (sound: guard_lane pins the lane, so an in-range
constant always fits). Noted while landing Phase B (int astore_append).

## Phase B int astore_append: WIDEN-FLICKER — FIXED (widen-eviction)
The headline idiom `for i=1,N do t[i]=i end` crosses i8->i16->i32; each monotonic
widen permanently invalidates the current-lane trace, but the stale trace lingered
in a per-anchor slot and the wider-lane steady state never got a stable trace
(~88% tier-0). Fixed by widen-eviction: when a trace side-exits with completed==0
and the live array's lane has monotonically widened past the trace's `guard_lane`
lane (`!live.canWidenTo(trace_lane)`, array.zig), the trace is permanently dead, so
we retire it (`removeTrace`) and reset the anchor's hot-counter so the stabilised
wider lane re-records. The dispatch walk was also made visit-once
(`nextTraceExcluding`) — the old `findNextTrace(skip)` cursor could cycle A->B->A
forever once two stale-lane traces coexisted (latent bug the eviction exposed).
Result: a fresh-table fill crossing i8->i16 runs 0.06s native vs 0.22s tier-0
(~3.7x). Output byte-identical across all 8 modes (eviction never affects output —
tier-0 stays the oracle).

### Known limitation (gate-bounded, output-safe): polymorphic-anchor thrash
A genuinely bi-hot anchor — same loop PC alternately filling an i8 table and an i32
table — can record+evict the narrow-lane trace repeatedly (eviction only fires when
the live lane is WIDER, so the i32 trace is never evicted by an i8 table, but the
re-recorded i8 trace is evicted whenever the i32 table flows). This is deterministic
and output-safe; the existing penalty->gateAnchor cooldown bounds the repeated
low-yield re-entries. Monomorphic fills (the target) are unaffected. If it ever
shows up in a profile, gate re-recording on a per-anchor widen-eviction count.

## Phase B int astore_append: loop-INVARIANT int value (t[i]=v) is "unsupported"
`local v=1000; for i=1,N do t[i]=v end` records but proveKinds rejects the trace (the
invariant value isn't proven .int / fits-covered after loop-invariant handling). Smaller
follow-up; affects another common fill idiom. Characterise + fix alongside the flicker.

## stdlib pattern pass — follow-ups (string.find/match/gmatch/gsub landed)
- **gsub function replacement** — DONE (chunk-1 foundations). `Vm.callValue`
  (the call-into-VM-from-native primitive) landed; `addReplFunction` drives the
  replacement per match. CSV row is `implemented`. Same primitive unblocked
  `table.sort`'s comparator.
- **Misleading native-error messages** — DONE (error-message cheap-wins batch).
  `describeFault`'s `.call` arm now only emits "attempt to call a <type> value"
  for a genuine non-callable; a native-internal fault renders `"bad argument to
  '<name>'"` (located), and converted `*Arg` checkers raise the full detailed
  `Vm.badArg` message. See the "Native-raised fault messages …— DONE" section
  below.

## Native-raised fault messages are misattributed to the call site — DONE

Fixed in the error-message cheap-wins batch. The keystone was the shared
`Vm.callSiteAt(level)` locator (interp.zig): when a native faults inline in a
`.call`, its caller frame still holds that `.call`, so the native's name and the
source location are recoverable from the live call site without threading.
- `describeFault`'s `.call` arm now distinguishes a native-internal fault (→
  `"bad argument to '<name>'"`, located) from a genuine non-callable (keeps
  `"attempt to call a <type> value"`).
- `Vm.badArg(n, expected, got)` / `Vm.badArgReason(n, reason)` raise the full
  Lua-style `"<chunk:line>: bad argument #<n> to '<fn>' (…)"`; the shared
  `*Arg` checkers in string/table/basic/base route through them. `math.zig`
  stays a pure module (no `interp` import) and uses the generic located arm.
- `synthErrorValue` now prefixes `chunk:line:` on caught bare runtime faults too
  (matching Lua's caught-error value format). Deterministic across all 8 modes
  (proto name is static, line derives from a source offset).
Remaining (metatables chunk): `__tostring` on error objects; richer context.

### Known limitation: indirectly-called natives misattribute the arg-error name

When a native is invoked *indirectly* through another native — e.g.
`pcall(string.sub, nil, 1)` or `pcall(math.floor, "x")` — the bad-argument
message names the **outer** native (`pcall`), not the faulting one (`sub`):

```
pcall(string.sub, nil, 1)  → bad argument #1 to 'pcall' (string expected, got nil)   (Lua: 'sub')
```

Root cause is structural and the mirror image of the fix above: `Vm.callValue`'s
native path runs the target native inline **without pushing a frame and without a
`.call` instruction**, so `callSiteAt(1)`/`nativeSite` find the live call site of
the *outer* native instead. The **direct** call form
(`(function() return string.sub(nil,1) end)`) is correct — only the
native-invokes-native indirection is wrong, and it's an uncommon pattern.

Proper fix (deferred — needs a new mechanism, not a hack): have `callValue`'s
native path set a "currently-invoked native" context (name + the caller's
call-site) that `nativeSite` consults *before* falling back to the live `.call`
frame, then clears on return. Confirmed by both reviewers (Codex, Antigravity)
during the cheap-wins review.

## error(msg, level) location prefix — DONE

`nError` (stdlib/errors.zig) honors `level`: a string message gets a
`chunk:line:` prefix from `Vm.raiseLocatedError(bytes, level)` (level 1 = the
function that called `error`, level 0 = no prefix), reusing the shared
`callSiteAt` locator. Non-string messages pass through verbatim. CSV `error`
row flipped to `implemented`.

## String ordering (`<` `<=` `>` `>=` on strings) — DONE

`arith.lt`/`arith.le` (`src/arith.zig`) now compare two strings lexicographically
by byte (`std.mem.order`), keeping mixed string/number a `TypeError` exactly as
Lua does. `table.sort` on a string list with the default comparator works. Safe
for the JIT: `recCompare` (trace.zig) aborts a compare whose operands aren't
numbers, so string ordering only ever runs on tier-0/1a, never inside native
trace code. Parity tests in interp.zig ("strings: …").

## LuaJIT 3.0 syntax extensions — parity survey + decision log (June 2026)

> **Promoted to `docs/design/13-luajit-syntax-parity.md` (June 2026).** That doc is
> now the contract (decisions, semantics-to-match, phasing checklist). Keep edits
> there; this section is retained as the original scratch/survey for context.

Mike Pall is formalizing a "Lua-shaped, not Lua-compatible" syntax-extension set
for LuaJIT 3.0 — the same thesis as mahina. Source of truth is the evolving spec in
the **first comment** of LuaJIT/LuaJIT#1475 (full per-operator semantics), with the
backport scope/checklist in #1476 and the instrumentation-ABI call in #1457. Policy
Bart set: **match LuaJIT's exact semantics unless we have a specific reason not to;
where semantics must diverge, keep the *syntax* aligned.**

Precedence foundation is already aligned: mahina's Pratt binding powers
(`infixBp`, src/parser.zig:485-512) match Mike's published precedence table for
every shared operator, including the bitwise ordering (`&` > binary-`~` > `|`,
between shifts and comparison). New operators have well-defined slots: `?.` at
index/call level, `??` at `or` level, `?:` just below `or` (right-assoc).

### Decision log (Bart, June 2026)

| # | Operator(s) | Decision |
|---|-------------|----------|
| 1 | `//` by zero (& general error policy) | **Fail loud / throw.** Syntax matches LuaJIT, semantics diverge (no `inf`/`nan` result). Fail-loud is mahina philosophy; it is *not* a JIT tax — a throw is deterministic control flow (replay-safe), and on a guarded-upstream hot path the cost is one predictable branch the optimizer can eliminate as a redundant guard. What hurts a trace is the exceptional path being *taken*, not its existence. |
| 2 | `& \| ~ << >> ~>>` (bitwise) | Keep **syntax** aligned; **64-bit native** semantics — deliberate divergence from LuaJIT's 32-bit `bit.*` (mahina has no `bit` library; native i64 ops, see "stdlib `math`"/bitwise notes above). |
| 3 | `~>>` arithmetic right shift + `~>>=` | **Add** — completes the operator set. Currently mahina has `>>` (logical) but no `~>>`; add the token (`~>>`), AST op (e.g. `sar`), and compound form. |
| 4 | `! && \|\| !=` (customary operators) | **Add** as pure aliases for `not`/`and`/`or`/`~=`. Two-ways-to-write is acceptable here (Bart writes `&&`). Identical semantics. |
| 5 | `??` (nil-coalescing) | **Add.** Checks **pure nil only** (the only nil mahina has — no NULL cdata). Eval `a` once, short-circuit `b`. |

### Still on the table (not yet decided) — exact semantics to match when we do

- **`?:` ternary** — right-assoc, short-circuits; the wart to replicate: `b` can't
  directly hold `obj:method()` (parse ambiguity) → requires parens.
- **`?.` safe navigation** — trickiest. Match: `?.[key]` not `?[key]`; whole-chain
  short-circuit (`foo?.a.b` → nil, but `(foo?.a).b` throws — JS-identical, Mike
  confirmed); works on assignment LHS too (unlike JS); method form `obj?.:method()`.
  Full placement table in the #1475 spec.
- **Compound assignment `+= -= *= … ..=`** — eval prefix once
  (`x.y.z.field += b` → temp `x.y.z`). Gotchas: `~=` becomes xor-assign in
  *statement* context (no ambiguity — inequality `~=` is expression-only); **no
  `^=`** (deliberately omitted by Mike); his table has a typo (`&=` shown as
  `a = a ^ b`, means `a = a & b`).
- **`??=`** — short-circuits `b`.
- **`continue`** — landmine is `repeat…until` where `continue` jumps into a local's
  scope referenced by `until`. Mike rejects continue-into-scope; he can afford the
  analysis (3.0 parser is SSA). mahina is tree-walk+JIT → needs its own equivalent
  check, not a verbatim lift.
- **Underscores in number literals** — `1_000_000`. Lexer-only.

### Don't chase yet (Mike hasn't frozen the syntax)

`const` (soft keyword, leaning `const` over `<const>`), short-function
(`|…| -> expr` / `|…| -> do … end`, TBD), string interpolation ("needed?"), and
**match/switch** (novel `in expr do … end` with `=>` arms, mid-design). Matching
now = matching a moving target.

### Adjacent: #1457 instrumentation ABI

Mike is proposing near-zero-overhead VM instrumentation (map machine-code addr →
trace number, per-trace details, frame walking) so external profilers don't
disassemble the VM. That's the introspection surface our trace visualiser /
time-travel replay already owns natively. Worth lurking as a gap-check on what a
tracing JIT "should" expose.

## Pre-existing tier-1a crash: driveChain .ir on a `%`-in-outer-body nested loop (found 2026-07-14 during 2c-E)

Repro (crashes at HEAD d4d82d9 too — NOT introduced by 2c-E; tier-0 and
`--jit-native` both print 2552):

```lua
-- /tmp/probe1.lua ; ./zig-out/bin/mahina --trace /tmp/probe1.lua
local s = 0
local m = 30
for i = 1, 300 do
  if i == 60 then m = 2 end
  for j = 1, m do s = s + 1 end
  s = s % 100000007 + 1
end
print(s)
```

Panic: `invalid enum value` in `regwindow.get` (reading a register tag), from
`irinterp.execute(sct, …)` called by `driveChain` tier `.ir` at trace.zig:1469
(the `.ir_numeric_for_done` dispatcher chain, interp.zig:2878). The sct being
entered is presumably the `%`-containing continuation (it also nativegen-bails:
`--dump-native` says "trace #1: unsupported"). Looks like the tier-1a chain
enters a continuation whose trace reads a register slot the window never wrote
(uninitialized tag). Reduce + fix separately.

## Pre-existing: `zig build wasm` is broken (64-bit assumptions on wasm32; found 2026-07-14)

Discovered while wiring the `build_options` module into the wasm module tree for
jitdbg (which itself compiles fine there). Three errors, all at HEAD before that
change too:

- `src/trace.zig:859` (`hotIndex`): `@as(usize, pc) *% 0x9E3779B97F4A7C15` — the
  64-bit golden-ratio constant can't fit `usize` on wasm32. Needs `u64` math (or
  a 32-bit mixer) with a truncate to index width. From the direct-mapped
  hotcount arc.
- `src/value.zig:132` (`rowViewParent`): `payload.bits & row_view_ptr_mask` is
  `u64`, `@ptrFromInt` wants `usize` — needs `@intCast`/`@truncate` on 32-bit
  targets. From the RowView arc.
- (third error is a duplicate of the hotIndex one via a second reference path)

Nothing gates `zig build wasm` in `just test`, so it rotted silently. Fix +
consider adding the wasm build to CI/justfile as a compile-only gate.

## ~~Pre-existing: `nextLoggedEffect` advances the cursor before validation~~ FIXED 2026-08-28 (Bart chose validate-before-advance)

Was: `nextLoggedEffect` bumped `effect_cursor` BEFORE the caller validated the
entry, making `noteUnicodeVersion`'s mismatch path self-erasing — the
wrong-version entry landed BEHIND the cursor, so a later `noteUnicodeVersion`
on the same VM took the `versionAlreadyConsumed` prefix scan and silently
pinned the MISMATCHED table. Fixed with the peek/commit split: the cursor now
advances only on acceptance (`nextLoggedEffect` kind-checks before advancing;
`noteUnicodeVersion` peeks via the new `peekLoggedEffect`, validates the
version, and consumes only on success) — cursor position is now a truthful
"consumed successfully" record, which is the documented contract on both
functions. Regression tests: the self-erasing retry (direct
`noteUnicodeVersion` re-raise), the kind-diverged cursor hold, and cursor/pin
asserts on the corrupt-float leg. Found while testing: a top-level re-`run` of
the faulted VM was ALREADY refused by `beginTopLevelEpoch`
(`DirtyTopLevelEntry`) — see the amendment on the faulted-but-live entry
below; the seam this fix closes is host-driven calls / resumed sessions.

## Pre-existing: faulted-but-live VM can be re-run without resetting depth/stack_top (found 2026-07-17, doc-17 F-7 grounding)

**AMENDMENT 2026-08-28:** partially stale. `beginTopLevelEpoch`
(interp.zig:1278) now fail-closes on `depth != 0` with `DirtyTopLevelEntry`,
so a host calling `run` again on a faulted-but-live VM IS refused (verified by
the doc-26 cursor-fix regression test, which had to route its retry through
`noteUnicodeVersion` directly because the re-`run` path is shut). What remains
of this entry: entry points that do NOT pass through `beginTopLevelEpoch`
(host-driven `callValue`-style invocation) still land on the raised
depth/stack_top, and depth/stack_top are still never reset after a fault.

Non-catchable / uncaught errors deliberately leave `vm.frames`/`vm.depth`/`stack_top`
raised so `describeFault` can read the live top frame (`interp.zig:1215-1223`,
`callValue` `:1454-1457` — the "errors don't unwind frames" invariant). But there is
NO error-exit hook and NO poisoned-VM guard: a host that calls `run`/`start` again on a
faulted-but-live VM does NOT trip an assert, and `run` (`:1025`) only disarms native
links (`beginTopLevelEpoch`) — it does NOT zero `depth`/`stack_top` before pushing the
new main frame. So `pushFrame` (`:1350`) writes `frames[self.depth]` at the leftover
nonzero depth → the new run's main frame lands on top of the faulted stack instead of
index 0. Latent; only bites a host that reuses a VM after an uncaught error. Fix options:
zero depth/stack_top in `beginTopLevelEpoch`, or a poisoned-VM precondition. Orthogonal
to exit-branch patching (doc 17); noted here so it isn't lost.

## nsieve historical drift: July baseline was ~60ms jit, now ~103ms (2026-08-12)

The A-vii-e protocol compared against the immediate pre-flip commit (9ee7d4b,
~101ms bench jit at N=7) — but the July full-suite baseline
(bench/results/20260715-101717-0753b7d.tsv) had nsieve jit at 60.2ms. Something
between 0753b7d (July 15) and 9ee7d4b (Aug 12) cost nsieve ~40ms — plausibly the
A-vii-c gate-consumption flip or config changes, but unmeasured. Out of scope for
the A-vii-e arc (its baseline was the pre-flip tree by design); worth a bisect
before trusting "nsieve is at its historical best".
## B2b: a lane-polymorphic anchor gets thrash-gated on prologue refusals (2026-08-30)

Found while measuring doc 32. `Av` in spectral-norm is called alternately over `u`
(`.value`) and `v` (`.f64`) — ONE anchor, TWO array lanes. The committed trace is
compiled for one lane; when the other array arrives the native prologue REFUSES entry
(`exit_instr == maxInt(u32)`, `completed == 0`, zero iterations executed).
`accountLegacyThrash` (trace.zig ~3459) scores that refusal as a thrash strike, so ~60
consecutive refusals per call drive `gate[dispatch:legacy_thrash]` at pc=9 with
escalating 256→4096-tick cooldowns — which also block the calls that WOULD have entered.

Measured cost: `Av:9` runs native for 14.8% of its iterations at 22.2 c/it while 89.3%
of the whole run sits in tier-0 at 434.3 c/it on a healthy trace. `Atv:9` (monomorphic,
always `.f64`) sits at 99.0%. This is why doc 32's coverage fix bought only −4.2% on
spectral-norm instead of the predicted ~5x.

Two separable defects:
  1. an entry refusal is not thrash — NOTHING executed, so pricing it as turnstile cost
     is a category error. Gate on `completed > 0` (or exclude the
     `exit_instr == maxInt(u32)` prologue-refusal case) before counting a strike.
  2. the anchor never records a SECOND trace for the second lane shape. LuaJIT's answer
     to a polymorphic loop is another root/side trace, not a penalty. Adjacent to B3
     (`nativegen.zig laneConsistent` — one array lane per whole trace, a single `?i32`
     with no keying by table/ref/slot), which is the wall right behind it.

Deferred out of the doc 32 arc deliberately: it is a dispatch/gating bug, not a
`.value`-lane recording bug, and it needs its own design + review.

## Doc 32 scope cuts, deliberately deferred (2026-08-30)

  * `.value` `astore_append` — the append gate excludes `.value`, so growing a mixed
    array still falls to the bounds check. Reads/writes at existing indices are covered.
  * string and bool `.value` elements — admission is int/float only, mirroring
    `hashGetShape`, because only those have a strict type guard (`guard_int`/
    `guard_float`) to pin the element type.
  * heap-valued `.value` STORES (the read side already handles element tables).
  * zombie-trace cache-slot cost: if a `.value` array later narrows at a rehash, the
    `.value`-recorded trace stays in the cache occupying a slot until pressure clears
    it. `laneWidenedPast` correctly does not evict it (the guard is not permanently
    unsatisfiable), so this is a cost to record, not a bug to fix.

## Benchmark boards must come from `gt profile`, not the desktop (2026-08-30)

The development desktop cannot produce a trustworthy board: a background game at 790%
CPU (load average 12.9-17.3) once produced a uniform +11%..+46% "regression" across
EVERY row including the pure tier-0 column, which no JIT change can affect. Use
`gt profile` (`.gothab/workflows/profile-bench.yml`) — an isolated 2-vCPU pool where
measured per-row run-to-run noise on identical code is 1.3%.

Three things to remember when reading those boards:
  * absolute ms are NOT comparable to anything in `bench/results/` or the design docs —
    that pool is much narrower than the desktop. Only same-pool A/B deltas mean anything.
  * a +-2..3% single-row move with UNCHANGED trace structure is binary code layout, not
    behaviour. Diff `--dump-native` (it will differ only in embedded addresses) rather
    than re-timing. Confirmed this way for `str_find_match` and `scimark-lu` in doc 32.
  * ~~absolute ms are not comparable across runs either~~ **FIXED 2026-10-04.** The old
    unpinned pool picked the cheapest spot type (Granite Rapids one run, Ice Lake the
    next, ~2× apart). The workflow now targets `runs-on: pt-default`, a pool pinned to
    c8id.large (2 vCPU). Gothab refuses profile jobs without a pinned label. Two
    back-to-back runs of identical code (fac4c94) differed by **0.30% mean |Δ| over
    all 86 wall rows**, max 1.1% outside the 0.7 ms probe. Absolute ms ARE now comparable
    across pt-default runs (still not to desktop `bench/results/`).
  * `gt profile` ships committed-but-unpushed + dirty changes as a patch on origin. Two
    traps: the patch is capped (a 2.9 MB diff got 413), and untracked files are not
    shipped (another agent's dirty `build.zig` importing its untracked `src/asm/` broke
    the remote build). For a clean board of committed work, push, then
    `gt profile --sha $(git rev-parse HEAD)`. It needs the FULL sha; a short one is rejected.

## Numeric φ widening (next arc after doc 38, 2026-09-04)

A while-body root recorded at trip 1-2 pins an int entry load on a carried
slot that the body floats (`j - k` with float k, `k / 2`) — lk=int/sk=float,
the nativegen RV-3 analyze bail, so the root never compiles and the anchor
starves (fft_bitreverse:9 at 0% residency).

**DESIGN LANDED: docs/design/39-numeric-phi-widening.md** (v3, three codex
review rounds). NB the approach sketched here originally — eager entry
coercion ("convert the ENTRY value explicitly, carry the φ as float") — was
REJECTED in review: it changes observable first-iteration semantics (integer
arithmetic, math.type, >2^53 compares). The sound design is a
**type-stabilizing peel**: record iteration 2 behind the existing
`preheader` marker, carried dataflow via lazy internal φs. The demote-vs-
widen arbitration resolves itself: on the peel's second iteration the
runtime values are genuinely float, so `recCompare`/`keyRefNarrowed` stay
runtime-keyed and unmodified. See the doc's checklist for phases.

## Type-guard side traces (deferred, 2026-09-04)

The general mechanism (side traces for guard_int/guard_float failures on
type-oscillating variables) is sound but needs:
1. A scalar-path `consumeSideTraceWantAtResume` call (missing today)
2. Restriction to tier-1a chaining (native type guards are hoisted to prologue)
3. A commit-time duplicate-fingerprint check (DONE-latch poisoning risk)

Deferred because fft_bitreverse's actual problem is branch-shape variance
from while-inner unrolling, not type oscillation. Come back when a benchmark
demonstrates genuine type oscillation on a carried slot.

## Debug-build jit-stats shows native execution = 0 cycles on fft (2026-09-05)

A Debug (`just build`) binary running `--trace --jit-native --jit-stats` on
scimark-fft reports `native execution: 0 (0.0%)` while simultaneously reporting
789 native link exits and 9 compiled traces; the same tree at ReleaseFast
reports 15.1% native. nsieve under the SAME Debug binary reports native 35%,
so it's not a global Debug accounting hole — something about fft's fused
loopdone chains (`link fused: loopdone=40516`) attributes native cycles to the
steering seam (or skips the native TSC bracket) only in Debug. Harmless for
benchmarking (we only trust ReleaseFast numbers) but confusing during
diagnosis — worth a look at the TSC bracketing in the fused-loopdone dispatch
path.

## Doc-41 follow-ups from the split review (2026-09-06)

Confirmed findings from the three-cluster review of the ownership extraction
(commit 243c434); the cheap boundary items were fixed in the follow-up commit,
these remain:

1. **topologyView rebuild cost — FIXED 2026-09-07** (two mechanical halves,
   both landed; interleaved A/B vs the 8a9ef56 shadow):
   - Lazy bridge-emission queries: the eager O(traces×exits×slots×IR) fact
     materialization in `topologyView` is gone — the emissions scan moved onto
     `TraceCode` (`bridgeEmissions`/`bridgeEmitsSlot`, pure immutable-IR query
     next to its sibling `classifyBridgeCandidate`) and the topology builder
     queries it lazily at its three edge sites, exactly the pre-split pattern.
     nativegen's `compositeBridgeEmitsSlot`/`compositeBridgeEmissions` deleted.
     grid_matmul +14% → +5.4%.
   - `RegionPolicy.receiptsInert()` early-out in `accountRegionProfit`: with
     `region_profit` + `source_exit_regions` + `dest_entry_regions` all empty
     the whole classify/choose/credit/destination pipeline is provably a no-op,
     but scimark-fft ran it ~1M times per run (~95 cyc each — its one region is
     armable=false, so the armable-only physical indices stay empty). Three
     O(1) size loads now gate it. fft +8.8% → +3.7%, grid_matmul → +3.7%;
     region/link tier now CHEAPER than pre-split (5.7ms vs 7.9ms on fft).
   The `replayLedgerFrom` "doubling" from the original diagnosis did not
   reproduce today (per-walk seam equal or better under `--jit-stats`: 315 vs
   366 cyc/walk).

1b. **interpreter i-cache regression from the split — CLOSED 2026-09-07 by
   the doc-42 tail-call dispatch conversion** (per-op musttail handlers; see
   docs/design/42 §9 for the full receipts). The megafunction block-placement
   lottery is structurally gone: pi_leibniz t0 icache misses 9.1K on the
   final shape (the 19.7M-miss layout roll can no longer happen — handlers
   are independently-placed functions), and t0 beats pre-conversion HEAD on
   5/7 battery benches (pi_leibniz -10.8%, fft -8.9%, euler14 -5.9%,
   grid_matmul -4.6%, array3d -4.2%). Honest residuals, recorded in doc 42
   §9.3: recursive-fib/lua54 t0 ≈ +2% vs HEAD (call-boundary reload work the
   megafunction kept in registers), scimark-fft jit +6.9% (profiled to the
   trace-chain seam / R3 back-edge epilogue call, NOT the dispatch hot
   path). Follow-up lever awaiting Bart's call: `omit_frame_pointer = true`
   on the mahina module = a further measured ~1.5–3.5% t0 (doc 42 §9.4;
   costs fp-based `perf -g` call graphs).
2. **Forwarding facade on TraceState** — 176 pure-forward decls
   (trace.zig:2401+), three-layer aliasing trace.zig → trace_link →
   native_registry for ~9 demote/mutation ops, ~10 one-line policy forwards in
   trace_regionops. Doc 41's own invariant ("no permanent forwarding-only
   endpoint") forbids this as an end-state; it is the doc's outstanding
   coordinator phase, not a quick fix.
3. **RegionPolicy pub-field reach-ins** — coordinator slices read/write
   `region_profit.getPtr` / `region_defs` / `edge_cache` directly (trace_chain,
   trace_link, trace_regionops); bridge-arm decision logic lives in regionops
   while its data moved to policy. Related: `EntryPatchState` transitions are
   written from three modules; `debug_log` sync is manual boilerplate at ~7
   sites; promoted-set `summary`/`metadata` inner pointers still reachable
   through the const view.
4. **trace_finalize's `rec: anytype`** — a ~20-field implicit structural
   contract over the recorder; consider a named view struct.

## File-split review round 2 findings (2026-09-10, eager-tiger)

Fresh audit of the 5-slice trace.zig split (two read-only agents + hand
verification). Dead facade swept same-day (34 alias deletions + 9 pub
demotions in trace.zig, compiler-adjudicated). Deferred items:

1. **Recording-start family cut in half + raw `rec` writes** — the split's
   one real seam defect. `maybeStartContinuation` (trace_link.zig:216) and
   `maybeStartReplaySide` (:240) live in trace_link while their siblings
   `maybeStartCont`/`maybeStartHead` stayed in trace.zig; the trace_link
   pair calls `rec.reset` + writes `rec.kind`/`rec.side_src` directly
   (8 reach-ins, 5 writes — the ONLY `.rec.` sites outside the hub),
   re-implementing the hub's private `arm()` minus its two seeds. Verified
   consequence (not unsound, fail-closed): cont/side recordings never seed
   `anchor_abs_base` (stays 0 → trace_recorder.zig:4085 aborts EVERY open-
   upvalue read `.aliased_input`) nor `route_upvalue_reads` (→ eternal
   `.upvalue_mutable` re-aborts, doc 43 P5 memo never consulted). Fix shape
   is Bart's call: (a) pure motion — reunite all four starters hub-side next
   to `arm()`, behaviour unchanged; (b) also route them through `arm()` so
   cont/side get the seeds = behaviour change, needs its own gate+bench run
   (cont anchors DO carry a base via PendingRetAnchor, so seeding is
   possible).
2. **Link-arming stragglers in the hub** — `hasArmedFrameLink`,
   `hasArmedSiblingHandoff`, `siblingHandoffEligible`, `tryArmFrameLinks`,
   `tryArmSiblingHandoff`, `publishSiblingArm`, `armedEdgeInBridgeFreeCycle`,
   `resolveLoopDoneCont` (trace.zig:1540-2261) are trace_link's declared
   concern; `publishSiblingArm` sets the Part-S sibling latch that
   trace_link's `clearSiblingLatch` clears — one latch maintained from two
   files.
3. **Chain-only material stranded in the hub** — `dbgNoteBurst`/
   `dbgNoteSuffixLedger`/`dbgNoteReplayRow`/`dbgDumpBurstStats` (called only
   from trace_chain) and `ChainResult`/`ChainTier`/`ExitMaterialization`
   (21 chain uses vs 3 hub uses).
4. **Pure `*const Trace` classifiers in the hub** — the
   `isLoopDoneGuardIndex`/`whileLoopDonePostPc` family (trace.zig:179-290)
   touches no TraceState, consumed by 8+ modules; leaf material
   (trace_record.zig or trace_ir.zig).
5. **No registry query API** — 17 hand-rolled `armedLinks()` filter loops
   across trace.zig(6)/trace_link(6)/trace_regionops(5).
6. **Cosmetic**: 4 test files (trace_code_test, trace_finalize_test,
   traceser_test, trace_region_topology_test) import leaf modules directly
   where sibling tests use the trace.X facade; `trace_link_mod.arm` (native
   link) vs `TraceState.arm` (recording) name collision is a readability
   trap.

## Stable-ID heap-eq coverage leftovers (Astra review of doc 50)

- [ ] A spill-pressure variant of the heap `eq`/`ne` identity tests (enough
      live values that the compared refs live in memory homes, pinning the
      mem-operand id-compare path).
- [ ] A differential identity test through a REAL keyframe capture/restore
      (run the eq trace pre-capture and post-restore and compare), rather
      than the simulated same-id/different-address twin.

## Recurring jit-debug test-gate "flake" — diagnosed and fixed (2026-09-26)

Twelve+ occurrences since 2026-09-17: a stray `failed command: …/test
--seed=… --listen=-` line after `[jit]` probe spam. Every fully captured
one exited 0 with `+- run test w` and no `error: '…' failed` line.

**Cause** (read in the pinned zig, `lib/compiler/Maker.zig`): a step
whose `result_stderr` is non-empty is printed even on success, labelled
` w` (`printStepFailure`'s last arm), followed by its `failed command`.
A passing test's stderr is buffered and handed over as `result_stderr`
at the end, so whether any is left depends on buffering. The stderr was
the recorder's jitdbg probes (`guard-dedup`, `ABORT`, `bad_type`), which
skipped the per-VM `debug_log` gate and printed for every VM in a
`-Djit-debug` build. Fixed in doc 56 Phase 4: `RecordingSession.dbg`,
gated by the flag `RecordingSession.start` stamps. The gate now prints
nothing at all.

- [ ] **Watch.** Occurrences 1–3 and 5–8 lost their output to pipes, so
      a real failure hiding among them can't be ruled out. The gate is
      silent now, so any line it prints is real: if a `failed command`
      shows up again, keep the whole log (`> log 2>&1`) and treat it as a
      failure. (2026-09-26: a background loop of 30 direct runs of the
      pre-fix test binary with random seeds was started to look for a
      real non-zero exit; see CURRENT_TASK for its result.)

## Doc 56 Phase 3 leftovers (2026-09-25)

- [ ] **v1: burst hops don't materialize.** Only the dispatcher's direct
      tier-1a entry takes the exit-side route. A child entered through a
      chain or burst whose own guard fails at iteration 0 still gets the
      old strikes and can be gated (glue test pc 24). Its exits never get
      exit-side children. Phase 4/5 (adapters, ledger grammar) is the
      natural place.
- [ ] **A retired child leaves its exit stuck at `attached`.** If the
      bound continuation is later removed (lane widening, retire), the
      parent exit stays `attached` and never records again. It needs an
      unbind on `removeTrace` (DONE latch included).
- [ ] **Per-hop cache scan.** `consumeExitSide` → `driveChain` looks up
      the continuation at `P` with a cache scan on every hop (fft: 508k
      hops). Measured on the native path in Phase 4 (nsieve, switch on):
      the whole runtime round-trip dominates (33% `enterSelectedTrace`,
      plus hashing, `resumeOf`, `memcpy`, `replayLedgerFrom`). Phase 5's
      direct jump removed the round-trip for ARMED exits (fft: 843k of
      963k hops fused). The scan is still paid by exits that are bound
      but can't arm (nsieve's tier-1a-only child); re-measure after the
      boolean-slot item below and Phase 6.
- [ ] **Tier-1a materialize scans every later instruction per hop.**
      `irinterp.materializeExitSide` walks `gi+1..n` for the sunk stores
      on every hop. The native adapter uses `flushStoreIndices` once at
      build; tier-1a could keep the same store list per trace.
- [ ] **No sunk grid store can precede an attachable exit.** Every grid
      shape tried (read-modify-write, or a write after any other heap
      load) aborts with `store_after_load` on `set_index2`, so the exit
      adapter's `gstore` path is reached by no program. It reuses the
      body's `emitGStore`; add a parity test once the recorder allows it.
- [ ] **`set_upval` on an OPEN upvalue is NYI in the recorder**
      (`recSetUpval` aborts `nyi_opcode` when `cell.isOpen()`; closed
      cells record as `ustore`). The same goes for `set_global`. Both
      stop whole loops from tracing (`u = u + i` in a nested function
      whose parent is still running; `G = G + i`). It blocks some
      exit-side recordings too.
- [ ] **Two iteration credits can't be seen yet.** Tier-1a call B's and
      `replayLedger`'s `enclosing_iteration` credits don't change any
      test when removed: `linked_completed` is already ≥ 1 there, and the
      dispatcher doesn't read `ChainResult.completed`. Options: keep them
      so the counts stay honest for later readers, or drop them. Bart to
      decide.

## Doc 56 Phase 5 findings (2026-09-27)

- [ ] **nsieve with the switch ON is still 12 → 38 ms (doc 56 G6).**
      R4 fixed the G4 turnstile (was 259 ms); Phase 6 took 43 → 38.
      Diagnosed (doc 56 §4.8.4): t6 is a `.side` trace at pc 18 that
      unrolled the OUTER loop, not the inner `for k`. Waiting on Bart's
      G6-Q1 (item above).
- [x] **Doc 56 G5: a `while` root's loop-done exit never links
      natively.** Fixed by doc 58 B2 (2026-09-30): the condition moved to
      the END of the trace (LuaJIT's `BC_LOOP` shape), so the exit is an
      ordinary exit that exit-side serves. The `.while_done` chain is
      deleted. Bit-reverse: 0.2% / 36.8% → 83.4% / 75.7% of iterations
      traced at its two hot anchors with the switch on.
- [ ] **DOC 58 B2 IS REVIEW-REJECTED — read this before touching the arc.**
      codex (2026-09-30, `docs/reviews/doc58/codex-b2.md`): *do not land*.
      B2 is implemented and both gates are green, but it is UNCOMMITTED and
      must stay that way until three blockers are fixed. Details and the
      options awaiting Bart's pick are in `CURRENT_TASK.md`
      ("B2 REVIEW OUTCOME 2026-09-30") and doc 58 §5.
      - **Blocker 1 is a verified mode-equivalence violation**, now covered
        by `bench/while_shortcircuit_probe.lua` (NEW). That probe prints 76
        under tier-0 / `--trace` / `--jit-native` and **215** under
        `--jit-native --jit-exit-side-native`; LuaJIT also prints 76, so 215
        is simply wrong. **The 4-mode parity sweep is therefore RED with B2
        applied — that is correct and expected, not a sweep bug.** The probe
        stays in the tree after the fix: it is the only parity coverage of a
        short-circuit condition on a `while` root, and its absence is why
        28 benches × 4 modes came back clean.
      - **Blocker 1 FIXED 2026-10-01** (composite bridge vs exit snapshot,
        `TraceCode.bridgeMatchesExitSnapshot`; see CURRENT_TASK "B2 FIX-ALL").
      - **Blocker 2 FIXED 2026-10-01** — the dispatcher now counts
        own-loop-test exits; `noteTakenExit` routes them to exit-side and
        stops them before every legacy route.
      - **Follow-up from blocker 2 (doc 56 G6 territory, after B2 lands):** an
        exit-side `.continuation` recorded on a ZERO-trip outer iteration
        re-reaches its own non-header anchor through the outer `for`, and
        `TraceState.maybeCloseAtAnchor` closes it `.loop`; exit-side only
        binds `.link` children, so that exit gives up for good (seen on
        `for i … do local j = i % 3; while k < j … end end` under tier-1a).
        LuaJIT never closes a side trace at a non-loop-op pc: it keeps
        recording across an uncompiled loop (`rec_loop_interp`, bounded by
        `loopunroll`) and stops `LJ_TRLINK_ROOT` at the next compiled loop op
        (`rec_loop_jit`). Fix together with G6-Q1(d)'s `loopunroll` bound.
      - **Blocker 3 FIXED 2026-10-01** — two parts. (a) fft's `repeat`
        body became a closed SCC with two qualifying loop roots and minted
        `armable=false`; doc 58 §4.8's gate-dominance tie-break elects the
        first loop (`Proto.dom`, `bc_dom.zig`). (b) `exit_side_native` is ON
        by default (CLI ablation: `--jit-no-exit-side-native`; the harness
        follows the config default), so the replacement for
        `.low_trip_while` is the shipped path.
      - **All six should-fixes DONE 2026-10-01:** `loopExtentFor` is an O(1)
        checked query that fails closed (malformed-bytecode tests;
        `isWhileHeader` no longer `@enumFromInt`s an unchecked kind);
        `recLoopLink` checks the root's entry contract like `recForLoop`;
        the bound-7 steady-region test with a `peeled_steady_zero_exits`
        witness; the link-kind oracle is CFG natural loops, not
        `loopExtentFor`; bit-reverse names its two headers; the repeat test
        demands a link into the repeat root; unused imports gone; §4.5 split
        into a numeric final-test exemption and a marker-loop policy that
        strikes once exit-side cannot serve the exit (test + mutation).
      - **Flip fallout, fixed in the same change:** one-shot `.link` traces
        now classify loaded+stored slots `.invariant` like `.terminal`
        (`nativegen_alloc.zig`) — an exit-side child starting mid-statement
        loads a table temp the body reuses for an int, and bailed native.
        Five tests that pin legacy arm kinds (Part S head arms, doc 16
        prime-side, doc 17 A-viii scope, doc 47 same-anchor sibling, the
        adapter-off layout) set `exit_side_native = false` explicitly; doc 47
        gained a default-config twin asserting the exit-side form.
      - Gates, parity sweep and board done (doc 58 §5 "B2 FIX-ALL" 6–7).
        Committed (Bart: commit now, fix after). The flip's sieve regression
        is **FIXED 2026-10-01** (doc 56 §4.8.5: G6-Q1(a) side link close,
        G6-Q1(d) `loopunroll`, the region bridge's ledger-cap yield; sieve_int
        23.6 → 6.6, nsieve 38.1 → 14.4, nsieve-bit 33.7 → 13.7), and the codex
        re-review of B2 + that fix found no blocker
        (`docs/reviews/doc56/codex-g6-bridge-cap.md`; three should-fixes
        folded in).
- [ ] **Duplicate root traces at one anchor (fft +19%, found 2026-10-01).**
      `fft_bitreverse:60` (the bit-reverse `while`) commits byte-identical
      root traces: the ordinary hot counter re-arms a root recording at an
      anchor that already holds one, and the recording, starting on a later
      back-edge iteration, reproduces the existing trace exactly (3 copies +
      a peeled int-entry variant on the 20261001-180122 board; 2 copies even
      in the faster build). Every dispatch then selects among them
      (`enterSelectedTrace`, `accountRegionProfit`): +13% instructions.
      Counting inlined markers in `loopunroll` only moved the formation
      timing that decides how many copies form. Find which entry the
      existing root refuses that triggers the re-arm, and answer it the
      LuaJIT way (a side trace from the failing guard, never a second root
      at a `JLOOP` anchor); a commit-time identical-trace refusal is a
      safety net, not the fix. Doc 56 §4.8.5 has the measurements.
- [ ] **Port LuaJIT's root-arm `nins - loopref > 24` unroll clause.**
      `rec_loop_interp` also aborts a root that unrolls an inner loop whose
      body (IR since the last loop event) exceeds 24 instructions, outside
      `LOOPEV_ENTERLO`. We count only `loopunroll` (doc 56 G6-Q1(d)); our IR
      density differs from LuaJIT's, so the 24 needs calibrating against
      our recorder before porting.
- [ ] **The nsieve init loop's 2-member region takes a window gate-strike
      every `nsieve` call**, and the strike runs a global `disarmAllLinks`
      (seen diagnosing the sieve regression, 2026-10-01). nsieve is 14.4 ms
      switch-on vs ~13 switch-off; this is the leading suspect for the
      remaining gap. A per-region disarm, or not striking a region that is
      merely re-entered, would be the general direction.
- [ ] **Exit-side children are never retired with their parents.** Found
      by the doc 58 flip (`trace_evict_test` monotonic widening): doc 48
      retires a stale narrow-lane root on entry, its exit-side child (a
      `.continuation` at the raw resume pc) loses its only arm and stays
      cached for good — unreachable, still guarding the stale lane, still
      counting against `max_traces_per_anchor` at its pc. LuaJIT flushes a
      root's side traces with it (`trace_flushroot`). Ours are shared by
      resume pc (doc 56 rev 5), so the analogue needs a binder count
      (retire when the last binding parent goes), not a parent pointer.
- [ ] **Exits of a child reached inside a burst never get exit-side
      service (doc 56 P6-Q3, deferred).** Seen writing the doc 58 §4.5 test:
      a post-loop child that guards a phase branch deopts at its OWN exit
      on every hop, nothing wants that exit (exit-side serves only the
      directly entered trace's exits), the parent's exit gives up after
      `tryside` unlinked chains and the anchor is gated. LuaJIT would grow a
      side trace of the side trace there.
- [ ] **`continuationReachesEnclosingBackEdge` scans at most 128
      instructions** (`trace_exit_attach.zig` ~471): an enclosing loop
      whose closer is further away is missed, so a big `repeat`/`while` body
      (fft at n=64 before hoisting `sin`/`pi`) never forms the cycle. Replace
      the bounded scan with an exact structural query (`Proto.dom` /
      `loopExtentFor` from the enclosing header side are both O(1) now).
- [ ] **Topology rebuild is ~k² in region members** (`bench-topology`,
      `zig build bench-topology`): k=512 ≈ 3.5 ms per rebuild, k=128 ≈
      0.2 ms; independent of proto size since doc 58 §4.8. The cost is the
      per-node `hasInnerRootAt` / edge loops, pre-existing (the §4.8
      tie-break is ~2% of it). Index them.
- [ ] **Unused import aliases** in `trace_chain.zig`, `trace_link.zig` and
      `trace_regionops.zig` (dozens: `IrOp`, `Ref`, `ProgramPoint`, …), left
      by the file split. Zig does not flag unused file-scope decls; prune.
- [ ] **Legacy exit routes are fallback-only now that exit-side native is
      the default.** Part S sibling handoff, doc 16 prime-side chains and
      doc 47 same-anchor siblings only serve exits exit-side refuses
      (peeled, precise, non-attachable, gave up). Audit which remain
      reachable in the default config and retire the rest (Z-7).
- [ ] **Doc 58 B4 leftovers (the arc is not finished).**
      - fft is still 336 ms with the switch on (B0 215, doc 58 §6 target
        131). **Diagnosed 2026-09-30 (Z-8 ladder) — the earlier "every 32
        rows pays a replay walk" reading was wrong.** On fft the seam IS
        the run (native 8.2% of cycles, steering seam **87.2%**, 66,032
        replay walks at ~34,624 cyc/walk), but **70% of dispatcher bursts
        end in `prologue_fail`** (46,184 of 66,029, on `fft_bitreverse:60`
        and `:69`) — entry failures, mostly well before the cap. codex
        reached the same place independently (6,901/6,969 on its isolated
        probe) and names a cause to test first: `recLoopLink`
        (`trace_recorder.zig` ~3933) discards `regs` and closes the
        inner-root link with **no `entryGuardsMatch` check**, unlike the
        numeric path at ~3559 — so a reset integer can reach a root
        specialised for a later float iteration.
      - `silent_promotions = 0` is a SEPARATE, downstream finding, and it is
        **not** owner election: 6 regions minted, 4 `armable=true`, and every
        `silent rejects:` counter is 0 with `candidates=0`, so
        `considerSilentPromotion` bails *before* the candidate counter. The
        smell is `region maps: profit count=0` against 203 `region: close`
        for 6 mints — no frozen accumulator is live when a full-cap yielded
        ledger arrives (`trace_link.zig:1524-1537`). And prologue failures
        satisfy neither promotion route's evidence class (~1505, ~1724), so
        fixing the entry contract may answer this on its own. Arming is fine
        (`t=10 ei=8 deopt outcome=yielded` 17,599 times proves the slot is
        armed). Next step: a permanent `self.dbg` probe naming which of the
        four gates bails.
      - This is the promotion-check item G5 asked for — add it to the
        test "doc 56 Phase 6: fft bit-reverse's exit-side cycle mints
        armable" once B4 diagnoses why they do not promote (Z-8 ladder).
      - With the switch OFF, `while`-heavy code is slower than B0 by
        design (lowtrip +115%, fft +75%): the exit is a coarse deopt that
        replays the final body pass and arms no continuation. B4 flips
        the switch, which is what ends it.
      - Tier-0 cost of the extra marker instruction: +5.3% lowtrip,
        +4.6% hightrip (doc 58 §4.2 budgeted 2%; real benches are
        +2.1% pi_leibniz, +1.8% nsieve-bit-fp, −2.3% fft). BART's call
        whether the synthetic-probe overage matters.
- [ ] **A branch that flips for good strands the loop on tier-0 (switch
      off).** `for i = 1, N do local lt = i < 500; if lt then ... end end`:
      after i = 500 the root trace fails its first guard every entry,
      legacy strikes gate it, 99.5% runs on tier-0. Switch on, since
      Phase 6: silent, 1 ms (switch off 2 ms). So this is fixed by
      Phase 8 (turning the switch on); nothing to do until then.
- [ ] **sieve_int / nsieve-bit are still slower with the switch on**
      (after Phase 6, best of 5: 6 → 22 ms, 14 → 35 ms). sieve_int: 203
      ledger walks off → 30k on, with ZERO silent candidates (so its
      ledgers never fill to the forced yield — find the terminal rows
      with the jit-debug build). nsieve-bit: 1.7k candidates, 1
      promotion. Diagnose with the Z-8 ladder. Doc 56 §4.8.3 "Phase 6
      landed" has the table.
- [ ] **BART: G6-Q1 / G6-Q2 (doc 56 §4.8.4).** The nsieve family's
      silent candidates never promote because a `.side` recording at the
      inner loop's `for_prep` unrolls the OUTER loop (one guard per
      composite) instead of linking to the outer root, like LuaJIT's
      `rec_loop_jit` would; its per-step exits give up ("anchor full")
      and their short ledgers reset the promotion streak. Widening
      `recForLoop`'s link close to `.side` (one condition) measured:
      switch on fft 224 → 131, nsieve 38 → 25, nsieve-bit 34 → 18,
      sieve_int 23 → 11; switch off fft 215 → 512 (G5). Options: (a)
      unconditional, (b) only with the switch, (c) G5 first, (d) also a
      `loopunroll` = 15 bound. Antigravity: APPROVE WITH CHANGES,
      recommends (c) + (d). Experiment reverted.
- [ ] **Bart to decide: widen `exit_side_ok` to bursts (P6-Q3 (b))?**
      Phase 6's counter (`burst skips=` on the `exit-side arms:` stats
      line) counts burst ledgers that ended in the ordinary deopt where
      the adapter would have hopped: nsieve 4.2k, nsieve-bit 1.7k,
      nsieve-bit-fp 9.5k, fft 2.6k, bit-reverse 2.4k, sieve_int 4.
- [ ] **Measure R3 on the two-level branch probe** (Phase 5 finding: 65%
      traced with the switch off, 13% on). R3 now lets a child's exits
      become wanted; the probe program is not in the tree yet.

## Recorder `bad_type` aborts found by the Phase Q side differential (noted 2026-10-10)

Both showed up while building the "side recording over a retired parent"
test in `src/interp_phaseq_test.zig` and were dodged there, not fixed.

- [ ] **`string.find(s, "z")` (a pattern with no specials) aborts recording
      with `bad_type` at the `call` (op 49).** The same call with `"%l"` or
      `"%d+"` records fine (`smatch` + `guard_sid`), so the plain-pattern
      fast path probably has no recorder lowering. Check the abort site
      with `--dump-aborts` and give it one.
- [ ] **`t[1] = nil` on a small array table aborts recording with
      `bad_type` at the `set_index` (op 40).** Seen as `hold[1] = nil` on a
      one-element `{ p }`, in a side recording. Storing nil (an array
      shrink / hole) seems to have no recorded store shape.
