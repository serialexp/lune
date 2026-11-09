# 83 — A source formatter (`mahina fmt`) — Design

Status: partial — phases 0 (printer), 0b (tokens), 1 (comments), 2 (builder), 3 (corpus gate) and 4 (CLI) landed; phases 5–7 outstanding. Every style decision made by Bart
2026-11-10; review round 1 (Codex, Antigravity) folded in 2026-11-10 (see
"Review"); the engine-level choices not asked about are marked in §12.
Owner: claude (coral-raven)
Last updated: 2026-11-10 (phase 4)

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole phases to Done once everything inside them is checked.

### Done

- [x] **D1 — one fixed standard, no options** (§3): decided by Bart
  2026-11-10. gofmt / `zig fmt` shaped: there is no config file, no flag that
  changes the output, and no escape-hatch directive.
- [x] **D2 — a Wadler-style document printer** (§4.3): decided by Bart
  2026-11-10. Groups that fit the width print flat, the rest break; output is
  a pure function of the tree.
- [x] **D3 — a pure source-to-source function, many front ends** (§8): decided
  by Bart 2026-11-10. `src/format.zig` takes bytes and returns bytes; the CLI,
  the language server, wasm and the C API all call it.
- [x] **D4 — comments attach to the next symbol** (§5): decided by Bart
  2026-11-10, with trailing comments staying put (confirmed the same day).
- [x] **D5 — the style** (§3): decided by Bart 2026-11-10: 4 spaces, width
  100, prefer-double quotes, `f("x")` call form, tables by count and
  simplicity with fill for literal arrays, trailing commas, blocks always
  expanded, blank-line rule, semicolons and provably-redundant parentheses
  removed, LF output.
- [x] **D6 — syntax errors: refuse** (§7.1): decided by Bart 2026-11-10. A
  file with diagnostics is returned unchanged with those diagnostics.
- [x] **D7 — format the repo's own sources, then gate** (§9): decided by
  Bart 2026-11-10. One mechanical commit, then `fmt --check` in CI.

- [x] **Review round 1** (§Review): Codex and Antigravity, 2026-11-10. Their
  findings are applied or rejected with reasons below; two points concern
  Bart's own decisions (call sugar does not exist, §3; template holes, §6.8).

- [x] **Phase 0 — the printing core.** `src/format_doc.zig`: the document
  algebra (text, raw, line, softline, hardline, break_parent, group, indent,
  fill, hug, lineSuffix, ifBreak, alt) and the fitting printer; 15 unit tests print
  hand-built documents, including the hug, trailing-comment, fill and
  bounded-lookahead cases (`Stats.fits_steps` is asserted, Rule #22). Done
  2026-11-10.

- [x] **Phase 0b — expose the token stream.** `parser.parseFormat` (next to
  `parseTrivia`) returns the AST and its token slice (in the AST's arena); the
  trivia and diagnostics already come through the sinks callers pass. The only
  edit to the parser; no AST node changed. Done 2026-11-10.

- [x] **Phase 1 — comment attachment.** `src/format_comments.zig`: a
  `Comments` index over the lexer's trivia that the builder queries in source
  order: `takeLeading` (own-line and inline comments before an item, with
  blank-line flags), `takeTrailing` (same-line comments after code),
  `gapHasBlank`, `pendingBefore`. Implemented as lazy consumption by the
  builder rather than a separate attachment pass, so no position arithmetic is
  repeated; a comment the builder never reaches makes the formatter refuse
  (never lose, never move across a symbol). 7 tests. Done 2026-11-10.

- [x] **Phase 2 — statements and expressions.** `src/format.zig`: every
  statement and expression form of `ast.zig` built into documents (templates
  verbatim, with comments inside a hole travelling with it); the
  semicolon-before-`(` rule; the redundant-paren rule. Deviations from the
  plan, to revisit: name lists are not wrapped; blank lines between expanded
  table entries are preserved; a comment inside an expression other than in a
  list or between statements makes the formatter refuse (`UnplacedComment`).
  Done 2026-11-10.
- [x] **Phase 3 — correctness gates.** `src/format_gate_test.zig` runs the
  formatter over `bench`, `tests`, `viz/fixtures` and `src/stdlib` (70 files):
  each must format, be a fixed point, and compile to the same program
  (recursive proto signature, no line info). All 70 pass. The benchmark
  (Q2) is still outstanding. Done 2026-11-10.

- [x] **Phase 4 — CLI.** `mahina fmt [--check] [--stdin] <paths>` (§8.1):
  `src/fmt_cli.zig` (logic and tests) behind a `fmtMain` in `main.zig`. Sorted
  walk, fixed skip list, symlinks skipped and reported, atomic same-directory
  rewrite keeping the mode, size+mtime re-check before the rename; exit 1 on
  refusal, failure, or a changed file in `--check`. Done 2026-11-10.

### Outstanding

- [ ] **Method-chain breaking and name-list wrapping** (§6): not built in
  phase 2; long chains and name lists currently stay on one line.
- [ ] **Comments inside expressions** (§5): refused in v1; place them or keep
  refusing, decided once real code hits it.
- [ ] **Phase 5 — language server.** `textDocument/formatting` and
  `rangeFormatting`; the `documentFormattingProvider` capability (§8.2).
- [ ] **Phase 6 — wasm, C API, viz editor.** `mahina_format` export, the
  capi function, a Format command in the viz editor (§8.3).
- [ ] **Phase 7 — format the repo, add the gate.** One commit that reformats
  every `.lua`/`.mah` file in the tree, then `just fmt-check` in CI (§9).
- [ ] **Q1 — where the table thresholds sit** (§6.5): settled by running the
  rule over the corpus and reading the diff.
- [ ] **Q2 — does the printer stay linear on pathological nesting** (§10):
  settled by a benchmark over a deeply nested generated file.
- [ ] **Q3 — newlines inside long strings and templates** (§3, §7.2): whether
  the lexer already folds `\r\n` to `\n` inside long-bracket strings (as Lua
  does); settled by reading and testing the lexer in phase 2. If it does not,
  CRLF inside those regions is preserved and the LF-only gate exempts them.

## Why this exists

We have a language server, a Tree-sitter grammar and a viz editor, and no
shared answer to "what does mahina code look like". Every file in the repo is
laid out by whoever wrote it, and a diff that re-wraps a table is review noise.
A built-in formatter ends the conversation: one standard, applied by a tool,
the same in the CLI, the editor, CI and the browser. This doc is the contract
for that tool.

It is a language feature in the sense that matters: the standard is part of
the toolchain, versioned with the compiler, and fed by the same parser, so it
cannot drift from the syntax (a template, an attribute, `global`) the way an
external formatter would.

## Goals

1. **One output.** For every valid source file there is exactly one formatted
   form; nothing is configurable.
2. **Idempotent.** `fmt(fmt(x)) == fmt(x)`.
3. **Never changes meaning.** The compiled bytecode of the input and of the
   output are identical (§7.2).
4. **Never loses a comment.** Every comment in the input appears, with the
   same text, in the output.
5. **Fast enough to run on every debounced keystroke** in the editor, and over
   the whole repo in CI (§10).
6. **One implementation** behind every front end (§8).

## Non-goals (v1)

- Options, a config file, ignore directives (D1).
- Reflowing comment text or wrapping long comments.
- Formatting inside strings, long-bracket strings or template text. The
  expressions inside a template's `{ }` holes are handled by §6.8; the text
  between them is not touched.
- Linting or renaming; the formatter changes layout only, apart from the
  token-level normalisations in §3.
- Formatting code that fails to parse (D6).
- Formatting Lua embedded in other files (Markdown fences, Zig test strings).

## 3. The standard

| Rule | Decision |
| --- | --- |
| Indent | 4 spaces per level; never tabs |
| Width | 100 columns; a group fits or breaks (§4.3) |
| Line ending | LF always; one final newline; no trailing whitespace |
| Strings | §6.10 (prefer double; long-bracket strings and template text untouched) |
| Call form | always `f(x)`. mahina has no call sugar today (`f "x"` / `f{...}` are a syntax error, `parser.zig` header: deferred), so there is nothing to rewrite; if the language ever gains it, the formatter normalises it to `f(x)` in the same change |
| Semicolons | removed, and synthesised where the next statement begins with `(` (§6.1) |
| Blocks | every block body on its own indented lines; no one-line `if`, `function` or loop forms |
| Blank lines | a run of blank lines collapses to one; none at the start or end of a block; one blank line is *inserted* before and after each top-level function declaration (not at the start or end of the file); before means before the declaration's attached leading comment group, never between the comments and the function |
| Parentheses | removed only when provably redundant (§6.9), in one step; operand parentheses between operators are kept |
| Tables / argument lists | §6.5 |
| Trailing comma | always, in a table printed one entry per line; never in an argument list, parameter list or name list |
| Numbers | token text kept as written (the AST stores the value; the formatter re-reads the span) |
| Operators | a space either side of binary operators; no space after a unary operator except `not`, with one exception: a space is kept wherever two adjacent tokens would otherwise lex as a different token (`- -x` must not become `--x`, a comment) |

Everything not listed here is decided by §6.

## 4. Architecture

### 4.1 Where it lives

```
src/format_doc.zig        the document algebra and the fitting printer (no language knowledge)
src/format_comments.zig   trivia → leading / trailing / dangling attachment
src/format.zig            AST + comments → document; the public entry points
```

None of them takes a `Vm` or any `std.Io`; they take an `std.mem.Allocator`
(Rule Z-4) and return a result owned by it, so the language server and wasm
can call the same functions the CLI does.

### 4.2 The pipeline

```
bytes ──► lexer (tokens + trivia) ──► parser (AST, diagnostics) ──► refuse if diagnostics
                                         │
                       trivia + tokens ──┴──► comment attachment (§5)
                                         │
                                  AST ──►│──► document builder (§6) ──► printer (§4.3) ──► bytes
```

`parser.parseTrivia` returns the AST and the comments the lexer skipped, with
byte spans (doc 74 §6.5), but not the token list, and the AST is a semantic
tree, not a syntax tree. Review showed what it loses: semicolons, the
prefixed-versus-postfixed placement of attributes (`local <const> a, b`
against `local a <const>, b`), `then`/`do`/`end` and delimiter positions, the
`function` keyword of a literal (its span starts at `(`), the boundaries of a
template's chunks and holes, a method declaration's synthesised leading
`self` parameter, and `await e` (a call of an intrinsic). Decision (claude;
review): do not widen the AST. The formatter reads the **token stream**,
which phase 0b makes `parseFormat` return, and finds every such position by
scanning the tokens inside a node's span; the AST gives the structure and
the tokens give the syntax. Builder rules that undo the parser's rewrites:
a method declaration drops its synthesised `self` (the parameter whose span is
the method name's start); an intrinsic call prints as `await e`; number and
string tokens print from their source text.

Blank lines and "same line" tests come from a line-start table built once
from the source bytes (a binary search per token), not from the lexer: the
`Trivia` records carry only byte spans.

Both sinks are lossy on allocation failure (`Trivia.incomplete`,
`Diagnostics.incomplete`). The formatter returns an error, never text, when
either is set, and propagates `OutOfMemory`.

### 4.3 The printer

A document is a tree of: `text`, `line` (a space if flat, a newline if broken),
`softline` (nothing if flat, a newline if broken), `hardline` (always a
newline; forces every enclosing group to break), `group` (print flat if it fits
in the remaining width, else break its direct `line`s), `indent`, `fill` (as
many items per line as fit, for literal arrays, §6.5), `hug` and `lineSuffix`.

`hug(doc)` isolates an embedded multi-line document from its enclosing group:
a `hardline` inside a hugged element breaks the element's own groups but does
not propagate past the `hug` boundary, and the enclosing group is decided by
whether the text up to the hugged element's first newline fits (Prettier's
conditional group). This is what lets `f(a, function() … end)` keep `a` on
the call's line (§6.2) although a function body contains hardlines.

`lineSuffix(text)` queues a trailing comment: it is flushed at the next
newline, after any comma, semicolon or closing delimiter that the code
itself prints on that line, so those can never land inside a `--` comment. It
is not counted against the width of the group it follows.

The printer is Wadler's. "Fits" stops as soon as the remaining width is
exhausted, so deciding a group costs at most the width (100), not the length of
the line: stopping at the next newline is not enough (a long single-line input
has none) and is not the rule. Q2 checks the aggregate on nested input. The
algebra is its own file because it has no language in it, and its unit tests
print hand-built documents.

## 5. Comments

The rule, as decided (D4):

- A comment attaches to the **next symbol** (statement, table entry, argument,
  parameter, `elseif`/`else` branch, …) **unless there is a blank line between
  them.**
- A run of own-line comments, or a multi-line `--[[ ... ]]` comment, attaches
  as a unit if its **last line** is directly followed (no blank line) by a
  symbol.
- A comment on the same line **after** code (`x = 1 -- note`) is *trailing*: it
  stays on that line, one space after the code. It is never moved to its own
  line, even when the line then exceeds the width.
- A comment that is not directly above a symbol (a blank line follows it, or
  nothing follows it before the block's `end`) is *free-standing*: it keeps its
  place between its neighbours, with the blank-line rule applied around it.
- A comment inside an otherwise empty block, table or argument list is
  *dangling*: it is printed inside the brackets on its own indented line(s).

An attached comment moves with its symbol: it is printed on the lines
immediately above wherever the symbol is printed, at the symbol's indentation.
Comment text is never altered, except that trailing whitespace is trimmed; a
block comment's inner lines are not re-indented (the bytes between `--[[` and
`]]` are preserved).

**Ownership is by token boundary, not by node.** "Symbol" in the rule means
the next token that begins a syntactic item: a statement, a table entry, an
argument, a parameter, a name, an operand, and also the closing tokens `end`,
`until`, `else`, `elseif`, `)`, `]`, `}`. So:

- an own-line comment before a closing token (`f(\n a\n -- last\n)`, a comment
  after the final statement of a block) attaches to that closing token and is
  printed as the last line(s) of the container, at the container's inner
  indent, before the closing token;
- a comment between tokens of one construct's header (`if x -- c\n then`,
  `local a = -- c\n b`) is trailing on the previous token if on its line, and
  otherwise leading on the next, which forces a break at that point;
- a comment inside an *empty* container is dangling (above); inside a
  non-empty one it is leading/trailing on some entry or the closing token,
  so no comment is ever "between" owners.

The table of header positions (around `then`, `do`, `=`, attributes, type
paths, operators in a broken chain) is built in phase 1 as golden tests, one
per position; each is an application of this paragraph, and none may move a
comment across another symbol.

Attachment is computed once over token and trivia positions, before
printing, so the printer sees "this node has leading comments […]" and does no
position arithmetic. A trailing comment is a `lineSuffix` (§4.3). It forces its
enclosing group to break only if code follows it inside that group (the
remaining arguments, entries or operands cannot share its line); a comment
after a statement's last token forces nothing. A comment never sits inside a
flat group.

Lexical regions: the byte-preservation of block comments, long strings and
template text applies inside those tokens only. Trailing whitespace is trimmed
and `\r` dropped from line comments and from code lines; the bytes inside a
block comment are kept as they are, including trailing spaces, and the
comment gate compares the *sequence* of comment texts (§7.2).

## 6. Layout rules

The builder maps each `ast` form to a document. The rules not obvious from the
table in §3 follow.

### 6.1 Statements

- One statement per line. The AST has no semicolons, so a `;` is *synthesised*
  (never "kept"): it is printed before a statement whose first token is `(`
  (an expression statement `(f or g)()`, an assignment `(t)[1] = 2`) when the
  previous statement ends in an expression: Lua reads `f()\n(g)()` as one
  call. A previous statement that ends in the `end` of a block statement
  (`if`, `while`, `for`, `do`, a function declaration) cannot absorb it and
  gets none; `local f = function() end` ends in an expression, so it does, and
  so does `repeat … until cond`. The `;` is printed on the previous
  statement's line before its trailing comment (`f(); -- note`). §7.2 catches
  a miss.
- `local a, b: T = e1, e2`, `global`, attributes: the name list is an ordinary
  group (one per line, indented, if it ever does not fit); attributes print
  in the position the source had them (prefix `local <const> a, b` or postfix
  `local a <const>, b`), found from the tokens (§4.2). A long value list wraps
  as an argument-style list (§6.4) indented after the `=`.
- `if`/`elseif`/`else`, `while`, `repeat … until`, `for`, `do`: keyword and
  condition on the first line, body indented, `end` (or `until cond`) on its
  own line. A condition that does not fit wraps per §6.3.
- `return`: the value list wraps as in §6.4.
- Compound assignment prints with its source operator spelling.
- `function a.b:m(params) … end`, `local function`, `global function`, and
  `async function`: header on one line if it fits, else the parameter list
  breaks (one per line, no trailing comma).

### 6.2 Function literals

`function(a, b) … end` as an argument or value: the body is always expanded
(§3). When a function literal is the last argument of a call, the call hugs it
(`f(a, function() … end)`): the arguments before it stay on the call's line,
and only the function's own body breaks (`hug`, §4.3). The same holds for a
table constructor that is the last or only argument (`f({ … })`), which is
laid out by §6.5's rules, not the argument list's. Text before the hugged
element is still counted against the width: if `f(a, b,` itself does not fit,
the whole argument list breaks instead.

### 6.3 Binary and unary expressions

A chain of one operator precedence is one group: flat if it fits, otherwise
broken before each operator after the first, one per line, indented one level
from the line it started on. `and` / `or` chains and `..` chains follow the
same rule. An operand that is itself a chain of a different precedence is its
own nested group.

### 6.4 Calls, method chains and argument lists

An argument list is a group: flat if it fits, else one argument per line,
indented, closing `)` on its own line. A method chain (`a:b():c():d()`) with
more than two calls that does not fit breaks before each `:` or `.` after the
first, indented. A single table or function argument hugs (§6.2).

### 6.5 Tables

A table constructor is printed one entry per line (the "expanded" form) if
**any** of these holds, and flat otherwise:

1. it does not fit in the remaining width;
2. it has more than four entries;
3. one of its entries is a table constructor or a function literal;
4. one of its entries carries a comment.

Exception — **fill** (D5): a table whose entries are all positional and all
number literals, short strings (at most 12 characters) or `true`/`false`/`nil`
is never expanded by rule 2; when it does not fit on one line it is printed as
a `fill` (as many entries per line as fit, continuation lines indented one
level, trailing comma), and flat when it does.

A table that is a call's last or only argument hugs (§6.2); a table among
several arguments is laid out by these rules in place. An empty table is
`{}`; a non-empty flat one has a space inside the braces (`{ a = 1 }`). "Twelve
characters" is the string token's source bytes between its quotes, undecoded
(`"\x41\x42"` is eight). The thresholds (four entries, twelve bytes) are chosen
once here; Q1 reads them against the corpus, and any change is a new decision
of Bart's.

### 6.6 Keyed and named fields

`name = value` and `[key] = value`; a key written `["name"]` stays as written
(rewriting it to `name =` is a change the formatter does not make).

### 6.7 Declarations: attributes, `global`, types

`global x <const>`, `global *`, `global <const> *`, and type annotations
(`a: Foo.Bar?`, return types) print in the form the parser read; the formatter
normalises only the spacing.

### 6.8 Templates

`` `text {expr} text` `` is one token run to the formatter, printed **from its
source bytes, verbatim: text chunks and hole contents alike**. Review found
every alternative unsafe: a hole may contain newlines (doc 82 §3.3), a `--`
comment (flattening it would comment out the closing `}` and the string), a
function literal (whose body §3 expands), and `{ {1} }` (whose whitespace the
`{{` diagnostic depends on); and a hole formatted only when it fits would
change shape when an edit moved it across column 100, breaking idempotence.
Verbatim is idempotent by construction. The cost is that expressions inside
holes are not reformatted (a hole is usually a name or a short call). The
width gate exempts template lines (§7.2). Formatting hole expressions is a
possible later decision of Bart's, not part of v1.

### 6.9 Redundant parentheses

A pair of parentheses is removed only when all hold: its inner expression is
not a call, method call, `await` or `...` (a call and `...` yield one value
inside parentheses, many outside, so the pair is meaning); and the pair wraps a
*whole* expression, as one element, in one of these positions: the condition
of `if`/`elseif`/`while`/`until`, an element of a `return` or `local`/`global`/
assignment value list, a call argument, a table entry value, or a bound of a
numeric `for`. Parentheses inside an operator expression (`(a and b) or c`),
around a prefix (`("x"):rep(3)`, `(f or g)(x)`, `(t or {}).x`), and every pair
around a call, `await` or `...` are kept.

Removal is a **tree rewrite done before layout**, to its fixpoint: a chain
`((1 + 2))` collapses in one step to `1 + 2`, and layout decisions (the fill
eligibility of `{ (1), (2), (3), (4), (5) }`, a table's entry count) are made
on the rewritten tree, so a second pass changes nothing. The bytecode gate
(§7.2) verifies the result: a removed pair that mattered cannot ship.

### 6.10 Strings

The token is scanned escape by escape (a backslash always consumes the next
byte, so `\\` is an escaped backslash and the delimiter after it is the
delimiter). The count compares the delimiter-kind characters in the *source*
content, an escaped `\"` or `\'` counting as one of its kind. Double quotes are
used unless the content has more `"` than `'`. When the delimiter changes, the
only edits are: a quote of the new delimiter's kind gains a backslash, and a
quote of the old delimiter's kind that was escaped loses it; every other
escape (`\\`, `\n`, `\z`, `\ddd`, `\xHH`, `\u{…}`, backslash-newline) is copied
byte for byte. Long-bracket strings (`[[…]]` and every `[=[…]=]` level) are
never touched. Gate 2 compares string constants by content, so any mistake
here fails the build.

## 7. Correctness gates

These are tests and CI checks. They are part of phase 3, which lands with
phase 2.

### 7.1 Refuse on error (D6)

`format(src)` returns the diagnostics and no text when the parser reports any
error, or when `Trivia.incomplete` or `Diagnostics.incomplete` is set (a lossy
sink could drop a comment or hide an error); the CLI exits non-zero and writes
nothing for that file; the LSP returns no edits (the editor already shows the
diagnostics). This holds for range formatting too: the whole file is parsed
first. The formatter adds no diagnostics of its own.

### 7.2 Properties

Run over a corpus (every `.lua`/`.mah` in the tree and `tests/lang/`, plus
programs from a small grammar-driven generator in the test):

1. **Idempotent:** `fmt(fmt(x)) == fmt(x)`.
2. **Same program:** the compiled output of `x` and `fmt(x)` is identical,
   compared recursively over every proto: instruction stream, constants (strings
   by content, not address), parameter count, vararg flag, upvalue descriptors,
   close-variable metadata, with line info stripped (lines legitimately
   differ). This catches a wrong parenthesis removal, a missing `;`, a quote
   swap and an unary-spacing accident. A file that parses but does not compile
   (for example an invalid escape) is formatted and reported, and skips this
   gate by name in the test output.
3. **Comments preserved, in order:** the *sequence* of comment texts is
   identical. (The formatter never reorders statements or comments, so order is
   a property worth checking; a multiset would hide a wrong attachment.)
4. **Types preserved:** the sequence of type annotation texts is identical
   (bytecode cannot see them).
5. **Output is valid:** `fmt(x)` parses with no diagnostics.
6. **Shape:** no trailing whitespace and no `\r` outside block comments, long
   strings and template text (Q3); exactly one final newline.
7. **Width:** for every output line, the width of the code before any trailing
   comment is at most 100 columns, except lines that contain a long-bracket
   string or a template, own-line comments, and unbreakable atoms wider than
   the width. The exceptions are listed by the test, and the code prefix is
   measured on its own so a long trailing comment cannot hide an overlong line.

### 7.3 Pinned shapes

Golden tests (`tests/fmt/*.in.mah` → `*.out.mah`) for each §6 rule, including
the comment rule's cases and the doc 76 and doc 82 syntax. A change to the
standard changes goldens in the same commit.

## 8. Entry points

### 8.1 CLI

`mahina fmt [--check] [--stdin] [paths…]`

- with paths: rewrite each `.lua`/`.mah` file in place (directories walked;
  there is no ignore file), atomic write, skipped when already formatted;
- `--check`: print the names of files that would change, exit 1 if any, write
  nothing (the CI form);
- `--stdin`: read stdin, write the result to stdout (the editor form);
- a file with syntax errors is reported and skipped; the exit code is
  non-zero, but the other files are still formatted.

File-system contract: only the named paths are walked; symlinks are not
followed (a symlinked file or directory is skipped and reported, so there are
no cycles); a fixed skip list (`.git`, `zig-out`, `.zig-cache`, `node_modules`,
`target`) is never entered when walking a directory (it is not an ignore file,
it cannot be configured). A rewrite writes a temporary file in the same
directory, copies the mode, re-checks that the original's size and mtime are
unchanged since the read (otherwise it skips the file and reports it, so an
editor's newer save is never overwritten), and renames over it; the temporary
file is removed on every failure path.

The subcommand sits with `lsp` in `main.zig`; the logic stays in `format.zig`.

### 8.2 Language server

`documentFormattingProvider` and `documentRangeFormattingProvider`. Whole
document: edits diffed to the changed lines so the editor keeps its cursor and
undo history. Range: the **whole file is formatted** (so a range result is
always what whole-document formatting would produce there, since a table's or
an argument's layout depends on its whole construct), and only the diff hunks
that intersect the range are returned as edits; a hunk that straddles the range
edge is returned whole. A file with any syntax error returns no edits (D6), for
range formatting as well. No `onTypeFormatting` in v1.

### 8.3 wasm, C API, viz

A `mahina_format(src_ptr, src_len)` export alongside `mahina_check`
(`src/wasm_entry.zig`), returning text or diagnostics through a result struct
that has a matching `mahina_free_format_result` (the `mahina_check` pattern); the
matching function and free function in `src/capi.zig`; and a Format command in the viz editor that calls it. `bun
test` in `viz/` gets one test that formats and re-runs a sample.

## 9. Formatting the repo (D7)

Phase 7 is one mechanical commit: run `mahina fmt` over every `.lua`/`.mah`
under `bench/`, `tests/`, `src/` and `viz/` (about 70 files today), then add
`just fmt-check` (`mahina fmt --check .`) to the CI recipe.

Reformatting shifts line numbers. Before the commit, list every test and
reference that pins a line (error messages with `:line:`, trace dumps, the
replay index's `SafepointLine`, `bench/refs`) and update those in the same
commit. `just hashgate` must stay identical in all three modes: the programs'
*output* does not depend on layout, and a changed digest means the formatter
changed meaning, not that the digest needs refreshing.

## 10. Performance

A formatter that runs on a debounced keystroke has a budget (Rule #20): **100
ms for a 5,000-line file, ReleaseFast, on the reference machine, linear in input
size, no per-node heap allocation in the printer** (the document is built into
one arena and the output into one buffer; "fits" is bounded by the remaining
width, §4.3). Phase 3 adds a benchmark, not a test (Rule #22): the largest
corpus file; generated 50,000-line files of each of wide argument lists, long
operator chains, dense comments and a single 1 MB line; and nesting of depth
200 of tables and calls. It records time and peak memory and is compared with
itself over time. Comment attachment, line-table lookups and the LSP diff are
each O(n log n) or better, and the benchmark covers them.

## 11. Phasing

Phase 0 (printer) and phase 1 (comments) have no language dependency and can
land first. Phase 2 and its gates (phase 3) are one unit: a builder without the
bytecode-equivalence gate is how formatters change programs. Phases 4–6 are
thin: each is an entry point to the function already tested. Phase 7 is last
and mechanical.

Doc 82 (templates) and doc 76 (attributes, `global`) are handled in phase 2; if
doc 82's later phases change the AST for templates, the builder follows. The
lexer and parser are not edited by this work except to widen spans (§4.2), and
only once the agent working in those files is done with them.

## 12. Decisions

Decided by Bart 2026-11-10: D1–D7 above, and the comment rule's reading (own
line above a symbol with no blank line attaches; trailing comments stay put).

Not asked, decided by claude, and subject to review:

- the printer details of §4.3 (`fill`, the capped lookahead);
- §6.3 binary-chain breaking before the operator, §6.4 the method-chain
  threshold (more than two calls), §6.2 hugging a last function or table
  argument;
- §6.9 the exact positions where parentheses are removed (a restriction of
  "provably redundant"; widening it is a new decision);
- §6.8 template holes always flat;
- §8.2 range formatting widened to whole statements, no on-type formatting;
- the budget of §10;
- the review-driven rules: token stream rather than AST widening (§4.2),
  `hug` and `lineSuffix` (§4.3), ownership by token boundary (§5), synthesised
  semicolons (§6.1), verbatim templates (§6.8), the rewrite-to-fixpoint
  parenthesis pass (§6.9), the string scanning rule (§6.10), the file-system
  contract (§8.1), range formatting by whole-file diff (§8.2).

## 13. Questions only building can answer

- **Q1** (§6.5): whether four entries / twelve characters is the right place
  for the table thresholds, read off the diff of the corpus run.
- **Q2** (§4.3, §10): whether the capped-lookahead printer stays linear on deep
  nesting; the benchmark settles it.

## Review

Round 1, 2026-11-10: Codex (18 findings) and Antigravity (14), both static.
Applied, with the section that carries each:

- **Call sugar does not exist** (both, P1): `f "x"` / `f{}` are a parse error
  today, so a rewrite is impossible and §11's "no parser edits" stands. §3 now
  says so; Bart's call-form decision is vacuous until the language gains the
  sugar. Gate 2 therefore has nothing to say about it.
- **Unary spacing makes `--`** (Codex): §3 exception for adjacent tokens that
  would re-lex.
- **AST is not a syntax tree** (both): synthesised `self`, `await`, lost
  semicolons, attribute placement, missing keyword spans, template chunk
  boundaries, the `function` keyword span, no token list. Answer: expose the
  token stream (phase 0b), no AST widening (§4.2). *Rejected:* Antigravity's
  `prefix_attrib` AST field and line numbers in `Comment`, because the tokens
  and a line-start table give both without touching the AST or lexer.
- **Template holes** (both): verbatim (§6.8).
- **Comment ownership** (both): token-boundary ownership (§5).
- **Lossy sinks** (Codex): refuse when `incomplete` (§4.2, §7.1).
- **Byte preservation vs shape gates** (Codex): lexical regions and a Q3
  (§5, §7.2).
- **Parenthesis order, nested parens, list positions** (both): rewrite to
  fixpoint before layout; all list elements, not only a single value (§6.9).
- **Quotes** (both): precise escape-by-escape rule (§6.10).
- **Semicolons** (both): synthesised, only after statements ending in an
  expression, placed before the trailing comment (§6.1). *Rejected:*
  Antigravity's "never after a statement that ends in `end`" as stated:
  `local f = function() end` ends in `end` but is an expression statement.
- **Hardline propagation vs hugging** (Codex): `hug` (§4.3).
- **Trailing comment width/flush** (both): `lineSuffix`, break only if code
  follows, width gate measures the code prefix (§4.3, §5, §7.2).
- **Width property gaps, table-argument rule, "12 characters"** (Codex,
  Antigravity): name lists wrap, table arguments hug, twelve source bytes
  (§6.1, §6.5, §7.2).
- **Blank line before a top-level function detaches its comments**
  (Antigravity): blank line goes before the comment group (§3).
- **Gate gaps** (Codex): recursive proto comparison, ordered comment
  sequence, type annotations, non-compiling inputs (§7.2).
- **Range formatting vs refusal** (both): whole-file format, hunks cut to the
  range, refuse on any error (§8.2).
- **Lookahead bound** (both): bounded by remaining width, not newline (§4.3,
  §10).
- **CLI file-system contract, `src/wasm_entry.zig`, free function** (Codex):
  §8.1, §8.3.

## 14. References

- `docs/design/74-language-server.md` — §6.5 (trivia sink), the server this
  plugs into.
- `docs/design/76-global-declarations-and-attributes.md`,
  `docs/design/82-string-interpolation.md` — syntax the formatter must cover.
- `src/lexer.zig` (`Trivia`), `src/parser.zig` (`parseTrivia`), `src/ast.zig`.
- Wadler, "A prettier printer" (2003); StyLua and `zig fmt` as the
  fixed-standard precedents.
