// Store-logic test (DOM-free): loading the fixture populates the store and
// selection behaves. The SolidJS store itself needs no DOM, so this runs under
// bun. Browser render is verified separately (manual, post-build).

import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { state, loadBytes, selectTrace, selectedTrace, parseArgsString, loadSourceText, setScriptArgs, execLogFor } from "../src/store";
import type { TraceExecLogOutput } from "../src/gen/generated";

const fixturePath = fileURLToPath(new URL("../fixtures/counting-loop.mahinatrace", import.meta.url));
const bytes = new Uint8Array(readFileSync(fixturePath));

test("loadBytes populates the store and auto-selects the first trace", () => {
  loadBytes("counting-loop.mahinatrace", bytes);
  expect(state.error).toBeNull();
  expect(state.fileName).toBe("counting-loop.mahinatrace");
  expect(state.version).toBe(5); // v5: traces carry their stable Trace.id
  expect(state.traces.length).toBe(1);
  expect(state.selected).toBe(0);

  const t = selectedTrace();
  expect(t).not.toBeNull();
  expect(t!.anchorPc).toBe(5);
  expect(t!.instrs.length).toBe(21);
});

test("loadBytes on garbage records an error, not a crash", () => {
  loadBytes("bogus.mahinatrace", new Uint8Array([0xff, 0x00, 0x01]));
  // Either a clean decode error or zero traces — never a thrown exception.
  expect(state.fileName).toBe("bogus.mahinatrace");
  expect(state.selected === -1 || state.traces.length === 0).toBe(true);
});

test("exec logs join to traces by stable id, not by list position", () => {
  // A retired trace leaves a gap in ids: the surviving traces [7, 3] sit at list
  // positions 0 and 1, and the logs are in a different order still.
  const log = (trace_id: number): TraceExecLogOutput => ({ trace_id, entries_capped: 0, entries: [] });
  const logs = [log(3), log(7)];
  expect(execLogFor({ id: 7 }, logs)?.trace_id).toBe(7);
  expect(execLogFor({ id: 3 }, logs)?.trace_id).toBe(3);
  expect(execLogFor({ id: 0 }, logs)).toBeNull(); // position 0 is not id 0
  expect(execLogFor(null, logs)).toBeNull();
});

test("selectTrace updates the selection", () => {
  loadBytes("counting-loop.mahinatrace", bytes);
  selectTrace(0);
  expect(state.selected).toBe(0);
  expect(selectedTrace()!.anchorProtoId).toBe(0);
});

test("parseArgsString splits on whitespace and drops empties", () => {
  expect(parseArgsString("9")).toEqual(["9"]);
  expect(parseArgsString("9 hello 42")).toEqual(["9", "hello", "42"]);
  expect(parseArgsString("  9\t hello \n")).toEqual(["9", "hello"]);
  expect(parseArgsString("")).toEqual([]);
  expect(parseArgsString("   ")).toEqual([]);
});

test("loadSourceText loads text into the editor and sets the script name", () => {
  loadSourceText("nsieve.mahina", "print(arg[1])\n");
  expect(state.source).toBe("print(arg[1])\n");
  expect(state.scriptName).toBe("nsieve.mahina");
});

test("setScriptArgs updates the raw args string", () => {
  setScriptArgs("9");
  expect(state.scriptArgs).toBe("9");
  setScriptArgs("");
  expect(state.scriptArgs).toBe("");
});
