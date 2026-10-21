# 65 — The `io` and `os` host library — Design

Status: Phase 0 implemented; Phases 1–6 not started. Ground rules D1–D4
(2026-10-20) and all ten design questions Q1–Q10 (2026-10-21) decided by
Bart; the design below reflects the answers.
Owner: Bart
Last updated: 2026-10-21

## Implementation status

Tracking the gap between this design and what's on master. Tick items as
they land; move whole phases to Done once everything inside them is
checked. Every phase lands behind `just test`, `just hashgate` and
`just embed-test`; Phase 0 and Phase 3 also carry the benchmarks in §9.

### Done

- [x] **Decision D1 — the determinism guarantee does not bend.** Every
  input an `io`/`os` call returns is logged in record and fed back in
  replay. Bart, 2026-10-20. (Q8 adds the size cap that keeps this from
  surprising anyone.)
- [x] **Decision D2 — a replay does not write.** The write already
  happened when the run was recorded. Replay feeds back what the write
  returned at the time (success, or the error), and anything the program
  later read back is in the log as a read. Bart, 2026-10-20.
- [x] **Decision D3 — text is UTF-8, not bytes.** mahina strings are
  code-point strings (doc 06); `io` does not try to be Lua-compatible
  for byte strings. Bart, 2026-10-20.
- [x] **Decision D4 — embedding gets no system interfaces by default**,
  but enabling all of them must be one switch. Bart, 2026-10-20.
- [x] **Decisions Q1–Q10** (§10). Bart, 2026-10-21.
- [x] **Phase 0 — stdout/stderr correctness and buffering.** 2026-10-21.
  - [x] Streaming writers for stdout/stderr (`src/io.zig`,
    `writerStreaming`). `File.writer()` was std's *positional* writer, so
    `prog > f 2>&1` made stdout and stderr each write from their own
    offset 0 and overwrite each other (usability study §1).
  - [x] The C-stdio buffering policy (§6, Q9), replacing the flush on
    every `io.write` and `print`: line-buffered on a terminal
    (`File.isTty`), fully buffered otherwise (4 KiB, sized by the sweep
    in §9); stdout flushed before every stderr write (`stderrWriter`,
    jitdbg probes), on `io.flush` (new) and when `main` returns. The
    stdin-read and `os.exit` flush points arrive with those functions
    (Phases 3 and 4); `setvbuf` with file handles (Phase 3).
  - [x] Benchmarks `bench/stdlib/io_print.lua` and `io_write.lua` (§9).
  - [x] Inventory rows for `io.write` and `io.flush` (`base-host`,
    `partial`: both act on stdout only until Phase 3 adds handles).

### Outstanding

- [ ] **Phase 1 — one host seam and the system switch.**
  - [ ] `HostSystem` (§5) replaces `FsSource` and `HostEnv` and adds
    files, stdio, wall time and the local time zone.
  - [ ] Move the real-OS implementation out of `src/main.zig` into
    `src/host_system.zig`, used by the CLI and `src/capi.zig`.
  - [ ] `mh_config.system` (C) and a builder switch (Rust); off by
    default (D4), the clock and random seed included (Q4).
  - [ ] A deterministic default seed for `math.random` when no seed
    source is enabled (Q4).
  - [ ] Without an interface group, its functions are not installed
    (Q5, §5.3). This removes the non-catchable `FsUnavailable` /
    `EnvUnavailable` errors that poison an embedded VM today.
- [ ] **Phase 2 — the effect-log format for host operations.**
  - [ ] Error results and the new effect kinds (§4.2); binary results
    as inline bytes (§4.2, Q1).
  - [ ] The error mode (§4.4) recorded with the log, so a replay cannot
    run under the other mode.
  - [ ] The recording size cap, 1 MiB by default, configurable (§4.5,
    Q8).
  - [ ] `effect_format_version` bump; `schema/trace.json` and the
    regenerated Zig and TS codecs (`tools/regen-trace-schema.sh`).
- [ ] **Phase 3 — file handles and the `io` library.**
  - [ ] The `file` heap object (§4.1), its methods table, and keyframe
    serialization, including the reopen fingerprint (Q7).
  - [ ] `io.open/close/read/write/lines/input/output/flush/type/tmpfile`,
    `io.stdin/stdout/stderr`, `file:read/write/lines/seek/flush/setvbuf/close`;
    text and `b` modes (Q1, Q2).
  - [ ] The raising error mode and the Lua-compatibility mode (§4.4),
    with the CLI flag and the embedding config field.
  - [ ] Live resume of a restored keyframe: handles refuse operations,
    or reopen under the opt-in flag when the file is unchanged (§4.1,
    Q7).
  - [ ] Record/replay tests for every effect kind, including a replay
    with the host system detached.
- [ ] **Phase 4 — the `os` library.**
  - [ ] `os.exit` (§7, Q6), `os.getenv`, `os.time`, `os.date` (§8),
    `os.remove`, `os.rename`, `os.tmpname`.
  - [ ] Remove the bare `getenv`/`argc`/`argv` globals (Q3).
- [ ] **Phase 5 — the visualiser.** "Run both + diff" refuses programs
  whose native run used a system interface, with a message saying why
  (Q10).
- [ ] **Phase 6 — docs and inventory.** Flip the 27 `cli-binding` rows;
  update doc 02's taxonomy table; document the user-facing differences
  (raising errors and the compatibility mode, code-point `read(n)`,
  byte arrays in `b` mode, the size cap).
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
  script except through the effect log. The size cap (§4.5) refuses a
  recording that grows too large; it never drops entries.
- **Replay never touches the host.** Reads come from the log; writes,
  removes and renames are not performed. What they returned is in the
  log.
- **Text in, text out.** A text-mode read that does not decode as UTF-8
  is an error, never a corrupted string (doc 06's rule for the
  text/binary boundary). Binary files are read and written as doc 06's
  binary type, the byte array (Q1), never as strings.
- **No system access unless the host asks.** The CLI asks for all of
  it. An embedder asks with one switch, or not at all.

## 3. Goals and non-goals

### Goals

- The Lua 5.4 `io` library and the `cli-binding` part of `os`, with
  Lua's calling conventions, as far as D3 allows. Failures raise by
  default; a Lua-compatibility mode gives Lua's `nil, msg, code`
  returns (§4.4).
- Every operation recordable and replayable, keyframes included.
- One host seam for every system interface, implemented once for real
  OS access and shared by the CLI and the C API.
- Speed: reading and writing large files is not much slower than
  `lua5.4` (§9).

### Non-goals (v1)

- Byte strings (D3). Binary data is byte arrays (Q1).
- `io.popen` and `os.execute`: excluded (process spawning is
  unrecordable).
- `os.setlocale`: excluded. Formatting uses a fixed C locale.
- Network I/O.
- The browser: the wasm build has no system interface, so these
  functions are absent there (§5.3), and the visualiser refuses to
  compare programs that use them (Q10).

## 4. The model

### 4.1 File handles are VM objects

A Lua file handle is a userdata. mahina gets a `file` heap object
(`ObjectType.file`). Its state:

- `id` — a VM-assigned handle number, a deterministic counter.
- `kind` — `stdin`, `stdout`, `stderr` or `file`.
- `mode` — the `io.open` mode, including whether it is binary (`b`).
- `closed`.

The host owns the OS side: a table from handle id to an OS file. The VM
never sees a file descriptor.

- **Off / record:** each method calls the host with the handle id.
- **Replay:** the handle exists only as the VM object. Every method
  returns from the log, so replay needs no host at all.

Methods come from one shared metatable (`__index`, `__name = "FILE*"`,
`__tostring`, `__close`). There is no `__gc`: the GC has no finalizers
(doc 02), so an unclosed file stays open until `os.exit` or VM teardown
closes it.

**Keyframes (Q7).** A keyframe serializes the four fields, plus, for an
open `file` handle, its path, its byte position and a fingerprint of the
file as it was at capture (size and modification time; content hashing
would cost a full read of the file). Restore for replay needs none of
the extra fields. Restore followed by *live* execution:

- **By default**, the handles are restored but every operation on them
  raises "file handle was not reopened after restore".
- **With the reopen flag** (`--reopen-files` on the CLI, a config field
  when embedding), restore reopens each file by path, checks the
  fingerprint, and seeks to the recorded position. A file whose
  fingerprint no longer matches stays closed and raises like the
  default case. This is for restarting a session straight after a
  crash, when nothing has touched the files since.

### 4.2 Effects

Each host call is one effect. The kind says which operation; the result
is what the script sees, or the error it raises.

| Operation | Kind | Logged result |
|---|---|---|
| `io.open`, `io.tmpfile` | `file_open` | handle id, or an error |
| `read` / `lines` step (any format) | `file_read_op` | the value read (string, number, byte array, `nil` at EOF), or an error |
| `write` | `file_write` | success, or an error |
| `seek` | `file_seek` | the new position, or an error |
| `flush`, `setvbuf`, `close` | `file_control` | success, or an error |
| `os.remove`, `os.rename` | `fs_mutate` | success, or an error |
| `os.tmpname` | `fs_tmpname` | the name |
| `os.time()` | `wall_clock` | integer seconds |
| `os.date` / `os.time(t)` in local time | `local_offset` | the zone offset in seconds |
| `os.getenv` | `getenv` (exists) | string or `nil` |

Each kind logs the result only, as today: the arguments are a
deterministic function of the program, so replay reproduces them. The
log grows with what was actually read, not with file sizes: reading a
2 GB file line by line logs 2 GB of lines; reading one line of it logs
one line.

An error is logged as its error class and message. Messages are
mahina's own text built from a small set of classes (`not found`,
`permission denied`, `exists`, `is a directory`, `not valid UTF-8`,
`other`), not `strerror`. The existing `file_read` does the same
("cannot open <path>" depends only on the path), so a recording made on
Linux replays with the same messages anywhere. The `code` a
compatibility-mode return carries is the class number, not the OS
errno.

The existing `file_read` kind (whole-file reads for `loadfile`/`dofile`/
`require`) stays as it is.

**Binary results.** A `b`-mode read returns a byte array, a heap table,
which the effect log's rule ("scalars and inline strings, never heap
refs", doc 02) does not allow. It is carried as inline bytes with its
own result tag and rebuilt into a fresh byte array on replay, the way
inline strings are re-interned today.

### 4.3 Writes under replay

In off and record mode a write goes to the host, and record logs what
it returned. In replay the write is not performed, and the logged result
is returned (D2).

stdout and stderr are different: their text is the program's observable
output, and the replay driver needs it (the visualiser shows "output so
far" at every step). In replay they write to the VM's output seam
(`Vm.out`, plus a new `Vm.err`), and the driver decides where that goes.
The OS never sees them, as with any other write.

### 4.4 Errors: raise, or Lua's returns (Q1 and its follow-up)

**By default, every failed `io`/`os` operation raises** a catchable
error: a missing file in `io.open`, invalid UTF-8 in a text read, a
failed write, `os.remove` of a missing file. The message is the class
text from §4.2 plus the path or handle, e.g. `cannot open 'cfg.txt':
not found`.

**The Lua-compatibility mode** returns Lua's `nil, msg, code` from the
same calls instead, so existing Lua code (`local f = io.open(p) if not
f then … end`) keeps working. Calls that raise in Lua too, such as a
read on a closed handle, raise in both modes.

The mode is per VM: a CLI flag (`--lua-io-errors`) and an embedding
config field. It changes what a program observes for the same logged
results, so it is part of the recording: record logs it once, and
replay refuses a log made under the other mode, the way it refuses a
`unicode_version` mismatch (doc 02).

### 4.5 The recording size cap (Q8)

A recording whose effect log would grow past a cap is refused with a
clear error naming the cap and how to raise it. The default is 1 MiB:
large enough for most files a script reads, small enough that the cap
is met in testing rather than as a surprise in production. It is
configurable (`--effect-log-limit <bytes>` on the CLI, an embedding
config field; `0` means unlimited).

The cap counts the encoded log, every effect kind included. It applies
only in record mode; off mode logs nothing and has no cap.

## 5. The host seam

### 5.1 `HostSystem`

One vtable replaces `FsSource` and `HostEnv`:

- **Files:** open, read, write, seek, flush, setvbuf, close, tmpfile,
  remove, rename, tmpname, and the fingerprint used for reopening (Q7).
- **stdio:** the three standard handles (ids 0, 1, 2).
- **Environment:** `getenv`, argument count, argument i.
- **Time:** wall-clock now; the local zone offset at a given UTC time.
- **Whole-file read** for `loadfile`/`dofile`/`require` (today's
  `FsSource.read`).

`ClockSource` (`os.clock`) and `RandomSeedSource` stay separate
interfaces, but in embedding they are behind the same switch (Q4).

Reads are buffered on the host side: the host keeps a buffer per handle
and answers line, count, number and whole-file reads from it, so a line
loop costs one host call per line, not one syscall per character. A
text-mode `read(n)` counts code points (Q2), so the host reads whole
characters: it never returns half of one.

The real-OS implementation moves out of `src/main.zig` (`EnvCtx`,
`FsCtx`) into its own module, `src/host_system.zig`. It is one of the
`std.Io` users Rule Z-2 confines, alongside `src/io.zig` and
`src/viz_server.zig`.

### 5.2 Enabling it

- **CLI:** always installed.
- **C API:** a new `mh_config.system` bit mask. Zero means none (D4).
  The groups are files, stdio, environment (`os.getenv`, `os.exit`),
  time (`os.time`, `os.date`), clock (`os.clock`) and random seed;
  `MH_SYSTEM_ALL` enables everything. `capi.zig` installs the shared
  real-OS implementation.
- **Rust:** the same mask on the VM builder, e.g. `.system(System::ALL)`.
- **A custom implementation:** a host can supply its own `HostSystem`
  (an in-memory filesystem, an archive, a sandbox). The C API exposes
  the vtable for that; the mask is the convenience for the common case.

**Deterministic by default (Q4).** Today the C API injects the host
clock and an OS random seed, so two embedded runs differ. With the
switch off, `os.clock` is absent and `math.random` draws from a fixed
default seed, so an embedded VM is deterministic out of the box.

### 5.3 What a VM without it sees (Q5)

Without a group, its functions are not installed: `io.open` is `nil`,
as in a Lua state that never opened the library.

The non-catchable `FsUnavailable` / `EnvUnavailable` errors go away.
The usability study found that one `require` in an embedded script
poisons the whole VM. With no files group, `require`'s file searcher
reports "module not found" like any other miss, and `package.preload`
and host-registered searchers still work.

## 6. stdout and stderr (Q9)

Phase 0 has two parts.

**Correctness.** The stdout and stderr writers become streaming writers
(`writerStreaming`), so a file shared by both (`2>&1`) is appended to,
not written at fixed offsets.

**Buffering.** Today `print` and `io.write` flush on every call: one
`write` syscall per call. The policy, as C stdio has for Lua:

- stdout is line-buffered when it is a terminal and fully buffered
  otherwise.
- stdout is flushed before any stderr write (so `2>&1` keeps the
  program's order), before a read from stdin, on `io.flush`, on
  `os.exit` and at VM teardown.
- `setvbuf` overrides the policy per handle.

## 7. `os.exit` (Q6)

`os.exit(code, close)` ends the program; it is not an input and logs
nothing. In replay, the run simply reaches the same call and ends there.

It unwinds as a non-catchable signal carrying the status (`pcall` must
not catch it). Then:

- **CLI:** flush stdout/stderr, close open files if `close` is true,
  and exit with the status (`true` → 0, `false` → 1, an integer as
  given).
- **Embedding:** `os.exit` never ends the host process. It returns from
  `mh_eval`/`mh_call` with a new status, `MH_EXIT`, and the code. It is
  in the environment group (§5.2), so a VM without that group has no
  `os.exit` at all.

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
| `f:read("a")` of a 100 MB file in `rb` mode | ≤ 1.5× `lua5.4` (byte array in the `u8` lane) |
| Record-mode line loop, cap raised | log ≈ the bytes read, no superlinear growth |

The budgets are a proposal for Bart to adjust.

**Phase 0 measurements** (2026-10-21; best of 7 to 11 runs, Linux x86-64,
ReleaseFast; "before" is master with a flush per call):

| Benchmark | before | after | `lua5.4` | LuaJIT |
|---|---|---|---|---|
| `io_print` 1 M lines → file | 0.227 s | 0.038 s | 0.400 s | 0.054 s |
| `io_print` 1 M lines → pipe | 0.208 s | 0.033 s | — | — |
| `io_write` 100 MB in 4 KiB → file | 0.052–0.057 s | 0.050–0.055 s | 0.055 s | 0.051 s |
| `io_write` 100 MB in 4 KiB → pipe | 0.0077–0.0083 s | 0.0071 s | 0.007 s | — |

Both are inside the 1.5× budget. A million `print`s went from 1 M
`pwritev` calls to 443 `writev` calls. Sweeping the stdout buffer:
16 KiB and 32 KiB cut `print` to a file by a further 1–2 ms, but they
copy each 4 KiB `io.write` into the buffer instead of passing it
straight to the kernel, so 100 MB to a pipe took 9–13 ms instead of
7 ms. We use 4 KiB.

## 10. Design questions (all decided 2026-10-21)

Kept with their options, so the reasoning stays visible.

- [x] **Q1 — binary files and invalid UTF-8.** Doc 06 already has a
  binary type (byte arrays: integer tables `1..n`, packed by the `u8`
  lane, converted with `string.encode`/`string.decode`) and a rule that
  invalid UTF-8 is a caught error, never silent corruption. So U+FFFD
  replacement was out. Options:
  1. **`b` mode means byte arrays.** In `"rb"`, reads return byte
     arrays (`read(n)` counts bytes, `"a"` reads everything, `"l"` is
     refused); in `"wb"`, `write` takes byte arrays.
  2. **Text only.** `b` is refused ("binary files are not supported").

  **Decided: 1, byte arrays.** Error form: **raise**, with a
  compatibility mode that returns `nil, msg, code` instead (§4.4). The
  follow-up asked whether "raise" covers `io.open` and the other calls
  too; Bart's answer was the compatibility mode, "one raises, the other
  returns nil".
- [x] **Q2 — what a text-mode `read(n)` counts.** Code points, matching
  `#s`, or bytes, matching Lua (a byte count can end inside a character,
  so it would have to stop short or overshoot). `seek` positions are
  bytes either way. **Decided: code points.**
- [x] **Q3 — the bare `getenv`, `argc` and `argv` globals.** Move
  `getenv` to `os.getenv` and remove all three, or keep them as well.
  **Decided: `os.getenv` only**; the bare globals go (`arg` and `...`
  cover the arguments).
- [x] **Q4 — the clock and random seed in embedding.** Part of the
  off-by-default switch, or on by default. **Decided: off by default**,
  so an embedded VM is deterministic out of the box (§5.2).
- [x] **Q5 — a missing interface.** Absent (`nil`), or present and
  raising "not available". **Decided: absent.**
- [x] **Q6 — `os.exit` in embedding.** Returns `MH_EXIT` to the host
  when enabled, or never available. **Decided: `MH_EXIT`.**
- [x] **Q7 — a keyframe restored and resumed live, with files open.**
  Options were detached handles, reopening by path, or refusing the
  resume. **Decided (Bart's own option):** restore the handles but
  refuse operations on them, unless a flag allows reopening files that
  have not changed since they were recorded, e.g. restarting a session
  straight after a crash (§4.1).
- [x] **Q8 — very large reads.** Log everything, or a configurable cap.
  **Decided: a cap, about 1 MB by default** — "large enough to catch
  most files, and small enough that you encounter it before it
  surprises you" (§4.5).
- [x] **Q9 — stdout buffering.** The C-stdio policy, or flushing on
  every call. **Decided: the C-stdio policy** (§6).
- [x] **Q10 — the browser.** Leave the difference to the comparison, or
  an in-memory filesystem later. **Decided (Bart's own option):** report
  that the script cannot be compared and refuse to compare it. The
  native run's effect log says whether a system interface was used; the
  visualiser refuses the comparison when it was.

## 11. References

- `02-determinism.md` — the effect log, `file_read`, `HostEnv`,
  `FsSource`.
- `04-snapshot-replay-schema.md` — the effect and keyframe formats.
- `06-strings-and-bytes.md` — code-point strings and byte arrays.
- `59-rust-embedding-api.md` — `mh_config`, the C and Rust surfaces.
- `63-trace-host-calls.md` — host calls in traces.
- `docs/lua-stdlib-inventory.csv` — the 27 `cli-binding` rows.
- `TODO_USABILITY.md` — the study this comes from.
- Lua 5.4 reference manual §6.8 (`io`) and §6.9 (`os`).
