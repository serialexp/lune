import { For } from "solid-js";
import { state, selectTrace } from "../store";

/** Left pane: one row per trace, showing its anchor and instruction count. */
export default function TraceList() {
  return (
    <nav class="trace-list">
      <div class="pane-title">traces ({state.traces.length})</div>
      <For each={state.traces}>
        {(t, i) => (
          <button
            type="button"
            class="trace-row"
            classList={{ selected: i() === state.selected }}
            onClick={() => selectTrace(i())}
          >
            <span class="anchor">
              proto {t.anchorProtoId}:{t.anchorPc}
            </span>
            <span class="count">{t.instrs.length} ir</span>
          </button>
        )}
      </For>
    </nav>
  );
}
