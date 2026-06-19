# lune benchmark suite

Small, focused Lua programs plus a runner that does two jobs at once:

1. **catch discrepancies** — every program runs across lune's three execution
   tiers (tier-0 bytecode, tier-1a IR-interpreter, tier-1b native x86-64) and
   their stdout must be byte-identical (the determinism property); programs that
   stay inside LuaJIT's stdlib surface are *also* diffed against LuaJIT; and
2. **show how far behind LuaJIT we are** — best-of-N wall-clock per engine and
   the lune/LuaJIT slowdown ratio.

The programs double as a usability smoke test for the standard library: each
exercises one or a few stdlib functions in a hot, arg-sized loop and prints a
deterministic checksum.

## Running

```sh
zig build -Doptimize=ReleaseFast        # the runner needs a release lune
python3 bench/run.py                     # whole suite
python3 bench/run.py --filter str        # only programs whose name contains 'str'
python3 bench/run.py --reps 7            # best-of-7 timing (default 5)
python3 bench/run.py --scale 0.1         # scale the first integer arg (quick run)
python3 bench/run.py --no-luajit         # skip the LuaJIT comparison
python3 bench/run.py --no-save           # don't write a results snapshot
```

LuaJIT defaults to `~/Projects/LuaJIT/src/luajit` (override with `--luajit` or
`$LUAJIT`); lune defaults to `zig-out/bin/lune` (`--lune` / `$LUNE`).

The runner exits non-zero if any program shows a correctness flag (cross-mode
`MISMATCH`, a LuaJIT `DIFF`, or an `ERR`), so it is usable as a gate.

### Reading the table

```
program          cross   luajit      t0 ms    jit ms     lj ms  jit/lj   t0/lj
str_format       ok      ok          521.8     523.5      28.8   18.2x   18.1x
```

| column   | meaning |
|----------|---------|
| `cross`  | do tier-0 / tier-1a / tier-1b agree byte-for-byte? (`ok` / `MISMATCH`) |
| `luajit` | parity vs LuaJIT: `ok` / `DIFF` / `skip` (lune-only surface) / `ERR` / `n/a` |
| `t0 ms`  | tier-0 (bytecode interpreter) best-of-N wall time |
| `jit ms` | tier-1b (`--jit-native`) best-of-N wall time |
| `lj ms`  | LuaJIT best-of-N wall time |
| `jit/lj` | how many× slower lune's native tier is than LuaJIT |
| `t0/lj`  | how many× slower lune's interpreter is than LuaJIT |

`jit ms ≈ t0 ms` on a stdlib-heavy program is expected and informative: the loop
is dominated by native-call dispatch, which the tracing JIT does not accelerate
(LuaJIT's fast-path builtins do — hence the gap).

## Adding a program

Drop a `.lua` file under `bench/` (or `bench/stdlib/`) carrying a single
metadata comment line anywhere in the file:

```lua
-- @bench args="200000" luajit=compatible
-- @bench args="poison 2000 1000" luajit=compatible name=repack
-- @bench args="100000" luajit=skip
```

| key       | meaning |
|-----------|---------|
| `args=`   | literal argv passed to the program (space-split; may be empty) |
| `luajit=` | `compatible` → diff + time against LuaJIT; `skip` → lune-only (5.4 surface LuaJIT lacks), cross-tier check only |
| `name=`   | optional display name (defaults to the file stem) |

Conventions, so a program is both a perf probe and a parity check:

- Wrap the function(s) under test in a loop sized by `arg[1]`.
- Accumulate an **integer** checksum (float checksums diverge across engines for
  non-obvious reasons); print a tiny, deterministic summary line.
- Use only the LuaJIT-available surface for `luajit=compatible`. LuaJIT 2.1 is
  Lua 5.1 + selected 5.2/5.3 bits; it does **not** have `math.type`,
  `math.maxinteger`, `table.pack`, `table.unpack`, or `rawlen`. Lune's Lua 5.4
  additions go in a `luajit=skip` program (see `stdlib/lua54.lua`).

## Results history

Each run appends a timestamped, git-rev-stamped TSV under `bench/results/`
(one row per program). Those snapshots are committed — they are the suite's
history. `bench/results/latest.tsv` is a volatile mirror of the most recent run
and is git-ignored. Timings are machine- and load-dependent; compare ratios and
trends, not absolute milliseconds across machines.
