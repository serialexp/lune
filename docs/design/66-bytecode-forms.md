# 66 — Bytecode forms: constant operands, field ops, compare-and-branch, ITERN

Status: rev 2, decided, not yet implemented. Round-1 review findings
(codex and antigravity, §10) are folded in. Bart answered Q1–Q5 (§9) on
2026-10-22; implementation starts with the `condBranchOf` refactor.
Owner: claude (coral-marten)
Last updated: 2026-10-22

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole phases to Done once everything inside them is checked.

### Done

- [x] **Diagnosis** (2026-10-21, §1). Per-op marginal instructions against
  LuaJIT `-joff`, after the item 1–3 tier-0 fast paths (d40cf2d). The
  probes are `bench/opprobe/ops3.lua` with `bench/opprobe/measure.sh`.
- [x] **Consumer inventory** (§4.1). Lists every place that switches on
  bytecode ops or pattern-matches compiler output. Completed in rev 2 from
  the review.
- [x] **Round-1 review** (codex and antigravity,
  `docs/reviews/doc66/*-r1.md`, summary in §10). Rev 2 fixes these:
  - Strategy B's GC argument was false;
  - `itern` shape (b) has three successors and bypasses the loop gate;
  - commutative swapping reorders metamethod arguments;
  - `itern` must decline grids;
  - the recorder's field helpers take a key register;
  - constant `==` needs numeric semantics.

### Outstanding

- [x] **P0 — probes into the repo** (2026-10-21). They are now in
  `bench/opprobe/`: `ops.lua`, `ops2.lua`, `ops3.lua` and `fields.lua`,
  with `measure.sh` (per-op marginal cost against LuaJIT `-joff`) and
  `abench.sh` (every `@bench` program, both tiers). They are not
  `@bench` programs, so `run.py` and hashgate skip them.
- [x] **Q1 — strategy for the fused forms** (§4). Bart, 2026-10-22:
  strategy A (new canonical opcodes) for every form, with the §5.4
  `condBranchOf` predicate refactor landed first as its own commit.
- [x] **Q2 — constant-operand arithmetic shape** (§5.3). Bart,
  2026-10-22: a K index (any number), keeping the constant-on-the-left
  forms. Int immediates only if a probe later shows the K load matters.
- [x] **Q3 — which compare-and-branch forms** (§5.4). Bart, 2026-10-22:
  register-register, equality against a constant, and ordered compares
  against a constant (`jltk` and kin).
- [x] **Q4 — the `pairs` fast path's shape** (§5.1). Bart, 2026-10-22:
  (b2), declining while the hash view needs a build (no allocation in
  the fast lane).
- [x] **Q5 — phase order** (§7). Bart, 2026-10-22: `condBranchOf`
  refactor → P2 → P3 → P5 → P4 → P1.
- [ ] **`condBranchOf` refactor** (§5.4), its own commit, before P2.
- [ ] **P1 — `itern`** (§5.1): the generic-`for` step for the real `next`
  without a call.
- [ ] **P2 — `get_field` / `set_field`** (§5.2): a constant string key in
  the instruction.
- [ ] **P3 — constant-operand arithmetic** (§5.3).
- [ ] **P4 — compare-and-branch** (§5.4).
- [ ] **P5 — `eq`/`ne` against a constant** (§5.5).
- [ ] **Each phase: recorder and JIT parity in the same change** (§6). A
  new op that the recorder aborts on regresses every traced loop that uses
  it.
- [ ] **Each phase: measured** (§8). Per-op probe, `abench.sh` over every
  `@bench` program in both tiers, and hashgate.
- [ ] **Defer: JIT recording of `itern`** (§5.1). Today a `pairs` loop
  aborts recording at the `next` call (`.host_barrier`). Recording the
  step natively is a separate design: an IR op for the step, as LuaJIT's
  `rec_itern` does.

## 1. Why this exists

After items 1–3 of the tier-0 survey (TODO.md "Tier-0 interpreter cost
survey"), the ops themselves are close to LuaJIT. `<` is 39 instructions
against 32 and `==` is 43 against 38. What remains is the number of ops a
construct compiles to, and each extra op pays the dispatch floor.

Marginal instructions over the `s = s + i` loop, mahina tier-0 against
LuaJIT `-joff`, at d40cf2d:

| construct | mahina | LuaJIT | what mahina runs | LuaJIT op |
|---|---:|---:|---|---|
| `local b = 7` | 25 | 9 | `load_int` | `KSHORT` |
| `local b = "x"` | 32 | 11 | `load_const` | `KSTR` |
| `t.x` (local `t`) | 128 | 29 | `load_const` + `get_index` | `TGETS` |
| `t.x = i` | 125 | 32 | `load_const` + `set_index` | `TSETS` |
| `if i > n then` | 73 | 23 | `gt` + `jmp_if_false` | `ISGE` + `JMP` |
| `if x == nil then` | 100 | 16 | `load_nil` + `eq` + `jmp_if_false` | `ISNEP` + `JMP` |
| `i - 7` | 73 | 15 | `load_int` + `sub` | `SUBVN` |
| one `pairs` step | 459 | 17 | 3 × `move` + `call next` + `tfor_loop` | `ITERN` + `ITERL` |

Two numbers explain most of the table:

- **One op costs about 25 instructions** even when it does nothing: a
  `load_int` is a dispatch plus one store. That floor is the dispatch
  prologue (doc 42 §4.2), item 6 of the survey. This doc removes ops;
  item 6 makes each remaining op cheaper. The two compound.
- **The `pairs` step is 27× LuaJIT.** It runs three `move`s, the generic
  native-call path (argument marshalling and `multi` result scatter) and
  `next` itself. The `next` lookup is already O(1) per step
  (`HashPart.nextLive` resumes from `iter_pos`, 9b212e2). What remains is
  the protocol around it.

The base loop itself, `for i` with `s = s + i`, is 124 instructions against
LuaJIT's 37. That gap belongs to item 6, not here.

## 2. Goals

- Each targeted construct compiles to as few ops as LuaJIT's, or fewer
  where our 12-byte `Instr` (three u16 operands plus an i32 `aux`) lets one
  op carry what LuaJIT needs two for.
- **No JIT regression.** Every new op is recorded in the same change, and
  every JIT site that pattern-matches compiler output keeps matching
  (§4.1, §6).
- **Determinism unchanged.** All eight modes stay byte-identical, hashgate
  digests stay stable, and replay-to-k stays exact (§6.3).
- **General, not per-benchmark** (Rule Z-6). Each form targets a construct
  every program uses: field access, constant operands, conditions,
  `pairs`.

## 3. Non-goals (v1)

- The dispatch prologue (survey item 6) and the call/return path (item 5).
- Register allocation and `move` elimination beyond what 69fec42 did.
- Recording `itern` natively in the JIT (deferred bullet above).
- Constant forms for every op. Bitwise ops, `pow` and `concat` keep the
  register forms unless a probe shows a real gap.

## 4. Two strategies for a fused form

A "form" here is either a new instruction in `Proto.code` or a tier-0
handler that runs two existing instructions in one dispatch. The choice is
per form (Q1).

### 4.1 Strategy A — new canonical opcodes

The compiler emits the new op, and every consumer learns it. The inventory
of consumers that switch on bytecode ops (non-test):

- **Exhaustive switches; the build fails until an arm is added.**
  `interp.zig` `handlerFor`, and `bc_liveness.zig` `effectOf` (the
  use/kill/successor model that `bc_dom` and GC masking build on).
- **The CFG model's fixed shape.** `bc_liveness.Effect` holds at most two
  successors, and `edge_kill` is one register per edge, not a range
  (`bc_liveness.zig` ~54/68). `bc_liveness.successors` and `bc_dom` store
  and walk exactly two edges. An op with three destinations, or one that
  writes a register range on only one edge, needs that model widened
  first.
- **Loop contracts.** In `bytecode.zig`:
  - `loopHeaderOf`: which ops are back-edges.
  - `loopGateOf` (~360): the gate every body entry passes through. For a
    generic `for` that is the `tfor_loop`, and region topology elects
    owners by dominance from it (`trace_region_topology_build.zig` ~596).
- **Loop entry patching.** `trace_entry_registry.patchedEntryOp`,
  `resolvePatchPc` and the install checks, and `interp.opJLoop`'s switch on
  the canonical op. These fix which instructions can host a loop entry.
  The patched `repeat` entry is its `loop` marker; the backward
  `jmp_if_false` is not patched.
- **Call-site consumers.** `interp.nativeSite` (the current call-site
  instruction), `frameShape` (a suspended Lua caller must sit after a
  `.call`) and `frameMask` (multret `.call`). An op that can perform a
  call, such as `itern` shape (b2), must be accepted by all three.
- **Slow-path table.** `interp.zig` `buildSlowTable`. A fast handler that
  leaves through `slowTail` without an entry lands on `noSlowPath`, which
  panics.
- **Recorder.** `trace_recorder.zig` `recordOne`, where `else` is
  `abort(.nyi_opcode)`. A missed arm means silent loss of JIT coverage, not
  a build error.
- **Operand decoding outside the handler.** `interp.zig` ~2009–2023,
  `describeFault`'s operand pick (`firstNonNumber`, the indexed object),
  reads `regs.get(instr.b)` and `regs.get(instr.c)`. On a constant form,
  `c` or `aux` is a K index or an immediate, so it must render the
  constant instead of reading a register. `bytecode.writeInstr`, the disassembler that
  viz shows through `wasm_entry.buildDisasmBlob`.
- **Compiler-shape matchers.** These matter only for compare-and-branch,
  because they name `jmp_if_false`/`jmp_if_true` as "the branch". Some
  also admit `jmp_if_not_nil` and some do not, for example
  `trace_link.zig` ~443 against `trace_code.zig` ~989:
  - `bytecode.loopExtentFor` (the `while` branch check ~339 and the
    `repeat` closer check ~349) and `assertLoopClosersWellFormed`
    (~393–416);
  - in `trace_code.zig`: `computeOwnLoopTest` (a loop's own test), and the
    branch-source checks in `classifyBridgeCandidate` and
    `CompositeWalk.init`;
  - `trace_exit_attach.resumeOf`, which resumes a branch guard on the
    untaken edge (the `rec_comp_fixup` analogue), and
    `continuationReachesEnclosingBackEdge`;
  - the "wants prime side" check in `trace_link.zig` (~446), the sibling
    handoff branch-op check in `trace.zig` (~1853), and `recBranch`
    (~3423/3443/3483), which takes its polarity (`jumped`) and the
    `repeat` LLEAVE from the op;
  - `trace_finalize.phiLiveRow`, through `CompositeWalk`.

  Missing one of these does not fail the build. It quietly turns a loop
  test into an ordinary branch, which unpatches entries or loses
  bridges. Doc 64's machinery is exactly what would degrade.
- **Generic-`for` shape.** `loopExtentFor`'s `.jmp` arm scans the test
  block for `move`/`call` up to the `tfor_loop`. A new op in that block must
  be accepted there, or region topology and `linkKindAt` fail closed.
- **Compiler emission sites** for field forms include table constructors'
  named fields (`compileTable` ~1328–1351), not only `t.x` expressions.
- **Audited, unchanged.** These are specialised on purpose, and no form
  here alters what they match:
  - multret producer and consumer recognition (`bc_liveness` ~437/474,
    `trace_exit_attach.isMultretConsumer`);
  - call-layout masking;
  - numeric-`for` linking;
  - the recorder driver's inner-root context decoding (`trace.zig`
    ~3577).

Nothing serializes bytecode ordinals. Keyframes re-compile from source and
store pcs only, `traceser` writes IR ops, and viz shows disassembly text.
New ops are appended at the end of the enum (the comptime density assert,
doc 42 §4.6). Pcs shift wherever the compiler emits fewer ops, and that is
deterministic because compiler output is.

### 4.2 Strategy B — handler-level fusion over unchanged bytecode

The bytecode stays as it is. The first instruction's fast handler checks
whether the next instruction is the partner it fuses with, executes both,
and dispatches once. LuaJIT's interpreter does this itself: `ISLT` reads
the offset of the `JMP` that follows it and never dispatches that `JMP`.

Examples:

- The `lt` fast handler, after writing `R[a]`, checks that `next.op` is
  `jmp_if_false` or `jmp_if_true` with `next.a == a`, and jumps straight to
  the target.
- `load_const` checks for a following `get_index`/`set_index` whose key
  register is its `a`.

What B keeps:

- Every JIT consumer sees exactly today's bytecode, so no shape matcher
  changes and no recorder arm is added. The recorder runs in `.full` mode,
  which does not fuse (below).
- The temporary register is still written, so liveness, GC masking and
  keyframes are unaffected.

What B must preserve. The skipped instruction's prologue is part of the
determinism contract (doc 42 §4.2, normative). For the second instruction
the fused handler must:

1. **GC check.** ~~It may skip this only because neither instruction
   allocates.~~ **Rev 2: that argument is false** (codex blocker 1).
   `shouldCollect()` is `gc_stress or object_count >= next_gc`
   (`gc.zig` ~583). Under `gc_stress`, which runs in `.fast`, every
   boundary collects, and a collection that fails its worklist
   reservation stays due (`interp.zig` ~2524). A collection is
   observable: it scrubs registers, invalidates dead trace constants,
   advances the host epoch and drops iterator caches. So the fused handler
   may skip the second boundary only when collection is **not due there**:
   it re-tests `shouldCollect()` and dispatches normally if it is true.
   Allocation-freedom is still required as well. A `get_index` on a grid
   deflates it (doc 14, `indexGet`), so a fused `load_const` +
   `get_index` fuses only on the `heapKeyChainGet` lane, which declines
   grids.
2. **`safepoint_seq`.** Bump it once more, so step counts are unchanged.
3. **Replay lines, suspend, recording close, continuation and replay-side
   activation, recording mirror.** These are `.full`-only, so B fuses
   only in `.fast` mode. Each hook that needs them blocks `.fast` (active
   recording, pending anchors, suspend controls, line recording;
   `trace.zig` ~3132, `interp.zig` ~3033/3409). Rev 2 correction: "replay
   runs `.full`" holds because the wasm replay paths enable suspension and
   line recording (`wasm_entry.zig` ~441/704). Effect replay on its own
   does not force `.full`. The argument rests on the hooks, not on
   "replay".
4. **Region departure observer.** Fuse only while
   `regionProfitCount() == 0`, the exact prologue gate (`interp.zig`
   ~3374). Rev 2 correction (antigravity B2): that count is non-zero
   whenever a region profit map exists, which is the case in effectively
   every program that tiers up. So B does not "fuse less" in traced
   programs; it does not fuse in them at all. Its tier-0 exits and
   fallbacks get nothing.
5. **`frame.pc` and the counter.** Bump `safepoint_seq` after the first
   instruction executes, then publish the second pc to `frame.pc` before
   executing it. That is the prologue's order (`interp.zig` ~3325/3402).
   An error from the second instruction reports its own pc.
6. **Entry patches.** The partner must be read from the running image
   `st.code`, never from `instr + 1`. A handler can be handed a canonical
   instruction when a head or continuation patch declines
   (`interp.zig` ~6618/6718), so its neighbour in memory is canonical
   code, not the image. A patched partner (`jloop`, `jcont`) is not the
   expected op, so the pair does not fuse and the patch runs.

B's limits:

- It cannot remove the store of the temporary, the constant's
  `load_const`/`load_int` store, or the second fetch.
- Each first-op handler gains a peek-and-branch even when it doesn't
  fuse, plus the `shouldCollect()` re-test from rule 1.
- By rule 4 it is off in every program with a live region profit map.
- Tier-0 behaviour then depends on mode, which is exactly what the 8-mode
  equivalence suite exists to catch.

### 4.3 Where each fits

| form | A cost | B cost | B saves |
|---|---|---|---|
| `get_field`/`set_field` | small: recorder takes the key from K; `bc_liveness` arm | allocation caveat (§4.2 rule 1) | one dispatch, not the K store |
| constant-operand arith | small: recorder emits `konst` | gains little: the constant store stays | almost nothing |
| compare-and-branch | large: ~12 shape matchers (§4.1) | none in the JIT | one dispatch, and only with no live region profit map (§4.2 rule 4) |
| `eq` against a constant | as arith if no branch; as compare-and-branch if fused | as compare-and-branch | one or two dispatches, same restriction |
| `itern` | moderate to large, depending on shape (§5.1) | not applicable (no adjacent pair) | — |

## 5. The forms

### 5.1 `itern` — `pairs` without a call (P1)

Today the generic-`for` test block runs on every step:

```
jmp test
body: …
test: move b+3, b+0; move b+4, b+1; move b+5, b+2
      call b+3, 2, n
      tfor_loop b → body
```

LuaJIT's parser predicts `pairs`/`next` by name (`predict_next`) and
emits `ISNEXT` + `ITERN` + `ITERL`. `ISNEXT` checks once per loop entry
that the iterator is the real `next` over a table with a nil control. If
not, it despecializes the bytecode in place to `JMP` + `ITERC`. `ITERN`
keeps a slot index in the hidden control variable, so a step never hashes.

Mahina doesn't need the slot index. Once its view is built, the hash part
resumes in O(1) from `iter_pos`, and the array part steps by index. Building
the view allocates, scans and sorts. An insertion invalidates it, and a
collection drops it. In the steady state, the cost is all protocol.
LuaJIT's `ITERN` is more than a shortcut around a call: it owns hot-loop
accounting, and `rec_itern` does its own loop detection
(`vm_x64.dasc` ~4185, `lj_record.c` ~675).

The shapes:

- **(a) LuaJIT's.** The compiler predicts by name, and an `isnext` op
  despecializes into the per-VM copy-on-patch image (doc 20).
  - Rev 2: the restore argument is **not established** (codex
    should-fix 6). A keyframe restore re-compiles to the speculative
    form, but an uninterrupted run that despecialized during an earlier
    call keeps the generic image.
  - The two paths would have to be proven equivalent in pcs, safepoints,
    recording and the control representation. Otherwise the
    specialization state has to be captured or rebuilt.
  - It also needs a new kind of patch, since today's patches are trace
    entries, and two ops.
- **(b) A guarded prefix (rev 1, superseded by (b2)).** One `itern` at
  the top of the test block, jumping to the body on a step and falling
  through to the unchanged `move`/`call` path otherwise. Round 1 found it
  unsound as specified:
  - It has **three** destinations: the fallback, the body, and the exit
    past `tfor_loop`. `bc_liveness.Effect` and `bc_dom` hold two, and an
    edge kill is one register, not the range the step writes (codex
    blocker 2, antigravity B1).
  - Its fast edge bypasses `tfor_loop`. That breaks `loopGateOf`'s
    contract that every body entry passes the gate, which owner election
    depends on. It also skips `opTForLoop`'s back-edge accounting and
    recording activation.
  - The encoding needs two jump offsets.
- **(b2) A guarded iterator op that replaces the `move`s and the `call`**
  (codex's suggestion):

  ```
  jmp test
  body: …
  test: itern b, n            ; was: move b+3,b; move b+4,b+1; move b+5,b+2; call b+3, 2, n
        tfor_loop b → body
  ```

  `itern` has one successor, the `tfor_loop` at `pc + 1`, exactly like the
  `call` it replaces:
  - **Fast lane.** `R[b]` is the `next` builtin and `R[b+1]` is a
    non-grid table or a `row_view`. It runs one step of `next(R[b+1],
    R[b+2])` inline, writes the key and value into `R[b+3]`, `R[b+4]`,
    and nil-pads `R[b+3..b+3+n)` (key nil when exhausted).
  - **Fallback.** Anything else. It does exactly the three `move`s and the
    generic call `call b+3, 2, n`, by tail-calling `opCall`'s logic with
    those operands. A Lua iterator returns to `pc + 1`, the `tfor_loop`,
    as today.

  The gate, `tfor_loop`'s back-edge accounting, recording activation and
  entry patching are all untouched. Liveness is a single-successor arm:
  use `b..b+2`, kill `b+3 .. b+3+max(n, 3)`, the union of what the
  `move`s and the `call` wrote. It saves the three `move`s, the `call`
  dispatch and the native-call path; the `tfor_loop` dispatch stays.
  Other iterators (`ipairs`, `gmatch`, closures) take the fallback, which
  is today's sequence minus three dispatches.
- **(c) A fast path in `opCall`** for "callee is `next` in a `tfor` test
  block call". No bytecode change, but the three `move`s and their
  dispatches stay, so it saves less than (b2).

What (b2) must keep (most also apply to (a) and (c)):

- **Grids.** `next` on an outer grid deflates it first (`iterableArg`,
  `stdlib/base.zig` ~74–84), which allocates. The fast lane declines a
  grid, and the fallback's real `next` deflates as today (codex blocker 4,
  antigravity S1).
- **Allocation and OOM.** `HashPart.nextLive` allocates when the view
  must be (re)built. Two options:
  - the fast lane declines whenever `!iter_valid`, so it never allocates
    and the generic `next` builds the view once;
  - the fast lane builds it and parks `OutOfMemory`, which must then
    match the generic path's error outcome exactly.

  The first keeps every error path identical and costs one generic step
  per view build, which an unchanged table keeps across traversals.
- **Errors.** In the fast lane `f` is `next` and `s` is a valid table, so
  the only failure is OOM (above). Every other case goes through the
  fallback and raises as today.
- **Absent control key.** Mahina does not raise "invalid key to next": it
  resumes at the first greater canonical key, including after a deletion
  (`hash_part.zig` ~460). The fast lane calls the same core, so this is
  preserved.
- **Mutation during traversal.** It is the same core (`nextStepAny` after
  the `iterableArg` checks), so assigning to existing fields, clearing
  them, or inserting keys behaves exactly as `next` does.
- **Call-site consumers.** A fallback call through `itern` is a call site:
  - `nativeSite` decodes the call operands for a native's error location;
  - `frameShape` classifies a suspended Lua caller by `code[pc-1]`;
  - `frameMask` handles multret calls.

  All three accept `itern` as `call b+3, 2, n`. A helper,
  `bytecode.callOperandsOf(ins) ?CallOperands`, keeps that decoding in
  one place.
- **`loopExtentFor`.** The generic-`for` scan accepts the
  `itern` + `tfor_loop` test block.
- **Recorder.**
  - Fast lane: the recorder aborts with a new reason (`.itern_next`), so
    `--dump-aborts` counts it. Today the same loop aborts at the `next`
    call with `.host_barrier`, so coverage is unchanged.
  - Fallback: it records exactly today's sequence, the three `setReg`
    moves then `recCall` with the synthesized call operands.
  - Soundness: `recCall` pins the callee's identity. That is `guard_func`
    for an inlined closure (`trace_recorder.zig` ~4278) or the builtin
    recorder's `guard_builtin` (~4918); an untagged native aborts. So a
    later `next` in the same slot exits.
  - The P1 test reuses **one compiled loop function** across calls with
    different iterators: gmatch, then `pairs`, then gmatch.

`ipairs` can join later through the same op (a second builtin identity,
an array-only step).

### 5.2 `get_field` / `set_field` — constant string keys (P2)

- `get_field a, b, aux=K`: `R[a] = R[b][K[aux]]`.
- `set_field a, aux=K, c`: `R[a][K[aux]] = R[c]`.
- The compiler emits them for `t.x`, `t.x = v`, method lookup
  (`compileCallInPlace`, `compileMethodCall`), `function t.f()` and
  compound `t.x op= v`.
- The handlers reuse the item 2 lanes: `HashPart.liveHeapNode`,
  `heapKeyChainGet`, in-place overwrite. The slow halves call the same
  `opGetIndexSlow`/`opSetIndexSlow` cores with the key taken from K.
- Recorder. The access IR can be identical (`konst`, `guard_table`,
  `href`, `guard_hash`, `hload`), but the helpers take a key
  **register**. `GetFrame`/`SetFrame` carry `key: u16`, and
  `hashGetShape`/`hashSetShape` and the absent-read paths read its
  observed value and SSA ref (`trace_recorder.zig` ~2281/3106/3128/3263).
  Rev 2: P2 refactors them to take a resolved key (observed value plus
  IR ref) from either a register or a constant. It does not fabricate a
  temporary register. Pcs, ordinals and provenance metadata change; the
  IR ops do not.
- The error-message site (`interp.zig` ~2009) learns that the key is a
  constant.
- Allocation. Any outer read of a grid deflates it (`indexGet`, doc 14),
  string keys included, so the full op can allocate. `heapKeyChainGet`
  already declines a grid (`isGrid` returns null), so the fast lane is
  allocation-free and the slow half keeps today's deflate.

An integer-constant key form (`t[1]`, LuaJIT `TGETB`) is a possible P2b.
Only adopt it if a probe shows `load_int` + `get_index` matters in real
programs; most `a[i]` keys are variables.

### 5.3 Constant-operand arithmetic (P3)

`i + 1`, `n - 1`, `x * 0.5`, `i % 2`: today a `load_int`/`load_const`
plus the op. Options (Q2):

- **(i) Immediate ints only.** `addi`/`subi`/`muli`/`modi`/`idivi`, with an
  i32 immediate in `aux` (the `load_int` encoding). Covers the common
  integer cases with no K load. Float constants keep the register form.
- **(ii) K index.** `addk`, … with `aux` indexing a number constant, ints
  and floats alike (LuaJIT `ADDVN`). One more load per op than (i), and it
  covers `x * 0.5`.
- **Constant on the left** (`1 - x`, `1 + obj`; LuaJIT `ADDNV`/`SUBNV`).
  ~~Commutative ops can swap operands in the compiler.~~ **Rev 2: they
  cannot** (codex blocker 3). `1 + obj` and `obj + 1` pass `__add` its
  arguments in different orders, and mahina calls `handler(a, b)` in
  source order (`interp.zig` ~7883). LuaJIT keeps orientation with
  separate `VN` and `NV` forms, `ADDNV` and `MULNV` included
  (`lj_bc.h` ~102, `lj_parse.c` ~820). There are three options: separate
  NV forms, an orientation bit in the encoding, or leaving constant-left
  expressions on the register form.

The fast lanes are item 3's: raw int and float math, with metamethods, a
zero divisor and mixed types going to the slow half. The recorder emits
`konst` for the operand, the IR it already gets from `load_int`. The
traces are the same. Rev 2: no IR `konst` disappears. The recorder's
`konst` already interns (`trace_recorder.zig` ~1884), so both forms
produce the one interned constant.

### 5.4 Compare-and-branch (P4)

`if a < b`, `while i <= n`, `repeat … until x >= y`: today a compare into
a temporary plus `jmp_if_false`/`jmp_if_true`.

- **Strategy A:** `jlt`/`jle`/`jgt`/`jge`/`jeq`/`jne b, c, aux=offset`,
  with a polarity bit in `a` (branch when true or when false). It
  replaces both instructions and writes no temporary. Every shape matcher
  in §4.1 learns "a fused compare-branch is a branch". The cleanest way is
  one predicate, `bytecode.condBranchOf(ins) ?CondBranch` (polarity,
  target, kind), that every matcher calls instead of naming
  `jmp_if_false`. The recorder records the fused op as today's two-part
  sequence: the compare IR and a `guard_true`/`guard_false` with
  `.branch_cond` provenance on it. `resumeOf` resumes on the untaken edge
  through the same predicate.

  Rev 2 (codex should-fix 5, antigravity S5). The predicate only
  centralizes **decoding**. Each caller keeps its own restrictions:
  - own-loop recognition still needs marker adjacency, or a backward edge
    to its own marker;
  - bridge and sibling selection still need real branch guards with
    branch provenance;
  - `jmp_if_not_nil`'s differing admission (§4.1) is kept per caller,
    not unified by accident.

  `resumeOf` keeps its exact rule:
  `recorded_jump = branch_on_true == recorded_result;
  resume = recorded_jump ? fallthrough : target`. It also keeps the
  checks that tie provenance and the snapshot pc to the fused
  instruction: only the `.branch_cond` guard takes the opposite edge, and
  operand-type guards resume at the fused op itself.

  The recorder needs compare and branch helpers that take an IR ref and
  an observed result. Today `recCompare` writes a destination register and
  `recBranch` reads one, and with a fused op `a` becomes the polarity, so
  neither fits as is.
- **Strategy B:** the compare handlers fuse with a following
  `jmp_if_*` on their result (§4.2). There is no JIT change at all. Fusion
  happens only in `.fast` with no live regions.

Which compares (Q3):

- LuaJIT fuses ordered compares only register-to-register.
- Equality has constant forms: `ISEQS` for strings, `ISEQN` for numbers,
  `ISEQP` for primitives.
- `if i < 0` stays `KSHORT` + `ISLT` in LuaJIT. With our `aux`
  holding the offset, a constant compare needs its K index in `c`, so
  `jltk b, c=K, aux=offset` fits the encoding.

### 5.5 `eq`/`ne` against a constant (P5)

`x == nil`, `x ~= false`, `s == "str"`, `n == 0`. Today it is `load_nil`
or `load_const`, then `eq`, then usually a branch.

- **nil, booleans and interned strings** compare by tag and bits in a
  single compare. Strings are interned, so equal contents means the same
  object.
- **Numbers do not** (rev 2, codex nit): `1 == 1.0`, `-0.0 == 0.0` and
  NaN need numeric semantics. A number constant uses item 3's `opEqNe`
  lanes: same-tag raw compare, and the full op for a mixed int and float. This is P4's branch form with a constant
`c`, or a non-branching `eqk a, b, c=K` when the result is a value.

## 6. Correctness and determinism

### 6.1 Semantics

Every form must be exactly its unfused sequence, metamethods and error
messages included. Each phase gets an `expectProgram` semantics test
(ten legs) over the operand-type matrix, like item 3's "every operand
mix" tests. Each is mutation-checked against its fast lanes.

### 6.2 Recorder and JIT parity

Each phase lands with its recorder arm. Before and after the phase:

- `--dump-aborts` on every `@bench` program must show no new
  `nyi_opcode` aborts;
- `abench.sh` JIT instruction counts must show no regression.

For strategy A on compare-and-branch, every matcher in §4.1 goes through
the one predicate. A test pins that a `while` with a fused condition is
still `loopExtentFor`'s shape, still its own loop test
(`computeOwnLoopTest`), and still a bridge candidate.

### 6.3 Determinism

- **Bytecode.** Compiler output is a pure function of source, so fewer
  ops change pcs and step counts deterministically. Replay-to-k, keyframe
  restore and hashgate stay exact across runs of the same binary. Pinned
  fixtures that count instructions or pcs are re-blessed in the phase that
  shifts them, for example viz `decode.test.ts` `anchor_pc` and safepoint
  counts in suspend tests.
- **Strategy B** keeps step counts and pcs identical by construction
  (§4.2 rules 2–5).
- **`itern` shape (a)'s despecialization** is a function of execution
  only (the iterator's identity at loop entry), and lives in the per-VM
  image. Rev 2: that alone does not make restore equivalent (§5.1 (a)).
  Shapes (b2) and (c) hold no specialization state, so this question does
  not arise for them.

## 7. Phasing (Q5)

Suggested by payoff per effort. Each phase is a slice of the end state
(Rule Z-7), gated and measured on its own:

1. **P1 `itern`.** Largest per-use gap (459 against 17).
   - Rev 1 called it "fully localized". Round 1 showed that was only true
     of the withdrawn shape (b).
   - Shape (b2)'s surface: the compiler's generic `for`, one handler that
     can call, `effectOf`, `loopExtentFor`, the three call-site consumers
     (§4.1), and the recorder's abort and fallback.
   - Codex would move P1 last for that reason, and antigravity would keep
     it first (§10).
2. **P2 `get_field`/`set_field`.** The most frequent construct. Small JIT
   surface.
3. **P3 constant-operand arithmetic.** Frequent and small.
4. **P5 `eq` against a constant.** Moderate payoff, cheap once P3's
   K-operand plumbing exists.
5. **P4 compare-and-branch.** High frequency, but strategy A has the
   largest JIT surface of all the phases.

## 8. Measurement

- **Per-op probes.** `bench/opprobe/measure.sh bench/opprobe/ops3.lua
  <probes…>` (`M=binary`), against LuaJIT `-joff`. The target for
  each form is its LuaJIT column in §1 plus the remaining dispatch-floor
  difference (≈ 25 − 9 per op until item 6).
- **Whole programs.** `bench/opprobe/abench.sh BASE NEW`: tier-0 and JIT instruction
  counts over all 31 `@bench` programs. No row may regress beyond noise
  (±0.05% tier-0). `pairs_hash`, `field_hash` and `tbl_ops` are the P1/P2
  witnesses. They are measurement points, not targets (Rule Z-6).
- **Gates per phase.** `just test`, `zig build test -Djit-debug=true`,
  `just hashgate`, `just embed-test`, `zig build wasm`, and viz under bun.

## 9. Open questions for Bart

- **Q1 — strategy per fused form (§4).** Options:
  - A everywhere;
  - B everywhere;
  - A for the forms with a small JIT surface (`itern`, field ops,
    constant arith, `eqk`) and B for compare-and-branch;
  - A everywhere, with the §5.4 `condBranchOf` predicate refactor landed
    first as its own commit.
- **Q2 — constant-operand arithmetic (§5.3).**
  - (i) int immediates;
  - (ii) K index for any number;
  - both;
  - in each case, with or without constant-on-the-left forms.
- **Q3 — compare-and-branch coverage (§5.4).**
  - register-register only (LuaJIT);
  - plus equality against constants;
  - plus ordered compares against a constant (`jltk`).
- **Q4 — `itern` shape (§5.1).**
  - (a) LuaJIT's prediction plus a despecialization patch; its restore
    equivalence is open;
  - (b2) a guarded iterator op that replaces the `move`s and the `call`
    and converges on `tfor_loop`. Rev 1's shape (b) is withdrawn.
  - (c) an `opCall` fast path with no bytecode change.

  Within (b2): either decline while the hash view needs a build, or build
  it in the fast lane and park OOM.
- **Q5 — phase order (§7).** As listed, or something else.

## 10. Round-1 review (2026-10-21)

Codex (`docs/reviews/doc66/codex-r1.md`) and antigravity
(`docs/reviews/doc66/antigravity-r1.md`) did read-only reviews of rev 1
(7d32e84). Rev 2 makes these corrections:

| finding | from | rev 2 |
|---|---|---|
| B's GC skip is unsound (`gc_stress`, a failed reservation stays due) | codex B1 | §4.2 rule 1: re-test `shouldCollect()` |
| B is off whenever a region profit map exists | antigravity B2 | §4.2 rule 4, §4.3 |
| `itern` (b) has three successors, needs range edge kills, bypasses the gate and `tfor_loop` accounting | codex B2, antigravity B1 | (b) withdrawn; (b2) added |
| commutative swap reorders metamethod arguments | codex B3 | §5.3 |
| `itern` must decline grids (or deflate) | codex B4, antigravity S1 | §5.1 |
| `nextLive` can allocate and fail | antigravity S3 | §5.1, decline-or-park option |
| field helpers take a key register | codex S4, antigravity S4 | §5.2 |
| `condBranchOf` decodes, callers keep their restrictions; recorder helpers | codex S5, antigravity S5 | §5.4 |
| `describeFault` reads `c` as a register | antigravity S6 | §4.1 |
| inventory gaps: two-edge CFG, `loopGateOf`, entry registry, call-site consumers, table constructors, `jmp_if_not_nil`, loop-check lines | codex S1, antigravity nits | §4.1 |
| the "replay runs `.full`" claim was too broad; the stale `repeat`-closer patch example | codex S2 | §4.2 rules 3, 6 |
| shape (a)'s restore equivalence is unproven | codex S6 | §5.1, §6.3 |
| constant `==` on numbers needs numeric lanes | codex nit | §5.5 |
| "minus one IR `konst`" was wrong | codex nit | §5.3 |
| the probes live in `/tmp` | codex nit | P0 |

Where the reviewers agree and disagree on the open questions:

| | codex | antigravity |
|---|---|---|
| Q1 | A, `condBranchOf` refactor first | A everywhere, `condBranchOf` first |
| Q2 | K-index first, keep the constant-left orientation; immediates only if measured | int immediates first; no constant-left in v1 |
| Q3 | register-register + constant equality + ordered constants | register-register + constant equality |
| Q4 | revised (b), which is (b2) here | (b), with the grid and encoding fixes |
| Q5 | P2 → P3 → P5 → `condBranchOf`/P4 → P1 | as proposed: P1 → P2 → P3 → P5 → P4 |

## 11. References

- LuaJIT: `src/lj_bc.h` (op set), `src/lj_parse.c` `predict_next` /
  `parse_for_iter`, `src/vm_x64.dasc` `BC_ISNEXT` / `BC_ITERN`,
  `src/lj_record.c` `rec_itern` / `rec_isnext`.
- Doc 20 (copy-on-patch entry images), doc 42 §4.2 (the normative
  dispatch prologue), doc 58 (loop markers and `loopExtentFor`), doc 62
  (slot hints), doc 64 (the chain machinery the shape matchers feed).
- TODO.md "Tier-0 interpreter cost survey".
