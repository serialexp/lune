import { For, Show } from "solid-js";
import { state, selectTrace, traceLine } from "../store";

/** Left pane: one row per trace, showing the source line its anchor (the loop
 *  header, the body's first bytecode) sits on — else its proto:pc — and its
 *  instruction count. */
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
            <span class="anchor" title={`anchor: proto ${t.anchorProtoId}, pc ${t.anchorPc}`}>
              <Show when={traceLine({ protoId: t.anchorProtoId, pc: t.anchorPc })} fallback={`proto ${t.anchorProtoId}:${t.anchorPc}`}>
                {(line) => `from line ${line()}`}
              </Show>
            </span>
            <span class="count">{t.instrs.length} ir</span>
          </button>
        )}
      </For>
    </nav>
  );
}
