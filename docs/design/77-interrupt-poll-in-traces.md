# 77 — Interrupting traced loops — Design

Status: draft, not yet implemented (tier-0 interrupt landed in 24340e8)
Owner: Bart
Last updated: 2026-11-01

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole sections to Done once everything inside them is checked.

### Done

- [x] **Tier-0 interrupt.** `Heap.requestInterrupt` (signal-safe: a flag plus
  `gc_headroom = 0`), `Error.Interrupted` raised from `gcTrampoline`, the
  REPL's SIGINT handler (doc 75 §4). No instruction was added to the hot
  prologue. Commit 24340e8.

### Outstanding

- [ ] **D1 — pick the poll.** Which of P1–P3 (§Options for the poll) is the
  mechanism. Needs a decision from Bart before any code.
- [ ] **D2 — pick the exit.** Which of E1–E2 (§Options for the exit) the poll
  leaves by.
- [ ] **Phase 0 — measure the cost.** Cycles per iteration of the poll on a
  tight arithmetic loop, a table loop and a call loop, with `just bench` and
  `--jit-stats`. This decides D1 if the options are close.
- [ ] **Phase 1 — tier-1a.** The poll in `irinterp`'s `.loop` arm and the exit
  result the dispatcher already understands.
- [ ] **Phase 2 — native x64.** The poll in nativegen's `.loop` terminal, its
  exit stub, the prover (`nativegen_prove.zig`), and the allocator's exit
  inventory.
- [ ] **Phase 3 — tests.** A traced `while true do end` per loop shape
  (arithmetic, call, table, allocation) interrupted in tier-1a and in native,
  the VM running again afterwards, and a replay of a run that was
  interrupted.
- [ ] **Phase 4 — viz and trace schema.** Only if D2 adds an IR op: the op in
  `viz/src/enums.ts`, `schema/trace.json` and `traceser.zig`.
- [ ] **Q1 — does the poll change tiering counts?** Open.
- [ ] **Q2 — replay of an interrupted run.** Open.
- [ ] **Q3 — keyframe cuts and `safepoint_seq`.** Open.
- [ ] **Q4 — a separate interrupt byte for native.** Open.
- [ ] **Defer — other architectures.** Native code is x64 only today; any
  later backend carries the poll from the start.

## Why this exists

The REPL (doc 75 Phase 4) must survive Ctrl-C on a runaway line. In tier-0
that works: the SIGINT handler zeroes the heap's `gc_headroom`, the dispatch
prologue's one GC compare sends the next safepoint to the cold trampoline, and
the trampoline raises `Error.Interrupted`. A pty test shows four loop shapes
(arithmetic, table stores, allocation, calls) stopping with the session's
locals intact.

A loop that has been traced never reaches that prologue. Measured with
`--trace` (tier-1a) and with `--trace --jit-native`:

| loop | tier-0 | `--trace` | `--jit-native` |
|---|---|---|---|
| `local i=0 while true do i=i+1 end` | stops | hangs | hangs |
| `local function f(x) return x+1 end ... i=f(i)` | stops | hangs | hangs |
| table store `t[i%100+1]=i*2` | stops | not run | stops |
| allocation `local s={i}` | stops | not run | stops |

The last two return to the dispatcher through guard exits (array growth,
allocation budget), so they meet the prologue. They were measured under
`--jit-native` only. The first two stay inside the trace until a guard fails,
and in those loops none does. This doc designs the check those loops lack.

The JIT is off by default, so only `--trace` sessions are affected. A
long-running program that wants to be stoppable (a game host, `mahina viz`)
would be affected by the same gap.

## Goals

- Ctrl-C stops any traced loop within a bounded number of iterations, in both
  tier-1a and native, leaving the VM in a state the REPL can unwind and reuse.
- A cost that is measured, not argued: Phase 0 produces the number, and the
  decision rests on it (Rule Z-6: it must help programs in general, not one
  benchmark).
- Determinism: a run that is never interrupted behaves as it does today.

## Non-goals (v1)

- Interrupting a native call that never returns (a blocked `proc.run` has its
  own forwarding, doc 75 §6).
- Timeouts or instruction budgets for embedders. The same poll could serve
  them later; this doc does not design that API.
- A non-x64 backend.

## What the code does today

Facts read in the tree, because the options depend on them. Items 3 and 4 are
read from comments and code but not yet exercised by an experiment.

1. **Where a trace loops.** tier-1a: `irinterp.zig` `.loop` arm adds to
   `completed`, commits the recording and does `continue :iter`. Native:
   `nativegen.zig` `.loop` arm shuffles the carried values (the parallel move),
   `inc rbx` (the completed-iterations counter) and `jmp loop_top`. Neither has
   a bound or a check.
2. **Where it leaves.** Only through a guard, a `link` terminal, or a
   loop-done guard. Each exit stub (`nativegen.zig`, the `exit_labels` loop)
   restores the ABI, stores `exit_instr`, flushes the carried homes and
   returns through the shared exit or a patched link slot.
3. **An iteration-entry exit exists.** The eager `guard_gc` of an allocating
   trace fails at the top of an iteration, before any of the iteration's
   effects. It is deliberately not chainable and not hot-guard counted (no
   exit PC). In a precise trace its `snap == 0` exit is documented as
   "iteration-entry coherent: regs untouched since the last φ flush", and the
   dispatcher resumes tier-0 at the anchor.
4. **The state at the back-edge.** After the φ shuffle the carried homes hold
   the next iteration's inputs, which is the same state an entry-time guard
   sees. The coarse-deopt model (doc 17) re-runs the iteration from the anchor
   in tier-0, so an exit from this point needs the same write-back the
   existing guards already emit.
5. **The tier-1a clean completion.** `exit_instr == maxInt` with
   `completed > 0` is already a "productive" result the dispatcher handles
   (`trace_exec.zig`, `ExitReason.normal`). Native uses `maxInt` for
   `prologue_fail` too, which is why `ExitReason` exists.
6. **The tier-0 side is free.** `gc_headroom` is the prologue's only GC test;
   zeroing it reaches the cold trampoline. A native poll can read the same
   word, so the signal path stays one mechanism.

## Options for the poll

**P1 — flag check at the back-edge.** `cmp qword [&heap.gc_headroom], 0; jle
exit` after the shuffle (native), a field test in `irinterp`. Reads the same
word tier-0 reads, so the handler needs no second store. It also exits when a
collection is due, which is correct (tier-0 would collect at that point); a
non-allocating loop cannot make one become due while it runs, so this adds no
exits in steady state. Cost: one load, one compare, one predictable branch per
iteration.

**P2 — iteration budget.** `cmp rbx, CAP; jae exit` using the counter that is
already in a register. No memory load. The trace leaves every CAP iterations
(for example 2^20), tier-0 runs one prologue, the interrupt is served there,
and otherwise the trace is re-entered. The bound is a function of iteration
counts only, so it is deterministic and does not read signal state; the same
mechanism bounds the time between any two safepoints, which an embedder may
want. Cost: one register compare per iteration, plus one exit and re-entry per
CAP iterations.

**P3 — patch the back-edge from the handler.** The handler rewrites the
`jmp loop_top` of live traces into a jump to an exit stub (LuaJIT's
exit-patching; Rule Z-8 notes mahina already patches guard slots). Zero cost
when idle. The cost is complexity: a handler that edits executable memory is
async-signal-unsafe unless the pages are pre-mapped writable twice and the
patch is one aligned store; `nativegen_mcode.zig` registers the pages and W^X
would need re-checking.

**P0 — leave it.** Document that `--trace` sessions are not interruptible in a
pure loop. This is today's state.

## Options for the exit

**E1 — an IR op, `guard_intr`.** Emitted by the finalizer at the loop head
(after `preheader`) of every loop-anchor trace, next to where the eager
`guard_gc` goes. It is an ordinary guard with the `guard_gc` treatment: no exit
PC, not hot-guard counted, an iteration-entry exit. Lowered in irinterp
(`break :iter` with the guard's index) and native (`jccNativeExit`). Reuses
every existing exit stub and the precise-trace `snap == 0` path. Cost: a new
op through finalize, prove, alloc, the dump formats, `schema/trace.json`,
`traceser.zig` and `viz/src/enums.ts` (Phase 4).

**E2 — an exit attached to the `.loop` terminal.** No new op: the `.loop` arm
gets its own exit label, `exit_instr` names the `.loop` instruction, and the
dispatcher treats that as a clean completion (a productive receipt, tier-0 at
the anchor). Smaller IR surface, but `exit_labels` is indexed by guard
instruction today, the exit-PC and snapshot tables assume `exit_instr` is a
guard, and the silent-set / ledger rows (`emitLedgerAppend`) would need a new
row kind; Rule Z-8 warns against adding those casually.

## How the pieces combine

| | exit E1 (op) | exit E2 (terminal) |
|---|---|---|
| **P1** flag | one op, one load+cmp per iteration | new row kind, one load+cmp |
| **P2** budget | op takes the CAP compare | new row kind, register compare |
| **P3** patch | not applicable | stub only, no per-iteration cost |

P1 and P2 differ in what they trade: P1 reacts at the next iteration but pays
a memory load every time; P2 pays a register compare and reacts within CAP
iterations, and also gives every trace a bounded stay. P2 changes the number
of exits a long loop makes, which is Q1.

## Phasing

0. Measure: build a throwaway P1 and P2 in the x64 emitter on a shadow tree and
   run `just bench` and `--jit-stats` on the whole board, not one benchmark.
   Record cycles per iteration and the residency column. Nothing from this
   phase is kept unless it is the chosen design.
1. tier-1a poll and its dispatcher handling.
2. Native x64 poll, exit, prover and allocator updates.
3. Tests (see Goals).
4. Viz and schema only if E1.

## Open questions for review

- **Q1 — tiering counts.** P2 adds exits to long loops; P1 and E1 add none
  unless interrupted. Do the hot-exit counters, ledger rows and silent
  promotion treat a CAP exit as a productive receipt without changing which
  traces get compiled or armed? Phase 0 reads the `-Djit-debug` probe output on
  the board to answer it.
- **Q2 — replay.** An interrupted run is not reproducible by definition; what
  does `--emit-effects` record? One proposal: nothing, the interrupt ends the
  line as a fault the host reports. A replay of a run that was interrupted
  would then run the loop to its natural end, so the effect log may need to
  say the program was cut. Decide with doc 65.
- **Q3 — keyframe cuts.** `safepoint_seq` counts tier-0 instructions. P2 adds
  tier-0 dispatches at every CAP exit, shifting the count for the same run
  across modes. Is the count compared across modes anywhere other than inside
  one mode's own record/replay pair?
- **Q4 — signal race.** An allocation's `gc_headroom -= 1` can overwrite the
  handler's zero (one lost Ctrl-C, today). With P1 in native the flag word
  would be better than the headroom, which argues for a separate
  `interrupt_requested` byte at a stable address; tier-0 would still check it
  in the cold trampoline only. Confirm that costs the prologue nothing.

## References

- `docs/design/75-process-spawn-and-shell.md` §4 (the REPL), §6 (Ctrl-C and
  children).
- Doc 17 (coarse deopt, exit patching), doc 45 D6 (precise traces and the
  eager `guard_gc`), Rule Z-8 in `CLAUDE.md`.
- `src/irinterp.zig` (`.loop`), `src/nativegen.zig` (`.loop`, exit stubs),
  `src/trace_exec.zig` (`ExitReason`), `src/interp.zig` (`gcTrampoline`).
- LuaJIT `lj_asm_patchexit` for P3.
