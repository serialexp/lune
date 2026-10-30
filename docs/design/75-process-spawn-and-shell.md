# 75 — Process spawning, and mahina as a shell — Design

Status: draft, not yet implemented (every design question decided 2026-10-30)
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
- [x] **Q3 — failure policy** (§3.3): decided 2026-10-30 — a nonzero exit
  or a fatal signal raises by default; `check = false` opts out.
- [x] **Q4 — `max_bytes` overflow** (§5.2): decided 2026-10-30 — a capture
  keeps the latest `max_bytes` bytes and drops the earlier ones.
- [x] **Q5 — environment** (§3.1): decided 2026-10-30 — a given `env` is
  the child's whole environment; an omitted `env` inherits the parent's,
  which is what a shell is expected to do.
- [x] **Q5b — listing the parent's environment** (§3.1): decided 2026-10-30
  — add `os.environ()`.
- [x] **Q6 — platforms** (§7): decided 2026-10-30 — macOS and Windows get
  `proc`; wasm does not, because exec makes no sense there.

### Outstanding

- [ ] **Phase 0 — the `proc` module, capture modes only.** `proc.run{argv,
  env, cwd, stdin, stdout, stderr}` returning a result object; `capture`,
  `null`, string/file stdin, `merge`. One new `EffectKind` (`proc_run`).
  Inventory rows (Rule Z-5) for every new function.
- [ ] **Phase 1 — record/replay for `proc.run`.** Log
  `(code, signal, stdout bytes, stderr bytes)`; fatal on unrecordable
  arguments (§5); `max_bytes` keeps the latest bytes; the doc 65 §4.5 cap applies.
- [ ] **Phase 2 — pipelines.** `proc.pipe{a, b, ...}` runs spawns connected
  stdout→stdin; the final stage is captured; intermediate bytes are not
  logged.
- [ ] **Phase 3 — `inherit`, handles, background jobs.** Non-recording mode
  only: `inherit` stdio, `proc.spawn` returning a handle (`pid`, `wait`,
  `kill`). All fatal in record mode.
- [ ] **Phase 4 — the REPL.** Interactive loop: prompt, line editing,
  history, multi-line chunks, `cd`/env builtins. Never recordable (§6).
- [ ] **Phase 5 — shell ergonomics.** Command-position sugar, globbing,
  completion (from the LSP symbol index), job control. Scope decided after
  Phase 4.
- [ ] **Phase 0a — `os.environ()`.** Returns a table of the parent's
  variables (§3.1). New `EffectKind` (`environ`), logged as one result per
  call like `getenv`; inventory row (`os`, `cli-binding`) in the same change.
  Lands before `proc` so `env` can be built from it.
- [ ] **Phase 6 — macOS and Windows spawn backends** (§7). The same `proc`
  surface on the other release platforms of `tools/mahina-cli.sh`; behaviour
  differences (signals, `PATH` lookup, argv quoting on Windows) pinned by
  tests per platform.

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
  stdin  = "text to feed",         -- string | {file = path} | "null"
  stdout = "capture",              -- "capture" | "null" | "inherit" | "pipe"
  stderr = "capture",              -- as stdout, plus "merge" (2>&1)
  max_bytes = 1 << 20,             -- per captured stream
  check  = true,                   -- default; false = don't raise on nonzero exit
}
```

argv is an array of strings. There is no shell between mahina and the
program, so no quoting and no word splitting.

**Environment (Q5, decided).** If `env` is omitted, the child gets the
parent's environment unchanged, as a shell's children do. If `env` is given,
it is the child's entire environment and nothing else is passed down, so
inheriting plus changes is written explicitly. The lookup of
`argv[1]` on `PATH` uses the child's environment (the `PATH` in `env`, when
given); a bare name with no `PATH` in a given `env` is not found, and an
absolute or `./` path always works. Building a child environment from the
parent's is done in Lua with `os.environ()` (Q5b, decided):

```lua
local env = os.environ()          -- { PATH = "...", HOME = "...", ... }
env.GIT_PAGER = "cat"
proc.run{"git", "log", env = env}
```

`os.environ()` is a logged `getenv`-style effect, one result per call: a
table of name to string. An omitted `env` passes the parent's environment
down without a Lua-visible read, so it adds no effect of its own; replay
never spawns, so it never needs the parent's environment at all.

### 3.2 Result

| field | meaning |
|---|---|
| `code` | exit status, or `nil` if killed by a signal |
| `signal` | terminating signal number, or `nil` |
| `stdout`, `stderr` | captured bytes as a string, `nil` if not captured |
| `ok` | `code == 0` |
| `truncated` | `stdout` or `stderr` lost earlier bytes to `max_bytes` (Q4) |

A program that cannot be started (not found, not executable) raises, with
the OS error class. It is not a result with a code.

### 3.3 Failure policy (Q3, decided)

A nonzero exit, or death by a signal, raises by default. The error carries
the result (`code`, `signal`, captured `stdout`/`stderr`) so a `pcall`
handler can read it. `check = false` returns the result instead and the
caller tests `r.ok`. Record and replay behave identically: the raise
happens after the result is logged or read back, so replay raises the same
error at the same call.

## 4. Effect kind

One new `EffectKind` (`proc_run`, next free value; values are never
renumbered). Like the doc 65 operations it logs only its result — the
arguments are program data. Logged: `code`, `signal`, and each captured
stream as inline bytes (as `getenv` and `file_read` already carry strings).
A failure to start logs its error class.

## 5. Record and replay

Following doc 65 D1/D2: record logs the result; replay returns the Nth
logged result and **does not spawn**.

**The recording rule (Q1, decided).** In record mode, a spawn that cannot be
recorded and replayed is fatal at the call, before anything runs. The check
depends only on the arguments, so it is deterministic and the failure points
at its cause.

| recordable | fatal in record mode |
|---|---|
| `capture`, `null`, `merge` | `inherit` on any stream |
| string or file stdin | a pty |
| pipelines whose final stage is captured | a handle that outlives the script, or is never waited on |

Off mode (no recording) allows all of it.

### 5.1 Why the rule is on the spawn, not the log

The alternative — record what you can and mark the rest "unreplayable" —
yields recordings that look valid and fail late. Failing at the call keeps
the invariant simple: a recording that exists, replays.

### 5.2 Size

Captured bytes go in the log, so they count against the doc 65 §4.5 cap
(`--effect-log-limit`, default 1 MiB), which stays fatal when exceeded: a
recording never drops an input.

`max_bytes` bounds one captured stream and is part of the call's semantics,
not a recording limit (Q4, decided): the stream is read to its end, the
child never blocks on a full pipe, and the result keeps the **latest**
`max_bytes` bytes. `r.truncated` is true when earlier bytes were dropped.
Because the program sees the same truncated string in every mode, record,
replay and off agree; what the log stores is what the program was given.
Truncation is by bytes, so it can split a UTF-8 sequence at the front of the
kept tail (doc 06: the string is the raw bytes; callers that need text
validate it).

### 5.3 Concurrency

Phases 0–2 run each spawn to completion before returning, so spawns are
ordered by the program and the log needs no extra ordering. Background jobs
(Phase 3) would make completion order an input; they are fatal in record
mode rather than logged.

## 6. The REPL and the shell

The REPL is an interactive process: it reads a terminal, so it is never
recordable, and runs in off mode. Scripts it runs may be recorded
separately with `--record`.

Phase 4 scope: prompt, line editing, history file, multi-line chunk
detection, result printing, and builtins that must run in the shell's own
process (`cd`, `export`/env set, `exit`). Phase 5 (ergonomics) is decided
after Phase 4 has been used.

## 7. Portability and the host seam

Spawning goes through the `HostSystem` vtable (doc 65 §5.1) like every other
host operation, so replay and embedding can supply their own. The Linux
implementation is `fork`/`exec` via `std` (verify the pinned toolchain's
`std.process` API first — Rule Z-1). macOS and Windows get the same
`proc` surface (Q6, decided; Phase 6). Windows differs enough to need its own
backend: no `fork`, a command line instead of an argv (so the backend must
quote argv for `CreateProcess` correctly), and no signals (`signal` is
always `nil`; `kill` terminates). The wasm VM (playground) gets no `proc`
module, because exec makes no sense there.

## Phasing

See the checklist. Phase 0 and 1 land together, since a spawn that records
nothing would have to be re-audited later. Each phase lands behind
`just test`, `just hashgate` and `just embed-test`.

## Open questions for review

None: every question in the checklist is decided.

## References

- `docs/design/02-determinism.md` — the effect boundary.
- `docs/design/65-cli-host-library.md` — D1/D2, §4.5 the size cap, §5.1
  `HostSystem`.
- `docs/lua-stdlib-inventory.csv` — `os.execute`, `io.popen` (excluded).
- `src/effectlog.zig`, `src/effectser.zig`, `src/function.zig`
  (`EffectKind`).
