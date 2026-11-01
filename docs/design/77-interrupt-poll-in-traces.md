# 77 — Interrupting traced loops — Design

Status: implemented 2026-11-02 (P1 on the interrupt byte + E2 with its own ledger kind) for tier-1a and native x64; remaining tests listed under Outstanding. Tier-0 interrupt landed in 24340e8.
Owner: Bart
Last updated: 2026-11-02

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole sections to Done once everything inside them is checked.

### Done

- [x] **Tier-0 interrupt.** `Heap.requestInterrupt` (signal-safe: a flag plus
  `gc_headroom = 0`), `Error.Interrupted` raised from `gcTrampoline`, the
  REPL's SIGINT handler (doc 75 §4). No instruction was added to the hot
  prologue. Commit 24340e8.
- [x] **Review.** Codex and Antigravity reviewed the first draft; every
  contested claim was then checked against the code (§Review and tiebreak).
- [x] **Q2 — replay.** Resolved: nothing is recorded (§Review and tiebreak).
- [x] **Q3 — `safepoint_seq`.** Resolved: unchanged by the chosen design.

### Outstanding

- [x] **D1 — the poll.** P1 reading `Heap.interrupt_requested` (the byte), at
  the back-edge. P2 and P3 dropped.
- [x] **D2 — the exit.** E2 with its own `LedgerKind.interrupt = 13`. No
  `ExitReason.interrupted` was added: the ledger's debug assertion requires
  `ledger_reason == exit_reason` and pairs reasons with kinds, and the row is
  already unambiguous (`exit_instr = maxInt`, reason `.normal`, kind
  `.interrupt`). E1 not taken.
- [x] **Phase 0 — measure the cost** (numbers under "Measured cost"). Cycles per iteration of the byte poll
  (`movabs` + `cmp byte [rax], 0` + `jne`) on an arithmetic, a table and a
  call loop; `just bench` over the whole board; `-Djit-debug` receipts
  identical to master.
- [x] **Phase 1 — tier-1a.** Poll in `irinterp`'s `.loop` arm after the
  commit; a productive `exit_instr = maxInt` exit.
- [x] **Phase 2 — dispatcher.** No change was needed: it already tolerates a
  productive `maxInt` exit and resumes tier-0, whose prologue parks the
  interrupt. (Planned: an early arm for `.interrupted`: account the
  laps, re-arm the headroom (see Q4), resume tier-0 at the anchor.)
- [x] **Phase 3 — native x64.** The poll in the `.loop` arm, its own exit
  stub (carried-homes flush, `exit_target = shared_exit`, no slot dispatch),
  the new ledger row kind and its `replayLedger` arms.
- [ ] **Phase 4 — tests.** Done: an interrupt delivered to a trace that is
  already running (a thread waits for `trace.entries > 0`), for arithmetic,
  call, table-write and `for` loops, in tier-1a and native, then the VM
  running another line (`interp_interrupt_test.zig`); pty runs of the REPL
  keep session locals. Not yet: peeled and instability-unrolled loops; a loop
  entered through a chain (ledger length > 1); an interrupt during recording;
  injecting the lost-zero race (Q4); registers coherent (parallel-φ swaps,
  write-only values). Allocating loops (`{}`, string concat) do not trace
  today (`new_table` / `set_list` abort), so they are interruptible only
  through tier-0. Behaviour asserted by counts, a generous watchdog for
  hangs, no wall-clock bounds (Rule #22).
- [ ] **Phase 5 — bench.** `just bench` over the whole board is not run yet
  (see "Measured cost" for the targeted numbers); code size and register
  pressure of the full sequence are not measured.
- [x] **Q1 — tiering counts.** No change when uninterrupted: `-Djit-debug`
  receipts of `sieve_int` and `field_hash` are byte-identical to the
  pre-change build; the other boards differ only by stdout/stderr
  interleaving, which also differs between two runs of the same binary.
- [ ] **Q4 — the lost zero.** Resolved in design (re-arm on delivery);
  Phase 4 tests it by injecting the race.
- [ ] **Defer — other architectures.** Native code is x64 only today; any
  later backend carries the poll from the start.

## Measured cost (2026-11-02, ReleaseFast, `--jit-native`, perf stat)

The poll is 3 instructions per back-edge (`movabs`, `cmp byte`, `jne`).

| program | instructions | cycles |
|---|---|---|
| `while n < 4e8 do n = n + 1; x = x + n end` | 4.00G → 5.20G | 403M → 802M (2.0x) |
| `bench/sieve_int.lua` | 466M → 523M | 82.7M → 88.9M (+7%) |
| `bench/pi_leibniz.lua` | 1.751G → 1.901G | 1.929G → 1.931G (0%) |
| `bench/grid_matmul.lua` | 465M → 489M | 97.5M → 97.8M (+0.3%) |

The two-instruction-per-lap loop is the worst case (the loop was already one
cycle per lap); real loops pay between 0 and 7%. A cheaper sequence (no
`movabs`, e.g. a flag reachable from a register the trace already holds)
is a possible follow-up, not done.

## Why this exists

The REPL (doc 75 Phase 4) must survive Ctrl-C on a runaway line. In tier-0
that works: the SIGINT handler zeroes the heap's `gc_headroom`, the dispatch
prologue's one GC compare sends the next safepoint to the cold trampoline, and
the trampoline raises `Error.Interrupted`. A pty test shows four loop shapes
(arithmetic, table stores, allocation, calls) stopping with the session's
locals intact.

A loop that has been traced never reaches that prologue. Measured:

| loop | tier-0 | `--trace` | `--jit-native` |
|---|---|---|---|
| `local i=0 while true do i=i+1 end` | stops | hangs | hangs |
| `local function f(x) return x+1 end ... i=f(i)` | stops | hangs | hangs |
| table store `t[i%100+1]=i*2` | stops | not run | stops |
| allocation `local s={i}` | stops | not run | stops |

The last two return to the dispatcher through guard exits (array growth,
allocation budget), so they meet the prologue. They were measured under
`--jit-native` only. The first two stay inside the trace until a guard fails,
and in those loops none does.

The JIT is off by default, so only `--trace` sessions are affected. A
long-running program that wants to be stoppable (a game host, `mahina viz`)
would be affected by the same gap.

## Goals

- Ctrl-C stops any traced loop within a bounded number of iterations, in both
  tier-1a and native, leaving the VM in a state the REPL can unwind and reuse.
- A cost that is measured, not argued (Rule Z-6): Phase 0 produces the number.
- A run that is never interrupted behaves exactly as today: same receipts,
  same tiering, same `safepoint_seq`.

## Non-goals (v1)

- Interrupting a native call that never returns (a blocked `proc.run` has its
  own forwarding, doc 75 §6).
- Timeouts or instruction budgets for embedders; the same poll could serve
  them later.
- A non-x64 backend.

## What the code does today

Facts read in the tree (first draft corrected after review).

1. **Where a trace loops.** tier-1a: the `.loop` arm of `irinterp.zig`
   flushes the φ writeback, adds to `completed` (two for a peeled trace's
   first back-edge), commits the recording and does `continue :iter`. Native
   (`nativegen.zig`): the `.loop` arm first commits write-only slots, then does
   the parallel move over carried slots and internal φs, `inc rbx`, `jmp
   loop_top`. Neither has a bound or a check. `rbx` is chain-cumulative: a
   body entered through an armed link starts with `rbx > 0` and its local
   laps are `rbx - entry_rbx`.
2. **Where it leaves.** Through a guard exit stub (`exit_labels`), the
   `.link` and `.terminal` arms (inline, not through `exit_labels`), a
   loop-done guard, a prologue failure or seed decline (entry), or a precise
   trace's snapshot exits, which flush a bytecode snapshot rather than
   carried homes. The coarse `deopt_exit` flushes carried homes; a peeled
   trace with zero local laps skips the flush.
3. **`guard_gc`.** In a precise trace it is emitted eagerly after the entry
   loads (`trace_recorder.zig:1680`); in an ordinary trace lazily, just before
   the first allocating op (`:1952`), after earlier stores. Its predicate is
   `!gc_stress and object_count + A < next_gc`. It reads neither
   `gc_headroom` nor `interrupt_requested`, so an interrupt does not trip it.
   It **is** counted as a hot exit: `noteTakenExit` (`trace_link.zig:384`)
   increments `exit_counts[exit_instr]` for every in-range exit, and an
   exit with `completed == 0` that is not a branch guard can raise a
   side-trace want after `hotexit` hits. The first draft's "not hot-guard
   counted" was wrong (a stale comment). A precise `snap == 0` exit asserts
   `pins.op == .guard_gc` (`nativegen.zig:2833`).
4. **What the dispatcher does with `exit_instr == maxInt`.** A productive
   result (`local_done > 0`) skips hot-exit counting (`exit_ok` false,
   `interp.zig:7538`), `onSideExitReceipt` takes a null key, and
   `maybeArmContinuation`, `isSourceBranchGuardExit` and `driveChain` all
   return early on `maxInt` ("no guard identity"). Then it resumes tier-0 at
   the anchor. Today the only producers are the tier-1a malformed-trace
   fallthrough (`irinterp.zig:1515`) and native prologue failure (with
   `completed == 0`); a productive `maxInt` is therefore a new path, though
   its consumers tolerate it.
5. **The ledger rejects it in a fused span.** `replayLedger`
   (`trace_chain.zig:2395`) panics on a `.deopt` row whose exit is out of
   range or `maxInt`, or names a `.loop`/`.link` terminator. Rows are only
   replayed when `ledger_len > 1` (a trace entered through a chain); a single
   row is handled directly from `result.exit_instr`.
6. **Bounded without a poll.** Multi-trace cycles are bounded by
   `LEDGER_CAP` (32 rows, then a forced yield to `shared_exit`),
   `silent_budget`, and `DESCENT_BUDGET` (65,536) for row-free frame-motion
   cycles. Only a trace that loops on its own `.loop` back-edge has no bound.
7. **The tier-0 side.** `gc_headroom` is the prologue's only GC test;
   zeroing it reaches the cold trampoline. `Heap.interrupt_requested` is a
   separate byte at a stable address (`Vm.heap` is heap-allocated; native
   pages already bake `&heap.gc_stress`). `gc_stress` forces
   `gc_headroom = 0` permanently (`refreshHeadroom`).

## Options for the poll

**P1 — a byte check at the back-edge.** After the shuffle and `inc rbx`:
`movabs rax, &heap.interrupt_requested; cmp byte [rax], 0; jne exit`, and a
volatile read of the same field in `irinterp`. The byte is only ever set by
the handler and cleared by the host, so there is no decrement race, and
`gc_stress` does not touch it. Zero extra exits in steady state. Reading
`gc_headroom` instead (the first draft) is rejected: under `gc_stress` it is
0 forever, so the trace would exit every iteration, and the allocation
decrement can overwrite the handler's zero. Cost: one `movabs`, one byte
compare, one predictable branch per iteration; Phase 0 measures the sequence
including register pressure and code size.

**P2 — an iteration budget.** Rejected after review. `rbx` counts trace trips
cumulatively across a chain, not laps of one trace; trips are not source
iterations (unrolled trips, a peeled first back-edge counting two). It also
adds a tier-0 dispatch per exit even when nothing is pending, shifting
`safepoint_seq` against pure tier-0 and perturbing keyframe cuts, and it
changes receipts, hit counts and the promotion/arming evidence.

**P3 — patch the back-edge from the handler.** Rejected. Mahina's exit
patching rewrites writable data slots (`CompiledTrace.slots`), not the
executing machine code; its executable mappings are RW→RX
(`nativegen_mcode.zig`). A handler cannot safely edit code, and it would
cover no tier-1a. Rule Z-8's "exit patching" does not establish otherwise.

**P0 — leave it.** Today's state.

## Options for the exit

**E1 — an IR op, `guard_intr`.** An ordinary guard at the loop head. Reuses
the exit stubs and the dispatcher grammar, but: it is hot-exit counted unless
excluded explicitly; an ordinary guard's exit resolves through its own `slot[ei]`
(`nativegen.zig`, exit stub comment), so unless arming is made to refuse it
an armed sibling-handoff could jump past the dispatcher and defeat the poll
(not checked whether `guard_gc` is already refused); a nullary invariant
guard would probably need a pin in `tropt.kindOf` so it is not hoisted out of
the loop (not checked); the precise `snap == 0` assertion must admit it; and it adds an
opcode to finalize, prove, alloc, irinterp, `traceser.zig`,
`schema/trace.json` and `viz/src/enums.ts`.

**E2 — an exit attached to the `.loop` terminal.** No IR change. The poll is
placed after the shuffle, so all state is committed and equals an
iteration-entry state; it exits straight to `shared_exit` (no slot
dispatch). Because a fused span's ledger cannot carry a `.deopt` row with
`maxInt`, it gets its own `LedgerKind.interrupt` and `ExitReason.interrupted`
rather than borrowing either. Touches: the `.loop` arm in both executors, one
exit stub, `trace_exec.zig` (enum values and the comptime ordinal test),
`trace_link.zig:1491`, the two `replayLedger` switches, and the dispatcher's
early arm.

## Review and tiebreak (2026-11-01)

Codex preferred E1; Antigravity preferred E2 with `exit_instr = maxInt`.
Both agreed on P1, both rejected P3, and both found P2's problems. Each
contested claim was checked:

| Claim | Verdict | Evidence |
|---|---|---|
| E1 `guard_gc`-style exits are not hot-counted | **Wrong** (the doc's) | `noteTakenExit` counts every in-range exit |
| `maxInt` bypasses `noteTakenExit` and the dispatcher tolerates it | **True** (Antigravity) | `interp.zig:7538`; guards in `trace_link.zig:147,1038`, `trace_chain.zig:242` |
| E2 needs no new ledger kind | **Wrong** (Antigravity) | `replayLedger` panics on a `.deopt` row with `maxInt` when `ledger_len > 1` |
| E2 needs a contract change at the ledger | **True** (Codex) | `trace_chain.zig:2395` |
| Poll `gc_headroom` | **Wrong** (the doc's) | `gc_stress` pins it to 0; the decrement race |
| Q4's byte is new | **Wrong** (the doc's) | `Heap.interrupt_requested` exists |
| An interrupt can be recorded/replayed | **Moot** | see Q2 |
| `.loop` as an exit disables coalescing (`opMayExitInBody`) | **No for E2** | the poll is after the shuffle; nothing to roll back |
| E1 inserting an op shifts refs | **No** | the recorder emits `guard_gc` at recording time already |

Tiebreak: **P1 on the byte, E2 with its own reason and ledger kind.** The
deciding facts: E2's exit goes to `shared_exit` and cannot be armed away,
E1's resolves through `slot[ei]` unless made to refuse arming; E2's state is post-commit and needs no
rollback reasoning; E2 touches no schema or viewer; and the one real cost
Antigravity missed (the fused-span ledger) is a bounded change of about six
sites. E1 remains sound if Bart prefers reusing guard machinery; it would
need the four extra items listed under E1.

### Answers to the open questions

- **Q1 — tiering counts.** With P1 + E2, none in an uninterrupted run (the
  poll never fires). When it fires the `.interrupted` arm accounts the laps
  and does no hot-exit counting. Phase 0 checks the board's `-Djit-debug`
  receipts are identical to master.
- **Q2 — replay.** Nothing is recorded. Only the REPL installs a SIGINT
  handler, and the REPL's VM stays in `effect_mode = .off` (`main.zig:652`
  sets `.record` only for the script path under `--emit-effects`). A script's
  runtime fault returns 1 before any artifact is written (`main.zig:744`).
  If a host ever installs the handler under record mode, the interrupt must
  be a fatal, non-recordable fault like `ProcNotRecordable`; that is not
  built now.
- **Q3 — `safepoint_seq`.** Unchanged: the poll adds no tier-0 dispatch
  unless it fires, and `safepoint_seq` stays a tier-0-only counter, not a
  cross-tier coordinate.
- **Q4 — the lost zero.** The trace poll reads the byte, so a lost zero does
  not hide the interrupt from traces. It could, though, hide it from tier-0
  after the poll exit: the dispatcher resumes at the anchor, `gc_headroom`
  is positive, the prologue skips the trampoline, the trace is re-entered,
  polls, exits, and so on without ever raising. The `.interrupted` arm must
  therefore call a re-arm (`requestInterrupt` again, now from the single
  thread, so no race) before resuming. A non-allocating tier-0 loop has no
  decrement to race; an allocating one reaches a collection and the
  trampoline.

## Phasing

0. Measure the poll sequence on a shadow tree (whole board, receipts).
1. tier-1a poll and exit result.
2. Dispatcher early arm and re-arm.
3. Native x64: poll, stub, ledger kind, replay arms.
4. Tests (Outstanding list).
5. Bench and sign-off.

## References

- `docs/design/75-process-spawn-and-shell.md` §4 (the REPL), §6 (Ctrl-C and
  children).
- Doc 17 (coarse deopt), doc 45 D6 (precise traces), Rule Z-8 in `CLAUDE.md`.
- `src/irinterp.zig` (`.loop`), `src/nativegen.zig` (`.loop`, exit stubs,
  `deopt_exit`), `src/trace_exec.zig` (`ExitReason`, `LedgerKind`),
  `src/trace_chain.zig` (`replayLedger`), `src/trace_link.zig`
  (`noteTakenExit`), `src/interp.zig` (`gcTrampoline`, the dispatcher's exit
  arms), `src/gc.zig` (`requestInterrupt`).
