# 65 — The `io` and `os` host library — Design

Status: Phases 0–6 implemented; open: the zone-record decision and the
deferred items below. Ground rules
D1–D4 (2026-10-20) and all ten design questions Q1–Q10 (2026-10-21)
decided by Bart; the design below reflects the answers.
Owner: Bart
Last updated: 2026-10-24

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
- [x] **Phase 1 — one host seam and the system switch.** 2026-10-24.
  - [x] `HostSystem` (§5, `src/system.zig`) replaces `FsSource` and
    `HostEnv`. Its vtable already names the file, stdio, wall-time and
    local-zone operations; the real implementation fills in whole-file
    reads and `getenv` so far, the rest arrive with Phases 3 and 4.
  - [x] The real-OS implementation moved out of `src/main.zig` into
    `src/host_system.zig` (`RealSystem`), used by the CLI and
    `src/capi.zig`.
  - [x] `mh_config.system` (C, `MH_SYSTEM_*`) and `Config.system`
    (Rust, `System::ALL` etc.); zero by default (D4), the clock and
    random seed included (Q4).
  - [x] A deterministic default seed for `math.random` when no seed
    source is enabled (`interp.default_random_seed`, Q4); it is logged
    like a host seed.
  - [x] Without an interface group, its functions are not installed
    (Q5, §5.3; `Vm.enableSystem`). The non-catchable `FsUnavailable`,
    `EnvUnavailable` and `RandomUnavailable` errors are gone: without a
    system, `loadfile`/`dofile`/`require` report "cannot open".
  - [x] The bare `getenv`/`argc`/`argv` globals removed (Q3, listed
    under Phase 4 before); `os.getenv` is in the env group.
  - [x] Extended beyond the plan: the CLI's `--system <groups>` flag
    (default `all`). The visualiser's native diff and coverage runs pass
    the playground's groups (`clock,random`), so both engines see the
    same globals.
- [x] **Phase 2 — the effect-log format for host operations.** 2026-10-24.
  - [x] Error results and the new effect kinds (§4.2): `file_open`,
    `file_read_op`, `file_write`, `file_seek`, `file_control`,
    `fs_mutate`, `fs_tmpname`, `wall_clock`, `local_offset`. A result is
    a value, the bytes of a `b`-mode read, or a failure class
    (`effectlog.Effect.Result`); bytes live in the log's own buffer and
    ride the wire inline (`EffectBytes`, tag 5), failures as their class
    (`HostFail`, tag 6). The decoder checks every result against its
    kind. `recordHost`/`recordHostBytes`/`replayHost` are the entry
    points the Phase 3 and 4 natives call.
  - [x] The error mode (§4.4) pinned into the log once per session as
    the `io_error_mode` kind (`noteIoErrorMode`, sharing
    `pinSessionConstant` with the Unicode version pin); a replay under
    the other mode fails with the non-catchable `IoErrorModeMismatch`.
    The mode itself (`Vm.io_errors`) gets its CLI flag in Phase 3.
  - [x] The recording size cap (§4.5, Q8): `Vm.effect_log_limit`,
    1 MiB by default, `--effect-log-limit <bytes>` on the CLI, 0 for
    none. It counts the encoded log exactly (`effectser.encodedEntrySize`,
    pinned against `encodeFile` by a test) and stops the run with the
    non-catchable `EffectLogLimit`, whose message names the limit and
    the flag.
  - [x] `effect_format_version` 6; `schema/trace.json` and the
    regenerated Zig and TS codecs.
- [x] **Phase 3 — file handles and the `io` library.** 2026-10-24.
  - [x] The `file` heap object (§4.1, `src/file.zig`), its methods
    table (`@file`, `__name = "FILE*"`) and keyframe serialization
    (`HeapFile`, keyframe v12: the file metatable, the default input and
    output and `next_file_id` are roots). The reopen fingerprint (size,
    modification time, position) is host metadata: a keyframe captured
    live takes it from the host, one captured in replay carries the
    stored one, and the viz keyframe comparison leaves it out.
  - [x] `io.open/close/read/write/lines/input/output/flush/type/tmpfile`,
    `io.stdin/stdout/stderr`, `file:read/write/lines/seek/flush/setvbuf/close`
    (`src/stdlib/io.zig`), text and `b` modes (Q1, Q2). The real host
    (`src/host_system.zig`) buffers reads (64 KiB) and writes (8 KiB) per
    handle. `io.tmpfile` opens in text mode (`w+`), since `b` would mean
    byte arrays. Byte arrays cannot be written to stdout/stderr, which
    are text streams.
  - [x] The raising error mode and the Lua-compatibility mode (§4.4):
    `--lua-io-errors`, `mh_config.lua_io_errors`, Rust
    `Config::lua_io_errors`. The mode is pinned in the log by the first
    host operation (`io_error_mode`), so a replay in the other mode is
    refused. Three new error classes for failures the VM decides without
    the host, never logged: `not_readable`, `not_writable`,
    `not_seekable`.
  - [x] Live resume of a restored keyframe: a restored `file`/`tmpfile`
    handle is detached and every operation raises "file handle was not
    reopened after restore"; `Vm.reopenFiles` reopens the ones whose
    fingerprint still matches, at the recorded position (§4.1, Q7).
  - [x] Record/replay tests for every effect kind, including a replay
    with no host at all (`src/interp_io_test.zig`, on the in-memory
    `FakeHost` in `src/interp_testutil.zig`, which fills 3 bytes at a
    time so every read crosses host buffers).
  - [x] Benchmarks `bench/stdlib/io_lines.lua`, `io_read_all.lua`,
    `io_read_all_bin.lua` (§9), all inside budget. Text `read("a")` was
    1.6× `lua5.4` until `String.countCodepoints` (every string's
    construction scan) was vectorised.
  - [x] Inventory rows for the 20 `io` functions; `io.type`,
    `io.stdout`/`io.stderr` and the `file:` methods moved to
    `base-host`, since every VM has them.
- [x] **Phase 4 — the `os` library.** 2026-10-24.
  - [x] `os.time`, `os.date` (§8), `os.remove`, `os.rename`,
    `os.tmpname` (`src/stdlib/os.zig`); `os.difftime` was already there.
    Calendar arithmetic and `strftime` in the C locale are
    `src/datetime.zig`; every C99 conversion, Lua's `checkoption`, and
    Lua 5.4's date-table errors and in-place normalization.
  - [x] The local zone, parsed by mahina rather than libc (Bart,
    2026-10-24): TZif files v1–v4 with their POSIX footer, and POSIX `TZ`
    rules (`src/tzif.zig`). The real host reads `$TZ` (a zoneinfo name
    under `$TZDIR`, an absolute file, or a rule; empty means UTC) or
    `/etc/localtime`; Windows asks `GetTimeZoneInformation`.
  - [x] Changed from the plan: the zone effect is `local_zone`, not
    `local_offset` (§4.2, §8 *As built*), carrying the offset, the
    daylight-saving flag and the abbreviation. Effect format version 7.
  - [x] `os.exit` (§7, Q6): the non-catchable `Error.Exit` with
    `Vm.exit_status`. The CLI exits with it after its usual reports and
    artifacts; the C API returns `MH_EXIT` (`mh_exit_status`), the Rust
    crate `Error::Exit`.
  - [x] Windows `getenv` in libmahina: the process environment block,
    tested under wine with the Windows paths and zone
    (`src/host_system.zig` tests).
  - [x] Tests: `src/interp_os_test.zig` (live results against
    `lua5.4`'s under the same `TZ`, both error modes, record/replay with
    no host, `os.exit` in every trace mode), the C API and Rust exit
    tests, and the real-OS tests in `src/host_system.zig`.
  - [x] Benchmark `bench/stdlib/os_date.lua` (§9).
  - [x] Inventory rows for the six functions.
- [x] **Phase 5 — the visualiser.** 2026-10-24.
  - [x] Changed from the plan (Bart, 2026-10-24): the refusal keys on the
    run's error, not on the effect log (§10 Q10, *As built*).
  - [x] Runtime errors name the value as Lua 5.4 does ("attempt to call a
    nil value (field 'open')", "(global 'foo')", "(method 'read')"),
    derived from the bytecode (`src/bc_names.zig`). A nil that a system
    group this VM lacks would have installed says so: "(field 'open';
    io.open needs the 'files' system interface, which this VM does not
    have)". Every embedding gets it; it is not a visualiser feature.
  - [x] "Run both + diff" reports "not compared" with that clause when
    either run stopped on it (`viz/src/diff.ts`); a program that handles
    the miss with `pcall` is compared as usual.
  - [x] Tests: `src/bc_names.zig` (names, the no-name cases, hand-built
    branch and loop CFGs, the comptime tables against `bc_liveness`),
    the messages in `interp_semantics_test.zig` and `interp_os_test.zig`
    (every trace mode), and the viz diff tests on both engines.
  - [x] Benchmark `bench/stdlib/pcall_faults.lua` (§9).
- [x] **Phase 6 — docs and inventory.** 2026-10-24.
  - [x] Inventory checked: every `io` and `os` row is `implemented` or
    `excluded`; the rows flipped with Phases 0, 3 and 4 (Rule Z-5). The
    "27 `cli-binding` rows" figure was from before several moved to
    `base-host`; 15 `cli-binding` rows remain, all implemented.
  - [x] Doc 02's effect taxonomy: the time, file and environment rows
    name their effect kinds; new rows for process spawning (forbidden),
    the io error mode (pinned), program output and `os.exit` (not
    inputs).
  - [x] `docs/differences-from-lua.md`, linked from the README: strings
    are text, error messages, the system interfaces, raising errors and
    `--lua-io-errors`, text and `b` modes, file handles, stdout
    buffering, `os.exit`, dates and times, and the recording cap.

### Outstanding

- [ ] **Defer — `--reopen-files` and its embedding config field.**
  Neither the CLI nor the C API can resume from a keyframe yet, so the
  flag has nothing to apply to; `Vm.reopenFiles` is the mechanism they
  will call.
- [ ] **Defer — `__close`.** mahina has no to-be-closed variables, so
  the file metatable has no `__close` and `io.lines` returns no
  closing value for one.
- [ ] **Defer — the cap's embedding config field.** The C API has no
  record mode yet, so there is nothing for an `mh_config` field to cap;
  it arrives with recording in the C API.
- [ ] **Decide — what the zone record carries.** Implemented as
  offset + daylight-saving flag + abbreviation, so `%Z` and `isdst`
  replay without a host (§8 *As built*). The alternative is offset only,
  with `%Z` printing the numeric offset; Bart has not confirmed the
  choice.
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

*As built (Phase 3):* the reopen is a call, `Vm.reopenFiles`, made after
restore once the host is set; the CLI flag and the config field wait for
a resume entry point (status section). The metatable has no
`__tostring` (`tostring` renders a handle natively, as "file (0x…)")
and no `__close` (no to-be-closed variables). A temporary file is
detached on restore like any other, and never reopened: it has no path.

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
| `os.date` / `os.time(t)` in local time | `local_offset` | the zone offset in seconds (built as `local_zone`, below) |
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

*As built (Phase 4):* `os.exit` sets `Vm.exit_status` (C's `int`) and
returns `Error.Exit`, which `catchable` excludes. `Vm.run` unwinds the
stack before returning it, as a finished run leaves it, so the CLI still
prints its reports and writes its artifacts (`--emit-effects`,
`--emit-keyframe`, …) and then exits with the low 8 bits, as C's `exit`
does. stdout is flushed and open files are flushed and closed at
teardown either way, so `close` has nothing to do. In the C API the
boundary is restored as for a catchable fault and the call returns
`MH_EXIT`; `mh_exit_status` gives the status. A nested `mh_call` inside a
host callback that returns `MH_EXIT` leaves the exit pending: whatever
the callback then returns, the exit continues outward to the outermost
entry (`cHostCall`). The Rust crate maps it to `Error::Exit(status)`.

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

*As built (Phase 4):* the offset alone could not replay `%Z` or a date
table's `isdst`, so the zone effect is `local_zone` (kind 15), a byte
record: the offset east of UTC (`i32`, little-endian), a daylight-saving
byte, and the abbreviation (at most 64 bytes, cut to valid UTF-8 before
it is logged). The host owns the abbreviation's text: the tz database's
names on Linux and macOS, the full zone names on Windows, as the C
runtime's `%Z` gives them. A host with no `localZone` is in UTC, and so
is `os.date` with a `!` prefix, which logs nothing.

`os.date` asks for the zone once. `os.time(t)` reads the table's wall
time as C's `mktime` does: the offset at the wall time taken as UTC is a
guess, the offset at the instant that guess gives is the answer (exact
away from a change; at a gap or an overlap it picks one side, as glibc
does from a fresh process), and the zone at the result fills in the
normalized table, usually with no third lookup. These differ from
glibc's `mktime`, by choice:

- `isdst` that disagrees with the zone (say `isdst=true` in January):
  glibc steps a week at a time, up to about 7 years either way, for the
  nearest instant with the requested state and uses its offset; failing
  that it assumes daylight saving is one hour. Every step would be a
  logged effect here (up to ~760), so mahina probes every half year out
  to 7 years, nearest first, then makes the same one-hour assumption: at
  most 28 lookups, and the same answer in every case compared below.
- At an overlap, glibc's choice depends on the offset its previous
  `mktime` call found (a static cache), so the same table can give
  either answer within one process. mahina's depends only on the
  table.
- glibc applies a POSIX `TZ` rule only from 1970 (before that, every
  year uses 1970's transition instants); mahina applies it to every
  year, as tzcode does.
- The date table's fields are read raw, without `__index`.
- On Windows the zone is always the system's; `TZ` is not read.

Compared by hand (2026-10-24) with `lua5.4` on glibc: 420 `os.time`
round trips per zone (years 1950–2040, hours around the changes,
`isdst` true/false/absent), under 14 zoneinfo zones (Amsterdam, São
Paulo, UTC, Lord Howe, New York, London, Kolkata, Chatham, Santiago,
Dublin, Casablanca, Tehran, St John's, Moscow). The output is identical
except New York's 1996 overlap (glibc's cache, above). A POSIX
`CET-1CEST,…` rule also differs only in its 1950 rows (glibc's
1970-only rules, above). The unit tests in `src/interp_os_test.zig` pin
a subset of these results.

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

**Phase 3 measurements** (2026-10-24; best of 7, Linux x86-64,
ReleaseFast, tier-0; a 100 MB file of 1 M 100-byte ASCII lines, warm in
the page cache):

| Benchmark | mahina | `lua5.4` | LuaJIT | vs `lua5.4` |
|---|---|---|---|---|
| `io_lines` 1 M lines | 0.106 s | 0.096 s | 0.112 s | 1.11× |
| `io_read_all` text, 100 MB | 0.074 s | 0.065 s | 0.057 s | 1.14× |
| `io_read_all_bin` `rb`, 100 MB | 0.063 s | 0.064 s | 0.061 s | 0.98× |

Text `read("a")` first measured 0.100 s (1.6×): 69% of it was
`String.countCodepoints`, the scan every new string pays for its
code-point count and ASCII bit, running a byte at a time. Vectorised,
it no longer shows. The `--jit-native` times are the same: the loops
are host calls.

Record mode, `io_lines` with `--effect-log-limit 0`: the log is 1.05×
the bytes read (105 MB for 100 MB), and the time per line is flat,
462, 429 and 415 ns at 100 k, 300 k and 1 M lines (0.42 s at 1 M
against 0.11 s off), so it grows linearly. Peak memory at 1 M lines is
437 MB: the log keeps every line string alive until it is written.

**Phase 4 measurements** (2026-10-24; best of 7, Linux x86-64,
ReleaseFast): `bench/stdlib/os_date.lua`, 300 k iterations of one
`os.date` with eleven conversions and an `os.date("*t", os.time(t))`
round trip, `TZ=Europe/Amsterdam` (a TZif file):

| Benchmark | mahina | `lua5.4` | LuaJIT | vs `lua5.4` |
|---|---|---|---|---|
| `os_date` 300 k | 0.21 s | 0.51 s | 0.37 s | 0.41× |

The zone file is read once per VM and each lookup is a binary search
over its transitions. Record mode logs one 14-byte `local_zone` entry
per lookup, three per iteration here (0.34 s, 13 MB for 900 k entries).

**Phase 5 measurements** (2026-10-24; Linux x86-64, ReleaseFast): naming
the value costs every caught fault a backward scan and a walk over the
function's jumps. A `pcall` loop of a million nil calls from a
30-instruction function: 0.17 s before, 0.29 s after, `lua5.4` 0.37 s.
`bench/stdlib/pcall_faults.lua` (300 k mixed faults): mahina 0.10 s,
LuaJIT 0.31 s.

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

  *As built (Phase 5, Bart's choice 2026-10-24):* Phase 1 gave the
  visualiser's native runs the playground's groups (`clock,random`), so
  both engines see the same globals, and a program that calls `io.open`
  fails the same way in both; the effect log can never show the
  interface. So the VM's error says it: an "attempt to call a nil value"
  (or to index one) whose value would have come from a group the VM
  lacks names the member and the group, and the visualiser refuses the
  comparison when either run stopped on that error. The phrase is
  `Vm.missing_system_phrase`, matched by `missingSystemInterface` in
  `viz/src/diff.ts`.

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
