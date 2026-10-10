# Antigravity — Prerequisite A implementation review (round 1, 2026-10-10)

Verbatim reply. Dispositions in `prereqA-dispositions.md`.

---

**APPROVE WITH CHANGES**

### Summary of Assessment
The core design of the `StrResult` ABI protocol and the dual-tail exit dispatch is sound, elegant, and matches the existing `tnew` precise deopt architecture. Returning `StrResult` as a one-word return in `rax` preserves the zero-overhead raw pointer for the success path while cleanly encoding failure ordinals below `@alignOf(object.GcHeader) == 8`. Ordinary (non-precise) traces remain completely unaffected, tier parity between tier-1a and native codegen is achieved, and native store ordering / register discipline is well-conceived.

However, there is **one high-severity register allocation / liveness hole** where allocating string operations were not added to `trace_ir.requiresPreciseSnapshot`, which risks guest register corruption upon exit materialization in native precise traces, plus a few test/documentation gaps.

---

### Numbered Findings

#### Finding 1: `requiresPreciseSnapshot` omits allocating string operations (Regalloc Liveness Hazard)
- **Severity**: HIGH
- **Files**: [`src/trace_ir.zig`](file:///home/bart/Projects/lune/src/trace_ir.zig#L887-L892), [`src/nativegen_alloc.zig`](file:///home/bart/Projects/lune/src/nativegen_alloc.zig#L874-L891), [`src/trace_finalize.zig`](file:///home/bart/Projects/lune/src/trace_finalize.zig#L273), [`src/nativegen.zig`](file:///home/bart/Projects/lune/src/nativegen.zig#L230)
- **Detail**:
  In [`src/nativegen_alloc.zig:885`](file:///home/bart/Projects/lune/src/nativegen_alloc.zig#L885), snapshot reference liveness extension for precise traces specifically relies on `trace_ir.requiresPreciseSnapshot`:
  ```zig
  if (t.deopt_mode == .precise) {
      for (t.instrs, 0..) |ins, i| {
          if (ins.snap == 0 or !trace_ir.requiresPreciseSnapshot(ins.op)) continue;
          const rec = t.snapshots[ins.snap - 1];
          for (t.snapshot_slots[rec.slots_begin..][0..rec.slots_len]) |ss| {
              if (last_use[ss.ref] < i) last_use[ss.ref] = @intCast(i);
          }
      }
  }
  ```
  As documented in [`nativegen_alloc.zig:874-882`](file:///home/bart/Projects/lune/src/nativegen_alloc.zig#L874-L882):
  > *"PRECISE snapshot refs are read by the per-snapshot exit materializers, which `operandReads` cannot see. Extend every captured ref's liveness to each exit that can materialize it — BEFORE any allocation decision — or the flush would read a recycled register/spill."*

  Because [`trace_ir.requiresPreciseSnapshot`](file:///home/bart/Projects/lune/src/trace_ir.zig#L887) only checks `isSideExitGuardOp` and `.tnew, .tset`, `!trace_ir.requiresPreciseSnapshot(ins.op)` evaluates to `true` for all allocating string ops (`.tostr_int`, `.tostr_num`, `.ssub`, etc.). Consequently:
  1. The linear-scan allocator does not extend the liveness of snapshot-held transient values to the string allocation site `i`. Any transient register whose last IR operand read was before `i` can be expired and re-allocated to an intervening calculation.
  2. If the string helper then exits (either on OOM or decline), the precise exit stub jumps to `mat_err` or `mat_resume`, which executes [`emitPreciseSnapshotFlush`](file:///home/bart/Projects/lune/src/nativegen.zig#L719). The flush reads `placeOfRef(alloc, ss.ref)` for the captured slot and flushes clobbered/corrupted data back into the guest register file.
  3. Additionally, [`trace_finalize.zig:273`](file:///home/bart/Projects/lune/src/trace_finalize.zig#L273) and [`nativegen.zig:230`](file:///home/bart/Projects/lune/src/nativegen.zig#L230) fail to enforce fail-closed snapshot validation on string allocating body ops in precise traces, and the invariant asserted in [`irinterp.zig:1438-1441`](file:///home/bart/Projects/lune/src/irinterp.zig#L1438-L1441) (`assert(runtime_error == 0)` if `snap == 0`) assumes `requiresPreciseSnapshot` covers all ops setting `runtime_error != 0`.
- **Recommendation**:
  Update [`requiresPreciseSnapshot`](file:///home/bart/Projects/lune/src/trace_ir.zig#L887) in `src/trace_ir.zig` to include the string allocating operations:
  ```zig
  pub fn requiresPreciseSnapshot(op: IrOp) bool {
      return isSideExitGuardOp(op) or switch (op) {
          .tnew, .tset => true,
          .tostr_int, .tostr_num, .ssub, .srev, .schar1, .srep2, .supper, .slower, .scap_str => true,
          else => false,
      };
  }
  ```

---

#### Finding 2: `tostr_num` is missing from `PreciseStrOom` testing
- **Severity**: MEDIUM
- **Files**: [`src/interp_trace_test.zig`](file:///home/bart/Projects/lune/src/interp_trace_test.zig#L6676-L6945), [`TODO.md`](file:///home/bart/Projects/lune/TODO.md#L170-L178)
- **Detail**:
  `checkTostr` in `PreciseStrOom` runs against `tostr_source`, which converts integer loop index `i` via `tostring(i)` (generating `.tostr_int`). While all seven `snew`/`scap` ops are tested across both tiers in `PreciseStrOom.cases`, `tostr_num` (`stralloc.tostrNumRuntime`) is not present in `cases` or `tostr_source`. Although `tostr_num` shares `tostrScalar` with `tostr_int`, it is an independent IR op with its own native lowering and SysV argument passing (`xmm0` instead of `rsi`).
- **Recommendation**:
  Add a `tostr_num` test case to `PreciseStrOom.cases` (e.g. `tostring(i + 0.5)`).

---

#### Finding 3: `scap_str` decline path (`StaleScratch`) has no direct decline test
- **Severity**: LOW
- **Files**: [`src/interp_trace_test.zig`](file:///home/bart/Projects/lune/src/interp_trace_test.zig#L6947)
- **Detail**:
  [`src/stdlib/string.zig`](file:///home/bart/Projects/lune/src/stdlib/string.zig#L1391) introduces `error.StaleScratch`, which `scapStrRuntime` converts to `.decline`. The decline pipeline test only exercises `schar1` out-of-range codepoints. While `schar1` validates the `.decline` -> `.precise_resume` mechanism end-to-end, `scap_str`'s specific decline branch is unexercised. Given `StaleScratch` is defensive ("never trust the IR"), a direct unit test of `scapStrRuntime` returning `.decline` when `subj == 0` would ensure defense-in-depth coverage.

---

#### Finding 4: Stale comment in `irinterp.zig` regarding `runtime_error`
- **Severity**: LOW
- **Files**: [`src/irinterp.zig`](file:///home/bart/Projects/lune/src/irinterp.zig#L1455-L1457)
- **Detail**:
  Lines 1455–1457 read:
  ```zig
  // `tnew` only exists in precise traces (finalize-asserted), so a shim
  // failure is always folded above — it can never leak out as `.normal`.
  std.debug.assert(runtime_error == 0 or out.exit_reason == .precise_error);
  ```
  With this change, `runtime_error` is also set by string allocating shims. The assertion holds because `strFailure` gates on `t.deopt_mode == .precise`, but the comment still mentions only `tnew`.
- **Recommendation**:
  Update comment to mention that both `tnew` and string allocating helpers gate `runtime_error` on precise traces.

---

### Verification Checklist
- **Protocol Soundness**: PASS. Pointer success always produces `w >= 8`; `Status.out_of_memory` ordinal (1) and `decline` (0) are `< 8`. All 9 allocating helper arms cleanly map to `.ok`, `.oom`, or `.decline`.
- **Native Register Discipline & Store Ordering**: PASS. `emitStrResultCheck` stashes `StrResult` in `rcx` before `emitCalloutRestore`, safely comparing with `fail_limit`. In nativegen precise stub, `movMemImm32` stamps `snapshot_id` and zeroes `runtime_error` in one 64-bit store before the conditional 32-bit `movMemReg32` write on OOM, guaranteeing clean state on both branches.
- **Ordinary Traces Unaffected**: PASS. `strFailure` returns 0 for non-precise traces in tier-1a; native code only executes the precise stub when `precise == true`. Ordinary traces continue to take normal deopt exits without setting `runtime_error`.
- **Tier Parity**: PASS. Exact alignment between tier-1a and native for success, OOM, and decline across all string helpers.
- **Docs & TODO Accuracy**: PASS. `docs/design/63-trace-host-calls.md` and `TODO.md` accurately document the problem, the landed fix, and the open policy question regarding non-precise traces.
