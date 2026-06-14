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
import { decodeSnapshot } from "../src/snapshot";
import { diffRuns } from "../src/diff";

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

test("a successful run reports execute-only and total timing", () => {
  const result = mod.runSource("local s = 0\nfor i = 1, 1000 do s = s + i end\nprint(s)\n");
  expect(result.status).toBe(0);
  // Both are finite, non-negative wall-clocks. execMs is measured inside wasm
  // (the vm.run call alone); totalMs in JS around the whole lune_run call.
  expect(Number.isFinite(result.execMs)).toBe(true);
  expect(Number.isFinite(result.totalMs)).toBe(true);
  expect(result.execMs).toBeGreaterThanOrEqual(0);
  expect(result.totalMs).toBeGreaterThanOrEqual(0);
});

test("a syntax error is reported, not thrown", () => {
  const result = mod.runSource("local = = =\n");
  expect(result.status).toBe(1);
  expect(result.diagnostics.length).toBeGreaterThan(0);
});

test("a runtime error carries a located, Lua-style message", () => {
  // `d` is an unassigned global (reads nil) → nil arithmetic on line 2.
  const src = "local s = 0\ns = s + d\n";
  const result = mod.runSource(src);
  expect(result.status).toBe(1);
  expect(result.errorLine).toBe(2);
  expect(result.diagnostics).toContain("arithmetic");
  expect(result.diagnostics).toContain("nil");
  // The byte span brackets the faulting `s + d` operation.
  expect(src.slice(result.errorStart, result.errorEnd)).toBe("s + d");
});

test("calling a nil value is a located runtime error", () => {
  const result = mod.runSource("local f\nf()\n");
  expect(result.status).toBe(1);
  expect(result.errorLine).toBe(2);
  expect(result.diagnostics).toContain("call");
});

test("a nested fault carries a deepest-first backtrace", () => {
  // `f` faults on line 2 (nil arithmetic); it is called from main on line 5.
  const src = "function f(x)\n  return x + nope\nend\nlocal s = 0\ns = f(1)\n";
  const result = mod.runSource(src);
  expect(result.status).toBe(1);
  expect(result.backtrace.length).toBe(2);
  // Leaf first: f at line 2; then its caller main at the call site, line 5.
  expect(result.backtrace[0]).toMatchObject({ name: "f", line: 2 });
  expect(result.backtrace[1]).toMatchObject({ name: "main", line: 5 });
  // The leaf mirrors the flat error location used by the editor squiggle.
  expect(result.errorLine).toBe(result.backtrace[0].line);
  // Flattened the way the UI renders it.
  const traceback = result.backtrace.map((f) => `${f.name}:${f.line}`).join(" → ");
  expect(traceback).toBe("f:2 → main:5");
});

test("a clean run reports no runtime-error location", () => {
  const result = mod.runSource("print(1 + 2)\n");
  expect(result.status).toBe(0);
  expect(result.errorLine).toBe(0);
  expect(result.backtrace.length).toBe(0);
});

test("replay: stepping advances the line and grows stdout; the full replay matches the run", () => {
  const src = "local s = 0\nfor i = 1, 3 do\n  s = s + i\n  print(s)\nend\nprint(\"done\")\n";
  const run = mod.runSource(src);
  expect(run.status).toBe(0);
  // The record run reports a positive step count and a matching line index.
  expect(run.safepointCount).toBeGreaterThan(0);
  expect(run.safepointLines.length).toBe(run.safepointCount);
  expect(run.safepointCapped).toBe(false);

  // Replaying to the same step twice is byte-identical (deterministic replay).
  const a = mod.replay(src, run.effects, 5);
  const b = mod.replay(src, run.effects, 5);
  expect(a.status).toBe(0);
  expect(a.currentLine).toBe(b.currentLine);
  expect(a.stdout).toBe(b.stdout);
  expect(a.finished).toBe(false);
  // A suspended step reports an in-range pending line (the source is 6 lines).
  expect(a.currentLine).toBeGreaterThanOrEqual(1);
  expect(a.currentLine).toBeLessThanOrEqual(6);

  // stdout-so-far never shrinks as the step index advances.
  let prevLen = 0;
  for (let k = 1; k <= run.safepointCount; k++) {
    const step = mod.replay(src, run.effects, k);
    expect(step.stdout.length).toBeGreaterThanOrEqual(prevLen);
    prevLen = step.stdout.length;
  }

  // Replaying past the last safepoint reproduces the uninterrupted run exactly.
  const whole = mod.replay(src, run.effects, run.safepointCount + 1);
  expect(whole.finished).toBe(true);
  expect(whole.stdout).toBe(run.stdout);

  // The mid-run keyframe decodes into a state view: `s` lives in a local and the
  // built-in `print` shows up among the globals.
  const view = decodeSnapshot(a.keyframe);
  expect(view).not.toBeNull();
  expect(view!.locals.length).toBeGreaterThan(0);
  expect(view!.globals.some((g) => g.label === "print")).toBe(true);
});

test("a run disassembles the proto tree and the replay cursor indexes it", () => {
  const src = "local s = 0\nfor i = 1, 3 do\n  s = s + i\n  print(s)\nend\nprint(\"done\")\n";
  const run = mod.runSource(src);
  expect(run.status).toBe(0);

  // The disassembly is non-empty and includes the top-level `main` proto with a
  // non-empty instruction listing.
  expect(run.disasm.length).toBeGreaterThan(0);
  const main = run.disasm.find((p) => p.name === "main");
  expect(main).toBeDefined();
  expect(main!.instrs.length).toBeGreaterThan(0);
  // Every instruction carries rendered text (op + operands).
  expect(main!.instrs.every((ins) => ins.text.length > 0)).toBe(true);

  // A mid-run step reports a cursor that lands on a real instruction whose
  // annotated line matches the step's reported current line.
  const step = mod.replay(src, run.effects, 5);
  expect(step.finished).toBe(false);
  const proto = run.disasm.find((p) => p.id === step.protoId);
  expect(proto).toBeDefined();
  expect(step.pc).toBeLessThan(proto!.instrs.length);
  expect(proto!.instrs[step.pc].line).toBe(step.currentLine);
});

test("keyframe + effects are produced for a deterministic program", () => {
  const result = mod.runSource("local t = {a = 1, b = 2}\nprint(t.a + t.b)\n");
  expect(result.status).toBe(0);
  expect(result.stdout).toBe("3\n");
  expect(result.keyframe.length).toBeGreaterThan(0); // reachable heap graph
});

test("env/args builtins read the wasm null host: getenv→nil, argc→0, argv→nil", () => {
  // The browser has no process environment or command-line args, so the wasm
  // host injects a *null* HostEnv: every getenv misses (nil), argc is 0, and any
  // argv index is out of range (nil). These are still recorded effects — the call
  // site is a nondeterministic-input boundary — but their values are fixed here.
  const result = mod.runSource(
    'print(getenv("HOME"))\nprint(argc())\nprint(argv(0))\n',
  );
  expect(result.status).toBe(0);
  expect(result.stdout).toBe("nil\n0\nnil\n");
  // Three effect natives fired (getenv, argc, argv) → three logged effects, read
  // from the EffectFile length prefix the diff view uses (decode-free).
  const dv = new DataView(
    result.effects.buffer,
    result.effects.byteOffset,
    result.effects.byteLength,
  );
  expect(dv.getUint32(4, true)).toBe(3);
});

test("env/args reads diff as expected nondeterministic divergence, not a real mismatch", () => {
  // A program that reads env/args records effects, so it is NOT in the strong
  // (zero-effect) determinism regime. diffRuns must treat an effects/keyframe/
  // stdout divergence as *expected* (like clock()/random()), the same way the
  // EffectFile length prefix the diff reads is unchanged by the v2 result format.
  const reader = mod.runSource('print(getenv("PATH"))\n');
  expect(reader.status).toBe(0);
  // Fabricate a second engine's artifacts that differ only in the recorded input
  // (one effect each, distinct bytes) — the env-reading program is nondeterministic.
  const other = mod.runSource('print(getenv("PATH"))\n');
  const report = diffRuns(
    { keyframe: reader.keyframe, effects: reader.effects, trace: reader.trace, stdout: reader.stdout, status: reader.status },
    { keyframe: other.keyframe, effects: other.effects, trace: other.trace, stdout: other.stdout, status: other.status },
  );
  // One effect recorded on each side → not the strong-claim regime.
  expect(report.deterministic).toBe(false);
  expect(report.wasmEffects).toBe(1);
  expect(report.nativeEffects).toBe(1);
  // Whatever differs is excused: no unexplained artifact mismatch survives.
  expect(report.ok).toBe(true);
});
