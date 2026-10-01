# Doc 58 §4.8 review — closed-SCC multi-root owner election (codex, 2026-10-01)

Reviewer: codex (default model `gpt-6.1-sol`, read-only, no files changed).
Thread: 01a0f4f3-2ecf-7303-bd69-92d4e829c259.
Subject: doc 58 §4.8 (rev 1), proposing gate dominance as the tie-break when
Increment B's closed-SCC fallback tier finds two or more qualifying roots.

**Verdict: APPROVE WITH CHANGES.**

Gate dominance is a sound, conservative way to resolve the policy
ambiguity. The saved evidence supports owner election as fft's remaining
transform-loop bottleneck, and no new downstream correctness violation was
found.

1. **BLOCKER — the adversarial performance claim is unsupported.** O(k·n) is
   fine for two roots in a small proto, but "64k instructions → microseconds
   per rebuild" does not follow: neither the qualifier count nor the trace
   count has the assumed small bound. `max_traces_per_anchor` bounds
   siblings, not anchors. With k growing with n, the cost is quadratic per
   rebuild, and rebuilds repeat as traces commit and admission rebuilds
   topology.
   - Run a release benchmark at the rebuild boundary, varying n and k and
     including repeated rebuilds.
   - If large-k behaviour is unacceptable, compute a dominator tree once
     and answer queries from it.
   - Scratch belongs locally in `build`: lazily allocate it from the
     injected allocator, reuse it across roots and candidates, and free it
     on every return. No per-node allocation and no queue-front removal.
2. **SHOULD-FIX — make dominance non-vacuous and fail closed.**
   - An originally unreachable member stays unreachable whatever gate is
     removed, so the test treats dead membership as evidence. Establish
     baseline reachability first: the gate, its header and every member
     must be reachable and in bounds. Pin refusal in a test.
   - `loopExtentFor` calls the asserting `loopMarkerExit`, and repeat
     validation is incomplete. Either document a trusted-compiler
     precondition or use checked queries.
   - A malformed jump target that becomes a null successor must not
     silently manufacture a dominance proof.
3. **SHOULD-FIX — separate the structural diagnosis from logging-inflated
   timings.** The diagnosis holds: `.yielded` proves an armed target was
   suppressed by the ledger cap, and the four-anchor region flips to
   armable and promotes, with problematic yields falling 17,599 → 229. But
   the 82.5% seam figure and 284 → 73 ms include live debug printing
   (~675k vs ~83k log lines). Cite the non-logging board (325.3 → 178.0 ms)
   and non-logging `--jit-stats`.
4. **SHOULD-FIX — test the lifecycle, not just minting.**
   - Pin for the multi-root case: same-id rebind stability,
     primary↔fallback transitions, loss of unique election, sticky
     tombstones, proof invalidation, and input-order permutations for
     determinism.
   - Replace the malformed synthetic ambiguity fixture with valid
     compiler-shaped CFGs.
   - The integration test must require the expected owner,
     `fallback_owner`, admission, promotion and cross-mode output
     equivalence.
5. **MINOR — dominance is a tie-break, not a universal owner requirement.**
   - Gate choices are confirmed against the compiler: `for_prep` jumps
     straight to `for_loop`; generic entry reaches `tfor_loop` before the
     body; while and repeat entry pass the marker.
   - Keep the single-qualifier rule: a legitimate continuation can
     precede the sole root's gate on initial entry.
   - Choose the single-root vs multi-root path by the *original*
     structural qualifier count. Filtering out roots with no gate must not
     collapse an ambiguous case into the single-qualifier shortcut.
6. **MINOR — owner responsibilities and the fft regions.**
   - The owner also participates in `openCollision`.
   - It is not RegionId identity: internal structural edges determine
     identity.
   - Region 4 (three anchors) stays unarmable even under the experiment.
     The multi-root fix is region 5 (four anchors).
7. **MINOR — sharper reasoning for the rejected alternatives.**
   - Lowest pc is deterministic and not shown unsound. Its cost is
     arbitrary attribution and admitting more ambiguous shapes.
   - An owner set adds lifecycle complexity with no established benefit.
   - A non-member enclosing owner changes the representative contract and
     still needs a selection rule.
