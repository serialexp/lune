// Loader + typed surface for the in-browser mahina VM (src/wasm_entry.zig, built
// by `zig build wasm`). This is the one place the app touches the wasm C-ABI;
// everything above it works in terms of `MahinaRunResult` (decoded with the
// existing binschema decoders — no new parsing here).
//
// The same module runs the script in-browser that the native binary runs on
// disk; the dual-execution differential validator (Phase 7 v3, Commit 3) asserts
// the two produce byte-identical artifacts for deterministic programs.

/** Raw C-ABI exports of the wasm module. wasm32 ⇒ every pointer is a u32. */
interface MahinaExports {
  memory: WebAssembly.Memory;
  mahina_alloc(len: number): number;
  mahina_free(ptr: number, len: number): void;
  mahina_run(srcPtr: number, srcLen: number, argsPtr: number, argsLen: number, filesPtr: number, filesLen: number): number;
  mahina_free_result(resPtr: number): void;
  mahina_check(srcPtr: number, srcLen: number): number;
  mahina_free_check_result(resPtr: number): void;
  mahina_replay(srcPtr: number, srcLen: number, effPtr: number, effLen: number, stopAfter: number): number;
  mahina_free_replay_result(resPtr: number): void;
  mahina_dispatch_smoke(iterations: number): number;
  mahina_panic_message_ptr(): number;
  mahina_panic_message_len(): number;
}

/** The VM panicked (a bug in mahina, not in the program): wasm trapped, with
 *  the panic's message. The instance's memory is left mid-operation, so every
 *  later call on it throws this too; load a fresh module. */
export class MahinaTrapError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options);
    this.name = "MahinaTrapError";
  }
}

/** The artifacts of one in-browser run. Byte buffers are copies out of linear
 *  memory (the wasm-side originals are freed before this returns). */
export interface MahinaRunResult {
  /** 0 = ran to completion, 1 = parse/compile/runtime error (see `diagnostics`). */
  status: number;
  /** The program's `print` output (tab/newline formatted), exactly as native. */
  stdout: string;
  /** Human-readable diagnostics / error text (empty on success). */
  diagnostics: string;
  /** binschema keyframe snapshot (the reachable heap graph + roots). */
  keyframe: Uint8Array;
  /** binschema effect log (recorded nondeterministic inputs, e.g. clock()). */
  effects: Uint8Array;
  /** binschema trace cache (recorded hot loops). */
  trace: Uint8Array;
  /** 1-based source line of a runtime error (0 = no located runtime error).
   *  Set only on a run failure with a faulting frame; parse/compile errors
   *  leave it 0 (their spans come through `check`). */
  errorLine: number;
  /** The proto `errorLine` is in, which names its file (see `chunks`). */
  errorProtoId: number;
  /** UTF-8 byte offsets [start,end) of the faulting span, for an editor
   *  squiggle. Both 0 when there's no located runtime error. */
  errorStart: number;
  errorEnd: number;
  /** The runtime-error call chain, deepest-first (leaf at index 0). Empty when
   *  the run succeeded or the error had no locatable frame. `[0]` mirrors
   *  `errorLine`/`errorStart`/`errorEnd`. */
  backtrace: BacktraceFrame[];
  /** VM-execute-only time in milliseconds (the `vm.run` call alone, measured
   *  inside wasm via the host clock — excludes parse/compile + serialization). */
  execMs: number;
  /** Total wall-clock for the whole `mahina_run` wasm call in milliseconds
   *  (parse + compile + execute + artifact serialization), measured in JS. */
  totalMs: number;
  /** Total instruction-boundary safepoint count of a pure tier-0 replay of this
   *  run — the step-debugger's step count. 0 ⇒ no replay available (e.g. the run
   *  failed). */
  safepointCount: number;
  /** True if the replay index hit the safepoint cap before the program finished
   *  (stepping is bounded to `safepointCount` steps — surfaced, never silent). */
  safepointCapped: boolean;
  /** Line-per-safepoint index: entry k is the 1-based source line of the
   *  instruction pending at safepoint k+1. Length == `safepointCount`. Drives
   *  line-grain stepping (slider over the indices where the line changes). */
  safepointLines: Uint32Array;
  /** Parallel to `safepointLines`: the proto each line is in, which names its
   *  file (see `chunks`). */
  safepointProtos: Uint32Array;
  /** Every chunk the run compiled: entry 0 is the program, the rest what
   *  `require`/`loadfile`/`dofile`/`load` compiled, in load order. Names the
   *  file of any proto id. Empty when the run never got to execute. */
  chunks: RunChunk[];
  /** Static disassembly of every proto in the program, indexed by `id` (use the
   *  replay cursor's `protoId`). Empty when the disassembly couldn't be built.
   *  Drives the step-replay panel's bytecode view. */
  disasm: ProtoDisasm[];
  /** binschema trace execution log (per cached trace: the recorded entries /
   *  exit-ramps and their per-iteration events). Empty when no trace executed.
   *  Drives the JIT-trace iteration animation in the trace view. */
  executionLog: Uint8Array;
  /** binschema JIT execution-coverage artifact (`CoverageFile`): the aggregate
   *  native-vs-tier-0 split, event counters, and per-anchor breakdown. Time
   *  attribution is n/a under wasm (no rdtsc), so only iteration counts are
   *  populated. Empty only on a run that never reached a back-edge. Drives the
   *  coverage view. */
  coverage: Uint8Array;
}

/** One compiled chunk of a run: the proto ids `[firstProtoId, firstProtoId +
 *  protoCount)` are its functions. */
export interface RunChunk {
  firstProtoId: number;
  protoCount: number;
  /** The chunk name: the path `require`/`loadfile`/`dofile` read (as the
   *  program spelled it, e.g. `./mod.mah`), else `load`'s chunkname. Empty
   *  for entry 0, the program itself. */
  name: string;
  /** The text it was compiled from. Empty for entry 0 (the caller has it). */
  source: string;
}

/** A file the program can `require`/`loadfile`/`dofile`, by its path relative
 *  to the program's directory. */
export interface SourceFile {
  path: string;
  text: string;
}

/** The disassembly of one function prototype (a node in the proto tree). */
export interface ProtoDisasm {
  /** Stable compile-time id; matches `MahinaReplayResult.protoId`. */
  id: number;
  /** Debug name (`"main"` for the top-level chunk). */
  name: string;
  /** Declared fixed parameter count. */
  numParams: number;
  /** Register slots the frame reserves. */
  numRegisters: number;
  /** One row per instruction, in `pc` order. */
  instrs: DisasmInstr[];
}

/** One disassembled instruction row. */
export interface DisasmInstr {
  /** 1-based source line of this instruction (0 if no span). */
  line: number;
  /** Rendered columnar text (op + operands), from `bytecode.writeInstr`. */
  text: string;
}

/** The VM state at one replay step (see `MahinaModule.replay`). */
export interface MahinaReplayResult {
  /** 0 = ok (suspended at the step, or finished), 1 = error (see `diagnostics`). */
  status: number;
  /** Program output accumulated up to this step. */
  stdout: string;
  /** Error text, empty unless `status === 1`. */
  diagnostics: string;
  /** Whole-VM keyframe snapshot AT this step (decode with `decodeSnapshot`). */
  keyframe: Uint8Array;
  /** 1-based source line of the instruction pending at this step (0 when finished). */
  currentLine: number;
  /** UTF-8 byte span [start,end) of that pending instruction (editor highlight). */
  currentStart: number;
  currentEnd: number;
  /** Live call depth at this step. */
  depth: number;
  /** True if the program completed before reaching the requested step. */
  finished: boolean;
  /** Deepest-first call chain at this step (empty when finished). */
  backtrace: BacktraceFrame[];
  /** Replay cursor: the `Proto.id` of the innermost live frame (index into
   *  `MahinaRunResult.disasm` by `id`). 0 when finished/unavailable. */
  protoId: number;
  /** Index of the pending instruction within that proto's `instrs`. 0 when
   *  finished/unavailable. */
  pc: number;
}

/** One row of a runtime-error backtrace. `start`/`end` are UTF-8 byte offsets. */
export interface BacktraceFrame {
  /** Function name (`"main"` for the top-level chunk). */
  name: string;
  /** The frame's proto, which names its file (see `MahinaRunResult.chunks`). */
  protoId: number;
  /** 1-based source line of this frame's active instruction. */
  line: number;
  start: number;
  end: number;
}

/** One compile diagnostic from `check` (parse/compile only — no execution). The
 *  `start`/`end` are UTF-8 *byte* offsets into the source (the mahina frontend's
 *  native unit); callers targeting a UTF-16 editor must convert. */
export interface MahinaDiagnostic {
  severity: "error" | "warning";
  /** Byte offset of the span start (inclusive). */
  start: number;
  /** Byte offset of the span end (exclusive). */
  end: number;
  /** 1-based line of `start`. */
  line: number;
  message: string;
}

/** A ready-to-use VM instance. */
export interface MahinaModule {
  /** Parse, compile, and run a source chunk; returns its artifacts. `argv`, when
   *  given, fills the global `arg` table (`argv[0]` = script name, `argv[1..]` =
   *  user args) exactly as the CLI does — so a script reading `arg[1]` (e.g.
   *  nsieve's workload size) sees it. Omitted/empty ⇒ `arg` stays an empty table.
   *  `files` are what `require`/`loadfile`/`dofile` can read. */
  runSource(src: string, argv?: string[], files?: SourceFile[]): MahinaRunResult;
  /** Parse + compile a source chunk and return its diagnostics WITHOUT running
   *  it — the editor's live linter. An empty array means a clean compile. */
  check(src: string): MahinaDiagnostic[];
  /** Replay `src` forward to instruction-boundary safepoint `stopAfter`, feeding
   *  the recorded `effects` blob (from a prior `runSource`) back deterministically,
   *  and return the VM state there. Re-running to the same `stopAfter` yields
   *  identical state every time (the deterministic-replay payoff). */
  replay(src: string, effects: Uint8Array, stopAfter: number): MahinaReplayResult;
  /** The guaranteed-tail-call capability gate: run `iterations` `.always_tail`
   *  hops and return the accumulator (== `iterations` iff frames were reused). */
  dispatchSmoke(iterations: number): number;
}

// Result struct layout (extern struct in wasm_entry.zig), little-endian:
//   u32 status; then 5 × { u32 ptr; u32 len } for stdout/keyframe/effects/trace/diag;
//   then 3 × u32 error_line/error_start/error_end (runtime-error location);
//   then { u32 ptr; u32 len } backtrace (structured call-chain blob, at offset 56);
//   then u64 exec_ns (VM-execute-only nanoseconds, at offset 64);
//   then u32 safepoint_count (@72), u32 safepoint_capped (@76);
//   then { u32 ptr; u32 len } safepoint_lines (line-per-safepoint blob, @80);
//   then { u32 ptr; u32 len } disasm (static bytecode blob, @88);
//   then { u32 ptr; u32 len } exec_log (trace execution-log blob, @96);
//   then { u32 ptr; u32 len } coverage (JIT coverage blob, @104);
//   then { u32 ptr; u32 len } chunks (the chunk table, @112);
//   then u32 error_proto_id (@120). 124 bytes read (128 with the u64's padding).
const RESULT_BYTES = 4 + 5 * 8 + 3 * 4 + 8 + 8 + 4 + 4 + 8 + 8 + 8 + 8 + 8 + 4;

// ReplayResult struct layout (extern struct), little-endian:
//   u32 status; { u32 ptr; u32 len } stdout/keyframe/diag; u32 current_line (@28),
//   current_start (@32), current_end (@36), depth (@40), finished (@44);
//   { u32 ptr; u32 len } backtrace (@48); u32 proto_id (@56), u32 pc (@60).
//   Total 64 bytes.
const REPLAY_RESULT_BYTES = 4 + 3 * 8 + 5 * 4 + 8 + 4 + 4;

// CheckResult layout: u32 status; { u32 ptr; u32 len } diags (len = record count).
const CHECK_RESULT_BYTES = 4 + 8;
// Diag record layout: u32 severity, start, end, line; { u32 ptr; u32 len } msg.
const DIAG_BYTES = 4 * 4 + 8;

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** Pack an argv into the blob `mahina_run` decodes (see `parseArgv` in
 *  wasm_entry.zig): little-endian `u32 count`, then per arg `{ u32 len; utf8 }`.
 *  Empty argv → empty blob (the caller then passes len 0 and the VM leaves `arg`
 *  an empty table). */
function encodeArgv(argv: string[]): Uint8Array {
  return encodeRecords(argv.length, argv);
}

/** Pack the program's files into the blob `mahina_run` decodes (see
 *  `parseFiles` in wasm_entry.zig): `u32 count`, then per file `{ u32 len;
 *  utf8 path }{ u32 len; utf8 text }`. No files → empty blob. */
function encodeFiles(files: SourceFile[]): Uint8Array {
  return encodeRecords(files.length, files.flatMap((f) => [f.path, f.text]));
}

/** `u32 count`, then each field as `{ u32 len; utf8 }`. Count 0 → empty. */
function encodeRecords(count: number, fields: string[]): Uint8Array {
  if (count === 0) return new Uint8Array(0);
  const parts = fields.map((a) => encoder.encode(a));
  const total = 4 + parts.reduce((n, p) => n + 4 + p.length, 0);
  const buf = new Uint8Array(total);
  const dv = new DataView(buf.buffer);
  dv.setUint32(0, count, true);
  let off = 4;
  for (const p of parts) {
    dv.setUint32(off, p.length, true);
    off += 4;
    buf.set(p, off);
    off += p.length;
  }
  return buf;
}

/** Build the import object the module needs. `host_now_ns` and `host_random_seed`
 *  are the injected nondeterministic inputs that can cross into the VM. */
function imports(): WebAssembly.Imports {
  return {
    env: {
      // i64 result ⇒ JS must return a BigInt. Monotonic-ish nanoseconds.
      host_now_ns: (): bigint => BigInt(Math.round(performance.now() * 1e6)),
      // One nondeterministic 64-bit seed for the VM-owned PRNG. Two CSPRNG words
      // packed into an i64 (returned as a BigInt; the VM @bitCasts it to u64).
      host_random_seed: (): bigint => {
        const w = crypto.getRandomValues(new Uint32Array(2));
        return BigInt.asIntN(64, (BigInt(w[1]) << 32n) | BigInt(w[0]));
      },
    },
  };
}

/** Read a `{ptr,len}` pair at `off` and copy those bytes out of linear memory.
 *  Always re-reads `memory.buffer`: a prior `mahina_run` may have grown (and thus
 *  detached) the buffer. */
function readBuf(memory: WebAssembly.Memory, dv: DataView, off: number): Uint8Array {
  const ptr = dv.getUint32(off, true);
  const len = dv.getUint32(off + 4, true);
  if (ptr === 0 || len === 0) return new Uint8Array(0);
  return new Uint8Array(memory.buffer, ptr, len).slice();
}

/** Reinterpret a `{ptr,len}` byte blob of little-endian u32s as a `Uint32Array`.
 *  `readBuf` already copied the bytes into a fresh, zero-offset ArrayBuffer, so
 *  the view is safe and independent of wasm memory. Assumes a little-endian host
 *  (every browser/wasm target is). Empty blob → empty array. */
function readU32Array(blob: Uint8Array): Uint32Array {
  if (blob.length === 0) return new Uint32Array(0);
  return new Uint32Array(blob.buffer, blob.byteOffset, blob.length >>> 2);
}

/** Split the safepoint index blob (little-endian `{u32 proto_id, u32 line}`
 *  pairs, see `encodeSafepointLines` in wasm_entry.zig) into its two columns. */
function decodeSafepoints(blob: Uint8Array): { lines: Uint32Array; protos: Uint32Array } {
  const pairs = readU32Array(blob);
  const n = pairs.length >>> 1;
  const lines = new Uint32Array(n);
  const protos = new Uint32Array(n);
  for (let i = 0; i < n; i++) {
    protos[i] = pairs[2 * i];
    lines[i] = pairs[2 * i + 1];
  }
  return { lines, protos };
}

/** Decode the chunk table (see `buildChunksBlob` in wasm_entry.zig): `u32
 *  count`, then per chunk `{ u32 first_proto_id, u32 proto_count, u32
 *  name_len, name, u32 source_len, source }`. Empty → []. */
function decodeChunks(blob: Uint8Array): RunChunk[] {
  if (blob.length < 4) return [];
  const dv = new DataView(blob.buffer, blob.byteOffset, blob.byteLength);
  const count = dv.getUint32(0, true);
  const chunks: RunChunk[] = [];
  let off = 4;
  const str = (): string => {
    const len = dv.getUint32(off, true);
    off += 4;
    const s = decoder.decode(blob.subarray(off, off + len));
    off += len;
    return s;
  };
  for (let i = 0; i < count; i++) {
    const firstProtoId = dv.getUint32(off, true);
    const protoCount = dv.getUint32(off + 4, true);
    off += 8;
    const name = str();
    const source = str();
    chunks.push({ firstProtoId, protoCount, name, source });
  }
  return chunks;
}

/** Decode the structured backtrace blob (see `encodeBacktrace` in
 *  wasm_entry.zig): `u32 frame_count`, then per frame (deepest-first)
 *  `{ u32 proto_id, line, start, end, name_len, [name_len]u8 name }`. Empty → []. */
function decodeBacktrace(blob: Uint8Array): BacktraceFrame[] {
  if (blob.length < 4) return [];
  const dv = new DataView(blob.buffer, blob.byteOffset, blob.byteLength);
  const count = dv.getUint32(0, true);
  const frames: BacktraceFrame[] = [];
  let off = 4;
  for (let i = 0; i < count; i++) {
    const protoId = dv.getUint32(off, true);
    const line = dv.getUint32(off + 4, true);
    const start = dv.getUint32(off + 8, true);
    const end = dv.getUint32(off + 12, true);
    const nameLen = dv.getUint32(off + 16, true);
    off += 20;
    const name = decoder.decode(blob.subarray(off, off + nameLen));
    off += nameLen;
    frames.push({ name, protoId, line, start, end });
  }
  return frames;
}

/** Decode the static disassembly blob (see `buildDisasmBlob` in wasm_entry.zig):
 *  `u32 proto_count`, then per proto `{ u32 id, u32 name_len, [name_len]u8 name,
 *  u16 num_params, u16 num_registers, u32 instr_count }`, then per instruction
 *  `{ u32 line, u32 text_len, [text_len]u8 text }`. Empty → []. */
function decodeDisasm(blob: Uint8Array): ProtoDisasm[] {
  if (blob.length < 4) return [];
  const dv = new DataView(blob.buffer, blob.byteOffset, blob.byteLength);
  const protoCount = dv.getUint32(0, true);
  const protos: ProtoDisasm[] = [];
  let off = 4;
  for (let p = 0; p < protoCount; p++) {
    const id = dv.getUint32(off, true);
    const nameLen = dv.getUint32(off + 4, true);
    off += 8;
    const name = decoder.decode(blob.subarray(off, off + nameLen));
    off += nameLen;
    const numParams = dv.getUint16(off, true);
    const numRegisters = dv.getUint16(off + 2, true);
    const instrCount = dv.getUint32(off + 4, true);
    off += 8;
    const instrs: DisasmInstr[] = [];
    for (let i = 0; i < instrCount; i++) {
      const line = dv.getUint32(off, true);
      const textLen = dv.getUint32(off + 4, true);
      off += 8;
      const text = decoder.decode(blob.subarray(off, off + textLen));
      off += textLen;
      instrs.push({ line, text });
    }
    protos.push({ id, name, numParams, numRegisters, instrs });
  }
  return protos;
}

function wrap(exports: MahinaExports): MahinaModule {
  // Set by the first trap; the instance is unusable from then on.
  let trapped: string | null = null;
  const guarded = <A extends unknown[], R>(name: string, fn: (...args: A) => R) => (...args: A): R => {
    if (trapped !== null) throw new MahinaTrapError(`the in-browser VM crashed earlier (${trapped}); reload it`);
    try {
      return fn(...args);
    } catch (e) {
      if (!(e instanceof WebAssembly.RuntimeError)) throw e;
      const len = exports.mahina_panic_message_len();
      const msg = len === 0 ? e.message : decoder.decode(new Uint8Array(exports.memory.buffer, exports.mahina_panic_message_ptr(), len));
      trapped = msg;
      throw new MahinaTrapError(`mahina ${name} panicked: ${msg}`, { cause: e });
    }
  };

  const runSource = (src: string, argv: string[] = [], files: SourceFile[] = []): MahinaRunResult => {
    const bytes = encoder.encode(src);
    const srcPtr = bytes.length === 0 ? 0 : exports.mahina_alloc(bytes.length);
    if (bytes.length !== 0) {
      new Uint8Array(exports.memory.buffer, srcPtr, bytes.length).set(bytes);
    }
    // Pack argv AFTER writing the source. A grow here would detach the source
    // view, but the bytes are already in place and pointers survive as offsets
    // (same ordering discipline as `replay`'s src-then-effects alloc).
    const argsBlob = encodeArgv(argv);
    const argsPtr = argsBlob.length === 0 ? 0 : exports.mahina_alloc(argsBlob.length);
    if (argsBlob.length !== 0) {
      new Uint8Array(exports.memory.buffer, argsPtr, argsBlob.length).set(argsBlob);
    }
    const filesBlob = encodeFiles(files);
    const filesPtr = filesBlob.length === 0 ? 0 : exports.mahina_alloc(filesBlob.length);
    if (filesBlob.length !== 0) {
      new Uint8Array(exports.memory.buffer, filesPtr, filesBlob.length).set(filesBlob);
    }

    // Total wall-clock brackets the whole wasm call (parse + compile + execute +
    // artifact serialization). The execute-only subset comes back as `exec_ns`.
    const t0 = performance.now();
    const resPtr = exports.mahina_run(srcPtr, bytes.length, argsPtr, argsBlob.length, filesPtr, filesBlob.length);
    const totalMs = performance.now() - t0;
    if (srcPtr !== 0) exports.mahina_free(srcPtr, bytes.length);
    if (argsPtr !== 0) exports.mahina_free(argsPtr, argsBlob.length);
    if (filesPtr !== 0) exports.mahina_free(filesPtr, filesBlob.length);
    if (resPtr === 0) {
      throw new Error("mahina_run returned null (wasm allocation failure)");
    }

    // Re-acquire the view after the call — memory may have grown.
    const dv = new DataView(exports.memory.buffer, resPtr, RESULT_BYTES);
    const status = dv.getUint32(0, true);
    const stdout = readBuf(exports.memory, dv, 4);
    const keyframe = readBuf(exports.memory, dv, 12);
    const effects = readBuf(exports.memory, dv, 20);
    const trace = readBuf(exports.memory, dv, 28);
    const diag = readBuf(exports.memory, dv, 36);
    const errorLine = dv.getUint32(44, true);
    const errorStart = dv.getUint32(48, true);
    const errorEnd = dv.getUint32(52, true);
    const backtrace = decodeBacktrace(readBuf(exports.memory, dv, 56));
    const execMs = Number(dv.getBigUint64(64, true)) / 1e6;
    const safepointCount = dv.getUint32(72, true);
    const safepointCapped = dv.getUint32(76, true) !== 0;
    const safepoints = decodeSafepoints(readBuf(exports.memory, dv, 80));
    const disasm = decodeDisasm(readBuf(exports.memory, dv, 88));
    const executionLog = readBuf(exports.memory, dv, 96);
    const coverage = readBuf(exports.memory, dv, 104);
    const chunks = decodeChunks(readBuf(exports.memory, dv, 112));
    const errorProtoId = dv.getUint32(120, true);

    exports.mahina_free_result(resPtr);

    return {
      status,
      stdout: decoder.decode(stdout),
      diagnostics: decoder.decode(diag),
      keyframe,
      effects,
      trace,
      errorLine,
      errorProtoId,
      errorStart,
      errorEnd,
      backtrace,
      execMs,
      totalMs,
      safepointCount,
      safepointCapped,
      safepointLines: safepoints.lines,
      safepointProtos: safepoints.protos,
      chunks,
      disasm,
      executionLog,
      coverage,
    };
  };

  const replay = (src: string, effects: Uint8Array, stopAfter: number): MahinaReplayResult => {
    const srcBytes = encoder.encode(src);
    const srcPtr = srcBytes.length === 0 ? 0 : exports.mahina_alloc(srcBytes.length);
    if (srcBytes.length !== 0) {
      new Uint8Array(exports.memory.buffer, srcPtr, srcBytes.length).set(srcBytes);
    }
    // Allocate the effect blob AFTER the source (a grow here detaches the source
    // view, but we've already written it; pointers stay valid as offsets).
    const effPtr = effects.length === 0 ? 0 : exports.mahina_alloc(effects.length);
    if (effects.length !== 0) {
      new Uint8Array(exports.memory.buffer, effPtr, effects.length).set(effects);
    }

    const resPtr = exports.mahina_replay(srcPtr, srcBytes.length, effPtr, effects.length, stopAfter);
    if (srcPtr !== 0) exports.mahina_free(srcPtr, srcBytes.length);
    if (effPtr !== 0) exports.mahina_free(effPtr, effects.length);
    if (resPtr === 0) {
      throw new Error("mahina_replay returned null (wasm allocation failure)");
    }

    const dv = new DataView(exports.memory.buffer, resPtr, REPLAY_RESULT_BYTES);
    const status = dv.getUint32(0, true);
    const stdout = readBuf(exports.memory, dv, 4);
    const keyframe = readBuf(exports.memory, dv, 12);
    const diag = readBuf(exports.memory, dv, 20);
    const currentLine = dv.getUint32(28, true);
    const currentStart = dv.getUint32(32, true);
    const currentEnd = dv.getUint32(36, true);
    const depth = dv.getUint32(40, true);
    const finished = dv.getUint32(44, true) !== 0;
    const backtrace = decodeBacktrace(readBuf(exports.memory, dv, 48));
    const protoId = dv.getUint32(56, true);
    const pc = dv.getUint32(60, true);

    exports.mahina_free_replay_result(resPtr);

    return {
      status,
      stdout: decoder.decode(stdout),
      diagnostics: decoder.decode(diag),
      keyframe,
      currentLine,
      currentStart,
      currentEnd,
      depth,
      finished,
      backtrace,
      protoId,
      pc,
    };
  };

  const check = (src: string): MahinaDiagnostic[] => {
    const bytes = encoder.encode(src);
    const srcPtr = bytes.length === 0 ? 0 : exports.mahina_alloc(bytes.length);
    if (bytes.length !== 0) {
      new Uint8Array(exports.memory.buffer, srcPtr, bytes.length).set(bytes);
    }

    const resPtr = exports.mahina_check(srcPtr, bytes.length);
    if (srcPtr !== 0) exports.mahina_free(srcPtr, bytes.length);
    if (resPtr === 0) {
      throw new Error("mahina_check returned null (wasm allocation failure)");
    }

    // Re-acquire views after the call — memory may have grown.
    const head = new DataView(exports.memory.buffer, resPtr, CHECK_RESULT_BYTES);
    const diagsPtr = head.getUint32(4, true);
    const count = head.getUint32(8, true);

    const out: MahinaDiagnostic[] = [];
    for (let i = 0; i < count; i++) {
      const off = diagsPtr + i * DIAG_BYTES;
      const dv = new DataView(exports.memory.buffer, off, DIAG_BYTES);
      const severity = dv.getUint32(0, true);
      const start = dv.getUint32(4, true);
      const end = dv.getUint32(8, true);
      const line = dv.getUint32(12, true);
      const msg = readBuf(exports.memory, dv, 16);
      out.push({
        severity: severity === 0 ? "error" : "warning",
        start,
        end,
        line,
        message: decoder.decode(msg),
      });
    }

    exports.mahina_free_check_result(resPtr);
    return out;
  };

  return {
    runSource: guarded("run", runSource),
    check: guarded("check", check),
    replay: guarded("replay", replay),
    dispatchSmoke: guarded("dispatch smoke", (iterations: number) => exports.mahina_dispatch_smoke(iterations)),
  };
}

/** Instantiate from raw module bytes (used by tests, which read the `.wasm`
 *  from disk). */
export async function instantiateMahinaFromBytes(bytes: BufferSource): Promise<MahinaModule> {
  const { instance } = await WebAssembly.instantiate(bytes, imports());
  return wrap(instance.exports as unknown as MahinaExports);
}

/** Fetch and instantiate the module from a URL (used by the browser app). Falls
 *  back to a buffered instantiate when streaming compilation is unavailable
 *  (e.g. a dev server serving the wrong MIME type). */
export async function loadMahina(url: string): Promise<MahinaModule> {
  try {
    const { instance } = await WebAssembly.instantiateStreaming(fetch(url), imports());
    return wrap(instance.exports as unknown as MahinaExports);
  } catch {
    const resp = await fetch(url);
    if (!resp.ok) throw new Error(`fetch ${url}: ${resp.status} ${resp.statusText}`);
    const bytes = await resp.arrayBuffer();
    return instantiateMahinaFromBytes(bytes);
  }
}
