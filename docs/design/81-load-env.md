# 81 — `load` honours its env: chunk environments — Design

Status: draft, not yet implemented (options for Bart; nothing built)
Owner: Bart
Last updated: 2026-11-02

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole phases to Done once everything inside them is checked.

### Done

_(nothing yet)_

### Outstanding

- [ ] **Q1 — the environment model** (§3): (A) Lua 5.4 lexical `_ENV`
  everywhere, (B) a per-closure environment, inherited at closure creation,
  or (C) B for implicit globals, plus A only in chunks that name `_ENV`.
- [ ] **Q2 — metatables on the environment** (§5): does `get_global` honour
  `__index`/`__newindex` on `_G` and on a `load` env (strict.lua), in the
  same unit or a later one?
- [ ] **Phase 0 — baselines.** `get_global`/`set_global` instruction counts
  (tier-0 and native) on a globals-heavy loop and the bench suite, so the
  chosen model's cost is measured against today.
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

## References

- `src/compiler.zig` `loadName`/`storeName`; `src/resolve.zig` (`_G`).
- `src/stdlib/load.zig` `compileToClosure`.
- `src/interp.zig` `opGetGlobal`/`opSetGlobal`.
- `src/trace_recorder.zig` `recInputGet`.
- Lua 5.4 manual §2.2 (Environments) and `lparser.c` `singlevar`;
  Lua 5.1 `setfenv`.
