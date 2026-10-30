# 74 — A language server (`mahina lsp`) — Design

Status: partial — P0 landed (the `mahina lsp` stdio server: framing,
lifecycle, positions, document sync, debounce, cancellation; the wasm host);
everything from P1 on outstanding. Direction decided 2026-10-27 (server in
Zig as a CLI subcommand; design before code). Review round 1 (Codex,
Antigravity) folded in 2026-10-27; Bart delegated the picks where the
reviewers disagreed (§12). Every open question decided 2026-10-27.
Clients decided 2026-10-27 (§13): the viz web UI and Zed; no VS Code or
Neovim client.
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
- [x] **Review round 1** (§12): Codex and Antigravity, 2026-10-27. Five
  factual errors in the first draft corrected, phasing reordered, Q1–Q4,
  Q6–Q9 and Q11 decided (Bart delegated the picks), Q10 mostly answered by
  doc 00.
- [x] **Q1 — text sync** (§5.3): incremental sync, full re-analysis,
  bounded debounce, immediate analysis for interactive requests.
- [x] **Q2 — compiling without a `Vm`** (§6.1): a bare `gc.Heap` per
  analysis; no heap-optional compiler mode.
- [x] **Q3 — one scoping implementation** (§6.3): a shared resolver pass
  whose results the compiler consumes.
- [x] **Q4 — hover/signature source** (§7.3): structured signature columns
  in the inventory CSV, generated into an embedded table, checked against
  the registered natives.
- [x] **Q6 — richer diagnostics** (§6.4): stable codes and related
  locations in P1; better prose later, message by message.
- [x] **Q7 — the parse-error cascade** (§6.2): recovery regions in the
  parser, compile the recovered tree, suppress scope-dependent warnings in
  damaged scopes.
- [x] **Q8 — running user code for JIT lenses** (§7.6): explicit command,
  child process, timeout, panel plus compact inlay hints; not described as
  a sandbox.
- [x] **Q9 — DAP** (§7.7): its own doc (75).
- [x] **Q11 — comments** (§6.5): an optional trivia-span sink in the lexer.
- [x] **Q10 — file extension, extension home, publishing** (§8): `.mah` by
  default (doc 00 §"Two source extensions"), `.lua` opt-in; the VS Code
  extension lives in-repo under `editors/vscode/` and is not published to
  any marketplace (Bart, 2026-10-27: no publisher account, doesn't use VS
  Code); it installs from a locally built `.vsix`. **Superseded the same
  day by D3:** there is no VS Code extension; the `.mah` default stands.
- [x] **D3 — clients** (§13): decided by Bart 2026-10-27. The viz web UI
  (the server compiled to wasm, in the existing worker, behind
  `@codemirror/lsp-client`) and Zed (a dev-installed extension plus a
  Tree-sitter grammar). Bart uses neither VS Code nor Neovim.
- [x] **Q5 — workspace configuration file** (§7.4): `mahina.toml` at the
  project root (Bart, 2026-10-27). The Zig stdlib has no TOML reader, so
  P6 includes a small one for the subset the config uses.
- [x] **Q12 — the §9 budget**: confirmed by Bart 2026-10-27 (≤ 10 ms at
  10k lines, ≤ 100 ms at 100k lines).
- [x] **Prerequisite — constant dedup was quadratic** (§9): 2026-10-27.
  `Compiler.addConstant` now looks the pool slot up in a per-compiler hash
  map keyed by exact identity (`ConstKey`: tag + payload bits, heap
  constants by address), so `1` and `1.0` stay distinct and the pool order
  is unchanged. Tests: exact-identity dedup, and a 65 536-constant pool
  that fills exactly with the 65 537th refused. The scaling measurement
  belongs to the P2 bench's 60k-distinct-constants file.
- [x] **P0 — transport, lifecycle, documents** (§5): 2026-10-27, `mahina
  lsp` runs end to end over stdio.
  - [x] `src/lsp/position.zig`: LSP line index (LF/CRLF/CR), utf-8 and
    utf-16 columns, clamping, sparse checkpoints on long lines, a monotonic
    `Cursor` for sorted batches; built by a bulk scan for line breaks.
  - [x] `src/lsp/jsonrpc.zig`: `Content-Length` `FrameReader` (split and
    coalesced input, header and body limits, oversize bodies skipped,
    resynchronises after a bad header), message parse (string and integer
    ids), result/error/notification encoders that keep a `null` result and
    a `null` error id while omitting null optional fields inside results,
    `$/cancelRequest` target extraction.
  - [x] `src/lsp/protocol.zig`, `src/lsp/documents.zig`: protocol shapes;
    the open-document store with incremental range edits (clamped, never
    dropped) in the negotiated encoding.
  - [x] `src/lsp/server.zig`: the sans-IO core — lifecycle state machine and
    exit codes, position-encoding negotiation (utf-8 if offered), didOpen /
    didChange / didClose, cancellation through a host hook (a cancelled
    request is still answered), a 50 ms / 250 ms debounce driven by
    `nextDeadline()`/`tick()`. Until P2 it publishes an empty diagnostic set
    per analysed version.
  - [x] `src/lsp/host_stdio.zig` + `mahina lsp`: reader thread and worker,
    a byte-bounded queue with back-pressure, cancellation noted on the
    reader thread, the worker sleeping on the debounce deadline, a
    ref-counted shared state so a reader blocked in `read` cannot outlive
    its memory. In-memory-pipe tests (one-byte fragmentation, garbage,
    oversize bodies, EOF, the timer, cancellation) plus a real-pipe check
    and `tools/cli-smoke.sh` coverage.
  - [x] The core and its modules build for wasm32 (`zig build wasm`).
  - [x] P1a name spans (§6.3): `ast.Ident` (text + span) for `for` variables
    and `function a.b:m` components; `name_span` on `local_function`,
    `numeric_for`, `field`, `method_call` and named table fields; the
    implicit `self` is a zero-width span at the method name.
  - [x] P1b recovery regions (§6.2, parser half): `Stmt.err` / `Expr.err`
    nodes carry the span a failed statement dropped; `synchronize` returns
    that span and no longer swallows a boundary keyword it is already at
    (`local x =` then `local y = 1` keeps `y`); a `local` whose value is
    broken keeps its names with an error value; an identifier on a later
    line ends the skip; a stray block-closing token after an earlier error
    is an error node without a second diagnostic, and the rest of the file
    still parses. The compiler treats error nodes as nothing / nil. The
    damaged-scope marking and the compile-after-error steps wait for the
    resolver (P1c) and P2.
  - [x] P1c shared resolver (§6.3): `src/resolve.zig` (`Resolution`:
    `bindings`, `occurrences` sorted by start, `bindingAt` /
    `occurrenceAt` / `occurrenceCovering`; one hash probe per use through
    shadow chains). The compiler consults it instead of matching names:
    `Local` carries a `BindingId`, `declareLocal` takes the name token's
    span, and `endScope` asserts the compiler's dynamic capture marking
    equals the resolver's `captured`, so the two cannot drift. `builtin`
    and `unresolved` binding kinds are not produced yet (P5 and P1d).
  - [x] P1d diagnostics model (§6.4, sink half): `diag.Code` (stable
    number per message, `E0109`-style `id()`, `W0001` for lints; 65 call
    sites in the lexer, parser and compiler now name a code and the message
    lives once, in `Code.message`); `Diagnostic.related` (span + static
    label) set for every unclosed `if`/`while`/`for`/`do`/`repeat`/
    `function`/call/paren/table; `Diagnostics.incomplete` set when an
    allocation failure drops a diagnostic.
  - [x] Wasm host: `mahina_lsp_open/send/tick/next_deadline/message_ptr/
    message_len/is_done/close` in `src/wasm_entry.zig` (message bodies, no
    framing; JS owns the debounce timer). `viz/test/lsp-wasm.test.ts`.

  - [x] P1d (rest) + P2 core: `compiler.checkChunk` recovers per statement
    and assembles no bytecode, with the unknown-global lint hiding names
    found in damaged text; `lsp/analysis.zig` runs parse → resolve → check
    with phase-boundary abandonment (`Hooks.input_pending`; an abandoned
    document stays dirty); the server publishes versioned diagnostics with
    code, source, severity, `relatedInformation`, ranges in the negotiated
    encoding, and empty sets on clear.
  - [x] P2 Zed client + grammar (§13.2): `editors/tree-sitter-mahina/`
    (grammar with an external scanner for long brackets and block comments,
    highlights/brackets/outline/indents queries, a corpus test) and
    `editors/zed/` (manifest, language config, a launcher crate that runs
    `mahina lsp`; queries symlinked from the grammar). The drift check
    (`test/drift.test.ts`) parses every tracked `.lua`/`.mah` source with
    the grammar and fails on any ERROR node. Not yet tried inside Zed
    itself: installing the dev extension is a manual step.
  - [x] P2 viz client (§13.1): `@codemirror/lsp-client` over postMessage to a
    dedicated worker (`mahina.lsp.worker.ts`, its own wasm instance, so a run
    never stalls diagnostics and `stop()` never kills the session; the
    worker owns the debounce timer). `mahinaLinter` and the run worker's
    `check` call are gone; tab switches work with the default workspace.
    `mahina_check` stays only for the bun tests of the shared path.
  - [x] `mahina_check` (wasm) runs `lsp.analysis.analyse`, the same
    recovering frontend path as the server; it reports every error, not
    just the first.
  - [x] P2 bench (§9): `zig build bench-lsp` (`src/bench_lsp.zig`). First
    numbers (ReleaseFast, end to end): 10k lines 8.5 ms, 100k lines 108 ms
    (budget 100 ms, about 8% over: check is 63 ms of it), 1 MB astral line
    9 ms, 60k constants 28 ms, 50k-deep nesting 136 ms with no crash on the
    native stack, 200-edit burst 23 ms, 49 documents in one tick 39 ms.

  - [x] P3 navigation and completion (§7.2): `src/lsp/navigation.zig`
    (definition, references, document highlight, rename checks),
    `src/lsp/completion.zig`, `lexer.contextAt` (no completion in strings,
    comments, declarations, after `.`/`:`). `resolve.Binding.scope_end` is
    now the closing keyword's start (`end`, `elseif`, `else`), from
    `Branch.kw_start` / `if_.else_start`. Position requests analyse the
    document first if its debounce has not run. Rename refuses an invalid
    name, keyword, host global, implicit `self`, and any rename where a use
    would capture or be captured (checked against occurrences, not by
    re-resolving), answering `RequestFailed` with the line; it replies with
    `changes` (what `@codemirror/lsp-client` reads). Verified in the viz
    editor: completion list, F2 rename.

  - [x] P4 syntactic features (§7.1) and the trivia sink (§6.5):
    `lexer.Trivia` records each skipped comment (`Comment`: bytes, block,
    closed), passed through `parser.parseTrivia` and `tokenizeTrivia`;
    `Analysis.comments` keeps them. `src/lsp/tokens.zig` classifies each
    token from the lexer and the resolver's occurrences (keyword, operator,
    number, string, comment, function, parameter, variable with
    `declaration`/`defaultLibrary`, property for a name with no binding).
    `src/lsp/syntax.zig` gives folding nodes, the document outline (functions,
    methods, locals, table constructors and their fields, plain blocks
    flattened into their enclosing list), and the spans selection ranges
    chain. Multi-line folds keep their closing `end`/`}` line visible.
    Budget (Rule #20, the same as the keystroke budget since editors ask on
    every change): semantic tokens and the outline ≤ 10 ms at 10k lines,
    ≤ 100 ms at 100k. `zig build bench-lsp` (the "syntax requests" table)
    measured them at 3.4 / 3.2 ms (10k) and 38 / 35 ms (100k) under a load
    average of 5–9. Folding is 0.6 ms (10k). The fix that brought tokens from
    7.1 to 3.4 ms at 10k: the occurrence and line lookups walk forward with the
    sorted tokens instead of searching per token (`position.Cursor` now steps
    over lines too).

### Outstanding

- [ ] **Bench follow-ups:** the 100k-line budget miss (check dominates).
- [x] **Nesting limit (2026-10-30):** a tree deeper than 200 levels
  (`parser.max_depth`, Lua's and LuaJIT's) is one `E0135` and the parse
  ends there; before, 10k nested brackets or blocks, or a 100k-term
  `1+1+…`, overflowed the stack natively and in the browser. Each nested
  construct is a level, and so is each operator or suffix of an
  expression after its first, since every later pass recurses once per
  level of the tree (a flat `a+b+c…` past 200 terms is refused, where Lua,
  building no tree, takes it: Bart kept that divergence over making every
  pass iterate over chains). The first operator or suffix sharing its
  expression's level makes `f(f(…))` a level per call, as in LuaJIT (199
  calls; LuaJIT's registers stop it at 123, PUC Lua's C stack at 195); it
  first cost two, and stopped at 99. That sharing lets a tree run up to
  about twice the counted depth (`f(…).a` nested), so the probe covers
  those shapes too. Probed at and past the limit on the Debug wasm build
  (1 MiB stack, 23 shapes) and the Debug CLI, through every LSP request,
  check and run. `bench/compile_multret_chain.lua` loaded a 2,000-deep
  chain, which neither Lua nor LuaJIT loads; it now splits its calls into
  chains of 190. std's JSON writer asserts 256 levels of nesting in a safe build,
  so a document-symbol outline nests at most 100 levels (deeper symbols are
  listed flat there) and a selection chain keeps its innermost 199 steps
  and the file.
- [x] **Cross-file globals (2026-10-30):** rename and references of a
  global reach every file that uses it (see "Globals across files" under
  P6e's as-built notes).
- [ ] **P3 follow-ups:** completion after `.`/`:` waits
  for P5; a `local x =` with a missing value still offers `x` right after
  the `=` (the parser cannot say where the missing value would end);
  `contextAt` now takes its comments from the trivia sink, but still lexes
  from the start per completion request; no completion/definition bench yet.
- [ ] **P4 follow-ups:** semantic tokens are full-document only (no
  `range` or `delta` requests); multi-line tokens are always split per line,
  whatever `multilineTokenSupport` says; consecutive line comments do not fold
  (only block comments do); selection ranges come from AST spans and the
  resolver's name tokens, so a name's parent is its statement, not the list it
  sits in; `contextAt` still lexes from the start per completion request (its
  comments now come from the sink).
- [x] **P5 — stdlib knowledge** (§7.3): hover, `lib.` member completion and
  signature help, all read from `stdlib_db.zig` (the inventory's table).
- [ ] **P5 follow-ups:** the call scan (`callAt`) and the name lookups lex the
  document from its start per request, as `contextAt` already does: 0.3–0.5 ms
  at 10k lines and 3–5 ms at 100k (`bench-lsp`, "library requests"), against a
  110 ms analysis at 100k. Keeping a token list with the analysis would remove
  that scan if it ever matters. Calls are resolved by name only: `f:read(` on a
  value (a local `file`) answers nothing, and so does a callee with a space in
  it (`string . sub(`). Overloads are not split (one signature per name). Values
  (`math.pi`, `io.stdin`) have no signature. The inventory's descriptions are
  implementation notes, shown verbatim in hover.
- [x] **P6 — cross-file** (§7.4): `require` resolution mirroring
  `package.searchpath`, `mahina.toml` (with a TOML-subset reader in
  `src/lsp/config.zig`), open-document overlays,
  module exports for `local M = {} … return M`, workspace symbols.
  - [x] P6a `mahina.toml` reader (`config.zig`): the TOML subset, located
    errors, `version = 1`, tables `[runtime]` (`cwd`, `package_path`,
    `system`), `[globals]`, `[diagnostics]` (`suppress`).
  - [x] P6b `require` resolution (`modules.zig`): built-ins, then
    `package.path` templates against the runtime cwd, through a probe the
    host supplies; literal sites from the tokens, a shadowed or field
    `require` skipped, dynamic arguments named as such.
  - [x] P6c server integration: one server for every workspace folder, each
    folder's `mahina.toml` (`workspace.zig`), `file:` URIs (`uri.zig`), the
    host's disk as `workspace.Files` (stdio: `host_stdio.disk`; the browser
    has none), open documents ahead of the disk, definition on a module name,
    `unresolved-require` information diagnostics, `[globals]` and `suppress`
    applied, a rejected config published on the file,
    `workspace/didChangeWorkspaceFolders`.
  - [x] P6d module exports (`exports.zig`): the returned constructor's
    fields, or for `return M` the fields `M`'s constructor names plus
    `function M.f`, `function M:m` and `M.x =` in the chunk's own code;
    a consumer's `local m = require("x")`, never assigned again, offers
    them after `m.` (after `m:`, only what can be called) and goes to them
    on definition. `module_cache.zig` keeps each module's exports per path,
    checked against the text by hash on every lookup, 64 paths, least
    recently used out. Follow-ups: hover and signature help on `m.f`;
    `local s = require("string")` could offer the library's members;
    `require("x").f` without a local; a typed local
    (`local m: T = require("x")`); a module that is itself a required
    value (`return require("y")`).
  - [x] P6e, in four parts:
    - [x] `system` groups applied: `system = [...]` sets the groups (every
      one when absent, as the CLI gives; none for `[]`). A host global whose
      every native is in a group none of which is on (`aio`) is not known,
      `lib.` completion leaves out the members of groups that are off, and
      hover on one says the project does not enable its group. `io.stdin`'s
      group is now read from the VM's own list (`Vm.system_members`).
    - [x] `initializationOptions` overriding `mahina.toml`: the file's
      tables as JSON (`runtime`, `globals` as an object of descriptions,
      `diagnostics`), decoded strictly (`jsonrpc.decodeStrict`): a misspelt
      key or a wrong type is a warning (`window/showMessage`) naming it, and
      the options are ignored as a whole. The Zed extension passes
      `lsp.mahina.initialization_options`.
    - [x] `workspace/didChangeWatchedFiles`: after `initialized`, a client
      that offers dynamic registration is asked (`client/registerCapability`)
      to watch `**/mahina.toml`; a change, creation or deletion of a folder's
      file reads that folder's config again, republishes or clears its error,
      and analyses every open document again. A client that cannot watch is
      told once (`window/logMessage`) that a config edit then needs the
      folder re-added or a restart. A refused registration is logged. The
      P6d cache needs no invalidation: it checks the text on each lookup.
    - [x] workspace symbols (`symbol_index.zig`): `workspace/symbol`
      over every function and method of every folder's source files at any
      depth (with the enclosing function or table as `containerName`) and
      each file's top-level names. A source file is one whose extension a
      `package_path` template names (`.mah`, `.lua`); hidden directories,
      `node_modules`, `zig-out` and `target` are not entered, symbolic links
      are not followed, and at most 200,000 files are indexed. A folder is
      walked when it appears (again when its extensions change, or when a
      folder goes), in the background: `tick` takes slices of about 5 ms
      (`slice_budget`) while the host has no message, so a request is never
      held up by a walk. The index is saved per folder under
      `$XDG_CACHE_HOME/mahina/lsp` (else `~/.cache/mahina/lsp`), when a walk
      ends with something changed and at shutdown; the next session loads
      it before walking, and the walk parses only the files whose stamps
      differ, dropping what is gone. A save that does not check out
      (checksum, format version, encoding, folder, extensions) is ignored
      and rebuilt. After the walk a request looks only at the paths the client's watcher reported
      since the last one (`**/*` is registered with `**/mahina.toml`; the
      index drops a change to a non-source file, a path in no folder or in
      a directory not walked). A reported directory stands for everything
      under it: deleted, its files go; created, it is walked. A looked-at
      file is parsed again only when its size or modification time
      (`workspace.Files.stamp`) differs. A client that cannot watch, or
      refuses the registration, has no change log, so the index polls in
      `tick` (`Index.setPolling`, `nextDeadline` the next poll) and a
      request only searches. Every directory the walks entered is stamped
      each second (`Files.dir_stamp`, its modification time) and, moved,
      listed again (and once more the round after, for a change in the same
      tick of a coarse clock): a file created, deleted or renamed, an
      editor's save by rename, or a directory gone, shows within a second.
      Each file has its own next stamp: a second after it changed (or
      appeared after its root's first walk), when it is parsed once more
      even if its stamp holds (a same-size rewrite in the same tick of a
      coarse clock), the wait then doubling with each
      unchanged stamp up to 5 minutes, which bounds how long an edit in
      place to a long-unchanged file goes unseen; a first walk's or saved
      index's files start spread over the 5 minutes, so the stamps come
      evenly. A change log
      longer than 200,000 paths is dropped for a walk. Open documents are
      indexed from their text, keyed by its hash, and a document with no
      file is searched too. Matching ignores case and ranks the whole name,
      then a prefix, then a substring, then a subsequence; at most 500
      results, kept by a bounded heap. All symbols lie in shared columns
      (a `MultiArrayList` and one name pool): a search scans the 64-bit
      character-class masks in order and scores only the names whose mask
      covers the query's; a removed file's symbols are marked dead and
      compacted away once they outnumber the live. The browser has no `Files.list`, so it searches the open
      documents only.
- [ ] **P7 — JIT lenses** (§7.6): extend the `--emit-coverage` artifact
  with source spans and structured abort records; in Zed, a code action
  running the file and inlay hints from the result. The viz already shades
  loop headers from its own run's coverage (`MahinaEditor.tsx`
  `coverageField`); P7 adds abort reasons there.
- [ ] **Doc 75 — time-travel debugging over DAP** (§7.7): write the
  design doc.
- [ ] **Defer — inference (tier 5)** (§7.5): table shapes and
  annotation-driven types. Not before P5 ships and the annotations (doc 00)
  have a semantics.

## 1. Why this exists

mahina is usable from the viz editor: a CodeMirror 6 mode keyed to the real
lexer, live validation through the compile-only wasm entry `mahina_check`,
located runtime errors and a backtrace (doc 00, Phase 7 v4–v6). Outside the
browser it has nothing: open a `.mah` file in VS Code, Neovim or Helix and
you get, at best, a borrowed Lua mode that does not know `??`, `~>>`, the
reserved type annotations or the unknown-global lint.

The Language Server Protocol is what all of those editors speak. One server
gives every one of them diagnostics, navigation, rename, hover and
completion. This doc is the contract for that server, and for the editor
side of the thing only mahina can offer: showing what the JIT did with a
loop, on the loop. Stepping a recorded run backwards is the other one; it
gets its own doc (§7.7).

## 2. Goals

- **One frontend.** The server's diagnostics are the compiler's
  diagnostics, for the same host configuration, the promise `mahina_check`
  already makes for the browser. No second grammar and no second scoping
  model that can drift (§6.3). Recovery improvements go into the shared
  frontend, so the LSP and the browser check never disagree.
- **Every LSP editor, two first-class clients.** Plain LSP 3.17; nothing
  editor-specific in the server. The clients we build and test are the
  viz web UI and Zed (§13).
- **One core, two hosts.** The server core is sans-IO and single-threaded,
  so the same code runs over stdio in the CLI and in the browser's wasm
  worker (§5.2, §13.1).
- **Fast on large and hostile files** (Rule 20, §9). Nothing quadratic in
  document size, line length, constant count or workspace size.
- **Allocation discipline** (Rule Z-4). The server takes an allocator;
  per-version analysis lives in an arena freed in one shot; every queue
  and cache is bounded.
- **Churn confined** (Rule Z-2). Framing, stdio and `std.json` for the LSP
  live in `src/lsp/jsonrpc.zig` (`viz_server.zig` remains the viz's own
  JSON user); analysis code never sees JSON.

## 3. Non-goals (v1)

- **A type checker.** Tier 5 (§7.5) is deferred until the annotations mean
  something.
- **Formatting.** The trivia sink (§6.5) is the foundation a formatter
  would need, but the formatter is a separate project.
- **Running user code implicitly.** Only P7 runs anything, and only on an
  explicit command.
- **Debugging.** Doc 75.
- **Lua compatibility shims.** The server analyses mahina, not Lua 5.4.

## 4. Module layout

```
src/resolve.zig     the shared resolver (P1c): used by the compiler AND the LSP
src/lsp/
  jsonrpc.zig       framing + std.json; the only churny file of the LSP
  protocol.zig      the LSP structs we use, plain Zig types, no JSON
  server.zig        sans-IO core: dispatch, lifecycle, capabilities, timers
  host_stdio.zig    the CLI host: reader thread, worker thread, clock
  documents.zig     document store: text, version, line index, latest analysis
  position.zig      byte offset <-> (line, character) in the negotiated encoding
  analysis.zig      parse + resolve + compile for one document version
  stdlib_db.zig     generated builtin table (P5)
  config.zig        mahina.toml reader, a TOML subset (P6)
  modules.zig       `require` sites and resolution over package.path (P6)
  workspace.zig     workspace folders, their configs, the host's files (P6)
  exports.zig       a module's exports; the consumer's module locals (P6)
  module_cache.zig  exports per module path, checked by text, bounded (P6)
src/main.zig        `lsp` subcommand, next to `viz`
src/wasm_entry.zig  `mahina_lsp_*` exports: the browser host (§13.1)
editors/zed/                 the Zed extension (§13.2)
editors/tree-sitter-mahina/  the Tree-sitter grammar Zed requires (§13.2)
```

`main.zig` dispatches `viz` before the flag loop (`src/main.zig:260`);
`lsp` joins it there. On stdio, stdout carries protocol messages only: the
server never reaches the diagnostic stdout path in `src/io.zig`; logging
goes to stderr or `window/logMessage`.

## 5. P0 — transport, lifecycle, documents

### 5.1 Framing and the wire contract

`Content-Length: N\r\n\r\n` + N bytes of UTF-8 JSON. The reader handles
messages split across reads and several messages in one read, rejects
headers over 8 KiB and bodies over a configurable limit (default 64 MiB)
with a logged error, checks the length arithmetic, and accepts string and
integer request ids. Malformed JSON gets `ParseError`, an unknown request
`MethodNotFound`, an unknown notification is ignored, and notifications
never get responses. EOF without `exit` ends the process with status 1.
Lifecycle follows the spec's state machine: requests before `initialize`
get `ServerNotInitialized`; after `shutdown`, everything but `exit` gets
`InvalidRequest`; `exit` returns 0 after `shutdown`, 1 otherwise.

`std.json` in the pinned 0.17 has `parseFromSlice`/`Value` and
`Stringify` (verified in `lib/std/json.zig`). Parsed values can borrow the
message buffer (`json/static.zig:39`), so anything that outlives a message
— document text, queued parameters — is copied into storage the document
or the queue owns.

### 5.2 Threads and cancellation

*Amended 2026-10-27 by D3 (§13.1):* the browser host runs on
wasm32-freestanding, which has no threads. The server core in
`server.zig` is therefore **sans-IO**: it takes one decoded message,
returns the messages to send, and exposes `nextDeadline()`/`tick(now)` so
the host owns the clock and the debounce timer, plus a host-supplied
`isCancelled(request)`/`isStale(document, version)` callback polled at
analysis phase boundaries. The thread design below is now the **stdio
host's** (`host_stdio.zig`); the browser host is in §13.1.

The stdio host has two threads:

- **The reader** frames messages, parses them, and pushes them onto a
  bounded queue in arrival order. It does two things itself:
  `$/cancelRequest` sets a cancelled flag on the queued or running request,
  and a `didChange` bumps the document's "newest version" atomic, so work
  on an older version can see it is stale.
- **The worker** owns every piece of state (documents, analyses, caches)
  and processes the queue strictly in order, so text changes are applied
  in order and every positional request sees the version it was sent
  against. Analysis checks the cancelled flag and the newest-version
  atomic at phase boundaries (after parse, resolve, compile) and abandons
  stale work. A cancelled request still gets a response
  (`RequestCancelled`, or the result if it already finished).

The alternative was one thread with cooperative work slices; that would
turn the parser and compiler into resumable state machines for a benefit
the phase-boundary checks already give us (§12).

### 5.3 Documents and sync

- **Incremental sync** (`TextDocumentSyncKind.Incremental`). The worker
  applies each range edit to the document's text immediately on
  `didChange`, so a hover or completion that follows sees the current text
  even while diagnostics are debounced. The text is one contiguous buffer;
  an edit is a splice (a memmove of the tail), well under a millisecond
  at 5 MB.
- **Full re-analysis.** Every analysis parses the whole current text (§9
  says why that's affordable). Incremental sync saves wire bytes, JSON
  parsing and copying on large files, not analysis work.
- **Debounce.** Diagnostics run 50 ms after the last change, but never
  later than 250 ms after the first unanalysed change, so a long typing
  burst still gets feedback. An interactive request (hover, definition,
  completion, references) on a document with a pending change analyses
  immediately.
- **Position encoding.** We pick `utf-8` if the client offers it
  (`general.positionEncodings`) and fall back to the mandatory `utf-16`,
  which counts UTF-16 **code units** (a character outside the BMP is 2).
  The LSP line index is separate from the compiler's `LineTable`: LSP
  breaks lines at `\n`, `\r\n` and `\r`, while the compiler also treats
  `\n\r` as one break (`compiler.zig:192`, Lua's `inclinenumber`).
  Converting many positions (semantic tokens, a diagnostic batch) walks a
  sorted list with a monotonic cursor, so one 1 MB line costs one pass,
  not one pass per token; random queries use sparse UTF-16 checkpoints
  every 1 KiB within long lines. Out-of-range positions are clamped.

## 6. The frontend changes (P1) and diagnostics (P2)

### 6.1 Compiling without a `Vm`

`compileWithOptions` (`compiler.zig:103`) needs a `*gc.Heap`, not a `Vm`;
`stringConstant` (`compiler.zig:468`) is the only use. `mahina_check`
builds a whole `Vm` (`wasm_entry.zig:1013`), which allocates the call
stack and installs every library (`interp.zig:1279`). The analysis creates
a bare `gc.Heap.init(gpa)` (`gc.zig:208`), compiles, collects diagnostics
and frees the heap with the version. The wasm check does the same.

We considered making the heap optional, with placeholder constants when
it's absent (Antigravity's preference); that puts a second mode into
every constant path of the compiler for one consumer, while a bare heap
changes nothing in the compiler (§12).

### 6.2 Recovery: no more flicker

Today three gates hide every compile-level diagnostic while a statement is
half typed: `check` doesn't compile after a parse error
(`wasm_entry.zig:1012`), the compiler stops at its first `CompileError`
(`compileBlock`, `compiler.zig:809`, propagates it), and the unknown-global lint runs only with no errors
at all (`compiler.zig:140`). Removing the first gate alone doesn't help,
and recovery itself loses information: `synchronize`
(`parser.zig:163`) advances and drops the broken statement, so a `local`
being edited disappears and later uses of the name change meaning.

The fix is in the shared frontend:

1. **Recovery regions.** `synchronize` records the byte span it skipped;
   the dropped statement becomes an error node carrying that span. When
   the broken statement's declaration part parsed (a `local x =` whose
   value is broken), the declaration is kept and its value is an error
   expression.
2. **Damaged scopes.** The resolver marks every scope containing an error
   node as incomplete.
3. **Compile the recovered tree.** The compiler compiles error nodes as
   nothing and keeps going after a `CompileError` where the error is local
   to a statement. Diagnostics from intact code are reported; warnings
   whose answer depends on an incomplete scope (an unknown global whose
   declaration might be in the broken text) are suppressed.

The rejected alternative was keeping the last good diagnostics for text the
edit didn't touch: editing a declaration changes uses far away, so "outside
the edited range" isn't a sound criterion.

### 6.3 The shared resolver and the binding index

The compiler resolves names local → upvalue → global as it emits code, and
does so in more places than `loadName`/`storeName`: operands read locals
in place through `localRegOf` (`compiler.zig:689`), and
`compileSingleAssign` resolves its target directly (`compiler.zig:952`).
Hooking a few compiler functions would miss those. Running a separate
LSP-only resolver would be the second scoping model the goals rule out.

So scoping moves into **one pass**, `src/resolve.zig`, which walks the AST
before code generation and produces:

```
Binding    { kind: local|param|self|for_var|local_function|global,
             name, decl_span, visible_from, scope_end, func, captured: bool }
Occurrence { span, binding: BindingId, access: declare|read|write|read_write }
```

as flat arrays sorted by span start (lookups are a binary search; "all
occurrences of B" is built once per version; no per-occurrence
allocation). It owns the rules the compiler encodes today: a `local`'s
value is evaluated before the name is visible (`compiler.zig:838`), a
`local function` sees itself (`compiler.zig:2005`), `repeat … until` sees
the body's locals, upvalues capture through closures (`compiler.zig:627`), and `_G.x` /
`_G["x"]` writes count as global writes (`compiler.zig:758`). The
compiler then asks the resolver's table which binding a name node is,
instead of resolving it. One implementation; the existing test corpus
proves the compiler unchanged, and the LSP gets the index for free.

Prerequisite: precise spans (P1a). `local_function`, `numeric_for`,
`generic_for`, `FuncName` components and `TableField.named` store names
without spans (`ast.zig:148`–`192`), and implicit `self` gets the whole
function body (`parser.zig:427`).

A global's "declaration" is its first write in the chunk: a navigation
convention, not a guarantee.

### 6.4 The diagnostics model

- **Codes and related locations.** `Diagnostic` gains a stable `code`
  (`E0012`-style, one per message) and an optional related span with a
  short label, so "expected `end`" can link the `function` it would
  close. Clients can filter by code; better prose comes later, one message
  at a time.
- **Ownership.** Messages may be allocated (the unknown-global lint uses
  `allocPrint` into the compile arena, `compiler.zig:796`); the analysis
  copies them into the version arena before freeing the compile arena.
- **Incomplete analysis.** `Diagnostics.add` drops a diagnostic on OOM
  (`diag.zig:38`); the sink gains an `incomplete` flag so the server says
  "analysis incomplete" instead of presenting a partial set as clean.
- **Publishing.** `publishDiagnostics` carries the document version where
  the client supports it, and an empty array clears a closed or fixed
  document.

### 6.5 Comments: the trivia sink

`Lexer.next` always calls `skipTrivia` (`lexer.zig:57`), and the comment
scanner already handles every long-bracket level and the unterminated case
(`lexer.zig:98`). The lexer gains an optional trivia sink: a pointer to a
list of `{ kind: line_comment|block_comment, span }`. When it's null (the
parser's normal path) nothing changes; when set, `skipTrivia` appends each
comment's span. That gives semantic tokens and folding their comments
without a second scanner, and a future formatter can interleave the sink
with the token stream. Comments must come from the server because some
clients replace TextMate highlighting with semantic tokens entirely.

## 7. Features

### 7.1 P4 — syntactic

- **Semantic tokens** (full document): a declared legend (keyword,
  operator, number, string, comment, function, parameter, variable,
  property) with modifiers (declaration, readonly for `const`-shaped
  upvalues if they arrive, defaultLibrary for builtins, global). Tokens
  are emitted in order; multi-line strings and comments are split per line
  unless the client advertises `multilineTokenSupport`. Locals vs globals
  come from the resolver.
- **Document symbols**: functions (`function a.b:c()`, `local function`),
  top-level locals, named table constructors, nested; `selectionRange`
  from the P1a name spans.
- **Folding ranges**: every block, table constructors, multi-line comments
  (from the sink).
- **Selection ranges**: the AST span ancestry of a position.

### 7.2 P3 — navigation and basic completion

Definition, references, document highlight (read/write), and
prepareRename/rename from the binding index. Rename refuses: an invalid
identifier or keyword; a new name that would capture or shadow a
different binding at any occurrence (checked against `visible_from` and
`scope_span`); a builtin. A global renames in every workspace file that
uses it, each checked the same way (see "Globals across files", §7.4).
Completion here is
keywords plus the names visible at the cursor.

### 7.3 P5 — stdlib knowledge

Hover, `lib.` member completion and signature help need a table of name,
signature, parameters, description, tier and system group. Natives carry
no arity or parameter names (`BaseNative`, `function.zig:594`), so the
table comes from the inventory CSV (`docs/lua-stdlib-inventory.csv`, the
Rule Z-5 canonical map), which gained a `signature` column in Lua-manual
form: `[...]` marks optional parameters, and `file:read(...)` names
methods.

Decided while building it (2026-10-28):
- **One row per name, one signature per row.** Overloads are not split
  into rows, which would break Rule Z-5's one-row-per-function rule. A
  function with two call forms gets its most complete one.
- **Parsed at compile time, not by a build tool.** `build.zig` copies the
  CSV into a generated wrapper module (`stdlib_inventory`), and
  `src/lsp/stdlib_db.zig` parses it with comptime `@embedFile`. There is no
  second generated artefact to keep in step.
- **The system group is not a CSV column.** It is read from the native
  registered under the same name (`interp.base_natives`), so the
  registration is the one source. A cross-check test holds both
  directions: every non-hidden native has a row, and every implemented or
  partial row is a native, a constant, or a listed value (`_G`,
  `io.stdin`, `package.*`). Hidden `@file` methods map to `file:read`.
- Excluded and not-started rows are kept in the table with their status;
  the features that read it (P5) filter on status.

Inventory tier alone is not availability: natives are installed by group
(`function.zig:621`).

### 7.4 P6 — cross-file

`require("a.b")` resolves the way `package.searchpath`
(`stdlib/package.zig:102`) does with the default searchers: preload and
already-loaded built-in modules first (`package.zig:424`), then each
`package.path` template with `?` substituted, relative to the **runtime
working directory** the project config names (native lookup is
cwd-relative, `host_system.zig:84`), not implicitly the workspace root.
Only string-literal arguments to an unshadowed `require` resolve; anything
else, or a host-installed searcher, is reported as "unresolved
(dynamic)", never as an error. Open documents shadow their files on disk.
Resolution runs again on every request, so a new file that shadows an earlier
candidate is seen at once; the module cache checks each module's text on
every lookup (P6d, below), so it needs no invalidation.

Module exports: P6 includes one bounded piece of shape tracking — fields
assigned to a local table that the chunk's top-level `return` returns
(`local M = {} … M.f = … return M`, and a returned constructor). Anything
more is tier 5.

**Project config: `mahina.toml`** at the project root (Q5, decided
2026-10-27). The Zig stdlib has no TOML reader, so `src/lsp/config.zig`
parses the subset the config needs (tables, strings, integers, booleans,
string arrays) and rejects anything else with a located error, published
as a diagnostic on `mahina.toml` itself. Versioned (`version = 1`), never executed,
with LSP `initializationOptions` overriding it, documented precedence and
per-root behaviour in multi-root workspaces. *As built (P6e):* the options
apply over every folder's file and to files in no folder. A setting with one
value (`cwd`, `package_path`, `system`) replaces the file's; a list of names
(`globals`, `suppress`) is added to the file's, so an editor-wide
suppression does not undo a project's own. An option's `cwd` is relative to
each folder (to the file's own directory outside every folder). Content: runtime cwd,
`package.path`, enabled system groups, extra host globals with optional
member descriptions (for embedding hosts), and diagnostic code
suppressions.

**Decided 2026-10-29 (Bart), as built in P6c:**
- *Multi-root.* One server process serves every workspace folder; each
  folder's own `mahina.toml` governs the files under it, and when folders
  nest the innermost wins. A file in no folder gets the defaults and
  searches from its own directory, the likeliest place the CLI is run from.
  A document that names no file (`untitled:`) resolves only built-ins.
- *An unresolved literal `require` is information* (code
  `unresolved-require`), not a warning: the runtime may still find it
  through a searcher or `package.preload` entry the host installs
  (`package.searchers` is a real table hosts may prepend to,
  `package.zig:21`), which the server cannot see. With no disk (the browser)
  a miss says nothing, so nothing is reported. A dynamic argument gets no
  diagnostic. `suppress = ["unresolved-require"]` silences it per folder.
  Once definition files exist (below), a host can declare its modules and a
  miss outside them can become a warning.
- *Definition files for every module, the stdlib included,* generated from
  the implementations where they can be (lua-language-server's meta files,
  TypeScript's `.d.ts`): stub `.mah` files with empty bodies. They need a
  type grammar the language does not have yet — today an annotation is a
  dotted name only, and the `?` of an optional type is reserved but not
  parsed (`parser.zig` `matchOptionalMarker`) — so they wait for their own
  design doc. The type grammar is **based on the base grammar**: it extends
  what the language can already say, so constructs can later move between
  the type grammar and the main grammar as needed. When stubs land, the
  stdlib inventory stops feeding the server and stays the implementation
  checklist (Rule Z-5).

**Module exports, as built in P6d (2026-10-29).** The cache is checked
against the module's text on every lookup (a read and a Wyhash), not
invalidated by file events: an edit on disk or in an open document is never
missed, and a hit is cheap next to a parse. Watched files (P6e) are then
needed only for `mahina.toml`. Measured (`bench-lsp`, "module members", a
module exporting one function per 13 lines, load average ~16): completion
after `m.` costs 0.31 / 4.0 / 64 ms cold and 0.02 / 0.12 / 1.5 ms warm at
1k / 10k / 100k lines of module. The host reads files up to 16 MiB.

**Workspace symbols, as built in P6e (2026-10-30).** The first cut walked
every folder and stamped every file on each request (11.6 ms at 10k files,
growing with the workspace); Bart chose the client's file watcher as the
index's change log instead, with the walk kept only for a client that
cannot watch. Each file's entry is two allocations sized exactly. Measured
(`bench-lsp`, "workspace symbols", files of 100 lines with 8 functions
each, load average ~2): at 1k / 10k / 20k files, 28 / 296 / 599 ms cold;
warm for a watching client 0.11 / 1.5 / 4.8 ms, and 0.12 / 1.3 / 3.9 ms
with one file rewritten and reported; warm for a client that cannot watch
0.6 / 10.9 / 25 ms. The index holds 0.7 / 7.1 / 14.3 MiB, and building it
peaks at 1.2 / 9.1 / 18.3 MiB (each file's text is freed once it is
indexed). A watching client's warm cost is now the search, a scan of every
symbol: linear in the workspace, the next lever if the cap rises.

Bart then asked for 100k files, a faster search and an index kept between
sessions; the walk moved into `tick`, the index into columns, and a saved
index per folder in the cache directory. Measured (load average ~4, files of
100 lines, 8 symbols each), at 1k / 10k / 100k files: cold (no saved index,
initialize until the index is idle) 28 / 290 / 3008 ms; restart from the
saved index 1.0 / 16.6 / 200 ms, with no file parsed; the narrow query
"w123_4" 0.01 / 0.09 / 2.8 ms and the broad "w" (every name matches) 0.28 /
0.76 / 4.6 ms; one file rewritten and reported, then the narrow query, 0.01
/ 0.07 / 2.8 ms; a client that cannot watch (each request a walk, since
replaced by polling, below) 0.46 / 5.2 / 105 ms. The index
holds 0.7 / 7.5 / 63 MiB, peaks at 1.3 / 13.6 / 126 MiB (the restart's load
buffer on top of the index), and saves 0.4 / 4.0 / 41.5 MiB. Before the
columns (one allocation per file) the 100k search took 10.3 / 40.6 ms and
the peak was 171 MiB.

A client that cannot watch then walked every folder on each request (105 ms
at 100k files). Bart asked for files that change to be checked often and
files that never do seldom; with directory stamps for creations and
deletions (his choice, as was a background timer over checking on each
request, and the 5-minute cap), the request is the search alone: 0.07 / 2.7
ms at 10k / 100k files. Idle, polling 100k files in 1,000 directories costs
0.69 ms per second (1,331 stamps: the directories, and a 300th of the
files), averaged over 5 minutes in which a created file and a file edited in
place both showed.

**Globals across files (2026-10-30).** Rename and references of a global
reach every file that uses it; definition still looks in the cursor's file
only. The symbol index also runs the resolver on each file it parses and
keeps a 64-bit hash (`useKey`) of each global the file reads or writes
(`Entry.uses`, saved with the entry, format 3); `filesUsing` scans them, a
shared hash costing only a needless read. Each file it gives, but the
cursor's, is read (its open document ahead of the disk) and parsed and
resolved, not compiled (`analysis.analyseNames`). A rename checks every such
file with its own folder's settings as the cursor's file is checked
(capture either way, a host global), and is refused when another file
already uses the new name as a global, which would merge the two; a file
that cannot be read or parsed is left alone, with a warning. With walks still under way
the index is incomplete, so a rename is refused until it is idle;
references answer from what is indexed. The browser has no disk: only the
open documents are renamed, and a warning says so. Bart was away when the
two choices came up, so they are mine, to revisit: the resolver-exact
index (over storing every identifier, or scanning every file per
request), and every workspace folder as one global namespace (as
`workspace/symbol` searches, over the cursor's folder only). `_G.x` is
not yet the global `x` to the resolver (TODO.md).

Measured (`bench-lsp`, load average ~2; every file calls the global
`shared_log`, one in 100 writes `shared_total`), at 1k / 10k / 100k files:
references to and a rename of `shared_total` 0.2 / 3.1 / 34 ms (10 / 100 /
1,000 files read); a lookup that finds no other file, about 1 ms at 100k;
the resolver adds about 15% to a cold walk (28 / 298 / 3080 ms without it,
33 / 341 / 3583 ms with). References to `shared_log`, in every file, read
and parse them all: 31 / 313 / 3307 ms, a cold walk's cost. That is the
open limit: answering without the reads means keeping every global
occurrence's position in the index, many times its size.

**Cost, measured** (`zig build bench-lsp`, cross-file table: a literal
`require` per 14 lines, half resolving nowhere, real disk): 0.08 ms added
at 1k lines, 0.9 ms at 10k, 6 ms at 100k (7,143 requires). Each distinct
module name is looked for once per analysis, and a `require` is told to be
the global by the resolver's occurrence lookup (O(log n)); the first cut
scanned every binding per site and added 468 ms at 100k.

### 7.5 Tier 5 — inference (deferred)

lua-language-server-style inference of table shapes propagated through
locals and returns, plus the reserved `name: Type?` annotations as declared
types: member completion and typed hover. Deferred: a type checker in all
but name, and the annotations have no semantics yet.

### 7.6 P7 — JIT lenses

Machine-readable coverage already exists: `--emit-coverage`
(`main.zig:128`) writes a versioned binschema artifact with per-anchor
counters (`coverageser.zig:68`: proto id, pc, traced/interp/fallback
iterations, cycles). P7 extends it, or adds a companion artifact, with
the source identity (path + content hash), anchor kind, byte spans
(mapped through `Proto.spans`, and through `entryPc` for head and
continuation anchors, `trace_code.zig:134`), and structured abort records
(today only in `--dump-aborts`' text).

An editor command ("mahina: show JIT residency") runs the saved file, or
an unsaved snapshot written to a temp file, in a child `mahina --trace
--jit-native --emit-coverage` with the configured args, cwd and system
groups, a timeout (default 10 s, configurable) and bounded output. Results
go to a panel with the full per-anchor table; loop headers get compact
inlay hints. Labels name what they measure: `--jit-stats` alone does not
enable native code (`main.zig:280`, `:310`), "traced" includes tier-1a,
per-anchor cycles are approximate, and non-x86 targets have no TSC, so
hints read e.g. `native 97% iters` and the panel defines the denominator.
Hints clear on the next edit. The doc and the UI must not call this a
sandbox: `--system none` still loads modules and files (`main.zig:557`).

### 7.7 Debugging (doc 75)

LSP has no debugging; the Debug Adapter Protocol does, and it is not
JSON-RPC (a different envelope), so only the `Content-Length` framing is
shared. Reverse step needs nearest-keyframe restore (today's browser
replay restarts from scratch at tier 0, `wasm_entry.zig:402`) and
runtime local-name/register lifetime maps (`compiler.zig:291`). Those are
its own design questions; doc 75 owns them.

## 8. Editor clients

*Superseded 2026-10-27 by D3:* the clients are the viz web UI and Zed,
specified in §13. The original plan below is kept for the record.

- **VS Code** (in-repo, `editors/vscode/`, versioned with the server):
  `vscode-languageclient` starting `mahina lsp` from `PATH` or a setting,
  a TextMate grammar for first paint, `.mah` associated by default and
  `.lua` by opt-in setting. TypeScript, pnpm. The minimal version lands
  with P2. Not published to any marketplace (Q10): a `just` recipe builds
  a `.vsix` to install with `code --install-extension`.
- **Neovim / Helix / Zed / Emacs**: configuration snippets in the README,
  the Neovim one alongside P2.
- **Smoke**: P0 brings a headless client (a Zig test driving the server
  over pipes); `tools/cli-smoke.sh` runs one initialize/shutdown round
  trip on every built platform.

## 9. Performance budget (Rule 20)

Full re-analysis on every change is only acceptable if it's fast; the
budget is explicit and benchmarked.

- **Budget (confirmed by Bart 2026-10-27, Q12):** didChange → publishDiagnostics, measured end
  to end (queueing, analysis, serialisation; excluding the debounce), ≤ 10
  ms for a 10k-line file and ≤ 100 ms for 100k lines, ReleaseFast, this
  machine. Peak memory ≤ 2 analysed versions per document.
- **Known violation:** `addConstant` is quadratic in distinct constants
  (`compiler.zig:454`); fixed first (Outstanding, prerequisite).
- **Not automatically linear:** compilation also runs liveness, dominators
  and maskability analyses, liveness by iterative dataflow
  (`compiler.zig:157`, `bc_liveness.zig:9`). The benchmark measures each
  stage separately; if one misses budget, it is fixed on its own terms
  (incremental reparsing is not the default answer).
- **The benchmark:** `bench_lsp.zig`, next to the other `bench_*.zig`
  roots. Corpus: realistic files (functions, nested loops, tables,
  requires) at 1k/10k/100k lines, plus adversarial ones: a 1 MB single
  line with astral characters, 60k distinct constants, nesting 500 deep,
  a file broken every 20 lines, an edit burst of 200 changes, 50 open
  documents. It reports stage times, peak memory and allocation counts.
  A deliberate run, never a test assertion (Rule 22).

## 10. Testing

- **Protocol**: fragmented and coalesced frames, oversize headers and
  bodies, malformed JSON, string/integer ids, unknown methods,
  notifications, lifecycle transitions, cancellation responses, EOF; over
  in-memory pipes on `std.testing.allocator`.
- **Positions**: utf-8 and utf-16 over ASCII, BMP, astral, `\r\n`, bare
  `\r`, `\n\r`, missing final newline, EOF and clamping.
- **Recovery**: which diagnostics survive a broken statement; no warning
  inside a damaged scope; a broken `local` keeps its binding.
- **Resolver**: compiler output unchanged across the whole test corpus
  after P1c; occurrence and binding tables for every scoping rule in §6.3.
- **Rename**: capture and shadowing refusals, invalid names.
- **Staleness**: a request against a superseded version, results after
  cancellation.
- **Features**: source strings with markers (`--[[1]]`) at request and
  expected-result positions.

## 11. Open questions

None. Q5, Q10 and Q12 were decided by Bart on 2026-10-27, D3 the same day
(§13); the rest in review round 1 (§12).

## 12. Review round 1 (2026-10-27)

Codex and Antigravity reviewed the first draft (425710a) against the
code. Corrections it made, all verified:

- Machine-readable JIT coverage already exists (`--emit-coverage`); the
  draft said `--jit-stats` stderr was all there was.
- Natives carry no arity (`BaseNative`); the draft said they did.
- Several declarations have no name span; the draft assumed every name
  had one.
- Diagnostic messages are not all static; the lint allocates them.
- Compilation is not linear: `addConstant` is quadratic.
- `.mah` was already decided as mahina's extension (doc 00).
- UTF-16 positions count code units, not code points; a cancelled request
  still needs a response; LSP line breaks differ from the compiler's.
- P2 semantic tokens depended on P3's resolver, and comment folding on
  Q11: the phases were in the wrong order.
- P5 overstated how closely static `require` resolution matches runtime.

Where both agreed (Q4, Q5's content, Q8's shape, Q9, Q10, Q7's
direction), the doc follows them. Where they disagreed, Bart delegated the
pick; these are the picks and why:

| Question | Codex | Antigravity | Picked | Why |
|---|---|---|---|---|
| Q1 sync | incremental from the start | full first, incremental later | Codex | Full sync on a 5 MB file re-sends and re-parses 5 MB of JSON per keystroke, the risk Antigravity itself flagged; applying range edits is a small, contained piece of P0. |
| Q2 heap | bare heap now; heap-free analysis long-term | optional heap, placeholder constants | Codex (bare heap) | No compiler change; an optional heap adds a second mode to every constant path for one consumer. |
| Q3 resolver | one shared resolver pass both consume | a collector hooked into `declareLocal`/`loadName`/`storeName` | Codex | Verified: `operandReg`/`localRegOf` and `compileSingleAssign` resolve without those functions, so hooks would miss occurrences. |
| Q6 diagnostics | codes + related locations now | defer | Codex | Codes and a related span are structural fields; adding them when the model is first exposed avoids changing the wire shape after clients rely on it. Prose stays incremental. |
| Q11 comments | trivia-span sink, or a lossless token stream | an `emit_comments` token mode | sink | Leaves the parser's token path untouched with zero cost when off; still enough for a formatter later. |
| Q8 timeout | configurable | strict 2000 ms | configurable, 10 s default | JIT residency only means something on a run long enough to warm up. |
| Threads | reader + worker, or cooperative slices | a buffered reader loop | reader + worker | Slices would make the parser and compiler resumable; phase-boundary checks give the same responsiveness. |

## 13. Clients: the viz web UI and Zed (D3, 2026-10-27)

Bart uses neither VS Code nor Neovim; the clients that matter are the
viz web UI and Zed. Both are first-class: built in-repo, tested, and
landing with P2.

### 13.1 The viz web UI

The viz already runs the VM in a wasm worker (`viz/src/wasm/mahina.worker.ts`),
validates live through `mahina_check` (`viz/src/editor/mahinaLinter.ts`)
and shades loop headers from its run's coverage (`MahinaEditor.tsx`,
`coverageField`). The LSP takes over the checking:

- **The browser host.** `src/wasm_entry.zig` gains `mahina_lsp_init`,
  `mahina_lsp_send(msg_ptr, msg_len)` (one JSON message in; returns a
  buffer of zero or more JSON messages out), `mahina_lsp_next_deadline()`
  and `mahina_lsp_tick(now_ms)`. These wrap the same sans-IO core as the
  stdio host (§5.2); no framing is needed because postMessage already
  delimits messages. The core, `std.json` and the analysis all have to
  build for wasm32-freestanding; the analysis already does (it is what
  `mahina_check` runs).
- **The client.** `@codemirror/lsp-client` (CodeMirror's own LSP client,
  MIT) with a `Transport` whose `send` posts to the worker and whose
  `subscribe` receives the worker's replies. The worker runs debounce
  timers with `setTimeout` against `mahina_lsp_next_deadline`. The client
  implements diagnostics, completion, hover, signature help, definition,
  references and rename, which covers P2, P3 and P5; highlighting stays
  with the existing CodeMirror mode (`mahinaLanguage.ts`), since the
  client has no semantic tokens.
- **Positions.** CodeMirror documents are UTF-16, so this host negotiates
  `utf-16` (§5.3).
- **One checking path.** `mahinaLinter.ts` is replaced by the LSP's
  diagnostics, and `mahina_check` is deleted when nothing calls it: the
  browser and the CLI then check through exactly the same core.
- **Cancellation.** A single wasm call can't see a message that arrives
  during it; the worker queues messages while a call runs and drops
  superseded `didChange`-triggered analyses before calling in. With the
  §9 budget, that's sufficient.
- **Cross-file (P6).** The browser has no filesystem; the viz's open tabs
  (the files it passes to `mahina_run`) are the workspace, given to the
  server as open documents. There is no `mahina.toml` in the browser;
  the viz passes its settings as `initializationOptions`.
- **JIT lenses (P7).** The viz doesn't need the child-process path: it
  already has its run's coverage artifact. Wasm has no native tier and no
  TSC, so the shading reports traced vs tier-0 iterations, not native
  residency, and labels it that way. P7 adds abort reasons to the same
  decorations.
- **Performance.** The §9 budget is for the native CLI. The benchmark
  also runs the wasm build (it is what the viz uses) and reports its
  numbers; the worker keeps analysis off the UI thread, so a slower
  analysis delays diagnostics, not typing.

### 13.2 Zed

A Zed language extension has four parts (Zed docs,
`docs/src/extensions/languages.md`): language metadata, a **required**
Tree-sitter grammar, Tree-sitter queries, and optional language servers.

- **`editors/zed/`**: `extension.toml` naming the grammar and the
  `mahina` language server; `languages/mahina/config.toml` (`.mah` suffix,
  `--` line comments, brackets); and the small Rust extension (compiled
  to wasm by Zed) whose `language_server_command` returns `mahina lsp`
  found on `PATH`. Installed with Zed's "install dev extension"; not
  published (Q10's spirit).
- **`editors/tree-sitter-mahina/`**: the grammar, referenced from
  `extension.toml` by this repository, a pinned rev and `path =
  "editors/tree-sitter-mahina"` (Zed's grammar manifest supports a
  subdirectory, `crates/extension/src/extension_manifest.rs`
  `GrammarManifestEntry.path`). Queries: `highlights.scm`,
  `brackets.scm`, `outline.scm`, `indents.scm`.
- **A second grammar, on purpose and bounded.** Zed builds highlighting,
  bracket matching, outline and indentation on Tree-sitter, so it needs
  one regardless of the LSP. That is a second grammar, which §2 rules out
  for *diagnostics and scoping*; it is acceptable here because it only
  drives presentation. Every error, warning, definition and rename still
  comes from the server. The drift check (Outstanding) keeps it honest:
  the Tree-sitter grammar must parse every mahina source in the repo that
  mahina's parser accepts without an `ERROR` node. Zed can also layer the
  server's semantic tokens over Tree-sitter highlighting (its
  `semantic_tokens` setting), which is where P4's locals-vs-globals
  colouring shows up.
- **Positions.** Zed negotiates its own encoding; the server picks
  `utf-8` if offered, else `utf-16` (§5.3).
- **JIT lenses (P7).** A code action ("Show JIT residency") runs
  `workspace/executeCommand`; the server spawns the child run (§7.6) and
  then serves the results as `textDocument/inlayHint` until the next
  edit.

## References

- LSP 3.17 specification —
  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/
- Debug Adapter Protocol — https://microsoft.github.io/debug-adapter-protocol/
- Doc 00 Phase 7 v4–v6 (viz editor, `mahina_check`, located errors) and
  §"Two source extensions" — `docs/design/00-architecture.md`
- `src/wasm_entry.zig` `check` — today's compile-only path
- `src/compiler.zig` — `warnUnknownGlobals`, `addConstant`, name resolution
- `src/coverageser.zig` — the coverage artifact P7 extends
- `src/stdlib/package.zig` — `package.searchpath` semantics P6 mirrors
- Codex review thread `01a17a97-e280-7cc1-9c5c-9334d3c5a39c`
- lua-language-server (sumneko) — the reference for tier 5 inference
- `@codemirror/lsp-client` — https://code.haverbeke.berlin/codemirror/lsp-client
- Zed language extensions — `docs/src/extensions/languages.md` in
  zed-industries/zed
