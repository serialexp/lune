# 85 — Library calls through their module table, and heap values read out of tables — Design

Status: partial — Phase 0 (a tier-0 ordering bug in `math.max`/`math.min`,
found while reading for Phase 3), Phase 1 (string and native hash fields),
Phase 2 (string, native, closure and bool array elements) and the typed-load
exit fix that Phase 2 turned up (§5.2, §5.3) landed, `type()` of a
string records (§5.3 follow-up), and Phase 4's board row is in
(`bench/records_script.lua`, §7): the JIT runs it 1.67x slower than tier
0, and Phases 1 and 2 and the exit fix each made it slower (§7.2). `#t`
on an array of records, strings or booleans records now (§7.3):
meta_fields −39.9%, and `records_script` unchanged, because nothing joins
its loops across the calls between them. Phase 3 is not
started; Q1, Q2 and Q3 (§8) are open. Bart has not picked this arc: it was
started on 2026-11-11 under "continue using your best judgement" after four
asks went unanswered. Phase 3 needs his answer to Q1.
Owner: Bart
Last updated: 2026-11-11

Prerequisite reading: doc 11 (hash-field tracing), doc 43 (heap-valued fields:
the dynamic `guard_func`/`guard_table` precedents this doc follows), doc 32
(the `.value` array lane), doc 12 and doc 23 (`RecordedBuiltin` arms), doc 63
(host calls in precise loop roots).

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole phases to Done once everything inside them is checked.

### Done

- [x] **Phase 0 — `math.max`/`math.min` order their arguments exactly.**
  `pickExtremum` compared through `f64`, so two integers past 2^53 that share
  a float tied: `math.max(9007199254740992, 9007199254740993)` returned the
  first. It now orders like the `<` operator: one compare for two integers
  or two floats, `value.compareNumeric` for a mixed pair. The tier-0 fast
  path takes the same-typed pairs and hands a mixed pair to the native, so
  it stays free of calls. Test: "math.max and math.min order integers
  exactly, alone and against a float". A recorded arm (Phase 3) has to
  agree with tier 0, so this went first. Tier 0 on §2.1's clamp probe went
  from 3,288 M to 3,239 M instructions (the integer compare replaces two
  conversions); the board's tier-0 rows moved between −0.32% (scalar) and
  +0.14% (io_print, co_pingpong: one instruction per native call, from
  `opCall`'s register allocation shifting), geomean +0.008%.
- [x] **Phase 1 — a hash field holding a string or a native records and
  runs native** (§4, §4.4 for what was built and measured). On §2.1's
  probes with the JIT on: `math.floor` by its qualified name 1,282 M to
  211 M instructions (the hoisted local is 178 M), a string field's length
  1,054 M to 76 M, `string.sub` by its qualified name 2,398 M to 784 M.
  The board is flat, as §2.2 predicted (geomean +0.016%, the same
  native-call instruction as Phase 0).

- [x] **Phase 2 — a `.value`-lane array element holding a string, a native,
  a closure or a bool records and runs native** (§5, §5.1 for what was
  built and measured). With the JIT on: `#names[i % 3 + 1]` 1,036 M to
  121 M instructions, a native element called 1,123 M to 214 M, closure
  elements called 3,150 M to 127 M. The board is flat: str_sort's three
  `get_index` sites now record and its loops stop at the next thing they
  cannot do (a string stored into an array, `concat`).
- [x] **A typed load is a side exit in its own right** (§5.2 for the
  finding, §5.3 for what was built). A `.value`-lane `aload`, an `hload`
  and a `uload` now have exit facts, and `guard_string` joined the
  side-exit guards, so a slot whose type alternates gets an exit-started
  side trace at the load. With the JIT on: an array alternating int and
  float 3,030 M to 423 M instructions (tier 0: 897 M), a field alternating
  int and float 3,202 M to 750 M (1,113 M), flags alternating bool and int
  6,958 M to 536 M (904 M), elements alternating string and table 3,115 M
  to 473 M (984 M). Board geomean +0.012%.

- [x] **Phase 4 — a board row** in the script idiom, asked for by Bart on
  2026-11-11 after the board did not move for Phases 1 and 2:
  `bench/records_script.lua` with its hashgate digests (§7.1). Agrees
  across the three tiers and with LuaJIT. Baseline and what it shows:
  §7.2.
- [x] **`#t` on a `.value`- or `.boolean`-lane array records** (§7.3;
  the first of §7.2's causes taken, on an unanswered ask). `alen` carries
  an `AlenProbe` and answers tier 0's own fast case
  (`Table.lengthFast`) on every lane but a grid. With the JIT on:
  meta_fields 2,236 M to 1,344 M instructions (−39.9%), globals_script
  −0.27%, `records_script` 9,300 M to 9,301 M. `bad_type len` aborts on
  the board: 169 to 46.

### Outstanding

- [ ] **`records_script` is slower with the JIT than on tier 0** (§7.2):
  9,221 M instructions against 5,561 M (1.66x), LuaJIT 853 M. Four
  causes, each with its own entry in `TODO.md`; none is in this doc's
  phases. `#t` is done (§7.3); what it uncovered is the next item. The
  step from 9,301 M is a gate fix found on this row (doc 84 §4.5
  follow-up).
- [ ] **Nothing joins a loop to the next one across a return and a
  call** (§7.3). LuaJIT runs `records_script` as a ring of four loop
  traces joined by side traces that return to the caller and enter the
  next function's loop. Here each step of that ring stops a recording:
  `cross_frame` at the `ret`, `cont_backedge` at the next loop,
  `nyi_opcode for_prep` at a function head, and no link from inside an
  inlined call. Needs a design; Bart has not picked it.

- [ ] **Phase 3 — `math.abs`, `math.min`, `math.max` get recorder arms**
  (§6). Needs Q1.
- [ ] **Q1 — how `abs`/`min`/`max` record** (§8).
- [ ] **Q2 — whether the module-table load chain is hoisted out of the
  loop** (§8).
- [ ] **Defer — heap values stored into tables** (`hstore`/`astore` of a
  string, closure or table decline native today; the recorder's
  `bad_type set_field` and `nyi_opcode set_index` rows are a separate
  census, §2.2).
- [ ] **Q3 — whether `guard_sid` joins the side-exit guards** (§8). Doc
  30 pinned it out; a pattern that alternates runs 1.8 times slower with
  the JIT than on tier 0.
- [ ] **Defer — an exit whose resume pc is the loop header gets no
  trace for the other type** (§5.3). Not specific to loads: any exit of
  the loop's first bytecode. Noted in `TODO.md`.
- [ ] **Defer — a continuation whose first recording aborts for a retry
  never gets the retry** (§5.3). Noted in `TODO.md`.
- [ ] **Defer — a barred loop's back-edge cost.** A loop whose recording
  is abandoned pays about 30 instructions per iteration over tier 0 with
  the JIT on (§2.1's `math.floor` row). Noted in `TODO.md`.

## 1. Why this exists

A loop that calls a library function by its qualified name, or reads a
string out of a table, never traces:

```lua
for i = 1, n do acc = acc + math.floor(i / 2) end   -- nyi_opcode at get_field
for i = 1, n do acc = acc + #obj.name end           -- nyi_opcode at get_field
for i = 1, n do acc = acc + #names[i % 3 + 1] end   -- nyi_opcode at get_index
```

`math` is a global table and `floor` a field of it, so `math.floor` is a
hash-field load whose value is a native. `hashGetShape`
(`src/trace_recorder.zig`) admits a field holding a number, a bool, a
closure or a table, and aborts on a native or a string. `arrayGetShape`'s
`.value` lane admits a table or a number and aborts on everything else. The
recording aborts each time it is tried, the anchor is barred, and the loop
stays on tier 0 for good.

The board does not show this because its programs were written in the
LuaJIT-era idiom, `local floor = math.floor` at the top of the file. A
local is a `slot_load`, and a slot-loaded native or string already has its
guards (`guard_builtin`, `guard_native`, `guard_string`). Code that is not
written by someone tuning for a JIT calls `math.floor` directly.
`bench/globals_script.lua`, the row added to stand for script-style code,
does exactly that and is the row this gap shows up on.

## 2. Evidence

### 2.1 Probes

Three million iterations each, `instructions:u`, at 54b0a62:

| loop body | tier 0 | `--trace --jit-native` | per iteration (JIT) |
|---|---|---|---|
| `acc = acc + math.floor(i / 2)` | 1,191 M | 1,282 M | 427 |
| the same with `local floor = math.floor` | 879 M | 178 M | 59 |
| `acc = acc + #M.k + M.n` (`k` a string) | 963 M | 1,054 M | 351 |
| `acc = acc + #names[i % 3 + 1]` | 945 M | 1,036 M | 345 |
| `acc = acc + #string.sub("abcdef", 2, i % 4 + 2)` | 2,307 M | 2,398 M | 799 |
| `math.max(10, math.min(1000, x)) + math.abs(1000 - x)` | 3,288 M | 3,379 M | 1,126 |

The first two rows are the same program; caching the function in a local
is worth 7.2x. Every uncached row is slower with the JIT than without it,
by about 30 instructions per iteration: the price of the back-edge hook on
a loop that is barred from recording.

### 2.2 Board census

`--dump-aborts` over the board at 54b0a62, the rows this doc is about:

| count | reason | opcode | rows |
|---|---|---|---|
| 73 | `nyi_opcode` | `get_field` | globals_script (6 sites), ray, co_churn, co_garbage, co_many (3 sites), io_write, os_date |
| 16 | `nyi_opcode` | `get_index` | str_sort (3 sites) |

With the recorder half of Phase 1 in place the `get_field` rows are gone
and the same recordings stop at the next thing they cannot do:

| was `nyi_opcode get_field` in | now | why |
|---|---|---|
| globals_script `clamp`, `near`, `move`, `tick` | `host_barrier call` | `math.max`, `math.min`, `math.abs` have no recorder arm (Phase 3) |
| io_write, os_date | `host_barrier call` | `io.write`, `os.date` are host calls outside a precise loop root (doc 63) |
| co_churn, co_garbage, co_many | `nyi_opcode closure` | closure creation is not recorded |
| co_many (one site) | `nyi_opcode get_index` | a non-table, non-number element (Phase 2) |

So on today's board Phase 1 alone moves nothing; globals_script needs
Phases 1 and 3 together, str_sort needs Phase 2. The probes in §2.1 are
what Phase 1 moves by itself, and Phase 4 puts them on the board.

Related rows that are not in scope (their own work): `bad_type len` 88
(globals_script's `#entities`, tbl_stack, meta_fields), `bad_type
set_field` 43, `bad_type jeq` 28 (`eqRef` aborts on two heap values, so
`a ~= b` over tables or `s == "x"` over strings does not record),
`nyi_opcode set_index` 23, `nyi_opcode set_field` 19.

## 3. What LuaJIT does

Read from `~/Projects/LuaJIT/src`:

- **The load.** `rec_idx_key` emits `HREFK` for a constant string key and
  the load is `IRTG(loadop, t)` (`lj_record.c:1604`): the load itself
  carries a guard on the loaded value's type, whatever that type is. A
  string, a function and a table all load the same way.
- **The callee.** `rec_call_setup` specialises to the function's identity:
  `emitir(IRTG(IR_EQ, IRT_FUNC), tr, kfunc)` (`lj_record.c:825`), one
  pointer compare against a constant. For a fast function the recorder
  then dispatches on its id (`lj_ffrecord.c`).
- **`math.abs`/`min`/`max`.** `recff_math_abs` emits `IR_ABS`;
  `recff_math_minmax` emits `IR_MIN`/`IR_MAX`, in the integer type when
  both operands are integers and after a conversion to number otherwise.
  All three are branch-free in the backend.
- **Hoisting.** With no store to `_G` or `math` in the loop, LOOP
  optimisation leaves the `HREFK`/`HLOAD`/`EQ` chain in the pre-loop part
  of the trace, so the loop body pays nothing for the qualified name.

mahina's shape differs in one way that matters here: `hload ty=.heap`
checks only "a heap value" (the tag), and the subtype is pinned by a
separate guard. That is what doc 43 built for closures (`guard_func`) and
tables (`guard_table`), in both tiers, with a per-iteration in-body form
in native code. Strings and natives are the two subtypes it left out.

## 4. Phase 1 — string and native hash fields

### 4.1 Recorder

`hashGetShape` admits a field whose value is a string or a native and
emits the load chain it already emits for every field (`guard_table`,
`href`, `guard_hash`, `hload ty=.heap`), then:

- **String:** `guard_string` on the loaded ref, at the load: the type pin
  LuaJIT's typed load carries, and what doc 43 does for closures and
  tables. A string consumer (`slen`, `ssub`, the pattern ops) pins its
  operand itself through `stringArgRef`; the optimiser's guard dedup folds
  that second `guard_string` into the load's.
- **Native:** nothing at the load. The consumer pins it: `recBuiltin`'s
  arms emit `guard_builtin(ref, tag)` through `guardBuiltinCallee`,
  `recHostCall` emits `guard_native(ref, k)`, `type()`/`math.type()` emit
  `guard_builtin`, and a host call that ends the trace (`call_interp`)
  needs no guard because tier 0 makes the call with whatever is in the
  register. This is the rule a slot-loaded native follows today: an
  unguarded `slot_load` is legal, and each consumer guards what it relies
  on. There is no op that says only "this is a native", and adding one
  would put a second check in front of the identity check every call
  makes anyway.

Nothing changes in tier 1a: `irinterp`'s `guard_string` and
`guard_builtin` arms read a `Value` and do not care where it came from.

### 4.2 Native

The prover accepts `guard_builtin` only on a `slot_load` (the check is
hoisted to the prologue, once per entry) and `guard_string` only on a ref
already proven a string. Both gain the per-iteration form `guard_func`
and `guard_table` have:

- `guard_builtin` on a `.heap`-kinded ref: in the body, `header.type ==
  native`, `recorded` is non-null, `recorded == tag`; any miss side-exits.
  The same three compares as the prologue form.
- `guard_string` on a loaded ref (`hload`, or a `.value`-lane `aload`):
  in the body, `header.type == string`; a miss side-exits. The prover
  marks the ref a proven string from there on, as `guard_sid` does.

Which form a guard takes is decided by its operand, the way
`guard_func` decides (`kinds[a] == .heap`), so the prover, the
may-exit-in-body table, the home-read analysis and the emitter agree by
construction. The loaded pointer is a transient raw `*GcHeader`, the class
doc 43 P2 established for function fields: safe while no body callout can
collect, and a host call is covered by its `guard_host_epoch`.

### 4.3 Cost

Per iteration, for `math.floor(x)` against the hoisted local: the
`hload` (a tag compare and a load from the entry-resolved cell) and the
three compares of the dynamic `guard_builtin`. Whether those are worth
hoisting is Q2.

### 4.4 Implemented, 2026-11-11

As designed, with these particulars:

- **One predicate decides the string guard's form.**
  `nativegen_prove.isLoadedHeapRef(t, kinds, ref)`: a `.heap`-kinded
  `hload` or `aload`. The prover's Pass B, the emitter, `opMayExitInBody`
  and `HomeReads.readA` all call it. `guard_builtin` needs no predicate:
  its operand is `.native` (the prologue form) or `.heap` (the body form).
- **A carried string may be written back from a loaded field.**
  `cur = obj.name` with `cur` live across the back edge is a carried
  `.heap` slot. The carried-string rule (doc 30 c4b) wanted a string
  producer or a pinned `slot_load` as the writeback; it now also takes a
  loaded value with its own `guard_string`, which the body checks before
  the back edge on every iteration. Without this the trace compiled for
  tier 1a only.
- **Not built: a carried native.** A local that enters as a slot-loaded
  native and is reassigned from a field in the loop (`f = math.floor`
  inside the loop) has no carried-slot rule, so that trace stays on tier
  1a. Pinned by a test as exact, not as native.
- **Host calls.** With `trace_host_calls` on (doc 63, an embedder's
  setting), a host function read from a field is called from the trace:
  `guard_native` already took any `.heap` operand. Two tests in
  `interp_hosttrace_test.zig`.

Measured at three million iterations, `instructions:u`, against 54b0a62:

| loop body | before (JIT) | after (JIT) | per iteration | hoisted local |
|---|---|---|---|---|
| `acc = acc + math.floor(i / 2)` | 1,282 M | 211 M | 70 | 59 |
| `acc = acc + #M.k + M.n` | 1,054 M | 76 M | 25 | |
| `acc = acc + #string.sub("abcdef", 2, i % 4 + 2)` | 2,398 M | 784 M | 261 | |

So a qualified `math.floor` costs 11 instructions per iteration more than
the cached local (Q2's subject). With `--trace` alone (tier 1a, no native
code) the same loops are 2.3 to 4.7 times slower than tier 0 (4,023 M
against 1,185 M for the `math.floor` row), which is what tier 1a costs on
any trace; before, they did not trace and ran at tier-0 speed plus the
hook. The JIT is off unless asked for, and `--trace` without
`--jit-native` is the oracle mode.

Tests: two recorder-shape tests, seven native end-to-end programs (each
runs the ten-leg matrix and then asserts a native entry), three drift
programs (the field replaced by another builtin, by a closure, a string
field by a table and back), one carried-native parity program, and one
truth-test program (`if t.x then` over a string and a native field, each
replaced by `false` mid-loop: any heap value is truthy, so the load's
"some heap value" exit is the only pin the test needs). The older test
that pinned "a string field aborts" now pins the abort for a coroutine
field, a heap type that still has no pin.

## 5. Phase 2 — `.value`-lane elements

`arrayGetShape`'s `.value` lane has the same prefix for every element
type (`guard_table`, `guard_lane`, `aref`, `guard_bounds`, `aload`) and
differs only in the trailing pin. It admits a table (`guard_table`) and a
number (`guard_int`/`guard_float`). To add:

| element | `aload ty` | pin |
|---|---|---|
| string | `.heap` | `guard_string` (Phase 1's dynamic form) |
| closure | `.heap` | `guard_func` (doc 43 P2's dynamic form) |
| native | `.heap` | none at the load, as §4.1 |
| bool | `.boolean` | the load's own tag check, as doc 43 P1 did for fields |

The code comment that refuses these says "no strict type guard pins
them". For bool that was answered by doc 43 P1 (the fused tag exit is the
strict guard); for strings by `guard_string`. To check when building:
that the native `.value`-lane `aload` lowers `ty = .boolean`, and that a
nil element (the lane's in-band hole) fails each pin.

### 5.1 Implemented, 2026-11-11

- **The `.value`-lane `aload` is a typed load in both executors.** Native
  code already checked the element's tag against the recorded `ty` inside
  the load and exited there. Tier 1a read the element and left the check
  to the guard behind it, which a native or a bool element does not have.
  `irinterp`'s `aload` now makes the same tag check for the `.value` lane
  and exits at the load, as its `hload` does. That one rule ("a `.heap`
  load is some heap value, a `.boolean` load is a bool") is what the
  consumers of a field already rely on, so everything Phase 1 established
  for a loaded field holds for a loaded element. A hole (in-band nil)
  fails the tag check.
- **Recorder.** `arrayGetShape` pins a string with `guard_string`, a
  closure with `guard_func` (its proto id, the pin a function field has),
  and emits nothing behind a native or a bool. `boolTyped` takes a bool
  `.value`-lane load as a proven bool. A coroutine or userdata element
  still aborts.
- **Native.** The prover and the emitter take `ty = .boolean` (`TAG_BOOL`,
  the canonical 0/1 payload into a GP home, `hload`'s bool arm). Strings,
  closures and natives needed nothing: Phase 1's `isLoadedHeapRef` already
  named `aload`, and `guard_func`/`guard_builtin` take any `.heap` operand.

Three million iterations, `instructions:u`, against 7ed7ff0:

| loop body | tier 0 | before (JIT) | after (JIT) | per iteration |
|---|---|---|---|---|
| `acc = acc + #names[i % 3 + 1]` | 945 M | 1,036 M | 121 M | 40 |
| `acc = acc + fns[1](i / 2)` (natives) | 1,032 M | 1,123 M | 214 M | 71 |
| `acc = hs[i % 3 + 1](acc)` (closures) | 1,902 M | 3,150 M | 127 M | 42 |
| `if flags[i % 2 + 1] then acc = acc + 1 end` (bools beside a string) | 863 M | 954 M | 373 M | 124 |

The closure row was 1.7 times slower with the JIT than without it: the
loop did not record, and each call entered the callee's own trace through
the one-shot lane (doc 84's subject).

Board, `--trace --jit-native`: every row within 0.001% except str_sort
+0.036% (its recordings now get further before they abort). The census
for str_sort went from `nyi_opcode get_index` at three sites to
`nyi_opcode set_index` (a string stored into an array, the deferred item
above), `nyi_opcode concat`, `needs_precise new_table` and one
`host_barrier call`. co_many's `get_index` row stays: that element is a
coroutine.

Tests: the recorder shape for a string element, the abort for a coroutine
element, native end-to-end programs for string, native, closure and bool
elements and a carried string element, and exactness programs for two
natives alternating at one call site, a closure replaced mid-loop, a bool
turning into a hole, a string turning into a table and back, strings and
numbers mixed in one array, and a native under a truth test replaced by
`false`. `trace_record_test`'s "a `.value`-lane bool element aborts" now
pins the typed load with no trailing guard.

### 5.2 Found: a typed load whose type alternates

Not caused by this doc, and measured on 7ed7ff0 before Phase 2:

| loop body | tier 0 | JIT |
|---|---|---|
| `acc = acc + mixed[i % 4 + 1]`, `mixed = { 1, 2.5, 3, 4.5 }` | 897 M | 3,030 M |
| the same over `{ 1, {}, 3, {} }` behind `type(v) == "number"` | 1,431 M | 3,541 M |
| `acc = acc + objs[i % 2 + 1].v`, `v` an int in one record, a float in the other | 1,113 M | 3,202 M |
| for comparison, a branch that alternates (`if i % 2 == 0`) | 1,157 M | 423 M |

`--jit-stats` on the first row: one trace, 1,499,973 native entries, half
the iterations run on tier 0 "despite a trace", `exit side: wants=0`. The
trace is specialised to the type it was recorded with, the load's tag
check fails on the next iteration, and nothing ever records the other
type. Each native entry that runs a single iteration costs about 1,700
instructions against 300 for the iteration on tier 0. A branch that
alternates is handled (last row).

The first rung of rule Z-8's ladder, from a `-Djit-debug` run of that
loop: every receipt reads `exit=19`, and instruction 19 is the `aload`.
The trace's exit table (`exit-loc:`) has no row for 19. It has one for
instruction 20, the `guard_int` on the loaded value, and that row says
`attach=attachable resume=15`. So the exit native code takes (the tag
check fused into the load) has no snapshot, no attachability and no
exit-side state: `TraceCode.exitSnapIdx` wants a side-exit guard op
(`trace_ir.isSideExitGuardOp`) and a load is not one. The guard behind
the load has all three, and native code never exits there, because the
prover discharges it against the kind the load proved. `routeExitSide`
therefore never wants the exit; and since every entry completes an
iteration, `noteTakenExit` files it as a productive receipt of a
non-branch guard, which raises no want either. An `hload` is the same in
both executors.

Tier 1a used to exit at the guard for an element (the attachable row)
and at the load for a field; since Phase 2 it exits at the load for both,
as native code does. The oracle mode got faster on these loops (8,070 M
to 5,658 M on the first row), having lost the side traces it recorded and
ran slowly.

Phase 2 widens who can meet this a little: before it, an array of mixed
types recorded only when the recorded iteration happened to load a number
or a table; now a string, bool, closure or native iteration records too.

What a fix has to decide (not designed here): the load's exit either
takes the identity of the guard behind it (its snapshot and exit-side
state exist already; a bool and a native have no such guard), or a typed
load becomes an exit in its own right with its own exit facts in both
executors (the op-level `isSideExitGuardOp` cannot tell a `.value`-lane
load from a narrow-lane one, which never exits). Either way the other
type then records as an exit-started side trace (doc 56), the machinery
that serves the alternating branch.

### 5.3 Implemented, 2026-11-11: a typed load is a side exit in its own right

The second shape. It was already half there: the recorder stamps exit
provenance on every typed load (`stampProv(rload, .element_type, …)`,
`.field_type` for `hload` and `uload`; the role's own comment reads
"fused native hload producer-exit"), every instruction carries its
bytecode's boundary ordinal, and native code gives every exiting
instruction a stub that writes its own index. The one missing piece was
that `TraceCode.exitSnapIdx` refused anything that was not a side-exit
guard op, so the load had provenance and an ordinal and no snapshot.

**What changed.** `trace_ir.isTypedLoad(ins)` names the loads that check
their recorded type at the load (`hload`, `uload`, and `aload` out of a
`.value` lane), and `trace_ir.isSideExitInstr(ins)` is "a side-exit guard
op or a typed load". Every place that asked the op-level question about
one instruction now asks the instruction-level one: the recorder's
boundary-snapshot commit, `tropt`'s two snapshot-rooting sites,
finalize's snapshot validation, `exitSnapIdx`, and the two thrash
discriminators (`accountLegacyThrash`'s side headroom,
`candidateLeftEntryState`). Nothing downstream changed: attachability
(`trace_exit_attach`), the native liveness extension, the exit adapter and
tier 1a's materialization all go through `exitSnapIdx` and
`exitAttachable`. `guard_string` joined `isSideExitGuardOp`: it is the
string twin of `guard_table` (the subtype pin behind a `.heap` load), was
left out when it only ever pinned loop-invariant slots, and a table in a
string's place exits there.

**Soundness.** An attachable exit resumes tier 0 (or a child) at its
bytecode `B` from `B`'s boundary snapshot (doc 56 §4.1). For a load:

- the snapshot is `B`'s boundary state whenever it is committed inside
  `B` (`noteSlotWrite` saves a slot's boundary binding before the first
  write), so letting the load commit it changes nothing it holds;
- every ref it holds is bound before `B`'s first op, so before the load;
  finalize's `refsDefinedAt` now checks that for loads as it does for
  guards;
- both executors check the tag before they write anything: native code
  compares and branches before the payload move, in all three emitters,
  and tier 1a tests before it sets `values[i]`. The trace state at the
  exit is the state before the load;
- rules 6 and 7 of `trace_exit_attach` (no effect of `B` before the exit,
  only modelled stores of earlier bytecodes after it) are per exit and
  apply unchanged;
- a hoisted load loses its ordinal in `tropt` like any hoisted exit and
  never looks attachable;
- the rooting sites and `exitSnapIdx` use one predicate, so a snapshot an
  exit can reach is always rooted and kept.

**Progress.** The child starts at `B` with the other type in the slot
and records its own typed load, which is a side exit in turn. A site that
sees k types gets at most k − 1 continuations down the chain, bounded by
the limits every exit has (`hotexit`, `tryside`, the per-anchor trace
cap); a megamorphic site gives up like any exit that cannot be served.

**Measured** (3 M iterations, instructions, before = Phase 2):

| loop body | tier 0 | JIT before | JIT after |
|---|---|---|---|
| `acc = acc + mixed[i % 4 + 1]`, `{ 1, 2.5, 3, 4.5 }` | 897 M | 3,030 M | 423 M |
| the same over `{ 1, {}, 3, {} }` behind `type(v) == "number"` | 1,431 M | 3,541 M | 944 M |
| `acc = acc + objs[i % 2 + 1].v`, `v` an int or a float | 1,113 M | 3,202 M | 750 M |
| `if flags[i % 4 + 1] then …`, `{ true, 1, false, 2 }` | 904 M | 6,958 M | 536 M |
| `acc = acc + #mixed[i % 4 + 1]`, strings and tables | 984 M | 3,115 M | 473 M |

`--jit-stats` on the first row now reads `exit side: wants=1 records=1
binds=1`, all iterations traced.

The board with the JIT on: geomean +0.012% over 61 rows, largest
meta_fields +0.18% and ray +0.13%. No row has a load whose type
alternates. The cost is not in the traces' bodies: a disassembly diff of
meta_fields' seven traces is five more exit stubs and no body
instruction. It comes to about six instructions per native entry, and it
moves with the shape of the predicate (written as one switch it was
+0.29% on meta_fields), which points at the compiler's inlining around
the dispatcher and not at work the change added.

**Tier 1a alone got slower on these loops** (first row 5,658 M to
7,562 M): it records the continuation and runs it at tier-1a speed. That
is where it stood before Phase 2 (8,070 M), when it exited at the guard
behind an element load.

**A test changed.** "phase Q: link peels end linked, one-trip,
type-mismatched and rewound" produced its type mismatch from rows whose
elements were ints in a float array. Those rows now leave through the
load's exit and get a continuation, so no peel ever sees them; the
mismatch now comes from a local that is an int on every seventh row.

**What it does not cover**, each measured the same way:

- **The load is the loop's first bytecode** (`acc = acc + x`, `x` a
  closed upvalue whose type alternates: tier 0 993 M, JIT 3,305 M). Its
  resume pc is the loop header, which rule 8 refuses (the child would be
  the loop's root), and every entry completes an iteration, so
  `noteTakenExit` raises no sibling want either. The same holds for any
  exit of a loop's first bytecode; loads are not special.
- **The continuation's first recording aborts for a retry** (the same
  loop with the read second: 927 M, 3,287 M). The continuation reads the
  cell and then stores to it, which aborts `.upvalue_mutable` and
  memoizes the anchor for a retry. The record gate bars the anchor for
  256 ticks; the exit gives up after `tryside` (4) more firings. LuaJIT
  counts attempts there, not firings.
- **`guard_sid`** (`string.find(s, pats[i % 2 + 1], 1, true)`: 2,415 M,
  4,454 M). Q3.
- **`type(v)` of a string** aborts `bad_type` (strings and ints mixed:
  1,502 M, 3,705 M). A recorder gap, noted in `TODO.md`.

  *Follow-up, 2026-11-11:* closed. `recBType` and `recBMType` shared one
  heap switch with arms for a table, a native and a closure; it is now
  `pinHeapTypeOf`, with a string arm that pins `guard_string` (nothing
  for a proven producer such as `tostr_int`; tropt's dedup drops the pin
  behind a string load's own). The answer never consults a metatable, so
  the heap-type check is the whole fact. The mixed probe runs 935 M: the
  string rows are the root trace and the int rows leave through the
  load's exit into a continuation (§5.3). Board unchanged (no row calls
  `type` on a string in a hot loop).

## 6. Phase 3 — `math.abs`, `math.min`, `math.max`

Tier-0 semantics (`src/stdlib/math.zig`): `abs` keeps the subtype, and
integer `abs(mininteger)` wraps to `mininteger`; `max`/`min` scan left to
right and replace the running best only when the next argument is
strictly beyond it, so ties keep the earlier argument and its subtype, a
NaN never replaces and is never replaced, and the result's subtype is the
chosen argument's. They are `FastBuiltin`s at tier 0 (doc 70) and have no
`RecordedBuiltin` tag, so a call is a host barrier in a function trace
and a `call_host` in a precise loop root.

The arm's shape is Q1. Whatever is chosen: new `RecordedBuiltin` ordinals
are appended (26, 27, 28), the inventory rows do not change status (the
functions are already implemented), and a mixed int/float pair has a
result whose subtype depends on the values, so it either specialises on
the observed choice behind a guard or stays a barrier.

## 7. Phase 4 — the board row

One program in the script idiom: qualified `math.*` and `string.*` calls
in loops and in small functions, string fields read off records, string
elements read out of an array. It must be valid for LuaJIT so the
hashgate's cross-check applies. `globals_script` stays as it is; it
measures globals, and this row measures library calls and heap loads.

### 7.1 The program (2026-11-11)

`bench/records_script.lua`, 20,000 rounds. An inventory of 64 records
built from a hand-written catalogue (so `weight` is an integer in one
record and a fraction in the next), and six passes per round, each a
small function with a loop over a small collection:

| pass | what it does |
|---|---|
| `carried` | sums `item.weight * item.qty`, then `math.floor` |
| `owed` | `rules[item.kind]` (a table found by a string key), `math.floor(price * qty * rule.rate)`, and `rule.bonus(item)` (one of four closures) |
| `tags` | `string.upper(string.sub(item.name, 1, 3))`, `#item.name`, `#rules[item.kind].label` |
| `count` | `item.kind == kind` on two strings, else `item.magic` (a bool) |
| `configured` | `weigh(v)` over a list of numbers, strings, bools and a table, behind `type(v)` |
| `refine` | three closures in an array, called in order |

It was written as a script would be and then measured, not shaped to
what records. `string.byte` is not in mahina (doc 06), so the tag pass
uses `string.upper`.

### 7.2 Baseline, and what it shows

Instructions (`instructions:u`), 20,000 rounds, at b835226:

| | instructions | against tier 0 |
|---|---|---|
| tier 0 | 5,561 M | |
| `--trace` (tier-1a only) | 12,520 M | 2.25x |
| `--trace --jit-native` | 9,300 M | 1.67x |
| LuaJIT | 853 M | 0.15x |

The same JIT run at each step of this doc:

| binary | instructions |
|---|---|
| 54b0a62 (before Phase 1) | 7,317 M |
| 7ed7ff0 (Phase 1) | 7,825 M |
| 693ffaa (Phase 2) | 8,719 M |
| 78cbca7 (typed-load exits) | 9,337 M |
| b835226 (`type()` of a string) | 9,300 M |

So on this program every phase made the JIT slower. Before Phase 1 the
loops aborted at their first string or native load and ran on tier 0
behind a bar; now three of the six record and cost more than tier 0 did.

Each pass alone (5,000 rounds, a scratch copy of the program that runs
one pass per round):

| pass | tier 0 | JIT at 54b0a62 | JIT at b835226 | LuaJIT | what happens with the JIT |
|---|---|---|---|---|---|
| `carried` | 141 M | 152 M | 279 M | 9.8 M | records, with a continuation at the `weight` load; 55% of its cycles are the ledger seam |
| `owed` | 501 M | 819 M | 892 M | 81 M | the loop aborts (`bad_type get_index`); the four `bonus` closures are head traces entered from tier 0, 320k times at ~375 cycles |
| `tags` | 610 M | 620 M | 621 M | 113 M | the loop aborts (`bad_type get_index`) |
| `count` | 132 M | 145 M | 145 M | 15 M | the loop aborts (`bad_type jeq`) |
| `configured` | 46 M | 130 M | 221 M | 6.8 M | records; five types in eight elements, ~1,300 cycles per traced iteration against 267 on tier 0 |
| `refine` | 19 M | 46 M | 61 M | 2.0 M | a three-trip loop: 0.2% of its iterations run in its loop trace |

Four causes, none of them a missing recorder arm for a library call:

1. **A loop that runs a few dozen iterations per call never goes
   silent.** `carried` is one root trace and one continuation, armed and
   fused (84,970 native hops in 5,000 calls, `yields=0`), in a region
   minted `armable=true`. Every hop writes ledger rows. Promotion
   to a silent set needs `promote_after` (4) full-cap ledgers in a row,
   and the streak is per activation: one call of `carried` fills one
   ledger, the loop exits, the region closes. `silent: candidates=298
   promotions=0` over 300 calls, with every reject counter at zero. So
   each call pays two ledger walks at ~4,100 cycles. The same cycle in
   one long loop (§5.3's probes) promotes after four ledgers and its
   seam is 3.9%. This is Rule Z-8's layer 2, and the cousin of
   `TODO.md`'s "a nested `while` goes silent late on a short run".
2. **A small function called from a loop that does not trace is a head
   trace entered once per call** (`owed`'s closures; doc 84's subject).
3. **A table found by a string key that is not a constant does not
   record** (`rules[item.kind]`: `bad_type get_index`), nor does `==` on
   two strings (`bad_type jeq`, §2.2), nor `#t` on a `.value`-lane array
   (`recAlenShape` takes scalar lanes only, so an array of tables,
   strings, closures or mixed values is `bad_type len`, §2.2). The last
   one stops the program's outer loop and all six functions' heads at
   their `for i = 1, #list`. (`#t` records since §7.3.)
4. **A short loop in a function is entered from tier 0 on every call.**
   LuaJIT records the caller's loop through the call and the inner loop;
   here the outer loop does not record (cause 3), so each inner loop
   pays an entry and an exit per call (`TODO.md`, "a short loop in a
   function called from a loop"). (Corrected in §7.3: LuaJIT's trace
   log shows no trace for the caller's loop. Its inner loops are roots
   and their exits link them through the caller.)

The probes this doc used (§2.1, §5.3) were single loops of three million
iterations. They measured the trace body and missed all four.

### 7.3 `#t` on an in-band lane (2026-11-11)

Taken first of §7.2's causes because it stood in front of the others:
every function in the row starts `for i = 1, #list`, so no recording
that came from outside a loop got past the first line. The ask about
which cause to take went unanswered.

**What was built.** `alen` answers exactly tier 0's fast case,
`Table.lengthFast`: not a grid, hash part empty, and `asize ≤ 1` (0) or
slot `asize − 1` occupied (`asize − 1`). Until now it took only the
lanes that keep a presence bitmap. How "occupied" is read is the one
thing that differs by lane, so the op carries an `AlenProbe` in `b`:
`bitmap` (the scalar lanes; ordinal 0, what the op carried before),
`value` (the element's tag is not nil) and `boolean` (the element's byte
is not 0). `recAlenShape` records when the lane has a probe and
`lengthFast()` answers at record time. Tier 1a calls `lengthFast` behind
a check that the table's lane is still in the recorded probe's class;
native compares the lane byte and reads the tag at `data + 16·(asize−1)`
or the byte at `data + (asize−1)`. A failed check is the op's side exit,
as before.

The sunk-store argument (doc 24 D7) carries over: a pending store
cannot empty a slot on any lane (a nil store aborts the recording; a
recorded store pins its value's type, int or float on `.value`,
`guard_fits` elsewhere), so the op read before the flush either gives
tier 0's answer or leaves.

Tests, in `src/interp_trace_test.zig`: `#t` of an array of tables in a
`while` condition, of strings, of booleans, of a list of records in a
function called from a loop; the border moving under a compiled trace
(last slot emptied, then the hash part filled) on the value lane and on
the boolean lane; a boolean-lane recording whose array widens to the
value lane with the last slot empty (16 elements, so the byte the
boolean probe would read is element 1's tag); a scalar lane widening to
the value lane. In `src/trace_record_test.zig`: the probe recorded per
lane, and the abort matrix with a value-lane trailing nil. Three mutants
of the native arm (value probe without its exit, boolean probe without
its exit, no lane check on the in-band probes) each fail one test.

**Measured** (instructions, `--trace --jit-native`, 2e0b2fd against
2e0b2fd with this):

| row | before | after | |
|---|---|---|---|
| meta_fields | 2,236 M | 1,344 M | −39.9% |
| globals_script | | | −0.27% |
| records_script | 9,299.6 M | 9,300.7 M | +0.01% |

Every other row is within ±0.05% (proc_pipe counts a child process and
differs between two runs of one binary). meta_fields' inner
`for i = 1, #ps` over an array of tables records now: 65.8% of the run
in traces before, 90.5% after. `bad_type len` aborts over the board:
169 to 46. The 46 are globals_script and tbl_stack, both after
`t[#t] = nil`, which leaves a nil in the last slot so the fast case does
not hold (`TODO.md`, "A popping loop never traces").

Each pass alone, as in §7.2 (5,000 rounds, JIT):

| pass | before | after | LuaJIT |
|---|---|---|---|
| `carried` | 279 M | 280 M | 9.8 M |
| `owed` | 892 M | 892 M | 81 M |
| `tags` | 620 M | 621 M | 113 M |
| `count` | 145 M | 145 M | 15 M |
| `configured` | 220 M | 9 M | 6.8 M |
| `refine` | 61 M | 4 M | 2.0 M |

**Why two passes fall by 24 and 15 times alone and the row does not
move.** In the scratch copy the round runs one pass. The `for round`
loop then records through the call, and the callee's loop is unrolled
inside it (8 and 3 trips, under `loopunroll`'s 15): one trace holds the
whole round. In the full program the same recording reaches `carried`
first, and its loop runs 64 trips: `loop_unroll` at 389 IR, six times,
and the anchor is barred. With the outer loop gone, the abort table
after this change is:

| recording | stops at | reason |
|---|---|---|
| main's `for round` (root) | `carried`'s loop, inlined | `loop_unroll` |
| the continuation after each of main's first five calls (`.cont`) | the next callee's loop | `cont_backedge` |
| the continuation after `refine` returns (`.cont`) | main's own back-edge | `cont_backedge` |
| each function's head (`.head`), six | its own `for_prep` | `nyi_opcode` (LINNER) |
| a recording that runs off the end of `configured`'s or `refine`'s loop | the function's `ret` | `cross_frame` |
| `owed`, `tags`, `count` loops | as §7.2 | `bad_type get_index`, `jeq` |

**What LuaJIT does with it** (`luajit -jv`, 29 traces). Its roots are
the four loops in `carried`, `owed`, `tags` and `count`. There is no
trace for main's loop, nor for `configured`'s or `refine`'s. Each
loop's exit grows a side trace that returns into main, runs main's code
up to the next call, enters the callee and links to that callee's loop:
`25 (3/3) :112 -> 4` (`carried` to `owed`), `28 (13/3) :123 -> 5`
(`owed` to `tags`), `27 (5/3) :134 -> 6` (`tags` to `count`), and
`10 (6/1) :143 -> 3`, which leaves `count`, carries `configured` and
`refine` unrolled (8 and 3 trips), main's back-edge and the call of
`carried`, and links to `carried`'s loop. The program is a ring of four
loop traces and never leaves native code. Two mechanisms make the ring:
a side trace that returns below the frame it started in
(`lj_record_ret`: `J->retdepth`, a guard on the return address), and a
side trace that links to a root from any frame depth (`rec_loop_jit`,
`LJ_TRLINK_ROOT`). A root that reaches an inner loop aborts there too
(`LJ_TRERR_LINNER`), so the function-head aborts above are not the
difference.

Here the first mechanism is the `cross_frame` abort, and the second is
`recForPrepLink`'s depth rule: a link's target is resolved in the
anchor's proto, so a recording inside an inlined call can only unroll
the loop it meets. Doc 44's frame links (`ret_cont`, `call_head`) are
the nearest machinery; this run has `ret-cont arms=0`, `call-head
arms=0`.

So cause 4 of §7.2 said the wrong thing about LuaJIT, and the cause is
wider than "a short loop": no loop in a called function is joined to
anything outside that function, whatever its trip count. That is a
design of its own, not a phase of this doc.

## 8. Open questions for review

**Q1 — how `abs`/`min`/`max` record.**

- (a) Dedicated IR ops, typed int or float, lowered branch-free (`neg` +
  `cmov`; `cmp` + `cmov`; `andpd`; `minsd`/`maxsd` with the operand order
  that reproduces the tie and NaN rules). New wire numbers, `irinterp`
  arms, optimiser rows, viz enums. A mixed pair needs a second mechanism
  (a guard on the observed choice) or stays a barrier. This is LuaJIT's
  shape.
- (b) Existing ops only: record the comparison and a guard on its observed
  outcome, and the result is whichever operand ref was chosen. No new IR,
  and mixed pairs come for free. A result that flips often (`abs` of a
  difference of positions flips about half the time) side-exits on every
  flip, and the two directions become sibling traces.
- (c) (a) for same-typed operands and (b) for mixed pairs.

**Q2 — whether the module-table load chain is hoisted.**

- (a) Leave it per iteration (§4.3). Nothing more to build.
- (b) Hoist an `hload` and its guards into the run-once region when the
  trace has no store that can alias the cell and no call that can run
  guest code. This is the general "loop-invariant load" pass, of use to
  every invariant field read, and is its own piece of work in the
  optimiser.
- Measure first: the per-iteration cost after Phase 1 against the hoisted
  local, on the probes in §2.1.

**Q3 — does `guard_sid` join the side-exit guards?** It pins the identity
of an observed pattern string (doc 30 §2a). Doc 30's review (M02) pinned
it out of `isSideExitGuardOp`, with a test, on the grounds that its `aux`
is a konst id and not a PC. That was the test for exit-PC chaining; doc
56's exits resume from a snapshot and need no PC. Today a pattern that
alternates between two strings exits at `guard_sid` on every other
iteration with no way to get a second trace (§5.3: 4,454 M against
2,415 M on tier 0).

- (a) Leave it: the stance stays as reviewed.
- (b) Add it, as §5.3 did for `guard_string`: the alternate pattern
  records as a continuation. Costs a snapshot root at each such guard.

## 9. References

- `src/trace_recorder.zig`: `hashGetShape`, `arrayGetShape`, `recCall`,
  `recHostCall`, `guardBuiltinCallee`.
- `src/nativegen_prove.zig` (Pass A and Pass B arms for `guard_func`,
  `guard_builtin`, `guard_string`, `guard_sid`, `hload`),
  `src/nativegen.zig` (the `guard_builtin` prologue, the dynamic
  `guard_func`), `src/nativegen_alloc.zig` (`HomeReads.readA`, the
  may-exit-in-body table).
- LuaJIT: `lj_record.c` (`rec_idx_key`, `rec_call_setup`),
  `lj_ffrecord.c` (`recff_math_abs`, `recff_math_minmax`).
- Docs 11, 12, 23, 32, 43, 63, 70.
