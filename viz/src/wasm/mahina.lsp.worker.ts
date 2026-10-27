// Web Worker hosting the in-browser language server (doc 74). It owns its own
// wasm instance, apart from the run/check worker: a run blocks its thread (and
// `stop()` terminates it), and neither must stall or kill the editor's
// diagnostics. The server core is sans-IO — message bodies in, message bodies
// out — so this file is only the host: it timestamps input, owns the debounce
// timer (`nextDeadline` → `setTimeout` → `tick`), and posts what the server
// emits. Wire format, both directions: `{ messages: string[] }` out,
// `{ init: url } | { send: string } | { close: true }` in.

import { loadMahina, type MahinaModule } from "./mahina";

type In = { init: string } | { send: string } | { close: true };
export type LspWorkerOut = { messages: string[] } | { error: string };

let mod: MahinaModule | null = null;
let timer: ReturnType<typeof setTimeout> | null = null;
// Input that arrives while the wasm module is still loading.
let queue: string[] = [];

const now = (): number => performance.now();

function emit(messages: string[]): void {
  if (messages.length > 0) (self as unknown as Worker).postMessage({ messages } satisfies LspWorkerOut);
}

function fail(e: unknown): void {
  (self as unknown as Worker).postMessage({ error: e instanceof Error ? e.message : String(e) } satisfies LspWorkerOut);
}

function rearm(): void {
  if (timer !== null) clearTimeout(timer);
  timer = null;
  const deadline = mod?.lsp.nextDeadline() ?? null;
  if (deadline === null) return;
  timer = setTimeout(() => {
    timer = null;
    try {
      emit(mod!.lsp.tick(now()));
      rearm();
    } catch (e) {
      fail(e);
    }
  }, Math.max(0, deadline - now()));
}

function deliver(body: string): void {
  emit(mod!.lsp.send(body, now()));
  rearm();
}

self.onmessage = async (ev: MessageEvent<In>) => {
  const msg = ev.data;
  try {
    if ("init" in msg) {
      mod = await loadMahina(msg.init);
      mod.lsp.open();
      for (const body of queue) deliver(body);
      queue = [];
    } else if ("send" in msg) {
      if (mod === null) queue.push(msg.send);
      else deliver(msg.send);
    } else {
      if (timer !== null) clearTimeout(timer);
      mod?.lsp.close();
      self.close();
    }
  } catch (e) {
    fail(e);
  }
};
