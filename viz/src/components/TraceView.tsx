import { For, Show } from "solid-js";
import { selectedTrace } from "../store";

/** Right pane: the selected trace's anchor, entry slots, IR, consts, exits. */
export default function TraceView() {
  const trace = selectedTrace;
  return (
    <Show when={trace()} fallback={<section class="trace-view empty">No trace selected.</section>}>
      {(t) => (
        <section class="trace-view">
          <header class="trace-header">
            <h2>
              JIT trace IR <span class="accent">{t().anchorProtoId}:{t().anchorPc}</span>
            </h2>
            <p class="trace-note muted">
              Optimized SSA recorded for this hot loop — not the tier-0 bytecode
              the step-replay panel above executes.
            </p>
            <div class="entry">
              entry = [
              <For each={t().entrySlots}>{(s, i) => <span> {i() > 0 ? " " : ""}r{s}</span>}</For>
              {" ]"}
            </div>
          </header>

          <table class="ir">
            <thead>
              <tr>
                <th>#</th>
                <th>op</th>
                <th>operands</th>
                <th>ty</th>
                <th>snap</th>
              </tr>
            </thead>
            <tbody>
              <For each={t().instrs}>
                {(ins) => (
                  <tr classList={{ guard: ins.op.startsWith("guard") }}>
                    <td class="idx">%{ins.index}</td>
                    <td class="op">{ins.op}</td>
                    <td class="operands">{ins.operands}</td>
                    <td class="ty">{ins.ty}</td>
                    <td class="snap">{ins.op.startsWith("guard") ? ins.snap : ""}</td>
                  </tr>
                )}
              </For>
            </tbody>
          </table>

          <Show when={t().consts.length > 0}>
            <div class="subsection">
              <div class="pane-title">consts</div>
              <table class="consts">
                <tbody>
                  <For each={t().consts}>
                    {(c) => (
                      <tr>
                        <td class="idx">{c.slot}</td>
                        <td class="ty">{c.kind}</td>
                        <td class="val">{c.text}</td>
                      </tr>
                    )}
                  </For>
                </tbody>
              </table>
            </div>
          </Show>

          <Show when={t().exitStores.length > 0}>
            <div class="subsection">
              <div class="pane-title">exit stores</div>
              <div class="exits">
                <For each={t().exitStores}>
                  {(s) => (
                    <span class="exit">
                      r{s.slot}&lt;-%{s.ref}
                    </span>
                  )}
                </For>
              </div>
            </div>
          </Show>
        </section>
      )}
    </Show>
  );
}
