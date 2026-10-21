# 67 — Proven-fact link entry: a linked child skips the checks its parent proved

Status: draft rev 1, not yet implemented. Bart answered Q1–Q4 (§9) on
2026-10-21; round-1 review (codex, antigravity) is next.
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
- [x] **Q3 — parent fact storage** (§5.2). Bart, 2026-10-21: the
  compile-time fact table.
- [x] **Q4 — review rounds.** Bart, 2026-10-21: codex and antigravity
  before P1.

### Outstanding

- [ ] **Round-1 review** (codex, antigravity), findings folded into rev 2.
- [ ] **P0 — dry run** (§8). At every arm, compute whether the parent exit
  proves the child's entry facts, and count it. No behaviour change. This
  says how many arms the mechanism covers before any native code changes.
- [ ] **P1 — child side** (§4). Entry facts on `CompiledTrace`, the
  `proven` label after the checks, proven twins of `linked_entry` and
  `ordinary_entry`, step and overflow guards on invariant slots checked in
  the prologue. Inert: no arm targets a proven entry yet.
- [ ] **P2 — parent side** (§5). The per-exit proven-fact table.
- [ ] **P3 — arm funnel** (§6). `arm` picks the proven twin when the
  parent exit proves the child's facts. Silent promotion and the rowless
  path accept it. Counters in `--jit-stats`.
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
`init` set (`rec_for_check`, `lj_record.c` ~445). `init` is set for FORI
and for a root that starts at FORL (`rec_for_loop(..., 1)` in
`lj_record_setup`), never for a FORL crossed later. Every entry from the
interpreter checks once, and everything reached from that entry through
patched exits inherits the result. mahina's continuations have no parent
in that sense: they are anchored at a pc and entered from any exit that
resumes there, and from the dispatcher. So the inheritance has to be per
arm.

## 2. Goals

- A linked hop skips every entry check its parent exit proves statically.
- No check is ever skipped that the parent does not prove. A dispatcher
  entry and an unproven arm keep today's full prologue.
- Arm decisions stay a pure function of the two committed artifacts, so
  tiering stays deterministic and replay-neutral.

## 3. Non-goals (v1)

- Heap-structure checks (`.ptr` table type, metatable, lane, grid;
  `.func` proto id; `.native`; string). A parent's own stores can widen a
  lane or set a metatable, so proving them needs effect analysis. They stay
  on the proven path, after the `proven` label.
- Seeded pages, exit-side adapter arms, frame-motion arms (§7).
- Tier-1a. `irinterp` chains keep checking guards in the body.

## 4. Child side

### 4.1 Entry facts and the `proven` label

An entry fact is a statement about the slab at entry that the prologue
checks. It reads only `tags[]` and `payloads[]`:
- `tag(s, T)`: `tags[s] == T`, one per [RV-1] row.
- `pin(s, v)`: `payloads[s] == v` for an invariant doc 57 pin.
- `step_up(s)` / `step_down(s)`: the sign of an invariant step slot (§4.2).
- `nov(l, s)`: `payloads[l] + payloads[s]` does not overflow, for
  invariant int slots or a constant on one side (§4.2).

`lower` emits the fact checks as one contiguous block: the [RV-1] loop
plus the §4.2 checks. It binds `proven` right after that block, before
`snapshotBoxedTags`. The page keeps the facts as a sorted list,
`CompiledTrace.entry_facts`.

Two new stubs mirror the existing ones:
- `linked_proven_entry` presets `linked_loop_done = 1`.
- `ordinary_proven_entry` presets `linked_loop_done = 0`.

Each then stores `entry_rbx` (the first thing `body_entry` does, line
~889) and jumps to `proven`. A page with a seed plan gets neither stub
(null), because its seed callout precedes the tag checks and writes the
slots they read.

### 4.2 Step and overflow guards in the prologue

Today these three guards are body guards (`nativegen.zig` ~1323–1350;
body exits in `opMayExitInBody`). To make them skippable, a guard whose
operands are invariant slot loads (or a constant, for `guard_for_nov`)
is checked in the prologue instead and emits nothing in the body. This is
the doc 57 `pinHoisted` pattern.

The guard's IR does not change, and neither does tier-1a. A native
failure becomes an entry refusal (`prologue_fail`: regs untouched, tier-0
runs from the anchor) instead of a body exit. Both are correct, because
tier-0 re-runs the same path. They differ only in coverage when the
check fails. Doc 57 accepted the same trade for pins. A `guard_for_nov`
whose limit goes through `int_of_float` is not a plain load and stays in
the body.

Q1 asks whether this applies to every trace or only to one-shot pages.
On a loop root, LICM already runs these guards once per entry, so moving
them costs nothing and keeps one rule. On a root, though, a failure today
can grow a side trace off the guard's exit, and an entry refusal cannot.

## 5. Parent side

### 5.1 What an exit proves

For an armed exit `e` of parent `P`, the proven facts `F(P, e)` are the
union of three sets:
1. **Flushed slots.** Every slot the exit path writes with a statically
   known kind gives `tag(s, tagOf(kind))`. Which slots, by exit path
   (survey 2026-10-21):
   - ordinary and sibling exits: the carried homes, from `s.kind` or
     `steady_kind`;
   - `.link` terminal: the stores, from `kinds[store_ref]`;
   - `loop_done_linked`: the sunk stores and slot φs;
   - region bridge: the carried homes and the bridge φs.
   A slot flushed from a `konst` also proves the constant's payload, and
   with it `step_*` and `nov` facts that hold for that payload.
2. **Untouched checked slots.** A slot of class `.invariant` in `P` keeps
   its entry value at every exit, because nothing in `P` writes it.
   Whatever `P`'s own entry facts say about it still holds: its tag, its
   pin, and its hoisted `step_*`/`nov` facts.
3. Nothing else. A `write_only` slot holds its entry value until the
   first back-edge, so its tag is unknown at an early exit. `.boxed`,
   `.none` and unchecked slots are unknown too.

### 5.2 Storage

P2 builds `F(P, e)` at compile time, while `kinds` and `alloc` are
alive, for every exit that can be armed. Each list is sorted by slot and
kept on `CompiledTrace` in one flat layout: offsets per exit, then all
facts. That is at most `exits × slots` small records per page, allocated
once per compile. The alternative (Q3) retains `kinds` and the slot table
on the page and derives `F` at arm time. That keeps less per page, but it
puts the derivation in the arm path and makes the alloc structures part
of the page's lifetime.

## 6. Arm funnel

`publishValidatedLink` chooses the target at `trace_native_registry.zig`
~1045–1049. With this design:
- `.link_terminal` takes `linked_proven_entry` when
  `child.entry_facts ⊆ F(parent, exit)`, else `linked_entry`.
- `.ordinary_guard`, `.loop_done_linked`, `.region_bridge` and
  `.sibling_handoff` take `ordinary_proven_entry` or `ordinary_entry` by
  the same test.

The subset test is a merge of two sorted lists. Arms are rare, so it is
not on a hot path. The link record keeps the decision as `proven: bool`.

These consumers re-derive or reuse the target and must agree with it:
- **Silent promotion** (`trace_link.zig` ~1389–1397) recomputes the
  target and requires `slot == target`. It reads `link.proven`, so that
  check stays exact. Both sites call one shared `linkTarget(kind, child,
  proven)`.
- **The rowless sibling path** (`nativegen.zig` ~2852–2893) jumps to the
  staged exit target. P3 checks that it is read from the slot, so it
  follows the proven address unchanged.
- **Silent epilogues** continue through the same per-exit slot. P3 checks
  that each one flushes the same slots as the exit path its facts were
  computed from.

**Soundness, by induction over a native episode.** An episode starts at a
dispatcher entry, which runs the full prologue, so `P`'s entry facts hold
there. A proven hop into `P` holds them too, because its parent exit
proved them. Inside `P`, invariant slots are not written, so their entry
facts hold at every exit, and flushed slots hold the kinds the exit
wrote. Between the exit and the child's first instruction no code runs
except the exit stub itself (the ledger row, `emitForcedYieldCheck`, the
slot jump). The heap-structure checks still run after `proven`. So
`F(P, e)` is true whenever the jump happens, and the skipped checks would
have passed.

**Determinism.** `entry_facts` and `F` are functions of the committed
IR and its compile. The arm choice is a function of those and of the arm
event, which is already deterministic. Nothing is serialized, so the
replay schema doesn't change.

## 7. v1 exclusions (Q2)

- **Seeded pages.** No proven stubs (§4.1).
- **Exit-side adapter arms** (`.exit_side`). The adapter page writes
  snapshot slots, copies and constants between the parent exit and the
  child. Proving through it means computing `F` over the adapter's writes.
  v1 targets `ordinary_entry` as today.
- **Frame-motion arms** (`.call_head`, `.ret_cont`, the head self-push).
  They shift `rdi`/`rsi` by a frame, so slot numbers differ between the
  two sides. v1 keeps them on the full prologue.
- **Heap-structure checks** (§3).

## 8. Measurement and tests

**Budget.** Against the §1 bounds:
- nsieve-bit-fp, nsieve and scimark-sparse each at least −1% in
  instructions;
- no `@bench` row above +0.3%;
- hashgate 99/99.

P0 reports `proven-eligible arms / arms` per arm kind, and P3 reports
`proven arms` and `checked arms` per kind, both in `--jit-stats`.

**Tests**, each mutation-checked:
- An arm picks the proven entry when the parent proves every fact.
  Assert the counter and that the slot holds the proven address.
- An arm keeps the checked entry when the parent does not prove a fact:
  the child reads a slot the parent never touches.
- **The adversarial test.** A child entered by two parents, one that
  proves a slot's tag and one that leaves it a different type. Forcing
  every arm proven must give a wrong result or a crash, so the test can
  catch a missing check.
- The step-sign and overflow checks in the prologue. A continuation whose
  enclosing step changes sign between activations, and a limit at
  `math.maxinteger`, in every mode.
- Silent promotion still promotes a cycle whose links are proven.

## 9. Questions for Bart (answered 2026-10-21)

Answers: Q1 every trace; Q2 the exclusions as listed; Q3 the compile-time
table; Q4 both review rounds before P1.

- **Q1** (§4.2). Check the step and overflow guards in the prologue on
  every trace, or only on one-shot pages?
- **Q2** (§7). Are the v1 exclusions acceptable: seeded pages, exit-side
  adapter arms, frame-motion arms, heap-structure checks?
- **Q3** (§5.2). A compile-time fact table on each page, or `kinds` and
  `alloc` retained and `F` derived at arm time?
- **Q4.** Codex and antigravity review rounds before P1, as for doc 66?

## References

- `TODO.md`: "Continuation traces re-check a `for` step every run" (the
  measurements).
- LuaJIT `lj_record.c`: `rec_for_check` (~445), `rec_for_loop` (~479),
  `lj_record_setup`'s FORL root case; `IRSLOAD_INHERIT`.
- Doc 17 (exit patching, entry stubs), doc 22 §B (seed prologue), doc 56
  (exit adapters), doc 57 (prologue pins, `pinHoisted`).
