# mahina for Lua programmers: the differences

mahina follows Lua 5.4 closely, and most Lua programs run unchanged. Where
compatibility would cost determinism or a sound design, mahina differs on
purpose. This page lists those differences as a program sees them. The
reasoning behind each is in the design doc it names.

## Strings are text

A string is a sequence of Unicode code points stored as valid UTF-8.
`#s` counts code points, not bytes, and invalid UTF-8 never becomes a
string: wherever bytes arrive from outside, they are checked, and bad
bytes raise an error rather than being replaced or passed through.
Binary data is a **byte array**: a table of integers `0..255` at keys
`1..n`. `string.encode(s)` gives a string's UTF-8 bytes as a byte array;
`string.decode(bytes)` turns valid UTF-8 bytes back into a string
(`docs/design/06-strings-and-bytes.md`).

## Error messages

Runtime errors name the value the way Lua 5.4 does: `attempt to call a
nil value (global 'foo')`, `(field 'open')`, `(method 'read')`. mahina
keeps no names for locals and upvalues, so a value read from one gets no
name where Lua would say `(local 'f')` or `(upvalue 'f')`.

## Files and the operating system: `io` and `os`

### Which functions a program has

The CLI gives a program the whole library. An embedding host chooses
which **system interfaces** a VM gets, and a program in a VM without one
does not have its functions at all, as if the library had never been
opened (`docs/design/65-cli-host-library.md` §5):

| Interface | Functions |
|---|---|
| `files` | `io.open`, `io.tmpfile`, `os.remove`, `os.rename`, `os.tmpname` |
| `stdio` | `io.stdin` (and stdin as the default input) |
| `files` or `stdio` | `io.read`, `io.lines`, `io.input`, `io.output`, `io.close`: either one installs them |
| `env` | `os.getenv`, `os.exit` |
| `time` | `os.time`, `os.date` |
| `clock` | `os.clock` |
| `random` | an entropy seed for `math.random` (without it, every run draws the same sequence) |

`io.write`, `print`, `io.stdout`, `io.stderr`, `io.type` and the file
methods are always there. On the CLI, `--system` limits the interfaces
(`--system none`, `--system files,time`); the browser playground has
only `clock` and `random`. Calling a missing function says why:

```
attempt to call a nil value (field 'open'; io.open needs the 'files' system interface, which this VM does not have)
```

`io.popen`, `os.execute` and `os.setlocale` do not exist anywhere: a
spawned process can't be recorded and replayed, and formatting always
uses the C locale.

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
