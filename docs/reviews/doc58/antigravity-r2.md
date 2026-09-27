# Doc 58 rev 3 (Option B) — design review round 2 (Antigravity, 2026-09-27)

**Verdict: CHANGES REQUESTED.** Dispositions are in doc 58 §8.

Summary of the review (9 findings):

1. **BLOCKER (claimed):** with the anchor at the body start, a coarse
   deopt at the condition guard "re-runs the body a second time on a
   condition that was already false" (example: `while n < 3 do n = n + 1
   end` ends with `n == 4`). Also: doc 56 adapters publish only after
   `hotexit` firings, so the first firings deopt coarsely. Recommended:
   materialize at the post-loop pc from firing 1; B2 cannot land with
   `exit_side_native` off.
2. **BLOCKER (claimed):** peeled traces are refused by exit attach
   (`trace_exit_attach.zig:315`, `trace_shape`), so their condition exit
   is always a coarse deopt, which "re-runs the body". Recommended:
   adapters for peeled parents, or a dedicated loop-exit stub.
3. **MAJOR:** `continuationReachesEnclosingBackEdge` scans FORWARD from
   the post-inner-loop pc; an enclosing `while`'s `loop` op sits at the
   top, behind the scan. The backward `.jmp` at the bottom of the
   enclosing `while` must stay the recognised closer.
4. **MAJOR:** the proposed compiler assertion "every backward jump
   targets a `loop` op" is false for `while` (its backward `jmp`
   targets the condition).
5. **MAJOR:** making every `while` condition guard a plain
   `.branch_cond` makes `isSourceBranchGuardExit` (`trace_link.zig`
   ~760–768) treat the loop's exit as a branch alternation:
   `noteTakenExit` raises `wants_prime_side` and unpatches the anchor's
   entry; the dispatcher's same-anchor sibling chaining
   (`interp.zig` ~4651) runs on loop completion. Keep a distinct
   classification for the loop's own test.
6. **MAJOR:** `linkKindAt(target, back_edge_pc)` tests
   `target <= anchor <= back_edge_pc`; with a `loop` op the header is
   `pc + 1 > pc`, so it can never report `.enclosing_iteration`. Use the
   loop's extent.
7. **MINOR:** B2 cannot pass with the switch off (from finding 1). And
   B1 is not inert if `repeat`'s backward branch moves to the `loop` op
   in B1 (its back-edge target changes). Keep `repeat`'s closer on the
   body in B1.
8. **MINOR:** `forLoopEndFor` exists twice (`trace_region_topology_build.zig`
   ~27, `trace_link.zig` ~827). With `loopExtentFor` returning
   `{start, end}`, the member test at `trace_region_topology_build.zig`
   ~419 must check both bounds: `while` members in the condition
   prefix have `pc < anchor`.
9. **NIT:** `recordingMirrorInstr` already mirrors `.jloop` from
   `proto.code[pc]`; it needs no change.
