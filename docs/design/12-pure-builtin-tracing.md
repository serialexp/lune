# lune — tracing pure builtins (`math.sqrt` → native `sqrtsd`)

Status: **partial — F0 (recorder + tier-1a oracle) landed; F1 (native `sqrtsd`)
outstanding.** F0 is byte-identical across all 8 determinism modes + keyframe
replay. The tier-1a oracle exercises the two new ops via the record-execute and
record-execute-noopt modes; native codegen *declines* any trace carrying them, and
in `--jit-native` mode a declined trace is skipped so the loop falls back to
**tier-0** (not the oracle — see `nativeFor == null → continue` in the dispatch
walk, `interp.zig`). All five trace modes therefore agree byte-for-byte. No speedup
yet (that is F1).
Owner: Bart
Last updated: 2026-06-26

Prerequisite reading: `00-architecture.md` (tiers + the determinism asterisk),
`01-trace-lifecycle.md` §"Loop-header re-entry deopt" (the deopt model guards
rest on), `02-determinism.md` (why an identity is the *registry name*, never a
serialized pointer), and the `int_of_float` arc in `05-native-codegen.md` (the
self-identifying-unary-op → one-SSE-instruction pattern this mirrors).

## Why this exists

A native call inside a hot loop aborts the recorder at `recCall` with
`.host_barrier` (`trace.zig`) — it crosses the embedding boundary, and the trace
can't model arbitrary host effects. But a handful of stdlib functions are **pure
deterministic builtins**: `math.sqrt(x)` is a mathematical function of its float
argument with no state, no effect, and — decisively — it lowers to a **single
x86-64 instruction `sqrtsd xmm, xmm`**, not a libm call.

nbody (`~/Projects/LuaJIT/bench/nbody.lua`) records **zero traces** today: its
inner loop `local mag = sqrt(dx*dx + dy*dy + dz*dz)` hits the `sqrt` upvalue and
aborts before the rest of the loop matters. This lever inlines such a call as a
dedicated leaf IR op (`fsqrt`) instead of aborting, the same way `int_of_float`
is a self-identifying unary op rather than a general "convert anything" feature.

This is **not** a general "call C from native code" feature: x64.zig has no `call`
emitter, and `sin`/`cos`/`exp` would drag in libm with a cross-version
reproducibility hazard. It is deliberately scoped to builtins that *are* one SSE
instruction and *are* IEEE correctly-rounded.

## Goals

- `sqrt(x)` on an observed-float argument records a trace, byte-identical across
  all 8 modes + replay (F0), then runs native as one `sqrtsd` (F1).
- nbody records a native trace and moves off its tier-0 baseline.
- The mechanism generalizes to future one-instruction pure builtins (`floor`,
  `abs`, …) by adding a `PureBuiltin` enumerator + an `f*` op — no new machinery.

## Non-goals (v1)

- Non-float arguments (`sqrt(4)` with an int literal): the recorder aborts
  `.bad_type` so tier-0 owns the int→float promotion. (A later `guard_number` +
  cvt could admit it.)
- libm builtins (`sin`/`cos`/`exp`/`log`/…): no `call` emitter, and a
  cross-libm-version bit-reproducibility hazard. Explicitly excluded.
- Multi-arg / multi-result pure builtins: `fsqrt` is a leaf unary producer.

## The determinism crux — callee-identity guard

The trace bakes in "the callee is `sqrt`" (an `fsqrt` op computing `@sqrt`
directly). The `sqrt` upvalue could be **reassigned between trace entries**
(`sqrt = function() … end`). So a guard, present in **both** the tier-1a oracle
and the native code, must side-exit to tier-0 on the **same iteration** in both
tiers when the callee is no longer the `sqrt` builtin.

- **Stable identity is a `PureBuiltin` enum, never a pointer.** `pure: ?PureBuiltin`
  rides `Native`/`BaseNative` (`function.zig`); the `math.sqrt` registry row sets
  `.pure = .sqrt`; `defineNative` (`interp.zig`) and the keyframe restorer
  (`keyframeser.zig`) copy it through exactly as `effect`/`multi`. Because the
  restorer rebinds natives by registry name, `pure` rides the registry and is
  replay-stable by construction — no pointer is ever serialized (doc 02).
- **`guard_pure` (a=callee ref, aux=`@intFromEnum(PureBuiltin)`)** re-proves the
  identity. The callee is a once-seeded loop-invariant input (an upvalue/global
  read seeded by `recInputGet`), so the value is loop-invariant and the guard is a
  LICM candidate — but the current LICM pass does **not** hoist guards (re-checking
  an invariant value each iteration is cheap; hoisting is a later refinement that
  would buy ~nothing per iteration once F1 lowers it to native). `fsqrt` reads the
  float *argument*, not the callee pointer, so a
  stale callee is caught by an ordinary guard side-exit with no unsafe deref — no
  seed-time native-decline is needed (unlike `hash_cell`).

## The `@sqrt` ≡ `sqrtsd` bit-equality (the MXCSR invariant)

`@sqrt(f64)` (tier-0 `mSqrt`, the tier-1a oracle's `fsqrt` arm) and native
`sqrtsd` are **both IEEE-754 correctly-rounded** square root. Under the default
**MXCSR** (round-to-nearest-even), they agree **bit-for-bit**, including the edge
cases: `sqrt(-0.0) = -0.0`, `sqrt(x<0) = qNaN`, `sqrt(+inf) = +inf`.

**lune never calls `fesetround`** and never mutates MXCSR. This is the invariant
the bit-equality rests on; it is recorded here so a future SSE-rounding feature
can't silently break replay. `fsqrt` is also deliberately **left unfoldable** in
`tropt` (like `int_of_float`) — we never compute `@sqrt` at compile time, removing
any fold-vs-runtime sign/NaN divergence surface.

## Op set (append-only, wire-ordinal-stable)

Two new `IrOp`s after `guard_hash` (44); new total 47:

| op | ordinal | operands | kind | notes |
|----|---------|----------|------|-------|
| `guard_pure` | 45 | `a`=callee ref, `aux`=`PureBuiltin` ordinal | `.guard` | callee-identity; deduped via `guardKeyAux` (aux is semantic) |
| `fsqrt` | 46 | `a`=float arg ref, `ty`=`.float` | `.unary` | leaf producer; never folded; hoistable iff operand invariant |

Lockstep: `traceser.zig` ordinal contract test (45/46, count → 47),
`viz/src/enums.ts` (both names + the unary-render set), `assertWellFormed` (both
read `a`).

## Implementation status

Tracking the gap between this design and what's on the main branch. Tick items as
they land; move whole sections to "done" once everything inside them is checked.

### Done

- [x] **F0 identity plumbing (`function.zig`, `stdlib/math.zig`, `interp.zig`,
  `keyframeser.zig`).** `PureBuiltin{ sqrt }` enum; `pure: ?PureBuiltin` on
  `Native` + `BaseNative`; `.pure = .sqrt` on the `math.sqrt` row; `defineNative`
  and the keyframe restorer copy `pure` through alongside `effect`/`multi`.
- [x] **F0 two `IrOp`s — `guard_pure`/`fsqrt` (`trace.zig`).** Appended at the end
  (wire ordinals 45–46, total 47); `assertWellFormed` widened (both read `a`);
  disassembly prints the callee + builtin tag for `guard_pure`.
- [x] **F0 recorder — `recPureSqrt` (`trace.zig`).** `recCall`'s `.native` arm
  branches on `nat.pure` (`.sqrt` → inline, else `.host_barrier`). The helper
  rejects nargs≠1 / nresults≠1 (`.cross_frame`) and a non-float arg (`.bad_type`),
  then emits `guard_pure(callee, aux=sqrt)` (deduped) → `guard_float(arg)` →
  `fsqrt(arg)`, landing the result in `instr.a`. No frame push / no `recReturn`.
- [x] **F0 tier-1a oracle (`irinterp.zig`).** `guard_pure` side-exits unless the
  value is a `.native` carrying exactly the `aux` `pure` tag; `fsqrt` =
  `Value.float(@sqrt(arg))` with a defensive non-float side-exit.
- [x] **F0 optimizer classification (`tropt.zig`, `troptdiag.zig`).** `guard_pure`
  is a `.guard` (dedup aux via `guardKeyAux`); `fsqrt` is `.unary` (hoistable,
  DCE-able) but explicitly skipped by the constant folder; uses-counting and
  consumer-set passes updated.
- [x] **F0 native auto-decline (`nativegen.zig`).** `proveKinds`' existing
  `else => return false` declines any trace carrying the two ops. No new code; in
  `--jit-native` mode the dispatch walk skips a non-compilable trace
  (`nativeFor == null → continue`), so the loop falls back to tier-0. The oracle
  path is exercised by the record-execute / record-execute-noopt modes instead;
  all five trace modes stay byte-identical.
- [x] **F0 wire ordinals (`traceser.zig` + `viz/src/enums.ts`).** 45/46 pinned by
  the contract test (count → 47); the viz tables mirror them by position.
- [x] **F0 tests (`trace.zig` + `interp.zig`).** Recorder unit asserts the
  `slot_load → guard_pure → slot_load → guard_float → fsqrt` order with
  `fsqrt.a == arg_ref`, `guard_pure.aux == @intFromEnum(.sqrt)`, and the call dest
  holding the `fsqrt` result; abort units cover `sqrt(a,b)` (nargs 2) /
  `x,y=sqrt(a)` (nresults 2) → `.cross_frame`, int arg → `.bad_type`, a non-pure
  native → `.host_barrier`; three 8-mode `expectProgram`s — a float-reduction sqrt
  loop, a rebound-upvalue guard_pure deopt, and the NaN / `-0.0` edge cases — all
  byte-identical across the matrix + keyframe replay.

### Outstanding

- [ ] **F1 — `x64.zig` `sqrtsdRegReg`/`sqrtsdRegMem`** (`F2 0F 51 /r`) + encoding
  unit test.
- [ ] **F1 — `nativegen.zig` lowering.** `proveKinds` `fsqrt` → `Kind.float` iff
  operand proven float, `guard_pure` → guard (no kind); `isTransient`/
  `operandReads`/`last_body_guard`; `lower`: `guard_pure` = deref callee header,
  check `heapType==.native` ∧ `[native+pure_off]==aux` → `jcc(.ne, deopt_exit)`
  (LICM-hoisted to preheader); `fsqrt` = `sqrtsd` into the float home. Remove the
  F0 decline for these two ops.
- [ ] **F1 — nbody coverage + measure.** `--dump-native` shows `sqrtsd`;
  `just bench --filter nbody` tier-0 vs `--jit-native` vs LuaJIT, recorded here.
- [ ] **Defer — non-float arg admission** (`guard_number` + cvt). Out of v1 scope.
- [ ] **Defer — further pure builtins** (`floor`/`abs`/…): one `PureBuiltin`
  enumerator + one `f*` op each; the machinery is reusable as-is.

## References

- `docs/design/05-native-codegen.md` — the `int_of_float` self-identifying-unary
  pattern this mirrors.
- `docs/design/02-determinism.md` — identity-by-registry-name, never a pointer.
- `~/Projects/LuaJIT/src/lj_ircall.h`, `lj_asm_x86.h` — Pall's `IRCALL`/`sqrtsd`
  fast path for the same builtin.
