# mahina — GC liveness masking — Design

Status: draft rev 2, not yet implemented (awaiting codex + antigravity review)
Owner: Bart + agents (amber-badger)
Last updated: 2026-10-05

## Implementation status

Tracking the gap between this design and what's on the main branch. Tick items
as they land; move bullets to Done once everything inside them is checked.

### Done

- [x] **Rev 1 → rev 2 tradeoff review** (codex, 2026-10-05). It compared rev 1
      with an alternative draft; rev 2 is the merge it recommended, with its
      corrections (see "Revision history").

### Outstanding

- [ ] **Review rev 2.** codex + antigravity; fold findings, re-review until
      both approve.
- [ ] **Q1 — trace-constant roots (§6).** Pick an option before Phase 1: masking
      makes the hazard easier to reach.
- [ ] **Q2 — visualiser display of scrubbed dead locals** (§9).
- [ ] **Phase 0 — frame state made exact.**
      - `gcTrampoline` publishes the innermost pc before `collect()` (§3.1).
      - `CallFrame.in_flight` is set and cleared on every path that runs code
        inside a frame's instruction, including the dynamic-argument span end
        (§3.2, §3.5).
      - Every frame push initialises it: the Zig literal, the native emitted
        push and the `.S` host entry, with offsets bumped for coral-marten.
      - The static call-layout check runs over the corpus (§3.3).
      - Behaviour-neutral on its own; pinned by the frame-shape tests (§7).
- [ ] **Phase 1 — the masked `.gc` root walk + scrub (§4).**
      - Frame windows root `liveRoots(f)`.
      - Alias spans and gaps are always rooted.
      - Dead window slots are set to nil before sweep.
      - Gates, hashgate (reference regeneration only where all modes agree,
        §8), the §7 tests and mutations, the boundary benchmark, and a
        pt-default board.
- [ ] **Phase 2 — land the dead-φ writeback filter on top.** The uncommitted
      `phiLiveRow`/`phiWritebackKept` change, plus `/tmp/gcphi_new.lua` as a
      doc test that prints the same id in every mode.
- [ ] **Phase 3 — relax doc 24 D3's full-write-set flush.** Today
      `alloc_count != 0` keeps every φ only because the collector roots every
      register. Re-derive it under masking. Separate review.
- [ ] **Backtraces use the in-flight marker.** `backtraceFrames`/`callSiteAt`
      assume pc+1 for every parent and so misreport in-flight frames. This is a
      pre-existing bug and its own change; adding the marker alone fixes
      nothing.
- [ ] **Defer — `.snapshot` walk masking (doc 21 Phase B).** The scrub makes
      dead slots canonical after each collection; byte identity between
      collections is still not promised and no pin needs it.

## Why this exists

The native JIT stores every slot a loop defines back to `regs[]` on every
iteration, dead temporaries included. On `pi_leibniz` (99.5% native residency,
8.9× LuaJIT on the pinned board) that is 8 tag + 8 value stores per iteration.
LuaJIT stores none of them: a slot that no later bytecode reads is simply not
restored (`snap_usedef`, lj_snap.c). We have the same per-pc liveness
(`Proto.reg_live`, doc 56 §4.2). A filter that drops a φ dead at every pc that
consumes the φ set is written, gated and review-clean on every runtime path
except one.

That one path is the collector. `Vm.forEachRootHeader(.gc)` roots every
register in `0..stack_top`, live or not (`src/interp.zig` ~2419). A dropped φ
leaves a stale value in a dead slot. If that value is a heap reference, or
replaces one, the JIT run keeps a different set of objects alive than tier-0.
It then re-interns a swept string with a fresh id, and the printed table ids
diverge. Codex's counterexample does exactly this: tier-0 prints
`table: 0x178f`, the traced modes print `0x1790`. Object ids are deterministic
program output in mahina, so this is a determinism bug, not a GC-quality nit.

LuaJIT roots the whole stack too (`gc_traverse_thread`). It gets away with
that because nothing about its addresses is part of a contract. Our contract
is stronger. Per CLAUDE.md, "replay forbids it" only justifies *adapting* the
mechanism, so we adapt: make the collector's view of the stack a pure function
of the program's **logical** state, i.e. its live registers. Then what a dead
slot happens to hold is unobservable in every tier, every JIT may elide dead
stores freely, and dead objects are freed sooner.

## Goals

1. **Determinism theorem.** At every collection, the rooted set is a function
   of the heap, the live register values, the explicitly-aliased spans and the
   non-register roots. Every tier agrees on all of those at a tier-0
   instruction boundary, and collections happen at identical points in every
   tier. So every tier marks and sweeps the identical set.
2. **No dangling reads.** No later reader of a dead slot ever sees a pointer
   to a swept object. That covers mid-flight `encodeSnapshot`, the `.snapshot`
   walk and a trace's entry fingerprint read.
3. **Sound by default.** Anything the masking cannot classify is rooted
   conservatively (today's behaviour), never masked.
4. **Linear cost, no allocation per collection** (§5).

## Non-goals (v1)

- Masking the `.snapshot` walk or the verbatim stack serialization (doc 21
  Phase B).
- Weak tables / finalizers (none exist, `src/gc.zig:7`).
- Keeping collection *timing* as it is today. Fewer roots means a smaller
  surviving population and a lower `next_gc` (`gc.zig:776`). Collections
  therefore move, identically in every tier (§8).

## 1. Facts the design rests on

Verified against the tree at `93da3a3` (codex tradeoff review, 2026-10-05).

- **Collections happen only at the tier-0 dispatch prologue**
  (`interp.zig:2852 → gcTrampoline`) and via `mh_collect` (`capi.zig:584`).
  - Allocation only bumps `object_count`. The trigger is
    `gc_stress or object_count >= next_gc`.
  - Traces never collect: `guard_gc` refuses entry unless the trace's
    allocations fit under the threshold (doc 24 D3), and callouts are audited
    `may_collect = false`.
  - So at every collection, every frame is at a tier-0 instruction boundary
    or inside one instruction's re-entry, in every tier, after any trace has
    exited and flushed.
- **Lua call windows are disjoint.** Rev 1 got this wrong.
  - A Lua call lays the callee at the end of the caller's window,
    `callee_base = base + caller.num_registers` (`interp.zig:6382`). It copies
    the fixed parameters into it and nil-fills the rest. The native inline
    push does the same (`nativegen_emit.zig:979`).
  - The caller's call slots `a, a+1..` stay in the caller's window.
  - **Surplus varargs are not copied.** They stay in the caller's window at
    `va_base = base + a + 1 + num_params` and are read through the callee's
    `varargs_base`/`varargs_count` (`interp.zig:6406`).
  - Host entry (`bindAndPushClosure`, and the hand-written `.S` path in
    `src/asm/hostcall_x64.S`) and `callValue` put an argument region below the
    callee base. That region is not any frame's window.
- **pc conventions differ by frame state.**
  - **Innermost frame at a prologue collection:** `frame.pc` is stale. It is
    written at prologue step 6 (`:2965`), after the GC check at step 1. The
    true next pc is the trampoline's `pc` argument.
  - **A caller suspended at a Lua call:** `frame.pc` is the call pc + 1
    (`:6410`; the native push uses `term_aux + 1`).
  - **A frame whose instruction is running other code:** `frame.pc` is the
    in-flight instruction itself (step 6). This covers metamethods,
    `pcall`/`xpcall`, `sort`, `gsub`, `require`, `load`, a native called from
    `call`, host callbacks and capi `runProtected`.
  - **Nothing in the frame says which.**
- **Open upvalues are not marked through their stack location.** `gc.zig:703`
  marks only closed upvalues. An open upvalue's value is kept alive solely by
  the stack scan.
- **`reg_top_pending` is not a lifetime.** A `call` consuming `all_results`
  clears it before pushing or invoking the callee (`interp.zig:6374`). An
  argument span that runs past the caller window is therefore unprotected
  during re-entry and `mh_collect`. This is a pre-existing gap (§3.5).
- **`Proto.reg_live`:** `live_in[pc] = use ∪ (live_out − kill) ∪ captured`.
  - It is conservative: captured registers are live at every pc, multret
    consumers read to the window top, dynamic or conditional writes kill
    nothing, and the patched `j*` opcodes mark everything live.
  - `words == 0` means "unknown".

## 2. The rule

A slot `i < stack_top` is rooted iff any of these holds:

- **Gap.** No frame window contains it. It is rooted conservatively.
- **Alias.** It lies in an explicit alias span (§3.5), whatever its window
  says.
- **Live.** It lies in frame `f`'s window and `liveRoots(f)` contains
  `i − f.base`.

Frame windows `[f.base, f.base + nreg(f))` are disjoint, so a slot has at
most one owning frame. Every window slot that is in no alias span and not live
is **dead**: it is not rooted, and it is scrubbed (§4.3).

`liveRoots(f)` is "all live" whenever it cannot be computed: no liveness table,
a pc out of range, or an unrecognised suspension shape. That is today's
behaviour for that frame.

## 3. Per-frame live rows and alias spans

### 3.1 Innermost frame, between instructions

`liveRoots = live_in[pc]`, where `pc` is the next instruction to execute.
Phase 0 makes `gcTrampoline` store `st.frame.pc = pc` before `collect()`. Step
6 performs the same store anyway; doing it earlier on the cold path is
behaviour-neutral. An `mh_collect` from a host with the VM suspended between
instructions is the same shape: `frame.pc` already holds the next pc.

### 3.2 In-flight frame (`in_flight == true`)

The frame is inside instruction `P = frame.pc`, which is running other code.
Its operands may still be read when that returns. Natives also keep `Value`s
in Zig locals and rely on the operand registers staying rooted (e.g.
`require`'s `name_val`, `stdlib/package.zig:299`). `live_in[P]` contains every
operand of `P` (uses are added after kills). So:

`liveRoots = live_in[P]`.

The destination is killed at `P` and holds a stale value, which is correctly
left unrooted. A native called from `call` is in flight: its arguments are
uses of `P`, so they stay rooted.

**The marker is `CallFrame.in_flight: bool`** (rev 1's Q1, now decided). A Vm
depth stack would duplicate the unwind bookkeeping, and a union of the rows on
both sides of `pc` would root stale values, which breaks Goal 1.

The marker's lifecycle is part of the contract:

- **Set** on the frame whose instruction re-enters, before the callee runs:
  - `callValue` (every caller: metamethods, `pcall`/`xpcall`, `sort`, `gsub`,
    `require`, `load`, capi `runProtected`);
  - the `call` opcode's native/host-function path;
  - `pushHostCall`/`runPushedFrame`;
  - the `.S` entry, wherever it suspends a Lua frame.
- **Cleared** on the normal return to that frame, on every
  `protectedCall`/`xpcall` unwind that lands in it, and on error paths that
  pop past it.
- **Initialised false** by every push: the Zig struct literal, the native
  emitted inline push and the `.S` frame write. Frame-slot reuse goes through
  those pushes, so a stale `true` cannot survive.
- **Nesting:** each frame carries its own flag, so nested re-entry is just
  more flagged frames.
- **Unknown sites:** any site the Phase 0 audit cannot classify leaves the
  frame "all live", which is the fail-safe direction.

### 3.3 Caller suspended at a Lua call (`in_flight == false`, not innermost)

`frame.pc = p` is one past the call `C = code[p − 1]`, with call base `a`.

`liveRoots = live_in[p] ∩ [0, a)`.

Every caller slot at or above `a` is one of these:

- the callee (`a`), consumed by the push and rooted through the callee
  frame's `closure`;
- a fixed argument, copied into the callee window;
- a surplus vararg, rooted by the alias span in §3.5;
- a result slot (`a..a+c−1`), overwritten by the result copy before the
  caller can read it, with no safepoint between the pop and the copy;
- a free temporary above the call window, dead by register discipline.

None of them holds a value the caller reads after the return, so masking them
is sound. It is also necessary for Goal 1: the stale results and temporaries
there can differ between tiers. For `c = all_results`, `live_in[p]` includes
the window top only because the consumer reads it, and those slots are
results.

**Rev 1's assertion is withdrawn.** It checked for a liveness bit at or above
`a`, which confuses conservative captured and multret bits with preserved
values. In its place, Phase 0 adds a **static call-layout check**, run in
debug builds over every compiled proto (corpus and tests):

- for every Lua call instruction `(a, b, c)`, every slot `r >= a` that is in
  `live_out(call)` must be in `kill(call)` or `captured`;
- every captured slot at or above `a` must be closed before the call. The
  compiler's per-iteration `close` for generic-for loop variables, which reuse
  `base+3..` as the call window (`compiler.zig:1004`), is exactly the case
  this pins.

A proto that fails is compiled with liveness, but its suspended frames fall
back to "all live". So a compiler change can cost memory, never soundness.

### 3.4 Unknown shape

If `code[p − 1]` is not a call-like opcode that suspends a frame at pc+1, the
frame is "all live". The call-like opcodes, enumerated in Phase 0 from the
push sites, are `call`, the self/method call forms, the `tfor_loop` call and
the native inline push.

### 3.5 Alias spans: rooted regardless of window liveness

These are computed per collection from frame and Vm state, without
allocation:

- **Varargs.** `[f.varargs_base, f.varargs_base + f.varargs_count)` of every
  frame, wherever it lies (caller window or host argument region).
- **Open upvalues.** The stack location of every open upvalue on
  `open_upvalues`. Liveness's `captured` rule already makes these live in the
  owning frame. The alias rule makes rooting independent of that rule and of
  §3.3's `∩ [0, a)`.
- **Dynamic argument spans.** When an in-flight instruction consumed
  `all_results`, the span `[base + a + 1, reg_top_at_call)`, recorded on the
  in-flight frame when the flag is set (`CallFrame.dyn_hi`, 0 = none). This
  closes the gap in §1, which exists today too.
- **Gaps** need no rule. Host argument regions, the parked `__call` region,
  returned spans still covered before the copy, the depth-0 B-6 result span,
  and frames left raised during an `xpcall` handler or a `protectedCall`
  unwind are all outside every window, so §2 roots them.

## 4. The walk

### 4.1 Shape

The walk streams. It does not build a whole-stack mask.

```
for each frame f (any order; windows are disjoint):
    row = liveRoots(f)                  // or ALL
    for i in [f.base, f.base + nreg(f)):
        if row[i - f.base] or inAlias(i): root(slot i)
        else: scrub(slot i)
root every slot in [0, stack_top) outside all windows
```

`inAlias` checks a small sorted list built once per collection in a Vm-owned
scratch buffer:

- one varargs span per frame;
- one dynamic span per in-flight frame;
- one slot per open upvalue.

The buffer is sized at VM init: frames are bounded by `max_call_depth` and
open upvalues by the stack slab. Gaps fall out of walking frames in base
order.

### 4.2 Only the `.gc` kind

The `.snapshot` walk keeps its current seeding: doc 21 Phase A's final-cut
mask, otherwise every slot. That is safe after Phase 1 because of §4.3.

### 4.3 Scrub: dead slots become nil

A dead slot is written to nil during the `.gc` walk, before the sweep.

1. **No dangling pointer survives.** A dead slot whose object is swept would
   otherwise be dereferenced by the next mid-flight `encodeSnapshot` (verbatim
   `stack[0..stack_top]`, `keyframeser.zig:315`) or `.snapshot` walk. Between
   collections, a dead slot can only acquire a pointer to an object that is
   live at that moment, and the next collection scrubs it before sweeping.
   Invariant: *after any collection, no register slot points to a swept
   object.*
2. **Canonical dead state.** Collections happen at identical points in every
   tier, so after each one the dead slots are identical (nil) in every tier.
3. **Never observable to the program.** By `reg_live`'s definition, a dead
   slot is written before any read on every path from its frame's pc.

**Readers outside tier-0 bytecode,** checked in the tradeoff review:

- `matchesFingerprint`/entry guards read only slots a trace reads before
  writing on its recorded path from the anchor, and those are live at the
  anchor.
- Doc 56 exit-side snapshots and region bridges' `bridgeMatchesExitSnapshot`
  already materialise or check against resume-pc liveness.
- `ret_cont` receives copied results.
- Backtraces read pcs, not registers.
- The **visualiser** shows registers directly (`viz/src/snapshot.ts:130`), so
  a dead local reads nil after a collection (Q2).

## 5. Performance budget (Rule #20)

Per collection:

- one liveness-row lookup per frame;
- one bit test plus one alias check per window slot;
- building the alias list, linear in frames + open upvalues.

That is linear work on a walk that already touches every slot, with no
allocation (the Vm-owned scratch is sized at init).

**Boundary benchmark,** run deliberately, never a timing assertion in a test:

- a full 65,536-slot stack;
- 200 frames;
- large vararg and alias spans;
- a small heap, so the root walk dominates the collection.

The target is a root-walk cost within noise of today's unmasked walk at that
size. Board: pinned pt-default (0.30% noise), with no row regressing beyond
noise. `binary-trees` is the allocation-heavy row to watch. Memory can only go
down.

## 6. Q1 — trace constants are not always redundant (pre-existing hazard)

Rev 1 claimed trace consts "stay redundant with pinned proto constants". That
is false. A folded `tostring` result (`trace_recorder.zig:4518`) and a runtime
pattern string (`:4735`) are interned into the trace pool. The pool is a `.gc`
root only when a trace exists (`interp.zig:2451`). If such a string's last
ordinary reference dies:

- the JIT run keeps it alive;
- tier-0 sweeps it;
- a later re-intern allocates a new object in tier-0 only, and `next_obj_id`
  diverges.

Masking removes more ordinary roots, so it makes this easier to reach. One
attempt to reproduce it on HEAD did not diverge (`/tmp/tconst.lua`). Whatever
it was, it is recorded as a hazard, not a demonstrated bug. Options:

- **(a) Weak trace-pool references.** Trace consts stop being `.gc` roots for
  runtime-created heap values. A sweep that frees a pooled object retires
  every trace naming it (cache eviction plus native slot disarm, through the
  existing retire path) before its memory is reused. Deterministic: the sweep
  set no longer depends on the JIT. Retiring is behaviour, not output.
  Cost: a pooled-object → traces index, and a retire on sweep.
- **(b) Fold only already-pinned values.** The recorder folds a heap value
  into the pool only if it is otherwise permanently rooted (proto constants,
  pinned loaded-chunk constants, interned metamethod names). Anything else
  takes the runtime path: `tostring` called on trace, the pattern guarded by
  content rather than pool id. Simple, but it loses folding for those cases.
- **(c) Root pooled values in every tier.** Not implementable: tier-0 never
  records a trace.

Recommendation for review: (a). It keeps folding, and it matches the general
principle that the JIT must not change the heap's liveness. Bart decides.

## 7. Tests (pinned before the code they cover lands)

- **Frame shapes** (unit, constructed VMs):
  - innermost frame at a prologue GC;
  - caller at a fixed-result call, and at a multret call (stale result tail
    masked);
  - in-flight frame under a metamethod, `pcall`, an `xpcall` handler, a native
    called from `call`, and nested re-entry;
  - an erroring re-entry unwound by `pcall` (flag cleared);
  - `.S`/native frame reuse (flag initialised false);
  - a host-entered callee with an argument region;
  - the parked `__call` region;
  - the depth-0 result span;
  - `words == 0`;
  - a proto failing the static call-layout check (all live).
- **Alias spans:**
  - surplus varargs in a caller window survive a collection while the callee
    runs;
  - an open upvalue's slot survives;
  - an `all_results` argument span past the window survives a re-entrant
    collection.
- **Captured-before-definition:** a captured slot holding a stale temp before
  its definition, compared across tiers.
- **Behaviour:** an object whose only reference is a dead register is freed at
  the next collection (`gc_stress`), and the slot reads nil afterwards. Objects
  in a live register, an alias span and an in-flight operand survive.
- **Determinism (differential, all three modes, also under `gc_stress`):**
  - `/tmp/gcphi_new.lua` as a doc test;
  - a heap value in a `while` temporary;
  - a generic-for body;
  - a slot holding a table before the loop and a number inside it;
  - a collection from a metamethod;
  - a collection from `mh_collect` inside a host callback;
  - collect → snapshot → restore → linked execution.
  coral-marten's hostcall differential tests, which dump every register under
  GC stress in off/record/replay, cover the host-entry layouts.
- **Use-after-free net.** Under `gc_stress` in debug, the sweep records freed
  addresses in a set. After each collection, a walk checks that no slot below
  `stack_top` holds one of them. It never dereferences a freed header.
- **Mutations** (each must fail a test):
  - mask with the stale `frame.pc`;
  - drop `∩ [0, a)` at a call;
  - drop the varargs alias;
  - drop the open-upvalue alias;
  - skip the scrub;
  - never set `in_flight`;
  - never clear it on a `pcall` unwind;
  - use `live_in[p]` ∪ `live_in[p − 1]` for in-flight frames.

## 8. Observable changes

- **Collection timing changes.** Fewer dead objects survive, so collections
  happen at different allocation counts than HEAD. That shifts
  `next_obj_id`, printed table ids, and string-keyed `pairs` order after a
  re-intern, identically in all tiers.
- **hashgate.** Each affected program is first checked to agree across all
  three modes on both builds. Only then are its references regenerated, in
  Phase 1. `hashgate.py --generate --filter` rewrites the whole refs file, so
  generate into a scratch `--refs` and merge rows by hand.
- **Memory.** `mh_mem_stats` live bytes drop (host-visible, not
  program-visible).

## 9. Open questions for review

- **Q1** — trace-constant roots (§6): (a) weak pool + retire on sweep,
  (b) fold only pinned values, or something else.
- **Q2** — the time-travel visualiser shows register contents. After this
  change, a dead local reads nil after a collection (identically in every
  tier), where today it shows its last value. Accept that, or have the viewer
  label dead slots? (Bart.)
- **Q3** — completeness: reviewers, please try to find a slot holding a live
  value that no frame row, alias span or gap covers. Also check whether any
  `in_flight` set/clear site is missing.

## Revision history

- **Rev 1** (`93da3a3`). It modelled a callee window as overlapping the
  caller's call slots, with innermost ownership.
- **Rev 2** (this; codex tradeoff review against an alternative draft):
  - **Disjoint windows.** Lua callee windows are disjoint (`interp.zig:6382`),
    so the overlap model is gone. Under it, rev 1 would have scrubbed a
    callee's live surplus varargs.
  - **Alias spans added:** varargs, open-upvalue slots and dynamic argument
    spans.
  - **In-flight marker decided:** a `CallFrame.in_flight` flag, taken from
    the alternative draft, with its full lifecycle.
  - **Call-layout check replaced.** Rev 1's liveness-bit assertion becomes a
    static call-layout check.
  - **Trace-const hazard raised** as Q1.
  - **Tests broadened** (the alternative draft's variants plus codex's), with
    a use-after-free net that never dereferences freed memory.
  - **Boundary benchmark specified.**
  - **Reference-output regeneration procedure stated.**

## References

- Codex review of the Phase 2 filter (GC counterexample): thread
  01a10917-bc12-70f1-a55e-d09ea59b082c.
- Codex tradeoff review, rev 1 vs the alternative draft: thread
  01a1094b-d759-7ab2-b076-f51a6be6f10c.
- Doc 21 (canonical snapshot liveness; Phase B deferred).
- Doc 24 D3/D8 (full-write-set flush).
- Doc 03 (root set; "must coordinate with liveness").
- Doc 56 §4.2 (`Proto.reg_live`).
- LuaJIT: `snap_usedef` (lj_snap.c:208), `gc_traverse_thread` (lj_gc.c).
