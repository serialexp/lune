# 84 — The lean one-shot entry lane — Design

Status: draft, not yet implemented. The evidence (§2) is measured; the
options in §4 wait on Bart's picks (§7)
Owner: Bart
Last updated: 2026-11-10

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole phases to Done once everything inside them is checked.

### Done

- [x] **Step 1 of TODO (B): barred anchors are memoized in the call and
  return hooks** (4a8c8e6). An exact direct-mapped memo
  (`TraceState.bar_cache`) replaces two hash lookups per call and per
  return on an anchor that has no trace and is barred from recording. The
  pure probe (§2.1) went from +662 to +573 instructions per call. This doc
  is step 2.

### Outstanding

- [ ] **Phase 0 — probes on the board.** Commit the pure-callee probe
  (§2.1) as a `@bench` program, so the per-call entry cost has a row of
  its own. Record the §2 baselines on the pinned pool.
- [ ] **Phase 1 — a per-anchor quiet predicate** (§4.1). Today a single
  penalty or gate entry anywhere sends every one-shot entry in the program
  down the full path (§3.1). Pick from Q1.
- [ ] **Phase 2 — one admission test** (§4.2). The `jfunc_head`/`jcont`
  bypass set, the quiet predicate and `enterPatchedTrace`'s per-call
  prelude collapse into one compare on the patch. Safe builds assert it
  against the long form. Pick from Q2.
- [ ] **Phase 3 — a lean completion** (§4.3). A terminal completion with
  nothing to consume does counters only. Pick from Q3.
- [ ] **Phase 4 — a thin native call for one-shot pages** (§4.4). A small
  fixed result in registers. The `NativeResult` init, the lease and
  `prepareNativeEpisode` run only on the paths that read them.
- [ ] **Phase 5 — a one-load return refusal** (§4.5). `onRetResume`'s
  refusal chain becomes one per-pc settled bit.
- [ ] **Phase 6 — re-measure binary-trees' seed cost after doc 81 E2**
  (§4.6). A `.global` seed is a hash lookup per entry in `nativeSeedFn`.
  Doc 81's load-time cells make it a load. This doc does no seed work of
  its own until E2 lands.
- [ ] **Q1 — per-anchor penalty/gate knowledge** (§4.1).
- [ ] **Q2 — the admission word** (§4.2).
- [ ] **Q3 — where completion counters are bumped** (§4.3).
- [ ] **Q4 — scope: heads and continuations together** (§5).
- [ ] **Defer — the loop-anchor lane.** Doc 44 D9 already deferred the
  loop-anchor quiet episode. It stays deferred until the one-shot lane has
  proved itself (§5).

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

Whichever is picked, the prelude's per-call work (§3.3) moves behind the
admission test. On the lane, the walk state is never set up, because
admission guarantees there is no failer carry, sibling want or ordinary
probe to consume.

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

### 4.4 Phase 4 — a thin native call for one-shot pages

One-shot pages get an entry wrapper with a small fixed result: the exit
code, the exit instruction and the completed count, in registers. The
`NativeResult` frame and the ledger are used only when the page reaches
a non-terminal exit, a burst or a pushed descent. The episode code
already branches on exactly those. `prepareNativeEpisode`'s stores run
only for pages whose seed plan or frame motion reads the ctx: the page
knows this at compile time and can carry the flag. The lease is raised
only on paths that can retire a trace.

This is the half of the LuaJIT seam that is codegen work. LuaJIT's
`vm_exit_interp` is cheap because the trace has already written its
results to the stack, and the handoff is a jump with three live
registers.

### 4.5 Phase 5 — a one-load return refusal

`onRetResume` refuses a settled continuation anchor through about a dozen
checks (§3.5). A per-proto bitset indexed by pc, "this resume pc is
settled", turns the common answer into one load. The bit is set when the
refusal chain proves the answer is permanent. It is cleared under the
same invalidation the bar memo uses (`gate_gen`, `cache_gen`, image
patches). Anchors that are refused only temporarily keep the chain.

This helps every return in a program running under `--trace`, not only
returns from traces.

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
step.

**Non-goals.**

- No change to what receipts, gates, wants or strikes decide. Only when
  the code that does nothing is physically executed.
- No loop-anchor lane in v1 (doc 44 D9's deferral stands). A loop entry
  amortises the seam over its iterations.
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

Phase 0 puts the pure probe on the board. Each phase is measured with
callgrind on both tiers, on the pure probe and binary-trees, and with a
full board A/B on the pinned pool. Hashgate must stay byte-identical in
both builds after every phase. Each phase's Safe-build assert is the
proof of exactness that the hashgate cannot give on its own.

## 7. Open questions for review

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
