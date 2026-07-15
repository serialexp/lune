import { For, Show } from "solid-js";
import { state, coverageAggregate } from "../store";

/** Format an integer with thin thousands separators. Accepts number|bigint. */
function fmt(n: number | bigint): string {
  return n.toLocaleString("en-US");
}

/** One-decimal percentage. */
function pct(n: number): string {
  return `${n.toFixed(1)}%`;
}

/**
 * JIT execution-coverage panel (Phase 3). Renders the last wasm run's
 * native-vs-tier-0 split as a stacked bar + counts, the per-line legend, and the
 * raw JIT event counters. The whole thing is a `<Show when={state.coverage}>` at
 * the call site, so this only mounts when a run produced a coverage artifact.
 *
 * Under wasm there is no rdtsc, so time attribution (`cycles_*`) is 0 — we weigh
 * strictly by back-edge iterations and say so.
 */
export default function CoveragePanel() {
  const agg = () => coverageAggregate();

  // The raw JIT event counters, nonzero only, in schema order. `entries` is the
  // trace-entry counter; the rest track the native-chaining machinery.
  const counters = () => {
    const cov = state.coverage;
    if (cov === null) return [];
    return Object.entries(cov.counters).filter(([, v]) => v !== 0n) as [string, bigint][];
  };

  return (
    <Show when={agg()} keyed>
      {(a) => (
        <div class="coverage">
          <div class="coverage-head">
            <span class="coverage-title">JIT coverage</span>
            <span class="muted">
              {fmt(a.total)} loop iteration(s) ·{" "}
              <Show when={state.coverage!.run_cycles === 0n} fallback={"time-weighted"}>
                time attribution n/a (wasm)
              </Show>
            </span>
          </div>

          {/* Stacked proportion bar: native / covered-interpreted / uncovered. */}
          <Show
            when={a.total > 0}
            fallback={<div class="muted coverage-empty">no back-edges executed</div>}
          >
            <div class="coverage-bar" role="img" aria-label="native vs interpreted iteration split">
              <div class="seg seg-native" style={{ width: pct(a.nativePct) }} title={`native ${pct(a.nativePct)}`} />
              <div class="seg seg-covered" style={{ width: pct(a.coveredInterpPct) }} title={`covered-interpreted ${pct(a.coveredInterpPct)}`} />
              <div class="seg seg-uncovered" style={{ width: pct(a.uncoveredPct) }} title={`uncovered ${pct(a.uncoveredPct)}`} />
            </div>

            <ul class="coverage-legend">
              <li>
                <span class="swatch sw-native" /> native{" "}
                <b>{pct(a.nativePct)}</b> <span class="muted">({fmt(a.native)})</span>
              </li>
              <li>
                <span class="swatch sw-covered" /> covered-interpreted{" "}
                <b>{pct(a.coveredInterpPct)}</b> <span class="muted">({fmt(a.coveredInterp)})</span>
                <span class="coverage-hint muted"> — has a trace but ran tier-0</span>
              </li>
              <li>
                <span class="swatch sw-uncovered" /> uncovered{" "}
                <b>{pct(a.uncoveredPct)}</b> <span class="muted">({fmt(a.uncovered)})</span>
                <span class="coverage-hint muted"> — no trace</span>
              </li>
            </ul>
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
