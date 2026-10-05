# Doc 61 rev 3 — codex review (2026-10-05)

Thread 01a1096c-37fe-77f0-8e3f-441ba5942d46. Verdict: **REVISE**. Folded into rev 4.

## Blockers

1. **Gating the watermark on `maskable` is insufficient.** The watermark drops slots `>= base+4` by lexical position, which includes a register a later captured local reuses. Captured bits are live at every pc, so that φ is not dead anywhere. → Rev 4 retires the watermark in Phase 2 and, until then, also requires "not captured" (§2, §5).
2. **Nested `xpcall` breaks the single Vm fault range.** A handler that runs its own protected call with a handler creates a second fault region, and one `[fault_lo, fault_hi)` cannot describe both. → Rev 4 drops the range (§4.4).
3. **The ∅ mask for faulting frames is unsafe.** `describeFault` reads the top faulting frame's operands. A non-catchable fault inside the handler propagates with those frames live to capi `guestFault → renderFault` (`capi.zig:384`, `:405`) or the CLI reporter (`interp.zig:1925`). → Rev 4 marks the topmost faulting frame in flight with save/restore; its mask `live_in[fault pc]` keeps the operands (§4.4).
4. **P2 needs a restoration owner.** On success, restore after the result copy. On failure, leave `stack_top` raised until the catcher discards the frames, after diagnostics and upvalue closing. Cover rejected pushes and non-catchable propagation. → Rev 4 §3 P2.
5. **The P3 audit is too narrow.** It must cover every arbitrary-code/re-entry boundary, including the interpreter's metamethod paths (`interp.zig:7106`, `:7436`). It must cover saved callees, slices and partial result buffers, with balanced restoration on every exit. → Rev 4 §3 P3.
6. **Keyframe exclusion must be enforced in release.** `encodeSnapshot` (`keyframeser.zig:279`) must reject capture during in-flight or native-activation state. → Rev 4 P4, §6.4.

## Should-fixes

- **P1 scope.** It applies only to the opcode path and the native inline push. `callValue` and `.S` already place surplus arguments below the callee (`interp.zig:2105`, `hostcall_x64.S:300`). Restore should validate ordered, non-overlapping, bounded windows rather than add gap data. → Rev 4 §3 P1.
- **Tests.** Add:
  - captured-slot watermark omission;
  - nested faults;
  - handler-side C reporting after GC;
  - release capture rejection.

  → Rev 4 §8.
