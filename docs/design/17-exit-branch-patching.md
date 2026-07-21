# Exit-Branch Patching (Direct Side-Trace Linking) — Design

Status: partial — Increment 1 (shared mcode arena, P-D), Increment 2.1 (frameless chain-entry ABI, P-A), Increment 2.2 (chain-wide result contract, P-B), Increment 2.3a (indirect exit + link-slot table + P-E registry scaffolding), Increment 2.3b (2.3b-0 inert scaffolding + 2.3b-1 flip arming on), Increment 2.3c-0 (inert contracts a–f + post-review blocker fixes: memory-staged `exit_target`, reserved-cell removal, `final`-first exclusion), Increment 2.3c-1 (M1 half-fusion: arm skip→prime-side ordinary source-branch guard + dispatcher fused-`.link` consumer), Increment 2.3c-2a (per-transition ledger ABI + native emission at all four exit sites + terminal-consistency assert, no accounting change), and Increment 2.3c-2b (route `runLinkedBurst`'s native call-B drain through ledger replay — `runCapturingLedger` + phase-machine `replayContinuationLedger`, ≤2-entry release-enforced, no accounting change) landed; all byte-identical. Direction chosen (faithful port; re-architect lune's native traces toward LuaJIT's frameless shared-arena model). Native trace bodies run frameless under one shared trampoline (`ensureTrampoline`); every native exit stub jumps through a per-exit heap-resident link slot (`jmp qword [&slots[i]]`, default = `shared_exit`) and bakes the final trace's stable id into `NativeResult.final_trace_id`. As of 2.3c-0f/blocker-fix, ordinary/loop-done-ordinary guards route through the shared `deopt_exit` flush, which dispatches the RESOLVED target via the flush-immune `NativeResult.exit_target` memory field (`jmp qword [rdx+exit_target]`) — no reserved slot cell, no rax-staged holder. As of 2.3b-1, `driveChain` ARMS the continuation's `.link`-terminal slot → `inner.linked_entry`, so a native run of the continuation fuses straight into the inner root under the shared frame (no ~600ns Zig re-entry per hop). The dispatcher resolves `final = traceById(final_trace_id)` STRICTLY on the native path (`@panic` on null, no `ct` fallback), and `final != ct` is now expected. `driveChain` drains fused results by resolving each child strictly by `final_trace_id` + `isInnerLoopRoot` shape check (unresolvable/mis-shaped ⇒ `@panic`, no unsafe resume). The P-E backlink registry (`armed_links` + `armNativeLink`/`resetLinksTouching`, reset before `destroy` in `removeTrace`) is now LIVE for `.link` slots AND (2.3c-1) `.ordinary_guard` source-branch slots. As of 2.3c-1, `driveChain` also arms the skip trace's source-branch guard → the prime-side ramp's `ordinary_entry`, and the dispatcher gained a fused top-level `.link` consumer (`fusedSourceBranchLinkSlot` provenance recognizer → `onSideExit(ct, skip_local)` replay → `runLinkedBurst`) so skip→ramp fuses into one native call. Next: Increment 2.3c-2c — persistent loop-done inner→continuation, closing the native cycle. Re-scoped 2026-07-14 after a codex pre-impl BLOCKER + a follow-up APPROVE-WITH-CHANGES review: because a persistently-armed I→C cycle is also entered where no ledger is captured (call A, dispatcher native runs), the safe path is capture-everywhere — a 6-sub-step sequence (2c-A ledger disambiguation ABI → 2c-B forced-yield cap → 2c-C single generic `replayLedger` returning a terminal directive → 2c-D capture at call A + dispatcher with exact M1 parity → 2c-E arm I→C persistently → 2c-F disarm load-bearing test + review). The ledger ABI (2.3c-2a) and the ≤2-entry call-B replay (2.3c-2b) are the foundation; 2c-C/2c-D generalize the drain and 2c-E flips the cycle-closing arm. **As of 2026-07-14, 2c-A through 2c-E have all LANDED byte-identical — the native `continuation↔inner` cycle is CLOSED** (`armLoopDoneLink` at 3 sites incl. the `replayLedger` convergence arm; a native one-trip correctness fix; 5 blocking tests green; nsieve/mandelbrot/nbody/spectral-norm tier-0==tier-1a==native). A permanent compile-gated JIT debug facility (`src/jitdbg.zig`, `-Djit-debug`/`--jit-debug`) replaced the ad-hoc `std.debug.print` scaffolding used through this arc. **2c-F COMPLETE (2026-07-14)** — the two-phase same-VM disarm integration test + negative control + supported cold-re-entry guard landed, and the full codex `gpt-5.6-sol` review of the arc ran: every supported path sound, one rerun blocker raised and resolved by exit-slot hardening (derive-not-trust target + in-page entry validation) plus `Vm.run`/`start` epoch containment (`beginTopLevelEpoch` → `disarmAllLinks`). Increment 2.3c-2c closes; the native continuation↔inner cycle is closed and its lifetime hardened. See §Implementation status → Outstanding for the per-sub-step record. **Increment 3 DESIGN landed 2026-07-17** (pre-impl review pending): re-scoped after a fresh `--jit-stats` profile + a decisive throwaway A/B (disabling the gate lifts nsieve:14 from 5.0%→92.8% traced but moves wall time only ~1%) proved the wall is **per-transition Zig re-entry on the still-open branch-loop region, not codegen or the indirect-slot load**. Two sequenced parts: **3A** arms the one missing edge — `cont(29).composite-guard → skip(14).ordinary_entry` (the mirror of M1/2.3c-1) — closing `skip→ramp→inner→cont→skip` as one `LEDGER_CAP`-bounded native region so `onSideExit(nsieve:14, …)` clears ≥ `min_useful` and the anchor never gates; **3B** is the faithful `lj_asm_patchexit` rel32 port + the in-place-patch P-E hardening, measure-gated. Four blocking review questions on 3A (edge-4 header coherence, the composite-back-edge no-yield safe-point hole, `safe_to_arm`/disarm coverage of the new cycle, P-EBP accounting parity). **codex `gpt-5.6-sol` pre-impl review (2026-07-17) = BLOCKER**: two Part-A claims unsound — (1) edge-4 coherence (cont's composite guard is coherent at cont's anchor, not skip's header → needs its own materialization contract, not `.ordinary_guard` reuse); (2) the "summed composite count → never gates" mechanism is retracted (`replayLedger` bills per-segment local deltas; the M1 grammar is same-anchor-only and panics on an `rbx`-advancing successor). Gate-clear now hinges on a Bart fork: (a) per-segment accounting + armed entry bypassing `isGated`, then measure; or (b) region-level accounting as a P-EBP-2 redesign. Part B: "co-location ⇒ rel32 reaches" is false (arena defers cross-region reachability), a raw rel32 bypasses the forced-yield cap, ordinary guards lack a per-exit patch point, discovery needs a cross-anchor PC map. Antigravity (gemini-3.1-pro) review = confirms both blockers + adds option (c) exempt-armed + a mid-burst-gate correction + a "fix trace selection" reframe. **RESOLVED 2026-07-17 (Bart):** trace-selection investigated and RULED OUT — doc 15 + the recorder (`recForPrepLink` LINNER) + `luajit -jdump=t` on the same nsieve (3 self-loop roots + 8 side traces patched into roots) all show lune fragments **byte-for-byte identically to LuaJIT**, so "record as one trace" is the exact thing both tried-and-rejected; arming/patching (Increment 3) is confirmed the LuaJIT-faithful path. **Part A design of record** (§Part A (RESOLVED)): edge-4 gets its own bridge/materialization (`asm_head_side`-style, commits cont's outer-back-edge phis — NOT `.ordinary_guard` reuse) + **gate strategy B (region-level accounting)** chosen over (c) exempt-armed (B measures the right unit, correct regardless of transition cost, retains cold-region retirement; C is "trust arming ⇒ profitable", valid only post-patching + needs a separate flush). New cross-anchor replay grammar + region-membership map. `min_useful` retune is a Part-B-landing obligation; B→C hybrid for proven regions is a measure-gated future opt. See §Increment 3 → Review outcome + §Part A (RESOLVED). **ROUND-3 DESIGN WRITTEN 2026-07-17** (§Part A — round-3 design): all nine round-2 blocker items now have concrete code-grounded contracts — bridge dominance snapshot (filtered by `update_index < 23` + successor-liveness) via `flushSlot`/`placeOfRef`, enter `skip.ordinary_entry` (guard re-run resolves the invariant-bypass hazard), `inputs.len==0`, an **in-page bridge stub** (parallel to `linked_loop_done_labels`, lifetime covered by the existing registry for free) + `ArmKind.region_bridge`; `onSideExit` split into `accountTraceRun` (per-segment, preserves `hit_count` selection) vs `accountRegionProfit` (penalty/gate, a lone trace = degenerate 1-member region → identical to today), normalized outer-traversal unit, identity `RegionKey` owned by `AnchorKey(proto,14)`, one persistent accumulator on **logical** (not physical `LEDGER_CAP`/hop) windows with GC-safepoint exclusion; additive `.region_bridge` ledger arm that leaves the same-anchor `.deopt` provenance (3098)/zero-progress (2159) invariants intact. Reframe correction: an armed ordinary guard is already a native in-page handoff (edge 4 is the *only* per-iteration Zig re-entry), and edge 4's coherence gap is exact (cont's `count+1`/`next i` dominate `%023` but their phi writebacks are post-guard, so the shared `deopt_exit` flush commits stale values). **ROUND-3 REVIEW (codex `gpt-5.6-sol` + Antigravity) = BLOCKER (both)** — sound sub-parts confirmed (A.1.1–1.3, A.2.1–2.3, A.3); 9 converging fixes for a **round-4 pass** (§Review outcome — round 3): B-1 forced-yield must cap-check-first→ordinary-deopt (commit-then-yield breaks the terminal-consistency assert + replay); B-2 unarmed stub must stage `exit_target`; B-3 the compile-time bridge classifier is temporally impossible (native lowering has no region map; pages memoized) → an emission-strategy fork (precompute / generic stubs / recompile) = Bart's call; B-4 the logical-window accumulator must be a persistent VM-level region table (NOT trace state, NOT flushed on GC-physical retirement) with stack-depth-gated region-exit + tier-independent membership; B-5..B-9 smaller precisions. No code until round-4 is clean. **ROUND-4 DESIGN WRITTEN 2026-07-17** (§Part A — round-4 design): all nine resolved — Bart's B-3 fork = **(b) generic stubs, armed later** (trace-local bridge stub at every composite guard, no region map at lowering); cap-check-FIRST then commit, reusing the `ordinary_mini` path for both unarmed and ledger-full (B-1/B-2, byte-identical when unarmed); a **persistent VM-level region table** (proto/VM lifetime, NOT trace state, NOT flushed on retirement) with a stack-depth-gated region-exit + activation-keyed `RegionKey` + logical window `N = min_useful` (B-4); a tier-independent `(proto, exit_pc)` classifier at all three accounting sites (B-6); successor live-in ∪ live-through set (B-5); replay-owned resume PC via the edge map (B-7); synthesized `completed` preserved in `accountTraceRun` (B-8); stub-free/map-explicit split lifetimes (B-9). **ROUND-4 REVIEW (codex `gpt-5.6-sol` + Antigravity) = BLOCKER (both)** — direction reconfirmed sound, most of B-1..B-9 resolved; five converging round-5 must-fixes (D-1..D-5) unified by "the LOGICAL region layer persists at Proto/VM lifetime + is identity/edge-keyed; only the PHYSICAL armed-edge slot layer is retirement-cleaned": D-1 cap-check reserve-2-cells off-by-one (`>= CAP-1`); D-2 compile-time set E vs arm-time set S (drop `final_trace_id`, child `inputs.len==0` is arm-time); D-3 accounting-state (window `+=N`, identity `region_id`, no invented `FrameId`, membership from the recorded trace graph in every tier); D-4 classifier keyed `(trace_id, exit_instr)` + split at every `onSideExit` site; D-5 ‡ logical map never retirement-cleaned. One scope fork (D-3c recursion handling) = Bart's call. See §Review outcome — round 4. No code until round-5 is clean. **ROUND-5 DESIGN WRITTEN 2026-07-17** (§Part A — round-5 design): all resolved with Bart's D-3c = **(β) build activation discrimination** (deterministic per-VM monotonic `call_seq` on `CallFrame`, gc_stress-invariant); D-1 two-cell cap reservation + unreachable-`CAP` invariant; D-2 compile-time set E vs arm-time set S (drop `final_trace_id`, child `inputs.len==0` at arm time); D-3 three-map split + identity `RegionId` + window `+= N` + `call_seq` activation identity + discovery from the trace graph in every tier; D-4 `(trace_id, exit_instr)` classifier + split at every site; D-5 logical maps Proto/VM-owned, only `armed_links` retirement-cleaned; D-6 precisions. **ROUND-5 REVIEW (codex `gpt-5.6-sol` + Antigravity) = BLOCKER (both)** — edge-4 bridge (D-1/D-2/D-6) now SOUND; surviving blockers are integration surfaces (E-1..E-7): E-1 `RegionDef` keyed by ephemeral `Trace.id` (need stable structural edge id); E-2 `call_seq` can't be a physical `CallFrame` counter under trace inlining; E-3 classifier key absent at synthetic scalar `onSideExit` sites; E-4 overlapping-PC region exit; E-5 keyframe schema v4→v5; E-6 coroutine thread-scoped depth; E-7 error-unwind cleanup. The review re-weights D-3c=β (E-2 + `call_seq` half of E-5 are β-only; α avoids them) — **α/β RE-CALL surfaced to Bart** before round 6. See §Review outcome — round 5. **ROUND-6 DESIGN WRITTEN 2026-07-17** (§Part A — round-6 design), preceded by three parallel tree-grounding sweeps (trace inlining+deopt / keyframe schema / coroutine+error-unwind): all E-1..E-7 resolved, with **one reshaping insight ‡** — `region_profit` + `call_seq` are **transient JIT-tiering state, NOT replay-serialized** (same category as the trace cache / `safepoint_seq` / `effect_cursor`, none of which ride the keyframe), because they steer only *which tier* runs and never *what it computes* (native ≡ tier-0). That **collapses E-5 to no schema bump** (keyframe stays v4; reset-on-restore, which is the reviewers' own "logical region reset" alternative made rigorous — strictly safer for `encodeSnapshot∘restore==identity`) and **collapses E-2** (the activation key is the *anchor* frame's `call_seq`, assigned in tier-0 at `pushFrameVararg` `interp.zig:1346` before tier-up and never mutated on-trace since inlined callees push no physical frame — tier-invariant, no new IR op, no loop-carried commit discipline). E-1 stable `StructuralEdgeId{anchor_proto_id,anchor_pc,exit_pc,succ_anchor_pc}` + ephemeral `(Trace.id,exit_instr)` cache; E-3 optional `?ExitKey` (synthetic sites region-neutral); E-4 identity-transition exit under PC overlap; E-6 no coroutines exist (host-reentrancy `native_reentry_depth` handled instead); E-7 two teardown hooks (`.ret`/`.halt` pop + `protectedCall` `entry_depth` restore), `__gc` moot (finalizer-free GC). β fully preserved (one `u64` on `CallFrame` + one choke-point bump). **E-5 deviation from the round-5 v4→v5 resolution is flagged in-doc for Bart + round-6 reviewers to veto.** **ROUND-6 REVIEW (codex `gpt-5.6-sol` + Antigravity) 2026-07-17 = reshaping insight SURVIVES / BLOCKER on restore path.** codex confirms it directly ("a v4→v5 schema bump is not inherently required") → **the E-5 deviation is VINDICATED, keyframe stays v4**; Antigravity returned UNSOUND but its sharpest counterexamples (address-dependent `pairs()`, side-exit callee-frame reconstruction, `__gc` finalizers, background compilation) are all defused by lune facts codex verified (id-monotonic address-independent iteration, resume-at-loop-header deopt, finalizer-free GC, synchronous compilation). Surviving round-7 items (F-1..F-8): F-1 ‡ `StructuralEdgeId` can collide (multiple guards share `cur_pc`) → needs a stable guard-ordinal/role discriminator; **F-2 ‡ restore is a physical-frame construction path** (`keyframeser.zig:671`) → "reset call_seq=0" is WRONG, must **re-key each restored live frame with a fresh transient `call_seq` by frame order** (still no wire field, v4 holds); F-3 exact-current-frame (`frames[depth-1]`) invariant, not proto-match + `next_call_seq` exhaustion contract; F-4 JIT/VM share the allocator → post-restore tiering divergence could OOM one timeline (fork: exclude/isolate/fail-closed); F-5 current F2c harness is tier-0-only → owe a native-F2c test; F-6 E-6 exit-test polarity was backwards (`current_depth <= captured_anchor_depth`); F-7 host-abort boundary (non-catchable faults don't guarantee VM teardown; fork) + centralize cleanup with `protectedCall`'s 3-site depth restore; F-8 ground (not assert) that tier-dependent `safepoint_seq` can't perturb effect-log cuts. Both reviewers agree the layering is right; the work is restore-path precision. Two forks (F-4, F-7) for Bart. No code until round-7 clean. **ROUND-7 DESIGN WRITTEN 2026-07-17** (§Part A — round-7 design), grounded in two more tree sweeps (allocator arch; effect-log drivers): F-1..F-8 all resolved and **both forks collapsed** — F-4 (mcode is a separate `mmap`, `gpa` unbounded by default → OOM-divergence is pre-existing to native tiering and outside replay equivalence; JIT-allocator isolation flagged as optional Bart tightening) and F-7 (monotonic `call_seq` keys ⇒ no correctness hazard; extend the existing `beginTopLevelEpoch` to clear `region_profit` + the existing cap). F-2 ‡ restore re-keys each live frame `call_seq=i` by index (keyframe stays **v4**, no wire field); F-1 structural key gains a recording-stable `exit_ordinal`; F-3 exact-`frames[depth-1]` + exhaustion contract; F-5 native-F2c test obligation; F-6 exit polarity fixed; F-8 grounded non-issue (effect log logical-order-keyed/tier-independent). **ROUND-7 REVIEW (codex `gpt-5.6-sol` + Antigravity) = BLOCKER (both) — two deep new findings on the JIT↔snapshot boundary.** F-3/F-4/F-5/F-6 resolved (F-4 reworded: replay-equivalence is conditional on no allocator/mcode exhaustion). Surviving/new (G-n): **G-1 ‡** `exit_ordinal` by IR position is NOT re-recording-stable (recording is guest-value-dependent — `guardNum` int/float, array-guard variance, guard elision/LICM) AND `guardExitPc` (`trace.zig:451`) can't supply `exit_pc` for array/table/grid guards at all → need a canonical guest-logical guard identity carried as new IR metadata; **G-2 ‡ (the deep one, CONFIRMED against the tree)** the transient trace cache roots heap objects INTO the serialized snapshot — `keyframeser.zig:265` seeds its walk from the shared `forEachRootHeader`, whose item 5 roots trace/recording consts (which may be the sole ref to an otherwise-dead heap object) → a tiering-dependent `region_profit` history can change snapshot bytes (latent only because the F2c harness is tier-0-only) → need JIT-independent snapshot reachability; **G-3** a bounded/LRU cap can evict LIVE activation accounting + no enforced clean-entry rule; **G-4** a native F2c cut selected by safepoint count is tier-dependent → define the cut by a tier-independent logical event; **G-5** Antigravity's coroutine cross-stack re-key collision (grounded N/A — lune has a single physical stack; invariant pinned). **ROUND-8 DESIGN WRITTEN 2026-07-17** (§Part A — round-8 design): G-1 replaces the IR-position ordinal with a guest-logical `GuardProvenance{source_proto_id,source_pc,inline_depth,role,operand,occurrence}` tag stamped at emission for ALL guard kinds (an IR extension); **G-2 splits `forEachRootHeader` into `{gc, snapshot}` kinds — trace/recording consts are GC-liveness roots only, excluded from the snapshot semantic-root walk**, with a case-1/case-2 proof (every trace const is either semantic-reachable ⇒ unchanged, or trace-only-and-semantically-dead ⇒ correctly dropped because deopt recomputes it at the loop header) — the general fix, making ALL snapshotting JIT-independent by construction; G-3 makes activation-scoped cleanup MANDATORY (entry lifetime = activation lifetime ⇒ cap can never evict live) + unconditional `beginTopLevelEpoch` region-clear; G-4 tier-independent logical cut + effect-cursor assertion; G-5 single-stack re-key invariant pinned. Keyframe stays **v4**. Two new impl obligations: the `GuardProvenance` IR extension + the `{gc,snapshot}` root-walk split. **ROUND-8 REVIEW (codex `gpt-5.6-sol` + Antigravity) = BLOCKER (both) — a FOUNDATIONAL finding, both reviewers built the SAME counterexample.** **H-2 ‡‡ (escalated to Bart):** the `{gc,snapshot}` split is necessary but NOT sufficient — dropping a **trace-only interned** const changes the observable heap-**id** timeline (uninterrupted VM re-finds the interned obj → same id; restored VM re-allocates → different id), and ids are semantic (equality `value.zig:197`, table hash `table.zig:545`, `pairs` order `key_order.zig:21`, `tostring` `io.zig:166`); `next_obj_id` is unserialized (`keyframeser.zig:521`) and the F2c test already only supports programs with no discarded pre-cut objects (`keyframeser.zig:1755`). This is **broader than Increment 3** and likely **forces serializing `next_obj_id` → keyframe schema bump, reversing the reshaping insight** — OR restricting when snapshots may be cut. Mechanics blockers survive: **H-1** `GuardProvenance` collides (`inline_depth` ≠ call-path; `source_pc` is post-increment resume-PC; derived-value guards under-defined → need per-opcode `GuardSite` vocab + inline call-site path); **H-3** cap-eviction bound unproven + `beginTopLevelEpoch` clean-entry not enforced; **H-4** only "after Nth committed effect" cut is implementable (native overshoots iterations). **G-5 RESOLVED.** **H-2 escalated to Bart for a scope/architecture call before round 9; no code.**
Owner: Bart
Last updated: 2026-07-21 (**A-i COMPLETE (9-B GuardProvenance) — the exit-identity substrate is fully landed and inert.** All four green byte-identical sub-steps in the tree (A-i.1 types+storage+`tropt` remap → A-i.2 inline-path capture → A-i.3 stamp every guard + 3 fused producer-exits → A-i.4 `.link`-terminal transport); `just test` green (default + `-Djit-debug`), nsieve/nbody/mandelbrot tier-0 ≡ native byte-identical throughout. GuardProvenance is populated at every guard, fused native producer-exit, and `.link` terminal, remapped through `tropt` to committed indices, and queryable via `Trace.provAt` — but unread until the Part-A region classifier (A-ii) consumes it. Design reviewer-certified (§A4, round-10 APPROVE). Next: A-ii per §A8. — earlier: 2026-07-19 (**Part-A design APPROVED — round-10 `gpt-5.6-sol` pre-impl review = APPROVE.** "The consolidated Part-A contract is now implementation-ready." Ten review rounds (1–9 BLOCKER, all folded; 10 APPROVE); the region-accounting state machine, physical classification keys, edge-4 bridge, and §A8 landing sequence are buildable without further design decisions. One non-blocking cleanup applied (A-iv "cap" → no-cap lifetime invariant). **This is Bart's Part-A design-approval checkpoint.** — earlier: **Part-A round-9 `gpt-5.6-sol` review = BLOCKER, 1 finding folded** (destination-state correction): collapsing "successor not yet selected" into destination `∅` wrongly closed the region (cap-yield / unfused / forced-yield / terminal-`.link_terminal` are not exits). Destination classification is now three states — `deferred` (retain, no flush/close), `known(set)` (apply the table; `known(∅)` genuinely closes), `terminal_outside` (proven exit closes). Three tests added; `.link_terminal` clarified as a concrete keyed receipt. Core sound across all nine rounds. — earlier: **Part-A round-8 `gpt-5.6-sol` review = BLOCKER, 1 finding folded** (the `.link` transport passed; last candidate-production correction): classification must be keyed physically, not by the logical `StructuralEdgeId` — sibling traces at one anchor share a boundary `StructuralEdgeId` while only one segment belongs to R. So `source_exit_regions` is keyed by `ExitKey{Trace.id, exit_instr}` (owner resolved before `local`) and `dest_entry_regions` by the runtime-selected successor trace (deferring open until one exists); `StructuralEdgeId` stays the logical interning/rebind key only. Sibling-trace tests added. Core sound across all eight rounds. — earlier: **Part-A round-7 `gpt-5.6-sol` review = BLOCKER, both folded** (both correct real mechanism transport/definition, no model change): (1) `.link` is synthesized at commit not at `recForPrepLink` (link traces bypass `tropt.optimize`), so `.link_terminal` provenance needs a `Recorder.pending_link_provenance` transport consumed at commit; (2) region identity vs boundary classification are now separated — reverse indices built over every committed edge (source keyed by the producing segment's membership incl. leaving edges), boundary edges kept out of the intern set, so a nonzero-work boundary exit credits R before close. Core sound across all seven rounds. — earlier: **Part-A round-6 `gpt-5.6-sol` review = BLOCKER, both folded** (both "define the missing piece," no model change): (1) edge 2's `.link` terminal is not a guard, so the edge-key provenance became an `ExitProvenance` union `{guard | link_terminal}`; (2) candidate sets are produced by two reverse indices (`edge_source_regions`/`edge_destination_regions`) and the transition phase operates on `?selected_source`, giving the outside→region entry (zero source, one destination) an explicit "open D" row. Core sound across all six rounds. — earlier: **Part-A round-5 `gpt-5.6-sol` review = BLOCKER, both folded** (both "complete the fail-closed table," no model change): (1) `invalidateRegion(id)` is now a concrete conservative-global-teardown operation (physical `NativeLink` has no region identity, so: tombstone `armable=false`, drop `region_profit` entries, `disarmAllLinks()`, recheck `armable` before every arm); (2) receipt source/destination normalization is now a complete `(active, candidate-set)` table — every none/A × ∅/{X}/∋A/{B}/{≥2} pair pinned, incl. active-A-matches-zero-regions ⇒ close-A-now and active-id-wins-on-tie. Core sound across all five rounds. — earlier: **Part-A round-4 `gpt-5.6-sol` review = BLOCKER, both folded** (narrow identity/state-machine precision; recorded-path membership confirmed buildable): (1) `StructuralEdgeId` gains `succ_anchor_proto_id`, and one `RegionId` → exactly one `RegionDef` (incompatible rediscovery marks the id ambiguous/unarmable + disarms its links, never mints a second def); (2) receipt processing gains three source-normalization steps (classify to one source RegionId or fail closed; open if none active; close the active-but-different one first) covering first-entry + A-active/B-source. Core sound across all four rounds. — earlier: **Part-A round-3 `gpt-5.6-sol` review = BLOCKER, all four folded** (consolidation-hygiene only, runtime direction re-confirmed correct): (1) collision-safe interned `RegionId` on the full sorted `StructuralEdgeId` set moved INTO consolidated §A3.3 (not just historical D.3.2), complete edge key not the reduced tuple, `polarity` added to the declared `GuardProvenance` struct; (2) membership built from recorded `{proto_id, source_pc}` paths (pre-IR-opt transient metadata), not un-buildable "CFG corridors"; (3) receipt processing order fixed 1–6 so a receipt that both credits work and exits doesn't lose terminal work; (4) three retracted instructions in the "single contract" section corrected (A3.2 per-window not per-burst, A-viii dispatcher-mediated-native oracle not tier-0, A9 Q6 option (a)). — earlier: **Part-A round-2 `gpt-5.6-sol` review = BLOCKER, all six folded** (R2-1 `r>0` exit-flush + orthogonal `segment_delta`/`transition_edge` per receipt; R2-2 dedicated `observeRegionProgramPoint` hook in `nextOp` + `{proto_id,pc}` membership; R2-3 `RegionId` = full sorted structural-edge-set equality, hash only accelerates; R2-4 disarm ⇒ dispatcher-mediated native entries not tier-0 bodies + corrected A-viii oracle; R2-5 common `onEffectCommitted()` across all four commit sites `3976/4017/4058/4089`; R2-6 P-EBP-2 = normalized-accounting equivalence over the same receipt stream), plus **Q3 resolved** (keep `min_useful=8` as the initial correctness constant; measure the general workload suite when A-vii lands, never tune to nsieve — Rule Z-6) and **Q6 resolved = option (a)** (schema-bump `FrameRef` with `varargs_base`/`varargs_count` as its own foundational-piece ticket before Part-A F2c). Core re-confirmed sound both rounds; status now pending round-3 re-review. — earlier this day: **Doc-hygiene pass + starting the Increment-3 Part-A close-out arc.** Flipped two stale checkboxes whose own bodies already said done: **2.3c-2c** (persistent `I.loopdone→C` cycle — all six sub-steps 2c-A..2c-F landed 2026-07-14; verified in-tree: `armLoopDoneLink` at `trace.zig:1772/1836/2113`, ledger `replayLedger`, `linked_one_trip` fix, `native_link_disarms` epoch containment) and **P-C** (loop-done slot-exclusivity invariant enforced at emission `nativegen.zig:4563` + arming `armNativeLink` `trace.zig:3274`). Also closed the compile→run chunk-constant GC hole flagged as the H-2 follow-up ticket (`feat(gc)` commit — `Vm.retained_chunks` borrow list rooted in both `forEachRootHeader` walks; see `docs/design/03-gc-memory.md`). Then **wrote §"Part A — CONSOLIDATED buildable design (2026-07-19)"**: assembles rounds 3–8 + the H-series groundings + the 2026-07-18 landings into one buildable spec (five mechanisms — edge-4 bridge / region accounting + gate B / GuardProvenance 9-B un-deferred / H-3 cap / H-4 native-F2c cut — an 8-step byte-identical landing sequence, five reviewer questions), folding the two post-round-8 changes: H-2 CLOSED ⇒ Part A no longer gated by it (snapshot bytes JIT-tiering-independent by construction), and 9-A's two preconditions landed. Pending a fresh gpt-5.6-sol pre-impl review → APPROVE before any code (per Bart's cadence: autonomous, checkpoint at the Part-A APPROVE boundary). — earlier, 2026-07-18: **H-2 HARD-HALF CLOSED — all three parts LANDED.** The complete fix shipped as three gated commits: **part (2)** `{gc,snapshot}` root-walk split (`forEachRootHeader` gains a comptime `RootKind`; trace/recording consts are `.gc`-only, excluded from the snapshot walk — closes the final-snapshot facet for static *and* dynamic trace consts); **part (1)** dynamic-proto tracing gate (`Proto.dynamic` bit stamped by `assignProtoIds`, set at the `load`/`loadfile`/`dofile` + keyframe-recompile sites; four gates in `trace.zig` — `arm`, `maybeStartContinuation`/`maybeStartReplaySide` after the pending-null-clear, `recCall`→`abort(.dynamic_proto)` — closes the mid-run dropped-`load`-closure facet); **part (3)** `TraceState.clearCache()` from `beginTopLevelEpoch` after `disarmAllLinks()` (frees every trace mid-VM-life, mcode slots returned to the retained arena, and resets the full tiering+diagnostic reset set incl. `exec_logs`/`coverage`/`abort_log` cross-epoch `*Proto`-borrow hazards — closes the cross-epoch `depth==0` GC-liveness facet). Each part: design → gpt-5.6-sol review (each returned BLOCKER, corrections folded, then re-APPROVE) → landed behind `just test` (782) + `-Djit-debug`, all load-bearing by negative control. **All 10 modes + keyframe restore now byte-identical for `load`ed/dropped-closure/multi-epoch programs — H-2 is closed.** One latent product concern surfaced + noted for a separate ticket (gpt-5.6-sol-confirmed): a freshly-`compile`d-but-not-yet-run chunk's heap-valued constants are rooted by nothing (`Chunk` doesn't root them; `gc.zig` marks only via a live closure), so an interleaving GC can sweep them in the compile→run window. — earlier this day: **H-2 HARD-HALF DESIGN written** (§"H-2 hard half — design"): grounding **refuted** the round-8 reviewers' "materialized folded string" mechanism — `irinterp.evalBinary`/`evalUnary` take no allocator (`arith.*` can't intern), `concat` aborts the trace (`trace.zig:4096`), every heap `konst` is a proto literal (`trace.zig:3992`), and the static proto tree is redundantly rooted whole-program by the main closure via recursive `markProtoConstants` (`gc.zig:526-529`). The REAL, pre-existing hole is narrow: a `load`/`loadfile`/`dofile` chunk (separate proto tree, closure NOT retained in `loaded_chunks` `stdlib/load.zig:145,154`) whose sole closure is dropped after a trace over it was recorded (traces never retire) ⇒ the trace const becomes the SOLE root of a proto-literal string ⇒ cross-mode (`.off` sweeps it, record-mode keeps it → divergent re-intern id under GC) + snapshot-restore id divergence. Bart's direction (of 3 options): **gate trace recording to the static proto tree** — never anchor in / inline a dynamic proto. Deterministic predicate `isDynamic(proto)` (explicit `Proto.dynamic` bit, or id-boundary `id ≥ static_count`), checked at all THREE arm sites (`rec.reset` choke: `arm`/`maybeStartContinuation`/`maybeStartReplaySide` `trace.zig:3657/2997/3018`) + a `recCall` `abort(.dynamic_proto)` on inlining a dynamic callee. **gpt-5.6-sol review = BLOCKER (tree-verified): the gate is sound but NECESSARY-not-sufficient** — `forEachRootHeader` roots static-tree closures only while `depth>0` (`interp.zig:1612`), so at `depth==0` (final snapshot `keyframeser.zig:252`, and the next top-level epoch) a static literal referenced only by a cached trace is a sole-root trace const too. Corrected complete fix = **(1) dynamic-proto gate + (2) `{gc,snapshot}` root-walk split (G-2 is NEEDED, not moot) + (3) `beginTopLevelEpoch` trace-cache clear**; tests must assert on ids/`pairs`/snapshot bytes, not trace presence. Escalated to Bart (larger than first approved). Piece 1 (`next_obj_id` v4→v5) already landed. — earlier this day: **ROUND-9 LANDING PLAN written** (§round-8 review → "Round-9 landing plan"): sequences the grounded blockers into code. Scope split — **9-A** (small/safe/immediate): `pure ⇒ !effect` at the one builtin-install choke point (`interp.zig:916`) + a `depth==0` clean-entry precondition before `beginTopLevelEpoch`'s disarm (sub-fork: fail-closed assert vs skip-reset, needs `disarmAllLinks`-on-suspended-VM characterized); **9-B** (foundational plumbing, no consumer yet): the `GuardProvenance` IR extension as a **transient side table** keyed by instr index — NOT a field on `IrInstr` (which serializes via `schema.IrInstr` `traceser.zig:67` ⇒ a field would bump the wire schema + bloat every instr; and provenance is transient JIT-tiering state the reshaping insight already excludes from serialization), so zero schema bump, rebuilt on re-record. Tag = 3 axes `{path, source_pc, role, operand}` (`occurrence` retired): `path` needs the H-1a `InlineFrame{+caller_proto_id,+call_pc}` (bounded `MAX_INLINE_DEPTH=3` ⇒ inline `[3]`, no alloc); `source_pc` stamped explicitly for the 13 non-PC guards + 3 fused producers (`aux` is consumed there); `role`/`operand` stamped at emission. Safety net (no consumer ⇒ weak): 10-mode matrix + a re-record-stability unit test + an H-1a collision test. **Deferred to Increment-3 machinery** (NOT round 9): the F2c native-cut harness (H-4 cut) + region cap contract (H-3 cap) — they need `region_profit`/native-F2c. **gpt-5.6-sol review = BLOCKER → resolved (design only), 6 defects all tree-verified + folded** (§"Review outcome — round-9 landing plan"): ‡ the damaging one — an emission-time instr-index key is STALE at commit (`tropt.optimize` renumbers/drops/reorders `tropt.zig:299-537`) ⇒ provenance must be optimizer-remapped via `new_index` + copied by `dupe`; the tag dropped leaf `source_proto_id` (cross-proto collision) + mis-sized the path (leaf split out, `[3]` = edges only); the schema-bump justification was wrong (`traceser` maps 6 fields explicitly ⇒ side table chosen for the 16-byte budget); `pure⇒!effect` needs comptime-over-tables + restore assert (`.manual`/restore/package/synthetic bypass `interp.zig:916`); the `depth!=0` skip-reset option is unsound (`run`/`start` push a fresh frame) ⇒ fail-closed release-enforced; stamping is structural in the `emit` helper (omitted `recArrayGet`/`recHashGet`/`recForPrepLink`), `source_pc = cur_pc−1`, lane ordinal is NOT an operand. **Then LANDED 9-A** (commit `9fcc2c4`): `pure ⇒ !effect` comptime check over `base_natives` + restore assert; `depth==0` fail-closed via `Error.DirtyTopLevelEntry` in `beginTopLevelEpoch`, load-bearing suspended-VM test (negative-control-proven); `just test` green (default + `-Djit-debug`), nsieve tier-0≡native. **9-B DEFERRED** (Bart): design-clean but large, optimizer-touching (`tropt` remap), and no consumer ⇒ co-design with region accounting / Increment 3 when it needs the tags. Round-9 landing stops here. — earlier this day: **H-3 + H-4 GROUNDED** (§round-8 review → "H-3 grounding" / "H-4 grounding"), the two mechanics blockers. **H-3:** the `region_profit` map doesn't exist yet (unlanded design); call depth is hard-bounded (`max_call_depth = 200`, `interp.zig:119`), so the live-region set is bounded once round 9 states a per-`(activation,anchor)` cardinality invariant ⇒ **fail-closed or strict-lifetime map is safe, *silent* evict-live banned**. Clean-entry gap is REAL and broader than framed — `depth` has no reset (`pcall`/keyframe-restore aside), and *any* uncaught error leaves frames live (invariant `interp.zig:1454`) **plus** a suspended VM is a second dirty-entry case ⇒ round 9 needs a **`depth==0` precondition checked BEFORE `disarmAllLinks`**. **H-4:** `suspend_ctl` is tier-0-only (`:1716`, safepoint-counted) and native runs bursts, so a safepoint cut is tier-dependent (G-4); host effects abort the trace (`.host_barrier` `trace.zig:5046`) so **the tier-0 boundary after the Nth committed effect is the one implementable tier-independent cut** — but the barrier isn't structural (`pure`/`effect` independent fields ⇒ enforce `pure ⇒ !effect`), the immediate post-effect boundary isn't always suspendable (`reg_top_pending` multret gate `:1719/3685`) ⇒ cut at *first eligible* boundary after effect N, and assert full **semantic keyframe** + replay-driver state, not `effect_cursor` alone. `gpt-5.6-sol` = NEEDS-CHANGE (both), every correction tree-verified + folded (StackOverflow is catchable contra my draft; `depth` moved by more than ±1; region bound needs an explicit invariant; effect barrier + suspendability sharpened). No code. — earlier this day: **H-1c GROUNDED** (§round-8 review → "H-1c grounding"): pinned the per-opcode guard-site vocabulary that completes `GuardProvenance`. Load-bearing finding — the IR op kind is a runtime-varying attribute of a site (`guardNum`→int/float by value `trace.zig:4187`; `recBranch`→true/false by path `4834`), so identity must be a structural `role` not the op enum. `gpt-5.6-sol` = NEEDS-CHANGE, all folded: corrected the vocabulary table (set_index container is `a` not `b`; `for_loop`/`for_prep` guard three operand-types first; hash-set guards value first; grid guards row/col types; pure-call guards its arg; +`get_upval`/`get_global`→`guard_func` row), `guard_fits` is every-narrow-lane not int-only, `role` is a closed vocab with a **runtime-selected realized subset** (array-vs-hash/closure-vs-pure routing), and — decisively — **`occurrence` is REFUTED and DROPPED**: recording-order is a dynamic ordinal (branch truthiness, inner-loop trip counts, cache-state), the `exit_ordinal` failure again; within one opcode-execution `(role,operand)` is already unique, duplicates come only from unrolling whose copy-index is inherently dynamic, so provenance keys the guest-static site `{source_pc, call-path, role, operand}` and unrolled physical copies **share** one tag (many-to-one). Plus a follow-on: fused `hload`/`aload`/`href` native exits (`nativegen.zig:4022/4120/3517`) aren't `guard_*` nodes → round-9 must role-tag + source-PC-stamp them too. Net identity = 3 axes not G-1's 4. No code. — earlier this day: **H-1a GROUNDED** (§round-8 review → "H-1a grounding"): the recorder's `InlineFrame` (`trace.zig:5324`) stores `{base_off,ret_dest,ret_count}` but neither the caller proto id nor the `.call` PC, so `f(a);f(b)` inlined give every guard in `f` an identical `{callee_proto,source_pc,inline_depth}` **and** identical `base_off` → real collision; fix = persist `{caller_proto_id=proto.id, call_pc=cur_pc−1}` per `InlineFrame` at `recCall`, giving `GuardProvenance`'s ordered call-path prefix (bounded by `MAX_INLINE_DEPTH=3`, additive +24B recorder-only, no wire/behaviour change). `gpt-5.6-sol` = CONFIRMED directional + 3 sharpenings (path is in the live VM stack not lost; necessary-not-sufficient ordered prefix — full identity still needs role/operand/occurrence; proto-id uniqueness is a compile/`load` precondition, and recursion is reachable to depth 3 contra doc-10). Land-now-vs-defer is Bart's call; recommend defer to the GuardProvenance landing. No code. — earlier this day: **H-5 GROUNDED — both hazards REAL, not N/A** (§round-8 review → "H-5 grounding"): `gpt-5.6-sol` adversarial pass refuted the "discharge as N/A" hypothesis, all findings tree-verified. **H-5(ii)** (metadata id leakage) — no *direct* leak (trace metadata is `gpa`/mmap, never `link`), but trace-const GC-rooting keeps an interned string alive that tier-0 sweeps → tier-dependent `next_obj_id` + intern identity = **H-2's hard half** (folds in, not separate; also corrected a stale premise — `new_table`/`concat`/`closure` abort `.nyi_opcode`, traces materialize no such objects today). **H-5(i)** (dead-register poisoning) — cut is tier-0-boundary-only + no mid-native cut (confirmed), BUT numeric-`for` traces omit dead expression temporaries from the exit snapshot (`trace.zig:3761`, proven `interp.zig:9180`), so a post-native-exit mid-execution cut serializes stale bytes vs tier-0 → **folds into F-5**, upgrading it from unverified obligation to a concrete bug the mandatory native-F2c test must catch. No code. — earlier this day: Foundational piece 2 — **H-1b LANDED** (§round-8 review → "Foundational piece 2 — H-1b design"): canonical `guardSourcePc` accessor names the source-opcode PC distinctly from the resume/exit PC, the 8 open-coded `guardExitPc(g)-1` derivations rerouted through it, conflated `cur_pc`/`emit`/`guardExitPc` docs fixed. Non-breaking (no `exit_pc`/`aux`/wire/control-flow value changed), 10-mode-invariant by construction. `gpt-5.6-sol` review = NEEDS-CHANGE→clean (independent known-index test, `guard_number` emit-fixture, doc-scope fix); `just test` green (772, default + `-Djit-debug`), nsieve byte-identical, test proven load-bearing (broken accessor reddens 16). — earlier: Part A ROUND-8 DESIGN — round-7 review = BLOCKER (both) with two deep findings on the JIT↔snapshot boundary, now resolved. **G-1**: the round-7 `exit_ordinal` is abandoned — it is NOT stable across re-recording (recording is guest-value-dependent: `guardNum` picks int/float, array-guard sequences vary, guard elision/LICM shifts ranks) and `guardExitPc` can't even supply `exit_pc` for array/table/grid guards — replaced by a guest-logical `GuardProvenance{source_proto_id,source_pc,inline_depth,role,operand,occurrence}` tag stamped at guard emission for ALL guard kinds (a new IR metadata obligation). **G-2 ‡ (the deep one, confirmed against the tree)**: the transient trace cache roots heap objects into the SERIALIZED snapshot (keyframeser seeds its walk from the shared `forEachRootHeader`, item 5 roots trace/recording consts, which can be the sole ref to an otherwise-dead object) → a tiering-dependent `region_profit` history can change snapshot bytes; resolved by splitting `forEachRootHeader` into `{gc, snapshot}` kinds so trace consts are GC-liveness roots ONLY (excluded from the snapshot semantic-root walk), with a case-1/case-2 proof — the general fix making all snapshotting JIT-independent by construction. **G-3**: activation-scoped `region_profit` cleanup made MANDATORY (entry lifetime = activation lifetime ⇒ the cap can never evict a live activation) + unconditional `beginTopLevelEpoch` region-clear. **G-4**: the native F2c cut is defined by a tier-independent logical event, asserting on effect-log cursors not safepoint counts. **G-5**: single-stack re-key invariant pinned (coroutine future-proofing). Keyframe stays **v4**. Two new impl obligations: the `GuardProvenance` IR extension + the `{gc,snapshot}` root-walk split. **ROUND-8 REVIEW (codex `gpt-5.6-sol` + Antigravity) = BLOCKER (both) — a FOUNDATIONAL finding, both reviewers built the SAME counterexample.** **H-2 ‡‡ (escalated to Bart):** the `{gc,snapshot}` split is necessary but NOT sufficient — dropping a **trace-only interned** const changes the observable heap-**id** timeline (uninterrupted VM re-finds the interned obj → same id; restored VM re-allocates → different id), and ids are semantic (equality `value.zig:197`, table hash `table.zig:545`, `pairs` order `key_order.zig:21`, `tostring` `io.zig:166`); `next_obj_id` is unserialized (`keyframeser.zig:521`) and the F2c test already only supports programs with no discarded pre-cut objects (`keyframeser.zig:1755`). This is **broader than Increment 3** and likely **forces serializing `next_obj_id` → keyframe schema bump, reversing the reshaping insight** — OR restricting when snapshots may be cut. Mechanics blockers survive: **H-1** `GuardProvenance` collides (`inline_depth` ≠ call-path; `source_pc` is post-increment resume-PC; derived-value guards under-defined → need per-opcode `GuardSite` vocab + inline call-site path); **H-3** cap-eviction bound unproven + `beginTopLevelEpoch` clean-entry not enforced; **H-4** only "after Nth committed effect" cut is implementable (native overshoots iterations). **G-5 RESOLVED.** **H-2 escalated to Bart for a scope/architecture call before round 9; no code.** — earlier this day: ROUND-6/7 — Reshaping insight ‡: `region_profit`+`call_seq` are transient JIT-tiering state, NOT replay-serialized — so E-5 needs **no keyframe schema bump** (v4 stays; reset-on-restore is accounting-neutral because tiering never affects output) and E-2's `call_seq` is the anchor frame's, assigned tier-0 at `pushFrameVararg` and never touched on-trace → tier-invariant, no new IR op. E-1 structural edge id + ephemeral cache; E-3 optional key; E-4 identity-transition exit; E-6 no coroutines (host-reentrancy depth instead); E-7 two teardown hooks + `__gc` moot. β preserved. E-5 deviation from round-5's v4→v5 flagged for veto. ROUND-6 REVIEW (codex+Antigravity) = reshaping insight SURVIVES (codex: "a v4→v5 schema bump is not inherently required" → E-5 deviation VINDICATED, keyframe stays v4; Antigravity UNSOUND but its counterexamples all defused by lune facts); BLOCKER on the restore path → round-7 items F-1..F-8, the central one being F-2 (restore must re-key live activations, not zero call_seq). Two forks (F-4 allocator exhaustion, F-7 host-abort boundary) for Bart. ROUND-7 DESIGN WRITTEN (§Part A — round-7 design): F-1..F-8 resolved + grounded, BOTH forks collapsed (F-4 mcode separate mmap / gpa unbounded → OOM pre-existing to native tiering, outside replay equivalence; F-7 monotonic keys → no correctness hazard, extend beginTopLevelEpoch + cap). F-2 ‡ restore re-keys live frames by index (v4 stays); F-1 exit_ordinal; F-3 exact-frame + exhaustion; F-5 native-F2c obligation; F-6 polarity fixed; F-8 non-issue. codex+Antigravity round-7 review PENDING; no code until clean. — earlier: Increment 3 DESIGN — re-scoped to "close the region, then patch" after a fresh `--jit-stats` profile showed nsieve:14 is 59% of wall / 5% traced because it is GATED, and a throwaway `max_penalty=1e9` A/B proved disabling the gate buys coverage (5.0%→92.8% traced) but NOT wall time (~1%), i.e. the wall is per-transition Zig re-entry on the open branch-loop region, not codegen. Part 3A arms the one missing edge `cont(29).composite-guard → skip(14).ordinary_entry` to close `skip→ramp→inner→cont→skip` as one native region (escaping the `onSideExit` gate); Part 3B is the faithful `lj_asm_patchexit` rel32 port + in-place-patch P-E, measure-gated. See §Increment 3 for the evidence table, the four-edge map, and the four blocking review questions. **codex `gpt-5.6-sol` pre-impl review = BLOCKER** (2026-07-17): edge-4 coherence unsound (needs its own materialization contract, not `.ordinary_guard` reuse) and the "summed composite count → never gates" mechanism retracted (`replayLedger` bills per-segment; M1 grammar is same-anchor only). Gate-clear now hinges on a Bart fork (per-segment + measure vs region-level P-EBP-2 redesign). Part B rel32-reachability/forced-yield-cap/per-exit-patch-point gaps recorded. **RESOLVED 2026-07-17 (Bart's call):** trace-selection reframe RULED OUT (doc 15 + recorder + `luajit -jdump` all show lune fragments identically to LuaJIT → arming/patching is the faithful path); Part A redesigned around **gate strategy B (region-level accounting)** + a dedicated **edge-4 bridge/materialization** (`asm_head_side`-style, commits cont's outer-back-edge phis, not `.ordinary_guard` reuse). B chosen over (c) exempt-armed: measures the right unit, correct regardless of transition cost, retains cold-region retirement C discards. Adds a cross-anchor replay grammar + region-membership map; `min_useful` retune is a Part-B obligation; B→C hybrid for proven regions is a future measure-gated opt. See §Increment 3 → §Part A (RESOLVED). **ROUND-3 DESIGN WRITTEN** (§Part A — round-3 design): all nine round-2 blocker items resolved with concrete, code-grounded contracts (bridge dominance snapshot / `ordinary_entry` entry / in-page stub lifetime / `ArmKind.region_bridge`; `onSideExit` split preserving `hit_count` selection / normalized unit / identity `RegionKey` owned by `AnchorKey(proto,14)` / persistent accumulator on logical windows / GC-safepoint exclusion; additive `.region_bridge` ledger arm). Reframe: an armed ordinary guard is already a native handoff → edge 4 is the only per-iteration Zig re-entry; its coherence gap is exact (cont's `count+1`/`next i` dominate `%023` but their phi writebacks are post-guard). Round-3 review = BLOCKER (both), 9 converging fixes (B-1..B-9). **ROUND-4 DESIGN WRITTEN** (§Part A — round-4 design) resolves all nine with Bart's B-3 fork = (b) generic stubs armed later: trace-local bridge stub at every composite guard; cap-check-first→`ordinary_mini` (B-1/B-2); persistent VM-level region table + stack-depth-gated exit + activation-keyed `RegionKey` (B-4); tier-independent `(proto,exit_pc)` classifier (B-6); live-in ∪ live-through set (B-5); replay-owned resume PC (B-7); synthesized `completed` (B-8); split stub-free/map-explicit lifetimes (B-9). Round-4 review = BLOCKER (both) — direction reconfirmed, most resolved; five converging round-5 must-fixes (D-1..D-5) unified by "logical region layer persists at Proto/VM lifetime + identity/edge-keyed; only the physical armed-edge slot layer is retirement-cleaned"; one scope fork (D-3c recursion) = Bart's call. **ROUND-5 DESIGN WRITTEN** (§Part A — round-5 design): all resolved with Bart's D-3c = (β) build activation discrimination (deterministic per-VM `call_seq`); D-1 two-cell cap reserve; D-2 set E vs set S; D-3 three-map split + identity `RegionId` + `call_seq` + tier-graph discovery; D-4 `(trace_id,exit_instr)` classifier; D-5 logical maps Proto/VM-owned; D-6 precisions. Fresh codex + Antigravity re-review PENDING before any code.) — earlier: 2026-07-14 (Increment 2.3c-2c 2c-F COMPLETE — the 2c arc's rerun blocker is RESOLVED and the increment closes. Two codex `gpt-5.6-sol` reviews: the full read-only arc review found every supported path sound (accounting, ledger, determinism, observation-window, P-E retirement) and raised one blocker — a layout-dependent `TypeError` when re-running a completed top-level proto twice on one VM with a live armed cycle (~1/25 runs, unconfined because `Vm.run` has no enforced one-shot precondition). Fixed in two layers: (1) exit-slot HARDENING (codex edit-mode) — `armNativeLink` derives its target from `child`+`kind` instead of trusting a caller address, `compileImpl` validates each secondary-entry offset is in the child's live mcode page before publishing; a focused re-review judged this correct-but-defensive-only; (2) EPOCH CONTAINMENT (the actual fix) — `Vm.beginTopLevelEpoch` disarms all links at every fresh `run`/`start` entry (not `exec()` resume, not nested calls), so a stale link that passes the hardening checks still can't fire into a fresh-epoch frame. Tests: the two-phase integration test reframed to "a fresh top-level run disarms the prior epoch's live cycle" (load-bearing — disabling `beginTopLevelEpoch` fails exactly it) + supported cold-re-entry guard + `disarmAllLinks`/`native_link_disarms` unit coverage. `just test` green in both default and `-Djit-debug=true` builds; nsieve/mandelbrot/nbody/spectral-norm tier-0==tier-1a==native byte-identical. Nice-to-have follow-up: a suspend/resume-with-window integration test for the 2.3c-0e dispatcher window-disarm (unit-covered today). — earlier the SAME day, Increment 2.3c-2c 2c-F TESTS (first cut) LANDED — the disarm integration test + `native_link_disarms` counter. — earlier, Increment 2.3c-2c 2c-E LANDED — persistent `I.loopdone → C.ordinary_entry` arm CLOSES the native continuation↔inner cycle, byte-identical. Counters `native_loopdone_link_arms`/`native_loopdone_link_fused`; fail-closed `armLoopDoneLink(inner, guard_idx, cont, safe_to_arm)` targeting `nativeFor(cont).ordinary_entry` (ordinary mode, 2.3c-0c); `safe_to_arm` threaded through all 4 `replayLedger` call sites; armed at 3 sites (scalar call-A, driveChain hop-0 under `.native_numeric_for_done`, and the `replayLedger` terminal `.loop_done_linked` CONVERGENCE arm so sibling inners reached only via replay converge). A native-only one-trip dispatcher correctness fix (`linked_one_trip`): a linked loop-done receipt with `local_completed==0` routes through the productive path — the old scalar zero path DOUBLE-COMMITTED the final iteration (proven by disabling the fix: one-trip programs print N+1; the byte-identity gate, not just accounting, is what catches it; reachable only with `min_trip_entry=0`). Five blocking tests green: (i) one-trip productive, (ii) end-to-end arm+fuse, (iii) `replayLedger` terminal convergence arm, (iv) forced-yield at `LEDGER_CAP`, (v) `disarmAllLinks` resets every slot. Plus a permanent compile-gated JIT debug facility `src/jitdbg.zig` (`-Djit-debug` build opt + `--jit-debug` CLI + `TraceConfig.debug_log` + `TraceState.dbg`/`dbgDump*`) replacing hand-added scaffolding. `just test` green; nsieve/mandelbrot/nbody/spectral-norm tier-0==tier-1a==native byte-identical (nsieve-bit/fannkuch need LuaJIT `bit`/`unpack`, unsupported — not regressions). Remaining in 2.3c-2c: 2c-F (two-phase disarm integration test + negative control + full codex diff review). — earlier the SAME day, Increment 2.3c-2c RE-SCOPED to capture-everywhere after two codex reviews — see the 2.3c-2c bullet in §Implementation status → Outstanding for the 6-sub-step plan and per-question rulings; no code landed yet for it. — earlier, 2026-07-13: Increment 2.3c-2b LANDED — native call-B drain rerouted through ledger replay. New `CompiledTrace.runCapturingLedger(regs, ledger_out)` decodes `NativeResult.ledger_*[0..ledger_len]` into a `TraceState`-owned `[LEDGER_CAP]irinterp.LedgerEntry` scratch (option b: `runWithLinkedLoopDone` gained a `?[]LedgerEntry` out-param; `run`/`runLinkedLoopDone` pass null). `runLinkedBurst`'s native continuation drain now runs `snt.runCapturingLedger` and replays via a phase-machine `replayContinuationLedger` returning a `ContinuationReplay` directive (`run_continuation`/`run_inner`/`return_result`/`break_burst`) that drives the newly-labeled `hop:` loop; the old scalar `while (final != current_link.id)` drain + standalone-`.link`/`completed>0`/break tail are gone on the native path. Accounting reproduced exactly: resolve each entry's owner strictly by `trace_id` + `isInnerLoopRoot` (panic on mismatch, as before), `flocal = cum[1]-cum[0]`, loop-done via `guardExitPc`+`for_loop`, `native_link_exits` charged ONCE on the `C.link` marker (replaces both the old per-fused-span and standalone-`.link` bumps — same count). Call A (hop-top inner) + driver swap + burst-entry accounting UNCHANGED (scalar); only call B rerouted. Tier-1a keeps its scalar single-exit path (never fuses). Post-impl codex gpt-5.6-sol review confirmed exact parity for `[C.link]`/`[C.guard]`/`[C.link,I.mid]`/`[C.link,I.done]` and closed one BLOCKER: the `entries.len ≤ 2` invariant is now RELEASE-enforced with `@panic` (a `C.link→I.guard→R.link` composition could produce 3 entries; a debug-only assert would let ReleaseFast silently misresume — now aborts loudly in every build, matching the old drain's unexpected-shape panic; 2.3c-2c lifts the cap). `just test` green; nsieve/nsieve-bit/fannkuch/mandelbrot/nbody/spectral-norm tier-0==tier-1a==native byte-identical; `just bench` nsieve flat (`cross ok`, jit 92.9ms). NOT yet the cycle-closing arm (2.3c-2c). — earlier, Increment 2.3c-2a LANDED — per-transition ledger ABI + emission. `NativeResult` gained tail-appended parallel arrays `ledger_cum: [LEDGER_CAP]usize` (scale-8), `ledger_id`/`ledger_exit`/`ledger_reason: [LEDGER_CAP]u32` (scale-4) plus `ledger_len`, with `LEDGER_CAP=32` (covers the ≤9-iter × 2-transition burst-hop bound); `ExecResult` gained a defaulted `ledger_len` so ~40 tier-1a sites are untouched. New `emitLedgerAppend(a, trace_id)` helper — bounds-guarded drop-if-full (`ledger_len` vs `LEDGER_CAP`, `jae full`), SIB-indexed stores (`ledger_cum[len]=rbx`, `ledger_id[len]=trace_id` imm, `ledger_exit[len]=exit_instr`, `ledger_reason[len]=exit_reason` reloaded from memory), `inc len` — emitted at all four exit-materialization sites (`.link` terminal, linked_loop_done stub, shared `deopt_exit`, `prologue_fail`). `runWithLinkedLoopDone` wrapper adds a `runtime_safety` tripwire asserting the TERMINAL ledger entry matches the scalar result (`ledger_cum[n-1]==completed`, id/exit/reason, `1≤n≤CAP`) and threads `ledger_len` into the returned `ExecResult`. Appends touch only `NativeResult` scratch (never `regs[]`/program state) and the drop-if-full branch is never taken pre-cycle, so byte-identical: `just test` green (assert live across the whole Debug suite — single-trace hot path AND fused C→I spans, which already emit 2 entries per 2.3b-1); nsieve/nbody/mandelbrot tier-0==tier-1a==native byte-identical; `just bench` nsieve flat (jit_execns 89.7M vs 95.9M baseline). NOT yet the accounting change (2.3c-2b) or the cycle-closing arm (2.3c-2c). — earlier, Increment 2.3c-1 LANDED — M1 half-fusion implemented per the reviewed contract. `driveChain` arms the skip trace's source-branch guard slot → the prime-side ramp's `ordinary_entry` (`.ordinary_guard`, gated `native_only ∧ safe_to_arm ∧ .ordinary_header ∧ inputs.len==0 ∧ isSourceBranchGuardExit`); the burst body extracted into the now-`pub` `runLinkedBurst`. New recognizer `fusedSourceBranchLinkSlot` (armed-edge provenance: record `{parent==ct, child==final}` whose slot is a source-branch guard) + the dispatcher fused-`.link` consumer (interp.zig, after `local_done`, gated `ran_native ∧ final!=ct ∧ exit_reason==.normal ∧ exit_instr<final.instrs.len`): replays `onSideExit(ct, skip_local=result.completed)`, asserts the two other productive hooks inert (`isSourceBranchGuardExit`, `countTracesAt≥2`), then `.link` → `runLinkedBurst(final, result, false, …)` else internal-guard-deopt → `onSideExit(final,0)` + resume `ct.anchor.pc`. New counters `native_source_link_arms`/`native_source_link_fused`, both asserted `>0` in the Phase-2 nsieve chain test. `just test` green; 6 benchmarks tier-0==tier-1a==native byte-identical; nsieve keyframe tier-0==native byte-identical. Acyclic (no 2.3c-0e dependence); `ran_native_link_mode` untouched; M2 still deferred. — earlier, 2026-07-13: Increment 2.3c-1 DESIGN — a codex gpt-5.6-sol pre-implementation contract review found the terse "arm skip→prime-side" scope incoherent: the prime-side is a `.link` entry ramp, so arming the skip guard alone lands the fused run at the ramp's `.link` terminal with regs coherent at the inner PC while the dispatcher misreads it as an outer-header zero-exit → semantic misresume. Added §Increment 2.3c — fused-transition contract: chose M1 (half-fusion) — arm ONLY `skip.guard → prime_side.ordinary_entry`, decode the root's own count as `result.completed` (ramp commits 0 → no new NativeResult field), add a dispatcher fused-top-level-`.link` consumer that replays `onSideExit(ct, skip_local)` + continues the burst via a driveChain seed of the already-run ramp result. Rejected M2 (full single-call skip→prime-side→inner fusion) as needing the deferred P-F per-hop ledger nothing on the roadmap requires. Re-scoped the 2.3c-1/2.3c-2 Outstanding bullets. codex re-review of the written M1 design (2026-07-13, round 2) confirmed the receipt decode (ramp never `inc rbx` between `ordinary_entry` and its `.link`), register coherence, inert-hook asserts, and `onSideExit` ordering — and found one BLOCKER + one SHOULD-FIX now folded in: the fused-`.link` recognizer must discriminate on P-E armed-edge provenance (`parent==ct ∧ child==final ∧ slot_index` a source-branch guard) with a `exit_reason==.normal ∧ exit_instr<len` bounds gate, NOT the bare `final.instrs[exit_instr].op==.link` opcode (which OOBs on fused prologue-fail and false-positives on 2.3c-2's persistently-armed inner→continuation); and the driveChain seed must consume a `current_link`-owned `.link` receipt at trace.zig:~1390, not initialize `fused_inner` from the ramp result. NOT yet implemented — design now review-clean, ready to code. — earlier, 2026-07-12: Increment 2.3c-0 landed — inert contracts a–f, each its own byte-identical commit, then a codex gpt-5.6-sol contract review found 3 blockers, all closed: (1) the shared ordinary-guard flush staged its dispatch holder in rax, which `flushSlot`'s spilled-carried-home path clobbers — re-architected to stage the resolved target in a flush-immune `NativeResult.exit_target` and dispatch `jmp qword [rdx+exit_target]`; (2) that removed the reserved `slots[n]` "direct cell" entirely, so `slots.len == instrs.len` and no off-table cell is arm-addressable; (3) the dispatcher's sibling-retry exclusion now orders `final` FIRST so `driveChain`'s own 8-entry cap can't truncate the just-failed child. Proven load-bearing by a negative control (revert the tail to `jmp rax` → only the frameless carried-spill regression crashes). codex re-review: all closed, no new blocker. `just test` green; 6 benchmarks byte-identical tier-0/tier-1a/native. — earlier that day, Increment 2.3b-1: `driveChain` arms the continuation's `.link` slot → `inner.linked_entry` (eligibility: `inner.compiled`, `inputs.len == 0`, terminal `.link` with `aux == inner_pc` re-read after the driver swap; `safe_to_arm` gate on `suspend_ctl`/`record_safepoint_lines`). Fused `snt.run` results drained by strict `traceById(final_trace_id)` + `isInnerLoopRoot` resolution — unresolvable/mis-shaped ⇒ `@panic` (no unsafe resume); loop-done vs. mid-loop classified via `guardExitPc` following `for_loop`; steering on the child's own `local_completed`. Dropped `assert(final == ct)` and the `entry_rbx == 0` assert; native dispatcher resolution strict (`@panic` on null, release too), tier-1a still uses `ct`. New `native_link_arms` counter. Peer-reviewed codex gpt-5.6-sol across 3 rounds — closed, no correctness blocker. `just test` green; 8-value N-sweep + 5 benchmarks byte-identical across tier-0/tier-1a/native. Deferred: native 9-completion bound reconcile (Issue 4), observation-window unpatching (Issue 5 → P-F).)

Coherent-state chaining (doc 16) proved *correct* but *performance-neutral* on
nsieve: the JIT compiles every hot loop to native code, chaining hands control
from one native trace to the next at a shared coherent anchor — and yet it does
not beat tier-0 on the prime/composite clusters, because **every transition
re-enters the runtime**. A native guard fails, returns to the Zig dispatcher,
which does guard-failure accounting, a linear trace-cache scan, and an indirect
call through a function pointer with a fresh `NativeResult` — measured at
~600 ns per hop (doc 16 §nsieve outcome). On nsieve's 1–2-iteration clusters that
per-hop cost rivals just interpreting the gap in tier-0, so `driveChain` swaps
tier-0 for something no faster. Increasing chain coverage makes nsieve *slower*,
which is the structural signature that the transition cost — not codegen
tightness — is the wall.

LuaJIT does not have this cost. When a guard on a parent trace fails hot enough
to record a side trace, LuaJIT **patches the parent's machine code** so the
guard's exit jumps *directly* into the side trace's native entry — zero
dispatcher re-entry, zero marshalling. This doc is the contract for porting that
mechanism (`lj_asm_patchexit`) to lune's tier-1b backend, and the home for the
determinism obligations the port must discharge to stay byte-identical across the
10-mode matrix.

This is not a redesign. LuaJIT's mechanism works and we have the source
(`~/Projects/LuaJIT/src/`); the job is to adapt it to lune's handoff model, which
differs in one load-bearing way (memory-file vs. register handoff — see §The one
real difference). The investigation that produced this doc read both codebases in
full; citations are inline.

## Implementation status

Tracking the gap between this design and what's on `master`. Tick items as they
land; move whole sections to Done once everything inside is checked.

### Done

- [x] **H-2 (hard half) — CLOSED, all three parts LANDED (2026-07-18).** The complete determinism fix
  for JIT-trace-const object identity, shipped as three gated commits, each design → gpt-5.6-sol review
  (BLOCKER, folded, re-APPROVE) → land behind `just test` + `-Djit-debug`, all negative-control-proven:
  **(2)** `{gc,snapshot}` root-walk split (`forEachRootHeader` comptime `RootKind`; trace consts `.gc`-only,
  excluded from the snapshot walk — final-snapshot facet, commit `3f1df3f`); **(1)** dynamic-proto tracing
  gate (`Proto.dynamic` bit stamped by `assignProtoIds`; four gates in `trace.zig` — `arm`,
  `maybeStartContinuation`/`maybeStartReplaySide` after the pending-null-clear, `recCall`→`.dynamic_proto` —
  mid-run dropped-`load`-closure facet, commit `b2d9d18`); **(3)** `TraceState.clearCache()` from
  `beginTopLevelEpoch` after `disarmAllLinks()` (frees traces mid-VM-life, mcode to the retained arena;
  resets the full tiering + `exec_logs`/`coverage`/`abort_log` cross-epoch hazard set — cross-epoch
  `depth==0` facet, commit `9a8c141`). All 10 modes + keyframe restore byte-identical for `load`ed /
  dropped-closure / multi-epoch programs. See §"H-2 hard half — design" and its three part sections.
  **Follow-up ticket (Rule #10):** a freshly-`compile`d-but-not-yet-run chunk's heap constants are rooted
  by nothing (`Chunk` doesn't root them; `gc.zig` marks only via a live closure) — an interleaving GC can
  sweep them in the compile→run window (gpt-5.6-sol-confirmed latent product concern, separate scope).
- [x] **Round-9 landing — 9-A (small/safe).** `pure ⇒ !effect` enforced by a `comptime` check over the
  static `base_natives` registry (`interp.zig`, `@compileError` on any both-set entry; covers `manual`
  entries) + a `keyframeser` restore-path assert; `depth == 0` clean-entry fail-closed via
  `Error.DirtyTopLevelEntry` returned from `beginTopLevelEpoch` before `disarmAllLinks` (release-enforced;
  `run`/`start` `try` it; `catchable()` = not-catchable). Load-bearing test (suspended-VM re-entry rejects
  `start`/`run`, then resumes via `exec()`); negative-control-proven. `just test` green (default +
  `-Djit-debug`), nsieve tier-0 ≡ native. Commit `9fcc2c4`.
- [x] **Phase 0 — Investigation + this doc.** LuaJIT `lj_asm_patchexit` mechanism
  mapped to bytes-and-pointers (`lj_asm_x86.h`, `vm_x86.dasc`, `lj_asm.c`,
  `lj_trace.c`); lune's native guard-exit emission mapped to the patch-point
  (`nativegen.zig` exit stubs → shared `deopt_exit`; W^X page finalize). The one
  architectural difference (register vs. `regs[]`-memory handoff) identified.
- [x] **P-D — Shared code arena (Increment 1).** `McodeArena` (`nativegen.zig`):
  a chain of ~1 MiB `mmap`'d regions, bump cursor + first-fit free-list, mcprot-
  style RW↔RX toggle per write. Owned by `TraceState` (`mcode_arena`), deinited
  *after* the trace cache so per-trace `free` returns slots first. Every native
  trace is now a co-located slice (`ExecPage` is a view: `.owned` mmap for the
  test path, `.arena` slot for production via `compileInto`→`nativeFor`). Per-trace
  reclaim kept via the free-list (Bart's call: try reclaim first, revisit if it
  measures worse than pure bump). No cross-region references emitted yet, so the
  ±2 GiB reachability check is deferred to Increment 2. Behaviour byte-identical:
  10-mode matrix green, nsieve identical across tier-0/tier-1a/native, bench
  unchanged (arena work is compile-time only, never the hot loop).
- [x] **P-A — Frameless chain-entry ABI (Increment 2.1).** The shared trampoline
  (`McodeArena.ensureTrampoline`) owns the single C frame: it saves every
  callee-saved GPR once, reserves a fixed `SPILL_MAX`-slot spill area (keeping body
  `rsp % 16 == 8`), zeroes the rbx counter, and `jmp`s into the body (`body_entry`
  in rcx). Trace bodies are now frameless — `lower` skips the per-trace
  `push/sub/pop/ret` when `shared_exit != null` and every side-exit jumps (absolute)
  to the trampoline's `shared_exit` instead of tearing down its own frame. A body
  needing more than `SPILL_MAX` (512) spill slots bails to tier-1a. `CompiledTrace`
  gained `trampoline_entry`; `run` dispatches through the trampoline for arena
  (production) pages and directly for owned (test) pages. This is option (ii) from
  the P-A sketch — linked traces share one frame and don't each push/pop — the ABI
  foundation the link handoff (P-C) and chain-wide result (P-B) build on. No linking
  yet: exits still land on `shared_exit`, so behaviour is byte-identical (10-mode
  matrix green; nsieve + nsieve-bit + field_hash/grid/array all tier-0==native;
  nsieve jit ms flat vs the pre-change baseline).
  - **ABI invariant made explicit (2.3a review, fable item 5).** When a slot is
    armed (2.3b+) an exit becomes a bare `jmp` into a child body under the shared
    frame, inheriting the parent's exit-time register state. That is only safe
    because at every *chainable* exit the SoA lane registers `rdi` (tags) / `rsi`
    (payloads) are guaranteed live-and-correct — the `.link` terminal and
    linked-loop-done stub both flush φ/snapshot state through them immediately
    before `emitReturn`. `rdx` (`*NativeResult`) and `rsp` (trampoline frame) are
    body-reserved; `rbx` is the cumulative iteration counter carried *across* the
    hop (its chain-wide meaning is P-B/P-G). This liveness is a **contract**, not an
    accident: any new chainable exit kind must re-establish `rdi`/`rsi` before it
    hands off. `rax` is dead scratch at every exit (used only to load the slot
    address).
- [x] **P-B — Chain-wide result contract (Increment 2.2).** `NativeResult` gains
  `final_trace_id: u32` — the stable id of the *final* trace in the chain, baked as
  an imm32 into every native exit stub (`emitReturn` writes it to
  `@offsetOf(NativeResult,"final_trace_id")` via rdx, which holds `*NativeResult` at
  every exit). `ExecResult` (tier-1a) grows the same field, *defaulted* to
  `NO_TRACE_ID` so the ~40 tier-1a construction sites are untouched (zero churn).
  Traces carry a stable, never-reused `id` (monotonic `TraceState.next_trace_id`,
  assigned at finalize) because the cache index is `swapRemove`'d and unusable as a
  baked constant; `TraceState.traceById(id)` resolves it. The dispatcher computes
  `final = traceById(result.final_trace_id) orelse ct` and asserts `final == ct`
  under `ran_native`. With no linking armed yet every exit bakes its own `ct.id`, so
  `final == ct` always holds — the assert validates the full baked-id round-trip
  (id → stub imm32 → `NativeResult` → `traceById`) end-to-end while staying
  byte-identical. Consumers stay routed through `ct`; 2.3 routes them through
  `final` once child links populate a real id. (nsieve/nsieve-bit/fannkuch/
  mandelbrot/nbody/spectral-norm all tier-0==native; Debug asserts pass.)

- [x] **Increment 2.3a — indirect exit + link-slot table + P-E registry
  (byte-identical, nothing armed).** The direct `movabs rax, shared_exit; jmp rax`
  exit becomes an indirect `movabs rax, &slot; jmp qword [rax]` (`x64.zig` gains
  `jmpMem` (FF /4 memory form) + golden-byte tests). `CompiledTrace` gains an owned,
  heap-allocated `slots: []usize` (one per IR instruction index) plus a `gpa` handle
  for `deinit`; `compileImpl` allocates it *before* `lower` (so `&slot` is a stable
  imm64) and default-fills every entry with `shared_exit`, so an unarmed slot is
  behaviourally identical to 2.1's direct jump. `emitReturn` takes a `slot_addr:
  ?usize` and bakes the indirect form when set (the `.link` terminal and loop-done
  stub pass their slot; `deopt_exit`/`prologue_fail` pass `null` → unchanged, still
  direct to `shared_exit`). The **P-E backlink registry** lands here as inert
  scaffolding: `TraceState.armed_links: ArrayList(NativeLink{parent, slot_index,
  child})`; `armNativeLink(parent, slot, child, target)` records the dependency (and
  supersedes a prior same-slot record) then writes the slot; `resetLinksTouching(t)`
  — called in `removeTrace` **before** `t.destroy` — resets each surviving parent's
  slot back to `shared_exit` when `t` is a link *target* (child retires) and drops
  the record when `t` is a link *source* (parent retires, slot array about to be
  freed), re-deriving the slot address from the live parent so it's never a cached
  dangling pointer. A focused unit test pins both retire directions, re-arm
  supersede, and OOB/non-compiled no-ops. Chosen a flat trace-identity-keyed list
  over the plan's `AutoHashMap(*Trace, ArrayList(*usize))` because keying on trace
  identity (not cached slot pointers) makes reset correct regardless of retire order.
  Nothing arms a slot yet, so `armed_links` is always empty and `final == ct` still
  holds — provably inert. (nsieve/nsieve-bit/fannkuch/mandelbrot/nbody/spectral-norm
  tier-0==tier-1a==native byte-identical; `just bench --filter nsieve` flat within
  noise — one extra load per exit.) **Hardened post-landing** per an independent
  two-model review (codex gpt-5.6-sol + a fable technical-architect pass, both
  "approve with changes"): fixed a latent OOM-only re-arm UAF (BUG-1 — the
  supersede path now mutates the record in place instead of remove-then-append, so a
  failed append can never strand an armed-but-untracked slot); `armNativeLink` now
  returns `bool` (armed vs no-op) for P-F accounting; pinned "`armNativeLink` is the
  only writer of `slots[i]`" as an invariant. Deferred to 2.3b (need real compiled
  pages / a live trampoline to exercise): the Debug `target`-within-`child`-page
  bounds assert, the missing-trampoline assert (BUG-2), and a real
  retire-then-reuse lifetime test (fable item 6). The slot-identity-vs-exit-kind
  collision (2.3c) and the `rdi`/`rsi` liveness contract are recorded under P-C and
  P-A above.
- [x] **Increment 2.3c-0 — inert contracts (byte-identical, nothing armed).** Six
  sub-steps, each its own commit + byte-identity sweep: (a) P-C option (b) invariant
  enforced at emission (nativegen) + arming (`armNativeLink` + `ArmKind` + the
  `isLoopDoneGuardIndex` classifier); (b) distinct `ExitReason.prologue_fail`
  discriminator so `exit_instr == maxInt` no longer conflates "no guard identity" with
  "prologue failed"; (c) `ordinary_entry` (mode 0) vs `linked_entry` (mode 1) secondary
  entry-point contract; (d) routed the remaining `final != ct` consumers (widen-
  eviction, `visited` exclusion, materialization class) through `final`; (e) disarm-on-
  unsafe (`disarmAllLinks`, wired inert, load-bearing at 2.3c-2); (f) shared ordinary-
  guard flush + default-slot tail — all slots default `shared_exit`, so byte-identical.
  **Post-landing hardening (codex gpt-5.6-sol contract review → 3 blockers, all
  closed):** (1) the 0f shared flush staged the dispatch holder in rax, which
  `flushSlot`'s spilled-carried-home `.mem` path clobbers before the jump — re-architected
  to stage the RESOLVED target in a flush-immune `NativeResult.exit_target` memory field
  (`jmp qword [rdx+exit_target]`); this also (2) let the reserved trailing `slots[n]`
  "direct cell" be DELETED (`slots.len == n == instrs.len` again, so `armNativeLink`'s
  bound rejects index n — no off-table cell is arm-addressable); (3) the dispatcher's
  `excl` buffer now orders `final` FIRST so `driveChain`'s own 8-entry cap never truncates
  the just-failed child away. A frameless carried-spill regression (`buildCarriedSpillLoop`,
  13 carried > 9 GP homes) was proven load-bearing by a negative control (revert the tail
  to `jmp rax` → only that test crashes). codex re-review: all three blockers closed, no
  new correctness blocker. (nsieve/nested-loop/nbody/mandelbrot/fannkuch/spectral-norm
  tier-0==tier-1a==native byte-identical.)
- [x] **Increment 2.3c-1 — arm skip→prime-side (half-fusion, M1).** `driveChain`
  arms the failing skip trace's source-branch guard slot → the prime-side ramp's
  `ordinary_entry` (`armNativeLink(failed, exit_instr, sct, oe, .ordinary_guard)`,
  gated `tier == .native_only ∧ safe_to_arm ∧ materialization == .ordinary_header ∧
  sct.inputs.len == 0 ∧ isSourceBranchGuardExit`); the burst body was extracted into
  `runLinkedBurst` so both `driveChain` and the new consumer share it. The dispatcher
  gained a **fused top-level `.link` consumer** (interp.zig, after `local_done`):
  recognizes the fusion by ARMED-EDGE PROVENANCE (`fusedSourceBranchLinkSlot` — armed
  record `{parent==ct, child==final}` whose slot is a source-branch guard, + the
  `exit_reason == .normal ∧ exit_instr < final.instrs.len` bounds gate), replays
  `onSideExit(ct, skip_local = result.completed)` (the ramp commits 0 of its own, so
  `completed == entry_rbx`; no new `NativeResult` field), asserts the two other
  productive hooks inert (`isSourceBranchGuardExit`, `countTracesAt ≥ 2`), then splits:
  ramp reached its `.link` → `runLinkedBurst(final, result, false, …)` (seed ignored,
  `sresult_fused == false`); ramp deopted at an internal guard → `onSideExit(final, 0)`
  + resume at `ct.anchor.pc` (byte-identical to the unarmed `driveChain` seed). New
  counters `native_source_link_arms`/`native_source_link_fused` (> 0 asserted in the
  Phase-2 nsieve chain test). Acyclic — does NOT depend on 2.3c-0e disarm;
  `ran_native_link_mode` untouched. `just test` green; 6 benchmarks tier-0==tier-1a==
  native byte-identical; nsieve keyframe tier-0==native byte-identical.

### Outstanding

- [ ] **A-i — 9-B GuardProvenance IR extension (IN PROGRESS, un-deferred 2026-07-21; consumer = Part A,
  now designed).** The exit-identity substrate (§A4). Un-deferred because its consumer (the region
  classifier, A-ii) is now fully specified, so the exact tag layout it reads is pinned. Lands in four
  green sub-steps, each byte-identical across the 10 modes (no consumer yet ⇒ inert), gated by
  `just test` + `-Djit-debug`:
  - [x] **A-i.1 — types + storage + `tropt` remap (inert). LANDED 2026-07-21.** `just test` green
    (default + `-Djit-debug`); nsieve tier-0 ≡ native byte-identical (inert: nothing stamps yet). Add
    `GuardRole`/`OperandDesig`/`Polarity`/
    `CallEdge`/`GuardProvenance`/`ExitProvenance` (union: `guard | link_terminal`) near `IrInstr` in
    `trace.zig`. Emission-time storage = a dense lockstep `Recorder.exit_prov: []?ExitProvenance` grown
    one-`null`-per-append in `emit` (4178) — the single IR-append choke; committed storage = a compact,
    alloc-once sorted `Trace.exit_prov: []{index,prov}` with a `provAt(idx)` accessor. **`tropt` interface
    decision:** `Optimized` gains an owned `old_to_new: ?[]?Ref` compaction map (`optimize` fills
    `new_index[i]` for emitted survivors, `null` for dropped/dead/CSE-merged; `dupe` leaves it `null` ⇒
    identity, since link/unoptimized traces preserve indices 1:1). Commit (3849+) compacts non-`null`
    provenance through that map into `Trace.exit_prov`. Nothing stamps yet ⇒ table empty ⇒ byte-identical.
    Tests: `optimize` compaction-map correctness on a hand-built trace (dead-drop + CSE-merge + survive);
    pure remap-and-compact round-trip.
  - [x] **A-i.2 — inline call-edge path capture (inert). LANDED 2026-07-21.** `just test` green;
    nbody/mandelbrot/nsieve tier-0 ≡ native. Extend `InlineFrame` (5398) with
    `{caller_proto_id: u32, call_pc: u32}`, set in `recCall`'s frame push (5169) — needs threading the
    call `pc` into `recCall` (currently absent). A `currentPath()` helper reads `frames[0..inline_depth]`
    into `[MAX_INLINE_DEPTH]CallEdge`. Read by nothing ⇒ byte-identical (a re-record-stability test guards it).
  - [x] **A-i.3 — stamp every guard + fused producer-exit site. LANDED 2026-07-21.** `just test` green
    (default + `-Djit-debug`); nsieve/nbody/mandelbrot tier-0 ≡ native byte-identical. Per the emit-site
    inventory (§A4 H-1c table, refreshed 2026-07-21): `stampProv(ref, role, operand, polarity)` fills
    `source_proto_id`/`source_pc = cur_pc −| 1` (saturating — `cur_pc ≥ 1` in production, `−|` only maps the
    synthetic `pc=0` test sentinel to 0, matching `guardSourcePc`)/path and writes `exit_prov[ref]`. The
    type-guard helper `guard`/`guardNum`/`guardInt` now carries `(role, operand)` and stamps only on a real
    emit (deduped guards keep the first stamp — many-to-one, H-1c). Stamped the raw-`emit` guard sites
    (`recBranch` branch_cond + taken/fallthrough polarity, `recArith`/`recBitwise`/`recNeg`/`recBnot`/
    `recCompare`/`recEq` operand_type, `recForLoop`/`recForPrepLink` operand_type/limit_int/loop_done,
    array/hash/grid, `guard_func` callee_identity, `guard_pure` callee_pure, `int_of_float` limit_int) and
    the **3 fused producer-exit nodes** (`.value` `aload` → element_type/loaded; `hload` → field_type/loaded;
    `href` → hash_struct — stamped on the producer IR node). Added two grid-specific roles `row_bounds`/
    `col_bounds`. Still inert (table populated, unread). Tests added: arith operand identity + `source_pc =
    pc−1`; int↔float re-record keeps identity (only IR op flips); branch polarity taken vs fallthrough
    distinguishes the two CFG edges, rest equal. (`f(a);f(b)` path collision already covered by the A-i.2
    `pathFromFrames` test; optimizer-remap opt-ON vs OFF by the A-i.1 `buildExitProv` remap test.)
  - [x] **A-i.4 — `.link`-terminal provenance transport (inert). LANDED 2026-07-21.** `just test` green
    (default + `-Djit-debug`); nsieve/nbody/mandelbrot tier-0 ≡ native byte-identical. `recForPrepLink`
    fills `Recorder.pending_link_provenance` (`.link_terminal` variant, `source_pc = cur_pc −| 1`, empty
    path since a `for_prep` is never inlined) together with `link_target` — so the commit-time release
    invariant `link_target != null ⇔ pending_link_provenance != null` (a `@panic` on violation) holds by
    construction. `reset` clears both on every abort/re-arm. The `.link` terminal is appended directly at
    commit (no lockstep slot, always the `dupe`/identity path), so `buildExitProv` takes an optional
    `link_terminal: ?ExitProvEntry` and injects it at the terminal's committed index (`instrs.len − 1`),
    sorted among the guard entries. Tests: `buildExitProv` link-terminal injection+sort; full
    `recForPrepLink`→commit integration (committed `.link` trace carries `.link_terminal` provenance at its
    `.link` index, `source_pc = 4`, `inline_depth = 0`).
  **A-i COMPLETE (all four sub-steps landed 2026-07-21).** The GuardProvenance substrate is fully in the
  tree and inert — populated at every guard + fused producer-exit + `.link` terminal, unread until the
  Part-A region classifier (A-ii) consumes it. Next: A-ii per §A8.
- [ ] **Deferred to Increment-3 machinery.** F2c native-cut harness (H-4 cut) + region-map cap
  contract (H-3 cap) land WITH `region_profit`/native-F2c, not in round 9.
**Increment 2.3b — arm `.link`-terminal handoffs (ACTIVE; re-scoped after the
2026-07-12 codex contract review).** The review found the original one-commit
2.3b under-scoped on two counts, so it is split into an inert-scaffolding step
(2.3b-0, byte-identical, reviewed) and an arming step (2.3b-1). The armed hop is
**Hop A**: a `.link` continuation reaching its terminal → the inner-loop root it
names (run today via `runLinkedLoopDone`, trace.zig:1369). Findings:

  1. *The `.link` terminal is NOT single-contract on the CHILD side.* The inner
     root `I` is run in linked mode (`runLinkedLoopDone` sets
     `NativeResult.linked_loop_done = 1`; `I`'s loop-done guard reads it at
     nativegen ~4213 to pick linked-completion materialization). A bare armed
     `jmp I.page.code.ptr` never sets the flag → `I` takes ordinary `deopt_exit`,
     never commits its final iteration → wrong state. **Fix (2.3b-0): a second
     entry point `linked_entry` on every frameless body** that presets the flag
     then falls into `body_entry`; the armed slot targets `linked_entry`, not the
     bare body. Emitted after `prologue_fail`, inert until targeted.
  2. *Cumulative `rbx` ≠ the child's local count.* Once fused, `I` is entered under
     the shared frame WITHOUT `xor rbx,rbx`, so `I`'s exit would report the chain's
     cumulative count, not `I`'s own — and `driveChain` feeds that count to
     `onSideExit(I, …)`, which decides penalty/gate/`hit_count` (steers future
     recording). Feeding cumulative `rbx` can flip a low-yield event to "useful" →
     different later traces → non-byte-identical across modes. **Fix (2.3b-0):
     `NativeResult.local_completed`** = `rbx − entry_rbx`, where `entry_rbx` is
     snapshotted into a `NativeResult` scratch field at `body_entry` (rdx-relative,
     uniform for both ABIs; no frame-slot reservation). Unchained, `entry_rbx == 0`
     so `local_completed == completed` — pinned by a Debug invariant in
     `runWithLinkedLoopDone` while nothing is armed.
  3. *`traceById(id) orelse ct` masks a missing id.* Once linking is live a child
     exit must resolve to the child, never silently fall back to the parent.
     **Fix (2.3b-0): fail closed** — when `ran_native`, assert the baked id actually
     resolved (`resolved != null`) before the `orelse ct`; keep `resolved.? == ct`
     until 2.3b-1 drops it.

- [x] **Increment 2.3b-0 — inert scaffolding (byte-identical).** (a) fail-closed
  `traceById` in the dispatcher (`963bdbb`); (b) `linked_entry` stub +
  `CompiledTrace.linked_entry` + `x64.labelOffset` (`954ea89`, emitted, nothing
  targets it); (c) `NativeResult.entry_rbx` scratch → `ExecResult.local_completed`
  with the `entry_rbx == 0` / `local_completed == completed` invariant (`319da11`).
  S3 prep (prologue_fail commits cumulative `rbx`) landed first (`9d16711`). Four
  separate byte-identical commits; nsieve 3-mode + 6-benchmark tier-0==`--jit-native`
  differential green. **Peer-reviewed (codex gpt-5.6-sol + fable), 2026-07-12:**
  SOUND / behavior-neutral today, correct foundation. rbx provably 0 at every
  `body_entry`/`prologue_fail` reach (trampoline + self-framed both `xor rbx,rbx`
  before entry; sole `inc rbx` is the back-edge → `loop_top`, never before entry);
  `linked_entry` inert (no consumer) and its address maps 1:1 (`resolve()` patches
  rel32 in place, `McodeArena.alloc` `@memcpy`s verbatim). Nit fixed: the
  `movMemImm32(linked_loop_done,1)` comment wrongly said "dword store to the low
  half" — it is REX.W `C7 /0`, a full-u64 store.
- [x] **Increment 2.3b-1 — flip arming on (LANDED, byte-identical).** `driveChain`
  now arms the continuation's `.link`-terminal slot → `inner.linked_entry`
  (`armNativeLink(current_link, len-1, inner, le)`; eligibility gated on
  `inner.compiled`, `inputs.len == 0`, terminal `.link` with `aux == inner_pc`,
  re-read AFTER the driver swap; `safe_to_arm = suspend_ctl == null and
  !record_safepoint_lines`, threaded from the dispatcher). A FUSED `snt.run` whose
  `final_trace_id != current_link.id` is drained in a dedicated loop that resolves
  the child STRICTLY by `traceById(final_trace_id)` + `isInnerLoopRoot` shape
  validation (never `findLoopTrace` substitution — a previously-armed slot can target
  a sibling `findLoopTrace` no longer picks), classifies loop-done vs. mid-loop via
  `guardExitPc(child.instrs[exit_instr])` following a `for_loop`, and steers on the
  child's OWN `local_completed`. An unresolvable/mis-shaped fused id is a hard
  invariant failure (`@panic`) — the child's exit leaves `regs[]` with no
  known-coherent resume PC, so bailing could re-run a committed inner loop. Dropped
  `assert(final == ct)`; native dispatcher resolution is strict (`@panic` on null,
  release builds too), tier-1a still uses `ct`. New counter `native_link_arms`.
  Peer-reviewed codex gpt-5.6-sol (3 rounds): closed, no correctness blocker.
  Verified `just test` green, 8-value N-sweep + 5 benchmarks byte-identical across
  tier-0/tier-1a/native.
  - **MUST (both 2.3b-0 reviewers, arming-time correctness) — DONE:**
    1. **Dropped `assert(result.entry_rbx == 0)`** in `runWithLinkedLoopDone`
       (nativegen ~669): a fused child inherits the parent's cumulative rbx, so
       `entry_rbx > 0` is expected steady state. `local = completed -% entry_rbx`
       kept.
    2. **Productivity classified by `local_completed`.** The final-trace productivity
       check routes through `local_completed`, not cumulative `completed`; a chained
       child that prologue-fails returns `completed = parent-cumulative` (nonzero) but
       `local_completed == 0` and is correctly non-productive.
  - **Note (fable):** `linked_loop_done` is sticky once the stub sets it — every
    later body in the native run sees 1. Correct for Hop A (continuation + inner both
    want linked mode); a hazard only if 2.3c ever arms an exit into a body that must
    materialize *unlinked* loop-done — flag under P-C.
  - **Outstanding within 2.3b-1's mechanism (non-blocking, deferred):**
    - **Native completion bound (Issue 4).** The native drain permits up to
      `visited.len + 1` (9) completions per burst; the tier-1a path caps at 8. This
      is a heuristic burst maximum, **not** a correctness contract — accounting is
      exact regardless of where the burst stops. The "8-hop" phrasing at doc §… and
      in the `trace.zig`/`interp.zig` comments should be reconciled to this 9 vs. 8
      native/tier-1a split.
    - **Previously-armed-slot unpatching under active observation (Issue 5 → P-F).**
      Once armed, a slot keeps fusing on later bursts even when `safe_to_arm` becomes
      false (safepoint/replay recording active). This is now always CORRECTLY
      accounted (the drain resolves + classifies every child by `final_trace_id`), so
      it is not a correctness bug — but it widens the observation blackout window
      beyond the driveChain hop bound. Resetting/declining armed slots when
      observation activates is deferred to **P-F** as the observation-window concern.

**Increment 2.3c — arm the remaining nsieve hops (ACTIVE; re-scoped 2026-07-12 by a
codex gpt-5.6-sol contract review that caught two blockers the plan missed).** The
skip→prime-side (ordinary source-branch guard) and inner→continuation (numeric-for
loop-done guard) hops. The review found: (i) arming inner→continuation closes a
persistent native cycle `continuation↔inner` that escapes the `hops<8` bound AND
`driveChain`'s safepoint/GC/replay observation boundary — `safe_to_arm` only blocks
*new* arms, never resets a slot armed earlier; (ii) `linked_entry` sets
`linked_loop_done=1` and nothing clears it, so inner→continuation would make the
continuation inherit mode 1 (wrong if it has its own loop-done guard). It also
settled that S1's slot-selected-materialization rewrite is **unnecessary** (runtime
mode selection already picks correctly; armedness ≠ requested materialization) and
that ordinary guards keep ONE shared flush (don't duplicate the carried-home flush
per guard). Split into three:

**Increment 2.3c-2 — arm loop-done inner→continuation (closes the native cycle).**
CORRECTION (2026-07-13): the earlier "fusion is INTERNAL to `driveChain`, drained
hop-by-hop as 2.3b-1's, needs no ledger" scoping was WRONG. Once BOTH `C.link → I`
(2.3b-1) and `I.loopdone → C` (this increment) are armed, a single trampoline entry
runs a CLOSED cycle `C→I→C→I→…` and returns ONE `NativeResult` describing only the
TERMINAL body — every intermediate hop is unrecoverable from the scalar fields (each
body's entry overwrites `entry_rbx`, each exit overwrites `final_trace_id`). A codex
gpt-5.6-sol pre-implementation review confirmed the cycle is real and coherent but the
scalar receipt cannot reconstruct the hidden hops. Bart's decision: **promote the M2
per-transition ledger** into this increment (rather than relax P-EBP-2 or keep the
edge acyclic). Sub-stepped, each byte-identical behind `just test`:

- [x] **2.3c-2a — ledger ABI + emission + terminal-consistency assert.** `NativeResult`
  gains a tail-appended per-transition ledger (`ledger_len` + parallel `ledger_cum`
  [scale-8] / `ledger_id` / `ledger_exit` / `ledger_reason` [scale-4] arrays, cap
  `irinterp.LEDGER_CAP = 32`). `emitLedgerAppend` (rax index, rcx staging, rbx = cum)
  appends one entry at ALL FOUR exit sites (`.link` terminal, linked-loop-done stub,
  shared `deopt_exit`, `prologue_fail`) after each writes `exit_instr`/`exit_reason` and
  before it dispatches; bounds-guarded (drop-if-full, inert pre-cycle). The Zig wrapper
  inits `ledger_len = 0` and, in debug, asserts the TERMINAL entry reproduces the scalar
  fields (`ledger_cum[n-1]==completed`, id/exit/reason match, `1 ≤ n ≤ CAP`). `ExecResult`
  carries `ledger_len` only (entries not yet consumed). Nothing new armed → spans stay
  short. `just test` green (assert live across the whole Debug suite); nsieve/nbody/
  mandelbrot tier-0==tier-1a==native byte-identical; `just bench` nsieve flat.
- [x] **2.3c-2b — route `runLinkedBurst`'s native drain through ledger replay.** Landed
  2026-07-13. The native call-B drain now runs `snt.runCapturingLedger(regs,
  &ledger_scratch)` (new `CompiledTrace` entry point that decodes `NativeResult.ledger_*
  [0..ledger_len]` into a `TraceState`-owned `[LEDGER_CAP]LedgerEntry` scratch — option b,
  no by-value array copy) and replays it via a phase-machine `replayContinuationLedger`
  returning a `ContinuationReplay` directive (`run_continuation` / `run_inner` /
  `return_result` / `break_burst`) that drives the labeled `hop:` loop. It resolves each
  entry's owner strictly by `trace_id`, classifies loop-done vs mid via
  `guardExitPc`+`for_loop`, derives the per-segment local as `cum[i]-cum[i-1]`, and charges
  `native_link_exits` ONCE on the `C.link` marker (replacing BOTH the old per-fused-span
  bump and the standalone-`.link` bump — byte-identical count). Call A (hop-top inner run)
  + the driver swap + burst-entry accounting stay on the scalar path unchanged; only call B
  is rerouted (per the codex pre-impl contract). Tier-1a keeps its scalar single-exit path
  (never fuses → no ledger). Post-impl codex gpt-5.6-sol review confirmed exact accounting
  parity for every ≤2-entry shape and flagged one BLOCKER now fixed: the `entries.len ≤ 2`
  invariant is RELEASE-enforced with a `@panic` (a `C.link→I.guard→R.link` composition — an
  inner whose own source guard is armed to a ramp — could yield 3 entries; a debug-only
  assert would let ReleaseFast silently drop R's hop and misresume, so it now aborts loudly
  in every build, matching the old scalar drain's "unexpected fused shape" hard-stop; 2.3c-2c's
  full-ledger replay lifts the cap). `just test` green; nsieve/nsieve-bit/fannkuch/mandelbrot/
  nbody/spectral-norm tier-0==tier-1a==native byte-identical; `just bench` nsieve flat
  (`cross ok`, jit 92.9ms).
- [x] **2.3c-2c — persistent `I.loopdone → C.ordinary_entry` via capture-everywhere. LANDED
  2026-07-14 (all six sub-steps 2c-A..2c-F complete; verified in-tree — `armLoopDoneLink` at the
  three arm sites `trace.zig:1772/1836/2113`, ledger ABI + `replayLedger`, the `linked_one_trip`
  correctness fix, `native_link_disarms` epoch containment; sub-steps individually `[x]` below).**
  Closes the persistent `continuation↔inner` native cycle — the real LuaJIT persistent-patch
  end state. **Design v2 (re-scoped after a codex pre-impl BLOCKER + a second
  APPROVE-WITH-CHANGES review, 2026-07-14):** the naive "just arm I→C and let the existing
  call-B ledger handle it" is unsafe, because with I→C persistently armed the closed cycle is
  *also* entered where no ledger is captured — call A `runLinkedLoopDone(inner)` (`trace.zig`
  ~1718) and the dispatcher `nt.run`/`runLinkedLoopDone` (`interp.zig` ~2590) — and those
  return terminal-only scalar `NativeResult` fields that cannot reconstruct intermediate hops.
  Remediation: capture the per-transition ledger at *every* native entry and drain it through
  one generic walker. Six sub-steps, each byte-identical behind `just test` except 2c-E
  (stdout identical, diagnostic counters move):
  - **2c-A — ledger disambiguation ABI.** Two orthogonal per-entry fields, both set at emit
    time (explicit, NOT position-inferred; in ledger flags, not the scalar `ExitReason`):
    (i) *materialization kind* (`link_terminal` / `loop_done_linked` / `loop_done_ordinary` /
    `ordinary_guard` / `prologue_fail`) from the compile-time-constant site; (ii) *dispatch
    outcome* (`terminal` / `dispatched` / `yielded`) for every chainable kind, so replay can
    validate every non-final entry dispatched, every final dispatched-looking entry is a
    marked forced-yield, and 'arm fired' counters separate a real child transfer from a cap
    yield. `LedgerEntry` gains the fields; the terminal-consistency assert extends to check
    the terminal entry's kind. Nothing *reads* the fields until 2c-C.
  - **2c-B — forced-yield cap.** At chain-source sites, after `emitLedgerAppend` reload
    `ledger_len`; if `>= LEDGER_CAP` `jmp shared_exit` instead of the child (append already
    recorded this exit; stamp its outcome `yielded`). Bounds a persistent cycle to ≤CAP
    entries per trampoline entry. Inert pre-cycle (spans ≤2 « 32).
  - **2c-C — generic `replayLedger` (the single authoritative multi-entry drain).** Port
    call-B `replayContinuationLedger` + the dispatcher M1 fused consumer *into* it, then
    arbitrary compositions (`C.link → I.guard → R.link`). Returns a **directive union**
    (enter `runLinkedBurst` with an already-executed ramp / offer terminal event to dispatcher
    steering / run inner / resume tier-0), NOT a bare `ChainResult`: replay owns per-entry
    *transition accounting*, the caller does *terminal steering* from the directive. Account
    every entry before any re-run bound (`hops>=max_hops` only declines the next re-run at
    span end, never early-returns mid-ledger). Terminal directive legal only at `k==n-1`;
    would-be-terminal at `k<n-1` ⇒ release-panic. Release-validate `ledger_len>=1`, first
    owner `== seed_owner`, `cum` monotonic, every adjacent pair a legit armed successor.
  - **2c-D — capture everywhere (highest risk).** (D1) mode-preserving capture at call A: a
    literal `runCapturingLedger` swap is WRONG — it forces ordinary mode (`nativegen.zig:707`,
    `false`) while call A needs linked-loop-done mode (commits the final inner iteration); add
    a linked-mode capturing entry point. (D2) dispatcher capture preserving `ran_native_link_mode`:
    `ledger_len==1` keeps the existing scalar consumer path UNCHANGED; `ledger_len>1` routes to
    `replayLedger` for accounting + a classified terminal directive, but the dispatcher STILL
    performs terminal steering — no blanket bypass. The single most likely regression: dropping
    the M1 `[ct.deopt, ramp.link]` consumer (`interp.zig:2707`), losing `onSideExit(ct,
    completed)` (~2730) + `runLinkedBurst`-with-already-executed-ramp (~2745), which shifts
    `hit_count`/penalty/gate evolution and native chain coverage. (D3) other terminal grammars.
  - **2c-E — arm `I.loopdone → C.ordinary_entry` persistently** (`.loop_done_linked`,
    `isLoopDoneGuardIndex` gate). Cycle closes; stdout byte-identical, burst bound ≤17.
    **LANDED 2026-07-14 (byte-identical; diagnostic counters move).** Counters
    `native_loopdone_link_arms`/`native_loopdone_link_fused`; fail-closed
    `armLoopDoneLink(inner, guard_idx, cont, safe_to_arm)` (all gates silently
    `return`; `nativeFor(cont).ordinary_entry` target — ORDINARY mode, 2.3c-0c);
    `safe_to_arm` threaded through `replayLedger` (all 4 call sites); armed at 3 sites
    (scalar call-A after `arm_term`; driveChain hop-0 under
    `.native_numeric_for_done`; `replayLedger` terminal `.loop_done_linked` is_last —
    the *convergence* arm so sibling inners reached only via replay still converge).
    A native-only one-trip correctness fix in the dispatcher: a linked loop-done
    receipt with `local_completed == 0` (final linked snapshot committed WITHOUT the
    back-edge `rbx` increment) is routed through the PRODUCTIVE path (`linked_one_trip`
    predicate) — the old scalar zero path DOUBLE-COMMITTED the final iteration
    (proven: with the fix disabled nsieve-shaped one-trip programs print N+1). Five
    blocking tests, all green: (i) native one-trip productive (byte-identity is the
    load-bearing gate; needs `min_trip_entry=0` to make the one-trip receipt
    reachable), (ii) end-to-end arm+fuse fire, (iii) `replayLedger` terminal
    convergence arm, (iv) forced-yield at `LEDGER_CAP`, (v) `disarmAllLinks` resets
    every slot. nsieve/mandelbrot/nbody/spectral-norm tier-0==tier-1a==native
    byte-identical.
  - **jitdbg — permanent compile-gated live JIT telemetry (2026-07-14).** Replaced the
    hand-added/removed `std.debug.print` scaffolding used to debug this arc with a
    permanent facility: `src/jitdbg.zig` + `-Djit-debug=true` build option +
    `--jit-debug` CLI flag + `TraceConfig.debug_log` runtime gate +
    `TraceState.dbg()`/`dbgDumpGuardFailures()`/`dbgDumpCache()`. Double-gated
    (comptime `-Djit-debug` ∧ runtime `debug_log`); compiled to nothing by default.
    Permanent probes: dispatcher receipt, link arm/re-arm/disarm/retire-reset.
    Documented in project `CLAUDE.md`.
  - **2c-F — disarm-on-unsafe load-bearing test + negative control + doc/task update + full
    codex `gpt-5.6-sol` diff review** before the final commit. 2.3c-0e becomes LOAD-BEARING (a
    mid-cycle observation window must reset both slots): two-phase same-VM test. S1
    slot-selected materialization rewrite is explicitly NOT part of this — runtime mode
    selection kept. **TESTS LANDED 2026-07-14; codex review still owed.** New counter
    `native_link_disarms` (slots reset by `disarmAllLinks`) makes the tear-down observable
    end-to-end. Two permanent tests added: *"2c-F … an observation window disarms a LIVE
    armed native cycle on the same VM"* — Phase A arms+fuses the cycle with NO window and
    asserts `native_link_disarms == 0` (the negative control: the safe path never disarms),
    then Phase B re-runs the same proto on the same VM behind a `record_safepoint_lines`
    window and asserts byte-identity + `native_link_disarms > 0` (the live cycle was torn
    down — load-bearing, since a byte-identical run under an open window can't by itself
    prove a non-empty registry was reset); and *"2c-F … a hot armed cycle inside a
    repeatedly-called function stays correct on re-entry"* — the supported cold-re-entry
    guard (a fused cycle inside a function called 20×), byte-identical across ASLR layouts.
    Unit test (v) additionally asserts the counter + idempotence. **Rerun blocker RESOLVED
    (2026-07-14, two codex `gpt-5.6-sol` reviews).** The full read-only review of the arc
    found all supported paths sound and raised ONE blocker: re-running a *completed top-level
    proto* twice on one VM with a live armed cycle once produced a layout-dependent `TypeError`
    from the fused handoff (~1/25 runs; unreproducible in 1600 in-process reruns or codex's
    64-layout + forced-retire harness), *unconfined* because `Vm.run` is public with no
    enforced one-shot precondition. Two layers landed: (1) **hardening** (codex) —
    `armNativeLink` DERIVES its target from `child`+`kind` (never trusts a caller address) and
    `compileImpl` validates each secondary-entry offset is in the child's live mcode page
    before publishing; the re-review judged this defensive-only (proves address provenance, not
    dynamic-entry validity across an epoch); (2) **epoch containment** (the fix) —
    `Vm.beginTopLevelEpoch` calls `disarmAllLinks()` at every fresh `run`/`start` entry (NOT
    `exec()` resume — same epoch, governed by 2.3c-0e — nor nested calls), so a stale link that
    passes both hardening checks can't fire into a fresh-epoch frame. The two-phase integration
    test was accordingly reframed from "observation window disarms" to "a fresh top-level run
    disarms the prior epoch's live cycle" (proven load-bearing: disabling `beginTopLevelEpoch`
    fails exactly it). **Nice-to-have follow-up:** a suspend/resume-with-window integration test
    for the 2.3c-0e dispatcher window-disarm specifically (unit-covered today).

**Blocking prerequisites — must be designed before any patch is safe** (peer
review, 2026-07-11; see §Blocking prerequisites for the argument):

- [x] **P-C — Exit-kind taxonomy. RESOLVED + ENFORCED IN-TREE (2026-07-12, option (b) +
  hard invariant).** The loop-done slot-exclusivity invariant is enforced at BOTH emission
  (`nativegen.zig:4563` routes the ordinary loop-done deopt around `slot[ei]`) and arming
  (`armNativeLink` `trace.zig:3274`, `isLoopDoneGuardIndex` gate) — the `(index,kind)` collision
  is impossible by construction. See the RESOLVED sub-bullet below for the full rationale.
  Only ordinary per-guard exits hit
  `deopt_exit`. `.link` terminals (`nativegen.zig:3808`) and linked-numeric-for
  loop-done (`emitLinkedLoopDoneSnapshot`, `nativegen.zig:2934`) have their own
  return/materialization paths and post-loop coherent PCs. Each transition kind in
  nsieve's chain needs its own patch/link rule; patching only ordinary guards
  leaves most hops re-entering Zig.
  - **RESOLVED (2026-07-12, Bart) — option (b) + hard invariant.** The slot table is
    keyed by *IR instruction index*. A numeric-for loop-done guard at index `ei` has
    **two** logical exits sharing that index — the linked-materialized exit (mode 1,
    `linked_loop_done=1` → `slot[ei]` → continuation) and the ordinary deopt (mode 0,
    → `shared_exit`/tier-0). **Decision: `slot[ei]` of a numeric-for loop-done guard
    is EXCLUSIVELY its linked-materialized exit; the ordinary deopt path never
    consults a slot and is never eligible for ordinary-guard arming.** Enforced as an
    invariant at BOTH the emission site (nativegen) and the arming site (trace.zig),
    so the collision is impossible by construction — no `(index, kind)` slot keying,
    no doubled P-E bookkeeping. Analysis (do-it-right-now check): option (a)'s
    capability — two independently-armable successors from one IR instruction — is
    needed by **nothing** on the roadmap. nsieve's mode-0 and mode-1 loop-done exits
    target the *same* continuation, so they never diverge; and the full
    `lj_asm_patchexit` port is one-side-trace-per-exit-snapshot (LuaJIT never attaches
    two side traces to one exit — linked vs standalone would be *different*
    snapshots). The "one instruction, two exits" is purely a lune *folding* artifact.
    If the exotic divergent case (same inner trace hot both fused and standalone with
    different post-exit targets) ever appears, the correct fix is to **unfold that one
    guard into two IR instructions** (each getting its own natural slot) — a localized
    change, strictly better than taxing every exit with `(index, kind)` keying now.
- [ ] **P-E — Patched-target lifetime / unpatching.** Since Increment 1 the arena
  keeps regions mapped for the whole run, so a stale patch is no longer a raw
  use-after-*unmap* — but it is now use-after-*reuse*: `removeTrace`→`destroy`
  (`trace.zig:1749,622`) returns the child's mcode slot to the arena free-list, and
  a later `compileInto` can hand that exact slot to an **unrelated** trace, so a
  parent still patched to it would `jmp` into foreign code. Need dependency tracking
  + unpatch-on-retire before a freed slot may be reused (or pin patched-into slots
  out of the free-list / use trampolines). Strictly required once patching exists.
  *Registry scaffolding landed in 2.3a* (`armed_links` + `armNativeLink`/
  `resetLinksTouching`, reset before `destroy`); inert until 2.3b arms the first
  slot. Still outstanding: exercise the reset under a real retire-then-reuse (widen
  eviction) end-to-end — the 2.3d lifetime stress test.
- [ ] **P-F — Determinism replication.** The patched path *skips*
  `onSideExit`/`hit_count`/penalty/gate/prime-side arming/lane-widen eviction
  (`interp.zig:2588,2605,2763`) — all of which steer *future* recording. Skipping
  them changes which traces get recorded/selected later, so byte-identity is **not**
  free. Either replicate the accounting on the patched path or prove it inert; and
  handle the exec-log mode that picks tier-1a before native (`interp.zig:2567`).
  - **Observation-window unpatching (raised 2.3b-1, Issue 5).** A slot armed by
    `driveChain` keeps fusing on later bursts even after `safe_to_arm` goes false
    (safepoint/replay-line recording active). The fused hop is still exactly
    accounted (the drain classifies every child by `final_trace_id`), so this is a
    determinism-*window* concern, not a correctness bug: it widens the observation
    blackout past the driveChain hop bound. P-F must reset/decline armed slots when
    observation activates (or prove the widened window inert), landed alongside the
    replicate-or-prove-inert work above.
- [ ] **P-G — Child eligibility + prologue-failure fallback.** A direct patch
  bypasses `driveChain`'s guards (zero synthetic inputs — `seedTraceInputs` is
  mandatory for `inputs.len != 0`, `interp.zig:2551`; native availability; terminal
  shape; bounded candidate attempts). Child prologue failure is state-safe
  (`nativegen.zig:3884` leaves `regs[]` untouched) but currently has *no* clean
  fallback after a patched jump (parent count lost, no sibling retry). Both need a
  defined contract.

**Increment 3 — close the branchy-loop region, then patch (design landed 2026-07-17;
codex `gpt-5.6-sol` pre-impl review = BLOCKER — REDESIGN before coding).** Two
sequenced parts (Bart's call). See §Increment 3 for the full contract, the
`--jit-stats`/gate-A-B evidence, AND the review-outcome subsection that supersedes the
first framing. Two Part-A claims came back unsound; a fork on the determinism contract
awaits Bart.

- [ ] **3A — Close the outer-loop region: edge-4 bridge + gate strategy B. [CONSOLIDATED
  BUILDABLE DESIGN WRITTEN 2026-07-19 — see §Part A — CONSOLIDATED buildable design; pending a fresh
  gpt-5.6-sol pre-impl review before code.]** The consolidated section assembles rounds 3–8 + the
  H-series groundings + the 2026-07-18 landings into one buildable spec (superseding the scattered
  round-N subsections for implementation) and folds the two post-round-8 changes: **H-2 is CLOSED**
  (dynamic-proto gate `b2d9d18` + `{gc,snapshot}` split `3f1df3f` + `beginTopLevelEpoch` cache-clear
  `9a8c141` + keyframe v4→v5 `next_obj_id` — snapshot bytes are now JIT-tiering-independent by
  construction, so **Part A is no longer gated by H-2**), and **9-A landed both preconditions**
  (`pure ⇒ !effect`, `depth==0` fail-closed, `9fcc2c4`). Five mechanisms (edge-4 bridge / region
  accounting + gate B / GuardProvenance 9-B un-deferred as Part A's consumer / H-3 cap / H-4
  native-F2c cut), an 8-step byte-identical landing sequence (inert scaffolding A-i..A-vi, then the
  A-vii arm-flip, then A-viii disarm+safepoint), and five open questions for the reviewer (Q1 the
  composite-gap no-yield safepoint hole is the sharpest). Round-8 (superseded for impl) resolved the two deep findings the
  round-7 review surfaced on the JIT↔snapshot boundary. **G-1** abandons the IR-position
  `exit_ordinal` (NOT re-recording-stable — recording is guest-value-dependent, `guardExitPc` can't
  supply `exit_pc` for array/table/grid guards) for a guest-logical `GuardProvenance`
  `{source_proto_id,source_pc,inline_depth,role,operand,occurrence}` stamped at emission for ALL
  guard kinds (a new IR metadata obligation). **G-2 ‡ (the deep one, confirmed against the tree)**:
  the transient trace cache roots heap objects INTO the serialized snapshot (keyframeser seeds its
  walk from the shared `forEachRootHeader`, item 5 roots trace/recording consts) → a
  tiering-dependent `region_profit` history can change snapshot bytes; resolved by splitting
  `forEachRootHeader` into `{gc, snapshot}` kinds (trace consts are GC-liveness roots ONLY,
  excluded from the snapshot semantic-root walk) with a case-1/case-2 proof — the general fix,
  making all snapshotting JIT-independent by construction. **G-3** activation-scoped cleanup made
  MANDATORY (entry lifetime = activation lifetime ⇒ cap can never evict live) + unconditional
  `beginTopLevelEpoch` region-clear. **G-4** tier-independent native-F2c cut + effect-cursor
  assertion. **G-5** single-stack re-key invariant pinned (coroutine future-proofing). Keyframe
  stays **v4**; two new impl obligations (`GuardProvenance` IR extension + `{gc,snapshot}` root-walk
  split). — Round-7 (superseded): resolved all round-6 blockers, grounded in 2 more tree sweeps. F-1
  structural key gained a recording-stable `exit_ordinal` (REVERSED by G-1); **F-2 ‡ restore re-keys
  each live frame `call_seq=i`** by index (v4 holds, no wire field); F-3 exact-`frames[depth-1]` +
  `next_call_seq` exhaustion; **F-4 fork COLLAPSED** (mcode separate `mmap`, `gpa` unbounded → OOM
  outside replay equivalence); F-5 native-F2c obligation; F-6 exit polarity fixed; **F-7 fork
  COLLAPSED** (monotonic keys ⇒ no correctness hazard — but round-7 review re-opened this as G-3:
  the cap can still evict LIVE accounting); F-8 non-issue. — Round-6 (superseded): reshaping insight survives,
  codex "a v4→v5
  schema bump is not inherently required") → **E-5 deviation VINDICATED, keyframe stays v4**;
  Antigravity UNSOUND but every counterexample defused by lune facts codex verified. Surviving
  round-7 blockers: F-1 ‡ structural-edge-id collision (guards share `cur_pc` → add ordinal/role
  discriminator); **F-2 ‡ restore must re-key live activations** (`keyframeser.zig:671` bypasses
  `pushFrameVararg` → "reset call_seq=0" wrong; fresh transient `call_seq` per restored frame by
  order, still no wire field); F-3 exact-current-frame invariant + `next_call_seq` exhaustion;
  F-4 allocator-exhaustion fork (JIT/VM share allocator); F-5 native-F2c test obligation (current
  harness tier-0-only); F-6 E-6 exit-test polarity fix; F-7 host-abort-boundary fork + centralize
  cleanup with `protectedCall`'s 3-site depth restore; F-8 ground `safepoint_seq`/effect-log
  non-interference. E-3/E-4/E-6 resolved (E-4 modulo F-1). Round-6 (superseded) resolved all
  E-1..E-7; the
  reshaping insight ‡: `region_profit`+`call_seq` are **transient JIT-tiering state, NOT
  replay-serialized** (they steer only which tier runs, never output) → **E-5 needs no keyframe
  schema bump** (v4 stays; reset-on-restore is accounting-neutral, the reviewers' own "logical
  reset" alternative) and **E-2's `call_seq` is the anchor frame's**, assigned tier-0 at
  `pushFrameVararg` and never mutated on-trace (inlined callees push no physical frame) →
  tier-invariant, no new IR op, no loop-carried commit discipline. E-1 `StructuralEdgeId` +
  ephemeral `(Trace.id,exit_instr)` cache; E-3 optional `?ExitKey`; E-4 identity-transition exit;
  E-6 no coroutines (host-reentrancy depth handled); E-7 two teardown hooks + `__gc` moot. β
  preserved (one `u64` on `CallFrame`). **The E-5 deviation from round-5's recorded v4→v5
  resolution is flagged in-doc for Bart + reviewers to veto.** — Round-5 review (superseded):
  edge-4 bridge mechanism (D-1/D-2/D-6) now SOUND; surviving blockers were
  cross-cutting integration surfaces the round-5 machinery pulls in (E-1 `RegionDef` keyed by
  ephemeral `Trace.id` → needs stable structural edge id + ephemeral lookup; E-2 `call_seq`
  can't be a physical `CallFrame` counter under trace inlining; E-3 classifier key absent at
  synthetic scalar `onSideExit` sites; E-4 overlapping-PC region exit; E-5 keyframe schema v4→v5
  for `call_seq`+`region_profit`; E-6 coroutine thread-scoped depth; E-7 error-unwind cleanup).
  **E-2 + the `call_seq` half of E-5 are β-specific** — the review re-weights the D-3c=β choice:
  (α) fail-closed-exclude-recursion avoids ALL `call_seq` machinery + the schema bump and
  unblocks nsieve now; E-1/E-3/E-4/E-6/E-7 + the `region_profit` half of E-5 are the floor under
  both. Round-5 discharges D-1..D-6 with
  Bart's D-3c fork = **(β) build activation discrimination** (deterministic per-VM monotonic
  `call_seq` on `CallFrame`, gc_stress-invariant): D-1 cap-check reserves TWO cells
  (`>= CAP-1 → ordinary_mini`) + unreachable-`CAP` invariant; D-2 compile-time emitted set E
  (parent-trace-local) vs arm-time required set S (arm iff `S ⊆ E ∪ invariants`, drop
  `final_trace_id` write, child `inputs.len==0` at arm time); D-3 three-map split (logical
  `region_defs` / per-activation `region_profit` / physical `armed_links`), identity `RegionId`,
  window `+= N`, stack-gated exit, discovery from the recorded trace graph in every tier; D-4
  classifier keyed `(trace_id, exit_instr)` + split at every `onSideExit` site; D-5 ‡ logical
  maps at Proto/VM & logical-boundary lifetimes, only `armed_links` retirement-cleaned; D-6
  wording/fixed-point/`.yielded` precisions. Round-4 discharges
  B-1..B-9 with Bart's B-3 fork = **(b) generic stubs, armed later**: a trace-local
  bridge-capable stub emitted at every composite guard (C.1.1, no region map at lowering),
  cap-check-FIRST then commit reusing the `ordinary_mini` path for both unarmed and
  ledger-full (C.1.2/C.1.3, B-1/B-2); a **persistent VM-level region table** (not trace
  state, not flushed on retirement) with a stack-depth-gated region-exit + activation-keyed
  `RegionKey` + logical window `N = min_useful` (C.2, B-4); a tier-independent
  `(proto, exit_pc)` classifier at all three accounting sites (C.3, B-6); successor
  live-in ∪ live-through set (C.4, B-5); replay-owned resume PC via the edge map (C.5, B-7);
  synthesized `completed` preserved (C.3.2, B-8); stub-free/map-explicit split lifetimes
  (C.1.4, B-9). Round-3 review (codex+Antigravity) confirmed the sound sub-parts
  (A.1.1–1.3, A.2.1–2.3, A.3). Round-2 codex+
  Antigravity both approve the direction (arming/
  patching over trace-selection) and gate **B over C** (decisive reason corrected to
  *determinism*: C's "armed" is a physical native state tier-1a/record-only can't share),
  but both returned BLOCKER on the specifics; the **round-3 design pass now resolves all
  nine** in §Part A — round-3 design (grounded in `nativegen.zig:4543-4705`/`3597-3625`,
  `trace.zig:1550-1581`/`3098-3395`/`2148-2160`, `irinterp.zig:154-217`, and the cont(29)
  IR dump), pending a fresh codex+Antigravity re-review before code. Key round-3 findings:
  an armed ordinary guard is ALREADY a native handoff (edge 4 is the *only* per-iteration
  Zig re-entry left, not edges 1+4); edge 4's coherence gap is exact — cont's `count+1`(%4)/
  `next i`(%11) dominate its `%023` composite guard but their phi writebacks (`%031-033`→
  r2/r3/r6) are post-guard, so the shared `deopt_exit` carried-home flush commits stale
  values; the bridge is an in-page stub (like `linked_loop_done_labels`), not a heap object,
  so the existing registry covers its lifetime for free. The nine items were: **bridge** — (1)
  dominance-scoped snapshot (only phis dominating cont's composite guard, `{count+1, next
  i, next visible i}`; NOT the full `.link` flush, which includes post-guard inner phis);
  (2) materialize `regs[]` + enter `skip.ordinary_entry` so the child prologue re-runs
  type/shape/identity guards (resolves the invariant-bypass hazard) — no physical register
  shuffle; (3) require `skip.inputs.len==0`; (4) bridge lifetime/ABI (emission, target
  storage, re-arm, retirement invalidates bridge+parent slot, forced-yield). **accounting**
  — (5) split `onSideExit` into `accountTraceRun` (coverage/cycle/hit_count, per-segment) vs
  `accountRegionProfit` (penalty/gate only) — else hit_count changes which traces
  select/record; (6) normalized traversal unit (skip composite iters + one per prime cycle;
  never sum raw `rbx`/inner `k`); (7) stable identity `RegionKey` owner `AnchorKey`
  `(proto,14)`, not the selected `*Trace`; (8) tier-independent **logical** region window
  feeding one accumulator (native LEDGER_CAP=32 vs tier-1a 8-hop vs unlinked per-segment
  must NOT define profitability events) + GC-safepoint exits excluded; (9) additive
  cross-anchor ledger grammar that does NOT weaken the same-anchor `.deopt` provenance
  (3098) / zero-progress (2159) invariants. `min_useful` retune attaches to the bridge
  (2.3a indirect already removed the ~600ns hop; Part B rel32 only removes the slot load);
  8 holds iff the logical window is multi-prime, else scale→1 pre-patch. P-EBP-2 equivalence
  asserted over the 6 `record+exec-* × gc_stress` modes only. Direction is settled; the
  fragmentation is LuaJIT-faithful (doc 15 +
  recorder + `luajit -jdump` all show identical fragmentation → "fix trace selection"
  ruled out). Two mandatory mechanisms: (1) **edge-4 bridge/materialization** — new
  `ArmKind`/ledger kind + a compiler-generated bridge stub (lune's `asm_head_side`)
  that commits `cont`'s outer-back-edge phis (`count+1`, next `i`) and shuffles regs
  into `skip(14)`'s entry contract before jumping — NOT `.ordinary_guard` reuse
  (discharges the coherence BLOCKER); (2) **gate strategy B — region-level
  accounting** — `replayLedger` aggregates one region-burst's committed traversals
  into a single `onSideExit(region_owner, summed)` vs `min_useful`, applied
  consistently across native/tier-1a/unlinked (discharges the accounting BLOCKER;
  chosen over (c) exempt-armed because B measures the right unit, is correct regardless
  of transition cost, and retains cold-region retirement C discards). New cross-anchor
  replay grammar (accept cross-anchor + rbx-advancing successor; attribute to region
  owner) + a validated region-membership/PC map (`driveChain` walks `failed.anchor.pc`;
  cont@29 must discover skip@14). Carried: no-yield hole = APPROVE-WITH-CHANGES (native
  back-edge poll only if async latency needed); lifetime SOUND if `safe_to_arm`-gated +
  both-cycle 2c-F test. P-EBP-2: aggregate `onSideExit` sequence proven mode-invariant
  on the 10-mode matrix. Future opt (measure-gated): B collapses to C for proven-hot
  armed regions.
- [ ] **3B — Faithful `lj_asm_patchexit` port + in-place-patch P-E. [BLOCKER — depends
  on 3A + new patch contracts].** Review found "co-location ⇒ rel32 always reaches" is
  false (`McodeArena` `mmap(null)`, cross-region deferred; nativegen.zig:175/296) — every
  patch needs a checked disp32 + near-trampoline fallback; a raw rel32 child jump
  bypasses the forced-yield cap (must keep "ledger-full → shared exit, else fall through
  to patchable rel32"); ordinary guards have no per-exit patch point (converge on one
  shared `deopt_exit` post-flush) — need per-exit tails/trampolines; discovery needs a
  defined cross-anchor PC mapping (`driveChain` walks `failed.anchor.pc`); P-E must track
  patch offset/encoding/restore, not just slot cells; W^X window is whole-region — state
  the single-threaded/no-native-callback invariant. Safe-point argument = P-EBP-4.
  **Also on Part-B landing: retune `min_useful`** (calibrated for expensive entry;
  cheap rel32 transitions drop break-even toward 1–2, so `8` unchanged would over-retire
  short-trip regions — the nsieve pathology inverted). Retune the constant (or express
  break-even as a function of transition cost) as part of this increment; consume 3A's
  region-membership map for cross-anchor patch discovery.

**Implementation phases (unblocked only after the prerequisites above):**

- [ ] **Phase 1 — Patch infrastructure.** `exit_instr → mcode offset` map on
  `CompiledTrace`; W^X repatch on `ExecPage`. (Still needed; unchanged.)
- [ ] **Phase 2 — Memory-handoff link.** Once P-A/P-B/P-C exist, patch each
  transition kind to hand off native→native through `regs[]`. A/B on nsieve.
- [ ] **Phase 3 — Register-level coherence (defer).** Keep carried values in
  registers across the handoff (canonical anchor register assignment or an
  `asm_head_side`-style reconciling head). Only if Phase 2's A/B shows the memory
  round-trip still dominates.
- [ ] **Open question — safe point vs. live parent.** Patching happens in the
  dispatcher *after* the native call returned, so normally no parent activation is
  live; but `mprotect(RW)` makes the whole page briefly non-executable, and lune's
  assembler does not align jump operands (`x64.zig:852`). Use an explicit safe
  point; do not treat "aligned 4-byte store" as the safety proof (LuaJIT relies on
  its mcode write-protect protocol, not dword-store atomicity).

## The LuaJIT mechanism (what we're porting)

Four moving parts on x86-64 (`~/Projects/LuaJIT/src/`):

1. **Exit stubs** — shared 4-byte trampolines, one per exit number. They live in
   `jit_State.exitstubgroup` and are generated **lazily and reused** across trace
   compiles (`asm_exitstub_setup`, `lj_asm_x86.h:51`; addressing via
   `exitstub_addr`, `lj_target.h:152`), not freshly per trace — a correction to the
   first-draft claim. Each pushes its exit number and falls into a shared
   `jmp lj_vm_exit_handler`. The stub address is a pure function of the exit
   number.
2. **Guard jumps** — each guard is a 6-byte near `0f 8x rel32` (`emit_jcc`,
   `lj_emit_x86.h:502-509`) whose `rel32` targets *its exit's* stub. Exit number =
   snapshot index; one `SnapShot` per exit.
3. **The exit handler** — `lj_vm_exit_handler` (`vm_x86.dasc:2806`) spills all
   GPRs/XMMs into an `ExitState`, reconstructs the exit number, sets
   `J->parent`/`J->exitno`, and calls `lj_trace_exit`, which `lj_snap_restore`s
   the interpreter stack from the exit snapshot. **This entire path runs only
   before a side trace exists.**
4. **The patch** — `lj_asm_patchexit` (`lj_asm_x86.h:3127-3164`). When a side
   trace is assembled (`trace_stop`'s `BC_JMP` case, `lj_trace.c:528-545`), it
   makes the parent page writable, scans the parent mcode with a length decoder,
   finds every `0f 8x` whose `rel32` resolves to the target exit's stub
   (`px = exitstub_addr(exitno) - 6`), and rewrites the 4-byte `rel32` at `p+2` to
   `side_entry - (p+6)`. It skips the stack-check and GC-check exits. Then it marks
   the parent snapshot `SNAPCOUNT_DONE` so it's never side-traced again.

**Why the direct jump needs little marshalling (the crux):** the side trace's head
(`asm_head_side`, `lj_asm.c:1941-2110`) was compiled to expect *exactly* the
parent's register/spill state at that exit — seeded by `lj_snap_regspmap` reading
the `(parent, exitno)` snapshot's RegSP map as register-allocation hints, then a
reconciling prologue that reloads spills and register-shuffles (breaking cycles
through a temp). It is **not literally "zero marshalling"** (the first draft
overstated this): `asm_head_side` still adjusts the stack, reloads spills, and
shuffles registers — the property is *direct native-to-native state
reconciliation with no interpreter round-trip*, not zero work. The **snapshot is
the single coherence contract**, consumed by both the interpreted restore *and*
the native side-trace head. The patch swings one `rel32` from the
interpreted-exit stub to that head.

**The structural precondition lune does not share:** LuaJIT traces are mcode in
*one contiguous VM-owned arena* and do **not** each carry a C-ABI stack frame — a
trace transfer is a bare `jmp` within a shared machine-code region, and the frame
/ stack discipline is uniform across all traces. lune traces are each entered as
an **independent C function** (`fn(tags, payloads, *NativeResult) callconv(.c)`)
with their own push/frame-alloc prologue and `pop`/`ret` epilogue, each in its own
`mmap`. That single fact is what turns "swing one rel32" from a 4-byte edit into a
new-ABI problem (see §Blocking prerequisites).

## lune today (where the patch point is)

lune's tier-1b backend funnels **all** native guard exits through one shared
epilogue (`nativegen.zig`):

- Each guard's failure path is a `jcc`/`jmp rel32` to a **per-guard-instr local
  label** (`jccNativeExit`/`jmpNativeExit`, `nativegen.zig:2705-2718`).
- Each label binds a tiny stub (`nativegen.zig:3843-3857`):
  `mov dword [rdx + exit_instr], <ir_index>` then `jmp deopt_exit`. `rdx` is the
  `*NativeResult` out-param.
- `deopt_exit` (`nativegen.zig:3870`) flushes every `.carried` slot's register
  home back into the `regs[]` SoA file (`flushSlot`, re-boxing with type tags),
  writes `completed = rbx`, runs the shared teardown (`add rsp; pop; ret`).

Control returns to the dispatcher by a plain C-ABI `ret`; the trace was entered
as `fn([*]u8 tags, [*]u64 payloads, *NativeResult) callconv(.c) void`
(`nativegen.zig:351`). `interp.zig` (~2560–2810) unpacks `ExecResult`, does
guard-failure accounting, then `driveChain` linear-scans the trace cache
(`nextTraceExcluding`, `trace.zig:1084`) and enters the next trace via a fresh
`NativeResult` + indirect call — the ~600 ns.

**Patch site.** The natural target is the exit stub's trailing `jmp deopt_exit`
(`nativegen.zig:3845-3855`): it is already one 5-byte `jmp rel32` per
`exit_instr`. Redirecting one exit = rewriting that `rel32` to a side trace's
entry.

**Three things don't exist yet** (all net-new, all Phase 1):

1. **No exit-instr → offset map survives compilation.** `exit_labels` is
   `gpa.alloc`'d and freed by `defer` at the top of `lower` (`nativegen.zig:2970`);
   the `Assembler` (labels + fixups) is deinit'd after `resolve()`. `CompiledTrace`
   retains only the `ExecPage` bytes (`nativegen.zig:348`) — no metadata linking an
   exit to where its jump lives. We must record `exit_instr → byte-offset` during
   `lower` and store it on `CompiledTrace`.
2. **The page is W^X (RX), not RWX.** `mapExecutable` maps RW, copies, then
   `mprotect`s to `READ|EXEC` (`nativegen.zig:104-134`). In-place patching needs a
   `mprotect(RW) → write → mprotect(RX)` path on `ExecPage`.
3. **No parent-guard → side-trace address link.** The trace layer records side/
   link traces by anchor (`findLinkTrace`, doc 15/16), but the parent's compiled
   page holds no reference to a child's `CompiledTrace.page.entry()`. Joining
   `(parent Trace, exit_instr)` → `child entry addr` at side-trace compile time is
   the trigger for the patch.

## The one real difference — memory handoff, not register handoff

This is the load-bearing distinction and it defines the phasing.

LuaJIT keeps live values **in registers** across the guard exit; the side trace's
head shuffles the parent's registers into place. That is why LuaJIT *needs*
`asm_head_side` + the snapshot RegSP map — without them the direct jump would land
on code that reads the wrong registers.

lune keeps live values **in the `regs[]` SoA memory file**. The parent's
`deopt_exit` flushes carried homes to `regs[]`; the child's prologue loads them
back from `regs[]` and re-checks their tags. Both sides already agree on the
`regs[]` layout at a shared anchor pc — that agreement is exactly what makes
`driveChain` correct today (it passes `regs` and each entered trace reads its
coherent state from the file at its anchor).

Consequences — with the peer-review corrections folded in:

- **lune's patch avoids LuaJIT's register-shuffle head for a *correct value
  transfer*:** the handoff medium (the memory file) is layout-compatible between
  siblings at a shared anchor by construction, so no `asm_head_side`-style register
  reconciliation is needed *merely to move the values*. This much of the first
  draft holds — see the coherent-anchor contract already relied on by `driveChain`
  (`trace.zig:1200`).
- **But "no `asm_head_side` needed" is true only about physical value layout, not
  about the control/fallback contract.** The naive direct jump breaks on several
  axes the memory-layout argument does not touch: the per-trace C-ABI frame (a
  child prologue cannot run on top of the parent's live frame), result attribution,
  the multiple exit kinds, child eligibility, and the fallback when a child's own
  entry guards fail. These are the §Blocking prerequisites.
- **The round-trip lune still pays** (that LuaJIT avoids): even once a *valid*
  native handoff exists, the parent flushes carried homes to `regs[]` and the child
  reloads + re-tag-checks them in its prologue. The child prologue is **not** just
  "reload 1–2 carried slots" — it tag-checks every non-write-only slot, reloads
  invariants/spills, and re-runs table/function identity + array-base checks
  (`nativegen.zig:3006-3125`). Still likely tens of cycles when hot (much less than
  a 600 ns dispatch), but the first draft conflated "1–2 carried slots" with "1–2
  prologue checks." Phase 3 (register coherence) is what removes this round-trip.

**Retraction of the headline hypothesis.** The first draft claimed *"Phase 2 alone
flips nsieve from neutral to a win."* That is **unsupported** and partly wrong: the
proposed patch site (the ordinary per-guard exit stub) covers only *one* of
nsieve's transition kinds. The prime→inner→continuation chain also hops through
`.link` terminals and linked-numeric-for loop-done exits, which do **not** flow
through `deopt_exit` and have no patch point in the first draft — so most of
nsieve's linked-burst hops would still re-enter Zig. The *narrow* hypothesis that
survives: **once a valid direct native handoff exists for a given transition kind,
the hot `regs[]` stores + prologue checks are probably much cheaper than the
600 ns Zig dispatch.** That is plausible and worth measuring, but it is a
per-transition-kind claim, not a whole-benchmark prediction, and it presupposes
P-A…P-C are built. We measure component costs (dispatch vs. memory handoff vs.
child prologue vs. remaining unpatched hops), not a single before/after.

## Blocking prerequisites

These came out of the peer review (gpt-5.6-sol, 2026-07-11) verified against the
tree. None of the implementation phases are safe until these are designed; they
are the checklist items P-A…P-G above, argued here.

**P-A — Native chain-entry ABI (the load-bearing blocker).** Every lune trace is
entered as an independent C function that pushes callee-saves, allocates a spill
frame, and keeps its completed-iteration count in `rbx` (`nativegen.zig:2991`), all
restored by `emitTeardown` before `ret` (`nativegen.zig:3870`). Patching an exit
stub to `jmp child.entry` skips that teardown: the child then pushes *its* frame on
top of the parent's live frame, and its eventual `ret` returns through parent spill
contents — a crash, not a link. A correct patched route must (1) materialize the
exit state, (2) fold the parent's `rbx` into a chain-wide completed count, (3)
restore the parent frame + callee-saves, (4) preserve the ABI arg regs
(`rdi`/`rsi`/`rdx`), and only then tail-jump to a child C entry — *or* introduce a
bespoke internal chain-entry ABI where linked traces share one frame and skip the
per-trace push/pop. Contrast LuaJIT: its traces are mcode in one arena with a
uniform frame, so a trace-to-trace `jmp` is frameless by design. This is the
decision everything else hangs off.

**P-B — Chain-wide result contract.** `NativeResult{completed, exit_instr,
linked_loop_done}` (`nativegen.zig:337`) describes *one* trace. A child resets
`rbx` to 0 in its prologue (`nativegen.zig:2996`), overwrites `result.completed`
with only its own count, and writes an `exit_instr` indexed into *its* IR. The
dispatcher still binds the returned result to `ct` = the parent and indexes the
parent's instrs with it (`interp.zig:2584,2595`) → out-of-bounds or wrong-guard
accounting, and the parent's committed count is lost (it drives `onSideExit`,
arming, gating). Need a result carrying *final* trace identity, *final* exit
identity, *cumulative* completed work, and the coherent resume PC.

**P-C — Exit-kind taxonomy.** Ordinary per-guard exits flush `.carried` slots via
`deopt_exit`. But: `.link` terminals commit every slot-bound phi snapshot and
return directly, not through `deopt_exit` (`nativegen.zig:3808`); linked-numeric-
for loop-done runs `emitLinkedLoopDoneSnapshot` (post-guard stores + phi handling,
coherent PC is *post-loop*, `nativegen.zig:2934`) and its trigger currently comes
from the dispatcher *before* entry (`interp.zig:2573`); write-only slots are
committed at the completed back-edge, **not** at a failing-iteration deopt
(`nativegen.zig:3760`) — flushing a failing iteration's write-only temp would be
wrong. Each transition kind in nsieve's chain (skip→prime guard, prime `.link`→
inner, inner loop-done→continuation, continuation `.link`→inner) needs its own
patch/link rule.

**P-D — Shared code arena / rel32 reachability.** Each trace is its own anonymous
`mmap` (`nativegen.zig:104`) with no ±2 GiB adjacency guarantee, so a parent→child
`rel32` may be unencodable. LuaJIT owns a contiguous mcode arena and asserts
reachability. Options: a near code arena for trace mcode, per-link near
trampolines, or an absolute-indirect transfer (`jmp [mem]`) at the patch site.

**P-E — Patched-target lifetime.** Traces are retired and their pages unmapped via
`removeTrace`→`destroy` (`trace.zig:1749,622`); a parent patched to a since-freed
child is a use-after-unmap on the next exit. Need a back-reference so retiring a
child unpatches its parents (restore the exit to `deopt_exit`), or pinned
trampolines that outlive individual traces.

**P-F — Determinism replication (not free).** The dispatcher path the patch
replaces does more than transfer control: it runs guard-failure counting,
`onSideExit`, `hit_count`, penalty/gate updates, prime-side arming, and lane-widen
eviction (`interp.zig:2588,2605,2763`). Those mutate *future* trace
selection/recording. A patched jump that skips them changes which traces exist
later — so byte-identical output is **not** guaranteed by construction (this
retracts the first draft's P-EBP-2 claim that "patching adds no new signal").
Either the patched path must replicate the accounting that still matters, or each
skipped counter must be *proven* inert once a link is committed. Additionally, when
exec-logging is on the dispatcher selects tier-1a *before* the native branch
(`interp.zig:2567`), so the patched-native exec-log surface must be reconciled with
the tier-1a one, not assumed identical.

**P-G — Child eligibility + prologue-failure fallback.** A direct patch bypasses
every precondition `driveChain` enforces today: zero synthetic inputs (a trace with
`inputs.len != 0` requires `seedTraceInputs` before entry — `interp.zig:2551` —
and must **never** be a patch target), native availability, terminal shape, bounded
candidate attempts, and exclusion of already-failed siblings (`trace.zig:1239,
1249`). And when a patched child's *own* prologue guard fails, it returns
state-safe (zero completed, `regs[]` untouched — `nativegen.zig:3884`) but into a
world with no fallback: the result is attributed to the parent, the parent count is
gone, and the `driveChain` that would have tried another sibling was bypassed. The
link contract must define this fallback (e.g. child-prologue-fail returns to a
dispatcher entry that re-derives coherent tier-0 state at the anchor).

## Port architecture (LuaJIT-grounded)

A second read of LuaJIT's `lj_mcode.c` (arena) and `vm_x86.dasc` /
`lj_target_x86.h` (frameless ABI) settled *how* to adapt, and the central finding
is that **lune does not need LuaJIT's full fixed-register convention.** LuaJIT
keeps `BASE`/`PC`/`DISPATCH`/`KBASE` in fixed registers (`lj_target_x86.h:46-53`)
so a trace→trace `jmp` needs zero marshalling. lune already round-trips every
Lua-level value through the `regs[]` SoA memory file, so it only needs the two
sides to agree on **where the base pointers live** — a 2–3 register mini-convention
— not on where any Lua value lives. That keeps the handoff a pure function of
`regs[]` memory (determinism-safe: nothing new is smuggled into a register that
isn't already a deterministic function of the slab) while still enabling a bare
`jmp`.

**The arena (P-D), from `lj_mcode.c`.** One (or few) large `mmap`'d region(s)
instead of a per-trace `mmap`, placed inside a rel32 window so any trace can
`jmp`/`call` any other and the runtime. Port verbatim-in-spirit:
`mcode_setrange`/`mcode_inrange` (`lj_mcode.c:269,288`) — a `[mcmin,mcmax]` window
of width ≤ rel32 range, **centered on the code traces must reach** (LuaJIT centers
on `lj_vm_exit_handler`; lune centers on the Zig `driveChain`/trampoline address so
trace↔runtime calls stay reachable); the contiguous-below-then-probe placement
loop (`mcode_alloc`, `:295-320`); the `LJ_TRERR_MCODEAL` **abort-the-trace**
fallback when no in-range placement is found (`:333`) — out-of-range is never
tolerated. Sub-allocate each trace from a `mctop`/`mcbot` cursor pair; the
`ExecPage` becomes a *slice* of the shared region, not an owned mapping. Area-level
W^X with the `mcprot` RW/RX cache (`:252`) and an `lj_mcode_patch`-style RW/RX
bracket (`:416`) for the patch window.

**The frameless model (P-A), from `vm_x86.dasc`.** LuaJIT traces have no C frame:
`BC_JLOOP` publishes `BASE`, saves the extra callee-saves *once* at the
interpreter↔trace boundary, and `jmp`s into `T->mcode` (`vm_x86.dasc:5429-5461`);
trace→trace links are bare `jmp`s (`asm_tail_fixup`, `lj_asm_x86.h:2961-2963`, taken
**unconditionally** when there's a link target because the arena guarantees reach);
the *only* frame restore is the exit handler (`vm_x86.dasc:2867`), owned by the
interpreter, entered once and left once regardless of how many traces chained.
lune's analogue:

- **One shared trampoline owns the single C frame.** It does the real prologue
  (`push rbx` + callee-saves + frame + pins `tags`/`payloads`/`result` into the
  reserved registers, mirroring `nativegen.zig:2997-3000`), then `jmp`s to the
  first trace body's entry label.
- **Trace bodies become frameless** — drop their per-trace `push/sub`
  (`nativegen.zig:2997-3000`) and `pop/ret` (`:2699-2702`). A body ends by either
  (i) `jmp`ing directly to the next body's label (the chain link — the bare `jmp`
  that replaces the ~600 ns Zig round-trip), or (ii) `jmp`ing to **one shared
  epilogue** that fills `NativeResult`, runs `pop`/`ret` once, and returns to Zig.
- **Exactly one frame is built/torn down per chain entry from Zig**, not per trace.
  `driveChain` calls the trampoline once and gets one chain-wide `NativeResult`
  (P-B) back after the chain reaches a genuine exit.

This is where the nsieve win actually lands: the per-transition re-entry collapses
to a single `jmp rel32` per link.

## Phasing (three ordered increments)

### Increment 1 — Shared arena, keep the per-trace C ABI (P-D) — ✅ LANDED

Pure co-location: replaced `mapExecutable`'s per-trace `mmap` (production path)
with `McodeArena` (`nativegen.zig`) — a chain of ~1 MiB regions, bump cursor +
first-fit free-list, mcprot-style RW↔RX toggle per write. **The per-trace
`call`/`ret` C ABI is unchanged** — traces are still C functions, just co-located.
`ExecPage` became a view (`.owned` for `mapExecutable`'s standalone test path,
`.arena` for the arena); `compile(gpa,t)` (tests) and `compileInto(gpa,arena,t)`
(production via `nativeFor`) share `compileImpl`. Owned by `TraceState`
(`mcode_arena`), deinited after the trace cache. Bought nothing for speed on its
own (arena work is compile-time only); it is the *precondition* for every later
bare `jmp`, landed independently with byte-identical behaviour.

**Deferred out of Increment 1** (were listed here, moved to Increment 2/3 where
they actually apply): the rel32-window placement centred on the runtime + strict
in-range check (nothing emits a cross-region reference yet — all runtime-helper
calls are absolute `mov rax,imm64; call rax`), and the `exit_instr → mcode-offset`
map + `repatch` (that is patch infrastructure, so it lands with Increment 3).
Gate met: `just test` green, 10-mode matrix + nsieve byte-identical, nothing
patched yet.

### Increment 2 — Shared trampoline + frameless bodies (P-A, P-B, P-C, P-G, P-F)

Introduce the single entry trampoline, strip per-trace prologue/epilogue, pin the
2–3 base pointers, and convert chain links from Zig round-trips into bare `jmp`s
between body labels — for each exit kind (ordinary guard / `.link` /
linked-loop-done, P-C). Add the chain-wide result (P-B), child eligibility +
prologue-failure fallback (P-G), and replicate/prove-inert the skipped accounting
(P-F). Gate: 10-mode matrix byte-identical; keyframe + replay goldens unchanged;
**component-timed** nsieve A/B (dispatch vs. handoff vs. prologue vs. residual
hops).

#### Increment 2 — detailed design (frameless + link-slot handoff)

This is the concrete plan the phasing bullet above summarises. It is grounded in
the *current* native ABI (mapped exhaustively from `nativegen.zig`, 2026-07-11):

Current per-trace ABI (what we are replacing):
- Entry `fn(rdi=tags, rsi=payloads, rdx=*NativeResult) callconv(.c) void`.
- Prologue: `push rbx; push <callee-saved used>; xor rbx,rbx; sub rsp,frame`.
  `rbx` = committed-iteration counter; `rdi/rsi/rdx` held across the body;
  `rax/rcx` scratch; allocatable GPRs `r8–r11` (caller-saved) + `rbp,r12–r15`
  (callee-saved, saved only if used); allocatable XMMs `xmm2–xmm15`; spills at
  `[rsp+k*8]` in the trace's own frame.
- Every exit `flushSlot`s live carried/write-only slots back to `regs[]`
  (tags[slot]=tag byte via rdi, payloads[slot*8]=payload via rsi), writes
  `completed`(rbx) + `exit_instr`(i) to `[rdx]`, then `emitTeardown` (restore rsp,
  pop callee-saved, pop rbx, `ret`). `.loop` back-edge is a local `jmp loop_top`.
- Only runtime call is `resolveHashCell`, absolute `mov rax,imm64; call rax`, with
  manual save/restore of rdi/rsi/rdx + caller-saved around it. **No cross-buffer
  rel32 exists.**

**Load-bearing correctness fact (the whole design rests on this):** the *only*
state that crosses a trace→trace transition is `regs[]` (tags/payloads, in
memory), `rbx` (the counter), and `rsp` (constant in a frameless chain). Register
homes are **not** live across a transition — every exit already flushes live slots
to `regs[]`, and every trace's hoisted prologue reloads its homes from `regs[]`.
So a child can reuse the parent's spill area and registers freely; the handoff is
pure memory. (This is the memory-handoff model; register-level coherence that skips
the flush+reload is the deferred "Later" step, measured first.)

**1. Trampoline owns the one C frame (P-A).** Replace the per-trace C prologue/
epilogue with a single shared trampoline, emitted once into the arena (or kept as a
Zig `naked`/asm stub):
```
trampoline(tags=rdi, payloads=rsi, result=rdx, entry=rcx):
    push rbx; push rbp; push r12; push r13; push r14; push r15   ; save ALL callee-saved once
    sub rsp, SPILL_MAX*8 (+align)                                  ; one generous shared spill area
    xor rbx, rbx                                                  ; chain-cumulative counter
    jmp rcx                                                       ; enter the first trace body
shared_exit:                                                       ; every final exit lands here
    ; result.completed / exit_instr / final_trace_id already written by the exiting body
    add rsp, SPILL_MAX*8 (+align); pop r15..r12; pop rbp; pop rbx; ret
```
`SPILL_MAX` is the max spill-slot count any compiled trace can use (a fixed bound;
today's allocator caps spills — pin a comptime `SPILL_MAX` and **bail compile** if a
trace exceeds it, exactly as we bail other unsupported shapes). The trampoline is
the C-callable entry; `CompiledTrace.run` calls `trampoline(tags,payloads,&result,
body_entry)`.

**2. Frameless bodies.** Each trace body drops its own `push`/`sub rsp`/`pop`/`ret`.
It uses `rbx` (counter), `r8–r15/rbp` (homes), `xmm2–15`, `rax/rcx` scratch, spills
at `[rsp+k*8]` in the *shared* frame. Homes are clobbered freely (trampoline saved
them). `.loop` is unchanged (local `jmp loop_top`). The hoisted prologue (type
checks + slot loads from `regs[]`) stays — it is exactly the child-entry reload.

**3. Link-slot indirect handoff (P-A/P-C) — no code patching in Increment 2.** Give
each compiled trace a small **link-slot table**: one writable 8-byte pointer per
*chainable exit* (each ordinary guard exit, the `.link` terminal, each linked-loop-
done exit — the P-C taxonomy). Each slot defaults to `&shared_exit`. An exit site
emits, after its `flushSlot`s + `result` writes:
```
    jmp qword [rip + link_slot_for_this_exit]     ; default target = shared_exit
```
So with all slots at their default, behaviour is byte-identical to today (flush →
write result → leave to the dispatcher via shared_exit → `ret`). When the
dispatcher's existing `driveChain` logic selects a native child `C` for parent `P`'s
exit `E`, instead of returning to re-enter `C` by C-ABI call, it **stores `C`'s
body-entry address into `P.link_slots[E]`** (a plain data write — no `mprotect`, W^X
untouched, since the slot is data, not code). The next time `P` fails guard `E` it
`jmp`s straight into `C`'s frameless body under the same frame. This is the native→
native handoff that removes the ~600 ns Zig round-trip, achieved without touching
the code pages. (Increment 3 upgrades the hottest of these from `jmp [slot]` to a
patched direct `rel32`, shaving the indirect-load; the slot table also *is* the
unpatch/lifetime handle for P-E.)

**4. Chain-wide result contract (P-B).** `NativeResult` describes one trace; a
chain needs the *final* trace's identity. Extend to:
```
ChainResult { completed: usize,        // cumulative rbx across the whole chain
              exit_instr: u32,          // exit index within the FINAL trace
              final_trace_id: u32,      // which trace performed the final exit
              linked_loop_done: u64 }
```
`rbx` already accumulates naturally (never reset on a link jmp). Each body's exit
sites write `exit_instr` **and** a compile-time-constant `final_trace_id` (the
trace's cache id, baked as an imm32) before `jmp [slot]`. The dispatcher then maps
`(final_trace_id, exit_instr) → resume PC` instead of assuming the entered trace.
This removes the `interp.zig:2584,2595` mis-attribution hazard.

**5. Per-exit-kind rules (P-C).** Three exit kinds, each already distinct in
`nativegen.zig`, get a link slot and the uniform `jmp [slot]` tail:
- ordinary guard exit (shared `deopt_exit` today, `:4051`) — one slot per guard `i`;
- `.link` terminal (`:3989`) — one slot (its natural successor is the linked trace);
- linked-loop-done (`emitLinkedLoopDoneSnapshot`, `:3115`; exit path `:4038`) — one
  slot per loop-done guard; the post-guard snapshot stores stay *before* the tail.
Prologue-fail (`:4065`) is **not** chainable (no child makes sense pre-first-
iteration): it writes completed=0, exit_instr=-1, and `jmp shared_exit` directly.

**6. Child eligibility + prologue-failure fallback (P-G).** A slot is only populated
for a child that is native (`.compiled`), has zero synthetic inputs
(`inputs.len==0`; `seedTraceInputs` handoff is not expressible through a bare jmp —
those children stay dispatcher-driven), and whose terminal shape is chainable. When
a populated child's own hoisted prologue guard fails (its entry types don't match
the handoff `regs[]`), that is just a normal guard exit *inside the child*: it
flushes, writes the child's `(final_trace_id, exit_instr)`, and `jmp`s the child's
own slot (default `shared_exit`) — the cumulative `rbx` is intact, so the dispatcher
resumes correctly at the child's guard PC. No parent-count loss, no sibling retry
needed (the dispatcher re-evaluates from the coherent resume PC as it does today).

**7. Determinism (P-F).** The in-mcode handoff *skips* the per-hop dispatcher
accounting that today runs between native traces: `onSideExit`, `hit_count`,
penalty/gate bumps, prime-side arming, lane-widen eviction (`interp.zig:2588,2605,
2763`). These steer *future* recording, so byte-identity is not automatic. Increment
2 keeps them correct by **only populating a link slot after the dispatcher has
already driven that transition enough times to have done its accounting** — i.e. the
slot is armed *by* `driveChain` at the same point it already commits to the chain, so
every accounting side effect that would happen up to arming still happens on the
dispatcher path; once armed, the transition is deterministic control flow between
semantically-equivalent traces whose committed values all round-trip through `regs[]`.
The obligation to discharge in code: prove (via the 10-mode matrix + keyframe/replay
goldens) that no *armed* slot changes which traces get recorded later. If any does,
the fallback is to replicate that specific counter on the trampoline's `shared_exit`
path (it has `final_trace_id` to attribute correctly). Link slots are reset to
`&shared_exit` on any event that would invalidate the child (retire, flush) — which
is also the P-E lifetime hook.

**Sub-stepping (each behind `just test`, byte-identical gate):**
- 2.1 Trampoline + frameless bodies, **all exits pinned to `shared_exit`** (pure
  ABI move; no linking; behaviour byte-identical — this de-risks the frame change
  in isolation). **LANDED** — see the Done bullet above. Refinement made while
  coding: 2.1 emits a *direct* absolute `movabs rax, shared_exit; jmp rax` at each
  exit rather than the indirect `jmp [slot]` of the final design. With no slots
  armed yet the two are behaviourally identical, and the direct form needs no
  per-trace slot table; 2.3 replaces it with the indirect `jmp [slot]` handoff
  (slot default = `shared_exit`) when link population arrives. The trampoline lives
  as a permanent, never-freed `McodeArena` slot (`ensureTrampoline`, emitted once);
  the test path (`compile`, `arena == null`) keeps the self-framed ABI, giving a
  built-in A/B of both ABIs over the same lowered trace.
- 2.2 `ChainResult` (P-B) + dispatcher `(final_trace_id,exit_instr)→PC` mapping,
  still no linking. Byte-identical.
- 2.3 Link-slot population from `driveChain` for `.link` first (simplest kind),
  then guard + loop-done (P-C/P-G). nsieve A/B + matrix.
- 2.4 P-F verification pass; replicate any counter proven live.

##### Peer-review corrections (gpt-5.6-sol, 2026-07-11) — fold in BEFORE coding

The review confirmed the pure-memory handoff premise (point A) is sound —
ordinary deopt flushes carried slots (`nativegen.zig:4051`), write-only slots
commit at each back-edge (`:3940`), invariant slots stay in `regs[]`, `.link`
snapshots every slot (`:3989`), and child entry reconstructs *all* homes incl.
hoisted array base pointers (`:3306`) and preheader/phi init (`:4008`). No
child-visible value survives only in a parent register/spill. **But three
showstoppers + several load-bearing fixes must land first:**

- **SHOWSTOPPER 1 — loop-done dual materialization.** A loop-done guard has two
  incompatible state contracts: ordinary deopt (do *not* commit the final
  iteration; resume at the header) vs. linked completion (commit post-guard stores
  + phi snapshot, enter continuation). Today the guard picks via
  `NativeResult.linked_loop_done` (`:4024,:4030,:4042`). Point 5's "snapshot stays
  before the tail" is WRONG: with the slot defaulting to `shared_exit`, the default
  path would commit the final iteration and return as an ordinary deopt → tier-0
  replays it → duplicated stores / mis-advanced for-state. **Fix:** the indirection
  must select *before* materialization — default slot → ordinary-deopt stub (no
  final-iteration snapshot); armed slot → an exit-specific linked-materialization
  stub that snapshots *then* jumps to the child. A slot pointing straight at the
  child cannot choose between the two contracts.
- **SHOWSTOPPER 2 — dangling code links (P-E is NOT deferrable to Increment 3).**
  `removeTrace`→`destroy` frees the child's arena slot to the reuse free-list
  (`trace.zig:1757,1761`→`622`→`nativegen.zig:294`); a later compile overwrites it
  (`:254`). A parent slot still pointing there is a code-use-after-free, and
  **widen-eviction makes this reachable in normal operation** (`interp.zig:2767`),
  not just shutdown. **Fix (required as soon as slots exist):** inbound-link
  ownership — backlinks reset before destroy, or link refcount blocking removal, or
  generation-checked indirection through a stable link object. "Dead code happens to
  stay readable" is insufficient under arena reuse.
- **SHOWSTOPPER 3 — child prologue-fail vs. cumulative counter.** Point 6 (cumulative
  `rbx` intact) contradicts point 5 (prologue-fail writes `completed=0`, `:4065`).
  After a productive parent→child jump where the child's entry guard fails, writing
  zero loses committed progress, triggers the zero-yield penalty path, and can spur
  bogus sibling retries. **Fix:** child prologue-fail must write cumulative progress
  + `final_trace_id=child` + a *distinct* reason (`prologue_fail`), never an
  overloaded `exit_instr=-1`. The dispatcher must treat "final child committed zero
  *locally*" and "chain committed nonzero *globally*" as two separate facts.
- **MUST-FIX — `completed` is not raw cumulative `rbx`.** Nested chaining rolls up as
  `linked_completed += 1` per inner run (one inner run = one enclosing iteration),
  NOT the sum of raw inner iterations (`trace.zig:1387,1391`). `completed` drives
  useful/low-yield classification, `hit_count`, penalty/gate (`:1132,1140,1145`),
  zero-guard counting (`interp.zig:2588`), and arming (`:2605`). So `ChainResult`
  needs *separate* fields: final-trace **local** commits, enclosing-chain progress,
  and the final exit reason/identity — cumulative `rbx` is at most diagnostic. (No
  dispatcher PC-advance is proportional to `completed`; resume PC is separate.)
- **MUST-FIX — all exit consumers need the FINAL trace, not just PC lookup.** The
  dispatcher indexes `ct.instrs[result.exit_instr]` in guard-failure lookup
  (`interp.zig:2595`), `maybeArmContinuation` (`:2616`), productive-branch counting
  (`:2626`), source-branch discrimination (`:2730`), and `onSideExit(ct,…)` (`:2607`).
  Feeding the entered *parent* with the child's exit index is OOB / misclassifies.
  Every one must switch to the final trace + its local count.
- **MUST-FIX — stable trace identity.** The only id today is the cache index from a
  `cache.items` scan (`trace.zig:1113`), and `removeTrace` uses `swapRemove`
  (`:1761`) so indices are reassigned. A baked-imm32 `final_trace_id` goes stale
  after any eviction. Add a never-reassigned runtime id to `Trace` + a lookup table,
  valid ≥ as long as any mcode link can reference it.
- **MUST-FIX — stack alignment.** At C entry `rsp%16==8`; 6 pushes keep `%16==8`;
  the callout helper assumes body `rsp%16==8` and subtracts 8 before `call`
  (`nativegen.zig:2981`). The shared frame reservation must be rounded to a multiple
  of 16 (not merely `SPILL_MAX*8`) and must include the callout-save region in the
  max (`:2273,2305`), else an odd `SPILL_MAX` breaks the SysV call alignment.
- **MUST-FIX — slot reachability + W^X.** `jmp qword [rip+disp32]` only reaches
  ±2 GiB; a heap side-table has no such guarantee, and slots embedded in an RX arena
  region can't take "plain data writes" without a RW toggle (`:215`). **Fix:** put
  slots in a separate *nearby RW page*, or load the slot address as a full imm64 and
  `jmp qword [rax]` (absolute — no rel32 constraint; `rax` is scratch post-flush).
  The target pointer itself may be anywhere (loaded as imm64); only code→slot
  addressing is constrained.
- **MUST-FIX — safepoint/observation blackout.** `driveChain` caps a burst at 8 hops
  (`trace.zig:1315`); an mcode continuation↔inner-root cycle removes that bound and
  can run an entire enclosing loop without returning, expanding the safepoint/GC/
  suspend/replay-line blackout (`interp.zig:1643,1668`) from one loop to an arbitrary
  nested computation. **Fix:** when `suspend_ctl`, replay-line recording, exec-log,
  or any observation hook is active, leave slots unarmed / reset to the dispatcher
  (no mcode poll in Increment 2).
- **Terminology:** `body_entry` = the child's guards/reloads/preheader, **not**
  `loop_top`.
- **Nits:** aligned 8-byte slot writes need no icache flush (single-thread, data);
  the trampoline need not save XMMs (caller-saved); `rdi/rsi/rdx` stay live through
  bodies because the callout restores them; CET/IBT would need landing pads at body
  entries only if ever built with enforcement (not a current constraint).

**P-F contract — DECIDED (Bart, 2026-07-11): replicate-but-inert.** Native
link-slots make tiering metadata (`hit_count`/penalty/gate, recording set) diverge
between native and tier-1a modes; it does not change stdout (the C5 contract already
permits different trace *sets* per mode) but it does make internal counters / trace
dumps mode-dependent. Rather than relax the contract *or* pay the accounting cost
always, the chain carries a **per-hop transition record that is gated by a config
flag** (parallel to `record_exec_log`): when the flag is on (the 10-mode matrix /
determinism goldens), `shared_exit` replays the per-hop accounting the dispatcher
would have done — attributed via `final_trace_id` — so tests assert byte-identical
tiering metadata across modes; when off (production `--jit-native`), the transition
record and replay are skipped entirely, so the mcode handoff stays cheap. "Test
equivalence while not paying the cost when not relevant."

### Increment 2.3c — fused-transition contract (root receipt, top-level drain, materialization)

**Status: M1 implemented (2026-07-13, Increment 2.3c-1); M2 ledger PROMOTED into 2.3c-2
(2026-07-13, sub-steps 2.3c-2a = ABI + emission and 2.3c-2b = call-B replay path landed;
2.3c-2c = cycle-closing arm + cap remains).** This section is
the contract for 2.3c-1/2.3c-2 arming, written after a codex gpt-5.6-sol pre-
implementation contract review (2026-07-13) found the one-line 2.3c-1 scope ("arm
skip→prime-side") incoherent as stated. It supersedes the terse Outstanding bullets
below. The M1 half-fusion path (recognizer `fusedSourceBranchLinkSlot` on armed-edge
provenance, `runLinkedBurst` extraction, dispatcher fused-`.link` consumer) landed as
2.3c-1. **CORRECTION (2026-07-13):** the earlier verdict that M2's per-hop ledger was
"rejected/deferred, nothing on the roadmap needs it" was overturned when 2.3c-2's
inner→continuation arming was scoped — with BOTH `C.link→I.linked_entry` (2.3b-1) and
`I.loopdone→C.ordinary_entry` (2.3c-2c) armed, one trampoline entry runs a closed
`C→I→C→I…` cycle returning ONE `NativeResult` whose scalar fields describe only the
TERMINAL hop (each body entry overwrites `entry_rbx`, each exit overwrites
`final_trace_id`), so the intermediate hops are unrecoverable from scalars and the
dispatcher drain cannot account them. The M2 per-transition ledger is therefore
PROMOTED and is being built inside 2.3c-2 as parallel arrays on `NativeResult`
(`ledger_cum`/`ledger_id`/`ledger_exit`/`ledger_reason`, `LEDGER_CAP`), appended by
every native exit site and replayed by `runLinkedBurst`. 2.3c-2 (loop-done
inner→continuation) is still Outstanding; sub-step 2.3c-2a (ledger ABI + emission +
terminal-consistency assert, no accounting change) has landed byte-identical.

#### The blocker the review found

The "prime-side" is not a loop root — it is a `.link` **entry ramp** anchored at
the outer header (recorded by the 2D prime-side machinery: `guard_true(p[i]) →
inner for_prep → link`). It has no numeric-for back-edge of its own. In the unarmed
steady state (`driveChain`, trace.zig:1380) the ramp is `snt.run`, returns at its
`.link` terminal, and `driveChain` then runs the inner root and — only after the
ramp→continuation swap (trace.zig:1542) — arms the *continuation's* `.link`, never
the ramp's. So today nothing fuses the ramp into the inner.

If 2.3c-1 arms `skip.guard → prime_side.ordinary_entry` and nothing else, the fused
native call is:

```
skip ordinary source-branch guard
  → prime_side.ordinary_entry → prime_side body → prime_side .link terminal
  → shared_exit          (the ramp's .link slot is unarmed)
```

The final body is the **ramp**, exiting at its `.link` (`final_trace_id =
prime_side.id`, `exit_instr = ramp .link index`), with `local_completed == 0` (no
back-edge). But that `.link` terminal has already flushed the register snapshot its
inner root expects (nativegen `emitLinkedLoopDoneSnapshot`/link flush) — regs are
coherent at the **inner-loop PC**, not the outer header. The dispatcher has **no
top-level `.link`-terminal consumer**: it sees `local_done == 0`, calls
`onSideExit(prime_side, 0)` (interp.zig:2858), and drives `.ordinary_header` off
`prime_side.anchor.pc` (the outer header) — a **semantic misresume** that can re-run
the prime iteration from the wrong coherent PC. This is a correctness bug, not
merely divergent steering.

The review's three corollary findings:
- **`final` cannot reproduce hidden root/intermediate events.** `NativeResult`
  (nativegen.zig:568) keeps only the *final* body's `{final_trace_id, entry_rbx,
  completed, exit_instr, exit_reason}`; every child body overwrites `entry_rbx` and
  every exit overwrites `final_trace_id`. Once a top-level run fuses, the dispatcher
  cannot recover the root's exit identity or the intermediate `.link`/loop-follow
  events. The **load-bearing** missing event is `onSideExit(skip, skip_local)` —
  it drives `hit_count`/penalty/gate (trace.zig:~1225), and tier-1a/unarmed native
  still perform it, so dropping it only under patched native violates P-F.
- **`ran_native_link_mode` misroutes once fused.** It is computed from `ct`
  (interp.zig:2592) but consumed against `final` (interp.zig:2781). A fused
  `final ≠ ct` reads the wrong entry-mode fact.
- **Arm needs `failed: *Trace`** (currently `*const`); `ordinary_entry` is the
  correct robust target (clears the inherited `linked_loop_done`).

#### Two mechanisms

**M1 — half-fusion + top-level `.link` consumer (RECOMMENDED).** Arm ONLY
`skip.guard → prime_side.ordinary_entry`; leave `ramp.link → inner` a `driveChain`
Zig hop. Because the ramp commits zero of its own iterations, the fused result is
trivially decodable with **no new `NativeResult` field**:

```
result.completed == result.entry_rbx == skip_local   (ramp local_completed == 0)
final == prime_side, exit_instr == ramp's .link terminal index
```

i.e. the root's own committed count is `result.completed` directly. The dispatcher
gains ONE new branch — a *fused top-level `.link`-terminal consumer* — that:
  1. replays the root's productive-exit steering on `ct` (skip): `onSideExit(ct,
     skip_local)`, and *asserts* the two remaining productive-exit hooks inert for
     this exit shape (`maybeArmContinuation` is statically a no-op on a source-branch
     guard; `countProductiveBranchExit` returns early once `countTracesAt(anchor) ≥
     2`, i.e. once the prime-side coexists — trace.zig:~1962); then
  2. continues the burst by handing the already-run ramp result to a `driveChain`
     entry variant seeded with `(current_link = prime_side, sresult = the fused
     result)` that runs the inner root and drives continuation⇄inner exactly as the
     unarmed path does *after* `snt.run(ramp)` — WITHOUT re-running the ramp (which
     would re-do its `for_prep`).

**Recognizer — provenance, not opcode (codex 2026-07-13 re-review BLOCKER).** The
first-pass recognizer `final ≠ ct ∧ final.instrs[exit_instr].op == .link` is unsafe
on two counts, both confirmed against the tree:
  - **OOB on fused prologue failure.** A fused child that fails its entry guard sets
    `exit_instr == maxInt(u32)` with `exit_reason ≠ .normal` (nativegen.zig:~4406),
    so `final.instrs[exit_instr]` indexes out of bounds. Any recognizer MUST first
    gate `exit_reason == .normal ∧ exit_instr < final.instrs.len`.
  - **False positive once 2.3c-2 lands.** After 2.3c-2 *persistently* arms the
    inner→continuation loop-done slot, the dispatcher can enter the inner root
    directly in linked-loop-done mode (`hasNativeLoopDoneLink(ct, proto)` →
    `runLinkedLoopDone`, interp.zig:~2590) and the fused native run then returns
    `ct = inner root`, `final = continuation`, `final ≠ ct`,
    `final[exit_instr].op == .link` — satisfying the opcode recognizer but NOT a
    skip→ramp receipt. (So the earlier "2.3c-2 is purely internal to `driveChain`"
    claim is only true for the *arming*; the persistently-armed inner is also
    reachable as a top-level `final`.)

  The fix is to discriminate on **armed-edge provenance** via the P-E backlink
  registry (`armed_links: {parent, slot_index, child}`, trace.zig:~868), not on the
  final opcode. The consumer fires only when there is an armed record with
  `parent == ct ∧ child == final ∧ slot_index` a *source-branch* guard of `ct`
  (`isSourceBranchGuardExit`), plus the bounds/`.normal` gate and
  `final.anchor == ct.anchor` as a corroborating shape assert. That cleanly separates
  the 2.3c-1 `.ordinary_guard` skip→ramp edge from the 2.3c-2 `.loop_done_linked`
  inner→continuation edge with no new `NativeResult` field.

**Seed helper — consume a `current_link`-owned `.link`, do NOT reuse `fused_inner`
(codex SHOULD-FIX).** In `driveChain`, `fused_inner = sresult` means the result
already belongs to an *inner* root and is resolved through `isInnerLoopRoot`
(trace.zig:~1426/1463); seeding it with the *ramp* receipt would panic/misclassify.
The seeded entry variant must instead enter at the existing `.link`-recognition point
(trace.zig:~1390) as "a verified `current_link`-owned `.link` receipt" — i.e. take
the same path `snt.run(ramp)`'s own `.link` result takes, deriving `resume_pc` from
`.link.aux` and calling `runLinkedLoopDone(regs)`. Its `.link` contract is
non-nullable and every return continues the burst (never falls through into the
`local_done` numeric-for-done split).

M1 sidesteps all three corollary findings: the receipt is `result.completed` (no
ledger, no new field); `ran_native_link_mode` is untouched (the fused `.link` result
takes its own dispatcher branch, not the `.native_numeric_for_done` path); and the
only P-F obligation is the single `onSideExit(ct, skip_local)` replay plus two
asserted-inert hooks. The perf it buys is removing the skip→prime-side Zig re-entry
per prime; consistent with 2.3b-1, expect this to be ~neutral on nsieve's tiny
clusters — its value is completing native chain coverage and de-risking Increment 3,
not a standalone speedup (state that honestly in the verify step).

**M2 — full single-call skip→prime-side→inner fusion (REJECTED for 2.3c-1).** Dual-
arm (`skip.guard → prime_side.ordinary_entry` AND `ramp.link → inner.linked_entry`)
so one native call spans skip→ramp→inner. This resurrects every problem M1 avoids:
the inner's loop-follow + the ramp's `.link` events happen *inside* native code and
are invisible to the dispatcher, so reproducing them needs the **gated per-hop
transition ledger** floated in the P-F contract note above — a bounded
`[N]{trace_id, local_completed, exit_reason}` array in `NativeResult`, replayed by
`shared_exit` under the determinism flag. That ledger is real, but nothing on the
2.3c roadmap *needs* the single-call span: M1 already makes skip→prime-side native,
and the ramp→inner hop is one `driveChain` call the ledger would only collapse, not
eliminate. Per the same "do-it-right-now" discipline that rejected `(index,kind)`
slot keying in P-C, M2's ledger is deferred until a hop actually appears whose
intermediate events cannot be decoded from `{root_completed, final_result}` — at
which point the P-F-note ledger is the sanctioned mechanism.

> **CORRECTION (2026-07-13).** The parenthetical that stood here — "2.3c-2's
> inner→continuation fusion is *internal* to `driveChain`, drained hop-by-hop exactly
> as 2.3b-1's — it introduces no new top-level fusion, so it does not need M2 either" —
> was **WRONG**, and 2.3c-2 is exactly the hop the deferral clause above anticipated.
> Arming `I.loopdone → C` on top of the already-live `C.link → I` (2.3b-1) closes a
> CLOSED native cycle: one trampoline entry runs `C→I→C→I→…` and returns a single
> `NativeResult` whose scalar fields describe only the terminal body. The intermediate
> `C` and `I` transitions are NOT drained hop-by-hop — the drain never re-enters Zig
> between them, so `{root_completed, final_result}` cannot decode them. This is precisely
> "a hop whose intermediate events cannot be decoded," so the M2 ledger is now the
> sanctioned mechanism and is PROMOTED into 2.3c-2 (see §Implementation status →
> Increment 2.3c-2; landed 2.3c-2a = the ledger ABI + emission). What actually differs
> from the P-F-note sketch: the ledger is realized as **parallel arrays** (`ledger_cum`
> scale-8, `ledger_id`/`ledger_exit`/`ledger_reason` scale-4) rather than an AoS, so each
> lane is a single native SIB store with no ×stride multiply; it is appended by every
> exit site (not only `shared_exit`); and it is replayed by `runLinkedBurst` on return
> (not by `shared_exit` in native code). The determinism-flag gating still applies via
> the `safe_to_arm`/`disarmAllLinks` path that keeps a cycle from forming during an
> observation window.)

#### What 2.3c-1 and 2.3c-2 actually share

Less than the first pass feared, once 2.3c-1 is M1:
- `ordinary_entry` target + the `.ordinary_guard`/`ArmKind` P-C enforcement
  (already built, 2.3c-0a/0c) — both increments arm into `ordinary_entry`.
- `armNativeLink` taking `parent: *Trace` (the const→mutable change) + P-E backlink
  reset on retire (already built; exercised for guard slots the first time here).
- disarm-on-unsafe (2.3c-0e) becomes load-bearing only at 2.3c-2 (the cycle-closer);
  2.3c-1's skip→prime-side is acyclic (the burst always yields to the dispatcher; the
  skip trace is re-entered by the hotcount, never by a native handoff), so 2.3c-1 does
  not depend on it.

The materialization-discriminator idea (an explicit `ExecResult` field stamping
whether the final exit ran linked vs ordinary) is **not required by M1** and is
folded into M2's deferred ledger; recorded here so it is not re-discovered.

### Increment 3 — Close the branchy-loop region, then patch (P-E)

Increment 3 is **two sequenced parts in one arc** (Bart's call, 2026-07-17), because
the profiling below shows the doc's original framing — "port `lj_asm_patchexit`,
shave the indirect `jmp [slot]` load" — is *not* what moves nsieve. The indirect
load is not the wall; the **open branch-loop region** is. So Part A closes the
region (the payoff), and Part B does the faithful rel32 mechanism port + the real
in-place-patch lifetime hardening (the polish the doc's title names). One reviewer
pass covers the whole arc.

#### Evidence: the gate, not codegen, owns nsieve (2026-07-17, `--jit-stats`)

nsieve `9`, ReleaseFast, per-anchor split (`--jit-native --jit-stats`):

| anchor    | role                              | run% wall | trc% of its iters |
|-----------|-----------------------------------|----------:|------------------:|
| nsieve:4  | init `for i=2,m do p[i]=true end`  |    28.0%  |            57.1%  |
| nsieve:14 | **outer scan `if p[i]` skip loop** |  **59.4%**|          **5.0%** |
| nsieve:24 | inner sieve `for k=i+i,m,i`        |    11.6%  |            96.2%  |

nsieve:14 is 59% of the run and **95% of its iterations fall back to tier-0 despite
having a compiled trace** — it is *gated* (`onSideExit` → `max_penalty`,
trace.zig:1550/1578). Root cause: the outer loop's `if p[i]` splits into a
composite-run skip trace (nsieve:14, `%012 guard_false`) and a prime-handling
continuation (nsieve:29, terminating `link -> 24`). The prime excursion fuses
natively today (edges 1–3 below are armed: `source fused=40288`,
`loopdone fused=55826`), but the **return edge — continuation → skip trace across
the composite gap — is not armed**, so every prime returns to the Zig dispatcher,
re-enters the skip trace through the gate, and the dense early primes (gaps < 8 =
`min_useful`) drive the penalty to `max_penalty` and gate the anchor.

**Decisive A/B (throwaway `max_penalty = 1e9`, reverted):** disabling the gate lifts
nsieve:14 from **5.0% → 92.8%** traced — confirming the gate *is* the fallback cause
— **but wall time barely moves (546 ms → 539 ms, ~1%).** Running the outer loop as a
trace without closing the region does not help, because it still re-enters Zig ~twice
per prime (~600 ns/hop, doc 16 §nsieve). **The wall is per-transition re-entry, not
codegen.** That is the whole design in one measurement: coverage without region
closure is worthless; the lever is eliminating the per-prime re-entry (Part A), and
the residual indirect-load shave (Part B) is second-order.

#### The four edges of the branchy loop

nsieve's `for i=2,m do if p[i] then for k=i+i,m,i do p[k]=false end; count=count+1 end end`
compiles to a cycle of four native transitions (anchors are **bytecode PCs**):

| # | edge                                                        | armed by            |
|---|-------------------------------------------------------------|---------------------|
| 1 | `skip(14).guard_false → prime-side ramp.ordinary_entry`      | M1 / 2.3c-1         |
| 2 | `ramp/cont(29).link → inner(24).linked_entry`               | 2.3b-1              |
| 3 | `inner(24).loopdone → cont(29).ordinary_entry`              | 2.3c-2c             |
| 4 | **`cont(29).guard_true-fail (composite) → skip(14).ordinary_entry`** | **Part A (new)** |

Edges 1–3 are live (confirmed via `--jit-debug`: e.g. `arm parent id=1 pc=24 slot=19
-> child id=2 pc=29 kind=loop_done_linked`). Edge 4 is the mirror of edge 1: M1
(2.3c-1) arms a source-branch guard (`skip.guard_false`, "this i is prime") into a
child's `ordinary_entry`; edge 4 arms the *opposite* source-branch guard
(`cont.guard_true` failing = "the next i is composite") into the skip trace's
`ordinary_entry`. Same P-C taxonomy (`isSourceBranchGuardExit` → `ordinary_entry`,
`inputs.len == 0`), same `armNativeLink` machinery — a *different failed-trace/child
pairing* than the two existing M1 arm sites (trace.zig:1738/1800) reach.

#### Part A — Arm edge 4: close the region, escape the gate

Arm `cont(29)`'s composite source-branch guard slot → `skip(14).ordinary_entry`
(reusing the 2.3c-1 `.ordinary_guard` `ArmKind`, the `ordinary_entry` target from
2.3c-0c, and the P-E backlink registry). With all four edges armed, one trampoline
entry runs `skip →[prime] ramp → inner → cont →[composite] skip → …` as **one
sustained native region**, bounded only by the `LEDGER_CAP = 32` forced-yield cap
(`emitForcedYieldCheck`, nativegen.zig:3347) — not by a per-prime Zig round-trip.

Why this escapes the gate: the fused-burst drain (`replayLedger`, 2c-C) already bills
every hop's `onSideExit` against **its own anchor** with **its own local count**
(trace.zig:1552 comment; 2.3c-2b/2c parity). Once edge 4 fuses, a single burst's
skip segments commit the *summed* composite count across up to ~8–16 primes before
yielding — comfortably ≥ `min_useful = 8` in both the dense head (≈16 primes/burst)
and the sparse tail (one composite run alone exceeds 8) — so `onSideExit(nsieve:14,
…)` clears the penalty instead of bumping it, and the anchor **never gates**. No
change to the gate constants; the fix is upstream of them.

**Correctness questions this raises (for review — these are where 2.3c-1's review
found the real blockers):**

- **P-A/edge-4 coherence.** Does `cont(29)`'s composite-guard exit leave `regs[]`
  coherent at `skip(14)`'s outer-header anchor? `cont` runs the outer back-edge
  (`i = i + step; guard i ≤ m`) *before* its `if p[i]` guard, so at the composite
  exit `i` is already the next value and `m`/`p`/`count` are set — this *should* match
  the skip trace's `entry=[r4 r0 r6 r3 r5]` header state, but it is the exact class of
  claim 2.3c-1's review overturned (the ramp landed regs at the inner PC, not the
  header). Must be proven, not assumed, before arming.
- **`LEDGER_CAP` sufficiency + the composite-gap yield hole.** Each prime appends
  ~2–3 ledger entries (skip→ramp guard, ramp→inner `.link`, inner→cont loop-done);
  the cont→skip hop adds a 4th kind. `LEDGER_CAP = 32` must bound a full burst — but
  note the **skip trace's own composite back-edges (`%023 loop`) do *not* append to
  the ledger**, so in the sparse tail a burst can run *millions* of composite
  back-edges between two ledger appends with **no forced yield**. Is there a
  back-edge interrupt/suspend check on the native numeric-for loop path, or does edge
  4 create an unbounded no-safe-point region (a suspend/interrupt-responsiveness and
  P-EBP-4 safe-point hazard)? This is the sharpest open question.
- **Cycle vs. the observation window (2.3c-0e / P-F).** Edge 4 makes the outer loop a
  *second* persistent native cycle (alongside `cont↔inner`). `safe_to_arm` must gate
  the new arm, and `disarmAllLinks`/`resetLinksTouching` must cover edge 4, so an
  active safepoint/replay window still collapses it (same load-bearing disarm test as
  2c-F).
- **P-EBP-1/2 determinism.** The drain must reproduce edge 4's `onSideExit` order and
  the skip-anchor accounting exactly across the 10-mode matrix; the newly-non-gated
  nsieve:14 must not change *which* later traces record (it changes only where its own
  iterations run).

Expected payoff (hypothesis to measure, not a promise): Part A converts nsieve:14's
59% from gated-tier-0 to sustained-native, removing the ~2 re-entries/prime the A/B
exposed as the wall. Report the honest before/after; do not proclaim success.

#### Part B — Faithful `lj_asm_patchexit` port + in-place-patch lifetime (P-E)

With the edge set complete (Part A) and co-location (Increment 1 arena, rel32 always
reaches) + frameless bodies (Increment 2.1, a mid-chain `jmp` is legal), port
`lj_asm_patchexit` (`lj_asm_x86.h:3127`): upgrade the hottest armed exits from the
indirect `jmp qword [&slot]` (2.3a) to a **patched direct `jmp rel32`** rewritten in
place, shaving the memory load per transition. The slot table stays as the fallback
and the P-E handle; patching is a hot-path specialization over it.

- **P-E becomes load-bearing here.** Today `resetLinksTouching` restores a *slot cell*
  on retire (2.3a); an in-place rel32 patch means retiring a child must **re-patch the
  parent's mcode** back to the shared-exit rel32 (or to the slot indirect), inside an
  `mprotect(RW)` window — mirror LuaJIT's `lj_mcode_patch` RW/RX bracket
  (`lj_mcode.c:416`) and its deliberate stack-check/GC-exit skip (`lj_asm_x86.h:3153`).
- **P-EBP-4 safe point.** Patching runs in the dispatcher after the native call
  returned (no live parent activation), but `mprotect(RW)` makes the page briefly
  non-executable and lune does not align jump operands (`x64.zig:852`) — so the safety
  argument is the safe point, not an aligned atomic store. Identify any reentrant JIT
  path (native callback / host hook) that violates it.
- **Measure-gated.** The A/B above says the indirect load is second-order once the
  region is closed. Part B lands only if post-Part-A component timings show the
  `jmp [slot]` load is a measurable fraction; otherwise it is the faithful-port
  completion + the P-E hardening that in-place patching *requires the moment it
  exists*, and its speed claim is explicitly "measure, don't assume."

#### Review outcome — codex `gpt-5.6-sol`, 2026-07-17 (pre-impl): BLOCKER

A pre-implementation review found the two central Part A claims **unsound as
written**, plus concrete Part B gaps. The Part A/B text above is kept as the
historical first framing; the corrections below supersede it and are the real work.

- **[BLOCKER] Edge-4 coherence.** The Part A "should match the header state" claim is
  wrong. `cont(29)`'s composite guard is an *ordinary* deopt that flushes only carried
  homes and is coherent at `cont`'s OWN anchor (trace.zig:1648, nativegen.zig:4598) —
  it has **not** committed the outer-back-edge phis (`count+1`, next `i`; committed only
  at `.link`, nativegen.zig:4502). Jumping to `skip(14).ordinary_entry` makes skip read
  **stale `i`/count**. Edge 4 cannot reuse `.ordinary_guard`; it needs its own
  materialization contract (distinct `ArmKind` + ledger kind + exit stub + replay rule)
  that commits the continuation's outer-back-edge phis before entering skip — closer to
  a `.link`/linked-loop-done materialization than to a source-branch guard.
- **[BLOCKER] The gate-clear arithmetic does not hold under the current drain.**
  `replayLedger` bills each ledger entry a *local* delta (`e.cum − prev_cum`) and calls
  `onSideExit(owner, local)` **per segment** (trace.zig:1972/1996/2162) — it does NOT
  sum a burst's skip segments. So 16 dense short gaps stay 16 low-yield
  `onSideExit(skip, 1..3)` events, and "never gates" is **not established** (a run of
  eight short gaps still gates). Region closure buys native execution but, on the
  existing accounting, **does not by itself un-gate the anchor.** Two further hard
  failures on the reused path: the fused-M1 grammar requires parent+child share an
  anchor (trace.zig:3098) — `cont(29)→skip(14)` is cross-anchor and fails provenance;
  and non-last `.deopt` replay assumes a zero-progress successor with equal cumulative
  counters (trace.zig:2154) → a skip successor advancing `rbx` **panics** (2159). Edge
  4 needs a new replay grammar regardless.
  - **The real fork (Bart's call, P-EBP-2-bound).** Either (a) **preserve per-segment
    accounting** and rely on the fact that an armed edge-4 handoff enters
    `skip.ordinary_entry` *natively, bypassing the dispatcher's `isGated` entry check* —
    so the region can keep running even while the anchor is nominally gated — then
    **measure** whether gating still matters for wall-time; or (b) introduce
    **region-level accounting** (one aggregated `onSideExit` per region-burst) applied
    **consistently across native, tier-1a, and unlinked paths**, accepting it as a
    deterministic heuristic redesign rather than "exact replay parity." (a) is smaller
    and keeps P-EBP-2 trivially; (b) is what makes the gate genuinely go away but must
    be proven mode-invariant. This choice is NOT mine to make — it changes the
    determinism contract.
- **[APPROVE-WITH-CHANGES] No-yield hole.** Confirmed: no native back-edge
  suspend/interrupt/yield check (nativegen.zig:4453/4499); `LEDGER_CAP` bounds
  *cross-trace exits*, not iterations — the doc's "LEDGER_CAP-bounded region" is
  corrected below. Not a *current* correctness break: suspend is pre-armed not async
  (interp.zig:1716/1654) and `safe_to_arm==false` disarms all persistent links before
  native entry (interp.zig:2632). The doc must state LEDGER_CAP bounds exits only, that
  suspend is pre-armed, and must make a native back-edge poll a prerequisite *if* async
  interrupts / bounded latency are ever required.
- **[SOUND, conditional] Lifetime for slot-based 3A.** The identity-based registry
  (`armNativeLink`/`resetLinksTouching`/`disarmAllLinks`, trace.zig:3234/3335/3368;
  epoch disarm interp.zig:997) covers a correctly-registered edge 4 — *provided* the
  new arm is `safe_to_arm`-gated, all writes go through `armNativeLink`, and a 2c-F-style
  test runs with **both** persistent cycles live plus negative controls.
- **[BLOCKER] Part B specifics.** (1) **Discovery:** `driveChain(.ordinary_header)`
  walks `failed.anchor.pc` (trace.zig:1647), so a cont anchored at 29 never discovers a
  skip anchored at 14 — Part A needs a defined, validated cross-anchor PC mapping, not
  "a different pairing." (2) **A raw rel32 child jump bypasses the forced-yield cap** —
  `emitForcedYieldCheck` may rewrite the armed target in `rax` to `shared_exit`
  (nativegen.zig:3255/3347); an unconditional rel32 ignores that redirect and lets a
  closed cycle overflow the ledger indefinitely. Part B must keep the cap load-bearing
  ("ledger-full → shared exit; else fall through to the patchable rel32"). (3) **No
  per-exit patch point for ordinary guards** — every guard's mini-stub converges on one
  shared `deopt_exit` *after* the carried-home flush (nativegen.zig:4543/4598); patching
  the guard directly skips materialization, patching the shared tail can't select a
  per-exit child. Needs per-exit post-flush tails / duplicated flush stubs / near
  trampolines. (4) **rel32 reachability is NOT guaranteed** — `McodeArena` maps regions
  with unconstrained `mmap(null,…)` and defers cross-region reachability
  (nativegen.zig:175/296); "co-location means rel32 always reaches" is false. Every
  patch needs a checked signed-32 displacement + near-trampoline/fail-closed fallback.
  (5) **P-E must track patches** (parent mcode identity, patch offset/encoding, current
  child, restore form), not just slot cells. (6) whole-region 1 MiB W^X is broader than
  the parent; state the single-threaded / no-native-active invariant and prove no host
  callback re-enters JIT code during the patch window.

Corrected phrasing carried into the design: "`LEDGER_CAP`-bounded native region"
means **bounded in cross-trace transitions, not iterations** — a same-trace composite
loop runs unbounded between appends. The Part A "summed composite count ≥ min_useful"
mechanism is **retracted**; whether region closure un-gates the anchor is now an
open measurement under fork (a), or a deliberate accounting redesign under fork (b).

#### Review outcome — Antigravity (gemini-3.1-pro), 2026-07-17: confirms both blockers

An independent second review **agreed with both blockers** (coherence: needs a
compiler-generated bridge stub that shuffles registers + materializes the phis to
`SKIP`'s entry contract — a direct `jmp` cannot; accounting: per-segment
`onSideExit` on 1–3-length gaps gates `SKIP` almost instantly). It added three points
the codex pass did not:

- **A third accounting option — exempt armed edges from the penalty.** "Bumping a
  *deopt* penalty for a transition that successfully stayed in native code is a logical
  contradiction." The penalty exists to brake interpreter-fallback thrash; an armed
  native→native hop is not a fallback. So beyond codex's fork (a)/(b), option **(c):
  when a segment's exit was taken via an armed link (stayed native), do not bump the
  anchor penalty at all** — arguably the most principled, and narrower than a full
  region-accounting redesign. Still P-EBP-2-relevant (it changes `onSideExit`'s future
  steering), so it remains Bart's call, but it is the cleanest of the three.
- **Disagreement with the "armed entry bypasses the gate → gate is moot for wall-time"
  optimism (fork a's premise).** Correct reconciliation: an armed edge bypasses
  `isGated` **only mid-burst**; every burst **start and every re-entry after a
  `LEDGER_CAP` forced yield** still transitions tier-0→native through the gated entry
  check. So a gated anchor still throttles the region to ~32-transition spurts
  separated by gated tier-0 stretches (until the gate cooldown elapses). Wall-time
  win from closure alone is therefore *partial*, not total — **resolving the gate is
  mandatory, not optional.** This tightens fork (a): "arm + measure" is necessary but
  likely insufficient without (c) or (b).
- **Root-cause reframe (worth weighing before committing to the arming approach).**
  `SKIP` and `CONT` being two ping-ponging traces is itself the symptom of trace
  *selection*, not a fixed input. A tracing JIT that recorded the outer loop as **one**
  trace with the inner loop nested / the composite side as a side-exit (LuaJIT's shape)
  would have neither the coherence nor the accounting problem — there is no cross-anchor
  handoff to stitch. Increment 3 (arm the fragments back together) treats the symptom;
  an alternative increment (fix outer-loop-with-branch recording so it does not
  fragment) removes the disease. This is an architectural fork above Increment 3 and is
  recorded here for Bart, not decided.

**Net of both reviews:** the two blockers are real and concordant. The open decision
is no longer "how to word Part A" but **which of three gate strategies (a/b/c) and
whether to pursue arming at all vs. fixing trace selection** — a direction call for
Bart before any code. Increment 3 does not proceed to implementation on the current
framing.

#### Part A (RESOLVED) — Gate strategy **B** (region accounting) + edge-4 bridge (Bart's decision, 2026-07-17)

This subsection is the **design of record** for Part A and supersedes the "Arm edge
4 / reuse `.ordinary_guard` / summed-count-never-gates" framing above (kept as the
historical first cut) and resolves the codex/Antigravity fork. Both blockers stand;
this is how they're discharged.

**The direction is settled by evidence, not preference.** Before choosing a gate
strategy, Bart asked to investigate *why* lune fragments the outer-loop-with-branch
into `skip`/`cont`/`inner` at all — i.e. whether Antigravity's "record it as one
trace" reframe is the real fix. It is not. Three independent sources agree the
fragmentation is deliberate and byte-for-byte LuaJIT-faithful:

- **doc 15** — the one-trace approach "was implemented and **failed**" (unrolls the
  inner loop into forward-referencing malformed IR that trips `assertWellFormed`);
  "The single-loop trace model cannot represent a nested loop as one straight-line
  body. LuaJIT reached the same conclusion and does not unroll."
- **The recorder** (`recForPrepLink`, trace.zig:4925) LINNER-aborts any `.root`
  reaching an inner `for_prep`; nsieve:29 is a `.continuation` that links back to
  inner root 24 — LuaJIT's `rec_loop_jit → LJ_TRERR_LINNER` verbatim.
- **LuaJIT itself** (`luajit -jdump=t` on the same nsieve): 11 traces = **3
  self-loop roots** (line 3 init, line 7 inner, line 5 outer-skip) + **8 side traces
  each patched into a root** (`stop -> 1/3/6`). Maps 1:1 onto lune: lune nsieve:24 =
  LJ trace 3 (inner root), nsieve:14 = LJ trace 6 (outer-skip root), nsieve:29→link
  24 = LJ trace 4 (side 3/3, `stop -> 3`). **LuaJIT fragments identically.** Its only
  edge lune lacks is that `stop -> 3` is a *patched* rel32 jump into the root's
  mcode (Part B), not a Zig re-entry.

So "fix trace selection" is ruled out: it is the exact thing lune **and** LuaJIT
both tried and rejected. Increment 3 (stitch the fragments together natively, then
patch) is the LuaJIT-faithful path. The remaining choice is only the gate strategy.

**Gate strategy chosen: (b) region-level accounting** — not (c) exempt-armed. The
reasoning (the gate's job is a *deterministic proxy for profitability-over-time*,
since determinism forbids measuring cycles):

- **(a) per-segment iterations** measures the wrong unit — a segment is not the
  thing that is or isn't profitable; the fused region is. nsieve's 1–3-iteration
  prime bursts look unproductive per-segment while the region self-looping thousands
  of times is wildly profitable. Metric ≠ profitability. Rejected.
- **(b) per-region iterations** measures the right unit. The region
  `skip→ramp→inner→cont→skip` *is* the outer back-edge; it self-loops once per `i`,
  thousands of times. Region-accounting keeps it (correct — it is the hot outer loop
  in native) and still retires a region that genuinely runs cold (< `min_useful`
  traversals) — also correct. The metric tracks the quantity.
- **(c) exempt armed edges** measures nothing; asserts `armed ⇒ profitable`. That
  conflates *linkable* (a structural recorder fact) with *profitable* (pays at
  runtime). An armed link that ping-pongs in tiny bursts re-entering Zig at
  ~600 ns/hop is armed **and** unprofitable, and (c) keeps it forever. (c) is only
  correct once Part B makes transitions cheap **and** needs a *separate* flush /
  blacklist to retire cold armed regions (LuaJIT has exactly that alongside its
  patching; lune's epoch-disarm only approximates it). B provides that retirement in
  the *same* gate for free.

Bart's framing: **C is "trust Pall, he made it fast"; B is "it is fast, and here is
why."** B is correct regardless of transition cost, strictly dominates C on
correctness, and — once you account for the flush machinery C would otherwise need —
is not obviously more machinery either. Chosen.

**Two mandatory mechanisms** (each discharges one blocker):

1. **Edge-4 bridge / materialization (coherence blocker).** Edge 4
   (`cont(29).composite-guard → skip(14)`) does **not** reuse `.ordinary_guard`. It
   gets its own contract: a new `ArmKind` (`.branch_backedge`/`.region_bridge`), a
   new ledger kind, and a compiler-generated **bridge stub** that commits the
   continuation's outer-back-edge phis (`count+1`, next `i`) — the values a `.link`
   commits (nativegen.zig:4502) but an ordinary deopt does not (4598) — and shuffles
   registers into `skip(14)`'s entry contract (`entry=[r4 r0 r6 r3 r5]`) **before**
   jumping to skip. This is lune's `asm_head_side` (LuaJIT `lj_asm.c`): a per-edge
   reconciling head, not a bare `jmp`. Without it, skip reads stale `i`/count. This
   is the same materialization doc 17's "Later — Register-level coherence" (below)
   anticipated; edge 4 forces it now rather than deferring.

2. **Region-level accounting (gate blocker).** `replayLedger` stops billing each
   ledger entry a *local* delta via per-segment `onSideExit` (trace.zig:1972/1996/
   2162). Instead it **aggregates one region-burst's committed iterations** and
   issues a single `onSideExit(region_owner, summed_traversals)` per burst, comparing
   the region's traversal count against `min_useful`. Applied **consistently across
   native, tier-1a, and the unlinked path** (P-EBP-2 demands all modes account
   identically). A region self-looping thousands of times per top-level run clears
   `min_useful` on the first burst and the anchor never gates; a genuinely cold
   region (< `min_useful` region traversals total) still gates — correct retirement,
   which (c) would lose.

**Cross-anchor replay grammar + discovery (the two "hard failures" the review
found, now in-scope work, not blockers):**

- The fused-M1 grammar requires parent+child share an anchor (trace.zig:3098) and
  panics on an `rbx`-advancing successor (2159). Edge 4 is cross-anchor
  (`cont(29)→skip(14)`) and skip *does* advance `rbx`. The bridge's new replay
  grammar must (i) accept a cross-anchor successor, (ii) accept an rbx-advancing
  successor, (iii) attribute both segments' committed counts to the **region owner**
  for the aggregate `onSideExit`.
- Discovery: `driveChain(.ordinary_header)` walks `failed.anchor.pc` (trace.zig:1647),
  so `cont@29` never finds `skip@14`. Part A defines an explicit **region-membership
  map** (which anchors constitute the region + the cross-anchor PC mapping), validated
  at arm time — not "a different pairing." This map is also what Part B's patch
  discovery consumes.

**Carried forward unchanged from the reviews** (not re-litigated by this decision):

- **No-yield hole = APPROVE-WITH-CHANGES.** `LEDGER_CAP` bounds cross-trace
  *transitions*, not iterations; a same-trace composite back-edge runs unbounded
  between appends. Not a current break (suspend is pre-armed, not async;
  `safe_to_arm==false` disarms before native entry). A native back-edge poll becomes
  a prerequisite **only if** async interrupts / bounded latency are ever required.
- **Lifetime = SOUND, conditional.** The identity registry
  (`armNativeLink`/`resetLinksTouching`/`disarmAllLinks`) covers edge 4 **iff** the
  new arm is `safe_to_arm`-gated, all writes go through `armNativeLink`, and a
  2c-F-style test runs with **both** persistent cycles live plus negative controls.
- **Antigravity's mid-burst point holds and reinforces B.** An armed edge bypasses
  `isGated` only mid-burst; every burst start / post-`LEDGER_CAP` re-entry still hits
  the gated entry check. So closure alone (fork a) is *partial* — resolving the gate
  is mandatory, which is exactly what B does. (Fork a is thereby subsumed: "arm +
  measure" is necessary but insufficient; B is the sufficient part.)

**`min_useful` retuning — an explicit Part-B-landing obligation (not free).**
`min_useful = 8` is calibrated for *expensive* entry (deopt + Zig re-entry). Once
Part B's rel32 patching makes transitions cheap, the break-even trip count drops
toward 1–2; carried unchanged, `8` would start **over-retiring** short-trip
profitable regions — the nsieve pathology inverted. So when Part B lands, retune
`min_useful` down (better: express break-even as a function of measured transition
cost rather than a magic constant). This is a constant + a re-measure, not a
redesign, but it must not be forgotten — it is a checklist item on Part B.

**Hybrid optimization (Bart's intuition; future, measure-gated).** B pays a small
per-traversal bookkeeping cost in the hot path that C does not. Once a region is
**confirmed hot + armed**, that accounting is pure overhead — the profitability
question is already answered. So the optimization path is **B collapsing to C for
proven regions**: measure until a region clears `min_useful` with margin, then stop
billing its traversals (exempt the already-armed region, C-style), keeping the full
region accounting only for un-proven regions and for detecting a proven region going
cold (via the existing disarm/epoch machinery). This is "measure-until-proven, then
trust" — strictly better than either B-always or C-always. Gate it on first
measuring how much bookkeeping B actually costs; do not build it speculatively.

**Determinism (P-EBP-2).** Region-level accounting is a deterministic *heuristic
redesign*, not exact per-segment replay parity — so it must be proven mode-invariant,
not assumed. It is: region membership, which burst a segment belongs to, and the
summed committed count are all deterministic functions of the replayed instruction
stream (the same P1-style argument doc 15 uses for arming order). The obligation is
to replicate the *identical* aggregate `onSideExit` sequence across all
`{record+exec-*}` × `gc_stress` modes, pinned by the 10-mode matrix, and to prove the
newly-non-gated nsieve:14 does not change *which* later traces record (only where its
own iterations run). The bridge's phi-commit + register shuffle carries the same
P-EBP-1 output-invariance obligation as any `.link` materialization.

#### Review outcome — round 2 (gate-B design), codex `gpt-5.6-sol` + Antigravity, 2026-07-17: DIRECTION APPROVED, DESIGN still BLOCKER

Both reviewers **approve the direction** — arming/patching over trace-selection, and
gate **B over C** — but both return **BLOCKER** on the design as written: it picks the
right strategy but under-specifies the bridge snapshot and the region-accounting state
machine. Coding is **not** unblocked; one more design pass is required. The §Part A
(RESOLVED) text above is the correct *strategy*; the specifics below supersede its
mechanism sketch.

**Two corrections to the strategy write-up (adopt these):**

- **The B-over-C rationale I gave is weak; the real reason is determinism.** Both
  reviewers flag that "C needs a separate flush for cold regions, B doesn't" is *weak* —
  the existing disarm/epoch machinery already flushes cold armed regions. The load-bearing
  reason to prefer B is: under C, "armed" is a **physical native-compilation state** that
  tier-1a and record-only modes do not share (they compile no native code, patch no
  jumps), so using armed-ness as a gate-exemption rule **diverges across the 10-mode
  matrix**. B, defined on a tier-independent logical unit, does not. Correctness-of-unit
  (the earlier argument) still holds and is fine; determinism is the *decisive* one.
- **Edge-4's LuaJIT correspondence was mis-cited.** The four-edge table / earlier text
  implied `LJ trace 4 (stop -> 3)` is the edge lune lacks — but trace 4 is cont/ramp →
  inner = **edge 2**, which lune already arms. Edge 4 (`cont composite-fail → outer-skip
  root`) corresponds to LuaJIT **traces 10/11 (`stop -> 6`)**. Direction unaffected;
  evidence mapping corrected. (Also: "arming is the *only* LuaJIT-faithful lever" is too
  absolute — LuaJIT's `innerloopleft` unrolls very short inner loops; N/A to nsieve's hot
  inner loop, but it exists.)

**BLOCKER 1 — Edge-4 bridge is viable but the contract is underspecified.** "Commit phis
+ shuffle registers" is not implementable as stated. The concrete contract both reviews
converge on:
- **Guard-specific, dominance-scoped snapshot — NOT the full `.link` flush.** At cont's
  composite `guard_true` failure only the phis whose update values **dominate that guard**
  are defined: for nsieve `{r2 ← count+1, r3 ← next i, r6 ← next visible i}`. The `.link`
  snapshot (nativegen.zig:4502) additionally commits the inner-loop-setup phis that live
  *after* the failed guard — those are **undefined** on edge 4. The bridge must materialize
  only the dominating set; reusing the whole `.link` flush is a correctness bug.
- **Materialize `regs[]` and enter `ordinary_entry`; do NOT bypass the child prologue with
  a physical register shuffle.** `skip.ordinary_entry` falls through to `body_entry`
  (nativegen.zig:4691), which re-runs all tag/type/table-shape/identity/array-base guards
  (nativegen.zig:3690/3749/3773). This is what *resolves* Antigravity's "bypassed
  loop-invariant guards" hazard — provided the bridge enters at `ordinary_entry`, not the
  loop head. A physical parent→child register shuffle is wasted (the child reloads homes
  from `regs[]`); the bridge writes the dominating phis into `regs[]` and jumps to
  `ordinary_entry`. `entry=[r4 r0 r6 r3 r5]` is a VM-slot list (trace.zig:636), not a
  machine-register ABI. Require `skip.inputs.len == 0` (a bare jump cannot seed synthetic
  inputs; existing chained-child restriction).
- **Bridge lifetime/ABI is a new object, not just an `ArmKind`.** `armNativeLink`
  (trace.zig:3234) derives its target directly from the child's entry; a bridge is
  `parent guard slot → bridge → child ordinary_entry`. Define: emission (with-parent vs
  lazy vs second indirect slot), where the child target is stored, how re-arm updates it,
  how child retirement invalidates *both* the bridge and the parent slot, and how the
  forced-yield check behaves before bridge materialization.

**BLOCKER 2 — Region accounting needs an API split, a normalized unit, a stable key, and a
tier-independent window.** "Replace per-segment `onSideExit` with one
`onSideExit(region_owner, sum)`" cannot be done as stated:
- **Split the API.** `onSideExit` (trace.zig:1550) conflates four jobs: per-anchor coverage,
  cycle attribution, `Trace.hit_count`, and penalty/gate. `hit_count` drives trace
  *selection* (findTrace/findLoopTrace/findLinkTrace, trace.zig:1415/1451/1471), so calling
  it once on skip changes *which traces later execute/record* — violating "heuristic-only".
  Split into `accountTraceRun(trace, local)` (coverage/cycles/hit ordering, per-segment as
  today) and `accountRegionProfit(region_key, normalized_traversals)` (penalty/gate only).
- **Normalized traversal unit — never sum raw `rbx`.** skip's `rbx` counts composite outer
  iters, inner's counts `k`, `.link` increments nothing, one-trip is synthesized as
  `max(local,1)` (trace.zig:2057). Summing raw deltas makes one big inner sieve loop look
  like thousands of outer traversals. Define: `outer_traversals = committed skip composite
  iterations + one per completed prime(inner→cont) cycle`; inner `k` iterations are **not**
  added. This preserves doc-15's "loop-done = one completion" rule and keeps `min_useful`
  meaningful.
- **`region_owner` = a stable identity-based `RegionKey` with an explicit owner `AnchorKey`**
  (probably the outer root `(proto, 14)`), NOT whichever `*Trace` is selected at PC 14.
  Gating keys on `AnchorKey` (trace.zig:1575/3481), so `(proto,14)` correctly gates/ungates
  both same-anchor skip and its prime-side siblings.
- **Membership/discovery map is identity/edge-based, not PC-based:** `(parent_trace_id,
  exit_slot) → (region_id, child_trace_id, child_anchor, bridge_contract)`, with retirement
  cleanup alongside `resetLinksTouching`. (A PC holds multiple sibling traces; `hit_count`
  changes which is selected.)
- **Tier-independent logical window (the determinism blocker).** Burst boundaries are
  physically tier-dependent — native `LEDGER_CAP=32` (irinterp.zig:86), tier-1a 8-hop
  (trace.zig:2369), unlinked per-segment — so a physical "one call per burst" yields
  `onRegion(32)` vs `onRegion(8)` vs `onRegion(1..)` for the *same* logical traversals →
  different gates → matrix divergence. All three tiers must feed **one persistent region
  accumulator** flushed on **logical** boundaries (after N normalized outer traversals, on
  genuine region exit, on program/frame exit, on retirement) — never on physical
  native-call return / ledger-full / hop-exhaustion. **GC-stress corollary (Antigravity):**
  GC safepoint exits must **not** count as region-burst exits, or a region gates under
  `gc_stress on` but not off. Accounting equivalence is assertable across the **6
  `record+exec-* × gc_stress` modes only** — trace-off/record-only execute no traces and
  cannot match the `onSideExit` sequence; state this in P-EBP-2.

**Cross-anchor ledger grammar — ADDITIVE is fine, WHOLESALE is not.** A new ledger kind +
a dedicated validation arm for the bridge transition (validate parent identity+slot, child
identity, registered region edge, expected child anchor, cumulative-counter relation,
dispatched/terminated/force-yielded, child prologue-fail as a valid terminal) is localized
and safe. It must **not** weaken the existing `.deopt` same-anchor provenance check
(trace.zig:3098) or its zero-progress-successor invariant (the 2159 panic guards a real
case). Replacing *all* local accounting inside the replay machine (which tracks
continuation identity, `link_pc`, `linked_completed`, resume PC, hop budgets from
trace.zig:1945; scalar dispatcher paths at interp.zig:2848/3008) is the broad, stateful
part — that is the API split above, done carefully, not a rewrite of the drain.

**`min_useful` retune — attach to the bridge, not Part B (SHOULD-FIX).** The ~600 ns Zig
transition is already removed by the *indirect slot* handoff (2.3a); Part B's rel32 only
removes the residual slot load. So the break-even shift starts the moment edge 4 fuses via
the bridge, not at Part B. codex: retaining `min_useful = 8` through the bridge landing is
*probably* safe for nsieve **iff** the normalized logical window covers multiple primes
(dense-prefix short gaps sum within the window). Antigravity is sharper: if the window is
per-prime, the dense prefix gates skip *before* reaching the sparse tail (permanent tier-0)
— remedy scale `min_useful`→1 or disable the penalty pre-patch. **These reconcile: Q4 is
subsumed by the logical-window definition** — get the window right (multi-prime, tier-
independent) and 8 holds; get it wrong (per-prime physical) and it gates. So the window is
load-bearing for correctness, not just determinism.

**Net of round 2:** direction and gate-B choice confirmed and hardened; the design needs a
**round-3 pass** nailing the nine specifics (bridge dominance-snapshot / `ordinary_entry`
entry / `inputs==0` / bridge lifetime ABI; `onSideExit` API split / normalized unit /
identity `RegionKey` / tier-independent logical window / GC-safepoint exclusion) before any
code. Increment 3 does not proceed to implementation on the round-2 framing.

#### Part A — round-3 design (2026-07-17): the nine specifics, resolved

This subsection discharges the nine round-2 blocker items with concrete, code-grounded
contracts and is the **design of record** for Part A's mechanism (superseding the
mechanism sketches in §Part A (RESOLVED) and the original §Part A above; the *strategy*
there — gate B, edge-4 bridge — stands). Grounding reads for this pass:
`nativegen.zig:3099` (`flushSlot`), `:3249` (`emitReturn`), `:3347` (`emitForcedYieldCheck`),
`:3597-3625` (`emitLinkedLoopDoneSnapshot`), `:4543-4705` (per-guard exit stubs, shared
`deopt_exit`, `prologue_fail`, the `linked_entry`/`ordinary_entry` stubs);
`trace.zig:1550-1581` (`onSideExit`), `:892/1003/3234-3395` (`NativeLink`/`armed_links`/
`armNativeLink`/`resetLinksTouching`/`disarmAllLinks`), `:3098-3107`
(`fusedSourceBranchLinkSlot` same-anchor check), `:2148-2160` (M1 zero-progress panic),
`:1493-1507` (`nextTraceExcluding` anchor-exact discovery), `:1415/1451/1471`
(`findTrace`/`findLoopTrace`/`findLinkTrace` — `hit_count` selection);
`irinterp.zig:154-217` (`LedgerKind`/`LedgerEntry`, `LEDGER_CAP=32`); and the nsieve
`cont(29)` native-IR dump.

**Correction that reframes the whole edge (adopt): an armed ordinary guard is ALREADY a
native in-page handoff, not a Zig re-entry.** The round-2 sketch (and my earlier notes)
implied edge 4, being an "ordinary" source-branch guard, would re-enter the dispatcher.
It would not. An armed ordinary guard resolves its dispatch target **through its own
`slot[ei]`** (`nativegen.zig:4569-4573`: `mov rax, &slot[ei]; mov rax,[rax]; mov
[rdx+exit_target], rax`) and the shared `deopt_exit` tail ends in `jmp qword
[rdx+exit_target]` (`:4631-4633`), so when the slot is armed the flush jumps **straight
into the child body** under the shared frame — exactly how edges 1–3 already fuse. So the
per-iteration Zig re-entry the A/B measured is **edge 4 alone** (the one edge left
unarmed): today a burst runs `skip→ramp→inner→cont` natively and then cont's composite
guard hits the *unarmed* shared `deopt_exit` → returns to the dispatcher, once per outer
iteration. Closing edge 4 removes that single re-entry and the outer loop self-sustains
natively to the `LEDGER_CAP` cap. **But** edge 4 cannot simply reuse the ordinary-guard
slot path, because the shared `deopt_exit` flush commits the *wrong values* for it (A.1.2)
— which is the coherence blocker, now grounded to IR indices.

##### A.1 — The edge-4 bridge (BLOCKER 1)

**A.1.1 — Which guard, why it is coherent at cont's anchor and not skip's.** Edge 4's
source is `cont(29)`'s `%023 guard_true` on `%022 aload p[next i]` — the outer loop's
`if p[i]` re-test. It is an *ordinary* guard (`isNumericForLoopDoneGuard(cont,23) ==
false`; it is the mirror of `skip(14)`'s `%012 guard_false`). Its failure means "the next
`i` is composite" → hand to `skip(14)`, the composite self-loop root. The reason edge 1
(skip→ramp) needs no special snapshot but edge 4 does, read straight off the IR:

- **Edge 1**: `skip.%012 guard_false` fires *before* skip's outer back-edge (its phis
  `%021/%022` and `%023 loop` are all after %012). So skip's carried homes still hold the
  *current* `i` — the prime — which is exactly ramp's required entry state. The shared
  `deopt_exit` pre-update carried-home flush is correct.
- **Edge 4**: `cont.%023 guard_true` fires *after* cont has already computed the outer
  back-edge values — `%004 add` (`count+1`) and `%011 add` (`next i`) sit at indices 4 and
  11, *before* %023 — but the phi writebacks that move them into their homes (`%031 phi
  update=%4 → r2`, `%032 phi update=%11 → r3`, `%033 phi update=%11 → r6`) are at indices
  31–33, *after* %023. So at %023-failure the homes `{r2,r3,r6}` still hold the *previous*
  iteration's `{count, current i, current i}`, while skip needs `{count+1, next i, next i}`.
  The shared `deopt_exit` flush (`nativegen.zig:4602-4603`, carried homes only) commits
  those stale homes → skip would read a stale `i`/`count`. This is round-2's coherence
  blocker, exact.

**A.1.2 — Dominance-scoped snapshot (NOT the `.link` flush).** The bridge commits only the
phi *update values* whose defining instruction **dominates** the composite guard, i.e.
`update_index < guard_index (23)`, and whose target slot is either read by skip or is live
VM state skip must preserve:

- `%031 phi update=%4 (idx 4) → r2` (count+1) — live VM state; skip does not load r2 but
  must preserve it for cont's later `count` read. Commit.
- `%032 phi update=%11 (idx 11) → r3` (next i, control) — in `skip.entry`. Commit.
- `%033 phi update=%11 (idx 11) → r6` (next visible i) — in `skip.entry`. Commit.

The **post-guard** phis are undefined on edge 4 and must NOT be committed: `%034 update=%24
→ r7`, `%035 update=%25 → r8`, `%037 update=%24 → r10` (all `update_index > 23`, inner-loop
setup regs). `%036 update=%11 → r9` has a dominating *update value* but a slot skip never
reads — harmless to skip either way, but the rule "commit only dominating updates whose
slot is live at the successor" cleanly excludes it. Mechanically the bridge reuses
`flushSlot(a, slot, kind, placeOfRef(alloc, update_ref))` — identical to
`emitLinkedLoopDoneSnapshot`'s per-phi flush (`nativegen.zig:3623`) — but **filtered** to
the dominating set instead of "all non-internal phis," and with the post-guard `astore`
scan (`:3604-3614`) omitted (those stores are the inner-loop body, undefined here).

**Fail-closed rule (arm-time validation).** For every slot in `skip.entry` (`[r4 r0 r6 r3
r5]`), require it to be either (i) invariant/coherent in `regs[]` at the composite exit
(`r4` limit, `r0` p-table, `r5` step — invariant slots, never destructively overwritten in
`regs[]`), or (ii) fed by a *dominating* phi the bridge commits (`r3`, `r6`). If any
`skip.entry` slot is fed by a *post-guard* (undefined) phi in cont, the region is **not
armable** — decline the arm (do not build the bridge). nsieve satisfies (i)/(ii) for all
five; the check is what makes the mechanism general rather than nsieve-specific.

**A.1.3 — Materialize `regs[]`, enter `ordinary_entry`; no register shuffle.** After the
snapshot the bridge jumps to `skip.ordinary_entry` (`nativegen.zig:4698-4702`), which
presets `linked_loop_done = 0` and falls into `body_entry`, **re-running skip's hoisted
type/table-shape/identity/array-base guards from `regs[]`** (`:3690` onward). That re-run
is what discharges Antigravity's "bypassed loop-invariant guards" hazard — the bridge must
enter at `ordinary_entry`, never at skip's loop head. `skip.entry = [r4 r0 r6 r3 r5]` is a
**VM-slot list** (`trace.zig:636`), not a machine-register ABI, so there is nothing to
shuffle: the child reloads its homes from `regs[]`. Require `skip.inputs.len == 0` (a bare
jump cannot seed synthetic inputs — the existing chained-child restriction, 2.3b-1).

**A.1.4 — Emission + lifetime ABI: an in-page stub, not a heap object.** The bridge is a
**compile-time stub emitted inside cont's own page**, structurally identical to the
existing `linked_loop_done_labels` stubs (`nativegen.zig:4583-4596`) — *not* a separately
allocated object, which dissolves round-2's "new object lifetime" worry:

- A recorder/region-map classifier (`isRegionBridgeGuard(t, ei)`, fed by the region
  membership map of A.2.4) marks cont's composite guard index. At the per-guard stub loop
  (`:4557`), that index binds a **dedicated bridge stub** instead of routing to the shared
  `deopt_exit` — the same fork the loop-done guard already takes via
  `isNumericForLoopDoneGuard` (`:4561`).
- The bridge stub branches on **slot armedness** to stay byte-identical when unarmed:
  `load slot[ei]; if == shared_exit → jmp deopt_exit` (today's exact ordinary-composite
  path: pre-update carried flush, resume tier-0 at the composite exit PC — byte-identical);
  `else →` dominating snapshot (A.1.2) `→ mov [rdx+completed], rbx →` `emitLedgerAppend(a,
  cont.id, .region_bridge)` `→ mov [rdx+final_trace_id], skip.id →` stage `exit_target =
  slot[ei]` `→ emitForcedYieldCheck(a, shared_exit)` `→ jmp qword [rdx+exit_target]`. INERT
  until armed (slot defaults `shared_exit`), so it lands byte-identical like every prior
  increment.
- **New `ArmKind.region_bridge`** (`trace.zig:479`). `armNativeLink` derives the target
  `= skip.ordinary_entry` from `child + kind` (`:3264-3271`) — preserving the "derive, never
  trust a caller address" hardening invariant — and writes `slot[ei]` (the *same* invariant
  the doc pins at `:3229`, "only writer of `slots[i]`"). Extend the two target `switch`es
  (`:3268` and the loop-done-shape `switch` at `:3248`).
- **Lifetime falls out of the existing registry for free.** `resetLinksTouching`
  (`:3346-3366`) and `disarmAllLinks` (`:3381-3395`) reset a parent slot to `shared_exit`
  by `(parent, slot_index)` — they already cover the bridge slot with no change (child
  retire → parent slot reset; parent retire → record dropped). Because the bridge stub
  lives and dies with cont's page and is reachable only through the armed slot, disarming
  the slot fully retires the edge — **no separate free path**. `safe_to_arm` gates the arm
  (same as all edges), so an observation/replay window declines it and `disarmAllLinks`
  collapses a live one (the 2c-F disarm test extends to cover **both** persistent cycles —
  `cont↔inner` and the outer `skip→…→cont→skip` — plus negative controls).
- **Forced-yield after commit.** If the ledger is full at the bridge,
  `emitForcedYieldCheck` redirects to `shared_exit` **after** the snapshot has already
  committed `{r2,r3,r6}` — so the yield resumes in the dispatcher at the **child anchor**
  `skip.pc = 14` (from the region map's `child_anchor`), with `regs[]` already coherent for
  skip. The ledger entry carries the `.region_bridge` kind + a `yielded` outcome (A.3), and
  the replay resumes there; this is coherent precisely because `ordinary_entry` and a
  tier-0 resume at `skip.pc` read the same materialized `regs[]`.

##### A.2 — Region accounting (BLOCKER 2)

**A.2.1 — Split `onSideExit` into selection vs. profitability.** `onSideExit`
(`trace.zig:1550-1581`) conflates four jobs; two of them (`noteTraceIters` coverage 1560,
`noteTracedCycles` 1565 — both already `config.coverage`-gated, off the deterministic hot
path) plus the per-`Trace` `hit_count += 1` (1570) are **selection-relevant**: `hit_count`
drives `findTrace`/`findLoopTrace`/`findLinkTrace`/`nextTraceExcluding` (1424/1451/1471/1493,
highest-hit-count wins), so moving or aggregating it would change *which traces execute and
record* — violating "heuristic-only." Split:

- `accountTraceRun(t, local)` — coverage + cycles + `if (local >= min_useful) t.hit_count
  +|= 1`. **Per-segment, unchanged**, called exactly where `onSideExit` is called today in
  `replayLedger`/dispatcher. Selection stays byte-identical.
- `accountRegionProfit(region_key, normalized)` — the penalty/gate half only
  (1569 `penalty.remove`+`gate.remove` on `normalized >= min_useful`; else 1575 penalty
  bump + `gateAnchor` at `max_penalty`). Keyed on the region's owner `AnchorKey`.

The elegance that keeps every non-fused path identical: **a lone trace is a degenerate
one-member region** whose window is one segment, so `accountRegionProfit` fires per-segment
with `normalized = local` — i.e. today's exact gating. Only genuinely *fused* regions
aggregate. This is how "applied consistently across native/tier-1a/unlinked" (P-EBP-2) is
satisfied without special-casing the common path.

**A.2.2 — Normalized traversal unit (never sum raw `rbx`).** skip's `rbx` counts composite
outer iters, inner's counts `k`, `.link` increments nothing, and a one-trip loop-done is
synthesized `max(local,1)` (`trace.zig:2057`). Summing raw deltas makes one big inner sieve
loop look like thousands of outer traversals. Define, per ledger entry, mapped by
`LedgerKind`:

  `outer_traversals += (kind == .deopt or .region_bridge on a skip/composite source) ? local
                      : (kind == .loop_done_linked /* inner→cont completion */) ? 1
                      : /* .link_terminal, prologue_fail */ 0`

i.e. **committed skip composite iterations + one per completed `inner→cont` prime cycle;
inner `k` iterations are not added.** This preserves doc-15's "loop-done = one completion"
rule and keeps `min_useful` in outer-iteration units.

**A.2.3 — `region_owner` = identity `RegionKey` with an explicit owner `AnchorKey`.** The
owner is the outer root `AnchorKey (proto, 14)` (`AnchorKey = {proto, pc}`, `trace.zig:542`),
**not** whichever `*Trace` is selected at PC 14. Gating keys on `AnchorKey` (1575/3481/3494),
so `(proto,14)` gates/ungates the skip trace *and* every prime-side sibling anchored there
uniformly — the correct blast radius. `RegionKey` itself is identity/edge-based (A.2.4), not
PC-based, because a PC holds multiple sibling traces and `hit_count` changes which is
selected.

**A.2.4 — Membership/discovery map (identity/edge-based, replaces the PC walk).** Discovery
today is anchor-exact: `driveChain(.ordinary_header)` sets `walk_pc = failed.anchor.pc`
(`trace.zig:1647`) and `nextTraceExcluding` only returns traces whose `anchor.pc` matches
(`:1500`) — so `cont@29` can never discover `skip@14`. Part A defines an explicit map,
populated at arm time and validated then:

  `(parent_trace_id, exit_slot) → { region_id, child_trace_id, child_anchor,
      bridge_contract /* dominating-phi set + fail-closed result */ }`

with retirement cleanup alongside `resetLinksTouching`. This is the same map Part B's patch
discovery consumes. It replaces "a different pairing" of the anchor-local walk with an
explicit cross-anchor edge table — the review's requirement.

**A.2.5 — Tier-independent logical window + one persistent accumulator (the determinism
blocker).** Burst boundaries are physically tier-dependent: native `LEDGER_CAP = 32`
(`irinterp.zig:96`), tier-1a's hop budget, unlinked per-segment — so a physical "one
`accountRegionProfit` per burst" would issue `onRegion(32)` vs `onRegion(8)` vs
`onRegion(1..)` for the *same* logical traversals → different gates → matrix divergence.
Fix: **all three tiers feed one persistent region accumulator held in `TraceState`, keyed
by `RegionKey`**, updated by the native `replayLedger`, the tier-1a dispatcher, and the
unlinked per-segment path alike. It flushes (`accountRegionProfit` + reset) only on
**logical** boundaries:

- after `N` normalized outer traversals (a logical window constant, tier-independent), or
- on genuine region exit — control reaches a bytecode PC outside the region's membership
  (a deterministic function of the instruction stream), or
- on program/frame exit, or on region retirement.

Never on `LEDGER_CAP` / hop-exhaustion / native-call return — a forced yield at
`LEDGER_CAP` followed by re-entry is **not** a region exit; the accumulator survives it.
**GC-stress corollary (Antigravity):** a GC safepoint exit is likewise **not** a
region-burst exit — otherwise a region gates under `gc_stress on` but not off. Accounting
equivalence is assertable across the **6 `record+exec-* × gc_stress` modes only** (trace-off
and record-only execute no traces and cannot match the `onSideExit`/`accountRegionProfit`
sequence); state this explicitly in P-EBP-2.

##### A.3 — Cross-anchor ledger grammar (ADDITIVE, not wholesale)

Add one `LedgerKind.region_bridge` (`irinterp.zig:154`) plus a **dedicated validation arm**
in `replayLedger` for the bridge transition: validate parent identity + slot, child
identity, a **registered region edge** (the A.2.4 map), the expected child anchor
(`skip@14`), the cumulative-counter relation, the dispatch outcome
(`dispatched`/`terminal`/`yielded`), and child prologue-fail as a valid terminal. Crucially
this arm **accepts a cross-anchor, `rbx`-advancing successor** — which the *existing* M1
`.deopt` arm forbids: `fusedSourceBranchLinkSlot` requires parent+child share an anchor
(`trace.zig:3098-3107`) and the zero-progress panic asserts the successor commits 0
(`:2159-2160`, `entries[k+1].cum == e.cum`). Those guard the real M1 skip→ramp case (ramp
commits 0 of its own) and **must not be weakened**; the bridge's cross-anchor rbx-advance is
handled entirely in the *separate* `.region_bridge` arm, leaving the same-anchor invariant
intact. This is the "additive is fine, wholesale is not" line: a new kind + a new arm,
never a rewrite of the drain's continuation/`link_pc`/resume-PC/hop-budget state machine.

##### A.4 — `min_useful` retune attaches to the bridge landing (SHOULD-FIX)

The ~600 ns Zig transition is removed the moment edge 4 fuses via the bridge (the indirect
handoff is native from that point), **not** at Part B — Part B's rel32 only removes the
residual `mov rax,[rdx+exit_target]` load. So the break-even trip count drops at the bridge
landing. Q4 is **subsumed by the A.2.5 logical window**: with a multi-prime, tier-independent
window (the dense prefix's short composite gaps sum within one window), `min_useful = 8`
holds; with a per-prime *physical* window the dense prefix would gate skip before the sparse
tail (permanent tier-0). So the window definition is load-bearing for *correctness*, not only
determinism. Retuning `min_useful` (better: expressing break-even as a function of measured
transition cost) is a **bridge-landing checklist item**, not deferred to Part B.

**Net of round 3:** all nine specifics have concrete, code-anchored contracts — bridge:
dominance snapshot filtered by `update_index < 23` and successor-liveness / enter
`skip.ordinary_entry` with guard re-run / `inputs.len == 0` / in-page stub + `ArmKind.
region_bridge` + registry-covered lifetime + forced-yield-resumes-at-child-anchor; region
accounting: `accountTraceRun`/`accountRegionProfit` split preserving `hit_count` selection /
normalized outer-traversal unit / identity `RegionKey` owned by `AnchorKey(proto,14)` /
identity-edge membership map / one persistent accumulator on logical (not physical) windows
with GC-safepoint exclusion; plus the additive `.region_bridge` ledger arm and the
bridge-landing `min_useful` retune. Ready for a fresh codex `gpt-5.6-sol` + Antigravity
review; still no code until that review is clean.

#### Review outcome — round 3, codex `gpt-5.6-sol` + Antigravity (gemini-3.1-pro), 2026-07-17: BLOCKER (both)

Both reviewers **confirm the sound sub-parts** and both return **BLOCKER** on a small,
tightly-converging set of specifics. Judged **sound by both**: A.1.1/A.1.2 coherence +
dominance rule (`update_index < guard_index`; codex confirms native allocation already
relies on index-order = dominance at `nativegen.zig:2397`) + the `{r2,r3,r6}` set; the
armed-ordinary-guard-is-native reframe (codex verified the `exit_target` path
`nativegen.zig:4569/4623/4631`); A.1.3 `ordinary_entry` guard re-run + VM-slot-list ABE
(`nativegen.zig:4691/3681/3700/3730`, `trace.zig:636`); A.2.1 API split preserving
`hit_count` selection; A.2.2 normalized unit; A.2.3 `RegionKey`/`AnchorKey(proto,14)` blast
radius; A.3 additive grammar leaving 3098/2159 intact. The blockers (numbered by convergence
— items both reviewers hit are marked ‡):

- **B-1 ‡ Forced-yield-after-commit is broken (both, converged remedy).** The A.1.4 sequence
  stamps `final_trace_id = skip.id` *before* the forced-yield check, then (if the ledger is
  full) redirects to `shared_exit` — but skip never runs, so the terminal ledger owner ≠
  `final_trace_id`, violating the live terminal-consistency assert (`nativegen.zig:771`) and
  the scalar ABI (`:572`); Antigravity adds the replay desync (committed `{r2,r3,r6}` with no
  ledger entry → resume-state mismatch) and the "no static way to carry resume PC 14" hazard.
  **Converged fix: check the ledger cap FIRST; if full, branch to the *unarmed* ordinary
  `deopt_exit` path** (commits nothing, stages the static parent exit PC 29, yields cleanly →
  tier-0 runs cont's `loop` then branches to 14). No commit-then-yield.
- **B-2 Unarmed stub is NOT byte-identical as written (codex).** The proposed `if slot ==
  shared_exit → jmp deopt_exit` does not *stage* `exit_target`; `deopt_exit` unconditionally
  does `jmp qword [rdx+exit_target]` and the field starts at 0 (`nativegen.zig:736`) → jump
  through zero/stale. The stub must stage `exit_target = shared_exit` before entering
  `deopt_exit`, exactly as the current mini-stub does. (Folds into B-1's "branch to the
  ordinary path" — reuse the existing mini-stub, don't hand-roll.)
- **B-3 Compile-time classifier is temporally impossible as designed (codex, NEW).**
  `isRegionBridgeGuard` is said to be fed by the *arm-time* region map, but native lowering
  receives only `*Trace`, not `TraceState`/the map (`nativegen.zig:864/3641`), and compiled
  pages are memoized permanently (`trace.zig:3450`); the region edge is discovered *later* at
  arm time. Must pick one **emission strategy**: (a) precompute immutable bridge metadata
  from trace-local info *before* first compile; (b) emit *generic* bridge-capable stubs at
  every eligible composite guard (trace-local shape only), armed later; or (c) invalidate +
  recompile the page when the region is discovered. This is an architecture fork.
- **B-4 ‡ Logical-window state machine still under-specified + physical leaks (both).**
  (i) tier-1a/unlinked never arm, so they cannot obtain `RegionKey`/membership "at arm time"
  (codex) — needs a tier-independent membership source. (ii) "genuine region exit = PC
  outside membership" is ill-defined under **nested calls** (Antigravity: a call leaves
  region PCs → false flush; gate exit on stack-depth ≤ region-root frame) and **sibling
  traces at the same PC** (codex). (iii) `N` unvalued, window-crossing/remainder semantics
  unspecified (codex). (iv) a single `RegionKey` accumulator conflates re-entrant/recursive
  activations (codex). (v) **the accumulator must NOT live in transient trace state and must
  NOT flush on trace retirement** (Antigravity) — retirement is a GC-physical event →
  `gc_stress` divergence; it must live in a **persistent VM-level region table** keyed by
  `RegionKey` (proto/VM lifetime), flushed only on logical program boundaries. This
  contradicts the round-3 "flush on retirement" bullet — remove it.
- **B-5 Fail-closed rule needs a defined successor live-through set (codex).** Checking only
  `skip.entry` slots misses "live-through" state like `r2` (not loaded by skip but must
  survive into cont's later `count` read). Define the required successor live-in/live-through
  slot set and require every *stale* member to have a dominating update — the nsieve
  `{r2,r3,r6}` result is right, the *rule* as written is under-specified.
- **B-6 Tier-1a/unlinked ledger classifier undefined (codex).** `LedgerKind` exists only in
  native receipts (`irinterp.zig:154`); A.2.2's per-kind normalization has no defined
  equivalent for the tier-1a and unlinked scalar paths. Specify the classifier + exact
  call sites so all three tiers update the accumulator identically (P-EBP-2).
- **B-7 Replay must own resume-PC assignment (both).** `LedgerEntry` carries no child anchor
  / resume PC (`irinterp.zig:193`); the `.region_bridge` replay arm must derive skip's resume
  PC from the validated live region edge — make it part of the replay contract.
- **B-8 `accountTraceRun` must use the synthesized `completed`, not raw `local` (codex).** At
  the linked one-trip site (`trace.zig:2066`, `max(local,1)`) passing raw `local` would change
  coverage + `hit_count` selection. Preserve the existing synthesized value.
- **B-9 The region-edge/bridge-contract MAP lifetime is not "free" (codex).** Only the in-page
  machine-code stub's lifetime falls out of the page + slot registry; the separate region-map
  metadata needs atomic re-arm replacement, OOM ordering, and retirement cleanup (the doc
  already lists cleanup at A.2.4 — reconcile the "for free" overclaim to "stub free, map
  explicit").

**Net of round 3 review:** direction + the bulk of the mechanism are sound; a **round-4 pass**
must (1) rewrite the forced-yield path to cap-check-first→ordinary-deopt (B-1/B-2), (2) resolve
the emission-strategy fork (B-3, Bart's call), (3) specify the persistent VM-level region table
+ stack-depth-gated logical-window state machine + tier-independent membership/classifier
(B-4/B-6), and (4) fold the smaller precisions (B-5 live-through set, B-7 resume-PC contract,
B-8 synthesized `completed`, B-9 map lifetime). Still no code.

#### Part A — round-4 design (2026-07-17): the nine blockers, resolved

This subsection discharges B-1..B-9 and is the **design of record** for Part A's mechanism,
superseding the round-3 A.1.4 forced-yield sequence and the round-3 classifier/lifetime
claims wherever they conflict below. Everything round 3 got right — the A.1.1/A.1.2
coherence + dominance rule, the `{r2,r3,r6}` commit set, the armed-ordinary-guard-is-native
reframe, the `ordinary_entry` guard re-run, the A.2.1 `accountTraceRun`/`accountRegionProfit`
split, the A.2.2 normalized unit, the A.2.3 `RegionKey`/`AnchorKey(proto,14)` blast radius,
and the A.3 additive grammar leaving `3098`/`2159` intact — **stands unchanged** and is not
re-derived here. Grounding reads added this pass: `nativegen.zig:730-736` (`NativeResult`
field init, `exit_target` starts 0), `:571-576` (scalar terminal ABI), `:767-775`
(terminal-consistency tripwire), `:864/3641` (native lowering sees only `*Trace`);
`trace.zig:3450` (page memoization), `:1815-1827` (scalar/unlinked `onSideExit` tail),
`:2047-2068` (`replayLedger` synthesized `max(local,1)`); `irinterp.zig:154-217`
(`LedgerKind`/`LedgerEntry`/`LedgerOutcome` — native-only, no anchor/resume-PC field).

Bart's decision on the B-3 fork: **emission strategy (b) — generic stubs, armed later.**
This matches lune's established inert-scaffolding pattern (`linked_entry`/`ordinary_entry`/
`linked_loop_done` stubs are all emitted unconditionally at compile time, then armed by a
later `armNativeLink`), so the round-4 mechanism is a *fifth* instance of a shape the tree
already proves byte-identical, not a new architecture.

##### C.1 — Emission: a generic, trace-local bridge stub, armed later (B-3, B-1, B-2)

**C.1.1 — Compile-time eligibility is trace-local only (B-3).** Native lowering receives
only `*Trace` and pages are memoized permanently (`nativegen.zig:864/3641`, `trace.zig:3450`),
so the bridge stub cannot depend on the arm-time region map. Emit a bridge-capable stub at
**every composite ordinary guard that passes a purely trace-local shape test** —
`isCompositeBridgeCandidate(t, ei)`:

- the guard is an *ordinary* guard (`isNumericForLoopDoneGuard(t, ei) == false`), and
- it is a same-proto outer-loop re-test whose *dominating* phi-update set (the
  `update_index < ei` filter of A.1.2) covers every slot in the trace's own back-edge
  live-through set (C.4) — computable from this trace's IR alone, and
- `t.inputs.len == 0` (bare-jump entry requirement, 2.3b-1).

This is a *superset* of the guards that will ever be armed — cont(29)'s `%023` qualifies,
and so may a handful of other composite re-tests that never get a region edge. That is fine:
an unarmed bridge stub is byte-identical to today's shared `deopt_exit` path (C.1.3), so
emitting extra inert stubs costs only a few bytes of mcode and never changes behavior. No
`TraceState`, no region map, no recompile at lowering time — the temporal impossibility is
gone.

**C.1.2 — What the stub emits (armed branch).** When the stub's `slot[ei]` is armed
(`!= shared_exit`), in order:

1. **Cap check FIRST** (B-1): `mov rax, [rdx+ledger_len]; cmp rax, LEDGER_CAP; jae
   bridge_full` — *before* any commit or any `final_trace_id` write.
2. Dominating-phi snapshot (A.1.2, unchanged): `flushSlot(a, slot, kind,
   placeOfRef(alloc, update_ref))` for each phi in the dominating live-through set.
3. `mov [rdx+completed], rbx`.
4. `emitLedgerAppend(a, t.id, .region_bridge)` (the append reads `ledger_len < CAP`,
   guaranteed by step 1).
5. `mov [rdx+final_trace_id], child.id` (= skip.id, derived by `armNativeLink`, C.1.4).
6. stage `mov [rdx+exit_target], <slot[ei] value>` (load the armed slot, store to the
   flush-immune field — same as the ordinary-guard path `:4569-4573`).
7. `jmp qword [rdx+exit_target]` — native in-page handoff into `skip.ordinary_entry`.

There is **no `emitForcedYieldCheck` in the armed body** — the cap check at step 1 *is* the
yield decision, taken before any state mutation. This is the B-1 converged remedy made
concrete: cap-check-first, then commit, and the commit path is unconditionally followed by a
real dispatch (never a post-commit redirect to `shared_exit`).

**C.1.3 — `bridge_full` and the unarmed branch both reuse the existing ordinary mini-stub
(B-1, B-2).** Both "ledger full" and "slot unarmed" must land on the *exact* current
ordinary-composite behavior: stage `exit_target = shared_exit`, commit nothing new, and
`jmp deopt_exit` (whose tail flushes only carried homes and resumes tier-0 at the static
composite exit PC 29 — cont then runs its own `loop` and branches to 14). Concretely the
stub head is:

    load slot[ei]
    cmp slot, shared_exit
    je  ordinary_mini          ; unarmed -> byte-identical today
    mov rax, [rdx+ledger_len]
    cmp rax, LEDGER_CAP
    jae ordinary_mini          ; armed but full -> B-1 clean yield, no commit
    <armed body: steps 2..7 of C.1.2>
  ordinary_mini:
    mov [rdx+exit_target], shared_exit   ; B-2: stage the field (starts 0 at :736)
    jmp deopt_exit

`ordinary_mini` is the byte-for-byte current ordinary-guard exit (stage `exit_target`, jump
to the shared flush). B-2 is discharged by step "stage the field" being *inside* the shared
path both fall through to, never skipped. Because the whole stub is behind
`cmp slot, shared_exit / je`, an **unarmed** trace executes `load; cmp; je; mov
exit_target; jmp deopt_exit` — the same instruction sequence (modulo one dead compare) as
today, so the increment lands byte-identical exactly like 2.3c-0's inert contracts.

**C.1.4 — Arm/lifetime (B-9, precise).** A new `ArmKind.region_bridge` (`trace.zig:479`).
`armNativeLink(parent=cont, exit_instr=composite_guard_ei, child=skip, .region_bridge)`
derives the target `= skip.ordinary_entry` from `child + kind` (`:3264-3271`, preserving
"derive, never trust a caller address") and writes `slot[ei]` (sole-writer invariant
`:3229`). Extend the `:3268` target `switch` and the loop-done-shape `switch` at `:3248`.
Two *separate* lifetimes, and the round-3 "lifetime is free" claim is corrected to B-9's
split:

- **The in-page machine-code stub is free.** It lives and dies with cont's page, is
  reachable only through the armed slot, and `resetLinksTouching`/`disarmAllLinks`
  (`:3346-3395`) already reset `(parent, slot_index)` to `shared_exit` on either endpoint's
  retirement — no separate free path for the stub.
- **The region-map metadata (C.2.3) is explicit, not free.** It is a heap entry that must
  be (i) replaced atomically on re-arm (old edge dropped before new published), (ii) ordered
  so an OOM while building the map leaves the slot *unarmed* (fail-closed — the stub then
  runs `ordinary_mini`), and (iii) cleaned up in `resetLinksTouching`/`removeTrace`
  alongside the slot reset. State both lifetimes explicitly in P-EBP-2; do not describe the
  map as falling out "for free."

##### C.2 — Persistent VM-level region table + logical window (B-4)

**C.2.1 — The accumulator is VM-persistent, never trace-transient (B-4v).** Round-3 put the
region accumulator "in `TraceState`" and listed "flush on region retirement" as a boundary.
Both are wrong under `gc_stress`: trace retirement is a GC-physical event, so flushing the
accumulator there makes a region gate under `gc_stress on` and not off → matrix divergence.
Corrected contract: a **persistent VM-level region table**, `region_profit:
AutoHashMap(RegionKey, RegionAccum)`, owned by the VM (proto/VM lifetime, allocated from the
VM allocator per Rule Z-4), **not** by any `Trace` and **not** reset on trace retirement.
`RegionAccum = { outer_traversals: usize, window_base: usize, active_frame_depth: u32 }`.
When a region's owning trace retires, its slot disarms (C.1.4) but the table entry
**persists** (a re-armed region resumes its accumulator); the entry is dropped only on
proto teardown / VM deinit, never on a GC cycle. This is the determinism fix — the table's
lifetime is a *logical* program property, independent of physical trace churn.

**C.2.2 — Flush only on logical boundaries; retirement is NOT one (B-4v).** `accountRegionProfit`
(the penalty/gate half, A.2.1) fires — and resets `window_base` — only when:

- `outer_traversals - window_base >= N` (a logical window of `N` normalized outer
  traversals; C.2.4 fixes `N`), OR
- **genuine region exit**, defined stack-safely in C.2.3, OR
- program/frame teardown of the region's root frame.

It fires **never** on: `LEDGER_CAP`/hop exhaustion + re-entry (a forced yield is mid-region,
C.1.3), native-call return, GC safepoint exit (Antigravity's `gc_stress` corollary — a GC
safepoint is not a region-burst exit), or trace retirement (C.2.1). Accounting equivalence
is assertable across the **6 `record+exec-* × gc_stress` modes** only (trace-off /
record-only run no traces).

**C.2.3 — "Region exit" is stack-depth-gated, not PC-membership alone (B-4ii).** Round-3's
"control reaches a PC outside the region's membership" mis-fires on nested calls: a call out
of the region's body leaves the region PCs while still logically inside the region. Corrected
definition — a **genuine region exit** requires BOTH:

- the current bytecode PC is outside the region's membership PC-set (A.2.4 map), AND
- the current stack depth `<=` the region root frame's depth (`active_frame_depth`, recorded
  when the accumulator's window opened).

A call deeper than the root frame that leaves the membership PC-set is **not** an exit (we're
in a callee, the region resumes on return). Only a PC outside membership *at or above* the
root frame — the outer loop genuinely fell through / broke — flushes. `active_frame_depth`
is the VM call-stack depth at window open, a deterministic function of the instruction
stream.

**C.2.4 — `N`, window-crossing, re-entrancy (B-4iii/iv).** `N = min_useful` (= 8) outer
traversals: one window == one gating decision's worth of the unit `min_useful` is already
denominated in. Window-crossing has no remainder problem because `window_base` is *absolute*
(`outer_traversals` is monotonic per region activation), so a flush at `>= N` sets
`window_base = outer_traversals` and the next window measures the *next* `N` from there;
partial progress is simply carried in the running counter, never dropped. Re-entrant /
recursive activation (B-4iv): `RegionKey` includes the activation discriminator so a
recursive self-call opens a *distinct* accumulator (C.2.5) — one `RegionKey` never conflates
two live activations.

**C.2.5 — `RegionKey` (identity + activation).** `RegionKey = { owner: AnchorKey(proto,14),
activation: FrameId }` where `FrameId` is the region-root frame's deterministic stack
identity (depth + call-site PC — the same value already available to the tier machinery, not
a clock/address). The owner `AnchorKey` gives the gate blast radius (A.2.3, gates every
sibling anchored at PC 14 uniformly); the `activation` field separates re-entrant
activations. A non-recursive region (nsieve) has exactly one live activation at a time, so
this collapses to today's single-accumulator behavior.

##### C.3 — Tier-independent membership + classifier (B-4i, B-6)

The accumulator must be updated *identically* by all three execution tiers (native
`replayLedger`, tier-1a dispatcher, unlinked per-segment scalar), or the same logical
traversals produce different gates across the matrix. Two tier-independent sources:

**C.3.1 — Membership from the map, not from `LedgerKind` (B-4i, B-6).** Tier-1a and unlinked
paths never arm, so they can't obtain a `RegionKey` "at arm time," and `LedgerKind` exists
only in native receipts (`irinterp.zig:154`). Define membership + classification off data
all tiers already have: the **(proto, PC) region membership map** (A.2.4), which is a pure
function of the recorded traces, populated at region-discovery/arm time but *readable by any
tier*. Every tier, at each side exit it accounts, looks up the exiting `(proto, exit_pc)` in
the membership map to decide (a) whether this exit is inside a known region, and (b) which
normalized-unit class it is:

    classifyExit(proto, exit_pc) -> enum { outer_composite, inner_completion, neutral }

- `outer_composite` — the exit PC is the region's outer composite guard / skip self-loop
  (adds `local` normalized outer traversals),
- `inner_completion` — the exit PC is the region's inner loop-done continuation edge (adds
  `1`),
- `neutral` — `.link`/prologue-fail/inside-inner-body (adds `0`).

This is the tier-independent replacement for A.2.2's `LedgerKind` switch. The native path may
*additionally* carry `LedgerKind` for its own drain disambiguation, but the *accounting
classification* is derived from `(proto, exit_pc)` so tier-1a and unlinked classify the
identical exits identically. B-6 discharged: the classifier is one function of `(proto,
exit_pc)`, and its call sites are exactly the three `onSideExit`/`accountTraceRun` sites per
tier (native `replayLedger` per ledger entry `trace.zig:2047-2068`; tier-1a dispatcher
per-hop; unlinked scalar tail `trace.zig:1815-1827`).

**C.3.2 — `accountTraceRun` keeps the synthesized `completed` (B-8).** The A.2.1 split's
selection half must pass the *synthesized* count the current code uses, not raw `local`. At
the linked one-trip site `replayLedger` calls `onSideExit(owner, if (local > 0) local else 1)`
(`trace.zig:2068`, the `max(local,1)` synthesis); `accountTraceRun` must receive that same
synthesized value so coverage + `hit_count` selection stay byte-identical. Only
`accountRegionProfit` consumes the *normalized* region unit (C.3.1); the two halves take
different arguments and neither is the raw ledger delta.

##### C.4 — Successor live-through set (B-5)

The A.1.2 fail-closed rule checked only `skip.entry` slots, missing live-through state (r2 —
count+1 — is not loaded by skip but must survive into cont's later `count` read). Define, per
region edge, the **successor live-in ∪ live-through set** `S`:

- `live_in(skip)` = `skip.entry` (`trace.zig:636`), the slots skip reads at its
  `ordinary_entry`, PLUS
- `live_through(edge)` = slots not read by skip but read by *any* trace downstream of skip in
  the region before their next definition — for the nsieve edge, r2 (cont's `count`
  accumulator, read again at the next cont run).

Arm-time validation (fail-closed): for every slot in `S`, require it to be either (i)
invariant/coherent in `regs[]` at the composite exit (never destructively overwritten between
window entry and the guard), or (ii) fed by a *dominating* phi (`update_index < guard_index`)
that the bridge commits. If any slot in `S` is fed by a *post-guard* (undefined-on-this-edge)
phi, the region is **not armable** — decline the arm; the stub then permanently runs
`ordinary_mini` (C.1.3). `live_through` is computed from the region's trace set at
region-discovery time (all member traces are known then), so it is available at arm-time
validation. For nsieve `S = {r4,r0,r6,r3,r5} ∪ {r2}`; r4/r0/r5 are invariant (i), r3/r6 are
dominating-phi committed (ii), r2 is dominating-phi committed (ii) — all pass.

##### C.5 — Replay owns the resume PC (B-7)

`LedgerEntry` carries no child anchor / resume PC (`irinterp.zig:193`). The `.region_bridge`
replay arm (A.3) must **derive skip's resume PC from the validated live region edge**, not
from the ledger entry. Contract: on decoding a `.region_bridge` entry, `replayLedger` looks
up `(entry.id /*=cont*/, entry.exit /*=composite guard ei*/)` in the region-membership map,
validates the edge is live and its `child_anchor` is `skip@14`, and takes the resume PC =
`child_anchor.pc` (14) for the dispatched case, or — for a `.yielded` outcome (the C.1.3
`bridge_full` path never commits, so it never emits `.region_bridge`; a `.yielded` here can
only arise from a genuinely armed-and-committed entry that then found the ledger full at the
*next* hop) — the same `child_anchor.pc`, because the bridge already materialized `regs[]`
coherent for skip before the yield. The resume PC is thus a property of the *edge*, owned by
replay via the map, and is validated (`@panic` on an unregistered/mismatched edge, matching
the drain's existing unexpected-shape panics). This makes B-7 part of the replay contract and
removes any "no static way to carry PC 14" hazard (B-1's tail).

##### C.6 — What is unchanged from round 3

For the record, round-3 contracts that survive round 4 verbatim (do not re-litigate in
review): A.1.1 (which guard, coherence asymmetry), A.1.2 (dominance snapshot + `{r2,r3,r6}`),
A.1.3 (`ordinary_entry` guard re-run, VM-slot-list ABI, `inputs.len==0`), A.2.1 (split), A.2.2
(normalized unit — now *sourced* tier-independently per C.3.1 but the *unit* is identical),
A.2.3 (`RegionKey` owner `AnchorKey(proto,14)` — now *extended* with the activation
discriminator per C.2.5), A.2.4 (identity/edge membership map — now also the tier-independent
classifier source), A.3 (additive `.region_bridge` grammar leaving `3098`/`2159` intact), A.4
(`min_useful` retune is a bridge-landing obligation; `N = min_useful` per C.2.4 makes the
logical window load-bearing for correctness, not just determinism).

**Net of round 4:** every B-item has a concrete, code-anchored contract — B-1/B-2
cap-check-first stub reusing `ordinary_mini` (C.1.2/C.1.3); B-3 generic trace-local stub
armed later (C.1.1, Bart's fork (b)); B-4 persistent VM-level region table + stack-depth-gated
logical window + activation-keyed `RegionKey` (C.2); B-5 successor live-in ∪ live-through set
(C.4); B-6 tier-independent `(proto, exit_pc)` classifier at all three accounting sites
(C.3.1); B-7 replay-owned resume PC via the edge map (C.5); B-8 synthesized `completed`
preserved in `accountTraceRun` (C.3.2); B-9 stub-free / map-explicit split lifetimes (C.1.4).
Ready for a fresh codex `gpt-5.6-sol` + Antigravity review; still no code until that review is
clean.

#### Review outcome — round 4, codex `gpt-5.6-sol` + Antigravity (gemini-3.1-pro), 2026-07-17: BLOCKER (both)

Both reviewers **confirm the direction is sound** and that round 4 resolved the majority of the
nine. codex marks **B-2, B-5, B-7, B-8, B-9 RESOLVED** and **B-1, B-3, B-4, B-6 STILL-BLOCKER**;
Antigravity marks **B-1..B-8 RESOLVED** and **B-9 STILL-BLOCKER** (codex is the stricter reviewer
and caught concrete code-grounded defects Antigravity missed — trust codex on the overlaps). The
surviving blockers, deduped and given a unifying theme:

**Unifying theme both reviewers circle: split the LOGICAL layer from the PHYSICAL layer.** The
logical region definition (membership, profit accumulator, classifier) must be a pure function of
the recorded trace graph, owned at **Proto/VM lifetime**, readable by every tier, and **never
mutated by trace retirement**; the physical armed-edge (slot + `NativeLink`) metadata is the only
thing retirement-cleaned. Round 4 conflated the two in several places. The specific must-fix items
for a **round-5 pass** (labelled D-n):

- **D-1 (B-1, codex) — cap-check off-by-one.** `jae LEDGER_CAP → bridge_full` still lets
  `ledger_len == CAP-1` commit its own `.region_bridge` entry (filling the ledger) and then
  dispatch to the child, whose terminal append is silently dropped (`nativegen.zig:3301`) while
  the terminal ledger entry still describes the *parent* bridge — violating the terminal-consistency
  tripwire (`:779`) and the scalar final-trace contract (`:568`). Fix: the bridge must reserve **two**
  cells (its own entry + a successor terminal) → threshold `ledger_len >= LEDGER_CAP - 1 →
  ordinary_mini`; prove `len <= CAP-1` on stub entry as an invariant (every armed dispatch leaves ≥1
  free cell; base case call-start `len=0`), so `ordinary_mini`'s single terminal append (`:4616`) is
  always safe and never followed by a dispatch. Also retain the existing `exit_instr` write (`:4560`).
- **D-2 (B-3, codex) — separate compile-time set E from arm-time set S.** C.1.1/C.1.2 still smuggle
  arm-time facts into compile time: (i) candidate eligibility references C.4's `live_through`, which is
  an *arm-time* region-set computation — eligibility must reference only the **parent-trace-local
  emitted snapshot set E** (this trace's dominating phi-updates, `update_index < guard_index`); (ii)
  `inputs.len == 0` is a **child** (skip) property checkable only at arm time, not `t.inputs.len` at
  compile time; (iii) `mov final_trace_id, child.id` is impossible for a generic immutable stub *and
  unnecessary* — the child's own `emitReturn` (`nativegen.zig:3249`) stamps its id on exit; drop the
  step. Contract: compile emits E from the parent trace alone; arm-time validates the required
  successor set **S ⊆ E ∪ coherent-invariants** (C.4) and the child's `inputs.len == 0`.
- **D-3 (B-4, codex) — four accounting-state defects.** (a) Window remainder rule is wrong: a flush at
  `>= N` must advance `window_base += N` (possibly repeatedly), **not** jump to the current total —
  jumping discards the remainder and changes gate state. (b) `RegionKey` lost its identity component:
  `{AnchorKey, activation}` aliases two sibling regions that share anchor `(proto,14)`; the accumulator
  must be keyed by an **identity/edge-based `region_id`** (the A.2.4 map), with `AnchorKey(proto,14)`
  retained only as the *gate* blast-radius key. (c) `FrameId = depth + call-site PC` is not a real frame
  identity — frames carry no generation/id and depths/slots are reused (`interp.zig:327/1346/2364`); do
  not invent one. (d) Membership is still "populated at arm time," but tier-1a never arms
  (`trace.zig:1797` native-only) — logical region **discovery must run from the recorded trace graph in
  every tier**; native arming consumes that definition, never creates it. And region-exit detection must
  use identity/edge, not a bare PC-set (siblings share a PC).
- **D-4 (B-6, codex) — classifier keyed by `(trace_id, exit_instr)`, not `(proto, exit_pc)`.** Sibling
  traces record *opposite* guards at the same source bytecode PC (`skip.guard_false` vs
  `cont.guard_true`) → different normalized classes, identical `(proto, exit_pc)`. Use exact logical
  exit identity `(trace_id, exit_instr)` → registered region edge/class; all tiers have it (native via
  `LedgerEntry`, tier-1a via entered trace + `ExecResult.exit_instr`). Also: the selection/accounting
  split must apply at **every** `onSideExit` call site (replay arms `trace.zig:2068`, `driveChain`
  tails `:1815`, direct dispatcher exits `interp.zig:2852/3010`, other scalar burst paths), not one
  nominal site per tier.
- **D-5 ‡ (B-9, both — the convergent determinism fix) — logical region map is Proto/VM-owned, NEVER
  retirement-cleaned.** Round 4's C.1.4(ii) cleans region-map metadata in `resetLinksTouching`/
  `removeTrace`; but retirement is a GC-physical event, so under `gc_stress on` a retired inner trace
  drops its membership PC while `gc_stress off` keeps it → the region-exit check diverges → gate
  divergence. Fix: the **logical region definition/membership/profit** map persists for Proto/VM
  lifetime and is cleaned only at proto teardown; **only** the physical armed-edge registry (slot +
  `NativeLink`) is retirement-cleaned. Keep the two maps strictly distinct.
- **D-6 (minor precisions).** B-2: restate "byte-identical" as *VM-state/output* equivalent, not literal
  mcode bytes (the unarmed path adds a dead load/cmp/branch). B-5: state the live-through set is a
  fixed-point over cycles and arming requires S ⊆ E. B-7: the C.5 `.yielded` `.region_bridge` prose is
  inconsistent with C.1.2 (the bridge has no post-append forced-yield, so its own entry is never
  `.yielded`; the *next* hop owns any yield) — correct after D-1.

**One genuine architecture fork for round 5 (D-3c, Bart's call):** how to handle a region whose root
frame can be **re-entered recursively** (two live activations of the same `region_id` on the stack at
once). Options: (α) **fail-closed exclude** — decline to arm any region whose membership includes a
call back to the region-root proto (recursion detectable from the trace graph), exactly as
`inputs.len != 0` is already excluded; nsieve is non-recursive so this unblocks the target with zero
activation-discrimination machinery, and it is reversible later. (β) **build activation discrimination**
— a deterministic per-activation accumulator (needs a real frame-activation identity the VM does not
currently carry, per D-3c). This is a scope decision, not a correctness one.

**Net of round 4 review:** direction reconfirmed sound; five converging must-fix items (D-1..D-5) +
minor precisions (D-6), all code-grounded, unified by "logical layer persists at Proto/VM lifetime and
is identity/edge-keyed; physical armed-edge layer is the only retirement-cleaned thing." One scope fork
(D-3c recursion) is Bart's call. Still no code.

#### Part A — round-5 design (2026-07-17): D-1..D-6 resolved

This subsection discharges D-1..D-6 and is the **design of record**, superseding round-4
wherever they conflict below (chiefly C.1.1/C.1.2 eligibility + `final_trace_id`, C.1.4/C.2.4
map lifetime, C.2.5 `RegionKey`, C.3.1 classifier key). Everything round 4 got right —
cap-check-first structure (C.1.2/C.1.3), the `ordinary_mini` reuse, `ArmKind.region_bridge`,
the persistent-not-transient accumulator direction, stack-depth-gated region exit (C.2.3),
the tier-independent-classifier *goal*, the successor live-through *set* (C.4), replay-owned
resume PC (C.5), synthesized `completed` (C.3.2) — **stands** and is not re-derived. Grounding
reads added: `interp.zig:320-350` (`CallFrame` — no generation/id field), `:1346` (frame
setup), `:2364` (frame pop); `nativegen.zig:3301` (append drop-if-full), `:3332` (existing
chain source's post-append forced-yield refusal), `:568/779` (scalar final-trace + terminal
tripwire), `:3249` (`emitReturn` stamps the exiting trace's own id), `:4560/4616` (ordinary
guard `exit_instr` write / `deopt_exit` append); `trace.zig:442` (`guardExitPc`), `:562`
(`GuardKey` = anchor + exit), `:621/636` (`inputs`/`entry_slots`), `:1982` (replay strict
id-resolution), `:2064-2068` (loop-done resume-PC derivation + synthesized `max(local,1)`),
`:3272/3288/3346/3381/3397` (registry arm/append/reset/disarm/cleanup ordering);
`irinterp.zig:200` (`LedgerEntry` carries `id` + `exit`, no PC).

**Bart's decision on the D-3c fork: (β) build activation discrimination.** Round 5 introduces
a deterministic per-activation frame identity (D.3.3) so recursive re-entries each open a
distinct accumulator; the general case is handled from day one rather than fail-closed-excluded.

##### D.1 — Cap-check reserves TWO cells (B-1)

The round-4 `jae LEDGER_CAP → bridge_full` is off by one: at `ledger_len == CAP-1` the bridge
would append its own `.region_bridge` entry (filling the ledger to `CAP`) and *then* dispatch
to the child, whose terminal append is silently dropped (`nativegen.zig:3301`) while the
terminal entry still describes the *parent* bridge — violating the terminal-consistency
tripwire (`:779`) and the scalar final-trace contract (`:568`). Corrected contract:

- **Threshold reserves two cells** (bridge entry + a successor terminal): the armed body is
  taken only when `ledger_len <= CAP - 2`; `ledger_len >= CAP - 1 → ordinary_mini`.
- **Invariant (state + prove in P-EBP-2): on entry to any exit stub, `ledger_len <= CAP-1`
  (at least one free cell).** Base case: a native call starts with `ledger_len = 0`
  (trampoline-zeroed). Inductive step: the armed bridge path requires `<= CAP-2` and appends
  one → leaves `<= CAP-1` for the successor stub; the `ordinary_mini` path appends one
  terminal entry (`:4616`) → `<= CAP` and **does not dispatch** (it is a tier-0 resume), so no
  successor stub sees `CAP`. Hence `ledger_len == CAP` is unreachable at a stub, and every
  append is safe. This is the same discipline the existing chain source uses at `:3332`
  (refuse dispatch when the append fills the ledger), applied to the bridge with the check
  *before* any commit so nothing is committed on the yield path.
- **Retain the `exit_instr` write** (`nativegen.zig:4560`) on the unarmed/`ordinary_mini`
  path — it is part of today's ordinary-guard exit and must not be dropped.

##### D.2 — Compile-time emitted set E vs. arm-time required set S (B-3)

Round-4 C.1.1/C.1.2 still leaked arm-time facts into compile time. Split cleanly:

- **Compile-time (native lowering, `*Trace` only): emit the snapshot set `E`.** `E` = the
  parent trace's **dominating phi-update set** — every phi whose update-value instruction has
  `update_index < guard_index` at the composite guard, computable from this trace's IR alone
  (`isCompositeBridgeCandidate(t, ei)` = ordinary guard ∧ same-proto outer re-test ∧ `E`
  non-empty). The stub commits exactly `E`. **No reference to `live_through`** (that is the
  arm-time region-set computation of C.4) and **no reference to any child**.
- **Drop `mov final_trace_id, child.id` entirely.** A generic immutable stub cannot know the
  child id, and it is unnecessary: once the bridge dispatches into the child, the child's own
  exit stub stamps `final_trace_id` via `emitReturn` (`nativegen.zig:3249`). The bridge writes
  only `completed`, the ledger append, and `exit_target`.
- **Arm-time (has the region map + child): validate `S ⊆ E ∪ invariants` and the child.**
  The required successor set `S` (C.4 live-in ∪ live-through) must be **covered by the
  compile-time-emitted `E`** or by slots invariant/coherent in `regs[]` at the exit; and the
  **child's** `inputs.len == 0` is checked here (round-4's `t.inputs.len` tested the wrong
  trace). If `S ⊄ E ∪ invariants` or `child.inputs.len != 0`, decline the arm (fail-closed →
  the stub permanently runs `ordinary_mini`). This is the round-3 fail-closed rule made
  temporally honest: the *commit* set is fixed at compile time; arming only ever *chooses
  whether* to use a stub whose behavior is already baked.

##### D.3 — Accounting state machine + three-map split + activation identity (B-4)

**D.3.1 — Three distinct structures (this is the unifying fix).** Round 4 conflated the
logical region definition, the profit accumulator, and the physical armed edge. Separate them:

1. **Logical region DEFINITION** — `region_defs: Map(RegionId, RegionDef)` where `RegionDef =
   { members: set of (trace_id, exit_instr) edges + membership PC-set, owner: AnchorKey(proto,
   root_pc), classifier }`. A **pure function of the recorded trace graph**, owned at
   **Proto/VM lifetime**, populated at region discovery, **never mutated by trace retirement**
   (D.5). Readable by every tier (native, tier-1a, unlinked).
2. **Per-activation profit ACCUMULATOR** — `region_profit: Map(RegionKey, RegionAccum)`,
   `RegionKey = { region_id: RegionId, activation: u64 }`, `RegionAccum = { outer_traversals,
   window_base, root_frame_depth, root_call_seq }`. Created when a region window opens at an
   activation; **dropped on genuine region exit** (D.3.4) — a *logical* boundary, so live
   entries are bounded by the region's live recursion depth, not total activations ever. Owned
   by the VM (allocated per Rule Z-4), but its lifetime is keyed to *logical* region
   enter/exit, never to trace retirement or GC.
3. **Physical armed-edge REGISTRY** — the existing `armed_links` (`NativeLink` per
   `(parent, slot)`), retirement-cleaned by `resetLinksTouching`/`disarmAllLinks` (unchanged).

**D.3.2 — `RegionId` is identity/edge-based, `AnchorKey` is only the gate key.** Round-4
`RegionKey = {AnchorKey, activation}` aliases two sibling regions that share anchor
`(proto,14)`. Fix: `RegionId` is an identity assigned per discovered region (its edge set is
its identity); the accumulator keys on `RegionId`. `AnchorKey(proto, root_pc)` is retained
**only** as the gate/penalty blast-radius key (A.2.3: gating `(proto,14)` ungates every
sibling anchored there uniformly), read by `accountRegionProfit` when it flushes — it is *not*
the accumulator key.

**The equality key is the full sorted edge SET, not a hash (round-2 review, R2-3).** `RegionId`
is interned: at discovery, the region's structural edges — each a `(StructuralEdgeId)` =
`(source_proto_id, source_pc, role, selected-CFG-edge)` per D.4, **not** raw `(trace_id,
exit_instr)` which is tier-/retirement-unstable — are collected, **sorted into a canonical
order**, and looked up in a `region_intern` map. A 64-bit hash of that sorted set only
**accelerates** the bucket lookup; a hash *hit* is confirmed by **full sorted-set equality**
before reusing the existing `RegionId`, and a genuine collision (equal hash, unequal set) mints a
distinct `RegionId`. So two regions are the same iff their structural-edge sets are equal — the
hash is never the identity. This keeps `RegionId` stable across trace retirement/re-record (the
structural edges are guest-logical, D.4) and across all 6 `record+exec-* × gc_stress` modes.

**D.3.3 — Deterministic activation identity (Bart's fork β).** `CallFrame` (`interp.zig:327`)
carries no generation/id and frame slots/depths are reused (`:1346/2364`), so depth alone
cannot distinguish two live activations. Add a **per-VM monotonic `call_seq: u64`**, assigned
to each `CallFrame` at push time from a VM counter that increments once per call. `call_seq` is
a **pure function of the executed call stream** — GC adds/removes no calls, so at any logical
program point the counter value is identical across all `gc_stress` modes (determinism-safe;
it is a deterministic counter, not a clock/address, the same class as the direct-mapped
hotcount). `RegionKey.activation = root_call_seq`, snapshotted from the region-root frame when
the accumulator's window opens. A recursive re-entry pushes a new frame with a fresh `call_seq`
→ a distinct `RegionKey` → a distinct accumulator; no conflation. The counter is `u64`
(non-wrapping in practice) and is **not** itself a table key over all history — only live
accumulators key on it, and they are reclaimed at region exit (D.3.4), so no unbounded growth.

**D.3.4 — Flush + drop only on logical boundaries (window `+= N`, stack-gated exit).**
`accountRegionProfit` fires — advancing `window_base` and, on genuine exit, dropping the
accumulator — only when:

- `outer_traversals - window_base >= N` (`N = min_useful = 8`). **Advance `window_base += N`,
  possibly repeatedly** (round-4's "jump to the current total" discarded the remainder and
  changed gate state); i.e. `while (outer_traversals - window_base >= N) { flush one window;
  window_base += N; }`. The remainder `< N` is carried in the running counter, never dropped.
- **genuine region exit** — the current bytecode PC is outside the region's membership PC-set
  **AND** the current stack depth `<= root_frame_depth` (recorded at window open). A call
  deeper than the root frame that leaves membership PCs is **not** an exit (callee; region
  resumes on return); only a fall-through/break at or above the root frame flushes the final
  partial window and **drops** the accumulator entry (reclaiming its `RegionKey`).
- program/frame teardown of the region-root frame.

Fires **never** on: `LEDGER_CAP`/hop exhaustion + re-entry (mid-region forced yield),
native-call return, **GC safepoint exit** (not a region-burst exit — the `gc_stress`
corollary), or **trace retirement** (a GC-physical event; D.5). Accounting equivalence is
assertable across the **6 `record+exec-* × gc_stress` modes** only.

**D.3.5 — Membership is discovered from the recorded trace graph in every tier.** Round-4
"populated at arm time" is wrong: tier-1a and unlinked never arm (`trace.zig:1797` is
native-only). Region **discovery** is a pure function of the recorded traces (the edge set +
membership PC-set), run whenever the trace graph gains an edge that closes a region — available
identically to all tiers because it reads only recorded-trace structure. Native *arming*
consumes a discovered region (to install the bridge slot) but never *creates* the definition.
Region-exit detection uses the membership PC-set for the "outside region" test but the
per-edge **identity** (D.4) for classification, so sibling traces sharing a PC are not
confused.

##### D.4 — Classifier keyed by `(trace_id, exit_instr)` + split at every site (B-6)

Round-4 `classifyExit(proto, exit_pc)` is insufficient: sibling traces record *opposite*
guards at the same source bytecode PC (`skip.%012 guard_false` vs `cont.%023 guard_true`) — same
`(proto, exit_pc)`, different normalized class. Use the **exact logical exit identity
`(trace_id, exit_instr)`** → registered region edge → class:

  `classifyExit(trace_id, exit_instr) -> { outer_composite (+= local) | inner_completion (+= 1)
                                          | neutral (+= 0) }`

All tiers possess `(trace_id, exit_instr)`: native via `LedgerEntry` (`id` + `exit`,
`irinterp.zig:200`), tier-1a via the entered `*Trace` + `ExecResult.exit_instr`, unlinked
likewise. This mirrors the identity strength the tree already uses (`GuardKey` = anchor + exit,
`trace.zig:562`; replay's strict id-resolution, `:1982`). **The `accountTraceRun` /
`accountRegionProfit` split must be applied at *every* `onSideExit` call site**, not one
nominal site per tier — enumerated: the `replayLedger` arms (`trace.zig:2068`, …), the
`driveChain` tails (`:1815-1825`), the direct dispatcher productive/zero-progress exits
(`interp.zig:2852/3010`), and the remaining scalar burst paths. Each site calls
`accountTraceRun` (selection, unchanged) and, when `classifyExit` places the exit in a known
region, updates the per-activation accumulator via the tier-independent classifier.

##### D.5 — Logical map is Proto/VM-owned, NEVER retirement-cleaned (B-9, ‡ both)

The convergent determinism fix. Round-4 C.1.4(ii) cleaned region-map metadata in
`resetLinksTouching`/`removeTrace`, but retirement is a GC-physical event: under `gc_stress
on` a retired inner trace would drop its membership PC while `gc_stress off` keeps it → the
region-exit test (D.3.4) diverges → gate divergence. Corrected lifetimes:

- **`region_defs` (logical definition, D.3.1-1): Proto/VM lifetime.** Built at discovery from
  the recorded trace graph; cleaned **only** at proto teardown / VM deinit. A trace retiring
  does **not** remove its edges from a region definition (the definition is the logical shape,
  not the live compilation). Re-recording the same trace re-uses the existing definition.
- **`region_profit` (accumulator, D.3.1-2): logical region enter/exit lifetime** (D.3.4) —
  never touched by retirement or GC.
- **`armed_links` (physical, D.3.1-3): retirement-cleaned** — the *only* structure
  `resetLinksTouching`/`removeTrace` touch, exactly as today. On a bridge child/parent
  retiring, the slot resets to `shared_exit` (the stub goes inert) but the region *definition*
  and any *accumulator* persist; a later re-arm resumes them.
- **Atomic re-arm + OOM ordering** (the B-9 explicit-metadata requirement): disarm old slot →
  drop old *physical* edge record → fully build + publish the new physical edge → register the
  dependency → arm the slot **last**; any failure after nothing-published leaves the slot
  unarmed (fail-closed → `ordinary_mini`). The *logical* `region_defs` entry is built once at
  discovery and is not part of this per-arm dance.

##### D.6 — Minor precisions (B-2/B-5/B-7)

- **B-2 wording.** The unarmed bridge path is **VM-state / output equivalent** to today's
  ordinary-composite exit, **not** literal-mcode-byte identical — it adds a dead
  `load slot; cmp shared_exit; je` prefix and stages a constant `shared_exit` rather than the
  loaded slot value. The increment lands with *behavior* byte-identical (the gate the whole
  arc uses), which is what "byte-identical" has always meant here; state it as such.
- **B-5.** The `live_through(edge)` computation is a **backward-liveness fixed point over the
  region's cycles** (all member traces known at discovery); arming requires `S ⊆ E ∪
  invariants` (D.2) — restate the C.4 rule with the fixed-point + `E`-coverage condition
  explicit.
- **B-7.** Correct the C.5 `.yielded` prose: the bridge has **no** post-append forced-yield
  (D.1 checks the cap *before* committing), so a `.region_bridge` entry is **never** stamped
  `.yielded` by its own stub — a forced yield is always owned by the *next* hop's stub. The
  replay resume-PC derivation (look up `(entry.id, entry.exit)` in `region_defs`, validate the
  live edge, take `child_anchor.pc`) stands.

**Net of round 5:** D-1 two-cell reservation + unreachable-`CAP` invariant; D-2 compile-time
`E` / arm-time `S ⊆ E ∪ invariants`, `final_trace_id` write dropped, child `inputs.len==0`
checked at arm time; D-3 three-map split, identity `RegionId`, deterministic per-VM `call_seq`
activation identity (Bart's β), window `+= N`, stack-gated exit, discovery from the trace graph
in every tier; D-4 `(trace_id, exit_instr)` classifier + split at every `onSideExit` site; D-5
logical `region_defs`/`region_profit` at Proto/VM & logical-boundary lifetimes, only
`armed_links` retirement-cleaned; D-6 wording/fixed-point/`.yielded` precisions. Ready for a
fresh codex `gpt-5.6-sol` + Antigravity review; still no code until that review is clean.

#### Review outcome — round 5, codex `gpt-5.6-sol` + Antigravity (gemini-3.1-pro), 2026-07-17: BLOCKER (both)

Both **RESOLVED D-1, D-2, D-6** (codex verified the two-cell induction against the real append
sites `nativegen.zig:736/3332/4516/4591/4616/4669`, the `emitReturn` id-stamp at `:3249/4622`,
and the fixed-point/`.yielded` corrections). The surviving blockers are **not** flaws in the
edge-4 bridge — they are cross-cutting **integration surfaces the round-5 machinery pulls in**:
the `call_seq` + logical-map design colliding with `Trace.id` lifetime, the keyframe/replay
schema, coroutines, error-unwinding, and trace-inlining. codex marks D-3/D-5 NEW-ISSUE and D-4
STILL-BLOCKER; Antigravity marks all D-1..D-5 resolved but raises four must-fixes of the same
character. Consolidated round-6 items (E-n):

- **E-1 ‡ (codex D-3/D-5) — `RegionDef` must NOT be keyed by `Trace.id`.** The persistent
  `region_defs` is Proto/VM-lifetime, but its `members` set is `(trace_id, exit_instr)` and
  `Trace.id` is *ephemeral* — a re-recorded logically-identical edge gets a NEW id
  (`trace.zig:3841`) after retirement (`:3397`), so it won't match the persistent def (and any
  "rediscover a replacement" repair reintroduces retirement/GC-timing dependence — the exact
  leak D-5 was meant to remove). Fix: **two identities** — (i) a stable *structural/logical*
  edge identity (proto + bytecode anchor + target proto/pc, no `Trace.id`) keying persistent
  `region_defs`; (ii) an *ephemeral* `(Trace.id, exit_instr) → logical-edge/RegionId` lookup,
  rebuilt on trace commit, removed on retirement. This is the load-bearing fix — E-3/E-4/E-5
  all lean on it.
- **E-2 ‡ (codex D-3 + Antigravity MF1) — `call_seq` cannot be a purely physical
  `CallFrame`-push counter, because tracing inlines cross-frame calls.** The recorder supports
  cross-frame execution (`trace.zig:4014`), so a native/traced run may *not* push a `CallFrame`
  where the interpreter does → `call_seq` would differ by tier, breaking equivalence. Fix:
  either (a) drive `call_seq` off a **tier-independent logical-call event** that native traces
  also fire (and that a deopt reconstructs identically), or (b) **fail-closed decline** any
  region whose root frame can be trace-inlined/elided (establish the root identity
  tier-independently or don't arm). This directly re-weights the D-3c=β decision (see the
  scope note below).
- **E-3 (codex D-4, STILL-BLOCKER) — the `(trace_id, exit_instr)` classifier key is absent at
  synthetic scalar-burst `onSideExit` sites.** `onSideExit(seed, 0)` at `trace.zig:2708/2873`
  (and similar) carry no concrete exit instruction; passing `0` would misclassify as "guard
  zero." Fix: an **optional** classifier key — synthetic accounting events are explicitly
  *unclassified* (region-neutral) — or a separate synthetic-accounting API, or move accounting
  to the concrete exit site before the key is discarded.
- **E-4 (codex D-3) — overlapping-PC region exit.** Distinct `RegionId`s don't fix leaving
  region A for a *sibling* region B that shares A's `(proto, pc)` membership: A's accumulator
  stays open (PC still "inside A") across distinct episodes. Fix: **a transition to an
  edge/region identity outside the active region is a genuine exit even when the destination PC
  overlaps** the old membership. Boundedness (accumulator drop-on-exit) depends on this.
- **E-5 ‡ (both — the snapshot obligation) — keyframe capture/restore for the new state.** A
  keyframe captured mid-region and restored loses `call_seq`, the VM next-call counter, and any
  live `region_profit` accumulator unless they are serialized — silently preserving them in the
  original VM but dropping them on restore is non-deterministic replay. codex: `CallFrame` has
  no field (`interp.zig:327`), `FrameRef`/schema don't carry it (`schema/trace.json:163`,
  `keyframeser.zig:274/671`), format is still v4 (`:59`). Fix: add `call_seq` to every
  serialized frame + the VM counter + the active `region_profit` entries to the snapshot, with
  a **format version bump (v4→v5)** — *or* define snapshot capture as a **logical region reset
  performed identically in both the original and restored timelines** (cheaper, if a mid-region
  reset is accounting-neutral).
- **E-6 (Antigravity MF2) — coroutine thread-scoped depth.** lune has coroutines
  (thread-local stacks); the region-exit check `stack depth <= root_frame_depth` must be
  evaluated against the **originating coroutine's** stack, or a context switch spoofs the depth
  test.
- **E-7 (Antigravity MF3) — error-unwind cleanup.** `pcall`/`xpcall` stack unwinding must drop
  active `region_profit` entries whose root frames unwind (leak + stale-state contamination);
  and `__gc` finalizers must not run guest code at non-deterministic points (defer to
  deterministic step boundaries) — a determinism note.

**Scope re-weighting of the D-3c=β decision (Bart's re-call, prompted by E-2/E-5).** When Bart
chose (β) "build activation discrimination" the visible cost was "add a `call_seq` field." The
round-5 review reveals β's *true* cost: E-2 (tier-independent logical-call event vs.
physical-push counter, because of trace inlining) + E-5 (a v4→v5 snapshot schema bump to
serialize `call_seq` + the VM counter). (α) "fail-closed exclude recursion" avoids **all** of
the `call_seq` machinery — no new frame field, no schema bump, no inlining-invariance proof —
and unblocks nsieve (non-recursive) now, deferring β to when a recursive region actually
appears. **Note the independent floor:** E-1, E-3, E-4, E-6, E-7, and the `region_profit`
half of E-5 are required under *both* α and β (they are general-case obligations of region-level
accounting, not of recursion discrimination) — only E-2 and the `call_seq` half of E-5 are
β-specific. This is a genuine cost/scope decision, surfaced to Bart before round 6.

**RESOLVED 2026-07-17 (Bart): HOLD β — build the general mechanism.** Bart's ruling: "Stop
thinking I care about nsieve. If we can make something more general than nsieve now while still
helping nsieve, just do that — I'm not in the business of building an 'nsieve-optimised
language'." So the D-3c=β decision **stands**, and the operating principle for the rest of Part A
is: always the general, determinism-safe mechanism that *also* helps nsieve, never an
nsieve-special-case. Round 6 therefore builds **all** of E-1..E-7 in their general form — E-2
`call_seq` driven by a **tier-independent logical-call event** (surviving native trace inlining +
deopt frame reconstruction) and E-5 the **v4→v5 keyframe schema** carrying `call_seq` + the VM
counter + live `region_profit` — not the α shortcut.

**Net of round 5 review:** the edge-4 bridge mechanism (D-1/D-2/D-6) is now sound; the
remaining work is making region-level accounting determinism-safe against `Trace.id` lifetime
(E-1), trace inlining (E-2), synthetic sites (E-3), overlapping regions (E-4), snapshots (E-5),
coroutines (E-6), and error unwinding (E-7). Round 6 folds E-1/E-3/E-4/E-6/E-7 unconditionally
and E-2/E-5 per Bart's α/β re-call. Still no code.

#### Part A — round-6 design (2026-07-17): E-1..E-7 resolved, grounded

Round 6 was preceded by three parallel grounding sweeps of the tree (trace inlining + deopt
frame reconstruction; keyframe/snapshot schema + versioning; coroutine + error-unwind model), so
every resolution below is anchored in real `file:line` rather than assumed. The grounding
produced **one reshaping insight** that collapses the two heaviest round-5 blockers, and it must
be stated first because E-2 and E-5 both hang off it.

**The reshaping insight ‡ — `region_profit` and `call_seq` are transient JIT-tiering state, NOT
replay-serialized VM state.** The keyframe deliberately does **not** serialize the JIT layer:
the trace cache, `safepoint_seq` (`interp.zig:568`, "monotonic count of dispatch-loop
safepoints"), `effect_cursor`/`effect_log` (doc 04:173-176, "the keyframe deliberately does not
carry the log/cursor"), `rng`, and `next_proto_id` (`interp.zig:650`) are **all** either
transient replay-driver state or re-derived on restore — none rides the keyframe (grounding: E-5
sweep of `keyframeser.zig` `encodeSnapshot` `:310-326`, which captures only
`globals_id`/`string_metatable_id`/`objects`/`stack`/`frames`/`open_upvalues`/`loaded_chunks`).
The load-bearing reason they can be omitted is that **none of them affect observable output** —
they only steer *which tier* runs, and native ≡ tier-0 by construction (the whole determinism
premise). `region_profit` (a region's aggregated traversal count) and `call_seq` (an activation
discriminator used *only* to key `region_profit`) are exactly that category: JIT tiering
heuristics whose sole effect is *when* a region tiers up, never *what it computes*. Therefore
they are **runtime-only, reset on restore, same lifetime as the trace cache** — and the keyframe
stays **v4, no schema bump.** This is the reviewers' own round-5 alternative ("define snapshot
capture as a logical region reset performed identically in both timelines, cheaper, if a
mid-region reset is accounting-neutral" — E-5) made rigorous: a mid-region reset *is*
accounting-neutral because the reset quantity never reaches output.

> **‡ Deviation flagged for Bart + round-6 reviewers.** The round-5 resolution note recorded
> "E-5 the **v4→v5 keyframe schema** carrying `call_seq` + the VM counter + live
> `region_profit`." Round-6 grounding shows that bump is not only unnecessary but is the *less*
> general choice — it would couple a JIT tiering heuristic into the replay schema (a layering
> violation), and would add a new `Keyframe` scalar + a map that must be canonically ordered or
> it breaks `encodeSnapshot ∘ restore == identity` (E-5 grounding, `sortedHashEntries`
> `keyframeser.zig:94-109`). Not serializing is *strictly safer* for that byte-identity harness
> (nothing new to order) and more general (JIT state stays out of the schema, exactly as the
> trace cache already does). β (activation discrimination) is **fully preserved** — `call_seq`
> still exists and still discriminates recursive activations; it is simply runtime-only. I did
> **not** silently reverse the recorded resolution: the v4→v5 text stays above as history, and
> this is the follow-up explaining the change (design-doc convention). If Bart or a reviewer
> wants the counters durable across a snapshot boundary, that is the v4→v5 path and it is still
> available — but the grounding says it buys nothing output-visible.

Determinism check for the reset (the claim the reviewers must stress-test): the F2c contract
asserts `out_before ++ out_after == F` (uninterrupted output) **and** the resumed final-state
snapshot is byte-identical to the reference `Sf` (doc 02:304-307, doc 04:120-148). A mid-region
capture→restore resets `region_profit`/`call_seq` to empty/0, so the restored VM may tier its
regions up at a *different instruction* than the uninterrupted run — but every instruction
produces identical output regardless of tier, so `out_after` is byte-identical, and since
`region_profit`/`call_seq` are **not in the snapshot**, they cannot perturb `Sf`'s bytes. The
reset is invisible to both halves of the contract. (Contrast: had we serialized them, we would
have to prove canonical map ordering *and* exact counter reconstruction, or fail the identity
harness — strictly more obligation for zero output benefit.)

With that established:

**E-1 ‡ (resolved) — two identities, and the persistent one is now VM-run-lifetime, not
snapshot-lifetime.** The persistent `region_defs` is keyed by a **structural edge identity** with
no `Trace.id` in it:

```
StructuralEdgeId = { anchor_proto_id: u32, anchor_pc: u32, exit_pc: u32, succ_anchor_pc: u32 }
```

— proto id (stable: `next_proto_id` is monotonic and protos are not freed mid-run,
`interp.zig:650`) plus the bytecode anchor PC, the exit PC, and the successor region's anchor PC.
A re-recorded logically-identical edge (new `Trace.id` at `trace.zig:3841` after retirement at
`:3397`) computes the **same** `StructuralEdgeId` and rebinds to the same persistent def — the
D-5 leak (retirement/GC-timing dependence) is gone because def identity never referenced the
ephemeral id. The runtime exit event still arrives as `(Trace.id, exit_instr)`, so an **ephemeral
lookup** `(Trace.id, exit_instr) → StructuralEdgeId` is rebuilt on trace commit and dropped on
retirement — a pure cache over the structural key, never the source of truth. Because the
reshaping insight removed serialization, this persistent structure only needs stability across
**one VM run's trace-cache lifetime** (flush ⇒ region_defs rebuild alongside the traces), not
across a restore boundary — a strictly smaller obligation than round 5 assumed. E-3/E-4 lean on
this structural key.

**E-2 ‡ (resolved) — the activation key is the *anchor* frame's `call_seq`, which every tier
agrees on because it is assigned in tier-0 before tier-up, and traces never touch it.** The
grounding (trace-inlining sweep) established the mechanism that dissolves the "tiers disagree"
fear:

- `call_seq` is a `u64` on `CallFrame` (`interp.zig:327-350`), drawn from a VM-level monotonic
  `next_call_seq`, bumped at the **single physical frame-push choke point** `pushFrameVararg`
  (`interp.zig:1346`) — which catches *both* the bytecode `.call` handler (`:2229`) and the
  host-reentrant `callValue` path (`:1452`). One choke point, both interpreted call kinds.
- Traces **inline** Lua callees by register-window renaming and push **no** physical `CallFrame`
  (trace-inlining sweep: `recCall` `trace.zig:5011-5080` shifts `base_off`/`inline_depth`, emits
  only a `guard_func`; there is no frame-enter IR op, `recReturn` `:5123-5143` emits nothing).
  So an inlined callee **never gets a `call_seq`** — and does not need one: it is part of the
  **anchor region**, not its own region. Regions are anchored at root PCs **in the anchor proto**
  (exit PCs are always anchor-proto indices: `nativegen.zig:3394-3396/5944`, `trace.zig:468-469`)
  and are entered only from the tier-0 dispatch loop (`tryChainExit`/`driveChain`), at which
  point the anchor frame is physically live on `vm.frames`.
- Therefore the region's activation key = **the anchor frame's `call_seq`**, assigned by tier-0
  at the frame push that created it, *before* the frame ever tiered up. Native execution of that
  region does not re-push the anchor frame and does not mutate `call_seq`, so the key is
  **identical across tier-0, tier-1a, and native** — the exact tier-independence E-2 demanded,
  achieved without a new IR op and without loop-carried commit/restore discipline (the round-5
  worry): **nothing on-trace ever writes `call_seq`.** On deopt the anchor frame persists on the
  tier-0 stack (trace-inlining sweep Q3: side-exit resumes at the loop header with `frames`
  unchanged — "there is no restore-frames path, by construction there is nothing to rebuild"), so
  the key is stable across the region's whole deopt/re-enter lifetime.
- **Fail-closed invariant (asserted, not assumed):** a region we arm must anchor at a frame that
  is physically present in tier-0 (never itself a trace-inlined/elided callee). The grounding
  shows the fusion regions we arm satisfy this by construction (anchor PCs are anchor-proto root
  PCs reached from tier-0). We assert it at arm time — if a candidate region's anchor identity
  cannot be resolved to a live tier-0 frame, **decline to arm** (the α fail-closed guard, kept as
  a guard rail under β, never as the primary path). This is the determinism-safe reading of
  E-2's option (b), retained only as an assertion.

The recursion case β exists for now works with zero extra machinery: each recursive activation of
proto `P` is a distinct `pushFrameVararg` → distinct `call_seq` → distinct `region_profit`
accumulator, purely from physical frame pushes; inlined recursion inside a trace is bounded by
`MAX_INLINE_DEPTH` (`trace.zig:5041`) and stays within the anchor region's single accumulator,
which is correct (it is one traversal of the anchor region).

**E-3 (resolved) — optional classifier key; synthetic accounting events are region-neutral.** The
classifier key becomes `?ExitKey`. The synthetic scalar-burst `onSideExit(seed, 0)` sites
(`trace.zig:2708/2873`) pass `null`, not a fabricated `0` (which would misclassify as "guard
zero"). Region accounting **skips `null`-keyed events** — they are not region edges, so they
neither open nor close nor credit an accumulator. Concrete guard exits carry
`ExitKey{ Trace.id, exit_instr }` and go through the E-1 ephemeral lookup as normal.

**E-4 (resolved) — a transition to any edge/region identity outside the active region is a
genuine exit, even under PC overlap.** Region membership is tracked by **active `RegionId`
identity**, never by PC containment. On each accounted (non-null) exit we resolve the target's
`StructuralEdgeId → owning RegionId` (E-1) and compare to the currently-open `RegionId`: a
mismatch is an exit of A (drop A's accumulator) **and** an entry of B — even when B's destination
PC lies inside A's `(proto, pc)` membership set (the sibling-region-sharing-a-PC case D-3/E-4
raised). Boundedness (accumulator drop-on-exit) holds because "still inside A" is now an identity
test, not a PC test.

**E-5 ‡ (resolved) — no keyframe change; see the reshaping insight above.** `region_profit` and
`call_seq` are not serialized; restore resets them (empty map, `next_call_seq = 0`, per-frame
`call_seq` irrelevant since it is not read from `FrameRef`). Keyframe stays v4; `schema/trace.json`,
`keyframeser.zig`, `src/gen/trace_schema.zig`, `viz/`, and the ~13 round-trip test sites are
**untouched**. The determinism-neutrality argument is the F2c check above.

**E-6 (resolved, largely moot) — no coroutines; the real axis is host re-entrancy depth.** lune
has **no coroutines** (coroutine/error-unwind sweep: `coroutine.*` is `excluded` in the stdlib
inventory, and there is no thread object type; there is a single global `vm.frames`/`vm.depth`).
So the round-5 "evaluate the depth test against the originating coroutine's stack" concern does
not arise. The genuine nuance the sweep surfaced is **host re-entrancy**: native builtins
(`pcall`/`xpcall`, the `table.sort` comparator, `gsub` replacement) re-enter the dispatch loop at
a higher depth via `callValue`, tracked by `native_reentry_depth` (`interp.zig:534`). The
region-exit test "have we returned past the anchor?" must therefore compare against the **anchor
frame's own `depth`** (captured when the region opened), not "outermost" — a re-entrant host call
runs at a deeper `depth` and must not be mistaken for the anchor still being active. Because the
region key is the **activation id** (`call_seq`, E-2), not depth, depth is used *only* for this
"returned past anchor" boundary test, and keying it to the anchor's own captured depth is exact.

**E-7 (resolved) — two teardown hooks; `__gc` moot.** The accumulator must be dropped when its
anchor activation leaves, on both exit paths the sweep identified:

- **Normal return.** `.ret/.halt` pops frames at `interp.zig:2345/2364/2395`. When a frame whose
  `call_seq` owns an open `region_profit` accumulator is popped, its entries are dropped (or the
  activation marked dead and swept). Because `call_seq` is monotonic, a popped activation's key
  can **never** collide with a future activation, so a stale entry is a correctness non-issue —
  the sweep is purely to bound memory, and pairs naturally with the existing round-5 cap/LRU on
  the map.
- **Error unwind.** Errors deliberately do **not** pop `frames` (they stay live so `pcall` can
  describe the fault); the discard happens at the `protectedCall` boundary when it restores to
  `entry_depth` (`stdlib/errors.zig:100-119`). Hook there: drop `region_profit` entries for every
  activation above `entry_depth`. Non-catchable faults (OOM, determinism faults) bypass `pcall`
  and tear down the whole host stack — the accumulator map is freed with the VM, nothing to do.
- **`__gc` — moot.** The GC is a **finalizer-free mark-sweep** (coroutine/error-unwind sweep): it
  runs **no guest code** at a safepoint, so it cannot mutate `region_profit` at a
  non-deterministic point. The round-5 "defer `__gc` to deterministic boundaries" note has no
  subject; recorded here only so a future finalizer feature knows to revisit it.

**Net of round 6.** The edge-4 bridge (D-1/D-2/D-6) is sound; region-level accounting is now
determinism-safe against every integration surface round 5 surfaced — `Trace.id` lifetime
(E-1: structural edge id), trace inlining (E-2: anchor-frame `call_seq`, tier-invariant, no IR
op), synthetic sites (E-3: optional key), overlapping regions (E-4: identity-transition exit),
snapshots (E-5: transient JIT state, no bump), coroutines (E-6: none exist; host re-entrancy
depth handled), and error unwinding (E-7: two hooks, `__gc` moot). The reshaping insight makes
the whole feature **runtime-only JIT state** — which is where region-profit accounting belongs.
β (activation discrimination) is fully preserved and costs one `u64` on `CallFrame` plus one
choke-point bump. Still no code; round-6 review (codex `gpt-5.6-sol` + Antigravity) next, with the
E-5 deviation flagged for explicit stress-testing.

#### Review outcome — round 6, codex `gpt-5.6-sol` + Antigravity (gemini-3.1-pro), 2026-07-17: reshaping insight SURVIVES; BLOCKER on the restore path

**The load-bearing verdict: the reshaping insight is confirmed sound.** codex (which read the
tree) states it directly — *"`region_profit` need not be serialized, and `call_seq` need not
preserve its pre-snapshot numeric values. A v4→v5 schema bump is not inherently required."* The
E-5 deviation flagged for veto is **vindicated: keyframe stays v4.** Antigravity returned UNSOUND,
but its two sharpest counterexamples rest on assumptions that **do not hold for lune**, and are
defused by facts codex verified in the tree — recorded here because they *strengthen* the doc:

- **Address-dependent `pairs()` iteration order** (Antigravity's #1): assumes hash-iteration
  order depends on object *addresses*. lune keys iteration on **monotonic `GcHeader.id`**
  (address-independent — the determinism foundation, `keyframeser.zig` restore re-stamps original
  ids precisely so re-serialization is byte-identical). A divergent JIT allocation timeline cannot
  perturb iteration order. **Defused.**
- **Side-exit frame reconstruction inside an inlined callee** (Antigravity's `call_seq` #1):
  assumes LuaJIT-style snapshot frame rebuild on a mid-callee guard failure. lune does **not**
  reconstruct callee frames — it resumes at the **loop header** (`anchor.pc`) and re-executes the
  real `.call` (trace-inlining sweep Q3: "no restore-frames path, by construction there is nothing
  to rebuild"). **Defused.**
- **`__gc` finalizers at divergent instruction counts** (Antigravity #3): the collector is
  **finalizer-free** and runs no guest code at sweep (`gc.zig:533`). **Defused.**
- **Background-thread compilation scheduling** (Antigravity): compilation is **synchronous** in
  the dispatch loop; there is no concurrent compiler. **Defused.**

But the review is a genuine **BLOCKER**: "reset to empty/0" is too glib, E-1's structural key can
collide, and teardown misses a host-abort case. Antigravity independently corroborated one hazard
codex also raised (shared allocator). Consolidated round-7 items (F-n):

- **F-1 ‡ (E-1 collision, codex STILL-BLOCKER) — `StructuralEdgeId{proto,anchor_pc,exit_pc,
  succ_anchor_pc}` is NOT unique.** The recorder emits several guards for one bytecode
  instruction, all sharing `rec.cur_pc` (`trace.zig:3956/4084`); runtime distinguishes them by
  `exit_instr`, but two guards for one instruction can share identical anchor proto / anchor PC /
  exit PC / successor anchor PC while being distinct exits — recreating the very collision D-4
  avoided by choosing `(Trace.id, exit_instr)`. Fix: add a stable discriminator — a
  recording-stable guard ordinal + role/op/polarity, or a region-discovery-assigned structural
  edge ordinal — proven stable across re-recording. (The run-lifetime scope reduction is
  otherwise correct: no identity need survive restore.) E-4 depends on this (a colliding key
  yields the wrong owning `RegionId`).
- **F-2 ‡ (E-2/E-5 restore re-keying, codex STILL-BLOCKER — the central correction) — restore
  is a physical-frame construction path and MUST re-key live activations.** `restoreSnapshot`
  writes `vm.frames[i]` directly (`keyframeser.zig:671`), bypassing `pushFrameVararg`. My round-6
  text "`next_call_seq = 0`, per-frame `call_seq` irrelevant" is **wrong**: a restored live frame
  can subsequently enter a region, and a recursive snapshot holds several live instances of the
  same proto that need **distinct** keys. Correct rule: **reset `region_profit` (empty); assign
  each restored live frame a fresh unique transient `call_seq` deterministically by frame order;
  set `next_call_seq` above that range.** Still **no wire field** (the map is empty, nothing to
  serialize) — the schema stays v4, so the reshaping insight holds; only the reset *procedure*
  changes from "zero everything" to "re-key the live stack." This supersedes the E-5 body's reset
  sentence.
- **F-3 (E-2 exact-frame invariant, codex) — the activation key is the EXACT current physical
  dispatcher frame, not a proto match.** "Anchor frame's `call_seq`" must mean `frames[depth-1]`
  (exact index + closure + anchor relation), never "some live frame whose proto matches" — under
  recursion a proto search selects the wrong activation. State and check this at every
  region-open / arm site (the fail-closed guard must assert the exact-frame relation). Add a
  checked-exhaustion contract for `next_call_seq` (a silent `u64` wrap would violate activation
  uniqueness → fail-closed). codex found no path where a region root is entered as an elided
  callee (roots are armed/entered from the dispatcher with their physical frame current), so the
  invariant is satisfiable — it just must be explicit.
- **F-4 (E-5 allocator exhaustion, codex + Antigravity) — JIT and VM share the backing
  allocator, so a divergent post-restore tiering timeline can change which timeline OOMs.** A
  changed tiering timeline changes JIT allocation timing/retention; under a bounded allocator a
  later *guest* allocation could fail in one timeline only, truncating output — the one way a
  reset could become output-visible. Fix (a design fork for Bart/reviewers): (i) explicitly
  **exclude** allocator exhaustion from replay equivalence; (ii) **isolate/budget** JIT
  allocations so they cannot starve semantic VM allocations (Antigravity's "strictly isolate the
  JIT compiler allocator from the GC heap"); or (iii) a fail-closed testable policy. Options
  recorded; not yet chosen.
- **F-5 (E-5 test evidence, codex) — the existing F2c/F2d harness is tier-0-only.** The resume
  tests state this explicitly (`keyframeser.zig:1863/1905`), so round 6 cannot cite the current
  harness as validation of *differing post-restore native tiering*. Round-7 design owes a
  **trace-enabled/native F2c obligation**: restore with an empty trace/region cache, re-enable the
  same JIT config, assert output + effect order/cursor + final snapshot byte-identical. (An
  implementation obligation, but it belongs in the design.)
- **F-6 (E-6 polarity, codex — my text is backwards) — correct exit test is `outside-region
  identity AND current_depth <= captured_anchor_depth`.** A *deeper* re-entrant host call means the
  anchor is still live and the region must **not** close. My round-6 sentence had the polarity
  inverted (though the intended captured-depth rule was right). Capture the anchor's own `depth`
  when the region opens; close only on return to ≤ that depth with an outside-region identity.
- **F-7 (E-7 host-abort boundary, codex NEW-ISSUE) — non-catchable faults do NOT guarantee
  whole-VM teardown.** `run`/`start`/`exec`/`callValue` return errors to the embedding host, which
  may retain or reuse the VM; faulting frames stay live on several paths. Need a host-abort
  boundary (a design fork): (i) an explicit VM reset/abandon that drops all activation-owned
  region state; (ii) cleanup at every public execution boundary when an error escapes and
  execution will not resume; or (iii) a documented VM-reuse-forbidden invariant enforced by a
  poisoned-VM state. Also: `protectedCall` restores `depth` at **three** sites
  (`errors.zig:100/108/117`), not one — centralize the accumulator cleanup with the depth restore
  so no branch omits it. (Stale keys don't *collide* while `call_seq` is unique, but they consume
  the bounded/LRU map and can evict live accounting — not cosmetic.)
- **F-8 (Antigravity `safepoint_seq`/effect-log — needs grounding, likely already-safe) — confirm
  a tier-dependent `safepoint_seq` count cannot perturb the serialized effect-log ordering/cuts.**
  Native runs fewer dispatch safepoints than tier-0, so `safepoint_seq` is *already* tier-dependent
  and the 10-mode matrix must already tolerate it (effect log is logical-effect-ordered, not
  safepoint-indexed; `safepoint_seq` is re-derived, not serialized — E-5 grounding). This is
  almost certainly a non-issue, but round 7 must **ground it, not assert it** (a sweep of what
  drives effect-log cuts and whether any async/interrupt surface is safepoint-indexed).
- **Phrasing correction (both) — soften "native ≡ tier-0 by construction."** The doc's own
  P-EBP-1 says output/effect/replay equality is **asserted by the 10-mode matrix, not assumed by
  construction** (`17:P-EBP-1`). Round 7 states the reset-neutrality as resting on that *asserted*
  invariant, not a constructional one.

**Net of round 6 review.** Both reviewers agree the layering — JIT tiering state is out-of-band
from the replay snapshot — is the right architecture; the keyframe stays **v4**. The surviving
work is precision on the **restore path** (F-2 re-key live activations, F-3 exact-frame invariant,
F-4 allocator-exhaustion contract, F-5 native-F2c test), the **structural key** (F-1 collision
discriminator), the **exit-test polarity** (F-6), and a **host-abort lifecycle** (F-7), plus one
grounding item (F-8). E-3/E-4/E-6 are resolved (E-4 modulo F-1). Two design forks (F-4, F-7) carry
option-sets for Bart/reviewer selection in round 7. No code until round-7 is review-clean.

#### Part A — round-7 design (2026-07-17): F-1..F-8 resolved, grounded — both forks collapsed

Round 7 was preceded by two more grounding sweeps (allocator architecture: JIT-vs-GC-heap; and
effect-log cut drivers vs `safepoint_seq`). **Both round-6 forks (F-4, F-7) collapsed to a single
sound resolution once grounded** — no Bart decision is required, though the F-4 contract boundary
is flagged for ratification.

**F-1 ‡ (resolved) — disambiguate the structural key with a recording-stable exit ordinal.** The
persistent key gains one field:

```
StructuralEdgeId = { anchor_proto_id, anchor_pc, exit_pc, exit_ordinal, succ_anchor_pc }
```

`exit_ordinal` is the **rank of this exit's `exit_instr` within the region's exit set**, assigned
at region-discovery time by walking the recorded trace graph and ordering the region's concrete
exits by `exit_instr`. This defeats the collision codex found (multiple guards for one bytecode
instruction share `rec.cur_pc` `trace.zig:3956/4084`, hence share `anchor_pc`/`exit_pc`): the
runtime already distinguishes them by `exit_instr` (distinct per guard), so mapping each distinct
`exit_instr` to a dense ordinal yields a unique persistent key. The ephemeral
`(Trace.id, exit_instr) → (StructuralEdgeId)` cache is built at commit by pairing each runtime
`exit_instr` with its discovered ordinal. **Stability across re-recording** rests on recording
being a deterministic function of the trace graph: a logically-identical edge re-records to the
same guard set in the same order → same ordinals; a re-recording that produced a *different* guard
order would be a *different* edge and correctly gets a different id. Assert recording-determinism at
the discovery site. (E-4's correctness depends on this — a colliding key would return the wrong
owning `RegionId`.)

**F-2 ‡ (resolved — the central correction; supersedes the E-5 body's reset sentence) — restore is
the THIRD physical-frame construction path and MUST re-key live activations.** `restoreSnapshot`
writes `vm.frames[i]` directly (`keyframeser.zig:671`), bypassing `pushFrameVararg`, so alongside
"reset `region_profit` empty" the restore must **stamp each restored live frame with a fresh
transient `call_seq`, assigned deterministically by frame index** (`frames[i].call_seq = i`), and
set `next_call_seq = vm.depth` (above the assigned range). This gives each restored frame — and
each of several live instances of the same recursive proto — a **distinct** key, which "zero
everything" did not. **Still no wire field:** the pre-snapshot `call_seq` values are neither
serialized nor needed (the `region_profit` map is empty on restore, so nothing references them), so
the schema stays **v4** and the reshaping insight holds — only the reset *procedure* changes from
"zero" to "re-key the live stack by index." Determinism note: the restored timeline's `call_seq`
values (`0..depth-1`) differ from the uninterrupted timeline's accumulated values, but since
`call_seq` only keys transient `region_profit` and output is tier-invariant, `out_after` is
byte-identical and the final snapshot (which carries neither) is byte-identical — F2c holds.

**F-3 (resolved) — the activation key is `frames[depth-1]`, the exact current dispatcher frame,
never a proto match.** At every region-open / arm site the anchor activation is the precise
physically-current frame (`frames[depth-1]`), identified by exact index + closure identity + anchor
relation — never "some live frame whose proto matches," which under recursion selects the wrong
activation. The fail-closed guard (E-2) asserts this exact-frame relation; if a candidate region's
anchor cannot be resolved to the current physical frame, decline to arm. `next_call_seq` gets a
**checked-increment / exhaustion contract**: a `u64` at realistic push rates is unreachable
(centuries), but the wrap is handled fail-closed (stop discriminating / decline to arm) rather than
silently violating activation uniqueness. codex confirmed no path where a region root is entered as
an elided callee (roots are armed/entered from the dispatcher with their physical frame current),
so the invariant is satisfiable — it just must be explicit at each site.

**F-4 (resolved — fork collapsed; contract boundary flagged for Bart) — allocator-exhaustion
divergence is pre-existing to native tiering and outside replay equivalence.** Grounding: native
mcode lives in a **separate `mmap`** (`nativegen.zig:296-310`, `READ|EXEC`, `PRIVATE|ANONYMOUS`,
1 MiB regions), **disjoint from the GC heap** — compiling a trace's *code* never consumes bytes a
guest allocation would get. Only small trace/IR *metadata* shares the VM's single injected `gpa`
(`interp.zig:481`), and `gpa` is the **unbounded** process allocator by default (the test harness
uses `std.testing.allocator`, also unbounded and leak-checking). Therefore a divergent post-restore
tiering timeline changes only the *interleaving* of an unbounded allocator, not a zero-sum budget —
ordinary interleaving, not contention. An OOM-timing divergence arises **only** under a
deliberately-injected *bounded* allocator, and even then it is **pre-existing**: native tiering
*already* perturbs the `gpa` interleaving vs tier-0 independently of `region_profit`. **Resolution:**
the replay-equivalence contract is defined over the default unbounded allocator; OOM under a
capped embedder allocator is explicitly **outside byte-identical-output equivalence** (a non-goal,
already true for native tiering generally). *Flagged for Bart:* if you want replay-equivalence to
hold even under a bounded allocator, that requires isolating/budgeting the JIT-metadata allocator
from the guest heap (a larger, separate lift) — deferred as a non-goal unless you say otherwise.

**F-5 (resolved — obligation recorded) — a native/trace-enabled F2c test.** The existing F2c/F2d
resume harness is **tier-0-only** (`keyframeser.zig:1863/1905`), so it cannot validate
differing-post-restore native tiering. Round 7 records the obligation (and adds it to the P-EBP
list): a `--jit-native` F2c case that captures mid-region, restores into a fresh VM with an **empty
trace/region cache**, re-enables the same JIT config, and asserts `out_before ++ out_after == F` +
effect order/cursor + final snapshot byte-identical. This is what empirically backs the
reset-neutrality claim (rather than resting on "by construction").

**F-6 (resolved — polarity fixed) — a region closes iff `target identity ∉ active region AND
current_depth ≤ captured_anchor_depth`.** Capture the anchor frame's own `depth` when the region
opens. A *deeper* re-entrant host call (`current_depth > captured_anchor_depth`, e.g. a `pcall`
comparator re-entering dispatch at `native_reentry_depth`, `interp.zig:534`) means the anchor is
**still live** → do **not** close. My round-6 E-6 sentence inverted this; the captured-depth rule
was right but the polarity is now stated correctly.

**F-7 (resolved — fork collapsed) — monotonic keys ⇒ no correctness hazard; extend the existing
epoch hook + rely on the cap.** Grounding: `beginTopLevelEpoch` (`interp.zig:1011`) already runs at
every fresh `run`/`start` entry (not `exec` resume, not nested calls) and disarms all native links;
there is **no** error-exit hook, **no** poisoned-VM flag, and **no** cheap reset (only full
`deinit`). But because `call_seq` is **monotonic**, a faulted or popped activation's `region_profit`
entries can **never collide** with a future activation's key — so stale entries are a **memory**
concern only, never a correctness one. **Resolution:** extend `beginTopLevelEpoch` to also
`region_profit.clearRetainingCapacity()` (a fresh top-level run is a fresh tiering epoch, exactly
mirroring the link-disarm it already does); within a single run the existing bounded/LRU cap bounds
growth, and a cheap sweep at frame-pop (`.ret/.halt` `interp.zig:2345/2364/2395`) and at
`protectedCall`'s three error-unwind depth restores (`errors.zig:100/108/117` — all three are
error paths, correcting the round-6 "one normal + two error" framing) is a memory optimization, not
a correctness requirement. No new error-exit lifecycle, no poisoned-VM state, needed for this
feature. (Grounding also surfaced a **pre-existing, orthogonal** hazard — a host can re-`run` a
faulted-but-live VM and `run` doesn't zero `depth`/`stack_top` first — noted in `TODO.md`, not
addressed here.)

**F-8 (resolved — grounded non-issue) — the effect log is tier-independent; `safepoint_seq`
touches only the keyframe cut, not our state.** Grounding: effect-log entries are keyed by
**logical call order** (`effect_cursor` / append order, `interp.zig:3866/3876`), the wire schema is
`{kind, result}` with **no** safepoint field (`effectser.zig:107`), and effects always execute in
**tier-0** (effectful natives are not pure builtins → side-exit; only `guard_pure` builtins inline
into mcode, `nativegen.zig:406`). So a tier difference is invisible to the serialized effect log.
`safepoint_seq` *is* tier-dependent (a per-instruction tier-0 counter, `interp.zig:1702`) but feeds
only `suspend_ctl`, the `safepoint_lines` index, and **keyframe** records (`total_safepoints`,
`keyframeser.zig:1694`) — a separate serialization family (the resume-cut mechanism), which
`region_profit`/`call_seq` do not touch. Caveat recorded: a *keyframe cut* selected by safepoint
count is tier-dependent, but that is pre-existing and owned by the snapshot machinery; our reset
neither reads nor writes `safepoint_seq`.

**Phrasing correction (applied) — "native ≡ tier-0 in output is ASSERTED, not by construction."**
Throughout, the reset-neutrality argument rests on the P-EBP-1 invariant (output/effect/replay
equality gated by the 10-mode matrix), **not** a constructional claim. codex flagged that the doc
itself says this equality is "not assumed by construction" (`P-EBP-1`); round 7 states the
neutrality as resting on that *asserted* invariant.

**Net of round 7.** Every round-6 blocker is resolved and grounded; both forks collapsed to a
single sound answer (F-4 flagged for optional Bart tightening). The feature is **runtime-only JIT
state, keyframe v4 unchanged**, with a precise restore-path contract (F-2 re-key by index, F-3
exact-frame, F-7 epoch-clear + cap), a collision-free structural key (F-1 exit ordinal), the
correct exit polarity (F-6), and a native-F2c validation obligation (F-5). β (activation
discrimination) is preserved at the cost of one `u64` on `CallFrame`, one choke-point bump, and one
restore-time re-key loop. Still no code; round-7 review (codex `gpt-5.6-sol` + Antigravity) next.

#### Review outcome — round 7, codex `gpt-5.6-sol` + Antigravity (gemini-3.1-pro), 2026-07-17: BLOCKER (both) — two deep new findings on the JIT↔snapshot boundary

Both reviewers returned **STILL-BLOCKER**. Four round-7 resolutions hold; the reset-neutrality
argument, however, has a **hole codex found and I confirmed against the tree** (G-2 below), plus the
exit-identity key (F-1/G-1) is still not re-recording-stable. This round is **not**
implementation-ready. The surviving/next items are **G-n**.

**Resolved by round 7 (both reviewers concur):**
- **F-3 → RESOLVED.** `frames[depth-1]` is the exact current dispatcher frame at every arm site;
  codex verified `execImpl` seeds hot state from `frames[depth-1]` (`interp.zig:1767`), bytecode
  calls reload the top frame (`:2229`), returns reload the parent (`:2393`), reentrant `callValue`
  enters a depth-bounded nested dispatcher, and trace-inlining never constructs an elided physical
  callee frame (`trace.zig:4995`). Exact-frame check + closure/anchor relation + fail-closed `u64`
  exhaustion is sound.
- **F-4 → RESOLVED, with a wording correction.** mcode is a separate `mmap` (`nativegen.zig:296`),
  metadata uses the injected `gpa` (`interp.zig:481/712`), the native CLI uses `std.process` gpa
  (`main.zig:163`); no default path injects a bounded allocator; `OutOfMemory` is *already*
  deliberately non-catchable because pressure varies across modes (`interp.zig:3772`). codex's
  correction: no allocator is *literally* unbounded, so phrase the contract as **"replay
  equivalence applies to executions that complete without allocator / executable-memory
  exhaustion."** No existing determinism assertion requires OOM to occur at identical logical points
  across modes.
- **F-6 → RESOLVED.** Correct close condition is outside-region identity **and** `current_depth ≤
  captured_anchor_depth`; deeper native reentry leaves the anchor live.
- **F-5 → RESOLVED as an obligation** — but it will not pass the *stronger final-snapshot*
  assertion until G-2 is fixed.

**Surviving / new blockers (G-n):**

- **G-1 ‡ (was F-1, codex STILL-BLOCKER + Antigravity UNSOUND) — `exit_ordinal` by IR position is
  NOT stable across re-recording, and the IR cannot even supply `exit_pc` for every native exit
  slot.** Recording is explicitly **guest-value-dependent**: `recordInstr` reads pre-execution
  values (`trace.zig:3948`); `guardNum` picks `guard_int` vs `guard_float` by observed type
  (`:4165`); array recording varies its guard sequence by lane / bounds / presence / append status /
  loaded type (`:4255`, `:4382`). So a later recording at the same anchor can **add, remove, or
  reorder** guards before a logically-corresponding exit → its dense `exit_instr` rank changes, and
  worse, the *same* ordinal can rebind to a *different* guard at the same `exit_pc`/successor —
  recreating a cross-recording collision. Antigravity's independent counterexample: type-feedback
  guard **elision** / LICM hoisting shifts the ordinal (an exit that was rank 2 becomes rank 1 when
  an upstream type guard is proven redundant). **Grounded compounding fact:** `guardExitPc`
  (`trace.zig:451`) returns a PC for **only** `guard_int/float/number/true/false` + `int_of_float`;
  `guard_lane`/`guard_fits` reuse `aux` for lane ordinals and the rest leave it zero — so today the
  IR **cannot** provide an `exit_pc` for array/table/grid native exit slots at all. A structural key
  over *all* concrete native exit slots therefore needs **new guard-provenance metadata**, not a
  re-derivation from IR position. **Remaining:** define a canonical guard identity independent of raw
  IR position — source proto / inlining path, source bytecode PC, guard role/op/polarity, guarded
  structural operand, and an occurrence discriminator within that canonical role — and prove
  re-recording cannot map two semantically-different exits to one key. "Recording is deterministic
  for identical inputs" is **insufficient** (the inputs — observed guest types — legitimately
  differ across recordings).

- **G-2 ‡ (was part of F-2, codex STILL-BLOCKER — THE DEEP ONE, confirmed against the tree) — the
  transient trace cache roots heap objects into the SERIALIZED snapshot, so a tiering-dependent
  `region_profit` history can change snapshot bytes.** The physical re-key procedure (F-2) is
  correct — codex verified `restoreSnapshot` writes `vm.frames[i]` directly (`keyframeser.zig:671`),
  `call_seq = i` gives distinct keys incl. recursive instances, `next_call_seq = depth` + checked
  monotonic allocation avoids collision, no wire field needed — and codex found **no route from the
  numeric `call_seq` into stdout or effect records.** The blocker is subtler: keyframe serialization
  seeds its reachable-set walk from **`Vm.forEachRootHeader`** (`keyframeser.zig:265`), the *single*
  root definition shared with the collector, and that function **roots every cached-trace constant
  and in-progress-recording constant** (`interp.zig` item 5, lines ~1560/1583) — trace consts may
  hold heap values (`trace.zig` `Trace.consts`), and the code's own comment says *"a cached trace can
  outlive its proto's reachability, so its consts must be roots in their own right."* Therefore:
  differing `region_profit` histories → different set of *live traces* → different otherwise-dead
  heap objects retained → **those objects enter the serialized reachable heap graph even though the
  trace cache itself is not serialized → final-snapshot bytes can differ.** This is latent today
  only because the F2c harness is tier-0-only (no traces). Making native traces long-lived under
  snapshotting — the whole point of Increment 3 — activates it. **Remaining:** make **snapshot
  reachability JIT-independent** — a snapshot-specific *semantic-root* walk that excludes trace-only
  roots (distinct from the GC-liveness walk, which keeps them), **with a proof** that every
  trace-only constant is either (a) independently reachable from semantic roots (⇒ no behaviour
  change) or (b) trace-only and semantically dead (⇒ correctly excluded, because deopt resumes at
  the loop header and *recomputes* it). Then the native F2c test (F-5/G-4) can assert byte-identical
  final snapshots.

- **G-3 (was F-7, codex STILL-BLOCKER) — a bounded/LRU cap can evict LIVE activation accounting,
  and there is no enforced clean-entry invariant.** Monotonic keys do eliminate *mistaken-activation
  reuse* (a stale key never compares equal to a future activation), and codex verified
  `beginTopLevelEpoch` runs at every `run`/`start` (`interp.zig:1025/1045`) but **not** on `exec`
  resume or nested `callValue`, frame pops at `:2364/:2395`, and the three `protectedCall` unwinds at
  `errors.zig:100/108/117`. But under a *capped* map, stale entries **occupy** slots and can evict
  the accounting of a **currently-live** activation — which changes region gating/profit decisions,
  the exact mechanism this feature implements (round 6 already called that "not cosmetic"; round 7
  did not remove it). Also there is **no enforced clean top-level-entry rule**: a non-catchable fault
  leaves frames live and `run`/`start` do not require `depth == 0`, so "clear all region state at the
  next top-level entry" is not proven safe against the real API. **Remaining:** make the frame-pop +
  all three `protectedCall` sweeps **mandatory** (region-profit entry lifetime = activation
  lifetime), **or** give the cap an eviction rule proven never to evict a live activation's
  accounting; **and** enforce/document a clean-entry rule (reject `run`/`start` when `depth != 0`,
  explicit reset, or a poisoned-VM state). Ties into the pre-existing faulted-but-live-VM hazard
  already in `TODO.md`.

- **G-4 (was F-8, codex STILL-BLOCKER for cuts; RESOLVED for completed logs) — a native F2c cut
  selected by safepoint count is tier-dependent.** For a run that reaches the same logical effects,
  the effect log is tier-independent (append strictly in call order `interp.zig:3866`, sequential
  `effect_cursor` consume `:3872`, wire `{kind,result}` `effectser.zig:107`, `safepoint_seq` not
  consulted by `logEffect`/`nextLoggedEffect`). **But** tier choice changes how many dispatcher
  safepoints execute → `safepoint_seq` (`:1702`) triggers `suspend_ctl` (`:1716`) → suspension
  returns *before later logical effects run* → serializing the effect log **at that cut** yields a
  different-length prefix. So a snapshot cut defined by a numeric safepoint count does not denote the
  same *logical* cut across tiers. **Remaining:** define the native F2c cut (and its assertion) by a
  **tier-independent logical event**, or compare each snapshot against the effect-log cursor/prefix
  produced *at that snapshot's actual logical cut* rather than assuming equal safepoint counts denote
  equal cuts. (`keyframeser.zig:1694` is test-harness `total_safepoints` bookkeeping, not a keyframe
  wire field — a phrasing correction to round 7's F-8.)

- **G-5 (Antigravity coroutine counterexample — grounded N/A for lune, invariant pinned).**
  Antigravity's sharpest re-key counterexample: if a snapshot holds multiple live stacks (suspended
  coroutines), per-stack `call_seq = frame_index` collides across stacks and a single global
  `next_call_seq` collides with a suspended stack's range. **Grounded:** lune has a **single physical
  stack** (`frames: [max_call_depth]CallFrame`, one `depth`, one `stack_top`, one `open_upvalues`,
  `interp.zig:531/512/546`); `keyframeser` has **no** coroutine/fiber/multi-stack path and the F2c
  harness is single-stack. So the collision cannot arise today (E-6 "no coroutines" holds). Round 8
  **pins the invariant**: the restore re-key is a *single-stack* traversal; **if** coroutines /
  multiple serialized stacks are ever added, the re-key MUST become a **global-flat** monotonic
  assignment across all restored frames of all stacks (and `next_call_seq` = total restored frames),
  recorded now so a future coroutine feature cannot silently break activation uniqueness.

**Phrasing correction (codex):** the F2c contract for native must state that byte-identical
final-snapshot equivalence is **conditional on G-2** (semantic-root walk) — round 7's F-2 claim
"the final snapshot carries neither field therefore its bytes are unchanged" is **false as stated**
because trace roots enter the snapshot indirectly.

**Net of round 7.** The *layering* (JIT tiering state out-of-band from replay, keyframe v4) and the
*restore re-key mechanics* (F-2 physical procedure, F-3 exact-frame, F-4 allocator boundary, F-6
polarity) survive. Two deep items remain: **G-1** (a canonical, optimizer-invariant guard identity —
the current IR is insufficient) and **G-2** (JIT-independent snapshot reachability — the reset is
*not* snapshot-neutral while trace roots seed the serializer). Plus **G-3** (mandatory
activation-scoped cleanup + clean-entry rule) and **G-4** (tier-independent native F2c cut). No code
until round-8 is review-clean.

#### Part A — round-8 design (2026-07-17): G-1..G-5 resolved, grounded

Round 8 was preceded by grounding sweeps confirming both deep findings against the tree:
`guardExitPc`'s coverage gap (`trace.zig:451` — PC only for the 5 PC-carrying guards + `int_of_float`)
and the shared-root serializer seed (`forEachRootHeader` item 5 roots trace consts;
`keyframeser.zig:265` walks the same function). Both are real; both resolutions below are structural,
not glosses.

**G-1 ‡ (resolved) — key each region exit by its GUEST-LOGICAL provenance, not its IR position;
carry the provenance as guard metadata.** The IR-position `exit_ordinal` is abandoned. Each guard
that can become a concrete native exit gains a **provenance tag stamped at emission**, independent of
how many sibling guards the recorder emits or in what order:

```
GuardProvenance = { source_proto_id, source_pc, inline_depth, role, operand, occurrence }
StructuralEdgeId = { anchor_proto_id, anchor_pc, GuardProvenance(exit), succ_anchor_pc }
```

- `source_proto_id` + `source_pc` + `inline_depth` locate the exit at the **guest bytecode**
  instruction that caused it, through the recorder's inlining (a trace inlines callees by
  register-window renaming — `recCall` `trace.zig:5011`; `inline_depth` is the renaming depth at
  emission, a deterministic function of the *guest call structure*, not of guard order).
- `role` is the guard's **semantic kind** (type-check / branch-taken / branch-not-taken /
  bounds / lane-present / append-status / loop-done), and `operand` is the **guarded structural
  operand** (register or array-lane index). These come from *what the bytecode means*, not from the
  IR emission sequence, so guard **elision** or **reordering** in a later recording does not move
  them: an elided upstream type guard simply means that `(source_pc, role=type, operand=rN)` exit
  does not exist in that specialization — it does **not** renumber the branch exit's identity.
- `occurrence` disambiguates the rare case of two guards with identical
  `(source_pc, role, operand)` (e.g. two independent bounds checks the same instruction can emit),
  ranked by a **canonical guest-level order** (operand index, then sub-operation index within the
  bytecode's defined semantics) — *not* by IR position.

This requires the grounded IR change G-1 exposed: **`guardExitPc` (and the guard record) must be
extended to carry `GuardProvenance` for _all_ guard kinds**, not just the five that currently stamp
`aux` — `guard_lane`/`guard_fits`/table/grid guards included. Emission already knows the source PC
and role (it is mid-recording of a specific bytecode op); it currently just discards them for the
array/table families. The persistent key is then a pure function of guest semantics, stable across
re-recording **by construction of the tag** (not by asserting recording-determinism over
guest-value-dependent inputs). The ephemeral `(Trace.id, exit_instr) → StructuralEdgeId` cache is
still built at commit, now by reading each exit guard's stamped provenance. Two semantically-distinct
exits cannot collide because they differ in at least one of `{source_pc, role, operand, occurrence}`;
two recordings of the *same* logical exit produce the *same* tag regardless of the surrounding guard
set. **Determinism obligation:** prove `GuardProvenance` is a deterministic function of
`(guest bytecode, inlining structure)` alone — no observed-type or guard-order input — pinned by the
10-mode matrix.

**G-2 ‡ (resolved — the deep one) — split root enumeration into a GC-liveness superset and a
snapshot SEMANTIC-root subset; trace/recording constants are roots of the former only.**
`forEachRootHeader` today is a single function serving *both* the collector (must keep trace consts
alive — a cached trace can outlive its proto) and the keyframe serializer (must serialize only
*semantic* state). Those two needs **diverge exactly on the transient JIT roots.** Round 8 splits
them:

```
forEachRootHeader(kind: {gc, snapshot}, ctx, cb)
  // shared semantic roots (both kinds): globals, live registers, frame closures,
  //   open upvalues, effect-log heap results, pending error, metamethod roots
  // gc-only roots (kind == .gc): cached-trace consts, in-progress-recording consts
```

The collector calls it with `.gc` (unchanged root set — no trace const is ever prematurely freed).
`keyframeser.encodeSnapshot` calls it with `.snapshot` (trace/recording consts **excluded** from the
serialized reachable-set walk). **Correctness proof obligation** — every trace/recording constant is
in exactly one of two cases:
1. **Also reachable from a semantic root** (it is a live register value, a reachable proto constant,
   an upvalue, …): excluding it from the *trace* root edge changes nothing — the semantic walk still
   reaches it, it still serializes, identically. No behaviour change.
2. **Reachable ONLY via the trace** (a folded constant the recorder materialized — e.g. a
   concat/`load_const` result whose proto is no longer reachable): it is **semantically dead** — the
   resumed program cannot name it, because deopt resumes at the **loop header** (`anchor.pc`) and
   *re-executes the real bytecode*, which *recomputes* an equal value from live inputs (the
   trace-inlining sweep's "by construction there is nothing to rebuild"). Excluding it is **correct**:
   the restored VM (empty trace cache) neither has nor needs it, and a fresh record recomputes it.

Case 2 is the whole hazard — it is precisely the object whose retention was tiering-dependent — and
it is exactly the object that is safe to drop. So the split is not merely sound but *removes the
tiering-dependence from the snapshot by construction*: the serialized graph becomes a pure function
of semantic state, independent of which traces happen to be live. (In-progress-recording consts are
additionally almost-unreachable at a cut — recording is synchronous within one dispatch step and a
safepoint cut cannot land mid-record — but excluding them is justified by the same case-1/case-2
split regardless.) This is the general fix — it makes **all** snapshotting JIT-independent, not
nsieve-specific — and it is what unblocks the native F2c final-snapshot assertion (G-4/F-5).

**G-3 (resolved) — activation-scoped `region_profit` lifetime made mandatory; clean-entry enforced.**
Two mechanisms, both required (not "memory optimizations"):
1. **Entry lifetime = activation lifetime.** A `region_profit` entry keyed by a live activation's
   `call_seq` is removed **when that activation is destroyed** — at the normal frame pop
   (`.ret/.halt`, `interp.zig:2345/2364/2395`) **and** at all three `protectedCall` error-unwind
   depth restores (`errors.zig:100/108/117`). Centralize this with the depth restore so no branch can
   omit it (codex's requirement). With per-activation entries deleted at activation death, the map
   holds **only live-activation accounting** plus at most the current run's regions — so the cap can
   **never** evict a live activation (there is nothing dead to evict, and the live set is bounded by
   `max_call_depth × regions_per_frame`). This defeats the "cap evicts live accounting" hazard by
   *construction of the lifetime*, not by an eviction heuristic.
2. **Clean top-level entry.** `beginTopLevelEpoch` (`interp.zig:1011`, every `run`/`start`) also
   `region_profit.clearRetainingCapacity()` — a fresh top-level run is a fresh tiering epoch,
   mirroring the link-disarm it already performs. **And** the pre-existing faulted-but-live-VM hazard
   (a host re-`run`s without `depth`/`stack_top` reset — `TODO.md`) is addressed *for this feature's
   state* by the epoch-clear (region state starts empty regardless of leftover frames); the broader
   frame/stack-reset question stays a separate `TODO.md` item, but this feature no longer depends on
   it because the epoch-clear is unconditional. No poisoned-VM state is required.

**G-4 (resolved) — the native F2c cut is defined by a tier-independent LOGICAL event, and the
assertion compares effect-log cursors, not safepoint counts.** The trace-enabled F2c obligation
(F-5) is sharpened: the capture cut is taken at a **logical program point** reproducible across tiers
(e.g. "after the Nth committed effect" or "at the Kth back-edge of the outer loop as counted by
committed iterations," both tier-independent), **not** at "the Kth safepoint" (which is
tier-dependent because native runs fewer dispatch safepoints). The equivalence assertion compares,
at that logical cut: `out_before ++ out_after == F`, **the effect-log cursor/prefix produced at that
same logical cut** (not an assumption that equal safepoint counts denote equal cuts), and — now
enabled by G-2 — the byte-identical final snapshot. This makes the reset-neutrality claim empirical
under native tiering, closing F-5's "cannot cite the tier-0 harness" gap.

**G-5 (resolved — invariant pinned).** The restore re-key (F-2) is explicitly a **single physical
stack** traversal (`frames[0..depth]`), correct because lune serializes exactly one stack. The
invariant is recorded in the design and belongs in a code comment at the re-key site: *if lune ever
gains coroutines / multiple serialized stacks, the `call_seq` re-key must become a global-flat
monotonic assignment across every restored frame of every stack, with `next_call_seq` = total
restored frame count* — so a future feature cannot silently reintroduce Antigravity's cross-stack
collision.

**Net of round 8.** The two deep findings are resolved structurally: **G-1** replaces the unstable
IR-position ordinal with a guest-logical guard-provenance tag (requiring an IR metadata extension for
the array/table guard families), and **G-2** splits root enumeration so the serialized snapshot graph
is a pure function of *semantic* state — removing the tiering-dependence from snapshot bytes by
construction, the general fix. **G-3** makes activation-scoped cleanup mandatory (defeating cap
eviction by lifetime construction) and unconditionally epoch-clears region state; **G-4** defines the
native F2c cut by a tier-independent logical event and asserts on effect-log cursors + (now)
byte-identical snapshots; **G-5** pins the single-stack re-key invariant. Two new implementation
obligations are now explicit: the **`GuardProvenance` IR extension** (G-1) and the **`{gc,snapshot}`
root-walk split** (G-2). Keyframe stays **v4**. Still no code; round-8 review (codex `gpt-5.6-sol`
+ Antigravity) next.

#### Review outcome — round 8, codex `gpt-5.6-sol` + Antigravity (gemini-3.1-pro), 2026-07-17: BLOCKER (both) — a FOUNDATIONAL finding surfaces (JIT-materialized object identity vs the monotonic-id replay model)

Both reviewers returned **STILL-BLOCKER**, and — decisively — **independently constructed the *same*
counterexample** that G-2's case-1/case-2 proof missed. This is not another mechanics refinement: it
is a **foundational determinism question about the interaction between the tracing JIT and lune's
monotonic-object-id replay model**, it is **broader than Increment 3** (it holds for *any*
trace-materialized object under snapshot, not just region-gated ones), and its fix likely **reverses
the reshaping insight's "keyframe stays v4"** conclusion. G-5 is RESOLVED; G-1/G-2/G-3/G-4 survive.
The next items are **H-n**; **H-2 is escalated to Bart** as a scope/architecture decision, not a
round-9 mechanics item.

- **H-2 ‡‡ (THE FOUNDATIONAL ONE — G-2 STILL-BLOCKER, both reviewers, same counterexample) — the
  `{gc,snapshot}` split is necessary but NOT sufficient: dropping a trace-only object changes the
  observable heap-id timeline, and object ids are semantic.** The split correctly stops the *trace
  graph* from being serialized, but a trace-only **interned** constant (a folded string the recorder
  materialized) held alive only by the trace root has object id N. In the **uninterrupted** VM, a
  later recomputation re-finds the interned object → **recovers id N**; in the **restored** VM (empty
  trace cache, no intern entry) the same recomputation **allocates a fresh object → id N′ ≠ N**. And
  ids are observable: equality is id-based (`value.zig:197`), table hashing uses id (`table.zig:545`),
  `pairs` ordering uses id (`key_order.zig:21`), non-string `tostring` exposes it (`io.zig:166`). Both
  reviewers built the identical `pairs()`-order-divergence program. **Compounding (codex):**
  `next_obj_id` is semantic future state that is **not serialized** — restore reconstructs it as
  `max(serialized id)+1` (`keyframeser.zig:521`) — and the F2c test **already** admits final-state
  equivalence is proven only for programs with **no discarded pre-cut objects**
  (`keyframeser.zig:1755`); dropping the highest-id trace-only object lands squarely in that
  already-unsupported case. **Antigravity adds:** `collectgarbage("count")` divergence (trace roots
  inflate the GC footprint in one timeline only) and table capacity / hash-chain divergence from
  shifted ids (and table capacity *is* serialized → snapshot bytes differ even without iteration).
  **codex corrections to the round-8 proof:** (i) in-progress-recording consts are **not**
  "almost unreachable at a cut" — recording spans multiple bytecodes, and suspension is checked at an
  instruction boundary (`interp.zig:1716`) *before* the next recording mirror (`interp.zig:1754`)
  while `rec.active` is still true, so a cut *can* land mid-recording; (ii) snapshot restore resumes
  at the **captured frame PC**, not `anchor.pc` — the "deopt resumes at the loop header and recomputes"
  argument is **not** the operative one for snapshot restore (the restored VM simply has no
  recorder/trace and continues from the serialized cursor). **Consequence:** "the program cannot name
  the object now" does **not** imply its identity history is semantically irrelevant — the weak intern
  table + monotonic allocation counter can expose it later. A clean fix probably must **serialize
  `next_obj_id`** (and reconcile weak-intern identity), which **bumps the keyframe schema** — reversing
  the reshaping insight's v4-stays result — *or* restrict when a snapshot may be cut. **This is
  foundational and out-of-scope-for-Increment-3 as currently framed; escalated to Bart.**

- **H-1 (G-1 STILL-BLOCKER, both reviewers) — `GuardProvenance` as specified still collides and is
  under-defined.** *(Status: **H-1b LANDED**, **H-1a GROUNDED**, **H-1c GROUNDED** — see the H-1b/H-1a/H-1c
  sections below. H-1c result: identity is `{source_pc, call-path, role, operand}` — the G-1 fourth axis
  **`occurrence` is retired as un-groundable** (recording-order = a dynamic ordinal, the `exit_ordinal`
  failure again); unrolled physical copies share one provenance (many-to-one). Round-9 landing owed.)* Three concrete gaps: **(H-1a, both) `inline_depth` identifies nesting, not the
  call PATH** — `f(a); f(b)` inlined in one trace gives both guards inside `f` identical
  `{proto,source_pc,inline_depth,role,operand,occurrence}` while they are distinct logical exits with
  different caller state. Need a full deterministic **inline call-site path** (a sequence of
  `(caller_proto_id, call_opcode_pc)`), not a depth integer; the recorder's inline-frame record today
  stores offsets/return-wiring, not the call-site path (`trace.zig:5284`). **(H-1b, codex)
  `source_pc` is conflated** — `nextOp` passes the **post-increment** pc into `recordInstr`
  (`interp.zig:1762`, documented `trace.zig:3951`), i.e. the resume/exit PC, not the opcode index.
  Provenance needs **both** distinct: the source-opcode location (`cur_pc`) and the deopt/resume PC.
  **(H-1c, both) `operand`/`occurrence` are under-specified** — one `get_index` guards
  container/lane/bounds/presence/**and a value loaded from a `.value` lane** (a derived guest
  expression, not a source register); "canonical guest-level order" is not yet a definition and
  Antigravity's guard-elision case shows an emission-order `occurrence` still slides when an upstream
  guard is elided. Need a **closed per-opcode `GuardSite` vocabulary** (explicit structural operands
  incl. derived values), ranked by a fixed opcode spec independent of emission order / dedup /
  observed types / optimizer movement.

- **H-3 (G-3 STILL-BLOCKER, codex) — mandatory deletion bounds the map but does not by itself prove
  the cap can't evict a live entry, and `beginTopLevelEpoch` still does not enforce clean entry.**
  *(Status: **GROUNDED 2026-07-18** — see "H-3 grounding" below. Live set bounded by hard `max_call_depth
  = 200` × a per-`(activation,anchor)` cardinality invariant round 9 must state ⇒ fail-closed OR strict
  lifetime-scoped map is safe, *silent* evict-live banned. Clean-entry gap is real & broader than framed:
  any uncaught error OR a suspended VM strands frames (no `depth` reset exists) ⇒ round 9 needs a
  `depth==0` precondition checked BEFORE the epoch mutation. Round-9 landing owed.)*
  The frame-destruction audit is otherwise confirmed complete (normal pops `interp.zig:2364/2395`,
  three `protectedCall` unwinds `errors.zig:100/108/117`; no tail-call frame replacement, no
  coroutine teardown, native calls push no physical frame). But: (i) all *remaining* entries may be
  live and still exceed a bounded cap unless the cap is **statically ≥ the proven max simultaneous
  live-region count** (which needs a hard bound on `regions_per_frame`), **or** insertion **fails
  closed** without evicting a live entry, **or** the map is uncapped over the bounded live set —
  `max_call_depth × regions_per_frame` is not a bound until `regions_per_frame` is bounded and the cap
  is tied to it. (ii) `beginTopLevelEpoch` currently only disarms links (`interp.zig:1011`) and
  `run`/`start` call it *before* pushing a frame (`:1025/:1046`); if a non-catchable fault left frames
  live, an unconditional `region_profit` clear **deletes accounting of still-live activations** and
  then pushes above them — so round 9 must **choose** a real clean-entry contract (reject `run`/`start`
  unless `depth==0`; or a real VM reset/unwind; or a poisoned-VM state), not merely clear the map.

- **H-4 (G-4 STILL-BLOCKER, codex) — "Kth committed outer iteration" is not an implementable cut;
  only "immediately after the Nth committed effect opcode boundary" is.**
  *(Status: **GROUNDED 2026-07-18** — see "H-4 grounding" below. Confirmed: `suspend_ctl` is tier-0-only
  (`interp.zig:1716`), native runs bursts; effects abort the trace (`.host_barrier`) so the effect
  boundary is always tier-0-reached — the one implementable tier-independent cut. Sharpened: the
  effect-barrier isn't structural yet (`pure`/`effect` independent → enforce `pure ⇒ !effect`); the
  immediate post-effect boundary isn't always suspendable (`reg_top_pending` multret gate) → cut at first
  eligible boundary after effect N; assert full semantic keyframe + replay-driver state, not the effect
  cursor. Round-9 landing owed.)* A native trace runs *many*
  outer iterations in **one** native call, and `suspend_ctl` is only checked when control returns to
  the dispatcher (`interp.zig:1716`); disarming native→native links does not force an ordinary native
  root to *return* at iteration K. So native can overshoot K with extra committed non-effect state
  (table writes, phi writebacks) while the effect cursor matches tier-0 — **effect-prefix equality
  alone does not identify an equal VM state.** Round 9 must either take the cut at the
  after-Nth-effect opcode boundary (host effects are trace barriers, so this is precise — but must
  not snapshot from inside `logEffect` before the result is installed) **or** add a native
  logical-budget/yield that returns *exactly* at iteration K with all registers/heap coherent, and
  **assert the whole logical-cut identity, not just the effect cursor.**

- **H-5 (Antigravity, needs grounding) — two further hazards. → GROUNDED 2026-07-18, both REAL; see
  "H-5 grounding" below: (i) ⊆ F-5 (real coherence gap, gated behind the tier-0-only F2c harness),
  (ii) ⊆ H-2 (trace-const rooting drifts the counter/intern identity).** (i) **Dead-register poisoning:** if a
  snapshot is ever cut *inside* a native trace, JIT liveness may drop a logically-dead register (→
  `nil`) that the interpreter still holds as a stale object → snapshot mismatch. (Relevant only if
  native-frame capture is in scope; today F2c cuts at tier-0 boundaries — ground whether a native cut
  is ever taken.) (ii) **JIT-metadata id leakage:** if trace-IR/metadata allocations ever draw from
  the monotonic **object-id** counter, JIT activity drifts the counter. (Almost certainly N/A —
  object ids are `GcHeader.id` for GC heap objects, trace IR is `gpa` metadata — but the *folded
  guest* objects in H-2 *do* get ids, which is the real mechanism; ground that trace metadata does not
  touch `next_obj_id`.)

- **G-5 → RESOLVED (codex).** Exactly one physical stack today (`interp.zig:505/525/544`); the
  single-stack re-key invariant is vacuous-but-correct, with the global-flat warning recorded for a
  future coroutine feature.

**Net of round 8 — the inflection.** The exit-branch-patching *mechanics* (edge-4 bridge, gate B,
activation-scoped accounting, structural exit identity) are converging: each is now a well-scoped
engineering problem (H-1 guard provenance, H-3 cap contract, H-4 logical cut). But **H-2 is a
different animal** — both independent reviewers proved that trace-materialized object *identity*
interacts with lune's monotonic-id + weak-intern + non-serialized-`next_obj_id` replay model in a way
that neither *serializing* nor *excluding* trace-only objects cleanly resolves, and that this is a
**general property of native-tracing-under-snapshot**, not a region-profit artifact. It very likely
forces a **keyframe schema change** (serialize `next_obj_id`, reconcile intern identity) — reversing
the reshaping insight — **or** a restriction on when snapshots may be cut. Because that reverses a
prior "resolved" decision and exceeds Increment 3's frame, it is **surfaced to Bart** for a
scope/architecture call before any round-9 pass. No code.

#### H-2 decision + foundational piece 1 LANDED (Bart, 2026-07-17): fix H-2 via schema bump; land safe foundational work first

**Bart's calls:** (1) **fix H-2 now with a keyframe schema bump** — serialize `next_obj_id` +
reconcile weak-intern identity so restore reproduces the id timeline regardless of tiering (this
**reverses the reshaping insight's "keyframe stays v4"** — the schema now moves). (2) The full
Increment-3 scope is too large to land at once; **pick up the earlier foundational pieces that are
unambiguously useful and non-breaking first**, so later work shrinks.

**Piece 1 — `next_obj_id` serialization (keyframe v4 → v5) — LANDED, `just test` green (default +
`-Djit-debug`), viz builds.** This is the **counter-drift half** of H-2 and closes a *pre-existing*
gap independent of the JIT: the restorer reconstructed the heap's monotonic id counter as
`max(restored id) + 1` (`gc.zig:149`, `keyframeser.zig:~555`), correct **only** for runs with no
allocated-then-dropped pre-cut garbage — a limitation the F2c harness itself admitted
(`keyframeser.zig:~1758`, "these corpus programs leak no pre-suspend garbage"). Now `next_obj_id` is
a serialized `Keyframe` field (`schema/trace.json`, regenerated codecs) restored **verbatim**, with a
`next_obj_id >= max(id)+1` validation (`NextObjIdBelowObjects`). Because for a garbage-free run the
serialized value *equals* `max(id)+1`, **every existing test is unaffected**; only the
previously-unsupported garbage case becomes correct. Regression test:
`"H-2: next_obj_id survives pre-cut garbage"` (gc_stress + garbage after the survivor → counter
strictly above the live count → restored verbatim + byte-identical round-trip; proven load-bearing by
a temporary impossible-bound flip that reddened exactly it). Files: `schema/trace.json`,
`src/gen/trace_schema.zig` + `viz/src/gen/generated.ts` (regenerated), `src/keyframeser.zig`
(encode/restore/version/tests), doc `04-snapshot-replay-schema.md`.

**Still owed for H-2 (the hard half — needs its own design + review):** the **weak-intern identity
reconciliation** + the safe `{gc,snapshot}` root-walk split. Serializing `next_obj_id` fixes counter
*drift* but does NOT by itself make a *dropped trace-only interned object* reproduce its original id
(a restored VM re-interns it fresh at the — now correct — high counter, still ≠ the original low id).
So the split (G-2/H-2) stays unsafe until interned identity is preserved across a drop; that is the
next H-2 design pass, not landed here. Mechanics blockers **H-1** (guard provenance), **H-3** (cap +
clean-entry), **H-4** (logical cut) are untouched by piece 1 and remain round-9 design work.

#### H-2 hard half — design (Bart, 2026-07-18): gate trace recording to the static proto tree

**Direction (Bart's call, from the three options presented):** do NOT build weak-intern identity
reconciliation, and do NOT reverse the "never invalidate a committed trace" invariant. Instead
**gate trace recording so the JIT never records a trace that touches a dynamically-`load`ed proto**
(anchors in one *or* inlines one). Loaded code runs tier-0 in every mode; the JIT is opted out of it.
This is the smallest fix that *fully* closes the determinism hole, needs no schema change, and reverses
no invariant. Accepted cost: `load`/`loadfile`/`dofile` chunks never JIT (rare, and correctness-first).

**Why this closes H-2 completely — the grounded chain (verified against the tree 2026-07-18).** The
round-8 reviewers' *stated* mechanism ("a folded string the recorder/optimizer materialized") **does
not exist in this tree**, but a *different, real* mechanism does. Both were run down:

1. **No recording/optimization path allocates a heap object.** `tropt` constant-folding computes with
   `irinterp.evalBinary`/`evalUnary` (`irinterp.zig:878-911`), which take **no allocator** and dispatch
   only to `arith.*` (numeric/bool results); `arith.add`/`mul`/`neg` (`arith.zig:63,79,87`) have no
   `Allocator` parameter and *cannot* intern a string. `concat` is **not** a foldable IR op and is not
   recorded at all — string concatenation hits the recorder's catch-all `else => abort(.nyi_opcode)`
   (`trace.zig:4096`) and abandons the trace. So a folded/materialized trace-only string is impossible.
2. **Every heap-valued trace `konst` is a proto literal.** The only heap-capable `konst` call site is
   `.load_const => konst(proto.constants[b])` (`trace.zig:3992`); the others pass `nil`/`bool`/`int`
   (`trace.zig:3989-3991,5090,5160`). `get_global`/upvalue heap values flow through `slot_load`
   (re-seeded live from `globals`/cells each entry), never the const pool. The compiler only ever adds
   *string* heap constants (`compiler.zig:356`, `internValue`); all other constants are `int`/`float`.
   So a trace const pool can hold exactly one kind of heap object: an **interned proto-literal string**.
3. **A proto-literal string is redundantly rooted UNLESS its proto has no live ancestor closure.**
   `markProtoConstants` (`gc.zig:526-529`) marks a proto's constants and **recurses into its nested
   child protos** (`for (proto.protos) |child|`), and it runs downward from every live closure
   (`gc.zig:509-512`). The **static main closure is a GC root for the entire run** (`frames[0].closure`
   in `forEachRootHeader`), and every statically-nested function's proto is a descendant of the main
   proto — so **all static-tree constants are marked whole-program regardless of tracing**. A trace
   const over static code is therefore always *also* reachable; its root in `forEachRootHeader`
   (`interp.zig:1615` for `cache`, `1618` for `rec`) is redundant.
4. **The one exception is a dynamically-loaded chunk whose sole closure was dropped.** `load()`
   compiles a *separate* proto tree (no static parent), stores the `Chunk` in `vm.loaded_chunks` but
   **not** the closure (`stdlib/load.zig:145,154`; `LoadedChunk` is `{chunk, source}` only), and hands
   the closure to the guest. If the guest drops it after a hot loop in that chunk was recorded, the
   chunk's proto has no live closure and no live ancestor → `markProtoConstants` never reaches it → its
   string constant's **sole** root is the trace const pool (`interp.zig:1615`). Committed traces are
   never retired (`trace.zig:639`, freed only at VM `deinit`), so the trace outlives the closure.
   That sole-root is exactly the H-2 divergence: **cross-mode** (`.off` sweeps + de-interns the string,
   a record-mode run keeps it alive → a later re-intern returns a *different* id under GC — observable
   via `pairs` order/`key_order.zig:21`, non-string `tostring`/`io.zig:166`, table capacity) **and**
   **snapshot-restore** (uninterrupted keeps it; the restored VM has neither trace nor string → fresh
   id). It is a **pre-existing** hole (`load` + trace + GC), independent of region accounting.

**Both facets share one root cause** — a trace const out-roots a proto-literal string past its chunk's
closure liveness — and that can only happen for a **dynamic** proto (step 3 proves the static tree is
immune). So: **if no trace ever touches a dynamic proto, no trace const is ever a sole root**, hence
trace consts are always redundant → cross-mode liveness is identical to tier-0's and the snapshot never
serializes a trace-only object. **The `{gc,snapshot}` root-walk split (G-2) is then unnecessary**: with
trace consts always redundant, leaving them in the shared `forEachRootHeader` walk serializes nothing
extra. (It stays available as future hardening, not a correctness dependency.)

**The gate — two checks on one deterministic predicate.**

- **Predicate `isDynamic(proto)`.** A proto is dynamic iff it belongs to a `load*`/restore-recompiled
  chunk. Two equivalent discriminators exist; the design picks the **explicit per-proto flag** for
  robustness (survives restore without a VM-field dependency, decoupled from the id scheme, per-proto so
  inlined callees are handled naturally): add a runtime-only `Proto.dynamic: bool = false` (NOT
  serialized — `Proto` is re-derived from the program image on restore, so a runtime bool is free) set
  via a new `compileWithOptions` option that is `false` for the static compile and `true` at the two
  dynamic compile sites (`stdlib/load.zig`'s `compileWithOptions`, and `keyframeser.zig`'s
  `recompileLoadedChunks`). *Rejected alternative:* the id-boundary `proto.id >= static_count` — it
  works (static compile uses `id_base=0`, `load`/restore pass `id_base = next_proto_id` so every dynamic
  proto has `id ≥ static_count`, `compiler.zig:69-73,149`) but couples the gate to the id scheme and
  needs a restored VM field for the boundary. (Open for review: is the extra `Proto` field worth it vs.
  the zero-struct-change boundary check?)
- **Anchor gate (all THREE arm sites).** Recording physically starts at `self.rec.reset(key, …)`, called
  from exactly three production arms: `arm` (`trace.zig:3657`, root traces from `onBackEdge`),
  `maybeStartContinuation` (`trace.zig:2997`), and `maybeStartReplaySide` (`trace.zig:3018`). Each must
  early-out when `isDynamic(key.proto)`. Gating only `onBackEdge` is insufficient (the round-9 "one
  choke point is not enough" lesson) — a shared `if (isDynamic(proto)) return;` guard goes at all three,
  or inside `rec.reset` itself as the single universal choke (tests build static hand-protos, `dynamic
  = false`, so a choke in `reset` is inert for them).
- **Cross-proto-inline gate (`recCall`).** A trace anchored in a *static* proto can inline a call into a
  *dynamic* callee (`recCall` switches the recorder to the callee's code, whose `load_const`s would
  capture the callee's strings into the static trace's const pool — re-opening the hole). So `recCall`
  must `abort(.dynamic_proto)` when the resolved callee `isDynamic`. Add `dynamic_proto` to `AbortReason`
  (`trace.zig:716`) for `--dump-aborts` legibility. (A non-inlined dynamic call is already safe: the
  callee runs its own tier-0 frame and its consts never enter the trace.)

**Determinism argument.** `isDynamic` is a pure function of the program's compile/load history, which is
deterministic under deterministic execution → **mode-invariant**. Post-gate, all 10 modes agree: `.off`
never traced; record modes now also never trace dynamic protos → loaded code runs tier-0 in every mode →
one id timeline. Snapshot: no trace ever holds a dynamic-proto string → `keyframeser`'s trace-const walk
(`keyframeser.zig:270` via `forEachRootHeader`) never serializes a trace-only object → restore consistent.

**Assumptions to confirm under review (each tree-checked so far):** (i) `load*` + `recompileLoadedChunks`
are the *only* populators of `loaded_chunks`/dynamic protos (verified: `stdlib/load.zig`,
`keyframeser.zig:484`); (ii) the static main closure is live at every GC safepoint during a `run`
(verified: `frames[0].closure`); (iii) `recCall` is the only cross-proto const-capture path (the recorder
only `konst`s the *currently-recording* proto's `load_const`s, so switching protos on inline is the sole
way a foreign proto's const enters the pool).

**Testing (the gate is behaviour-preserving, so the proof is presence/absence of a trace + equivalence).**
1. **Positive equivalence:** a `load`ed chunk with a hot loop is byte-identical across all 10 modes +
   keyframe restore (the code still runs, just tier-0). Extends the `expectProgram` matrix to a
   load-driven program.
2. **Gate behaviour:** a hot loop inside a `load`ed chunk records **zero** traces (its anchor is dynamic
   → never armed); the *same* loop in the static chunk records normally. Assert on trace-cache contents.
3. **Negative control (load-bearing):** neutralize the anchor gate → the load-chunk hot loop now DOES
   commit a trace anchored at a dynamic proto id → proves the gate is exactly what prevents the sole-root.
   (The full `pairs`-order determinism divergence is the underlying symptom; the trace-presence assertion
   is the crisp, reliable load-bearing check.)
4. **Cross-proto inline:** a static hot loop that inlines a `load`ed callee aborts with `.dynamic_proto`
   (assert via the abort record / `--dump-aborts`) and stays byte-identical across modes.

**Status: DESIGN — gpt-5.6-sol review = BLOCKER (necessary but not sufficient). See review outcome below.**

##### Review outcome — H-2 hard-half design, codex `gpt-5.6-sol`, 2026-07-18: BLOCKER — the gate is sound but static trace consts are ALSO sole-rootable at `depth==0`

The constant-materialization analysis (claims 1–2), the dynamic-source inventory, the three arm sites, and
the `recCall` cross-proto gate were all **confirmed against the tree**. But the review **refuted claim 3**
as used in the completeness proof, and the refutation is **tree-verified**:

- **‡ BLOCKER — the static main closure is a root only WHILE `depth > 0`, not for the VM/snapshot lifetime.**
  `forEachRootHeader` roots `frames[0..depth]` closures (`interp.zig:1612`); `run` returns after the last
  frame pops (`depth → 0`). So a static literal referenced *only* by a cached trace becomes a **sole-root
  trace const** the moment the top-level frame returns — the static tree is NOT "always redundantly rooted."
- **‡ BLOCKER — final-state snapshots hit this immediately.** `encodeSnapshot` is explicitly taken *after*
  `vm.run` returns, stack/frames empty (`keyframeser.zig:252`), reachability via the shared
  `forEachRootHeader` (`:270`). So a trace-only static const is serialized in trace modes but not in `.off`
  → restored VMs diverge. Gating **dynamic** protos does nothing for this. **⇒ the `{gc,snapshot}` split
  (G-2) is NECESSARY, not unnecessary** (the design's claim that it becomes moot is wrong and is retracted).
- **‡ BLOCKER — repeated top-level epochs.** `run`/`start` are public and allow multiple runs on one VM;
  `beginTopLevelEpoch` disarms links but does **not** clear the trace cache (`interp.zig:1041/1076`). A
  trace from an earlier run keeps a static string alive across GC in a later run while `.off` sweeps it →
  divergent re-intern id. Needs epoch-boundary trace-cache clearing (or equivalent).
- **MEDIUM — "committed traces never retire" is imprecise.** `removeTrace` exists (lane-widening,
  `trace.zig:3417`); the accurate statement is "traces are not retired based on closure/proto liveness."
- **MEDIUM — `Proto.constants` is `[]const Value`** (`bytecode.zig:247`): compiler-generated protos only
  ever hold string/number literals, but a hand-built/embedding proto could carry a heap table/closure
  constant → `load_const` would copy it into the trace pool. If the determinism guarantee covers
  embedding-created protos, an invariant/validation restricting proto constants to literal kinds is owed.
- **Confirmed:** explicit `Proto.dynamic` bit preferred over the id-boundary; gate inside `rec.reset`
  should return started/not-started (not a silent early-return the callers then `.kind=`-stamp); no tier-0
  correctness regression from gating; and the proposed tests are **inadequate** — trace presence/absence
  does not prove object-liveness parity. Need a static-hot-loop **final-snapshot** test + a repeated-`run`
  GC/re-intern test, asserting on **object ids / `pairs` order / snapshot bytes**, not trace-cache contents.

**Corrected scope — the complete fix is three cooperating parts, not one:** (1) **gate dynamic-proto
tracing** (this design — closes the mid-run dropped-`load`-closure case); (2) **the `{gc,snapshot}`
root-walk split** (closes the `depth==0` / final-snapshot facet for static *and* dynamic trace consts);
(3) **clear/retire the trace cache at `beginTopLevelEpoch`** (closes the cross-epoch GC-liveness facet).
Within a single run, static consts are safe mid-flight (main closure live) and dynamic consts are handled
by (1); the `depth==0` exposure (snapshot + next epoch) is what (2)+(3) close. **Escalated to Bart:** this
is larger than the single "don't trace load chunks" mechanism first approved. **Bart's call: land the 3
parts, split first.**

**Part (2) — `{gc,snapshot}` root-walk split — LANDED (2026-07-18).** `Vm.forEachRootHeader` gained a
`comptime kind: RootKind` (`.gc` | `.snapshot`); the two trace-const loops (`trace.cache[].consts`,
`trace.rec.consts`) are gated `if (kind == .gc)`. GC marking passes `.gc` (behaviour byte-identical —
still visits trace consts); the snapshot walk (`keyframeser.zig:270`) passes `.snapshot` and excludes them.
Load-bearing test `"H-2/G-2: snapshot bytes are identical whether or not the JIT recorded"`: a hot loop
makes a string key ("k") a trace-only const at the final (`depth==0`) snapshot; asserts `.off` and a
recording mode produce byte-identical snapshots (gc_stress off+on) + a `found_k` sanity check that a trace
with "k" actually committed. Negative-control proven (reverting the walk to `.gc` reddens exactly it,
774/775). `just test` green (default + `-Djit-debug`). **gpt-5.6-sol implementation review = APPROVE**
(no blocker): split correctly placed; `effect_log` is genuine record/replay state (correctly kept in both
walks — excluding it would risk the post-cut object-id timeline, `effectser.zig:102/121`); exclusion is
sound (every heap konst is a proto literal, traces aren't serialized, re-recording re-obtains it); test
adequate. Folded its one non-blocking doc nit (`04-snapshot-replay-schema.md`). **Remaining: (1) the
dynamic-proto gate, (3) the `beginTopLevelEpoch` trace-cache clear.**

##### Part (1) — design: gate trace recording out of the dynamic proto tree (2026-07-18)

**What (1) closes.** Part (2) stops a live trace const from *leaking into a snapshot*. It does nothing
about the *mid-run GC* facet: a `load`/`loadfile`/`dofile` chunk compiles a **separate** proto tree whose
sole closure is **not** retained anywhere durable (`vm.loaded_chunks` holds only `{chunk, source}`,
`stdlib/load.zig:145,154`; the closure is an ordinary GC value that dies when the caller drops it). Because
traces never retire, a trace recorded over that dynamic chunk keeps its proto-literal string konsts alive
(via the `.gc` walk) *after the closure is gone* — so under `record_execute*` the string survives and
under `.off` it is swept, and a subsequent re-intern gets a **different** `next_obj_id` between the two
modes. That is a live cross-mode `pairs`/id divergence with **no** `depth==0` requirement. (2) can't touch
it — it's genuine GC liveness, correctly kept in the `.gc` walk — the only fix is to **never record a trace
that can be sole-rooted by a dropped dynamic closure.** Bart's chosen direction: never anchor a recording
in, nor inline a call into, a **dynamic** proto.

**The predicate: an explicit `Proto.dynamic` bit** (gpt-5.6-sol's preference over the id-boundary
`id >= static_count`). Add `dynamic: bool = false` to `bytecode.Proto` (`bytecode.zig:238`). It is stamped
by the existing pre-order id pass `assignProtoIds` (`compiler.zig:174`), which already walks the whole
tree once and touches every proto — thread a `dynamic: bool` through it (default `false`), driven by a new
`Options.dynamic` field (`compiler.zig:67`, default `false`). Static main-chunk compiles keep the default;
the two dynamic-proto sources set it `true`: the runtime `load`/`loadfile`/`dofile` path
(`stdlib/load.zig`, the `id_base = vm.next_proto_id` compile) and the keyframe **recompile** path
(`keyframeser.zig:466`, same `id_base` idiom). Stamping it in the recompile path is what keeps a *restored*
load-chunk gated — the bit is a pure compile-time property, re-derived identically on every recompile, so
it is not serialized. Preferred over the id-boundary because it survives a keyframe restore (where
`next_proto_id` is re-seeded from the static root, `keyframeser.zig:441`) with no separate `static_count`
to store and stay in sync; the bit *is* the predicate — checked inline as `proto.dynamic`, no helper.
(The id-boundary *could* recompute the static count from the root — `seedProtoIds` (`interp.zig:1009`)
already does exactly that — so "necessarily requires serialized `static_count`" was overstated; the
explicit bit is still cleaner: no ambient boundary threaded into `TraceState`, and it works uniformly for
an inlined callee. Zig note: `assignProtoIds` takes the flag as an explicit parameter, not a defaulted one
— Zig has no default function arguments; the `false` default lives on `Options.dynamic` and `Proto.dynamic`
only. Mutating each child via the existing `@constCast` in `assignProtoIds` is sound under the
allocation-arena invariant already documented at `compiler.zig:159`.)

**The gate points (four, all determined by grounding the reset/inline sites):**

1. **`arm()` (`trace.zig:3656`)** — the single choke point for *both* root arming (from `onBackEdge`,
   `:3649`) and side-trace arming (from the `wants_side_trace` path, `:3606`), since both call
   `self.arm(proto, target_pc)`. Add `if (proto.dynamic) return;` at the top → a dynamic anchor never
   starts a root or side recording.
2. **`maybeStartContinuation()` (`trace.zig:2992`)** — arms a `.full` continuation via `rec.reset`
   directly (not through `arm`). Insert the guard **after** the pending field is cleared, not at entry:
   ```zig
   const key = self.pending_exit_anchor orelse return;
   if (self.rec.active) return;
   if (key.proto != proto or key.pc != cur_pc) return;
   self.pending_exit_anchor = null;   // consume the pending arm FIRST
   if (key.proto.dynamic) return;     // then decline to record
   self.rec.reset(...) catch return;
   ```
   Placing `if (proto.dynamic) return;` at entry (or before the null-clear) would leave a *matching
   dynamic* pending arm set, permanently forcing `.full` dispatch through `runFastPath` (`interp.zig:1720`)
   until execution unwinds (gpt-5.6-sol). Consume, then decline.
3. **`maybeStartReplaySide()` (`trace.zig:3013`)** — arms a prime side-trace via `rec.reset` directly.
   Same ordering: clear `pending_replay_anchor` first, then `if (key.proto.dynamic) return;` before reset.
4. **`recCall()` (`trace.zig:5059`, after resolving the callee proto `cp`)** — a recording *anchored in a
   static proto* can still inline-call a dynamic callee (e.g. a static loop calling a `load`ed closure each
   iteration), which would embed the dynamic proto's literal konsts into a static trace. Add
   `if (cp.dynamic) return self.abort(.dynamic_proto);` — a new `AbortReason.dynamic_proto`
   (`trace.zig:716`). This is the only new abort; it fails the recording cleanly (tier-0 unaffected) and
   gates the static anchor with the normal backoff.

**Why four and not one:** (1) covers root+side arming (shared `arm`); (2)/(3) are the two `.full`-pinning
arms that bypass `arm` and reset the recorder themselves; (4) is the *inlining* direction — a static trace
reaching into a dynamic callee. Miss any one and a dynamic proto's konst can still enter the trace-const
set. There is no fifth `rec.reset` production site (the remaining `rec.reset` calls in `trace.zig` are all
in `test` blocks).

**Determinism argument.** Whether to record is a JIT-tiering decision; determinism requires it be a pure
function of deterministic state. `proto.dynamic` is a **static compile-time property**, identical across
all 10 modes and re-derived identically on every keyframe recompile. So every mode makes the *same*
decision — dynamic-proto code is never traced in any mode — which means the trace-const set never contains
a dynamic proto's literals in *any* record mode, and `.off` (which has no traces at all) trivially agrees.
The mid-run GC facet is closed: no trace can be the sole root of a dropped-dynamic-closure's string,
because no such trace is ever recorded. No new nondeterministic input is introduced (the bit is not a
clock, RNG, or address).

**Cost.** One bool per `Proto` (compile-time, cold). Four branch checks, all on cold arm/abort paths — the
hot dispatch loop is untouched. Dynamic chunks lose JIT coverage; this is the intended trade (correctness
over speculative speed on rarely-hot `load`ed code, and LuaJIT itself does not persist traces across the
proto lifetimes we're protecting here).

**Tests** — the naive "intern a fresh string, compare its id" is **not** load-bearing (gpt-5.6-sol,
tree-verified); a genuinely fresh string gets the same new id in both modes regardless (keeping a stale
literal alive consumes no id — its allocation already happened identically in both). And `tostring`/`print`
of a **string** emits raw bytes (`basic.zig` `bToString`, `io.zig:164`), never its id — so id must be
observed through `pairs` **order** of string keys, not `tostring` of the string. The correct construction:
- **Cross-mode id parity over a dropped load-chunk** (the core regression). `load` a chunk whose hot loop
  reads a string literal *inside the loop* as a table field (`t.victim`, so it is a `load_const` trace
  konst, **not** a pre-loop `slot_load`). Run it hot enough to record; **then**, in this id order:
  1. dynamic literal `"victim"` → interned at id **A** (inside the loaded chunk);
  2. drop the loaded closure and allocate a retained **marker** string → id **B** (`B > A`);
  3. force real collection, then reconstruct the *same literal content* `"victim"` and put both it and the
     marker as keys in a fresh table and `print` the `pairs` order.
  - **traced (pre-fix, `record_execute*`):** the konst kept id **A** alive, so `"victim"` re-interns to the
    live A and sorts **before** the marker B.
  - **`.off`:** `"victim"` was swept, re-interns to a fresh id **C** (`C > B`), so the marker sorts first.
  → divergent `pairs` order ⇒ `expectProgram` reddens pre-fix; with the gate the dynamic loop is never
  traced, `"victim"` is swept in every mode alike, and all modes agree.
  - **Non-stress half needs real GC pressure:** `collectgarbage` is **unimplemented**, so the test can't
    force a cycle directly — the non-stress modes must allocate enough throwaway objects to cross the actual
    GC threshold, or half the 10-mode matrix (gc_stress off) never sweeps and stays trivially green.
- **Static caller inlining a dynamic callee aborts** (covers gate 4). The `load`ed callee must be a
  **fixed-arity nested function** — `load("return function(x) ... end")()` — because a *directly* loaded
  root is `vararg_root = true` (`load.zig:115`) and `recCall` already aborts it at `cp.is_vararg`
  (`trace.zig:5061`); only a non-vararg dynamic callee proves gate 4 is what fired. Assert the abort reason
  is `.dynamic_proto` (jit-debug `--dump-aborts` / abort-log probe), not `.cross_frame`.
- **Restore keeps the bit** (covers the `keyframeser.zig:466` stamp — none of the live-run tests would
  catch forgetting it): restore a snapshot containing a live loaded closure and assert its root **and**
  nested protos have `dynamic == true` (or run it hot post-restore and assert no trace records). Without
  this, dropping the recompile-site stamp passes every live-run test.
- **Static tracing is unaffected**: an equivalent all-static program still records and runs native (guard
  against over-gating — `proto.dynamic` must be `false` for the main tree).

**Sequence:** design (this) → `gpt-5.6-sol` review (**done — BLOCKER, corrections folded above**) → land
behind `just test` (default + `-Djit-debug`).
Part (3) (the `beginTopLevelEpoch` trace-cache clear, closing the *cross-epoch* `depth==0` facet) follows.

**Review outcome — Part (1) design, `gpt-5.6-sol`, 2026-07-18: BLOCKER (on design/tests), mechanism
APPROVED.** Confirmed the four-gate set is *complete* for the mid-run facet — the only production
`rec.reset` sites are `maybeStartContinuation`/`maybeStartReplaySide`/`arm` (rest are `test` blocks),
`arm` covers both root and `wants_side_trace` arming (`trace.zig:3603`), the only heap-capable konst is
`load_const(proto.constants[b])` (`trace.zig:3992`), and `recCall` (`trace.zig:5033`) is the only
proto-crossing point. Approved the explicit `Proto.dynamic` bit. The BLOCKER was two-fold and both are
folded above: **(a)** the two `maybeStart*` guards must be placed *after* the pending-anchor null-clear or
a dynamic pending arm permanently pins `.full` dispatch; **(b)** the proposed regression test was not
load-bearing — fixed to the marker/`pairs`-order construction, `t.victim` in-loop konst, real GC pressure
for the non-stress half (`collectgarbage` unimplemented), a non-vararg nested-function callee for gate 4,
and a restore-time `dynamic == true` assertion for the `keyframeser.zig:466` stamp. With those, the
reviewer would approve. Tree-verified all cites before folding (`basic.zig` `bToString`, `io.zig:164`,
`load.zig:115`, `collectgarbage` absent).

**Part (1) — LANDED (2026-07-18).** `Proto.dynamic` (`bytecode.zig`) stamped by `assignProtoIds` via
`Options.dynamic` (`compiler.zig`); set `true` at the `load`/`loadfile`/`dofile` compile site
(`stdlib/load.zig`) and the keyframe recompile site (`keyframeser.zig`). Four gates in `trace.zig`:
`arm` (root + side arming), `maybeStartContinuation`/`maybeStartReplaySide` (guard after the pending-anchor
null-clear), and `recCall` → `abort(.dynamic_proto)` (new `AbortReason`). Tests: (A) dynamic loop records
zero traces / static records one; (B) static caller inlining a fixed-arity dynamic callee aborts
`.dynamic_proto`; (C) restored load-chunk protos are `dynamic == true` (whole tree); and the **end-to-end
cross-mode determinism regression** — a dropped load-chunk's `"victim"` re-interns to a divergent id under
record-vs-`.off` *without* the gate, so its `pairs` order diverges; `expectProgram` (all 10 modes) asserts
byte-identical `"marker victim"` *with* it. All four verified load-bearing by negative control (each
gate/stamp reverted reddens exactly its test; the e2e reddens at both CLI and unit level, both gc_stress
values). `just test` (779) + `-Djit-debug` green. Gates (2)/(3) are defensive — unreachable once `arm`
blocks a dynamic anchor from acquiring an initial trace, so they carry no dedicated test (belt-and-braces).
**gpt-5.6-sol implementation review = APPROVE** ("production implementation and its determinism argument
are approved"; no change to production hunks required). **Remaining: part (3) — the `beginTopLevelEpoch`
trace-cache clear.**

##### Part (3) — design: clear the trace cache at `beginTopLevelEpoch` (the cross-epoch facet) (2026-07-18)

**What (3) closes.** Parts (1)+(2) handle dynamic protos and the *snapshot* walk. The last facet is
**static-tree trace consts surviving across a top-level epoch boundary.** A lune VM can run more than one
top-level epoch (`vm.run`/`vm.start` called again — REPL, embedder, restore-then-continue). `run` calls
`beginTopLevelEpoch` at a *clean* entry (`depth == 0`, `interp.zig:1041`). At `depth == 0` **no frame
closure roots the static proto tree** — `forEachRootHeader` roots only `frames[0..depth]` closures, and
`markProtoConstants` recurses only from a *live* closure (`gc.zig:512`). So between epochs a static proto
literal (e.g. a string key `"foo"`) is rooted by **nothing except a cached trace's const**. In a
`record_execute*` mode that trace (recorded in epoch N) keeps `"foo"` interned across the boundary; under
`.off` there is no trace and `"foo"` is swept. Epoch N+1 re-interning `"foo"` then gets a **different**
`next_obj_id` between the modes → the same cross-mode `pairs`/id divergence as part (1), but triggered at
the epoch boundary rather than by a dropped dynamic closure. Part (1)'s gate does not help (these are
*static* protos, legitimately traced within their epoch); part (2)'s snapshot split does not help (this is
GC liveness, not serialization). The only determinism-preserving fix is to **not carry a trace's
GC-rooting across an epoch boundary** — free the trace cache at `beginTopLevelEpoch`.

**The mechanism: a mid-life `clearCache()` on `TraceState`, called from `beginTopLevelEpoch` after the
existing `disarmAllLinks()`.** This is a *mid-VM-life* free (the VM keeps running — NOT `deinit`, which
also tears down `mcode_arena`). Reuse the safe-free discipline already proven by `removeTrace`
(`trace.zig:3431`) and `deinit` (`trace.zig:1341`):
- **Ordering makes link-cleanup trivial.** `beginTopLevelEpoch` already calls `disarmAllLinks()` first,
  which resets every armed parent slot to `shared_exit` **and** empties `armed_links`
  (`clearRetainingCapacity`, `trace.zig:3428`). So by the time `clearCache()` runs there are **no inbound
  native links** to any cached trace — no per-trace `resetLinksTouching` needed.
- **Free + clear:** `for (self.cache.items) |t| t.destroy(self.gpa);` (each `destroy` returns its mcode
  slots to the *retained* `mcode_arena` free-list, exactly as `deinit` does — the arena is reused, not torn
  down) then `self.cache.clearRetainingCapacity();`.
- **Reset the anchor-keyed tiering state** so epoch N+1 re-warms cleanly and no stale entry references a
  freed trace or suppresses re-recording: `counters`, `hotcount` (`@memset` to 0), `gate`, `penalty`,
  `guard_failures`, `prime_exits` (all `clearRetainingCapacity`), and null the epoch-local "already hot"
  scalars `wants_side_trace`, **`wants_prime_side`** (`trace.zig:1250` — parallel to `wants_side_trace`,
  populated from `prime_exits`/guard failures at `trace.zig:3168`; clearing `prime_exits` without nulling
  this leaves a stale `AnchorKey` that address reuse could make epoch N+1 arm on), `pending_exit_anchor`,
  and `pending_replay_anchor`. This mirrors the counter reset `removeTrace` does per anchor, wholesale.
- **Clear the trace-index-keyed and `*Proto`-borrowing diagnostic state** (gpt-5.6-sol — these are *not*
  safe to retain across the boundary):
  - **`exec_logs` + the recorder.** Execution logs are keyed by `trace_id`, and `trace_id` **is the cache
    index** (`traceIndex`, `trace.zig:1550`; `execLogFor`, `trace.zig:1539`). After the cache is cleared,
    epoch N+1 reuses index 0 and would append its events to epoch N's log (`trace.zig:1432`). Worse, log
    events can hold string `Value`s and `exec_logs` is **absent from the GC root walk** (`interp.zig:1635`),
    so once the trace-const root is gone a later sweep leaves dangling string values in a retained log.
    Fix: `for (self.exec_logs.items) |*l| l.deinit(self.gpa)`, `exec_logs.clearRetainingCapacity()`, and
    null the recorder's current log target (`exec_recorder.?.log`).
  - **`coverage` map.** `AnchorCoverage.has_trace` means "a trace currently exists" and classifies later
    tier-0 iterations (`trace.zig:919,1366`); leaving it true after bulk retirement corrupts the report.
    More seriously the map key borrows a `*Proto` that reporters dereference (`coverageser.zig:77`,
    `trace.zig:5756`), which conflicts with `Vm.run`'s contract that a proto is only valid *during* its
    call (`interp.zig:1060`) — a chunk freed between epochs would dangle. Fix: `coverage.clearRetainingCapacity()`
    at the boundary; keep only the **scalar lifetime aggregates** (`iters_traced`, `cycles_traced`,
    `run_cycles`, … — pure `u64`s, no borrowed pointers).
  - **`abort_log`.** `AbortRecord` explicitly borrows a `*Proto` (`trace.zig:749`) and rendering
    dereferences `r.proto.name` (`trace.zig:5621`); retaining it across independently-owned chunks is a
    diagnostic UAF. Fix: `abort_log.clearRetainingCapacity()` per epoch.
- **Left untouched (deliberately):** `mcode_arena` (reused — `Trace.destroy` returns each slot to its
  free-list, `nativegen.zig:312`), `next_trace_id` (monotonic — prevents old native/result/log identities
  from aliasing later traces), `tick` (monotonic; safe because `gate` is cleared, so no surviving retry
  deadline depends on its old value), and the scalar coverage/lifetime `u64` aggregates. `values_scratch`,
  ledger scratch, and the inactive `Recorder` hold no persistent `*Trace` and need no reset.

**Why entry/arming stays self-consistent after the free.** Trace *entry* and *re-arm* both scan `cache`
(via `findTrace`/`hasTrace`), never a cached "already traced" flag — so an empty `cache` is authoritatively
"no trace here" for every consumer. Freeing the traces and clearing `cache` in one step can't leave a path
that enters a freed trace.

**Determinism argument.** `beginTopLevelEpoch` is **mode-independent** — every mode (including `.off`, whose
cache is always empty so the clear is a no-op) reaches it at the same deterministic point (a fresh
`run`/`start` with `depth == 0`). Clearing there means trace-const GC-rooting **never crosses an epoch
boundary in any mode**, so between epochs the interned-string liveness of a record mode matches `.off`
(neither holds a live trace root), making every cross-epoch re-intern id identical across all 10 modes. No
nondeterministic input is introduced; the clear is unconditional and its *position* (epoch entry) is the
determinism boundary. It only ever touches JIT scratch state, never `Value` / heap semantics.

**Interaction with suspend/resume.** `beginTopLevelEpoch` runs **only** on the fresh `run`/`start` entry,
never on `exec()` resume after a `.suspended` (`interp.zig:1031-1033`) — so clearing there cannot discard a
trace mid-continuation of the *same* epoch. Safe by the existing clean-entry contract.

**Cost.** Multi-epoch embedders/REPL re-warm the JIT each epoch (LuaJIT persists traces across a REPL; lune
cannot, by the determinism-over-speed asterisk). Single-epoch CLI runs are unaffected — the clear is a
no-op at the one `beginTopLevelEpoch` of a one-shot `run` (cache still empty). This is the intended trade.

**Tests.**
- **Cross-epoch id parity** (the core regression): a custom two-epoch harness (like the `keyframeser`
  restore tests — `expectProgram` is single-`run`). On **one** VM: epoch 1 runs a hot loop reading a static
  string key `t.foo` (records a trace whose const is `"foo"`); epoch 1 returns (`depth==0`); epoch 2
  (`vm.run` of a second chunk on the same VM) allocates a marker string, forces GC, re-interns `"foo"` at
  runtime (`"f".."oo"`), and reports the `pairs` order. Assert byte-identical order for a recording mode
  vs `.off`, both `gc_stress` values. Negative control: skipping the `clearCache()` reddens it (the epoch-1
  trace keeps `"foo"` at its old id in the record mode).
- **Clear is a no-op for a single run**: an ordinary static-loop program still records exactly one trace
  and prints correctly (guard against the clear firing mid-useful-run — it must only fire at entry, when
  the cache is empty).
- **Multi-epoch still JITs**: after the epoch-1 clear, an epoch-2 hot loop still records a fresh trace
  (guard against the counter/gate reset accidentally wedging re-recording).
- **Direct `clearCache()` reset assertion** (gpt-5.6-sol): after a run that populates traces + exec logs +
  coverage + abort rows, assert every field in the reset set is empty/null — `cache`, `counters`, `gate`,
  `penalty`, `guard_failures`, `prime_exits`, `exec_logs`, `coverage`, `abort_log` empty; `wants_side_trace`,
  `wants_prime_side`, `pending_*` null; `hotcount` all-zero — so a future field added to the recorder isn't
  silently missed.

**Sequence:** design (this) → `gpt-5.6-sol` review (**done — BLOCKER: reset set was incomplete; folded
`wants_prime_side`, `exec_logs`+recorder, `coverage` map, and `abort_log` above, all cross-epoch
`*Proto`-borrow / cache-index-reuse hazards**) → land behind `just test` (default + `-Djit-debug`).
This completes the three-part H-2 hard-half fix.

**Part (3) — LANDED (2026-07-18).** `TraceState.clearCache()` (`trace.zig`) destroys every cached trace
(mcode slots returned to the *retained* `mcode_arena` free-list — mid-VM-life, not `deinit`) and resets the
full reset set from the design: anchor-keyed tiering (`counters`, `hotcount`, `gate`, `penalty`,
`guard_failures`, `prime_exits`, `wants_side_trace`, `wants_prime_side`, `pending_exit_anchor`,
`pending_replay_anchor`) plus the trace-index-keyed / `*Proto`-borrowing diagnostic state (`exec_logs` +
`exec_recorder.log`, `coverage`, `abort_log`). `Vm.beginTopLevelEpoch` (`interp.zig`) calls it right after
`disarmAllLinks()` (whose emptied `armed_links` is the precondition that makes a wholesale free safe with
no per-trace `resetLinksTouching`). Tests: (A) cross-epoch id-parity e2e across all four record modes ×
`gc_stress{on,off}` — one VM, epoch 1 records a `t.foo` trace, epoch 2 re-interns `"foo"` at runtime and
reports `pairs` order; every record mode matches `.off` ("marker foo "). The harness **interleaves
compile+run per epoch** (parse+compile+run epoch 1, *then* epoch 2) because string literals intern weakly
— compiling epoch 2 up front would let epoch 1's GC sweep its not-yet-live constants (a real latent
product concern in its own right, see below). (B) a direct `clearCache()` reset assertion with a
*populated* coverage map (`config.coverage = true`, asserting `coverage.count() >= 1` pre-clear so the
coverage clear is load-bearing) checking every reset field empty/null. (C) a second-epoch re-record test
proving the JIT still warms after the clear. All load-bearing by negative control. `just test` (782) +
`-Djit-debug` green. **gpt-5.6-sol implementation review = APPROVE** ("no implementation correctness
blocker"), with two non-blocking test improvements applied (added `record_execute_noopt` to the modes
loop; made the coverage clear load-bearing). **This completes the three-part H-2 hard-half fix — H-2 is
closed.**

**Latent product concern surfaced by the part-(3) harness (separate ticket, Rule #10).** A freshly
`compile`d-but-not-yet-run chunk's **heap-valued constants** (interned string literals) are rooted by
**nothing** — `Chunk` does not root them, and `gc.zig` marks them only via a *live* closure
(`markProtoConstants` recursing from `frames[0..depth]`). So if another epoch's GC runs between compiling a
chunk and first-running it (or under `gc_stress`), those constants are swept and the chunk's `load_const`s
dangle. Not a part-(3) defect (the fix is a harness-level interleave, and a real program runs a chunk
immediately after compiling it), but it *is* a genuine latent hole in the compile→run window that
gpt-5.6-sol confirmed deserves its own ticket. Noted so it isn't lost.

#### Foundational piece 2 — H-1b design: name the source-opcode PC distinctly from the resume/exit PC (Bart, 2026-07-18)

**Scope (Bart's call):** land the **H-1b** sub-part of the H-1 guard-provenance blocker as
foundational, non-breaking work that shrinks round-9 scope. H-1b (codex) is the observation that the
recorder **conflates two different PCs into one**: `recordInstr` is handed the *post-increment* PC
(`interp.zig:1762` passes `pc.*` = `cur + 1`), stores it as `rec.cur_pc` (`trace.zig:3961`), and
`emit` stamps *that* into the guard's `aux` (`trace.zig:4094`). So the only PC a committed guard
carries — read back through `guardExitPc` — is the **resume/exit PC**, not the **source-opcode
index**. `GuardProvenance` (G-1) needs the source-opcode PC as its `source_pc` identity field; today
every consumer that wants it re-derives `guardExitPc(g) - 1` by hand.

**Grounding (verified against the tree, 2026-07-18):**

- **The two PCs have a fixed, exact relationship at emission** — but *only numerically*, and that is
  precisely why the conflation is a latent hazard rather than a live bug. The fetch in `step`
  (`interp.zig:1727-1732`) always does `cur = pc.*; cur_pc.* = cur; pc.* = cur + 1` **before** the
  recording mirror, and jumps are applied by the *executor* after `recordInstr`, never before it. So
  at emission `rec.cur_pc == source_pc + 1` holds for **every** opcode (fixed-width `Instr`, one code
  slot each; no multi-word opcode). The split is therefore about **naming and robustness**, not about
  recovering a number that is currently lost.
- **`exit_pc` (the guard `aux`) is NOT the tier-0 deopt resume cursor.** On an ordinary guard failure
  tier-0 resumes at the **loop header / anchor** with `regs` untouched (`irinterp.zig:7-9,222`), then
  re-executes. `exit_pc` is used as a **control-flow / continuation target**: the numeric-for
  loop-done fall-through (`code[exit_pc-1].op == for_loop`), the exit-PC chaining anchor
  (`driveChain`), and the `(anchor, exit_pc)` guard-failure accounting key. Renaming the source-opcode
  derivation must therefore **not** touch any `exit_pc` value — only give the `-1` a name.
- **Only six ops carry a PC in `aux`**: `guard_int/float/number/true/false` + `int_of_float`
  (`guardExitPc`, `trace.zig:451-455`). The array/table/grid guards (`guard_lane`/`guard_fits`/…)
  reuse `aux` for lane ordinals and are **not** yet provenance-tagged — extending provenance to them
  is the *rest* of H-1 (G-1's "all guard kinds"), explicitly **out of scope for H-1b**.
- **Eight sites hand-derive the source opcode as `code[guardExitPc(g) - 1]`**: `irinterp.zig:229`,
  `trace.zig:470 / 2528 / 2889 / 2940 / 3069`, `nativegen.zig:3396 / 3618`. Each re-encodes the "+1"
  convention independently — the maintenance smell H-1b removes.

**The landing (recommended shape — minimal, non-breaking, no per-guard storage):**

1. **Add one canonical accessor** `pub fn guardSourcePc(ins: IrInstr) ?u32` in `trace.zig`, defined as
   `if (guardExitPc(ins)) |e| (if (e == 0) null else e - 1) else null` — the **source-opcode index**
   that owns the guard, i.e. `GuardProvenance.source_pc`. Documented as the *single* definition of
   "which bytecode op does this guard belong to," to be read by the future provenance tag and by every
   existing `-1` site. Its sibling `guardExitPc` keeps its exact meaning (the resume/exit/continuation
   PC). Two named accessors = the two "distinct" PCs codex asked for, storing only the one number
   (`aux`) that is actually independent — the other is exactly derivable, so a redundant per-`IrInstr`
   field would be pure hot-buffer bloat (CLAUDE.md perf rule) with no information gain.
2. **Centralize the eight derivations** onto `guardSourcePc`: replace each `code[guardExitPc(g) - 1]`
   with `code[guardSourcePc(g).?]` (the `.?` is safe at every site — all are already gated by a
   successful `guardExitPc` + `exit_pc != 0` range check, so `guardSourcePc` is non-null there).
   Behaviour-identical (`source = exit − 1`); it just removes eight open-coded copies of the
   convention.
3. **Fix the conflated documentation (review-corrected scope).** `recordInstr`'s comment is **already
   correct** — it says "`pc` is the *post-increment* program counter" (`trace.zig:3952`); leave it. The
   comments that actually mis-name the PC as the source opcode are three: **(a)** `RecState.cur_pc`
   (`trace.zig:5372-5375`, "Bytecode PC of the instruction currently being recorded … `emit` stores it
   in the `aux` field"); **(b)** `emit`'s own comment (`trace.zig:4082-4086`, "the current bytecode PC
   is stored in `aux`"); **(c)** `guardExitPc`'s doc (`trace.zig:442-450`), which says "**ONLY**
   `guard_int/float/number/true/false`" and "the **five** PC-carrying guards" but the switch (and the
   whole design) includes `int_of_float` — it is **six**. Correct all three to say *post-increment
   resume/exit PC*, fix the "five"→"six" miscount, and cross-reference `guardSourcePc` as the
   source-opcode identity. (The field name `cur_pc` stays — a rename touches the 6 stamping call sites
   for zero behaviour gain; deferred to the G-1 provenance restructure.)
4. **Pin the invariant with an INDEPENDENT test + determinism (review-corrected).** The first draft's
   test (`guardSourcePc(g).? + 1 == guardExitPc(g).?`) is **tautological** — with `guardSourcePc`
   *defined* as `exit - 1` the assertion is true even when the derived "source" is wrong, so it cannot
   catch a changed fetch order or a future multi-slot opcode. The real test records an opcode at a
   **known bytecode index `N`** and asserts `guardSourcePc(g).? == N` **and** `guardExitPc(g).? == N + 1`
   — comparing the accessor against an *independently known* source index, which is what actually locks
   the "+1" fetch contract. Coverage note: the production recorder only emits `guard_int`/`guard_float`
   (`guardNum`, `trace.zig:4165`) — it **never** emits `guard_number`, so that op (and `int_of_float`,
   which is emitted synchronously while recording its owning `for_loop`/`for_prep` at `trace.zig:4868 /
   4972`, `aux` then overwritten by the same stamping switch) is covered by an explicit recorder-level
   `emit` fixture at a known PC rather than an end-to-end recorded program. No observable output
   changes, so the **10-mode determinism matrix is unaffected by construction** — nothing on the wire,
   in stdout, or in a keyframe moves; `just test` (default + `-Djit-debug`) is the gate.

**Why this is genuinely useful and not just churn:** it converts the "+1" convention from eight
undocumented open-coded assumptions into one asserted, named definition that the round-9
`GuardProvenance` work reads directly for `source_pc` — so H-1's remaining scope drops by exactly the
"where does `source_pc` come from, and is it stable" question. It changes **no** runtime behaviour and
**no** serialized bytes.

**Alternative shape (heavier — recorded here, deferred unless review demands it):** thread the
source-opcode PC (`cur`) explicitly from the dispatch loop into `recordInstr` as a distinct parameter
and store it in a new `rec.source_pc` field (and, for the full provenance record, a per-guard source
field). This buys robustness if a future opcode ever occupies multiple code slots or a guard's exit
target ever legitimately diverges from `source + 1` — at the cost of hot-path plumbing and per-guard
memory that today stores a derivable value. Recommendation: **defer to the G-1 provenance landing**,
which restructures the guard record anyway; H-1b ships the accessor + centralization now. Put to
`gpt-5.6-sol` review before coding (governing workflow); Antigravity only if the review surfaces a
robustness objection to the derived-accessor choice.

**Review outcome — `gpt-5.6-sol`, 2026-07-18 = NEEDS-CHANGE (not a soundness blocker), then LAND.**
The mechanism is confirmed sound and non-breaking: `source_pc == exit_pc − 1` is exact at emission for
**all six** PC-carrying ops incl. `int_of_float` (fetch `interp.zig:1727-1732`; one `Instr` per
`Proto.code` slot `bytecode.zig:174/238`, one append per op `compiler.zig:291`; jumps applied *after*
`recordInstr`; `tropt.zig:535` preserves the stamped `aux`); all **eight** `.?` unwraps are non-null at
their index (each gated by a successful `guardExitPc` + nonzero/range check, incl. `nativegen.zig:3618`
whose gate is caller-established via `isNumericForLoopDoneGuard`); it touches **no** `aux` value,
control-flow target, IR layout, or serialized field (`traceser.zig:66` writes `aux` unchanged); the
guest-observable determinism claim holds by construction. Three required corrections, all folded into
points 3–4 above: **(i)** the invariant test was tautological → replaced with an *independent
known-index* assertion; **(ii)** `guard_number` is never recorder-emitted (`guardNum` picks int/float
only) → covered by an explicit `emit` fixture; **(iii)** the doc-cleanup scope was wrong (`recordInstr`
already correct; the real fixes are `RecState.cur_pc`, `emit`'s comment, and `guardExitPc`'s "five"→"six"
miscount). No Antigravity round needed (no robustness objection to the derived-accessor choice).

**LANDED 2026-07-18 — `just test` green (772, default + `-Djit-debug`), nsieve tier-0==tier-1a==native
byte-identical.** Shipped exactly the recommended shape: new `pub fn guardSourcePc(ins) ?u32` in
`trace.zig` (= `guardExitPc − 1`, null on the 0 sentinel), the eight open-coded `code[guardExitPc(g)−1]`
derivations rerouted through it (`irinterp.zig:229`; `trace.zig:489/2548/2909/2960/3089`;
`nativegen.zig:3396/3617` — the last dropping a now-dead `exit_pc` local), the three conflated doc
comments corrected (`RecState.cur_pc`, `emit`, `guardExitPc` "five"→"six") plus a stale
`countProductiveBranchExit` identity comment. Test `"guardSourcePc: source-opcode PC is exit PC − 1
(H-1b), pinned independently"` uses the review-mandated *independent known-index* assertion (recorded
`get_index` at chosen N ⇒ `guardSourcePc==N`, `guardExitPc==N+1`) + an `emit`-fixture for
`guard_number`/`int_of_float` + null-accessor cases; **proven load-bearing** — dropping the `−1` in
`guardSourcePc` reddens 16 tests (10 fail + 6 crash), the accessor is now the single owner of the "+1"
fetch convention. No `aux`/wire/control-flow value changed. **H-1's remaining round-9 scope: `source_pc`
is now a named, tested, single-owner accessor — `GuardProvenance` reads it directly.**

#### H-5 grounding (Bart, 2026-07-18) — both hazards GROUNDED, and both are REAL (not N/A). No code.

Grounding pass on the two round-8 "needs grounding" H-5 items (`gpt-5.6-sol` adversarial review, every
finding re-verified against the tree). The going-in hypothesis was "both discharge as N/A"; the review
**refuted both**, and the value of the pass is exactly that it found two real issues — one that folds
into H-2, one latent behind F-5.

**H-5(ii) — "JIT-metadata id leakage" → REFUTED as N/A; it is the H-2 mechanism, not a separate item.**
The *narrow* claim holds: `next_obj_id` is bumped only by `gc.Heap.link` (`gc.zig:122-126`, called from
the five guest-object creates), and **no trace metadata calls it** — `Trace` structs are `gpa`
(`trace.zig:3856`), carry no embedded `GcHeader` (`trace.zig:637`), and native mcode is the mmap arena
(`nativegen.zig:299`). But the *broad* conclusion ("JIT can't make `next_obj_id` tier-dependent") is
**false**: cached / in-progress trace consts are GC roots (`interp.zig:1560/1583`), so a trace-rooted
interned string **survives a sweep tier-0 would collect** (`gc.zig:531/542`); a later re-intern then
allocates a replacement under tier-0 (bumps the counter, `gc.zig:369`) but *reuses* the rooted original
under the JIT (no bump) → **tier-dependent counter + intern identity**, and the snapshot walk uses the
same roots (`keyframeser.zig:268`). That is precisely **H-2's hard half** (weak-intern reconciliation +
the `{gc,snapshot}` root split). *Conclusion: H-5(ii) ⊆ H-2 — no independent discharge; the direct
metadata-leak is confirmed absent, the liveness/intern drift is tracked under H-2.* **Correction to a
stale premise:** traces do **not** currently materialize `new_table`/`concat`/`closure` — those abort
recording `.nyi_opcode` (`trace.zig:4093`), so tier-1a/native allocate no such guest objects today.

**H-5(i) — "dead-register poisoning" → REFUTED as safe-by-design; it is a REAL latent coherence gap,
currently unreachable only because of the F-5 harness limitation.** Confirmed: a cut is observed only
in tier-0 `step` (`interp.zig:1716`), native runs are a synchronous trampoline call that returns
through `shared_exit` (`nativegen.zig:225`), unsafe windows disarm all links before native entry
(`interp.zig:2632/2643`), and F2c serializes only after `Vm.start` returns `.suspended`
(`keyframeser.zig:1831/1836`) — so **no snapshot is ever cut while a native frame is physically live**.
But the register-coherence claim is **false**: numeric-`for` traces deliberately **omit** dead
expression temporaries from the exit snapshot — a slot `>= locals_watermark` that is not entry-read is
dropped from the φ writeback (`trace.zig:3761`, permanent proof `interp.zig:9180` "dead expression
temporaries are dropped from the exit snapshot"). Such a slot is neither `.carried`/`.invariant`/
`.write_only` — it is **absent from the classification** (`nativegen.zig:1996`), so after a native run
its physical slot holds a **stale pre-entry value** while tier-0 would have overwritten it that
iteration. Keyframes serialize every physical slot through `stack_top` (`keyframeser.zig:279`), so an
immediate **post-native-exit** mid-execution cut would serialize **different bytes** than tier-0 (and,
if the stale value is a heap ref, different reachability). This is *not* Antigravity's "JIT writes nil"
but the adjacent real mechanism: the JIT deliberately performs **no** write, retaining a stale slot.
*It is unreachable today only because F2c's mid-execution harness is tier-0-only* (fresh VMs with
tracing off, `keyframeser.zig:1972/2014`) — i.e. exactly the **F-5** gap. *Conclusion: H-5(i) ⊆ F-5,
and F-5 is upgraded from "unverified proof obligation" to "has a concrete coherence bug to catch."*
When native-F2c mid-execution cuts land, the fix must either flush the omitted temporaries at a
cut-eligible native exit, exclude those physical slots from the snapshot, or forbid a cut immediately
after a native exit — decided in that pass, not here.

**Net:** neither H-5 item is independently closeable. **H-5(ii) folds into H-2** (do not re-derive it);
**H-5(i) folds into F-5** and makes the native-F2c test *mandatory before* native mid-execution cuts,
because it will fail on the omitted numeric-`for` temporaries unless they are reconciled. No Antigravity
round — the counterexamples are concrete and tree-verified (incl. a permanent proving test), not a
judgment call.

#### H-1a grounding (Bart, 2026-07-18) — the inline call-site path the recorder must carry. No code.

Grounding pass on H-1a (round-8: "`inline_depth` identifies nesting, not the call PATH — `f(a); f(b)`
inlined in one trace give both guards inside `f` identical provenance"). Establishes exactly what the
recorder stores for inlining today vs what `GuardProvenance.source_pc`/`inline_depth` needs, so the
round-9 provenance landing is turnkey. **`gpt-5.6-sol` review = grounding CONFIRMED directionally with
three sharpenings (folded in below): (1) the path lives in the live VM stack, not just "lost"; (2) it is
the *necessary-not-sufficient* static-inline prefix — full identity still needs role/operand/occurrence,
and must be ordered not multiset; (3) proto-id uniqueness is a compile/`load`-model precondition, not a
`Proto` invariant.**

**What the recorder tracks for an inlined call today** (`Recorder`, `trace.zig:5428-5447`):
- `inline_depth: u8` — number of open inlined calls (0 at the anchor). *This is the bare nesting
  integer H-1a flags as insufficient.*
- `base_off: u32` — the current frame's absolute slot offset relative to the anchor base; drives the
  register-window renaming (`refOf`/`setReg` add it). A pure function of the **caller frame layout**
  (`caller_base_off + caller_proto.num_registers`, `recCall` `trace.zig:5069`).
- `frames: [MAX_INLINE_DEPTH]InlineFrame`, one per open call, where
  **`InlineFrame = { base_off, ret_dest, ret_count }`** (`trace.zig:5324`) — the caller's slot offset,
  the call's result register (`instr.a`), and how many results it wants (`instr.c`).

**The gap (confirmed, and it is a real collision — not a theoretical one):** `InlineFrame` stores
neither the **caller proto id** nor the **call-site PC**. `recCall` *has both in hand* when it pushes
the frame — `proto` is the caller proto (so `proto.id`) and `instr`/`cur_pc` locate the `.call` — but
it discards them (`trace.zig:5095-5099` pushes only `{base_off, ret_dest, ret_count}`). So for
`f(a); f(b)` where both calls inline into one trace, every guard recorded inside `f` carries an
identical `{callee_proto=f, source_pc, inline_depth=1}` — **and `base_off` is identical too**, because
`base_off` depends only on the caller's register-window layout, not on *which* `.call` opcode opened the
frame (both calls in the same caller produce `callee_base_off = base_off + caller.num_registers`). Even
`ret_dest` collides when both calls target the same result register. **The call-site PATH is
unrecoverable from any current *recorder* state** — I checked `base_off`, `ret_dest`, `reg_map`, and the
return wiring; none encodes which call opcode led into the frame. (Review nuance: the path is *not*
absent from the live VM — during tier-0 recording the physical call stack still holds it, since the
interpreter writes the post-call resume PC into `frame.pc` before descending (`interp.zig:2226`) and
each `CallFrame` keeps its closure/proto, so the caller frame yields `caller_proto_id =
frame.closure.proto.id`, `call_pc = frame.pc − 1`. That is exactly the information `recCall` already has
in hand via `proto` + `cur_pc`; it simply isn't threaded into `InlineFrame`. So the fix is "persist what
recCall sees," not "recover something lost.")

**The minimal fix (matches G-1's `GuardProvenance`):** extend `InlineFrame` with two fields set in
`recCall` at push time —
```
InlineFrame = { base_off, ret_dest, ret_count, caller_proto_id: u32, call_pc: u32 }
```
`caller_proto_id = proto.id` (the caller proto's stable id) and `call_pc =` the `.call`'s source-opcode
PC (`guardSourcePc`-equivalent — `cur_pc − 1` at `recCall`, since `recordInstr` runs on the `.call`
before `recCall` and stamps the post-increment `cur_pc`). A guard's provenance path is then
`[(frames[i].caller_proto_id, frames[i].call_pc) for i in 0..inline_depth] ++ (source_proto_id,
source_pc)` — the leaf `source_proto_id` is the callee proto currently being recorded. `f(a)` vs `f(b)`
now differ in the last path entry's `call_pc`.

**Necessary, but NOT a complete guard identity (review correction).** The ordered call path resolves the
*static inline-context* dimension only. It does **not**, by itself, uniquely identify an emitted guard,
because the recorder can **unroll** — a back-edge at a *different* anchor deliberately keeps recording
(`skipBackEdge`, `trace.zig:3580`), so the *same* `call_pc` + *same* leaf `source_pc` + *same* path can
be emitted multiple times in one recording. Disambiguating those still needs G-1's `role` / `operand` /
`occurrence`. So the honest framing: full `GuardProvenance` = **call-path prefix (H-1a) + leaf
`(source_proto_id, source_pc)` + `role`/`operand`/`occurrence` (H-1c)**; H-1a delivers the first, it is
*necessary but not sufficient* alone. **The path must be an ordered sequence, not a set/multiset:** with
recursion reachable to depth 3, `A:x→B, B:z→A, A:y→B` and `A:y→B, B:z→A, A:x→B` share the same edge
*multiset* and leaf but are different call stacks — only order distinguishes them.

**Determinism / replay-safety (the load-bearing property):** the path is a pure function of the **guest
call structure** — which `.call` opcode in which proto — with **no** observed-type or guard-order
input, so it is stable across re-recording by construction (the G-1 obligation). `call_pc = cur_pc − 1`
is deterministically derivable at `recCall` time (verified: fetch increments `pc` before `recordInstr`
stamps the post-increment `cur_pc`, `interp.zig:1727` → `trace.zig:3968`). `proto.id` is the stable
`u32` id `guard_func` already stamps precisely *because* "pointers change across a keyframe restore and
would break replay" (`recCall` `trace.zig:5077`) — assigned deterministically in preorder at compile
(`compiler.zig:142/174`), disjoint ranges for runtime-loaded chunks (`load.zig:108`), and reconstructed
in load order across a restore (`keyframeser.zig:439/629`); protos are never cloned per tier. **Precondition
(review caveat):** this uniqueness is an invariant of the canonical *one-static-image + `load`* model,
**not** enforced by `Proto` itself — `Proto.id` defaults to `0` for hand-built protos (`bytecode.zig:264`)
and there is no id-exhaustion check, so an embedder combining two independently-compiled images outside
the `load` machinery could collide ids. `GuardProvenance` must state this precondition (or a later pass
enforce global proto-id uniqueness). The path length is bounded by `MAX_INLINE_DEPTH = 3`
(`trace.zig:5305`).

**Recursion reachability (review correction to a stale doc-10 claim).** `recCall` does **not** reject a
callee already on the inline stack — its only gates are vararg, `MAX_INLINE_DEPTH`, and reg-map capacity
(`trace.zig:5053-5071`); there is no "proto already inlined" check. So down-recursion via a
parameter-held callee *can* inline up to depth 3, contradicting doc 10's "down-recursion is Phase 3"
(`10-cross-frame-tracing.md:120`); ordinary lexical recursion usually aborts earlier only because the
inlined callee's own upvalue/global access is rejected (`recInputGet`, `trace.zig:5177`). This is why
the ordered-path (not multiset) property above is load-bearing, not academic — recursive shapes are
reachable within the depth bound today.

**Cost / breakage:** two `u32`s per `InlineFrame` → `+8 bytes × 3` on the recorder *once* (not
per-guard, not per-instruction — negligible, and off the hot per-op path). Purely additive: nothing
reads the new fields until `GuardProvenance` does, so landing them changes no behaviour and no
serialized byte.

**Land-now vs defer (Bart's call).** Unlike H-1b — whose `guardSourcePc` *replaced* eight existing
open-coded derivations and so paid off immediately — this extension has **no consumer until the
`GuardProvenance` IR change is built**, so landing it now adds two currently-unread fields. Two honest
options: **(a)** land the `InlineFrame` extension + an `inlineCallPath()` accessor + a test now (turnkey
plumbing, mirrors H-1b, but speculative fields), or **(b)** defer the field addition to the
`GuardProvenance` landing (which is the consumer and will want to co-design the exact tag layout) and
keep this as the pinned spec. Recommendation leans **(b)** — the fields are cheap but consumer-less, and
G-1 will restructure the guard record anyway — but it is a genuine judgment call, surfaced rather than
presumed (Rule #17). Either way the *grounding* result stands: the path shape above is what provenance
must key on, and the recorder has everything needed to build it at `recCall`.

**Review outcome — `gpt-5.6-sol`, 2026-07-18 = grounding CONFIRMED (directional), sharpened, no code.**
Claim 4 (cost/no-serialization) fully confirmed: `InlineFrame`/`Recorder`/`rec.frames` are recorder-only,
touched by no serializer (`traceser.zig:62` maps only committed `Trace` fields; keyframes serialize
physical VM frames `keyframeser.zig:691`), so `+8 bytes × 3` is behaviour- and wire-inert. Claims 1–3
were *directionally* right but overstated; all three corrections are folded in above (live-VM-stack
recoverability; necessary-not-sufficient ordered prefix; proto-id precondition + reachable recursion).
The net design conclusion is unchanged and stronger: **H-1a = persist `(caller_proto_id, call_pc)` per
`InlineFrame` at `recCall`, giving the ordered call-path prefix of `GuardProvenance`; land-now vs defer
is Bart's call.**

#### H-1c grounding (Bart, 2026-07-18) — the closed per-opcode guard-site vocabulary. No code.

Grounding pass on H-1c (round-8: "derived-value guards under-defined → need per-opcode `GuardSite`
vocab"). This is the last of `GuardProvenance`'s three axes: H-1b gave `source_pc`, H-1a the ordered
call-path prefix, and H-1c must give the `{role, operand, occurrence}` that distinguishes the *several
guards one guest opcode emits at the same PC*. Grounded against the recorder's actual emission code.

**The load-bearing finding: the IR op kind is NOT a stable guard identity — it is a runtime-varying
attribute of the same site.** Two emission paths prove it directly:
- `guardNum(ref, v)` emits `guard_int` **or** `guard_float` chosen by the *observed value*
  (`trace.zig:4187` — `if v.isInt() … guard_int else guard_float`). A loop body whose operand is an int
  on one recording and a float on the next emits a *different op* at the *same site*.
- `recBranch` emits `guard_true` **or** `guard_false` chosen by *which path tier-0 took*
  (`trace.zig:4834`). A branch that records true this trace and false the next flips the op at the same
  PC, same operand.

This is exactly why round-8's `exit_ordinal` was abandoned (G-1) and it restates the same instability one
level down: a provenance tag keyed on the op enum — or on a running rank over *emitted* guards — is not
re-recording-stable. `role` must be a **structural label**, invariant to observed types and taken paths.

**The vocabulary (closed set of `role`s, corrected against the tree after review).** Each guest opcode
that can emit guards has an ordered list of guard slots, each a `(role, operand)` pair. Grounded to the
`rec*` emitters (order = emission order); the review REFUTED my first-draft table on several rows — this
is the corrected version:

| guest opcode (`recFn`) | ordered `(role, operand)` guard slots | tree ref |
|---|---|---|
| `add/sub/mul/div/idiv/mod/pow` (`recArith`), `eq/ne` (`recEq`), `lt/le/gt/ge` (`recCompare`) | `(operand_type, b)`, `(operand_type, c)` | `4197-4198`, `4247-4248` |
| `neg` (`recNeg`), `bnot` (`recBnot`), binary bitwise `band/bor/bxor/shl/shr/sar` (`recBitwise`) | `(operand_type, b)` [+ `(operand_type, c)` for binary bitwise] | `4219`, `4236`, `4209-4210` |
| `jmp_if_false/jmp_if_true` (`recBranch`) | `(branch_cond, a)` | `4834` |
| `for_loop` (`recForLoop`), `for_prep` (`recForPrepLink`) | `(operand_type, a)`, `(operand_type, a+1)`, `(operand_type, a+2)`, then `(limit_int, a+1)` *(float-limit only)*, `(loop_done, ·)` | `4870-4872`, `4890`, `4901` (mirror `4977/4993/5003`) |
| `get_index` array read (`recArrayGet`) | `(container_type, b)`, `(container_lane, b)`, `(key_type, c)`, `(bounds, ·)`, then `(present, ·)` *(narrow lane)* **or** `(element_type, loaded)` *(.value lane)* | `4308`, `4315`, `4319`, `4328` |
| `set_index` array write (`recArraySet`) | `(container_type, a)`, `(container_lane, a)`, `(key_type, b)`, `(bounds, ·)` **or** `(append_precond, ·)`, `(value_fits, c)` *(every narrow lane)* | `4376`, `4462-4480`, `4424` |
| `get_index` const-key hash (`recHashGet`) | `(container_type, a)`, `(hash_struct, a)`, + consumer `(field_type, loaded)` on the `hload` result | `4727-4735` |
| `set_index` const-key hash (`recHashSet`) | `(value_type, c)` **first**, `(container_type, a)`, `(hash_struct, a)` | `4795`, `4797` |
| `get_index2` grid read (`recGridGet`) | `(grid_shape, b)`, `(grid_stride, b)`, `(row_type, c)`, `(col_type, aux)`, `(row_bounds, ·)`, `(col_bounds, ·)`, `(present, ·)` | `4508`, `4529-4542` |
| `set_index2` grid write (`recGridSet`) | `(grid_shape, a)`, `(grid_stride, a)`, `(row_type, b)`, `(col_type, c)`, `(row_bounds, ·)`, `(col_bounds, ·)`, `(value_fits, aux)` | `4557`, `4584-4595` |
| `call` (`recCall`) | `(callee_identity, a)` **or** `[(callee_pure, a)`, `(operand_type, a+1)]` *(pure-builtin)* | `5073`, `5122-5133` |
| `get_upval`/`get_global` (`recInputGet`) | `(callee_identity, dest)` *(only when the resolved input is a closure)* | `4090`, `5220-5222` |

Three properties this table makes concrete — the first two survive review, the third (subset framing) is
correct but needs a sharpening the review supplied:

1. **The op kind is derivable from `(role + observed type)`, not the reverse.** `(operand_type, b)` lowers
   to `guard_int` or `guard_float`; `(branch_cond, a)` to `guard_true` or `guard_false`. The op is a
   *view* of the site under a given recording; `(role, operand)` is the site. (CONFIRMED.)

2. **A recording emits a SUBSET of an opcode's static slot list, so `role` must be a structural label,
   never a dense rank over *emitted* guards.** The materialized subset is runtime-dependent —
   `guard_present` omitted on the `.value` lane (`4315`), `guard_append` replacing `guard_bounds` on the
   append path (`4424`), the `.value` element check appearing only for a table element (`4319-4328`).
   Were `role` "the Nth guard emitted", omitting `guard_present` would renumber every later guard — the
   exact instability G-1 rejected. A structural `role` keeps `(bounds) = (bounds)` regardless. *(Draft
   correction: `guard_fits` is NOT int-lane-only — the in-bounds path emits it for **every** narrow lane
   incl. boolean/f64, `4480`; only the append path restricts to boolean/int, `4404`.)*

3. **But `role` is NOT simply "read from the opcode" — the semantic *sub-path* is runtime-selected (review
   sharpening).** The same `get_index` records the **array** path or the **hash** path by observed key
   type (`4052/4056`); `set_index` likewise (`4063`); `call` records closure-identity or pure-builtin by
   observed callee (`5033`); `get_upval`/`get_global` emit `guard_func` only if the resolved input *is* a
   closure (`5220`); `for_loop` emits `int_of_float` only for an exact-integer float limit (`4890`). The
   `role` *vocabulary* is a finite closed set, but which roles a given recording realizes depends on the
   heap shape / observed types. This is not fatal to stability (see the determinism note below), but the
   honest statement is "closed vocabulary, runtime-selected realized subset," not "static function of the
   opcode alone."

**`operand` disambiguates a role that repeats across source operands — and it repeats more than I first
claimed.** Binary arith/compare/bitwise guard two operands with the same role (`(operand_type, b)` vs
`(operand_type, c)`, `recArith` `4197-4198`); but numeric-`for` guards *three* (`a`, `a+1`, `a+2`), grid
access guards two index types (row, col), and the pure call guards its argument. So `operand` must be a
register *designator* covering `a`/`b`/`c`, the derived offsets `a+1`/`a+2` (numeric-for control regs),
and register-valued `aux` (grid col/value) — not merely `instr.b`/`instr.c` as the draft implied. It is
still a static field of the bytecode, hence re-recording-stable. (The `recCompare` `gt`/`ge` swap happens
*after* the b-then-c guard emission (`4245-4253`), so `operand` tracks the **source** register, not the
normalized IR operand — CONFIRMED.)

**`occurrence` REFUTED — dropped, not grounded (the decisive review finding).** My draft defined
`occurrence` as "the Nth emission of `(path, source_pc, role, operand)` during recording," to disambiguate
**unrolling**. The review showed this reintroduces the *exact* dynamic-ordinal instability that killed
`exit_ordinal`: recording order is a function of runtime branch truthiness (`4834`), array-vs-hash routing
(observed key type), inner-loop *trip counts* (the recorder peels an inner loop — a non-anchor back-edge
returns without closing, `onBackEdge` `3588`, so the inner body records once per dynamic trip), and even
`for_prep` closing as a `.link` by trace-cache state (`4966`). So "the Nth emission" *slides* whenever an
earlier dynamic execution is skipped, deduped, or runs a different trip count — it is not a function of
bytecode + inline structure alone. **Resolution:** within *one* execution of *one* opcode, `(role,
operand)` is already unique (verified: no opcode emits two guards with identical role AND operand); the
only source of duplicate tuples is unrolling, whose copy-index is *inherently* dynamic and therefore has
no stable structural value. So `GuardProvenance` keys the **guest-static guard site** `(path, source_pc,
role, operand)` and deliberately does **not** distinguish unrolled physical copies — the physical
trace-exit → provenance map is **many-to-one**, which is correct for the consumer: every unrolled copy of
a guard is the *same* guest-level check, exits to the *same* guest PC, and wants the *same* side-trace
anchor / failure counter. The third axis named in G-1 ("occurrence") is thus **not needed and not
implementable stably** — the grounding result is to remove it, leaving `{source_pc, path, role,
operand}`.

**`guarded_refs` dedup — the many-to-one runs the other way too (review qualification).** `guard()`
dedups per **SSA ref** (`4176-4179`): a value already guarded emits nothing. So a static `(role, operand)`
slot can produce *no* guard when its ref was already guarded elsewhere — e.g. `x+x` (both operands one
ref), a `konst` reused across sites (`4131`), or the pure-callee identity deduped across the whole
recording (`5127`). (Note: this is *ref* sharing through the recorder's register map / moves / interning,
**not** guest-value equality; optimizer CSE runs later and cannot retroactively trigger recorder-time
dedup.) My draft's "each unrolled iteration carries a fresh ref, so dedup never collapses occurrences" is
**false as a blanket rule** — loop-invariant and aliased refs stay shared (only recomputed loop-carried
values like `rnext` `4874` get fresh refs). This is a second reason `occurrence` is unsound and a reason
the consumer must treat "static slot → guard" as *may-be-absent*, not one-to-one.

**Determinism / replay-safety (narrowed and made precise).** The property G-1 actually requires is
**non-shifting under sibling elision** — the failure mode that sank `exit_ordinal`. `source_pc` (H-1b),
the call `path` (H-1a), `role` (structural label), and `operand` (static register designator) all have it:
eliding or adding a *sibling* guard does not renumber them, because none is a position. What is *not*
value-independent is the **set** of roles a recording realizes (property 3) — but a differently-shaped
re-recording (array vs hash, closure vs pure) legitimately contains *different guards*, so assigning them
different provenance is correct, not unstable. The one axis that had the shifting property was
`occurrence`, now dropped. Net: `{source_pc, path, role, operand}` is stable across re-recording of the
same-shaped trace and correctly *differentiates* differently-shaped ones; no observed-type, taken-path,
trip-count, cache-state, or pointer input leaks into the *identity of a materialized guard* (only into
which guards materialize).

**Follow-on obligation surfaced by review — fused native exits are not all `guard_*` nodes.** Some
concrete native side-exits attach to a *producer/address* IR node, not a `guard_*`: native `hload`
type-exits at the `hload` index (`nativegen.zig:4022`) before the following `guardNum`; `.value`-lane
`aload` exits on a non-heap tag at the `aload` (`nativegen.zig:4120`); `href` can exit on cell-resolution
failure (`nativegen.zig:3517`). A provenance scheme that tags only guard-emission sites leaves those exit
slots untagged. So the round-9 landing must (a) assign a `role` to these fused producer exits too (e.g.
`(field_type, loaded)` belongs on the `hload`, not a phantom later guard), and (b) extend the
source-PC stamp beyond the six PC-carrying ops `guardSourcePc` covers today (`trace.zig:442`) — the H-1b
section already flagged this stamp-for-every-exit obligation; H-1c inherits it for the fused set.

**Scope / landing.** This is a genuine **IR-metadata + emission** change (a closed `GuardRole` enum + an
operand register designator stamped at every `rec*` guard-emit *and* fused-producer-exit site),
inseparable from the `GuardProvenance` IR extension itself (G-1's "new IR metadata obligation"). It lands
*with* provenance in round 9, not standalone — there is no non-speculative subset to land early (contrast
H-1a's `InlineFrame` fields). The grounding deliverable is the corrected table + the "drop occurrence,
key the static site, many-to-one physical map" result + the fused-exit obligation.

**Review outcome — `gpt-5.6-sol`, 2026-07-18 = NEEDS-CHANGE, all folded in above; no code.** The central
op-kind argument was CONFIRMED, but the review REFUTED the draft on five concrete points, every one
tree-verified before folding: (1) the vocabulary table had wrong operands/order on `set_index` (container
is `a` not `b`), `for_loop`/`for_prep` (missing the three operand-type guards), hash-set (value guard is
*first*), grid (missing row/col type guards), and pure-call (missing the arg guard), plus a missing
`get_upval`/`get_global` row — corrected. (2) `guard_fits` is every-narrow-lane, not int-only. (3) `role`
is a closed vocabulary with a *runtime-selected* realized subset, not a static function of the opcode
alone. (4) **`occurrence` is unsound** (dynamic recording-order ordinal) — dropped; provenance keys the
guest-static site with a many-to-one physical map. (5) fused `hload`/`aload`/`href` native exits need
`role`s + source-PC stamps too. The net identity is **`{source_pc (H-1b), call-path (H-1a), role,
operand}`** — three axes, not the four G-1 named; `occurrence` is retired as un-groundable.

#### H-3 grounding (Bart, 2026-07-18) — the region-map cap bound + `beginTopLevelEpoch` clean-entry. No code.

Grounding pass on H-3 (round-8: "mandatory deletion bounds the map but doesn't prove the cap can't evict a
live entry, and `beginTopLevelEpoch` doesn't enforce clean entry"). **First, the scope fact that reframes
both halves: the `region_profit` accounting map does NOT exist in the tree yet** — it is round-3/4/5 Part-A
design that has not landed (`grep region_profit src/` → nothing). So H-3 is grounding a *contract the
round-9 map must satisfy*, plus the *existing* `beginTopLevelEpoch`, not auditing a live structure.

**(i) The live-region set is bounded — because call depth is hard-bounded — so a fail-closed or
lifetime-scoped map is provably safe; an evict-live cap is not.**
- **`max_call_depth = 200` is a hard static bound** (`interp.zig:119`), enforced by a fixed-size frame
  array `frames: [max_call_depth]CallFrame` (`:531`) and the single `pushFrame` guard `depth >=
  max_call_depth → StackOverflow` (`:1347`, mirrored `:1430`). The Lua call stack cannot exceed 200
  activations, ever.
- A region is keyed (round-5 design) by identity `(proto, anchor_pc)` scoped to an **activation**
  (`call_seq`). A proto has finitely many static bytecode anchors — but **`regions_per_frame ≤ static
  anchor count` does NOT follow** (review correction): the design gives regions distinct `RegionId`s and
  can admit *sibling* regions sharing one anchor, and today's "≤ 2 traces per anchor" cap
  (`trace.zig:3035/3142`) does **not** bound future *logical* regions one-for-one (regions can encode
  graph cycles/combinations, and traces retire and re-record). So the per-activation bound is real only
  once round 9 **states an explicit live-region cardinality invariant** — e.g. "at most one live
  accumulator per `(activation, anchor)`" — rather than assuming the anchor count supplies it.
- With such an invariant, the live-region set is bounded at every instant (`≤ 200 activations × the
  per-`(activation,anchor)` bound), and G-3's **mandatory** activation-scoped cleanup keeps the map's live
  population from exceeding the live set — it cannot grow with history.
- **Grounding conclusion.** `max_call_depth` is the hard 200; the missing piece is the per-activation
  region-cardinality invariant (NOT "the static anchor count" — that was overstated). Note too that there
  is **no** global static `max_anchors_per_proto` for a universal fixed cap (protos are dynamically
  loaded with varying `code.len`), which pushes toward the lifetime-scoped option. Round 9 must pick ONE
  of: **(a)** a fixed cap that **fails closed** (refuse to arm a new region when full — never *silently*
  evict), **or** **(c)** an *uncapped* map bounded purely by the live set via strict activation-lifetime
  deletion (G-3). Both are sound. What is banned is the finding's hazard: a cap that **silently** evicts a
  still-live entry — un-accounting an armed region corrupts the gate decision (P-EBP-2). (Narrowing: a
  *non-silent* eviction that atomically disarms the region and reverts it to fail-closed tier-0 could be
  made safe; only silent evict-live is categorically wrong.) Fail-closed degrades gracefully (an
  untrackable region simply isn't armed, staying tier-0).

**(ii) `beginTopLevelEpoch` does not enforce clean entry, and the hazard is REACHABLE — broader than the
finding stated (review correction).**
- Today `beginTopLevelEpoch` does **only** `disarmAllLinks()` (`interp.zig:1012`) — no region-map clear
  (there is no map), no `depth` check. `run`/`start` call it *before* `pushFrame` (`:1025/:1046`).
- **Correction to my draft:** `depth` is *not* moved only by `±1`. Dispatch pushes/pops by one
  (`:2364/:2395`), but `pcall`/`xpcall` **directly restore** `vm.depth = entry_depth` on unwind
  (`stdlib/errors.zig:101/109/117`) and keyframe restore assigns it verbatim (`keyframeser.zig:710`). The
  claim that *survives* is the narrow one: there is **no unconditional top-level reset to zero** in
  `run`/`start`/`beginTopLevelEpoch`.
- **The hazard needs no "non-catchable" framing** — my draft mis-stated that. The real invariant is
  explicit in the source: *"a runtime error must leave `self.frames` live (depth raised) so the catching
  `pcall` can synthesize the located message before it restores the boundary"* (`interp.zig:1454`); an
  error escaping `execWith` clears only the pending trace anchor, never pops frames (`:1633`). So **any
  UNCAUGHT error escaping `run`** (catchable or not) leaves `depth > 0`. (`StackOverflow` is in fact
  **catchable** — `interp.zig:3776`, a deterministic function of call depth — contra my draft; only
  `OutOfMemory` + the effect-log faults are non-catchable. But catchability is beside the point: an
  *uncaught* error of any kind strands the frames.)
- **A second, fault-free dirty-entry case the finding missed:** calling `run`/`start` on a **suspended**
  VM (one parked mid-execution via `suspend_ctl`, awaiting `exec()`) also enters dirty — `depth > 0`, no
  fault required. The API documents "resume via `exec()`" but does not enforce it.
- **The corruption is worse than "push above stale frames."** Top-level `exec` runs with `stop_depth == 1`
  (`:1631`), so after the fresh `pushFrame` lands at e.g. depth 6, a return that unwinds to depth > 1 can
  **resume a stale parent frame** instead of finishing the new run. And an *unconditional* `region_profit`
  clear at epoch start (G-3's phrasing) would **delete accounting for still-live activations** and arm
  above them.
- **Ordering constraint (review):** the clean-entry check must run **before** `disarmAllLinks` / any
  future map clear — otherwise *rejecting* a `run` on a legitimately suspended VM would already have
  mutated its still-resumable epoch.
- **Grounding conclusion.** Round 9 must choose a *real* clean-entry contract, not "clear the map":
  **(a)** reject `run`/`start` unless `depth == 0` (check *first*, before any epoch mutation), **(b)** a
  real VM reset that unwinds+pops to depth 0, or **(c)** a poisoned-VM state latched on the stranding
  fault that refuses reuse. Recommendation (surfaced, not presumed — Rule #17): **(a)** — a well-behaved
  embedder already discards a faulted VM and resumes a suspended one via `exec()`, so a `depth == 0`
  entry precondition (evaluated ahead of `disarmAllLinks`) converts a silent corruption into a loud, cheap
  check and is the minimal contract that makes the unconditional-clear safe. Lineage: `beginTopLevelEpoch`
  was *added* in Increment 2c-F for this same epoch-containment reason (disarm stale links across a fresh
  run); H-3(ii) extends its remit from links to region accounting + frame cleanliness.

No code. The deliverable is: the live set is bounded (hard 200 activations × a per-`(activation,anchor)`
region-cardinality invariant round 9 must state), so fail-closed or lifetime-scoped is safe and *silent*
evict-live is banned; and the clean-entry gap is real and broader than framed (any uncaught error *or* a
suspended VM strands frames — no reset exists), needing a `depth == 0` precondition checked *before* the
epoch mutation, not a blind map clear.

#### H-4 grounding (Bart, 2026-07-18) — the only implementable F2c logical cut. No code.

Grounding pass on H-4 (round-8: "'Kth committed outer iteration' is not an implementable cut; only
'immediately after the Nth committed effect opcode boundary' is"). Grounded against the suspend/effect
machinery.

**The cut mechanism today is tier-0-only and safepoint-counted.** `suspend_ctl: ?SuspendCtl` where
`SuspendCtl = { min_depth, after_safepoints }` (`interp.zig:418`) is checked at exactly **one** place:
the tier-0 instruction boundary in `step`, `if safepoint_seq >= after_safepoints and depth >= min_depth`
(`interp.zig:1716-1725`), and `safepoint_seq` advances **once per tier-0 instruction** (`:1704`). A
native trace neither returns to this dispatcher per instruction nor advances `safepoint_seq` per
iteration — it runs a whole **burst** of outer iterations in one native call and returns only at a
side-exit / loop-done / prologue-fail / forced-yield. **So `suspend_ctl` cannot fire *mid*-native-trace,
and a safepoint-count cut is tier-dependent by construction** (native and tier-0 reach the same guest
state at *different* `safepoint_seq` values). This is precisely G-4. (`suspend_ctl != null` does **not**
stop a native root from *running* — it only forces `.full` dispatcher mode and makes `safe_to_arm` false
so links don't fuse, `interp.zig:2627`; the root still runs a whole burst before returning.)

**Why "after the Nth committed effect" IS precise and tier-independent — host effects are trace barriers
(true for today's built-ins, but NOT yet a structural contract).** `recCall` aborts recording
`.host_barrier` on any non-inlinable native (`trace.zig:5046`); the *only* inlined natives are
`PureBuiltin`s (today just `sqrt`, `function.zig:170` / `math.zig:260`, registered with no effect). So
**no effect is ever committed on-trace** — every `logEffect` (`interp.zig:3868/3889/3930/…`) runs inside a
tier-0-owned host-native call, at an instruction boundary where `safepoint_seq` advances and `suspend_ctl`
*can* fire. An effect in the guest forces the native trace to side-exit *before* the effect opcode, tier-0
resumes and commits it. **But this chain is a property of the current built-ins, not an enforced invariant
(review):** `Native.pure` and `Native.effect` are **independent** optional fields (`function.zig:229/238`),
copied without an exclusivity assertion (`interp.zig:910`), and `recCall` checks `pure` first without
rejecting `effect != null` — so a native mis-tagged both `.pure = .sqrt` *and* `.effect != null` would
inline as `fsqrt` and **skip its effect on-trace**. Round 9 must **enforce `pure != null ⇒ effect ==
null`** (ideally binding each pure tag to its function) to make the barrier structural. With that, "the
tier-0 boundary immediately following the Nth committed effect" is the one implementable, tier-independent
cut.

**Why "iteration K" is NOT implementable without new machinery.** For an *effect-free* hot loop, native
runs many outer iterations per call with no per-iteration return to the dispatcher, so a cut cannot land
at exactly iteration K — native overshoots to the burst's end. Making iteration-count cuts precise needs
an added **native logical-budget/yield** that returns at exactly K with all registers + heap coherent —
extra codegen the roadmap does not otherwise require. So round 9 takes the effect-boundary cut, and any
mid-burst-iteration cut is explicitly out of the implementable set until that yield exists. (The effect
boundary is not the *only* conceivable tier-independent event — loop/program completion and other trace
barriers qualify too — but it is the viable choice among the two the finding proposed.)

**The immediate post-effect boundary is not always suspendable (review correction) — so cut at the FIRST
snapshot-eligible boundary after effect N.** Two grounded cases break "snapshot right after the effect":
(1) an effect used as a **multret producer** (`print(clock())`) routes through `stampSingleResult`, which
sets `reg_top_pending = true` (`interp.zig:3685`), and the suspend check **refuses to fire while that flag
is set** (`:1719`) — the earliest eligible cut is after the *consumer*, not in the producer→consumer gap.
(2) A faulting effect opcode has no successful "next instruction" boundary in its frame at all. So the
harness must select a **successful, fixed-result** effect (e.g. `local t = os.clock()`) and define the cut
as "the first snapshot-eligible tier-0 boundary at or after `effect_cursor == N`," not "the immediate
next instruction." Also: `SuspendCtl` has **no effect-count field** today (`min_depth`/`after_safepoints`
only) — the harness must either step one eligible boundary at a time until `effect_cursor == N` or round 9
adds a logical-effect trigger; a precomputed `after_safepoints` threshold stays tier-dependent and must
not be used.

**The cut assertion is full *semantic keyframe* equality, not `effect_cursor` alone (review sharpening).**
My draft's "regs + heap + `effect_cursor` + `depth`" understates it. The effect cursor is a coarse clock
(a loop with few effects but many heap mutations advances it slowly while committing lots of non-logged
state), so an effect-cursor-only assert would pass even if a codegen bug left the heap or a phi-writeback
diverged. The robust comparison is a **byte-identical semantic keyframe** — the full live stack + every
frame's `{closure, pc, base, return-wiring, varargs}`, heap/globals + the object-id counter, and open
upvalues (what `keyframeser.zig:279` already serializes) — **plus** the replay-driver state the keyframe
deliberately *omits*: the `effect_log` prefix + `effect_cursor` (supplied separately, `keyframeser.zig:2090`),
the output prefix, and any PRNG/native semantic state. And the cut must be taken **after** the effect's
result is installed — the writeback happens after `performEffect` returns (`:2272`), and `suspend_ctl` is
checked at the *top* of `step` for the *next* instruction (`:1716`), so reusing that boundary is correct;
round 9 must **not** introduce a snapshot call inside `logEffect`/`performEffect`.

**Status relative to F-5.** Today **no snapshot is ever cut inside a native trace** — the F2c harness
cuts at tier-0 boundaries (`suspend_ctl` above; the F-5 obligation). H-4's grounding says the round-9
native-F2c test must (a) cut at the tier-0 boundary immediately after a post-native-burst effect, and (b)
assert full-state identity, not the effect cursor. This dovetails with H-5(i)'s finding (dead numeric-for
temporaries omitted from the exit snapshot, `trace.zig:3761`) — that same test is what must catch a stale
temporary at the cut.

No code. The deliverable: the effect boundary is the unique tier-independent cut (because effects are
trace barriers → always tier-0-reached → `suspend_ctl`-fireable with the result already installed);
"iteration K" needs a native yield lune doesn't have; and the cut assertion must be full VM state, since
effect-prefix equality is necessary but not sufficient.

**Review outcome — H-3 + H-4, `gpt-5.6-sol`, 2026-07-18 = NEEDS-CHANGE (both), all folded in above; no
code.** Every correction was tree-verified before folding. **H-3:** the region-non-existence, the hard
200 bound, and "`beginTopLevelEpoch` only disarms" all CONFIRMED; the draft was REFUTED/narrowed on (1)
`depth` is *not* moved only by ±1 — `pcall`/`xpcall` and keyframe-restore assign it directly
(`errors.zig:101/109/117`, `keyframeser.zig:710`); (2) `StackOverflow` is **catchable**, and the hazard
needs no "non-catchable" framing — *any* uncaught error leaves frames live (explicit invariant
`interp.zig:1454`), plus a **suspended VM** is a second fault-free dirty-entry case; (3) the corruption is
worse (top-level `stop_depth==1` can resume a stale frame); (4) the clean-entry check must precede
`disarmAllLinks`; (5) `regions_per_frame ≤ anchor-count` was OVERSTATED — round 9 needs an explicit
per-`(activation,anchor)` cardinality invariant, and *silent* evict-live (not all eviction) is what's
banned. **H-4:** the effect-barrier chain holds for today's built-ins but is NOT structural —
`pure`/`effect` are independent fields, so round 9 must enforce `pure ⇒ !effect`; the immediate
post-effect boundary is NOT always suspendable (`reg_top_pending` multret gate `interp.zig:1719/3685`;
faulting effects), so the cut is "first snapshot-eligible boundary after effect N" on a successful effect;
and the assertion is a full **semantic keyframe** + replay-driver (effect log + cursor, omitted from the
keyframe) + output prefix, not `effect_cursor` alone. Net: both groundings stand, materially sharpened —
H-3 = "bounded live set ⇒ fail-closed or lifetime-scoped, ban silent evict-live; `depth==0` precondition
before epoch mutation"; H-4 = "effect boundary is the one implementable tier-independent cut (enforce the
barrier), cut at first eligible boundary, assert full semantic state."

#### Round-9 landing plan (Bart, 2026-07-18) — sequencing the grounded blockers into code

Every H-blocker except **H-2** (the escalated weak-intern/id-timeline one) is now grounded. This
subsection pins the *implementation* plan — representation, sequencing, and scope boundaries — for turning
those groundings into code. gpt-5.6-sol review pending; **no code until reviewed**.

**Scope split — what lands in round 9 vs with Increment-3 machinery.** The grounded blockers divide by
whether their *consumer machinery* exists in the tree yet:

- **9-A (small, safe, immediate)** — two invariant/precondition enforcements that stand entirely alone.
- **9-B (foundational plumbing)** — the `GuardProvenance` IR extension: self-contained, but with **no
  consumer** until `StructuralEdgeId`/region accounting is built. Lands the way H-1b did — behaviour-neutral
  plumbing ahead of its reader — just larger.
- **Deferred to Increment-3 machinery (NOT round 9)** — the F2c native-cut *harness* (H-4's cut) and the
  region-map *cap contract* (H-3's cap) both need `region_profit` / native-F2c, which do not exist. They
  land **with** that machinery; round 9 lands only their standalone preconditions (below).

**9-A(i) — `pure ⇒ !effect` (H-4 barrier made structural).** `function.zig` carries `pure: ?PureBuiltin`
and `effect: ?EffectKind` as **independent** nullable fields (Function `229/236`, NativeFn `278/284`), and
`recCall` inlines on `pure` first — so a builtin that ever set *both* could inline an effect past the
`.host_barrier` (`trace.zig:5046`), silently committing a host effect on-trace and breaking H-4's
"no effect ever commits on-trace" cut. **`interp.zig:916` is NOT a single choke point (review, tree-verified):**
`defineNative` early-returns for `.manual` descriptors *before* the field copies (`interp.zig:914`), package
natives are constructed separately (`stdlib/package.zig:434`), keyframe restore copies both fields
independently (`keyframeser.zig:606`), and synthetic natives set `.pure` directly (`trace.zig:6501/6534`).
So the structural enforcement is a **comptime check over every static `base_natives`/module descriptor**
(covers `.manual` entries, which carry the fields even without an install slot) **plus a runtime assert on
the restore path** (`restore` accepts a caller-supplied `NativeRegistry`). Behaviour-neutral today (no
builtin sets both); it *pins* the invariant H-4 leans on. Prefer a constructor that initializes all
classification fields together so the two-independent-nullable-fields shape can't drift.

**9-A(ii) — `depth == 0` clean-entry precondition (H-3).** `beginTopLevelEpoch` (`interp.zig:1011`, every
`run`/`start`) today only `disarmAllLinks()`. The grounded hazard: a **suspended** VM (fault-free) or a
**faulted-but-live** VM has `depth != 0` with live frames (`interp.zig:1454` invariant), and mutating
epoch state on such a VM corrupts its resumable epoch. Round 9 adds a `depth == 0` check **before** the
disarm (and before the future region-clear). **Sub-fork resolved by the tree (review):** the earlier
draft's option (b) "skip the reset, treat leftover depth as a continuation" is **unsound** — `run`/`start`
never continue; both allocate and `pushFrame` a *fresh* top-level frame (`interp.zig:1025-1035/1046-1052`),
and suspension resume goes through `exec()` (top-level `stop_depth == 1`), not `start()`. So a `depth != 0`
entry to `run`/`start` is unambiguously caller misuse ⇒ **fail-closed is the only sound option**. It must
be **release-enforced** (a returned error or unconditional panic before any epoch mutation) — a bare
`std.debug.assert` vanishes under ReleaseFast and would let a dirty entry corrupt silently. A genuine fresh
entry always has `depth == 0` (init 0 `interp.zig:506`; successful top-level return decrements to 0
`:2356-2365`; suspend/error deliberately leave frames live), so the check rejects only misuse.

**9-B — the `GuardProvenance` IR extension.**

- **Representation: a transient side table, NOT a field on `IrInstr`.** *(Justification corrected by the
  review.)* Adding an in-memory field to `trace.IrInstr` does **not by itself** force a schema bump —
  `traceser.toSchemaTrace` maps exactly six fields explicitly (`.op/.a/.b/.aux/.ty/.snap`, `traceser.zig:66`;
  the wire type in `schema/trace.json:37`), so an unmapped transient field rides along the way `Trace.inputs`
  / `entry_guards` / native state already do (runtime-only, `trace.zig:657-672`). The side table is chosen
  for **two other reasons**: `IrInstr` has a pinned 16-byte size budget (`trace.zig:5849`) that a fat
  provenance field blows, and guards are a **minority** of ops so per-instr storage is wasteful. And
  provenance is transient JIT-tiering state the round-8 reshaping insight already excludes from
  serialization (native ≡ tier-0; keyframe stays v4) — so it is rebuilt on re-record, never on the wire.
- **‡ Representation blocker (review, THE damaging one — tree-verified): an emission-time instr-index key
  is STALE at commit.** `tropt.optimize` rewrites a freshly-recorded body into a smaller renumbered one:
  it CSE/const-folds and **drops duplicate + always-pass guards** (`tropt.zig:299-312`), DCEs, runs LICM,
  builds a **new emission order** with the preheader region first + a synthesized `.preheader` marker
  inserted (`tropt.zig:507-533`), and assigns every survivor a fresh `new_index[i]` (`:535`). A side table
  keyed by the *emission-order* instr index and copied unchanged into the committed `Trace` therefore points
  at the wrong (or removed) instructions. **So provenance MUST participate in the transform:** `tropt.optimize`
  remaps old→new via the same `new_index` (dropping entries for dead/deduped guards, leaving the synthesized
  `.preheader` untagged), and `tropt.dupe` (`tropt.zig:204`) copies it unchanged. Guard **dedup**
  (`:305-311`, exact-duplicate `GuardKey` → earlier copy dominates) needs a defined rule: the survivor keeps
  its own provenance (the dropped duplicate's guest site is the same anchor/counter — the H-1c many-to-one
  note). Concretely the committed table is a `[]GuardProvenance` (or `AutoHashMapUnmanaged(u32→…)`) keyed by
  the **committed** instr index, produced by the optimizer, never the raw emission index.

- **The tag — 4 fields (still 3 *identity axes*; `occurrence` retired per H-1c):**
  `GuardProvenance = { path: [MAX_INLINE_DEPTH]CallEdge (len = inline_depth), source_proto_id: u32,
  source_pc: u32, role: Role, operand: OperandDesig }`. *(Review correction: the earlier draft dropped
  `source_proto_id`, which collides guards across different leaf protos with the same `source_pc`; and it
  tried to fit the leaf into the path array.)*
  - **`path` (H-1a).** The ordered inline call-**edge** prefix `[(caller_proto_id, call_pc) for i in
    0..inline_depth]`; the **leaf** `(source_proto_id, source_pc)` is the two separate tag fields above, NOT
    a path entry. Requires extending `InlineFrame = {base_off, ret_dest, ret_count}` (`trace.zig:5324`) with
    `{caller_proto_id: u32, call_pc: u32}`, set in `recCall` (`:5095`) from `proto.id` + the call's source PC
    (both live there, currently discarded — the H-1a collision: `f(a); f(b)` inlined share `base_off`).
    Ordered (multiset unsafe — recursion to `MAX_INLINE_DEPTH = 3` is reachable). Because it holds **edges
    only** (leaf split out), the max edge count is exactly `MAX_INLINE_DEPTH = 3` ⇒ an inline `[3]` fixed
    array, **no allocation** (the earlier "`[3]` for edges+leaf" was one short — leaf is separate).
  - **`source_pc`.** For the six PC-carrying guards, `= guardSourcePc(ins)` (H-1b, landed). For the **13
    non-PC guards** (`guard_table/lane/bounds/present/fits/append/func/hash/pure/grid/stride/gcol/gpresent`,
    whose `aux` is fully consumed by lane/size/proto-id/enum) **and the 3 fused native producer-exits**
    (`hload/aload/href` side-exit at the producer, no `guard_*` op), `source_pc` is *unavailable from the
    instruction* → **stamp it explicitly at emission**. **The value is `cur_pc − 1`, NOT `cur_pc`** (review):
    `Recorder.cur_pc` is the *post-increment* resume PC (`trace.zig:5394`), so the source-opcode PC is one
    back — stamp through a dedicated `currentSourcePc()` helper (the `guardSourcePc`-for-non-PC-guards
    analogue), never a bare `cur_pc`. This is the core new-storage need and why a side table (not `aux`-reuse)
    is mandatory.
  - **`role`.** The structural label from the H-1c closed vocabulary (type-check / branch-true /
    branch-false / bounds / lane-present / lane-fits / append-ok / loop-done / func-identity / hash-stable /
    grid-shape / grid-col / grid-present / …). Derivable from `(bytecode op at source_pc, operand)`, but
    **stamped explicitly at emission** for robustness and cost — the emitter already knows its own role, so
    re-deriving at edge-construction time is needless work and a second place to get the vocab wrong.
  - **`operand`.** A **register** designator over `a / b / c / a+1 / a+2` (numeric-for) / the grid
    register-valued `aux` — a **static bytecode field**, hence stable across re-recording (the `recCompare`
    gt/ge swap happens *after* guard emission, so operand tracks the source register — confirmed H-1c). **The
    array/grid *lane ordinal* is NOT an operand designator** (review): the lane is *observed runtime
    representation*, not a static bytecode operand — putting it in the tag would inject an observed-type input
    and break the "deterministic function of `(guest bytecode, inlining structure)` alone" obligation.
    `guard_lane`'s operand is its table register, not its lane.

- **Stamping — structural, not a site checklist (review: my first list was incomplete).** Enumerating
  emitters is fragile — the draft omitted **`recArrayGet`** (`trace.zig:4277`, emits table/lane/bounds/
  present + value guards), **`recHashGet`** (`:4698`, table/hash/field-type), and **`recForPrepLink`**
  (`:4939`, three numeric guards + optional `int_of_float` + `guard_true`), alongside the ones it did name
  (`guardNum`, `recBranch`, `recForLoop`, `recArith`, `recArraySet`, `recHashSet`, `recGridGet/Set`,
  `recCall`→`guard_func`/`guard_pure`, `recInputGet`). The robust shape is to **stamp in the low-level guard
  `emit` helper** so completeness is structural (every guard funnels through it), with each `rec*` call site
  **supplying its `(role, operand)`** — because `guardNum` sees only a ref + observed value, not the guest
  operand designator or structural role, those must come from the caller. The helper reads `currentSourcePc()`
  (= `cur_pc − 1`) and the open-`InlineFrame` path itself. The **three fused native producer-exits**
  (`hload`/`aload`/`href`, `nativegen 3517/4026/4118`) side-exit with no `guard_*` node, so they need their
  own explicit `(role=lane-load-miss/… , source_pc)` stamp — extending H-1b's "stamp every exit" past the
  six PC-carrying ops (the H-1c follow-on).

- **Determinism obligation + the honest weak spot.** There is **no consumer** — `StructuralEdgeId`/region
  accounting is unbuilt — so nothing *reads* the tags in round 9. Safety net (expanded per review): **(1)**
  the 10-mode matrix stays green (provenance is read by nothing ⇒ changes no output); **(2)** a
  **re-record-stability test** — record, invalidate, re-record, assert byte-identical tags — that must
  **validate each *committed* provenance entry against the *committed* instr at that index AFTER `tropt`**
  (not compare two identically-stale emission-time tables, which would agree while both are corrupt),
  pinning G-1's "deterministic function of `(guest bytecode, inlining structure)` alone" obligation; **(3)**
  a **collision test** — `f(a); f(b)` inlined emit distinct `call_pc`; **(4)** an **optimizer-remap test** —
  same program with optimization ON and OFF, asserting provenance tracks `new_index` and survives guard
  dedup / LICM preheader insertion; **(5)** a **max-inline-depth test** — three call edges + leaf fit the
  `[MAX_INLINE_DEPTH]` array; **(6)** assert **`source_pc == cur_pc − 1`** for non-PC guards and all fused
  exits, and that **no observed lane/type** appears in any `operand`. Plus allocator ownership/cleanup for
  both the recorder and committed side tables (incl. the optimize-OOM path — the committed table frees on
  the same errdefer as `instrs`). *Weakness, stated plainly:* plumbing ahead of its reader can be subtly
  wrong in ways the matrix cannot catch; tests (2)–(6) are the mitigation, and the consumer (region
  accounting) co-designs final consumption. Same posture as H-1b, larger surface.

**Sequencing.** 9-A first (tiny, de-risks the arc, immediately useful), then 9-B (the large plumbing).
Each lands behind `just test` + the 10-mode matrix; 9-B adds tests (2)–(6). The deferred pieces (F2c cut
harness, region cap) land with Increment-3 machinery, not here.

**Outcome (Bart, 2026-07-18): 9-A LANDED, 9-B DEFERRED.** 9-A (`pure ⇒ !effect` comptime check over
`base_natives` + `keyframeser` restore assert; `Error.DirtyTopLevelEntry` fail-closed in
`beginTopLevelEpoch` with a load-bearing suspended-VM test) landed behind `just test` (default +
`-Djit-debug`), nsieve tier-0 ≡ native. **9-B is deferred to co-design with its consumer** — the review
revealed it must touch the optimizer (`tropt` remap) and it has no reader yet, so building it now risks the
wrong tag shape; it lands when region accounting / Increment 3 needs it (H-1a's grounding recommendation,
now the decision of record).

**Review outcome — round-9 landing plan, codex `gpt-5.6-sol`, 2026-07-18: BLOCKER → resolved (design
only).** The plan was not implementation-ready; the review returned six concrete defects, **all
tree-verified before folding** (none taken on faith). Ranked: **(1) ‡ the damaging one** — an emission-time
instr-index key is stale at commit because `tropt.optimize` renumbers/drops/reorders (`tropt.zig:299-312/
507-537`); provenance must be remapped by the optimizer via `new_index` and copied by `dupe` (folded into
Representation). **(2)** the tag dropped the leaf `source_proto_id` (cross-leaf-proto collision) and mis-sized
the path array — leaf split out, `[MAX_INLINE_DEPTH]` holds *edges only* (folded into the tag). **(3)** the
"adding an `IrInstr` field forces a schema bump" justification was wrong — `traceser.toSchemaTrace` maps six
fields explicitly (`traceser.zig:66`); the side table is chosen for the 16-byte budget + minority-of-ops
instead (corrected). **(4)** `pure ⇒ !effect` at `interp.zig:916` alone is insufficient — `.manual` early-
return + restore + package + synthetic sites bypass it ⇒ comptime-over-tables + restore assert (folded into
9-A-i). **(5)** the `depth != 0` sub-fork's "skip-reset" option is unsound — `run`/`start` push a fresh
frame ⇒ fail-closed, release-enforced only (folded into 9-A-ii). **(6)** stamping-site list was incomplete
(`recArrayGet`/`recHashGet`/`recForPrepLink` omitted) and `source_pc` is `cur_pc − 1` not `cur_pc`, and the
lane ordinal must not be an `operand` (observed input) ⇒ stamp structurally in the `emit` helper with per-
site `(role, operand)` (folded into Stamping). Net: the side-table concept is viable, but only with
optimizer-integrated remapping; the plan now says so. No code landed — this is still design.

#### Part A — CONSOLIDATED buildable design (2026-07-19): the single contract to build

Status: **design — APPROVED (round-10 `gpt-5.6-sol` pre-impl review = APPROVE, 2026-07-19; rounds 1–9
were BLOCKER, all folded, see §A9 review log). "The consolidated Part-A contract is now
implementation-ready." Ready to build behind `just test` per the §A8 landing sequence.** This section
assembles
the final resolved contract from rounds 3–8 + the H-series groundings + the 2026-07-18
landings into **one buildable spec**. For implementation it **supersedes** the scattered
round-N Part-A subsections above; those stay as the historical derivation (why each choice
was made). Every claim here is the *resolved* form after all retractions; where a round
introduced then reversed a claim, only the survivor appears. Two things changed *since*
round 8 and are folded in:

- **H-2 is CLOSED (2026-07-18) — Part A is no longer gated by it.** The round-8 review's
  foundational blocker (JIT-trace-materialized object *identity* leaking into serialized
  snapshot bytes) shipped a complete three-part fix + the `next_obj_id` keyframe bump:
  (1) dynamic-proto tracing gate (`b2d9d18` — no trace ever anchors in / inlines a `load`ed
  proto, so a dropped-`load`-closure can't leave a trace as the sole root of an interned
  const); (2) `{gc,snapshot}` root-walk split (`3f1df3f` — trace/recording consts are
  `.gc`-liveness roots only, **excluded** from the `.snapshot` walk); (3) `clearCache()` from
  `beginTopLevelEpoch` (`9a8c141` — frees all traces at each top-level epoch); plus keyframe
  **v4→v5** serializing `next_obj_id` verbatim (`NextObjIdBelowObjects` validation). Net:
  **snapshot bytes are a pure function of semantic state, JIT-tiering-independent by
  construction, as already-shipped.** Part A *inherits* this and must not break it (§A7).
- **9-A landed both Part-A preconditions (`9fcc2c4`):** `pure ⇒ !effect` (comptime check over
  `base_natives` + restore assert) and the `depth == 0` clean-entry fail-closed
  (`Error.DirtyTopLevelEntry` from `beginTopLevelEpoch`, release-enforced). §A5/§A6 build on
  these as done.

What remains to build is everything in §A2–§A8. **9-B (GuardProvenance) is un-deferred here**:
it was parked "until it has a consumer," and Part A's classifier + region-membership map are
that consumer (§A4).

##### A0 — Goal, evidence, the one lever

Arm **edge 4** — `cont(29).%023 composite-guard → skip(14).ordinary_entry` — to close nsieve's
four-edge native region so the outer scan `nsieve:14` stops falling back to gated tier-0.
Evidence (`--jit-stats`, ReleaseFast, nsieve 9): `nsieve:14` is **59.4% of wall / 5.0% traced**
because it is *gated* (`onSideExit → max_penalty`, `trace.zig:1550/1578`); the decisive throwaway
A/B (`max_penalty = 1e9`) lifted it to 92.8% traced but moved wall only ~1% — proving the wall is
**per-transition Zig re-entry on the still-open region (~600 ns/hop), not codegen or the indirect
slot load.** Closing the region (Part A) is the lever; the rel32 slot-load shave (Part B) is
second-order. Payoff is a **hypothesis to measure, not a promise** (§A9).

##### A1 — The four edges; Part A adds edge 4

| # | edge | armed by |
|---|------|----------|
| 1 | `skip(14).guard_false → prime-ramp.ordinary_entry` | M1 / 2.3c-1 (landed) |
| 2 | `ramp/cont(29).link → inner(24).linked_entry` | 2.3b-1 (landed) |
| 3 | `inner(24).loopdone → cont(29).ordinary_entry` | 2.3c-2c (landed) |
| 4 | **`cont(29).composite-guard → skip(14).ordinary_entry`** | **Part A (new)** |

Edge 4 is the mirror of edge 1 (a source-branch guard → a child's `ordinary_entry`, same P-C
taxonomy `isSourceBranchGuardExit`), but a *different failed-trace/child pairing* than the two M1
arm sites reach, and — critically — it is **not** a plain `.ordinary_guard` arm: `cont`'s guard
leaves stale phi homes (§A2), so it needs a **bridge**.

##### A2 — Mechanism 1: the edge-4 bridge (emitted-code contract; resolved D-1..D-6)

**A2.1 Why a bridge, and what it commits.** `cont`'s outer-back-edge phis `count+1` (`%004`, idx 4)
and `next i` (`%011`, idx 11) *dominate* its `%023` composite guard, but their writebacks
(`%031→r2`, `%032→r3`, `%033→r6`, idx 31–33) are **post-guard**, so at `%023`-failure the homes
`{r2,r3,r6}` still hold the *previous* iteration's values while `skip` needs the *next*. The shared
`deopt_exit` carried-home flush (`nativegen.zig:4602`) commits the stale homes. The bridge commits
the **dominance-scoped set `E`** = phi update-values whose defining instr dominates the guard
(`update_index < guard_index(23)`) **and** whose target slot is live at the successor — for nsieve
`E = {r2 (count+1), r3 (next i), r6 (next visible i)}`. It **must NOT** commit post-guard phis
(`%034/%035/%037`, inner-loop setup — undefined on this edge) nor run the
`emitLinkedLoopDoneSnapshot` post-guard `astore` scan (`nativegen.zig:3604`). Mechanically it reuses
`flushSlot(a, slot, kind, placeOfRef(alloc, update_ref))` (as `emitLinkedLoopDoneSnapshot` does at
`nativegen.zig:3623`) filtered to `E`. `E` is computable from the parent trace's IR alone via a
compile-time `isCompositeBridgeCandidate(t, ei)` — no arm-time facts.

**A2.2 Entry contract.** The bridge materializes `regs[]` then jumps to **`skip.ordinary_entry`**
(`nativegen.zig:4698`), which presets `linked_loop_done = 0`, falls into `body_entry`, and **re-runs
skip's hoisted type/shape/identity/array-base guards from `regs[]`** — entering at `ordinary_entry`
(never `linked_entry`, never skip's loop head) is what discharges the invariant-bypass hazard. **No
register shuffle**: `skip.entry = [r4 r0 r6 r3 r5]` is a VM-slot list (`trace.zig:636`), the child
reloads homes from `regs[]`. Requires **`child(skip).inputs.len == 0`** (a bare jump can't seed
synthetic inputs), checked at arm time.

**A2.3 Emission — generic stubs armed later (B-3 fork = (b)).** Native lowering sees only `*Trace`
and pages are memoized permanently, so the stub **cannot** depend on the arm-time region map (that
map doesn't exist at lowering). So emit a bridge-capable stub at **every** composite ordinary guard
passing the trace-local `isCompositeBridgeCandidate(t, ei)` (ordinary guard ∧ same-proto outer
re-test ∧ `E` non-empty) — a superset of guards ever armed; an unarmed stub is behaviour-identical to
today's `deopt_exit` path (a few inert bytes). This is the fifth instance of the inert-scaffolding
pattern (`linked_entry`/`ordinary_entry`/`linked_loop_done` already do this). New
**`ArmKind.region_bridge`** (`trace.zig:479`); `armNativeLink(cont, composite_ei, skip, .region_bridge)`
**derives** target `= skip.ordinary_entry` from `child + kind` (never trusts a caller address,
`trace.zig:3264`) and is the sole writer of `slot[ei]`.

**A2.4 Armed-body ordering — cap-check FIRST (D-1), two cells reserved.** The stub head:

```
  load slot[ei]; cmp shared_exit; je ordinary_mini      ; unarmed → behaviour-identical today
  mov rax,[rdx+ledger_len]; cmp rax, LEDGER_CAP-2; ja ordinary_mini   ; armed-but-full → clean yield
  <armed body:>
    1. dominating-phi snapshot E                         (A2.1)
    2. mov [rdx+completed], rbx
    3. emitLedgerAppend(a, t.id, .region_bridge)         (safe: reserved 2 cells)
    4. stage mov [rdx+exit_target], slot[ei]             (flush-immune, as ordinary path :4569)
    5. jmp qword [rdx+exit_target]                       ; native in-page handoff → skip.ordinary_entry
  ordinary_mini:                                          ; reused for BOTH unarmed and ledger-full
    mov [rdx+exit_target], shared_exit; jmp deopt_exit    ; byte-for-behaviour today
```

Two cells reserved (bridge entry + successor terminal) → threshold `CAP-2`; the invariant *"on entry
to any exit stub `ledger_len ≤ CAP-1`"* makes `ledger_len == CAP` at a stub unreachable (P-EBP-2).
The stub writes **no `final_trace_id`** — a generic immutable stub can't know the child id, and the
child's own `emitReturn` stamps it (`nativegen.zig:3249`). There is **no `emitForcedYieldCheck`** in
the armed body — the cap check *is* the yield decision, taken before any state mutation, so a
`.region_bridge` entry is never stamped `.yielded` by its own stub (a forced yield is always owned by
the next hop's stub). `ordinary_mini` is VM-state/output-equivalent to today (not literal-byte —
it adds the dead `load/cmp/je` prefix); the `exit_instr` write at `nativegen.zig:4560` is retained.

**A2.5 Lifetime / ABI — three structures, three lifetimes (D-5, final).** The **machine-code stub**
lives in cont's own page (structurally identical to `linked_loop_done_labels`, `nativegen.zig:4583`),
reachable only through the armed slot; `resetLinksTouching`/`disarmAllLinks` already reset
`(parent, slot_index)` to `shared_exit` on either endpoint's retirement — **stub lifetime is free.**
But the *region metadata* is explicit and split into three (§A3.1): `region_defs` (Proto/VM lifetime,
**NEVER retirement-cleaned** — cleaning it on a GC-physical retire would diverge `gc_stress on/off`),
`region_profit` (activation lifetime, §A5), `armed_links` (the **only** structure retirement-cleaned,
as today). Atomic re-arm ordering: disarm old slot → drop old physical edge → build+publish new →
register dependency → arm slot **last** (any pre-publish failure leaves it unarmed → `ordinary_mini`).
`safe_to_arm` gates the arm; an observation/replay window declines it (§A7).

**A2.6 Arm-time gate + successor set `S` + replay resume-PC + synthesized `completed`.** Arm iff
**`S ⊆ E ∪ invariants`** where `S = live_in(skip) ∪ live_through(edge)` = `{r4,r0,r6,r3,r5} ∪ {r2}`
(a backward-liveness fixed point over the region's cycles; r4/r0/r5 invariant in `regs[]` at the
exit, r3/r6/r2 fed by the committed dominating phis) **and** `child.inputs.len == 0`; else the region
is not armable and the stub permanently runs `ordinary_mini`. Because `LedgerEntry` carries no resume
PC (`irinterp.zig:193`), the `.region_bridge` replay arm derives skip's resume PC from the validated
region edge: look up `(entry.id=cont, entry.exit=composite_ei)` in `region_defs`, validate the edge
is live and its child anchor is `skip@14`, take resume PC `= child_anchor.pc (14)`; `@panic` on an
unregistered/mismatched edge. This is an **additive** grammar — one new `LedgerKind.region_bridge`
plus a dedicated `replayLedger` arm that accepts a **cross-anchor, `rbx`-advancing** successor — and
it **must not weaken** the existing M1 same-anchor `.deopt` invariant (`trace.zig:3098`) or the
zero-progress panic (`:2159`). The selection half of accounting (§A3.2) must receive the *synthesized*
`completed` the current code passes (`onSideExit(owner, max(local,1))`, `trace.zig:2068`) so
`hit_count`/coverage stay byte-identical; only `accountRegionProfit` consumes the normalized region
unit.

##### A3 — Mechanism 2: region-accounting layer + gate strategy B

**A3.1 Three maps.** All three are **transient JIT-tiering state — never serialized** (§A7); keyframe
carries none of them (the v5 bump was `next_obj_id`, unrelated).

- **`region_defs: Map(RegionId, RegionDef)`** — logical region *definition*, `RegionDef = { members:
  set of StructuralEdgeId + membership program-point set, owner: AnchorKey(proto, root_pc), classifier
  }`. Keyed by the **interned** `RegionId` (§A3.3: hash-accelerated lookup, full sorted-set equality
  resolves collisions — never a bare hash). A pure function of the recorded trace graph; **Proto/VM
  lifetime, never retirement-cleaned**; rebuilt on a trace-cache flush.
- **`region_profit: Map(RegionKey, RegionAccum)`**, `RegionKey = { region_id: RegionId, activation:
  u64 }`, `RegionAccum = { outer_traversals, window_base, root_frame_depth, root_call_seq }`. The
  per-activation profit accumulator; **logical region enter/exit lifetime, activation-scoped deletion
  mandatory** (§A5).
- **`armed_links`** — the existing physical `NativeLink` per `(parent, slot)`; the only structure
  `resetLinksTouching`/`disarmAllLinks`/`removeTrace` touch.

Plus two **transient physical classification indices** — `source_exit_regions: ExitKey{Trace.id,
exit_instr} → sorted set RegionId` and `dest_entry_regions` (keyed by the runtime-selected successor
trace) — populated as member traces bind, excluding tombstoned ids, which produce a receipt's
source/destination candidate sets (§A3.5). **Physical** (keyed by the concrete producing/consuming
trace, NOT the logical `StructuralEdgeId` — round-8 review: sibling traces at one anchor share a
boundary `StructuralEdgeId`); not a source of truth; rebuilt on trace-cache flush.

**A3.2 Gate B — `accountTraceRun` / `accountRegionProfit` split (D-4), at EVERY `onSideExit` site.**
Split `onSideExit` into (a) **`accountTraceRun`** — per-segment, **selection logic unchanged**
(coverage/cycle/`hit_count` → `findTrace`/`findLoopTrace`/…), preserving byte-identical trace
selection; and (b) **`accountRegionProfit(region_owner, …)`** — penalty/gate only, updating the
per-activation accumulator via the classifier when `classifyExit` places the exit in a known region.
Applied at every `onSideExit` call site (`replayLedger` arms, `driveChain` tails, dispatcher
productive/zero-progress exits `interp.zig:2852/3010`, scalar burst paths) — **not** one nominal site
per tier. **Gate B aggregates a region's committed traversals and flushes `accountRegionProfit` once
per full `N = min_useful` window** (the precise state machine is §A3.5 — NOT "one per burst," a
round-1 wording since corrected), applied identically across native / tier-1a / unlinked (P-EBP-2). Chosen over **(c) exempt-armed** because (c) conflates *linkable* (a recorder
fact) with *profitable* (a runtime fact) and would pin an armed-but-ping-ponging edge forever; B
measures the fused region (which self-loops thousands of times per `i`) **and** still retires
genuinely cold regions (< `min_useful` traversals) in the same gate. `AnchorKey(proto, root_pc)` is
retained **only** as the gate/penalty blast-radius key (gating `(proto,14)` ungates its siblings
uniformly), read by `accountRegionProfit` at flush — never the accumulator key.

**A3.3 Identity keys — `RegionId` is INTERNED on the full sorted edge SET; the hash only accelerates
(round-2 review R2-3, round-3 review finding 1).** The edge set *is* the identity. `RegionId` is
minted by interning: collect the region's `StructuralEdgeId`s, put them in a **fixed total order**
(**NOT** discovery/insertion order — round-1 BLOCKER 2: discovery order varies by recording sequence
and would make the identity, hence the gate key, mode-dependent), and look the sorted set up in a
`region_intern` map. A 64-bit hash of the sorted set is **bucket acceleration only**: a hash *hit* is
confirmed by **full sorted-set equality** before reusing the existing `RegionId`, and a genuine
collision (equal hash, unequal set) **mints a distinct `RegionId`**. `region_defs` is therefore
`Map(RegionId, RegionDef)` keyed by the interned id, but equality is the set (§A3.1). The **complete**
edge key is
`StructuralEdgeId = { anchor_proto_id, anchor_pc, ExitProvenance(exit), succ_anchor_proto_id,
succ_anchor_pc }` — the successor anchor is `{proto, pc}` (a bare `succ_anchor_pc` aliases successors at
the same PC in different protos — round-4 review, finding 1; an anchor is `{proto, pc}`,
`trace.zig:561`). Do **not** reduce it to `(source_proto_id, source_pc, role, selected-edge)`, which
aliases the same site reached through different inline paths, multiple operand guards at one opcode, and
logically different successors.

**`ExitProvenance` is a union, because not every structural edge exits through a guard (round-6 review,
finding 1).** Edge 2 (`ramp/cont.link → inner.linked_entry`) leaves through a **`.link` terminal**,
which is *not* a `guard_*` node (`trace.zig:498`), so a bare `GuardProvenance(exit)` cannot key it:
```
ExitProvenance = union(enum) {
    guard:         GuardProvenance,                                   // the guard exits (§A4)
    link_terminal: { path: [MAX_INLINE_DEPTH]CallEdge, source_proto_id: u32, source_pc: u32 },
}                                                                     // role ≡ .link_terminal, polarity .neutral, no operand
```
**The `.link_terminal` provenance needs a two-stage transport — `recForPrepLink` does not emit `.link`
(round-7 review, finding 1).** `recForPrepLink` (`trace.zig:5008`) records `link_target` and calls
`closeTrace` (`:5080`); the `.link` instruction itself is **synthesized later, at commit**
(`trace.zig:3844`), and link traces **bypass `tropt.optimize`** (they use the duplication path because
optimization expects a `.loop`, `:3853`). So there is no emission-index to key at `recForPrepLink`, and
stamping "where the link is emitted" would attach to the wrong instruction (or none). Transport:
- Add **`Recorder.pending_link_provenance: ?LinkProvenance`**. `recForPrepLink` fills it with the inline
  `path`, `source_proto_id`, and **`source_pc = pc − 1`** (the recording PC is post-increment, so the
  originating `for_prep` site is `pc − 1`, cf. the record call near `interp.zig:1886`).
- The **commit path** (`trace.zig:3844`) consumes `pending_link_provenance` when it appends the
  synthesized `.link`, keying the side table by that **new committed index**.
- The **`tropt.dupe` path copies it** (link traces take duplication, not `optimize`); **all
  abort/reset paths clear it** (`resetTrace` link-state clear, `trace.zig:5582`) — fail-closed, a stale
  pending provenance must never bind to an unrelated later link. **Release-assert
  `link_target != null ⇔ pending_link_provenance != null` immediately before the `.link` append**
  (`trace.zig:3843`; one `link_target` setter at `:5082`), so any path that synthesizes a `.link`
  without a matching fill aborts loudly in every build.
With that transport the `ExitProvenance` union distinguishes all four edges — the issue was provenance
transport, not the union's information content. (Equivalently one may widen `GuardProvenance`'s closed
`role` vocab with a `.link_terminal` member and rename it `ExitProvenance` — same content; the union
spelling is clearer about "this exit is not a value guard.") It
is the persistent def key, **guest-logical** so a re-recorded logically-identical edge (new `Trace.id`)
computes the same id and rebinds to the same def; the `GuardProvenance(exit)` component (§A4) replaces
the abandoned IR-position `exit_ordinal`. A pure **ephemeral cache** `(Trace.id, exit_instr) →
StructuralEdgeId` is rebuilt on commit, dropped on retirement, never the source of truth. The
classifier key is an **optional `?ExitKey{Trace.id, exit_instr}`**: synthetic scalar-burst
`onSideExit(seed, 0)` sites (`trace.zig:2708/2873`) pass **`null`** (region accounting skips
null-keyed events for *classification* — never open/close/credit — though the tier-0
`observeRegionProgramPoint` hook still runs after them, §A3.5). **Every concrete keyed receipt** carries
the key — both **guard exits** *and* the **terminal `.link_terminal`** (a real instruction index,
`e.exit == owner.instrs.len − 1`, `trace.zig:2037`); only **prologue-fail / synthetic events with no
real instruction index** pass `null`.
Membership is tracked by **active `RegionId` identity, never PC containment** (a transition to any
identity outside the active region is a genuine exit even under PC overlap).

**A3.4 `call_seq` (D-3c = β).** A per-VM monotonic `call_seq: u64` on `CallFrame`, drawn from a
VM-level `next_call_seq`, bumped at the **single physical frame-push choke point `pushFrameVararg`
(`interp.zig:1439`; anchor refreshed per the round-1 review, was 1346)** — which catches both the
bytecode `.call` handler and the host-reentrant `callValue` path. `RegionKey.activation = root_call_seq`, snapshotted from the anchor frame at window
open. **Tier-invariant** because traces *inline* Lua callees by register renaming and push no physical
`CallFrame` (`recCall` emits only `guard_func`; `recReturn` emits nothing), so the anchor frame's
`call_seq` is assigned by tier-0 before tier-up and **nothing on-trace ever writes `call_seq`** →
identical across tier-0/tier-1a/native. Determinism-safe (a pure function of the executed call
stream, same class as the direct-mapped hotcount). **Fail-closed:** an armed region must anchor at the
exact physically-current frame `frames[depth-1]` (by index + closure identity + anchor relation),
never a trace-inlined/elided callee; else decline to arm. `next_call_seq` gets a checked-increment /
u64-exhaustion contract (fail-closed on wrap). **Restore re-key (F-2):** `restoreSnapshot` writes
`vm.frames[i]` directly (`keyframeser.zig:699`; anchor refreshed per the round-1 review, was 671),
bypassing `pushFrameVararg`, so restore **re-keys each live frame by index — `frames[i].call_seq = i`,
`next_call_seq = vm.depth`** — giving each restored
frame (incl. several live instances of one recursive proto) a distinct key. No wire field; `call_seq`
stays unserialized (the v5 bump was `next_obj_id` only). Single physical stack `frames[0..depth]`
(G-5); a future coroutine feature would make this a global-flat monotonic assignment.

**A3.5 The accounting state machine (round-1 review, BLOCKER 2 — now a complete contract).** A
region's accumulator is driven by a **deterministic per-transition `outer_delta`**, a window flush,
and a region-exit flush. The three are specified so a lone/cold region and a hot region reach the
gate through the *same* code, and so nothing is tier-dependent.

**‡ Work and structural role are ORTHOGONAL per receipt (round-2 review, R2-1).** Each receipt
carries **two independent things**, and the classifier emits both — do NOT collapse them into one
role-keyed delta. (The trap: there is **no native event per `skip.loop` back-edge** — native code just
`inc rbx` and jumps, `nativegen.zig:4498`; skip's committed composite count is delivered *later*, on
the **source-branch `.deopt` receipt = edge 1**, where `local` is documented as skip's committed count,
`trace.zig:2159/2179/2187`. So the edge-1 receipt is *simultaneously* "carries `local` skip work" and
"is a source-branch control transition." A single role-keyed delta cannot express that.)

- **`segment_delta(owner, work)`** — the committed-work payload the receipt carries: a **skip segment**
  receipt (delivered on its edge-1 `.deopt`) contributes `work = local`; an **inner loop-done** receipt
  contributes `work = 1` (one outer traversal, regardless of the inner loop's large local `k`,
  `trace.zig:2595`); a pure control/bridge receipt with no committed segment contributes `work = 0`.
  `outer_traversals += work`.
- **`transition_edge`** — the receipt's structural role (edge 1–4 / null), which drives **region
  state** (open / continue / exit per §"exit detection" below) but adds no work of its own. An edge-1
  receipt therefore commonly carries **nonzero** `segment_delta` *and* is a control transition — both
  are accounted from the one receipt.
- **`null`-keyed synthetic events** (§A3.3): `segment_delta = 0`, `transition_edge = none` — the event
  itself performs **no region-state inference** (it cannot recover a concrete exit from a null key);
  region departure after it is detected by the subsequent `observeRegionProgramPoint` tier-0 hook.

**‡ Receipt processing ORDER is fixed (round-3 review finding 3, round-4 review finding 2).** A single
receipt can *both* carry source-region work *and* leave that region (edge 1 = skip's committed `local`
+ a control transition), and its owner is resolved from the physical ledger owner first
(`trace.zig:2008`, `local` derived at `:2021`) — which may differ from whatever region is *currently*
active. So the order must first **normalize the source accumulator** (open it / switch to it) before
crediting, or first-entry and A-active/B-source states are undefined. Every non-null receipt is
processed in exactly this order:

**Candidate sets separate REGION IDENTITY (logical) from BOUNDARY CLASSIFICATION (PHYSICAL) — round-7
finding 2, round-8 review.** A receipt that carries nonzero `segment_delta` *and* leaves its region
rides a **boundary exit edge** that is **not** one of the region's *internal* structural edges — so
inverting only the interned member-edge set would give it **zero source candidates**, wrongly take the
`A/∅` row, and lose the terminal work. But classification also must **not** key on the logical
`StructuralEdgeId` alone: lune runs **multiple sibling traces at one anchor** (`nextTraceExcluding`
`trace.zig:2921`; side recording restarts at the same anchor `:3024`; `countTracesAt(anchor) ≥ 2`
`:2178`), and two siblings can traverse different earlier guest paths yet converge on the *same* exit
site + polarity + successor — hence the **same boundary `StructuralEdgeId`** — while only one physical
segment belongs to `R`. Keying `edge_source_regions[StructuralEdgeId]` would then credit `R` for a
*non-member* sibling's receipt. So the two concerns come fully apart:
- **Region identity** (interns the `RegionId`, §A3.3) is **logical** — the region's **internal edges
  only**; boundary/exit edges are **kept OUT of the sorted intern set** (an exit edge would corrupt the
  topology identity). `StructuralEdgeId` stays the key for stable interning + re-record rebinding.
- **Boundary classification** (produces candidate sets) is **physical + transient**, keyed by the
  concrete producing/consuming trace, never by `StructuralEdgeId` alone:
  - **`source_exit_regions: ExitKey{Trace.id, exit_instr} → sorted set RegionId`** — contains `R`
    whenever *this physical exit of this bound member trace* belongs to `R` (incl. edges that leave
    `R`). Derived from the actual bound member traces; the receipt **already resolves its physical
    owner before computing `local`** (`trace.zig:2008`), so the owner is in hand. A sibling that is not
    a member has a different `Trace.id` → does **not** map to `R`.
  - **`dest_entry_regions`** — a destination is classified **only when the runtime has identified the
    actual successor trace** (the next ledger entry's `trace_id`, or the dispatcher's selected child),
    an analogous transient physical binding — **not** merely `{succ_proto, succ_pc}` (which doesn't say
    *which* sibling accepted entry). **If no actual successor has been selected yet, defer opening**
    the destination until its first *source* receipt, rather than speculatively opening from the anchor
    PC.

Both indices **exclude tombstoned (`armable == false`) ids** (§A3.5 invalidate) and are transient
JIT-tiering state rebuilt on trace-cache flush (§A7). (This corrects the earlier "inverted from
`region_defs`" phrasing in §A3.1: the *logical member set* lives in `region_defs`, but the *physical
classification indices* are keyed by `{Trace.id, exit_instr}` / selected-successor and populated as
member traces bind, not by inverting the logical edge set.) Sibling-trace tests are mandatory: two
traces sharing one boundary `StructuralEdgeId` where only one is a region member — assert correct
source credit AND destination opening for the member, and region-neutral for the non-member.

Every non-null receipt therefore yields a **source-candidate set** (`source_exit_regions[{receipt owner
Trace.id, exit_instr}]`) and a **destination classification** that is one of **three states, NOT a
plain set** (round-9 review): `deferred` (no actual successor selected yet — e.g. an unfused, cap-
yielded, or dispatcher-bound transition; a full-ledger forced yield, `trace.zig:2015`; a terminal
`.link_terminal` returning to dispatcher steering, `:2045`), `known(set)` (`dest_entry_regions[selected
successor trace]` once the runtime has picked the child), or `terminal_outside` (a receipt that
*proves* a logical exit without selecting a trace; otherwise this is left to the program-point
observer). Collapsing `deferred` into `∅` was the round-9 bug: `∅` means "the selected successor
belongs to no region," which flushes+closes the source — but a not-yet-selected successor must **not**
close the region (that would reduce region accounting back toward per-burst accounting and add
tier-dependent remainder flushes). The complete `(active accumulator,
candidate set)` table is pinned (round-4 finding 2, round-5/6 finding 2) — no case falls through, and
the transition phase operates on **`?selected_source`** (there may be none — an outside→region entry):

*Source selection + normalization.* Classify the receipt to its source-`RegionId` candidate set, then:
| active | candidates | action |
|---|---|---|
| none | ∅ | **region-neutral** (skip accounting) |
| none | {X} | **open** X's accumulator, then credit |
| none | {≥2} | **`invalidateRegion`** each ambiguous candidate; region-neutral |
| A | ∅ | **flush(`r>0`)+close A**; region-neutral (a concrete receipt matched zero regions *has left A* — do NOT wait for `observeRegionProgramPoint`, a fused native receipt may follow before tier-0 runs) |
| A | set ∋ A | **select A** (even if other candidates also claim the edge — the active id wins, no invalidation) |
| A | {B} (B≠A) | **flush(`r>0`)+close A**, open B, then credit B |
| A | {≥2}, A ∉ set | **flush(`r>0`)+close A**, `invalidateRegion` each ambiguous candidate; region-neutral |

*Credit the selected source* (if any): **add `segment_delta`** (`outer_traversals += work`), then
**flush every complete `N` window** (`while (outer_traversals − window_base ≥ N) {
accountRegionProfit(owner, N); window_base += N; }`). If `selected_source` is **null** (an
outside→region entry), there is nothing to credit — proceed straight to the destination table's
no-source rows.

*Destination (apply `transition_edge`), on `?selected_source` × destination-classification:*
| selected_source | destination classification | action |
|---|---|---|
| any | **`deferred`** (successor not yet selected) | **retain** `selected_source` as-is — **no flush, no close** (a later selected-child event or `observeRegionProgramPoint` decides). This is the round-9 fix: cap-yield / unfused / forced-yield / terminal-`.link_terminal` do NOT exit the region. |
| — (none) | `known(∅)` | **region-neutral** |
| — (none) | `known({D})` | **open** D (the normal outside→region entry — round-6 review, finding 2) |
| — (none) | `known({≥2})` | **`invalidateRegion`** each ambiguous candidate; region-neutral |
| — (none) | `terminal_outside` | region-neutral |
| S | `known(set ∋ S)` | **continue** S |
| S | `known(∅)` | **flush(`r>0`)+close** S (the selected successor genuinely belongs to no region) |
| S | `terminal_outside` | **flush(`r>0`)+close** S |
| S | `known({D})` (D≠S) | **flush(`r>0`)+close** S, then **open** D |
| S | `known({≥2})`, S ∉ set | **flush(`r>0`)+close** S, `invalidateRegion` each ambiguous candidate |

**`null`-keyed synthetic events are the sole exception** — no structural identity, so they perform no
selection/close here; region departure after them is detected by `observeRegionProgramPoint`.

Tests (§A4 list): (a) a nonzero-`segment_delta` receipt that also exits (terminal work credited before
close); (b) an overlapping-PC transition to a *different* `RegionId` (closes on identity); (c) a null
event immediately followed by an outside `observeRegionProgramPoint` program point (departure detected
by the hook, not the null event); (d) **first-entry** — first classified receipt carries source work,
no accumulator active (open-before-credit); (e) **A-active/B-source** — A active, receipt classifies to
B (close A before opening/crediting B); (f) **A-active/zero-candidate** concrete receipt (close A
immediately, don't wait for the tier-0 hook); (g) **ambiguous multi-candidate** edge (`invalidateRegion`
the candidates, no arm survives); (h) **boundary-entry** — active {none | A}, **zero source** candidates
but **exactly one destination** candidate D (opens D; when A was active, A is closed first); (i)
**nonzero-work boundary exit** — a receipt on an edge *leaving* R that carries `segment_delta > 0`:
source candidates `{R}` (via `source_exit_regions[{owner Trace.id, exit_instr}]`, keyed by the
producing trace's membership, not by R's internal edge set), destination `known(∅)` ⇒ **credit R, flush
complete windows + `r>0` remainder, then close R** (must NOT hit the `A/∅`-loses-work path); (j)
**deferred transition does not close** — an unfused internal member transition of R (successor not yet
selected ⇒ `deferred`) followed by selection of *another R member*: **no intermediate remainder flush**,
R stays open; (k) **forced yield inside R survives** — a full-ledger cap yield (`trace.zig:2015`, no
following successor entry) leaves R's accumulator intact; (l) **deferred-then-outside** — the same
deferred transition followed by an outside tier-0 program point: `observeRegionProgramPoint` closes R
**exactly once** (not double-closed by a spurious destination `∅`).

**Full-window flush** (per window, not per burst — A3.2's "one `accountRegionProfit` per burst" is
corrected to **one per full `N` window**): `while (outer_traversals − window_base ≥ N) {
accountRegionProfit(owner, N); window_base += N; }` with **`N = min_useful = 8`**, tier-independent
(NOT native `LEDGER_CAP`, NOT tier-1a's 8-hop, NOT the unlinked per-segment count). Each full window
clears penalty / ungates the anchor.

*Region exit (drops the accumulator, reclaims `RegionKey`) — flushes a NONZERO remainder as ONE
low-yield window.* On a genuine exit the carried remainder `r = outer_traversals − window_base`
(`0 ≤ r < N`) is flushed **once, and only when `r > 0`** (round-2 review, R2-1: a zero-work
`accountRegionProfit(owner, 0)` is a spurious low-yield strike under the current gate,
`trace.zig:1594` — so an exact-multiple-of-`N` exit or a control-only visit must NOT emit one). A
region that repeatedly runs 1–7 traversals and exits is charged a low-yield event each time and
**still retires** (the cold-region retirement gate B keeps; without the `r>0` exit-flush a sub-`N`
region would silently escape both ungating and penalty).

**‡ Exit detection is a dedicated tier-0 hook, NOT `onSideExit` (round-2 review, R2-2).** `onSideExit`
fires only on *trace receipts*, but a region can be left by ordinary forward tier-0 instructions
(fall-through / `break`) that produce no receipt — so exit detection needs its own cheap per-op hook
`observeRegionProgramPoint(proto_id, pc, depth, call_seq)` in **`nextOp`** (`interp.zig:1796`, current
PC at `:1851`), **guarded by "any accumulator live"** so it costs nothing when no region is active.
Region **membership is a set of qualified program points `{proto_id, pc}`** (a bare PC is
insufficient — round-2 review). **The membership set is built from RECORDED PATHS, not a static CFG
walk (round-3 review, finding 2).** "Corridors between anchors" is under-specified — "all paths,"
"shortest path," and "the recorded path" give different sets, and lune has no canonical CFG structure
to consume (only decoded opcodes + offsets, `bytecode.zig:178`; distinct successor rules at
`interp.zig:2111/2131/2144/2165`). The exact, buildable construction:
- **During recording, retain the ordered `{proto_id, source_pc}` stream** of every guest instruction
  traversed, captured **before IR optimization** (the same pre-opt point GuardProvenance is stamped, so
  no post-`tropt` renumbering hazard). Each committed trace carries this as **transient path metadata**
  (JIT-tiering state, never serialized — §A7).
- **Region membership = the canonical union** of the member traces' recorded `{proto_id, source_pc}`
  paths **plus the explicitly-validated handoff endpoints** (the armed edges' anchor + successor PCs).
- **Rebinding the same `RegionId`** (a re-record of a logically-identical region) **must confirm
  compatible membership**. One `RegionId` maps to **exactly one `RegionDef`** — `region_defs` is
  `Map(RegionId, RegionDef)` and `RegionKey` carries only the id, so a second definition is
  unrepresentable (round-4 review, finding 1). Therefore: identical recorded-path union ⇒ reuse; a
  *differing* path set (or a region that cannot be reconstructed uniquely) ⇒ **`invalidateRegion(id)`**
  (fail-closed — an unarmed region is state-equivalent, §A8 A-v). Do **NOT** mint a second `RegionDef`
  and do **NOT** silently discovery-order-union the paths. (If membership variance ever proves common
  enough to matter, the alternative is to fold the canonical membership set *into* the intern key so
  the combined identity *is* the `RegionId` — deferred; the conservative invalidate rule is the Part-A
  contract.)

  **`invalidateRegion(region_id)` — concrete operation (round-5 review, finding 1).** The physical
  `NativeLink` carries no region identity (`{parent, slot_index, child}`, `trace.zig:913`) and the
  targeted teardown `resetLinksTouching` takes a physical `*Trace`, not a `RegionId` (`trace.zig:3380`),
  so there is no reliable way to enumerate exactly the links of one logical region. Part-A therefore
  uses **conservative global teardown** (rare, allocation-free, cannot leave a dangling slot):
  1. Permanently set `RegionDef.armable = false` (the def stays as a **tombstone**; never deleted, so
     the `RegionId` can't be re-minted with different membership).
  2. Flush any nonzero (`r>0`) remainders and **remove all `region_profit` entries for that id**.
  3. Call `disarmAllLinks()` (resets every registered parent slot + clears the registry,
     `trace.zig:3415`).
  4. Every arm/re-arm path **rechecks `RegionDef.armable` immediately before `armNativeLink`**.
  5. Subsequent classifier hits on the tombstoned id are **region-neutral** — they cannot recreate an
     accumulator or an arm.
  (A *targeted* alternative would add `region_id` to `NativeLink` and tag/re-tag every edge — a
  substantially larger change, deferred with the intern-key alternative above.)
A genuine exit is: the observed
`{proto_id, pc}` is **outside** the membership set **AND** `depth ≤ captured_anchor_depth` (F-6
polarity — a *deeper* re-entrant host call, e.g. a `table.sort` comparator via `native_reentry_depth`,
keeps the anchor live → do NOT close). This reconciles §A3.3: **edge identity** classifies
*trace-to-trace* transitions; the **program-point observer** closes a region during *tier-0*
execution. Exit **never** fires on `LEDGER_CAP`/hop exhaustion + re-entry, native-call return,
**GC-safepoint exit** (excluded — the `gc_stress` corollary), or trace retirement.

Region membership is discovered from the recorded trace graph in every tier (native *arming* consumes
a discovered region, never creates it). P-EBP-2 equivalence (§Determinism obligations) is over the
**same logical receipt stream**: the `(segment_delta, transition_edge, window flush, r>0 exit flush)`
sequence is a pure function of that stream, identical whether the receipts came from native hops,
tier-1a hops, or unlinked per-segment `onSideExit`s.

##### A4 — Mechanism 3: GuardProvenance (9-B), un-deferred (Part A is the consumer)

The region-membership map (§A3.3) and the classifier key on **guest-logical exit identity**, not IR
position — because recording is guest-value-dependent (`guardNum` int/float by value, `guard_true/
false` by taken path, realized-subset variance, elision/LICM), and `guardExitPc` can't even supply
`exit_pc` for array/table/grid guards (only 6 ops carry a PC in `aux`, `trace.zig:451`). So each exit
carries a **`GuardProvenance` tag stamped at emission**, a deterministic function of `(guest bytecode
site, inline path, selected static CFG edge)` — sharpened per round-2 review (B1): the earlier
"`(guest bytecode, inlining structure)` alone" was **literally incomplete**, because for a branch
guard *which* of the two out-edges the trace recorded is chosen by the observed truthiness at record
time (`recBranch`, `trace.zig:4900/4905`). The resolution is not to drop that input but to **name it
and freeze it**: once recording commits to an edge, the *selected* CFG edge (the `polarity`
discriminator below) is a **static property of the recorded trace**, so the tag's inputs are the
bytecode site, the inline path, and that selected edge — all trace-static, none an ongoing observed
value. Under that corrected statement the tag is deterministic and optimizer-invariant:

```
GuardProvenance = { path: [MAX_INLINE_DEPTH]CallEdge (len = inline_depth),  // edges only
                    source_proto_id: u32, source_pc: u32,                    // the leaf, split out
                    role: Role, operand: OperandDesig,
                    polarity: Polarity }   // selected static CFG out-edge; .neutral for non-branch guards
CallEdge = { caller_proto_id: u32, call_pc: u32 }
Polarity  = enum { neutral, taken, fallthrough }   // which out-edge recording committed to (round-2 R2/B1, round-3 finding 1)
```

- **`path`** = the ordered inline call-**edge** prefix (a *sequence*, not a multiset — recursion to
  depth 3 is reachable), backed by extending `InlineFrame` (`trace.zig:5398`) with `{caller_proto_id,
  call_pc}` set in `recCall` from `proto.id` + the call PC (both live there, currently discarded — the
  `f(a); f(b)` collision fix). `MAX_INLINE_DEPTH = 3` ⇒ inline `[3]`, **no alloc**.
- **`role`** is a **closed structural vocab, NOT the op enum** (the op is a runtime *view* of the same
  site), stamped explicitly at emission with a runtime-selected realized subset; per-opcode
  `(role, operand)` table (H-1c, tree-corrected: `set_index` container is `a`; `for_loop/for_prep`
  guard three operand-types; hash-set guards value first; grid guards row+col; pure-call guards its
  arg; `get_upval/get_global → guard_func`; `guard_fits` is every-narrow-lane). `operand` is a
  **static register designator** (`a/b/c/a+1/a+2/aux`); the **lane ordinal is NOT an operand**
  (observed runtime representation → would inject an observed input).
- **‡ Branch polarity is part of the identity (round-1 review, BLOCKER 1).** `recBranch` emits
  `guard_true` *or* `guard_false` by the taken path (`trace.zig:4900/4905`), and these are **opposite
  CFG edges** of the region — the true-exit and the false-exit of one `if` are different transitions
  (edge 1 = `skip.guard_false`, edge 4 = `cont.guard_true`-fail — literally the two polarities of the
  outer `if p[i]`). So a branch guard's tag carries an explicit **`polarity` / exit-CFG-edge
  discriminator** (which structural exit this is: taken-branch vs fall-through). This is **guest-static
  edge selection** (which of the branch's two out-edges the recording committed to), *not* an observed
  value — omitting it lets `StructuralEdgeId` rebind an opposite-polarity re-record onto a stale
  logical edge (worse because `region_defs` outlives physical retirement). Add an **opposite-polarity
  re-record collision test** to §A4's test list. (Non-branch guards leave `polarity` neutral.)
- **`source_pc = cur_pc − 1`** (`cur_pc` is the post-increment resume PC); `= guardSourcePc(ins)` for
  the 6 PC-carrying guards (H-1b, landed), **explicitly stamped** via a `currentSourcePc()` helper for
  the 13 non-PC guards + the **3 fused native producer-exits** (`hload` `nativegen.zig:4022`, `.value`
  `aload` `:4120`, `href` `:3517`, which have no `guard_*` node).
- **Storage = transient side table keyed by the COMMITTED instr index** (NOT an `IrInstr` field — the
  16-byte budget + guards-are-a-minority; also transient ⇒ zero schema bump, rebuilt on re-record).
  **‡ Optimizer-remap obligation:** emission-time indices are **stale at commit** — `tropt.optimize`
  (`tropt.zig:223`) CSEs, drops duplicate/always-pass guards (`:299`), DCEs, LICM-hoists, and assigns
  fresh `new_index` (`:494`); provenance **must** be remapped via `new_index` (dropping dead entries,
  the survivor of a dedup keeps its own tag — many-to-one is correct) and copied by `tropt.dupe`
  (`:204`); freed on the same errdefer as `instrs` (incl. the optimize-OOM path).
- **`occurrence` is retired** (un-groundable dynamic ordinal); within one opcode execution
  `(role, operand)` is already unique; unrolled physical copies deliberately **share** one tag.
- **Precondition to state:** `path`/leaf identity relies on globally-unique `Proto.id` (an invariant
  of the one-static-image + `load` model, not enforced by `Proto` — defaults 0 for hand-built protos).
  State it, or enforce global proto-id uniqueness.

Because Part A is now the consumer, the `Role` enum and the exact tag fields the classifier reads are
**pinned by this design** (no longer provisional). Tests: 10-mode matrix + re-record-stability
(validate each *committed* entry against the *committed* instr post-`tropt`, not two stale emission
tables) + `f(a);f(b)` collision + optimizer-remap (opt ON vs OFF) + max-inline-depth + `source_pc ==
cur_pc−1` / no-observed-lane.

##### A5 — Mechanism 4: region-cap contract (H-3)

**Fork resolved (round-1 review, BLOCKER 5): option (c), no cap.** `region_profit` is an **uncapped
map bounded purely by mandatory activation-scoped deletion** — no fixed cap, no eviction path at all
(there is no static `max_anchors_per_proto`; protos load with varying `code.len`, so any constant
would be arbitrary). Live entries are bounded because live *activations* are bounded (`max_call_depth
= 200`, `interp.zig:119`, fixed `frames` array) **and** an entry is deleted the instant its activation
ends. **Activation-scoped deletion is MANDATORY** (G-3): an entry is removed at every normal frame
pop (`.ret/.halt`, `interp.zig:2469/2488/2519` — anchors refreshed per the round-1 review; the
consolidated draft's 2345/2364/2395 were stale) **and** all three `protectedCall` error-unwind depth
restores (`errors.zig:100/108/117`). Entry lifetime = activation lifetime ⇒ **the map never holds a
dead entry, so there is nothing to evict** and **silent evict-live cannot arise** (it is banned
anyway — un-accounting an armed region corrupts the gate, P-EBP-2).

**Release-enforced cardinality invariant:** **at most one active accumulator per `(call_seq, owner
AnchorKey)`** (`call_seq` = the anchor frame's activation id, §A3.4). Depth alone does *not* bound the
number of distinct sibling `RegionId`s one frame could open at one anchor, so the invariant is stated
and *enforced*, not merely hoped. **Replacement rule:** if a *different* `RegionId` is opened for a
`(call_seq, AnchorKey)` that already has a live accumulator, **close+flush the old accumulator** (the
§A3.5 region-exit remainder flush) **before** installing the new one — never silently overwrite, and
never keep two. (This is the natural encoding: the frame moved from one region to another at the same
anchor; the old region genuinely exited.) A release assert pins "≤ 1 live entry per `(call_seq,
AnchorKey)`."

`region_profit` is cleared wholesale at `beginTopLevelEpoch` — **after** the **landed** `depth == 0`
`Error.DirtyTopLevelEntry` precondition passes (9-A) and alongside the existing `disarmAllLinks`.

##### A6 — Mechanism 5: native-F2c logical cut + test (H-4)

`suspend_ctl` is tier-0-only (safepoint-counted, `interp.zig:1716`) and a native trace runs a whole
burst without advancing `safepoint_seq`, so a safepoint-count cut is tier-dependent (G-4). Since
**every host effect aborts recording** (`.host_barrier`, `trace.zig:5046`; the only inlined natives
are effect-free `PureBuiltin`s), **no effect ever commits on-trace** — so the **tier-0 boundary after
the Nth committed effect is the only implementable tier-independent cut.** (`pure ⇒ !effect` is landed,
9-A, so the barrier is structural.)

**The cut counter must be mode-independent: `committed_effect_seq`, not `effect_cursor` (round-1
review, BLOCKER 6).** `effect_cursor` only advances in **replay** (`interp.zig:4004`); in record mode
the effect is appended but the cursor does not move (`interp.zig:3976/3994`) — so `effect_cursor == N`
is *not* the same logical event across modes. Introduce a **`committed_effect_seq`** incremented once
**after** a successful effect result is committed, in *every* mode, and cut on it. Cut at the **first
snapshot-eligible tier-0 boundary at or after `committed_effect_seq == N`**, not the immediate next
instruction: an effect used as a multret producer sets `reg_top_pending` (`interp.zig:3685`) and the
suspend check refuses while it's set (`:1719`), and a faulting effect has no successful next boundary —
so the harness selects a successful fixed-result effect (e.g. `local t = os.clock()`) and steps
eligible boundaries until the count is reached.

**There is no single existing choke point — enumerate all four commit paths (round-2 review, R2-5).**
Effects are committed at four distinct sites, and the counter must be bumped by a *common* hook
`onEffectCommitted()` invoked from **each**, *after* that site's success/shape/version validation, in
every mode (off/record/replay): (1) **normal native effects** (`interp.zig:3976`) — after the
appended result is accepted; (2) **lazy random-seed materialization** (`interp.zig:4017`) — after the
seed is drawn and committed; (3) **unicode-version pin** (`interp.zig:4058`) — after the version is
pinned, **guarded by `versionAlreadyConsumed`** so an *already-consumed* pin does **not** re-increment
(it committed nothing new); (4) **file reads** (`interp.zig:4089`) — after the read result is
validated. **A failed/faulting effect increments nothing** (the hook is downstream of validation at
every site). `onEffectCommitted` is the single logical "effect committed" definition; no site bumps
the counter inline. The F-5 test must exercise **every effect family** (a normal effect, a
random-seed draw, a unicode-version pin including the already-consumed re-entry, and a file read)
across **off / record / replay** and assert `committed_effect_seq` is byte-identical at the cut in all
three — proving the counter is mode-independent per family, not just for `os.clock`.

**The keyframe is not yet "full" — vararg cursors are missing (round-1 review, BLOCKER 6).** The
claimed full-semantic-keyframe includes each frame's vararg state, but the wire schema **omits**
`varargs_base`/`varargs_count` (`schema/trace.json:163`; `keyframeser.zig:288/709` construct/restore a
`FrameRef` without them), so restore silently leaves them at defaults and a cut **inside a live vararg
frame is not semantically complete.** **Resolution — option (a), committed (round-2 review, Q6):** add
`varargs_base`/`varargs_count` to `FrameRef`, bump the snapshot schema, serialize + validate + restore
them. This is a **pre-existing keyframe-completeness gap** (a snapshot taken inside a live vararg
frame is unsound *today*, independent of edge 4), the same class as the `next_obj_id` gap that became
its own foundational-piece ticket (#27) — so it lands as **its own foundational piece, sequenced
before Part A's F2c work**, not folded into the harness. Rejected the round-1 fallback (b) ("scope the
harness to non-vararg frames") because it leaves the underlying unsoundness in the tree. Regenerate
the schema via `tools/regen-trace-schema.sh` (never hand-edit `src/gen/`). Either way the cut assertion is
**semantic keyframe (as serialized) + the replay-driver state the keyframe omits** (`effect_log`
prefix + `committed_effect_seq`, output prefix, PRNG state) — **not the effect counter alone** (a
coarse clock that a heap-heavy/few-effect loop advances too slowly to catch a diverged heap). The
**native-F2c test (F-5)** must (a) cut at the tier-0 boundary immediately after a post-native-burst
effect and (b) assert this full-state identity; it also catches H-5(i) — numeric-`for` traces omit
dead expression temporaries from the exit snapshot (`trace.zig:3761`), so a post-native-exit cut
could serialize a stale temporary. Do **NOT** introduce a snapshot call inside
`logEffect`/`performEffect`.

##### A7 — Determinism inheritance + the sharp open question

**Inherited (already shipped):** snapshot bytes are JIT-tiering-independent (H-2 closed, keyframe v5,
`{gc,snapshot}` split). Part A's obligation is to **stay in that lane**: `region_defs`/`region_profit`/
`call_seq` are transient, `.gc`-only-or-non-root, **never a `.snapshot` root**, and **reset on
restore** (`region_profit`/`call_seq` re-keyed per §A3.4; `region_defs` rebuilt from the trace graph)
— so they are structurally incapable of appearing in serialized bytes.

**P-EBP-1/2 — the correctness property is OUTPUT identity, not trace-selection identity (round-1
review, BLOCKER 3, retraction).** An earlier draft required "`nsieve:14` must not change *which* later
traces record." That is **false and not needed.** Every interpreted back-edge advances the global
tiering tick / direct-mapped hotcount (`trace.zig:3598`) and gate-retry cooldown keys on it
(`:3586`), but a **native** back-edge only bumps `rbx` and jumps locally (`nativegen.zig:4498`) — it
does *not* reproduce the tick. So closing edge 4 removes dispatcher-visible outer back-edges and
**does** shift tick/cooldown timing for unrelated gated anchors — exactly as tier selection *already*
differs across the 10 modes today (that is the premise: `record_execute_native` and `off` pick
different traces yet print identically). The replay/determinism contract is **byte-identical program
output + snapshot bytes**, resting on **native ≡ tier-0 semantic equivalence + H-2 snapshot
JIT-independence** — NOT on identical trace selection. What Part A *must* preserve is (a) the
`accountTraceRun` *selection* inputs are unchanged **per transition** (so a given executed transition
stream selects the same way — the split keeps `hit_count`/coverage identical for the *same* stream),
and (b) no accounting path re-roots a heap object into the `.snapshot` walk (§A7/Q5). It must **not**
promise the stronger "same later traces" property, which native tiering never provided. This is the
honest contract; the 10-mode matrix + keyframe-restore equality is the test, not trace-cache
equality.

**The composite-gap no-yield safe-point hole — RESOLVED as contract (i): synchronous, cooperative
suspend; no new poll (round-1 review, BLOCKER 4).** `skip`'s composite back-edges (`%023 loop`) do
not append to the ledger, so a burst can run millions of native composite back-edges with no forced
yield. The round-1 review established the decisive facts: (1) this is **not unique to edge 4** — the
already-shipped `inner(24)` armed cycle *already* runs unbounded native self-loops (`nativegen.zig:
4498`, a native `.loop` has no poll), so edge 4 introduces no new *class* of hazard; (2) `suspend_ctl`
is only ever set **synchronously** by the replay/suspend driver *before* a run, and is checked only
in the tier-0 instruction prologue (`interp.zig:1820-1847`); (3) **when a suspend is armed,
`safe_to_arm` is false and every link slot is reset before native execution** (`interp.zig:2767`),
so the **cross-trace cycle collapses to dispatcher-mediated native trace entries** — each native
body still runs and dispatcher re-entry still *selects* native (`interp.zig:2772` is unchanged), but
the inter-trace jump no longer fuses, so control returns to the tier-0 dispatcher at each natural
trace exit, where the `suspend_ctl` prologue check fires (round-2 review, R2-4: it does **not**
collapse to tier-0 execution of the *bodies*, only to dispatcher-mediated hops between them). lune
has **no asynchronous preemption requirement** (no signals/interrupts drive `suspend_ctl`
mid-native). Therefore the supported contract is: **suspension is cooperative and
disarm-on-observation is the mechanism** — `safe_to_arm` gates arming and an observation/replay window
resets the outer cycle's slots just as it does `inner(24)`'s. **No back-edge poll is added.** The
residual — a *single* native self-loop body (`inner(24)`'s `.loop`, `nativegen.zig:4498`) can still
spin without reaching a dispatcher exit — is a **pre-existing cooperative-suspension limitation that
edge 4 neither creates nor worsens**, not something disarming fixes. A-viii no longer carries a
back-edge poll; its 2c-F-style disarm test oracle is: after the observation window, **every handoff
link slot is reset to its default AND the dispatcher is reached at the next natural trace exit**
(§A8). If lune ever grows async preemption, a *general* native back-edge budget/poll (for all native
self-loops, not edge 4 alone) is the right design then — out of scope now, recorded as a future note.

##### A8 — Landing sequence (each sub-step: design-confirmed → land behind `just test`, 10-mode byte-identical)

Ordered by dependency; every step before A-vii is **behaviour-neutral** (inert scaffolding), so each is
byte-identical across the 10 modes and provable by negative control:

1. **A-i — GuardProvenance (9-B).** The exit-identity substrate (§A4), incl. the `tropt` remap. Tests
   (2)–(6). No consumer yet ⇒ still byte-identical. (Un-defers task #37.)
2. **A-ii — region discovery + classifier, inert.** `region_defs` built from the trace graph;
   `StructuralEdgeId`/ephemeral cache; the `accountTraceRun`/`accountRegionProfit` split with
   `accountRegionProfit` a **no-op**. Selection unchanged ⇒ byte-identical.
3. **A-iii — `call_seq` plumbing, inert.** `CallFrame.call_seq` + `pushFrameVararg` bump + restore
   re-key. Read by nothing ⇒ byte-identical (a re-record/restore-stability test is the guard).
4. **A-iv — `region_profit` accumulator + window + activation-scoped cleanup + no-cap
   lifetime/cardinality invariant** (§A5 selects an uncapped, activation-lifetime-bounded map with no
   eviction — NOT a fixed cap). Still `accountRegionProfit`-inert (accumulates but does not gate).
   Byte-identical.
5. **A-v — edge-4 bridge stub emission, unarmed.** Generic stubs at every composite candidate
   (§A2.3); nothing armed ⇒ `ordinary_mini` everywhere ⇒ behaviour-identical.
6. **A-vi — native-F2c harness + H-3/H-4 tests** (§A6), incl. the H-5(i) stale-temporary catch.
7. **A-vii — FLIP: arm edge 4 + gate B consumes `region_profit`.** The single behaviour-changing
   step. `accountRegionProfit` now gates; `armNativeLink(.region_bridge)` fires under `safe_to_arm`.
   Measure nsieve honestly (before/after, per-anchor `--jit-stats`); report even if flat.
8. **A-viii — disarm coverage.** Extend the 2c-F disarm test to the **outer** cycle
   (`skip→…→cont→skip`) with a negative control. Oracle (round-3 review, finding 4; NOT "collapse to
   tier-0 bodies" — `interp.zig:2772` still selects native): after the observation/replay window,
   **every handoff link slot is reset to its default AND the dispatcher is reached at the next natural
   trace exit** (the `suspend_ctl` prologue check then fires). The cross-trace cycle collapses to
   dispatcher-mediated native trace entries. **No back-edge poll** (§A7 contract (i): suspension is
   synchronous/cooperative and disarm-on-observation is the supported mechanism, as for `inner(24)`
   today; the lone native self-loop poll-freedom is a pre-existing limitation edge 4 does not worsen).

##### A9 — Review log + residual questions

**Round-1 `gpt-5.6-sol` pre-impl review (2026-07-19) = BLOCKER → all six folded above.** Verified
**sound** and unchanged: H-2 genuinely closed (`.snapshot` walk excludes trace consts,
`keyframeser.zig:270` / split at `interp.zig:1703`; scalar region metadata can't re-root a GC object
unless implementation adds it to the walk — a coding rule, §A7); the edge-4 bridge set `{r2,r3,r6}` +
`skip.ordinary_entry` re-run of tag/table/metatable/lane guards + reload (`nativegen.zig:3699`) is
coherent, including live-through `r2`; `pushFrameVararg` (`interp.zig:1439`) is the single physical
push choke and restore re-key by stack index is sufficient for multiple live recursive frames; the
unarmed A-v stub is state-equivalent. **Folded blockers:** (1) GuardProvenance gains a branch-polarity
discriminator (§A4); (2) the accounting state machine is now complete — per-transition `outer_delta`,
window flush, **region-exit remainder flush as one low-yield window**, canonical sorted-edge-set
`RegionId` (§A3.3/§A3.5); (3) the trace-selection-identity requirement is **retracted** — correctness
is output+snapshot identity via native≡tier-0 + H-2, not trace-cache identity (§A7); (4) the
safepoint hole is resolved as **contract (i)** (synchronous cooperative suspend, no poll; §A7); (5)
H-3 collapses to **option (c)** with a release-enforced ≤1-accumulator-per-`(call_seq, AnchorKey)`
invariant + close-then-replace rule + refreshed cleanup anchors (§A5); (6) H-4 uses a mode-independent
`committed_effect_seq` and the vararg-cursor keyframe gap is resolved as **schema option (a)** (Q6:
add `varargs_base`/`varargs_count` to `FrameRef`, its own foundational-piece ticket before F2c; §A6).
Stale anchors refreshed (`pushFrameVararg` 1439, restore 699, frame pops 2469/2488/2519, suspend
1820-1847).

**Round-2 review — folded (BLOCKER, 6 findings; core re-confirmed sound both rounds):** (R2-1) the
region-exit remainder flushes **only when `r > 0`** (a zero-work `accountRegionProfit(owner,0)` is a
spurious low-yield strike, `trace.zig:1594`); segment work and structural role are **orthogonal per
receipt** (`segment_delta` + `transition_edge`), one `accountRegionProfit` per full-`N` window (§A3.5).
(R2-2) exit detection is a dedicated **`observeRegionProgramPoint(proto_id, pc, depth, call_seq)`** hook
in `nextOp` (`interp.zig:1796`), guarded by "any accumulator live," membership = a **`{proto_id, pc}`**
program-point set (recorded-path union, per round-4 finding 2 — not a static CFG walk); reconciles
§A3.3 (edge identity ⇒ trace transitions) vs the program-point observer (⇒ tier-0 region close). (R2-3) `RegionId` equality is the
**full sorted structural-edge SET**; the 64-bit hash only accelerates the bucket and every hit is
confirmed by set equality (collisions mint a distinct id) (§D.3.2). (R2-4) disarm resets link slots so
the **cross-trace cycle collapses to dispatcher-mediated native trace entries** (not tier-0 bodies;
`interp.zig:2772` still selects native); the lone native self-loop poll-freedom is a **pre-existing
cooperative-suspension limitation** edge 4 neither creates nor worsens; A-viii oracle = all handoff
slots reset + dispatcher reached at next natural trace exit. (R2-5) `committed_effect_seq` has **no
single existing choke point** — a common `onEffectCommitted()` hook is invoked from all four commit
sites (normal `3976`, random-seed `4017`, unicode-pin `4058` w/ `versionAlreadyConsumed` guard, file
read `4089`), *after* per-site validation, in every mode; failed effects don't increment; F-5 tests
every effect family across off/record/replay. (R2-6) P-EBP-2 restated as **normalized-accounting
equivalence over the same logical receipt stream** + output/effect/snapshot identity, not identical
trace discovery.

**Resolved residuals (round-2):**

- **(Q3 — resolved)** `min_useful = 8` stays as the **initial correctness constant** for Part A. Closing
  the region *does* remove a transition and so shifts the true break-even, but the retune is **not**
  driven from nsieve (Rule Z-6): keep `8`, and when A-vii lands **measure the general workload suite**
  to express break-even as a function of measured transition cost; Part B (rel32) revalidates after the
  cheap-transition change. So: not *strictly* Part B, but the measurement/retune is sequenced after
  A-vii on the general suite, never tuned to a single benchmark.
- **(Q6 — resolved, option (a))** Schema-bump `FrameRef` with `varargs_base`/`varargs_count`, landed as
  its **own foundational-piece ticket sequenced before Part A's F2c work** (a pre-existing
  keyframe-completeness gap, same class as `next_obj_id` #27), regenerated via
  `tools/regen-trace-schema.sh` (§A6). Rejected fallback (b) (scope harness to non-vararg frames) —
  leaves the underlying unsoundness.

**Round-3 review — folded (BLOCKER, 4 findings; all consolidation-hygiene, runtime direction
re-confirmed correct):** (1) the collision-safe `RegionId` contract is now IN consolidated §A3.3 (not
just historical D.3.2): interned on the **full sorted `StructuralEdgeId` set** = `{anchor proto/pc,
full GuardProvenance (inline path + role + operand + polarity edge), succ proto/pc}` — **not** the
reduced `(proto,pc,role,edge)` tuple which aliases inline paths / operands / successors; hash
accelerates only; §A3.1 keyed by the interned id; the `polarity` field is now in the declared
`GuardProvenance` struct (§A4). (2) membership is built from **recorded `{proto_id, source_pc}` paths**
captured pre-IR-opt (transient per-trace metadata), unioned across member traces + validated handoff
endpoints — "tier-0 CFG corridors" was not buildable (no canonical CFG in-tree); rebinding confirms
compatible membership or fails closed (§A3.5). (3) receipt **processing order** is now fixed 1–6
(resolve source → add `segment_delta` → flush complete `N` windows → apply `transition_edge` → if it
leaves the active `RegionId`, flush `r>0` remainder + close → open/continue destination), so a receipt
that both credits work and exits doesn't lose terminal work; null events do no state inference, the
`observeRegionProgramPoint` hook detects tier-0 departure; three tests added (§A3.5). (4) three
retracted instructions in the "single contract to build" section corrected to match the folds: A3.2
"one `accountRegionProfit` per burst" → per full `N` window; A-viii "prove collapse to tier-0" →
dispatcher-mediated native entries + slots-reset oracle; A9 round-1 "schema add *or* scope the harness"
→ Q6 option (a). No new runtime-model change; core sound across all three rounds.

**Round-4 review — folded (BLOCKER, 2 findings; recorded-path mechanism confirmed buildable + free of
`tropt` renumbering):** (1) **identity consistency** — `StructuralEdgeId` gains `succ_anchor_proto_id`
(a bare `succ_anchor_pc` aliases successors at the same PC in different protos; an anchor is
`{proto, pc}`, `trace.zig:561`); and one `RegionId` → **exactly one `RegionDef`** (a second is
unrepresentable in `Map(RegionId, RegionDef)` / `RegionKey`), so an incompatible-membership rediscovery
**marks the `RegionId` ambiguous/unarmable and disarms its links**, never mints a second def (§A3.5).
(2) **receipt source-normalization** — the 1–6 order is prefixed with three steps that *establish* the
source accumulator before crediting: classify to exactly one source `RegionId` (zero ⇒ neutral;
multiple + none active ⇒ fail closed), open it if none active, or close the active-but-different one
first (≤1-accumulator invariant) — covering first-entry and A-active/B-source, with two new tests. Core
sound across all four rounds; deltas are now narrow identity/state-machine precision.

**Round-5 review — folded (BLOCKER, 2 findings; both "complete the fail-closed table," no model
change):** (1) **`invalidateRegion(id)` is now a concrete operation** — the physical `NativeLink` has no
region identity (`{parent, slot_index, child}`, `trace.zig:913`; `resetLinksTouching` takes a `*Trace`
not a `RegionId`, `:3380`), so Part-A uses **conservative global teardown**: set `RegionDef.armable =
false` (tombstone, never deleted), flush+drop its `region_profit` entries, `disarmAllLinks()`
(`:3415`), every arm path rechecks `armable` before `armNativeLink`, tombstoned hits are region-neutral.
(2) the source/destination normalization is now a **complete `(active, candidate-set)` table** — every
`{none,A} × {∅, {X}, ∋A, {B}, {≥2}}` pair has a pinned action, incl. the previously-missing "active A,
concrete receipt matches **zero** regions ⇒ close A now (don't wait for the tier-0 hook — a fused native
receipt may precede tier-0)" and "active id wins when candidates include A"; destination has the
symmetric zero/one/multiple rules; null events remain the sole hook-deferred exception. Two more tests
(A-active/zero-candidate, ambiguous multi-candidate). Core sound across all five rounds; the design is
converging on state-machine completeness with no further model changes.

**Round-6 review — folded (BLOCKER, 2 findings; both "define the missing piece," no model change):**
(1) **edge 2 (`ramp/cont.link → inner.linked_entry`) exits through a `.link` terminal, not a guard**
(`trace.zig:498`), so the edge key's provenance is now an **`ExitProvenance` union** `{ guard:
GuardProvenance | link_terminal: {path, source_proto_id, source_pc} }`, the `.link_terminal` variant
stamped where `recForPrepLink` emits the link (neutral polarity, no operand), remapped through the same
side table (§A3.3). (2) **candidate sets are now produced by two reverse indices** —
`edge_source_regions` / `edge_destination_regions` (`StructuralEdgeId → sorted set RegionId`, inverted
from `region_defs` at discovery, tombstoned ids excluded, §A3.1), and the transition phase now operates
on **`?selected_source`** so the previously-undefined **outside→region entry** (zero source candidates,
one destination) has an explicit "open D" row; boundary-entry test (h) added. Core sound across all six
rounds; deltas continue to narrow to missing definitions, not model corrections.

**Round-7 review — folded (BLOCKER, 2 findings; both correct real mechanism transport/definition,
no model change):** (1) **`.link` is synthesized at COMMIT, not at `recForPrepLink`** (which records
`link_target`+`closeTrace`, `trace.zig:5008/5080`; the `.link` is appended at `:3844`, and link traces
**bypass `tropt.optimize`** via duplication, `:3853`), so `.link_terminal` provenance can't be keyed at
`recForPrepLink` — added a **`Recorder.pending_link_provenance`** transport: `recForPrepLink` fills it
(`source_pc = pc−1`), the commit path consumes it when appending `.link` and keys the side table by the
new committed index, `tropt.dupe` copies it, all abort/reset paths clear it (§A3.3). (2) **region
identity and boundary classification are now separated** — a nonzero-work boundary *exit* edge is not
an internal region edge, so inverting only the interned member set gave it zero source candidates and
lost terminal work; the reverse indices are now built over **every committed `StructuralEdgeId`**
(`edge_source_regions[e] ∋ R` iff the producing segment belongs to `R`, incl. leaving edges;
`edge_destination_regions[e] ∋ R` iff `e`'s successor is a validated `R` entry, incl. outside origins),
while **boundary edges stay OUT of the intern set** (§A3.1/§A3.5). Test (i) nonzero-work boundary exit
added. Core sound across all seven rounds; the `(active, candidate-set)`/`?selected_source` tables and
`invalidateRegion` teardown are confirmed exhaustive/coherent given corrected candidate production.

**Round-8 review — folded (BLOCKER, 1 finding; the `.link` transport passed, this is the last
candidate-production correction):** classification must be keyed **physically, not by the logical
`StructuralEdgeId`** — lune runs **sibling traces at one anchor** (`nextTraceExcluding` `trace.zig:2921`,
side-record restart `:3024`, `countTracesAt≥2` `:2178`), and two siblings can converge on the same exit
site + polarity + successor ⇒ the **same boundary `StructuralEdgeId`** while only one physical segment
belongs to `R`; keying on it would credit `R` for a non-member sibling. So `edge_source_regions` →
**`source_exit_regions: ExitKey{Trace.id, exit_instr} → RegionId`** (the receipt resolves its physical
owner before `local`, `trace.zig:2008`), and `edge_destination_regions` → **`dest_entry_regions`** keyed
by the **runtime-selected successor trace** (next ledger `trace_id` / dispatcher child), **deferring
open** until a real successor exists — never `{succ_proto, succ_pc}` alone. `StructuralEdgeId` stays the
**logical** interning/rebind key only. Sibling-trace tests (member credited, non-member neutral) added;
plus the non-blocking `link_target ⇔ pending_link_provenance` pre-append release assert. Core sound
across all eight rounds; the correction was purely the classification key's granularity.

**Round-9 review — folded (BLOCKER, 1 finding; the physical-key blocker resolved, this is the
destination-state correction):** collapsing "no successor selected yet" into destination `∅` was wrong —
`∅` triggers the `S/∅` flush+close, but a cap-yielded / unfused / dispatcher-bound transition, a
full-ledger forced yield (`trace.zig:2015`), or a terminal `.link_terminal` returning to steering
(`:2045`) does **not** exit the region (closing then reopening reduces region accounting toward
per-burst + adds tier-dependent flushes). Destination classification is now **three states** —
`deferred` (retain source, no flush/close; a later selected-child or `observeRegionProgramPoint`
decides), `known(set)` (apply the zero/one/multiple table; `known(∅)` genuinely = successor in no
region ⇒ close), `terminal_outside` (proven exit ⇒ close). Three tests added (j deferred-then-R-member
no flush, k forced-yield survives, l deferred-then-outside closes once). Non-blocking wording:
`.link_terminal` is a concrete **keyed** receipt (`trace.zig:2037`), only prologue-fail/synthetic pass
`null`. Core sound across all nine rounds.

**Round-10 review — APPROVE (2026-07-19).** "The consolidated Part-A contract is now
implementation-ready." The destination state machine is total across `?selected_source × {deferred,
known(set), terminal_outside}`; the physical classification keys (`{owner Trace.id, exit_instr}` source,
runtime-selected-successor destination) prevent sibling cross-crediting and same-anchor destination
aliasing; guard + `.link_terminal` receipts are keyed, prologue-fail/synthetic null-keyed; tests
(a)–(l) make the accounting transition matrix complete. One non-blocking cleanup applied: A-iv "cleanup
+ cap" → "cleanup + no-cap lifetime/cardinality invariant" (§A5 selects an uncapped activation-lifetime
map, no eviction). **This is the Part-A design-approval checkpoint (Bart's cadence boundary).**

### Later — Register-level coherence (defer; measure first)

Only if Increment 2/3 component timings show the flush→memory→reload round-trip
still dominates: a canonical anchor→register assignment (siblings agree by
construction, child skips flush *and* reload) or a ported `asm_head_side`. Note
(peer review): canonical register assignment alone does not discharge the child's
*structural/identity* entry guards — those are separate from value placement and
must still be reconciled.

## Determinism obligations

Exit patching is **native-only** (there is no tier-1a IR to patch), so it fires
only under `--jit-native`. The C5 obligation (doc 16) must be discharged
explicitly — and, per P-F, is **not** free:

- **P-EBP-1 (output invariance).** Patched-native must produce byte-identical
  stdout + effects + keyframe/replay goldens to the tier-0 and tier-1a paths.
  Gated on the 10-mode matrix, plus assertions on link firing, final trace/exit
  identity, cumulative completed count, coherent fallback PC, and heap effects
  firing exactly once — *not* assumed by construction.
- **P-EBP-2 (accounting equivalence, was "mode-invariant timing"; RESTATED — Part-A
  round-2 review, R2-6).** The obligation is **normalized-accounting equivalence over
  the same logical receipt stream, plus output/effect/snapshot identity** — **NOT**
  identical trace *discovery*. Native execution already does not advance the tiering
  tick that tier-0 back-edges do (`trace.zig:3598` vs `nativegen.zig:4498`), so closing
  a region legitimately changes *which* later traces record and *when* — as tier
  selection already differs across the 10 modes. What must hold: (a) the region
  accounting state machine (§A3.5) produces the same penalty/gate/`hit_count` decisions
  for the same *logical* receipt stream regardless of tier (native hop / tier-1a hop /
  unlinked per-segment); (b) byte-identical stdout + effects + keyframe/replay goldens
  (P-EBP-1). Do **not** require an unchanged set/order of recorded traces post-link —
  that property native tiering never provided and Part A does not restore (§A7).
- **P-EBP-3 (replay).** Patching changes control flow, not observable state or the
  order/content of side effects. Confirm against replay goldens *and* assert the
  exec-log surface does not widen; reconcile the exec-log-on tier-1a selection
  (`interp.zig:2567`) explicitly.
- **P-EBP-4 (safe point, was "atomicity").** The real safety argument is a JIT
  safe point where no code on the affected page is executing — not dword-store
  atomicity. Patching runs in the dispatcher after the native call returned, so
  normally no parent activation is live; `mprotect(RW)` briefly makes the page
  non-executable, and lune does not align jump operands (`x64.zig:852`), so do not
  lean on an aligned atomic store. Identify any reentrant JIT-activity path
  (native callback / host hook) that could violate the safe point.

## References

- `docs/design/16-coherent-state-chaining.md` — the chaining mechanism this
  replaces the transition cost of; the nsieve outcome that motivates this doc.
- `docs/design/15-nested-loop-linking.md` — `.link`/exit-PC anchors, side-trace
  recording the parent-guard link builds on.
- `docs/design/05-native-codegen.md`, `09-soa-register-file.md` — the tier-1b
  backend and `regs[]` handoff model.
- LuaJIT: `lj_asm_x86.h` (`asm_exitstub_gen`, `lj_asm_patchexit`),
  `lj_asm.c` (`asm_head_side`, `asm_setup_regsp`), `lj_snap.c`
  (`lj_snap_regspmap`), `lj_trace.c` (`trace_stop` `BC_JMP`, `trace_hotside`),
  `vm_x86.dasc` (`lj_vm_exit_handler`).
