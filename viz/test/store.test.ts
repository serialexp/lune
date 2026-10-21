// Store-logic test (DOM-free): loading the fixture populates the store and
// selection behaves. The SolidJS store itself needs no DOM, so this runs under
// bun. Browser render is verified separately (manual, post-build).

import { test, expect } from "bun:test";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  state,
  loadBytes,
  selectTrace,
  selectedTrace,
  parseArgsString,
  loadSourceText,
  loadSourceBytes,
  loadDroppedFile,
  decodeSourceText,
  coverageLineTitle,
  setScriptArgs,
  execLogFor,
} from "../src/store";
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
  expect(state.fileName).toBe("bogus.mahinatrace");
  expect(state.error).toContain("not a .mahinatrace");
  expect(state.version).toBeNull();
  expect(state.traces.length).toBe(0);
  expect(state.selected).toBe(-1);
});

test("a loaded trace drops the last run's execution logs", () => {
  // Trace ids restart at 0 in every run, so a stale log would join to (and
  // animate) a different program's trace.
  loadBytes("counting-loop.mahinatrace", bytes);
  expect(state.execLogs).toEqual([]);
  expect(state.execLogsRecorded).toBe(false);
});

test("a coverage stripe's tooltip gives the class and the counts behind it", () => {
  expect(coverageLineTitle({ cls: "native", native: 43, coveredInterp: 57, uncovered: 0 })).toBe(
    "ran native — loop iterations: 43 native · 57 interpreted (warm-up included)",
  );
  expect(coverageLineTitle({ cls: "uncovered", native: 0, coveredInterp: 0, uncovered: 12000 })).toBe(
    "no trace, ran tier-0 — loop iterations: 0 native · 12,000 interpreted, no trace",
  );
});

test("decodeSourceText accepts UTF-8 text and refuses binary", () => {
  const enc = (s: string) => new TextEncoder().encode(s);
  expect(decodeSourceText(enc("print('héllo') -- ✓\n"))).toBe("print('héllo') -- ✓\n");
  expect(decodeSourceText(enc(""))).toBe("");
  expect(decodeSourceText(new Uint8Array([0x70, 0x00, 0x71]))).toBeNull(); // NUL
  expect(decodeSourceText(new Uint8Array([0x70, 0xc3, 0x28]))).toBeNull(); // bad UTF-8
  expect(decodeSourceText(bytes)).toBeNull(); // a .mahinatrace is binary
});

test("a binary source file is reported, and the editor keeps its text", () => {
  loadSourceText("keep.mahina", "print(1)\n");
  loadSourceBytes("photo.png", new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00]));
  expect(state.source).toBe("print(1)\n");
  expect(state.scriptName).toBe("keep.mahina");
  expect(state.sourceError).toContain("photo.png is not a text file");
  loadSourceBytes("next.mahina", new TextEncoder().encode("print(2)\n"));
  expect(state.source).toBe("print(2)\n");
  expect(state.sourceError).toBeNull();
});

test("a dropped file loads by what it is, not only by its name", () => {
  // Text under any name → the editor.
  loadDroppedFile("prog.txt", new TextEncoder().encode("print(3)\n"));
  expect(state.source).toBe("print(3)\n");
  // A trace saved under another name → the trace view.
  loadDroppedFile("saved.bin", bytes);
  expect(state.fileName).toBe("saved.bin");
  expect(state.traces.length).toBe(1);
  expect(state.source).toBe("print(3)\n");
  // Neither → reported; nothing replaced.
  loadDroppedFile("blob.dat", new Uint8Array([1, 0, 2, 0, 3]));
  expect(state.sourceError).toContain("neither source text nor a .mahinatrace");
  expect(state.source).toBe("print(3)\n");
  expect(state.traces.length).toBe(1);
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
