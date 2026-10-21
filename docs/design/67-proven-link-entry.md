# 67 — Proven-fact link entry: a linked child skips the checks its parent proved

Status: draft rev 2, not yet implemented. Bart answered Q1–Q4 (§9) on
2026-10-21. Round-1 review (codex, antigravity) is folded in (§10). Next: P0.
Owner: claude (coral-marten)
Last updated: 2026-10-21

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole phases to Done once everything inside them is checked.

### Done

- [x] **Sizing** (2026-10-21, §1). Unsound shadow builds measured the upper
  bound of each cost a linked continuation pays per hop. The numbers are in
  §1 and in `TODO.md` ("Continuation traces re-check a `for` step every
  run").
- [x] **Model choice** (2026-10-21). Bart picked the proven-fact link
  (option (b) of the TODO entry) over a static literal step and over Lua
  5.4's iteration count.
- [x] **Q1 — where the step and overflow guards run** (§4.2). Bart,
  2026-10-21: in the prologue on every trace.
- [x] **Q2 — v1 exclusions** (§7). Bart, 2026-10-21: as listed.
- [x] **Q3 — parent fact storage** (§5.3). Bart, 2026-10-21: the
  compile-time fact table.
- [x] **Q4 — review rounds.** Bart, 2026-10-21: codex and antigravity
  before P1.
- [x] **Round-1 review** (2026-10-21, `docs/reviews/doc67/*-r1.md`,
  summary in §10). Rev 2 fixes these:
  - one-shot `.invariant` slots are written back at the terminal, so
    facts transfer per exit (kill what the exit writes) instead of
    following slot class;
  - each exit kind gets one write-set description shared with its emitter;
  - facts have a formal identity, constant operands and one entailment rule;
  - one predicate decides hoisting everywhere it matters;
  - the fact table fails closed and has a budget;
  - proven stubs can be null, and the arm falls back;
  - identical republication reuses the decision.

### Outstanding

- [ ] **P0 — dry run** (§8). At every arm, build both fact sets, run the
  §6 test and count the result per arm kind. No behaviour change. This says
  how many arms the mechanism covers before any native code changes.
- [ ] **P1 — child side, proven targeting disabled** (§4). Entry facts on
  `CompiledTrace`, the `proven` label, the proven stubs, and the step and
  overflow guards checked in the prologue. No arm targets a proven entry
  yet. The hoisting already changes behaviour (exit identity and coverage
  when a step check fails), so P1 gets its own board run.
- [ ] **P2 — parent side** (§5). The exit write sets, shared with the
  emitters, and the per-exit fact table.
- [ ] **P3 — arm funnel** (§6). `arm` picks the proven stub when the parent
  exit proves the child's facts. Every consumer listed in §6 agrees with
  that choice. Counters in `--jit-stats`.
- [ ] **P4 — measurement** (§8). The board, against the §1 bounds.

## 1. Why this exists

When a native parent's exit is armed into a child, the jump lands in the
child's `ordinary_entry` or `linked_entry`. Both stubs fall into
`body_entry` (`nativegen.zig` ~3025–3042), which runs the whole prologue
(`nativegen.zig` ~879–1126):
- a tag compare for every input slot;
- a payload compare for every invariant doc 57 pin;
- the heap-structure checks on `.ptr`, `.func`, `.native` and string
  slots.

The child then runs its body guards, among them the step guards
`guard_step_up`/`guard_step_down` and the overflow guard `guard_for_nov`
of any enclosing `for_loop` the trace crosses. A loop root pays this once
per entry. A one-shot continuation pays it on every hop, and in a silent
cycle it hops once per outer iteration.

Measured 2026-10-21 (instruction counts, unsound shadow builds, outputs
identical):

| change (unsound) | nsieve | nsieve-bit-fp | scimark-fft | scimark-sparse | sieve_int |
|---|---|---|---|---|---|
| no step guard in `.continuation` recordings | −0.31% | −0.28% | −0.27% | −0.24% | −0.36% |
| + no `guard_for_nov` there | −0.49% | −0.78% | −0.63% | −1.11% | −0.55% |
| + no prologue tag checks anywhere | −2.25% | −2.61% | hangs | – | – |

The last row overstates the lever, because it also drops checks that a
dispatch entry needs (fft hangs without them). It also covers loop roots,
where the prologue runs once per entry and costs next to nothing. So the
bound for tag checks skipped on links alone is "up to about 2%". P0
measures the real share before any native code changes.

LuaJIT pays none of this on a side trace. A side trace starts from its
parent's snapshot. Its `SLOAD`s are `IRSLOAD_INHERIT`, so their types
come from the parent, and the FOR overflow checks are emitted only with
`init` set (`rec_for_check`, `lj_record.c` ~445). `init` is set in three
cases (`lj_record.c` ~2875, ~2903):
- FORI;
- a root that starts at FORL;
- a side trace that starts at a JFORI's exit.

It is never set for a FORL crossed later. Every entry from the interpreter
checks once, and everything reached from that entry through patched exits
inherits the result. A LuaJIT side trace is compiled for one parent exit.
A mahina continuation is anchored at a pc and entered from any exit that
resumes there, and from the dispatcher. So the inheritance has to be
decided per arm.

## 2. Goals

- A linked hop skips every slab-level entry check its parent exit proves
  statically.
- No check is ever skipped that the parent does not prove. A dispatcher
  entry, an unproven arm and an excluded arm keep today's full prologue.
- Arm decisions stay a pure function of the two committed artifacts, so
  tiering stays deterministic and replay-neutral.

## 3. Non-goals (v1)

- Heap-structure checks (`.ptr` table type, metatable, lane, grid;
  `.func` proto id; `.native`; string). A parent's own stores can widen a
  lane or set a metatable, so proving them needs effect analysis. They stay
  on the proven path, after the `proven` label.
- Seeded children, exit-side adapter arms, frame-motion arms (§7).
- Tier-1a. `irinterp` chains keep checking guards in the body.

## 4. Child side

### 4.1 Facts

A fact is a predicate on the slab (`tags[]`, `payloads[]`) that names no
trace-local ref, so two artifacts can compare it. An operand is either
`slot(s)` or `int(k)`, a 64-bit integer constant.

| fact | holds when |
|---|---|
| `tag(s, T)` | `tags[s] == T` |
| `pin(s, b)` | `payloads[s]` is boolean `b` (doc 57's canonical 0/1) |
| `step_up(s)` | `0 < step`, Lua 5.4's rule (`arith.forStepAscending`) |
| `step_down(s)` | the complement of `0 < step`: negative, zero and NaN |
| `nov(x, y)` | the int add `x + y` does not overflow |

The step facts cover int and float steps, read with the slot's tag.
Signed add overflow is commutative, so a `nov` operand pair is normalized:
- a slot comes before a constant;
- of two slots, the lower comes first.

Facts are ordered by `(kind, first operand, second operand, payload)`, and
equality is equality of all four.

A parent table may also hold `exact(s, v)`: the slot holds the known value
`v`, from a constant the exit writes (§5.2). A child never requires
`exact`. It exists for the one entailment rule in §6.

A child's entry facts are what its prologue checks:
- every [RV-1] tag row;
- every invariant pin;
- every hoisted guard (§4.2).

`lower` emits these checks as one contiguous block and binds `proven`
right after it, before `snapshotBoxedTags`. The page keeps its facts as a
sorted list, `CompiledTrace.entry_facts`. The list is optional. If
building it fails, the page has no proven stubs, so its requirements are
never mistaken for an empty list.

Two stubs mirror the existing ones:
- `linked_proven_entry` presets `linked_loop_done = 1`;
- `ordinary_proven_entry` presets `linked_loop_done = 0`.

Each then stores `entry_rbx` (the first thing `body_entry` does, line
~889) and jumps to `proven`. A page with a seed plan gets neither stub
(null), because its seed callout precedes the tag checks and writes the
slots they read. The checked stubs stay exactly as they are, so
`stubEnterability` (`trace_chain.zig` ~178) and every checked target
are unchanged.

### 4.2 Step and overflow guards in the prologue

Today these three guards are body guards (`nativegen.zig` ~1323–1350;
body exits in `opMayExitInBody`). With Q1, every trace checks them in
the prologue when one shared predicate admits them:

`entryGuardHoisted(t, kinds, alloc, i)` holds when instruction `i` is a
`guard_step_up`, `guard_step_down` or `guard_for_nov`, and every operand
is either an int constant or the `slot_load` of an `.invariant` slot. The
guard then reads the slot's entry value, which is what the prologue reads
from the slab. Any computed operand, an `int_of_float` limit or an
internal φ, keeps the guard in the body.

Every place that needs this decision calls the predicate:
- **Entry-fact construction.** The guard becomes a `step_*` or `nov`
  fact.
- **Prologue emission.** The check reads the slab payload and constant
  immediates directly, never a home: homes are not loaded yet, and the
  body emitters would read unloaded locations. An int step compares
  `qword [rsi+s*8]` against 0. A float step loads into `xmm0`; every XMM
  register is dead at `body_entry` (comment at ~906). `nov` does
  `mov rax, [rsi+x*8]; add rax, y; jo prologue_fail`.
- **Body suppression.** The guard emits nothing in the body.
- **`opMayExitInBody`.** It returns false for a hoisted guard. The
  predicate controls carried-home coalescing and precise-snapshot
  liveness (`nativegen_alloc.zig` ~883, ~1153), so a mismatch with the
  emitter would be unsound.

The guard's IR does not change, and neither does tier-1a, which keeps its
snapshot metadata. A native failure becomes an entry refusal
(`prologue_fail`: regs untouched, tier-0 runs from the anchor) instead of
a body exit. Both are correct, because tier-0 re-runs the same path. They
differ in exit identity and coverage when a check fails; doc 57 accepted
the same trade for pins. Precise-page tests compare the completed VM
behaviour, not intermediate snapshots. A hoisted guard has no native exit
stub (its `exit_labels` entry stays null). Anything that publishes native
arms or adapters from IR exit metadata must skip it. That includes the
materializing-exit republication at `trace_link.zig` ~3185. The
predicate's result is exposed per exit for those consumers.

## 5. Parent side

### 5.1 The transfer

`E(P)` is `P`'s entry facts. They hold at the start of every admitted
activation of `P` (§6). `W(e)` is the set of slots exit `e`'s
materialization writes, and `gen(e)` is the facts those writes establish
(§5.2). Then:

    F(P, e) = gen(e) ∪ { f ∈ E(P) : no slot f mentions is in W(e) }

This rests on one invariant, which P2 asserts in code and documents at
the emitter: **a native body writes the slab only in exit
materialization.** The review traced every path (codex, answer (1)):
- body ops keep values in homes;
- sunk `astore`/`hstore`/`ustore`/`gstore` write heap storage (`ustore`
  a verified closed cell);
- host calls are refused natively;
- body callouts do not collect;
- seeds run before the checks.

So a slot outside `W(e)` still holds its entry value at the jump, and
every entry fact about it still holds, whatever its allocation class.

Slot class is not the test. On a one-shot page, a slot that is both
loaded and stored is `.invariant` (`nativegen_alloc.zig` ~439): the
class describes the entry home. The `.link` terminal then writes it back
with the store's kind (`nativegen.zig` ~2225). Rev 1 inherited facts by
class, which kept `pin(s, true)` alive after the terminal wrote `false`.

### 5.2 Write sets, by exit kind

Each exit kind has one write-set description, `exitWrites`, which yields
`(slot, kind, source)` triples. Both the flush emitter and the fact
builder iterate it, so the two cannot drift. A write of static kind `k`
generates `tag(s, tagOf(k))`. A write whose source is a constant also
generates `exact(s, v)`. A `.boxed` write copies a tag snapshotted at
entry (`nativegen_emit.zig` ~479), so it generates nothing and still kills
facts about its slot.

| exit kind | `W(e)` | kind and source |
|---|---|---|
| ordinary deopt, sibling handoff, and the silent `.deopt` epilogue (`nativegen.zig` ~2985 duplicates the flush) | the carried homes | `s.kind`, or `steady_kind`, from the current home. Never `exact`: an early exit flushes the current home, not `store_ref` |
| `.link` terminal | every slot with `store_ref >= 0`, the one-shot `.invariant` writebacks included | `kinds[store_ref]`; `exact` when the store is a `konst` |
| `loop_done_linked` | the slot-bound φs except the visible loop variable `R[a+3]` (`nativegen_emit.zig` ~2536), which is not written and so not in `W(e)` | `kinds[p.b]` |
| region bridge | the carried homes, minus those the selected φ emissions overwrite, plus those φ emissions (`nativegen_emit.zig` ~2558, ~2589) | the final write's kind |

Sunk stores write heap, not slab, so they add nothing to `W(e)`. Peeled
and precise pages stay excluded at arm time, as today (`trace_link.zig`
~2242). A peeled exit skips its flush when local completion is zero, so
its write set is not static.

### 5.3 Storage

The fact table is built at compile time, while `kinds` and `alloc` are
alive. It covers only exits that have a native exit stub and an armable
shape:
- the `.link` terminal;
- the numeric-for loop-done guard;
- the bridge candidates;
- the ordinary exits that pass `exitIsPreEffect`.

Each exit's list is sorted, and all the lists live in one flat
allocation on `CompiledTrace`: offsets per exit, then the facts.

The size is computed with checked arithmetic before allocating:
- **Per exit**, at most `|E(P)| + |W(e)|` facts.
- **Each fact** is a fixed-size record of at most 32 bytes; P2 pins
  the size with a comptime assert.
- **The page budget** is 64 KiB, at least 2,000 facts. That is far above
  anything the current trace limits produce, so it only matters for an
  adversarial page.

Building fails closed. On overflow, over budget or OOM, the page carries
no table, proves nothing, and every arm out of it uses the checked stubs.
P2 adds an allocation-failure test, and a compile-time and memory
benchmark at the trace size limits (Rule #20).

## 6. Arm funnel

`publishValidatedLink` chooses the target at `trace_native_registry.zig`
~1045–1049. With this design:

```zig
const stub = if (kind == .link_terminal) child_c.linked_proven_entry else child_c.ordinary_proven_entry;
const use_proven = provenKind(kind) and stub != null and
    proves(parent_c.exitFacts(exit), child_c.entry_facts);
const target = if (use_proven) stub.? else switch (kind) {
    .link_terminal => child_c.linked_entry orelse return .declined,
    .region_bridge => child_c.ordinary_entry orelse @panic(...),
    else => child_c.ordinary_entry orelse return .declined,
};
```

`provenKind` admits `.link_terminal`, `.ordinary_guard`,
`.loop_done_linked`, `.region_bridge` and `.sibling_handoff`. `proves`
is false when either table is missing. Otherwise it holds when every child
fact `f` is either:
- in `F` after normalization (a merge of two sorted lists), or
- entailed by `exact` facts in `F`, the one entailment rule. Each slot `f`
  mentions has an `exact(s, v)` fact, and `f` evaluates true on those
  values. For example, `exact(s, 1)` entails `tag(s, TAG_INT)`,
  `step_up(s)` and `nov(slot(l), slot(s))` when `l` is exact too.

The link record stores `proven`: whether the proven stub was actually
written, not merely whether `proves` passed.

`proves` runs only when the relation is new or changed. The registry
already recognises an identical republication (`trace_native_registry.zig`
~1059, ~1073, ~1099). For the same parent artifact, exit and child
artifact, it reuses the recorded decision. P0 counts publication attempts
and changed arms separately, and P3 benchmarks repeated unchanged
publication with large fact lists.

Every consumer of a slot's target must agree with `link.proven`:
- **Silent promotion** (`trace_link.zig` ~1389–1397) recomputes the
  target and requires `slot == target`. It and the registry call one
  shared `linkTarget(kind, child, proven)`.
- **Identical re-arm and candidate invalidation**
  (`trace_native_registry.zig` ~1073, ~1102) compare the slot with the
  derived target. They keep `link.proven` in step on insert, replace and
  unchanged publication.
- **The rowless sibling path** (`nativegen.zig` ~2852–2893) jumps to the
  target staged from the slot at exit time and deliberately doesn't
  reread the slot. The staged address is the proven address, so nothing
  changes; P3 tests it.
- **Silent epilogues** continue through the same slot. The `.deopt` one
  duplicates the carried-home flush (`nativegen.zig` ~2985), and the other
  kinds materialize before their check. `exitWrites` describes both
  copies of each flush.
- **Unchanged:**
  - `hasArmedExitSide` (`trace.zig` ~1763) and exit-side arms (excluded);
  - disarm and retirement, which reset to `shared_exit`;
  - ordinary-arm detection, which tests against `shared_exit`
    (`trace_link.zig` ~590).

**Soundness, per page activation.** Take any activation of a page `P`.
- **Checked entry:** a dispatcher entry, a checked stub, or an excluded
  frame-motion edge, all of which reach `body_entry`. The prologue
  verified `E(P)`.
- **Proven stub:** the arm admitted it only if `E(P)` is proven by
  `F(parent, e)`, and that held at the jump, by the same argument one
  level up.

Either way `E(P)` holds when `P` starts. The body doesn't write the slab
(§5.1), and `e`'s materialization writes exactly `W(e)`. So `F(P, e)`
holds when `e` jumps. Between materialization and the jump only metadata
changes:
- the ledger row;
- `emitForcedYieldCheck`, which diverts to the runtime instead of
  entering the child;
- silent accounting;
- the rowless counter publish.

The heap-structure checks still run after `proven`. So every skipped check
would have passed.

**Determinism.** `entry_facts` and `F` are functions of the committed
IR and its compile. The arm choice is a function of those and of the arm
event, which is already deterministic. Nothing is serialized, so the
replay schema doesn't change.

## 7. v1 exclusions (Q2, as listed)

- **Seeded children.** No proven stubs (§4.1). A seeded parent can still
  prove facts: its checks run after its seed callout, so `E(P)` holds.
- **Exit-side adapter arms** (`.exit_side`). The adapter page writes
  snapshot slots, copies and constants between the parent exit and the
  child. Proving through it means a write set for the adapter. v1 targets
  `ordinary_entry`, as today.
- **Frame-motion arms** (`.call_head`, `.ret_cont`, the head self-push).
  They shift `rdi`/`rsi` by a frame, so slot numbers differ between the
  two sides. They keep the checked target. The page they enter is then
  checked, so it can still prove facts for its own outgoing arms.
- **Heap-structure checks** (§3).

## 8. Measurement and tests

**Budget.** Against the §1 bounds:
- nsieve-bit-fp, nsieve and scimark-sparse each at least −1% in
  instructions;
- no `@bench` row above +0.3%;
- hashgate 99/99.

P1's hoisting gets its own board run, since it changes behaviour before
any proven arm exists.

**Counters** in `--jit-stats`:
- P0: per arm kind, proven-eligible arms, arms, and publication attempts;
- P3: per arm kind, proven and checked arms.

**Tests.** All fixtures are unseeded, so the seeded exclusion can't mask
a failure. Each case asserts which child body actually ran, not only the
slot address. Each mechanism is mutation-checked separately: killing by
`W(e)`, each predicate comparison, `nov` normalization, and the
`exact` rule.

- **Selection.** A parent that proves every fact gets the proven stub.
  One that leaves a child slot unproven (a slot it never touches) keeps
  the checked stub.
- **Stale facts.** Each of these keeps the checked stub, or the child's
  check still runs:
  - a one-shot parent overwriting a checked tag at its `.link` terminal
    (float in, int out, as spectral's `a`);
  - a payload change with no tag change: `true` → `false`, a positive
    step → negative, and a limit that makes overflow possible;
  - an overwrite of either `nov` operand;
  - a `.boxed` writeback whose runtime tag changes.
- **Exit shapes.** An early carried-home exit against a completed φ
  writeback; `loop_done_linked` with the visible `R[a+3]`.
- **`nov` symmetry.** A parent proving `nov(l, s)` and a child checking
  the pair in the opposite order.
- **Chains.** Proven parent → proven child → proven grandchild, through
  reporting, promoted silent, and post-motion rowless sibling paths.
- **Still checked.** The heap-structure checks still refuse after a
  proven entry skips the slab checks.
- **Lifecycle.** Re-arm, disarm and retirement of a proven target; a
  child whose proven stub is null; a page whose fact table failed to
  build.
- **The forced-skip test.** A child entered by two parents, one proving a
  slot's tag and one leaving it a different type. Forcing every arm
  proven must give a wrong result or a crash.
- **Hoisting.** A continuation whose enclosing step changes sign between
  activations, and a limit at `math.maxinteger`, in every mode.
- **Silent promotion** still promotes a cycle whose links are proven.

## 9. Questions for Bart (answered 2026-10-21)

Answers: Q1 every trace; Q2 the exclusions as listed; Q3 the compile-time
table; Q4 both review rounds before P1.

- **Q1** (§4.2). Check the step and overflow guards in the prologue on
  every trace, or only on one-shot pages?
- **Q2** (§7). Are the v1 exclusions acceptable: seeded pages, exit-side
  adapter arms, frame-motion arms, heap-structure checks?
- **Q3** (§5.3). A compile-time fact table on each page, or `kinds` and
  `alloc` retained and `F` derived at arm time?
- **Q4.** Codex and antigravity review rounds before P1, as for doc 66?

## 10. Round-1 review summary

Full reviews: `docs/reviews/doc67/codex-r1.md`,
`docs/reviews/doc67/antigravity-r1.md`.

| finding | from | disposition |
|---|---|---|
| A one-shot `.invariant` slot is written back at the terminal, so class-based inheritance keeps stale facts | codex B1, antigravity B1 | accepted: the §5.1 transfer kills facts by `W(e)` |
| The silent `.deopt` epilogue skips the carried-home flush | antigravity B2 | rejected: `nativegen.zig` ~2979–2985 duplicates the flush out of line (codex answer (1) agrees) |
| Write sets per exit kind were too coarse: `R[a+3]` skipped, sunk stores hit heap, early exits flush current homes, bridge overwrites | codex S1, antigravity S3 | accepted: §5.2 table and the shared `exitWrites` |
| Fact identity, constant operands, `nov` order, entailment | codex S2, antigravity S5 | accepted: §4.1 and the §6 `exact` rule |
| One hoisting predicate for facts, prologue, body and `opMayExitInBody`; checks read the slab, not homes; float steps; native-exit vs IR metadata | codex S3, antigravity S7 and nit 1 | accepted: §4.2 |
| Tests miss wrongly kept facts | codex S4, antigravity S8 | accepted: §8 |
| Identical republication is frequent | codex S5 | accepted: decision reuse in §6 |
| Storage budget and failure behaviour | codex S6 | accepted: §5.3, fail closed |
| Store facts only for armable exits | antigravity S6 | accepted: §5.3 |
| A null proven stub must fall back; `proven` means written | antigravity S4 | accepted: §6 |
| P1 is not inert; `step_down` includes zero and NaN; the rowless path uses the staged target | codex nits | accepted: status list, §4.1, §6 |
| More target consumers: re-arm and invalidation compare against the target | codex answer (6) | accepted: §6 list |

## References

- `TODO.md`: "Continuation traces re-check a `for` step every run" (the
  measurements).
- LuaJIT `lj_record.c`: `rec_for_check` (~445), `rec_for_loop` (~479),
  the `init` callers in `lj_record_setup` (~2875, ~2903);
  `IRSLOAD_INHERIT`.
- Doc 17 (exit patching, entry stubs), doc 22 §B (seed prologue), doc 55
  §2d (silent sites), doc 56 (exit adapters), doc 57 (prologue pins,
  `pinHoisted`).
