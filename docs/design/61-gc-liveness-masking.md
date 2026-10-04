# mahina — GC liveness masking — Design

Status: draft, not yet implemented (awaiting codex + antigravity review)
Owner: Bart + agents (amber-badger)
Last updated: 2026-10-05

## Implementation status

Tracking the gap between this design and what's on the main branch. Tick items
as they land; move bullets to Done once everything inside them is checked.

### Done

_(nothing yet)_

### Outstanding

- [ ] **Review.** codex + antigravity on this doc; fold findings, re-review
      until both approve.
- [ ] **Phase 0 — frame pc made exact at every collection.** `gcTrampoline`
      publishes the innermost pc before `collect()` (§3.1); reentrant
      `callValue` callers are marked in-flight (§3.2). Behaviour-neutral on
      its own (the walk still roots everything); pinned by the frame-shape
      tests in §6.
- [ ] **Phase 1 — the masked `.gc` root walk + dead-slot scrub (§4).**
      Frame-owned slots root only `liveRoots(frame)`; the gaps keep
      conservative rooting; dead slots are set to nil during the walk.
      Gates, hashgate, §6 tests, board on pt-default (§7 budget).
- [ ] **Phase 2 — land the dead-φ writeback filter on top.** The uncommitted
      `phiLiveRow`/`phiWritebackKept` change (CURRENT_TASK 2026-10-05) plus
      the codex GC counterexample (`/tmp/gcphi_new.lua` → doc test) printing
      the same id in every mode.
- [ ] **Phase 3 — relax doc 24 D3's full-write-set flush.** `alloc_count != 0`
      forces every φ today *because* the collector roots every register
      (doc 24 :191-209). Re-derive it under masking and drop the rule if the
      argument holds. Separate review.
- [ ] **Q1 — in-flight marker representation** (§3.2).
- [ ] **Q2 — visualiser display of scrubbed dead locals** (§8).
- [ ] **Defer — `.snapshot` walk masking (doc 21 Phase B).** Same liveness
      source could serve it, but it has its own hazards and no current pin.
- [ ] **Defer — `backtraceFrames`/`callSiteAt` pc+1 assumption for
      in-flight frames** (pre-existing, §3.2): fix it with the Phase 0
      marker, but as its own change. Noted in TODO.md.

## Why this exists

The native JIT stores every slot a loop defines back to `regs[]` on every
iteration, dead temporaries included. On `pi_leibniz` (99.5% native residency,
8.9× LuaJIT on the pinned board) that is 8 tag + 8 value stores per iteration.
LuaJIT stores none of them: a slot that no later bytecode reads is simply not
restored (`snap_usedef`, lj_snap.c). We have the same per-pc liveness
(`Proto.reg_live`, doc 56 §4.2), and a filter that drops a φ dead at every pc
that consumes the φ set is written, gated and review-clean on every runtime
path except one.

That one path is the collector. `Vm.forEachRootHeader(.gc)` roots every
register in `0..stack_top`, live or not (`src/interp.zig` ~2419). A dropped
φ leaves a stale value in a dead slot; if that value is (or replaces) a heap
reference, the JIT run retains a different object set than tier-0, re-interns
a swept string with a fresh id, and the printed table ids diverge. Codex's
counterexample does exactly this: tier-0 prints `table: 0x178f`, the traced
modes print `0x1790`. Object ids are deterministic program output in mahina,
so this is a determinism bug, not a GC-quality nit.

LuaJIT roots the whole stack too (`gc_traverse_thread`), and gets away with it
because nothing about its addresses is part of a contract. Our contract is
stronger, so per CLAUDE.md ("replay forbids it" only justifies *adapting* the
mechanism) we adapt: make the collector's view of the stack a pure function of
the program's **logical** state — the live registers — so that what a dead
slot happens to hold is unobservable in every tier. Then every JIT may elide
dead stores freely, and dead objects are also freed sooner.

## Goals

1. **Determinism theorem.** At every collection, the rooted set is a function
   of (heap, live register values, non-register roots) only. Since every tier
   already agrees on live register values at a tier-0 instruction boundary,
   and collections happen at identical points in every tier, every tier
   marks and sweeps the identical set.
2. **No dangling reads.** Any later reader of a dead slot (mid-flight
   `encodeSnapshot`, the `.snapshot` walk, a trace's entry fingerprint read)
   must never see a pointer to a swept object.
3. **Sound by default.** Anything the masking cannot classify is rooted
   conservatively (today's behaviour), never masked.
4. **Cost:** O(frames × liveness words + stack slots) per collection — the
   walk already visits every slot; masking adds one bit test per slot.

## Non-goals (v1)

- Masking the `.snapshot` walk or the verbatim stack serialization (doc 21
  Phase B). Scrubbing (§4.3) makes dead slots canonical *after* a collection,
  which helps, but mid-flight byte identity between collections is not
  promised and no pin needs it.
- Weak tables / finalizers (none exist, `src/gc.zig:7`).
- Changing *when* collections happen (count-based, dispatch-prologue only,
  `src/gc.zig:634`; `mh_collect` from the C API).

## 1. Facts the design rests on

- **Collections happen only at the tier-0 dispatch prologue**
  (`interp.zig:2852 → gcTrampoline`) and via `mh_collect`. Allocation only
  bumps `object_count`; the trigger is `gc_stress or object_count >= next_gc`.
  Traces never collect: `guard_gc` refuses entry unless the trace's
  allocations fit under the threshold (doc 24 D3), and callouts are audited
  `may_collect = false`. So at every collection, every frame is at a tier-0
  instruction boundary, in every tier, after any trace has exited and flushed.
- **Frames** (`CallFrame`, `interp.zig:367`) carry `base` and `pc`; the
  register count comes from `closure.proto.num_registers`. Windows stack
  contiguously, and a callee's window overlaps its caller's call window
  (`callee_base = base + a + 1`).
- **pc conventions differ by frame position:**
  - innermost frame at a prologue collection: `frame.pc` is STALE (written at
    prologue step 6, after the GC check at step 1); the true next pc is the
    trampoline's `pc` argument;
  - a caller suspended at a Lua call: `frame.pc` = call pc + 1 (`:6410`; the
    native inline push uses `term_aux + 1`);
  - a caller re-entered through `callValue` from inside an instruction
    (metamethods, `pcall`, `sort`, `gsub`, `require`, load, capi): `frame.pc`
    = the in-flight instruction itself (step 6). Nothing in the frame says
    which convention applies.
- **Slots no frame describes:** host argument regions below a host-entered
  callee base, the parked `__call` region, multret spans above the window
  (protected by `reg_top_pending` suppressing the safepoint), the B-6 final
  result span at depth 0, and frames left raised over a fault until
  `protectedCall` unwinds.
- **`Proto.reg_live`**: `live_in[pc] = use ∪ (live_out − kill) ∪ captured`;
  conservative (captured registers live at every pc, multret consumers read
  to the window top, dynamic/conditional writes kill nothing, `j*` patched
  opcodes mark everything live); `words == 0` means "unknown".

## 2. The rule

A register slot `i < stack_top` is rooted iff:

- it is **not owned** by any frame window (a gap, §1) — rooted
  conservatively; or
- it is owned by frame `f` and `liveRoots(f)` contains `i − f.base`.

A slot owned by more than one window (the overlap of a caller's call window
with its callee) is owned by the **innermost** frame that covers it: during
the call, the callee's window *is* those slots.

`liveRoots(f)` (§3) is a bit row over `f`'s registers. When it cannot be
computed (no liveness table, pc out of range, an unrecognised suspension
shape), it is "all live" — today's behaviour for that frame.

## 3. `liveRoots(f)` per frame shape

### 3.1 Innermost frame

`liveRoots = live_in[pc]` where `pc` is the next instruction to execute.
Phase 0 makes `gcTrampoline` store `st.frame.pc = pc` before `collect()`, so
the collector reads one field for every frame. (The same store happens at
step 6 anyway; doing it earlier on the cold path is behaviour-neutral.)
`mh_collect` from a host callback runs with the innermost Lua frame suspended
in a host call — that is §3.2's in-flight or §3.3's call shape, not this one.

### 3.2 Frame suspended in-flight (`callValue` re-entry)

The frame is in the middle of instruction `p = frame.pc`. Its operands may
still be read after the callee returns (and natives hold `Value`s in Zig
locals relying on the argument registers being rooted, e.g. `require`'s
`name_val`). `live_in[p]` contains every operand of `p` (uses are added after
kills), so `liveRoots = live_in[p]`. The destination register is killed at
`p` and holds a stale value; not rooting it is correct (it is written before
any read).

Phase 0 adds the marker that distinguishes this shape from §3.3. **Q1:** a
`CallFrame.in_flight: bool` set/cleared around `callValue`'s reentry (one
store each way on a cold-ish path), or a depth-indexed bitset on the Vm.
Recommendation pending review; either is O(1). The marker also lets
`backtraceFrames`/`callSiteAt` (which today assume pc+1 for every parent and
so misreport in-flight frames) be fixed — kept as a separate change.

### 3.3 Frame suspended at a Lua call

`frame.pc = p` is one past the call instruction `C = code[p − 1]` with call
base `a`. During the call:

- slot `a` holds the callee (also rooted via the callee frame's `closure`);
- slots `a+1..` are the callee's window, owned by the callee (§2);
- on return, results are copied into `a..a+c−1` with no safepoint between
  the pop and the copy, so whatever those slots hold during the call is dead
  to the caller.

So `liveRoots = live_in[p] ∩ [0, a)`. Everything at or above `a` is either
callee-owned or overwritten by the result copy before the caller can read it.
This also handles `c == all_results` (where `live_in[p]` includes the window
top because the multret consumer reads it): those slots are the callee's
until the copy.

Soundness relies on the compiler placing a call at the first free register
(no caller local lives at or above `a`). Phase 1 checks it cheaply instead of
trusting it: if `live_in[p]` has a bit at or above `a + max(c, 0)` that the
call does not kill, the frame falls back to "all live" (and a debug assert
fires). The set of call-like opcodes that suspend a frame at pc+1 (`call`,
self/method call forms, `tfor_call`, the native inline push) is enumerated
in Phase 0 from the push sites; any other `code[p − 1]` opcode → "all live".

### 3.4 Depth 0 / idle VM

No frame owns the B-6 result span or a capi-parked region; they are gaps and
stay conservatively rooted.

## 4. The walk

### 4.1 Shape

```
for each frame f, innermost first:
    row = liveRoots(f)           // or ALL
    for i in owned(f):           // [f.base, f.base+nreg) minus slots already
        if row[i]: root(slot)    //  claimed by an inner frame
        else: scrub(slot)
root every unowned slot in [0, stack_top)
```

Ownership is resolved without allocation: frames are walked innermost-first
and each claims `[base, min(base + nreg, upper))`, where `upper` starts at
`stack_top` and drops to each claimed frame's base. Slots in
`[base + nreg, upper)` are gaps.

### 4.2 Only the `.gc` kind

The `.snapshot` walk keeps its current seeding (doc 21 Phase A's final-cut
mask, otherwise every slot). That is safe after Phase 1 because of §4.3.

### 4.3 Scrub: dead slots become nil

A masked slot is written to nil during the `.gc` walk, before sweep. Reasons:

1. **No dangling pointer survives.** A dead slot whose object is swept would
   otherwise be dereferenced by the next mid-flight `encodeSnapshot`
   (verbatim `stack[0..stack_top]`, `keyframeser.zig:326`) or `.snapshot`
   walk. Between collections, a dead slot can only acquire a pointer to an
   object live at that moment, and the next collection scrubs it before
   sweeping. Invariant: *after any collection, no register slot points to a
   swept object.*
2. **Canonical dead state.** Collections are at identical points in every
   tier, so after each one the dead slots are identical (nil) in every tier.
   That narrows the doc 21 Phase B gap instead of widening it.
3. **Never observable to the program:** a dead slot is, by `reg_live`'s
   definition, written before any read on every path from the frame's pc.

The one reader that is not tier-0 bytecode is a trace's entry check
(`matchesFingerprint` reads `entry_guards` slots). Every guarded slot is one
the trace reads before writing on its recorded path from the anchor, so it is
live at the anchor and never scrubbed while the frame sits there.

## 5. Determinism argument (to be attacked in review)

At a collection: (i) the trigger point is identical across tiers (count-based,
prologue-only, no on-trace GC); (ii) every frame's pc and suspension shape is
identical (tier-0 boundary, same call stack); (iii) the value of every live
register is identical — that is the existing exit/flush contract every tier
already satisfies, since tier-0 may read any live register; (iv) gap slots
hold call arguments/results/parked values produced by the same boundary code
in every tier; (v) non-register roots are unchanged by this design. The
masked rooted set is a function of (i)–(v), so the marked set, the sweep, and
every subsequent id are identical. The one pre-existing tier-dependent root,
trace consts (`.gc` only), is unaffected and stays redundant with pinned
proto constants as before.

Consequence for the JIT: a φ may be dropped iff its slot is dead at every pc
where tier-0 or a linked trace consumes the φ set (the Phase 2 rule). Proof
sketch: if a later collection at frame pc `Y` finds the slot live, then
either it was written between the resume pc `R` and `Y` (identical in every
tier) or it was live at `R` (so it was kept).

## 6. Tests (pinned before Phase 1 code lands)

- **Frame shapes** (unit, constructed VMs): innermost at a prologue GC;
  caller at a fixed-result call; caller at a multret call; in-flight frame
  under a metamethod and under `pcall`; host-entered callee with an argument
  region; `__call` parked region; depth-0 result span; proto with
  `words == 0`; a call shape with a live bit above the call base (falls back
  to all-live).
- **Behaviour:** an object whose only reference is a dead register is freed
  at the next collection (`gc_stress`), and the slot reads nil afterwards; an
  object in a live register, an open-upvalue register and an in-flight
  operand survives.
- **Determinism:** `/tmp/gcphi_new.lua` as a doc test, all modes, same
  output, before and after Phase 2; hashgate over the bench corpus.
- **Mutations** (each must fail a test): mask with the stale `frame.pc`;
  use `live_in[p]` without `∩ [0, a)` at a call; skip the scrub; drop the
  in-flight marker.

## 7. Performance budget (Rule #20)

Per collection: one liveness-row lookup per frame plus one bit test per slot,
on a walk that already touches every slot. Expected noise-level. Measured on
the pinned pt-default board (0.30% noise): no row may regress beyond noise,
with `binary-trees` (allocation-heavy, deepest stacks) as the boundary
benchmark; `gc_stress` test-suite wall time is the adversarial check. Memory
can only go down (strictly fewer roots).

## 8. Open questions for review

- **Q1** — in-flight marker: frame field vs depth-indexed bitset (§3.2).
- **Q2** — the time-travel visualiser shows register contents. After this,
  a dead local reads nil after a collection (identically in every tier),
  where today it shows its last value. Acceptable, or should the viewer
  label dead slots instead? (Bart.)
- **Q3** — completeness of §1's gap list and §3.3's call-like opcode list:
  reviewers, please try to find a slot holding a live value that no shape
  covers.

## References

- Codex review of the Phase 2 filter (GC counterexample): thread
  01a10917-bc12-70f1-a55e-d09ea59b082c.
- Doc 21 (canonical snapshot liveness; Phase B deferred), doc 24 D3/D8
  (full-write-set flush), doc 03 (root set; "must coordinate with
  liveness"), doc 56 §4.2 (`Proto.reg_live`).
- LuaJIT: `snap_usedef` (lj_snap.c:208), `gc_traverse_thread` (lj_gc.c).
