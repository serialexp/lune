# 74 — A language server (`mahina lsp`) — Design

Status: draft, not yet implemented. Direction decided 2026-10-27 (server in
Zig as a CLI subcommand; design before code). Review round 1 (Codex,
Antigravity) folded in 2026-10-27; Bart delegated the picks where the
reviewers disagreed (§12). Open: Q5's file format, Q10's publisher, and
confirming the §9 budget.
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
- [x] **Q10 (part) — file extension and extension home** (§8): `.mah` by
  default (doc 00 §"Two source extensions"), `.lua` opt-in; the VS Code
  extension lives in-repo under `editors/vscode/`.

### Outstanding

- [ ] **Q5 — workspace configuration file** (§7.4): name and format of the
  project file (`mahina.toml` vs `.mahinarc`); the content is decided.
- [ ] **Q10 (rest) — marketplace publisher** for the VS Code extension
  (Bart's account decision).
- [ ] **Q12 — confirm the §9 budget** numbers.
- [ ] **Prerequisite — constant dedup is quadratic** (§9, `TODO.md`):
  `Compiler.addConstant` (`src/compiler.zig:454`) scans the pool per
  constant. Fix with an identity-keyed map before the P2 benchmark can
  meet budget.
- [ ] **P0 — transport, lifecycle, snapshots** (§5): `src/lsp/jsonrpc.zig`
  framing with limits, the reader thread + analysis worker, cancellation
  with responses, the handshake and shutdown/exit state machine,
  position-encoding negotiation, the incremental document store, a
  headless smoke client; protocol tests over in-memory streams.
- [ ] **P1a — AST name spans** (§6.3): `name_span` on `local_function`,
  numeric/generic `for` variables, `FuncName` components, named table
  fields; implicit `self` gets a synthetic, zero-width span instead of the
  body's.
- [ ] **P1b — parser recovery regions** (§6.2): `synchronize` records the
  skipped span; error nodes where a statement was dropped; recovered
  declarations kept where they are trustworthy.
- [ ] **P1c — the shared resolver** (§6.3): `src/resolve.zig`, a pass over
  the AST producing bindings and occurrences; the compiler reads its
  results instead of resolving names itself; equivalence tests on the
  whole test corpus.
- [ ] **P1d — diagnostics model** (§6.4): codes and related spans on
  `Diagnostic`; message ownership (copied out of the compile arena);
  OOM reported as "analysis incomplete", not silently dropped; the
  compiler keeps going after a `CompileError` where it can.
- [ ] **P2 — diagnostics end to end** (§6): `publishDiagnostics` with
  versions, empty sets on clear; the same frontend path for the LSP and
  `mahina_check` (the wasm check gets the recovery work too).
- [ ] **P2 bench** (§9): `bench_lsp.zig` with the adversarial corpus.
- [ ] **P2 clients** (§8): the minimal VS Code extension and a Neovim
  snippet, enough to use P2 in a real editor.
- [ ] **P3 — navigation and basic completion** (§7.2): definition,
  references, document highlight, prepareRename/rename with capture
  checks; completion of keywords and in-scope names.
- [ ] **P4 — syntactic features** (§7.1): semantic tokens (with comments
  from the trivia sink and locals vs globals from the resolver), document
  symbols, folding ranges (incl. comments), selection ranges.
- [ ] **P5 — stdlib knowledge** (§7.3): hover, `lib.` member completion,
  signature help from the generated table.
- [ ] **P6 — cross-file** (§7.4): `require` resolution mirroring
  `package.searchpath`, the project config (Q5), open-document overlays,
  module exports for `local M = {} … return M`, workspace symbols.
- [ ] **P7 — JIT lenses** (§7.6): extend the `--emit-coverage` artifact
  with source spans and structured abort records; the editor command,
  panel and inlay hints.
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
- **Every LSP editor.** Plain LSP 3.17 over stdio; nothing editor-specific
  in the server.
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
  server.zig        reader thread, worker, dispatch, lifecycle, capabilities
  documents.zig     document store: text, version, line index, latest analysis
  position.zig      byte offset <-> (line, character) in the negotiated encoding
  analysis.zig      parse + resolve + compile for one document version
  stdlib_db.zig     generated builtin table (P5)
src/main.zig        `lsp` subcommand, next to `viz`
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

Two threads:

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
Binding    { id, kind: local|param|for_var|local_function|self|global|builtin|unresolved,
             decl_span, visible_from, scope_span, captured: bool }
Occurrence { span, binding: BindingId, access: read|write|read_write }
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
`scope_span`); a builtin. Globals rename within the open workspace only,
with a warning that other chunks may use them. Completion here is
keywords plus the names visible at the cursor.

### 7.3 P5 — stdlib knowledge

Hover, `lib.` member completion and signature help need a table of name,
signature, parameters, one-line description, tier and system group.
Natives carry no arity or parameter names (`BaseNative`,
`function.zig:594`), so the table comes from the inventory CSV
(`docs/lua-stdlib-inventory.csv`, already canonical under Rule Z-5),
which gains structured `signature` columns (parameters with names and
optionality, overloads as separate rows). The build generates
`stdlib_db.zig` from it, filters `excluded` and `not-started` rows, and a
test cross-checks the generated names against the natives actually
registered per system group. Inventory tier alone is not availability:
natives are installed by group (`function.zig:621`).

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
The module cache invalidates on file changes (`workspace/didChangeWatchedFiles`),
on config changes, and when a new file could shadow an earlier candidate.

Module exports: P6 includes one bounded piece of shape tracking — fields
assigned to a local table that the chunk's top-level `return` returns
(`local M = {} … M.f = … return M`, and a returned constructor). Anything
more is tier 5.

**Project config (Q5 open on name/format).** Versioned, never executed,
with LSP `initializationOptions` overriding it, documented precedence and
per-root behaviour in multi-root workspaces. Content: runtime cwd,
`package.path`, enabled system groups, extra host globals with optional
member descriptions (for embedding hosts), and diagnostic code
suppressions.

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

- **VS Code** (in-repo, `editors/vscode/`, versioned with the server):
  `vscode-languageclient` starting `mahina lsp` from `PATH` or a setting,
  a TextMate grammar for first paint, `.mah` associated by default and
  `.lua` by opt-in setting. TypeScript, pnpm. The minimal version lands
  with P2; publisher is Q10.
- **Neovim / Helix / Zed / Emacs**: configuration snippets in the README,
  the Neovim one alongside P2.
- **Smoke**: P0 brings a headless client (a Zig test driving the server
  over pipes); `tools/cli-smoke.sh` runs one initialize/shutdown round
  trip on every built platform.

## 9. Performance budget (Rule 20)

Full re-analysis on every change is only acceptable if it's fast; the
budget is explicit and benchmarked.

- **Budget (proposal, Q12):** didChange → publishDiagnostics, measured end
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

- **Q5 — config file name and format.** `mahina.toml` or `.mahinarc`
  (and so TOML vs something else). The content is settled (§7.4).
- **Q10 — marketplace publisher** for the VS Code extension.
- **Q12 — the §9 budget numbers.** Proposed, not yet confirmed.

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
