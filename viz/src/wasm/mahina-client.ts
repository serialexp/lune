// Main-thread client for the mahina Web Worker (`mahina.worker.ts`). The store talks
// to the VM exclusively through this async surface, so no WASM call ever blocks
// the UI thread. It mirrors the synchronous `MahinaModule` API — `runSource`,
// `check`, `replay` — but every method returns a Promise settled when the worker
// posts back its response.
//
// The worker is spawned LAZILY, on the first call, and never at module load: the
// bun test suite imports `store.ts` (which imports this) and must not touch
// `Worker`. Only a real run in the browser stands the worker up.

import type { MahinaRunResult, MahinaReplayResult, MahinaDiagnostic, SourceFile } from "./mahina";

/** The wasm URL: `${base}mahina.wasm` resolved against the *page* URL to an
 *  absolute URL, so dev and built bases both work. It must be absolute before
 *  it reaches the worker: the built base is `./`, and the worker would resolve
 *  a relative URL against its own script (`/assets/…`), where there is no wasm
 *  — Run 404'd that way in `mahina viz`. */
export function resolveWasmUrl(base: string, pageUrl: string): string {
  return new URL(`${base}mahina.wasm`, pageUrl).href;
}

interface Pending {
  resolve: (value: unknown) => void;
  reject: (reason: Error) => void;
}

type WorkerRes =
  | { id: number; ok: true; result: unknown }
  | { id: number; ok: false; error: string };

class MahinaWorkerClient {
  #worker: Worker | null = null;
  #pending = new Map<number, Pending>();
  #nextId = 1;
  #initId: number | null = null;

  #wasmUrl(): string {
    return resolveWasmUrl(import.meta.env?.BASE_URL ?? "./", document.baseURI);
  }

  /** Spawn the worker (once) and kick off instantiation. Idempotent. */
  #ensureWorker(): Worker {
    if (this.#worker !== null) return this.#worker;
    const w = new Worker(new URL("./mahina.worker.ts", import.meta.url), { type: "module" });
    w.onmessage = (ev: MessageEvent<WorkerRes>) => {
      const { id } = ev.data;
      const p = this.#pending.get(id);
      if (p === undefined) return;
      this.#pending.delete(id);
      if (ev.data.ok) p.resolve(ev.data.result);
      else p.reject(new Error(ev.data.error));
    };
    w.onerror = (ev) => {
      // A worker-level failure (e.g. module load error) can't be tied to one
      // request — reject every in-flight call so callers don't hang.
      const err = new Error(ev.message || "mahina worker error");
      for (const [, p] of this.#pending) p.reject(err);
      this.#pending.clear();
    };
    this.#worker = w;
    // Fire the one-shot init that hands the worker its wasm URL. Its own promise
    // is tracked like any other request so a load failure surfaces.
    this.#initId = this.#nextId++;
    this.#send(this.#initId, { method: "init", url: this.#wasmUrl() });
    return w;
  }

  #send(id: number, msg: Record<string, unknown>, transfer: Transferable[] = []): void {
    this.#ensureWorker().postMessage({ id, ...msg }, transfer);
  }

  #call<T>(msg: Record<string, unknown>, transfer: Transferable[] = []): Promise<T> {
    this.#ensureWorker();
    const id = this.#nextId++;
    return new Promise<T>((resolve, reject) => {
      this.#pending.set(id, { resolve: resolve as (v: unknown) => void, reject });
      this.#send(id, msg, transfer);
    });
  }

  runSource(src: string, argv: string[] = [], files: SourceFile[] = []): Promise<MahinaRunResult> {
    return this.#call<MahinaRunResult>({ method: "run", src, argv, files });
  }

  check(src: string): Promise<MahinaDiagnostic[]> {
    return this.#call<MahinaDiagnostic[]>({ method: "check", src });
  }

  replay(src: string, effects: Uint8Array, stopAfter: number): Promise<MahinaReplayResult> {
    // The effects blob is owned by the store (frozen for the whole replay
    // session), so DON'T transfer it — the worker gets a structured-clone copy.
    return this.#call<MahinaReplayResult>({ method: "replay", src, effects, stopAfter });
  }

  /** Stop whatever the worker is doing (a runaway `while true do end`): the VM
   *  runs synchronously inside the worker and can't be interrupted, so the
   *  worker is terminated. Every in-flight call rejects with `StoppedError`;
   *  the next call spawns a fresh worker (the browser has the wasm cached). */
  stop(): void {
    if (this.#worker === null) return;
    this.#worker.terminate();
    this.#worker = null;
    this.#initId = null;
    const err = new StoppedError();
    for (const [, p] of this.#pending) p.reject(err);
    this.#pending.clear();
  }
}

/** The rejection of a call cut short by `stop()`. */
export class StoppedError extends Error {
  constructor() {
    super("stopped");
    this.name = "StoppedError";
  }
}

/** Lazily-constructed singleton, mirroring the old `mahina()` helper. */
let client: MahinaWorkerClient | null = null;
export function mahinaWorker(): MahinaWorkerClient {
  if (client === null) client = new MahinaWorkerClient();
  return client;
}
