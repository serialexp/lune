# 66 — Bytecode forms: constant operands, field ops, compare-and-branch, ITERN

Status: draft, not yet implemented. Decisions Q1–Q5 (§9) are open for Bart.
Owner: claude (coral-marten)
Last updated: 2026-10-21

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole phases to Done once everything inside them is checked.

### Done

- [x] **Diagnosis** (2026-10-21, §1). Per-op marginal instructions against
  LuaJIT `-joff`, after the item 1–3 tier-0 fast paths (d40cf2d). The
  probes are in `/tmp/t0micro/ops3.lua` and `opsmeasure3.sh`.
- [x] **Consumer inventory** (§4.1). Lists every place that switches on
  bytecode ops or pattern-matches compiler output.

### Outstanding

- [ ] **Q1 — strategy for the fused forms** (§4): new canonical opcodes,
  handler-level fusion over unchanged bytecode, or a mix per form.
- [ ] **Q2 — constant-operand arithmetic shape** (§5.3): immediate ints in
  `aux`, or a K index, and whether constant-on-the-left forms are included.
- [ ] **Q3 — which compare-and-branch forms** (§5.4).
- [ ] **Q4 — the `pairs` fast path's shape** (§5.1).
- [ ] **Q5 — phase order** (§7).
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
- **Slow-path table.** `interp.zig` `buildSlowTable`. A fast handler that
  leaves through `slowTail` without an entry lands on `noSlowPath`, which
  panics.
- **Recorder.** `trace_recorder.zig` `recordOne`, where `else` is
  `abort(.nyi_opcode)`. A missed arm means silent loss of JIT coverage, not
  a build error.
- **Operand decoding outside the handler.** `interp.zig` ~2009, the
  error-message operand pick (`firstNonNumber`, the indexed object), which
  assumes register operands. `bytecode.writeInstr`, the disassembler that
  viz shows through `wasm_entry.buildDisasmBlob`.
- **Compiler-shape matchers.** These matter only for compare-and-branch,
  because they name `jmp_if_false`/`jmp_if_true` as "the branch":
  - `bytecode.loopExtentFor` and `assertLoopClosersWellFormed`, which check
    the `while` and `repeat` condition branches;
  - in `trace_code.zig`: `computeOwnLoopTest` (a loop's own test), and the
    branch-source checks in `classifyBridgeCandidate` and
    `CompositeWalk.init`;
  - `trace_exit_attach.resumeOf`, which resumes a branch guard on the
    untaken edge (the `rec_comp_fixup` analogue), and
    `continuationReachesEnclosingBackEdge`;
  - the "wants prime side" check in `trace_link.zig` (~446), the sibling
    handoff branch-op check in `trace.zig` (~1853), and `recBranch`'s
    LLEAVE detection;
  - `trace_finalize.phiLiveRow`, through `CompositeWalk`.

  Missing one of these does not fail the build. It quietly turns a loop
  test into an ordinary branch, which unpatches entries or loses
  bridges. Doc 64's machinery is exactly what would degrade.
- **Generic-`for` shape.** `loopExtentFor`'s `.jmp` arm scans the test
  block for `move`/`call` up to the `tfor_loop`. A new op in that block must
  be accepted there, or region topology and `linkKindAt` fail closed.

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

1. **GC check.** It may skip this only because neither instruction
   allocates: debt does not change between the two checks, so the second
   cannot collect if the first didn't. Every fused pair must be checked
   allocation-free. A `get_index` on a grid deflates it (doc 14,
   `indexGet`), which allocates. So a fused `load_const` + `get_index`
   fuses only on the allocation-free lane, `heapKeyChainGet`, which
   declines grids, and otherwise dispatches the `get_index` normally.
2. **`safepoint_seq`.** Bump it once more, so step counts are unchanged.
3. **Replay lines, suspend, recording close, continuation and replay-side
   activation, recording mirror.** These are `.full`-only, so B fuses
   only in `.fast` mode. Replay runs in `.full` and never sees a fused
   step.
4. **Region departure observer.** Fuse only while the region counter is
   zero. That is the same `cmpl` the prologue already does. With regions
   live, the handler dispatches normally.
5. **`frame.pc`.** Stored for the second pc as the prologue would. An
   error raised by the second instruction must report its own pc.
6. **Entry patches.** The fused handler reads the next instruction from the
   running code image. A patched instruction (`jloop` over a `repeat`
   closer, `jcont`) is not the expected partner, so the pair does not fuse
   and the patch runs. No extra check is needed.

B's limits:

- It cannot remove the store of the temporary, the constant's
  `load_const`/`load_int` store, or the second fetch.
- Each first-op handler gains a peek-and-branch even when it doesn't
  fuse.
- Rule 4 means regions-live programs, which are most traced programs,
  fuse less.

### 4.3 Where each fits

| form | A cost | B cost | B saves |
|---|---|---|---|
| `get_field`/`set_field` | small: recorder takes the key from K; `bc_liveness` arm | allocation caveat (§4.2 rule 1) | one dispatch, not the K store |
| constant-operand arith | small: recorder emits `konst` | gains little: the constant store stays | almost nothing |
| compare-and-branch | large: ~12 shape matchers (§4.1) | none in the JIT | one dispatch |
| `eq` against a constant | as arith if no branch; as compare-and-branch if fused | as compare-and-branch | one or two dispatches |
| `itern` | moderate (§5.1) | not applicable (no adjacent pair) | — |

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

Mahina doesn't need the slot index. The hash part's view already resumes
in O(1) from `iter_pos`, and the array part steps by index. The cost is
all protocol. Three shapes:

- **(a) LuaJIT's.** The compiler predicts by name; an `isnext` op
  despecializes into the per-VM copy-on-patch image (doc 20). Canonical
  `Proto.code` is never mutated, so keyframe restore re-compiles to the
  speculative form, and the first entry despecializes again,
  deterministically. It needs a new kind of patch, since today's patches
  are trace entries, and two ops.
- **(b) A guarded prefix, no prediction and no patching.** Every generic
  `for` gets one op at the top of its test block:

  ```
  test: itern b, n, aux → body
        move …; move …; move …; call b+3, 2, n; tfor_loop b → body
  ```

  `itern` checks that `R[b]` is the `next` builtin and `R[b+1]` is a table
  or `row_view`. If so it runs the step inline, writes `R[b+2]` (control)
  and `R[b+3..b+3+n)`, and jumps to the body, or past the `tfor_loop` at
  the end. Otherwise it falls through to the unchanged generic path. The
  check is a few instructions per step. Other iterators (`ipairs`,
  `gmatch`, closures) pay one extra failed check per step.
- **(c) A fast path in `opCall`** for "callee is `next` and the call is a
  `tfor` test block call". No bytecode change, but the three `move`s and
  the dispatches stay, so it saves less than (b).

What every shape must keep:

- **Errors.** `next` on a non-table, or a key that is not in the table,
  must give today's message. (b) gets this for free: `itern` declines and
  the generic call raises.
- **`frameShape`/`nativeSite`.** These require `code[pc-1] == .call` for a
  native frame. The fast path never pushes a native frame, so they are
  untouched.
- **Mutation during traversal.** The fast path calls the same
  `nextStepAny`, so assigning to existing fields, clearing them, or
  inserting keys (which invalidates the view) behaves exactly as `next`
  does.
- **Liveness.** `effectOf` gains an `itern` arm with two successors. It
  uses `b..b+2` and kills `b+2..b+3+n` on the taken edge.
- **`loopExtentFor`.** Its generic-`for` scan accepts `itern` before the
  `move`s.
- **Recorder.** When `itern` takes the fast path, the recorder aborts.
  Today it aborts at the `next` call with `.host_barrier`, so coverage is
  unchanged; the new abort gets its own reason, so `--dump-aborts` counts
  it. When `itern` falls through, the recorder records nothing for it, but
  only if the callee guard on the following `call` implies "not `next`".
  Otherwise it emits an identity guard. This is the one soundness argument
  P1 has to pin with a test: a traced `gmatch` loop whose iterator becomes
  `next` must exit, not run the gmatch path.

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
- Recorder: `hashGetShape`/`hashSetShape` need the key as a `konst`.
  Today that is the `load_const`'s IR ref; with the new forms it is
  `konst(K[aux])`, which is the same IR.
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
- **Constant on the left** (`1 - x`, `2 / x`; LuaJIT `SUBNV`). Commutative
  ops can swap operands in the compiler. `sub`/`div`/`mod`/`idiv` would
  need their own forms. LuaJIT has them; whether we need them is a probe
  question.

The fast lanes are item 3's: raw int and float math, with metamethods, a
zero divisor and mixed types going to the slow half. The recorder emits
`konst` for the operand, the IR it already gets from `load_int`. That
gives the same traces, minus one IR `konst` per site, which CSE already
merges.

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
or `load_const`, then `eq`, then usually a branch. Primitives and
interned strings compare by tag and bits, so the fast lane is a single
compare against the constant's bits. Strings are interned, so equal
contents means the same object. This is P4's branch form with a constant
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
  only (the iterator's identity at loop entry). It lives in the per-VM
  image, never in canonical code.

## 7. Phasing (Q5)

Suggested by payoff per effort. Each phase is a slice of the end state
(Rule Z-7), gated and measured on its own:

1. **P1 `itern`.** Largest per-use gap (459 against 17) and fully
   localized: compiler generic `for`, one handler, liveness,
   `loopExtentFor`, recorder abort/fallthrough.
2. **P2 `get_field`/`set_field`.** The most frequent construct. Small JIT
   surface.
3. **P3 constant-operand arithmetic.** Frequent and small.
4. **P5 `eq` against a constant.** Moderate payoff, cheap once P3's
   K-operand plumbing exists.
5. **P4 compare-and-branch.** High frequency, but strategy A has the
   largest JIT surface of all the phases.

## 8. Measurement

- **Per-op probes.** `/tmp/t0micro/ops3.lua` with `opsmeasure3.sh`
  (`P=…`, `PROBES=…`, `M=binary`), against LuaJIT `-joff`. The target for
  each form is its LuaJIT column in §1 plus the remaining dispatch-floor
  difference (≈ 25 − 9 per op until item 6).
- **Whole programs.** `abench.sh BASE NEW`: tier-0 and JIT instruction
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
  - (a) LuaJIT's prediction plus a despecialization patch;
  - (b) a guarded prefix on every generic `for`;
  - (c) an `opCall` fast path with no bytecode change.
- **Q5 — phase order (§7).** As listed, or something else.

## 10. References

- LuaJIT: `src/lj_bc.h` (op set), `src/lj_parse.c` `predict_next` /
  `parse_for_iter`, `src/vm_x64.dasc` `BC_ISNEXT` / `BC_ITERN`,
  `src/lj_record.c` `rec_itern` / `rec_isnext`.
- Doc 20 (copy-on-patch entry images), doc 42 §4.2 (the normative
  dispatch prologue), doc 58 (loop markers and `loopExtentFor`), doc 62
  (slot hints), doc 64 (the chain machinery the shape matchers feed).
- TODO.md "Tier-0 interpreter cost survey".
