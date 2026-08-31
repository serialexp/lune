// Dual-execution differential validator test. Runs an integer corpus through
// BOTH engines — the wasm VM (in this process) and the native binary (spawned) —
// and asserts the two produce byte-identical keyframe + effects + trace. Two
// different engines agreeing is the strongest determinism check we have.
//
// This drives the native binary directly via Bun.spawnSync (the same flag set
// the dev-server `POST /run` middleware uses), so it needs no Vite server.
// Requires `zig build` (native) and `zig build wasm` at the repo root.

import { test, expect, beforeAll } from "bun:test";
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { instantiateMahinaFromBytes, type MahinaModule } from "../src/wasm/mahina";
import { diffRuns, type RunArtifacts } from "../src/diff";

const repoBin = (name: string) => fileURLToPath(new URL(`../../zig-out/bin/${name}`, import.meta.url));
const wasmPath = repoBin("mahina.wasm");
const nativePath = repoBin("mahina");

let mod: MahinaModule;

beforeAll(async () => {
  mod = await instantiateMahinaFromBytes(new Uint8Array(readFileSync(wasmPath)));
});

/** Run a source chunk through the native binary, collecting its artifacts. */
function runNative(source: string): RunArtifacts {
  const dir = mkdtempSync(join(tmpdir(), "mahina-difftest-"));
  try {
    const src = join(dir, "p.mahina");
    const kf = join(dir, "k");
    const ef = join(dir, "e");
    const tr = join(dir, "t");
    writeFileSync(src, source);
    const r = Bun.spawnSync([nativePath, "--emit-traces", tr, "--emit-keyframe", kf, "--emit-effects", ef, src]);
    const read = (p: string): Uint8Array => {
      try {
        return new Uint8Array(readFileSync(p));
      } catch {
        return new Uint8Array(0);
      }
    };
    return {
      status: r.exitCode === 0 ? 0 : 1,
      stdout: r.stdout.toString(),
      keyframe: read(kf),
      effects: read(ef),
      trace: read(tr),
    };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function runWasm(source: string): RunArtifacts {
  const r = mod.runSource(source);
  return { status: r.status, stdout: r.stdout, keyframe: r.keyframe, effects: r.effects, trace: r.trace };
}

// Integer/deterministic corpus: no clock(), no floats ⇒ the strong byte-identity
// claim must hold across both engines.
const integerCorpus: { name: string; src: string }[] = [
  { name: "counting loop", src: "local s = 0\nfor i = 1, 100 do s = s + i end\nprint(s)\n" },
  { name: "hot loop (traced)", src: "local s = 0\nfor i = 1, 2000 do s = s + i end\nprint(s)\n" },
  { name: "table of ints", src: "local t = {a = 1, b = 2, c = 3}\nprint(t.a + t.b + t.c)\n" },
  { name: "nested arithmetic", src: "local x = 7\nlocal y = (x * 3 + 1) % 5\nprint(y)\n" },
  { name: "string interning", src: 'local a = "mahina"\nlocal b = "mahina"\nprint(a)\nprint(b)\n' },
];

for (const { name, src } of integerCorpus) {
  test(`wasm ≡ native (byte-identical): ${name}`, () => {
    const wasm = runWasm(src);
    const native = runNative(src);
    const report = diffRuns(wasm, native);

    expect(wasm.status).toBe(0);
    expect(native.status).toBe(0);
    expect(report.deterministic).toBe(true);
    // Every artifact byte-identical, stdout identical, no unexplained divergence.
    expect(report.stdoutMatch).toBe(true);
    for (const a of report.artifacts) {
      expect(a.match).toBe(true);
    }
    expect(report.ok).toBe(true);
  });
}

test("clock() program: effect-log divergence is expected, not a failure", () => {
  const src = "local t = os.clock()\nlocal x = 0\nfor i = 1, 10 do x = x + i end\nprint(x)\n";
  const wasm = runWasm(src);
  const native = runNative(src);
  const report = diffRuns(wasm, native);

  expect(report.deterministic).toBe(false);
  // The effect logs differ (independent clock values) — but it's labelled, so the
  // overall verdict is still ok (no UNEXPLAINED divergence). The integer sum that
  // doesn't depend on the clock still prints identically.
  expect(report.stdoutMatch).toBe(true);
  const effects = report.artifacts.find((a) => a.name === "effects")!;
  expect(effects.match).toBe(false);
  expect(effects.expectedNote).not.toBeNull();
  expect(report.ok).toBe(true);
});

test("basic float ops are bit-identical across wasm and native", () => {
  // Basic IEEE-754 (+, -, *, /) is deterministic across wasm and x86-64, so an
  // ordinary float program is fully byte-identical. Globals (no `local`) so the
  // float is reachable from the globals table at the final keyframe. (Only
  // transcendentals / NaN payloads can diverge — the documented FP carve-out,
  // not exercised here since we bundle no libm.)
  const src = "x = 1.5\ny = x * 2.0 + 0.25\nprint(y)\n";
  const wasm = runWasm(src);
  const native = runNative(src);
  const report = diffRuns(wasm, native);

  expect(report.deterministic).toBe(true);
  expect(report.stdoutMatch).toBe(true);
  for (const a of report.artifacts) expect(a.match).toBe(true);
  expect(report.ok).toBe(true);
});
