import { defineConfig, type Plugin } from "vite";
import solid from "vite-plugin-solid";
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { normalizePath } from "./src/paths";

// The in-browser VM artifact, built by `zig build wasm` at the repo root. It
// lives outside viz/ (it is not a source asset), so this plugin bridges it into
// the app: served at `/mahina.wasm` in dev, copied into `dist/` at build time.
// `MAHINA_WASM` overrides the path (tools/mahina-cli.sh builds its own).
const wasmPath =
  process.env.MAHINA_WASM ?? fileURLToPath(new URL("../zig-out/bin/mahina.wasm", import.meta.url));

// The native CLI, built by `zig build` at the repo root. The differential
// validator (Phase 7 v3) runs it as a dev-server subprocess to compare its
// artifacts against the in-browser wasm VM. Outside `vite dev`, `mahina viz`
// (src/viz_server.zig) answers the same `/run` contract from the CLI itself.
const nativeBin = fileURLToPath(new URL("../zig-out/bin/mahina", import.meta.url));

// Read a small request body to a string (the source chunk).
function readBody(req: import("node:http").IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (c) => chunks.push(c as Buffer));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

/** The program a `/run` request carries: its files (paths relative to the
 *  program's directory) and which of them to run. */
interface RunProgram {
  files: { path: string; text: string }[];
  entry: string;
  args: string[];
}

/** Decode and check a `/run` body: JSON `{ files, entry, args }`. Every path
 *  must normalize (relative, inside the program's directory) and the entry
 *  must be one of the files — the server writes them all under a fresh temp
 *  directory, so a path climbing out of it is refused, never written. */
function parseRunBody(body: string): RunProgram {
  const parsed = JSON.parse(body) as { files?: unknown; entry?: unknown; args?: unknown };
  if (!Array.isArray(parsed.files) || typeof parsed.entry !== "string") throw new Error("/run wants JSON { files, entry, args }");
  const files: { path: string; text: string }[] = [];
  for (const f of parsed.files as { path?: unknown; text?: unknown }[]) {
    if (typeof f?.path !== "string" || typeof f?.text !== "string") throw new Error("/run: each file is { path, text }");
    const path = normalizePath(f.path);
    if (path === null) throw new Error(`/run: ${f.path} is not a path inside the program's directory`);
    files.push({ path, text: f.text });
  }
  const entry = normalizePath(parsed.entry);
  if (entry === null || !files.some((f) => f.path === entry)) throw new Error(`/run: entry ${parsed.entry} is not among the files`);
  const args = Array.isArray(parsed.args) ? parsed.args.map(String) : [];
  return { files, entry, args };
}

// Run the program through the native binary with all three emit flags and
// collect the artifact bytes (base64) + the program's stdout. Mirrors the flag
// set the wasm entry uses internally, so the two are comparable. The files are
// written under a temp directory the binary runs in, so `require`/`loadfile`/
// `dofile` resolve their relative paths there, as the wasm run's file set does.
function runNative(program: RunProgram): {
  status: number;
  stdout: string;
  diagnostics: string;
  keyframe: string;
  effects: string;
  trace: string;
  coverage: string;
} {
  const dir = mkdtempSync(join(tmpdir(), "mahina-diff-"));
  const { files, entry, args } = program;
  try {
    // The program in its own directory, the artifacts beside it.
    const prog = join(dir, "prog");
    const kf = join(dir, "k.mahinasnap");
    const ef = join(dir, "e.mahinaeff");
    const tr = join(dir, "t.mahinatrace");
    const cov = join(dir, "c.mahinacov");
    for (const f of files) {
      const path = join(prog, f.path);
      mkdirSync(dirname(path), { recursive: true });
      writeFileSync(path, f.text);
    }
    // The entry by its relative path: that is the native run's `arg[0]`, as
    // the wasm run's is the entry's path.
    const src = entry;
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
      { encoding: "buffer", timeout: 15_000, cwd: prog },
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
      { encoding: "buffer", timeout: 15_000, cwd: prog },
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

function mahinaWasm(): Plugin {
  return {
    name: "mahina-wasm",
    configureServer(server) {
      // Dev: serve the freshly-built wasm straight from zig-out (no copy step).
      server.middlewares.use("/mahina.wasm", (_req, res) => {
        try {
          const bytes = readFileSync(wasmPath);
          res.setHeader("Content-Type", "application/wasm");
          res.end(bytes);
        } catch {
          res.statusCode = 404;
          res.end("mahina.wasm not found — run `zig build wasm` at the repo root.");
        }
      });

      // Dev: the differential validator's native side. POST the program; get
      // back the native binary's artifacts (base64) + stdout for
      // byte-comparison against the wasm run. Dev/CI only.
      server.middlewares.use("/run", (req, res, next) => {
        if (req.method !== "POST") return next();
        void (async () => {
          try {
            const result = runNative(parseRunBody(await readBody(req)));
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
      // Build: emit the wasm as a top-level asset so `./mahina.wasm` resolves.
      this.emitFile({
        type: "asset",
        fileName: "mahina.wasm",
        source: readFileSync(wasmPath),
      });
    },
  };
}

// Static SPA + an in-browser wasm VM. The visualiser decodes `.mahinatrace`
// artifacts and can also author + run mahina programs in-browser (Phase 7 v3).
export default defineConfig({
  plugins: [solid(), mahinaWasm()],
  base: "./",
  build: { target: "esnext", outDir: "dist" },
});
