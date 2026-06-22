# CURRENT TASK — native-level work: safety net (Part 1) + shift codegen (Part 2)

Governing intent (Bart): "that was a good flip for our interpreter level, but we
really need to get back to the native level." Direction chosen: **"Both, in
order"** — land the native-unsupported safety net first (stop the `--jit-native`
regression vs tier-0 on traces that can't go native), then add shl/shr native
lowering so shift-heavy loops (nsieve-bit) compile native instead of being retired.

SoA register file (phases 0–2) is **committed** (`827b286` + `79402e0`). This task
is on top of that.

## Part 1 — native-unsupported safety net — DONE, GREEN (uncommitted)

### The regression it fixes
Under `--jit-native`, a recorded trace that compiles to native-*unsupported*
(`nativeFor` → null) previously fell back to the **tier-1a IR-interpreter**, which
is ~equal-to-slower than tier-0 on the bodies that hit it (shift-heavy sieves) — so
enabling native codegen *regressed* those loops vs plain tier-0. The existing
thrash gate (`onSideExit`/penalty) never caught it because the trace *completes*
its iterations on tier-1a (just slowly), so `completed` stays high.

### The fix (determinism-safe: tier-0 and tier-1a are byte-identical; non-native
modes still run every trace on tier-1a, preserving oracle coverage)
- **src/trace.zig** — `gateNativeUnsupported(anchor)` (after `onSideExit`): gates
  the anchor immediately (no `max_penalty` wait — "unsupported" is known the first
  time `nativeFor` compiles). Self-heals via the gate's backoff + `onSideExit`
  clear. Keyed only on the deterministic back-edge `tick`.
- **src/interp.zig** dispatch walk (3 edits):
  1. `var saw_native_unsupported = false;` before the trial walk.
  2. In the walk, after `matchesFingerprint`: if `native_codegen and
     nativeFor(ct) == null`, set `saw_native_unsupported` and **skip** (never enter
     tier-1a). A native-supported sibling at the same anchor still runs.
  3. At the post-walk fall-through (reached only when nothing ran productively —
     a productive entry does `continue :outer`): if `saw_native_unsupported`, call
     `gateNativeUnsupported`. The following `afterBackEdge` arms the `GATE_SKIP`
     hot-count window so tier-0 owns the loop.

### Verified
- `just test` exit 0 (all 8 modes byte-identical).
- Instrumented run confirmed the net fires on its intended targets and is inert
  elsewhere:
  - **nsieve-bit** (shift-heavy, both traces unsupported): gates=11, entries=0
    (kept off tier-1a). Wall-clock **2.1× regression → ~1.05× (neutral)**.
  - **repack_adversarial poison**: gates=6, entries=0. **1.5× → ~1.05×**.
  - **scimark-sparse**: gates=0, skips=0, **entries=0** — safety net inert (see
    below). Unchanged.
- `just bench` full suite: every `cross=ok`, only the pre-existing `str_manip`
  LuaJIT-reference flag. No new regressions; all prior JIT wins intact (nsieve
  168→65, fft 721→546, lu 769→165, sor 560→85, pi 189→42, sieve_int 77→13).

### scimark-sparse residual (~17% jit>t0) — OUT OF SCOPE for the safety net
Diagnosed via instrumentation, NOT a native-unsupported / tier-1a problem:
- The hot inner loop `for i=row[r],row[r+1]-1 do sum=sum+vx[col[i]]*val[i] end`
  runs exactly **nr = floor(nz/n) = floor(5000/1000) = 5** trips — below
  `min_trip_entry=24`, so the dispatch **trip-declines** entry every invocation
  (`entries=0`). The trace never runs (native or tier-1a); the safety net never
  engages.
- The overhead is pure trace-dispatch bookkeeping on a short hot loop nested in a
  hot outer loop: per-back-edge `onBackEdge` (hashmap getOrPut) + `isGated` +
  `armShortLoopSkip`, plus the middle loop (`for r=1,n`, 1000 trips) which never
  commits a trace and re-pays `onBackEdge` + fingerprint-miss every back-edge.
  Pure tier-0 (no `--trace`) skips all of it (`config.enabled=false`).
- This is a distinct, **pre-existing** JIT-coverage / recorder-bookkeeping issue
  (short trip-declined inner loop + un-committable middle loop), addressable only
  by cheaper warming-loop bookkeeping or by tracing the middle loop with the inner
  unrolled — neither is the safety net nor shift codegen. Logged in TODO.md.

## Part 2 — shl/shr native codegen lowering — DONE, GREEN (uncommitted)

Added `shl`/`shr` to the nativegen supported op set. Confined to **two files** —
no new IR op, no recorder/snapshot/irinterp/tropt change (shl/shr stay opaque ops;
only native lowering was added):
- **src/x64.zig** — `shlRegCl`/`shrRegCl` (REX.W `D3 /4`, `D3 /5`), `Cond.s = 0x8`
  (sign), golden-byte test.
- **src/nativegen.zig** — proveKinds Int arm admits shl/shr; `isTransient` +
  `operandReads` arms; `emitShift` lowering + lower dispatch.

### The lowering (branch-bracketed `cl`-shift)
x86 `shl/shr reg,cl` honours only the low 6 bits of the count, but Lua's
`arith.shiftLeft`/`shiftRight` are full logical shifts where `|count| ≥ 64 → 0` and
a negative count reverses direction. So `emitShift` brackets the hardware shift with
explicit range checks: load count into **rcx first** (the operand's home may be the
dst reg, since cut-2 may reuse a dying operand's home as the result); `cmp rcx,0` +
`js` → negative branch (negate, shift the *other* way); `neg`/`cmp rcx,64` + `jae` →
`|count| ≥ 64` → `xor W,W` (result 0); else the bare `cl`-shift. Uses only the dst
register (or rax for a spilled dst) + rcx scratch — fits the two scratch registers
the cut-2 allocator guarantees, regardless of operand homes.

### Verified
- **Differential test** (nativegen.zig, `expectShiftMatch`): builds a loop body
  `acc = X <op> N` and runs the tier-1a oracle (irinterp → `arith.shl/shr`) vs the
  native compile across every count regime — 0, 5, 63, **64**, 100, **-4**, -1,
  **-64**, **INT64_MIN** — so the expected bits come from the oracle, not re-derived.
- `just test` exit 0 — all **8 modes byte-identical**, including the new shift test.
- **nsieve-bit native win**: output byte-identical (tier-0 vs `--jit-native`); the
  two shift-bearing inner loops now compile native (538 + 448 bytes). Bench
  **t0 139.2 ms → jit 55.3 ms (2.5×)** — was a ~2.1× *regression* under Part 1's
  safety net before shl/shr lowering, now a native win.
- `just bench` full suite: every `cross=ok`, only the pre-existing `str_manip`
  LuaJIT-reference flag. No new regressions; all prior JIT wins intact.

### nsieve-bit `trace #2` still native-unsupported — separate follow-up (logged)
The array-init loop `for i=0,(m>>6) do p[i]=-1 end` (in-bounds on the 2nd/3rd
`nsieve` call) stays unsupported, but **not for a shift reason** — diagnosed via
temporary `[NGDBG]` prints (since reverted) to `astore int-lane no fits_ok`. The
constant store value `-1` has its `guard_fits` DCE'd by tropt (constant trivially
fits the lane), yet proveKinds's int-lane `astore` requires `fits_ok[ins.b]`
unconditionally — the exact case already exempted for the f64/bool lanes. Logged as
TODO.md item 9; distinct from shl/shr, needs its own plan + review.

## Gate / process
- Do NOT commit without Bart's explicit approval (Rule #15).
- Codex + Antigravity review of Parts 1+2 before landing.
- Stray untracked files (CURRENT_TASK_E3.md, SESSION_CHANGES.md, check_ordinals,
  bench/results/*.tsv) are NOT mine — left untouched.
