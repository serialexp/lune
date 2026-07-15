// Unit tests for the Phase 3 coverage resolver + aggregate (viz/src/store.ts).
// These are the pure functions the editor line-shading and the stats panel are
// built on: `resolveCoverageLines` maps per-anchor `(proto_id, pc)` back to a
// source line via the static disasm and picks each line's dominant class, and
// `aggregateCoverage` turns the top-level counts into a percentage split. Both
// are pure (no store singleton), so we drive them with hand-built fixtures.

import { test, expect } from "bun:test";
import { resolveCoverageLines, aggregateCoverage, timeSplitOf } from "../src/store";
import type { CoverageAnchorOutput, CoverageFileOutput } from "../src/decode";
import type { ProtoDisasm } from "../src/wasm/lune";

/** A CoverageAnchor with sane defaults; override what a test cares about. */
function anchor(o: Partial<CoverageAnchorOutput> & { proto_id: number; pc: number }): CoverageAnchorOutput {
  return {
    proto_id: o.proto_id,
    pc: o.pc,
    traced_iters: o.traced_iters ?? 0n,
    interp_iters: o.interp_iters ?? 0n,
    traced_cycles: o.traced_cycles ?? 0n,
    interp_cycles: o.interp_cycles ?? 0n,
    has_trace: o.has_trace ?? 0,
  };
}

/** A one-proto disasm whose instruction i sits on source line `lines[i]`. */
function disasmOf(id: number, lines: number[]): ProtoDisasm[] {
  return [
    {
      id,
      name: "main",
      numParams: 0,
      numRegisters: 0,
      instrs: lines.map((line) => ({ line, text: "" })),
    },
  ];
}

test("resolves an anchor's (proto_id, pc) to its source line", () => {
  const dis = disasmOf(0, [1, 2, 3, 4, 5]); // pc 3 → line 4
  const m = resolveCoverageLines([anchor({ proto_id: 0, pc: 3, traced_iters: 10n, has_trace: 1 })], dis);
  expect([...m.keys()]).toEqual([4]);
  expect(m.get(4)!.cls).toBe("native");
  expect(m.get(4)!.native).toBe(10);
});

test("classes a traced-dominant line native", () => {
  const dis = disasmOf(0, [7]);
  const m = resolveCoverageLines([anchor({ proto_id: 0, pc: 0, traced_iters: 90n, interp_iters: 10n, has_trace: 1 })], dis);
  expect(m.get(7)!.cls).toBe("native");
});

test("classes a has_trace line that ran mostly interpreted as covered-interpreted (the smell)", () => {
  const dis = disasmOf(0, [7]);
  // Trace exists, but interpreted back-edges dominate → covered-interpreted.
  const m = resolveCoverageLines([anchor({ proto_id: 0, pc: 0, traced_iters: 5n, interp_iters: 95n, has_trace: 1 })], dis);
  const e = m.get(7)!;
  expect(e.cls).toBe("covered-interpreted");
  expect(e.coveredInterp).toBe(95);
  expect(e.uncovered).toBe(0);
});

test("classes a no-trace line uncovered and buckets its interp iters there", () => {
  const dis = disasmOf(0, [7]);
  const m = resolveCoverageLines([anchor({ proto_id: 0, pc: 0, interp_iters: 40n, has_trace: 0 })], dis);
  const e = m.get(7)!;
  expect(e.cls).toBe("uncovered");
  expect(e.uncovered).toBe(40);
  expect(e.coveredInterp).toBe(0);
});

test("sums multiple anchors that resolve to the same line", () => {
  const dis = disasmOf(0, [7, 7]); // both pcs on line 7
  const m = resolveCoverageLines(
    [
      anchor({ proto_id: 0, pc: 0, traced_iters: 3n, has_trace: 1 }),
      anchor({ proto_id: 0, pc: 1, interp_iters: 2n, has_trace: 1 }),
    ],
    dis,
  );
  const e = m.get(7)!;
  expect(e.native).toBe(3);
  expect(e.coveredInterp).toBe(2);
  expect(e.cls).toBe("native"); // 3 traced >= 2 covered-interp
});

test("drops anchors the disasm can't place (bad proto, out-of-range pc, or line 0)", () => {
  const dis = disasmOf(0, [0, 5]); // pc 0 → line 0 (no span); pc 1 → line 5
  const m = resolveCoverageLines(
    [
      anchor({ proto_id: 9, pc: 0, traced_iters: 1n }), // no such proto
      anchor({ proto_id: 0, pc: 99, traced_iters: 1n }), // pc out of range
      anchor({ proto_id: 0, pc: 0, traced_iters: 1n }), // line 0 → dropped
      anchor({ proto_id: 0, pc: 1, traced_iters: 1n, has_trace: 1 }), // ok → line 5
    ],
    dis,
  );
  expect([...m.keys()]).toEqual([5]);
});

/** A CoverageFile carrying just the aggregate counts (anchors/counters empty).
 *  Optional `cycles` sets the time split `[traced, covered, uncovered, run]`;
 *  `runNanos` is the whole-run wall time that turns cycles into real ns. */
function covWith(
  traced: bigint,
  covered: bigint,
  uncovered: bigint,
  cycles?: [bigint, bigint, bigint, bigint],
  runNanos: bigint = 0n,
): CoverageFileOutput {
  const [ct, cc, cu, run] = cycles ?? [0n, 0n, 0n, 0n];
  return {
    version: 1,
    iters_traced: traced,
    iters_tier0_covered: covered,
    iters_tier0_uncovered: uncovered,
    cycles_traced: ct,
    cycles_tier0_covered: cc,
    cycles_tier0_uncovered: cu,
    run_cycles: run,
    run_nanos: runNanos,
    counters: {
      entries: 0n,
      native_link_arms: 0n,
      native_source_link_arms: 0n,
      native_loopdone_link_arms: 0n,
      native_source_link_fused: 0n,
      native_loopdone_link_fused: 0n,
      native_link_disarms: 0n,
      native_link_exits: 0n,
      native_link_follow_count: 0n,
      link_ir_exits: 0n,
      link_follow_count: 0n,
      prime_side_arms: 0n,
      prime_side_chain_follows: 0n,
      tier0_outer_body_entries: 0n,
    },
    anchors: [],
  };
}

test("aggregate splits the three buckets into percentages", () => {
  const a = aggregateCoverage(covWith(70n, 20n, 10n));
  expect(a.total).toBe(100);
  expect(a.nativePct).toBeCloseTo(70);
  expect(a.coveredInterpPct).toBeCloseTo(20);
  expect(a.uncoveredPct).toBeCloseTo(10);
});

test("aggregate with no iterations reports zero percentages, not NaN", () => {
  const a = aggregateCoverage(covWith(0n, 0n, 0n));
  expect(a.total).toBe(0);
  expect(a.nativePct).toBe(0);
  expect(a.coveredInterpPct).toBe(0);
  expect(a.uncoveredPct).toBe(0);
});

test("timeSplitOf is null without cycle data (a wasm run — no rdtsc)", () => {
  expect(timeSplitOf(covWith(100n, 50n, 0n))).toBeNull(); // run_cycles == 0
});

test("timeSplitOf gives the honest time split — % of run, with a non-loop remainder", () => {
  // The nsieve shape: iterations flatter the JIT (traced dominates), but by TIME
  // the traced fraction is tiny and tier-0-has-trace dominates. run > loop sum, so
  // there's a non-loop remainder.
  //   iterations: 60% traced; cycles: 10 traced / 970 covered / 5 uncovered of 1000 run.
  const t = timeSplitOf(covWith(600n, 400n, 0n, [10n, 970n, 5n, 1000n]))!;
  expect(t).not.toBeNull();
  expect(t.run).toBe(1000);
  expect(t.nativePct).toBeCloseTo(1.0); // ~1% of run ran as a trace — the honest number
  expect(t.coveredInterpPct).toBeCloseTo(97.0);
  expect(t.uncoveredPct).toBeCloseTo(0.5);
  expect(t.other).toBe(15); // 1000 - 10 - 970 - 5 = non-loop
  expect(t.otherPct).toBeCloseTo(1.5);
  // No wall clock supplied → the real-time fields are all 0 (cycles aren't a unit).
  expect(t.runNanos).toBe(0);
  expect(t.nativeNs).toBe(0);
});

test("timeSplitOf converts cycles to real ns via run_nanos (the effective clock)", () => {
  // 1000 run cycles measured over 2000 ns wall → 0.5 GHz effective, so ns = 2× cycles.
  const t = timeSplitOf(covWith(600n, 400n, 0n, [10n, 970n, 5n, 1000n], 2000n))!;
  expect(t.runNanos).toBe(2000);
  expect(t.nativeNs).toBeCloseTo(20); // 10 cyc × (2000/1000)
  expect(t.coveredInterpNs).toBeCloseTo(1940); // 970 × 2
  expect(t.uncoveredNs).toBeCloseTo(10); // 5 × 2
  expect(t.otherNs).toBeCloseTo(30); // 15 × 2
});
