// Client for the dev-server `POST /run` middleware (vite.config.ts), which runs
// the source through the *native* mahina binary and returns its artifacts. Used
// only by the differential validator — the native engine is the second opinion
// the in-browser wasm VM is checked against. There is no production backend;
// this works only under `vite dev`.

import type { RunArtifacts } from "./diff";

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

/** Run `source` (with optional script `args` → `arg[1..]`) through the native
 *  binary via the dev server. Throws if the endpoint is unavailable (e.g. running
 *  against a static build, not `vite dev`). */
export async function runNative(source: string, args: string[] = []): Promise<RunArtifacts & { diagnostics: string; coverage: Uint8Array }> {
  const resp = await fetch("/run", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ source, args }),
  });
  if (!resp.ok) {
    throw new Error(`POST /run: ${resp.status} ${resp.statusText} (is the dev server running?)`);
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
