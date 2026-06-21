# CURRENT TASK — native bitwise operators + bit benchmarks

Governing arc: chase Lua compatibility so lune is usable, then optimize. Bart's
steer: "grow the corpus first." Bitwise was the next unlock.

## Landed this session

1. **`5c47b3a`** require/package module system (base-host).
2. **`bde108e`** vendored LuaJIT macro-benchmark corpus (8 CLBG ports).
3. **`0c09771`** long-bracket string literals `[[…]]` / `[=[…]=]`.

## In progress — bitwise operators + bit benches (NOT yet committed)

Discovery: lune **already has native 64-bit bitwise operators** (`&` `|` `~` `<<`
`>>`, with `~=` disambiguated) — lexer/parser/compiler/VM (`arith.zig`)/metamethods
all wired by the metamethod arc (#102). No operator implementation was needed.

Bart's decision: do **not** add a LuaJIT `bit` module (its int32-normalization is a
32-bit island in a 64-bit language; Lua 5.4 itself rejected it for native
operators). Stay **strict integer-only** (no integral-float coercion). Just fix the
misleading error message and rewrite the two benches to native ops.

- **arith.zig**: comment now states the deliberate strict-integer-only policy.
- **interp.zig `describeFault`**: bitwise ops (`band/bor/bxor/shl/shr/bnot`) split
  out of the *arithmetic* message arm. New helpers `firstNonInteger` +
  `bitwiseFaultMessage`: a float operand → "number has no integer representation";
  a non-number → "attempt to perform bitwise operation on a <type> value" (Lua-5.4
  shaped). New 8-mode e2e test pins both. `just test` + check-version green.
- **bench/luajit/euler14-bit.lua, nsieve-bit.lua**: native-operator rewrites,
  semantically equivalent to the upstream `bit.*` versions. Verified byte-identical
  to LuaJIT across scales. Corpus is now **10**.
- **bench/run.py**: new `luajit_src=` metadata key — LuaJIT runs an alternate
  source (the verbatim `bit.*` original under `bench/luajit/_ref/`) while lune runs
  the native-operator file. Preserves the "byte-identical to LuaJIT" corpus
  property for files using 5.4 syntax LuaJIT (5.1) can't parse. Harness confirms
  both benches `cross ok` + `luajit ok`.
- **docs**: bench/README (verbatim vs adapted, the `_ref/`+`luajit_src` mechanism,
  corpus list 8→10), TODO (bit RESOLVED-not-added rationale).

### Review + commit
Run Codex + Antigravity on the core diff (interp.zig describeFault + arith.zig),
then Bart's commit approval (Rule #15). Suggested message:
`feat(interp): distinct bitwise-fault messages; add euler14-bit/nsieve-bit benches`
(or split: interp/arith error-message change as one commit, the bench+run.py as a
second). Stray untracked files (CURRENT_TASK_E3.md, SESSION_CHANGES.md,
check_ordinals, bench/results/*.tsv) are NOT mine — leave them.

## Next (Bart's steer: grow the corpus)
Remaining unlocks (TODO.md): `coroutine` library (chameneos, coroutine-ring —
largest, determinism-adjacent); `require`-from-cwd in run.py (scimark suite,
small); binary/Latin-1 output (mandelbrot, fannkuch); io.read shapes
(k-nucleotide, sum-file).
