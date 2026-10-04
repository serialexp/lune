# Antigravity — doc 60 H2 implementation review (2026-10-04)

**VERDICT: APPROVE**

---

### Findings

#### 1. Runtime layout checks placed in `mh_vm_new` rather than `createVm`
- **Severity:** should-fix
- **Location:** `src/capi.zig:504-513`
- **What's wrong:** `verifySliceLayout()` and `verifyAssembledMode()` run exclusively in `mh_vm_new`. Any internal tests or embeddings constructing a VM via `capi.createVm(allocator, config)` (such as `src/capi_test.zig` and `src/capi_hostcall_test.zig`) bypass these runtime checks before making calls through `mh_call`.
- **Evidence:**
  `grep -rn "createVm(" src/capi*` shows `src/capi_hostcall_test.zig:401`, `src/capi_hostcall_test.zig:796`, `src/capi_test.zig:21`, and `src/capi_test.zig:25` all call `capi.createVm(testing.allocator, ...)` directly. Moving the check/assertions into `createVm` ensures every `VmBox` instance verifies slice and assembled-mode invariants upon creation regardless of the entry point.

---

#### 2. Acceptance harness hardcoded symbols and references for H3 transition
- **Severity:** should-fix (heads-up for H3)
- **Location:** `tools/hostcall-acceptance.sh:56`, `src/asm/hostcall_x64.S:44`
- **What's wrong:**
  1. `tools/hostcall-acceptance.sh:56` has a hardcoded symbol requirement:
     ```awk
     n = split("mahina_hostcall_entry mahina_hostcall_slow mahina_hostcall_offsets_safety", want, " ")
     ```
     When H3 exports `mahina_hostcall_chain` and `mahina_hostcall_park_rest`, this check will fail unless updated.
  2. `src/asm/hostcall_x64.S` declares hidden visibility on undefined references (`HIDDEN(SYM(mahina_hostcall_slow))`). In H3, the entry calls `mahina_hostcall_chain` and `mahina_hostcall_park_rest`, which must likewise be declared `.hidden` in the `.S` file to satisfy the per-object visibility check in `check_visibility`.
  3. The gdb walks in `check_walks` (lines 92, 94, 96) expect `mahina_hostcall_slow` for all 3 paths in H2. In H3, the admitted path and callback path will walk through `mahina_hostcall_chain <- mahina_hostcall_entry <- main`.
- **Evidence:**
  `readelf -sW` in `check_visibility` verifies `$6 == "HIDDEN"` on undefined references (`$7 == "UND"`). Running acceptance without declaring new references hidden will trigger `awk` failure on `libmahina.a`.

---

#### 3. Stateful operation inside `assert()` causes `capi-smoke` to hang under ReleaseFast
- **Severity:** should-fix (pre-existing)
- **Location:** `tests/capi_smoke.c:90`
- **What's wrong:** In `build.zig:171`, `smoke_mod` inherits `.optimize = optimize`. Under `ReleaseFast` and `ReleaseSmall`, the C compiler defines `NDEBUG`, causing `assert(expr)` to expand to `((void)0)`. Line 90 places a state-mutating function call inside `assert()`:
  ```c
  assert(mh_table_iter_next(vm, it, &k, &v, &done) == MH_OK);
  if (done) break;
  ```
  Under `NDEBUG`, `mh_table_iter_next` is never invoked, `done` remains `0`, and the loop spins indefinitely.
- **Evidence:**
  Running `zig build test -Doptimize=ReleaseFast -Dtest-filter=offsets_x64` spawned `.zig-cache/o/.../capi-smoke` at PID 2557673 consuming 99.9% CPU indefinitely until killed (`capi-smoke` is an unconditional dependency of `test_step` in `build.zig:179`). Replacing `assert(expr == MH_OK)` with explicit status checks or an always-active macro resolves this.

---

#### 4. Printed correction for inactive mode block displays active mode value
- **Severity:** nit
- **Location:** `src/asm/offsets_x64.zig:247-249`
- **What's wrong:** When an expected mode-dependent field is missing from the inactive block (e.g., missing from `#else` during a Debug build), line 249 prints:
  ```
  missing (in the #else block):  .set NAME, <value>
  ```
  Because `e.value` is evaluated at comptime for the active build (Debug), the printed suggestion for the `#else` block is the Debug offset (e.g. 27520), not the ReleaseFast offset (27288).
- **Evidence:**
  In `expected`:
  ```zig
  .{ .name = "VM_DEPTH", .value = off(Vm, "depth") }
  ```
  In Debug, `e.value` is 27520. When missing in `#else`, the suggested snippet prints `.set VM_DEPTH, 27520`. While the subsequent ReleaseFast build flags the wrong number and prints the correct value, adding a note that the suggested number reflects the active mode's layout would avoid confusion.

---

### Verification Summary

1. **Offsets checker (`src/asm/offsets_x64.zig`):**
   - Correctly enforces directive sequence (`#if MAHINA_RUNTIME_SAFETY` $\to$ `#else` $\to$ `#endif`), rejecting misplaced, nested, or unterminated blocks.
   - Enforces `.set NAME, N` syntax with decimal radix 10, rejects duplicate entries, unknown names, and entries present in both shared and mode blocks.
   - Verified that `optimize == .Debug or optimize == .ReleaseSafe` in `build.zig:135` matches `std.debug.runtime_safety` in `lib/std/debug.zig:237`.

2. **Assembly & Linkage (`src/asm/hostcall_x64.S`, `src/capi.zig`):**
   - Hidden visibility is verified per object for both definitions and undefined references:
     - `readelf -sW /tmp/review-h2-ag/acc/pic/lib/libmahina.a` confirms `mahina_hostcall_entry`, `mahina_hostcall_slow`, and `mahina_hostcall_offsets_safety` are all `GLOBAL HIDDEN` (including undefined references in `hostcall_x64.o` and `capi.o`).
     - `mh_call` is `GLOBAL DEFAULT`.
     - `readelf --dyn-syms` on `libmahina.so` contains only `mh_call`.
   - `mh_call` disassembly confirms frame teardown (`add $0x10, %rsp; pop %rbp`) followed by direct `jmp <mahina_hostcall_entry>`.
   - Non-executable stack verified via `.section .note.GNU-stack, "", @progbits` and `readelf -lW`.

3. **Acceptance Harness (`tools/hostcall-acceptance.sh`, `tools/hostcall_walk.py`):**
   - Both `ReleaseFast` and `Debug` acceptance runs pass all checks:
     - Shared library links with `--whole-archive -Wl,-z,text` (no `TEXTREL`).
     - PIE links and executes cleanly.
     - DWARF and raw `rbp` chain unwinding pass all 3 paths back to `main`.
     - Negative controls verified: DEFAULT symbol rejected by `check_visibility`, absolute text relocation rejected by `-z text`, `-fomit-frame-pointer` rejected by `expect-fp-walk`.

4. **Measured Overhead (§5.7):**
   - Re-measured `bench/embed/hostcall_probe.c` (`a1 2000000` minus `a1 0` setup) against `ReleaseFast` `libmahina.a`:
     - Instructions: $(906,777,995 - 777,484) / 2,000,000 = \mathbf{453.00}$ ins/call (+4 vs 449 baseline).
     - Cycles: $(139,116,780 - 768,750) / 2,000,000 = \mathbf{69.17}$ cyc/call (matches 69.1 table entry).
