# Antigravity — doc 60 H2 implementation re-review (round 2) (2026-10-04)

**VERDICT: APPROVE**

---

### Round 1 Findings Verification

#### Codex Round 1 Findings

1. **Codex 1 (blocking) — Canonical decimal parsing in offsets checker**
   - **Status in §10:** Fixed (`offsets_x64.zig`, §3.2).
   - **Verification:** `src/asm/offsets_x64.zig:291-297` implements `canonicalDecimal()`, enforcing optional `-` followed strictly by `0` or non-zero digits `[1-9][0-9]*`. Leading zeros (e.g. `064`, `00`), negative zero (`-0`), signs (`+64`), separators (`6_4`), bases (`0x40`, `0b1`), and suffixes (`64h`) are rejected.
   - **Evidence:** `zig build test -Dtest-filter=offsets_x64` passed unit tests `canonical decimal is the only accepted spelling` and `the checker rejects what cpp or gas would read differently`. `zig build lib` in all four optimization modes (`Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall`) compiled cleanly.

2. **Codex 2 (blocking) — Preprocessor line splicing swallowing directives**
   - **Status in §10:** Fixed (`offsets_x64.zig`, §3.2).
   - **Verification:** `src/asm/offsets_x64.zig:212-219` inspects trimmed lines prior to skipping blank lines or comments. Lines ending in `\` or containing trigraph `??/` are flagged before any comment strip can occur.
   - **Evidence:** Tested in `src/asm/offsets_x64.zig:354-356` with test cases `// boundary \\\n#else\n`, `.set VM_TAGS, 64 \\\n`, and `// boundary ??/\n`.

3. **Codex 3 (should-fix) — Cargo rebuild dependencies for `.S` and offsets**
   - **Status in §10:** Fixed (`build.rs`).
   - **Verification:** `embed/rust/mahina-sys/build.rs:79` now emits `cargo:rerun-if-changed` on directory `"src"`, `"include"`, `"build.zig"`, `"build.zig.zon"`, and `".zig-version"`. Cargo recursively scans directory targets, covering `src/asm/`.
   - **Evidence:** `cargo test --manifest-path embed/rust/mahina-sys/Cargo.toml --locked --offline` and `--release` run cleanly (2 passed).

4. **Codex 4 (should-fix) — DWARF unwinding verification and entry CFI coverage**
   - **Status in §10:** Fixed (`hostcall_walk.py`, §5.7).
   - **Verification:** `tools/hostcall_walk.py:153-157` queries all FDE intervals via `readelf --debug-dump=frames -W` and verifies that every physical frame's PC falls within an active FDE, preventing silent fallback to GDB's `i386 prologue` unwinder. An explicit breakpoint at `mahina_hostcall_entry` checks that the entry's pre-commit `.cfi_startproc`/`.cfi_endproc` interval is walked back to `main`.
   - **Evidence:** `tools/hostcall-acceptance.sh:187-197` negative control `accept-pie-nocfi` correctly fails with `walk FAILED: callback: no FDE covers host_cb, main (gdb may have unwound without CFI)`.

5. **Codex 5 (should-fix) — Text relocation negative control discriminating `-z text`**
   - **Status in §10:** Fixed (`hostcall-acceptance.sh`).
   - **Verification:** `tools/hostcall-acceptance.sh:172-183` replaced `movl $f, %eax` with `movabs $f, %rax`. The control verifies that the permissive shared object links and contains `TEXTREL`, while linking with `-Wl,-z,text` fails.
   - **Evidence:** Acceptance runs output `ok: -z text rejects a text relocation that links without it`.

6. **Codex 6 (nit) — `SafetyLock` size documentation**
   - **Status in §10:** Fixed (§3.2, `offsets_x64.zig`).
   - **Verification:** `docs/design/60-hand-written-machine-code.md:370-372` and `src/asm/offsets_x64.zig:24-26` accurately state `SafetyLock` is a one-byte enum under safety, which padding turns into 8 additional bytes per map.

7. **Codex 7 (nit) — Instruction delta summary range**
   - **Status in §10:** Fixed (§5.7, status).
   - **Verification:** `docs/design/60-hand-written-machine-code.md:141-143` and line 1424 specify −2…+12 instructions across all shapes, noting +3…+12 on every shape except `vararg` (−2).

---

#### Antigravity Round 1 Findings

1. **Antigravity 1 (should-fix) — Relocate runtime layout checks into `createVm`**
   - **Status in §10:** Fixed (`capi.zig`).
   - **Verification:** `src/capi.zig:461-468` executes `verifySliceLayout()` and `verifyAssembledMode()` directly within `createVm()`, ensuring tests calling `createVm` directly validate slice layout and safety mode invariants before executing calls.

2. **Antigravity 2 (should-fix / heads-up) — H3 acceptance symbols and walks**
   - **Status in §10:** Noted (status).
   - **Verification:** `docs/design/60-hand-written-machine-code.md:163-167` explicitly tracks the carry-over requirements for H3 (`mahina_hostcall_chain`, `mahina_hostcall_park_rest`, `ChainResult`, CFI, and acceptance walks).

3. **Antigravity 3 (should-fix pre-existing) — `capi-smoke` asserts vanish under `NDEBUG`**
   - **Status in §10:** Fixed separately in its own commit after H2 (`tests/capi_smoke.c`).
   - **Verification:** Logged in `TODO.md:5-10`. Deliberately excluded from H2 changes as planned.

4. **Antigravity 4 (nit) — Missing block value reporting**
   - **Status in §10:** Fixed (`offsets_x64.zig`).
   - **Verification:** `src/asm/offsets_x64.zig:281` prints `missing (in the {s} block): {s}; a build of that kind prints its number` rather than outputting the active mode's numerical value.

---

### Analysis of New Mechanisms

1. **Soundness of FDE-coverage in `tools/hostcall_walk.py`:**
   - **Load offset:** In a PIE, `readelf -sW` provides the file static address of `main` (`st_value`). In GDB, `int(gdb.parse_and_eval("(unsigned long)&main")) - main` yields the runtime ASLR slide (load bias). Applying `offset` to all static FDE boundaries `[a + offset, b + offset)` accurately relocates intervals to runtime memory.
   - **`.eh_frame` vs `.debug_frame`:** `readelf --debug-dump=frames -W` parses and outputs both `.eh_frame` and `.debug_frame` sections if present. The regex `re.findall(r"pc=([0-9a-f]+)\.\.([0-9a-f]+)", frames)` collects all interval records matching GNU binutils output format. Since GDB's `dwarf2` unwinder claims any frame covered by an FDE prior to invoking `i386 prologue`, confirming PC presence inside an FDE strictly proves CFI coverage.
   - **`pc - 1` for callers:** In x86-64, caller frame return addresses sit immediately after the `call` instruction. If a call instruction is terminal or followed by unconditional jumps/tail code, the return address can coincide with the start of the subsequent function, landing outside the caller's half-open FDE `[a, b)`. `pc = frame.pc() - 1` guarantees the examined byte resides inside the caller's `call` instruction within `[a, b)`. For the innermost frame, `frame.pc()` is evaluated directly.
   - **Assembly Entry Stop:** Breaking at `mahina_hostcall_entry` validates the pre-commit stretch. Its FDE `pc=0000000000664c90..0000000000664c95` is verified, and the walk pattern `mahina_hostcall_entry main` requires `main` to be the direct caller, proving both CFI presence and frame-less tail-call handoff from `mh_call`.

2. **Parser Agreement (`offsets_x64.zig` vs Preprocessor & GNU as):**
   - The grammar accepted by `problemsIn` strictly restricts input to canonical decimal numbers, `#if MAHINA_RUNTIME_SAFETY`, `#else`, `#endif`, blank lines, and `//` comments.
   - Any inline comments after `.set` (e.g. `;`, `//`, `#`), block comments `/* */`, octal literals, hex literals, trigraphs `??/`, or trailing backslashes `\` are rejected at comptime.

3. **Documentation Claims vs Tree:**
   - Claims in Status, §3.1 As built, §3.2 Follow-up, §5.7, §6.3 As built, Q11, and §10 match the implementation in the tree.

---

### Findings

#### 1. Outdated `SafetyLock` size comment in `offsets_x64.inc`
- **Severity:** nit
- **Location:** `src/asm/offsets_x64.inc:8`
- **What's wrong:** While §3.2 and `src/asm/offsets_x64.zig:24` were updated to reflect that `SafetyLock` is 1 byte (expanded to 8 bytes per map by padding), line 8 of `src/asm/offsets_x64.inc` still reads:
  ```
  // hash maps carry an 8-byte SafetyLock under Debug/ReleaseSafe, which moves
  ```
- **Evidence:** `git diff src/asm/offsets_x64.zig src/asm/offsets_x64.inc` shows the discrepancy between the explanation in `.zig` vs the comment in `.inc`.

#### 2. Stale reference to `mh_vm_new` in `build.zig` comment and doc 60 §3.2
- **Severity:** nit
- **Location:** `build.zig:131`, `docs/design/60-hand-written-machine-code.md:493`
- **What's wrong:** Runtime layout checks (`verifySliceLayout` and `verifyAssembledMode`) were moved to `capi.createVm`. `build.zig:131` states `and mh_vm_new verifies the two agree`, and doc line 493 states `the same check runs once in mh_vm_new on the gated target`.
- **Evidence:** `src/capi.zig:461-468` contains the calls in `createVm`. `mh_vm_new` delegates to `createVm`.

#### 3. Pathological C whitespace after line-continuation backslash
- **Severity:** nit
- **Location:** `src/asm/offsets_x64.zig:208-215`
- **What's wrong:** `line = std.mem.trim(u8, raw, " \t\r")` trims spaces, tabs, and `\r`. Standard C (ISO C99 6.4) also classifies vertical tab (`\v` / `0x0B`) and form feed (`\f` / `0x0C`) as whitespace, and GCC/Clang will splice lines when `\` is followed by `\v` or `\f` before `\n`. If a comment ended with `\\\v`, `endsWith(line, "\\")` would be false because `line` ends with `\v`, bypassing the backslash check while still splicing in the C preprocessor.
- **Evidence:** In a scratch probe, `printf '// test \\\v\n#define FOO 1\nint x = FOO;\n' | gcc -E -P -` spliced the lines and emitted `int x = FOO;`. Trimming `" \t\r\x0b\x0c"` closes this edge case.
