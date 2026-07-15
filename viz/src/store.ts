// App state: the loaded trace file's decoded views + the current selection.
// A native SolidJS store (no prop drilling) — components read `state` and call
// the actions here.

import { createStore } from "solid-js/store";
import { decodeTraceFile, decodeExecLogFile, decodeCoverageFile, type TraceExecLogOutput, type CoverageFileOutput, type CoverageAnchorOutput } from "./decode";
import { viewsOf, type TraceView } from "./disasm";
import { flattenExec, type ExecStep } from "./exec";
import { loadLune, type LuneModule, type LuneRunResult, type LuneReplayResult, type LuneDiagnostic, type BacktraceFrame, type ProtoDisasm } from "./wasm/lune";
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
  /** The script name used as `arg[0]` and shown as the loaded-file label. Set
   *  when a local source file is opened; a plain default otherwise. `arg[0]` is
   *  cancelled by the differential validator, so its exact value is cosmetic. */
  scriptName: string;
  /** Raw script-args string from the args input (whitespace-separated). Fills
   *  `arg[1..]` for the run — e.g. nsieve's workload size. Empty ⇒ no user args. */
  scriptArgs: string;
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
  /** Static disassembly of the captured run's proto tree, indexed by `id` (the
   *  replay cursor's `protoId`). Frozen with the run; drives the bytecode view. */
  disasm: ProtoDisasm[];

  // --- JIT-trace iteration animation (fourth record family) ---
  /** Decoded per-trace execution logs from the last wasm run, in cache order.
   *  Each `trace_id` is the index into `traces` (the trace-cache index), so the
   *  selected trace maps to its log directly. Empty when nothing ran hot. */
  execLogs: TraceExecLogOutput[];
  /** Animation slider position: an index into the selected trace's flattened
   *  event stream (`traceExecSteps()`). Reset to 0 on run / trace change. */
  traceExecPos: number;

  // --- JIT execution coverage (fifth record family) ---
  /** Decoded coverage artifact from the last wasm run: the aggregate
   *  native-vs-tier-0 iteration split, the raw JIT event counters, and the
   *  per-anchor breakdown. Null until a run produces one (a run that never
   *  reached a back-edge yields no anchors, but the aggregate is still present).
   *  Under wasm the `cycles_*`/`run_cycles` fields are 0 (no rdtsc) — the UI
   *  weighs by iterations only. */
  coverage: CoverageFileOutput | null;
  /** The honest, time-weighted coverage from the NATIVE binary (real TSC cycles),
   *  fetched via the dev-server `/run` endpoint during "Run both + diff". Null on a
   *  plain wasm run (the panel's time column then reads "run native"). The native
   *  run is `--jit-native`, so `cycles_traced` is genuine native-machine-code time
   *  — the number the wasm iteration split can't show. */
  nativeCoverage: CoverageFileOutput | null;
}

/** The coverage class of a source line, from the last run's per-anchor data.
 *  `native` = the loop's back-edges predominantly ran on compiled native code;
 *  `covered-interpreted` = a trace exists for the loop but it predominantly fell
 *  back to the tier-0 interpreter (the smell — traced yet not native);
 *  `uncovered` = no trace exists, the loop ran purely interpreted. */
export type CoverageClass = "native" | "covered-interpreted" | "uncovered";

/** Per-source-line coverage tally (loop-header anchors resolved to their line).
 *  Counts are back-edge iterations. `cls` is the dominant bucket. */
export interface LineCoverage {
  cls: CoverageClass;
  /** Iterations that ran as native compiled code. */
  native: number;
  /** Interpreted iterations at an anchor that HAS a trace (the smell bucket). */
  coveredInterp: number;
  /** Interpreted iterations at an anchor with no trace at all. */
  uncovered: number;
}

/** Pick the dominant bucket. Ties resolve toward the more interesting signal:
 *  native > covered-interpreted (smell) > uncovered. */
function classifyLine(c: LineCoverage): CoverageClass {
  if (c.native >= c.coveredInterp && c.native >= c.uncovered && c.native > 0) return "native";
  if (c.coveredInterp >= c.uncovered && c.coveredInterp > 0) return "covered-interpreted";
  if (c.uncovered > 0) return "uncovered";
  // All-zero anchor (has_trace set but never iterated): treat as the smell.
  return "covered-interpreted";
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
  scriptName: "playground.lune",
  scriptArgs: "",
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
  disasm: [],
  execLogs: [],
  traceExecPos: 0,
  coverage: null,
  nativeCoverage: null,
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

/** Load a local source file's text into the editor (does not run). Sets the
 *  script name (used as `arg[0]` and the loaded-file label). Distinct from
 *  `loadBytes`, which decodes a binary `.lunetrace` artifact into the trace view. */
export function loadSourceText(name: string, text: string): void {
  setState({ source: text, scriptName: name });
}

/** Update the raw script-args string (does not run). */
export function setScriptArgs(args: string): void {
  setState("scriptArgs", args);
}

/** Split a raw args string into an argv, on runs of whitespace, dropping empties.
 *  Deliberately simple — no shell quoting or escapes (documented in the UI); a
 *  single token per whitespace-separated word. Pure, so it's unit-testable. */
export function parseArgsString(s: string): string[] {
  return s.split(/\s+/).filter((w) => w.length > 0);
}

/** The argv handed to the wasm VM for the current source + args: `[scriptName,
 *  ...userArgs]` when there are user args, else `[]` (leaving `arg` an empty
 *  table, the historical default). The native side receives only `userArgs`
 *  (`runNative`) — it supplies `arg[0]` = the temp source path itself. */
function wasmArgv(): string[] {
  const userArgs = parseArgsString(state.scriptArgs);
  return userArgs.length > 0 ? [state.scriptName, ...userArgs] : [];
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
  // The trace execution log (fourth record family) — what the IR-interpreter
  // actually did per hot iteration / exit ramp. A decode failure degrades to no
  // animation (the static IR table still renders), never throws the run away.
  let execLogs: TraceExecLogOutput[] = [];
  if (result.executionLog.length > 0) {
    try {
      execLogs = decodeExecLogFile(result.executionLog).logs;
    } catch {
      execLogs = [];
    }
  }
  // The JIT coverage artifact (fifth record family) — the native-vs-tier-0
  // execution split + per-anchor breakdown. A decode failure degrades to no
  // coverage view (the rest of the run still renders), never throws it away.
  let coverage: CoverageFileOutput | null = null;
  if (result.coverage.length > 0) {
    try {
      coverage = decodeCoverageFile(result.coverage);
    } catch {
      coverage = null;
    }
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
    disasm: result.disasm,
    execLogs,
    traceExecPos: 0,
    coverage,
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
    const result = mod.runSource(src, wasmArgv());
    applyWasmResult(result, "(wasm run)", src);
    // A wasm-only run has no cycle counter — drop any prior native time split so
    // the panel's time column reverts to "run native".
    setState({ running: false, nativeCoverage: null });
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
    // wasm gets `[scriptName, ...userArgs]`; native gets the raw userArgs and
    // prepends the temp source path as its own arg[0]. Both see the same
    // arg[1..], which is what the keyframe compare requires (arg[0] is cancelled).
    const userArgs = parseArgsString(state.scriptArgs);
    const [wasm, native] = await Promise.all([
      Promise.resolve(mod.runSource(src, wasmArgv())),
      runNative(src, userArgs),
    ]);
    applyWasmResult(wasm, "(wasm + native diff)", src);
    // The native run carries the honest time-weighted coverage (real TSC cycles).
    // Decode best-effort — a failure just leaves the time column grayed.
    let nativeCoverage: CoverageFileOutput | null = null;
    if (native.coverage.length > 0) {
      try {
        nativeCoverage = decodeCoverageFile(native.coverage);
      } catch {
        nativeCoverage = null;
      }
    }
    setState({ diff: diffRuns(wasm, native), running: false, nativeCoverage });
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
      // A loaded .lunetrace carries no coverage — drop any stale run panel.
      coverage: null,
      nativeCoverage: null,
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
  // A new selection resets the animation to the start of that trace's stream.
  setState({ selected: index, traceExecPos: 0 });
}

/** The currently-selected trace view, or null. */
export function selectedTrace(): TraceView | null {
  return state.selected >= 0 ? state.traces[state.selected] ?? null : null;
}

/** The execution log for the currently-selected trace, or null. `trace_id` is
 *  the trace-cache index, which equals `state.selected` (both index the cache in
 *  order). Null when the selected trace never executed (not hot enough). */
export function selectedTraceExec(): TraceExecLogOutput | null {
  if (state.selected < 0) return null;
  return state.execLogs.find((l) => l.trace_id === state.selected) ?? null;
}

/** The selected trace's exec log flattened into one linear event stream the
 *  animation slider scrubs. Empty when there's no log for the selection. */
export function traceExecSteps(): ExecStep[] {
  const log = selectedTraceExec();
  return log ? flattenExec(log) : [];
}

/** Move the animation slider to `pos` (clamped into the flattened stream). */
export function setTraceExecPos(pos: number): void {
  const n = traceExecSteps().length;
  if (n === 0) {
    setState("traceExecPos", 0);
    return;
  }
  setState("traceExecPos", Math.max(0, Math.min(pos, n - 1)));
}

/** Step the animation one event backward / forward (no wrap). */
export function stepTraceExec(delta: number): void {
  setTraceExecPos(state.traceExecPos + delta);
}

/** The aggregate coverage split, as raw counts + total + percentages. */
export interface CoverageAggregate {
  native: number;
  coveredInterp: number;
  uncovered: number;
  total: number;
  nativePct: number;
  coveredInterpPct: number;
  uncoveredPct: number;
}

/** Pure resolver: map per-anchor coverage `(proto_id, pc)` to source lines using
 *  the static disasm (`disasm[proto_id].instrs[pc].line`). Anchors landing on the
 *  same line are summed and the line's dominant class computed. Anchors the
 *  disasm can't place (no proto, out-of-range pc, or line 0) are dropped. Pure —
 *  no store access — so it's unit-testable directly. Mirrors `replayDisasm`'s
 *  proto-by-id lookup. */
export function resolveCoverageLines(
  anchors: CoverageAnchorOutput[],
  disasm: ProtoDisasm[],
): Map<number, LineCoverage> {
  const map = new Map<number, LineCoverage>();
  for (const a of anchors) {
    const proto = disasm.find((p) => p.id === a.proto_id);
    const line = proto?.instrs[a.pc]?.line ?? 0;
    if (line <= 0) continue;
    let e = map.get(line);
    if (e === undefined) {
      e = { cls: "uncovered", native: 0, coveredInterp: 0, uncovered: 0 };
      map.set(line, e);
    }
    // Iteration counts are exact small integers here (back-edge tallies); Number
    // is lossless well past any realistic loop-trip count.
    e.native += Number(a.traced_iters);
    if (a.has_trace !== 0) e.coveredInterp += Number(a.interp_iters);
    else e.uncovered += Number(a.interp_iters);
  }
  for (const e of map.values()) e.cls = classifyLine(e);
  return map;
}

/** Pure aggregate: the native / covered-interpreted / uncovered iteration split
 *  from a coverage artifact. The three buckets mirror `CoverageFile`'s
 *  `iters_traced` / `iters_tier0_covered` / `iters_tier0_uncovered`. Pure — no
 *  store access. */
export function aggregateCoverage(cov: CoverageFileOutput): CoverageAggregate {
  const native = Number(cov.iters_traced);
  const coveredInterp = Number(cov.iters_tier0_covered);
  const uncovered = Number(cov.iters_tier0_uncovered);
  const total = native + coveredInterp + uncovered;
  const p = (n: number): number => (total > 0 ? (n / total) * 100 : 0);
  return {
    native,
    coveredInterp,
    uncovered,
    total,
    nativePct: p(native),
    coveredInterpPct: p(coveredInterp),
    uncoveredPct: p(uncovered),
  };
}

/** The time-weighted coverage split, in TSC cycles + percentage of the whole
 *  run. The three loop buckets mirror the iteration split; `other` is non-loop
 *  time (call overhead, allocation, the parts that never hit a back-edge). */
export interface CoverageTimeSplit {
  native: number;
  coveredInterp: number;
  uncovered: number;
  other: number;
  run: number;
  nativePct: number;
  coveredInterpPct: number;
  uncoveredPct: number;
  otherPct: number;
}

/** Pure time split from a coverage artifact carrying real cycles. Percentages are
 *  of `run_cycles` (the honest denominator the CLI uses — "% of run"), so the
 *  three loop buckets + `other` sum to 100%. Returns null when the artifact has no
 *  cycle data (`run_cycles == 0`, i.e. a wasm run — no rdtsc). Pure. */
export function timeSplitOf(cov: CoverageFileOutput): CoverageTimeSplit | null {
  const run = Number(cov.run_cycles);
  if (run <= 0) return null;
  const native = Number(cov.cycles_traced);
  const coveredInterp = Number(cov.cycles_tier0_covered);
  const uncovered = Number(cov.cycles_tier0_uncovered);
  const other = Math.max(0, run - native - coveredInterp - uncovered);
  const p = (n: number): number => (n / run) * 100;
  return {
    native,
    coveredInterp,
    uncovered,
    other,
    run,
    nativePct: p(native),
    coveredInterpPct: p(coveredInterp),
    uncoveredPct: p(uncovered),
    otherPct: p(other),
  };
}

/** The honest native time split from the last "Run both" (store wrapper over
 *  {@link timeSplitOf}). Null on a wasm-only run — the panel then grays the time
 *  column and prompts "run native". */
export function nativeTimeSplit(): CoverageTimeSplit | null {
  return state.nativeCoverage ? timeSplitOf(state.nativeCoverage) : null;
}

/** Resolve the last run's per-anchor coverage to source lines (store wrapper over
 *  {@link resolveCoverageLines}). Empty when there's no coverage. */
export function coverageByLine(): Map<number, LineCoverage> {
  const cov = state.coverage;
  if (cov === null) return new Map();
  return resolveCoverageLines(cov.anchors, state.disasm);
}

/** The last run's aggregate coverage split (store wrapper over
 *  {@link aggregateCoverage}). Null when there's no coverage. */
export function coverageAggregate(): CoverageAggregate | null {
  const cov = state.coverage;
  if (cov === null) return null;
  return aggregateCoverage(cov);
}

/** The bytecode view at the current replay step: the disassembly of the proto
 *  the cursor is in (`replayState.protoId`) plus the pending `pc`. Null when no
 *  step is loaded, the program has finished (no live frame), or the disasm is
 *  unavailable. Drives the step-replay panel's bytecode listing. */
export function replayDisasm(): { proto: ProtoDisasm; pc: number } | null {
  const rs = state.replayState;
  if (rs === null || rs.finished || rs.status !== 0) return null;
  const proto = state.disasm.find((p) => p.id === rs.protoId);
  if (proto === undefined) return null;
  return { proto, pc: rs.pc };
}
