# mahina

A Lua-shaped (not Lua-compatible), dynamically-typed language with a tracing
JIT and time-travel replay, written in Zig.

*Mahina* is Hawaiian for **moon** — continuing the family habit, since *Lua* is
Portuguese for moon and *Luau* followed it. Previously called **lune** (French,
same word), renamed because [lune-org/lune](https://github.com/lune-org/lune) is
an established standalone Luau runtime and two moon-named runtimes for two
Lua-family languages is one too many.

## What it is

- **Lua-shaped, not Lua-compatible.** The syntax and standard library follow
  Lua 5.4 closely (LuaJIT-era programs mostly run unmodified), but where
  compatibility fights determinism or design, determinism wins. Deliberate
  divergences are documented, not accidental.
- **Deterministic by construction.** A program produces byte-identical output
  across all execution modes — tier-0 bytecode interpreter, tier-1a IR
  interpreter, tier-1b native x86-64, and their exec-log/replay variants.
  This is a hard invariant, enforced by a frozen-output gate on every change.
- **Time-travel replay.** Execution can be snapshotted, replayed, and
  inspected; the trace visualiser (`viz/`) is built on this. Determinism is
  what makes replay exact rather than approximate.
- **Tracing JIT.** LuaJIT-style: hot loops are recorded to an SSA IR,
  optimised, and compiled to native code, with side-trace chaining, exit
  patching, and cross-frame tracing. The design docs under `docs/design/`
  (start at `00-architecture.md`) document each mechanism.

## Source extensions: `.mah` and `.lua`

The extension states which *language* the file is written in, and therefore who
can run it. This is a real distinction, not decoration:

| ext | the file is | runs under |
|---|---|---|
| `.mah` | a **mahina** program | mahina only |
| `.lua` | a **Lua** program | `lua`, `luajit`, **and** mahina |

Lua is a subset of what mahina accepts, so mahina runs both and `package.path`
searches `./?.mah` and `./?/init.mah` before the `.lua` forms — you are running
the mahina binary, so a mahina-specific module shadows a Lua one of the same
name. Stock Lua, of course, only reads `.lua`.

The asymmetry is the point. Several planned divergences (freezable shapes,
optional type annotations) are *syntax*, so a file using them does not merely
behave differently under `lua` — it fails to parse. Calling such a file `.lua`
would be false. Equally, the LuaJIT parity benchmarks under `bench/` are
genuinely Lua programs and stay `.lua` permanently, which is why `bench/run.py`
rejects a `.mah` file that claims `luajit=compatible`.

Today every program in the tree is still valid Lua, so nothing is `.mah` yet.
Files move over as they start using mahina-only features.

## Performance

Ongoing campaign: every benchmark ≤1.2× LuaJIT. Current board (2026-08-27,
rev `31ff9db`, 27 LuaJIT-comparable programs, best-of-5 wall clock; absolute
times are machine-specific — compare ratios):

- **Median: 5.3× LuaJIT.** Range 1.1× to 29×.
- At or near parity already: `sieve_int` 1.12×, `nsieve` ~1.1×,
  `str_gsub` 1.4×, `field_hash` ~1.6×.
- The long tail (`spectral-norm` 29×, `array3d` 28×, `nbody` 22×,
  `recursive-fib` 20×) maps to known JIT-coverage gaps — nest coverage,
  builtin recording breadth, return tracing — tracked in `CURRENT_TASK.md`,
  not to codegen quality on covered code.

Every row is also a correctness check: all three tiers must agree
byte-for-byte with each other and (where claimed) with LuaJIT on the same
source. See `bench/README.md` for how to read the board and
`bench/results/` for the committed history.

## Build

The Zig toolchain is pinned in `.zig-version` (a `-dev` snapshot; the build
warns on drift, `just check-version` makes it fatal). `just` recipes are the
canonical entry points:

```sh
just build          # build the CLI (Debug)
just test           # build + full unit-test suite (the gate)
just release        # ReleaseFast CLI
just run -- x.lua   # run a script
just bench          # benchmark suite vs LuaJIT (rebuilds ReleaseFast first)
just hashgate       # frozen-output gate: 28 programs x 3 modes,
                    #   ReleaseFast + safety-checked Debug legs
```

## Documentation

- `docs/design/00-architecture.md` — start here; principles and layout.
- `docs/design/01`–`04` — trace lifecycle, determinism, GC/memory,
  snapshot/replay schema.
- `docs/design/05+` — one doc per JIT mechanism (native codegen, store
  sinking, cross-frame tracing, nested-loop linking, exit-branch patching,
  …).
- `docs/lua-stdlib-inventory.csv` — per-function map of the Lua 5.4 stdlib
  surface: what's in scope, what's implemented, what's deliberately excluded.
