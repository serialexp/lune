# Doc 60 H1 implementation review, round 2 — antigravity

Reviewer: antigravity (`mcp__antigravity__delegate`, tools allowed,
read-only brief), 2026-10-03. Input: `/tmp/h1-r2.diff`, both round-1
reviews, doc 60 §10. Disposition: doc 60 §10.

---

VERDICT: APPROVE

Phase H1 is fully verified in Round 2. All findings from both Round 1 reviews (Codex 1–6 and Antigravity 1–4) have been genuinely and cleanly resolved in the code and design documentation. The expanded differential snapshot, lifecycle synchronization assertions, positive activation fixtures, byte-for-byte artifact comparisons, and documentation updates are sound, robust, and leak-free.

### Verification Summary

1. **Resolution of Round 1 Review Findings**
   - **Codex 1 (Differential snapshot depth)**: Resolved in src/capi_hostcall_test.zig:83-168. `Dump`/`snap` performs alias-aware deep traversal of tables (array elements, hash entries, and metatables) and closures (proto name and upvalues). Upvalues and heap objects share a unified address-to-ordinal mapping (`ids`), which correctly detects aliasing across registers, results, and park lists, and halts cycles immediately. Region activations compare sorted keys and accumulators; open upvalues track cell identity, slot index, and current register value; in-flight recordings compare kind, anchor, constants, and IR; link arm counters and safepoint line indices are compared. The `peek()` host callback captures live mid-call state (including nested reentry), verifying open upvalue cells and table contents mid-execution.
   - **Codex 2 & Antigravity 3 (Lifecycle boundaries & positive fixtures)**: Resolved in src/trace.zig:3079, src/interp_fastblock_test.zig:201-296, and src/capi_hostcall_test.zig:754-826. `TraceState.assertTraceBitsInSync` now actively validates `(fast_block & FastBit.trace_owned) == traceFastBits()` in Debug at recorder start, instruction entry and exit, abort, and close/commit. New tests verify start OOM, commit, mid-record self-abort (`too_long`), and an allocation failure sweep across 143 allocation points. New positive fixtures verify that matching exit, replay, and call anchors actually activate recordings through H1, and that frame-link arm requests with live parents successfully arm native links.
   - **Codex 3 (Suspend check ordering)**: Resolved in src/interp.zig:2069-2077. `pushHostCall` now asserts `self.suspend_ctl == null` before clearing `final_cut` or mutating frames/registers, matching `callValue`'s order.
   - **Codex 4 (Artifact byte-for-byte comparison)**: Resolved in src/capi_hostcall_test.zig:176-196. Serialized effect logs, committed traces, and keyframes are collected as raw byte slices in `Snap.blobs` and compared byte-for-byte via `testing.expectEqualSlices`.
   - **Codex 5 (Measurement conclusions)**: Resolved in doc 60 §5.5. Fast-word test frequency is accurately identified as dispatch-mode selection, the `wide` cycle regression is explicitly qualified as suspected code placement, and timing noise is properly classified.
   - **Codex 6 & Antigravity 1 (Test counts & matrix)**: Resolved in doc 60 Implementation status. Correctly documents 18 scenario tests in `capi_hostcall_test.zig` and 7 tests in `interp_fastblock_test.zig`, moving the embedding record/replay legs to Outstanding.
   - **Antigravity 2 (`suspend_ctl` in fast-word setup)**: Resolved in src/capi_hostcall_test.zig:697-701 with an explanatory comment detailing the precondition assertion.
   - **Antigravity 4 (ReleaseFast testing guidance)**: Resolved in doc 60 Implementation status and TODO.md:5-13.

2. **Analysis of New Changes**
   - **Snapshot Determinism**: Table hash-part iteration via `t.hash.iterator()` visits entries in physical slot order (`nodes[0..mask+1]`). In mahina, `Table.hash` is backed by `hash_part.HashPart` (doc 49), whose layout is a pure function of deterministic `keyHash` (hashing heap objects by stable monotonic `GcHeader.id`, not pointer address) and insertion sequence. Because both legs execute identical operations in lockstep, slot order is completely deterministic. No spurious diffs can arise from slot order.
   - **Harness Memory Management**: Every allocated slice in `Dump`, `snap` (`Snap.text`, `Snap.blobs`, `rows`), and `PeekCtx` has matching `defer` or `errdefer` cleanups on both normal and error paths. All test suites pass cleanly under `std.testing.allocator` with zero leaks.
   - **Assertion Stability**: `assertTraceBitsInSync` accurately masks by `FastBit.trace_owned` to check only trace-owned bits against `traceFastBits()`, ignoring VM-owned bits (`vm_suspend`, `vm_safepoint_lines`).
   - **Test Non-Vacuity**: The positive anchor fixtures verify matching protos and PCs via `recordedAt`, and the arm fixture asserts `ret_cont_link_arms >= 1` and `call_head_link_arms >= 1`.
   - **Gate Verification**: Full test suite passes under Debug (`just test`: 1,600+ unit tests, `capi smoke: OK`, and boundary checks pass); hostcall tests (19/19) and fastblock tests (7/7) pass; Rust crate integration tests pass (27/27).

### Numbered Findings

#### Finding 1 (Nit): Add explicit parentheses around bitwise AND in `assertTraceBitsInSync`
- **File & Line**: src/trace.zig:3080
- **Details**: In Zig, bitwise `&` has higher precedence than `==`, so `a & b == c` correctly parses as `(a & b) == c`. However, for developers and readers accustomed to C precedence rules (where `==` binds tighter than `&`), unparenthesized expressions like this often cause pause or confusion.
- **Suggested Fix**: `std.debug.assert((self.fast_block & FastBit.trace_owned) == self.traceFastBits());`
