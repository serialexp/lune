# 74 — A language server (`mahina lsp`) — Design

Status: draft, not yet implemented. Direction decided 2026-10-27 (server in
Zig, as a subcommand of the CLI binary; design doc before code). Every
question in §11 is open.
Owner: claude (coral-raven)
Last updated: 2026-10-27

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole phases to Done once everything inside them is checked.

### Done

- [x] **D1 — where the server lives** (§3): decided by Bart 2026-10-27, a
  `mahina lsp` subcommand in the CLI binary, written in Zig, sharing the
  frontend directly. A TypeScript server over the wasm `mahina_check` was
  the alternative.
- [x] **D2 — design first** (this doc): decided by Bart 2026-10-27.

### Outstanding

- [ ] **Q1–Q11** (§11): every open question.
- [ ] **P0 — transport and lifecycle** (§5): `src/lsp/jsonrpc.zig`
  (`Content-Length` framing over stdio, the only `std.json` user), the
  `initialize`/`initialized`/`shutdown`/`exit` handshake, position-encoding
  negotiation, the document store (`didOpen`/`didChange`/`didClose`),
  tested end to end over in-memory streams.
- [ ] **P1 — diagnostics** (§6): `textDocument/publishDiagnostics` from the
  same parse + compile path as `mahina_check`; byte span → LSP position
  through a per-document line index; the parse-error cascade fixed (Q7).
- [ ] **P1 bench** (§9): `bench_lsp.zig` measuring the didChange →
  diagnostics path on a generated 10k-line and 100k-line file; budget in
  §9.
- [ ] **P2 — syntactic features** (§7.1): semantic tokens (full), document
  symbols, folding ranges, selection ranges.
- [ ] **P3 — the binding index** (§7.2): a resolver that records every
  name use → its declaration span; definition, references, document
  highlight, prepareRename/rename for locals, upvalues and chunk globals.
- [ ] **P4 — stdlib knowledge** (§7.3): hover, completion (keywords,
  in-scope names, builtins, `lib.` members), signature help, driven by one
  generated table (Q4).
- [ ] **P5 — cross-file** (§7.4): resolve `require("a.b")` statically
  through the workspace's `package.path` (Q5); go-to-definition into the
  module; workspace symbols; diagnostics for unresolvable requires.
- [ ] **P6 — editor clients** (§8): a VS Code extension (launches `mahina
  lsp`, ships a TextMate grammar for first-paint highlighting) and
  Neovim/Helix configuration snippets in the docs.
- [ ] **P7 — JIT lenses** (§7.6): on an explicit command, run the file
  under `--jit-stats`/coverage and show per-loop tier, abort reason and
  residency as inlay hints / code lenses.
- [ ] **P8 — time-travel debugging** (§7.7): a `mahina dap` Debug Adapter
  Protocol server on top of keyframes + the effect log: breakpoints, step,
  and reverse step/continue. Probably gets its own doc (Q9).
- [ ] **Defer — inference (tier 5)** (§7.5): table-shape and annotation-
  driven types for member completion and hover. Not before P4 has shipped
  and the type annotations (doc 00) are given a semantics.

## 1. Why this exists

mahina is usable from the viz editor: a CodeMirror 6 mode keyed to the real
lexer, live validation through the compile-only wasm entry `mahina_check`,
located runtime errors and a backtrace (doc 00, Phase 7 v4–v6). Outside the
browser it has nothing: write a `.lua`-shaped file in VS Code, Neovim or
Helix and you get, at best, a borrowed Lua mode that does not know `??`,
`~>>`, the reserved type annotations or the unknown-global lint, and points
at the wrong things.

The Language Server Protocol is what every one of those editors speaks.
One server gives all of them diagnostics, navigation, rename, hover and
completion. This doc is the contract for that server, and for the two
things only mahina can offer on top of it: showing what the JIT did with a
loop, right on the loop, and stepping a recorded run *backwards*.

## 2. Goals

- **One frontend.** The server's diagnostics are the compiler's
  diagnostics, byte for byte, the same promise `mahina_check` made for the
  browser. No second grammar, no second scoping model that can drift
  (Q3).
- **Every LSP editor.** Plain LSP 3.17 over stdio; nothing editor-specific
  in the server.
- **Fast on large files** (Rule 20, §9). Diagnostics on a 10k-line file
  feel immediate; nothing is quadratic in document or workspace size.
- **Allocation discipline** (Rule Z-4). The server takes an allocator;
  per-document state lives in a per-version arena and is freed in one
  shot when the next version replaces it.
- **Churn confined** (Rule Z-2). `std.json`, stdio and the protocol
  framing live in `src/lsp/jsonrpc.zig`; the analysis code never sees
  JSON.

## 3. Non-goals (v1)

- **A type checker.** Tier 5 (§7.5) is deferred until the annotations
  mean something.
- **Formatting.** A formatter needs a comment-preserving tree (the lexer
  drops trivia today); it is a separate project.
- **Running user code implicitly.** Only P7 runs anything, and only on an
  explicit command (Q8).
- **Lua compatibility shims.** The server analyses mahina, not Lua 5.4.

## 4. Module layout

```
src/lsp/
  jsonrpc.zig    framing + std.json (de)serialisation; the only churny file
  protocol.zig   the LSP structs we use (Position, Range, Diagnostic, ...),
                 plain Zig types, no JSON knowledge
  server.zig     request dispatch, lifecycle, capabilities
  documents.zig  open-document store: text, version, line index, analysis
  position.zig   byte offset <-> (line, character) in the negotiated encoding
  analysis.zig   parse + compile + binding index for one document version
  resolve.zig    the binding index (P3)
  stdlib_db.zig  generated builtin table for hover/completion (P4)
src/main.zig     `lsp` subcommand, next to `viz`
```

`main.zig` already dispatches `viz` before the flag loop
(`src/main.zig:260`); `lsp` joins it there. In a stdio LSP, stdout carries
protocol messages only, so the server must never reach the diagnostic
stdout path in `src/io.zig`; logging goes to stderr or `window/logMessage`.
The CLI's `jitdbg` probes already go to stderr.

## 5. P0 — transport, lifecycle, documents

- **Framing.** `Content-Length: N\r\n\r\n` + N bytes of UTF-8 JSON. Requests
  are handled in order on one thread. Cancellation (`$/cancelRequest`) is
  honoured by dropping a request that hasn't started; analysis is fast
  enough (§9) that we don't need preemption.
- **JSON.** Zig 0.17's `std.json` has `parseFromSlice`/`Value` for input
  and `Stringify` for output (verified in the pinned
  `lib/std/json.zig`). Incoming messages are parsed into a per-message
  arena; we decode `params` into `protocol.zig` structs for the methods we
  implement and ignore unknown fields.
- **Position encoding.** LSP 3.17 lets the client offer
  `general.positionEncodings`. We pick `utf-8` when it's offered (byte
  offsets are what our spans already are; Neovim and Helix offer it) and
  fall back to the mandatory `utf-16` otherwise. `position.zig` holds a
  line-start table per document version; utf-16 columns are computed by
  walking the line's code points, so the cost is per line, not per
  document.
- **Document sync.** Q1 decides full vs incremental. Either way the store
  keeps the full text of each open version; analysis always re-parses the
  whole document (§9 explains why that's affordable).

## 6. P1 — diagnostics

The server runs what `wasm_entry.zig`'s `check` runs: parse, then (if the
tree is usable) `compileWithOptions` with the host's builtin global names,
then collects every `Diagnostic` (severity, message, byte span) and maps
spans to ranges. Debounced on `didChange` (Q1); published on
`didOpen`/`didSave` without delay.

Three facts about today's path that shape P1:

1. **Compiling needs a heap.** `compileWithOptions` interns constants into
   a `gc.Heap`, so `check` creates a whole `Vm` per call. That's fine for
   the browser; for a server that re-checks on every edit it's wasted work
   and wasted memory (Q2).
2. **Parse errors suppress the compiler entirely.** `check` only compiles
   when there are no parse errors, and the unknown-global lint only runs
   when there are no errors at all (`compiler.zig:140`). While you're in
   the middle of typing a statement, every compile-level diagnostic in the
   file disappears and then comes back, which flickers (Q7).
3. **Messages are static strings** (`diag.zig`). "expected `end`" without
   saying which `function` it closes is weaker than it could be (Q6).

## 7. Features

### 7.1 P2 — syntactic

All from the lexer and the AST, no resolution:

- **Semantic tokens** (full document): keywords, operators, numbers,
  strings, function/parameter/local declarations, globals vs locals (once
  P3 lands; before that, one `variable` class). Comments: the lexer skips
  trivia, so either the lexer grows an optional trivia-emitting mode or
  comments are left to the client's TextMate grammar (Q11).
- **Document symbols**: functions (`function a.b:c()`, `local function`),
  top-level locals, table constructors assigned to names, nested.
- **Folding ranges**: every block (`function`, `do`, `if`, `for`,
  `while`, `repeat`), table constructors and long comments.
- **Selection ranges**: the AST span ancestry of a position.

### 7.2 P3 — the binding index

The compiler already resolves every name local → upvalue → global, but
lowers the result to registers and keeps no mapping back to source. The
binding index is a per-document table:

```
Binding  { decl_span, kind: local|param|for_var|local_function|global, scope_span }
Use      { span, binding: BindingId, is_write }
```

stored as two flat arrays sorted by span start, so "what's at this
offset" is a binary search and "all uses of binding B" is a list built
once per version (no per-use allocation; Rule 20). Globals are one
binding per name per chunk, declared by their first write; a global read
with no write and no builtin is exactly the existing unknown-global
warning.

Features: definition, references, document highlight (read vs write),
prepareRename/rename (locals, params and upvalues always; globals only
within the workspace, with the cross-file caveat from P5).

Whether the index comes from the compiler itself (one scoping
implementation) or from a separate resolver pass over the AST (no
coupling to codegen) is Q3.

### 7.3 P4 — stdlib knowledge

Hover over a builtin or `lib.member`, completion of keywords, in-scope
names (from the binding index), globals and library members, and
signature help in call arguments. All of that needs one table:
name, signature, one-line description, tier
(`core`/`base-host`/`cli-binding`). The inventory CSV
(`docs/lua-stdlib-inventory.csv`) has the name, tier, status and
description but no signatures; the native registrations know arity but
not parameter names. Where the table comes from is Q4. The table is
generated at build time and embedded, so hover costs no I/O.

The host matters: a game host omits the `cli-binding` tier, so
completion and the unknown-global lint should know which host the
workspace targets (Q5).

### 7.4 P5 — cross-file

`require("a.b")` is resolved the way `package.searchPath` does it:
substitute `?` in each `package.path` template, relative to the workspace
root. The server can only do this statically for string-literal
arguments and for the default searchers; a host that installs its own
searcher is invisible to it, and the docs should say so. Resolved modules
are analysed on demand and cached per file mtime. A module's exports are
what its top-level `return` table constructor names. That covers the
common `local M = {} ... return M` shape when P3 tracks fields assigned
to `M`; anything more is tier 5.

Workspace symbols search the cached modules' document symbols.

### 7.5 Tier 5 — inference (deferred)

lua-language-server-style inference of table shapes (fields assigned to a
local table, constructor fields), propagated through locals and returns,
plus the reserved `name: Type?` annotations as declared types. That gives
member completion and typed hover. Deferred: it is a type checker in all
but name, and the annotations have no semantics yet (doc 00 reserves
the syntax only).

### 7.6 P7 — JIT lenses

An editor command ("mahina: show JIT residency") runs the current file the
way `--jit-stats` does and maps the per-anchor results back to source:

- on each loop header, an inlay hint `native 97%` / `tier-0` /
  `aborted: <reason>`, from the per-anchor iteration and TSC-cycle split
  and `--dump-aborts`;
- a code lens on the function with the residency summary;
- clearing on the next edit, because the results describe an older
  version.

This is the tool the project's own profiling rules ask for ("a bench that
stays flat gets a `--jit-stats` run before any verdict") brought into the
editor. It needs `--jit-stats` output in a machine-readable form; today
it's a human-readable stderr report. It also runs user code, so it is
explicit, runs in a child process with a timeout, and gets the CLI's
normal system switch (Q8).

### 7.7 P8 — time-travel debugging (DAP)

LSP has no debugging; the Debug Adapter Protocol does, and VS Code,
Neovim (nvim-dap) and Helix speak it. mahina already records runs
(keyframes, effect log) and replays them deterministically to a given
point (`mahina_replay(..., stop_after)` in the browser). A `mahina dap`
adapter maps that onto DAP:

- `launch` records the run, `breakpoints` stop at a line;
- `stackTrace`/`scopes`/`variables` from the stopped VM (the same frame
  walk `describeFault` does);
- `stepBack`/`reverseContinue` (DAP's `supportsStepBack`) by restoring the
  nearest earlier keyframe and replaying forward to the previous stop.
  This is the feature no Lua debugger has.

It's a second protocol with its own design questions (keyframe density
vs reverse-step latency, what "line" means once a trace is running
natively), so it probably wants its own doc (Q9). It is listed here so
the server layout (`src/lsp/jsonrpc.zig` serves both) and the CLI surface
are planned together.

## 8. P6 — editor clients

- **VS Code**: a minimal extension (`vscode-languageclient`) that starts
  `mahina lsp` from `PATH` or a setting, plus a TextMate grammar so the
  file is coloured before the server answers. Where it lives and whether
  it is published to the marketplace is Q10. It's TypeScript, so pnpm per
  the house preference.
- **Neovim / Helix / Zed / Emacs**: no code, a configuration snippet each
  in the README.
- File association: `.lua` is ambiguous with real Lua; whether mahina gets
  its own extension is part of Q10.

## 9. Performance budget (Rule 20)

The design re-parses and re-analyses the whole document on every change.
That only stays acceptable if the frontend is fast, so the budget is
explicit and benchmarked, not assumed:

- **Budget (proposal, Q1):** didChange → publishDiagnostics, excluding the
  debounce, ≤ 10 ms for a 10k-line file and ≤ 100 ms for 100k lines on
  this machine in ReleaseFast. The parser is a single pass into an arena
  and the compiler a single pass over the tree, so this should be met with
  room to spare; the benchmark proves it.
- **What scales with what:** parse, compile and the binding index are
  linear in document size; position mapping is linear in the length of one
  line; references are linear in the number of uses of one binding; P5's
  module cache is keyed per file and invalidated per file, never rebuilt
  workspace-wide on an edit.
- **Memory:** one arena per document version, freed when the next version
  replaces it; at most two versions alive (the published one and the one
  being analysed).
- **The benchmark:** `bench_lsp.zig`, next to the existing `bench_*.zig`
  roots, generates realistic files (functions, nested loops, tables,
  requires) at 1k/10k/100k lines and measures parse, compile, index and
  serialisation separately. A deliberate run, not a test assertion
  (Rule 22). If a measurement shows full re-parse misses the budget, the
  answer is incremental reparsing at block granularity, decided then, with
  numbers.

## 10. Testing

- **Protocol tests**: the server driven over in-memory reader/writer pairs
  with recorded JSON exchanges (initialize → didOpen → diagnostics →
  definition → shutdown), on `std.testing.allocator` so every leak fails.
- **Position tests**: utf-8 and utf-16 mapping across ASCII, BMP, astral
  code points, CRLF and a missing final newline.
- **Feature tests**: per feature, a source string with markers
  (`--[[1]]`) at the request and expected-result positions.
- **Smoke**: `tools/cli-smoke.sh` starts `mahina lsp` and runs one
  initialize/shutdown round trip on every built platform.

## 11. Open questions for review

- **Q1 — text sync and debounce.** Full-document sync is simplest and
  matches the full re-parse; incremental sync sends less over the pipe but
  saves nothing on our side. And the debounce: none (we're fast), or a
  fixed delay like 50 ms?
- **Q2 — compiling without a `Vm`.** (a) Keep creating a `Vm` per check, as
  `mahina_check` does; (b) give the compiler a heap-free mode for analysis
  (constants not interned); (c) keep one long-lived analysis `Vm` per
  server and reset its heap between checks.
- **Q3 — one scoping implementation or two.** (a) The compiler emits the
  binding index as a side output when asked; (b) a separate resolver pass
  over the AST, kept consistent with the compiler by tests that compare
  both on the same corpus.
- **Q4 — source of hover/signature text.** (a) Extend the inventory CSV
  with a signature column and generate from it; (b) doc comments on the
  native registrations, extracted at build time; (c) a new hand-written
  table.
- **Q5 — workspace configuration.** How a workspace says which host it
  targets (CLI vs an embedding host without `cli-binding`), its
  `package.path`, and extra known globals: a `mahina.toml`/`.mahinarc` at
  the root, LSP `initializationOptions`, or both.
- **Q6 — richer diagnostic messages.** Interpolated messages ("expected
  `end` to close `function` at line 12") would need formatted,
  allocated messages in `diag.zig` (v1 avoids that on purpose). Part of
  this doc, or separate?
- **Q7 — the parse-error cascade.** (a) Compile the recovered tree even
  when it has parse errors (the parser already synchronises per statement)
  and keep compile-level diagnostics from the error-free statements;
  (b) keep the last good compile-level diagnostics for regions the edit
  didn't touch; (c) accept the flicker.
- **Q8 — running user code for JIT lenses.** Which system switch the
  child gets (full CLI system, or none), the timeout, and whether the
  result is shown inline or in a panel.
- **Q9 — DAP in this doc or its own.**
- **Q10 — VS Code extension home and file extension.** In-repo
  (`editors/vscode/`) or a separate repo; marketplace publishing under
  which publisher; whether mahina claims a file extension of its own
  instead of `.lua`.
- **Q11 — comments in semantic tokens.** A trivia-emitting lexer mode
  (also the foundation a future formatter needs) or leave comments to the
  TextMate grammar.

## References

- LSP 3.17 specification —
  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/
- Debug Adapter Protocol — https://microsoft.github.io/debug-adapter-protocol/
- Doc 00 Phase 7 v4–v6 (viz editor, `mahina_check`, located errors) —
  `docs/design/00-architecture.md`
- `src/wasm_entry.zig` `check` — the compile-only path P1 mirrors
- `src/compiler.zig` `warnUnknownGlobals` — the existing global lint
- `src/stdlib/package.zig` — `package.path` / searcher semantics P5
  imitates
- Doc 04 (snapshot/replay schema), doc 73 (keyframes inside coroutines) —
  what P8 builds on
- lua-language-server (sumneko) — the reference for tier 5 inference
