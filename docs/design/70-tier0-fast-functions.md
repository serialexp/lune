# 70 — Tier-0 fast functions

Status: partial. P0–P2 landed (14 builtins, the call-protocol byte);
P3's allocating half and Q1–Q3's confirmation by Bart are outstanding.
Owner: claude (coral-marten)
Last updated: 2026-10-23

## Implementation status

Tracking the gap between this design and what's on master. Tick items as they
land; move whole phases to Done once everything inside them is checked.

### Done

- [x] **Diagnosis and prototype** (2026-10-23, §2). Inlining `type` in
  front of the generic native path takes a `type(i)` call from 252 to 152
  instructions, and scalar −5.1% tier-0 on top of 3dfb1de.
- [x] **P0 — the mechanism** (2026-10-23, §4, §4a). `FastBuiltin`, the
  `Native.protocol` byte, `opCallFast`, `fastResult`, the fallback through
  `callNative`; the differential test (`interp_fastcall_test.zig`).
- [x] **P1 — math**: `floor`, `ceil`, `sqrt`, `abs`, `min`, `max`, sharing
  their bodies with the natives (`stdmath.floorOf` …).
- [x] **P2 — base**: `type`, `select('#', …)`, `rawequal`, `rawget` (not on
  a grid), `rawlen`.
- [x] **P3, non-allocating half**: `string.len` of a string.
- [x] **`tonumber`**, every shape (2026-10-23): `arith.toNumber` parses
  without allocating. Called out of line (`.never_inline`): inlined, the
  parser's register pressure cost every other fast body 2–8 instructions.
  `tonumber("123")` 327 → 274 (LuaJIT 264); scalar −1.33%,
  str_find_match −0.81%.
- [x] **`math.type`** (2026-10-23). `Vm.subtype_names` caches "integer"
  and "float" beside `type_names`: interned in `internMetamethodNames`
  (so the keyframe restorer re-derives them), rooted with them. The
  native reads the same cache. Probe `mtype` 328 → 133 instructions;
  lua54 −10.9% on both tiers (its subtype loop calls `math.type`
  three times an iteration), str_gsub −0.76%, array3d −0.96%.
  - The enum member and switch arm sit last: placed after `type`, they
    renumbered the jump table and `floor` paid one instruction (nsieve-
    bit-fp +0.14%); last, every other probe and row is unchanged.
  - The two interned names shift every later heap id by 2. Hash parts
    hash heap keys by id, so placements move: field_hash +3.28% at tier
    0, pairs_hash +0.09%. Both are that lottery, not cost: the base
    binary with one or two string constants prepended to the bench runs
    the new count exactly (field_hash 7320M → 7560M), and the new binary
    with one prepended runs the old (TODO.md "field_hash's hash part
    pays 3% for id parity").
  - Caching lazily, on the first slow call, would leave ids alone for
    programs that never call `math.type`, but it breaks replay: a
    restored heap can hold an "integer" the original run never cached,
    so the restorer cannot tell whether to root it. It would need the
    cache state in the snapshot schema.
  - Tests: the differential test covers it (it walks every
    `FastBuiltin`); "math.type names the subtype, and its error shape
    falls back" pins the wiring. Eight GC and phase-Q tests that print a
    fresh table's id now print it 2 higher.
- [x] **Q1–Q3 defaults** (2026-10-23, Bart away; §7 records them): a
  separate `FastBuiltin`, non-allocating bodies only, the generic ABI later.

### Outstanding

- [ ] **Q1–Q3 confirmation by Bart** (§7).
- [ ] **Allocating bodies** (Q2): `string.sub`, `tostring` of a number,
  `rawset`.
- [ ] **The generic native ABI** (Q3): register-lane arguments, results in
  registers.

## 1. Why this exists

A native call at tier 0 costs about 125 instructions in `opCall` before the
native's own body runs (TODO.md "A native call is ~125 instructions"). The
same call under LuaJIT `-joff` costs about 60 in total. Most of the gap is
not the native's work. It is the generic call protocol:

- the callee-type dispatch, the `in_flight` and `stack_top` bookkeeping that
  a native which can re-enter the VM needs;
- the SoA → AoS copy of the arguments into `boundary_scratch` (the `[]Value`
  ABI);
- an indirect call, with everything live across it spilled and reloaded,
  and the `anyerror!Value` result coming back through memory;
- the result write and the dispatch prologue.

LuaJIT does not run its common builtins through this protocol at all. Each
`GCfuncC` carries an `ffid`. `BC_CALL` on a fast function jumps to a
hand-written assembler body (`vm_x86.dasc`, `ffunc_*`) that handles the
common argument shapes in registers. Anything else falls back to the C
function. This doc is the tier-0 equivalent. It is a general mechanism:
every program that calls `type`, `math.floor`, `select('#')` or
`string.len` in a loop pays for the protocol today.

## 2. Diagnosis

`bench/opprobe/measure.sh`, instructions per call (LuaJIT `-joff` second):

| call | mahina | LuaJIT |
|---|---|---|
| `type(i)` (an upvalue) | 252 | 69 |
| `math.abs(i)` (a local) | 227 | 59 |

The prototype adds one check in `callTail`'s native arm. If
`nat.recorded == .type`, there is at least one argument, and the result
count is fixed, it writes `vm.type_names[…]` and dispatches. That gives
`type(i)` 152, a saving of 100 per call, and scalar (three `type` calls per
iteration) −5.1% tier-0. The remaining 152 is the upvalue load (31), the
argument `move`, the callee-type dispatch and the prologue.

## 3. Goals

- The common shapes of the common pure builtins skip the generic protocol.
- Every result is byte-identical to the native's, in every mode, and
  replay is untouched.
- No new per-call cost for natives without a fast path. The generic arm's
  register allocation is fragile (doc 69 §3b), so the A/B bar is the usual
  one: no @bench row up.

## 4. Mechanism

**Dispatch point.** In `callTail`'s `.native` arm, before anything else,
test the native's id. With an id, tail-call a handler of its own,
`opCallFast(mode, of)`, that switches on it. Doc 69 §3b's lesson is that
code added to the shared arm moves the generic path's register allocation.
A separate handler keeps the fast bodies out of it, at the cost of one
test and one jump on the generic path (to be measured; inlining the switch
is the alternative if the jump costs more than the isolation saves).

**Fallback contract.** A fast body handles only the argument shapes it is
sure of. Any other shape, including every error case, re-enters the
generic native path for this same call. Errors, messages and partial
results therefore stay the native's. The fast path is a refinement of the
native, never a second implementation of its edge cases.

**What a fast body may not do.** Run a safepoint, call back into the VM, or
raise. So it needs neither `in_flight` nor the `stack_top` cover. If Q2
allows allocation, an allocating body must allocate through exactly the
helper the native uses, in the same order, so ids and GC timing match.

**Results.** The same writers as the generic arm: `writeSingleResult`
for a fixed count, `stampSingleResult` for `all_results`.

## 4a. What landed, and two changes to §4 (2026-10-23)

The mechanism is §4's, with two changes the first A/B forced. In both, the
cost of the fast path landed on unrelated calls through register
allocation, the doc 69 §3b effect.

**One call-protocol byte, not a fifth test.** The first cut tested
`nat.fast != null` ahead of the generic arm. Every other native call paid
for it: io_print +0.54% (exactly +4 instructions per `print`), pairs_hash
+0.70%, tbl_ops +0.40%. The test itself was 2 instructions; the rest was
spills it caused. The generic arm already tested `host`, `effect` and
`multi` in turn. Now `Native.protocol` is a tagged union (`plain`,
`multi`, `effect`, `host`, `fast: FastBuiltin`), and the arm switches on
its tag once. The fast check came out free, and every generic native call
got cheaper than at HEAD: io_print −0.67%, tbl_ops −0.51%, `math.abs`
before this doc's set 227 → 151 instructions. `Native.fast` is gone; the
`fast` payload is the id. Registry rows' protocols are computed at compile
time (`interp.base_protocols`), so install stores two bytes per native.
That store is the one cost left, about 650 instructions per VM start
(while_shortcircuit_probe, a 0.7M-instruction run, +0.10%). The call arm
asserts in safety builds that the byte agrees with `host`, `effect` and
`multi` (`protocolConsistent`). A ReleaseFast `assert` would be an
assumption, and LLVM tested the fields again.

Follow-up (2026-10-23, doc 66's `ipairs` lane). Doc 66 added a second
registry byte, `Native.itern`, and storing it cost another ~320
instructions per start. Registry rows are now whole comptime `Native`
templates (`interp.base_templates`), protocol included, and
`Heap.newNativeFrom` copies one. A VM start is 2k instructions under
the protocol-byte cost, and while_shortcircuit_probe −0.27% tier-0.

**`itern`'s fallback in its own handler.** `opIternSlow` inlined
`callTail` for the call it falls back to, so the larger native arm moved
its `next` step (+3 instructions per hash step). The call is now
`opIternCall`, reached through a cold per-op table read with the runtime
opcode (`coldTail`, like `slowTail`): LLVM inlines a direct tail call
back. `opItern` sends a non-`next` iterator straight there, which skips
`opIternSlow` too: str_gmatch −2.10%, pairs_hash −0.94%.

Results, instructions against 3dfb1de (every output identical):

| | tier-0 | `--jit-native` |
|---|---|---|
| scalar | −12.72% | −0.14% |
| nsieve-bit-fp | −9.87% | −0.16% |
| str_manip | −3.14% | −0.17% |
| partialsums | −2.66% | |
| array3d | −2.12% | |
| str_gmatch | −2.10% | −0.66% |
| nbody | −2.09% | |
| lua54 | −2.03% | −2.01% |
| scimark-lu | −0.27% | −1.25% |
| pairs_hash | −0.94% | −0.87% |
| io_print | −0.67% | −0.64% |
| while_shortcircuit_probe | +0.10% | +0.06% |

Per call (`bench/opprobe/builtins.lua`, mahina / LuaJIT `-joff`): `type`
240 → 152 (64), `math.floor` 287 → 207 (82), `math.abs` 227 → 151 (59),
`math.sqrt` 228 → 156 (56), `math.max` 285 → 216 (78), `rawget` 332 → 253
(111), `rawequal` 272 → 189 (153), `string.len` 228 → 147 (95),
`select('#', …)` in a vararg function 790 → 664 (269).

## 5. Determinism and the JIT

The builtins in scope are pure functions of their arguments, so the fast
path changes no value and no effect log. The recorder observes calls in the
prologue, before the handler runs, so recording is unchanged: a recorded
builtin still records through `recBuiltin`, and anything else is still a
barrier. Keyframes don't serialize the id. It comes from the registry at
install and at restore, like `recorded` and `effect` today.

## 6. Testing

A differential harness per builtin: for each argument matrix (every value
kind, wrong arity, and the boundary values), call the native directly and
through the fast path, and compare results or errors. Mutation-check it by
breaking one fast body. Programs run through `expectProgram`'s mode legs
as usual.

## 7. Open questions for Bart

Asked 2026-10-23 and unanswered; the work went ahead on the defaults
marked below, which the code can change.

- **Q1 — which id.** (a) Reuse `Native.recorded`. It already names
  `type`, `select`, the `raw*` family, `floor`/`ceil`/`sqrt`, `string.len`
  and more, and it is append-only. But `math.abs`, `math.min`/`max` and
  `string.byte` are not in it, and adding them means adding recorder arms
  or entries the recorder ignores. (b) A separate `fast: ?FastBuiltin`,
  set from the same registry rows, so the tier-0 set and the recorded set
  evolve independently. *Default taken: (b).* The registry's own rule
  (`basic.zig`) is that a `.recorded` tag lands together with its
  recorder arm, which (a) would have broken for `math.abs`/`min`/`max`.
- **Q2 — the first set, and allocation.** P1–P3 above are non-allocating
  except `string.sub`. `tostring` of a number allocates (interns), and is
  hot in scalar. Allowing allocation means a fast body must run the
  native's own allocation helper (§4). *Default taken: non-allocating
  only.*
- **Q3 — the generic ABI.** Independently of fast functions, the generic
  arm could pass results back in registers and read arguments from the
  register lanes, dropping the scratch copy and the result through
  memory. It touches every native's signature (a comptime adapter could
  keep their bodies). Fast functions first and the ABI later, or the ABI
  first, or not at all? *Default taken: fast functions first.*

## 8. References

- LuaJIT: `lj_obj.h` (`GCfuncC.ffid`), `lj_ffrecord.c`, `vm_x86.dasc`
  (`ffunc_*`, `vm_fallback`).
- Doc 23 (builtin recording breadth, `RecordedBuiltin`), doc 69 §3b (the
  native arm's register allocation).
- TODO.md "A native call is ~125 instructions in opCall".
