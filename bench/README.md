# mahina benchmark suite

Small, focused Lua programs plus a runner that does two jobs at once:

1. **catch discrepancies** — every program runs across mahina's three execution
   tiers (tier-0 bytecode, tier-1a IR-interpreter, tier-1b native x86-64) and
   their stdout must be byte-identical (the determinism property); programs that
   stay inside LuaJIT's stdlib surface are *also* diffed against LuaJIT; and
2. **show how far behind LuaJIT we are** — best-of-N wall-clock per engine and
   the mahina/LuaJIT slowdown ratio.

The programs double as a usability smoke test for the standard library: each
exercises one or a few stdlib functions in a hot, arg-sized loop and prints a
deterministic checksum.

## Running

```sh
zig build -Doptimize=ReleaseFast        # the runner needs a release mahina
python3 bench/run.py                     # whole suite
python3 bench/run.py --filter str        # only programs whose name contains 'str'
python3 bench/run.py --reps 7            # best-of-7 timing (default 5)
python3 bench/run.py --scale 0.1         # scale the first integer arg (quick run)
python3 bench/run.py --no-luajit         # skip the LuaJIT comparison
python3 bench/run.py --no-save           # don't write a results snapshot
```

LuaJIT defaults to `~/Projects/LuaJIT/src/luajit` (override with `--luajit` or
`$LUAJIT`); mahina defaults to `zig-out/bin/mahina` (`--mahina` / `$MAHINA`).

The runner exits non-zero if any program shows a correctness flag (cross-mode
`MISMATCH`, a LuaJIT `DIFF`, or an `ERR`), so it is usable as a gate.

### Reading the table

```
program          cross   luajit      t0 ms    jit ms     lj ms  jit/lj   t0/lj   t0 MB  jit MB   lj MB
str_format       ok      ok          521.8     523.5      28.8   18.2x   18.1x     3.4     3.6     1.9
```

| column   | meaning |
|----------|---------|
| `cross`  | do tier-0 / tier-1a / tier-1b agree byte-for-byte? (`ok` / `MISMATCH`) |
| `luajit` | parity vs LuaJIT: `ok` / `DIFF` / `skip` (mahina-only surface) / `ERR` / `n/a` |
| `t0 ms`  | tier-0 (bytecode interpreter) best-of-N wall time |
| `jit ms` | tier-1b (`--jit-native`) best-of-N wall time |
| `lj ms`  | LuaJIT best-of-N wall time |
| `jit/lj` | how many× slower mahina's native tier is than LuaJIT |
| `t0/lj`  | how many× slower mahina's interpreter is than LuaJIT |
| `t0 MB` / `jit MB` / `lj MB` | peak memory (kernel max RSS) per engine, best-of-N from **dedicated non-timed runs** (`--mem-reps`, default 3) — measured identically for mahina and LuaJIT via per-child `rusage`, so the columns are directly comparable. Whole-process peak: includes code, stacks, allocator slack, and JIT pages, not just the Lua heap. For mahina-internal exact heap-byte inspection use the CLI's `--mem-stats` flag instead; that never feeds the harness. |

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
| `luajit=` | `compatible` → diff + time against LuaJIT; `skip` → mahina-only (5.4 surface LuaJIT lacks), cross-tier check only |
| `name=`   | optional display name (defaults to the file stem) |

Conventions, so a program is both a perf probe and a parity check:

- Wrap the function(s) under test in a loop sized by `arg[1]`.
- Accumulate an **integer** checksum; print a tiny, deterministic summary line.
  Not superstition — `print(x)` on a float is **not** LuaJIT-comparable, because
  mahina renders the shortest round-tripping decimal by design where Lua uses
  `%.14g`: `print(1/3)` is `0.3333333333333333` here and `0.33333333333333`
  there. `string.format("%.6f", x)` *is* comparable (exact since
  `src/stdlib/decimal.zig`); bare `tostring`/`print` of a float is not.
- Use only the LuaJIT-available surface for `luajit=compatible`. LuaJIT 2.1 is
  Lua 5.1 + selected 5.2/5.3 bits; it does **not** have `math.type`,
  `math.maxinteger`, `table.pack`, `table.unpack`, or `rawlen`. Mahina's Lua 5.4
  additions go in a `luajit=skip` program (see `stdlib/lua54.lua`).

## Vendored LuaJIT benchmarks (`bench/luajit/`)

`bench/luajit/` holds programs from `~/Projects/LuaJIT/bench/` (the Computer
Language Benchmarks Game ports LuaJIT itself uses), with a prepended `-- @bench`
header line added. They are the macro-benchmark corpus we measure the mahina/LuaJIT
gap against — and, because the runner diffs mahina's output against LuaJIT, they
double as Lua-fidelity tests on real programs.

Only the subset that runs correctly on mahina today is vendored. A program is
included when it (a) parses and runs, (b) stays inside the stdlib surface mahina
implements, and (c) is byte-for-byte identical to LuaJIT's output (so
`luajit=compatible` parity holds). Workload sizes (`args=`) are tuned down from
LuaJIT's defaults so tier-0 mahina finishes in a fraction of a second — the runner
times the *same* size on both engines, so the ratio is honest.

Most are copied **verbatim**. Two — `euler14-bit` and `nsieve-bit` — are
**adapted**: the upstream uses LuaJIT's BitOp library (`bit.band`/`rshift`/…,
int32 semantics), which mahina deliberately does not provide; mahina is 5.4-shaped
and uses native 64-bit bitwise *operators* (`&`, `|`, `~`, `<<`, `>>`). The mahina
file is rewritten to those operators, semantically equivalent but not
code-identical, and the verbatim `bit.*` original lives under `_ref/` and is run
**only by LuaJIT** via the `luajit_src=` metadata key (see `run.py`). Both halves
still produce byte-identical output, so `luajit=compatible` parity holds. (Files
under `_ref/` carry no `@bench` header, so discovery skips them as standalone
benches.)

Currently vendored: `array3d`, `binary-trees`, `euler14-bit`, `nbody`, `nsieve`,
`nsieve-bit`, `nsieve-bit-fp`, `partialsums`, `recursive-fib`, `spectral-norm`,
and the four `scimark-*` kernels (`fft`, `lu`, `sor`, `sparse`).

### `require`-from-cwd benches (the scimark suite)

`scimark-fft`/`lu`/`sor`/`sparse` are thin wrappers that `require("scimark_lib")`
— a shared kernel library (`bench/luajit/scimark_lib.lua`, vendored verbatim with
**no** `@bench` header so discovery skips it as a standalone bench). For the
`require` to resolve, the runner runs **every** child (mahina and LuaJIT, all tiers)
with its working directory set to the bench's own directory, mirroring upstream
LuaJIT's `run.sh` (`cd $BENCH_DIR`). The default `package.path` (`"./?.lua;..."`)
then finds `./scimark_lib.lua`. The bench path itself is passed absolute, so the
cwd only affects `require`. They are the float- and array-heavy numeric
throughput workload where mahina's tracing JIT is still a no-op (`jit ms ≈ t0 ms`,
tens of × off LuaJIT), i.e. the headline optimization targets.

The kernels return a flop count the wrappers discard, so upstream these print
nothing. Until 2026-08-26 mahina vendored them that way, which made their frozen
digest `sha256("")` and made the cross-tier check compare `"" == "" == ""` while
reporting `cross=ok`. Each wrapper now ends in `print(lib.checksum())` — an exact
integer fold of the kernel's result state (the transformed vector, the relaxed or
factored matrix, the product vector). It is an integer fold rather than a
formatted float: when it was written mahina's `string.format` could not render a
double's exact decimal expansion, so a `%.17g` print would have differed from
LuaJIT's for formatting reasons alone. That is since fixed
(`src/stdlib/decimal.zig`), but the fold stays — it depends on no formatting
behaviour at all, so it compares the numbers themselves and cannot be quietly
weakened by a future rendering change.

Two consequences worth knowing:

* **`scimark_lib.lua` is no longer byte-verbatim upstream.** It selects its RNG
  with `if jit and jit.status and jit.status()`, and the two branches are *not*
  equivalent generators — LuaJIT and mahina took different ones and so ran these
  kernels on different input data, making byte-parity unreachable rather than
  merely absent. The lib now forces the portable branch. This costs nothing
  (`rand` is setup-only for these four kernels; measured −0.8% sor, −1.8% lu on
  LuaJIT) and all four now match LuaJIT bit-for-bit. Both mahina-local edits are
  marked as such in the file.
* **`array3d`'s row moved a lot** when its checksum landed — its fold walks all
  512,000 elements and does not tier up (49.8 ms under both tier-0 and
  `--jit-native`). Measured:

  | array3d | mahina t0 | mahina jit | LuaJIT | jit/lj |
  |---|---|---|---|---|
  | before | 172.1 | 177.9 | 1.9 | 95.8x |
  | after  | 226.1 | 225.6 | 8.3 | 27.1x |

  The ratio moved in the *flattering* direction, which is the counter-intuitive
  part: the fold costs LuaJIT +6.5 ms against a 1.9 ms baseline (+348%) but mahina
  only +48 ms (+27%), so array3d dropped from the worst row on the board to a
  middling one. Both engines run the identical added work, so 27.1x is a true
  measurement — of a different mixture (~21% of the row is now checksum). Read
  the step at 2026-08-26 as a change of workload, not as an optimization, and
  don't compare the ratio across it. Pre-change baselines are in
  `bench/results/` up to `20260825-181602`.

Not yet runnable (tracked in `TODO.md`), by blocking gap: coroutines
(chameneos, coroutine-ring); binary/Latin-1 output (life, mandelbrot,
mandelbrot-bit, fannkuch); the `jit` module / numeric-chunkname `loadstring` /
stdin for the dynamic-codegen ports (fasta, pidigits-nogmp, revcomp, meteor);
a couple of missing functions (k-nucleotide, sum-file); and deep non-tail
recursion that overflows mahina's call stack at LuaJIT's N (recursive-ack).
Programs that print their own `os.clock` timing (e.g. `series`) are excluded —
their stdout is not byte-comparable.

## Results history

Each run appends a timestamped, git-rev-stamped TSV under `bench/results/`
(one row per program). Those snapshots are committed — they are the suite's
history. `bench/results/latest.tsv` is a volatile mirror of the most recent run
and is git-ignored. Timings are machine- and load-dependent; compare ratios and
trends, not absolute milliseconds across machines.

Since 2026-08 each row also carries `mahina_t0_maxrss_kb`, `mahina_jit_maxrss_kb`,
and `luajit_maxrss_kb` (peak RSS in KB, see "Reading the table" above). Older
TSVs simply lack the columns.
