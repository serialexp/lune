/*
 * Doc 60: the hand-written host-call entry, Linux x86-64 (SysV, ELF).
 *
 * `mh_call` (capi.zig) does the public checks, then tail-calls
 * `mahina_hostcall_entry` with its own seven-argument signature:
 *
 *   rdi  vm (non-null)          rsi, rdx  callee (tag word, payload word)
 *   rcx  args                   r8   nargs
 *   r9   results                [rsp+8]   max_results (0 when results is null)
 *   [rsp+16]  nresults (non-null, *nresults already 0)
 *
 * Narrow contract, established by mh_call: the VM is not fatal.
 *
 * Every pre-commit rejection is a bare `jmp mahina_hostcall_slow` (H1,
 * capi.zig) before any prologue or VM write, with the argument registers and
 * both stack arguments untouched, so H1 sees exactly the call mh_call made.
 *
 * H2 (this revision) builds the layer — build wiring, hidden linkage, the
 * offsets file and its comptime check — and the entry is the fallback edge
 * alone. H3 adds the admitted path in front of it.
 *
 * Object-format specifics stay behind the macros below, so a later Mach-O
 * port changes only them (symbol prefix, section, private visibility).
 */

/* The build passes MAHINA_RUNTIME_SAFETY from the optimize mode: std's hash
 * maps are larger under runtime safety, which moves some Vm fields, so the
 * offsets file carries a block per mode (offsets_x64.zig explains). */
#if !defined(MAHINA_RUNTIME_SAFETY)
#error "MAHINA_RUNTIME_SAFETY must be defined (build.zig derives it from the optimize mode)"
#endif
#include "offsets_x64.inc"

#define SYM(name) name
#define HIDDEN(name) .hidden name
#define FUNC_BEGIN(name) \
    .globl SYM(name); HIDDEN(SYM(name)); .type SYM(name), @function; .p2align 4; SYM(name):
#define FUNC_END(name) .size SYM(name), . - SYM(name)

    .text

    /* Undefined references are hidden too (doc 60 §4.2): the per-object
     * visibility check holds for references as well as definitions. */
    HIDDEN(SYM(mahina_hostcall_slow))

FUNC_BEGIN(mahina_hostcall_entry)
    .cfi_startproc
    jmp SYM(mahina_hostcall_slow)
    .cfi_endproc
FUNC_END(mahina_hostcall_entry)

    /* The offsets block this object was assembled with; every VM's creation
     * (capi.createVm) and a unit test compare it with the Zig side's
     * runtime_safety. */
    .section .rodata
    .globl SYM(mahina_hostcall_offsets_safety)
    HIDDEN(SYM(mahina_hostcall_offsets_safety))
    .type SYM(mahina_hostcall_offsets_safety), @object
    .size SYM(mahina_hostcall_offsets_safety), 1
SYM(mahina_hostcall_offsets_safety):
    .byte MAHINA_RUNTIME_SAFETY

    /* No executable stack. */
    .section .note.GNU-stack, "", @progbits
