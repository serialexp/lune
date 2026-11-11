# 87 — Joining loops across returns and calls — Design

Status: draft, not implemented. One prerequisite fix landed with this draft
(an admitted region no longer turns off native frame motion, §4.4). Q1–Q5
(§10) are open, and no phase starts before Q1 and Q2 are answered.
Owner: Bart
Last updated: 2026-11-11

## Implementation status

Tracking the gap between this design and what's on the main branch.
Tick items as they land; move whole sections to "done" once everything
inside them is checked.

### Done

- [x] **Research round.** LuaJIT's mechanism (`lj_record_ret`,
  `rec_loop_jit`, its trace list on the probe and on `records_script`),
  and mahina's machinery as it stands: continuation arming, exit
  attachability, the one-shot kinds, frame links, regions (§3, §4).
- [x] **Probe and baseline.** The two-function ring of §2.1 at four trip
  counts on tier 0, the JIT and LuaJIT, and a callgrind split of one
  round (§2.2).
- [x] **Prerequisite fix: an admitted region no longer turns off native
  frame motion and the one-shot lane** (§4.4; doc 54 "Episode descent
  gate", follow-up of 2026-11-11). `fib(30)` after a linked 300×300 nest:
  10,092 M instructions → 1,017 M.

### Outstanding

- [ ] **Q1 — the shape of the join** (§5.2 against §5.3): one glue trace
  whose frames move at its end, or a page per frame joined by frame
  links.
- [ ] **Q2 — regions and the ledger on a ring** (§5.5): rows that carry
  frame motion, or the ring as one region of the caller's activation;
  and whether the "inert only" slice is the first step.
- [ ] **Q3 — the seam itself** (§5.6): a lean loop episode before the
  join, alongside it, or not now.
- [ ] **Q4 — v1 scope** (§7): numeric `for` only, one frame down and one
  up, fixed result counts.
- [ ] **Q5 — the probe as a board row** (§8 Phase 0).
- [ ] **Review round.** §11 lists the claims this draft makes from
  reading, not from running; each needs a check against the source
  before the phase that leans on it.
- [ ] **Phase 0 — the probe row and counters** (inert).
- [ ] **Phase 1 — a recording that starts at a loop's exit and leaves the
  function.**
- [ ] **Phase 2 — the join runs, with the runtime moving the frames.**
- [ ] **Phase 3 — the frames move in machine code.**
- [ ] **Phase 4 — regions on a ring** (per Q2).
- [ ] **Phase 5 — widen**: `while` and generic `for` loops, more than one
  frame, a caller with several return sites.
- [ ] **Defer: vararg frames, `pcall`'d frames, multiple-result returns
  (`all_results`), coroutine boundaries.** Each declines to tier 0, as
  doc 54's pop does today.

## 1. Why this exists

A common program shape is an outer loop that calls helpers, each of which
runs a loop of its own:

```lua
for round = 1, N do
    total = total + carried(inv) + owed(inv)   -- each has `for i = 1, #inv`
end
```

Each helper's loop gets a trace. Nothing connects the end of one loop to
the start of the next. Between them the program leaves native code,
returns, runs the caller, calls, runs the callee's first instructions, and
enters the next loop's trace through the dispatcher. On the probe below
that costs 4,955 instructions a round against 2,426 for the two loops
themselves. LuaJIT spends 231.

`records_script` (doc 85 §7) is this shape with four helpers. TODO.md
carries three entries that are cases of it: "Nothing joins a loop to the
next one across a return and a call", "A short loop in a function is
entered from tier 0 on every call", and the heapsort entry "A short loop
in a function called from a loop".

This doc is the contract for joining those loops: what is recorded, where
the frames move, and what the region and ledger machinery must learn.
Rule Z-8 asks for a design doc before any new arm kind or mediation
layer; §4.1 is the ladder's answer (no arm kind can express the
transition today).

## 2. Evidence

### 2.1 The probe

```lua
local N = tonumber(arg and arg[1]) or 20000
local TRIPS = tonumber(arg and arg[2]) or 64
local data = {}
for i = 1, TRIPS do
    data[i] = i % 13
end
local function sum(t)
    local s = 0
    for i = 1, #t do
        s = s + t[i]
    end
    return s
end
local function weigh(t)
    local s = 0
    for i = 1, #t do
        s = s + t[i] * i
    end
    return s
end
local check = 0
for round = 1, N do
    check = (check * 31 + sum(data) + weigh(data)) % 1000000007
    data[round % TRIPS + 1] = round % 13
end
print(check)
```

`perf stat`, user instructions, 6f34c37 with §4.4's fix. Every row runs
1.28 M iterations of each loop; only the number of rounds changes.

| trips | rounds | tier 0 | JIT | LuaJIT |
|---|---|---|---|---|
| 4 | 320,000 | 1,042.3 M | 69.4 M | 94.3 M |
| 16 | 80,000 | 638.2 M | 456.1 M | 38.6 M |
| 64 | 20,000 | 537.2 M | 150.5 M | 24.7 M |
| 256 | 5,000 | 512.0 M | 74.0 M | 21.2 M |

The three lower rows are linear in the number of rounds, so they split
into a cost per round and a cost per iteration:

| | per round | per iteration |
|---|---|---|
| tier 0 | 1,681 | 197 |
| JIT | 5,094 | 19.0 |
| LuaJIT | 231 | 7.8 |

- **The JIT pays three times what tier 0 pays for a round's glue.** At 16
  trips it is 71% of tier 0's whole run.
- **At 4 trips there is nothing to join.** main's loop root records
  through both calls and unrolls both loops (`loopunroll` is 15), and the
  round costs 217 instructions, under LuaJIT's 295. The cliff is between
  15 and 16 trips.
- **The per-iteration gap (19.0 against 7.8) is a different subject**
  (codegen of the loop body) and is not this doc's.

### 2.2 Where a round goes

Callgrind on an `x86_64_v3` ReleaseFast build of cea1955 with the fix
(valgrind has no AVX-512), 64 trips, the difference between 6,000 and
2,000 rounds divided by 4,000. Self cost.

| where | instructions per round |
|---|---|
| machine code of the two loop traces (126 iterations) | 2,426 |
| `Vm.enterSelectedTrace` | 1,146 |
| receipt, provenance and arming helpers it calls | 1,341 |
| tier-0 handlers | 2,468 |
| total | 7,381 |

The helpers, largest first: `TraceCode.anchorSourceInstr` 260,
`driveDispatcherSilentResult` 154, `maybeArmContinuation` 136,
`guardExitPc` 128, `settleNativeCallProvenance` 94,
`isSourceBranchGuardExit` 86, `onCallEntryTraced` 82,
`captureNativeCallProvenance` 60, `drainSilentResult` 52,
`hasNativeLoopDoneLink` 50, `continuationReachesEnclosingBackEdge` 46.

Tier 0 runs the glue (`opCall` 501, `opForPrep` 410, `opRet` 314 and the
straight-line code) and one iteration of each loop: the trace's loop-done
exit is taken before the final iteration is committed, so tier 0 replays
it.

So a round is one third loop bodies, one third dispatcher (about 1,240
per visit to a loop), and one third tier 0.

### 2.3 `records_script`

20,000 rounds, four helper loops of 64 trips, 9,221 M instructions on the
JIT against 853 M on LuaJIT. `--jit-stats` on 6f34c37 with the fix:

- 37.1% of cycles in tier-0 loop bodies with no trace (`owed`, `tags`
  and `count` do not record; doc 85 §7.3 and TODO.md list why);
- 28.3% outside loops;
- 12.5% in the steering seam (99,965 ledger walks at ~2,830 cycles);
- 20.4% in native code.

**The join is not the largest share of this row today.** The loops that
do not record are. The join's share grows as they start recording: each
one that does adds a seam per round.

## 3. What LuaJIT does

On the probe, five traces:

```
[TRACE   1 ring2.lua:4 loop]
[TRACE   2 ring2.lua:9 loop]
[TRACE   3 ring2.lua:16 loop]
[TRACE   4 (2/3) ring2.lua:12 -> 3]
[TRACE   5 (3/3) ring2.lua:19 -> 2]
```

Traces 2 and 3 are the two loops. Trace 4 starts at the exit of `sum`'s
loop, returns into main, runs main up to the call of `weigh`, enters it
and stops at its loop with a link to trace 3:

```
---- TRACE 4 start 2/3 ring2.lua:12
0001    num SLOAD  #3    PI
0003 >  p64 RETF   proto: 0x708ef7a63a70  [0x708ef7a63b78]
0004 >  num SLOAD  #12   T
0005    num ADD    0004  0001
0006 >  fun SLOAD  #6    T
0007 >  tab SLOAD  #4    T
0008 >  fun EQ     0006  ring2.lua:14
0009    int ALEN   0007  nil
0010 >  int LE     0009  +2147483646
0011 >  int GE     0009  +1
0012    num CONV   0009  num.int
---- TRACE 4 stop -> 3
```

Trace 5 does the same from `weigh`'s exit, passes main's own back-edge on
the way, and links to trace 2. main's loop has no trace. On
`records_script` the ring has four loops and four such side traces
(`25 (3/3) :112 -> 4`, `28 (13/3) :123 -> 5`, `27 (5/3) :134 -> 6`,
`10 (6/1) :143 -> 3`).

The mechanisms, in `lj_record.c`:

- **A return below the start frame is a guard.** `lj_record_ret` at
  `framedepth == 0` in a side trace emits `IR_RETF` holding the caller's
  proto and the return pc, bumps `J->retdepth`, shifts the result slots,
  and keeps recording in the caller. A root trace aborts there instead
  (`LJ_TRERR_LLEAVE`: a return would leave its loop).
- **A side trace that reaches a compiled loop links to it at any depth.**
  `rec_loop_jit` ends the recording with `LJ_TRLINK_ROOT`. The frame
  depth matters only when a trace wants to form a loop with itself
  (`framedepth + retdepth == 0`). A root trace that reaches an inner loop
  aborts (`LJ_TRERR_LINNER`), which is why main's loop never gets one.
- **A frame is two stack slots.** The call the side trace leaves standing
  when it links is a pair of slot stores, and the base moves by an add.
  Snapshots hold the frame links, so an exit anywhere restores the
  frames.
- **The side trace is specific to its caller.** A different caller fails
  `RETF` and grows its own side trace from that exit.

Two things do not carry over as they are. mahina's frames are `CallFrame`
records with a `call_seq` and a region context, not stack slots. And
mahina's exits are coarse: a failing guard resumes at the trace's anchor,
so a trace cannot move a frame and then fail a guard.

## 4. What mahina has today

### 4.1 The path, step by step

`--dump-aborts` on the probe at 64 trips shows every step of the path
ending a recording:

| step | what stops it | where |
|---|---|---|
| the loop-done exit of `sum`'s root | No continuation is armed: `maybeArmContinuation` wants a back-edge of the same function within 128 instructions, and the scan stops at `ret`. `exitAttachable` refuses loop-done exits (`loop_done=3`). The final iteration replays in tier 0. | `trace_link.zig`, `trace_exit_attach.zig` |
| `ret` | A recording that is not one-shot aborts `cross_frame` at a depth-0 `ret`. | `recRet` |
| main between the calls | A `.cont` is recorded at the resume pc and dies at the next loop it meets: `cont_backedge`, 6 at the inlined callee's `for_prep` and 6 at main's own `for_loop`. | doc 44 D12b |
| the call of `weigh` | The recorder inlines the callee. The only terminal that leaves by a call is a direct self-call (`self_call_interp`). | doc 44 D11 |
| `weigh`'s first instructions | Its head trace aborts at the running `for_prep` (`nyi_opcode`, 6 each for `sum` and `weigh`): a head is root-like, and a root never links. | `recForPrepLink` |
| the link into `weigh`'s root | At `inline_depth > 0` `recForPrepLink` unrolls instead of linking: the link target is resolved in the anchor's proto. | `recForPrepLink` |
| main's own loop | Its root dies unrolling the callee's loop (`loop_unroll`, 227 IR, 6 times). | `noteLoopIteration` |

Rule Z-8's ladder ends at its last step here: the exit is not armed
because no trace exists at its destination, and no trace can exist there
because every recording kind stops at one of the rows above.

### 4.2 Frame links (docs 44 and 54)

Native frame motion exists for recursion:

- A head or continuation page whose terminal is a direct self-call pushes
  a `CallFrame` inline and jumps to the head page (`.call_head`).
- A page whose terminal is a return pops inline and jumps to the
  continuation page anchored at the caller's resume pc (`.ret_cont`,
  four resume-pc slots per page).

Both are pinned to one proto. `tryArmFrameLinks` wants parent and child
anchored in the same proto. The pop's walls pin the parent frame to the
anchor proto, want the frame's `ctl` byte zero (no `pcall`), adjacent
windows, no open upvalue at or above the frame, and a fixed result
count. The episode context (`NativeSeedCtx`) treats `proto` and
`reg_capacity` as constant for the episode; a push or a pop refreshes
only the closure, the base and `call_seq`.

Frame motion "begins on, and only ever transfers among, one-shot pages"
(doc 54). The loop replay and the silent burst both panic on a
frame-motion edge. A ring breaks that premise by construction: a loop
page reaches frame motion.

Per call, today's links cost about 376 instructions on `fib(30)` (1,013 M
for 2.69 M calls), each call being a push, a pop and on average two page
entries.

### 4.3 Regions

A region is a cycle of traces of one proto, opened per activation
(`RegionKey{ region_id, activation = call_seq }`) and closed when control
leaves the loop. `resolveSuccessorAnchor` gives no edge across protos
("a known deferred refinement") and none from a one-shot trace. Region
receipts are filed by replaying ledger rows after a native burst, against
the region context current at replay time.

On the probe neither loop has a region (each is a lone root). On
`records_script` `carried` does: its root has exit-side children, and its
activation opens and closes once a round (`loop_exit=39980`).

### 4.4 The gate that was too wide (fixed with this draft)

Native frame motion and the quiet one-shot entry both asked
`RegionPolicy.receiptsInert()`, which is false from the moment any region
is admitted until its traces die. One linked loop nest anywhere turned
both off for the rest of the program. The region term is now
`noOpenActivation()` (and `receiptInertFor(trace)` for the one
loop-anchored case); doc 54 holds the argument. What still declines:
frame motion while an activation is open anywhere. A ring whose loops
have regions of their own is that case, and §5.5 is about it.

## 5. Design

### 5.1 A ring is a nest whose inner loops are in callees

Doc 15 already joins an inner loop to its outer loop inside one function:
the inner root's loop-done exit starts a continuation, which records the
outer body forward and ends with a link to the inner root. The ring is
the same picture with a return on one side of the glue and a call on the
other. The caller's frame is the one thing that stays put for the whole
ring, as the outer loop's frame does in a nest.

Call the code between one loop's last iteration and the next loop's first
the **glue**: the rest of the callee, the return, the caller up to the
next call, the call, and the next callee up to its `for_prep`. Its net
effect on the frame stack is one pop and one push, both under the same
caller frame. With adjacent windows the new callee's window starts where
the old one did.

Two shapes can carry the glue. They differ in where the frames move.

### 5.2 Shape A — one glue trace, frames move at its end

LuaJIT's shape, fitted to coarse exits.

- **Start.** A continuation recording anchored at the loop's exit pc, as
  doc 15 arms one, without the "enclosing back-edge" condition. The
  loop-done exit links to it (`loop_done_linked`), which also commits the
  final iteration natively instead of replaying it.
- **Return.** A depth-0 `ret` records a caller pin instead of aborting:
  the parent frame's proto and resume pc, a zero `ctl` byte, a fixed
  result count. The results move to the caller's registers and recording
  continues in the caller. Nothing is popped yet.
- **Caller code and the call** record as they do now; the callee is
  inlined.
- **End.** At the callee's `for_prep`, with a root compiled there, the
  recording closes with a link that also moves the frames: flush the
  sunk stores, check the walls (§4.2's, minus the same-proto pin),
  rewrite the top `CallFrame` for the new callee, advance `call_seq` and
  `tick` as a return and a call would, set the caller's resume pc, then
  enter the root with the registers `for_prep` would have left.
- **Exits.** Every guard sits before the frame motion, so a failing
  guard resumes at the anchor with the old frame intact. That is today's
  coarse exit, unchanged.
- **Addressing.** With the caller pinned, the callee's window is at a
  fixed offset above the caller's, so the trace can address both from
  the caller's base. It is the layout of a trace that starts inside an
  inlined call, except that the frame it starts in is real.
- **A second caller** fails the pin at entry and gets a sibling at the
  same anchor (doc 17's siblings).
- **The caller's own back-edge** (the last glue of a ring) is passed and
  counted against `loopunroll`, as LuaJIT's side trace does.

What has to be built: the return below the anchor in the recorder
(`recRet`, the register window, entry slots, exit snapshots and exit
locations below the anchor's base); the link at depth
(`recForPrepLink`, `driveChain`, tier 1a); the frame-moving link in both
executors; an episode context whose `proto` and `reg_capacity` change at
the link.

### 5.3 Shape B — a page per frame, joined by frame links

Doc 44's shape, widened from recursion to any call.

- **A tail page**: a one-shot anchored at the loop's exit pc in the
  callee, closing at the `ret` with today's `return_interp` terminal.
- **`.ret_cont` across protos**: the pop sequence loses its same-proto
  pin and keys on the parent's proto and resume pc.
- **The caller's `.cont` page** at the resume pc. It closes at the next
  call with a terminal for a call to another function (today's
  `call_interp` is a host call; a direct self-call is
  `self_call_interp`), and may pass its own frame's back-edge.
- **`.call_head` across protos**: the push sequence for a callee that is
  not the anchor proto.
- **The callee's head page**, which closes at `for_prep` with a link to
  the loop root instead of aborting.

Each page lives in one frame, so no register is addressed below an
anchor's base and no terminal does more than one frame motion. A guard
that fails on the caller's page resumes on the caller's page; the pop
before it stays done.

What has to be built: the two link kinds across protos (arming, the
inline sequences, the episode context); a one-shot kind anchored at a
loop exit and its `loop_done_linked` arm; a `.cont` that closes at a
call and passes one back-edge; a head that links.

### 5.4 Side by side

| | A — one glue trace | B — a page per frame |
|---|---|---|
| traces per glue | 1 | 3 (tail, caller segment, head) |
| page entries per glue | 1, plus the loop root's | 3, plus the loop root's |
| frame motion | one combined pop and push, at the link | a pop and a push, at two terminals |
| values across the glue | stay in the trace (the loop's result reaches the caller's arithmetic without a store and a reload) | stored and reloaded at each hop, with entry guards on each page |
| callers of one helper | a sibling per caller at the exit anchor | one tail page and one head page for all callers; four resume-pc slots per tail page |
| a guard failing in the caller's code | resumes in the callee, at the loop's exit, and tier 0 redoes the return | resumes in the caller |
| new recorder concepts | a return below the anchor; a link at depth; a frame-moving link | a call-out terminal; a head that links; a loop-exit one-shot |
| reuse of docs 44 and 54 | the walls and the frame-write sequences | the walls, the sequences, the link kinds and their arming |
| what recursion gains | nothing directly | cross-proto links also serve mutual recursion and any hot call that is not a self-call |
| known cost today | not built; LuaJIT's 231 per round is the same shape | 376 instructions per call on `fib(30)` with the same kind of pages, so on the order of 1,100 per round on the probe before doc 54's P3 |
| duplication | the glue trace re-records caller code that a `.cont` page may also hold | the caller segment is recorded once and shared with recursion's continuation machinery |

Both shapes need the same four things underneath: a recording that
starts at a loop's exit and leaves the function; native frame motion
between two different protos; a loop root entered from a frame native
code just pushed; and an answer for regions (§5.5).

### 5.5 Regions and the ledger on a ring

Either shape puts frame motion on a path that loop pages are on. Three
ways to account for it; the first is a subset of the other two.

- **(R-c) Inert only.** A glue link is armed only between traces for
  which `receiptInertFor` holds, and taken only while no activation is
  open (today's gate, after §4.4). The probe's ring forms. A loop with a
  region of its own (siblings, exit-side children, an inner nest) is
  entered and left through the dispatcher as now; on `records_script`
  that is `carried`.
- **(R-a) Rows carry frame motion.** Each frame motion on a ring writes
  a marker row. The replay tracks depth and `call_seq` through the
  markers (both are deterministic counters), files every loop row under
  the activation it ran in, and opens and closes activations in order.
  This is the "per-row activation identity" that doc 44 recorded as a
  non-goal. The ledger holds 32 rows, so a ring writing four rows a round
  walks every eight rounds. Rings never become silent.
- **(R-b) The ring is one region of the caller's activation.** Glue
  links become structural edges across protos. The cycle (the loops,
  their own siblings, the glue traces) is one region keyed by the
  caller's `call_seq`, whose members run one frame above their owner.
  Promotion to a silent set makes the ring rowless, as it does for a
  nest today. Owner election, the region context during frame motion
  and the close conditions all need definitions for a region that spans
  frames. Doc 47 Increment B (election on a closed cycle) is the nearest
  existing problem.

(R-a) keeps one region model and adds a row kind and replay logic. (R-b)
changes what a region is and removes the rows. They can be built in that
order or (R-b) alone.

### 5.6 The seam itself

Whatever joins loops, a loop is still entered from tier 0 whenever the
ring has not formed: the first rounds, a cold caller, a declined link, a
shape outside v1. That visit costs about 1,240 instructions on the probe
(§2.2). Doc 84 did this work for one-shot pages; doc 44 D9 left "the
loop-anchor quiet episode" as a follow-up that was never built.

Two items in §2.2's split repeat a decision that cannot change:

- `maybeArmContinuation` re-derives "no enclosing back-edge" on every
  loop-done exit: 384 instructions a round with its callees.
- `isSourceBranchGuardExit` re-derives facts about a fixed guard: 280
  instructions a round with its callees. `anchorSourceInstr`, reached
  from it and from `maybeArmContinuation`, takes 130 instructions per
  call to find a fixed guard's source instruction.

A lean loop episode is independent of the join and survives it. It could
come first, alongside, or later (Q3).

### 5.7 Determinism and replay

- The frame motion writes the `CallFrame` fields, `call_seq` and `tick`
  exactly as `opRet` followed by `opCall` would (doc 54's rule for the
  push and the pop).
- Arming and the decision to record are functions of deterministic
  counters only: the loop-done exit's hit count, as `hotexit` is today.
- A glue link is one more arm through `commitSlotMutation`; replay sees
  it as it sees every other arm.
- The ten-leg matrix must print the same with glue traces on tier 1a,
  native, and with recording on and off.

## 6. Goals

- A loop that ends, returns, and is followed by a call into another
  loop reaches that loop without the dispatcher and without tier 0.
- The probe's round costs no more than twice LuaJIT's (§9).
- Loops with regions of their own can be on a ring (after Q2).
- No change to a loop that is not followed by a return.

## 7. Non-goals (v1)

- Loops other than numeric `for` at either end of the glue.
- More than one return or more than one call in a glue.
- Vararg frames, `pcall`'d frames, `all_results` returns, coroutine
  boundaries, a callee with open upvalues at the return.
- The per-iteration cost of the loop bodies (19.0 against 7.8).
- The loops of `records_script` that do not record at all.

## 8. Phasing

Phases 0 and 1 are the same for both shapes.

- **Phase 0 — the probe row and counters (inert).** §2.1's program as a
  board row at 64 trips with its hashgate rows; `--jit-stats` counters
  for glue wants, recordings, arms, hits and declines by reason;
  jit-debug probes for each.
- **Phase 1 — a recording that starts at a loop's exit and leaves the
  function.** Arming from the loop-done exit without the enclosing
  back-edge condition; the loop-done exit links to it. Shape A: it
  records through the return and to the next loop, and runs on tier 1a
  with the runtime doing the return and the call. Shape B: it is the
  tail page, and ends at the `ret`.
- **Phase 2 — the join runs natively, frames moved by a callout.** As
  doc 44 D11 began: the helper is `opRet` and `opCall` verbatim. Shape
  A: the frame-moving link. Shape B: the two cross-proto links, the
  call-out terminal, the head that links.
- **Phase 3 — the frames move in machine code.** The inline sequences,
  as doc 54 P0–P1 did for recursion.
- **Phase 4 — regions on a ring**, per Q2. (R-c) is the gate Phases 1–3
  run under.
- **Phase 5 — widen** to `while` and generic `for`, more frames, more
  return sites.

Each phase lands behind `just test`, the jit-debug gate and the
hashgate, and is measured on the probe row.

## 9. Budget (Rule 20)

The probe at 64 trips, instructions per round over the two loop bodies:

| | per round |
|---|---|
| today | 4,955 (callgrind; 5,094 by `perf stat`) |
| tier 0's own glue | 1,681 |
| LuaJIT | 231 |
| proposed ceiling when Phase 3 is in, rows still written | 460 |

The ceiling is twice LuaJIT's. A phase that leaves the probe above tier
0's 1,681 has not paid for itself and does not land as "done".

## 10. Open questions for review

- **Q1 — the shape.** A (§5.2) or B (§5.3). §5.4 lists what each
  costs and reuses.
- **Q2 — regions.** (R-a), (R-b), or (R-a) then (R-b); and whether
  (R-c) ships first as its own step.
- **Q3 — the seam.** A lean loop episode (§5.6) before the join,
  alongside it, or not now. The two repeated refusals listed there are
  small enough to fix on their own if wanted.
- **Q4 — v1 scope.** §7's list.
- **Q5 — the probe as a board row**, and at which trip counts (64 alone,
  or 16 and 64).

## 11. Claims a review round should verify

These come from reading the source, not from an experiment:

- A callee's window starts where its caller's ends for every non-vararg
  call, not only for the self-calls `nativeFrameMotionAssert` checks.
- `loop_done_linked` commits the final iteration for a child that is not
  a doc 15 continuation.
- Nothing a call or a return does in tier 0 is missing from the list
  "frame fields, `call_seq`, `tick`, region context" (hot-call counters,
  `onCallEntryTraced`, safepoint numbering for replay).
- The episode context can change `proto` and `reg_capacity` mid-episode
  without breaking a consumer that read them at entry.
- Shape A's addressing from the caller's base fits exit snapshots and
  exit locations as they are stored today.
- (R-a)'s replay can derive every row's `call_seq` from marker rows
  alone when a burst ends mid-ring.

## References

- `~/Projects/LuaJIT/src/lj_record.c`: `lj_record_ret`, `rec_loop_jit`,
  `rec_loop_interp`.
- Doc 15 (nested-loop linking), doc 17 (sibling handoffs), doc 44 (call
  anchors, frame links), doc 47 (regions, the receipt tax, Increment B),
  doc 54 (inline frame motion; the descent gate follow-up), doc 56
  (exit-started side traces; "side traces leaving the anchor frame" is a
  non-goal there), doc 58 (while-done links), doc 84 (the lean one-shot
  lane), doc 85 §7 (`records_script`).
- `src/trace_link.zig` (`maybeArmContinuation`, `resolveSuccessorAnchor`),
  `src/trace_recorder.zig` (`recRet`, `recForPrepLink`,
  `noteLoopIteration`), `src/trace.zig` (`tryArmFrameLinks`),
  `src/nativegen_emit.zig` (`emitInlineSelfRetPop`),
  `src/trace_region_policy.zig` (`noOpenActivation`, `receiptInertFor`).
