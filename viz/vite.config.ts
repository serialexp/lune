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
function runNative(source: string, args: string[]): {
  status: number;
  stdout: string;
  diagnostics: string;
  keyframe: string;
  effects: string;
  trace: string;
  coverage: string;
} {
  const dir = mkdtempSync(join(tmpdir(), "lune-diff-"));
  try {
    const src = join(dir, "prog.lune");
    const kf = join(dir, "k.lunesnap");
    const ef = join(dir, "e.luneeff");
    const tr = join(dir, "t.lunetrace");
    const cov = join(dir, "c.lunecov");
    writeFileSync(src, source);
    const b64 = (p: string): string => {
      try {
        return readFileSync(p).toString("base64");
      } catch {
        return "";
      }
    };
    // Script args go AFTER the source path — the native CLI fills `arg[1..]` from
    // them (arg[0] is the src path). The wasm run gets the same arg[1..] (its
    // arg[0] is the in-browser script name); the differential validator cancels
    // the arg[0] divergence structurally (keyframeSansArg), so arg[1..] must
    // match for the keyframe compare to pass.
    const r = spawnSync(
      nativeBin,
      ["--emit-traces", tr, "--emit-keyframe", kf, "--emit-effects", ef, src, ...args],
      { encoding: "buffer", timeout: 15_000 },
    );
    // A SECOND, separate run purely to capture the honest native coverage split
    // (real TSC cycles): `--jit-native` so traces run as native machine code (the
    // wasm playground can't — no codegen), `--emit-coverage` for the artifact. Its
    // keyframe/effects/trace are irrelevant here; only the diff run above feeds the
    // determinism compare, which stays a pure tier-0 check untouched by this
    // observation run. Best-effort: a failure just leaves coverage empty (the
    // panel keeps its wasm iteration split, time column grayed).
    spawnSync(
      nativeBin,
      ["--jit-native", "--emit-coverage", cov, src, ...args],
      { encoding: "buffer", timeout: 15_000 },
    );
    return {
      status: r.status === 0 ? 0 : 1,
      stdout: (r.stdout ?? Buffer.alloc(0)).toString("utf8"),
      diagnostics: (r.stderr ?? Buffer.alloc(0)).toString("utf8"),
      keyframe: b64(kf),
      effects: b64(ef),
      trace: b64(tr),
      coverage: b64(cov),
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
            const body = await readBody(req);
            // Body is JSON `{ source, args }`. Tolerate a bare string body (older
            // clients / manual POSTs) as source with no args.
            let source = body;
            let args: string[] = [];
            try {
              const parsed = JSON.parse(body) as { source?: string; args?: string[] };
              if (parsed && typeof parsed === "object" && typeof parsed.source === "string") {
                source = parsed.source;
                args = Array.isArray(parsed.args) ? parsed.args.map(String) : [];
              }
            } catch {
              // not JSON — treat the whole body as source
            }
            const result = runNative(source, args);
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
