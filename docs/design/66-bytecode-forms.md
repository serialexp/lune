# 66 — Bytecode forms: constant operands, field ops, compare-and-branch, ITERN

Status: rev 2, all five phases landed. The `condBranchOf` refactor, P2, P3,
P5, P4 and P1 are on master; follow-ups and deferrals remain (Outstanding).
Round-1 review findings
(codex and antigravity, §10) are folded in. Bart answered Q1–Q5 (§9) on
2026-10-22.
Owner: claude (coral-marten)
Last updated: 2026-10-23

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
- [x] **Q6 — P3 constant-left encoding and op set** (§5.3). Bart,
  2026-10-22: separate NV opcodes (LuaJIT `ADDVN`/`ADDNV`, no orientation
  bit). K forms for add, sub, mul, div, mod, idiv and pow in both
  orientations, and for band, bor, bxor, shl and shr with the constant on
  the right only. A static count over the `@bench` sources before the
  choice: 164 constant-operand sites, 43 of them constant-left (`*` 19,
  `+` 9, `/` 7, `^` 4).
- [x] **`condBranchOf` refactor** (2026-10-22, §5.4). `bytecode.condBranchOf`
  decodes a conditional branch (`CondTest`, polarity, target) and
  `falseBranchTargetOf` names the `while` test and `repeat` closer shape.
  Every §4.1 shape matcher calls them instead of naming `jmp_if_*`:
  `loopExtentFor`, `assertLoopClosersWellFormed`, `computeOwnLoopTest`,
  `classifyBridgeCandidate`, `CompositeWalk.init`, `resumeOf`,
  `continuationReachesEnclosingBackEdge`, the prime-side and sibling
  branch checks, and `recBranch` (polarity and LLEAVE). Each keeps its own
  admission: `jmp_if_not_nil` is still accepted only where it was.
  Op-semantic switches (`handlerFor`/`opJump`, `effectOf`, the
  disassembler, `recordOne`'s dispatch) still name the opcodes. No
  behaviour change: `--dump-native` and `--jit-stats` counts are
  identical to HEAD on all 33 `@bench` programs with helper addresses
  masked.
- [x] **P2 — `get_field` / `set_field`** (2026-10-22, §5.2). Ops `get_field A B C`
  (`R[A] = R[B][K[C]]`) and `set_field A B C` (`R[A][K[B]] = R[C]`), the K
  operand an interned-string constant. The compiler emits them for
  `t.name`, `t.name = v`, a literal-string `t["k"]`, method lookups, the
  `function a.b.c()` path and compound field stores (`IndexKey`,
  `indexKeyOf`). The handlers share the d40cf2d heap-key fast paths; the
  recorder takes them through `KeyOperand` (`.reg` | `.konst`) into the
  existing hash shapes; `bc_liveness`, the disassembler and the replay
  effect list name them. Per-op probe (`fields.lua`, instructions per op,
  before → after, LuaJIT `-joff` in brackets): fget 128 → 89 (29), fset
  125 → 87 (32), mlook 213 → 173, mcall 711 → 671. `abench.sh` tier-0:
  field_hash −22.3%, nbody −14.2%, array3d −6.6%, io_write −2.9%, lua54
  −0.7%, everything else within ±0.01% except compile_multret_chain +0.07%
  (one extra instruction per call in `bc_liveness.effectOf`'s by-value
  return, LLVM codegen). JIT tier: array3d −0.9%, nbody −0.1%;
  euler14-bit, spectral-norm, repack and while_shortcircuit_probe
  +0.2–0.6% on the native (AVX-512) build but within ±0.02% on an
  x86_64_v3 build except the probe (+0.4%, the accessor below). The
  pinned board arbitrates. hashgate: 99 digests match on both legs.
- [x] **Inlined-callee branch guards were decoded against the anchor
  proto** (found during P2, fixed in the same change). A guard's aux is
  the recorder's post-increment pc in the proto it was recorded in, but
  every loop-test, branch and bridge classifier indexed `anchor.proto.code`
  with it, inlined callee or not. P2 shortened an iterator by one op, so
  its `jmp_if_false` landed on the same pc as the anchor's own, and
  array3d paid a "want PRIME side" on every row wrap (+6.3% JIT
  instructions; the output stayed right). `TraceCode.anchorSourcePc`,
  `anchorSourceInstr` and `anchorCondBranch` now answer only for
  anchor-frame guards (`isAnchorFrameGuard`: provenance inline depth 0,
  not a link terminal), memoised at commit as the `off_frame` bitset;
  every classifier goes through them. Test: "doc 66 P2: an inlined
  callee's branch guard is never decoded against the anchor proto"
  (tier-1a and native, mutation-checked).

- [x] **P3 — constant-operand arithmetic** (2026-10-22, §5.3, Q6). 19
  opcodes: `add_rk`/`add_kr` (`R[A] = R[B] op K[C]` / `K[C] op R[B]`, the
  register always B and the constant always C) and the same for sub, mul,
  div, mod, idiv and pow; `band_rk`, `bor_rk`, `bxor_rk`, `shl_rk` and
  `shr_rk`. `bytecode.arithFormOf` decodes every arithmetic op to
  (base operator, `rr`/`rk`/`kr`) and `constantFormOf` is its inverse;
  `bc_liveness` and fault rendering (`describeFault`) follow. The
  compiler emits a K form when either operand is a number literal (a
  parenthesised or negated one too), constant-right first, through
  `compileBinary` and every compound-assignment path (`emitCompoundOp`).
  The handlers are built per opcode over one `ArithOperands` reader, so
  metamethods see the operands in source order. The recorder takes the
  constant as a `konst` (`Operand`, renamed from P2's `KeyOperand`), so
  the IR is the IR `load_int` + op produced.
- [x] **P3 extended: the arithmetic lanes** (beyond the plan, same change).
  Every handler, register form included, now computes mixed int/float
  `+ - * /` on the lanes (both as floats, as `arith` does), pow on any
  two numbers through `fmath.powRuntime`, mod/idiv on any non-both-int
  number pair in the slow half, and shifts in the both-int lane
  (`arith.shiftLeft`/`shiftRight`/`shiftRightArith`, now `pub`). Before,
  each of these went through `arith.*` + `arithMeta`. The operands' tags
  are read up front and their payloads behind pointers, so a lane loads
  only what it uses: the first cut loaded both payloads eagerly, which
  cost the register-form float handlers 1–3 instructions (nbody +0.5%
  tier-0) until the load could fold into the arithmetic again.
- [x] **P3 measured** (`ops3.lua`, instructions per op, e4ba1e2 → P3,
  LuaJIT `-joff` in brackets): `i - 7` 73 → 50 (15), `7 - i` 73 → 50
  (15), `i * 0.5` 109 → 73 (15), `x + 2.5` 83 → 53 (15), `x ^ 2` 285 →
  257 (163), `i << 3` 84 → 58, `i & 7` 75 → 52; the register forms
  `x * x` 51 → 49, `x / x` 46 → 46, `i * i` 48 → 46, and the empty
  loop's own `s = s + i` 128 → 126. `abench.sh` tier-0: pi_leibniz
  −27.9%, euler14-bit −16.3%, nsieve-bit −10.7%, spectral-norm −10.1%,
  while_shortcircuit_probe −7.9%, partialsums −7.4%, scimark-fft −6.8%,
  scimark-sor −5.4%, recursive-fib −5.1%, repack −4.4%, array3d −3.9%,
  nsieve-bit-fp −3.3%, lua54 −3.1%, io_print −2.9%, nbody −1.7%, the
  rest −0.05 to −2.6%. The one rise, io_write +0.08% in both tiers
  (+1 instruction per `io.write`), is an LLVM register-allocation shift in
  `nativeIoWrite` (which inlines `coerceConcat`): one more stack spill in
  its per-argument loop, same calls and same control flow. An earlier
  version of this bullet, and the P3 commit message, blamed doc 68 P0's
  `CF_CTL` store. A d0b815e build with P0 backed out still measures the
  +1, so P0 is not the cause. JIT tier: euler14-bit
  −5.1%, lua54 −3.1%, io_print −2.8%, while_shortcircuit_probe −1.9%,
  tbl_ops −1.5%, str_format −1.1%, the rest 0 to −0.7%. `--dump-aborts`
  NYI counts are unchanged on all 33 programs; hashgate: 99 digests match
  on both legs. Test: "doc 66 P3: every constant arithmetic form is its
  register form", 12 operators × 8 constants × both sides × 13 operands
  against the register form, with a digest of every result taken on
  e4ba1e2 (before the new lanes). Mutation-checked: the mixed lane, `kr`
  operand order, the shift lane, mod's float lane, pow and div each
  change it.
- [x] **Q7 — P5 encoding** (§5.5). Asked 2026-10-22; Bart was away, so
  taken by default and open to reversal: the LuaJIT split
  (`ISEQP`/`ISEQS`/`ISEQN`), following Q6's precedent of separate
  opcodes. The alternatives were one `eq_k`/`ne_k` pair over any K, or
  `eq_n` plus one nil/boolean/string form. Static count over the `@bench`
  sources: 17 equality sites, 15 against a constant (10 strings, 3 nil,
  2 numbers), 14 of them conditions (P4's branch form takes those).
- [x] **P5 — equality against a constant** (2026-10-22, §5.5, Q7). Six
  opcodes: `eq_p`/`ne_p` (`R[A] = R[B] == P(C)`, `C` a `bytecode.Prim`
  immediate: nil, false, true), `eq_s`/`ne_s` (an interned-string K),
  `eq_n`/`ne_n` (a number K). `bytecode.eqFormOf` decodes every equality
  (`negate`, right operand `reg`/`prim`/`str`/`num`), `eqOpOf` is its
  inverse and `eqConstant` reads the constant. The compiler emits them
  for a nil, boolean, string or number literal on either side: `__eq`
  never fires against a constant, so `nil == x` is `x == nil` with the
  same evaluation order, and no `_kr` forms exist. No handler can fault:
  `eq_p` tests the tag (and truth, as `asBool` does), `eq_s` identity
  (strings are interned), `eq_n` the same number type on the raw lanes
  and the other one in `opEqNSlow` (`compareNumeric`), which keeps the
  fast half's frame free of callee-saved registers (45 → 42 on `i == 7`).
  The recorder's `recEq` takes P3's frame (renamed `BinaryFrame`), so the
  constant arrives as a `konst` and the IR is the IR `load_*` + `eq`
  produced. Per op (`ops3.lua`, d0b815e → P5, LuaJIT `-joff` in
  brackets): `local b = x == nil` 66 → 33 (30), `x ~= false` 70 → 36
  (25), `x == "x"` 78 → 36 (33), `i == 7` 68 → 42 (32), register `x == y`
  43 → 43; as conditions, `if x == nil` 100 → 67 (16) and `if x == "x"`
  112 → 70 (19), the rest of those gaps being P4's. `abench.sh` tier-0:
  lua54 −2.2%, scalar −2.1%, nsieve-bit −1.35%, str_manip −0.65%,
  array3d −0.54%, every other row within ±0.04%. JIT: lua54 −2.2%,
  recursive-fib −0.2%, and repack +0.09%, scimark-lu +0.03%, array3d
  +0.02%. repack's is pc layout, not P5: its only equalities run once at
  top level, the trace set and iteration counts are identical, and padding
  the program with no-op statements moves the same binary by up to 0.15%
  and flips the P3→P5 delta's sign (TODO.md). `--dump-aborts` NYI counts
  unchanged on all 33 programs; hashgate 99 digests match on both legs.
  Tests: "doc 66 P5: equality against a literal compiles to a constant
  form" (compiler), "doc 66 P5: equality against a constant is
  `Value.eql` against it" (ten legs, a digest taken on e4ba1e2 over every
  value class × nil/booleans/strings/numbers on both sides, plus hot loop
  conditions; no recording aborts at an equality op). Mutation-checked:
  `eq_p`'s false case, `eq_s` identity, `eq_n`'s float lane and its slow
  half, and the recorder's immediate decoding each change it.
- [x] **P4 — compare-and-branch** (2026-10-22, §5.4, Q3). Twelve
  opcodes: `jlt`/`jle`/`jgt`/`jge`/`jeq` over two registers, `jlt_k`/
  `jle_k`/`jgt_k`/`jge_k` against a number K, and `jeq_p`/`jeq_s`/`jeq_n`
  against a primitive, string or number constant. `a` carries the polarity
  (`cmp_on_true`) and `cmp_k_left`, `aux` the offset; `~=` is `jeq` with
  the polarity flipped, and `not (cmp)` flips it as well. `bytecode.cmpBranchOf`
  decodes them, `cmpBranchOp` is its inverse, and `condBranchOf` reports
  them as a `.compare` condition (`CondBranch.onFalseCondition`). `if`,
  `while` and `repeat … until` emit them through `compareBranch`; any
  other condition keeps `jmp_if_false`. The handlers share the value
  forms' lanes (`eqLanes`, `eqNumLane`, `orderLanes`), returning a
  `Lane` enum: the first cut returned `?bool`, which LLVM spilled through
  the stack, and the value forms lost 3–5 instructions until the enum.
  The recorder (`recCmpBranch`) emits the compare IR and a `.branch_cond`
  guard on it (`branchOn`), so the IR is what compare + `jmp_if_*` gave.
  Per op (`ops3.lua`, 4f08b76 → P4, LuaJIT `-joff` in brackets):
  `if i > n` 73 → 43 (23), `if x == nil` 67 → 39 (16), `if x == "x"`
  70 → 40 (19), `if i < 0` 98 → 49 (32), `if 0 >= i` 98 → 49 (32),
  `if not (i <= n)` 107 → 43 (23), float `if x < y` 74 → 45 (23),
  `if x == y` 77 → 44 (24); the value forms are unchanged (`x == nil` 33,
  `i == 7` 42, `x == y` 43, `lt` 39, `eq` 43). `abench.sh` against
  4f08b76, on the commit content (which bundles coral-raven's doc 68 P1
  slice 1), tier-0: nsieve-bit-fp −9.8%, recursive-fib −6.4%, pi_leibniz
  −6.0%, lua54 −1.7%, nsieve-bit −1.6%, scalar −1.6%, binary-trees −1.5%,
  array3d −1.0%, scimark-fft −0.9%, str_manip −0.8%, euler14-bit −0.6%,
  str_format −0.3%, scimark-lu −0.1%; compile_multret_chain +0.04%, the
  rest within ±0.02%. JIT: pi_leibniz −7.9%, nsieve-bit-fp −2.3%, lua54
  −1.7%, recursive-fib −1.7%, nsieve-bit −1.3%, scimark-fft −1.1%,
  euler14-bit −0.9%, scimark-lu −0.6%, str_format −0.3%, str_manip −0.2%,
  binary-trees −0.2%, scimark-sor −0.1%; while_shortcircuit_probe +0.11%
  (+1.2k instructions on 1.09M with identical tiering, compile cost),
  compile_multret_chain +0.03%, repack +0.02%. `--dump-aborts` NYI counts
  unchanged on all 33 programs. Tests: "doc 66 P4: a comparison test
  compiles to one compare-and-branch" (compiler), "cmpBranchOf and
  cmpBranchOp are inverses" (bytecode), "a compare-and-branch is its
  compare followed by the branch" (a matrix over every relation, operand
  order, polarity and value class, the digest taken on 8eee20c, LuaJIT
  agreeing on the numeric line), "a compare-and-branch fault names its
  operands in source order", and "a compare-and-branch is still a
  composite bridge candidate" (exit side). Mutation-checked: the float
  lane's strictness, the `>`/`>=` swap, `eq_n`'s mixed lane and slow half,
  the table-equality lane, the `cmp_k_left` fault order, the compiler's
  mirrored relation and the recorder's observed outcome each fail a test.
- [x] **P4's two JIT prerequisites** (beyond the plan, landed first). The
  first P4 cut left two JIT rows above noise, neither in P4's own code:
  - nsieve-bit +0.37%: a fused branch's exit-side snapshot re-executes the
    compare, so the compared temporary stays live past it, operand
    coalescing failed and the bool spilled. 4744457 lowers a compare read
    only by the guard after it to `cmp` + `jcc` (`Loc.flags`), as LuaJIT's
    comparisons are guards; that alone is −12% to −2% JIT across the
    numeric rows.
  - binary-trees +0.46%: `hasTrace` missing-key probing in `AnchorMap`,
    whose walk length moved with the new pc layout. 4f08b76 runs those
    maps at 50% load (TODO.md, pc layout).
- [x] **Float text at the extremes** (found by the P3 test, fixed in the
  same change). `print`, `tostring` and `..` rendered a float
  positionally at any magnitude, so `1e308 / 3` ran to 309 digits and
  overran `tostring`'s fixed buffer (a Debug panic; undefined in
  release). Bart chose exponent form at the extremes: `io.formatFloat`
  keeps the shortest round-trip digits, positional for
  `1e-7 <= |x| < 1e21` and `3.333333333333333e+307` / `5e-324` outside,
  bounded by `io.float_text_max`. One renderer behind all three.
- [x] **P1 — `itern`** (2026-10-23, §5.1, Q4 shape (b2)). The generic-`for`
  test block is `itern a, c; tfor_loop`, where `itern` stands for `move
  a+3,a; move a+4,a+1; move a+5,a+2; call a+3, 2, c`.
  `bytecode.callOperandsOf` decodes the call either one makes for every
  call-site consumer: `nativeSite`, `frameShape`, `frameMask`,
  `describeFault` and the liveness call-layout check. `loopExtentFor`
  accepts only that test block.
  - Lanes: `opItern` steps `next` over a non-grid table's array part
    call-free, and ends the traversal at an empty hash part. `opIternSlow`
    takes the hash part, once its view is built, and a `row_view` through
    `stdbase.iternStep` (`nextStep(.no_alloc)`, which declines with
    `error.WouldAllocate` while `live != 0 and !iter_valid`). Anything else
    runs the moves, then `callTail`, `.call`'s body shared through
    `inline`.
  - The recorder aborts on the `next` lane (`.itern_next`). Otherwise it
    records the three moves and `recCall` over the synthesized call.
  - As built, against the plan in §5.1: the liveness kill set is
    `a+3 .. a+3+c` (below), and the recorder runs `recCall` on a scratch
    copy of the register window (below).
  - Per op (`ops3.lua`, 98aef7f → P1, LuaJIT `-joff` in brackets): hash
    `pairs` step 454.6 → 256.4 (16.7), array `pairs` step 393.7 → 59.8
    (10.3), `ipairs` step 353.7 → 306.2 (61.9).
  - `abench.sh`-style instruction A/B against 98aef7f, both tiers:
    pairs_hash −30.6% / −29.2%, str_gmatch −3.7% / −1.2%, array3d −0.55% /
    −0.12%, while_shortcircuit_probe −1.1% / −0.8%, compile_multret_chain
    −4.1% / −4.1%; every other row within ±0.02%, and outputs are
    identical. The compile_multret_chain change is the `effectOf`
    codegen swing below, not `itern`.
  - Two codegen traps, found by that A/B before commit:
    - `callTail` first took the operands as a by-value struct. LLVM then
      held them in registers across `.call`'s whole body: recursive-fib
      +0.28%, scalar +1.2% tier-0. `callA`/`callB` re-read `instr` at each
      use, as `.call` always did, and the call rows are back to ±0.00%.
    - An inline `.itern` arm in `bc_liveness.effectOf` made it spill on
      every instruction (compile_multret_chain +0.26%). Out of line
      (`iternEffect`), `effectOf` compiles to under half its size (TODO.md).
  - **A pre-existing GC bug, found by the `row_view` test and fixed in the
    same change.** `forEachKeptRegister`, the doc 61 register root walk,
    rooted only `heap_ref`-tagged registers. So a register holding a
    `row_view` did not keep its parent grid alive, unlike
    `Heap.markValue`. A row whose grid was otherwise dead was swept under
    it, and the next `next` read freed cells: a Debug panic, undefined in
    release. On 98aef7f the `row_view` test's GC-stress legs crash through
    the `next` native. The walk now roots the parent of a `row_view` too.
  - `--dump-aborts` NYI counts are unchanged on all 33 programs.
    pairs_hash's `host_barrier` at the `next` call is now `itern_next` at
    the `itern`, and str_gmatch's trace exit snapshots shrank from 40 slots
    to 28.
  - Tests:
    - "doc 66 P1: a generic `for` steps with one `itern`" (compiler);
    - `loopExtentFor` over the new block (bytecode);
    - in the semantics matrix: "`itern` steps a table exactly as the
      `next` native does", whose digest was taken on 98aef7f, covering
      array, hash, holes, mutation, absent keys, grids and every `c`;
    - "`itern` steps a host's `row_view` as `next` does". A program sees
      a `row_view` only from a host, because indexing a grid and `ipairs`
      deflate it, so a test native hands one over;
    - "any other iterator is the call `itern` replaced", covering
      closures, gmatch, `__call`, bad arguments and non-callables, with
      the 98aef7f messages;
    - "one generic `for` traced with `gmatch` keeps its trace across
      `pairs`", the §5.1 soundness test.
- [x] **The hash-part step on the call-free lane** (follow-up to P1,
  2026-10-23). A hash `pairs` step was 247 instructions against
  LuaJIT's 17: it left `opItern` for `opIternSlow` and
  `stdbase.iternStep`'s generic walk. `opItern` now takes `nextLive`'s
  usual step itself when the view is built and the control is the key
  it returned last (`HashPart.isLastReturned`, `liveFrom`): 64. The
  first hash key and every other control still leave. pairs_hash −42.5%
  tier-0, −39.6% `--jit-native`, no other row moved. Inside `opItern`
  but shaped as a check on the control, the array lane stayed at 54
  instructions; a fuller `nextLiveBuilt(?Value)` there cost it +8.
- [x] **`ipairs` through `itern`** (follow-up to P1, §5.1's last
  paragraph, 2026-10-23). `ipairs` was 270 instructions a step against
  LuaJIT's 62; it is now 92.6. A per-step identity check for a second
  builtin in `opItern` cost str_gmatch's iterator 0.15–0.46%, so the
  identity is a byte instead. `Native.itern` (`function.IternLane`) is
  set from the registry row, and `opItern`, after testing for `next`,
  leaves through a table indexed by it (`iternLaneTail`): `.call` to
  `opIternCall`, `.inext` to `opIternInext`. That load replaces
  `coldTail`'s opcode load, so the other iterators pay nothing.
  `opIternInext` steps a non-grid table with an integer control; a grid
  (the native deflates it), a `row_view` or another control takes the
  call. The extra byte at install cost about 320 instructions per VM
  start, so registry natives are now one comptime `Native` template
  each (`interp.base_templates`, `Heap.newNativeFrom`). Install is a
  struct copy, and a VM start is 2k instructions cheaper than before
  (doc 70's while_shortcircuit cost, −0.27%). No other `@bench` row
  moved. The test found a bug that predates this change: the `ipairs`
  native's `i + 1` overflowed at `math.maxinteger` (a Debug panic,
  wrapped by accident in release). It now wraps as Lua's does, to
  `t[math.mininteger]`. Test: "`itern` steps `ipairs` exactly as its
  native does".
- [x] **Short-circuit conditions and `not` on a truthiness test**
  (follow-ups to P4, 2026-10-23). An `if` or `while` test is now a chain
  of branches (`Compiler.condJumps`, LuaJIT's `bcemit_branch_t/f`):
  `not` flips a link's polarity, `and`/`or` chain their links, and each
  link is a compare-and-branch or a `jmp_if_*` on the operand, so no
  link writes the condition's value. Per test, against the value form:
  `a < b and c > d` 124 → 74 instructions (LuaJIT 44), short-circuited
  on its first link 92 → 38 (23), `a > b or c < d` 144 → 80 (53),
  `not x` 55 → 27 (13), `x and a > b` 110 → 63 (34). Literals are not
  folded, so `while true` keeps its branch above the marker.
  - What a loop test is had to change with it. A `while` chain's last
    link sits right above the marker, but it may be a `jmp_if_true`
    (`while not done`), and an earlier `and` link also leaves the loop.
    `CondBranch.onFalseCondition` is gone, and `falseBranchTargetOf` is
    `loopTestTargetOf`: a condition branch in either polarity, since only
    its position says which way leaves the loop. The new
    `bytecode.whileTestMarkerOf` names the loop a leaving link belongs
    to. `TraceCode.computeOwnLoopTest` and the recorder's LLEAVE check
    (`leavesAnchorLoop`) ask it, where they used to ask "is the next
    instruction the marker".
  - A/B: tier-0 while_shortcircuit_probe −4.0%; no other row moved, in
    either tier, because no other `@bench` program has a compound test
    in a hot loop. `--dump-aborts` counts are unchanged on every program.
    The probe's `--jit-native` row is +1.9% at its n = 120 (+20k
    instructions, one time), −0.2% at 1200 and −6.2% at 12000. Its loop
    leaves through its first link, which the value form hid behind an
    ordinary branch. As the loop's own test, the exit now takes exactly
    the plain `while i < X` path (event logs identical bar snapshot
    ordinals): its fallback region mints dormant (doc 47 Increment B),
    and the short run ends before admission and silent promotion pay
    back. A first cut that classified only the last link left the first
    link a bridge candidate: 10 failed bridge pipelines, +2.3%.
  - Two tests changed to keep their intent:
    - doc 57's bool-lane test takes `not t[i]` as a value, since as a
      test it is now the load's branch flipped;
    - doc 58 B2's hazard test wraps its `and` in `== true`, which keeps
      the condition temp the hazard needs.
  - Tests: "an `and`/`or`/`not` test compiles to a chain of branches",
    "a `while` test may end on a `jmp_if_true`" (compiler); "every link
    of a `while` test that leaves the loop names its marker" (bytecode);
    in the semantics matrix "an `and`/`or`/`not` test runs its links in
    order, each once" and "loops leave through any link of their test",
    whose outputs were taken on 8b98d64.
- [x] **A call lays its frame out at its destination; `return x` returns
  in place** (2026-10-23, beyond the original plan; doc 69 §3b's "a
  `move` per result"). Lua's `exp2reg` on a fresh slot:
  - `compileCall`/`compileMethodCall` put the function slot at `dest`
    itself when `dest` is the top register and holds no local
    (`isFreshTop`), so `local b = f(i)` is `call r_b` with no result
    `move`. A store into an existing local (`x = f(x)`) keeps its move:
    the call reads the local while it runs.
  - `return e` of one value returns from `operandReg(e)`, so `return x`
    of a local is `ret r_x 1` with no `move`.
  - Probes: call1 408 → 355, `math.abs(i)` 151 → 129, call0 unchanged
    at 284. A/B: no row up in either tier; tier-0 recursive-fib −6.0%,
    scalar −4.7%, str_manip −3.8%, nsieve-bit-fp −3.0%, lua54 −2.5%
    (jit −2.5%), partialsums −2.2%, binary-trees −2.0%, spectral-norm
    −2.0%. `--dump-aborts` sites are unchanged on every program.
  - The new shape put a `ret` right after a recursive call (`local s =
    f(n - 1) return s`), which exposed an existing hang that `f() end`
    already had: doc 44's `.self_terminal` fix, committed first.
  - Four doc 61 register probes read the new layout; their expectations
    follow it, and the dead-φ probe declares `w` first so `peek` still
    reads `s`.
  - Tests: "a call lays its frame out at a fresh destination; `return x`
    returns in place" (compiler); "a call laid out at its destination,
    and `return x` in place, keep every value" (semantics matrix, output
    taken on 2a20e98).
- [x] **`and`/`or` as values: `A and B or C`** (2026-10-23, the follow-up
  to the chains). `local b = i > n and 1 or 2` materialised `i > n` and
  tested the temporary: 110 instructions against LuaJIT's 32. LuaJIT
  compiles it with pending jump lists (`expr_toreg` with `t`/`f` lists).
  Here the idiom gets the same code without them: a falsy `A` is never
  the value of `A and B or C`, because the `or` discards it, so `A`
  compiles to branches straight to `C` (`condJumps`, any `A`). `B` lands
  in the destination and is tested with one `jmp_if_true`, or jumped over
  unconditionally when it is a literal that is always true
  (`isAlwaysTrue`).
  - Alone, `A and B` and `A or B` with a comparison `A` keep the value
    form: branching on `A` would load the `false`/`true` it short-
    circuits to, so neither path gets shorter.
  - Probe: `tern` 110 → 58 instructions at tier 0 (LuaJIT 32); with
    `--jit-native` 16 → 12 an iteration.
  - A/B: lua54 −0.70% on both tiers; no other row moves at tier 0. The
    one JIT row up is scimark-lu +0.04%, inside the bar: every
    `--jit-stats` counter is identical, and the only difference is that
    `lu_factor`'s anchors sit one pc lower (its `m < n and m or n` is one
    instruction shorter), the `AnchorMap` probing lottery 4f08b76 names.
  - Tests: "`A and B or C` compiles `A` to branches straight to `C`"
    (compiler); "`A and B or C` runs each operand once, in order, with
    Lua's values" (semantics matrix, output taken on 2a20e98 and checked
    against LuaJIT).

### Outstanding

- [ ] **Defer: a `sar` constant form.** Q6's set leaves mahina's `~>>`
  (`sar`, no Lua 5.4 spelling, 0 `@bench` sites) on the register form.
- [ ] **Decode inlined branch guards against their own proto** (follow-up
  to the fix above). Today they are simply not classified. An option is
  to carry the guard's proto in provenance, so a callee's own loop test
  can still be recognised. Not needed for correctness.
- [ ] **Bart to confirm the short-circuit change's one probe row**
  (2026-10-23, asked while he was away, default taken). See the Done
  bullet: while_shortcircuit_probe `--jit-native` +1.9% at the bench's
  n = 120, a one-time warm-up the plain `while` already pays.
- [ ] **`repeat … until` with an `and`/`or` test** (follow-up to the
  chains). It keeps the value form: its closer must be the one backward
  branch onto the marker (`assertLoopClosersWellFormed`), and the body's
  `close_upvalues` must run before it, so a chain's earlier links have
  nowhere to jump.
- [ ] **Each phase: recorder and JIT parity in the same change** (§6). A
  new op that the recorder aborts on regresses every traced loop that uses
  it.
- [ ] **Each phase: measured** (§8). Per-op probe, `abench.sh` over every
  `@bench` program in both tiers, and hashgate.
- [ ] **Defer: JIT recording of `itern`** (§5.1). Today a `pairs` loop
  aborts recording at its `itern` (`.itern_next`; `.host_barrier` at the
  `next` call before P1). Recording the
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

**As built (P1, 2026-10-23).** Two points differ from the plan above:

- **Liveness kills `a+3 .. a+3+c`, not `.. a+3+max(c, 3)`.** The fast lane
  writes only the `c` loop variables. When `c < 3`, R[a+3+c .. a+6) keep
  whatever they held, so they are not a must-write and cannot be a kill.
  Nothing reads them: they sit above the loop variables, the body's
  registers start past them, and collection and keyframe capture both
  treat dead slots as dead (scrubbed; tombstoned).
- **The recorder runs `recCall` on a scratch register window.** The
  recorder observes before tier-0 executes the instruction, so at an
  `itern` R[a+3..a+5] still hold the previous step's values, not f, s and
  ctrl. `recItern` copies the window, sets those three slots to R[a..a+2],
  and runs `recCall` over the synthesized `call a+3, 2, c` against the
  copy. The copy is per recorded `itern`, during recording only.

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
  As built (2026-10-22). `a`'s bit 0 is the polarity (`cmp_on_true`) and
  bit 1 `cmp_k_left`: a constant on the left (`0 < x`) compiles to the
  mirrored relation with the constant on the right (`x > 0`), and the flag
  exists only so a fault names the operands in source order. Ordered
  relations get constant forms for numbers only; a string or primitive
  on one side of `<` uses the register form, which faults or calls
  `__lt` as before. In `repeat … until cmp` the operands evaluate in the
  body's scope, which then closes (its `close_upvalues`), and the fused
  branch jumps back. Exits from the fused guard re-execute the fused op
  (the exit-side adapter's rule 6), so its operands stay live in those
  snapshots; the backend's flags compare (4744457) keeps that from
  costing a register.
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

Follow-up (Q7, 2026-10-22): the value form landed as the LuaJIT split,
not one `eqk`: `eq_p`/`ne_p` with nil and the booleans as an immediate
(no K load), `eq_s`/`ne_s` and `eq_n`/`ne_n` over a K index. A constant
on the left needs no form of its own, since `__eq` cannot fire against
a constant. P4's constant branch forms will mirror the three kinds.

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
