// App state: the loaded trace file's decoded views + the current selection.
// A native SolidJS store (no prop drilling) — components read `state` and call
// the actions here.

import { createStore } from "solid-js/store";
import { decodeTraceFile, decodeExecLogFile, decodeCoverageFile, type TraceExecLogOutput, type CoverageFileOutput, type CoverageAnchorOutput } from "./decode";
import { viewsOf, type TraceView, type SourcePoint } from "./disasm";
import { flattenExec, type ExecStep } from "./exec";
import { type MahinaRunResult, type MahinaReplayResult, type MahinaDiagnostic, type BacktraceFrame, type ProtoDisasm, type RunChunk, type SourceFile } from "./wasm/mahina";
import { normalizePath } from "./paths";
import { mahinaWorker, StoppedError } from "./wasm/mahina-client";
import { runNative } from "./native";
import { diffRuns, type DiffReport } from "./diff";
import { decodeSnapshot, type SnapshotView, type NamedValue } from "./snapshot";

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
  /** The program's files, in tab order: what the editor edits and what a run
   *  can `require`/`loadfile`/`dofile`. Paths are normalized (`normalizePath`). */
  files: SourceFile[];
  /** The file a run executes (its path is `arg[0]`). Always one of `files`. */
  entryPath: string;
  /** The tab the editor shows: one of `files`, or one of the last run's
   *  read-only `runFiles` that isn't a workspace file. */
  activePath: string;
  /** Why the last picked/dropped source file wasn't loaded (not text), or null.
   *  Shown beside the editor; cleared by the next load. */
  sourceError: string | null;
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
   *  the file, 1-based `line` + UTF-8 byte span `[start,end)` in it. Null
   *  unless the last run faulted with a locatable instruction. */
  runErrorSpan: { path: string; line: number; start: number; end: number } | null;
  /** The last runtime error's call chain, deepest-first. Null on a clean run or
   *  an error with no locatable frame. The UI flattens it to a one-line
   *  traceback; the editor squiggle still uses `runErrorSpan` (the leaf only). */
  runBacktrace: BacktraceFrame[] | null;
  /** The full artifact bundle from the last wasm run (kept for the differential
   *  validator in Commit 3). */
  lastRun: MahinaRunResult | null;
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
  /** The recorded effect log + the exact entry source that produced it, frozen
   *  when replay opened. Replay re-runs this pair to any step k (the other
   *  files' reads are effects in the log); editing the editor afterwards doesn't
   *  disturb an open replay (it replays the captured source). */
  replayEffects: Uint8Array | null;
  replaySource: string;
  /** The files the last run compiled, one per chunk (index = chunk index; 0 is
   *  the entry). Names the file of every proto id; see `runFileOf`. */
  runFiles: RunFile[];
  /** Total instruction-boundary safepoints in the captured run (step count). */
  safepointCount: number;
  /** True if the record run hit the safepoint cap (stepping is bounded; surfaced
   *  in the panel, never silent). */
  safepointCapped: boolean;
  /** Per-safepoint source line (`safepointLines[k-1]` = line pending at step k).
   *  Drives line-grain navigation without extra wasm round-trips. */
  safepointLines: Uint32Array;
  /** Parallel to `safepointLines`: the proto each line is in (names its file). */
  safepointProtos: Uint32Array;
  /** Parallel to `safepointLines`: 1 where a replay can stop. 0 inside code a
   *  native runs that can't suspend yet (a `pcall` body, a `require`d module, a
   *  metamethod); the slider skips those steps. */
  safepointStoppable: Uint8Array;
  /** How many of the steps are not stoppable (0s in `safepointStoppable`). */
  safepointNested: number;
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
  replayState: MahinaReplayResult | null;
  /** The decoded globals + locals view of `replayState.keyframe`, or null. */
  replayView: SnapshotView | null;
  /** The globals as they stood at the first step (before the program ran a
   *  line), keyed by `globalKey`: the builtins. The globals list hides entries
   *  still equal to these unless `showBuiltinGlobals`. Null until that step is
   *  fetched. */
  replayBaseGlobals: string[] | null;
  /** Show the builtin globals too (the globals list's toggle). */
  showBuiltinGlobals: boolean;
  /** Static disassembly of the captured run's proto tree, indexed by `id` (the
   *  replay cursor's `protoId`). Frozen with the run; drives the bytecode view. */
  disasm: ProtoDisasm[];

  // --- JIT-trace iteration animation (fourth record family) ---
  /** Decoded per-trace execution logs from the last wasm run. Each `trace_id` is
   *  the stable `Trace.id` the trace records also carry (`TraceView.id`), so a log
   *  joins to its trace by id — cache positions reshuffle when traces retire.
   *  Empty when nothing ran hot. */
  execLogs: TraceExecLogOutput[];
  /** Whether `execLogs` came from a run (which records them) — false for a
   *  loaded `.mahinatrace`, which holds the traces only. Tells "this trace never
   *  executed" apart from "this file has no execution logs to show". */
  execLogsRecorded: boolean;
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

  // --- trace ↔ source mapping ---
  /** Whether `traces` came from the last wasm run, so their proto ids match
   *  `disasm`. False for a loaded `.mahinatrace`: its protos are some other
   *  compile's, and mapping them through this run's disasm would point at the
   *  wrong lines. */
  tracesFromRun: boolean;
  /** Where the IR row under the pointer was recorded (null = none). */
  irHoverLoc: Loc | null;
  /** Where the last clicked IR row was recorded (null = none). */
  irPinnedLoc: Loc | null;
  /** Where the editor last scrolled to on request (`revealLoc`). */
  revealTarget: Loc | null;
  /** Bumped by every `revealLoc`, so revealing the same place again still
   *  scrolls the editor back to it. */
  revealSeq: number;
  /** The editor cursor's place once the user has put the cursor somewhere
   *  (null = not yet). IR rows recorded from that line are marked. */
  editorCursor: Loc | null;
}

/** A place in the program: a file (a `files` or `runFiles` path) and a 1-based
 *  line in it. */
export interface Loc {
  path: string;
  line: number;
}

/** One chunk of the last run, resolved to a file. */
export interface RunFile {
  /** The workspace file it was read from (normalized), or, for a chunk no
   *  workspace file holds (a `load`ed string), a read-only virtual path. */
  path: string;
  /** The text the chunk was compiled from. */
  text: string;
  firstProtoId: number;
  protoCount: number;
  /** True for a chunk no workspace file holds; shown as a read-only tab. */
  virtual: boolean;
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
  /** Interpreted iterations at a traced anchor before its trace existed. They
   *  are shown but never decide the class: every loop that tiers up has some. */
  warmup: number;
  /** Interpreted iterations at an anchor once it HAD a trace (the smell bucket). */
  coveredInterp: number;
  /** Interpreted iterations at an anchor with no trace at all. */
  uncovered: number;
}

/** Pick the dominant bucket, ignoring warm-up. Ties resolve toward the more
 *  interesting signal: native > covered-interpreted (smell) > uncovered. */
function classifyLine(c: LineCoverage): CoverageClass {
  if (c.native >= c.coveredInterp && c.native >= c.uncovered && c.native > 0) return "native";
  if (c.coveredInterp >= c.uncovered && c.coveredInterp > 0) return "covered-interpreted";
  if (c.uncovered > 0) return "uncovered";
  // Traced but never iterated after the trace committed (or not at all): the
  // trace didn't run, so treat it as the smell.
  return "covered-interpreted";
}

/** Short labels for the coverage classes, shared by the editor's stripe legend
 *  and tooltips. */
export const COVERAGE_LABEL: Record<CoverageClass, string> = {
  native: "ran native",
  "covered-interpreted": "traced, but ran tier-0",
  uncovered: "no trace, ran tier-0",
};

/** The hover text for a coverage stripe: the line's class and the iteration
 *  counts behind it. Pure. */
export function coverageLineTitle(c: LineCoverage): string {
  const n = (x: number) => x.toLocaleString("en-US");
  const parts = [`${n(c.native)} native`];
  if (c.coveredInterp > 0) parts.push(`${n(c.coveredInterp)} interpreted after tracing`);
  if (c.warmup > 0) parts.push(`${n(c.warmup)} warm-up before the trace`);
  if (c.uncovered > 0) parts.push(`${n(c.uncovered)} interpreted, no trace`);
  return `${COVERAGE_LABEL[c.cls]} — loop iterations: ${parts.join(" · ")}`;
}

/** A run's step index, as `runSource` returned it: per safepoint k (1-based),
 *  entry k-1 of each column. */
export interface StepIndex {
  count: number;
  lines: Uint32Array;
  protos: Uint32Array;
  stoppable: Uint8Array;
}

/** The safepoint indices the slider steps through for a grain. `instr` is every
 *  stoppable safepoint in 1..count; `line` is the first stoppable step of each
 *  run of steps on one line (a line change is a change of file or of line:
 *  line 3 of another file is a new line), so a line whose steps all ran inside
 *  nested code gets no stop. Both append `count+1` — the terminal "finished"
 *  state (replay past the last safepoint reproduces the uninterrupted run).
 *  Pure. */
export function buildStops(grain: "instr" | "line", index: StepIndex, fileKeyOf: (protoId: number) => number): number[] {
  const { count, lines, protos, stoppable } = index;
  if (count <= 0) return [];
  const stops: number[] = [];
  const canStop = (k: number) => stoppable[k - 1] === 1;
  if (grain === "instr") {
    for (let k = 1; k <= count; k++) if (canStop(k)) stops.push(k);
  } else {
    let prevLine = -1;
    let prevFile = -1;
    let pending = false; // a new line started and has no stop yet
    for (let k = 1; k <= count; k++) {
      const ln = lines[k - 1] ?? 0;
      const file = fileKeyOf(protos[k - 1] ?? 0);
      if (ln !== prevLine || file !== prevFile) {
        pending = true;
        prevLine = ln;
        prevFile = file;
      }
      if (pending && canStop(k)) {
        stops.push(k);
        pending = false;
      }
    }
  }
  stops.push(count + 1); // finished
  return stops;
}

/** The number of steps a replay cannot stop at. */
function countUnstoppable(stoppable: Uint8Array): number {
  let n = 0;
  for (let i = 0; i < stoppable.length; i++) if (stoppable[i] !== 1) n++;
  return n;
}

/** The last run's step index, from the store. */
function stepIndex(): StepIndex {
  return {
    count: state.safepointCount,
    lines: state.safepointLines,
    protos: state.safepointProtos,
    stoppable: state.safepointStoppable,
  };
}

export const DEFAULT_PATH = "main.mah";
export const DEFAULT_SOURCE = `-- Edit and run in-browser (wasm). A hot loop records a trace.
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
  files: [{ path: DEFAULT_PATH, text: DEFAULT_SOURCE }],
  entryPath: DEFAULT_PATH,
  activePath: DEFAULT_PATH,
  sourceError: null,
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
  runFiles: [],
  safepointCount: 0,
  safepointCapped: false,
  safepointLines: new Uint32Array(0),
  safepointProtos: new Uint32Array(0),
  safepointStoppable: new Uint8Array(0),
  safepointNested: 0,
  grain: "instr",
  replayStops: [],
  replayPos: 0,
  replayState: null,
  replayView: null,
  replayBaseGlobals: null,
  showBuiltinGlobals: false,
  disasm: [],
  execLogs: [],
  execLogsRecorded: false,
  traceExecPos: 0,
  coverage: null,
  nativeCoverage: null,
  tracesFromRun: false,
  irHoverLoc: null,
  irPinnedLoc: null,
  revealTarget: null,
  revealSeq: 0,
  editorCursor: null,
});

export { state };

/** The workspace file at `path`, or undefined. */
function workspaceFile(path: string): SourceFile | undefined {
  return state.files.find((f) => f.path === path);
}

/** The text of the tab at `path`: a workspace file's, else a read-only run
 *  file's; undefined when there is no such tab. */
export function fileText(path: string): string | undefined {
  return workspaceFile(path)?.text ?? state.runFiles.find((f) => f.virtual && f.path === path)?.text;
}

/** One editor tab. `virtual` tabs are the last run's read-only chunks. */
export interface Tab {
  path: string;
  entry: boolean;
  virtual: boolean;
}

/** The editor's tabs: the workspace files, then the last run's read-only
 *  chunks (each path once). */
export function tabs(): Tab[] {
  const out: Tab[] = state.files.map((f) => ({ path: f.path, entry: f.path === state.entryPath, virtual: false }));
  for (const rf of state.runFiles) {
    if (rf.virtual && !out.some((t) => t.path === rf.path)) out.push({ path: rf.path, entry: false, virtual: true });
  }
  return out;
}

/** Whether the active tab is read-only (one of the last run's chunks). */
export function activeReadOnly(): boolean {
  return workspaceFile(state.activePath) === undefined;
}

/** Update a workspace file's text (does not run). */
export function setFileText(path: string, text: string): void {
  const i = state.files.findIndex((f) => f.path === path);
  if (i >= 0 && state.files[i].text !== text) setState("files", i, "text", text);
}

/** Show the tab at `path` in the editor. */
export function setActivePath(path: string): void {
  if (fileText(path) !== undefined && state.activePath !== path) setState("activePath", path);
}

/** Make the workspace file at `path` the one a run executes. */
export function setEntryPath(path: string): void {
  if (workspaceFile(path) !== undefined) setState("entryPath", path);
}

/** Why `path` can't name a new or renamed file (null when it can). The name is
 *  checked as written: callers pass it through `normalizePath` first. */
export function filePathProblem(path: string | null, except?: string): string | null {
  if (path === null) return "a file name is relative, inside the program's directory (no leading / or ..)";
  if (path !== except && workspaceFile(path) !== undefined) return `${path} already exists`;
  return null;
}

/** Add an empty file with a fresh `untitledN.mah` name and show it. */
export function newFile(): string {
  let n = 1;
  while (workspaceFile(n === 1 ? "untitled.mah" : `untitled${n}.mah`) !== undefined) n++;
  const path = n === 1 ? "untitled.mah" : `untitled${n}.mah`;
  setState({ files: [...state.files, { path, text: "" }], activePath: path });
  return path;
}

/** Rename a workspace file. Returns why not (and changes nothing), or null. */
export function renameFile(from: string, to: string): string | null {
  const norm = normalizePath(to.trim());
  const problem = filePathProblem(norm, from);
  if (problem !== null || norm === null) return problem;
  if (norm === from) return null;
  setState({
    files: state.files.map((f) => (f.path === from ? { path: norm, text: f.text } : f)),
    entryPath: state.entryPath === from ? norm : state.entryPath,
    activePath: state.activePath === from ? norm : state.activePath,
  });
  return null;
}

/** Remove a workspace file. The last file stays (a program needs an entry); a
 *  removed entry passes to the first remaining file. */
export function closeFile(path: string): void {
  if (state.files.length <= 1 || workspaceFile(path) === undefined) return;
  const files = state.files.filter((f) => f.path !== path);
  setState({
    files,
    entryPath: state.entryPath === path ? files[0].path : state.entryPath,
    activePath: state.activePath === path ? files[0].path : state.activePath,
  });
}

/** Whether the workspace is still the untouched default program, which a
 *  loaded file replaces instead of joining. */
function pristineWorkspace(): boolean {
  return state.files.length === 1 && state.files[0].path === DEFAULT_PATH && state.files[0].text === DEFAULT_SOURCE;
}

/** Load a local source file's text into the editor (does not run). It replaces
 *  the untouched default program (and becomes the entry, its name `arg[0]`);
 *  otherwise it joins the program as a new tab, or replaces the file of the
 *  same name. Distinct from `loadBytes`, which decodes a binary `.mahinatrace`
 *  artifact into the trace view. */
export function loadSourceText(name: string, text: string): void {
  const path = normalizePath(name) ?? DEFAULT_PATH;
  if (pristineWorkspace()) {
    replaceWorkspace([{ path, text }], path);
    return;
  }
  const files = workspaceFile(path) !== undefined
    ? state.files.map((f) => (f.path === path ? { path, text } : f))
    : [...state.files, { path, text }];
  setState({ files, activePath: path, sourceError: null });
}

/** Replace the whole program (a project `mahina viz` serves, or the first file
 *  opened). An open replay describes the old program, so it closes. */
export function replaceWorkspace(files: SourceFile[], entry: string): void {
  setState({
    files,
    entryPath: entry,
    activePath: entry,
    sourceError: null,
    replayActive: false,
    replayState: null,
    replayView: null,
  });
}

/** mahina source is UTF-8 text (doc 06): the bytes of a file as source, or
 *  null when they can't be — invalid UTF-8, or a NUL byte (which no text file
 *  has, and every binary artifact does). Pure, so it's unit-testable. */
export function decodeSourceText(bytes: Uint8Array): string | null {
  if (bytes.includes(0)) return null;
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return null;
  }
}

/** Load a picked/dropped file's bytes as source, or say why it isn't source. */
export function loadSourceBytes(name: string, bytes: Uint8Array): void {
  const text = decodeSourceText(bytes);
  if (text === null) {
    setState("sourceError", `${name} is not a text file (binary or not UTF-8); not loaded`);
    return;
  }
  loadSourceText(name, text);
}

/** Load a dropped file by what it is: a `.mahinatrace` by name, else source
 *  text when it is text, else a trace by content (a trace saved under another
 *  name). A file that is neither is reported, never loaded as garbage. */
export function loadDroppedFile(name: string, bytes: Uint8Array): void {
  if (name.endsWith(".mahinatrace")) {
    loadBytes(name, bytes);
    return;
  }
  const text = decodeSourceText(bytes);
  if (text !== null) {
    loadSourceText(name, text);
    return;
  }
  try {
    decodeTraceFile(bytes);
  } catch {
    setState("sourceError", `${name} is neither source text nor a .mahinatrace; not loaded`);
    return;
  }
  loadBytes(name, bytes);
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
  return userArgs.length > 0 ? [state.entryPath, ...userArgs] : [];
}

/** The entry file's current text. */
function entrySource(): string {
  return workspaceFile(state.entryPath)?.text ?? "";
}

/** Resolve a run's chunks to files. Chunk 0 is the entry; a loaded chunk is
 *  the workspace file it was read from when its name normalizes to one whose
 *  text (as the run saw it, `ranFiles`) is the chunk's; anything else — a
 *  `load`ed string, a chunk under a made-up name — is a read-only virtual file
 *  named after its chunk. Pure. */
export function resolveRunFiles(chunks: RunChunk[], entry: string, entryText: string, ranFiles: SourceFile[]): RunFile[] {
  return chunks.map((c, i) => {
    if (i === 0) return { path: entry, text: entryText, firstProtoId: c.firstProtoId, protoCount: c.protoCount, virtual: false };
    const norm = normalizePath(c.name);
    const ws = norm === null ? undefined : ranFiles.find((f) => f.path === norm);
    if (ws !== undefined && ws.text === c.source) {
      return { path: ws.path, text: c.source, firstProtoId: c.firstProtoId, protoCount: c.protoCount, virtual: false };
    }
    const label = c.name.length > 0 ? c.name : "(load)";
    return { path: `${label} #${i}`, text: c.source, firstProtoId: c.firstProtoId, protoCount: c.protoCount, virtual: true };
  });
}

/**
 * Compile-only validation: parse + compile `src` through the in-browser mahina
 * frontend (the wasm `check` entry — it does NOT run the program) and return its
 * diagnostics. Drives the editor's live linter. A transient wasm error yields no
 * diagnostics rather than spamming squiggles. Wasm access stays funnelled through
 * the store (the editor never touches the module directly — Rule #9).
 */
export async function checkSource(src: string): Promise<MahinaDiagnostic[]> {
  try {
    return await mahinaWorker().check(src);
  } catch {
    return [];
  }
}

/** Decode a wasm run's recorded trace and push it + stdout into the store. The
 *  trace flows into the existing views exactly as a loaded .mahinatrace would. */
function applyWasmResult(result: MahinaRunResult, fileName: string, ran: RunInput): void {
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
  const runFiles = resolveRunFiles(result.chunks, ran.entry, ran.source, ran.files);
  const errorFile = runFileIn(runFiles, result.errorProtoId);
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
      ? { path: errorFile?.path ?? ran.entry, line: result.errorLine, start: result.errorStart, end: result.errorEnd }
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
    replaySource: ran.source,
    runFiles,
    // A read-only tab of the previous run may be gone now.
    activePath: state.files.some((f) => f.path === state.activePath) || runFiles.some((f) => f.path === state.activePath)
      ? state.activePath
      : state.entryPath,
    safepointCount: result.safepointCount,
    safepointCapped: result.safepointCapped,
    safepointLines: result.safepointLines,
    safepointProtos: result.safepointProtos,
    safepointStoppable: result.safepointStoppable,
    safepointNested: countUnstoppable(result.safepointStoppable),
    replayStops: [],
    replayPos: 0,
    replayState: null,
    replayView: null,
    replayBaseGlobals: null,
    disasm: result.disasm,
    execLogs,
    execLogsRecorded: true,
    traceExecPos: 0,
    coverage,
    tracesFromRun: true,
    irHoverLoc: null,
    irPinnedLoc: null,
  });
}

/** What a run was given: the entry's path and text, and every file. */
interface RunInput {
  entry: string;
  source: string;
  files: SourceFile[];
}

/** Snapshot the program for a run. */
function runInput(): RunInput {
  return { entry: state.entryPath, source: entrySource(), files: state.files.map((f) => ({ path: f.path, text: f.text })) };
}

/** The run file chunk `protoId` belongs to in `runFiles`, or null. Pure. */
function runFileIn(runFiles: readonly RunFile[], protoId: number): RunFile | null {
  for (const f of runFiles) {
    if (protoId >= f.firstProtoId && protoId - f.firstProtoId < f.protoCount) return f;
  }
  return null;
}

/** The last run's file that proto `protoId` was compiled from, or null. */
export function runFileOf(protoId: number): RunFile | null {
  return runFileIn(state.runFiles, protoId);
}

/** Whether lines of the last run still name lines of tab `path`: it's one of
 *  the run's read-only chunks, or a workspace file whose text is unchanged
 *  since the run. */
export function fileMapped(path: string): boolean {
  const rf = state.runFiles.find((f) => f.path === path);
  if (rf === undefined) return false;
  return rf.virtual || workspaceFile(path)?.text === rf.text;
}

/** Where `line` of proto `protoId` is, if the last run's lines still apply
 *  to that file (`fileMapped`); null otherwise or for line 0. */
export function locOf(protoId: number, line: number): Loc | null {
  if (line <= 0) return null;
  const rf = runFileOf(protoId);
  if (rf === null || !fileMapped(rf.path)) return null;
  return { path: rf.path, line };
}

/** A place as the UI writes it: `line N` in the entry file, else
 *  `path:N`. */
export function locLabel(loc: Loc): string {
  return loc.path === state.entryPath ? `line ${loc.line}` : `${loc.path}:${loc.line}`;
}

/** Show `loc`'s file in the editor and scroll it to the line. */
export function revealLoc(loc: Loc): void {
  setActivePath(loc.path);
  setState({ revealTarget: loc, revealSeq: state.revealSeq + 1 });
}

/** A stable small number per file of the last run (its first chunk's index),
 *  for telling files apart in the safepoint index. */
function fileKeyOf(protoId: number): number {
  const rf = runFileOf(protoId);
  return rf === null ? -1 : state.runFiles.findIndex((f) => f.path === rf.path);
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
  const stops = buildStops(state.grain, stepIndex(), memoFileKey());
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
  const stops = buildStops(grain, stepIndex(), memoFileKey());
  let pos = 0;
  for (let i = 0; i < stops.length; i++) {
    if (stops[i] <= curK) pos = i;
    else break;
  }
  setState({ grain, replayStops: stops });
  setReplayPos(pos);
}

/** `fileKeyOf`, memoized per proto: the index has a row per step, the program
 *  only a few protos. */
function memoFileKey(): (protoId: number) => number {
  const memo = new Map<number, number>();
  return (id) => {
    let k = memo.get(id);
    if (k === undefined) {
      k = fileKeyOf(id);
      memo.set(id, k);
    }
    return k;
  };
}

/** Where the replay is paused: the file and line of the pending instruction,
 *  or null when finished, unavailable, or the file was edited since the run. */
export function replayLoc(): Loc | null {
  const rs = state.replayState;
  if (!state.replayActive || rs === null || rs.finished) return null;
  return locOf(rs.protoId, rs.currentLine);
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
  // The position moves now, so quick steps (held arrow key, fast clicks) add
  // up instead of each starting from a position whose replay hasn't returned;
  // only the newest request's state is applied.
  setState("replayPos", clamped);
  const req = ++replayRequest;
  void (async () => {
    try {
      const rs = await mahinaWorker().replay(state.replaySource, state.replayEffects!, k);
      if (req !== replayRequest) return;
      const view = decodeSnapshot(rs.keyframe);
      setState({ replayState: rs, replayView: view });
      // Follow the step into whichever file it is in, like a debugger.
      const loc = replayLoc();
      if (loc !== null && loc.path !== state.activePath) setActivePath(loc.path);
      // Step 1 is before the program's first line: its globals are the builtins.
      if (k === 1 && state.replayBaseGlobals === null && view !== null) {
        setState("replayBaseGlobals", view.globals.map(globalKey));
      }
    } catch (e) {
      if (req !== replayRequest) return;
      setState({
        replayState: null,
        replayView: null,
        runError: e instanceof Error ? e.message : String(e),
      });
    }
  })();
}

/** Bumped by every `setReplayPos`; a replay result applies only if it is
 *  still the newest request's. */
let replayRequest = 0;

/** Identity of a global for the builtin filter: its name and displayed value,
 *  so a builtin the program reassigns (`print = myPrint`) shows up again. */
function globalKey(g: NamedValue): string {
  return `${g.label}\u0000${g.value}`;
}

/** The globals list to show at the current step and how many builtins it
 *  hides: every global, or (by default) those that differ from step 1's.
 *  Pure, so it's unit-testable. */
export function visibleGlobals(
  globals: readonly NamedValue[],
  base: readonly string[] | null,
  showBuiltins: boolean,
): { shown: NamedValue[]; hidden: number } {
  if (showBuiltins || base === null) return { shown: [...globals], hidden: 0 };
  const builtin = new Set(base);
  const shown = globals.filter((g) => !builtin.has(globalKey(g)));
  return { shown, hidden: globals.length - shown.length };
}

/** Show or hide the builtin globals in the replay panel. */
export function setShowBuiltinGlobals(show: boolean): void {
  setState("showBuiltinGlobals", show);
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
  runAbort = new AbortController();
  try {
    const ran = runInput();
    const result = await mahinaWorker().runSource(ran.source, wasmArgv(), ran.files);
    applyWasmResult(result, "(wasm run)", ran);
    // A wasm-only run has no cycle counter — drop any prior native time split so
    // the panel's time column reverts to "run native".
    setState({ running: false, nativeCoverage: null });
  } catch (e) {
    setState({ running: false, runError: runFailureText(e) });
  } finally {
    runAbort = null;
  }
}

/** Cancels the in-flight run's native request (`runBoth`); null when idle. */
let runAbort: AbortController | null = null;

/** Stop the in-flight run (the Stop button): terminate the wasm worker, which
 *  can't otherwise be interrupted mid-program, and abandon the native request.
 *  The run's own catch then reports it stopped. No-op when idle. */
export function stopRun(): void {
  if (!state.running) return;
  runAbort?.abort();
  mahinaWorker().stop();
}

/** The message for a run that threw: a plain "stopped" for Stop, else the error. */
function runFailureText(e: unknown): string {
  if (e instanceof StoppedError || (e instanceof DOMException && e.name === "AbortError")) {
    return "stopped (Stop pressed before the program finished)";
  }
  return e instanceof Error ? e.message : String(e);
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
  runAbort = new AbortController();
  const signal = runAbort.signal;
  try {
    const ran = runInput();
    // wasm gets `[entryPath, ...userArgs]`; native gets the raw userArgs and
    // prepends the temp source path as its own arg[0]. Both see the same
    // arg[1..], which is what the keyframe compare requires (arg[0] is cancelled).
    const userArgs = parseArgsString(state.scriptArgs);
    const [wasm, native] = await Promise.all([
      mahinaWorker().runSource(ran.source, wasmArgv(), ran.files),
      runNative(ran.files, ran.entry, userArgs, signal),
    ]);
    applyWasmResult(wasm, "(wasm + native diff)", ran);
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
    // One side failing (or Stop) leaves the other running: stop it too, so
    // a runaway wasm half doesn't keep the worker busy behind a native error.
    if (state.running) mahinaWorker().stop();
    setState({ running: false, runError: runFailureText(e) });
  } finally {
    runAbort = null;
  }
}

/** Decode a `.mahinatrace` buffer and replace the current view. */
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
      sourceError: null,
      // A loaded .mahinatrace carries no coverage or execution logs — drop the
      // last run's, which describe other traces.
      coverage: null,
      nativeCoverage: null,
      execLogs: [],
      execLogsRecorded: false,
      traceExecPos: 0,
      tracesFromRun: false,
      irHoverLoc: null,
      irPinnedLoc: null,
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
 * Fetch a `.mahinatrace` from a URL and load it. Powers the deep-link affordance
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

/** A program as `mahina viz <file>` serves it at `GET /project`: the entry's
 *  path and every file of its directory tree it found (paths relative to that
 *  directory), plus why the list is incomplete, if it is. */
export interface ProjectPayload {
  entry: string;
  files: SourceFile[];
  truncated?: string;
}

/** Decode a `/project` payload into the program it holds: paths normalized,
 *  files that don't normalize dropped. Throws when the entry isn't among the
 *  files. Pure. */
export function projectWorkspace(p: ProjectPayload): { files: SourceFile[]; entry: string } {
  const files: SourceFile[] = [];
  for (const f of p.files) {
    const path = normalizePath(f.path);
    if (path !== null && !files.some((g) => g.path === path)) files.push({ path, text: f.text });
  }
  const entry = normalizePath(p.entry);
  if (entry === null || !files.some((f) => f.path === entry)) throw new Error(`project entry ${p.entry} is not among its files`);
  return { files, entry };
}

/** Fetch a program from `url` (`mahina viz <file>` serves `/project`) and open
 *  it in the editor, replacing the current one. Doesn't run it. */
export async function loadProjectFromUrl(url: string): Promise<void> {
  try {
    const resp = await fetch(url);
    if (!resp.ok) throw new Error(`fetch ${url}: ${resp.status} ${resp.statusText}`);
    const payload = (await resp.json()) as ProjectPayload;
    const { files, entry } = projectWorkspace(payload);
    replaceWorkspace(files, entry);
    if (payload.truncated) setState("sourceError", payload.truncated);
  } catch (e) {
    setState("sourceError", e instanceof Error ? e.message : String(e));
  }
}

/** A backtrace frame as the UI writes it: `name:line` in the entry file, else
 *  `name (path:line)`. */
export function frameLabel(f: BacktraceFrame): string {
  const path = runFileOf(f.protoId)?.path ?? state.entryPath;
  return path === state.entryPath ? `${f.name}:${f.line}` : `${f.name} (${path}:${f.line})`;
}

export function selectTrace(index: number): void {
  // A new selection resets the animation to the start of that trace's stream.
  setState({ selected: index, traceExecPos: 0, irHoverLoc: null, irPinnedLoc: null });
}

/** The source line of bytecode `sp`, via the disassembly of the same compile
 *  (`disasm[proto].instrs[pc].line`); 0 when unknown. Pure. */
export function sourceLineOf(disasm: ProtoDisasm[], sp: SourcePoint | null): number {
  if (sp === null) return 0;
  const proto = disasm.find((p) => p.id === sp.protoId);
  return proto?.instrs[sp.pc]?.line ?? 0;
}

/** Where a trace instruction (or anchor) was recorded from, or null when it
 *  has no place, the traces aren't the last run's (a loaded `.mahinatrace`'s
 *  protos are another compile's), or its file changed since the run. */
export function traceLoc(sp: SourcePoint | null): Loc | null {
  if (!state.tracesFromRun || sp === null) return null;
  return locOf(sp.protoId, sourceLineOf(state.disasm, sp));
}

/** Two places are the same line of the same file. */
export function sameLoc(a: Loc | null, b: Loc | null): boolean {
  return a !== null && b !== null && a.path === b.path && a.line === b.line;
}

/** The IR row under the pointer is from `loc` (null clears). */
export function hoverIrLoc(loc: Loc | null): void {
  setState("irHoverLoc", loc);
}

/** An IR row from `loc` was clicked: keep its line marked in the editor, and
 *  show and scroll to it. */
export function pinIrLoc(loc: Loc): void {
  setState("irPinnedLoc", loc);
  revealLoc(loc);
}

/** The editor cursor moved to `line` of the active tab (by the user). */
export function setEditorCursorLine(line: number): void {
  const loc = { path: state.activePath, line };
  if (!sameLoc(state.editorCursor, loc)) setState("editorCursor", loc);
}

/** The currently-selected trace view, or null. */
export function selectedTrace(): TraceView | null {
  return state.selected >= 0 ? state.traces[state.selected] ?? null : null;
}

/** The execution log for the currently-selected trace, or null. Joined by the
 *  stable trace id (`trace_id` === `TraceView.id`), never by list position.
 *  Null when the selected trace never executed (not hot enough). */
export function selectedTraceExec(): TraceExecLogOutput | null {
  return execLogFor(selectedTrace(), state.execLogs);
}

/** Pure join behind `selectedTraceExec`: the log whose `trace_id` is `t.id`. */
export function execLogFor(
  t: Pick<TraceView, "id"> | null,
  logs: readonly TraceExecLogOutput[],
): TraceExecLogOutput | null {
  if (!t) return null;
  return logs.find((l) => l.trace_id === t.id) ?? null;
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
      e = { cls: "uncovered", native: 0, warmup: 0, coveredInterp: 0, uncovered: 0 };
      map.set(line, e);
    }
    // Iteration counts are exact small integers here (back-edge tallies); Number
    // is lossless well past any realistic loop-trip count.
    e.native += Number(a.traced_iters);
    if (a.has_trace !== 0) {
      const fallback = Number(a.fallback_iters);
      e.coveredInterp += fallback;
      e.warmup += Number(a.interp_iters) - fallback;
    } else e.uncovered += Number(a.interp_iters);
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

/** The time-weighted coverage split, in TSC cycles, real nanoseconds, and
 *  percentage of the whole run. The three loop buckets mirror the iteration split;
 *  `other` is non-loop time (call overhead, allocation, the parts that never hit a
 *  back-edge). The `*Ns` fields convert the cycle counts to wall time via the run's
 *  measured `run_nanos / run_cycles` (the effective clock), so the UI can show a
 *  real time unit — cycles are a count, not a duration. `runNanos` is the whole-run
 *  wall time; 0 if the artifact carried cycles but no wall clock (shouldn't happen
 *  for a native run, but the `*Ns` fields are then all 0). */
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
  runNanos: number;
  nativeNs: number;
  coveredInterpNs: number;
  uncoveredNs: number;
  otherNs: number;
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
  // Convert cycles → real nanoseconds via the measured effective clock
  // (`run_nanos / run_cycles`). Guard `run_nanos == 0` (no wall clock) → 0 ns.
  const runNanos = Number(cov.run_nanos);
  const ns = (cycles: number): number => (runNanos > 0 ? (cycles / run) * runNanos : 0);
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
    runNanos,
    nativeNs: ns(native),
    coveredInterpNs: ns(coveredInterp),
    uncoveredNs: ns(uncovered),
    otherNs: ns(other),
  };
}

/** The honest native time split from the last "Run both" (store wrapper over
 *  {@link timeSplitOf}). Null on a wasm-only run — the panel then grays the time
 *  column and prompts "run native". */
export function nativeTimeSplit(): CoverageTimeSplit | null {
  return state.nativeCoverage ? timeSplitOf(state.nativeCoverage) : null;
}

/** Resolve the last run's per-anchor coverage to the lines of file `path`
 *  (store wrapper over {@link resolveCoverageLines}). Empty when there's no
 *  coverage or the file changed since the run. */
export function coverageLinesOf(path: string): Map<number, LineCoverage> {
  const cov = state.coverage;
  if (cov === null || !fileMapped(path)) return new Map();
  const anchors = cov.anchors.filter((a) => runFileOf(a.proto_id)?.path === path);
  return resolveCoverageLines(anchors, state.disasm);
}

/** Whether the editor is showing coverage stripes: the last run produced
 *  per-line coverage for the active tab and it is unchanged since the run (an
 *  edit clears the stripes). Gates the stripe legend. */
export function coverageStripesShown(): boolean {
  return coverageLinesOf(state.activePath).size > 0;
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
