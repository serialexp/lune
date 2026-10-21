# Doc 66 review, round 1 — Antigravity

Verbatim reply to the round-1 review request (read-only review of
`docs/design/66-bytecode-forms.md` at `7d32e84` against the tree, with
read access to the repo and `~/Projects/LuaJIT`).

---

# Design Review: `docs/design/66-bytecode-forms.md`

**Status:** Read-only review against master ([7d32e84](file:///home/bart/Projects/lune/commit/7d32e84) / working tree). No files modified.

---

## 1. Blockers

### B1. `bc_liveness.zig` `Effect` cannot represent edge-range kills for `itern`
- **Location:** [src/bc_liveness.zig:68](file:///home/bart/Projects/lune/src/bc_liveness.zig#L68) and [src/bc_liveness.zig:198-204](file:///home/bart/Projects/lune/src/bc_liveness.zig#L198-L204)
- **Doc claim (§5.1):** *"`effectOf` gains an `itern` arm with two successors. It uses `b..b+2` and kills `b+2..b+3+n` on the taken edge."*
- **Issue:** `Effect.edge_kill` is typed as `[2]?u16` — it only stores a **single register** written along that successor edge (used by `.for_loop` for `a+3` and `.tfor_loop` for `a+2`). It **cannot** express a range kill `b+2..b+3+n` (which writes at least 2 registers: the control slot `b+2` plus `b+3..b+3+n`).
- **Impact:** If `itern` uses `Effect.kill(b+2, b+3+n)`, it kills `b+2` across **both** successors. On the fall-through edge, `move b+5, b+2` reads `b+2`. Killing it unconditionally will report a use of a dead register in liveness analysis or truncate live ranges. `Effect` must be structurally extended with an edge-kill range (e.g., `edge_kill_range: [2]struct { lo: u16, hi: u16 }`) before `itern` can land.

### B2. Strategy B is disabled for any program with JIT regions live
- **Location:** [src/interp.zig:3374](file:///home/bart/Projects/lune/src/interp.zig#L3374)
- **Doc claim (§4.2 Rule 4):** *"`Region departure observer.` Fuse only while the region counter is zero. That is the same cmpl the prologue already does. With regions live, the handler dispatches normally."*
- **Issue:** In `src/interp.zig`, `self.trace.regionProfitCount() != 0` is true whenever regions are tracked/active. Strategy B requires that when regions are live, fusion is bypassed because the region observer must see every instruction boundary.
- **Impact:** Strategy B does not just "fuse less" — **it never fuses at all once a trace region forms**. Any benchmark or real-world workload that tiers up will see zero benefit from Strategy B in tier-0 exits/fallbacks. This disqualifies Strategy B as a general tier-0 solution (violates [Rule Z-6](file:///home/bart/Projects/lune/AGENTS.md#L94) and [Rule Z-7](file:///home/bart/Projects/lune/AGENTS.md#L107)).

---

## 2. Should-Fix

### S1. `itern` must decline grids (deflation invariant)
- **Location:** [src/stdlib/base.zig:81-82](file:///home/bart/Projects/lune/src/stdlib/base.zig#L81-L82)
- **Doc claim (§5.1):** *"`itern` checks that `R[b]` is the `next` builtin and `R[b+1]` is a table or `row_view`. If so it runs the step inline..."*
- **Issue:** In `iterableArg`, iterating a matrix table deflates it (`if (t.array.isGrid()) try vm.heap.deflateGrid(t)`). A flat `row_view` has no hash part, but a parent grid table must deflate before iteration so child rows are real tables, not unescaped internal handles.
- **Fix:** `itern` fast path must check `!t.array.isGrid()`. If it is a grid, it must decline and fall through to the generic `call` path (which calls `iterableArg` and deflates).

### S2. `itern` instruction encoding omits the exit target
- **Location:** [src/bytecode.zig:480-486](file:///home/bart/Projects/lune/src/bytecode.zig#L480-L486)
- **Doc claim (§5.1):** *"`test: itern b, n, aux → body` ... jumps to the body, or past the `tfor_loop` at the end."*
- **Issue:** `Instr` has only one `aux: i32`. If `aux` holds the backward offset to `body`, the forward offset to exit (past `tfor_loop`) is unspecified.
- **Fix:** Specify that `c: u16` carries the forward offset to `tfor_loop` (or loop exit), while `aux: i32` carries the backward jump offset to `body`.

### S3. `itern` `nextLive` allocation and error handling
- **Location:** [src/hash_part.zig:474](file:///home/bart/Projects/lune/src/hash_part.zig#L474) and [src/stdlib/base.zig:103](file:///home/bart/Projects/lune/src/stdlib/base.zig#L103)
- **Issue:** `t.hash.nextLive(gpa, ctrl)` allocates memory when building or resorting the key view and returns `std.mem.Allocator.Error!?Entry`.
- **Fix:** The `itern` interpreter handler must handle `error.OutOfMemory` (either by parking the error via `parkErr(st, e)` or falling through to the slow path).

### S4. `hashGetShape` / `hashSetShape` take register slots, not constant refs
- **Location:** [src/trace_recorder.zig:2281-2297](file:///home/bart/Projects/lune/src/trace_recorder.zig#L2281-L2297) and [src/trace_recorder.zig:3178-3179](file:///home/bart/Projects/lune/src/trace_recorder.zig#L3178-L3179)
- **Doc claim (§5.2):** *"`hashGetShape`/`hashSetShape` need the key as a `konst`. Today that is the `load_const`'s IR ref; with the new forms it is `konst(K[aux])`, which is the same IR."*
- **Issue:** `GetFrame` and `SetFrame` define `key: u16` as a register index, and `hashGetShape` calls `self.refOf(f.key)`. For `get_field a, b, aux=K`, the key is in `proto.constants[aux]`, not a register.
- **Fix:** Clarify that `GetFrame`/`SetFrame` or helper functions must be refactored to take an already-resolved `key_ref: Ref` rather than a register slot.

### S5. `recBranch` polarity and LLEAVE checks assume `jmp_if_false`/`jmp_if_true`
- **Location:** [src/trace_recorder.zig:3423, 3443, 3483](file:///home/bart/Projects/lune/src/trace_recorder.zig#L3423)
- **Issue:** `recBranch` directly tests `instr.op == .jmp_if_true` and `instr.op == .jmp_if_false` to compute `jumped` and to detect `repeat` loop LLEAVE.
- **Fix:** If compare-and-branch instructions (`jlt`, `jle`, etc.) are routed through `recBranch`, these checks will misclassify `jumped` and fail to detect `repeat` loop exit aborts. `recBranch` must decode polarity via `condBranchOf`.

### S6. `describeFault` operand pick will read out-of-bounds registers on constant forms
- **Location:** [src/interp.zig:2011-2023](file:///home/bart/Projects/lune/src/interp.zig#L2011-L2023)
- **Issue:** `describeFault` handles arith/comparison errors by calling `regs.get(instr.b)` and `regs.get(instr.c)`. For constant arithmetic (`addi`, `addk`) or constant compares (`jltk`), `instr.c` or `instr.aux` is an immediate or a constant index, not a register.
- **Fix:** Calling `regs.get(instr.c)` on a constant form will read arbitrary registers or crash if `c >= num_registers`. `describeFault` must format constant operands from `K` or `aux`.

---

## 3. Nits

1. **Missing `.jmp_if_not_nil` in inventory citations:**
   - [src/trace_link.zig:447](file:///home/bart/Projects/lune/src/trace_link.zig#L447) and [src/trace.zig:1854](file:///home/bart/Projects/lune/src/trace.zig#L1854) switch on `.jmp_if_false, .jmp_if_true, .jmp_if_not_nil`. §4.1 only mentions the first two.
2. **Missing `while`/`repeat` closer checks in `loopExtentFor` inventory:**
   - §4.1 notes `assertLoopClosersWellFormed`, but misses [src/bytecode.zig:339](file:///home/bart/Projects/lune/src/bytecode.zig#L339) (`branch.op != .jmp_if_false`) and [src/bytecode.zig:349](file:///home/bart/Projects/lune/src/bytecode.zig#L349) (`closer.op != .jmp_if_false`) in `loopExtentFor`.
3. **`continuationReachesEnclosingBackEdge` check:**
   - [src/trace_exit_attach.zig:507](file:///home/bart/Projects/lune/src/trace_exit_attach.zig#L507) checks `.jmp, .jmp_if_false`. A repeat loop closed with a fused compare-and-branch would be skipped if not included.

---

## 4. Verification of Specific Questions

### Q1. Consumer Inventory in §4.1 completeness
**Verdict: Incomplete regarding compiler-shape matchers.**
The following sites need updating for compare-and-branch (Strategy A) and were omitted or incomplete in §4.1:
1. [src/bytecode.zig:338-350](file:///home/bart/Projects/lune/src/bytecode.zig#L338-L350) (`loopExtentFor` `while` condition and `repeat` closer checks).
2. [src/bytecode.zig:393, 413, 416](file:///home/bart/Projects/lune/src/bytecode.zig#L393) (`assertLoopClosersWellFormed` backward jump check and asserts).
3. [src/trace_code.zig:787](file:///home/bart/Projects/lune/src/trace_code.zig#L787) (`computeOwnLoopTest` hardcodes `src.op != .jmp_if_false`).
4. [src/trace_code.zig:832](file:///home/bart/Projects/lune/src/trace_code.zig#L832) (`classifyBridgeCandidate` only accepts `.jmp_if_true, .jmp_if_false`).
5. [src/trace_code.zig:992](file:///home/bart/Projects/lune/src/trace_code.zig#L992) (`CompositeWalk.init` only accepts `.jmp_if_true, .jmp_if_false`).
6. [src/trace_exit_attach.zig:379](file:///home/bart/Projects/lune/src/trace_exit_attach.zig#L379) (`resumeOf` only accepts `.jmp_if_true, .jmp_if_false`).
7. [src/trace_exit_attach.zig:507](file:///home/bart/Projects/lune/src/trace_exit_attach.zig#L507) (`continuationReachesEnclosingBackEdge` checks `.jmp, .jmp_if_false`).
8. [src/trace_recorder.zig:3423, 3443, 3483](file:///home/bart/Projects/lune/src/trace_recorder.zig#L3423) (`recBranch` polarity calculation and `repeat` LLEAVE detection).
9. [src/trace_link.zig:447](file:///home/bart/Projects/lune/src/trace_link.zig#L447) and [src/trace.zig:1854](file:///home/bart/Projects/lune/src/trace.zig#L1854) (include `.jmp_if_not_nil`).

### Q2. Strategy B determinism argument (§4.2)
**Verdict: Flawed and functionally dead for JIT execution.**
- **GC check (Rule 1):** Sound for `heapKeyChainGet` (verified at [src/interp.zig:8235](file:///home/bart/Projects/lune/src/interp.zig#L8235); it declines grids and does not allocate).
- **`.fast`-only fusion (Rule 3):** Sound (verified via [src/interp.zig:3013-3016](file:///home/bart/Projects/lune/src/interp.zig#L3013-L3016) `fast_block == 0`).
- **Region-observer gate (Rule 4):** **Unsound practically** (see Blocker B2). Since `regionProfitCount() != 0` when any region is live, Strategy B shuts off completely for all compiled code.
- **`frame.pc` (Rule 5):** Sound, provided `st.frame.pc` is updated prior to any error exit on the second op.
- **Entry patches (Rule 6):** Sound. `st.code[pc + 1]` in the active code image contains `.jloop` / `.jcont` when patched, which safely prevents fusion.

### Q3. `itern` shape (b) (§5.1)
**Verdict: Sound with caveats.**
- **Recorder fall-through:** Sound. [src/trace_recorder.zig:4282](file:///home/bart/Projects/lune/src/trace_recorder.zig#L4282) (`guard_func`) and [src/trace_recorder.zig:5259](file:///home/bart/Projects/lune/src/trace_recorder.zig#L5259) (`guard_builtin`) strictly pin the callee identity. If `R[b]` is replaced with `next` at runtime, the callee guard fails and exits cleanly to tier-0.
- **`frameShape`/`nativeSite`:** Sound ([src/interp.zig:1863, 2618](file:///home/bart/Projects/lune/src/interp.zig#L1863)); no native call frame is pushed.
- **Mutation during traversal:** Sound ([src/hash_part.zig:474](file:///home/bart/Projects/lune/src/hash_part.zig#L474)); `nextLive` handles in-place mutations and deletions canonically.
- **Caveats:** Must handle grid deflation (Should-Fix S1), encoding of the loop exit target (Should-Fix S2), and `Effect` edge-kill representation in liveness (Blocker B1).

### Q4. `get_field` (§5.2)
**Verdict: Allocation claim is correct; recorder requires `GetFrame` refactor.**
- `heapKeyChainGet` ([src/interp.zig:8235](file:///home/bart/Projects/lune/src/interp.zig#L8235)) declines grids (`return null;`) and performs zero allocations. `indexGet` ([src/interp.zig:8265](file:///home/bart/Projects/lune/src/interp.zig#L8265)) deflates grids and allocates. The claim is exact.
- Emitted IR for the recorder is identical (`konst` + `guard_table` + `href` + `guard_hash` + `hload`), but `GetFrame` must be refactored (Should-Fix S4) because `key` is currently assumed to be a register.

### Q5. Compare-and-Branch Strategy A & `resumeOf` (§5.4)
**Verdict: A single `condBranchOf` predicate is sufficient, and `resumeOf` is preserved.**
- In [src/trace_exit_attach.zig:379-397](file:///home/bart/Projects/lune/src/trace_exit_attach.zig#L379-L397), `resumeOf` checks if the recorded trace jumped (`jumped = jumps_if_truthy == recorded_truthy`). If it jumped, untaken resume is fallthrough (`b + 1`); if it fell through, untaken resume is `fall + aux`.
- If `condBranchOf(ins)` provides `.{ .target = u32, .jumps_if_true = bool, .aux = i32 }`, `resumeOf` computes `jumped = cond_branch.jumps_if_true == (g.op == .guard_true)` and verifies `gp.polarity == (if (jumped) .taken else .fallthrough)`. The logic holds unchanged.

---

## 5. Opinions on Open Questions (Q1–Q5)

- **Q1 (Strategy): Adopt Strategy A everywhere; land `condBranchOf` first.**
  Strategy B adds peek-and-branch overhead to unfused instructions, cannot eliminate temporary register writes, and turns off completely whenever trace regions are live (Blocker B2). Strategy A is clean, removes opcodes and register stores permanently, and aligns with [Rule Z-7](file:///home/bart/Projects/lune/AGENTS.md#L107). Landing `condBranchOf` as a preparatory refactor isolates the JIT matcher changes cleanly.
- **Q2 (Constant arithmetic): Int immediate in `aux` first.**
  Mahina's 12-byte `Instr` has `aux: i32` readily available. Emitting `addi a, b, aux=imm32` requires no constant table allocation, no memory dereference of `K`, and handles `i + 1`, `i - 1`, `i % 2` directly. Float constant forms (`addk`) can be added if needed, but int immediates cover the vast majority of hot loops. Omit constant-on-the-left in v1 (rare, per [Rule Z-6](file:///home/bart/Projects/lune/AGENTS.md#L94)).
- **Q3 (Compare-and-branch): Register-register + constant equality.**
  Register-register (`jlt`, `jle`, `jgt`, `jge`, `jeq`, `jne` with polarity bit in `a`) covers standard loops and conditionals. Constant equality (`x == nil`, `x == false`, `x == true`) eliminates 2 opcodes per guard. Ordered constant compares (`jltk`) can wait.
- **Q4 (`itern` shape): Shape (b) (guarded prefix).**
  Shape (b) avoids despecialization patching and mutable bytecode images (unlike (a)), while eliminating the 3 `move`s and native call frame overhead in `pairs` (unlike (c)). It handles non-`next` iterators by falling through at the cost of 2-3 instructions. Be sure to address S1 (grid check) and S2 (exit encoding).
- **Q5 (Phasing): Order as proposed: P1 (`itern`) → P2 (`get_field`/`set_field`) → P3 (constant arith) → P5 (`eqk`) → P4 (compare-and-branch).**
  P1 and P2 provide the largest marginal instruction savings (459→17 for `pairs`, 128→29 for `t.x`). Compare-and-branch has the largest JIT surface area and should land last after `condBranchOf` is established.
