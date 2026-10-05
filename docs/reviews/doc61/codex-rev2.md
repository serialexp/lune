# Doc 61 rev 2 — codex review (2026-10-05)

Thread 01a1095f-23da-71a1-8b68-36b2e40d2012. Verdict: **REVISE**. Folded into rev 3.

Rev 2 corrects the disjoint-window model, adds the necessary vararg/open-upvalue aliases, and substantially improves tests and benchmarking. The dynamic-span fix and the marker lifecycle remain incomplete, and Q1 is acknowledged but unresolved.

## Blockers

1. **`dyn_hi` does not protect arguments above `stack_top`.**
   - Dynamic producers write beyond `stack_top` (interp.zig:6708), and the consuming `call` clears the suppression (interp.zig:6374). §2/§4 only visit slots below `stack_top`, so a host callback calling `mh_collect` can lose a live argument in the tail.
   - Re-entry also starts its window at `stack_top`, overwriting that tail (interp.zig:2085). Ordinary Lua calls start at the static caller-window end (interp.zig:6382).
   - The doc needs to specify preservation or relocation, the scanned extent and restoration, not just an alias interval. A suspended Lua call also needs protection even though its marker is false.
   - → Rev 3 §3 P1/P2.
2. **Nested re-entry can flag the same frame.**
   - An opcode invokes a native, the native invokes `callValue`, and a native callee can invoke it again recursively without pushing a frame (interp.zig:2228). An unconditional clear on the inner return drops the outer instruction's protection.
   - Saved state must be restored and tied to the original frame identity. That has to hold across rejected pushes, recursive `__call`, protected unwinds, H1 and the `.S` path, and also for the xpcall unwind (errors.zig:100) and C error unwinds (capi.zig:382).
   - The fields also need initialising in emitted pushes (nativegen_emit.zig:1015) and in assembly (hostcall_x64.S:253).
   - → Rev 3 §4.2.
3. **Operand-register liveness does not cover all native-held values.**
   - `gsub` builds capture strings in a Zig array and calls an arbitrary replacement (string.zig:1473). For a native replacement, `callValue` neither pushes nor parks those arguments, and the C adapter forwards them directly (capi.zig:1109).
   - Also: a native's saved copy of an operand loses its root when a callback rewrites the operand through an open upvalue (interp.zig:7574).
   - → Rev 3 §3 P3.
4. **The static check rejects ordinary multret and lacks a closure-state proof.**
   - `kill(call)` is empty for `c = all_results` (bc_liveness.zig:202), while adjacent multret consumers make the result tail live.
   - "Captured slots closed before the call" needs CFG analysis.
   - Generic-for does emit scope closure before window reuse (compiler.zig:994), but the captured bits are permanent.
   - The check must be enforced in release builds too.
   - → Rev 3 §5.
5. **Conservative soundness is not the same as tier-independent rooting.**
   - The all-live fallback keeps exactly the stale values that motivate the design.
   - Permanent captured bits keep slots alive before their definition and after closure (bc_liveness.zig:21).
   - Faulting frames stay in `frames[0..depth]` during xpcall, so they are not gaps (errors.zig:83).
   - → Rev 3 §2 lemma, §4.4, §5.
6. **Q1 needs a complete lifetime and cost design.**
   - (a) can be sound, since collection happens outside native execution, provided invalidation finishes before baked pointers are freed (nativegen_emit.zig:1975). It must cover the active recorder, dependency-index removal and every dispatch/link reference. Repeated retirement is expensive (trace_link.zig:2379), so it needs batching and a benchmark.
   - (b) must restrict every heap-constant insertion, pattern pins included. Proto constants are rooted only conditionally (interp.zig:2423), so permanence needs an actual pin.
   - → Rev 3 §7.

## Should-fixes

- **Scrub safety and keyframes.** The scrub's safety claim holds only once the blockers are fixed. Define whether capture is rejected while a frame is in flight: frame serialization omits the new state, and restore requires contiguous windows (keyframeser.zig:811). → Rev 3 §6.4.
- **Alias membership.** Specify a linear algorithm. Open-upvalue order is unstable under `swapRemove` (interp.zig:7596). Also, "memory only goes down" ignores the new scratch buffers. → Rev 3 §6.1, §9.
- **Tests and mutations.** Add same-frame nesting, above-top arguments, a native `gsub` replacement that collects, both xpcall-handler outcomes, Q1 invalidation, and maximally fragmented aliases. Land Q1 before masking. → Rev 3 §8.
