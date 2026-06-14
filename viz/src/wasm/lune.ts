// Loader + typed surface for the in-browser lune VM (src/wasm_entry.zig, built
// by `zig build wasm`). This is the one place the app touches the wasm C-ABI;
// everything above it works in terms of `LuneRunResult` (decoded with the
// existing binschema decoders — no new parsing here).
//
// The same module runs the script in-browser that the native binary runs on
// disk; the dual-execution differential validator (Phase 7 v3, Commit 3) asserts
// the two produce byte-identical artifacts for deterministic programs.

/** Raw C-ABI exports of the wasm module. wasm32 ⇒ every pointer is a u32. */
interface LuneExports {
  memory: WebAssembly.Memory;
  lune_alloc(len: number): number;
  lune_free(ptr: number, len: number): void;
  lune_run(srcPtr: number, srcLen: number): number;
  lune_free_result(resPtr: number): void;
  lune_check(srcPtr: number, srcLen: number): number;
  lune_free_check_result(resPtr: number): void;
  lune_dispatch_smoke(iterations: number): number;
}

/** The artifacts of one in-browser run. Byte buffers are copies out of linear
 *  memory (the wasm-side originals are freed before this returns). */
export interface LuneRunResult {
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
  /** UTF-8 byte offsets [start,end) of the faulting span, for an editor
   *  squiggle. Both 0 when there's no located runtime error. */
  errorStart: number;
  errorEnd: number;
}

/** One compile diagnostic from `check` (parse/compile only — no execution). The
 *  `start`/`end` are UTF-8 *byte* offsets into the source (the lune frontend's
 *  native unit); callers targeting a UTF-16 editor must convert. */
export interface LuneDiagnostic {
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
export interface LuneModule {
  /** Parse, compile, and run a source chunk; returns its artifacts. */
  runSource(src: string): LuneRunResult;
  /** Parse + compile a source chunk and return its diagnostics WITHOUT running
   *  it — the editor's live linter. An empty array means a clean compile. */
  check(src: string): LuneDiagnostic[];
  /** The guaranteed-tail-call capability gate: run `iterations` `.always_tail`
   *  hops and return the accumulator (== `iterations` iff frames were reused). */
  dispatchSmoke(iterations: number): number;
}

// Result struct layout (extern struct in wasm_entry.zig), little-endian:
//   u32 status; then 5 × { u32 ptr; u32 len } for stdout/keyframe/effects/trace/diag;
//   then 3 × u32 error_line/error_start/error_end (runtime-error location).
const RESULT_BYTES = 4 + 5 * 8 + 3 * 4;

// CheckResult layout: u32 status; { u32 ptr; u32 len } diags (len = record count).
const CHECK_RESULT_BYTES = 4 + 8;
// Diag record layout: u32 severity, start, end, line; { u32 ptr; u32 len } msg.
const DIAG_BYTES = 4 * 4 + 8;

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** Build the import object the module needs. `host_now_ns` is the injected
 *  clock — the only nondeterministic input that can cross into the VM. */
function imports(): WebAssembly.Imports {
  return {
    env: {
      // i64 result ⇒ JS must return a BigInt. Monotonic-ish nanoseconds.
      host_now_ns: (): bigint => BigInt(Math.round(performance.now() * 1e6)),
    },
  };
}

/** Read a `{ptr,len}` pair at `off` and copy those bytes out of linear memory.
 *  Always re-reads `memory.buffer`: a prior `lune_run` may have grown (and thus
 *  detached) the buffer. */
function readBuf(memory: WebAssembly.Memory, dv: DataView, off: number): Uint8Array {
  const ptr = dv.getUint32(off, true);
  const len = dv.getUint32(off + 4, true);
  if (ptr === 0 || len === 0) return new Uint8Array(0);
  return new Uint8Array(memory.buffer, ptr, len).slice();
}

function wrap(exports: LuneExports): LuneModule {
  const runSource = (src: string): LuneRunResult => {
    const bytes = encoder.encode(src);
    const srcPtr = bytes.length === 0 ? 0 : exports.lune_alloc(bytes.length);
    if (bytes.length !== 0) {
      new Uint8Array(exports.memory.buffer, srcPtr, bytes.length).set(bytes);
    }

    const resPtr = exports.lune_run(srcPtr, bytes.length);
    if (srcPtr !== 0) exports.lune_free(srcPtr, bytes.length);
    if (resPtr === 0) {
      throw new Error("lune_run returned null (wasm allocation failure)");
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

    exports.lune_free_result(resPtr);

    return {
      status,
      stdout: decoder.decode(stdout),
      diagnostics: decoder.decode(diag),
      keyframe,
      effects,
      trace,
      errorLine,
      errorStart,
      errorEnd,
    };
  };

  const check = (src: string): LuneDiagnostic[] => {
    const bytes = encoder.encode(src);
    const srcPtr = bytes.length === 0 ? 0 : exports.lune_alloc(bytes.length);
    if (bytes.length !== 0) {
      new Uint8Array(exports.memory.buffer, srcPtr, bytes.length).set(bytes);
    }

    const resPtr = exports.lune_check(srcPtr, bytes.length);
    if (srcPtr !== 0) exports.lune_free(srcPtr, bytes.length);
    if (resPtr === 0) {
      throw new Error("lune_check returned null (wasm allocation failure)");
    }

    // Re-acquire views after the call — memory may have grown.
    const head = new DataView(exports.memory.buffer, resPtr, CHECK_RESULT_BYTES);
    const diagsPtr = head.getUint32(4, true);
    const count = head.getUint32(8, true);

    const out: LuneDiagnostic[] = [];
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

    exports.lune_free_check_result(resPtr);
    return out;
  };

  return {
    runSource,
    check,
    dispatchSmoke: (iterations: number) => exports.lune_dispatch_smoke(iterations),
  };
}

/** Instantiate from raw module bytes (used by tests, which read the `.wasm`
 *  from disk). */
export async function instantiateLuneFromBytes(bytes: BufferSource): Promise<LuneModule> {
  const { instance } = await WebAssembly.instantiate(bytes, imports());
  return wrap(instance.exports as unknown as LuneExports);
}

/** Fetch and instantiate the module from a URL (used by the browser app). Falls
 *  back to a buffered instantiate when streaming compilation is unavailable
 *  (e.g. a dev server serving the wrong MIME type). */
export async function loadLune(url: string): Promise<LuneModule> {
  try {
    const { instance } = await WebAssembly.instantiateStreaming(fetch(url), imports());
    return wrap(instance.exports as unknown as LuneExports);
  } catch {
    const resp = await fetch(url);
    if (!resp.ok) throw new Error(`fetch ${url}: ${resp.status} ${resp.statusText}`);
    const bytes = await resp.arrayBuffer();
    return instantiateLuneFromBytes(bytes);
  }
}
