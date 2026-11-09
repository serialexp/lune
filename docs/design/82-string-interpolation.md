# 82 — String interpolation — Design

Status: complete — phases 0–5 landed
Owner: Bart
Last updated: 2026-11-09 (implementation)

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole phases to Done once everything inside them is checked.

### Done

- [x] **Phase 5 — command words.** Decided by Bart 2026-11-10: a backtick
  word in a shortcut (`cd`, `export`) is one argument and is evaluated by the
  session as a template, so its holes see the session's locals and globals,
  and its result is never split again. `nextWord` and `writeWordExpr` scan
  it with `skipTemplate`/`skipHole` (escapes, nested braces, quotes, long
  strings and nested templates hide their braces); it joins neighbouring text
  in the word (`~/`{x}`/y`). An unterminated one is reported at once as
  "unterminated template", as an unterminated quote is: shortcut lines do not
  wait for more input. REQ-116.1–3.

- [x] **Phase 3 — tracing.** `tostr` and `interp` record. A number hole is
  `guardNum` plus `tostr_int`/`tostr_num`; nil and bool fold to their interned
  rendering; a string is pinned. The join is two new ops: `sjpart` (keeps part
  k, stores it in `Heap.join_parts`) and `sjoin` (one `Heap.internJoin` over
  the n parts), the same function tier-0's `interp` ends in, so every tier
  interns the same strings at the same ids. A table hole with a Lua-closure
  `__tostring` records `guard_tostring` (the metatable's raw `__tostring` is
  still a closure of that proto id; one callout, shared by tier-1a and native)
  and inlines the handler like a call; its `ret` applies `tostringAnswer`
  (string pinned, number converted, anything else aborts). A deopt re-runs the
  iteration in tier-0 (the coarse model), so nothing runs twice. Proved by
  REQ-115.1–3: recorded, committed, entered natively, snapshot and next object
  id byte-identical in every trace mode, handler swapped between runs.
  Templates with more than `gc.join_max` (32) parts stay in tier-0.
- [x] **Q5 — the allocation protocol.** Decided by Phase 3: one intern per
  number hole (what `tostring(n)` makes) plus one for the join, no
  intermediate strings, identical in every tier. Limits kept as context: only
  self-contained handlers trace (any table access on a metatable-bearing
  table aborts, so a handler reading a field of its argument stays in
  tier-0), and precise-mode loops never inline handlers.

- [x] **Q1 — syntax follows Luau** (§3): decided 2026-11-09. Backticks with
  `{expr}` holes, the form of Luau's implemented RFC (the only interpolation in
  the Lua family; LuaJIT 3.0 lists it under "Extensions Not Considered" and Lua
  5.5 has none). Bart: "lets just align with luau".
- [x] **Q2 — no paren-less call** (§3.4): decided 2026-11-09. `` f`...` `` is a
  syntax error; write `f(`...`)`. The form stays free for a later
  tagged-template meaning (JS calls `tag(strings, ...values)`).
- [x] **Q3 — newlines** (§3.3): decided 2026-11-09. A raw newline in the text
  is part of the string; a backslash-newline gives the same newline, so
  Luau-flavoured code means the same here.
- [x] **Q4 — no format specifier** (§3.5): decided 2026-11-09, as Luau. A
  hole is any expression, converted like `tostring`.
- [x] **Q6 — evaluation schedule** (§4): decided 2026-11-09, following the
  review and Luau's compiler: every hole is evaluated left to right to one
  value first; the conversions then run in order.
- [x] **Q7 — conversion is intrinsic** (§3.5, §5): decided 2026-11-09. The
  compiler emits the VM's own conversion, never a reference to the name
  `tostring`, so a user's `local tostring` or a rebound global changes nothing.
- [x] **Q8 — a hole is one value** (§3.1): decided 2026-11-09. The first
  result of the expression, or nil if it returns none; a trailing call or `...`
  is never expanded.
- [x] **Phase 0 — lexer.** `interp_simple`/`interp_begin`/`interp_mid`/
  `interp_end` tokens carrying their delimiters; a per-template brace depth
  and a template stack of `max_template_depth` (200); the `{{`, unterminated
  and too-deep diagnostics (`E0006`–`E0008`). Tests are `template: …` in
  `lexer.zig`.
- [x] **Phase 1 — parser and compiler.** `ast.Expr.string_interp` (chunks +
  holes), `parseTemplate` (an empty hole is `expected_expression`, a hole not
  closed by its `}` is `expected_template_hole_end`, `E0141`); the resolver and
  the editor's syntax walker visit the holes. Lowering (`compileInterp`): text
  chunks (escapes `\`` `\{` `\}` plus the string escapes; raw line breaks
  normalised to LF in `decodeEscapes`) and hole values go to consecutive
  registers, one `tostr` per hole in source order after all holes are
  evaluated, then one `interp a, b, c`; a template with no hole is a constant,
  a lone hole is `tostr` plus a `move`. `tostr` converts in place and runs a
  Lua `__tostring` as a continuation frame (`finishOp`), so it may yield;
  `interp` joins the strings like `concat` (stack buffer or one built
  allocation, operand character facts reused). Tests:
  `src/interp_template_test.zig`, across every GC and trace-mode leg.
- [x] **Phase 2 — REPL.** `failedWith` treats `unterminated_template` as
  incomplete input, so an unfinished text, hole, nested template or trailing
  backslash waits for more lines in both the expression probe and statement
  input, while an empty hole is reported at once (`repl.zig` test).
- [x] **Phase 4 — tools.** `contextAt` calls template text a string and a hole
  code, including an unterminated hole while typing; semantic tokens mark text
  as string (the braces and the hole's own tokens are not); a name in a hole
  resolves for go-to-definition, references and rename through the resolver.
  The Tree-sitter grammar parses templates (`template_text`, `template_escape`,
  `template_hole`), with a corpus case and a drift test that reads
  `tests/lang/interpolation.lua`; the grammar also gained doc 76's attributes
  and `global` declarations, which the drift check had been failing on.

### Outstanding

_(nothing outstanding)_
## Why this exists

Building a string from values is `..` chains or `string.format`. Both are
noisy for the common case, and the REPL's command lines (doc 75 §6.1) need a
way to put a variable into a word that is not shell-specific syntax. Doc 75
deliberately has no `$NAME`; it waits for this feature.

## Goals

- Luau-compatible surface: code written with Luau interpolation lexes and
  means the same here, so Luau-flavoured snippets move without edits.
- Unambiguous: a template is never readable as another construct.
- No cost for programs that do not use it; no new cost on the hot path of
  those that do beyond what the equivalent `..` chain pays.
- Deterministic: a template is a pure function of its holes' values, and the
  conversion is exactly `tostring`'s (including `__tostring`).

## Non-goals (v1)

- Format specifiers in holes (`{x:%5.2f}`); use `string.format`.
- Tagged templates (`` tag`...` ``); the call form is reserved (Q2).
- Raw (no-escape) templates.
- Shell-only variable syntax (`$NAME`); command lines use this feature.

## 3. Syntax

### 3.1 Template

```
stringinterp ::= <INTERP_SIMPLE>
              | <INTERP_BEGIN> exp {<INTERP_MID> exp} <INTERP_END>
```

A template is an expression, `string_interp` in `ast.zig`: the chunk spans and
the hole expressions. It has exactly one more text chunk than holes;
chunks may be empty, and holes may be adjacent or at either end. `INTERP_SIMPLE`
is the no-hole form (`` `plain` ``), which is the string itself. The
expression in a hole is any Lua expression, including calls, table
constructors and nested templates, but it is a single-value context (Q8):
`` `{f()}` `` converts `f`'s first result, or nil if it returns none, and
`...` contributes its first value.

### 3.2 Escapes

Inside a template a backslash escapes `` ` ``, `{` and itself; the ordinary
string escapes (`\n`, `\t`, `\x..`, `\z`, ...) work as in strings, and
`\u{...}` is the Unicode escape, not a hole (`\\u{41}` is a backslash, then a
hole). A literal brace is `\{`; `\}` is accepted too (decoding to `}`), and a bare `}`
in the text needs no escape. Chunks are decoded by a template-chunk decoder
of their own: the existing `decodeString` asserts surrounding quotes, rejects
`` \` `` and `\{`, and does not fold raw `\r`/`\r\n` into `\n`. The new decoder
takes delimiter-free spans, including empty ones. A backslash at the very end
of the input is an unclosed escape: incomplete input in the REPL, an error
elsewhere.

`{{` is a syntax error only where text scanning meets a hole opener
immediately followed by a table constructor opener. Table constructors inside
a hole are ordinary: `` `{ {1, 2} }` `` and `` `{({1, 2})}` `` are fine.

### 3.3 Newlines

A raw newline in the text is a newline in the string. This is a deliberate
extension of Luau, whose RFC ends a chunk at an unescaped newline (Bart,
2026-11-09). A backslash-newline is the same newline, so Luau code means the
same here. Each of `\n`, `\r`, `\r\n` and `\n\r`, raw or escaped, is one `\n`
in the string, as for a Lua string's escaped newline. Hole expressions span
lines freely. A template left unterminated at the end of the input is a syntax
error; the REPL treats it as incomplete input, not as an error (Phase 2).

### 3.4 No call form

`` f`...` `` is a syntax error. A callee followed directly by a template is
never call sugar, unlike `f"..."` and `f{...}`.

### 3.5 Conversion

Each hole is converted by the VM's own `tostring` conversion (Q7): the same
rules for nil, booleans, numbers, strings, tables, userdata and functions,
the same `__tostring` and string-metatable handling, and the same errors for
an invalid `__tostring` result. The pinned behaviours are those of `tostring`
at the time of the build; a test pins each so a lowering cannot disagree. No
format specifier is accepted.

### 3.6 Lexing

The lexer has a text mode and an expression mode. On `{` in text it enters
expression mode with brace depth 0; braces count only as code tokens there
(strings, long strings and comments inside the hole are scanned by their own
scanners, so `` `{f("}")}` `` and `` `{[=[}]=]}` `` are fine). A `}` at depth 0
returns to text mode: that `}` is consumed by the lexer (it emits no `rbrace`),
and text scanning continues to the next `{` (token `INTERP_MID`) or closing
backtick (`INTERP_END`). An empty hole, including one holding only blanks or
comments, is a parse error when an expression is expected and `INTERP_MID` or
`INTERP_END` arrives. A backtick in expression mode starts a nested template,
so the lexer keeps a stack. The parser tokenizes the whole source first, so
the lexer alone decides modes. Nesting depth is bounded by the parser's
`max_depth` (200), with a clear error past the limit; EOF in either mode is the unterminated error with the opening
backtick's position.

## 4. Semantics

The schedule is fixed (Q6): every hole expression is evaluated left to right
to one value, and only then are the values converted in order, each once, and
the pieces joined. So for `` `{obj}{change()}` `` the `__tostring` of `obj`
sees the state `change()` made, as in Luau. An error in a hole expression
carries that expression's position; an error in a conversion carries the
position of the hole whose value was being converted.

The result is deterministic in the sense of the rest of the system: given the
same hole values and the same logged host inputs, it is the same string. A
`__tostring` may itself read recorded inputs, yield or raise; none of that is
new.

## 5. Lowering and the hot path

Constraints, not yet a choice (Q5):

- **Linear cost.** Construction work is proportional to the fragment count
  plus the output bytes, with checked size accumulation. A chain of binary
  `Vm.concat` calls materialises and interns every intermediate, which is
  quadratic in bytes for many equal fragments, so it is excluded. The
  lowering is one n-ary construction op after one intrinsic conversion per
  hole.
- **Not `string.format`.** Luau lowers to `string.format` with a new `%*`.
  mahina's `string.format` is a synchronous native call that rejects strings
  containing NUL ("string contains zeros") and is reached through the name
  `string`, so it breaks the next constraint, 8-bit cleanliness and Q7.
- **Intrinsic conversion** (Q7), sharing the existing resumable `tostring`
  implementation. A Lua `__tostring` runs as an activation frame (doc 68), so
  a template survives a yield, a replay stop and a keyframe capture inside it,
  with the pending values and the partial construction rooted. A synchronous
  callback shortcut (as `string.format`'s `%s` has today) is not acceptable.
- **One allocation protocol across tiers** (doc 24). Object ids enter
  snapshots and affect observable order, so tier-0, tier-1a and native must
  allocate the same objects in the same order; equal output is not enough.
- **The recorder** has no `concat` support today, and its string conversion
  aborts on any operand that is not a number (a string hole included), so
  without Phase 3 work every template would run in tier-0. Phase 3 adds: a
  string guard that passes strings through, an IR op for the n-ary
  construction, and the destination allocation in the GC headroom check. Tests must show committed and executed traces, not only equal
  output.

## Decisions

See the Done list. Alternatives rejected by Luau and not revisited here:
Python's `f"..."` (ambiguous with call syntax), Swift's `\(x)` and Ruby's
`#{x}` (change the meaning of existing strings). C#'s `$"..."` is the only
other backward-compatible form; backticks were chosen to match Luau.

## Questions only building can answer

- Q5 above: which lowering costs least on the hot path.

## Review

Codex reviewed this draft on 2026-11-09 (16 findings); all were applied or
answered above: JIT support (Phase 3, §5), evaluation order (Q6, §4),
hygiene (Q7), lexer modes (§3.6), REPL incomplete input (Phase 2), the raw
newline extension (§3.3), escape decoding (§3.2), zero-hole grammar (§3.1),
`{{` scope (§3.2), hole arity (Q8), linear cost and allocation protocol (§5),
resumable conversion (§5), conversion contract (§3.5, §4), tooling (Phase 4),
command words (Phase 5).

Antigravity reviewed it the same day (10 findings, after a first attempt timed
out at 15 minutes); applied: `string.format` removed as a lowering (§5, Q5),
the REPL's `failedWith` and the probe suffix (Phase 2), `contextAt` inside an
unterminated hole (Phase 4), the AST node and a template-chunk decoder (§3.1,
§3.2), the cross-tier intermediate-string rule (Q5), the recorder's wider gap
(§5), `}` handling and empty holes in the lexer (§3.6), `\}` and a trailing
backslash (§3.2), `nextWord` and backticks (Phase 5), the nesting bound and
deferred constant folding (§3.6, Q5). One claim is unverified: Antigravity says
Luau's RFC also accepts `\}`; the RFC text I read lists only `` ` ``, `{` and `\`.
Accepting `\}` is a superset, so Luau code still lexes.

## References

- Luau RFC "String interpolation" (https://rfcs.luau.org/syntax-string-interpolation.html).
- LuaJIT issue #1475 (lists it under "Extensions Not Considered").
- `docs/design/75-process-spawn-and-shell.md` §6.1 — the first consumer.
- `docs/design/13-luajit-syntax-parity.md` — the parity doc that noted it.
