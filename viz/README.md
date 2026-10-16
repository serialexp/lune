# mahina — trace inspector (Phase 7, v1)

A SolidJS app that loads a `.mahinatrace` artifact (emitted by `mahina
--emit-traces`) and renders its trace IR: per-trace anchor, entry slots, the
straight-line SSA body (mirroring `mahina --dump-traces`), the constant pool, and
the loop-carried exit stores.

**Scope (v1):** a *static inspector*. The on-disk artifact contains the committed
trace IR, not a recorded execution log — so this shows trace *structure*, not yet
time-stepping. Time-travel stepping waits on the effect-log / keyframe work (see
`../docs/design/04-snapshot-replay-schema.md`).

## Stack

Bun + Vite + SolidJS. The binary decoder is **generated** from
`../schema/trace.json` by binschema and **vendored** under `src/gen/` (committed
output — no build-time dependency on the binschema repo).

## Develop

```sh
bun install
bun run dev        # vite dev server; open the printed URL
bun run build      # tsc --noEmit && vite build  → dist/
bun test           # cross-language decode + disasm + store tests
```

`mahina viz [trace.mahinatrace]` serves a built copy of this app from the CLI
itself, `POST /run` included (`just cli` builds CLIs with it embedded; see
`src/viz_server.zig`).

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
- `src/decode.ts` — thin wrapper over the generated decoder.
- `src/disasm.ts` — decoded trace → view-model + text (mirrors `trace.zig`'s
  `writeTrace`).
- `src/store.ts` — SolidJS store (loaded file, traces, selection).
- `src/components/` — `TraceList` (left pane), `TraceView` (right pane).
- `fixtures/` — `counting-loop.lua` + the committed `counting-loop.mahinatrace`
  cross-language fixture.
- `test/` — `bun test` specs.

## Regenerating the decoder

```sh
# from the repo root; BINSCHEMA_DIR defaults to ~/Projects/binschema
tools/regen-trace-schema.sh
```

This regenerates both `src/gen/` (Zig, for the VM) and `viz/src/gen/` (TS, here)
from `schema/trace.json`, stamping the binschema commit into each `PROVENANCE.txt`.
