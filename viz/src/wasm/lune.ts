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
}

/** A ready-to-use VM instance. */
export interface LuneModule {
  /** Parse, compile, and run a source chunk; returns its artifacts. */
  runSource(src: string): LuneRunResult;
  /** The guaranteed-tail-call capability gate: run `iterations` `.always_tail`
   *  hops and return the accumulator (== `iterations` iff frames were reused). */
  dispatchSmoke(iterations: number): number;
}

// Result struct layout (extern struct in wasm_entry.zig), little-endian:
//   u32 status; then 5 × { u32 ptr; u32 len } for stdout/keyframe/effects/trace/diag.
const RESULT_BYTES = 4 + 5 * 8;

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

    exports.lune_free_result(resPtr);

    return {
      status,
      stdout: decoder.decode(stdout),
      diagnostics: decoder.decode(diag),
      keyframe,
      effects,
      trace,
    };
  };

  return {
    runSource,
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
