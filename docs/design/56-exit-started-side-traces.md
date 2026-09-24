# 56 — Exit-started side traces (LuaJIT's side-trace mechanism) — Design

Status: draft, not yet implemented. Revision 3. Antigravity round 1 returned CHANGES REQUESTED and round 2 APPROVE WITH CHANGES; all findings from both are folded in. A Codex round is still owed.
Owner: Bart
Last updated: 2026-09-24

## Implementation status

Tracking the gap between this design and what's on the main branch.
Tick items as they land; move whole sections to "done" once everything
inside them is checked. Every phase lands behind `just test` and the
jit-debug gate. Phases 1–2 are inert: they add data that nothing
consumes yet, so every program's output and trace set stays identical.

### Done

- [x] **Diagnosis.** doc 55 §3 "Finding": both fft bit-reverse anchors
  are 0.0% traced (56% of fft's run). Our side-trace analogue re-runs
  the whole iteration from the anchor, so the shapes multiply; LuaJIT
  builds 2 roots and about 8 exit-started side traces.
- [x] **Research round.** LuaJIT side traces (`lj_trace.c`,
  `lj_record.c`, `lj_snap.c`, `lj_asm.c`, `lj_asm_x86.h`); mahina's exit
  state model (coarse deopt, doc 45 precise); mahina's recording and
  linking machinery. Summarised in §2–§3.
- [x] **Design review round 1 (Antigravity): CHANGES REQUESTED.** Three
  blockers, three majors, one nit, all accepted. Dispositions are in
  §11. Codex was unavailable until 2026-09-29.
- [x] **Design review round 2 (Antigravity): APPROVE WITH CHANGES.** Two
  majors, one minor, one nit, all accepted. It also answered Q3, Q6, Q7
  and Q8. Dispositions are in §12.

### Outstanding

- [ ] **Design review, Codex round.** Due once Codex is back
  (2026-09-29). Receipts go in `docs/reviews/doc56/`.
- [ ] **Phase 0 — baseline and probes.** Board + fft `--jit-stats`
  baseline; jit-debug probes for every new event (snapshot capture,
  attachability verdict, exit-side want/record/commit/arm, adapter
  build, materialize, tryside give-up); a ten-leg bit-reverse reduction
  test that pins today's shape (parity holds, the residency expectation
  fails).
- [ ] **Phase 1 — exit snapshots and exit locations (inert).**
  - Boundary ordinals and sparse snapshots per bytecode boundary.
  - Every guard and every sunk store carries its boundary ordinal.
  - `tropt` keeps snapshot refs live and remaps them, and preserves the
    ordinals.
  - The native compiler records, per attachable exit, where each needed
    ref lives (register, spill, home or constant).
- [ ] **Phase 2 — attachability and resume pc (inert).**
  `exitAttachable` and `exitResumePc`, including the branch fix-up and
  the Q6 guard-emitter audit. Pure tests.
- [ ] **Phase 3 — tier-1a materialize and exit-side recording.**
  - `irinterp` materializes at an attached or wanted guard.
  - The dispatcher resumes tier-0 at `P`, with recording when a side
    trace is wanted.
  - New `.exit_side` recorder kind and `AnchorKind.exit`, closing by
    linking to a loop anchor's trace.
  - Commit with `(parent, exit)` provenance and a DONE latch, bounded by
    `tryside` and `maxside`.
- [ ] **Phase 4 — native exit adapters.**
  - Per-exit adapters built from the Phase-1 exit location map when an
    exit first becomes hot: materialize, then jump through a data cell
    to either the child's entry or the resume-at-`P` return.
  - `ArmKind.exit_side` and its `arm` validation.
  - A `.exit` child's prologue failure resumes tier-0 at `P`.
- [ ] **Phase 5 — ledger grammar and accounting.** `LedgerKind.exit_side`
  rows, the replay grammar, and completion attribution.
- [ ] **Phase 6 — regions and silent promotion.**
  - First, on its own with a board A/B: owner election compares decoded
    pcs (`entryPc`), not tagged ones (§4.8).
  - `exit_side` edges and the side trace's `.link` back are
    intra-iteration edges of the parent's loop region.
  - A new `SilentSiteKind.exit_side`, so the steady cycle promotes and
    stops writing rows (doc 55 §2d machinery).
- [ ] **Phase 7 — tiering policy.**
  - Routing: existing live arms first, then attachable exits to
    exit-side, then today's routes.
  - The legacy-strike exemption for attachable exits that are not yet
    DONE.
  - `tryside` / `maxside` constants.
- [ ] **Phase 8 — measurement and docs.** The §9 budget on fft and the
  full board, compile time, snapshot memory and adapter mcode, and
  updates to docs 17 (§S.8), 40 (open question) and 55 (§3).
- [ ] **Open question Q3 — snapshot liveness cost.** (§8) Direction
  settled in round 2; the number is measured in Phase 4.
- [ ] **Defer — register inheritance.** LuaJIT's `asm_head_side` takes
  the parent's registers directly. v1 adapters hand off through the
  slab, like every mahina link today; the adapter is where inheritance
  would later live.
- [ ] **Defer — typed entry.** Skip the side trace's prologue tag checks
  when the parent's snapshot proves the types.
- [ ] **Defer — peeled parents.** An exit-side hop from a peeled parent
  needs the doc-39 `+1` completion split at the hop. It is computable
  (guard before or after the `.preheader` marker) but not needed for
  bit-reverse; t1 at `:9` is a numeric `for`, which never peels.
- [ ] **Defer — exits inside inlined frames** (`inline_depth > 0`),
  until frame reconstruction exists (doc 45 D1's deferral).
- [ ] **Defer — side traces that leave the anchor frame** (return below
  their start frame; LuaJIT allows it).
- [ ] **Defer — precise-trace exits** (doc 45 "precise links").
- [ ] **Defer — snapshot serialization** (`traceser` v5).

## 1. Why this exists

scimark-fft is 12.6× LuaJIT after doc 55 §2d, and 56% of its run is two
bit-reverse loops that never run as traces (doc 55 §3 "Finding"):

```lua
for i=0,2*n-4,2 do
  if i < j then v[i+1], v[i+2], v[j+1], v[j+2] = v[j+1], v[j+2], v[i+1], v[i+2] end
  local k = n
  while k <= j do j = j - k; k = k / 2 end
  j = j + k
end
```

The root trace at the `for` unrolls the `while` for the one path it
recorded (swap, 3 trips). Real iterations take the swap about half the
time and run 0, 1, 2, … trips with probability 2^-(t+1). Every other
path exits, and our only way to cover an exit is a same-anchor
**sibling**: a whole new trace that re-runs the iteration from the loop
header. The shapes multiply (swap × trip count ≈ 10), against a cap of 4
traces per anchor and a prime-side bound of 2. So the anchor thrashes,
gets gated, and never runs traced again.

LuaJIT (`luajit -jv`, the same function) builds 2 root traces and about
8 **side traces**. Each side trace starts recording **at its parent's
exit**, from the parent's state at that point, and ends by jumping into
a root trace. The prefix before the exit is shared, never re-recorded.
Covering one more path costs one small trace, and the parent's exit is
patched to jump straight into it.

Doc 17 §S chose the whole-iteration sibling on purpose. Mahina exits are
*anchor-coherent*: the slab holds the state at the start of the current
iteration, and tier-0 re-runs it. §S.8 deferred "true per-exit
snapshots (LuaJIT `snap`/`lj_snap_regspmap`) for non-anchor-coherent
exits" until "a workload demands mid-body exit handoffs". Bit-reverse
is that workload, and the shape is not specific to it. Any loop body
with branches or a variable inner trip count multiplies whole-iteration
siblings in the same way. This doc is the contract for Pall's mechanism,
adapted to mahina's deopt and determinism model.

## 2. What LuaJIT does (the reference)

All citations are `~/Projects/LuaJIT/src/`.

- **Hotness.** Every exit goes through `lj_trace_exit` →
  `lj_snap_restore` (restore the Lua stack from the snapshot, data
  driven) → `trace_hotside` (`lj_trace.c:799`): `++snap->count >=
  hotexit` (10) starts recording at the snapshot's pc, from the state
  just restored. `SNAPCOUNT_DONE` (255) latches an exit once a side
  trace is attached. Retries are bounded: `count >= hotexit + tryside`
  (4), or the root already has `maxside` (100) children, gives a trivial
  side trace that links straight to the interpreter
  (`lj_record.c:2883`). A side-trace abort is never penalised
  (`trace_abort` penalises only `parent == 0`, `lj_trace.c:605`).
- **Snapshots.** A snapshot is a sparse slot → IR-ref map plus the
  frame links and the resume pc, 12 bytes of header + 4 per entry
  (`lj_jit.h:179-226`). A guard uses the most recent snapshot, so there
  are fewer snapshots than guards. Snapshots are added after stores and
  side-effecting calls, before comparisons, and so on
  (`lj_record.c:2283`, `2196`). Dead slots are purged
  (`snap_usedef`, `lj_snap.c:208`).
- **The branch fix-up.** `rec_comp_fixup` (`lj_record.c:2205`) rewrites
  a comparison's snapshot pc to the branch target *not* taken on the
  recorded path. A failed comparison guard therefore resumes, in the
  interpreter or in a side trace, at the other branch, and the
  comparison is never re-recorded.
- **Side-trace setup.** `lj_snap_replay` (`lj_snap.c:508`) turns the
  parent's snapshot into the side trace's opening IR: one
  `SLOAD PARENT|INHERIT` per entry (no type check, the type is copied
  from the parent), `PVAL`s for sunk values, and re-materialized sunk
  allocations. Slots the parent never touched load lazily with a normal
  guarded `SLOAD`.
- **Register inheritance.** `asm_head_side` (`lj_asm.c:1941`) coalesces
  the parent's exit registers and spill slots into the side trace's
  entry. `asm_snap_alloc` keeps every snapshot ref in a register or
  spill slot at each guard. A patched exit therefore does no
  materialization at all; only unpatched exits pay `lj_snap_restore`.
- **Linking out.** A side trace that reaches a loop with a trace ends
  with `LJ_TRLINK_ROOT` to it (`rec_loop_jit`, `lj_record.c:660`); that
  can be its own root or another root (an inner loop). Loops without a
  trace are unrolled up to `loopunroll` (15). Values cross into the
  linked trace **through memory** (`asm_tail_link`); only the parent →
  side edge passes registers.
- **Patching.** `lj_asm_patchexit` (`lj_asm_x86.h:3127`) rewrites every
  `jcc` that targets the exit's stub to jump to the side trace. It is
  one-way, done once when the side trace attaches.

## 3. What mahina has today

- **Exit contract.** Ordinary exits are anchor-coherent.
  - The native `deopt_exit` flushes `.carried` homes, so the slab holds
    the current iteration's start state (`nativegen.zig` ~2583).
  - Tier-1a writes `regs` only at `.loop`/`.link`/`.terminal`
    (`irinterp.zig:12-24`).
  - A store that follows any heap read is **sunk** below every guard
    (`pending_stores`, appended by `finalize`), because the re-run
    would otherwise apply it twice (the C1 model).
- **Precise snapshots (doc 45).** `Snapshot {resume_pc, slots_begin,
  slots_len, register_count}` and `SnapshotSlot {slot, ref}` exist
  (`trace_snapshot.zig`), with interning and budgets. Only `new_table`
  anchors are precise. Precise traces refuse inlining, sunk stores,
  `.link` closes, peeling and native links, and skip `tropt`. The native
  materializer `emitPreciseSnapshotFlush` (`nativegen.zig:653`) and the
  `.precise_resume` dispatcher arm (resume tier-0 at `snap.resume_pc`,
  `interp.zig:4052`) work, and so does the tier-1a precise exit tail
  (`irinterp.zig:1290`).
- **Recording.** Every recording starts at an anchor. For the loop,
  head and cont kinds the slab must be coherent there, and slots load
  lazily with type guards (`refOf`). Continuation recordings
  (`maybeArmContinuation`) are the one existing start at a non-header pc
  reached by an exit: a loop-done exit, whose state is naturally
  coherent at the post-loop pc. `.side`/`.continuation` recordings can
  close with `.link` into another anchor's root (`recWhileLink`,
  `recForPrepLink`).
- **Linking.** The patch is slot indirection (`commitSlotMutation`
  writes `c.slots[exit]`), with handoff through the slab: the child
  re-checks tags and reloads. The arm kinds are `link_terminal`,
  `loop_done_linked`, `ordinary_guard`, `sibling_handoff`, `ret_cont`,
  `call_head` and the region bridge. `arm` refuses peeled and precise
  parents and children.
- **Hot exits.** `noteTakenExit` (`trace_link.zig:311`) is the
  `trace_hotside` analogue: `exit_counts[exit]` (u8), `EXIT_COUNT_DONE`
  (255), `hotexit` (10). Its own comment names the gap: "We cannot
  record from an arbitrary mid-body exit". All three routes (prime
  side, replay side, head sibling) record at the parent's anchor.
- **Missing.** Mid-body snapshots on ordinary traces; recording from an
  exit pc; program positions on sunk stores; a guard-pc-coherent native
  exit; an arm kind, ledger row and replay grammar for such a hop;
  cross-anchor provenance.

## 4. The design

### 4.1 Two exit contracts per guard

Every guard keeps today's **anchor-coherent** contract on its default
path, and that path does not change. An exit that is attached (it has
an exit-side trace) or wanted (it is hot and a side trace should be
recorded) takes a second path: the **resume-coherent** contract. There,
the exit makes the tier-0 state at the guard's resume pc `P` real. Then
it continues at `P`, either in the side trace or, when there is none
yet, in tier-0.

Making it real means three writes, in this order:

1. **Stores from earlier bytecodes.** Every sunk store from a bytecode
   **strictly before** the guard's own bytecode is applied, in program
   order (§4.2's ordinals).
2. **Snapshot slots.** Each slot in the guard's snapshot is written from
   its ref's value.
3. **Carried slots the snapshot does not name.** Every carried slot is
   written from its home, because after the first back-edge its slab
   copy is stale.

**Soundness.** On this path nothing is re-run from the anchor. The
parent executed every bytecode before the guard's bytecode `B`; tier-0
or the side trace executes from `P` onward.

- **Stores before `B`.** Applying the sunk stores of bytecodes before
  `B`, in order, is exactly what tier-0 would have done by then.
- **`B`'s own stores are never applied** (review finding 4). A
  non-branch guard resumes at `B` itself, which is re-executed, so its
  store runs once, there. If `guard_fits` failed, forcing the store into
  the lane would also be wrong. A branch guard's `B` stores nothing.
- **Pure-write stores** that ran inline earlier in `B` are rewritten
  with the same value on re-execution. That is today's C1 argument,
  unchanged.
- **Forwarded loads** (`forwardPendingArrayLoad`/`HashLoad`) already saw
  the forwarded values in SSA. Loads before a store in program order
  read the pre-store heap and still precede it.
- **Stores after `B`** stay unexecuted; whoever runs from `P` performs
  its own.

The default path keeps the C1 argument unchanged. It has no extra cost
while an exit is neither wanted nor attached. Replay-to-k runs pure
tier-0, and keyframes are taken only at interpreter safe points, so
neither is affected.

### 4.2 Exit snapshots and boundary ordinals (Phase 1)

The recorder already keeps `reg_map` per bytecode, and precise mode
snapshots the full window at every boundary (`snapBoundary`).

Ordinary traces get, at each bytecode boundary:

- **A boundary ordinal.** A monotonic `u16` counting bytecodes executed
  on the recorded path.
- **A sparse snapshot.** The `.def` slots of the anchor window
  (depth 0), each mapped to its ref, plus the resume pc of that
  boundary. `.undef` slots are still coherent in the slab.
  `SnapshotSlot.slot` already exists "so a future sparse form is a
  validation change" (`trace_snapshot.zig:11`). Identical vectors are
  interned, so snapshot ids are **not** ordered; the ordinal is.
  `TraceCode` gains a small `ordinal → snapshot id` table.

Every guard records the ordinal of the bytecode that emitted it, and so
does every **sunk store IR instruction**: the ordinal of the bytecode
whose store it is, stamped when the store is deferred. This is review
blocker 1's fix. The sunk stores already exist as real IR instructions
at the end of the trace, and `tropt` already keeps them and remaps
their operands. Carrying the ordinal on the instruction itself makes
"which stores precede this guard" a question in one coordinate space
(ordinals) that survives DCE, CSE, compaction and LICM. Raw IR indices
do not.

- **The optimizer** must treat snapshot refs as liveness roots, remap
  them through `canon`/`new_index`, and preserve the ordinal fields
  (doc 45's outstanding "optimizer integration"). This is the largest
  Phase 1 item.
- **Budgets.** A trace over the snapshot budget simply has
  non-attachable exits; it never aborts the recording.
- **The exit location map (native).** For each attachable exit, the
  compiler records where every needed ref lives at that guard:
  register, spill slot, carried home or constant. "Needed" means the
  snapshot refs plus the operands of the preceding sunk stores. For an
  array store that includes the table base behind its `aref`
  (`aref.a`) when the table is dynamic, because `emitAStore` loads the
  array's data pointer from it (the liveness rule at
  `nativegen_alloc.zig:777` already extends it to the store). Only
  attachable exits, and only their snapshots' `.def` slots, get their
  liveness extended. The map
  is data, compact and per exit. It is what lets an adapter be built
  later without recompiling the parent (§4.6), and it is exactly the
  input register inheritance will need.

Snapshot and map memory are reported per trace in `--jit-stats`.
LuaJIT's measured snapshot cost is about the size of the IR; ours must
stay in that range.

### 4.3 Attachability and the resume pc (Phase 2)

`exitAttachable(t, exit)` is true only when all of these hold:

- the guard has an ordinal and a snapshot, and `exit_prov` is complete
  for it;
- `inline_depth == 0`;
- the exit is not a loop-done exit (those stay with the continuation
  machinery, which already solves them);
- every sunk store from earlier bytecodes is a kind the linked
  loop-done flush already supports (`loopDoneSnapshotSupported`), else
  fail closed;
- the trace is neither precise nor peeled (peeled parents are
  deferred);
- the guard's emitter passed the Q6 audit.

`exitResumePc(t, exit)`:

- **Branch guards** (role `.branch_cond`, source op `jmp_if_*`): the
  successor NOT taken on the recorded path, derived from `source_pc` and
  `polarity`. This is `rec_comp_fixup`. Branch ops write no slots, so
  the boundary snapshot is exact.
- **Every other guard:** the source bytecode `B` itself, re-executed
  from the boundary snapshot taken before it.

The fix-up matters for sharing. On bit-reverse, t1's three
wrong-trip-count exits (ei 60/65/70) all resume at the post-`while` pc
`j = j + k`, so one side trace can serve them (§4.5).

### 4.4 Recording from the exit: materialize first (Phase 3)

Round 1 had tier-0 re-run the iteration from the anchor and start
recording on arrival at `P`. Review blocker 2 showed the flaw: in an
unrolled loop the re-run reaches `P` several times, and the first
arrival is the wrong one. The revision does what LuaJIT does.
`lj_snap_restore` makes the exit state real, and recording starts right
there. There is no re-run and no ambiguity.

- **Want.** When a hot attachable exit reaches `hotexit` in
  `noteTakenExit`, the exit is marked *wanted*.
  - Native: its adapter is built with its data cell set to
    "resume-at-`P`".
  - Tier-1a: a wanted bit is set on the exit.
  - Exits that already have a live arm keep it (Q5, §4.9).
- **Next firing.** The exit materializes (§4.1) and returns
  `ExitReason.exit_side {parent, exit, P}`. The dispatcher arms a
  `.exit_side` recording anchored at `(proto, P)` and resumes tier-0 at
  `P`, following the `.precise_resume` precedent. Entry state is the
  freshly materialized slab. Slots load lazily with type guards, like
  any root, and the parent's snapshot is not replayed into the recorder
  (that belongs to register inheritance, deferred).
- **Anchor.** A new `AnchorKind.exit`, encoded like cont anchors with a
  pc tag bit: `EXIT_PC_BIT = 1 << 30` in `trace_code.zig`, next to
  `CONT_PC_BIT = 1 << 31` and `FUNC_HEAD_PC`. `anchorKind`, `entryPc`
  and the `trace` module's `anchorKind` decode it, and the compiler's
  length contract tightens from `resume_pc < 2^31` to `< 2^30`. Its
  anchor-coherent contract is coherence at `P`, so an
  exit-side trace's **own** exits deopt and resume at `P` under today's
  rules, with no special casing. It sinks its own stores the normal
  way. It is one-shot: it never loops to itself.
- **Close.** Reaching a back-edge or loop header whose anchor has a
  usable trace closes it as `.link` to that anchor. That is usually the
  parent's loop; it can be an inner loop with a root. Peeled targets
  are refused (review finding 5: a peeled trace's entry guards are its
  run-once iteration's types), so the loop is unrolled instead.
  Interpreted loops are unrolled up to a deterministic
  `exit_side_unroll` (LuaJIT: 15), then abort (`LUNROLL`). Leaving the
  anchor frame aborts in v1.
- **Commit.** The trace commits with provenance
  `ProvenanceEdge{parent, exit, child}`. `finishSideTraceProvenance`
  today requires the same anchor; it grows a cross-anchor branch. The
  commit DONE-latches `parent.exit_counts[exit]` and points the exit's
  cell at the child.
- **Retries and caps.** An abort is not a strike (LuaJIT). The exit
  stays wanted, so its next firings still resume at `P`, which is never
  worse than re-running from the anchor. At `hotexit + tryside` the want
  is dropped, the exit latches DONE with no side trace, and it returns
  to the default path; the old routes then apply. The per-root child
  cap is `maxside` (100). Both are deterministic constants.

### 4.5 Sharing by resume pc

An exit-side trace is keyed by `(proto, P)` and selected by entry
fingerprint, like siblings at any anchor. Several exits that resume at
the same `P` with the same types share one trace; their cells all point
at it, and it is recorded once.

The parent knows each exit's slot types statically: they are its IR
types for the snapshot refs. Binding an exit to a child checks that the
child's entry guards match those types. If none matches, the exit stays
wanted and records one. Bit-reverse needs this: at the post-`while`
pc, `k` is an int after 0 trips (`k = n`) and a float after ≥1 trip.

### 4.6 Native exit adapters (Phase 4)

Round 1 emitted a materializer for every attachable exit at compile
time. Review finding 6 priced that at 5–10 KB of cold code per trace,
for the 1–2 exits that ever attach. The revision builds an **adapter
per exit when it first becomes hot**, from the Phase-1 exit location
map. The parent is never recompiled, and exits that never get hot cost
only their map entry.

- **The guard side.** Each attachable exit's mini-stub starts with a
  data-cell test, the §2d pattern: code is never rewritten, and runtime
  state lives in a cell.
  - Cell zero means the default anchor-coherent path, byte-identical to
    today.
  - Cell nonzero means jump to the adapter the cell names.

  The test must not disturb any register holding a needed ref (Q7,
  resolved in round 2). Exit cells live in an RW data region placed
  within ±2 GB of the mcode arena, so the stub needs no register at
  all:

  ```
  cmp qword [rip + cell], 0
  jne .to_adapter
  ; fall through: today's anchor-coherent exit, unchanged
  .to_adapter:
  jmp qword [rip + cell]
  ```

  Inside the adapter, `rax` and `rcx` are free scratch registers:
  neither is in `ALLOC_ORDER` (`nativegen_alloc.zig:180`), so no value
  ever lives in them at a guard.
- **The adapter.** A small mcode-arena allocation, reading values from
  the locations the map names:
  1. the stores from earlier bytecodes, in order, reusing the linked
     loop-done store emitters (`emitLinkedLoopDoneSnapshot`);
  2. the snapshot slots, reusing `emitPreciseSnapshotFlush`'s rules
     (never skip `.carried` on ref identity; write-dominated carried
     loads flush the home);
  3. the carried homes;
  4. `jmp` through the adapter's own target cell, which holds either the
     child's `ordinary_entry` or a resume-at-`P` return stub.

  The exit's cell is set once, at want time. Attaching a child only
  rewrites the adapter's target cell.
- **`ArmKind.exit_side`.** The registry records the arm so that
  `resetLinksTouching` and retirement work as for every kind.
  Validation requires:
  - the parent exit is attachable;
  - the child is `.exit`-anchored at the exit's resume pc and not
    peeled;
  - the child's entry fingerprint matches the parent's static types;
  - the child is compiled.

  Retiring the child points the target cell back at resume-at-`P`.
  Retiring the parent drops the adapter with the parent's page.
- **Register allocation.** Snapshot refs and preceding store operands
  must be recoverable at attachable guards: in a register, a spill slot,
  a home or the slab. `nativegen_alloc` already extends `last_use` for
  precise snapshot refs (`:795`), and the same extension applies here.
  Q3 measures the pressure; there is no parent recompilation.
- **Prologue failure.** A `.exit` child's `prologue_fail` resumes tier-0
  at `P`, which is its anchor. No new contract.

### 4.7 Tier-1a and the runtime chain (Phase 3)

Tier-1a materializes **inside `irinterp.executeImpl`**, at the guard
failure, where `values[]` is live (review finding 7; the tier-1a
precise exit tail at `irinterp.zig:1290` is the precedent). It applies
the stores from earlier bytecodes through the same store helpers the
linked loop-done flush uses, and sets the snapshot slots, before it
returns. `regs` is therefore coherent at `P` when `driveChain` or the
dispatcher looks at it. This phase proves the semantics on the ten-leg
matrix before any native code exists. P-EBP-2 in doc 17 allows the tiers
to discover different traces, so native legs simply keep today's
behaviour until Phase 4.

### 4.8 Ledger, accounting, regions and silent promotion (Phases 5–6)

Round 1 proposed rowless attached hops. Review blocker 3 rejected that:

- `replayLedgerFrom` validates each row against the armed successor of
  the row before it, so a missing row leaves an orphan owner, which
  panics;
- an all-rowless cycle never reaches `LEDGER_CAP`, so it never yields;
- zero-progress cycle detection needs the rows;
- above all, Rule Z-8: the mechanism that removes per-row cost from a
  steady cycle already exists. It is silent promotion, which since doc
  55 §2d is a data-cell switch.

So:

- **Rows.** A new `LedgerKind.exit_side` row (append-only ordinal) is
  written at the hop. `replayLedgerFrom` gains its grammar: row
  `(parent, exit)` must be armed `exit_side` to the next row's owner,
  and the hop's coherent point is `P`.
- **Completions.**
  - The parent's local completions are counted as today (`rbx`).
  - The iteration the parent started and the side trace finished is
    counted once, at the side trace's `.link` back-edge. That is the
    same rule continuation traces follow.
- **Regions.** `exit_side` edges and the side trace's `.link` back are
  classified as intra-iteration edges of the parent's loop region, the
  way `loop_done_linked` → continuation edges already join nest-cycle
  regions. The steady cycle (parent → side → parent) then forms a
  region like fft_transform's `:131`/`:193` nest did after doc 55 §2.
- **Owner election must decode pcs.** The dispatcher-entered cycle's
  enclosure test (`trace_region_topology_build.zig:413-421`) compares
  raw anchor pcs (`b.pc <= a.pc or b.pc > flp`). A tagged `.exit` pc
  is above `2^30`, so the test fails, the region mints
  `armable = false`, and silent promotion never happens (Rule Z-8,
  layer 2). The test must compare `entryPc(b.pc)` instead. A test pins
  that a `:9`-shaped parent-plus-side-trace cycle mints
  `armable = true`. Cont anchors (bit 31) hit the same raw comparison
  today, so decoding also changes which existing cont-member cycles can
  elect an owner. Phase 6 lands the decode as its own step, with a
  board A/B, before any `exit_side` edge exists.
- **Silent promotion.** A new `SilentSiteKind.exit_side`: the adapter's
  jump is a silent site, with its data-cell check and its epilogue.
  Once the region qualifies, the cycle promotes and runs with no ledger
  appends, bounded by `silent_budget`.

### 4.9 Tiering policy (Phase 7)

- **Routing precedence** (review Q5), in `noteTakenExit`:
  1. an exit that already has a live arm (sibling handoff, bridge, …)
     keeps it, which protects nsieve's tuned path;
  2. an unarmed attachable exit routes to exit-side;
  3. everything else keeps today's routes (prime side, replay side,
     head sibling).
- **Strikes.** A zero-progress receipt at an attachable exit that is not
  yet DONE does not strike the anchor. The exit is on its way to a side
  trace, and `hotexit + tryside` bounds the wait (Pall: exits never gate
  a trace; only recording aborts are penalised). A DONE exit without a
  side trace strikes as today. This is what keeps `:9` alive long
  enough to grow its tree.
- **Retiring the old routes** for attachable exits is not in v1. Phase 8
  measures whether same-anchor siblings still earn their keep there.

### 4.10 Determinism

Every decision is a pure function of deterministic state:

- `exit_counts`, wanted bits and DONE latches, charged exactly once per
  receipt;
- trace ids and `(proto, pc)` anchors, never addresses;
- the constants `hotexit`, `tryside`, `maxside`, `exit_side_unroll` and
  the snapshot budgets.

Materialization is data-driven from IR snapshots and ordinals. Cell and
adapter addresses are storage, never inputs to a decision. The ten-leg
matrix (P-EBP-1/2) must hold with side traces firing, and every new test
asserts that they actually fire (trace shape plus arm counts), not just
output parity.

## 5. Bit-reverse under this design (the worked example)

The t1 root at `:9` (swap taken, 3 trips; a numeric `for`, so never
peeled) produces these side traces:

| Exit | Resume pc `P` | Side trace records | Links to |
|---|---|---|---|
| ei 60/65/70 (wrong trip count) | post-`while` `j = j + k` | `j = j + k`, the `for` back-edge | `:9` |
| ei 75 (4th trip taken) | `while` body | `j = j - k; k = k / 2`, back to the while header | `:55`'s root is peeled, so it unrolls up to the limit and links to `:9` |
| ei 12 (`i < j` false) | the no-swap successor | `local k = n`, then the while, unrolled for the observed trips | `:9` |

- **Types.** The post-`while` trace gets two fingerprint variants: `k`
  int (after 0 trips) and `k` float.
- **Nesting.** ei 12's trace has its own trip-count exits, which get
  side traces of their own. That is the same tree LuaJIT builds (T3,
  T5, T7, T8, …).
- **Steady state.** Each outer iteration runs t1 until its first
  mismatch, hops natively through the adapter into the side trace, and
  links back to t1 at `:9`. Once the region promotes, no rows are
  written.
- **Expected count.** About 8–12 side traces for bit-reverse, in line
  with LuaJIT's 8.

## 6. Goals

- LuaJIT's side-trace mechanism on mahina: exit-started recording from
  materialized exit state, resume-coherent native hops, sharing by
  resume pc.
- The fft bit-reverse anchors run as traces (§9).
- No change to any cold exit's behaviour or cost.
- Determinism, the ten-leg matrix and replay are intact.

## 7. Non-goals (v1)

- Register inheritance across the hop (deferred; adapters hand off
  through the slab).
- Peeled parents, exits inside inlined frames, side traces leaving the
  anchor frame, and precise-trace exits (all deferred, listed above).
- Replacing same-anchor siblings. They keep precedence where armed, and
  keep serving non-attachable exits, until measurement says otherwise.
- Snapshot serialization.

## 8. Open questions for review

- **Q1 — row policy.** Resolved in round 1: rows, plus silent promotion
  (§4.8).
- **Q2 — regions.** Resolved in round 1: intra-iteration edges of the
  parent's loop region (§4.8).
- **Q3 — snapshot liveness cost.** Keeping snapshot refs and store
  operands recoverable at every attachable guard (in a register, spill,
  home or the slab) may add register pressure to every trace. Parent
  recompilation is ruled out (round 1). Round 2: under pressure the
  allocator spills rather than fails (`SPILL_MAX = 512`), and a spilled
  snapshot ref is only read on the exit path. The extension applies
  only to attachable exits and their `.def` slots (§4.2). The cost is
  still measured on the board in Phase 4.
- **Q4 — peeled parents.** Resolved in round 1: deferred. Linking into
  peeled children is refused.
- **Q5 — routing precedence.** Resolved in round 1: live arms first
  (§4.9).
- **Q6 — non-branch resume.** Round 1's audit says guards precede their
  bytecode's register and heap writes, apart from the store guards
  (`guard_bounds`, `guard_fits`), which §4.1 handles by never applying
  `B`'s own stores. Phase 2 re-audits every emitter and makes
  `exitAttachable` refuse any guard emitted after a partial effect of
  its own bytecode. Round 2 agrees: `exitAttachable` asserts the guard's
  bytecode has made no irreversible effect before the guard.
- **Q7 — the exit's cell test without a scratch register.** Resolved in
  round 2: RIP-relative cells in an RW region next to the mcode arena
  (§4.6). Reserving an allocatable register was rejected. It would take
  one of the 9 GP registers from every trace (Rule Z-6), and it isn't
  needed, because `rax`/`rcx` are never allocated.
- **Q8 — exec-log `ExitKind`.** Resolved in round 2: no new `ExitKind`.
  The parent logs its normal guard exit, and the hop shows up as the
  side trace's entry, as with `sibling_handoff`.

## 9. Performance budget (Rule #20)

- **fft.** `fft_bitreverse:9` and `:55` at ≥ 90% traced time
  (`--jit-stats`, `trc%time`), from 0.2% / 0.1% today. fft wall clock
  must fall by at least the tier-0 share those anchors lose. The
  estimate is ~200 → ~110 ms; the real number goes on the board.
- **Board.** No bench regresses by more than 3% on `just bench`
  (interleaved A/B against a `just shadow` baseline for anything
  flagged).
- **Compile and memory.** Snapshot + exit-location-map memory per trace
  no more than about 1× its IR bytes (the LuaJIT ratio). Recording and
  compile time on the board's largest traces measured before/after in
  Phase 1, when the data exists but is unused. That isolates the
  capture cost. Adapter mcode is reported per run and scales with
  attached exits only.
- **Side-trace count.** Bit-reverse lands in the 8–12 range. Any bench
  whose side-trace count hits `maxside` gets investigated, not raised.

## 10. References

- doc 55 §3 "Finding" (the diagnosis), §2d (runtime state in data).
- doc 17 §S (sibling handoff, anchor coherence), §S.8 (the deferral this
  doc takes up), P-EBP-1..4 (equivalence obligations), B-3 (silent
  promotion).
- doc 45 (precise snapshots, materializers, `.precise_resume`,
  outstanding optimizer integration).
- doc 38 (while-inner linking, unroll-first, `low_trip_while`), docs
  39/40 (peeling, the fusion exclusion and its open question).
- doc 54 P2 amendment (rowless transitions and their progress bound).
- LuaJIT: `lj_trace.c` (`trace_hotside`, `lj_trace_exit`,
  `trace_stop`), `lj_record.c` (`lj_record_setup`, `rec_comp_fixup`,
  `rec_loop_jit`, `rec_loop_interp`), `lj_snap.c` (`lj_snap_add`,
  `lj_snap_replay`, `lj_snap_restore`, `snap_usedef`), `lj_asm.c`
  (`asm_head_side`, `asm_tail_link`, `asm_snap_alloc`), `lj_asm_x86.h`
  (`lj_asm_patchexit`).

## 11. Review round 1 (Antigravity, 2026-09-24): CHANGES REQUESTED, dispositions

1. **BLOCKER — `PendingStore.pos` against post-`tropt` guard indices.**
   Accepted. Replaced with per-bytecode boundary ordinals carried on
   guards and on the sunk store IR instructions themselves (§4.2).
2. **BLOCKER — the tier-0 re-run reaches `P` several times inside an
   unrolled loop.** Accepted. The reviewer's fix was an occurrence
   count. The revision takes LuaJIT's order instead: materialize at the
   exit, then record from `P` (§4.4). The ambiguity disappears rather
   than being counted.
3. **BLOCKER — rowless hops break replay validation, the yield bound
   and cycle detection, and duplicate silent promotion (Z-8).**
   Accepted. Rows plus region classification plus silent promotion
   (§4.8); the rowless phase is removed.
4. **MAJOR — a bytecode's own sunk stores must not be applied at its
   guards.** Accepted: strictly earlier bytecodes only (§4.1, §4.2).
5. **MAJOR — linking into a peeled child is unsound** (its entry guards
   are the run-once types). Accepted: refused, so the side trace unrolls
   instead (§4.4, §4.6). Peeled parents are deferred. Verified: `:9` is
   a numeric `for`, and `isPlainWhileAnchor` never admits it to peeling
   (`trace_recorder.zig:181`).
6. **MAJOR — compile-time materializers at every attachable exit bloat
   mcode.** Accepted. Adapters are built per exit when it gets hot, from
   a compile-time exit location map (§4.6). This is also the seam where
   register inheritance will go.
7. **NIT — tier-1a materializes in `irinterp`, not `driveChain`.**
   Accepted (§4.7).

## 12. Review round 2 (Antigravity, 2026-09-24): APPROVE WITH CHANGES, dispositions

Receipt: `docs/reviews/doc56/antigravity-r2.md`. All seven round-1
findings were marked RESOLVED.

1. **MAJOR — owner election compares tagged pcs, so `.exit` members
   make every such region unarmable.** Accepted and verified
   (`trace_region_topology_build.zig:419`). Decode with `entryPc`
   (§4.8), landed first and on its own because it also affects cont
   members.
2. **MAJOR — Q7 must not reserve an allocatable register (Z-6).**
   Accepted and verified (`ALLOC_ORDER` has no `rax`/`rcx`,
   `nativegen_alloc.zig:180`). RIP-relative cells (§4.6, §8).
3. **MINOR — a dynamic table's base (`aref.a`) is a needed operand of
   its sunk array store.** Accepted and verified
   (`nativegen_alloc.zig:777`), §4.2.
4. **NIT — spell out `EXIT_PC_BIT` and its decoding.** Accepted:
   `1 << 30`, with the tighter compiler length contract (§4.4).
