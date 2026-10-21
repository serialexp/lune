# Doc 67 review, round 1 — Codex

Verbatim reply to the round-1 review request (read-only review of
`docs/design/67-proven-link-entry.md` at `9ff7ab1` against the tree).
Codex thread `01a15d8e-9a0d-7791-9631-34aed1138ca3`.

---

Bart, **§5.1 contains a soundness blocker: `.invariant` does not mean “never written on exit.”** The proposed union can retain facts that the terminal flush has invalidated.

Reviewed doc 67 and the source at `9ff7ab1`; HEAD matches that commit. No files changed, and no builds or tests ran.

## Blockers

### B1 — One-shot `.invariant` slots can invalidate every kind of inherited fact

The claim at [67-proven-link-entry.md:170](/home/bart/Projects/lune/docs/design/67-proven-link-entry.md:170) contradicts the allocator. For `.link`- and `.terminal`-terminated traces, a slot that is both loaded and written is deliberately classified `.invariant`, even when its outgoing type differs from its entry type. Here, “invariant” describes the **entry home**, not the slab after terminal materialization. See [nativegen_alloc.zig:439](/home/bart/Projects/lune/src/nativegen_alloc.zig:439).

A `.link` terminal subsequently writes every slot with `store_ref >= 0`, using the **store’s** kind and payload. See [nativegen.zig:2225](/home/bart/Projects/lune/src/nativegen.zig:2225).

A concrete counterexample to the proposed fact rules:

- Parent checks invariant `s == true`, then its terminal snapshot writes `false` to `s`.
- §5.1(2) retains `pin(s, true)`; §5.1(1) additionally derives the outgoing constant’s facts.
- A child requiring `pin(s, true)` passes the subset test and skips its payload check, although the slab contains `false`.

This also permits stale type, step-direction, and overflow facts. A `nov(l,s)` fact becomes invalid when **either** operand changes, even if its tag stays unchanged.

**Suggested fix:** define `F(P,e)` through an exit-specific transfer:

1. Start with established entry facts.
2. Kill every fact mentioning a slot that this exit overwrites.
3. Generate facts from the values actually materialized.

For an initial conservative rule, inherit a fact only when **all its referenced slots are untouched by that exit**. Do not use `.invariant` alone. Keep entry-home classification unchanged; its existing purpose is valid.

## Should-fix

### S1 — Specify the exact materialization write sets and sources

The survey at [67-proven-link-entry.md:160](/home/bart/Projects/lune/docs/design/67-proven-link-entry.md:160) is too coarse to implement safely:

- Linked loop-done explicitly **skips the visible loop-variable slot `R[a+3]`**, despite its slot-bound φ. See [nativegen_emit.zig:2536](/home/bart/Projects/lune/src/nativegen_emit.zig:2536). Its admissibility relies on that slot being dead after the loop, not on it having been written: [trace_code.zig:680](/home/bart/Projects/lune/src/trace_code.zig:680).
- Sunk `astore`/`hstore`/`ustore`/`gstore` operations write heap storage, not slab tags. They do not directly generate `tag(slot,T)` facts: [nativegen_emit.zig:2515](/home/bart/Projects/lune/src/nativegen_emit.zig:2515).
- An ordinary exit flushes the **current carried home**, not `store_ref`. A constant φ update therefore does not prove a constant payload at an early exit: [nativegen_emit.zig:2551](/home/bart/Projects/lune/src/nativegen_emit.zig:2551).
- Bridge materialization skips carried slots overwritten by its selected φ emissions, then writes those emissions: [nativegen_emit.zig:2558](/home/bart/Projects/lune/src/nativegen_emit.zig:2558), [nativegen_emit.zig:2589](/home/bart/Projects/lune/src/nativegen_emit.zig:2589).

**Suggested fix:** give each supported exit contract an explicit write/source description shared with, or checked against, its emitter. Compute facts from that description. Preserve the existing peeled/precise arm exclusions.

### S2 — Define fact identity and constant entailment before P0

“Sorted by slot” is insufficient for the merge in §6. One slot can have tag, pin, and direction facts; `nov` has two operands and permits constants. See [67-proven-link-entry.md:113](/home/bart/Projects/lune/docs/design/67-proven-link-entry.md:113).

For example, `nov(slot_l, constant 1)` does not establish `nov(slot_l, constant 2)`. Trace-local constant indices or SSA refs cannot identify facts across artifacts.

Also, a finite parent table cannot enumerate every child overflow predicate implied by a known constant payload.

**Suggested fix:** specify:

- A complete ordering and equality over predicate kind and operands.
- Operand identities such as `slot(s)` and `int_constant(bits)`, independent of trace-local refs.
- Numeric interpretation for direction predicates.
- Whether matching means exact normalized-fact membership or logical entailment using stored known values.

If constants support additional entailment at arm time, describe that explicitly instead of calling the entire operation a list merge. This preserves the chosen compile-time table.

### S3 — Hoisting needs one shared predicate across lowering and allocation

The document mentions `opMayExitInBody`, but its synchronization with emission is a correctness requirement.

That predicate controls carried-home coalescing: removing an exit from its inventory permits earlier destructive home updates. It also controls precise-snapshot liveness. See [nativegen_alloc.zig:1153](/home/bart/Projects/lune/src/nativegen_alloc.zig:1153) and [nativegen_alloc.zig:883](/home/bart/Projects/lune/src/nativegen_alloc.zig:883).

**Suggested fix:** define one `entryGuardHoisted(...)` predicate used by entry-fact construction, prologue emission, body suppression, and `opMayExitInBody`. Computed operands—including `int_of_float` and internal φs—must remain body guards unless separately proved eligible.

The new checks precede home loads and constant materialization, so they must read slab operands and constant immediates directly. Reusing the current body emitters would read uninitialized allocated locations: [nativegen.zig:988](/home/bart/Projects/lune/src/nativegen.zig:988), [nativegen.zig:1323](/home/bart/Projects/lune/src/nativegen.zig:1323).

Keep IR-level attachability metadata for tier-1a, but distinguish it from **emitted native exits**. Otherwise tier-1a evidence can cause publication of adapters or arms for guards that no longer have native exit stubs. Native compilation currently republishes materializing exits: [trace_link.zig:3185](/home/bart/Projects/lune/src/trace_link.zig:3185).

### S4 — The proposed tests do not cover incorrect fact preservation

The two-parent adversarial test can catch an unconditional “everything is proven” mutation. It does not necessarily catch B1: its bad parent simply lacks a fact, whereas B1 incorrectly **retains a previously true fact**. See [67-proven-link-entry.md:253](/home/bart/Projects/lune/docs/design/67-proven-link-entry.md:253).

Existing step/overflow tests exercise checked entry. Their helper also intentionally accepts a native prologue refusal when tier-1a completed zero iterations: [nativegen_core_test.zig:452](/home/bart/Projects/lune/src/nativegen_core_test.zig:452), [nativegen_testutil.zig:79](/home/bart/Projects/lune/src/nativegen_testutil.zig:79).

**Suggested fix:** add explicit native-hop cases for:

- A one-shot parent overwriting a checked tag.
- `true → false`, positive → negative, and overflow becoming possible, **without a tag change**.
- Overwriting either operand of `nov`.
- A boxed writeback whose runtime tag changes.
- Early carried-home exits versus completed φ writebacks.
- Proven parent → proven child → proven grandchild.
- Reporting, promoted silent, and post-motion rowless sibling paths.
- Heap-structure checks still refusing after proven slab checks are skipped.
- Re-arm, disarm, and retirement of proven targets.

Assert actual child execution as well as the selected slot address. Mutation-check omission of fact killing and each predicate comparison separately. Use unseeded fixtures so the seeded-page exclusion cannot mask the test.

### S5 — “Arms are rare” misses repeated publication

§6 assumes subset testing is infrequent. The registry explicitly receives identical convergence republications, including republications on every terminal observation. See [nativegen_registry target logic at trace_native_registry.zig:1059](/home/bart/Projects/lune/src/trace_native_registry.zig:1059) and [trace_native_registry.zig:1099](/home/bart/Projects/lune/src/trace_native_registry.zig:1099).

**Suggested fix:** reuse the recorded decision for an unchanged relation between the same compiled artifacts. Recompute after artifact replacement or relation changes. Distinguish publication attempts from changed arms in P0 counters, and benchmark repeated unchanged publication with large fact lists.

### S6 — Specify storage limits and failure behavior

The per-exit table duplicates common facts, and relational facts are not bounded solely by slot count. §5.2 supplies no byte budget or allocation-failure contract: [67-proven-link-entry.md:180](/home/bart/Projects/lune/docs/design/67-proven-link-entry.md:180).

**Suggested fix:** retain the chosen flat table, but define checked size calculations, a memory budget, and fail-closed fallback to checked entries. An unavailable or incomplete child fact list must never be represented as a valid empty requirement list. Add allocation-failure tests and a deliberate compile-time/memory benchmark near supported trace limits.

## Nits

- **P1 is not behaviorally inert.** Moving guard failure to `prologue_fail` changes exit identity, side-trace evidence, and native coverage even before proven targets are armed. Describe P1 as “proven targeting disabled.” See [67-proven-link-entry.md:36](/home/bart/Projects/lune/docs/design/67-proven-link-entry.md:36).
- **Define `step_down` as the complement of `0 < step`.** It includes zero and unordered NaN, not just negative numbers. Preserve the existing cases at [nativegen_core_test.zig:454](/home/bart/Projects/lune/src/nativegen_core_test.zig:454).
- **Correct the rowless-path wording.** The tail consumes the already staged target; it deliberately does not reread the slot. See [nativegen.zig:2855](/home/bart/Projects/lune/src/nativegen.zig:2855). §6 should require preservation of that staged address.

## Answers to (1)-(6)

### (1) Is an `.invariant` slot never written?

**No.** One-shot terminal writebacks are the direct counterexample in B1.

For the other paths inspected:

- Ordinary coarse exits flush only carried homes.
- Bridge and linked loop-done paths have their own selected write sets.
- Silent materialization mirrors the corresponding reporting path; ordinary silent exits duplicate the carried-home flush: [nativegen.zig:2985](/home/bart/Projects/lune/src/nativegen.zig:2985).
- Native `ustore` addresses a verified **closed** upvalue cell, not a live slab alias: [nativegen.zig:1596](/home/bart/Projects/lune/src/nativegen.zig:1596).
- Native host-call IR is currently refused; general unsupported operations also fail native admission: [nativegen.zig:221](/home/bart/Projects/lune/src/nativegen.zig:221), [nativegen_prove.zig:1541](/home/bart/Projects/lune/src/nativegen_prove.zig:1541).
- Current body callouts do not collect: [nativegen_alloc.zig:1858](/home/bart/Projects/lune/src/nativegen_alloc.zig:1858).
- Parent seeds run before entry checks. Facts established **after successful seeding** can be propagated subject to subsequent writes.
- Frame motion changes the window and must terminate the old fact context.

### (2) Are flushed tags static?

**For supported unpeeled, nonprecise ordinary links, typed flushes have static tags. Boxed terminal writebacks do not.**

`flushBoxedSlot` writes a tag snapshotted from the runtime source at entry: [nativegen_emit.zig:479](/home/bart/Projects/lune/src/nativegen_emit.zig:479). Thus `.boxed` must generate no static tag fact, as the document intends.

Additional distinctions:

- `write_only` is unknown before its first back-edge unless the particular exit writes it.
- `.none` does not itself establish a checked type.
- `pin_only` has no home; use only the facts its emitted checks actually establish.
- Peeled exits conditionally skip flushing when local completion is zero: [nativegen.zig:2813](/home/bart/Projects/lune/src/nativegen.zig:2813). Their post-exit state is not uniformly described by `steady_kind`, but current arming excludes them.

### (3) Can intervening machinery change the slab?

**Not on the inspected v1-eligible direct hops after their materialization finishes.**

Ledger append, forced-yield checks, silent accounting, and rowless hit publication write result/counter metadata. Silent continuation follows the existing slot: [nativegen_emit.zig:1455](/home/bart/Projects/lune/src/nativegen_emit.zig:1455). Forced yield redirects execution to the runtime instead of entering the child: [nativegen_emit.zig:767](/home/bart/Projects/lune/src/nativegen_emit.zig:767).

Adapters and frame motion do change slab state and correctly remain excluded. A later dispatcher re-entry must continue using checked entry.

### (4) Does the induction handle other entry routes?

**The entry-route argument works after repairing B1.**

Existing ordinary and linked stubs both jump to `body_entry`; neither skips slab checks: [nativegen.zig:3025](/home/bart/Projects/lune/src/nativegen.zig:3025). Dispatcher wrappers enter `page.code.ptr`, also through checked entry: [nativegen_artifact.zig:793](/home/bart/Projects/lune/src/nativegen_artifact.zig:793).

Head self-push shifts the window and jumps back to `body_entry`: [nativegen_emit.zig:1049](/home/bart/Projects/lune/src/nativegen_emit.zig:1049). `call_head` and `ret_cont` retain checked ordinary targets. Therefore an excluded incoming frame-motion edge does not prevent that newly checked page from proving a later eligible outgoing hop.

Rewrite the induction around **each page activation’s established entry facts plus its exit transfer**, rather than assuming invariants survive the whole episode.

### (5) Is hoisting itself sound?

**I found no semantic counterexample under the stated direct-load/constant eligibility and S3’s emission requirements.** Refusing before executing the body leaves tier-0 able to execute the path from the anchor.

The numeric loop-done classifier requires `guard_true`; these three guards are not loop-done exits: [trace_code.zig:729](/home/bart/Projects/lune/src/trace_code.zig:729). Losing their native side-exit identity and growth opportunity is the accepted coverage trade-off.

Preserve:

- Body guards for computed operands.
- Shared hoisting/emission/liveness classification.
- Existing peeled and precise fusion exclusions: [trace_link.zig:2242](/home/bart/Projects/lune/src/trace_link.zig:2242).
- Precise IR snapshot metadata for tier-1a, even when native lowering no longer emits that guard’s snapshot exit.

Precise tests with effects before the original guard should compare completed VM behavior after fallback, not demand identical intermediate snapshot results.

### (6) Are there additional address consumers?

Beyond the two target switches named in §6:

- **Identical re-arm and candidate invalidation** compare the physical slot with the derived target: [trace_native_registry.zig:1073](/home/bart/Projects/lune/src/trace_native_registry.zig:1073), [trace_native_registry.zig:1102](/home/bart/Projects/lune/src/trace_native_registry.zig:1102). Keep `link.proven` synchronized on insertion, replacement, and unchanged publication.
- **`hasArmedExitSide`** compares directly against checked `ordinary_entry`: [trace.zig:1763](/home/bart/Projects/lune/src/trace.zig:1763). It can remain unchanged because exit-side arms are excluded.
- **`stubEnterability`** checks checked-entry availability: [trace_chain.zig:178](/home/bart/Projects/lune/src/trace_chain.zig:178). Preserve those checked stubs independently of proven-stub availability.
- **Disarm and retirement** reset physical slots to `shared_exit`, without matching a particular child entry address: [trace_native_registry.zig:718](/home/bart/Projects/lune/src/trace_native_registry.zig:718), [trace_native_registry.zig:864](/home/bart/Projects/lune/src/trace_native_registry.zig:864). Their structure already accommodates either target.
- **Ordinary-arm detection** tests only against `shared_exit`, so either checked or proven addresses remain armed: [trace_link.zig:590](/home/bart/Projects/lune/src/trace_link.zig:590).

I kept all 23 global numbered rules and eight project rules in mind.
