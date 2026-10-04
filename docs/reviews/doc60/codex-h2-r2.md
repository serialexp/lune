# Codex — doc 60 H2 implementation review, round 2 (2026-10-04)

**CHANGES REQUESTED**

1. **blocking — [src/asm/offsets_x64.zig:208](/home/bart/Projects/lune/src/asm/offsets_x64.zig:208): comments still permit unchecked assembly.**

   Two scratch probes passed library builds:

   - Appending `// hidden line\r.set VM_TAGS, 52\n` with a literal bare CR passed ReleaseFast. Zig skips the whole comment; CPP treats CR as a newline. `readelf -sW` reported `VM_TAGS=0x34` (52), rather than 64.
   - Inserting `// mode boundary \\f\n` before `#else`, with a literal form feed after the backslash, passed Debug. CPP warned `backslash and newline separated by space` and swallowed `#else`. The object contained fast-mode `VM_DEPTH=27288` and `TRACE_FAST_BLOCK=10176`, rather than Debug’s 27520 and 10408.

   The second object’s safety byte remained `01`; its linked fixture printed `hostcall-accept: ok`. Reject bare CR and continuation-capable whitespace before skipping comments, and test both full-file cases. §3.2’s grammar-agreement claim remains false.

2. **should-fix — [tools/hostcall_walk.py:71](/home/bart/Projects/lune/tools/hostcall_walk.py:71), doc §5.7: readelf coverage does not establish GDB’s chosen unwinder.**

   GDB searches its decoded, filtered FDE table. It rejects unsupported CIE versions and prefers `.debug_frame` when discarding entries with identical initial addresses. The checker instead unions every range printed by readelf. [GDB 15.1 decoder and FDE selection](https://github.com/RTEMS/sourceware-mirror-binutils-gdb/blob/gdb-15.1-release/gdb/dwarf2/frame.c).

   Evidence: `/tmp/review-h2-codex/fde-v2` contains a version-2 CIE in `.debug_frame`. Readelf prints its FDE covering `foo` and `main`; invoking the actual `_fde_ranges()` in GDB printed:
   ```
   foo covered: True
   main covered: True
   ```
   GDB 15’s decoder rejects that CIE. A successful prologue fallback would therefore pass the coverage check.

   Verify the selected unwinder and add a rejected-CIE negative control. GDB 15’s frame-debug logging records each sniffer’s acceptance. [GDB unwinder logging](https://github.com/RTEMS/sourceware-mirror-binutils-gdb/blob/gdb-15.1-release/gdb/frame-unwind.c). The current fixture’s caller `pc-1` adjustment and PIE offset computation are appropriate; the coverage inference is the gap.

3. **nit — [src/asm/offsets_x64.inc:8](/home/bart/Projects/lune/src/asm/offsets_x64.inc:8): the old SafetyLock wording remains.**

   This header still says “8-byte SafetyLock.” The lock is one byte under safety; padding increases the map size by eight bytes. The doc and Zig checker now describe this correctly. Round-1 finding 6 is only partially resolved.

Round-1 dispositions and verification:

- **1 and the original 2 reproductions:** now fail builds with `value is not a canonical decimal integer` and `ends in a backslash`, respectively. Finding 1 above identifies remaining bypasses.
- **3:** resolved. Changing scratch assembly triggered Cargo’s `Dirty mahina-sys … src has changed`; the rebuilt archive’s entry grew from five to six bytes. Rust tests passed **31/31**.
- **4:** partially resolved. Supplied logs show the new entry walk and rejection of the no-CFI fixture. Finding 2 remains.
- **5:** resolved. The `movabs` object linked permissively with `TEXTREL`; `-z text` rejected it with `read-only segment has dynamic relocations`.
- **6:** doc/checker corrected; remaining header covered above.
- **7:** resolved. Fresh gate-off/H2 probes reproduced all twelve instruction-count rows, including `vararg` **510→508**.

Offsets tests passed **7/7** in Debug and ReleaseFast. Runtime checks are before allocation in `createVm`. Own acceptance passed visibility, links, execution and tail-jump checks before `ptrace: Operation not permitted`; live walks could not be repeated here. The NDEBUG smoke issue remains deferred as requested.

Bart, I kept all 31 numbered rules in mind. Repository files and Git state were unchanged; scratch work stayed under `/tmp/review-h2-codex/`.

[Codex thread: 01a105b9-c55a-7e01-b928-1de8bb492882]
