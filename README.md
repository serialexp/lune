# lune

A Lua-shaped (not Lua-compatible), dynamically-typed language with a tracing
JIT and time-travel replay, written in Zig.

Working codename — rename at will.

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

## Performance

Ongoing campaign: every benchmark ≤1.2× LuaJIT. Current board (2026-08-27,
rev `31ff9db`, 27 LuaJIT-comparable programs, best-of-5 wall clock; absolute
times are machine-specific — compare ratios):

- **Median: 5.6× LuaJIT.** Range 1.0× to 41×.
- At or near parity already: `sieve_int` 1.03×, `nsieve` 1.06×,
  `str_gsub` 1.45×, `field_hash` 1.67×.
- The long tail (`scalar` 41×, `spectral-norm` 31×, `array3d` 27×,
  `nbody` 22×) maps to known JIT-coverage gaps — builtin recording breadth,
  nest coverage, return tracing — tracked in `CURRENT_TASK.md`, not to
  codegen quality on covered code.

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
