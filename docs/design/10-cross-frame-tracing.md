# mahina — cross-frame tracing (inline Lua calls into a trace) — Design

Status: partial — Phase 0 (leaf-call inlining) + cluster Sub-lever 1 **U0**
(callee-via-upvalue/global recording) + **U1** (native `guard_func` lowering — the
speedup) landed & green; all 8 modes byte-identical + replay. **spectral-norm's
inner loop now runs native (~2×: jit 51 ms vs tier-0 104 ms).** Phases 2–3 and the
method/iterator cluster levers outstanding.
Owner: Bart
Last updated: 2026-06-23

Prerequisite reading: `00-architecture.md` (the tier model and the single-window
execution invariant), `01-trace-lifecycle.md` (record → optimize → execute →
deopt), `02-determinism.md` + `04-snapshot-replay-schema.md` (why `guard_func`
keys on the stable `Proto.id`, never a raw pointer), and `07-rmw-store-sinking.md`
(the store-sink discipline that makes deopt-replay idempotent).

## Implementation status

Tracking the gap between this design and what's on the main branch. Tick items as
they land; move whole sections to "done" once everything inside them is checked.

### Done

- [x] **Phase 0 — recorder frame stack + `guard_func` + non-recursive
  fixed-result leaf inlining (tier-1a).** New IR op `guard_func` (ordinal 40, last
  member of `IrOp`; mirrored in `viz/src/enums.ts` and pinned by the traceser
  wire-ordinal test). Recorder (`src/trace.zig`) grew `anchor_num_registers`,
  `base_off`, a `frames` stack, and `inline_depth`; `reset` sizes `reg_map` to
  `num_registers + MAX_INLINE_DEPTH(3) × MAX_CALLEE_REGS(256)`. The `.call` arm
  (`recCall`) inlines a fixed-arity, non-vararg, non-native, non-`__call` Lua
  closure: emits `guard_func` keyed on `Proto.id`, S1-seeds every callee slot,
  pushes a frame. The `.ret` arm (`recReturn`) maps the fixed result window back
  to the caller's `ret_dest..` and pops. Tier-1a oracle (`src/irinterp.zig`) has
  the `.guard_func` arm (proto-id check → side-exit). `src/tropt.zig` classifies
  it `.guard`; `src/troptdiag.zig` lists it in the a-only operand groups. Native
  auto-declines (`proveKinds` Pass B `else => return false`) and the
  native-unsupported safety net retires such traces to tier-0 — no native risk.
- [x] **S1 — pre-seed every callee slot.** At the inlining `.call`, each callee
  register is seeded `.def` (param slots → the caller arg's SSA ref; the rest →
  `konst(nil)`), so `refOf` never emits a `slot_load` on a callee index. Unit test
  `recorder S1: …` asserts no `slot_load` reads ≥ the anchor window.
- [x] **S2 — cap φ writeback to outer slots.** `commit()`'s φ loop drops any slot
  `≥ anchor_num_registers` (callee slots are dead at the loop boundary). Unit test
  `recorder S2: …` asserts no φ names a callee index.
- [x] **S3 — verifier bound pinned to the anchor window.** `assertWellFormed` is
  called with `anchor_num_registers`, not the grown `reg_map.len`. Unit test
  `recorder S3: …` confirms the reserved scratch genuinely extends past the bound,
  so pinning to the narrow window is load-bearing rather than vacuous.
- [x] **Depth + capacity guards.** New `AbortReason.too_deep`; `.call` aborts
  beyond `MAX_INLINE_DEPTH` and when `base_off + callee.num_registers` would
  overflow `reg_map`. The anchor-frame `.ret`/`.halt` still abort `.cross_frame`.
  *(2026-08-28: the single tag was split so abort tables name which limit fired —
  `.too_deep` now means only the `MAX_INLINE_DEPTH` case; the `reg_map` overflow
  is `.frame_bounds`, and the synthetic-input budget is `.input_cap`.)*
- [x] **Clean aborts on out-of-scope shapes (confirmed at depth).** Native callee
  → `host_barrier`; `__call`/metamethod, vararg callee, dynamic multret
  (`all_results`), and same-proto recursion → `cross_frame`/`too_deep`. Tests:
  `recorder: a vararg call … still aborts cleanly`; recursion (`fib`) records 0
  traces without crashing.
- [x] **8-mode determinism corpus.** `cross-frame: a fixed-arity leaf call inlines
  and stays byte-identical` (single leaf, `x*x+1`) and `cross-frame: a two-deep
  call chain …` (genuine depth-2 via a function passed as a *parameter*, verified
  by two `guard_func` ops in `--dump-traces`) — both byte-identical across
  {stress×{off,record-only,no-opt,record-execute,native}} and keyframe restore.
- [x] **Cluster Sub-lever 1 — U0: record a callee reached via UPVALUE / GLOBAL
  (tier-1a, no speedup).** The recorder's `recordOne` switch grew `.get_upval` and
  `.get_global` arms (`recInputGet`). A callee reached through a loop-invariant
  upvalue/global is a value the executor cannot read (no `*Vm`, no closure), so the
  recorder snapshots it: it allocates a synthetic input slot *above* the anchor
  window (counter from `anchor_num_registers`, deduped per source), emits a
  `slot_load` on that slot + (when the value is a function) a `guard_func`, and
  records one `InputSeed { kind, source, slot }` on the `Trace`. The dispatch loop
  (`src/interp.zig`) pre-resolves the value at record time (`upvalGet` / `globals.get`,
  passed as `recordInstr(… , resolved)`) and re-seeds the slab slot every entry via
  `seedTraceInputs`, widening the executor `RegWindow` to `num_registers + n_inputs`
  (declining the entry if it would overflow `regCapacity`). `set_upval`/`set_global`
  stay out of the switch → abort (the snapshot is only sound while the cell is
  stable). `assertWellFormed`'s slot bound is widened to
  `anchor_num_registers + n_inputs` for `slot_load` while φ stays pinned to the
  anchor window. `tryChainExit` skips input-carrying side traces (no `*Vm` to seed
  there). No new IR op; native still auto-declines (`guard_func`). Tests: `recorder:
  a callee reached through an upvalue …` / `… a global …` (assert one `InputSeed`, a
  `slot_load` on its slot ≥ anchor window, a `guard_func`); `recorder: a set_upval/
  set_global in the loop body aborts cleanly` (0 traces, gated); 8-mode `cross-frame:
  a callee reached through an upvalue / a global inlines …` (60100) + `… a changed
  upvalue callee deopts the snapshot and replays byte-identically` (per-entry
  re-resolve + `guard_func` side-exit on a proto-Y closure).

- [x] **Phase 1 / Sub-lever 1 U1 — native lowering of `guard_func` (the speedup).**
  A new `Kind = .func` (in `nativegen.zig`) mirrors `.ptr`: an invariant heap
  pointer, GP home, prologue tag-checked `TAG_HEAP`, loaded once, consumed **only**
  by `guard_func`, never feeding arithmetic/`aref`/a flush, so it never reaches
  `exit_stores`/`flushSlot` (same C2 safety as `.ptr`). `proveKinds` Pass A marks a
  `slot_load` covered by a `guard_func` as `func_guarded`; Pass B classifies it
  `.func` and validates each `guard_func`'s operand kind (`→ .none`).
  `analyzeInner` stashes the recorded `Proto.id` (`guard_func.aux`) onto the slot —
  and **bails if two `guard_func`s cover one snapshot with conflicting ids** (a
  shape the recorder never emits — dedup gives one synthetic slot → one resolved
  closure → one id — but the prologue can hoist only one check while the oracle
  re-checks each, so a malformed trace must decline native rather than diverge).
  The check is hoisted to the **prologue** (the snapshot is loop-invariant —
  re-resolved + re-seeded each entry; a `set_upval`/`set_global` in the region
  aborts recording): for each `.func` slot, `cmp [closure].type == function`;
  `mov proto, [closure+proto_off]`; `cmp [proto].id == recorded`; `jne
  prologue_fail` (returns 0, regs untouched → tier-0 re-runs the iteration). The
  sequence is byte-identical in outcome to irinterp's `guard_func` arm
  (`isHeap() ∧ heapType()==function ∧ proto.id==aux`). The body lowers `guard_func`
  to nothing (it joins the hoisted no-ops with `slot_load`/`guard_int`/…). Offsets
  are `@offsetOf` (layout-drift-proof). Same op for both the leaf-call corpus and
  the U0 upvalue/global cluster traces. Reviewed by Codex + Antigravity (cleared
  oracle-identity for every callee value, `.func` escape analysis, `rax`-scratch
  safety, offset correctness; the conflicting-aux divergence Codex flagged is now
  the defensive bail above). Tests: `nativegen: guard_func passes / side-exits on
  different proto.id / side-exits on a non-closure` (`expectMatch` vs the oracle) +
  `nativegen: two guard_funcs with conflicting ids … decline native` (`expectBail`).
  spectral-norm's inner loop runs native (task #186).

### Outstanding

- [ ] **Phase 2 — fixed multi-result broadening.** Generalise the `.ret` mapping to
  `produced`/`want` with nil-pad/truncate, fixed counts only; keep the dynamic
  multret abort. Tests for `want>1`, `produced<want`, `produced>want`, `want==0`.
- [ ] **Phase 3 — bounded down-recursion + real exit chaining.** Allow the same
  proto to inline while `inline_depth < cap` (deterministic counter bound, à la
  `recunroll`); enable `(proto.id, pc)` exit identity in `tryChainExit` so a deep
  side trace links. Verify the cap aborts the unbounded case cleanly.
- [ ] **Cluster lever (beyond this plan) — method / iterator inlining.** Sub-lever 1
  (callee reached via upvalue/global) is done at U0; the remaining JIT-inert shapes
  (array3d, nbody, …) call through *methods* (`__index`/field) and *generic-for
  iterators*, each its own change. (Plain constant-key field access `obj.field` on a
  metatable-free table now records via the hash-field path — see
  `11-hash-field-tracing.md`, H0 landed; `__index`-dispatched method calls remain a
  separate lever.) **Tripwire (still open):** U0 reaches the callee
  *through* an upvalue but the inlined callee reads no upvalues of its *own*, so
  `Proto.id` is still a sound `guard_func` key (any closure of that proto is
  interchangeable). The day we inline a callee whose *own body* executes
  `get_upval`, `guard_func` must tighten from `Proto.id` to the closure's
  `GcHeader.id` (two closures over one proto are no longer trace-identical once the
  body reads an upvalue).

## Why this exists

The JIT-inert bench cluster (array3d ~119× vs LuaJIT, spectral-norm, nbody,
scalar, recursive-fib, nsieve-bit-fp) records traces poorly or not at all and runs
on the tier-0 interpreter, so `--jit` is wall-clock-identical to no JIT. Every hot
loop in that cluster has a Lua **call** in its body; the recorder aborted on any
`.call`/`.ret`/`.halt` with `AbortReason.cross_frame`. Cross-frame tracing —
inlining the called body straight into the trace (LuaJIT's
`lj_record_call`/`lj_record_ret`) — is the *coverage* lever the nsieve verdict in
`CLAUDE.md` predicted: making already-traced code faster cannot touch a loop that
never tiers up.

### Why this is far simpler in mahina than in LuaJIT

LuaJIT needs multi-frame snapshots (`snapshot_framelinks`) because a side-exit can
land mid-inlined-call and stay off-trace. **mahina does not**, for two structural
reasons:

1. **The recorder already follows tier-0 across the frame boundary.**
   `recordInstr` runs from the single dispatch loop for every executed instruction
   regardless of frame depth. After a `.call` pushes the callee frame, tier-0 keeps
   dispatching the callee's bytecode and the recorder keeps seeing it — it just
   aborted. Driving the recorder through a call needed no new machinery; we only
   stopped aborting.
2. **Deopt = replay the whole iteration from the anchor header in the *outer*
   frame.** A side-exit runs no φ, leaves the outer registers untouched, and tier-0
   re-runs the iteration from the loop header — *including the real `.call`*, which
   reconstructs the callee frame for free. No multi-frame snapshot, no new exit
   machinery; the store-sink discipline already makes the replay idempotent.

The consequence — the **load-bearing invariant** of the whole design — is that
**callee local slots are pure internal SSA temporaries.** They are
defined-before-use inside the inlined body, are never a trace input (no
`slot_load`), and are never loop-carried (the call returns before the outer loop
closes). Trace *execution* still runs against a single `RegWindow` (the outer
frame); callee slots are SSA values that never touch real register storage. The
S1–S3 rails are what *enforce* this rather than assume it.

## Goals

- Record (Phase 0) then natively run (Phase 1) a hot loop whose body calls a
  fixed-arity, non-recursive, non-vararg Lua leaf reached as a plain register value
  (local or parameter), with **byte-identical** output across all 8 modes + replay.
- Keep the single-window execution model and the deopt-replay-from-header model
  untouched. `guard_func` fails **closed** (deopt) on any identity mismatch.

## Non-goals (v1 / out of scope)

- Multi-frame side-exit snapshots / off-trace mid-call exits — the
  replay-from-header model makes them unnecessary.
- Metatable / method / generic-for-iterator / table-construct inlining — each stays
  an abort (Phase 0). **Updated:** reaching a callee through an upvalue/global is now
  in scope via Sub-lever 1 (U0 records it; U1 lowers it native). A callee whose *own
  body* reads upvalues, and method/iterator dispatch, remain out of scope.
- Native callees — they cross the embedding boundary (`host_barrier`), correctly
  never inlined.
- Native-codegen *quality* (the residual vs LuaJIT on already-traced loops).

## The `guard_func` op + the S1–S3 safety rails

`guard_func`: operand `a` = SSA ref of the callee value at the `.call` slot; `aux`
= `@bitCast(Proto.id)` (a stable `u32`, **not** a pointer — a keyframe restore
brings the proto back at a new address with the same preserved id, so a pointer
compare would spuriously miss after restore and diverge the 8-mode matrix). The
op side-exits unless the runtime callee is a heap function whose
`Closure.proto.id` equals the recorded const.

The "callee slots are pure internal SSA" claim is true *only if* three invariants
hold; each is a silent out-of-bounds slab access if violated (the executor indexes
`RegWindow` with unchecked raw pointers), so each is a checked mechanism:

- **S1 — pre-seed every callee slot** so `refOf` never emits a callee-index
  `slot_load` (an OOB trace input reading uninitialised slab).
- **S2 — cap φ writeback** to `[0, anchor_num_registers)` so the `.loop` flush
  never writes OOB past the executor's single window.
- **S3 — pin the verifier bound** to `anchor_num_registers`, not the grown
  `reg_map.len`, so `assertWellFormed` actually catches an OOB callee `aux`.

## Cluster Sub-lever 1 — reach a callee through an UPVALUE / GLOBAL

Phase 0 inlines a callee reached as a plain register value (local/param). The
JIT-inert cluster does not produce those: **spectral-norm**'s inner loop
`a = a + x[j] * A(i,j)` reaches `A` through an *upvalue*, so Phase 0 aborted on the
`get_upval`. Sub-lever 1 admits that shape (and the loop-invariant *global* analogue
`function f() … end; for i do f(i) end`).

**The hard constraint.** The trace executor has **no `*Vm` and no closure** (tier-1a
is `execute(t, regs, values)`; the native ABI is just `(tags, payloads)` of the
`RegWindow`). An upvalue/global value can therefore only be obtained in the
**dispatch loop** (`src/interp.zig`), which owns the Vm and the frame's `closure`.

**Approach A — entry-snapshot input (chosen).** The callee upvalue/global is
*loop-invariant*, so resolve it **once per entry**, snapshot it into a dead slab
slot *above* the frame window, guard it, and let the executor read it as an ordinary
`slot_load`. **No new IR op** — reuse `slot_load` + `guard_func`. Mechanically:

- **Record time** (`recInputGet` in `src/trace.zig`): the dispatch loop pre-resolves
  the live value (`upvalGet(closure.upvalues[b])` / `globals.get(proto.constants[b])`)
  and passes it to `recordInstr(… , resolved)` — it must come from the closure/globals
  because `recordInstr` runs *before* tier-0 executes the `get_upval`, so `regs.get(dest)`
  is not yet populated. The recorder allocates a synthetic slot from a counter
  starting at `anchor_num_registers` (deduped per `(kind, source)`), emits
  `slot_load aux=slot`, appends the slot to `entry_slots`, records one
  `InputSeed { kind, source, slot }`, and — when the resolved value is a function —
  emits `guard_func a=<that ref>, aux=@bitCast(proto.id)`. Restricted to the anchor
  frame (`inline_depth != 0` → abort): the dispatch loop only has the anchor frame's
  closure/proto at entry.
- **Entry time** (`seedTraceInputs` in `src/interp.zig`): before running the trace,
  re-resolve each `InputSeed` and write it into its slab slot, then build the
  executor `RegWindow` as `frameWindow(base, num_registers + n_inputs)` — declining
  the entry (run tier-0) if `base + count` would exceed `regCapacity`. The
  `[base+num_registers, …)` region holds no live child frame at a normal loop
  back-edge entry, so the synthetic slots are dead scratch.

**Correctness condition: value stability, not openness.** The snapshot is
re-resolved and re-guarded **every entry** (a cross-entry change → `guard_func`
deopt), and within one trace run nothing writes the cell (the callee body is pure
SSA; `set_upval`/`set_global` in the traced region **abort** — they are not in the
record switch). Open upvalues are therefore fine: we never need to *write* the cell
through the trace, only read a stable snapshot of it.

**`Proto.id` still suffices here.** We reach the callee *through* an upvalue, but the
inlined callee `A` reads no upvalues of *its own*, so any closure of that proto is
interchangeable and `Proto.id` is the right `guard_func` key. (The
`Proto.id → GcHeader.id` tighten in the cluster-lever tripwire fires only when we
later inline a callee whose *own body* executes `get_upval` — not here.)

Why not the alternatives: extending the native ABI to pass the closure + a real
`upval_load` op (B) cannot resolve *open* upvalues in the executor (needs
`vm.regGet`) and breaks the 2-arg ABI; baking the resolved closure pointer as a
konst (C) breaks keyframe-restore/replay (pointers move; ids are preserved — the
exact reason `guard_func` keys on `Proto.id`).

**Verifier & chaining adjustments.** `assertWellFormed`'s `slot_load` bound widens
to `[0, anchor_num_registers + n_inputs)` — the deliberate, guarded counterpart to
S3 — while φ stays pinned to `[0, anchor_num_registers)` (inputs are read-only, never
loop-carried). `tryChainExit` skips input-carrying side traces: the chain path has
no `*Vm` to seed the inputs, so such a trace must enter only through the dispatch
loop. The `InputSeed` table is runtime-only (not serialized; precedent:
`entry_guards`).

## Phasing

See the implementation-status checklist above for the authoritative per-phase
state. In brief: Phase 0 = recorder mechanism + leaf inlining on the oracle (done);
Phase 1 = native lowering (the speedup); Phase 2 = fixed multret; Phase 3 =
bounded recursion + exit chaining.

## Open questions for review

- [ ] **Does Phase 1 earn its keep before the cluster lever?** Phase 0 confirms the
  inert cluster does not produce leaf-call traces (its calls are upvalue / method /
  iterator / native). Phase 1 natively lowers *leaf-call* traces, so it speeds up
  programs shaped like the determinism corpus, not array3d/nbody/scalar. Whether to
  do Phase 1 next or jump to the upvalue/method/iterator cluster lever is a
  prioritisation call for Bart.
- [ ] **`Proto.id` → `GcHeader.id` tighten timing.** Still safe after Sub-lever 1:
  U0 reaches the callee *through* an upvalue but the inlined callee reads no upvalues
  of its *own*, so `Proto.id` remains a sound key. Must tighten the instant we inline
  a callee whose own body executes `get_upval` (tracked as the cluster-lever tripwire
  above).

## References

- LuaJIT: `lj_record.c` (`lj_record_call`/`lj_record_ret`), `lj_snap.c`
  (`snapshot_framelinks` — the machinery mahina avoids), `recunroll` (Phase 3
  recursion bound).
- `src/trace.zig` (`recCall`/`recReturn`, S1–S3, `assertWellFormed`; Sub-lever 1:
  `recInputGet`, `InputSeed`, `Trace.inputs`), `src/interp.zig` (Sub-lever 1:
  `seedTraceInputs`, the pre-resolve at the `recordInstr` call site, the widened
  `RegWindow` at trace entry), `src/irinterp.zig` (`.guard_func` arm),
  `src/tropt.zig` (`kindOf`), `docs/design/01`/`02`/`04`/`07`.
