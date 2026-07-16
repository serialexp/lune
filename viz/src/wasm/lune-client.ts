// Main-thread client for the lune Web Worker (`lune.worker.ts`). The store talks
// to the VM exclusively through this async surface, so no WASM call ever blocks
// the UI thread. It mirrors the synchronous `LuneModule` API — `runSource`,
// `check`, `replay` — but every method returns a Promise settled when the worker
// posts back its response.
//
// The worker is spawned LAZILY, on the first call, and never at module load: the
// bun test suite imports `store.ts` (which imports this) and must not touch
// `Worker`. Only a real run in the browser stands the worker up.

import type { LuneRunResult, LuneReplayResult, LuneDiagnostic } from "./lune";

interface Pending {
  resolve: (value: unknown) => void;
  reject: (reason: Error) => void;
}

type WorkerRes =
  | { id: number; ok: true; result: unknown }
  | { id: number; ok: false; error: string };

class LuneWorkerClient {
  #worker: Worker | null = null;
  #pending = new Map<number, Pending>();
  #nextId = 1;
  #initId: number | null = null;

  /** Resolve the wasm URL the way the old in-store loader did
   *  (`${BASE_URL}lune.wasm`), so dev and built bases both work. */
  #wasmUrl(): string {
    const base = import.meta.env?.BASE_URL ?? "./";
    return `${base}lune.wasm`;
  }

  /** Spawn the worker (once) and kick off instantiation. Idempotent. */
  #ensureWorker(): Worker {
    if (this.#worker !== null) return this.#worker;
    const w = new Worker(new URL("./lune.worker.ts", import.meta.url), { type: "module" });
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
      const err = new Error(ev.message || "lune worker error");
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

  runSource(src: string, argv: string[] = []): Promise<LuneRunResult> {
    return this.#call<LuneRunResult>({ method: "run", src, argv });
  }

  check(src: string): Promise<LuneDiagnostic[]> {
    return this.#call<LuneDiagnostic[]>({ method: "check", src });
  }

  replay(src: string, effects: Uint8Array, stopAfter: number): Promise<LuneReplayResult> {
    // The effects blob is owned by the store (frozen for the whole replay
    // session), so DON'T transfer it — the worker gets a structured-clone copy.
    return this.#call<LuneReplayResult>({ method: "replay", src, effects, stopAfter });
  }
}

/** Lazily-constructed singleton, mirroring the old `lune()` helper. */
let client: LuneWorkerClient | null = null;
export function luneWorker(): LuneWorkerClient {
  if (client === null) client = new LuneWorkerClient();
  return client;
}
