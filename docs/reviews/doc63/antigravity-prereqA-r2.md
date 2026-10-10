# Antigravity — Prerequisite A implementation review (round 2, 2026-10-10)

Verbatim reply. Dispositions in `prereqA-dispositions.md`.

---

# Code Review (Round 2): doc 63 Prerequisite A

**Verdict: APPROVE**

---

### Executive Summary

The round 2 revisions for doc 63 "Prerequisite A" resolve all findings from round 1 comprehensively and with high architectural rigor. 

Specifically:
- **Snapshot liveness & regalloc safety (Finding 1)**: Rather than merely patching string ops, `nativegen_alloc.analyzeInner` now anchors precise snapshot-ref liveness to [`opMayExitInBody`](file:///home/bart/Projects/lune/src/nativegen_alloc.zig#L1630-L1719), which is the closed inventory of every exit possible in native code. Symmetrically, [`requiresPreciseSnapshot`](file:///home/bart/Projects/lune/src/trace_ir.zig#L894-L906) now covers every exit-capable body op across both tier-1a and native, with [`guard_gc`](file:///home/bart/Projects/lune/src/trace_ir.zig#L887-L889) deliberately excluded. Codegen asserts this contract at the precise exit stub via [`std.debug.assert(pins.snap == 0 or opMayExitInBody(...))`](file:///home/bart/Projects/lune/src/nativegen.zig#L2539), and the new regression test [`checkSnapshotLiveness`](file:///home/bart/Projects/lune/src/interp_trace_test.zig#L6958-L6993) verifies regalloc `last_use` across all helpers.
- **Unified native materializer (`mat`)**: Merging the separate `mat_resume` and `mat_err` label arrays into a single per-snapshot materializer that branches to `precise_tail_err` vs `precise_tail_resume` based on `runtime_error` prevents duplicate snapshot flushes from exhausting [`PRECISE_FLUSH_STORE_MAX`](file:///home/bart/Projects/lune/src/nativegen.zig#L2731).
- **Test coverage & witnesses (Findings 2 & 3)**: [`tostr_num`](file:///home/bart/Projects/lune/src/interp_trace_test.zig#L6704-L6713) is now present in `PreciseStrOom.cases`, and [`helperCallPc`](file:///home/bart/Projects/lune/src/interp_trace_test.zig#L6844-L6854) paired with [`raised.at_helper >= 1`](file:///home/bart/Projects/lune/src/interp_trace_test.zig#L6943) provides an unambiguous witness that every individual helper failed and raised at its own callsite. `scap_str` decline and OOM handling have a direct unit test in [`src/stralloc.zig`](file:///home/bart/Projects/lune/src/stralloc.zig#L240-L257).
- **Documentation & TODO accuracy (Finding 4, Codex 3 & 4)**: The stale comment in [`src/irinterp.zig`](file:///home/bart/Projects/lune/src/irinterp.zig#L1458), [`TODO.md`](file:///home/bart/Projects/lune/TODO.md#L181-L200), and [`docs/design/63-trace-host-calls.md`](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md#L30-L45) are all cleanly synchronized.

---

### Verification of Round 1 Fixes

| Round 1 Finding | Status | Verification Detail |
|---|---|---|
| **1. Regalloc snapshot liveness** | **VERIFIED** | [`nativegen_alloc.zig:889`](file:///home/bart/Projects/lune/src/nativegen_alloc.zig#L889) extends liveness whenever `opMayExitInBody(...)` holds for `snap > 0`. [`trace_ir.requiresPreciseSnapshot`](file:///home/bart/Projects/lune/src/trace_ir.zig#L894) covers all exit-capable body ops. Regression test [`PreciseStrOom.checkSnapshotLiveness`](file:///home/bart/Projects/lune/src/interp_trace_test.zig#L6958) checks `last_use[ss.ref] >= i` across all string helper exits in every committed precise trace. |
| **2. Test coverage & `tostr_num`** | **VERIFIED** | `tostr_num` (`tostring(i + 0.5)`) added to [`PreciseStrOom.cases`](file:///home/bart/Projects/lune/src/interp_trace_test.zig#L6704). [`helperCallPc`](file:///home/bart/Projects/lune/src/interp_trace_test.zig#L6844) inspects the bytecode to isolate the helper under test's callsite PC from `new_table` or other setup calls; [`sweep`](file:///home/bart/Projects/lune/src/interp_trace_test.zig#L6915-L6935) enforces `raised.at_helper >= 1` in both tier-1a and native. |
| **3. `scap_str` decline test** | **VERIFIED** | Unit test `doc 45 D5: scapStrRuntime maps stale scratch to decline and an intern OOM to oom` added to [`src/stralloc.zig:240`](file:///home/bart/Projects/lune/src/stralloc.zig#L240-L257). Tests virgin scratch (`subj == 0`) → `.decline`, intern OOM under failing allocator → `.oom`, and successful projection → `.ok`. |
| **4. Stale `irinterp.zig` comment** | **VERIFIED** | Comment at [`src/irinterp.zig:1458`](file:///home/bart/Projects/lune/src/irinterp.zig#L1458-L1461) now accurately documents that nonzero `runtime_error` is set by both `tnew` and string allocating helpers. |
| **Codex 3 / 4: TODO & Doc 63** | **VERIFIED** | [`TODO.md:181-200`](file:///home/bart/Projects/lune/TODO.md#L181-L200) clarifies boundary snapshot presence on ordinary traces vs helper-exit integration. `Outstanding` section in [`docs/design/63-trace-host-calls.md:38`](file:///home/bart/Projects/lune/docs/design/63-trace-host-calls.md#L38) restored, Prerequisite A moved to Done list, and §5.4 updated to past tense. |

---

### Soundness Analysis of New Changes

#### 1. Soundness of Widening `requiresPreciseSnapshot`
We evaluated whether widening [`requiresPreciseSnapshot`](file:///home/bart/Projects/lune/src/trace_ir.zig#L894) could cause [`trace_finalize.zig`](file:///home/bart/Projects/lune/src/trace_finalize.zig#L273), [`nativegen.zig`](file:///home/bart/Projects/lune/src/nativegen.zig#L230), or [`irinterp.zig`](file:///home/bart/Projects/lune/src/irinterp.zig#L1421) to reject or assert on legitimate trace shapes:

- **`trace_finalize.zig:273`**:
  ```zig
  } else if (ir.requiresPreciseSnapshot(ins.op) and i > @as(usize, @intCast(gr))) {
      return error.InvalidSnapshotMetadata;
  }
  ```
  This branch is only taken when `ins.snap == 0` on a precise trace (`rec.precise == true`). In precise mode, [`trace_recorder.zig:1793`](file:///home/bart/Projects/lune/src/trace_recorder.zig#L1793) stamps `ins.snap = self.cur_snap` on *every* body instruction, and `self.cur_snap > 0` is initialized before any body op is recorded. Hence, all body ops carry `snap > 0` and enter the `ins.snap != 0` validation branch; none hit line 273.
- **`nativegen.zig:230`**:
  ```zig
  } else if (trace_ir.requiresPreciseSnapshot(ins.op)) {
      return null;
  }
  ```
  Likewise, this only evaluates when `ins.snap == 0`. In a precise trace, the only ops with `snap == 0` are in the prologue: `slot_load` (forced entry loads) and `guard_gc`. Neither is in `requiresPreciseSnapshot`. All body ops have `snap > 0`. Therefore, native admission does not reject any valid precise trace.
- **`irinterp.zig:1421`**:
  ```zig
  std.debug.assert(trace_ir.requiresPreciseSnapshot(ins.op));
  ```
  This assert fires when an iteration breaks mid-body with `ins.snap > 0`. An exhaustive audit of all `break :iter` exit sites in [`src/irinterp.zig`](file:///home/bart/Projects/lune/src/irinterp.zig) confirms that *every* body instruction capable of exiting (`arith`, `guards`, `alen`, `int_of_float`, `fsqrt/sin/cos/floor/ceil`, `aload/href/hload/uload`, string and pattern helpers, `tnew/tset`) is in `requiresPreciseSnapshot`. The assert holds universally.

#### 2. Isolation of Ordinary Traces
- In [`src/nativegen_alloc.zig:887`](file:///home/bart/Projects/lune/src/nativegen_alloc.zig#L887), snapshot liveness extension is strictly gated:
  ```zig
  if (t.deopt_mode == .precise) { ... }
  ```
  Ordinary traces have `t.deopt_mode == .entry_replay` and empty `snapshots`, so they completely bypass this loop.
- In [`src/nativegen.zig:2534`](file:///home/bart/Projects/lune/src/nativegen.zig#L2534), the precise exit stub (which stores `runtime_error` and branches to `mat`) is guarded by `if (precise)`. Ordinary traces fall through to [`deopt_exit`](file:///home/bart/Projects/lune/src/nativegen.zig#L2747) with `exit_reason = .normal`.
- In [`src/irinterp.zig:228`](file:///home/bart/Projects/lune/src/irinterp.zig#L228), `strFailure` returns 0 for non-precise traces.
- Ordinary traces remain completely unaffected.

---

### Numbered Findings

#### Finding 1: Typo in `requiresPreciseSnapshot` doc comment (`nativeMayExit` vs `opMayExitInBody`)
- **Severity**: LOW (Documentation Nit)
- **File**: [`src/trace_ir.zig:892`](file:///home/bart/Projects/lune/src/trace_ir.zig#L892)
- **Detail**:
  The doc comment for `requiresPreciseSnapshot` states:
  ```zig
  /// and both exit tails assert it: tier-1a's on every precise exit, native's
  /// through `nativegen_alloc.nativeMayExit` (a subset).
  ```
  The function in `nativegen_alloc.zig` (and asserted in `nativegen.zig:2539`) is named `opMayExitInBody`, not `nativeMayExit`.
- **Recommendation**:
  Update the doc comment in [`src/trace_ir.zig:892`](file:///home/bart/Projects/lune/src/trace_ir.zig#L892) to reference `nativegen_alloc.opMayExitInBody`.
