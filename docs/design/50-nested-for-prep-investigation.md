# 50 — Nested `for_prep` tracing investigation

**Status:** rejected experiment; no nested-loop tracing feature lands from this arc.
Reviewed by Codex Astra (read-only, 2026-09-16) — see "External review" below;
review follow-ups (prover chain validation, eq coverage) landed after `d35ca63`.
**Last updated:** 2026-09-16

## Problem

The post-doc-49 nbody profile leaves its outer numeric loop (`advance:4`)
entirely in tier 0. Recording reaches the inner loop's `for_prep` and aborts
with `nyi_opcode`. That outer loop accounts for roughly 13.5% of nbody's run,
and the same recorder boundary appears in other nested-loop programs.

The candidate mechanism was deliberately general: while recording a numeric
root, execute a bounded, statically small nested numeric loop into the parent
trace. This is the numeric-for analogue of the recorder's bounded while-loop
unrolling, not an nbody-specific pattern.

## Experiment

The prototype:

- recognized a nested `for_prep`/`for_loop` pair while recording another root;
- admitted only numeric loops whose trip count was known at record time;
- capped expansion at 15 trips; and
- recorded each inner iteration through the ordinary recorder path, preserving
  guards and effects instead of introducing a benchmark-specific IR opcode.

It produced a native-compilable outer nbody trace of about 500 IR instructions.
That established that the missing recorder opcode was not the only obstacle:
the experiment also exercised multi-loop exit classification, repeated grid
guards, and heap-reference equality in forms the existing single-loop traces
had not reached.

## Result

The mechanism is rejected because it does not provide a general speedup.

- Nbody's inner trip count shrinks across the outer loop. The recorded outer
  trace matched only about one third of outer iterations and cost roughly
  2,417 cycles per matched iteration, versus roughly 485 cycles for tier 0.
  Wall time regressed to about 108 ms from a roughly 69–72 ms baseline.
- Retiring the trace on repeated trip-count mismatch restored the old execution
  shape (about 75.6 ms in that sample), but then the new outer trace provided no
  durable coverage.
- A fixed-four-trip nested-loop control was already effectively fully covered
  by the existing inner-root plus continuation-link machinery. Unrolling the
  inner loop into its parent did not open a missing general execution class.

This is exactly the Z-6 rejection condition: the approach can manufacture an
outer trace for nbody, but it neither survives realistic variable trip counts
nor improves programs whose fixed nested loops are already covered.

Scope of the rejection (sharpened per the Astra review): what the evidence
rejects is *whole-inner-loop cloning as the general nested-numeric-loop
mechanism* — specifically for variable/shrinking trip counts. It does NOT
rule out evidence-driven bounded unrolling of genuinely short, stable-trip
loops in general; LuaJIT and mahina's own while-loop machinery both use that
legitimately, and this experiment produced no evidence against it.

## Independent correctness findings retained

Two pre-existing defects exposed by the larger trace are independent of the
rejected mechanism and remain fixed:

1. `tropt.kindOf(.guard_gcol)` classified a two-reference guard as unary.
   Compaction remapped `a` but left the live column reference in `b` stale.
   `guard_gcol` now uses the ordered two-operand effect class, with a regression
   test that forces renumbering before the guard.
2. Native `eq`/`ne` admitted invariant heap pointers by process address and
   rejected value-lane heap references. Mahina identity is `GcHeader.id`;
   keyframe restore preserves IDs while rebuilding objects at new addresses.
   Native equality now compares the stable 32-bit IDs for both `.ptr` and
   `.heap`, with differential tests for same pointer, distinct identity, and
   different-address/same-ID restored twins.

The experiment also showed that a future trace containing more than one
numeric loop cannot classify every `for_loop`-sourced guard as the root's own
linked loop completion. An owner-aware classifier prototype fixed that case,
but the current replay unit fixtures encode the older source-only contract.
We *believe* no existing production recording path can emit a multi-loop
trace (the `for_prep` `nyi_opcode` abort is the only known entry into that
shape), but this has not been exhaustively verified against every recording
path — treat it as a working assumption, not a proven invariant (Astra
review). That change does not land in this arc. Any future multi-loop root
design must specify the ownership rule and update the replay fixture model
before enabling recording.

## Verification

- Focused `guard_gcol`, invariant/value-lane heap identity, and nested-loop
  tests pass.
- `just test` passes.
- `zig build test -Djit-debug=true` passes.
- Nbody 50,000 after removing the prototype: correct output; `advance:4` has
  zero traced iterations; 50.8% of wall cycles run as traces; 71.8 ms sampled
  wall time. This matches the pre-experiment execution shape.
- Full `just bench` (five repetitions) reports `cross=ok` for every row and
  `luajit=ok` for every compatible row. Nbody is 62.4 ms versus 61.7 ms on the
  post-doc-49 board, within ordinary run noise; the board contains no apparent
  regression attributable to stable-ID comparison.

## External review (Codex Astra, read-only, 2026-09-16)

Verdicts: removing the prototype was justified; both retained fixes are
technically sound; but the original write-up overstated what the evidence
proves (rejection scoped and the multi-loop-shape claim softened above), and
the deeper diagnosis was incomplete — mahina ALREADY HAS inner-root /
continuation decomposition, and the real question is why the existing
`inner root → outer continuation → inner root` cycle fails to cover the
outer work on shapes like nbody's `advance:4`.

Follow-ups landed after `d35ca63` from the review's two code findings:

1. **`guard_gcol` validation gap (pre-existing, fail-open).** Native lowering
   range-checks `guard_gcol.b` while the oracle derives the column from
   `gcell.b`; the prover never tied them together, and the shared `.aref`
   kind let aref/garow/gcell stand in for each other while native emitters
   walk `t.instrs[...]` chains assuming exact ops (`guard_bounds` on a gcell
   even satisfied `bounds_ok` for a gcell-of-gcell chain). The prover now
   enforces `guard_gcol.b == gcell.b` and exact op identity along the whole
   chain (`gcell.a` is a `garow`; `guard_gcol`/`gload`/`gstore`/
   `guard_gpresent` root at a `gcell`). Regression test: three previously
   fail-open variants (divergent column ref, garow-rooted guard+load,
   gcell-of-gcell behind a malformed bounds guard) — all verified to compile
   pre-fix by temporary neutering, all bail now, positive control compiles.
2. **Stable-ID eq coverage.** Added: the `eq` op (only `ne` was covered),
   a mixed invariant-`.ptr` vs value-lane-`.heap` operand pair, and
   top-bit-set ids (sign-extension trap) for both the equal-twin and
   differing case. Still open (TODO.md): spill-pressure variant and a
   differential through a REAL keyframe capture/restore rather than the
   simulated same-id twin.

## Outstanding direction

Nested `for_prep` remains a real coverage gap, but bounded full-body unrolling
is not the mechanism to pursue. The next design should preserve a reusable
inner trace while representing the enclosing loop's state transition, rather
than cloning a variable-trip inner execution into one monolithic root.

Per the Astra review, the next arc is a *diagnosis*, not a mechanism: build a
small variable-trip numeric-nest instrument (a reduced `advance:4`-shaped
script) and walk the EXISTING decomposition layer by layer — the doc 17 /
Rule Z-8 ladder generalized to nests:

1. Trace topology: which inner roots / continuations record, which abort,
   and on what.
2. Entry-guard mismatches: does the outer continuation's entry refuse on
   state the inner trace changed?
3. Exit arming: are the inner-exit → continuation → inner-entry transitions
   armed (`sibling_handoff` / `region_bridge`), or paying runtime re-entry?
4. Silent-region promotion: does the nest's SCC elect an owner
   (`armable=true`) or mint `armable=false` forever (doc 47 Increment B
   territory)?
5. Native residency + seam cost: `--jit-stats` split and per-transition
   cycles once 1–4 are accounted for.

Intended end state: the inner trace is REUSED (code size independent of the
inner trip count), outer state carries through continuation φ / writeback,
and the outer loop's per-iteration cost approaches the inner chain's. The
other existing candidates remain `get_upval` alias handling, measured seam
cost, and doc 44 return tracing.
