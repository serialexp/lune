# 50 — Nested `for_prep` tracing investigation

**Status:** rejected experiment; no nested-loop tracing feature lands from this arc.

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
but the current replay unit fixtures encode the older source-only contract and
no production trace can currently contain the problematic shape. That change
does not land in this arc. Any future multi-loop root design must specify the
ownership rule and update the replay fixture model before enabling recording.

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

## Outstanding direction

Nested `for_prep` remains a real coverage gap, but bounded full-body unrolling
is not the mechanism to pursue. The next design should preserve a reusable
inner trace while representing the enclosing loop's state transition, rather
than cloning a variable-trip inner execution into one monolithic root. The
other existing candidates remain `get_upval` alias handling, measured seam
cost, and doc 44 return tracing.
