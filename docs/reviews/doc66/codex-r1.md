# Doc 66 review, round 1 — Codex

Verbatim reply to the round-1 review request (read-only review of
`docs/design/66-bytecode-forms.md` at `7d32e84` against the tree).
Codex thread `01a15c32-dafc-7830-96ca-0b2ed820b5eb`.

---

Bart, I found four implementation blockers in the proposed design. The overall direction is viable, but §4.1 is incomplete and shape (b) needs a fuller control-flow design.

Reviewed doc 66 at `7d32e84` against the working tree, including its existing uncommitted changes. I made no file changes and ran no builds or tests.

## Blockers

### 1. Strategy B’s GC-skipping proof is false as written

“No allocation between checks” does **not** imply that the second check cannot collect.

`shouldCollect()` returns `gc_stress or object_count >= next_gc`. GC stress explicitly works in `.fast`; it does not force `.full`. Also, an attempted collection can fail its worklist reservation and leave collection due. See [gc.zig:583](/home/bart/Projects/lune/src/gc.zig:583), [interp.zig:3000](/home/bart/Projects/lune/src/interp.zig:3000), and [interp.zig:2524](/home/bart/Projects/lune/src/interp.zig:2524).

This matters beyond collection counts: collection scrubs registers, invalidates dead trace constants, advances the host epoch, and drops iterator caches. Skipping that boundary can therefore change observable VM state. See [interp.zig:2530](/home/bart/Projects/lune/src/interp.zig:2530) and [gc.zig:655](/home/bart/Projects/lune/src/gc.zig:655).

**Required amendment:** preserve the second GC boundary whenever collection remains due. A sufficient fusion admission condition is that collection is not due at that boundary, with no intervening allocation or change to collection eligibility. Merely excluding allocating pairs is insufficient.

### 2. `itern` shape (b) has three successors and invalidates the existing loop-gate model

Its possible destinations are:

1. Generic fallback at the first `move`.
2. Successful step to the body.
3. Exhaustion past `tfor_loop`.

The proposed “two successors” is incorrect. Today `Effect.succ`, `Effect.edge_kill`, and the public successor interface support two edges; edge kills support **one register per edge**, not a range. Dominance also explicitly allocates and traverses two successors per instruction. See [bc_liveness.zig:54](/home/bart/Projects/lune/src/bc_liveness.zig:54), [bc_liveness.zig:114](/home/bart/Projects/lune/src/bc_liveness.zig:114), and [bc_dom.zig:46](/home/bart/Projects/lune/src/bc_dom.zig:46).

More fundamentally, accepting `itern` in `loopExtentFor`’s scan is insufficient. `loopGateOf` currently returns the `tfor_loop`, because every body entry passes through it. Shape (b)’s fast path bypasses it, so that claim becomes false. Topology uses this gate for dominance-based owner election. See [bytecode.zig:360](/home/bart/Projects/lune/src/bytecode.zig:360) and [trace_region_topology_build.zig:596](/home/bart/Projects/lune/src/trace_region_topology_build.zig:596).

The fast path also bypasses `opTForLoop`’s back-edge accounting and recording activation: [interp.zig:6749](/home/bart/Projects/lune/src/interp.zig:6749).

**Required amendment:** specify the complete CFG, edge-specific writes, hotness/back-edge behavior, gate identity, and entry-patch behavior. An alternative worth considering is a guarded iterator instruction that performs either the direct step or generic call and then reaches a shared `tfor_loop`.

### 3. Compiler operand swapping changes arithmetic semantics

§5.3 says commutative operations can swap operands. That is unsafe for dynamically typed operands:

```lua
1 + obj
obj + 1
```

Their `__add` receives different argument orders. Mahina deliberately invokes `handler(a, b)` in source operand order: [interp.zig:7883](/home/bart/Projects/lune/src/interp.zig:7883).

LuaJIT preserves this distinction too: it has `ADDNV` and `MULNV`, alongside their `VN` forms, and selects them for constant-left expressions. See [lj_bc.h:102](/home/bart/Projects/LuaJIT/src/lj_bc.h:102) and [lj_parse.c:820](/home/bart/Projects/LuaJIT/src/lj_parse.c:820).

**Required amendment:** preserve operand orientation through separate forms or an encoding flag, or retain ordinary bytecode for constant-left expressions. Numeric commutativity alone does not justify compiler swapping.

### 4. Calling `nextStepAny` alone omits necessary grid handling

The existing `next` implementations first call `iterableArg`, which validates the container and **deflates outer grids**, then call `nextStepAny`. See [base.zig:74](/home/bart/Projects/lune/src/stdlib/base.zig:74), [base.zig:170](/home/bart/Projects/lune/src/stdlib/base.zig:170), and [base.zig:180](/home/bart/Projects/lune/src/stdlib/base.zig:180).

Shape (b) admits any table and proposes calling `nextStepAny` directly. That helper assumes the wrapper has handled grids; its table path eventually calls `array.get`, which rejects grid lanes. See [base.zig:163](/home/bart/Projects/lune/src/stdlib/base.zig:163), [base.zig:130](/home/bart/Projects/lune/src/stdlib/base.zig:130), and [array.zig:314](/home/bart/Projects/lune/src/array.zig:314).

**Required amendment:** decline grids or perform exactly the existing deflation before stepping. The latter can allocate and fail.

## Should-fix

### 1. Complete and qualify the consumer inventory

The listed compare-and-branch matchers are substantially correct. The inventory nevertheless misses important consumers:

| Missing consumer | Consequence |
|---|---|
| `bc_liveness.successors` and `bc_dom`’s fixed two-edge storage/traversal | Shape (b) requires changes beyond `effectOf`. [bc_liveness.zig:114](/home/bart/Projects/lune/src/bc_liveness.zig:114), [bc_dom.zig:61](/home/bart/Projects/lune/src/bc_dom.zig:61) |
| `bytecode.loopHeaderOf` and `loopGateOf` | New iterator control flow must preserve back-edge and gate contracts. [bytecode.zig:245](/home/bart/Projects/lune/src/bytecode.zig:245), [bytecode.zig:370](/home/bart/Projects/lune/src/bytecode.zig:370) |
| `trace_entry_registry.patchedEntryOp`, `resolvePatchPc`, installation; `interp.opJLoop`’s canonical-op switch | These define which instructions can host loop entries and which semantics patched handlers execute. [trace_entry_registry.zig:125](/home/bart/Projects/lune/src/trace_entry_registry.zig:125), [interp.zig:6472](/home/bart/Projects/lune/src/interp.zig:6472) |
| `interp.nativeSite`, `frameShape`, `frameMask` | Additional `.call`-specific operand/shape consumers. [interp.zig:1859](/home/bart/Projects/lune/src/interp.zig:1859), [interp.zig:2609](/home/bart/Projects/lune/src/interp.zig:2609), [interp.zig:2668](/home/bart/Projects/lune/src/interp.zig:2668) |
| Compiler table constructors | Named fields currently emit constant loads plus stores; §5.2’s emission-site list omits them. [compiler.zig:1328](/home/bart/Projects/lune/src/compiler.zig:1328) |

There are also deliberately specialized consumers worth recording as **audited, unchanged**: multret producer/consumer recognition, call-layout masking, numeric-for linking, and the recorder driver’s inner-root context decoding. Examples: [bc_liveness.zig:437](/home/bart/Projects/lune/src/bc_liveness.zig:437), [bc_liveness.zig:474](/home/bart/Projects/lune/src/bc_liveness.zig:474), [trace_exit_attach.zig:469](/home/bart/Projects/lune/src/trace_exit_attach.zig:469), and [trace.zig:3577](/home/bart/Projects/lune/src/trace.zig:3577).

The serialization claim is accurate for bytecode ordinals: wasm emits disassembly text through `writeInstr`; snapshots carry frame PCs and runtime-loaded source for recompilation. See [wasm_entry.zig:761](/home/bart/Projects/lune/src/wasm_entry.zig:761) and [keyframeser.zig:360](/home/bart/Projects/lune/src/keyframeser.zig:360).

### 2. Strategy B’s remaining proof is mostly sound, with precise conditions

- **Recording and suspension:** active recording, pending recording anchors, suspend controls, and line recording block `.fast`. The omitted prologue hooks really are `.full`-only. See [trace.zig:3132](/home/bart/Projects/lune/src/trace.zig:3132), [interp.zig:3033](/home/bart/Projects/lune/src/interp.zig:3033), and [interp.zig:3409](/home/bart/Projects/lune/src/interp.zig:3409).
- **Replay:** “replay always runs `.full`” is too broad. Effect replay alone is not a fast-block condition. The wasm replay paths force `.full` through suspension/line recording. See [interp.zig:765](/home/bart/Projects/lune/src/interp.zig:765), [wasm_entry.zig:441](/home/bart/Projects/lune/src/wasm_entry.zig:441), and [wasm_entry.zig:704](/home/bart/Projects/lune/src/wasm_entry.zig:704). The argument should depend on the actual enabled hooks.
- **Region gate:** correct when it checks exactly `regionProfitCount() == 0`; that is the production prologue gate. It means an empty profit map, rather than simply “no active region.” See [interp.zig:3374](/home/bart/Projects/lune/src/interp.zig:3374) and [trace_regionops.zig:1606](/home/bart/Projects/lune/src/trace_regionops.zig:1606).
- **Counter and PC:** increment once more **after the first instruction executes**, then publish the second instruction’s PC before executing it. That matches the actual ordering. See [interp.zig:3325](/home/bart/Projects/lune/src/interp.zig:3325) and [interp.zig:3402](/home/bart/Projects/lune/src/interp.zig:3402).
- **Patches:** reading the partner from `st.code` is essential. A handler can receive a canonical instruction when a head/continuation patch declines; taking its adjacent pointer would inspect canonical bytecode instead of the running image. See [interp.zig:6618](/home/bart/Projects/lune/src/interp.zig:6618) and [interp.zig:6718](/home/bart/Projects/lune/src/interp.zig:6718).

The repeat-closer example is stale: current code patches the `loop` marker, **not** the backward `jmp_if_false`. [trace_entry_registry.zig:121](/home/bart/Projects/lune/src/trace_entry_registry.zig:121).

### 3. The iterator recorder fall-through argument holds for the named cases

`recCall` guards an inlined closure with `guard_func`, pinning its proto ID. Native calls delegate to their builtin recorder; `gmatch_iter` explicitly emits `guard_builtin`. Either rejects replacement by `next`. See [trace_recorder.zig:4208](/home/bart/Projects/lune/src/trace_recorder.zig:4208), [trace_recorder.zig:4278](/home/bart/Projects/lune/src/trace_recorder.zig:4278), and [trace_recorder.zig:4918](/home/bart/Projects/lune/src/trace_recorder.zig:4918).

The proposed reuse is therefore sound provided every successfully recorded fallback either proves that exclusion or terminates before executing a specialized callee path.

The regression should reuse the **same compiled loop function** across invocations with different iterator arguments. Reassigning the original iterator variable after generic-for initialization does not change its copied hidden iterator.

Two corrections:

- `frameShape`’s preceding-`.call` check classifies a suspended **Lua caller**, while `nativeSite` examines the current call-site instruction. Neither describes a pushed native frame. The direct step needs no native frame, but its failure paths still need specified location handling.
- An absent control key does **not** currently raise “invalid key to next.” Mahina finds the first greater canonical key, including after deletion. [hash_part.zig:460](/home/bart/Projects/lune/src/hash_part.zig:460). Preserve that behavior.

Result writes also need explicit nil padding for extra variables and exhaustion; the control register currently updates only on continuation. [base.zig:180](/home/bart/Projects/lune/src/stdlib/base.zig:180), [interp.zig:6756](/home/bart/Projects/lune/src/interp.zig:6756).

### 4. Field allocation claims are correct; “identical IR” needs a recorder interface change

`heapKeyChainGet` rejects grids at every chain hop, and `indexGet` deflates them before ordinary lookup—even with a string key. The doc is right. [interp.zig:8231](/home/bart/Projects/lune/src/interp.zig:8231), [interp.zig:8263](/home/bart/Projects/lune/src/interp.zig:8263).

Equivalent access IR is achievable, but `GetFrame`/`SetFrame` currently require a **key register**. Both shape functions read that register’s observed value and SSA ref; absent reads do too. See [trace_recorder.zig:2281](/home/bart/Projects/lune/src/trace_recorder.zig:2281), [trace_recorder.zig:3106](/home/bart/Projects/lune/src/trace_recorder.zig:3106), [trace_recorder.zig:3128](/home/bart/Projects/lune/src/trace_recorder.zig:3128), and [trace_recorder.zig:3263](/home/bart/Projects/lune/src/trace_recorder.zig:3263).

Specify a shared key-value/key-ref interface supporting register and constant sources. Do not fabricate a temporary register just to reuse these helpers. IR operations can match; PCs, ordinals, and provenance metadata necessarily change.

### 5. `condBranchOf` is useful, but recognition alone is insufficient

One decoder can centralize branch encoding. Callers must retain their semantic restrictions:

- Own-loop recognition needs marker adjacency or a backward edge to the matching marker.
- Bridge and sibling selection need actual branch guards and provenance.
- `jmp_if_not_nil` has different semantics and is currently admitted by some matchers but excluded by others. Compare [trace_link.zig:443](/home/bart/Projects/lune/src/trace_link.zig:443) with [trace_code.zig:989](/home/bart/Projects/lune/src/trace_code.zig:989).

For `resumeOf`, preserve this exact rule:

```text
recorded_jump = branch_on_true == recorded_compare_result
resume = recorded_jump ? fallthrough : target
```

Also retain the checks tying guard provenance and snapshot resume PC to the fused instruction. Only `.branch_cond` takes the opposite edge; operand/type guards resume at the fused instruction itself. [trace_exit_attach.zig:352](/home/bart/Projects/lune/src/trace_exit_attach.zig:352).

The recorder needs helpers accepting a comparison SSA ref and observed result: today `recCompare` writes a destination register, while `recBranch` reads one. Neither can be reused verbatim when `a` becomes a polarity bit. [trace_recorder.zig:2265](/home/bart/Projects/lune/src/trace_recorder.zig:2265), [trace_recorder.zig:3410](/home/bart/Projects/lune/src/trace_recorder.zig:3410).

### 6. Shape (a)’s restore argument is not established

Deterministic compilation does not reconstruct historical despecialization. After an earlier invocation despecializes a loop, a later invocation may use real `next`; uninterrupted execution retains the generic image, while restore recreates the speculative image.

The design needs to prove those paths equivalent for PCs, safepoints, recording, and any hidden control representation—or preserve/reconstruct specialization state. “The first entry despecializes again” does not cover a mid-loop restore or changed iterator on a later invocation. LuaJIT’s actual implementation stores an internal slot index, making a literal transplant especially sensitive. [vm_x64.dasc:4193](/home/bart/Projects/LuaJIT/src/vm_x64.dasc:4193).

## Nits

- **No extra IR constant disappears.** Both old loads and new constant forms call the recorder’s already-interning `konst`; §5.3’s “minus one IR `konst` per site” is wrong. [trace_recorder.zig:1884](/home/bart/Projects/lune/src/trace_recorder.zig:1884).
- **Constant equality needs numeric semantics.** Tag/bits comparison cannot implement `1 == 1.0`, signed zero, or NaN. Keep the existing numeric lanes and exact mixed-number fallback. [interp.zig:6145](/home/bart/Projects/lune/src/interp.zig:6145).
- **Iterator O(1) is a steady-state qualification.** Cache construction allocates, scans, and sorts; insertion invalidates it, and collection drops it. Mutation behavior can remain identical while costs differ substantially. [hash_part.zig:474](/home/bart/Projects/lune/src/hash_part.zig:474), [hash_part.zig:518](/home/bart/Projects/lune/src/hash_part.zig:518).
- Preserve the microprobe sources in the repository before using them as repeatable phase gates; `/tmp` references are insufficient.

## Q1–Q5 opinions

| Question | My preference and reason |
|---|---|
| **Q1: strategy** | **A for canonical forms**, with the branch decoder refactor first. It removes temporary stores/register pressure and benefits regions-live execution. B is viable after fixing the GC proof, but adds mode-dependent behavior and runtime recognition for smaller savings. |
| **Q2: arithmetic** | **K-index forms first**, preserving constant-left orientation. They cover integers and floats through one mechanism. Add immediate forms only if measurements show the K load matters enough to justify another family. |
| **Q3: comparisons** | **Register/register plus constant equality and ordered constant comparisons.** The encoding fits; `i < limit_literal` is general language usage. Preserve numeric edge cases and metamethod operand order. |
| **Q4: iterator** | **Revise (b) around a shared loop gate**, preferably a guarded iterator operation with a generic-call fallback converging on `tfor_loop`. That is an additional option, rather than approval of (b) as written. It avoids persistent specialization state and the unconditional three-move protocol. |
| **Q5: order** | **P2 → P3 → P5 → branch-decoder refactor/P4 → revised P1.** P1’s measured opportunity is large, but its architectural surface is substantially understated. Field and constant forms provide narrower first phases. |

LuaJIT’s useful lessons here are its orientation-preserving constant forms and its integrated iterator hotness/recording treatment. `ITERN` owns hotloop accounting, and `rec_itern` has explicit loop detection; it is more than a shortcut around a native call. See [vm_x64.dasc:4185](/home/bart/Projects/LuaJIT/src/vm_x64.dasc:4185) and [lj_record.c:675](/home/bart/Projects/LuaJIT/src/lj_record.c:675).

I kept all 23 numbered global rules and all eight project rules in mind.
