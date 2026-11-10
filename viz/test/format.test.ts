// mahina_format tests: the source formatter (doc 83) through the wasm module the
// editor's Format command drives. Pure: it never runs the program.
//
// Requires `zig build wasm` at the repo root.

import { test, expect, beforeAll } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { instantiateMahinaFromBytes, type MahinaModule } from "../src/wasm/mahina";

const wasmPath = fileURLToPath(new URL("../../zig-out/bin/mahina.wasm", import.meta.url));

let mod: MahinaModule;
beforeAll(async () => {
  mod = await instantiateMahinaFromBytes(new Uint8Array(readFileSync(wasmPath)));
});

test("formats a sample, and the formatted program still runs the same", () => {
  const src = "local   s=0;\nfor i=1,10 do s=s+i end\nprint( s )";
  const r = mod.format(src);
  expect(r.status).toBe("ok");
  if (r.status !== "ok") return;
  expect(r.text).toBe("local s = 0\nfor i = 1, 10 do\n    s = s + i\nend\nprint(s)\n");
  const before = mod.runSource(src);
  const after = mod.runSource(r.text);
  expect(after.status).toBe(0);
  expect(after.stdout).toBe(before.stdout);
});

test("formatting is a fixed point", () => {
  const r = mod.format("local t={1,2,3,x=4}\nprint(t.x)\n");
  expect(r.status).toBe("ok");
  if (r.status !== "ok") return;
  const again = mod.format(r.text);
  expect(again).toEqual({ status: "ok", text: r.text });
});

test("a syntax error is refused with structured diagnostics", () => {
  const r = mod.format("local = =\n");
  expect(r.status).toBe("syntax");
  if (r.status !== "syntax") return;
  expect(r.diagnostics.length).toBeGreaterThan(0);
  expect(r.diagnostics[0]!.severity).toBe("error");
});

test("an empty program formats to nothing", () => {
  expect(mod.format("")).toEqual({ status: "ok", text: "" });
});

test("non-ASCII text survives", () => {
  const r = mod.format('print( "héllo — 世界" )');
  expect(r).toEqual({ status: "ok", text: 'print("héllo — 世界")\n' });
});
