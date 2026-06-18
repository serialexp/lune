# Trace-opportunity detector (Bart's idea, E3 rescope direction)

## Why
Phase E3's original target (float strength reduction of pi_leibniz's `denom`) is
**dropped**: it's unsound under lune's all-inputs bit-exactness contract (recompute
`2k+1` vs accumulator `denom+=2.0` diverge at k=2^52+1) AND LuaJIT doesn't even do it
(verified in src/lj_opt_loop.c: LICM + copy-substitution unroll + CSE; src/lj_opt_fold.c
reassociates only INT, never FP). Integer SR is sound but doesn't help pi.

The REAL pi_leibniz waste (measured): the loop body emits ~16 memory stores/iteration
flushing DEAD carried temps r4..r11 to the tier-0 register file (`mov qword [rdi+slot*16],
tag` + payload, inside loop_top→back-edge). lune --jit-native = 0.15s vs luajit 0.01-0.02s
at N=20M. Live carries (sum/sign/k) are register-homed & cheap; the dead ones are
memory-homed & flushed every iteration. LuaJIT avoids this via snapshot liveness.

## The idea (instead of / before a point-fix)
A deterministic analysis pass over each recorded+optimized trace that scores it against a
catalog of "waste signatures" and emits a STRUCTURED report. New programs then *announce*
their optimization opportunities — a triage signal — without anyone reading disassembly.
Even when a flagged instance turns out non-reducible, we learned that for free.

## Waste signatures (all cheap IR-level predicates, no machine code)
1. **Dead carried phi** — `phi{aux=rN}` with no `slot_load rN` anywhere in the trace, and
   rN not live-out at the anchor PC. (pi: 8 of these → ~16 stores/iter.) NEEDS tier-0 slot
   liveness at the loop-anchor PC — open question whether lune already has it (check the
   recorder watermark machinery, tasks #128-129) or must compute it from bytecode.
2. **Duplicate carry** — two phis with the same `update` ref → different slots (pi: %025 &
   %026 both update=%22). Copy-propagation / shared-home opportunity.
3. **Affine-over-IV recompute** — `mul(konst,IV)`+`add(_,konst)` cone (the SR shape). Flag
   even where FP-reduction is unsound; integer-IV integer-affine cases ARE soundly reducible.
4. **Un-hoisted invariant** — a pure binary/unary whose operands are all invariant but it's
   in the body (LICM gap).
5. **Spilled / memory-homed carry** — register-pressure signal.
6. **Redundant guard** — same `(op, ref)` guarded twice (post-CSE this should be rare; flag
   if seen).

Each row: `{signature, count, est_cost_per_iter, refs[]}`. Deterministic → fits the
02-determinism matrix. Surface behind `--trace-opportunities` (stderr, like --dump-traces),
later a viz panel. lune-native analogue of LuaJIT `-jv`/`-jdump`, organized around
opportunities not raw dumps.

## Likely first concrete step (next session)
- Decide home: a new `src/troptdiag.zig` (pure analysis over a Trace → report struct) keeps
  tropt.zig clean; or fold into tropt as a post-optimize scan.
- Implement signatures #1 (dead carry) + #2 (duplicate carry) first — they're the measured
  pi waste and need no new soundness model to *detect* (detection is always safe; only the
  eventual *transform* needs the anchor-PC liveness proof).
- Then the actual transform: dead-carried-phi elimination, gated on anchor-PC liveness, with
  the deopt-coherence argument (a write-before-read slot gets a fresh value on replay, so its
  dropped carry is unobservable). Codex+Antigravity review before it lands (standing directive
  applies — it's a deopt-coherence change).

## State as of pause
- E0/E1/E2 landed & committed (E2 = b79ee71). Phase E foundation (unified phi + LICM +
  internal-phi native computed home) is DONE.
- E3 (float SR) abandoned per review; rescoped to dead-PHI elim + this detector.
- Working files to clean up: CURRENT_TASK_E3.md (the float-SR design, now superseded — keep
  for the soundness write-up or delete), this note.
- nativegen.zig E2 tests are in & green; `zig build test`/`wasm`/ReleaseFast all green.
