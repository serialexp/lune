# Doc 60 §5.6 + H1.5 review — antigravity

Reviewer: antigravity (`mcp__antigravity__delegate`, tools allowed,
read-only brief), 2026-10-04. Input: `/tmp/h15.diff`. Disposition: doc 60
§10.

---

VERDICT: APPROVE

### Summary of Soundness & Invariant Checks
1. **Change A (`Vm.bindAndPushClosure`, src/interp.zig:2080-2095):**
   - **Aliasing:** Completely sound. `args` is `[]const Value` (AoS, 16-byte structs) provided by the caller, while `w` accesses `self.tags` (`u8`) and `self.payloads` (`u64`) located at `cb = self.stack_top`. The new window resides strictly above active stack frames, so writes through `w` cannot alias `args` or the proto's fields. Hoisting `w` and `nreg` eliminates repeated reloads of the slice headers and `cp.num_registers`.
   - **Bounds:** Guaranteed `np = @min(cp.num_params, args.len) <= cp.num_registers = nreg`. Slices and loops handle `nreg == 0` gracefully without out-of-bounds access.

2. **Change B (`callClosure`, src/capi.zig:755-768):**
   - **GC Rooting:** Registers are read via `w.get(k)` while `vm.stack_top` is still raised over the returned frame's window. `park()` allocates only via GPA (`vm.gpa`) or inline array slots—it never triggers VM garbage collection. Even if a collection were possible, all result registers remain rooted on the stack until after the loop.
   - **Stack Restoration & OOM Semantics:** `vm.stack_top = entry_top` executes unconditionally after the loop, properly restoring `stack_top` on both success and `status == .err_oom` break. `*nresults` remains `0` on OOM (set at `mh_call` entry), matching `runProtected`'s contract where `results[*nresults..]` are undefined per include/mahina.h:145-147.
   - **Park Ordering:** Results are parked in identical ascending index order `0..produced` as in `runProtected`. All differential tests in src/capi_hostcall_test.zig pass.

3. **Change C (`clearPendingExitAnchor`, src/trace_link.zig:258-262):**
   - **Invariant Verification:** An exhaustive sweep across the codebase confirms:
     - `pending_exit_src` is written non-null *only* at `trace_link.zig:248`, immediately following `setPendingExitAnchor(key)`. It is cleared whenever `pending_exit_anchor` is cleared (`maybeStartContinuation:203`, `clearPendingExitAnchor:264`, `clearCache:2655`).
     - `pending_replay_src` is written non-null *only* at `trace.zig:3333` and `interp.zig:4811`, in both cases immediately following `setPendingReplayAnchor(...)`. It is cleared whenever `pending_replay_anchor` is cleared (`maybeStartReplaySide:298`, `clearPendingExitAnchor:266`, `clearCache:2657`).
     - `FastBit.exit_anchor` and `FastBit.replay_anchor` mirror their respective anchor pointers in lockstep through the setters.
     - Therefore, `(fast_block & (exit_anchor | replay_anchor)) == 0` strictly guarantees that both anchor pointers and both source fields are `null`. The debug assertion is sound.

4. **Doc Accuracy (§5.6, docs/design/60-hand-written-machine-code.md:1067-1200):**
   - The stage breakdown, instruction counts, callgrind methodology, and deltas match the baseline measurements from §5.5 and §5.3.
   - The trade-off for A (vectorized 8-wide nil-fill on wide frames vs register pressure and setup on 1-register frames) is clearly reasoned and complies with Rule Z-6.

---

### Findings

1. **Nit — Idiomatic nil setter on `RegWindow`**
   - **File & Line:** src/interp.zig:2093
   - **Details:** The loop nil-fills using `w.set(i, Value.nil())`. `RegWindow` already exposes a dedicated helper `w.setNil(i)` (src/regwindow.zig:98) which directly sets `tags[slot] = @intFromEnum(Tag.nil)` and `payloads[slot] = 0`. While LLVM inlines both to identical stores in ReleaseFast, `setNil` is more idiomatic for `RegWindow` usage.
   - **Suggested Fix:** Optionally replace `w.set(i, Value.nil());` with `w.setNil(i);`.
