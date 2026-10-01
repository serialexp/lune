# codex review — doc 58 B2 (`while`/`repeat` in LuaJIT's `BC_LOOP` shape)

Reviewer: codex CLI 0.159.2, `gpt-6-astra` (its configured default; no model
pinned). Read-only sandbox, 2026-09-30, against the uncommitted working tree on
top of `55137e0`. Prompt: `/tmp/b2-review-prompt.md` (reproduced in doc 58 §5).

Blocker 1 was independently reproduced and root-caused by Claude after the
review — see doc 58 §5 "B2 REVIEW OUTCOME" and `CURRENT_TASK.md`.

---

**Verdict — do not land**

Bart, I reproduced incorrect output with native exit-side linking enabled, and found a dispatcher condition that prevents direct `while` completion exits from becoming exit-side candidates. The marker-based architecture is a general improvement consistent with Z-6/Z-7, but its replacement execution path is not ready. The measured default regression also remains a landing blocker; merely flipping the switch would expose the correctness failure and would still leave FFT slower than baseline.

This was read-only. I inspected the working-tree diff and exercised existing binaries; I did not rebuild or independently rerun the two build gates.

**Findings**

1. **Blocker — native exit-side execution produces incorrect results.**  
   Relevant changed boundary: [trace_exit_attach.zig:346](/home/bart/Projects/lune/src/trace_exit_attach.zig:346), with the corresponding removal of while-copy roles in [trace_recorder.zig:3355](/home/bart/Projects/lune/src/trace_recorder.zig:3355).

   This program reproduces it:

   ```lua
   local s = 0
   for r = 1, 120 do
     local b = false
     local i = 0
     while i < (r % 9 + 3) and s < 100000 do
       b = not b
       i = i + 1
       if b then s = s + i else s = s - i end
     end
   end
   print(s)
   ```

   | Execution mode | Output |
   |---|---:|
   | Tier-0 | `76` |
   | `--trace` | `76` |
   | `--jit-native` | `76` |
   | `--jit-native --jit-exit-side-native` | **`215`** |
   | Same, with `--trace-no-opt` | **`215`** |
   | Existing saved ReleaseSafe B2 binary | **`215`** |

   The existing B0 shadow prints `76` with native exit-side enabled. I did not rebuild that shadow during this review.

   Removing the compound condition removes the divergence; replacing its second operand with `true` preserves it. Debugging shows an unrolled root and exit-side continuations at the short-circuit join.

   **Action:** add this to the mode matrix and isolate the incorrect state transfer across the unrolled guard → native adapter → continuation boundary. I have not established the exact erroneous emitter instruction, so I would not attribute this specifically to `isOwnLoopTest`.

2. **Blocker — direct loop exits cannot warm the replacement exit-side path.**  
   [interp.zig:4434](/home/bart/Projects/lune/src/interp.zig:4434) computes:

   ```zig
   const count_exit = exit_ok and !any_loop_done;
   ```

   Since `any_loop_done` includes `isOwnLoopTestIndex`, direct `while`/`repeat` completion exits never reach `noteTakenExit`.

   But [trace_link.zig:378](/home/bart/Projects/lune/src/trace_link.zig:378) deliberately routes hot exits to exit-side **before** its own-loop-test early return. The dispatcher blocks that intended route upstream.

   Reproduction:

   ```lua
   local s = 0
   for i = 1, 40 do
     local j = 0
     while j < 100 do
       j = j + 1
       s = s + j
     end
   end
   print(s)
   ```

   With `--jit-native --jit-exit-side-native --jit-stats`, I observed 40 native entries, attachable exits with no classification refusals, but **zero wants, records, bindings, adapters, or hops**. Tier-1a likewise never wants the side trace.

   **Action:** let ordinary marker-loop exits reach exit-side hotness accounting. Keep suppression of inappropriate legacy sibling recording in `noteTakenExit`, after exit-side routing. Preserve the separate numeric final-flush classification. Add direct-entry tests that require actual wants and bindings.

3. **Blocker — the deleted low-trip protection has no effective default replacement.**  
   [trace.zig:649](/home/bart/Projects/lune/src/trace.zig:649) still defaults `exit_side_native` to false; [interp.zig:4451](/home/bart/Projects/lune/src/interp.zig:4451) now uses ordinary coarse-deopt handling.

   Moving the marker prevents entry on zero-trip instances. It does **not** eliminate the cost of repeatedly entering a one-trip trace, failing its ending condition before a coarse completion, and replaying that body in tier-0. Removing `.low_trip_while` therefore removes load-bearing protection when exit-side linking is unavailable.

   Your measured +115% low-trip and +75% FFT regressions demonstrate that distinction. With the switch enabled, findings 1–2 and the entry failures below remain.

   **Action:** land the architectural migration together with a correct, effective replacement and its default configuration. Keeping intermediate commits locally is reasonable; shipping this intermediate state is not supported by the measurements.

4. **Should-fix — relocated links repeatedly reach incompatible native entries.**  
   [trace_recorder.zig:3933](/home/bart/Projects/lune/src/trace_recorder.zig:3933) discards `regs`; after finding an inner root, [trace_recorder.zig:3984](/home/bart/Projects/lune/src/trace_recorder.zig:3984) closes the link without an entry-contract check. Compare the explicit `entryGuardsMatch` check in the numeric path at [trace_recorder.zig:3559](/home/bart/Projects/lune/src/trace_recorder.zig:3559).

   In the isolated bit-reverse diagnostic, **6,901 of 6,969 dispatcher bursts ended in prologue failures**. All four minted regions were `armable=true`.

   Moving the link point from the closer to the first body entry changes the available value types: a reset integer can now reach a root specialized for a later floating-point iteration. The unchecked marker link is a concrete suspect for that mismatch, although the exact failing entry guard needs further isolation.

   **Action:** resolve the source-state/destination-entry contract at the general linking boundary. Diagnose the failed guards and arrange a compatible transition; adding promotion exceptions around failing entries would address the symptom.

5. **Should-fix — several rewritten tests no longer establish their advertised behavior.**

   - [interp_tier1a_test.zig:1132](/home/bart/Projects/lune/src/interp_tier1a_test.zig:1132): “ordinary attachable exit” only calls `resumeOf`. It accepts **every refusal except `loop_done`**, despite saying only `no_snapshot` is acceptable. It never requires attachability or attachment, so finding 2 passes unnoticed.
   - [interp_native_test.zig:1727](/home/bart/Projects/lune/src/interp_native_test.zig:1727): the zero-completion **steady-region** regression now exits during run-once. Starting trip 5 with `i=5`, its body increments `i` to 6 and the ending condition immediately fails against bound 6. Use a case such as bound 7 to reach the steady region, and assert the failed guard’s region and zero completion count.
   - [interp_exit_side_test.zig:334](/home/bart/Projects/lune/src/interp_exit_side_test.zig:334): the link-kind oracle now repeats the production `loopExtentFor` containment calculation. An incorrect extent can make implementation and oracle agree.
   - [interp_tier1a_test.zig:1067](/home/bart/Projects/lune/src/interp_tier1a_test.zig:1067): the repeat link check silently skips `null` extents and does not require a link into the repeat root.
   - [interp_exit_side_test.zig:76](/home/bart/Projects/lune/src/interp_exit_side_test.zig:76): `anchors >= 2` permits a continuation to substitute for one of the two intended loop headers. Identify and check those two headers explicitly.
   - The boolean/unrolling tests retain the harness’s `exit_side_native=false` default at [interp_testutil.zig:85](/home/bart/Projects/lune/src/interp_testutil.zig:85). They do not cover the newly enabled native snapshot path implicated by finding 1.

6. **Should-fix — the shared extent helpers do not consistently fail closed on malformed bytecode.**  
   [bytecode.zig:282](/home/bart/Projects/lune/src/bytecode.zig:282):

   - `loopExtentFor` calls the asserting, nonoptional `loopMarkerExit` before validating its result. Negative exit offsets can trap rather than return `null`.
   - The `while` arm validates the closer and its target, but not the condition branch immediately before the marker or that branch’s exit target.
   - The `repeat` arm does not validate its closer at all. A repeat marker with exit `marker + 1` can produce an extent containing only the marker.
   - [bytecode.zig:354](/home/bart/Projects/lune/src/bytecode.zig:354) accepts `header == code.len`, although no instruction exists there.

   **Action:** distinguish trusted compiler assertions from checked structural queries, and add malformed/ambiguous fixtures. I found no corresponding extent error for compiler-generated empty bodies, nested loops, or ordinary `break` placement.

**Answers to the specific questions**

**1. Keep the numeric exemption, but the replacement is not behavior-identical.**

Your objection to deleting the whole exemption is valid: the numeric zero-completion case survives B2.

However, the old numeric predicate explicitly rejects `.loop_test_copy` at [trace.zig:207](/home/bart/Projects/lune/src/trace.zig:207). The new predicate matches every copy. It also requires the test to belong to the trace’s own anchor. Those are observable classification changes.

I would split the policy explicitly:

- Numeric final-test zero-completion exemption.
- Marker-loop zero-completion policy, including a deliberate decision about unrolled copies and unavailable exit-side service.

The second is a new policy decision, not preservation of the old top-condition exemption. It remains reachable; it is not dead code. Permanently exempting zero-work marker-loop entries also needs to be considered alongside the removed yield gate.

**2. No direct resume/snapshot/role writer found, but “refusal-only” is inaccurate.**

The production call graph is:

| Consumer | Transitive effect |
|---|---|
| Dispatcher through `isOwnLoopTestIndex` | Suppresses hotness **and changes receipt `region_work` to 1** |
| `trace_regionops` through the wrapper | Suppresses zero-completion strikes |
| `noteTakenExit` | Stops legacy routing after exit-side routing |
| `isSourceBranchGuardExit` | Gates wants, sibling eligibility, ordinary chain arms and dispatcher chaining |
| Source-branch predicate through `hasArmedSourceBranchLinkAt` | Validates ledger replay; inconsistent rows can panic |

The positive accounting use is [interp.zig:4459](/home/bart/Projects/lune/src/interp.zig:4459). The replay validation is [trace_chain.zig:2226](/home/bart/Projects/lune/src/trace_chain.zig:2226).

I found no call from this classifier into `resumeOf`, snapshot construction, or stored guard-role assignment. Thus matching an early copy does not directly select a wrong resume PC. Nevertheless, its effects exceed “missed opportunity,” and the hotness suppression is already functionally wrong.

The imports in `trace_chain.zig` and `trace_link.zig` of `isOwnLoopTestIndex` are unused.

**7a. B2 should not land separately from its effective replacement.**

A planned default flip does not justify the current regression. Nor is a combined B2-plus-flip sufficient today: switch-on is incorrect on the reproduction, and your FFT result remains approximately **56% slower** than baseline.

This does not argue for restoring the old architecture. It argues for completing the new execution boundary before landing it.

**7b. The bit-reverse evidence points to entry failures, not failed owner election.**

My isolated run reproduced the reported **83.4% / 75.7%** coverage, but its regions were all armable. Its prologue-failure terminals explain why neither promotion route accepts the observed bursts:

- [trace_link.zig:1505](/home/bart/Projects/lune/src/trace_link.zig:1505) requires a full ledger ending in `.yielded`.
- [trace_link.zig:1724](/home/bart/Projects/lune/src/trace_link.zig:1724) requires a short ledger ending in a normal deopt for recurrence promotion.

Prologue failures satisfy neither.

Also, the closed-SCC fallback already exists at [trace_region_topology_build.zig:426](/home/bart/Projects/lune/src/trace_region_topology_build.zig:426). A closed SCC alone does not establish failed election.

Full FFT did mint some unarmable regions as well, so I would not generalize the isolated diagnosis to every FFT region. But failed owner election is not the demonstrated explanation for the relocated bit-reverse cycle.

**7c. The marker overage is real evidence, not an invalid probe artifact.**

Small bodies expose dispatch overhead precisely because they contain little else. They are valid workloads for a general language. Your +5.3%/+4.6% results miss the stated 2% budget.

The real benchmarks make the practical impact less uniform; they do not erase that miss. Repeat interleaved measurements and report absolute cost per iteration alongside percentages. Any budget change is your decision. Performance assertions should remain in benchmarks, not wall-clock unit tests.

**Remaining requested checks**

- **Extent/closer scan:** forward scanning is appropriate for compiler output. Each generated loop owns a distinct closer and exit, so nesting does not create two valid markers for that closer. Malformed bytecode can contain two matching markers; the assertion accepts the first and does not prove uniqueness.
- **Debug-only validation:** reasonable for a compiler invariant over trusted output. Making the current scanner always-on would neither complete its validation nor justify its potentially repeated scans. If external bytecode becomes an input, validate it explicitly at that boundary.
- **Deleted materialization and chain:** the ending condition no longer permits the old top-of-trace `.while_done` shortcut. Removing that special materialization, its coherent-at-zero gate, and its special resume refusal is structurally appropriate. Ordinary snapshots/coarse replay now carry the obligation.
- **Deleted continuation/glue:** exit-side can replace their continuation role, but findings 1–4 show that replacement is incomplete in practice.
- **Deleted yield gate:** not equivalent while the replacement is disabled, starved, or repeatedly failing entry.
- **Deleted while-copy role:** no remaining old materialization consumer needs it, but native materialization of those now-ordinary exits needs substantially better coverage.
- **Dispatch:** `opLoop` retains the guaranteed-tail-call discipline; without tracing it advances to the next instruction. Removing the backward test from `opJump` matches compiler output. The explicit `took` flag in `opJLoop` correctly accommodates a forward marker header.
- **Receipt condition:** `local_done > 0 or linked_one_trip` is appropriate. A zero-completion ordinary while exit must not be treated as committed work merely because it is a loop completion.
- **Panic:** [interp.zig:3693](/home/bart/Projects/lune/src/interp.zig:3693) is **already present in `HEAD`**, not introduced by B2. I found no legitimate nonlinked, missing-resume chain result. Silently resuming at the original PC would risk replaying already committed work.
- **Determinism:** I found no newly introduced clock-, RNG-, or address-based policy decision. Finding 1 already violates execution-mode equivalence; the benchmark parity sweep does not establish the broader guarantee.

**Rewritten-test audit**

These are the 20 runtime test rewrites, excluding the two compiler tests.

| Test | Assessment |
|---|---|
| Boolean two-iteration numeric loop | Retains classification and native-behavior checks. |
| Unrolled while condition copies | Retains coarse-mode checks; misses native exit-side materialization. |
| Period-3 nil/false/true loop | Retains numeric copy/final-test distinction. |
| Bit-reverse coverage | Useful stronger coverage requirement; header identification weakened. |
| Enclosing-iteration link kind | Switch-on is appropriate; shared implementation oracle weakens independence. |
| Post-while continuation reused by wrong-trip exits | Default-threshold change is justified for exercising the intended recording order. |
| While/repeat live entry patches | Faithful migration to marker patch sites. |
| Same-turn prologue-strike unpatch | Faithful migration; retains restoration requirement. |
| Recurring int-entry/float-body peel | Threshold shift preserves intended transition trip. |
| Zero-completion deopt leaves boxes untouched | Threshold shift preserves the intended entry alignment. |
| Run-once integer semantics above `2^53` | Retains its semantic obligation. |
| Reverse float-entry/int-store peel | Threshold shift preserves the transition. |
| Doc 40 phase-0 zero-completion peel | **No longer exercises the claimed steady-region exit.** |
| Reset-to-int glue peel → root peel | Appropriate replacement behavior; no longer demonstrates glue, as expected. |
| While-inner native nest | New arms/fused assertions establish the replacement path with switch-on; default coverage is lost. |
| Repeat anchor/parity | Compiler-shape checks useful; link assertion can be vacuous. |
| Low-trip yield gate → attachable exit | **Does not establish equivalent protection or actual attachment.** |
| Entry-patch resolve/lifecycle fixture | Faithful migration; preserves ambiguity and canonical restoration checks. |
| Entry-patch strike exhaustion fixture | Faithful migration. |
| Exit-attach resume-header/back-edge fixture | Updated numeric back-edge fixture preserves the intended classifier checks. |

Both compiler-test rewrites appropriately check the new marker/header relationship and extents, but do not cover the malformed cases above.

**Inaccurate as-built claims**

- [Doc 58:693](/home/bart/Projects/lune/docs/design/58-while-done-native-link.md:693): “consumers only ever REFUSE” omits positive receipt accounting.
- [Doc 58:716](/home/bart/Projects/lune/docs/design/58-while-done-native-link.md:716): numeric behavior is not unchanged; unrolled-copy treatment differs.
- [Doc 58:791](/home/bart/Projects/lune/docs/design/58-while-done-native-link.md:791): “every 32 rows costs a replay walk” mischaracterizes the observed bit-reverse traffic. Most measured bursts terminated through entry failures, often well before the cap.
- The claim that tests were rewritten without weakening their original obligations is too broad; the low-trip and steady-peel examples above contradict it.
- [Doc 58:5](/home/bart/Projects/lune/docs/design/58-while-done-native-link.md:5) says B2 “landed,” although this is the uncommitted change under review.
- `recLoopLink` still describes the deleted doc-38 `maybeArmContinuation` while path at [trace_recorder.zig:3955](/home/bart/Projects/lune/src/trace_recorder.zig:3955).

I made no file changes and kept your 23 global rules and eight project rules in mind throughout the review.
