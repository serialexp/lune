# mahina — builtin recording breadth, arc A: the non-allocating subset

Status: **landed (2026-08-27).** Implementation notes are inline at the
points where the landed code deviates from the draft (result-arity abort
reason; int-arg promotion; the `pow` callout).
Scope decision (Bart): arc A = everything that records without guest-heap
allocation; the allocating builtins (`tostring` on non-konst args, the string
library) are **arc B**, behind a deterministic on-trace-allocation design
(future doc). scalar's loop contains `#tostring(i)`, so **scalar does not move
in arc A**; partialsums and every loop using the arc-A builtins do.
Owner: Bart
Last updated: 2026-08-27

Prerequisite reading: `12-pure-builtin-tracing.md` (the identity mechanism this
generalizes), `02-determinism.md`, `03-gc-memory.md` (non-moving GC,
safepoint-only collection), `05-native-codegen.md` (`resolveHashCell` callout),
`18-slot0-array-part.md` (the `#t` border fast case).

Upstream source read: `~/Projects/LuaJIT/src/lj_ffrecord.c` (all base-library
handlers), `lj_ircall.h` (typed C-call table), `lj_record.c`
`rec_call_specialize`, `lj_asm.c` `asm_tostr`.

## Why this exists

A `.call` to any native except `math.sqrt` aborts recording with
`.host_barrier`; one `type()` call kills an entire loop's trace. Measured
demand (`--dump-aborts`, 2026-08-27, post-stringtable):

| bench | abort | builtins on the hot path | arc |
|---|---|---|---|
| partialsums (6.9×) | `host_barrier` pc 36 | `sin`, `cos` (sqrt already inlines) | **A** |
| scalar (4.0×) | `host_barrier` pc 18 | `type` ×3, `select('#',…)`, `tonumber`(konst), `rawset`, `rawget`, `rawequal`, `#t` — all arc A — **plus `tostring(i)`: arc B** | A+B |
| str_manip | `host_barrier` pc 17 | `string.sub/upper/…` (string results = allocation) | B |
| tbl_ops | `host_barrier` pc 16 | `table.move` (+ `new_table` nyi — different lever) | later |

LuaJIT records all of these (`LJLIB_REC` → `recff_*`). Its mechanism
decomposes into **four recording classes**; the decomposition is what this
design ports — every future builtin recorder is a table entry, not new
architecture (Z-6):

1. **Fold-to-konst** (`recff_type`, `recff_select` `'#'`, `recff_tonumber` on
   konsts, `recff_rawequal`): result is a recording-time constant once the
   argument's type/identity is pinned; zero IR beyond guards.
2. **Reuse existing IR** (`recff_rawget/rawset` → the same `lj_record_idx` the
   index bytecodes use, metamethod chain off; `recff_rawlen` → existing
   `FLOAD`/`ALEN` ops).
3. **Typed runtime callout** (IRCALL): a typed call to a C helper with declared
   effects. Even `IR_TOSTR` is this class (`asm_tostr` → `lj_strfmt_int` call
   with GC accounting). Arc A ports the **non-allocating** half (`sin`/`cos`);
   the allocating half is arc B.
4. **Stitching** (`recff_nyi` ends the trace with a continuation instead of
   aborting). Not this arc; own lever.

Callee identity: LuaJIT guards `callee == <function object>` (GC-pointer
konst, `rec_call_specialize`). mahina's determinism-preserving equivalent exists
— `guard_pure` re-proving a registry-riding enum ordinal (doc 12); no pointer
baked or serialized.

## Goals (arc A)

- The dispatch skeleton: `recCall`'s native arm dispatches per-builtin over the
  (renamed) stable builtin enum — mahina's `recff_idmap`.
- Class 1: `type`, `select('#')`, `tonumber`(konst / observed-number),
  `rawequal` (NaN-safe subset), `tostring`(konst, lookup-only),
  `rawlen`(konst string).
- Class 2: `rawget`/`rawset` via the extracted index-recording shapes; `#t` and
  `rawlen(t)` via a new guarded `alen` op.
- Class 3, non-allocating: `fsin`/`fcos` through a generalized body-callout
  facility grown from the `resolveHashCell` precedent, calling **one shared
  routine per function across all three tiers**.
- **Recording allocates no guest-heap object, ever** (the arc's invariant; see
  D6). partialsums records its loops end-to-end; all gates green.

## Non-goals (arc A)

- **Any on-trace guest allocation.** `tostring` of a non-konst value, the
  string library, `table.move`, `concat`. Arc B, behind its own design: the
  codex review established that deferring collection while allocating diverges
  the de-intern/re-intern history and thus the `next_obj_id` stream that rides
  keyframes; repairing that needs continuation exits + a collection-boundary
  protocol, not a flag.
- Stitching (class 4). `select(k,…)` multi-result shuffle. `tonumber` on
  non-konst strings (guarded parse). `__tostring` metacall recording.
  `new_table`/`concat`/generic `len` opcodes beyond the `alen` fast case.
- New type guards (`guard_string`, value-equality guards): nothing in arc A's
  demand needs them; speculative vocabulary without a consumer is Z-7
  scaffolding.
- Callout clobber-mask refinement (conservative save-all is v1; measure first).

## Design

### D1. Dispatch, and the enum rename

`PureBuiltin` becomes **`RecordedBuiltin`** (field `Native.pure`/
`BaseNative.pure` → `.recorded`; op `guard_pure` → `guard_builtin`): with
`rawset` (effectful) and `tostring` (allocating, arc B) joining, "pure" would
be a standing lie for future readers (codex #11). Mechanics unchanged:
ordinals are the stable wire enum in `guard_builtin`'s aux — **append-only,
never renumbered**; `sqrt = 0` keeps its ordinal; registry rows set
`.recorded = .<tag>`; `defineNative` + keyframe restore copy it by name
exactly as before (replay stability inherited from doc 12). The IrOp rename is
safe: traces are runtime-only, never serialized. Appended ordinals:

```
sqrt = 0,            // existing
type = 1, tostring = 2, tonumber = 3, select = 4,
rawequal = 5, rawget = 6, rawset = 7, rawlen = 8,
sin = 9, cos = 10,
```

`recCall`'s `.native` arm:

```zig
if (nat.recorded) |rb| return self.recBuiltin(rb, instr, regs);
return self.abort(.host_barrier);
```

Common preamble (extracted from `recPureSqrt`, which becomes the `.sqrt` arm):
fixed windows only (`instr.b`/`instr.c != all_results` → `.cross_frame`);
`guard_builtin(callee_ref, rb)` deduped through `guarded_refs` (callee is a
seeded loop-invariant → one guard per trace per callee).

**Result-arity rule (codex #8): every producer arm requires `instr.c == 1`**
and writes `setReg(instr.a, result)`. The two statement-tolerant arms are
`rawset` (`c ∈ {0,1}`; `setReg` of the table ref only when `c == 1`) and — in
principle — nothing else in arc A. `c == 0` on a producer aborts (tier-0 owns
discarding; no silent register clobber of the callee slot). *Implementation
note:* the landed arms use `.cross_frame` for every `c ≠ 1` producer window —
the mismatch is a compile-time window shape, not an observed-value type — where
this draft said `.bad_type`; the abort either way, and the reason taxonomy
(`cross_frame` = structural window, `bad_type` = observed shape) favours
`cross_frame`.

Each arm then checks its own arity (`instr.b`) and observed argument shapes
(`regs.get` — the runtime values recording shadows), aborting `.bad_type`
where tier-0 must own the case. The guards it emits are what make the
observed-shape choice sound on later entries.

### D2. Class 1 — fold-to-konst recorders

**The arc-A fold invariant (codex #1): a fold may not allocate.** The recorder
runs *before* the instruction executes (`recordInstr` precedes dispatch,
interp.zig), so it must not perform fallible guest-heap work on tier-0's
behalf. Any fold needing an interned string uses **`Heap.internedLookup`
(read-only) and aborts `.bad_type` on a miss**. In steady state the lookup
always hits — the hot-count threshold guarantees prior tier-0 iterations of
this very call already interned the value — so the abort path is a cold
oddity (first-ever execution of a just-hot branch), and recording simply
retries later, by which time tier-0 has interned it. D7 pins the invariant
with a test: *recording never creates a guest heap object*.

**`type(x)`** — dispatch on the observed argument:

| observed `x` | guard emitted | folds to (via lookup) |
|---|---|---|
| int or float | `guard_number(arg)` | `"number"` |
| table, no metatable | `guard_table(arg)` (checks both) | `"table"` |
| native with `recorded` tag | `guard_builtin(arg, tag)` | `"function"` |
| Lua closure | `guard_func(arg, proto.id)` | `"function"` |
| anything else | — | abort `.bad_type` |

`guard_table`'s metatable==null side-condition and `guard_func`'s proto-id
over-specificity are *stronger* than `type()` needs — a metatable'd table or a
different closure deopts to tier-0. Correct, merely conservative; a weaker
guard waits for a consumer. The type-name strings are pre-interned in
practice (tier-0 ran this call ≥ hot-count times); lookup-miss aborts per the
invariant. The konst is rooted by the existing trace-consts GC-root walk
(`forEachRootHeader` item 5 covers `rec.consts` and cached `t.consts`; GC is
non-moving), and stays out of the `.snapshot` walk (doc 17 H-2/G-2) — lifting
`konst`'s proto-constants-only *convention* needs no new mechanism.

**`select('#', a…)`** — only when the selector ref is a konst whose value is
the interned `"#"` string (pointer identity, licensed by interning): fold to
`Value.int(instr.b - 1)`. `instr.b` is the arg count excluding the callee
(verified against the call ABI + bytecode tests; codex #5 confirmed), so the
count after the selector is `b − 1`, compile-time fixed — zero runtime guards
beyond `guard_builtin`; konst args need no re-proving. Non-konst selector:
abort `.bad_type`.

**`tonumber(v)`** — konst arg (1- and 2-arg konst forms): run `bToNumber`'s
parse at record time, fold the int/float/nil result — no interning involved
(the result is never a string). Observed non-konst *number* arg (1-arg form):
`guard_number(arg)` + identity pass-through. Everything else aborts.

**`rawequal(a, b)` — NaN-safe subset only (codex #6).** `Value.eql` on two
NaNs is *false*, so `same SSA ref → true` is wrong for floats
(`rawequal(0/0, 0/0)`). Fold rules:
- both refs konst → fold `Value.eql(ka, kb)` (record-time, exact);
- same SSA ref **and** the ref's type is proven non-float (int konst; heap
  konst; or a ref already carrying `guard_int`/produced by an int-typed op) →
  fold `true`;
- same SSA ref with float or unknown type: abort `.bad_type` (a NaN-aware
  compare op has no consumer yet);
- different non-konst refs: abort.
scalar's `rawequal(t, t)` is same-ref on a table (heap, non-float) → folds.

**`tostring(v)`** — **konst arg only** in arc A: compute the rendering tier-0
would produce (shared helper with `bToString`'s scalar path, which cannot hit
`__tostring` for non-heap konsts — numbers can't carry metatables, and
`metaToString` on a string returns it unchanged), then `internedLookup` + fold;
miss aborts. Observed string arg that is itself a konst → pass-through fold.
Everything non-konst aborts (that's arc B's `tostr_int`).

**`rawlen(v)`** — konst string arg: fold `Value.int(s.len)` — **byte length**
(`bRawLen` returns `String.len`; codex #7 caught that `#s` is `cp_len`, a
different quantity — the two must not share an implementation). Table arg:
the `alen` emission below, same as `#t`. Else abort.

### D3. Class 2 — rawget/rawset via extracted shapes, and `alen`

`rawget`/`rawset` bypass `__index`/`__newindex` — and the existing index
recorders already abort on *any* metatable (`.has_metatable`) with
`guard_table` re-proving absence at runtime. On a metatable-free table, raw
and non-raw access are the same operation, so the recorders are reusable
verbatim; their guards make the equivalence sound rather than assumed.

Refactor: extract the cores of `recArrayGet`/`recArraySet`/`recHashGet`/
`recHashSet` from their `get_index`/`set_index` instruction framing into shape
functions over explicit `(table_reg, key_reg, dest/val_reg)`, consumed by both
the opcode arms and the call-shaped builtins. No behavioural change for the
opcodes (existing index-tracing tests are the gate); the extraction is a slice
of the final architecture, not scaffolding.

- `rawget(t, k)`: numeric `k` → array-get shape; konst-string `k` → hash-get
  shape; else `.bad_type`. Result → `instr.a` (`c == 1` required).
- `rawset(t, k, v)`: numeric → array-set (in-bounds RMW or append shape; store
  sinking discipline unchanged — the sunk store commits below every guard
  exactly as for `set_index`); konst-string → hash-set (present-key overwrite
  only). Nil/NaN konst key → abort (tier-0 owns the error). `c` rule per D1.
- Grid-lane tables abort `.bad_type` at record time (tier-0's raw access
  deflates grids; a trace must not bake a deflation). `guard_lane` already
  deopts if a table becomes a grid between entries.

**`alen` — the `#t`/`rawlen(t)` op.** `Table.length()`'s fast case is exact:
for a non-grid table with empty hash, `asize == 0` → 0; `asize > 0` with slot
`asize−1` present → `asize − 1` (verified against table.zig; key 0 never
participates, doc 18). Broadened per codex: **`asize <= 1` needs no presence
check at all** (the result is 0 either way).

- **Presence is lane-specific (codex #4)**: the presence *bitmap* exists only
  for fixed-width scalar lanes; `.value` encodes nil in-band and `.boolean`
  encodes absence as byte 0. Arc A scopes `alen` to **bitmap lanes** (the
  common case); `.value`/`.boolean`/grid lanes abort `.bad_type` at record
  time, and the op's runtime check re-verifies the lane (below).
- **Emission**: `guard_table(t)` → `alen(t)` — a guarded producer (side-exits
  but yields a value, like `int_of_float`). Runtime semantics, identical in
  tier-1a (shared `Table` helper) and native (memory-operand compares, mirroring
  `guard_append`'s lowering): side-exit unless *hash.count == 0 ∧ lane is a
  bitmap lane ∧ (asize ≤ 1 ∨ presence(asize−1))*; result `max(asize−1, 0)`.
  The side-exit sends the border search back to tier-0, which owns every
  general case.
- **Pending-store hazard (codex #4)**: sunk RMW stores commit only at trace
  commit, below all guards — an `alen` recorded after a sunk `astore` to the
  same table would read the pre-store border. Arc A rule: **recording `alen`
  aborts if `rec.pending_stores` is non-empty** (conservative — any pending
  store, any table; per-table refinement waits for a consumer). scalar's
  `#t` follows its `rawset` in source order, but that `rawset` targets slot 1
  of a ≥3-element array — an in-bounds RMW that is *sunk*; so scalar's shape
  is exercised only if the flush-ordering refinement lands, otherwise the
  `#t` aborts recording. See D5 for what this means for scalar (nothing —
  scalar waits for arc B anyway).
- **Optimizer barriers**: `alen` classifies as a *load with table-alias
  effects* — never CSE'd or hoisted across `astore`/`astore_append`/`hstore`
  (same alias discipline as `aload` across stores), and never reordered with
  the commit flush. tropt's `kindOf` gets an explicit arm; the conservative
  choice is "treat as `.opaque` for motion, `.load` for DCE" until a profile
  argues otherwise.

`#t` (the `len` opcode) records through the same shape when the operand is an
observed table. A string operand: konst → fold `cp_len` (code points — the
`#s` semantic, distinct from `rawlen`'s bytes); non-konst → stays unrecorded
(`nyi_opcode`, as today — no string guard).

### D4. Class 3 — the generalized non-allocating body callout

Doc 12's "no `call` emitter" scoping is stale: `emitHrefCallout` is a complete
precedent — SysV call, full caller-saved GP+XMM save/restore into the
pre-reserved `callout_save_base` frame area, 16-byte alignment fix,
restore-*then*-test so a deopt's snapshot flush sees correct homes, side-exit
on failure sentinel. Arc A generalizes it to a table without changing the
discipline:

- **`BodyCallout` grows `fsin`, `fcos`** (alongside `resolve_hash_cell`).
  `calloutMayGc` keeps its exhaustive fail-closed switch; both new rows are
  honestly `false` — the helpers neither allocate nor collect. (The
  "allocation ≠ collection" refinement of that capability's meaning belongs
  to arc B, which will split `may_allocate` from `may_collect`; arc A does not
  touch the contract.)
- **One shared routine per function across all tiers (codex #10).** A bare
  `@sin` at three sites does not prove one emitted routine — LLVM may lower
  the sites differently. Arc A adds `noinline` wrappers as the single source:

  ```zig
  pub noinline fn sinRuntime(x: f64) callconv(.c) f64 { return @sin(x); }
  pub noinline fn cosRuntime(x: f64) callconv(.c) f64 { return @cos(x); }
  ```

  Tier-0 (`mSin`/`mCos`), tier-1a (`.fsin`/`.fcos` arms), and the native
  callout all call these. Bit-identity across the 8 modes is then by
  construction *within this binary* — the same argument as `fsqrt`'s, via a
  call instead of an instruction. The cross-binary libm-drift hazard is not
  new (tier-0 has carried it since `math.sin` landed); if it ever needs
  refusing at replay time, that is a recorded-constant check à la
  `unicode_version`, orthogonal, protecting tier-0 too.
- **No heap/VM context needed**: `f64 → f64`, args/result in `xmm0`. The
  callout emitter takes the target address + arg recipe (ref-to-register or
  immediate) + result disposition; `fsin`/`fcos` have no failure sentinel and
  no exit — simpler rows than `resolve_hash_cell`. (The `*Heap` channel
  question is arc B's, deleted from this arc.)
- **Recorder arms**: `sin`/`cos` clone the `sqrt` arm — `guard_float(arg)` +
  producer op; int args abort `.bad_type` (tier-0 owns promotion; doc 12's v1
  scoping unchanged). *Implementation note (landed):* this scoping contradicted
  D5's own headline — partialsums' loop var `k` is an **integer** under Lua 5.4
  for-loop semantics, so `sin(k)`/`sqrt(k)` aborted `.bad_type` and the loop
  never recorded. The landed arms accept a numeric arg and pin the *observed*
  type (`guard_int` or `guard_float`); an int operand promotes by the SAME
  operand-level discipline the float binary ops already use (tier-1a
  `@floatFromInt`, native `cvtsi2sd` in `floatOperandToXmm` — round-to-nearest,
  bit-identical). No new IR op: promotion is an operand property, exactly as in
  the existing float-binop lowering, and it lifts `fsqrt` too. Non-numeric args
  still abort `.bad_type`.

### D5. Expected effect

- **partialsums** records its loops end-to-end (`fsin` + `fcos` join `fsqrt`
  in otherwise-arithmetic bodies) — the arc's headline row.
  *Implementation note (landed):* recording end-to-end took the int-promotion
  fix above, and **compiling** the trace took one more general lever the draft
  missed: the loop's `(2/3)^k` emits a `pow`, which nativegen deferred — the
  whole trace declined to tier-1a, and the gate correctly retired it (tier-1a
  ≈ tier-0 on this body). `pow` is now the second user of the generalized
  body-callout: `arith.pow` routes through a shared `noinline`
  `fmath.powRuntime(f64, f64)` kernel (pure-software `std.math.pow`, strict FP)
  and the native body calls that same kernel (args xmm0/xmm1, result xmm0,
  `calloutMayGc = false`). One compiled body → cross-tier bit-identity by
  construction, same argument as sin/cos. Landed result: partialsums 100%
  native iterations, 278 c/it vs 5340 tier-0, wall 245 → 63.5 ms
  (−79.3% instructions), board row 6.9× → 2.0× LuaJIT.
- **Breadth**: every loop whose only barrier was `type`/`select('#')`/
  `tonumber`(konst)/`rawequal`/`rawget`/`rawset`/`#t` now records. The suite's
  `--dump-aborts` inventory after landing tells us which rows moved; no
  prediction beyond partialsums is baked in.
- **scalar does not move**: its loop still aborts at `#tostring(i)` (arc B).
  Stated up front so the board delta is read correctly.

### D6. Determinism analysis

- **Recording allocates no guest-heap object** — the arc invariant. Folds are
  read-only (`internedLookup`, abort on miss); `tonumber` folds produce
  non-heap values; `alen`/`rawget`/`rawset`/`fsin`/`fcos` emit ops, allocate
  nothing. Recorder *host* allocations (`rec.consts` etc.) were always outside
  the guest heap's id/accounting space. Consequently the object-id stream is
  byte-identical across all 8 modes by construction — no "same logical point"
  reasoning required (the codex review showed that argument was unsound;
  arc A simply removes its premise).
- **No on-trace allocation → no GC-timing divergence.** Bursts defer the
  safepoint exactly as they do today, and since nothing grows the heap
  mid-burst, the collection points and de-intern/re-intern history are
  unchanged from the pre-arc behaviour.
- **`fsin`/`fcos`**: one shared compiled routine per function (D4) — 8-mode
  bit-identity by construction.
- **Fail-closed identity**: `guard_builtin` (unknown ordinal → deopt) and the
  append-only ordinal rule carry over from doc 12 unchanged; keyframe restore
  rebinds `.recorded` by registry name.
- **Konst rooting**: heap konsts (interned type-name strings etc.) are rooted
  by the existing trace-consts root walk; non-moving GC keeps baked pointers
  valid; snapshot walk exclusion (doc 17 H-2/G-2) keeps snapshot bytes
  JIT-mode-invariant.

### D7. New-op integration inventory (codex #12 — the checklist per new IrOp)

For each of `guard_builtin` (rename), `alen`, `fsin`, `fcos`:
`isSideExitGuardOp` / side-exit classification; `guardExitPc` + exit
provenance (`alen` carries the `len`/call pc); `opMayExitInBody`
(nativegen C1 inventory — `alen` yes, `fsin`/`fcos` no); tropt `kindOf`
(+ alias/motion rules for `alen`); DCE use-counting; well-formedness checks
(operand types); tier-1a executor arms; native lowering + exit metadata;
`jitdbg` dump formatting; exec-log handling; the IR-dump golden tests. The
serializer is untouched (traces are not serialized) — asserted by grep at
implementation time, recorded here if wrong.

### D8. Tests

- Per-arm recorder tests: each fold/reuse shape records with the expected IR
  (dump assertions), and **deopts correctly**: builtin reassigned between
  entries (`guard_builtin`), metatable'd table (`guard_table`), `alen` fast
  case broken (hash key added / trailing nil / `.value`-lane table), float
  `rawequal` aborts (NaN case pinned as *not folded*), `c == 0` producer
  aborts.
- **The no-allocation invariant**: a counting-allocator test asserting
  recording a builtin-heavy loop creates zero guest heap objects
  (codex's inverted D7 test).
- `alen` differential vs `Table.length()`: dense / trailing-nil / hash-border
  / grid / `.value`-lane / `asize ∈ {0,1,2}` tables — guarded fast case
  matches exactly or side-exits.
- `rawlen("héllo")` vs `#"héllo"` differential (bytes 6 vs code points 5 —
  codex's UTF-8 catch, pinned in both tiers).
- `select('#')` boundary: 0, 1, several trailing args.
- `fsin`/`fcos` bit-identity corpus across tiers: NaN, ±inf, ±0, subnormals,
  a value sweep — plus partialsums in the 8-mode hashgate (already covered;
  the new fact is it traces, asserted via `--jit-stats`).
- Full gate battery: `just test`, `-Djit-debug=true`, hashgate 84/84 both
  legs, bench 28/28.

### D9. Risks

- **Recorder-arm sprawl**: ten arms × observed-shape dispatch; the abort
  matrix must be exact. Mitigation: arms land one at a time behind green
  gates, each with its own deopt tests.
- **Callout save/restore cost** (~30 moves around `fsin`): partialsums still
  wins hugely vs tier-0 dispatch; clobber-mask refinement deferred until a
  profile shows it (Z-6).
- **`alen`'s pending-store abort** may keep some real `rawset-then-#t` loops
  (scalar's shape) unrecorded even in arc B; the flush-ordering refinement is
  the known follow-up, tracked, not speculatively built.
- **The rename sweep** (`PureBuiltin`→`RecordedBuiltin`, `guard_pure`→
  `guard_builtin`) touches many sites; done as a dry-run-reviewed script
  (Rule #6), ordinals asserted unchanged by the existing wire-stability
  comments + tests.
