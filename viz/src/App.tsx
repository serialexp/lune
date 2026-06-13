import { Show, onMount } from "solid-js";
import { state, loadBytes, loadFromUrl } from "./store";
import TraceList from "./components/TraceList";
import TraceView from "./components/TraceView";

/** Read a picked/dropped File into the store. */
async function ingest(file: File) {
  const buf = new Uint8Array(await file.arrayBuffer());
  loadBytes(file.name, buf);
}

export default function App() {
  let inputRef: HTMLInputElement | undefined;

  // Deep link: `?src=<url>` auto-loads a trace on open (no file picker needed).
  onMount(() => {
    const src = new URLSearchParams(window.location.search).get("src");
    if (src) void loadFromUrl(src);
  });

  const onDrop = (e: DragEvent) => {
    e.preventDefault();
    const file = e.dataTransfer?.files?.[0];
    if (file) void ingest(file);
  };

  return (
    <div class="app" onDragOver={(e) => e.preventDefault()} onDrop={onDrop}>
      <header class="topbar">
        <h1>lune — trace inspector</h1>
        <div class="loader">
          <button type="button" onClick={() => inputRef?.click()}>
            Open .lunetrace…
          </button>
          <input
            ref={inputRef}
            type="file"
            accept=".lunetrace,application/octet-stream"
            style={{ display: "none" }}
            onChange={(e) => {
              const file = e.currentTarget.files?.[0];
              if (file) void ingest(file);
            }}
          />
          <Show when={state.fileName}>
            <span class="filename">
              {state.fileName} <span class="muted">· v{state.version} · {state.traces.length} trace(s)</span>
            </span>
          </Show>
        </div>
      </header>

      <Show
        when={state.error === null}
        fallback={<div class="error">decode failed: {state.error}</div>}
      >
        <Show
          when={state.traces.length > 0}
          fallback={<div class="hint">Drop a <code>.lunetrace</code> file here, or use “Open”. Emit one with <code>lune --emit-traces out.lunetrace prog.lua</code>.</div>}
        >
          <main class="panes">
            <TraceList />
            <TraceView />
          </main>
        </Show>
      </Show>
    </div>
  );
}
