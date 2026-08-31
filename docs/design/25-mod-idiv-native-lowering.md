# mahina — mod/idiv native lowering (the scalar-native frontier)

Status: **landed 2026-08-28.** Results: scalar **4.3× → 0.9× LuaJIT** (jit
instructions 633.7M → 78.7M, −87.6%); the safety net no longer fires on
`%`-carrying traces (VM-level e2e asserts `native_entries > 0` with `%`, `//`,
and a mixed int%float in one body). Instruction A/B vs the c4 shadow on the
non-`%` board: ≤ ±0.25% everywhere measured (partialsums jit ±0.0001%; the
small t0 drifts are recompiled-unit codegen jitter plus the new `y == -1`
compare in tier-0 int mod). Landed find: the oracle's claimed-safe
`minInt % -1` actually SIGFPE'd in every tier (`@mod` lowers to a raw idiv);
`arith.mod` now special-cases `y == -1 → 0` (any x), matching Lua 5.4's
`luaV_mod` — pinned in arith tests. Wall-clock boards taken under load ~20
were noise; the instruction A/B is the regression record.
Codex verdict: sound except (1) BLOCKER: the `(minInt, -1)` pair must NOT
side-exit (tier-1a produces the defined value and CONTINUES; a native exit
diverges via the deopt ledger and iteration replay) → materialize the special
result inline; (2) the proveKinds arm needs an exhaustive `ty` check (the
add/sub/mul arm's `else` treats `.boolean`/`.nil` stamps as int) plus
`a < i`/`b < i` operand bounds; (3) `div_save` must be an allocator-owned
unique spill slot (in `spill_count`, frame sizing, and the SPILL_MAX check —
never the callout alignment-padding slot), with a combined int-div +
float-callout + spill-pressure test. All three folded into D1/D3/D4 below.
Owner: Bart
Last updated: 2026-08-28

Prerequisite reading: `24-deterministic-on-trace-allocation.md` implementation
notes (the native-safety-net interaction that motivates this), `23-builtin-
recording-breadth.md` D4 (the shared-noinline-kernel identity discipline),
`02-determinism.md`.

Upstream reference: `~/Projects/LuaJIT/src/lj_asm_x86.h` (`asm_intmod` →
`IRCALL_lj_vm_modi`; note `lj_vm_modi` is a hand-written minimal-clobber asm
helper in `vm_x64.dasc`, NOT a SysV full-save call — so "Pall calls out" does
not license our heavyweight callout for the int case), `lj_vmmath.c`
(`lj_vm_foldarith` float mod: `a - floor(a/b)*b`).

## Why this exists

`mod` and `idiv` record (`recArith`) and run in tier-1a (`arith.mod` /
`arith.floorDiv`), but have **no native lowering** — `proveKinds` bails. Under
`--jit-native` the trial-walk safety net then declines any trace containing one
of them ENTIRELY (never falls back to tier-1a), so a single `%` locks a whole
loop out of the JIT. This is what holds scalar at 4.3× (its `i % 10` poisons
the trace) and what made three arc-B VM-level tests silently vacuous. The fix
is general per Z-6: every `%`/`//`-using program gains native coverage; no
benchmark-specific machinery.

Not in scope: `pow`-style rationalization of other ops, float unary `neg`,
`guard_number` — separately deferred, unchanged.

## Semantics to reproduce (the oracle, `arith.zig`)

| variant | stamped `ty` | result | corners |
|---|---|---|---|
| int `%` (both int) | `.int` | `@mod(x, y)` — floored, sign of divisor | `y == 0` → `DivisionByZero` (raise); `minInt % -1 == 0` (defined) |
| int `//` (both int) | `.int` | `@divFloor(x, y)` | `y == 0` → raise; `minInt // -1` wraps to `minInt` (defined) |
| float `%` (≥1 float) | `.float` | `x - floor(x/y) * y`, strict FP | `y == 0` → NaN via IEEE, **no error** |
| float `//` (≥1 float) | `.float` | `floor(x / y)`, strict | IEEE inf/NaN fall out, no error |

`arithResultType` stamps `.int` iff both operands int (unlike `div`/`pow`,
which are always float). The recorder needs no changes. tropt already refuses
to hoist mod/idiv (fallible → must side-exit at the exact tier-0 re-raise
point) and already leaves erroring folds as runtime ops. traceser wire pins
exist (`mod` = 7). Only nativegen + the kernel layer move.

## D1. Int variants: inline `cqo`/`idiv` + floor adjustment

Rejected alternative — the generalized body callout: `emitCalloutSave` is a
full rdi/rsi/rdx + r8–r11 + xmm2–xmm15 sweep (~40 moves round trip), absurd
for the hottest scalar op in the suite. Rejected alternative — hardware-only:
x86 `idiv` gives the TRUNCATED quotient/remainder and #DE-traps on both
`y == 0` and `minInt / -1`; both need explicit handling regardless.

Register model: homes are r8–r11/rbp/r12–r15/spills; rax/rcx are the only GP
scratch; **rdx is live all body long** (`*NativeResult`), rdi/rsi are the
tags/payloads bases. `idiv` clobbers rdx:rax unconditionally, so the frame
reserves ONE extra 8-byte slot (`div_save`) whenever the trace contains an
int mod/idiv, and rdx is parked there across the instruction. Emission
(`emitIntDivMod`, ~16 instrs):

The `(minInt, -1)` pair does NOT exit (codex blocker): the oracle returns a
DEFINED value (`mod` → `0`, `idiv` → `minInt`) and tier-1a continues, so a
native side-exit would diverge — the deopt ledger would record an exit
tier-1a never takes, and the replayed iteration could redo earlier heap
stores tier-1a performs once. The pair is detected (it would #DE in
hardware) and its result materialized inline; only `y == 0` exits (that one
IS an error in every tier — `DivisionByZero` raised by tier-0 from the same
instruction-`i` exit snapshot tier-1a errors at). The result canonically ends
in rax on every path so homing is uniform:

```
mov  [rsp + div_save*8], rdx    ; park (rdx itself intact — exits still fine)
mov  rax, place(a)              ; dividend
mov  rcx, place(b)              ; divisor
cmp  rcx, 0
je   exit_i                     ; DivisionByZero → side-exit; tier-0 re-raises
movabs rdx, 0x8000000000000000  ; minInt probe (rdx now clobbered; no exit
xor  rdx, rax                   ;   until it is reloaded)  0 iff x == minInt
jne  Lgo                        ; x != minInt → hardware-safe
cmp  rcx, -1
jne  Lgo
;; (minInt, -1): defined result, computed inline, NO exit —
;;   mod:  xor eax, eax          (result 0)
;;   idiv: (nothing — rax already holds the dividend == minInt)
jmp  Ldone
Lgo: cqo
idiv rcx                        ; rax = trunc quot, rdx = trunc rem
;; floor adjust: rem != 0 && sign(rem) != sign(divisor)
;; mod (result = rem, canonicalized into rax; quot dead → xor scratch):
;;   cmp rdx,0; je Lmove; mov rax,rdx; xor rax,rcx; jns Lmove; add rdx,rcx
;;   Lmove: mov rax, rdx
;; idiv (result = quot, already rax; rem dead after the test → clobber it):
;;   cmp rdx,0; je Ldone; xor rdx,rcx; jns Ldone; sub rax,1
Ldone:
mov  home_i, rax                ; home is never rax/rcx/rdx
mov  rdx, [rsp + div_save*8]    ; unpark
```

Bit-identity for the int lane is arithmetic identity: `idiv` + floor-adjust
equals `@mod`/`@divFloor` for every non-special pair; the two specials are
handled exactly (`y == 0` exits to the oracle's own raise, `(minInt, -1)`
materializes the oracle's own defined value). Integers are exact; no FP
discipline needed.

The one exit fires BEFORE any architectural state change (rdx parked but
valid, homes untouched) — the standard mid-body guard-exit contract
(`exit_labels[i]`, the same exit snapshot tier-1a uses when `arith.mod`
errors at instruction `i`).

New encodings in `x64.zig`: `cqo`, `idivReg` (F7 /7). Everything else
(`cmpRegImm32`, `xorRegReg`, `movRegImm64`, labels, `jcc`) exists.

## D2. Float variants: body callout to shared `fmath` kernels

The `pow` discipline verbatim (doc 23 D4): one noinline kernel per op, called
by tier-0, tier-1a, and the native body alike — bit-identity by construction,
no inline SSE re-derivation, no new determinism surface (`roundsd`/SSE4.1
stays out of the codebase).

- `fmath.fmodRuntime(x, y) = x - @floor(x / y) * y` (strict FP).
- `fmath.floordivRuntime(x, y) = @floor(x / y)` (strict FP).
- `arith.mod` / `arith.floorDiv` float paths refactored to CALL these kernels
  (as `arith.pow` calls `powRuntime`), so all three tiers share one compiled
  body per op.

Total functions — `y == 0` yields NaN/inf through IEEE exactly as the oracle
does; **no side-exit** on the float lane. `emitFloatCallout` extends its
binary-staging condition (`pow` → `pow | float-mod | float-idiv`) and the
kernel-address switch; `BodyCallout` gains `.fmod`/`.ffloordiv` rows
(`may_collect = false`, allocate nothing).

## D3. nativegen integration matrix

- `proveKinds`: `.mod, .idiv` arm with an EXHAUSTIVE `ty` switch (codex: the
  add/sub/mul arm's `else` silently treats a malformed `.boolean`/`.nil`
  stamp as int — do not copy that; only `.int` and `.float` are admissible,
  everything else fails closed) and explicit `ins.a < i` / `ins.b < i`
  bounds before indexing `kinds` (release-mode fail-closed;
  `assertWellFormed` is debug-only). `ty == .int` → both operands `.int`,
  result `.int`; `ty == .float` → both `isNumKind` AND ≥1 proven float
  (don't trust a stamped `.float` on int/int operands: the oracle would have
  produced an int), result `.float`; int operands promote via the shared
  `cvtsi2sd` discipline at the callout.
- `isTransient`: both true (GP home for int, XMM/spill for float).
- `isCommutative`, `isCoalescibleOp`: NOT added (order-sensitive; fixed-reg
  int lowering computes in scratch, not in a coalesced dst).
- `operandReads`: `.{ .a = true, .b = true }`.
- `opMayExitInBody`: `.mod, .idiv => ins.ty == .int` (the two guarded
  corners; the float lane is total).
- `bodyCalloutOf`: `.mod => if (ty == .float) .fmod else null`; likewise
  `.idiv => .ffloordiv`.
- Frame layout: `Alloc.div_save: ?u32` — an allocator-OWNED slot reserved
  iff any int mod/idiv is present, consumed as a unique `spill_count` slot
  wholly outside the callout save region (NEVER the callout
  alignment-padding slot), included in frame sizing and the SPILL_MAX
  production check; addressed as `div_save * 8` like every other spill
  (codex medium: an overlap could corrupt a spilled divisor or the parked
  `*NativeResult`).
- Emit switch: `ty == .int` → `emitIntDivMod`; `.float` → `emitFloatCallout`.

## D4. Gates

1. `x64.zig` encoding tests: `cqo`, `idiv` (golden bytes).
2. Lowering tier-parity (nativegen_lowering_test): int `%`/`//` loops over a
   sign matrix (+/+, +/−, −/+, −/−; results pinned against `@mod`/`@divFloor`
   truth — the floor-adjust is THE bug farm); divisor hits 0 mid-run →
   side-exit parity vs tier-1a (completed/exit_instr/regs slot-by-slot);
   `(minInt, -1)` pair → native CONTINUES with the oracle's defined value
   (`mod` 0 / `idiv` minInt), completed-count and result parity, NO exit
   (the codex-blocker inversion); float `%`/`//` parity bit-for-bit incl.
   `y == 0` → NaN continuing natively (no exit); mixed int/float promotion
   parity; a combined trace with an int divide AND a float-kernel callout
   under enough register pressure to spill operands (the `div_save`
   non-overlap proof).
3. e2e (interp_trace_test): a `% `-carrying scalar-shaped loop under FULL
   `--jit-native` config with `vm.trace.native_entries > 0` asserted — the
   assertion that `mod` no longer poisons native entry (the arc-B vacuity
   trap, now inverted into the payoff test). Output equals tier-0 truth.
4. The standing battery: full suite both legs (incl. `-Djit-debug=true`),
   hashgate 84/84, `just bench` 28/28 — scalar expected to move (its loop
   finally tiers to native); any OTHER row moving unexplained blocks commit.
   Instruction A/B vs a HEAD shadow on scalar + two non-`%` benches
   (regression guard), with rc + magnitude sanity checks (LATEST-89 lesson).

## Non-goals

- `roundsd`/SSE4.1 inline float floor — the kernel callout is the identity
  discipline; revisit only if a profile ever blames the callout.
- Unary float `neg`, `guard_number` lowering — separate deferrals, unchanged.
- Strength reduction (`x % 2^k` → mask for known-positive operands) — a
  later peephole; it must not gate this landing (Z-6: correctness-general
  first).
- Changing the safety net's decline-entirely behaviour — with mod/idiv
  lowered it simply stops firing on these traces; its policy is a separate
  question.
