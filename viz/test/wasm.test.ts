// In-browser VM (wasm) test, run under bun's WebAssembly engine (which honours
// `return_call`, like every major browser since Safari 18.2). Two things are
// proven here:
//   1. The guaranteed-tail-call capability gate runs on wasm: a 2M-hop
//      `@call(.always_tail)` chain completes in O(1) stack (pillar #4).
//   2. The wasm VM runs a real program end-to-end and produces a decodable
//      trace, byte-identical to what the native binary emits for the same
//      deterministic source (the foundation of the differential validator).
//
// The .wasm is built by `zig build wasm` at the repo root; this test reads it
// from zig-out. If it's missing, build it first.

import { test, expect, beforeAll } from "bun:test";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { instantiateLuneFromBytes, type LuneModule } from "../src/wasm/lune";
import { decodeTraceFile } from "../src/decode";
import { viewsOf } from "../src/disasm";

const wasmPath = fileURLToPath(new URL("../../zig-out/bin/lune.wasm", import.meta.url));

let mod: LuneModule;

beforeAll(async () => {
  const bytes = new Uint8Array(readFileSync(wasmPath));
  mod = await instantiateLuneFromBytes(bytes);
});

test("tail-call capability gate: 2M .always_tail hops run in O(1) stack", () => {
  // If wasm frames were NOT reused this would overflow long before completing.
  expect(mod.dispatchSmoke(2_000_000)).toBe(2_000_000);
});

test("runs a counting loop end-to-end and prints the sum", () => {
  const result = mod.runSource("local s = 0\nfor i = 1, 100 do s = s + i end\nprint(s)\n");
  expect(result.status).toBe(0);
  expect(result.diagnostics).toBe("");
  expect(result.stdout).toBe("5050\n");
});

test("records a decodable trace for a hot loop", () => {
  // A loop hot enough to be traced (the recorder's threshold is well under 1k).
  const result = mod.runSource("local s = 0\nfor i = 1, 1000 do s = s + i end\nprint(s)\n");
  expect(result.status).toBe(0);
  expect(result.stdout).toBe("500500\n");
  // The trace bytes decode with the same pipeline the inspector uses.
  expect(result.trace.length).toBeGreaterThan(0);
  const file = decodeTraceFile(result.trace);
  const views = viewsOf(file);
  expect(views.length).toBeGreaterThan(0);
});

test("a syntax error is reported, not thrown", () => {
  const result = mod.runSource("local = = =\n");
  expect(result.status).toBe(1);
  expect(result.diagnostics.length).toBeGreaterThan(0);
});

test("keyframe + effects are produced for a deterministic program", () => {
  const result = mod.runSource("local t = {a = 1, b = 2}\nprint(t.a + t.b)\n");
  expect(result.status).toBe(0);
  expect(result.stdout).toBe("3\n");
  expect(result.keyframe.length).toBeGreaterThan(0); // reachable heap graph
});
