# 81 — `load` honours its env: chunk environments — Design

Status: draft, not yet implemented. Strictness decided, Phase 0 measured
(§6, §7); the environment model still open
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

### Outstanding

- [ ] **Q3 — where a declared global lives** (§6.2, §7): today's hinted
  table slot, read through the closure's environment (B), or a cell bound
  at load time (E2). Decide with §7's numbers in hand.
- [ ] **Q4 — how Lua code opts out** (§6.1): the bench corpus and other
  Lua sources use implicit globals. A CLI flag, a `global *` the file
  writes, or a file extension rule.

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

**Stores don't trace.** `set_global` is NYI in the recorder (`nyi_opcode`,
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

## References

- `src/compiler.zig` `loadName`/`storeName`; `src/resolve.zig` (`_G`).
- `src/stdlib/load.zig` `compileToClosure`.
- `src/interp.zig` `opGetGlobal`/`opSetGlobal`.
- `src/trace_recorder.zig` `recInputGet`.
- Lua 5.4 manual §2.2 (Environments) and `lparser.c` `singlevar`;
  Lua 5.1 `setfenv`.
