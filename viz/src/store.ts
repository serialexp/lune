// App state: the loaded trace file's decoded views + the current selection.
// A native SolidJS store (no prop drilling) — components read `state` and call
// the actions here.

import { createStore } from "solid-js/store";
import { decodeTraceFile } from "./decode";
import { viewsOf, type TraceView } from "./disasm";
import { loadLune, type LuneModule, type LuneRunResult, type LuneReplayResult, type LuneDiagnostic, type BacktraceFrame } from "./wasm/lune";
import { runNative } from "./native";
import { diffRuns, type DiffReport } from "./diff";
import { decodeSnapshot, type SnapshotView } from "./snapshot";

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
  /** The last runtime error's call chain, deepest-first. Null on a clean run or
   *  an error with no locatable frame. The UI flattens it to a one-line
   *  traceback; the editor squiggle still uses `runErrorSpan` (the leaf only). */
  runBacktrace: BacktraceFrame[] | null;
  /** The full artifact bundle from the last wasm run (kept for the differential
   *  validator in Commit 3). */
  lastRun: LuneRunResult | null;
  /** The last dual-execution diff (wasm vs native), null until "Run both". */
  diff: DiffReport | null;
  /** Execution timing from the last wasm run: `totalMs` is the whole wasm call
   *  (compile+execute+serialize); `execMs` the VM-execute-only subset. Null until
   *  the first run. */
  timing: { execMs: number; totalMs: number } | null;

  // --- deterministic step-replay (Phase 7 v8) ---
  /** True while the replay panel is open. Opened only after a successful run
   *  that produced a non-empty safepoint index. */
  replayActive: boolean;
  /** The recorded effect log + the exact source that produced it, frozen when
   *  replay opened. Replay re-runs this pair to any step k; editing the editor
   *  afterwards doesn't disturb an open replay (it replays the captured source). */
  replayEffects: Uint8Array | null;
  replaySource: string;
  /** Total instruction-boundary safepoints in the captured run (step count). */
  safepointCount: number;
  /** True if the record run hit the safepoint cap (stepping is bounded; surfaced
   *  in the panel, never silent). */
  safepointCapped: boolean;
  /** Per-safepoint source line (`safepointLines[k-1]` = line pending at step k).
   *  Drives line-grain navigation without extra wasm round-trips. */
  safepointLines: Uint32Array;
  /** Step grain: `instr` = one stop per safepoint; `line` = one stop per source
   *  line change. */
  grain: "instr" | "line";
  /** The actual safepoint indices (1-based; the trailing one is `safepointCount+1`
   *  = the finished terminal state) the slider steps through, for the current
   *  grain. Recomputed when the run or grain changes. */
  replayStops: number[];
  /** Slider position: an index into `replayStops`. */
  replayPos: number;
  /** The VM state at the current step (null until a step is fetched). */
  replayState: LuneReplayResult | null;
  /** The decoded globals + locals view of `replayState.keyframe`, or null. */
  replayView: SnapshotView | null;
}

/** The safepoint indices the slider steps through for a grain. `instr` is every
 *  safepoint 1..count; `line` is just the steps where the source line changes.
 *  Both append `count+1` — the terminal "finished" state (replay past the last
 *  safepoint reproduces the uninterrupted run). */
function buildStops(grain: "instr" | "line", count: number, lines: Uint32Array): number[] {
  if (count <= 0) return [];
  const stops: number[] = [];
  if (grain === "instr") {
    for (let k = 1; k <= count; k++) stops.push(k);
  } else {
    let prev = -1;
    for (let k = 1; k <= count; k++) {
      const ln = lines[k - 1] ?? 0;
      if (ln !== prev) {
        stops.push(k);
        prev = ln;
      }
    }
  }
  stops.push(count + 1); // finished
  return stops;
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
  runBacktrace: null,
  lastRun: null,
  diff: null,
  timing: null,
  replayActive: false,
  replayEffects: null,
  replaySource: "",
  safepointCount: 0,
  safepointCapped: false,
  safepointLines: new Uint32Array(0),
  grain: "instr",
  replayStops: [],
  replayPos: 0,
  replayState: null,
  replayView: null,
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
function applyWasmResult(result: LuneRunResult, fileName: string, source: string): void {
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
    // The full call chain (deepest-first) for the traceback line; null on a
    // clean run or an unlocatable fault.
    runBacktrace: result.status !== 0 && result.backtrace.length > 0 ? result.backtrace : null,
    lastRun: result,
    timing: { execMs: result.execMs, totalMs: result.totalMs },
    // A fresh run invalidates any open replay; freeze the new run's effects +
    // source + safepoint index so replay can re-run them to any step.
    replayActive: false,
    replayEffects: result.effects,
    replaySource: source,
    safepointCount: result.safepointCount,
    safepointCapped: result.safepointCapped,
    safepointLines: result.safepointLines,
    replayStops: [],
    replayPos: 0,
    replayState: null,
    replayView: null,
  });
}

/** True when the last run produced a replayable step index (a successful run
 *  with at least one safepoint). Gates the "Replay" affordance. */
export function canReplay(): boolean {
  return state.runError === null && state.safepointCount > 0 && state.replayEffects !== null;
}

/** Open the step-replay panel on the last run's captured effects + source, and
 *  land on the first step. No-op if there's nothing replayable. */
export function openReplay(): void {
  if (!canReplay()) return;
  const stops = buildStops(state.grain, state.safepointCount, state.safepointLines);
  setState({ replayActive: true, replayStops: stops, replayPos: 0 });
  setReplayPos(0);
}

/** Close the panel (clears the editor's current-line highlight via `replayState`). */
export function closeReplay(): void {
  setState({ replayActive: false, replayState: null, replayView: null });
}

/** Switch step grain (instr ⇄ line), keeping the viewer at roughly the same
 *  point: snap to the last stop at or before the current safepoint. */
export function setGrain(grain: "instr" | "line"): void {
  const curK = state.replayStops[state.replayPos] ?? 1;
  const stops = buildStops(grain, state.safepointCount, state.safepointLines);
  let pos = 0;
  for (let i = 0; i < stops.length; i++) {
    if (stops[i] <= curK) pos = i;
    else break;
  }
  setState({ grain, replayStops: stops });
  setReplayPos(pos);
}

/** Move the slider to position `pos` (an index into `replayStops`) and fetch the
 *  VM state there by deterministically replaying the captured effects to that
 *  safepoint. Re-running to the same position yields identical state every time
 *  (the deterministic-replay payoff). */
export function setReplayPos(pos: number): void {
  const stops = state.replayStops;
  if (stops.length === 0 || state.replayEffects === null) return;
  const clamped = Math.max(0, Math.min(pos, stops.length - 1));
  const k = stops[clamped];
  void (async () => {
    try {
      const mod = await lune();
      const rs = mod.replay(state.replaySource, state.replayEffects!, k);
      setState({ replayPos: clamped, replayState: rs, replayView: decodeSnapshot(rs.keyframe) });
    } catch (e) {
      setState({
        replayPos: clamped,
        replayState: null,
        replayView: null,
        runError: e instanceof Error ? e.message : String(e),
      });
    }
  })();
}

/** Step one stop backward / forward (no wrap). */
export function stepReplay(delta: number): void {
  setReplayPos(state.replayPos + delta);
}

/**
 * Run `state.source` through the in-browser wasm VM and surface its artifacts:
 * stdout, diagnostics, and the recorded trace (decoded into the existing trace
 * views). Errors are captured into the store, never thrown.
 */
export async function runWasm(): Promise<void> {
  setState({ running: true, runError: null, runErrorSpan: null, runBacktrace: null, diff: null });
  try {
    const mod = await lune();
    const src = state.source;
    const result = mod.runSource(src);
    applyWasmResult(result, "(wasm run)", src);
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
  setState({ running: true, runError: null, runErrorSpan: null, runBacktrace: null, diff: null });
  try {
    const mod = await lune();
    const src = state.source;
    const [wasm, native] = await Promise.all([
      Promise.resolve(mod.runSource(src)),
      runNative(src),
    ]);
    applyWasmResult(wasm, "(wasm + native diff)", src);
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
