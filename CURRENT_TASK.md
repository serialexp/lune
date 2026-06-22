# CURRENT TASK — cross-frame tracing (inline Lua calls into a trace)

Governing intent (Bart): "that was a good flip for our interpreter level, but we
really need to get back to the native level." Approved plan:
`~/.claude/plans/clever-yawning-neumann.md`. Design doc:
`docs/design/10-cross-frame-tracing.md`.

Goal: stop the recorder aborting on `.call`/`.ret` so hot loops with a Lua call in
their body record a trace (LuaJIT `lj_record_call`/`lj_record_ret`), inlining the
callee body into the trace. Phased: Phase 0 = recorder mechanism + leaf inlining on
the tier-1a oracle; Phase 1 = native lowering (the speedup); Phase 2 = fixed
multret; Phase 3 = bounded recursion + exit chaining.

## Phase 0 — DONE, GREEN (uncommitted, pending review + Bart approval)

`just test` green: 8 modes byte-identical + replay.

### Code (all in the tree)
- **src/trace.zig** — `guard_func` IR op (ordinal 40, last); `AbortReason.too_deep`;
  `MAX_INLINE_DEPTH=3`, `MAX_CALLEE_REGS=256`, `InlineFrame`; recorder fields
  `anchor_num_registers`/`base_off`/`frames`/`inline_depth`; `reset` sizes `reg_map`
  to `num_registers + MAX_INLINE_DEPTH*MAX_CALLEE_REGS`; `recCall` (inline a
  fixed-arity non-vararg non-native Lua leaf: emit `guard_func` keyed on
  `Proto.id`, S1-seed callee slots, push frame) + `recReturn` (map fixed result
  window to `ret_dest..`, pop); S2 φ-cap in `commit()`; S3 `assertWellFormed` bound
  = `anchor_num_registers`.
- **src/irinterp.zig** — `.guard_func` oracle arm (proto-id check → side-exit).
- **src/tropt.zig** — `kindOf` `.guard_func => .guard`.
- **src/troptdiag.zig** — `.guard_func` in the two a-only operand groups.
- **src/traceser.zig** + **viz/src/enums.ts** — ordinal 40 pinned + mirrored,
  field-count bumped to 41.

### Tests (interp.zig, all green)
- `recorder S1/S2/S3: …` — the three OOB rails as committed-trace property checks.
- `recorder: a non-recursive fixed-arity leaf call is inlined into one trace` —
  cache==1, gate==0, !recording.
- `recorder: a vararg call … still aborts cleanly` — cache==0, gated.
- `cross-frame: a fixed-arity leaf call …` + `… a two-deep call chain …` — 8-mode
  + replay byte-identical (depth-2 via a function passed as a parameter, verified
  by two `guard_func` ops in `--dump-traces`).

## IMPORTANT FINDING — the inert *cluster* does NOT move in Phase 0

The plan's Phase-0 expectation "array3d / nbody / spectral-norm / scalar now record
a trace" is **over-optimistic**. Measured (`--dump-traces`, debug):
- **array3d** → 0 traces. Hot loop is `for x,y,z in arr:points() do arr:set(...)`:
  a generic-for over a closure iterator calling a **method**. Both out of scope.
- **nbody** → 0 traces. Method/upvalue calls. Out of scope.
- **scalar** → 0 traces. Calls **native** `type`/`tostring`/`tonumber`/`select`/
  `rawget` → `host_barrier` (correctly never inlined).
- **spectral-norm** → 1 trace, but **0 `guard_func`** — a plain inner numeric loop,
  not via inlining.

Only pure local/param-leaf-call loops inline in Phase 0. The cluster needs
**upvalue / method / generic-for-iterator** inlining (the "cluster lever" in the
design doc, beyond this plan's Phase 1). **Consequence for prioritisation:** Phase
1 (native lowering of leaf inlining) speeds up corpus-shaped programs, *not* the
inert cluster. Whether to do Phase 1 next or pivot to the cluster lever is Bart's
call (open question in the design doc).

## Next steps
1. Codex + Antigravity review of the Phase 0 recorder change (determinism of
   `guard_func`-on-`Proto.id`, the S1–S3 OOB rails).
2. Surface the cluster finding to Bart; get the prioritisation decision + commit
   approval (no commit without it — Rule #15 + plan).

## Stray untracked files (NOT mine — leave alone)
`CURRENT_TASK_E3.md`, `SESSION_CHANGES.md`, `check_ordinals`,
`bench/results/*.tsv`.
