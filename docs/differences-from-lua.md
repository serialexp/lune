# mahina for Lua programmers: the differences

mahina is shaped like Lua 5.4 but is not a drop-in replacement. Where
compatibility would cost determinism or a sound design, mahina differs on
purpose; elsewhere a Lua feature is simply not built yet. This page lists
both as a program sees them, marked **not yet supported** where the
difference is a gap rather than a decision. The reasoning behind a
deliberate difference is in the design doc it names.

The differences most likely to stop an existing Lua program:

- Strings never turn into numbers in arithmetic: `"10" + 1` is an error
  (§Numbers).
- No `goto` or `f"str"`/`f{...}` call syntax (§Syntax).
- Calls nest at most 200 deep, and tail calls are not eliminated
  (§Calls).

## Syntax

**Added.** Compound assignment (`+=`, `-=`, `*=`, `/=`, `//=`, `%=`,
`..=`, `&=`, `|=`, `<<=`, `>>=`, `~=`), `??` (the right side when the left
is `nil`), `!=`, `!`, `&&`, `||`, and optional type annotations
(`local x: number = 3`) (`docs/design/13-luajit-syntax-parity.md`). One
catch: as a statement, `x ~= 1` is xor-assignment, not a comparison.

**Async functions** (`docs/design/73-coroutines.md` §7). `async` and
`await` are reserved words, so a Lua program using either as a name
doesn't compile. `async function f() … end` (also `local async
function` and `async function (…) … end`) makes a function whose call
starts a task running the body at once and returns the task; `await e`
(a prefix operator binding like `not`, and a call, so a statement too)
gives the task's results once it has finished, raising its error if it
failed, or `e` itself when it isn't a task. An error before the task's
first wait is raised at the call. `await` works anywhere: in the task's
own code it suspends the task, elsewhere it runs the other ready tasks
until the awaited one finishes. Tasks still ready when the main chunk
returns run after it, and a failed task nothing awaited is then a
fatal error. A task's own `coroutine.yield` is an error; coroutines
inside a task work as usual. An embedder's host functions can return
operations to await (doc 59 §3.10); with no wait callback, `await`
outside a task's own code then fails with "await would block".

**`aio`** (doc 73 §7.6), a module Lua doesn't have:
`aio.sleep(s)`, `aio.read(path [, "b"])`, `aio.write(path, data)` and
`aio.append(path, data)` start an operation that runs while the program
goes on and return it at once, for `await`. A read gives the whole file
(a string that must be valid UTF-8, or with `"b"` a byte array); a write
gives `true`. A failure raises at the await, or under `--lua-io-errors`
the await gives `nil, msg, code`. Tasks wake in the order operations
finish, which a recording logs, so a replay wakes them the same way.
The browser playground has only `aio.sleep`, on a virtual clock: a sleep
finishes at once, after every sleep due before it.

**Numerals** read as in Lua, hex floats (`0x1.8p+1`) and wrapping hex
integers included, with one exception: `..` ends a numeral, so `1..2` is
`1 .. 2` where Lua reports a malformed number.

**Not yet supported:**

- `goto` and labels.
- Yielding from a builtin installed directly as a metamethod
  (`__index = coroutine.yield`), or from a `__call` reached through
  another `__call` table, raises "attempt to yield across a C-call
  boundary". A Lua function metamethod can yield, `__close` and `__call`
  included.
- Calls without parentheses: `f"str"`, `f[[str]]`, `f{...}`, so
  `require"mod"` must be `require("mod")`.
- A `#!` first line.
- `...` in the main chunk. Script arguments are only in `arg`.

A compile error reads `file:line: error: message`, without Lua's
`near 'token'`, and one compile may report several.

A read of a global that is never assigned anywhere prints a warning on
stderr when the file compiles (`warning: undefined global 'x'`). It also
fires for globals created through `_G.name = …`.

## Numbers

Integers and floats are separate subtypes as in Lua 5.4, integer
arithmetic wraps, and `/` and `^` always give floats.

**Strings are not numbers.** Lua converts a numeric string wherever a
number is wanted; mahina never does. `"10" + 1`, `-"2"`, `for i = "1", 2`,
`math.floor("3.7")` and `string.format("%d", "10")` are all errors. Use
`tonumber`. The other direction still works for `..`: `1 .. ""` is `"1"`,
but string functions don't accept numbers (`string.len(123)` is an
error).

**Bitwise operators take integers only**, not floats with an integral
value: `3.0 | 0` raises "number has no integer representation", where Lua
gives `3`. Use `math.tointeger`.

**Floats print as the shortest text that reads back to the same value**,
positionally between `1e-7` and `1e21`, and an integral float prints
without `.0`:

| Value | Lua 5.4 | mahina |
|---|---|---|
| `3.0`, `4 / 2` | `3.0`, `2.0` | `3`, `2` |
| `0.1 + 0.2` | `0.3` | `0.30000000000000004` |
| `math.pi` | `3.1415926535898` | `3.141592653589793` |
| `1e15` | `1e+15` | `1000000000000000` |
| `2^63` | `9.2233720368548e+18` | `9223372036854776000` |
| `-0.0` | `-0.0` | `-0` |

`print`, `tostring`, `..`, `%s` and `table.concat` all use this text, so
text alone no longer tells an integer from a float; `math.type` does.
`string.format("%g", x)` and friends format as in C.

`n // 0` and `n % 0` on integers raise "attempt to perform integer
division or modulo by zero".

## Tables

- `pairs` and `next` visit the array part in order, then the other keys
  in the order they were first inserted. Lua's order depends on hashing;
  mahina's is the same on every run and every platform
  (`docs/design/02-determinism.md`).
- `next(t, k)` with a `k` that is not in `t` returns the key after it
  rather than raising "invalid key to 'next'": a traversal may delete
  the current key, and mahina does not keep deleted keys around to tell
  the two apart.
- `#t` on a table with holes may pick a different border than Lua does
  (both are valid): `#{1, 2, nil, 4}` is 2, where Lua gives 4. Everything
  that uses `#t` follows it: `table.sort({3, nil, 1})` sorts only the
  one-element prefix (Lua reaches the nil and raises "attempt to compare
  nil with number"), and `table.unpack`, `table.concat` and `table.insert`
  work on the same shorter prefix.
- `tostring({})` is `table: 0x11b`: a small object number, not an
  address, so it is the same on every run. Built-in functions print as
  `native: 0x…` (`type` still says `"function"`).
- **Not yet supported:** `__pairs`; `ipairs` and the `table` library
  ignore `__index`, `__newindex` and `__len`.
- `table.sort` is a heapsort: equal elements may end up in a different
  order than Lua's, and a comparator that is not a valid order does not
  raise "invalid order function".
- A `table.sort` comparator, and a `__lt` the sort calls, can yield; Lua
  raises "attempt to yield across a C-call boundary". The comparator may
  also be a callable table, which Lua refuses. A sort the program calls
  through a builtin (`pcall(table.sort, t, f)`) still cannot yield.
- A chunk run by `dofile` can yield; Lua raises "attempt to yield across a
  C-call boundary". Through a builtin (`pcall(dofile, path)`) it still
  cannot.
- A `string.gsub` function replacement can yield; Lua raises "attempt to
  yield across a C-call boundary". Through a builtin
  (`pcall(string.gsub, s, p, f)`) it still cannot.

## Calls

The call stack holds 200 frames, and a tail call takes a frame like any
other call. A recursion deeper than that, tail-recursive or not, raises
"stack overflow"; Lua allows hundreds of thousands. **Not yet
supported:** proper tail calls and a deeper stack.

## Globals and environments

**Not yet supported:** `_ENV`, and `load`'s `env` and `mode` arguments
(both are ignored), a reader function as `load`'s chunk, and metatables
on `_G` (an `__index` or `__newindex` there has no effect).

`_VERSION` is `"mahina 0.0.0"`.

## Strings are text

A string is a sequence of Unicode code points stored as valid UTF-8.
`#s` counts code points, not bytes, and invalid UTF-8 never becomes a
string: wherever bytes arrive from outside, they are checked, and bad
bytes raise an error rather than being replaced or passed through.
Binary data is a **byte array**: a table of integers `0..255` at keys
`1..n`. `string.encode(s)` gives a string's UTF-8 bytes as a byte array;
`string.decode(bytes)` turns valid UTF-8 bytes back into a string
(`docs/design/06-strings-and-bytes.md`).

What follows from that:

- `#s`, `string.sub`, `string.find` positions, `string.reverse`, and the
  width and precision of `%5s`/`%.1s` all count code points:
  `#"héllo"` is 5, `("日本語"):sub(2, 2)` is `"本"`.
- `string.byte` is gone; `string.codepoint(s, i, j)` returns code points.
  `string.char` takes code points (`string.char(256)` is `"Ā"`), and
  `%c` writes one. There is no `utf8` library: `string.char`,
  `string.codepoint`, `string.codes` and `#` cover it.
- `string.upper` and `lower` use Unicode simple case mapping:
  `("é"):upper()` is `"É"`.
- In patterns, `.` matches one code point, but the classes `%a`, `%w`,
  `%s`, `%p`, `%d` are ASCII only, their complements (`%A`, `%W`, …)
  don't match characters outside ASCII either, and a set such as
  `[а-я]` or `[é]` does not match characters outside ASCII yet.
- A `\xNN` or `\ddd` escape must be below 128, and `\u{...}` must be a
  valid code point; Lua accepts any byte.

## The rest of the standard library

- **`string.format`.** `%p` writes the object's stable id (`0x11b`, the
  one `tostring` shows), not its address.
- **`string.gmatch`** ignores the `init` argument (**not yet
  supported**), and its iterator only works inside a generic `for`.
- **`string.pack`, `packsize`, `unpack`**: **not yet supported**.
- **`math.random`** uses xoshiro256 like Lua 5.4, but draws a different
  sequence for the same seed, and `math.randomseed` returns one value.
  Without the `random` system interface every run uses the same seed.
- **`math`** has no `pow`, `ldexp`, `frexp`, `log10`, `cosh`, `sinh`,
  `tanh` (none is in Lua 5.4 proper, only in compatibility builds).
- **`collectgarbage`**: **not yet supported**. There are no finalizers or
  weak tables, so `__gc` and `__mode` do nothing.
- **`tostring`** ignores `__name` (**not yet supported**).
- **`warn`** is on from the start and prints `mahina warning: …`; the Lua
  interpreter starts with warnings off.
- **`require`** searches `package.path`, which starts with
  `./?.mah;./?/init.mah;./?.lua;./?/init.lua`. There are two searchers
  (`package.preload` and the path); C modules are not supported, so
  `package.cpath` is empty and `package.loadlib` is absent.
- **`debug`** has only `traceback`.

## Missing libraries and functions

| Missing | Why | Instead |
|---|---|---|
| `debug.*` except `traceback` | reflection breaks the language's guarantees; the trace visualiser takes its place | `mahina viz` |
| `string.byte`, `utf8` | strings are code points | `string.codepoint`, `string.char`, `string.codes` |
| `string.dump` | bytecode is internal and not portable between versions | — |
| `package.loadlib`, C modules | native code can't be sandboxed or replayed | the embedding API |
| `io.popen`, `os.execute` | a spawned process can't be recorded and replayed | — |
| `os.setlocale` | formatting always uses the C locale | — |
| `loadstring`, `unpack`, `setfenv` | removed from Lua itself before 5.4 | `load`, `table.unpack` |

## Error messages

Runtime errors name the value the way Lua 5.4 does: `attempt to call a
nil value (global 'foo')`, `(field 'open')`, `(method 'read')`. mahina
keeps no names for locals and upvalues, so a value read from one gets no
name where Lua would say `(local 'f')` or `(upvalue 'f')`.

Other differences:

- `load`'s chunk name is used as given (`=name` keeps its `=`), and the
  default is `(load)`, not `[string "..."]`.
- Some wording differs: arithmetic on a string says "attempt to perform
  arithmetic on a string value"; `ipairs` takes only a table ("table
  expected"), where Lua takes any value.
- An uncaught error prints `mahina: runtime error: message at file:line`
  and an indented traceback. Tracebacks (this one and `debug.traceback`'s)
  have no `[C]` rows except a coroutine whose body is a library function
  (`[C]: in function 'pcall'`) and the task library's frames under an
  `await` or an async call (`[C]: in function 'task.wait'`), and name every Lua function `function
  'name'`, an unnamed one `'anonymous'`, where Lua says `local 'f'` or
  `function <main:2>`. An error object's
  `__tostring` gives the message, as in Lua; if that `__tostring` itself
  fails, mahina prints `(error object is a table value)` where Lua reports
  the handler's error.

## Files and the operating system: `io` and `os`

### Which functions a program has

The CLI gives a program the whole library. An embedding host chooses
which **system interfaces** a VM gets, and a program in a VM without one
does not have its functions at all, as if the library had never been
opened (`docs/design/65-cli-host-library.md` §5):

| Interface | Functions |
|---|---|
| `files` | `io.open`, `io.tmpfile`, `os.remove`, `os.rename`, `os.tmpname`; `aio.read`, `aio.write`, `aio.append` with an async host |
| `stdio` | `io.stdin` (and stdin as the default input) |
| `files` or `stdio` | `io.read`, `io.lines`, `io.input`, `io.output`, `io.close`: either one installs them |
| `env` | `os.getenv`, `os.exit` |
| `time` | `os.time`, `os.date` |
| `clock` | `os.clock`; `aio.sleep` with an async host |
| `random` | an entropy seed for `math.random` (without it, every run draws the same sequence) |

`io.write`, `print`, `io.stdout`, `io.stderr`, `io.type` and the file
methods are always there. On the CLI, `--system` limits the interfaces
(`--system none`, `--system files,time`); the browser playground has
only `clock` and `random`. Calling a missing function says why:

```
attempt to call a nil value (field 'open'; io.open needs the 'files' system interface, which this VM does not have)
```

`io.popen`, `os.execute` and `os.setlocale` do not exist anywhere (see
§Missing libraries and functions).

### Failures raise

By default a failed `io` or `os` operation raises a catchable error
instead of returning `nil, message, code`:

```lua
local f = io.open("cfg.txt")   -- error: cannot open 'cfg.txt': not found
```

The messages are mahina's own (`not found`, `permission denied`,
`exists`, `is a directory`, `not valid UTF-8`, `other`), the same on
every platform, so a recording made on Linux replays with the same text
anywhere.

For existing Lua code that checks the return value, run with
`--lua-io-errors` (or set `lua_io_errors` in the embedding config). The
same calls then return Lua's `nil, message, code`. `code` is the number
of the error class above, not the OS `errno`. Calls that raise in Lua
too, such as reading a closed file, raise in both modes.

### Text and binary files

A file opened without `b` is text:

- `read(n)` reads `n` **code points**, matching `#s`; Lua counts bytes.
  `seek` positions are bytes in both.
- Reading bytes that are not valid UTF-8 is an error (or `nil, message`
  under `--lua-io-errors`).

A file opened with `b` (`"rb"`, `"wb"`, …) is binary: reads return byte
arrays (`read(n)` counts bytes, `"a"` reads to the end, and `"l"`/`"L"`
are refused), and `write` takes byte arrays as well as strings.

```lua
local f = io.open("image.png", "rb")
local bytes = f:read("a")      -- a table: bytes[1] == 137
f:close()
```

### File handles

`tostring(f)` is `file (0x…)`, and `io.type(f)` is `"file"` or
`"closed file"` as in Lua. A handle has no `__close`, and nothing closes
a handle the program drops: mahina has no finalizers, so it stays open
until the program ends or calls `os.exit`.

### stdout and stderr

stdout is buffered as C's stdio buffers it for Lua: by line when it is a
terminal, in blocks otherwise. It is flushed before anything is written
to stderr (so `2>&1` keeps the program's order), before a read from
stdin, on `io.flush`, and at exit.

### `os.exit`

`os.exit(code)` ends the program with `code` (`true` is 0, `false` is 1),
and `pcall` cannot catch it. The CLI still writes the files it was asked
for (`--emit-effects`, `--emit-keyframe`, …) before it exits. In an
embedding, `os.exit` never ends the host process: the call returns
`MH_EXIT` (`Error::Exit(code)` in Rust) with the code, and the VM can run
again. It belongs to the `env` interface.

### Dates and times

`os.time`, `os.date` and `os.difftime` follow Lua 5.4, including its
normalization of out-of-range date fields (`{month = 14}` is February
of the next year) and its errors. The differences:

- The local zone comes from `$TZ` (a zone name such as
  `Europe/Amsterdam`, a POSIX rule such as `CET-1CEST,M3.5.0,M10.5.0/3`,
  or empty for UTC) or `/etc/localtime`. mahina reads these itself; it
  does not ask the C library. On Windows the zone is the system's, and
  `%Z` prints its full name ("W. Europe Standard Time") as the C runtime
  does there.
- A wall time that falls in a daylight-saving overlap (the hour that
  happens twice) always resolves the same way. glibc's answer depends on
  what an earlier `os.time` call found.
- An `isdst` that contradicts the date (`isdst = true` in January) is
  resolved by looking up to seven years either way for daylight-saving
  rules, as glibc does, but in half-year steps rather than weekly ones.
- A POSIX `TZ` rule applies to every year. glibc applies it only from
  1970.
- The date table's fields are read directly, without `__index`.

`os.clock` counts seconds since the VM started, as Lua's starts near 0,
but it measures elapsed time from a monotonic clock, not CPU time: time
spent waiting on input or a file counts. Each VM in an embedding has its
own zero; Lua's is the process's.

### Recording and replay

Every result the operating system gives a program (a line read, the
time, an environment variable, whether a file opened) is an input, and
recording a run logs each one so a replay reproduces the run exactly
without touching the system. Two consequences:

- A recording refuses to grow its log past a limit, 1 MiB by default,
  and stops with an error that says how to raise it
  (`--effect-log-limit <bytes>`, `0` for none). Reading a large file in
  full while recording logs the whole file.
- A replay writes nothing to the filesystem; writes return what they
  returned when recorded. stdout and stderr still show the program's
  output.
