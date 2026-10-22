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
  visibleGlobals,
  setScriptArgs,
  execLogFor,
  sourceLineOf,
  traceLoc,
  fileText,
  replaceWorkspace,
  newFile,
  renameFile,
  closeFile,
  filePathProblem,
  resolveRunFiles,
  buildStops,
  projectWorkspace,
  DEFAULT_PATH,
  DEFAULT_SOURCE,
} from "../src/store";
import type { TraceExecLogOutput } from "../src/gen/generated";

const fixturePath = fileURLToPath(new URL("../fixtures/counting-loop.mahinatrace", import.meta.url));
const bytes = new Uint8Array(readFileSync(fixturePath));

test("loadBytes populates the store and auto-selects the first trace", () => {
  loadBytes("counting-loop.mahinatrace", bytes);
  expect(state.error).toBeNull();
  expect(state.fileName).toBe("counting-loop.mahinatrace");
  expect(state.version).toBe(6); // v6: instructions map back to their bytecode
  expect(state.traces.length).toBe(1);
  expect(state.selected).toBe(0);

  const t = selectedTrace();
  expect(t).not.toBeNull();
  expect(t!.anchorPc).toBe(5);
  expect(t!.instrs.length).toBe(24);
});

test("a loaded trace is never mapped through the last run's disassembly", () => {
  // Its proto ids belong to whatever compile produced the file, not this run.
  loadBytes("counting-loop.mahinatrace", bytes);
  expect(state.tracesFromRun).toBe(false);
  expect(traceLoc({ protoId: 0, pc: 5 })).toBeNull();
});

test("sourceLineOf resolves a bytecode position through the disassembly", () => {
  const disasm = [
    { id: 0, name: "main", numParams: 0, numRegisters: 1, instrs: [{ line: 1, text: "" }, { line: 4, text: "" }] },
    { id: 3, name: "f", numParams: 0, numRegisters: 1, instrs: [{ line: 9, text: "" }] },
  ];
  expect(sourceLineOf(disasm, { protoId: 0, pc: 1 })).toBe(4);
  expect(sourceLineOf(disasm, { protoId: 3, pc: 0 })).toBe(9);
  expect(sourceLineOf(disasm, { protoId: 7, pc: 0 })).toBe(0); // no such proto
  expect(sourceLineOf(disasm, { protoId: 0, pc: 5 })).toBe(0); // pc out of range
  expect(sourceLineOf(disasm, null)).toBe(0);
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
  expect(coverageLineTitle({ cls: "native", native: 43, warmup: 57, coveredInterp: 2, uncovered: 0 })).toBe(
    "ran native — loop iterations: 43 native · 2 interpreted after tracing · 57 warm-up before the trace",
  );
  expect(coverageLineTitle({ cls: "uncovered", native: 0, warmup: 0, coveredInterp: 0, uncovered: 12000 })).toBe(
    "no trace, ran tier-0 — loop iterations: 0 native · 12,000 interpreted, no trace",
  );
});

test("the globals list hides step 1's builtins unless asked, but not reassigned ones", () => {
  const g = (label: string, value: string) => ({ label, value });
  const base = [g("print", "native#3"), g("string", "table#9")].map((x) => `${x.label}\u0000${x.value}`);
  const now = [g("count", "42"), g("print", "function#40"), g("string", "table#9")];
  const hidden = visibleGlobals(now, base, false);
  expect(hidden.shown.map((x) => x.label)).toEqual(["count", "print"]); // print was reassigned
  expect(hidden.hidden).toBe(1);
  expect(visibleGlobals(now, base, true)).toEqual({ shown: now, hidden: 0 });
  // Before step 1 is known, nothing is hidden.
  expect(visibleGlobals(now, null, false)).toEqual({ shown: now, hidden: 0 });
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
  replaceWorkspace([{ path: "keep.mahina", text: "print(1)\n" }], "keep.mahina");
  loadSourceBytes("photo.png", new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00]));
  expect(state.files).toEqual([{ path: "keep.mahina", text: "print(1)\n" }]);
  expect(state.entryPath).toBe("keep.mahina");
  expect(state.sourceError).toContain("photo.png is not a text file");
  loadSourceBytes("next.mahina", new TextEncoder().encode("print(2)\n"));
  expect(fileText("next.mahina")).toBe("print(2)\n");
  expect(state.activePath).toBe("next.mahina");
  expect(state.sourceError).toBeNull();
});

test("a dropped file loads by what it is, not only by its name", () => {
  replaceWorkspace([{ path: "main.mah", text: "print(0)\n" }], "main.mah");
  // Text under any name → the editor.
  loadDroppedFile("prog.txt", new TextEncoder().encode("print(3)\n"));
  expect(fileText("prog.txt")).toBe("print(3)\n");
  // A trace saved under another name → the trace view.
  loadDroppedFile("saved.bin", bytes);
  expect(state.fileName).toBe("saved.bin");
  expect(state.traces.length).toBe(1);
  expect(fileText("prog.txt")).toBe("print(3)\n");
  // Neither → reported; nothing replaced.
  loadDroppedFile("blob.dat", new Uint8Array([1, 0, 2, 0, 3]));
  expect(state.sourceError).toContain("neither source text nor a .mahinatrace");
  expect(state.files.map((f) => f.path)).toEqual(["main.mah", "prog.txt"]);
  expect(state.traces.length).toBe(1);
});

test("a loaded file joins the program as a tab, or replaces the file of its name", () => {
  replaceWorkspace([{ path: "main.mah", text: "require('lib')\n" }], "main.mah");
  loadSourceText("./lib.mah", "return 1\n");
  expect(state.files.map((f) => f.path)).toEqual(["main.mah", "lib.mah"]);
  expect(state.entryPath).toBe("main.mah");
  expect(state.activePath).toBe("lib.mah");
  loadSourceText("lib.mah", "return 2\n");
  expect(state.files.length).toBe(2);
  expect(fileText("lib.mah")).toBe("return 2\n");
});

test("files are added, renamed and closed; the entry follows its file", () => {
  replaceWorkspace([{ path: "main.mah", text: "" }], "main.mah");
  const a = newFile();
  expect(a).toBe("untitled.mah");
  expect(newFile()).toBe("untitled2.mah");
  expect(renameFile(a, "lib/util.mah")).toBeNull();
  expect(fileText("lib/util.mah")).toBe("");
  // Refused, nothing changed: an existing name, an escaping or absolute path.
  expect(renameFile("lib/util.mah", "untitled2.mah")).toContain("already exists");
  expect(renameFile("lib/util.mah", "../x.mah")).toContain("relative");
  expect(renameFile("lib/util.mah", "/x.mah")).toContain("relative");
  expect(filePathProblem("main.mah")).toContain("already exists");
  expect(filePathProblem("main.mah", "main.mah")).toBeNull();
  // Renaming the entry moves it.
  expect(renameFile("main.mah", "app.mah")).toBeNull();
  expect(state.entryPath).toBe("app.mah");
  // Closing the entry passes it to the first remaining file; the last file stays.
  closeFile("app.mah");
  expect(state.entryPath).toBe("lib/util.mah");
  closeFile("untitled2.mah");
  closeFile("lib/util.mah");
  expect(state.files.map((f) => f.path)).toEqual(["lib/util.mah"]);
});

test("resolveRunFiles maps each chunk to the workspace file it ran, else a read-only text", () => {
  const ran = [
    { path: "main.mah", text: "local m = require('mod')\n" },
    { path: "mod.mah", text: "return {}\n" },
  ];
  const chunks = [
    { firstProtoId: 0, protoCount: 2, name: "", source: "" },
    { firstProtoId: 2, protoCount: 1, name: "./mod.mah", source: "return {}\n" },
    { firstProtoId: 3, protoCount: 1, name: "=(load)", source: "return 1" },
    // A file whose text differs from the workspace's isn't that file.
    { firstProtoId: 4, protoCount: 1, name: "mod.mah", source: "return 2\n" },
  ];
  const files = resolveRunFiles(chunks, "main.mah", ran[0].text, ran);
  expect(files.map((f) => [f.path, f.virtual])).toEqual([
    ["main.mah", false],
    ["mod.mah", false],
    ["=(load) #2", true],
    ["mod.mah #3", true],
  ]);
  expect(files[0].text).toBe(ran[0].text);
  expect(files[2].text).toBe("return 1");
});

test("projectWorkspace normalizes paths and requires the entry among the files", () => {
  const ws = projectWorkspace({
    entry: "./prog.lua",
    files: [
      { path: "./prog.lua", text: "a" },
      { path: "lib/x.mah", text: "b" },
      { path: "lib/./x.mah", text: "dup" },
      { path: "../escape.mah", text: "c" },
    ],
  });
  expect(ws.entry).toBe("prog.lua");
  expect(ws.files).toEqual([
    { path: "prog.lua", text: "a" },
    { path: "lib/x.mah", text: "b" },
  ]);
  expect(() => projectWorkspace({ entry: "gone.lua", files: [{ path: "a.lua", text: "" }] })).toThrow("not among its files");
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

test("loadSourceText replaces the untouched default program and becomes the entry", () => {
  replaceWorkspace([{ path: DEFAULT_PATH, text: DEFAULT_SOURCE }], DEFAULT_PATH);
  loadSourceText("nsieve.mahina", "print(arg[1])\n");
  expect(state.files).toEqual([{ path: "nsieve.mahina", text: "print(arg[1])\n" }]);
  expect(state.entryPath).toBe("nsieve.mahina");
});

test("setScriptArgs updates the raw args string", () => {
  setScriptArgs("9");
  expect(state.scriptArgs).toBe("9");
  setScriptArgs("");
  expect(state.scriptArgs).toBe("");
});

test("buildStops offers only stoppable steps, and one per line", () => {
  // Steps 1..6: line 1 (stoppable), line 5 of another file ×2 (nested, inside
  // a `require`), line 2 ×2 (the first one still nested), line 3.
  const index = {
    count: 6,
    lines: new Uint32Array([1, 5, 5, 2, 2, 3]),
    protos: new Uint32Array([0, 9, 9, 0, 0, 0]),
    stoppable: new Uint8Array([1, 0, 0, 0, 1, 1]),
  };
  const fileKey = (id: number) => (id === 9 ? 1 : 0);
  expect(buildStops("instr", index, fileKey)).toEqual([1, 5, 6, 7]);
  // Line 5 has no stoppable step, so no stop; line 2 stops at its first
  // stoppable step (5), not at the nested 4.
  expect(buildStops("line", index, fileKey)).toEqual([1, 5, 6, 7]);
  // With every step stoppable, a line stop is the line's first step.
  expect(buildStops("line", { ...index, stoppable: new Uint8Array(6).fill(1) }, fileKey)).toEqual([1, 2, 4, 6, 7]);
  expect(buildStops("instr", { ...index, count: 0 }, fileKey)).toEqual([]);
});
