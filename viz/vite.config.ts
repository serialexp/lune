import { defineConfig, type Plugin } from "vite";
import solid from "vite-plugin-solid";
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";

// The in-browser VM artifact, built by `zig build wasm` at the repo root. It
// lives outside viz/ (it is not a source asset), so this plugin bridges it into
// the app: served at `/lune.wasm` in dev, copied into `dist/` at build time.
const wasmPath = fileURLToPath(new URL("../zig-out/bin/lune.wasm", import.meta.url));

// The native CLI, built by `zig build` at the repo root. The differential
// validator (Phase 7 v3) runs it as a dev-server subprocess to compare its
// artifacts against the in-browser wasm VM. Dev/CI tool only — not a production
// feature (there is no production backend).
const nativeBin = fileURLToPath(new URL("../zig-out/bin/lune", import.meta.url));

// Read a small request body to a string (the source chunk).
function readBody(req: import("node:http").IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (c) => chunks.push(c as Buffer));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

// Run `source` through the native binary with all three emit flags and collect
// the artifact bytes (base64) + the program's stdout. Mirrors the flag set the
// wasm entry uses internally, so the two are comparable.
function runNative(source: string): {
  status: number;
  stdout: string;
  diagnostics: string;
  keyframe: string;
  effects: string;
  trace: string;
} {
  const dir = mkdtempSync(join(tmpdir(), "lune-diff-"));
  try {
    const src = join(dir, "prog.lune");
    const kf = join(dir, "k.lunesnap");
    const ef = join(dir, "e.luneeff");
    const tr = join(dir, "t.lunetrace");
    writeFileSync(src, source);
    const r = spawnSync(
      nativeBin,
      ["--emit-traces", tr, "--emit-keyframe", kf, "--emit-effects", ef, src],
      { encoding: "buffer", timeout: 15_000 },
    );
    const b64 = (p: string): string => {
      try {
        return readFileSync(p).toString("base64");
      } catch {
        return "";
      }
    };
    return {
      status: r.status === 0 ? 0 : 1,
      stdout: (r.stdout ?? Buffer.alloc(0)).toString("utf8"),
      diagnostics: (r.stderr ?? Buffer.alloc(0)).toString("utf8"),
      keyframe: b64(kf),
      effects: b64(ef),
      trace: b64(tr),
    };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function luneWasm(): Plugin {
  return {
    name: "lune-wasm",
    configureServer(server) {
      // Dev: serve the freshly-built wasm straight from zig-out (no copy step).
      server.middlewares.use("/lune.wasm", (_req, res) => {
        try {
          const bytes = readFileSync(wasmPath);
          res.setHeader("Content-Type", "application/wasm");
          res.end(bytes);
        } catch {
          res.statusCode = 404;
          res.end("lune.wasm not found — run `zig build wasm` at the repo root.");
        }
      });

      // Dev: the differential validator's native side. POST the source; get back
      // the native binary's artifacts (base64) + stdout for byte-comparison
      // against the wasm run. Dev/CI only.
      server.middlewares.use("/run", (req, res, next) => {
        if (req.method !== "POST") return next();
        void (async () => {
          try {
            const source = await readBody(req);
            const result = runNative(source);
            res.setHeader("Content-Type", "application/json");
            res.end(JSON.stringify(result));
          } catch (e) {
            res.statusCode = 500;
            res.setHeader("Content-Type", "application/json");
            res.end(JSON.stringify({ error: e instanceof Error ? e.message : String(e) }));
          }
        })();
      });
    },
    generateBundle() {
      // Build: emit the wasm as a top-level asset so `./lune.wasm` resolves.
      this.emitFile({
        type: "asset",
        fileName: "lune.wasm",
        source: readFileSync(wasmPath),
      });
    },
  };
}

// Static SPA + an in-browser wasm VM. The visualiser decodes `.lunetrace`
// artifacts and can also author + run lune programs in-browser (Phase 7 v3).
export default defineConfig({
  plugins: [solid(), luneWasm()],
  base: "./",
  build: { target: "esnext", outDir: "dist" },
});
