# mahina — trace visualiser

A SolidJS app for writing a mahina program, running it in the browser, and
seeing what the tracing JIT made of it. `mahina viz` serves it from the CLI
(the release CLIs embed it); `pnpm dev` serves it for development.

What it does:

- **Edit and run.** A CodeMirror editor with mahina highlighting and live
  compile diagnostics. Run (wasm) executes the program in a Web Worker on the
  wasm VM and shows its output; a runtime error is squiggled at its source
  location with a traceback. Stop ends a runaway program. Script arguments go
  in the args box (`arg[1..]`).
- **Several files.** A program is a set of files in tabs, paths relative to
  the program's directory: the entry (▶) is what Run executes, and the rest
  are what its `require`/`loadfile`/`dofile` read (`require('lib.util')` reads
  `lib/util.mah`). + adds a file, double-click renames, × closes, "Run this
  file" makes the shown tab the entry. Opening files adds them as tabs (the
  first replaces the untouched starter program). Every location the UI shows
  — a runtime error, a traceback frame, a replay step, a trace row, a coverage
  stripe — names its file, and showing it switches to that tab; a string
  `load` compiled appears as a read-only tab of its own.
- **Step replay.** Replay re-runs the recorded effect log to any instruction
  (or line) of the last run, deterministically: the current line, the
  bytecode with the pending pc, output so far, the call chain, locals (dead
  registers marked) and the globals the program set. Code that a native runs
  (a `pcall` body, a `require`d module's top level, a sort comparator, a
  metamethod) can't be paused yet: stepping skips it, and the panel says how
  many steps that was (`../docs/design/68-nested-suspension.md`).
- **Trace IR.** Every trace the run recorded: anchor, entry slots and the
  optimised SSA body (as `mahina --dump-traces` prints it), with an animation
  of each executed trace's per-iteration events (values, guards, commits,
  exits). Each instruction shows the source line it was recorded from
  (inlined callees included): hover a row to mark that line in the editor,
  click to jump there; putting the editor cursor on a line marks its rows.
  This needs the traces of a run of the editor's current source — a loaded
  `.mahinatrace` isn't mapped.
- **JIT coverage.** How the run's loop iterations split between native code,
  traced-but-interpreted, and no trace; the editor stripes each loop line the
  same way (hover for its counts).
- **Run both + diff.** Runs the program on the wasm VM *and* the native
  binary (`POST /run`, answered by `mahina viz` or the dev server) and
  compares every artifact byte for byte — two engines agreeing is the
  determinism check (`../docs/design/02-determinism.md`). It also gives the
  native run's time split, which wasm (no cycle counter) can't.
- **Open a `.mahinatrace`** from `mahina --emit-traces` to inspect its traces
  (structure only: the file holds no execution log).

Keyboard: Ctrl/⌘+Enter runs (with Shift: Run both), Esc stops a run. With a
replay open: Space plays, ←/→ step, Home/End jump, Esc closes.

## Stack

Vite + SolidJS, installed with pnpm (the version `package.json`'s
`packageManager` pins; Node >= 22.13). Bun is the test runner only; never
`bun install` here, which lays a second dependency tree beside pnpm's. The binary
decoder is **generated** from
`../schema/trace.json` by binschema and **vendored** under `src/gen/` (committed
output — no build-time dependency on the binschema repo).

## Develop

```sh
pnpm install
pnpm dev           # vite dev server; open the printed URL
pnpm build         # tsc --noEmit && vite build  → dist/
pnpm test          # `bun test`: cross-language decode + disasm + store tests
pnpm smoke:browser <mahina>   # drive `mahina viz` in headless Chrome (e2e/)
```

`smoke:browser` needs a CLI with the UI embedded (`just cli`) and a system
Chrome; CI runs it on every CLI build.

`mahina viz [script] [trace.mahinatrace]` serves a built copy of this app from
the CLI itself, `POST /run` included (`just cli` builds CLIs with it embedded;
see `src/viz_server.zig`). Given a script, it opens that program: the script as
the entry, plus the source files (`.mah`/`.mahina`/`.lua`) under its directory
as tabs (`GET /project`; hidden directories, `node_modules`, `zig-cache` and
`zig-out` are skipped, and the listing stops at 256 files / 8 MiB). `POST /run`
takes the whole program (`{files, entry, args}`) and runs the native binary on
it in a scratch directory.

Load a trace via the “Open .mahinatrace…” button, drag-and-drop, or a `?src=<url>`
deep link (e.g. `…/?src=/my-trace.mahinatrace`) that auto-loads on open. Generate
one:

```sh
# from the repo root
zig build
./zig-out/bin/mahina --emit-traces /tmp/out.mahinatrace your-hot-loop.lua
```

## Layout

- `src/gen/` — **vendored, generated** TS decoder + binschema runtime. Do not
  edit by hand; regenerate with `../tools/regen-trace-schema.sh` (emits both the
  Zig and TS codecs from the one schema).
- `src/enums.ts` — wire-ordinal → name tables for `op`/`ty`/`tag`, mirroring the
  Zig enums. Pinned by the contract test in `../src/traceser.zig`.
- `src/decode.ts` — strict wrapper over the generated decoders (a file that
  isn't a `.mahinatrace` fails with a reason).
- `src/disasm.ts` — decoded trace → view-model + text (mirrors `trace.zig`'s
  `writeTrace`).
- `src/store.ts` — the SolidJS store: every piece of app state and the
  actions on it (components read `state` and call these; no prop drilling).
- `src/wasm/` — the wasm VM binding (`mahina.ts`), the Web Worker that hosts
  it, and the main-thread client (`mahina-client.ts`, which also stops it).
- `src/native.ts` — the `POST /run` client for Run both.
- `src/diff.ts`, `src/snapshot.ts`, `src/exec.ts` — the wasm-vs-native
  comparison, the keyframe → globals/locals view, the trace-animation stream.
- `src/editor/` — the CodeMirror editor, mahina language mode and linter.
- `src/components/` — `TraceList`/`TraceView` (the trace panes),
  `ReplayPanel`, `CoveragePanel`, `FileTabs` (the program's files).
- `src/paths.ts` — program-relative path normalization, mirroring
  `../src/relpath.zig` so the UI, the wasm VM and `mahina viz` agree on which
  file `./lib/util.mah` is.
- `fixtures/` — `counting-loop.lua` + the committed `counting-loop.mahinatrace`
  cross-language fixture.
- `test/` — `bun test` specs.
- `e2e/browser-smoke.ts` — the headless-Chrome smoke test (`pnpm smoke:browser`).

## Regenerating the decoder

```sh
# from the repo root; BINSCHEMA_DIR defaults to ~/Projects/binschema
tools/regen-trace-schema.sh
```

This regenerates both `src/gen/` (Zig, for the VM) and `viz/src/gen/` (TS, here)
from `schema/trace.json`, stamping the binschema commit into each `PROVENANCE.txt`.
