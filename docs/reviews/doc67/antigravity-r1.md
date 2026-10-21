# Doc 67 review, round 1 — Antigravity

Verbatim reply to the round-1 review request (read-only review of
`docs/design/67-proven-link-entry.md` at `9ff7ab1` against the tree).

Disposition note (coral-marten): Blocker 2 is rejected. The silent `.deopt`
epilogue does flush carried homes: `nativegen.zig` ~2979–2985 emits every
silent epilogue out of line, and the `.deopt` one duplicates the
`deopt_exit` carried-home flush ("ordinary deopt duplicates the shared
carried-home flush here"). Codex's answer (1) says the same. Everything
else is accepted; see doc 67 §10.

---

# Design Review: `docs/design/67-proven-link-entry.md` (commit `9ff7ab1`)

This is a read-only architectural and soundness review of [67-proven-link-entry.md](file:///home/bart/Projects/lune/docs/design/67-proven-link-entry.md) against the mahina runtime and native x86-64 backend in `/home/bart/Projects/lune`.

---

## Executive Summary

The core idea of doc 67—skipping redundant tag, pin, and step/overflow checks when jumping between native traces whose parent exit statically proves those facts—is sound in concept and aligns well with the existing coarse-deopt model.

However, the design contains **two critical soundness blockers**:
1. **The Invariant-Slot Writeback Flaw**: In one-shot traces (`.link` continuations), slots that are both loaded and stored are classified as `s.class = .invariant` by [analyzeInner](file:///home/bart/Projects/lune/src/nativegen_alloc.zig#L440-L452), yet they are **overwritten at the `.link` terminal** by [nativegen.zig:2239-2246](file:///home/bart/Projects/lune/src/nativegen.zig#L2239-L2246). Doc 67 §5.1 assumes invariant slots are never written and unconditionally inherits entry facts, allowing a overwritten slot (e.g. spectral-norm's float `a` overwritten with int `0`) to be falsely certified under its entry type.
2. **The Silent Epilogue `.deopt` Carried-Homes Omission**: For ordinary guards and sibling handoffs (`.deopt`), the silent check [nativegen.zig:2748-2751](file:///home/bart/Projects/lune/src/nativegen.zig#L2748-L2751) branches to [emitSilentEpilogue](file:///home/bart/Projects/lune/src/nativegen_emit.zig#L1290-L1458), which jumps directly to the target slot **without executing `emitCarriedHomesFlush`** at `deopt_exit`. On the silent path, carried homes in registers are **never flushed to the slab**. Claiming in §5.1 and §6 that ordinary exits prove carried homes and that silent epilogues flush the same slots will lead to the child reading un-flushed, stale slab data.

---

## Blockers

### 1. Invariant slots in `.link` continuations are overwritten at the terminal
- **Files**:
  - [src/nativegen_alloc.zig:439-453](file:///home/bart/Projects/lune/src/nativegen_alloc.zig#L439-L453)
  - [src/nativegen.zig:2239-2246](file:///home/bart/Projects/lune/src/nativegen.zig#L2239-L2246)
  - [docs/design/67-proven-link-entry.md:170-176](file:///home/bart/Projects/lune/docs/design/67-proven-link-entry.md#L170-L176)
  - [docs/design/67-proven-link-entry.md:214-223](file:///home/bart/Projects/lune/docs/design/67-proven-link-entry.md#L214-L223)

#### The Problem
Doc 67 §5.1 (item 2) defines **Untouched checked slots** as:
> *"A slot of class `.invariant` in `P` keeps its entry value at every exit, because nothing in `P` writes it. Whatever `P`'s own entry facts say about it still holds: its tag, its pin, and its hoisted `step_*`/`nov` facts."*

And §6 states:
> *"Inside `P`, invariant slots are not written, so their entry facts hold at every exit, and flushed slots hold the kinds the exit wrote."*

**This premise is false for `.link` continuations.** In `analyzeInner`:
```zig
const one_shot = t.instrs[n - 1].op == .terminal or t.instrs[n - 1].op == .link;
if (loaded and stored and one_shot) {
    s.class = .invariant;
    s.kind = kinds[@intCast(s.load_ref)];
}
```
In a one-shot trace ending in `.link`, any slot that is both loaded and stored has its class set to **`.invariant`** (so its entry register home is immutable during body execution). However, its `store_ref >= 0`. At the `.link` terminal:
```zig
for (alloc.slots) |s| {
    if (s.store_ref < 0) continue;
    const ref: usize = @intCast(s.store_ref);
    const flush_kind = kinds[ref];
    ...
    try flushSlot(a, @as(i32, s.slot), flush_kind, placeOfRef(alloc, ref));
}
```
Every slot with `s.store_ref >= 0` **is flushed with `kinds[store_ref]`**, explicitly overwriting `tags[s.slot]` and `payloads[s.slot]` in the slab. As documented in `analyzeInner`:
> *"So the entry and the writeback may be of any two classes — a doc 56 exit-side child starting mid-statement routinely loads a table temp that the body then reuses for an int (doc 58 B2 flip), and doc 34's spectral `a` loads float and stores int 0."*

Under doc 67's current specification, `F(P, .link)` would include:
1. `tag(s, TAG_INT)` from Set 1 (flushed slots).
2. `tag(s, TAG_FLOAT)` from Set 2 (untouched checked slots, because `s.class == .invariant`).

If the child trace expects `tag(s, TAG_FLOAT)` from its entry facts, `child.entry_facts ⊆ F(P, .link)` succeeds! The child enters at `proven`, skips its tag check, and proceeds to execute float instructions against an integer payload written to the slab.

#### Concrete Fix
In §5.1, explicitly restrict Set 2:
> **2. Untouched checked slots.** A slot is untouched on exit path `e` iff `e` does not write it. Specifically:
> - For `.link` terminal and `.terminal`: only slots where `s.class == .invariant and s.store_ref < 0` (i.e. not in `exit_stores`).
> - For ordinary deopt exits: slots where `s.class == .invariant`.
> Any slot written by the exit path (i.e. in Set 1) is strictly excluded from Set 2.

---

### 2. Silent epilogues for `.deopt` exits do NOT flush carried homes
- **Files**:
  - [src/nativegen.zig:2748-2751](file:///home/bart/Projects/lune/src/nativegen.zig#L2748-L2751)
  - [src/nativegen.zig:2830](file:///home/bart/Projects/lune/src/nativegen.zig#L2830)
  - [src/nativegen_emit.zig:1290-1458](file:///home/bart/Projects/lune/src/nativegen_emit.zig#L1290-L1458)
  - [src/trace_link.zig:1296, 1417](file:///home/bart/Projects/lune/src/trace_link.zig#L1296)
  - [docs/design/67-proven-link-entry.md:163, 210-212](file:///home/bart/Projects/lune/docs/design/67-proven-link-entry.md#L163)

#### The Problem
Doc 67 §5.1 asserts:
> *"- ordinary and sibling exits: the carried homes, from `s.kind` or `steady_kind`;"*

And §6 claims:
> *"- **Silent epilogues** continue through the same per-exit slot. P3 checks that each one flushes the same slots as the exit path its facts were computed from."*

In `nativegen.zig`, ordinary guards and sibling handoffs are `.deopt` silent sites:
```zig
if (shared_exit != null and !isNumericForLoopDoneGuard(t, ei) and !isCompositeBridgeCandidate(t, ei))
    try emitSilentSite(a, silent_emissions, metadata_cells, ei, .deopt);
try a.jmp(deopt_exit);
```
Notice that `emitSilentSite(..., .deopt)` is placed **before** `jmp deopt_exit`.
When an exit is promoted to silent (`metadata_cell != 0`), `emitSilentCheck` branches directly to `emitSilentEpilogue`. In [emitSilentEpilogue](file:///home/bart/Projects/lune/src/nativegen_emit.zig#L1456-L1458):
```zig
// Continue through the same per-exit slot as the reporting path.
try a.movRegMem(.rax, .rax, @offsetOf(SilentExitMetadata, "slot"));
try a.movRegMem(.rax, .rax, 0);
try a.jmpReg(.rax);
```
It jumps straight through the slot! **`emitCarriedHomesFlush` (which lives at `deopt_exit:2830`) never runs on the silent path.**

If `P` is a loop trace that has `.carried` slots (e.g. loop variables, accumulators):
- On the reporting path: execution reaches `deopt_exit`, and `emitCarriedHomesFlush` writes the carried homes to `tags[]` and `payloads[]`.
- On the silent path: `emitSilentEpilogue` bypasses `deopt_exit`. **The slab is not updated.**

If `F(P, e)` includes carried homes for an exit that can be promoted to silent (which includes `.ordinary_guard` and `.sibling_handoff` per `silentKindForArm`), the child trace entered via `proven` will load un-flushed, stale slab memory without checking tags.

*(Note: One-shot traces have no `.carried` slots because `analyzeInner` marks them `.invariant`. But loop roots have real `.carried` slots in registers across iterations.)*

#### Concrete Fix
Choose one of two structural fixes:
1. **Codegen fix**: In [nativegen.zig:2748](file:///home/bart/Projects/lune/src/nativegen.zig#L2748), do not place `.deopt` silent checks in the per-guard stub before `deopt_exit`. Instead, place them after `emitCarriedHomesFlush` so that both reporting and silent transitions write the carried homes before jumping to `slot`.
2. **Fact restriction**: In §5.1, exclude carried homes from `F(P, e)` for any `.deopt` exit (`.ordinary_guard`, `.sibling_handoff`) if `P` is a loop trace with carried slots, or until the silent epilogue is proven to flush carried homes.

---

## Should-Fix

### 3. `loop_done_linked` explicitly skips the visible loop variable slot
- **Files**:
  - [src/nativegen_emit.zig:2536-2544](file:///home/bart/Projects/lune/src/nativegen_emit.zig#L2536-L2544)
  - [docs/design/67-proven-link-entry.md:165](file:///home/bart/Projects/lune/docs/design/67-proven-link-entry.md#L165)

#### Details
Doc 67 §5.1 states:
> *"- `loop_done_linked`: the sunk stores and slot φs;"*

In [emitLinkedLoopDoneSnapshot](file:///home/bart/Projects/lune/src/nativegen_emit.zig#L2536-L2544):
```zig
const guard = t.instrs[exit_instr];
const for_ins = t.anchor.proto.code[trace.guardSourcePc(guard).?];
const visible_var_slot: i32 = @as(i32, @intCast(for_ins.a)) + 3;
for (t.instrs) |p| {
    if (p.op != .phi or p.aux == trace.PHI_INTERNAL) continue;
    if (p.aux == visible_var_slot) continue;
    try emitPhiValueFlush(a, t, kinds, alloc, p);
}
```
`p.aux == visible_var_slot` (`for_ins.a + 3`) is deliberately skipped. The visible loop index is out of scope in Lua 5.4 after loop termination, so the snapshot does not flush it. If `F(P, loop_done_linked)` includes all slot φs, it will falsely claim `visible_var_slot` was flushed with `kinds[p.b]`.

#### Concrete Fix
In §5.1, specify that for `loop_done_linked`, the flushed slot φs exclude `visible_var_slot` (`for_ins.a + 3`).

---

### 4. Missing fallback when `child.linked_proven_entry` / `ordinary_proven_entry` is null
- **Files**:
  - [src/trace_native_registry.zig:1045-1049](file:///home/bart/Projects/lune/src/trace_native_registry.zig#L1045-L1049)
  - [src/trace_chain.zig:178-185](file:///home/bart/Projects/lune/src/trace_chain.zig#L178-L185)
  - [docs/design/67-proven-link-entry.md:129, 193-197](file:///home/bart/Projects/lune/docs/design/67-proven-link-entry.md#L129)

#### Details
Doc 67 §4.1 states: *"A page with a seed plan gets neither stub (null)"*.
In §6, target selection is described as:
> *"- `.link_terminal` takes `linked_proven_entry` when `child.entry_facts ⊆ F(parent, exit)`, else `linked_entry`."*

If `child.entry_facts ⊆ F` evaluates to `true` (which trivially happens if `child.entry_facts` is empty), but `child_c.linked_proven_entry` is `null` (because `child` has a seed plan or is a test fixture without proven stubs), an unconditional select will crash or unwrap to `.declined`. The link should succeed via the fallback `linked_entry`.

Furthermore, `link.proven: bool` in the link record must reflect whether the proven entry address was actually chosen and written into the slot, not merely that the subset predicate passed.

#### Concrete Fix
In §6, formulate the target selection as:
```zig
const use_proven = child.entry_facts.isSubsetOf(F) and 
    (if (kind == .link_terminal) child_c.linked_proven_entry != null else child_c.ordinary_proven_entry != null);

const target = switch (kind) {
    .link_terminal => if (use_proven) child_c.linked_proven_entry.? else (child_c.linked_entry orelse return .declined),
    else => if (use_proven) child_c.ordinary_proven_entry.? else (child_c.ordinary_entry orelse return .declined),
};
```
Record `proven = use_proven`.

---

### 5. Representation, canonical ordering, and constant operands for `nov(l, s)`
- **Files**:
  - [src/trace_recorder.zig:3603-3610](file:///home/bart/Projects/lune/src/trace_recorder.zig#L3603-L3610)
  - [src/nativegen_prove.zig:563-566](file:///home/bart/Projects/lune/src/nativegen_prove.zig#L563-L566)
  - [docs/design/67-proven-link-entry.md:116, 168, 199](file:///home/bart/Projects/lune/docs/design/67-proven-link-entry.md#L116)

#### Details
1. **Constant Operands**: In `trace_recorder.zig:3604-3607`, `guard_for_nov` is emitted when one operand is a constant (e.g. constant step `1` or constant limit `100`):
   ```zig
   if (self.konstValueOf(rlimit_cmp) == null or self.konstValueOf(rstep) == null) {
       const nov = try self.emit(.{ .op = .guard_for_nov, .a = rlimit_cmp, .b = rstep });
   ```
   Doc 67 notes `nov(l, s)` can have a constant on one side, but does not specify how this is stored in `entry_facts`. If `EntryFact` only contains `(u16, u16)`, a constant cannot be represented.
2. **Canonical Ordering**: Signed addition overflow `@addWithOverflow(a, b)[1] == 0` is commutative. If parent proves `nov(5, 6)` and child checks `nov(6, 5)` (or vice versa), a sorted list merge will fail to find the match.

#### Concrete Fix
Define the `EntryFact` union explicitly in §4.1:
```zig
pub const EntryFact = union(enum) {
    tag: struct { slot: u16, tag: u8 },
    pin: struct { slot: u16, val: bool },
    step_up: u16,
    step_down: u16,
    nov_slots: struct { slot_a: u16, slot_b: u16 }, // invariant: slot_a <= slot_b
    nov_const: struct { slot: u16, step: i64 },
};
```
Require `nov_slots` to always store `min(a, b)` and `max(a, b)` to guarantee canonical sorting during 2-way merge.

---

### 6. Scope of Compile-time Fact Table to Armable Exits
- **Files**:
  - [docs/design/67-proven-link-entry.md:180-187](file:///home/bart/Projects/lune/docs/design/67-proven-link-entry.md#L180-L187)
  - [src/trace_link.zig:2235-2241](file:///home/bart/Projects/lune/src/trace_link.zig#L2235-L2241)

#### Details
Doc 67 §5.2 proposes allocating `exits × slots` records per page for "every exit that can be armed".
In a trace with 100+ instructions, there may be dozens of guards, but only a tiny fraction are ever eligible for arming:
- `.link` terminal (the terminal instruction only).
- `loop_done_linked` (the loop-done exit only).
- `ordinary_guard` / `sibling_handoff` (only guards passing `exitIsPreEffect`).
Allocating facts for all IR exits wastes GPA memory on internal arithmetic and type guards that can never link.

#### Concrete Fix
In §5.2, specify that `F(P, e)` is only derived and stored for exits that satisfy `canArmExit(t, e)` (e.g. `isLinkTerminal`, `isNumericForLoopDoneGuard`, or `exitIsPreEffect`).

---

### 7. Handling of float step slots in prologue hoisting
- **Files**:
  - [src/nativegen.zig:1325-1337](file:///home/bart/Projects/lune/src/nativegen.zig#L1325-L1337)
  - [src/arith.zig:260-262](file:///home/bart/Projects/lune/src/arith.zig#L260-L262)
  - [docs/design/67-proven-link-entry.md:115, 135-140](file:///home/bart/Projects/lune/docs/design/67-proven-link-entry.md#L115)

#### Details
In `nativegen.zig:1325`, `guard_step_up` / `guard_step_down` support both `.int` and `.float`. If an invariant step is a float, checking `0 < step` requires `ucomisd` with `0.0`.
In the prologue, checking a memory float payload requires `movsd xmm0, [rsi + slot*8]` before homes are loaded.
Doc 67 does not mention float steps in §4.1 or §4.2.

#### Concrete Fix
Specify in §4.2 whether float step slots are admitted for prologue hoisting (using scratch `xmm0`), or whether v1 restricts step hoisting to integer steps (`kinds[ins.a] == .int`), leaving float step guards in the body.

---

### 8. Test suite omissions
- **Files**:
  - [docs/design/67-proven-link-entry.md:253-266](file:///home/bart/Projects/lune/docs/design/67-proven-link-entry.md#L253-L266)

#### Details
The test list in §8 covers the happy path and a basic adversarial test, but misses the two subtle failure modes identified above:
1. **The Overwritten Invariant Test**: A one-shot continuation that loads slot `s` as float, executes, stores `s` as int at `.link`, and arms into a child expecting float. The test must verify that the arm remains `checked` (or that float is not considered proven).
2. **The Carried Home Silent Cycle Test**: A loop trace with a carried slot in a register, with an ordinary guard armed to a child that reads that slot. Verify that if the cycle is promoted to silent, the child does not observe stale data.
3. **The Commutative `nov` Test**: A parent proving `nov(l, s)` and a child checking `nov(s, l)` with operands in opposite orders.

---

## Nits & Implementation Notes

1. **`opMayExitInBody` sync**: When moving `guard_step_*` and `guard_for_nov` to the prologue, [src/nativegen_alloc.zig:1658-1660](file:///home/bart/Projects/lune/src/nativegen_alloc.zig#L1658-L1660) must be updated to return `false` when hoisted (mirroring `!pinHoisted`). Otherwise, [src/nativegen.zig:2598](file:///home/bart/Projects/lune/src/nativegen.zig#L2598) and coalescing will treat them as mid-body exits.
2. **`exit_labels` binding**: In `nativegen.zig:2570`, exit stubs are only generated if `exit_labels[ei] != null`. Hoisted guards do not call `jccNativeExit`, so `exit_labels[ei]` remains `null`. This correctly leaves their physical slot as `shared_exit`.
3. **LuaJIT comparison in §1**: Doc 67's reading of LuaJIT (`rec_for_check`, `init`, `IRSLOAD_INHERIT` in [lj_record.c](file:///home/bart/Projects/LuaJIT/src/lj_record.c#L445) and [lj_snap.c](file:///home/bart/Projects/LuaJIT/src/lj_snap.c#L539)) is accurate. Note however that LuaJIT side traces are compiled for a specific parent snapshot exit, whereas mahina continuations are independent and can be reached from multiple parent exits and the interpreter.
4. **Impact on LICM, Exit Attachment, Loop-Done, Tier Equivalence**:
   - **Loop-done**: No breakage. [isNumericForLoopDoneGuard](file:///home/bart/Projects/lune/src/trace_code.zig#L716) strictly checks `guard_true` from `for_loop`.
   - **Exit attachment**: No breakage. v1 excludes `.exit_side` adapter arms.
   - **LICM**: [tropt.zig:98-106](file:///home/bart/Projects/lune/src/tropt.zig#L98-L106) already hoists invariant `.cvt` ops to the preheader; nativegen's prologue check matches this semantic.
   - **Tier equivalence**: Native prologue refusal yields `exit_reason = .prologue_fail` with `local_completed = 0`, byte-identically matching tier-1a's zero-completion deopt before loop entry.
