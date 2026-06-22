# lune — cross-frame tracing (inline Lua calls into a trace) — Design

Status: partial — Phase 0 (recorder mechanism + leaf-call inlining on the tier-1a
oracle) landed & green; all 8 modes byte-identical + replay. Phases 1–3
outstanding. **Scope caveat below: the JIT-inert bench cluster does *not* move in
Phase 0** — its calls go through upvalue / method / generic-for-iterator / native
shapes that Phase 0 aborts by design.
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

### Outstanding

- [ ] **Phase 1 — native lowering of `guard_func`.** Admit it in
  `nativegen.proveKinds` A/B (single ref operand, no kind change — same shape as an
  entry guard), add `isTransient`/`operandReads` arms, and lower it: load the
  callee value, extract `asClosure().proto.id`, `cmp` to the recorded const, `jne`
  → the existing deopt stub. No prologue/ABI change. **This is the speedup** — but
  see the cluster caveat: it speeds up *leaf-call* traces, which the inert cluster
  does not currently produce.
- [ ] **Phase 2 — fixed multi-result broadening.** Generalise the `.ret` mapping to
  `produced`/`want` with nil-pad/truncate, fixed counts only; keep the dynamic
  multret abort. Tests for `want>1`, `produced<want`, `produced>want`, `want==0`.
- [ ] **Phase 3 — bounded down-recursion + real exit chaining.** Allow the same
  proto to inline while `inline_depth < cap` (deterministic counter bound, à la
  `recunroll`); enable `(proto.id, pc)` exit identity in `tryChainExit` so a deep
  side trace links. Verify the cap aborts the unbounded case cleanly.
- [ ] **Cluster lever (beyond this plan) — upvalue / method / iterator inlining.**
  The JIT-inert cluster (array3d, nbody, scalar, …) calls through shapes Phase 0
  aborts. Moving it needs in-callee upvalue reads, method (`__index`/field) call
  dispatch, and generic-for iterator inlining — each its own change. **Tripwire:**
  the day upvalue inlining lands, `guard_func` must tighten from `Proto.id` to the
  closure's `GcHeader.id` (two closures over one proto are no longer
  trace-identical once an upvalue is read).

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

### Why this is far simpler in lune than in LuaJIT

LuaJIT needs multi-frame snapshots (`snapshot_framelinks`) because a side-exit can
land mid-inlined-call and stay off-trace. **lune does not**, for two structural
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
- Upvalue / global / metatable / method / generic-for-iterator / table-construct
  inlining — each stays an abort (this is precisely why the inert cluster does not
  move in Phase 0; see the cluster caveat).
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
- [ ] **`Proto.id` → `GcHeader.id` tighten timing.** Safe while upvalue reads
  abort; must tighten the instant in-callee upvalue inlining lands (tracked as the
  cluster-lever tripwire above).

## References

- LuaJIT: `lj_record.c` (`lj_record_call`/`lj_record_ret`), `lj_snap.c`
  (`snapshot_framelinks` — the machinery lune avoids), `recunroll` (Phase 3
  recursion bound).
- `src/trace.zig` (`recCall`/`recReturn`, S1–S3, `assertWellFormed`),
  `src/irinterp.zig` (`.guard_func` arm), `src/tropt.zig` (`kindOf`),
  `docs/design/01`/`02`/`04`/`07`.
