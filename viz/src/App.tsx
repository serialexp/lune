import { For, Show, onMount } from "solid-js";
import { state, loadBytes, loadFromUrl, runWasm, runBoth, canReplay, openReplay } from "./store";
import LuneEditor from "./editor/LuneEditor";
import TraceList from "./components/TraceList";
import TraceView from "./components/TraceView";
import ReplayPanel from "./components/ReplayPanel";

/** Format a byte count for the run readout: plain bytes under 1 KiB, else KiB. */
function fmtBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  return `${(n / 1024).toFixed(1)} KiB`;
}

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

      {/* Authoring + in-browser execution (Phase 7 v3): edit a lune program and
          run it through the wasm VM. The recorded trace flows into the views
          below exactly as a loaded .lunetrace would. */}
      <section class="editor">
        <div class="editor-head">
          <span class="muted">Author &amp; run in-browser (wasm)</span>
          <div class="editor-actions">
            <button type="button" disabled={state.running} onClick={() => void runWasm()}>
              {state.running ? "Running…" : "Run (wasm)"}
            </button>
            <button
              type="button"
              class="secondary"
              disabled={state.running}
              title="Run through both the wasm VM and the native binary, then compare every artifact byte-for-byte"
              onClick={() => void runBoth()}
            >
              Run both + diff
            </button>
            <button
              type="button"
              class="secondary"
              disabled={state.running || !canReplay()}
              title="Step through the last run's execution: scrub the timeline and watch VM state evolve (deterministic replay)"
              onClick={openReplay}
            >
              Replay
            </button>
          </div>
        </div>
        <LuneEditor />
        <Show when={state.replayActive}>
          <ReplayPanel />
        </Show>
        <Show when={state.stdout !== null || state.runError !== null}>
          <div class="run-output">
            <Show when={state.timing}>
              {(t) => (
                <span class="run-timing">
                  ran in {t().totalMs.toFixed(2)} ms <span class="muted">(execute {t().execMs.toFixed(2)} ms)</span>
                </span>
              )}
            </Show>
            <Show when={state.lastRun}>
              {(r) => (
                <span class="run-timing muted">
                  trace {fmtBytes(r().trace.length)} · keyframe {fmtBytes(r().keyframe.length)} · effects {fmtBytes(r().effects.length)}
                </span>
              )}
            </Show>
            <Show when={state.runError}>
              <pre class="run-error">
                {state.runErrorSpan ? `line ${state.runErrorSpan.line}: ${state.runError}` : state.runError}
                <Show when={state.runBacktrace && state.runBacktrace.length > 1}>
                  {"\n"}<span class="run-traceback">
                    {state.runBacktrace!.map((f) => `${f.name}:${f.line}`).join(" → ")}
                  </span>
                </Show>
              </pre>
            </Show>
            <Show when={state.stdout}>
              <pre class="run-stdout">{state.stdout}</pre>
            </Show>
          </div>
        </Show>

        <Show when={state.diff} keyed>
          {(diff) => (
            <div class="diff" classList={{ "diff-ok": diff.ok, "diff-bad": !diff.ok }}>
              <div class="diff-head">
                <span class="diff-verdict">
                  {diff.ok ? "✓ wasm ≡ native" : "✗ unexplained divergence"}
                </span>
                <span class="muted">
                  {diff.deterministic
                    ? "deterministic (byte-identity required)"
                    : `nondeterministic: ${diff.wasmEffects}/${diff.nativeEffects} effect(s) recorded`}
                </span>
              </div>
              <ul class="diff-list">
                <For each={diff.artifacts}>
                  {(a) => (
                    <li classList={{ "diff-match": a.match, "diff-expected": !a.match && a.expectedNote !== null, "diff-mismatch": !a.match && a.expectedNote === null }}>
                      <span class="diff-name">{a.name}</span>
                      <Show
                        when={a.match}
                        fallback={
                          <span class="diff-detail">
                            differ @ byte {a.firstDiffByte} (wasm {a.wasmLen}B / native {a.nativeLen}B)
                            <Show when={a.expectedNote}>
                              {" "}— <span class="diff-note">{a.expectedNote}</span>
                            </Show>
                          </span>
                        }
                      >
                        <span class="diff-detail">identical ({a.wasmLen}B)</span>
                      </Show>
                    </li>
                  )}
                </For>
                <li classList={{ "diff-match": diff.stdoutMatch, "diff-expected": !diff.stdoutMatch && diff.stdoutNote !== null, "diff-mismatch": !diff.stdoutMatch && diff.stdoutNote === null }}>
                  <span class="diff-name">stdout</span>
                  <span class="diff-detail">
                    {diff.stdoutMatch ? "identical" : "differ"}
                    <Show when={!diff.stdoutMatch && diff.stdoutNote}>
                      {" "}— <span class="diff-note">{diff.stdoutNote}</span>
                    </Show>
                  </span>
                </li>
              </ul>
            </div>
          )}
        </Show>
      </section>

      <Show
        when={state.error === null}
        fallback={<div class="error">decode failed: {state.error}</div>}
      >
        <Show
          when={state.traces.length > 0}
          fallback={<div class="hint">Run a program above, drop a <code>.lunetrace</code> file here, or use “Open”. A program with a hot loop records a trace.</div>}
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
