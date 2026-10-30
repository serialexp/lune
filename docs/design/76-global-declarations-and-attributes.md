# 76 — Global declarations, attributes and frozen tables — Design

Status: draft, not yet implemented
Owner: Bart
Last updated: 2026-10-31

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole phases to Done once everything inside them is checked.

### Done

- [x] **D1 — follow Lua 5.5** (§2): decided 2026-10-30 — global declarations
  as Lua 5.5 §3.3.7 has them, as written. `_G.x` stays for code coming from
  Lua, and the resolver already reads it as the global `x` (doc 74).
- [x] **D2 — `global` is reserved** (§3.1): decided 2026-10-30 — a reserved
  word outright, as 5.5 has it by default; no contextual escape like 5.5's
  `LUA_COMPAT_GLOBAL`. A program using `global` as a name adjusts.
- [x] **D3 — const is not frozen** (§4, §5): decided 2026-10-31 — `<const>`
  forbids assigning the variable again and nothing else, as in Lua and JS.
  Freezing a table is a separate run-time call, `table.freeze`, as Luau's and
  JS `Object.freeze`: shallow, permanent, for every holder. A deep freeze is
  the program calling it recursively.
- [x] **D4 — one change** (§Phasing): decided 2026-10-31 — attributes
  (`<const>`, `<close>`) land with `global`, not separately.

### Outstanding

- [ ] **Phase 0 — syntax.** `global` reserved; attributes on `local` and
  `global` names (prefix and postfix); `global *`, `global <attrib> *`,
  `global function`; the AST to carry them (§3).
- [ ] **Phase 1 — the resolver owns the declarations.** Global declarations
  as scoped bindings; the strict scope; `<const>` checks; undeclared names
  and assignments to a const as compile errors; the compiler reads it all
  from the resolver (§3.2, §4).
- [ ] **Phase 2 — `global x = v` and `global function f`** raise a run-time
  error when the global is already non-nil (§3.3).
- [ ] **Phase 3 — `<close>`.** Scope exit, `break`, `return`, error unwind
  through `pcall`, `coroutine.close` (§6). The recorder aborts at a
  to-be-closed variable at first.
- [ ] **Phase 3b — `<close>` in traces.** Record the close as a call, so a
  hot loop with a to-be-closed variable inside stays native (§6.4).
- [ ] **Phase 4 — `table.freeze` / `table.isfrozen`.** The table's
  `readonly` bit; every store path checks it, the JIT's included; keyframes
  carry it; inventory rows (§5).
- [ ] **Phase 5 — language server.** The keyword, attributes and
  declarations in completion, semantic tokens, hover, definition and rename;
  the strict-scope errors as diagnostics (§7).
- [ ] **Phase 6 — measured.** A table-store benchmark before and after the
  `readonly` check, and the suite (`just bench`) (§5.4).
- [ ] **Q1 — the generic `for`'s closing value** (§6.3): Lua 5.4 and 5.5
  take a fourth value from a generic `for`'s explist and close it when the
  loop ends; mahina takes three. Follow?
- [ ] **Q2 — read-only `for` variables** (§8): Lua 5.5 also makes loop
  variables read-only. Not part of D1's section; follow?
- [ ] **Q3 — `table.clone`** (§5.3): Luau pairs `table.freeze` with
  `table.clone` (shallow, never frozen). Add it here, later, or not at all?
- [ ] **Q4 — compile-time constants** (§4.2): Lua 5.4 folds a `<const>`
  local with a constant initializer into its uses and gives it no register.
  Do the same?

## 1. Why this exists

A mahina program has no way to say "this is meant to be a global": any name
not declared `local` is one, and a typo is a global read that the compiler can
only warn about. Lua 5.5 adds global declarations for exactly this: inside the
scope of one, every free name must be declared, so a typo is a compile error,
and a whole chunk can opt in by starting with one. Bart's direction (TODO.md,
2026-10-30) is to follow 5.5 rather than invent a variant, because a standard
nobody follows is pointless.

5.5's declarations carry Lua 5.4's attributes (`<const>`, `<close>`), which
mahina has none of yet, so they come in the same change (D4). Attributes
raised what const should mean for a table; the answer (D3) is that const is
about the variable, and making a table unwritable is `table.freeze`, which
this doc also covers.

This doc is the contract for the syntax, the scoping and error rules, the
run-time behaviour of `<close>` and frozen tables, and their cost.

## 2. Goals

- Lua 5.5 §3.3.7 global declarations, as written: a program written for 5.5
  that uses them compiles and behaves the same in mahina.
- Lua 5.4/5.5 attributes on locals and globals: `<const>` and `<close>`.
- `table.freeze` / `table.isfrozen` with Luau's semantics.
- One scoping model: the resolver (doc 74 §6.3) owns declarations, const-ness
  and the strict scope; the compiler and the language server both read it.
- No cost to programs that use none of it, beyond one bit test per table
  store (measured, §5.4).

## Non-goals

- `_ENV`. mahina has none (the globals table is the one `_G` holds); 5.5's
  text explains globals through `_ENV`, and nothing here depends on it.
- Deep freezing, or freezing anything but tables (D3).
- A const that freezes (D3). `local t <const> = {}; t.x = 1` is allowed.
- The rest of 5.5 (named vararg tables, `table.create`, …), except where a
  question below asks.

## 3. Global declarations

### 3.1 Syntax

As 5.5 §3.3.7 and §9:

```
stat ::= global attnamelist ['=' explist]
       | global [attrib] '*'
       | global function Name funcbody
       | local attnamelist ['=' explist]
attnamelist ::= [attrib] Name [attrib] {',' Name [attrib]}
attrib ::= '<' Name '>'
```

`global` joins the reserved words (D2). The attribute names are `const` and
`close`; any other is a compile error. A prefixed attribute applies to every
name in the list, a postfixed one to its own name. `<close>` is for locals
only. A list holds at most one to-be-closed variable (5.4's rule; to confirm
5.5 keeps it).

### 3.2 Scoping

- Every chunk starts with an implicit `global *`: with no declaration in
  scope, any free name is a global, as today.
- A declaration's scope starts at the next statement and runs to the end of
  the innermost block, like a `local`'s; it shadows any declaration of the
  same name in scope.
- Inside the scope of any explicit `global` declaration, the implicit
  default no longer applies: a free name that no `local` and no `global`
  declares is a **compile error**. `global *` declares every name not
  declared so far; `global <const> *` declares them read-only.
- Host-installed globals are not special: inside a strict scope, `print`
  must be declared too (`global print`, or `global <const> *` at the top).
  That is 5.5's rule.
- Declarations are compile-time only. `_G.x = 1` still writes `x`, const or
  not; another chunk or function can change any global.

In the resolver (doc 74 §6.3) a declared global becomes a binding with a
scope, like a local; its uses resolve to it by the usual innermost-wins
rule, and the binding still names the global `x` (one entry per name in the
symbol index, `navigation.globalNamed`). The undefined-global *warning*
(`compiler.zig` `warnUnknownGlobals`) stays for code outside any declaration;
inside one, the same situation is the error above.

### 3.3 Initialization

- `global x` with no value leaves `x` as it is (a local starts as `nil`).
- `global x = v` raises a run-time error if `x` is already non-nil, then
  assigns. With several names, each is checked before any is assigned
  (5.5 does the check per name; to confirm against its source before
  implementing).
- `global function f () … end` is `global f; global f = function () … end`:
  the same error if `f` is set.

Bytecode: a `def_global` that loads the slot (the doc 62 slot hint applies),
raises `global 'x' already defined` when non-nil, and stores. The recorder
treats it as `get_global`, a guard that the value is nil, and `set_global`.

## 4. `<const>`

### 4.1 Meaning

A `<const>` local or global cannot be assigned after its declaration: `x = …`,
`x += …` and `function x()` on it are compile errors, found by the resolver
(it knows which binding each assignment hits). What the variable holds is
untouched (D3). A `<const>` local needs an initializer; a `<const>` global
without one declares a read-only global name. For a global, only this chunk's
syntax is bound; `_G.x = 1` and other chunks may still write it.

### 4.2 Constants (Q4)

5.4 compiles a `<const>` local whose initializer is a constant expression
(nil, a boolean, a number, a string) as that constant: no register, folded
into every use. It changes nothing a program can see and saves a register and
a move. Proposed as part of Phase 1, pending Q4.

## 5. Frozen tables

### 5.1 Meaning (Luau's)

- `table.freeze(t)` freezes `t` in place and returns it. After that, any
  attempt to change it raises an error: a field store (`t.x = v`, `t[k] = v`,
  including through `rawset`), any `table` library function that writes it
  (`insert`, `remove`, `move` into it, `sort`), and `setmetatable(t, …)`.
- It errors if `t` is already frozen, or if its metatable is protected (has a
  `__metatable` field), as Luau's does.
- Shallow: the keys, the values and the metatable keep their own state.
- Permanent: there is no unfreeze. `table.isfrozen(t)` reports it.
- A store into a frozen table errors even when the table has `__newindex`
  and the key is absent: the table is not modified by the store itself, but
  Luau checks before dispatch, and so do we. (To confirm against Luau's
  `luaV_settable` before implementing.)
- Freezing `_G` is allowed; after it, every global assignment errors.

### 5.2 Representation

A `readonly: bool` on `Table` (Luau's own name for it). Not `frozen`:
`ArrayPart.frozen` already means the array lane is committed (doc 47), a
different thing. It rides in existing padding next to `no_grid`; the struct
does not grow.

Keyframes carry it as `HeapTable.flags` bit 2 (`table_flag_readonly`,
`keyframeser.zig`), so a restored session refuses the same writes; a
`snapshot_format_version` bump. Freezing is deterministic, so replay needs
nothing else.

### 5.3 Every store path

Each must check the bit:

- tier 0: `set_index`, `set_field`, `set_index2` (the fused grid store), and
  `set_global`/`def_global` (the globals table can be frozen);
- `rawset`, `setmetatable`, `table.insert`/`remove`/`move`/`sort`, and any
  native that writes a table it did not just create;
- the JIT: `hstore`, `astore`, `astore_append` and the hash-insert paths.
  The recorder emits one guard per table reference that the bit is clear,
  CSE'd and hoisted with the table's other loop-invariant guards, so a store
  loop pays it once per entry, not per store. `table.freeze` inside a trace
  is a call, an ordinary barrier, so a guard taken before it is not trusted
  after it.

Fresh tables (constructors, `set_list`, `table.pack`, `table.create`) cannot
be frozen yet and need no check. Grid inflation and deflation (doc 14)
change a table's representation, not its contents, and stay allowed.

`table.clone` (Q3) is not part of this unless decided.

### 5.4 Cost

The check is one byte test on a cache line every store already touches. The
budget: no table-store microbenchmark slower by more than noise in user
instructions, and `just bench` flat. Measured in Phase 6, on the pinned
profile pool.

## 6. `<close>`

### 6.1 Meaning (5.4 §3.3.8)

`local x <close> = v` marks `x` to be closed: when `x` goes out of scope,
however it does, `v`'s `__close` metamethod is called as `__close(v, err)`,
where `err` is the error object if an error caused the exit, else `nil`. `v`
must have a `__close` metamethod, or be `nil` or `false` (then nothing is
called); anything else is a run-time error at the declaration. Several
to-be-closed variables close in reverse order of declaration. An error in a
closing method is handled like an error where the variable was declared, and
the other pending closes still run.

### 6.2 Implementation

- A `tbc` instruction after the declaration checks `v` and marks its
  register in the frame's to-be-closed list.
- `close_upvalues` becomes `close`: it closes upvalues as now and calls
  `__close` on every marked register at or above its operand, newest first.
  Block ends, `break` and `return` already emit it where upvalues need it;
  they will also emit it where a to-be-closed variable is in scope. A
  `return` closes after its values are evaluated, before the frame is left.
- Error unwind: the dispatch loop's unwind to a `pcall`/`xpcall` frame
  (doc 68) runs the pending closes of every frame it discards, with the
  error, before handing the error over.
- `coroutine.close(co)` runs a suspended coroutine's pending closes (doc 73).
- Determinism: closes run in a fixed order at fixed points; nothing new for
  replay.

### 6.3 The generic `for` (Q1)

5.4 and 5.5 take four values from a generic `for`'s explist; the fourth is
closed when the loop ends, by any route. mahina takes three
(`compiler.zig` `compileGenericFor`). Following would make `for l in
io.lines(f)`-style iterators able to close their file; it costs a fourth
reserved slot per loop.

### 6.4 In traces

At first the recorder aborts at `tbc`, so a loop body declaring a
to-be-closed variable runs on tier 0. That is a coverage gap, not a design:
Phase 3b records the close as the call it is (a `__close` lookup guard and a
call), at the scope exit it happens at.

## 7. The language server

- Completion offers `global`; semantic tokens mark it as a keyword and the
  attributes as modifiers (`readonly` for `<const>`).
- Definition of a declared global goes to its `global x` line; hover shows
  the attributes.
- Rename of a declared global renames its declaration too; across files the
  global is still one name (doc 74, "Globals across files").
- The compiler's new errors (undeclared name in a strict scope, assignment to
  a const) are diagnostics like any other, with the resolver's spans.

## 8. Open questions for review

- **Q1** — the generic `for`'s closing value (§6.3).
- **Q2** — read-only `for` variables: 5.5 makes a loop's control variables
  read-only (an assignment to one is a compile error). It is a separate item
  of 5.5's change list, not part of §3.3.7, so D1 does not settle it.
- **Q3** — `table.clone` (§5.3).
- **Q4** — compile-time constants for `<const>` locals (§4.2).

## References

- Lua 5.5 reference manual §3.3.7 (global declarations), §3.3.8 (to-be-closed
  variables), §8.1 (`global` reserved, `LUA_COMPAT_GLOBAL`):
  https://www.lua.org/manual/5.5/manual.html
- Luau library, `table.freeze` / `table.isfrozen` / `table.clone`:
  https://luau.org/library
- Doc 74 §6.3 (the resolver owns scoping), "Globals across files".
- Doc 62 (global slot hints), doc 68 (`pcall` frames), doc 73 (coroutines),
  doc 14 (grids), doc 47 (`ArrayPart.frozen`), doc 04 (snapshot schema).
- TODO.md, "Language: declaring a global" (superseded by this doc).
