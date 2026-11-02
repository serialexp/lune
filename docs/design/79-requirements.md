# 79 — Requirements on gothab.io for mahina — Design

Status: draft; the model is adopted from Gothab. A prototype of the Zig citation scheme and JUnit report works locally (Q1, Q2); CI upload and a reusable package are not done. No doc is converted yet.
Owner: Bart
Last updated: 2026-11-02

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole sections to Done once everything inside them is checked.

### Done

- [x] **Skill.** `.claude/skills/design-doc-to-requirements/SKILL.md`, pulled
  from the gothab repository and adapted to mahina (repository
  `serialexp/lune`, flat `docs/design/`, this doc as the progress record).
  Its trace-pass half is gated on Q1/Q2.

### Outstanding

- [x] **Q1 — how a Zig test cites a key.** Prototype: `[REQ-n.m]` tags in the
  test name (option A).
- [x] **Q2 (local half) — a JUnit report with the citations.** `tests/test_runner.zig`
  swaps each test's `func` for a per-index shim (option C) and writes one
  `<testcase>` per test to `<dir>/<pid>.frag` when `MAHINA_TEST_JUNIT_DIR` is
  set; `zig build test -Dtest-junit=<dir>` sets it on every test run and makes
  the runs uncached; `tools/junit-merge.py <dir>` joins the fragments.
  Checked: 2512 cases from the full suite, tags land in the `requirements`
  property. Not checked: that gothab.io ingests it (CI upload only).
- [ ] **Q2 (CI half).** Add the `-Dtest-junit` run, the merge and an
  `actions/test-results@v1` upload (`files:` the merged report) to
  `.gothab/workflows/ci.yml`'s unit-test job.
- [ ] **A shared package.** The runner code is mahina-specific (Linux
  syscalls, `junit_capacity` shims, our sharding). A reusable `verifies` for
  Zig would extract the shim, the tag parser and the JUnit writer into a
  module a project adds as its `test_runner`. Not started.
- [ ] **Prototype limits.** Linux only; at most 8192 tests per binary (a
  larger binary writes nothing and says so); a leak is detected by std after
  the shim returns, so it fails the build but not the case in the report; the
  8192 comptime shims are compiled into every test binary (compile cost not
  measured).
- [ ] **Conversion order.** Which docs, in which areas (§Converting).
- [ ] **Extraction + trace pass** per doc; progress is logged under
  §Conversion progress.
- [ ] **`design-doc` skill.** Once conversion is under way, new work is
  authored as requirements (as Gothab did in its Phase 8 step 6). Not
  changed yet.

## Why this exists

Mahina's design docs hold two kinds of statement: progress (checklists) and
behaviour (what the language, VM, JIT and tools must do). Only the second can
be checked, and nothing checks that a stated behaviour has a test. Gothab
already has a requirements tree with criteria, notes and per-commit
verification. Using it for mahina puts the behavioural statements in one place
with computed coverage ("these criteria have a passing test, these have
none") instead of prose that drifts.

## What is taken from Gothab

Source: `~/Projects/gothab/wiki/guides/requirements.md` (user model) and
`docs/design/requirements-traceability.md` (contract). Taken as is:

- **Tree.** Four levels fixed by the parent: area, epic, feature,
  requirement. Keys `REQ-n` per repository, never reused; criteria
  `REQ-n.m`. A requirement without criteria is verified by its own key.
- **Immutable criteria.** Changing one retires its key and creates a new one;
  every test citing the old key must be re-annotated. A requirement without
  criteria is replaced when its title or body changes.
- **Status.** Set by hand on requirements only (`draft`, `review`,
  `approved`, `implementing`, `done`); areas, epics and features derive it.
  Test results never change it.
- **Notes.** `rationale`, `goal`, `non-goal`, `decision`, `open-question`,
  `context`. Editing keeps the earlier text as a version.
- **Retire, not delete.** A retired key stays readable and reserved.
- **Traces are declared in tests, never linked by hand.** The link moves with
  the test and disappears with it.
- **Wire format.** A JUnit `<testcase>` carries
  `<property name="requirements" value="REQ-142.1,REQ-142.2"/>`
  (Xray's convention); several properties on one case are unioned; anything
  not matching `REQ-<n>` or `REQ-<n>.<m>` is reported as malformed.
- **Verification states** per criterion, in precedence: `failing`, `flaky`,
  `not_run`, `verified` (at least N clean passes, N per repository, default
  1), `under_verified`, `untraced`. Flaky never counts as verified. Skipped
  tests should still report their keys, so a criterion reads "not run"
  instead of losing its verifier.
- **Conversion table** (doc content to requirement content):

| Doc content | Becomes |
|---|---|
| Why this exists, problem statement | `rationale` note |
| Goals | `goal` note; behavioural goals also become criteria |
| Decisions, chosen and rejected alternatives | one `decision` note each |
| Non-goals | `non-goal` note |
| Open questions, deferred items | `open-question` note |
| Doc/code drift, perf findings, live-check plans | dated `context` note |
| Implementation-status checklists | nothing (progress) |

## What is not taken

- Gothab's producers (Rust `#[verifies]`, vitest, Playwright) and its CI
  wiring. Mahina is Zig.
- Issue linking and the Requirements page internals; they come with the
  service.
- Gothab's Phase 8 area list. Areas are created as docs are converted, from
  the doc's natural area (Bart's rule for Gothab, 2026-10-21; assumed to
  carry over, see Q3).

## Mahina-specific rules for criteria

- Observable behaviour: program output, error messages, exit codes, the
  bytecode or IR shape only when that shape is the contract (a serialized
  format, a CLI flag, an embedding API).
- No speed or memory claims; those are benchmarks (global Rule #22). A
  benchmark finding goes into a dated `context` note.
- The determinism and replay guarantees (docs 02, 04) are criteria where they
  are observable: byte-identical output across the eight modes, a replay
  reproducing a recorded run.
- Zig-stdlib or toolchain facts are not criteria (Rule Z-1 keeps them in the
  code and `.zig-version`).

## Q1 — citing a key from a Zig test

Zig tests have no attributes, so the key has to ride on something the test
runner can read. `builtin.test_functions` exposes each test's name, and
`tests/test_runner.zig` already filters that list for sharding.

- **A. A tag in the test name:** `test "[REQ-12.1] a closed upvalue keeps its value"`.
  The runner (or a post-processor of its output) splits tags from names. One
  line, visible in failure output, survives renames only if the tag is kept.
  Static, so skipped tests still report their keys. A test cannot be
  cited from a file other than the one it is in.
- **B. A registry file:** a Zig file mapping test names to keys. Rejected
  by the Gothab principle ("the link must live in the test code"): it rots
  when a test is renamed.
- **C. A `verifies` comptime marker** next to each test (`comptime
  verifies(...)`). Zig has no declaration-attached metadata for tests; it
  would need a registry built at comptime from `@src()`, and a skipped test
  would not run it.

Proposed: A.

## Q2 — getting citations into gothab.io

Gothab ingests JUnit XML uploaded by CI. Std's test runner prints text and
does not write JUnit. Options:

- **A. A mahina test runner that writes JUnit** (`MAHINA_TEST_JUNIT=<path>`),
  replacing the `std_runner.main` delegation with a loop over
  `builtin.test_functions` that records results and parses `[REQ-…]` tags.
  Costs: re-implementing what std's runner does (progress, leak detection,
  `fuzz`, skip handling, panics); sharding already lives here.
- **B. Parse std's runner output** in a post-processing step to JUnit.
  Cheap, but the output format is the churning stdlib surface (Rule Z-2) and
  per-test results with leaks or panics are awkward to recover.
- **C. Both halves in one wrapper:** keep delegating to std's runner for
  execution, wrap each `TestFn.func` in a shim (as sharding wraps the list)
  that records pass/fail/skip into a result file. No output parsing, no loop
  to maintain; panics and hangs kill the process, so a crashed shard is
  reported as one failed run.

Option C is the least code; to be confirmed against how std's runner invokes
`test_fn.func` in the pinned toolchain (Rule Z-1) before building.

## Q3 — areas

Mahina's natural areas, as a starting list (created as docs are converted,
not up front): *Language* (syntax, values, semantics, stdlib), *Runtime*
(VM, GC, memory, errors), *JIT* (tracing, native codegen, linking),
*Replay and visualiser* (snapshots, determinism, `mahina viz`), *Tooling*
(CLI, REPL, language server, process/shell). Whether implemented docs are
converted first (no `done/` directory exists here; the `Status:` header says)
is the conversion order, Q4.

## Conversion progress

One bullet per converted doc: its keys, criterion and note counts, trace-pass
result, drift found.

- **Doc 77, interrupting traced loops** (2026-11-02, serialexp/lune): area
  REQ-1 *Runtime*, epic REQ-2 *Interrupting running code*, feature REQ-3
  *Interrupting traced loops*, requirements REQ-4 (a runaway loop stops in
  every execution tier; 4 criteria) and REQ-5 (the VM is usable after an
  interrupt; 2 criteria). 16 notes on REQ-3 (1 rationale, 2 goals, 3
  non-goals, 4 decisions, 4 open questions, 4 context). All `draft`.
  Trace pass: all 6 criteria verified by `gt requirement verify` against a
  local report (17 of 33 interrupt-filtered cases cite a key). Two tests were
  strengthened so they prove what their criterion says (globals survive the
  interrupt; code after `pcall` does not run). The first verify run also
  caught a wrong test of mine (the interrupt was requested before the global
  was set). Drift: the doc names an `ExitReason.interrupted` and a dispatcher
  early arm that the code does not have (recorded as a `context` note). The
  tier-0 criterion (REQ-4.1) comes from the interrupt landed under doc 75 §4,
  which this doc builds on.
- **Doc 75, process spawning** (2026-11-02, serialexp/lune; spawning and
  `os` environment only): area REQ-6 *Tooling*, epic REQ-7 *Process
  spawning*, features REQ-8 `proc.run` (REQ-12..18), REQ-9 `proc.pipe`
  (REQ-19..21), REQ-10 `proc.spawn` (REQ-22..25), REQ-11 environment and
  working directory (REQ-26..27). 20 requirements, 46 criteria, all `draft`,
  15 notes on REQ-7 (1 rationale, 3 goals, 4 non-goals, 4 decisions, 2 open questions, 1 context).
  Trace pass: all 46 criteria verified by `gt requirement verify` against a
  local report. Three tests added to prove what criteria claim (poll returns
  the result once ended; signalled and timed-out jobs raise on wait; kill
  defaults to `TERM`). Same day, the REPL half: epic REQ-28 *The REPL and
  shell*, features REQ-29 session (REQ-32..36), REQ-30 shortcuts
  (REQ-37..41), REQ-31 line editor (REQ-42..46); 15 requirements, 33
  criteria, 8 notes on REQ-28, all verified locally (79 units across docs 75
  and 77). Not covered: Ctrl-C forwarding to children and VM-close
  termination (no test; context note on REQ-7), the REPL printing
  `interrupted`, portability (§7). `cd` translation test now also asserts
  the OLDPWD/PWD updates its criterion claims.
