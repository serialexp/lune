# lune — tracing string-keyed (hash-part) table field get/set

Status: **complete** — H0 (recorder + tier-1a oracle) and H1 (native lowering, the
speedup) both landed 2026-06-23, green under `zig build test` and byte-identical
across all 8 determinism modes + keyframe replay. The field micro-bench runs **99.9%
on native [JIT]** (perf-confirmed, `Table.get/set` 0.0%), a **68.8× speedup** over
tier-0 (1534 ms → 22.3 ms), within **2.6× of LuaJIT** (8.5 ms). Computed-key /
absent-key inserts remain deferred follow-ons (see Outstanding).
Owner: Bart
Last updated: 2026-06-23

Prerequisite reading: `01-trace-lifecycle.md` §"Loop-header re-entry deopt" (the
deopt model the store-sink rests on), `05-native-codegen.md` §Phase B (the C1/C2
invariants), `07-rmw-store-sinking.md` and `08-multi-store-sinking.md` (the
store-sink discipline this reuses verbatim), and `02-determinism.md` (why an
invariant pointer is never serialized). This doc covers tracing `obj.field` — table
access through a **constant string key**, i.e. the hash part — which until now
aborted every trace.

## Implementation status

Tracking the gap between this design and what's on the main branch. Tick items as
they land; move whole sections to "done" once everything inside them is checked.

### Done

- [x] **H0 recorder — `recHashGet`/`recHashSet` (`trace.zig`).** Key-type branch in
  the `get_index`/`set_index` dispatch routes interned-string keys to the hash path;
  the helpers emit `guard_table → href → guard_hash → hload`/`hstore` with the
  present-key, const-key, scalar-field, metatable, and C1 store-sink abort rules.
- [x] **H0 four `IrOp`s — `href`/`hload`/`hstore`/`guard_hash`.** Appended at the end
  of the enum (wire ordinals 41–44, total 45) so existing ordinals are unperturbed;
  `assertWellFormed` widened for their operand shapes.
- [x] **H0 tier-1a oracle (`irinterp.zig`).** Four arms re-derive table+key from the
  operands and run the real hash ops (`href` → nil token; `hload` → `Table.get`;
  `hstore` → in-place `fieldPtr(key).* = v`; `guard_hash` → metatable∧present∧count
  side-exit).
- [x] **H0 optimizer classification (`tropt.zig`, `troptdiag.zig`).** `href` is
  addressing (`.aref`), `hload` value-producing (`.aload`), `hstore` an effect
  (`.astore`), `guard_hash` a `.guard`; uses-counting and consumer-set passes updated.
- [x] **H0 native auto-decline (`nativegen.zig`).** `proveKinds`' existing
  `else => return false` declines any trace carrying the four ops → tier-1a. No new
  code; confirmed by the 8-mode `expectProgram` native mode running the oracle.
- [x] **H0 wire ordinals (`traceser.zig` + `viz/src/enums.ts`).** Ordinals 41–44
  pinned by the contract test; the viz tables mirror them by position.
- [x] **H0 tests.** Recorder units (`interp.zig`): read records
  `href`+`guard_hash`+`hload`+type guard; RMW sinks the `hstore` below the load;
  float field records; absent-key / metatable / heap-value / computed-key all abort
  with no trace. 8-mode `expectProgram`: field-read, int RMW, float RMW, two-key, and
  a mid-loop type-change deopt — all byte-identical + keyframe restore.
- [x] **H1 — native lowering (THE speedup), seed-based (Approach B).** The
  loop-invariant cell pointer is resolved **in the dispatch loop** (`seedTraceInputs`,
  Zig — which has the `*Vm`/table) at *every* entry and stashed into a synthetic slab
  slot, exactly mirroring U0's upvalue/global `InputSeed`. Native reads it as an
  invariant `Kind.href` home — no native→Zig call, no inline hash probe. Specifics:
  - **H0 IR frozen.** `href` stays `(a=table, b=key)`; the tier-1a oracle keeps
    re-deriving the cell via `fieldPtr` per iteration and emitting real `guard_hash`
    exec-log events. This is mandatory: replay compares exec logs, so `guard_hash`
    cannot be subsumed into the seed (a decline-at-seed would drop the i0 guard event
    and diverge the log from the non-native modes). `href.aux` (unused by the oracle)
    carries the native synthetic slot index.
  - **Seed-only `InputSeed.hash_cell`** (`{table_reg, key_const, slot}`):
    `seedTraceInputs` resolves `table = regGet(base+table_reg)`,
    `cell = table.fieldPtr(consts[key_const])`, validates metatable-free + present +
    `hash.count()==aux`, and writes `@intFromPtr(cell)` into `payloads[slot]`. Unlike
    a U0 seed it emits **no** `slot_load` — the existing `href` op (via `href.aux`) is
    the consumer. Re-seeded every entry, never serialized (dead scratch above the
    anchor window) → same determinism as U0.
  - **Per-entry native eligibility.** If any `hash_cell` fails to resolve/validate,
    the entry runs **tier-1a** (the oracle), not native — byte-identical to the oracle
    side-exiting at `guard_hash` i0 (both yield `completed=0`, tier-0 re-runs). Native
    therefore only ever runs when the structure is valid at entry, and within a native
    run the structure is invariant (own store is present-key; no external code runs).
  - **`nativegen`:** `Kind.href` (invariant cell pointer, GP home, **never** in
    `exit_stores` — C2, like `.ptr`/`.aref`); prologue loads the cell from
    `[rsi + aux*8]`; `guard_hash` lowers to **nothing** (validated by seed
    eligibility); `hload` = tag-check `[cell+0]` vs guarded ty → side-exit, then load
    payload `[cell+8]`; `hstore` = store tag+payload to `[cell]` (heap value declines
    native, as the recorder already restricts to int/float). A hash-only table's
    `.ptr` slot has no `guard_lane` (lanes are array-only), so the analyze pass makes
    the lane optional — required only when an `aref` references the slot — and the
    prologue lane-check is gated on `lane >= 0`.
- [x] **H1 deopt-replay tests (`nativegen`/`interp.zig`).** A field whose type
  changes mid-loop side-exits via the `hload` tag-check (the type-change 8-mode test);
  a sibling-table grow between trace entries re-resolves the cell and never dangles
  (the "grows between trace entries" 8-mode test); RMW double-apply is covered by the
  existing field-RMW 8-mode parity (native ≡ oracle ≡ tier-0).
- [x] **H1 measure.** `bench/field_hash.lua` (`t.x = t.x + t.y` RMW): tier-0 1534 ms
  → native 22.3 ms (**68.8×**), within **2.6× of LuaJIT** (8.5 ms). `perf record`
  confirms **99.9%** of the run is native `[JIT]` with `Table.get/set` at **0.0%** —
  the value-cell pointer is fully hoisted. nbody/array3d still record (coverage win)
  but their companion blockers (`sqrt`, the closure iterator) keep them tier-1a until
  those levers land.

### Outstanding

- [ ] **Computed-key / absent-key follow-ons (deferred).** `t[expr]` (runtime key)
  and absent-key insert/`__index` are out of v1 scope — they need a runtime
  key-identity guard and a grow-aware cell re-resolve respectively. Defer until a
  real corpus bench needs them.

## 1. Problem: every `obj.field` aborts the trace

Profiling the JIT-inert cluster (`perf record`, per the project profile-first rule)
showed every OOP-shaped bench recording **zero traces**. The root cause is in
`src/trace.zig`: the recorder only handled **integer array keys**. `recArrayGet` and
`recArraySet` both opened with `if (!vkey.isInt()) return self.abort(.bad_type)`.
Since the compiler lowers every `obj.field` to `get_index`/`set_index` with an
interned **string** key, *all* field access aborted. A bare
`local t = {x = 1}; for i = 1, N do s = s + t.x end` recorded nothing — nbody,
array3d, and every idiomatic table-of-fields program were blocked here.

This is the single highest-leverage recorder gap: the prerequisite for the whole OOP
cluster and a generalization to all idiomatic Lua. (Honest scope caveat, told to
Bart up front: this lever alone moves **zero corpus benches** because nbody *also*
calls `sqrt` and array3d *also* has a stateful closure iterator — each needs a
companion lever to fully cash out. It unblocks the *first* abort so those levers can
land on top, and is measured in isolation via a field micro-bench.)

## 2. Why a constant-key hash cell is hoistable (the mechanism)

For a **constant** key, the hash-part value-cell address is loop-invariant and
hoistable to the native prologue, exactly like the array base pointer (nativegen
Phase 2) and the `.ptr`/`.func` snapshots. Facts (verified against the pinned
toolchain's `lib/std/hash_map.zig` and `src/table.zig`):

- The hash part is `std.HashMapUnmanaged(Value, Value, ValueContext)`
  (`table.zig`). `getPtr(key) -> ?*Value` (wrapped as `Table.fieldPtr`) returns a
  pointer to the 16-byte value cell. That cell's base lives *behind* the `metadata`
  pointer, so it is stable across iterations **unless the map grows/rehashes** (a
  realloc moves it).
- Removal **tombstones in place** (no backward shift); a same-key `put` overwrites
  the cell in place. So `obj.x = obj.x + 1` causes **no structural change**.
- String keys are **interned** (`string.zig`); key identity is a pointer/id compare.
- Determinism (docs 02/04): an invariant pointer is **never serialized** — the cell
  is re-resolved per trace-entry via `fieldPtr`, identical to how `guard_func` keys
  on `Proto.id` and the cross-frame `InputSeed`s re-resolve each entry. Only the
  interned key (a heap-string trace const, serialized as bytes) and the table slot
  are persisted.

## 3. Design decisions

### 3.1 `guard_hash` pins structural stability, not the raw cell

H0's `guard_hash` checks `metatable == null ∧ fieldPtr(key) != null ∧
hash.count() == recorded`. The `count()` half catches any delete/insert/grow (the
population changed); the metatable/present halves are the soundness floor. The cell
is **re-resolved via `fieldPtr`**, never computed from a serialized pointer. In H1
this becomes the native `(size, metadata)` sentinel: `guard_hash` will pin **both**
`[table + hash_off + @offsetOf(Map,"size")]` (delete/insert/grow → size changes)
**and** `[table + hash_off + 0]` (the `metadata` pointer → realloc-grow). Precedent
for reading Map internals from native: `guard_append` already reads
`hash_off + @offsetOf(Map,"size")`.

### 3.2 `hload` is a *typed* load + the existing type-guard, not a polymorphic load

A cell holds a full 16-byte tagged `Value`, unlike a packed array lane. So the
recorder emits `hload` then the **existing** `guard_int`/`guard_float`/… on its ref,
mirroring `slot_load` + type-guard. The oracle returns the whole `Value`; the
type-guard is what makes the two agree on the side-exit iteration (and pins the field
type, so an int→float change side-exits). In H1, native lowers `hload` to: load tag
`[cell+0]`, side-exit if ≠ guarded tag, load payload `[cell+8]` into a scalar
register of that Kind — reusing the existing scalar-Kind register model, no new value
representation.

### 3.3 Scalar-field restriction (int/float only)

H0 traces only **int/float** field values, for read and store. Two joined reasons:
(1) the scalar exec-log encoder (the cross-mode determinism oracle) cannot serialize
a heap value, so `hload`'s logged value must be scalar; (2) only int/float have a
*strict* type guard that pins the field's type across iterations — a `bool` field
could silently become a truthy heap value that `guard_true` would wave through. A
bool/heap/string field aborts (`.nyi_opcode`), exactly as a `.value` array lane does.
This covers the int/float field arithmetic OOP code is built from (nbody/array3d);
reference fields (`obj.next = node`) stay tier-0.

### 3.4 Present-key only (the dangle-hazard floor)

The recorder aborts unless `fieldPtr(key) != null` at record time. This forbids
absent-key inserts (which could grow/rehash and dangle every hoisted cell) and is the
hash analogue of the array path rejecting the grow case. A present-key overwrite never
grows. A `nil` store (delete) also aborts. No `hstore_insert` analogue in v1.

### 3.5 Const-key only

The key must be a recorded `konst` (the bytecode literal interned via `load_const`),
checked by `self.rec.instrs.items[rkey].op == .konst`. A computed key (`t[expr]`)
reaches the hash path as a `slot_load`/arith ref and aborts (v1 scope) — a
runtime-varying key cannot be pinned to one cell, and would need a runtime
key-identity guard.

### 3.6 `hstore` follows the C1 store-sink discipline

A store after any heap **LOAD** (`aload` *or* `hload`) is deferred into
`pending_stores` (cap `MAX_PENDING_STORES`, flushed below every guard before `.loop`),
identical to `recArraySet` — `PendingStore` carries an `.op` field so the flush emits
`hstore` vs `astore` correctly. `recHashGet` aborts if a pending store is already live
(the post-store no-load invariant). No `guard_fits`: a hash cell holds a full tagged
`Value`, so any value type fits (native declines a heap value in H1).

## 4. Soundness summary (the argument reviewers must check)

1. **Cell never dangles.** Present-key-only forbids the grow/rehash that moves the
   values base; `guard_hash`'s population check side-exits if a *sibling* mutation
   grows the map between entries. The cell is re-resolved per entry, never serialized.
2. **Store idempotence.** `hstore` inherits the store-sink argument verbatim
   (docs 07/08): it is flushed below every guard, so any side-exit leaves it
   un-executed and tier-0's loop-header re-entry applies it exactly once. The
   post-store no-load invariant closes the stale-read channel.
3. **Type stability.** The `hload` type-guard pins the field to int/float; a change
   side-exits on the same iteration in oracle and (H1) native.
4. **Determinism inherited, not re-argued.** No raw pointer is serialized; the key is
   an interned heap-string const; the cell re-resolves at entry. Store-sinking moves
   only *when* the store emits, not *what* it writes. The tier-1a oracle executes the
   same IR, so all 8 modes stay byte-identical.

## 5. Phasing

### H0 — recorder + tier-1a oracle (correctness, NO speedup) — **landed**

Native auto-declines (the trace carries the four new ops; `proveKinds` returns
`false` on first sight of any → tier-1a). This is the array path's oracle-first first
cut (cf. `astore_append`, `int_of_float`). Goal met: the field micro-bench records a
trace with `guard_hash`/`href`/`hload`/`hstore`, byte-identical across 8 modes +
replay.

### H1 — native lowering (THE speedup) — **outstanding**

See the Outstanding checklist. **Seed-based (Approach B, chosen 2026-06-23):** the
cell pointer is re-resolved per entry in the dispatch loop (`seedTraceInputs`) and
stashed in a synthetic slot — mirroring U0's `InputSeed` — so native reads it as an
invariant `Kind.href` home with no native→Zig call and no inline hash probe. H0's IR
and oracle stay frozen (the per-iteration `guard_hash` keeps emitting exec-log events
for replay parity); `href.aux` carries the synthetic slot; native's `guard_hash`
lowers to nothing because seed eligibility already proved the structure at entry.
`obj.x = obj.x + 1`-shaped loops run native; measured via the field micro-bench and
`perf record`.

> **Rejected alternative (the plan's original wording):** a prologue `hresolve`
> *helper call* from native (`{cell_ptr,size,metadata}` into `cell_home`/…). It would
> introduce the codebase's first native→Zig call (new ABI/clobber/alignment surface)
> and was the riskiest path; seeding reuses the U0 machinery instead. The
> `(size,metadata)` sentinel is likewise unnecessary: within a native run the cell
> never dangles (own store is present-key, no external code runs), and a cross-entry
> structural change is caught by the per-entry seed validation, not a body guard.

## 6. Out of scope (follow-ons)

- **Computed keys** (`t[expr]`) — need a runtime key-identity guard. Deferred.
- **Absent-key insert / `__index` / `__newindex`** — grow-aware re-resolve and
  metatable dispatch; out of scope, still abort.
- **Heap/bool field values** — no scalar exec-log encoding and no strict type guard;
  abort (`.nyi_opcode`), as a `.value` array lane does.
