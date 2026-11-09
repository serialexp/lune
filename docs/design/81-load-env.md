# 81 — `load` honours its env: chunk environments — Design

Status: draft, not yet implemented. Strictness, opt-out and the access
model decided (§6); Phase 0 measured (§7); `set_global` records (§7.1);
E2's design still to write
Owner: Bart
Last updated: 2026-11-09

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole phases to Done once everything inside them is checked.

### Done

- [x] **Q0 — globals are declared** (§6): decided 2026-11-09. Every chunk
  is strict: a free name that no `local` and no `global` declares is a
  compile error. The names the host installs (`print`, `string`, …) count
  as declared. Bart: "less footguns and cheaper global access are both
  positives".
- [x] **Phase 0 — baselines** (§7): measured before choosing the model.
  Bart: "Measure first".
- [x] **Q3 — cells bound at load time (E2)** (§6.2): decided 2026-11-09,
  with §7's numbers in hand. Bart: "I suggest we go E2". E2 needs its own
  design (stable cells in the environment; `rawset`, `pairs`, `_G[name]`,
  late-created globals, keyframes).
- [x] **Q4 — opt-out by extension** (§6.1): decided 2026-11-09. A `.lua`
  file keeps implicit globals; a `.mah` file is strict, and may write
  `global *` to opt out. Bart: "decide by extension, but allow specifying
  global * in mah files".
- [x] **`set_global` recorded by the JIT** (§7.1): landed 2026-11-09, first
  by Bart's order. It records as a hash store into the globals table. Its
  recorded store changes shape under E2 (a cell store); the aliasing
  machinery around it carries over. It exposes TODO.md's head-trace entry
  cost (B) on `globals_script` (§7.1), which Bart chose to fix next.

### Outstanding

- [ ] **E2's design** (§6.2): the cell layout, how a table environment
  keeps stable cells, and what a `.lua` chunk's implicit globals bind to.
- [ ] **Q1 — the environment model** (§3): (A) Lua 5.4 lexical `_ENV`
  everywhere, (B) a per-closure environment, inherited at closure creation,
  or (C) B for implicit globals, plus A only in chunks that name `_ENV`.
- [ ] **Q2 — metatables on the environment** (§5): does `get_global` honour
  `__index`/`__newindex` on `_G` and on a `load` env (strict.lua), in the
  same unit or a later one?
- [ ] **Phase 1 — the model** (per Q1): compiler, resolver, `load`'s env
  argument, `closure` creation.
- [ ] **Phase 2 — JIT**: the recorder's global inputs keyed by the
  environment the trace saw, with a guard on its identity.
- [ ] **Phase 3 — keyframes**: the environment of every live closure
  survives capture and restore; `recompileLoadedChunks` rebuilds env-mode
  chunks as they were compiled.
- [ ] **Phase 4 — docs**: `docs/differences-from-lua.md` "Not yet
  supported" entries, TODO_USABILITY, stdlib inventory row for `load`.

## 1. Why this exists

`load(chunk, name, mode, env)` ignores `env`. `load("return x", "c", "t",
{x = 5})()` returns nil, and `load("y = 10", "c", "t", env)()` writes the
real global. Sandboxing, configuration files read with a private table, and
template engines all rely on it. `local _ENV = {}` is ignored for the same
reason: mahina has no `_ENV`.

## 2. Today

- A free name compiles to `get_global k` / `set_global k` (compiler.zig
  `loadName`/`storeName`). Both read `vm.globals` directly, through a
  per-proto slot hint (`Proto.global_slot_hints`), with no metatable.
- `_G.x` is resolved statically to a global when `_G` itself is the global
  (resolve.zig ~513, ~667).
- `load` compiles the source and makes a closure with no upvalues
  (`stdlib/load.zig` `compileToClosure`, `newClosure(chunk.proto, 0)`).
- Traces record `get_global` as an input keyed on `vm.globals`
  (`trace_recorder.zig` `recInputGet(.global, …)`).
- Keyframes rebuild loaded chunks from source (`keyframeser`
  `recompileLoadedChunks`, schema `LoadedChunk`).

## 3. Q1 — three models

### (A) Lua 5.4: `_ENV` is an upvalue

Every chunk has one upvalue, `_ENV`; a free name `x` is `_ENV.x`. `load`
sets that upvalue to `env`, or to the globals table. `local _ENV = t` and
`_ENV = t` are ordinary local and upvalue assignments, so all of Lua's
semantics follow from the compiler alone.

- **Cost:** `get_global` becomes "read upvalue 0, then index it". As a
  fused op that is one more dependent load than today (the upvalue cell),
  plus a table check, because the environment is no longer known to be
  `vm.globals`. Every closure that touches a global needs `_ENV` as an
  upvalue, so closure creation captures one more upvalue.
- **JIT:** the trace guards the environment's identity once (a loop
  invariant) and keeps today's slot-hinted loads.
- **Keyframes:** nothing new. `_ENV` is an upvalue and is already captured.

### (B) A per-closure environment

`Closure` gains an `env` field. `get_global` reads `closure.env` instead of
`vm.globals`; the `closure` op copies the creating closure's env; `load`
sets the chunk closure's env. This is Lua 5.1's `setfenv` model without
`setfenv`.

- **Cost:** one load per `get_global` (the frame's closure is already in
  hand), no extra upvalue, no extra work at closure creation beyond a copy.
- **Gaps:** `local _ENV = t` and `_ENV = t` do not exist. Reassigning the
  environment after closures were created cannot reach them.
- **Keyframes:** a new `Closure` field in the schema.

### (C) B, plus A where a chunk names `_ENV`

Implicit globals use B. A chunk that mentions the name `_ENV` anywhere is
compiled in A's mode instead: its free names index the lexical `_ENV`, so
`local _ENV` and `_ENV = t` behave as in Lua. Most code never names `_ENV`
and keeps B's cost.

- **Cost:** B's cost for most code; A's only where `_ENV` is named.
- **Complexity:** two compilation modes for free names, and the resolver's
  `_G` shortcut must know which mode applies.

## 4. What every model shares

- `load`'s chunk name and `mode` arguments are unchanged; only `env` gains
  a meaning.
- The environment, not `vm.globals`, is what `get_global` reads, so
  `vm.globals` stays the default environment only.
- Determinism (doc 02): the environment is a heap object chosen by the
  program, so nothing new is non-deterministic.

## 5. Q2 — metatables on the environment

`setmetatable(_G, {__index = …, __newindex = …})` is ignored today, because
`get_global` never looks at a metatable. strict.lua and lazy module loaders
depend on it. The fast path can stay as it is: a miss already leaves for
the slow handler, which is where an `__index` lookup belongs. A
`__newindex` check on `set_global` costs one metatable test per store.
This can land with Phase 1 or separately.

## 6. Explicit globals (2026-11-09)

Bart: "Maybe we should just make globals explicit? I feel like resolving g
to _ENV.g is a bit icky if we have to do it every single time we use a
variable." Doc 76 already has Lua 5.5's declarations and its strict scope
(`global x`; inside its scope an undeclared name is a compile error). Two
points shaped the choice:

- No model resolves a name per use. The compiler decides once that `g` is
  a global and which table it reads; what runs per use is loads.
- A declared global still lives in some table, so declaring globals does
  not answer which table `load`'s `env` replaces. That stays Q1/Q3.

### 6.1 Strictness (Q0, decided)

Every chunk is strict, as if it opened with doc 76's declarations. The
names the host installs at VM creation count as declared, so `print` needs
no `global print`; a program's own globals do. This is stricter than 5.5,
whose chunks start with an implicit `global *`. Lua sources that rely on
implicit globals need a way to opt out (Q4).

### 6.2 Cheaper access (Q3)

- **Hinted slot, through the closure's env (B).** Today's fast path with
  `closure.env` in place of `vm.globals`: about one more load.
- **Cells bound at load time (E2).** Declarations give the compiler the set
  of globals a chunk uses. At load, each is bound to a cell in its
  environment, and a use loads the cell. The environment must then keep
  each value in a stable cell: `env.x = 1` from outside, `rawset`, `pairs`,
  `_G[name]`, a global first created after the load, and keyframes all have
  to see the same cell. A design doc of its own.

## 7. Phase 0: what globals cost today (2026-11-09)

ReleaseFast at f91022e, instruction counts (`perf stat instructions:u`).

**Microbenchmarks**, 20M iterations; each row's delta is against the same
loop on locals:

| loop | tier 0 | `--trace --jit-native` |
|---|---|---|
| `acc = acc + g1 + g2 + g3 + g4` | +54 instructions per read | ±0 (the reads are trace inputs) |
| `g1 = i` | +92 per store | the loop never traces (below) |

A read's tier-0 fast path (`opGetGlobal`) is ~50 instructions. About 28
are the hinted lookup: the hint array's bounds, the constant's tag,
`vm.globals`, the node's bounds, tag and key, the value's nil test. The
rest is the dispatch every op pays. A cell would replace the lookup with
about three dependent loads, so E2 could save roughly 20 of the ~50, at
tier 0 only. (B) adds about one load.

**Stores don't trace** (since fixed, §7.1). `set_global` is NYI in the recorder (`nyi_opcode`,
TODO.md "`set_upval` on an OPEN upvalue"), so `g1 = i` in a loop runs at
tier 0 under the JIT, and the `--trace` run costs 18% more than tier 0
alone (4007M against 3400M). This is independent of Q3.

**The suite** (55 benches, perf samples in the global handlers): under 3%
in every bench but `str_long_keys` (6.5% tier 0, 5.9% JIT), where its one
read per iteration is `tostring`. Instruction counts put that read at 2.0%
(a `local tostring` copy saves 9.6M of 473M), so the sampled shares
overstate: the bench suite is written with locals and spends little on
globals. Code written with globals pays the per-read cost above at
tier 0, and nothing on traced reads.

**A bench and probes for code written with globals.** The suite had none,
so two were added:

- `bench/globals_script.lua`: a game tick written the way scripts are,
  with config, state, counters, functions and the RNG seed all globals and
  the stdlib reached through global `math`. LuaJIT-compatible. At f91022e:
  tier 0 240 ms, JIT 140 ms, LuaJIT 14 ms (16.7× and 9.7×), 15.5% of
  loop iterations native. Its aborts are mostly `set_global` NYI, in
  `rand`, `move`, `tick`, `bounce` and `collide`.
- `bench/opprobe/globals.lua`: one global operation per iteration.
  Marginal instructions at tier 0 against LuaJIT `-joff`:

| probe | mahina | LuaJIT `-joff` | ratio |
|---|---|---|---|
| `gget` (read) | 54 | 25 | 2.2× |
| `gset` (store) | 114 | 38 | 3.0× |
| `grmw` (`G = G + 1`) | 207 | 58 | 3.6× |
| `gcall` (call a global function) | 361 | 86 | 4.2× |
| `gfield` (`math.abs`) | 237 | 110 | 2.2× |
| `gbuiltin` (`type`) | 166 | 81 | 2.0× |

A store costs twice a read: `opSetGlobal` checks `readonly`, calls
`Table.setHinted` out of line (which normalizes the key), then runs the
write barrier. A call's cost is the call's: `call1` from a local is 361
too.

### 7.1 Recording `set_global` (landed 2026-11-09)

A recorded `set_global k` is a hash store into the globals table, the
shape `set_field` records on any table: `href`, a hash guard and `hstore`.
The trace roots it on a `.globals` input seed, `vm.globals` itself,
reseeded at every entry. Reads stay what they were, an entry snapshot of
the value (`recInputGet(.global)`), unless one of two things holds:

- **The trace already stored to that name.** The read becomes an `hload`
  through the globals table, so it sees the store (`global_store_keys`).
- **The trace stores to a name it snapshotted.** The recording aborts
  `global_mutable`, and the anchor is memoized, as doc 43 P5 does for
  `upvalue_mutable`. The retry records every scalar global read as an
  `hload` (`route_global_reads`), so the store and its later reads agree.

The check is per name (`global_seed_keys`), so a trace that reads `step`
and stores `pos` keeps `step` as a snapshot. Stores through a `_G` handle
keep doc 43 P0b's coarse rule. Function values stored to a global still
abort. The recorder tests are in `interp_trace_test.zig`, and the
tier-equivalence corpus g01–g10 is in `trace_p0_alias_test.zig`.

**What it moved.** The board is unchanged beyond 0.3%, except
`globals_script` on the JIT: 3.53 G → 4.18 G instructions (+18.2%). Tier 0
is 6.28 G either way. `rand`, `move` and `bounce` used to abort on their
store and now trace as head traces (doc 44), entered from tier 0 at every
call: `rand` 631k times at ~270 cycles per call, because the loop in
`collide` that calls it still aborts (`jeq` on two tables). The cost is
the entry, not the store. On HEAD before this change, a two-line pure
function called from a loop that can't trace runs 931M instructions on the
JIT against 531M on tier 0. That is TODO.md's head-trace entry cost (B).
Bart chose to land this and fix (B) next.

## References

- `src/compiler.zig` `loadName`/`storeName`; `src/resolve.zig` (`_G`).
- `src/stdlib/load.zig` `compileToClosure`.
- `src/interp.zig` `opGetGlobal`/`opSetGlobal`.
- `src/trace_recorder.zig` `recInputGet`.
- Lua 5.4 manual §2.2 (Environments) and `lparser.c` `singlevar`;
  Lua 5.1 `setfenv`.
