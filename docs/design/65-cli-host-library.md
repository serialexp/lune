# 65 — The `io` and `os` host library — Design

Status: draft, not yet implemented. Four ground rules decided by Bart
(2026-10-20, §2); the open questions in §10 need answers before Phase 1.
Owner: Bart
Last updated: 2026-10-20

## Implementation status

Tracking the gap between this design and what's on master. Tick items as
they land; move whole phases to Done once everything inside them is
checked. Every phase lands behind `just test`, `just hashgate` and
`just embed-test`; Phase 0 and Phase 3 also carry the benchmarks in §9.

### Done

- [x] **Decision D1 — the determinism guarantee does not bend.** Every
  input an `io`/`os` call returns is logged in record and fed back in
  replay. A replay of a program that reads a 2 GB file carries 2 GB of
  log (or the recording is refused as silly; §10 Q8). Bart, 2026-10-20.
- [x] **Decision D2 — a replay does not write.** The write already
  happened when the run was recorded. Replay feeds back what the write
  returned at the time (success, or the error), and anything the program
  later read back is in the log as a read. Bart, 2026-10-20.
- [x] **Decision D3 — text is UTF-8, not bytes.** mahina strings are
  code-point strings (doc 06); `io` does not try to be Lua-compatible
  for byte strings. Bart, 2026-10-20.
- [x] **Decision D4 — embedding gets no system interfaces by default**,
  but enabling all of them must be one switch. Bart, 2026-10-20.

### Outstanding

- [ ] **Decisions Q1–Q10** (§10).
- [ ] **Phase 0 — stdout/stderr correctness and buffering.**
  - [ ] Streaming writers for stdout/stderr (`src/io.zig`). Today
    `File.writer()` is std's *positional* writer, so `prog > f 2>&1`
    makes stdout and stderr each write from their own offset 0 and
    overwrite each other (usability study §1).
  - [ ] A buffering policy (§6) with a benchmark, replacing the flush
    on every `io.write` and `print`.
  - [ ] Fix the inventory row for `io.write` (says `not-started`; it
    works).
- [ ] **Phase 1 — one host seam and the system switch.**
  - [ ] `HostSystem` (§5) replaces `FsSource` and `HostEnv` and adds
    files, stdio, wall time and the local time zone.
  - [ ] Move the real-OS implementation out of `src/main.zig` into a
    module both the CLI and `src/capi.zig` use.
  - [ ] `mh_config.system` (C) and a builder switch (Rust) that enable
    it; off by default (D4).
  - [ ] Without the interface, its library functions are not installed
    (§5.3). This removes the non-catchable `FsUnavailable` /
    `EnvUnavailable` errors that poison an embedded VM today.
- [ ] **Phase 2 — the effect-log format for host operations.**
  - [ ] Multi-value and error results (`nil, msg, code`) in
    `EffectResult`; the new effect kinds (§4.2).
  - [ ] `effect_format_version` bump; `schema/trace.json` and the
    regenerated Zig and TS codecs (`tools/regen-trace-schema.sh`).
- [ ] **Phase 3 — file handles and the `io` library.**
  - [ ] The `file` heap object (§4.1), its methods table, and keyframe
    serialization.
  - [ ] `io.open/close/read/write/lines/input/output/flush/type/tmpfile`,
    `io.stdin/stdout/stderr`, `file:read/write/lines/seek/flush/setvbuf/close`.
  - [ ] Record/replay tests for every effect kind, including a replay
    with the host system detached.
- [ ] **Phase 4 — the `os` library.**
  - [ ] `os.exit` (§7), `os.getenv`, `os.time`, `os.date` (§8),
    `os.remove`, `os.rename`, `os.tmpname`.
  - [ ] The bare `getenv`/`argc`/`argv` globals, per Q3.
- [ ] **Phase 5 — docs and inventory.** Flip the 27 `cli-binding` rows;
  update doc 02's taxonomy table; the user-facing differences (Q1, Q2).
- [ ] **Defer — `collectgarbage`.** It is `core`, not `cli-binding`, and
  `"count"` is a determinism question of its own (heap sizes differ
  between wasm32 and x86-64). Tracked in `TODO_USABILITY.md` §1.
- [ ] **Defer — a REPL, `mahina -` for stdin, `...` in the main chunk.**
  CLI entry points, `TODO_USABILITY.md` §2. They need nothing from this
  doc except Phase 3's `io.stdin`.

## 1. Why this exists

The `cli-binding` tier of `docs/lua-stdlib-inventory.csv` is 27
functions, and all of them are `not-started`. The usability study
(`TODO_USABILITY.md`, 2026-10-20) found this the first thing that stops
anyone using the CLI: a script cannot read stdin or a file, write a
file, exit with a status, or read the time. `io.write` and `os.clock`
are the only pieces that exist.

Most of the machinery is already built. Doc 02 has the effect log:
record calls the host and logs the result, replay feeds the log back and
never touches the host. `loadfile`/`dofile` read files through the
`file_read` effect, `getenv`/`argc`/`argv` go through `HostEnv`, and
results that are strings ride the log inline. This doc extends that to
the rest of `io` and `os`. It is the contract for which host operations
exist, how each is logged, and what an embedder gets.

## 2. Ground rules

The four decisions in the status section (D1–D4) shape everything below.
Restated as rules:

- **Inputs are logged, always.** No host operation returns a value to a
  script except through the effect log. There is no "too big to log"
  escape hatch.
- **Replay never touches the host.** Reads come from the log; writes,
  removes and renames are not performed. What they returned is in the
  log.
- **Text in, text out.** A text-mode read that does not decode as UTF-8
  is a caught error, never a corrupted string (doc 06's rule for the
  text/binary boundary). Binary data, if Q1 takes it, is doc 06's binary
  type, the byte array, never a string.
- **No system access unless the host asks.** The CLI asks for all of
  it. An embedder asks with one switch, or not at all.

## 3. Goals and non-goals

### Goals

- The Lua 5.4 `io` library and the `cli-binding` part of `os`, with
  Lua's calling conventions and error returns (`nil, msg, code`), as
  far as D3 allows.
- Every operation recordable and replayable, keyframes included.
- One host seam for every system interface, implemented once for real
  OS access and shared by the CLI and the C API.
- Speed: reading and writing large files is not much slower than
  `lua5.4` (§9).

### Non-goals (v1)

- Byte strings (D3). Binary files are either byte arrays or not
  supported (Q1).
- `io.popen` and `os.execute`: excluded (process spawning is
  unrecordable).
- `os.setlocale`: excluded. Formatting uses a fixed C locale.
- Network I/O.
- The browser: the wasm build has no system interface, so these
  functions are absent there (§5.3).

## 4. The model

### 4.1 File handles are VM objects

A Lua file handle is a userdata. mahina gets a `file` heap object
(`ObjectType.file`). Its state:

- `id` — a VM-assigned handle number, a deterministic counter.
- `kind` — `stdin`, `stdout`, `stderr` or `file`.
- `mode` — the `io.open` mode.
- `closed`.

The host owns the OS side: a table from handle id to an OS file. The VM
never sees a file descriptor.

- **Off / record:** each method calls the host with the handle id.
- **Replay:** the handle exists only as the VM object. Every method
  returns from the log, so replay needs no host at all.

Methods come from one shared metatable (`__index`, `__name = "FILE*"`,
`__tostring`, `__close`, `__gc` is not needed: the GC has no finalizers,
doc 02, so an unclosed file stays open until `os.exit` or VM teardown
closes it).

A keyframe serializes the four fields. Restore for replay is complete.
Restore followed by *live* execution has no OS file behind the handle;
Q7 decides what happens.

### 4.2 Effects

Each host call is one effect. The kind says which operation; the result
is what the script sees.

| Operation | Kind | Logged result |
|---|---|---|
| `io.open`, `io.tmpfile` | `file_open` | handle id, or `nil, msg, code` |
| `read` / `lines` step (any format) | `file_read_op` | the value read (string, number, `nil` at EOF), or an error |
| `write` | `file_write` | success, or `nil, msg, code` |
| `seek` | `file_seek` | the new position, or an error |
| `flush`, `setvbuf`, `close` | `file_control` | success, or an error |
| `os.remove`, `os.rename` | `fs_mutate` | success, or `nil, msg, code` |
| `os.tmpname` | `fs_tmpname` | the name |
| `os.time()` | `wall_clock` | integer seconds |
| `os.date` / `os.time(t)` in local time | `local_offset` | the zone offset in seconds |
| `os.getenv` | `getenv` (exists) | string or `nil` |

Each kind logs the result only, as today: the arguments are a
deterministic function of the program, so replay reproduces them. The
log grows with what was actually read, not with file sizes: reading a
2 GB file line by line logs 2 GB of lines; reading one line of it logs
one line.

Error messages are mahina's own text built from a small error class
(`not found`, `permission denied`, `exists`, `is a directory`, `other`),
not `strerror`. The existing `file_read` does the same ("cannot open
<path>" depends only on the path), so a recording made on Linux replays
with the same messages anywhere. The `code` value is the class number,
not the OS errno.

The existing `file_read` kind (whole-file reads for `loadfile`/`dofile`/
`require`) stays as it is.

If Q1 takes byte arrays for `b` mode, a binary read's result is a heap
table, which the effect log's rule ("scalars and inline strings, never
heap refs", doc 02) does not allow. It is carried as inline bytes with
its own result tag and rebuilt into a fresh byte array on replay, the
way inline strings are re-interned today.

### 4.3 Writes under replay

In off and record mode a write goes to the host, and record logs what
it returned. In replay the write is not performed, and the logged result
is returned (D2).

stdout and stderr are different: their text is the program's observable
output, and the replay driver needs it (the visualiser shows "output so
far" at every step). In replay they write to the VM's output seam
(`Vm.out`, plus a new `Vm.err`), and the driver decides where that goes.
The OS never sees them, as with any other write.

## 5. The host seam

### 5.1 `HostSystem`

One vtable replaces `FsSource` and `HostEnv`:

- **Files:** open, read, write, seek, flush, setvbuf, close, tmpfile,
  remove, rename, tmpname.
- **stdio:** the three standard handles (ids 0, 1, 2).
- **Environment:** `getenv`, argument count, argument i.
- **Time:** wall-clock now; the local zone offset at a given UTC time.
- **Whole-file read** for `loadfile`/`dofile`/`require` (today's
  `FsSource.read`).

`ClockSource` (`os.clock`) and `RandomSeedSource` stay separate. They
are cheap and useful without a filesystem, and Q4 decides their
embedding default.

Reads are buffered on the host side: the host keeps a buffer per handle
and answers line, count, number and whole-file reads from it, so a line
loop costs one host call per line, not one syscall per character.

The real-OS implementation moves out of `src/main.zig` (`EnvCtx`,
`FsCtx`) into its own module, `src/host_system.zig`. It is one of the
`std.Io` users Rule Z-2 confines, alongside `src/io.zig` and
`src/viz_server.zig`.

### 5.2 Enabling it

- **CLI:** always installed.
- **C API:** a new `mh_config.system` field. Zero means none (D4); a
  bit mask enables groups (files, stdio, environment, time), and
  `MH_SYSTEM_ALL` enables everything. `capi.zig` installs the shared
  real-OS implementation.
- **Rust:** the same mask on the VM builder, e.g. `.system(System::ALL)`.
- **A custom implementation:** a host can supply its own `HostSystem`
  (an in-memory filesystem, an archive, a sandbox). The C API exposes
  the vtable for that; the mask is the convenience for the common case.

### 5.3 What a VM without it sees

Without a group, its functions are simply not installed: `io.open` is
`nil`, as in a Lua state that never opened the library. The other
option is installing them to raise a catchable "not available" error
(Q5).

Either way, the non-catchable `FsUnavailable` / `EnvUnavailable` errors
go away. The usability study found that one `require` in an embedded
script poisons the whole VM. With no filesystem group, `require`'s file
searcher reports "module not found" like any other miss, and
`package.preload` and host-registered searchers still work.

## 6. stdout and stderr

Phase 0 has two parts.

**Correctness.** The stdout and stderr writers become streaming writers
(`writerStreaming`), so a file shared by both (`2>&1`) is appended to,
not written at fixed offsets.

**Buffering.** Today `print` and `io.write` flush on every call: one
`write` syscall per call. The proposal:

- stdout is line-buffered when it is a terminal and fully buffered
  otherwise, as C stdio does for Lua.
- stdout is flushed before any stderr write (so `2>&1` keeps the
  program's order), before a read from stdin, on `io.flush`, on
  `os.exit` and at VM teardown.
- `setvbuf` overrides the policy per handle.

Q9 is whether to take this or keep flushing on every call.

## 7. `os.exit`

`os.exit(code, close)` ends the program; it is not an input and logs
nothing. In replay, the run simply reaches the same call and ends there.

It unwinds as a non-catchable signal carrying the status (`pcall` must
not catch it). Then:

- **CLI:** flush stdout/stderr, close open files if `close` is true,
  and exit with the status (`true` → 0, `false` → 1, an integer as
  given).
- **Embedding:** `os.exit` must never end the host process. It returns
  from `mh_eval`/`mh_call` with a new status, `MH_EXIT`, and the code.
  It is in the environment group (§5.2), so a VM without system
  interfaces has no `os.exit` at all (Q6).

## 8. Time and dates

- `os.time()` reads the host wall clock: the `wall_clock` effect,
  integer seconds since the epoch.
- `os.time(t)` turns a date table into a timestamp; `os.date(fmt, t)`
  formats one. Both are pure arithmetic in UTC. Local time needs one
  host input, the zone offset at that instant (it changes with daylight
  saving), logged as `local_offset`. A `!` prefix in `os.date` means
  UTC and needs no host at all.
- Formatting (`%Y`, `%m`, `%H`, `%a`, `%c`, …) is implemented in the VM
  in the C locale, so `os.date` gives the same text on every machine for
  the same logged inputs.
- `os.clock` stays the monotonic clock in seconds (the absolute value
  differs from Lua's CPU time since start; deltas match). `os.difftime`
  exists.

## 9. Performance

Each call is a host call: a trace barrier today, and possibly traced
after doc 63. In off mode (the CLI default) it costs the host call and
nothing else. Record adds one log entry per call, holding the result.

Phases 0 and 3 add benchmarks under `bench/` against `lua5.4` on the
same files:

| Benchmark | Budget |
|---|---|
| `print` 1 M short lines to a file | ≤ 1.5× `lua5.4` |
| `io.write` 100 MB in 4 KB strings | ≤ 1.5× `lua5.4` |
| `for l in io.lines(f)` over a 100 MB, 1 M-line file | ≤ 1.5× `lua5.4` |
| `f:read("a")` of a 100 MB file | ≤ 1.5× `lua5.4` (one UTF-8 validation pass) |
| Record-mode line loop over the same file | log ≈ the bytes read, no superlinear growth |

The budgets are a proposal for Bart to adjust.

## 10. Open questions for review

- [ ] **Q1 — binary files and invalid UTF-8.** Doc 06 already has a
  binary type (byte arrays: integer tables `1..n`, packed by the `u8`
  lane, converted with `string.encode`/`string.decode`) and a rule that
  invalid UTF-8 is a caught error, never silent corruption. So U+FFFD
  replacement is out. Options:
  1. **`b` mode means byte arrays.** In `"rb"`, reads return byte
     arrays (`read(n)` counts bytes, `"a"` reads everything, `"l"` is
     refused); in `"wb"`, `write` takes byte arrays. Text-mode reads
     that hit invalid UTF-8 return `nil, msg, code`.
  2. **Text only.** `b` is refused ("binary files are not supported");
     invalid UTF-8 returns `nil, msg, code`.

  Either way, which error form: the `nil, msg, code` return above, or a
  raised error.
- [ ] **Q2 — what a text-mode `read(n)` counts.** Code points, matching
  `#s`, or bytes, matching Lua (a byte count can end inside a character,
  so it would have to stop short or overshoot). `seek` positions are
  bytes either way (they come from the OS), so code-point reads make
  `seek` arithmetic less obvious.
- [ ] **Q3 — the bare `getenv`, `argc` and `argv` globals.** Options:
  1. Move `getenv` to `os.getenv` and remove all three bare globals,
     since `arg` and `...` cover the arguments (no compatibility kept,
     global Rule #8).
  2. Keep them as well as `os.getenv`.
- [ ] **Q4 — the clock and random seed in embedding.** The C API
  injects the host clock and an OS random seed today, so two embedded
  runs differ. Options:
  1. They become part of the system switch (off by default), so an
     embedded VM is deterministic by default. `math.random` then needs
     a fixed default seed; `os.clock` is absent.
  2. They stay on by default.
- [ ] **Q5 — a missing interface.** The function is absent (`nil`), or
  present and raising a catchable "not available" error.
- [ ] **Q6 — `os.exit` in embedding.** It returns `MH_EXIT` to the host
  when enabled, or is never available to embedded scripts.
- [ ] **Q7 — a keyframe restored and resumed live, with files open.**
  Options:
  1. The restored handles are detached: every operation on them
     returns an error.
  2. Restore reopens them by path and seeks to the recorded position
     (needs the path and position in the keyframe; the file may have
     changed).
  3. Live resume of a keyframe with open files is refused.
- [ ] **Q8 — very large reads.** Log everything (D1), or add a
  configurable log-size cap that refuses the recording when exceeded.
- [ ] **Q9 — stdout buffering.** The C-stdio policy in §6, or keep
  flushing on every call.
- [ ] **Q10 — the browser.** The wasm build has no system interface, so
  a program using `io.open` cannot pass the visualiser's wasm-vs-native
  comparison. Options: leave it (the comparison reports it as a
  difference), or give the browser an in-memory filesystem and a stdin
  text box later.

## 11. References

- `02-determinism.md` — the effect log, `file_read`, `HostEnv`,
  `FsSource`.
- `04-snapshot-replay-schema.md` — the effect and keyframe formats.
- `06-strings-and-bytes.md` — code-point strings (D3).
- `59-rust-embedding-api.md` — `mh_config`, the C and Rust surfaces.
- `63-trace-host-calls.md` — host calls in traces.
- `docs/lua-stdlib-inventory.csv` — the 27 `cli-binding` rows.
- `TODO_USABILITY.md` — the study this comes from.
- Lua 5.4 reference manual §6.8 (`io`) and §6.9 (`os`).
