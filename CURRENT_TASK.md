# CURRENT TASK — JIT hash-field (string-keyed) tracing, H0

Governing intent (Bart): close the LuaJIT gap one named technique at a time. The
cross-frame cluster sub-lever (U0+U1) landed; the next highest-leverage recorder
gap is **string-keyed field access** (`obj.field`). Until now the recorder only
handled integer array keys — every `obj.field` get/set lowered to a string-keyed
`get_index`/`set_index` and aborted the trace. Approved plan:
`~/.claude/plans/clever-yawning-neumann.md`. Design doc:
`docs/design/11-hash-field-tracing.md`.

Phased: **H0** = recorder + tier-1a oracle (byte-identical across 8 modes + replay,
NO speedup, native auto-declines) → **H1** = native lowering (the speedup).

## H0 — DONE, GREEN (uncommitted, pending Bart approval)

`just test` green: 8 modes byte-identical + replay. Native auto-declines (any of
the four new ops → `proveKinds` returns false → tier-1a oracle runs the body).

### Mechanism

Four new `IrOp`s (appended at the END of the enum, wire-ordinal-stable):
`href`=41 (a=table, b=key-konst → cell descriptor, classified `.aref`), `hload`=42
(a=href → typed `Value` load, `.aload`), `hstore`=43 (a=href, b=value → in-place
overwrite, `.astore`), `guard_hash`=44 (a=href, aux=recorded `hash.count()` →
structural-stability guard, `.guard`). Total 45 ops.

- **`src/trace.zig`**: `get_index`/`set_index` dispatch branches on key type —
  `isInt()` → existing array path; heap **string** key → new `recHashGet`/
  `recHashSet`; else abort. Abort rules: non-table → `.bad_type`; metatable →
  `.has_metatable`; absent key (`fieldPtr == null`) → `.bad_type` (present-key
  only); nil store → `.bad_type`; non-konst key → `.bad_type` (const-key only);
  non-scalar field value → `.nyi_opcode` (int/float only). C1 store-sink reused:
  a store after any heap load defers into `pending_stores`, flushed below every
  guard before `.loop`.
- **`src/irinterp.zig`**: four oracle arms re-derive table+key from operands and
  do the real hash ops. `hload` is a **typed self-side-exiting load** — it
  tag-checks the loaded value against `ins.ty` (int/float) and side-exits BEFORE
  logging, so a field that drifted to a heap value never reaches the scalar-only
  exec log (review fix, see below).
- **`src/tropt.zig`**: classifies the four ops across every OpKind pass.
- **`src/nativegen.zig`**: one-line `proveKinds`-declines-if-present guard so H0
  never reaches native lowering.
- **`src/traceser.zig` + `viz/src/enums.ts`**: four op ordinals (no new const kind;
  the key is an existing heap-string const).
- **`src/table.zig`**: `fieldPtr(key)` → `hash.getPtr(normalizeKey(key))`.

### Reviews — Codex + Antigravity, both findings closed

- **Codex HIGH/MEDIUM (the substantive one):** the oracle `hload` arm logged its
  loaded `Value` via `rec.value` BEFORE the consumer `guard_int`/`guard_float`
  could reject it. A field that became non-scalar (heap) — via the trace's own
  `hstore` drifting, or external mutation that keeps `hash.count()` unchanged so
  `guard_hash` still passes — would leak a heap `Value` into the scalar-only exec
  log → latent `UnsupportedEffectResult` on serialization (snapshot/replay).
  Additionally the store value `rval` carried no strict type guard.
  **Fixes applied & verified green:** (1) made oracle `hload` a typed
  self-side-exiting load (tag-check vs `ins.ty`, side-exit before `rec.value` on
  mismatch — mirrors the planned H1 native tag-check); (2) added
  `guardNum(rval, vval)` in `recHashSet` to pin the store value's type inline
  (analogue of the array path's `guard_fits`).
- **Codex dedup sub-concern (resolved as non-issue):** worried `guardNum`'s
  ref-only dedup could let a `guard_true` skip a numeric guard. Verified (and
  Antigravity independently observed) that `recBranch` emits `guard_true`/
  `guard_false` RAW via `self.emit` (not registered in `guarded_refs`), so
  `guarded_refs` holds ONLY numeric type guards → `guardNum` dedup on the store
  value is sound.

### Tests (all green)

- **Recorder units (interp.zig, via `runForTrace`+`dumpTrace`):** const-key read
  records `href`+`guard_hash`+`hload`+`guard_int` (no `hstore`); int RMW sinks
  `hstore` below `hload` (asserts `indexOf(hload) < indexOf(hstore)`); float field
  RMW records `guard_float`; absent-key aborts; metatable aborts; heap/string-value
  aborts; computed/non-konst key aborts.
- **8-mode `expectProgram` (interp.zig):** const-key read, int RMW, float RMW,
  two-key distinct cells, mid-loop type-change deopt — all byte-identical across
  {stress × {off, record-only, no-opt, record-execute, native}} + keyframe restore.

### Manual end-to-end verification (rebuilt CLI)

- `/tmp/h_deopt.lua` (mid-loop field type change) → `0.5` tier-0 == native ==
  record-only.
- `/tmp/h_rmw.lua` (`t.n = t.n + 1` ×200) → `200` tier-0 == native;
  `--dump-traces` shows `href`/`guard_hash`/`hload`/`hstore` with `hload` (%005)
  before the sunk `hstore` (%021).

## H1 — NOT STARTED (the speedup)

Native lowering: prologue `hresolve(table, key)` hoist stashing
`{cell_ptr, size, metadata}` into new homes; `(size, metadata)` sentinel
`guard_hash`; typed `hload`/`hstore` lowering with tag-check; new `Kind.href`;
deopt-replay tests (type-change side-exit, sibling-table grow doesn't dangle, RMW
double-apply); measure via field micro-bench + `perf record`.

## Stdlib inventory

Untouched — H0 is a JIT recorder change, no stdlib function added/changed.
