# Doc 61 Phase 0 — codex review (2026-10-09)

Thread: 01a11ee9-5673-72d1-ac86-678680250a8c. Reviewed the uncommitted Phase 0
diff on top of ba6ce32 (coral-marten's in-flight capi fix excluded).

**REVISE**

The producer/consumer precision change introduces no false-dead slot for
compiler-emitted layouts: adjacency holds, consumer bases descend through
nested calls, survivors are conservative, and the extra requeue covers the
non-CFG dependencies. The marking simplifications also look sound for current
entry paths. No additional frame-classification error found in
suspend/restore, replay, push/pop, or unwind handling.

## Blockers

- **nativegen.zig:2641, trace_region_topology_build.zig:352: the bridge
  question exposes a real admitted coherence hole.** A `.loop` source can
  complete iterations while an accumulator remains solely in its carried
  home. If its update follows the guard, it is absent from E and the
  boundary's `.def` snapshot; the armed bridge skips its flush. The topology
  check labels a required non-E slot "invariant" without proving slab
  coherence. `.link` sources keep immutable entry homes
  (nativegen_alloc.zig:439), which explains why the sieve result is
  insufficient evidence. Flush the required carried state before overlaying
  E, or reject these sources, and pin an armed exit after local completions.
- **design:407, design:829: the new precision invalidates the stated path
  lemma for conservative multret rows.** A slot can be dead before the
  producer, unwritten because it lies above the actual dynamic top, then
  conservatively live in the consumer's whole-window row. A native consumer
  clears `reg_top_pending` and can collect while in flight, so safepoint
  suppression does not resolve this. Establish how Phase 1 excludes or
  canonicalizes that stale tail; the current theorem does not prove
  tier-identical rooting there. Exit-snapshot omission itself remains sound
  for actual guest reads.

## Should-fixes

- **interp.zig:3041, interp_semantics_test.zig:1922: pin the innermost pc
  during collection.** Every new probe runs inside a marked native. The
  safety assertion accepts a stale, in-range pc, so these tests do not detect
  removing the trampoline publication.
- **interp_semantics_test.zig:2098: assert native self-push actually
  occurs.** The reuse test can retain its expected output through tier-0
  pushes alone; check the push counter on the native leg.
- **bc_liveness.zig:476: measure long multret chains.** Walking the remaining
  chain separately for each producer costs quadratic chain work; the new
  backward requeue also walks chains. Add a representative/adversarial
  compile benchmark and budget.

## Nits

- **interp_semantics_test.zig:1896: misleading test name/comment.**
  `reg_top_pending` suppresses collection before this consumer; the test
  exercises collection after entering `g`.
- **design:649: reconcile the obsolete mandatory `guestFault` signature
  change with the implemented invariant.**

## Disposition

- **Blocker 1 (bridge carried homes):** accepted as real. It is pre-existing
  and independent of Phase 0's code. Tracked in TODO.md with this analysis
  and queued as the next task after Phase 0 (a repro with a `.loop`-closed
  armed source, then a flush or refusal, pinned by a test). Codex accepted
  the deferral.
- **Blocker 2 (conservative consumer rows):** recorded in doc 61 §5 as a
  Phase 1 prerequisite with options A / A′ / B and a Phase 1 checklist item.
  Codex accepted the deferral.
- **Should-fixes:** all done. The innermost-pc probe test was
  mutation-checked. The native-push witness is asserted on the native leg.
  Survivor sets are cached down a chain with O(1) requeues; there is a
  chain test and `bench/compile_multret_chain.lua`.
- **Nits:** both done.

## Re-review (same thread)

**REVISE — documentation only. No remaining Phase 0 implementation
blockers.** Both deferrals accepted. Two corrections:

- **design: include faulting consumers under `xpcall`.** A `b=all_results`
  call can fail before entering its callee (a rejected Lua push). The
  handler's `callValue` then marks that retained frame in flight at the
  consumer pc, and the handler can collect. So A′ must also cover failures
  before native/`__call` dispatch, and B must keep the bound before those
  failures.
- **design: remove "Programs cannot observe this" and the unconditional
  "latent" claim.** String survival affects re-interning allocations and
  subsequently printed object ids. The revised liveness already changes exit
  snapshots. Describe it as an unresolved potential determinism divergence
  accepted for this phase boundary.

The cache and requeue changes look sound. Changed dependency rows requeue
`k−2`, and the unconditional forwarding through chained producers carries
survivor changes even when their whole-window rows stay the same. For Phase
1 codex recommends **B**: it records the actual bound and filters during
collection, which avoids A/A′'s window-sized clearing on every call. Its
review must cover captured aliases, survivors, nesting and retained faulting
frames.

Both corrections were folded into §5.

## Final

**APPROVE for Phase 0.** The documentation corrections address the
remaining blockers. Accepted follow-ups: bridge coherence as the next task,
and consumer-tail handling before Phase 1 masking.

## Follow-up: blocker 1 fix (same thread)

The fix: `emitCompositeBridgeSnapshot` now flushes the carried homes (all
but E's slots) before E, through a new `emitCarriedHomesFlush`. The ordinary
deopt flush uses the same helper. A native test pins the bug: a `.loop`
source with an accumulator updated after the composite guard runs four local
iterations before it bridges. Before the fix the accumulator read 100; it
now reads the correct 104.

**APPROVE, no blockers.**
- The order (carried homes, then E) is correct and complete. Write-only
  slots already commit at back-edges, and invariant homes never change.
- The cap path (`bridge_full`) takes the ordinary deopt, so it flushes once
  and commits no E.
- No register-clobber hazard: `flushSlot` clobbers only rax, which allocation
  excludes.
- The bridge owes nothing else that the deopt does. Materialization precedes
  the silent check, so silent bridges get the fix too.

Two nits, both done: the stale "flushes ONLY slot-bound φs" comment in
`classifyBridgeCandidate`, and the silent-deopt epilogue's duplicate loop,
which now calls the helper.
