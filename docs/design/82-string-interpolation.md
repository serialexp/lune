# 82 — String interpolation — Design

Status: draft, not yet implemented
Owner: Bart
Last updated: 2026-11-09

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole phases to Done once everything inside them is checked.

### Done

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

### Outstanding

- [ ] **Phase 0 — lexer.** Text and expression modes with a per-template
  brace depth and a template stack (§3.6); the escape set on delimiter-free
  chunks; the `{{`, empty-hole and unterminated errors; a backtick outside a
  template stays an error.
- [ ] **Phase 1 — parser and compiler.** `stringinterp` as an expression with
  an exact shape (§3.1); hole expressions are ordinary expressions for the
  resolver (locals, upvalues, strict globals, doc 81); one intrinsic
  conversion per hole and one construction op (§5).
- [ ] **Phase 2 — REPL.** A structured "incomplete input" status distinct from
  a malformed template, covering unfinished text, holes, nested templates and
  escapes, in both the expression probe and statement input (§3.3).
- [ ] **Phase 3 — tracing.** The recorder gains what templates need: today it
  has no `concat` recording (it falls back as `.nyi_opcode`) and its string
  conversion rejects heap operands. Templates must record, commit and execute
  in tier-1a and native, not only match output (§5).
- [ ] **Phase 4 — tools.** The language server (completion contexts: text vs
  code; semantic tokens; hole symbols) and the Tree-sitter grammar (doc 74),
  with a drift test each.
- [ ] **Phase 5 — command words.** Whether a template is one argv element in a
  REPL command line, and how it requests more input; owned by doc 75 §6.1.
- [ ] **Q5 — the construction op.** One n-ary construction (linear in
  fragments plus bytes) versus Luau's `string.format` with `%*`. A binary
  `..` chain is excluded by §5's cost rule. Settled by the Phase 3
  measurement; the allocation protocol must not differ across tiers.

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

A template is an expression. It has exactly one more text chunk than holes;
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
hole). A literal brace is `\{`; a `}` in the text needs no escape. Chunks are
decoded without surrounding delimiters (the existing string decoder assumes
them), including empty chunks and a trailing backslash (an error).

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
returns to text mode. A backtick in expression mode starts a nested template,
so the lexer keeps a stack. The parser tokenizes the whole source first, so
the lexer alone decides modes. Nesting depth is bounded, with a clear error
past the limit; EOF in either mode is the unterminated error with the opening
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
  quadratic in bytes for many equal fragments, so it is excluded. Candidates:
  one n-ary construction op, or Luau's `string.format` with a new `%*` (which
  needs `%` in the text doubled and widens `string.format`).
- **Intrinsic conversion** (Q7), sharing the existing resumable `tostring`
  implementation. A Lua `__tostring` runs as an activation frame (doc 68), so
  a template survives a yield, a replay stop and a keyframe capture inside it,
  with the pending values and the partial construction rooted. A synchronous
  callback shortcut (as `string.format`'s `%s` has today) is not acceptable.
- **One allocation protocol across tiers** (doc 24). Object ids enter
  snapshots and affect observable order, so tier-0, tier-1a and native must
  allocate the same objects in the same order; equal output is not enough.
- **The recorder** has no `concat` support today and rejects heap operands in
  its string conversion, so without Phase 3 work every template would run in
  tier-0. Tests must show committed and executed traces, not only equal
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
command words (Phase 5). Antigravity's review timed out after 15 minutes and
returned nothing, so this doc has one review, not two.

## References

- Luau RFC "String interpolation" (https://rfcs.luau.org/syntax-string-interpolation.html).
- LuaJIT issue #1475 (lists it under "Extensions Not Considered").
- `docs/design/75-process-spawn-and-shell.md` §6.1 — the first consumer.
- `docs/design/13-luajit-syntax-parity.md` — the parity doc that noted it.
