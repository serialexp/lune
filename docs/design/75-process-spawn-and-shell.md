# 75 — Process spawning, and mahina as a shell — Design

Status: draft, not yet implemented
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

### Outstanding

- [ ] **Phase 0 — the `proc` module, capture modes only.** `proc.run{argv,
  env, cwd, stdin, stdout, stderr}` returning a result object; `capture`,
  `null`, string/file stdin, `merge`. One new `EffectKind` (`proc_run`).
  Inventory rows (Rule Z-5) for every new function.
- [ ] **Phase 1 — record/replay for `proc.run`.** Log
  `(code, signal, stdout bytes, stderr bytes)`; fatal on unrecordable
  arguments (§5); `max_bytes` on captures; the doc 65 §4.5 cap applies.
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
- [ ] **Q3 — failure policy.** Does a nonzero exit raise, or return? Default
  and the `check=` option (§3.3).
- [ ] **Q4 — `max_bytes` overflow.** Fatal in both modes, or truncate when
  not recording (§5.2).
- [ ] **Q5 — environment.** Is `env` a full replacement or a delta over the
  parent's? Which `getenv` effects does a spawn imply (§3.1)?
- [ ] **Q6 — non-Linux hosts.** Which spawn primitives on macOS and Windows
  (six release platforms, `tools/mahina-cli.sh`), and whether wasm gets any
  (§7).

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
  env    = { LANG = "C" },         -- see Q5
  stdin  = "text to feed",         -- string | {file = path} | "null"
  stdout = "capture",              -- "capture" | "null" | "inherit" | "pipe"
  stderr = "capture",              -- as stdout, plus "merge" (2>&1)
  max_bytes = 1 << 20,             -- per captured stream
  check  = false,                  -- raise on nonzero exit (Q3)
}
```

argv is an array of strings. There is no shell between mahina and the
program, so no quoting and no word splitting.

### 3.2 Result

| field | meaning |
|---|---|
| `code` | exit status, or `nil` if killed by a signal |
| `signal` | terminating signal number, or `nil` |
| `stdout`, `stderr` | captured bytes as a string, `nil` if not captured |
| `ok` | `code == 0` |

A program that cannot be started (not found, not executable) raises, with
the OS error class. It is not a result with a code.

### 3.3 Failure policy (Q3)

Open. Options: (a) never raise on exit status, callers test `r.ok`;
(b) raise by default, `check=false` to opt out; (c) a separate
`proc.check{...}` that raises. Bash ignores failure by default, which is a
large part of the complaint, so this default is worth deciding on purpose.

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
(`--effect-log-limit`, default 1 MiB). `max_bytes` bounds one stream
independently. Overflow is fatal in record mode, because a recording never
drops an input. Outside record mode: Q4.

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
`std.process` API first — Rule Z-1). Other platforms: Q6. The wasm VM
(playground) gets no `proc` module.

## Phasing

See the checklist. Phase 0 and 1 land together, since a spawn that records
nothing would have to be re-audited later. Each phase lands behind
`just test`, `just hashgate` and `just embed-test`.

## Open questions for review

Q3–Q6 in the checklist above.

## References

- `docs/design/02-determinism.md` — the effect boundary.
- `docs/design/65-cli-host-library.md` — D1/D2, §4.5 the size cap, §5.1
  `HostSystem`.
- `docs/lua-stdlib-inventory.csv` — `os.execute`, `io.popen` (excluded).
- `src/effectlog.zig`, `src/effectser.zig`, `src/function.zig`
  (`EffectKind`).
