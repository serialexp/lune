# Doc 60 H1 implementation review — codex

Reviewer: codex (`mcp__codex__delegate`, Codex default model), 2026-10-03.
Input: the uncommitted H1 tree, `/tmp/h1.diff`, doc 60 with §5.5.
Disposition of each finding: doc 60 §10, "H1 review".

---

VERDICT: CHANGES REQUESTED

1. **Major — The differential snapshot does not establish the equivalence promised by §6.1.** src/capi_hostcall_test.zig:90, :131, :138.

   Heap normalization includes content only for strings. Two different returned tables can both become `h0:table`; two closures with different captured values can both become `h0:function`. Keyframes do not close this gap because parked values are excluded from snapshot roots. Region activations are compared only by count, open upvalues only by register index, and active recorder state only by its anchor. Incorrect accumulator contents, upvalue cells, or partial recordings can therefore compare equal.

   **Suggested fix:** normalize tables and closures with cycle-safe content and alias tracking shared across guest roots, results, and parks. Compare region activation keys and accumulator fields, upvalue identity/location/value, and meaningful active-recorder state. Add fixtures returning fresh tables and capturing closures, plus observations during reentry while those states are live.

2. **Major — The fast-block verification misses important lifecycle boundaries and successful hook activation.** src/interp_fastblock_test.zig:66, src/capi_hostcall_test.zig:570, src/trace.zig:3920.

   The four mutation tests cover successful starts, explicit aborts, setters, and several consumers. They do not check the word immediately after recorder-start OOM, recorder self-abort through `recordInstr`, or successful/failed close and finalization. Those synchronization sites are central to avoiding skipped hooks in ReleaseFast.

   The host-entry fixtures use the prior eval's proto, unreachable PC `9999`, mismatched activation sequences, and nonexistent parent trace IDs. They exercise waiting, discard, and abort paths, but do not establish that matching anchors activate or valid frame-link requests arm through H1.

   **Suggested fix:** add exact-word checks after each missing lifecycle outcome, preserving unrelated bits. Add matching anchor and valid-parent fixtures with assertions that the intended recording or arm actually occurred. Compare `safepoint_lines` for the line-recording case.

3. **Minor — Suspension changes rejection ordering despite the "same checks" claim.** src/interp.zig:2123, :2148, :2205.

   `callValue` asserts that suspension is disarmed before clearing `final_cut` or checking reentry. H1 checks suspension only after binding and pushing. With suspension armed and a limit already reached, H1 returns `StackOverflow` where the reference asserts; otherwise H1 mutates registers, frames, and `next_call_seq` before asserting. Suspension is an unsupported host-call precondition, so this does not establish a supported-path regression, but literal error-order equivalence is false.

   **Suggested fix:** assert `suspend_ctl == null` in `pushHostCall` before clearing `final_cut`; retain the runner assertion for future H3 callers.

4. **Minor — Serialized artifacts are compared by hash, not byte for byte.** src/capi_hostcall_test.zig:109, docs/design/60-hand-written-machine-code.md:1056.

   Effect logs, committed traces, and keyframes contribute only their length and Wyhash digest to the comparison. That is useful evidence, but it is weaker than the stated byte-identical check and gives poor diagnostics.

   **Suggested fix:** compare the serialized byte slices directly; retain hashes as diagnostic summaries if useful.

5. **Minor — §5.5 overstates the measurement conclusions.** docs/design/60-hand-written-machine-code.md:994, :1013, src/interp.zig:7019.

   The fast-word predicate is a dispatch-mode selection check, not a per-bytecode check. Also, unchanged instruction counts and five timing repetitions do not establish that every ±2–4% timing delta was noise. Byte-identical handlers at different addresses support a placement hypothesis; they do not isolate placement or branch aliasing as the cause.

   **Suggested fix:** correct the execution-frequency description and qualify the conclusions: no aggregate timing regression was resolved by these measurements, and placement is the suspected explanation for `wide`.

   The ledger's instruction reductions are supported: rerunning the saved measurement script reproduced all twelve counts exactly. `wide` remained slower, by approximately 1.7% in my run.

6. **Minor — The status text overstates current test coverage.** docs/design/60-hand-written-machine-code.md:61, :1058.

   There are **15 scenario tests**, plus the import test, producing 16 reported tests. The claimed embedding record/replay matrix is not implemented; the test module explicitly acknowledges that omission. The additional verification gaps above are absent from Outstanding.

   **Suggested fix:** correct the count and matrix, and distinguish completed H1 implementation from outstanding equivalence coverage.

I found no missed production setter or supported-path regression in the source audit. The flat setters, initialization without recomputation, reuse of `execWithEntry`, inlining, and skip-if-unchanged volatile word store appear sound.

Validation: 1,606 Debug tests passed; the ReleaseFast host-call and fast-block tests passed; dependency checks passed.
