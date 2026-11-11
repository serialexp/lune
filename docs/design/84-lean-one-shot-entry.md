# 84 — The lean one-shot entry lane — Design

Status: partial — Phases 1, 2a, 3 and 5 landed, with the runtime half of
Phase 4 (the quiet episode reads the raw native result) and the first
slice of a cheap decline (the lean decline tail, §3.6). Phase 4's other
parts need a page capability and are sized in §4.4. The refusal want (§3.6) is
prototyped and measured: it costs more than it saves until a declined
entry is cheap. Q5 (its order against Phases 3 and 4) went unanswered on
2026-11-11; order A is being followed until Bart says otherwise. Phase 2b
is parked until Phases 3 and 4 are in. Q1-Q4 settled (§7) after reviews
by Codex and Antigravity
Owner: Bart
Last updated: 2026-11-11

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole phases to Done once everything inside them is checked.

### Done

- [x] **An admitted region no longer takes one-shot traces off the lane**
  (§3.1 follow-up, 2026-11-11). The region term of `headEpisodeQuiet` was
  `receiptsInert()`; it is `noOpenActivation()` now. Landed with the same
  fix to the frame-motion descent gate (doc 54).
- [x] **A strike on an abandoned gate no longer retires the bar memo and
  the settled bits** (§4.5 follow-up, 2026-11-11). Found on
  `records_script`, where two anchors were struck once a round each, for good:
  −0.86% JIT instructions there, the rest of the board unchanged.
- [x] **Step 1 of TODO (B): barred anchors are memoized in the call and
  return hooks** (4a8c8e6). An exact direct-mapped memo
  (`TraceState.bar_cache`) replaces two hash lookups per call and per
  return on an anchor that has no trace and is barred from recording. The
  pure probe (§2.1) went from +662 to +573 instructions per call. This doc
  is step 2.
- [x] **Phase 0a — the probe is a board row.** `bench/call_small_fn.lua`
  is §2.1's program at 10⁶ calls, with its hashgate rows (all three modes
  and LuaJIT agree).
- [x] **Q1 — per-anchor knowledge: (b), two membership bits** (§4.1).
- [x] **Q2 — admission: (a), a blocker word of its own** (§4.2).
- [x] **Q3 — completion counters: (a), in the runtime** (§4.3).
- [x] **Q4 — heads and continuations together** (§5).
- [x] **Phase 1 prerequisite — one funnel for penalty mutations** (§4.1).
  `penaltyEntry`/`removePenalty` (by anchor) and
  `penaltyEntryAt`/`removePenaltyAt` (from a trace) are the penalty map's
  only inserts and removals outside the bulk clears. The gate already had
  `bumpGateEntry`/`clearDispatchGate`; the member-amnesty loop now goes
  through the latter too.
- [x] **Check: `opJFuncHead`'s bypass set omits `pending_ret_anchor`.**
  The omission is sound: `pending_ret_anchor` is always null at a
  `jfunc_head` handler. Every setter (`onRetResume`, `onHostCallTerminal`,
  the probe and want transfers) flips to `.full` and parks at the anchor's
  resume pc. That pc's prologue consumes or discards the anchor
  (`maybeStartCont`). The one pending that survives a prologue is kept at
  its host call's pc. That pc holds a `call` op, and pc 0 never does: the
  compiler loads the callee first. `opJCont` needs the term because a
  continuation can sit over a `call` (the outer call in `f(g())`). A
  Safe-build assert in `opJFuncHead` now pins this. Phase 2's word can
  carry the bit for both opcodes at no cost.
- [x] **Phase 1 — a per-anchor quiet predicate** (§4.1). Every trace
  carries `anchor_penalty` and `anchor_gate`. `headEpisodeQuiet` and the
  productive legacy receipt read them instead of the program-wide
  `count() != 0` terms. JIT board (instructions, against the parent
  commit): binary-trees −16.5%, spectral-norm −7.2%, globals_script
  −1.2%, pcall_faults −0.3%; euler14-bit +0.4% and nsieve +0.03% (see
  the §4.1 follow-up). call_small_fn is unchanged; its one anchor never
  had a penalty. The tier-0 board is flat.

- [x] **Phase 2a — the lane at the patch site** (§4.2, "Implemented").
  `opJFuncHead` and `opJCont` test one gate first (`oneShotGate`). A
  settled entry runs the quiet episode directly (`enterOneShotLane`): the
  long-form gates, the walk prelude and the epilogue are not executed.
  Safe builds assert the gate against the long form on every entry. JIT
  board (instructions, against the parent's sources): call_small_fn
  −5.3%, binary-trees −1.8%, co_pingpong_d20 −1.4%, spectral-norm −0.8%,
  ray −0.2%; globals_script +0.10% and array3d +0.04% (their entries are
  refused on a hash seed and pay a few instructions more). The tier-0
  board is flat. The pure probe is at +500 per call (was +577 on the same
  measure).

- [x] **A stale head-sibling want no longer bars every other anchor**
  (1192436; found building §3.6). `wants_head_sibling` is one slot for the
  program. `BottomUpTree`'s want was raised and its anchor gated in one
  receipt, so no walk consumed it and no other anchor could ask for a
  sibling. Another anchor's hot exit now displaces a standing want. The
  board is unchanged; the refusal want needs it.
- [x] **Phase 0c — the two-shape probe is a board row.**
  `bench/call_two_shapes.lua` calls one small function with two table
  shapes in turn, from a loop that cannot trace: 500,000 iterations, two
  calls each, one of them refused at the head trace's entry checks. Its
  hashgate rows agree in all three modes and with LuaJIT.

- [x] **The lean decline tail** (§3.6, "Landed: the lean decline tail").
  A lane entry whose incumbent declined returns straight to the
  canonical instruction when the walk tail has nothing to do: the
  incumbent is the only trace at its anchor, the anchor is below sibling
  capacity, no sibling want stands for it, and there is nothing to merge
  or drain (`laneDeclineSettled`). Safe builds assert the walk tail's own
  tests on every such decline. A refused call costs 216 instructions
  less. JIT board (instructions, against the parent's sources):
  `call_two_shapes` −7.8%, binary-trees −5.9%, the rest flat. The tier-0
  board is flat.

- [x] **Phase 3 — a lean completion** (§4.3, "Implemented").
  `noteHostCallTerminal`, `noteHeadSiblingCompletion` and
  `consumeHeadWalkFail` test their own first condition inline, at every
  call site, and make a call only when there is something to file,
  retire or charge. A plain completion makes none of the three.
- [x] **Phase 4, the runtime half — the quiet episode reads the raw
  result** (§4.4, "Implemented"). `enterHeadNativeQuiet` keeps the
  `NativeResult` and decodes it (ledger rows, `ExecResult`) only for a
  pushed descent or a fused burst. A completion, a refusal and a guard
  exit read their scalar fields from it. With Phase 3: a completing call
  costs 87 instructions less and a refused one 67. JIT board
  (instructions, against the parent's sources): `call_small_fn` −6.3%,
  `call_two_shapes` −6.0%, binary-trees −1.1%, spectral-norm −1.1%, ray
  −0.6%, `globals_script` −0.6%, `meta_fields` −0.3%, array3d −0.3%;
  nothing rose. The tier-0 board is flat.
- [x] **Phase 5 — a one-load return refusal** (§4.5, "Implemented").
  One settled bit per pc, in a trailer behind the proto's code image.
  `opRet` tests it inline, then the live `.jcont`, and calls the long
  form only when neither answers. A settled return costs 74 instructions
  less. JIT board (instructions): `call_small_fn` −5.7%,
  `call_two_shapes` −6.1%, `co_pingpong` −3.0%, binary-trees −2.0%,
  `globals_script` −1.8%, ray −1.1%, spectral-norm −0.9%; `gsub_fn`
  +0.135% and `compile_multret_chain` +0.046% (a first image in a program
  that had none, §4.5). The tier-0 board is flat.
- [x] **An activation's code memo is filled at its creation** (§4.5,
  "Follow-up"). A resumable native's activation no longer pays the image
  hash on every call once an image exists. JIT board: `tostring_meta`
  −3.7%, `gsub_fn` −0.11% (back to +0.02% against the tree before
  Phase 5). Tier 0: `tostring_meta` +0.14%.

  Q1-Q4 were settled 2026-11-10. Bart asked for second opinions from Codex and
  Antigravity and for the tiebreak to be settled here. Both reviewers
  picked the same four options independently. Their factual corrections
  were checked against the code and folded into §4.1–§4.4 as follow-up
  paragraphs ("Review, 2026-11-10").

- [x] **The loop-anchor lane** (was "Defer — the loop-anchor lane").
  Built 2026-11-11 as doc 87 §5.6's loop lane, after Bart's answer to
  doc 87 Q3 ("Trim it before the join"). It is a lane of its own, not an
  extension of this doc's one-shot lane: a settled visit through a
  patched loop entry makes the native call `enterSelectedTrace` makes
  and reads a numeric-`for` loop-done exit without the shared consumer.
  Design, checks and numbers are in doc 87 §5.6 ("the trim").

### Outstanding

- [ ] **Phase 0b — baselines on the pinned pool.** Record §2's rows there
  (needs a push, so it waits until Bart asks for one).
- [ ] **Entry refusals raise a sibling want** (§3.6). 46% of
  binary-trees' one-shot entries are refused at the trace's own prologue
  and run on tier 0 after paying the entry. Bart picked option (a) on
  2026-11-11: design note first, then build. The note is in §3.6. The
  prototype works. Re-measured on 5eef689 it costs +9.7% on binary-trees,
  +14.4% on the two-shape probe and +3.7% on ray: a decline at an anchor
  with siblings costs about 380 instructions (the walk tail 275, the
  declined entry 105), and a lean sibling walk would leave the probe 93
  per call behind a plain refusal (§3.6, "Re-measured"). Not landed;
  waits on Q5, and on (ii) or (iii) in particular.
- [ ] **Q5 — what makes a declined entry cheap, and in which order**
  (§3.6, "What would make a sibling pay"). Open, for Bart. Asked on
  2026-11-11 and not answered; order A (Phases 3 and 4 with the refused
  outcome in scope, then re-measure the want) is being followed
  meanwhile, because it is his earlier order and lands no regression.
  The re-measurement is in: (i) alone does not make the want pay, so the
  question is now (ii) or (iii).
- [ ] **Defer — Phase 2b, the blocker word** (§4.2, "Parked"). The
  lane's gate still reads its remaining program-wide conditions one by
  one (three in the gate, about fourteen in `headEpisodeQuiet`, ~40
  instructions). Parked by Bart on 2026-11-11 until Phases 3 and 4 are
  in.
- [ ] **Phase 4, the page capability — entries that skip the episode
  ctx and the result frame** (§4.4, "What is left"). Per entry:
  `prepareNativeEpisode` 38 instructions, the `NativeResult` init 20, and
  on the native side the trampoline and the terminal's ledger row. All
  three need the page to promise that nothing it can reach reads them,
  and a page's armed exits jump into other pages, so the promise has to
  cover what can be armed. Not started; §4.4 has the options.
- [ ] **Phase 6 — re-measure binary-trees' seed cost after doc 81 E2**
  (§4.6). A `.global` seed is a hash lookup per entry in `nativeSeedFn`.
  Doc 81's load-time cells make it a load. This doc does no seed work of
  its own until E2 lands.

## 1. Why this exists

A one-shot trace is a head trace (doc 44: entered at a function's pc 0) or
a continuation trace (entered just after a call returns). Each one is
entered once per call from tier 0, runs a short body and leaves at a `ret`
or a host call. Tier 0 then carries on. Whether such a trace pays for
itself is decided almost entirely by the cost of that entry and exit.

Today that cost is large enough that a head trace on a small function
loses to tier 0 outright:

- **The pure probe** (§2.1) runs 573 instructions more per call with the
  JIT than on tier 0, around a native body of 109.
- **binary-trees** runs 91% more instructions with the JIT than on tier 0
  (§2.2). 59% of its cycles are outside both native code and tier-0
  bodies.
- **`globals_script`** is +18% with the JIT since `set_global` began
  recording. The cause is a new head trace on `rand` (doc 81 §7.1).

Doc 44 D9 built the quiet episode to skip calls that do nothing. It left
two things behind, and this doc is the contract for fixing both:

1. **The structure of the entry itself.** Even on the quiet path, the
   lane has to clear about 400 instructions of checks, marshalling and
   bookkeeping around the body.
2. **The quiet predicate is global.** In a real program it is often false
   for every entry (§3.1).

The target is the one TODO (B) set: a one-line body breaks even against
tier 0.

## 2. Evidence

All numbers are instruction counts. They were taken with callgrind on an
`x86_64_v3` ReleaseFast build of 4a8c8e6 (valgrind has no AVX-512), unless
a row says `perf stat`. Every figure is per call or per entry.

### 2.1 The pure probe

```lua
-- tiny pure callee, called from a loop that cannot trace
local function f(n)
  local x = (n * 16807) % 2147483647
  return x % 7
end
local a, b = {}, {}
local acc = 0
local N = tonumber(arg and arg[1]) or 600000
for i = 1, N do
  if a ~= b then acc = acc + f(i) end
end
print(acc)
```

The probe ran 100k calls: 87.68 M instructions on tier 0 against 145.00 M
with `--trace --jit-native`, or **+573 per call**. Every entry takes the
quiet path.

| Where | Per call | Notes |
|---|---:|---|
| `opJFuncHead`, `enterPatchedTrace` inlined | 178 | bypass set, decline memo, walk prelude, strikes, drain |
| `enterHeadNativeQuiet`, run wrapper inlined | 178 | lease, `prepareNativeEpisode`, `NativeResult` init, result decode, receipts |
| `headEpisodeQuiet` | 40 | 13 checks |
| native body | 109 | tier 0 runs the same four bytecodes in ~145 (`opModIdiv` 108, `opBinNum` 35) |
| `onRetResume` | 73 | refusals only (no hash since 4a8c8e6) |
| `opRet` | +24 | 147 against 123 on tier 0 |
| `noteHostCallTerminal` | 18 | |
| `onCallEntryTraced` | 14 | |
| `gatedBackEdgeHandler` | 37 | the caller's loop, which never traces. Outside this lane (TODO.md) |

The body is break-even or better. Everything else is the seam.

### 2.2 binary-trees

| Measurement | Tier 0 | JIT | Δ |
|---|---:|---:|---:|
| `perf stat`, argument 12 | 2.60 G | 4.97 G | +91% |
| callgrind, argument 10 | 516.6 M | 947.5 M | +431 M |

At argument 10 there are 402k trace entries, so the seam costs **~1070 per
entry**. `--jit-stats` reports 512k self-call pushes, 129k self-return
pops and 262k call-head link hits. `headEpisodeQuiet` was called 402k
times and failed on `penalty.count() != 0 or gate.count() != 0` nearly
every time: the run has six `legacy_thrash` dispatch gates. **Every entry
took the full path.**

| Where (argument 10) | Instructions | Per entry |
|---|---:|---:|
| native code | 128.0 M | 318 |
| `enterSelectedTrace` (self + inlined marshal) | 136.2 M | 338 |
| `nativeSeedFn` | 87.5 M | 218 |
| `opJCont` | 51.2 M | 127 |
| `opJFuncHead` | 28.5 M | 71 |
| `consumePushedDescent` | 26.6 M | 66 |
| `onRetResume` | 17.0 M | 42 |
| `consumeDescentTerminalRow` | 14.7 M | 37 |
| `headEpisodeQuiet` (always false) | 14.1 M | 35 |
| `cachedCodeFor`'s `ImageKey` hash | 12.2 M | 30 |
| `countTracesAt` hash | 8.3 M | 21 |
| `nextTraceExcluding` hash | 8.0 M | 20 |
| `hasNativeLoopDoneLink` | 8.0 M | 20 |

### 2.3 How widely this lane is entered

Trace entries per run of the board's programs, with `--jit-native
--jit-stats`:

| Program | Entries |
|---|---:|
| binary-trees | 2,169,279 |
| `globals_script` | 767,690 |
| `pcall_faults` | 299,982 |
| nsieve-bit-fp | 90,599 |
| `str_gmatch` | 68,211 |
| spectral-norm | 65,675 |

Any program that calls small functions from code that doesn't trace runs
through this lane. That makes it a general fix in the sense of Rule Z-6,
not a binary-trees one.

**What the entries do, 2026-11-11** (after Phase 1; throwaway counters in
the two handlers and the quiet predicate, ReleaseFast, board arguments):

| Program | One-shot entries | Quiet | Refused by | Outcome of the quiet ones |
|---|---:|---:|---|---|
| `call_small_fn` | 999,888 | all | | all complete at the `ret` |
| binary-trees | 2,169,280 | 2,169,141 | | 1,004,790 fail the trace's entry checks; 1,164,489 move frames; none completes at a plain `ret` |
| `co_pingpong_d20`, `_d150` | ~400,000 | nearly all | | nearly all move frames |
| `globals_script` | 705,098 | 112 | hash seed (704,986) | |
| spectral-norm | 28,032 | 20,985 | provenance edges (7,042), promoted sets (5) | |
| array3d | 12,533 | 0 | hash seed | |

Three things follow. The terms of the quiet predicate that refuse in
practice are the hash seed (Phase 6) and provenance edges; region
receipts, demotion, teardown and the debug-log sync never refused on the
board. binary-trees' sibling walk ran 34 times in 2.17 M entries. And a
lane that covered only a completion at the `ret` would cover none of
binary-trees: its quiet entries end in frame motion or in an entry
refusal (§3.6).

## 3. Findings

### 3.1 The quiet predicate is global

`headEpisodeQuiet` asks "is anything live that could observe or steer
this episode?" Most of its 13 terms are about the whole program. For two
of them, the global question stands in for a per-anchor one:

```zig
// The legacy productive removals no-op on empty maps; head gate READS
// (want transfer, repatch) stay correct because non-empty forces full.
if (ts.penalty.count() != 0 or ts.gate.count() != 0) return null;
```

What the quiet path actually needs to know is narrower: will the
productive receipt's two removals (`penalty.remove(anchor)` and
`clearDispatchGate(anchor)`) be no-ops for this anchor? It also needs to
know whether this anchor's gate reads are unaffected. One thrashing loop
elsewhere in the program makes the global answer "no" for every head and
continuation, for the rest of the run. binary-trees (§2.2) is exactly
that case.

*Follow-up (2026-11-11): a third term was global the same way.*
`region_policy.receiptsInert()` is false from the moment a region is
admitted until its traces die, so one linked loop nest took every head
and continuation off the lane for the rest of the run. The term is now
`noOpenActivation()`, plus `receiptInertFor(trace.id)` for a
loop-anchored trace (doc 54, "Episode descent gate"). For §4.2's blocker
word this term needs one bit, "an activation is open", whose funnels are
`openRegion` and the activation closes; the physical index no longer
feeds it for one-shot traces.

### 3.2 The completion is an exit receipt

A terminal completion runs five calls: `accountTraceRun`,
`accountCandidateCharge`, `noteHostCallTerminal`,
`noteHeadSiblingCompletion` and `consumeHeadWalkFail`. Each is cheap on
its own, and each early-outs in the common case. Together they are the
grammar of an exit, running on a path that in the steady state has
nothing to report except "it completed, again".

### 3.3 The entry prelude does work that doesn't depend on the trace

`enterPatchedTrace` does several things on every call, before and after
the native run:

- clears the walk's evidence channels;
- checks the descent carry;
- runs `ordinaryProbeNeeded` twice;
- sets up the visited and dead arrays;
- merges the burst-visited set;
- updates the patch strikes;
- calls `dead.retire` and `drainEntryPatchWork`.

Before any of that, `opJFuncHead` checks seven bypass conditions and the
decline memo. Almost none of these answers changes from one call to the
next.

### 3.4 The native call marshals a loop-shaped result

`runWithLinkedLoopDone` initialises about 25 `NativeResult` fields per
entry. Many of them (silent budgets, descent budget, ledger length) exist
for loops and chains. `prepareNativeEpisode` stores seven ctx fields and
recomputes `descent_ok`. The lease is raised and lowered. After the run,
the result is decoded through the general `ExecResult`.

### 3.5 The return side is paid twice

The trace leaves at the `ret`, as LuaJIT's `LJ_TRLINK_RETURN` does, and
tier 0 runs it. The `opRet` hook `onRetResume` then walks its refusal
chain (73 instructions) to conclude that the caller's continuation anchor
is settled. That answer, too, doesn't change from call to call.

### 3.6 An entry refusal is not evidence

Seen 2026-11-11 on binary-trees. `ItemCheck`'s head trace was recorded on
an inner node. Its entry checks pin the argument's array lane: an inner
node `{ item, left, right }` is a mixed array (the value lane), a leaf
`{ item }` is an integer array, and the prologue's lane check refuses it.
(This paragraph first blamed a `guard_bounds` on `tree[2]`. That was
wrong: `guard_bounds` is a body guard with an exit of its own. Corrected
2026-11-11.) At argument 10 that is 134,092 head entries
refused at the prologue, and another 134,036 at the bottom of pushed
descents. A prologue failure is an entry refusal, not a guard exit: it
counts no hot exit and raises no sibling want. So no trace for the leaf
shape is ever recorded, and every leaf call pays an entry and then runs
on tier 0. That is the 1,004,790 `.next_candidate` rows in §2.3, 46% of
the program's one-shot entries. The patch is not retired either: a
one-shot patch accrues no strikes while its anchor is below sibling
capacity (doc 44 D8).

`BottomUpTree`'s head trace has the same shape at exit 5, the bottom of
131k descents, with 37 `record_abort` gates and repeated unpatch and
repatch.

The loop analog is already in TODO.md ("the anchor never records a
SECOND trace for the second lane shape"). Nothing in this doc's phases
addresses it: the lane makes a refused entry cheaper, it does not make it
useful. Options (Bart picked (a) on 2026-11-11; its design note goes
below this list before anything is built):

- **(a) Entry refusals raise a sibling want.** A counter per trace; at a
  threshold the anchor asks for a second trace, recorded on the
  activation that was just refused, as a zero-exit guard failure does
  today.
- **(b) Entry refusals count against the patch.** A patch whose entries
  are mostly refused is unpatched, so the leaf calls stop paying the
  entry. The inner-node calls lose their trace too.
- **(c) Leave it.** The lane keeps lowering the price of a refusal.

#### Design note for (a), 2026-11-11

Built as a prototype and measured before anything landed. The prototype
is not in the tree.

**The mechanism.** About 25 lines, all of it reuse:

- `Trace.refusal_count`, a saturating `u8` with the exit counters' `DONE`
  latch. The `.entry_refusal` branch of the two receipt funnels
  (`onSideExit`, `onSideExitReceipt`) bumps it for a one-shot anchor. The
  branch is keyed on the explicit charge kind, never on
  `exit_instr == maxInt` (doc 33 §3a), and every refusal site already goes
  through it.
- At `hotexit` it raises `wants_head_sibling` with the source
  `(trace, maxInt)`, behind the same three tests the exit route uses: no
  want standing for this anchor, recording not barred, the anchor below
  `max_traces_per_anchor`.
- Nothing new consumes it. The refused entry returns `.next_candidate`,
  `finishPatchedWalk` walks the siblings, and when all of them decline it
  transfers the want to the current activation, as it does for a hot
  zero exit. The recording starts on the call that was just refused.
- `noteHeadSiblingCompletion` latches the counter when another sibling
  completes, so a covered shape stops asking.

**A bug in the way (fixed, 1192436).** The first run raised nothing.
`wants_head_sibling` is one slot for the whole program and `noteTakenExit`
refused to raise while any want stood. `BottomUpTree`'s head trace raises
one at exit 5, and the same receipt's thrash strike gates and unpatches
that anchor, so no walk ever consumed it. It held the slot for the rest
of the run. Another anchor's hot exit now displaces a standing want; the
displaced source's counter stays saturated, so it asks again at its next
zero exit.

**What it records.** On binary-trees `ItemCheck` gets three more head
traces, not one. A leaf is not one shape: the integer lane follows the
width of `item`, and the run has leaves in lanes 7, 3 and 2. With the
inner node's value lane that is four traces, which is
`max_traces_per_anchor`. A fifth lane would stay uncovered.

**What it costs.** Instructions, `--jit-native`:

| Program | Tier 0 | JIT at HEAD | JIT with the want | Δ |
|---|---:|---:|---:|---:|
| binary-trees, argument 12 | 2.60 G | 4,074.6 M | 4,182.8 M | +2.7% |
| `call_two_shapes`, per iteration (two calls) | 1,559 | 2,786 | 2,977 | +6.9% |

With the want every call in the probe completes in native code, and the
run is slower. The reason is what a declined entry costs. One call of a
two-branch function, 10⁶ calls after the trace is recorded, against the
same program on tier 0:

| Call | Over tier 0 |
|---|---:|
| the shape the trace was recorded for (entry, body, completion) | +430 |
| the other shape, today (refused entry, then the body on tier 0) | +802 |
| the other shape with a sibling (refused entry, walk, sibling entry) | +1,019 |

Where a refused call's 795 go (callgrind, 200,000 calls, against tier 0):

| Where | Per call |
|---|---:|
| `finishOneShotLane` with `nextTraceExcluding` (the walk tail and its hash lookups) | 228 |
| `enterHeadNativeQuiet` (the call prelude, the result marshal, the refusal's receipts) | 183 |
| `opJFuncHead` | 114 |
| `onRetResume` (the return hook every JIT-mode call pays) | 72 |
| native code: the prologue, the fail stub, its ledger row | 49 |
| `headEpisodeQuiet` | 40 |
| the rest (back-edge handler, call hook, `opRet`) | ~110 |

About 610 of the 795 are the entry attempt; the native prologue that
does the refusing is 49 of them. binary-trees has 1,004,790 refused
entries at argument 12, so about 0.6 G of the 1.47 G its JIT run spends
over tier 0 is refusals (an estimate: the probe's per-call figure times
the count).

So a sibling cannot pay while a decline costs 610. A leaf call with a
sibling pays a decline for the incumbent, then the walk, then a full
entry, to replace a tier-0 body of about 150 instructions. On
binary-trees it pays 2.04 declines per leaf on average, because the
leaf lanes are three siblings deep.

**What would make a sibling pay (Q5, open).** Three ways to make a
decline cheap. They are not exclusive.

- **(i) A lean refusal in the lane.** The refused outcome becomes a
  first-class result of Phase 4's thin native call, and a refusal at an
  anchor with no other candidate and no want due leaves on a short path,
  as Phase 3 does for a completion. It removes most of the 228 and the
  183 and leaves the gate and the handler (about 150) plus the native
  49. The entry contract stays in one place, the native prologue. Inside
  a pushed descent the leaf still leaves native code.
- **(ii) An entry-fact check at the patch.** Each page publishes its
  entry checks as a list (slot, kind, expected value), and the walk tests
  a candidate against it before entering. A decline is then 15 to 20
  instructions and only the matching sibling is entered. It is a second
  description of the entry contract next to the emitted prologue (tags,
  table type, metatable, frozen bit, lane, grid, function and builtin
  identity, string pins), and seeded slots cannot be checked before the
  seed call.
- **(iii) A native miss chain.** The prologue-fail stub gets a jump slot
  and is armed to the next sibling's entry, so a leaf at the bottom of a
  descent runs without leaving native code. That is where fib is today:
  its base case is a real guard exit, `.sibling_handoff` arms both ways,
  and fib(27) runs 302 M instructions on tier 0 and 240 M with the JIT.
  It needs a slot on the stub, `.prologue_fail` as a chain source in the
  ledger grammar (today "always terminal"), and an order rule so that an
  argument no sibling accepts cannot cycle to the ledger cap (the nsieve
  ping-pong, +128%). Rule Z-8 sends it through a design doc of its own.

Orders to choose from:

- **A.** Phases 3 and 4 next, with the refused outcome in their scope
  (i). Then re-measure the want and land it when the probe and
  binary-trees both improve. (iii) afterwards, as its own doc, if
  descents still dominate.
- **B.** (ii) now, then the want, then Phases 3 and 4.
- **C.** (iii) now: write its design doc before any more lane work.
- **D.** Land the want as measured (+2.7% binary-trees, +6.9% on the
  probe) and recover it in later phases.

#### Landed: the lean decline tail, 2026-11-11

The first slice of (i), ahead of Phases 3 and 4 because it needs neither.
The largest row of the table above was the walk tail: `finishOneShotLane`
is a call with twelve arguments into the whole of `finishPatchedWalk`,
and for a refused sole incumbent every step of it does nothing. The lane
now tests that directly (`Vm.laneDeclineSettled`) and returns
`.next_candidate` itself:

- the patch is still live and still this trace's (so the trace record is
  safe to read: the entry's lease has been lowered, and a retirement
  during the entry marks the slot pending);
- no burst owners to merge and no patch work to drain;
- the trace is the only one on its anchor's list (three loads, no hash);
- `max_traces_per_anchor > 1`, so a sole trace is below capacity and the
  patch takes no strike (doc 44 D8);
- no sibling want stands for this anchor.

Anything else takes the walk tail as before. Safe builds run the walk
tail's own tests (`nextTraceExcluding`, `countTracesAt`) on every lean
decline and assert they agree.

| Probe (`--jit-native`, instructions) | Before | After |
|---|---:|---:|
| a refused call, over tier 0 | +802 | +586 |
| `call_two_shapes`, per iteration | 2,787 | 2,571 |
| binary-trees, argument 12 | 4,074.6 M | 3,835.2 M |

The test is a `noinline` function on measurement. Inlined, a decline
saved 224 and every completing lane entry paid two instructions
(`call_small_fn` +0.14%); as a call a decline saves 216 and a completion
pays nothing.

It does not help a decline at an anchor that has siblings, which is what
the refusal want creates. That case still walks, so the want is not
re-measured yet.

#### Re-measured after Phases 3 and 4, 2026-11-11

The prototype rebuilt on 5eef689 (the same 25 lines, with the
displacement rule of 1192436 on the raise). Still not in the tree.
Instructions, `--jit-native`:

| Program | Tier 0 | JIT at 5eef689 | JIT with the want | Δ |
|---|---:|---:|---:|---:|
| `call_two_shapes` | 779.9 M | 1,208.4 M | 1,382.6 M | +14.4% |
| binary-trees, argument 12 | 2,602.8 M | 3,792.6 M | 4,158.7 M | +9.7% |
| ray | 11,532 M | 24,908 M | 25,830 M | +3.7% |

The rest of the board is flat. ray is the same story as the other two:
five more head traces (12 pages become 17, at argument 3) and 28% more
trace entries, each of the new ones behind a decline.

The want costs more against HEAD than it did before, because HEAD's
decline got cheap only where there is no sibling, and the want is what
creates siblings. The probe, per call over tier 0 (three measurements
and one callgrind run, 100,000 iterations):

| Call | Over tier 0 |
|---|---:|
| the recorded shape (entry, native body, completion) | +413 |
| the other shape, no sibling (refused, body on tier 0) | +445 |
| the other shape, with a sibling (refused, walk, sibling entry) | +793 |

The third row splits like this:

| Part | Per call |
|---|---:|
| what every call at a patched anchor pays (handler, return hook, call hook, gate) | ~340 |
| the incumbent's declined entry (`enterHeadNativeQuiet`, the prologue and its fail stub, the refusal's receipt) | ~105 |
| the walk tail (`finishOneShotLane` 170, `nextTraceExcluding` 86, `laneDeclineSettled` 19) | 275 |
| the sibling's entry and native body, less the tier-0 body it replaces | ~73 |

Two readings.

A lean sibling walk in the lane (walk the anchor's list from the
incumbent, about 20 instructions) is not enough. It takes the third row
to about +538, still 93 over a plain refusal, and on binary-trees a leaf
pays 2.04 declines of about 125 each before the sibling that accepts it.
The walk would also be thrown away by (iii), where a refusal with a
sibling never returns to the lane.

The last row is the floor for anything done in the runtime. Entering a
page for a body this small (two index reads and a test) costs 73 more
than interpreting it, so even a decline that cost nothing would leave
the sibling path at about +413 against +445. The margin comes from
Phase 4's page capability (the episode ctx and the result frame, about
58 of the 73) or from bodies larger than this probe's.

What this leaves for Q5: the want does not land on (i). It needs a
decline of 20 instructions or fewer, which is (ii) or (iii), and of
those only (iii) keeps a leaf at the bottom of a pushed descent in
native code (134,036 of binary-trees' refusals at argument 10 are
there).

Two things this note does not solve. `BottomUpTree`'s base case cannot
be recorded at all: `return { item }` aborts on `set_list` (doc 72 P3),
so its 131k descents per run at argument 10 each end in a deopt at exit
5 whatever is done here. And the integer lanes multiply shapes: a
function that only reads `t[1]` needs one trace per width of the stored
integers.

## 4. Design

**What LuaJIT does at the same seam.** `BC_JFUNCF` runs `BC_IFUNCF`'s
frame setup (the stack check and missing-parameter fill), loads the
trace number and jumps to `BC_JLOOP`. That loads the trace's machine code
address and jumps into it: about 15 instructions from the call to
machine code (`vm_x64.dasc`, `BC_JFUNCF`/`BC_JLOOP`). A trace that
returns below its start frame is stopped with `LJ_TRLINK_RETURN`
(`lj_record.c`). Its tail is a direct jump to `lj_vm_exit_interp`
(`asm_tail_fixup`, `lj_asm_x86.h`). That restores two callee-saved
registers, reloads `KBASE` and dispatches the `RET` in the interpreter:
about 20 instructions. Nothing on the completion path does any
bookkeeping. Counting happens only on guard exits
(`lj_trace_exit` → `trace_hotside`).

mahina's lane must keep what LuaJIT doesn't carry:

- every receipt, gate and want keeps its meaning;
- hashgate stays byte-identical across the eight modes;
- tiering decisions stay a pure function of deterministic counters.

Within that, the lane is a shape, not a list of skips. The design keeps
doc 44 D9's rule: compute an admission verdict, run a dedicated small
episode when it holds, and leave the full path unchanged.

**The lane replaces `enterHeadNativeQuiet`.** It is not a third path next
to the quiet and full episodes (Rule Z-7).

### 4.1 Phase 1 — a per-anchor quiet predicate

The predicate's penalty and gate terms become questions about this
anchor. The global `count() != 0` terms go away. All three options below
are exact, so the lane's behaviour stays byte-identical:

- **(a) A hash lookup per entry.** Look `anchor` up in `penalty` and
  `gate`. Simple, but it puts back the two hashes per entry that D9's S2
  removed (~25 instructions each).
- **(b) A membership bit on the entry patch.** The patch or the trace
  carries "my anchor has a penalty or gate entry". It is set and cleared
  at the mutation funnels: penalty insert and remove, `bumpGateEntry`,
  `clearDispatchGate`, and the bulk gate removals that already call
  `noteGatesChanged`. Each check is one load. Every funnel has to keep
  the bit exact, and a Safe-build assert at lane entry checks it against
  the maps.
- **(c) A direct-mapped memo** keyed by anchor and stamped with
  `gate_gen` plus a new `penalty_gen`, like 4a8c8e6's bar memo. A
  mutation anywhere invalidates every entry. A thrashing loop that is
  struck on every iteration keeps bumping `penalty_gen`, so the memo
  misses at the same rate.

**Review, 2026-11-10: (b), with two bits.** (a) puts back the hashes
the lane exists to remove. (c) is invalidated by every unrelated strike,
which is exactly binary-trees' state. `gate_gen` also counts record-gate
changes, which a productive receipt never touches. What (b) needs:

- **Two bits, not one: `has_penalty` and `has_dispatch_gate`.** Then
  removing a penalty never has to look in the gate map to know whether
  the combined answer changed. The lane needs both clear. It tests
  membership, not whether the gate's cooldown is currently in force: a
  productive receipt removes an expired gate entry too.
- **One funnel for penalty mutations first.** Today penalties are
  inserted by the legacy receipt (`trace_regionops.zig` ~154), inserted
  and removed by region decisions (~314-363), removed by member amnesty
  (~1464, which also removes a gate directly) and cleared in bulk by
  `clearCache` (`trace_link.zig` ~3082). Each of these goes through one
  pair of operations that keeps the bits, as `noteGatesChanged` now does
  for gates.
- **The bits belong to the anchor.** A mutation finds the patch through
  an anchor-to-slot index, so it doesn't scan `entry_patches`. Whichever
  sibling trace runs, it reads the same bits.
- **A new or reused patch is initialised from the maps** before its
  opcode is published (`installEntryPatch`, `trace_entry_registry.zig`
  ~167-198).

**Implemented, 2026-11-10.** Two choices differ from the review above:

- **The bits sit on the traces, not on the patch.** Each trace carries
  `anchor_penalty` and `anchor_gate` (`trace_record.zig`). A funnel that
  changes an anchor's membership walks the anchor's trace list (the
  registry's `anchor_prev`/`anchor_next`) and sets them all, so whichever
  sibling runs reads the same answer. No anchor-to-slot index was needed.
  The legacy receipt also reads the bits, so the productive path tests
  this anchor and no longer the whole map.
- **The bits are conservative, not exact.** FALSE is exact: the anchor
  is in neither map. TRUE means "in the map, or unknown". A new trace
  starts TRUE, and the registry's link and unlink set TRUE. The publish
  site sets both bits from the maps. This matters because receipts also
  arrive for traces that are not on any list: hand-built traces in tests,
  and a trace detached while it was running. Those take the exact path
  instead. `assertAnchorMarks` checks the implication in Safe builds.

A funnel that holds the trace (the legacy receipt) walks the list from
that trace. One that holds only an anchor (region decisions, member
amnesty) uses `registry.tracesAt`, which hashes. The walk runs only when
an anchor enters or leaves a map. The fast paths are inline:
`removePenalty` and `clearDispatchGate` are called on every region-window
`.recover`, nearly always for an anchor with no entry. Out of line they
cost nsieve +0.7%.

Two variants were measured and rejected:

- **Clearing only the receipt's own trace on removal**, leaving siblings
  TRUE to heal on their own receipts. Siblings do not reliably come back
  through that receipt: co_pingpong_d20 went +1.8%.
- **Inlining `penaltyEntryAt`/`removePenaltyAt` into the inline legacy
  receipt.** euler14-bit went from +0.4% to +1.3%.

**Residual: euler14-bit +0.4%.** One of its anchors flips in and out of
the penalty map on alternate receipts, about 150k times. Each flip now
pays two out-of-line calls and a short list walk, about 30 instructions,
where the old code paid two inline map operations. The flip itself is
legacy-thrash bookkeeping on an anchor whose receipts alternate between
a strike and progress. It is not yet known whether that anchor is a
one-shot trace that Phase 3's lean completion would cover, or a loop
outside this doc's lane.

### 4.2 Phase 2 — one admission test

The bypass set (seven loads in `opJFuncHead`/`opJCont`), the decline
memo, the remaining global quiet terms and the prelude conditions become
one compare at the patch site. Safe builds assert the compare against the
long form on every entry, as `barCached` does. If the compare passes, the
lane runs. If not, today's code runs unchanged.

- **(a) A blocker bitmask on `TraceState`.** Each global condition owns a
  bit, set and cleared at its own mutation funnel: recording, suspension,
  pending anchors, pending arms, demotion and teardown, provenance,
  promoted sets, region receipts, coverage and debug config. The
  admission test is `blockers == 0`, plus the patch's own per-anchor bit
  from §4.1. Every funnel must keep its bit exact. The Safe assert is what
  catches a missed one.
- **(b) A generation counter.** One `lane_gen` is bumped by every
  mutation that could change the verdict. Each patch caches the verdict
  together with the gen it was computed at. Mutation sites only bump,
  with no per-condition bookkeeping. A mutation that leaves the verdict
  true still costs one full re-check at each patch's next entry.
- **(c) Keep the predicate and flatten it.** Pack the conditions into
  adjacent fields so that one or two wide loads and a mask test answer
  it. No funnel discipline is needed. The prelude's per-call work (§3.3)
  still needs its own trimming.

**Review, 2026-11-10: (a).** The tree already has this pattern:
`TraceState.fast_block` and `FastBit` (`trace.zig` ~3200-3280). They
already have owned setters, a Safe-build reference check, and the store
discipline that avoids a measured store-forwarding stall. Ten of the
conditions the lane needs already have bits there. (b) re-checks every
patch after any unrelated recording or arm. (c) can't flatten
`receiptsInert()` (three maps) or the per-trace eligibility. What (a)
needs:

- **A word of its own.** `fast_block` stays 16 bits: `hostcall_x64.S`
  asserts `TRACE_FAST_BLOCK_SIZE == 2`. The lane's word is a separate
  `one_shot_blockers`, which mirrors the `fast_block` bits it needs
  through the same setters.
- **Pending walk evidence is a blocker.** That covers `head_walk_fail`,
  `pending_descent_fail`, `wants_head_sibling` and an outstanding
  ordinary probe. While any of them is live, the entry takes today's
  prelude, which consumes or pairs it. The same goes for pending patch
  work (`drainEntryPatchWork`) and a non-zero strike count on the patch.
- **Failing admission still has three outcomes.** Recording and
  suspension run the canonical instruction. A dead patch runs the
  deferred-unpatch recovery. Anything else runs the full path. The word
  only decides "lane or not". The existing dispatch picks among the
  rest.
- **Funnels that don't exist yet get one.** For example,
  `receiptsInert()` changes with the physical index as well as with
  `refreshObserverFast` (`trace_region_policy.zig` ~313-369). The Safe
  assert checks the full reference verdict on both admission and
  refusal. Tests drive every blocker's transitions, including the
  out-of-memory paths.

Whichever is picked, the prelude's per-call work (§3.3) moves behind the
admission test. On the lane, the walk state is never set up, because
admission guarantees there is no failer carry, sibling want or ordinary
probe to consume.

**Implemented, 2026-11-11 (Phase 2a).** The phase is cut in two. 2a is
the lane itself, admitted by reading the existing fields, so it is exact
by construction and needs no new funnel. 2b compresses those reads into
the word. §2.3's measurement set the order: the prelude and epilogue
cost more than the predicate's loads.

- **One gate, `oneShotGate`.** Both handlers switch on its result: the
  lane, the walk (`enterPatchedTrace`), the canonical instruction, or the
  deferred unpatch. The settled test is `fast_block == 0`, the patch
  live, no exec log. That proves the suspension test and the whole
  bypass set, so a settled entry skips them whether or not it reaches
  the lane. Any other state runs the handlers' old gate sequence.
- **The lane, `enterOneShotLane`.** It does the prelude's two evidence
  resets and enters `enterHeadNativeQuiet`. If the episode completed and
  left no burst owners and no patch work, the epilogue is the strike
  reset. Any other outcome (an entry refusal, burst owners, dirty
  patches) runs the shared walk tail (`finishPatchedWalk`, split out of
  `enterPatchedTrace`) from the state the walk would have had.
- **`fast_block` is tested directly.** The review's plan mirrored its
  bits into the new word. Reading the word that already exists costs one
  load and adds no store to its setters, which are hot.
- **A pending descent carry or ordinary probe refuses the lane**, as
  planned. `head_walk_fail` needs no test (the prelude resets it and the
  lane does too). `wants_head_sibling` is read only after a refused
  entry, which the walk tail handles. A non-zero strike count needs no
  test: a completion resets it on both paths.
- **The decline memo needs no test on the lane.** It is armed only after
  a walk found the patch's trace native-unsupported. That verdict is
  permanent, a patch never changes its trace, and the quiet predicate
  requires a compiled page.
- **A refused entry does not ask twice.** When the quiet predicate
  refuses a compiled page, the gate tells the walk, which goes straight
  to the full entry. The first cut asked twice and re-ran the long gates
  after a refusal; `globals_script` paid +1.1% for it.
- **Asserts.** `assertOneShotSettled` (the settled test implies the
  suspension test and the bypass set) and `assertOneShotLaneAdmission`
  run on every entry in Safe builds. Tests read
  `TraceState.one_shot_lane_entries` (counted in Safe builds only) to
  prove the lane is taken, and refused under an exec log, coverage and a
  held `.full` dispatch.

Still read one by one on the lane, and left for 2b: the exec log, the
descent carry, the probe count, and `headEpisodeQuiet`'s program-wide
terms. The config terms (`native_codegen`, `coverage`, `record_exec_log`,
the debug-log sync) have no mutation funnel: about 70 test sites assign
config fields directly. They stay direct loads unless a funnel is worth a
sweep of those sites.

**Parked, 2026-11-11 (Phase 2b).** The remaining terms live in three
structs: `TraceState`, the native physical registry and the region
policy. The last two are also built standalone in tests, so they cannot
reach a word on `TraceState` without plumbing. Three shapes were measured
or bounded on the JIT board (instructions, against Phase 2a):

| Shape | call_small_fn | binary-trees | Needs |
|---|---:|---:|---|
| One word for everything, config included (unsound stand-in: an upper bound) | −2.5% | −2.8% | the registry and the policy reach `TraceState`'s word; a funnel for config writes (a sweep of ~70 test sites) |
| One exact summary per owner struct, config direct (stand-in) | −1.7% | −2.2% | ~25 hook sites, no plumbing, no sweep |
| No word: the predicate inlined into the handlers, minus the terms `fast_block == 0` implies | +2.0% | +1.0% | nothing; rejected (the handlers spill) |

Bart's pick: stop at 2a, do Phases 3 and 4 first (about 178 instructions
per call each, of the 500 left on the probe), then revisit. Those phases
may also change what the admission has to read.

### 4.3 Phase 3 — a lean completion

When admission held and the native run ended at its terminal, the
completion has nothing to consume (§3.2). What is left is counting:
`hit_count`, the entered charge, `entries`/`native_entries`, and the
patch-install side effect of `accountTraceRun`. Two places to do it:

- **(a) In the runtime.** The lane runs the counter increments in place
  of the five calls. It keeps `accountTraceRun`'s threshold check, which
  may mark entry-patch installation pending.
- **(b) In native code.** The terminal stub bumps the trace's counters
  through addresses baked into the page, as LuaJIT's trace exits do with
  its hot counters. The runtime pays nothing on completion. The
  threshold check needs its own answer: one compare in the stub, with an
  exit to the full path when it is reached. Tier-1a keeps counting in
  the runtime. The counts are identical either way, because every
  completion counts once.

`noteHostCallTerminal` keeps its work for a `call_interp` terminal, the
one terminal kind that files a continuation anchor. Admission can't
exclude it, because it is a property of the terminal, not of the program
state.

**Review, 2026-11-10: (a), and there is no threshold.** The framing
above misread `accountTraceRun` (`trace_regionops.zig` ~1641):

- `hit_count` rises only when one receipt's `completed >= min_useful`.
  A scalar one-shot completion passes 1 against a default of 8, so it
  normally leaves `hit_count` alone.
- Patch installation is marked only for a trace whose patch is
  `.eligible`. On the lane, the patch is already installed (`.bound`).
  One-shot patches qualify at commit (`trace.zig` ~4406).
- The entered charge resets `consec_refusals`; it doesn't count anything
  (`accountCandidateCharge`).
- `entries` and `native_entries` count before the run, so seed declines
  and guard failures count too. They stay where they are.

So the runtime completion is one shared function holding exactly what is
left: the `min_useful` compare, the `consec_refusals` reset, the
diagnostic `last_exit_instr`, and `noteHostCallTerminal` for
`call_interp`. Wrapping and saturating arithmetic stay as they are
today. (b) would also bake addresses inside the movable `Vm`
(`nativegen_emit.zig` ~1082: "`Vm` is movable, never baked"). It would
need a mode bit so that fused and full consumers don't charge twice, all
to save a few instructions.

**Implemented, 2026-11-11.** Nothing was left to design after the
review: the completion already ran `accountTraceRun` and the entered
charge inline. What cost instructions was the three notes after them,
each an out-of-line call that returned at its first test (18, 6 and 3
instructions in the callee, plus the calls). Each is now an inline test
in front of a `noinline` body:

- `noteHostCallTerminal` tests the terminal kind; `fileHostCallTerminal`
  files the continuation anchor of a `call_interp`.
- `noteHeadSiblingCompletion` tests `wants_head_sibling`;
  `retireHeadSiblingWant` does the rest.
- `consumeHeadWalkFail` tests `head_walk_fail`; `chargeHeadWalkFail`
  does the rest.

Every caller gets it (the burst, descent and full-path consumers too),
and there is no second completion to keep in step with the first.

### 4.4 Phase 4 — a thin native call for one-shot pages

One-shot pages get an entry wrapper with a small fixed result: the exit
code, the exit instruction and the completed count, in registers. The
`NativeResult` frame and the ledger are used only when the page reaches
a non-terminal exit, a burst or a pushed descent. The episode code
already branches on exactly those. `prepareNativeEpisode`'s stores run
only for pages whose seed plan or frame motion reads the ctx: the page
knows this at compile time and can carry the flag. The lease is raised
only on paths that can retire a trace.

**Review, 2026-11-10: one-shot doesn't mean scalar.** Continuation
pages emit frame pushes and return pops as well as head pages
(`nativegen.zig` ~2554, ~2689). The comment in `enterPatchedTrace` that
says otherwise is stale. The emitted push reads `descent_budget` from
`NativeResult` before deciding whether to push (`nativegen_emit.zig`
~1106). A dynamic-window plain terminal reads the episode ctx even with
no active seed (`nativegen.zig` ~2786). So the thin call is a capability
the compiler grants a page: no frame-motion sequence reachable, no ctx
read, no ledger append. Its eligibility is a flag on the page, and pages
without it keep today's result.

This is the half of the LuaJIT seam that is codegen work. LuaJIT's
`vm_exit_interp` is cheap because the trace has already written its
results to the stack, and the handoff is a jump with three live
registers.

**Implemented, 2026-11-11: the runtime half.** The run wrapper
(`runWithLinkedLoopDone`) is now three inline pieces: `initResult`,
`enterPage` and `decodeResult`. Every other caller composes the same
three and compiles as before. The quiet episode calls `enterQuiet`
(init and call) and keeps the raw `NativeResult`:

- a pushed descent or a fused burst (`pushed_frames > 0`, or more than
  one ledger row) calls `decodeQuiet` and goes to the same two consumers
  as before;
- every other outcome is scalar. The episode reads `exit_reason`,
  `exit_instr` and the local count (`localCompleted`) from the raw
  fields, in the same order of tests as before. The one ledger row is
  not copied and no `ExecResult` is built.

A refusal names no exit, so `noteTakenExit`'s first test (the exit has a
counter) runs at the call site and the call is not made. Safe builds
decode every scalar result as well and assert the fields agree; the
wrapper's own tripwire (`assertResult`) still runs on every entry.

Where a completing call's 191 instructions in `enterHeadNativeQuiet`
went, before this (callgrind, the pure probe):

| Part | Per call | Now |
|---|---:|---|
| `prepareNativeEpisode` | 38 | unchanged |
| the three completion notes, with their calls | 40 | three inline tests (Phase 3) |
| the `ExecResult` marshal | 20 | gone |
| the `NativeResult` init | 20 | unchanged |
| the ledger row copy | 17 | gone |
| outcome tests | 20 | about the same |
| the function's own frame (pushes, pops, 1.4 KiB of stack) | 16 | unchanged |
| the lease, the entry counters, the call, the directive | 21 | unchanged |

**What is left.** Three costs, each needing the page to promise
something:

- **The episode ctx (38).** `prepareNativeEpisode` publishes the
  activation for code that bakes the ctx address: the seed prologue, the
  frame-motion sequences, the dynamic-window terminal, traced host calls
  and every helper that reaches the `Vm` through `ctx.vm`. There are
  thirteen bake sites in `nativegen.zig` and `nativegen_emit.zig`. A
  page that bakes none still has exits, and an armed exit jumps into
  another page that may. So "this entry needs no ctx" is a property of
  the page and of everything armed out of it.
- **The result frame (20) and the native side.** The page writes its
  outcome and one ledger row into `NativeResult` at every exit; the
  shared trampoline saves and restores six registers around it. A
  result in registers needs exit stubs that know which kind of entry
  they are returning to, since the same page is also entered by the
  walk, by chains and by other pages' arms.
- **The lease (6).** It guards the running page against a retirement
  from a collection inside a helper call, so it stays for any page that
  can call one.

Options for the promise, not yet chosen:

- **(a) A static flag and no arms.** The compiler sets `ctx_free` when
  no bake site fired. The lane skips the ctx only while the page has no
  armed slot, counted at `commitSlotMutation` (the one funnel) and at
  exit-adapter publication.
- **(b) Arming refuses.** An arm out of a `ctx_free` page to a page
  that is not `ctx_free` is refused, so the property is closed under
  arming and the lane tests one bit.
- **(c) Leave the ctx and the frame.** Take the 58 as the price of one
  ABI for every entry, and spend the effort on Phase 5 (72 per return,
  every program) and Phase 2b (45 per entry).

### 4.5 Phase 5 — a one-load return refusal

`onRetResume` refuses a settled continuation anchor through about a dozen
checks (§3.5). A per-proto bitset indexed by pc, "this resume pc is
settled", turns the common answer into one load. The bit is set when the
refusal chain proves the answer is permanent. It is cleared under the
same invalidation the bar memo uses (`gate_gen`, `cache_gen`, image
patches). Anchors that are refused only temporarily keep the chain.

This helps every return in a program running under `--trace`, not only
returns from traces.

#### Implemented, 2026-11-11

**Where the bit lives.** Three places were on the table: a trailer on
the code image, a flag byte in `Instr`, and a faster bar memo. Bart was
asked and did not answer, so the trailer was chosen here: it is the
"per-proto bitset indexed by pc" this section describes, it leaves
`Instr` and the canonical code untouched, and `opRet` already holds the
image pointer. The bits sit behind the image in the same allocation
(`imageAllocLen`, one bit per pc, rounded up to whole `Instr`s), so the
test is one byte load off a pointer already in a register. A proto with
no image has no bits. Settling a pc gives its proto an image if it has
none (`ensureImage`): one copy of the code, once per proto, bounded by
code size. Protos are arena-owned and live as long as the VM, so an
image never outlives its key.

**What is settled.** Two refusals are permanent until a named event:

- the collision rule: the canonical op at the resume pc is a loop patch
  site. That never changes.
- a continuation anchor with no trace whose recording is abandoned
  (`recordingBarredMemo` returns `.abandoned`, a gate bar until
  `maxInt`).

A cooling anchor (a bar with an end tick), a vararg or system proto, an
active recording and a suspended JIT are not settled. They keep the long
form.

**What clears it.** Every gate mutation (`noteGatesChanged`, the four
funnels `gate_gen` already has) and every trace attach or detach
(`TraceRegistry.changed()`, with `cache_gen`) clears all settled bits,
and `dropEntryPatchState` drops them with the images. The clear walks a
list of the set bits (`settled_sites`), so it costs what was set, and
nothing when nothing was. Clearing all bits is coarser than the bar
memo's per-entry generations: a gate move anywhere makes every settled
pc take the long form once more, which settles it again. A per-anchor
clear is a possible refinement. It has not been needed: gates move at
recording decisions, not per call.

**Follow-up, 2026-11-11: one case did move a gate per call.** On
`records_script` (doc 85 §7) the short loops of `configured` and `refine`
are each a root with exit-side children that link back to it. Every
call leaves through a child's exit, and `accountLegacyThrash` strikes
the child's own anchor with zero completions. No dispatch gate stops a trace reached through an
armed link, so the strikes go on after the gate is abandoned: 39,916
gate bumps in 20,000 rounds, each one moving `gate_gen` and clearing
every settled bit. `bumpGateEntry` now returns an abandoned gate as it
stands (every reader takes `strikes >= max_strikes` as final and reads
nothing else of it), so the generation stays still. `records_script`
−0.86% JIT instructions (9,300.7 M to 9,220.9 M, 4,000 per round); no
other board row moves. Test: "gate: striking an abandoned gate again
leaves it and the gate generation alone". Whether that child should be
struck at all is a separate question, in `TODO.md`.

**The hook.** `onRetResume` is inline at its call site in `opRet`:

1. `img.ptr != proto.code.ptr` (the caller has an image), else the long
   form;
2. the settled bit, return;
3. `img[resume_pc].op == .jcont`, return (entry is the patch's job);
4. the long form (`onRetResumeUnsettled`, out of line), which settles
   what it proves.

Safe builds assert every inline hit against the long form's own answer
(`resumeSettledHolds` reads the canonical code and the maps;
the `.jcont` hit re-runs `resumeRefused`). The hashgate runs that assert
over every board row in Debug.

**Shapes measured.** JIT board, instructions, against 5eef689:

| Shape | `call_small_fn` | binary-trees | ray | Rose |
|---|---:|---:|---:|---|
| the bit inline, `.jcont` in the call | −5.69% | −1.12% | −0.26% | |
| the bit tested out of line | 18 more per settled return | | | |
| **the bit and `.jcont` inline (landed)** | −5.69% | −2.05% | −1.12% | |
| the same, collision rule not settled | −5.69% | −2.05% | −1.12% | `meta_fields` +0.16% (−0.31% when settled) |
| collision rule tested inline from the canonical op | −4.30% | −1.92% | −1.30% | `tostring_meta` +1.17%, `compile_multret_chain` +0.40% |
| a narrower inline collision test | −5.30% | −1.80% | −0.86% | `tostring_meta` +0.27%, `compile_multret_chain` +0.25% |

An inline test costs every return that it does not settle, so only the
two tests that answer most returns stay inline, and the collision rule
goes through the bit.

**Result.** JIT board: `call_two_shapes` −6.10%, `call_small_fn` −5.69%
(1,297.96 M → 1,224.18 M, 74 per return), `co_pingpong` −2.96%,
binary-trees −2.05% (3,792.57 M → 3,714.87 M), `globals_script` −1.84%,
ray −1.12%, `co_pingpong_d20` −0.90%, spectral-norm −0.89%,
`meta_fields` −0.31%, array3d −0.23%, `co_pingpong_d150` −0.17%. The
`--trace` board: `call_small_fn` −2.99%, `co_pingpong` −2.96%,
`call_two_shapes` −2.34%, binary-trees −1.01%, `globals_script` −0.95%,
`co_pingpong_d20` −0.91%, `co_pingpong_d150` −0.87%, ray −0.56%,
recursive-fib −0.44%, spectral-norm −0.29%. The tier-0 board is flat.

**Two rows rise, in both traced modes:** `gsub_fn` +0.135% and
`compile_multret_chain` +0.046%. Neither had an image before, and a
settle gives them their first. Once any image exists, `closureCode`
stops answering "the canonical code" on a count test and reads the
closure's memo instead, and a closure made fresh pays the image hash
once to fill it. `gsub_fn` makes one such closure per `string.gsub`
call (the native's activation, doc 68 §5.1). Callgrind at the bench's
size: the settle saves 3.3 M instructions and the first image costs
5.3 M (the image hash 1.24 M, the memo path in `opNativeAct` 2.69 M and
`opEntry` 0.92 M). Any program that already has one patched trace pays
this today, so it is the existing price of images, moved earlier for
these two rows. The activation's part of it is removable, since an
activation's proto can never have an image. That is taken as its own
change.

**Follow-up, 2026-11-11: an activation's memo is filled at its
creation.** A resumable native's activation is a fresh closure per call
(`enterActivation`), so once any image existed its empty memo sent every
activation through the image hash (47 instructions on `tostring_meta`).
No anchor can arise in an activation's proto: it has no loop, its entry
is not counted, and the return hook refuses a system proto before it
settles anything. So it never has an image, and `enterActivation` now
writes the canonical code into the new closure's memo when an image
exists. Safe builds check the claim against the image map at every
activation, and a test pins it with images present. JIT board:
`tostring_meta` −3.68% (922.23 M → 888.26 M, 57 per activation),
`gsub_fn` −0.112%, which leaves it +0.02% against the tree before
Phase 5. Tier 0: `tostring_meta` +0.141% (the image-count test, 2 per
activation), the rest flat.

Three other placements were measured. Skipping the memo for an
activation inside `enterCallee`, and testing for an activation proto in
`closureCode`'s cold fill, both changed the code of the shared entry
handler (`enterCallee` is inlined into it) and cost tier 0 on rows the
change has nothing to do with: `pcall_faults` +0.036% to +0.072%, which
makes no activation, and `sort_cmp` +0.115%. Filling the memo with no
image-count test cost a tier-0 activation 6.

The first measurements of this change were flat for a reason worth
keeping: the Safe-build witness was written as a bare
`std.debug.assert(reg.codeFor(proto).ptr == proto.code.ptr)`, and
ReleaseFast still made the lookup it was meant to remove. An assert
whose argument calls a lookup or a scan needs
`if (std.debug.runtime_safety)` in front. The same mistake was in
`settleResume` (cold, fixed with this), and a sweep found it in older
code, where one instance rescanned every new string (`CLAUDE.md`, Rule
Z-1's list).

### 4.6 Phase 6 — seeds, after doc 81 E2

Per entry, binary-trees pays ~218 instructions in `nativeSeedFn`. Its
seeds resolve `BottomUpTree`/`ItemCheck` as globals: a hash lookup per
entry, behind a C-ABI call. LuaJIT guards an `HREFK` into the globals
table inline. Doc 81 E2 (load-time cells) makes a global seed a cell
load, which removes this cost at its source. This doc owns re-measuring
it after E2, not a separate fix.

## 5. Scope

**Heads and continuations together (Q4).** `enterPatchedTrace` already
treats both as one-shot anchors (`one_shot`), and they share
`headEpisodeQuiet`/`enterHeadNativeQuiet`. binary-trees enters both
(`opJFuncHead` 71, `opJCont` 127 per entry). The lane is written for the
one-shot class. Splitting it by kind would mean two lanes to keep in
step. Settled this way (Q4). The real differences stay explicit:

- only a head consumes the descent carry;
- the continuation side refuses on `pending_ret_anchor` (see the check
  in Outstanding);
- a continuation's anchor pc is tagged (`contAnchorPc`), so membership
  and sibling lookups keep using the exact anchor, never the resume pc.

`headEpisodeQuiet` and `enterHeadNativeQuiet` already serve
continuations. The lane's functions are named for the one-shot class.

**Non-goals.**

- No change to what receipts, gates, wants or strikes decide. Only when
  the code that does nothing is physically executed.
- No loop-anchor lane in v1 (doc 44 D9's deferral stands). A loop entry
  amortises the seam over its iterations. (Follow-up, 2026-11-11: built
  separately as doc 87 §5.6's loop lane. A loop visited from tier 0 for
  a few trips at a time does not amortise it: `bench/loop_ring.lua`.)
- Not the frame-motion paths (`consumePushedDescent`,
  `consumeDescentTerminalRow`, call-head and ret-cont links). The lane
  covers the scalar result. Those consumers keep their own costs, and
  §2.2 shows them separately so they can be judged after Phase 1.

## 6. Measurement and budget

The boundary is per-call seam cost. Budgets, in instructions:

| Probe | Today | Budget |
|---|---:|---|
| pure probe (§2.1), JIT minus tier 0 | +573 per call | ≤ 0: the trace's body win pays for the seam |
| binary-trees, JIT against tier 0 | +91% | ≤ tier 0 |
| `globals_script`, JIT against 2dade3b (before `set_global` recorded) | ~+13.7% (+18.2%, then −3.8% from step 1) | ≤ 0% |

Progress, `perf stat` on the board rows (JIT minus tier 0):

| After | Pure probe, per call | binary-trees |
|---|---:|---:|
| step 1 (4a8c8e6) | +577 | +91% |
| Phase 1 | +577 | +59.4% |
| Phase 2a | +500 | +56.6% |
| the lean decline tail (§3.6) | +500 | +47.3% |
| Phase 3 and Phase 4's runtime half | +413 | +45.7% |
| Phase 5 | +339 | +42.7% |

Phase 0 puts the pure probe on the board. Each phase is measured with
callgrind on both tiers, on the pure probe and binary-trees, and with a
full board A/B on the pinned pool. Hashgate must stay byte-identical in
both builds after every phase. Each phase's Safe-build assert is the
proof of exactness that the hashgate cannot give on its own.

## 7. Questions (settled 2026-11-10; kept for the record)

- **Q1 (§4.1):** per-anchor penalty/gate knowledge through (a) a hash
  lookup per entry, (b) a membership bit kept by the funnels, or (c) a
  generation-stamped memo.
- **Q2 (§4.2):** the admission word as (a) a blocker bitmask, (b) a
  generation counter, or (c) a flattened predicate.
- **Q3 (§4.3):** completion counters (a) in the runtime, or (b) in the
  terminal stub with a threshold exit.
- **Q4 (§5):** one lane for heads and continuations, as written, or heads
  first.

## References

- Doc 44, `docs/design/44-call-anchors-and-return-tracing.md`: D9 (the
  quiet episode and its predicate), D10 (head-sibling exit patching), D11
  and D12c (frame motion).
- Doc 81 §7.1, `docs/design/81-load-env.md`: the `globals_script`
  regression. §6.2 covers E2.
- TODO.md (B), "Make a head-trace entry from tier-0 cheap".
- LuaJIT: `src/vm_x64.dasc` (`BC_JFUNCF`, `BC_JLOOP`, `vm_exit_interp`),
  `src/lj_record.c` (`LJ_TRLINK_RETURN`), `src/lj_asm_x86.h`
  (`asm_tail_fixup`).
