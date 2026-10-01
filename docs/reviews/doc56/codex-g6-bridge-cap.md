# Codex re-review — doc 58 B2 (387118e) + doc 56 G6 / bridge-cap fix

Date: 2026-10-01. Reviewer: Codex (`mcp__codex__delegate`, default model),
read-only. Scope: commit `387118e` (B2 + fix-all + `exit_side_native` flip),
and the uncommitted G6-Q1(a) widening, G6-Q1(d) `loopunroll` bound, native
region-bridge cap yield (`bridge_full`), detector cap-bridge evidence, and the
`native_region_bridge_cap_yields` counter (doc 56 §4.8.5).

Verdict: **no blocker**; one implementation should-fix, two coverage
should-fixes. The earlier B2 fixes (`docs/reviews/doc58/codex-b2.md`) hold.

## Findings and disposition

1. **Should-fix — inlined `while`/`repeat` markers bypassed `loopunroll`.**
   `recLoopLink` returned at inline depth > 0 before counting, so a side or
   continuation recording unrolled an inlined `while` until `maxrecord`
   (codex's repro: exit-side continuation at main pc 12 aborted `too_long`
   at 2,000 IR). **Fixed:** an inlined marker counts for every kind; the
   own-anchor exemption is depth-0 only (an inlined recursive instance is a
   different loop). Codex also noted LuaJIT bounds root unrolling on the
   `innerloopleft` escape (root arm of `rec_loop_interp`): **fixed** — the
   `unroll_while` path counts too, and an abort there carries
   `unrolled_while`, feeding `unroll_fail` like any dying unrolled root.
   `noteLoopIteration` is now kind-blind, like LuaJIT's counter. The repro
   now aborts `loop_unroll` at 68–80 IR. LuaJIT's other root-arm clause
   (`nins - loopref > 24` outside `ENTERLO`) is NOT ported: our IR density
   differs, so 24 needs calibration — recorded in TODO.
   Test: the G6-Q1(d) recorder test gains inlined (side/continuation/root),
   root-escape (root/head) and plain-root-LINNER cases; mutation (skip the
   inlined count) fails it.

2. **Should-fix — the cap path's deopt-state identity was only pinned
   end-to-end.** **Fixed:** new native fixture "the native bridge stub fires
   at CAP-2 and at CAP-1 yields the ordinary deopt's exact state"
   (`trace_promotion_test.zig`): a bridge→link ring entered at the bridge
   fires the bridge at even lengths (30 = CAP-2 must materialize and run the
   successor); entered at the link trace it fires at odd lengths (31 = CAP-1
   is full: final row `.deopt`/`.yielded` at exit 11, successor not run).
   The CAP-1 registers, exit index, exit reason, local count and row reason
   are compared against an unarmed twin bridge entered with the 16th pass's
   registers (the disarmed/ordinary_mini path). Mutations: full → 
   `ordinary_mini` fails (`.normal` not `.yielded`); `ja` → `jae` fails
   (CAP-2 deopts). Float/spilled values are not separately exercised: the
   cap path runs the same `deopt_exit` flush as `ordinary_mini` (only the
   staged `exit_target` differs), and that flush's spill/float handling has
   its own tests (blocker-1 carried-spill test et al.).

3. **Should-fix — no competing-cell / stale-arm negatives for the evidence
   exception.** **Fixed:** the match is now one pure predicate,
   `rowMatchesSilentKind` (`trace_link.zig`), pinned by a table test over
   every `SilentSiteKind` (a final yielded deopt names only `.deopt` and
   `.region_bridge`; an exit-side row never names the bridge and a deopt row
   never names the exit-side adapter). The integration test adds a stale
   region proof and a disarmed bridge, both rejected `open_chain`. Mutation
   (exception broadened to any same-exit edge) fails the table test. An
   attached exit-side arm on the hand-built B3 bridge was not constructed —
   it needs doc 56's full attach/publish pipeline; the predicate test covers
   the same decision.

## Codex's soundness answers (summary)

- (c) bridge_full: sound for reachable states. Arm check precedes cap check;
  disarmed slots take `ordinary_mini`; at CAP-1 the stub skips
  materialization, runs the same carried-home flush, appends the final
  `.deopt`, yields before entering the child. Guest state and replay resume
  match ordinary deopt; only transport bookkeeping differs.
- (d) detector: no misattribution found; `.normal` bridge deopts stay
  rejected; registry proof, region membership and child adjacency still
  required. The detector does not prove a single closed ring (pre-existing
  design: unobserved region-member edges are included by intent).
- (b) arithmetic correct (15 crossings allowed, 16th aborts; recording-wide).

## Raw reply

> Bart, I found **one implementation should-fix and two coverage
> should-fixes; no soundness blocker reproduced**. […] The earlier B2
> correctness fixes hold in the inspected code and combined-tree checks:
> snapshot agreement, own-test hotness routing, marker entry contracts, and
> strengthened tests. The original short-circuit reproduction prints `76`.
> Validation passed: `just test`, tests with `-Djit-debug=true`, and the
> topology benchmark. […] native times were approximately **14.6 ms nsieve,
> 13.8 ms nsieve-bit, and 6.2 ms sieve_int**. Nsieve reported **12 bridge cap
> yields**.

[Codex thread: 01a0f668-533a-7583-979b-db00fe5c8bb1]
