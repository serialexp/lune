# Codex — doc 60 H2 implementation review (2026-10-04)

CHANGES REQUESTED

1. **blocking — [src/asm/offsets_x64.zig:222](/home/bart/Projects/lune/src/asm/offsets_x64.zig:222): decimal parsing disagrees with the assembler.**  
   The checker accepts leading-zero integers as decimal; the assembler interprets them as octal. In a `/tmp` copy, changing `VM_TAGS` from `64` to `064` passed `zig build lib -Doptimize=ReleaseFast --prefix …`. `readelf -sW` then showed `VM_TAGS = 0x34`—52, rather than 64. H3 would access the wrong field despite a passing checker. Require canonical decimal spelling and add a negative control for leading zeros.

2. **blocking — [src/asm/offsets_x64.zig:195](/home/bart/Projects/lune/src/asm/offsets_x64.zig:195): skipped comments can change preprocessing.**  
   The checker splits physical lines and ignores comments before accounting for backslash-newline splicing. Adding `// mode boundary \` immediately before `#else` passed a Debug library build. Preprocessing swallowed `#else`, so the fast block overwrote the safe block. `readelf` reported `VM_DEPTH=27288` and `TRACE_FAST_BLOCK=10176`, instead of Debug’s 27520 and 10408. The linked acceptance fixture still printed `hostcall-accept: ok`: the safety byte remained 1, so `verifyAssembledMode()` did not detect this. Reject preprocessing continuations before skipping comments and test this case.

3. **should-fix — [embed/rust/mahina-sys/build.rs:76](/home/bart/Projects/lune/embed/rust/mahina-sys/build.rs:76): Cargo does not watch the new assembly dependencies.**  
   None of `src/asm/hostcall_x64.S`, the offsets files, or `target.zig` appears in the rerun dependencies. After building the scratch Rust workspace, I added a `nop` to its assembly entry and reran `cargo test --locked --offline -vv`. Cargo printed `Fresh mahina-sys`; its archive retained a five-byte entry, while compiling the changed `.S` produced six bytes. H3 assembly-only changes can therefore leave Rust tests exercising stale code. Watch `src/asm` or all four files.

4. **should-fix — [tools/hostcall-acceptance.sh:88](/home/bart/Projects/lune/tools/hostcall-acceptance.sh:88), [tools/hostcall_walk.py:36](/home/bart/Projects/lune/tools/hostcall_walk.py:36): the DWARF leg does not establish DWARF unwinding.**  
   `_physical_walk()` accepts whichever unwinder GDB chooses. `maintenance info frame-unwinders` lists `i386 prologue` alongside `dwarf2`; the harness neither checks the selected unwinder nor tests rejection when unwind information is absent. It also never stops inside `mahina_hostcall_entry`, so deleting that routine’s CFI would leave all three inspected stacks unchanged. Verify DWARF use and explicitly cover the assembly entry’s FDE, with a missing/broken-CFI negative control. My live GDB probes were blocked by `ptrace: Operation not permitted`.

5. **should-fix — [tools/hostcall-acceptance.sh:158](/home/bart/Projects/lune/tools/hostcall-acceptance.sh:158): the relocation negative control does not test `-z text`.**  
   `movl $f,%eax` produces `R_X86_64_32`, which the linker rejects for a shared object even without `-z text`. Both link commands failed with `relocation R_X86_64_32 … can not be used when making a shared object`. A scratch `movabs $f,%rax` control linked without the flag and produced `TEXTREL`; adding `-z text` rejected it with `read-only segment has dynamic relocations`. Use that discriminating control and require its permissive link to succeed.

6. **nit — doc §3.2, [line 368](/home/bart/Projects/lune/docs/design/60-hand-written-machine-code.md:368), and [src/asm/offsets_x64.zig:20](/home/bart/Projects/lune/src/asm/offsets_x64.zig:20): `SafetyLock` itself is one byte under safety.**  
   Pinned-toolchain compile probes reported `@sizeOf(SafetyLock)=1` in Debug and 0 in ReleaseFast. `AutoHashMapUnmanaged(u64,u64)` grows from 16 to 24 bytes because of padding. Describe the eight-byte map-size increase rather than an eight-byte lock.

7. **nit — doc §5.7, [line 1388](/home/bart/Projects/lune/docs/design/60-hand-written-machine-code.md:1388): the instruction-cost summary excludes `vararg`.**  
   “+3…+12 instructions” contradicts the table’s `vararg` row, 510→508. Five fresh interleaved runs of 2M calls reproduced every listed instruction count, including that −2. State the exception or use the full range.

Verification: the Debug gate passed **1615/1615 tests**, JIT boundary checks passed, focused ReleaseFast C API tests passed, and offsets tests passed across all four optimize modes. Rust tests passed in debug and release. ReleaseFast and Debug acceptance passed visibility, real links, fixture execution, and tail-jump checks before the environment blocked GDB. A deliberately mismatched safety-mode object correctly panicked in `mh_vm_new`.

Bart, I kept all 31 numbered rules in mind. Repository files and Git state were unchanged; scratch work stayed under `/tmp/review-h2-codex`.

[Codex thread: 01a105b9-c55a-7e01-b928-1de8bb492882]
