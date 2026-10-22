// Browser smoke test for `mahina viz`: drive the served page in headless Chrome
// the way a user does, and fail on anything that would leave them stuck.
// `tools/cli-smoke.sh` checks every asset is *served*; this checks the page
// *works* — v0.1.2 served `/mahina.wasm` fine, but the worker fetched
// `/assets/mahina.wasm` and every Run button was dead.
//
//   pnpm run smoke:browser <mahina-binary>
//
// (Plain `node` runs this TypeScript file: it needs Node >= 22.18, which
// strips types itself.) The binary must embed the UI (`-Dviz-dist`), as the
// release CLIs from tools/mahina-cli.sh do.
//
// It records a trace with the binary, serves it with `mahina viz --no-open`,
// and checks, in one page:
//   - the trace named in the page URL (`?src=…`) loads;
//   - Run (wasm) runs an edited program and prints its output;
//   - Run both + diff (wasm VM against the binary's POST /run) agrees;
//   - Replay opens on that run;
//   - no request fails and the page throws nothing.
//
// Chrome is the system install (Playwright's `chrome` channel), which GitHub's
// runners carry; `MAHINA_SMOKE_CHROME` points it at another executable.

import { spawn, execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { chromium } from "playwright-core";

const mahina = process.argv[2];
if (!mahina) {
  console.error("usage: node e2e/browser-smoke.ts <mahina-binary>");
  process.exit(2);
}
const exe = resolve(mahina);

const work = mkdtempSync(join(tmpdir(), "browser-smoke-"));
writeFileSync(join(work, "loop.mahina"), "local s = 0\nfor i = 1, 100000 do s = s + i end\nprint(s)\n");
execFileSync(exe, ["--emit-traces", "t.mahinatrace", "loop.mahina"], { cwd: work, stdio: "ignore" });

let serverLog = "";
const server = spawn(exe, ["viz", "--no-open", "--port", "0", "t.mahinatrace"], { cwd: work });
let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;
const problems: string[] = [];
try {
  const pageUrl = await new Promise<string>((ok, bad) => {
    const timer = setTimeout(() => bad(new Error("mahina viz printed no URL in 10 s")), 10_000);
    const read = (chunk: Buffer) => {
      serverLog += chunk.toString();
      const m = /serving on (http:\/\/\S+)/.exec(serverLog);
      if (m) {
        clearTimeout(timer);
        ok(m[1]);
      }
    };
    server.stdout.on("data", read);
    server.stderr.on("data", read);
    server.on("exit", (code) => bad(new Error(`mahina viz exited (${code}) before serving`)));
  });

  browser = await chromium.launch(
    process.env.MAHINA_SMOKE_CHROME ? { executablePath: process.env.MAHINA_SMOKE_CHROME } : { channel: "chrome" },
  );
  const page = await browser.newPage();
  // The worker's requests (the wasm fetch) are the context's, not the page's.
  page.context().on("response", (r) => {
    if (r.status() >= 400 && new URL(r.url()).pathname !== "/favicon.ico") {
      problems.push(`HTTP ${r.status()} ${r.url()}`);
    }
  });
  page.context().on("requestfailed", (r) => problems.push(`request failed: ${r.url()} (${r.failure()?.errorText})`));
  page.on("pageerror", (e) => problems.push(`page error: ${e.message}`));
  page.on("console", (m) => {
    if (m.type() === "error" && !m.location().url.endsWith("/favicon.ico")) {
      problems.push(`console error: ${m.text()}`);
    }
  });
  // One user-visible step. A step fails on its own check *or* on any failed
  // request / page error that happened while it ran.
  const step = async (what: string, check: () => Promise<unknown>) => {
    let why = "";
    try {
      await check();
    } catch (e) {
      why = (e as Error).message.split("\n")[0];
    }
    if (why || problems.length) {
      throw new Error([`${what}${why ? `: ${why}` : ""}`, ...problems].join("\n  "));
    }
    console.log(`browser-smoke: ok   ${what}`);
  };
  const timeout = 30_000;

  await step("the page opens on the trace in its URL", async () => {
    await page.goto(pageUrl, { waitUntil: "networkidle" });
    await page.getByText(/t\.mahinatrace/).first().waitFor({ timeout });
    await page.getByText(/· [1-9]\d* trace\(s\)/).first().waitFor({ timeout });
  });

  await step("Run (wasm) runs the edited program", async () => {
    await page.locator(".cm-content").click();
    await page.keyboard.press("ControlOrMeta+A");
    await page.keyboard.insertText("local s = 0\nfor i = 1, 1000 do s = s + i * 2 end\nprint('sum', s)\n");
    await page.getByRole("button", { name: "Run (wasm)" }).click();
    await page.locator(".run-stdout").filter({ hasText: "sum\t1001000" }).waitFor({ timeout });
  });

  await step("a trace's IR rows map back to source lines", async () => {
    // The loop is all on line 2: the trace list says so, and hovering the
    // body's `mul` marks line 2 in the editor.
    await page.locator(".trace-row .anchor").filter({ hasText: "from line 2" }).waitFor({ timeout });
    await page.locator("table.ir tbody tr", { has: page.locator("td.op", { hasText: /^mul$/ }) }).first().hover();
    const marked = (await page.locator(".cm-trace-line").innerText()).trim();
    if (!marked.startsWith("for i = 1, 1000")) throw new Error(`marked editor line is "${marked}"`);
  });

  await step("Run both + diff finds wasm and native agree", async () => {
    await page.getByRole("button", { name: "Run both + diff" }).click();
    const verdict = page.locator(".diff-verdict");
    await verdict.waitFor({ timeout });
    const text = (await verdict.innerText()).trim();
    if (!text.startsWith("✓")) throw new Error(`verdict is "${text}"`);
  });

  await step("Replay opens on the last run", async () => {
    await page.getByRole("button", { name: "Replay" }).click();
    await page.locator(".replay").waitFor({ timeout });
  });

  // A replay paused late in a long program, then a shorter file loaded: the
  // replay closes and the next Run is clean (it used to throw CodeMirror's
  // "Position … is out of range" from a stale replay-line decoration).
  await step("loading a source file mid-replay closes the replay", async () => {
    const lines = Array.from({ length: 30 }, (_, i) => `local v${i} = ${i}`).join("\n");
    await page.locator(".cm-content").click();
    await page.keyboard.press("ControlOrMeta+A");
    await page.keyboard.insertText(`${lines}\nprint(v29)\n`);
    await page.getByRole("button", { name: "Run (wasm)" }).click();
    await page.locator(".run-stdout").filter({ hasText: "29" }).waitFor({ timeout });
    await page.getByRole("button", { name: "Replay" }).click();
    const slider = page.locator(".replay input[type=range]");
    await slider.waitFor({ timeout });
    await slider.fill(String(Math.max(0, Number(await slider.getAttribute("max")) - 2)));
    await page.locator(".cm-replay-line").waitFor({ timeout });
    writeFileSync(join(work, "short.mahina"), "print('short')\n");
    await page.locator("section.editor input[type=file]").setInputFiles(join(work, "short.mahina"));
    await page.locator(".replay").waitFor({ state: "detached", timeout });
    await page.getByRole("button", { name: "Run (wasm)" }).click();
    await page.locator(".run-stdout").filter({ hasText: "short" }).waitFor({ timeout });
  });

  await step("Stop ends a runaway program, and the next Run works", async () => {
    await page.locator(".cm-content").click();
    await page.keyboard.press("ControlOrMeta+A");
    await page.keyboard.insertText("while true do end\n");
    await page.getByRole("button", { name: "Run (wasm)" }).click();
    await page.getByRole("button", { name: "Stop" }).click({ timeout });
    await page.locator(".run-error").filter({ hasText: "stopped" }).waitFor({ timeout });
    await page.locator(".cm-content").click();
    await page.keyboard.press("ControlOrMeta+A");
    await page.keyboard.insertText("print('after stop')\n");
    await page.getByRole("button", { name: "Run (wasm)" }).click();
    await page.locator(".run-stdout").filter({ hasText: "after stop" }).waitFor({ timeout });
  });

  await step("a binary file is refused as source", async () => {
    writeFileSync(join(work, "blob.mahina"), new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0, 1, 2]));
    await page.locator("section.editor input[type=file]").setInputFiles(join(work, "blob.mahina"));
    await page.locator(".source-error").filter({ hasText: "not a text file" }).waitFor({ timeout });
  });
  console.log("browser-smoke: PASS");
} catch (e) {
  console.error(`browser-smoke: FAIL: ${(e as Error).message}`);
  if (serverLog) console.error(`--- mahina viz output:\n${serverLog}`);
  process.exitCode = 1;
} finally {
  await browser?.close();
  server.kill();
  rmSync(work, { recursive: true, force: true });
}
