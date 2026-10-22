# 69 — Tier-0 dispatch prologue: one gate, lazy pc, frame pointer

Status: partial. P0 (the GC countdown gate) is on master; P1–P3 wait on
Bart's answers to §7.
Owner: claude (coral-marten)
Last updated: 2026-10-23

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole phases to Done once everything inside them is checked.

### Done

- [x] **Diagnosis** (2026-10-23, §2). The hot prologue costs ~17 of a simple
  handler's 22 instructions, against LuaJIT's ~5. Deliberately unsound
  upper-bound builds measured what each piece is worth (§2.2).
- [x] **P0 — the GC countdown gate** (§3), landed 2026-10-23 together with
  the slot-ordered open-upvalue list (TODO.md "Lua call + return"). `Heap.gc_headroom`
  replaces the three-field `gc_stress or object_count >= next_gc` test,
  and the `reg_top_pending` conjunct moves into `gcTrampoline`. Every
  @bench row is −0.6 to −11.7% instructions at tier 0 and −0.0 to −5.4%
  with the JIT; the worst row is scalar JIT at +0.05% (one extra
  decrement per allocation). Outputs are byte-identical.
- [x] **A replay-line OOM was described at the previous instruction**, found
  by the §5 audit. Step 3's park ran before step 6's pc store; it now stores
  the pc itself. Landed with P0, with a test in `interp_dispatch_test.zig`.

### Outstanding
- [ ] **Q1 — the merged slow-path gate** (§4). Fold the regions-live test
  into P0's gate so the prologue has one compare. Upper bound −0.3 to −5.3%
  at tier 0 on top of P0. Needs a decision on who owns the gate (§7 Q1).
- [ ] **P1 — the merged gate**, after Q1.
- [ ] **Q2 — lazy `frame.pc`** (§5). Upper bound another −0.1 to −5.5% at tier
  0. It is a soundness audit of every `frame.pc` reader, not a local edit
  (§7 Q2).
- [ ] **P2 — lazy `frame.pc`**, after Q2 and the reader audit.
- [ ] **Q3 — `omit_frame_pointer` on the mahina module** (§6; doc 42 §9.4,
  "Bart's call"). Measured on top of P0: −1.0 to −5.3% at tier 0 and
  −0.0 to −5.3% with the JIT.
- [ ] **P3 — call/return transitions** (TODO.md "Lua call + return"; §2.3).
  It waits on doc 68's activation frames settling. It gets its own
  section here once doc 68 P1 has landed.

## 1. Why this exists

Doc 42 turned tier 0 into per-op handlers that tail-call each other. Every
handler ends with the same inlined dispatch tail, the §4.2 prologue, so its
cost is paid once per executed instruction in every program. Doc 42 §4.2 makes
the prologue's step order part of the determinism contract: "Each step is part
of the determinism contract, so changing one needs a design argument". This
doc is that argument for the cheaper shapes below. Its claim for each is the
same: the verdict of every step at every instruction boundary is unchanged,
and only how the verdict is computed changes.

## 2. Diagnosis

### 2.1 Where the instructions go

`opLoad` in `.fast` mode, ReleaseFast, at HEAD d21a333 plus the slot-ordered
upvalue change (the "uv" baseline):

| piece | instructions |
|---|---|
| frame pointer (`push rbp; mov rsp,rbp; pop rbp`) | 3 |
| the handler's own work | 4 |
| GC gate: `reg_top_pending`, load `heap`, `gc_stress`, load `object_count`, compare `next_gc` | 8 |
| `safepoint_seq += 1` | 1 |
| regions-live: `region_profit.count() != 0` | 2 |
| `frame.pc = cur`: load `st.frame`, store | 2 |
| pc advance, fetch the opcode, indirect jump | 3 |

That makes 22 hot-path instructions for an op whose work is 4. LuaJIT's
`-joff` dispatch is about 5: decode, advance, and the indirect jump. It keeps
no per-instruction GC test (a check runs only at the allocating bytecodes),
and it saves the pc only on the slow paths that need it.

### 2.2 Upper bounds

These are unsound builds, made only to measure. The numbers are
`instructions:u` over every @bench program against the uv baseline
(`/tmp/p1/ab2.sh`).

- **ubA** removes the GC and region tests outright: −6.6 to −23.5% at tier
  0 on compute rows (pi_leibniz −23.5%, euler14-bit −19.9%, scimark-sor
  −19.5%), and −1.3 to −10% on library-bound rows.
- **ubB** is ubA without the `frame.pc` store: another −0.1 to −5.5%.
- **ggR** is P0 with the region test removed: −0.3 to −5.3% at tier 0 on
  top of P0.

JIT rows that lose their region profiling in ubA/ubB regress (scalar
+491%). That is expected, since those builds never mint regions, and it
does not bear on the sound shapes.

### 2.3 Call and return (for P3)

Measured by callgrind on the uv baseline:

- opCall is ~190 instructions per call and opRet ~140.
- `onCallEntry` costs 19, plus 13 of setup.
- `reloadTopFrame` plus `cachedCodeFor` cost ~70.
- The frame write is 15 and the `onRetResume` call 11.

The ExecState reload re-reads 7 fields on every transition.
`setRegionContext` runs twice per call. The ~96-byte `CallFrame` is written
whole on every push. These are the P3 levers. They wait because doc 68 P1
slice 2 is reshaping the same push path (activation frames).

## 3. P0 — the GC countdown gate

`Heap.gc_headroom: i64` is a countdown. A collection is due exactly when it
is `<= 0`, which is the old predicate `gc_stress or object_count >= next_gc`.
It is kept exact as follows:

- `link`, the single allocation chokepoint, decrements it in step with
  `object_count`. That is one memory decrement per allocation.
- `setNextGc` and `setGcStress` re-derive it from the inputs, and every write
  of those two fields goes through them. The sweep and the keyframe restore
  call `setNextGc`. The tests now use the setters too.
- Under stress it is 0, and allocating under stress only moves it further
  below zero.
- It is signed, so a due collection that is deferred (a pending multret, or
  a cycle skipped because `beginCollect` hit OOM) keeps counting down and
  stays due. 2^63 allocations cannot wrap it. A restored `next_gc` past
  `i64` saturates.
- `shouldCollect` re-derives the old predicate in Debug and asserts that the
  two agree. Every Debug test run therefore checks the invariant at every
  safepoint.

The prologue tests only the gate. `!reg_top_pending` is rare, so it moves
into `gcTrampoline`, which skips the collection when a multret result set is
pending. At every boundary the step-1 verdict ("collect here or not") is
therefore identical to the old one. The trampoline adds one tail jump per
instruction only while a collection is both due and deferred.

**Rejected first cut: a `collect_due: bool`.** It was set in `link` by
comparing `object_count` against `next_gc`. That costs ~4 instructions per
allocation, because LLVM stops folding `object_count += 1` into one memory
increment once the count is also compared. On scalar JIT it measured +0.44%.
The countdown costs one decrement (+0.05%).

The native code's `guard_gc` still reads `gc_stress`, `object_count` and
`next_gc` through baked addresses. Those fields keep their meaning, so the
JIT is untouched.

## 4. Q1 — merging regions-live into the gate

After P0 the prologue still makes two tests: the heap gate (load `heap`,
compare, branch) and the region count (compare, branch). Folding both into
one value would leave one test. Mechanism: the region policy forces the gate
to `<= 0` while `region_profit` is non-empty, and re-derives it when the map
empties. The gate's trampoline then re-tests both inputs. It collects if
`dueFromInputs()` holds and nothing is pending, then takes the region path
if the map is non-empty, in §4.2 order (step 1 before steps 2–4 before step
5).

This is not the same edit as P0, and its ordering argument is different.
Steps 2–4 (`safepoint_seq`, the replay-line append, the suspend test) sit
between GC and region in the contract. So a merged trampoline must run
step 1, then the inlined steps 2–4, then step 5. In other words it cannot
be one trampoline; it is the GC trampoline followed by the region test in
the out-of-line copy of steps 2–5. Regions-live programs keep paying one
extra tail jump per instruction, as they do today.

The region map's mutation sites are few: `getOrPut` at
`trace_region_policy.zig:231`, `remove` at :257, and
`clearRetainingCapacity` at :287, plus tests. What makes this a question is
who owns the gate:

- **(a) Heap-owned.** `Heap` gains a `regions_live` input, and the policy
  holds a `*gc.Heap` to flip it. This couples the trace policy to the GC
  module for a flag that has nothing to do with collection.
- **(b) A separate stable-address `SafepointGate`.** It is heap-allocated
  like `Heap` (`Vm` is movable), and both `Heap` and the policy hold a
  pointer to it. The coupling is cleaner, but there is one more indirection
  on every allocation (`link` writes through the gate pointer).
- **(c) Leave the two tests separate.** Forgo the ~0.3–5.3%.

## 5. Q2 — lazy `frame.pc`

Today step 6 stores `frame.pc = cur` at every instruction, so any reader
sees the faulting or calling instruction. LuaJIT stores the pc only on paths
that leave the interpreter's straight line (`savePC` before a C call, a
metamethod or an error). The mahina equivalent drops step 6 from the hot
prologue and stores `cur` in every handler path that can reach a reader.

The readers, which all need an audit:

- the GC root walk (doc 61 §4.1 reads `frame.pc` of every frame for
  liveness masks; `gcTrampoline` already publishes it);
- fault location (`describeFault`, `callSiteAt`, `error` levels,
  `backtraceFrames`);
- suspend (step 4 already stores it);
- natives that re-enter (`callValue`, the activation frames of doc 68);
- the trace recorder's anchors and exits;
- keyframe capture.

**Audit (2026-10-23, read-only, on the P0 shadow).**

- **Innermost-frame readers.** `describeFault` (every `.err` park, about
  45 `parkErr` sites), `backtraceFrames`, `callSiteAt(1)` with
  `nativeSite` (natives' `badArg`, `error`, `assert`, host raise),
  `frameShape`/`frameMask` (GC liveness: `collect`, `fillKeep`, keyframe
  capture) and `assertFrameShapesKnown`. The resume paths (`execImpl`
  re-entry, wasm step, keyframe capture) read only pcs that were stored
  explicitly.
- **Outer-frame readers.** A frame below a Lua call carries its push-time
  pc and does not depend on step 6. A frame below a metamethod, native
  callback or host call (`in_flight`) carries the prologue's value, and
  code running inside the nested call reads it: a nested `collect` reads
  it through `frameMask`, and so do `debug.traceback` and
  `error(msg, 2)`.
- **Consequence.** A store at error time is not enough. The pc must be
  stored before every re-entry. That is ~25 handler exit points:
  - one store in `slowTail` covers the 12 split slow handlers;
  - `callTail`'s native and `__call` arms;
  - the metamethod fallbacks in `binNum`/`arithGeneric`, `unArithMeta`,
    `lenValue`, `binMeta` and `fusedGet`/`fusedStore`.

  Then there are ~15 error-only parks, cleanest handled as a pc argument
  to `parkErr`. The re-entering helpers (`callValue`, `callMeta`,
  `indexGet`, …) have no pc, and natives call them at depth > 0, so the
  store cannot be centralised in them.
- **The hardest reader** is `frameMask`'s in-flight arm. There, a stale
  pc is a wrong GC root set, not just a wrong error line.

What has to hold for soundness: every reader observes exactly the value the
per-instruction store would have produced. That is a property of every
handler's slow paths, not of the prologue. One missed store gives a wrong
line in an error message, or a wrong liveness mask in the GC (which frees a
live value). So this needs an exhaustive enumeration, plus a Debug-mode
checker that the lazily kept pc equals `cur` at each reader. It is not a
spot edit. The upper bound is −0.1 to −5.5% at tier 0.

## 6. Q3 — the frame pointer

This is already on file as doc 42 §9.4. Measured on top of P0 with
`omit_frame_pointer = true` on the `mahina` module, `instructions:u`:

- tier 0: −1.0 to −5.3% (pi_leibniz −5.1%, grid_matmul −5.3%, tbl_ops −5.2%);
- JIT: −0.0 to −5.3% (tbl_ops −5.3%, lua54 −4.5%).

Outputs are identical. The cost is that `perf record -g` with fp unwinding
loses the runtime's chains. The CLI already has `-Dcli-frame-pointers=true`
for exactly that profiling case, but today it only reaches the exe's root
module. It would have to reach the `mahina` module as well.

## 7. Open questions for Bart

1. **Q1, the merged gate.** Who owns it: (a) the heap, (b) a separate
   `SafepointGate`, or (c) keep the two tests separate?
2. **Q2, lazy pc.** Take it on, as the audit of §5 plus a Debug checker, or
   defer it?
3. **Q3, frame pointer.** Omit it on the `mahina` module, with
   `-Dcli-frame-pointers` keeping it for profiling builds, or keep it?

## 8. References

- Doc 42 §4.2 (the prologue contract), §9.2 (the call-free prologue), §9.4
  (the frame pointer).
- Doc 61 §4.1 (GC liveness reads `frame.pc`).
- LuaJIT `vm_x64.dasc`: `ins_next`, the GC checks at the allocating
  bytecodes (`lj_gc_check` sites), `savePC`.
