# Doc 64 review, round 1 — Antigravity

Verbatim reply to the round-1 review request (read-only review of
`docs/design/64-heavy-iteration-nests.md` at `a161e09` plus the doc).
Its file links are condensed to `path:line`; a mermaid diagram of the
order is replaced by its four step titles. Two of its factual claims are
wrong, and doc 64 §9 records them: `LEDGER_CAP` is 32, not 23, and
Rule Z-1 is about verifying the Zig stdlib. Its TSC point itself stands
on the determinism rules (doc 02), not on Z-1.

---

# Review of `docs/design/64-heavy-iteration-nests.md`

This is an independent design and code review of `docs/design/64-heavy-iteration-nests.md` for mahina. The document investigates the performance gap on `bench/luajit/nsieve-bit-fp.lua` (16.1× slower than LuaJIT) and proposes options across four distinct mechanisms (P1–P4).

Overall verdict: **The document’s core diagnosis is fundamentally sound and correctly identifies why nsieve-bit-fp fails.** The previous diagnosis in `TODO.md` ("the `while` inside `for k` has no looping root trace") was indeed stale—the `while` root `t7` (`nsieve:54`) compiles and commits. However, there are two crucial code-level mechanisms that the document missed or understated regarding P3 and P4, and option 1b contains a proposal that would violate project determinism rules.

## 1. Verification of Diagnosis Against Code

### P1. Region decay gates the outer `for i`
* **Mechanism verified:**
  * In `src/trace_region_policy.zig:135-138`, `beginCredit` adds `work` directly to `accum.outer_traversals`.
  * In `src/trace_chain.zig:1802-1820`, `region_work` for `.loop_done_linked` is hardcoded to `1` (line 1803), `.deopt` to `local`, and `.link_terminal` to `0`.
  * Because `for k` executes inside `for i`, and the inner transitions write ledger rows, the ledger hits `LEDGER_CAP` (23 rows) after only 3–6 traversals of `for i`.
  * When execution yields to the runtime or departs region member points (observed at `src/trace_regionops.zig:1550-1565`), `src/trace_regionops.zig:378-401` calls `closeRegion`.
  * In `src/trace_region_policy.zig:237-249` (`beginClose`), `work = accum.outer_traversals - accum.window_base`. Because `work` (3–6) is strictly less than `min_useful` (8) and `!accum.useful_window_seen`, the tail waiver (line 247) does not apply.
  * `flushWindow` (line 122) returns `.strike = def.owner`.
  * In `src/trace_regionops.zig:345-375` (`applyWindowDecision`), `penalty` for owner anchor 23 is incremented. At `penalty >= max_penalty` (8), line 368 calls `gateAnchor(owner, .region_decay)`, line 371 calls `condemnProvenanceEdgesAt(owner)`, and line 372 calls `disarmAllLinks()`.
* **Impact verified:** Anchor 23 is dispatch-gated for 256 → 8192 ticks (`src/trace.zig:3248`), forcing 532,161 outer loop iterations to run in tier-0 (21.1% of the entire run), while `disarmAllLinks()` nukes all armed links VM-wide.
* **Diagnosis verdict:** **Confirmed accurate.**

### P2. A chain that ends at an enclosing loop-done counts as a miss
* **Mechanism verified:**
  * When `t7` (anchor 54, the `while` root) exits at `e10` (its own loop test), `src/interp.zig:4400-4441` (`routeExitSide`) calls `driveChain`.
  * `driveChain` (`src/trace_chain.zig:216`) runs `sct` (`t8`, anchored at post-while pc 63).
  * `t8` executes the post-while body. When `for k` finishes, the `for_loop` guard (`e33` in `t8`, instruction `%033 guard_true %32`) deopts.
  * In `src/trace_chain.zig:546`, `sresult.exit_instr` is 33, not `sct.code.instrs.len - 1` (the `.link` terminator).
  * `driveChain` takes the "Not a completed link run" path (`src/trace_chain.zig:590-613`) and returns `ChainResult{ .completed = 0, .resume_pc = ..., .linked_trace = null }`.
  * In `src/interp.zig:4417`, `routeExitSide` calls `ts.noteExitSideChain(ct, ei, if (chained) |c| c.linked_trace != null else false);`
  * Because `linked_trace == null`, `linked` is passed as `false`.
  * In `src/trace_link.zig:648-670` (`noteExitSideChain`), `m.* +|= 1`. At `m.* >= tryside` (4), lines 664–665 unpublish the exit adapter, disarm the link, and set `parent.exit_side[exit_instr] = .gave_up`.
* **Diagnosis verdict:** **Confirmed accurate.** `t8` successfully executed all bytecode to the end of the `for k` loop, yet was penalized as a misfit.

### P3. The exit-side chain at a `.loop` marker never tries the loop's root
* **Mechanism verified:**
  * In `nsieve-bit-fp.lua`, pc 53 is the `.loop` marker; pc 54 is the `while` header.
  * `src/bytecode.zig:245-254` (`loopHeaderOf`) defines `.loop`'s header as `pc + 1` (54).
  * In `src/trace_exit_attach.zig:341`, rule 8 checks `isLoopHeader(proto, p)`. Since 53 is not a header, `p = 53` is allowed, while 54 is refused with `.resume_header`.
  * `driveChain` queries `nextTraceExcluding(proto, 53, ...)` (`src/trace.zig:2496`), which only returns traces anchored at 53 (`t2`, `t6`).
  * `t7` is anchored at pc 54, so `nextTraceExcluding` never sees `t7`.
* **Missing code blocker (not mentioned in doc 64):**
  Even if `driveChain` or `routeExitSide` were told to look at pc 54, two existing gates in the codebase strictly forbid attaching to `t7`:
  1. `src/trace_chain.zig:355`: `if ((loop_done_values != null or materialization == .exit_side) and !is_link) continue;` — `driveChain` unconditionally skips any exit-side candidate that does not end in `.link`. `t7` ends in `.loop`.
  2. `src/trace_link.zig:2080` in `arm()`: `if (child.code.instrs.len == 0 or child.code.instrs[child.code.instrs.len - 1].op != .link) return false;` — the arm funnel refuses to arm an `.exit_side` link unless the child ends in `.link`.
  * **Doc 64 missed these two gates.** Any option to offer or bind to `t7` must update these gates.

### P4. One ledger row per `while` trip
* **Mechanism verified:**
  * `t6` is anchored at 53 and unrolls 2 trips. Its `e10` resumes at 53 and is armed to `t6` itself.
  * Every 2 trips, `t6` takes `e10`, running the exit adapter, appending an `.exit_side` row, and jumping back to `t6`.
  * This repeats until `LEDGER_CAP` (23 rows), forcing a yield to `driveDispatcherLedger` to replay 23 identical rows.
* **Missing root cause (why silent promotion fails, not diagnosed in doc 64):**
  * Why did `t6 e10 -> t6` fail silent promotion?
  * Look at `src/trace_link.zig:881-885` (`resolveSuccessorAnchor`): `if (p != t.code.anchor.pc and self.countTracesAt(...) != 0) return .{ .proto_id = proto.id, .pc = p };`
  * Note `p != t.code.anchor.pc` on line 883! Because `t6`'s resume pc is 53, which equals its own anchor pc (53), `resolveSuccessorAnchor` returns `null`!
  * Thus, the edge `t6 e10 -> t6` is excluded from the structural graph, excluded from `edge_cache`, and has no `RegionDef`.
  * In `src/trace_link.zig:1510-1521` (`considerSilentPromotion`), promotion requires an active region with `accum.frozen == true`. Because `t6 -> t6` is not in any region, it can never be promoted.

## 2. Answers to Document §7 Questions & Assessment of Options

### Question 1: Is P1 diagnosis right? Assessment of 1a–1d
**Yes, the P1 diagnosis is correct.** "Outer traversals per activation" conflates "how many times the outer loop stepped" with "how much useful work the region completed". When an outer traversal contains an inner loop of variable trip count, a single traversal does massive work, but ledger capacity forces early activation termination before 8 outer traversals accumulate.

* **Option 1a (Count work in member iterations):**
  * **Soundness:** **Sound and deterministic.** It credits actual committed iterations (`local`) from member rows rather than a flat `1`.
  * **Generality:** High. General language principle: a region that executes 500 inner loop iterations is doing productive work and must not be punished for having an inner loop.
  * **Risk to protections:** Low.
    * *Cold regions:* A loop nest that runs < 8 total iterations across all members still has work < 8, striking and retiring normally.
    * *Ping-pong arms:* Ping-ponging coarse deopts have `local == 0` (or commit no guest work, per doc 55 §1 `commitsGuestWork`). They earn zero credit and continue to strike out.
    * *fft butterfly:* In late stages (512 iterations), `t6` will credit 512 units of work, qualifying the window and setting `useful_window_seen = true`, which protects the stage-end remainder via doc 55's tail waiver.
* **Option 1b (Strike only on ping-pong, or use cycle buckets):**
  * **Soundness:** **REJECT as phrased.** Using TSC cycles in tiering decisions strictly violates Rule Z-1, §A7, and deterministic replay guarantees across the 10 modes. If restricted to deterministic row/iteration counts, it collapses into 1a.
* **Option 1c (Drop owner gate; tombstone region like `fallback_owner`):**
  * **Soundness:** **Sound and highly recommended.** Notice that `src/trace_regionops.zig:359-366` already implements this exact behavior for `fallback_owner` (`penalty.remove(owner)`; `invalidateRegion` if not tombstoned; return).
  * **Generality:** High. Regions are an optimization for multi-trace native chaining and silent promotion. If a region's cross-trace links are unprofitable, the region should be tombstoned. Banishment of the owner anchor to tier-0 interpreter mode for 8,192 ticks (`gateAnchor(owner, .region_decay)`) punishes a perfectly good trace.
* **Option 1d (Scoped link disarm instead of `disarmAllLinks`):**
  * **Soundness:** Sound. Global `disarmAllLinks()` was an acknowledged temporary coarsening in doc 17 §A3 because links lacked region tags. Tearing down links in unrelated functions is indefensible.

**Better Alternative for P1:** Combine **1a** and **1c**:
1. In `src/trace_chain.zig:1803`, change `loop_done_linked => 1` to `loop_done_linked => local` (or `@max(local, 1)`).
2. In `src/trace_regionops.zig:348-375`, treat primary owner strike-out the same as fallback owner strike-out: invalidate the region definition, but do **not** dispatch-gate the owner anchor and do **not** call `disarmAllLinks()`.

### Question 2: Is enclosing loop-done a sound signal for P2?
**Yes, it is completely sound.**
* **Does it hide a misfit? No.**
  * A "misfit" is a continuation whose guards fail on entry (e.g., type check failure, array shape mismatch). A misfit deopts at its *first* few instructions.
  * The loop-done guard of an enclosing loop is the `guard_true` associated with the enclosing `for_loop` bytecode opcode (e.g. `e33` in `t8`).
  * A trace cannot reach the enclosing loop's done guard unless it has successfully executed every preceding instruction in the loop body.
  * Reaching the end of the enclosing loop is positive evidence that the continuation executed the entire remainder of the iteration and reached the program's natural control-flow exit.

* **Option 2a (Loop-done counts as linked/success):** Sound, general, and directly reflects reality.
* **Option 2b (Neutral):** Suboptimal; if an exit predominantly fires on iterations that end the enclosing loop, it shouldn't be left vulnerable to accumulating stale strikes.
* **Option 2c (LuaJIT semantics):** In LuaJIT, `tryside` only limits compilation attempts, not run outcomes. 2c is the pure LuaJIT design, but mahina uses coarse deopts where bad child bindings can cause turnstile overhead.
* **Option 2d (Give-ups expire):** Mandatory hygiene. A permanent `.gave_up` latch turns any temporary phase change into permanent deoptimization.

**Recommendation for P2:** **2a + 2d**. In `src/trace_link.zig:648`, if the child's terminal exit is `isLoopDoneGuardIndex` of an enclosing loop, treat it as successful (`m.* = 0`). Additionally, allow `.gave_up` to reset to `.none` after a cooldown period.

### Question 3: Which of 3a–3d is sound for P3?
* **Option 3a (Offer header root in chain):** Unsound without major modifications. In `src/trace_chain.zig:355`, `driveChain` rejects candidates where `!is_link`. A loop root ends in `.loop`, not `.link`.
* **Option 3c (Recorder links to compiled loop):** Good for future recordings, but useless for existing committed traces (`t1`, `t2`, `t6`).
* **Option 3d (Lift rule 8):** Rule 8 in `src/trace_exit_attach.zig:341` refuses loop headers (`isLoopHeader(proto, p)`). Lifting rule 8 allows `P = 54`.
* **Option 3b (Bind exit to header root):**
  * When `P = 53` (the `.loop` marker), the register slab is already 100% coherent for entry at pc 54 because the `.loop` marker opcode is a bytecode no-op.
  * An exit adapter (`src/nativegen_adapter.zig:326-342`) materializes the registers into the slab and jumps to the child's `ordinary_entry`.
  * A compiled loop root (`t7`) has an `ordinary_entry` that expects exactly this tier-0 register state!
  * The only barriers preventing `ArmKind.exit_side` from targeting `t7` are: `src/trace_link.zig:2079` (requires `child.code.anchor.pc == p`); `src/trace_link.zig:2080` (requires the child to end in `.link`); `src/trace_chain.zig:355` (requires `is_link`).

**Recommendation for P3:** Combine **3b and 3d**:
1. Recognize that when an exit resumes at a `.loop` marker `P`, its target can be the loop root at `loopHeaderOf(P)` (`P + 1`).
2. Update `src/trace_link.zig:2078-2081` to allow `child.code.anchor.pc == loopHeaderOf(p)` and permit `child` to end in `.loop`.
3. In `src/trace_chain.zig:355`, allow `.loop` roots when at a loop header.
4. This requires **no new ArmKind**. It remains `ArmKind.exit_side`, and the exit adapter simply jumps to `t7.ordinary_entry`.

### Question 4: Does 4a hold, or is P4 a general gap?
* **For `nsieve-bit-fp`:** **4a holds.** Once P3 is fixed, `t1` branches directly into `t7` (the `while` root). `t7` executes its trips via its own native `.loop` back-edge. `t6` is never executed, and the 390,454 ledger rows disappear completely.
* **For the language in general (Rule Z-6):** **P4 is a real architectural gap.**
  * If any side trace in any program loops back to its own start PC, mahina currently compiles it with an exit adapter jumping back to its entry.
  * Because `src/trace_link.zig:883` filters out `p == t.code.anchor.pc`, this self-edge cannot form a region and cannot silent-promote (4c fails).
  * **Option 4b is LuaJIT's principled answer:** in `lj_record.c:668`, when a side trace loops back to `startpc`, it is compiled as an extra loop (`LJ_TRLINK_LOOP`) with a real native back-edge.
  * Therefore: treat 4a as the immediate consequence of fixing P3, but schedule 4b to resolve self-looping side traces generally.

### Question 5: Anything misread in the evidence?
1. **Option 1b's mention of TSC cycles:** using TSC cycles for tiering decisions is forbidden because it breaks determinism and cross-mode byte-equivalence. Only deterministic counters (iterations, rows) may be used.
2. **Missing prerequisites in P3:** Doc 64 assumed offering `t7` in `driveChain` was sufficient, overlooking the hard asserts in `trace_chain.zig:355` and `trace_link.zig:2080` that reject any non-`.link` trace.
3. **Missing root cause in P4:** Doc 64 noted that `t6 -> t6` writes ledger rows every trip without explaining why silent promotion failed. `src/trace_link.zig:883` explicitly excludes same-anchor exits from `resolveSuccessorAnchor`.

## 3. Comparison with LuaJIT

| Problem | mahina today | LuaJIT (`lj_record.c`, `lj_trace.c`) |
| :--- | :--- | :--- |
| **P1 (Outer loop gating)** | Traversal count < 8 strikes owner. At penalty 8, gates owner anchor in tier-0 and calls `disarmAllLinks()`. | **No runtime trace de-optimization.** In `lj_trace.c:392-414`, penalties (`penalty_pc`) and blacklists fire **exclusively on recording aborts**. A compiled trace is never demoted or blacklisted because its activations were short. |
| **P2 (Side trace give-up)** | `noteExitSideChain` counts a miss on any run that doesn't reach `.link`. After 4 misses, permanently sets `.gave_up`. | **`tryside` (4) limits recording attempts, not run outcomes.** In `lj_record.c:2883-2892`, `tryside` stops trying to compile a side trace after 4 aborts (`LJ_TRLINK_INTERP`). Once compiled, exits patch permanently. |
| **P3 (Loop behind marker)** | Rule 8 bans loop headers. `driveChain` only looks at marker PC and rejects non-`.link` traces. | **Direct link to compiled loop root.** In `lj_record.c:660-672` (`rec_loop_jit`), when a side trace hits a compiled loop, it emits `LJ_TRLINK_ROOT` directly to the loop root. When recording hits an uncompiled loop, it aborts with `LJ_TRERR_LINNER` to let the inner loop compile first. |
| **P4 (Self-looping side trace)** | Arms exit adapter to own entry. Writes `.exit_side` row every trip. Blocked from silent promotion. | **Forms an extra loop.** In `lj_record.c:667-668`, if `J->pc == J->startpc`, LuaJIT emits `LJ_TRLINK_LOOP`, compiling a native loop with its own back-edge. |

## 4. Recommended Combination, Ordering, and Pinned Tests

Order (diagram): Step 1 — fix P2 (2a + 2d); Step 2 — fix P3 (3b/3d, relax `is_link`); Step 3 — fix P1 (1a + 1c); Step 4 — fix P4 (4b).

1. **Step 1: Fix P2 first (2a + 2d).**
   * *Why:* Fixing P3 causes `t7` to run and hand off to `t8`. When `for k` ends, `t8` hits `e33`. Without Step 1, `t7 e10` will give up after 4 iterations, immediately re-breaking P3.
   * *Changes:* In `src/trace_link.zig:648` (`noteExitSideChain`), check if child ended at an enclosing loop-done (`isLoopDoneGuardIndex`). If so, treat as success (`m.* = 0`). In `src/trace_chain.zig:606`, set `linked_trace = sct` when terminal exit is enclosing loop-done. Allow `.gave_up` to decay to `.none` after a cooldown.
2. **Step 2: Fix P3 (3b + 3d) — which also eliminates P4 on this benchmark (4a).**
   * *Why:* Allows `t1 e15` to jump straight to `t7` (`while` root) natively.
   * *Changes:* In `src/trace_exit_attach.zig:341`, allow resume at loop header when a compiled root exists. In `src/trace_link.zig:2078-2081`, relax `anchor.pc == p` and `is_link` checks when child is a `.loop` root at `loopHeaderOf(p)`. In `src/trace_chain.zig:355`, allow `.loop` roots at loop headers for `materialization == .exit_side`.
3. **Step 3: Fix P1 (1a + 1c).**
   * *Why:* Reclaims the 21.1% tier-0 execution time by preventing region decay from gating outer `for i` and disarming links.
   * *Changes:* In `src/trace_chain.zig:1803`, credit `local` (member iterations) on `.loop_done_linked` rows instead of hardcoded `1`. In `src/trace_regionops.zig:368-372`, on primary owner strike-out, invalidate/demote the region (mirroring lines 359–366 for fallback owner), but do **not** gate the owner anchor in tier-0 and do **not** call `disarmAllLinks()`.
4. **Step 4: Fix P4 (4b) for general language robustness.** When an exit-side recording returns to its own start PC, compile it with a `.loop` back-edge (`LJ_TRLINK_LOOP`).

### Pinned Tests Required

1. **P2 (loop-done continuation success)** — `src/interp_exit_side_test.zig`: an outer loop `for k = 1, 2` containing a branch whose attachable exit attaches to a side trace `t_side`. Run the loop where the branch fires on the final iteration of `k` (so `t_side` hits `k`'s `for_loop` loop-done guard). Assert `t.exit_side_misses[ei] == 0` and `t.exitSideAt(ei) == .attached` (never `.gave_up`).
2. **P3 (binding exit adapter to loop root)** — `src/interp_exit_side_test.zig`: a loop `for k = 1, N` containing `while cond do ... end`. Let the `while` loop become hot first so its root `t_while` compiles. Then let the outer loop attach its exit to `t_while`. Verify `armNativeLink(parent, exit, t_while, .exit_side)` returns `true`; confirm the exit adapter jumps directly to `t_while.ordinary_entry`, with zero tier-0 fallback.
3. **P1 (member-iteration crediting, no owner gating)** — `src/trace_gate_test.zig`: a region containing an outer loop and an inner loop; 3 outer iterations, each inner loop 100 iterations. Verify the accumulated work ≥ 300, `useful_window_seen == true`, and `penalty.get(owner) == null`. Strike-out test: an intentionally short region that strikes out; assert `region_defs.get(rid).?.armable == false`, but `gate.get(owner) == null` and unrelated armed links remain armed.
4. **P4 (self-looping side trace)** — `src/trace_finalize_test.zig`: an exit-side trace that loops back to its own start PC; verify the trace emits a `.loop` terminator and executes without per-iteration `.exit_side` ledger rows.
