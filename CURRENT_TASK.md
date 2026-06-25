# CURRENT TASK — JIT hash-field (string-keyed) tracing, H0+H1

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

## H1 — DONE, GREEN (uncommitted, pending Bart approval)

Native lowering via **seed-based cell resolution (Approach B)** — H0 IR frozen, the
oracle keeps re-deriving the cell + emitting real `guard_hash` events.

### Mechanism

- **`src/trace.zig`** (H1-B1): `InputSeed.hash_cell{table_reg, key_const, slot}`;
  the recorder allocates a synthetic slab slot and stamps it into `href.aux`.
- **`src/interp.zig`** (H1-B2): `seedTraceInputs` resolves `cell =
  table.fieldPtr(consts[key_const])` each entry, validates metatable-free + present +
  `hash.count()==aux`, writes `@intFromPtr(cell)` into `payloads[slot]`. If any
  `hash_cell` fails to resolve/validate → entry runs **tier-1a** (oracle), not native
  → byte-identical (`completed=0`, tier-0 re-runs).
- **`src/nativegen.zig`** (H1-B3): `Kind.href` (invariant cell ptr, GP home, never in
  `exit_stores`); prologue loads `[rsi + aux*8]`; `guard_hash` → no-op (seed-gated);
  `hload` → tag-check `[cell+0]` vs guarded ty → `deopt_exit`, then payload `[cell+8]`;
  `hstore` → write tag+payload to `[cell]`. **Analyze-lane fix:** a hash-only `.ptr`
  slot has no `guard_lane` (array-only), so the lane is made optional (required only
  when an `aref` references the slot) and the prologue lane-check gated on `lane >= 0`.

### Tests (all green, 8-mode + replay)

- Field-RMW (`t.x=t.x+t.y`), field-get, float-field RMW, mid-loop type-change deopt,
  two-key distinct cells — byte-identical tier-0 ≡ oracle ≡ native + keyframe restore.
- **Sibling-grow (cell-dangle proof):** a table that grows between trace entries
  re-resolves the cell every entry and never dangles — `1000\t3000`.
- RMW double-apply is covered by the field-RMW 8-mode parity (native ≡ oracle).

### Measure

`bench/field_hash.lua` (`t.x = t.x + t.y` RMW): tier-0 **1534 ms** → native **22.3
ms** (**68.8×**), within **2.6×** of LuaJIT (8.5 ms). `perf record`: **99.9%** native
`[JIT]`, `Table.get/set` **0.0%** — the value-cell pointer is fully hoisted. The field
body compiles to 220 bytes of x86-64.

### Reviews — Codex + Antigravity (H1 native lowering)

- **Codex HIGH (determinism, the substantive finding — FIXED):** `hload` lowers
  to a **mid-body side-exit** (tag-check `[cell+0]` vs the guarded field type →
  `jcc(.ne, deopt_exit)`), but it was absent from the `last_body_guard` set in the
  win2 accumulator-home-coalescing pass (nativegen.zig ~1419). So a carried
  accumulator whose in-place update **preceded** a later `hload` could coalesce
  into its home register; if that `hload` then side-exited (field drifted
  int→float between entries), the deopt flush would commit the **already-bumped**
  accumulator — diverging from the tier-1a oracle, which side-exits at `hload`
  with the carried slot untouched. **Fix:** added `.hload` to the
  `last_body_guard` switch so any home update at index ≤ the last `hload` is
  blocked from coalescing (matches the documented invariant — the comment block
  enumerates the side-exiting ops, and `hload` is one). `guard_hash` stays out of
  the set (hoisted to the seed, never side-exits).
  **Regression test:** `nativegen win2(H1): an hload AFTER the accumulation blocks
  coalescing (cond 1)` — a trace with `add(acc,1)` at idx 6 preceding `hload` at
  idx 9 asserts `slotCoalesced(&t, 1) == false`. Verified load-bearing: reverting
  the one-token fix turns the test red, re-applying turns it green.
- **Antigravity:** independently cleared the rest of the H1 lowering as sound
  (seed cell re-resolution, `guard_hash` no-op gating, tag-check deopt, in-place
  `hstore`).

### Pending

Surface the review outcome + the fix to Bart, then request commit approval
(Rule #15 — no commit without explicit approval).

## Stdlib inventory

Untouched — H0 is a JIT recorder change, no stdlib function added/changed.
