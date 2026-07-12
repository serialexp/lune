# Exit-Branch Patching (Direct Side-Trace Linking) — Design

Status: partial — Increment 1 (shared mcode arena, P-D), Increment 2.1 (frameless chain-entry ABI, P-A), Increment 2.2 (chain-wide result contract, P-B) and Increment 2.3a (indirect exit + link-slot table + P-E registry scaffolding) landed; all byte-identical. Direction chosen (faithful port; re-architect lune's native traces toward LuaJIT's frameless shared-arena model). Native trace bodies now run frameless under one shared trampoline (`ensureTrampoline`); every native exit stub jumps through a per-exit heap-resident link slot (`jmp qword [&slots[i]]`, default = `shared_exit`) and bakes the final trace's stable id into `NativeResult.final_trace_id`, resolved by the dispatcher via `traceById` (asserts `final == ct` while no slot is armed). The P-E backlink registry (`armed_links` + `armNativeLink`/`resetLinksTouching`, reset before `destroy` in `removeTrace`) is wired but inert — nothing arms a slot yet. Next: Increment 2.3b — arm `.link`-terminal handoffs from `driveChain`. A 2026-07-12 codex contract review re-scoped it (the `.link` terminal is not single-contract on the child side — the inner root needs `linked_loop_done` mode propagation; and cumulative `rbx` must not drive `onSideExit`), so 2.3b is split into 2.3b-0 (inert scaffolding: `linked_entry` mode-propagation stub, `NativeResult.local_completed`, fail-closed `traceById`; byte-identical, reviewed) then 2.3b-1 (flip arming on + driveChain accounting split). See §Implementation status → Outstanding.
Owner: Bart
Last updated: 2026-07-12 (Increment 2.3b-0 landed — inert arming scaffolding across four byte-identical commits: S3 prologue_fail cumulative-`rbx` prep, fail-closed `traceById`, `NativeResult.entry_rbx`→`local_completed`, and the `linked_entry` secondary-entry stub + `x64.labelOffset`. Nothing armed; `final == ct` still holds. Peer-reviewed codex gpt-5.6-sol + fable: SOUND / behavior-neutral today, correct foundation — rbx provably 0 at every body/prologue-fail entry, `linked_entry` inert and 1:1-mapped, one misleading comment fixed. Two arming-time musts recorded on the 2.3b-1 item: drop the `entry_rbx==0` assert, classify productivity via `local_completed`. nsieve 3-mode + 6-benchmark differential green.)

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
- [x] **P-D — Shared code arena (Increment 1).** `McodeArena` (`nativegen.zig`):
  a chain of ~1 MiB `mmap`'d regions, bump cursor + first-fit free-list, mcprot-
  style RW↔RX toggle per write. Owned by `TraceState` (`mcode_arena`), deinited
  *after* the trace cache so per-trace `free` returns slots first. Every native
  trace is now a co-located slice (`ExecPage` is a view: `.owned` mmap for the
  test path, `.arena` slot for production via `compileInto`→`nativeFor`). Per-trace
  reclaim kept via the free-list (Bart's call: try reclaim first, revisit if it
  measures worse than pure bump). No cross-region references emitted yet, so the
  ±2 GiB reachability check is deferred to Increment 2. Behaviour byte-identical:
  10-mode matrix green, nsieve identical across tier-0/tier-1a/native, bench
  unchanged (arena work is compile-time only, never the hot loop).
- [x] **P-A — Frameless chain-entry ABI (Increment 2.1).** The shared trampoline
  (`McodeArena.ensureTrampoline`) owns the single C frame: it saves every
  callee-saved GPR once, reserves a fixed `SPILL_MAX`-slot spill area (keeping body
  `rsp % 16 == 8`), zeroes the rbx counter, and `jmp`s into the body (`body_entry`
  in rcx). Trace bodies are now frameless — `lower` skips the per-trace
  `push/sub/pop/ret` when `shared_exit != null` and every side-exit jumps (absolute)
  to the trampoline's `shared_exit` instead of tearing down its own frame. A body
  needing more than `SPILL_MAX` (512) spill slots bails to tier-1a. `CompiledTrace`
  gained `trampoline_entry`; `run` dispatches through the trampoline for arena
  (production) pages and directly for owned (test) pages. This is option (ii) from
  the P-A sketch — linked traces share one frame and don't each push/pop — the ABI
  foundation the link handoff (P-C) and chain-wide result (P-B) build on. No linking
  yet: exits still land on `shared_exit`, so behaviour is byte-identical (10-mode
  matrix green; nsieve + nsieve-bit + field_hash/grid/array all tier-0==native;
  nsieve jit ms flat vs the pre-change baseline).
  - **ABI invariant made explicit (2.3a review, fable item 5).** When a slot is
    armed (2.3b+) an exit becomes a bare `jmp` into a child body under the shared
    frame, inheriting the parent's exit-time register state. That is only safe
    because at every *chainable* exit the SoA lane registers `rdi` (tags) / `rsi`
    (payloads) are guaranteed live-and-correct — the `.link` terminal and
    linked-loop-done stub both flush φ/snapshot state through them immediately
    before `emitReturn`. `rdx` (`*NativeResult`) and `rsp` (trampoline frame) are
    body-reserved; `rbx` is the cumulative iteration counter carried *across* the
    hop (its chain-wide meaning is P-B/P-G). This liveness is a **contract**, not an
    accident: any new chainable exit kind must re-establish `rdi`/`rsi` before it
    hands off. `rax` is dead scratch at every exit (used only to load the slot
    address).
- [x] **P-B — Chain-wide result contract (Increment 2.2).** `NativeResult` gains
  `final_trace_id: u32` — the stable id of the *final* trace in the chain, baked as
  an imm32 into every native exit stub (`emitReturn` writes it to
  `@offsetOf(NativeResult,"final_trace_id")` via rdx, which holds `*NativeResult` at
  every exit). `ExecResult` (tier-1a) grows the same field, *defaulted* to
  `NO_TRACE_ID` so the ~40 tier-1a construction sites are untouched (zero churn).
  Traces carry a stable, never-reused `id` (monotonic `TraceState.next_trace_id`,
  assigned at finalize) because the cache index is `swapRemove`'d and unusable as a
  baked constant; `TraceState.traceById(id)` resolves it. The dispatcher computes
  `final = traceById(result.final_trace_id) orelse ct` and asserts `final == ct`
  under `ran_native`. With no linking armed yet every exit bakes its own `ct.id`, so
  `final == ct` always holds — the assert validates the full baked-id round-trip
  (id → stub imm32 → `NativeResult` → `traceById`) end-to-end while staying
  byte-identical. Consumers stay routed through `ct`; 2.3 routes them through
  `final` once child links populate a real id. (nsieve/nsieve-bit/fannkuch/
  mandelbrot/nbody/spectral-norm all tier-0==native; Debug asserts pass.)

- [x] **Increment 2.3a — indirect exit + link-slot table + P-E registry
  (byte-identical, nothing armed).** The direct `movabs rax, shared_exit; jmp rax`
  exit becomes an indirect `movabs rax, &slot; jmp qword [rax]` (`x64.zig` gains
  `jmpMem` (FF /4 memory form) + golden-byte tests). `CompiledTrace` gains an owned,
  heap-allocated `slots: []usize` (one per IR instruction index) plus a `gpa` handle
  for `deinit`; `compileImpl` allocates it *before* `lower` (so `&slot` is a stable
  imm64) and default-fills every entry with `shared_exit`, so an unarmed slot is
  behaviourally identical to 2.1's direct jump. `emitReturn` takes a `slot_addr:
  ?usize` and bakes the indirect form when set (the `.link` terminal and loop-done
  stub pass their slot; `deopt_exit`/`prologue_fail` pass `null` → unchanged, still
  direct to `shared_exit`). The **P-E backlink registry** lands here as inert
  scaffolding: `TraceState.armed_links: ArrayList(NativeLink{parent, slot_index,
  child})`; `armNativeLink(parent, slot, child, target)` records the dependency (and
  supersedes a prior same-slot record) then writes the slot; `resetLinksTouching(t)`
  — called in `removeTrace` **before** `t.destroy` — resets each surviving parent's
  slot back to `shared_exit` when `t` is a link *target* (child retires) and drops
  the record when `t` is a link *source* (parent retires, slot array about to be
  freed), re-deriving the slot address from the live parent so it's never a cached
  dangling pointer. A focused unit test pins both retire directions, re-arm
  supersede, and OOB/non-compiled no-ops. Chosen a flat trace-identity-keyed list
  over the plan's `AutoHashMap(*Trace, ArrayList(*usize))` because keying on trace
  identity (not cached slot pointers) makes reset correct regardless of retire order.
  Nothing arms a slot yet, so `armed_links` is always empty and `final == ct` still
  holds — provably inert. (nsieve/nsieve-bit/fannkuch/mandelbrot/nbody/spectral-norm
  tier-0==tier-1a==native byte-identical; `just bench --filter nsieve` flat within
  noise — one extra load per exit.) **Hardened post-landing** per an independent
  two-model review (codex gpt-5.6-sol + a fable technical-architect pass, both
  "approve with changes"): fixed a latent OOM-only re-arm UAF (BUG-1 — the
  supersede path now mutates the record in place instead of remove-then-append, so a
  failed append can never strand an armed-but-untracked slot); `armNativeLink` now
  returns `bool` (armed vs no-op) for P-F accounting; pinned "`armNativeLink` is the
  only writer of `slots[i]`" as an invariant. Deferred to 2.3b (need real compiled
  pages / a live trampoline to exercise): the Debug `target`-within-`child`-page
  bounds assert, the missing-trampoline assert (BUG-2), and a real
  retire-then-reuse lifetime test (fable item 6). The slot-identity-vs-exit-kind
  collision (2.3c) and the `rdi`/`rsi` liveness contract are recorded under P-C and
  P-A above.

### Outstanding

**Increment 2.3b — arm `.link`-terminal handoffs (ACTIVE; re-scoped after the
2026-07-12 codex contract review).** The review found the original one-commit
2.3b under-scoped on two counts, so it is split into an inert-scaffolding step
(2.3b-0, byte-identical, reviewed) and an arming step (2.3b-1). The armed hop is
**Hop A**: a `.link` continuation reaching its terminal → the inner-loop root it
names (run today via `runLinkedLoopDone`, trace.zig:1369). Findings:

  1. *The `.link` terminal is NOT single-contract on the CHILD side.* The inner
     root `I` is run in linked mode (`runLinkedLoopDone` sets
     `NativeResult.linked_loop_done = 1`; `I`'s loop-done guard reads it at
     nativegen ~4213 to pick linked-completion materialization). A bare armed
     `jmp I.page.code.ptr` never sets the flag → `I` takes ordinary `deopt_exit`,
     never commits its final iteration → wrong state. **Fix (2.3b-0): a second
     entry point `linked_entry` on every frameless body** that presets the flag
     then falls into `body_entry`; the armed slot targets `linked_entry`, not the
     bare body. Emitted after `prologue_fail`, inert until targeted.
  2. *Cumulative `rbx` ≠ the child's local count.* Once fused, `I` is entered under
     the shared frame WITHOUT `xor rbx,rbx`, so `I`'s exit would report the chain's
     cumulative count, not `I`'s own — and `driveChain` feeds that count to
     `onSideExit(I, …)`, which decides penalty/gate/`hit_count` (steers future
     recording). Feeding cumulative `rbx` can flip a low-yield event to "useful" →
     different later traces → non-byte-identical across modes. **Fix (2.3b-0):
     `NativeResult.local_completed`** = `rbx − entry_rbx`, where `entry_rbx` is
     snapshotted into a `NativeResult` scratch field at `body_entry` (rdx-relative,
     uniform for both ABIs; no frame-slot reservation). Unchained, `entry_rbx == 0`
     so `local_completed == completed` — pinned by a Debug invariant in
     `runWithLinkedLoopDone` while nothing is armed.
  3. *`traceById(id) orelse ct` masks a missing id.* Once linking is live a child
     exit must resolve to the child, never silently fall back to the parent.
     **Fix (2.3b-0): fail closed** — when `ran_native`, assert the baked id actually
     resolved (`resolved != null`) before the `orelse ct`; keep `resolved.? == ct`
     until 2.3b-1 drops it.

- [x] **Increment 2.3b-0 — inert scaffolding (byte-identical).** (a) fail-closed
  `traceById` in the dispatcher (`963bdbb`); (b) `linked_entry` stub +
  `CompiledTrace.linked_entry` + `x64.labelOffset` (`954ea89`, emitted, nothing
  targets it); (c) `NativeResult.entry_rbx` scratch → `ExecResult.local_completed`
  with the `entry_rbx == 0` / `local_completed == completed` invariant (`319da11`).
  S3 prep (prologue_fail commits cumulative `rbx`) landed first (`9d16711`). Four
  separate byte-identical commits; nsieve 3-mode + 6-benchmark tier-0==`--jit-native`
  differential green. **Peer-reviewed (codex gpt-5.6-sol + fable), 2026-07-12:**
  SOUND / behavior-neutral today, correct foundation. rbx provably 0 at every
  `body_entry`/`prologue_fail` reach (trampoline + self-framed both `xor rbx,rbx`
  before entry; sole `inc rbx` is the back-edge → `loop_top`, never before entry);
  `linked_entry` inert (no consumer) and its address maps 1:1 (`resolve()` patches
  rel32 in place, `McodeArena.alloc` `@memcpy`s verbatim). Nit fixed: the
  `movMemImm32(linked_loop_done,1)` comment wrongly said "dword store to the low
  half" — it is REX.W `C7 /0`, a full-u64 store.
- [ ] **Increment 2.3b-1 — flip arming on.** In `driveChain`, after Hop A is
  accounted, `armNativeLink(current_link, terminal_idx, inner, inner.linked_entry)`
  (eligibility: `inner.compiled`, `inputs.len == 0`, `.link` terminal; safepoint
  blackout when `record_exec_log`/`record_safepoint_lines`/`suspend_ctl` active).
  Rewrite the burst loop to handle a FUSED `snt.run` result whose `final_trace_id ==
  inner.id` (continuation linked straight into inner): reproduce the hop's logical
  accounting (`onSideExit(inner, max(local_completed,1))` + `linked_completed += 1`)
  from the aggregate result instead of the separate `runLinkedLoopDone` call. Drop
  `assert(final == ct)`; route exit IDENTITY (`exit_instr`/guard/resume PC) through
  `final`, steering-accounting through the reproduced hop events. Verify 10-mode
  byte-identical + arm counter > 0 + bench.
  - **MUST (both 2.3b-0 reviewers, arming-time correctness):**
    1. **Drop `assert(result.entry_rbx == 0)`** in `runWithLinkedLoopDone`
       (nativegen ~669) when arming activates. In ReleaseFast the assert is an LLVM
       *assume*, folding `completed -% entry_rbx` → `completed` — silently
       resurrecting the exact cumulative-count `onSideExit` bug `local_completed`
       exists to kill, visible only as cross-mode release divergence.
    2. **Classify final-trace productivity by `local_completed`, NOT cumulative
       `completed`.** The surrounding `if (result.completed > 0)` branch
       (interp.zig ~2626) must switch to `local_completed`; a chained child that
       fails its prologue returns `completed = parent-cumulative` (nonzero) but
       `local_completed == 0` — the old test would misclassify it productive. Keep
       field meanings rigid: `completed` = aggregate/resume; `local_completed` =
       final-trace productivity/penalty; `final_trace_id`+`exit_instr` = identity.
  - **Note (fable):** `linked_loop_done` is sticky once the stub sets it — every
    later body in the native run sees 1. Correct for Hop A (continuation + inner both
    want linked mode); a hazard only if 2.3c ever arms an exit into a body that must
    materialize *unlinked* loop-done — flag under P-C.

**Blocking prerequisites — must be designed before any patch is safe** (peer
review, 2026-07-11; see §Blocking prerequisites for the argument):

- [ ] **P-C — Exit-kind taxonomy.** Only ordinary per-guard exits hit
  `deopt_exit`. `.link` terminals (`nativegen.zig:3808`) and linked-numeric-for
  loop-done (`emitLinkedLoopDoneSnapshot`, `nativegen.zig:2934`) have their own
  return/materialization paths and post-loop coherent PCs. Each transition kind in
  nsieve's chain needs its own patch/link rule; patching only ordinary guards
  leaves most hops re-entering Zig.
  - **OPEN QUESTION (2.3a review — decide before 2.3c arms ordinary guards):**
    the slot table is indexed by *IR instruction index*, but that is an exit
    *instruction* identity, not an exit *kind* identity. A numeric-for loop-done
    guard at index `ei` has **two** logical exits sharing that index — the ordinary
    deopt (chain to same-anchor sibling) and the linked-loop-done (materialize final
    iteration, chain to continuation). 2.3a arms neither (only the `.link` terminal,
    at the distinct terminal index), so there is no collision today. But if 2.3c
    routes ordinary-guard failures through `slots[ei]` it collides with the
    linked-loop-done target already using `slots[ei]`. Resolve by either (a) keying
    physical slots on `(instr_index, exit_kind)` rather than raw index, or
    (b) explicitly forbidding ordinary-link arming on numeric-loop-done guards and
    documenting that it loses no required chain. Decide before 2.3b bakes consumers
    around `exit_instr → slot index`.
- [ ] **P-E — Patched-target lifetime / unpatching.** Since Increment 1 the arena
  keeps regions mapped for the whole run, so a stale patch is no longer a raw
  use-after-*unmap* — but it is now use-after-*reuse*: `removeTrace`→`destroy`
  (`trace.zig:1749,622`) returns the child's mcode slot to the arena free-list, and
  a later `compileInto` can hand that exact slot to an **unrelated** trace, so a
  parent still patched to it would `jmp` into foreign code. Need dependency tracking
  + unpatch-on-retire before a freed slot may be reused (or pin patched-into slots
  out of the free-list / use trampolines). Strictly required once patching exists.
  *Registry scaffolding landed in 2.3a* (`armed_links` + `armNativeLink`/
  `resetLinksTouching`, reset before `destroy`); inert until 2.3b arms the first
  slot. Still outstanding: exercise the reset under a real retire-then-reuse (widen
  eviction) end-to-end — the 2.3d lifetime stress test.
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

## Port architecture (LuaJIT-grounded)

A second read of LuaJIT's `lj_mcode.c` (arena) and `vm_x86.dasc` /
`lj_target_x86.h` (frameless ABI) settled *how* to adapt, and the central finding
is that **lune does not need LuaJIT's full fixed-register convention.** LuaJIT
keeps `BASE`/`PC`/`DISPATCH`/`KBASE` in fixed registers (`lj_target_x86.h:46-53`)
so a trace→trace `jmp` needs zero marshalling. lune already round-trips every
Lua-level value through the `regs[]` SoA memory file, so it only needs the two
sides to agree on **where the base pointers live** — a 2–3 register mini-convention
— not on where any Lua value lives. That keeps the handoff a pure function of
`regs[]` memory (determinism-safe: nothing new is smuggled into a register that
isn't already a deterministic function of the slab) while still enabling a bare
`jmp`.

**The arena (P-D), from `lj_mcode.c`.** One (or few) large `mmap`'d region(s)
instead of a per-trace `mmap`, placed inside a rel32 window so any trace can
`jmp`/`call` any other and the runtime. Port verbatim-in-spirit:
`mcode_setrange`/`mcode_inrange` (`lj_mcode.c:269,288`) — a `[mcmin,mcmax]` window
of width ≤ rel32 range, **centered on the code traces must reach** (LuaJIT centers
on `lj_vm_exit_handler`; lune centers on the Zig `driveChain`/trampoline address so
trace↔runtime calls stay reachable); the contiguous-below-then-probe placement
loop (`mcode_alloc`, `:295-320`); the `LJ_TRERR_MCODEAL` **abort-the-trace**
fallback when no in-range placement is found (`:333`) — out-of-range is never
tolerated. Sub-allocate each trace from a `mctop`/`mcbot` cursor pair; the
`ExecPage` becomes a *slice* of the shared region, not an owned mapping. Area-level
W^X with the `mcprot` RW/RX cache (`:252`) and an `lj_mcode_patch`-style RW/RX
bracket (`:416`) for the patch window.

**The frameless model (P-A), from `vm_x86.dasc`.** LuaJIT traces have no C frame:
`BC_JLOOP` publishes `BASE`, saves the extra callee-saves *once* at the
interpreter↔trace boundary, and `jmp`s into `T->mcode` (`vm_x86.dasc:5429-5461`);
trace→trace links are bare `jmp`s (`asm_tail_fixup`, `lj_asm_x86.h:2961-2963`, taken
**unconditionally** when there's a link target because the arena guarantees reach);
the *only* frame restore is the exit handler (`vm_x86.dasc:2867`), owned by the
interpreter, entered once and left once regardless of how many traces chained.
lune's analogue:

- **One shared trampoline owns the single C frame.** It does the real prologue
  (`push rbx` + callee-saves + frame + pins `tags`/`payloads`/`result` into the
  reserved registers, mirroring `nativegen.zig:2997-3000`), then `jmp`s to the
  first trace body's entry label.
- **Trace bodies become frameless** — drop their per-trace `push/sub`
  (`nativegen.zig:2997-3000`) and `pop/ret` (`:2699-2702`). A body ends by either
  (i) `jmp`ing directly to the next body's label (the chain link — the bare `jmp`
  that replaces the ~600 ns Zig round-trip), or (ii) `jmp`ing to **one shared
  epilogue** that fills `NativeResult`, runs `pop`/`ret` once, and returns to Zig.
- **Exactly one frame is built/torn down per chain entry from Zig**, not per trace.
  `driveChain` calls the trampoline once and gets one chain-wide `NativeResult`
  (P-B) back after the chain reaches a genuine exit.

This is where the nsieve win actually lands: the per-transition re-entry collapses
to a single `jmp rel32` per link.

## Phasing (three ordered increments)

### Increment 1 — Shared arena, keep the per-trace C ABI (P-D) — ✅ LANDED

Pure co-location: replaced `mapExecutable`'s per-trace `mmap` (production path)
with `McodeArena` (`nativegen.zig`) — a chain of ~1 MiB regions, bump cursor +
first-fit free-list, mcprot-style RW↔RX toggle per write. **The per-trace
`call`/`ret` C ABI is unchanged** — traces are still C functions, just co-located.
`ExecPage` became a view (`.owned` for `mapExecutable`'s standalone test path,
`.arena` for the arena); `compile(gpa,t)` (tests) and `compileInto(gpa,arena,t)`
(production via `nativeFor`) share `compileImpl`. Owned by `TraceState`
(`mcode_arena`), deinited after the trace cache. Bought nothing for speed on its
own (arena work is compile-time only); it is the *precondition* for every later
bare `jmp`, landed independently with byte-identical behaviour.

**Deferred out of Increment 1** (were listed here, moved to Increment 2/3 where
they actually apply): the rel32-window placement centred on the runtime + strict
in-range check (nothing emits a cross-region reference yet — all runtime-helper
calls are absolute `mov rax,imm64; call rax`), and the `exit_instr → mcode-offset`
map + `repatch` (that is patch infrastructure, so it lands with Increment 3).
Gate met: `just test` green, 10-mode matrix + nsieve byte-identical, nothing
patched yet.

### Increment 2 — Shared trampoline + frameless bodies (P-A, P-B, P-C, P-G, P-F)

Introduce the single entry trampoline, strip per-trace prologue/epilogue, pin the
2–3 base pointers, and convert chain links from Zig round-trips into bare `jmp`s
between body labels — for each exit kind (ordinary guard / `.link` /
linked-loop-done, P-C). Add the chain-wide result (P-B), child eligibility +
prologue-failure fallback (P-G), and replicate/prove-inert the skipped accounting
(P-F). Gate: 10-mode matrix byte-identical; keyframe + replay goldens unchanged;
**component-timed** nsieve A/B (dispatch vs. handoff vs. prologue vs. residual
hops).

#### Increment 2 — detailed design (frameless + link-slot handoff)

This is the concrete plan the phasing bullet above summarises. It is grounded in
the *current* native ABI (mapped exhaustively from `nativegen.zig`, 2026-07-11):

Current per-trace ABI (what we are replacing):
- Entry `fn(rdi=tags, rsi=payloads, rdx=*NativeResult) callconv(.c) void`.
- Prologue: `push rbx; push <callee-saved used>; xor rbx,rbx; sub rsp,frame`.
  `rbx` = committed-iteration counter; `rdi/rsi/rdx` held across the body;
  `rax/rcx` scratch; allocatable GPRs `r8–r11` (caller-saved) + `rbp,r12–r15`
  (callee-saved, saved only if used); allocatable XMMs `xmm2–xmm15`; spills at
  `[rsp+k*8]` in the trace's own frame.
- Every exit `flushSlot`s live carried/write-only slots back to `regs[]`
  (tags[slot]=tag byte via rdi, payloads[slot*8]=payload via rsi), writes
  `completed`(rbx) + `exit_instr`(i) to `[rdx]`, then `emitTeardown` (restore rsp,
  pop callee-saved, pop rbx, `ret`). `.loop` back-edge is a local `jmp loop_top`.
- Only runtime call is `resolveHashCell`, absolute `mov rax,imm64; call rax`, with
  manual save/restore of rdi/rsi/rdx + caller-saved around it. **No cross-buffer
  rel32 exists.**

**Load-bearing correctness fact (the whole design rests on this):** the *only*
state that crosses a trace→trace transition is `regs[]` (tags/payloads, in
memory), `rbx` (the counter), and `rsp` (constant in a frameless chain). Register
homes are **not** live across a transition — every exit already flushes live slots
to `regs[]`, and every trace's hoisted prologue reloads its homes from `regs[]`.
So a child can reuse the parent's spill area and registers freely; the handoff is
pure memory. (This is the memory-handoff model; register-level coherence that skips
the flush+reload is the deferred "Later" step, measured first.)

**1. Trampoline owns the one C frame (P-A).** Replace the per-trace C prologue/
epilogue with a single shared trampoline, emitted once into the arena (or kept as a
Zig `naked`/asm stub):
```
trampoline(tags=rdi, payloads=rsi, result=rdx, entry=rcx):
    push rbx; push rbp; push r12; push r13; push r14; push r15   ; save ALL callee-saved once
    sub rsp, SPILL_MAX*8 (+align)                                  ; one generous shared spill area
    xor rbx, rbx                                                  ; chain-cumulative counter
    jmp rcx                                                       ; enter the first trace body
shared_exit:                                                       ; every final exit lands here
    ; result.completed / exit_instr / final_trace_id already written by the exiting body
    add rsp, SPILL_MAX*8 (+align); pop r15..r12; pop rbp; pop rbx; ret
```
`SPILL_MAX` is the max spill-slot count any compiled trace can use (a fixed bound;
today's allocator caps spills — pin a comptime `SPILL_MAX` and **bail compile** if a
trace exceeds it, exactly as we bail other unsupported shapes). The trampoline is
the C-callable entry; `CompiledTrace.run` calls `trampoline(tags,payloads,&result,
body_entry)`.

**2. Frameless bodies.** Each trace body drops its own `push`/`sub rsp`/`pop`/`ret`.
It uses `rbx` (counter), `r8–r15/rbp` (homes), `xmm2–15`, `rax/rcx` scratch, spills
at `[rsp+k*8]` in the *shared* frame. Homes are clobbered freely (trampoline saved
them). `.loop` is unchanged (local `jmp loop_top`). The hoisted prologue (type
checks + slot loads from `regs[]`) stays — it is exactly the child-entry reload.

**3. Link-slot indirect handoff (P-A/P-C) — no code patching in Increment 2.** Give
each compiled trace a small **link-slot table**: one writable 8-byte pointer per
*chainable exit* (each ordinary guard exit, the `.link` terminal, each linked-loop-
done exit — the P-C taxonomy). Each slot defaults to `&shared_exit`. An exit site
emits, after its `flushSlot`s + `result` writes:
```
    jmp qword [rip + link_slot_for_this_exit]     ; default target = shared_exit
```
So with all slots at their default, behaviour is byte-identical to today (flush →
write result → leave to the dispatcher via shared_exit → `ret`). When the
dispatcher's existing `driveChain` logic selects a native child `C` for parent `P`'s
exit `E`, instead of returning to re-enter `C` by C-ABI call, it **stores `C`'s
body-entry address into `P.link_slots[E]`** (a plain data write — no `mprotect`, W^X
untouched, since the slot is data, not code). The next time `P` fails guard `E` it
`jmp`s straight into `C`'s frameless body under the same frame. This is the native→
native handoff that removes the ~600 ns Zig round-trip, achieved without touching
the code pages. (Increment 3 upgrades the hottest of these from `jmp [slot]` to a
patched direct `rel32`, shaving the indirect-load; the slot table also *is* the
unpatch/lifetime handle for P-E.)

**4. Chain-wide result contract (P-B).** `NativeResult` describes one trace; a
chain needs the *final* trace's identity. Extend to:
```
ChainResult { completed: usize,        // cumulative rbx across the whole chain
              exit_instr: u32,          // exit index within the FINAL trace
              final_trace_id: u32,      // which trace performed the final exit
              linked_loop_done: u64 }
```
`rbx` already accumulates naturally (never reset on a link jmp). Each body's exit
sites write `exit_instr` **and** a compile-time-constant `final_trace_id` (the
trace's cache id, baked as an imm32) before `jmp [slot]`. The dispatcher then maps
`(final_trace_id, exit_instr) → resume PC` instead of assuming the entered trace.
This removes the `interp.zig:2584,2595` mis-attribution hazard.

**5. Per-exit-kind rules (P-C).** Three exit kinds, each already distinct in
`nativegen.zig`, get a link slot and the uniform `jmp [slot]` tail:
- ordinary guard exit (shared `deopt_exit` today, `:4051`) — one slot per guard `i`;
- `.link` terminal (`:3989`) — one slot (its natural successor is the linked trace);
- linked-loop-done (`emitLinkedLoopDoneSnapshot`, `:3115`; exit path `:4038`) — one
  slot per loop-done guard; the post-guard snapshot stores stay *before* the tail.
Prologue-fail (`:4065`) is **not** chainable (no child makes sense pre-first-
iteration): it writes completed=0, exit_instr=-1, and `jmp shared_exit` directly.

**6. Child eligibility + prologue-failure fallback (P-G).** A slot is only populated
for a child that is native (`.compiled`), has zero synthetic inputs
(`inputs.len==0`; `seedTraceInputs` handoff is not expressible through a bare jmp —
those children stay dispatcher-driven), and whose terminal shape is chainable. When
a populated child's own hoisted prologue guard fails (its entry types don't match
the handoff `regs[]`), that is just a normal guard exit *inside the child*: it
flushes, writes the child's `(final_trace_id, exit_instr)`, and `jmp`s the child's
own slot (default `shared_exit`) — the cumulative `rbx` is intact, so the dispatcher
resumes correctly at the child's guard PC. No parent-count loss, no sibling retry
needed (the dispatcher re-evaluates from the coherent resume PC as it does today).

**7. Determinism (P-F).** The in-mcode handoff *skips* the per-hop dispatcher
accounting that today runs between native traces: `onSideExit`, `hit_count`,
penalty/gate bumps, prime-side arming, lane-widen eviction (`interp.zig:2588,2605,
2763`). These steer *future* recording, so byte-identity is not automatic. Increment
2 keeps them correct by **only populating a link slot after the dispatcher has
already driven that transition enough times to have done its accounting** — i.e. the
slot is armed *by* `driveChain` at the same point it already commits to the chain, so
every accounting side effect that would happen up to arming still happens on the
dispatcher path; once armed, the transition is deterministic control flow between
semantically-equivalent traces whose committed values all round-trip through `regs[]`.
The obligation to discharge in code: prove (via the 10-mode matrix + keyframe/replay
goldens) that no *armed* slot changes which traces get recorded later. If any does,
the fallback is to replicate that specific counter on the trampoline's `shared_exit`
path (it has `final_trace_id` to attribute correctly). Link slots are reset to
`&shared_exit` on any event that would invalidate the child (retire, flush) — which
is also the P-E lifetime hook.

**Sub-stepping (each behind `just test`, byte-identical gate):**
- 2.1 Trampoline + frameless bodies, **all exits pinned to `shared_exit`** (pure
  ABI move; no linking; behaviour byte-identical — this de-risks the frame change
  in isolation). **LANDED** — see the Done bullet above. Refinement made while
  coding: 2.1 emits a *direct* absolute `movabs rax, shared_exit; jmp rax` at each
  exit rather than the indirect `jmp [slot]` of the final design. With no slots
  armed yet the two are behaviourally identical, and the direct form needs no
  per-trace slot table; 2.3 replaces it with the indirect `jmp [slot]` handoff
  (slot default = `shared_exit`) when link population arrives. The trampoline lives
  as a permanent, never-freed `McodeArena` slot (`ensureTrampoline`, emitted once);
  the test path (`compile`, `arena == null`) keeps the self-framed ABI, giving a
  built-in A/B of both ABIs over the same lowered trace.
- 2.2 `ChainResult` (P-B) + dispatcher `(final_trace_id,exit_instr)→PC` mapping,
  still no linking. Byte-identical.
- 2.3 Link-slot population from `driveChain` for `.link` first (simplest kind),
  then guard + loop-done (P-C/P-G). nsieve A/B + matrix.
- 2.4 P-F verification pass; replicate any counter proven live.

##### Peer-review corrections (gpt-5.6-sol, 2026-07-11) — fold in BEFORE coding

The review confirmed the pure-memory handoff premise (point A) is sound —
ordinary deopt flushes carried slots (`nativegen.zig:4051`), write-only slots
commit at each back-edge (`:3940`), invariant slots stay in `regs[]`, `.link`
snapshots every slot (`:3989`), and child entry reconstructs *all* homes incl.
hoisted array base pointers (`:3306`) and preheader/phi init (`:4008`). No
child-visible value survives only in a parent register/spill. **But three
showstoppers + several load-bearing fixes must land first:**

- **SHOWSTOPPER 1 — loop-done dual materialization.** A loop-done guard has two
  incompatible state contracts: ordinary deopt (do *not* commit the final
  iteration; resume at the header) vs. linked completion (commit post-guard stores
  + phi snapshot, enter continuation). Today the guard picks via
  `NativeResult.linked_loop_done` (`:4024,:4030,:4042`). Point 5's "snapshot stays
  before the tail" is WRONG: with the slot defaulting to `shared_exit`, the default
  path would commit the final iteration and return as an ordinary deopt → tier-0
  replays it → duplicated stores / mis-advanced for-state. **Fix:** the indirection
  must select *before* materialization — default slot → ordinary-deopt stub (no
  final-iteration snapshot); armed slot → an exit-specific linked-materialization
  stub that snapshots *then* jumps to the child. A slot pointing straight at the
  child cannot choose between the two contracts.
- **SHOWSTOPPER 2 — dangling code links (P-E is NOT deferrable to Increment 3).**
  `removeTrace`→`destroy` frees the child's arena slot to the reuse free-list
  (`trace.zig:1757,1761`→`622`→`nativegen.zig:294`); a later compile overwrites it
  (`:254`). A parent slot still pointing there is a code-use-after-free, and
  **widen-eviction makes this reachable in normal operation** (`interp.zig:2767`),
  not just shutdown. **Fix (required as soon as slots exist):** inbound-link
  ownership — backlinks reset before destroy, or link refcount blocking removal, or
  generation-checked indirection through a stable link object. "Dead code happens to
  stay readable" is insufficient under arena reuse.
- **SHOWSTOPPER 3 — child prologue-fail vs. cumulative counter.** Point 6 (cumulative
  `rbx` intact) contradicts point 5 (prologue-fail writes `completed=0`, `:4065`).
  After a productive parent→child jump where the child's entry guard fails, writing
  zero loses committed progress, triggers the zero-yield penalty path, and can spur
  bogus sibling retries. **Fix:** child prologue-fail must write cumulative progress
  + `final_trace_id=child` + a *distinct* reason (`prologue_fail`), never an
  overloaded `exit_instr=-1`. The dispatcher must treat "final child committed zero
  *locally*" and "chain committed nonzero *globally*" as two separate facts.
- **MUST-FIX — `completed` is not raw cumulative `rbx`.** Nested chaining rolls up as
  `linked_completed += 1` per inner run (one inner run = one enclosing iteration),
  NOT the sum of raw inner iterations (`trace.zig:1387,1391`). `completed` drives
  useful/low-yield classification, `hit_count`, penalty/gate (`:1132,1140,1145`),
  zero-guard counting (`interp.zig:2588`), and arming (`:2605`). So `ChainResult`
  needs *separate* fields: final-trace **local** commits, enclosing-chain progress,
  and the final exit reason/identity — cumulative `rbx` is at most diagnostic. (No
  dispatcher PC-advance is proportional to `completed`; resume PC is separate.)
- **MUST-FIX — all exit consumers need the FINAL trace, not just PC lookup.** The
  dispatcher indexes `ct.instrs[result.exit_instr]` in guard-failure lookup
  (`interp.zig:2595`), `maybeArmContinuation` (`:2616`), productive-branch counting
  (`:2626`), source-branch discrimination (`:2730`), and `onSideExit(ct,…)` (`:2607`).
  Feeding the entered *parent* with the child's exit index is OOB / misclassifies.
  Every one must switch to the final trace + its local count.
- **MUST-FIX — stable trace identity.** The only id today is the cache index from a
  `cache.items` scan (`trace.zig:1113`), and `removeTrace` uses `swapRemove`
  (`:1761`) so indices are reassigned. A baked-imm32 `final_trace_id` goes stale
  after any eviction. Add a never-reassigned runtime id to `Trace` + a lookup table,
  valid ≥ as long as any mcode link can reference it.
- **MUST-FIX — stack alignment.** At C entry `rsp%16==8`; 6 pushes keep `%16==8`;
  the callout helper assumes body `rsp%16==8` and subtracts 8 before `call`
  (`nativegen.zig:2981`). The shared frame reservation must be rounded to a multiple
  of 16 (not merely `SPILL_MAX*8`) and must include the callout-save region in the
  max (`:2273,2305`), else an odd `SPILL_MAX` breaks the SysV call alignment.
- **MUST-FIX — slot reachability + W^X.** `jmp qword [rip+disp32]` only reaches
  ±2 GiB; a heap side-table has no such guarantee, and slots embedded in an RX arena
  region can't take "plain data writes" without a RW toggle (`:215`). **Fix:** put
  slots in a separate *nearby RW page*, or load the slot address as a full imm64 and
  `jmp qword [rax]` (absolute — no rel32 constraint; `rax` is scratch post-flush).
  The target pointer itself may be anywhere (loaded as imm64); only code→slot
  addressing is constrained.
- **MUST-FIX — safepoint/observation blackout.** `driveChain` caps a burst at 8 hops
  (`trace.zig:1315`); an mcode continuation↔inner-root cycle removes that bound and
  can run an entire enclosing loop without returning, expanding the safepoint/GC/
  suspend/replay-line blackout (`interp.zig:1643,1668`) from one loop to an arbitrary
  nested computation. **Fix:** when `suspend_ctl`, replay-line recording, exec-log,
  or any observation hook is active, leave slots unarmed / reset to the dispatcher
  (no mcode poll in Increment 2).
- **Terminology:** `body_entry` = the child's guards/reloads/preheader, **not**
  `loop_top`.
- **Nits:** aligned 8-byte slot writes need no icache flush (single-thread, data);
  the trampoline need not save XMMs (caller-saved); `rdi/rsi/rdx` stay live through
  bodies because the callout restores them; CET/IBT would need landing pads at body
  entries only if ever built with enforcement (not a current constraint).

**P-F contract — DECIDED (Bart, 2026-07-11): replicate-but-inert.** Native
link-slots make tiering metadata (`hit_count`/penalty/gate, recording set) diverge
between native and tier-1a modes; it does not change stdout (the C5 contract already
permits different trace *sets* per mode) but it does make internal counters / trace
dumps mode-dependent. Rather than relax the contract *or* pay the accounting cost
always, the chain carries a **per-hop transition record that is gated by a config
flag** (parallel to `record_exec_log`): when the flag is on (the 10-mode matrix /
determinism goldens), `shared_exit` replays the per-hop accounting the dispatcher
would have done — attributed via `final_trace_id` — so tests assert byte-identical
tiering metadata across modes; when off (production `--jit-native`), the transition
record and replay are skipped entirely, so the mcode handoff stays cheap. "Test
equivalence while not paying the cost when not relevant."

### Increment 3 — Exit-branch patching + lifetime (P-E)

With co-location (rel32 always reaches) and frameless bodies (a mid-chain `jmp` is
legal), port `lj_asm_patchexit` (`lj_asm_x86.h:3127`): rewrite a guard's
`jcc`/tail-`jmp` rel32 in place to jump straight into a child body. Add unpatch-on-
retire (P-E, mirroring LuaJIT's RW window + the deliberate GC-exit skip at
`lj_asm_x86.h:3153`). Gate as Increment 2, plus the safe-point argument (P-EBP-4).

### Later — Register-level coherence (defer; measure first)

Only if Increment 2/3 component timings show the flush→memory→reload round-trip
still dominates: a canonical anchor→register assignment (siblings agree by
construction, child skips flush *and* reload) or a ported `asm_head_side`. Note
(peer review): canonical register assignment alone does not discharge the child's
*structural/identity* entry guards — those are separate from value placement and
must still be reconciled.

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
