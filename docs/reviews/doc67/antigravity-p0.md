# Doc 67 — P0 findings review (antigravity, 2026-10-21)

Asked for a recommendation on doc 67 §11.3 Q5–Q7 after the P0 dry run.
Read-only, with tool access to the tree and LuaJIT. Verbatim:

---

### Executive Summary & Bottom-Line Verdict

**Recommendation: Option Q5(d) — Stop here. Keep P0’s refactor and diagnostic counters, and park P1–P3.**

P0 was a model experiment: it built the fact algebra and dry-run infrastructure without changing codegen, and produced an unambiguous empirical verdict:
- Across all benchmarks, **`link_terminal` proved 0/53** and **`loop_done_linked` proved 0/20**.
- The theoretical ceiling was already modest (an unsound build dropping *all* prologue tag checks everywhere yielded −2.25% to −2.61% instructions on `nsieve`/`nsieve-bit-fp`, and −0.5% to −1.1% for continuation step/`nov` guards).
- The root cause is architectural: in a tracing JIT where traces are independent PC-anchored units, inner loop roots and outer loop continuations operate on **disjoint register subsets**. Pairwise static fact tables at trace boundaries cannot prove facts about slots the parent never touches.

Attempting to patch this through Q5–Q7 requires an arm-time stub compiler, prologue restructuring around C-ABI callouts, and multi-operand guard propagation across exits — all to chase a net payoff well under 1% instruction reduction. Per **Rule Z-7** (do not stack elaborate machinery on a known structural boundary) and **Rule Z-6** (do not optimize for a single benchmark), the correct decision is to park the lever.

### Q5 — Pass-Through Slots (Doc 67 §11.3)

* **(a) Residual-check entry stubs:**
  * **Soundness & Mechanics:** Sound in isolation. An exit-adapter-like stub checks unproven facts and jumps to `child.proven`; failure branches to `child.prologue_fail` (nativegen.zig:2908–2921).
  * **Interaction with §6 consumers:** High friction. Introducing a dynamic per-arm stub creates a third target address kind. Silent promotion (trace_link.zig:1389–1397) requires `slot == target`; the registry's identical re-publication check (trace_native_registry.zig:1142) and invalidation/demotion logic must now track stub lifecycles, memory churn in the code arena, and deallocation on trace retirement.
  * **The Performance Flaw:** **The residual checks still run on every hop.** You do not eliminate the unproven tag checks; you merely execute them in a newly minted stub before jumping to `proven`. The instruction savings per hop is reduced to the few checks that *did* prove, while adding an extra jump indirection.
* **(b) Import link target's needs:**
  * **Soundness:** Sound. Adding target slot requirements to the parent's prologue means dispatcher entries into the parent fail safe if the slab doesn't match the downstream child.
  * **Asymmetry:** Only works forward. A loop root compiles before its continuation, so root → continuation (`loop_done_linked`, 13/13 misses) cannot import the continuation's needs without prior knowledge.
  * **The Net Cycle Flaw:** In the steady-state cycle (root → continuation → root), having the continuation import the root's needs (e.g. `tag(0, heap_ref)` for `p`) merely moves the check from the root's entry to the continuation's entry. **The total number of tag checks executed per outer iteration is identical.**
* **(c) (b) + Recompiling the loop root:**
  * **Hazard:** Recompiling the root once the continuation compiles triggers code reallocation, slot re-assignment, and demotes live promoted silent sets (trace_native_registry.zig:1148–1150). JIT recompilation churn creates fragility and replay complexity for negligible return.
* **(d) Stop here (Park P1–P3):** **Adopt (d).** None of (a)–(c) provides a clean, general architectural solution.

### Q6 — Seeded Children (31 of 66 misses)

**Recommendation: Keep the v1 exclusion.**

1. **Does `nativeSeedFn` write only seeded slots?** Yes. In src/interp.zig:1414, 1457, every write is explicitly `self.regSet(ctx.base + seed.slot, v)` for active seeds in `plan` (src/nativegen_artifact.zig:419). Inactive and unseeded slots are never written.
2. **Does running unseeded checks before the seed callout preserve contracts?** Yes. If an unseeded check fails before the seed callout, it branches to `prologue_fail` (nativegen.zig:2908–2921). Since `nativeSeedFn` has not been invoked yet, `regs[]` remains byte-identical. If unseeded checks pass, `nativeSeedFn` executes and its decline paths (`seed_hash_exit`, `seed_capacity_exit`, nativegen.zig:2933–2947) behave exactly as they do today.

Why lifting the exclusion is an economic trap:
* **The Seed Callout Cost:** At nativegen.zig:921–937, the seed prologue executes a SysV C-ABI callout: pushing `rdi`, `rsi`, `rdx`, loading imm64 arguments, `call rax` (`nativeSeedFn`), popping registers, and testing return codes (~20+ cycles). A linked entry to a seeded page *must still run this callout* to populate upvalues/globals. Shaving 1–2 inline tag checks (~1–2 cycles) directly in front of a heavy C callout is insignificant.
* **Miss Conversion:** Lifting the exclusion does not convert the 31 misses into hits. Those seeded children are loop roots and continuations; once the seed gate is lifted, they immediately fail on pass-through slots (Q5) and guard-derived facts (Q7).

### Q7 — Guard-Derived Facts

**Recommendation: Do not implement in `nativegen_factbuild.zig`.**

* In a linear, single-activation trace (such as a one-shot `.link` continuation), IR instructions are SSA. A guard at index g < e strictly dominates exit e. If execution reaches e, the guard unconditionally succeeded.
* Transferring `step_up`, `step_down`, or doc-57 boolean `pin` from the IR ref to `w.slot` at exit e is conceptually sound for `.link` writebacks.

Traps & complexities:
1. **Multi-iteration loop traces (`loop_done_linked`):** In a `.loop` trace, exits take φ writebacks (nativegen_boundary.zig:178, 189–192). The ref written at loop-done is the φ next-value (`p.b`). An in-body guard from iteration 1 may not describe the state of `p.b` when the loop finally terminates after N iterations.
2. **Multi-slot dependencies (`guard_for_nov`):** `nov(a, b)` requires proving that *both* operands map to the child's expected slots at the exit boundary simultaneously.
3. **The Miss Breakdown:** For `loop_done_linked`: 0 of 20 misses are Q7. For `link_terminal`: only 6 of 53 misses are pure Q7 candidates; the remaining 14 are "mixed" (they require both Q7 *and* Q5). On `nsieve`, continuation slot 9 needs Q7, but slot 0 (`p`) needs Q5. Without Q5, **Q7 converts 0 misses on `nsieve`**.

### The Contrast with LuaJIT

* A side trace is recorded *from* a parent snapshot. It inherits the parent's known slot types via `IRSLOAD_INHERIT` / `IRSLOAD_PARENT` (lj_snap.c:539; lj_ir.h:238) without generating entry type checks.
* When a side trace links back to root (`T->link != 0`), `canonicalize_slots` reconciles types, and `asm_tail_link` (lj_asm.c:2131) patches directly to the target mcode.
* LuaJIT never attempts pairwise static fact deduction between independently compiled trace pages that were recorded in isolation.

### Honest Sizing & Final Decision

| Factor | Sizing |
|---|---|
| Unsound upper bound (all tag checks dropped everywhere) | −2.25% to −2.61% (`nsieve`) |
| Unsound continuation step + `nov` guards dropped | −0.49% to −1.11% (`nsieve` / `sparse`) |
| Continuation `guard_step_up` / `guard_for_nov` baseline | Already hoisted to run once per entry by LICM (tropt.zig:102–106) |
| Realistic net gain of Doc 67 with Q5(a) + Q6 + Q7 | **< 0.5% – 0.8% instruction count** |

To capture that sub-1% gain, the codebase would incur per-arm executable stub generation at runtime (Q5a), a third target kind and lifecycle tracking in silent promotion & invalidation (§6), native prologue partitioning around C-ABI seeding callouts (Q6), and multi-ref guard-to-write set dataflow analysis (Q7).

**Conclusion:** P0 succeeded as an investigative spike. Keep P0's refactor and `--jit-stats` counters, but **park P1–P3**. Do not proceed with the runtime linkage changes.
