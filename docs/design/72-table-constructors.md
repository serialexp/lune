# 72 — Table constructors

Status: partial — §2a and P0–P2 landed; P3 (the recorder) outstanding
Owner: claude (coral-marten)
Last updated: 2026-10-23

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole phases to Done once everything inside them is checked.

### Done

- [x] **Diagnosis** (§2): constructor probes against LuaJIT `-joff`, the
  binary-trees profile.
- [x] **Tier-0 store lanes** (§2a): `set_index`'s append lane (b63a116), a
  narrow array part in one allocation (44e9ac2), and the fresh-table seed
  lane with the append lane inlined. `{i}` 908 → 643, `{i,i,i}` 1506 → 949
  instructions.
- [x] **Q1–Q3 answered** (§7, 2026-10-23): expand, exact capacity, pre-size
  only.
- [x] **P0 — sized `new_table`** (§4.1): `c` = hash entries, the hash part
  allocated at its final size (`HashPart.reserve`, `opNewTableSized`).
  `{x=,y=,z=,w=}` 1823 → 1565 instructions. Narrower than planned: no `b`
  (see "As built").
- [x] **P1 — `set_list`** (§4.2–4.5): a run of positional values stored by one
  instruction, from consecutive registers, into an array part allocated
  once in the lane the sequential stores would have ended on
  (`Table.storeRun`, `ArrayPart.storeRun`). `{i,i,i}` 949 → 798, `{i,t,t}`
  1356 → 702, `{t,t,t}` 880 → 680; binary-trees −13.8% tier-0, −6.6% JIT.
- [x] **P2 — trailing call / `...`** (§4.6): `set_list` with `b =
  all_results`. Fixes TODO.md's `{f()}` truncation (Q1: expand).
- [x] **Liveness: decode the dynamic producers once** (extended beyond the
  plan, §4.6). `compile_multret_chain` −0.9%.

### Outstanding

- [ ] **P3 — the recorder** (§5): `set_list` aborts `nyi_opcode` until doc 45's
  `tset` lands; then it records as a run of `tset`s on the `tnew`.
- [ ] **Defer — template tables** (LuaJIT's `TDUP`, §3): copy a prebuilt table
  for constant fields. Only if a probe shows the named-field constructor
  still matters after P0.

## 1. Why this exists

A table constructor costs mahina two to three times what it costs LuaJIT's
interpreter. Every positional element is a `load_int` of its key and a
`set_index`, and the array part's lane is decided by the first value and
widened by the later ones. `{ item, left, right }` (binary-trees' node)
commits a `u8` lane for `item`, allocates it, then converts the part to
`.value` for `left`: a second allocation, a copy, a free. The conversion
alone is 10% of binary-trees at tier 0.

The JIT records no constructor at all: `set_index` and `set_field` on a fresh
table abort `bad_type` (doc 45 has `tset` outstanding). So a constructor in a
hot loop keeps the loop at tier 0.

This doc is the contract for how a constructor compiles and stores.

## 2. Diagnosis

`bench/opprobe/ctors.lua`, marginal instructions per constructor at tier 0
(`measure.sh`, ReleaseFast), after §2a:

| constructor | mahina | LuaJIT `-joff` |
|---|---|---|
| `{}` | 256 | 418 |
| `{ i }` | 643 | 502 |
| `{ i, i, i }` | 949 | 571 |
| `{ i, t, t }` | 1356 | 571 |
| `{ t, t, t }` | 880 | 571 |
| `{ x = i, y = i }` | 940 | 831 |
| `{ x = i, y = i, z = i, w = i }` | 1826 | 1018 |

An empty table is cheaper than LuaJIT's; each positional element adds about
150 instructions against LuaJIT's 35, a lane change about 400, and each
named field beyond the first two about 440 against about 95.

binary-trees at tier 0 (perf, after §2a): `opCall` 18%, `collect` 15%,
`opNewTable` 11%, `ArrayPart.convert` 10%, `opGetIndex` 8%, `alloc` 7%,
`ArrayPart.deinit` 7%. Nearly all of `opNewTable`, `convert` and `deinit`
sits on the first store into memory just allocated or about to be freed:
binary-trees is bound by allocation traffic. Each node allocates the
table, a `u8` block, then a 128-byte `.value` block for 4 live slots.

### 2a. What landed first

Three changes inside the current shape, each general to every array store:

- An append into allocated capacity takes a cold lane (`opSetIndexAppend`,
  `Table.appendInCap`) instead of `indexSet` → `Table.set` → `append`.
- A narrow lane's presence bitmap shares its data block
  (`ArrayPart.allocStorage`).
- A fresh table's first store at key 0 or 1 takes `opSetIndexSeed`
  (`ArrayPart.seedFresh`: `seedAt`'s end state from one allocation).

They leave the per-element dispatch, the lane conversion and the 8-slot
first capacity, which need the constructor's shape.

## 3. What Lua and LuaJIT do

- **Lua 5.4** (`lparser.c` `constructor`, `lvm.c` `OP_SETLIST`):
  `NEWTABLE` carries the array and hash sizes; positional values accumulate
  in consecutive registers and `SETLIST` stores each batch of 50, the last
  with `C = 0` after a multi-value call or `...`. Keyed fields store as they
  are met, so `{"b", [1] = "a"}` ends with `"b"`.
- **LuaJIT** (`lj_parse.c` `expr_table`): `TNEW` carries the array size
  (min 3) and the hash size's log, so every later store is in bounds. A
  positional element is a `TSETB` (constant index) emitted in order, so
  `{"b", [1] = "a"}` ends with `"a"`. Constant key/value pairs go into a
  template table the constructor copies (`TDUP`). A trailing call or `...`
  is `TSETM`. Small array parts are colocated with the table.

mahina matches LuaJIT today on every observable: `#{1, nil, 3}` is 1 (Lua
5.4: 3), and `{"b", [1] = "a"}` gives `"a"` (Lua 5.4: `"b"`), and a
trailing call or `...` is truncated to one value (both: expanded; §4.6).

## 4. Design

The rule: **a constructor ends in exactly the state its sequential stores
would leave**, apart from the array part's capacity (Q2: exact, `n + 1`
slots) and a trailing call or `...` (Q1: expanded, §4.6). Lane, frozen bit,
`asize`, where each key lives, and `pairs` order are unchanged, so no
program output, keyframe or 8-mode result changes. Only the work does.

### 4.1 `new_table a, b, c`

`b` is the constructor's positional count (saturating), `c` its hash-field
count (named fields, keyed fields). `Heap.newTable` takes them: the hash
part is allocated once for `c` keys, so `{x=, y=, z=, w=}` does not grow it
twice. The array part is not allocated here; its lane is not known until
the values are (§4.3). `b` is kept for `set_list`'s capacity when a
constructor needs more than one batch.

**As built (P0).** `new_table` carries only `c`: `set_list` sizes the
array part from its own run, so the positional count has no reader. The
compiler emits `c = 0` for three keys or fewer
(`HashPart.first_alloc_keys`): the first insertion allocates that capacity
anyway, and a pre-sized empty map costs every `set_field` a failed probe
where `nodes == null` returned at once (`{x=, y=}` measured +56
instructions pre-sized, +2 without). The sized path is a cold lane
(`opNewTableSized`), so `{}` pays one test.

### 4.2 `set_list a, b, c` + `aux`

`R[a]` is the table, `R[b]..R[b+c-1]` the values, `aux` the first key.
The compiler places a run of positional values in consecutive registers
and emits one `set_list` per run, at most 64 values per instruction (Lua
flushes at 50) so a long constructor cannot exhaust the frame's registers.
A run ends at a keyed field (`[k] = v`), which must store after the
positionals before it (§4.5); a named field (`x = v`) cannot collide with
an integer key and does not end it.

**As built.** A named field ends the run too. Deferring a positional
store past a named one changes how many keys the hash part holds when an
integer key reaches it, and `set`'s rehash fires on that count, so a run
with a hole followed by a named field could split differently. Ending the
run keeps every store in source order, so there is nothing to argue.
`{tag = x, a, b}` still takes the fast path: string keys in the hash part
do not stop it (§4.4).

**As built (operands).** The operands are `set_list a, b, c` + `aux` with
`R[a]..R[a+b-1]` the values, `R[c]` the table, `aux` the first key: the
run's base and count sit where a multret `call`'s and `ret`'s do (§4.6).
With the values anywhere but `a`, `bc_liveness.effectOf`'s arm for it cost
a callee-saved register on every instruction it decodes
(`compile_multret_chain` +0.08% out of line, +0.25% inline).

### 4.3 The lane

The handler folds the lane lattice over the values without storing them:
the lane `commitFreshLane` would commit for the first, widened by
`widenFor`'s target for each later value that does not fit. That is the
lane the sequential stores end on, so lane evolution is unchanged — it is
still a pure function of the write sequence (doc 18 D2a). The part is then
allocated once, in that lane, and the values encoded straight in. `{ item,
left, right }` allocates one `.value` block and converts nothing.

The fold reuses the existing functions (`laneForValue`, the `widenFor`
target), split out of the mutating paths, so the two cannot drift.

### 4.4 When the fast path applies

The one-allocation path needs the sequential stores to be appends: the
table has no array storage yet, or `aux == asize`; the hash part holds
none of the run's keys; no value is `nil`. Anything else — a `nil` in the
run (sequential stores send the keys after a hole to the hash part, which
is why `#{1, nil, 3}` is 1), an earlier keyed field that put an integer key
in the hash — runs the run as sequential `Table.set`s. A fresh constructor
cannot have a metatable.

**As built.** The conditions are checked at run time, by `Table.storeRun`,
not decided by the compiler, so they cover every run: the first (a part
that has never had storage, key 1), a later batch or a run after a keyed
or named field (`aux == asize`), and a run behind named fields. The run
must have no metatable to consult, and the hash part, when it is not
empty, must hold none of the integer keys `set` would absorb or drop on
the way: the run's own, its successor (`migrateFromHash`), and key 0 for
a seed. `storeRun` stores the run's leading non-nil values and returns how
many; the handler stores the rest one at a time through `indexSet`, the
old per-field path.

### 4.5 Evaluation and store order

Every field expression still evaluates in source order. A positional store
is deferred to the end of its run, which nothing can observe: the table is
not reachable from its own field expressions, has no metatable, and runs
end before a keyed field, so `{"b", [1] = "a"}` still ends with `"a"`. An
error in a later expression aborts the constructor before the run is
stored; the half-built table was unreachable, so that is unobservable too.

### 4.6 A trailing call or `...`

Lua and LuaJIT expand a constructor's last positional call or `...` to all
its values. mahina truncates it to one (TODO.md, 2026-10-09; doc 27 §7: no
`all_results` shape). With `set_list`, the expansion is `c = all_results`:
the count is the frame's `stack_top` minus `b`, as `call` with
`all_results` arguments reads it. Q1: make the change.

**As built.** With §4.2's operands the expansion is `b = all_results`, the
count `reg_top` minus `a`. `bytecode.isMultretConsumer` names the
consumers (`call`, `ret` and `set_list` with `b = all_results`, each
reading `R[a..)` to the top); liveness (`dynamicProducerBase`, `maskable`'s
chain check) and the exit-attach rule 9 read it. Without the liveness
half, the producer before a `set_list` killed nothing and the consumer's
read to the top kept every register above it live back through the code,
which fails `maskable`'s call-layout check. A `set_list` consumer writes no
register, so `survivorsOfConsumer` kills only for a fixed-`c` `call`.

Widening the predicate moved `compile_multret_chain` +0.1% to +0.4% with
each rewording of it, from inlining alone: the worklist decoded each pc's
producer status two to five times per visit. `compute` now decodes it once
into a bitset (`producers`) and tests bits, −0.9% there against the
baseline.

## 5. Determinism and the JIT

All 8 modes run the same tier-0 `set_list`, and by §4 its end state is the
sequential stores' (capacity aside, which no keyframe carries), so
equivalence and replay are unaffected.

The recorder aborts on `set_list` with `nyi_opcode`. No trace is lost: the
positional `set_index`es it replaces abort `bad_type` on a fresh table today
(and so do named fields' `set_field`s, which stay). The abort rows move to
the new opcode. As built: on the board only binary-trees' rows move (two
sites, same counts, `bad_type` → `nyi_opcode`). Doc 45's `tset` (constructor stores
on a `tnew`) then records `set_list` as a run of `tset`s with the folded
lane, and the native lowering is doc 45's.

## 6. Testing

- Semantics (interp_semantics_test): every lane and lane change in one run,
  holes, a keyed field between runs, `{"b", [1] = "a"}`, a run longer than
  one batch, nested constructors, an erroring field expression, and, with
  P2, `{f()}`, `{0, f()}`, `{...}`, `{f(), 0}`.
- An array.zig unit test pinning the fold to the sequential lane over
  value sequences (the `seedFresh`-vs-`seedAt` pattern).
- The board: no row above noise, outputs and abort counts identical (abort
  rows move from `set_index` to `set_list`).

## 7. Questions (answered by Bart, 2026-10-23)

- **Q1 — trailing call and `...`.** (a) Expand them, as Lua and LuaJIT do
  (`#{f()}` is 3, `{...}` packs the varargs). (b) Keep mahina's
  truncation. TODO.md had asked since 2026-10-09; its vararg roadmap lists
  `{...}`/`{f()}` table-spread as remaining work. **Answer: (a), expand.**
- **Q2 — capacity.** (a) Exact: `n + 1` slots, as LuaJIT sizes `TNEW`; a
  4-slot node takes 64 bytes instead of 128, and a later `t[#t+1]` grows
  immediately. (b) The sequential stores' capacity (8, doubling). Neither
  is in a keyframe. **Answer: (a), exact.**
- **Q3 — scope of P0.** Pre-size the hash part from `c` only, or also add an
  insertion lane for a new string key on `set_field`, the named-field
  counterpart of §2a's append lane? **Answer: pre-size only.**

## 8. References

- Lua 5.4: `lparser.c` (`constructor`, `closelistfield`, `lastlistfield`),
  `lvm.c` (`OP_NEWTABLE`, `OP_SETLIST`).
- LuaJIT: `lj_parse.c` (`expr_table`), `lj_tab.c` (`lj_tab_new`,
  `lj_tab_dup`), `vm_x86.dasc` (`TNEW`, `TDUP`, `TSETB`, `TSETM`).
- Doc 18 (array part, lane lattice, D2a fresh-lane commit), doc 27 §7 (no
  `all_results` constructor shape), doc 45 (`tnew`/`tset`, precise deopt).
- `bench/opprobe/ctors.lua`.
