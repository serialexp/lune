# Doc 60 rev 3 — codex review (2026-10-03)

Reviewer: Codex (configured default model), thread 01a0ff7d-4739-7101-be5d-96603aad96d7.
Source review; no project tests run. (Its compiler probe left an untracked
assembler-output file named `-` in the repo root; reported to Bart, left untouched.)

CHANGES REQUESTED

## BLOCKERS

1. **The preflight still permits null-buffer dereferences.** The public wrapper validates only `vm` and `nresults`; the assembly then validates arguments and later copies results without specifying checks for `args` or `results`.

   Today, `args == null && nargs > 0` returns `.err_api`, while `results == null` means an empty output buffer even when `max_results > 0`. Following §4.1/§4.3 literally can instead dereference either pointer. Specify both behaviors before admission and test null pointers with zero **and nonzero** lengths.

   Evidence: doc60:287, doc60:303, doc60:425; capi.zig:681, capi.zig:708.

2. **The representation boundary still contradicts the assembly's required work.** Moving `final_cut` into Zig and invalidating only `code_cache_gen` resolves those particular accesses. It does **not** resolve slice access generally.

   Binding, nil-fill, capacity checks and result gathering require `Vm.tags.ptr`, `Vm.payloads.ptr` and a capacity currently obtained from `payloads.len`. Idle park clearing also requires clearing `parked_results.items.len`. These are slice representations, which §3.2 expressly prohibits assembly from interpreting or writing. Outer field offsets and sizes do not establish their component layout.

   Specify primitive pointer/length interfaces or an explicit, verified representation exception covering every consumed component. Codex rev-2 B1 remains partially unresolved.

   Evidence: doc60:234, doc60:391; interp.zig:573, interp.zig:803, interp.zig:1067, interp.zig:1080; capi.zig:313.

## SHOULD-FIX

1. **§5.4's non-exclusivity conclusion is supported, but the audit contains incorrect lifecycle claims and is incomplete.**

   - Frame-link requests are consumed when the dispatcher **selects and enters** a trace, including an existing trace—not only when a matching child commits. Requests can survive a recording, but recording is not their mandatory lifecycle.
   - `maybeArmContinuation` also rejects active recording and an existing exit anchor. `maybeArmExitSide` also checks recording, barred anchors and population capacity. The prime-side transfer has an earlier exit-anchor return that its quoted local condition omits.
   - The audit omits the replay-anchor producer `consumeSideTraceWantAtResume`, which checks recording/replay state but permits an outstanding exit anchor.
   - The exit-plus-return example is supported for a **non-boundary return**: `opRet` calls `onRetResume` without clearing the outstanding exit request, and `onRetResume` does not reject that request. Boundary returns bypass this producer.

   Retaining the mask is justified. Correct the producer/consumer inventory, include displacement, stale-parent cleanup and cache clearing, and add reachable coexistence cases to the mutation tests.

   Evidence: trace.zig:1001, trace.zig:1906, trace.zig:3193, trace.zig:3448; trace_link.zig:145, trace_link.zig:233, trace_link.zig:2650; interp.zig:4039, interp.zig:4690, interp.zig:6560.

2. **Complete the fast-word test migration and define bit-exact validation.** Production synchronization now has an identifiable owner, including failed starts, recorder aborts, finalization and preservation of VM bits during trace resets. However, numerous tests start an **owned** recorder directly through `state.rec.reset`; these are distinct from standalone `RecordingSession` tests. Their starts bypass the proposed owner synchronization.

   Also, `fastPathReference()` returns one boolean. Comparing `fast_block == 0` against that boolean cannot detect a missing or extra bit while another condition remains active. Mutation tests should compare an independently reconstructed nine-bit word and exercise overlapping conditions, selective clearing and VM-bit-preserving resets.

   Evidence: doc60:582, doc60:609, doc60:629; trace_record_test.zig:51, interp_trace_test.zig:1700, interp.zig:2555.

3. **Specify module placement and actual symbol linkage.** The proposed shim combines C-API responsibilities (`VmBox`, `guestFault`) with private interpreter machinery (`ExecState`, `cachedCodeFor`, `execWith`, `chainEntry`). Placing it in `capi.zig` cannot access those private declarations as written; placing it in the VM core would introduce the C-API dependency.

   Define the VM-owned Zig runner and the C-API-owned C-ABI shim separately, with the intended visibility between them. Also name and declare the architecture entry, and specify hidden `@export` linkage for the assembly-callable Zig functions. `callconv(.c)` alone still does not create those external symbols. §4.2 lists three declarations while referring to four hidden symbols.

   Evidence: doc60:319, doc60:344; capi.zig:46, capi.zig:79, capi.zig:192, capi.zig:345; interp.zig:2515, interp.zig:2584, interp.zig:2652, interp.zig:2978.

4. **The unwind and visibility acceptance checks can give misleading results.** A tail-called `mh_call` has no retained physical frame, so the promised stack walk cannot require `mh_call → entry`. Maintaining `rbp` in assembly also does not establish frame-pointer unwinding through the Zig shim and arbitrary host callbacks.

   Require traversal across the retained boundaries, define frame-pointer settings for the FP test, and test DWARF separately. For visibility, inspect archive-member symbol visibility and link a shared-library/PIE consumer. `nm -D` on `libmahina.a` does not verify hidden ELF symbols, and relocatable-object relocation listings alone do not establish absence of dynamic text relocations.

   Evidence: doc60:189, doc60:259, doc60:294; build.zig:106, build.zig:115; pinned Module.zig:214, Module.zig:227.

5. **macOS support requires more than assembly macros.** The current C-API constructor unconditionally installs explicitly Linux-only clock and entropy implementations using `std.os.linux`. Thus Q8's macOS entry needs a portable host-source prerequisite and an actual target build/link acceptance case. Checking Mach-O directive spelling alone is insufficient.

   Evidence: doc60:170; capi.zig:414, capi.zig:450.

6. **The delayed `final_cut` clear needs an explicit H1 distinction.** The statement that frame push does not read it is false in Debug: `pushFrameTrusted` asserts `final_cut == null`. Delaying the clear is viable for the assembly's manual push, but H1 must clear it before using the existing Zig pusher, or specify another push implementation. Add a call after a genuine top-level finish, when the previous cut can be non-null.

   Evidence: doc60:244, doc60:413; interp.zig:2021, interp.zig:2100, interp.zig:2452.

7. **§10 still needs verified dispositions rather than blanket closure.** Rev-2 check:

   | Rev-2 finding | Rev-3 disposition |
   |---|---|
   | Codex B1 | Partial: optional/cache fixes addressed; slice contract remains blocked. |
   | Codex B2 / Antigravity B2 | Resolved at design level: box, original boundary, stop depth, authoritative status and result encoding specified. |
   | Codex B3 / Antigravity B3 | Resolved at design level: post-execution overflow helper preserves parking order and existing OOM behavior. |
   | Codex B4 / Antigravity S5 | Production ownership addressed; owned-recorder test migration/validation remains incomplete. |
   | Antigravity B1 | Resolved for the original null-VM/null-`nresults`/fatal findings; new buffer gap is BLOCKER 1. |
   | Codex S1 / Antigravity S4 | Partial: public layering settled; concrete linkage/module seam remains. |
   | Codex S2 | Partial: ABI gate addressed; unwind/link acceptance remains incomplete. |
   | Codex S3 | Addressed: independent oracle, serialized logs/traces, park multiplicity and requested boundary cases included. |
   | Codex S4 | Addressed: additional ledger rows, scaling shapes and estimates explicitly unsubstantiated. |
   | Codex S5 / Antigravity Q6 | Partial: non-exclusivity supported; audit needs correction. |
   | Codex S6 / Antigravity Q7 | Decision settled; checked-layout inventory still needs completion below. |
   | Antigravity S6, S7 | Addressed: pre-prologue fallback and target-gated checker. |
   | Codex N1; Antigravity N8–N10 | Addressed: seven trace conditions, corrected recorder set line, `ExecState` excluded, register status return. |
   | Codex N2–N4 | Addressed: explicit `code_gen`, correct `guestFault` ordering, migration/review enforcement. |
   | Codex N5 | Unresolved: splitting the table does not establish complete resolution. |

   "Resolved" here means specified by the design, not implemented or tested.

## NITS

1. **`always_tail` failure is a compile error, not an automatic extra frame.** Describe a failed H2 check accordingly; an ordinary-call alternative would require explicitly changing the call modifier and reconsidering Q9.

   Evidence: doc60:296; pinned lang.zig:880.

2. **Complete the checked-layout inventory.** Include `TraceState.fast_block`, `ChainResult` size/member offsets, consumed alignments, and explicit `FrameResult` bit offsets. The listed `@offsetOf`/`@sizeOf`/`@bitSizeOf` checks do not by themselves specify packed-field bit positions. Clarify that the debug rejection scratch retains a compatible physical layout across Debug/ReleaseFast, or provide configuration-specific offsets.

   Evidence: doc60:203, doc60:352, doc60:615; interp.zig:342.

3. **Correct the remaining audit details.** There are **10**, not 12, standalone tests in `trace_recorder.zig`; they begin at line 6148. Line 1262 clears recording during finalization, rather than demonstrating self-abort inside `recordInstr`. Z-6 concerns general language performance; the no-tiering-change constraint is this document's §2.

   Evidence: doc60:561, doc60:584; trace_recorder.zig:1254, trace_recorder.zig:6148.
