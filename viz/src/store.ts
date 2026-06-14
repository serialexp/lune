// App state: the loaded trace file's decoded views + the current selection.
// A native SolidJS store (no prop drilling) — components read `state` and call
// the actions here.

import { createStore } from "solid-js/store";
import { decodeTraceFile } from "./decode";
import { viewsOf, type TraceView } from "./disasm";
import { loadLune, type LuneModule, type LuneRunResult, type LuneDiagnostic } from "./wasm/lune";
import { runNative } from "./native";
import { diffRuns, type DiffReport } from "./diff";

interface VizState {
  fileName: string | null;
  /** Wire-format version word from the TraceFile header. */
  version: number | null;
  traces: TraceView[];
  /** Index into `traces`, or -1 when empty. */
  selected: number;
  /** Decode/load error message, if the last load failed. */
  error: string | null;

  // --- authoring + in-browser execution (Phase 7 v3) ---
  /** The editable source for the in-browser VM. */
  source: string;
  /** True while a wasm run is in flight. */
  running: boolean;
  /** The program's stdout from the last wasm run (null = never run). */
  stdout: string | null;
  /** Diagnostics / runtime-error text from the last wasm run, if it failed. */
  runError: string | null;
  /** Located runtime error from the last wasm run (for the editor squiggle):
   *  1-based `line` + UTF-8 byte span `[start,end)`. Null unless the last run
   *  faulted with a locatable instruction. */
  runErrorSpan: { line: number; start: number; end: number } | null;
  /** The full artifact bundle from the last wasm run (kept for the differential
   *  validator in Commit 3). */
  lastRun: LuneRunResult | null;
  /** The last dual-execution diff (wasm vs native), null until "Run both". */
  diff: DiffReport | null;
}

const DEFAULT_SOURCE = `-- Edit and run in-browser (wasm). A hot loop records a trace.
local sum = 0
for i = 1, 100 do
  sum = sum + i
end
print(sum)
`;

const [state, setState] = createStore<VizState>({
  fileName: null,
  version: null,
  traces: [],
  selected: -1,
  error: null,
  source: DEFAULT_SOURCE,
  running: false,
  stdout: null,
  runError: null,
  runErrorSpan: null,
  lastRun: null,
  diff: null,
});

export { state };

/** Lazily-instantiated singleton wasm VM. The module is ~2 MiB; load it once on
 *  first run, then reuse. */
let lunePromise: Promise<LuneModule> | null = null;
function lune(): Promise<LuneModule> {
  if (lunePromise === null) {
    const base = import.meta.env?.BASE_URL ?? "./";
    lunePromise = loadLune(`${base}lune.wasm`);
  }
  return lunePromise;
}

/** Update the editable source (does not run). */
export function setSource(src: string): void {
  setState("source", src);
}

/**
 * Compile-only validation: parse + compile `src` through the in-browser lune
 * frontend (the wasm `check` entry — it does NOT run the program) and return its
 * diagnostics. Drives the editor's live linter. A transient wasm error yields no
 * diagnostics rather than spamming squiggles. Wasm access stays funnelled through
 * the store (the editor never touches the module directly — Rule #9).
 */
export async function checkSource(src: string): Promise<LuneDiagnostic[]> {
  try {
    const mod = await lune();
    return mod.check(src);
  } catch {
    return [];
  }
}

/** Decode a wasm run's recorded trace and push it + stdout into the store. The
 *  trace flows into the existing views exactly as a loaded .lunetrace would. */
function applyWasmResult(result: LuneRunResult, fileName: string): void {
  let traces: TraceView[] = [];
  let version: number | null = null;
  if (result.trace.length > 0) {
    const file = decodeTraceFile(result.trace);
    version = file.version;
    traces = viewsOf(file);
  }
  setState({
    fileName,
    version,
    traces,
    selected: traces.length > 0 ? 0 : -1,
    error: null,
    stdout: result.stdout,
    runError: result.status === 0 ? null : result.diagnostics || "run failed",
    // A located runtime error (errorLine > 0) drives the editor squiggle. Parse/
    // compile errors carry no run-time span here (errorLine stays 0).
    runErrorSpan: result.status !== 0 && result.errorLine > 0
      ? { line: result.errorLine, start: result.errorStart, end: result.errorEnd }
      : null,
    lastRun: result,
  });
}

/**
 * Run `state.source` through the in-browser wasm VM and surface its artifacts:
 * stdout, diagnostics, and the recorded trace (decoded into the existing trace
 * views). Errors are captured into the store, never thrown.
 */
export async function runWasm(): Promise<void> {
  setState({ running: true, runError: null, runErrorSpan: null, diff: null });
  try {
    const mod = await lune();
    const result = mod.runSource(state.source);
    applyWasmResult(result, "(wasm run)");
    setState({ running: false });
  } catch (e) {
    setState({
      running: false,
      runError: e instanceof Error ? e.message : String(e),
    });
  }
}

/**
 * The dual-execution differential validator: run `state.source` through BOTH the
 * in-browser wasm VM and the native binary (via the dev-server `POST /run`), and
 * compare their artifacts byte-for-byte. Two different engines agreeing is the
 * strongest determinism check we have (docs/design/02-determinism.md). The wasm
 * run also populates the trace views as usual.
 */
export async function runBoth(): Promise<void> {
  setState({ running: true, runError: null, runErrorSpan: null, diff: null });
  try {
    const mod = await lune();
    const [wasm, native] = await Promise.all([
      Promise.resolve(mod.runSource(state.source)),
      runNative(state.source),
    ]);
    applyWasmResult(wasm, "(wasm + native diff)");
    setState({ diff: diffRuns(wasm, native), running: false });
  } catch (e) {
    setState({
      running: false,
      runError: e instanceof Error ? e.message : String(e),
    });
  }
}

/** Decode a `.lunetrace` buffer and replace the current view. */
export function loadBytes(name: string, bytes: Uint8Array): void {
  try {
    const file = decodeTraceFile(bytes);
    const traces = viewsOf(file);
    setState({
      fileName: name,
      version: file.version,
      traces,
      selected: traces.length > 0 ? 0 : -1,
      error: null,
    });
  } catch (e) {
    setState({
      fileName: name,
      version: null,
      traces: [],
      selected: -1,
      error: e instanceof Error ? e.message : String(e),
    });
  }
}

/**
 * Fetch a `.lunetrace` from a URL and load it. Powers the deep-link affordance
 * (`?src=<url>`) so a trace can be opened directly without the file picker.
 */
export async function loadFromUrl(url: string): Promise<void> {
  try {
    const resp = await fetch(url);
    if (!resp.ok) throw new Error(`fetch ${url}: ${resp.status} ${resp.statusText}`);
    const bytes = new Uint8Array(await resp.arrayBuffer());
    const name = url.split("/").pop() || url;
    loadBytes(name, bytes);
  } catch (e) {
    setState({
      fileName: url,
      version: null,
      traces: [],
      selected: -1,
      error: e instanceof Error ? e.message : String(e),
    });
  }
}

export function selectTrace(index: number): void {
  setState("selected", index);
}

/** The currently-selected trace view, or null. */
export function selectedTrace(): TraceView | null {
  return state.selected >= 0 ? state.traces[state.selected] ?? null : null;
}
