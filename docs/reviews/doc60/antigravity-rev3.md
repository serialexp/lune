# Doc 60 rev 3 — antigravity review (2026-10-03)

Reviewer: Antigravity (tools enabled, read-only instruction). No files modified.

Verdict: CHANGES REQUESTED

Revision 3 addresses the bulk of the rev-2 findings: the C-ABI shim signature now correctly receives `box: *VmBox`, `entry_top: usize`, and `entry_depth: u32` (§4.2, §4.3 Step 14); `ChainResult` is returned directly in `%rax` (§4.2); result parking after execution is delegated to an inline loop with a Zig helper fallback (`mahina_hostcall_park_rest`, §4.3 Step 10); the target gate restricts assembly to SysV x86-64 (Linux/macOS) with Windows deferred (§3.1); and the §5.4 coexistence audit confirms that pending trace fields and arms coexist and cannot be replaced with a single tagged union without changing tiering behavior.

However, two soundness blockers remain: an unchecked null `results` pointer causing a segmentation fault when `max_results > 0`, and a direct contradiction between the strict representation rule in §3.2 and the assembly's required slice accesses into the SoA register file and park buffers.

---

### Verification of Rev-2 Findings & Citations

1. **Antigravity B1 / Codex S1 (Null/fatal checks on entry)**: Resolved in §4.1 Layer 1. `mh_call` remains in Zig on all targets and validates `vm orelse return .err_api`, `nresults orelse return .err_api`, `nres.* = 0`, and `checkFatal(box)` (`src/capi.zig:693–696`) before tail-calling `.S`.
2. **Antigravity B2 / Codex B2 (Shim context & signature)**: Resolved in §4.2 and §4.3 Step 14. Signature passes `box: *VmBox`, `cl: *const Closure`, `base: usize`, `entry_top: usize`, and `entry_depth: u32`. `guestFault` (`src/capi.zig:345–359`) receives `box`, `entry_depth`, and `entry_top`, ensuring upvalues spanning surplus vararg arguments (`src/interp.zig:2176–2189`) are closed and stack top is restored cleanly.
3. **Antigravity B3 / Codex B3 (Result parking overflow & OOM semantics)**: Resolved in §4.3 Step 10 and Q10. Assembly parks inline slots; on overflow it invokes `mahina_hostcall_park_rest`, which delegates to `park(box, ...)` (`src/capi.zig:325–335`) and preserves today's non-fatal OOM behavior.
4. **Antigravity S4 / Codex S1 (Symbol visibility & linkage)**: Resolved in §3.1, §4.1, and §4.2. `mh_call` is the sole exported symbol; internal symbols are hidden. Tail-call via `@call(.always_tail, ...)` was verified against the pinned compiler to emit `pop %rbp; jmp`.
5. **Antigravity S5 / Codex B4 (Fast-word sync at recorder and VM boundaries)**: Resolved in §5.4. `syncRecordingBit()` gates `fast_block` updates at the `TraceState` boundary functions without coupling `RecordingSession` (`src/trace_recorder.zig:6150–6508`). `TraceState` resets preserve VM-owned bits (`src/trace_link.zig:2643–2651`).
6. **Antigravity S6 (Pre-commit checks before prologue)**: Resolved in §3.3 and §4.1. Pre-commit checks use scratch registers `rax, r10, r11` and argument registers before executing the SysV prologue, allowing a clean `jmp` to H1 with pristine stack and registers.
7. **Antigravity S7 / Codex S2 (Comptime layout checks on target)**: Resolved in §3.1 and §3.2. Checked only for gated targets.
8. **Codex B1 (`final_cut` and slice representations)**: Partially resolved. `final_cut` clearing was moved to the Zig shim (§4.1), and `code_cache` invalidation uses the plain-`u64` sentinel `code_cache_gen = -1` (`src/interp.zig:403–410`). However, slice access to `tags`, `payloads`, and `parked_results` remains unresolved (see Blocker 2).
9. **Codex S2 (Gate on ABI, frame-pointer unwinding)**: Resolved in §3.1, §3.3, and §6.3. Target is SysV x86-64. Frame-pointer chain and DWARF CFI are enforced.
10. **Codex S3 (Independent stage-1 oracle & artifact coverage)**: Resolved in §6.1. Stage 1 diffs against `fastPathReference()`. Serialized effect logs, committed traces, and keyframes are compared byte-for-byte; park order and multiplicity are tested.

---

### Verification of the §5.4 Non-Exclusivity Audit

The §5.4 audit was verified against the source code and is **correct and complete**:
- **Arm requests outlive recordings**: `pending_ret_cont_arm` (`src/trace.zig:1893–1904`) and `pending_call_head_arm` (`src/interp.zig:3490–3503`) are installed when a hotguard counter crosses threshold and persist until a matching child trace commits in `tryArmFrameLinks` (`src/trace.zig:1906–1925`). Both coexist with `isRecording()` and with each other.
- **Dispatch anchors are not mutually exclusive**:
  - `maybeArmExitSide` (`src/trace_link.zig:231–240`) checks only `pending_exit_anchor` and `pending_replay_anchor`.
  - Continuation arming (`src/trace_link.zig:180–185`) checks neither anchor.
  - Prime-side replay arming (`src/interp.zig:4710–4725`) checks only `pending_replay_anchor`.
  - `onCallEntry` (`src/trace.zig:3383–3417`) and `onRetResume` (`src/trace.zig:3448–3474`) check only `rec.active`.
  - Probe and want transfers (`src/interp.zig:4979–4981`, `:5101–5102`) test only `pending_call_anchor` and `pending_ret_anchor` together.
  - The audit correctly concludes that replacing the 6 fields with a single union would require adding artificial refusals that alter tiering decisions, violating Rule Z-6.

---

### Verification of New Rev-3 Citations

- `lib/std/lang.zig:128` (`doc60:173`): Verified (`pub const c = builtin.target.cCallingConvention().?;`).
- `lib/std/Build/Module.zig:89` (`doc60:184`): Verified (`assembly_with_preprocessor`).
- `lib/std/Build/Module.zig:435` (`doc60:183`): Verified (`pub fn addAssemblyFile(m: *Module, source: LazyPath) void`).
- `src/interp.zig:676` (`doc60:244`): Verified (`final_cut: ?FinalCut = null`).
- `src/interp.zig:402–408` (`doc60:252`): Verified (`code_cache_gen: u64 = CODE_CACHE_GEN_INVALID`).
- `src/interp.zig:2025` (`doc60:312`): Verified (`if (call_seq == std.math.maxInt(u64)) @panic(...)`).
- `src/interp.zig:2486`, `:2652` (`doc60:324`): Verified (`cachedCodeFor` does not set `st.code_gen`).
- `src/wasm_entry.zig:711` (`doc60:598`): Verified (`vm.record_safepoint_lines = true; vm.suspend_ctl = ...`).
- `src/trace_recorder.zig:6077`, `:6144` (`doc60:593`): Verified (`active = false` at 6077, `active = true` at 6144).
- `src/trace_recorder.zig:996`, `:1262` (`doc60:591`): Verified (`active = false` inside `abort` and `finalize`).
- `src/trace_link.zig:2643–2651` (`doc60:602`): Verified (`clearCache` clears pending anchors and arms).
- `include/mahina.h:149` (`doc60:786`): Verified (`mh_call` prototype).

---

### BLOCKERS

#### 1. Unchecked null `results` pointer causes SIGSEGV on host calls with `results == NULL, max_results > 0`
- **Evidence:** doc60:288–292, :425–426, :680; `src/capi.zig:681–686, :692–705`.
- **Details:** In `src/capi.zig:681–686`, `resultsSlice` handles nullable output buffers:
  ```zig
  fn resultsSlice(results: ?[*]mh_value, max: usize) []Value {
      if (max == 0) return &.{};
      const p = results orelse return &.{};
      const vp: [*]Value = @ptrCast(p);
      return vp[0..max];
  }
  ```
  If an embedder passes `results = NULL, max_results = 5`, today's implementation safely treats it as an empty slice of length 0 (`produced = 0`), writes nothing to `results`, and returns `MH_OK` with `*nresults = 0`.
  In rev 3:
  1. Layer 1 (`mh_call`, doc60:288–292) checks only `vm` and `nresults` before tail-calling `.S`. It does not clamp `max_results = 0` when `results == null`.
  2. Layer 2 pre-commit checks (doc60:303–315) do not validate `results`.
  3. Step 8 (doc60:425) states: *"8. Copy the results out, `min(count, max_results)` of them, word-wise (`storeWords`)."*
  If the callee returns >= 1 result, `min(count, max_results)` is >= 1, and the assembly immediately executes a store to `results[0]` (`(%r9)`), which is NULL (`0x0`), causing an immediate `SIGSEGV`.
  Furthermore, §6.1 line 680 explicitly mandates testing `"null vm/args/results/nresults pointers"`. This test case will crash the `.S` entry.
- **Required Fix:** In Layer 1 (`mh_call` in `capi.zig`), normalize `max_results` before tail-calling `.S`:
  ```zig
  const effective_max = if (results == null) 0 else max_results;
  return @call(.always_tail, mahina_hostcall_entry, .{ box, callee, args, nargs, results, effective_max, nres });
  ```
  Or have the `.S` pre-commit checks reject `results == null && max_results > 0` to H1.

#### 2. The assembly contract contradicts its representation boundary regarding slice access to the register file and park buffers
- **Evidence:** doc60:234–243, :401–403, :425–426; `src/interp.zig:573–574, :803–805, :1067–1076`.
- **Details:** §3.2 lines 234–242 establishes the representation rule:
  > *"The `.S` code reads and writes only plain integers, pointers and the two words of a Value. It never writes or interprets: an optional; an error union; a tagged union; **a slice**; a packed struct (other than reading the fast word as a u16)."*

  Yet `Vm` stores its register stack as Structure-of-Arrays slices (`tags: []u8`, `payloads: []u64`, `src/interp.zig:573–574`), and its park overflow buffer in an `ArrayList` (`parked_results: std.ArrayList(Value)`, `src/interp.zig:803`, which contains `items: []Value`).
  To bind arguments (Step 4), nil-fill registers (Step 4), copy results out (Step 8), or clear the park when idle (Step 1), the `.S` code MUST:
  1. Load `vm.tags.ptr` (interpreting slice `[]u8` as `{ ptr: [*]u8, len: usize }`).
  2. Load `vm.payloads.ptr` (interpreting slice `[]u64` as `{ ptr: [*]u64, len: usize }`).
  3. Clear `vm.parked_results.items.len = 0` (interpreting `items: []Value` in `ArrayList`).

  In Zig, slices are language primitives, not `extern struct`s; `@offsetOf([]u8, "ptr")` is a compile error (`error: expected struct type, found '[]u8'`), so the target offsets checker cannot verify field offsets of a slice directly.
- **Required Fix:** Either:
  - (A) Explicitly amend the representation rule in §3.2 to allow reading slice pointers for `tags` and `payloads`, and add a comptime check in the target offsets checker asserting that for `[]u8` and `[]u64`, `ptr` is at offset 0 and size is 16 bytes; OR
  - (B) Store explicit pointer fields on `Vm` (`tags_ptr: [*]u8`, `payloads_ptr: [*]u64`), so that `.S` reads plain pointers and strictly satisfies the representation rule without touching slice metadata.

---

### SHOULD-FIX

#### 1. `produced` is undefined in §4.3 Step 8 and creates buffer overflow ambiguity in Steps 10 and 11
- **Evidence:** doc60:425–440; `src/capi.zig:394, :401, :406`, `src/interp.zig:2208–2214`.
- **Details:** Step 8 specifies: *"8. Copy the results out, `min(count, max_results)` of them, word-wise (`storeWords`)."* Then Step 10 references `produced` in `mahina_hostcall_park_rest(box, results, i, produced)`, and Step 11 sets `*nresults = produced`.
  `produced` is never formally defined in Step 8. In `interp.zig:2208`, `callValue` returns `n = @min(fr.count, results_out.len)`, which `capi.zig:401` captures as `produced`. If an assembly implementer interprets `produced` as the callee's total result count (`count` / `fr.count`) rather than `@min(count, max_results)`:
  1. Step 10 will park `results[0..count]` (reading unmapped/unallocated memory past `max_results`).
  2. Step 11 will report `*nresults = count`, violating the buffer capacity contract in `mahina.h:145`.
- **Recommendation:** In Step 8, explicitly define: `"Let produced = min(count, max_results); copy produced results out..."`.

#### 2. `mahina_hostcall_park_rest` signature takes non-optional `[*]const mh_value`
- **Evidence:** doc60:356–357; `src/capi.zig:683, :692`.
- **Details:** The proposed signature in §4.2 is:
  ```zig
  fn mahina_hostcall_park_rest(box: *VmBox, results: [*]const mh_value,
                               from: usize, count: usize) callconv(.c) mh_status;
  ```
  In Zig, `[*]const mh_value` is a non-null many-item pointer. If a call has `results == null` (which is valid when `max_results == 0`), passing `null` to `[*]const mh_value` is undefined behavior / illegal in Zig.
- **Recommendation:** Change the signature to `results: ?[*]const mh_value` (or `?[*]const Value`).

#### 3. Contradiction between §4.1 pre-commit check and §5.1 / §5.3 straight-line arg limit
- **Evidence:** doc60:309, :471, :518.
- **Details:** §4.1 line 309 lists `"the arg count vs a small straight-line limit"` under pre-commit checks, where any failure triggers fallback to H1 (`jmp mahina_hostcall_slow`).
  Conversely, §5.1 line 471 specifies: `"straight-line up to the small limit, loop beyond"`, and §5.3 line 518 includes `"beyond the straight-line limit"` in the ledger shapes.
  If `.S` falls back to H1 when `nargs > limit`, then `.S` does not loop beyond the limit. If `.S` loops beyond the limit, `nargs > limit` is not a pre-commit fallback trigger.
- **Recommendation:** Clarify whether `nargs > STRAIGHT_LINE_LIMIT` falls back to H1 or loops in `.S`, and define the numeric value of `STRAIGHT_LINE_LIMIT`.

#### 4. Missing explicit `args != null` pre-commit check when `nargs > 0`
- **Evidence:** doc60:308; `src/capi.zig:711`.
- **Details:** §4.1 line 308 lists checking `"each argument's tag, and its non-null heap pointer"`. If `args == null` and `nargs > 0`, attempting to load `args[0]` before verifying `args != null` (`test %rcx, %rcx; jz fallback`) will segfault in assembly before reaching H1.
- **Recommendation:** Explicitly document `test %rcx, %rcx; jz fallback` when `nargs > 0` as part of the pre-commit checks.

---

### NITS

1. **Assembly entry symbol omitted from §4.2 code block**: §4.2 notes: *"All four symbols are hidden. `mh_call` is the only exported one."* But the code block in §4.2 lists only three symbols (`mahina_hostcall_slow`, `mahina_hostcall_chain`, `mahina_hostcall_park_rest`). The assembly entry symbol called by `mh_call` (e.g. `extern fn mahina_hostcall_fast(...) callconv(.c) mh_status;`) should be declared in the block.
2. **Debug rejection scratch field ownership and lifecycle**: §5.4 states: *"The .S entry records the rejection reason in a debug-only scratch field."* Specify which struct owns this field (`VmBox.debug_fast_block_rejection`), ensure it is reset to `.none` after assertion in `mahina_hostcall_slow` to prevent stale checks on subsequent calls, and confirm it is compiled only in Debug builds.
3. **Reentry limit constant identifier in §3.2**: §3.2 lists `"the reentry limit"`. In `src/interp.zig:139`, the identifier is `max_native_reentry`. Using the exact identifier avoids ambiguity with `max_call_depth`.
