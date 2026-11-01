# 75 — Process spawning, and mahina as a shell — Design

Status: partial — Phase 0a (`os.environ`) and Phase 0 (`proc.run` on Linux,
recorded and replayed) landed; pipelines, handles, the REPL and the other
platforms not yet. Review round 1 (Codex, Antigravity,
2026-10-30) folded in; one open question left (Q14b).
Owner: Bart
Last updated: 2026-10-30

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole phases to Done once everything inside them is checked.

### Done

- [x] **Q1 — recording rule** (§5): decided 2026-10-30 — in record mode, a
  spawn that cannot be recorded and replayed is a fatal error at the call.
  A recording never contains something unreplayable.
- [x] **Q2 — replay never spawns** (§5): decided 2026-10-30, following doc 65
  D2 — replay feeds back the logged result; the child does not run again.
- [x] **Q3 — failure policy** (§3.3): decided 2026-10-30 — a failed exit
  raises by default; `check = false` opts out. Refined by Q8.
- [x] **Q4 — `max_bytes` overflow** (§5.2): decided 2026-10-30 — a capture
  keeps the latest `max_bytes` bytes and drops the earlier ones.
- [x] **Q5 — environment** (§3.1): decided 2026-10-30 — a given `env` is
  the child's whole environment; an omitted `env` inherits the parent's,
  which is what a shell is expected to do.
- [x] **Q5b — listing the parent's environment** (§3.1): decided 2026-10-30
  — add `os.environ()`.
- [x] **Q6 — platforms** (§7): decided 2026-10-30 — macOS and Windows get
  `proc`; wasm does not, because exec makes no sense there.
- [x] **Q7 — captured output is byte arrays** (§3.2): decided 2026-10-30,
  following doc 65 D3 — strings are UTF-8 text; binary data is byte arrays.
  Callers wanting text use `string.decode`.
- [x] **Q8 — a failed exit raises a table** (§3.3): decided 2026-10-30.
- [x] **Q9 — `timeout` is part of `proc.run`** (§3.4): decided 2026-10-30 —
  without one, every user wraps spawns in their own coroutine watchdog.
- [x] **Q10 — phase order** (§Phasing): decided 2026-10-30 — macOS and
  Windows come after the REPL, unless a platform turns out to be easy.
- [x] **Q9b — default timeout** (§3.4): decided 2026-10-30 — unlimited.
- [x] **Q11 — handle teardown** (§5.3): decided 2026-10-30 — children still
  running when the VM closes are killed by default.
- [x] **Q12 — Ctrl-C** (§6): decided 2026-10-30 — the parent receives Ctrl-C
  and forwards it to the child. A terminal-owning `inherit`
  child in the REPL becomes the terminal's foreground group (§6, confirmed).
- [x] **Q13 — environment and cwd mutation** (§6): decided 2026-10-30 —
  `os.setenv` and `os.chdir`, plus REPL shortcuts for the two.
- [x] **Q14 — macOS floor** (§7): decided 2026-10-30 — 10.15; no legacy
  support.
- [x] **Phase 0a — `os.environ()` and the byte-record encoding** (§4).
  `EffectKind.environ` = 19, logged as one byte record (a count, then
  length-prefixed name/value pairs sorted by name, a name the host lists
  twice keeping its first value); the table is built from the record in every
  mode. `effect_format_version` 9. New `HostSystem.VTable.environ` (a visitor,
  so no host memory outlives the call); `RealSystem` lists the CLI's
  environment map, or libc's `environ` when embedded on POSIX. Variables that
  are not valid UTF-8, and names a `NAME=value` cannot carry, are left out. A
  malformed record on replay refuses it (`EffectKindMismatch`). Tests:
  `interp_os_test.zig`, `effectser.zig`, `host_system.zig`. Embedded Windows
  without a map lists nothing yet (Phase 6).

### Outstanding

- [x] **Phase 0 — `proc.run` on Linux, with record/replay.** Landed:
  `src/proc_host.zig` (spawn, poll pump, TERM→KILL), `src/stdlib/proc.zig`,
  `EffectKind.proc_run`=20, format v10. The parser has no call sugar
  (`f{...}`), so examples below that read `proc.run{...}` are written
  `proc.run({...})` today. The host runs each spawn on a private threadless
  `Io` over its own allocator, because libmahina's shared `Io` cannot
  allocate. Original scope: The call shape
  (§3.1), the result (§3.2), failure table (§3.3), `timeout` (§3.4), the
  concurrent pump (§3.5), one new `EffectKind` (`proc_run`), the recording
  rule and budget reservation (§5), a new `proc` host group (§7). Record and
  replay land in the same phase: a spawn that records nothing would have to
  be re-audited later. Inventory rows (Rule Z-5) for every new function;
  update doc 02's "Process spawning: forbid" row.
- [x] **Phase 1 — pipelines.** `proc.pipe` (§3.6). Landed: `proc_host.run` is
  the n-stage runner and `proc.run` its one-stage case; the `proc_run` record
  (format v11) holds every stage. Written `proc.pipe({{...}, {...}, ...})`
  until the parser has call sugar. Decisions made in the implementation:
  `r.code`/`r.signal` are the last stage's and `r.ok` is the pipefail verdict
  (a timeout leaves out `code`/`signal`); `stderr = "merge"` sends each stage's
  stderr down the pipe (`|&`); every stage is in one process group, so a
  timeout ends them all; all programs are found on `PATH` before the first
  starts; a pipeline has at most 64 stages; a stage table is just its argv.
- [x] **Phase 3 — `inherit`, handles, background jobs.** Non-recording mode
  only (§5): `inherit` stdio, `proc.spawn` returning a job (`pid`, `wait`,
  `poll`, `kill`). All fatal in record mode. Q11 and Q12 are decided (§5.3, §6).
  Landed: Ctrl-C forwarding to the children's group while a call waits
  (`proc_host.Interrupt`), the terminal's foreground group for a child that
  inherits stdin from a terminal, stdout/stderr flushed before an inheriting
  child writes, `Job` as the one runner (`run` = start + wait; `spawn` = start,
  then `advance` whenever the program looks), VM close terminates jobs
  (SIGTERM, 500 ms, SIGKILL). Decisions made in the implementation:
  - A job's `stdout`/`stderr` default to the parent's, not `capture`: nothing
    reads a background job's pipes between looks, so a captured one would stall
    on a full pipe. Captured streams are drained when the job is waited on or
    polled; a child that fills the pipe in between waits for that look.
  - `proc.spawn` takes one program (no background pipelines yet) and the same
    options as `proc.run`; `timeout` counts from the spawn and is enforced
    whenever the job is looked at (it cannot fire while the program never looks).
  - `job:kill(sig)` signals the group by name (`"TERM"` default, `"SIG"` prefix
    optional) and answers false, without signalling, once every program has been
    reaped (a reaped pid may be recycled).
  - A foreground child that stops (Ctrl-Z) is killed and reported as ended by
    the stopping signal: stopped-child handling is job control (Phase 5).
  - A job survives only in its host; a restored VM's job answers "the job is
    gone".
- [ ] **Phase 4 — the REPL.** Interactive loop: prompt, line editing,
  history, multi-line chunks, `cd`/env builtins on an authoritative host
  environment (§6). Never recordable. Depends on Phase 4a.
  - [x] Core loop (`src/repl.zig`, `src/lineedit.zig`; `mahina` with no
    script): own raw-mode editor (POSIX; decided 2026-11-01), history file
    (`$XDG_STATE_HOME/mahina/history`, else `~/.local/state/mahina/history`),
    cwd prompt, multi-line chunks (a parse error at the end of the input
    waits for more), expressions print their values (`__show`), runtime
    errors reported and the session goes on, piped stdin runs the same lines
    without prompts or editing. Shortcuts `cd`, `export`, `unset`, `exit`
    (keyword + whitespace, rest not starting with `= ( [ : ,`, and only while
    no global of that name exists) translate to `os.chdir`/`os.setenv` Lua;
    words support quotes, `\`, `~`, `$NAME`, `${NAME}`, `cd -`.
  - [x] Top-level `local`s persist between lines (decided 2026-11-01). Each
    line is compiled with `compiler.Options.repl`: the session's earlier locals
    are seeded into the resolver as func-0 locals (`resolve.resolveWith`,
    binding `i` = root upvalue `i`), and this line's own top-level `local`s
    (and `local function`s; not `<close>` ones, which close when their chunk
    ends) become further root upvalues instead of registers. `Vm.runLine` hands
    the root closure its cells (carried ones, fresh closed nil cells for new
    ones) and roots the closure in `host_refs`, so the cells survive GC; the
    session adopts the new cells after the run. A redeclaration is a new cell
    (older closures keep theirs), as in a script. Locals of blocks and loops stay
    in registers. Constant folding of `<const>` locals (doc 76 D8) must skip
    these root-level ones: they have no register to fold away.
  - [ ] Ctrl-C interrupts a running Lua line (needs a VM interrupt poll; a
    running child already gets it, §6). Today it ends the REPL.
  - [ ] Windows console and wasm: plain lines only until Phase 6.
- [ ] **Phase 5 — shell ergonomics.** Command-position sugar, globbing,
  completion (from the LSP symbol index), job control. Scope decided after
  Phase 4.
- [ ] **Phase 6 — macOS and Windows spawn backends** (§7). After the REPL
  (Q10), earlier if a platform is easy. Q14 is decided (macOS 10.15); Q14b is open.
- [x] **Phase 4a — `os.setenv`, `os.chdir`, `os.getcwd` and the owned
  host environment** (§6). Done: `RealSystem` keeps one environment map
  (`owned_env`, copied from the CLI's map or libc `environ` on the first
  `setenv`; `activeEnv()` is what `getenv`, `environ`, `proc.run` and
  `proc.spawn` then read) and `chdir` is a real process chdir, so relative
  file paths and the children's inherited cwd agree. Effects: `setenv` and
  `chdir` reuse `fs_mutate` (an `?ErrorClass` outcome; replay skips the
  mutation and feeds back the logged result), `getcwd` is the new kind 21
  (`string_or_fail`, effect format v12). All three are in the `env` group.
  `setenv` refuses an empty name, `=` or NUL in a name, and NUL in a value,
  before the host is asked; `nil` removes. `getcwd` raises when the host cannot
  say or the directory is not UTF-8. The REPL shortcuts (`cd`, `export`) are
  Phase 4, not here. `os.getcwd` was added so the prompt can read the
  directory (accepted 2026-10-30); further small host functions the REPL turns
  out to need may be added the same way.
- [ ] **Phase 6a — raise the macOS release floor to 10.15** in
  `tools/mahina-cli.sh` (currently 10.12 x86-64), with the Darwin backend.
- [ ] **Q14b — Windows `.bat`/`.cmd`.** Rejected with an error, or explicitly
  run through `cmd.exe` with different (shell) semantics (§7). Needs the Zig
  claim verified first.

## Why this exists

Bash is the thing most scripts end up in and the thing nobody enjoys:
strings instead of argv, silent failures, word splitting, `$?` instead of
values. mahina is a real language with tables, closures and errors, and
it already has a host library (doc 65) with `io` and `os`. What it lacks is
the one capability a shell is made of: running other programs.

Today `os.execute` and `io.popen` are `excluded` in
`docs/lua-stdlib-inventory.csv` because they are "nondeterministic and
unsandboxable". The effect log (docs 02, 65) already answers the first
half: every host input is logged in record mode and fed back in replay. This
doc adds spawning as one more effect, takes the argv-array shape instead of
shell strings, and sets the rules under which it stays replayable.

## Goals

- Run a program with an argv array (no shell parsing, no quoting bugs) and
  get a structured result.
- Keep determinism: a recorded session replays byte-identically, with the
  child never running again.
- Keep the VM core free of it: spawning is a `cli-binding` tier function
  (Rule Z-2), absent from an embedding host by default (doc 65 D4).
- Reach a usable interactive shell in a later phase, built on the same
  primitive.

## Non-goals (v1)

- Compatibility with bash/POSIX shell syntax. mahina is the language.
- Replaying interactive or streaming sessions (§5, §6).
- A sandbox. A spawned program has the privileges of the user.
- `os.execute` / `io.popen` compatibility. They stay excluded; `proc`
  replaces them with a different shape.

## 3. The spawn API

### 3.1 Call shape

```lua
local r = proc.run{
  "git", "log", "--oneline",       -- argv; argv[1] is looked up on PATH
  cwd    = "/home/bart/Projects/lune",
  env    = { LANG = "C", PATH = "/usr/bin" },  -- the child's WHOLE environment
  stdin  = "text to feed",         -- see below
  stdout = "capture",              -- "capture" | "null" | "inherit"
  stderr = "capture",              -- as stdout, plus "merge" (2>&1)
  max_bytes = 65536,               -- per captured stream
  timeout = 30,                    -- seconds (§3.4)
  check  = true,                   -- default; false = don't raise on failure
}
```

argv is an array of strings. There is no shell between mahina and the
program, so no quoting and no word splitting.

**Defaults.** `stdin` omitted: the child's stdin is empty and closed.
`stdout` and `stderr` omitted: `"capture"`. `max_bytes`: 64 KiB (proposed:
well under the default 1 MiB log cap, §5.2). `check`: `true`. `timeout`:
unlimited (Q9b). `cwd` omitted: the parent's. `env` omitted: the parent's.

**`stdin`** is exactly one of: a string (its UTF-8 bytes), a byte array,
`{file = path}`, or `{inherit = true}`. A string is always data; there is no
sentinel string, so no value is both data and a mode. `stdout`/`stderr`
modes are strings because they carry no data. A standalone `"pipe"` mode
does not exist in `proc.run`; streams only become pipes inside a pipeline
(§3.6) or a Phase 3 handle.

**Paths.** A relative `cwd` and a relative `stdin.file` resolve against the
**parent's** working directory, never against the child's `cwd`. A relative
`argv[1]` containing a slash, and relative `PATH` entries, resolve against
the child's `cwd`, as `exec` does after `chdir`. All of this resolution
happens on the host while the call is live; replay skips it (§5).

**Environment (Q5, decided).** If `env` is omitted, the child gets the
parent's environment unchanged, as a shell's children do. If `env` is given,
it is the child's entire environment and nothing else is passed down, so
inheriting plus changes is written explicitly. The lookup of `argv[1]` on
`PATH` uses the child's environment (the `PATH` in `env`, when given); a bare
name with no `PATH` in a given `env` is not found, and an absolute or `./`
path always works. The backend resolves the executable itself against that
environment: the pinned Zig spawn resolves against the *parent's* `PATH`, so
passing `env` through to it would run the wrong program (Rule Z-1; verified
in `std/process.zig` `SpawnOptions`: "that resolution always uses parent
environment"). Building a child environment from the
parent's is done in Lua with `os.environ()` (Q5b, decided):

```lua
local env = os.environ()          -- { PATH = "...", HOME = "...", ... }
env.GIT_PAGER = "cat"
proc.run{"git", "log", env = env}
```

`os.environ()` is a logged effect, one result per call, a table of name to
string (§4). An omitted `env` passes the host's environment down without a
Lua-visible read, so it adds no effect of its own; replay never spawns, so it
never needs the parent's environment at all. The child inherits only file
descriptors 0, 1 and 2; every other descriptor mahina holds (effect log,
trace files) is close-on-exec.

### 3.2 Result

Captured output is **byte arrays** (Q7, decided), not strings: process output
is arbitrary bytes, doc 65 D3 reserves strings for UTF-8 text, and
`string.decode(bytes)` turns a capture into a string when the caller wants
text (it errors on invalid UTF-8, deterministically).

| field | meaning |
|---|---|
| `code` | exit status, or `nil` if killed by a signal or timed out. Full width: a Windows `DWORD` status is kept whole, never truncated to a byte |
| `signal` | terminating signal as a canonical name string (`"SIGKILL"`), or `nil` |
| `stdout`, `stderr` | captured byte arrays, `nil` if not captured |
| `ok` | `code == 0` |
| `truncated` | `stdout` or `stderr` lost earlier bytes to `max_bytes` (Q4) |
| `timed_out` | the call hit `timeout` and the child was killed (§3.4) |

Signals are logged and returned as names, not numbers, because numbers differ
by platform (`SIGBUS` is 7 on x86 Linux, 10 on macOS); an unknown number
becomes `"SIG<n>"`.

A program that cannot be started (not found, not executable, `stdin.file`
unreadable) raises regardless of `check`, with the OS error class; it is not
a result with a code. That raise is built from a logged failure class, so
replay raises the same error anywhere.

### 3.3 Failure policy (Q3, Q8, decided)

A nonzero exit, death by a signal, or a timeout raises by default. The error
is a **table** (Q8), not a string:

```lua
local ok, e = pcall(proc.run, {"false"})
-- e = { kind = "exit",    code = 1,   stdout = {...}, stderr = {...}, truncated = false }
--   | { kind = "signal",  signal = "SIGSEGV", ... }
--   | { kind = "timeout", timed_out = true, ... }
```

It carries every field of the result plus `kind`, and has a `__tostring`
giving a one-line message so an uncaught error still prints readably. Raising
a table is new for host functions in mahina (the rest of the stdlib raises
located strings, `raiseLocatedError`); this doc adds the first. `check =
false` returns the result instead, and the caller tests `r.ok`. Start
failures (§3.2) are not suppressed by `check = false`.

Doc 65 §4.4 has a VM-wide `io_error_mode` (`--lua-io-errors`) for `io`/`os`
errors, which does not apply here: `proc` has its own explicit `check`, and a
nonzero exit is a result of a successful call, not an `io` failure. The two
conventions are separate on purpose.

Record and replay behave identically: the raise happens **after** the result
is logged or read back, so replay raises the same error at the same call. The
generic effect wrapper does not log natives that raise, so `proc.run` uses
the manual log-then-raise pattern.

### 3.4 Timeout

`timeout` is in seconds (a number). When it expires the call:

1. kills the child (a graceful signal, then a forced kill after a short
   grace period; `TerminateProcess` on Windows),
2. reaps it, and drains and closes the pipes,
3. returns or raises with `timed_out = true`, `code = nil`, and whatever
   output had been captured so far.

The timer is a host wall-clock measurement and the **outcome is the effect**:
only `timed_out`, the captured bytes and the status are logged, so replay
never times anything and never consults a clock. A program sees the same
result in every mode.

Killing only the direct child leaves descendants that may still hold the
capture pipes, so the timeout needs to kill a **process group** (POSIX) or job
object (Windows). That is the same mechanism Ctrl-C forwarding needs (§6): a child runs
in its own process group. With no `timeout` (the default, Q9b), the call waits for the child to exit **and** for
EOF on every captured stream, so a descendant that outlives its parent while
holding a pipe also blocks the call. That is the case a timeout exists for.

### 3.5 Pumping the pipes

The backend must service stdin, stdout and stderr **concurrently** (poll/epoll,
kqueue, overlapped I/O, or a thread per stream). Sequential handling
deadlocks: a child that fills stderr while the parent blocks reading stdout, or
a stdin larger than the pipe buffer written before any output is read. Stdin is
fed and then closed; a child closing stdin early (`EPIPE`) is not an error.
Captures keep a bounded ring of the latest `max_bytes` and keep draining, so
memory is bounded and the child never blocks on a full pipe. Zig's
`std.process.run` is not usable for this: it has no stdin, and raises
`StreamTooLong` at its limit rather than keeping the tail.

### 3.6 Pipelines

```lua
local r = proc.pipe{
  {"cat", "access.log"},
  {"grep", "ERROR"},
  {"wc", "-l"},
  timeout = 30,
}
```

`proc.pipe` connects each stage's stdout to the next stage's stdin and takes
the same options as `proc.run` for the pipeline as a whole. It is **one
effect**, one logged result. Every stage is started before any is waited on;
if a later stage fails to start, the earlier ones are killed and reaped and
the call raises the start failure.

- `r.stdout` is the final stage's stdout, a byte array. `r.stages[i]` holds
  each stage's `code`, `signal` and `stderr` (each stage's stderr is captured
  by default; `"null"` and `"merge"` apply to all stages; `inherit` is fatal
  in record mode like anywhere else).
- Failure follows `pipefail`: the pipeline fails if any stage failed, and the
  raised table describes the **rightmost** failing stage and includes
  `stages`. `r.code`/`r.ok` are the last stage's, unless `check = false`.
- A stage killed by `SIGPIPE` because a downstream stage closed its input
  early (`yes | head -n 1`) is **not** a failure.
- Recordability checks every stage, not just the last.

## 4. Effect kinds and the log encoding

Effects carry a single scalar, string or byte span (`effectlog.zig`
`Effect.Result`); `function.zig` documents that a native "is never both an
effect and multi-result". So neither a process result nor an environment table
is logged as a table. Each is logged as **one encoded byte record** in the
existing byte span, and rebuilt into fresh Lua values in **both** record and
replay mode, so the two modes cannot diverge:

- `proc_run` (new `EffectKind`, next free value; values are never renumbered):
  `status` (full width, with a signal/exit/timeout discriminant),
  `truncated`, `timed_out`, `stdout` length + bytes, `stderr` length + bytes
  (for a pipeline: the stages' records, in order). A start failure logs its
  error class instead. The arguments are program data and are not logged.
- `environ` (new `EffectKind`): the variable names and values as
  length-prefixed pairs, **sorted by name** at record time. Replay builds a
  fresh table inserting in log order, so allocation order and table iteration
  order are identical in every mode and no object identity is ever carried over.

Each record is validated on read; a malformed record is a refused replay, like
any other bad log. If the record needs fields the current schema lacks,
`effect_format_version` (now 8) is bumped. The encoded size counts exactly
against the doc 65 §4.5 cap.

## 5. Record and replay

Following doc 65 D1/D2: record logs the result; replay returns the Nth
logged result and **does not spawn**. It also skips everything host-dependent
before the spawn: path and `PATH` resolution, existence checks, and opening
`stdin.file`. Inherited `cwd` and environment need no logging of their own,
because the complete outcome is logged and the child never runs again.

**The recording rule (Q1, decided).** In record mode, a spawn that cannot be
recorded and replayed is fatal **at the call, before anything runs**. The
check depends only on the call's arguments and on the log's remaining budget,
both deterministic.

| recordable | fatal in record mode |
|---|---|
| `capture`, `null`, `merge` | `inherit` on any stream (including `stdin = {inherit = true}`) |
| string, byte-array or file stdin | a pty |
| pipelines whose stages are all recordable | `proc.spawn` (Phase 3 handles), unconditionally |

Handles are fatal unconditionally rather than "if never waited on": whether
a handle is ever waited on cannot be known at the call, so the rule could not
stay argument-only. Off mode (no recording) allows all of it.

### 5.1 Why the rule is on the spawn, not the log

The alternative — record what you can and mark the rest "unreplayable" —
yields recordings that look valid and fail late. Failing at the call keeps
the invariant simple: a recording that exists, replays.

### 5.2 Size and the budget reservation

Captured bytes go in the log, so they count against the doc 65 §4.5 cap
(`--effect-log-limit`, default 1 MiB), which stays fatal when exceeded: a
recording never drops an input. But the encoded size is unknown until the
child has run, and refusing afterwards would mean the child already changed
files. So, in record mode, **the call reserves its worst case up front**:
`2 × max_bytes` per captured stream-pair plus record overhead (per stage for
a pipeline). If the log's remaining budget is below that, the call is fatal
before anything runs, naming the cap and how to raise it. A
`max_bytes` default of 64 KiB keeps a normal session far from the cap. Replay
checks nothing.

`max_bytes` bounds one captured stream and is part of the call's semantics,
not a recording limit (Q4, decided): the stream is read to its end, the
child never blocks on a full pipe (§3.5), and the result keeps the **latest**
`max_bytes` bytes. `truncated` is true when earlier bytes were dropped, and
**it is logged** (the two captures `"abc"` and `"xabc"` at `max_bytes = 3`
are otherwise identical, and a program may branch on the flag). Because a
capture is a byte array, truncation splitting a UTF-8 sequence is harmless;
`string.decode` of such a tail reports it.

### 5.3 Concurrency and lifetimes

Phases 0–1 run each spawn to completion before returning, so spawns are
ordered by the program and the log needs no extra ordering. Every child is
reaped before the call returns, including on a start failure, an I/O error or
a timeout, so no zombies or leaked descriptors escape a failing call. Background
jobs (Phase 3) would make completion order an input; they are fatal in record
mode rather than logged. mahina has no GC finalizers (doc 02), so a handle that
is dropped unwaited is never reaped by the collector: children still running when
the VM closes are **killed** by default (Q11, decided; their process group, so
descendants go too), and handles track their own state so `kill` on an already-reaped
child cannot signal a recycled PID.

## 6. The REPL and the shell

The REPL is an interactive process: it reads a terminal, so it is never
recordable, and runs in off mode. Scripts it runs may be recorded
separately with `--record`.

Phase 4 scope: prompt, line editing, history file, multi-line chunk
detection, result printing, and builtins that must run in the shell's own
process (`cd`, `export`/env set, `exit`). Before Phase 3 and 4, job control
cannot wait for Phase 5: Ctrl-C routing, which process group owns the
terminal, stopped-child behaviour, and cleanup at shell exit are part of
those phases, because otherwise Ctrl-C kills the REPL along with its
child, or a stopped child strands a synchronous wait. Only the ergonomics
(sugar, globbing, completion) wait for Phase 5.

**Ctrl-C (Q12, decided).** The parent receives Ctrl-C and passes it on to the
child. A child runs in its own process group, so the terminal's Ctrl-C reaches
only mahina (the foreground group); mahina's SIGINT handler forwards `SIGINT`
to the child's group and keeps waiting, since the child may handle it. The
call then ends as any other signal death does: a result or table with `signal
= "SIGINT"`. The same group is what the timeout kills (§3.4) and what VM close
kills (§5.3). An `inherit` child in the REPL that needs the terminal (an editor) cannot sit
in a background group, or it is stopped on terminal I/O
(`SIGTTIN`/`SIGTTOU`). Such a child is made the terminal's foreground group
for its lifetime (confirmed 2026-10-30), and then the terminal delivers
Ctrl-C to it directly, so forwarding applies to captured children only.

`export` and `cd` change the environment and working directory that
`os.getenv`, `os.environ()` and an omitted `env` all read, so the CLI host
must own **one authoritative environment map and working directory**,
initialised from the process, and pass the map to the child explicitly
rather than relying on the OS's. Today the CLI host reads its initialisation
map separately (`host_system.zig`), so updating only one place gives stale reads
or stale children. The mutations are `os.setenv(name, value)` and `os.chdir(path)` (Q13,
decided; neither exists in real Lua; inventory rows added, `cli-binding`,
`not-started`), plus **REPL shortcuts** for the two, since they are done all
the time: a line starting with `cd <path>` or `export NAME=value` is
recognised as a shortcut for the corresponding call. The exact recognition
rule (keyword at line start, how it coexists with a Lua statement) is decided
with Phase 4 and shares its design with Phase 5's command sugar. Neither
function is recordable in the REPL, which is never recorded; in a recorded
script each returns its result through the log like `fs_mutate`.

## 7. Portability and the host seam

Spawning goes through the `HostSystem` vtable (doc 65 §5.1) like every other
host operation, so replay and embedding can supply their own. It is a **new
`proc` group** in `system.zig` `Group`, with its own vtable methods and its own
C API mask bit: enabling `files` or `env` does not enable it, and an embedding
host gets none by default (doc 65 D4). `os.environ()` stays in the `env`
group.

The Linux implementation is `fork`/`exec` via `std` (verify the pinned
toolchain's `std.process` API first — Rule Z-1; §3.1 and §3.5 already record
two things it gets wrong for us). macOS and Windows get the same `proc`
surface (Q6, decided; Phase 6):

- **macOS** uses `posix_spawn`, not `fork`, which is unsafe in a threaded
  runtime there. Q14 (decided): the release
  floor becomes macOS 10.15, which has the cwd spawn action; the release script
  moves from 10.12.
- **Windows** has no `fork`, takes a command line instead of an argv (the
  backend quotes argv for `CreateProcess` correctly), has no signals (`signal`
  is always `nil`; `kill` terminates), keeps the full `DWORD` exit status,
  resolves `argv[1]` with `PATHEXT`, and treats `PATH`/`Path` as one
  case-insensitive variable (a given `env` holding both is an error). A given
  `env` without `SystemRoot` may fail to start the child at all; that is
  reported, not patched. Review round 1 reports that Zig's backend runs
  `.bat`/`.cmd` through `cmd.exe` (`std/Io/Threaded.zig`; not yet verified
  here), which would contradict "no shell" (Q14b).
- The wasm VM (playground) gets no `proc` module, because exec makes no sense
  there.

## Phasing

See the checklist. Phase 0a comes first, since `env` is built from
`os.environ()` and it proves the byte-record encoding. Phase 0 then lands the
spawn and its record/replay together. The REPL (Phase 4) comes before the
macOS and Windows backends (Phase 6, Q10). Each phase lands behind
`just test`, `just hashgate` and `just embed-test`, and Phase 0 carries a
benchmark at the boundary that matters: a spawn that captures a few MiB of
output, to show the pump and ring buffer stay linear and bounded.

## Open questions for review

Q14b in the checklist above.

## References

- `docs/design/02-determinism.md` — the effect boundary (its "Process
  spawning: forbid" row changes with Phase 0).
- `docs/design/65-cli-host-library.md` — D1/D2/D3, §4.4 the error mode, §4.5
  the size cap, §5.1 `HostSystem`.
- `docs/design/06-strings-and-bytes.md` — byte arrays, `string.decode`.
- `docs/lua-stdlib-inventory.csv` — `os.execute`, `io.popen` (excluded),
  `os.environ` (not-started).
- `src/effectlog.zig`, `src/effectser.zig`, `src/function.zig`
  (`EffectKind`), `src/system.zig` (`Group`, `HostSystem`).
- Review round 1: Codex and Antigravity, 2026-10-30 (conversation only; no
  report files were written).
