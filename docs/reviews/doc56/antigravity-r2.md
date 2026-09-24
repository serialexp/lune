# Design Review: doc 56 (Revision 2) — Exit-started side traces

Reviewer: Antigravity, 2026-09-24. Round 2 (follow-up to round 1 CHANGES
REQUESTED). Receipt copied from the review response. Dispositions are in
doc 56 §12.

# Verdict: APPROVE WITH CHANGES

Revision 2 is an exceptional turnaround. It completely eliminates the architectural risks identified in Round 1:
1. The pre-vs-post-`tropt` index collision is replaced by monotonic boundary ordinals carried on guards and sunk-store IR nodes.
2. The ambiguous unrolled-loop tier-0 re-run is replaced with LuaJIT's exact, sound **materialize-first** model.
3. The ad-hoc "rowless" mode is eliminated in favor of standard `LedgerKind.exit_side` warmup rows followed by existing **silent promotion** under `silent_budget`, strictly upholding Rules Z-7 and Z-8.
4. Mcode bloat is solved via compact compile-time exit location maps and lazy on-demand adapter emission.

The core design is now architecturally sound and honors project principles. There is one major integration trap identified in `trace_region_topology_build.zig` that would silently disable silent promotion on dispatcher-entered cycles, plus a necessary clarification on register availability for Q7. Once these changes are incorporated, the design is ready for Phase 0 implementation.

---

## 1. Disposition of Round-1 Findings

| # | Round-1 Finding | Status in Rev 2 | Reasons & Verification |
|---|---|---|---|
| 1 | `PendingStore.pos` vs `guard index` coordinate space mismatch under `tropt` | **RESOLVED** | §4.2 introduces monotonic boundary ordinals (`u16`) stamped on bytecode boundaries, guards, and sunk-store IR instructions. Because ordinals count guest bytecode events rather than IR array indices, they survive DCE, CSE, operand remapping, compaction, and preheader splitting. Sunk stores remain real IR instructions at the end of the trace whose operands are canonicalized by `tropt`. |
| 2 | Ambiguity in tier-0 re-run when `P` is inside an unrolled loop | **RESOLVED** | §4.4 abandons the re-run entirely and adopts LuaJIT's order: the exit materializes the exact guest state at `P`, and tier-0 resumes directly at `P` with recording armed. |
| 3 | Phase 7 "rowless" mode | **RESOLVED** | §4.8 removes the rowless phase. Transitions emit standard `LedgerKind.exit_side` rows during discovery. Intra-region classification lets the steady cycle qualify for data-cell silent promotion (`SilentSiteKind.exit_side`) under `silent_budget`. |
| 4 | Sunk stores of the current bytecode must not be flushed | **RESOLVED** | §4.1 defines the materializer filter: only stores from bytecodes strictly preceding the guard's bytecode are flushed. |
| 5 | Linking into a peeled child is unsound | **RESOLVED** | §4.4 and §4.6 enforce `!child.code.peeled`. Verified: `fft_bitreverse:9` is a numeric `for` loop, never peeled (`isPlainWhileAnchor`, `src/trace_recorder.zig:181`). |
| 6 | Mcode bloat from static materializers | **RESOLVED** | §4.6 replaces them with a compact exit location map and lazy adapters built when an exit reaches `hotexit`. |
| 7 | Tier-1a materialization locus | **RESOLVED** | §4.7 places it inside `irinterp.executeImpl`, matching `.precise_resume`. |

---

## 2. Soundness analysis of the new Revision-2 mechanics

### 2.1 Materialize-first (§4.4) — SOUND
- Because state at `P` is completely coherent in the slab, tier-0 resumes without needing to replay any prefix.
- Recording starts at `P` in `interp.zig` right before the mirror records `P`'s instruction, mirroring how continuation recordings start (`pending_exit_anchor`, `src/interp.zig:2698-2700`).
- Slots load lazily via `refOf` with type guards, exactly like root traces.

### 2.2 Boundary ordinals and `tropt` survival (§4.2) — SOUND
- **DCE:** sunk stores (`.astore`, `.hstore`, `.ustore`, `.astore_append`) are classified as `OpKind.astore` (`src/tropt.zig:137, 711`), unconditional liveness roots (`src/tropt.zig:555`).
- **CSE & compaction:** `tropt` remaps operand refs through `new_index[canon[...]]` (`src/tropt.zig:832-835`); the instruction is copied verbatim (`var out = ins;`, `src/tropt.zig:796`), so an ordinal field survives.
- **LICM:** memory stores and guards are excluded from invariant hoisting (`src/tropt.zig:711`).
- **Snapshot refs:** Phase 1 must treat them as liveness roots (`src/tropt.zig:555`); already recognised in §4.2.

### 2.3 Lazy exit adapters and location map validity (§4.6) — SOUND
- `nativegen_alloc.zig:795-812`: extending `last_use` to the guard keeps registers from being freed before it.
- Register assignments are static for the compiled trace; values are not re-spilled mid-lifetime.
- Frame layout is fixed (`SPILL_MAX * 8` bytes in the shared trampoline); spills sit at fixed `[rsp + idx*8]`.
- On a guard failure, execution branches to the mini-stub then the adapter with `rsp` and all allocatable registers (`r8..r15`, `rbp`, `xmm2..xmm15`) undisturbed.

### 2.4 `.exit` anchors and resume-at-`P` coherence (§4.4) — SOUND
- The exit-side trace's sunk stores sit at its end (before `.link`); on an internal guard failure they have not executed.
- Carried homes at entry hold values loaded from the slab at `P`. In-place coalescing is prohibited if any side exit follows (`src/nativegen_alloc.zig:1093`), so homes still hold entry values at a deopt exit.
- Tier-0 resumes at `P` with the slab state preserved from entry.

### 2.5 Strike exemption and thrashing bounds (§4.9) — SOUND
- Once latched DONE without a side trace, zero-progress exits strike the anchor normally (`accountLegacyThrash`, `src/trace_regionops.zig:84`).
- With `tryside = 4`, `hotexit = 10` and `maxside = 100`, unpenalised zero-progress receipts per root are strictly bounded.

### 2.6 Ledger rows, replay grammar and silent promotion (§4.8) — SOUND, with finding 1 below.

### 2.7 Determinism (§4.10) — SOUND. Decisions use integer counters, constants and bytecode coordinates only.

---

## 3. Answers to open questions

### Q3 — Snapshot liveness cost
Proceed, measuring in Phase 1. Under register pressure the allocator spills (`loc[i] = .{ .spill = spill_count }`, `nativegen_alloc.zig:1212`); with `SPILL_MAX = 512` spilling does not fail. A spilled ref is read in the adapter with an ordinary `mov rax, [rsp + disp]`; on the hot non-exiting path it is written once and never read. Specify that liveness extension applies only to attachable exits and only to `.def` slots of sparse snapshots.

### Q6 — Non-branch resume
Enforce the strict pre-effect gate in `exitAttachable`. Operand type guards, table identity guards and bounds guards precede any register definition or heap mutation; in store bytecodes the store is inline (pure write, C1 idempotent) or sunk, and the current bytecode's sunk stores are excluded (§4.1). In Phase 2, `exitAttachable` should assert that the guard's bytecode has performed no irreversible effect before the guard.

### Q7 — The cell test without a scratch register
Adopt option 1 (RIP-relative memory test); reject option 2. `src/nativegen_alloc.zig:180`:

```zig
pub const ALLOC_ORDER = [_]Reg{ .r8, .r9, .r10, .r11, .rbp, .r12, .r13, .r14, .r15 };
```

`rax` and `rcx` are never allocated; they are transient scratch only. Reserving an allocatable register would cut GP registers from 9 to 8 across the whole language (Rule Z-6). Option 1:

```
cmp qword [rip + cell], 0
jne .Lto_adapter
; fallthrough: default anchor-coherent path
.Lto_adapter:
jmp qword [rip + cell]
```

uses zero registers, and inside the adapter `rax`/`rcx` are free.

### Q8 — Exec-log `ExitKind`
No new `ExitKind`. The parent logs its standard guard exit and the side trace logs its entry, as with `sibling_handoff`.

---

## 4. Numbered findings

### 1. [MAJOR] Owner election fails on `.exit` anchors due to raw tagged pc comparisons
- **Evidence:** `src/trace_region_topology_build.zig:413-421`, `src/trace_code.zig:84-120`.
- **Analysis:** the enclosure predicate for a dispatcher-entered cycle compares `b.pc <= a.pc or b.pc > flp` on raw anchor pcs. A tagged `.exit` pc is above `2^30`, so `b.pc > flp` is true, `enclosing` is false, owner election fails (`both_count == 0`) and the region mints `armable = false`. Per Rule Z-8, silent promotion is then permanently blocked and the cycle pays per-row ledger costs and hits `LEDGER_CAP` forever.
- **Required change:** in §4.8 and Phase 6, decode with `entryPc(b.pc)` before the comparison.

### 2. [MAJOR] Q7 must reject register reservation (Rule Z-6)
- **Evidence:** doc 56 Q7, `src/nativegen_alloc.zig:180`.
- **Required change:** resolve Q7 with option 1 (RIP-relative test and indirect jump through co-located data cells) and discard option 2.

### 3. [MINOR] Dynamic table references in sunk stores need `aref.a` in the location map
- **Evidence:** `src/nativegen_alloc.zig:775-782`, `src/nativegen_emit.zig:2351, 2371`.
- **Analysis:** `emitAStore` loads the array data pointer from `aref_ins.a`. For invariant slots the table pointer is pinned in a home; for dynamic tables `nativegen_alloc.zig:777` extends liveness to `aref_ins.a`.
- **Required change:** clarify in §4.2 that "operands of preceding sunk stores" include `aref.a` for dynamic tables.

### 4. [NIT] Define `EXIT_PC_BIT` and update `AnchorPcKind`
- **Evidence:** `src/trace_code.zig:84-120` (bit 31 is `CONT_PC_BIT`, `0xFFFFFFFF` is `FUNC_HEAD_PC`).
- **Required change:** `pub const EXIT_PC_BIT: u32 = 1 << 30;` and update `anchorKind()`, `entryPc()` and `trace_mod.anchorKind()`.

---

## 5. Summary

The Revision-2 architecture is sound, follows Pall's reference model, and respects mahina's determinism, deopt and ledger-replay invariants. With the four findings above folded in, doc 56 is ready to execute.
