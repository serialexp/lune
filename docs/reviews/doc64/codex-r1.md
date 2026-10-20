# Doc 64 review, round 1 — Codex

Verbatim reply to the round-1 review request (read-only review of
`docs/design/64-heavy-iteration-nests.md` at `a161e09` plus the doc).
Codex thread `01a15780-3908-7043-bb13-377b7b245bfc`.

---

Bart, I recommend **2b with explicit outcome accounting, 3b backed by a matching runtime path, and 4a**. For P1, first identify what actually closes the accumulator; if short but productive activations remain, use a corrected deterministic work measure. Targeted teardown, 1d, is worthwhile independently.

The document identifies real policy problems, but several statements need correction before choosing an implementation. This review is based on source inspection; I did not reproduce the reported profiling numbers or run builds/tests. No files were modified.

**Diagnosis: what holds and what needs correcting**

- **P1’s penalty mechanism is real.** Sub-threshold nonzero work strikes; a useful window recovers. Closing an activation that never qualified can therefore penalize its owner, and saturation gates that owner, condemns its provenance, and disarms links. [trace_region_policy.zig:122], [trace_region_policy.zig:237], [trace_regionops.zig:313], [trace_regionops.zig:345]

  **But ledger fullness does not itself close the activation.** A yielded exit-side row publishes its coherent resume PC and returns; deferred destinations retain the accumulator. Actual closure can come from destination classification, source normalization, or a tier-0 program point outside recorded membership. Consequently, “the ledger fills, so every activation closes below eight” is an incomplete causal explanation. Capture the close reason, PC, source/destination classifications, and accumulated work before changing profitability policy. [trace_chain.zig:1924], [trace_region_policy.zig:176], [trace_region_policy.zig:200], [trace_regionops.zig:1555]

  Also, `outer_traversals` is the accumulator’s name, not a guarantee that every credited unit represents its owner’s outer iteration. Replay supplies **one** for `.loop_done_linked`, `local` for `.deopt`, zero for structural rows, and `local + 1` for `.exit_side`. P1 describes a genuine measurement mismatch, but oversimplifies the existing units. [trace_region_policy.zig:135], [trace_chain.zig:1802]

- **P2’s miss accounting is verified, with a materialization caveat.** The router passes only `linked_trace != null`; an attached exit gives up after `tryside` consecutive false results. However, a terminal numeric-for guard does **not** necessarily mean that the candidate committed the post-loop state. Ordinary native deopt leaves the failing iteration for replay; the linked loop-done path explicitly flushes it. The document’s “the loop finished” is true about the observed control-flow condition, but can overstate the committed execution. [interp.zig:4415], [trace_link.zig:648], [nativegen.zig:2696]

  Further, this miss counter measures **routed firings**, not every execution through an armed child. Its sole call site is the router. That distinction matters when interpreting the logs. [interp.zig:4417]

- **P3’s missing runtime route is verified, but 3c already exists.** Candidate lookup is exact-PC, and exit-side chaining additionally rejects anything without a `.link` terminal. Offering traces at header 54 without changing that shape filter would still reject t7. [trace.zig:2496], [trace_chain.zig:308], [trace_chain.zig:349]

  The recorder already resolves a marker’s header, obtains the inner root’s entry contract, and closes eligible continuation recordings with `.link -> header`. This was also present in the cited `2752e6c`. The remaining problem is reaching or replacing old composites, not implementing recorder-to-root linking for the first time. [trace.zig:3530], [trace_recorder.zig:4125], [trace_recorder.zig:4142]

  Rule 8 also does not *choose* the marker as the resume PC. Branch provenance determines the actual successor; rule 8 subsequently rejects header successors. This particular exit resumes at the marker because of its bytecode control flow. [trace_exit_attach.zig:375], [trace_exit_attach.zig:339]

- **P4 is a per-hop reporting problem, not necessarily one row per while trip.** Each exit-side adapter firing contributes a row unless silent. The document itself describes t6 as containing two trips, so “20 trips means 20 t6 hops” needs correction or an accompanying IR dump explaining that count. [trace_chain.zig:1900], [64-heavy-iteration-nests.md:69]

- **The ledger cap is 32, not 23**, both currently and at `2752e6c`. A 23-row burst can be an observation, but cannot be described as reaching `LEDGER_CAP`. [trace_exec.zig:90]

- **The fallback tombstone path still globally disarms.** Option 1c’s parenthetical description is misleading: fallback strike-out calls `invalidateRegion`, and that function calls `disarmAllLinks`. Avoiding global teardown requires changing that path too. [trace_regionops.zig:359], [trace_regionops.zig:512]

There is also a minor kernel-description error: `i < cm` does not guarantee zero while trips. `kidx` retains the previous step’s remainder, then adds `i`; that addition can cross `cm` even for small `i`. [nsieve-bit-fp.lua:17]

**P1: assess work without confusing burst boundaries with region lifetime**

I agree with §7.1’s underlying concern: a small number of enclosing traversals can contain substantial native work. First distinguish legitimate short activations from accidental membership departures. Doc 55 encountered exactly the latter, and deliberately separated arrival membership from bridge-target membership. Broadly extending either map would risk restoring its bad bridge selection. [trace_region_topology_build.zig:800]

- **1a — member iterations:** reasonable and general, **with revised accounting**. Raw `local` is insufficient: it drops the explicit interrupted-iteration credit of exit-side rows and changes numeric-for completion accounting. Define committed work by materialization kind, attribute it to the selected region, and prevent duplicate credit across partial and closing segments. Preserve separate traversal information where lifecycle accounting needs it. [trace_chain.zig:1802], [trace_chain.zig:2017]

  This remains deterministic if based on committed counters. It preserves cold-region retirement when little work actually commits. It must also preserve bounded handling of sustained barren receipts: qualifying once cannot grant permanent immunity. [trace_regionops.zig:1425]

  Change rowed, scalar, and silent accounting together. The silent epilogue currently reproduces the existing per-kind work rules; changing replay alone would make promotion change the policy’s inputs. [nativegen_emit.zig:1363], [trace_chain.zig:1197]

- **1b — evidence of ping-pong:** the deterministic-count version is viable; **the cycle/TSC version is unacceptable**. Measured cycles must remain diagnostics. Also distinguish *guest progress* from *profitability*: a cycle can advance the guest while spending too much effort on transitions.

  My preferred formulation is two explicit protections: bounded consecutive no-progress transitions, plus deterministic work-versus-accounting evidence for promotion retention. There is already a receipts-debit/suppressed-transitions-credit mechanism for fallback regions; assess whether its units can be extended before inventing another payoff ledger. [trace_regionops.zig:1300]

- **1c — remove the owner gate:** viable as an architectural policy change, but I would not select it as the first response to P1. Region retirement and root dispatch eligibility are different concerns, so separating them has merit. Nevertheless, removing the gate without replacing its no-progress protection can retain expensive turnstiles. Existing legacy accounting intentionally gates repeated zero-progress execution while allowing any productive segment to recover. [trace_regionops.zig:83], [trace_regionops.zig:120]

  Tombstoning a genuinely unprofitable region can still retire that region without condemning a healthy root. That is a defensible replacement policy, but it needs explicit semantics rather than being presented as merely deleting the gate.

- **1d — targeted teardown:** recommended independently. The current blast radius is intentional because region identity is incomplete across arm kinds. Make teardown dependency-based: remove arms and promoted sets whose authorization depends on the retired region, including shared dependencies, while preserving unrelated ones. Merely filtering existing `region_id` fields would miss relevant links. Preserve deferred physical mutation during replay. [trace_regionops.zig:289]

For fft, retain the qualified-tail exemption, strict bridge-target membership, and barren-run protection. None should depend on the benchmark’s name or phase sizes. [trace_region_policy.zig:237], [trace_region_topology_build.zig:816], [trace_region_policy.zig:169]

**P2: natural completion is not a failed continuation, but opcode identity is insufficient**

For §7.2, a **proven exit from the relevant enclosing loop** is evidence of a natural stopping condition. It is not automatically evidence that the selected child successfully committed its continuation.

A misfit can hide behind the proposed test if an unrolled loop condition fails because the loop **continues**, rather than ends; if the guard belongs to another loop or inline frame; or if the child rolls back to its entry after doing no committed work. Existing provenance and materialization distinctions must remain authoritative. [trace_exit_attach.zig:359], [trace_chain.zig:1885]

- **2a — reset:** sound only with proof of the relevant loop, failing-edge direction, and meaningful committed service by the candidate. Do not implement it by setting `linked_trace`: that field also selects the child to bind and arm, so it carries a stronger meaning than “do not penalize this outcome.” [interp.zig:4419]

- **2b — neutral:** my preferred immediate policy for a proven natural stop that supplies no positive service evidence. It avoids penalizing legitimate completion without erasing previous failures. If positive service is separately proved, resetting is reasonable.

- **2c — recording failures and entry refusals only:** closest to LuaJIT’s intended growth model, and a sensible eventual direction. It requires a bounded repair path for stale children: try fitting alternatives, rebind, or grow a side trace from the failing child. Simply removing runtime give-ups preserves the `guard_append` misfit R4 was introduced to stop. Existing entry-refusal disarming should remain targeted. [trace_link.zig:638], [trace_chain.zig:2496]

- **2d — expiry:** useful recovery, not a diagnosis fix. Prefer retry after deterministic evidence changes—such as a relevant new root or candidate generation—with bounded backoff and preserved resource budgets. Plain periodic expiry would repeatedly retry unchanged bad children. Today `.gave_up` directly declines exit-side routing. [trace_link.zig:547]

I recommend replacing the boolean policy input with an explicit distinction between **served**, **natural stop**, **entry refusal/misfit**, and **yield**. Attribute service to the candidate being assessed: earlier progress by the parent while root must not indefinitely excuse a child that never fits.

**P3: resolve the entry contract, not just the lookup PC**

The coherence argument is sound for this marker: `.loop` falls through without guest effects, and `loopHeaderOf` maps it to the next instruction. Tier-0’s patched-marker handler uses that same body-start entry. This argument does not generalize to skipping arbitrary loop instructions; generic-for, for example, has control-variable work. [bytecode.zig:215], [bytecode.zig:245], [interp.zig:6313]

- **3a — offer the root:** sound with an explicit marker-to-header entry contract and a root-capable result consumer. **Offering it after composites is insufficient:** a composite can mutate state and return before later candidates are attempted. Prefer a fitting header root before marker composites, with deterministic ordering and a bounded fallback walk. Existing retry logic assumes non-looping continuations; it must not be applied unchanged after a root has completed iterations. [trace_chain.zig:596], [trace_chain.zig:618]

- **3b — direct binding:** my preferred steady-state implementation. Reuse `.exit_side` with a documented extension: its child may be either an exact-PC continuation or an eligible root behind an effect-free marker. Enter the root through its ordinary entry, retaining entry checks and the existing peeled/precise restrictions.

  This needs coordinated changes, not just relaxing the arm predicate. Arming, promotion validation, replay adjacency, cursor resume state, and structural successor discovery currently encode the exact-PC continuation contract. Replay specifically rejects a root at `P + 1`, and later deopt handling requires the published resume to equal the child’s anchor. [trace_link.zig:2073], [trace_link.zig:1122], [trace_chain.zig:1941], [trace_chain.zig:2432], [trace_link.zig:881]

  A shared resolved-target description should distinguish the adapter’s resume PC from the child’s entry PC. That can compose with exit patching without introducing another arm kind.

- **3c — recorder linking:** already implemented. A fresh forwarding continuation is a possible alternative using the existing grammar, but requires deterministic rebinding of stale parents and adds another transition. Retiring all older composites would be unnecessarily broad: other exits may still use them.

- **3d — lift rule 8:** does not solve this marker-PC lookup problem by itself. Nor should it rewrite the actual resume PC merely because a root becomes available. Attachability and resume PC are cached as immutable commit-time facts; conditioning them on subsequent root availability would invalidate that model. Keep snapshot coherence static and target availability dynamic. [trace_code.zig:601], [trace_code.zig:624], [trace_code.zig:651]

**P4: use the looping root first**

- **4a:** yes, provided P3 actually redirects execution to the fitting root ahead of the old composites. Merely making the root discoverable does not establish this. This addresses the measured shape through a general nested-loop entry mechanism.

- **4b:** a legitimate future compiler capability, but **self-target identity is not enough to synthesize an IR loop**. It needs loop-carried values, guards, exact store/snapshot behavior, progress proof, and bounded observation. An adapter-backed self-hop is already a native jump; the proposed improvement would be removing materialization/reporting and rebuilding the loop’s execution contract.

- **4c:** appropriate for productive self-cycles that genuinely remain after P3. Exit-side silent accounting already exists. Diagnose the missing authorization or candidacy evidence before adding machinery. In particular, structural exit-side successor discovery currently excludes same-anchor destinations, although promotion membership can admit an armed edge whose endpoints lie inside an existing region. A standalone self-cycle therefore needs investigation at that structural boundary. [nativegen_emit.zig:1421], [trace_link.zig:881], [trace_link.zig:1253]

If 4c becomes necessary, preserve existing silent budgets, kind-exact evidence, child adjacency, and no-progress protections. Those are what distinguish suppressing redundant reporting from permitting an unbounded JIT livelock. [nativegen_emit.zig:1445], [trace_link.zig:1363]

**LuaJIT comparison**

The document’s central comparison is right, with two qualifications.

LuaJIT penalizes root compilation aborts; it does not reconsider a compiled root because its latest execution contained few outer iterations. Its side-exit hot counter starts recordings, and `hotexit + tryside` limits repeated side compilation attempts before an interpreter-linked trace is produced. Committing a side trace patches its parent’s exit and marks the snapshot DONE. [lj_trace.c:604], [lj_trace.c:798], [lj_record.c:2882], [lj_trace.c:528]

“Permanently patched” should mean **not detached because subsequent execution stops naturally**. LuaJIT still has explicit trace flushing and root unpatching. [lj_trace.c:203], [lj_trace.c:258]

Its nested-loop formation is directly relevant: root recording usually aborts on entering an inner loop, with bounded low-trip unrolling exceptions; side recording links into a compiled root. Mahina already reproduces the recorder portion. [lj_record.c:629], [lj_record.c:660]

LuaJIT’s extra-loop case is narrower than 4b suggests. It checks return to the recording start PC with balanced frame depth, and setup can disable extra-loop formation depending on the parent snapshot. It does not infer a loop merely from parent/child identity. [lj_record.c:665], [lj_record.c:2869]

Its assembler also handles parent register dependencies and restores state at trace links. That is the relevant execution technique to replicate or adapt; removing mahina’s ledger alone would omit mahina’s accounting and replay obligations. [lj_asm.c:1941], [lj_asm.c:2131]

Finally, do not copy LuaJIT’s penalty arithmetic verbatim: it includes PRNG jitter. Mahina should retain counter-derived backoff. [lj_trace.c:392], [trace.zig:3239]

**Recommended order and tests**

1. **Correct the diagnosis and pin the boundaries.** Establish P1’s actual close cause. Test that a cap yield inside a region preserves its key, accumulator, qualification, and penalty; test a genuine departure separately. Include destination-sibling and recorded-membership departures so a doc-55-style classification error cannot masquerade as low profitability.

2. **Implement P2’s explicit outcomes, initially using 2b for unproductive natural stops.** Test enclosing-loop completion beyond `tryside`; distinguish loop-leaving from loop-continuing branch polarity. Include unrelated and inlined loops, unroll-copy guards, entry refusals, genuine stale `guard_append` children, and yields. Assert that earlier parent progress cannot conceal repeated child misfit. Check scalar, fused, and silent execution.

3. **Implement 3b with the corresponding runtime path from 3a.** Use one resolved-entry contract throughout arming, replay, promotion, and topology. Test root-before-composite and composite-before-root formation, including already attached parents. Sweep zero, one, two, three, and long trip counts; test mismatching entry types, peeled/precise roots, child deopt after several iterations, retirement, and observation-window disarming. Assert the root actually fires and the old composite no longer handles each trip.

4. **Remeasure P1; apply corrected 1a only if genuinely productive short activations remain.** Pin few enclosing traversals containing substantial committed inner work, equally short low-work activations, qualified tails, and qualification followed by sustained barren execution. Require matching accounting across rowed and silent paths. Retain fft’s phase-varying butterfly and zero-progress ping-pong as adversarial witnesses.

5. **Implement 1d independently.** Use two unrelated armed nests and a shared-dependency case. Retiring one region must preserve unrelated arms while removing every dependent arm and promotion, including when retirement occurs mid-replay. Cover fallback invalidation too.

6. **Take 4a, then profile again.** If a separate productive self-cycle still pays reporting costs, pursue 4c through existing machinery. Defer 4b until a remaining workload demonstrates the need for compiler loop formation.

For every behavioral change, run the output-equivalence matrix, GC-stress variants, replay/keyframe checks, and deterministic decision-counter comparisons. The existing m=5000 test is insufficient as the sole witness for a problem whose reported topology changes at board size. [interp_exit_side_test.zig:1736]

Performance acceptance should use deliberate benchmarks: independent variable-trip nests, the board-size sieve, fft, and the full suite. Expect root-internal repetition to stop producing one reporting hop per repetition; measure seam work, native residency, allocations, compile cost, and memory as well as wall time. Keep timing thresholds out of behavioral tests.
