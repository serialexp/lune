# CURRENT TASK — grow the bench corpus (scimark) then pivot to optimization

Governing arc: chase Lua compatibility so lune is usable, then optimize. Bart's
steer: "grow the corpus first," then profile + optimize. The corpus is now
settled for the surfaces Bart cares about (no coroutines / io for now).

## Landed earlier this session (committed)

1. **`5c47b3a`** require/package module system (base-host).
2. **`bde108e`** vendored LuaJIT macro-benchmark corpus (8 CLBG ports).
3. **`0c09771`** long-bracket string literals `[[…]]` / `[=[…]=]`.
4. **`6057b54`** distinct bitwise-fault messages (describeFault split + arith.zig
   policy comment + 8-mode test).
5. **`26ba124`** euler14-bit / nsieve-bit native-operator benches + `luajit_src=`
   harness key + `_ref/` verbatim originals (corpus 8→10).

## In progress — scimark suite (NOT yet committed)

Vendored the SciMark numeric-throughput kernels via require-from-cwd. Corpus 10→14.

- **bench/run.py** (uncommitted): `run_once`/`time_best` gained a `cwd=` param
  passed to `subprocess.run`; the per-bench loop computes `bench_dir =
  os.path.dirname(b.path)` and passes `cwd=bench_dir` at all 6 call sites. This
  mirrors LuaJIT's `run.sh` (`cd $BENCH_DIR`) so `package.path`'s `./?.lua`
  resolves the shared lib. The bench path itself stays absolute, so cwd only
  affects `require`.
- **bench/luajit/scimark_lib.lua** (new, verbatim, NO `@bench` header → discovery
  skips it): the shared FFT/LU/SOR/SPARSE/MC kernel library.
- **bench/luajit/scimark-{fft,lu,sor,sparse}.lua** (new): the upstream one-liner
  wrappers + a `-- @bench args="…" luajit=compatible name=scimark-…` header.
  Workload args (≈1 s each on ReleaseFast): fft=500, lu=80, sor=1000, sparse=3000.
  The kernels return a flop count the wrappers discard → **empty stdout** → pure
  timing benches (empty == empty satisfies `luajit=compatible` parity).
- **docs**: bench/README (corpus 10→14, the require-from-cwd section), TODO
  (require-from-cwd DONE + str_manip pre-existing-bug note).

Harness verified: all 4 `scimark-*` show `cross ok` + `luajit ok`; the full suite
still passes (no regression from the cwd change). The scimark kernels sit **35–76×
off LuaJIT** — exactly the float/array throughput lune's tracing JIT is a no-op on.

### Pre-existing bug surfaced (NOT mine to fix in this commit)
`bench/stdlib/str_manip.lua` is mislabeled `luajit=compatible` but calls
`string.codepoint` (5.3+), which LuaJIT lacks → `luajit=ERR`. Independent of the
cwd change (errors identically from repo root). Noted in TODO.md for a separate
bench-fix pass.

### Review + commit
Run Codex + Antigravity if Bart wants a review (this is bench-harness + vendored
Lua only — no VM/effect/determinism surface, so a lighter touch than the prior
commits). Then Bart's commit approval (Rule #15). Suggested message:
`bench: add scimark suite via require-from-cwd (corpus 10→14)`.
Stray untracked files (CURRENT_TASK_E3.md, SESSION_CHANGES.md, check_ordinals,
bench/results/*.tsv) are NOT mine — leave them.

## Next (the pivot Bart deferred): profile the 14+ corpus, optimize
With the corpus settled, return to the governing arc's second half: `perf record`
the corpus (the scimark kernels are the new float/array targets), roll symbols up
by tier, and pick the next named optimization technique. See the bottom of
CLAUDE.md (the profile-FIRST recipe) and TODO's "Native codegen follow-ups" +
"tier-0 interpreter perf" sections for the levers.
