import { For, Show } from "solid-js";
import { state, coverageAggregate, nativeTimeSplit } from "../store";

/** Format an integer with thin thousands separators. Accepts number|bigint. */
function fmt(n: number | bigint): string {
  return n.toLocaleString("en-US");
}

/** One-decimal percentage. */
function pct(n: number): string {
  return `${n.toFixed(1)}%`;
}

/** Compact cycle count (K/M/G/T). Cycles span many orders of magnitude. */
function fmtCyc(n: number): string {
  if (n < 1e3) return `${n}`;
  if (n < 1e6) return `${(n / 1e3).toFixed(1)}K`;
  if (n < 1e9) return `${(n / 1e6).toFixed(1)}M`;
  if (n < 1e12) return `${(n / 1e9).toFixed(2)}G`;
  return `${(n / 1e12).toFixed(2)}T`;
}

/**
 * JIT execution-coverage panel (Phase 3). A small table with an **iterations**
 * column and a **time** column, one row per class (native / covered-interpreted /
 * uncovered).
 *
 * The iteration split is always available (it's what the wasm run records). The
 * time split needs real TSC cycles, which only the NATIVE binary has — so under a
 * plain wasm run the time column is grayed and prompts "Run both + diff". After
 * that, `state.nativeCoverage` carries the honest, time-weighted split (native
 * machine-code time vs tier-0 fallback) — the number the iteration count hides:
 * nsieve shows ~60% of *iterations* ran as a trace, but only ~1% of *time*.
 */
export default function CoveragePanel() {
  const agg = () => coverageAggregate();
  const time = () => nativeTimeSplit();

  // The raw JIT event counters, nonzero only, in schema order.
  const counters = () => {
    const cov = state.coverage;
    if (cov === null) return [];
    return Object.entries(cov.counters).filter(([, v]) => v !== 0n) as [string, bigint][];
  };

  // One row per class, iterations from the wasm aggregate + time from the native
  // split (null under wasm-only). Kept a plain function so JSX reads cleanly.
  const rows = () => {
    const a = agg();
    if (a === null) return [];
    const t = time();
    return [
      { label: "native", sw: "sw-native", iter: a.native, iterPct: a.nativePct, time: t?.native ?? null, timePct: t?.nativePct ?? null, hint: null as string | null },
      { label: "covered-interpreted", sw: "sw-covered", iter: a.coveredInterp, iterPct: a.coveredInterpPct, time: t?.coveredInterp ?? null, timePct: t?.coveredInterpPct ?? null, hint: "has a trace but ran tier-0" },
      { label: "uncovered", sw: "sw-uncovered", iter: a.uncovered, iterPct: a.uncoveredPct, time: t?.uncovered ?? null, timePct: t?.uncoveredPct ?? null, hint: "no trace" },
    ];
  };

  return (
    <Show when={agg()} keyed>
      {(a) => (
        <div class="coverage">
          <div class="coverage-head">
            <span class="coverage-title">JIT coverage</span>
            <span class="muted">
              {state.scriptName} · {fmt(a.total)} loop iteration(s)
            </span>
          </div>

          <Show
            when={a.total > 0}
            fallback={<div class="muted coverage-empty">no back-edges executed</div>}
          >
            <table class="coverage-table">
              <thead>
                <tr>
                  <th>class</th>
                  <th class="cov-num-h">iterations</th>
                  <th class="cov-num-h">time <span class="muted">(cycles, of run)</span></th>
                </tr>
              </thead>
              <tbody>
                <For each={rows()}>
                  {(r, i) => (
                    <tr>
                      <td class="cov-class">
                        <span class={`swatch ${r.sw}`} /> {r.label}
                        <Show when={r.hint}>
                          <span class="coverage-hint muted"> — {r.hint}</span>
                        </Show>
                      </td>
                      <td class="cov-num">
                        {fmt(r.iter)} <span class="muted">{pct(r.iterPct)}</span>
                      </td>
                      <Show
                        when={time()}
                        fallback={
                          i() === 0 ? (
                            <td class="cov-time-empty muted" rowspan={3}>
                              run <b>Run both + diff</b> for the
                              <br />
                              native cycle split (no rdtsc in wasm)
                            </td>
                          ) : null
                        }
                      >
                        <td class="cov-num">
                          {fmtCyc(r.time!)} <span class="muted">{pct(r.timePct!)}</span>
                        </td>
                      </Show>
                    </tr>
                  )}
                </For>
                <Show when={time()} keyed>
                  {(t) => (
                    <tr class="cov-other">
                      <td class="cov-class muted">other (non-loop)</td>
                      <td class="cov-num muted">—</td>
                      <td class="cov-num muted">
                        {fmtCyc(t.other)} {pct(t.otherPct)}
                      </td>
                    </tr>
                  )}
                </Show>
              </tbody>
            </table>
          </Show>

          {/* Raw event counters (nonzero). Muted, monospace, wraps. */}
          <Show when={counters().length > 0}>
            <div class="coverage-counters">
              <For each={counters()}>
                {([name, v]) => (
                  <span class="counter-chip">
                    <span class="counter-name">{name}</span>
                    <span class="counter-val">{fmt(v)}</span>
                  </span>
                )}
              </For>
            </div>
          </Show>
        </div>
      )}
    </Show>
  );
}
