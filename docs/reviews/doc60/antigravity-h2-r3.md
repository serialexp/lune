# Antigravity — doc 60 H2 implementation re-review, round 3 (2026-10-04)

**VERDICT: APPROVE**

---

### Verification of Round 2 Findings

1. **Codex r2 1 (blocking) / Antigravity r2 3 (nit) — Unchecked assembly via bare CR, backslash + whitespace (`\f`, `\v`), and CRLF**
   - **Resolution:** `src/asm/offsets_x64.zig:214-220` enforces that every byte in each line must be a tab or printable ASCII (`0x20..0x7e`) before any trimming or comment stripping. Lines ending in `\` or containing `??/` are rejected before skipping comments.
   - **Evidence:** `zig build test -Dtest-filter=offsets_x64` ran 12/12 test steps cleanly. Comptime tests at `src/asm/offsets_x64.zig:372-375` explicitly assert rejection of bare CR (`0x0d`), FF (`0x0c`), VT (`0x0b`), and CRLF (`\r\n`). All 4 library optimize modes (`Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall`) built cleanly via `zig build lib`.

2. **Codex r2 2 (should-fix) — GDB unwinder selection verification**
   - **Resolution:** `tools/hostcall_walk.py:65-98` replaced readelf FDE range inference with dynamic GDB frame unwinder auditing. `_logged_walk()` flushes the frame cache (`maint flush register-cache`), captures GDB's `set debug frame on` log into a temporary file, and extracts the unwinder accepted for each frame level (`frame_unwind_try_unwinder: yes`). `expect-walk` verifies that every machine frame except `main` was accepted by unwinder `"dwarf2"`.
   - **Evidence:**
     - `HOSTCALL_ACCEPTANCE_DIR=/tmp/review-h2-ag/acc3 bash tools/hostcall-acceptance.sh` passed all checks in `ReleaseFast` (4 DWARF walks, 3 FP walks).
     - `HOSTCALL_ACCEPTANCE_DIR=/tmp/review-h2-ag/acc3-dbg bash tools/hostcall-acceptance.sh Debug` passed all checks in `Debug`.
     - The negative control `accept-pie-nocfi` correctly reported `walk FAILED: callback: not unwound from CFI: host_cb by amd64 prologue` (in `/tmp/review-h2-ag/acc3/neg/walk-nocfi.log`).

3. **Codex r2 3 / Antigravity r2 1 (nit) — Outdated `SafetyLock` comment in `.inc`**
   - **Resolution:** `src/asm/offsets_x64.inc:10-15` now accurately explains that `std`'s hash maps carry a one-byte `SafetyLock` under Debug/ReleaseSafe, which padding makes 8 more bytes per map. Line 1 also removed the non-ASCII `§` character.

4. **Antigravity r2 2 (nit) — Stale reference to `mh_vm_new`**
   - **Resolution:** `build.zig:132-133` and doc 60 §3.2 (line 498) now explicitly refer to `capi.createVm`.

---

### Soundness Analysis of New Mechanisms

1. **GDB Log Parsing & Level Numbering:**
   - In GDB C++ source, `frame_unwind_find_by_frame` logs `this_frame=%d` formatted using `frame_relative_level(this_frame)`. In GDB Python API, `frame.level()` evaluates `frame_relative_level(frame)`. The two level numbers are identical integers across physical and inline frames.
2. **Inline Frames Handling:**
   - `_physical_walk()` filters out frames with `frame.type() == gdb.INLINE_FRAME`, keeping only physical machine frames in `frames` with their original GDB levels (e.g. 0, 1, 3, 7, 8 when frames 2, 4, 5, 6 are inlined).
   - In GDB's unwinding log, inline frames register unwinder `"inline"` at their respective levels, while physical frames register `"dwarf2"`.
   - `ExpectWalk` checks `unwinders.get(level) == "dwarf2"` specifically for the levels in `frames[:-1]`, confirming that every machine frame on the path between the stop and `main` was unwound via DWARF CFI.
3. **Cache Flushing:**
   - `maint flush register-cache` runs prior to enabling `set debug frame on` and executing `_physical_walk()`. This completely clears GDB's cached `frame_info` structures. The subsequent `gdb.newest_frame()` call forces GDB to re-sniff and re-unwind frame 0 and all caller frames afresh while logging is active.
4. **Target Assembly & Safety Mode Byte:**
   - Inspected `mahina_hostcall_offsets_safety` in the built static archive `libmahina.a`: `.rodata` contains byte `01` in `Debug` and `ReleaseSafe`, and byte `00` in `ReleaseFast` and `ReleaseSmall`.

---

### Documentation Claims vs Tree

- **§10 Review Tables:** Round 2 findings from both Codex and Antigravity are logged with accurate statuses and locations.
- **Status & §3.2, §5.7, §6.3:** Descriptions of the offsets grammar, `createVm` checks, GDB DWARF unwinder verification via frame-debug logs, and negative controls match the committed code.
- **Suite Gate:** `just test` passes (unit tests + boundary tests + `capi smoke: OK`). Cargo tests for `mahina-sys` pass in both debug and release.
