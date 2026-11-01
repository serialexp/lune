# 76 — Global declarations, attributes and frozen tables — Design

Status: in progress (Phases 0, 2 and 3 landed)
Owner: Bart
Last updated: 2026-11-01

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole phases to Done once everything inside them is checked.

### Done

- [x] **D1 — follow Lua 5.5** (§2): decided 2026-10-30 — global declarations
  as Lua 5.5 §3.3.7 has them, as written. `_G.x` stays for code coming from
  Lua, and the resolver already reads it as the global `x` (doc 74).
- [x] **D2 — `global` is reserved** (§3.1): decided 2026-10-30 — a reserved
  word outright, with no contextual escape. Note: 5.5's default build defines
  `LUA_COMPAT_GLOBAL` (`luaconf.h`), which keeps `global` usable as a name
  where a declaration can't start, so reserving it outright is stricter than
  stock 5.5. A program using `global` as a name adjusts.
- [x] **D3 — const is not frozen** (§4, §5): decided 2026-10-31 — `<const>`
  forbids assigning the variable again and nothing else, as in Lua and JS.
  Freezing a table is a separate run-time call, `table.freeze`, as Luau's and
  JS `Object.freeze`: shallow, permanent, for every holder. A deep freeze is
  the program calling it recursively.
- [x] **D4 — one change** (§Phasing): decided 2026-10-31 — attributes
  (`<const>`, `<close>`) land with `global`, not separately.
- [x] **D5 — the generic `for` takes a closing value** (§6.3): decided
  2026-11-01 — four values, as 5.4 and 5.5; the fourth is closed like a
  `<close>` variable when the loop ends, by any route.
- [x] **D6 — `for` control variables are read-only** (§3.4): decided
  2026-11-01 — as 5.5: the numeric `for`'s variable and the generic `for`'s
  first variable are `<const>` inside the loop body.
- [x] **D7 — `table.clone`** (§5.5): decided 2026-11-01 — added with
  `table.freeze`, as Luau's.
- [x] **D8 — `<const>` locals with a constant value are folded** (§4.2):
  decided 2026-11-01 — as 5.4: no register, the constant in every use.
- [x] **Phase 0 — syntax.** `global` reserved; attributes on `local` and
  `global` names (prefix and postfix); `global *`, `global <attrib> *`,
  `global function`; the AST to carry them (§3).
- [x] **Phase 2 — `global x = v` and `global function f`** raise a run-time
  error when the global is already non-nil (§3.3).
- [x] **Phase 3 — `<close>`.** Scope exit, `break`, `return`, error unwind
  through `pcall`, `coroutine.close`, a coroutine dying; the generic
  `for`'s closing value via `tfor_prep`; `io.lines`'s file closed by it
  (§6).
- [x] **Phase 4 — `table.freeze` / `table.isfrozen` / `table.clone`.**
  The table's `readonly` bit; every store path checks it, the JIT's
  included; keyframes carry it; inventory rows (§5).

### Outstanding

- [ ] **Phase 1 — the resolver owns the declarations.** Global declarations
  as scoped bindings; the strict scope; `<const>` checks, `for` control
  variables included; undeclared names and assignments to a const as
  compile errors; the compiler reads it all from the resolver (§3.2, §3.4,
  §4).
  - [x] all of the above
  - [ ] constant `<const>` locals folded (D8, §4.2)
- [ ] **Phase 3b — `<close>` in traces** (§6.4).
  - [x] `tbc`, `tfor_prep`, `close` and `ret_close` recorded while the
    values are nil or false, so loops with a generic `for` inside stay
    native
  - [ ] a value with a `__close` recorded as the call, not an abort
- [ ] **`<close>` gaps against 5.4** (§6.2, TODO.md): pending closes on an
  uncaught top-level error; a `__close` that yields.
- [ ] **Phase 5 — language server.** The keyword, attributes and
  declarations in completion, semantic tokens, hover, definition and rename;
  the strict-scope errors as diagnostics (§7).
- [ ] **Phase 6 — measured.** A table-store benchmark before and after the
  `readonly` check, and the suite (`just bench`) (§5.4).

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
- The rest of 5.5 (named vararg tables, `table.create`, …), except the
  `for` changes (D5, D6).

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
only. A list holds at most one to-be-closed variable (5.4's rule, which 5.5
keeps).

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

In the resolver (doc 74 §6.3) a declared global becomes a scope entry, like
a local's; its uses resolve to it by the usual innermost-wins rule. The
entry points at the global's one binding, so every declaration and use of
`x` stays one name in the symbol index (`navigation.globalNamed`), not a
binding per declaration. The undefined-global *warning*
(`compiler.zig` `warnUnknownGlobals`) stays for code outside any declaration;
inside one, the same situation is the error above.

### 3.3 Initialization

- `global x` with no value leaves `x` as it is (a local starts as `nil`).
- `global x = v` raises a run-time error if `x` is already non-nil, then
  assigns. With several names, the values are all evaluated first, then the
  names are checked and assigned one at a time, last name first, as 5.5's
  `initglobal` does: in `global a, b = 1, 2` with `a` already set, `b` is
  assigned before `a`'s check raises.
- `global function f () … end` is `global f; global f = function () … end`:
  the same error if `f` is set.

Bytecode: a `def_global` that loads the slot (the doc 62 slot hint applies),
raises `global 'x' already defined` when non-nil, and stores. The recorder
treats it as `get_global`, a guard that the value is nil, and `set_global`.

### 3.4 Read-only `for` variables (D6)

As 5.5 §3.3.5: the numeric `for`'s variable is a read-only (`const`) local of
the loop body, and so is the generic `for`'s first variable, the control
variable. The generic `for`'s other variables stay ordinary locals. An
assignment to a read-only one is the same compile error as for any
`<const>` (§4.1). A body that wants to change the value copies it into a
local first.

## 4. `<const>`

### 4.1 Meaning

A `<const>` local or global cannot be assigned after its declaration: `x = …`,
`x += …` and `function x()` on it are compile errors, found by the resolver
(it knows which binding each assignment hits). What the variable holds is
untouched (D3). A `<const>` local without an initializer is allowed and is
`nil` for good, as in 5.4; a `<const>` global without one declares a
read-only global name. For a global, only this chunk's
syntax is bound; `_G.x = 1` and other chunks may still write it.

### 4.2 Constants (D8)

As 5.4: a `<const>` local whose initializer is a constant expression (nil, a
boolean, a number, a string) compiles as that constant, with no register,
folded into every use. It changes nothing a program can see and saves a
register and a move. The resolver marks the binding; the compiler emits the
constant where it would read the register. A closure capturing it gets the
constant too, not an upvalue. A `<const>` global is never folded: another
chunk may write it (§4.1).

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
- Only a store that would assign checks it. Luau's `luaV_settable` tests
  `readonly` at the raw store, after the `__newindex` lookup, so a store of
  an absent key into a frozen table with a `__newindex` dispatches to it,
  and so does ours (`Vm.indexSet`).
- The order of the other checks is Luau's too: `rawset` checks first;
  `setmetatable` checks the protected metatable, then `readonly`;
  `insert`/`remove`/`move` check their arguments, then error at the first
  write; `sort` checks up front.
- Freezing `_G` is allowed; after it, every global assignment errors.
- The message is Luau's: "attempt to modify a readonly table".

### 5.2 Representation

A `readonly` bit (Luau's own name for it), in `GcFlags` in the object
header, not a field on `Table`. Not `frozen`: `ArrayPart.frozen` already
means the array lane is committed (doc 47), a different thing.

The header, not the table's padding, because every store already tests the
header's type byte. With `readonly` in the same 32-bit word,
`GcHeader.isWritableTable()` is one masked compare (type == table and
readonly clear), so the tier-0 fast lanes pay for the check exactly what
they paid for the type test it replaces. A bit next to `no_grid` would be a
second load from another field. The struct does not grow either way.

Keyframes carry it as `HeapTable.flags` bit 2 (`table_flag_readonly`,
`keyframeser.zig`), so a restored session refuses the same writes; a
`snapshot_format_version` bump. Freezing is deterministic, so replay needs
nothing else.

### 5.3 Every store path

Each checks the bit:

- tier 0: `set_index` and `set_field` take their fast lanes only through
  `isWritableTable()`; a frozen table falls to `Vm.indexSet`, which raises
  `Error.ReadonlyTable` at the raw store. `set_global`/`def_global` check the
  globals table.
- `rawset`, `setmetatable`, `table.insert`/`remove`/`move`/`sort`,
  `require`'s writes to `package.loaded`, and the `string.gmatch`/
  `string.codes` iterators' writes to their state table. That state is a
  table the program can reach and freeze; the fused gmatch fast path
  (`stralloc.zig`) reports a frozen state as a bad layout, so tier 0 runs
  the step and raises.
- the C API: `mh_global_set`, `mh_register_fn` and `mh_table_metatable_set`
  refuse with the same message; `mh_table_set` goes through `indexSet`.
  There is no C entry that freezes.
- the JIT. The recorder aborts (`readonly_table`) when the table it records
  a store into is frozen, and every store's `guard_table` carries
  `aux = GUARD_TABLE_WRITABLE`. `tropt` keys guards on `aux`, so a read's
  plain guard on the same table does not absorb a store's. The native code
  tests the header bit (`bt`): once in the entry prologue for a
  loop-invariant table, which every entry stub reaches, and at the guard for
  a table loaded in the loop. A read guard does not test it: reading a
  frozen table stays native. The bit cannot change during a native run:
  `table.freeze` is not a recorded builtin, so a call to it ends the trace,
  and every host call and C API entry bumps the host epoch.
- `set_index2` (the fused grid store) needs nothing. Grid inflation refuses
  frozen rows, so a grid's cells are never in a frozen table. A store
  through a frozen outer table that holds a grid writes a row, not the
  outer table; reassigning a row goes through `set_index` and is refused.

Fresh tables (constructors, `set_list`, `table.pack`, `table.create`) cannot
be frozen yet and need no check. Grid inflation and deflation (doc 14)
change a table's representation, not its contents, and stay allowed.

`table.clone` (§5.5) builds a fresh table and needs no check on its result.

### 5.4 Cost

The check is one byte test on a cache line every store already touches. The
budget: no table-store microbenchmark slower by more than noise in user
instructions, and `just bench` flat. Measured in Phase 6, on the pinned
profile pool.

### 5.5 `table.clone` (D7)

Luau's: `table.clone(t)` returns a new table with the same keys, values and
metatable, never frozen, even if `t` was. Shallow. It errors if `t`'s
metatable is protected (has `__metatable`), as Luau's does
(`ltablib.cpp` `tclone`). Its argument is deflated from a grid first, as
every library function's is. Then the array and hash parts are copied as
they stand, capacity included, so the copy costs one allocation per part
and no rehash (`Table.clone`). A `table` library function, deterministic;
an inventory row.

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

- A `tbc` instruction after the declaration checks `v`. Which registers are
  to-be-closed where is static: `Proto.tbc_vars` lists each one's register
  and pc range (`bytecode.TbcVar`), so the frame keeps no list and a
  function without one pays nothing.
- A new `close a` calls `__close` on every to-be-closed variable live there
  at or above `a`, newest first. `close_upvalues` stays its own instruction:
  most scopes close upvalues and no to-be-closed variable, and keeping them
  apart keeps that path as it was. Block ends and `break` emit `close` where
  a to-be-closed variable is in scope.
- A `return` in such a scope compiles to `ret_close`, which closes every
  live one after the values are evaluated, then is `ret`. A plain `ret`
  stays check-free.
- `close` and `ret_close` first test whether every value they would close is
  nil or false, and go on without a call when so: the generic `for`'s
  closing value (§6.3) nearly always is.
- Error unwind: the unwind to a `pcall`/`xpcall` frame (doc 68) runs the
  pending closes of every frame it discards, with the error, before handing
  the error over. An error raised in a `__close` replaces the error passed
  to the closes after it, as in 5.4. The closes run after `xpcall`'s message
  handler has seen the original error, and an error in a `__close` reaches
  the `xpcall` result without passing the handler again.
- `coroutine.close(co)` runs a suspended coroutine's pending closes (doc 73).
  **Deviation from 5.4:** a coroutine that dies of an error closes its
  pending variables as it dies, with the error. 5.4 leaves them pending
  until `coroutine.close`, which a program can forget; closing at death
  keeps "closed by any route" true.
- **Gap:** a `__close` cannot yield yet. A yield inside one raises "attempt
  to yield across a C-call boundary", where 5.4 suspends the coroutine
  mid-close (TODO.md). The close runs as a nested call (`Vm.callClose`), not
  as a resumable frame.
- An error that nothing catches ends the program without running pending
  closes yet (TODO.md); lua.c runs them, because its `pcall` around the
  chunk does.
- Determinism: closes run in a fixed order at fixed points; nothing new for
  replay.

### 6.3 The generic `for` (D5)

As 5.4 and 5.5: the explist is adjusted to four values; the fourth, the
closing value, behaves like a `<close>` variable of the loop and is closed
when the loop ends, by any route (normal end, `break`, `return`, error).
`nil` or `false` means nothing to close. It lets `for l in io.lines(f)`
close the file it opened (its 4th value; a file's `__close` closes it).

Only an explist that can have a fourth value gets a closing value: four or
more expressions, or a last expression that is a call or `...`
(`compiler.zig` `compileGenericFor`). `for k, v in next, t do` keeps today's
code. With one, the closing value takes the register below the control
registers, and the loop's entry jump becomes `tfor_prep a, aux`: it moves
the fourth value down to `R[a]`, checks it as `tbc` does, and jumps to the
test block. That is Lua 5.4's `OP_TFORPREP`, and one dispatch, as the entry
`jmp` was. A `close` at the loop's exit, where `break`s land too, closes it.
Per loop run (not per iteration) that costs one more result from the
explist's call, the `tfor_prep` check and the `close`. On tier 0, an
`ipairs` loop over an empty table runs about 90 more instructions per run
(≈ +4% on a microbenchmark made of short `pairs`/`ipairs` loops). The
dispatches themselves are tier 0's general cost (doc 69).

A to-be-closed `for` state is named `(for state)` in errors, as 5.4 names it.

The numeric `for`'s and the generic `for`'s first variable are read-only
(D6), so the loop's own registers cannot be reassigned by the body.

### 6.4 In traces

The recorder records `tbc`, `tfor_prep`, `close` and `ret_close` while the
values they would close are nil or false: it pins each one so (a guard on a
slot it loads), and the instructions record nothing else. A loop with a
generic `for` inside, or a function with a `<close>` local holding `nil`,
stays native. A value that has a `__close` aborts the recording, so such a
scope runs on tier 0. Recording the close as the call it is (a `__close`
lookup guard and a call, at the scope exit it happens at) is what's left
of Phase 3b.

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

None; Q1–Q4 became D5–D8 (2026-11-01). Of the two details to confirm
against the reference sources: 5.5 checks and assigns the names of
`global a, b = …` one at a time, last first (§3.3). Whether Luau refuses a
store into a frozen table before `__newindex` dispatch (§5.1) is still to
check, in Phase 4.

## References

- Lua 5.5 reference manual §3.3.5 (`for`: read-only control variables, the
  closing value), §3.3.7 (global declarations), §3.3.8 (to-be-closed
  variables), §8.1 (`global` reserved, `LUA_COMPAT_GLOBAL`):
  https://www.lua.org/manual/5.5/manual.html
- Luau library, `table.freeze` / `table.isfrozen` / `table.clone`:
  https://luau.org/library; source `VM/src/ltablib.cpp` (`tfreeze`, `tclone`).
- Doc 74 §6.3 (the resolver owns scoping), "Globals across files".
- Doc 62 (global slot hints), doc 68 (`pcall` frames), doc 73 (coroutines),
  doc 14 (grids), doc 47 (`ArrayPart.frozen`), doc 04 (snapshot schema).
- TODO.md, "Language: declaring a global" (superseded by this doc).
