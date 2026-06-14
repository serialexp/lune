// lune_check tests: the compile-only validation entry the in-browser editor's
// live linter drives. It parses + compiles WITHOUT running the program and
// returns structured diagnostics (severity + byte span + line + message), so the
// editor can draw a squiggle exactly under the offending token.
//
// Requires `zig build wasm` at the repo root.

import { test, expect, beforeAll } from "bun:test";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { instantiateLuneFromBytes, type LuneModule } from "../src/wasm/lune";

const wasmPath = fileURLToPath(new URL("../../zig-out/bin/lune.wasm", import.meta.url));

let mod: LuneModule;
beforeAll(async () => {
  mod = await instantiateLuneFromBytes(new Uint8Array(readFileSync(wasmPath)));
});

test("a valid program checks clean (no diagnostics)", () => {
  const src = "local s = 0\nfor i = 1, 100 do s = s + i end\nprint(s)\n";
  expect(mod.check(src)).toEqual([]);
});

test("a syntax error produces a structured diagnostic with a valid span", () => {
  const src = "local x =\n";
  const diags = mod.check(src);

  expect(diags.length).toBeGreaterThan(0);
  const d = diags[0]!;
  expect(d.severity).toBe("error");
  expect(d.message.length).toBeGreaterThan(0);
  expect(d.line).toBeGreaterThanOrEqual(1);
  // The span must be well-formed and point inside the source.
  expect(d.end).toBeGreaterThanOrEqual(d.start);
  expect(d.start).toBeLessThanOrEqual(src.length);
  expect(d.end).toBeLessThanOrEqual(src.length);
});

test("an empty program checks clean", () => {
  expect(mod.check("")).toEqual([]);
});

test("check does not execute the program (an infinite loop returns promptly)", () => {
  // If `check` ran the program this would hang the test runner. It compiles
  // cleanly and returns no diagnostics — proving it stops after the frontend.
  const src = "while true do end\n";
  const diags = mod.check(src);
  expect(diags).toEqual([]);
});

test("a second check on the same module instance still works (no leaked state)", () => {
  expect(mod.check("print(1)\n")).toEqual([]);
  expect(mod.check("local y =\n").length).toBeGreaterThan(0);
  expect(mod.check("print(2)\n")).toEqual([]);
});

test("an unknown global read produces a warning with a span on the name", () => {
  // `d` is read but never assigned and is not a builtin → Luau-style warning.
  const src = "local sum = 0\nsum = sum + d\n";
  const diags = mod.check(src);

  expect(diags.length).toBe(1);
  const d = diags[0]!;
  expect(d.severity).toBe("warning");
  expect(d.message).toContain("undefined global");
  expect(d.message).toContain("'d'");
  // Span underlines exactly the one-character `d`.
  expect(src.slice(d.start, d.end)).toBe("d");
});

test("a global assigned elsewhere does not warn", () => {
  expect(mod.check("g = 1\nlocal x = g\nprint(x)\n")).toEqual([]);
});

test("reading a builtin global does not warn", () => {
  expect(mod.check("print(clock())\n")).toEqual([]);
});

test("a forward reference to a later global function does not warn", () => {
  const src = "local function main() return helper() end\nfunction helper() return 1 end\n";
  expect(mod.check(src)).toEqual([]);
});
