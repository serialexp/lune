// Client for `POST /run`, which runs the source through the *native* mahina
// binary and returns its artifacts: the dev-server middleware (vite.config.ts)
// or `mahina viz` (src/viz_server.zig), which answer the same contract. Used
// only by the differential validator — the native engine is the second opinion
// the in-browser wasm VM is checked against. A plain static host of `dist/` has
// no `/run`.

import type { RunArtifacts } from "./diff";
import type { SourceFile } from "./wasm/mahina";

interface NativeRunResponse {
  status: number;
  stdout: string;
  diagnostics: string;
  keyframe: string; // base64
  effects: string; // base64
  trace: string; // base64
  coverage: string; // base64 — the honest native coverage (real TSC cycles)
  error?: string;
}

function fromBase64(b64: string): Uint8Array {
  if (b64.length === 0) return new Uint8Array(0);
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** Run the program — `files`, of which `entry` is executed (with optional
 *  script `args` → `arg[1..]`) — through the native binary via `vite dev` or
 *  `mahina viz`. The server writes the files into a fresh directory and runs
 *  there, so `require`/`loadfile`/`dofile` read them as the wasm run does.
 *  Throws if the endpoint is unavailable (a static host of `dist/`). `signal`
 *  abandons the request (Stop); the server's own per-run timeout ends the
 *  native process. */
export async function runNative(
  files: SourceFile[],
  entry: string,
  args: string[] = [],
  signal?: AbortSignal,
): Promise<RunArtifacts & { diagnostics: string; coverage: Uint8Array }> {
  const resp = await fetch("/run", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ files, entry, args }),
    signal,
  });
  if (!resp.ok) {
    throw new Error(`POST /run: ${resp.status} ${resp.statusText} (needs \`vite dev\` or \`mahina viz\`)`);
  }
  const data = (await resp.json()) as NativeRunResponse;
  if (data.error) throw new Error(`native run failed: ${data.error}`);
  return {
    status: data.status,
    stdout: data.stdout,
    diagnostics: data.diagnostics,
    keyframe: fromBase64(data.keyframe),
    effects: fromBase64(data.effects),
    trace: fromBase64(data.trace),
    coverage: fromBase64(data.coverage ?? ""),
  };
}
