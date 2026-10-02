# Doc 60 rev 2 — codex review (2026-10-02)

Reviewer: Codex (configured default model), thread 01a0fb6c-cb8f-7fe0-90bb-c8c3f0667b02.
Source review only; no files modified, no tests run.

CHANGES REQUESTED

## BLOCKERS

1. **The assembly contract contradicts its representation boundary.** Rev 2 says assembly never interprets optionals, but assigns it `final_cut = null` during entry. `Vm.final_cut` is `?FinalCut`; checking its field offset and size does not establish the optional's null encoding. This needs a Zig-owned mutation before frame push, or an explicitly checked primitive representation. Slice access and `code_cache = empty` also need a concrete representation contract.

   Evidence: doc60:162, doc60:247, interp.zig:676, interp.zig:2021, interp.zig:409.

2. **The shim's protected-error context is unspecified.** The proposed signature receives `*Vm`, callee base and stop depth, but its promised error handling requires `*VmBox`, the original entry depth, and the original stack top. Recovery is possible, but the document must define it. In the surplus-vararg layout, callee `base` is **not** `entry_top`; restoring it would retain the argument region and close the wrong range of upvalues.

   Also define initialization of `out_status`, make status authoritative on every return, and specify the success word's encoding. "Returns a sentinel" currently supplies neither a value nor its interpretation.

   Evidence: doc60:220, doc60:270, capi.zig:345, capi.zig:399, interp.zig:2176, interp.zig:342.

3. **Pre-commit park checks cannot guarantee successful result parking.** Results' heap types and count become known after execution. Moreover, callbacks can make nested API calls that append parked values, consuming capacity that was available at entry. The design supplies only pre-commit fallback and guest-error handling; neither handles this post-execution capacity failure.

   Specify a Zig continuation for success cleanup and result-parking overflow, without executing the guest again. Preserve today's distinct result-parking OOM behavior: execution has completed, top/reentry are restored, `nresults` remains zero, and the VM is not poisoned merely by this parking failure. Eager allocation for `max_results` would change allocation and OOM timing relative to the reference.

   Evidence: doc60:189, doc60:264, capi.zig:313, capi.zig:325, capi.zig:392, interp.zig:2213.

4. **The fast-word synchronization mechanism remains incomplete.** Moving storage onto `TraceState` resolves the VM-backpointer problem, but two ownership gaps remain:

   - `TraceState` cannot recompute all nine conditions "from the fields": two fields belong to `Vm`. Trace resets must preserve VM-owned bits, or receive their values through an explicit interface.
   - Recorder success/abort/OOM boundaries operate on standalone `RecordingSession`, which likewise has no connection to `TraceState.fast_block`. Specify synchronization at the owning TraceState boundaries, including recorder-triggered aborts inside `recordInstr`, failed starts, and successful or failed finalization.

   The shim assertion covers admitted assembly calls. A stale set bit rejects admission and bypasses that assertion; validation must also cover rejection decisions or explicitly guaranteed fallback checks.

   Evidence: doc60:350, doc60:362, doc60:368, trace_recorder.zig:996, trace_recorder.zig:1262, trace_recorder.zig:6077, trace.zig:3360, trace_link.zig:207.

## SHOULD-FIX

1. **Make the assembly entry, shim and fallback linkage concrete.** `callconv(.c)` specifies a calling convention; the proposed private `fn hostcallChain` does not establish an externally named assembly symbol. Specify its exported internal name/visibility and the exact C-callable H1 fallback interface.

   Identify which layer owns fatal refusal, null-handle/output checks, argument validation and `nresults = 0`. The tail fallback must restore its caller's stack and preserve every original argument, including stack-passed arguments if it mirrors `mh_call`.

   Evidence: doc60:193, doc60:220, capi.zig:78, capi.zig:692, mahina.h:149.

2. **Gate on the supported ABI/object format, not architecture alone.** The build condition admits every x86-64 target, while the routine is specified as SysV. The pinned toolchain's `.c` convention is target-dependent and includes a separate Windows x64 convention. Either narrow admission or specify additional implementations.

   Add concrete PIC/link, symbol-visibility and unwind acceptance checks. CFI alone does not guarantee the stated `perf record -g` result; specify DWARF call-graph collection or the required frame-pointer configuration. Verify ordinary return and fallback unwind paths.

   Evidence: doc60:135, doc60:173, build.zig:10, pinned std/lang.zig:128.

3. **Keep stage 1 independent of the packed-word implementation, and complete artifact coverage.** Replacing shared `runFastPath` means "today's path" can use the same faulty mask as H1. Preserve the original nine-condition predicate in the reference leg or independently test every mutation transition against it.

   Explicitly compare serialized effect logs and committed traces, not only counters and keyframes; enumerate the supported tier/record/replay matrix. Compare parking multiplicity and order rather than only set membership: duplicate parks consume capacity. Add reentry-limit and call-sequence-exhaustion cases, null argument/result/output pointers, and a callback that exhausts park capacity before the outer call returns heap results.

   Keyframes deliberately exclude parked roots, so snapshot equality cannot substitute for those checks.

   Evidence: doc60:386, doc60:394, doc60:425, interp.zig:2555, interp.zig:2385, capi.zig:681.

4. **The ledger is more complete, but its totals remain optimistic.** The 15–20-instruction preflight row must include condition branches, dependent closure/proto loads, argument validation and park accounting. There is no explicit owner for the assembly routine's own register saves/restores, stack setup, preservation across the shim, and fallback argument reconstruction. Normal assembly entry plus ordinary Zig shim still creates two callable boundaries.

   A substantial reduction is plausible; **90–120 internal / 180–230 public is not yet substantiated**. Keep the measured admission gate. Expand measurements beyond argument/result counts to varying register-window sizes and large argument/park-overflow workloads: binding, validation, parking and nil-fill scale with those sizes.

   Evidence: doc60:321, doc60:333, interp.zig:2164, capi.zig:714, doc59:134.

5. **Q6 trade-offs: storage location and pending representation are separate decisions.** A TraceState mask retains standalone operation and permits simultaneous pending requests, at the cost of maintaining a derived invariant and preserving the two VM-owned bits during resets. A union can reduce independent payload bookkeeping if exclusivity is established, but changes request representation and overwrite policy. It still leaves recording and both VM controls to combine into the dispatch decision.

   The cited "INDEPENDENTLY" comment concerns per-owner watches accumulating independently of the arm-request slot; it does not prove coexistence or exclusivity among all six pending fields. These alternatives therefore need a lifecycle/coexistence audit before comparison. I make no selection.

   Evidence: doc60:375, doc60:484, trace.zig:1887, trace.zig:1906, interp.zig:4989.

6. **Q7 trade-offs: checked constants versus absolute symbols.** A checked include provides assembly-time constants, permitting compact displacement encodings and assembly-time expressions. It requires maintenance when consumed layout changes, and mandatory target-side evaluation of the checker. Check sizes, widths, alignments and tag/sentinel constants as well as field locations.

   Absolute symbols remove duplicated numeric values, but defer resolution until linking, generally force larger relocatable displacements, and limit expressions requiring assembler-known constants. Their definition, visibility, archive retention and relocation behavior need validation for the supported linker/object format. Static absolute-symbol relocations should also be distinguished from runtime address relocations when stating the PIC policy. I make no selection.

   `Module.addAssemblyFile` is verified. Capital-`.S` preprocessing remains explicitly unverified; the pinned stdlib also exposes `addCSourceFile` with `.assembly_with_preprocessor`.

   Evidence: doc60:150, doc60:157, pinned Build/Module.zig:435, Build/Module.zig:89.

## NITS

1. **Correct the fast-condition count and recorder citations.** Seven conditions belong to TraceState, not eight. Recorder `active` is cleared at line 6077 and set at 6144; line 6130 starts the allocation condition.

   Evidence: doc60:344, doc60:354, interp.zig:2556, trace_recorder.zig:6144.

2. **`cachedCodeFor` does not set `ExecState.code_gen`.** It updates the frame cache's generation. The caller assigns `st.code_gen` separately; retain that explicit shim responsibility.

   Evidence: doc60:197, interp.zig:2486, interp.zig:2652.

3. **Match the claimed error ordering to the source.** Today, `guestFault` clears `pending_error` immediately after rendering and before closing upvalues and dropping activations. Rev 2 places that clear after restoration. The current intervening operations do not collect, so this is not independently a demonstrated soundness failure, but an "ordered, unchanged" contract should reproduce the actual order.

   Evidence: doc60:275, capi.zig:352, interp.zig:7493.

4. **"Private fields" needs an enforcement strategy.** Existing external modules directly access TraceState fields without `pub` field declarations. Setter ownership needs caller migration and an audit/check; omitting `pub` does not hide Zig struct fields.

   Evidence: doc60:351, trace.zig:1625, interp.zig:4990, trace_gate_test.zig:1095.

5. **§10 overstates complete resolution.** Finding-by-finding disposition ("resolved" means resolved by the revised design, not implemented or tested):

   | Rev-1 findings | Rev-2 disposition |
   |---|---|
   | Codex B1 / Antigravity B4 | Resolved: input parking retained with lifetime regressions. |
   | Codex B2 / Antigravity B1 | Frame invalidation resolved; shim/protected context remains incomplete. |
   | Codex B3 / Antigravity B2–B3 | Mode resumption and trace cleanup resolved; complete error boundary remains unspecified. |
   | Codex B4 / Antigravity S6 | Partial: standalone TraceState preserved, synchronization gaps remain. |
   | Codex B5 / Antigravity S8, N10 | Hashgate scope and listed boundary cases resolved; independent oracle/artifact coverage remains incomplete. |
   | Codex S1 | Resolved: unchanged first prologue; no added `onCallEntry`. |
   | Codex S2 / Antigravity S5 | Partial: two inclusive ledgers added, accounting still incomplete. |
   | Codex S3 / Antigravity N9 | CFI convention added; ABI/linkage/representation gaps remain. |
   | Codex S4 / Antigravity S7 | Resolved: LuaJIT build-time generation, SIB support and executable-memory distinction corrected. |
   | Codex S5 | Resolved: measured H1 admission and H3 A/B gates explicit. |
   | Codex N1 | Resolved: handler C-convention conversion separated. |
   | Codex N2 | Resolved: serialized equality and normalized state distinguished. |
   | Antigravity N11 | Resolved within the proposed ABI: piecemeal handlers removed from scope. |

   Evidence: doc60:518, interp.zig:2494, interp.zig:6327, x64.zig:362, LuaJIT Makefile:675, LuaJIT vm_x64.dasc:649.
