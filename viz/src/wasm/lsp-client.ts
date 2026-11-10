// Main-thread side of the in-browser language server (doc 74): one
// `LSPClient` (`@codemirror/lsp-client`) talking to `mahina.lsp.worker.ts` over
// postMessage. The worker is spawned lazily, on the first editor that asks, so
// the test suite that imports the store never touches `Worker`.

import { LSPClient, languageServerExtensions, languageServerSupport, type Transport } from "@codemirror/lsp-client";
import type { Extension } from "@codemirror/state";
import { resolveWasmUrl } from "./mahina-client";
import type { LspWorkerOut } from "./mahina.lsp.worker";

/** A `Transport` over a Worker: the messages are the JSON bodies themselves. */
export function workerTransport(worker: Worker): Transport {
  const handlers = new Set<(value: string) => void>();
  worker.onmessage = (ev: MessageEvent<LspWorkerOut>) => {
    if ("error" in ev.data) {
      console.error("mahina language server:", ev.data.error);
      return;
    }
    for (const m of ev.data.messages) for (const h of handlers) h(m);
  };
  return {
    send: (message) => worker.postMessage({ send: message }),
    subscribe: (h) => void handlers.add(h),
    unsubscribe: (h) => void handlers.delete(h),
  };
}

let client: LSPClient | null = null;

function ensureClient(): LSPClient {
  if (client !== null) return client;
  const worker = new Worker(new URL("./mahina.lsp.worker.ts", import.meta.url), { type: "module" });
  worker.postMessage({ init: resolveWasmUrl(import.meta.env?.BASE_URL ?? "./", document.baseURI) });
  client = new LSPClient({ extensions: languageServerExtensions() }).connect(workerTransport(worker));
  return client;
}

/** The CodeMirror extension that keeps `path` open on the server and shows
 *  its diagnostics. Every tab gets its own URI under one workspace. */
export function mahinaLanguageServer(path: string): Extension {
  return languageServerSupport(ensureClient(), `file:///${path.replace(/^\/+/, "")}`, "mahina");
}
