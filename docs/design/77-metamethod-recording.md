# 77 — Recording metamethods — Design

Status: designed, reviewed (Codex and Antigravity, 2026-11-01), Q1–Q5
decided; Phases 0 and 1 landed (2026-11-11); Phases 2–7 outstanding
(doc 68 P2, which Phase 4 waits on, has landed)
Owner: Bart
Last updated: 2026-11-11

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole phases to Done once everything inside them is checked.

### Done

- [x] **Phase 0 — baselines and the nested-recording probe** (§10,
  2026-11-11).
  - [x] bench programs that use metatables: `bench/luajit/ray.lua`
    (LuaJIT's; its pixels feed a checksum, since `string.char` writes UTF-8
    here), `bench/meta_ops.lua` (in-place `__add`, `__lt`/`__le`/`__eq`/
    `__unm` on a field), `bench/meta_proxy.lua` (`__index`/`__newindex`
    functions over upvalues), `bench/meta_close_reused.lua` (one `<close>`
    value reused; `bench/stdlib/meta_close.lua` from doc 68 allocates one
    per iteration), and, beyond the plan, `bench/meta_fields.lua` (present-key
    reads and overwrites on objects with a class metatable, Phase 1's own
    target). `bench/stdlib/meta_calls.lua` (doc 68) and
    `bench/opprobe/fields.lua` are regression cases. Local numbers and
    aborts in §10.1; hashgate rows added.
  - [x] the probe. Doc 68 P2 landed after this doc was written: tier 0 now
    runs a Lua metamethod as a `.finish_op` frame in the same dispatch
    (`pushMetaFrame`), not through a nested `callValue`, so the mirror sees
    the handler's instructions as an ordinary frame's. Doc 82 Phase 3
    records exactly that path for `__tostring`, and its test (`[REQ-115.1]`
    in `src/interp_template_test.zig`) is the probe: the handler is
    inlined at inline depth 1 and the trace runs. `pushMetaFrame`'s
    `bumpHostEpoch` matters to a recording only while a host call's results
    are pending (`recHostResults`), which a metamethod frame cannot
    interleave with.

- [x] **Phase 1 — tables that carry a metatable, on their raw paths** (§4,
  §5, 2026-11-11).
  - [x] `guard_table` aux bit `GUARD_TABLE_ANY_META` (Q4: merged with AND,
    the writable bit with OR), in tier-1a, native and tropt
    (`tropt.mergeTableGuardAux`). The native prologue skips its metatable
    check for a slot table only when every guard on it carries the bit
    (`SlotInfo.meta_ok`).
  - [x] the metatable refusals in `guard_absent` (tier-1a `isAbsent` and
    the native int-key path), tier-1a `guard_hash` and native hash-cell
    entry seeding (`seedHashCell`) are gone; `guard_table` is the only
    metatable check on a trace. A test pins that a present field of a slot
    table with a metatable is seeded and read natively
    (`seed_hash_declines` stays 0).
    `trace_finalize` asserts in safety builds that every table a
    `guard_absent`, `href` or `guard_hash` reaches is a `load_meta` result
    or has an earlier `guard_table`.
  - [x] IR op `load_meta` (wire 104), tier-1a and native, with a fused
    exit (decision note below)
  - [x] metamethod lookup (`guardNoMetamethod` in `trace_recorder.zig`):
    the interned name, then `load_meta`, then `forwardPendingHashLoad`,
    then `guard_absent`; a metamethod that is present aborts
    `has_metatable` (Phases 3 and 4)
  - [x] present-key reads on hash fields, array slots and table fields;
    absent reads with no `__index`; overwrites of present hash fields and
    present array slots (with a `guard_present`). Not covered: `.value`-lane
    overwrites and appends, which still abort. A grid never has a metatable
    (decision note below).
  - [x] `#t` (no `__len`: `guardNoMetamethod` then `alen`), `type(t)`,
    `math.type(t)`, `rawequal`, `rawget`/`rawset`/`rawlen` (raw frames:
    no metamethod proof) and the generic-for control (§5.4)
  - [x] the §9.2 gates for these paths, in `src/interp_meta_trace_test.zig`
    (all ten `expectProgram` legs, so both GC disciplines): a metatable on
    the metatable, frozen receivers, stores into the metatable inside the
    loop, `setmetatable` between entries, `__index`/`__len`/`__newindex`
    appearing later. §4.2 is pinned by a test that `setmetatable` has no
    `recorded` arm.

### Outstanding

- [ ] **Phase 0 numbers on the board** (the pinned pool): needs a push, then
  `gt profile`.
- [ ] **Phase 2 — invariant lookups leave the loop body** (§5.5): the
  metatable pointer as an invariant field only `setmetatable` writes, and
  the lookup chain of an invariant receiver evaluated once per entry;
  measured in emitted probes per iteration.
- [ ] **Phase 3 — `__index` and `__newindex` tables** (§6.2): chains of
  table hops, bounded deterministically.
- [ ] **Phase 4 — function metamethods as inlined calls** (§6). Starts
  after doc 68 P2 (Q1).
  - [ ] doc 68 P2 landed: tier 0 runs metamethods as continuation frames,
    and §6.3's pending-instruction stages mirror its `finish_op` stages
  - [ ] the pending-instruction stack (§6.3) and its stage transitions
  - [ ] the per-route exit contract (§7), with its exclusions tested
  - [ ] computed-callee upvalue access (§6.6)
  - [ ] `__index`/`__newindex` functions
  - [ ] arithmetic, `__unm`, bitwise, `__bnot`
  - [ ] `__len`, `__eq`, `__lt`, `__le`, the compare-and-branch forms (§6.4)
  - [ ] `__call` (§6.7)
- [ ] **Phase 5 — `__close`** (§8): doc 76's Phase 3b, with the
  "closes done, return only" completion.
- [ ] **Phase 6 — doc amendments** (§9.3): doc 61 §2 and F3, the
  `nativegen.zig` prologue argument, doc 10's non-goal, doc 68 §4.6, doc 23,
  TODO.md's `guard_no_metatable` entry.
- [ ] **Phase 7 — measured** (§10): the Phase 0 programs after each phase,
  and `just bench` on the pinned pool.
- [ ] **Defer — allocating handlers** (Q5, §2.1): doc 78 (allocation in
  inlined calls), parked.
- [ ] **Defer — hash insertion on trace.** An absent string-key store
  aborts today, metatable or not (§5.3).
- [ ] **Defer — `__concat`.** `concat` itself does not record yet.
- [ ] **Defer — `__tostring` and other library metamethods** (doc 23).
- [ ] **Defer — native metamethods without a recorded-builtin tag**, and
  native-valued handler fields (§6.6).
- [ ] **Defer — metamethods of strings, files and other non-table values.**
- [x] **Q1 decided** (Bart, 2026-11-01): doc 68 P2 before Phase 4.
- [x] **Q2 decided** (Bart, 2026-11-02): `MAX_INDEX_CHAIN = 100`, as LuaJIT.
- [x] **Q3 decided** (Bart, 2026-11-02): the computed-callee route by
  access path.
- [x] **Q4 decided** (Bart, 2026-11-02): a "metatable allowed" bit, merged
  with AND.
- [x] **Q5 decided** (Bart, 2026-11-02): (a), allocation-free handlers;
  allocation in inlined calls is doc 78, written and parked.

## 1. Why this exists

Every table that carries a metatable stops a recording today. The recorder
aborts with `has_metatable` at fourteen sites (`trace_recorder.zig`: the
array, hash and grid shapes, `#`, `type`, `math.type`, `rawequal`, the gmatch
state, the generic-for control), with `bad_type` on arithmetic and
comparison operands that are not numbers, and with `cross_frame` on a call
of a non-function. So any loop that touches an object built the usual Lua
way, a table whose metatable's `__index` is its class, runs on tier 0,
however simple the loop is. That is most object-oriented Lua. None of it is
in the pinned benchmark pool, so the gap has never shown on the board; the
only metatable program in `bench/` is the diagnostic probe
`bench/opprobe/fields.lua`.

Doc 76's Phase 3b (record a `__close` call instead of aborting) is the
immediate trigger: a `__close` is a metamethod call, and no trace makes one.
Solving it for `__close` alone would build machinery that the general case
replaces, so this doc solves metamethods in general and makes `__close` one
consumer of it (§8).

LuaJIT records all of this (`lj_record.c`: `lj_record_mm_lookup`,
`rec_mm_arith`, `lj_record_idx`, ...). This doc follows its model: a lookup
is a guarded read of the metatable, a function metamethod is an inlined call
under a continuation. It departs from it where mahina's trace model differs:
a handler's own exits replay the iteration, so no continuation frame appears
in a snapshot (§7).

## 2. Goals

- A loop over objects that use metatables records and runs natively:
  class method lookup through `__index` tables, field reads and overwrites
  on objects with a metatable, operator metamethods whose handlers do not
  allocate, proxies with `__index`/`__newindex` functions, callable tables,
  and `<close>` values with a `__close`.
- One lookup mechanism for every metamethod: a guarded table read on the
  metatable through the recorder's existing hash shapes and forwarding.
- One call mechanism: a function metamethod is an inlined call through the
  existing inlining path, driven by a stack of pending instructions (§6.3).
- No cost to code without metatables: the metatable-free `guard_table` stays
  the one prologue check it is today, and a program that never sees a
  metatable compiles to byte-identical IR.
- Determinism: no addresses in any tiering decision; identities are
  `GcHeader.id`.

### 2.1 What v1 does not reach

The conventional value-type operator allocates:
`function V.__add(a, b) return setmetatable({x = a.x + b.x}, V) end`. Two
independent barriers stop it: `new_table` records only in precise mode, and
precise mode refuses inlining (`trace_recorder.zig` ~1889, ~4572); and
`setmetatable` is untagged, so it aborts `host_barrier`. That is a coverage
limit of the inlining model, not of this doc's metamethod work. v1 covers
handlers that do not build tables (in-place updates, accessors, proxies,
comparisons on fields, `__close`), and its benchmarks say so rather than
substitute an allocation-free handler for the conventional one. Q5
(decided) leaves that to doc 78, which covers allocation in every inlined
call.

## Non-goals

- Changing tier-0's metamethod dispatch (but see Q1).
- A negative metamethod cache (LuaJIT's `nomm`). LuaJIT's recorder never
  reads `nomm` either; a tier-0 cache is a separate TODO.md item.
- Metamethods in precise recordings, beyond what Q5 decides.

## 3. What exists

**Inlining.** `recCall` inlines a fixed-arity, non-vararg Lua closure up to
`MAX_INLINE_DEPTH = 3`: one `guard_func` on the callee (aux = proto id), the
callee's slots seeded as SSA values, an `InlineFrame` on a recorder-only
stack. `recReturn` copies the result refs into the caller's destination
slots. No frame is pushed in IR. Callee upvalues go through
`callee_upvalue` seeds, which find the closure through the caller's
`ret_dest` register and need it to be a `slot_load` (~6080); the seed is
resolved at trace entry from `base + seed.callee_slot` (`interp.zig` ~1823).

**Exits.** An exit taken inside an inlined callee is coarse: no exit
snapshot is captured at inline depth > 0 (`trace_recorder.zig` ~1483,
~1503), doc 56 attachment refuses inline provenance
(`trace_exit_attach.zig` ~363), composite bridges need non-inlined
provenance (`trace_link.zig` ~1203), and sibling handoff needs a pre-effect
exit (`trace.zig` ~1876). Tier 0 re-runs the activation from its anchor
(the loop header, `FUNC_HEAD_PC` for `.head`, `resume_pc` for `.cont`) and
so re-executes the real call. Other exits are not coarse: exit-side
adapters resume at a bytecode boundary (`nativegen.zig` ~2858), linked loop
completion commits the final iteration (~2987), and one-shot return
terminals resume tier 0 at the return instruction after committing the
trace's stores (`irinterp.zig` ~1501).

**Recording follows tier-0.** The recording mirror runs in the dispatch
prologue before tier-0 executes each instruction (`interp.zig` ~5697,
`recordInstr`). It sits in the shared `execImpl`, and recording forces
`.full`, so a nested `execWithEntry` (what `callValue` runs for a Lua
metamethod) passes through it too; ordinary recording has no general
epoch-change abort (both reviews confirmed). Today this never matters: the
recorder aborts before tier-0 runs the instruction that would make the call.

**Tables.** `guard_table` means "a heap table with no metatable"; aux
`GUARD_TABLE_WRITABLE` adds "not frozen". For a slot-rooted invariant table
it is hoisted into the native prologue, argued sound because "a metamethod
call is a trace barrier, so the metatable cannot change within a single
native run" (`nativegen.zig` ~1072). The same assumption sits, separately,
in `guard_absent` (tier-1a `table_runtime.isAbsent`; native int-key path
`nativegen_emit.zig` ~2546), tier-1a `guard_hash` (`irinterp.zig` ~779) and
native hash-cell entry seeding (`interp.zig` ~1994). No IR op loads a
metatable or guards one's identity.

**The optimizer.** tropt leaves memory loads uncombined (`tropt.zig` ~603)
and never hoists memory operations or guards (~724). Load/store forwarding
of hash fields lives in the recorder (`forwardPendingHashLoad`,
`trace_recorder.zig` ~2719). Any lookup this doc emits therefore runs every
iteration unless Phase 2 makes it otherwise.

**Tier-0.** `Vm.metamethod(v, name)` is `metatableOf(v)` then one hash probe
for the interned name. `indexGet`/`indexSet` follow `__index`/`__newindex`
table chains (up to 2000 hops) and call a function handler through
`callValue`; `callMeta` does the same for arithmetic, comparison, `__len`,
`__concat`; `.call` runs `__call` through `callValue` too; `callClose` runs
a protected `callValue` for `__close`, and `closeFrameVars` runs several in
one instruction.

## 4. The receiver guard (D2)

### 4.1 ANY_META and the other refusals

`guard_table` keeps its meaning. A new aux bit, `GUARD_TABLE_ANY_META`,
drops the metatable half: the value is a heap table, metatable or not. The
recorder sets it only on paths that look at the metatable or do not care
about it (§5.3); every other path keeps the metatable-free guard, so a loop
that never sees a metatable compiles exactly as today. tropt's per-table
merge (one `guard_table` per table, doc 76 6b64d10) must keep the stricter
requirement: the merged guard allows a metatable only if every guard on that
table did. The bit means "metatable allowed" and merges with AND (Q4, decided), so an
aux-0 guard keeps meaning "no metatable".

The metatable refusals outside `guard_table` move to it, so that each guard
proves one thing:

| check | today | after |
|---|---|---|
| `guard_absent`, tier-1a (`isAbsent`) | key absent and no metatable | key absent |
| `guard_absent`, native int-key (`nativegen_emit.zig` ~2546) | the same, inline | key absent |
| `guard_hash`, tier-1a (`irinterp.zig` ~779) | shape and no metatable | shape |
| hash-cell entry seeding (`interp.zig` ~1994) | refuses a metatable | follows the table's `guard_table` aux |

Each of these is preceded by a `guard_table` on the same table in every
trace that emits it (the recorder emits the table guard first); Phase 1
asserts that at IR verification, so removing the inner check cannot open a
path where nothing checks the metatable.

### 4.2 Nothing on trace sets a metatable (D5)

The hoisted prologue check of a metatable-free table is sound only if
nothing in the trace can give that table a metatable. Today that follows
from "metamethod calls are barriers"; after this doc it follows from:
`setmetatable` is untagged, so no recording calls it, and `Table.metatable`
is not a field any recorded store reaches. Phase 1 states this in
`nativegen.zig` in place of the old argument and pins it with a recorder
assertion (tagging `setmetatable` fails a test until whoever does it
revisits the prologue hoist).

## 5. Lookup: the metatable is a table (D1)

### 5.1 `load_meta`

`load_meta t` is a new IR op: the table's metatable, or nil. Its only writer
is `setmetatable`, which no trace calls (§4.2).

### 5.2 Reading a metamethod

A metamethod lookup on `t` is:

```
mt = load_meta t           ; heap table or nil
     guard_table mt ANY_META   ; non-nil; a metatable may itself have one,
                               ; which is never consulted
h  = <constant-key read mt."__index">
```

The constant-key read is what `get_field` records for a string key
(`hashGetShape`), routed through `forwardPendingHashLoad` first, so a value
the trace stored into the metatable earlier in the iteration is forwarded,
and a store the recorder cannot order (`store_fwd_ambiguity`) aborts as it
does for any other table. A missing key is proved with `guard_absent`. The
function identity comes from the call's guard (§6.6), not from a guard on
the metatable. This is LuaJIT's `lj_record_mm_lookup`: a raw `lj_record_idx`
on the metatable.

`hashGetShape` refuses native-valued fields (~3377); a handler that is a
native (`__index = rawget`) aborts until that is lifted (deferred).

### 5.3 The index paths, and what the shapes can do

Lua consults `__index` only for a key whose raw value is nil, and
`__newindex` only for a store to such a key. Storing nil to a present key
bypasses `__newindex` and deletes it; frozenness is checked at the raw
destination (`interp.zig` ~11879).

| access | at record time | records | shape support today |
|---|---|---|---|
| read | raw non-nil | ANY_META + the present-key read | yes |
| read | raw nil, no `__index` | ANY_META + `guard_absent` + `load_meta` + "no `__index`"; nil | yes, after §4.1 |
| read | raw nil, `__index` table | §6.2 | |
| read | raw nil, `__index` function | §6 | |
| store | raw non-nil (overwrite) | ANY_META + the overwrite, writable bit as today | yes for non-heap values; heap-valued hash stores abort today (~3480) |
| store | raw nil, no `__newindex` | ANY_META + absence + "no `__newindex`" + insert | **no**: hash insertion aborts today, metatable or not (~3490); array append conflicts with a preceding `guard_absent` (~3183, ~2927) — deferred |
| store | raw nil, `__newindex` | §6.2 / §6 | |

A guard on "present" that fails at run time exits; tier 0 re-runs and takes
the metamethod path, and a side or sibling trace picks up the other shape as
for any other shape change.

### 5.4 The other `has_metatable` sites

`type(t)`, `math.type(t)`, `rawequal`, `rawget`/`rawset`/`rawlen` never
consult a metatable: ANY_META, nothing else. `#t` looks up `__len` (§6 when
present; "no `__len`" + `alen` when absent). The generic-for control needs
nothing from the metatable. The gmatch state keeps its guard.

### 5.5 Invariant lookups (Phase 2)

With Phase 1 alone, a class method call `obj:m()` costs a `load_meta`, a
guard and a hash probe per hop on every iteration, even for an invariant
`obj`. Phase 2 makes the invariant case cheap in two steps that keep the two
kinds of memory apart:

- the metatable *pointer* of an invariant table is invariant for a native
  run (§4.2), so `load_meta` of a prologue-guarded table is evaluated once
  in the prologue, like the table's other prologue pins;
- fields *inside* a metatable are ordinary mutable table fields. Their
  lookups move to the prologue only when the trace provably stores to no
  table that could be that metatable (no hash store at all, or stores only
  to tables proven distinct), and stay in the body otherwise.

This is the first memory-load hoisting mahina does, so it lands as its own
phase with its own measurement (emitted probes and callouts per iteration,
not only residency).

## 6. Calls: a metamethod is an inlined call (D3)

### 6.1 Following tier-0 into the call

For a `.call` the recorder sees the instruction and pushes the frame. For a
metamethod, tier-0's `callValue` pushes a frame and runs a nested
`execWithEntry` inside the triggering instruction. So at the triggering
instruction the recorder records the lookup and the handler guard, seeds
the callee's parameters with the argument refs, pushes an `InlineFrame`
whose callee ref is explicit (not derived from `ret_dest`, §6.6), and lets
tier-0 run. The mirror sees the callee's instructions from the nested
dispatch at the pushed depth; the callee's `ret` reaches `recReturn`, which
hands the result to the pending instruction (§6.3). Phase 0 proves this
against the real dispatcher.

### 6.2 Table chains

An `__index` that is a table repeats the access on that table, as
`indexGet` does; `__newindex` tables likewise (the store is re-done on that
table, not raw). The recorder unrolls the chain it observes, one §5.2
lookup per hop, bounded by `MAX_INDEX_CHAIN` (Q2), counted deterministically,
with its own abort reason. `obj:m()` on a class:

```
guard_table obj ANY_META ; guard_absent obj."m"
mt = load_meta obj ; guard_table mt ANY_META
c  = read mt."__index" ; guard_table c ANY_META
f  = read c."m" ; guard on f …
```

### 6.3 The pending-instruction stack

One continuation per frame is not enough: some instructions make several
calls, and some finish in more than one way. `closeFrameVars` runs a
`__close` per open variable inside one `close`/`ret_close`; the fused
`get_index2`/`set_index2` do two index operations in one instruction
(`fusedGet`, `interp.zig` ~11666); a compare-and-branch can take its branch.
The multret shadow is consumed on every mirrored instruction (~1701), so a
pending instruction must carry what it needs itself.

So the recorder keeps a stack of pending instructions. Each entry holds the
triggering instruction's proto, pc and opcode; a stage; the operand and
result refs it saved (including a dynamic result count); and the next
action. A handler's return feeds the top entry, which either finishes the
instruction (writes its destination, emits its branch guard, or does
nothing) or starts its next stage, which may push another call (the next
`__close`, the second index of a fused access). Only when the entry is
finished does the recorder expect the parent's next instruction, which is
`pc + 1` or the branch target. Stages the recorder cannot model abort
explicitly. `recReturn` pops the frame the handler occupied, never a frame
the pending instruction still owns.

| finish | used by | effect |
|---|---|---|
| `result` | `__index` fn, arithmetic, `__unm`, bitwise, `__bnot`, `__len` | first result (or nil) to `R[A]` |
| `none` | `__newindex` fn, each `__close` | results dropped |
| `truthy` | `__eq`, `__lt`, `__le` | the result's truthiness, then the relation's polarity (§6.4) |

### 6.4 Exact call signatures

As tier 0 makes them, so the 8-mode equivalence holds:

- binary arithmetic and bitwise: `h(a, b)` in source order (doc 66 P3),
  constant operands as konst arguments; the first operand's handler, else
  the second's;
- unary `__unm`/`__bnot`: `h(v, v)` (`unMeta`, `interp.zig` ~11411);
- `__len`: `h(t)` as tier 0 does today (one argument; 5.4 passes two,
  TODO.md);
- `__lt`/`__le`: the relation is normalised first: `a > b` is `b < a` and
  `a >= b` is `b <= a`, swapping the arguments (`interp.zig` ~8856; the
  recorder already normalises value comparisons, ~1729). The branch
  polarity of a compare-and-branch is a separate bit (~8851) applied after
  the truthiness;
- `__eq`: only for two tables that are raw-unequal at run time (a runtime
  pointer-inequality guard, not a comparison of SSA refs); the first
  operand's handler, else the second's, which is 5.4's rule
  (`luaV_equalobj`; 5.4 does not require the two handlers to be equal,
  unlike 5.1/LuaJIT); `ne` negates.

### 6.5 Budget

A metamethod call uses one inline level of `MAX_INLINE_DEPTH`, like any
call; deeper nesting aborts `too_deep`.

### 6.6 The handler's identity and upvalues

The handler is a computed value, so its guard is on the loaded ref:
`guard_func` pins the proto, which suffices for a handler without upvalues.
A handler with upvalues (`__index = function(t, k) return defaults[k] end`,
the common case) needs more than an identity guard: `callee_upvalue` seeds
are resolved at entry from a slot, and a loaded closure is in no slot. So
Phase 4 adds computed-callee upvalue access:

- the handler gets a closure-identity guard on its `GcHeader.id`;
- its upvalue reads become loads through the closure ref the trace holds
  (an upvalue-cell load off an SSA closure), not entry seeds; writes go
  through the same path, and the open-slot alias check (~6203) applies to
  the cell it reaches;
- nothing is baked as a constant: trace constants are not GC roots, and
  serialised traces carry only string heap constants (`traceser.zig` ~68).
  A collected handler is a dead dependency and retires the trace the way
  dead constants do today (`interp.zig` ~4043); no trace-only root is added,
  so collection timing and object ids do not change.

The access-path rule (Q3, decided) chooses between them: a callee in a slot
keeps the slot route; any other callee takes this one.

### 6.7 `__call`

`recCall`'s non-function arm looks up `__call` (§5.2), shifts the arguments
up one with the called object first, and inlines the handler. The outer
instruction is a `.call`, so its result window is already the caller's;
tier 0 runs the handler through `callValue`, so the pending-instruction
entry has the `result`-like finish of a call with its result count.

## 7. Exits, by route (D4)

| route | where | contract |
|---|---|---|
| a guard inside the handler | inline depth > 0 | coarse: the activation re-runs from its anchor on tier 0, which makes the real call. No snapshot, no attachment, no bridge, no sibling handoff (all already refused at depth > 0, §3); Phase 4 tests each refusal with a handler |
| a guard of the triggering instruction after a handler returned (result-type guard, branch guard, the next stage's guards) | depth 0, mid-instruction | coarse, never an adapter: resuming at the triggering pc after flushing the handler's stores would run the handler again. The recorder marks these guards non-attachable |
| a guard after the instruction finished | depth 0, a later pc | as today: an adapter may resume there and commits the pending stores, the handler's included, because the instruction completed |
| a one-shot return terminal after closes ran | `ret_close` | §8: "closes done, return only" |
| linked loop completion, region bridges | depth 0 | unchanged; a bridge source with inline provenance is already refused |

So a handler needs no continuation frame in any snapshot, but the
mid-instruction guards need the explicit coarse marking.

## 8. `__close` (doc 76 Phase 3b)

Today `tbc`/`tfor_prep`/`close`/`ret_close` record only while every value
they would close is nil or false. With this doc:

- `tbc` on a closable value records "`__close` present" on its metatable,
  the check tier 0 makes before raising `NonClosable`.
- `close` at a block end or `break` is a pending instruction with one stage
  per open closable value, top first (`closeFrameVars`' order); each stage
  re-reads `__close` (as `callClose` does) and calls it with `(v, nil)`,
  finish `none`. nil/false values only keep their pin.
- `ret_close` is the same, then the return. The return values are computed
  before the closes (doc 76) and saved in the pending entry, dynamic count
  included. The completion must not run the closes twice: today a
  one-shot return terminal resumes tier 0 *at* the return instruction
  (`irinterp.zig` ~1501; native return-pop accepts only `.ret`,
  `nativegen.zig` ~2644), and resuming at `ret_close` would re-run every
  close the trace ran. Phase 5 adds a completion both executors share:
  closes done, perform the return only (a return terminal that resumes
  with the closes marked done, or the return-pop accepting `ret_close`
  once its closes are in the trace). Until that exists, a trace ends before
  a `ret_close` whose closes would run.
- A `__close` that raises exits; tier 0 re-runs and handles the error,
  including the top-level case (98ff883). A `__close` that yields aborts the
  recording as any yield does.

## 9. Invariants, gates and doc amendments

### 9.1 Invariants

- **The doc 61 §2 audit holds as written.** A trace never calls
  `callValue`, a native through the dispatch arm, or a metamethod: it runs
  an inlined copy of the handler's body, and every exit that could need the
  real call replays to tier 0. `in_flight` gains no JIT site; Phase Q's F3
  holds, with doc 63's existing exception for a suspended host call
  (`interp.zig` ~4068) unchanged; (A′)'s "tier 0 is the only executor of a
  `__call`" holds.
- **Nothing on trace sets a metatable** (§4.2).
- **No new GC roots** (§6.6).

### 9.2 Gates

Behaviour, all 8 modes (`expectProgram`'s legs), before any phase is done:
GC during recording; a handler replaced or removed, then collected; two
closures of one proto as handlers; mutable and open upvalues in a handler;
forced exits inside a handler and between stages; replay and keyframe
restore through a handler; `__close` order and errors; a yield refused;
metatables on the metatable; frozen receivers; a store to the metatable
inside the loop.

### 9.3 Doc amendments (Phase 6)

Doc 61 §2/F3 reworded to "never calls" rather than "aborts on"; doc 68
§4.6's "none of the sites is recorded"; doc 10's non-goal on metatable
inlining lifted; doc 23's `has_metatable` remarks; the `nativegen.zig`
comment; TODO.md's `guard_no_metatable` entry subsumed by ANY_META.

## 10. Measurement

Phase 0 lands the programs before any code. Budget: `ray` within 2× of
LuaJIT; the proxy, `<close>` and operator programs native with no
`has_metatable`/`bad_type` aborts in `--dump-aborts` and residency above
90% in `--jit-stats`; the existing pool's IR byte-identical and its times
within noise on the pinned pool. Phase 2 also reports emitted probes and
callouts per iteration for an invariant receiver.

### 10.1 Phase 0 baseline (2026-11-11)

Local machine (load ~4.6 on 24 cores), `bench/run.py`, best of 5, at the
`@bench` sizes; `--dump-aborts` from a `--jit-native` run.

| program | t0 ms | jit ms | LuaJIT ms | res% | aborts |
|---|---|---|---|---|---|
| ray | 462.4 | 1248.3 | 32.3 | 26.3 | 19 sites: `has_metatable` on `get_field` (`intersect`, `sphere_distance`, main), `for_prep` |
| meta_fields | 389.1 | 435.4 | 14.4 | 0.0 | `has_metatable` (`get_index` of an element with a metatable, `get_field` in `step`), `len` |
| meta_ops | 393.0 | 397.2 | 7.0 | 0.0 | `bad_type` on `add` |
| meta_proxy | 302.8 | 301.2 | 13.3 | 0.0 | `has_metatable` on `get_field` |
| meta_close_reused | 407.4 | 420.7 | n/a | 0.0 | `nyi_opcode` on `tbc` |
| meta_calls (doc 68) | 46.8 | 46.9 | 0.9 | 0.0 | `has_metatable` on `get_index` |
| fields.lua `mlook`/`mcall` | | | | | `has_metatable` on `get_field` |

`ray` is 2.7x slower with the JIT than on tier 0: its leaf functions run as
one-shot head traces (213-380 cycles a call) around tier-0 callers that
abort on the class fields. That is doc 84's entry cost plus this doc's
Phases 1 and 3 (TODO.md).

### 10.2 After Phase 1 (2026-11-11)

Same machine and method (load ~3; the `meta_fields` row ~5).

| program | t0 ms | jit ms | LuaJIT ms | res% | remaining aborts |
|---|---|---|---|---|---|
| meta_fields | 384.9 | 92.8 | 15.0 | 65.4 | `bad_type` on `len` (`#ps`, no metatable involved), `needs_precise` on `new_table` |
| ray | 457.2 | 1251.0 | 32.8 | 28.2 | `has_metatable` on method lookups through `__index = self` (Phase 3), `for_prep`, `host_barrier` |
| meta_ops | 404.2 | 418.7 | 7.0 | 0.0 | unchanged (Phase 4) |
| meta_proxy | 297.6 | 301.8 | 13.3 | 0.0 | unchanged (Phase 4) |
| meta_close_reused | 414.5 | 415.6 | n/a | 0.0 | unchanged (Phase 5) |
| meta_calls (doc 68) | 45.9 | 45.2 | 0.9 | 0.0 | unchanged (Phase 4) |

`meta_fields`, Phase 1's own target, went from 435.4 to 92.8 ms with the
JIT (144.8 ms before `seedHashCell` stopped declining a table with a
metatable, which sent every entry of its field loops to tier-1a); the
others wait on later phases.

### 10.3 Phase 1 decision notes (2026-11-11)

- **`load_meta` has a fused exit instead of yielding nil.** §5.1 and §5.2
  specify `load_meta` as "the metatable or nil", followed by a
  `guard_table mt ANY_META`. Phase 1 emits `load_meta` only where the
  recording saw a metatable, so the op exits itself when the metatable is
  gone, and its result is always a table (`.heap` in `nativegen_prove`).
  That removes a guard per lookup and keeps a nil out of the native
  register model. A trace that needs to observe a nil metatable (none in
  Phases 1–4) would add a non-exiting variant.
- **A grid never has a metatable.** `inflateToGrid` declines a table with
  one, and every writer of `Table.metatable` deflates a grid first
  (`setmetatable` through `tableArg`, the C API through `tableOf`, `proc`'s
  fresh tables). The grid shapes keep their `has_metatable` abort, which
  cannot fire, and §5.3's "grid" overwrite row needs no work.
- **`.value`-lane overwrites abort.** nil is in-band in that lane, so the
  overwrite has no presence guard to exit on before a store to a hole
  would call `__newindex`.
- **Absent reads go through `forwardPendingHashLoad` before `guard_absent`
  on the metatable**, as §5.2 asks, so a sunk store of `__index` into the
  metatable earlier in the iteration is forwarded or aborts, never missed.

## 11. Open questions for review

- **Q1 — doc 68 P2 (tier-0 continuation frames) before Phase 4?** Not
  required by the exit contract, but the pending-instruction stages (§6.3)
  are the recorder's mirror of exactly the `finish_op` stages doc 68 P2
  gives tier 0. Codex: P2 first, so the two share one model. Antigravity:
  independent, the wins come sooner. Options: (a) independent; (b) P2
  before Phase 4 (Phases 1–3 need neither).
  **Decided (Bart, 2026-11-01): (b).** Future wins and one maintained
  model matter more than landing the first win sooner. Phase 4's stages
  are built as the recorder's view of doc 68's `finish_op` stages, not as a
  separate scheme.
- **Q2 — `MAX_INDEX_CHAIN`.** Codex: 100, as LuaJIT, bounded additionally by
  the recording length limit, to avoid coverage cliffs. Antigravity: 4,
  since deeper hierarchies are rare and each hop costs guards.
  **Decided (Bart, 2026-11-02): 100, as LuaJIT.** A chain long enough to
  reach it would hit some other limit (the recording length) first anyway.
- **Q3 — when a call uses the computed-callee route.** Both reviewers:
  not for every call. Codex: by access path (the callee is not in a slot),
  not by "loaded from a table". Antigravity: only table-loaded handlers.
  **Decided (Bart, 2026-11-02): by access path.** A callee the trace can
  reach through a slot keeps the slot route and its proto guard; any other
  callee (loaded from a table, an upvalue, a call's result) takes the
  computed route with a closure-identity guard.
- **Q4 — ANY_META encoding.** (a) Codex: a bit meaning "metatable
  allowed", merged with AND while the writable bit keeps OR; existing
  aux-0 guards keep their meaning, so metatable-free IR stays
  byte-identical. (b) Antigravity: a bit meaning "no metatable", so the
  existing OR merge needs no change; every existing metatable-free guard
  then carries the new bit.
  **Decided (Bart, 2026-11-02): (a).** The default must fail safe: a guard
  that omits the bit stays strict, so the worst case is an extra exit, where
  under (b) an omitted bit would let a metatable through and a raw read skip
  its `__index`. It also keeps metatable-free IR byte-identical, so §10's
  unchanged-IR check stays a gate. The cost is a per-bit merge rule in
  tropt (AND for ANY_META, OR for writable), tested in both merge orders.
- **Q5 — allocating handlers in this doc?** (§2.1) (a) v1 as written,
  allocation-free handlers only, precise inlining a later doc; (b) bring
  inlining into precise recordings and a recorded `setmetatable` into this
  doc, so the conventional vector type is covered.
  **Decided (Bart, 2026-11-02): (a).** Allocation inside an inlined call is
  not a metamethod problem (a plain `local function vec(x, y) return {x =
  x, y = y} end` hits the same wall), so it gets one design for every
  inlined call: doc 78, written now and parked until Bart picks it up.

## 12. Review (2026-11-01)

Codex and Antigravity reviewed the first draft. Dispositions:

| finding | by | disposition |
|---|---|---|
| `ret_close`'s return terminal would run the closes twice | Codex (blocker) | §8: the "closes done, return only" completion |
| several calls in one instruction (closes, fused index, branch) break one continuation per frame | both (blocker/major) | §6.3: the pending-instruction stack |
| a computed closure has no upvalue access path; an id guard is not one | both (blocker/major) | §6.6: computed-callee upvalue access |
| "exits need nothing new" is too broad; exits differ by route | both (major) | §7: per-route contract, mid-instruction guards coarse |
| tropt has no memory LICM or alias classes; forwarding is the recorder's | both (major) | §3, §5.2, §5.5: Phase 2, explicit |
| other metatable refusals (`guard_hash`, native absence, entry seeding) | Codex (major) | §4.1 table |
| allocating vector handlers cannot record | Codex (major) | §2.1, Q5 |
| the shapes lack hash insertion, heap-valued stores, native fields, append after absence | both (major/minor) | §5.3 capability column; deferred items |
| `>`/`>=` swap their operands; unary passes `(v, v)`; `__len` one argument | both (major/minor/nit) | §6.4 |
| GC and replay contract for handler dependencies; behavioural gates | Codex (major) | §6.6, §9.2 |
| "no program in `bench/` calls `setmetatable`" is false | Codex (minor) | §1; `fields.lua` reused |
| F3 wording must keep doc 63's suspended-host-call exception | Codex | §9.1 |
| exits replay from the activation anchor, not always the loop header | Antigravity | §3, §7 |
| `__call` runs through `callValue` in tier 0 | Antigravity (nit) | §6.7 |
| 5.4 `__eq` requires equal handlers | Antigravity (minor) | not adopted: 5.4's `luaV_equalobj` takes the first handler, else the second, with no equality test (that is 5.1/LuaJIT); §6.4 |

## References

- LuaJIT `src/lj_record.c`: `lj_record_mm_lookup` (~1088), `rec_mm_prep`
  (~1072), `rec_mm_arith` (~1160), `rec_mm_equal`/`rec_mm_comp`
  (~1230–1308), `lj_record_idx` (~1530), the `frame_iscont` return (~1011),
  `rec_call_setup`'s `__call` (~839); `lj_snap.c` continuation frames.
- Lua 5.4 `lvm.c`: `luaV_equalobj`, `luaV_objlen`.
- Doc 10 (cross-frame tracing), doc 56 (exit attachment), doc 61 §2 /
  Phase Q, doc 63 §5.6 / §5.9, doc 66 P3, doc 68 §3 / §4.6, doc 76 §6.
