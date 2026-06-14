import { defineConfig, type Plugin } from "vite";
import solid from "vite-plugin-solid";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

// The in-browser VM artifact, built by `zig build wasm` at the repo root. It
// lives outside viz/ (it is not a source asset), so this plugin bridges it into
// the app: served at `/lune.wasm` in dev, copied into `dist/` at build time.
const wasmPath = fileURLToPath(new URL("../zig-out/bin/lune.wasm", import.meta.url));

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
