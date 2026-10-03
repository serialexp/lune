# embedding-boundary benchmark (doc 59 E5)

The embedding analogue of the language suite one directory up: instead of
guest programs timed across mahina's tiers, one **host program per engine**
drives byte-identical guest code through each engine's embedding API and
reports the amortized cost of one boundary crossing. Like `bench/run.py` it
is half parity check (every op prints a checksum; all engines and all reps
must agree or the runner exits non-zero) and half scoreboard (best-of-N
ns/op + mahina/LuaJIT + mahina/Lua 5.4 ratios).

Informational, never a gate (global Rule #22).

## Running

```sh
just embed-bench                     # from the repo root, or:
python3 bench/embed/run.py           # all three engines, best-of-5
python3 bench/embed/run.py --reps 9
python3 bench/embed/run.py --no-lua54 --no-luajit
```

The runner builds everything it needs into `bench/embed/.cache/` (gitignored):

- **mahina** — `zig build lib -Doptimize=ReleaseFast` into its own prefix
  (your `zig-out/` is untouched), then `cc bench_mahina.c` against
  `mahina.h`/`libmahina.a`.
- **LuaJIT** — `cc bench_lua.c` against `~/Projects/LuaJIT/src` (needs
  `libluajit.a` already built there; override `--luajit-src` / `$LUAJIT_SRC`).
- **Lua 5.4** — the official tarball is downloaded and `liblua.a` built into
  the cache on first use (the system ships only the runtime `.so`, no
  headers). Offline? The column is skipped with a warning.

`bench_lua.c` is one source compiled against both Lua engines — the
5.1-vs-5.4 C-API differences are confined to a couple of `#ifndef` shims.

## What each op measures

| op | host side | per-iteration work (all engines) |
|----|-----------|----------------------------------|
| `call` | host→guest | fetch rooted guest `id(x)`, push int arg, protected call, read int result |
| `callback` | guest→host | guest loop calls a registered host function returning its arg; cost = loop time / calls (includes the guest loop itself) |
| `table_get`/`table_set` | host | metamethod-aware get/set with a reused guest-string key |
| `iterate` | host | walk a 10k-entry hash table (`mh_table_iter` vs `lua_next`), per entry |
| `ref` | host | create a guest string, root it, unroot it (`mh_ref_*` vs `luaL_ref`/`luaL_unref`) |
| `compile` | host | compile (not run) a small chunk |
| `eval` | host | full compile+run+result round trip of `return 1 + 2` |

Fairness choices mirror each other: both hosts keep the callee/table/key
rooted and reused (no per-iteration global lookup or string re-intern), both
use the protected call path, both use metamethod-aware table access.

## Per-shape host-call probe (`hostcall_probe.c`)

The `call` row above is one shape, `id(1)`. `hostcall_probe.c` measures
`mh_call` per **call shape** (0/1/4/8/9 arguments, 0/1/4 results, heap
values, varargs, a 40-register window, result-park overflow; the list is
in the file header). It is the doc 60 §5.3 ledger instrument, run under
`perf stat`. It is not part of `run.py`. Build it against the same
ReleaseFast prefix:

```sh
python3 bench/embed/run.py --reps 1 --no-lua54 --no-luajit   # builds .cache/mahina-prefix
P=bench/embed/.cache/mahina-prefix
cc -O2 bench/embed/hostcall_probe.c -I$P/include $P/lib/libmahina.a -lm -o /tmp/hostcall_probe
MH_NOJIT=1 perf stat -e instructions:u,cycles:u /tmp/hostcall_probe a1 2000000
MH_NOJIT=1 perf stat -e instructions:u,cycles:u /tmp/hostcall_probe a1 0   # setup, to subtract
```

Per-call cost is the difference between the two runs, divided by the
iteration count. Numbers are informational, never a gate.

## Reading the numbers (snapshot, 2026-10-01, Bart's home machine)

```
op                              mahina    luajit    lua5.4   mh/lj   mh/5.4
host->guest call                  28ns      13ns      16ns    2.1x     1.7x
guest->host callback              32ns      10ns       9ns    3.4x     3.4x
table get (string key)            17ns      10ns       8ns    1.7x     2.2x
table set (string key)            10ns       6ns       4ns    1.6x     2.3x
table iteration (10k hash)        92ns      11ns      18ns    8.3x     5.2x
ref create+free                   10ns      32ns      34ns    0.3x     0.3x
compile small chunk             1988ns     577ns    1151ns    3.4x     1.7x
eval 'return 1 + 2'              916ns     199ns     481ns    4.6x     1.9x
peak RSS                          69MB      23MB      23MB
```

### JIT state

Both JIT engines run with the JIT **enabled** (mahina's config default is the
CLI's production shape, `capi.zig`; embedded LuaJIT sets `JIT_F_ON` in
`jit_init`, `lib_jit.c`) — but every row is boundary-dominated, so the table
is effectively a comparison of *interpreter-mode* crossing costs:

- Seven of the eight rows are host-side loops crossing into trivial guest
  code — there is no guest loop to trace. A pure guest hot loop through the
  same embedding path tiers up fine (probe, 2026-10-01: 20M-iteration sum is
  27× faster with JIT default than `jit=2` in mahina, 4× in LuaJIT).
- The `callback` row has a guest loop, but the host call inside it blocks
  trace formation in BOTH JIT engines: mahina's host natives are
  recorder-opaque by design (doc 59 §3.5), and LuaJIT aborts on
  non-monomorphic C functions (`lj_record.c`). Measured: mahina's callback
  loop is unchanged with the JIT off (34.6 → 32.8 ms); LuaJIT's is actually
  *faster* with `jit.off()` (9.7 → 6.3 ms — no abort/retry overhead).

Two rows are structural, not incidental:

- **`iterate`** — `mh_table_iter_new` *materializes* the deterministic key
  order into a guest table up front (doc 59 §3.4); the per-entry figure
  amortizes that materialization, where `lua_next` walks the live table
  directly. That is the price of deterministic, O(1)-per-step iteration.
- **peak RSS / `compile`** — `mh_compile` retains every chunk for the VM's
  lifetime by design (guest `load()` ownership, doc 59 §3.2); 20k compiles
  therefore grow the heap where Lua's chunks are collected.

The Rust safe crate (`just embed-bench-rust`) sits **on top** of this C ABI
and adds its own per-value cost (auto-promotion of every crossing heap value
to a GC ref, `Vec` marshalling) — compare its numbers against the `mahina`
column here to see the safe-layer overhead in isolation.
