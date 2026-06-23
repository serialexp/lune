# CURRENT TASK — cross-frame tracing, cluster Sub-lever 1 (callee via upvalue/global)

Governing intent (Bart): "that was a good flip for our interpreter level, but we
really need to get back to the native level." Approved plan:
`~/.claude/plans/clever-yawning-neumann.md`. Design doc:
`docs/design/10-cross-frame-tracing.md`.

Sub-lever 1 lets the recorder reach a callee through an UPVALUE or GLOBAL (not just
a local/param), so spectral-norm's inner loop (`a = a + x[j] * A(i,j)`, `A` an
upvalue) records a trace. Phased: **U0** = record on the tier-1a oracle (no speedup,
done) → **U1** = native `guard_func` lowering (the speedup; merges task #186).

## U1 — DONE, GREEN (uncommitted, pending Bart approval) — the speedup

Task #186. Native lowering of `guard_func` in `src/nativegen.zig`. A new
`Kind = .func` mirrors `.ptr` (invariant heap pointer, GP home, prologue-tag-checked
`TAG_HEAP`, loaded once, consumed ONLY by `guard_func`, never feeds
arithmetic/`aref`/flush → never reaches `exit_stores`, same C2 safety as `.ptr`).
`proveKinds` A marks a `guard_func`-covered `slot_load` (`func_guarded`); B
classifies it `.func` + validates each guard's operand. `analyzeInner` stashes the
recorded `Proto.id` (`guard_func.aux`) onto the slot and **bails on conflicting-aux
duplicate guards** (defensive — recorder never emits it). The identity check is
hoisted to the **prologue** (snapshot is loop-invariant): per `.func` slot,
`cmp [closure].type==function` → `mov proto,[closure+proto_off]` →
`cmp [proto].id==recorded` → `jne prologue_fail` (returns 0, regs untouched →
tier-0 re-runs the iter). Byte-identical in outcome to irinterp's `guard_func` arm.

- **Reviews:** Codex + Antigravity both cleared oracle-identity (every callee
  value), `.func` escape analysis, `rax`-scratch safety, `@offsetOf` correctness.
  Codex's one finding — two `guard_func`s on one snapshot with *different* ids would
  pass the single prologue check while the oracle exits on the second — is closed by
  the `analyzeInner` duplicate-aux bail (unreachable via the recorder, but the
  native subset must equal the oracle for any well-formed trace). The symmetric
  pre-existing `.ptr`/`guard_lane` first-match shape is noted in TODO.md (Rule #10),
  not touched (out of U1 scope).
- **Tests (nativegen.zig, green):** `guard_func passes when … matches the recorded
  proto.id` / `… side-exits … different proto.id` / `… side-exits … not a closure`
  (all `expectMatch` vs the oracle) + `two guard_funcs with conflicting ids …
  decline native` (`expectBail`).
- **Measure:** `just bench --filter spectral` → jit 51.1 ms vs tier-0 103.6 ms
  (~2×; the inner loop now runs native). Full sweep: all benches `cross=ok`; the
  lone `str_manip(ok/ERR)` flag is a **LuaJIT-side** ERR on a `bench/stdlib/` bench
  (lune `cross=ok`), independent of U1 and pre-existing.

## U0 — DONE, GREEN (uncommitted, pending Bart approval)

`just test` green: 8 modes byte-identical + replay. Phase 0 (leaf inlining) +
guard_fits-fix already landed as `0d7823d`, so the uncommitted diff is **pure U0**
— a clean single logical change (src/trace.zig, src/interp.zig + this doc/task
update). Codex + Antigravity reviewed; both cleared determinism/replay/OOB/abort/
leaks. Codex's one low-sev finding (u16 synthetic-slot counter could wrap for a
near-`u16`-max register window, folding into the live anchor window) is fixed with
a defensive abort in `recInputGet`.

### Mechanism (approach A — entry-snapshot input)

The executor has no `*Vm`/closure, so an upvalue/global value can only be read in
the dispatch loop. At record time the dispatch loop pre-resolves the loop-invariant
value and passes it to the recorder, which snapshots it into a synthetic slab slot
*above* the anchor window, emits `slot_load` + `guard_func`, and records an
`InputSeed`. The dispatch loop re-seeds those slots every entry and widens the
executor `RegWindow`. Sound because the cell is **stable** across the traced region
(re-resolved+re-guarded each entry; `set_upval`/`set_global` in the region abort).
`Proto.id` still suffices: the inlined callee reads no upvalues of its own.

### Code (all in the tree, uncommitted)
- **src/trace.zig** — `InputKind`/`InputSeed`; `Trace.inputs` (+ `destroy` free);
  recorder fields `input_seeds`/`input_dedup`/`next_input_slot` (+ `deinit`/`reset`);
  `MAX_TRACE_INPUTS=8`; `recordInstr`/`recordOne` gained `resolved: Value`;
  `.get_upval`/`.get_global` switch arms → `recInputGet` (dedup, synthetic slot,
  `slot_load`, `entry_slots` append, `InputSeed`, `guard_func` on functions);
  `assertWellFormed` slot bound widened to `anchor_num_registers + n_inputs`;
  entry_guard fingerprint capped to anchor slots; `commit` dupes `inputs`;
  `tryChainExit` skips input-carrying side traces.
- **src/interp.zig** — pre-resolve block at the `recordInstr` call site
  (`upvalGet`/`globals.get`); `seedTraceInputs` helper; trace-entry walk seeds inputs
  + widens `RegWindow` (`orelse continue` on `regCapacity` overflow).

### Tests (interp.zig, all green)
- `recorder: a callee reached through an upvalue records a snapshot input +
  guard_func` / `… through a global …` — one `InputSeed`, a `slot_load` on a slot
  ≥ anchor window, a `guard_func`.
- `recorder: a set_upval in the loop body aborts cleanly` / `… set_global …` —
  0 traces, anchor gated.
- `cross-frame: a callee reached through an upvalue inlines and stays
  byte-identical` / `… a global …` (60100) — 8-mode + replay.
- `cross-frame: a changed upvalue callee deopts the snapshot and replays
  byte-identically` (20300/20100) — per-entry re-resolve + `guard_func` side-exit
  when the captured upvalue is reassigned to a different-proto closure.

### Manual verification
- `./zig-out/bin/lune --dump-traces bench/luajit/spectral-norm.lua 100` →
  `guard_func` present (was 0); inner loop records a trace via the upvalue snapshot.
- spectral-norm byte-identical across tier-0 / `--trace` / `--jit-native` /
  `--trace-record-only` (1.274224116).
- No speedup expected yet: the trace carries `guard_func`, which native
  auto-declines until U1.

## Next steps
1. **Get Bart's commit approval for the U0+U1 diff** (no commit without it — Rule
   #15). Held together per Bart ("keep that uncommitted until we finish U1"). The
   diff spans src/trace.zig + src/interp.zig (U0), src/nativegen.zig (U1),
   docs/design/10-cross-frame-tracing.md, CURRENT_TASK.md, TODO.md. Suggested split
   or bundle:
   - **Bundle (recommended):** one commit `feat(jit): cross-frame tracing — inline a
     callee reached via upvalue/global and run it native (cluster sub-lever 1)`.
   - **Per-file split:** U0 commit (trace.zig+interp.zig) then U1 commit
     (nativegen.zig); docs/task files go with whichever lands last. Both are
     Rule-#13-clean (no partial-file staging needed — each file is wholly one phase).
2. Cluster lever continues (separate changes): method/`__index` dispatch (array3d,
   nbody), generic-for iterator inlining. See TODO.md + doc-10 Outstanding.

## Stray untracked files (NOT mine — leave alone)
`CURRENT_TASK_E3.md`, `SESSION_CHANGES.md`, `check_ordinals`,
`bench/results/*.tsv`.
