# Codex — doc 60 H2 implementation review, round 3 (2026-10-04)

**APPROVE**

No new blocking, should-fix or nit findings.

1. **Round-2 finding 1 (blocking): resolved — [offsets_x64.zig:214](/home/bart/Projects/lune/src/asm/offsets_x64.zig:214).**  
   Byte validation runs before trimming or comment skipping. A full-file scratch probe containing the CR, backslash+FF and backslash+VT cases failed `zig build lib -Doptimize=Debug --prefix …` with:
   ```
   contains byte 0x0c
   contains byte 0x0d
   contains byte 0x0b
   ```
   Filtered offsets tests passed **7/7 in each of Debug, ReleaseSafe, ReleaseFast and ReleaseSmall**. I found no remaining CPP/GAS disagreement within the accepted grammar.

2. **Round-2 finding 2 (should-fix): resolved — [hostcall_walk.py:65](/home/bart/Projects/lune/tools/hostcall_walk.py:65).**  
   `Frame.level()` and the sniffer log both use `frame_relative_level`; retaining actual levels handles gaps from skipped inline frames. Cache flushing invalidates cached frames, and an absent acceptance event fails as `an unlogged unwinder`. Verified against GDB 15.1’s [frame API](https://github.com/RTEMS/sourceware-mirror-binutils-gdb/blob/gdb-15.1-release/gdb/python/py-frame.c), [cache invalidation](https://github.com/RTEMS/sourceware-mirror-binutils-gdb/blob/gdb-15.1-release/gdb/regcache.c), and [sniffer logging](https://github.com/RTEMS/sourceware-mirror-binutils-gdb/blob/gdb-15.1-release/gdb/frame-unwind.c).

   The actual walker/parser, exercised with simulated GDB events, accepted an inline-level gap and rejected prologue fallback, missing events and `dwarf2 signal`. Supplied logs show four DWARF walks, three frame-pointer walks, and:
   ```
   not unwound from CFI: host_cb by amd64 prologue
   ```
   A separate version-2-CIE fixture is no longer required: rejection now depends on GDB’s selected unwinder, independently of why it rejected CFI.

3. **Round-2 finding 3 (nit): resolved — [offsets_x64.inc:11](/home/bart/Projects/lune/src/asm/offsets_x64.inc:11).**  
   The header correctly distinguishes the one-byte lock from the eight-byte padded map increase. The grammar and `createVm` documentation updates match the code.

Live GDB remains blocked here by `ptrace: Operation not permitted`; live-walk evidence comes from your supplied logs. `bash -n tools/hostcall-acceptance.sh` passed.

Bart, I kept all 31 numbered rules in mind. Repository files and Git state were unchanged; scratch work stayed under `/tmp/review-h2-codex/`.

[Codex thread: 01a105b9-c55a-7e01-b928-1de8bb492882]
