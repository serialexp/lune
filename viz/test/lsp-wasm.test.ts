// The language server's wasm exports (doc 74): a message-body API over the
// sans-IO core. Requires `zig build wasm` at the repo root.

import { test, expect, beforeAll } from "bun:test";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const wasmPath = fileURLToPath(new URL("../../zig-out/bin/mahina.wasm", import.meta.url));
const enc = new TextEncoder();
const dec = new TextDecoder();

type Exports = Record<string, any> & { memory: WebAssembly.Memory };
let e: Exports;

beforeAll(async () => {
  const { instance } = await WebAssembly.instantiate(readFileSync(wasmPath), {
    env: { host_now_ns: () => 0n, host_random_seed: () => 1n },
  });
  e = instance.exports as Exports;
});

function messages(n: number): any[] {
  const out: any[] = [];
  const mem = new Uint8Array(e.memory.buffer);
  for (let i = 0; i < n; i++) {
    const p = e.mahina_lsp_message_ptr(i);
    const l = e.mahina_lsp_message_len(i);
    out.push(JSON.parse(dec.decode(mem.slice(p, p + l))));
  }
  return out;
}

function send(msg: object, now: number): any[] {
  const b = enc.encode(JSON.stringify(msg));
  const p = e.mahina_alloc(b.length);
  new Uint8Array(e.memory.buffer).set(b, p);
  const n = e.mahina_lsp_send(p, b.length, now);
  e.mahina_free(p, b.length);
  expect(n).not.toBe(0xffffffff);
  return messages(n);
}

test("initialize, open, debounced diagnostics, shutdown, exit", () => {
  expect(e.mahina_lsp_open()).toBe(0);
  expect(e.mahina_lsp_next_deadline()).toBe(-1);

  const [init] = send(
    { jsonrpc: "2.0", id: 1, method: "initialize", params: { capabilities: { general: { positionEncodings: ["utf-8"] } } } },
    0,
  );
  expect(init.result.capabilities.positionEncoding).toBe("utf-8");
  expect(send({ jsonrpc: "2.0", method: "initialized", params: {} }, 1)).toEqual([]);

  const uri = "file:///a.mh";
  send({ jsonrpc: "2.0", method: "textDocument/didOpen", params: { textDocument: { uri, languageId: "mahina", version: 1, text: "local x = 1" } } }, 10);
  // The timer is the host's: the core only says when.
  expect(e.mahina_lsp_next_deadline()).toBe(60);
  expect(messages(e.mahina_lsp_tick(59))).toEqual([]);
  const [pub] = messages(e.mahina_lsp_tick(60));
  expect(pub.method).toBe("textDocument/publishDiagnostics");
  expect(pub.params).toEqual({ uri, version: 1, diagnostics: [] });
  expect(e.mahina_lsp_next_deadline()).toBe(-1);

  const [down] = send({ jsonrpc: "2.0", id: 2, method: "shutdown" }, 100);
  expect(down.result).toBeNull();
  expect(e.mahina_lsp_is_done()).toBe(0);
  send({ jsonrpc: "2.0", method: "exit" }, 101);
  expect(e.mahina_lsp_is_done()).toBe(1);
  e.mahina_lsp_close();
});

test("malformed input answers with an error instead of trapping", () => {
  e.mahina_lsp_open();
  const b = enc.encode("{not json");
  const p = e.mahina_alloc(b.length);
  new Uint8Array(e.memory.buffer).set(b, p);
  const n = e.mahina_lsp_send(p, b.length, 0);
  e.mahina_free(p, b.length);
  const [err] = messages(n);
  expect(err.error.code).toBe(-32700);
  e.mahina_lsp_close();
});
