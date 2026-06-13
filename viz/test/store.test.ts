// Store-logic test (DOM-free): loading the fixture populates the store and
// selection behaves. The SolidJS store itself needs no DOM, so this runs under
// bun. Browser render is verified separately (manual, post-build).

import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { state, loadBytes, selectTrace, selectedTrace } from "../src/store";

const fixturePath = fileURLToPath(new URL("../fixtures/counting-loop.lunetrace", import.meta.url));
const bytes = new Uint8Array(readFileSync(fixturePath));

test("loadBytes populates the store and auto-selects the first trace", () => {
  loadBytes("counting-loop.lunetrace", bytes);
  expect(state.error).toBeNull();
  expect(state.fileName).toBe("counting-loop.lunetrace");
  expect(state.version).toBe(1);
  expect(state.traces.length).toBe(1);
  expect(state.selected).toBe(0);

  const t = selectedTrace();
  expect(t).not.toBeNull();
  expect(t!.anchorPc).toBe(5);
  expect(t!.instrs.length).toBe(18);
});

test("loadBytes on garbage records an error, not a crash", () => {
  loadBytes("bogus.lunetrace", new Uint8Array([0xff, 0x00, 0x01]));
  // Either a clean decode error or zero traces — never a thrown exception.
  expect(state.fileName).toBe("bogus.lunetrace");
  expect(state.selected === -1 || state.traces.length === 0).toBe(true);
});

test("selectTrace updates the selection", () => {
  loadBytes("counting-loop.lunetrace", bytes);
  selectTrace(0);
  expect(state.selected).toBe(0);
  expect(selectedTrace()!.anchorProtoId).toBe(0);
});
