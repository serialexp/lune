# CURRENT TASK — float codegen Gap B (RMW store-sinking, relaxing C1)

Governing arc: chase Lua compatibility so lune is usable, THEN optimize toward
LuaJIT parity (1× everywhere is the bar; determinism/replay must cost 0 perf).

## Gap A — COMMITTED (`b64fd01`)
Native f64 array-lane lowering (Phase D Gap A). Pure read reductions / fills over
float arrays now run native. See doc 05 §Phase D Gap A + TODO.md. Done & landed.

## Gap B — IMPLEMENTED (uncommitted, awaiting Bart's commit approval)

Relaxes the recorder's **C1 rule** so single-store read-modify-write float loops
(scimark SOR/LU) can record and run native. Design doc: `docs/design/07-rmw-store-sinking.md`.

### Mechanism (store-sinking)
The recorder used to abort (`.bad_type`) any trace with an `astore` after any `aload`,
because lune's coarse deopt re-runs a whole iteration from the loop header → a
store-after-read could double-apply. Now: instead of aborting, the recorder **defers
the single `astore`** and re-emits it in `commit()` **just before the `.loop`
terminator** — i.e. below every loop-exit guard (including `recForLoop`'s back-edge
`guard_true`). On any side-exit the sunk store has NOT executed inside the trace, so
tier-0 re-runs the side-exiting iteration from bytecode and applies the store exactly
once → idempotent. Closes both the data channel (RMW value) and control channel
(read-steered branch), since no read-derived decision sits below the store. SSA
guarantees the sunk store still addresses `v[x]` (the `aref` captured the pre-increment
key ref).

### Constraint (enforced)
Exactly one deferred store, and it must be the trace's **last** array access: a second
heap-observing op (`aload`/`astore`/`astore_append`) after the deferral aborts. Pure
constant fills (no aload, e.g. nsieve clearing) never defer → unaffected.

### Changes (all in `src/trace.zig`)
- `PendingStore` struct + `pending_store: ?PendingStore` field on `Recorder` (+ reset).
- In-bounds astore path: if the trace has a prior aload, stash into `pending_store`
  instead of emitting the `astore` (and instead of the old C1 abort).
- `recArrayGet` / `recArraySet`: abort if `pending_store != null` (B2 — store is last).
- `commit()`: flush the pending astore before the φ loop, then `.loop`.

### Tests (green)
- trace.zig recorder units: RMW store deferral (data channel) + read-steered const
  store (control channel) → both now continue recording with `pending_store` set;
  a subsequent get_index aborts.
- nativegen.zig unit: f64-lane RMW with the astore SUNK after the increment matches
  the tier-1a oracle bit-for-bit.
- interp.zig e2e: `t[i]=t[i]+1.0` RMW loop **byte-identical across all 8 determinism
  modes** (the load-bearing deopt-idempotence test). `--dump-native` confirms the
  `movsd [rax],xmm0` + presence `bts` land at the very bottom of the trace, below
  every guard, before the loop-back `jmp`.

### Measure (`just bench --filter scimark`, ReleaseFast, cross ok = 8-mode identical)
- scimark-sor: t0/lj 46.9× → **jit/lj 4.5×** (10.5× JIT speedup over tier-0)
- scimark-lu:  t0/lj 74.5× → **jit/lj 12.4×** (6×)
- scimark-fft (4 stores/iter) and scimark-sparse (indirect `x[col[k]]` gather) stay
  ~35–62× — out of scope (multi-store deferral / non-RMW gather are named follow-ons).

### Gate / docs
`just test` green; `just check-version` green. Docs lockstep done: doc 07 status →
implemented, doc 05 §C1 invariant + Gap A closing note, TODO.md Gap B section.

### Reviews
Design reviewed pre-implementation (Codex + Antigravity both sound). **Implementation
review: pending** (final Codex + Antigravity pass on the landed trace.zig change), then
Bart's commit approval (Rule #15 — do NOT commit without explicit instruction).

### Suggested commit (Preference #2 conventional commits)
`feat(jit): sink RMW array stores below loop-exit guards (Gap B, relax C1)`
Files: src/trace.zig, src/nativegen.zig, src/interp.zig,
docs/design/07-rmw-store-sinking.md, docs/design/05-native-codegen.md, TODO.md,
CURRENT_TASK.md.
Stray untracked files (CURRENT_TASK_E3.md, SESSION_CHANGES.md, check_ordinals,
bench/results/*.tsv) are NOT mine — leave them.

## Follow-ons (not Gap B)
- Multi-store deferral (FFT: 4 stores/iter) — sink an ordered set of last stores.
- Sparse gather (`x[col[k]]`) — indirect index, not a same-index RMW; different work.
- Native follow-up #4c (scalar carried-register home coalescing) — still open, distinct
  mechanism from array store-sinking.
