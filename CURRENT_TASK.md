# CURRENT TASK — LuaJIT benchmark corpus + long-bracket strings

Governing arc: chase Lua compatibility so lune is usable, then optimize. Bart's
steer after landing require/package: "grow the corpus first."

## Landed this session

1. **`ee6a821`** base-host cleanup (os.clock float / os.nsclock / warn).
2. **`5c47b3a`** require/package module system (base-host, host-injectable loader).
3. **`bde108e`** vendored LuaJIT macro-benchmark corpus — `bench/luajit/` with the
   8 CLBG ports that run byte-identical to LuaJIT today (array3d, binary-trees,
   nbody, nsieve, nsieve-bit-fp, partialsums, recursive-fib, spectral-norm).
   Baseline: t0/lj 8x–112x; the JIT is a no-op on the float/array-heavy benches
   (coverage gap, not codegen). README + TODO document the per-gap backlog.

## Landed — long-bracket strings

Genuine Lua 5.4 conformance gap: lune lacked long-bracket strings **entirely**
(even `[[…]]`), only long *comments* at level 0. Implemented:

- **lexer.zig**: `longBracketLevel`/`longBracketClose` helpers; `longString`
  scanner emits the whole `[==[…]==]` as one `.string_literal`; `next()` dispatch
  on `[`; `skipComment` generalized to leveled `--[=[…]=]`. Sentinel-safe (`=`/`]`
  scans stop at the `0` terminator).
- **compiler.zig**: `decodeString` branches on `raw[0]=='['` →
  `decodeLongString`: compute level, strip `level+2` each side, drop one leading
  EOL (\n/\r/\r\n/\n\r), **no escapes**, UTF-8 validate. Returns a source-slice
  (safe — `stringConstant` interns/copies immediately).
- **Tests**: lexer unit (levels 0/1/2, nested `]]`, leveled comment, unterminated,
  `[` still indexes); interp 8-mode e2e (concat+#len, leading-newline drop, no
  escapes, leveled passthrough, leveled comment). `just test` + check-version green.
- **Docs**: lexer module doc, 00-architecture Phase-2 line, TODO updated.

Deliberately **not** added: `loadstring` (5.1 alias) — unlocks nothing measurable
alone. Long strings did NOT unlock the dynamic-codegen benches (fasta/pidigits/
revcomp/meteor) — they need the `jit` module, numeric-chunkname loadstring, stdin.

Reviewed clean (Codex + Antigravity), gate green, committed.

## Next (Bart's steer: grow the corpus)
Discussing the **`bit` library** (euler14-bit, nsieve-bit — clean text output)
with Bart: does a LuaJIT `bit` (int32-normalized, pure/deterministic → base-host)
belong in lune, or stay a bench-only shim? Pending his language-surface decision.
