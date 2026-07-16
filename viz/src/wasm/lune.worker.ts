// Web Worker host for the in-browser lune VM. The WASM module runs the script
// synchronously (it blocks whatever thread it's on), so the main thread must not
// be it — this worker owns the single module instance and answers run/check/
// replay requests over `postMessage`, keeping the SolidJS UI responsive during a
// run, a linter `check`, or a replay scrub.
//
// The wire protocol is a tiny request/response RPC (see `lune-client.ts` for the
// caller side). All artifacts already cross the structured-clone boundary
// cleanly: `readBuf` (`lune.ts`) copies every blob out of linear memory, and the
// result structs are plain data (strings, numbers, typed arrays, plain objects).

import { loadLune, type LuneModule, type LuneRunResult, type LuneReplayResult } from "./lune";

/** Request from the client. `init` must arrive (once) before any call; it carries
 *  the wasm URL to instantiate from. Each call carries a unique `id` the client
 *  matches the response to. */
type Req =
  | { id: number; method: "init"; url: string }
  | { id: number; method: "run"; src: string; argv: string[] }
  | { id: number; method: "check"; src: string }
  | { id: number; method: "replay"; src: string; effects: Uint8Array; stopAfter: number };

type Res =
  | { id: number; ok: true; result: unknown }
  | { id: number; ok: false; error: string };

// The single module instance, lazily created by the first `init`. Subsequent
// `init`s are idempotent (the client only sends one, but be defensive).
let modPromise: Promise<LuneModule> | null = null;

function ensureModule(url: string): Promise<LuneModule> {
  if (modPromise === null) modPromise = loadLune(url);
  return modPromise;
}

/** Collect the transferable `ArrayBuffer`s of a run result so structured clone
 *  moves (not copies) the artifact bytes back to the main thread. They're
 *  throwaway copies in the worker, so transferring ownership is safe. */
function runTransferables(r: LuneRunResult): Transferable[] {
  return [
    r.keyframe.buffer,
    r.effects.buffer,
    r.trace.buffer,
    r.safepointLines.buffer,
    r.executionLog.buffer,
    r.coverage.buffer,
  ] as Transferable[];
}

function replayTransferables(r: LuneReplayResult): Transferable[] {
  return [r.keyframe.buffer] as Transferable[];
}

self.onmessage = async (ev: MessageEvent<Req>) => {
  const req = ev.data;
  try {
    if (req.method === "init") {
      await ensureModule(req.url);
      post({ id: req.id, ok: true, result: null });
      return;
    }
    if (modPromise === null) throw new Error("lune worker: request before init");
    const mod = await modPromise;
    switch (req.method) {
      case "run": {
        const result = mod.runSource(req.src, req.argv);
        post({ id: req.id, ok: true, result }, runTransferables(result));
        return;
      }
      case "check": {
        const result = mod.check(req.src);
        post({ id: req.id, ok: true, result });
        return;
      }
      case "replay": {
        const result = mod.replay(req.src, req.effects, req.stopAfter);
        post({ id: req.id, ok: true, result }, replayTransferables(result));
        return;
      }
    }
  } catch (e) {
    post({ id: req.id, ok: false, error: e instanceof Error ? e.message : String(e) });
  }
};

function post(res: Res, transfer: Transferable[] = []): void {
  (self as unknown as Worker).postMessage(res, transfer);
}
