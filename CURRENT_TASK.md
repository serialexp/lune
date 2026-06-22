# CURRENT TASK — tier-0 array decode/encode fast path (Gap T0-array)

Governing arc: chase Lua compatibility so lune is usable, THEN optimize toward
LuaJIT parity. After the JIT-coverage arc (Gap A/B/C), we pivoted to the tier-0
interpreter — the denominator under every benchmark, including the ones the JIT can't
trace.

## Profile-first finding (decisive)
Pure tier-0 `perf record` (no `--trace`, ReleaseFast) of the array-heavy scimark
kernels overturned both hypotheses (Bart guessed dispatch):
- **Dispatch `jmp` = 0.46%** (confirms the old T2 threaded-dispatch skip was right).
- **`array.ArrayPart.decode` = 54.8% of scimark-sparse, 11% of fft** — an *out-of-line
  call per element* across the interp.zig→array.zig module boundary.
- The rest of fft's `execImpl` is inherent **16-byte `Value` shuffling** (`vmovapd`
  stack spills + `×16` offsets). **NaN-boxing is OFF THE TABLE** (Value's explicit
  `payload.bits` layout is foundational to determinism+replay). So we cut cost *around*
  the Value, not the Value.

## Change — IMPLEMENTED (uncommitted, awaiting Bart's commit approval)
All in **src/array.zig**:
1. Marked `get`, `setInLane`, `decode`, `encode` **`inline`** so the read/write chain
   folds into `execImpl` — the loop-invariant lane `switch` hoists and the per-element
   call vanishes. (decode went from a 55% standalone symbol to fully inlined; sparse
   `perf` now shows execImpl 98%, no separate decode.)
2. Removed a gratuitous `@memcpy`-into-stack-buffer round-trip in `readInt`/`writeInt`
   — pass the `*const [n]u8` slice straight to `std.mem.readInt(.little)`. Byte-for-byte
   identical (same function minus the dead copy); this alone was ~0% (the memcpy was
   already LLVM-elided) but it's a clean simplification kept in the same change.

Nothing else changed — recorder, oracle (irinterp), serializer (keyframeser), native
(nativegen, which uses raw loads, not these fns) all untouched.

## Measure (`just bench`, ReleaseFast, all `cross=ok` = 8-mode byte-identical)
Tier-0 (t0 ms) before → after:
- scimark-sparse: 866 → **770** (~11%)
- scimark-lu:     1162 → **1019** (~12%)
- scimark-sor:    953 → **871** (~9%)
- scimark-fft:    994 → **911** (~8%)
Other benches flat (not decode-bound). No regressions; every `cross=ok`.

## Gate / reviews
`zig build test` exit 0; `just check-version` exit 0. Full `just bench` all `cross=ok`
(the recipe's exit 1 is a pre-existing `str_manip` *LuaJIT-parity* flag — `luajit=ERR`,
not a lune determinism issue, and unrelated to this array change). Reviewed by Codex +
Antigravity — both confirmed sound, no findings (readInt change byte-identical incl. f64
NaN payload bits; `inline` is codegen-only, no semantic/oracle/serializer effect).

## Suggested commit (Preference #2 conventional commits)
`perf(interp): inline tier-0 array decode/encode into the hot opcode arms`
Files: src/array.zig, TODO.md, CURRENT_TASK.md.
Stray untracked files (CURRENT_TASK_E3.md, SESSION_CHANGES.md, check_ordinals,
bench/results/*.tsv) are NOT mine — leave them. Also untracked from the prior session:
docs/design/08-multi-store-sinking.md (Gap C — separate, already-approved commit).

## Why no design doc
This is a contained 2-part micro-opt (inline hints + dead-memcpy removal) in one file,
not a subsystem — noted in TODO.md's perf section instead.

## Follow-ons (not this change)
- The inherent 16-byte `Value` register-file shuffling in `execImpl` — not addressable
  without changing the Value rep (forbidden).
- Faster tier-0 for the genuinely-interpreted remainder beyond array access — the next
  profile would need to target the post-inline execImpl hot instructions.
- Sparse's indirect `x[col[k]]` gather JIT coverage — distinct mechanism, still open.
