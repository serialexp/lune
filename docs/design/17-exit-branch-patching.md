# Exit-Branch Patching (Direct Side-Trace Linking) — Design

Status: draft — NOT implementation-ready. Mechanism mapped on both sides; peer review (gpt-5.6-sol, 2026-07-11) found the first-draft "swing one rel32" Phase 2 unsound. The real port needs a native chain-entry ABI + a shared code arena + a chain-wide result contract before any patch is safe. The headline "Phase 2 flips nsieve" hypothesis is **unsupported** as first drafted (most nsieve hops stay unpatched). See §Blocking prerequisites.
Owner: Bart
Last updated: 2026-07-11 (peer review folded in)

Coherent-state chaining (doc 16) proved *correct* but *performance-neutral* on
nsieve: the JIT compiles every hot loop to native code, chaining hands control
from one native trace to the next at a shared coherent anchor — and yet it does
not beat tier-0 on the prime/composite clusters, because **every transition
re-enters the runtime**. A native guard fails, returns to the Zig dispatcher,
which does guard-failure accounting, a linear trace-cache scan, and an indirect
call through a function pointer with a fresh `NativeResult` — measured at
~600 ns per hop (doc 16 §nsieve outcome). On nsieve's 1–2-iteration clusters that
per-hop cost rivals just interpreting the gap in tier-0, so `driveChain` swaps
tier-0 for something no faster. Increasing chain coverage makes nsieve *slower*,
which is the structural signature that the transition cost — not codegen
tightness — is the wall.

LuaJIT does not have this cost. When a guard on a parent trace fails hot enough
to record a side trace, LuaJIT **patches the parent's machine code** so the
guard's exit jumps *directly* into the side trace's native entry — zero
dispatcher re-entry, zero marshalling. This doc is the contract for porting that
mechanism (`lj_asm_patchexit`) to lune's tier-1b backend, and the home for the
determinism obligations the port must discharge to stay byte-identical across the
10-mode matrix.

This is not a redesign. LuaJIT's mechanism works and we have the source
(`~/Projects/LuaJIT/src/`); the job is to adapt it to lune's handoff model, which
differs in one load-bearing way (memory-file vs. register handoff — see §The one
real difference). The investigation that produced this doc read both codebases in
full; citations are inline.

## Implementation status

Tracking the gap between this design and what's on `master`. Tick items as they
land; move whole sections to Done once everything inside is checked.

### Done

- [x] **Phase 0 — Investigation + this doc.** LuaJIT `lj_asm_patchexit` mechanism
  mapped to bytes-and-pointers (`lj_asm_x86.h`, `vm_x86.dasc`, `lj_asm.c`,
  `lj_trace.c`); lune's native guard-exit emission mapped to the patch-point
  (`nativegen.zig` exit stubs → shared `deopt_exit`; W^X page finalize). The one
  architectural difference (register vs. `regs[]`-memory handoff) identified.

### Outstanding

**Blocking prerequisites — must be designed before any patch is safe** (peer
review, 2026-07-11; see §Blocking prerequisites for the argument):

- [ ] **P-A — Native chain-entry ABI.** A patched exit cannot `jmp` a child's
  C-ABI prologue on top of the parent's live frame (stack corruption). Define how
  a parent hands off: either (i) parent tears down its frame/callee-saves and rolls
  its `completed` into a chain accumulator *before* a tail-jump to a child C entry,
  or (ii) a bespoke internal chain-entry ABI where linked traces share one frame
  and don't each push/pop. Everything else depends on this.
- [ ] **P-B — Chain-wide result contract.** `NativeResult` describes one trace;
  a child overwrites `completed`/`exit_instr` with *its* IR indices, which the
  dispatcher then mis-attributes to the parent (`interp.zig:2584,2595`) → OOB /
  wrong accounting. Need a result carrying *final* trace identity, *final* exit
  identity, *cumulative* completed work, and the coherent resume PC.
- [ ] **P-C — Exit-kind taxonomy.** Only ordinary per-guard exits hit
  `deopt_exit`. `.link` terminals (`nativegen.zig:3808`) and linked-numeric-for
  loop-done (`emitLinkedLoopDoneSnapshot`, `nativegen.zig:2934`) have their own
  return/materialization paths and post-loop coherent PCs. Each transition kind in
  nsieve's chain needs its own patch/link rule; patching only ordinary guards
  leaves most hops re-entering Zig.
- [ ] **P-D — Shared code arena (rel32 reachability).** Traces are independent
  `mmap`s with no ±2 GiB guarantee (`nativegen.zig:104`); a `rel32` from parent to
  child may not reach. LuaJIT owns one contiguous mcode arena. Need a near code
  arena, near trampolines, or absolute-indirect transfer.
- [ ] **P-E — Patched-target lifetime / unpatching.** Retired traces are unmapped
  (`removeTrace`→`destroy`, `trace.zig:1749,622`); a parent patched to a freed
  child is use-after-unmap. Need dependency tracking + unpatch-on-retire (or pinned
  trampolines).
- [ ] **P-F — Determinism replication.** The patched path *skips*
  `onSideExit`/`hit_count`/penalty/gate/prime-side arming/lane-widen eviction
  (`interp.zig:2588,2605,2763`) — all of which steer *future* recording. Skipping
  them changes which traces get recorded/selected later, so byte-identity is **not**
  free. Either replicate the accounting on the patched path or prove it inert; and
  handle the exec-log mode that picks tier-1a before native (`interp.zig:2567`).
- [ ] **P-G — Child eligibility + prologue-failure fallback.** A direct patch
  bypasses `driveChain`'s guards (zero synthetic inputs — `seedTraceInputs` is
  mandatory for `inputs.len != 0`, `interp.zig:2551`; native availability; terminal
  shape; bounded candidate attempts). Child prologue failure is state-safe
  (`nativegen.zig:3884` leaves `regs[]` untouched) but currently has *no* clean
  fallback after a patched jump (parent count lost, no sibling retry). Both need a
  defined contract.

**Implementation phases (unblocked only after the prerequisites above):**

- [ ] **Phase 1 — Patch infrastructure.** `exit_instr → mcode offset` map on
  `CompiledTrace`; W^X repatch on `ExecPage`. (Still needed; unchanged.)
- [ ] **Phase 2 — Memory-handoff link.** Once P-A/P-B/P-C exist, patch each
  transition kind to hand off native→native through `regs[]`. A/B on nsieve.
- [ ] **Phase 3 — Register-level coherence (defer).** Keep carried values in
  registers across the handoff (canonical anchor register assignment or an
  `asm_head_side`-style reconciling head). Only if Phase 2's A/B shows the memory
  round-trip still dominates.
- [ ] **Open question — safe point vs. live parent.** Patching happens in the
  dispatcher *after* the native call returned, so normally no parent activation is
  live; but `mprotect(RW)` makes the whole page briefly non-executable, and lune's
  assembler does not align jump operands (`x64.zig:852`). Use an explicit safe
  point; do not treat "aligned 4-byte store" as the safety proof (LuaJIT relies on
  its mcode write-protect protocol, not dword-store atomicity).

## The LuaJIT mechanism (what we're porting)

Four moving parts on x86-64 (`~/Projects/LuaJIT/src/`):

1. **Exit stubs** — shared 4-byte trampolines, one per exit number. They live in
   `jit_State.exitstubgroup` and are generated **lazily and reused** across trace
   compiles (`asm_exitstub_setup`, `lj_asm_x86.h:51`; addressing via
   `exitstub_addr`, `lj_target.h:152`), not freshly per trace — a correction to the
   first-draft claim. Each pushes its exit number and falls into a shared
   `jmp lj_vm_exit_handler`. The stub address is a pure function of the exit
   number.
2. **Guard jumps** — each guard is a 6-byte near `0f 8x rel32` (`emit_jcc`,
   `lj_emit_x86.h:502-509`) whose `rel32` targets *its exit's* stub. Exit number =
   snapshot index; one `SnapShot` per exit.
3. **The exit handler** — `lj_vm_exit_handler` (`vm_x86.dasc:2806`) spills all
   GPRs/XMMs into an `ExitState`, reconstructs the exit number, sets
   `J->parent`/`J->exitno`, and calls `lj_trace_exit`, which `lj_snap_restore`s
   the interpreter stack from the exit snapshot. **This entire path runs only
   before a side trace exists.**
4. **The patch** — `lj_asm_patchexit` (`lj_asm_x86.h:3127-3164`). When a side
   trace is assembled (`trace_stop`'s `BC_JMP` case, `lj_trace.c:528-545`), it
   makes the parent page writable, scans the parent mcode with a length decoder,
   finds every `0f 8x` whose `rel32` resolves to the target exit's stub
   (`px = exitstub_addr(exitno) - 6`), and rewrites the 4-byte `rel32` at `p+2` to
   `side_entry - (p+6)`. It skips the stack-check and GC-check exits. Then it marks
   the parent snapshot `SNAPCOUNT_DONE` so it's never side-traced again.

**Why the direct jump needs little marshalling (the crux):** the side trace's head
(`asm_head_side`, `lj_asm.c:1941-2110`) was compiled to expect *exactly* the
parent's register/spill state at that exit — seeded by `lj_snap_regspmap` reading
the `(parent, exitno)` snapshot's RegSP map as register-allocation hints, then a
reconciling prologue that reloads spills and register-shuffles (breaking cycles
through a temp). It is **not literally "zero marshalling"** (the first draft
overstated this): `asm_head_side` still adjusts the stack, reloads spills, and
shuffles registers — the property is *direct native-to-native state
reconciliation with no interpreter round-trip*, not zero work. The **snapshot is
the single coherence contract**, consumed by both the interpreted restore *and*
the native side-trace head. The patch swings one `rel32` from the
interpreted-exit stub to that head.

**The structural precondition lune does not share:** LuaJIT traces are mcode in
*one contiguous VM-owned arena* and do **not** each carry a C-ABI stack frame — a
trace transfer is a bare `jmp` within a shared machine-code region, and the frame
/ stack discipline is uniform across all traces. lune traces are each entered as
an **independent C function** (`fn(tags, payloads, *NativeResult) callconv(.c)`)
with their own push/frame-alloc prologue and `pop`/`ret` epilogue, each in its own
`mmap`. That single fact is what turns "swing one rel32" from a 4-byte edit into a
new-ABI problem (see §Blocking prerequisites).

## lune today (where the patch point is)

lune's tier-1b backend funnels **all** native guard exits through one shared
epilogue (`nativegen.zig`):

- Each guard's failure path is a `jcc`/`jmp rel32` to a **per-guard-instr local
  label** (`jccNativeExit`/`jmpNativeExit`, `nativegen.zig:2705-2718`).
- Each label binds a tiny stub (`nativegen.zig:3843-3857`):
  `mov dword [rdx + exit_instr], <ir_index>` then `jmp deopt_exit`. `rdx` is the
  `*NativeResult` out-param.
- `deopt_exit` (`nativegen.zig:3870`) flushes every `.carried` slot's register
  home back into the `regs[]` SoA file (`flushSlot`, re-boxing with type tags),
  writes `completed = rbx`, runs the shared teardown (`add rsp; pop; ret`).

Control returns to the dispatcher by a plain C-ABI `ret`; the trace was entered
as `fn([*]u8 tags, [*]u64 payloads, *NativeResult) callconv(.c) void`
(`nativegen.zig:351`). `interp.zig` (~2560–2810) unpacks `ExecResult`, does
guard-failure accounting, then `driveChain` linear-scans the trace cache
(`nextTraceExcluding`, `trace.zig:1084`) and enters the next trace via a fresh
`NativeResult` + indirect call — the ~600 ns.

**Patch site.** The natural target is the exit stub's trailing `jmp deopt_exit`
(`nativegen.zig:3845-3855`): it is already one 5-byte `jmp rel32` per
`exit_instr`. Redirecting one exit = rewriting that `rel32` to a side trace's
entry.

**Three things don't exist yet** (all net-new, all Phase 1):

1. **No exit-instr → offset map survives compilation.** `exit_labels` is
   `gpa.alloc`'d and freed by `defer` at the top of `lower` (`nativegen.zig:2970`);
   the `Assembler` (labels + fixups) is deinit'd after `resolve()`. `CompiledTrace`
   retains only the `ExecPage` bytes (`nativegen.zig:348`) — no metadata linking an
   exit to where its jump lives. We must record `exit_instr → byte-offset` during
   `lower` and store it on `CompiledTrace`.
2. **The page is W^X (RX), not RWX.** `mapExecutable` maps RW, copies, then
   `mprotect`s to `READ|EXEC` (`nativegen.zig:104-134`). In-place patching needs a
   `mprotect(RW) → write → mprotect(RX)` path on `ExecPage`.
3. **No parent-guard → side-trace address link.** The trace layer records side/
   link traces by anchor (`findLinkTrace`, doc 15/16), but the parent's compiled
   page holds no reference to a child's `CompiledTrace.page.entry()`. Joining
   `(parent Trace, exit_instr)` → `child entry addr` at side-trace compile time is
   the trigger for the patch.

## The one real difference — memory handoff, not register handoff

This is the load-bearing distinction and it defines the phasing.

LuaJIT keeps live values **in registers** across the guard exit; the side trace's
head shuffles the parent's registers into place. That is why LuaJIT *needs*
`asm_head_side` + the snapshot RegSP map — without them the direct jump would land
on code that reads the wrong registers.

lune keeps live values **in the `regs[]` SoA memory file**. The parent's
`deopt_exit` flushes carried homes to `regs[]`; the child's prologue loads them
back from `regs[]` and re-checks their tags. Both sides already agree on the
`regs[]` layout at a shared anchor pc — that agreement is exactly what makes
`driveChain` correct today (it passes `regs` and each entered trace reads its
coherent state from the file at its anchor).

Consequences — with the peer-review corrections folded in:

- **lune's patch avoids LuaJIT's register-shuffle head for a *correct value
  transfer*:** the handoff medium (the memory file) is layout-compatible between
  siblings at a shared anchor by construction, so no `asm_head_side`-style register
  reconciliation is needed *merely to move the values*. This much of the first
  draft holds — see the coherent-anchor contract already relied on by `driveChain`
  (`trace.zig:1200`).
- **But "no `asm_head_side` needed" is true only about physical value layout, not
  about the control/fallback contract.** The naive direct jump breaks on several
  axes the memory-layout argument does not touch: the per-trace C-ABI frame (a
  child prologue cannot run on top of the parent's live frame), result attribution,
  the multiple exit kinds, child eligibility, and the fallback when a child's own
  entry guards fail. These are the §Blocking prerequisites.
- **The round-trip lune still pays** (that LuaJIT avoids): even once a *valid*
  native handoff exists, the parent flushes carried homes to `regs[]` and the child
  reloads + re-tag-checks them in its prologue. The child prologue is **not** just
  "reload 1–2 carried slots" — it tag-checks every non-write-only slot, reloads
  invariants/spills, and re-runs table/function identity + array-base checks
  (`nativegen.zig:3006-3125`). Still likely tens of cycles when hot (much less than
  a 600 ns dispatch), but the first draft conflated "1–2 carried slots" with "1–2
  prologue checks." Phase 3 (register coherence) is what removes this round-trip.

**Retraction of the headline hypothesis.** The first draft claimed *"Phase 2 alone
flips nsieve from neutral to a win."* That is **unsupported** and partly wrong: the
proposed patch site (the ordinary per-guard exit stub) covers only *one* of
nsieve's transition kinds. The prime→inner→continuation chain also hops through
`.link` terminals and linked-numeric-for loop-done exits, which do **not** flow
through `deopt_exit` and have no patch point in the first draft — so most of
nsieve's linked-burst hops would still re-enter Zig. The *narrow* hypothesis that
survives: **once a valid direct native handoff exists for a given transition kind,
the hot `regs[]` stores + prologue checks are probably much cheaper than the
600 ns Zig dispatch.** That is plausible and worth measuring, but it is a
per-transition-kind claim, not a whole-benchmark prediction, and it presupposes
P-A…P-C are built. We measure component costs (dispatch vs. memory handoff vs.
child prologue vs. remaining unpatched hops), not a single before/after.

## Blocking prerequisites

These came out of the peer review (gpt-5.6-sol, 2026-07-11) verified against the
tree. None of the implementation phases are safe until these are designed; they
are the checklist items P-A…P-G above, argued here.

**P-A — Native chain-entry ABI (the load-bearing blocker).** Every lune trace is
entered as an independent C function that pushes callee-saves, allocates a spill
frame, and keeps its completed-iteration count in `rbx` (`nativegen.zig:2991`), all
restored by `emitTeardown` before `ret` (`nativegen.zig:3870`). Patching an exit
stub to `jmp child.entry` skips that teardown: the child then pushes *its* frame on
top of the parent's live frame, and its eventual `ret` returns through parent spill
contents — a crash, not a link. A correct patched route must (1) materialize the
exit state, (2) fold the parent's `rbx` into a chain-wide completed count, (3)
restore the parent frame + callee-saves, (4) preserve the ABI arg regs
(`rdi`/`rsi`/`rdx`), and only then tail-jump to a child C entry — *or* introduce a
bespoke internal chain-entry ABI where linked traces share one frame and skip the
per-trace push/pop. Contrast LuaJIT: its traces are mcode in one arena with a
uniform frame, so a trace-to-trace `jmp` is frameless by design. This is the
decision everything else hangs off.

**P-B — Chain-wide result contract.** `NativeResult{completed, exit_instr,
linked_loop_done}` (`nativegen.zig:337`) describes *one* trace. A child resets
`rbx` to 0 in its prologue (`nativegen.zig:2996`), overwrites `result.completed`
with only its own count, and writes an `exit_instr` indexed into *its* IR. The
dispatcher still binds the returned result to `ct` = the parent and indexes the
parent's instrs with it (`interp.zig:2584,2595`) → out-of-bounds or wrong-guard
accounting, and the parent's committed count is lost (it drives `onSideExit`,
arming, gating). Need a result carrying *final* trace identity, *final* exit
identity, *cumulative* completed work, and the coherent resume PC.

**P-C — Exit-kind taxonomy.** Ordinary per-guard exits flush `.carried` slots via
`deopt_exit`. But: `.link` terminals commit every slot-bound phi snapshot and
return directly, not through `deopt_exit` (`nativegen.zig:3808`); linked-numeric-
for loop-done runs `emitLinkedLoopDoneSnapshot` (post-guard stores + phi handling,
coherent PC is *post-loop*, `nativegen.zig:2934`) and its trigger currently comes
from the dispatcher *before* entry (`interp.zig:2573`); write-only slots are
committed at the completed back-edge, **not** at a failing-iteration deopt
(`nativegen.zig:3760`) — flushing a failing iteration's write-only temp would be
wrong. Each transition kind in nsieve's chain (skip→prime guard, prime `.link`→
inner, inner loop-done→continuation, continuation `.link`→inner) needs its own
patch/link rule.

**P-D — Shared code arena / rel32 reachability.** Each trace is its own anonymous
`mmap` (`nativegen.zig:104`) with no ±2 GiB adjacency guarantee, so a parent→child
`rel32` may be unencodable. LuaJIT owns a contiguous mcode arena and asserts
reachability. Options: a near code arena for trace mcode, per-link near
trampolines, or an absolute-indirect transfer (`jmp [mem]`) at the patch site.

**P-E — Patched-target lifetime.** Traces are retired and their pages unmapped via
`removeTrace`→`destroy` (`trace.zig:1749,622`); a parent patched to a since-freed
child is a use-after-unmap on the next exit. Need a back-reference so retiring a
child unpatches its parents (restore the exit to `deopt_exit`), or pinned
trampolines that outlive individual traces.

**P-F — Determinism replication (not free).** The dispatcher path the patch
replaces does more than transfer control: it runs guard-failure counting,
`onSideExit`, `hit_count`, penalty/gate updates, prime-side arming, and lane-widen
eviction (`interp.zig:2588,2605,2763`). Those mutate *future* trace
selection/recording. A patched jump that skips them changes which traces exist
later — so byte-identical output is **not** guaranteed by construction (this
retracts the first draft's P-EBP-2 claim that "patching adds no new signal").
Either the patched path must replicate the accounting that still matters, or each
skipped counter must be *proven* inert once a link is committed. Additionally, when
exec-logging is on the dispatcher selects tier-1a *before* the native branch
(`interp.zig:2567`), so the patched-native exec-log surface must be reconciled with
the tier-1a one, not assumed identical.

**P-G — Child eligibility + prologue-failure fallback.** A direct patch bypasses
every precondition `driveChain` enforces today: zero synthetic inputs (a trace with
`inputs.len != 0` requires `seedTraceInputs` before entry — `interp.zig:2551` —
and must **never** be a patch target), native availability, terminal shape, bounded
candidate attempts, and exclusion of already-failed siblings (`trace.zig:1239,
1249`). And when a patched child's *own* prologue guard fails, it returns
state-safe (zero completed, `regs[]` untouched — `nativegen.zig:3884`) but into a
world with no fallback: the result is attributed to the parent, the parent count is
gone, and the `driveChain` that would have tried another sibling was bypassed. The
link contract must define this fallback (e.g. child-prologue-fail returns to a
dispatcher entry that re-derives coherent tier-0 state at the anchor).

## Phasing (unblocked only after the prerequisites)

### Phase 1 — Patch infrastructure (no behavior change)

- **`exit_instr → offset` map on `CompiledTrace`.** During `lower`, record the
  byte offset of each patchable jump's `rel32` operand (the assembler knows the
  emit position); store it on `CompiledTrace`. Only new persisted state; changes no
  emitted byte. This much is safe to build independently of the ABI decision and is
  a reasonable first concrete step *if* Bart wants motion before P-A is settled.
- **`ExecPage.repatch(offset, bytes)`** — `mprotect(RW)` → overwrite →
  `mprotect(RX)`; assert the write stays within the page. Note the page is briefly
  non-executable during `mprotect`, so this composes with the safe-point decision,
  not with dword-atomicity.
- Gate: `just test`, 10-mode matrix byte-identical (nothing calls `repatch` yet).

### Phase 2 — Memory-handoff link (needs P-A, P-B, P-C, P-D, P-E, P-G)

- Implement the chain-entry ABI (P-A) and result contract (P-B), then link each
  transition kind (P-C) native→native through `regs[]`, honoring eligibility and
  fallback (P-G), reachability (P-D), and lifetime (P-E). Replicate or prove-inert
  the skipped accounting (P-F).
- Gate: 10-mode matrix byte-identical; keyframe + replay goldens unchanged;
  **component-timed** nsieve A/B (dispatch vs. handoff vs. prologue vs. residual
  unpatched hops), per doc 16 methodology.

### Phase 3 — Register-level coherence (defer; measure Phase 2 first)

- Only if Phase 2's component timings show the flush→memory→reload round-trip still
  dominates. Sub-options: a canonical anchor→register assignment so siblings agree
  by construction (child skips flush *and* reload), or a ported `asm_head_side`
  reconciling head. Note (peer review): canonical register assignment alone does
  not discharge the child's *structural/identity* entry guards — those are separate
  from value placement and must still be reconciled (inherited-vs-new guard
  semantics).

## Determinism obligations

Exit patching is **native-only** (there is no tier-1a IR to patch), so it fires
only under `--jit-native`. The C5 obligation (doc 16) must be discharged
explicitly — and, per P-F, is **not** free:

- **P-EBP-1 (output invariance).** Patched-native must produce byte-identical
  stdout + effects + keyframe/replay goldens to the tier-0 and tier-1a paths.
  Gated on the 10-mode matrix, plus assertions on link firing, final trace/exit
  identity, cumulative completed count, coherent fallback PC, and heap effects
  firing exactly once — *not* assumed by construction.
- **P-EBP-2 (accounting equivalence, was "mode-invariant timing").** Because the
  patched path skips future-steering accounting (P-F), the obligation is stronger
  than the first draft stated: prove the set/order of *recorded* traces and arming
  decisions is unchanged by patching (replicate the accounting on the patched path,
  or prove each skipped counter inert post-link).
- **P-EBP-3 (replay).** Patching changes control flow, not observable state or the
  order/content of side effects. Confirm against replay goldens *and* assert the
  exec-log surface does not widen; reconcile the exec-log-on tier-1a selection
  (`interp.zig:2567`) explicitly.
- **P-EBP-4 (safe point, was "atomicity").** The real safety argument is a JIT
  safe point where no code on the affected page is executing — not dword-store
  atomicity. Patching runs in the dispatcher after the native call returned, so
  normally no parent activation is live; `mprotect(RW)` briefly makes the page
  non-executable, and lune does not align jump operands (`x64.zig:852`), so do not
  lean on an aligned atomic store. Identify any reentrant JIT-activity path
  (native callback / host hook) that could violate the safe point.

## References

- `docs/design/16-coherent-state-chaining.md` — the chaining mechanism this
  replaces the transition cost of; the nsieve outcome that motivates this doc.
- `docs/design/15-nested-loop-linking.md` — `.link`/exit-PC anchors, side-trace
  recording the parent-guard link builds on.
- `docs/design/05-native-codegen.md`, `09-soa-register-file.md` — the tier-1b
  backend and `regs[]` handoff model.
- LuaJIT: `lj_asm_x86.h` (`asm_exitstub_gen`, `lj_asm_patchexit`),
  `lj_asm.c` (`asm_head_side`, `asm_setup_regsp`), `lj_snap.c`
  (`lj_snap_regspmap`), `lj_trace.c` (`trace_stop` `BC_JMP`, `trace_hotside`),
  `vm_x86.dasc` (`lj_vm_exit_handler`).
