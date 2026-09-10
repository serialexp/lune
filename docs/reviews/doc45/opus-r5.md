The Write tool is disabled in this session, so I'll deliver the review here.

# Doc 45 Revision 5 — **APPROVE for implementation**

No design blockers remain. This is design approval only; the code currently in the tree is *not* approved, and R5 correctly says so.

## Every normative citation checks out against source

| Contract claim | Source | Result |
|---|---|---|
| `IrInstr.snap` reserved; `SnapIdx = u32`, `Ref = u16` | `trace_ir.zig:19,26,700` | ✅ 2000 snapshots and 65535 refs both representable |
| `guard_absent` = ordinal 87, last in `IrOp` | `trace_ir.zig:670` (`terminal` = 86) | ✅ `tnew` 88 / `tset` 89 are the right appends |
| `guard_absent` missing from `isSideExitGuardOp` | `trace_ir.zig:726-731` | ✅ D7's fix is real |
| …and adding it touches only penalty/headroom | sole call site `trace_regionops.zig:147`; `trace_link`/`trace_chain` merely import it | ✅ `guardExitPc` stays null → no chaining side effect |
| …and does not break the pinned "no callout op joins the set" test | `tropt.zig:1325-1335` (list excludes it) | ✅ |
| **Defect A1** | `nativegen.zig:1816` (`.none` when `href_key[i]`) vs `:1950-1956` (guard_absent inspects `t.instrs[ins.b]` structurally, never `kinds[ins.b]`); callout `:6773` does `placeToReg(.rsi, placeOfRef(ins.b))` | ✅ **real and reachable — unmaterialized pointer into the callout** |
| Misplaced `guard_func` comment | `nativegen.zig:1944-1949` sits above the `.guard_absent` arm | ✅ |
| `trace_finalize.zig:52-53` raw `entry_slots` filter | exact | ✅ |
| `tropt.dupe` at `:85` doesn't prune eager loads | `tropt.zig:319-331` is three `gpa.dupe`s | ✅ "(it does not)" correct |
| `loop_leave` re-arm to `hotloop -\|1` | `trace.zig:3365-3382` | ✅ verbatim precedent |
| head/cont need their own re-arm | `trace.zig:3201-3206`, `3258-3263` (reset-to-0, fire on `>= hotcall`) | ✅ well-defined |
| `Table.set` non-transactional | `table.zig:298-299`, `302-332` ("the lane commit may survive the unwind"), `348-359` | ✅ all three ranges exact |
| OOM uncatchable / TypeError catchable | `interp.zig:6705-6728` | ✅ exact |
| `heap.gpa == vm.gpa` | `gc.zig:109,163` + `interp.zig:858-862` | ✅ the D5 assert is valid |
| `LedgerKind` max 9 / `ExitReason` max 3 | `trace_exec.zig:194,197` / `:25-48` | ✅ 10, 11 and the appends are clean |
| `guard_gc` with `aux=0` ≡ `!shouldCollect()` | `irinterp.zig:738-750` vs `gc.zig:635` | ✅ zero-bound legalization is exactly right |
| `alloc_count > 0` assertion to relax | `trace_finalize.zig:33-36` | ✅ precisely scoped |
| Eager `guard_gc` compatible with `emitAlloc` | `trace_recorder.zig:1002-1008` (`if (guard_gc_ref == null)`) | ✅ pre-seeding the ref suppresses the lazy emit |
| Peel already refuses allocation | `trace_recorder.zig:4615` | ✅ D1's deferral is pre-enforced |
| `old_to_new` null for CSE-merged refs; canonical map needed | `tropt.zig:65-69,671-673,716`; `canon` at `:722` | ✅ real hazard, fixable from existing state |
| `.alloc` already a DCE liveness root | `tropt.zig:476` | ✅ `tnew` inherits dead-allocation-still-executes |
| A ref in `aux` is precedented | `.scratch3`: `tropt.zig:245,482,531-535,739-743` | ✅ `tset`'s `(a,b,aux-ref)` encoding is well-founded |
| `ret_cont` = bytecode PC, `call_head` = terminal IR index | `trace_link.zig:1237-1242` | ✅ D6's "never use slot_index as a snapshot index" is a live hazard |
| Ledger can silently drop an overflow row | `trace_exec.zig:50-60`, `LEDGER_CAP = 32` | ✅ D6's "space for the final row" is correctly mandatory |
| `maxrecord = 2000` | `trace.zig:525` | ✅ budget aligns with the existing bound |
| Boxed slots skipped by today's deopt flush | `nativegen.zig:7913` | ✅ D3's boxed-snapshot rule is necessary, not decorative |
| doc24 D3v2's four obligations | `24-deterministic-on-trace-allocation.md:244-255` | ✅ inherited verbatim |

## The one deep question I chased

D3 disables phi/home coalescing while D2 has unwritten slots reference **entry `slot_load`s** — so I checked whether a snapshot early in iteration ≥2 of a precise *loop* trace would flush a stale first-iteration value in native. Tier-1a is safe by construction (`.loop` does `continue :iter`, `irinterp.zig:1186-1200`, so `slot_load`s re-execute after phi writeback). Native is safe too: the carried-slot **home** holds the current iteration's entry value — `deopt_exit` flushes `slotHomePlace(s)` (`nativegen.zig:7908-7923`) and the back-edge shuffle writes the phi's `store_ref` into that home (`:7461-7483`). Coalescing (`:4159-4229`) is a win-2 optimization already gated on "no side-exit follows" (`:4202`) with the comment "the coalesced value IS snapshot state from j onward" (`:4223`). Disabling it is strictly conservative — one extra back-edge move, identical semantics. **The two tiers agree.**

## R4 mandatory clarifications — all landed in R5

256 **vectors** vs 2000 **records** vs 65536 **slots** with the explicit "the 256 limit applies to vectors, NOT records" (D2) · explicit counter re-arm cited to `loop_leave`, extended to head/cont (D2) · eager `guard_gc` including zero-bound mutating traces with the assertion relaxed only for that mode (D4) · `*Heap`/`heap.gpa` through the C ABI, never an `Allocator` fat value (D5) · `interp.catchable` named with the OOM/TypeError split (D5) · checked per-boundary failure order (D2) · explicit multret_top/stack_top/close-upvalue refusals (D2). Approval does not rest on anything left open.

## Non-blocking notes (refinements, not conditions)

1. **Slot-array length type.** 65536 `SnapshotSlot` entries straddles a `uint16` length prefix by exactly one — use `uint32` (`schema/trace.json:65,109` pattern) or the bound silently becomes 65535.
2. **`guard_gc`'s snapshot is implied, not stated.** D2's per-bytecode rule plus D4's placement makes it snapshot #1 (body-entry map, no register written yet). One sentence removes the inference.
3. **`boxedPassThroughOnly` also gates on terminator kind** (`nativegen.zig:1520`: `.terminal`/`.link` only). A precise *loop* trace needs that relaxed too, not just the snapshot-only-use admission — otherwise any unproven entry register bails the page to tier-1a. Correct, but it will surface in D3's "measure refusals and frame sizes".
4. **Cosmetic.** Line 419-420 lost spaces: "is399.1ms", "with159869 native pops/159819".

## Why this is an approve, not a conditional

A1 is held as a P0 gate with fail-closed-on-`.none` as the interim, not waved through. The single-ordered-IR-from-the-start decision removes the whole class of mid-recording remap hazards R4 objected to, and the needs_precise cancel + next-anchor re-record replaces retroactive promotion with a deterministic, address-free, per-anchor policy that matches an existing precedent line-for-line. Legacy isolation is stated as an invariant with its own gate row rather than assumed. Nothing in the contract defers a decision that would change the design if resolved the other way.

I kept all 19 global rules plus the project's Z-rules in mind — in particular Rule #0.5 (A1 is a pre-existing bug and is named as one), Rule #3 (no success proclaimed; this is a design verdict, and the tree is not green on A1), Rule #17 (verdict and blockers, not a judgement about what you should want), and Z-6 (checked that admission is governed by bytecode shape, never benchmark names — D1 says so explicitly).
