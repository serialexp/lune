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

test("navigation and completion answer over the wasm boundary", () => {
  e.mahina_lsp_open();
  send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { capabilities: {} } }, 0);
  const uri = "file:///nav.mh";
  const text = "local count = 1\nprint(count)\n";
  send({ jsonrpc: "2.0", method: "textDocument/didOpen", params: { textDocument: { uri, languageId: "mahina", version: 1, text } } }, 1);
  const at = { textDocument: { uri }, position: { line: 1, character: 8 } };

  // Asked before the debounce ran: the request analyses the text itself.
  const def = send({ jsonrpc: "2.0", id: 2, method: "textDocument/definition", params: at }, 2).at(-1);
  expect(def.result.range.start).toEqual({ line: 0, character: 6 });

  const rename = send({ jsonrpc: "2.0", id: 3, method: "textDocument/rename", params: { ...at, newName: "total" } }, 3).at(-1);
  expect(rename.result.changes[uri].map((x: any) => x.newText)).toEqual(["total", "total"]);

  const refused = send({ jsonrpc: "2.0", id: 4, method: "textDocument/rename", params: { ...at, newName: "end" } }, 4).at(-1);
  expect(refused.error.code).toBe(-32803);

  const list = send({ jsonrpc: "2.0", id: 5, method: "textDocument/completion", params: { textDocument: { uri }, position: { line: 2, character: 0 } } }, 5).at(-1);
  const labels = list.result.items.map((x: any) => x.label);
  expect(labels).toContain("count");
  expect(labels).toContain("print");
  expect(labels).toContain("while");
  e.mahina_lsp_close();
});

test("semantic tokens, outline and folds answer over the wasm boundary", () => {
  e.mahina_lsp_open();
  send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { capabilities: {} } }, 0);
  const uri = "file:///syntax.mh";
  const text = "local n = 1\nif n then\n  n = 2\nend\n";
  send({ jsonrpc: "2.0", method: "textDocument/didOpen", params: { textDocument: { uri, languageId: "mahina", version: 1, text } } }, 1);

  const tokens = send({ jsonrpc: "2.0", id: 2, method: "textDocument/semanticTokens/full", params: { textDocument: { uri } } }, 2).at(-1);
  // Five integers per token, the first being `local` (a keyword) at 0:0.
  expect(tokens.result.data.slice(0, 5)).toEqual([0, 0, 5, 0, 0]);
  expect(tokens.result.data.length % 5).toBe(0);

  const folds = send({ jsonrpc: "2.0", id: 3, method: "textDocument/foldingRange", params: { textDocument: { uri } } }, 3).at(-1);
  // The `if` opens on line 1 and its `end` is on line 3: line 2 folds away.
  expect(folds.result).toEqual([{ startLine: 1, endLine: 2 }]);

  const outline = send({ jsonrpc: "2.0", id: 4, method: "textDocument/documentSymbol", params: { textDocument: { uri } } }, 4).at(-1);
  expect(outline.result.map((s: any) => s.name)).toEqual(["n"]);
  e.mahina_lsp_close();
});
test("hover, signature help and library members answer over the wasm boundary", () => {
  e.mahina_lsp_open();
  send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { capabilities: {} } }, 0);
  const uri = "file:///lib.mh";
  const text = 'print(string.format("%d", 1))\nlocal s = string.\n';
  send({ jsonrpc: "2.0", method: "textDocument/didOpen", params: { textDocument: { uri, languageId: "mahina", version: 1, text } } }, 1);

  // `format` starts at character 13 of the first line.
  const hover = send({ jsonrpc: "2.0", id: 2, method: "textDocument/hover", params: { textDocument: { uri }, position: { line: 0, character: 15 } } }, 2).at(-1);
  expect(hover.result.contents.kind).toBe("markdown");
  expect(hover.result.contents.value).toContain("string.format(formatstring, ...)");
  expect(hover.result.range.start).toEqual({ line: 0, character: 13 });

  // The cursor is after the comma that follows the format string: argument 1.
  const sig = send({ jsonrpc: "2.0", id: 3, method: "textDocument/signatureHelp", params: { textDocument: { uri }, position: { line: 0, character: 26 } } }, 3).at(-1);
  expect(sig.result.signatures[0].label).toBe("string.format(formatstring, ...)");
  expect(sig.result.activeParameter).toBe(1);

  const members = send({ jsonrpc: "2.0", id: 4, method: "textDocument/completion", params: { textDocument: { uri }, position: { line: 1, character: 17 } } }, 4).at(-1);
  const format = members.result.items.find((x: any) => x.label === "format");
  expect(format.kind).toBe(3);
  expect(format.detail).toBe("string.format(formatstring, ...)");
  e.mahina_lsp_close();
});
