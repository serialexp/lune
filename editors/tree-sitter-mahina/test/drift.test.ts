// The drift check (doc 74 §13.2). The Tree-sitter grammar is a second parser,
// kept only for presentation, so it must never reject a program mahina accepts.
// Every mahina source the repository tracks (`.lua` / `.mah`, outside vendor/)
// is a program mahina's own tests run; the grammar must parse each without an
// ERROR node. A construct added to src/parser.zig without a grammar change
// lands here first.
//
// Requires `pnpm install` in this directory (it fetches the tree-sitter CLI);
// run it with `pnpm drift` (Vitest; CI's "viz and grammar tests" leg).

import { expect, test } from "vitest";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const here = fileURLToPath(new URL("..", import.meta.url));
const repo = fileURLToPath(new URL("../../..", import.meta.url));
const cli = `${here}node_modules/.bin/tree-sitter`;

function trackedSources(): string[] {
  const r = spawnSync("git", ["-C", repo, "ls-files", "*.lua", "*.mah"], { encoding: "utf8" });
  if (r.status !== 0) throw new Error(`git ls-files failed: ${r.stderr}`);
  return r.stdout
    .split("\n")
    .filter((p) => p !== "" && !p.startsWith("vendor/"));
}

test("[REQ-113.4] the grammar parses the template sample, as a template tree, without an ERROR node", () => {
  // tests/lang/interpolation.lua holds every template form src/parser.zig
  // accepts and is run by mahina itself; the grammar must read each as a template.
  const sample = `${repo}/tests/lang/interpolation.lua`;
  const r = spawnSync(cli, ["parse", sample], { cwd: here, encoding: "utf8" });
  expect(r.status).toBe(0);
  expect(r.stdout).toContain("(template ");
  expect(r.stdout).toContain("(template_hole ");
  expect(r.stdout).toContain("(template_escape ");
  expect(r.stdout).not.toContain("ERROR");
});

test("the grammar parses every tracked mahina source without an ERROR node", () => {
  const sources = trackedSources();
  expect(sources.length).toBeGreaterThan(0);
  const rejected: string[] = [];
  for (const rel of sources) {
    const r = spawnSync(cli, ["parse", "-q", `${repo}/${rel}`], { cwd: here, encoding: "utf8" });
    if (r.status !== 0) rejected.push(rel);
  }
  expect(rejected).toEqual([]);
}, 120_000);

test("an actual syntax error is an ERROR node (the check can fail)", () => {
  const r = spawnSync(cli, ["parse", "-q", "/dev/stdin"], { cwd: here, input: "local x = = 1\n", encoding: "utf8" });
  expect(r.status).not.toBe(0);
});
