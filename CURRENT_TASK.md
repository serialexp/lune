# CURRENT TASK — JIT pure-builtin tracing (`math.sqrt` → native `sqrtsd`), F0

Governing intent (Bart): close the LuaJIT gap one named technique at a time. The
string-keyed field lever (H0+H1) landed and is committed (`86f0710`). The next
chosen lever is **sqrt-from-trace**: make `math.sqrt(x)` inside a hot traced loop
record a trace instead of aborting `recCall` with `.host_barrier`. Target
benchmark: **nbody** — its inner loop `local mag = sqrt(dx*dx + dy*dy + dz*dz)`
records zero traces today; `sqrt` reaches the loop as a loop-invariant upvalue
(`local sqrt = math.sqrt`). Approved plan:
`~/.claude/plans/clever-yawning-neumann.md`. Design doc:
`docs/design/12-pure-builtin-tracing.md`.

Phased: **F0** = identity plumbing + recorder + tier-1a oracle (byte-identical
across 8 modes + replay, NO speedup, native auto-declines) → **F1** = native
`sqrtsd` lowering (the speedup).

**Decisive insight:** `math.sqrt` lowers to a SINGLE x86-64 instruction
`sqrtsd xmm,xmm` — no libm call. This is the `int_of_float` pattern (a
self-identifying unary IR op → one SSE instruction), NOT a general "call C from
native" feature. `@sqrt(f64)` (tier-0 / oracle) and `sqrtsd` (native) are IEEE
correctly-rounded and bit-identical under the default MXCSR (lune never calls
`fesetround`).

## F0 — DONE, GREEN (uncommitted, pending Bart approval)

`just test` green (`--summary all` → test success). Native auto-declines any
trace carrying the two new ops (`proveKinds`' existing `else => return false`),
so the `record_execute_native` mode runs the tier-1a oracle on the body.

### Mechanism

Two new `IrOp`s (appended at the END of the enum, wire-ordinal-stable):
`guard_pure`=45 (a=callee ref, aux=`@intFromEnum(PureBuiltin)` → callee-identity
guard, classified `.guard`), `fsqrt`=46 (a=float arg ref, ty=.float → leaf
producer computing `@sqrt`, classified `.unary` but never folded). Total 47 ops.

- **`src/function.zig`**: `PureBuiltin` enum `{ sqrt }` (stable replay-safe native
  identity, never a pointer); `pure: ?PureBuiltin = null` on `Native` + `BaseNative`.
- **`src/stdlib/math.zig`**: `.pure = .sqrt` on the `math.sqrt` registry row.
- **`src/interp.zig`** (`defineNative`) + **`src/keyframeser.zig`** (HeapNative
  restore): copy `pure` through alongside `effect`/`multi` — install and replay can
  never disagree about what is an inlinable pure builtin.
- **`src/trace.zig`**: `recCall`'s `.native` arm branches on `nat.pure` (`.sqrt` →
  `recPureSqrt`, else `.host_barrier`). `recPureSqrt` rejects nargs≠1 / nresults≠1
  (`.cross_frame`) and a non-float arg (`.bad_type`), then emits
  `guard_pure(callee)` (deduped via `guarded_refs`) → `guard_float(arg)` →
  `fsqrt(arg)`, result in the call's dest reg. NO frame push / NO `recReturn` (leaf).
- **`src/irinterp.zig`**: `guard_pure` side-exits unless the value is a `.native`
  carrying exactly the `aux` `pure` tag; `fsqrt` = `Value.float(@sqrt(arg))` with a
  defensive non-float side-exit.
- **`src/tropt.zig`**: `guard_pure` → `.guard` (dedup aux via `guardKeyAux`);
  `fsqrt` → `.unary` (hoistable/DCE-able) but explicitly skipped by the constant
  folder (`if (ins.op != .fsqrt)`), so `@sqrt` is never computed at compile time.
- **`src/troptdiag.zig`**: both ops added to the single-operand uses-count and
  consumer-set passes.
- **`src/nativegen.zig`**: NO new code — `proveKinds`' `else => return false`
  declines the trace → tier-1a oracle runs (mirrors the H0 decline).
- **`src/traceser.zig` + `viz/src/enums.ts`**: ordinals 45/46 pinned (count → 47);
  viz mirrors by position.

### The determinism crux

The trace bakes in "callee is sqrt". The `sqrt` upvalue can be reassigned between
trace entries, so `guard_pure` (in BOTH oracle and native) re-proves the callee is
still the `sqrt` builtin and side-exits to tier-0 on the same iteration in both
tiers when it changes. Identity is a `PureBuiltin` enum (never a pointer); replay
rebinds natives by registry name, so the enum rides the registry and is
replay-stable. The callee is a once-seeded loop-invariant input → `guard_pure` is
LICM-hoistable (one check per entry).

### Tests (all green)

- **Recorder units (`trace.zig`):** `recPureSqrt: sqrt(float)` asserts the
  `slot_load → guard_pure → slot_load → guard_float → fsqrt` order, `guard_pure.a`
  = seeded callee ref, `guard_pure.aux == @intFromEnum(.sqrt)`, `fsqrt.a` = arg
  ref, `fsqrt.ty == .float`, and the call dest holds the `fsqrt` result.
  Abort units: `sqrt(a,b)` / `x,y=sqrt(a)` → `.cross_frame`; int arg →
  `.bad_type`; a non-pure native (`print`-shaped) → `.host_barrier`.
- **8-mode `expectProgram` (`interp.zig`):** a float-reduction sqrt loop
  (`3472.556388576408`); a rebound-upvalue guard_pure deopt
  (`3472.556388576408\n45450`); the NaN / `-0.0` edge cases (`-nan\n-0`) — all
  byte-identical across {stress × {off, record-only, no-opt, record-execute,
  native}} + keyframe restore.

### Manual end-to-end verification (rebuilt CLI)

- `/tmp/sq1.lua` (float-reduction) `--dump-traces` shows `guard_pure %1 [sqrt]`
  and `fsqrt`. `/tmp/sq3b.lua` records 2 fsqrt traces (NaN + -0.0 loops).

### Pending (F0)

Codex + Antigravity review (determinism of the `PureBuiltin` identity guard, the
`@sqrt`≡`sqrtsd` bit-equality, abort coverage), then surface to Bart and request
commit approval (Rule #15 — no commit without explicit approval).

## F1 — DONE, GREEN (uncommitted, pending Bart approval)

`just test` green. Native `sqrtsd` lowering landed; F0 decline removed.

### Mechanism (F1)

- **`src/x64.zig`**: `sqrtsdRegReg`/`sqrtsdRegMem` (`F2 0F 51 /r`) + two encoding tests.
- **`src/nativegen.zig`**:
  - New `Kind.native` for the callee-snapshot slot (a heap native pointer, GP home
    like `.func`/`.ptr`).
  - `proveKinds`: a `pure_guarded` pass marks the `guard_pure`-covered slot_load
    `.native` (parallel to `func_guarded`); `guard_pure` → `.none`; `fsqrt` →
    `.float` iff operand proven float.
  - `SlotInfo.pure_tag` carries the recorded `PureBuiltin` ordinal; `analyzeInner`
    stashes it from the covering `guard_pure` (mirrors the `func_id` stash, with the
    same two-guards-disagree bail).
  - **Prologue** checks each `.native` slot ONCE (like `guard_func`, NOT via LICM):
    `header.type==native` ∧ `[native+pure]==tag` ∧ `[native+pure+1]==1`. The
    `?PureBuiltin` field is 2 bytes `[payload, has_value]` (verified empirically); two
    byte compares avoid needing a 16-bit-immediate compare encoder. Miss →
    `prologue_fail` (returns 0, side-exits to tier-0).
  - **Body**: `guard_pure` joins the hoisted no-ops; `fsqrt` = `floatOperandToXmm`
    (stage arg into xmm0) + `sqrtsdRegReg(xmm0,xmm0)` + store to the float home. No
    body side-exit (a stale callee is caught by the hoisted prologue guard).
  - `isTransient`/`operandReads` updated; `else => return false` decline removed for
    the two ops. `Kind.native` added to the two `guard_true/false` unreachable lists.

### Verification (F1)

- `--dump-native` on a sustained sqrt loop shows `f2 0f 51 c0` (`sqrtsd xmm0,xmm0`).
- Native ≡ tier-0 on the float-reduction loop (`59650.633125239394`) and the
  rebound-upvalue deopt (`7464.5342420517045\n125750` — guard_pure prologue side-exits
  to tier-0 when `sqrt` is reassigned, tier-0 runs the new closure).
- **Measure:** sustained `s += sqrt(i*1.0)` (5e7 iters): tier-0 **1.39 s** →
  `--jit-native` **0.37 s** (**3.8×**); LuaJIT 0.07 s.
- **nbody is UNCHANGED** (`bench` N=50000: t0 286 ms → jit 285 ms): it records ZERO
  traces because its inner `for j=i+1,nbody` loop has trip count ≤4 (nbody=5), too
  short to trip the back-edge hotcount. The sqrt abort *was* a real blocker (a
  sustained copy of the inner body now records + compiles native), but the
  short-trip-count blocker is independent and out of this lever's scope — a future
  lever. Recorded honestly in doc 12.

### Review (F1) — DONE, both reviewers signed off

Codex + Antigravity both reviewed the F1 diff: **no P0/P1 correctness or determinism
bugs**. Both confirmed (1) the native `guard_pure` prologue check (header.type==native,
flag byte==1, payload==recorded tag) is byte-identical to the oracle's `guard_pure`
arm in `irinterp.zig` — no 8-mode divergence; (2) the `?PureBuiltin` 2-byte
`[payload, has_value]` layout + `@offsetOf(Native,"pure")` base are correct on the
pinned toolchain (Native's header is field 0, so the native pointer == `*GcHeader`);
(3) `@sqrt` ≡ `sqrtsd` bit-for-bit under default MXCSR (verified `-0.0`, negatives→qNaN,
`±inf`, subnormals); (4) hoisting `guard_pure` to the prologue is safe — a reassigned
callee local becomes a `.carried` non-scalar slot and bails to tier-1a, and
`set_upval`/`set_global`/storing-a-native-to-a-table all abort recording; (5) the
fsqrt body lowering is sound.

**Hardening applied from the shared low-priority suggestion:**
- `comptime` assert `@sizeOf(?PureBuiltin) == 2` next to `NATIVE_PURE_OFF`, plus a new
  runtime test (`nativegen: ?PureBuiltin is laid out [payload, has_value] …`) pinning
  the payload@+0 / flag@+1 byte order the prologue depends on — a future toolchain
  optional-layout change now fails the build/test instead of silently miscompiling.
  (The byte *order* can't be comptime-asserted — an optional has no well-defined
  comptime layout to deref — so it lives in the runtime test.)
- Fixed a stale `floatOperandToXmm` unreachable comment to mention `.native`; passed
  `.float` literally to the fsqrt `floatOperandToXmm` to match the `int_of_float` sibling.

Gate still green after the additions.

### Pending (F1)

Surface to Bart and request commit approval (Rule #15 — no commit without explicit
approval).

## Stdlib inventory

Untouched — F0 is a JIT recorder change. `math.sqrt` stays `status=implemented`
(`docs/lua-stdlib-inventory.csv:74`).
