---
name: design-doc-to-requirements
description: Convert a mahina Markdown design doc (docs/design/) into requirements on gothab.io (serialexp/lune) — an area/epic/feature/requirement subtree with acceptance criteria and reasoning notes, created through the `gt requirement` CLI — and then run the trace pass that maps tests to each criterion. Use whenever asked to "convert a doc to requirements", extract requirements from a design doc, or trace tests against REQ keys. The model comes from Gothab (see docs/design/79-requirements.md).
argument-hint: <design doc, e.g. 77-interrupt-poll-in-traces>
---

# Converting a design doc into requirements

Read `docs/design/79-requirements.md` first: it records the adopted model, the
open decisions (how a Zig test cites a key, how citations reach gothab.io) and
which docs are already converted under "Conversion progress". The model's
source is `~/Projects/gothab/wiki/guides/requirements.md` (levels, keys,
immutable criteria, notes, retire vs. delete).

The work has two halves, usually done as two requests:

1. **Extraction**: the subtree, criteria and notes on gothab.io. Everything
   lands as `draft`. Bart approves.
2. **Trace pass**: every criterion gets at least one test that cites it.
   Blocked until doc 79 Q1/Q2 are decided; until then do extraction only and
   report the coverage map in prose.

## 0. Pick the doc

- Docs whose `Status:` header says implemented come first: their behaviour
  exists, so a criterion can be checked against the code today. Then docs in
  progress. Parked or draft-only docs last.
- If Bart didn't name one, pick a self-contained doc (one subsystem, few
  hundred lines) and say which you picked and why.
- Don't edit, move or delete the Markdown doc. Converted docs stay as they
  are.

## 1. Read the doc, then read the code

Read the doc top to bottom. Then read the implementation and its tests. **A
criterion states what the code does (or must do), checked against the source,
not paraphrased from the doc.** Docs drift (mahina's CURRENT_TASK notes and
several docs carry corrections of earlier claims).

When doc and code disagree, record it as a dated `context` note ("Found
during conversion (YYYY-MM-DD)"). Write the criterion for the intended
behaviour only if the code meets it. If it doesn't, the trace pass will find
it (step 6). Don't change code during extraction.

Also pick up behaviour the code has but the doc never mentions, when it is
part of the same contract. Leave unrelated features of the same module out.

## 2. Place it in the tree

```sh
gt requirement list -R serialexp/lune
```

Levels are fixed: **area → epic → feature → requirement**, set by the parent.
Create each doc's area as it is converted, using the doc's natural area
(doc 79 Q3 has a starting list). Reuse an existing area or epic when the doc
fits under it.

Usually the doc becomes one **feature**. Its body is a short paragraph saying
what the feature does. Each coherent behaviour becomes a **requirement**
under it. Give each requirement a title that states the behaviour ("Ctrl-C
stops a runaway loop in every execution tier", not "Interrupts") and a
one-line body naming the scope.

## 3. Write the criteria

Criteria are **immutable**. Changing one retires its key and forces every
citing test to be re-annotated, so get the wording right before tests cite it.

- One checkable statement per criterion. A test must be able to prove it
  true or false.
- Observable behaviour, not implementation: program output, error messages,
  exit codes, what a serialized format contains, what a CLI flag does. Name
  an internal function only when it *is* the contract (the C API, a wire
  format, a CLI flag).
- Concrete values: "reports `interrupted`", "answers with exit code 130".
  Say which defaults can be configured, and how.
- Include the failure paths: rejected input changes nothing, a failed
  dependency degrades in the way the doc says.
- Determinism and replay guarantees are criteria where they are observable
  (byte-identical output across modes, a replay reproducing a recorded run).
- **No speed or memory claims.** Those belong in a benchmark (Rule #22). Put
  them in a `context` note.
- No toolchain or Zig-stdlib facts (Rule Z-1 keeps those in the code).
- No rollout or live checks. They go in an `open-question` or `context` note
  that points at TODO.md.
- No "should". Present tense: "A second Ctrl-C while a child runs reaches the
  child".

## 4. Map everything else to notes

| Doc content | Becomes |
|---|---|
| "Why this exists", problem statement | `rationale` note on the feature |
| Goals | `goal` note (behavioural goals also become criteria) |
| Decisions, chosen and rejected alternatives, review tiebreaks | one `decision` note each, with the rejected alternative |
| Non-goals | `non-goal` note |
| Open questions, outstanding items, deferred work | `open-question` note |
| Doc/code drift, live-verification plans, perf and benchmark findings | `context` note, dated |
| Implementation-status checklists | nothing. They are progress, not requirements |

Put notes on the node they explain, usually the feature. Give each a short
title that states the point.

## 5. Create it on gothab.io

```sh
R="-R serialexp/lune"       # zsh: expand with ${=R}; zsh does not word-split $R
gt requirement create ${=R} -t "Interrupts" -b "…"                  # area → prints "Created area REQ-1"
gt requirement create ${=R} -p REQ-1 -t "Runaway code" -b "…"       # epic
gt requirement create ${=R} -p REQ-2 -t "Traced loops" -b "…"       # feature
gt requirement create ${=R} -p REQ-3 -t "Ctrl-C stops a pure loop" -b "…"
gt requirement criterion add ${=R} REQ-4 "A requested interrupt stops a …"
gt requirement note add ${=R} REQ-3 --kind decision -t "Short title" -b "Body"
```

Keys come from the command output. They are allocated per repository and
never reused, so read them back instead of predicting them. Note kinds are
`rationale`, `goal`, `non-goal`, `decision`, `open-question`, `context`.
Finish with `gt requirement list` and `gt requirement export <feature>` to
check the result.

Leave everything `draft`. Approval is Bart's.

Report to Bart:
- the tree, with criterion counts;
- criteria that go beyond the doc;
- doc/code drift you found;
- a first coverage map: which criteria existing tests already prove, and
  which have none.

## 6. Trace pass: annotate and write tests

Blocked on doc 79 Q1 (the Zig citation syntax) and Q2 (how the report reaches
gothab.io). Once decided, the syntax is recorded in doc 79 and here.

Rules that hold regardless:

- **Cite only what the test proves.** If a test is close, strengthen it.
- **Test the shipped values.** Use the production constant, not a test-local
  copy of the number. Probe the boundary.
- **Don't re-implement the code in the test.**
- **Pick the highest layer where the behaviour shows**: a language-level
  test (source in, output out) before an internal-structure test.
- **No timing assertions** (Rule #22). Assert a countable proxy instead.
- **Tests are `zig build test`-green and leak-checked** (Rule Z-3, Z-4).
- **When the code doesn't meet a criterion, stop and ask Bart.** The options
  are to fix the code, or to replace the criterion with what the code does.
  Replacing retires the key. Don't quietly write a test for a narrower case.

Check that every key is cited before you finish (command per doc 79's
syntax), then run `just test`. Commit per CLAUDE.md with explicit paths
(`git commit --only`), e.g.
`test(<scope>): verify every criterion of the <feature> requirements`. List
in the body which tests were annotated and which are new. Check `git status`
on every file you touched for another agent's uncommitted changes first. A
whole-file commit would carry their work (Rule #13), so ask.

## 7. Record progress

Add a bullet under "Conversion progress" in
`docs/design/79-requirements.md`: the doc, its keys, its criterion and note
counts, the trace-pass result, and any drift found. Then bump `Last updated:`
there. Per the `design-doc` skill, add to the body; don't rewrite it.
